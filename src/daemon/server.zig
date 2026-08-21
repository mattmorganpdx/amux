//! The daemon's socket front door.
//!
//! Written fresh rather than shared with `src/socket/server.zig`, because that
//! one is still serving the GUI until item 6 turns the GUI into a client, at
//! which point it goes away. Every hardening lesson from it is carried over
//! deliberately, and each is noted where it applies:
//!
//!   - the socket is created 0600 by setting the umask around bind(), which is
//!     atomic where a later chmod() would leave a window open
//!   - client threads are detached, or they never release their stacks
//!   - a request line longer than the cap is drained and refused, not parsed
//!     in pieces
//!   - shutdown wakes threads parked in read() and waits for them, because a
//!     handler still holds a pointer to State
//!   - shutdown() the listener before close(), or a blocked accept() never
//!     returns and the accept thread cannot be joined

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const handlers = @import("handlers.zig");
const protocol = @import("../socket/protocol.zig");
const State = @import("State.zig");

const Server = @This();

const log = std.log.scoped(.daemon_server);

/// Longest request line accepted.
const max_request_bytes: usize = 8192;

/// How long shutdown waits for in-flight handlers.
const drain_timeout_ns: u64 = 5 * std.time.ns_per_s;

alloc: Allocator,
state: *State,
socket_path: []const u8,
listen_fd: ?posix.socket_t = null,
running: std.atomic.Value(bool) = .init(false),
accept_thread: ?std.Thread = null,

client_mutex: std.Thread.Mutex = .{},
client_drained: std.Thread.Condition = .{},
clients: std.AutoHashMapUnmanaged(posix.socket_t, void) = .{},
active_clients: usize = 0,

/// True when systemd handed us the listening socket. Changes two things: we
/// must not bind (it is already listening), and we must not delete the socket
/// file, because systemd owns its lifetime.
socket_activated: bool = false,

pub fn init(alloc: Allocator, state: *State, socket_path: []const u8) !*Server {
    const self = try alloc.create(Server);
    self.* = .{
        .alloc = alloc,
        .state = state,
        .socket_path = try alloc.dupe(u8, socket_path),
    };
    return self;
}

pub fn deinit(self: *Server) void {
    const drained = self.stop();
    if (!drained) {
        log.warn("skipping teardown: client handlers still active", .{});
        return;
    }
    self.clients.deinit(self.alloc);
    self.alloc.free(self.socket_path);
    self.alloc.destroy(self);
}

pub fn start(self: *Server) !void {
    const fd = if (inheritedSocket()) |inherited| blk: {
        self.socket_activated = true;
        log.info("using socket-activated listener from systemd", .{});
        break :blk inherited;
    } else try self.bindOwnSocket();

    // Keep the listener out of the shells we spawn. Without this every pane's
    // child inherits it, which both leaks a descriptor per pane and keeps the
    // socket alive if the daemon dies.
    setCloexec(fd);

    self.listen_fd = fd;
    self.running.store(true, .release);
    self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});

    log.info("listening on {s}", .{self.socket_path});
}

/// The sd_listen_fds handshake, without linking libsystemd.
///
/// systemd sets LISTEN_PID to the pid it activated and LISTEN_FDS to the count,
/// with the descriptors starting at 3. The variables are cleared afterwards so
/// the shells we spawn do not inherit them and mistake themselves for
/// socket-activated services.
fn inheritedSocket() ?posix.socket_t {
    const listen_pid = posix.getenv("LISTEN_PID") orelse return null;
    const listen_fds = posix.getenv("LISTEN_FDS") orelse return null;

    const pid = std.fmt.parseInt(std.posix.pid_t, listen_pid, 10) catch return null;
    const count = std.fmt.parseInt(u32, listen_fds, 10) catch return null;

    // Not meant for us: an ancestor was activated and we merely inherited the
    // environment.
    if (pid != std.os.linux.getpid()) return null;
    if (count < 1) return null;
    if (count > 1) log.warn("systemd passed {d} sockets; using the first", .{count});

    _ = unsetenv("LISTEN_PID");
    _ = unsetenv("LISTEN_FDS");
    _ = unsetenv("LISTEN_FDNAMES");

    // SD_LISTEN_FDS_START
    return 3;
}

fn bindOwnSocket(self: *Server) !posix.socket_t {
    std.fs.deleteFileAbsolute(self.socket_path) catch {};

    const addr = try std.net.Address.initUnix(self.socket_path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    // 0600, applied atomically by bind() rather than chmod()ed afterwards.
    // Under socket activation this is systemd's job instead: SocketMode=0600.
    {
        const prev = std.c.umask(0o177);
        defer _ = std.c.umask(prev);
        try posix.bind(fd, &addr.any, addr.getOsSockLen());
    }
    try posix.listen(fd, 16);
    return fd;
}

extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn setCloexec(fd: posix.fd_t) void {
    const flags = posix.fcntl(fd, posix.F.GETFD, 0) catch return;
    _ = posix.fcntl(fd, posix.F.SETFD, flags | @as(usize, std.posix.FD_CLOEXEC)) catch {};
}

/// Returns false if the drain timed out with handlers still running.
pub fn stop(self: *Server) bool {
    if (!self.running.swap(false, .acq_rel)) return true;

    // Join before closing the listener. The accept loop polls with a timeout so
    // it returns on its own once `running` is false; closing the descriptor
    // first leaves it able to call accept() on a closed fd, and std maps that
    // EBADF to `unreachable` -- which panicked the daemon on shutdown.
    if (self.accept_thread) |t| {
        t.join();
        self.accept_thread = null;
    }
    if (self.listen_fd) |fd| {
        // Only shut down a socket we created. Under socket activation systemd
        // owns this socket and hands the *same* one to the next start, so
        // shutdown() breaks it permanently -- every later accept() then fails
        // with SocketNotListening.
        if (!self.socket_activated) posix.shutdown(fd, .both) catch {};
        posix.close(fd);
        self.listen_fd = null;
    }

    const drained = self.drainClients();
    // Only ours to remove if we created it; systemd cleans up its own.
    if (!self.socket_activated) std.fs.deleteFileAbsolute(self.socket_path) catch {};
    return drained;
}

fn drainClients(self: *Server) bool {
    self.client_mutex.lock();
    defer self.client_mutex.unlock();

    var it = self.clients.keyIterator();
    while (it.next()) |fd| posix.shutdown(fd.*, .both) catch {};

    var timer = std.time.Timer.start() catch return self.active_clients == 0;
    while (self.active_clients > 0) {
        const elapsed = timer.read();
        if (elapsed >= drain_timeout_ns) {
            log.warn("drain timed out with {d} handler(s) running", .{self.active_clients});
            return false;
        }
        self.client_drained.timedWait(&self.client_mutex, drain_timeout_ns - elapsed) catch {};
    }
    return true;
}

/// Give up after this many consecutive accept failures. A listener that keeps
/// erroring will not fix itself, and retrying in a tight loop burns a core and
/// floods the journal -- which is exactly what a permanently shut-down socket
/// did before the fix above.
const max_consecutive_accept_errors = 16;

fn acceptLoop(self: *Server) void {
    const listen_fd = self.listen_fd orelse return;
    var consecutive_errors: usize = 0;

    while (self.running.load(.acquire)) {
        // Wait for a connection with a timeout rather than blocking forever, so
        // shutdown is noticed without having to break the listening socket.
        var poll_fds = [_]posix.pollfd{.{
            .fd = listen_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(&poll_fds, 200) catch |err| {
            if (!self.running.load(.acquire)) break;
            log.warn("poll error: {}", .{err});
            consecutive_errors += 1;
            if (consecutive_errors >= max_consecutive_accept_errors) break;
            continue;
        };
        if (ready == 0) continue;

        const client = posix.accept(listen_fd, null, null, posix.SOCK.CLOEXEC) catch |err| {
            if (!self.running.load(.acquire)) break;
            consecutive_errors += 1;
            if (consecutive_errors >= max_consecutive_accept_errors) {
                log.err("giving up after {d} consecutive accept errors, last: {}", .{
                    consecutive_errors, err,
                });
                break;
            }
            log.warn("accept error: {}", .{err});
            continue;
        };
        consecutive_errors = 0;
        if (!self.running.load(.acquire)) {
            posix.close(client);
            break;
        }

        // Registered before the thread starts, so a concurrent stop() cannot
        // miss a client still being spawned.
        if (!self.registerClient(client)) {
            posix.close(client);
            continue;
        }
        const thread = std.Thread.spawn(.{}, handleClient, .{ self, client }) catch |err| {
            log.warn("failed to spawn client thread: {}", .{err});
            self.unregisterClient(client);
            posix.close(client);
            continue;
        };
        thread.detach();
    }
}

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

fn handleClient(self: *Server, fd: posix.socket_t) void {
    defer {
        self.unregisterClient(fd);
        posix.close(fd);
    }

    const stream = std.net.Stream{ .handle = fd };
    var buf: [max_request_bytes]u8 = undefined;
    var leftover: usize = 0;
    var overflow = false;

    while (self.running.load(.acquire)) {
        if (leftover >= buf.len) {
            overflow = true;
            leftover = 0;
        }

        const n = stream.read(buf[leftover..]) catch break;
        if (n == 0) break;
        const total = leftover + n;

        var line_start: usize = 0;
        for (0..total) |i| {
            if (buf[i] != '\n') continue;
            if (overflow) {
                overflow = false;
                self.reply(stream, protocol.errorResponse(
                    self.alloc,
                    0,
                    "request_too_large",
                    "Request exceeds the maximum size",
                ));
            } else if (i > line_start) {
                self.processRequest(stream, buf[line_start..i]);
            }
            line_start = i + 1;
        }

        if (line_start < total) {
            std.mem.copyForwards(u8, &buf, buf[line_start..total]);
            leftover = total - line_start;
        } else leftover = 0;
    }
}

fn processRequest(self: *Server, stream: std.net.Stream, line: []const u8) void {
    var req = protocol.Request.parse(self.alloc, line) catch {
        self.reply(stream, protocol.errorResponse(self.alloc, 0, "invalid_request", "Failed to parse request"));
        return;
    };
    defer req.deinit(self.alloc);

    const response = handlers.dispatch(self.alloc, self.state, &req) catch |err| {
        self.reply(stream, protocol.errorResponse(self.alloc, req.id, "internal_error", @errorName(err)));
        return;
    };
    defer self.alloc.free(response);

    stream.writeAll(response) catch {};
    stream.writeAll("\n") catch {};
}

fn reply(self: *Server, stream: std.net.Stream, maybe: anytype) void {
    const body = maybe catch return;
    defer self.alloc.free(body);
    stream.writeAll(body) catch {};
    stream.writeAll("\n") catch {};
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

test "socket activation is ignored unless LISTEN_PID names this process" {
    // A process whose ancestor was socket-activated inherits these variables.
    // Adopting fd 3 in that case would take whatever descriptor happens to be
    // there, which is not a listening socket.
    _ = setenv("LISTEN_PID", "1", 1);
    _ = setenv("LISTEN_FDS", "1", 1);
    defer {
        _ = unsetenv("LISTEN_PID");
        _ = unsetenv("LISTEN_FDS");
    }
    try std.testing.expect(inheritedSocket() == null);
}

test "socket activation is ignored when no descriptors were passed" {
    var pid_buf: [24]u8 = undefined;
    const pid_str = try std.fmt.bufPrintZ(&pid_buf, "{d}", .{std.os.linux.getpid()});
    _ = setenv("LISTEN_PID", pid_str, 1);
    _ = setenv("LISTEN_FDS", "0", 1);
    defer {
        _ = unsetenv("LISTEN_PID");
        _ = unsetenv("LISTEN_FDS");
    }
    try std.testing.expect(inheritedSocket() == null);
}

test "a bound socket is 0600 and is removed on stop" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/amux-servertest-{d}.sock", .{
        std.os.linux.getpid(),
    });
    std.fs.deleteFileAbsolute(path) catch {};

    const server = try init(alloc, &state, path);
    try server.start();

    const st = try std.fs.cwd().statFile(path);
    // Anyone who can connect can drive every terminal the daemon owns.
    try std.testing.expectEqual(@as(u16, 0o600), @as(u16, @intCast(st.mode & 0o777)));
    try std.testing.expect(!server.socket_activated);

    server.deinit();
    // We created it, so we clean it up.
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(path));
}

test "stopping while a client is connecting does not abort the daemon" {
    // Regression: stop() used to close the listening descriptor before joining
    // the accept thread. A client arriving in that window left accept() running
    // on a closed fd, and std maps EBADF to `unreachable` -- so shutdown
    // panicked the whole daemon instead of exiting. Connect right as we stop,
    // repeatedly, to land inside the window.
    const alloc = std.testing.allocator;

    var round: usize = 0;
    while (round < 12) : (round += 1) {
        var state = State.init(alloc);
        defer state.deinit();

        var path_buf: [80]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/amux-racetest-{d}-{d}.sock", .{
            std.os.linux.getpid(), round,
        });
        std.fs.deleteFileAbsolute(path) catch {};

        const server = try init(alloc, &state, path);
        defer server.deinit();
        try server.start();

        // Fire a connection and tear down without waiting for it to be served.
        const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        var addr = std.net.Address.initUnix(path) catch unreachable;
        posix.connect(sock, &addr.any, addr.getOsSockLen()) catch {};
        _ = server.stop();
        posix.close(sock);
    }
}
