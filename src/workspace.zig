const std = @import("std");
const PaneTree = @import("pane_tree.zig");

const log = std.log.scoped(.workspace);

/// A workspace groups a set of panes (split layout) together.
/// Workspaces are shown in the sidebar and can be switched between.
pub const Workspace = @This();

const Allocator = std.mem.Allocator;

pub const WorkspaceId = u64;

id: WorkspaceId,
title: [256]u8 = [_]u8{0} ** 256,
title_len: usize = 0,
pinned: bool = false,

/// Accent color name (from predefined palette).
color: [32]u8 = [_]u8{0} ** 32,
color_len: usize = 0,

/// The pane tree managing the split layout for this workspace.
pane_tree: PaneTree,

/// Working directory buffer for new terminals in this workspace.
cwd_buf: [4096]u8 = [_]u8{0} ** 4096,
cwd_len: usize = 0,

/// Git branch name (polled from cwd).
git_branch: [128]u8 = [_]u8{0} ** 128,
git_branch_len: usize = 0,

/// Whether the git working tree has uncommitted changes.
git_dirty: bool = false,

/// Status entries: key-value pairs stored as packed "key\x00val\x00" pairs.
status_buf: [1024]u8 = [_]u8{0} ** 1024,
status_len: usize = 0,
status_count: usize = 0,

/// Log entries: packed "msg\x00" ring buffer of recent messages.
log_buf: [2048]u8 = [_]u8{0} ** 2048,
log_len: usize = 0,
log_count: usize = 0,

/// Progress bar fraction (0.0 = hidden, 0.01-1.0 = visible).
progress: f32 = 0.0,
progress_label: [128]u8 = [_]u8{0} ** 128,
progress_label_len: usize = 0,

pub fn init(alloc: Allocator, id: WorkspaceId) Workspace {
    return .{
        .id = id,
        .pane_tree = PaneTree.init(alloc),
    };
}

/// Initialize with a shared node ID counter (for use via TabManager).
pub fn initShared(alloc: Allocator, id: WorkspaceId, shared_next_node_id: *PaneTree.NodeId) Workspace {
    return .{
        .id = id,
        .pane_tree = PaneTree.initShared(alloc, shared_next_node_id),
    };
}

pub fn deinit(self: *Workspace) void {
    self.pane_tree.deinit();
}

pub fn setTitle(self: *Workspace, title: []const u8) void {
    const len = @min(title.len, self.title.len);
    @memcpy(self.title[0..len], title[0..len]);
    self.title_len = len;
}

pub fn getTitle(self: *const Workspace) []const u8 {
    if (self.title_len == 0) {
        return "Workspace";
    }
    return self.title[0..self.title_len];
}

/// Predefined color palette names.
pub const valid_colors = [_][]const u8{
    "red", "blue", "green", "yellow", "purple", "orange", "pink", "cyan",
};

pub fn setColor(self: *Workspace, name: []const u8) void {
    const len = @min(name.len, self.color.len);
    @memcpy(self.color[0..len], name[0..len]);
    self.color_len = len;
}

pub fn clearColor(self: *Workspace) void {
    self.color_len = 0;
}

pub fn getColor(self: *const Workspace) ?[]const u8 {
    if (self.color_len == 0) return null;
    return self.color[0..self.color_len];
}

/// Validate that a color name is in the predefined palette.
pub fn isValidColor(name: []const u8) bool {
    for (valid_colors) |c| {
        if (std.mem.eql(u8, name, c)) return true;
    }
    return false;
}

pub fn setGitBranch(self: *Workspace, branch: []const u8) void {
    const len = @min(branch.len, self.git_branch.len);
    @memcpy(self.git_branch[0..len], branch[0..len]);
    self.git_branch_len = len;
}

pub fn getGitBranch(self: *const Workspace) ?[]const u8 {
    if (self.git_branch_len == 0) return null;
    return self.git_branch[0..self.git_branch_len];
}

pub fn setCwd(self: *Workspace, path: []const u8) void {
    const len = @min(path.len, self.cwd_buf.len - 1);
    @memcpy(self.cwd_buf[0..len], path[0..len]);
    self.cwd_buf[len] = 0;
    self.cwd_len = len;
}

/// Get the cwd as a null-terminated C string, or null if unset.
pub fn getCwd(self: *Workspace) ?[*:0]const u8 {
    if (self.cwd_len == 0) return null;
    return @ptrCast(&self.cwd_buf);
}

/// Get the number of panes in this workspace.
pub fn paneCount(self: *const Workspace) usize {
    return self.pane_tree.paneCount();
}

// ------------------------------------------------------------------
// Metadata setters/getters
// ------------------------------------------------------------------

pub fn setGitDirty(self: *Workspace, dirty: bool) void {
    self.git_dirty = dirty;
}

/// Add or update a key-value status entry. If key exists, replace value.
pub fn setStatusEntry(self: *Workspace, key: []const u8, value: []const u8) void {
    // First try to find and replace existing key
    if (self.removeStatusEntryInternal(key)) {
        // Removed old entry, now add new one below
    }
    // Append "key\x00value\x00"
    const needed = key.len + 1 + value.len + 1;
    if (self.status_len + needed > self.status_buf.len) return; // buffer full
    @memcpy(self.status_buf[self.status_len..][0..key.len], key);
    self.status_len += key.len;
    self.status_buf[self.status_len] = 0;
    self.status_len += 1;
    @memcpy(self.status_buf[self.status_len..][0..value.len], value);
    self.status_len += value.len;
    self.status_buf[self.status_len] = 0;
    self.status_len += 1;
    self.status_count += 1;
}

/// Remove a specific status entry by key. Returns true if found and removed.
fn removeStatusEntryInternal(self: *Workspace, key: []const u8) bool {
    var pos: usize = 0;
    while (pos < self.status_len) {
        // Find key end
        const key_start = pos;
        var key_end = pos;
        while (key_end < self.status_len and self.status_buf[key_end] != 0) : (key_end += 1) {}
        const entry_key = self.status_buf[key_start..key_end];

        // Find value end
        const val_start = key_end + 1;
        var val_end = val_start;
        while (val_end < self.status_len and self.status_buf[val_end] != 0) : (val_end += 1) {}
        const entry_end = val_end + 1;

        if (std.mem.eql(u8, entry_key, key)) {
            // Shift remaining data left
            const remaining = self.status_len - entry_end;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.status_buf[key_start..], self.status_buf[entry_end..][0..remaining]);
            }
            self.status_len -= (entry_end - key_start);
            self.status_count -= 1;
            return true;
        }
        pos = entry_end;
    }
    return false;
}

/// Remove a status entry by key (public).
pub fn removeStatusEntry(self: *Workspace, key: []const u8) void {
    _ = self.removeStatusEntryInternal(key);
}

/// Clear all status entries.
pub fn clearStatus(self: *Workspace) void {
    self.status_len = 0;
    self.status_count = 0;
}

/// Iterator for status entries. Returns key-value pairs.
pub const StatusIterator = struct {
    buf: []const u8,
    pos: usize,

    pub fn next(self: *StatusIterator) ?struct { key: []const u8, value: []const u8 } {
        if (self.pos >= self.buf.len) return null;

        // Read key
        const key_start = self.pos;
        var key_end = self.pos;
        while (key_end < self.buf.len and self.buf[key_end] != 0) : (key_end += 1) {}
        if (key_end >= self.buf.len) return null;
        const key = self.buf[key_start..key_end];

        // Read value
        const val_start = key_end + 1;
        var val_end = val_start;
        while (val_end < self.buf.len and self.buf[val_end] != 0) : (val_end += 1) {}
        const value = self.buf[val_start..val_end];

        self.pos = val_end + 1;
        return .{ .key = key, .value = value };
    }
};

pub fn statusIterator(self: *const Workspace) StatusIterator {
    return .{ .buf = self.status_buf[0..self.status_len], .pos = 0 };
}

/// Add a log entry. If the buffer is full, drops oldest entries to make room.
pub fn addLogEntry(self: *Workspace, text: []const u8) void {
    const needed = text.len + 1; // text + null separator
    if (needed > self.log_buf.len) return; // single entry too large

    // Make room if needed by dropping oldest entries
    while (self.log_len + needed > self.log_buf.len) {
        // Find end of first entry
        var end: usize = 0;
        while (end < self.log_len and self.log_buf[end] != 0) : (end += 1) {}
        const remove = end + 1;
        const remaining = self.log_len - remove;
        if (remaining > 0) {
            std.mem.copyForwards(u8, &self.log_buf, self.log_buf[remove..][0..remaining]);
        }
        self.log_len -= remove;
        self.log_count -= 1;
    }

    @memcpy(self.log_buf[self.log_len..][0..text.len], text);
    self.log_len += text.len;
    self.log_buf[self.log_len] = 0;
    self.log_len += 1;
    self.log_count += 1;
}

/// Clear all log entries.
pub fn clearLog(self: *Workspace) void {
    self.log_len = 0;
    self.log_count = 0;
}

/// Get the most recent log entry.
pub fn lastLogEntry(self: *const Workspace) ?[]const u8 {
    if (self.log_count == 0) return null;
    // Walk backwards from end to find last entry start
    if (self.log_len < 2) return null;
    // log_buf ends with: ...text\x00
    // Start from log_len - 2 (skip trailing null) and search backwards for previous null or start
    var i: usize = self.log_len - 2;
    while (i > 0) : (i -= 1) {
        if (self.log_buf[i] == 0) {
            return self.log_buf[i + 1 .. self.log_len - 1];
        }
    }
    return self.log_buf[0 .. self.log_len - 1];
}

/// Set progress bar. fraction=0 hides it.
pub fn setProgress(self: *Workspace, fraction: f32, label: ?[]const u8) void {
    self.progress = std.math.clamp(fraction, 0.0, 1.0);
    if (label) |l| {
        const len = @min(l.len, self.progress_label.len);
        @memcpy(self.progress_label[0..len], l[0..len]);
        self.progress_label_len = len;
    } else {
        self.progress_label_len = 0;
    }
}

/// Clear progress bar.
pub fn clearProgress(self: *Workspace) void {
    self.progress = 0.0;
    self.progress_label_len = 0;
}

/// Get progress label if set.
pub fn getProgressLabel(self: *const Workspace) ?[]const u8 {
    if (self.progress_label_len == 0) return null;
    return self.progress_label[0..self.progress_label_len];
}
