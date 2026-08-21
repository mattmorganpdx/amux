//! Terminal session archive, in SQLite.
//!
//! Why a database rather than the file-per-session layout `src/history.zig`
//! uses: search there means loading an index and grepping every file, and
//! retention means rewriting the index. Neither answers the questions this is
//! for -- what did that agent run, in which workspace, when -- without reading
//! everything. SQLite gives real queries, FTS5 gives full-text search, and it
//! is one file with no server.
//!
//! Where search lives, since there are two kinds:
//!
//!   - **live scrollback**: `ghostty-vt` exports `search` over a pane's own
//!     PageList. That is find-in-this-terminal, answered by the pane, and is
//!     not this module's job.
//!   - **closed sessions**: this archive. Once a pane is gone its scrollback
//!     only exists here.
//!
//! The boundary is the pane's lifetime, and nothing is searched twice.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("sqlite3.h");
});

const History = @This();

const log = std.log.scoped(.history);

/// Sessions kept before the oldest are pruned.
const default_max_entries: usize = 5000;

/// Largest scrollback stored per session.
const default_max_bytes: usize = 10 * 1024 * 1024;

alloc: Allocator,
db: ?*c.sqlite3 = null,
/// FTS5 is a compile-time option in SQLite. When it is missing we fall back to
/// LIKE, which is slower but correct, rather than failing to open at all.
fts: bool = false,

pub const Error = error{
    OpenFailed,
    QueryFailed,
    Disabled,
};

/// Metadata for one archived session. `content` is fetched separately: a list
/// of a few thousand sessions should not drag megabytes of scrollback with it.
pub const Entry = struct {
    id: i64,
    workspace_id: u64,
    workspace_title: []const u8,
    pane_id: u64,
    closed_at: i64,
    cwd: []const u8,
    reason: []const u8,
    lines: usize,
    bytes: usize,

    pub fn deinit(self: *const Entry, alloc: Allocator) void {
        alloc.free(self.workspace_title);
        alloc.free(self.cwd);
        alloc.free(self.reason);
    }
};

pub fn freeEntries(alloc: Allocator, entries: []const Entry) void {
    for (entries) |e| e.deinit(alloc);
    alloc.free(entries);
}

pub const Record = struct {
    workspace_id: u64,
    workspace_title: []const u8,
    pane_id: u64,
    cwd: []const u8,
    reason: []const u8,
    content: []const u8,
};

pub fn isDisabled() bool {
    const v = std.posix.getenv("AMUX_HISTORY_DISABLED") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

fn maxEntries() usize {
    const v = std.posix.getenv("AMUX_HISTORY_MAX_ENTRIES") orelse return default_max_entries;
    return std.fmt.parseInt(usize, v, 10) catch default_max_entries;
}

fn maxBytes() usize {
    const v = std.posix.getenv("AMUX_HISTORY_MAX_BYTES") orelse return default_max_bytes;
    return std.fmt.parseInt(usize, v, 10) catch default_max_bytes;
}

/// Open (creating if needed) the archive at `path`.
pub fn open(alloc: Allocator, path: []const u8) !History {
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);

    var db: ?*c.sqlite3 = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
    if (c.sqlite3_open_v2(path_z.ptr, &db, flags, null) != c.SQLITE_OK) {
        log.err("cannot open {s}: {s}", .{ path, c.sqlite3_errmsg(db) });
        _ = c.sqlite3_close(db);
        return error.OpenFailed;
    }

    var self: History = .{ .alloc = alloc, .db = db };
    errdefer self.close();

    // WAL so a reader never blocks the writer that is archiving a closing pane.
    try self.exec("PRAGMA journal_mode=WAL");
    try self.exec("PRAGMA synchronous=NORMAL");
    try self.exec(
        \\CREATE TABLE IF NOT EXISTS sessions (
        \\  id              INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  workspace_id    INTEGER NOT NULL,
        \\  workspace_title TEXT    NOT NULL,
        \\  pane_id         INTEGER NOT NULL,
        \\  closed_at       INTEGER NOT NULL,
        \\  cwd             TEXT    NOT NULL,
        \\  reason          TEXT    NOT NULL,
        \\  lines           INTEGER NOT NULL,
        \\  bytes           INTEGER NOT NULL,
        \\  content         TEXT    NOT NULL
        \\)
    );
    try self.exec("CREATE INDEX IF NOT EXISTS idx_sessions_closed_at ON sessions(closed_at DESC)");
    try self.exec("CREATE INDEX IF NOT EXISTS idx_sessions_workspace ON sessions(workspace_id)");

    // External-content FTS5: the index points at `sessions` rather than keeping
    // a second copy of every scrollback.
    self.fts = blk: {
        self.exec(
            \\CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
            \\  content, content='sessions', content_rowid='id'
            \\)
        ) catch {
            log.warn("FTS5 unavailable; history search will use LIKE", .{});
            break :blk false;
        };
        try self.exec(
            \\CREATE TRIGGER IF NOT EXISTS sessions_ai AFTER INSERT ON sessions BEGIN
            \\  INSERT INTO sessions_fts(rowid, content) VALUES (new.id, new.content);
            \\END
        );
        try self.exec(
            \\CREATE TRIGGER IF NOT EXISTS sessions_ad AFTER DELETE ON sessions BEGIN
            \\  INSERT INTO sessions_fts(sessions_fts, rowid, content)
            \\  VALUES ('delete', old.id, old.content);
            \\END
        );
        break :blk true;
    };

    return self;
}

pub fn close(self: *History) void {
    if (self.db) |db| {
        _ = c.sqlite3_close(db);
        self.db = null;
    }
}

/// Archive a session. Returns its id, or null if nothing was stored.
pub fn record(self: *History, rec: Record) !?i64 {
    if (isDisabled()) return null;

    // A pane that only ever showed a prompt is not worth keeping.
    const trimmed = std.mem.trim(u8, rec.content, " \r\n\t");
    if (trimmed.len == 0) return null;

    // Keep the tail, and cut on a UTF-8 boundary so the stored text stays valid.
    const limit = maxBytes();
    var content = rec.content;
    if (content.len > limit) {
        var start = content.len - limit;
        while (start < content.len and (content[start] & 0xC0) == 0x80) start += 1;
        content = content[start..];
    }

    // Skip a byte-identical repeat for the same pane: closing and reopening
    // without doing anything should not add an entry.
    if (try self.isDuplicate(rec.workspace_id, rec.pane_id, content)) {
        log.debug("skipping duplicate scrollback for ws{d}/pane{d}", .{ rec.workspace_id, rec.pane_id });
        return null;
    }

    var lines: usize = 0;
    for (content) |ch| {
        if (ch == '\n') lines += 1;
    }
    if (content.len > 0 and content[content.len - 1] != '\n') lines += 1;

    const sql =
        \\INSERT INTO sessions
        \\  (workspace_id, workspace_title, pane_id, closed_at, cwd, reason, lines, bytes, content)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ;
    const stmt = try self.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(rec.workspace_id));
    _ = bindText(stmt, 2, rec.workspace_title);
    _ = c.sqlite3_bind_int64(stmt, 3, @intCast(rec.pane_id));
    _ = c.sqlite3_bind_int64(stmt, 4, std.time.timestamp());
    _ = bindText(stmt, 5, rec.cwd);
    _ = bindText(stmt, 6, rec.reason);
    _ = c.sqlite3_bind_int64(stmt, 7, @intCast(lines));
    _ = c.sqlite3_bind_int64(stmt, 8, @intCast(content.len));
    _ = bindText(stmt, 9, content);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        log.err("insert failed: {s}", .{c.sqlite3_errmsg(self.db)});
        return error.QueryFailed;
    }

    const id = c.sqlite3_last_insert_rowid(self.db);
    try self.prune();
    log.info("archived session {d} (ws{d}/pane{d}, {d} lines)", .{ id, rec.workspace_id, rec.pane_id, lines });
    return id;
}

fn isDuplicate(self: *History, workspace_id: u64, pane_id: u64, content: []const u8) !bool {
    const stmt = try self.prepare(
        \\SELECT content FROM sessions
        \\WHERE workspace_id = ? AND pane_id = ?
        \\ORDER BY id DESC LIMIT 1
    );
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(workspace_id));
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(pane_id));

    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return false;
    const prev = columnText(stmt, 0);
    return std.mem.eql(u8, prev, content);
}

/// Metadata for recent sessions, newest first.
pub fn list(self: *History, alloc: Allocator, workspace_id: ?u64, limit: usize) ![]Entry {
    const sql = if (workspace_id != null)
        \\SELECT id, workspace_id, workspace_title, pane_id, closed_at, cwd, reason, lines, bytes
        \\FROM sessions WHERE workspace_id = ? ORDER BY closed_at DESC, id DESC LIMIT ?
    else
        \\SELECT id, workspace_id, workspace_title, pane_id, closed_at, cwd, reason, lines, bytes
        \\FROM sessions ORDER BY closed_at DESC, id DESC LIMIT ?
    ;
    const stmt = try self.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);

    if (workspace_id) |w| {
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(w));
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(limit));
    } else {
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(limit));
    }

    var out: std.ArrayListUnmanaged(Entry) = .{};
    errdefer {
        for (out.items) |e| e.deinit(alloc);
        out.deinit(alloc);
    }
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        try out.append(alloc, .{
            .id = c.sqlite3_column_int64(stmt, 0),
            .workspace_id = @intCast(c.sqlite3_column_int64(stmt, 1)),
            .workspace_title = try alloc.dupe(u8, columnText(stmt, 2)),
            .pane_id = @intCast(c.sqlite3_column_int64(stmt, 3)),
            .closed_at = c.sqlite3_column_int64(stmt, 4),
            .cwd = try alloc.dupe(u8, columnText(stmt, 5)),
            .reason = try alloc.dupe(u8, columnText(stmt, 6)),
            .lines = @intCast(c.sqlite3_column_int64(stmt, 7)),
            .bytes = @intCast(c.sqlite3_column_int64(stmt, 8)),
        });
    }
    return out.toOwnedSlice(alloc);
}

/// The stored scrollback for one session. Caller owns it.
pub fn get(self: *History, alloc: Allocator, id: i64) !?[]const u8 {
    const stmt = try self.prepare("SELECT content FROM sessions WHERE id = ?");
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, id);

    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return try alloc.dupe(u8, columnText(stmt, 0));
}

/// Sessions whose scrollback matches `query`, newest first.
pub fn search(self: *History, alloc: Allocator, query: []const u8, limit: usize) ![]Entry {
    // FTS5 when available. The LIKE path exists because FTS5 is a compile-time
    // option and a missing one should degrade, not break.
    const sql = if (self.fts)
        \\SELECT s.id, s.workspace_id, s.workspace_title, s.pane_id, s.closed_at,
        \\       s.cwd, s.reason, s.lines, s.bytes
        \\FROM sessions_fts f JOIN sessions s ON s.id = f.rowid
        \\WHERE sessions_fts MATCH ? ORDER BY s.closed_at DESC LIMIT ?
    else
        \\SELECT id, workspace_id, workspace_title, pane_id, closed_at, cwd, reason, lines, bytes
        \\FROM sessions WHERE content LIKE ? ORDER BY closed_at DESC LIMIT ?
    ;
    const stmt = try self.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);

    if (self.fts) {
        _ = bindText(stmt, 1, query);
    } else {
        const pattern = try std.fmt.allocPrint(alloc, "%{s}%", .{query});
        defer alloc.free(pattern);
        _ = bindText(stmt, 1, pattern);
    }
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(limit));

    var out: std.ArrayListUnmanaged(Entry) = .{};
    errdefer {
        for (out.items) |e| e.deinit(alloc);
        out.deinit(alloc);
    }
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        try out.append(alloc, .{
            .id = c.sqlite3_column_int64(stmt, 0),
            .workspace_id = @intCast(c.sqlite3_column_int64(stmt, 1)),
            .workspace_title = try alloc.dupe(u8, columnText(stmt, 2)),
            .pane_id = @intCast(c.sqlite3_column_int64(stmt, 3)),
            .closed_at = c.sqlite3_column_int64(stmt, 4),
            .cwd = try alloc.dupe(u8, columnText(stmt, 5)),
            .reason = try alloc.dupe(u8, columnText(stmt, 6)),
            .lines = @intCast(c.sqlite3_column_int64(stmt, 7)),
            .bytes = @intCast(c.sqlite3_column_int64(stmt, 8)),
        });
    }
    return out.toOwnedSlice(alloc);
}

pub fn delete(self: *History, id: i64) !bool {
    const stmt = try self.prepare("DELETE FROM sessions WHERE id = ?");
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.QueryFailed;
    return c.sqlite3_changes(self.db) > 0;
}

pub fn count(self: *History) !usize {
    const stmt = try self.prepare("SELECT COUNT(*) FROM sessions");
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
    return @intCast(c.sqlite3_column_int64(stmt, 0));
}

/// Drop the oldest sessions beyond the retention limit.
fn prune(self: *History) !void {
    const stmt = try self.prepare(
        \\DELETE FROM sessions WHERE id NOT IN (
        \\  SELECT id FROM sessions ORDER BY closed_at DESC, id DESC LIMIT ?
        \\)
    );
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(maxEntries()));
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.QueryFailed;
    const removed = c.sqlite3_changes(self.db);
    if (removed > 0) log.info("pruned {d} old session(s)", .{removed});
}

// --- sqlite plumbing ---------------------------------------------------

fn exec(self: *History, sql: [:0]const u8) !void {
    var err_msg: [*c]u8 = null;
    if (c.sqlite3_exec(self.db, sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
        if (err_msg != null) {
            log.err("exec failed: {s}", .{err_msg});
            c.sqlite3_free(err_msg);
        }
        return error.QueryFailed;
    }
}

fn prepare(self: *History, sql: [:0]const u8) !?*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        log.err("prepare failed: {s}\n  sql: {s}", .{ c.sqlite3_errmsg(self.db), sql });
        return error.QueryFailed;
    }
    return stmt;
}

/// SQLITE_TRANSIENT: sqlite copies the bytes, so the caller's buffer does not
/// have to outlive the statement.
fn bindText(stmt: ?*c.sqlite3_stmt, index: c_int, text: []const u8) c_int {
    return c.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))));
}

fn columnText(stmt: ?*c.sqlite3_stmt, index: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, index) orelse return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, index));
    return ptr[0..len];
}

// --- tests -------------------------------------------------------------

extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn testOpen(alloc: Allocator, tag: []const u8, buf: []u8) !History {
    // Retention and the kill switch are read from the environment, so make the
    // tests independent of the surrounding shell.
    _ = unsetenv("AMUX_HISTORY_DISABLED");
    _ = unsetenv("AMUX_HISTORY_MAX_ENTRIES");
    _ = unsetenv("AMUX_HISTORY_MAX_BYTES");

    const path = try std.fmt.bufPrint(buf, "/tmp/amux-histtest-{d}-{s}.db", .{
        std.os.linux.getpid(), tag,
    });
    std.fs.deleteFileAbsolute(path) catch {};
    return open(alloc, path);
}

fn testClose(h: *History, buf: []const u8) void {
    h.close();
    // WAL leaves companions behind.
    var extra: [96]u8 = undefined;
    for ([_][]const u8{ "", "-wal", "-shm" }) |suffix| {
        const p = std.fmt.bufPrint(&extra, "{s}{s}", .{ buf, suffix }) catch continue;
        std.fs.deleteFileAbsolute(p) catch {};
    }
}

fn sample(content: []const u8) Record {
    return .{
        .workspace_id = 1,
        .workspace_title = "ws",
        .pane_id = 7,
        .cwd = "/tmp",
        .reason = "pane_close",
        .content = content,
    };
}

test "archives a session and reads its scrollback back" {
    const alloc = std.testing.allocator;
    var buf: [96]u8 = undefined;
    var h = try testOpen(alloc, "roundtrip", &buf);
    const path = std.mem.sliceTo(&buf, 0);
    defer testClose(&h, path);

    const id = (try h.record(sample("line one\nline two\n"))).?;

    const content = (try h.get(alloc, id)).?;
    defer alloc.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "line two") != null);

    const entries = try h.list(alloc, null, 10);
    defer freeEntries(alloc, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u64, 7), entries[0].pane_id);
    try std.testing.expectEqual(@as(usize, 2), entries[0].lines);
    try std.testing.expectEqualStrings("pane_close", entries[0].reason);
    try std.testing.expectEqualStrings("ws", entries[0].workspace_title);
    // Every column is written by a live path, so every column is read back.
    try std.testing.expectEqualStrings("/tmp", entries[0].cwd);
    try std.testing.expect(entries[0].closed_at > 0);
}

test "full-text search finds a session by its contents" {
    const alloc = std.testing.allocator;
    var buf: [96]u8 = undefined;
    var h = try testOpen(alloc, "search", &buf);
    const path = std.mem.sliceTo(&buf, 0);
    defer testClose(&h, path);

    _ = try h.record(sample("deploying the frontend to staging\n"));
    _ = try h.record(.{
        .workspace_id = 2,
        .workspace_title = "other",
        .pane_id = 8,
        .cwd = "/tmp",
        .reason = "pane_close",
        .content = "running the database migration\n",
    });

    const hits = try h.search(alloc, "migration", 10);
    defer freeEntries(alloc, hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(u64, 2), hits[0].workspace_id);

    const misses = try h.search(alloc, "kubernetes", 10);
    defer freeEntries(alloc, misses);
    try std.testing.expectEqual(@as(usize, 0), misses.len);
}

test "listing can be scoped to one workspace" {
    const alloc = std.testing.allocator;
    var buf: [96]u8 = undefined;
    var h = try testOpen(alloc, "scoped", &buf);
    const path = std.mem.sliceTo(&buf, 0);
    defer testClose(&h, path);

    _ = try h.record(sample("in workspace one\n"));
    _ = try h.record(.{
        .workspace_id = 42,
        .workspace_title = "w42",
        .pane_id = 9,
        .cwd = "/tmp",
        .reason = "workspace_close",
        .content = "in workspace forty two\n",
    });

    const scoped = try h.list(alloc, 42, 10);
    defer freeEntries(alloc, scoped);
    try std.testing.expectEqual(@as(usize, 1), scoped.len);
    try std.testing.expectEqual(@as(u64, 42), scoped[0].workspace_id);
}

test "an unchanged pane does not archive twice" {
    const alloc = std.testing.allocator;
    var buf: [96]u8 = undefined;
    var h = try testOpen(alloc, "dedup", &buf);
    const path = std.mem.sliceTo(&buf, 0);
    defer testClose(&h, path);

    const first = try h.record(sample("identical output\n"));
    try std.testing.expect(first != null);

    // Closing and reopening without doing anything should not pile up entries.
    const second = try h.record(sample("identical output\n"));
    try std.testing.expect(second == null);
    try std.testing.expectEqual(@as(usize, 1), try h.count());

    // A different pane with the same text is a different session.
    const other = try h.record(.{
        .workspace_id = 1,
        .workspace_title = "ws",
        .pane_id = 99,
        .cwd = "/tmp",
        .reason = "pane_close",
        .content = "identical output\n",
    });
    try std.testing.expect(other != null);
}

test "a pane that only showed a prompt is not archived" {
    const alloc = std.testing.allocator;
    var buf: [96]u8 = undefined;
    var h = try testOpen(alloc, "blank", &buf);
    const path = std.mem.sliceTo(&buf, 0);
    defer testClose(&h, path);

    try std.testing.expect(try h.record(sample("")) == null);
    try std.testing.expect(try h.record(sample("   \n\n  \t ")) == null);
    try std.testing.expectEqual(@as(usize, 0), try h.count());
}

test "deleting removes the session and its search index entry" {
    const alloc = std.testing.allocator;
    var buf: [96]u8 = undefined;
    var h = try testOpen(alloc, "delete", &buf);
    const path = std.mem.sliceTo(&buf, 0);
    defer testClose(&h, path);

    const id = (try h.record(sample("findable marker text\n"))).?;
    try std.testing.expect(try h.delete(id));
    try std.testing.expect(!try h.delete(id));
    try std.testing.expect(try h.get(alloc, id) == null);

    // The FTS trigger has to keep up, or deleted sessions keep matching.
    const hits = try h.search(alloc, "findable", 10);
    defer freeEntries(alloc, hits);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}

test "retention drops the oldest sessions" {
    const alloc = std.testing.allocator;
    var buf: [96]u8 = undefined;
    var h = try testOpen(alloc, "prune", &buf);
    const path = std.mem.sliceTo(&buf, 0);
    defer testClose(&h, path);

    _ = setenv("AMUX_HISTORY_MAX_ENTRIES", "3", 1);
    defer _ = unsetenv("AMUX_HISTORY_MAX_ENTRIES");

    for (0..6) |i| {
        var content: [64]u8 = undefined;
        _ = try h.record(.{
            .workspace_id = 1,
            .workspace_title = "ws",
            .pane_id = @intCast(i),
            .cwd = "/tmp",
            .reason = "pane_close",
            .content = try std.fmt.bufPrint(&content, "session number {d}\n", .{i}),
        });
    }

    try std.testing.expectEqual(@as(usize, 3), try h.count());
    // The survivors are the newest.
    const kept = try h.list(alloc, null, 10);
    defer freeEntries(alloc, kept);
    try std.testing.expectEqual(@as(u64, 5), kept[0].pane_id);
}

test "oversized scrollback is truncated to the tail" {
    const alloc = std.testing.allocator;
    var buf: [96]u8 = undefined;
    var h = try testOpen(alloc, "truncate", &buf);
    const path = std.mem.sliceTo(&buf, 0);
    defer testClose(&h, path);

    _ = setenv("AMUX_HISTORY_MAX_BYTES", "64", 1);
    defer _ = unsetenv("AMUX_HISTORY_MAX_BYTES");

    const big = try alloc.alloc(u8, 512);
    defer alloc.free(big);
    @memset(big, 'x');
    @memcpy(big[500..512], "TAIL_MARKER\n");

    const id = (try h.record(sample(big))).?;
    const stored = (try h.get(alloc, id)).?;
    defer alloc.free(stored);

    try std.testing.expect(stored.len <= 64);
    // The end is what matters: it is the most recent output.
    try std.testing.expect(std.mem.indexOf(u8, stored, "TAIL_MARKER") != null);
}

test "history can be switched off entirely" {
    const alloc = std.testing.allocator;
    var buf: [96]u8 = undefined;
    var h = try testOpen(alloc, "disabled", &buf);
    const path = std.mem.sliceTo(&buf, 0);
    defer testClose(&h, path);

    _ = setenv("AMUX_HISTORY_DISABLED", "1", 1);
    defer _ = unsetenv("AMUX_HISTORY_DISABLED");

    try std.testing.expect(try h.record(sample("should not be stored\n")) == null);
    try std.testing.expectEqual(@as(usize, 0), try h.count());
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
