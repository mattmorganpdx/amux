//! window.* handlers: list, current.

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
// Window handlers
// ------------------------------------------------------------------

/// MUST run on the GTK main thread (see JsonOnMain).
fn buildWindowListJson(window: *Window, alloc: Allocator, _: void) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\{{"windows":[{{"id":1,"ref":"window:1","focused":true,"workspace_count":{d}}}]}}
    , .{window.tab_manager.workspaces.items.len});
}

pub fn handleWindowList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"windows\":[]}");
    };
    return respondFromMainThread(alloc, req, window, buildWindowListJson);
}

/// MUST run on the GTK main thread (see JsonOnMain).
fn buildWindowCurrentJson(window: *Window, alloc: Allocator, _: void) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\{{"window":{{"id":1,"ref":"window:1","focused":true,"workspace_count":{d}}}}}
    , .{window.tab_manager.workspaces.items.len});
}

pub fn handleWindowCurrent(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"window\":null}");
    };
    return respondFromMainThread(alloc, req, window, buildWindowCurrentJson);
}
