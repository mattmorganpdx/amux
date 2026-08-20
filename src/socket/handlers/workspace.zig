//! workspace.* handlers: lifecycle (list/create/select/close/rename,
//! next/previous/last) and sidebar metadata mutations.
//!
//! The mutation machinery (`WsMutArg`, `mutateWorkspaceOnMain`) is also used
//! by the Claude hook handlers.

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

pub fn handleWorkspaceList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

    pub fn run(self: *WorkspaceCreateCtx) void {
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

pub fn handleWorkspaceCreate(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleWorkspaceCurrent(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"workspace\":null}");
    };
    return respondFromMainThread(alloc, req, window, buildWorkspaceCurrentJson);
}

pub fn handleWorkspaceSelect(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

    pub fn run(self: *WorkspaceSwitchCtx) void {
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

pub fn handleWorkspaceClose(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

    pub fn run(self: *WorkspaceCloseCtx) void {
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


pub fn handleWorkspaceRename(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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
pub const WsMutArg = struct {
    text_a: ?[]u8 = null,
    text_b: ?[]u8 = null,
    number: f64 = 0,
    flag: bool = false,
    has_flag: bool = false,

    pub fn free(self: WsMutArg) void {
        const ca = std.heap.c_allocator;
        if (self.text_a) |t| ca.free(t);
        if (self.text_b) |t| ca.free(t);
    }
};

/// Copy a request-allocator string into a c_allocator buffer for a WsMutArg.
pub fn ownArg(text: []const u8) ?[]u8 {
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

    pub fn run(self: *WorkspaceMutationCtx) void {
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
pub fn mutateWorkspaceOnMain(
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


pub fn handleWorkspaceReportGit(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleWorkspaceSetStatus(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleWorkspaceClearStatus(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleWorkspaceAddLog(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const text = req.getStringParam(alloc, "text") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'text' parameter");
    };
    defer alloc.free(text);

    const arg = WsMutArg{ .text_a = ownArg(text) orelse {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    } };
    return respondWorkspaceMutation(alloc, req, server, arg, applyAddLog, .row, "{\"ok\":true}");
}

pub fn handleWorkspaceClearLog(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    return respondWorkspaceMutation(alloc, req, server, .{}, applyClearLog, .row, "{\"ok\":true}");
}

pub fn handleWorkspaceSetProgress(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleWorkspaceSetPinned(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const pinned = req.getBoolParam(alloc, "pinned") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'pinned' parameter");
    };
    // Pinning changes sort order, so rebuild the whole sidebar.
    return respondWorkspaceMutation(alloc, req, server, .{ .flag = pinned }, applySetPinned, .rebuild, "{\"ok\":true}");
}

pub fn handleWorkspaceSetColor(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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
// workspace.next / workspace.previous / workspace.last
// ------------------------------------------------------------------

pub fn handleWorkspaceNext(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };
    return respondWorkspaceSwitch(alloc, req, window, .next);
}

pub fn handleWorkspacePrevious(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };
    return respondWorkspaceSwitch(alloc, req, window, .previous);
}

pub fn handleWorkspaceLast(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };
    return respondWorkspaceSwitch(alloc, req, window, .last_visited);
}
