const std = @import("std");
const c = @import("c.zig");
const App = @import("app.zig");
const TerminalWidget = @import("terminal_widget.zig");
const PaneTree = @import("pane_tree.zig");
const TabManager = @import("tab_manager.zig");
const Workspace = @import("workspace.zig");
const Sidebar = @import("sidebar.zig");
const CommandPalette = @import("command_palette.zig");
const SearchOverlay = @import("search_overlay.zig");
const session = @import("session.zig");

const log = std.log.scoped(.window);

const Window = @This();

const Allocator = std.mem.Allocator;

/// The GTK application window.
gtk_window: *c.GtkApplicationWindow,

/// The Ghostty app reference.
app: *App,

/// The workspace manager.
tab_manager: TabManager,

/// Map from PaneTree NodeId to the terminal widget for that pane.
pane_widgets: std.AutoHashMap(PaneTree.NodeId, *TerminalWidget),

/// Map from PaneTree NodeId to the GTK widget representing that node.
/// For pane nodes: the terminal's GtkWidget.
/// For split nodes: a GtkPaned widget.
node_widgets: std.AutoHashMap(PaneTree.NodeId, *c.GtkWidget),

/// GtkStack that holds per-workspace container boxes.  Switching the
/// visible child preserves GL contexts (and therefore Ghostty surfaces)
/// because GtkStack keeps non-visible children realized.
content_stack: *c.GtkStack,

/// Per-workspace wrapper boxes inside the stack, keyed by workspace ID.
workspace_boxes: std.AutoHashMap(Workspace.WorkspaceId, *c.GtkBox),

/// The workspace sidebar.
sidebar: *Sidebar,

/// Whether the sidebar is currently visible.
sidebar_visible: bool = true,

/// The command palette overlay.
command_palette: *CommandPalette,

/// The terminal search overlay.
search_overlay: *SearchOverlay,

/// Allocator
alloc: Allocator,

/// Create a new application window with workspace support.
pub fn create(gtk_app: *c.GtkApplication, app: *App) !*Window {
    const alloc = std.heap.c_allocator;

    // Create the application window
    const gtk_window: *c.GtkApplicationWindow = @ptrCast(
        c.gtk_application_window_new(gtk_app) orelse
            return error.WindowCreateFailed,
    );

    c.gtk_window_set_title(@ptrCast(gtk_window), "cmux");
    c.gtk_window_set_default_size(@ptrCast(gtk_window), 1100, 700);

    // Create the main layout: horizontal paned with sidebar on left + content on right
    const main_paned: *c.GtkPaned = @ptrCast(c.gtk_paned_new(c.GTK_ORIENTATION_HORIZONTAL));
    c.gtk_widget_set_hexpand(@as(*c.GtkWidget, @ptrCast(@alignCast(main_paned))), 1);
    c.gtk_widget_set_vexpand(@as(*c.GtkWidget, @ptrCast(@alignCast(main_paned))), 1);
    c.gtk_paned_set_resize_start_child(main_paned, 0); // sidebar stays fixed on window resize
    c.gtk_paned_set_resize_end_child(main_paned, 1); // terminal gets extra space
    c.gtk_paned_set_shrink_start_child(main_paned, 0);
    c.gtk_paned_set_shrink_end_child(main_paned, 0);

    // GtkStack content area — keeps all workspace widget trees alive
    const content_stack: *c.GtkStack = @ptrCast(@alignCast(c.gtk_stack_new()));
    c.gtk_stack_set_transition_type(content_stack, c.GTK_STACK_TRANSITION_TYPE_NONE);
    c.gtk_widget_set_hexpand(@as(*c.GtkWidget, @ptrCast(@alignCast(content_stack))), 1);
    c.gtk_widget_set_vexpand(@as(*c.GtkWidget, @ptrCast(@alignCast(content_stack))), 1);

    var self = try alloc.create(Window);
    self.* = .{
        .gtk_window = gtk_window,
        .app = app,
        .tab_manager = TabManager.init(alloc),
        .pane_widgets = std.AutoHashMap(PaneTree.NodeId, *TerminalWidget).init(alloc),
        .node_widgets = std.AutoHashMap(PaneTree.NodeId, *c.GtkWidget).init(alloc),
        .content_stack = content_stack,
        .workspace_boxes = std.AutoHashMap(Workspace.WorkspaceId, *c.GtkBox).init(alloc),
        .sidebar = undefined, // will be set below
        .command_palette = undefined, // will be set below
        .search_overlay = undefined, // will be set below
        .alloc = alloc,
    };

    // Create the sidebar
    const sidebar = try Sidebar.create(alloc, &self.tab_manager);
    sidebar.setSelectCallback(onSidebarSelect, @ptrCast(self));
    self.sidebar = sidebar;

    // Layout: sidebar | content (paned provides draggable divider)
    c.gtk_paned_set_start_child(main_paned, sidebar.widget());
    c.gtk_paned_set_end_child(main_paned, @as(*c.GtkWidget, @ptrCast(@alignCast(content_stack))));
    c.gtk_paned_set_position(main_paned, 200);

    // Wrap in overlay for command palette + search overlay
    const overlay: *c.GtkOverlay = @ptrCast(@alignCast(c.gtk_overlay_new()));
    c.gtk_overlay_set_child(overlay, @as(*c.GtkWidget, @ptrCast(@alignCast(main_paned))));

    // Create command palette and add as overlay
    const palette = try CommandPalette.create(alloc, self);
    self.command_palette = palette;
    c.gtk_overlay_add_overlay(overlay, palette.widget());

    // Create search overlay and add as overlay
    const search = try SearchOverlay.create(alloc);
    search.window = self;
    self.search_overlay = search;
    c.gtk_overlay_add_overlay(overlay, search.widget());

    c.gtk_window_set_child(@ptrCast(gtk_window), @as(*c.GtkWidget, @ptrCast(@alignCast(overlay))));

    // Create the first workspace with a single terminal pane
    const ws = try self.tab_manager.createWorkspace();
    try self.buildWorkspaceWidgets(ws);
    self.showWorkspaceInStack(ws.id);

    // Update sidebar to reflect the new workspace
    self.sidebar.rebuild();

    // Show the window
    c.gtk_window_present(@ptrCast(gtk_window));

    // Focus the first terminal
    if (ws.pane_tree.focused_pane) |pane_id| {
        if (self.pane_widgets.get(pane_id)) |tw| {
            _ = c.gtk_widget_grab_focus(tw.widget());
        }
    }

    log.info("Window created with sidebar", .{});

    return self;
}

/// Create a window and restore state from a session snapshot.
pub fn createFromSession(gtk_app: *c.GtkApplication, app: *App, snap: *const session.SessionSnapshot) !*Window {
    const alloc = std.heap.c_allocator;

    // Create the application window (same setup as create)
    const gtk_window: *c.GtkApplicationWindow = @ptrCast(
        c.gtk_application_window_new(gtk_app) orelse
            return error.WindowCreateFailed,
    );

    c.gtk_window_set_title(@ptrCast(gtk_window), "cmux");
    c.gtk_window_set_default_size(@ptrCast(gtk_window), 1100, 700);

    const main_paned: *c.GtkPaned = @ptrCast(c.gtk_paned_new(c.GTK_ORIENTATION_HORIZONTAL));
    c.gtk_widget_set_hexpand(@as(*c.GtkWidget, @ptrCast(@alignCast(main_paned))), 1);
    c.gtk_widget_set_vexpand(@as(*c.GtkWidget, @ptrCast(@alignCast(main_paned))), 1);
    c.gtk_paned_set_resize_start_child(main_paned, 0);
    c.gtk_paned_set_resize_end_child(main_paned, 1);
    c.gtk_paned_set_shrink_start_child(main_paned, 0);
    c.gtk_paned_set_shrink_end_child(main_paned, 0);

    const content_stack: *c.GtkStack = @ptrCast(@alignCast(c.gtk_stack_new()));
    c.gtk_stack_set_transition_type(content_stack, c.GTK_STACK_TRANSITION_TYPE_NONE);
    c.gtk_widget_set_hexpand(@as(*c.GtkWidget, @ptrCast(@alignCast(content_stack))), 1);
    c.gtk_widget_set_vexpand(@as(*c.GtkWidget, @ptrCast(@alignCast(content_stack))), 1);

    var self = try alloc.create(Window);
    self.* = .{
        .gtk_window = gtk_window,
        .app = app,
        .tab_manager = TabManager.init(alloc),
        .pane_widgets = std.AutoHashMap(PaneTree.NodeId, *TerminalWidget).init(alloc),
        .node_widgets = std.AutoHashMap(PaneTree.NodeId, *c.GtkWidget).init(alloc),
        .content_stack = content_stack,
        .workspace_boxes = std.AutoHashMap(Workspace.WorkspaceId, *c.GtkBox).init(alloc),
        .sidebar = undefined,
        .command_palette = undefined,
        .search_overlay = undefined,
        .alloc = alloc,
    };

    const sidebar = try Sidebar.create(alloc, &self.tab_manager);
    sidebar.setSelectCallback(onSidebarSelect, @ptrCast(self));
    self.sidebar = sidebar;

    c.gtk_paned_set_start_child(main_paned, sidebar.widget());
    c.gtk_paned_set_end_child(main_paned, @as(*c.GtkWidget, @ptrCast(@alignCast(content_stack))));
    c.gtk_paned_set_position(main_paned, 200);

    // Wrap in overlay for command palette + search overlay
    const overlay: *c.GtkOverlay = @ptrCast(@alignCast(c.gtk_overlay_new()));
    c.gtk_overlay_set_child(overlay, @as(*c.GtkWidget, @ptrCast(@alignCast(main_paned))));

    const palette = try CommandPalette.create(alloc, self);
    self.command_palette = palette;
    c.gtk_overlay_add_overlay(overlay, palette.widget());

    const search = try SearchOverlay.create(alloc);
    search.window = self;
    self.search_overlay = search;
    c.gtk_overlay_add_overlay(overlay, search.widget());

    c.gtk_window_set_child(@ptrCast(gtk_window), @as(*c.GtkWidget, @ptrCast(@alignCast(overlay))));

    // Restore workspaces from snapshot
    if (snap.workspaces.len == 0) {
        // No workspaces in snapshot — create a default one
        const ws = try self.tab_manager.createWorkspace();
        try self.buildWorkspaceWidgets(ws);
        self.showWorkspaceInStack(ws.id);
    } else {
        // First pass: find the max next_node_id across all workspaces
        // so the shared counter starts high enough.
        var max_node_id: PaneTree.NodeId = 1;
        for (snap.workspaces) |*ws_snap| {
            if (ws_snap.next_node_id > max_node_id) {
                max_node_id = ws_snap.next_node_id;
            }
        }
        self.tab_manager.next_node_id = max_node_id;

        for (snap.workspaces) |*ws_snap| {
            const ws = try alloc.create(Workspace);
            ws.* = Workspace.initShared(alloc, ws_snap.id, &self.tab_manager.next_node_id);
            ws.setTitle(ws_snap.title);
            if (ws_snap.cwd.len > 0) ws.setCwd(ws_snap.cwd);
            ws.pinned = ws_snap.pinned;
            if (ws_snap.color.len > 0) ws.setColor(ws_snap.color);

            // Restore pane tree layout
            _ = session.restorePaneTree(&ws.pane_tree, ws_snap) catch |err| {
                log.warn("Failed to restore pane tree for workspace {d}: {}", .{ ws_snap.id, err });
                // Fall back to a fresh root pane
                _ = ws.pane_tree.createRoot() catch {};
            };

            try self.tab_manager.workspaces.append(alloc, ws);
        }

        // Restore tab manager state
        self.tab_manager.next_id = snap.next_workspace_id;
        self.tab_manager.selected_index = if (snap.selected_workspace_index) |idx|
            if (idx < self.tab_manager.workspaces.items.len) idx else 0
        else
            0;

        // Build widgets for the selected workspace only (others are lazily built)
        if (self.tab_manager.selectedWorkspace()) |ws| {
            try self.buildWorkspaceWidgets(ws);
            self.showWorkspaceInStack(ws.id);
        }
    }

    self.sidebar.rebuild();
    c.gtk_window_present(@ptrCast(gtk_window));

    // Focus the first terminal in the selected workspace
    if (self.tab_manager.selectedWorkspace()) |ws| {
        if (ws.pane_tree.focused_pane) |pane_id| {
            if (self.pane_widgets.get(pane_id)) |tw| {
                _ = c.gtk_widget_grab_focus(tw.widget());
            }
        }
    }

    log.info("Window created from session ({d} workspaces)", .{snap.workspaces.len});
    return self;
}

pub fn deinit(self: *Window) void {
    // Clean up terminal widgets
    var it = self.pane_widgets.valueIterator();
    while (it.next()) |tw| {
        tw.*.deinit();
    }
    self.pane_widgets.deinit();
    self.node_widgets.deinit();
    self.workspace_boxes.deinit();
    self.search_overlay.deinit();
    self.command_palette.deinit();
    self.sidebar.deinit();
    self.tab_manager.deinit();
    self.alloc.destroy(self);
}

// ------------------------------------------------------------------
// Widget tree building
// ------------------------------------------------------------------

/// Build the GTK widget tree for a workspace and add it to the content stack.
/// Each workspace gets its own wrapper GtkBox inside the GtkStack so that
/// switching workspaces is just a visibility toggle (no unrealize/realize).
fn buildWorkspaceWidgets(self: *Window, ws: *Workspace) !void {
    if (ws.pane_tree.root) |root_id| {
        const root_widget = try self.buildNodeWidget(ws, root_id);
        const box = try self.getOrCreateWorkspaceBox(ws);
        c.gtk_box_append(box, root_widget);
    }
}

/// Get (or create) the per-workspace wrapper box inside the content stack.
fn getOrCreateWorkspaceBox(self: *Window, ws: *Workspace) !*c.GtkBox {
    if (self.workspace_boxes.get(ws.id)) |box| return box;

    const box: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0));
    c.gtk_widget_set_hexpand(@as(*c.GtkWidget, @ptrCast(box)), 1);
    c.gtk_widget_set_vexpand(@as(*c.GtkWidget, @ptrCast(box)), 1);

    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buf, "ws-{d}", .{ws.id}) catch return error.FormatError;
    _ = c.gtk_stack_add_named(self.content_stack, @as(*c.GtkWidget, @ptrCast(box)), name.ptr);

    try self.workspace_boxes.put(ws.id, box);
    return box;
}

/// Format a workspace ID into a stack child name.
fn wsStackName(buf: *[32]u8, ws_id: Workspace.WorkspaceId) [*:0]const u8 {
    const s = std.fmt.bufPrintZ(buf, "ws-{d}", .{ws_id}) catch "ws-0";
    return s.ptr;
}

/// Show a workspace's box in the content stack.
fn showWorkspaceInStack(self: *Window, ws_id: Workspace.WorkspaceId) void {
    var name_buf: [32]u8 = undefined;
    const name = wsStackName(&name_buf, ws_id);
    c.gtk_stack_set_visible_child_name(self.content_stack, name);
}

/// Queue a GL render on every terminal in a workspace.  Needed after
/// a GtkStack visibility switch — GTK keeps hidden children realized
/// but does not repaint them when they become visible again.
fn queueRenderForWorkspace(self: *Window, ws: *Workspace) void {
    var it = ws.pane_tree.nodes.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .pane => {
                if (self.pane_widgets.get(entry.key_ptr.*)) |tw| {
                    tw.queueRender();
                }
            },
            .split => {},
        }
    }
}

/// Recursively build GTK widgets for a tree node.
/// Reuses existing TerminalWidgets when available (e.g. after break/join).
fn buildNodeWidget(self: *Window, ws: *Workspace, node_id: PaneTree.NodeId) !*c.GtkWidget {
    const node = ws.pane_tree.getNode(node_id) orelse return error.InvalidTree;

    switch (node) {
        .pane => {
            // Reuse existing terminal widget if available (break/join case)
            if (self.pane_widgets.get(node_id)) |tw| {
                const widget = tw.widget();
                tw.workspace_id = ws.id;
                try self.node_widgets.put(node_id, widget);
                return widget;
            }

            // Create a new terminal widget for this pane
            const main_mod = @import("main.zig");
            const sock_path: ?[*:0]const u8 = if (main_mod.global_server) |srv| srv.getSocketPathZ() else null;
            const tw = try TerminalWidget.create(self.app, ws.getCwd(), node_id, ws.id, sock_path);
            try self.pane_widgets.put(node_id, tw);
            const widget = tw.widget();
            try self.node_widgets.put(node_id, widget);
            return widget;
        },
        .split => |s| {
            const orientation: c_uint = switch (s.orientation) {
                .horizontal => c.GTK_ORIENTATION_HORIZONTAL,
                .vertical => c.GTK_ORIENTATION_VERTICAL,
            };

            const paned: *c.GtkPaned = @ptrCast(c.gtk_paned_new(orientation));
            const paned_widget: *c.GtkWidget = @ptrCast(@alignCast(paned));

            // Allow both children to resize
            c.gtk_paned_set_resize_start_child(paned, 1);
            c.gtk_paned_set_resize_end_child(paned, 1);
            c.gtk_paned_set_shrink_start_child(paned, 0);
            c.gtk_paned_set_shrink_end_child(paned, 0);

            c.gtk_widget_set_hexpand(paned_widget, 1);
            c.gtk_widget_set_vexpand(paned_widget, 1);

            const first_widget = try self.buildNodeWidget(ws, s.first);
            const second_widget = try self.buildNodeWidget(ws, s.second);

            c.gtk_paned_set_start_child(paned, first_widget);
            c.gtk_paned_set_end_child(paned, second_widget);

            // Defer divider positioning until the widget has a real allocation.
            setDividerOnRealize(paned, s.divider_position, s.orientation) catch {};

            try self.node_widgets.put(node_id, paned_widget);
            return paned_widget;
        },
    }
}

// ------------------------------------------------------------------
// Divider positioning
// ------------------------------------------------------------------

/// Context for deferred divider positioning on GtkPaned realize.
const DividerData = struct {
    paned: *c.GtkPaned,
    position: f64,
    orientation: PaneTree.Orientation,
};

/// Schedule proportional divider positioning after the GtkPaned is realized.
fn setDividerOnRealize(paned: *c.GtkPaned, position: f64, orientation: PaneTree.Orientation) !void {
    const alloc = std.heap.c_allocator;
    const data = try alloc.create(DividerData);
    data.* = .{
        .paned = paned,
        .position = position,
        .orientation = orientation,
    };
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(paned)),
        "realize",
        @as(c.GCallback, @ptrCast(&onPanedRealize)),
        @ptrCast(data),
        null,
        0,
    );
}

fn onPanedRealize(_: *c.GtkWidget, userdata: c.gpointer) callconv(.c) void {
    const data: *DividerData = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(data);

    const widget: *c.GtkWidget = @ptrCast(@alignCast(data.paned));
    const size: f64 = switch (data.orientation) {
        .horizontal => @floatFromInt(c.gtk_widget_get_width(widget)),
        .vertical => @floatFromInt(c.gtk_widget_get_height(widget)),
    };

    if (size > 0) {
        c.gtk_paned_set_position(data.paned, @intFromFloat(data.position * size));
    }
}

// ------------------------------------------------------------------
// Split operations
// ------------------------------------------------------------------

/// Split the focused pane in the given direction.
pub fn splitFocused(self: *Window, direction: PaneTree.SplitDirection) !void {
    const ws = self.tab_manager.selectedWorkspace() orelse return;
    const focused = ws.pane_tree.focused_pane orelse return;

    // Get the current widget for the focused pane
    const old_widget = self.node_widgets.get(focused) orelse return;

    // Perform the tree split
    const new_pane_id = try ws.pane_tree.split(focused, direction);

    // Now we need to update the GTK widget tree:
    // The old pane is now a child of a new split node.
    // Find the split node that is the parent of both.
    const pane_node = ws.pane_tree.getNode(focused) orelse return;
    const split_id = switch (pane_node) {
        .pane => |p| p.parent orelse return,
        else => return,
    };
    const split_node = ws.pane_tree.getNode(split_id) orelse return;
    const s = switch (split_node) {
        .split => |sp| sp,
        else => return,
    };

    // Create a new terminal widget for the new pane, inheriting workspace cwd
    const main_mod = @import("main.zig");
    const sock_path: ?[*:0]const u8 = if (main_mod.global_server) |srv| srv.getSocketPathZ() else null;
    const new_tw = try TerminalWidget.create(self.app, ws.getCwd(), new_pane_id, ws.id, sock_path);
    try self.pane_widgets.put(new_pane_id, new_tw);
    try self.node_widgets.put(new_pane_id, new_tw.widget());

    // Create a GtkPaned for the new split
    const orientation: c_uint = switch (s.orientation) {
        .horizontal => c.GTK_ORIENTATION_HORIZONTAL,
        .vertical => c.GTK_ORIENTATION_VERTICAL,
    };

    const paned: *c.GtkPaned = @ptrCast(c.gtk_paned_new(orientation));
    const paned_widget: *c.GtkWidget = @ptrCast(@alignCast(paned));

    c.gtk_paned_set_resize_start_child(paned, 1);
    c.gtk_paned_set_resize_end_child(paned, 1);
    c.gtk_paned_set_shrink_start_child(paned, 0);
    c.gtk_paned_set_shrink_end_child(paned, 0);
    c.gtk_widget_set_hexpand(paned_widget, 1);
    c.gtk_widget_set_vexpand(paned_widget, 1);

    // Determine child order
    const first_widget: *c.GtkWidget = if (s.first == focused) old_widget else new_tw.widget();
    const second_widget: *c.GtkWidget = if (s.second == focused) old_widget else new_tw.widget();

    // We need to remove old_widget from its current parent first.
    // Find the old parent widget and replace old_widget with the paned.
    const grandparent_id = s.parent;
    if (grandparent_id) |gid| {
        if (self.node_widgets.get(gid)) |gp_widget| {
            // It's a GtkPaned — replace the appropriate child
            const gp_paned: *c.GtkPaned = @ptrCast(gp_widget);
            // Unparent old_widget by setting start/end to null
            // then set the paned as the replacement
            // GTK4: setting a new child automatically unparents the old one
            c.gtk_paned_set_start_child(gp_paned, null);
            c.gtk_paned_set_end_child(gp_paned, null);

            // Re-read the grandparent split to determine which side
            const gp_node = ws.pane_tree.getNode(gid);
            if (gp_node) |gpn| {
                switch (gpn) {
                    .split => |gps| {
                        // Rebuild the grandparent's children
                        const gp_first = self.node_widgets.get(gps.first);
                        const gp_second = self.node_widgets.get(gps.second);
                        if (gp_first) |fw| c.gtk_paned_set_start_child(gp_paned, fw);
                        if (gp_second) |sw| c.gtk_paned_set_end_child(gp_paned, sw);
                    },
                    else => {},
                }
            }
        }
    } else {
        // Root level — swap inside the workspace's container box
        if (self.workspace_boxes.get(ws.id)) |ws_box| {
            c.gtk_box_remove(ws_box, old_widget);
            c.gtk_box_append(ws_box, paned_widget);
        }
    }

    // Now set the children of the new paned
    c.gtk_paned_set_start_child(paned, first_widget);
    c.gtk_paned_set_end_child(paned, second_widget);

    // Set 50/50 divider position after realization
    setDividerOnRealize(paned, 0.5, s.orientation) catch {};

    try self.node_widgets.put(split_id, paned_widget);

    // Focus the new terminal
    _ = c.gtk_widget_grab_focus(new_tw.widget());

    self.sidebar.rebuild();
    log.info("Split created: pane {d} -> new pane {d}", .{ focused, new_pane_id });
}

/// Close the focused pane.
pub fn closeFocused(self: *Window) !void {
    const ws = self.tab_manager.selectedWorkspace() orelse return;
    const focused = ws.pane_tree.focused_pane orelse return;

    // Can't close the last pane
    if (ws.pane_tree.paneCount() <= 1) return;

    // Get the terminal widget for cleanup
    const tw = self.pane_widgets.get(focused) orelse return;

    // Get parent info before closing
    const pane_node = ws.pane_tree.getNode(focused) orelse return;
    const parent_id = switch (pane_node) {
        .pane => |p| p.parent,
        else => return,
    };

    // Get the parent split info to identify sibling
    const parent_split = if (parent_id) |pid| ws.pane_tree.getNode(pid) else null;
    const sibling_id = if (parent_split) |ps| switch (ps) {
        .split => |s| if (s.first == focused) s.second else s.first,
        else => null,
    } else null;
    const grandparent_id = if (parent_split) |ps| switch (ps) {
        .split => |s| s.parent,
        else => null,
    } else null;

    // Perform the tree close
    _ = try ws.pane_tree.close(focused);

    // Update GTK widgets
    // The sibling should replace the parent split's widget
    if (parent_id) |pid| {
        const parent_widget = self.node_widgets.get(pid);
        const sibling_widget = if (sibling_id) |sid| self.node_widgets.get(sid) else null;

        if (parent_widget != null and sibling_widget != null) {
            // Unparent sibling from the old paned
            const parent_paned: *c.GtkPaned = @ptrCast(parent_widget.?);
            c.gtk_paned_set_start_child(parent_paned, null);
            c.gtk_paned_set_end_child(parent_paned, null);

            if (grandparent_id) |gid| {
                if (self.node_widgets.get(gid)) |gp_widget| {
                    const gp_paned: *c.GtkPaned = @ptrCast(gp_widget);
                    // Replace parent_widget with sibling_widget in grandparent
                    c.gtk_paned_set_start_child(gp_paned, null);
                    c.gtk_paned_set_end_child(gp_paned, null);

                    // Re-read the grandparent to set correct children
                    if (ws.pane_tree.getNode(gid)) |gpn| {
                        switch (gpn) {
                            .split => |gps| {
                                const gp_first = self.node_widgets.get(gps.first);
                                const gp_second = self.node_widgets.get(gps.second);
                                if (gp_first) |fw| c.gtk_paned_set_start_child(gp_paned, fw);
                                if (gp_second) |sw| c.gtk_paned_set_end_child(gp_paned, sw);
                            },
                            else => {},
                        }
                    }
                }
            } else {
                // Root level — swap inside the workspace's container box
                if (self.workspace_boxes.get(ws.id)) |ws_box| {
                    c.gtk_box_remove(ws_box, parent_widget.?);
                    c.gtk_box_append(ws_box, sibling_widget.?);
                }
            }
        }

        _ = self.node_widgets.remove(pid);
    }

    // Clean up the closed pane
    _ = self.pane_widgets.remove(focused);
    _ = self.node_widgets.remove(focused);
    tw.deinit();

    // Focus the next pane
    if (ws.pane_tree.focused_pane) |new_focus| {
        if (self.pane_widgets.get(new_focus)) |new_tw| {
            _ = c.gtk_widget_grab_focus(new_tw.widget());
        }
    }

    self.sidebar.rebuild();
    log.info("Pane {d} closed", .{focused});
}

// ------------------------------------------------------------------
// Workspace operations
// ------------------------------------------------------------------

/// Create a new workspace and switch to it.
pub fn createWorkspace(self: *Window) !void {
    const ws = try self.tab_manager.createWorkspace();
    self.tab_manager.selectIndex(self.tab_manager.workspaces.items.len - 1);

    try self.buildWorkspaceWidgets(ws);
    self.showWorkspaceInStack(ws.id);

    // Update sidebar
    self.sidebar.rebuild();

    if (ws.pane_tree.focused_pane) |pane_id| {
        if (self.pane_widgets.get(pane_id)) |tw| {
            _ = c.gtk_widget_grab_focus(tw.widget());
        }
    }
}

/// Switch to a workspace by index.
pub fn switchWorkspace(self: *Window, index: usize) !void {
    if (self.tab_manager.selected_index) |sel| {
        if (sel == index) return;
    }

    self.tab_manager.selectIndex(index);

    if (self.tab_manager.selectedWorkspace()) |ws| {
        // Build widgets lazily on first visit (e.g. session restore)
        if (!self.workspace_boxes.contains(ws.id)) {
            try self.buildWorkspaceWidgets(ws);
        }

        // Flip the stack's visible child — no unrealize cascade
        self.showWorkspaceInStack(ws.id);

        // Queue a render on all terminals in this workspace so they
        // repaint after becoming visible again.  GtkStack keeps hidden
        // children realized but GTK won't automatically redraw them
        // when they reappear.
        self.queueRenderForWorkspace(ws);

        // Sync sidebar selection before focusing terminal, so GTK's
        // listbox selection handling doesn't steal focus back.
        self.sidebar.syncSelection();

        // Focus the workspace's focused pane
        if (ws.pane_tree.focused_pane) |pane_id| {
            if (self.pane_widgets.get(pane_id)) |tw| {
                _ = c.gtk_widget_grab_focus(tw.widget());
            }
        }
    }
}

/// Toggle sidebar visibility.
pub fn toggleSidebar(self: *Window) void {
    self.sidebar_visible = !self.sidebar_visible;
    c.gtk_widget_set_visible(self.sidebar.widget(), if (self.sidebar_visible) 1 else 0);
}

/// Toggle the command palette.
pub fn toggleCommandPalette(self: *Window) void {
    self.command_palette.toggle();
}

/// Show the terminal search overlay.
pub fn showSearch(self: *Window) void {
    // Get the focused terminal surface
    const ws = self.tab_manager.selectedWorkspace() orelse return;
    const focused = ws.pane_tree.focused_pane orelse return;
    const tw = self.pane_widgets.get(focused) orelse return;
    self.search_overlay.show(tw.surface);
}

/// Hide the terminal search overlay.
pub fn hideSearch(self: *Window) void {
    self.search_overlay.hide();
}

/// Return keyboard focus to the focused terminal pane.
pub fn focusCurrentTerminal(self: *Window) void {
    const ws = self.tab_manager.selectedWorkspace() orelse return;
    const pane_id = ws.pane_tree.focused_pane orelse return;
    const tw = self.pane_widgets.get(pane_id) orelse return;
    _ = c.gtk_widget_grab_focus(tw.widget());
}

/// Break a pane out into a new workspace.
pub fn breakPaneToNewWorkspace(self: *Window, pane_id: PaneTree.NodeId) !void {
    const ws = self.tab_manager.selectedWorkspace() orelse return;

    // Can't break the only pane
    if (ws.pane_tree.paneCount() <= 1) return error.LastPane;

    // Detach from the current tree (promotes sibling)
    _ = try ws.pane_tree.detachPane(pane_id);

    // Rebuild the current workspace's GTK widget tree
    try self.rebuildCurrentWorkspace();

    // Create a new workspace with shared node ID counter
    const alloc = self.alloc;
    const new_ws = try alloc.create(Workspace);
    new_ws.* = Workspace.initShared(alloc, self.tab_manager.next_id, &self.tab_manager.next_node_id);
    self.tab_manager.next_id += 1;

    // Attach the pane to the new workspace's tree
    try new_ws.pane_tree.attachPaneAsRoot(pane_id);
    try self.tab_manager.workspaces.append(alloc, new_ws);

    // Update the terminal widget's workspace ID
    if (self.pane_widgets.get(pane_id)) |tw| {
        tw.workspace_id = new_ws.id;
    }

    // Rebuild sidebar
    self.sidebar.rebuild();

    log.info("Pane {d} broken to new workspace {d}", .{ pane_id, new_ws.id });
}

/// Join (move) a pane from any workspace to the target workspace.
pub fn joinPaneToWorkspace(self: *Window, pane_id: PaneTree.NodeId, target_ws_id: Workspace.WorkspaceId) !void {
    // Find source workspace that contains this pane
    var src_ws: ?*Workspace = null;
    for (self.tab_manager.workspaces.items) |ws_item| {
        if (ws_item.pane_tree.getNode(pane_id) != null) {
            src_ws = ws_item;
            break;
        }
    }
    const source = src_ws orelse return error.PaneNotFound;

    // Find target workspace
    var target_ws: ?*Workspace = null;
    for (self.tab_manager.workspaces.items) |ws_item| {
        if (ws_item.id == target_ws_id) {
            target_ws = ws_item;
            break;
        }
    }
    const target = target_ws orelse return error.WorkspaceNotFound;
    if (source.id == target.id) return error.SameWorkspace;

    const source_is_last_pane = source.pane_tree.paneCount() <= 1;

    if (source_is_last_pane) {
        // Last pane — clear the source tree root instead of detaching
        source.pane_tree.root = null;
    } else {
        // Detach from source tree (sibling promotion)
        _ = try source.pane_tree.detachPane(pane_id);
    }

    // Attach to target tree
    if (target.pane_tree.root) |root_id| {
        // Split the existing root to accommodate this pane
        const new_split_id = target.pane_tree.nextNodeId();
        try target.pane_tree.nodes.put(new_split_id, .{ .split = .{
            .id = new_split_id,
            .parent = null,
            .orientation = .horizontal,
            .divider_position = 0.5,
            .first = root_id,
            .second = pane_id,
        } });

        // Update old root's parent
        var root_node = target.pane_tree.nodes.get(root_id) orelse return error.InvalidTree;
        switch (root_node) {
            .pane => |*p| p.parent = new_split_id,
            .split => |*s| s.parent = new_split_id,
        }
        try target.pane_tree.nodes.put(root_id, root_node);

        // Add the pane to target tree
        try target.pane_tree.nodes.put(pane_id, .{ .pane = .{
            .id = pane_id,
            .parent = new_split_id,
        } });

        target.pane_tree.root = new_split_id;
        target.pane_tree.setNextId(pane_id + 1);
    } else {
        try target.pane_tree.attachPaneAsRoot(pane_id);
    }

    // Update the terminal's workspace ID
    if (self.pane_widgets.get(pane_id)) |tw| {
        tw.workspace_id = target.id;
    }

    // If the source workspace is now empty, close it
    if (source_is_last_pane) {
        const source_id = source.id;
        _ = self.closeWorkspaceById(source_id);
    }

    // Rebuild current workspace if source is selected
    try self.rebuildCurrentWorkspace();

    self.sidebar.rebuild();
    log.info("Pane {d} joined to workspace {d}", .{ pane_id, target.id });
}

/// Switch to the next workspace.
pub fn nextWorkspace(self: *Window) void {
    const idx = self.tab_manager.selected_index orelse return;
    if (idx + 1 < self.tab_manager.workspaces.items.len) {
        self.switchWorkspace(idx + 1) catch |err| {
            log.warn("Failed to switch to next workspace: {}", .{err});
        };
    }
}

/// Switch to the previous workspace.
pub fn previousWorkspace(self: *Window) void {
    const idx = self.tab_manager.selected_index orelse return;
    if (idx > 0) {
        self.switchWorkspace(idx - 1) catch |err| {
            log.warn("Failed to switch to previous workspace: {}", .{err});
        };
    }
}

/// Remove a workspace's widget tree from the content stack entirely.
/// Only used when a workspace is being closed/deleted.
fn removeWorkspaceFromStack(self: *Window, ws_id: Workspace.WorkspaceId) void {
    if (self.workspace_boxes.get(ws_id)) |box| {
        c.gtk_stack_remove(self.content_stack, @as(*c.GtkWidget, @ptrCast(box)));
        _ = self.workspace_boxes.remove(ws_id);
    }
}

/// Close the currently selected workspace.
pub fn closeCurrentWorkspace(self: *Window) void {
    const ws = self.tab_manager.selectedWorkspace() orelse return;
    // Don't close the last workspace
    if (self.tab_manager.workspaces.items.len <= 1) return;
    _ = self.closeWorkspaceById(ws.id);
    self.sidebar.rebuild();
}

/// Switch to the last (most recently used) workspace.
pub fn lastWorkspace(self: *Window) void {
    const old_index = self.tab_manager.selected_index orelse return;
    self.tab_manager.selectLast();
    const new_index = self.tab_manager.selected_index orelse return;
    if (old_index != new_index) {
        self.switchWorkspace(new_index) catch |err| {
            log.warn("Failed to switch to last workspace: {}", .{err});
        };
    }
}

/// Close a workspace by ID, cleaning up its widget tree from the stack.
pub fn closeWorkspaceById(self: *Window, ws_id: Workspace.WorkspaceId) bool {
    self.removeWorkspaceFromStack(ws_id);
    const closed = self.tab_manager.closeWorkspaceById(ws_id);
    if (closed) {
        // If the selected workspace was closed, show the new selection
        if (self.tab_manager.selectedWorkspace()) |ws| {
            if (!self.workspace_boxes.contains(ws.id)) {
                self.buildWorkspaceWidgets(ws) catch {};
            }
            self.showWorkspaceInStack(ws.id);
        }
    }
    return closed;
}

/// Close a workspace by index, cleaning up its widget tree from the stack.
pub fn closeWorkspaceByIndex(self: *Window, index: usize) bool {
    // Get the workspace ID before closing so we can clean up the stack
    if (index < self.tab_manager.workspaces.items.len) {
        const ws_id = self.tab_manager.workspaces.items[index].id;
        self.removeWorkspaceFromStack(ws_id);
    }
    const closed = self.tab_manager.closeWorkspace(index);
    if (closed) {
        if (self.tab_manager.selectedWorkspace()) |ws| {
            if (!self.workspace_boxes.contains(ws.id)) {
                self.buildWorkspaceWidgets(ws) catch {};
            }
            self.showWorkspaceInStack(ws.id);
        }
    }
    return closed;
}

/// Sync GtkPaned positions to match the pane tree's divider_position values.
/// Called after pane.resize to reflect data model changes in GTK widgets.
pub fn syncDividerPositions(self: *Window, ws: *Workspace) void {
    if (ws.pane_tree.root) |root_id| {
        self.syncNodeDivider(ws, root_id);
    }
}

fn syncNodeDivider(self: *Window, ws: *Workspace, node_id: PaneTree.NodeId) void {
    const node = ws.pane_tree.getNode(node_id) orelse return;
    switch (node) {
        .pane => {},
        .split => |s| {
            if (self.node_widgets.get(node_id)) |widget| {
                const paned: *c.GtkPaned = @ptrCast(widget);
                const w: *c.GtkWidget = @ptrCast(@alignCast(paned));
                const size: f64 = switch (s.orientation) {
                    .horizontal => @floatFromInt(c.gtk_widget_get_width(w)),
                    .vertical => @floatFromInt(c.gtk_widget_get_height(w)),
                };
                if (size > 0) {
                    c.gtk_paned_set_position(paned, @intFromFloat(s.divider_position * size));
                }
            }
            self.syncNodeDivider(ws, s.first);
            self.syncNodeDivider(ws, s.second);
        },
    }
}

/// Rebuild the GTK widget tree for the current workspace, reusing existing
/// TerminalWidget instances. Used after pane.swap to reflect new layout.
pub fn rebuildCurrentWorkspace(self: *Window) !void {
    const ws = self.tab_manager.selectedWorkspace() orelse return;
    const ws_box = self.workspace_boxes.get(ws.id) orelse return;

    // Remove ALL direct children of the workspace box.
    // After detachPane/sibling promotion, the data model's root may differ
    // from what's actually in the box, so we can't rely on node_widgets
    // to find the right widget to remove.
    const box_widget: *c.GtkWidget = @ptrCast(@alignCast(ws_box));
    var child = c.gtk_widget_get_first_child(box_widget);
    while (child != null) {
        const next = c.gtk_widget_get_next_sibling(child);
        c.gtk_box_remove(ws_box, child);
        child = next;
    }

    // Clear split node widgets (pane widgets are retained)
    var to_remove: std.ArrayListUnmanaged(PaneTree.NodeId) = .{};
    defer to_remove.deinit(self.alloc);
    var it = self.node_widgets.iterator();
    while (it.next()) |entry| {
        // Only remove split node entries, keep pane entries
        if (self.pane_widgets.get(entry.key_ptr.*) == null) {
            try to_remove.append(self.alloc, entry.key_ptr.*);
        }
    }
    for (to_remove.items) |id| {
        _ = self.node_widgets.remove(id);
    }

    // Rebuild from the tree using existing terminal widgets
    if (ws.pane_tree.root) |root_id| {
        const root_widget = try self.rebuildNodeFromExisting(ws, root_id);
        c.gtk_box_append(ws_box, root_widget);
    }
}

/// Recursively build GTK widgets from a pane tree, reusing existing TerminalWidgets.
fn rebuildNodeFromExisting(self: *Window, ws: *Workspace, node_id: PaneTree.NodeId) !*c.GtkWidget {
    const node = ws.pane_tree.getNode(node_id) orelse return error.InvalidTree;

    switch (node) {
        .pane => {
            // Reuse existing terminal widget
            const tw = self.pane_widgets.get(node_id) orelse return error.MissingWidget;
            const widget = tw.widget();
            // Unparent if it has a parent (from old tree)
            safeUnparent(widget);
            try self.node_widgets.put(node_id, widget);
            return widget;
        },
        .split => |s| {
            const orientation: c_uint = switch (s.orientation) {
                .horizontal => c.GTK_ORIENTATION_HORIZONTAL,
                .vertical => c.GTK_ORIENTATION_VERTICAL,
            };

            const paned: *c.GtkPaned = @ptrCast(c.gtk_paned_new(orientation));
            const paned_widget: *c.GtkWidget = @ptrCast(@alignCast(paned));

            c.gtk_paned_set_resize_start_child(paned, 1);
            c.gtk_paned_set_resize_end_child(paned, 1);
            c.gtk_paned_set_shrink_start_child(paned, 0);
            c.gtk_paned_set_shrink_end_child(paned, 0);
            c.gtk_widget_set_hexpand(paned_widget, 1);
            c.gtk_widget_set_vexpand(paned_widget, 1);

            const first_widget = try self.rebuildNodeFromExisting(ws, s.first);
            const second_widget = try self.rebuildNodeFromExisting(ws, s.second);

            c.gtk_paned_set_start_child(paned, first_widget);
            c.gtk_paned_set_end_child(paned, second_widget);

            setDividerOnRealize(paned, s.divider_position, s.orientation) catch {};

            try self.node_widgets.put(node_id, paned_widget);
            return paned_widget;
        },
    }
}

/// Safely unparent a widget from whatever container it's in.
/// Handles GtkPaned (clears child slot), GtkBox (gtk_box_remove),
/// and unknown parents (skips to avoid GTK-CRITICAL assertions).
fn safeUnparent(widget: *c.GtkWidget) void {
    const parent = c.gtk_widget_get_parent(widget) orelse return;
    // Check if parent is a GtkPaned by comparing type
    const paned_type = c.gtk_paned_get_type();
    const box_type = c.gtk_box_get_type();
    const parent_obj: *c.GTypeInstance = @ptrCast(parent);
    const parent_type = parent_obj.g_class.*.g_type;
    if (c.g_type_is_a(parent_type, paned_type) != 0) {
        const parent_paned: *c.GtkPaned = @ptrCast(parent);
        if (c.gtk_paned_get_start_child(parent_paned) == widget) {
            c.gtk_paned_set_start_child(parent_paned, null);
        } else if (c.gtk_paned_get_end_child(parent_paned) == widget) {
            c.gtk_paned_set_end_child(parent_paned, null);
        }
    } else if (c.g_type_is_a(parent_type, box_type) != 0) {
        c.gtk_box_remove(@ptrCast(parent), widget);
    }
    // For any other parent type, skip — don't risk invalid casts
}

// ------------------------------------------------------------------
// Focus navigation
// ------------------------------------------------------------------

/// Navigate focus in the given direction.
pub fn navigateFocus(self: *Window, direction: PaneTree.SplitDirection) void {
    const ws = self.tab_manager.selectedWorkspace() orelse return;
    const focused = ws.pane_tree.focused_pane orelse return;

    if (ws.pane_tree.navigate(focused, direction)) |target_pane| {
        ws.pane_tree.focused_pane = target_pane;
        if (self.pane_widgets.get(target_pane)) |tw| {
            _ = c.gtk_widget_grab_focus(tw.widget());
        }
    }
}

// ------------------------------------------------------------------
// Sidebar callback
// ------------------------------------------------------------------

fn onSidebarSelect(index: usize, userdata: ?*anyopaque) void {
    const self: *Window = @ptrCast(@alignCast(userdata orelse return));
    self.switchWorkspace(index) catch |err| {
        log.warn("Failed to switch workspace: {}", .{err});
    };
}
