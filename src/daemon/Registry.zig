//! The daemon's panes, keyed by id.
//!
//! Deliberately does not hand out `*Pane`. The GUI's `pane_widgets` was a bare
//! map that callers looked into, which produced exactly one use-after-free
//! (a socket handler holding a widget while the GTK thread freed it) and one
//! data race. Every operation here takes an id and does the work while holding
//! the lock, so a pane cannot be destroyed out from under a caller.
//!
//! The cost is that the registry lock is held across a pty write or a screen
//! snapshot. Both are short, and correctness is worth more than the contention
//! at this scale.

const std = @import("std");
const Pane = @import("Pane.zig");

const Registry = @This();

const log = std.log.scoped(.registry);

alloc: std.mem.Allocator,
mutex: std.Thread.Mutex = .{},
panes: std.AutoHashMapUnmanaged(u64, *Pane) = .{},

/// Signalled when any pane's output changes, so a client waiting on a screen
/// update is woken instead of polling. One condition for all panes: a change to
/// a pane nobody is watching wakes the wrong waiter, who re-checks and goes back
/// to sleep. At this scale that costs less than per-pane condition variables
/// would, and it keeps the waiting rule the same as every other rule here --
/// hold an id, never a pointer.
change: std.Thread.Condition = .{},

/// Set on the way out, so a client parked in a long wait is answered instead of
/// being left holding a registry that is about to be freed.
///
/// Without this, shutdown raced the waiters: a relay's twenty-second poll almost
/// always had a thread inside `screen` or `output` when the daemon stopped, the
/// client drain gave up on it, and teardown freed the pane map underneath it.
/// That surfaced as "incorrect alignment" in the hash map -- a use-after-free by
/// another name.
stopping: bool = false,

pub const Error = error{PaneNotFound};

pub fn init(alloc: std.mem.Allocator) Registry {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *Registry) void {
    self.mutex.lock();
    var it = self.panes.valueIterator();
    while (it.next()) |pane| pane.*.destroy();
    self.panes.deinit(self.alloc);
    self.mutex.unlock();
}

/// Spawn a pane under `id`.
///
/// The caller owns the id space: pane ids are pane-tree node ids, so the tree
/// and the registry cannot drift apart.
pub fn open(self: *Registry, id: u64, opts: Pane.Options) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.panes.contains(id)) return error.PaneExists;

    var with_notify = opts;
    with_notify.notify = .{ .ctx = self, .func = notifyChanged };

    const pane = try Pane.create(self.alloc, id, with_notify);
    errdefer pane.destroy();

    try self.panes.put(self.alloc, id, pane);
    log.info("opened pane {d}", .{id});
}

/// Wake anything waiting for a screen update. Runs on a pane's reader thread.
///
/// `tryLock`, not `lock`: this thread is the one `Pane.destroy` joins, and
/// callers run `destroy` while holding this lock -- so blocking here would
/// deadlock the two against each other. Skipping a broadcast costs only latency,
/// because a waiter re-checks on its own timer regardless. That backstop is what
/// makes the non-blocking notify safe rather than merely convenient.
/// Release every waiter and refuse new waits. Call before tearing anything down.
pub fn stopWaiters(self: *Registry) void {
    self.mutex.lock();
    self.stopping = true;
    self.change.broadcast();
    self.mutex.unlock();
}

fn notifyChanged(ctx: *anyopaque) void {
    const self: *Registry = @ptrCast(@alignCast(ctx));
    if (!self.mutex.tryLock()) return;
    self.change.broadcast();
    self.mutex.unlock();
}

pub fn close(self: *Registry, id: u64) Error!void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const entry = self.panes.fetchRemove(id) orelse return error.PaneNotFound;
    entry.value.destroy();
    log.info("closed pane {d}", .{id});
}

pub fn write(self: *Registry, id: u64, bytes: []const u8) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    const pane = self.panes.get(id) orelse return error.PaneNotFound;
    try pane.write(bytes);
}

/// Caller owns the returned text.
pub fn snapshot(self: *Registry, id: u64, alloc: std.mem.Allocator) ![]const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const pane = self.panes.get(id) orelse return error.PaneNotFound;
    return pane.snapshot(alloc);
}

/// Caller owns the returned text.
pub fn snapshotScrollback(self: *Registry, id: u64, alloc: std.mem.Allocator) ![]const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const pane = self.panes.get(id) orelse return error.PaneNotFound;
    return pane.snapshotScrollback(alloc);
}

pub fn resize(self: *Registry, id: u64, cols: u16, rows: u16) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    const pane = self.panes.get(id) orelse return error.PaneNotFound;
    try pane.resize(cols, rows);
}

/// How long a blocked waiter sleeps before re-checking on its own.
///
/// A notify can be skipped (see `notifyChanged`) so this is what bounds the
/// resulting latency, not just a safety net. Small enough that a dropped
/// broadcast is not visible to someone typing; large enough that an idle
/// watcher costs a handful of atomic loads a second.
const wait_slice_ns: u64 = 25 * std.time.ns_per_ms;

pub const ScreenOptions = struct {
    /// The sequence number the client last saw. 0 asks for the whole screen,
    /// which is what attaching does.
    since: u64 = 0,
    /// How long to wait for a change before answering "nothing new". 0 answers
    /// immediately.
    timeout_ms: u32 = 0,
};

/// Serialize a pane's screen into `out`, optionally waiting for it to change.
///
/// Returns the pane's new sequence number, or null if the timeout passed with
/// nothing to report.
///
/// The wait holds the registry lock, which `timedWait` releases while sleeping,
/// so panes can still be opened, closed and written to meanwhile. The pane is
/// looked up again by id after every wake, so a pane closed under a waiting
/// client comes back as `PaneNotFound` rather than a use-after-free.
pub fn screen(
    self: *Registry,
    id: u64,
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    opts: ScreenOptions,
) !?u64 {
    const total_ns = @as(u64, opts.timeout_ms) * std.time.ns_per_ms;
    var timer: ?std.time.Timer = std.time.Timer.start() catch null;

    self.mutex.lock();
    defer self.mutex.unlock();

    var last_gen: ?u64 = null;
    while (true) {
        if (self.stopping) return null;
        const pane = self.panes.get(id) orelse return Error.PaneNotFound;

        // Only rebuild the render state when the cheap hint says something may
        // have happened. The first pass always checks, because the client can
        // be behind for reasons older than this call.
        const gen = pane.generation();
        if (last_gen == null or gen != last_gen.?) {
            last_gen = gen;
            if (try pane.screenSince(alloc, opts.since, out)) |seq| return seq;
        }

        const elapsed = if (timer) |*t| t.read() else total_ns;
        if (elapsed >= total_ns) return null;
        const slice = @min(total_ns - elapsed, wait_slice_ns);
        self.change.timedWait(&self.mutex, slice) catch {};
    }
}

pub const OutputResult = struct {
    offset: u64,
    /// Raw bytes to feed a terminal, owned by the caller. Empty when this is a
    /// repaint carried in `paint` instead.
    data: []const u8 = &.{},
    /// A repaint: either the client is attaching, or it fell so far behind that
    /// continuing from where it was would show a corrupted screen.
    paint: ?[]const u8 = null,
    cols: u16 = 0,
    rows: u16 = 0,
    exited: bool = false,
};

/// Raw output for a relay, optionally waiting for some.
///
/// `from` null means attaching: the answer is a repaint of the current screen
/// plus the offset to continue from. Otherwise it is the bytes since `from`,
/// unless that offset has aged out of the pane's ring -- then it is a repaint
/// again, because bytes we no longer hold cannot be replayed.
///
/// Same waiting rules as `screen`: the registry lock is held, `timedWait`
/// releases it, and the pane is looked up again after every wake.
pub fn output(
    self: *Registry,
    id: u64,
    alloc: std.mem.Allocator,
    from: ?u64,
    timeout_ms: u32,
) !?OutputResult {
    const total_ns = @as(u64, timeout_ms) * std.time.ns_per_ms;
    var timer: ?std.time.Timer = std.time.Timer.start() catch null;

    self.mutex.lock();
    defer self.mutex.unlock();

    var last_gen: ?u64 = null;
    while (true) {
        if (self.stopping) return null;
        const pane = self.panes.get(id) orelse return Error.PaneNotFound;
        const dims = pane.size();

        if (from == null) {
            var buf: std.ArrayListUnmanaged(u8) = .{};
            errdefer buf.deinit(alloc);
            const offset = try pane.paint(alloc, &buf);
            return .{
                .offset = offset,
                .paint = try buf.toOwnedSlice(alloc),
                .cols = dims.cols,
                .rows = dims.rows,
                .exited = pane.hasExited(),
            };
        }

        const gen = pane.generation();
        if (last_gen == null or gen != last_gen.?) {
            last_gen = gen;
            if (try pane.outputSince(alloc, from.?)) |got| {
                if (!got.gap) {
                    return .{
                        .offset = got.offset,
                        .data = got.data,
                        .cols = dims.cols,
                        .rows = dims.rows,
                        .exited = pane.hasExited(),
                    };
                }
                // Behind by more than the ring holds. Repaint rather than hand
                // back a stream that starts mid-escape-sequence.
                alloc.free(got.data);
                var buf: std.ArrayListUnmanaged(u8) = .{};
                errdefer buf.deinit(alloc);
                const offset = try pane.paint(alloc, &buf);
                return .{
                    .offset = offset,
                    .paint = try buf.toOwnedSlice(alloc),
                    .cols = dims.cols,
                    .rows = dims.rows,
                    .exited = pane.hasExited(),
                };
            }
            // A dead pane will never produce more, so waiting for it is a way
            // of hanging rather than a way of being patient.
            if (pane.hasExited()) {
                return .{
                    .offset = from.?,
                    .cols = dims.cols,
                    .rows = dims.rows,
                    .exited = true,
                };
            }
        }

        const elapsed = if (timer) |*t| t.read() else total_ns;
        if (elapsed >= total_ns) return null;
        const slice = @min(total_ns - elapsed, wait_slice_ns);
        self.change.timedWait(&self.mutex, slice) catch {};
    }
}

pub fn hasExited(self: *Registry, id: u64) Error!bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    const pane = self.panes.get(id) orelse return error.PaneNotFound;
    return pane.hasExited();
}

pub fn count(self: *Registry) usize {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.panes.count();
}

/// Ids of every live pane, oldest first. Caller owns the slice.
pub fn ids(self: *Registry, alloc: std.mem.Allocator) ![]u64 {
    self.mutex.lock();
    defer self.mutex.unlock();

    const out = try alloc.alloc(u64, self.panes.count());
    var i: usize = 0;
    var it = self.panes.keyIterator();
    while (it.next()) |k| : (i += 1) out[i] = k.*;
    std.mem.sort(u64, out, {}, comptime std.sort.asc(u64));
    return out;
}

test "opens, tracks and closes panes by id" {
    const alloc = std.testing.allocator;

    var reg = init(alloc);
    defer reg.deinit();

    try std.testing.expectEqual(@as(usize, 0), reg.count());

    const a: u64 = 1;
    const b: u64 = 2;
    try reg.open(a, .{ .argv = &.{ "/bin/sh", "-i" } });
    try reg.open(b, .{ .argv = &.{ "/bin/sh", "-i" } });
    try std.testing.expectEqual(@as(usize, 2), reg.count());
    try std.testing.expectError(error.PaneExists, reg.open(a, .{ .argv = &.{"/bin/sh"} }));

    const live = try reg.ids(alloc);
    defer alloc.free(live);
    try std.testing.expectEqualSlices(u64, &.{ a, b }, live);

    try reg.close(a);
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    try std.testing.expectError(error.PaneNotFound, reg.close(a));
}

test "operations on an unknown id report it rather than crashing" {
    const alloc = std.testing.allocator;

    var reg = init(alloc);
    defer reg.deinit();

    try std.testing.expectError(error.PaneNotFound, reg.write(999, "x"));
    try std.testing.expectError(error.PaneNotFound, reg.snapshot(999, alloc));
    try std.testing.expectError(error.PaneNotFound, reg.resize(999, 80, 24));
    try std.testing.expectError(error.PaneNotFound, reg.hasExited(999));
}

test "routes writes and snapshots to the right pane" {
    const alloc = std.testing.allocator;

    var reg = init(alloc);
    defer reg.deinit();

    const a: u64 = 1;
    const b: u64 = 2;
    try reg.open(a, .{ .argv = &.{ "/bin/sh", "-i" }, .env = &.{"PS1=$ "} });
    try reg.open(b, .{ .argv = &.{ "/bin/sh", "-i" }, .env = &.{"PS1=$ "} });

    // Markers assembled by the command, so a copy on screen is output rather
    // than the shell's echo of what it was asked to run. Depending on the echo
    // made this race: it is only on once the shell has set the terminal up.
    try reg.write(a, "printf 'ONLY_IN_%s\\n' 'PANE_A'\n");
    try reg.write(b, "printf 'ONLY_IN_%s\\n' 'PANE_B'\n");

    // Poll pane a for its own marker, then assert b's never leaked into it.
    var waited: usize = 0;
    var ok = false;
    while (waited < 20000) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
        waited += 50;
        const text = try reg.snapshot(a, alloc);
        defer alloc.free(text);
        if (std.mem.indexOf(u8, text, "ONLY_IN_PANE_A") != null) {
            ok = true;
            try std.testing.expect(std.mem.indexOf(u8, text, "ONLY_IN_PANE_B") == null);
            break;
        }
    }
    try std.testing.expect(ok);
}

test "deinit closes every pane still open" {
    const alloc = std.testing.allocator;

    var reg = init(alloc);
    try reg.open(1, .{ .argv = &.{ "/bin/sh", "-i" } });
    try reg.open(2, .{ .argv = &.{ "/bin/sh", "-i" } });
    try std.testing.expectEqual(@as(usize, 2), reg.count());
    // The allocator checks for leaks when the test ends, so a pane left behind
    // here would fail the test.
    reg.deinit();
}

test "a waiting client is woken by output instead of polling for it" {
    const alloc = std.testing.allocator;

    var reg = init(alloc);
    defer reg.deinit();

    const id: u64 = 1;
    try reg.open(id, .{ .argv = &.{ "/bin/sh", "-i" } });

    // Attach first, so the wait below starts from a known sequence number.
    var attach: std.ArrayListUnmanaged(u8) = .{};
    defer attach.deinit(alloc);
    const seq = (try reg.screen(id, alloc, &attach, .{})).?;
    try std.testing.expect(attach.items.len > 0);

    // Nothing has happened since, so a zero timeout reports no change.
    var empty: std.ArrayListUnmanaged(u8) = .{};
    defer empty.deinit(alloc);
    try std.testing.expect((try reg.screen(id, alloc, &empty, .{ .since = seq })) == null);

    try reg.write(id, "echo woken_by_output\n");

    // Generous timeout: the assertion is that it returns *because output
    // arrived*, which the elapsed time below distinguishes from timing out.
    var timer = try std.time.Timer.start();
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    const new_seq = try reg.screen(id, alloc, &out, .{ .since = seq, .timeout_ms = 20_000 });

    try std.testing.expect(new_seq != null);
    try std.testing.expect(new_seq.? > seq);
    try std.testing.expect(timer.read() < 19 * std.time.ns_per_s);
    try std.testing.expect(out.items.len > 0);
}

/// Drain updates until the pane goes quiet, returning the settled sequence
/// number. A freshly spawned shell prints a prompt whenever it gets around to
/// it, and a test that waits on "nothing happening" has to start from actual
/// silence or it is really just waiting on that prompt.
fn settle(reg: *Registry, id: u64, alloc: std.mem.Allocator, from: u64) !u64 {
    var seq = from;
    var tries: usize = 0;
    while (tries < 60) : (tries += 1) {
        var probe: std.ArrayListUnmanaged(u8) = .{};
        defer probe.deinit(alloc);
        if (try reg.screen(id, alloc, &probe, .{ .since = seq, .timeout_ms = 150 })) |s| {
            seq = s;
        } else return seq;
    }
    return error.PaneNeverWentQuiet;
}

test "closing a pane releases a client waiting on it" {
    const alloc = std.testing.allocator;

    var reg = init(alloc);
    defer reg.deinit();

    const id: u64 = 1;
    try reg.open(id, .{ .argv = &.{ "/bin/sh", "-i" } });

    var attach: std.ArrayListUnmanaged(u8) = .{};
    defer attach.deinit(alloc);
    const attached = (try reg.screen(id, alloc, &attach, .{})).?;

    // The pane has to be quiet before the waiter starts, or it returns on the
    // shell's prompt and never reaches the close this test is about.
    const seq = try settle(&reg, id, alloc, attached);

    // Wait on a pane that is about to be destroyed under us. Holding an id
    // rather than a pointer is what makes this answerable at all: the waiter
    // looks the pane up again after every wake, so a closed pane is an error
    // rather than a use-after-free.
    const Waiter = struct {
        reg: *Registry,
        alloc: std.mem.Allocator,
        id: u64,
        since: u64,
        err: ?anyerror = null,
        returned_normally: bool = false,

        fn run(self: *@This()) void {
            var out: std.ArrayListUnmanaged(u8) = .{};
            defer out.deinit(self.alloc);
            _ = self.reg.screen(self.id, self.alloc, &out, .{
                .since = self.since,
                .timeout_ms = 20_000,
            }) catch |e| {
                self.err = e;
                return;
            };
            self.returned_normally = true;
        }
    };
    var waiter: Waiter = .{ .reg = &reg, .alloc = alloc, .id = id, .since = seq };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});

    // Give the waiter time to get into the wait, then pull the pane out.
    std.Thread.sleep(300 * std.time.ns_per_ms);
    try reg.close(id);
    thread.join();

    // The point: it came back, and it came back as an error rather than as a
    // crash or a hang.
    try std.testing.expect(!waiter.returned_normally);
    try std.testing.expectEqual(Error.PaneNotFound, waiter.err.?);
}

test "a wait with nothing to report ends at its deadline" {
    const alloc = std.testing.allocator;

    var reg = init(alloc);
    defer reg.deinit();

    const id: u64 = 1;
    try reg.open(id, .{ .argv = &.{ "/bin/sh", "-i" } });

    var attach: std.ArrayListUnmanaged(u8) = .{};
    defer attach.deinit(alloc);
    const attached = (try reg.screen(id, alloc, &attach, .{})).?;

    // Genuinely waiting on silence, not on output still in flight.
    const seq = try settle(&reg, id, alloc, attached);

    var timer = try std.time.Timer.start();
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    const res = try reg.screen(id, alloc, &out, .{ .since = seq, .timeout_ms = 400 });

    try std.testing.expect(res == null);
    // It waited rather than returning immediately, and did not overshoot.
    try std.testing.expect(timer.read() >= 350 * std.time.ns_per_ms);
    try std.testing.expect(timer.read() < 3 * std.time.ns_per_s);
}
