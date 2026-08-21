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
}

pub fn selectWorkspace(self: *State, ws_id: u64) Error!void {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.tab_manager.findById(ws_id) == null) return error.WorkspaceNotFound;
    self.tab_manager.selectById(ws_id);
}

pub fn renameWorkspace(self: *State, ws_id: ?u64, title: []const u8) Error!u64 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const ws = try self.resolveWorkspaceLocked(ws_id);
    ws.setTitle(title);
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

test "writes and reads reach the addressed pane" {
    const alloc = std.testing.allocator;
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
