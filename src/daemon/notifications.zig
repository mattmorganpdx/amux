//! Notification records the daemon keeps.
//!
//! Records, not desktop notifications: showing one needs libnotify and a session
//! bus, and amuxd deliberately links neither. So the daemon remembers what
//! happened and any client can ask; a GUI that is running turns recent ones into
//! desktop notifications, and when nothing is running the record is still there
//! to be read afterwards. That is the point -- an agent reporting "needs
//! approval" with no window open should not lose the message.
//!
//! A fixed ring rather than a growing list: this is a tail of recent events, and
//! an unbounded one in a process that runs for weeks is a leak with a nicer name.

const std = @import("std");

const Notifications = @This();

/// Kept before the oldest is overwritten.
pub const capacity = 64;
const max_title = 96;
const max_body = 512;

pub const Record = struct {
    id: u64,
    title: [max_title]u8 = [_]u8{0} ** max_title,
    title_len: usize = 0,
    body: [max_body]u8 = [_]u8{0} ** max_body,
    body_len: usize = 0,
    workspace_id: ?u64 = null,
    at: i64 = 0,

    pub fn titleSlice(self: *const Record) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn bodySlice(self: *const Record) []const u8 {
        return self.body[0..self.body_len];
    }
};

mutex: std.Thread.Mutex = .{},
ring: [capacity]Record = [_]Record{.{ .id = 0 }} ** capacity,
/// Total ever added; also the next id. Never decremented, so ids stay unique
/// and `clear` cannot make a later record collide with an earlier one.
count: u64 = 0,

pub fn add(self: *Notifications, title: []const u8, body: []const u8, workspace_id: ?u64) u64 {
    self.mutex.lock();
    defer self.mutex.unlock();

    const id = self.count + 1;
    const slot: usize = @intCast(self.count % capacity);
    var rec: Record = .{ .id = id, .workspace_id = workspace_id, .at = std.time.timestamp() };
    rec.title_len = @min(title.len, max_title);
    @memcpy(rec.title[0..rec.title_len], title[0..rec.title_len]);
    rec.body_len = @min(body.len, max_body);
    @memcpy(rec.body[0..rec.body_len], body[0..rec.body_len]);
    self.ring[slot] = rec;
    self.count = id;
    return id;
}

/// Copy out the records still held, newest first. Caller owns the slice.
pub fn list(self: *Notifications, alloc: std.mem.Allocator, limit: usize) ![]Record {
    self.mutex.lock();
    defer self.mutex.unlock();

    const held: usize = @intCast(@min(self.count, @as(u64, capacity)));
    const want = @min(held, limit);
    const out = try alloc.alloc(Record, want);

    var i: usize = 0;
    while (i < want) : (i += 1) {
        // Walk backwards from the newest.
        const back = self.count - 1 - @as(u64, i);
        out[i] = self.ring[@intCast(back % capacity)];
    }
    return out;
}

/// Forget one record, or all of them when `id` is null.
///
/// Tombstones rather than compacting, and never touches `count`: the GUI's
/// notification store learned this the hard way, where decrementing a count on
/// clear made an unrelated record disappear.
pub fn clear(self: *Notifications, id: ?u64) bool {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (id == null) {
        for (&self.ring) |*rec| rec.* = .{ .id = 0 };
        return true;
    }
    for (&self.ring) |*rec| {
        if (rec.id != 0 and rec.id == id.?) {
            rec.* = .{ .id = 0 };
            return true;
        }
    }
    return false;
}

test "records are kept newest first and survive the ring wrapping" {
    const alloc = std.testing.allocator;
    var n: Notifications = .{};

    var i: usize = 0;
    while (i < capacity + 5) : (i += 1) {
        var buf: [32]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "event {d}", .{i});
        _ = n.add("amux", body, 1);
    }

    const got = try n.list(alloc, 3);
    defer alloc.free(got);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    // Newest first: the last one added is the one a client cares about most.
    try std.testing.expectEqualStrings("event 68", got[0].bodySlice());
    try std.testing.expectEqualStrings("event 67", got[1].bodySlice());
    try std.testing.expectEqualStrings("amux", got[0].titleSlice());
}

test "clearing one record leaves the others alone" {
    const alloc = std.testing.allocator;
    var n: Notifications = .{};

    _ = n.add("a", "first", null);
    const second = n.add("b", "second", null);
    _ = n.add("c", "third", null);

    try std.testing.expect(n.clear(second));
    try std.testing.expect(!n.clear(second)); // already gone

    const got = try n.list(alloc, capacity);
    defer alloc.free(got);

    var live: usize = 0;
    var saw_first = false;
    var saw_third = false;
    for (got) |rec| {
        if (rec.id == 0) continue;
        live += 1;
        if (std.mem.eql(u8, rec.bodySlice(), "first")) saw_first = true;
        if (std.mem.eql(u8, rec.bodySlice(), "third")) saw_third = true;
    }
    try std.testing.expectEqual(@as(usize, 2), live);
    try std.testing.expect(saw_first and saw_third);
}
