//! surface.* handlers: list, current, send_text, read_text, run, send_key,
//! split, close, search.

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

    pub fn run(self: *SurfaceListCtx) void {
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

pub fn handleSurfaceList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

    pub fn run(self: *SurfaceCurrentCtx) void {
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

pub fn handleSurfaceCurrent(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

    pub fn run(self: *BindingActionCtx) void {
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

pub fn handleSurfaceSendText(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

    pub fn run(self: *ReadTextCtx) void {
        // Reads tolerate an unrealized widget; surface.read_text did not
        // require `realized` before the main-thread refactor.
        const resolved = resolveSurfaceOnMain(self.window, self.explicit_pane, .allow_unrealized, &self.resolve_err) orelse return;
        self.pane_id = resolved.pane_id;
        self.result = readSurfaceTextOnMain(resolved.surface, self.include_scrollback);
    }
};

pub fn handleSurfaceReadText(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

    pub fn run(self: *RunStartCtx) void {
        // Sending the command is a write, so the widget must be realized.
        const resolved = resolveSurfaceOnMain(self.window, self.explicit_pane, .require_realized, &self.resolve_err) orelse return;
        self.pane_id = resolved.pane_id;
        self.before = readSurfaceTextOnMain(resolved.surface, true);
        if (!self.before.ok) return;
        _ = c.ghostty_surface_binding_action(resolved.surface, self.action.ptr, self.action.len);
        self.started = true;
    }
};

pub fn handleSurfaceRun(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleSurfaceSendKey(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleSurfaceSplit(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleSurfaceClose(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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

pub fn handleSurfaceSearch(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
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
