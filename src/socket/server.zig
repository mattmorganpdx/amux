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
        var buf: [256]u8 = undefined;
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
    self.stop();
    self.claude_session_store.deinit();
    self.registry.deinit();
    self.alloc.free(self.socket_path);
    self.alloc.destroy(self);
}

/// Start the socket server in a background thread.
pub fn start(self: *Server) !void {
    // Clean up stale socket
    std.fs.deleteFileAbsolute(self.socket_path) catch {};

    // Create Unix domain socket
    const addr = try std.net.Address.initUnix(self.socket_path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 5);

    self.listen_fd = fd;
    self.running.store(true, .release);

    log.info("Socket server listening on {s}", .{self.socket_path});

    // Spawn accept thread
    self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
}

pub fn stop(self: *Server) void {
    self.running.store(false, .release);
    if (self.listen_fd) |fd| {
        posix.close(fd);
        self.listen_fd = null;
    }
    if (self.accept_thread) |thread| {
        thread.join();
        self.accept_thread = null;
    }
    // Clean up socket file
    std.fs.deleteFileAbsolute(self.socket_path) catch {};
}

fn acceptLoop(self: *Server) void {
    while (self.running.load(.acquire)) {
        const client = posix.accept(self.listen_fd orelse break, null, null, 0) catch |err| {
            if (!self.running.load(.acquire)) break;
            log.warn("Accept error: {}", .{err});
            continue;
        };

        // Spawn a thread to handle this client
        _ = std.Thread.spawn(.{}, handleClient, .{ self, client }) catch |err| {
            log.warn("Failed to spawn client thread: {}", .{err});
            posix.close(client);
        };
    }
}

fn handleClient(self: *Server, client_fd: posix.socket_t) void {
    defer posix.close(client_fd);

    const stream = std.net.Stream{ .handle = client_fd };
    var buf: [8192]u8 = undefined;
    var leftover: usize = 0;

    while (self.running.load(.acquire)) {
        // Read data
        const n = stream.read(buf[leftover..]) catch break;
        if (n == 0) break; // Client disconnected

        const total = leftover + n;

        // Process complete lines
        var line_start: usize = 0;
        for (0..total) |i| {
            if (buf[i] == '\n') {
                const line = buf[line_start..i];
                if (line.len > 0) {
                    self.processRequest(stream, line);
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
