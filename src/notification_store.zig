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

/// Guards every field below.
///
/// All six call sites live in socket handlers, which run on a thread per
/// client, so `add`/`list`/`clear` genuinely run concurrently -- two Claude
/// Code hook events firing at once is enough. Without this, `list` could size
/// its result from one read of `count` and then bound its loop on a later,
/// larger one, writing past the allocation.
mutex: std.Thread.Mutex = .{},

/// Ring buffer of notifications.
///
/// Zero-initialised rather than `undefined`: `clear` compares `id` against
/// slots that may never have been written, and reading undefined memory is
/// undefined behaviour. A zeroed slot has `id == 0`, which is never a real id.
notifications: [MAX_NOTIFICATIONS]Notification = std.mem.zeroes([MAX_NOTIFICATIONS]Notification),
/// Number of slots in the live ring window. Includes cleared (tombstoned)
/// entries -- see `clear`.
count: usize = 0,
write_pos: usize = 0,
next_id: u64 = 1,

/// Add a notification and show it via libnotify. Returns the notification ID.
pub fn add(self: *NotificationStore, title: []const u8, body: ?[]const u8) u64 {
    // Scoped so the lock is released by `defer` on every path, and so the
    // libnotify call below happens outside it: that goes over DBus and can
    // block, and needs no store state.
    const id = blk: {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id;
        self.next_id += 1;

        var notif: Notification = std.mem.zeroes(Notification);
        notif.id = id;
        notif.timestamp = std.time.timestamp();

        const t_len = @min(title.len, notif.title.len);
        @memcpy(notif.title[0..t_len], title[0..t_len]);
        notif.title_len = t_len;

        if (body) |b| {
            const b_len = @min(b.len, notif.body.len);
            @memcpy(notif.body[0..b_len], b[0..b_len]);
            notif.body_len = b_len;
        }

        // Store in ring buffer
        self.notifications[self.write_pos] = notif;
        self.write_pos = (self.write_pos + 1) % MAX_NOTIFICATIONS;
        if (self.count < MAX_NOTIFICATIONS) self.count += 1;

        break :blk id;
    };

    self.showDesktopNotification(title, body);

    return id;
}

/// One queued desktop notification, owned by the GTK main thread.
///
/// The strings are copied in rather than borrowed: the requesting handler
/// thread returns (and frees its request arena) long before the idle callback
/// runs. Both buffers carry room for a NUL beyond the libnotify field sizes.
const DesktopRequest = struct {
    title: [257]u8,
    body: [513]u8,
    has_body: bool,
};

/// Show a desktop notification via libnotify.
///
/// libnotify and the GLib main context behind it are not safe to drive from
/// arbitrary threads, and every entry point in this store runs on a socket
/// handler thread. The show is therefore queued onto the GTK main thread, the
/// same place every other UI touchpoint in amux is driven from -- and where
/// `notify_init` itself runs, so this can no longer race initialisation.
///
/// Deliberately fire-and-forget: the caller does not wait, so a slow DBus
/// round-trip cannot stall a socket handler (or, before the store grew a
/// mutex, every other handler behind it). The only cost is that a request
/// queued while the main loop is shutting down never fires and its payload is
/// leaked -- bounded, and the process is exiting anyway.
fn showDesktopNotification(_: *NotificationStore, title: []const u8, body: ?[]const u8) void {
    const req = std.heap.c_allocator.create(DesktopRequest) catch |err| {
        log.warn("Dropping desktop notification: {}", .{err});
        return;
    };
    // Zeroed so both buffers are NUL-terminated whatever the copy length is.
    req.* = std.mem.zeroes(DesktopRequest);
    req.has_body = body != null;

    const t_len = @min(title.len, req.title.len - 1);
    @memcpy(req.title[0..t_len], title[0..t_len]);

    if (body) |b| {
        const b_len = @min(b.len, req.body.len - 1);
        @memcpy(req.body[0..b_len], b[0..b_len]);
    }

    _ = c.g_idle_add(&showQueuedNotification, @ptrCast(req));
}

/// Runs on the GTK main thread; consumes and frees one DesktopRequest.
fn showQueuedNotification(userdata: c.gpointer) callconv(.c) c.gboolean {
    const req: *DesktopRequest = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(req);

    const body_ptr: ?[*:0]const u8 = if (req.has_body) @ptrCast(&req.body) else null;
    const notif = c.notify_notification_new(@ptrCast(&req.title), body_ptr, null);
    if (notif) |n| {
        _ = c.notify_notification_show(n, null);
        c.g_object_unref(n);
    }
    return c.G_SOURCE_REMOVE;
}

/// Get all stored notifications (most recent first).
///
/// Cleared entries are returned as tombstones with `id == 0`; callers skip
/// them. Takes `*NotificationStore` rather than a const pointer because the
/// read has to be serialised against concurrent `add`/`clear`.
pub fn list(self: *NotificationStore, alloc: std.mem.Allocator) ![]const Notification {
    self.mutex.lock();
    defer self.mutex.unlock();

    // Read `count` exactly once. Sizing the allocation from one read and
    // bounding the loop on another is what let a concurrent `add` push
    // `out_idx` one past the end of `result`.
    const window = self.count;
    if (window == 0) return &[_]Notification{};

    const result = try alloc.alloc(Notification, window);
    // Read in reverse order (most recent first)
    var out_idx: usize = 0;
    var ring_idx: usize = if (self.write_pos == 0) MAX_NOTIFICATIONS - 1 else self.write_pos - 1;
    while (out_idx < window) : (out_idx += 1) {
        result[out_idx] = self.notifications[ring_idx];
        ring_idx = if (ring_idx == 0) MAX_NOTIFICATIONS - 1 else ring_idx - 1;
    }
    return result;
}

/// Clear a specific notification by ID, or all if id is null.
pub fn clear(self: *NotificationStore, id: ?u64) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (id == null) {
        self.count = 0;
        self.write_pos = 0;
        return;
    }

    // Clearing a single entry tombstones it in place; `handleNotificationList`
    // skips `id == 0`.
    //
    // `count` is deliberately left alone. It is the width of the ring window,
    // not a tally of live entries, so decrementing it here shrank the window
    // and silently dropped the *oldest* notification as well as the target.
    //
    // Only the live window is scanned: slots outside it hold stale entries
    // whose ids could still match and tombstone the wrong thing.
    const target_id = id.?;
    var scanned: usize = 0;
    var ring_idx: usize = if (self.write_pos == 0) MAX_NOTIFICATIONS - 1 else self.write_pos - 1;
    while (scanned < self.count) : (scanned += 1) {
        const n = &self.notifications[ring_idx];
        if (n.id == target_id) {
            n.id = 0;
            return;
        }
        ring_idx = if (ring_idx == 0) MAX_NOTIFICATIONS - 1 else ring_idx - 1;
    }
}
