//! Socket request handlers for the daemon.
//!
//! These are new rather than moved. The plan expected `src/socket/handlers/` to
//! come across largely as-is, and that held for the *protocol* -- `protocol.zig`
//! is reused unchanged, and the method names and response shapes match -- but
//! not for the bodies. The GUI's surface and pane handlers are written around
//! `Window`: they drive GtkPaned trees, rebuild the sidebar, and hop onto the
//! GTK main thread for every read. None of that exists here, so they are
//! rewritten against `State`.
//!
//! The upside is that `runOnMainThread`, the resolve-on-the-main-thread dance
//! and the leak-on-timeout contexts all disappear: there is no second thread to
//! defer to, so a handler just takes the state lock and does the work.
//!
//! Not implemented yet, deliberately: notifications, the command palette, the
//! Claude hooks and the sidebar metadata methods. All of those exist to drive
//! GUI chrome, and belong with item 6 when the GUI becomes a client.

const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("../socket/protocol.zig");
const PaneTree = @import("../pane_tree.zig");
const History = @import("History.zig");
const State = @import("State.zig");
const Registry = @import("Registry.zig");
const Workspace = @import("../workspace.zig");

const log = std.log.scoped(.daemon_handlers);

/// Methods this daemon answers. `system.capabilities` reports it, so a client
/// can tell what it is talking to.
const methods = [_][]const u8{
    "system.ping",
    "system.identify",
    "system.capabilities",
    "system.layout",
    "workspace.list",
    "workspace.create",
    "workspace.current",
    "workspace.select",
    "workspace.close",
    "workspace.rename",
    "workspace.metadata",
    "workspace.set_status",
    "workspace.clear_status",
    "workspace.add_log",
    "workspace.clear_log",
    "workspace.set_progress",
    "workspace.report_git",
    "workspace.set_color",
    "workspace.set_pinned",
    "notification.create",
    "notification.list",
    "notification.clear",
    "claude.hook",
    "surface.list",
    "surface.current",
    "surface.send_text",
    "surface.read_text",
    "surface.screen",
    "surface.output",
    "surface.input",
    "surface.resize",
    "surface.watch",
    "surface.send_key",
    "surface.split",
    "surface.close",
    "surface.run",
    "pane.list",
    "history.list",
    "history.show",
    "history.search",
    "history.delete",
};

/// Default and maximum rows returned by a history query.
const default_history_limit: usize = 50;
const max_history_limit: usize = 500;

pub fn dispatch(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const m = req.method;
    if (eq(m, "system.ping")) return protocol.successResponse(alloc, req.id, "{\"pong\":true}");
    if (eq(m, "system.capabilities")) return capabilities(alloc, req);
    if (eq(m, "system.identify")) return identify(alloc, state, req);
    if (eq(m, "system.layout")) return systemLayout(alloc, state, req);

    if (eq(m, "workspace.list")) return workspaceList(alloc, state, req);
    if (eq(m, "workspace.create")) return workspaceCreate(alloc, state, req);
    if (eq(m, "workspace.current")) return workspaceCurrent(alloc, state, req);
    if (eq(m, "workspace.select")) return workspaceSelect(alloc, state, req);
    if (eq(m, "workspace.close")) return workspaceClose(alloc, state, req);
    if (eq(m, "workspace.rename")) return workspaceRename(alloc, state, req);
    if (eq(m, "workspace.metadata")) return workspaceMetadata(alloc, state, req);
    if (eq(m, "workspace.set_status")) return workspaceSetStatus(alloc, state, req);
    if (eq(m, "workspace.clear_status")) return workspaceClearStatus(alloc, state, req);
    if (eq(m, "workspace.add_log")) return workspaceAddLog(alloc, state, req);
    if (eq(m, "workspace.clear_log")) return workspaceClearLog(alloc, state, req);
    if (eq(m, "workspace.set_progress")) return workspaceSetProgress(alloc, state, req);
    if (eq(m, "workspace.report_git")) return workspaceReportGit(alloc, state, req);
    if (eq(m, "workspace.set_color")) return workspaceSetColor(alloc, state, req);
    if (eq(m, "workspace.set_pinned")) return workspaceSetPinned(alloc, state, req);
    if (eq(m, "notification.create")) return notificationCreate(alloc, state, req);
    if (eq(m, "notification.list")) return notificationList(alloc, state, req);
    if (eq(m, "notification.clear")) return notificationClear(alloc, state, req);
    if (eq(m, "claude.hook")) return claudeHook(alloc, state, req);

    if (eq(m, "surface.list") or eq(m, "pane.list")) return paneList(alloc, state, req);
    if (eq(m, "surface.current")) return surfaceCurrent(alloc, state, req);
    if (eq(m, "surface.send_text")) return sendText(alloc, state, req);
    if (eq(m, "surface.read_text")) return readText(alloc, state, req);
    if (eq(m, "surface.screen")) return surfaceScreen(alloc, state, req);
    if (eq(m, "surface.output")) return surfaceOutput(alloc, state, req);
    if (eq(m, "surface.input")) return surfaceInput(alloc, state, req);
    if (eq(m, "surface.resize")) return surfaceResize(alloc, state, req);
    if (eq(m, "surface.watch")) return surfaceWatch(alloc, state, req);
    if (eq(m, "surface.send_key")) return sendKey(alloc, state, req);
    if (eq(m, "surface.split")) return split(alloc, state, req);
    if (eq(m, "surface.close")) return closePane(alloc, state, req);
    if (eq(m, "surface.run")) return run(alloc, state, req);

    if (eq(m, "history.list")) return historyList(alloc, state, req);
    if (eq(m, "history.show")) return historyShow(alloc, state, req);
    if (eq(m, "history.search")) return historySearch(alloc, state, req);
    if (eq(m, "history.delete")) return historyDelete(alloc, state, req);

    return protocol.errorResponse(alloc, req.id, "method_not_found", req.method);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Map a State error onto the wire vocabulary the GUI already used.
fn stateError(alloc: Allocator, id: i64, err: anyerror) ![]const u8 {
    return switch (err) {
        error.WorkspaceNotFound => protocol.errorResponse(alloc, id, "not_found", "Workspace not found"),
        error.PaneNotFound => protocol.errorResponse(alloc, id, "no_surface", "No target surface found"),
        error.NoWorkspace => protocol.errorResponse(alloc, id, "no_workspace", "No workspace selected"),
        error.LastPane => protocol.errorResponse(alloc, id, "last_pane", "Cannot close the last pane"),
        else => protocol.errorResponse(alloc, id, "internal_error", @errorName(err)),
    };
}

fn jsonEscape(alloc: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(alloc);
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (ch < 0x20) {
            var buf: [6]u8 = undefined;
            try out.appendSlice(alloc, std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch continue);
        } else try out.append(alloc, ch),
    };
    return out.toOwnedSlice(alloc);
}

fn toU64(v: i64) ?u64 {
    return if (v < 0) null else @intCast(v);
}

fn optionalIdParam(alloc: Allocator, req: *const protocol.Request, name: []const u8) ?u64 {
    const raw = req.getIntParam(alloc, name) orelse return null;
    return toU64(raw);
}

// --- system ------------------------------------------------------------

fn capabilities(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"methods\":[");
    for (methods, 0..) |m, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.append(alloc, '"');
        try out.appendSlice(alloc, m);
        try out.append(alloc, '"');
    }
    try out.appendSlice(alloc, "],\"daemon\":true}");
    return protocol.successResponse(alloc, req.id, out.items);
}

fn identify(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const ws_id = state.selectedWorkspaceId();
    const pane_id: ?u64 = state.resolvePane(null) catch null;

    const body = if (ws_id) |w|
        try std.fmt.allocPrint(alloc,
            \\{{"focused":{{"workspace_id":{d},"pane_id":{?d}}},"daemon":true}}
        , .{ w, pane_id })
    else
        try alloc.dupe(u8, "{\"focused\":null,\"daemon\":true}");
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

// --- workspaces --------------------------------------------------------

const WorkspaceJson = struct {
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    first: bool = true,

    fn append(self: *WorkspaceJson, ws: *Workspace, selected: bool, index: usize) anyerror!void {
        if (!self.first) try self.out.append(self.alloc, ',');
        self.first = false;

        const title = try jsonEscape(self.alloc, ws.getTitle());
        defer self.alloc.free(title);

        const json = try std.fmt.allocPrint(self.alloc,
            \\{{"id":{d},"ref":"workspace:{d}","title":"{s}","index":{d},"selected":{s},"pinned":{s},"pane_count":{d}
        , .{
            ws.id,
            ws.id,
            title,
            index,
            if (selected) "true" else "false",
            if (ws.pinned) "true" else "false",
            ws.pane_tree.paneCount(),
        });
        defer self.alloc.free(json);
        try self.out.appendSlice(self.alloc, json);

        // Metadata: only what is set, so a workspace nobody has reported on
        // stays as terse as it was before any of this existed.
        if (ws.getGitBranch()) |branch| {
            const esc = try jsonEscape(self.alloc, branch);
            defer self.alloc.free(esc);
            const git = try std.fmt.allocPrint(self.alloc, ",\"git_branch\":\"{s}\",\"git_dirty\":{s}", .{
                esc, if (ws.git_dirty) "true" else "false",
            });
            defer self.alloc.free(git);
            try self.out.appendSlice(self.alloc, git);
        }
        if (ws.progress > 0.0) {
            const prog = try std.fmt.allocPrint(self.alloc, ",\"progress\":{d:.3}", .{ws.progress});
            defer self.alloc.free(prog);
            try self.out.appendSlice(self.alloc, prog);
            if (ws.getProgressLabel()) |label| {
                const esc = try jsonEscape(self.alloc, label);
                defer self.alloc.free(esc);
                const lab = try std.fmt.allocPrint(self.alloc, ",\"progress_label\":\"{s}\"", .{esc});
                defer self.alloc.free(lab);
                try self.out.appendSlice(self.alloc, lab);
            }
        }
        if (ws.status_len > 0) try self.appendStatus(ws);
        if (ws.log_len > 0) try self.appendLog(ws);

        try self.out.append(self.alloc, '}');
    }

    /// Status entries are packed as NUL-separated key/value pairs, so unpacking
    /// them here is what turns them into something a client can read.
    fn appendStatus(self: *WorkspaceJson, ws: *Workspace) !void {
        try self.out.appendSlice(self.alloc, ",\"status\":{");
        var pos: usize = 0;
        var first_entry = true;
        while (pos < ws.status_len) {
            var key_end = pos;
            while (key_end < ws.status_len and ws.status_buf[key_end] != 0) : (key_end += 1) {}
            const key = ws.status_buf[pos..key_end];

            const val_start = key_end + 1;
            var val_end = val_start;
            while (val_end < ws.status_len and ws.status_buf[val_end] != 0) : (val_end += 1) {}
            if (val_start > ws.status_len) break;
            const value = ws.status_buf[val_start..@min(val_end, ws.status_len)];

            if (!first_entry) try self.out.append(self.alloc, ',');
            first_entry = false;

            const k = try jsonEscape(self.alloc, key);
            defer self.alloc.free(k);
            const v = try jsonEscape(self.alloc, value);
            defer self.alloc.free(v);
            const entry = try std.fmt.allocPrint(self.alloc, "\"{s}\":\"{s}\"", .{ k, v });
            defer self.alloc.free(entry);
            try self.out.appendSlice(self.alloc, entry);

            pos = val_end + 1;
        }
        try self.out.append(self.alloc, '}');
    }

    /// Log entries are NUL-separated lines.
    fn appendLog(self: *WorkspaceJson, ws: *Workspace) !void {
        try self.out.appendSlice(self.alloc, ",\"log\":[");
        var pos: usize = 0;
        var first_entry = true;
        while (pos < ws.log_len) {
            var end = pos;
            while (end < ws.log_len and ws.log_buf[end] != 0) : (end += 1) {}
            const line = ws.log_buf[pos..end];
            if (line.len > 0) {
                if (!first_entry) try self.out.append(self.alloc, ',');
                first_entry = false;
                const esc = try jsonEscape(self.alloc, line);
                defer self.alloc.free(esc);
                const item = try std.fmt.allocPrint(self.alloc, "\"{s}\"", .{esc});
                defer self.alloc.free(item);
                try self.out.appendSlice(self.alloc, item);
            }
            pos = end + 1;
        }
        try self.out.append(self.alloc, ']');
    }
};

/// The whole layout: workspaces, their pane trees and which is selected.
///
/// The body is the same JSON `session.zig` writes to disk, so a client restores
/// from the daemon using the code it already had for restoring from a file --
/// and pane node ids survive, which is what makes a client's pane ids and the
/// daemon's the same numbers.
///
/// `since` plus `timeout_ms` makes it a wait, so a GUI learns about a pane an
/// agent split from the CLI without polling for it.
fn systemLayout(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const since: u64 = if (req.getIntParam(alloc, "since")) |v| toU64(v) orelse 0 else 0;
    const timeout: u32 = if (req.getIntParam(alloc, "timeout_ms")) |v|
        @intCast(@max(0, @min(v, @as(i64, max_screen_timeout_ms))))
    else
        0;

    const res = state.layoutJson(alloc, since, timeout) catch |err|
        return stateError(alloc, req.id, err);

    if (res == null) {
        const body = try std.fmt.allocPrint(alloc, "{{\"seq\":{d},\"changed\":false}}", .{since});
        defer alloc.free(body);
        return protocol.successResponse(alloc, req.id, body);
    }

    defer alloc.free(res.?.json);
    const body = try std.fmt.allocPrint(
        alloc,
        "{{\"seq\":{d},\"layout\":{s}}}",
        .{ res.?.seq, res.?.json },
    );
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn workspaceList(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"workspaces\":[");

    var builder: WorkspaceJson = .{ .alloc = alloc, .out = &out };
    try state.withWorkspaces(&builder, WorkspaceJson.append);

    try out.appendSlice(alloc, "]}");
    return protocol.successResponse(alloc, req.id, out.items);
}

fn workspaceCurrent(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"workspace\":");

    var builder: WorkspaceJson = .{ .alloc = alloc, .out = &out };
    state.withWorkspace(null, &builder, WorkspaceJson.append) catch {
        return protocol.successResponse(alloc, req.id, "{\"workspace\":null}");
    };

    try out.append(alloc, '}');
    return protocol.successResponse(alloc, req.id, out.items);
}

fn workspaceCreate(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const title = req.getStringParam(alloc, "title");
    defer if (title) |t| alloc.free(t);
    const cwd = req.getStringParam(alloc, "cwd");
    defer if (cwd) |c| alloc.free(c);

    const id = state.createWorkspace(title, cwd) catch |err| return stateError(alloc, req.id, err);

    const body = try std.fmt.allocPrint(alloc, "{{\"workspace\":{{\"id\":{d}}}}}", .{id});
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn workspaceSelect(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const id = optionalIdParam(alloc, req, "id") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'id'");
    state.selectWorkspace(id) catch |err| return stateError(alloc, req.id, err);
    const body = try std.fmt.allocPrint(alloc, "{{\"selected\":{d}}}", .{id});
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn workspaceClose(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const id = optionalIdParam(alloc, req, "id") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'id'");
    state.closeWorkspace(id) catch |err| return stateError(alloc, req.id, err);
    return protocol.successResponse(alloc, req.id, "{\"closed\":true}");
}

fn workspaceRename(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const title = req.getStringParam(alloc, "title") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'title'");
    defer alloc.free(title);
    const id = optionalIdParam(alloc, req, "id");
    _ = state.renameWorkspace(id, title) catch |err| return stateError(alloc, req.id, err);
    return protocol.successResponse(alloc, req.id, "{\"renamed\":true}");
}

// --- panes / surfaces --------------------------------------------------

// ------------------------------------------------------------------
// Workspace metadata, notifications and Claude hooks
//
// These were GUI-only, which meant an agent could only report what it was doing
// while a window happened to be open. They belong to the daemon: it is what
// outlives the window.
// ------------------------------------------------------------------

/// Per-workspace metadata, with a sequence number to follow it by.
///
/// The same workspace objects `workspace.list` returns -- status, progress, git,
/// log -- but waitable, so a sidebar can track them without polling and without
/// being told about layout changes it does not care about.
fn workspaceMetadata(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const since: u64 = if (req.getIntParam(alloc, "since")) |v| toU64(v) orelse 0 else 0;
    const timeout: u32 = if (req.getIntParam(alloc, "timeout_ms")) |v|
        @intCast(@max(0, @min(v, @as(i64, max_screen_timeout_ms))))
    else
        0;

    const seq = state.waitForMeta(since, timeout) orelse {
        const body = try std.fmt.allocPrint(alloc, "{{\"seq\":{d},\"changed\":false}}", .{since});
        defer alloc.free(body);
        return protocol.successResponse(alloc, req.id, body);
    };

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    const head = try std.fmt.allocPrint(alloc, "{{\"seq\":{d},\"workspaces\":[", .{seq});
    defer alloc.free(head);
    try out.appendSlice(alloc, head);

    var builder: WorkspaceJson = .{ .alloc = alloc, .out = &out };
    try state.withWorkspaces(&builder, WorkspaceJson.append);
    try out.appendSlice(alloc, "]}");

    return protocol.successResponse(alloc, req.id, out.items);
}

/// A one-field reply naming the workspace that was changed.
fn okWorkspace(alloc: Allocator, id: i64, ws_id: u64) ![]const u8 {
    const body = try std.fmt.allocPrint(alloc, "{{\"workspace_id\":{d}}}", .{ws_id});
    defer alloc.free(body);
    return protocol.successResponse(alloc, id, body);
}

fn workspaceIdParam(alloc: Allocator, req: *const protocol.Request) ?u64 {
    return optionalIdParam(alloc, req, "workspace_id");
}

fn workspaceSetStatus(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const key = req.getStringParam(alloc, "key") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'key'");
    defer alloc.free(key);
    const value = req.getStringParam(alloc, "value") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'value'");
    defer alloc.free(value);

    const ws = state.setWorkspaceStatus(workspaceIdParam(alloc, req), key, value) catch |err|
        return stateError(alloc, req.id, err);
    return okWorkspace(alloc, req.id, ws);
}

fn workspaceClearStatus(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const ws = state.clearWorkspaceStatus(workspaceIdParam(alloc, req)) catch |err|
        return stateError(alloc, req.id, err);
    return okWorkspace(alloc, req.id, ws);
}

fn workspaceAddLog(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const text = req.getStringParam(alloc, "text") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'text'");
    defer alloc.free(text);

    const ws = state.addWorkspaceLog(workspaceIdParam(alloc, req), text) catch |err|
        return stateError(alloc, req.id, err);
    return okWorkspace(alloc, req.id, ws);
}

fn workspaceClearLog(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const ws = state.clearWorkspaceLog(workspaceIdParam(alloc, req)) catch |err|
        return stateError(alloc, req.id, err);
    return okWorkspace(alloc, req.id, ws);
}

fn workspaceSetProgress(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const frac = req.getFloatParam(alloc, "fraction") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'fraction'");
    const label = req.getStringParam(alloc, "label");
    defer if (label) |l| alloc.free(l);

    const clamped: f32 = @floatCast(@max(0.0, @min(1.0, frac)));
    const ws = state.setWorkspaceProgress(workspaceIdParam(alloc, req), clamped, label) catch |err|
        return stateError(alloc, req.id, err);
    return okWorkspace(alloc, req.id, ws);
}

fn workspaceReportGit(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const branch = req.getStringParam(alloc, "branch") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'branch'");
    defer alloc.free(branch);
    const dirty = req.getBoolParam(alloc, "dirty") orelse false;

    const ws = state.reportWorkspaceGit(workspaceIdParam(alloc, req), branch, dirty) catch |err|
        return stateError(alloc, req.id, err);
    return okWorkspace(alloc, req.id, ws);
}

fn workspaceSetColor(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const color = req.getStringParam(alloc, "color") orelse "";
    defer if (color.len > 0) alloc.free(color);

    const ws = state.setWorkspaceColor(workspaceIdParam(alloc, req), color) catch |err|
        return stateError(alloc, req.id, err);
    return okWorkspace(alloc, req.id, ws);
}

fn workspaceSetPinned(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const pinned = req.getBoolParam(alloc, "pinned") orelse true;
    const ws = state.setWorkspacePinned(workspaceIdParam(alloc, req), pinned) catch |err|
        return stateError(alloc, req.id, err);
    return okWorkspace(alloc, req.id, ws);
}

fn notificationCreate(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const title = req.getStringParam(alloc, "title") orelse try alloc.dupe(u8, "amux");
    defer alloc.free(title);
    const body_text = req.getStringParam(alloc, "body") orelse try alloc.dupe(u8, "");
    defer alloc.free(body_text);

    const id = state.notifications.add(title, body_text, workspaceIdParam(alloc, req));
    const body = try std.fmt.allocPrint(alloc, "{{\"id\":{d}}}", .{id});
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn notificationList(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const limit = historyLimit(alloc, req);
    const records = try state.notifications.list(alloc, limit);
    defer alloc.free(records);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"notifications\":[");
    var first = true;
    for (records) |rec| {
        if (rec.id == 0) continue; // cleared
        if (!first) try out.append(alloc, ',');
        first = false;

        const title = try jsonEscape(alloc, rec.titleSlice());
        defer alloc.free(title);
        const body_text = try jsonEscape(alloc, rec.bodySlice());
        defer alloc.free(body_text);

        const item = try std.fmt.allocPrint(alloc,
            \\{{"id":{d},"title":"{s}","body":"{s}","workspace_id":{?d},"at":{d}}}
        , .{ rec.id, title, body_text, rec.workspace_id, rec.at });
        defer alloc.free(item);
        try out.appendSlice(alloc, item);
    }
    try out.appendSlice(alloc, "]}");
    return protocol.successResponse(alloc, req.id, out.items);
}

fn notificationClear(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const id: ?u64 = if (req.getIntParam(alloc, "id")) |v| toU64(v) else null;
    const cleared = state.notifications.clear(id);
    const body = try std.fmt.allocPrint(alloc, "{{\"cleared\":{s}}}", .{
        if (cleared) "true" else "false",
    });
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

/// A Claude Code lifecycle hook.
///
/// Records what the agent is doing on the workspace, and leaves a notification
/// record for the events worth interrupting someone over. No desktop
/// notification: that needs libnotify and a session bus, which amuxd does not
/// link -- a GUI turns the records into desktop notifications, and when none is
/// running the record survives to be read afterwards.
fn claudeHook(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    // `subcommand` is the hook name the CLI sends (session-start, stop,
    // notification, prompt-submit); `event` is a field out of the hook's own
    // JSON payload and only sometimes present. The GUI's handler reads the same
    // field, so both front doors agree.
    const event = req.getStringParam(alloc, "subcommand") orelse
        req.getStringParam(alloc, "event") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'subcommand'");
    defer alloc.free(event);

    const message = req.getStringParam(alloc, "message");
    defer if (message) |m| alloc.free(m);

    const ws_param = workspaceIdParam(alloc, req);

    // The status word the sidebar shows, and whether it is worth a record.
    const status: []const u8 = if (eq(event, "session-start") or eq(event, "active"))
        "Running"
    else if (eq(event, "stop") or eq(event, "idle"))
        "Waiting"
    else if (eq(event, "notification") or eq(event, "notify"))
        "Attention"
    else if (eq(event, "permission"))
        "Permission"
    else if (eq(event, "error"))
        "Error"
    else if (eq(event, "prompt-submit"))
        "Running"
    else
        "Unknown";

    const ws_id = state.setWorkspaceStatus(ws_param, "claude", status) catch |err|
        return stateError(alloc, req.id, err);

    // Only events a person would want to know about while looking elsewhere.
    const notify = eq(event, "stop") or eq(event, "idle") or
        eq(event, "notification") or eq(event, "notify") or
        eq(event, "permission") or eq(event, "error");

    var notif_id: u64 = 0;
    if (notify) {
        const text = message orelse status;
        notif_id = state.notifications.add("Claude Code", text, ws_id);
        _ = state.addWorkspaceLog(ws_id, text) catch {};
    }

    const body = try std.fmt.allocPrint(
        alloc,
        "{{\"workspace_id\":{d},\"status\":\"{s}\",\"notification_id\":{d}}}",
        .{ ws_id, status, notif_id },
    );
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn paneList(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const panes = state.listPanes(alloc) catch |err| return stateError(alloc, req.id, err);
    defer alloc.free(panes);

    const key = if (eq(req.method, "pane.list")) "panes" else "surfaces";

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"");
    try out.appendSlice(alloc, key);
    try out.appendSlice(alloc, "\":[");
    for (panes, 0..) |p, i| {
        if (i > 0) try out.append(alloc, ',');
        const json = try std.fmt.allocPrint(alloc,
            \\{{"id":{d},"ref":"surface:{d}","pane_id":{d},"workspace_id":{d},"focused":{s},"alive":{s}}}
        , .{
            p.id, p.id, p.id, p.workspace_id,
            if (p.focused) "true" else "false",
            if (p.exited) "false" else "true",
        });
        defer alloc.free(json);
        try out.appendSlice(alloc, json);
    }
    try out.appendSlice(alloc, "]}");
    return protocol.successResponse(alloc, req.id, out.items);
}

fn surfaceCurrent(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const pane_id = state.resolvePane(null) catch
        return protocol.successResponse(alloc, req.id, "{\"surface\":null}");
    const ws_id = state.selectedWorkspaceId() orelse 0;
    const body = try std.fmt.allocPrint(alloc,
        \\{{"surface":{{"id":{d},"ref":"surface:{d}","pane_id":{d},"workspace_id":{d},"focused":true}}}}
    , .{ pane_id, pane_id, pane_id, ws_id });
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn sendText(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const text = req.getStringParam(alloc, "text") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'text'");
    defer alloc.free(text);

    const explicit = optionalIdParam(alloc, req, "surface_id");
    state.writePane(explicit, text) catch |err| return stateError(alloc, req.id, err);

    const id = state.resolvePane(explicit) catch 0;
    // The pane's generation after the write, so a following `surface.watch` can
    // say "tell me about anything after this" instead of guessing a baseline.
    const gen = state.paneGeneration(id) catch 0;
    const body = try std.fmt.allocPrint(
        alloc,
        "{{\"queued\":true,\"surface_id\":{d},\"gen\":{d}}}",
        .{ id, gen },
    );
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn readText(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const explicit = optionalIdParam(alloc, req, "surface_id");
    const scrollback = req.getBoolParam(alloc, "scrollback") orelse false;

    const text = state.readPane(explicit, alloc, scrollback) catch |err| return stateError(alloc, req.id, err);
    defer alloc.free(text);
    const escaped = try jsonEscape(alloc, text);
    defer alloc.free(escaped);

    const id = state.resolvePane(explicit) catch 0;
    const body = try std.fmt.allocPrint(alloc, "{{\"text\":\"{s}\",\"surface_id\":{d}}}", .{ escaped, id });
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

/// Longest a client may ask the daemon to hold a connection open waiting for the
/// screen to change. A watcher that wants to wait longer re-asks, which also
/// makes it prove it is still there.
const max_screen_timeout_ms: u32 = 30_000;

/// The screen as cells, for a client that draws it.
///
/// One method covers attach and update both: pass no `since` and get the whole
/// screen, pass the `seq` from last time and get only the rows that changed.
/// Attaching is just `since = 0`, so there is no separate attach handshake that
/// could disagree with the update path.
///
/// `timeout_ms` turns it into a wait: the daemon answers as soon as the screen
/// changes, or reports no change when the time is up. That is deliberately not
/// named `surface.watch` -- the roadmap keeps that name for semantic wake events
/// (a TUI appeared, a prompt is waiting), which is a different question asked by
/// a different kind of client. Both sit on the same change notification.
fn surfaceScreen(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const explicit = optionalIdParam(alloc, req, "surface_id");
    const since: u64 = if (req.getIntParam(alloc, "since")) |v| toU64(v) orelse 0 else 0;
    const requested: u32 = if (req.getIntParam(alloc, "timeout_ms")) |v|
        @intCast(@max(0, @min(v, @as(i64, max_screen_timeout_ms))))
    else
        0;

    const pane_id = state.resolvePane(explicit) catch |err| return stateError(alloc, req.id, err);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);

    const seq = state.paneScreen(pane_id, alloc, &out, .{
        .since = since,
        .timeout_ms = requested,
    }) catch |err| return stateError(alloc, req.id, err);

    if (seq == null) {
        // Nothing changed in the time allowed. Echoing the sequence number back
        // means the client can loop on the reply without tracking it separately.
        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"pane_id\":{d},\"seq\":{d},\"changed\":false}}",
            .{ pane_id, since },
        );
        defer alloc.free(body);
        return protocol.successResponse(alloc, req.id, body);
    }

    return protocol.successResponse(alloc, req.id, out.items);
}

const b64 = std.base64.standard;

/// Raw pty bytes, for a relay that owns a terminal of its own.
///
/// Base64 rather than JSON string escaping. These are arbitrary bytes including
/// escape sequences, and `\u00xx` costs six bytes for every control character in
/// a stream that is mostly control characters. Base64 costs a flat third, and
/// cannot be got wrong by a client that forgets to unescape.
///
/// Omit `offset` to attach: the answer is a repaint of the current screen plus
/// the offset to stream from. This mirrors `surface.screen`, where omitting
/// `since` means "send everything".
fn surfaceOutput(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const explicit = optionalIdParam(alloc, req, "surface_id");
    const from: ?u64 = if (req.getIntParam(alloc, "offset")) |v| toU64(v) else null;
    const timeout: u32 = if (req.getIntParam(alloc, "timeout_ms")) |v|
        @intCast(@max(0, @min(v, @as(i64, max_screen_timeout_ms))))
    else
        0;

    const pane_id = state.resolvePane(explicit) catch |err| return stateError(alloc, req.id, err);

    const res = state.paneOutput(pane_id, alloc, from, timeout) catch |err|
        return stateError(alloc, req.id, err);

    if (res == null) {
        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"surface_id\":{d},\"offset\":{d},\"changed\":false}}",
            .{ pane_id, from orelse 0 },
        );
        defer alloc.free(body);
        return protocol.successResponse(alloc, req.id, body);
    }

    const r = res.?;
    defer alloc.free(r.data);
    defer if (r.paint) |p| alloc.free(p);

    const bytes = r.paint orelse r.data;
    const encoded = try alloc.alloc(u8, b64.Encoder.calcSize(bytes.len));
    defer alloc.free(encoded);
    _ = b64.Encoder.encode(encoded, bytes);

    const body = try std.fmt.allocPrint(
        alloc,
        "{{\"surface_id\":{d},\"offset\":{d},\"cols\":{d},\"rows\":{d}," ++
            "\"painted\":{s},\"exited\":{s},\"data\":\"{s}\"}}",
        .{
            pane_id,
            r.offset,
            r.cols,
            r.rows,
            if (r.paint != null) "true" else "false",
            if (r.exited) "true" else "false",
            encoded,
        },
    );
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

/// Raw bytes towards the child's stdin, base64 for the same reason as above:
/// a keystroke is frequently an escape sequence.
fn surfaceInput(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const explicit = optionalIdParam(alloc, req, "surface_id");
    const encoded = req.getStringParam(alloc, "data") orelse
        return protocol.errorResponse(alloc, req.id, "invalid_params", "data is required");

    const max_len = b64.Decoder.calcSizeUpperBound(encoded.len) catch
        return protocol.errorResponse(alloc, req.id, "invalid_params", "data is not base64");
    const decoded = try alloc.alloc(u8, max_len);
    defer alloc.free(decoded);
    const n = b64.Decoder.calcSizeForSlice(encoded) catch
        return protocol.errorResponse(alloc, req.id, "invalid_params", "data is not base64");
    b64.Decoder.decode(decoded[0..n], encoded) catch
        return protocol.errorResponse(alloc, req.id, "invalid_params", "data is not base64");

    state.writePane(explicit, decoded[0..n]) catch |err| return stateError(alloc, req.id, err);

    const id = state.resolvePane(explicit) catch 0;
    const body = try std.fmt.allocPrint(alloc, "{{\"surface_id\":{d},\"wrote\":{d}}}", .{ id, n });
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

/// Set a pane's terminal size.
///
/// Driven by whatever is attached, because that is what knows how big the window
/// is. A pane painted for 80 columns into a 103-column terminal does not merely
/// look narrow -- rows land in the wrong places and characters at the edge go
/// missing, which is how this turned out to be needed.
fn surfaceResize(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const explicit = optionalIdParam(alloc, req, "surface_id");
    const cols_i = req.getIntParam(alloc, "cols") orelse
        return protocol.errorResponse(alloc, req.id, "invalid_params", "cols is required");
    const rows_i = req.getIntParam(alloc, "rows") orelse
        return protocol.errorResponse(alloc, req.id, "invalid_params", "rows is required");
    if (cols_i < 1 or rows_i < 1 or cols_i > 10_000 or rows_i > 10_000) {
        return protocol.errorResponse(alloc, req.id, "invalid_params", "cols and rows must be sane");
    }

    const pane_id = state.resolvePane(explicit) catch |err| return stateError(alloc, req.id, err);
    state.resizePane(pane_id, @intCast(cols_i), @intCast(rows_i)) catch |err|
        return stateError(alloc, req.id, err);

    const body = try std.fmt.allocPrint(
        alloc,
        "{{\"surface_id\":{d},\"cols\":{d},\"rows\":{d}}}",
        .{ pane_id, cols_i, rows_i },
    );
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

/// Read the `surfaces` list: `[3, 5]` or `[{"id":3,"since_gen":12}, ...]`.
///
/// Both forms accepted because both are natural to write. Returns how many were
/// filled in; zero means the request did not use the list form at all.
fn parseWatchTargets(
    req: *const protocol.Request,
    out: *[Registry.max_watch_targets]Registry.WatchTarget,
) usize {
    const params = req.params orelse return 0;
    const list = params.get("surfaces") orelse return 0;
    if (list != .array) return 0;

    var n: usize = 0;
    for (list.array.items) |item| {
        if (n >= out.len) break;
        switch (item) {
            .integer => |v| {
                if (v <= 0) continue;
                out[n] = .{ .id = @intCast(v) };
                n += 1;
            },
            .object => |o| {
                const id_val = o.get("id") orelse continue;
                if (id_val != .integer or id_val.integer <= 0) continue;
                var target: Registry.WatchTarget = .{ .id = @intCast(id_val.integer) };
                if (o.get("since_gen")) |g| {
                    if (g == .integer and g.integer >= 0) target.since_gen = @intCast(g.integer);
                }
                out[n] = target;
                n += 1;
            },
            else => {},
        }
    }
    return n;
}

/// Longest a watch may block. Longer than the screen protocol's ceiling because
/// waiting is the whole point here: an agent watching a build wants one call,
/// not a loop of reconnects.
const max_watch_timeout_ms: u32 = 600_000;

/// Block until this pane does something worth an agent's turn.
///
/// The alternative an agent has is sleeping and re-reading, which spends a turn
/// on every dead poll and still misses the moment a command stops to ask a
/// question. This answers as soon as there is something to see, and says why --
/// `command_complete`, `prompt_waiting`, `tui_detected`, `output_stalled` or
/// `exited` -- so the agent can decide what to do without re-reading everything
/// first.
fn surfaceWatch(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const explicit = optionalIdParam(alloc, req, "surface_id");
    const timeout: u32 = if (req.getIntParam(alloc, "timeout_ms")) |v|
        @intCast(@max(0, @min(v, @as(i64, max_watch_timeout_ms))))
    else
        60_000;
    const since_gen: ?u64 = if (req.getIntParam(alloc, "since_gen")) |v| toU64(v) else null;
    const stall: u64 = if (req.getIntParam(alloc, "stall_ms")) |v|
        @intCast(@max(0, v))
    else
        2000;
    const prompt = req.getStringParam(alloc, "prompt_pattern");
    defer if (prompt) |p| alloc.free(p);

    const opts: Registry.WatchOptions = .{
        .since_gen = since_gen,
        .stall_ms = stall,
        .timeout_ms = timeout,
        .prompt = prompt,
    };

    // `surfaces` watches several at once and answers about whichever fires
    // first. Each entry carries its own baseline, because generations are
    // per-pane -- one number could not describe two terminals.
    var targets: [Registry.max_watch_targets]Registry.WatchTarget = undefined;
    const target_count = parseWatchTargets(req, &targets);

    const res = if (target_count > 0)
        state.paneWatchAny(targets[0..target_count], alloc, opts) catch |err|
            return stateError(alloc, req.id, err)
    else blk: {
        const pane_id = state.resolvePane(explicit) catch |err| return stateError(alloc, req.id, err);
        break :blk state.paneWatch(pane_id, alloc, opts) catch |err|
            return stateError(alloc, req.id, err);
    };

    // Which pane the answer is about, for the reply when nothing fired.
    const pane_id: u64 = if (target_count > 0)
        targets[0].id
    else
        state.resolvePane(explicit) catch 0;

    if (res == null) {
        // The safety net fired. Reported as an event of its own rather than an
        // error, because "nothing happened for a minute" is a fact the agent
        // may well want to act on.
        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"surface_id\":{d},\"reason\":\"timeout\",\"woke\":false}}",
            .{pane_id},
        );
        defer alloc.free(body);
        return protocol.successResponse(alloc, req.id, body);
    }

    const ev = res.?;
    defer alloc.free(ev.text);

    const escaped = try jsonEscape(alloc, ev.text);
    defer alloc.free(escaped);

    const body = try std.fmt.allocPrint(
        alloc,
        "{{\"surface_id\":{d},\"reason\":\"{s}\",\"woke\":true," ++
            "\"idle_ms\":{d},\"alt_screen\":{s},\"exited\":{s}," ++
            "\"shell_integration\":{s},\"text\":\"{s}\"}}",
        .{
            ev.surface_id,
            ev.reason.name(),
            ev.idle_ms,
            if (ev.alt_screen) "true" else "false",
            if (ev.exited) "true" else "false",
            // Says whether the answer rests on the shell's own marks or on
            // recognising a prompt by sight, so a caller knows how much to
            // trust it.
            if (ev.shell_integration) "true" else "false",
            escaped,
        },
    );
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn sendKey(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const key = req.getStringParam(alloc, "key") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'key'");
    defer alloc.free(key);

    const bytes = keyBytes(key) orelse
        return protocol.errorResponse(alloc, req.id, "unknown_key", "Unknown key name");

    const explicit = optionalIdParam(alloc, req, "surface_id");
    state.writePane(explicit, bytes) catch |err| return stateError(alloc, req.id, err);

    const escaped = try jsonEscape(alloc, key);
    defer alloc.free(escaped);
    const body = try std.fmt.allocPrint(alloc, "{{\"sent\":true,\"key\":\"{s}\"}}", .{escaped});
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

/// Named keys to the bytes a terminal actually expects.
///
/// The GUI mapped these onto Ghostty binding-action strings because it went
/// through a Surface. Writing straight to a pty, the bytes are the whole story.
fn keyBytes(name: []const u8) ?[]const u8 {
    var lower_buf: [32]u8 = undefined;
    if (name.len > lower_buf.len) return null;
    for (name, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
    const k = lower_buf[0..name.len];

    // ctrl-<letter> is the letter minus 0x60.
    if ((std.mem.startsWith(u8, k, "ctrl-") or std.mem.startsWith(u8, k, "ctrl+")) and k.len == 6) {
        const c = k[5];
        if (c >= 'a' and c <= 'z') {
            const table = "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a";
            return table[c - 'a' ..][0..1];
        }
    }

    const map = .{
        .{ "enter", "\r" },     .{ "return", "\r" },
        .{ "tab", "\t" },       .{ "escape", "\x1b" },
        .{ "esc", "\x1b" },     .{ "space", " " },
        .{ "backspace", "\x7f" },
        .{ "up", "\x1b[A" },    .{ "down", "\x1b[B" },
        .{ "right", "\x1b[C" }, .{ "left", "\x1b[D" },
        .{ "home", "\x1b[H" },  .{ "end", "\x1b[F" },
        .{ "pageup", "\x1b[5~" }, .{ "pagedown", "\x1b[6~" },
        .{ "delete", "\x1b[3~" }, .{ "insert", "\x1b[2~" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, k, entry[0])) return entry[1];
    }
    return null;
}

fn split(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const dir_str = req.getStringParam(alloc, "direction") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'direction'");
    defer alloc.free(dir_str);

    const direction = parseDirection(dir_str) orelse
        return protocol.errorResponse(alloc, req.id, "invalid_direction", "Direction must be left, right, up or down");

    const explicit = optionalIdParam(alloc, req, "surface_id");
    const target = state.resolvePane(explicit) catch |err| return stateError(alloc, req.id, err);
    const new_id = state.splitPane(target, direction) catch |err| return stateError(alloc, req.id, err);

    const body = try std.fmt.allocPrint(alloc, "{{\"split\":true,\"surface_id\":{d}}}", .{new_id});
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn parseDirection(s: []const u8) ?PaneTree.SplitDirection {
    if (eq(s, "left")) return .left;
    if (eq(s, "right")) return .right;
    if (eq(s, "up")) return .up;
    if (eq(s, "down")) return .down;
    return null;
}

fn closePane(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const explicit = optionalIdParam(alloc, req, "surface_id");
    const target = state.resolvePane(explicit) catch |err| return stateError(alloc, req.id, err);
    state.closePane(target) catch |err| return stateError(alloc, req.id, err);
    return protocol.successResponse(alloc, req.id, "{\"closed\":true}");
}

// --- surface.run -------------------------------------------------------

const default_run_timeout_secs: u64 = 30;
const max_run_timeout_secs: u64 = 600;
const run_poll_interval_ms: u64 = 100;

/// Send a command and return what it printed.
///
/// Much simpler than the GUI's version: there is no GTK thread to dispatch
/// each read onto, so this just polls the terminal it already owns.
fn run(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const command = req.getStringParam(alloc, "command") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'command'");
    defer alloc.free(command);

    const timeout_secs: u64 = if (req.getIntParam(alloc, "timeout")) |t|
        @min(toU64(@max(t, 1)) orelse default_run_timeout_secs, max_run_timeout_secs)
    else
        default_run_timeout_secs;

    const prompt = req.getStringParam(alloc, "prompt_pattern");
    defer if (prompt) |p| alloc.free(p);

    const explicit = optionalIdParam(alloc, req, "surface_id");
    const pane_id = state.resolvePane(explicit) catch |err| return stateError(alloc, req.id, err);

    const before = state.readPane(pane_id, alloc, false) catch |err| return stateError(alloc, req.id, err);
    defer alloc.free(before);

    const line = try std.fmt.allocPrint(alloc, "{s}\n", .{command});
    defer alloc.free(line);
    state.writePane(pane_id, line) catch |err| return stateError(alloc, req.id, err);

    var timer = std.time.Timer.start() catch
        return protocol.errorResponse(alloc, req.id, "internal_error", "No monotonic clock");
    const deadline_ns = timeout_secs * std.time.ns_per_s;

    var timed_out = true;
    var after: ?[]const u8 = null;
    defer if (after) |a| alloc.free(a);

    // When the shell marks its own boundaries, "is it finished?" is a fact
    // rather than a resemblance. Checked once per poll alongside the snapshot.
    var marked = false;

    while (timer.read() < deadline_ns) {
        std.Thread.sleep(run_poll_interval_ms * std.time.ns_per_ms);

        if (state.paneAtPrompt(pane_id) catch null) |at_prompt| {
            marked = true;
            if (at_prompt) {
                timed_out = false;
                break;
            }
            continue;
        }

        const snapshot = state.readPane(pane_id, alloc, false) catch break;
        if (snapshot.len > before.len and endsWithPrompt(snapshot, prompt)) {
            if (after) |a| alloc.free(a);
            after = snapshot;
            timed_out = false;
            break;
        }
        if (after) |a| alloc.free(a);
        after = snapshot;
    }

    // Read the output from the marks when there are any; otherwise fall back to
    // matching the echoed command against the screen, which is what every
    // unintegrated shell still gets.
    var marked_output: ?[]const u8 = null;
    defer if (marked_output) |m| alloc.free(m);
    if (marked) {
        marked_output = state.paneCommandOutput(pane_id, alloc) catch null;
    }

    const output = if (marked_output) |m|
        m
    else if (after) |a|
        extractOutput(a, before, command)
    else
        "";

    const escaped = try jsonEscape(alloc, output);
    defer alloc.free(escaped);

    const body = try std.fmt.allocPrint(alloc,
        \\{{"output":"{s}","timed_out":{s},"shell_integration":{s},"surface_id":{d}}}
    , .{ escaped, if (timed_out) "true" else "false", if (marked) "true" else "false", pane_id });
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn endsWithPrompt(text: []const u8, custom: ?[]const u8) bool {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r')) end -= 1;
    if (end == 0) return false;
    var start = end;
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    const last = std.mem.trimRight(u8, text[start..end], " ");
    if (last.len == 0) return false;

    if (custom) |pat| return std.mem.endsWith(u8, last, pat);
    for ([_][]const u8{ "$ ", "# ", "% ", "> ", "$", "#", "%", ">" }) |suffix| {
        if (std.mem.endsWith(u8, last, suffix)) return true;
    }
    return false;
}

/// The lines between the echoed command and the prompt that followed it.
///
/// This is a heuristic and is honest about it. Two things make naive matching
/// fail, and both were observed:
///
///   - the terminal wraps the echoed command at the column limit, so the echo
///     on screen contains newlines the command string does not ("echo sec\nond")
///   - the screen can scroll between the two snapshots, so `before` is not
///     necessarily a prefix of `after`
///
/// The real fix is semantic prompts: shell integration emits OSC 133 marks
/// around the prompt and the command, and the VT engine already parses them, so
/// the daemon could know exactly where output starts and stops instead of
/// guessing. Worth doing when shell integration moves to the daemon.
fn extractOutput(after: []const u8, before: []const u8, command: []const u8) []const u8 {
    // Only look at what is new, tolerating a scroll rather than assuming
    // `before` is a byte prefix of `after`.
    const shared = commonPrefixLen(before, after);
    const tail = after[shared..];

    // Skip the echoed command, comparing while ignoring the line breaks the
    // terminal inserted when it wrapped.
    const rest = skipEcho(tail, command) orelse trimBlank(tail);

    // Drop the trailing prompt line the shell printed after finishing.
    var end = rest.len;
    while (end > 0 and (rest[end - 1] == '\n' or rest[end - 1] == '\r' or rest[end - 1] == ' ')) end -= 1;
    var line_start = end;
    while (line_start > 0 and rest[line_start - 1] != '\n') line_start -= 1;
    if (line_start > 0) end = line_start;

    return trimBlank(rest[0..end]);
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) i += 1;
    return i;
}

/// Find the echoed command in `text` and return what follows it.
///
/// Searches rather than matching a prefix: the new region routinely starts with
/// the prompt the shell printed before echoing, and prompts are arbitrary. CR
/// and LF in `text` are skipped while comparing, so an echo the terminal wrapped
/// at the column limit still matches.
fn skipEcho(text: []const u8, command: []const u8) ?[]const u8 {
    if (command.len == 0) return null;
    var start: usize = 0;
    while (start < text.len) : (start += 1) {
        // Cheap rejection before walking the whole candidate.
        if (text[start] != command[0]) continue;
        if (matchIgnoringBreaks(text, start, command)) |end| return text[end..];
    }
    return null;
}

/// If `command` matches `text` from `start` (ignoring CR/LF in `text`), return
/// the index just past the match.
fn matchIgnoringBreaks(text: []const u8, start: usize, command: []const u8) ?usize {
    var i = start;
    var ci: usize = 0;
    while (i < text.len and ci < command.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\n' or ch == '\r') continue;
        if (ch != command[ci]) return null;
        ci += 1;
    }
    return if (ci == command.len) i else null;
}

fn trimBlank(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \r\n\t");
}

// --- history -----------------------------------------------------------
//
// This queries the archive of *closed* sessions. Searching a pane that is still
// open is a different operation against a different data structure -- the VT
// engine's own scrollback search -- and belongs on surface.*, not here.

fn historyLimit(alloc: Allocator, req: *const protocol.Request) usize {
    const raw = req.getIntParam(alloc, "limit") orelse return default_history_limit;
    const v = toU64(raw) orelse return default_history_limit;
    return @min(@max(v, 1), max_history_limit);
}

fn entriesResponse(alloc: Allocator, id: i64, entries: []const History.Entry) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"entries\":[");
    for (entries, 0..) |e, i| {
        if (i > 0) try out.append(alloc, ',');
        const title = try jsonEscape(alloc, e.workspace_title);
        defer alloc.free(title);
        const cwd = try jsonEscape(alloc, e.cwd);
        defer alloc.free(cwd);
        const reason = try jsonEscape(alloc, e.reason);
        defer alloc.free(reason);
        const json = try std.fmt.allocPrint(alloc,
            \\{{"id":{d},"workspace_id":{d},"workspace_title":"{s}","pane_id":{d},"closed_at":{d},"cwd":"{s}","reason":"{s}","lines":{d},"bytes":{d}}}
        , .{ e.id, e.workspace_id, title, e.pane_id, e.closed_at, cwd, reason, e.lines, e.bytes });
        defer alloc.free(json);
        try out.appendSlice(alloc, json);
    }
    try out.appendSlice(alloc, "]}");
    return protocol.successResponse(alloc, id, out.items);
}

fn noArchive(alloc: Allocator, id: i64) ![]const u8 {
    return protocol.errorResponse(alloc, id, "no_archive", "Session archive unavailable");
}

/// History ids here are integers, but amux-cli sends them as strings because the
/// GUI's file-based store used `{timestamp}_ws{n}_p{n}` names. Accept either
/// while both stores exist; the string form goes away with item 6.
fn historyIdParam(alloc: Allocator, req: *const protocol.Request) ?i64 {
    if (req.getIntParam(alloc, "id")) |v| return v;
    const text = req.getStringParam(alloc, "id") orelse return null;
    defer alloc.free(text);
    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn historyList(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const hist = state.history orelse return noArchive(alloc, req.id);
    const workspace_id = optionalIdParam(alloc, req, "workspace_id");

    const entries = hist.list(alloc, workspace_id, historyLimit(alloc, req)) catch |err|
        return stateError(alloc, req.id, err);
    defer History.freeEntries(alloc, entries);
    return entriesResponse(alloc, req.id, entries);
}

fn historySearch(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const hist = state.history orelse return noArchive(alloc, req.id);
    const query = req.getStringParam(alloc, "query") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'query'");
    defer alloc.free(query);

    const entries = hist.search(alloc, query, historyLimit(alloc, req)) catch |err|
        return stateError(alloc, req.id, err);
    defer History.freeEntries(alloc, entries);
    return entriesResponse(alloc, req.id, entries);
}

fn historyShow(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const hist = state.history orelse return noArchive(alloc, req.id);
    const raw = historyIdParam(alloc, req) orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires a numeric 'id'");

    const found = hist.get(alloc, raw) catch |err| return stateError(alloc, req.id, err);
    const content = found orelse
        return protocol.errorResponse(alloc, req.id, "not_found", "No such session");
    defer alloc.free(content);

    const escaped = try jsonEscape(alloc, content);
    defer alloc.free(escaped);
    const body = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"text\":\"{s}\"}}", .{ raw, escaped });
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn historyDelete(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const hist = state.history orelse return noArchive(alloc, req.id);
    const raw = historyIdParam(alloc, req) orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires a numeric 'id'");

    const removed = hist.delete(raw) catch |err| return stateError(alloc, req.id, err);
    if (!removed) return protocol.errorResponse(alloc, req.id, "not_found", "No such session");
    return protocol.successResponse(alloc, req.id, "{\"deleted\":true}");
}

test "the surfaces list accepts both a bare id and an id with a baseline" {
    const alloc = std.testing.allocator;

    // Both shapes are natural to write, so both are read.
    const line =
        \\{"id":1,"method":"surface.watch","params":{"surfaces":[3,{"id":5,"since_gen":42}]}}
    ;
    var req = try protocol.Request.parse(alloc, line);
    defer req.deinit(alloc);

    var targets: [Registry.max_watch_targets]Registry.WatchTarget = undefined;
    const n = parseWatchTargets(&req, &targets);

    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u64, 3), targets[0].id);
    try std.testing.expect(targets[0].since_gen == null);
    try std.testing.expectEqual(@as(u64, 5), targets[1].id);
    try std.testing.expectEqual(@as(u64, 42), targets[1].since_gen.?);
}

test "a request with no surfaces list falls back to the single-pane form" {
    const alloc = std.testing.allocator;
    const line =
        \\{"id":1,"method":"surface.watch","params":{"surface_id":7}}
    ;
    var req = try protocol.Request.parse(alloc, line);
    defer req.deinit(alloc);

    var targets: [Registry.max_watch_targets]Registry.WatchTarget = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseWatchTargets(&req, &targets));
}

test "junk in the surfaces list is skipped rather than trusted" {
    const alloc = std.testing.allocator;
    const line =
        \\{"id":1,"method":"surface.watch","params":{"surfaces":[0,-4,"nope",{"nope":1},{"id":9}]}}
    ;
    var req = try protocol.Request.parse(alloc, line);
    defer req.deinit(alloc);

    var targets: [Registry.max_watch_targets]Registry.WatchTarget = undefined;
    const n = parseWatchTargets(&req, &targets);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u64, 9), targets[0].id);
}
