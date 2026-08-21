//! amuxd — the always-on terminal host.
//!
//! Owns pseudoterminals and the terminal state their output is parsed into, so
//! sessions exist independently of any GUI. No GTK, no libghostty, no GL: it is
//! meant to run under a systemd user unit with no display.
//!
//! It does not serve the socket yet. That arrives with work-plan item 4, when
//! the request handlers move behind this process. Until then `--self-check`
//! demonstrates that terminal hosting works end to end.

const std = @import("std");
const posix = std.posix;
const Registry = @import("Registry.zig");

const log = std.log.scoped(.amuxd);

/// Set by the signal handler; the main loop polls it.
var shutdown_requested: std.atomic.Value(bool) = .init(false);

pub fn main() !u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--self-check")) return selfCheck(alloc);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage();
            return 0;
        }
        log.err("unknown argument: {s}", .{arg});
        try printUsage();
        return 2;
    }

    return serve(alloc);
}

fn printUsage() !void {
    const usage =
        \\amuxd - the amux terminal daemon
        \\
        \\Usage: amuxd [options]
        \\
        \\Options:
        \\  --self-check   Spawn a shell, run a command, print the screen, exit
        \\  -h, --help     Show this message
        \\
        \\The socket API is not served yet; see docs/plan item 4.
        \\
    ;
    _ = try posix.write(1, usage);
}

/// Run until signalled. Panes outlive every client, so shutdown is the only
/// thing that closes them.
fn serve(alloc: std.mem.Allocator) !u8 {
    var registry = Registry.init(alloc);
    defer registry.deinit();

    installSignalHandlers();

    log.info("amuxd started (pid {d}); no socket yet, idling until signalled", .{
        std.os.linux.getpid(),
    });

    while (!shutdown_requested.load(.acquire)) {
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }

    log.info("shutting down: closing {d} pane(s)", .{registry.count()});
    return 0;
}

/// Prove the terminal hosting works: spawn a shell, run a command through the
/// pty, and read the result back off the parsed screen.
fn selfCheck(alloc: std.mem.Allocator) !u8 {
    var registry = Registry.init(alloc);
    defer registry.deinit();

    const id = try registry.open(.{
        .argv = &.{ "/bin/sh", "-i" },
        .env = &.{ "TERM=xterm-256color", "PS1=$ " },
        .cols = 80,
        .rows = 24,
    });

    const marker = "amuxd_self_check_ok";
    var cmd_buf: [128]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "echo {s}\n", .{marker});
    try registry.write(id, cmd);

    // The shell needs a moment; poll rather than guess a single sleep.
    var found = false;
    var waited_ms: usize = 0;
    while (waited_ms < 5000) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        waited_ms += 100;
        const screen = try registry.snapshot(id, alloc);
        defer alloc.free(screen);
        // Two occurrences means the echoed command and its output; one is just
        // the echo of what we typed.
        if (std.mem.count(u8, screen, marker) >= 2) {
            found = true;
            break;
        }
    }

    const screen = try registry.snapshot(id, alloc);
    defer alloc.free(screen);

    if (!found) {
        log.err("self-check FAILED after {d}ms; screen was:\n{s}", .{ waited_ms, screen });
        return 1;
    }

    log.info("self-check OK in {d}ms: shell ran a command and the daemon read it back off the parsed screen", .{waited_ms});
    return 0;
}

fn installSignalHandlers() void {
    const handler = posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &handler, null);
    posix.sigaction(posix.SIG.INT, &handler, null);
}

fn onSignal(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

test {
    _ = Registry;
    _ = @import("Pane.zig");
    _ = @import("Pty.zig");
}
