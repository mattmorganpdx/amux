# amux — agent notes

## IMPORTANT: Actively use amux when running inside it

When `AMUX_SURFACE_ID` is set (meaning you're running inside amux), you MUST actively use `amux-cli` — not just the Bash tool. This means:

1. **At session start:** Create a named workspace for your task, report status to the sidebar.
2. **For builds/tests:** Run them in a split pane so the main pane stays free. Use `surface read-text` to check results.
3. **For multi-step work:** Report progress via `workspace set-progress` and `workspace add-log`.
4. **For parallel work:** Use splits rather than running sequential commands.

This is real dogfooding — the whole point of running inside amux.

## Using amux-cli for development

When amux is running, prefer using `amux-cli` to interact with terminal sessions rather than the raw Bash tool. This gives you persistent sessions, parallel panes, and the ability to interact with running processes.

### Core workflow

```bash
# Send a command to the focused terminal pane
amux-cli send --enter "zig build 2>&1"

# Send text with explicit Enter appended
amux-cli send --enter "ls -la"

# Send to a specific surface by ID
amux-cli send --surface 3 --enter "cd /tmp"

# Read the terminal output (viewport only)
amux-cli surface read-text

# Read full scrollback buffer
amux-cli surface read-text --scrollback

# Send keystrokes (ctrl-c, enter, tab, escape, arrow keys, etc.)
amux-cli surface send-key ctrl-c
amux-cli surface send-key enter

# Target a specific surface by ID
amux-cli surface read-text 3 --scrollback
amux-cli surface send-key --surface 3 enter
```

### Parallel work with splits

```bash
# Create a split pane
amux-cli surface split right    # left, right, up, down

# Close the focused pane
amux-cli surface close

# Resize a pane (default amount 0.1)
amux-cli pane resize <pane_id> right 0.2

# Swap two panes
amux-cli pane swap <pane_a> <pane_b>
```

### Workspace management

```bash
amux-cli workspace create "build"     # create a named workspace
amux-cli workspace list               # list all workspaces
amux-cli workspace select <id>        # switch workspace
amux-cli workspace next               # cycle workspaces
```

### Observability — report status to the sidebar

```bash
amux-cli workspace set-progress <id> 0.5 "Building..."
amux-cli workspace set-status <id> task "compiling"
amux-cli workspace add-log <id> "Build succeeded"
amux-cli workspace report-git <id> main --dirty
```

### Discovery

```bash
amux-cli identify        # show focused workspace/pane context
amux-cli tree             # full hierarchy: windows → workspaces → panes
amux-cli surface list     # list all surfaces with IDs
amux-cli pane list        # list all panes
```

### Command palette

```bash
amux-cli palette list                  # list all available actions
amux-cli palette execute <action>      # execute an action by name
```

### Claude Code integration

When the `bin/claude` wrapper is in PATH before the real `claude` binary, it automatically injects hooks so Claude Code sessions report status to the amux sidebar.

```bash
# The wrapper handles this automatically, but you can also manually:
echo '{"session_id":"abc"}' | amux-cli claude-hook session-start
echo '{}' | amux-cli claude-hook stop
echo '{"message":"Needs approval"}' | amux-cli claude-hook notification
echo '{}' | amux-cli claude-hook prompt-submit
```

The sidebar shows `claude: Running`, `claude: Permission`, `claude: Error`, `claude: Waiting`, or `claude: Attention` depending on the hook event. Desktop notifications fire on stop and notification events.

### Environment

Each terminal pane automatically gets these environment variables:
- `AMUX_SURFACE_ID` — this pane's surface ID
- `AMUX_WORKSPACE_ID` — this pane's workspace ID
- `AMUX_SOCKET_PATH` — path to the amux socket

Socket path resolution: `AMUX_SOCKET` → `AMUX_SOCKET_PATH` → `/tmp/amux.sock`

## Building

```bash
cd linux && zig build
```

This produces two binaries in `zig-out/bin/`:
- `cmux` — the GUI terminal (requires GTK4, libghostty, libnotify)
- `amux-cli` — standalone socket client (libc only)

### Rebuilding libghostty

If the Ghostty submodule changes, rebuild via the setup script:

```bash
cd linux && ./setup.sh
```

## Architecture

- **Language:** Zig 0.14, `@cImport` for GTK4 and Ghostty C headers
- **UI:** GTK4 (GtkApplication, GtkGLArea, GtkPaned, GtkListBox)
- **Terminal:** Ghostty embedded apprt via `libghostty.so`
- **Socket:** Unix domain socket, newline-delimited JSON-RPC, thread-per-client
- **Source layout:** `src/` (GUI app), `cli/` (CLI tool), `src/socket/` (server + handlers)
