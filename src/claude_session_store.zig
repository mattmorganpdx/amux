const std = @import("std");

const log = std.log.scoped(.claude_session);

const Allocator = std.mem.Allocator;

pub const ClaudeSessionStore = @This();

pub const Record = struct {
    workspace_id: u64,
    surface_id: u64,
    cwd: [512]u8 = [_]u8{0} ** 512,
    cwd_len: usize = 0,
    last_subtitle: [256]u8 = [_]u8{0} ** 256,
    last_subtitle_len: usize = 0,
    last_body: [256]u8 = [_]u8{0} ** 256,
    last_body_len: usize = 0,
    updated_at: i64,

    fn setCwd(self: *Record, value: []const u8) void {
        const len = @min(value.len, self.cwd.len);
        @memcpy(self.cwd[0..len], value[0..len]);
        self.cwd_len = len;
    }

    fn setLastSubtitle(self: *Record, value: []const u8) void {
        const len = @min(value.len, self.last_subtitle.len);
        @memcpy(self.last_subtitle[0..len], value[0..len]);
        self.last_subtitle_len = len;
    }

    fn setLastBody(self: *Record, value: []const u8) void {
        const len = @min(value.len, self.last_body.len);
        @memcpy(self.last_body[0..len], value[0..len]);
        self.last_body_len = len;
    }

    pub fn getLastSubtitle(self: *const Record) ?[]const u8 {
        if (self.last_subtitle_len == 0) return null;
        return self.last_subtitle[0..self.last_subtitle_len];
    }

    pub fn getLastBody(self: *const Record) ?[]const u8 {
        if (self.last_body_len == 0) return null;
        return self.last_body[0..self.last_body_len];
    }
};

/// Maps session_id (heap-duped key) to Record.
sessions: std.StringHashMap(Record),
alloc: Allocator,
mutex: std.Thread.Mutex = .{},

pub fn init(alloc: Allocator) ClaudeSessionStore {
    return .{
        .sessions = std.StringHashMap(Record).init(alloc),
        .alloc = alloc,
    };
}

pub fn deinit(self: *ClaudeSessionStore) void {
    // Free all heap-duped keys.
    var it = self.sessions.keyIterator();
    while (it.next()) |key_ptr| {
        self.alloc.free(key_ptr.*);
    }
    self.sessions.deinit();
}

/// Insert or update a session record.
pub fn upsert(
    self: *ClaudeSessionStore,
    session_id: []const u8,
    workspace_id: u64,
    surface_id: u64,
    cwd: ?[]const u8,
) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    // Lazy prune: remove entries older than 24 hours.
    self.pruneUnlocked(24 * 3600);

    if (self.sessions.getPtr(session_id)) |existing| {
        existing.workspace_id = workspace_id;
        existing.surface_id = surface_id;
        existing.updated_at = std.time.timestamp();
        if (cwd) |c| existing.setCwd(c);
        return;
    }

    // New entry: heap-dupe the key.
    const key = self.alloc.dupe(u8, session_id) catch {
        log.err("Failed to allocate session key", .{});
        return;
    };

    var record = Record{
        .workspace_id = workspace_id,
        .surface_id = surface_id,
        .updated_at = std.time.timestamp(),
    };
    if (cwd) |c| record.setCwd(c);

    self.sessions.put(key, record) catch {
        self.alloc.free(key);
        log.err("Failed to insert session record", .{});
    };
}

/// Look up a session by ID. Returns a copy of the record (safe across threads).
pub fn lookup(self: *ClaudeSessionStore, session_id: []const u8) ?Record {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.sessions.get(session_id)) |rec| {
        return rec;
    }
    return null;
}

/// Remove and return a session record.
/// Tries exact session_id match first, then falls back to workspace_id+surface_id.
pub fn consume(
    self: *ClaudeSessionStore,
    session_id: ?[]const u8,
    workspace_id: ?u64,
    surface_id: ?u64,
) ?Record {
    self.mutex.lock();
    defer self.mutex.unlock();

    // Try exact session_id match first.
    if (session_id) |sid| {
        if (self.sessions.fetchRemove(sid)) |kv| {
            self.alloc.free(kv.key);
            return kv.value;
        }
    }

    // Fallback: match by workspace_id + surface_id.
    // Find the matching key first, then remove after iteration to avoid
    // modifying the HashMap while iterating.
    if (workspace_id) |ws_id| {
        var match_key: ?[]const u8 = null;
        var match_record: ?Record = null;
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.workspace_id == ws_id) {
                if (surface_id == null or entry.value_ptr.surface_id == surface_id.?) {
                    match_key = entry.key_ptr.*;
                    match_record = entry.value_ptr.*;
                    break;
                }
            }
        }
        if (match_key) |key| {
            _ = self.sessions.fetchRemove(key);
            self.alloc.free(key);
            return match_record;
        }
    }

    return null;
}

/// Update the last_subtitle and last_body fields for a session.
pub fn updateMessage(
    self: *ClaudeSessionStore,
    session_id: ?[]const u8,
    workspace_id: ?u64,
    subtitle: ?[]const u8,
    body: ?[]const u8,
) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const rec = blk: {
        if (session_id) |sid| {
            if (self.sessions.getPtr(sid)) |r| break :blk r;
        }
        // Fallback: find by workspace_id.
        if (workspace_id) |ws_id| {
            var it = self.sessions.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.workspace_id == ws_id) break :blk entry.value_ptr;
            }
        }
        return;
    };

    rec.updated_at = std.time.timestamp();
    if (subtitle) |s| rec.setLastSubtitle(s);
    if (body) |b| rec.setLastBody(b);
}

/// Remove entries older than max_age_seconds. Caller must hold mutex.
fn pruneUnlocked(self: *ClaudeSessionStore, max_age_seconds: i64) void {
    const now = std.time.timestamp();
    var to_remove: [64][]const u8 = undefined;
    var remove_count: usize = 0;

    var it = self.sessions.iterator();
    while (it.next()) |entry| {
        if (now - entry.value_ptr.updated_at > max_age_seconds) {
            if (remove_count < to_remove.len) {
                to_remove[remove_count] = entry.key_ptr.*;
                remove_count += 1;
            }
        }
    }

    for (to_remove[0..remove_count]) |key| {
        _ = self.sessions.fetchRemove(key);
        self.alloc.free(key);
    }

    if (remove_count > 0) {
        log.info("Pruned {d} stale claude session(s)", .{remove_count});
    }
}
