const std = @import("std");

const Allocator = std.mem.Allocator;

/// Tracks UUID <-> ref mapping with monotonic ordinals per kind.
/// Refs are human-readable like "window:1", "workspace:2", etc.
pub const HandleRegistry = @This();

pub const Kind = enum {
    window,
    workspace,
    pane,
    surface,

    pub fn prefix(self: Kind) []const u8 {
        return switch (self) {
            .window => "window",
            .workspace => "workspace",
            .pane => "pane",
            .surface => "surface",
        };
    }
};

const Entry = struct {
    kind: Kind,
    ordinal: u64,
    id: u64, // Internal numeric ID
};

alloc: Allocator,
entries: std.AutoHashMap(u64, Entry),
next_ordinal: [4]u64 = .{ 1, 1, 1, 1 }, // one per Kind

pub fn init(alloc: Allocator) HandleRegistry {
    return .{
        .alloc = alloc,
        .entries = std.AutoHashMap(u64, Entry).init(alloc),
    };
}

pub fn deinit(self: *HandleRegistry) void {
    self.entries.deinit();
}

/// Register an internal ID and get back its ref string.
pub fn register(self: *HandleRegistry, kind: Kind, id: u64) ![]const u8 {
    const kind_idx = @intFromEnum(kind);
    const ordinal = self.next_ordinal[kind_idx];
    self.next_ordinal[kind_idx] += 1;

    try self.entries.put(id, .{
        .kind = kind,
        .ordinal = ordinal,
        .id = id,
    });

    return std.fmt.allocPrint(self.alloc, "{s}:{d}", .{ kind.prefix(), ordinal });
}

/// Look up the ref for a given internal ID.
pub fn getRef(self: *const HandleRegistry, id: u64) ?[]const u8 {
    const entry = self.entries.get(id) orelse return null;
    return std.fmt.allocPrint(self.alloc, "{s}:{d}", .{ entry.kind.prefix(), entry.ordinal }) catch null;
}

/// Remove a registered ID.
pub fn unregister(self: *HandleRegistry, id: u64) void {
    _ = self.entries.remove(id);
}
