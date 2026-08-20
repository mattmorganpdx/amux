//! pane.* handlers: list, resize, swap, break, join.

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

pub fn handlePaneResize(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handlePaneSwap(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handlePaneBreak(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handlePaneJoin(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handlePaneList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"panes\":[]}");
    };
    // Optionally filter by workspace_id
    const filter_ws_id = req.getIntParam(alloc, "workspace_id");
    return respondFromMainThreadWith(alloc, req, window, ?i64, buildPaneListJson, filter_ws_id);
}

/// MUST run on the GTK main thread (see JsonOnMain).
fn buildPaneListJson(window: *Window, alloc: Allocator, filter_ws_id: ?i64) ![]const u8 {
    var array = JsonArrayBuilder.init(alloc);
    defer array.deinit();
    try array.startArray();

    const tm = &window.tab_manager;

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

    return std.fmt.allocPrint(alloc,
        \\{{"panes":{s}}}
    , .{panes_json});
}
