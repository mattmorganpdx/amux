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
| 5 | ~~Screen-state wire protocol (snapshot + delta)~~ **done** | 3 |
| 6 | ~~GUI becomes an attach client~~ **done** | 1, 5 |
| 7 | ~~systemd socket activation~~ **done** | 4 |
| 8 | ~~Scrollback + history into the daemon; pick a store~~ **done** | 3 |

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

## 5. Screen-state wire protocol — **DONE**

`surface.screen` returns the screen as cells: dimensions, colours, cursor and
styled text. `src/daemon/screen_json.zig` is the format, and it serializes
ghostty's own `RenderState` rather than a representation of amux's own devising
-- upstream already maintains a render-facing view of a terminal, and keeping a
second idea of what a terminal looks like is how the two drift apart.

### One constraint drove the whole design

`RenderState.update` **consumes** the terminal's dirty flags, and its per-row
`dirty` booleans are meant for a single renderer that clears them once it has
drawn. So at most one render state can exist per terminal, and its dirty flags
cannot be read twice.

That is fine for one renderer and useless for a daemon, which may have several
clients at different positions. So the pane owns the one render state and folds
those consume-once flags into **monotonic per-row sequence numbers**: on every
refresh the pane bumps a counter and stamps it onto the rows that changed. A
number can be compared by any number of readers; a flag that clears itself
cannot.

Everything else falls out of that:

- **Deltas are stateless on the server.** A client sends the seq it last saw and
  gets back the rows stamped later than that. The daemon keeps nothing per
  client, so a client can reconnect, skip updates or run behind without the
  daemon tracking it.
- **Attach is just `since = 0`.** A snapshot and a delta are the same code path,
  so there is no separate attach handshake that can disagree with the update
  path -- which is the part the plan said mattered most.
- **Several clients can watch one pane.** Verified with two following the same
  pane: both received identical, complete update streams.

### Deviation: per-row deltas immediately, not whole-viewport-then-measure

The plan said to send the whole viewport on every change and measure before
optimising. The measurement turned out to be the cheap part and the
"optimisation" was already computed upstream -- ghostty tracks which rows
changed whether or not anyone asks. Reading a flag it already sets is not a
premature optimisation, so the first version does per-row deltas.

Measured with two clients following a pane printing a line every 300ms for six
seconds: **28 rows sent where full screens would have been 336, or 8%.** A full
80x24 attach is about 3KB.

### Waiting, and why it is not called `surface.watch`

`timeout_ms` turns the call into a wait: the daemon answers the moment the
screen changes, or reports `changed: false` at the deadline. Measured wake
latency is ~10ms against output arriving a second into a five-second wait.

It is a long poll rather than server-pushed updates. A push model needs a queue
per client, a policy for a client that reads slower than the terminal produces,
and a way to drop or coalesce when that queue fills. A client that asks again
has none of those: nothing accumulates, a client that stops asking simply stops
being served, and the reply is always the current state rather than a backlog to
replay.

The name is deliberate. The roadmap keeps `surface.watch` for Smart Wake --
semantic events for an *agent* ("a TUI appeared", "a prompt is waiting"), which
is a different question than "what should I draw". Both sit on the same change
notification inside the registry.

### Two smaller decisions

**Colours are resolved to RGB in the daemon.** Cells can name a palette index
and the program can redefine the palette, so resolving here means a client can
never render against a stale one.

**An unset default colour is omitted, not sent as black.** A terminal with no
configured theme reports its default foreground and background as unset, and
`RenderState` collapses that to `#000000` -- which would have a client draw
black text on a black background. Absent means "use your own theme", which is
the honest answer from a daemon that has no theme. Reverse video ships as a flag
for the same reason: with the defaults unset, only the client knows which two
colours to swap.

Cells are emitted as runs of equal style, each carrying its **starting column**,
so a client never infers position from character widths. That matters because a
wide character occupies two columns and its trailing spacer cell is skipped
entirely.

### Things found on the way

**A delta includes the row the cursor left.** Moving the cursor off a row marks
that row changed, because a renderer has to repaint the cell it vacated. A test
asserting "one row changed" was wrong, not the code.

**`Style.Flags` is not `pub` upstream** even though the field is, so the type
cannot be named. `src/vt.zig` derives it with `@FieldType` -- one place to fix
if upstream exports it.

**Restarting a daemon on the same socket path can unlink the new socket.** A
stopping daemon ends by deleting its socket file; start a replacement before the
old one finishes and the old one deletes the new one's path. The new daemon goes
on listening on an unlinked inode, so it logs "listening" while every client
gets "no such file". Not introduced here and not fixed here -- socket activation
avoids it, since systemd owns the path -- but it is worth knowing before
debugging a daemon that is demonstrably running and demonstrably unreachable.

### Known gaps

- **No `surface.resize` on the wire.** Terminal size is a fixed condition for
  now, by decision. The *protocol* handles a size change correctly -- a resize
  stamps every row and sets `full`, so a client throws its grid away -- there is
  just no method to ask for one.
- **The viewport only.** `RenderState` is viewport-specific, so this sends what
  is on screen, not scrollback. Scrolling an attached client means moving the
  daemon's viewport, which needs a method that does not exist yet. Item 6.

52 tests, 10 of them new. Verified by mutation: disabling the delta filter fails
the delta test, and looking the pane up once instead of on every wake turns the
close-under-a-waiting-client test into the use-after-free it was written to
catch.

## 6. GUI becomes an attach client — **DONE**

With a daemon reachable the GUI owns no terminals. It fetches `system.layout`,
builds its workspaces and pane tree from it, and each terminal widget runs
`amux-cli --socket <path> attach <pane>` onto a daemon-owned pty. Close the
window and the shells keep running; open it again and they are still there with
the screen they had.

### The plan's approach was not affordable, and this is why

Item 6 called for `terminal_widget.zig` to become a renderer over a locally-held
`Terminal` populated by item 5. That is not reachable from where amux stands:

- **The renderer is Zig-only and the C API cannot drive it.** `libghostty.so`
  exposes surfaces, which own ptys. There is no entry point to feed bytes into
  one or to point a renderer at a terminal the embedder owns.
- **A `Terminal` pointer cannot be handed across.** amux compiles its own copy of
  those types through `ghostty-vt`, and Zig does not guarantee struct layout
  across two separate builds — amux Debug against libghostty ReleaseFast is a
  silent-corruption hazard, not a shortcut.
- **So the renderer would have to be compiled in.** `renderer/OpenGL.zig` imports
  `../apprt.zig` and `../config.zig`: the whole app runtime and config system,
  plus font discovery, harfbuzz and shadertoy. That is the doubling item 1
  thought it had retired, arriving through a different door — with the spike's
  unsolved `drawFrame` segfault still on top.

The surface config has a `command` field, which makes the tmux approach
available: the daemon paints and streams, and the GUI runs a relay inside an
ordinary Ghostty surface. **That was put to the user as a decision and they chose
the relay.** The cost is real and worth naming: the GUI's surface still owns a
pty (of the relay, not the shell), and the byte stream is interpreted twice —
once by the daemon's `Terminal`, once by the GUI's.

What is *not* a cost: item 5 is what makes attaching work. The repaint is
reconstructed from the same cell data `surface.screen` serves, because new output
says nothing about what is already on screen.

### What the relay needed

`surface.output` returns raw pty bytes; omit the offset to attach and get a
repaint plus a position to stream from. `surface.input` sends bytes back. Both
base64, since these streams are mostly control characters, where `\u00xx` costs
six bytes each against base64's flat third. Panes keep a 256KB ring so a client
that looked away replays what it missed; falling further behind is reported as a
gap and answered with a repaint.

**`surface.resize`, which item 5 had deliberately deferred.** A pane sized
differently from the window is not merely cramped: the paint positions rows
explicitly, so an 80-column screen drawn into a 103-column terminal put content
in the wrong places and dropped the character at the row edge. The attached
client owns the size, because it is what knows the window.

### Following changes the window did not make

An agent splitting a pane from the CLI is the normal case here, so the GUI
watches `system.layout` and rebuilds. Structural actions in the GUI are forwarded
to the daemon and then applied locally; both sides produce the same ids because
both run the same `pane_tree.zig` from the same state, and the GUI checks that
rather than trusting it. A window records the sequence number it has accounted
for, so its own splits do not trigger a rebuild.

The rebuild restarts every relay in the workspace, which is affordable **only**
because a relay repaints on attach. In a design where the GUI held the only copy
of the screen, none of this would be safe.

### Deviation: the GUI keeps its socket server

The plan said to delete it. That turned out to be wrong once the daemon owned the
terminals: the GUI's server is the only way to drive GUI-only chrome — the
command palette, window actions, sidebar toggles — and the daemon cannot execute
those. Serving them from the daemon would need server-to-client push, which the
protocol deliberately avoids (see item 5). So the division is by *ownership*
rather than by process: terminals, layout and metadata belong to the daemon;
drawing and chrome belong to the GUI.

What did move, because it must work with no window open: workspace status,
progress, logs and git reporting, notification **records**, and the Claude hooks.
An agent reporting "needs approval" with nothing running should not lose the
message. The daemon keeps records rather than showing notifications — that needs
libnotify and a session bus, which `amuxd` does not link.

### Known gaps

- **The GUI's sidebar does not show daemon-owned metadata yet.** It draws from
  its own workspace objects, which come from the layout snapshot; the metadata is
  on the wire in `workspace.list` but the sidebar does not read it. Wiring it
  needs a second sequence number, because bumping the layout one on every
  progress update would rebuild the widget tree every second.
- **Two VT interpretations**, inherent to relaying. Item 5's cell protocol is
  still the better answer if the renderer ever becomes compilable.
- **Memory under heavy layout churn.** 24 externally driven split/close cycles
  grow RSS by 33MB. Measured against a control: the same churn on a standalone
  GUI with local panes grows it by 30MB and plateaus, so this is Ghostty surface
  creation and teardown, which predates this work. Not chased into libghostty.

63 tests. Verified live: a GUI showing content that existed before it opened,
live output arriving, GUI-initiated splits creating daemon panes with matching
ids, an agent's split and new workspace appearing in the GUI, panes surviving the
window closing and reopening, 48 rebuilds under external churn with no panics,
agent status and hooks recorded with no GUI running, the no-daemon path still
running local shells, and clean daemon exits with relays attached.
