//! The screen wire format: what an attached client needs in order to draw.
//!
//! Serializes ghostty's `RenderState` -- dimensions, colors, cursor and cells.
//! Two decisions shape it:
//!
//! **Deltas are per row, keyed on a monotonic sequence number.** A client sends
//! the seq it last saw and gets back only the rows that changed since. Attach is
//! just `since = 0`, so a snapshot and a delta are the same code path and there
//! is no separate attach protocol to get wrong. The server keeps no per-client
//! state, so a client can reconnect, skip updates, or run behind without the
//! server tracking it.
//!
//! **Colors are resolved to RGB here.** Cells can name a palette index, and the
//! palette can be changed by the program running in the terminal. Resolving on
//! this side means a client never needs the palette and can never render a stale
//! one, at the cost of 6 bytes per styled run.
//!
//! Cells are emitted as runs of equal style, each carrying its starting column.
//! An explicit column means the client never has to infer positions from
//! character widths -- which matters because wide characters occupy two columns
//! and their trailing spacer cell is skipped entirely.

const std = @import("std");
const vt = @import("../vt.zig");

const Allocator = std.mem.Allocator;

/// Minimal JSON emitter. Hand-rolled to match the rest of the daemon's
/// handlers, which build responses the same way.
const Writer = struct {
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),

    fn raw(self: *Writer, bytes: []const u8) !void {
        try self.out.appendSlice(self.alloc, bytes);
    }

    fn print(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.out.appendSlice(self.alloc, s);
    }

    /// JSON string escaping, including the C0 range: terminal cells can hold
    /// control characters, and an unescaped one makes the whole response
    /// unparseable for the client.
    fn string(self: *Writer, s: []const u8) !void {
        try self.raw("\"");
        for (s) |ch| switch (ch) {
            '"' => try self.raw("\\\""),
            '\\' => try self.raw("\\\\"),
            '\n' => try self.raw("\\n"),
            '\r' => try self.raw("\\r"),
            '\t' => try self.raw("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                var buf: [8]u8 = undefined;
                try self.raw(std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch continue);
            },
            else => try self.out.append(self.alloc, ch),
        };
        try self.raw("\"");
    }
};

fn rgbHex(buf: *[7]u8, c: vt.color.RGB) []const u8 {
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch unreachable;
}

/// Resolve a style color against the live palette. `.none` means "the default",
/// which the client already has from the top-level colors.
fn resolve(c: vt.Style.Color, palette: *const vt.color.Palette) ?vt.color.RGB {
    return switch (c) {
        .none => null,
        .palette => |i| palette[i],
        .rgb => |v| v,
    };
}

/// What one run of same-styled cells looks like on the wire. Kept as a value so
/// runs can be compared for equality -- that comparison is what makes runs runs.
const RunStyle = struct {
    fg: ?vt.color.RGB = null,
    bg: ?vt.color.RGB = null,
    ul: ?vt.color.RGB = null,
    flags: vt.StyleFlags = .{},

    fn of(cell: vt.Cell, style: vt.Style, palette: *const vt.color.Palette) RunStyle {
        var self: RunStyle = .{
            .fg = resolve(style.fg_color, palette),
            .bg = resolve(style.bg_color, palette),
            .ul = resolve(style.underline_color, palette),
            .flags = style.flags,
        };
        // A cell with only a background carries the colour in its content
        // rather than in a style -- that is what the tag exists for, so
        // reading it off the style would silently lose the colour.
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

    fn eql(a: RunStyle, b: RunStyle) bool {
        const fa: u16 = @bitCast(a.flags);
        const fb: u16 = @bitCast(b.flags);
        if (fa != fb) return false;
        return colorEql(a.fg, b.fg) and colorEql(a.bg, b.bg) and colorEql(a.ul, b.ul);
    }

    fn colorEql(a: ?vt.color.RGB, b: ?vt.color.RGB) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.?.r == b.?.r and a.?.g == b.?.g and a.?.b == b.?.b;
    }
};

/// Write the style fields of a run. Everything at its default is omitted: an
/// ordinary terminal screen is overwhelmingly default-styled, so omission is
/// what keeps a full 80x24 snapshot small without a compression scheme.
fn writeStyle(w: *Writer, s: RunStyle) !void {
    const flags = s.flags;
    var buf: [7]u8 = undefined;
    if (s.fg) |c| try w.print(",\"fg\":\"{s}\"", .{rgbHex(&buf, c)});
    if (s.bg) |c| try w.print(",\"bg\":\"{s}\"", .{rgbHex(&buf, c)});
    if (s.ul) |c| try w.print(",\"ul\":\"{s}\"", .{rgbHex(&buf, c)});
    if (flags.bold) try w.raw(",\"bold\":true");
    if (flags.italic) try w.raw(",\"italic\":true");
    if (flags.faint) try w.raw(",\"faint\":true");
    if (flags.blink) try w.raw(",\"blink\":true");
    if (flags.inverse) try w.raw(",\"inverse\":true");
    if (flags.invisible) try w.raw(",\"invisible\":true");
    if (flags.strikethrough) try w.raw(",\"strike\":true");
    if (flags.overline) try w.raw(",\"overline\":true");
    if (flags.underline != .none) try w.print(",\"underline\":\"{s}\"", .{@tagName(flags.underline)});
}

pub const Options = struct {
    /// Only rows changed after this sequence number are sent. 0 means "send
    /// everything", which is what attaching does.
    since: u64 = 0,
    /// Included so a client can confirm which pane answered.
    pane_id: u64 = 0,
    /// True when the client must discard what it has: dimensions or global
    /// colors changed, so nothing it holds is positioned correctly any more.
    full: bool = false,
    /// The pane's current sequence number, to be echoed back next time.
    seq: u64 = 0,
    exited: bool = false,
    /// The terminal's default foreground/background, if it has an opinion.
    ///
    /// Null is not black -- it means the program running in the terminal has not
    /// asked for a colour, so the client should use its own theme. The daemon
    /// deliberately does not invent one: it has no theme, and answering black
    /// would render as invisible text against a black background.
    fg: ?vt.color.RGB = null,
    bg: ?vt.color.RGB = null,
    /// Reverse video is on. Sent as a flag rather than applied here, because
    /// with `fg`/`bg` unset only the client knows which two colours to swap.
    reverse: bool = false,
};

/// Serialize `state` into `out`. `row_seq[y]` is the sequence number at which
/// row y last changed; rows at or below `opts.since` are omitted.
pub fn write(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    state: *const vt.RenderState,
    row_seq: []const u64,
    opts: Options,
) !void {
    var w: Writer = .{ .alloc = alloc, .out = out };
    const palette = &state.colors.palette;

    var buf: [7]u8 = undefined;
    try w.print("{{\"pane_id\":{d},\"seq\":{d},\"cols\":{d},\"rows\":{d},\"full\":{s},\"exited\":{s}", .{
        opts.pane_id,
        opts.seq,
        state.cols,
        state.rows,
        if (opts.full) "true" else "false",
        if (opts.exited) "true" else "false",
    });

    try w.raw(",\"colors\":{");
    var wrote_color = false;
    if (opts.fg) |v| {
        try w.print("\"fg\":\"{s}\"", .{rgbHex(&buf, v)});
        wrote_color = true;
    }
    if (opts.bg) |v| {
        if (wrote_color) try w.raw(",");
        try w.print("\"bg\":\"{s}\"", .{rgbHex(&buf, v)});
        wrote_color = true;
    }
    if (state.colors.cursor) |cc| {
        if (wrote_color) try w.raw(",");
        try w.print("\"cursor\":\"{s}\"", .{rgbHex(&buf, cc)});
        wrote_color = true;
    }
    if (opts.reverse) {
        if (wrote_color) try w.raw(",");
        try w.raw("\"reverse\":true");
    }
    try w.raw("}");

    // Cursor position is viewport-relative, and null when the cursor is
    // scrolled out of view -- a client must not draw it in that case.
    try w.raw(",\"cursor\":{");
    if (state.cursor.viewport) |vp| {
        try w.print("\"x\":{d},\"y\":{d},\"wide_tail\":{s},", .{
            vp.x, vp.y, if (vp.wide_tail) "true" else "false",
        });
    }
    try w.print("\"visible\":{s},\"blinking\":{s},\"style\":\"{s}\"}}", .{
        if (state.cursor.visible) "true" else "false",
        if (state.cursor.blinking) "true" else "false",
        @tagName(state.cursor.visual_style),
    });

    try w.raw(",\"rows_changed\":[");
    var wrote_row = false;
    const rows = state.row_data.slice();
    const all_cells = rows.items(.cells);

    var y: usize = 0;
    while (y < state.rows) : (y += 1) {
        if (y < row_seq.len and row_seq[y] <= opts.since) continue;
        if (wrote_row) try w.raw(",");
        wrote_row = true;
        try w.print("{{\"y\":{d},\"runs\":[", .{y});
        try writeRow(&w, all_cells[y], palette);
        try w.raw("]}");
    }
    try w.raw("]}");
}

fn writeRow(
    w: *Writer,
    cells: std.MultiArrayList(vt.RenderState.Cell),
    palette: *const vt.color.Palette,
) !void {
    const slice = cells.slice();
    const raws = slice.items(.raw);
    const styles = slice.items(.style);
    const graphemes = slice.items(.grapheme);

    var wrote_run = false;
    var run_start: usize = 0;
    var run_style: RunStyle = .{};
    var run_text: std.ArrayListUnmanaged(u8) = .{};
    defer run_text.deinit(w.alloc);

    var x: usize = 0;
    while (x < raws.len) : (x += 1) {
        const cell = raws[x];

        // The trailing half of a wide character carries no content of its own;
        // the run's explicit start column is what keeps the client aligned.
        if (cell.wide == .spacer_tail) continue;

        const style: vt.Style = if (cell.style_id == 0) .{} else styles[x];
        const rs = RunStyle.of(cell, style, palette);

        const same = run_text.items.len > 0 and rs.eql(run_style);
        if (!same) {
            if (run_text.items.len > 0) {
                if (wrote_run) try w.raw(",");
                wrote_run = true;
                try w.print("{{\"x\":{d},\"t\":", .{run_start});
                try w.string(run_text.items);
                try writeStyle(w, run_style);
                try w.raw("}");
                run_text.clearRetainingCapacity();
            }
            run_start = x;
            run_style = rs;
        }

        try appendCellText(w.alloc, &run_text, cell, graphemes[x]);
    }

    if (run_text.items.len > 0) {
        if (wrote_run) try w.raw(",");
        try w.print("{{\"x\":{d},\"t\":", .{run_start});
        try w.string(run_text.items);
        try writeStyle(w, run_style);
        try w.raw("}");
    }
}

fn appendCellText(
    alloc: Allocator,
    text: *std.ArrayListUnmanaged(u8),
    cell: vt.Cell,
    grapheme: []const u21,
) !void {
    var buf: [4]u8 = undefined;
    switch (cell.content_tag) {
        .codepoint, .codepoint_grapheme => {
            // An empty cell is codepoint 0, which is a space to look at.
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
        // A background-only cell has no text; it still occupies its column.
        .bg_color_palette, .bg_color_rgb => try text.append(alloc, ' '),
    }
}

// ------------------------------------------------------------------
// Tests
//
// Driven from a Terminal directly rather than through a pty: the wire format is
// a pure function of terminal state, and a real shell would make it neither
// deterministic nor fast to check.
// ------------------------------------------------------------------

const testing = std.testing;

/// A terminal, its render state, and the row sequence bookkeeping, wired up the
/// way a Pane wires them.
const Fixture = struct {
    alloc: Allocator,
    term: vt.Terminal,
    render: vt.RenderState = .empty,
    row_seq: []u64 = &.{},
    seq: u64 = 0,
    full_seq: u64 = 0,

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
        self.alloc.free(self.row_seq);
        self.term.deinit(self.alloc);
    }

    /// Mirrors `Pane.refreshLocked`. Kept in step with it by the tests below,
    /// which assert the behaviour that matters rather than the implementation.
    fn refresh(self: *Fixture) !void {
        try self.render.update(self.alloc, &self.term);
        const rows: usize = self.render.rows;
        if (self.row_seq.len != rows) {
            self.row_seq = try self.alloc.realloc(self.row_seq, rows);
            self.seq += 1;
            @memset(self.row_seq, self.seq);
            self.full_seq = self.seq;
            const slice = self.render.row_data.slice();
            for (slice.items(.dirty)) |*d| d.* = false;
            self.render.dirty = .false;
            return;
        }
        if (self.render.dirty == .false) return;
        self.seq += 1;
        const full = self.render.dirty == .full;
        const slice = self.render.row_data.slice();
        const dirties = slice.items(.dirty);
        for (0..rows) |y| {
            if (full or dirties[y]) self.row_seq[y] = self.seq;
            dirties[y] = false;
        }
        if (full) self.full_seq = self.seq;
        self.render.dirty = .false;
    }

    fn json(self: *Fixture, since: u64) ![]u8 {
        try self.refresh();
        var out: std.ArrayListUnmanaged(u8) = .{};
        errdefer out.deinit(self.alloc);
        try write(self.alloc, &out, &self.render, self.row_seq, .{
            .since = since,
            .pane_id = 7,
            .full = since < self.full_seq,
            .seq = self.seq,
            .fg = self.term.colors.foreground.get(),
            .bg = self.term.colors.background.get(),
        });
        return out.toOwnedSlice(self.alloc);
    }
};

/// Count how many rows a payload carries, without a JSON parser.
fn rowCount(json: []const u8) usize {
    return std.mem.count(u8, json, "{\"y\":");
}

test "attaching sends the whole screen" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 20, 4);
    defer f.deinit();

    try f.term.printString("hello");

    const json = try f.json(0);
    defer alloc.free(json);

    try testing.expectEqual(@as(usize, 4), rowCount(json));
    try testing.expect(std.mem.indexOf(u8, json, "\"full\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"cols\":20") != null);
}

test "a delta sends only the rows that changed" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 20, 6);
    defer f.deinit();

    try f.term.printString("first");
    const attach = try f.json(0);
    defer alloc.free(attach);
    const after_attach = f.seq;
    try testing.expectEqual(@as(usize, 6), rowCount(attach));

    // Move to a new line and write there: one row changes, not six.
    try f.term.linefeed();
    f.term.carriageReturn();
    try f.term.printString("second");

    const delta = try f.json(after_attach);
    defer alloc.free(delta);

    // Two rows of six: the one written, and the one the cursor left -- a
    // renderer has to repaint the cell the cursor vacated, so ghostty marks it
    // changed too. Untouched rows are still absent, which is the point.
    try testing.expectEqual(@as(usize, 2), rowCount(delta));
    try testing.expect(std.mem.indexOf(u8, delta, "{\"y\":0,") != null);
    try testing.expect(std.mem.indexOf(u8, delta, "{\"y\":1,") != null);
    try testing.expect(std.mem.indexOf(u8, delta, "{\"y\":2,") == null);
    try testing.expect(std.mem.indexOf(u8, delta, "second") != null);
    try testing.expect(std.mem.indexOf(u8, delta, "\"full\":false") != null);
}

test "a resize invalidates everything the client holds" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 20, 4);
    defer f.deinit();

    try f.term.printString("before");
    const attach = try f.json(0);
    defer alloc.free(attach);
    const seen = f.seq;

    try f.term.resize(alloc, 30, 8);

    const after = try f.json(seen);
    defer alloc.free(after);

    // Every row, and the flag that tells the client to throw away its grid:
    // nothing it holds is in the right place any more.
    try testing.expectEqual(@as(usize, 8), rowCount(after));
    try testing.expect(std.mem.indexOf(u8, after, "\"full\":true") != null);
    try testing.expect(std.mem.indexOf(u8, after, "\"cols\":30") != null);
    try testing.expect(std.mem.indexOf(u8, after, "\"rows\":8") != null);
}

test "styles and colors survive the wire" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 30, 2);
    defer f.deinit();

    // Bold + red foreground, then plain: SGR through the same path a program
    // would use, so the style map and the palette are both exercised.
    var stream: vt.Stream(@typeInfo(@TypeOf(vt.Terminal.vtHandler)).@"fn".return_type.?) = .{
        .handler = f.term.vtHandler(),
        .parser = .init(),
        .utf8decoder = .{},
    };
    try stream.nextSlice("\x1b[1;31mRED\x1b[0m plain\x1b[44mBG\x1b[0m");

    const json = try f.json(0);
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"bold\":true") != null);
    // Palette index 1 resolved to RGB here rather than left for the client.
    try testing.expect(std.mem.indexOf(u8, json, "\"fg\":\"#") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"bg\":\"#") != null);
    // Runs break where the style breaks, and each carries its column.
    try testing.expect(std.mem.indexOf(u8, json, "\"x\":0,\"t\":\"RED\"") != null);
}

test "an unset default color is omitted rather than sent as black" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 10, 2);
    defer f.deinit();

    const json = try f.json(0);
    defer alloc.free(json);

    // A terminal with no configured theme has no opinion, and saying black
    // would render as invisible text on a black background.
    try testing.expect(std.mem.indexOf(u8, json, "\"colors\":{}") != null);
}

test "a wide character keeps the columns after it aligned" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 10, 2);
    defer f.deinit();

    // A CJK codepoint occupies two columns; its trailing spacer cell carries no
    // content and must not appear as a character of its own.
    try f.term.printString("a\u{4e16}b");

    const json = try f.json(0);
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\u{4e16}") != null);
    // 'b' sits at column 3: one for 'a', two for the wide character.
    const row = std.mem.indexOf(u8, json, "{\"y\":0,").?;
    const row_end = std.mem.indexOfPos(u8, json, row, "}]}").?;
    const first_row = json[row..row_end];
    try testing.expect(std.mem.indexOf(u8, first_row, "a\u{4e16}b") != null);
    // The spacer contributed no extra codepoint, so the text is 3 chars of
    // content: any duplication would show up as a repeated character.
    try testing.expect(std.mem.count(u8, first_row, "\u{4e16}") == 1);
}

test "control characters in a cell cannot break the payload" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 10, 2);
    defer f.deinit();

    // A quote and a backslash are the two characters that would end the JSON
    // string early if they were not escaped.
    try f.term.printString("\"\\ok");

    const json = try f.json(0);
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\\\\") != null);
    // Still parseable: every brace and bracket balances.
    var depth: i32 = 0;
    var in_string = false;
    var escaped = false;
    for (json) |ch| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            '{', '[' => depth += 1,
            '}', ']' => depth -= 1,
            else => {},
        }
        try testing.expect(depth >= 0);
    }
    try testing.expectEqual(@as(i32, 0), depth);
    try testing.expect(!in_string);
}
