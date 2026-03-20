const std = @import("std");
const protocol = @import("protocol.zig");
const Server = @import("server.zig");
const HandleRegistry = @import("handle_registry.zig");
const Window = @import("../window.zig");
const Workspace = @import("../workspace.zig");
const PaneTree = @import("../pane_tree.zig");
const TerminalWidget = @import("../terminal_widget.zig");
const CommandPalette = @import("../command_palette.zig");
const ClaudeSessionStore = @import("../claude_session_store.zig");
const history = @import("../history.zig");
const c = @import("../c.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.socket_handlers);

/// Safely cast an i64 to u64, returning null if negative.
fn toU64(val: i64) ?u64 {
    if (val < 0) return null;
    return @intCast(val);
}

/// Safely cast an i64 to usize, returning null if negative.
fn toUsize(val: i64) ?usize {
    if (val < 0) return null;
    return @intCast(val);
}

/// Timeout for GTK idle dispatch operations (10 seconds).
/// GTK callbacks should complete near-instantly; this guards against hangs.
const gtk_dispatch_timeout_ns: u64 = 10_000_000_000;

/// Dispatch a request to the appropriate handler.
pub fn dispatch(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    // System methods
    if (std.mem.eql(u8, req.method, "system.ping")) {
        return handleSystemPing(alloc, req);
    }
    if (std.mem.eql(u8, req.method, "system.identify")) {
        return handleSystemIdentify(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "system.capabilities")) {
        return handleSystemCapabilities(alloc, req);
    }
    if (std.mem.eql(u8, req.method, "system.tree")) {
        return handleSystemTree(alloc, server, req);
    }

    // Workspace methods
    if (std.mem.eql(u8, req.method, "workspace.list")) {
        return handleWorkspaceList(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.create")) {
        return handleWorkspaceCreate(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.current")) {
        return handleWorkspaceCurrent(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.select")) {
        return handleWorkspaceSelect(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.close")) {
        return handleWorkspaceClose(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.rename")) {
        return handleWorkspaceRename(alloc, server, req);
    }

    // Surface methods
    if (std.mem.eql(u8, req.method, "surface.list")) {
        return handleSurfaceList(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.send_text")) {
        return handleSurfaceSendText(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.current")) {
        return handleSurfaceCurrent(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.read_text")) {
        return handleSurfaceReadText(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.send_key")) {
        return handleSurfaceSendKey(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.split")) {
        return handleSurfaceSplit(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.close")) {
        return handleSurfaceClose(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.run")) {
        return handleSurfaceRun(alloc, server, req);
    }

    // Workspace metadata methods
    if (std.mem.eql(u8, req.method, "workspace.report_git")) {
        return handleWorkspaceReportGit(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.set_status")) {
        return handleWorkspaceSetStatus(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.clear_status")) {
        return handleWorkspaceClearStatus(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.add_log")) {
        return handleWorkspaceAddLog(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.clear_log")) {
        return handleWorkspaceClearLog(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.set_progress")) {
        return handleWorkspaceSetProgress(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.set_pinned")) {
        return handleWorkspaceSetPinned(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.set_color")) {
        return handleWorkspaceSetColor(alloc, server, req);
    }

    // Workspace navigation
    if (std.mem.eql(u8, req.method, "workspace.next")) {
        return handleWorkspaceNext(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.previous")) {
        return handleWorkspacePrevious(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.last")) {
        return handleWorkspaceLast(alloc, server, req);
    }

    // Pane methods
    if (std.mem.eql(u8, req.method, "pane.list")) {
        return handlePaneList(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "pane.resize")) {
        return handlePaneResize(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "pane.swap")) {
        return handlePaneSwap(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "pane.break")) {
        return handlePaneBreak(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "pane.join")) {
        return handlePaneJoin(alloc, server, req);
    }

    // Window methods
    if (std.mem.eql(u8, req.method, "window.list")) {
        return handleWindowList(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "window.current")) {
        return handleWindowCurrent(alloc, server, req);
    }

    // Notification methods
    if (std.mem.eql(u8, req.method, "notification.create")) {
        return handleNotificationCreate(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "notification.list")) {
        return handleNotificationList(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "notification.clear")) {
        return handleNotificationClear(alloc, server, req);
    }

    // Surface search
    if (std.mem.eql(u8, req.method, "surface.search")) {
        return handleSurfaceSearch(alloc, server, req);
    }

    // Command palette methods
    if (std.mem.eql(u8, req.method, "command_palette.list")) {
        return handleCommandPaletteList(alloc, req);
    }
    if (std.mem.eql(u8, req.method, "command_palette.execute")) {
        return handleCommandPaletteExecute(alloc, server, req);
    }

    // History methods
    if (std.mem.eql(u8, req.method, "history.list")) {
        return handleHistoryList(alloc, req);
    }
    if (std.mem.eql(u8, req.method, "history.show")) {
        return handleHistoryShow(alloc, req);
    }
    if (std.mem.eql(u8, req.method, "history.search")) {
        return handleHistorySearch(alloc, req);
    }
    if (std.mem.eql(u8, req.method, "history.delete")) {
        return handleHistoryDelete(alloc, req);
    }

    // Claude Code integration
    if (std.mem.eql(u8, req.method, "claude.hook")) {
        return handleClaudeHook(alloc, server, req);
    }

    return protocol.errorResponse(alloc, req.id, "method_not_found", req.method);
}

// ------------------------------------------------------------------
// JSON builder helpers
// ------------------------------------------------------------------

/// A simple JSON array builder that produces `[{...},{...}]`.
const JsonArrayBuilder = struct {
    buf: std.ArrayListUnmanaged(u8) = .{},
    alloc: Allocator,
    count: usize = 0,

    fn init(alloc: Allocator) JsonArrayBuilder {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *JsonArrayBuilder) void {
        self.buf.deinit(self.alloc);
    }

    fn startArray(self: *JsonArrayBuilder) !void {
        try self.buf.append(self.alloc, '[');
    }

    fn endArray(self: *JsonArrayBuilder) !void {
        try self.buf.append(self.alloc, ']');
    }

    fn addRaw(self: *JsonArrayBuilder, json: []const u8) !void {
        if (self.count > 0) {
            try self.buf.append(self.alloc, ',');
        }
        try self.buf.appendSlice(self.alloc, json);
        self.count += 1;
    }

    fn toOwnedSlice(self: *JsonArrayBuilder) ![]const u8 {
        return self.buf.toOwnedSlice(self.alloc);
    }
};

/// Escape a string for JSON embedding.
fn jsonEscapeString(alloc: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, ch),
        }
    }
    return out.toOwnedSlice(alloc);
}

// ------------------------------------------------------------------
// System handlers
// ------------------------------------------------------------------

fn handleSystemPing(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    return protocol.successResponse(alloc, req.id, "{\"pong\":true}");
}

fn handleSystemIdentify(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window;

    // Build focused surface info
    var focused_json: []const u8 = "null";
    var focused_alloc = false;
    if (window) |w| {
        if (w.tab_manager.selectedWorkspace()) |ws| {
            if (ws.pane_tree.focused_pane) |pane_id| {
                focused_json = try std.fmt.allocPrint(alloc,
                    \\{{"workspace_id":{d},"workspace_title":"{s}","pane_id":{d}}}
                , .{ ws.id, ws.getTitle(), pane_id });
                focused_alloc = true;
            }
        }
    }
    defer if (focused_alloc) alloc.free(focused_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"socket_path":"{s}","focused":{s},"caller":null}}
    , .{ server.socket_path, focused_json });
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleSystemCapabilities(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    const methods =
        \\{"methods":["system.ping","system.identify","system.capabilities","system.tree",
        \\"workspace.list","workspace.create","workspace.current","workspace.select","workspace.close","workspace.rename",
        \\"workspace.next","workspace.previous","workspace.last",
        \\"workspace.report_git","workspace.set_status","workspace.clear_status","workspace.add_log","workspace.clear_log","workspace.set_progress","workspace.set_pinned","workspace.set_color",
        \\"surface.list","surface.send_text","surface.current","surface.read_text","surface.send_key","surface.split","surface.close","surface.search","surface.run",
        \\"pane.list","pane.resize","pane.swap","pane.break","pane.join",
        \\"window.list","window.current",
        \\"notification.create","notification.list","notification.clear",
        \\"command_palette.list","command_palette.execute",
        \\"claude.hook"]}
    ;
    return protocol.successResponse(alloc, req.id, methods);
}

fn handleSystemTree(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        const result =
            \\{"focused":null,"caller":null,"windows":[]}
        ;
        return protocol.successResponse(alloc, req.id, result);
    };

    // Build the tree: one window containing all workspaces
    var ws_array = JsonArrayBuilder.init(alloc);
    defer ws_array.deinit();
    try ws_array.startArray();

    const tm = &window.tab_manager;
    for (tm.workspaces.items, 0..) |ws, i| {
        const is_selected = if (tm.selected_index) |sel| sel == i else false;

        // Build pane tree for this workspace
        var pane_array = JsonArrayBuilder.init(alloc);
        defer pane_array.deinit();
        try pane_array.startArray();

        var pane_ids = try ws.pane_tree.orderedPaneIds(alloc);
        defer pane_ids.deinit(alloc);

        for (pane_ids.items) |pane_id| {
            const is_focused = if (ws.pane_tree.focused_pane) |fp| fp == pane_id else false;
            const pane_json = try std.fmt.allocPrint(alloc,
                \\{{"id":{d},"focused":{s}}}
            , .{ pane_id, if (is_focused) "true" else "false" });
            defer alloc.free(pane_json);
            try pane_array.addRaw(pane_json);
        }
        try pane_array.endArray();
        const panes_json = try pane_array.toOwnedSlice();
        defer alloc.free(panes_json);

        const title_escaped = try jsonEscapeString(alloc, ws.getTitle());
        defer alloc.free(title_escaped);

        const ws_json = try std.fmt.allocPrint(alloc,
            \\{{"id":{d},"title":"{s}","selected":{s},"pane_count":{d},"panes":{s}}}
        , .{
            ws.id,
            title_escaped,
            if (is_selected) "true" else "false",
            ws.paneCount(),
            panes_json,
        });
        defer alloc.free(ws_json);
        try ws_array.addRaw(ws_json);
    }
    try ws_array.endArray();
    const workspaces_json = try ws_array.toOwnedSlice();
    defer alloc.free(workspaces_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"focused":null,"caller":null,"windows":[{{"id":1,"workspace_count":{d},"workspaces":{s}}}]}}
    , .{ tm.workspaces.items.len, workspaces_json });
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

// ------------------------------------------------------------------
// Workspace handlers
// ------------------------------------------------------------------

fn workspaceToJson(alloc: Allocator, ws: *const Workspace, is_selected: bool, index: usize) ![]const u8 {
    const title_escaped = try jsonEscapeString(alloc, ws.getTitle());
    defer alloc.free(title_escaped);

    const git_branch = ws.getGitBranch();
    var branch_json: []const u8 = "null";
    var branch_alloc = false;
    if (git_branch) |b| {
        const escaped = try jsonEscapeString(alloc, b);
        defer alloc.free(escaped);
        branch_json = try std.fmt.allocPrint(alloc, "\"{s}\"", .{escaped});
        branch_alloc = true;
    }
    defer if (branch_alloc) alloc.free(branch_json);

    // Build status_entries as JSON object
    const status_json = try buildStatusJson(alloc, ws);
    defer alloc.free(status_json);

    // Build log_entries as JSON array
    const log_json = try buildLogJson(alloc, ws);
    defer alloc.free(log_json);

    // Build progress label
    var progress_label_json: []const u8 = "null";
    var progress_label_alloc = false;
    if (ws.getProgressLabel()) |label| {
        const escaped = try jsonEscapeString(alloc, label);
        defer alloc.free(escaped);
        progress_label_json = try std.fmt.allocPrint(alloc, "\"{s}\"", .{escaped});
        progress_label_alloc = true;
    }
    defer if (progress_label_alloc) alloc.free(progress_label_json);

    // Format progress as fixed-point to avoid scientific notation
    var progress_buf: [16]u8 = undefined;
    const progress_str = std.fmt.bufPrint(&progress_buf, "{d:.2}", .{ws.progress}) catch "0.00";

    // Build color JSON
    var color_json: []const u8 = "null";
    var color_alloc = false;
    if (ws.getColor()) |color_name| {
        const escaped = try jsonEscapeString(alloc, color_name);
        defer alloc.free(escaped);
        color_json = try std.fmt.allocPrint(alloc, "\"{s}\"", .{escaped});
        color_alloc = true;
    }
    defer if (color_alloc) alloc.free(color_json);

    return std.fmt.allocPrint(alloc,
        \\{{"id":{d},"ref":"workspace:{d}","title":"{s}","index":{d},"selected":{s},"pinned":{s},"color":{s},"pane_count":{d},"git_branch":{s},"git_dirty":{s},"status_entries":{s},"log_entries":{s},"progress":{s},"progress_label":{s}}}
    , .{
        ws.id,
        ws.id,
        title_escaped,
        index,
        if (is_selected) "true" else "false",
        if (ws.pinned) "true" else "false",
        color_json,
        ws.paneCount(),
        branch_json,
        if (ws.git_dirty) "true" else "false",
        status_json,
        log_json,
        progress_str,
        progress_label_json,
    });
}

fn buildStatusJson(alloc: Allocator, ws: *const Workspace) ![]const u8 {
    if (ws.status_count == 0) return try alloc.dupe(u8, "{}");

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    try buf.append(alloc, '{');

    var iter = ws.statusIterator();
    var first = true;
    while (iter.next()) |entry| {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.append(alloc, '"');
        const key_esc = try jsonEscapeString(alloc, entry.key);
        defer alloc.free(key_esc);
        try buf.appendSlice(alloc, key_esc);
        try buf.appendSlice(alloc, "\":\"");
        const val_esc = try jsonEscapeString(alloc, entry.value);
        defer alloc.free(val_esc);
        try buf.appendSlice(alloc, val_esc);
        try buf.append(alloc, '"');
    }
    try buf.append(alloc, '}');
    return buf.toOwnedSlice(alloc);
}

fn buildLogJson(alloc: Allocator, ws: *const Workspace) ![]const u8 {
    if (ws.log_count == 0) return try alloc.dupe(u8, "[]");

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');

    // Walk log_buf entries (null-separated)
    var pos: usize = 0;
    var first = true;
    while (pos < ws.log_len) {
        const start = pos;
        while (pos < ws.log_len and ws.log_buf[pos] != 0) : (pos += 1) {}
        const entry = ws.log_buf[start..pos];
        pos += 1; // skip null

        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.append(alloc, '"');
        const esc = try jsonEscapeString(alloc, entry);
        defer alloc.free(esc);
        try buf.appendSlice(alloc, esc);
        try buf.append(alloc, '"');
    }
    try buf.append(alloc, ']');
    return buf.toOwnedSlice(alloc);
}

fn handleWorkspaceList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"workspaces\":[]}");
    };

    const tm = &window.tab_manager;

    var array = JsonArrayBuilder.init(alloc);
    defer array.deinit();
    try array.startArray();

    for (tm.workspaces.items, 0..) |ws, i| {
        const is_selected = if (tm.selected_index) |sel| sel == i else false;
        const ws_json = try workspaceToJson(alloc, ws, is_selected, i);
        defer alloc.free(ws_json);
        try array.addRaw(ws_json);
    }

    try array.endArray();
    const ws_list = try array.toOwnedSlice();
    defer alloc.free(ws_list);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"workspaces":{s}}}
    , .{ws_list});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleWorkspaceCreate(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    // Get optional title parameter
    const title = req.getStringParam(alloc, "title");
    defer if (title) |t| alloc.free(t);

    // Create the workspace data model
    const ws = window.tab_manager.createWorkspace() catch |err| {
        return protocol.errorResponse(alloc, req.id, "create_failed", @errorName(err));
    };

    if (title) |t| {
        ws.setTitle(t);
    }

    const idx = window.tab_manager.workspaces.items.len - 1;

    // Schedule GTK widget building and switch on the main thread.
    // The workspace data model is already created; we just need to build
    // the widgets and switch the UI to it.
    const switch_ctx = std.heap.c_allocator.create(WorkspaceSwitchCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    switch_ctx.* = .{ .window = window, .index = idx };
    _ = c.g_idle_add(&doWorkspaceSwitch, @ptrCast(switch_ctx));

    const ws_json = try workspaceToJson(alloc, ws, false, idx);
    defer alloc.free(ws_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"workspace":{s}}}
    , .{ws_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleWorkspaceCurrent(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"workspace\":null}");
    };

    const tm = &window.tab_manager;
    const ws = tm.selectedWorkspace() orelse {
        return protocol.successResponse(alloc, req.id, "{\"workspace\":null}");
    };

    const idx = tm.selected_index orelse 0;
    const ws_json = try workspaceToJson(alloc, ws, true, idx);
    defer alloc.free(ws_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"workspace":{s}}}
    , .{ws_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleWorkspaceSelect(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    // Resolve target workspace index
    var target_index: ?usize = null;

    if (req.getIntParam(alloc, "id")) |id| {
        const ws_id = toU64(id) orelse {
            return protocol.errorResponse(alloc, req.id, "invalid_param", "Workspace ID must be non-negative");
        };
        for (window.tab_manager.workspaces.items, 0..) |ws, i| {
            if (ws.id == ws_id) {
                target_index = i;
                break;
            }
        }
        if (target_index == null) {
            return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
        }
    } else if (req.getIntParam(alloc, "index")) |index| {
        const idx = toUsize(index) orelse {
            return protocol.errorResponse(alloc, req.id, "invalid_param", "Index must be non-negative");
        };
        if (idx >= window.tab_manager.workspaces.items.len) {
            return protocol.errorResponse(alloc, req.id, "not_found", "Invalid workspace index");
        }
        target_index = idx;
    } else {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'id' or 'index' parameter");
    }

    const idx = target_index.?;

    // Dispatch workspace switch to GTK main thread and block until complete.
    // This ensures subsequent socket commands (send, send-key) see the
    // updated workspace and target the correct surface.
    const ctx = std.heap.c_allocator.create(WorkspaceSwitchCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{
        .window = window,
        .index = idx,
    };
    _ = c.g_idle_add(&doWorkspaceSwitch, @ptrCast(ctx));

    // Block until the GTK main thread completes the switch
    ctx.done.timedWait(gtk_dispatch_timeout_ns) catch {
        // Timeout: GTK main thread is unresponsive. Leak ctx to avoid use-after-free
        // since the GTK idle callback may still fire later.
        log.warn("GTK dispatch timed out for socket request", .{});
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };

    const success = ctx.success;
    std.heap.c_allocator.destroy(ctx);

    if (!success) {
        return protocol.errorResponse(alloc, req.id, "switch_failed", "Failed to switch workspace");
    }

    // Return the now-selected workspace
    const ws = window.tab_manager.workspaces.items[idx];
    const ws_json = try workspaceToJson(alloc, ws, true, idx);
    defer alloc.free(ws_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"workspace":{s}}}
    , .{ws_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

const WorkspaceSwitchCtx = struct {
    window: *Window,
    index: usize,
    success: bool = false,
    done: std.Thread.ResetEvent = .{},
};

fn doWorkspaceSwitch(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *WorkspaceSwitchCtx = @ptrCast(@alignCast(userdata));
    // Do NOT defer destroy — the handler thread still needs ctx
    defer ctx.done.set();

    // Rebuild sidebar in case a new workspace was added
    ctx.window.sidebar.rebuild();

    ctx.window.switchWorkspace(ctx.index) catch |err| {
        log.warn("Failed to switch workspace from socket: {}", .{err});
        return c.G_SOURCE_REMOVE;
    };
    ctx.success = true;

    return c.G_SOURCE_REMOVE;
}

fn handleWorkspaceClose(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    // Validate the workspace exists before scheduling close
    var close_id: ?u64 = null;
    var close_index: ?usize = null;

    if (req.getIntParam(alloc, "id")) |id| {
        const ws_id = toU64(id) orelse {
            return protocol.errorResponse(alloc, req.id, "invalid_param", "Workspace ID must be non-negative");
        };
        for (window.tab_manager.workspaces.items, 0..) |ws, i| {
            if (ws.id == ws_id) {
                close_id = ws_id;
                close_index = i;
                break;
            }
        }
        if (close_id == null) {
            return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
        }
    } else if (req.getIntParam(alloc, "index")) |index| {
        const idx = toUsize(index) orelse {
            return protocol.errorResponse(alloc, req.id, "invalid_param", "Index must be non-negative");
        };
        if (idx >= window.tab_manager.workspaces.items.len) {
            return protocol.errorResponse(alloc, req.id, "not_found", "Invalid workspace index");
        }
        close_index = idx;
    } else {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'id' or 'index' parameter");
    }

    // Schedule close on main thread (tab_manager + sidebar rebuild)
    const ctx = std.heap.c_allocator.create(WorkspaceCloseCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{
        .window = window,
        .index = close_index.?,
        .id = close_id,
    };
    _ = c.g_idle_add(&doWorkspaceClose, @ptrCast(ctx));

    return protocol.successResponse(alloc, req.id, "{\"closed\":true}");
}

const WorkspaceCloseCtx = struct {
    window: *Window,
    index: usize,
    id: ?u64,
};

fn doWorkspaceClose(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *WorkspaceCloseCtx = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(ctx);

    if (ctx.id) |id| {
        _ = ctx.window.closeWorkspaceById(id);
    } else {
        _ = ctx.window.closeWorkspaceByIndex(ctx.index);
    }

    // Rebuild sidebar to reflect the change
    ctx.window.sidebar.rebuild();

    return c.G_SOURCE_REMOVE;
}

fn handleWorkspaceRename(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const new_title = req.getStringParam(alloc, "title") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'title' parameter");
    };
    defer alloc.free(new_title);

    // Find workspace by id or use current
    var ws: ?*Workspace = null;
    if (req.getIntParam(alloc, "id")) |id| {
        const ws_id = toU64(id) orelse {
            return protocol.errorResponse(alloc, req.id, "invalid_param", "Workspace ID must be non-negative");
        };
        ws = window.tab_manager.findById(ws_id);
    } else {
        ws = window.tab_manager.selectedWorkspace();
    }

    if (ws) |w| {
        w.setTitle(new_title);
        return protocol.successResponse(alloc, req.id, "{\"renamed\":true}");
    }

    return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
}

// ------------------------------------------------------------------
// Workspace metadata handlers
// ------------------------------------------------------------------

/// Helper: find a workspace by id param, or fall back to current workspace.
fn resolveWorkspace(server: *Server, alloc: Allocator, req: *const protocol.Request) ?*Workspace {
    const window = server.window orelse return null;
    if (req.getIntParam(alloc, "id")) |id| {
        return window.tab_manager.findById(toU64(id) orelse return null);
    }
    return window.tab_manager.selectedWorkspace();
}

/// Helper: find the index of a workspace in the tab manager.
fn workspaceIndex(server: *Server, ws: *const Workspace) ?usize {
    const window = server.window orelse return null;
    for (window.tab_manager.workspaces.items, 0..) |w, i| {
        if (w.id == ws.id) return i;
    }
    return null;
}

/// Context for scheduling a sidebar row update on the GTK main thread.
const SidebarUpdateCtx = struct {
    window: *Window,
    index: usize,
};

fn doSidebarUpdate(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *SidebarUpdateCtx = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(ctx);
    ctx.window.sidebar.updateRow(ctx.index);
    return c.G_SOURCE_REMOVE;
}

/// Schedule a sidebar row update for the given workspace.
fn scheduleSidebarUpdate(server: *Server, ws: *const Workspace) void {
    const window = server.window orelse return;
    const idx = workspaceIndex(server, ws) orelse return;
    const ctx = std.heap.c_allocator.create(SidebarUpdateCtx) catch return;
    ctx.* = .{ .window = window, .index = idx };
    _ = c.g_idle_add(&doSidebarUpdate, @ptrCast(ctx));
}

fn handleWorkspaceReportGit(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const ws = resolveWorkspace(server, alloc, req) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    const branch = req.getStringParam(alloc, "branch") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'branch' parameter");
    };
    defer alloc.free(branch);

    ws.setGitBranch(branch);

    if (req.getBoolParam(alloc, "dirty")) |dirty| {
        ws.setGitDirty(dirty);
    }

    scheduleSidebarUpdate(server, ws);
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

fn handleWorkspaceSetStatus(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const ws = resolveWorkspace(server, alloc, req) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    const key = req.getStringParam(alloc, "key") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'key' parameter");
    };
    defer alloc.free(key);

    const value = req.getStringParam(alloc, "value") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'value' parameter");
    };
    defer alloc.free(value);

    ws.setStatusEntry(key, value);
    scheduleSidebarUpdate(server, ws);
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

fn handleWorkspaceClearStatus(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const ws = resolveWorkspace(server, alloc, req) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    // Optional key param: clear one entry or all
    if (req.getStringParam(alloc, "key")) |key| {
        defer alloc.free(key);
        ws.removeStatusEntry(key);
    } else {
        ws.clearStatus();
    }

    scheduleSidebarUpdate(server, ws);
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

fn handleWorkspaceAddLog(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const ws = resolveWorkspace(server, alloc, req) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    const text = req.getStringParam(alloc, "text") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'text' parameter");
    };
    defer alloc.free(text);

    ws.addLogEntry(text);
    scheduleSidebarUpdate(server, ws);
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

fn handleWorkspaceClearLog(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const ws = resolveWorkspace(server, alloc, req) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    ws.clearLog();
    scheduleSidebarUpdate(server, ws);
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

fn handleWorkspaceSetProgress(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const ws = resolveWorkspace(server, alloc, req) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    const fraction = req.getFloatParam(alloc, "fraction") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'fraction' parameter");
    };

    const label = req.getStringParam(alloc, "label");
    defer if (label) |l| alloc.free(l);

    ws.setProgress(@floatCast(fraction), label);
    scheduleSidebarUpdate(server, ws);
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

fn handleWorkspaceSetPinned(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const ws = resolveWorkspace(server, alloc, req) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    const pinned = req.getBoolParam(alloc, "pinned") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'pinned' parameter");
    };

    ws.pinned = pinned;

    // Pinning changes sort order, so rebuild entire sidebar (not just update one row)
    scheduleSidebarRebuild(server);
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

fn handleWorkspaceSetColor(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const ws = resolveWorkspace(server, alloc, req) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    const color = req.getStringParam(alloc, "color");
    if (color) |name| {
        if (name.len == 0) {
            // Empty string clears color
            ws.clearColor();
        } else if (!Workspace.isValidColor(name)) {
            return protocol.errorResponse(alloc, req.id, "invalid_color", "Color must be one of: red, blue, green, yellow, purple, orange, pink, cyan");
        } else {
            ws.setColor(name);
        }
    } else {
        // null or missing clears the color
        ws.clearColor();
    }

    scheduleSidebarUpdate(server, ws);
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

/// Schedule a full sidebar rebuild on the GTK main thread.
fn scheduleSidebarRebuild(server: *Server) void {
    const window = server.window orelse return;
    const ctx = std.heap.c_allocator.create(SidebarRebuildCtx) catch return;
    ctx.* = .{ .window = window };
    _ = c.g_idle_add(&doSidebarRebuild, @ptrCast(ctx));
}

const SidebarRebuildCtx = struct {
    window: *Window,
};

fn doSidebarRebuild(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *SidebarRebuildCtx = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(ctx);
    ctx.window.sidebar.rebuild();
    return c.G_SOURCE_REMOVE;
}

// ------------------------------------------------------------------
// Surface handlers
// ------------------------------------------------------------------

fn handleSurfaceList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"surfaces\":[]}");
    };

    var array = JsonArrayBuilder.init(alloc);
    defer array.deinit();
    try array.startArray();

    const tm = &window.tab_manager;
    for (tm.workspaces.items) |ws| {
        var pane_ids = try ws.pane_tree.orderedPaneIds(alloc);
        defer pane_ids.deinit(alloc);

        for (pane_ids.items) |pane_id| {
            const is_focused = if (ws.pane_tree.focused_pane) |fp| fp == pane_id else false;
            const has_surface = window.pane_widgets.get(pane_id) != null;

            const surface_json = try std.fmt.allocPrint(alloc,
                \\{{"id":{d},"ref":"surface:{d}","workspace_id":{d},"pane_id":{d},"focused":{s},"alive":{s}}}
            , .{
                pane_id,
                pane_id,
                ws.id,
                pane_id,
                if (is_focused) "true" else "false",
                if (has_surface) "true" else "false",
            });
            defer alloc.free(surface_json);
            try array.addRaw(surface_json);
        }
    }

    try array.endArray();
    const surfaces_json = try array.toOwnedSlice();
    defer alloc.free(surfaces_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"surfaces":{s}}}
    , .{surfaces_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleSurfaceCurrent(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"surface\":null}");
    };

    const ws = window.tab_manager.selectedWorkspace() orelse {
        return protocol.successResponse(alloc, req.id, "{\"surface\":null}");
    };

    const pane_id = ws.pane_tree.focused_pane orelse {
        return protocol.successResponse(alloc, req.id, "{\"surface\":null}");
    };

    const has_surface = window.pane_widgets.get(pane_id) != null;

    const surface_json = try std.fmt.allocPrint(alloc,
        \\{{"surface":{{"id":{d},"ref":"surface:{d}","workspace_id":{d},"pane_id":{d},"focused":true,"alive":{s}}}}}
    , .{
        pane_id,
        pane_id,
        ws.id,
        pane_id,
        if (has_surface) "true" else "false",
    });
    defer alloc.free(surface_json);
    return protocol.successResponse(alloc, req.id, surface_json);
}

fn handleSurfaceSendText(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const text = req.getStringParam(alloc, "text") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'text' parameter");
    };
    defer alloc.free(text);

    // Find the target surface: by surface_id param, or use the focused surface
    var target_pane_id: ?PaneTree.NodeId = null;
    if (req.getIntParam(alloc, "surface_id")) |sid| {
        target_pane_id = toU64(sid);
    } else {
        // Use focused surface in current workspace
        if (window.tab_manager.selectedWorkspace()) |ws| {
            target_pane_id = ws.pane_tree.focused_pane;
        }
    }

    const pane_id = target_pane_id orelse {
        return protocol.errorResponse(alloc, req.id, "no_surface", "No target surface found");
    };

    const tw = window.pane_widgets.get(pane_id) orelse {
        return protocol.errorResponse(alloc, req.id, "no_surface", "Surface widget not found");
    };

    if (tw.surface == null or !tw.realized) {
        return protocol.errorResponse(alloc, req.id, "dead_surface", "Surface is not active (unrealized or uninitialized)");
    }

    // Use ghostty_surface_binding_action with "text:" prefix to write directly
    // to the PTY. This avoids bracketed paste mode (which ghostty_surface_text
    // uses) so that control characters like \n are properly interpreted by the
    // shell as Enter.
    //
    // The "text:" binding action expects Zig string literal escape syntax, so
    // we encode control characters (< 0x20) and DEL (0x7f) as \xHH sequences.
    // Printable ASCII and valid UTF-8 sequences are passed through as-is.
    const action_str = try encodeBindingActionText(alloc, text);
    defer alloc.free(action_str);

    _ = c.ghostty_surface_binding_action(tw.surface, action_str.ptr, action_str.len);

    log.info("send_text to pane {d}: {d} bytes", .{ pane_id, text.len });

    const result = try std.fmt.allocPrint(alloc,
        \\{{"queued":true,"surface_id":{d}}}
    , .{pane_id});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

/// Encode text as a Ghostty binding action string: "text:<zig-escaped-content>".
/// Control characters (< 0x20, 0x7F) are escaped as \xHH.
/// Backslashes are escaped as \\.
/// All other bytes (printable ASCII, UTF-8) are passed through.
fn encodeBindingActionText(alloc: Allocator, text: []const u8) ![]const u8 {
    const prefix = "text:";
    // Worst case: every byte becomes \xHH (4 chars), plus prefix
    var buf = try alloc.alloc(u8, prefix.len + text.len * 4);
    errdefer alloc.free(buf);

    @memcpy(buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;

    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7F) {
            // Control characters: encode as \xHH
            buf[pos] = '\\';
            buf[pos + 1] = 'x';
            buf[pos + 2] = hexDigit(byte >> 4);
            buf[pos + 3] = hexDigit(byte & 0x0f);
            pos += 4;
        } else if (byte == '\\') {
            // Escape backslashes
            buf[pos] = '\\';
            buf[pos + 1] = '\\';
            pos += 2;
        } else {
            // Printable ASCII and UTF-8 continuation bytes: pass through
            buf[pos] = byte;
            pos += 1;
        }
    }

    // Shrink to actual size
    const result = try alloc.realloc(buf, pos);
    return result;
}

fn hexDigit(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
}

// ------------------------------------------------------------------
// surface.read_text — read terminal content via Ghostty API
// ------------------------------------------------------------------

const ReadTextCtx = struct {
    surface: c.ghostty_surface_t,
    include_scrollback: bool,
    // Output fields — written by main thread, read by handler thread
    result_text: ?[*]const u8 = null,
    result_len: usize = 0,
    success: bool = false,
    done: std.Thread.ResetEvent = .{},
};

fn handleSurfaceReadText(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    // Resolve target surface
    var target_pane_id: ?PaneTree.NodeId = null;
    if (req.getIntParam(alloc, "surface_id")) |sid| {
        target_pane_id = toU64(sid);
    } else {
        if (window.tab_manager.selectedWorkspace()) |ws| {
            target_pane_id = ws.pane_tree.focused_pane;
        }
    }

    const pane_id = target_pane_id orelse {
        return protocol.errorResponse(alloc, req.id, "no_surface", "No target surface found");
    };

    const tw = window.pane_widgets.get(pane_id) orelse {
        return protocol.errorResponse(alloc, req.id, "no_surface", "Surface widget not found");
    };

    if (tw.surface == null) {
        return protocol.errorResponse(alloc, req.id, "no_surface", "Surface not initialized");
    }

    const include_scrollback = req.getBoolParam(alloc, "scrollback") orelse false;

    // Dispatch to GTK main thread and block until complete
    const ctx = std.heap.c_allocator.create(ReadTextCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{
        .surface = tw.surface,
        .include_scrollback = include_scrollback,
    };
    _ = c.g_idle_add(&doReadText, @ptrCast(ctx));

    // Block until the main thread callback completes
    ctx.done.timedWait(gtk_dispatch_timeout_ns) catch {
        // Timeout: GTK main thread is unresponsive. Leak ctx to avoid use-after-free
        // since the GTK idle callback may still fire later.
        log.warn("GTK dispatch timed out for socket request", .{});
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };

    // Read results (main thread is done writing)
    const success = ctx.success;
    const result_text = ctx.result_text;
    const result_len = ctx.result_len;
    std.heap.c_allocator.destroy(ctx);

    if (!success) {
        return protocol.errorResponse(alloc, req.id, "read_failed", "Failed to read terminal text");
    }

    // Build JSON response with the text
    if (result_text) |text_ptr| {
        const text_slice = text_ptr[0..result_len];
        defer std.heap.c_allocator.free(text_slice);

        // JSON-escape the text
        var escaped: std.ArrayListUnmanaged(u8) = .{};
        defer escaped.deinit(alloc);
        for (text_slice) |ch| {
            switch (ch) {
                '"' => try escaped.appendSlice(alloc, "\\\""),
                '\\' => try escaped.appendSlice(alloc, "\\\\"),
                '\n' => try escaped.appendSlice(alloc, "\\n"),
                '\r' => try escaped.appendSlice(alloc, "\\r"),
                '\t' => try escaped.appendSlice(alloc, "\\t"),
                else => {
                    if (ch < 0x20) {
                        var buf: [6]u8 = undefined;
                        const hex_str = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch continue;
                        try escaped.appendSlice(alloc, hex_str);
                    } else {
                        try escaped.append(alloc, ch);
                    }
                },
            }
        }

        const result = try std.fmt.allocPrint(alloc,
            \\{{"text":"{s}","surface_id":{d}}}
        , .{ escaped.items, pane_id });
        defer alloc.free(result);
        return protocol.successResponse(alloc, req.id, result);
    }

    const result = try std.fmt.allocPrint(alloc,
        \\{{"text":"","surface_id":{d}}}
    , .{pane_id});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn doReadText(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *ReadTextCtx = @ptrCast(@alignCast(userdata));
    // Do NOT defer destroy — the handler thread still needs ctx
    defer ctx.done.set();

    if (ctx.surface == null) return c.G_SOURCE_REMOVE;

    const point_tag: c.ghostty_point_tag_e = if (ctx.include_scrollback)
        c.GHOSTTY_POINT_SCREEN
    else
        c.GHOSTTY_POINT_VIEWPORT;

    var selection: c.ghostty_selection_s = std.mem.zeroes(c.ghostty_selection_s);
    selection.top_left.tag = point_tag;
    selection.top_left.coord = c.GHOSTTY_POINT_COORD_TOP_LEFT;
    selection.top_left.x = 0;
    selection.top_left.y = 0;
    selection.bottom_right.tag = point_tag;
    selection.bottom_right.coord = c.GHOSTTY_POINT_COORD_BOTTOM_RIGHT;
    selection.bottom_right.x = 0;
    selection.bottom_right.y = 0;
    selection.rectangle = true;

    var text: c.ghostty_text_s = std.mem.zeroes(c.ghostty_text_s);
    if (c.ghostty_surface_read_text(ctx.surface, selection, &text)) {
        defer c.ghostty_surface_free_text(ctx.surface, &text);
        if (text.text != null and text.text_len > 0) {
            // Copy text into heap-allocated buffer for the handler thread
            const slice = text.text[0..text.text_len];
            const copy = std.heap.c_allocator.alloc(u8, text.text_len) catch {
                return c.G_SOURCE_REMOVE;
            };
            @memcpy(copy, slice);
            ctx.result_text = copy.ptr;
            ctx.result_len = text.text_len;
        }
        ctx.success = true;
    }

    return c.G_SOURCE_REMOVE;
}

/// Reusable helper: read terminal text via g_idle_add + ResetEvent.
/// Returns heap-allocated text (caller must free with c_allocator), or null on failure.
fn readSurfaceText(surface: c.ghostty_surface_t) ?[]u8 {
    const ctx = std.heap.c_allocator.create(ReadTextCtx) catch return null;
    ctx.* = .{ .surface = surface, .include_scrollback = true };
    _ = c.g_idle_add(&doReadText, @ptrCast(ctx));
    ctx.done.timedWait(gtk_dispatch_timeout_ns) catch {
        log.warn("readSurfaceText: GTK dispatch timed out", .{});
        // Don't destroy ctx — the GTK callback may still fire and access it.
        return null;
    };
    const text_ptr = ctx.result_text;
    const text_len = ctx.result_len;
    const success = ctx.success;
    std.heap.c_allocator.destroy(ctx);
    if (!success or text_ptr == null) return null;
    return @constCast(text_ptr.?[0..text_len]);
}

// ------------------------------------------------------------------
// surface.run — send command, wait for prompt, return output
// ------------------------------------------------------------------

fn handleSurfaceRun(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    // 1. Extract params
    const command = req.getStringParam(alloc, "command") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'command' parameter");
    };
    defer alloc.free(command);

    const timeout_secs: u64 = if (req.getIntParam(alloc, "timeout")) |t|
        toU64(@max(t, 1)) orelse 30
    else
        30;
    const timeout_ns: u64 = timeout_secs * 1_000_000_000;

    const prompt_suffix = req.getStringParam(alloc, "prompt_pattern");
    defer if (prompt_suffix) |p| alloc.free(p);

    // 2. Resolve target surface
    var target_pane_id: ?PaneTree.NodeId = null;
    if (req.getIntParam(alloc, "surface_id")) |sid| {
        target_pane_id = toU64(sid);
    } else {
        if (window.tab_manager.selectedWorkspace()) |ws| {
            target_pane_id = ws.pane_tree.focused_pane;
        }
    }
    const pane_id = target_pane_id orelse {
        return protocol.errorResponse(alloc, req.id, "no_surface", "No target surface found");
    };
    const tw = window.pane_widgets.get(pane_id) orelse {
        return protocol.errorResponse(alloc, req.id, "no_surface", "Surface widget not found");
    };
    if (tw.surface == null or !tw.realized) {
        return protocol.errorResponse(alloc, req.id, "dead_surface", "Surface is not active");
    }

    // 3. Read "before" snapshot
    const before_text = readSurfaceText(tw.surface) orelse {
        return protocol.errorResponse(alloc, req.id, "read_failed", "Failed to read initial terminal text");
    };
    defer std.heap.c_allocator.free(before_text);

    // 4. Send command + Enter
    const cmd_with_newline = try std.fmt.allocPrint(alloc, "{s}\n", .{command});
    defer alloc.free(cmd_with_newline);
    const action_str = try encodeBindingActionText(alloc, cmd_with_newline);
    defer alloc.free(action_str);
    _ = c.ghostty_surface_binding_action(tw.surface, action_str.ptr, action_str.len);

    // 5. Poll loop — wait for prompt to reappear
    const poll_interval_ns: u64 = 150_000_000; // 150ms
    const start_ns: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var timed_out = true;
    var final_text: ?[]u8 = null;

    while (true) {
        const now_ns: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        const elapsed: u64 = now_ns -| start_ns; // saturating subtract handles clock weirdness
        if (elapsed >= timeout_ns) break;

        std.Thread.sleep(poll_interval_ns);

        const current = readSurfaceText(tw.surface) orelse continue;

        // Text must have grown beyond the before snapshot + command echo
        if (current.len > before_text.len) {
            if (endsWithPrompt(current, prompt_suffix)) {
                final_text = current;
                timed_out = false;
                break;
            }
        }
        std.heap.c_allocator.free(current);
    }

    // On timeout, do one final read
    if (timed_out and final_text == null) {
        final_text = readSurfaceText(tw.surface);
    }

    // 6. Extract output between command echo and final prompt
    const output = if (final_text) |ft| blk: {
        defer std.heap.c_allocator.free(ft);
        break :blk extractCommandOutput(alloc, before_text, ft, command) catch "";
    } else "";
    defer if (output.len > 0) alloc.free(@constCast(output));

    // 7. Build JSON response
    const escaped_output = try jsonEscapeString(alloc, output);
    defer alloc.free(escaped_output);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"output":"{s}","timed_out":{s},"surface_id":{d}}}
    , .{
        escaped_output,
        if (timed_out) "true" else "false",
        pane_id,
    });
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

/// Check if terminal text ends with a shell prompt.
fn endsWithPrompt(text: []const u8, custom_suffix: ?[]const u8) bool {
    // Find last non-empty line
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r')) end -= 1;
    if (end == 0) return false;
    var start = end;
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    const last_line = std.mem.trimRight(u8, text[start..end], " ");
    if (last_line.len == 0) return false;

    if (custom_suffix) |pat| {
        return std.mem.endsWith(u8, last_line, pat);
    }
    // Default: common prompt endings
    const suffixes = [_][]const u8{ "$ ", "# ", "% ", "> ", "$", "#", "%", ">" };
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, last_line, suffix)) return true;
    }
    return false;
}

/// Extract the command output from terminal text by diffing before/after snapshots.
/// Returns the text between the command echo line and the final prompt line.
fn extractCommandOutput(alloc: Allocator, before: []const u8, after: []const u8, command: []const u8) ![]const u8 {
    // Find where the new content starts — skip the "before" text
    const new_start = if (after.len > before.len and std.mem.startsWith(u8, after, before))
        before.len
    else blk: {
        // Text may have scrolled — find the command echo in the after text
        break :blk if (std.mem.indexOf(u8, after, command)) |cmd_pos| cmd_pos else 0;
    };

    if (new_start >= after.len) return try alloc.dupe(u8, "");

    const new_text = after[new_start..];

    // Skip the command echo line (first line containing the command)
    var output_start: usize = 0;
    if (std.mem.indexOf(u8, new_text, command)) |cmd_offset| {
        // Find end of the line containing the command
        if (std.mem.indexOfPos(u8, new_text, cmd_offset, "\n")) |nl| {
            output_start = nl + 1;
        }
    }

    // Find the last prompt line and exclude it
    var output_end = new_text.len;
    // Trim trailing newlines
    while (output_end > output_start and (new_text[output_end - 1] == '\n' or new_text[output_end - 1] == '\r')) {
        output_end -= 1;
    }
    // Find the start of the last line
    var last_line_start = output_end;
    while (last_line_start > output_start and new_text[last_line_start - 1] != '\n') {
        last_line_start -= 1;
    }
    // If the last line looks like a prompt, exclude it
    const last_line = std.mem.trimRight(u8, new_text[last_line_start..output_end], " ");
    const suffixes = [_][]const u8{ "$ ", "# ", "% ", "> ", "$", "#", "%", ">" };
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, last_line, suffix)) {
            output_end = last_line_start;
            break;
        }
    }

    // Trim trailing whitespace from output
    while (output_end > output_start and (new_text[output_end - 1] == '\n' or new_text[output_end - 1] == '\r' or new_text[output_end - 1] == ' ')) {
        output_end -= 1;
    }

    if (output_start >= output_end) return try alloc.dupe(u8, "");
    return try alloc.dupe(u8, new_text[output_start..output_end]);
}

// ------------------------------------------------------------------
// surface.send_key — send individual keystrokes
// ------------------------------------------------------------------

fn handleSurfaceSendKey(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const key = req.getStringParam(alloc, "key") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'key' parameter");
    };
    defer alloc.free(key);

    // Resolve target surface
    var target_pane_id: ?PaneTree.NodeId = null;
    if (req.getIntParam(alloc, "surface_id")) |sid| {
        target_pane_id = toU64(sid);
    } else {
        if (window.tab_manager.selectedWorkspace()) |ws| {
            target_pane_id = ws.pane_tree.focused_pane;
        }
    }

    const pane_id = target_pane_id orelse {
        return protocol.errorResponse(alloc, req.id, "no_surface", "No target surface found");
    };

    const tw = window.pane_widgets.get(pane_id) orelse {
        return protocol.errorResponse(alloc, req.id, "no_surface", "Surface widget not found");
    };

    if (tw.surface == null or !tw.realized) {
        return protocol.errorResponse(alloc, req.id, "dead_surface", "Surface is not active (unrealized or uninitialized)");
    }

    const action_bytes = resolveKeyAction(alloc, key) orelse {
        return protocol.errorResponse(alloc, req.id, "unknown_key", "Unknown key name");
    };
    defer alloc.free(action_bytes);

    _ = c.ghostty_surface_binding_action(tw.surface, action_bytes.ptr, action_bytes.len);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"sent":true,"key":"{s}","surface_id":{d}}}
    , .{ key, pane_id });
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

/// Map a named key to a Ghostty binding action string.
fn resolveKeyAction(alloc: Allocator, key_name: []const u8) ?[]const u8 {
    // Normalize to lowercase
    var lower_buf: [64]u8 = undefined;
    if (key_name.len > lower_buf.len) return null;
    for (key_name, 0..) |ch, i| {
        lower_buf[i] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
    }
    const lower = lower_buf[0..key_name.len];

    const eql = std.mem.eql;

    // Map key names to binding action strings
    const seq: ?[]const u8 = if (eql(u8, lower, "ctrl-c") or eql(u8, lower, "ctrl+c"))
        "text:\\x03"
    else if (eql(u8, lower, "ctrl-d") or eql(u8, lower, "ctrl+d"))
        "text:\\x04"
    else if (eql(u8, lower, "ctrl-z") or eql(u8, lower, "ctrl+z"))
        "text:\\x1a"
    else if (eql(u8, lower, "ctrl-\\") or eql(u8, lower, "ctrl+\\"))
        "text:\\x1c"
    else if (eql(u8, lower, "ctrl-a") or eql(u8, lower, "ctrl+a"))
        "text:\\x01"
    else if (eql(u8, lower, "ctrl-e") or eql(u8, lower, "ctrl+e"))
        "text:\\x05"
    else if (eql(u8, lower, "ctrl-l") or eql(u8, lower, "ctrl+l"))
        "text:\\x0c"
    else if (eql(u8, lower, "ctrl-r") or eql(u8, lower, "ctrl+r"))
        "text:\\x12"
    else if (eql(u8, lower, "ctrl-u") or eql(u8, lower, "ctrl+u"))
        "text:\\x15"
    else if (eql(u8, lower, "ctrl-w") or eql(u8, lower, "ctrl+w"))
        "text:\\x17"
    else if (eql(u8, lower, "enter") or eql(u8, lower, "return"))
        "text:\\x0d"
    else if (eql(u8, lower, "tab"))
        "text:\\x09"
    else if (eql(u8, lower, "escape") or eql(u8, lower, "esc"))
        "text:\\x1b"
    else if (eql(u8, lower, "backspace"))
        "text:\\x7f"
    else if (eql(u8, lower, "space"))
        "text:\\x20"
    else if (eql(u8, lower, "up") or eql(u8, lower, "arrow_up"))
        "text:\\x1b[A"
    else if (eql(u8, lower, "down") or eql(u8, lower, "arrow_down"))
        "text:\\x1b[B"
    else if (eql(u8, lower, "right") or eql(u8, lower, "arrow_right"))
        "text:\\x1b[C"
    else if (eql(u8, lower, "left") or eql(u8, lower, "arrow_left"))
        "text:\\x1b[D"
    else if (eql(u8, lower, "home"))
        "text:\\x1b[H"
    else if (eql(u8, lower, "end"))
        "text:\\x1b[F"
    else if (eql(u8, lower, "page_up") or eql(u8, lower, "pageup"))
        "text:\\x1b[5~"
    else if (eql(u8, lower, "page_down") or eql(u8, lower, "pagedown"))
        "text:\\x1b[6~"
    else if (eql(u8, lower, "delete") or eql(u8, lower, "del"))
        "text:\\x1b[3~"
    else if (eql(u8, lower, "insert"))
        "text:\\x1b[2~"
    else blk: {
        // Generic ctrl-<letter> pattern
        if (lower.len >= 6 and (eql(u8, lower[0..5], "ctrl-") or eql(u8, lower[0..5], "ctrl+"))) {
            const letter = lower[5..];
            if (letter.len == 1 and letter[0] >= 'a' and letter[0] <= 'z') {
                const ctrl_byte = letter[0] - 'a' + 1;
                return std.fmt.allocPrint(alloc, "text:\\x{x:0>2}", .{ctrl_byte}) catch null;
            }
        }
        break :blk null;
    };

    if (seq) |s| {
        return alloc.dupe(u8, s) catch null;
    }
    return null;
}

// ------------------------------------------------------------------
// surface.split — create splits via socket
// ------------------------------------------------------------------

const SplitCtx = struct {
    window: *Window,
    direction: PaneTree.SplitDirection,
    success: bool = false,
    err_code: []const u8 = "internal_error",
    err_msg: []const u8 = "Unknown error",
    done: std.Thread.ResetEvent = .{},
};

fn handleSurfaceSplit(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const dir_str = req.getStringParam(alloc, "direction") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'direction' parameter");
    };
    defer alloc.free(dir_str);

    const direction = parseDirection(dir_str) orelse {
        return protocol.errorResponse(alloc, req.id, "invalid_param", "direction must be left/right/up/down");
    };

    const ctx = std.heap.c_allocator.create(SplitCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{ .window = window, .direction = direction };
    _ = c.g_idle_add(&doSplit, @ptrCast(ctx));

    ctx.done.timedWait(gtk_dispatch_timeout_ns) catch {
        // Timeout: GTK main thread is unresponsive. Leak ctx to avoid use-after-free
        // since the GTK idle callback may still fire later.
        log.warn("GTK dispatch timed out for socket request", .{});
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };

    const success = ctx.success;
    const err_code = ctx.err_code;
    const err_msg = ctx.err_msg;
    std.heap.c_allocator.destroy(ctx);

    if (success) {
        return protocol.successResponse(alloc, req.id, "{\"split\":true}");
    } else {
        return protocol.errorResponse(alloc, req.id, err_code, err_msg);
    }
}

fn doSplit(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *SplitCtx = @ptrCast(@alignCast(userdata));
    defer ctx.done.set();
    ctx.window.splitFocused(ctx.direction) catch |err| {
        log.warn("Failed to split from socket: {}", .{err});
        ctx.err_code = "split_failed";
        ctx.err_msg = "Failed to create split";
        return c.G_SOURCE_REMOVE;
    };
    ctx.success = true;
    return c.G_SOURCE_REMOVE;
}

fn parseDirection(dir_str: []const u8) ?PaneTree.SplitDirection {
    if (std.mem.eql(u8, dir_str, "left")) return .left;
    if (std.mem.eql(u8, dir_str, "right")) return .right;
    if (std.mem.eql(u8, dir_str, "up")) return .up;
    if (std.mem.eql(u8, dir_str, "down")) return .down;
    return null;
}

// ------------------------------------------------------------------
// surface.close — close pane via socket
// ------------------------------------------------------------------

const SurfaceCloseCtx = struct {
    window: *Window,
    success: bool = false,
    err_code: []const u8 = "internal_error",
    err_msg: []const u8 = "Unknown error",
    done: std.Thread.ResetEvent = .{},
};

fn handleSurfaceClose(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const ws = window.tab_manager.selectedWorkspace() orelse {
        return protocol.errorResponse(alloc, req.id, "no_workspace", "No workspace selected");
    };

    // Guard: can't close the last pane
    if (ws.pane_tree.paneCount() <= 1) {
        return protocol.errorResponse(alloc, req.id, "last_pane", "Cannot close the last pane");
    }

    const ctx = std.heap.c_allocator.create(SurfaceCloseCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{ .window = window };
    _ = c.g_idle_add(&doCloseSurface, @ptrCast(ctx));

    ctx.done.timedWait(gtk_dispatch_timeout_ns) catch {
        // Timeout: GTK main thread is unresponsive. Leak ctx to avoid use-after-free
        // since the GTK idle callback may still fire later.
        log.warn("GTK dispatch timed out for socket request", .{});
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };

    const success = ctx.success;
    const err_code = ctx.err_code;
    const err_msg = ctx.err_msg;
    std.heap.c_allocator.destroy(ctx);

    if (success) {
        return protocol.successResponse(alloc, req.id, "{\"closed\":true}");
    } else {
        return protocol.errorResponse(alloc, req.id, err_code, err_msg);
    }
}

fn doCloseSurface(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *SurfaceCloseCtx = @ptrCast(@alignCast(userdata));
    defer ctx.done.set();
    ctx.window.closeFocused() catch |err| {
        log.warn("Failed to close surface from socket: {}", .{err});
        ctx.err_code = "close_failed";
        ctx.err_msg = "Failed to close surface";
        return c.G_SOURCE_REMOVE;
    };
    ctx.success = true;
    return c.G_SOURCE_REMOVE;
}

// ------------------------------------------------------------------
// surface.search
// ------------------------------------------------------------------

fn handleSurfaceSearch(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const text = req.getStringParam(alloc, "text") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'text' parameter");
    };
    defer alloc.free(text);

    // Schedule search on GTK main thread
    const text_copy = alloc.dupe(u8, text) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate");
    };
    const ctx = alloc.create(SearchCtx) catch {
        alloc.free(text_copy);
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate");
    };
    ctx.* = .{ .window = window, .text = text_copy, .alloc = alloc };
    _ = c.g_idle_add(&doSearch, @ptrCast(ctx));

    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

const SearchCtx = struct {
    window: *Window,
    text: []const u8,
    alloc: Allocator,
};

fn doSearch(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *SearchCtx = @ptrCast(@alignCast(userdata));
    defer {
        ctx.alloc.free(ctx.text);
        ctx.alloc.destroy(ctx);
    }

    // Get the focused terminal surface
    const ws = ctx.window.tab_manager.selectedWorkspace() orelse return c.G_SOURCE_REMOVE;
    const focused = ws.pane_tree.focused_pane orelse return c.G_SOURCE_REMOVE;
    const tw = ctx.window.pane_widgets.get(focused) orelse return c.G_SOURCE_REMOVE;

    // Show the search overlay with this surface
    ctx.window.search_overlay.show(tw.surface);

    // Send the search text to Ghostty
    var cmd_buf: [1024]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "search:{s}", .{ctx.text}) catch return c.G_SOURCE_REMOVE;
    _ = c.ghostty_surface_binding_action(tw.surface, cmd.ptr, cmd.len);

    return c.G_SOURCE_REMOVE;
}

// ------------------------------------------------------------------
// workspace.next / workspace.previous / workspace.last
// ------------------------------------------------------------------

fn handleWorkspaceNext(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const tm = &window.tab_manager;
    const idx = tm.selected_index orelse {
        return protocol.errorResponse(alloc, req.id, "no_workspace", "No workspace selected");
    };

    if (idx + 1 >= tm.workspaces.items.len) {
        return protocol.errorResponse(alloc, req.id, "at_end", "Already at last workspace");
    }

    const next_idx = idx + 1;
    const ctx = std.heap.c_allocator.create(WorkspaceSwitchCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{ .window = window, .index = next_idx };
    _ = c.g_idle_add(&doWorkspaceSwitch, @ptrCast(ctx));
    ctx.done.timedWait(gtk_dispatch_timeout_ns) catch {
        // Timeout: GTK main thread is unresponsive. Leak ctx to avoid use-after-free
        // since the GTK idle callback may still fire later.
        log.warn("GTK dispatch timed out for socket request", .{});
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };

    const success = ctx.success;
    std.heap.c_allocator.destroy(ctx);

    if (!success) {
        return protocol.errorResponse(alloc, req.id, "switch_failed", "Failed to switch workspace");
    }

    const ws = tm.workspaces.items[next_idx];
    const ws_json = try workspaceToJson(alloc, ws, true, next_idx);
    defer alloc.free(ws_json);
    const result = try std.fmt.allocPrint(alloc,
        \\{{"workspace":{s}}}
    , .{ws_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleWorkspacePrevious(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const tm = &window.tab_manager;
    const idx = tm.selected_index orelse {
        return protocol.errorResponse(alloc, req.id, "no_workspace", "No workspace selected");
    };

    if (idx == 0) {
        return protocol.errorResponse(alloc, req.id, "at_start", "Already at first workspace");
    }

    const prev_idx = idx - 1;
    const ctx = std.heap.c_allocator.create(WorkspaceSwitchCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{ .window = window, .index = prev_idx };
    _ = c.g_idle_add(&doWorkspaceSwitch, @ptrCast(ctx));
    ctx.done.timedWait(gtk_dispatch_timeout_ns) catch {
        // Timeout: GTK main thread is unresponsive. Leak ctx to avoid use-after-free
        // since the GTK idle callback may still fire later.
        log.warn("GTK dispatch timed out for socket request", .{});
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };

    const success = ctx.success;
    std.heap.c_allocator.destroy(ctx);

    if (!success) {
        return protocol.errorResponse(alloc, req.id, "switch_failed", "Failed to switch workspace");
    }

    const ws = tm.workspaces.items[prev_idx];
    const ws_json = try workspaceToJson(alloc, ws, true, prev_idx);
    defer alloc.free(ws_json);
    const result = try std.fmt.allocPrint(alloc,
        \\{{"workspace":{s}}}
    , .{ws_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleWorkspaceLast(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const tm = &window.tab_manager;
    if (tm.history.items.len == 0) {
        return protocol.errorResponse(alloc, req.id, "no_history", "No workspace history");
    }

    const last_id = tm.history.items[tm.history.items.len - 1];

    // Find index for this workspace ID
    var target_index: ?usize = null;
    for (tm.workspaces.items, 0..) |ws, i| {
        if (ws.id == last_id) {
            target_index = i;
            break;
        }
    }

    const idx = target_index orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Last workspace no longer exists");
    };

    const ctx = std.heap.c_allocator.create(WorkspaceSwitchCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{ .window = window, .index = idx };
    _ = c.g_idle_add(&doWorkspaceSwitch, @ptrCast(ctx));
    ctx.done.timedWait(gtk_dispatch_timeout_ns) catch {
        // Timeout: GTK main thread is unresponsive. Leak ctx to avoid use-after-free
        // since the GTK idle callback may still fire later.
        log.warn("GTK dispatch timed out for socket request", .{});
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };

    const success = ctx.success;
    std.heap.c_allocator.destroy(ctx);

    if (!success) {
        return protocol.errorResponse(alloc, req.id, "switch_failed", "Failed to switch workspace");
    }

    const ws = tm.workspaces.items[idx];
    const ws_json = try workspaceToJson(alloc, ws, true, idx);
    defer alloc.free(ws_json);
    const result = try std.fmt.allocPrint(alloc,
        \\{{"workspace":{s}}}
    , .{ws_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

// ------------------------------------------------------------------
// pane.resize — resize pane divider via socket
// ------------------------------------------------------------------

const PaneResizeCtx = struct {
    window: *Window,
    pane_id: PaneTree.NodeId,
    direction: PaneTree.SplitDirection,
    delta: f64,
    success: bool = false,
    err_code: []const u8 = "internal_error",
    err_msg: []const u8 = "Unknown error",
    done: std.Thread.ResetEvent = .{},
};

fn handlePaneResize(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const pane_id_raw = req.getIntParam(alloc, "pane_id") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'pane_id' parameter");
    };

    const dir_str = req.getStringParam(alloc, "direction") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'direction' parameter");
    };
    defer alloc.free(dir_str);

    const direction = parseDirection(dir_str) orelse {
        return protocol.errorResponse(alloc, req.id, "invalid_param", "direction must be left/right/up/down");
    };

    const amount = req.getFloatParam(alloc, "amount") orelse 0.1;

    const ctx = std.heap.c_allocator.create(PaneResizeCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{
        .window = window,
        .pane_id = toU64(pane_id_raw) orelse {
            std.heap.c_allocator.destroy(ctx);
            return protocol.errorResponse(alloc, req.id, "invalid_param", "pane_id must be non-negative");
        },
        .direction = direction,
        .delta = amount,
    };
    _ = c.g_idle_add(&doPaneResize, @ptrCast(ctx));

    // Block until the main thread callback completes
    ctx.done.timedWait(gtk_dispatch_timeout_ns) catch {
        // Timeout: GTK main thread is unresponsive. Leak ctx to avoid use-after-free
        // since the GTK idle callback may still fire later.
        log.warn("GTK dispatch timed out for socket request", .{});
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };

    const success = ctx.success;
    const err_code = ctx.err_code;
    const err_msg = ctx.err_msg;
    std.heap.c_allocator.destroy(ctx);

    if (success) {
        return protocol.successResponse(alloc, req.id, "{\"resized\":true}");
    } else {
        return protocol.errorResponse(alloc, req.id, err_code, err_msg);
    }
}

fn doPaneResize(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *PaneResizeCtx = @ptrCast(@alignCast(userdata));
    // Do NOT defer destroy — the handler thread still needs ctx
    defer ctx.done.set();

    const ws = ctx.window.tab_manager.selectedWorkspace() orelse {
        ctx.err_code = "no_workspace";
        ctx.err_msg = "No workspace selected";
        return c.G_SOURCE_REMOVE;
    };

    ws.pane_tree.resize(ctx.pane_id, ctx.direction, ctx.delta) catch |err| {
        log.warn("Failed to resize pane {d}: {}", .{ ctx.pane_id, err });
        ctx.err_code = "not_found";
        ctx.err_msg = "Pane not found or cannot resize";
        return c.G_SOURCE_REMOVE;
    };

    // Sync GTK widget positions to match updated data model
    ctx.window.syncDividerPositions(ws);
    ctx.success = true;

    return c.G_SOURCE_REMOVE;
}

// ------------------------------------------------------------------
// pane.swap — swap two panes via socket
// ------------------------------------------------------------------

const PaneSwapCtx = struct {
    window: *Window,
    pane_a: PaneTree.NodeId,
    pane_b: PaneTree.NodeId,
    success: bool = false,
    err_code: []const u8 = "internal_error",
    err_msg: []const u8 = "Unknown error",
    done: std.Thread.ResetEvent = .{},
};

fn handlePaneSwap(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const pane_a_raw = req.getIntParam(alloc, "pane_a") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'pane_a' parameter");
    };
    const pane_b_raw = req.getIntParam(alloc, "pane_b") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'pane_b' parameter");
    };

    const ctx = std.heap.c_allocator.create(PaneSwapCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{
        .window = window,
        .pane_a = toU64(pane_a_raw) orelse {
            std.heap.c_allocator.destroy(ctx);
            return protocol.errorResponse(alloc, req.id, "invalid_param", "pane_a must be non-negative");
        },
        .pane_b = toU64(pane_b_raw) orelse {
            std.heap.c_allocator.destroy(ctx);
            return protocol.errorResponse(alloc, req.id, "invalid_param", "pane_b must be non-negative");
        },
    };
    _ = c.g_idle_add(&doPaneSwap, @ptrCast(ctx));

    ctx.done.timedWait(gtk_dispatch_timeout_ns) catch {
        // Timeout: GTK main thread is unresponsive. Leak ctx to avoid use-after-free
        // since the GTK idle callback may still fire later.
        log.warn("GTK dispatch timed out for socket request", .{});
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };

    const success = ctx.success;
    const err_code = ctx.err_code;
    const err_msg = ctx.err_msg;
    std.heap.c_allocator.destroy(ctx);

    if (success) {
        return protocol.successResponse(alloc, req.id, "{\"swapped\":true}");
    } else {
        return protocol.errorResponse(alloc, req.id, err_code, err_msg);
    }
}

fn doPaneSwap(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *PaneSwapCtx = @ptrCast(@alignCast(userdata));
    defer ctx.done.set();

    const ws = ctx.window.tab_manager.selectedWorkspace() orelse {
        ctx.err_code = "no_workspace";
        ctx.err_msg = "No workspace selected";
        return c.G_SOURCE_REMOVE;
    };

    // Perform data model swap
    ws.pane_tree.swap(ctx.pane_a, ctx.pane_b) catch |err| {
        log.warn("Failed to swap panes: {}", .{err});
        ctx.err_code = "not_found";
        ctx.err_msg = "Pane not found or cannot swap";
        return c.G_SOURCE_REMOVE;
    };

    // Swap widget registrations
    const widget_a = ctx.window.pane_widgets.get(ctx.pane_a);
    const widget_b = ctx.window.pane_widgets.get(ctx.pane_b);
    if (widget_a) |wa| ctx.window.pane_widgets.put(ctx.pane_b, wa) catch {};
    if (widget_b) |wb| ctx.window.pane_widgets.put(ctx.pane_a, wb) catch {};

    const nw_a = ctx.window.node_widgets.get(ctx.pane_a);
    const nw_b = ctx.window.node_widgets.get(ctx.pane_b);
    if (nw_a) |na| ctx.window.node_widgets.put(ctx.pane_b, na) catch {};
    if (nw_b) |nb| ctx.window.node_widgets.put(ctx.pane_a, nb) catch {};

    // Rebuild GTK widget tree to reflect new layout
    ctx.window.rebuildCurrentWorkspace() catch |err| {
        log.warn("Failed to rebuild workspace after swap: {}", .{err});
        ctx.err_code = "rebuild_failed";
        ctx.err_msg = "Swap succeeded but failed to rebuild workspace";
        return c.G_SOURCE_REMOVE;
    };

    ctx.success = true;
    return c.G_SOURCE_REMOVE;
}

// ------------------------------------------------------------------
// Pane break/join handlers
// ------------------------------------------------------------------

fn handlePaneBreak(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const pane_id_raw = req.getIntParam(alloc, "pane_id") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'pane_id' parameter");
    };

    const ctx = std.heap.c_allocator.create(PaneBreakCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate");
    };
    ctx.* = .{
        .window = window,
        .pane_id = toU64(pane_id_raw) orelse {
            std.heap.c_allocator.destroy(ctx);
            return protocol.errorResponse(alloc, req.id, "invalid_param", "pane_id must be non-negative");
        },
    };
    _ = c.g_idle_add(&doPaneBreak, @ptrCast(ctx));

    ctx.done.timedWait(gtk_dispatch_timeout_ns) catch {
        // Timeout: GTK main thread is unresponsive. Leak ctx to avoid use-after-free
        // since the GTK idle callback may still fire later.
        log.warn("GTK dispatch timed out for socket request", .{});
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };

    const success = ctx.success;
    const err_code = ctx.err_code;
    const err_msg = ctx.err_msg;
    std.heap.c_allocator.destroy(ctx);

    if (success) {
        return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
    } else {
        return protocol.errorResponse(alloc, req.id, err_code, err_msg);
    }
}

const PaneBreakCtx = struct {
    window: *Window,
    pane_id: PaneTree.NodeId,
    success: bool = false,
    err_code: []const u8 = "internal_error",
    err_msg: []const u8 = "Unknown error",
    done: std.Thread.ResetEvent = .{},
};

fn doPaneBreak(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *PaneBreakCtx = @ptrCast(@alignCast(userdata));
    defer ctx.done.set();

    ctx.window.breakPaneToNewWorkspace(ctx.pane_id) catch |err| {
        switch (err) {
            error.LastPane => {
                ctx.err_code = "last_pane";
                ctx.err_msg = "Cannot break the last pane";
            },
            else => {
                ctx.err_code = "break_failed";
                ctx.err_msg = "Failed to break pane";
            },
        }
        log.warn("Failed to break pane: {}", .{err});
        return c.G_SOURCE_REMOVE;
    };
    ctx.success = true;

    return c.G_SOURCE_REMOVE;
}

fn handlePaneJoin(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const pane_id_raw = req.getIntParam(alloc, "pane_id") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'pane_id' parameter");
    };
    const ws_id_raw = req.getIntParam(alloc, "workspace_id") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'workspace_id' parameter");
    };

    const ctx = std.heap.c_allocator.create(PaneJoinCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate");
    };
    ctx.* = .{
        .window = window,
        .pane_id = toU64(pane_id_raw) orelse {
            std.heap.c_allocator.destroy(ctx);
            return protocol.errorResponse(alloc, req.id, "invalid_param", "pane_id must be non-negative");
        },
        .workspace_id = toU64(ws_id_raw) orelse {
            std.heap.c_allocator.destroy(ctx);
            return protocol.errorResponse(alloc, req.id, "invalid_param", "workspace_id must be non-negative");
        },
    };
    _ = c.g_idle_add(&doPaneJoin, @ptrCast(ctx));

    // Block until the main thread callback completes
    ctx.done.timedWait(gtk_dispatch_timeout_ns) catch {
        // Timeout: GTK main thread is unresponsive. Leak ctx to avoid use-after-free
        // since the GTK idle callback may still fire later.
        log.warn("GTK dispatch timed out for socket request", .{});
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };

    const success = ctx.success;
    const err_code = ctx.err_code;
    const err_msg = ctx.err_msg;
    std.heap.c_allocator.destroy(ctx);

    if (success) {
        return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
    } else {
        return protocol.errorResponse(alloc, req.id, err_code, err_msg);
    }
}

const PaneJoinCtx = struct {
    window: *Window,
    pane_id: PaneTree.NodeId,
    workspace_id: Workspace.WorkspaceId,
    success: bool = false,
    err_code: []const u8 = "internal_error",
    err_msg: []const u8 = "Unknown error",
    done: std.Thread.ResetEvent = .{},
};

fn doPaneJoin(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *PaneJoinCtx = @ptrCast(@alignCast(userdata));
    // Do NOT defer destroy — the handler thread still needs ctx
    defer ctx.done.set();

    ctx.window.joinPaneToWorkspace(ctx.pane_id, ctx.workspace_id) catch |err| {
        switch (err) {
            error.PaneNotFound => {
                ctx.err_code = "not_found";
                ctx.err_msg = "Pane not found";
            },
            error.WorkspaceNotFound => {
                ctx.err_code = "not_found";
                ctx.err_msg = "Workspace not found";
            },
            error.SameWorkspace => {
                ctx.err_code = "invalid_param";
                ctx.err_msg = "Pane is already in that workspace";
            },
            else => {
                ctx.err_code = "internal_error";
                ctx.err_msg = "Failed to join pane";
            },
        }
        log.warn("Failed to join pane: {}", .{err});
        return c.G_SOURCE_REMOVE;
    };
    ctx.success = true;

    return c.G_SOURCE_REMOVE;
}

// ------------------------------------------------------------------
// Pane handlers
// ------------------------------------------------------------------

fn handlePaneList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"panes\":[]}");
    };

    var array = JsonArrayBuilder.init(alloc);
    defer array.deinit();
    try array.startArray();

    const tm = &window.tab_manager;

    // Optionally filter by workspace_id
    const filter_ws_id = req.getIntParam(alloc, "workspace_id");

    for (tm.workspaces.items) |ws| {
        if (filter_ws_id) |fid| {
            if (toU64(fid)) |filter_id| {
                if (ws.id != filter_id) continue;
            } else continue;
        }

        var pane_ids = try ws.pane_tree.orderedPaneIds(alloc);
        defer pane_ids.deinit(alloc);

        for (pane_ids.items) |pane_id| {
            const is_focused = if (ws.pane_tree.focused_pane) |fp| fp == pane_id else false;

            const pane_json = try std.fmt.allocPrint(alloc,
                \\{{"id":{d},"ref":"pane:{d}","workspace_id":{d},"focused":{s},"surface_count":1}}
            , .{
                pane_id,
                pane_id,
                ws.id,
                if (is_focused) "true" else "false",
            });
            defer alloc.free(pane_json);
            try array.addRaw(pane_json);
        }
    }

    try array.endArray();
    const panes_json = try array.toOwnedSlice();
    defer alloc.free(panes_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"panes":{s}}}
    , .{panes_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

// ------------------------------------------------------------------
// Window handlers
// ------------------------------------------------------------------

fn handleWindowList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"windows\":[]}");
    };

    const ws_count = window.tab_manager.workspaces.items.len;
    const result = try std.fmt.allocPrint(alloc,
        \\{{"windows":[{{"id":1,"ref":"window:1","focused":true,"workspace_count":{d}}}]}}
    , .{ws_count});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleWindowCurrent(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"window\":null}");
    };

    const ws_count = window.tab_manager.workspaces.items.len;
    const result = try std.fmt.allocPrint(alloc,
        \\{{"window":{{"id":1,"ref":"window:1","focused":true,"workspace_count":{d}}}}}
    , .{ws_count});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

// ------------------------------------------------------------------
// Notification handlers
// ------------------------------------------------------------------

fn handleNotificationCreate(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const title = req.getStringParam(alloc, "title") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'title' parameter");
    };
    defer alloc.free(title);

    const body = req.getStringParam(alloc, "body");
    defer if (body) |b| alloc.free(b);

    const id = server.notification_store.add(title, body);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"notification":{{"id":{d}}}}}
    , .{id});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleNotificationList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const notifications = try server.notification_store.list(alloc);
    defer if (notifications.len > 0) alloc.free(notifications);

    var array = JsonArrayBuilder.init(alloc);
    defer array.deinit();
    try array.startArray();

    for (notifications) |notif| {
        if (notif.id == 0) continue; // Skip tombstones

        const title_esc = try jsonEscapeString(alloc, notif.title[0..notif.title_len]);
        defer alloc.free(title_esc);

        var body_json: []const u8 = "null";
        var body_alloc = false;
        if (notif.body_len > 0) {
            const body_esc = try jsonEscapeString(alloc, notif.body[0..notif.body_len]);
            defer alloc.free(body_esc);
            body_json = try std.fmt.allocPrint(alloc, "\"{s}\"", .{body_esc});
            body_alloc = true;
        }
        defer if (body_alloc) alloc.free(body_json);

        const n_json = try std.fmt.allocPrint(alloc,
            \\{{"id":{d},"title":"{s}","body":{s},"timestamp":{d}}}
        , .{ notif.id, title_esc, body_json, notif.timestamp });
        defer alloc.free(n_json);
        try array.addRaw(n_json);
    }

    try array.endArray();
    const list_json = try array.toOwnedSlice();
    defer alloc.free(list_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"notifications":{s}}}
    , .{list_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleNotificationClear(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const id = req.getIntParam(alloc, "id");
    if (id) |notif_id| {
        if (toU64(notif_id)) |nid| {
            server.notification_store.clear(nid);
        }
    } else {
        server.notification_store.clear(null);
    }
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

// ------------------------------------------------------------------
// Command palette handlers
// ------------------------------------------------------------------

fn handleCommandPaletteList(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    var array = JsonArrayBuilder.init(alloc);
    defer array.deinit();
    try array.startArray();

    const palette_actions = CommandPalette.getActions();
    for (palette_actions) |action| {
        const name_escaped = try jsonEscapeString(alloc, action.name);
        defer alloc.free(name_escaped);
        const desc_escaped = try jsonEscapeString(alloc, action.description);
        defer alloc.free(desc_escaped);

        const json = try std.fmt.allocPrint(alloc,
            \\{{"name":"{s}","description":"{s}"}}
        , .{ name_escaped, desc_escaped });
        try array.addRaw(json);
    }

    try array.endArray();
    const result = try array.toOwnedSlice();
    defer alloc.free(result);

    const wrapper = try std.fmt.allocPrint(alloc, "{{\"actions\":{s}}}", .{result});
    defer alloc.free(wrapper);
    return protocol.successResponse(alloc, req.id, wrapper);
}

fn handleCommandPaletteExecute(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const action_name = req.getStringParam(alloc, "action") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'action' parameter");
    };
    defer alloc.free(action_name);

    // Schedule execution on GTK main thread
    const ctx = try alloc.create(PaletteExecCtx);
    // Copy the action name for async use
    const name_copy = try alloc.dupe(u8, action_name);
    ctx.* = .{ .window = window, .action_name = name_copy, .alloc = alloc };
    _ = c.g_idle_add(&doPaletteExecute, @ptrCast(ctx));

    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

const PaletteExecCtx = struct {
    window: *Window,
    action_name: []const u8,
    alloc: Allocator,
};

fn doPaletteExecute(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *PaletteExecCtx = @ptrCast(@alignCast(userdata));
    defer {
        ctx.alloc.free(ctx.action_name);
        ctx.alloc.destroy(ctx);
    }

    _ = ctx.window.command_palette.executeByName(ctx.action_name);
    return c.G_SOURCE_REMOVE;
}

// ------------------------------------------------------------------
// Claude Code integration
// ------------------------------------------------------------------

fn handleClaudeHook(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const subcommand = req.getStringParam(alloc, "subcommand") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'subcommand' parameter");
    };
    defer alloc.free(subcommand);

    if (std.mem.eql(u8, subcommand, "session-start") or std.mem.eql(u8, subcommand, "active")) {
        return handleClaudeSessionStart(alloc, server, req);
    } else if (std.mem.eql(u8, subcommand, "stop") or std.mem.eql(u8, subcommand, "idle")) {
        return handleClaudeStop(alloc, server, req);
    } else if (std.mem.eql(u8, subcommand, "notification") or std.mem.eql(u8, subcommand, "notify")) {
        return handleClaudeNotification(alloc, server, req);
    } else if (std.mem.eql(u8, subcommand, "prompt-submit")) {
        return handleClaudePromptSubmit(alloc, server, req);
    }

    return protocol.errorResponse(alloc, req.id, "invalid_param", "Unknown claude.hook subcommand");
}

/// Resolve a workspace by explicit workspace_id param, session store lookup, or current.
fn resolveClaudeWorkspace(server: *Server, alloc: Allocator, req: *const protocol.Request) ?*Workspace {
    const window = server.window orelse return null;

    // 1. Explicit workspace_id param
    if (req.getIntParam(alloc, "workspace_id")) |id| {
        return window.tab_manager.findById(toU64(id) orelse return null);
    }

    // 2. Look up via session store
    if (req.getStringParam(alloc, "session_id")) |sid| {
        defer alloc.free(sid);
        if (server.claude_session_store.lookup(sid)) |rec| {
            return window.tab_manager.findById(rec.workspace_id);
        }
    }

    // 3. Fall back to current workspace
    return window.tab_manager.selectedWorkspace();
}

fn handleClaudeSessionStart(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const ws = resolveClaudeWorkspace(server, alloc, req) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    // Store session mapping
    const session_id = req.getStringParam(alloc, "session_id");
    defer if (session_id) |s| alloc.free(s);
    const cwd = req.getStringParam(alloc, "cwd");
    defer if (cwd) |c_val| alloc.free(c_val);
    const surface_id: u64 = if (req.getIntParam(alloc, "surface_id")) |s| (toU64(s) orelse 0) else 0;

    if (session_id) |sid| {
        server.claude_session_store.upsert(sid, ws.id, surface_id, cwd);
    }

    ws.setStatusEntry("claude", "Running");
    scheduleSidebarUpdate(server, ws);

    log.info("Claude session started for workspace {d}", .{ws.id});
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

fn handleClaudeStop(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const ws = resolveClaudeWorkspace(server, alloc, req) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    // Consume session mapping
    const session_id = req.getStringParam(alloc, "session_id");
    defer if (session_id) |s| alloc.free(s);
    const surface_id: u64 = if (req.getIntParam(alloc, "surface_id")) |s| (toU64(s) orelse 0) else 0;

    const record = server.claude_session_store.consume(session_id, ws.id, if (surface_id > 0) surface_id else null);

    // Build notification body from stored record if available
    const notif_body: []const u8 = if (record) |rec|
        rec.getLastBody() orelse "Session complete"
    else
        "Session complete";

    ws.removeStatusEntry("claude");
    scheduleSidebarUpdate(server, ws);

    _ = server.notification_store.add("Claude Code", notif_body);

    log.info("Claude session stopped for workspace {d}", .{ws.id});
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

fn handleClaudeNotification(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const ws = resolveClaudeWorkspace(server, alloc, req) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    const message = req.getStringParam(alloc, "message");
    defer if (message) |m| alloc.free(m);
    const event = req.getStringParam(alloc, "event");
    defer if (event) |e| alloc.free(e);

    // Classify notification
    const classified = classifyClaudeNotification(event, message);

    // Update sidebar status
    ws.setStatusEntry("claude", classified.label);
    scheduleSidebarUpdate(server, ws);

    // Fire desktop notification
    _ = server.notification_store.add("Claude Code", classified.body);

    // Update session record with last message info
    const session_id = req.getStringParam(alloc, "session_id");
    defer if (session_id) |s| alloc.free(s);
    server.claude_session_store.updateMessage(session_id, ws.id, classified.label, classified.body);

    log.info("Claude notification ({s}) for workspace {d}", .{ classified.label, ws.id });
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

fn handleClaudePromptSubmit(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const ws = resolveClaudeWorkspace(server, alloc, req) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    ws.setStatusEntry("claude", "Running");
    scheduleSidebarUpdate(server, ws);

    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

const ClassifiedNotification = struct {
    label: []const u8,
    body: []const u8,
};

fn classifyClaudeNotification(event: ?[]const u8, message: ?[]const u8) ClassifiedNotification {
    const default_body = message orelse "Claude needs your attention";

    // Check event and message for classification keywords.
    const sources = [_]?[]const u8{ event, message };
    for (&sources) |maybe_src| {
        const src = maybe_src orelse continue;
        if (containsCI(src, "permission") or containsCI(src, "approve") or containsCI(src, "approval")) {
            return .{ .label = "Permission", .body = message orelse "Approval needed" };
        }
        if (containsCI(src, "error") or containsCI(src, "failed") or containsCI(src, "exception")) {
            return .{ .label = "Error", .body = message orelse "Claude reported an error" };
        }
        if (containsCI(src, "idle") or containsCI(src, "wait") or containsCI(src, "input")) {
            return .{ .label = "Waiting", .body = message orelse "Claude is waiting for input" };
        }
    }

    return .{ .label = "Attention", .body = default_body };
}

/// Case-insensitive substring search.
fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        var matched = true;
        for (0..needle.len) |j| {
            if (toLowerAscii(haystack[i + j]) != toLowerAscii(needle[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn toLowerAscii(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

// ------------------------------------------------------------------
// History handlers — file-only, no GTK dispatch needed
// ------------------------------------------------------------------

fn handleHistoryList(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    const limit_param = req.getIntParam(alloc, "limit");
    const ws_filter = req.getIntParam(alloc, "workspace_id");

    var index = history.loadIndex(alloc) catch {
        // No index yet — return empty array
        return protocol.successResponse(alloc, req.id, "[]");
    };
    defer history.freeIndex(alloc, &index);

    var arr = JsonArrayBuilder.init(alloc);
    defer arr.deinit();
    try arr.startArray();

    var count: usize = 0;
    const max_count: usize = if (limit_param) |l| (toUsize(l) orelse index.entries.items.len) else index.entries.items.len;

    // Iterate in reverse (newest first)
    var i: usize = index.entries.items.len;
    while (i > 0 and count < max_count) {
        i -= 1;
        const entry = index.entries.items[i];

        // Apply workspace filter if provided
        if (ws_filter) |ws_id| {
            if (toU64(ws_id)) |filter_id| {
                if (entry.workspace_id != filter_id) continue;
            } else continue;
        }

        const entry_json = try serializeHistoryEntry(alloc, &entry);
        defer alloc.free(entry_json);
        try arr.addRaw(entry_json);
        count += 1;
    }

    try arr.endArray();
    const result = try arr.toOwnedSlice();
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleHistoryShow(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    const id = req.getStringParam(alloc, "id") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "id is required");
    };
    defer alloc.free(id);

    const text = history.loadEntryText(alloc, id) catch {
        return protocol.errorResponse(alloc, req.id, "not_found", "History entry not found");
    };
    defer alloc.free(text);

    const escaped = try jsonEscapeString(alloc, text);
    defer alloc.free(escaped);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"id":"{s}","text":"{s}"}}
    , .{ id, escaped });
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleHistorySearch(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    const query = req.getStringParam(alloc, "query") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "query is required");
    };
    defer alloc.free(query);

    const results = history.searchEntries(alloc, query) catch {
        return protocol.errorResponse(alloc, req.id, "search_failed", "Failed to search history");
    };
    defer history.freeSearchResults(alloc, results);

    var arr = JsonArrayBuilder.init(alloc);
    defer arr.deinit();
    try arr.startArray();

    for (results) |entry| {
        const entry_json = try serializeHistoryEntry(alloc, &entry);
        defer alloc.free(entry_json);
        try arr.addRaw(entry_json);
    }

    try arr.endArray();
    const result = try arr.toOwnedSlice();
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleHistoryDelete(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    const id = req.getStringParam(alloc, "id") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "id is required");
    };
    defer alloc.free(id);

    history.deleteEntry(alloc, id) catch {};

    return protocol.successResponse(alloc, req.id, "{\"deleted\":true}");
}

fn serializeHistoryEntry(alloc: Allocator, entry: *const history.HistoryEntry) ![]const u8 {
    const escaped_title = try jsonEscapeString(alloc, entry.workspace_title);
    defer alloc.free(escaped_title);
    const escaped_cwd = try jsonEscapeString(alloc, entry.cwd);
    defer alloc.free(escaped_cwd);
    const escaped_reason = try jsonEscapeString(alloc, entry.reason);
    defer alloc.free(escaped_reason);

    return std.fmt.allocPrint(alloc,
        \\{{"id":"{s}","workspace_id":{d},"workspace_title":"{s}","pane_id":{d},"closed_at":{d},"lines":{d},"bytes":{d},"cwd":"{s}","reason":"{s}"}}
    , .{
        entry.id,
        entry.workspace_id,
        escaped_title,
        entry.pane_id,
        entry.closed_at,
        entry.lines,
        entry.bytes,
        escaped_cwd,
        escaped_reason,
    });
}
