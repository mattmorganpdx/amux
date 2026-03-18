const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.notifications);

pub const NotificationStore = @This();

pub const Notification = struct {
    id: u64,
    title: [256]u8,
    title_len: usize,
    body: [512]u8,
    body_len: usize,
    timestamp: i64,
};

const MAX_NOTIFICATIONS = 64;

/// Ring buffer of notifications.
notifications: [MAX_NOTIFICATIONS]Notification = undefined,
count: usize = 0,
write_pos: usize = 0,
next_id: u64 = 1,

/// Add a notification and show it via libnotify. Returns the notification ID.
pub fn add(self: *NotificationStore, title: []const u8, body: ?[]const u8) u64 {
    const id = self.next_id;
    self.next_id += 1;

    var notif: Notification = undefined;
    notif.id = id;
    notif.timestamp = std.time.timestamp();

    const t_len = @min(title.len, notif.title.len);
    @memcpy(notif.title[0..t_len], title[0..t_len]);
    notif.title_len = t_len;

    if (body) |b| {
        const b_len = @min(b.len, notif.body.len);
        @memcpy(notif.body[0..b_len], b[0..b_len]);
        notif.body_len = b_len;
    } else {
        notif.body_len = 0;
    }

    // Store in ring buffer
    self.notifications[self.write_pos] = notif;
    self.write_pos = (self.write_pos + 1) % MAX_NOTIFICATIONS;
    if (self.count < MAX_NOTIFICATIONS) self.count += 1;

    // Show desktop notification via libnotify
    self.showDesktopNotification(title, body);

    return id;
}

/// Show a desktop notification via libnotify.
fn showDesktopNotification(_: *NotificationStore, title: []const u8, body: ?[]const u8) void {
    // Null-terminate title
    var title_z: [257]u8 = undefined;
    const t_len = @min(title.len, 256);
    @memcpy(title_z[0..t_len], title[0..t_len]);
    title_z[t_len] = 0;

    // Null-terminate body (or null)
    var body_ptr: ?[*:0]const u8 = null;
    var body_z: [513]u8 = undefined;
    if (body) |b| {
        const b_len = @min(b.len, 512);
        @memcpy(body_z[0..b_len], b[0..b_len]);
        body_z[b_len] = 0;
        body_ptr = @ptrCast(&body_z);
    }

    const notif = c.notify_notification_new(&title_z, body_ptr, null);
    if (notif) |n| {
        _ = c.notify_notification_show(n, null);
        c.g_object_unref(n);
    }
}

/// Get all stored notifications (most recent first).
pub fn list(self: *const NotificationStore, alloc: std.mem.Allocator) ![]const Notification {
    if (self.count == 0) return &[_]Notification{};

    var result = try alloc.alloc(Notification, self.count);
    // Read in reverse order (most recent first)
    var out_idx: usize = 0;
    var ring_idx: usize = if (self.write_pos == 0) MAX_NOTIFICATIONS - 1 else self.write_pos - 1;
    while (out_idx < self.count) : (out_idx += 1) {
        result[out_idx] = self.notifications[ring_idx];
        ring_idx = if (ring_idx == 0) MAX_NOTIFICATIONS - 1 else ring_idx - 1;
    }
    return result;
}

/// Clear a specific notification by ID, or all if id is null.
pub fn clear(self: *NotificationStore, id: ?u64) void {
    if (id == null) {
        self.count = 0;
        self.write_pos = 0;
        return;
    }

    // For simplicity with a ring buffer, clearing a single entry
    // just marks it as id=0 (tombstone). List skips tombstones.
    const target_id = id.?;
    for (&self.notifications, 0..) |*n, i| {
        _ = i;
        if (n.id == target_id) {
            n.id = 0;
            if (self.count > 0) self.count -= 1;
            return;
        }
    }
}
