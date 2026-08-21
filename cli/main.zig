const std = @import("std");
const posix = std.posix;
const net = std.net;

// --- Buffer sizes -------------------------------------------------------
//
// Request params are built into fixed stack buffers, tiered by what the
// command carries. Overflow is always reported, never truncated.

/// Server-side cap on one request line; keep in sync with `max_request_bytes`
/// in src/socket/server.zig, which rejects anything longer.
const max_request_bytes: usize = 8192;

/// Room reserved for the `{"id":N,"method":"...","params":...}` envelope that
/// wraps the params object. Without this the largest params object would build
/// fine and then fail to fit in the request line.
const request_envelope_reserve: usize = 256;

/// Ids, enums and flags only.
const params_small: usize = 256;
/// Params carrying a short user string: titles, branches, log lines, colours.
const params_medium: usize = 4096;
/// Params carrying arbitrary terminal text: send, run, and the Claude hook.
const params_large: usize = max_request_bytes - request_envelope_reserve;

/// Read granularity when draining a response.
const response_chunk_bytes: usize = 65536;

// Claude Code hook payload fields, extracted from stdin JSON.
const max_hook_stdin: usize = 8192;
const max_session_id: usize = 256;
const max_event_name: usize = 256;
const max_hook_message: usize = 2048;
const max_cwd: usize = 512;

const usage_text =
    \\amux - agent-first terminal multiplexer for AI agents
    \\
    \\Usage: amux <command> [args...]
    \\
    \\Commands:
    \\  ping          Ping the amux server
    \\  identify      Show current focus context
    \\  capabilities  List available API methods
    \\  tree          Show workspace/pane hierarchy
    \\  workspace     Workspace management (list, create, current, select, close, rename,
    \\                  report-git, set-status, clear-status, add-log, clear-log, set-progress, set-pinned, set-color)
    \\  attach        Relay a daemon-owned pane through this terminal
    \\  surface       Surface management (list, current, search, read-text, screen, send-key, split, close)
    \\  pane          Pane management (list, break, join, resize, swap)
    \\  window        Window management (list, current)
    \\  run           Run a command and return output (--surface <id>, --timeout <s>, --prompt-pattern <pat>)
    \\  send          Send text to a surface (--surface <id>, --enter)
    \\  notification  Notification management (create, list, clear)
    \\  palette       Command palette (list, execute)
    \\  history       Terminal history (list, show, search, delete)
    \\  claude-hook   Claude Code integration (session-start, stop, notification, prompt-submit)
    \\
    \\Options:
    \\  --socket <path>  Override socket path
    \\
    \\Environment:
    \\  AMUX_SOCKET       Socket path override
    \\  AMUX_SOCKET_PATH  Socket path override (fallback)
    \\
;

pub fn main() !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    var args = std.process.args();
    _ = args.skip(); // skip program name

    // Check for --socket flag before the subcommand.
    // The wrapper script may pass: amux-cli --socket /path ping
    var socket_override: ?[]const u8 = null;
    var first_arg = args.next() orelse {
        try stdout.writeAll(usage_text);
        return;
    };
    if (std.mem.eql(u8, first_arg, "--socket")) {
        socket_override = args.next();
        first_arg = args.next() orelse {
            try stdout.writeAll(usage_text);
            return;
        };
    }
    const subcommand = first_arg;

    // Determine socket path: --socket flag > env vars > runtime dir > default
    var socket_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const socket_path = resolveSocketPath(socket_override, &socket_path_buf);

    // args iterator now points to the first argument after the subcommand.
    if (std.mem.eql(u8, subcommand, "ping")) {
        try sendAndPrint(socket_path, "system.ping", "{}", stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "identify")) {
        try sendAndPrint(socket_path, "system.identify", "{}", stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "capabilities")) {
        try sendAndPrint(socket_path, "system.capabilities", "{}", stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "tree")) {
        try sendAndPrint(socket_path, "system.tree", "{}", stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "workspace")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            try sendAndPrint(socket_path, "workspace.list", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "create")) {
            // Optional: amux-cli workspace create "My Title"
            const title = args.next();
            if (title) |t| {
                var params_buf: [params_medium]u8 = undefined;
                var p = Params.init(&params_buf);
                p.str("title", t);
                const params = p.finish() orelse {
                    try stderr.writeAll("Title too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.create", params, stdout, stderr);
            } else {
                try sendAndPrint(socket_path, "workspace.create", "{}", stdout, stderr);
            }
        } else if (std.mem.eql(u8, sub, "current")) {
            try sendAndPrint(socket_path, "workspace.current", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "select")) {
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace select <id>\n");
                return;
            };
            const id = argInt(id_str) orelse {
                try stderr.writeAll("Invalid id: must be an integer\n");
                return;
            };
            var params_buf: [params_small]u8 = undefined;
            var p = Params.init(&params_buf);
            p.int("id", id);
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.select", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "close")) {
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace close <id>\n");
                return;
            };
            const id = argInt(id_str) orelse {
                try stderr.writeAll("Invalid id: must be an integer\n");
                return;
            };
            var params_buf: [params_small]u8 = undefined;
            var p = Params.init(&params_buf);
            p.int("id", id);
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.close", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "rename")) {
            // amux-cliworkspace rename [<id>] <title>
            const rename_arg1 = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace rename [<id>] <title>\n");
                return;
            };
            // If there's a second arg, rename_arg1 is the ID and second is the title
            var params_buf: [params_medium]u8 = undefined;
            if (args.next()) |rename_title| {
                const id = argInt(rename_arg1) orelse {
                    try stderr.writeAll("Invalid id: must be an integer\n");
                    return;
                };
                var p = Params.init(&params_buf);
                p.int("id", id);
                p.str("title", rename_title);
                const params = p.finish() orelse {
                    try stderr.writeAll("Title too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.rename", params, stdout, stderr);
            } else {
                var p = Params.init(&params_buf);
                p.str("title", rename_arg1);
                const params = p.finish() orelse {
                    try stderr.writeAll("Title too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.rename", params, stdout, stderr);
            }
        } else if (std.mem.eql(u8, sub, "report-git")) {
            // amux-cliworkspace report-git <id> <branch> [--dirty]
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace report-git <id> <branch> [--dirty]\n");
                return;
            };
            const branch = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace report-git <id> <branch> [--dirty]\n");
                return;
            };
            var dirty = false;
            if (args.next()) |flag| {
                if (std.mem.eql(u8, flag, "--dirty")) dirty = true;
            }
            const id = argInt(id_str) orelse {
                try stderr.writeAll("Invalid id: must be an integer\n");
                return;
            };
            var params_buf: [params_medium]u8 = undefined;
            var p = Params.init(&params_buf);
            p.int("id", id);
            p.str("branch", branch);
            p.boolean("dirty", dirty);
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.report_git", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "set-status")) {
            // amux-cliworkspace set-status <id> <key> <value>
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace set-status <id> <key> <value>\n");
                return;
            };
            const key = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace set-status <id> <key> <value>\n");
                return;
            };
            const value = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace set-status <id> <key> <value>\n");
                return;
            };
            const id = argInt(id_str) orelse {
                try stderr.writeAll("Invalid id: must be an integer\n");
                return;
            };
            var params_buf: [params_medium]u8 = undefined;
            var p = Params.init(&params_buf);
            p.int("id", id);
            p.str("key", key);
            p.str("value", value);
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.set_status", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "clear-status")) {
            // amux-cliworkspace clear-status <id> [key]
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace clear-status <id> [key]\n");
                return;
            };
            const id = argInt(id_str) orelse {
                try stderr.writeAll("Invalid id: must be an integer\n");
                return;
            };
            if (args.next()) |key| {
                var params_buf: [params_medium]u8 = undefined;
                var p = Params.init(&params_buf);
                p.int("id", id);
                p.str("key", key);
                const params = p.finish() orelse {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.clear_status", params, stdout, stderr);
            } else {
                var params_buf: [params_small]u8 = undefined;
                var p = Params.init(&params_buf);
                p.int("id", id);
                const params = p.finish() orelse {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.clear_status", params, stdout, stderr);
            }
        } else if (std.mem.eql(u8, sub, "add-log")) {
            // amux-cliworkspace add-log <id> <text>
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace add-log <id> <text>\n");
                return;
            };
            const text = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace add-log <id> <text>\n");
                return;
            };
            const id = argInt(id_str) orelse {
                try stderr.writeAll("Invalid id: must be an integer\n");
                return;
            };
            var params_buf: [params_medium]u8 = undefined;
            var p = Params.init(&params_buf);
            p.int("id", id);
            p.str("text", text);
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.add_log", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "clear-log")) {
            // amux-cliworkspace clear-log <id>
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace clear-log <id>\n");
                return;
            };
            const id = argInt(id_str) orelse {
                try stderr.writeAll("Invalid id: must be an integer\n");
                return;
            };
            var params_buf: [params_small]u8 = undefined;
            var p = Params.init(&params_buf);
            p.int("id", id);
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.clear_log", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "set-progress")) {
            // amux-cliworkspace set-progress <id> <fraction> [label]
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace set-progress <id> <fraction> [label]\n");
                return;
            };
            const fraction = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace set-progress <id> <fraction> [label]\n");
                return;
            };
            const id = argInt(id_str) orelse {
                try stderr.writeAll("Invalid id: must be an integer\n");
                return;
            };
            const fraction_val = argFloat(fraction) orelse {
                try stderr.writeAll("Invalid fraction: must be a number\n");
                return;
            };
            if (args.next()) |label| {
                var params_buf: [params_medium]u8 = undefined;
                var p = Params.init(&params_buf);
                p.int("id", id);
                p.float("fraction", fraction_val);
                p.str("label", label);
                const params = p.finish() orelse {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.set_progress", params, stdout, stderr);
            } else {
                var params_buf: [params_small]u8 = undefined;
                var p = Params.init(&params_buf);
                p.int("id", id);
                p.float("fraction", fraction_val);
                const params = p.finish() orelse {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.set_progress", params, stdout, stderr);
            }
        } else if (std.mem.eql(u8, sub, "set-pinned")) {
            // amux-cliworkspace set-pinned <id> <true|false>
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace set-pinned <id> <true|false>\n");
                return;
            };
            const val = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace set-pinned <id> <true|false>\n");
                return;
            };
            const id = argInt(id_str) orelse {
                try stderr.writeAll("Invalid id: must be an integer\n");
                return;
            };
            const pinned = argBool(val) orelse {
                try stderr.writeAll("Invalid value: must be true or false\n");
                return;
            };
            var params_buf: [params_small]u8 = undefined;
            var p = Params.init(&params_buf);
            p.int("id", id);
            p.boolean("pinned", pinned);
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.set_pinned", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "set-color")) {
            // amux-cliworkspace set-color <id> <color|clear>
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace set-color <id> <red|blue|green|yellow|purple|orange|pink|cyan|clear>\n");
                return;
            };
            const color_val = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace set-color <id> <red|blue|green|yellow|purple|orange|pink|cyan|clear>\n");
                return;
            };
            const id = argInt(id_str) orelse {
                try stderr.writeAll("Invalid id: must be an integer\n");
                return;
            };
            var params_buf: [params_small]u8 = undefined;
            var p = Params.init(&params_buf);
            p.int("id", id);
            p.str("color", if (std.mem.eql(u8, color_val, "clear")) "" else color_val);
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.set_color", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "next")) {
            try sendAndPrint(socket_path, "workspace.next", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "previous") or std.mem.eql(u8, sub, "prev")) {
            try sendAndPrint(socket_path, "workspace.previous", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "last")) {
            try sendAndPrint(socket_path, "workspace.last", "{}", stdout, stderr);
        } else {
            try stderr.writeAll("Unknown workspace subcommand. Use: list, create, current, select, close, rename,\n  report-git, set-status, clear-status, add-log, clear-log, set-progress, set-pinned, set-color, next, previous, last\n");
        }
    } else if (std.mem.eql(u8, subcommand, "attach")) {
        // amux-cli attach [surface_id]
        //
        // Relays a daemon-owned pane through this terminal: paints what is
        // already on screen, then streams. This is what the GUI runs inside each
        // of its terminal widgets, so the pty stays in the daemon.
        var sid: ?i64 = null;
        if (args.next()) |arg| {
            sid = argInt(arg) orelse {
                try stderr.writeAll("Invalid surface id: must be an integer\n");
                return;
            };
        }
        try attachCommand(socket_path, sid, stderr);
    } else if (std.mem.eql(u8, subcommand, "surface")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            try sendAndPrint(socket_path, "surface.list", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "current")) {
            try sendAndPrint(socket_path, "surface.current", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "search")) {
            const search_text = args.next() orelse {
                try stderr.writeAll("Usage: amux surface search <text>\n");
                return;
            };
            var params_buf: [params_medium]u8 = undefined;
            var p = Params.init(&params_buf);
            p.str("text", search_text);
            const params = p.finish() orelse {
                try stderr.writeAll("Text too long\n");
                return;
            };
            try sendAndPrint(socket_path, "surface.search", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "read-text") or std.mem.eql(u8, sub, "read")) {
            // amux-clisurface read-text [surface_id] [--scrollback]
            var surface_id: ?[]const u8 = null;
            var scrollback = false;
            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "--scrollback")) {
                    scrollback = true;
                } else {
                    surface_id = arg;
                }
            }
            var params_buf: [params_small]u8 = undefined;
            var p = Params.init(&params_buf);
            if (surface_id) |sid| {
                const sid_val = argInt(sid) orelse {
                    try stderr.writeAll("Invalid surface id: must be an integer\n");
                    return;
                };
                p.int("surface_id", sid_val);
            }
            if (scrollback) p.boolean("scrollback", true);
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "surface.read_text", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "screen")) {
            // amux-cli surface screen [surface_id] [--since <seq>] [--timeout <ms>]
            //
            // Cells rather than text: styles, colours and cursor, which is what
            // something drawing the terminal needs. `--since` asks for only the
            // rows that changed, and `--timeout` waits for a change instead of
            // reporting there is none.
            var surface_id: ?[]const u8 = null;
            var since: ?[]const u8 = null;
            var timeout_ms: ?[]const u8 = null;
            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "--since")) {
                    since = args.next() orelse {
                        try stderr.writeAll("--since requires a value\n");
                        return;
                    };
                } else if (std.mem.eql(u8, arg, "--timeout")) {
                    timeout_ms = args.next() orelse {
                        try stderr.writeAll("--timeout requires a value (milliseconds)\n");
                        return;
                    };
                } else {
                    surface_id = arg;
                }
            }
            var params_buf: [params_small]u8 = undefined;
            var p = Params.init(&params_buf);
            if (surface_id) |sid| {
                const sid_val = argInt(sid) orelse {
                    try stderr.writeAll("Invalid surface id: must be an integer\n");
                    return;
                };
                p.int("surface_id", sid_val);
            }
            if (since) |v| {
                const n = argInt(v) orelse {
                    try stderr.writeAll("Invalid --since: must be an integer\n");
                    return;
                };
                p.int("since", n);
            }
            if (timeout_ms) |v| {
                const n = argInt(v) orelse {
                    try stderr.writeAll("Invalid --timeout: must be an integer\n");
                    return;
                };
                p.int("timeout_ms", n);
            }
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "surface.screen", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "send-key")) {
            // amux-clisurface send-key [--surface <id>] <key>
            var surface_id: ?[]const u8 = null;
            var key: ?[]const u8 = null;
            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "--surface")) {
                    surface_id = args.next() orelse {
                        try stderr.writeAll("--surface requires a surface ID\n");
                        return;
                    };
                } else if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') {
                    try stderr.writeAll("Unknown flag: ");
                    try stderr.writeAll(arg);
                    try stderr.writeAll("\nUsage: amux surface send-key [--surface <id>] <key>\n");
                    return;
                } else {
                    key = arg;
                }
            }
            const key_name = key orelse {
                try stderr.writeAll("Usage: amux surface send-key [--surface <id>] <key>\n");
                return;
            };
            var params_buf: [params_small]u8 = undefined;
            var p = Params.init(&params_buf);
            p.str("key", key_name);
            if (surface_id) |sid| {
                const sid_val = argInt(sid) orelse {
                    try stderr.writeAll("Invalid surface id: must be an integer\n");
                    return;
                };
                p.int("surface_id", sid_val);
            }
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "surface.send_key", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "split")) {
            // amux-clisurface split <direction>
            const direction = args.next() orelse {
                try stderr.writeAll("Usage: amux surface split <left|right|up|down>\n");
                return;
            };
            var params_buf: [params_small]u8 = undefined;
            var p = Params.init(&params_buf);
            p.str("direction", direction);
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "surface.split", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "close")) {
            // amux-clisurface close
            try sendAndPrint(socket_path, "surface.close", "{}", stdout, stderr);
        } else {
            try stderr.writeAll("Unknown surface subcommand. Use: list, current, search, read-text, screen, send-key, split, close\n");
        }
    } else if (std.mem.eql(u8, subcommand, "pane")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            try sendAndPrint(socket_path, "pane.list", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "break")) {
            const pane_id = args.next() orelse {
                try stderr.writeAll("Usage: amux pane break <pane_id>\n");
                return;
            };
            const pane_id_val = argInt(pane_id) orelse {
                try stderr.writeAll("Invalid pane_id: must be an integer\n");
                return;
            };
            var params_buf: [params_small]u8 = undefined;
            var p = Params.init(&params_buf);
            p.int("pane_id", pane_id_val);
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "pane.break", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "join")) {
            const pane_id = args.next() orelse {
                try stderr.writeAll("Usage: amux pane join <pane_id> <workspace_id>\n");
                return;
            };
            const workspace_id = args.next() orelse {
                try stderr.writeAll("Usage: amux pane join <pane_id> <workspace_id>\n");
                return;
            };
            const pane_id_val = argInt(pane_id) orelse {
                try stderr.writeAll("Invalid pane_id: must be an integer\n");
                return;
            };
            const ws_id_val = argInt(workspace_id) orelse {
                try stderr.writeAll("Invalid workspace_id: must be an integer\n");
                return;
            };
            var params_buf: [params_small]u8 = undefined;
            var p = Params.init(&params_buf);
            p.int("pane_id", pane_id_val);
            p.int("workspace_id", ws_id_val);
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "pane.join", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "resize")) {
            // amux-clipane resize <pane_id> <direction> [amount]
            const pane_id = args.next() orelse {
                try stderr.writeAll("Usage: amux pane resize <pane_id> <left|right|up|down> [amount]\n");
                return;
            };
            const direction = args.next() orelse {
                try stderr.writeAll("Usage: amux pane resize <pane_id> <left|right|up|down> [amount]\n");
                return;
            };
            const pane_id_val = argInt(pane_id) orelse {
                try stderr.writeAll("Invalid pane_id: must be an integer\n");
                return;
            };
            var params_buf: [params_small]u8 = undefined;
            var p = Params.init(&params_buf);
            p.int("pane_id", pane_id_val);
            p.str("direction", direction);
            if (args.next()) |amount| {
                const amount_val = argFloat(amount) orelse {
                    try stderr.writeAll("Invalid amount: must be a number\n");
                    return;
                };
                p.float("amount", amount_val);
            }
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "pane.resize", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "swap")) {
            // amux-clipane swap <pane_a> <pane_b>
            const pane_a = args.next() orelse {
                try stderr.writeAll("Usage: amux pane swap <pane_a> <pane_b>\n");
                return;
            };
            const pane_b = args.next() orelse {
                try stderr.writeAll("Usage: amux pane swap <pane_a> <pane_b>\n");
                return;
            };
            const pane_a_val = argInt(pane_a) orelse {
                try stderr.writeAll("Invalid pane_a: must be an integer\n");
                return;
            };
            const pane_b_val = argInt(pane_b) orelse {
                try stderr.writeAll("Invalid pane_b: must be an integer\n");
                return;
            };
            var params_buf: [params_small]u8 = undefined;
            var p = Params.init(&params_buf);
            p.int("pane_a", pane_a_val);
            p.int("pane_b", pane_b_val);
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "pane.swap", params, stdout, stderr);
        } else {
            try stderr.writeAll("Unknown pane subcommand. Use: list, break, join, resize, swap\n");
        }
    } else if (std.mem.eql(u8, subcommand, "run")) {
        // amux run [--surface <id>] [--timeout <seconds>] [--prompt-pattern <pat>] <command>
        var surface_id: ?[]const u8 = null;
        var timeout_str: ?[]const u8 = null;
        var prompt_pat: ?[]const u8 = null;
        var run_command: ?[]const u8 = null;

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--surface")) {
                surface_id = args.next() orelse {
                    try stderr.writeAll("--surface requires a value\n");
                    return;
                };
            } else if (std.mem.eql(u8, arg, "--timeout")) {
                timeout_str = args.next() orelse {
                    try stderr.writeAll("--timeout requires a value\n");
                    return;
                };
            } else if (std.mem.eql(u8, arg, "--prompt-pattern")) {
                prompt_pat = args.next() orelse {
                    try stderr.writeAll("--prompt-pattern requires a value\n");
                    return;
                };
            } else {
                run_command = arg;
            }
        }

        const cmd = run_command orelse {
            try stderr.writeAll("Usage: amux run [--surface <id>] [--timeout <s>] [--prompt-pattern <pat>] <command>\n");
            return;
        };

        // Build JSON params
        var params_buf: [params_large]u8 = undefined;
        var p = Params.init(&params_buf);
        p.str("command", cmd);
        if (surface_id) |sid| {
            const sid_val = argInt(sid) orelse {
                try stderr.writeAll("Invalid surface id: must be an integer\n");
                return;
            };
            p.int("surface_id", sid_val);
        }
        if (timeout_str) |t| {
            const timeout_val = argInt(t) orelse {
                try stderr.writeAll("Invalid timeout: must be an integer\n");
                return;
            };
            p.int("timeout", timeout_val);
        }
        if (prompt_pat) |pat| p.str("prompt_pattern", pat);
        const params = p.finish() orelse {
            try stderr.writeAll("Command too long\n");
            return;
        };
        try sendAndPrint(socket_path, "surface.run", params, stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "send")) {
        // amux-clisend [--surface <id>] [--enter] <text>
        var surface_id: ?[]const u8 = null;
        var append_enter = false;
        var text: ?[]const u8 = null;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--surface")) {
                surface_id = args.next() orelse {
                    try stderr.writeAll("--surface requires a surface ID\n");
                    return;
                };
            } else if (std.mem.eql(u8, arg, "--enter")) {
                append_enter = true;
            } else if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') {
                try stderr.writeAll("Unknown flag: ");
                try stderr.writeAll(arg);
                try stderr.writeAll("\nUsage: amux send [--surface <id>] [--enter] <text>\n");
                return;
            } else {
                text = arg;
            }
        }
        const send_text = text orelse {
            try stderr.writeAll("Usage: amux send [--surface <id>] [--enter] <text>\n");
            return;
        };
        // Build params JSON with properly escaped text
        var params_buf: [params_large]u8 = undefined;
        var p = Params.init(&params_buf);
        p.strCat("text", send_text, if (append_enter) "\n" else "");
        if (surface_id) |sid| {
            const sid_val = argInt(sid) orelse {
                try stderr.writeAll("Invalid surface id: must be an integer\n");
                return;
            };
            p.int("surface_id", sid_val);
        }
        const params = p.finish() orelse {
            try stderr.writeAll("Text too long\n");
            return;
        };
        try sendAndPrint(socket_path, "surface.send_text", params, stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "window")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            try sendAndPrint(socket_path, "window.list", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "current")) {
            try sendAndPrint(socket_path, "window.current", "{}", stdout, stderr);
        } else {
            try stderr.writeAll("Unknown window subcommand. Use: list, current\n");
        }
    } else if (std.mem.eql(u8, subcommand, "notification") or std.mem.eql(u8, subcommand, "notify")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            try sendAndPrint(socket_path, "notification.list", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "create")) {
            const title = args.next() orelse {
                try stderr.writeAll("Usage: amux notification create <title> [body]\n");
                return;
            };
            var params_buf: [params_medium]u8 = undefined;
            var p = Params.init(&params_buf);
            p.str("title", title);
            if (args.next()) |body| p.str("body", body);
            const params = p.finish() orelse {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "notification.create", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "clear")) {
            if (args.next()) |id_str| {
                const id = argInt(id_str) orelse {
                    try stderr.writeAll("Invalid id: must be an integer\n");
                    return;
                };
                var params_buf: [params_small]u8 = undefined;
                var p = Params.init(&params_buf);
                p.int("id", id);
                const params = p.finish() orelse {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "notification.clear", params, stdout, stderr);
            } else {
                try sendAndPrint(socket_path, "notification.clear", "{}", stdout, stderr);
            }
        } else {
            try stderr.writeAll("Unknown notification subcommand. Use: create, list, clear\n");
        }
    } else if (std.mem.eql(u8, subcommand, "palette")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            try sendAndPrint(socket_path, "command_palette.list", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "execute") or std.mem.eql(u8, sub, "exec")) {
            const action_name = args.next() orelse {
                try stderr.writeAll("Usage: amux palette execute <action-name>\n");
                return;
            };
            var params_buf: [params_medium]u8 = undefined;
            var p = Params.init(&params_buf);
            p.str("action", action_name);
            const params = p.finish() orelse {
                try stderr.writeAll("Action name too long\n");
                return;
            };
            try sendAndPrint(socket_path, "command_palette.execute", params, stdout, stderr);
        } else {
            try stderr.writeAll("Unknown palette subcommand. Use: list, execute\n");
        }
    } else if (std.mem.eql(u8, subcommand, "claude-hook")) {
        // Claude Code hook integration. Reads JSON payload from stdin.
        // Usage: amux-cli claude-hook <session-start|stop|notification|prompt-submit>
        const hook_sub = args.next() orelse {
            try stderr.writeAll("Usage: amux claude-hook <session-start|stop|notification|prompt-submit>\n");
            return;
        };

        // Read stdin (Claude Code pipes hook JSON payload via stdin)
        var stdin_buf: [max_hook_stdin]u8 = undefined;
        var stdin_len: usize = 0;
        const stdin = std.fs.File.stdin();
        while (stdin_len < stdin_buf.len) {
            const n = stdin.read(stdin_buf[stdin_len..]) catch break;
            if (n == 0) break;
            stdin_len += n;
        }

        // Extract fields from stdin JSON into stack buffers.
        var sid_buf: [max_session_id]u8 = undefined;
        var sid_len: usize = 0;
        var msg_buf: [max_hook_message]u8 = undefined;
        var msg_len: usize = 0;
        var evt_buf: [max_event_name]u8 = undefined;
        var evt_len: usize = 0;
        var cwd_buf: [max_cwd]u8 = undefined;
        var cwd_len: usize = 0;

        if (stdin_len > 0) {
            // A malformed payload should not fail the hook -- the workspace/surface
            // ids come from the environment, not stdin -- but swallowing it
            // silently made a broken payload look like an empty one.
            const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, stdin_buf[0..stdin_len], .{}) catch |err| blk: {
                try stderr.writeAll("Warning: could not parse hook JSON from stdin (");
                try stderr.writeAll(@errorName(err));
                try stderr.writeAll("); continuing without its fields\n");
                break :blk null;
            };
            if (parsed) |p| {
                defer p.deinit();
                if (p.value == .object) {
                    if (extractJsonString(p.value, &[_][]const u8{ "session_id", "sessionId" })) |s| {
                        sid_len = @min(s.len, sid_buf.len);
                        @memcpy(sid_buf[0..sid_len], s[0..sid_len]);
                    }
                    if (extractJsonString(p.value, &[_][]const u8{ "message", "body", "text", "prompt", "error", "description" })) |s| {
                        msg_len = @min(s.len, msg_buf.len);
                        @memcpy(msg_buf[0..msg_len], s[0..msg_len]);
                    }
                    if (extractJsonString(p.value, &[_][]const u8{ "event", "event_name", "hook_event_name", "type", "kind" })) |s| {
                        evt_len = @min(s.len, evt_buf.len);
                        @memcpy(evt_buf[0..evt_len], s[0..evt_len]);
                    }
                    if (extractJsonString(p.value, &[_][]const u8{ "cwd", "working_directory", "project_dir" })) |s| {
                        cwd_len = @min(s.len, cwd_buf.len);
                        @memcpy(cwd_buf[0..cwd_len], s[0..cwd_len]);
                    }

                    // Also check nested .notification and .data objects
                    if (sid_len == 0) {
                        for ([_][]const u8{ "notification", "data", "session", "context" }) |ns| {
                            if (p.value.object.get(ns)) |nested| {
                                if (nested == .object) {
                                    if (extractJsonString(nested, &[_][]const u8{ "session_id", "sessionId", "id" })) |s| {
                                        sid_len = @min(s.len, sid_buf.len);
                                        @memcpy(sid_buf[0..sid_len], s[0..sid_len]);
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    if (msg_len == 0) {
                        for ([_][]const u8{ "notification", "data" }) |ns| {
                            if (p.value.object.get(ns)) |nested| {
                                if (nested == .object) {
                                    if (extractJsonString(nested, &[_][]const u8{ "message", "body", "text" })) |s| {
                                        msg_len = @min(s.len, msg_buf.len);
                                        @memcpy(msg_buf[0..msg_len], s[0..msg_len]);
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        const session_id: ?[]const u8 = if (sid_len > 0) sid_buf[0..sid_len] else null;
        const message: ?[]const u8 = if (msg_len > 0) msg_buf[0..msg_len] else null;
        const event: ?[]const u8 = if (evt_len > 0) evt_buf[0..evt_len] else null;
        const cwd_val: ?[]const u8 = if (cwd_len > 0) cwd_buf[0..cwd_len] else null;

        // Get workspace_id and surface_id from env vars
        const ws_id = posix.getenv("AMUX_WORKSPACE_ID");
        const surface_id = posix.getenv("AMUX_SURFACE_ID");

        // Build params JSON. The workspace/surface ids come from the environment
        // amux injects into each pane; if they are missing or malformed, omit them
        // rather than emitting an invalid JSON number.
        var params_buf: [params_large]u8 = undefined;
        var p = Params.init(&params_buf);
        p.str("subcommand", hook_sub);
        if (session_id) |sid| p.str("session_id", sid);
        if (ws_id) |w| {
            if (argInt(w)) |v| p.int("workspace_id", v);
        }
        if (surface_id) |sf| {
            if (argInt(sf)) |v| p.int("surface_id", v);
        }
        if (message) |m| p.str("message", m);
        if (event) |e| p.str("event", e);
        if (cwd_val) |cv| p.str("cwd", cv);
        const params = p.finish() orelse {
            try stderr.writeAll("Hook payload too long\n");
            return;
        };
        try sendAndPrint(socket_path, "claude.hook", params, stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "history")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            // Optional: --workspace <id> --limit <n>
            var params_buf: [params_medium]u8 = undefined;
            var params: []const u8 = "{}";
            // Check for optional flags
            var ws_id_str: ?[]const u8 = null;
            var limit_str: ?[]const u8 = null;
            while (args.next()) |flag| {
                if (std.mem.eql(u8, flag, "--workspace")) {
                    ws_id_str = args.next();
                } else if (std.mem.eql(u8, flag, "--limit")) {
                    limit_str = args.next();
                }
            }
            if (ws_id_str != null or limit_str != null) {
                var p = Params.init(&params_buf);
                if (ws_id_str) |ws_id| {
                    const ws_val = argInt(ws_id) orelse {
                        try stderr.writeAll("Invalid --workspace: must be an integer\n");
                        return;
                    };
                    p.int("workspace_id", ws_val);
                }
                if (limit_str) |limit| {
                    const limit_val = argInt(limit) orelse {
                        try stderr.writeAll("Invalid --limit: must be an integer\n");
                        return;
                    };
                    p.int("limit", limit_val);
                }
                params = p.finish() orelse {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
            }
            try sendAndPrint(socket_path, "history.list", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "show")) {
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux history show <id>\n");
                return;
            };
            var params_buf: [params_medium]u8 = undefined;
            var p = Params.init(&params_buf);
            p.str("id", id_str);
            const params = p.finish() orelse {
                try stderr.writeAll("ID too long\n");
                return;
            };
            try sendAndPrint(socket_path, "history.show", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "search")) {
            const query = args.next() orelse {
                try stderr.writeAll("Usage: amux history search <query>\n");
                return;
            };
            var params_buf: [params_medium]u8 = undefined;
            var p = Params.init(&params_buf);
            p.str("query", query);
            const params = p.finish() orelse {
                try stderr.writeAll("Query too long\n");
                return;
            };
            try sendAndPrint(socket_path, "history.search", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "delete")) {
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux history delete <id>\n");
                return;
            };
            var params_buf: [params_medium]u8 = undefined;
            var p = Params.init(&params_buf);
            p.str("id", id_str);
            const params = p.finish() orelse {
                try stderr.writeAll("ID too long\n");
                return;
            };
            try sendAndPrint(socket_path, "history.delete", params, stdout, stderr);
        } else {
            try stderr.writeAll("Unknown history subcommand: ");
            try stderr.writeAll(sub);
            try stderr.writeAll("\nAvailable: list, show, search, delete\n");
        }
    } else {
        try stderr.writeAll("Unknown command: ");
        try stderr.writeAll(subcommand);
        try stderr.writeAll("\nRun 'amux-cli' for usage.\n");
    }
}

/// Extract a string from a JSON object, trying multiple key names.
fn extractJsonString(obj: std.json.Value, keys: []const []const u8) ?[]const u8 {
    if (obj != .object) return null;
    for (keys) |key| {
        if (obj.object.get(key)) |val| {
            if (val == .string) return val.string;
        }
    }
    return null;
}

/// Builds a JSON params object safely.
///
/// Every string value is JSON-escaped and every numeric/boolean value is
/// validated before it reaches the wire, so user input containing quotes,
/// backslashes, newlines or non-numeric text can no longer produce malformed
/// JSON (or inject extra keys into the request).
///
/// Overflow is tracked rather than thrown: `finish()` returns null if the
/// object did not fit, so callers report one consistent error.
const Params = struct {
    buf: []u8,
    len: usize = 0,
    overflow: bool = false,
    first: bool = true,

    fn init(buf: []u8) Params {
        return .{ .buf = buf };
    }

    fn putByte(self: *Params, ch: u8) void {
        if (self.len >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.len] = ch;
        self.len += 1;
    }

    fn putAll(self: *Params, text: []const u8) void {
        for (text) |ch| self.putByte(ch);
    }

    fn putKey(self: *Params, key: []const u8) void {
        self.putByte(if (self.first) '{' else ',');
        self.first = false;
        self.putByte('"');
        self.putAll(key);
        self.putAll("\":");
    }

    /// Add a JSON-escaped string value.
    fn str(self: *Params, key: []const u8, value: []const u8) void {
        self.putKey(key);
        self.putByte('"');
        self.escapeInto(value);
        self.putByte('"');
    }

    /// Add a JSON-escaped string value assembled from two parts.
    fn strCat(self: *Params, key: []const u8, head: []const u8, tail: []const u8) void {
        self.putKey(key);
        self.putByte('"');
        self.escapeInto(head);
        self.escapeInto(tail);
        self.putByte('"');
    }

    fn escapeInto(self: *Params, value: []const u8) void {
        for (value) |ch| {
            switch (ch) {
                '"' => self.putAll("\\\""),
                '\\' => self.putAll("\\\\"),
                '\n' => self.putAll("\\n"),
                '\r' => self.putAll("\\r"),
                '\t' => self.putAll("\\t"),
                else => {
                    if (ch < 0x20) {
                        var hex: [6]u8 = undefined;
                        const written = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{ch}) catch {
                            self.overflow = true;
                            return;
                        };
                        self.putAll(written);
                    } else {
                        self.putByte(ch);
                    }
                },
            }
        }
    }

    fn int(self: *Params, key: []const u8, value: i64) void {
        self.putKey(key);
        var num: [24]u8 = undefined;
        const written = std.fmt.bufPrint(&num, "{d}", .{value}) catch {
            self.overflow = true;
            return;
        };
        self.putAll(written);
    }

    fn float(self: *Params, key: []const u8, value: f64) void {
        self.putKey(key);
        // `{d}` prints floats without an exponent, so f64's full range needs
        // room for ~310 integer digits plus a fractional tail.
        var num: [512]u8 = undefined;
        const written = std.fmt.bufPrint(&num, "{d}", .{value}) catch {
            self.overflow = true;
            return;
        };
        self.putAll(written);
    }

    fn boolean(self: *Params, key: []const u8, value: bool) void {
        self.putKey(key);
        self.putAll(if (value) "true" else "false");
    }

    /// Finish the object. Returns null if it did not fit in the buffer.
    fn finish(self: *Params) ?[]const u8 {
        if (self.first) self.putByte('{');
        self.putByte('}');
        if (self.overflow) return null;
        return self.buf[0..self.len];
    }
};

/// Where to find the server.
///
/// The runtime-directory probe is what lets a systemd-activated daemon be found
/// with no configuration: the unit listens on `$XDG_RUNTIME_DIR/amux.sock`. It
/// is a probe rather than an unconditional preference so that a GUI still
/// serving `/tmp/amux.sock` keeps working.
fn resolveSocketPath(override: ?[]const u8, buf: []u8) []const u8 {
    const default = "/tmp/amux.sock";
    if (override) |o| return o;
    if (posix.getenv("AMUX_SOCKET")) |v| return v;
    if (posix.getenv("AMUX_SOCKET_PATH")) |v| return v;
    if (posix.getenv("XDG_RUNTIME_DIR")) |dir| {
        const candidate = std.fmt.bufPrint(buf, "{s}/amux.sock", .{dir}) catch return default;
        std.fs.accessAbsolute(candidate, .{}) catch return default;
        return candidate;
    }
    return default;
}

/// Parse a CLI argument that must reach the server as a JSON number.
fn argInt(text: []const u8) ?i64 {
    return std.fmt.parseInt(i64, text, 10) catch null;
}

/// Parse a CLI argument that must reach the server as a JSON float.
///
/// `parseFloat` accepts "nan", "inf" and "infinity", but JSON has no literal
/// for either -- they would be emitted as bare tokens and make the whole
/// request unparseable. Reject them here so the user gets a clear message.
fn argFloat(text: []const u8) ?f64 {
    const value = std.fmt.parseFloat(f64, text) catch return null;
    if (!std.math.isFinite(value)) return null;
    return value;
}

/// Parse a CLI argument that must reach the server as a JSON boolean.
fn argBool(text: []const u8) ?bool {
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1") or
        std.mem.eql(u8, text, "yes")) return true;
    if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0") or
        std.mem.eql(u8, text, "no")) return false;
    return null;
}

var next_req_id: i64 = 1;

fn sendAndPrint(socket_path: []const u8, method: []const u8, params: []const u8, stdout: std.fs.File, stderr: std.fs.File) !void {
    // Connect to socket
    const addr = net.Address.initUnix(socket_path) catch {
        try stderr.writeAll("Failed to create socket address\n");
        return;
    };
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch {
        try stderr.writeAll("Failed to create socket\n");
        return;
    };
    defer posix.close(fd);

    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
        try stderr.writeAll("Failed to connect to amux (is it running?)\n");
        try stderr.writeAll("Socket path: ");
        try stderr.writeAll(socket_path);
        try stderr.writeAll("\n");
        return;
    };

    const stream = net.Stream{ .handle = fd };

    // Build and send request
    const id = next_req_id;
    next_req_id += 1;

    var req_buf: [max_request_bytes]u8 = undefined;
    const req_line = std.fmt.bufPrint(&req_buf,
        \\{{"id":{d},"method":"{s}","params":{s}}}
    , .{ id, method, params }) catch {
        try stderr.writeAll("Request too large\n");
        return;
    };

    stream.writeAll(req_line) catch {
        try stderr.writeAll("Failed to send request\n");
        return;
    };
    stream.writeAll("\n") catch {};

    // Read the response. Responses are newline-delimited and can be far larger
    // than any single read() returns (scrollback reads, `history show`), so keep
    // reading until the delimiter arrives instead of printing a truncated chunk.
    const alloc = std.heap.page_allocator;
    var response_buf: std.ArrayListUnmanaged(u8) = .{};
    defer response_buf.deinit(alloc);

    var chunk: [response_chunk_bytes]u8 = undefined;
    while (true) {
        const n = stream.read(&chunk) catch {
            try stderr.writeAll("Failed to read response\n");
            return;
        };
        if (n == 0) break; // server closed
        response_buf.appendSlice(alloc, chunk[0..n]) catch {
            try stderr.writeAll("Response too large\n");
            return;
        };
        if (std.mem.indexOfScalar(u8, chunk[0..n], '\n') != null) break;
    }

    if (response_buf.items.len == 0) {
        try stderr.writeAll("Empty response from server\n");
        return;
    }

    // Trim trailing newline
    var response: []const u8 = response_buf.items;
    while (response.len > 0 and (response[response.len - 1] == '\n' or response[response.len - 1] == '\r')) {
        response = response[0 .. response.len - 1];
    }

    try stdout.writeAll(response);
    try stdout.writeAll("\n");
}

// ------------------------------------------------------------------
// attach: relay a daemon-owned pane through this terminal
// ------------------------------------------------------------------

/// A connection held open across many requests.
///
/// The daemon serves newline-delimited requests in a loop per connection, so a
/// relay can keep one rather than reconnecting for every keystroke.
const Conn = struct {
    stream: net.Stream,
    alloc: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .{},

    fn open(alloc: std.mem.Allocator, socket_path: []const u8) !Conn {
        const addr = try net.Address.initUnix(socket_path);
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);
        try posix.connect(fd, &addr.any, addr.getOsSockLen());
        return .{ .stream = .{ .handle = fd }, .alloc = alloc };
    }

    fn close(self: *Conn) void {
        self.buf.deinit(self.alloc);
        posix.close(self.stream.handle);
    }

    /// Send one request and return its response line, valid until the next call.
    fn call(self: *Conn, method: []const u8, params: []const u8) ![]const u8 {
        var req_buf: [max_request_bytes]u8 = undefined;
        const line = try std.fmt.bufPrint(&req_buf,
            \\{{"id":1,"method":"{s}","params":{s}}}
        , .{ method, params });
        try self.stream.writeAll(line);
        try self.stream.writeAll("\n");

        self.buf.clearRetainingCapacity();
        var chunk: [response_chunk_bytes]u8 = undefined;
        while (true) {
            const n = try self.stream.read(&chunk);
            if (n == 0) return error.ConnectionClosed;
            try self.buf.appendSlice(self.alloc, chunk[0..n]);
            if (std.mem.indexOfScalar(u8, chunk[0..n], '\n') != null) break;
        }
        var line_out: []const u8 = self.buf.items;
        while (line_out.len > 0 and (line_out[line_out.len - 1] == '\n' or line_out[line_out.len - 1] == '\r')) {
            line_out = line_out[0 .. line_out.len - 1];
        }
        return line_out;
    }
};

/// Shared between the relay's two directions.
const Relay = struct {
    socket_path: []const u8,
    surface_id: ?i64,
    running: std.atomic.Value(bool) = .init(true),

    /// Params naming just the surface: what attaching sends, since omitting the
    /// offset is what asks for a repaint.
    fn attachParams(self: *const Relay, buf: []u8) ?[]const u8 {
        var p = Params.init(buf);
        if (self.surface_id) |sid| p.int("surface_id", sid);
        return p.finish();
    }
};

/// stdin -> daemon. Runs on its own thread because both directions block: this
/// one on the terminal, the other on the daemon.
fn relayInput(relay: *Relay) void {
    const alloc = std.heap.page_allocator;
    var conn = Conn.open(alloc, relay.socket_path) catch return;
    defer conn.close();

    var in: [4096]u8 = undefined;
    // Sized for the largest read above: base64 is four bytes per three, and the
    // params object adds the surface id and the quoting around it.
    var encoded: [4096 * 4 / 3 + 64]u8 = undefined;
    var params_buf: [encoded.len + 128]u8 = undefined;

    const stdin = std.fs.File{ .handle = posix.STDIN_FILENO };
    while (relay.running.load(.acquire)) {
        const n = stdin.read(&in) catch break;
        if (n == 0) break;

        const b64len = std.base64.standard.Encoder.calcSize(n);
        if (b64len > encoded.len) continue;
        _ = std.base64.standard.Encoder.encode(encoded[0..b64len], in[0..n]);

        var p = Params.init(&params_buf);
        if (relay.surface_id) |sid| p.int("surface_id", sid);
        p.str("data", encoded[0..b64len]);
        const params = p.finish() orelse continue;

        _ = conn.call("surface.input", params) catch break;
    }
    relay.running.store(false, .release);
}

/// This terminal's size, or null if it is not a terminal.
fn terminalSize() ?struct { cols: u16, rows: u16 } {
    var ws: posix.winsize = undefined;
    switch (posix.errno(std.c.ioctl(posix.STDIN_FILENO, posix.T.IOCGWINSZ, &ws))) {
        .SUCCESS => {},
        else => return null,
    }
    if (ws.col == 0 or ws.row == 0) return null;
    return .{ .cols = ws.col, .rows = ws.row };
}

/// Tell the daemon how big this terminal is.
///
/// The attached client owns the size: the daemon paints row by row with explicit
/// positioning, so a pane sized differently from the window puts content in the
/// wrong places rather than merely looking cramped.
fn sendResize(conn: *Conn, surface_id: ?i64, cols: u16, rows: u16) bool {
    var buf: [96]u8 = undefined;
    var p = Params.init(&buf);
    if (surface_id) |sid| p.int("surface_id", sid);
    p.int("cols", @intCast(cols));
    p.int("rows", @intCast(rows));
    const params = p.finish() orelse return false;
    _ = conn.call("surface.resize", params) catch return false;
    return true;
}

/// Put the terminal in raw mode so keystrokes reach the daemon unchanged.
///
/// Without this the local line discipline would echo, buffer until Enter, and
/// turn Ctrl-C into a signal for the relay instead of a byte for the pane. The
/// pane's own terminal state is the one that decides what those mean.
fn rawMode() ?posix.termios {
    const saved = posix.tcgetattr(posix.STDIN_FILENO) catch return null;
    var raw = saved;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.oflag.OPOST = false;
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw) catch return null;
    return saved;
}

fn attachCommand(socket_path: []const u8, surface_id: ?i64, stderr: std.fs.File) !void {
    const alloc = std.heap.page_allocator;

    var out_conn = Conn.open(alloc, socket_path) catch {
        try stderr.writeAll("Failed to connect to amux (is it running?)\n");
        return;
    };
    defer out_conn.close();

    var relay: Relay = .{ .socket_path = socket_path, .surface_id = surface_id };

    const saved = rawMode();
    defer if (saved) |s| posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, s) catch {};

    const stdout = std.fs.File{ .handle = posix.STDOUT_FILENO };

    // Attach: no offset asks for a repaint of what is already on screen, plus
    // the offset to stream from. Streaming alone would show an empty terminal
    // until the program next wrote something.
    var offset: i64 = 0;
    var decode_buf: std.ArrayListUnmanaged(u8) = .{};
    defer decode_buf.deinit(alloc);

    // Match the pane to this window before painting it, so the paint is built
    // for the size it is about to be drawn at.
    var size = terminalSize();
    if (size) |sz| _ = sendResize(&out_conn, surface_id, sz.cols, sz.rows);

    var params_buf: [128]u8 = undefined;
    {
        const params = relay.attachParams(&params_buf) orelse return;
        const resp = out_conn.call("surface.output", params) catch {
            try stderr.writeAll("Failed to attach\n");
            return;
        };
        offset = try writeRelayChunk(alloc, resp, stdout, &decode_buf, stderr) orelse return;
    }

    const input_thread = std.Thread.spawn(.{}, relayInput, .{&relay}) catch null;
    defer if (input_thread) |t| t.detach();

    while (relay.running.load(.acquire)) {
        // A window that changed size needs the pane resized and repainted.
        // Checked on each pass rather than driven by SIGWINCH: the wait below is
        // where this thread spends its time, and a signal landing in the middle
        // of it would have to be turned into something the loop could see
        // anyway. One ioctl a second is cheaper than that machinery.
        if (terminalSize()) |now| {
            const changed = if (size) |was| was.cols != now.cols or was.rows != now.rows else true;
            if (changed) {
                size = now;
                if (sendResize(&out_conn, relay.surface_id, now.cols, now.rows)) {
                    // Repaint at the new size: offsets from before the resize
                    // describe a differently shaped screen.
                    const attach = relay.attachParams(&params_buf) orelse break;
                    const resp = out_conn.call("surface.output", attach) catch break;
                    const next = writeRelayChunk(alloc, resp, stdout, &decode_buf, stderr) catch break;
                    offset = next orelse break;
                    continue;
                }
            }
        }

        var p = Params.init(&params_buf);
        if (relay.surface_id) |sid| p.int("surface_id", sid);
        p.int("offset", offset);
        // Short enough that a resize is noticed promptly, long enough that an
        // idle pane costs about one request a second.
        p.int("timeout_ms", 1000);
        const params = p.finish() orelse break;

        const resp = out_conn.call("surface.output", params) catch break;
        const next = writeRelayChunk(alloc, resp, stdout, &decode_buf, stderr) catch break;
        offset = next orelse break;
    }
    relay.running.store(false, .release);
}

/// Decode one `surface.output` reply onto the terminal. Returns the offset to
/// continue from, or null when the relay should stop.
fn writeRelayChunk(
    alloc: std.mem.Allocator,
    resp: []const u8,
    stdout: std.fs.File,
    decode_buf: *std.ArrayListUnmanaged(u8),
    stderr: std.fs.File,
) !?i64 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, resp, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;

    if (root.object.get("ok")) |ok| {
        if (ok == .bool and !ok.bool) {
            // The pane is gone: say so on the terminal, since this relay is
            // running inside a window someone is looking at.
            try stderr.writeAll("\r\n[amux: pane is gone]\r\n");
            return null;
        }
    }
    const result = root.object.get("result") orelse return null;
    if (result != .object) return null;

    const offset: i64 = if (result.object.get("offset")) |v| switch (v) {
        .integer => |i| i,
        else => return null,
    } else return null;

    if (result.object.get("data")) |d| {
        if (d == .string and d.string.len > 0) {
            const n = std.base64.standard.Decoder.calcSizeForSlice(d.string) catch return offset;
            try decode_buf.resize(alloc, n);
            std.base64.standard.Decoder.decode(decode_buf.items, d.string) catch return offset;
            try stdout.writeAll(decode_buf.items);
        }
    }

    if (result.object.get("exited")) |e| {
        if (e == .bool and e.bool) {
            try stderr.writeAll("\r\n[amux: pane exited]\r\n");
            return null;
        }
    }
    return offset;
}
