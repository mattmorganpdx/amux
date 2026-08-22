//! Deciding when a watching agent should be woken.
//!
//! An agent running a long command has to choose between polling on a timer --
//! burning a turn on every dead read -- and a completion callback, which is
//! worse, because commands stop for reasons other than finishing. `apt upgrade`
//! opens a dpkg config prompt; a build asks for a password; a script launches a
//! TUI. The agent has to *see* those, and a "done" callback never fires for
//! them.
//!
//! So the daemon watches on a fast local loop and wakes the agent only when
//! something happened worth a turn. This file is the "worth a turn" judgement,
//! kept as pure functions over an observed screen so it can be tested against
//! synthetic terminals rather than by driving real programs and hoping.
//!
//! One of these signals is exact and the rest are heuristics, which is worth
//! knowing when they disagree: entering the alternate screen is a fact reported
//! by the VT engine, while "this looks like a question" is pattern matching and
//! will occasionally be wrong in both directions.

const std = @import("std");

/// Why the agent is being woken. Sent with the event so it can orient without
/// re-reading the whole screen first.
pub const Reason = enum {
    /// The child process is gone.
    exited,
    /// The terminal entered the alternate screen: something full-screen took
    /// over, like an editor, a pager or a config dialog.
    tui_detected,
    /// The screen is asking a question and waiting for an answer.
    prompt_waiting,
    /// Output stopped and a shell prompt is back: the command finished.
    command_complete,
    /// Output stopped without a prompt: probably waiting for input, but not in
    /// a form recognised as a question.
    output_stalled,

    pub fn name(self: Reason) []const u8 {
        return @tagName(self);
    }
};

pub const Observation = struct {
    /// The visible screen.
    text: []const u8,
    /// The terminal is on the alternate screen right now.
    alt_screen: bool,
    /// It was on the alternate screen when the watch began. Entering is the
    /// event; already being there is not.
    was_alt_screen: bool,
    exited: bool,
    /// Output has arrived since the point the caller cares about.
    ///
    /// Required before anything can be called finished or stalled. Without it a
    /// watch started just after sending a command would see the *previous*
    /// prompt still on screen and report the command complete before it had
    /// produced a byte.
    ///
    /// Which point that is matters. Measuring from when the watch happened to
    /// start means a command that finishes before the agent gets round to
    /// watching is never reported, and the agent waits out the whole timeout --
    /// so the caller can name the generation it last saw instead.
    saw_output: bool,
    /// Milliseconds since the last output.
    idle_ms: u64,
    /// How long output must be stopped before it counts as stopped.
    stall_ms: u64,
    /// Overrides the built-in shell prompt suffixes.
    prompt: ?[]const u8 = null,

    /// Whether the shell is at a prompt, when the shell says so via OSC 133.
    ///
    /// Null means no shell integration on this pane, and the prompt has to be
    /// recognised by how it looks. That guess is wrong for any prompt not ending
    /// in one of a handful of characters, and wrong again for output that
    /// happens to end in one; when the shell marks its own boundaries there is
    /// nothing left to get wrong.
    at_prompt: ?bool = null,
};

/// Why this observation deserves a turn, or null to keep waiting.
pub fn classify(o: Observation) ?Reason {
    if (o.exited) return .exited;

    // Exact, not inferred: the VT engine reports which screen is active.
    if (o.alt_screen and !o.was_alt_screen) return .tui_detected;

    // A question wakes immediately rather than after the stall timer. Waiting
    // for silence before reporting one would add the stall delay to every
    // prompt, and a prompt is the case where the agent is most needed.
    if (looksLikeQuestion(o.text)) return .prompt_waiting;

    if (!o.saw_output) return null;
    if (o.idle_ms < o.stall_ms) return null;

    // The shell's own answer when it gives one, the guess otherwise.
    const at_prompt = o.at_prompt orelse endsWithPrompt(o.text, o.prompt);
    if (at_prompt) return .command_complete;
    return .output_stalled;
}

/// Only the last non-empty line is searched for a question.
///
/// Searching more of the tail seemed safer and was worse: a question answered a
/// moment ago is still on screen, so starting any new command re-matched it and
/// woke immediately with the wrong reason. A program waiting for an answer puts
/// the question where the cursor is, so that is the only line that can mean it
/// is being asked *now*.
///
/// The cost is prompts that put the question on one line and the cursor on the
/// next; those fall through to the stall detector, which is a slower wake rather
/// than a wrong one.
const question_tail_lines = 1;

/// Patterns that mean a program is waiting for an answer.
///
/// Matched case-insensitively against the last few lines. Deliberately short:
/// every addition is a chance to wake an agent for a line of ordinary output
/// that happens to contain the words, and a false wake costs exactly the turn
/// this whole mechanism exists to save.
const question_patterns = [_][]const u8{
    "[y/n]",
    "(y/n)",
    "[yes/no]",
    "(yes/no)",
    "password:",
    "password for",
    "passphrase",
    "press any key",
    "press enter",
    "--more--",
    "(end)",
    "overwrite?",
    "are you sure",
    "do you want to continue",
};

pub fn looksLikeQuestion(text: []const u8) bool {
    const tail = lastLines(text, question_tail_lines);
    if (tail.len == 0) return false;

    var buf: [512]u8 = undefined;
    const n = @min(tail.len, buf.len);
    const lowered = std.ascii.lowerString(buf[0..n], tail[tail.len - n ..]);

    for (question_patterns) |pat| {
        if (std.mem.indexOf(u8, lowered, pat) != null) return true;
    }
    return false;
}

/// The last `count` non-empty lines, trailing blank lines ignored.
fn lastLines(text: []const u8, count: usize) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r' or text[end - 1] == ' ')) {
        end -= 1;
    }
    if (end == 0) return "";

    var start = end;
    var seen: usize = 0;
    while (start > 0) {
        if (text[start - 1] == '\n') {
            seen += 1;
            if (seen == count) break;
        }
        start -= 1;
    }
    return text[start..end];
}

/// True if the last line looks like a shell prompt.
///
/// The same rule `surface.run` uses, and the same heuristic: the real answer is
/// OSC 133 shell integration, where the shell says where its prompt is instead
/// of being guessed at.
pub fn endsWithPrompt(text: []const u8, custom: ?[]const u8) bool {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r')) end -= 1;
    if (end == 0) return false;
    var start = end;
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    const last = std.mem.trimRight(u8, text[start..end], " ");
    if (last.len == 0) return false;

    if (custom) |pat| return std.mem.endsWith(u8, last, pat);
    for ([_][]const u8{ "$ ", "# ", "% ", "> ", "$", "#", "%", ">" }) |suffix| {
        if (std.mem.endsWith(u8, last, suffix)) return true;
    }
    return false;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

/// An observation with the boring fields filled in, so each test states only
/// what it is about.
fn obs(text: []const u8) Observation {
    // at_prompt defaults to null, so these exercise the guessing path unless a
    // test says otherwise.
    return .{
        .text = text,
        .alt_screen = false,
        .was_alt_screen = false,
        .exited = false,
        .saw_output = true,
        .idle_ms = 5000,
        .stall_ms = 2000,
    };
}

test "a finished command is told apart from a stalled one" {
    var done = obs("$ make\nbuilt 12 files\n$ ");
    try testing.expectEqual(Reason.command_complete, classify(done).?);

    // Same silence, no prompt: something is holding the terminal.
    var stalled = obs("$ ssh prod\nLast login: today\n");
    try testing.expectEqual(Reason.output_stalled, classify(stalled).?);

    _ = &done;
    _ = &stalled;
}

test "output still flowing is not worth a turn" {
    var running = obs("$ make\ncompiling foo.c\n");
    running.idle_ms = 100; // still producing
    try testing.expect(classify(running) == null);
}

test "a command that has produced nothing yet is not reported finished" {
    // The previous prompt is still on screen because the command has not
    // written anything. Reporting completion here would have the agent look at
    // a command that never ran.
    var fresh = obs("$ ");
    fresh.saw_output = false;
    try testing.expect(classify(fresh) == null);
}

test "entering the alternate screen wakes, staying in it does not" {
    var entered = obs("");
    entered.alt_screen = true;
    try testing.expectEqual(Reason.tui_detected, classify(entered).?);

    // Already full-screen when the watch began: the agent knows, and waking for
    // it every time would make watching a TUI useless.
    var already = obs("");
    already.alt_screen = true;
    already.was_alt_screen = true;
    already.idle_ms = 100;
    try testing.expect(classify(already) == null);
}

test "a question wakes immediately, without waiting out the stall timer" {
    var asking = obs("Do you want to continue? [Y/n] ");
    asking.idle_ms = 10; // nowhere near the stall threshold
    try testing.expectEqual(Reason.prompt_waiting, classify(asking).?);

    var sudo = obs("[sudo] password for matt: ");
    sudo.idle_ms = 10;
    try testing.expectEqual(Reason.prompt_waiting, classify(sudo).?);
}

test "an old question further up the screen is not a new one" {
    // Answered a while ago, then a build carried on. Waking here would be a
    // false alarm, and a false alarm costs the turn this is meant to save.
    const text =
        "Do you want to continue? [Y/n] y\n" ++
        "Unpacking libfoo\n" ++
        "Setting up libfoo\n" ++
        "Processing triggers\n" ++
        "$ ";
    try testing.expect(!looksLikeQuestion(text));
}

test "an exited child outranks everything else" {
    var gone = obs("$ ");
    gone.exited = true;
    gone.alt_screen = true;
    try testing.expectEqual(Reason.exited, classify(gone).?);
}

test "prompt detection accepts the usual shells and a custom pattern" {
    try testing.expect(endsWithPrompt("user@host:~$ ", null));
    try testing.expect(endsWithPrompt("root@host:/# ", null));
    try testing.expect(endsWithPrompt("PS> ", null));
    try testing.expect(!endsWithPrompt("compiling foo.c", null));
    try testing.expect(endsWithPrompt("READY!", "!"));
    try testing.expect(!endsWithPrompt("READY!", "?"));
}

test "the shell's own answer beats the guess, in both directions" {
    // A prompt that ends in nothing familiar. Guessing calls this stalled; the
    // shell says it is a prompt, and the shell is right.
    var unusual = obs("$ deploy\ndone\n\u{2192} ");
    unusual.at_prompt = true;
    try testing.expectEqual(Reason.command_complete, classify(unusual).?);
    unusual.at_prompt = null;
    try testing.expectEqual(Reason.output_stalled, classify(unusual).?);

    // Output that happens to end in "$ " while a command is still waiting for
    // input. Guessing calls it finished; the shell says otherwise.
    var trap = obs("$ cat prices.txt\nitem  $ ");
    trap.at_prompt = false;
    try testing.expectEqual(Reason.output_stalled, classify(trap).?);
    trap.at_prompt = null;
    try testing.expectEqual(Reason.command_complete, classify(trap).?);
}
