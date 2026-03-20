const std = @import("std");
const c = @import("c.zig");
const Clipboard = @import("clipboard.zig");
const TerminalWidget = @import("terminal_widget.zig");
const PaneTree = @import("pane_tree.zig");

const log = std.log.scoped(.app);

const App = @This();

/// The opaque Ghostty app handle.
ghostty_app: c.ghostty_app_t,

/// The Ghostty config.
config: c.ghostty_config_t,

/// Initialize the Ghostty backend.
pub fn init() !*App {
    const alloc = std.heap.c_allocator;

    // Initialize Ghostty global state.
    // ghostty_init(argc, argv) - pass 0/null for embedded use.
    if (c.ghostty_init(0, null) != c.GHOSTTY_SUCCESS) {
        log.err("ghostty_init failed", .{});
        return error.GhosttyInitFailed;
    }

    // Load configuration.
    // Order matters: amux defaults first, then user files override, then finalize.
    const config = c.ghostty_config_new();

    // Load amux defaults (e.g. term=xterm-256color) before user config so
    // the user can override if they want.
    {
        var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fs.selfExeDirPath(&exe_dir_buf)) |exe_dir| {
            var conf_buf: [std.fs.max_path_bytes]u8 = undefined;
            // Try <exe_dir>/../resources/ghostty.conf (installed layout)
            if (std.fmt.bufPrintZ(&conf_buf, "{s}/../resources/ghostty.conf", .{exe_dir})) |path| {
                if (std.fs.cwd().access(path, .{})) |_| {
                    c.ghostty_config_load_file(config, path.ptr);
                } else |_| {
                    // Try <exe_dir>/../../resources/ghostty.conf (zig-out/bin/ dev layout)
                    if (std.fmt.bufPrintZ(&conf_buf, "{s}/../../resources/ghostty.conf", .{exe_dir})) |path2| {
                        if (std.fs.cwd().access(path2, .{})) |_| {
                            c.ghostty_config_load_file(config, path2.ptr);
                        } else |_| {}
                    } else |_| {}
                }
            } else |_| {}
        } else |_| {}
    }

    c.ghostty_config_load_default_files(config);
    c.ghostty_config_load_recursive_files(config);
    c.ghostty_config_finalize(config);

    // Create the app with runtime callbacks.
    // Use zeroes to ensure all fields (including any padding) are initialized.
    var runtime_config: c.ghostty_runtime_config_s = std.mem.zeroes(c.ghostty_runtime_config_s);
    runtime_config.userdata = null;
    runtime_config.supports_selection_clipboard = true;
    runtime_config.wakeup_cb = &wakeupCallback;
    runtime_config.action_cb = &actionCallback;
    runtime_config.read_clipboard_cb = &Clipboard.readCallback;
    runtime_config.confirm_read_clipboard_cb = &Clipboard.confirmReadCallback;
    runtime_config.write_clipboard_cb = &Clipboard.writeCallback;
    runtime_config.close_surface_cb = &closeSurfaceCallback;

    const ghostty_app = c.ghostty_app_new(&runtime_config, config);
    if (ghostty_app == null) {
        log.err("ghostty_app_new failed", .{});
        c.ghostty_config_free(config);
        return error.GhosttyAppFailed;
    }

    const app = try alloc.create(App);
    app.* = .{
        .ghostty_app = ghostty_app,
        .config = config,
    };

    return app;
}

pub fn deinit(self: *App) void {
    if (self.ghostty_app != null) {
        c.ghostty_app_free(self.ghostty_app);
    }
    if (self.config != null) {
        c.ghostty_config_free(self.config);
    }
    std.heap.c_allocator.destroy(self);
}

/// Tick the Ghostty event loop. Called from the GTK main loop.
pub fn tick(self: *App) void {
    c.ghostty_app_tick(self.ghostty_app);
}

/// Create a new surface configuration inheriting from this app.
pub fn newSurfaceConfig(self: *App) c.ghostty_surface_config_s {
    _ = self;
    return c.ghostty_surface_config_new();
}

// --- Ghostty runtime callbacks ---

/// Called when Ghostty needs the event loop to tick.
/// We schedule this on the GTK main loop via g_idle_add.
fn wakeupCallback(_: ?*anyopaque) callconv(.c) void {
    _ = c.g_idle_add(&idleTickCallback, null);
}

fn idleTickCallback(_: c.gpointer) callconv(.c) c.gboolean {
    const main_mod = @import("main.zig");
    if (main_mod.global_app) |app| {
        app.tick();
    }
    return c.G_SOURCE_REMOVE;
}

/// Called when Ghostty wants to perform an action (e.g., set title, close, render).
fn actionCallback(
    app: ?*anyopaque,
    target: c.ghostty_target_s,
    action: c.ghostty_action_s,
) callconv(.c) bool {
    _ = app;

    switch (action.tag) {
        c.GHOSTTY_ACTION_RENDER => {
            if (target.tag == c.GHOSTTY_TARGET_SURFACE) {
                if (TerminalWidget.fromSurface(target.target.surface)) |tw| {
                    tw.queueRender();
                    return true;
                }
            }
            return false;
        },

        c.GHOSTTY_ACTION_SET_TITLE => {
            const title_ptr = action.action.set_title.title;
            if (title_ptr == null) return false;

            // Copy the title — Ghostty may free the original before the
            // idle callback runs on the next main loop iteration.
            const title_span = std.mem.span(title_ptr);
            const title_copy = std.heap.c_allocator.allocSentinel(u8, title_span.len, 0) catch return false;
            @memcpy(title_copy, title_span);

            const ctx = std.heap.c_allocator.create(SetTitleCtx) catch {
                std.heap.c_allocator.free(title_copy);
                return false;
            };
            ctx.* = .{ .title = title_copy };
            _ = c.g_idle_add(&doSetTitle, @ptrCast(ctx));
            return true;
        },

        c.GHOSTTY_ACTION_NEW_SPLIT => {
            const ctx = std.heap.c_allocator.create(NewSplitCtx) catch return false;
            ctx.* = .{ .direction = action.action.new_split };
            _ = c.g_idle_add(&doNewSplit, @ptrCast(ctx));
            return true;
        },

        c.GHOSTTY_ACTION_PWD => {
            const pwd_ptr = action.action.pwd.pwd;
            if (pwd_ptr == null) return false;

            const pwd_span = std.mem.span(pwd_ptr);
            const pwd_copy = std.heap.c_allocator.allocSentinel(u8, pwd_span.len, 0) catch return false;
            @memcpy(pwd_copy, pwd_span);

            const ctx = std.heap.c_allocator.create(PwdCtx) catch {
                std.heap.c_allocator.free(pwd_copy);
                return false;
            };
            ctx.* = .{ .pwd = pwd_copy };
            _ = c.g_idle_add(&doPwd, @ptrCast(ctx));
            return true;
        },

        c.GHOSTTY_ACTION_CELL_SIZE => {
            // Acknowledge — no action needed yet.
            return true;
        },

        c.GHOSTTY_ACTION_CLOSE_WINDOW => {
            _ = c.g_idle_add(&doCloseWindow, null);
            return true;
        },

        c.GHOSTTY_ACTION_START_SEARCH => {
            _ = c.g_idle_add(&doStartSearch, null);
            return true;
        },

        c.GHOSTTY_ACTION_END_SEARCH => {
            _ = c.g_idle_add(&doEndSearch, null);
            return true;
        },

        c.GHOSTTY_ACTION_SEARCH_TOTAL => {
            const ctx = std.heap.c_allocator.create(SearchTotalCtx) catch return false;
            ctx.* = .{ .total = action.action.search_total.total };
            _ = c.g_idle_add(&doSearchTotal, @ptrCast(ctx));
            return true;
        },

        c.GHOSTTY_ACTION_SEARCH_SELECTED => {
            const ctx = std.heap.c_allocator.create(SearchSelectedCtx) catch return false;
            ctx.* = .{ .selected = action.action.search_selected.selected };
            _ = c.g_idle_add(&doSearchSelected, @ptrCast(ctx));
            return true;
        },

        else => return false,
    }
}

/// Called when Ghostty wants to close a surface (e.g., shell exits).
fn closeSurfaceCallback(
    surface_userdata: ?*anyopaque,
    process_alive: bool,
) callconv(.c) void {
    _ = process_alive;
    _ = surface_userdata;
    _ = c.g_idle_add(&doCloseSurface, null);
}

// --- Idle callback context types and handlers ---
// These run on the GTK main thread via g_idle_add.

const SetTitleCtx = struct {
    /// Owned copy of the title string (Ghostty may free the original
    /// before the idle callback fires).
    title: [:0]const u8,

    fn deinit(self: *SetTitleCtx) void {
        std.heap.c_allocator.free(self.title);
        std.heap.c_allocator.destroy(self);
    }
};

fn doSetTitle(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *SetTitleCtx = @ptrCast(@alignCast(userdata));
    defer ctx.deinit();

    const main_mod = @import("main.zig");
    const window = main_mod.global_window orelse return c.G_SOURCE_REMOVE;

    // Set the GTK window title
    c.gtk_window_set_title(@ptrCast(window.gtk_window), ctx.title.ptr);

    return c.G_SOURCE_REMOVE;
}

const NewSplitCtx = struct {
    direction: c.ghostty_action_split_direction_e,
};

fn doNewSplit(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *NewSplitCtx = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(ctx);

    const main_mod = @import("main.zig");
    const window = main_mod.global_window orelse return c.G_SOURCE_REMOVE;

    const dir: PaneTree.SplitDirection = switch (ctx.direction) {
        c.GHOSTTY_SPLIT_DIRECTION_RIGHT => .right,
        c.GHOSTTY_SPLIT_DIRECTION_DOWN => .down,
        c.GHOSTTY_SPLIT_DIRECTION_LEFT => .left,
        c.GHOSTTY_SPLIT_DIRECTION_UP => .up,
        else => .right,
    };

    window.splitFocused(dir) catch |err| {
        log.warn("Failed to split from ghostty action: {}", .{err});
    };

    return c.G_SOURCE_REMOVE;
}

const PwdCtx = struct {
    pwd: [:0]const u8,

    fn deinit(self: *PwdCtx) void {
        std.heap.c_allocator.free(self.pwd);
        std.heap.c_allocator.destroy(self);
    }
};

fn doPwd(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *PwdCtx = @ptrCast(@alignCast(userdata));
    defer ctx.deinit();

    const main_mod = @import("main.zig");
    const window = main_mod.global_window orelse return c.G_SOURCE_REMOVE;

    if (window.tab_manager.selectedWorkspace()) |ws| {
        ws.setCwd(ctx.pwd);
    }

    return c.G_SOURCE_REMOVE;
}

fn doCloseWindow(_: c.gpointer) callconv(.c) c.gboolean {
    const main_mod = @import("main.zig");
    const window = main_mod.global_window orelse return c.G_SOURCE_REMOVE;
    c.gtk_window_destroy(@ptrCast(window.gtk_window));
    return c.G_SOURCE_REMOVE;
}

fn doCloseSurface(_: c.gpointer) callconv(.c) c.gboolean {
    const main_mod = @import("main.zig");
    const window = main_mod.global_window orelse return c.G_SOURCE_REMOVE;

    window.closeFocused() catch |err| {
        log.warn("Failed to close surface: {}", .{err});
    };

    return c.G_SOURCE_REMOVE;
}

// --- Search callbacks ---

fn doStartSearch(_: c.gpointer) callconv(.c) c.gboolean {
    const main_mod = @import("main.zig");
    const window = main_mod.global_window orelse return c.G_SOURCE_REMOVE;
    window.showSearch();
    return c.G_SOURCE_REMOVE;
}

fn doEndSearch(_: c.gpointer) callconv(.c) c.gboolean {
    const main_mod = @import("main.zig");
    const window = main_mod.global_window orelse return c.G_SOURCE_REMOVE;
    window.hideSearch();
    return c.G_SOURCE_REMOVE;
}

const SearchTotalCtx = struct { total: isize };

fn doSearchTotal(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *SearchTotalCtx = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(ctx);

    const main_mod = @import("main.zig");
    const window = main_mod.global_window orelse return c.G_SOURCE_REMOVE;
    window.search_overlay.updateSearchTotal(@intCast(ctx.total));
    return c.G_SOURCE_REMOVE;
}

const SearchSelectedCtx = struct { selected: isize };

fn doSearchSelected(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *SearchSelectedCtx = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(ctx);

    const main_mod = @import("main.zig");
    const window = main_mod.global_window orelse return c.G_SOURCE_REMOVE;
    window.search_overlay.updateSearchSelected(@intCast(ctx.selected));
    return c.G_SOURCE_REMOVE;
}
