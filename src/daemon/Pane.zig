//! One terminal the daemon owns: a pty with a child process, and the terminal
//! state its output is parsed into.
//!
//! No renderer and no GL. A pane exists and keeps running whether or not
//! anything is attached to look at it, which is the whole point of the daemon.

const std = @import("std");
const vt = @import("vt");
const Pty = @import("Pty.zig");

const Pane = @This();

const log = std.log.scoped(.pane);

/// The handler type `Terminal.vtHandler()` returns. Named this way because
/// `ghostty-vt` does not re-export `ReadonlyStream` directly, but the type is
/// reachable through the method's signature.
const Handler = @typeInfo(@TypeOf(vt.Terminal.vtHandler)).@"fn".return_type.?;

/// A VT stream that applies actions to a Terminal, ignoring anything that would
/// need a reply. Upstream recommends it for exactly this: driving terminal
/// state from a byte stream you are not interactively answering.
const Stream = vt.Stream(Handler);

/// How much pty output to take per read.
const read_chunk_bytes = 4096;

/// Scrollback retained per pane, in lines.
const default_scrollback_lines = 10_000;

alloc: std.mem.Allocator,
id: u64,
pty: Pty,

/// Terminal state. Guarded by `mutex`: the reader thread writes it, callers
/// read it.
terminal: vt.Terminal,
stream: Stream,
mutex: std.Thread.Mutex = .{},

reader: ?std.Thread = null,
running: std.atomic.Value(bool) = .init(false),

/// True once the child has exited and the pty reached EOF.
exited: std.atomic.Value(bool) = .init(false),

pub const Options = struct {
    argv: []const []const u8,
    env: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    cols: u16 = 80,
    rows: u16 = 24,
    scrollback: usize = default_scrollback_lines,
};

/// Heap-allocated because the stream handler holds a pointer to `terminal`,
/// so the pane's address has to be stable.
pub fn create(alloc: std.mem.Allocator, id: u64, opts: Options) !*Pane {
    const self = try alloc.create(Pane);
    errdefer alloc.destroy(self);

    var term = try vt.Terminal.init(alloc, .{
        .cols = opts.cols,
        .rows = opts.rows,
        .max_scrollback = opts.scrollback,
    });
    errdefer term.deinit(alloc);

    var pty = try Pty.spawn(alloc, opts.argv, opts.env, opts.cwd, .{
        .cols = opts.cols,
        .rows = opts.rows,
    });
    errdefer pty.deinit();

    self.* = .{
        .alloc = alloc,
        .id = id,
        .pty = pty,
        .terminal = term,
        // Patched below: the handler needs the final address of `terminal`.
        .stream = undefined,
    };
    self.stream = .{
        .handler = self.terminal.vtHandler(),
        .parser = .init(),
        .utf8decoder = .{},
    };

    self.running.store(true, .release);
    self.reader = try std.Thread.spawn(.{}, readLoop, .{self});

    return self;
}

pub fn destroy(self: *Pane) void {
    self.running.store(false, .release);

    // Closing the pty is what unblocks the reader thread's read().
    self.pty.deinit();
    if (self.reader) |thread| {
        thread.join();
        self.reader = null;
    }

    self.terminal.deinit(self.alloc);
    const alloc = self.alloc;
    alloc.destroy(self);
}

/// Send bytes to the child's stdin.
pub fn write(self: *Pane, bytes: []const u8) !void {
    try self.pty.writeAll(bytes);
}

/// The visible screen as text.
pub fn snapshot(self: *Pane, alloc: std.mem.Allocator) ![]const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.terminal.screens.active.dumpStringAlloc(alloc, .{ .active = .{} });
}

/// The visible screen plus everything still in scrollback.
pub fn snapshotScrollback(self: *Pane, alloc: std.mem.Allocator) ![]const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.terminal.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
}

pub fn resize(self: *Pane, cols: u16, rows: u16) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.terminal.resize(self.alloc, cols, rows);
    try self.pty.resize(.{ .cols = cols, .rows = rows });
}

pub fn hasExited(self: *const Pane) bool {
    return self.exited.load(.acquire);
}

/// Pumps pty output into the terminal until EOF or shutdown.
fn readLoop(self: *Pane) void {
    var buf: [read_chunk_bytes]u8 = undefined;
    while (self.running.load(.acquire)) {
        const n = self.pty.read(&buf) catch |err| {
            log.debug("pane {d}: read ended: {}", .{ self.id, err });
            break;
        };
        if (n == 0) break; // child exited

        self.mutex.lock();
        defer self.mutex.unlock();
        self.stream.nextSlice(buf[0..n]) catch |err| {
            // A malformed sequence should cost us that sequence, not the pane.
            log.warn("pane {d}: stream error: {}", .{ self.id, err });
        };
    }
    self.exited.store(true, .release);
    log.debug("pane {d}: reader finished", .{self.id});
}

/// Poll `snapshot` until `needle` appears, or give up. Spawned shells are
/// asynchronous, so tests must wait on content rather than on a fixed sleep.
fn expectOnScreen(self: *Pane, alloc: std.mem.Allocator, needle: []const u8, timeout_ms: usize) !void {
    var waited: usize = 0;
    while (waited < timeout_ms) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
        waited += 50;
        const screen = try self.snapshot(alloc);
        defer alloc.free(screen);
        if (std.mem.indexOf(u8, screen, needle) != null) return;
    }
    const screen = try self.snapshot(alloc);
    defer alloc.free(screen);
    std.debug.print("\nnever saw \"{s}\" in {d}ms; screen was:\n{s}\n", .{ needle, timeout_ms, screen });
    return error.NeedleNotFound;
}

test "hosts a shell and parses its output into terminal state" {
    const alloc = std.testing.allocator;

    const pane = try create(alloc, 1, .{
        .argv = &.{ "/bin/sh", "-i" },
        .env = &.{ "TERM=xterm-256color", "PS1=$ " },
    });
    defer pane.destroy();

    try pane.write("echo pane_hosting_works\n");
    try pane.expectOnScreen(alloc, "pane_hosting_works", 5000);
}

test "escape sequences are interpreted, not echoed literally" {
    const alloc = std.testing.allocator;

    const pane = try create(alloc, 2, .{
        .argv = &.{ "/bin/sh", "-i" },
        .env = &.{ "TERM=xterm-256color", "PS1=$ " },
    });
    defer pane.destroy();

    // Colour codes around the word. If the stream were passing bytes through
    // rather than parsing them, the escape bytes would appear on the screen.
    try pane.write("printf '\\033[31mRED_TEXT\\033[0m\\n'\n");
    try pane.expectOnScreen(alloc, "RED_TEXT", 5000);

    // The parsed screen holds text, not control bytes. Checking for the ESC
    // byte itself rather than "[31m": an interactive shell echoes the command
    // line back, and what we typed literally contains those characters.
    const screen = try pane.snapshot(alloc);
    defer alloc.free(screen);
    try std.testing.expect(std.mem.indexOfScalar(u8, screen, 0x1b) == null);
}

test "output scrolled off the screen stays in scrollback" {
    const alloc = std.testing.allocator;

    const pane = try create(alloc, 3, .{
        .argv = &.{ "/bin/sh", "-i" },
        .env = &.{ "TERM=xterm-256color", "PS1=$ " },
        .rows = 5,
        .cols = 40,
    });
    defer pane.destroy();

    try pane.write("for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo scrollline$i; done\n");
    try pane.expectOnScreen(alloc, "scrollline12", 5000);

    const active = try pane.snapshot(alloc);
    defer alloc.free(active);
    try std.testing.expect(std.mem.indexOf(u8, active, "scrollline1\n") == null);

    const all = try pane.snapshotScrollback(alloc);
    defer alloc.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "scrollline1") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "scrollline12") != null);
}

test "notices when its child exits" {
    const alloc = std.testing.allocator;

    const pane = try create(alloc, 4, .{ .argv = &.{ "/bin/sh", "-c", "echo bye" } });
    defer pane.destroy();

    var waited: usize = 0;
    while (waited < 5000 and !pane.hasExited()) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
        waited += 50;
    }
    try std.testing.expect(pane.hasExited());
}
