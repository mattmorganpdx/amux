const std = @import("std");
const c = @import("c.zig");
const App = @import("app.zig");

const log = std.log.scoped(.terminal_widget);

const TerminalWidget = @This();

/// The GtkGLArea widget for rendering.
gl_area: *c.GtkGLArea,

/// The Ghostty surface handle.
surface: c.ghostty_surface_t,

/// Reference to the Ghostty app.
app: *App,

/// Whether the GtkGLArea has been realized and the surface created.
/// When false, queueRender is a no-op to avoid GTK assertions.
realized: bool = false,

/// Working directory for this terminal, passed to Ghostty on realize.
working_directory: ?[*:0]const u8 = null,

/// Environment variable info for the surface (set at creation time).
pane_id: ?u64 = null,
workspace_id: ?u64 = null,
socket_path: ?[*:0]const u8 = null,

/// Optional command to run instead of the default shell (e.g. for history restore).
command: ?[*:0]const u8 = null,

/// Last known widget dimensions for detecting resize changes.
/// Updated by the tick callback to catch maximize/unmaximize events
/// that the GtkGLArea "resize" signal can miss.
last_width: c.gint = 0,
last_height: c.gint = 0,

/// Global registry mapping ghostty_surface_t → *TerminalWidget.
/// Used by the action callback to look up widgets without relying on
/// ghostty_surface_userdata pointer interpretation.
/// Protected by surface_registry_mutex for thread safety — GTK callbacks
/// write from the main thread, Ghostty renderer threads read via fromSurface().
var surface_registry: std.AutoHashMapUnmanaged(usize, *TerminalWidget) = .empty;
var surface_registry_mutex: std.Thread.Mutex = .{};

/// Look up a TerminalWidget by its Ghostty surface handle.
pub fn fromSurface(surface: c.ghostty_surface_t) ?*TerminalWidget {
    if (surface == null) return null;
    surface_registry_mutex.lock();
    defer surface_registry_mutex.unlock();
    return surface_registry.get(@intFromPtr(surface));
}

/// Create a new terminal widget backed by a GtkGLArea + Ghostty surface.
pub fn create(
    app: *App,
    working_directory: ?[*:0]const u8,
    pane_id: ?u64,
    workspace_id: ?u64,
    socket_path: ?[*:0]const u8,
) !*TerminalWidget {
    const alloc = std.heap.c_allocator;

    // Create the GtkGLArea
    const gl_area: *c.GtkGLArea = @ptrCast(c.gtk_gl_area_new() orelse
        return error.GtkGLAreaFailed);

    // Request OpenGL 3.3 core profile (Ghostty's minimum)
    c.gtk_gl_area_set_required_version(gl_area, 3, 3);
    c.gtk_gl_area_set_has_depth_buffer(gl_area, 0);
    c.gtk_gl_area_set_has_stencil_buffer(gl_area, 0);
    c.gtk_gl_area_set_auto_render(gl_area, 0);

    // Make the widget expand to fill available space
    c.gtk_widget_set_hexpand(@as(*c.GtkWidget, @ptrCast(gl_area)), 1);
    c.gtk_widget_set_vexpand(@as(*c.GtkWidget, @ptrCast(gl_area)), 1);

    // Enable the widget to receive focus and input
    c.gtk_widget_set_focusable(@as(*c.GtkWidget, @ptrCast(gl_area)), 1);
    c.gtk_widget_set_can_focus(@as(*c.GtkWidget, @ptrCast(gl_area)), 1);

    // Hold our own GObject reference on the GtkGLArea to prevent
    // GTK from finalizing it while we still hold a pointer.
    _ = c.g_object_ref(@as(c.gpointer, @ptrCast(gl_area)));

    const self = try alloc.create(TerminalWidget);
    self.* = .{
        .gl_area = gl_area,
        .surface = null,
        .app = app,
        .pane_id = pane_id,
        .workspace_id = workspace_id,
        .socket_path = socket_path,
    };

    // Connect signals
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(gl_area)),
        "realize",
        @as(c.GCallback, @ptrCast(&onRealize)),
        @ptrCast(self),
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(gl_area)),
        "unrealize",
        @as(c.GCallback, @ptrCast(&onUnrealize)),
        @ptrCast(self),
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(gl_area)),
        "render",
        @as(c.GCallback, @ptrCast(&onRender)),
        @ptrCast(self),
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(gl_area)),
        "resize",
        @as(c.GCallback, @ptrCast(&onResize)),
        @ptrCast(self),
        null,
        0,
    );

    // Set up keyboard input
    const key_controller = c.gtk_event_controller_key_new();
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(key_controller)),
        "key-pressed",
        @as(c.GCallback, @ptrCast(&onKeyPressed)),
        @ptrCast(self),
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(key_controller)),
        "key-released",
        @as(c.GCallback, @ptrCast(&onKeyReleased)),
        @ptrCast(self),
        null,
        0,
    );
    c.gtk_widget_add_controller(
        @as(*c.GtkWidget, @ptrCast(gl_area)),
        key_controller,
    );

    // Set up mouse/scroll input
    const click_gesture = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(click_gesture), 0); // all buttons
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(click_gesture)),
        "pressed",
        @as(c.GCallback, @ptrCast(&onMousePressed)),
        @ptrCast(self),
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(click_gesture)),
        "released",
        @as(c.GCallback, @ptrCast(&onMouseReleased)),
        @ptrCast(self),
        null,
        0,
    );
    c.gtk_widget_add_controller(
        @as(*c.GtkWidget, @ptrCast(gl_area)),
        @ptrCast(click_gesture),
    );

    const scroll_controller = c.gtk_event_controller_scroll_new(
        c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES |
            c.GTK_EVENT_CONTROLLER_SCROLL_DISCRETE,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(scroll_controller)),
        "scroll",
        @as(c.GCallback, @ptrCast(&onScroll)),
        @ptrCast(self),
        null,
        0,
    );
    c.gtk_widget_add_controller(
        @as(*c.GtkWidget, @ptrCast(gl_area)),
        scroll_controller,
    );

    // Motion controller for mouse movement tracking
    const motion_controller = c.gtk_event_controller_motion_new();
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(motion_controller)),
        "motion",
        @as(c.GCallback, @ptrCast(&onMotion)),
        @ptrCast(self),
        null,
        0,
    );
    c.gtk_widget_add_controller(
        @as(*c.GtkWidget, @ptrCast(gl_area)),
        motion_controller,
    );

    // Register a tick callback to detect size changes that the GtkGLArea
    // "resize" signal can miss (e.g., window maximize/unmaximize).
    _ = c.gtk_widget_add_tick_callback(
        @as(*c.GtkWidget, @ptrCast(gl_area)),
        &onTick,
        @ptrCast(self),
        null,
    );

    self.working_directory = working_directory;

    return self;
}

pub fn deinit(self: *TerminalWidget) void {
    self.realized = false;

    // Remove from registry before freeing the surface
    if (self.surface != null) {
        {
            surface_registry_mutex.lock();
            defer surface_registry_mutex.unlock();
            _ = surface_registry.remove(@intFromPtr(self.surface));
        }
        c.ghostty_surface_free(self.surface);
        self.surface = null;
    }

    // Release our GObject reference on the GtkGLArea
    c.g_object_unref(@as(c.gpointer, @ptrCast(self.gl_area)));

    std.heap.c_allocator.destroy(self);
}

/// Get the underlying GtkWidget for embedding in containers.
pub fn widget(self: *TerminalWidget) *c.GtkWidget {
    return @ptrCast(self.gl_area);
}

/// Request a redraw of the terminal surface.
/// Only queues a render if the GtkGLArea has been realized and the
/// Ghostty surface is active. This prevents GTK_IS_GL_AREA assertions.
pub fn queueRender(self: *TerminalWidget) void {
    if (!self.realized) return;
    if (self.surface == null) return;
    c.gtk_gl_area_queue_render(self.gl_area);
}

// --- GTK signal callbacks ---

fn onRealize(gl_area: *c.GtkGLArea, userdata: c.gpointer) callconv(.c) void {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));

    // Make the GL context current so Ghostty can initialize
    c.gtk_gl_area_make_current(gl_area);
    if (c.gtk_gl_area_get_error(gl_area)) |err| {
        log.err("GL context error on realize: {s}", .{err.*.message});
        return;
    }

    // Get the scale factor for HiDPI
    const gtk_widget: *c.GtkWidget = @ptrCast(gl_area);
    const scale: f64 = @floatFromInt(c.gtk_widget_get_scale_factor(gtk_widget));

    // Configure the Ghostty surface
    var surface_config = self.app.newSurfaceConfig();
    surface_config.platform_tag = c.GHOSTTY_PLATFORM_LINUX;
    surface_config.platform = .{ .gtk_linux = .{
        .gl_area = @ptrCast(gl_area),
    } };
    surface_config.scale_factor = scale;
    surface_config.userdata = @ptrCast(self);
    surface_config.working_directory = self.working_directory;
    surface_config.command = self.command;

    // Set environment variables so scripts know which terminal they're in
    var env_vars_buf: [3]c.ghostty_env_var_s = undefined;
    var env_count: usize = 0;
    var surface_id_buf: [32]u8 = undefined;
    var workspace_id_buf: [32]u8 = undefined;

    if (self.pane_id) |pid| {
        if (std.fmt.bufPrintZ(&surface_id_buf, "{d}", .{pid})) |id_str| {
            env_vars_buf[env_count] = .{ .key = "AMUX_SURFACE_ID", .value = id_str.ptr };
            env_count += 1;
        } else |_| {}
    }
    if (self.workspace_id) |wid| {
        if (std.fmt.bufPrintZ(&workspace_id_buf, "{d}", .{wid})) |id_str| {
            env_vars_buf[env_count] = .{ .key = "AMUX_WORKSPACE_ID", .value = id_str.ptr };
            env_count += 1;
        } else |_| {}
    }
    if (self.socket_path) |sp| {
        env_vars_buf[env_count] = .{ .key = "AMUX_SOCKET_PATH", .value = sp };
        env_count += 1;
    }
    if (env_count > 0) {
        surface_config.env_vars = &env_vars_buf;
        surface_config.env_var_count = env_count;
    }

    // Create the Ghostty surface
    self.surface = c.ghostty_surface_new(self.app.ghostty_app, &surface_config);
    if (self.surface == null) {
        log.err("Failed to create Ghostty surface", .{});
        return;
    }

    // Register in the global surface → widget map so the action callback
    // can look us up without relying on ghostty_surface_userdata.
    {
        surface_registry_mutex.lock();
        defer surface_registry_mutex.unlock();
        surface_registry.put(std.heap.c_allocator, @intFromPtr(self.surface), self) catch |err| {
            log.err("Failed to register surface in registry: {}", .{err});
        };
    }

    // Mark as realized AFTER surface creation succeeds
    self.realized = true;

    log.info("Terminal surface created successfully", .{});

    // Queue initial render
    c.gtk_gl_area_queue_render(gl_area);
}

fn onUnrealize(_: *c.GtkGLArea, userdata: c.gpointer) callconv(.c) void {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));

    // Mark as unrealized to prevent further queueRender calls
    self.realized = false;

    // Remove from the surface registry immediately so that Ghostty render
    // callbacks on other threads can no longer look up this widget via
    // fromSurface(). Without this, there is a race between unrealize
    // (GTK main thread) and the render action callback (Ghostty thread)
    // that can call gtk_gl_area_queue_render on a destroyed widget.
    if (self.surface != null) {
        surface_registry_mutex.lock();
        defer surface_registry_mutex.unlock();
        _ = surface_registry.remove(@intFromPtr(self.surface));
    }

    log.info("Terminal surface unrealized", .{});
}

fn onRender(
    _: *c.GtkGLArea,
    _: *c.GdkGLContext,
    userdata: c.gpointer,
) callconv(.c) c.gboolean {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));

    if (self.surface != null) {
        // Do NOT call ghostty_surface_set_size here. Calling set_size
        // re-triggers the async IO→renderer resize pipeline, and the
        // immediate draw() will see a grid/cells size mismatch and bail
        // (re-presenting the stale frame). Size updates are handled by
        // onResize and onTick; this callback should only draw.
        c.ghostty_surface_draw(self.surface);
    }

    return 1; // We handled the render
}

fn onResize(
    area: *c.GtkGLArea,
    width: c.gint,
    height: c.gint,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));

    if (self.surface != null) {
        // Update content scale first (mirroring Ghostty's GTK apprt pattern).
        const scale: f64 = @floatFromInt(c.gtk_widget_get_scale_factor(@as(*c.GtkWidget, @ptrCast(@alignCast(area)))));
        c.ghostty_surface_set_content_scale(self.surface, scale, scale);

        // Tell Ghostty the new size. This queues an async resize through the
        // IO thread → renderer mailbox pipeline.
        c.ghostty_surface_set_size(self.surface, @intCast(width), @intCast(height));

        // Queue a render. The first render may bail (cells not rebuilt yet
        // for the new grid size), but Ghostty's renderer thread will push
        // a redraw_surface message once the IO thread + renderer have
        // processed the resize, triggering a second render that succeeds.
        c.gtk_gl_area_queue_render(self.gl_area);
    }
    self.last_width = width;
    self.last_height = height;
}

/// Tick callback fires every GTK frame clock cycle. Detects size changes
/// that the GtkGLArea "resize" signal misses (maximize, unmaximize, etc.)
/// and triggers a Ghostty surface size update + render.
fn onTick(
    gtk_widget: [*c]c.GtkWidget,
    _: ?*c.GdkFrameClock,
    userdata: c.gpointer,
) callconv(.c) c.gboolean {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));
    if (self.surface == null) return 1; // keep ticking

    // gtk_widget_get_width/height return logical pixels — multiply by
    // scale factor to get physical pixels for Ghostty.
    const scale_int = c.gtk_widget_get_scale_factor(gtk_widget);
    const w = c.gtk_widget_get_width(gtk_widget) * scale_int;
    const h = c.gtk_widget_get_height(gtk_widget) * scale_int;

    if (w > 0 and h > 0 and (w != self.last_width or h != self.last_height)) {
        self.last_width = w;
        self.last_height = h;
        const scale: f64 = @floatFromInt(scale_int);
        c.ghostty_surface_set_content_scale(self.surface, scale, scale);
        c.ghostty_surface_set_size(self.surface, @intCast(w), @intCast(h));
        c.gtk_gl_area_queue_render(self.gl_area);
    }

    return 1; // G_SOURCE_CONTINUE — keep the callback active
}

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    state: c.GdkModifierType,
    userdata: c.gpointer,
) callconv(.c) c.gboolean {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));
    if (self.surface == null) return 0;

    // Convert keyval to Unicode codepoint for text input
    const codepoint = c.gdk_keyval_to_unicode(keyval);

    // Build UTF-8 text for printable characters (codepoint >= 0x20, not DEL 0x7f)
    var text_buf: [8]u8 = undefined;
    var text_ptr: ?[*:0]const u8 = null;
    if (codepoint >= 0x20 and codepoint != 0x7f) {
        if (std.unicode.utf8Encode(@intCast(codepoint), &text_buf)) |len| {
            text_buf[len] = 0;
            text_ptr = @ptrCast(&text_buf);
        } else |_| {}
    }

    // Compute unshifted codepoint (what the key produces without Shift)
    const unshifted = c.gdk_keyval_to_unicode(c.gdk_keyval_to_lower(keyval));

    const mods = gtkModsToGhostty(state);
    const key_event = c.ghostty_input_key_s{
        .action = c.GHOSTTY_ACTION_PRESS,
        .mods = mods,
        .consumed_mods = c.GHOSTTY_MODS_NONE,
        .keycode = keycode,
        .text = text_ptr,
        .unshifted_codepoint = @intCast(unshifted),
        .composing = false,
    };

    const consumed = c.ghostty_surface_key(self.surface, key_event);
    return if (consumed) 1 else 0;
}

fn onKeyReleased(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    state: c.GdkModifierType,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));
    if (self.surface == null) return;

    // Compute unshifted codepoint (text not needed for release events)
    const unshifted = c.gdk_keyval_to_unicode(c.gdk_keyval_to_lower(keyval));

    const mods = gtkModsToGhostty(state);
    const key_event = c.ghostty_input_key_s{
        .action = c.GHOSTTY_ACTION_RELEASE,
        .mods = mods,
        .consumed_mods = c.GHOSTTY_MODS_NONE,
        .keycode = keycode,
        .text = null,
        .unshifted_codepoint = @intCast(unshifted),
        .composing = false,
    };

    _ = c.ghostty_surface_key(self.surface, key_event);
}

fn onMousePressed(
    gesture: *c.GtkGestureClick,
    n_press: c.gint,
    x: c.gdouble,
    y: c.gdouble,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));
    _ = n_press;
    if (self.surface == null) return;

    const button = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
    const ghostty_button = gtkButtonToGhostty(button);

    // ghostty_surface_mouse_button(surface, state, button, mods)
    _ = c.ghostty_surface_mouse_button(
        self.surface,
        c.GHOSTTY_MOUSE_PRESS,
        ghostty_button,
        c.GHOSTTY_MODS_NONE,
    );

    // Update cursor position
    c.ghostty_surface_mouse_pos(self.surface, x, y, c.GHOSTTY_MODS_NONE);
}

fn onMouseReleased(
    gesture: *c.GtkGestureClick,
    n_press: c.gint,
    x: c.gdouble,
    y: c.gdouble,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));
    _ = n_press;
    _ = x;
    _ = y;
    if (self.surface == null) return;

    const button = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
    const ghostty_button = gtkButtonToGhostty(button);

    _ = c.ghostty_surface_mouse_button(
        self.surface,
        c.GHOSTTY_MOUSE_RELEASE,
        ghostty_button,
        c.GHOSTTY_MODS_NONE,
    );
}

fn onScroll(
    _: *c.GtkEventControllerScroll,
    dx: c.gdouble,
    dy: c.gdouble,
    userdata: c.gpointer,
) callconv(.c) c.gboolean {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));
    if (self.surface == null) return 0;

    // GTK4 scroll direction is inverted relative to Ghostty's expectation
    c.ghostty_surface_mouse_scroll(self.surface, dx, -dy, 0);
    return 1;
}

fn onMotion(
    _: *c.GtkEventControllerMotion,
    x: c.gdouble,
    y: c.gdouble,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));
    if (self.surface == null) return;

    c.ghostty_surface_mouse_pos(self.surface, x, y, c.GHOSTTY_MODS_NONE);
}

// --- Helper functions ---

fn gtkModsToGhostty(state: c.GdkModifierType) c.ghostty_input_mods_t {
    var mods: c.ghostty_input_mods_t = c.GHOSTTY_MODS_NONE;

    if (state & c.GDK_SHIFT_MASK != 0) mods |= c.GHOSTTY_MODS_SHIFT;
    if (state & c.GDK_CONTROL_MASK != 0) mods |= c.GHOSTTY_MODS_CTRL;
    if (state & c.GDK_ALT_MASK != 0) mods |= c.GHOSTTY_MODS_ALT;
    if (state & c.GDK_SUPER_MASK != 0) mods |= c.GHOSTTY_MODS_SUPER;

    return mods;
}

fn gtkButtonToGhostty(button: c.guint) c.ghostty_input_mouse_button_e {
    return switch (button) {
        1 => c.GHOSTTY_MOUSE_LEFT,
        2 => c.GHOSTTY_MOUSE_MIDDLE,
        3 => c.GHOSTTY_MOUSE_RIGHT,
        4 => c.GHOSTTY_MOUSE_FOUR,
        5 => c.GHOSTTY_MOUSE_FIVE,
        else => c.GHOSTTY_MOUSE_UNKNOWN,
    };
}
