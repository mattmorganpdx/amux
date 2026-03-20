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

**`amux-cli run` command**
- [x] New CLI command that combines send + poll + return output in one call
- [x] Handles the polling loop server-side for reliability
- [x] Configurable timeout (`--timeout`) and prompt detection (`--prompt-pattern`)
- [ ] This is the key primitive that makes transparent routing work — integrate with agent hooks

**Phase 3: Smart Wake (event-driven polling replacement)**

Currently when an agent runs a long command (like `apt upgrade`), it has to sleep for a fixed interval and re-poll terminal state — wasting turns and tokens on dead reads where nothing changed. But a pure completion-callback model won't work either: the agent needs to **see** the terminal because commands can launch unexpected TUIs (dpkg config prompts, interactive installers) that require navigation. Smart Wake moves the polling loop from the agent into amux. amux watches the terminal buffer on a fast local loop (cheap) and wakes the agent (expensive) only when something interesting happens.

- [ ] **`surface.watch` socket method** — register a surface for event monitoring, returns a stream of wake events
- [ ] **Output stall detection** — content was flowing but stopped for N seconds (likely waiting for input)
- [ ] **Alternate screen / TUI detection** — cursor position jumps, fullscreen redraw, or terminal enters alternate screen mode (ncurses-style TUI launched)
- [ ] **Interactive prompt patterns** — detect `[Y/n]`, `(yes/no)`, password prompts, `sudo` prompts, etc.
- [ ] **Screen geometry shift** — content changes shape inconsistent with normal line-by-line scrolling
- [ ] **Command completion** — shell prompt returns after a command was running (extends `surface.run` prompt detection)
- [ ] **Wake reason classification** — each wake event includes a `wake_reason` field (`output_stalled`, `tui_detected`, `prompt_waiting`, `command_complete`) so the agent can orient without re-reading everything
- [ ] **Periodic fallback timeout** — configurable max silence interval so the agent still gets woken up as a safety net
- [ ] **`amux-cli watch` command** — CLI interface that blocks until a wake event, prints the event + current terminal state
- [ ] **Multi-pane watch** — monitor multiple surfaces simultaneously, wake the agent about whichever one needs attention first

This is the key architectural shift from "agent drives the event loop" to "amux drives the event loop and the agent is the handler." It preserves the agent's ability to react to anything on screen while eliminating wasted polling turns.

**Phase 4: Smart command classification**
- [ ] Classify commands by behavior: pure reads (direct Bash), builds (dedicated pane), interactive (amux pane)
- [ ] Learn from timeouts — if a command times out via Bash, auto-route through amux next time
- [ ] Per-workspace routing: builds go to "build" pane, SSH to "remote" pane

### Agent awareness

The sidebar already shows metadata, but the agent can't easily see its own state.

- [ ] **Agent activity indicator** — visual indicator in sidebar when an agent is actively operating a workspace
- [ ] **Command history per pane** — socket method to retrieve recent commands sent to a pane (not just screen content)
- [ ] **Workspace templates** — create workspaces with pre-configured splits and titles (e.g., "SSH session" template with two panes)
- [ ] **Auto-workspace naming** — infer workspace name from the first command sent or the working directory

### Terminal history & audit trail

One of the key values of watching an agent work in amux is seeing what it does. These features make that observable history persistent and browsable — so you can review any session after the fact, not just while it's live.

**Scrollback persistence**
- [x] **Save full scrollback on exit** — when a terminal pane closes (or amux exits), persist the complete scrollback buffer to disk (`~/.config/amux/history/`)
- [x] **Load scrollback on restore** — when session restore reopens a pane, replay its scrollback via `command` field so you can scroll up and see everything from the previous run
- [x] **Configurable retention** — max entries (`AMUX_HISTORY_MAX_ENTRIES`, default 100), max bytes per entry (`AMUX_HISTORY_MAX_BYTES`, default 10MB), disable with `AMUX_HISTORY_DISABLED=1`

**Session history browser**
- [x] **Terminal session log** — index at `~/.config/amux/history/index.json` tracks every terminal session: pane ID, workspace name/ID, close time, line/byte counts, working directory, close reason
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

### Hardening

Identified via full code review (2026-03-19). These are correctness and safety issues in the existing codebase, not new features.

**Safety & thread correctness**
- [ ] **`surface_registry` mutex** — global HashMap written from GTK callbacks (`onRealize`, `onUnrealize`) and read from Ghostty renderer threads via `actionCallback` with no synchronization (`src/terminal_widget.zig`)
- [ ] **`ResetEvent.wait()` timeouts** — socket handler threads wait indefinitely for GTK idle callbacks; a GTK thread hang deadlocks the handler forever (`src/socket/handlers.zig`)
- [ ] **Surface lifetime in handler closures** — surface pointers captured in `g_idle_add` closures can dangle if the widget is destroyed before the idle callback fires; `handleSurfaceRun` polls `readSurfaceText()` from a handler thread where the surface could be destroyed mid-poll
- [ ] **`@intCast` bounds checks** — 25+ unchecked casts from `i64` → `u64`/`usize` throughout `handlers.zig`; negative JSON values cause undefined behavior
- [ ] **`claude_session_store` iterator invalidation** — `consume()` modifies HashMap during iteration; build a removal list first, then remove after iteration (`src/claude_session_store.zig`)
- [ ] **History truncation UTF-8 safety** — `saveScrollback` truncates to `max_bytes` without checking for partial UTF-8 sequences at the boundary (`src/history.zig`)

**Protocol hardening**
- [ ] **Parse JSON once in `protocol.zig`** — every call to `getStringParam()`, `getIntParam()`, etc. re-parses the entire raw JSON line; parse once and cache the params object in `Request`
- [ ] **Socket request size bounds** — fixed 8192-byte read buffer in `server.zig` silently truncates large requests with no feedback to the client
- [ ] **Clipboard null dereference** — `gdk_clipboard_read_text_finish` result not checked for null before use (`src/clipboard.zig`)

**CLI robustness**
- [ ] **Validate numeric IDs** — command-line arguments used as JSON number fields are never validated as integers; `amux workspace select "abc"` sends malformed JSON (`cli/main.zig`)
- [ ] **Buffer overflow on long inputs** — user input injected into fixed-size buffers (256–8192 bytes) via `bufPrint` with JSON escaping that can expand input size (`cli/main.zig`)
- [ ] **Silent JSON parse failures** — `parseFromSlice` failure on stdin input caught as `null` with no error message (`cli/main.zig`)
- [x] **Fix `CMUX_*` → `AMUX_*` env vars** — renamed all env vars, config paths, UI strings, and resource files from `cmux` to `amux`; moved `~/.config/cmux` to `~/.config/amux`

**Code quality**
- [ ] **Split `handlers.zig` by domain** — 2,772-line file handles all 42+ RPC methods; split into workspace, surface, notification, pane handler modules
- [ ] **Extract CLI helper for JSON formatting** — the same `bufPrint` + error-print + return pattern appears 30+ times in `cli/main.zig`
- [ ] **Named constants for buffer sizes** — bare literals (256, 512, 4096, 8192, 65536) throughout; define named constants
- [ ] **Cap workspace history** — history buffer in `tab_manager.zig` grows without limit; use a ring buffer or cap

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

As of 2026-03-19: amux is a fully functional agent-first terminal multiplexer with 47 socket API methods, a complete CLI, session persistence with scrollback history, Claude Code integration, and a Phase 1 Bash routing hook. Terminal history is saved on pane close and app exit, and restored on session reload. The `amux-cli run` command enables agents to send a command and get output back in a single call with prompt detection. A full code review identified thread safety, input validation, and protocol hardening issues now tracked in the Hardening section. It is being actively dogfooded — this roadmap was written, and the bugs in it were found and fixed, by an AI agent using amux as its own development environment.
