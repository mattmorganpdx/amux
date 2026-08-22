//! Reading a command's output from the shell's own OSC 133 marks.
//!
//! `surface.run` otherwise extracts output by matching the echoed command in a
//! "before" snapshot against an "after" one and looking for something that
//! resembles a prompt. That is documented as a heuristic and it is a fair one,
//! but it has to cope with the echo wrapping at the column limit, with the
//! screen scrolling between snapshots, and with prompts it does not recognise.
//!
//! When the shell marks its own boundaries there is nothing to infer: cells are
//! tagged as prompt, input or output, so the output is simply the cells that say
//! they are output.

const std = @import("std");
const vt = @import("../vt.zig");

const Allocator = std.mem.Allocator;

/// What a row is, judged by the marks on the cells that have content.
const RowKind = enum {
    /// Prompt text, or what the user typed at it.
    prompt_or_input,
    /// Command output.
    output,
    /// Nothing on it, so it belongs to whatever surrounds it.
    blank,
};

fn classifyRow(cells: std.MultiArrayList(vt.RenderState.Cell)) RowKind {
    const slice = cells.slice();
    const raws = slice.items(.raw);

    var kind: RowKind = .blank;
    for (raws) |cell| {
        if (cell.wide == .spacer_tail) continue;
        const empty = switch (cell.content_tag) {
            .codepoint => cell.content.codepoint == 0 or cell.content.codepoint == ' ',
            else => false,
        };
        switch (cell.semantic_content) {
            .prompt, .input => {
                // A prompt mark counts even on a blank cell: the cell after a
                // prompt's trailing space is still part of the prompt line, and
                // treating that line as output would put the prompt in the
                // result.
                return .prompt_or_input;
            },
            .output => if (!empty) {
                kind = .output;
            },
        }
    }
    return kind;
}

fn rowText(alloc: Allocator, cells: std.MultiArrayList(vt.RenderState.Cell)) ![]u8 {
    const slice = cells.slice();
    const raws = slice.items(.raw);
    const graphemes = slice.items(.grapheme);

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(alloc);

    var buf: [4]u8 = undefined;
    for (raws, 0..) |cell, x| {
        if (cell.wide == .spacer_tail) continue;
        switch (cell.content_tag) {
            .codepoint, .codepoint_grapheme => {
                const cp = cell.content.codepoint;
                if (cp == 0) {
                    try out.append(alloc, ' ');
                } else {
                    const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch {
                        try out.append(alloc, ' ');
                        continue;
                    };
                    try out.appendSlice(alloc, buf[0..n]);
                }
                if (cell.content_tag == .codepoint_grapheme) {
                    for (graphemes[x]) |g| {
                        const n = std.unicode.utf8Encode(@intCast(g), &buf) catch continue;
                        try out.appendSlice(alloc, buf[0..n]);
                    }
                }
            },
            .bg_color_palette, .bg_color_rgb => try out.append(alloc, ' '),
        }
    }

    // Trailing blanks are padding, not content.
    var end = out.items.len;
    while (end > 0 and out.items[end - 1] == ' ') end -= 1;
    out.shrinkRetainingCapacity(end);
    return out.toOwnedSlice(alloc);
}

/// True if anything on this screen carries an OSC 133 mark.
///
/// Looks at the cells rather than at the cursor. While a command is running the
/// cursor is legitimately on output, so asking it whether the shell is
/// integrated answers "no" for exactly as long as the command takes -- which
/// made the first `run` after enabling integration fall back to guessing. The
/// prompt line above is still marked the whole time.
pub fn hasMarks(state: *const vt.RenderState) bool {
    const rows = state.row_data.slice();
    const all_cells = rows.items(.cells);
    var y: usize = 0;
    while (y < state.rows) : (y += 1) {
        if (classifyRow(all_cells[y]) == .prompt_or_input) return true;
    }
    return false;
}

/// The output of the most recent command, or null if this screen carries no
/// marks and there is nothing to read them from.
///
/// Walks up from the prompt the cursor is sitting on, collecting output and
/// stopping at the line the command was typed on. Caller frees.
pub fn lastCommandOutput(alloc: Allocator, state: *const vt.RenderState) !?[]const u8 {
    if (!hasMarks(state)) return null;

    const rows = state.row_data.slice();
    const all_cells = rows.items(.cells);

    // Anchor on the cursor rather than on the bottom of the screen. The prompt
    // waiting now is the row the cursor is on, and everything below it is
    // padding. Walking up from the bottom instead meant guessing where that
    // prompt started, and the guess had no way to stop at the command's own line
    // when the command printed nothing -- it walked straight past it into
    // whatever happened to be on screen from before.
    const anchor: usize = if (state.cursor.viewport) |vp| vp.y else state.rows;
    if (anchor == 0) return try alloc.dupe(u8, "");

    var first_output: ?usize = null;
    var last_output: ?usize = null;

    var i: usize = anchor;
    while (i > 0) {
        i -= 1;
        switch (classifyRow(all_cells[i])) {
            // The line the command was typed on. Anything above it belongs to
            // an earlier command, including anything written before this shell
            // was integrated, which carries no marks and would otherwise read
            // as output.
            .prompt_or_input => break,
            .output => {
                first_output = i;
                if (last_output == null) last_output = i;
            },
            .blank => {
                // Blank lines within the output are part of it; blank lines
                // below it are trailing padding.
                if (last_output != null) first_output = i;
            },
        }
    }

    const start = first_output orelse return try alloc.dupe(u8, "");
    const end = last_output orelse return try alloc.dupe(u8, "");

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(alloc);
    var row = start;
    while (row <= end) : (row += 1) {
        const line = try rowText(alloc, all_cells[row]);
        defer alloc.free(line);
        if (out.items.len > 0) try out.append(alloc, '\n');
        try out.appendSlice(alloc, line);
    }
    return try out.toOwnedSlice(alloc);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

/// A terminal driven by the same stream a pane uses, so the marks are applied
/// exactly as they would be by a real shell.
const Fixture = struct {
    alloc: Allocator,
    term: vt.Terminal,
    render: vt.RenderState = .empty,

    fn init(alloc: Allocator, cols: u16, rows: u16) !Fixture {
        return .{ .alloc = alloc, .term = try vt.Terminal.init(alloc, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = 100,
        }) };
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

    fn output(self: *Fixture) !?[]const u8 {
        try self.render.update(self.alloc, &self.term);
        return lastCommandOutput(self.alloc, &self.render);
    }
};

test "output comes from the marks, not from matching the echoed command" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 40, 10);
    defer f.deinit();

    try f.feed("\x1b]133;A\x07$ \x1b]133;B\x07make\x1b]133;C\x07\r\n");
    try f.feed("compiling\r\nlinking\r\n");
    try f.feed("\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07");

    const got = (try f.output()).?;
    defer alloc.free(got);
    try testing.expectEqualStrings("compiling\nlinking", got);
}

test "a prompt that looks like nothing in particular is still excluded" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 40, 10);
    defer f.deinit();

    // A prompt no suffix list would recognise. The marks do not care.
    try f.feed("\x1b]133;A\x07\u{2192} \x1b]133;B\x07deploy\x1b]133;C\x07\r\n");
    try f.feed("shipped\r\n");
    try f.feed("\x1b]133;D;0\x07\x1b]133;A\x07\u{2192} \x1b]133;B\x07");

    const got = (try f.output()).?;
    defer alloc.free(got);
    try testing.expectEqualStrings("shipped", got);
}

test "output that ends in a prompt-like string is not truncated" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 40, 10);
    defer f.deinit();

    // "$ " inside the output is the case that fools matching by sight.
    try f.feed("\x1b]133;A\x07$ \x1b]133;B\x07prices\x1b]133;C\x07\r\n");
    try f.feed("apples $ \r\npears $ \r\n");
    try f.feed("\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07");

    const got = (try f.output()).?;
    defer alloc.free(got);
    try testing.expectEqualStrings("apples $\npears $", got);
}

test "a command with no output reads as no output" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 40, 10);
    defer f.deinit();

    try f.feed("\x1b]133;A\x07$ \x1b]133;B\x07true\x1b]133;C\x07\r\n");
    try f.feed("\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07");

    const got = (try f.output()).?;
    defer alloc.free(got);
    try testing.expectEqualStrings("", got);
}

test "an unmarked screen says so instead of guessing" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 40, 10);
    defer f.deinit();

    // No shell integration: every cell is plain output, and the caller has to
    // fall back to the heuristic rather than be handed a wrong answer.
    try f.feed("$ make\r\ncompiling\r\n$ ");
    try testing.expect((try f.output()) == null);
}

test "the exact byte sequence bash produces is recognised as marked" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 80, 10);
    defer f.deinit();

    // A shell is always already at a prompt when a command is typed, so the
    // sequence has to start there: it is the `B` from the previous cycle that
    // marks the echoed command as input rather than as output. Starting
    // mid-cycle put the echo in the result, which is a fair description of what
    // a client would see if this ever ran against a terminal that had just
    // started.
    try f.feed("\x1b]133;A\x07user@host $ \x1b]133;B\x07");

    // Captured verbatim from a live pane running the shipped bash integration,
    // bracketed-paste toggles, colour and all.
    try f.feed("echo hi\r\n\x1b[?2004l\r\x1b]133;C\x07hi\r\n" ++
        "\x1b]133;D;0\x07\x1b]133;A\x07\x1b[?2004h" ++
        "\x1b[01;32muser@host\x1b[00m:\x1b[01;34m~/src\x1b[00m $ \x1b]133;B\x07");

    try f.render.update(f.alloc, &f.term);
    try testing.expect(hasMarks(&f.render));

    const got = (try f.output()).?;
    defer alloc.free(got);
    try testing.expectEqualStrings("hi", got);
}

test "a command long enough to wrap is still not mistaken for output" {
    const alloc = testing.allocator;
    // Narrow on purpose: the typed command spills onto continuation rows that
    // carry no prompt of their own, only input marks. Those rows are exactly
    // what matching-by-sight gets wrong, and they are the reason input has to be
    // excluded by its mark rather than by sharing a line with a prompt.
    var f = try Fixture.init(alloc, 20, 10);
    defer f.deinit();

    try f.feed("\x1b]133;A\x07$ \x1b]133;B\x07");
    try f.feed("echo one two three four five\x1b]133;C\x07\r\n");
    try f.feed("one two three four five\r\n");
    try f.feed("\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07");

    const got = (try f.output()).?;
    defer alloc.free(got);

    // The result is the output, wrapped as the terminal wrapped it -- and none
    // of the command that produced it.
    try testing.expect(std.mem.indexOf(u8, got, "echo one") == null);
    const flat = try std.mem.replaceOwned(u8, alloc, got, "\n", "");
    defer alloc.free(flat);
    try testing.expectEqualStrings("one two three four five", flat);
}

test "output stops at the command's line, not at whatever came before it" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 40, 10);
    defer f.deinit();

    // Unmarked history, as every pane has before its shell is integrated. Those
    // cells are indistinguishable from output, so the walk has to stop at the
    // command's own marked line rather than run past it.
    try f.feed("$ source integration.sh\r\n");

    // A command that prints nothing at all: the case where there is no output
    // row to stop the walk.
    try f.feed("\x1b]133;A\x07$ \x1b]133;B\x07true\x1b]133;C\x07\r\n");
    try f.feed("\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07");

    const got = (try f.output()).?;
    defer alloc.free(got);
    try testing.expectEqualStrings("", got);
}

test "marks survive the incremental refreshes a live pane does" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 80, 6);
    defer f.deinit();

    // A live pane refreshes its render state constantly -- every poll, every
    // watch tick -- so rows are rebuilt incrementally rather than all at once.
    // Tests that fed everything and updated once did not exercise that.
    try f.feed("$ source integration.sh\r\n");
    try f.render.update(f.alloc, &f.term);

    try f.feed("\x1b]133;A\x07user@host $ \x1b]133;B\x07");
    try f.render.update(f.alloc, &f.term);

    try f.feed("true\r\n\x1b]133;C\x07\x1b]133;D;0\x07\x1b]133;A\x07user@host $ \x1b]133;B\x07");
    try f.render.update(f.alloc, &f.term);

    try testing.expect(hasMarks(&f.render));

    const got = try lastCommandOutput(alloc, &f.render);
    try testing.expect(got != null);
    defer alloc.free(got.?);
    try testing.expectEqualStrings("", got.?);
}
