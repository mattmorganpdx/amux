//! amuxd — the always-on terminal host.
//!
//! Owns pseudoterminals and the terminal state their output is parsed into, so
//! sessions exist independently of any GUI. No GTK, no libghostty, no GL: it is
//! meant to run under a systemd user unit with no display.
//!
//! It serves the amux socket protocol, so `amux-cli` talks to it directly and
//! sessions no longer depend on a GUI being open. `--self-check` still
//! demonstrates terminal hosting on its own.

const std = @import("std");
const posix = std.posix;
const Registry = @import("daemon/Registry.zig");
const History = @import("daemon/History.zig");
const Server = @import("daemon/server.zig");
const State = @import("daemon/State.zig");
const session = @import("session.zig");

// `zig build test` collects tests from this file's direct imports only, so a
// file reached one level deeper -- session.zig, via State -- was silently
// contributing none. Naming it here puts its tests in the daemon suite.
test {
    _ = session;
    _ = @import("daemon/notifications.zig");
}

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
        \\Environment:
        \\  AMUX_SOCKET       Socket path override
        \\  AMUX_SOCKET_PATH  Socket path override (fallback)
        \\
    ;
    _ = try posix.write(1, usage);
}

/// Run until signalled. Panes outlive every client, so shutdown is the only
/// thing that closes them.
fn serve(alloc: std.mem.Allocator) !u8 {
    var state = State.init(alloc);
    defer state.deinit();

    // Before any pane is spawned: restore and the initial-workspace path both
    // create panes, and they need AMUX_SOCKET_PATH in their environment.
    const sock = socketPath();
    state.socket_path = sock;
    // Scope the session file to this socket before anything reads or writes it,
    // so a daemon on its own socket cannot overwrite the GUI's layout.
    session.bindInstance(sock);

    var hist_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var history: ?History = null;
    if (historyPath(&hist_path_buf)) |hp| {
        // sqlite will create the file but not the directory holding it.
        if (std.fs.path.dirname(hp)) |dir| std.fs.cwd().makePath(dir) catch {};
        if (History.open(alloc, hp)) |h| {
            history = h;
            state.history = &history.?;
            log.info("session archive at {s}", .{hp});
        } else |err| {
            log.warn("could not open session archive: {}", .{err});
        }
    }
    defer if (history) |*h| h.close();

    const restored = state.restoreSession() catch |err| blk: {
        log.warn("could not restore session: {}", .{err});
        break :blk 0;
    };
    if (restored == 0) {
        // Always come up with somewhere to work.
        _ = state.createWorkspace(null, null) catch |err| {
            log.err("could not create initial workspace: {}", .{err});
            return 1;
        };
    }

    const server = try Server.init(alloc, &state, sock);
    defer server.deinit();
    try server.start();

    installSignalHandlers();
    log.info("amuxd ready (pid {d}), {d} workspace(s)", .{
        std.os.linux.getpid(),
        state.workspaceCount(),
    });

    while (!shutdown_requested.load(.acquire)) {
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }

    log.info("shutting down", .{});
    // Before anything is torn down: a client parked in a long poll is holding
    // the registry it is about to lose.
    state.stopWaiters();
    // Scrollback only exists while the terminal does, so capture it before the
    // panes go away with the process.
    state.archiveAll("daemon_exit");
    state.saveSession() catch |err| log.warn("could not save session: {}", .{err});
    return 0;
}

/// Where the session archive lives, alongside the session file.
fn historyPath(buf: []u8) ?[]const u8 {
    if (posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/amux/history.db", .{xdg}) catch null;
    }
    if (posix.getenv("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.config/amux/history.db", .{home}) catch null;
    }
    return null;
}

/// Same resolution order the CLI uses.
fn socketPath() []const u8 {
    return @import("socket_path.zig").forServer();
}

/// Prove the terminal hosting works: spawn a shell, run a command through the
/// pty, and read the result back off the parsed screen.
fn selfCheck(alloc: std.mem.Allocator) !u8 {
    var registry = Registry.init(alloc);
    defer registry.deinit();

    const id: u64 = 1;
    try registry.open(id, .{
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
    _ = State;
    _ = @import("daemon/handlers.zig");
    _ = @import("daemon/server.zig");
    _ = @import("daemon/Pane.zig");
    _ = @import("daemon/Pty.zig");
    _ = @import("daemon/State.zig");
    _ = @import("daemon/History.zig");
}
