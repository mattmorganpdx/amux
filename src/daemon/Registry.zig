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

    const pane = try Pane.create(self.alloc, id, opts);
    errdefer pane.destroy();

    try self.panes.put(self.alloc, id, pane);
    log.info("opened pane {d}", .{id});
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

    try reg.write(a, "echo only_in_pane_a\n");
    try reg.write(b, "echo only_in_pane_b\n");

    // Poll pane a for its own marker, then assert b's never leaked into it.
    var waited: usize = 0;
    var ok = false;
    while (waited < 5000) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
        waited += 50;
        const screen = try reg.snapshot(a, alloc);
        defer alloc.free(screen);
        if (std.mem.count(u8, screen, "only_in_pane_a") >= 2) {
            ok = true;
            try std.testing.expect(std.mem.indexOf(u8, screen, "only_in_pane_b") == null);
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
