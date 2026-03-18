const std = @import("std");

const log = std.log.scoped(.pane_tree);

/// A binary split tree for managing terminal pane layouts.
///
/// The tree has two node types:
///  - Leaf nodes represent individual panes (each containing one or more tabs).
///  - Split nodes are internal nodes that divide space between two children.
///
/// Split orientation and a proportional divider position (0.0–1.0) determine
/// how available space is allocated between the first and second child.
pub const PaneTree = @This();

const Allocator = std.mem.Allocator;

/// Unique identifier for tree nodes.
pub const NodeId = u64;

/// Split orientation.
pub const Orientation = enum {
    horizontal, // left / right
    vertical, // top / bottom
};

/// Split direction — used when requesting a new split.
pub const SplitDirection = enum {
    left,
    right,
    up,
    down,

    pub fn toOrientation(self: SplitDirection) Orientation {
        return switch (self) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        };
    }

    /// Returns true if the new pane should be the *second* child.
    pub fn isSecond(self: SplitDirection) bool {
        return switch (self) {
            .right, .down => true,
            .left, .up => false,
        };
    }
};

/// A node in the tree.
pub const Node = union(enum) {
    pane: PaneNode,
    split: SplitNode,
};

/// A leaf node representing a single pane.
pub const PaneNode = struct {
    id: NodeId,
    /// Parent split id, or null if this is the tree root.
    parent: ?NodeId = null,
};

/// An internal split node.
pub const SplitNode = struct {
    id: NodeId,
    parent: ?NodeId = null,
    orientation: Orientation,
    /// Proportional divider position (0.0–1.0).
    divider_position: f64 = 0.5,
    first: NodeId,
    second: NodeId,
};

/// Rectangle for layout calculation.
pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

alloc: Allocator,
nodes: std.AutoHashMap(NodeId, Node),
root: ?NodeId = null,
/// Pointer to a shared counter so node IDs are unique across all workspaces.
/// When null, uses the local `local_next_id` fallback (tests, standalone use).
shared_next_id: ?*NodeId = null,
/// Local counter used when no shared counter is provided.
local_next_id: NodeId = 1,
/// Currently focused pane.
focused_pane: ?NodeId = null,

pub fn init(alloc: Allocator) PaneTree {
    return .{
        .alloc = alloc,
        .nodes = std.AutoHashMap(NodeId, Node).init(alloc),
    };
}

pub fn initShared(alloc: Allocator, shared_next_id: *NodeId) PaneTree {
    return .{
        .alloc = alloc,
        .nodes = std.AutoHashMap(NodeId, Node).init(alloc),
        .shared_next_id = shared_next_id,
    };
}

pub fn deinit(self: *PaneTree) void {
    self.nodes.deinit();
}

// ------------------------------------------------------------------
// Queries
// ------------------------------------------------------------------

pub fn getNode(self: *const PaneTree, id: NodeId) ?Node {
    return self.nodes.get(id);
}

/// Return an ordered list of pane IDs via in-order traversal.
pub fn orderedPaneIds(self: *const PaneTree, alloc: Allocator) !std.ArrayListUnmanaged(NodeId) {
    var list: std.ArrayListUnmanaged(NodeId) = .{};
    if (self.root) |root_id| {
        try self.collectPanes(root_id, &list, alloc);
    }
    return list;
}

fn collectPanes(self: *const PaneTree, node_id: NodeId, list: *std.ArrayListUnmanaged(NodeId), alloc: Allocator) !void {
    const node = self.nodes.get(node_id) orelse return;
    switch (node) {
        .pane => try list.append(alloc, node_id),
        .split => |s| {
            try self.collectPanes(s.first, list, alloc);
            try self.collectPanes(s.second, list, alloc);
        },
    }
}

/// Calculate the layout rectangles for all panes.
pub fn calculateLayout(self: *const PaneTree, alloc: Allocator, bounds: Rect) !std.AutoHashMap(NodeId, Rect) {
    var result = std.AutoHashMap(NodeId, Rect).init(alloc);
    if (self.root) |root_id| {
        try self.layoutNode(root_id, bounds, &result);
    }
    return result;
}

fn layoutNode(self: *const PaneTree, node_id: NodeId, bounds: Rect, result: *std.AutoHashMap(NodeId, Rect)) !void {
    const node = self.nodes.get(node_id) orelse return;
    switch (node) {
        .pane => {
            try result.put(node_id, bounds);
        },
        .split => |s| {
            const d = std.math.clamp(s.divider_position, 0.05, 0.95);
            var first_rect: Rect = undefined;
            var second_rect: Rect = undefined;

            switch (s.orientation) {
                .horizontal => {
                    const w1 = bounds.width * d;
                    first_rect = .{ .x = bounds.x, .y = bounds.y, .width = w1, .height = bounds.height };
                    second_rect = .{ .x = bounds.x + w1, .y = bounds.y, .width = bounds.width - w1, .height = bounds.height };
                },
                .vertical => {
                    const h1 = bounds.height * d;
                    first_rect = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = h1 };
                    second_rect = .{ .x = bounds.x, .y = bounds.y + h1, .width = bounds.width, .height = bounds.height - h1 };
                },
            }

            try self.layoutNode(s.first, first_rect, result);
            try self.layoutNode(s.second, second_rect, result);
        },
    }
}

/// Count the number of panes in the tree.
pub fn paneCount(self: *const PaneTree) usize {
    var count: usize = 0;
    var it = self.nodes.valueIterator();
    while (it.next()) |node| {
        switch (node.*) {
            .pane => count += 1,
            .split => {},
        }
    }
    return count;
}

// ------------------------------------------------------------------
// Mutations
// ------------------------------------------------------------------

pub fn nextNodeId(self: *PaneTree) NodeId {
    if (self.shared_next_id) |ptr| {
        const id = ptr.*;
        ptr.* += 1;
        return id;
    }
    const id = self.local_next_id;
    self.local_next_id += 1;
    return id;
}

/// Get the current next_id value (from shared or local counter).
pub fn getNextId(self: *const PaneTree) NodeId {
    if (self.shared_next_id) |ptr| return ptr.*;
    return self.local_next_id;
}

/// Set the next_id value (updates shared or local counter).
pub fn setNextId(self: *PaneTree, val: NodeId) void {
    if (self.shared_next_id) |ptr| {
        // Only advance the shared counter, never retreat
        if (val > ptr.*) ptr.* = val;
    } else {
        self.local_next_id = val;
    }
}

/// Create the initial root pane. Returns the new pane's id.
pub fn createRoot(self: *PaneTree) !NodeId {
    const id = self.nextNodeId();
    try self.nodes.put(id, .{ .pane = .{ .id = id } });
    self.root = id;
    self.focused_pane = id;
    return id;
}

/// Split a pane in the given direction.
/// Returns the id of the newly created pane.
pub fn split(self: *PaneTree, pane_id: NodeId, direction: SplitDirection) !NodeId {
    const pane_node = self.nodes.get(pane_id) orelse return error.PaneNotFound;
    const parent_id = switch (pane_node) {
        .pane => |p| p.parent,
        else => return error.NotAPane,
    };

    // Create the new pane
    const new_pane_id = self.nextNodeId();
    const split_id = self.nextNodeId();

    // Determine child order
    const first_id = if (direction.isSecond()) pane_id else new_pane_id;
    const second_id = if (direction.isSecond()) new_pane_id else pane_id;

    // Create the split node
    try self.nodes.put(split_id, .{ .split = .{
        .id = split_id,
        .parent = parent_id,
        .orientation = direction.toOrientation(),
        .divider_position = 0.5,
        .first = first_id,
        .second = second_id,
    } });

    // Create the new pane
    try self.nodes.put(new_pane_id, .{ .pane = .{
        .id = new_pane_id,
        .parent = split_id,
    } });

    // Update the existing pane's parent
    try self.nodes.put(pane_id, .{ .pane = .{
        .id = pane_id,
        .parent = split_id,
    } });

    // Update the parent's child pointer to point to the new split
    if (parent_id) |pid| {
        var parent = self.nodes.get(pid) orelse return error.InvalidTree;
        switch (parent) {
            .split => |*s| {
                if (s.first == pane_id) {
                    s.first = split_id;
                } else if (s.second == pane_id) {
                    s.second = split_id;
                }
                try self.nodes.put(pid, .{ .split = s.* });
            },
            else => return error.InvalidTree,
        }
    } else {
        // This was the root
        self.root = split_id;
    }

    self.focused_pane = new_pane_id;
    return new_pane_id;
}

/// Close a pane. The sibling takes the pane's place in the tree.
/// Returns the id of the sibling that was promoted.
pub fn close(self: *PaneTree, pane_id: NodeId) !?NodeId {
    const pane_node = self.nodes.get(pane_id) orelse return error.PaneNotFound;
    const parent_id = switch (pane_node) {
        .pane => |p| p.parent,
        else => return error.NotAPane,
    };

    // Remove the pane
    _ = self.nodes.remove(pane_id);

    if (parent_id == null) {
        // This was the root (only pane)
        self.root = null;
        self.focused_pane = null;
        return null;
    }

    const split_parent = self.nodes.get(parent_id.?) orelse return error.InvalidTree;
    const sibling_id = switch (split_parent) {
        .split => |s| if (s.first == pane_id) s.second else s.first,
        else => return error.InvalidTree,
    };

    // The grandparent (parent of the split being removed)
    const grandparent_id = switch (split_parent) {
        .split => |s| s.parent,
        else => null,
    };

    // Remove the split node
    _ = self.nodes.remove(parent_id.?);

    // Update the sibling's parent to the grandparent
    var sibling = self.nodes.get(sibling_id) orelse return error.InvalidTree;
    switch (sibling) {
        .pane => |*p| p.parent = grandparent_id,
        .split => |*s| s.parent = grandparent_id,
    }
    try self.nodes.put(sibling_id, sibling);

    // Update the grandparent to point to the sibling
    if (grandparent_id) |gid| {
        var gp = self.nodes.get(gid) orelse return error.InvalidTree;
        switch (gp) {
            .split => |*s| {
                if (s.first == parent_id.?) {
                    s.first = sibling_id;
                } else if (s.second == parent_id.?) {
                    s.second = sibling_id;
                }
                try self.nodes.put(gid, .{ .split = s.* });
            },
            else => return error.InvalidTree,
        }
    } else {
        self.root = sibling_id;
    }

    // Focus the sibling (or its first pane child)
    self.focused_pane = self.firstPaneIn(sibling_id);
    return sibling_id;
}

/// Detach a pane from the tree, promoting its sibling.
/// Unlike close(), the pane node is removed from *this* tree but not destroyed.
/// Returns the sibling that was promoted (or null if the pane was root).
/// The caller is responsible for re-parenting the pane into another tree.
pub fn detachPane(self: *PaneTree, pane_id: NodeId) !?NodeId {
    const pane_node = self.nodes.get(pane_id) orelse return error.PaneNotFound;
    const parent_id = switch (pane_node) {
        .pane => |p| p.parent,
        else => return error.NotAPane,
    };

    // Remove the pane from this tree
    _ = self.nodes.remove(pane_id);

    if (parent_id == null) {
        // This was the only pane (root)
        self.root = null;
        self.focused_pane = null;
        return null;
    }

    const split_parent = self.nodes.get(parent_id.?) orelse return error.InvalidTree;
    const sibling_id = switch (split_parent) {
        .split => |s| if (s.first == pane_id) s.second else s.first,
        else => return error.InvalidTree,
    };

    const grandparent_id = switch (split_parent) {
        .split => |s| s.parent,
        else => null,
    };

    // Remove the split node
    _ = self.nodes.remove(parent_id.?);

    // Update the sibling's parent to the grandparent
    var sibling = self.nodes.get(sibling_id) orelse return error.InvalidTree;
    switch (sibling) {
        .pane => |*p| p.parent = grandparent_id,
        .split => |*s| s.parent = grandparent_id,
    }
    try self.nodes.put(sibling_id, sibling);

    // Update the grandparent to point to the sibling
    if (grandparent_id) |gid| {
        var gp = self.nodes.get(gid) orelse return error.InvalidTree;
        switch (gp) {
            .split => |*s| {
                if (s.first == parent_id.?) {
                    s.first = sibling_id;
                } else if (s.second == parent_id.?) {
                    s.second = sibling_id;
                }
                try self.nodes.put(gid, .{ .split = s.* });
            },
            else => return error.InvalidTree,
        }
    } else {
        self.root = sibling_id;
    }

    // Focus the sibling
    self.focused_pane = self.firstPaneIn(sibling_id);
    return sibling_id;
}

/// Attach a pane as the sole root of an empty tree.
pub fn attachPaneAsRoot(self: *PaneTree, pane_id: NodeId) !void {
    try self.nodes.put(pane_id, .{ .pane = .{ .id = pane_id, .parent = null } });
    self.root = pane_id;
    self.focused_pane = pane_id;
    // Ensure next_id is past this pane_id
    self.setNextId(pane_id + 1);
}

/// Find the first (leftmost/topmost) pane in a subtree.
fn firstPaneIn(self: *const PaneTree, node_id: NodeId) ?NodeId {
    const node = self.nodes.get(node_id) orelse return null;
    return switch (node) {
        .pane => node_id,
        .split => |s| self.firstPaneIn(s.first),
    };
}

/// Resize a split's divider that is the parent (or ancestor) of the given pane
/// in the given direction. `delta` is a fraction to add to the divider position.
pub fn resize(self: *PaneTree, pane_id: NodeId, direction: SplitDirection, delta: f64) !void {
    const target_orientation = direction.toOrientation();
    // Walk up from the pane to find the nearest split with matching orientation
    var current_id = pane_id;
    while (true) {
        const node = self.nodes.get(current_id) orelse return error.PaneNotFound;
        const pid = switch (node) {
            .pane => |p| p.parent,
            .split => |s| s.parent,
        };
        if (pid == null) break;

        const parent = self.nodes.get(pid.?) orelse break;
        switch (parent) {
            .split => |*s| {
                if (s.orientation == target_orientation) {
                    // Determine sign: if pane is in the second child, we need negative delta
                    const actual_delta = if (self.isInSubtree(s.first, pane_id))
                        delta
                    else
                        -delta;

                    var updated = s.*;
                    updated.divider_position = std.math.clamp(
                        updated.divider_position + actual_delta,
                        0.05,
                        0.95,
                    );
                    try self.nodes.put(pid.?, .{ .split = updated });
                    return;
                }
            },
            else => {},
        }
        current_id = pid.?;
    }
}

/// Check if `target` is in the subtree rooted at `root_id`.
fn isInSubtree(self: *const PaneTree, root_id: NodeId, target: NodeId) bool {
    if (root_id == target) return true;
    const node = self.nodes.get(root_id) orelse return false;
    return switch (node) {
        .pane => false,
        .split => |s| self.isInSubtree(s.first, target) or self.isInSubtree(s.second, target),
    };
}

/// Navigate from the focused pane in the given direction.
/// Returns the pane id that should receive focus.
pub fn navigate(self: *const PaneTree, from_pane: NodeId, direction: SplitDirection) ?NodeId {
    const target_orientation = direction.toOrientation();
    const want_second = direction.isSecond();

    // Walk up until we find a split with matching orientation
    // where we came from the opposite side
    var current_id = from_pane;
    while (true) {
        const node = self.nodes.get(current_id) orelse return null;
        const pid = switch (node) {
            .pane => |p| p.parent,
            .split => |s| s.parent,
        };
        if (pid == null) return null;

        const parent = self.nodes.get(pid.?) orelse return null;
        switch (parent) {
            .split => |s| {
                if (s.orientation == target_orientation) {
                    const came_from_first = (s.first == current_id) or self.isInSubtree(s.first, current_id);
                    if (came_from_first and want_second) {
                        // Navigate to the first pane in the second subtree
                        return self.firstPaneIn(s.second);
                    } else if (!came_from_first and !want_second) {
                        // Navigate to the last pane in the first subtree
                        return self.lastPaneIn(s.first);
                    }
                }
            },
            else => {},
        }
        current_id = pid.?;
    }
}

/// Find the last (rightmost/bottommost) pane in a subtree.
fn lastPaneIn(self: *const PaneTree, node_id: NodeId) ?NodeId {
    const node = self.nodes.get(node_id) orelse return null;
    return switch (node) {
        .pane => node_id,
        .split => |s| self.lastPaneIn(s.second),
    };
}

/// Swap two panes in the tree (exchange their positions).
pub fn swap(self: *PaneTree, pane_a: NodeId, pane_b: NodeId) !void {
    var node_a = self.nodes.get(pane_a) orelse return error.PaneNotFound;
    var node_b = self.nodes.get(pane_b) orelse return error.PaneNotFound;

    // Swap parent references
    const parent_a = switch (node_a) {
        .pane => |p| p.parent,
        else => return error.NotAPane,
    };
    const parent_b = switch (node_b) {
        .pane => |p| p.parent,
        else => return error.NotAPane,
    };

    // Update parents
    switch (node_a) {
        .pane => |*p| p.parent = parent_b,
        else => {},
    }
    switch (node_b) {
        .pane => |*p| p.parent = parent_a,
        else => {},
    }
    try self.nodes.put(pane_a, node_a);
    try self.nodes.put(pane_b, node_b);

    // Update parent split nodes to point to swapped children
    if (parent_a) |pa| {
        var p = self.nodes.get(pa) orelse return error.InvalidTree;
        switch (p) {
            .split => |*s| {
                if (s.first == pane_a) s.first = pane_b else if (s.second == pane_a) s.second = pane_b;
            },
            else => {},
        }
        try self.nodes.put(pa, p);
    } else {
        if (self.root == pane_a) self.root = pane_b;
    }

    if (parent_b) |pb| {
        var p = self.nodes.get(pb) orelse return error.InvalidTree;
        switch (p) {
            .split => |*s| {
                if (s.first == pane_b) s.first = pane_a else if (s.second == pane_b) s.second = pane_a;
            },
            else => {},
        }
        try self.nodes.put(pb, p);
    } else {
        if (self.root == pane_b) self.root = pane_a;
    }
}

// ------------------------------------------------------------------
// Snapshot (for session persistence and socket API)
// ------------------------------------------------------------------

pub const Snapshot = union(enum) {
    pane: PaneSnapshot,
    split_node: SplitSnapshot,
};

pub const PaneSnapshot = struct {
    id: NodeId,
};

pub const SplitSnapshot = struct {
    id: NodeId,
    orientation: Orientation,
    divider_position: f64,
    first: *Snapshot,
    second: *Snapshot,
};

/// Create a snapshot of the tree. The caller owns the returned memory.
pub fn snapshot(self: *const PaneTree, alloc: Allocator) !?*Snapshot {
    if (self.root) |root_id| {
        return try self.snapshotNode(alloc, root_id);
    }
    return null;
}

fn snapshotNode(self: *const PaneTree, alloc: Allocator, node_id: NodeId) !*Snapshot {
    const node = self.nodes.get(node_id) orelse return error.InvalidTree;
    const snap = try alloc.create(Snapshot);
    switch (node) {
        .pane => |p| {
            snap.* = .{ .pane = .{ .id = p.id } };
        },
        .split => |s| {
            const first = try self.snapshotNode(alloc, s.first);
            const second = try self.snapshotNode(alloc, s.second);
            snap.* = .{ .split_node = .{
                .id = s.id,
                .orientation = s.orientation,
                .divider_position = s.divider_position,
                .first = first,
                .second = second,
            } };
        },
    }
    return snap;
}
