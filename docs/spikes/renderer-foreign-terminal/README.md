# Spike: can Ghostty's renderer draw a Terminal the embedder owns?

Work-plan item 1. This gated the daemon split: if the renderer is welded to a
Ghostty `Surface`, the GUI needs its own text renderer and the cost of the
whole plan roughly doubles.

**Result: yes.** The renderer constructs against a `terminal.Terminal` that amux
allocated, with placeholder `Surface`/`Thread` pointers, and `updateFrame`
snapshots it successfully at runtime against a real OpenGL context.

## What was proven

By reading the fork:

- `renderer/State.zig` is `{ mutex, terminal: *terminal.Terminal, inspector,
  preedit, mouse }`. No `Surface`, apprt, PTY or termio.
- `renderer/Options.zig` asks for `rt_surface: *apprt.Surface` and
  `surface_mailbox`, but `rt_surface` is dereferenced **only** by `Metal.zig`.
  `OpenGL.threadEnter` discards both its arguments on the embedded apprt, with
  the comment that the GL context belongs to the embedder's `GtkGLArea` and
  rendering happens on the main thread. `Options.thread` is never read.
- In `Surface.zig` the binding is literally one field:
  `.renderer_state = .{ .mutex = mutex, .terminal = &self.io.terminal }`.

By building and running (`main_amux_proto.zig`):

```
[proto] apprt.runtime = apprt.none
[proto] Terminal.init returned
[proto] terminal filled: 80x24
[proto] font grid ready, cell = .{ .width = 10, .height = 21 }
[proto] EGL 1.5 initialised
[proto] offscreen GL context current (800x504)
[proto] glad loaded OpenGL 4.5
[proto] renderer.Size.grid() = .{ .columns = 80, .rows = 24 }  (terminal is 80x24)
[proto] renderer constructed
[proto] updateFrame OK: renderer snapshotted OUR terminal
```

The same source also **compiles as a shared library**, which is the
configuration that matters for amux: `apprt.runtime` resolves through
`build_config.artifact`, and only `.lib` selects the embedded apprt. So the
entire path — `Renderer.init`, `updateFrame`, `drawFrame`, and the surface
mailbox — type-checks under the apprt amux actually links against.

## What was not proven

**Pixels.** `drawFrame` segfaults. It needs the frame and swap-chain lifecycle
that `renderer.Thread` normally drives (`loopEnter` and friends), which this
prototype fakes with a placeholder thread pointer. That is ordinary integration
work the GUI will have to do regardless of who owns the terminal — it is not
evidence of Surface coupling. Reaching `updateFrame` already required the
renderer to read our `Terminal`'s dimensions and contents.

If item 6 hits trouble, this is where to resume: drive the real frame lifecycle
rather than stubbing the thread.

## Things worth knowing, found the hard way

- **`Contents.bg_cells` defaults to `undefined`** (`renderer/cell.zig`), and the
  first `cells.resize` frees it before allocating. Harmless in ReleaseFast,
  which is how Ghostty builds renderers; in Debug it is 0xAA-filled and panics
  in `sliceAsBytes` with an integer overflow. The prototype therefore builds
  ReleaseFast. Worth fixing in the fork if the GUI ever wants a Debug renderer.
- **`renderer.Size.screen` must match the framebuffer**, or `Size.grid()`
  disagrees with the terminal's dimensions and `rebuildCells` walks off the end.
  A 600px-tall buffer with a 21px cell gives 28 rows against a 24-row terminal.
- **`std.log` crashes in a `dlopen`ed Zig library.** No Zig start code runs, so
  the stderr writer and `Progress` globals are uninitialised and
  `Progress.unlockStderrWriter` segfaults. The prototype writes with `write(2)`
  instead. Relevant to any future `dlopen`-based plugin idea.
- **`apprt.none.App` has no `wakeup`**, so anything touching the surface mailbox
  cannot be compiled into an exe with `-Dapp-runtime=none`. The patch adds a
  no-op. Only needed to run the prototype as an executable.

## Reproducing

```sh
cd ghostty
git apply ../docs/spikes/renderer-foreign-terminal/ghostty-fork.patch
cp ../docs/spikes/renderer-foreign-terminal/main_amux_proto.zig src/
zig build -Dapp-runtime=none -Demit-bench=true
LIBGL_ALWAYS_SOFTWARE=1 ./zig-out/bin/amux-proto
```

The submodule is deliberately left pristine so amux's own build is unaffected;
the patch and source live here instead.
