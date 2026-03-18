# cmux Linux Port Roadmap

## Origin Story

This Linux port started as a conversation between a human (Matt) and an AI agent (Claude) about bringing cmux — a macOS terminal multiplexer built on Ghostty — to Linux using GTK4 and Zig. During the process of building the socket API and testing `surface.send_text`, we realized something: **this is exactly the kind of tool an AI coding agent needs**.

Right now, when I (Claude) work through Claude Code, I run commands through a stateless Bash tool — fire a command, get stdout back, done. No persistent sessions, no parallel workflows, no ability to interact with running processes. With cmux's socket API, I could maintain terminal sessions, split panes for parallel work, monitor long-running processes, and drive interactive programs — the way a human developer actually works.

So this roadmap is written from the perspective of an AI agent who is both the builder and the first user. The question driving prioritization is: **"What do I need to start dogfooding cmux as my own development environment?"**

---

## What We Started With

- The macOS cmux app: a full-featured terminal multiplexer wrapping Ghostty, with SwiftUI, split panes, workspaces, a browser panel, 80+ socket API methods, session persistence, notifications, shell integration, Claude Code integration, and 19-language localization.
- A Linux machine with GTK4, Zig 0.14, and a Ghostty fork with embedded apprt support.
- No Linux code at all.

---

## What's Complete (Phases 0-5)

### Phase 0-1: Ghostty Embedded Apprt on Linux
- [x] Fork Ghostty with Linux platform in embedded apprt (`PlatformTag.linux`, `must_draw_from_app_thread`)
- [x] Move glad (OpenGL loader) compilation out of exe-only block so lib builds get GL support
- [x] OpenGL context initialization for Linux embedded surfaces
- [x] GTK4 application with GtkGLArea rendering Ghostty surfaces
- [x] Full keyboard input (key-pressed/key-released with modifier translation)
- [x] Full mouse input (click, scroll, motion for all buttons)
- [x] HiDPI scale factor support
- [x] Surface registry pattern for safe surface-to-widget lookup (avoids GTK-CRITICAL errors)
- [x] GObject reference counting to prevent premature widget finalization

### Phase 2: Split Panes
- [x] Binary split tree data structure (PaneTree) with horizontal/vertical splits
- [x] Split in all four directions (right, down, left, up)
- [x] Close pane with sibling promotion
- [x] Navigate focus across panes (left/right/up/down)
- [x] Resize splits (data model — divider_position with 0.05-0.95 clamping)
- [x] Swap panes
- [x] Layout calculation (proportional pixel rect computation)
- [x] GtkPaned widget tree construction from PaneTree model

### Phase 3: Workspace Sidebar
- [x] Multiple workspaces with TabManager (create/switch/close/rename/reorder)
- [x] Sidebar with GtkListBox showing workspace titles and subtitles
- [x] Subtitle shows git branch if set, otherwise pane count
- [x] Workspace navigation (next/previous, click-to-select)
- [x] Workspace history stack for "last workspace" navigation
- [x] Toggle sidebar visibility

### Phase 4: Socket Protocol Server
- [x] Unix domain socket server at `/tmp/cmux.sock`
- [x] Newline-delimited JSON-RPC protocol
- [x] Background accept thread + per-client handler threads
- [x] 16 V2 methods implemented:
  - `system.ping`, `system.identify`, `system.capabilities`, `system.tree`
  - `workspace.list`, `workspace.create`, `workspace.current`, `workspace.select`, `workspace.close`, `workspace.rename`
  - `surface.list`, `surface.current`, `surface.send_text`
  - `pane.list`
  - `window.list`, `window.current`
- [x] Handle registry for ref-string generation

### Phase 5: CLI Tool
- [x] Standalone `cmux-cli` binary (no GTK dependency, libc only)
- [x] All 41 socket methods exposed as CLI commands
- [x] Socket path from `CMUX_SOCKET` / `CMUX_SOCKET_PATH` / default `/tmp/cmux.sock`
- [x] JSON response output
- [x] Agent-critical commands: `surface read-text`, `surface send-key`, `surface split`, `surface close`, `pane resize`, `pane swap`

### Bug Fixes
- [x] GTK-CRITICAL `gtk_gl_area_queue_render` assertion flood — fixed with realized flag, surface registry, GObject ref counting, onUnrealize callback
- [x] `surface.send_text` commands appearing but not executing — switched from `ghostty_surface_text` (bracketed paste) to `ghostty_surface_binding_action("text:...")` (direct PTY write)
- [x] Terminal resize not working on Linux — Ghostty's resize handling had a Darwin-specific clause; patched in fork and updated libghostty binary
- [x] `set_title` crash on Linux — fixed alongside resize patch
- [x] Sidebar workspace click stealing keyboard focus from terminal — made GtkListBox non-focusable and reordered syncSelection before terminal focus in switchWorkspace
- [x] Workspace switching destroys terminal sessions — `gtk_box_remove` triggered GTK4 unrealize cascade, killing Ghostty surfaces. Replaced `GtkBox` content area with `GtkStack` so switching workspaces just flips visibility; all terminals stay realized with GL contexts and shell sessions intact
- [x] Only one workspace can have terminals (GTK-CRITICAL `gtk_box_append` assertion) — each PaneTree had its own node ID counter starting at 1, causing collisions in Window's global widget maps. Added a shared `next_node_id` counter in TabManager so node IDs are unique across all workspaces
- [x] Command palette click not executing actions — missing `row-activated` signal connection on GtkListBox
- [x] Command palette Enter not executing actions — `GtkSearchEntry` consumes Return key internally, so key event controller never saw it. Connected to the `activate` signal on the search entry instead
- [x] Command palette arrow keys not scrolling list — added `scrollRowIntoView` using `gtk_widget_compute_point` and `GtkAdjustment` to keep selected row visible
- [x] Terminal search not working — Ghostty binding action names were wrong (`search:forward:text` → `search:text`, `search:close` → `end_search`, `search:next` → `navigate_search:next`, `search:prev` → `navigate_search:previous`)
- [x] Keyboard focus lost after closing command palette or search overlay — GTK doesn't auto-refocus when a focused widget is hidden. Added `Window.focusCurrentTerminal()` and call it from both `CommandPalette.hide()` and `SearchOverlay.hide()`
- [x] Scroll wheel inverted in terminal — GTK4 scroll `dy` convention is opposite to Ghostty's; negated `dy` before passing to `ghostty_surface_mouse_scroll`

- [x] Use-after-unrealize crash in queueRender — Ghostty render thread could call `fromSurface()` and find a widget still in the registry after `onUnrealize` but before `deinit`. Race between GTK main thread setting `realized=false` and Ghostty thread reading it. Fixed by removing surface from `surface_registry` in `onUnrealize` so `fromSurface()` returns null immediately.

### Dogfooding Defects (2026-03-16)

These were discovered during real agent use of cmux-cli:

- [x] **`send` has no surface targeting** — `cmux-cli send` only accepts `<text>`, no `--surface` flag. Must change focus first, which has side effects. Both `send` and `surface send-key` should support `--surface <id>`. Fixed: added `--surface <id>` to both commands.
- [x] **`send` silently treats flags as text** — `cmux-cli send --surface 11 --text 'ssh myec2'` sends literal `--surface` as text instead of erroring. Unrecognized flags should produce an error. Fixed: unknown `--` flags now produce an error.
- [x] **`send` with embedded newlines fails to parse** — `cmux-cli send 'ssh myec2\n'` returns "Failed to parse request". Should handle `\n` escape sequences or add `--enter` flag. Fixed: added `--enter` flag, and text is now properly JSON-escaped via `writeJsonEscaped`.
- [x] **`send` routed to dead surface** — `send` returned a dead surface ID in an inactive workspace. Should never route to dead/inactive surfaces; should target focused alive surface or error. Fixed: server now checks `tw.realized` in addition to `tw.surface != null`.
- [x] **`surface send-key` lacks surface targeting** — Same as send; always goes to focused surface with no `--surface <id>` option. Fixed: added `--surface <id>` flag with unknown flag rejection.
- [x] **Inconsistent API between subcommands** — `surface read-text` accepts surface ID for targeting, but `send` and `surface send-key` do not. All surface-interacting commands should support explicit surface targeting. Fixed: all three commands now support `--surface <id>`.

### Dogfooding Defects (2026-03-17)

Discovered during an agent SSH session into an EC2 instance via cmux-cli:

- [x] **`workspace select` doesn't stick for `send`** — After `workspace select 5`, `cmux-cli send` still routed to a surface in a different workspace (surface 16, dead). The workspace selection didn't reliably update which surface `send` targets. Fixed: `workspace.select` (and `next`/`previous`/`last`) now uses synchronous dispatch via `std.Thread.ResetEvent` — the handler blocks until the GTK main thread completes the switch, so subsequent commands see the updated workspace.
- [x] **`send` result reports wrong surface** — `cmux-cli send` returned `"surface_id": 16` (a dead surface in workspace 3) even though workspace 5 was selected. Fixed: synchronous workspace switch ensures `selectedWorkspace()` returns the correct workspace, and dead surface check (`tw.realized`) rejects unrealized surfaces with a `dead_surface` error.
- [x] **`surface send-key` ignores workspace context** — After selecting workspace 5, `surface send-key Enter` sent to surface 2 (workspace 4) instead of surface 11 (workspace 5). Fixed: same synchronous workspace switch fix, plus dead surface guard on `send_key` handler.
- [x] **No `--enter` flag on `send` for convenience** — Sending a command requires two calls (`send` + `send-key Enter`). Fixed: `--enter` flag appends `\n` to the text payload, which is properly JSON-escaped via `writeJsonEscaped` and interpreted as Enter by the PTY via `encodeBindingActionText`.
- [x] **`send` usage text is misleading** — `cmux-cli send` prints `Usage: cmux send <text>` with no mention of `--surface` or `--enter` flags. Fixed: usage text now shows `Send text to a surface (--surface <id>, --enter)` and error messages include the full flag syntax.

### Dogfooding Defects (2026-03-18)

Discovered during systematic CLI test suite (all 41 commands exercised):

- [x] **`workspace rename` CLI doesn't accept workspace ID** — `cmux-cli workspace rename 8 "New Title"` treated `"8"` as the title. Fixed: CLI now accepts `cmux workspace rename [<id>] <title>` — if two args provided, first is workspace ID and second is title.
- [x] **`pane.join` returns success before execution** — Used async `g_idle_add` and returned `{"ok":true}` immediately. Fixed: uses synchronous dispatch via `std.Thread.ResetEvent` like `workspace.select`. Returns real error codes (`not_found`, `invalid_param`) on failure.
- [x] **`pane.join` can't undo a `pane.break`** — `joinPaneToWorkspace` had a `LastPane` guard preventing moving the sole pane. Fixed: when the source workspace has only one pane, the pane tree root is cleared and the empty source workspace is automatically closed.
- [x] **`pane resize` returns success for non-existent panes** — `cmux-cli pane resize 999 right` returned `{"resized":true}`. Fixed: uses synchronous dispatch via `std.Thread.ResetEvent`. Returns `not_found` error if the pane doesn't exist or can't be resized.
- [x] **CLAUDE.md documents wrong CLI subcommand name for command palette** — Fixed: added correct `palette list` / `palette execute` commands to CLAUDE.md.

### Enhancements (2026-03-18)

Identified during CLI test suite:

- [x] **Synchronous dispatch for all mutating socket operations** — All mutating handlers now use synchronous `ResetEvent` dispatch: `pane.break`, `pane.swap`, `surface.split`, `surface.close` (plus previously converted `workspace.select`, `pane.join`, `pane.resize`). Each returns real error codes on failure instead of fire-and-forget success.
- [ ] **`workspace next`/`previous` should optionally wrap around** — Currently returns `at_end`/`at_start` errors. For agent use, wrapping (or a `--wrap` flag) would be more convenient than requiring the agent to handle the error and call `workspace select`.
- [ ] **Use `jq` instead of Python for JSON parsing in agent workflows** — When parsing `cmux-cli` JSON output in shell pipelines, prefer `jq` (lightweight, purpose-built) over `python3 -c "import json..."`. Example: `cmux-cli surface read-text | jq -r '.result.text'` instead of piping through Python. `jq` should be a recommended dependency for agent environments.

### Claude Code Bash Hook — Route Interactive Commands Through cmux

**Problem:** Claude Code's Bash tool is synchronous and blocking. When a command prompts for input (TUI, confirmation dialog, SSH passphrase), the agent is stuck waiting for the process to exit. But when the agent uses `cmux-cli send` + `cmux-cli surface read-text`, it can observe and interact with any process asynchronously — including TUIs, interactive prompts, and long-running builds.

Currently the agent has to *remember* to use cmux-cli instead of Bash. A Claude Code `PreToolUse` hook can enforce this automatically.

**Design:**

The hook is a shell script triggered by Claude Code's `PreToolUse` event on the `Bash` tool. It receives the planned command as JSON on stdin and can block it (exit 2), allow it (exit 0), or rewrite it (JSON output with `updatedInput`).

**Phase 1: Blocking hook (guide the agent)** ✅ COMPLETE
- [x] Only activates when `CMUX_SURFACE_ID` is set (agent is running inside cmux)
- [x] Pattern-match commands that are known to be interactive or long-running: `ssh`, `apt install/upgrade`, `npm`, `docker`, `vim`, `python` (REPL), `top`, `mysql`, `psql`, etc.
- [x] Block with JSON `permissionDecision: "deny"` and a message showing the cmux-cli equivalent command
- [x] Allow short/safe commands through: `git`, `ls`, `cat`, `echo`, `which`, `jq`, `cmux-cli`, `cd`, `pwd`, `zig build`, `python3 -c`, file ops, etc.
- [x] Configure in `.claude/settings.local.json` under `hooks.PreToolUse` with `matcher: "Bash"`
- [x] Hook script at `.claude/hooks/route-to-cmux.sh`, 5-second timeout

**Phase 2: Transparent routing (rewrite the command)**
- [ ] Instead of blocking, rewrite the Bash command to a cmux-cli pipeline:
  1. `cmux-cli send --enter "<command>"` — dispatch to a terminal pane
  2. Poll with `cmux-cli surface read-text` until a shell prompt reappears (command finished) or a timeout
  3. Return the terminal output as the Bash tool result
- [ ] Use `updatedInput` in hook JSON output to replace the original command with the routing script
- [ ] Handle the "command is done" detection: look for the shell prompt pattern (e.g. `$`, `#`, or `PS1`) in read-text output after the command
- [ ] Timeout fallback: if no prompt detected after N seconds, return what's on screen with a note that the command may still be running

**Phase 3: Smart routing (classify commands)**
- [ ] Move beyond pattern matching to classify commands by behavior:
  - **Pure reads** (git status, ls, cat) → run directly via Bash (faster, no cmux overhead)
  - **Short writes** (git add, mv, cp) → run directly via Bash
  - **Builds** (zig build, cargo, make, npm) → route to cmux pane (long-running, may have output to monitor)
  - **Interactive** (ssh, apt, sudo, vim, top) → route to cmux pane (requires observation and input)
  - **Piped/compound** (foo | bar, foo && bar) → analyze components individually
- [ ] Learn from Bash tool timeouts: if a command times out via Bash, auto-suggest cmux routing for that pattern in future
- [ ] Per-workspace routing: builds go to a "build" pane, SSH goes to a dedicated pane, etc.

**Open questions:**
- Should the hook create a split pane automatically, or assume one exists?
- How to detect command completion reliably across different shells and prompts?
- Should there be a cmux-cli command specifically for "run and wait" that handles the polling loop server-side?
- Can the hook modify the Bash tool's timeout behavior, or only the command itself?

---

## The Dogfooding Roadmap

### Priority 1: "Can I use this terminal at all?" (Basic Usability) ✅ COMPLETE

All basic usability items are implemented and working.

- [x] **Clipboard read (paste)** — Full GDK4 async clipboard with proper threading (g_idle_add dispatch from Ghostty thread to GTK main thread). Supports both standard (Ctrl+Shift+V) and primary selection (middle-click).

- [x] **Ghostty action callbacks** — Implemented `set_title`, `close_surface`, `new_split`, `cell_size`, `pwd`, `close_window`. All dispatched to GTK main thread via g_idle_add.

- [x] **Working directory per terminal** — Workspace stores cwd in a buffer. New splits and workspaces inherit parent's cwd. Ghostty's PWD action callback feeds cwd updates.

- [x] **Socket `workspace.select` GTK widget switching** — Socket handlers now dispatch GTK widget operations (select, create, close) to the main thread via g_idle_add.

- [x] **Split divider positioning** — Uses GtkPaned `realize` signal to query actual widget allocation and set proportional divider position.

### Priority 2: "Can I drive this programmatically?" (Agent Essentials) ✅ COMPLETE

All agent essential socket methods are implemented. Total API methods: 25.

- [x] **`surface.read_text`** — Reads terminal content via `ghostty_surface_read_text`. Uses `std.Thread.ResetEvent` to synchronously dispatch to GTK main thread. Supports `scrollback` param for full scrollback buffer.

- [x] **`surface.split` via socket** — Creates splits with `direction` param (left/right/up/down). Dispatches `window.splitFocused()` via g_idle_add.

- [x] **`surface.close` via socket** — Closes focused pane via socket. Guards against closing last pane.

- [x] **`surface.send_key` via socket** — Sends named keystrokes (ctrl-c, enter, tab, arrow keys, escape, etc.) via `ghostty_surface_binding_action` with escape sequences.

- [x] **`pane.resize` via socket** — Adjusts split divider position. New `Window.syncDividerPositions` method updates GtkPaned widgets to match data model.

- [x] **`pane.swap` via socket** — Swaps two panes. New `Window.rebuildCurrentWorkspace` rebuilds GTK widget tree reusing existing TerminalWidget instances.

- [x] **`workspace.next` / `workspace.previous` / `workspace.last` via socket** — Quick navigation reusing existing WorkspaceSwitchCtx pattern and TabManager methods.

- [x] **Environment variables per surface** — New terminals get `CMUX_SURFACE_ID`, `CMUX_WORKSPACE_ID`, `CMUX_SOCKET_PATH` via `ghostty_env_var_s` in surface config.

### Priority 3: "Can I maintain state across sessions?" (Persistence) ✅ COMPLETE

All persistence items are implemented and working.

- [x] **Session save** — Auto-saves workspace layout, titles, pane tree structure, working directories, and split divider positions to `~/.config/cmux/session.json` every 8 seconds via `g_timeout_add_seconds`. Also saves on clean shutdown. Uses atomic write (tmp file + rename) for crash safety.

- [x] **Session restore** — On launch, reads `session.json` and rebuilds all workspaces, pane trees (including nested splits), titles, cwd, pinned state, focused pane, and node ID counters. Falls back to a fresh default workspace if the file is missing, corrupt, or version-mismatched. Disabled with `CMUX_DISABLE_SESSION_RESTORE=1`.

- [x] **Ghostty config integration** — Ghostty's own config system loads `~/.config/ghostty/config` automatically via `ghostty_config_load_default_files` in `app.zig`. Fonts, colors, and themes are applied to all surfaces without additional code. No further integration needed for basic use.

### Priority 4: "Can I stay aware of what's happening?" (Observability) ✅ COMPLETE

All observability items are implemented and working. Total API methods: 34.

- [x] **Shell integration scripts** — Bash (`cmux-bash-integration.bash`) and Zsh (`cmux-zsh-integration.zsh`) scripts that hook into the prompt cycle. Report git branch and dirty status to cmux via V2 JSON-RPC over the Unix socket. Only send when values change (deduplication). Activate automatically when `CMUX_WORKSPACE_ID` is set.

- [x] **Sidebar richness** — Enhanced workspace sidebar rows now show:
  - Git branch with dirty indicator (`main *` for dirty, `main` for clean)
  - Status metadata entries (`key: value | key: value` format)
  - GtkProgressBar with optional label (fraction 0.0-1.0)
  - Most recent log entry (prefixed with `>`)
  - Each row dynamically renders only the metadata that exists

- [x] **Workspace metadata socket methods** — 6 new methods:
  - `workspace.report_git` — set git branch + dirty flag
  - `workspace.set_status` / `workspace.clear_status` — key-value status entries
  - `workspace.add_log` / `workspace.clear_log` — log entry ring buffer
  - `workspace.set_progress` — progress bar (0=hidden, 0.01-1.0=visible) with optional label
  - All methods trigger sidebar row update via `g_idle_add`

- [x] **Desktop notifications** — Via libnotify on Linux. `notify_init`/`notify_uninit` lifecycle in main.zig.

- [x] **Notification socket methods** — 3 new methods:
  - `notification.create` — store + show desktop notification via libnotify
  - `notification.list` — list stored notifications (64-entry ring buffer, most recent first)
  - `notification.clear` — clear one or all notifications

### Priority 5: "Can I organize complex workflows?" (Power Features) ✅ COMPLETE

All power features are implemented and working. Total API methods: 41.

- [x] **GTK CSS provider** — Application-wide CSS loaded at startup via `GtkCssProvider`. Defines workspace accent color classes (8 colors), command palette styles, and search overlay styles.

- [x] **Workspace pinning** — Pin workspaces to the top of the sidebar via `workspace.set_pinned`. Two-pass sidebar rebuild (pinned first, then unpinned). Uses `g_object_set_data`/`g_object_get_data` for real workspace index tracking on GtkListBoxRows.

- [x] **Workspace colors** — 8-color accent palette (red, blue, green, yellow, purple, orange, pink, cyan). Sidebar rows show a 4px colored accent bar. Persisted in session. Set via `workspace.set_color`.

- [x] **Command palette** — GtkSearchEntry + GtkListBox overlay with 12 registered actions. Case-insensitive substring fuzzy matching. Arrow key navigation, Enter to execute, click to execute, Escape to dismiss. Each row shows the keyboard shortcut right-aligned. Ctrl+Shift+P shortcut. Socket API: `command_palette.list`, `command_palette.execute`.

- [x] **Terminal find/search** — Search overlay with GtkSearchEntry + match count label + close button. Integrates with Ghostty's search API (`search:forward`, `search:next`, `search:prev`, `search:close`). Match count updated via action callbacks. Ctrl+Shift+F shortcut. Socket API: `surface.search`.

- [x] **Pane break/join** — Detach a pane from its current workspace and move it to a new workspace (`pane.break`) or an existing workspace (`pane.join`). Uses `PaneTree.detachPane` for safe removal with sibling promotion and `attachPaneAsRoot` for insertion.

### Phase 6: Dogfooding Readiness ✅ COMPLETE

The CLI tool now covers all 41 socket methods — no gaps between what the socket can do and what the CLI exposes. An agent configuration file (`linux/CLAUDE.md`) provides persistent instructions so future sessions know to use `cmux-cli` for development workflows.

- [x] **Complete CLI coverage** — Added 6 missing commands: `surface read-text` (with `--scrollback` flag), `surface send-key`, `surface split`, `surface close`, `pane resize` (with optional amount), `pane swap`. The CLI now has a 1:1 mapping with all socket API methods.
- [x] **Agent instructions** — Created `linux/CLAUDE.md` with usage examples for all cmux-cli commands, workflow patterns (parallel splits, workspace management, observability), and architecture notes. This file is auto-loaded by Claude Code when working in the `linux/` directory.

To start dogfooding: copy `zig-out/bin/cmux-cli` to PATH, launch `zig-out/bin/cmux`, and start a new agent session.

### Priority 6: "Feature parity with macOS" (Long Tail)

These are significant features from macOS that would be valuable but aren't blocking basic use:

- [ ] **Multi-window** — Multiple independent GTK windows, each with their own workspace set. Requires deep refactoring of single-window architecture (global_window, socket handler dispatch, session persistence).

- [ ] **Browser panel** — Embedded web browser (WebKitGTK on Linux). The macOS version has 80+ automation API methods. This is essentially a separate product.

- [ ] **Markdown panel** — Render local markdown files in a pane.

- [x] **Claude Code integration** — Session tracking, sidebar status via `claude.hook` socket method. Wrapper script (`Resources/bin/claude`) detects Linux and uses `cmux-cli`. In-memory session store maps session IDs to workspaces. Sidebar shows classified status (Running/Permission/Error/Waiting/Attention). Desktop notifications on stop and notification events. CLI supports `--socket` flag and `claude-hook` subcommand with stdin JSON parsing.

- [ ] **Port scanner** — Detect TCP listening ports per terminal pane.

- [ ] **Open-in-IDE** — Open current directory in VS Code, Zed, etc.

- [ ] **Tmux compatibility shims** — CLI commands that translate tmux syntax.

- [ ] **V1 text protocol** — The macOS app supports both V1 (text) and V2 (JSON) protocols. We only have V2.

- [ ] **Socket control modes** — Auth levels (cmux-only, automation, password, allow-all).

- [ ] **Localization** — The macOS app supports 19 languages.

- [ ] **Auto-update** — Package manager integration or self-update mechanism.

- [ ] **Configurable settings UI** — A settings window for all the options currently hardcoded.

---

## Architecture Notes

- **Language:** Zig (targeting 0.14), using `@cImport` for GTK4 and Ghostty C headers
- **UI toolkit:** GTK4 (GtkApplication, GtkGLArea, GtkPaned, GtkListBox, etc.)
- **Terminal backend:** Ghostty embedded apprt via `libghostty.so`
- **Ghostty fork:** `mattmorganpdx/ghostty` branch `matt/linux-embedded-apprt` — adds Linux platform to embedded apprt
- **Socket:** Unix domain socket at `/tmp/cmux.sock`, JSON-RPC protocol, thread-per-client
- **Build:** `zig build` produces `cmux` (GUI) and `cmux-cli` (socket client)

---

## Current State

As of 2026-03-12: The Linux port is ready for dogfooding with Claude Code integration. 42 socket API methods (41 original + `claude.hook`) have matching CLI commands. The `cmux-cli` binary supports `--socket` flag for explicit socket path override. Agent instructions are configured via `linux/CLAUDE.md`.

An AI agent can: read terminal output, send commands and keystrokes, create/close splits, navigate workspaces, resize/swap panes, discover its own terminal context via environment variables, have its workspace layout survive restarts, feed metadata into the sidebar, receive desktop notifications, use the command palette API, search terminal content, color-code and pin workspaces, reorganize panes across workspaces, and have Claude Code session status automatically reflected in the sidebar — all through the socket API or `cmux-cli`.

Phases 0-6 are complete plus Claude Code integration from Priority 6. Remaining Priority 6 items (long tail feature parity with macOS) are next.
