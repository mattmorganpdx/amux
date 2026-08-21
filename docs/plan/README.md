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
| 4 | Move socket handlers behind the daemon, and the pane tree / workspaces with them | 3 |
| 5 | Screen-state wire protocol (snapshot + delta) | 3 |
| 6 | GUI becomes an attach client | 1, 5 |
| 7 | systemd socket activation | 4 |
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

## 4. Move socket handlers behind the daemon

Now also carries the pane tree, workspaces and session persistence, deferred
from item 3 because they need the handlers as consumers.

`src/socket/handlers/` should largely move as-is — this is the payoff from the
per-domain split. `server.zig` becomes the daemon's front door. Handlers that
currently dispatch to the GTK main thread instead act directly on daemon state,
which removes `runOnMainThread` from those paths entirely.

Watch: `handlers/surface.zig` and `handlers/pane.zig` reach into `Window`, so
they need the equivalent daemon-side accessors before they can move.

## 5. Screen-state wire protocol

How an attached client learns what to draw. Snapshot on attach, deltas after.

Start with the cheapest correct thing — whole viewport on change — then measure
before optimising to dirty rows or damage rects. Getting attach correct matters
more than getting it cheap, and this is the piece that made the "output tee"
alternative unworkable.

## 6. GUI becomes an attach client

Drop PTY ownership from the GUI. `terminal_widget.zig` becomes a renderer over a
locally-held `Terminal` populated from item 5; most of `window.zig`'s widget
lifecycle logic goes away with it.

These are the two most recently hardened files in the codebase, so expect to
retire fixes along with the code — including the `onRealize` surface-leak fix,
which only exists because the GUI owns surfaces.

## 7. systemd socket activation

`amux.socket` + `amux.service` user units, so the first `amux-cli` call starts
the daemon. This is what actually delivers "just ready to go" — without it an
agent still has to care whether a process is running.

Include: socket path resolution consistent with the existing
`AMUX_SOCKET` → `AMUX_SOCKET_PATH` → `/tmp/amux.sock` order, and the `0600`
permission behaviour (systemd creates the socket, so the umask trick in
`server.zig` stops applying — the unit needs `SocketMode=0600`).

## 8. Scrollback and history into the daemon; pick a store

Scrollback lives with the terminal, so it moves to the daemon. That makes
history coherent — today it is saved by whichever widget owns the pane at close
time.

Decide the storage engine. SQLite is the leading candidate for search,
retention and audit. Note `ghostty-vt` exports `search` over its own
`PageList`, so decide deliberately where live-scrollback search ends and
database search over closed sessions begins, rather than duplicating both.
