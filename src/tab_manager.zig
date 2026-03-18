const std = @import("std");
const Workspace = @import("workspace.zig");
const PaneTree = @import("pane_tree.zig");

const log = std.log.scoped(.tab_manager);

/// Manages the ordered list of workspaces, selection, and history.
pub const TabManager = @This();

const Allocator = std.mem.Allocator;
const WorkspaceId = Workspace.WorkspaceId;

alloc: Allocator,

/// Ordered list of workspaces.
workspaces: std.ArrayListUnmanaged(*Workspace) = .{},

/// Currently selected workspace index.
selected_index: ?usize = null,

/// History stack for back/forward navigation.
history: std.ArrayListUnmanaged(WorkspaceId) = .{},
history_pos: usize = 0,

/// Next workspace id.
next_id: WorkspaceId = 1,

/// Global node ID counter shared by all PaneTree instances.
/// Ensures node IDs are unique across workspaces so that
/// Window's pane_widgets/node_widgets maps don't collide.
next_node_id: PaneTree.NodeId = 1,

pub fn init(alloc: Allocator) TabManager {
    return .{
        .alloc = alloc,
    };
}

pub fn deinit(self: *TabManager) void {
    for (self.workspaces.items) |ws| {
        ws.deinit();
        self.alloc.destroy(ws);
    }
    self.workspaces.deinit(self.alloc);
    self.history.deinit(self.alloc);
}

/// Create a new workspace and append it to the list.
pub fn createWorkspace(self: *TabManager) !*Workspace {
    const id = self.next_id;
    self.next_id += 1;

    const ws = try self.alloc.create(Workspace);
    ws.* = Workspace.initShared(self.alloc, id, &self.next_node_id);

    // Set a default title
    var buf: [32]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "Workspace {d}", .{id}) catch "Workspace";
    ws.setTitle(title);

    try self.workspaces.append(self.alloc, ws);

    // Create the root pane for this workspace
    _ = try ws.pane_tree.createRoot();

    // Auto-select if this is the first workspace
    if (self.workspaces.items.len == 1) {
        self.selected_index = 0;
    }

    return ws;
}

/// Get the currently selected workspace.
pub fn selectedWorkspace(self: *const TabManager) ?*Workspace {
    const idx = self.selected_index orelse return null;
    if (idx >= self.workspaces.items.len) return null;
    return self.workspaces.items[idx];
}

/// Select a workspace by index.
pub fn selectIndex(self: *TabManager, index: usize) void {
    if (index >= self.workspaces.items.len) return;

    // Push current to history
    if (self.selected_index) |current| {
        if (current != index) {
            const ws = self.workspaces.items[current];
            self.history.append(self.alloc, ws.id) catch {};
            self.history_pos = self.history.items.len;
        }
    }

    self.selected_index = index;
}

/// Select a workspace by id.
pub fn selectById(self: *TabManager, id: WorkspaceId) void {
    for (self.workspaces.items, 0..) |ws, i| {
        if (ws.id == id) {
            self.selectIndex(i);
            return;
        }
    }
}

/// Select the next workspace.
pub fn selectNext(self: *TabManager) void {
    const idx = self.selected_index orelse return;
    if (idx + 1 < self.workspaces.items.len) {
        self.selectIndex(idx + 1);
    }
}

/// Select the previous workspace.
pub fn selectPrevious(self: *TabManager) void {
    const idx = self.selected_index orelse return;
    if (idx > 0) {
        self.selectIndex(idx - 1);
    }
}

/// Select the last workspace in the history.
pub fn selectLast(self: *TabManager) void {
    if (self.history.items.len == 0) return;
    const last_id = self.history.items[self.history.items.len - 1];
    self.selectById(last_id);
}

/// Close a workspace by index. Returns true if closed.
pub fn closeWorkspace(self: *TabManager, index: usize) bool {
    if (index >= self.workspaces.items.len) return false;

    const ws = self.workspaces.orderedRemove(index);
    ws.deinit();
    self.alloc.destroy(ws);

    // Adjust selected index
    if (self.workspaces.items.len == 0) {
        self.selected_index = null;
    } else if (self.selected_index) |sel| {
        if (sel >= self.workspaces.items.len) {
            self.selected_index = self.workspaces.items.len - 1;
        } else if (sel > index) {
            self.selected_index = sel - 1;
        }
    }

    return true;
}

/// Close a workspace by id.
pub fn closeWorkspaceById(self: *TabManager, id: WorkspaceId) bool {
    for (self.workspaces.items, 0..) |ws, i| {
        if (ws.id == id) {
            return self.closeWorkspace(i);
        }
    }
    return false;
}

/// Reorder a workspace from one index to another.
pub fn reorder(self: *TabManager, from: usize, to: usize) void {
    if (from >= self.workspaces.items.len or to >= self.workspaces.items.len) return;
    if (from == to) return;

    const item = self.workspaces.orderedRemove(from);
    self.workspaces.insert(self.alloc, to, item) catch return;

    // Update selected index
    if (self.selected_index) |sel| {
        if (sel == from) {
            self.selected_index = to;
        } else if (from < sel and to >= sel) {
            self.selected_index = sel - 1;
        } else if (from > sel and to <= sel) {
            self.selected_index = sel + 1;
        }
    }
}

/// Find a workspace by id.
pub fn findById(self: *const TabManager, id: WorkspaceId) ?*Workspace {
    for (self.workspaces.items) |ws| {
        if (ws.id == id) return ws;
    }
    return null;
}

/// Get the total number of workspaces.
pub fn count(self: *const TabManager) usize {
    return self.workspaces.items.len;
}
