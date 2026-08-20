const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const HandleRegistry = @import("handle_registry.zig");
const handlers = @import("handlers.zig");
const Window = @import("../window.zig");
pub const NotificationStore = @import("../notification_store.zig");
pub const ClaudeSessionStore = @import("../claude_session_store.zig");

const c = @import("../c.zig");

const log = std.log.scoped(.socket_server);
const Allocator = std.mem.Allocator;

pub const Server = @This();

alloc: Allocator,
socket_path: []const u8,
listen_fd: ?posix.socket_t = null,
registry: HandleRegistry,
running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
accept_thread: ?std.Thread = null,

/// Reference to the application window (set after both are initialized).
window: ?*Window = null,

/// In-memory notification store.
notification_store: NotificationStore = .{},

/// In-memory Claude Code session store.
claude_session_store: ClaudeSessionStore,

// --- In-flight client tracking ---
//
// Client handlers run on detached threads and dereference this Server (and,
// through it, the Window) for the whole request. `deinit` runs from main()
// after g_application_run() returns, so without a drain it can free both out
// from under a handler that is still mid-request.

/// Guards `clients` and `active_clients`.
client_mutex: std.Thread.Mutex = .{},
/// Signalled when `active_clients` reaches zero.
client_drained: std.Thread.Condition = .{},
/// Sockets whose handler thread has not returned yet. Kept so shutdown can
/// wake threads parked in a blocking read().
clients: std.AutoHashMapUnmanaged(posix.socket_t, void) = .{},
/// Number of registered handlers still running.
active_clients: usize = 0,

/// Largest request line accepted. A longer line is drained and answered with
/// `request_too_large` rather than being parsed in pieces.
const max_request_bytes: usize = 8192;

/// Backing store for the null-terminated socket path handed to C. Unix socket
/// paths are capped at 108 bytes by the kernel, so this is generous.
const socket_path_buf_len: usize = 256;

/// How long shutdown waits for handlers to finish.
///
/// Sized just above the 10s GTK dispatch timeout in handlers.zig: once the
/// GTK loop is gone, a handler blocked in `runOnMainThread` cannot complete
/// until that timeout expires, and cutting the drain shorter would leave it
/// running against freed memory.
const drain_timeout_ns: u64 = 11 * std.time.ns_per_s;

pub fn init(alloc: Allocator) !*Server {
    const self = try alloc.create(Server);

    // Determine socket path
    const socket_path = if (std.posix.getenv("AMUX_SOCKET"))
        |s| try alloc.dupe(u8, s)
    else if (std.posix.getenv("AMUX_SOCKET_PATH"))
        |s| try alloc.dupe(u8, s)
    else
        try alloc.dupe(u8, "/tmp/amux.sock");

    self.* = .{
        .alloc = alloc,
        .socket_path = socket_path,
        .registry = HandleRegistry.init(alloc),
        .claude_session_store = ClaudeSessionStore.init(alloc),
    };

    return self;
}

/// Return the socket path as a null-terminated pointer.
/// The path allocated by init is contiguous and followed by unused allocator bytes,
/// but to be safe we store a sentinel copy on first call.
pub fn getSocketPathZ(self: *Server) [*:0]const u8 {
    // The alloc.dupe in init copies exact bytes without a sentinel.
    // We rely on the path being stored in a larger allocation that
    // happens to have a zero byte after it in practice, but let's be safe:
    // socket paths are always < 108 bytes (Unix limit), use a static buffer.
    const Static = struct {
        var buf: [socket_path_buf_len]u8 = undefined;
        var initialized: bool = false;
    };
    if (!Static.initialized) {
        const len = @min(self.socket_path.len, Static.buf.len - 1);
        @memcpy(Static.buf[0..len], self.socket_path[0..len]);
        Static.buf[len] = 0;
        Static.initialized = true;
    }
    return @ptrCast(&Static.buf);
}

pub fn deinit(self: *Server) void {
    if (!self.stop()) {
        // Handlers are still running and still dereferencing `self`. The
        // process is on its way out, so leaking is strictly safer than freeing
        // memory another thread is about to touch. The OS reclaims it.
        log.warn("Skipping server teardown: client handlers still active", .{});
        return;
    }
    self.clients.deinit(self.alloc);
    self.claude_session_store.deinit();
    self.registry.deinit();
    self.alloc.free(self.socket_path);
    self.alloc.destroy(self);
}

/// Register an accepted socket *before* its handler thread starts, so a
/// concurrent stop() cannot miss a client that is still being spawned.
fn registerClient(self: *Server, fd: posix.socket_t) bool {
    self.client_mutex.lock();
    defer self.client_mutex.unlock();
    self.clients.put(self.alloc, fd, {}) catch return false;
    self.active_clients += 1;
    return true;
}

fn unregisterClient(self: *Server, fd: posix.socket_t) void {
    self.client_mutex.lock();
    defer self.client_mutex.unlock();
    _ = self.clients.remove(fd);
    self.active_clients -= 1;
    if (self.active_clients == 0) self.client_drained.broadcast();
}

/// Wake every in-flight handler and wait for it to return.
/// Returns false if the drain timed out.
fn drainClients(self: *Server) bool {
    self.client_mutex.lock();
    defer self.client_mutex.unlock();

    // Unblock handlers parked in read(). Closing is not enough on its own;
    // shutdown() makes the pending read return immediately.
    var it = self.clients.keyIterator();
    while (it.next()) |fd| posix.shutdown(fd.*, .both) catch {};

    var timer = std.time.Timer.start() catch return self.active_clients == 0;
    while (self.active_clients > 0) {
        const elapsed = timer.read();
        if (elapsed >= drain_timeout_ns) {
            log.warn("Drain timed out with {d} client handler(s) still running", .{self.active_clients});
            return false;
        }
        self.client_drained.timedWait(&self.client_mutex, drain_timeout_ns - elapsed) catch {};
    }
    return true;
}

/// Start the socket server in a background thread.
pub fn start(self: *Server) !void {
    // Clean up stale socket
    std.fs.deleteFileAbsolute(self.socket_path) catch {};

    // Create Unix domain socket
    const addr = try std.net.Address.initUnix(self.socket_path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    // Create the socket as 0600. bind() applies the umask to the new inode, so
    // setting it around the call is atomic -- chmod()ing the path afterwards
    // would leave a window where another local user could connect. Anyone who
    // can connect can drive every terminal amux owns.
    {
        const prev_umask = std.c.umask(0o177);
        defer _ = std.c.umask(prev_umask);
        try posix.bind(fd, &addr.any, addr.getOsSockLen());
    }
    try posix.listen(fd, 5);

    self.listen_fd = fd;
    self.running.store(true, .release);

    log.info("Socket server listening on {s}", .{self.socket_path});

    // Spawn accept thread
    self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
}

/// Stop accepting connections and wait for in-flight handlers to finish.
/// Returns false if handlers were still running when the drain timed out.
pub fn stop(self: *Server) bool {
    self.running.store(false, .release);

    if (self.listen_fd) |fd| {
        // close() alone does not reliably return a blocked accept(); shutdown()
        // does, so the accept thread can actually be joined.
        posix.shutdown(fd, .both) catch {};
        posix.close(fd);
        self.listen_fd = null;
    }
    if (self.accept_thread) |thread| {
        thread.join();
        self.accept_thread = null;
    }

    // The accept thread has exited, so no further clients can be registered
    // and the set can only shrink from here.
    const drained = self.drainClients();

    // Clean up socket file
    std.fs.deleteFileAbsolute(self.socket_path) catch {};
    return drained;
}

fn acceptLoop(self: *Server) void {
    // Read the descriptor once: stop() clears the field, and re-reading it
    // every iteration races that write.
    const listen_fd = self.listen_fd orelse return;

    while (self.running.load(.acquire)) {
        const client = posix.accept(listen_fd, null, null, 0) catch |err| {
            if (!self.running.load(.acquire)) break;
            log.warn("Accept error: {}", .{err});
            continue;
        };

        // Register before spawning. If stop() ran between accept() and the
        // thread starting, an unregistered client would not be waited for.
        if (!self.registerClient(client)) {
            log.warn("Failed to register client socket", .{});
            posix.close(client);
            continue;
        }

        // Spawn a thread to handle this client.
        //
        // The handle must be detached: a Thread that is neither joined nor
        // detached never releases its stack and bookkeeping. amux-cli opens a
        // fresh connection per command, so leaving these attached leaked memory
        // on every single CLI invocation.
        const thread = std.Thread.spawn(.{}, handleClient, .{ self, client }) catch |err| {
            log.warn("Failed to spawn client thread: {}", .{err});
            self.unregisterClient(client);
            posix.close(client);
            continue;
        };
        thread.detach();
    }
}

fn handleClient(self: *Server, client_fd: posix.socket_t) void {
    defer {
        // Unregister before closing so the drain never shutdown()s a
        // descriptor number that has already been recycled. Nothing after this
        // touches `self` -- once the count hits zero, deinit may free it.
        self.unregisterClient(client_fd);
        posix.close(client_fd);
    }

    const stream = std.net.Stream{ .handle = client_fd };
    var buf: [max_request_bytes]u8 = undefined;
    var leftover: usize = 0;
    var overflow = false; // true when a line exceeds the buffer

    while (self.running.load(.acquire)) {
        // If the buffer is full without a newline, the line is too large.
        if (leftover >= buf.len) {
            overflow = true;
            leftover = 0;
        }

        // Read data
        const n = stream.read(buf[leftover..]) catch break;
        if (n == 0) break; // Client disconnected

        const total = leftover + n;

        // Process complete lines
        var line_start: usize = 0;
        for (0..total) |i| {
            if (buf[i] == '\n') {
                if (overflow) {
                    // Discard the oversized line and send an error
                    overflow = false;
                    var msg_buf: [64]u8 = undefined;
                    const msg = std.fmt.bufPrint(
                        &msg_buf,
                        "Request exceeds maximum size of {d} bytes",
                        .{max_request_bytes},
                    ) catch "Request too large";
                    const err_resp = protocol.errorResponse(
                        self.alloc,
                        0,
                        "request_too_large",
                        msg,
                    ) catch {
                        line_start = i + 1;
                        continue;
                    };
                    defer self.alloc.free(err_resp);
                    stream.writeAll(err_resp) catch {};
                    stream.writeAll("\n") catch {};
                } else {
                    const line = buf[line_start..i];
                    if (line.len > 0) {
                        self.processRequest(stream, line);
                    }
                }
                line_start = i + 1;
            }
        }

        // Save leftover data
        if (line_start < total) {
            std.mem.copyForwards(u8, &buf, buf[line_start..total]);
            leftover = total - line_start;
        } else {
            leftover = 0;
        }
    }
}

fn processRequest(self: *Server, stream: std.net.Stream, line: []const u8) void {
    const alloc = self.alloc;

    var req = protocol.Request.parse(alloc, line) catch {
        // Send parse error
        const err_resp = protocol.errorResponse(alloc, 0, "invalid_request", "Failed to parse request") catch return;
        defer alloc.free(err_resp);
        stream.writeAll(err_resp) catch {};
        stream.writeAll("\n") catch {};
        return;
    };
    defer req.deinit(alloc);

    // Dispatch to handler
    const response = handlers.dispatch(alloc, self, &req) catch |err| {
        const err_resp = protocol.errorResponse(alloc, req.id, "internal_error", @errorName(err)) catch return;
        defer alloc.free(err_resp);
        stream.writeAll(err_resp) catch {};
        stream.writeAll("\n") catch {};
        return;
    };
    defer alloc.free(response);

    stream.writeAll(response) catch {};
    stream.writeAll("\n") catch {};
}
