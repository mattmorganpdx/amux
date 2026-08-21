//! The GUI's connection to `amuxd`.
//!
//! The daemon owns the terminals; this is how the GUI finds out what they are.
//! Deliberately small and blocking: the calls here are either made once at
//! startup or in response to something the user did, so simplicity is worth more
//! than throughput. The one long-running caller is the layout watcher, which
//! gets its own thread.

const std = @import("std");
const posix = std.posix;
const net = std.net;

const log = std.log.scoped(.daemon_client);

const max_response_bytes = 8 * 1024 * 1024;
const chunk_bytes = 64 * 1024;

/// Where to look for a daemon, in order.
///
/// `AMUX_DAEMON_SOCKET` is separate from `AMUX_SOCKET` on purpose: the GUI still
/// runs a socket server of its own, and `AMUX_SOCKET` is what *that* binds. One
/// variable for both would have the GUI connect to itself.
pub fn discover(alloc: std.mem.Allocator, own_socket: ?[]const u8) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    if (posix.getenv("AMUX_DAEMON_SOCKET")) |p| {
        if (isDaemon(alloc, p)) return alloc.dupe(u8, p) catch null;
        log.warn("AMUX_DAEMON_SOCKET is set but no daemon answered there", .{});
        return null;
    }

    if (posix.getenv("XDG_RUNTIME_DIR")) |dir| {
        if (std.fmt.bufPrint(&buf, "{s}/amux.sock", .{dir})) |p| {
            if (!sameSocket(p, own_socket) and isDaemon(alloc, p)) return alloc.dupe(u8, p) catch null;
        } else |_| {}
    }

    const fallback = "/tmp/amux.sock";
    if (!sameSocket(fallback, own_socket) and isDaemon(alloc, fallback)) {
        return alloc.dupe(u8, fallback) catch null;
    }
    return null;
}

fn sameSocket(a: []const u8, b: ?[]const u8) bool {
    const other = b orelse return false;
    return std.mem.eql(u8, a, other);
}

/// True if something at this path answers and says it is a daemon.
///
/// Asking rather than assuming: the GUI's own server speaks the same protocol on
/// a similar path, and connecting to it would leave the GUI mirroring itself.
fn isDaemon(alloc: std.mem.Allocator, socket_path: []const u8) bool {
    const resp = call(alloc, socket_path, "system.capabilities", "{}") catch return false;
    defer alloc.free(resp);
    return std.mem.indexOf(u8, resp, "\"daemon\":true") != null;
}

/// One request, one response. Caller frees.
pub fn call(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    method: []const u8,
    params: []const u8,
) ![]u8 {
    const addr = try net.Address.initUnix(socket_path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(fd);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());

    const stream = net.Stream{ .handle = fd };

    const req = try std.fmt.allocPrint(alloc,
        \\{{"id":1,"method":"{s}","params":{s}}}
    , .{ method, params });
    defer alloc.free(req);
    try stream.writeAll(req);
    try stream.writeAll("\n");

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(alloc);
    var chunk: [chunk_bytes]u8 = undefined;
    while (true) {
        const n = try stream.read(&chunk);
        if (n == 0) break;
        if (out.items.len + n > max_response_bytes) return error.ResponseTooLarge;
        try out.appendSlice(alloc, chunk[0..n]);
        if (std.mem.indexOfScalar(u8, chunk[0..n], '\n') != null) break;
    }
    return out.toOwnedSlice(alloc);
}

pub const Layout = struct {
    seq: u64,
    /// The session JSON the daemon reported. Caller frees.
    json: []const u8,
};

/// The daemon's layout, or null if nothing changed within `timeout_ms`.
///
/// The body is the same format `session.zig` writes to disk, so the caller can
/// hand it straight to `session.deserializeSession`.
pub fn layout(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    since: u64,
    timeout_ms: u32,
) !?Layout {
    const params = try std.fmt.allocPrint(
        alloc,
        "{{\"since\":{d},\"timeout_ms\":{d}}}",
        .{ since, timeout_ms },
    );
    defer alloc.free(params);

    const resp = try call(alloc, socket_path, "system.layout", params);
    defer alloc.free(resp);

    if (std.mem.indexOf(u8, resp, "\"changed\":false") != null) return null;

    const seq = extractUint(resp, "seq") orelse return error.BadResponse;

    // Slice the layout object straight out of the response rather than parsing
    // and re-serializing it: `session.deserializeSession` wants JSON text, and
    // it already knows this schema. Parsing here would mean a second
    // description of it to keep in step.
    const body = extractObject(resp, "layout") orelse return error.BadResponse;

    return .{ .seq = seq, .json = try alloc.dupe(u8, body) };
}

/// The integer value of `"key":N`, ignoring anything inside strings.
fn extractUint(text: []const u8, key: []const u8) ?u64 {
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, text, pat) orelse return null;
    var i = at + pat.len;
    while (i < text.len and text[i] == ' ') i += 1;
    const start = i;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(u64, text[start..i], 10) catch null;
}

/// The `{...}` value of `"key":` , matching braces and skipping string contents
/// so a brace inside a workspace title cannot end the object early.
fn extractObject(text: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, text, pat) orelse return null;

    var i = at + pat.len;
    while (i < text.len and text[i] == ' ') i += 1;
    if (i >= text.len or text[i] != '{') return null;

    const start = i;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return text[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

/// Ask the daemon to split a pane, returning the new pane's id.
pub fn splitPane(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    pane_id: u64,
    direction: []const u8,
) !u64 {
    const params = try std.fmt.allocPrint(
        alloc,
        "{{\"surface_id\":{d},\"direction\":\"{s}\"}}",
        .{ pane_id, direction },
    );
    defer alloc.free(params);
    const resp = try call(alloc, socket_path, "surface.split", params);
    defer alloc.free(resp);
    if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return error.SplitFailed;
    return extractUint(resp, "surface_id") orelse error.SplitFailed;
}

pub fn closePane(alloc: std.mem.Allocator, socket_path: []const u8, pane_id: u64) !void {
    const params = try std.fmt.allocPrint(alloc, "{{\"surface_id\":{d}}}", .{pane_id});
    defer alloc.free(params);
    const resp = try call(alloc, socket_path, "surface.close", params);
    defer alloc.free(resp);
    if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return error.CloseFailed;
}

pub fn createWorkspace(alloc: std.mem.Allocator, socket_path: []const u8) !void {
    const resp = try call(alloc, socket_path, "workspace.create", "{}");
    defer alloc.free(resp);
    if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return error.CreateFailed;
}

pub fn selectWorkspace(alloc: std.mem.Allocator, socket_path: []const u8, ws_id: u64) !void {
    const params = try std.fmt.allocPrint(alloc, "{{\"workspace_id\":{d}}}", .{ws_id});
    defer alloc.free(params);
    const resp = try call(alloc, socket_path, "workspace.select", params);
    defer alloc.free(resp);
    if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return error.SelectFailed;
}

pub fn closeWorkspace(alloc: std.mem.Allocator, socket_path: []const u8, ws_id: u64) !void {
    const params = try std.fmt.allocPrint(alloc, "{{\"workspace_id\":{d}}}", .{ws_id});
    defer alloc.free(params);
    const resp = try call(alloc, socket_path, "workspace.close", params);
    defer alloc.free(resp);
    if (std.mem.indexOf(u8, resp, "\"ok\":true") == null) return error.CloseFailed;
}

/// The `amux-cli` next to this binary, so a relay runs the matching build
/// rather than whatever is first on PATH.
pub fn cliPath(buf: []u8) ?[]const u8 {
    const exe = std.fs.selfExePath(buf) catch return null;
    const dir = std.fs.path.dirname(exe) orelse return null;
    // Rewrite in place: dirname is a prefix of what selfExePath wrote.
    const candidate = std.fmt.bufPrint(buf[dir.len..], "/amux-cli", .{}) catch return null;
    const full = buf[0 .. dir.len + candidate.len];
    std.fs.cwd().access(full, .{}) catch return null;
    return full;
}
