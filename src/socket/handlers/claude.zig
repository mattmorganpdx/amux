//! claude.hook handlers: Claude Code session status reported into the sidebar.

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

const workspace = @import("workspace.zig");
const WsMutArg = workspace.WsMutArg;
const ownArg = workspace.ownArg;
const mutateWorkspaceOnMain = workspace.mutateWorkspaceOnMain;

// ------------------------------------------------------------------
// Claude Code integration
// ------------------------------------------------------------------

pub fn handleClaudeHook(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleClaudeSessionStart(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleClaudeStop(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleClaudeNotification(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleClaudePromptSubmit(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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
