//! Socket request handlers for the daemon.
//!
//! These are new rather than moved. The plan expected `src/socket/handlers/` to
//! come across largely as-is, and that held for the *protocol* -- `protocol.zig`
//! is reused unchanged, and the method names and response shapes match -- but
//! not for the bodies. The GUI's surface and pane handlers are written around
//! `Window`: they drive GtkPaned trees, rebuild the sidebar, and hop onto the
//! GTK main thread for every read. None of that exists here, so they are
//! rewritten against `State`.
//!
//! The upside is that `runOnMainThread`, the resolve-on-the-main-thread dance
//! and the leak-on-timeout contexts all disappear: there is no second thread to
//! defer to, so a handler just takes the state lock and does the work.
//!
//! Not implemented yet, deliberately: notifications, the command palette, the
//! Claude hooks and the sidebar metadata methods. All of those exist to drive
//! GUI chrome, and belong with item 6 when the GUI becomes a client.

const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("../socket/protocol.zig");
const PaneTree = @import("../pane_tree.zig");
const History = @import("History.zig");
const State = @import("State.zig");
const Workspace = @import("../workspace.zig");

const log = std.log.scoped(.daemon_handlers);

/// Methods this daemon answers. `system.capabilities` reports it, so a client
/// can tell what it is talking to.
const methods = [_][]const u8{
    "system.ping",
    "system.identify",
    "system.capabilities",
    "workspace.list",
    "workspace.create",
    "workspace.current",
    "workspace.select",
    "workspace.close",
    "workspace.rename",
    "surface.list",
    "surface.current",
    "surface.send_text",
    "surface.read_text",
    "surface.screen",
    "surface.send_key",
    "surface.split",
    "surface.close",
    "surface.run",
    "pane.list",
    "history.list",
    "history.show",
    "history.search",
    "history.delete",
};

/// Default and maximum rows returned by a history query.
const default_history_limit: usize = 50;
const max_history_limit: usize = 500;

pub fn dispatch(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const m = req.method;
    if (eq(m, "system.ping")) return protocol.successResponse(alloc, req.id, "{\"pong\":true}");
    if (eq(m, "system.capabilities")) return capabilities(alloc, req);
    if (eq(m, "system.identify")) return identify(alloc, state, req);

    if (eq(m, "workspace.list")) return workspaceList(alloc, state, req);
    if (eq(m, "workspace.create")) return workspaceCreate(alloc, state, req);
    if (eq(m, "workspace.current")) return workspaceCurrent(alloc, state, req);
    if (eq(m, "workspace.select")) return workspaceSelect(alloc, state, req);
    if (eq(m, "workspace.close")) return workspaceClose(alloc, state, req);
    if (eq(m, "workspace.rename")) return workspaceRename(alloc, state, req);

    if (eq(m, "surface.list") or eq(m, "pane.list")) return paneList(alloc, state, req);
    if (eq(m, "surface.current")) return surfaceCurrent(alloc, state, req);
    if (eq(m, "surface.send_text")) return sendText(alloc, state, req);
    if (eq(m, "surface.read_text")) return readText(alloc, state, req);
    if (eq(m, "surface.screen")) return surfaceScreen(alloc, state, req);
    if (eq(m, "surface.send_key")) return sendKey(alloc, state, req);
    if (eq(m, "surface.split")) return split(alloc, state, req);
    if (eq(m, "surface.close")) return closePane(alloc, state, req);
    if (eq(m, "surface.run")) return run(alloc, state, req);

    if (eq(m, "history.list")) return historyList(alloc, state, req);
    if (eq(m, "history.show")) return historyShow(alloc, state, req);
    if (eq(m, "history.search")) return historySearch(alloc, state, req);
    if (eq(m, "history.delete")) return historyDelete(alloc, state, req);

    return protocol.errorResponse(alloc, req.id, "method_not_found", req.method);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Map a State error onto the wire vocabulary the GUI already used.
fn stateError(alloc: Allocator, id: i64, err: anyerror) ![]const u8 {
    return switch (err) {
        error.WorkspaceNotFound => protocol.errorResponse(alloc, id, "not_found", "Workspace not found"),
        error.PaneNotFound => protocol.errorResponse(alloc, id, "no_surface", "No target surface found"),
        error.NoWorkspace => protocol.errorResponse(alloc, id, "no_workspace", "No workspace selected"),
        error.LastPane => protocol.errorResponse(alloc, id, "last_pane", "Cannot close the last pane"),
        else => protocol.errorResponse(alloc, id, "internal_error", @errorName(err)),
    };
}

fn jsonEscape(alloc: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(alloc);
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (ch < 0x20) {
            var buf: [6]u8 = undefined;
            try out.appendSlice(alloc, std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch continue);
        } else try out.append(alloc, ch),
    };
    return out.toOwnedSlice(alloc);
}

fn toU64(v: i64) ?u64 {
    return if (v < 0) null else @intCast(v);
}

fn optionalIdParam(alloc: Allocator, req: *const protocol.Request, name: []const u8) ?u64 {
    const raw = req.getIntParam(alloc, name) orelse return null;
    return toU64(raw);
}

// --- system ------------------------------------------------------------

fn capabilities(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"methods\":[");
    for (methods, 0..) |m, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.append(alloc, '"');
        try out.appendSlice(alloc, m);
        try out.append(alloc, '"');
    }
    try out.appendSlice(alloc, "],\"daemon\":true}");
    return protocol.successResponse(alloc, req.id, out.items);
}

fn identify(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const ws_id = state.selectedWorkspaceId();
    const pane_id: ?u64 = state.resolvePane(null) catch null;

    const body = if (ws_id) |w|
        try std.fmt.allocPrint(alloc,
            \\{{"focused":{{"workspace_id":{d},"pane_id":{?d}}},"daemon":true}}
        , .{ w, pane_id })
    else
        try alloc.dupe(u8, "{\"focused\":null,\"daemon\":true}");
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

// --- workspaces --------------------------------------------------------

const WorkspaceJson = struct {
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    first: bool = true,

    fn append(self: *WorkspaceJson, ws: *Workspace, selected: bool, index: usize) anyerror!void {
        if (!self.first) try self.out.append(self.alloc, ',');
        self.first = false;

        const title = try jsonEscape(self.alloc, ws.getTitle());
        defer self.alloc.free(title);

        const json = try std.fmt.allocPrint(self.alloc,
            \\{{"id":{d},"ref":"workspace:{d}","title":"{s}","index":{d},"selected":{s},"pinned":{s},"pane_count":{d}}}
        , .{
            ws.id,
            ws.id,
            title,
            index,
            if (selected) "true" else "false",
            if (ws.pinned) "true" else "false",
            ws.pane_tree.paneCount(),
        });
        defer self.alloc.free(json);
        try self.out.appendSlice(self.alloc, json);
    }
};

fn workspaceList(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"workspaces\":[");

    var builder: WorkspaceJson = .{ .alloc = alloc, .out = &out };
    try state.withWorkspaces(&builder, WorkspaceJson.append);

    try out.appendSlice(alloc, "]}");
    return protocol.successResponse(alloc, req.id, out.items);
}

fn workspaceCurrent(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"workspace\":");

    var builder: WorkspaceJson = .{ .alloc = alloc, .out = &out };
    state.withWorkspace(null, &builder, WorkspaceJson.append) catch {
        return protocol.successResponse(alloc, req.id, "{\"workspace\":null}");
    };

    try out.append(alloc, '}');
    return protocol.successResponse(alloc, req.id, out.items);
}

fn workspaceCreate(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const title = req.getStringParam(alloc, "title");
    defer if (title) |t| alloc.free(t);
    const cwd = req.getStringParam(alloc, "cwd");
    defer if (cwd) |c| alloc.free(c);

    const id = state.createWorkspace(title, cwd) catch |err| return stateError(alloc, req.id, err);

    const body = try std.fmt.allocPrint(alloc, "{{\"workspace\":{{\"id\":{d}}}}}", .{id});
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn workspaceSelect(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const id = optionalIdParam(alloc, req, "id") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'id'");
    state.selectWorkspace(id) catch |err| return stateError(alloc, req.id, err);
    const body = try std.fmt.allocPrint(alloc, "{{\"selected\":{d}}}", .{id});
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn workspaceClose(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const id = optionalIdParam(alloc, req, "id") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'id'");
    state.closeWorkspace(id) catch |err| return stateError(alloc, req.id, err);
    return protocol.successResponse(alloc, req.id, "{\"closed\":true}");
}

fn workspaceRename(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const title = req.getStringParam(alloc, "title") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'title'");
    defer alloc.free(title);
    const id = optionalIdParam(alloc, req, "id");
    _ = state.renameWorkspace(id, title) catch |err| return stateError(alloc, req.id, err);
    return protocol.successResponse(alloc, req.id, "{\"renamed\":true}");
}

// --- panes / surfaces --------------------------------------------------

fn paneList(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const panes = state.listPanes(alloc) catch |err| return stateError(alloc, req.id, err);
    defer alloc.free(panes);

    const key = if (eq(req.method, "pane.list")) "panes" else "surfaces";

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"");
    try out.appendSlice(alloc, key);
    try out.appendSlice(alloc, "\":[");
    for (panes, 0..) |p, i| {
        if (i > 0) try out.append(alloc, ',');
        const json = try std.fmt.allocPrint(alloc,
            \\{{"id":{d},"ref":"surface:{d}","pane_id":{d},"workspace_id":{d},"focused":{s},"alive":{s}}}
        , .{
            p.id, p.id, p.id, p.workspace_id,
            if (p.focused) "true" else "false",
            if (p.exited) "false" else "true",
        });
        defer alloc.free(json);
        try out.appendSlice(alloc, json);
    }
    try out.appendSlice(alloc, "]}");
    return protocol.successResponse(alloc, req.id, out.items);
}

fn surfaceCurrent(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const pane_id = state.resolvePane(null) catch
        return protocol.successResponse(alloc, req.id, "{\"surface\":null}");
    const ws_id = state.selectedWorkspaceId() orelse 0;
    const body = try std.fmt.allocPrint(alloc,
        \\{{"surface":{{"id":{d},"ref":"surface:{d}","pane_id":{d},"workspace_id":{d},"focused":true}}}}
    , .{ pane_id, pane_id, pane_id, ws_id });
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn sendText(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const text = req.getStringParam(alloc, "text") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'text'");
    defer alloc.free(text);

    const explicit = optionalIdParam(alloc, req, "surface_id");
    state.writePane(explicit, text) catch |err| return stateError(alloc, req.id, err);

    const id = state.resolvePane(explicit) catch 0;
    const body = try std.fmt.allocPrint(alloc, "{{\"queued\":true,\"surface_id\":{d}}}", .{id});
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn readText(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const explicit = optionalIdParam(alloc, req, "surface_id");
    const scrollback = req.getBoolParam(alloc, "scrollback") orelse false;

    const text = state.readPane(explicit, alloc, scrollback) catch |err| return stateError(alloc, req.id, err);
    defer alloc.free(text);
    const escaped = try jsonEscape(alloc, text);
    defer alloc.free(escaped);

    const id = state.resolvePane(explicit) catch 0;
    const body = try std.fmt.allocPrint(alloc, "{{\"text\":\"{s}\",\"surface_id\":{d}}}", .{ escaped, id });
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

/// Longest a client may ask the daemon to hold a connection open waiting for the
/// screen to change. A watcher that wants to wait longer re-asks, which also
/// makes it prove it is still there.
const max_screen_timeout_ms: u32 = 30_000;

/// The screen as cells, for a client that draws it.
///
/// One method covers attach and update both: pass no `since` and get the whole
/// screen, pass the `seq` from last time and get only the rows that changed.
/// Attaching is just `since = 0`, so there is no separate attach handshake that
/// could disagree with the update path.
///
/// `timeout_ms` turns it into a wait: the daemon answers as soon as the screen
/// changes, or reports no change when the time is up. That is deliberately not
/// named `surface.watch` -- the roadmap keeps that name for semantic wake events
/// (a TUI appeared, a prompt is waiting), which is a different question asked by
/// a different kind of client. Both sit on the same change notification.
fn surfaceScreen(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const explicit = optionalIdParam(alloc, req, "surface_id");
    const since: u64 = if (req.getIntParam(alloc, "since")) |v| toU64(v) orelse 0 else 0;
    const requested: u32 = if (req.getIntParam(alloc, "timeout_ms")) |v|
        @intCast(@max(0, @min(v, @as(i64, max_screen_timeout_ms))))
    else
        0;

    const pane_id = state.resolvePane(explicit) catch |err| return stateError(alloc, req.id, err);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);

    const seq = state.paneScreen(pane_id, alloc, &out, .{
        .since = since,
        .timeout_ms = requested,
    }) catch |err| return stateError(alloc, req.id, err);

    if (seq == null) {
        // Nothing changed in the time allowed. Echoing the sequence number back
        // means the client can loop on the reply without tracking it separately.
        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"pane_id\":{d},\"seq\":{d},\"changed\":false}}",
            .{ pane_id, since },
        );
        defer alloc.free(body);
        return protocol.successResponse(alloc, req.id, body);
    }

    return protocol.successResponse(alloc, req.id, out.items);
}

fn sendKey(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const key = req.getStringParam(alloc, "key") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'key'");
    defer alloc.free(key);

    const bytes = keyBytes(key) orelse
        return protocol.errorResponse(alloc, req.id, "unknown_key", "Unknown key name");

    const explicit = optionalIdParam(alloc, req, "surface_id");
    state.writePane(explicit, bytes) catch |err| return stateError(alloc, req.id, err);

    const escaped = try jsonEscape(alloc, key);
    defer alloc.free(escaped);
    const body = try std.fmt.allocPrint(alloc, "{{\"sent\":true,\"key\":\"{s}\"}}", .{escaped});
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

/// Named keys to the bytes a terminal actually expects.
///
/// The GUI mapped these onto Ghostty binding-action strings because it went
/// through a Surface. Writing straight to a pty, the bytes are the whole story.
fn keyBytes(name: []const u8) ?[]const u8 {
    var lower_buf: [32]u8 = undefined;
    if (name.len > lower_buf.len) return null;
    for (name, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
    const k = lower_buf[0..name.len];

    // ctrl-<letter> is the letter minus 0x60.
    if ((std.mem.startsWith(u8, k, "ctrl-") or std.mem.startsWith(u8, k, "ctrl+")) and k.len == 6) {
        const c = k[5];
        if (c >= 'a' and c <= 'z') {
            const table = "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a";
            return table[c - 'a' ..][0..1];
        }
    }

    const map = .{
        .{ "enter", "\r" },     .{ "return", "\r" },
        .{ "tab", "\t" },       .{ "escape", "\x1b" },
        .{ "esc", "\x1b" },     .{ "space", " " },
        .{ "backspace", "\x7f" },
        .{ "up", "\x1b[A" },    .{ "down", "\x1b[B" },
        .{ "right", "\x1b[C" }, .{ "left", "\x1b[D" },
        .{ "home", "\x1b[H" },  .{ "end", "\x1b[F" },
        .{ "pageup", "\x1b[5~" }, .{ "pagedown", "\x1b[6~" },
        .{ "delete", "\x1b[3~" }, .{ "insert", "\x1b[2~" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, k, entry[0])) return entry[1];
    }
    return null;
}

fn split(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const dir_str = req.getStringParam(alloc, "direction") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'direction'");
    defer alloc.free(dir_str);

    const direction = parseDirection(dir_str) orelse
        return protocol.errorResponse(alloc, req.id, "invalid_direction", "Direction must be left, right, up or down");

    const explicit = optionalIdParam(alloc, req, "surface_id");
    const target = state.resolvePane(explicit) catch |err| return stateError(alloc, req.id, err);
    const new_id = state.splitPane(target, direction) catch |err| return stateError(alloc, req.id, err);

    const body = try std.fmt.allocPrint(alloc, "{{\"split\":true,\"surface_id\":{d}}}", .{new_id});
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn parseDirection(s: []const u8) ?PaneTree.SplitDirection {
    if (eq(s, "left")) return .left;
    if (eq(s, "right")) return .right;
    if (eq(s, "up")) return .up;
    if (eq(s, "down")) return .down;
    return null;
}

fn closePane(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const explicit = optionalIdParam(alloc, req, "surface_id");
    const target = state.resolvePane(explicit) catch |err| return stateError(alloc, req.id, err);
    state.closePane(target) catch |err| return stateError(alloc, req.id, err);
    return protocol.successResponse(alloc, req.id, "{\"closed\":true}");
}

// --- surface.run -------------------------------------------------------

const default_run_timeout_secs: u64 = 30;
const max_run_timeout_secs: u64 = 600;
const run_poll_interval_ms: u64 = 100;

/// Send a command and return what it printed.
///
/// Much simpler than the GUI's version: there is no GTK thread to dispatch
/// each read onto, so this just polls the terminal it already owns.
fn run(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const command = req.getStringParam(alloc, "command") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'command'");
    defer alloc.free(command);

    const timeout_secs: u64 = if (req.getIntParam(alloc, "timeout")) |t|
        @min(toU64(@max(t, 1)) orelse default_run_timeout_secs, max_run_timeout_secs)
    else
        default_run_timeout_secs;

    const prompt = req.getStringParam(alloc, "prompt_pattern");
    defer if (prompt) |p| alloc.free(p);

    const explicit = optionalIdParam(alloc, req, "surface_id");
    const pane_id = state.resolvePane(explicit) catch |err| return stateError(alloc, req.id, err);

    const before = state.readPane(pane_id, alloc, false) catch |err| return stateError(alloc, req.id, err);
    defer alloc.free(before);

    const line = try std.fmt.allocPrint(alloc, "{s}\n", .{command});
    defer alloc.free(line);
    state.writePane(pane_id, line) catch |err| return stateError(alloc, req.id, err);

    var timer = std.time.Timer.start() catch
        return protocol.errorResponse(alloc, req.id, "internal_error", "No monotonic clock");
    const deadline_ns = timeout_secs * std.time.ns_per_s;

    var timed_out = true;
    var after: ?[]const u8 = null;
    defer if (after) |a| alloc.free(a);

    while (timer.read() < deadline_ns) {
        std.Thread.sleep(run_poll_interval_ms * std.time.ns_per_ms);

        const snapshot = state.readPane(pane_id, alloc, false) catch break;
        if (snapshot.len > before.len and endsWithPrompt(snapshot, prompt)) {
            if (after) |a| alloc.free(a);
            after = snapshot;
            timed_out = false;
            break;
        }
        if (after) |a| alloc.free(a);
        after = snapshot;
    }

    const output = if (after) |a| extractOutput(a, before, command) else "";
    const escaped = try jsonEscape(alloc, output);
    defer alloc.free(escaped);

    const body = try std.fmt.allocPrint(alloc,
        \\{{"output":"{s}","timed_out":{s},"surface_id":{d}}}
    , .{ escaped, if (timed_out) "true" else "false", pane_id });
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn endsWithPrompt(text: []const u8, custom: ?[]const u8) bool {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r')) end -= 1;
    if (end == 0) return false;
    var start = end;
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    const last = std.mem.trimRight(u8, text[start..end], " ");
    if (last.len == 0) return false;

    if (custom) |pat| return std.mem.endsWith(u8, last, pat);
    for ([_][]const u8{ "$ ", "# ", "% ", "> ", "$", "#", "%", ">" }) |suffix| {
        if (std.mem.endsWith(u8, last, suffix)) return true;
    }
    return false;
}

/// The lines between the echoed command and the prompt that followed it.
///
/// This is a heuristic and is honest about it. Two things make naive matching
/// fail, and both were observed:
///
///   - the terminal wraps the echoed command at the column limit, so the echo
///     on screen contains newlines the command string does not ("echo sec\nond")
///   - the screen can scroll between the two snapshots, so `before` is not
///     necessarily a prefix of `after`
///
/// The real fix is semantic prompts: shell integration emits OSC 133 marks
/// around the prompt and the command, and the VT engine already parses them, so
/// the daemon could know exactly where output starts and stops instead of
/// guessing. Worth doing when shell integration moves to the daemon.
fn extractOutput(after: []const u8, before: []const u8, command: []const u8) []const u8 {
    // Only look at what is new, tolerating a scroll rather than assuming
    // `before` is a byte prefix of `after`.
    const shared = commonPrefixLen(before, after);
    const tail = after[shared..];

    // Skip the echoed command, comparing while ignoring the line breaks the
    // terminal inserted when it wrapped.
    const rest = skipEcho(tail, command) orelse trimBlank(tail);

    // Drop the trailing prompt line the shell printed after finishing.
    var end = rest.len;
    while (end > 0 and (rest[end - 1] == '\n' or rest[end - 1] == '\r' or rest[end - 1] == ' ')) end -= 1;
    var line_start = end;
    while (line_start > 0 and rest[line_start - 1] != '\n') line_start -= 1;
    if (line_start > 0) end = line_start;

    return trimBlank(rest[0..end]);
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) i += 1;
    return i;
}

/// Find the echoed command in `text` and return what follows it.
///
/// Searches rather than matching a prefix: the new region routinely starts with
/// the prompt the shell printed before echoing, and prompts are arbitrary. CR
/// and LF in `text` are skipped while comparing, so an echo the terminal wrapped
/// at the column limit still matches.
fn skipEcho(text: []const u8, command: []const u8) ?[]const u8 {
    if (command.len == 0) return null;
    var start: usize = 0;
    while (start < text.len) : (start += 1) {
        // Cheap rejection before walking the whole candidate.
        if (text[start] != command[0]) continue;
        if (matchIgnoringBreaks(text, start, command)) |end| return text[end..];
    }
    return null;
}

/// If `command` matches `text` from `start` (ignoring CR/LF in `text`), return
/// the index just past the match.
fn matchIgnoringBreaks(text: []const u8, start: usize, command: []const u8) ?usize {
    var i = start;
    var ci: usize = 0;
    while (i < text.len and ci < command.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\n' or ch == '\r') continue;
        if (ch != command[ci]) return null;
        ci += 1;
    }
    return if (ci == command.len) i else null;
}

fn trimBlank(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \r\n\t");
}

// --- history -----------------------------------------------------------
//
// This queries the archive of *closed* sessions. Searching a pane that is still
// open is a different operation against a different data structure -- the VT
// engine's own scrollback search -- and belongs on surface.*, not here.

fn historyLimit(alloc: Allocator, req: *const protocol.Request) usize {
    const raw = req.getIntParam(alloc, "limit") orelse return default_history_limit;
    const v = toU64(raw) orelse return default_history_limit;
    return @min(@max(v, 1), max_history_limit);
}

fn entriesResponse(alloc: Allocator, id: i64, entries: []const History.Entry) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"entries\":[");
    for (entries, 0..) |e, i| {
        if (i > 0) try out.append(alloc, ',');
        const title = try jsonEscape(alloc, e.workspace_title);
        defer alloc.free(title);
        const cwd = try jsonEscape(alloc, e.cwd);
        defer alloc.free(cwd);
        const reason = try jsonEscape(alloc, e.reason);
        defer alloc.free(reason);
        const json = try std.fmt.allocPrint(alloc,
            \\{{"id":{d},"workspace_id":{d},"workspace_title":"{s}","pane_id":{d},"closed_at":{d},"cwd":"{s}","reason":"{s}","lines":{d},"bytes":{d}}}
        , .{ e.id, e.workspace_id, title, e.pane_id, e.closed_at, cwd, reason, e.lines, e.bytes });
        defer alloc.free(json);
        try out.appendSlice(alloc, json);
    }
    try out.appendSlice(alloc, "]}");
    return protocol.successResponse(alloc, id, out.items);
}

fn noArchive(alloc: Allocator, id: i64) ![]const u8 {
    return protocol.errorResponse(alloc, id, "no_archive", "Session archive unavailable");
}

/// History ids here are integers, but amux-cli sends them as strings because the
/// GUI's file-based store used `{timestamp}_ws{n}_p{n}` names. Accept either
/// while both stores exist; the string form goes away with item 6.
fn historyIdParam(alloc: Allocator, req: *const protocol.Request) ?i64 {
    if (req.getIntParam(alloc, "id")) |v| return v;
    const text = req.getStringParam(alloc, "id") orelse return null;
    defer alloc.free(text);
    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn historyList(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const hist = state.history orelse return noArchive(alloc, req.id);
    const workspace_id = optionalIdParam(alloc, req, "workspace_id");

    const entries = hist.list(alloc, workspace_id, historyLimit(alloc, req)) catch |err|
        return stateError(alloc, req.id, err);
    defer History.freeEntries(alloc, entries);
    return entriesResponse(alloc, req.id, entries);
}

fn historySearch(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const hist = state.history orelse return noArchive(alloc, req.id);
    const query = req.getStringParam(alloc, "query") orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'query'");
    defer alloc.free(query);

    const entries = hist.search(alloc, query, historyLimit(alloc, req)) catch |err|
        return stateError(alloc, req.id, err);
    defer History.freeEntries(alloc, entries);
    return entriesResponse(alloc, req.id, entries);
}

fn historyShow(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const hist = state.history orelse return noArchive(alloc, req.id);
    const raw = historyIdParam(alloc, req) orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires a numeric 'id'");

    const found = hist.get(alloc, raw) catch |err| return stateError(alloc, req.id, err);
    const content = found orelse
        return protocol.errorResponse(alloc, req.id, "not_found", "No such session");
    defer alloc.free(content);

    const escaped = try jsonEscape(alloc, content);
    defer alloc.free(escaped);
    const body = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"text\":\"{s}\"}}", .{ raw, escaped });
    defer alloc.free(body);
    return protocol.successResponse(alloc, req.id, body);
}

fn historyDelete(alloc: Allocator, state: *State, req: *const protocol.Request) ![]const u8 {
    const hist = state.history orelse return noArchive(alloc, req.id);
    const raw = historyIdParam(alloc, req) orelse
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires a numeric 'id'");

    const removed = hist.delete(raw) catch |err| return stateError(alloc, req.id, err);
    if (!removed) return protocol.errorResponse(alloc, req.id, "not_found", "No such session");
    return protocol.successResponse(alloc, req.id, "{\"deleted\":true}");
}
