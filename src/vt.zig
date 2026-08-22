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

/// Ghostty's own render-facing snapshot of a terminal: dimensions, colors,
/// cursor, and per-row cells with dirty tracking. This is what a renderer
/// consumes upstream, so it is what the screen wire protocol serializes --
/// building a parallel representation would mean maintaining a second idea of
/// what a terminal looks like.
///
/// One caveat shapes the whole design: `update` *consumes* the terminal's dirty
/// flags, so at most one RenderState may exist per Terminal. The pane owns it.
pub const RenderState = vt.RenderState;

/// Cell styling. `flags.underline` is an enum, so `@tagName` names it.
pub const Style = vt.Style;

/// `Style.Flags` is not `pub` upstream, so it cannot be named directly even
/// though the field is public. Deriving it from the field is the seam's job:
/// one place to fix if upstream exports it later.
pub const StyleFlags = @FieldType(Style, "flags");

/// A cell as stored in a page: content tag, codepoint, style id, wide flag.
pub const Cell = vt.Cell;

/// Colors and the 256-entry palette. Palette indices are resolved to RGB
/// before anything goes on the wire, so a client never needs the palette.
pub const color = vt.color;

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

test "OSC 133 marks reach the terminal through the stream amux uses" {
    const alloc = std.testing.allocator;

    var term = try Terminal.init(alloc, .{ .cols = 40, .rows = 5, .max_scrollback = 100 });
    defer term.deinit(alloc);

    const Handler = @typeInfo(@TypeOf(Terminal.vtHandler)).@"fn".return_type.?;
    var stream: Stream(Handler) = .{
        .handler = term.vtHandler(),
        .parser = .init(),
        .utf8decoder = .{},
    };

    // Nothing marked yet: everything written is command output as far as the
    // terminal knows.
    try std.testing.expectEqual(
        @as(@TypeOf(term.screens.active.cursor.semantic_content), .output),
        term.screens.active.cursor.semantic_content,
    );

    // A prompt, then the boundary where the user's typing begins.
    try stream.nextSlice("\x1b]133;A\x07$ ");
    try std.testing.expect(term.screens.active.cursor.semantic_content == .prompt);

    try stream.nextSlice("\x1b]133;B\x07");
    try std.testing.expect(term.screens.active.cursor.semantic_content == .input);

    // The command runs: what follows is output, which is what "the shell is
    // busy" looks like from here.
    try stream.nextSlice("make\x1b]133;C\x07\r\nbuilding\r\n");
    try std.testing.expect(term.screens.active.cursor.semantic_content == .output);

    // And back to a prompt.
    try stream.nextSlice("\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07");
    try std.testing.expect(term.screens.active.cursor.semantic_content == .input);
}

test "the exit status on OSC 133;D is recorded" {
    const alloc = std.testing.allocator;

    var term = try Terminal.init(alloc, .{ .cols = 40, .rows = 5, .max_scrollback = 100 });
    defer term.deinit(alloc);

    const Handler = @typeInfo(@TypeOf(Terminal.vtHandler)).@"fn".return_type.?;
    var stream: Stream(Handler) = .{
        .handler = term.vtHandler(),
        .parser = .init(),
        .utf8decoder = .{},
    };

    // Nothing has finished yet.
    try std.testing.expect(term.last_command_exit_code == null);

    try stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07false\x1b]133;C\x07\r\n");
    try stream.nextSlice("\x1b]133;D;1\x07");
    try std.testing.expectEqual(@as(i32, 1), term.last_command_exit_code.?);

    try stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07true\x1b]133;C\x07\r\n");
    try stream.nextSlice("\x1b]133;D;0\x07");
    try std.testing.expectEqual(@as(i32, 0), term.last_command_exit_code.?);

    // A command that ends without a status clears it rather than leaving the
    // previous one to be read as this command's.
    try stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07x\x1b]133;C\x07\r\n\x1b]133;D\x07");
    try std.testing.expect(term.last_command_exit_code == null);
}
