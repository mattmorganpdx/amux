//! amux's seam onto the headless terminal engine from the Ghostty fork.
//!
//! `ghostty-vt` is the VT parser, Screen, PageList/scrollback and search
//! extracted from Ghostty with no GL and no GTK. It is compiled in as a Zig
//! module (see build.zig) rather than linked as a library, because the
//! generated C headers expose only OSC/color/SGR/key while the Zig module
//! exports the types below.
//!
//! Everything goes through this file so there is one place to see what amux
//! actually depends on, and one place to adapt if the upstream API shifts --
//! it is explicitly documented as unstable.

const std = @import("std");
pub const vt = @import("ghostty_vt");

/// A terminal: screen, scrollback, modes, cursor. Owns no PTY and no renderer,
/// so the daemon can hold one per pane with no display attached.
pub const Terminal = vt.Terminal;

/// The visible screen plus its scrollback.
pub const Screen = vt.Screen;

/// Paged scrollback storage behind a Screen.
pub const PageList = vt.PageList;

/// Incremental VT parser. Feed it PTY bytes.
pub const Stream = vt.Stream;
pub const Parser = vt.Parser;

/// Coordinates into a Screen.
pub const point = vt.point;

/// Scrollback search. Relevant to the history/audit work: this searches live
/// scrollback, which is a different thing from querying closed sessions.
pub const search = vt.search;

test "terminal engine is usable from amux" {
    const alloc = std.testing.allocator;

    var term = try Terminal.init(alloc, .{
        .cols = 20,
        .rows = 5,
        .max_scrollback = 100,
    });
    defer term.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 20), term.cols);
    try std.testing.expectEqual(@as(usize, 5), term.rows);
}

test "printed text is readable back off the screen" {
    const alloc = std.testing.allocator;

    var term = try Terminal.init(alloc, .{
        .cols = 40,
        .rows = 5,
        .max_scrollback = 100,
    });
    defer term.deinit(alloc);

    try term.printString("amux terminal engine");

    const dump = try term.screens.active.dumpStringAlloc(alloc, .{ .active = .{} });
    defer alloc.free(dump);

    try std.testing.expect(std.mem.indexOf(u8, dump, "amux terminal engine") != null);
}

test "scrollback retains lines scrolled off the screen" {
    const alloc = std.testing.allocator;

    var term = try Terminal.init(alloc, .{
        .cols = 20,
        .rows = 3,
        .max_scrollback = 1000,
    });
    defer term.deinit(alloc);

    // More lines than fit, so the earliest must land in scrollback.
    for (0..10) |i| {
        var buf: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "line{d}", .{i});
        try term.printString(line);
        try term.linefeed();
        term.carriageReturn();
    }

    const active = try term.screens.active.dumpStringAlloc(alloc, .{ .active = .{} });
    defer alloc.free(active);
    // The oldest line has scrolled out of the active area...
    try std.testing.expect(std.mem.indexOf(u8, active, "line0") == null);

    // ...but is still retrievable from the scrollback.
    const all = try term.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "line0") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "line9") != null);
}
