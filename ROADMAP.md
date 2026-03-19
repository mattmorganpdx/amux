# amux Roadmap

## Origin

amux began as a Linux port of [cmux](https://cmux.dev), a macOS terminal multiplexer built on Ghostty with SwiftUI. The port used GTK4 and Zig to reimplement the UI layer while keeping the same socket protocol and CLI interface.

During the process of building the socket API and testing terminal interaction, we realized something: **this is exactly the kind of tool an AI coding agent needs**. When an AI agent works through Claude Code, it runs commands through a stateless Bash tool — fire a command, get stdout back, done. No persistent sessions, no parallel workflows, no ability to interact with running processes. With a socket-driven terminal multiplexer, an agent can maintain sessions, split panes for parallel work, monitor long-running processes, and drive interactive programs.

That insight drove a pivot. Rather than pursuing feature parity with cmux's human-oriented macOS app, we forked the Linux port as **amux** — an agent-first terminal multiplexer that speaks the cmux protocol but prioritizes the needs of AI coding agents.

---

## What was built before the fork (as cmux Linux port)

Everything below was completed while amux was still the `linux/` directory of the cmux repo. The phases reflect the original build-up from zero Linux code to a fully dogfood-ready terminal multiplexer.

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
- [x] Unix domain socket server (`/tmp/amux.sock`)
- [x] Newline-delimited JSON-RPC protocol (cmux V2 compatible)
- [x] Background accept thread + per-client handler threads
- [x] 42 API methods implemented (see CLI reference in README)
- [x] Handle registry for ref-string generation

### Phase 5: CLI Tool
- [x] Standalone `amux-cli` binary (no GTK dependency, libc only)
- [x] All socket methods exposed as CLI commands (including history)
- [x] Socket path from `AMUX_SOCKET` / `AMUX_SOCKET_PATH` / default `/tmp/amux.sock`
- [x] JSON response output
- [x] `--surface <id>` targeting on all surface-interacting commands
- [x] `--enter` flag for send command

### Phase 6: Agent Essentials
- [x] `surface.read_text` — read terminal content (viewport or full scrollback)
- [x] `surface.send_key` — send named keystrokes (ctrl-c, enter, tab, arrows, etc.)
- [x] Environment variables per surface (`AMUX_SURFACE_ID`, `AMUX_WORKSPACE_ID`, `AMUX_SOCKET_PATH`)
- [x] Session save/restore (auto-saves every 8 seconds, atomic writes)
- [x] Shell integration scripts (bash/zsh) for git status reporting
- [x] Sidebar metadata (git branch, status entries, progress bars, log entries)
- [x] Desktop notifications via libnotify
- [x] Command palette with socket API
- [x] Terminal find/search with Ghostty integration
- [x] Pane break/join across workspaces
- [x] Claude Code integration (session tracking, sidebar status, wrapper script)

### Bug fixes completed before fork
- [x] GTK-CRITICAL assertion floods — surface registry, GObject ref counting, realized flags
- [x] Terminal resize on Linux — patched Darwin-specific clause in Ghostty fork
- [x] Workspace switching destroying sessions — replaced GtkBox with GtkStack
- [x] Node ID collisions across workspaces — shared counter in TabManager
- [x] Dead surface routing — realized check on all surface-targeting commands
- [x] Synchronous dispatch for all mutating socket operations — ResetEvent pattern
- [x] GTK widget tree crash in break/join/close — safe unparent with GType checking
- [x] Stale sidebar pane count after split/close — missing sidebar.rebuild() calls
- [x] Socket-created workspaces not appearing in sidebar — missing sidebar.rebuild() in doWorkspaceSwitch
- [x] Various CLI usability fixes (flag parsing, usage text, workspace rename with ID)

---

## What's next for amux

Now that amux is its own project, the roadmap is driven by one question: **"What does an AI agent need from its terminal environment?"** We're no longer chasing feature parity with a human-oriented macOS app.

### Agent interaction model

The Bash routing hook (Phase 1 complete) proved the concept: intercepting commands that would block the agent and redirecting them through amux's async observe-and-react model.

**Phase 2: Transparent command routing**
- [ ] Instead of blocking interactive commands, transparently rewrite them to run through amux-cli
- [ ] Send command to a pane, poll `surface read-text` for shell prompt, return output
- [ ] Handle "command is done" detection via prompt pattern matching
- [ ] Timeout fallback with partial output

**Phase 3: Smart command classification**
- [ ] Classify commands by behavior: pure reads (direct Bash), builds (dedicated pane), interactive (amux pane)
- [ ] Learn from timeouts — if a command times out via Bash, auto-route through amux next time
- [ ] Per-workspace routing: builds go to "build" pane, SSH to "remote" pane

**`amux-cli run` command**
- [ ] New CLI command that combines send + poll + return output in one call
- [ ] Handles the polling loop server-side for reliability
- [ ] Configurable timeout and prompt detection
- [ ] This is the key primitive that makes transparent routing work

### Agent awareness

The sidebar already shows metadata, but the agent can't easily see its own state.

- [ ] **Agent activity indicator** — visual indicator in sidebar when an agent is actively operating a workspace
- [ ] **Command history per pane** — socket method to retrieve recent commands sent to a pane (not just screen content)
- [ ] **Workspace templates** — create workspaces with pre-configured splits and titles (e.g., "SSH session" template with two panes)
- [ ] **Auto-workspace naming** — infer workspace name from the first command sent or the working directory

### Terminal history & audit trail

One of the key values of watching an agent work in amux is seeing what it does. These features make that observable history persistent and browsable — so you can review any session after the fact, not just while it's live.

**Scrollback persistence**
- [x] **Save full scrollback on exit** — when a terminal pane closes (or amux exits), persist the complete scrollback buffer to disk (`~/.config/cmux/history/`)
- [x] **Load scrollback on restore** — when session restore reopens a pane, replay its scrollback via `command` field so you can scroll up and see everything from the previous run
- [x] **Configurable retention** — max entries (`CMUX_HISTORY_MAX_ENTRIES`, default 100), max bytes per entry (`CMUX_HISTORY_MAX_BYTES`, default 10MB), disable with `CMUX_HISTORY_DISABLED=1`

**Session history browser**
- [x] **Terminal session log** — index at `~/.config/cmux/history/index.json` tracks every terminal session: pane ID, workspace name/ID, close time, line/byte counts, working directory, close reason
- [x] **`amux-cli history list`** — CLI command to list past sessions with timestamps and metadata (supports `--workspace` and `--limit` filters)
- [x] **`amux-cli history show <id>`** — retrieve the full saved scrollback for a past session
- [x] **`amux-cli history search <query>`** — search across all saved session scrollbacks and metadata
- [x] **`amux-cli history delete <id>`** — remove a history entry
- [ ] **In-app history browser** — GUI panel to browse past sessions, preview scrollback, and optionally restore a session's working directory in a new pane
- [ ] **Session tagging** — tag sessions with labels (e.g., "deploy 2026-03-18", "debug auth bug") for easier retrieval

### Reliability

- [ ] **`workspace next`/`previous` wrap-around** — currently errors at boundaries, should optionally wrap
- [ ] **Connection health monitoring** — detect when SSH sessions die, notify the agent
- [ ] **Process status per pane** — track whether the shell is at a prompt or running a command
- [ ] **Crash recovery** — if amux crashes, restore sessions from the last auto-save on relaunch

### Developer experience

- [ ] **Multi-window** — multiple independent GTK windows, each with their own workspace set
- [ ] **Open-in-IDE** — open current directory in VS Code, Zed, etc.
- [ ] **Configurable settings UI** — settings window for options currently hardcoded
- [ ] **Auto-update** — package manager integration or self-update mechanism

### Protocol

- [ ] **Document the socket protocol** — formal spec for the 42 JSON-RPC methods, so other tools can integrate
- [ ] **V1 text protocol** — simpler text-based protocol for lightweight integrations
- [ ] **Socket authentication** — auth levels for multi-user or remote access scenarios

---

## Architecture

- **Language:** Zig 0.14, `@cImport` for GTK4 and Ghostty C headers
- **UI toolkit:** GTK4 (GtkApplication, GtkGLArea, GtkPaned, GtkListBox, etc.)
- **Terminal backend:** Ghostty embedded apprt via `libghostty.so`
- **Ghostty fork:** `mattmorganpdx/ghostty` branch `matt/linux-embedded-apprt` — adds Linux platform to embedded apprt
- **Socket:** Unix domain socket at `/tmp/amux.sock`, JSON-RPC protocol, thread-per-client
- **Build:** `zig build` produces `amux` (GUI) and `amux-cli` (socket client)

---

## Current state

As of 2026-03-19: amux is a fully functional agent-first terminal multiplexer with 46 socket API methods, a complete CLI, session persistence with scrollback history, Claude Code integration, and a Phase 1 Bash routing hook. Terminal history is saved on pane close and app exit, and restored on session reload. It is being actively dogfooded — this roadmap was written, and the bugs in it were found and fixed, by an AI agent using amux as its own development environment.
