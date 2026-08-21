//! Prototype: drive Ghostty's OpenGL renderer against a Terminal that the
//! *embedder* owns, rather than one owned by a Ghostty Surface.
//!
//! This is the spike for amux's daemon split (see amux docs/plan item 1). If
//! this works, the daemon can own terminal state and the GUI stays a thin
//! renderer; if it doesn't, the GUI needs its own text renderer.
//!
//! Deliberately headless: an EGL surfaceless context, so there is no GTK
//! dependency and the result can be verified by reading pixels back.

const std = @import("std");
const builtin = @import("builtin");

const apprt = @import("apprt.zig");
const configpkg = @import("config.zig");
const font = @import("font/main.zig");
const renderer = @import("renderer.zig");
const terminal = @import("terminal/main.zig");
const gl = @import("opengl");


/// Direct write(2) to stderr. std.log cannot be used here: when a non-Zig host
/// dlopens this library, Zig's start code never runs, so the stderr writer and
/// Progress globals std.log touches are uninitialised and it segfaults inside
/// Progress.unlockStderrWriter.
fn pr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[proto] " ++ fmt ++ "\n", args) catch return;
    _ = std.posix.write(2, msg) catch {};
}



// --- Minimal EGL, enough for an offscreen GL context ---------------------
//
// Declared by hand rather than @cImport so the prototype needs nothing beyond
// linking libEGL. A pbuffer means framebuffer 0 is offscreen, so glReadPixels
// can verify what the renderer actually drew.
const EGLDisplay = ?*anyopaque;
const EGLConfig = ?*anyopaque;
const EGLSurface = ?*anyopaque;
const EGLContext = ?*anyopaque;
const EGLint = i32;

extern fn eglGetDisplay(display_id: ?*anyopaque) EGLDisplay;
extern fn eglInitialize(dpy: EGLDisplay, major: *EGLint, minor: *EGLint) c_uint;
extern fn eglChooseConfig(dpy: EGLDisplay, attrib_list: [*]const EGLint, configs: [*]EGLConfig, config_size: EGLint, num_config: *EGLint) c_uint;
extern fn eglBindAPI(api: c_uint) c_uint;
extern fn eglCreatePbufferSurface(dpy: EGLDisplay, config: EGLConfig, attrib_list: [*]const EGLint) EGLSurface;
extern fn eglCreateContext(dpy: EGLDisplay, config: EGLConfig, share: EGLContext, attrib_list: [*]const EGLint) EGLContext;
extern fn eglMakeCurrent(dpy: EGLDisplay, draw: EGLSurface, read: EGLSurface, ctx: EGLContext) c_uint;
extern fn eglGetProcAddress(procname: [*:0]const u8) ?*const fn () callconv(.c) void;
extern fn eglGetError() EGLint;

const EGL_NONE: EGLint = 0x3038;
const EGL_WIDTH: EGLint = 0x3057;
const EGL_HEIGHT: EGLint = 0x3056;
const EGL_SURFACE_TYPE: EGLint = 0x3033;
const EGL_PBUFFER_BIT: EGLint = 0x0001;
const EGL_RENDERABLE_TYPE: EGLint = 0x3040;
const EGL_OPENGL_BIT: EGLint = 0x0008;
const EGL_RED_SIZE: EGLint = 0x3024;
const EGL_GREEN_SIZE: EGLint = 0x3023;
const EGL_BLUE_SIZE: EGLint = 0x3022;
const EGL_ALPHA_SIZE: EGLint = 0x3021;
const EGL_OPENGL_API: c_uint = 0x30A2;
const EGL_CONTEXT_MAJOR_VERSION: EGLint = 0x3098;
const EGL_CONTEXT_MINOR_VERSION: EGLint = 0x30FB;

// Sized to exactly 80x24 cells of the 10x21 JetBrains Mono cell this config
// produces, so the renderer's computed grid matches the Terminal's dimensions.
// A mismatch overflows while indexing rows.
const term_cols = 80;
const term_rows = 24;
const gl_width = term_cols * 10;
const gl_height = term_rows * 21;

fn initOffscreenGL() !void {
    const dpy = eglGetDisplay(null);
    if (dpy == null) return error.NoEglDisplay;

    var major: EGLint = 0;
    var minor: EGLint = 0;
    if (eglInitialize(dpy, &major, &minor) == 0) return error.EglInitFailed;
    pr("EGL {d}.{d} initialised", .{ major, minor });

    if (eglBindAPI(EGL_OPENGL_API) == 0) return error.EglBindApiFailed;

    const cfg_attrs = [_]EGLint{
        EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE,        8,
        EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,
        EGL_ALPHA_SIZE,      8,
        EGL_NONE,
    };
    var config: EGLConfig = null;
    var n: EGLint = 0;
    if (eglChooseConfig(dpy, &cfg_attrs, @ptrCast(&config), 1, &n) == 0 or n == 0) {
        return error.NoEglConfig;
    }

    const surf_attrs = [_]EGLint{ EGL_WIDTH, gl_width, EGL_HEIGHT, gl_height, EGL_NONE };
    const surface = eglCreatePbufferSurface(dpy, config, &surf_attrs);
    if (surface == null) return error.NoPbuffer;

    const ctx_attrs = [_]EGLint{
        EGL_CONTEXT_MAJOR_VERSION, 3,
        EGL_CONTEXT_MINOR_VERSION, 3,
        EGL_NONE,
    };
    const ctx = eglCreateContext(dpy, config, null, &ctx_attrs);
    if (ctx == null) return error.NoEglContext;

    if (eglMakeCurrent(dpy, surface, surface, ctx) == 0) return error.EglMakeCurrentFailed;
    pr("offscreen GL context current ({d}x{d})", .{ gl_width, gl_height });
}

/// Exported so this can be built as a library, which is what selects the
/// embedded apprt: `apprt.runtime` resolves via `build_config.artifact`, and
/// only `.lib` maps to `embedded`. Building it as an exe yields `apprt.none`,
/// whose App has no `wakeup`, so the renderer's surface mailbox will not
/// compile. amux itself links libghostty, so `.lib` is also the configuration
/// that actually matters here.
pub fn main() !void {
    run() catch |err| {
        pr("prototype failed: {}", .{err});
        return err;
    };
}

fn run() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    pr("apprt.runtime = {}", .{apprt.runtime});

    // --- 1. The Terminal we own. Nothing Ghostty-side created this. ---
    pr("allocator ready", .{});
    var term = try terminal.Terminal.init(alloc, .{
        .cols = term_cols,
        .rows = term_rows,
        .max_scrollback = 1000,
    });
    defer term.deinit(alloc);

    pr("Terminal.init returned", .{});
    // Put something on screen. Direct prints keep the prototype focused on the
    // renderer question rather than VT plumbing.
    for ("hello from an embedder-owned terminal") |ch| try term.print(ch);
    pr("terminal filled: {d}x{d}", .{ term.cols, term.rows });

    // --- 2. Config and font grid, the way Surface.init does it. ---
    var config = try configpkg.Config.default(alloc);
    defer config.deinit();

    var grid_set = try font.SharedGridSet.init(alloc);
    defer grid_set.deinit();

    var font_cfg = try font.SharedGridSet.DerivedConfig.init(alloc, &config);
    defer font_cfg.deinit();

    const font_size: font.face.DesiredSize = .{
        .points = config.@"font-size",
        .xdpi = 96,
        .ydpi = 96,
    };
    const grid_key, const font_grid = try grid_set.ref(&font_cfg, font_size);
    _ = grid_key;
    pr("font grid ready, cell = {any}", .{font_grid.cellSize()});

    // --- 3. A GL context. The renderer allocates GL buffers in init(). ---
    try initOffscreenGL();
    const glver = try gl.glad.load(&eglGetProcAddress);
    pr("glad loaded OpenGL {d}.{d}", .{ gl.glad.versionMajor(@intCast(glver)), gl.glad.versionMinor(@intCast(glver)) });

    // --- 4. The renderer, pointed at OUR terminal. ---
    //
    // rt_surface and thread are placeholders. Verified unused in this
    // configuration: rt_surface is dereferenced only by Metal.zig, and
    // OpenGL.threadEnter discards it outright on the embedded apprt
    // ("the GL context is managed by the embedder's GtkGLArea"). Options.thread
    // is never read by the renderer at all.
    const fake_surface: *apprt.Surface = @ptrFromInt(@alignOf(apprt.Surface));
    const fake_thread: *renderer.Thread = @ptrFromInt(@alignOf(renderer.Thread));

    const size: renderer.Size = .{
        .screen = .{ .width = gl_width, .height = gl_height },
        .cell = font_grid.cellSize(),
        .padding = .{},
    };

    pr("renderer.Size.grid() = {any}  (terminal is {d}x{d})", .{ size.grid(), term.cols, term.rows });
    var render_impl = try renderer.Renderer.init(alloc, .{
        .config = try renderer.Renderer.DerivedConfig.init(alloc, &config),
        .font_grid = font_grid,
        .size = size,
        .surface_mailbox = undefined,
        .rt_surface = fake_surface,
        .thread = fake_thread,
    });
    defer render_impl.deinit();
    pr("renderer constructed", .{});

    // --- 4. Hand it OUR terminal via a hand-built render state. ---
    var mutex: std.Thread.Mutex = .{};
    var state: renderer.State = .{
        .mutex = &mutex,
        .terminal = &term,
    };
    // updateFrame snapshots the terminal the state points at into the
    // renderer's own terminal.RenderState. This is the whole question: it
    // reads whatever Terminal we hand it, with no idea who owns it.
    try render_impl.updateFrame(&state, true);
    pr("updateFrame OK: renderer snapshotted OUR terminal", .{});

    try render_impl.drawFrame(true);
    pr("drawFrame OK", .{});

    // --- 5. Verify by reading the framebuffer back. ---
    const px = try alloc.alloc(u8, gl_width * gl_height * 4);
    defer alloc.free(px);
    gl.glad.context.ReadPixels.?(0, 0, gl_width, gl_height, 0x1908, 0x1401, px.ptr);

    var histogram = std.AutoHashMap(u32, u32).init(alloc);
    defer histogram.deinit();
    var lit: usize = 0;
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        const rgb = (@as(u32, px[i]) << 16) | (@as(u32, px[i + 1]) << 8) | px[i + 2];
        const e = try histogram.getOrPut(rgb);
        e.value_ptr.* = if (e.found_existing) e.value_ptr.* + 1 else 1;
        if (rgb != 0x000000) lit += 1;
    }
    pr("readback: {d} distinct colours, {d} non-black pixels of {d}", .{
        histogram.count(), lit, gl_width * gl_height,
    });

    if (histogram.count() < 2) {
        pr("FAIL: framebuffer is a single flat colour -- nothing was drawn", .{});
        return error.NothingRendered;
    }
    pr("PROTOTYPE PASS: Ghostty's renderer drew an embedder-owned Terminal", .{});
}

