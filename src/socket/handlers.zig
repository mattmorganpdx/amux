//! Socket request router.
//!
//! Maps JSON-RPC method names onto the per-domain handler modules in
//! `handlers/`. Handler implementations live there; this file only routes.

const std = @import("std");
const protocol = @import("protocol.zig");
const Server = @import("server.zig");

const Allocator = std.mem.Allocator;

const system = @import("handlers/system.zig");
const workspace = @import("handlers/workspace.zig");
const surface = @import("handlers/surface.zig");
const pane = @import("handlers/pane.zig");
const window_api = @import("handlers/window_api.zig");
const notification = @import("handlers/notification.zig");
const palette = @import("handlers/palette.zig");
const claude = @import("handlers/claude.zig");
const history_api = @import("handlers/history.zig");

pub fn dispatch(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    // System methods
    if (std.mem.eql(u8, req.method, "system.ping")) {
        return system.handleSystemPing(alloc, req);
    }
    if (std.mem.eql(u8, req.method, "system.identify")) {
        return system.handleSystemIdentify(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "system.capabilities")) {
        return system.handleSystemCapabilities(alloc, req);
    }
    if (std.mem.eql(u8, req.method, "system.tree")) {
        return system.handleSystemTree(alloc, server, req);
    }

    // Workspace methods
    if (std.mem.eql(u8, req.method, "workspace.list")) {
        return workspace.handleWorkspaceList(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.create")) {
        return workspace.handleWorkspaceCreate(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.current")) {
        return workspace.handleWorkspaceCurrent(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.select")) {
        return workspace.handleWorkspaceSelect(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.close")) {
        return workspace.handleWorkspaceClose(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.rename")) {
        return workspace.handleWorkspaceRename(alloc, server, req);
    }

    // Surface methods
    if (std.mem.eql(u8, req.method, "surface.list")) {
        return surface.handleSurfaceList(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.send_text")) {
        return surface.handleSurfaceSendText(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.current")) {
        return surface.handleSurfaceCurrent(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.read_text")) {
        return surface.handleSurfaceReadText(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.send_key")) {
        return surface.handleSurfaceSendKey(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.split")) {
        return surface.handleSurfaceSplit(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.close")) {
        return surface.handleSurfaceClose(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.run")) {
        return surface.handleSurfaceRun(alloc, server, req);
    }

    // Workspace metadata methods
    if (std.mem.eql(u8, req.method, "workspace.report_git")) {
        return workspace.handleWorkspaceReportGit(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.set_status")) {
        return workspace.handleWorkspaceSetStatus(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.clear_status")) {
        return workspace.handleWorkspaceClearStatus(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.add_log")) {
        return workspace.handleWorkspaceAddLog(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.clear_log")) {
        return workspace.handleWorkspaceClearLog(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.set_progress")) {
        return workspace.handleWorkspaceSetProgress(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.set_pinned")) {
        return workspace.handleWorkspaceSetPinned(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.set_color")) {
        return workspace.handleWorkspaceSetColor(alloc, server, req);
    }

    // Workspace navigation
    if (std.mem.eql(u8, req.method, "workspace.next")) {
        return workspace.handleWorkspaceNext(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.previous")) {
        return workspace.handleWorkspacePrevious(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.last")) {
        return workspace.handleWorkspaceLast(alloc, server, req);
    }

    // Pane methods
    if (std.mem.eql(u8, req.method, "pane.list")) {
        return pane.handlePaneList(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "pane.resize")) {
        return pane.handlePaneResize(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "pane.swap")) {
        return pane.handlePaneSwap(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "pane.break")) {
        return pane.handlePaneBreak(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "pane.join")) {
        return pane.handlePaneJoin(alloc, server, req);
    }

    // Window methods
    if (std.mem.eql(u8, req.method, "window.list")) {
        return window_api.handleWindowList(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "window.current")) {
        return window_api.handleWindowCurrent(alloc, server, req);
    }

    // Notification methods
    if (std.mem.eql(u8, req.method, "notification.create")) {
        return notification.handleNotificationCreate(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "notification.list")) {
        return notification.handleNotificationList(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "notification.clear")) {
        return notification.handleNotificationClear(alloc, server, req);
    }

    // Surface search
    if (std.mem.eql(u8, req.method, "surface.search")) {
        return surface.handleSurfaceSearch(alloc, server, req);
    }

    // Command palette methods
    if (std.mem.eql(u8, req.method, "command_palette.list")) {
        return palette.handleCommandPaletteList(alloc, req);
    }
    if (std.mem.eql(u8, req.method, "command_palette.execute")) {
        return palette.handleCommandPaletteExecute(alloc, server, req);
    }

    // History methods
    if (std.mem.eql(u8, req.method, "history.list")) {
        return history_api.handleHistoryList(alloc, req);
    }
    if (std.mem.eql(u8, req.method, "history.show")) {
        return history_api.handleHistoryShow(alloc, req);
    }
    if (std.mem.eql(u8, req.method, "history.search")) {
        return history_api.handleHistorySearch(alloc, req);
    }
    if (std.mem.eql(u8, req.method, "history.delete")) {
        return history_api.handleHistoryDelete(alloc, req);
    }

    // Claude Code integration
    if (std.mem.eql(u8, req.method, "claude.hook")) {
        return claude.handleClaudeHook(alloc, server, req);
    }

    return protocol.errorResponse(alloc, req.id, "method_not_found", req.method);
}
