# Work plan: daemon separation

Design and spike findings: [`../architecture/daemon-split.md`](../architecture/daemon-split.md).

Tracked here rather than in GitHub issues because the available token has no
`issues: write` scope. Each item is scoped tightly enough to pick up cold
without reading the others.

Roughly dependency-ordered. **D** = de-risking, do early.

| # | Item | Depends on |
|---|------|-----------|
| 1 | ~~**D** Prototype: Ghostty OpenGL renderer drawing an amux-owned `Terminal`~~ **done** | — |
| 2 | ~~Wire `ghostty-vt` into amux's build as a Zig module~~ **done** | — |
| 3 | ~~`amuxd`: own PTYs and terminal state~~ **done** | 2 |
| 4 | ~~Move socket handlers behind the daemon, and the pane tree / workspaces with them~~ **done** | 3 |
| 5 | Screen-state wire protocol (snapshot + delta) | 3 |
| 6 | GUI becomes an attach client | 1, 5 |
| 7 | ~~systemd socket activation~~ **done** | 4 |
| 8 | Scrollback + history into the daemon; pick a store | 3 |

---

## 1. Prototype the renderer against an amux-owned Terminal — **DONE**

Result and full findings: [`../spikes/renderer-foreign-terminal/`](../spikes/renderer-foreign-terminal/).

The renderer constructs against a `Terminal` amux allocated, with placeholder
`Surface`/`Thread` pointers, and `updateFrame` snapshots it at runtime against a
real OpenGL 4.5 context. The same source also compiles as a shared library,
which is the apprt configuration amux actually links.

Not proven: pixels. `drawFrame` needs the frame/swap-chain lifecycle that
`renderer.Thread` normally drives, which the prototype stubs. That is ordinary
integration work for item 6, not Surface coupling — reaching `updateFrame`
already required the renderer to read our terminal.

**The expensive risk in this plan is retired: the GUI does not need its own text
renderer.**

## 2. Wire `ghostty-vt` into the build — **DONE**

ghostty exposes `ghostty-vt` via `b.addModule` (`src/build/GhosttyZig.zig`), so
it is a consumable Zig package module with unicode tables, uucode and SIMD
already wired. amux now takes the fork as a path dependency in `build.zig.zon`
and pulls the module from it.

**Deviation from the original plan:** no `setup.sh` change and no
`libghostty-vt.so`. Compiling the module in is simpler than building, installing
and linking a second shared library, and it is the only option that gets
`Terminal`/`Screen`/`PageList` at all — the generated C headers expose only
OSC/color/SGR/key. `libghostty.so` is still built by `setup.sh` for the GUI's
terminal surfaces; that is unchanged.

`src/vt.zig` is the seam: one file naming exactly what amux depends on, so there
is one place to adapt when the upstream API shifts (it is documented as
unstable). It carries three tests, run by a new `zig build test` step — amux's
first tests:

- the engine constructs and reports its dimensions
- printed text reads back off the screen
- lines scrolled off the active area are still in scrollback

Verified by mutation: flipping the scrollback assertion fails the run, so the
assertions bite. Clean build cost is negligible (~8.5s, dependency artifacts sit
in the global Zig cache). The GUI still builds, runs, and shuts down clean, and
the 44-response API probe is unchanged.

The module is declared for the GUI executable too, so item 6 can `@import` it
without touching `build.zig`, but nothing in the GUI uses it yet.

## 3. `amuxd`: own PTYs and terminal state — **DONE**

`amuxd` is a third binary from the same `build.zig`, linking **only libc and
libm** — no GTK, no libghostty, no GL — so it runs under a systemd user unit
with no display. Verified with `ldd`.

- `src/daemon/Pty.zig` — a pty with a child on the far end. `forkpty` (libc,
  glibc >= 2.34) handles setsid/TIOCSCTTY/dup2; the child only chdirs and execs.
  argv, envp and cwd are all built *before* the fork, since only
  async-signal-safe calls are legal after it. Read, write, resize, reap.
- `src/daemon/Pane.zig` — a pty plus the terminal state its output parses into.
  A reader thread pumps pty bytes through a VT stream into a `Terminal` under a
  mutex. Exposes `write`, `snapshot`, `snapshotScrollback`, `resize` and exit
  detection.
- `src/daemon/Registry.zig` — panes keyed by id.
- `src/daemon/main.zig` — serve mode (idle until SIGTERM/SIGINT) plus
  `--self-check`, which spawns a shell, runs a command and reads the result back
  off the parsed screen. Runnable proof without a socket.

Two things worth knowing:

**The VT stream came for free.** `ghostty-vt` does not re-export
`ReadonlyStream`, but the type is reachable as
`@typeInfo(@TypeOf(Terminal.vtHandler)).@"fn".return_type`, so no change to the
fork was needed. Upstream describes that stream as intended for exactly this —
driving terminal state from a byte stream you are not interactively answering.

**The registry deliberately never hands out a `*Pane`.** Every operation takes
an id and does the work holding the lock. The GUI's `pane_widgets` was a bare
map callers looked into, and it produced precisely one use-after-free and one
data race. The cost is holding the lock across a pty write or a snapshot; both
are short, and it makes the hazard unrepresentable rather than merely avoided.

12 tests, all passing in under a second: pty round-trip and EOF, env and cwd
reaching the child, a hosted shell parsed into terminal state, escape sequences
interpreted rather than echoed (asserted by checking no raw ESC byte reaches the
screen), scrollback retention, child-exit detection, registry lifecycle,
unknown-id errors, write/snapshot routing between two panes, and deinit closing
everything. Confirmed the assertions bite by mutation.

**Deferred to item 4:** the pane tree, workspaces and session persistence. They
have no consumer until the handlers move, so relocating them now would be code
nothing calls. They land with item 4.

## 4. Move socket handlers behind the daemon — **DONE**

`amuxd` serves the amux socket protocol. `amux-cli` talks to it directly, with
no display and no GUI running, and sessions survive a daemon restart.

**The model layer moved as-is, and that was the payoff.** `TabManager`,
`Workspace` and `PaneTree` never depended on GTK, so `src/daemon/State.zig`
composes them with the pane Registry unchanged. `session.zig` is reused too --
only its `onAutosave` GTK timer callback is GUI-specific, and the daemon does
not use it.

**Deviation: the handlers were rewritten, not moved.** The plan expected
`src/socket/handlers/` to come across largely as-is. That held for the
*protocol* -- `protocol.zig` is reused unchanged and method names and response
shapes match -- but not for the bodies. The GUI's surface and pane handlers are
written around `Window`: they drive GtkPaned trees, rebuild the sidebar, and hop
onto the GTK main thread for every read. `src/daemon/handlers.zig` is new code
against `State`.

The upside is that all the machinery built to make the GUI safe simply is not
needed here: no `runOnMainThread`, no resolve-on-the-main-thread dance, no
leak-on-timeout contexts. There is no second thread to defer to, so a handler
takes the state lock and does the work.

`src/daemon/server.zig` is a fresh socket front door carrying every hardening
lesson from the GUI's, each noted in place: 0600 via umask around `bind`,
detached client threads, a request-size cap, `shutdown()` before `close()` so a
blocked `accept()` returns, and an in-flight drain on stop.

Implemented: `system.ping/identify/capabilities`, `workspace.list/create/
current/select/close/rename`, `surface.list/current/send_text/read_text/
send_key/split/close/run`, `pane.list`. 18 methods, reported by
`system.capabilities` along with `"daemon": true` so a client can tell what it
is talking to.

Deliberately not implemented: notifications, the command palette, the Claude
hooks and the sidebar metadata methods. Those exist to drive GUI chrome and
belong with item 6.

21 daemon tests. Verified live: headless (no `DISPLAY` in the process
environment), socket at 0600, send/read round-trip, `surface.run`, splits,
workspace lifecycle, error paths, and a full save-on-SIGTERM / restore-on-start
cycle that brought back three workspaces with their pane counts and respawned
working shells.

### Two things found on the way

**A latent inconsistency in `PaneTree`.** `TabManager.createWorkspace` already
creates the root pane, and `PaneTree.paneCount` counts every pane node in the
map rather than only those reachable from the root. Creating a second root
therefore reported one pane more than existed. State avoids it, and the restore
path clears the auto-created node before rebuilding a saved layout. The GUI has
the same shape and the same latent issue; `paneCount` was left alone because the
GUI's last-pane guard depends on its current behaviour.

**`surface.run` output extraction is a heuristic.** Two things break naive
matching, both observed: the terminal wraps the echoed command at the column
limit, so the echo on screen contains newlines the command string does not; and
the screen can scroll between snapshots, so the "before" text is not a prefix of
the "after" text. The daemon handles both. The real fix is semantic prompts --
shell integration emits OSC 133 marks and the VT engine already parses them, so
the daemon could know exactly where output starts and stops instead of guessing.
Worth doing when shell integration moves across.

### Operational note

The GUI still runs its own socket server until item 6, and both default to
`/tmp/amux.sock`. They cannot both use the default path; give one an
`AMUX_SOCKET` override while both exist.

## 5. Screen-state wire protocol

How an attached client learns what to draw. Snapshot on attach, deltas after.

Start with the cheapest correct thing — whole viewport on change — then measure
before optimising to dirty rows or damage rects. Getting attach correct matters
more than getting it cheap, and this is the piece that made the "output tee"
alternative unworkable.

## 6. GUI becomes an attach client

Also deletes the GUI's own socket server and the `Window`-based handlers, which
the daemon now supersedes, and picks up the GUI-chrome methods left out of item
4: notifications, the command palette, the Claude hooks and sidebar metadata.

Drop PTY ownership from the GUI. `terminal_widget.zig` becomes a renderer over a
locally-held `Terminal` populated from item 5; most of `window.zig`'s widget
lifecycle logic goes away with it.

These are the two most recently hardened files in the codebase, so expect to
retire fixes along with the code — including the `onRealize` surface-leak fix,
which only exists because the GUI owns surfaces.

## 7. systemd socket activation — **DONE**

`dist/systemd/` holds `amuxd.socket`, `amuxd.service` and an `install.sh` that
resolves the binary path and enables the socket. After that the first
`amux-cli` call starts the daemon: nothing is running beforehand and nothing has
to be launched by hand. Measured at 230ms for the activating call.

- The socket lives at `%t/amux.sock` (`/run/user/<uid>/amux.sock`): per-user,
  cleaned up on logout, and not in world-writable `/tmp`.
- `SocketMode=0600`, which is systemd's equivalent of the umask `server.zig`
  applies when it binds the socket itself.
- `Accept=no` (the default), so systemd hands over the listening socket and one
  daemon serves every client.
- The daemon implements the `sd_listen_fds` handshake directly rather than
  linking libsystemd: check `LISTEN_PID` against our own pid, take fd 3, then
  clear the variables so spawned shells do not inherit them.

Two discovery fixes went with it:

- **The daemon injects `AMUX_SOCKET_PATH` into every pane**, which the GUI did
  but the daemon had been missing. `amux-cli` run inside a pane therefore
  reaches the daemon that owns it with no configuration.
- **The CLI probes `$XDG_RUNTIME_DIR/amux.sock`** between the environment
  variables and the `/tmp` default. A probe rather than an unconditional
  preference, so a GUI still serving `/tmp/amux.sock` keeps working.

### Two bugs that only a real restart could find

**`stop()` was breaking systemd's socket permanently.** It called
`shutdown()` on the listener to wake a blocked `accept()`. That is right for a
socket we created and wrong for an inherited one: systemd hands the *same*
socket to the next start, so after the first stop every `accept()` failed with
`SocketNotListening` forever. Activation worked once and never again. `shutdown()`
is now only used on a socket we own, and the accept loop `poll()`s with a
timeout so it notices shutdown without needing the socket broken.

**The accept loop could spin.** With the listener permanently broken it retried
in a tight loop: 64,946 failures in two minutes, one core saturated, journal
flooded. It now gives up after 16 consecutive failures, because a listener that
keeps erroring will not fix itself.

Descriptors are also `CLOEXEC` now -- the listener and every accepted
connection. Without that each spawned shell inherited the listening socket,
leaking a descriptor per pane and keeping the socket alive if the daemon died.

Verified against real systemd user units: socket listening at 0600 with the
service inactive, activation on first connect, three stop/restart cycles each
re-activating cleanly, 0 accept errors and 7.6% CPU on the current instance,
`AMUX_SOCKET_PATH` present in panes, and `amux-cli` working from inside a pane
with the daemon's own environment stripped. The units were uninstalled and the
session file restored afterwards, so nothing was left behind.

## 8. Scrollback and history into the daemon; pick a store

Scrollback lives with the terminal, so it moves to the daemon. That makes
history coherent — today it is saved by whichever widget owns the pane at close
time.

Decide the storage engine. SQLite is the leading candidate for search,
retention and audit. Note `ghostty-vt` exports `search` over its own
`PageList`, so decide deliberately where live-scrollback search ends and
database search over closed sessions begins, rather than duplicating both.
