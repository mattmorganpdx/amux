# Daemon / GUI / CLI separation

Status: **design, spike complete**. Nothing implemented yet.

## The problem

The socket server lives inside the GUI process (`Server.init` is called from
`onActivate` in `src/main.zig`), and every PTY is owned by a `TerminalWidget`
bound to a `GtkGLArea`. `amux-cli` is only a socket client. No GUI, no amux.

Stated as a design flaw rather than an inconvenience:

> The agent-facing capability is implemented on top of the rendering layer.

An agent needs persistent shells, a way to write bytes, and a way to read the
screen. No pixels, no GL, no Ghostty. The GUI needs to draw a terminal well,
which is what Ghostty is for. Today the first is built on the second, so the
agent is hostage to a window being open. Every symptom follows from that one
inversion: sessions die with the window, the agent cannot start work unless a
human has launched a GUI, and two users cannot share state.

## Target shape

```
              ┌──────────────────────────────┐
              │  amuxd  (systemd user unit)  │
              │  owns: PTYs, terminal state, │
              │  pane tree, workspaces,      │
              │  scrollback, history         │
              └──────────────┬───────────────┘
                     unix socket (JSON-RPC)
                ┌────────────┴────────────┐
                │                         │
        ┌───────▼───────┐         ┌───────▼───────┐
        │  amux (GUI)   │         │   amux-cli    │
        │  renders      │         │  agent client │
        │  daemon state │         │               │
        └───────────────┘         └───────────────┘
```

The daemon is authoritative. The GUI is a viewer that attaches and detaches.
The CLI is unchanged in spirit — it already talks to a server.

## Spike findings

The question that gated this design: **can Ghostty's renderer draw a terminal
that amux owns, rather than one owned by a Ghostty `Surface`?** If not, the GUI
needs its own text renderer and the cost roughly doubles.

Answer: **yes, on Linux, with a modest change to the fork.**

1. **Per-frame render state is already decoupled.**
   `ghostty/src/renderer/State.zig` is `{ mutex: *std.Thread.Mutex, terminal:
   *terminal.Terminal, inspector, preedit, mouse }`. No `Surface`, no apprt, no
   PTY, no termio. The renderer reads a plain `*Terminal` behind a mutex.

2. **The `Surface` coupling is in construction only, and is vestigial here.**
   `renderer/Options.zig` wants `rt_surface: *apprt.Surface` and
   `surface_mailbox`. But `rt_surface` is dereferenced *only* by `Metal.zig`
   (macOS) — the OpenGL backend never touches it. `surface_mailbox` carries two
   optional notifications, scrollbar state and renderer health, both safe to
   stub.

3. **A headless terminal engine already exists and builds.**
   Ghostty ships `libghostty-vt` as a first-class target. `zig build lib-vt`
   produces `libghostty-vt.so` plus the `ghostty-vt` Zig module
   (`src/lib_vt.zig`), exporting `Terminal`, `Screen`, `PageList`, `Page`,
   `Parser`, `Stream`, `Selection`, `Pin`, `Cell`, `RenderState`, `search` and
   `highlight`. No GL, no GTK. Verified building clean in this tree.

4. **Consume it as a Zig module, not via C.** The generated C headers
   (`include/ghostty/vt/`) cover only OSC, color, SGR, key and paste — not
   `Terminal` or `Screen`. The Zig module exposes everything. amux is Zig, so
   this is the better path anyway.

Consequence: the daemon gets a battle-tested VT parser and scrollback without
writing one, and the GUI keeps Ghostty's renderer.

### A design that was considered and rejected

**Output tee**: daemon owns the PTY, GUI runs ordinary Ghostty surfaces fed a
copy of the PTY stream, input routed back through the daemon. Attractive
because it keeps Ghostty entirely intact.

Rejected because **attach is the whole point**. A client attaching mid-stream
has no history, so its grid starts blank; correct attach requires transferring
current screen state, and a Ghostty `Surface` cannot be initialised from a
foreign snapshot. It also means two independent VT models that can diverge on
resize and alt-screen — and alt-screen detection is exactly what Smart Wake
depends on.

So: one authoritative VT model in the daemon, and the GUI renders it.

## Settled decisions

- **Terminal size is a fixed condition.** Single-user tool. Multi-client size
  negotiation (tmux "smallest client wins", per-client reflow) is explicitly out
  of scope until the tool has users who need it.
- **Scrollback and history move to the daemon.** This makes the existing history
  feature more coherent: today it is saved by whichever widget happens to own
  the pane at close time.
- **No named sessions initially.** One implicit daemon instance, with workspaces
  as the unit of organisation. A minimal namespace is still needed so the GUI
  knows what to attach to, but zellij-style named sessions are a later nicety,
  not an architectural requirement.
- **systemd socket activation.** An `amux.socket` unit so the first `amux-cli`
  call starts the daemon on demand. This is the piece that actually delivers
  "just ready to go"; without it the agent still has to care whether a process
  is running.

## Open questions

- **Storage engine for scrollback and audit.** SQLite is the leading candidate
  (search, retention queries, no server). Note `ghostty-vt` already exports
  `search` over its own `PageList`, so the split between "engine search over
  live scrollback" and "database search over closed sessions" needs deciding
  rather than assuming.
- **Wire format for screen state.** Snapshot plus deltas, but the delta
  granularity (dirty rows? damage rects? whole viewport on change?) is
  unresolved. Cheapest correct thing first: full viewport on change, measure,
  then optimise.
- **What survives of `window.zig` / `terminal_widget.zig`.** These are the files
  most reworked by this change, and also the ones most recently hardened.

## What carries over

The socket protocol is the asset. It already assumes a server, and the pane
tree, workspaces, session persistence and history all belong on the daemon side
of the seam. `src/socket/handlers/` largely moves as-is — which is why the
per-domain split was worth doing — and `server.zig` becomes the daemon's front
door mostly unchanged.

What does not carry over: `terminal_widget.zig` and most of `window.zig`.
