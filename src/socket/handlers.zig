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

// ------------------------------------------------------------------
// Main-thread dispatch
//
// All window state -- `pane_widgets`, `tab_manager`, and the lifetime of
// TerminalWidgets and their Ghostty surfaces -- is owned by the GTK main
// thread. Socket handlers run on their own thread-per-client, so they must
// never resolve a pane to a surface themselves: the pane can be closed (and
// the widget freed) between the lookup and the call into libghostty, and
// `pane_widgets` is an unsynchronized HashMap that the main thread may be
// rehashing concurrently.
//
// Handlers therefore pass a *pane id* to the main thread and do the lookup
// inside the callback, where the widget cannot be destroyed underneath them.
// ------------------------------------------------------------------

/// Dispatch `ctx` to the GTK main thread and block until its `run()` completes.
///
/// `Ctx` must expose `done: std.Thread.ResetEvent` and `fn run(*Ctx) void`.
///
/// On timeout the caller must leak `ctx` (and anything it borrows): the idle
/// callback may still fire later and write through the pointer.
fn runOnMainThread(comptime Ctx: type, ctx: *Ctx) error{Timeout}!void {
    const Trampoline = struct {
        fn cb(userdata: c.gpointer) callconv(.c) c.gboolean {
            const inner: *Ctx = @ptrCast(@alignCast(userdata));
            defer inner.done.set();
            inner.run();
            return c.G_SOURCE_REMOVE;
        }
    };
    _ = c.g_idle_add(&Trampoline.cb, @ptrCast(ctx));
    ctx.done.timedWait(gtk_dispatch_timeout_ns) catch {
        log.warn("GTK dispatch timed out for socket request", .{});
        return error.Timeout;
    };
}

/// Builds a JSON response body on the GTK main thread.
///
/// `tab_manager.workspaces` is a `std.ArrayListUnmanaged(*Workspace)` that the
/// main thread reallocs on create (window.zig createWorkspace) and whose
/// elements it frees on close (TabManager.closeWorkspace does `ws.deinit()`
/// then `destroy(ws)`). Walking that list from a socket handler thread races
/// both: an append can move the buffer out from under an in-flight iteration,
/// and a close can leave the handler holding a dangling `*Workspace`. So the
/// whole traversal-and-format runs on the main thread and only the finished
/// string is handed back.
///
/// The body is allocated with c_allocator, not the request allocator, so it
/// stays valid even when the context has to be leaked after a timeout.
fn JsonOnMain(comptime Arg: type, comptime build: fn (*Window, Allocator, Arg) anyerror![]const u8) type {
    return struct {
        const Self = @This();

        window: *Window,
        arg: Arg,
        result: ?[]const u8 = null,
        done: std.Thread.ResetEvent = .{},

        fn run(self: *Self) void {
            self.result = build(self.window, std.heap.c_allocator, self.arg) catch |err| blk: {
                log.warn("main-thread JSON build failed: {}", .{err});
                break :blk null;
            };
        }
    };
}

/// Run `build` on the GTK main thread and wrap its output in a success response.
fn respondFromMainThreadWith(
    alloc: Allocator,
    req: *const protocol.Request,
    window: *Window,
    comptime Arg: type,
    comptime build: fn (*Window, Allocator, Arg) anyerror![]const u8,
    arg: Arg,
) ![]const u8 {
    const Ctx = JsonOnMain(Arg, build);
    const ctx = std.heap.c_allocator.create(Ctx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{ .window = window, .arg = arg };

    runOnMainThread(Ctx, ctx) catch {
        // Deliberately leak ctx: the idle callback may still fire later.
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };
    defer std.heap.c_allocator.destroy(ctx);

    const body = ctx.result orelse {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to build response");
    };
    defer std.heap.c_allocator.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

/// `respondFromMainThreadWith` for builders that need no extra argument.
fn respondFromMainThread(
    alloc: Allocator,
    req: *const protocol.Request,
    window: *Window,
    comptime build: fn (*Window, Allocator, void) anyerror![]const u8,
) ![]const u8 {
    return respondFromMainThreadWith(alloc, req, window, void, build, {});
}

/// Why a pane could not be resolved to a live surface.
const ResolveError = enum { none, no_surface, dead_surface, dead_realized };

/// A pane resolved to a live Ghostty surface.
const ResolvedSurface = struct {
    surface: c.ghostty_surface_t,
    pane_id: PaneTree.NodeId,
};

/// Whether an operation needs the widget to be GTK-realized.
///
/// Writing to a surface does; reading from it does not. `onUnrealize` clears
/// `realized` but deliberately leaves `surface` non-null, so a widget that GTK
/// has transiently unrealized (e.g. during the reparenting done by pane
/// break/join/swap) can still be read from.
const RealizedRequirement = enum { require_realized, allow_unrealized };

/// Resolve `explicit` (or the focused pane when null) to a live surface.
///
/// MUST be called on the GTK main thread. The returned surface is only valid
/// for the duration of that callback -- never store it across a dispatch.
fn resolveSurfaceOnMain(
    window: *Window,
    explicit: ?PaneTree.NodeId,
    requirement: RealizedRequirement,
    err: *ResolveError,
) ?ResolvedSurface {
    const pane_id = explicit orelse blk: {
        const ws = window.tab_manager.selectedWorkspace() orelse {
            err.* = .no_surface;
            return null;
        };
        break :blk ws.pane_tree.focused_pane orelse {
            err.* = .no_surface;
            return null;
        };
    };
    const tw = window.pane_widgets.get(pane_id) orelse {
        err.* = .no_surface;
        return null;
    };
    if (tw.surface == null) {
        err.* = .dead_surface;
        return null;
    }
    if (requirement == .require_realized and !tw.realized) {
        err.* = .dead_realized;
        return null;
    }
    err.* = .none;
    return .{ .surface = tw.surface, .pane_id = pane_id };
}

/// Map a resolve failure onto the wire error response.
fn resolveErrorResponse(alloc: Allocator, req_id: i64, err: ResolveError) ![]const u8 {
    return switch (err) {
        .dead_surface, .dead_realized => protocol.errorResponse(alloc, req_id, "dead_surface", "Surface is not active (unrealized or uninitialized)"),
        else => protocol.errorResponse(alloc, req_id, "no_surface", "No target surface found"),
    };
}

/// Outcome of reading a surface's text.
const ReadResult = struct {
    ok: bool = false,
    /// Heap-allocated with c_allocator; null when the surface had no text.
    text: ?[]u8 = null,
};

/// Read a surface's text. MUST be called on the GTK main thread.
fn readSurfaceTextOnMain(surface: c.ghostty_surface_t, include_scrollback: bool) ReadResult {
    if (surface == null) return .{};

    const point_tag: c.ghostty_point_tag_e = if (include_scrollback)
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
    if (!c.ghostty_surface_read_text(surface, selection, &text)) return .{};
    defer c.ghostty_surface_free_text(surface, &text);

    if (text.text == null or text.text_len == 0) return .{ .ok = true };

    const copy = std.heap.c_allocator.alloc(u8, text.text_len) catch return .{};
    @memcpy(copy, text.text[0..text.text_len]);
    return .{ .ok = true, .text = copy };
}

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

fn handleSystemIdentify(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        const result = try std.fmt.allocPrint(alloc,
            \\{{"socket_path":"{s}","focused":null,"caller":null}}
        , .{server.socket_path});
        defer alloc.free(result);
        return protocol.successResponse(alloc, req.id, result);
    };
    return respondFromMainThreadWith(alloc, req, window, []const u8, buildIdentifyJson, server.socket_path);
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

/// MUST run on the GTK main thread (see JsonOnMain).
fn buildWorkspaceListJson(window: *Window, alloc: Allocator, _: void) ![]const u8 {
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

    return std.fmt.allocPrint(alloc,
        \\{{"workspaces":{s}}}
    , .{ws_list});
}

fn handleWorkspaceList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"workspaces\":[]}");
    };
    return respondFromMainThread(alloc, req, window, buildWorkspaceListJson);
}

/// Creates a workspace and switches to it, entirely on the GTK main thread.
///
/// `TabManager.createWorkspace` appends to `workspaces`, which reallocs the
/// list. Doing that from a socket handler thread would race every main-thread
/// reader (and the sidebar), so the whole create-switch-serialize sequence
/// happens in one main-thread hop.
const WorkspaceCreateCtx = struct {
    window: *Window,
    /// c_allocator-owned copy of the requested title, so it stays valid even
    /// if this context has to be leaked after a dispatch timeout.
    title: ?[]u8,
    body: ?[]const u8 = null,
    failed: bool = false,
    done: std.Thread.ResetEvent = .{},

    fn run(self: *WorkspaceCreateCtx) void {
        const window = self.window;
        const tm = &window.tab_manager;

        const ws = tm.createWorkspace() catch |err| {
            log.warn("Failed to create workspace from socket: {}", .{err});
            self.failed = true;
            return;
        };
        if (self.title) |t| ws.setTitle(t);

        const idx = tm.workspaces.items.len - 1;

        // Build the widgets and switch the UI to the new workspace.
        window.sidebar.rebuild();
        window.switchWorkspace(idx) catch |err| {
            // The data model exists either way; report it rather than failing.
            log.warn("Failed to switch to new workspace: {}", .{err});
        };

        // Report the real selection state. HEAD hardcoded `false` because the
        // switch was dispatched asynchronously and had not happened yet at
        // serialization time; it now completes above, so `false` would lie.
        const is_selected = if (tm.selected_index) |sel| sel == idx else false;

        const ca = std.heap.c_allocator;
        const ws_json = workspaceToJson(ca, ws, is_selected, idx) catch {
            self.failed = true;
            return;
        };
        defer ca.free(ws_json);
        self.body = std.fmt.allocPrint(ca, "{{\"workspace\":{s}}}", .{ws_json}) catch {
            self.failed = true;
            return;
        };
    }
};

fn handleWorkspaceCreate(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    // Get optional title parameter
    const title = req.getStringParam(alloc, "title");
    defer if (title) |t| alloc.free(t);

    const ctx = std.heap.c_allocator.create(WorkspaceCreateCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    const title_owned: ?[]u8 = if (title) |t|
        std.heap.c_allocator.dupe(u8, t) catch {
            std.heap.c_allocator.destroy(ctx);
            return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
        }
    else
        null;
    ctx.* = .{ .window = window, .title = title_owned };

    runOnMainThread(WorkspaceCreateCtx, ctx) catch {
        // Deliberately leak ctx and its title copy: the idle callback may still
        // fire later and dereference both.
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };
    defer {
        if (ctx.title) |t| std.heap.c_allocator.free(t);
        if (ctx.body) |b| std.heap.c_allocator.free(b);
        std.heap.c_allocator.destroy(ctx);
    }

    if (ctx.failed) {
        return protocol.errorResponse(alloc, req.id, "create_failed", "Failed to create workspace");
    }
    const body = ctx.body orelse {
        return protocol.errorResponse(alloc, req.id, "create_failed", "Failed to create workspace");
    };
    return protocol.successResponse(alloc, req.id, body);
}

/// MUST run on the GTK main thread (see JsonOnMain).
fn buildWorkspaceCurrentJson(window: *Window, alloc: Allocator, _: void) ![]const u8 {
    const tm = &window.tab_manager;
    const ws = tm.selectedWorkspace() orelse {
        return alloc.dupe(u8, "{\"workspace\":null}");
    };

    const idx = tm.selected_index orelse 0;
    const ws_json = try workspaceToJson(alloc, ws, true, idx);
    defer alloc.free(ws_json);

    return std.fmt.allocPrint(alloc,
        \\{{"workspace":{s}}}
    , .{ws_json});
}

fn handleWorkspaceCurrent(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"workspace\":null}");
    };
    return respondFromMainThread(alloc, req, window, buildWorkspaceCurrentJson);
}

fn handleWorkspaceSelect(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    // The id/index -> workspace resolution happens on the main thread.
    const selector: WorkspaceSelector = if (req.getIntParam(alloc, "id")) |id| blk: {
        break :blk .{ .id = toU64(id) orelse {
            return protocol.errorResponse(alloc, req.id, "invalid_param", "Workspace ID must be non-negative");
        } };
    } else if (req.getIntParam(alloc, "index")) |index| blk: {
        break :blk .{ .index = toUsize(index) orelse {
            return protocol.errorResponse(alloc, req.id, "invalid_param", "Index must be non-negative");
        } };
    } else {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'id' or 'index' parameter");
    };

    return respondWorkspaceSwitch(alloc, req, window, selector);
}

/// How to pick the workspace to switch to.
///
/// Resolved inside WorkspaceSwitchCtx.run on the GTK main thread. The
/// workspace list is owned there, so a socket handler must never walk it to
/// turn an id into an index: an append can realloc the list and a close frees
/// the `*Workspace` outright.
const WorkspaceSelector = union(enum) {
    index: usize,
    id: u64,
    /// The most recently appended workspace (used right after create).
    newest,
    next,
    previous,
    /// The most recent entry in the workspace history stack.
    last_visited,
};

/// Why a switch could not happen, mapped to a wire error by the caller.
const SwitchFailure = enum {
    none,
    not_found,
    no_selection,
    at_end,
    at_start,
    no_history,
    switch_failed,
};

const WorkspaceSwitchCtx = struct {
    window: *Window,
    selector: WorkspaceSelector,
    /// Response body, c_allocator-owned so it survives a leaked context.
    body: ?[]const u8 = null,
    failure: SwitchFailure = .none,
    done: std.Thread.ResetEvent = .{},

    fn run(self: *WorkspaceSwitchCtx) void {
        const window = self.window;
        const tm = &window.tab_manager;

        // Rebuild the sidebar in case a workspace was just added.
        window.sidebar.rebuild();

        const idx: usize = switch (self.selector) {
            .index => |i| i,
            .id => |wid| blk: {
                for (tm.workspaces.items, 0..) |ws, i| {
                    if (ws.id == wid) break :blk i;
                }
                self.failure = .not_found;
                return;
            },
            .newest => blk: {
                if (tm.workspaces.items.len == 0) {
                    self.failure = .not_found;
                    return;
                }
                break :blk tm.workspaces.items.len - 1;
            },
            .next => blk: {
                const cur = tm.selected_index orelse {
                    self.failure = .no_selection;
                    return;
                };
                if (cur + 1 >= tm.workspaces.items.len) {
                    self.failure = .at_end;
                    return;
                }
                break :blk cur + 1;
            },
            .previous => blk: {
                const cur = tm.selected_index orelse {
                    self.failure = .no_selection;
                    return;
                };
                if (cur == 0) {
                    self.failure = .at_start;
                    return;
                }
                break :blk cur - 1;
            },
            .last_visited => blk: {
                if (tm.history.items.len == 0) {
                    self.failure = .no_history;
                    return;
                }
                const last_id = tm.history.items[tm.history.items.len - 1];
                for (tm.workspaces.items, 0..) |ws, i| {
                    if (ws.id == last_id) break :blk i;
                }
                self.failure = .not_found;
                return;
            },
        };

        if (idx >= tm.workspaces.items.len) {
            self.failure = .not_found;
            return;
        }

        window.switchWorkspace(idx) catch |err| {
            log.warn("Failed to switch workspace from socket: {}", .{err});
            self.failure = .switch_failed;
            return;
        };

        // Build the response here too: workspaceToJson reads the workspace and
        // its pane tree, which are main-thread state.
        const ca = std.heap.c_allocator;
        const ws_json = workspaceToJson(ca, tm.workspaces.items[idx], true, idx) catch {
            self.failure = .switch_failed;
            return;
        };
        defer ca.free(ws_json);
        self.body = std.fmt.allocPrint(ca, "{{\"workspace\":{s}}}", .{ws_json}) catch {
            self.failure = .switch_failed;
            return;
        };
    }
};

/// Dispatch a workspace switch to the main thread and build the response.
fn respondWorkspaceSwitch(
    alloc: Allocator,
    req: *const protocol.Request,
    window: *Window,
    selector: WorkspaceSelector,
) ![]const u8 {
    const ctx = std.heap.c_allocator.create(WorkspaceSwitchCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{ .window = window, .selector = selector };

    runOnMainThread(WorkspaceSwitchCtx, ctx) catch {
        // Deliberately leak ctx: the idle callback may still fire later.
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };
    defer {
        if (ctx.body) |b| std.heap.c_allocator.free(b);
        std.heap.c_allocator.destroy(ctx);
    }

    switch (ctx.failure) {
        .none => {},
        .not_found => return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found"),
        .no_selection => return protocol.errorResponse(alloc, req.id, "no_workspace", "No workspace selected"),
        .at_end => return protocol.errorResponse(alloc, req.id, "at_end", "Already at last workspace"),
        .at_start => return protocol.errorResponse(alloc, req.id, "at_start", "Already at first workspace"),
        .no_history => return protocol.errorResponse(alloc, req.id, "no_history", "No workspace history"),
        .switch_failed => return protocol.errorResponse(alloc, req.id, "switch_failed", "Failed to switch workspace"),
    }

    const body = ctx.body orelse {
        return protocol.errorResponse(alloc, req.id, "switch_failed", "Failed to switch workspace");
    };
    return protocol.successResponse(alloc, req.id, body);
}

fn handleWorkspaceClose(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    // Resolution happens on the main thread; validating here would race a
    // concurrent create/close that reallocs or shrinks the workspace list.
    const selector: WorkspaceSelector = if (req.getIntParam(alloc, "id")) |id| blk: {
        break :blk .{ .id = toU64(id) orelse {
            return protocol.errorResponse(alloc, req.id, "invalid_param", "Workspace ID must be non-negative");
        } };
    } else if (req.getIntParam(alloc, "index")) |index| blk: {
        break :blk .{ .index = toUsize(index) orelse {
            return protocol.errorResponse(alloc, req.id, "invalid_param", "Index must be non-negative");
        } };
    } else {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'id' or 'index' parameter");
    };

    const ctx = std.heap.c_allocator.create(WorkspaceCloseCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{ .window = window, .selector = selector };

    runOnMainThread(WorkspaceCloseCtx, ctx) catch {
        // Deliberately leak ctx: the idle callback may still fire later.
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };
    defer std.heap.c_allocator.destroy(ctx);

    if (!ctx.closed) {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    }
    return protocol.successResponse(alloc, req.id, "{\"closed\":true}");
}

const WorkspaceCloseCtx = struct {
    window: *Window,
    selector: WorkspaceSelector,
    closed: bool = false,
    done: std.Thread.ResetEvent = .{},

    fn run(self: *WorkspaceCloseCtx) void {
        const tm = &self.window.tab_manager;
        switch (self.selector) {
            .id => |wid| {
                var exists = false;
                for (tm.workspaces.items) |ws| {
                    if (ws.id == wid) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) return;
                self.closed = self.window.closeWorkspaceById(wid);
            },
            .index => |i| {
                if (i >= tm.workspaces.items.len) return;
                self.closed = self.window.closeWorkspaceByIndex(i);
            },
            else => return,
        }
        // Rebuild sidebar to reflect the change
        self.window.sidebar.rebuild();
    }
};


fn handleWorkspaceRename(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const new_title = req.getStringParam(alloc, "title") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'title' parameter");
    };
    defer alloc.free(new_title);

    const arg = WsMutArg{ .text_a = ownArg(new_title) orelse {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    } };
    return respondWorkspaceMutation(alloc, req, server, arg, applyRename, .row, "{\"renamed\":true}");
}

// ------------------------------------------------------------------
// Workspace metadata handlers
// ------------------------------------------------------------------

/// Payload for a workspace metadata mutation.
///
/// Strings are c_allocator-owned by the context, not the request allocator:
/// the handler's copies are freed as soon as it returns, but a context leaked
/// after a dispatch timeout may still be read by a late idle callback.
const WsMutArg = struct {
    text_a: ?[]u8 = null,
    text_b: ?[]u8 = null,
    number: f64 = 0,
    flag: bool = false,
    has_flag: bool = false,

    fn free(self: WsMutArg) void {
        const ca = std.heap.c_allocator;
        if (self.text_a) |t| ca.free(t);
        if (self.text_b) |t| ca.free(t);
    }
};

/// Copy a request-allocator string into a c_allocator buffer for a WsMutArg.
fn ownArg(text: []const u8) ?[]u8 {
    return std.heap.c_allocator.dupe(u8, text) catch null;
}

/// How the sidebar should be refreshed after a mutation.
const SidebarRefresh = enum { row, rebuild };

/// Applies a metadata mutation to a workspace on the GTK main thread.
///
/// Both halves must happen there. Resolving the target walks
/// `tab_manager.workspaces`, which the main thread reallocs on create and
/// frees elements from on close; and the mutated fields (title, status, log,
/// progress, git info, pin, color) are exactly what the sidebar reads.
const WorkspaceMutationCtx = struct {
    window: *Window,
    /// null selects the currently selected workspace.
    target_id: ?u64,
    arg: WsMutArg,
    apply: *const fn (*Workspace, WsMutArg) void,
    refresh: SidebarRefresh,
    found: bool = false,
    /// Id of the workspace the mutation actually landed on.
    resolved_id: u64 = 0,
    done: std.Thread.ResetEvent = .{},

    fn run(self: *WorkspaceMutationCtx) void {
        const tm = &self.window.tab_manager;
        var index: usize = 0;
        const ws: *Workspace = blk: {
            if (self.target_id) |wid| {
                for (tm.workspaces.items, 0..) |w, i| {
                    if (w.id == wid) {
                        index = i;
                        break :blk w;
                    }
                }
                return; // leaves found = false
            }
            const sel = tm.selected_index orelse return;
            if (sel >= tm.workspaces.items.len) return;
            index = sel;
            break :blk tm.workspaces.items[sel];
        };

        self.apply(ws, self.arg);
        self.found = true;
        self.resolved_id = ws.id;

        switch (self.refresh) {
            .row => self.window.sidebar.updateRow(index),
            .rebuild => self.window.sidebar.rebuild(),
        }
    }
};

/// Outcome of a workspace mutation, keeping "no such workspace" distinct from
/// "the GTK thread never answered" so the two do not report the same error.
const MutationResult = union(enum) {
    ok: u64,
    not_found,
    unavailable,
};

/// Run a workspace mutation on the GTK main thread.
///
/// Takes ownership of `arg` in all cases.
fn mutateWorkspaceOnMain(
    window: *Window,
    target_id: ?u64,
    arg: WsMutArg,
    apply: *const fn (*Workspace, WsMutArg) void,
    refresh: SidebarRefresh,
) MutationResult {
    const ctx = std.heap.c_allocator.create(WorkspaceMutationCtx) catch {
        arg.free();
        return .unavailable;
    };
    ctx.* = .{
        .window = window,
        .target_id = target_id,
        .arg = arg,
        .apply = apply,
        .refresh = refresh,
    };

    runOnMainThread(WorkspaceMutationCtx, ctx) catch {
        // Deliberately leak ctx and its owned strings: the idle callback may
        // still fire later and dereference both.
        return .unavailable;
    };
    defer {
        ctx.arg.free();
        std.heap.c_allocator.destroy(ctx);
    }

    if (!ctx.found) return .not_found;
    return .{ .ok = ctx.resolved_id };
}

fn respondWorkspaceMutation(
    alloc: Allocator,
    req: *const protocol.Request,
    server: *Server,
    arg: WsMutArg,
    apply: *const fn (*Workspace, WsMutArg) void,
    refresh: SidebarRefresh,
    success_body: []const u8,
) ![]const u8 {
    const window = server.window orelse {
        arg.free();
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    var target_id: ?u64 = null;
    if (req.getIntParam(alloc, "id")) |id| {
        target_id = toU64(id) orelse {
            arg.free();
            return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
        };
    }

    switch (mutateWorkspaceOnMain(window, target_id, arg, apply, refresh)) {
        .ok => {},
        .not_found => return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found"),
        .unavailable => return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out"),
    }
    return protocol.successResponse(alloc, req.id, success_body);
}

// Mutations. Each runs on the GTK main thread via WorkspaceMutationCtx.
fn applyReportGit(ws: *Workspace, arg: WsMutArg) void {
    if (arg.text_a) |branch| ws.setGitBranch(branch);
    if (arg.has_flag) ws.setGitDirty(arg.flag);
}

fn applySetStatus(ws: *Workspace, arg: WsMutArg) void {
    ws.setStatusEntry(arg.text_a orelse return, arg.text_b orelse return);
}

fn applyClearStatus(ws: *Workspace, arg: WsMutArg) void {
    if (arg.text_a) |key| {
        ws.removeStatusEntry(key);
    } else {
        ws.clearStatus();
    }
}

fn applyAddLog(ws: *Workspace, arg: WsMutArg) void {
    ws.addLogEntry(arg.text_a orelse return);
}

fn applyClearLog(ws: *Workspace, _: WsMutArg) void {
    ws.clearLog();
}

fn applySetProgress(ws: *Workspace, arg: WsMutArg) void {
    ws.setProgress(@floatCast(arg.number), arg.text_a);
}

fn applySetPinned(ws: *Workspace, arg: WsMutArg) void {
    ws.pinned = arg.flag;
}

fn applySetColor(ws: *Workspace, arg: WsMutArg) void {
    const name = arg.text_a orelse {
        ws.clearColor();
        return;
    };
    if (name.len == 0) {
        ws.clearColor();
    } else {
        ws.setColor(name);
    }
}

fn applyRename(ws: *Workspace, arg: WsMutArg) void {
    ws.setTitle(arg.text_a orelse return);
}


fn handleWorkspaceReportGit(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const branch = req.getStringParam(alloc, "branch") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'branch' parameter");
    };
    defer alloc.free(branch);

    var arg = WsMutArg{ .text_a = ownArg(branch) orelse {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    } };
    if (req.getBoolParam(alloc, "dirty")) |dirty| {
        arg.flag = dirty;
        arg.has_flag = true;
    }
    return respondWorkspaceMutation(alloc, req, server, arg, applyReportGit, .row, "{\"ok\":true}");
}

fn handleWorkspaceSetStatus(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const key = req.getStringParam(alloc, "key") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'key' parameter");
    };
    defer alloc.free(key);

    const value = req.getStringParam(alloc, "value") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'value' parameter");
    };
    defer alloc.free(value);

    const arg = WsMutArg{ .text_a = ownArg(key), .text_b = ownArg(value) };
    if (arg.text_a == null or arg.text_b == null) {
        arg.free();
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    }
    return respondWorkspaceMutation(alloc, req, server, arg, applySetStatus, .row, "{\"ok\":true}");
}

fn handleWorkspaceClearStatus(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    // Optional key param: clear one entry or all
    var arg = WsMutArg{};
    if (req.getStringParam(alloc, "key")) |key| {
        defer alloc.free(key);
        arg.text_a = ownArg(key) orelse {
            return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
        };
    }
    return respondWorkspaceMutation(alloc, req, server, arg, applyClearStatus, .row, "{\"ok\":true}");
}

fn handleWorkspaceAddLog(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const text = req.getStringParam(alloc, "text") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'text' parameter");
    };
    defer alloc.free(text);

    const arg = WsMutArg{ .text_a = ownArg(text) orelse {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    } };
    return respondWorkspaceMutation(alloc, req, server, arg, applyAddLog, .row, "{\"ok\":true}");
}

fn handleWorkspaceClearLog(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    return respondWorkspaceMutation(alloc, req, server, .{}, applyClearLog, .row, "{\"ok\":true}");
}

fn handleWorkspaceSetProgress(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const fraction = req.getFloatParam(alloc, "fraction") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'fraction' parameter");
    };

    var arg = WsMutArg{ .number = fraction };
    if (req.getStringParam(alloc, "label")) |label| {
        defer alloc.free(label);
        arg.text_a = ownArg(label) orelse {
            return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
        };
    }
    return respondWorkspaceMutation(alloc, req, server, arg, applySetProgress, .row, "{\"ok\":true}");
}

fn handleWorkspaceSetPinned(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const pinned = req.getBoolParam(alloc, "pinned") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'pinned' parameter");
    };
    // Pinning changes sort order, so rebuild the whole sidebar.
    return respondWorkspaceMutation(alloc, req, server, .{ .flag = pinned }, applySetPinned, .rebuild, "{\"ok\":true}");
}

fn handleWorkspaceSetColor(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    // Validation is a pure function, so it can stay off the main thread.
    var arg = WsMutArg{};
    if (req.getStringParam(alloc, "color")) |name| {
        defer alloc.free(name);
        if (name.len != 0 and !Workspace.isValidColor(name)) {
            return protocol.errorResponse(alloc, req.id, "invalid_color", "Color must be one of: red, blue, green, yellow, purple, orange, pink, cyan");
        }
        arg.text_a = ownArg(name) orelse {
            return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
        };
    }
    // A missing/null color, like an empty one, clears it.
    return respondWorkspaceMutation(alloc, req, server, arg, applySetColor, .row, "{\"ok\":true}");
}

// ------------------------------------------------------------------
// Surface handlers
// ------------------------------------------------------------------

/// One pane's externally visible state, captured on the main thread.
const PaneSnapshot = struct {
    pane_id: PaneTree.NodeId,
    workspace_id: Workspace.WorkspaceId,
    focused: bool,
    alive: bool,
};

/// Snapshots every pane across every workspace. `pane_widgets` and
/// `tab_manager` are owned by the main thread, so the walk happens there and
/// the handler thread only formats the copy.
const SurfaceListCtx = struct {
    window: *Window,
    /// c_allocator so the list survives independently of the request arena if
    /// this context has to be leaked on timeout.
    panes: std.ArrayListUnmanaged(PaneSnapshot) = .{},
    ok: bool = false,
    done: std.Thread.ResetEvent = .{},

    fn run(self: *SurfaceListCtx) void {
        const ca = std.heap.c_allocator;
        const tm = &self.window.tab_manager;
        for (tm.workspaces.items) |ws| {
            var pane_ids = ws.pane_tree.orderedPaneIds(ca) catch return;
            defer pane_ids.deinit(ca);
            for (pane_ids.items) |pane_id| {
                self.panes.append(ca, .{
                    .pane_id = pane_id,
                    .workspace_id = ws.id,
                    .focused = if (ws.pane_tree.focused_pane) |fp| fp == pane_id else false,
                    .alive = self.window.pane_widgets.get(pane_id) != null,
                }) catch return;
            }
        }
        self.ok = true;
    }
};

fn handleSurfaceList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"surfaces\":[]}");
    };

    const ctx = std.heap.c_allocator.create(SurfaceListCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{ .window = window };
    runOnMainThread(SurfaceListCtx, ctx) catch {
        // Deliberately leak ctx: the idle callback may still fire later.
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };
    defer {
        ctx.panes.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(ctx);
    }
    if (!ctx.ok) {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to enumerate surfaces");
    }

    var array = JsonArrayBuilder.init(alloc);
    defer array.deinit();
    try array.startArray();

    for (ctx.panes.items) |pane| {
        const surface_json = try std.fmt.allocPrint(alloc,
            \\{{"id":{d},"ref":"surface:{d}","workspace_id":{d},"pane_id":{d},"focused":{s},"alive":{s}}}
        , .{
            pane.pane_id,
            pane.pane_id,
            pane.workspace_id,
            pane.pane_id,
            if (pane.focused) "true" else "false",
            if (pane.alive) "true" else "false",
        });
        defer alloc.free(surface_json);
        try array.addRaw(surface_json);
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

/// Snapshots the focused pane on the main thread.
const SurfaceCurrentCtx = struct {
    window: *Window,
    found: bool = false,
    pane: PaneSnapshot = .{ .pane_id = 0, .workspace_id = 0, .focused = true, .alive = false },
    done: std.Thread.ResetEvent = .{},

    fn run(self: *SurfaceCurrentCtx) void {
        const ws = self.window.tab_manager.selectedWorkspace() orelse return;
        const pane_id = ws.pane_tree.focused_pane orelse return;
        self.pane = .{
            .pane_id = pane_id,
            .workspace_id = ws.id,
            .focused = true,
            .alive = self.window.pane_widgets.get(pane_id) != null,
        };
        self.found = true;
    }
};

fn handleSurfaceCurrent(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"surface\":null}");
    };

    const ctx = std.heap.c_allocator.create(SurfaceCurrentCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{ .window = window };
    runOnMainThread(SurfaceCurrentCtx, ctx) catch {
        // Deliberately leak ctx: the idle callback may still fire later.
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };
    defer std.heap.c_allocator.destroy(ctx);

    if (!ctx.found) {
        return protocol.successResponse(alloc, req.id, "{\"surface\":null}");
    }

    const surface_json = try std.fmt.allocPrint(alloc,
        \\{{"surface":{{"id":{d},"ref":"surface:{d}","workspace_id":{d},"pane_id":{d},"focused":true,"alive":{s}}}}}
    , .{
        ctx.pane.pane_id,
        ctx.pane.pane_id,
        ctx.pane.workspace_id,
        ctx.pane.pane_id,
        if (ctx.pane.alive) "true" else "false",
    });
    defer alloc.free(surface_json);
    return protocol.successResponse(alloc, req.id, surface_json);
}

/// Sends a pre-encoded binding action to a pane, resolved on the main thread.
const BindingActionCtx = struct {
    window: *Window,
    explicit_pane: ?PaneTree.NodeId,
    /// Owned by this context (c_allocator) so it can be leaked on timeout.
    action: []u8,
    resolve_err: ResolveError = .none,
    pane_id: PaneTree.NodeId = 0,
    sent: bool = false,
    done: std.Thread.ResetEvent = .{},

    fn run(self: *BindingActionCtx) void {
        const resolved = resolveSurfaceOnMain(self.window, self.explicit_pane, .require_realized, &self.resolve_err) orelse return;
        self.pane_id = resolved.pane_id;
        _ = c.ghostty_surface_binding_action(resolved.surface, self.action.ptr, self.action.len);
        self.sent = true;
    }
};

/// Build a BindingActionCtx owning a copy of `action`.
fn createBindingActionCtx(
    window: *Window,
    explicit_pane: ?PaneTree.NodeId,
    action: []const u8,
) ?*BindingActionCtx {
    const ctx = std.heap.c_allocator.create(BindingActionCtx) catch return null;
    const owned = std.heap.c_allocator.dupe(u8, action) catch {
        std.heap.c_allocator.destroy(ctx);
        return null;
    };
    ctx.* = .{ .window = window, .explicit_pane = explicit_pane, .action = owned };
    return ctx;
}

fn destroyBindingActionCtx(ctx: *BindingActionCtx) void {
    std.heap.c_allocator.free(ctx.action);
    std.heap.c_allocator.destroy(ctx);
}

/// Read the optional `surface_id` param. Returns false if it was present but
/// not a usable pane id, matching the previous "no target surface" behaviour.
fn explicitPaneParam(alloc: Allocator, req: *const protocol.Request, out: *?PaneTree.NodeId) bool {
    if (req.getIntParam(alloc, "surface_id")) |sid| {
        out.* = toU64(sid) orelse return false;
    } else {
        out.* = null;
    }
    return true;
}

fn handleSurfaceSendText(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const text = req.getStringParam(alloc, "text") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'text' parameter");
    };
    defer alloc.free(text);

    var explicit_pane: ?PaneTree.NodeId = null;
    if (!explicitPaneParam(alloc, req, &explicit_pane)) {
        return protocol.errorResponse(alloc, req.id, "no_surface", "No target surface found");
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

    const ctx = createBindingActionCtx(window, explicit_pane, action_str) orelse {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    runOnMainThread(BindingActionCtx, ctx) catch {
        // Deliberately leak ctx and its action buffer: the idle callback may
        // still fire later and dereference both.
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };
    defer destroyBindingActionCtx(ctx);

    if (!ctx.sent) return resolveErrorResponse(alloc, req.id, ctx.resolve_err);

    log.info("send_text to pane {d}: {d} bytes", .{ ctx.pane_id, text.len });

    const result = try std.fmt.allocPrint(alloc,
        \\{{"queued":true,"surface_id":{d}}}
    , .{ctx.pane_id});
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

/// Reads a pane's text, resolving the pane on the GTK main thread.
const ReadTextCtx = struct {
    window: *Window,
    explicit_pane: ?PaneTree.NodeId,
    include_scrollback: bool,
    // Output fields — written by main thread, read by handler thread
    resolve_err: ResolveError = .none,
    pane_id: PaneTree.NodeId = 0,
    result: ReadResult = .{},
    done: std.Thread.ResetEvent = .{},

    fn run(self: *ReadTextCtx) void {
        // Reads tolerate an unrealized widget; surface.read_text did not
        // require `realized` before the main-thread refactor.
        const resolved = resolveSurfaceOnMain(self.window, self.explicit_pane, .allow_unrealized, &self.resolve_err) orelse return;
        self.pane_id = resolved.pane_id;
        self.result = readSurfaceTextOnMain(resolved.surface, self.include_scrollback);
    }
};

fn handleSurfaceReadText(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    var explicit_pane: ?PaneTree.NodeId = null;
    if (!explicitPaneParam(alloc, req, &explicit_pane)) {
        return protocol.errorResponse(alloc, req.id, "no_surface", "No target surface found");
    }

    const include_scrollback = req.getBoolParam(alloc, "scrollback") orelse false;

    const ctx = std.heap.c_allocator.create(ReadTextCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{
        .window = window,
        .explicit_pane = explicit_pane,
        .include_scrollback = include_scrollback,
    };

    runOnMainThread(ReadTextCtx, ctx) catch {
        // Deliberately leak ctx: the idle callback may still fire later.
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };
    defer std.heap.c_allocator.destroy(ctx);

    if (ctx.resolve_err != .none) return resolveErrorResponse(alloc, req.id, ctx.resolve_err);
    if (!ctx.result.ok) {
        return protocol.errorResponse(alloc, req.id, "read_failed", "Failed to read terminal text");
    }

    const pane_id = ctx.pane_id;
    if (ctx.result.text) |text_slice| {
        defer std.heap.c_allocator.free(text_slice);

        const escaped = try jsonEscapeString(alloc, text_slice);
        defer alloc.free(escaped);

        const result = try std.fmt.allocPrint(alloc,
            \\{{"text":"{s}","surface_id":{d}}}
        , .{ escaped, pane_id });
        defer alloc.free(result);
        return protocol.successResponse(alloc, req.id, result);
    }

    const result = try std.fmt.allocPrint(alloc,
        \\{{"text":"","surface_id":{d}}}
    , .{pane_id});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

/// Outcome of one polling read during surface.run.
const PollStatus = enum {
    /// The read completed (`text` may still be null if the screen was empty).
    ok,
    /// This attempt failed but the pane may still be fine -- a saturated GTK
    /// main thread or a failed allocation. The caller should retry.
    transient,
    /// The pane is genuinely gone: it no longer resolves to a surface.
    gone,
};

/// Result of one polling read during surface.run.
const PollOutcome = struct {
    status: PollStatus,
    /// Heap-allocated with c_allocator when present.
    text: ?[]u8 = null,
};

/// Read a pane's full scrollback for the surface.run poll loop.
///
/// The pane is re-resolved on the main thread on every call, so a pane closed
/// mid-run ends the poll instead of dereferencing a freed widget or surface.
///
/// A dispatch timeout is reported as `.transient`, not `.gone`: before the
/// main-thread refactor a timed-out read simply skipped that poll iteration,
/// and treating a momentarily busy UI as a closed pane would abort the run and
/// discard output the command had already produced.
fn pollPaneText(window: *Window, pane_id: PaneTree.NodeId) PollOutcome {
    const ctx = std.heap.c_allocator.create(ReadTextCtx) catch return .{ .status = .transient };
    ctx.* = .{
        .window = window,
        .explicit_pane = pane_id,
        .include_scrollback = true,
    };
    runOnMainThread(ReadTextCtx, ctx) catch {
        // Deliberately leak ctx: the idle callback may still fire later.
        return .{ .status = .transient };
    };
    defer std.heap.c_allocator.destroy(ctx);

    if (ctx.resolve_err != .none) return .{ .status = .gone };
    return .{ .status = .ok, .text = ctx.result.text };
}

// ------------------------------------------------------------------
// surface.run — send command, wait for prompt, return output
// ------------------------------------------------------------------

/// Default timeout for surface.run when the caller does not specify one.
const default_run_timeout_secs: u64 = 30;

/// Upper bound on surface.run polling. A caller-supplied timeout is clamped to
/// this so one request cannot pin a handler thread (and its socket connection)
/// for an unbounded stretch.
const max_run_timeout_secs: u64 = 600;

/// Resolves the pane, snapshots the screen, and sends the command in a single
/// main-thread hop, so the surface cannot be destroyed between those steps.
const RunStartCtx = struct {
    window: *Window,
    explicit_pane: ?PaneTree.NodeId,
    /// Owned by this context (c_allocator) so it can be leaked on timeout.
    action: []u8,
    resolve_err: ResolveError = .none,
    pane_id: PaneTree.NodeId = 0,
    before: ReadResult = .{},
    started: bool = false,
    done: std.Thread.ResetEvent = .{},

    fn run(self: *RunStartCtx) void {
        // Sending the command is a write, so the widget must be realized.
        const resolved = resolveSurfaceOnMain(self.window, self.explicit_pane, .require_realized, &self.resolve_err) orelse return;
        self.pane_id = resolved.pane_id;
        self.before = readSurfaceTextOnMain(resolved.surface, true);
        if (!self.before.ok) return;
        _ = c.ghostty_surface_binding_action(resolved.surface, self.action.ptr, self.action.len);
        self.started = true;
    }
};

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
        @min(toU64(@max(t, 1)) orelse default_run_timeout_secs, max_run_timeout_secs)
    else
        default_run_timeout_secs;
    const timeout_ns: u64 = timeout_secs * std.time.ns_per_s;

    const prompt_suffix = req.getStringParam(alloc, "prompt_pattern");
    defer if (prompt_suffix) |ps| alloc.free(ps);

    var explicit_pane: ?PaneTree.NodeId = null;
    if (!explicitPaneParam(alloc, req, &explicit_pane)) {
        return protocol.errorResponse(alloc, req.id, "no_surface", "No target surface found");
    }

    var timer = std.time.Timer.start() catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "No monotonic clock available");
    };

    // 2. Encode the command as a binding action ("text:" + escapes).
    const cmd_with_newline = try std.fmt.allocPrint(alloc, "{s}\n", .{command});
    defer alloc.free(cmd_with_newline);
    const action_str = try encodeBindingActionText(alloc, cmd_with_newline);
    defer alloc.free(action_str);

    // 3. Resolve + snapshot + send, atomically on the main thread.
    const start_ctx = std.heap.c_allocator.create(RunStartCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    const action_owned = std.heap.c_allocator.dupe(u8, action_str) catch {
        std.heap.c_allocator.destroy(start_ctx);
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    start_ctx.* = .{ .window = window, .explicit_pane = explicit_pane, .action = action_owned };

    runOnMainThread(RunStartCtx, start_ctx) catch {
        // Deliberately leak ctx and its action buffer: the idle callback may
        // still fire later and dereference both.
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };

    const pane_id = start_ctx.pane_id;
    const resolve_err = start_ctx.resolve_err;
    const started = start_ctx.started;
    const before_result = start_ctx.before;
    std.heap.c_allocator.free(start_ctx.action);
    std.heap.c_allocator.destroy(start_ctx);

    if (resolve_err != .none) return resolveErrorResponse(alloc, req.id, resolve_err);
    if (!started) {
        if (before_result.text) |bt| std.heap.c_allocator.free(bt);
        return protocol.errorResponse(alloc, req.id, "read_failed", "Failed to read initial terminal text");
    }
    defer if (before_result.text) |bt| std.heap.c_allocator.free(bt);
    const before_text: []const u8 = before_result.text orelse &[_]u8{};

    // 4. Poll for the prompt to reappear. Every read re-resolves the pane on
    //    the main thread, so a pane closed mid-run ends the loop cleanly
    //    instead of reading through a freed widget.
    const poll_interval_ns: u64 = 150_000_000; // 150ms
    // Each timed-out dispatch leaks its context, so give up rather than
    // retrying forever against a wedged UI.
    const max_consecutive_transient: u8 = 3;
    var timed_out = true;
    var final_text: ?[]u8 = null;
    var pane_gone = false;
    var stalled = false;
    var transient_count: u8 = 0;

    while (timer.read() < timeout_ns) {
        std.Thread.sleep(poll_interval_ns);

        const outcome = pollPaneText(window, pane_id);
        switch (outcome.status) {
            .gone => {
                pane_gone = true;
                break;
            },
            .transient => {
                transient_count += 1;
                if (transient_count >= max_consecutive_transient) {
                    stalled = true;
                    break;
                }
                continue;
            },
            .ok => transient_count = 0,
        }

        const current = outcome.text orelse continue;

        // Text must have grown beyond the before snapshot + command echo
        if (current.len > before_text.len and endsWithPrompt(current, prompt_suffix)) {
            final_text = current;
            timed_out = false;
            break;
        }
        std.heap.c_allocator.free(current);
    }

    if (pane_gone) {
        if (final_text) |ft| std.heap.c_allocator.free(ft);
        return protocol.errorResponse(alloc, req.id, "dead_surface", "Surface was closed while the command was running");
    }
    if (stalled) {
        if (final_text) |ft| std.heap.c_allocator.free(ft);
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out while polling the terminal");
    }

    // On timeout, do one final read
    if (timed_out and final_text == null) {
        final_text = pollPaneText(window, pane_id).text;
    }

    // 5. Extract output between command echo and final prompt
    const output = if (final_text) |ft| blk: {
        defer std.heap.c_allocator.free(ft);
        break :blk extractCommandOutput(alloc, before_text, ft, command) catch "";
    } else "";
    defer if (output.len > 0) alloc.free(@constCast(output));

    // 6. Build JSON response
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

    var explicit_pane: ?PaneTree.NodeId = null;
    if (!explicitPaneParam(alloc, req, &explicit_pane)) {
        return protocol.errorResponse(alloc, req.id, "no_surface", "No target surface found");
    }

    const action_bytes = resolveKeyAction(alloc, key) orelse {
        return protocol.errorResponse(alloc, req.id, "unknown_key", "Unknown key name");
    };
    defer alloc.free(action_bytes);

    const ctx = createBindingActionCtx(window, explicit_pane, action_bytes) orelse {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    runOnMainThread(BindingActionCtx, ctx) catch {
        // Deliberately leaked; see handleSurfaceSendText.
        return protocol.errorResponse(alloc, req.id, "timeout", "GTK dispatch timed out");
    };
    defer destroyBindingActionCtx(ctx);

    if (!ctx.sent) return resolveErrorResponse(alloc, req.id, ctx.resolve_err);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"sent":true,"key":"{s}","surface_id":{d}}}
    , .{ key, ctx.pane_id });
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

    /// Checks the workspace and last-pane guard on the main thread before
    /// closing. Reading `selectedWorkspace()`/`paneCount()` from a handler
    /// thread would race workspace create/close and pane split/close.
    fn checkGuards(self: *SurfaceCloseCtx) bool {
        const ws = self.window.tab_manager.selectedWorkspace() orelse {
            self.err_code = "no_workspace";
            self.err_msg = "No workspace selected";
            return false;
        };
        if (ws.pane_tree.paneCount() <= 1) {
            self.err_code = "last_pane";
            self.err_msg = "Cannot close the last pane";
            return false;
        }
        return true;
    }
};

fn handleSurfaceClose(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

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
    if (!ctx.checkGuards()) return c.G_SOURCE_REMOVE;
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
    return respondWorkspaceSwitch(alloc, req, window, .next);
}

fn handleWorkspacePrevious(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };
    return respondWorkspaceSwitch(alloc, req, window, .previous);
}

fn handleWorkspaceLast(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };
    return respondWorkspaceSwitch(alloc, req, window, .last_visited);
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

// ------------------------------------------------------------------
// Window handlers
// ------------------------------------------------------------------

/// MUST run on the GTK main thread (see JsonOnMain).
fn buildWindowListJson(window: *Window, alloc: Allocator, _: void) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\{{"windows":[{{"id":1,"ref":"window:1","focused":true,"workspace_count":{d}}}]}}
    , .{window.tab_manager.workspaces.items.len});
}

fn handleWindowList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

fn handleWindowCurrent(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"window\":null}");
    };
    return respondFromMainThread(alloc, req, window, buildWindowCurrentJson);
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
/// Which workspace a Claude hook targets.
const ClaudeTarget = union(enum) {
    id: u64,
    /// No explicit target: use whichever workspace is selected.
    current,
    /// A target was given but is not a usable workspace id.
    invalid,
};

/// Resolve the target workspace *id* for a Claude hook.
///
/// Only touches the session store (which has its own mutex) and request
/// params, never `tab_manager` -- the id is turned into a `*Workspace` on the
/// main thread by WorkspaceMutationCtx.
fn resolveClaudeTarget(server: *Server, alloc: Allocator, req: *const protocol.Request) ClaudeTarget {
    // 1. Explicit workspace_id param
    if (req.getIntParam(alloc, "workspace_id")) |id| {
        return .{ .id = toU64(id) orelse return .invalid };
    }

    // 2. Look up via session store
    if (req.getStringParam(alloc, "session_id")) |sid| {
        defer alloc.free(sid);
        if (server.claude_session_store.lookup(sid)) |rec| {
            return .{ .id = rec.workspace_id };
        }
    }

    // 3. Fall back to current workspace
    return .current;
}

/// Apply a Claude status change and return the workspace it landed on.
fn claudeStatusUpdate(
    server: *Server,
    target: ClaudeTarget,
    arg: WsMutArg,
    apply: *const fn (*Workspace, WsMutArg) void,
) ?u64 {
    const window = server.window orelse {
        arg.free();
        return null;
    };
    const target_id: ?u64 = switch (target) {
        .id => |wid| wid,
        .current => null,
        .invalid => {
            arg.free();
            return null;
        },
    };
    return switch (mutateWorkspaceOnMain(window, target_id, arg, apply, .row)) {
        .ok => |wid| wid,
        .not_found, .unavailable => null,
    };
}

/// Sets the "claude" status entry to WsMutArg.text_a.
fn applyClaudeStatus(ws: *Workspace, arg: WsMutArg) void {
    ws.setStatusEntry("claude", arg.text_a orelse return);
}

/// Removes the "claude" status entry.
fn applyClaudeStatusClear(ws: *Workspace, _: WsMutArg) void {
    ws.removeStatusEntry("claude");
}

fn handleClaudeSessionStart(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const target = resolveClaudeTarget(server, alloc, req);

    const arg = WsMutArg{ .text_a = ownArg("Running") orelse {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    } };
    const ws_id = claudeStatusUpdate(server, target, arg, applyClaudeStatus) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    // Store session mapping
    const session_id = req.getStringParam(alloc, "session_id");
    defer if (session_id) |s| alloc.free(s);
    const cwd = req.getStringParam(alloc, "cwd");
    defer if (cwd) |c_val| alloc.free(c_val);
    const surface_id: u64 = if (req.getIntParam(alloc, "surface_id")) |s| (toU64(s) orelse 0) else 0;

    if (session_id) |sid| {
        server.claude_session_store.upsert(sid, ws_id, surface_id, cwd);
    }

    log.info("Claude session started for workspace {d}", .{ws_id});
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

fn handleClaudeStop(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const target = resolveClaudeTarget(server, alloc, req);

    const ws_id = claudeStatusUpdate(server, target, .{}, applyClaudeStatusClear) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    // Consume session mapping
    const session_id = req.getStringParam(alloc, "session_id");
    defer if (session_id) |s| alloc.free(s);
    const surface_id: u64 = if (req.getIntParam(alloc, "surface_id")) |s| (toU64(s) orelse 0) else 0;

    const record = server.claude_session_store.consume(session_id, ws_id, if (surface_id > 0) surface_id else null);

    // Build notification body from stored record if available
    const notif_body: []const u8 = if (record) |rec|
        rec.getLastBody() orelse "Session complete"
    else
        "Session complete";

    _ = server.notification_store.add("Claude Code", notif_body);

    log.info("Claude session stopped for workspace {d}", .{ws_id});
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

fn handleClaudeNotification(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const target = resolveClaudeTarget(server, alloc, req);

    const message = req.getStringParam(alloc, "message");
    defer if (message) |m| alloc.free(m);
    const event = req.getStringParam(alloc, "event");
    defer if (event) |e| alloc.free(e);

    // Classify notification
    const classified = classifyClaudeNotification(event, message);

    const arg = WsMutArg{ .text_a = ownArg(classified.label) orelse {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    } };
    const ws_id = claudeStatusUpdate(server, target, arg, applyClaudeStatus) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

    // Fire desktop notification
    _ = server.notification_store.add("Claude Code", classified.body);

    // Update session record with last message info
    const session_id = req.getStringParam(alloc, "session_id");
    defer if (session_id) |s| alloc.free(s);
    server.claude_session_store.updateMessage(session_id, ws_id, classified.label, classified.body);

    log.info("Claude notification ({s}) for workspace {d}", .{ classified.label, ws_id });
    return protocol.successResponse(alloc, req.id, "{\"ok\":true}");
}

fn handleClaudePromptSubmit(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const target = resolveClaudeTarget(server, alloc, req);

    const arg = WsMutArg{ .text_a = ownArg("Running") orelse {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    } };
    _ = claudeStatusUpdate(server, target, arg, applyClaudeStatus) orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
    };

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

    const text = history.loadEntryText(alloc, id) catch |err| switch (err) {
        error.InvalidEntryId => return protocol.errorResponse(alloc, req.id, "invalid_id", "History id contains unsupported characters"),
        else => return protocol.errorResponse(alloc, req.id, "not_found", "History entry not found"),
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

    history.deleteEntry(alloc, id) catch |err| switch (err) {
        error.InvalidEntryId => return protocol.errorResponse(alloc, req.id, "invalid_id", "History id contains unsupported characters"),
        error.NotFound => return protocol.errorResponse(alloc, req.id, "not_found", "History entry not found"),
        error.IndexUnavailable => return protocol.errorResponse(alloc, req.id, "index_unavailable", "History index could not be read"),
    };

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
