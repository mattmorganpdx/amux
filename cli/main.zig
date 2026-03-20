const std = @import("std");
const posix = std.posix;
const net = std.net;

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
    \\  surface       Surface management (list, current, search, read-text, send-key, split, close)
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

    // Determine socket path: --socket flag > env vars > default
    const socket_path = socket_override orelse
        posix.getenv("AMUX_SOCKET") orelse
        posix.getenv("AMUX_SOCKET_PATH") orelse
        "/tmp/amux.sock";

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
                var params_buf: [4096]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"title\":\"{s}\"}}", .{t}) catch {
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
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s}}}", .{id_str}) catch {
                try stderr.writeAll("Invalid id\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.select", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "close")) {
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux workspace close <id>\n");
                return;
            };
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s}}}", .{id_str}) catch {
                try stderr.writeAll("Invalid id\n");
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
            var params_buf: [4096]u8 = undefined;
            if (args.next()) |rename_title| {
                const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"title\":\"{s}\"}}", .{ rename_arg1, rename_title }) catch {
                    try stderr.writeAll("Title too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.rename", params, stdout, stderr);
            } else {
                const params = std.fmt.bufPrint(&params_buf, "{{\"title\":\"{s}\"}}", .{rename_arg1}) catch {
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
            var params_buf: [4096]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"branch\":\"{s}\",\"dirty\":{s}}}", .{
                id_str,
                branch,
                if (dirty) "true" else "false",
            }) catch {
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
            var params_buf: [4096]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"key\":\"{s}\",\"value\":\"{s}\"}}", .{ id_str, key, value }) catch {
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
            if (args.next()) |key| {
                var params_buf: [4096]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"key\":\"{s}\"}}", .{ id_str, key }) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.clear_status", params, stdout, stderr);
            } else {
                var params_buf: [256]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s}}}", .{id_str}) catch {
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
            var params_buf: [4096]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"text\":\"{s}\"}}", .{ id_str, text }) catch {
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
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s}}}", .{id_str}) catch {
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
            if (args.next()) |label| {
                var params_buf: [4096]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"fraction\":{s},\"label\":\"{s}\"}}", .{ id_str, fraction, label }) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.set_progress", params, stdout, stderr);
            } else {
                var params_buf: [256]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"fraction\":{s}}}", .{ id_str, fraction }) catch {
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
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"pinned\":{s}}}", .{ id_str, val }) catch {
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
            var params_buf: [256]u8 = undefined;
            const params = if (std.mem.eql(u8, color_val, "clear"))
                std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"color\":\"\"}}", .{id_str}) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                }
            else
                std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"color\":\"{s}\"}}", .{ id_str, color_val }) catch {
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
            var params_buf: [4096]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"text\":\"{s}\"}}", .{search_text}) catch {
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
            var params_buf: [256]u8 = undefined;
            const params = if (surface_id) |sid|
                if (scrollback)
                    std.fmt.bufPrint(&params_buf, "{{\"surface_id\":{s},\"scrollback\":true}}", .{sid}) catch {
                        try stderr.writeAll("Params too long\n");
                        return;
                    }
                else
                    std.fmt.bufPrint(&params_buf, "{{\"surface_id\":{s}}}", .{sid}) catch {
                        try stderr.writeAll("Params too long\n");
                        return;
                    }
            else if (scrollback)
                "{\"scrollback\":true}"
            else
                "{}";
            try sendAndPrint(socket_path, "surface.read_text", params, stdout, stderr);
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
            var params_buf: [256]u8 = undefined;
            const params = if (surface_id) |sid|
                std.fmt.bufPrint(&params_buf, "{{\"key\":\"{s}\",\"surface_id\":{s}}}", .{ key_name, sid }) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                }
            else
                std.fmt.bufPrint(&params_buf, "{{\"key\":\"{s}\"}}", .{key_name}) catch {
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
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"direction\":\"{s}\"}}", .{direction}) catch {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "surface.split", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "close")) {
            // amux-clisurface close
            try sendAndPrint(socket_path, "surface.close", "{}", stdout, stderr);
        } else {
            try stderr.writeAll("Unknown surface subcommand. Use: list, current, search, read-text, send-key, split, close\n");
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
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"pane_id\":{s}}}", .{pane_id}) catch {
                try stderr.writeAll("Invalid pane_id\n");
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
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"pane_id\":{s},\"workspace_id\":{s}}}", .{ pane_id, workspace_id }) catch {
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
            if (args.next()) |amount| {
                var params_buf: [256]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"pane_id\":{s},\"direction\":\"{s}\",\"amount\":{s}}}", .{ pane_id, direction, amount }) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "pane.resize", params, stdout, stderr);
            } else {
                var params_buf: [256]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"pane_id\":{s},\"direction\":\"{s}\"}}", .{ pane_id, direction }) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "pane.resize", params, stdout, stderr);
            }
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
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"pane_a\":{s},\"pane_b\":{s}}}", .{ pane_a, pane_b }) catch {
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
        var params_buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&params_buf);
        const writer = fbs.writer();
        try writer.writeAll("{\"command\":\"");
        try writeJsonEscaped(writer, cmd);
        try writer.writeByte('"');
        if (surface_id) |sid| {
            try writer.print(",\"surface_id\":{s}", .{sid});
        }
        if (timeout_str) |t| {
            try writer.print(",\"timeout\":{s}", .{t});
        }
        if (prompt_pat) |pat| {
            try writer.writeAll(",\"prompt_pattern\":\"");
            try writeJsonEscaped(writer, pat);
            try writer.writeByte('"');
        }
        try writer.writeByte('}');

        const params = fbs.getWritten();
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
        var params_buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&params_buf);
        const writer = fbs.writer();
        try writer.writeAll("{\"text\":\"");
        try writeJsonEscaped(writer, send_text);
        if (append_enter) try writer.writeAll("\\n");
        try writer.writeByte('"');
        if (surface_id) |sid| {
            try writer.writeAll(",\"surface_id\":");
            try writer.writeAll(sid);
        }
        try writer.writeByte('}');
        const params = fbs.getWritten();
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
            if (args.next()) |body| {
                var params_buf: [4096]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"title\":\"{s}\",\"body\":\"{s}\"}}", .{ title, body }) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "notification.create", params, stdout, stderr);
            } else {
                var params_buf: [4096]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"title\":\"{s}\"}}", .{title}) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "notification.create", params, stdout, stderr);
            }
        } else if (std.mem.eql(u8, sub, "clear")) {
            if (args.next()) |id_str| {
                var params_buf: [256]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s}}}", .{id_str}) catch {
                    try stderr.writeAll("Invalid id\n");
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
            var params_buf: [512]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"action\":\"{s}\"}}", .{action_name}) catch {
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
        var stdin_buf: [8192]u8 = undefined;
        var stdin_len: usize = 0;
        const stdin = std.fs.File.stdin();
        while (stdin_len < stdin_buf.len) {
            const n = stdin.read(stdin_buf[stdin_len..]) catch break;
            if (n == 0) break;
            stdin_len += n;
        }

        // Extract fields from stdin JSON into stack buffers.
        var sid_buf: [256]u8 = undefined;
        var sid_len: usize = 0;
        var msg_buf: [2048]u8 = undefined;
        var msg_len: usize = 0;
        var evt_buf: [256]u8 = undefined;
        var evt_len: usize = 0;
        var cwd_buf: [512]u8 = undefined;
        var cwd_len: usize = 0;

        if (stdin_len > 0) {
            const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, stdin_buf[0..stdin_len], .{}) catch null;
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

        // Build params JSON
        var params_buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&params_buf);
        const writer = fbs.writer();
        try writer.writeAll("{\"subcommand\":\"");
        try writer.writeAll(hook_sub);
        try writer.writeByte('"');
        if (session_id) |sid| {
            try writer.writeAll(",\"session_id\":\"");
            try writeJsonEscaped(writer, sid);
            try writer.writeByte('"');
        }
        if (ws_id) |w| {
            try writer.writeAll(",\"workspace_id\":");
            try writer.writeAll(w);
        }
        if (surface_id) |s| {
            try writer.writeAll(",\"surface_id\":");
            try writer.writeAll(s);
        }
        if (message) |m| {
            try writer.writeAll(",\"message\":\"");
            try writeJsonEscaped(writer, m);
            try writer.writeByte('"');
        }
        if (event) |e| {
            try writer.writeAll(",\"event\":\"");
            try writeJsonEscaped(writer, e);
            try writer.writeByte('"');
        }
        if (cwd_val) |c| {
            try writer.writeAll(",\"cwd\":\"");
            try writeJsonEscaped(writer, c);
            try writer.writeByte('"');
        }
        try writer.writeByte('}');

        const params = fbs.getWritten();
        try sendAndPrint(socket_path, "claude.hook", params, stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "history")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            // Optional: --workspace <id> --limit <n>
            var params_buf: [4096]u8 = undefined;
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
                var fbs = std.io.fixedBufferStream(&params_buf);
                const writer = fbs.writer();
                try writer.writeByte('{');
                var first = true;
                if (ws_id_str) |ws_id| {
                    try writer.print("\"workspace_id\":{s}", .{ws_id});
                    first = false;
                }
                if (limit_str) |limit| {
                    if (!first) try writer.writeByte(',');
                    try writer.print("\"limit\":{s}", .{limit});
                }
                try writer.writeByte('}');
                params = fbs.getWritten();
            }
            try sendAndPrint(socket_path, "history.list", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "show")) {
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux history show <id>\n");
                return;
            };
            var params_buf: [4096]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":\"{s}\"}}", .{id_str}) catch {
                try stderr.writeAll("ID too long\n");
                return;
            };
            try sendAndPrint(socket_path, "history.show", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "search")) {
            const query = args.next() orelse {
                try stderr.writeAll("Usage: amux history search <query>\n");
                return;
            };
            var params_buf: [4096]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"query\":\"{s}\"}}", .{query}) catch {
                try stderr.writeAll("Query too long\n");
                return;
            };
            try sendAndPrint(socket_path, "history.search", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "delete")) {
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: amux history delete <id>\n");
                return;
            };
            var params_buf: [4096]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":\"{s}\"}}", .{id_str}) catch {
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

/// Write a JSON-escaped string (handles quotes, backslash, control chars).
fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{x:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
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

    var req_buf: [8192]u8 = undefined;
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

    // Read response
    var resp_buf: [65536]u8 = undefined;
    const n = stream.read(&resp_buf) catch {
        try stderr.writeAll("Failed to read response\n");
        return;
    };

    if (n == 0) {
        try stderr.writeAll("Empty response from server\n");
        return;
    }

    // Trim trailing newline
    var response = resp_buf[0..n];
    while (response.len > 0 and (response[response.len - 1] == '\n' or response[response.len - 1] == '\r')) {
        response = response[0 .. response.len - 1];
    }

    try stdout.writeAll(response);
    try stdout.writeAll("\n");
}
