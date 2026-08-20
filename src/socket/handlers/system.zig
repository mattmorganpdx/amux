//! system.* handlers: ping, identify, capabilities, tree.

const std = @import("std");
const protocol = @import("../protocol.zig");
const Server = @import("../server.zig");
const Window = @import("../../window.zig");
const Workspace = @import("../../workspace.zig");
const PaneTree = @import("../../pane_tree.zig");
const TerminalWidget = @import("../../terminal_widget.zig");
const CommandPalette = @import("../../command_palette.zig");
const ClaudeSessionStore = @import("../../claude_session_store.zig");
const history = @import("../../history.zig");
const c = @import("../../c.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.socket_handlers);

const common = @import("common.zig");

// Shared infrastructure, aliased so the handler bodies below read exactly as
// they did when every handler lived in one file.
const toU64 = common.toU64;
const toUsize = common.toUsize;
const gtk_dispatch_timeout_ns = common.gtk_dispatch_timeout_ns;
const runOnMainThread = common.runOnMainThread;
const respondFromMainThread = common.respondFromMainThread;
const respondFromMainThreadWith = common.respondFromMainThreadWith;
const ResolveError = common.ResolveError;
const ResolvedSurface = common.ResolvedSurface;
const RealizedRequirement = common.RealizedRequirement;
const resolveSurfaceOnMain = common.resolveSurfaceOnMain;
const resolveErrorResponse = common.resolveErrorResponse;
const ReadResult = common.ReadResult;
const readSurfaceTextOnMain = common.readSurfaceTextOnMain;
const JsonArrayBuilder = common.JsonArrayBuilder;
const jsonEscapeString = common.jsonEscapeString;
const parseDirection = common.parseDirection;

// ------------------------------------------------------------------
// System handlers
// ------------------------------------------------------------------

pub fn handleSystemPing(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    return protocol.successResponse(alloc, req.id, "{\"pong\":true}");
}

/// MUST run on the GTK main thread (see JsonOnMain).
/// `socket_path` is fixed at Server.init and never mutated, so passing it in is safe.
fn buildIdentifyJson(window: *Window, alloc: Allocator, socket_path: []const u8) ![]const u8 {
    var focused_json: []const u8 = "null";
    var focused_alloc = false;
    if (window.tab_manager.selectedWorkspace()) |ws| {
        if (ws.pane_tree.focused_pane) |pane_id| {
            // The title is user-controlled and may contain quotes, backslashes
            // or control characters, so it has to be escaped like every other
            // string on the wire.
            const escaped_title = try jsonEscapeString(alloc, ws.getTitle());
            defer alloc.free(escaped_title);
            focused_json = try std.fmt.allocPrint(alloc,
                \\{{"workspace_id":{d},"workspace_title":"{s}","pane_id":{d}}}
            , .{ ws.id, escaped_title, pane_id });
            focused_alloc = true;
        }
    }
    defer if (focused_alloc) alloc.free(focused_json);

    return std.fmt.allocPrint(alloc,
        \\{{"socket_path":"{s}","focused":{s},"caller":null}}
    , .{ socket_path, focused_json });
}

pub fn handleSystemIdentify(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        const result = try std.fmt.allocPrint(alloc,
            \\{{"socket_path":"{s}","focused":null,"caller":null}}
        , .{server.socket_path});
        defer alloc.free(result);
        return protocol.successResponse(alloc, req.id, result);
    };
    return respondFromMainThreadWith(alloc, req, window, []const u8, buildIdentifyJson, server.socket_path);
}

pub fn handleSystemCapabilities(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
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

pub fn handleSystemTree(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        const result =
            \\{"focused":null,"caller":null,"windows":[]}
        ;
        return protocol.successResponse(alloc, req.id, result);
    };
    return respondFromMainThread(alloc, req, window, buildSystemTreeJson);
}

/// MUST run on the GTK main thread (see JsonOnMain).
fn buildSystemTreeJson(window: *Window, alloc: Allocator, _: void) ![]const u8 {
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

    return std.fmt.allocPrint(alloc,
        \\{{"focused":null,"caller":null,"windows":[{{"id":1,"workspace_count":{d},"workspaces":{s}}}]}}
    , .{ tm.workspaces.items.len, workspaces_json });
}
