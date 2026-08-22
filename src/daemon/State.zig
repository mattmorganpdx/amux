//! Everything the daemon owns: workspaces, their pane trees, and the live
//! terminals behind each pane.
//!
//! The model types come across from the GUI unchanged -- `TabManager`,
//! `Workspace` and `PaneTree` never depended on GTK, which is what makes this
//! move cheap. What stays behind in `window.zig` is only the widget mirror.
//!
//! One lock guards the whole model. Requests are short and this is a
//! single-user tool; a finer-grained scheme would buy contention we do not have
//! and reintroduce the ordering hazards the GUI just finished paying off.

const std = @import("std");
const Allocator = std.mem.Allocator;

const PaneTree = @import("../pane_tree.zig");
const History = @import("History.zig");
const Registry = @import("Registry.zig");
const Notifications = @import("notifications.zig");
const TabManager = @import("../tab_manager.zig");
const Workspace = @import("../workspace.zig");
const session = @import("../session.zig");
const Pane = @import("Pane.zig");

const State = @This();

const log = std.log.scoped(.state);

/// Fixed terminal geometry. Settled decision: this is a single-user tool, so
/// there is no client size negotiation to do.
pub const default_cols: u16 = 80;
pub const default_rows: u16 = 24;

alloc: Allocator,
mutex: std.Thread.Mutex = .{},
tab_manager: TabManager,
registry: Registry,

/// Session archive. Scrollback is captured here when a pane goes away, which is
/// the only moment it still exists: the terminal owns it, and closing the pane
/// destroys it. Optional so tests can run without touching a database.
history: ?*History = null,

/// Injected into every pane as AMUX_SOCKET_PATH, so `amux-cli` run from inside
/// a pane reaches the daemon that owns it without any configuration. Set by
/// amuxd before serving; tests leave it null.
socket_path: ?[]const u8 = null,

/// Bumped whenever the shape of things changes: a workspace or pane appearing,
/// disappearing, being renamed or being selected.
///
/// A GUI showing the daemon's layout has to learn about changes it did not
/// make -- an agent splitting a pane from the CLI is the normal case here, not
/// an edge one. A counter lets it ask "anything since N?" without the daemon
/// tracking who is watching, the same way the screen protocol works.
layout_seq: u64 = 1,

/// Recent notification records. See `notifications.zig` for why the daemon
/// keeps these rather than showing them.
notifications: Notifications = .{},

/// Bumped by metadata writes: status, progress, logs, git, colour, pinning.
///
/// Separate from `layout_seq` on purpose. A client following the layout rebuilds
/// its widget tree when it changes, and an agent reporting progress once a second
/// would have it doing that once a second. Metadata is not layout, so it gets its
/// own number and a client can follow it without touching a single widget.
meta_seq: u64 = 1,
meta_changed: std.Thread.Condition = .{},
layout_changed: std.Thread.Condition = .{},

pub const Error = error{
    WorkspaceNotFound,
    PaneNotFound,
    LastPane,
    NoWorkspace,
};

pub fn init(alloc: Allocator) State {
    return .{
        .alloc = alloc,
        .tab_manager = TabManager.init(alloc),
        .registry = Registry.init(alloc),
    };
}

pub fn deinit(self: *State) void {
    self.registry.deinit();
    self.tab_manager.deinit();
}

// --- Workspaces ---------------------------------------------------------

/// Create a workspace with one pane, and select it.
pub fn createWorkspace(self: *State, title: ?[]const u8, cwd: ?[]const u8) !u64 {
    self.mutex.lock();
    defer self.mutex.unlock();

    const ws = try self.tab_manager.createWorkspace();
    errdefer _ = self.tab_manager.closeWorkspaceById(ws.id);

    if (title) |t| ws.setTitle(t);
    if (cwd) |c| ws.setCwd(c);

    // TabManager.createWorkspace already made the root pane. Creating another
    // leaves the first orphaned in `nodes`, and `PaneTree.paneCount` counts
    // every pane node rather than only the reachable ones, so the workspace
    // would report one pane more than it has.
    const pane_id = ws.pane_tree.focused_pane orelse return error.PaneNotFound;
    try self.spawnPaneLocked(pane_id, ws);

    self.tab_manager.selectById(ws.id);
    self.bumpLayoutLocked();
    return ws.id;
}

pub fn closeWorkspace(self: *State, ws_id: u64) Error!void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const ws = self.tab_manager.findById(ws_id) orelse return error.WorkspaceNotFound;

    // Terminals first, while the tree still names them.
    var ids = ws.pane_tree.orderedPaneIds(self.alloc) catch return error.WorkspaceNotFound;
    defer ids.deinit(self.alloc);
    for (ids.items) |pane_id| {
        self.archivePaneLocked(pane_id, ws, "workspace_close");
        self.registry.close(pane_id) catch {};
    }

    _ = self.tab_manager.closeWorkspaceById(ws_id);
    self.bumpLayoutLocked();
}

pub fn selectWorkspace(self: *State, ws_id: u64) Error!void {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.tab_manager.findById(ws_id) == null) return error.WorkspaceNotFound;
    self.tab_manager.selectById(ws_id);
    self.bumpLayoutLocked();
}

pub fn renameWorkspace(self: *State, ws_id: ?u64, title: []const u8) Error!u64 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const ws = try self.resolveWorkspaceLocked(ws_id);
    ws.setTitle(title);
    self.bumpLayoutLocked();
    return ws.id;
}

pub fn selectedWorkspaceId(self: *State) ?u64 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const ws = self.tab_manager.selectedWorkspace() orelse return null;
    return ws.id;
}

pub fn workspaceCount(self: *State) usize {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.tab_manager.count();
}

// --- Panes -------------------------------------------------------------

/// Split `pane_id`, spawning a terminal for the new pane. Returns its id.
pub fn splitPane(self: *State, pane_id: u64, direction: PaneTree.SplitDirection) !u64 {
    self.mutex.lock();
    defer self.mutex.unlock();

    const ws = self.findPaneWorkspaceLocked(pane_id) orelse return error.PaneNotFound;
    const new_id = try ws.pane_tree.split(pane_id, direction);
    errdefer _ = ws.pane_tree.close(new_id) catch {};

    try self.spawnPaneLocked(new_id, ws);
    self.bumpLayoutLocked();
    return new_id;
}

/// Close a pane. Refuses the last pane in a workspace: closing that is
/// `closeWorkspace`, which is a different intent.
pub fn closePane(self: *State, pane_id: u64) Error!void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const ws = self.findPaneWorkspaceLocked(pane_id) orelse return error.PaneNotFound;
    if (ws.pane_tree.paneCount() <= 1) return error.LastPane;

    self.archivePaneLocked(pane_id, ws, "pane_close");
    _ = ws.pane_tree.close(pane_id) catch return error.PaneNotFound;
    self.registry.close(pane_id) catch {};
    self.bumpLayoutLocked();
}

pub fn writePane(self: *State, pane_id: ?u64, bytes: []const u8) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    const id = try self.resolvePaneLocked(pane_id);
    try self.registry.write(id, bytes);
}

/// Caller owns the returned text.
pub fn readPane(self: *State, pane_id: ?u64, alloc: Allocator, scrollback: bool) ![]const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const id = try self.resolvePaneLocked(pane_id);
    return if (scrollback)
        self.registry.snapshotScrollback(id, alloc)
    else
        self.registry.snapshot(id, alloc);
}

/// The focused pane of the selected workspace, or `explicit` if given.
/// Serialize a pane's screen, optionally waiting for it to change.
///
/// Deliberately does *not* take the state lock. This blocks for as long as the
/// caller's timeout, and holding the state lock that long would stall every
/// other request in the daemon. Nothing here reads what that lock protects --
/// the pane tree and workspace list are untouched, and the registry has its own
/// lock. Resolve the id with `resolvePane` first, which does take it.
pub fn paneScreen(
    self: *State,
    pane_id: u64,
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    opts: Registry.ScreenOptions,
) !?u64 {
    return self.registry.screen(pane_id, alloc, out, opts);
}

/// Raw output for a relay. Like `paneScreen`, deliberately without the state
/// lock: it blocks, and nothing it touches is what that lock protects.
pub fn paneOutput(
    self: *State,
    pane_id: u64,
    alloc: Allocator,
    from: ?u64,
    timeout_ms: u32,
) !?Registry.OutputResult {
    return self.registry.output(pane_id, alloc, from, timeout_ms);
}

/// Note a structural change. Caller holds `mutex`.
fn bumpLayoutLocked(self: *State) void {
    self.layout_seq += 1;
    self.layout_changed.broadcast();
}

/// The current layout as the same JSON `session.zig` writes to disk.
///
/// Reusing that format is what lets the GUI restore from the daemon with the
/// code it already had for restoring from a file -- including preserving pane
/// node ids, which is what makes the GUI's pane ids and the daemon's the same
/// numbers.
pub fn layoutJson(self: *State, alloc: Allocator, since: u64, timeout_ms: u32) !?struct { seq: u64, json: []const u8 } {
    const total_ns = @as(u64, timeout_ms) * std.time.ns_per_ms;
    var timer: ?std.time.Timer = std.time.Timer.start() catch null;

    self.mutex.lock();
    defer self.mutex.unlock();

    while (true) {
        if (self.layout_seq != since) {
            var snap = try session.captureSession(alloc, &self.tab_manager);
            defer session.freeSessionSnapshot(alloc, &snap);
            const json = try session.serializeSession(alloc, &snap);
            return .{ .seq = self.layout_seq, .json = json };
        }
        const elapsed = if (timer) |*t| t.read() else total_ns;
        if (elapsed >= total_ns) return null;
        const slice = @min(total_ns - elapsed, 250 * std.time.ns_per_ms);
        self.layout_changed.timedWait(&self.mutex, slice) catch {};
    }
}

/// Release clients blocked in a wait. Called on the way out, before teardown.
pub fn stopWaiters(self: *State) void {
    self.registry.stopWaiters();
}

/// Resize a pane's terminal and its pty.
///
/// The attached client drives this: it knows how big its window is, and a
/// mismatch shows up immediately as a picture painted for the wrong width.
pub fn resizePane(self: *State, pane_id: u64, cols: u16, rows: u16) !void {
    return self.registry.resize(pane_id, cols, rows);
}

// ------------------------------------------------------------------
// Workspace metadata
//
// The fields live on `Workspace`, which the GUI and the daemon share, so this is
// only about who owns the writes. The daemon does, because an agent reporting
// progress should not need a window open to be heard -- which was the whole
// reason these methods existed only in the GUI before.
//
// Deliberately *not* bumping `layout_seq`: a progress update every second would
// have an attached GUI rebuilding its widget tree every second. Metadata is not
// layout.
// ------------------------------------------------------------------

/// Run `f` against a workspace under the state lock.
fn withWorkspaceLocked(
    self: *State,
    ws_id: ?u64,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *Workspace) void,
) Error!u64 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const ws = try self.resolveWorkspaceLocked(ws_id);
    f(ctx, ws);
    self.meta_seq += 1;
    self.meta_changed.broadcast();
    return ws.id;
}

pub fn setWorkspaceStatus(self: *State, ws_id: ?u64, key: []const u8, value: []const u8) Error!u64 {
    const Ctx = struct { key: []const u8, value: []const u8 };
    return self.withWorkspaceLocked(ws_id, Ctx{ .key = key, .value = value }, struct {
        fn apply(ctx: Ctx, ws: *Workspace) void {
            ws.setStatusEntry(ctx.key, ctx.value);
        }
    }.apply);
}

pub fn clearWorkspaceStatus(self: *State, ws_id: ?u64) Error!u64 {
    return self.withWorkspaceLocked(ws_id, {}, struct {
        fn apply(_: void, ws: *Workspace) void {
            ws.clearStatus();
        }
    }.apply);
}

pub fn addWorkspaceLog(self: *State, ws_id: ?u64, text: []const u8) Error!u64 {
    return self.withWorkspaceLocked(ws_id, text, struct {
        fn apply(t: []const u8, ws: *Workspace) void {
            ws.addLogEntry(t);
        }
    }.apply);
}

pub fn clearWorkspaceLog(self: *State, ws_id: ?u64) Error!u64 {
    return self.withWorkspaceLocked(ws_id, {}, struct {
        fn apply(_: void, ws: *Workspace) void {
            ws.clearLog();
        }
    }.apply);
}

pub fn setWorkspaceProgress(self: *State, ws_id: ?u64, fraction: f32, label: ?[]const u8) Error!u64 {
    const Ctx = struct { fraction: f32, label: ?[]const u8 };
    return self.withWorkspaceLocked(ws_id, Ctx{ .fraction = fraction, .label = label }, struct {
        fn apply(ctx: Ctx, ws: *Workspace) void {
            ws.setProgress(ctx.fraction, ctx.label);
        }
    }.apply);
}

pub fn reportWorkspaceGit(self: *State, ws_id: ?u64, branch: []const u8, dirty: bool) Error!u64 {
    const Ctx = struct { branch: []const u8, dirty: bool };
    return self.withWorkspaceLocked(ws_id, Ctx{ .branch = branch, .dirty = dirty }, struct {
        fn apply(ctx: Ctx, ws: *Workspace) void {
            ws.setGitBranch(ctx.branch);
            ws.setGitDirty(ctx.dirty);
        }
    }.apply);
}

pub fn setWorkspaceColor(self: *State, ws_id: ?u64, color: []const u8) Error!u64 {
    return self.withWorkspaceLocked(ws_id, color, struct {
        fn apply(name: []const u8, ws: *Workspace) void {
            if (name.len == 0) ws.clearColor() else ws.setColor(name);
        }
    }.apply);
}

pub fn setWorkspacePinned(self: *State, ws_id: ?u64, pinned: bool) Error!u64 {
    return self.withWorkspaceLocked(ws_id, pinned, struct {
        fn apply(p: bool, ws: *Workspace) void {
            ws.pinned = p;
        }
    }.apply);
}

/// Wait until the metadata sequence differs from `since`, and return it.
///
/// Null means the wait timed out with nothing to report. Mirrors `layoutJson`,
/// but returns only the number: the caller reads the workspaces afterwards, so
/// the wait does not hold the state lock across serialization.
pub fn waitForMeta(self: *State, since: u64, timeout_ms: u32) ?u64 {
    const total_ns = @as(u64, timeout_ms) * std.time.ns_per_ms;
    var timer: ?std.time.Timer = std.time.Timer.start() catch null;

    self.mutex.lock();
    defer self.mutex.unlock();

    while (true) {
        if (self.meta_seq != since) return self.meta_seq;
        const elapsed = if (timer) |*t| t.read() else total_ns;
        if (elapsed >= total_ns) return null;
        const slice = @min(total_ns - elapsed, 250 * std.time.ns_per_ms);
        self.meta_changed.timedWait(&self.mutex, slice) catch {};
    }
}

pub fn resolvePane(self: *State, explicit: ?u64) Error!u64 {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.resolvePaneLocked(explicit);
}

pub const PaneInfo = struct {
    id: u64,
    workspace_id: u64,
    focused: bool,
    exited: bool,
};

/// Every pane across every workspace. Caller owns the slice.
pub fn listPanes(self: *State, alloc: Allocator) ![]PaneInfo {
    self.mutex.lock();
    defer self.mutex.unlock();

    var out: std.ArrayListUnmanaged(PaneInfo) = .{};
    errdefer out.deinit(alloc);

    for (self.tab_manager.workspaces.items) |ws| {
        var ids = try ws.pane_tree.orderedPaneIds(self.alloc);
        defer ids.deinit(self.alloc);
        for (ids.items) |pane_id| {
            try out.append(alloc, .{
                .id = pane_id,
                .workspace_id = ws.id,
                .focused = if (ws.pane_tree.focused_pane) |fp| fp == pane_id else false,
                .exited = self.registry.hasExited(pane_id) catch true,
            });
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Run `fn_` against each workspace while the lock is held. The callback must
/// not call back into State.
pub fn withWorkspaces(
    self: *State,
    ctx: anytype,
    comptime fn_: fn (@TypeOf(ctx), *Workspace, bool, usize) anyerror!void,
) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    const selected = self.tab_manager.selected_index;
    for (self.tab_manager.workspaces.items, 0..) |ws, i| {
        try fn_(ctx, ws, if (selected) |s| s == i else false, i);
    }
}

/// Run `fn_` against one workspace while the lock is held.
pub fn withWorkspace(
    self: *State,
    ws_id: ?u64,
    ctx: anytype,
    comptime fn_: fn (@TypeOf(ctx), *Workspace, bool, usize) anyerror!void,
) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    const ws = try self.resolveWorkspaceLocked(ws_id);
    const index = for (self.tab_manager.workspaces.items, 0..) |w, i| {
        if (w.id == ws.id) break i;
    } else 0;
    const selected = if (self.tab_manager.selected_index) |s| s == index else false;
    try fn_(ctx, ws, selected, index);
}

// --- Session ----------------------------------------------------------

/// Persist workspaces and layout. Terminal contents are not part of this;
/// scrollback persistence is item 8.
pub fn saveSession(self: *State) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const snap = try session.captureSession(self.alloc, &self.tab_manager);
    defer session.freeSessionSnapshot(self.alloc, &snap);
    try session.writeSessionFile(self.alloc, &snap);
}

/// Restore workspaces and layout, spawning a terminal per restored pane.
/// Returns the number of workspaces restored.
pub fn restoreSession(self: *State) !usize {
    if (session.isRestoreDisabled()) return 0;

    self.mutex.lock();
    defer self.mutex.unlock();

    var snap = session.loadSessionFile(self.alloc) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer session.freeSessionSnapshot(self.alloc, &snap);

    for (snap.workspaces) |ws_snap| {
        const ws = try self.tab_manager.createWorkspace();
        if (ws_snap.title.len > 0) ws.setTitle(ws_snap.title);
        if (ws_snap.cwd.len > 0) ws.setCwd(ws_snap.cwd);
        if (ws_snap.color.len > 0) ws.setColor(ws_snap.color);
        ws.pinned = ws_snap.pinned;

        // Drop the auto-created root before rebuilding the saved layout, or it
        // lingers unreachable in `nodes` and inflates paneCount.
        ws.pane_tree.nodes.clearRetainingCapacity();
        ws.pane_tree.root = null;
        ws.pane_tree.focused_pane = null;

        const root = session.restorePaneTree(&ws.pane_tree, &ws_snap) catch null;
        if (root == null) {
            // A layout we could not rebuild still gets a usable pane.
            const pane_id = try ws.pane_tree.createRoot();
            try self.spawnPaneLocked(pane_id, ws);
            continue;
        }

        var ids = try ws.pane_tree.orderedPaneIds(self.alloc);
        defer ids.deinit(self.alloc);
        for (ids.items) |pane_id| try self.spawnPaneLocked(pane_id, ws);
    }

    if (snap.selected_workspace_index) |i| self.tab_manager.selectIndex(i);
    self.bumpLayoutLocked();
    log.info("restored {d} workspace(s)", .{snap.workspaces.len});
    return snap.workspaces.len;
}

/// Archive every live pane. Called on the way out, so a session that was never
/// closed by hand is still recoverable.
pub fn archiveAll(self: *State, reason: []const u8) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.tab_manager.workspaces.items) |ws| {
        var ids = ws.pane_tree.orderedPaneIds(self.alloc) catch continue;
        defer ids.deinit(self.alloc);
        for (ids.items) |pane_id| self.archivePaneLocked(pane_id, ws, reason);
    }
}

// --- Internals (call with the lock held) -------------------------------

/// Capture a pane's scrollback into the archive. Best-effort: losing history is
/// not a reason to fail closing a pane.
fn archivePaneLocked(self: *State, pane_id: u64, ws: *Workspace, reason: []const u8) void {
    const hist = self.history orelse return;

    const content = self.registry.snapshotScrollback(pane_id, self.alloc) catch |err| {
        log.debug("pane {d}: no scrollback to archive ({})", .{ pane_id, err });
        return;
    };
    defer self.alloc.free(content);

    const cwd: []const u8 = if (ws.cwd_len > 0) ws.cwd_buf[0..ws.cwd_len] else "";
    _ = hist.record(.{
        .workspace_id = ws.id,
        .workspace_title = ws.getTitle(),
        .pane_id = pane_id,
        .cwd = cwd,
        .reason = reason,
        .content = content,
    }) catch |err| log.warn("could not archive pane {d}: {}", .{ pane_id, err });
}

fn spawnPaneLocked(self: *State, pane_id: u64, ws: *Workspace) !void {
    var ws_buf: [24]u8 = undefined;
    var pane_buf: [24]u8 = undefined;
    const ws_env = try std.fmt.bufPrint(&ws_buf, "AMUX_WORKSPACE_ID={d}", .{ws.id});
    const pane_env = try std.fmt.bufPrint(&pane_buf, "AMUX_SURFACE_ID={d}", .{pane_id});

    const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
    const cwd: ?[]const u8 = if (ws.cwd_len > 0) ws.cwd_buf[0..ws.cwd_len] else null;

    var sock_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    var env_buf: [4][]const u8 = undefined;
    var env_len: usize = 3;
    env_buf[0] = "TERM=xterm-256color";
    env_buf[1] = ws_env;
    env_buf[2] = pane_env;
    if (self.socket_path) |sp| {
        env_buf[3] = try std.fmt.bufPrint(&sock_buf, "AMUX_SOCKET_PATH={s}", .{sp});
        env_len = 4;
    }

    try self.registry.open(pane_id, .{
        .argv = &.{shell},
        .env = env_buf[0..env_len],
        .cwd = cwd,
        .cols = default_cols,
        .rows = default_rows,
    });
}

fn resolveWorkspaceLocked(self: *State, ws_id: ?u64) Error!*Workspace {
    if (ws_id) |id| return self.tab_manager.findById(id) orelse error.WorkspaceNotFound;
    return self.tab_manager.selectedWorkspace() orelse error.NoWorkspace;
}

fn resolvePaneLocked(self: *State, explicit: ?u64) Error!u64 {
    if (explicit) |id| {
        if (self.findPaneWorkspaceLocked(id) == null) return error.PaneNotFound;
        return id;
    }
    const ws = self.tab_manager.selectedWorkspace() orelse return error.NoWorkspace;
    return ws.pane_tree.focused_pane orelse error.PaneNotFound;
}

fn findPaneWorkspaceLocked(self: *State, pane_id: u64) ?*Workspace {
    for (self.tab_manager.workspaces.items) |ws| {
        if (ws.pane_tree.getNode(pane_id) != null) return ws;
    }
    return null;
}

test "a new workspace comes up with exactly one pane" {
    const alloc = std.testing.allocator;
    var state = init(alloc);
    defer state.deinit();

    const ws = try state.createWorkspace("test-ws", null);
    try std.testing.expectEqual(@as(usize, 1), state.workspaceCount());
    try std.testing.expectEqual(@as(?u64, ws), state.selectedWorkspaceId());

    // Regression: TabManager.createWorkspace already makes the root pane, and
    // PaneTree.paneCount counts unreachable nodes too, so creating a second
    // root reported one pane more than existed.
    const panes = try state.listPanes(alloc);
    defer alloc.free(panes);
    try std.testing.expectEqual(@as(usize, 1), panes.len);
    try std.testing.expectEqual(ws, panes[0].workspace_id);
}

test "splitting adds a pane to the same workspace" {
    const alloc = std.testing.allocator;
    var state = init(alloc);
    defer state.deinit();

    const ws = try state.createWorkspace(null, null);
    const first = try state.resolvePane(null);
    const second = try state.splitPane(first, .right);
    try std.testing.expect(first != second);

    const panes = try state.listPanes(alloc);
    defer alloc.free(panes);
    try std.testing.expectEqual(@as(usize, 2), panes.len);
    for (panes) |p| try std.testing.expectEqual(ws, p.workspace_id);
}

test "the last pane in a workspace cannot be closed" {
    const alloc = std.testing.allocator;
    var state = init(alloc);
    defer state.deinit();

    _ = try state.createWorkspace(null, null);
    const only = try state.resolvePane(null);
    try std.testing.expectError(error.LastPane, state.closePane(only));

    const extra = try state.splitPane(only, .down);
    try state.closePane(extra);
    try std.testing.expectError(error.LastPane, state.closePane(only));
}

test "closing a workspace takes its terminals with it" {
    const alloc = std.testing.allocator;
    var state = init(alloc);
    defer state.deinit();

    const a = try state.createWorkspace("a", null);
    const b = try state.createWorkspace("b", null);
    _ = try state.splitPane(try state.resolvePane(null), .right);

    var panes = try state.listPanes(alloc);
    try std.testing.expectEqual(@as(usize, 3), panes.len);
    alloc.free(panes);

    try state.closeWorkspace(b);
    panes = try state.listPanes(alloc);
    defer alloc.free(panes);
    try std.testing.expectEqual(@as(usize, 1), panes.len);
    try std.testing.expectEqual(a, panes[0].workspace_id);
    try std.testing.expectEqual(@as(usize, 1), state.registry.count());
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

test "writes and reads reach the addressed pane" {
    const alloc = std.testing.allocator;

    // Panes spawn `$SHELL`, which is right for the product and wrong for this
    // test: it made the round trip depend on whichever shell the developer uses
    // and whatever their rc does, and a slow rc under load pushed a printf past
    // the poll window. `sh` reads no rc, so what is being tested here -- that a
    // write and a read reach the pane they name -- is what decides the result.
    const saved_shell = std.posix.getenv("SHELL");
    _ = setenv("SHELL", "/bin/sh", 1);
    defer if (saved_shell) |sh| {
        var buf: [512]u8 = undefined;
        if (std.fmt.bufPrintZ(&buf, "{s}", .{sh})) |z| {
            _ = setenv("SHELL", z, 1);
        } else |_| {}
    };

    var state = init(alloc);
    defer state.deinit();

    _ = try state.createWorkspace(null, null);
    const pane = try state.resolvePane(null);
    // The marker is assembled by the command rather than written in it, so it
    // can only appear as *output*. Waiting for two copies -- the shell's echo
    // and the result -- looked equivalent but raced: a write that lands before
    // the shell turns echo on produces one copy and never a second, so the test
    // failed intermittently no matter how long it waited.
    try state.writePane(pane, "printf 'STATE_%s\\n' 'ROUND_TRIP'\n");

    var waited: usize = 0;
    while (waited < 20000) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
        waited += 50;
        const text = try state.readPane(pane, alloc, false);
        defer alloc.free(text);
        if (std.mem.indexOf(u8, text, "STATE_ROUND_TRIP") != null) return;
    }

    // Say what the shell actually did. Reporting only "never saw it" makes this
    // failure unactionable, which cost real time when it turned up on one
    // machine and not another.
    const text = try state.readPane(pane, alloc, false);
    defer alloc.free(text);
    std.debug.print(
        "\nnever saw STATE_ROUND_TRIP; SHELL={s}; screen was:\n{s}\n",
        .{ std.posix.getenv("SHELL") orelse "(unset)", text },
    );
    return error.NeverSawOutput;
}

test "unknown ids are reported, not crashed on" {
    const alloc = std.testing.allocator;
    var state = init(alloc);
    defer state.deinit();

    try std.testing.expectError(error.WorkspaceNotFound, state.closeWorkspace(999));
    try std.testing.expectError(error.WorkspaceNotFound, state.selectWorkspace(999));
    try std.testing.expectError(error.PaneNotFound, state.closePane(999));
    try std.testing.expectError(error.PaneNotFound, state.resolvePane(999));
    // With no workspace at all, resolving the focused pane has nothing to find.
    try std.testing.expectError(error.NoWorkspace, state.resolvePane(null));
}

test "metadata writes advance the metadata sequence but not the layout" {
    const alloc = std.testing.allocator;
    var state = init(alloc);
    defer state.deinit();

    _ = try state.createWorkspace(null, null);

    const layout_before = state.layout_seq;
    const meta_before = state.meta_seq;

    _ = try state.setWorkspaceStatus(null, "task", "building");
    _ = try state.setWorkspaceProgress(null, 0.5, "halfway");
    _ = try state.addWorkspaceLog(null, "a line");
    _ = try state.reportWorkspaceGit(null, "main", true);

    // The whole point of two counters: a client following the layout rebuilds
    // its widget tree when it changes, and an agent reporting progress once a
    // second must not cost that.
    try std.testing.expectEqual(layout_before, state.layout_seq);
    try std.testing.expect(state.meta_seq > meta_before);
}

test "a structural change advances the layout sequence" {
    const alloc = std.testing.allocator;
    var state = init(alloc);
    defer state.deinit();

    const ws = try state.createWorkspace(null, null);
    _ = ws;
    const before = state.layout_seq;

    const pane = try state.resolvePane(null);
    _ = try state.splitPane(pane, .right);

    try std.testing.expect(state.layout_seq > before);
}

test "waiting on metadata reports a change, and reports nothing when there is none" {
    const alloc = std.testing.allocator;
    var state = init(alloc);
    defer state.deinit();

    _ = try state.createWorkspace(null, null);
    const seq = state.meta_seq;

    // Nothing has happened, so a short wait comes back empty rather than
    // inventing an update.
    try std.testing.expect(state.waitForMeta(seq, 150) == null);

    _ = try state.setWorkspaceStatus(null, "task", "moved on");
    const got = state.waitForMeta(seq, 150);
    try std.testing.expect(got != null);
    try std.testing.expect(got.? > seq);
}
