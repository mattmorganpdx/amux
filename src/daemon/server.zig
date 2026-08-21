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
    std.fs.deleteFileAbsolute(self.socket_path) catch {};

    const addr = try std.net.Address.initUnix(self.socket_path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    // 0600, applied atomically by bind() rather than chmod()ed afterwards.
    {
        const prev = std.c.umask(0o177);
        defer _ = std.c.umask(prev);
        try posix.bind(fd, &addr.any, addr.getOsSockLen());
    }
    try posix.listen(fd, 16);

    self.listen_fd = fd;
    self.running.store(true, .release);
    self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});

    log.info("listening on {s}", .{self.socket_path});
}

/// Returns false if the drain timed out with handlers still running.
pub fn stop(self: *Server) bool {
    if (!self.running.swap(false, .acq_rel)) return true;

    if (self.listen_fd) |fd| {
        posix.shutdown(fd, .both) catch {};
        posix.close(fd);
        self.listen_fd = null;
    }
    if (self.accept_thread) |t| {
        t.join();
        self.accept_thread = null;
    }

    const drained = self.drainClients();
    std.fs.deleteFileAbsolute(self.socket_path) catch {};
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

fn acceptLoop(self: *Server) void {
    const listen_fd = self.listen_fd orelse return;

    while (self.running.load(.acquire)) {
        const client = posix.accept(listen_fd, null, null, 0) catch |err| {
            if (!self.running.load(.acquire)) break;
            log.warn("accept error: {}", .{err});
            continue;
        };
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
