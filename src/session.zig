const std = @import("std");
const c = @import("c.zig");
const TabManager = @import("tab_manager.zig");
const Workspace = @import("workspace.zig");
const PaneTree = @import("pane_tree.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.session);

// ------------------------------------------------------------------
// Snapshot types
// ------------------------------------------------------------------

pub const SessionSnapshot = struct {
    version: u32 = 1,
    selected_workspace_index: ?usize,
    next_workspace_id: u64,
    workspaces: []WorkspaceSnapshot,
};

pub const WorkspaceSnapshot = struct {
    id: u64,
    title: []const u8,
    cwd: []const u8,
    pinned: bool,
    color: []const u8,
    focused_pane: ?u64,
    next_node_id: u64,
    layout: ?LayoutSnapshot,
};

pub const LayoutSnapshot = union(enum) {
    pane: PaneLayoutSnapshot,
    split: SplitLayoutSnapshot,
};

pub const PaneLayoutSnapshot = struct {
    id: u64,
    history_id: []const u8 = "",
};

pub const SplitLayoutSnapshot = struct {
    id: u64,
    orientation: PaneTree.Orientation,
    divider_position: f64,
    first: *LayoutSnapshot,
    second: *LayoutSnapshot,
};

// ------------------------------------------------------------------
// Capture (runtime state -> snapshot)
// ------------------------------------------------------------------

const HistoryMap = std.AutoHashMap(PaneTree.NodeId, []const u8);

pub fn captureSession(alloc: Allocator, tm: *TabManager) !SessionSnapshot {
    return captureSessionWithHistory(alloc, tm, null);
}

pub fn captureSessionWithHistory(alloc: Allocator, tm: *TabManager, history_ids: ?*const HistoryMap) !SessionSnapshot {
    var ws_snapshots: std.ArrayListUnmanaged(WorkspaceSnapshot) = .{};
    defer ws_snapshots.deinit(alloc);

    for (tm.workspaces.items) |ws| {
        const snap = try captureWorkspace(alloc, ws, history_ids);
        try ws_snapshots.append(alloc, snap);
    }

    return .{
        .version = 1,
        .selected_workspace_index = tm.selected_index,
        .next_workspace_id = tm.next_id,
        .workspaces = try ws_snapshots.toOwnedSlice(alloc),
    };
}

fn captureWorkspace(alloc: Allocator, ws: *Workspace, history_ids: ?*const HistoryMap) !WorkspaceSnapshot {
    const layout = if (ws.pane_tree.root) |root_id|
        try captureLayout(alloc, &ws.pane_tree, root_id, history_ids)
    else
        null;

    return .{
        .id = ws.id,
        .title = try alloc.dupe(u8, ws.getTitle()),
        .cwd = try alloc.dupe(u8, if (ws.cwd_len > 0) ws.cwd_buf[0..ws.cwd_len] else ""),
        .pinned = ws.pinned,
        .color = try alloc.dupe(u8, ws.getColor() orelse ""),
        .focused_pane = ws.pane_tree.focused_pane,
        .next_node_id = ws.pane_tree.getNextId(),
        .layout = layout,
    };
}

fn captureLayout(alloc: Allocator, tree: *const PaneTree, node_id: PaneTree.NodeId, history_ids: ?*const HistoryMap) !LayoutSnapshot {
    const node = tree.getNode(node_id) orelse return error.InvalidTree;
    switch (node) {
        .pane => |p| {
            const hist_id = if (history_ids) |hm| (hm.get(p.id) orelse "") else "";
            return .{ .pane = .{
                .id = p.id,
                .history_id = try alloc.dupe(u8, hist_id),
            } };
        },
        .split => |s| {
            const first = try alloc.create(LayoutSnapshot);
            first.* = try captureLayout(alloc, tree, s.first, history_ids);
            const second = try alloc.create(LayoutSnapshot);
            second.* = try captureLayout(alloc, tree, s.second, history_ids);
            return .{ .split = .{
                .id = s.id,
                .orientation = s.orientation,
                .divider_position = s.divider_position,
                .first = first,
                .second = second,
            } };
        },
    }
}

// ------------------------------------------------------------------
// JSON serialization (snapshot -> JSON string)
// ------------------------------------------------------------------

const Buf = std.ArrayListUnmanaged(u8);

pub fn serializeSession(alloc: Allocator, snap: *const SessionSnapshot) ![]const u8 {
    var buf: Buf = .{};
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "{\"version\":");
    try appendInt(alloc, &buf, snap.version);
    try buf.appendSlice(alloc, ",\"selected_workspace_index\":");
    if (snap.selected_workspace_index) |idx| {
        try appendInt(alloc, &buf, idx);
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.appendSlice(alloc, ",\"next_workspace_id\":");
    try appendInt(alloc, &buf, snap.next_workspace_id);
    try buf.appendSlice(alloc, ",\"workspaces\":[");

    for (snap.workspaces, 0..) |*ws, i| {
        if (i > 0) try buf.append(alloc, ',');
        try serializeWorkspace(alloc, &buf, ws);
    }

    try buf.appendSlice(alloc, "]}");
    return try buf.toOwnedSlice(alloc);
}

fn serializeWorkspace(alloc: Allocator, buf: *Buf, ws: *const WorkspaceSnapshot) !void {
    try buf.appendSlice(alloc, "{\"id\":");
    try appendInt(alloc, buf, ws.id);
    try buf.appendSlice(alloc, ",\"title\":");
    try appendJsonString(alloc, buf, ws.title);
    try buf.appendSlice(alloc, ",\"cwd\":");
    try appendJsonString(alloc, buf, ws.cwd);
    try buf.appendSlice(alloc, ",\"pinned\":");
    try buf.appendSlice(alloc, if (ws.pinned) "true" else "false");
    try buf.appendSlice(alloc, ",\"color\":");
    try appendJsonString(alloc, buf, ws.color);
    try buf.appendSlice(alloc, ",\"focused_pane\":");
    if (ws.focused_pane) |fp| {
        try appendInt(alloc, buf, fp);
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.appendSlice(alloc, ",\"next_node_id\":");
    try appendInt(alloc, buf, ws.next_node_id);
    try buf.appendSlice(alloc, ",\"layout\":");
    if (ws.layout) |layout| {
        try serializeLayout(alloc, buf, &layout);
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.append(alloc, '}');
}

fn serializeLayout(alloc: Allocator, buf: *Buf, layout: *const LayoutSnapshot) !void {
    switch (layout.*) {
        .pane => |p| {
            try buf.appendSlice(alloc, "{\"type\":\"pane\",\"id\":");
            try appendInt(alloc, buf, p.id);
            if (p.history_id.len > 0) {
                try buf.appendSlice(alloc, ",\"history_id\":");
                try appendJsonString(alloc, buf, p.history_id);
            }
            try buf.append(alloc, '}');
        },
        .split => |s| {
            try buf.appendSlice(alloc, "{\"type\":\"split\",\"id\":");
            try appendInt(alloc, buf, s.id);
            try buf.appendSlice(alloc, ",\"orientation\":");
            try appendJsonString(alloc, buf, @tagName(s.orientation));
            try buf.appendSlice(alloc, ",\"divider_position\":");
            try appendFloat(alloc, buf, s.divider_position);
            try buf.appendSlice(alloc, ",\"first\":");
            try serializeLayout(alloc, buf, s.first);
            try buf.appendSlice(alloc, ",\"second\":");
            try serializeLayout(alloc, buf, s.second);
            try buf.append(alloc, '}');
        },
    }
}

fn appendInt(alloc: Allocator, buf: *Buf, val: anytype) !void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch return error.OutOfMemory;
    try buf.appendSlice(alloc, s);
}

fn appendFloat(alloc: Allocator, buf: *Buf, val: f64) !void {
    var tmp: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d:.6}", .{val}) catch return error.OutOfMemory;
    try buf.appendSlice(alloc, s);
}

fn appendJsonString(alloc: Allocator, buf: *Buf, val: []const u8) !void {
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

// ------------------------------------------------------------------
// JSON deserialization (JSON string -> snapshot)
// ------------------------------------------------------------------

pub fn deserializeSession(alloc: Allocator, json: []const u8) !SessionSnapshot {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidSession;

    const version = getJsonInt(root, "version") orelse 1;
    if (version != 1) return error.UnsupportedVersion;

    const selected = getJsonOptionalInt(root, "selected_workspace_index");
    const next_ws_id: u64 = @intCast(getJsonInt(root, "next_workspace_id") orelse 1);

    const ws_array = root.object.get("workspaces") orelse return error.MissingWorkspaces;
    if (ws_array != .array) return error.InvalidWorkspaces;

    var workspaces: std.ArrayListUnmanaged(WorkspaceSnapshot) = .{};
    defer workspaces.deinit(alloc);

    for (ws_array.array.items) |ws_val| {
        const ws_snap = try deserializeWorkspace(alloc, ws_val);
        try workspaces.append(alloc, ws_snap);
    }

    return .{
        .version = @intCast(version),
        .selected_workspace_index = if (selected) |s| @intCast(s) else null,
        .next_workspace_id = next_ws_id,
        .workspaces = try workspaces.toOwnedSlice(alloc),
    };
}

fn deserializeWorkspace(alloc: Allocator, val: std.json.Value) !WorkspaceSnapshot {
    if (val != .object) return error.InvalidWorkspace;

    const id: u64 = @intCast(getJsonInt(val, "id") orelse return error.MissingId);
    const title = getJsonString(val, "title") orelse "Workspace";
    const cwd = getJsonString(val, "cwd") orelse "";
    const pinned = getJsonBool(val, "pinned") orelse false;
    const color = getJsonString(val, "color") orelse "";
    const focused_pane = getJsonOptionalInt(val, "focused_pane");
    const next_node_id: u64 = @intCast(getJsonInt(val, "next_node_id") orelse 1);

    const layout_val = val.object.get("layout");
    const layout: ?LayoutSnapshot = if (layout_val) |lv| blk: {
        if (lv == .null) break :blk null;
        break :blk try deserializeLayout(alloc, lv);
    } else null;

    return .{
        .id = id,
        .title = try alloc.dupe(u8, title),
        .cwd = try alloc.dupe(u8, cwd),
        .pinned = pinned,
        .color = try alloc.dupe(u8, color),
        .focused_pane = if (focused_pane) |fp| @intCast(fp) else null,
        .next_node_id = next_node_id,
        .layout = layout,
    };
}

fn deserializeLayout(alloc: Allocator, val: std.json.Value) !LayoutSnapshot {
    if (val != .object) return error.InvalidLayout;

    const type_str = getJsonString(val, "type") orelse return error.MissingType;

    if (std.mem.eql(u8, type_str, "pane")) {
        const id: u64 = @intCast(getJsonInt(val, "id") orelse return error.MissingId);
        const hist_id = getJsonString(val, "history_id") orelse "";
        return .{ .pane = .{
            .id = id,
            .history_id = try alloc.dupe(u8, hist_id),
        } };
    } else if (std.mem.eql(u8, type_str, "split")) {
        const id: u64 = @intCast(getJsonInt(val, "id") orelse return error.MissingId);
        const orient_str = getJsonString(val, "orientation") orelse return error.MissingOrientation;
        const orientation: PaneTree.Orientation = if (std.mem.eql(u8, orient_str, "horizontal"))
            .horizontal
        else if (std.mem.eql(u8, orient_str, "vertical"))
            .vertical
        else
            return error.InvalidOrientation;

        const div_pos = getJsonFloat(val, "divider_position") orelse 0.5;

        const first_val = val.object.get("first") orelse return error.MissingSplitChild;
        const second_val = val.object.get("second") orelse return error.MissingSplitChild;

        const first = try alloc.create(LayoutSnapshot);
        first.* = try deserializeLayout(alloc, first_val);
        const second = try alloc.create(LayoutSnapshot);
        second.* = try deserializeLayout(alloc, second_val);

        return .{ .split = .{
            .id = id,
            .orientation = orientation,
            .divider_position = div_pos,
            .first = first,
            .second = second,
        } };
    } else {
        return error.UnknownLayoutType;
    }
}

// JSON helper functions
fn getJsonInt(val: std.json.Value, key: []const u8) ?i64 {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    return switch (v) {
        .integer => v.integer,
        .float => @intFromFloat(v.float),
        else => null,
    };
}

fn getJsonOptionalInt(val: std.json.Value, key: []const u8) ?i64 {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    return switch (v) {
        .integer => v.integer,
        .float => @intFromFloat(v.float),
        .null => null,
        else => null,
    };
}

fn getJsonFloat(val: std.json.Value, key: []const u8) ?f64 {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => null,
    };
}

fn getJsonString(val: std.json.Value, key: []const u8) ?[]const u8 {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getJsonBool(val: std.json.Value, key: []const u8) ?bool {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    return switch (v) {
        .bool => v.bool,
        else => null,
    };
}

// ------------------------------------------------------------------
// File I/O
// ------------------------------------------------------------------

/// Get the session file path: $XDG_CONFIG_HOME/amux/session.json or ~/.config/amux/session.json
fn sessionDir(buf: *[4096]u8) ?[]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        const len = std.fmt.bufPrint(buf, "{s}/cmux", .{xdg}) catch return null;
        return len;
    }
    if (std.posix.getenv("HOME")) |home| {
        const len = std.fmt.bufPrint(buf, "{s}/.config/cmux", .{home}) catch return null;
        return len;
    }
    return null;
}

fn sessionFilePath(buf: *[4096]u8) ?[]const u8 {
    var dir_buf: [4096]u8 = undefined;
    const dir = sessionDir(&dir_buf) orelse return null;
    const path = std.fmt.bufPrint(buf, "{s}/session.json", .{dir}) catch return null;
    return path;
}

/// Write session snapshot to disk atomically (write to .tmp, then rename).
pub fn writeSessionFile(alloc: Allocator, snap: *const SessionSnapshot) !void {
    var dir_buf: [4096]u8 = undefined;
    const dir = sessionDir(&dir_buf) orelse return error.NoConfigDir;

    // Ensure directory exists
    std.fs.cwd().makePath(dir) catch |err| {
        log.warn("Failed to create session dir: {}", .{err});
        return err;
    };

    const json = try serializeSession(alloc, snap);
    defer alloc.free(json);

    // Write to temp file
    var tmp_path_buf: [4096]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}/session.json.tmp", .{dir}) catch return error.PathTooLong;

    var file_path_buf: [4096]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/session.json", .{dir}) catch return error.PathTooLong;

    // Write tmp file
    const tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch |err| {
        log.warn("Failed to create temp session file: {}", .{err});
        return err;
    };
    tmp_file.writeAll(json) catch |err| {
        tmp_file.close();
        log.warn("Failed to write session data: {}", .{err});
        return err;
    };
    tmp_file.close();

    // Atomic rename
    std.fs.cwd().rename(tmp_path, file_path) catch |err| {
        log.warn("Failed to rename session file: {}", .{err});
        return err;
    };

    log.info("Session saved ({d} workspaces, {d} bytes)", .{ snap.workspaces.len, json.len });
}

/// Load session snapshot from disk.
pub fn loadSessionFile(alloc: Allocator) !SessionSnapshot {
    var path_buf: [4096]u8 = undefined;
    const path = sessionFilePath(&path_buf) orelse return error.NoConfigDir;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        log.info("No session file found: {}", .{err});
        return err;
    };
    defer file.close();

    const json = file.readToEndAlloc(alloc, 1024 * 1024) catch |err| {
        log.warn("Failed to read session file: {}", .{err});
        return err;
    };
    defer alloc.free(json);

    return deserializeSession(alloc, json);
}

// ------------------------------------------------------------------
// Autosave callback (called from g_timeout_add_seconds)
// ------------------------------------------------------------------

pub fn onAutosave(userdata: c.gpointer) callconv(.c) c.gboolean {
    const Window = @import("window.zig");
    const window: *Window = @ptrCast(@alignCast(userdata));

    const alloc = std.heap.c_allocator;
    const snap = captureSessionWithHistory(alloc, &window.tab_manager, &window.pane_history_ids) catch |err| {
        log.warn("Failed to capture session: {}", .{err});
        return 1; // keep firing
    };
    defer freeSessionSnapshot(alloc, &snap);

    writeSessionFile(alloc, &snap) catch |err| {
        log.warn("Failed to write session: {}", .{err});
    };

    return 1; // G_SOURCE_CONTINUE
}

pub fn freeSessionSnapshot(alloc: Allocator, snap: *const SessionSnapshot) void {
    for (snap.workspaces) |*ws| {
        alloc.free(ws.title);
        alloc.free(ws.cwd);
        alloc.free(ws.color);
        if (ws.layout) |layout| {
            freeLayout(alloc, &layout);
        }
    }
    alloc.free(snap.workspaces);
}

fn freeLayout(alloc: Allocator, layout: *const LayoutSnapshot) void {
    switch (layout.*) {
        .pane => |p| {
            if (p.history_id.len > 0) alloc.free(p.history_id);
        },
        .split => |s| {
            freeLayout(alloc, s.first);
            alloc.destroy(s.first);
            freeLayout(alloc, s.second);
            alloc.destroy(s.second);
        },
    }
}

// ------------------------------------------------------------------
// Restore helpers (build runtime state from snapshot)
// ------------------------------------------------------------------

/// Restore a PaneTree from a layout snapshot.
/// Returns the root node id if layout was present.
pub fn restorePaneTree(tree: *PaneTree, ws_snap: *const WorkspaceSnapshot) !?PaneTree.NodeId {
    const layout = ws_snap.layout orelse return null;
    const root_id = try restoreLayoutNode(tree, &layout, null);
    tree.root = root_id;
    tree.setNextId(ws_snap.next_node_id);
    tree.focused_pane = ws_snap.focused_pane;
    return root_id;
}

fn restoreLayoutNode(tree: *PaneTree, layout: *const LayoutSnapshot, parent: ?PaneTree.NodeId) !PaneTree.NodeId {
    switch (layout.*) {
        .pane => |p| {
            try tree.nodes.put(p.id, .{ .pane = .{
                .id = p.id,
                .parent = parent,
            } });
            return p.id;
        },
        .split => |s| {
            // First, insert a placeholder split node
            const first_id = try restoreLayoutNode(tree, s.first, s.id);
            const second_id = try restoreLayoutNode(tree, s.second, s.id);

            try tree.nodes.put(s.id, .{ .split = .{
                .id = s.id,
                .parent = parent,
                .orientation = s.orientation,
                .divider_position = s.divider_position,
                .first = first_id,
                .second = second_id,
            } });

            return s.id;
        },
    }
}

/// Check if session restore is disabled by environment variable.
pub fn isRestoreDisabled() bool {
    const val = std.posix.getenv("CMUX_DISABLE_SESSION_RESTORE") orelse return false;
    return std.mem.eql(u8, val, "1");
}
