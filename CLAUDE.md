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
amux-cli workspace create "build"     # create a named workspace, panes start in $PWD
amux-cli workspace create "x" --cwd /srv/app   # or somewhere else
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

amux pins **Zig 0.15.2**. Zig 0.16 will not build it — `build.zig` checks the
compiler version and fails with instructions. See `build.zig` for why (0.16's
translate-c cannot process the GTK4 headers).

```bash
zig build
```

This produces three binaries in `zig-out/bin/`:
- `amux` — the GUI terminal (requires GTK4, libghostty, libnotify)
- `amux-cli` — standalone socket client (libc only)
- `amuxd` — the terminal daemon (libc only; no GTK, no libghostty, no display)

`amuxd` owns pseudoterminals and terminal state so sessions outlive the GUI, and
it serves the socket protocol — so `amux-cli` works against it with no display
and no GUI running:

```bash
AMUX_SOCKET=/tmp/amuxd.sock amuxd &
AMUX_SOCKET=/tmp/amuxd.sock amux-cli run "echo hello"
```

It answers 41 methods (`system.capabilities` lists them, and reports
`"daemon": true`). The command palette and window actions stay in the GUI — they
drive its chrome, and nothing else can execute them.

### The GUI as a view onto the daemon

When a daemon is reachable, the GUI is a client of it rather than an owner of
terminals. On startup it fetches `system.layout` — the same session format
`session.zig` writes to disk, so pane node ids come across unchanged and a GUI
pane id *is* a daemon pane id — and each terminal widget runs
`amux-cli --socket <path> attach <pane>` instead of a shell. Close the window and
the shells keep running; open it again and they are still there.

Splits, closes and new workspaces are forwarded to the daemon, which owns them.
Both sides then apply the change to their own copy of the tree, which yields the
same ids because both run the same `pane_tree.zig` from the same state; the GUI
checks that and logs loudly if they ever drift.

The GUI finds the daemon via `AMUX_DAEMON_SOCKET`, else `$XDG_RUNTIME_DIR/amux.sock`,
else `/tmp/amux.sock` — skipping its own socket and requiring `"daemon": true`
from `system.capabilities`, so it cannot end up mirroring itself. With no daemon
reachable it runs terminals locally exactly as before.

An attached client owns the terminal size: the relay sends `surface.resize` for
its window and repaints. A pane sized differently from the window does not just
look cramped — the paint positions rows explicitly, so content lands in the wrong
places.

**The GUI still runs its own socket server too, and both default to
`/tmp/amux.sock`** — give one an `AMUX_SOCKET` override while both exist. The
GUI becomes a client of the daemon in work-plan item 6.

Each server's **session file is scoped to its socket**, so the two no longer
overwrite each other's layout: `/tmp/amux.sock` keeps the historical
`session.json`, and any other socket gets `session-<slug>.json` beside it
(`/run/user/1000/amux.sock` → `session-run-user-1000-amux.json`). Two servers
cannot bind one socket, so they cannot share a file; a restart on the same
socket deliberately restores the same layout. `AMUX_SESSION=<path>` pins it
explicitly, which is the safe way to keep a test daemon away from your real
session.

`amuxd --self-check` spawns a shell, runs a command and reads it back off the
parsed screen.

### Socket activation

```bash
./dist/systemd/install.sh        # enables amuxd.socket as a user unit
amux-cli ping                    # first call starts the daemon (~40ms)
```

`ExecStart` points at this checkout's `zig-out/bin/amuxd`, so a rebuild is picked
up on the next start — and moving the repo or cleaning `zig-out` breaks the unit.

The service raises `LimitNOFILE` to match a login shell. Panes inherit the
daemon's limits, and systemd's default soft limit of 1024 is far below what a
terminal normally has: with it, this project's own test suite went from 9 seconds
to over five minutes in a pane and then failed.

The socket lands at `$XDG_RUNTIME_DIR/amux.sock` with mode 0600, and `amux-cli`
probes that path before falling back to `/tmp/amux.sock`. Panes get
`AMUX_SOCKET_PATH`, so `amux-cli` inside a pane always reaches the daemon that
owns it.

Uninstall: `systemctl --user disable --now amuxd.socket && rm ~/.config/systemd/user/amuxd.{socket,service} && systemctl --user daemon-reload`

### Screen state (what an attached client draws)

`surface.screen` returns the screen as cells — dimensions, colours, cursor and
styled runs — rather than as text. It serializes ghostty's own `RenderState`.

```bash
amux-cli surface screen                      # whole screen (attach)
amux-cli surface screen 2                    # a specific surface
amux-cli surface screen --since 41           # only rows changed after seq 41
amux-cli surface screen --since 41 --timeout 5000   # wait up to 5s for a change
```

Pass back the `seq` from the previous reply to get a delta; `since` omitted (or
0) means "send everything", so attaching and updating are the same call. With
`timeout_ms` the daemon answers as soon as the screen changes, or returns
`{"changed":false}` at the deadline. A pane closed under a waiting client comes
back as `no_surface`.

Colours are resolved to RGB by the daemon, and a default colour the terminal has
no opinion about is **omitted** rather than sent as black — absent means "use
your own theme". Each run carries its starting column, so a client never infers
position from character widths.

This is deliberately not `surface.watch`, which the roadmap reserves for Smart
Wake's semantic events (TUI detected, prompt waiting). Different question, same
underlying change notification.

### Attaching a terminal to a daemon pane

`amux-cli attach [surface_id]` relays a daemon-owned pane through the terminal it
is run in: it paints what is already on screen, then streams new output, and
sends keystrokes back. Run it in any terminal to get a view of a pane whose pty
lives in the daemon — the same way `tmux attach` works.

```bash
amux-cli attach          # the focused pane
amux-cli attach 3        # a specific one
```

It rests on two methods. `surface.output` returns raw pty bytes, base64-encoded;
omit `offset` to attach (the reply is a repaint of the current screen plus the
offset to stream from), pass it back to continue, and `timeout_ms` waits for
output. A client that falls further behind than the pane's 256KB output ring is
sent a fresh repaint rather than a stream starting mid-escape-sequence.
`surface.input` sends raw bytes the other way.

The repaint is reconstructed from the same cell data `surface.screen` serves —
cursor positioning, SGR runs and text — because new output says nothing about
what is already on screen.

### Reporting status with no GUI running

Workspace metadata and the Claude hooks live in the daemon, so an agent can
report what it is doing whether or not a window is open — which is the point.

```bash
amux-cli workspace set-progress 1 0.4 "compiling"
amux-cli workspace set-status 1 task "item 6"
amux-cli workspace add-log 1 "started the build"
amux-cli workspace report-git 1 main --dirty
echo '{"message":"Needs approval"}' | amux-cli claude-hook notification
amux-cli workspace list        # carries status, progress, git and log back
amux-cli notification list     # records kept even with nothing to show them
```

The daemon keeps notification *records*, not desktop notifications: showing one
needs libnotify and a session bus, which `amuxd` deliberately does not link. A
running GUI turns records into desktop notifications; with none running the
record is still there to read afterwards.

The GUI's sidebar shows all of this. It follows `workspace.metadata`, which
carries the same workspace objects `workspace.list` returns plus a sequence
number to wait on:

```bash
amux-cli workspace metadata                            # current, with its seq
amux-cli workspace metadata --since 7 --timeout 5000   # wait for a change
```

Metadata has its own sequence number, separate from `system.layout`'s, and that
separation is the point: a client following the layout rebuilds its widget tree
when it changes, so sharing one number would make an agent's progress report as
expensive as a split. Reporting progress ten times in a row causes zero widget
rebuilds.

### Waiting for a pane instead of polling it

`surface.watch` blocks until a pane does something worth a turn, and says why.
The alternative is sleeping and re-reading, which spends a turn on every dead
poll and still misses the moment a command stops to ask a question.

```bash
GEN=$(amux-cli send --enter "make -j8" | jq -r .result.gen)
amux-cli watch --since $GEN --timeout 600000
```

`send` reports the pane's generation; passing it back as `--since` means "tell me
about anything after that write". Without it the baseline is whenever the watch
started, which loses a command that finished in the gap — and reports a
*previous* prompt as this command completing.

Reasons: `command_complete` (output stopped, prompt returned), `prompt_waiting`
(the screen is asking something — wakes immediately, without waiting out the
stall timer), `tui_detected` (entered the alternate screen), `output_stalled`
(output stopped with no prompt), `exited`, and `timeout` for the safety net.
`--stall-ms` sets how long output must be stopped to count (default 2000).

Only `tui_detected` and `exited` are exact; the rest are heuristics, and
`prompt_waiting` only inspects the **last** line — a question answered a moment
ago is still on screen, and matching it again woke agents with the wrong reason.

### Session history

The daemon archives a pane's scrollback to SQLite when the terminal ends — pane
close, workspace close, or daemon exit — at
`${XDG_CONFIG_HOME:-~/.config}/amux/history.db`. Scrollback only exists while
the terminal does, so this is the only chance to keep it.

```bash
amux-cli history list                 # recent sessions, newest first
amux-cli history list --workspace 2   # scoped to one workspace
amux-cli history show 7               # full scrollback of one session
amux-cli history search migration_42  # full-text search (FTS5)
amux-cli history delete 7
```

Retention is 5000 entries or 10 MB, pruned oldest-first. Set
`AMUX_HISTORY_MAX_ENTRIES` / `AMUX_HISTORY_MAX_BYTES` to change it, or
`AMUX_HISTORY=0` to archive nothing.

Search over **closed** sessions is SQL/FTS5; search over a **live** pane is
`ghostty-vt`'s `PageList` search. Different mechanisms by design — neither can
answer the other's question.

Tests:

```bash
zig build test
```

37 tests covering what needs no GTK or libghostty: `src/vt.zig` (the seam onto
the `ghostty-vt` headless engine) and the daemon — ptys, panes, the registry,
state, the socket front door and the history store. The GUI still has to be
exercised by running it.

### Rebuilding libghostty

If the Ghostty submodule changes, rebuild via the setup script:

```bash
./setup.sh
```

## Architecture

- **Language:** Zig 0.15.2 (pinned in `build.zig`), `@cImport` for GTK4 and Ghostty C headers
- **UI:** GTK4 (GtkApplication, GtkGLArea, GtkPaned, GtkListBox)
- **Terminal:** Ghostty embedded apprt via `libghostty.so`
- **Socket:** Unix domain socket, newline-delimited JSON-RPC, thread-per-client
- **Store:** SQLite + FTS5 (system library) for archived session scrollback
- **Screen protocol:** ghostty `RenderState` serialized as JSON; per-row sequence numbers give stateless deltas
- **Source layout:** `src/` (GUI app), `cli/` (CLI tool), `src/socket/` (server + request router), `src/socket/handlers/` (per-domain handlers: system, workspace, surface, pane, window_api, notification, palette, claude, history, plus `common` for shared main-thread dispatch), `src/daemon/` (the daemon: pty, pane, registry, state, handlers, server, history)
