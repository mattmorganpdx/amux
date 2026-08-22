//! One terminal the daemon owns: a pty with a child process, and the terminal
//! state its output is parsed into.
//!
//! No renderer and no GL. A pane exists and keeps running whether or not
//! anything is attached to look at it, which is the whole point of the daemon.

const std = @import("std");
const vt = @import("../vt.zig");
const Pty = @import("Pty.zig");
const screen_json = @import("screen_json.zig");
const vt_paint = @import("vt_paint.zig");
const semantic = @import("semantic.zig");

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

/// How long to hold the first writes while a freshly spawned shell starts up.
///
/// A shell sets up job control before it is ready to read, and bash flushes
/// pending terminal input while doing so -- so bytes written in that window are
/// thrown away with no error anywhere. Anything that creates a pane and
/// immediately sends a command hits this, which is the normal thing for an agent
/// to do, and the symptom is a command that silently never runs.
const spawn_grace_ms = 750;

/// Raw pty output retained per pane, so a client that looked away can replay
/// what it missed rather than being repainted from scratch every time.
///
/// A client that falls further behind than this gets told there is a gap and
/// repaints instead. That is the right failure: the alternative is stalling the
/// terminal until the slowest viewer catches up.
const default_output_ring_bytes = 256 * 1024;

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

/// Ghostty's render-facing view of `terminal`, and the sequence bookkeeping
/// that turns it into something several clients can follow independently.
///
/// `RenderState.update` consumes the terminal's dirty flags, so exactly one of
/// these may exist per terminal -- the pane owns it and nothing else may build
/// one. Its per-row dirty flags are likewise meant for a single renderer that
/// clears them after drawing, so they are folded here into monotonic per-row
/// sequence numbers: a number can be compared by any number of clients at
/// different positions, where a consume-once flag cannot.
render: vt.RenderState = .empty,
row_seq: []u64 = &.{},
seq: u64 = 0,
/// The sequence number of the last change that invalidated the whole screen.
/// A client that last saw something older has to discard what it holds.
full_seq: u64 = 0,

/// Called after pty output has been folded into the terminal, so a waiting
/// client can be woken instead of polling. Invoked with no pane lock held --
/// the registry takes its own lock in here, and holding both would invert the
/// order every request takes.
notify: ?Notify = null,

reader: ?std.Thread = null,
running: std.atomic.Value(bool) = .init(false),

/// True once the child has exited and the pty reached EOF.
exited: std.atomic.Value(bool) = .init(false),

/// Raw pty output, as bytes rather than as parsed screen state. A relay feeds
/// these straight into a terminal of its own, which is why they are kept
/// verbatim: re-encoding parsed state would lose anything the parser normalised.
/// Guarded by `mutex` along with `terminal`.
out_ring: []u8 = &.{},
/// Absolute offset just past the newest byte held.
out_end: u64 = 0,
/// Absolute offset of the oldest byte still held. `out_end - out_start` is how
/// much history is available.
out_start: u64 = 0,

/// Writes held until the child has spoken or the grace period has passed. See
/// `spawn_grace_ms`. Guarded by `mutex`.
pending: std.ArrayListUnmanaged(u8) = .{},
/// True once the child has produced output, or once we gave up waiting for it.
started: bool = false,
/// Measures the grace period from spawn.
since_spawn: ?std.time.Timer = null,
/// Reset on every read, so a watcher can ask how long output has been stopped.
/// Null until the child has written anything at all.
since_output: ?std.time.Timer = null,

/// The screen type as of the last refresh, and the generation at which it last
/// changed.
///
/// Recorded when it happens rather than compared against a baseline taken when
/// someone starts watching: a program that switches to the alternate screen
/// before the watch begins is already there by the time a baseline could be
/// taken, so the switch would never be seen. Which is exactly what happened.
last_alt_screen: bool = false,
alt_change_gen: u64 = 0,

/// True once this pane has ever shown an OSC 133 mark.
///
/// Shell integration is per-shell and opt-in, so the daemon cannot assume it.
/// Once a mark has been seen the boundaries are known exactly and the guessing
/// stops; until then the heuristics are all there is. Sticky, because a shell
/// that marked its last prompt has not stopped being integrated just because
/// the current screen has no mark on it.
saw_semantic_marks: bool = false,
/// Releases held input when the deadline passes rather than when the child
/// speaks. Needed because a program can read without ever writing -- `cat` being
/// the obvious one -- so waiting on output alone turns holding into dropping.
/// Spawned at most once, and only if there is something to release.
flusher: ?std.Thread = null,

/// Bumped whenever something may have changed the terminal. Only a hint, and
/// deliberately not the sequence number: a waiting client can read this without
/// taking the pane lock or rebuilding the render state, so an idle wake-up costs
/// an atomic load instead of a walk over the viewport.
gen: std.atomic.Value(u64) = .init(0),

pub const Notify = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
};

pub const Options = struct {
    argv: []const []const u8,
    env: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    cols: u16 = 80,
    rows: u16 = 24,
    scrollback: usize = default_scrollback_lines,
    output_ring: usize = default_output_ring_bytes,
    notify: ?Notify = null,
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

    const ring = try alloc.alloc(u8, opts.output_ring);
    errdefer alloc.free(ring);

    self.* = .{
        .alloc = alloc,
        .id = id,
        .pty = pty,
        .terminal = term,
        // Patched below: the handler needs the final address of `terminal`.
        .stream = undefined,
        .out_ring = ring,
        .since_spawn = std.time.Timer.start() catch null,
        .notify = opts.notify,
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
    // Joined, not detached: it holds a pointer to this pane and is about to be
    // freed out from under it otherwise.
    if (self.flusher) |thread| {
        thread.join();
        self.flusher = null;
    }

    self.render.deinit(self.alloc);
    self.alloc.free(self.row_seq);
    self.alloc.free(self.out_ring);
    self.pending.deinit(self.alloc);
    self.terminal.deinit(self.alloc);
    const alloc = self.alloc;
    alloc.destroy(self);
}

/// Send bytes to the child's stdin.
///
/// Held back until the child has produced output, or until the grace period
/// expires -- see `spawn_grace_ms`. A caller cannot tell the difference except
/// that its input is not lost.
pub fn write(self: *Pane, bytes: []const u8) !void {
    {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.started) {
            const waited_ms: u64 = if (self.since_spawn) |*t|
                t.read() / std.time.ns_per_ms
            else
                spawn_grace_ms;

            if (waited_ms < spawn_grace_ms) {
                try self.pending.appendSlice(self.alloc, bytes);
                if (self.flusher == null) {
                    const remaining = spawn_grace_ms - waited_ms;
                    self.flusher = std.Thread.spawn(.{}, releaseHeldInput, .{ self, remaining }) catch null;
                    // If the thread could not be spawned, send it now rather
                    // than hold something nothing will release.
                    if (self.flusher == null) self.started = true;
                }
                if (!self.started) return;
            }
            self.started = true;
        }
    }

    try self.flushPending();
    try self.pty.writeAll(bytes);
}

/// Wait out the remaining grace period, then send whatever is still held.
fn releaseHeldInput(self: *Pane, remaining_ms: u64) void {
    std.Thread.sleep(remaining_ms * std.time.ns_per_ms);
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.started) return; // the child spoke first and the reader flushed
        self.started = true;
    }
    self.flushPending() catch |err| {
        log.warn("pane {d}: could not send held input: {}", .{ self.id, err });
    };
}

/// Send anything that was held during startup, in the order it was given.
fn flushPending(self: *Pane) !void {
    var held: []u8 = &.{};
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending.items.len == 0) return;
        held = try self.pending.toOwnedSlice(self.alloc);
    }
    defer self.alloc.free(held);
    // Outside the lock: a pty write can block, and the reader thread needs the
    // lock to keep draining output.
    try self.pty.writeAll(held);
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
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.terminal.resize(self.alloc, cols, rows);
        try self.pty.resize(.{ .cols = cols, .rows = rows });
    }
    // The one change that does not arrive as pty output, so it has to be
    // announced here or a waiting client would not see the new geometry.
    _ = self.gen.fetchAdd(1, .release);
    if (self.notify) |n_| n_.func(n_.ctx);
}

pub fn hasExited(self: *const Pane) bool {
    return self.exited.load(.acquire);
}

/// Refresh the render state and fold its dirty flags into sequence numbers.
/// Caller holds `mutex`. Returns the pane's current sequence number.
fn refreshLocked(self: *Pane) !u64 {
    try self.render.update(self.alloc, &self.terminal);

    if (!self.saw_semantic_marks) {
        // Before the resize branch below, which returns early: on a pane's very
        // first refresh that branch is always taken, so detecting integration
        // after it meant the first command on a pane never saw the marks -- and
        // a quick command is finished before there is a second refresh.
        //
        // The cursor alone is not enough either: during a command it sits on
        // output, so an integrated shell would look unintegrated for exactly as
        // long as the command ran. The marked prompt above it is still there.
        self.saw_semantic_marks = self.terminal.screens.active.cursor.semantic_content != .output or
            semantic.hasMarks(&self.render);
    }

    const rows: usize = self.render.rows;
    if (self.row_seq.len != rows) {
        // A resize moves every cell a client is holding, so the only honest
        // answer is that all of it is stale.
        self.row_seq = try self.alloc.realloc(self.row_seq, rows);
        self.seq += 1;
        @memset(self.row_seq, self.seq);
        self.full_seq = self.seq;
        clearRowDirty(&self.render);
        self.render.dirty = .false;
        return self.seq;
    }

    const alt_now = self.render.screen == .alternate;
    if (alt_now != self.last_alt_screen) {
        self.last_alt_screen = alt_now;
        self.alt_change_gen = self.gen.load(.acquire);
    }

    if (self.render.dirty == .false) return self.seq;

    self.seq += 1;
    const full = self.render.dirty == .full;
    const slice = self.render.row_data.slice();
    const dirties = slice.items(.dirty);
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        if (full or dirties[y]) self.row_seq[y] = self.seq;
        // We are the only consumer of these flags, so clearing them here is
        // what makes the next refresh able to tell new changes from old.
        dirties[y] = false;
    }
    if (full) self.full_seq = self.seq;
    self.render.dirty = .false;
    return self.seq;
}

fn clearRowDirty(state: *vt.RenderState) void {
    const slice = state.row_data.slice();
    for (slice.items(.dirty)) |*d| d.* = false;
}

/// Serialize the screen for a client that last saw `since`, or return null if
/// nothing has changed since then.
///
/// One call does the refresh and the serialization together: splitting them
/// would mean releasing the lock in between, and the state could move.
pub fn screenSince(
    self: *Pane,
    alloc: std.mem.Allocator,
    since: u64,
    out: *std.ArrayListUnmanaged(u8),
) !?u64 {
    self.mutex.lock();
    defer self.mutex.unlock();

    const seq = try self.refreshLocked();
    if (since >= seq and since != 0) return null;

    // Read the defaults off the terminal rather than the render state: the
    // render state collapses "unset" to black, and unset is what a terminal
    // with no configured theme actually reports.
    const fg = self.terminal.colors.foreground.get();
    const bg = self.terminal.colors.background.get();

    try screen_json.write(alloc, out, &self.render, self.row_seq, .{
        .since = since,
        .pane_id = self.id,
        .full = since < self.full_seq,
        .seq = seq,
        .exited = self.exited.load(.acquire),
        .fg = fg,
        .bg = bg,
        .reverse = self.terminal.modes.get(.reverse_colors),
    });
    return seq;
}

/// Everything a watcher needs to judge whether to wake, taken under one lock so
/// the screen, the screen type and the idle time all describe the same instant.
pub const Observation = struct {
    /// The visible screen. Caller frees.
    text: []const u8,
    alt_screen: bool,
    /// The generation at which the screen type last changed, so a caller can
    /// tell "switched just now" from "was already full-screen".
    alt_change_gen: u64,
    /// Whether the shell is sitting at a prompt, or null when this pane has no
    /// shell integration and the question can only be guessed at.
    at_prompt: ?bool,
    exited: bool,
    /// Milliseconds since the last output. Large when nothing has ever been
    /// written, so a silent child reads as idle rather than as busy.
    idle_ms: u64,
    gen: u64,
};

/// The last command's output, read from the shell's OSC 133 marks.
///
/// Null when this pane has no shell integration, so the caller knows to fall
/// back rather than being handed an empty string that looks like an answer.
pub fn commandOutput(self: *Pane, alloc: std.mem.Allocator) !?[]const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    _ = try self.refreshLocked();
    return semantic.lastCommandOutput(alloc, &self.render);
}

/// The exit status of the last command, when the shell reported one.
///
/// Only integrated shells report it, so null means either no integration or a
/// command that ended without a status -- both cases where the honest answer is
/// that we do not know.
pub fn lastExitCode(self: *Pane) ?i32 {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.terminal.last_command_exit_code;
}

/// Whether the shell is at a prompt, or null without shell integration.
pub fn atPrompt(self: *Pane) !?bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    _ = try self.refreshLocked();
    if (!self.saw_semantic_marks) return null;
    return self.terminal.screens.active.cursor.semantic_content != .output;
}

/// The cheap half of `observe`: no allocation and no render rebuild.
///
/// Watching several panes means asking all of them on every tick, and most
/// ticks have nothing to report. Dumping every screen to discover that is waste
/// that grows with the number of panes being watched.
pub const Pulse = struct {
    gen: u64,
    idle_ms: u64,
    exited: bool,
};

pub fn pulse(self: *Pane) Pulse {
    self.mutex.lock();
    defer self.mutex.unlock();
    return .{
        .gen = self.gen.load(.acquire),
        .idle_ms = if (self.since_output) |*t| t.read() / std.time.ns_per_ms else std.math.maxInt(u64),
        .exited = self.exited.load(.acquire),
    };
}

pub fn observe(self: *Pane, alloc: std.mem.Allocator) !Observation {
    self.mutex.lock();
    defer self.mutex.unlock();

    _ = try self.refreshLocked();
    const text = try self.terminal.screens.active.dumpStringAlloc(alloc, .{ .active = .{} });
    errdefer alloc.free(text);

    return .{
        .text = text,
        .alt_screen = self.render.screen == .alternate,
        .alt_change_gen = self.alt_change_gen,
        // Upstream reads it the same way: anything other than command output
        // under the cursor means the shell is at a prompt or reading input.
        .at_prompt = if (self.saw_semantic_marks)
            self.terminal.screens.active.cursor.semantic_content != .output
        else
            null,
        .exited = self.exited.load(.acquire),
        .idle_ms = if (self.since_output) |*t| t.read() / std.time.ns_per_ms else std.math.maxInt(u64),
        .gen = self.gen.load(.acquire),
    };
}

/// The change hint. See `gen`.
pub fn generation(self: *const Pane) u64 {
    return self.gen.load(.acquire);
}

/// Append pty output to the ring. Caller holds `mutex`.
fn appendOutputLocked(self: *Pane, bytes: []const u8) void {
    if (self.out_ring.len == 0) return;

    const cap = self.out_ring.len;

    // A write larger than the ring can only keep its tail, but the offset
    // advances by the *whole* write: an offset is a position in the total output
    // stream, so not counting dropped bytes would hide the fact that a client
    // had fallen behind -- it would be handed a later part of the stream while
    // being told it was continuous.
    var src = bytes;
    if (src.len > cap) src = src[src.len - cap ..];

    const new_end = self.out_end + bytes.len;

    // Place the kept tail so that the ring holds exactly the last `cap` bytes
    // of the stream ending at `new_end`.
    const write_at: usize = @intCast((new_end - src.len) % cap);
    const first = @min(src.len, cap - write_at);
    @memcpy(self.out_ring[write_at..][0..first], src[0..first]);
    if (first < src.len) @memcpy(self.out_ring[0 .. src.len - first], src[first..]);

    self.out_end = new_end;
    self.out_start = new_end - @min(cap, new_end);
}

pub const Output = struct {
    /// Offset just past the last byte returned. Pass it back to continue.
    offset: u64,
    /// Bytes appended, owned by the caller.
    data: []const u8,
    /// The requested offset was older than anything still held, so `data`
    /// starts later than asked. A client that sees this has missed output and
    /// must repaint rather than assume continuity.
    gap: bool,
};

/// Raw output from `from` onwards, or null if there is none yet.
///
/// Caller frees `Output.data`.
pub fn outputSince(self: *Pane, alloc: std.mem.Allocator, from: u64) !?Output {
    self.mutex.lock();
    defer self.mutex.unlock();

    var start = from;
    var gap = false;
    if (start < self.out_start) {
        start = self.out_start;
        gap = true;
    }
    // A client ahead of us -- a pane that was replaced under the same id --
    // is treated as a gap rather than trusted, since we cannot produce bytes
    // we never had.
    if (start > self.out_end) {
        start = self.out_start;
        gap = true;
    }
    if (start == self.out_end and !gap) return null;

    const len: usize = @intCast(self.out_end - start);
    const data = try alloc.alloc(u8, len);
    errdefer alloc.free(data);

    const cap = self.out_ring.len;
    const read_at: usize = @intCast(start % cap);
    const first = @min(len, cap - read_at);
    @memcpy(data[0..first], self.out_ring[read_at..][0..first]);
    if (first < len) @memcpy(data[first..], self.out_ring[0 .. len - first]);

    return .{ .offset = self.out_end, .data = data, .gap = gap };
}

/// Paint the current screen as VT bytes, and report the output offset to stream
/// from afterwards.
///
/// Both under one lock: taking the offset separately would let output land in
/// between, and the relay would then replay bytes already reflected in the
/// paint -- doubling whatever arrived in that window.
pub fn paint(self: *Pane, alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !u64 {
    self.mutex.lock();
    defer self.mutex.unlock();

    _ = try self.refreshLocked();
    try vt_paint.write(alloc, out, &self.render);
    return self.out_end;
}

/// Terminal dimensions, for a client sizing itself to match.
pub fn size(self: *Pane) struct { cols: u16, rows: u16 } {
    self.mutex.lock();
    defer self.mutex.unlock();
    return .{
        .cols = @intCast(self.terminal.cols),
        .rows = @intCast(self.terminal.rows),
    };
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
        self.stream.nextSlice(buf[0..n]) catch |err| {
            // A malformed sequence should cost us that sequence, not the pane.
            log.warn("pane {d}: stream error: {}", .{ self.id, err });
        };
        self.appendOutputLocked(buf[0..n]);
        if (self.since_output) |*t| t.reset() else self.since_output = std.time.Timer.start() catch null;
        const was_starting = !self.started;
        self.started = true;
        self.mutex.unlock();

        // The child has spoken, so it is reading: anything held during startup
        // can go now.
        if (was_starting) self.flushPending() catch |err| {
            log.warn("pane {d}: could not send held input: {}", .{ self.id, err });
        };

        _ = self.gen.fetchAdd(1, .release);
        // Outside the lock on purpose: see `notify`.
        if (self.notify) |n_| n_.func(n_.ctx);
    }
    self.exited.store(true, .release);
    _ = self.gen.fetchAdd(1, .release);
    // A client blocked waiting for output needs to learn the pane is finished,
    // which is a change like any other.
    if (self.notify) |n_| n_.func(n_.ctx);
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
    try pane.expectOnScreen(alloc, "pane_hosting_works", 20000);
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
    try pane.expectOnScreen(alloc, "RED_TEXT", 20000);

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
    try pane.expectOnScreen(alloc, "scrollline12", 20000);

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
    while (waited < 20000 and !pane.hasExited()) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
        waited += 50;
    }
    try std.testing.expect(pane.hasExited());
}

/// A pane with a child that produces no output, so ring tests see only what
/// they put in. `sleep` rather than a shell: a shell prints a prompt.
fn quietPane(alloc: std.mem.Allocator, ring: usize) !*Pane {
    return create(alloc, 1, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .output_ring = ring,
    });
}

test "the output ring replays what a client missed" {
    const alloc = std.testing.allocator;
    var pane = try quietPane(alloc, 1024);
    defer pane.destroy();

    pane.mutex.lock();
    pane.appendOutputLocked("hello");
    pane.mutex.unlock();

    const from_start = (try pane.outputSince(alloc, 0)).?;
    defer alloc.free(from_start.data);
    try std.testing.expectEqualStrings("hello", from_start.data);
    try std.testing.expect(!from_start.gap);
    try std.testing.expectEqual(@as(u64, 5), from_start.offset);

    pane.mutex.lock();
    pane.appendOutputLocked(" world");
    pane.mutex.unlock();

    // Continuing from the offset returns only what arrived since.
    const rest = (try pane.outputSince(alloc, from_start.offset)).?;
    defer alloc.free(rest.data);
    try std.testing.expectEqualStrings(" world", rest.data);
    try std.testing.expect(!rest.gap);

    // Caught up: nothing to report rather than an empty answer.
    try std.testing.expect((try pane.outputSince(alloc, rest.offset)) == null);
}

test "the output ring wraps without corrupting what it still holds" {
    const alloc = std.testing.allocator;
    // Deliberately tiny, so the modular arithmetic is exercised rather than
    // merely present.
    var pane = try quietPane(alloc, 8);
    defer pane.destroy();

    pane.mutex.lock();
    pane.appendOutputLocked("abcde");
    pane.appendOutputLocked("fghij"); // crosses the end of the ring
    pane.mutex.unlock();

    // 10 bytes written into 8: the last 8 survive, in order.
    const got = (try pane.outputSince(alloc, 2)).?;
    defer alloc.free(got.data);
    try std.testing.expectEqualStrings("cdefghij", got.data);
    try std.testing.expectEqual(@as(u64, 10), got.offset);
    try std.testing.expect(!got.gap);
}

test "a client further behind than the ring is told there is a gap" {
    const alloc = std.testing.allocator;
    var pane = try quietPane(alloc, 8);
    defer pane.destroy();

    pane.mutex.lock();
    pane.appendOutputLocked("0123456789ab");
    pane.mutex.unlock();

    // Asking from the beginning, which has been overwritten. Silently returning
    // the oldest bytes we still have would hand back a stream starting
    // mid-escape-sequence; the flag is what lets the caller repaint instead.
    const got = (try pane.outputSince(alloc, 0)).?;
    defer alloc.free(got.data);
    try std.testing.expect(got.gap);
    try std.testing.expectEqualStrings("456789ab", got.data);
}

test "a write larger than the ring keeps its tail" {
    const alloc = std.testing.allocator;
    var pane = try quietPane(alloc, 4);
    defer pane.destroy();

    pane.mutex.lock();
    pane.appendOutputLocked("abcdefghij");
    pane.mutex.unlock();

    const got = (try pane.outputSince(alloc, 0)).?;
    defer alloc.free(got.data);
    try std.testing.expect(got.gap);
    try std.testing.expectEqualStrings("ghij", got.data);
    // The offset still counts every byte that went past, not just the kept ones.
    try std.testing.expectEqual(@as(u64, 10), got.offset);
}

test "input sent before the shell is ready is not lost" {
    const alloc = std.testing.allocator;
    var pane = try create(alloc, 1, .{ .argv = &.{"/bin/sh"} });
    defer pane.destroy();

    // Written with no pause at all, which is what an agent creating a pane and
    // immediately running a command does. A shell flushes pending terminal input
    // while setting up job control, so this used to be discarded outright and the
    // command simply never ran.
    try pane.write("printf 'EARLY_%s\\n' 'WRITE'\n");

    try pane.expectOnScreen(alloc, "EARLY_WRITE", 20000);
}

test "input still reaches a program that never writes anything first" {
    const alloc = std.testing.allocator;
    // `cat` echoes what it is given but says nothing on its own, so waiting for
    // the child to speak first would wait forever. The grace period is what
    // stops holding from becoming dropping.
    var pane = try create(alloc, 1, .{ .argv = &.{"/bin/cat"} });
    defer pane.destroy();

    try pane.write("HELD_THEN_SENT\n");
    try pane.expectOnScreen(alloc, "HELD_THEN_SENT", 20000);
}

test "shell integration is noticed on a pane's very first refresh" {
    const alloc = std.testing.allocator;

    // A child that marks a prompt straight away, then waits. The first refresh
    // of a pane also allocates its row bookkeeping and used to return early
    // before looking for marks -- so the first command run on a pane fell back
    // to guessing, and a quick command was over before a second refresh
    // happened. Only ever visible against a live shell.
    var pane = try create(alloc, 1, .{
        .argv = &.{ "/bin/sh", "-c", "printf '\\033]133;A\\007$ \\033]133;B\\007'; sleep 30" },
    });
    defer pane.destroy();

    // Wait for the marks to arrive, then ask exactly once.
    var waited: usize = 0;
    while (waited < 20000) : (waited += 100) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        if (pane.generation() > 0) break;
    }

    const at_prompt = try pane.atPrompt();
    try std.testing.expect(at_prompt != null);
    try std.testing.expect(at_prompt.?);
}
