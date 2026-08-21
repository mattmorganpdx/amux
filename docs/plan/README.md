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
| 6 | GUI becomes an attach client | 1, 5 |
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

## 8. Scrollback and history into the daemon — **DONE**

The store is **SQLite with FTS5**, linked from the system library (3.45.1 here,
FTS5 compiled in). Not vendored: it is already a dependency of everything else
on the machine, `amuxd` still links only libc plus sqlite3, and vendoring
370k lines to gain nothing was not worth the build time.

`src/daemon/History.zig` owns it:

- A `sessions` table plus an **external-content FTS5 index** over the content
  column, kept in sync by `sessions_ai`/`sessions_ad` triggers. External-content
  means the text is stored once, not once per index.
- WAL journal, `synchronous=NORMAL`. WAL is checkpointed on close, so a stopped
  daemon leaves a single self-contained `history.db`.
- Retention: 5000 entries or 10 MB, whichever binds first, pruned oldest-first
  on write. Both are overridable (`AMUX_HISTORY_MAX_ENTRIES`,
  `AMUX_HISTORY_MAX_BYTES`), and `AMUX_HISTORY=0` disables archiving entirely.
- `record` skips blank scrollback, truncates from the *tail* on a UTF-8
  boundary (so a split codepoint never reaches the database), and dedups
  against the previous entry for the same workspace+pane -- otherwise closing a
  pane that had already been archived stored the same screen twice.

`State` archives on all three paths that end a terminal: pane close, workspace
close, and daemon exit, each recorded with its `reason`. Scrollback only exists
while the terminal does, so `archiveAll` runs before teardown.

Handlers: `history.list` (optionally scoped to a workspace), `history.show`,
`history.search`, `history.delete`.

**Known gap: `cwd` is recorded but nothing in the daemon sets it yet.** The
column is wired end to end and asserted by test, but a workspace only gets a cwd
from the GUI or the Claude hooks, and neither is served by the daemon before
item 6. So it reads back empty today. Worth a `workspace create --cwd` flag
whenever a caller needs it -- knowing *where* an archived session ran is most of
what makes it findable later.

### Where live search ends and database search begins

The plan asked this to be decided deliberately. It is: **`ghostty-vt`'s
`PageList` search is for live panes, and SQL/FTS5 is for closed sessions.** They
do not overlap, because they cannot answer each other's question -- FTS5 has no
row for a pane that is still open, and the `PageList` is gone once the pty
closes. The seam is the archive write. A future "search everything" call is a
union of the two, not a third mechanism.

### Query strings are untrusted input

FTS5's `MATCH` grammar makes ordinary text a syntax error: `a-b`, `"unclosed`,
`NEAR(`, a bare `OR`. A search box that reports "malformed MATCH expression" is
useless, so `search` **falls back to `LIKE`** when the FTS query does not parse.
Verified against each of those inputs plus `deploy*`; all return results or an
empty set, never an error.

### The bug this turn actually found

**Shutdown aborted the daemon.** Wiring archive-on-exit meant stopping the
daemon for real, repeatedly, and that exposed a race left by item 7. `stop()`
closed the listening descriptor *before* joining the accept thread. A client
arriving in that window left `accept()` running on a closed fd, and Zig's std
maps `EBADF` to `unreachable` -- so a clean SIGTERM became SIGABRT and a core
dump, taking the archive-on-exit write with it.

The fix is ordering: join first, then close. The accept loop already polls with
a timeout, so it notices `running` going false on its own and needs no wake-up.
This is the third bug in this exact teardown path, and the pattern in all three
is the same -- a resource freed while another thread could still touch it. The
regression test connects a client and stops in the same breath, twelve rounds;
reverting the ordering reproduces the abort, so the test bites.

9 store tests, 37 total. Verified live end to end: archive on pane close, on
workspace close and on daemon exit; entries queryable after a full daemon
restart; FTS finding a marker in the right pane; workspace-scoped listing;
delete removing the row *and* its index entry; and two consecutive clean
shutdowns at exit 0 with the WAL checkpointed.

