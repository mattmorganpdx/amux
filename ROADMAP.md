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
- [x] **Content deduplication** — `saveScrollback` compares against the most recent entry for the same workspace+pane; skips save if content is byte-identical, preventing duplicate entries on repeated app exits

**Session history browser**
- [x] **Terminal session log** — index at `~/.config/amux/history/index.json` tracks every terminal session: pane ID, workspace name/ID, close time, line/byte counts, working directory, close reason
- [x] **`amux-cli history list`** — CLI command to list past sessions with timestamps and metadata (supports `--workspace` and `--limit` filters)
- [x] **`amux-cli history show <id>`** — retrieve the full saved scrollback for a past session
- [x] **`amux-cli history search <query>`** — search across all saved session scrollbacks and metadata
- [x] **`amux-cli history delete <id>`** — remove a history entry
- [x] **In-app history browser** — GTK overlay panel (Ctrl+Shift+H) to browse past sessions, preview scrollback, and restore as a new workspace with the original cwd and scrollback replayed
- [ ] **Session tagging** — tag sessions with labels (e.g., "deploy 2026-03-18", "debug auth bug") for easier retrieval

### Reliability

- [x] **Force `TERM=xterm-256color`** — Ghostty's resource directory resolver false-positives on ncurses-shipped terminfo entries (e.g. Arch Linux), setting `TERM=xterm-ghostty` which doesn't exist on most systems, breaking backspace and other keys. Fixed via `resources/ghostty.conf` loaded as amux defaults before user config.
- [ ] **`workspace next`/`previous` wrap-around** — currently errors at boundaries, should optionally wrap
- [ ] **Connection health monitoring** — detect when SSH sessions die, notify the agent
- [ ] **Process status per pane** — track whether the shell is at a prompt or running a command
- [ ] **Crash recovery** — if amux crashes, restore sessions from the last auto-save on relaunch

### Hardening

Identified via full code review (2026-03-19). These are correctness and safety issues in the existing codebase, not new features.

**Safety & thread correctness**
- [x] **`surface_registry` mutex** — added `std.Thread.Mutex` to protect global HashMap from concurrent GTK/Ghostty thread access (`src/terminal_widget.zig`)
- [x] **`ResetEvent.wait()` timeouts** — all 12 `ctx.done.wait()` calls replaced with `timedWait(10s)`; returns error response on timeout, leaks ctx to avoid use-after-free (`src/socket/handlers.zig`)
- [x] **Surface lifetime in handler closures** — root cause was broader than first described: `pane_widgets` is an unsynchronized `AutoHashMap` that socket handler threads read while the GTK thread does `put`/`remove`/`deinit`, and `handleSurfaceRun` held a `*TerminalWidget` across a multi-second poll loop calling into libghostty directly off-thread. Fixed by moving *all* pane→surface resolution onto the GTK main thread: new `runOnMainThread` primitive plus per-handler `run()` contexts that take a pane id and do the lookup inside the callback (`src/socket/handlers.zig`). `surface.run` now re-resolves the pane on every poll tick, so closing a pane mid-run returns `dead_surface` instead of dereferencing freed memory. Verified live: closing a pane during `run --timeout 40 "sleep 35"` returns cleanly with the app still alive
- [x] **`surface.run` timeout was unbounded** — a caller-supplied `timeout` pinned a handler thread indefinitely; now clamped to 600s (`max_run_timeout_secs`)
- [x] **`@intCast` bounds checks** — all 25+ unchecked `i64`→`u64`/`usize` casts replaced with `toU64()`/`toUsize()` helpers that return null on negative values (`src/socket/handlers.zig`)
- [x] **`claude_session_store` iterator invalidation** — `consume()` now finds the match key first, then removes after iteration (`src/claude_session_store.zig`)
- [x] **History truncation UTF-8 safety** — `saveScrollback` now walks forward past UTF-8 continuation bytes at the truncation boundary (`src/history.zig`)

**Protocol hardening**
- [x] **Parse JSON once in `protocol.zig`** — `Request` now stores a `std.json.Parsed(Value)` and caches the `params` ObjectMap; `getXParam()` methods do simple lookups instead of re-parsing
- [x] **Socket request size bounds** — `handleClient` now detects when leftover fills the buffer (line > 8KB) and sends `request_too_large` error response (`src/socket/server.zig`)
- [x] **Clipboard null dereference** — explicit null check on `gdk_clipboard_read_text_finish` result before passing to Ghostty (`src/clipboard.zig`)
- [x] **Path traversal via history entry IDs** — `history.show` / `history.delete` accepted an arbitrary socket-supplied `id` that was interpolated straight into a filesystem path, allowing any `.txt` file on the system to be read or deleted. IDs are now validated against `[A-Za-z0-9_-]` at `entryFilePath`, the single choke point all history paths flow through, and `deleteEntry` verifies the id is in the index before unlinking anything (`src/history.zig`)
- [x] **`tab_manager` data race** — `tab_manager.workspaces` is appended to and freed from on the GTK thread while ~20 socket handlers walked it directly; a `workspace list` concurrent with a create could walk a reallocated buffer and dereference freed `*Workspace`. `workspace.create` was worse — it performed the append itself from a handler thread. All read-only handlers now build their JSON on the main thread (`JsonOnMain` / `respondFromMainThread`), and all metadata mutations go through `WorkspaceMutationCtx`. Verified with 10 concurrent clients issuing ~1,900 requests while workspaces and panes were created/closed underneath: no crash, consistent final state, zero log errors
- [x] **`system.identify` emitted invalid JSON** — `workspace_title` was interpolated unescaped, so any workspace title containing `"`, `\`, or a control character produced an unparseable response (`src/socket/handlers.zig`)
- [x] **CLI accepted non-finite floats** — `set-progress <id> inf` and `pane resize <id> <dir> nan` produced bare `inf`/`nan` tokens, which are not valid JSON; `argFloat` now rejects them (`cli/main.zig`)
- [x] **`Params.float` scratch buffer too small** — `{d}` prints floats without an exponent, so large magnitudes need ~310 integer digits; a 32-byte buffer rejected legitimate values with a misleading "Params too long" (`cli/main.zig`)
- [x] **Leaked client thread per connection** — `acceptLoop` discarded the spawned thread handle with `_ =`, so it was neither joined nor detached and never released its stack or bookkeeping. `amux-cli` opens a fresh connection per command, so an agent driving amux leaked ~28.5KB per command. Fixed with `thread.detach()`; measured 11,408kB → 0kB over 400 requests (`src/socket/server.zig`)

**CLI robustness**
- [x] **Validate numeric IDs** — all id/limit/timeout/fraction/amount arguments are parsed and validated before they reach the wire; invalid input reports a clear error instead of emitting malformed JSON (`cli/main.zig`)
- [x] **Oversized inputs in fixed-size param buffers** — not memory-unsafe as originally described (`bufPrint`/`fixedBufferStream` return `NoSpaceLeft`, which was caught), but the error messages were wrong and escaping expansion was unaccounted for. Overflow is now tracked centrally by the `Params` builder, which refuses to emit a truncated object (`cli/main.zig`)
- [x] **CLI truncated large responses** — `sendAndPrint` did a single 64KB `read()`, so `surface read-text --scrollback` and `history show` (50MB cap) were silently cut off, and stream sockets can short-read at any size. Now reads to the newline delimiter; verified with a 500KB response delivered in 8KB chunks (`cli/main.zig`)
- [x] **Silent JSON parse failures** — a malformed Claude hook payload on stdin was caught as `null`, so a broken payload was indistinguishable from an empty one. The hook still succeeds (its workspace/surface ids come from the environment, not stdin) but now warns on stderr naming the parse error (`cli/main.zig`)
- [x] **Fix `CMUX_*` → `AMUX_*` env vars** — renamed all env vars, config paths, UI strings, and resource files from `cmux` to `amux`; moved `~/.config/cmux` to `~/.config/amux`

**Code quality**
- [x] **Shutdown use-after-free** — `Server.deinit` runs from `main()` after `g_application_run()` returns and freed `registry`, `claude_session_store`, `socket_path` and `self` while detached `handleClient` threads were still dereferencing them; `stop()` joined only the accept thread. Now every accepted socket is registered before its thread spawns, `stop()` `shutdown()`s the listener (a bare `close()` does not reliably return a blocked `accept()`) and then every client socket to wake threads parked in `read()`, and waits for the in-flight count to drain. If the drain times out, teardown is skipped and the allocations are deliberately leaked — the process is exiting, and leaking is strictly safer than freeing memory a live thread is about to touch. Verified: clean shutdown and shutdown with 8 handlers blocked in `read()` both exit in ~0.04s with full teardown; a handler stuck mid-dispatch trips the 11s drain cap, logs, skips teardown, and still exits 0 with no crash (`src/socket/server.zig`)
- [x] **No explicit socket permissions** — the socket inherited whatever the umask allowed (observed `0775`). Anyone who can connect can drive every terminal amux owns, so it is now created `0600`, verified with `stat`. The umask is set around `bind()` rather than `chmod`ing afterwards, which would leave a window open (`src/socket/server.zig`)
- [x] **`notification_store` had no synchronization at all** — audited and fixed. All six call sites run on socket handler threads (two Claude Code hook events firing at once is enough to overlap them), yet the ring buffer had no mutex, unlike `claude_session_store`. Three distinct bugs:
  - **`list` wrote past its allocation and crashed the app.** It sized `result` from one read of `count`, then bounded its loop on `while (out_idx < self.count)` — re-reading a value a concurrent `add` could grow. Reproduced under load: `thread panic: index out of bounds: index 7, len 7` at `notification_store.zig:91`, killing the whole process from ordinary socket traffic (silent heap corruption in ReleaseFast). `count` is now read exactly once.
  - **`clear(<id>)` silently dropped an unrelated notification.** It decremented `count`, but `count` is the width of the ring window rather than a tally of live entries, so shrinking it pushed the *oldest* entry out of view. Verified: clearing `N5` of `N1..N5` returned `N4,N3,N2` — `N1` vanished. Cleared entries are now tombstoned in place without touching `count`.
  - **`clear` compared ids against uninitialized memory.** The ring was `= undefined`, so the scan read never-written slots (undefined behaviour, and a spurious match would have corrupted `count`). The ring is now zero-initialised and the scan confined to the live window.
  - Added a mutex covering all state, released before the libnotify call so a blocking DBus round-trip cannot stall other handlers.
- [x] **libnotify was called from socket handler threads** — `showDesktopNotification` invoked `notify_notification_new`/`show` directly from whichever handler thread served the request, so it drove libnotify and the GLib main context off-thread and could race `notify_init` (which runs in `onActivate`). The show is now queued onto the GTK main thread via `g_idle_add`, with the title/body copied into a heap payload the callback frees — the handler's request arena is long gone by then. Deliberately fire-and-forget rather than a synchronous dispatch, so a slow DBus round-trip cannot stall a socket handler. Verified: 1,000 notifications add 0kB (unrun callbacks would leak ~758kB per round, so a flat profile proves they fire), the concurrent create/list/clear stress stays clean, and shutdown drains queued callbacks and exits 0 (`src/notification_store.zig`)
- [x] **Split `handlers.zig` by domain** — the file had grown to 3,399 lines. `handlers.zig` is now a 189-line router that maps method names onto per-domain modules in `src/socket/handlers/`: `common` (main-thread dispatch, surface resolution, JSON building), `system`, `workspace`, `surface`, `pane`, `window_api`, `notification`, `palette`, `claude`, `history`. Handler bodies moved verbatim, with each module aliasing the shared infrastructure so no body text changed — a line-multiset diff against the previous file shows the only differences are the removed monolith imports and the router's new imports, i.e. zero logic lines altered. Verified behaviour-preserving by capturing all 44 socket API responses (normalised for clocks, paths and per-process counters) from both builds against the same session state: byte-identical
- [x] **Segfault in libghostty on shutdown after pane churn** — was 3/3 reproducible; now 8/8 clean exits. Three separate defects, localised by marking each cleanup step in `main()`:
  - **`ghostty_app_free` raced live Ghostty threads.** The fault was inside `app.deinit()`: surfaces that were still alive kept their renderer/io threads running against app state the free tore down. Initially worked around by skipping the free at exit, on the mistaken belief that `ghostty_surface_free` never joins those threads. It does — the leak was amux's, and once surface lifetime was fixed (see the entry below) the real teardown became safe and was restored. Verified 8/8 clean exits with `app.deinit()` back in place.
  - **Closing a workspace leaked every pane's terminal widget.** `tw.deinit()` was only ever called from `closePane` and `Window.deinit`, so `closeWorkspaceById`/`closeWorkspaceByIndex` dropped the `Workspace` and its pane tree while leaving each `TerminalWidget` — and its Ghostty surface — allocated for the rest of the process. Halved the leak: thread growth went from 12 to 6 per workspace and RSS growth over 24 workspaces from ~350MB to ~289MB. Traversal starts at the pane-tree root so a pane moved out by `joinPaneToWorkspace` is never destroyed; verified by breaking a pane out and joining it back (which closes the emptied source workspace) and confirming the pane still reads.
  - **`doSetTitle` touched a destroyed window.** Ghostty can emit a title change at any time, and `global_window` stays set until `main()` finishes its exit path, so a late idle callback called `gtk_window_set_title` on freed memory — the `Gtk-CRITICAL` seen in the logs. A `closing` flag set on close-request now short-circuits it.
  - Teardown order matters and is now the same as `closePane`: read scrollback while surfaces are live, let GTK tear the hierarchy down (unrealising each surface so Ghostty stops calling into it), then free. Freeing first crashed on a glib worker thread instead.
- [x] **Every re-realize abandoned a Ghostty surface** — this was previously recorded here as libghostty failing to join a surface's renderer/io threads. That was wrong: `Surface.deinit` in the Ghostty fork joins both, and the leak was amux's own. `TerminalWidget.onRealize` assigned `self.surface = ghostty_surface_new(...)` unconditionally, while `onUnrealize` deliberately keeps the handle non-null so a transiently unrealized pane stays readable. GTK unrealizes and re-realizes a `GtkGLArea` whenever the widget is reparented — which the workspace rebuild, pane close and break/join paths all do — so each cycle overwrote the handle and abandoned a whole surface: renderer, io and io-reader threads, plus its PTY and child shell, for the rest of the process. `onRealize` now frees any leftover surface first.
  The earlier measurements that pointed at libghostty were confounded twice over: session restore was still realizing panes during the sampling window, and Ghostty's logger is not wired into amux's stderr, so the absence of its `surface closed` line proved nothing. Re-measured from a clean `XDG_CONFIG_HOME` with settling time between samples: surfaces went 1 → 4 → 6 → 9 → 12 across split/close and workspace churn before the fix, and hold at 1 after it. Functionally identical either way — a control run on the unfixed build shows the same panes responding and the same ones left unrealized by headless GL
- [x] **Extract CLI helper for JSON formatting** — replaced all 35 `bufPrint` format strings with a `Params` builder that escapes strings and validates numerics in one place (`cli/main.zig`)
- [x] **Named constants for buffer sizes** — the repeated literals now have names that say what they bound: `params_small`/`params_medium`/`params_large`, `max_hook_stdin`, `response_chunk_bytes`, `max_request_bytes` and the hook field caps in `cli/main.zig`; `max_request_bytes` and `socket_path_buf_len` in `server.zig` (the request-too-large message now formats the real cap instead of a hardcoded 8192); `std.fs.max_path_bytes` in place of a bare 4096 for all 22 path buffers across `history.zig`, `session.zig` and `window.zig`; and named chunk/command sizes where 4096 meant something else. Naming them surfaced a real bug: the CLI's params buffer was exactly `max_request_bytes`, so a maximally sized `send` built fine and then would not fit the request line — `params_large` is now the cap minus an envelope reserve. Only three tiny formatting scratch buffers keep bare sizes
- [x] **Cap workspace history** — one id was appended on every workspace switch and never removed. Capped at `max_history` (64), dropping the oldest entry when full; only the tail is ever read (`selectLast`). The write-only `history_pos` cursor went with it — it was assigned on every switch and never read (`src/tab_manager.zig`)

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

- **Language:** Zig 0.15.2 (pinned in `build.zig`), `@cImport` for GTK4 and Ghostty C headers
- **UI toolkit:** GTK4 (GtkApplication, GtkGLArea, GtkPaned, GtkListBox, etc.)
- **Terminal backend:** Ghostty embedded apprt via `libghostty.so`
- **Ghostty fork:** `mattmorganpdx/ghostty` branch `matt/linux-embedded-apprt` — adds Linux platform to embedded apprt
- **Socket:** Unix domain socket at `/tmp/amux.sock`, JSON-RPC protocol, thread-per-client. `src/socket/handlers.zig` routes; per-domain handlers live in `src/socket/handlers/`
- **Build:** `zig build` produces `amux` (GUI) and `amux-cli` (socket client)

---

## Current state

As of 2026-08-19: amux is a fully functional agent-first terminal multiplexer with 47 socket API methods, a complete CLI, session persistence with scrollback history, Claude Code integration, and a Phase 1 Bash routing hook. Terminal history is saved on pane close and app exit (with content deduplication to avoid redundant saves), and restored on session reload. An in-app history browser (Ctrl+Shift+H) lets users browse, preview, and restore past terminal sessions as new workspaces. The `amux-cli run` command enables agents to send a command and get output back in a single call with prompt detection. A full code review identified thread safety, input validation, and protocol hardening issues now tracked in the Hardening section — 31 are fixed, none open. The most significant round closed a use-after-free and data race on `pane_widgets` (all pane→surface resolution now happens on the GTK main thread), a path traversal through history entry IDs, unescaped user text in every CLI-built JSON request, and a per-connection thread leak in the socket server. The project pins Zig 0.15.2; Zig 0.16 cannot build it because translate-c fails on the GTK4 headers. TERM is forced to xterm-256color and dark mode is enabled by default. It is being actively dogfooded — this roadmap was written, and the bugs in it were found and fixed, by AI agents using amux as their own development environment.
