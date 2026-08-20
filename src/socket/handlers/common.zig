//! Shared handler infrastructure: main-thread dispatch, surface
//! resolution, and JSON building.
//!
//! All window state is owned by the GTK main thread; see `runOnMainThread`.

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

/// Safely cast an i64 to u64, returning null if negative.
pub fn toU64(val: i64) ?u64 {
    if (val < 0) return null;
    return @intCast(val);
}

/// Safely cast an i64 to usize, returning null if negative.
pub fn toUsize(val: i64) ?usize {
    if (val < 0) return null;
    return @intCast(val);
}

/// Timeout for GTK idle dispatch operations (10 seconds).
/// GTK callbacks should complete near-instantly; this guards against hangs.
pub const gtk_dispatch_timeout_ns: u64 = 10_000_000_000;

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
pub fn runOnMainThread(comptime Ctx: type, ctx: *Ctx) error{Timeout}!void {
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
pub fn respondFromMainThreadWith(
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
pub fn respondFromMainThread(
    alloc: Allocator,
    req: *const protocol.Request,
    window: *Window,
    comptime build: fn (*Window, Allocator, void) anyerror![]const u8,
) ![]const u8 {
    return respondFromMainThreadWith(alloc, req, window, void, build, {});
}

/// Why a pane could not be resolved to a live surface.
pub const ResolveError = enum { none, no_surface, dead_surface, dead_realized };

/// A pane resolved to a live Ghostty surface.
pub const ResolvedSurface = struct {
    surface: c.ghostty_surface_t,
    pane_id: PaneTree.NodeId,
};

/// Whether an operation needs the widget to be GTK-realized.
///
/// Writing to a surface does; reading from it does not. `onUnrealize` clears
/// `realized` but deliberately leaves `surface` non-null, so a widget that GTK
/// has transiently unrealized (e.g. during the reparenting done by pane
/// break/join/swap) can still be read from.
pub const RealizedRequirement = enum { require_realized, allow_unrealized };

/// Resolve `explicit` (or the focused pane when null) to a live surface.
///
/// MUST be called on the GTK main thread. The returned surface is only valid
/// for the duration of that callback -- never store it across a dispatch.
pub fn resolveSurfaceOnMain(
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
pub fn resolveErrorResponse(alloc: Allocator, req_id: i64, err: ResolveError) ![]const u8 {
    return switch (err) {
        .dead_surface, .dead_realized => protocol.errorResponse(alloc, req_id, "dead_surface", "Surface is not active (unrealized or uninitialized)"),
        else => protocol.errorResponse(alloc, req_id, "no_surface", "No target surface found"),
    };
}

/// Outcome of reading a surface's text.
pub const ReadResult = struct {
    ok: bool = false,
    /// Heap-allocated with c_allocator; null when the surface had no text.
    text: ?[]u8 = null,
};

/// Read a surface's text. MUST be called on the GTK main thread.
pub fn readSurfaceTextOnMain(surface: c.ghostty_surface_t, include_scrollback: bool) ReadResult {
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
// ------------------------------------------------------------------
// JSON builder helpers
// ------------------------------------------------------------------

/// A simple JSON array builder that produces `[{...},{...}]`.
pub const JsonArrayBuilder = struct {
    buf: std.ArrayListUnmanaged(u8) = .{},
    alloc: Allocator,
    count: usize = 0,

    pub fn init(alloc: Allocator) JsonArrayBuilder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *JsonArrayBuilder) void {
        self.buf.deinit(self.alloc);
    }

    pub fn startArray(self: *JsonArrayBuilder) !void {
        try self.buf.append(self.alloc, '[');
    }

    pub fn endArray(self: *JsonArrayBuilder) !void {
        try self.buf.append(self.alloc, ']');
    }

    pub fn addRaw(self: *JsonArrayBuilder, json: []const u8) !void {
        if (self.count > 0) {
            try self.buf.append(self.alloc, ',');
        }
        try self.buf.appendSlice(self.alloc, json);
        self.count += 1;
    }

    pub fn toOwnedSlice(self: *JsonArrayBuilder) ![]const u8 {
        return self.buf.toOwnedSlice(self.alloc);
    }
};

/// Escape a string for JSON embedding.
pub fn jsonEscapeString(alloc: Allocator, s: []const u8) ![]const u8 {
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
pub fn parseDirection(dir_str: []const u8) ?PaneTree.SplitDirection {
    if (std.mem.eql(u8, dir_str, "left")) return .left;
    if (std.mem.eql(u8, dir_str, "right")) return .right;
    if (std.mem.eql(u8, dir_str, "up")) return .up;
    if (std.mem.eql(u8, dir_str, "down")) return .down;
    return null;
}
