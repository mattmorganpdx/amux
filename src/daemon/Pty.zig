//! A pseudoterminal with a child process on the far end.
//!
//! Deliberately knows nothing about VT parsing or terminal state: it moves
//! bytes and owns the child's lifetime. `Pane` puts a terminal on top.

const std = @import("std");
const posix = std.posix;

const Pty = @This();

const log = std.log.scoped(.pty);

/// Master side. Read child output from it, write input to it.
master: posix.fd_t,

/// The child process.
pid: posix.pid_t,

/// Current size, kept so a resize can be compared against it.
size: Size,

pub const Size = struct {
    cols: u16,
    rows: u16,
};

pub const SpawnError = error{
    ForkptyFailed,
    ExecFailed,
    OutOfMemory,
};

// glibc >= 2.34 has these in libc proper rather than libutil.
extern "c" fn forkpty(
    amaster: *c_int,
    name: ?[*]u8,
    termp: ?*anyopaque,
    winp: ?*const posix.winsize,
) c_int;

/// Spawn `argv` on a new pty.
///
/// `env` entries are `KEY=VALUE`, appended to the parent's environment. `cwd`,
/// when given, becomes the child's working directory.
pub fn spawn(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    env: []const []const u8,
    cwd: ?[]const u8,
    size: Size,
) !Pty {
    std.debug.assert(argv.len > 0);

    // Everything the child needs must be built before forking: after fork only
    // async-signal-safe calls are legal, and allocating is not one of them.
    const argv_z = try allocArgv(alloc, argv);
    defer freeArgv(alloc, argv_z);
    const envp_z = try allocEnv(alloc, env);
    defer freeArgv(alloc, envp_z);
    const cwd_z: ?[:0]u8 = if (cwd) |c| try alloc.dupeZ(u8, c) else null;
    defer if (cwd_z) |c| alloc.free(c);

    const ws: posix.winsize = .{
        .col = size.cols,
        .row = size.rows,
        .xpixel = 0,
        .ypixel = 0,
    };

    var master: c_int = -1;
    const pid = forkpty(&master, null, null, &ws);
    if (pid < 0) return error.ForkptyFailed;

    if (pid == 0) {
        // Child. forkpty has already done setsid, TIOCSCTTY and the dup2s onto
        // 0/1/2, so only the cwd and the exec are left.
        if (cwd_z) |c| posix.chdirZ(c) catch {};
        posix.execvpeZ(argv_z[0].?, @ptrCast(argv_z.ptr), @ptrCast(envp_z.ptr)) catch {};
        // exec failed and there is nothing safe left to do.
        posix.exit(127);
    }

    log.info("spawned pid={d} on pty master={d} size={d}x{d}", .{
        pid, master, size.cols, size.rows,
    });

    return .{
        .master = master,
        .pid = @intCast(pid),
        .size = size,
    };
}

/// Read child output. Returns 0 at EOF (the child closed its side or exited).
pub fn read(self: *const Pty, buf: []u8) !usize {
    return posix.read(self.master, buf) catch |err| switch (err) {
        // The child exited and its slave side is gone: EOF, not a failure.
        error.InputOutput => 0,
        else => err,
    };
}

/// Write to the child's stdin. Loops until everything is written.
pub fn writeAll(self: *const Pty, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        index += try posix.write(self.master, bytes[index..]);
    }
}

pub fn resize(self: *Pty, size: Size) !void {
    if (size.cols == self.size.cols and size.rows == self.size.rows) return;
    const ws: posix.winsize = .{
        .col = size.cols,
        .row = size.rows,
        .xpixel = 0,
        .ypixel = 0,
    };
    switch (posix.errno(std.c.ioctl(self.master, posix.T.IOCSWINSZ, &ws))) {
        .SUCCESS => {},
        else => return error.ResizeFailed,
    }
    self.size = size;
}

/// Terminate the child and reap it. Safe to call more than once.
pub fn deinit(self: *Pty) void {
    if (self.pid > 0) {
        posix.kill(self.pid, posix.SIG.HUP) catch {};
        // SIGHUP is the polite version; the shell usually goes on its own.
        _ = posix.waitpid(self.pid, 0);
        self.pid = -1;
    }
    if (self.master >= 0) {
        posix.close(self.master);
        self.master = -1;
    }
}

fn allocArgv(alloc: std.mem.Allocator, argv: []const []const u8) ![]?[*:0]u8 {
    const out = try alloc.alloc(?[*:0]u8, argv.len + 1);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |v| if (v) |p| alloc.free(std.mem.span(p));
        alloc.free(out);
    }
    for (argv, 0..) |arg, i| {
        out[i] = (try alloc.dupeZ(u8, arg)).ptr;
        filled = i + 1;
    }
    out[argv.len] = null;
    return out;
}

/// Parent environment plus `extra`, as a null-terminated envp.
fn allocEnv(alloc: std.mem.Allocator, extra: []const []const u8) ![]?[*:0]u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .{};
    defer list.deinit(alloc);

    var it = std.process.getEnvMap(alloc) catch return error.OutOfMemory;
    defer it.deinit();

    var entries: std.ArrayListUnmanaged([]u8) = .{};
    defer {
        for (entries.items) |e| alloc.free(e);
        entries.deinit(alloc);
    }

    var map_it = it.iterator();
    while (map_it.next()) |kv| {
        // Anything in `extra` wins over the inherited value.
        if (overrides(extra, kv.key_ptr.*)) continue;
        const joined = try std.fmt.allocPrint(alloc, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.* });
        try entries.append(alloc, joined);
        try list.append(alloc, joined);
    }
    for (extra) |e| try list.append(alloc, e);

    return allocArgv(alloc, list.items);
}

fn overrides(extra: []const []const u8, key: []const u8) bool {
    for (extra) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
        if (std.mem.eql(u8, e[0..eq], key)) return true;
    }
    return false;
}

fn freeArgv(alloc: std.mem.Allocator, argv: []?[*:0]u8) void {
    for (argv) |v| if (v) |p| alloc.free(std.mem.span(p));
    alloc.free(argv);
}

test "spawns a child, streams its output, then reports EOF" {
    const alloc = std.testing.allocator;

    var pty = try spawn(
        alloc,
        &.{ "/bin/echo", "pty_round_trip" },
        &.{},
        null,
        .{ .cols = 80, .rows = 24 },
    );
    defer pty.deinit();

    // Read until the marker shows up or the child is gone.
    var seen: std.ArrayListUnmanaged(u8) = .{};
    defer seen.deinit(alloc);
    var buf: [256]u8 = undefined;
    while (seen.items.len < 4096) {
        const n = try pty.read(&buf);
        if (n == 0) break; // EOF: the child exited
        try seen.appendSlice(alloc, buf[0..n]);
        if (std.mem.indexOf(u8, seen.items, "pty_round_trip") != null) break;
    }

    try std.testing.expect(std.mem.indexOf(u8, seen.items, "pty_round_trip") != null);
}

test "child sees the environment it was given" {
    const alloc = std.testing.allocator;

    var pty = try spawn(
        alloc,
        &.{ "/bin/sh", "-c", "printf %s \"$AMUX_TEST_VAR\"" },
        &.{"AMUX_TEST_VAR=from_the_daemon"},
        null,
        .{ .cols = 80, .rows = 24 },
    );
    defer pty.deinit();

    var seen: std.ArrayListUnmanaged(u8) = .{};
    defer seen.deinit(alloc);
    var buf: [256]u8 = undefined;
    while (seen.items.len < 4096) {
        const n = try pty.read(&buf);
        if (n == 0) break;
        try seen.appendSlice(alloc, buf[0..n]);
        if (std.mem.indexOf(u8, seen.items, "from_the_daemon") != null) break;
    }

    try std.testing.expect(std.mem.indexOf(u8, seen.items, "from_the_daemon") != null);
}

test "child starts in the requested working directory" {
    const alloc = std.testing.allocator;

    var pty = try spawn(
        alloc,
        &.{ "/bin/sh", "-c", "pwd" },
        &.{},
        "/tmp",
        .{ .cols = 80, .rows = 24 },
    );
    defer pty.deinit();

    var seen: std.ArrayListUnmanaged(u8) = .{};
    defer seen.deinit(alloc);
    var buf: [256]u8 = undefined;
    while (seen.items.len < 4096) {
        const n = try pty.read(&buf);
        if (n == 0) break;
        try seen.appendSlice(alloc, buf[0..n]);
        if (std.mem.indexOf(u8, seen.items, "/tmp") != null) break;
    }

    try std.testing.expect(std.mem.indexOf(u8, seen.items, "/tmp") != null);
}
