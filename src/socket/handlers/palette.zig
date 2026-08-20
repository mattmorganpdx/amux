//! command_palette.* handlers: list, execute.

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
// Command palette handlers
// ------------------------------------------------------------------

pub fn handleCommandPaletteList(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
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

pub fn handleCommandPaletteExecute(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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
