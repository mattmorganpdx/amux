const std = @import("std");
const c = @import("c.zig");
const App = @import("app.zig");
const Window = @import("window.zig");
const Server = @import("socket/server.zig");
const shortcuts = @import("shortcuts.zig");
const session = @import("session.zig");

const log = std.log.scoped(.main);

/// Global application state, initialized in activate callback.
pub var global_app: ?*App = null;
pub var global_window: ?*Window = null;
pub var global_server: ?*Server = null;

pub fn main() !void {
    const gtk_app = c.gtk_application_new(
        "com.amux.linux",
        c.G_APPLICATION_DEFAULT_FLAGS,
    ) orelse {
        log.err("Failed to create GtkApplication", .{});
        return error.GtkInitFailed;
    };
    defer c.g_object_unref(gtk_app);

    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(gtk_app)),
        "activate",
        @as(c.GCallback, @ptrCast(&onActivate)),
        null,
        null,
        0,
    );

    const status = c.g_application_run(
        @as(*c.GApplication, @ptrCast(gtk_app)),
        @intCast(std.os.argv.len),
        @ptrCast(std.os.argv.ptr),
    );

    // Save session before cleanup (include history IDs from the close-request save)
    if (global_window) |window| {
        const alloc = std.heap.c_allocator;
        if (session.captureSessionWithHistory(alloc, &window.tab_manager, &window.pane_history_ids)) |snap| {
            defer session.freeSessionSnapshot(alloc, &snap);
            session.writeSessionFile(alloc, &snap) catch |err| {
                log.warn("Failed to save session on exit: {}", .{err});
            };
        } else |err| {
            log.warn("Failed to capture session on exit: {}", .{err});
        }
    }

    // Cleanup — order matters: free surfaces before the ghostty app
    if (global_server) |server| {
        server.deinit();
        global_server = null;
    }

    if (global_window) |window| {
        window.deinit();
        global_window = null;
    }

    if (global_app) |app| {
        app.deinit();
        global_app = null;
    }

    c.notify_uninit();

    if (status != 0) {
        log.err("Application exited with status {}", .{status});
        return error.ApplicationFailed;
    }
}

/// Application CSS theme — workspace accent colors, command palette, search overlay.
const app_css =
    \\.ws-accent-red { background-color: #e74c3c; }
    \\.ws-accent-blue { background-color: #3498db; }
    \\.ws-accent-green { background-color: #2ecc71; }
    \\.ws-accent-yellow { background-color: #f1c40f; }
    \\.ws-accent-purple { background-color: #9b59b6; }
    \\.ws-accent-orange { background-color: #e67e22; }
    \\.ws-accent-pink { background-color: #e91e63; }
    \\.ws-accent-cyan { background-color: #00bcd4; }
    \\
    \\.command-palette { background-color: rgba(30,30,30,0.95); border-radius: 8px; padding: 8px; }
    \\.command-palette entry { margin-bottom: 4px; }
    \\
    \\.search-overlay { background-color: rgba(30,30,30,0.95); border-radius: 0 0 8px 8px; padding: 6px 12px; }
    \\
    \\.history-browser { background-color: rgba(30,30,30,0.97); border-radius: 8px; border: 1px solid rgba(255,255,255,0.1); }
    \\.history-browser .history-title { color: @accent_color; font-weight: bold; }
    \\.history-browser listbox { background-color: transparent; }
    \\.history-browser listbox row { border-bottom: 1px solid rgba(255,255,255,0.05); }
    \\.history-browser listbox row:selected { background-color: rgba(255,255,255,0.1); }
    \\.history-browser textview { background-color: rgba(0,0,0,0.3); color: #cccccc; }
    \\.history-browser textview text { background-color: transparent; }
;

fn setupDarkMode() void {
    const settings = c.gtk_settings_get_default() orelse return;
    c.g_object_set(@ptrCast(settings), "gtk-application-prefer-dark-theme", @as(c_int, 1), @as(?*anyopaque, null));
}

fn setupCssProvider() void {
    const provider = c.gtk_css_provider_new() orelse return;
    c.gtk_css_provider_load_from_string(provider, app_css);
    const display = c.gdk_display_get_default() orelse return;
    c.gtk_style_context_add_provider_for_display(
        display,
        @ptrCast(provider),
        c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    log.info("CSS provider loaded", .{});
}

/// Install the app icon and .desktop file to XDG paths so GNOME shows
/// the icon in the taskbar/overview. Only copies if the files are missing.
fn installDesktopFiles() void {
    const data_dir = c.g_get_user_data_dir() orelse return;
    const data_dir_str = std.mem.span(data_dir);

    // Install icon to ~/.local/share/icons/hicolor/128x128/apps/com.amux.linux.png
    var icon_dir_buf: [512]u8 = undefined;
    const icon_dir = std.fmt.bufPrintZ(&icon_dir_buf, "{s}/icons/hicolor/128x128/apps", .{data_dir_str}) catch return;
    _ = c.g_mkdir_with_parents(icon_dir.ptr, 0o755);

    var icon_dest_buf: [512]u8 = undefined;
    const icon_dest = std.fmt.bufPrintZ(&icon_dest_buf, "{s}/com.amux.linux.png", .{icon_dir}) catch return;

    if (c.g_file_test(icon_dest.ptr, c.G_FILE_TEST_EXISTS) == 0) {
        // Find icon relative to executable
        const icon_src = findResourceFile("resources/amux-icon.png") orelse {
            log.warn("Could not find amux-icon.png resource", .{});
            return;
        };
        copyFile(icon_src, icon_dest) catch |err| {
            log.warn("Failed to install icon: {}", .{err});
        };
    }

    // Install .desktop file to ~/.local/share/applications/
    var desktop_dir_buf: [512]u8 = undefined;
    const desktop_dir = std.fmt.bufPrintZ(&desktop_dir_buf, "{s}/applications", .{data_dir_str}) catch return;
    _ = c.g_mkdir_with_parents(desktop_dir.ptr, 0o755);

    var desktop_dest_buf: [512]u8 = undefined;
    const desktop_dest = std.fmt.bufPrintZ(&desktop_dest_buf, "{s}/com.amux.linux.desktop", .{desktop_dir}) catch return;

    if (c.g_file_test(desktop_dest.ptr, c.G_FILE_TEST_EXISTS) == 0) {
        const desktop_src = findResourceFile("resources/com.amux.linux.desktop") orelse {
            log.warn("Could not find .desktop resource", .{});
            return;
        };
        copyFile(desktop_src, desktop_dest) catch |err| {
            log.warn("Failed to install .desktop file: {}", .{err});
        };
    }

    log.info("Desktop files checked/installed", .{});
}

/// Find a resource file relative to the executable path.
fn findResourceFile(rel_path: []const u8) ?[*:0]const u8 {
    // Try relative to executable
    const exe_path = std.fs.selfExePathAlloc(std.heap.c_allocator) catch return null;
    defer std.heap.c_allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;
    // Go up one level from zig-out/bin/ to the project root
    const project_dir = std.fs.path.dirname(exe_dir) orelse exe_dir;
    const project_root = std.fs.path.dirname(project_dir) orelse project_dir;

    var buf: [512]u8 = undefined;
    const full_path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ project_root, rel_path }) catch return null;

    const file = std.fs.openFileAbsoluteZ(full_path.ptr, .{}) catch return null;
    file.close();

    // Return a stable copy
    const copy = std.heap.c_allocator.allocSentinel(u8, full_path.len, 0) catch return null;
    @memcpy(copy, full_path);
    return copy.ptr;
}

/// Copy a file from src path to dest path.
fn copyFile(src: [*:0]const u8, dest: [*:0]const u8) !void {
    const src_file = try std.fs.openFileAbsoluteZ(src, .{});
    defer src_file.close();
    const dest_file = try std.fs.createFileAbsoluteZ(dest, .{});
    defer dest_file.close();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try src_file.read(&buf);
        if (n == 0) break;
        try dest_file.writeAll(buf[0..n]);
    }
}

/// Handle window close-request: save session and let GTK destroy the window.
/// Returning 0 (FALSE) lets GTK proceed with window destruction; when the last
/// window is destroyed GtkApplication automatically quits the main loop.
fn onCloseRequest(_: *c.GtkWindow, _: c.gpointer) callconv(.c) c.gboolean {
    // Save terminal history before the window is destroyed
    if (global_window) |window| {
        window.saveAllHistory("app_exit");
    }

    // Save session before the window is destroyed (include history IDs)
    if (global_window) |window| {
        const alloc = std.heap.c_allocator;
        if (session.captureSessionWithHistory(alloc, &window.tab_manager, &window.pane_history_ids)) |snap| {
            defer session.freeSessionSnapshot(alloc, &snap);
            session.writeSessionFile(alloc, &snap) catch |err| {
                log.warn("Failed to save session on close: {}", .{err});
            };
        } else |err| {
            log.warn("Failed to capture session on close: {}", .{err});
        }
    }

    return 0; // let GTK destroy the window, which quits the application
}

fn onActivate(gtk_app: *c.GtkApplication, _: c.gpointer) callconv(.c) void {
    // Initialize libnotify for desktop notifications
    _ = c.notify_init("amux");

    // Install icon and .desktop file to XDG paths
    installDesktopFiles();

    // Force dark mode — terminal apps should always be dark
    setupDarkMode();

    // Set up custom CSS theme
    setupCssProvider();

    // Initialize the Ghostty backend on first activation
    if (global_app == null) {
        global_app = App.init() catch |err| {
            log.err("Failed to initialize Ghostty app: {}", .{err});
            return;
        };
    }

    // Create a new window (only on first activation)
    if (global_window != null) return;

    const app = global_app orelse return;

    // Try to restore session from disk
    const window = blk: {
        if (!session.isRestoreDisabled()) {
            if (session.loadSessionFile(std.heap.c_allocator)) |snap| {
                if (Window.createFromSession(gtk_app, app, &snap)) |w| {
                    log.info("Session restored ({d} workspaces)", .{snap.workspaces.len});
                    break :blk w;
                } else |err| {
                    log.warn("Session restore failed, starting fresh: {}", .{err});
                }
            } else |_| {}
        }
        break :blk Window.create(gtk_app, app) catch |err| {
            log.err("Failed to create window: {}", .{err});
            return;
        };
    };
    global_window = window;

    // Set window icon name (matches installed icon at com.amux.linux.png)
    c.gtk_window_set_icon_name(@ptrCast(window.gtk_window), "com.amux.linux");

    // Connect close-request so closing the window quits the application
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(window.gtk_window)),
        "close-request",
        @as(c.GCallback, @ptrCast(&onCloseRequest)),
        @as(c.gpointer, @ptrCast(gtk_app)),
        null,
        0,
    );

    // Start autosave timer (every 8 seconds)
    _ = c.g_timeout_add_seconds(8, &session.onAutosave, @as(c.gpointer, @ptrCast(window)));

    // Install keyboard shortcuts
    shortcuts.install(window);

    // Start the socket server
    if (global_server == null) {
        const server = Server.init(std.heap.c_allocator) catch |err| {
            log.warn("Failed to init socket server: {}", .{err});
            return;
        };
        // Wire the window into the server so handlers can access app state
        server.window = window;
        server.start() catch |err| {
            log.warn("Failed to start socket server: {}", .{err});
            server.deinit();
            return;
        };
        global_server = server;
    }
}
