//! notification.* handlers: create, list, clear.

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
// Notification handlers
// ------------------------------------------------------------------

pub fn handleNotificationCreate(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleNotificationList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleNotificationClear(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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
