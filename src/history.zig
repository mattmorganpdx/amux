const std = @import("std");

const log = std.log.scoped(.history);

const Allocator = std.mem.Allocator;

/// A single history entry's metadata.
pub const HistoryEntry = struct {
    id: []const u8, // "{unix_timestamp}_ws{ws_id}_p{pane_id}"
    workspace_id: u64,
    workspace_title: []const u8,
    pane_id: u64,
    closed_at: i64, // unix timestamp
    lines: usize,
    bytes: usize,
    cwd: []const u8,
    reason: []const u8, // "pane_close", "workspace_close", "app_exit"
};

/// The index file stored at ~/.config/cmux/history/index.json
pub const HistoryIndex = struct {
    version: u32 = 1,
    entries: std.ArrayListUnmanaged(HistoryEntry) = .{},
};

/// Default limits (overridable by env vars).
const default_max_entries: usize = 100;
const default_max_bytes: usize = 10 * 1024 * 1024; // 10MB

fn isDisabled() bool {
    const val = std.posix.getenv("CMUX_HISTORY_DISABLED") orelse return false;
    return std.mem.eql(u8, val, "1");
}

fn getMaxEntries() usize {
    const val = std.posix.getenv("CMUX_HISTORY_MAX_ENTRIES") orelse return default_max_entries;
    return std.fmt.parseInt(usize, val, 10) catch default_max_entries;
}

fn getMaxBytes() usize {
    const val = std.posix.getenv("CMUX_HISTORY_MAX_BYTES") orelse return default_max_bytes;
    return std.fmt.parseInt(usize, val, 10) catch default_max_bytes;
}

/// Get the history directory: $XDG_CONFIG_HOME/cmux/history or ~/.config/cmux/history
fn historyDir(buf: *[4096]u8) ?[]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/cmux/history", .{xdg}) catch null;
    }
    if (std.posix.getenv("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.config/cmux/history", .{home}) catch null;
    }
    return null;
}

fn indexFilePath(buf: *[4096]u8) ?[]const u8 {
    var dir_buf: [4096]u8 = undefined;
    const dir = historyDir(&dir_buf) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/index.json", .{dir}) catch null;
}

pub fn entryFilePathPub(buf: *[4096]u8, id: []const u8) ?[]const u8 {
    return entryFilePath(buf, id);
}

fn entryFilePath(buf: *[4096]u8, id: []const u8) ?[]const u8 {
    var dir_buf: [4096]u8 = undefined;
    const dir = historyDir(&dir_buf) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/{s}.txt", .{ dir, id }) catch null;
}

/// Save scrollback text for a terminal pane.
/// Returns the allocated history entry ID, or null if nothing was saved.
pub fn saveScrollback(
    alloc: Allocator,
    text: []const u8,
    workspace_id: u64,
    workspace_title: []const u8,
    pane_id: u64,
    cwd: []const u8,
    reason: []const u8,
) !?[]const u8 {
    if (isDisabled()) return null;

    const max_bytes = getMaxBytes();
    const save_text = if (text.len > max_bytes) text[text.len - max_bytes ..] else text;

    if (save_text.len == 0) return null;

    // Skip if scrollback is just a single line (e.g. bare prompt after session restore)
    var newline_count: usize = 0;
    for (save_text) |ch| {
        if (ch == '\n') newline_count += 1;
    }
    if (newline_count <= 1) return null;

    // Generate entry ID
    const timestamp = std.time.timestamp();
    var id_buf: [128]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{d}_ws{d}_p{d}", .{ timestamp, workspace_id, pane_id }) catch return null;

    // Ensure history directory exists
    var dir_buf: [4096]u8 = undefined;
    const dir = historyDir(&dir_buf) orelse return null;
    std.fs.cwd().makePath(dir) catch |err| {
        log.warn("Failed to create history dir: {}", .{err});
        return null;
    };

    // Line count (reuse newline_count from above)
    const line_count = if (save_text.len > 0 and save_text[save_text.len - 1] != '\n')
        newline_count + 1
    else
        newline_count;

    // Write scrollback text file atomically
    var txt_path_buf: [4096]u8 = undefined;
    const txt_path = entryFilePath(&txt_path_buf, id) orelse return null;

    var tmp_path_buf: [4096]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{txt_path}) catch return null;

    const tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch |err| {
        log.warn("Failed to create history temp file: {}", .{err});
        return null;
    };
    tmp_file.writeAll(save_text) catch |err| {
        tmp_file.close();
        log.warn("Failed to write history text: {}", .{err});
        return null;
    };
    tmp_file.close();

    std.fs.cwd().rename(tmp_path, txt_path) catch |err| {
        log.warn("Failed to rename history text file: {}", .{err});
        return null;
    };

    // Load existing index, append entry, prune, write back
    var index = loadIndex(alloc) catch HistoryIndex{};
    defer freeIndex(alloc, &index);

    const entry = HistoryEntry{
        .id = try alloc.dupe(u8, id),
        .workspace_id = workspace_id,
        .workspace_title = try alloc.dupe(u8, workspace_title),
        .pane_id = pane_id,
        .closed_at = timestamp,
        .lines = line_count,
        .bytes = save_text.len,
        .cwd = try alloc.dupe(u8, cwd),
        .reason = try alloc.dupe(u8, reason),
    };
    try index.entries.append(alloc, entry);

    // Prune old entries
    const max_entries = getMaxEntries();
    while (index.entries.items.len > max_entries) {
        const old = index.entries.orderedRemove(0);
        deleteEntryFile(old.id);
        freeEntry(alloc, &old);
    }

    writeIndex(alloc, &index) catch |err| {
        log.warn("Failed to write history index: {}", .{err});
        return null;
    };

    log.info("History saved: {s} ({d} lines, {d} bytes)", .{ id, line_count, save_text.len });
    return try alloc.dupe(u8, id);
}

/// Load the history index from disk.
pub fn loadIndex(alloc: Allocator) !HistoryIndex {
    var path_buf: [4096]u8 = undefined;
    const path = indexFilePath(&path_buf) orelse return error.NoConfigDir;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    const json = file.readToEndAlloc(alloc, 2 * 1024 * 1024) catch |err| {
        log.warn("Failed to read history index: {}", .{err});
        return err;
    };
    defer alloc.free(json);

    return deserializeIndex(alloc, json);
}

/// Load the text content of a specific history entry.
pub fn loadEntryText(alloc: Allocator, id: []const u8) ![]const u8 {
    var path_buf: [4096]u8 = undefined;
    const path = entryFilePath(&path_buf, id) orelse return error.NoConfigDir;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    return file.readToEndAlloc(alloc, 50 * 1024 * 1024) catch |err| {
        log.warn("Failed to read history entry {s}: {}", .{ id, err });
        return err;
    };
}

/// Delete a history entry (both text file and index entry).
pub fn deleteEntry(alloc: Allocator, id: []const u8) !void {
    deleteEntryFile(id);

    var index = loadIndex(alloc) catch return;
    defer freeIndex(alloc, &index);

    var found: ?usize = null;
    for (index.entries.items, 0..) |e, i| {
        if (std.mem.eql(u8, e.id, id)) {
            found = i;
            break;
        }
    }
    if (found) |idx| {
        const old = index.entries.orderedRemove(idx);
        freeEntry(alloc, &old);
        writeIndex(alloc, &index) catch {};
    }
}

/// Search across all history entries for a query string.
pub fn searchEntries(alloc: Allocator, query: []const u8) ![]const HistoryEntry {
    var index = try loadIndex(alloc);
    // Don't free the index — we return borrowed entries. Caller gets owned copies below.
    defer {
        // Free entries we don't return
        index.entries.deinit(alloc);
    }

    var results = std.ArrayListUnmanaged(HistoryEntry){};

    for (index.entries.items) |entry| {
        // Check metadata first
        var found = false;
        if (std.mem.indexOf(u8, entry.workspace_title, query) != null) found = true;
        if (std.mem.indexOf(u8, entry.cwd, query) != null) found = true;
        if (std.mem.indexOf(u8, entry.id, query) != null) found = true;

        // Check scrollback content
        if (!found) {
            const text = loadEntryText(alloc, entry.id) catch continue;
            defer alloc.free(text);
            if (std.mem.indexOf(u8, text, query) != null) found = true;
        }

        if (found) {
            // Clone the entry for the result
            try results.append(alloc, HistoryEntry{
                .id = try alloc.dupe(u8, entry.id),
                .workspace_id = entry.workspace_id,
                .workspace_title = try alloc.dupe(u8, entry.workspace_title),
                .pane_id = entry.pane_id,
                .closed_at = entry.closed_at,
                .lines = entry.lines,
                .bytes = entry.bytes,
                .cwd = try alloc.dupe(u8, entry.cwd),
                .reason = try alloc.dupe(u8, entry.reason),
            });
        } else {
            freeEntry(alloc, &entry);
        }
    }

    return results.toOwnedSlice(alloc);
}

pub fn freeSearchResults(alloc: Allocator, results: []const HistoryEntry) void {
    for (results) |e| {
        freeEntry(alloc, &e);
    }
    alloc.free(results);
}

// ------------------------------------------------------------------
// Serialization
// ------------------------------------------------------------------

fn serializeIndex(alloc: Allocator, index: *const HistoryIndex) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(alloc);

    try buf.appendSlice(alloc, "{\"version\":");
    try appendInt(alloc, &buf, @intCast(index.version));
    try buf.appendSlice(alloc, ",\"entries\":[");

    for (index.entries.items, 0..) |entry, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.append(alloc, '{');

        try buf.appendSlice(alloc, "\"id\":");
        try appendJsonString(alloc, &buf, entry.id);

        try buf.appendSlice(alloc, ",\"workspace_id\":");
        try appendInt(alloc, &buf, @intCast(entry.workspace_id));

        try buf.appendSlice(alloc, ",\"workspace_title\":");
        try appendJsonString(alloc, &buf, entry.workspace_title);

        try buf.appendSlice(alloc, ",\"pane_id\":");
        try appendInt(alloc, &buf, @intCast(entry.pane_id));

        try buf.appendSlice(alloc, ",\"closed_at\":");
        try appendInt(alloc, &buf, entry.closed_at);

        try buf.appendSlice(alloc, ",\"lines\":");
        try appendInt(alloc, &buf, @intCast(entry.lines));

        try buf.appendSlice(alloc, ",\"bytes\":");
        try appendInt(alloc, &buf, @intCast(entry.bytes));

        try buf.appendSlice(alloc, ",\"cwd\":");
        try appendJsonString(alloc, &buf, entry.cwd);

        try buf.appendSlice(alloc, ",\"reason\":");
        try appendJsonString(alloc, &buf, entry.reason);

        try buf.append(alloc, '}');
    }

    try buf.appendSlice(alloc, "]}");
    return buf.toOwnedSlice(alloc);
}

fn deserializeIndex(alloc: Allocator, json: []const u8) !HistoryIndex {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidFormat;

    var index = HistoryIndex{};

    const entries_val = root.object.get("entries") orelse return error.InvalidFormat;
    if (entries_val != .array) return error.InvalidFormat;

    for (entries_val.array.items) |item| {
        if (item != .object) continue;

        const entry = HistoryEntry{
            .id = try alloc.dupe(u8, getJsonString(item, "id") orelse continue),
            .workspace_id = @intCast(getJsonInt(item, "workspace_id") orelse continue),
            .workspace_title = try alloc.dupe(u8, getJsonString(item, "workspace_title") orelse ""),
            .pane_id = @intCast(getJsonInt(item, "pane_id") orelse continue),
            .closed_at = getJsonInt(item, "closed_at") orelse 0,
            .lines = @intCast(getJsonInt(item, "lines") orelse 0),
            .bytes = @intCast(getJsonInt(item, "bytes") orelse 0),
            .cwd = try alloc.dupe(u8, getJsonString(item, "cwd") orelse ""),
            .reason = try alloc.dupe(u8, getJsonString(item, "reason") orelse ""),
        };
        try index.entries.append(alloc, entry);
    }

    return index;
}

// ------------------------------------------------------------------
// JSON helpers (matching session.zig patterns)
// ------------------------------------------------------------------

fn appendInt(alloc: Allocator, buf: *std.ArrayListUnmanaged(u8), val: i64) !void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch return;
    try buf.appendSlice(alloc, s);
}

fn appendJsonString(alloc: Allocator, buf: *std.ArrayListUnmanaged(u8), val: []const u8) !void {
    try buf.append(alloc, '"');
    for (val) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, ch),
        }
    }
    try buf.append(alloc, '"');
}

fn getJsonString(val: std.json.Value, key: []const u8) ?[]const u8 {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getJsonInt(val: std.json.Value, key: []const u8) ?i64 {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    return switch (v) {
        .integer => v.integer,
        .float => @intFromFloat(v.float),
        else => null,
    };
}

// ------------------------------------------------------------------
// File I/O helpers
// ------------------------------------------------------------------

fn writeIndex(alloc: Allocator, index: *const HistoryIndex) !void {
    var dir_buf: [4096]u8 = undefined;
    const dir = historyDir(&dir_buf) orelse return error.NoConfigDir;

    std.fs.cwd().makePath(dir) catch |err| {
        log.warn("Failed to create history dir: {}", .{err});
        return err;
    };

    const json = try serializeIndex(alloc, index);
    defer alloc.free(json);

    var tmp_path_buf: [4096]u8 = undefined;
    var file_path_buf: [4096]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}/index.json.tmp", .{dir}) catch return error.PathTooLong;
    const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/index.json", .{dir}) catch return error.PathTooLong;

    const tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch |err| {
        log.warn("Failed to create temp index file: {}", .{err});
        return err;
    };
    tmp_file.writeAll(json) catch |err| {
        tmp_file.close();
        log.warn("Failed to write index data: {}", .{err});
        return err;
    };
    tmp_file.close();

    std.fs.cwd().rename(tmp_path, file_path) catch |err| {
        log.warn("Failed to rename index file: {}", .{err});
        return err;
    };
}

fn deleteEntryFile(id: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    const path = entryFilePath(&path_buf, id) orelse return;
    std.fs.cwd().deleteFile(path) catch {};
}

fn freeEntry(alloc: Allocator, entry: *const HistoryEntry) void {
    alloc.free(entry.id);
    alloc.free(entry.workspace_title);
    alloc.free(entry.cwd);
    alloc.free(entry.reason);
}

pub fn freeIndex(alloc: Allocator, index: *HistoryIndex) void {
    for (index.entries.items) |e| {
        freeEntry(alloc, &e);
    }
    index.entries.deinit(alloc);
}
