//! Encode a screen as VT bytes, so a terminal that was not watching can be
//! brought to the picture that already exists.
//!
//! This is what makes attaching work at all. A relay can stream new output
//! easily enough, but new output says nothing about what is already on screen --
//! that was painted by bytes that went past before anyone was looking. So the
//! daemon reconstructs it: cursor positioning, SGR runs and text, from the same
//! `RenderState` the cell protocol serializes.
//!
//! tmux does the same thing for the same reason. The alternative -- replaying
//! the whole raw byte history -- would need unbounded history and would re-run
//! side effects like title changes and bell.

const std = @import("std");
const vt = @import("../vt.zig");

const Allocator = std.mem.Allocator;

/// A cell's styling, resolved and comparable, so runs can be found.
const Style = struct {
    fg: ?vt.color.RGB = null,
    bg: ?vt.color.RGB = null,
    ul: ?vt.color.RGB = null,
    flags: vt.StyleFlags = .{},

    fn of(cell: vt.Cell, style: vt.Style, palette: *const vt.color.Palette) Style {
        var self: Style = .{
            .fg = resolve(style.fg_color, palette),
            .bg = resolve(style.bg_color, palette),
            .ul = resolve(style.underline_color, palette),
            .flags = style.flags,
        };
        switch (cell.content_tag) {
            .bg_color_palette => self.bg = palette[cell.content.color_palette],
            .bg_color_rgb => {
                const v = cell.content.color_rgb;
                self.bg = .{ .r = v.r, .g = v.g, .b = v.b };
            },
            else => {},
        }
        return self;
    }

    fn resolve(c: vt.Style.Color, palette: *const vt.color.Palette) ?vt.color.RGB {
        return switch (c) {
            .none => null,
            .palette => |i| palette[i],
            .rgb => |v| v,
        };
    }

    fn eql(a: Style, b: Style) bool {
        const fa: u16 = @bitCast(a.flags);
        const fb: u16 = @bitCast(b.flags);
        return fa == fb and rgbEql(a.fg, b.fg) and rgbEql(a.bg, b.bg) and rgbEql(a.ul, b.ul);
    }

    fn rgbEql(a: ?vt.color.RGB, b: ?vt.color.RGB) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.?.r == b.?.r and a.?.g == b.?.g and a.?.b == b.?.b;
    }

    fn isDefault(self: Style) bool {
        const f: u16 = @bitCast(self.flags);
        return f == 0 and self.fg == null and self.bg == null and self.ul == null;
    }
};

const Out = struct {
    alloc: Allocator,
    buf: *std.ArrayListUnmanaged(u8),

    fn raw(self: *Out, bytes: []const u8) !void {
        try self.buf.appendSlice(self.alloc, bytes);
    }

    fn print(self: *Out, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.buf.appendSlice(self.alloc, s);
    }
};

/// Emit the SGR sequence for a style. Always resets first: the receiving
/// terminal's current attributes are unknown, so building on them would carry
/// stale styling into the run.
fn writeStyle(o: *Out, s: Style) !void {
    try o.raw("\x1b[0m");
    if (s.isDefault()) return;

    const f = s.flags;
    if (f.bold) try o.raw("\x1b[1m");
    if (f.faint) try o.raw("\x1b[2m");
    if (f.italic) try o.raw("\x1b[3m");
    if (f.blink) try o.raw("\x1b[5m");
    if (f.inverse) try o.raw("\x1b[7m");
    if (f.invisible) try o.raw("\x1b[8m");
    if (f.strikethrough) try o.raw("\x1b[9m");
    if (f.overline) try o.raw("\x1b[53m");
    switch (f.underline) {
        .none => {},
        // The colon form carries the style; plain SGR 4 cannot express curly.
        .single => try o.raw("\x1b[4m"),
        .double => try o.raw("\x1b[4:2m"),
        .curly => try o.raw("\x1b[4:3m"),
        .dotted => try o.raw("\x1b[4:4m"),
        .dashed => try o.raw("\x1b[4:5m"),
    }
    // Truecolor throughout: palette indices were already resolved, and sending
    // them as indices again would let a differently-themed client disagree.
    if (s.fg) |c| try o.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
    if (s.bg) |c| try o.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
    if (s.ul) |c| try o.print("\x1b[58;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}

fn appendCell(
    alloc: Allocator,
    text: *std.ArrayListUnmanaged(u8),
    cell: vt.Cell,
    grapheme: []const u21,
) !void {
    var buf: [4]u8 = undefined;
    switch (cell.content_tag) {
        .codepoint, .codepoint_grapheme => {
            const cp = cell.content.codepoint;
            if (cp == 0) {
                try text.append(alloc, ' ');
            } else {
                const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch {
                    try text.append(alloc, ' ');
                    return;
                };
                try text.appendSlice(alloc, buf[0..n]);
            }
            if (cell.content_tag == .codepoint_grapheme) {
                for (grapheme) |g| {
                    const n = std.unicode.utf8Encode(@intCast(g), &buf) catch continue;
                    try text.appendSlice(alloc, buf[0..n]);
                }
            }
        },
        .bg_color_palette, .bg_color_rgb => try text.append(alloc, ' '),
    }
}

/// True if the cell contributes nothing visible: blank text and default style.
/// Trailing runs of these are skipped, which is most of a typical screen.
fn isBlank(cell: vt.Cell, style: Style) bool {
    if (!style.isDefault()) return false;
    return switch (cell.content_tag) {
        .codepoint => cell.content.codepoint == 0 or cell.content.codepoint == ' ',
        else => false,
    };
}

/// Paint `state` into `out`.
pub fn write(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    state: *const vt.RenderState,
) !void {
    var o: Out = .{ .alloc = alloc, .buf = out };
    const palette = &state.colors.palette;

    // Reset attributes, home the cursor and clear. Deliberately not a full RIS
    // (`ESC c`): that would reset modes the running program set, and the relay
    // is joining an existing session rather than starting one.
    try o.raw("\x1b[0m\x1b[H\x1b[2J");

    const rows = state.row_data.slice();
    const all_cells = rows.items(.cells);

    var y: usize = 0;
    while (y < state.rows) : (y += 1) {
        const slice = all_cells[y].slice();
        const raws = slice.items(.raw);
        const styles = slice.items(.style);
        const graphemes = slice.items(.grapheme);

        // Find the last cell worth painting, so a mostly-empty row costs a few
        // bytes instead of a full width of spaces.
        var last: ?usize = null;
        for (raws, 0..) |cell, x| {
            if (cell.wide == .spacer_tail) continue;
            const st: vt.Style = if (cell.style_id == 0) .{} else styles[x];
            if (!isBlank(cell, Style.of(cell, st, palette))) last = x;
        }
        const end = if (last) |l| l + 1 else continue;

        try o.print("\x1b[{d};1H", .{y + 1});

        var run_style: Style = .{};
        var have_run = false;
        var text: std.ArrayListUnmanaged(u8) = .{};
        defer text.deinit(alloc);

        var x: usize = 0;
        while (x < end) : (x += 1) {
            const cell = raws[x];
            if (cell.wide == .spacer_tail) continue;

            const st: vt.Style = if (cell.style_id == 0) .{} else styles[x];
            const s = Style.of(cell, st, palette);

            if (!have_run or !s.eql(run_style)) {
                if (have_run and text.items.len > 0) {
                    try writeStyle(&o, run_style);
                    try o.raw(text.items);
                    text.clearRetainingCapacity();
                }
                run_style = s;
                have_run = true;
            }
            try appendCell(alloc, &text, cell, graphemes[x]);
        }
        if (text.items.len > 0) {
            try writeStyle(&o, run_style);
            try o.raw(text.items);
        }
    }

    try o.raw("\x1b[0m");

    // Put the cursor where the terminal has it, and match its visibility. A
    // cursor scrolled out of the viewport has no position to paint.
    if (state.cursor.viewport) |vp| {
        try o.print("\x1b[{d};{d}H", .{ vp.y + 1, vp.x + 1 });
    }
    try o.raw(if (state.cursor.visible) "\x1b[?25h" else "\x1b[?25l");
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

/// Terminal plus render state, the way a Pane holds them.
const Fixture = struct {
    alloc: Allocator,
    term: vt.Terminal,
    render: vt.RenderState = .empty,

    fn init(alloc: Allocator, cols: u16, rows: u16) !Fixture {
        return .{
            .alloc = alloc,
            .term = try vt.Terminal.init(alloc, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback = 100,
            }),
        };
    }

    fn deinit(self: *Fixture) void {
        self.render.deinit(self.alloc);
        self.term.deinit(self.alloc);
    }

    fn feed(self: *Fixture, bytes: []const u8) !void {
        const Handler = @typeInfo(@TypeOf(vt.Terminal.vtHandler)).@"fn".return_type.?;
        var stream: vt.Stream(Handler) = .{
            .handler = self.term.vtHandler(),
            .parser = .init(),
            .utf8decoder = .{},
        };
        try stream.nextSlice(bytes);
    }

    fn painted(self: *Fixture) ![]u8 {
        try self.render.update(self.alloc, &self.term);
        var out: std.ArrayListUnmanaged(u8) = .{};
        errdefer out.deinit(self.alloc);
        try write(self.alloc, &out, &self.render);
        return out.toOwnedSlice(self.alloc);
    }
};

/// Feed a painted screen into a second terminal and dump it, which is the only
/// assertion that really matters: does the paint reproduce the picture?
fn repaintInto(alloc: Allocator, paint: []const u8, cols: u16, rows: u16) ![]const u8 {
    var f = try Fixture.init(alloc, cols, rows);
    defer f.deinit();
    try f.feed(paint);
    return f.term.screens.active.dumpStringAlloc(alloc, .{ .active = .{} });
}

test "a paint reproduces the text that was on screen" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 20, 4);
    defer f.deinit();

    try f.feed("first line\r\nsecond line");

    const paint = try f.painted();
    defer alloc.free(paint);

    // Round-trip through a fresh terminal: what a relay's terminal would show.
    const shown = try repaintInto(alloc, paint, 20, 4);
    defer alloc.free(shown);

    try testing.expect(std.mem.indexOf(u8, shown, "first line") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "second line") != null);
}

test "a paint carries styles, not just characters" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 30, 2);
    defer f.deinit();

    try f.feed("\x1b[1;31mRED\x1b[0m plain");

    const paint = try f.painted();
    defer alloc.free(paint);

    // Bold as SGR 1, and the palette colour resolved to truecolor rather than
    // sent as an index a differently-themed client could reinterpret.
    try testing.expect(std.mem.indexOf(u8, paint, "\x1b[1m") != null);
    try testing.expect(std.mem.indexOf(u8, paint, "\x1b[38;2;") != null);

    // And it still reads back as the same text.
    const shown = try repaintInto(alloc, paint, 30, 2);
    defer alloc.free(shown);
    try testing.expect(std.mem.indexOf(u8, shown, "RED plain") != null);
}

test "a paint puts the cursor back where it was" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 20, 5);
    defer f.deinit();

    // Park the cursor at row 3, column 7 (1-based on the wire).
    try f.feed("\x1b[3;7H");

    const paint = try f.painted();
    defer alloc.free(paint);
    try testing.expect(std.mem.indexOf(u8, paint, "\x1b[3;7H") != null);

    // Feeding the paint into a fresh terminal lands the cursor in the same
    // place, which is what stops a relay typing into the wrong cell.
    var dest = try Fixture.init(alloc, 20, 5);
    defer dest.deinit();
    try dest.feed(paint);
    try testing.expectEqual(@as(usize, 2), dest.term.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 6), dest.term.screens.active.cursor.x);
}

test "blank rows and trailing blanks cost nothing to paint" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 80, 24);
    defer f.deinit();

    try f.feed("hi");

    const paint = try f.painted();
    defer alloc.free(paint);

    // Two visible characters on an 80x24 screen. Painting every cell would be
    // ~2KB of spaces; skipping empty rows and trailing blanks is what keeps an
    // attach cheap.
    try testing.expect(paint.len < 200);
    try testing.expect(std.mem.indexOf(u8, paint, "hi") != null);
    // Only the row that has content gets positioned.
    try testing.expect(std.mem.indexOf(u8, paint, "\x1b[2;1H") == null);
}

test "a paint does not reset modes the running program set" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 20, 3);
    defer f.deinit();

    const paint = try f.painted();
    defer alloc.free(paint);

    // A full reset would clobber the state of whatever is already running in
    // the pane -- the relay is joining a session, not starting one.
    try testing.expect(std.mem.indexOf(u8, paint, "\x1bc") == null);
    try testing.expect(std.mem.indexOf(u8, paint, "\x1b[2J") != null);
}
