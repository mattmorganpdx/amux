# Work plan: daemon separation

Design and spike findings: [`../architecture/daemon-split.md`](../architecture/daemon-split.md).

Tracked here rather than in GitHub issues because the available token has no
`issues: write` scope. Each item is scoped tightly enough to pick up cold
without reading the others.

Roughly dependency-ordered. **D** = de-risking, do early.

| # | Item | Depends on |
|---|------|-----------|
| 1 | **D** Prototype: Ghostty OpenGL renderer drawing an amux-owned `Terminal` | — |
| 2 | Wire `ghostty-vt` into amux's build as a Zig module | — |
| 3 | `amuxd`: own PTYs and terminal state | 2 |
| 4 | Move socket handlers behind the daemon | 3 |
| 5 | Screen-state wire protocol (snapshot + delta) | 3 |
| 6 | GUI becomes an attach client | 1, 5 |
| 7 | systemd socket activation | 4 |
| 8 | Scrollback + history into the daemon; pick a store | 3 |

---

## 1. Prototype the renderer against an amux-owned Terminal — **D**

The spike established this is feasible by reading the code: `renderer.State`
takes a bare `*terminal.Terminal`, `rt_surface` is dereferenced only by the
Metal backend, and `surface_mailbox` carries two stubbable notifications. Not
yet proven by building.

Build the smallest thing that draws: a GTK window with one `GtkGLArea`, a
`terminal.Terminal` that amux constructs and fills with static text, and
Ghostty's OpenGL renderer pointed at it via a hand-built `renderer.State`.
Requires satisfying `renderer.Options` — `DerivedConfig`, `*font.SharedGrid`,
`Size`, `*renderer.Thread`, and stubs for `rt_surface` / `surface_mailbox`.

Done when glyphs from an amux-owned `Terminal` appear on screen. If this turns
out to need real fork surgery, the GUI needs its own text renderer and the whole
estimate changes — which is why it goes first.

## 2. Wire `ghostty-vt` into the build

`zig build lib-vt` in the submodule already produces `libghostty-vt.so` and the
`ghostty-vt` Zig module; verified building clean. Consume the **Zig module**,
not the C API — the generated headers cover only OSC/color/SGR/key, while the
module exports `Terminal`, `Screen`, `PageList`, `Parser`, `Stream`, `search`.

Extend `setup.sh` to build it alongside `libghostty.so`, and add the module to
`build.zig` so both `amuxd` and the GUI can import it.

## 3. `amuxd`: own PTYs and terminal state

The daemon proper. Spawn shells on PTYs, feed output through a `ghostty-vt`
`Terminal` per pane, expose read/write. No GL, no GTK — it must run under
systemd with no display.

Also moves here: the pane tree, workspaces, session persistence. Terminal size
is fixed (settled decision), so no client size negotiation.

## 4. Move socket handlers behind the daemon

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
