const std = @import("std");
const c = @import("c.zig");
const Window = @import("window.zig");
const PaneTree = @import("pane_tree.zig");

const log = std.log.scoped(.shortcuts);

/// Install keyboard shortcuts on the application window.
/// Shortcuts use Ctrl+Shift prefix to avoid conflicting with terminal input.
pub fn install(window: *Window) void {
    const key_controller = c.gtk_event_controller_key_new();

    // Set the propagation phase to CAPTURE so we intercept before the terminal
    c.gtk_event_controller_set_propagation_phase(key_controller, c.GTK_PHASE_CAPTURE);

    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(key_controller)),
        "key-pressed",
        @as(c.GCallback, @ptrCast(&onKeyPressed)),
        @ptrCast(window),
        null,
        0,
    );

    c.gtk_widget_add_controller(
        @as(*c.GtkWidget, @ptrCast(@alignCast(window.gtk_window))),
        key_controller,
    );

    log.info("Keyboard shortcuts installed", .{});
}

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    state: c.GdkModifierType,
    userdata: c.gpointer,
) callconv(.c) c.gboolean {
    const window: *Window = @ptrCast(@alignCast(userdata));

    const has_ctrl = (state & c.GDK_CONTROL_MASK) != 0;
    const has_shift = (state & c.GDK_SHIFT_MASK) != 0;
    const ctrl_shift = has_ctrl and has_shift;

    if (!ctrl_shift) return 0; // Not our shortcut prefix

    // Ctrl+Shift+T: New workspace
    if (keyval == c.GDK_KEY_T or keyval == c.GDK_KEY_t) {
        window.createWorkspace() catch |err| {
            log.warn("Failed to create workspace: {}", .{err});
        };
        return 1;
    }

    // Ctrl+Shift+W: Close focused pane (or workspace if last pane)
    if (keyval == c.GDK_KEY_W or keyval == c.GDK_KEY_w) {
        window.closeFocused() catch |err| {
            log.warn("Failed to close pane: {}", .{err});
        };
        return 1;
    }

    // Ctrl+Shift+D: Split right
    if (keyval == c.GDK_KEY_D or keyval == c.GDK_KEY_d) {
        window.splitFocused(.right) catch |err| {
            log.warn("Failed to split right: {}", .{err});
        };
        return 1;
    }

    // Ctrl+Shift+E: Split down
    if (keyval == c.GDK_KEY_E or keyval == c.GDK_KEY_e) {
        window.splitFocused(.down) catch |err| {
            log.warn("Failed to split down: {}", .{err});
        };
        return 1;
    }

    // Ctrl+Shift+Arrows: Navigate between panes
    if (keyval == c.GDK_KEY_Left) {
        window.navigateFocus(.left);
        return 1;
    }
    if (keyval == c.GDK_KEY_Right) {
        window.navigateFocus(.right);
        return 1;
    }
    if (keyval == c.GDK_KEY_Up) {
        window.navigateFocus(.up);
        return 1;
    }
    if (keyval == c.GDK_KEY_Down) {
        window.navigateFocus(.down);
        return 1;
    }

    // Ctrl+Shift+]: Next workspace
    if (keyval == c.GDK_KEY_bracketright) {
        window.nextWorkspace();
        return 1;
    }

    // Ctrl+Shift+[: Previous workspace
    if (keyval == c.GDK_KEY_bracketleft) {
        window.previousWorkspace();
        return 1;
    }

    // Ctrl+Shift+B: Toggle sidebar
    if (keyval == c.GDK_KEY_B or keyval == c.GDK_KEY_b) {
        window.toggleSidebar();
        return 1;
    }

    // Ctrl+Shift+P: Command palette
    if (keyval == c.GDK_KEY_P or keyval == c.GDK_KEY_p) {
        window.toggleCommandPalette();
        return 1;
    }

    // Ctrl+Shift+F: Terminal search
    if (keyval == c.GDK_KEY_F or keyval == c.GDK_KEY_f) {
        window.showSearch();
        return 1;
    }

    // Ctrl+Shift+H: History browser
    if (keyval == c.GDK_KEY_H or keyval == c.GDK_KEY_h) {
        window.toggleHistory();
        return 1;
    }

    // Ctrl+Shift+Q: Close workspace
    if (keyval == c.GDK_KEY_Q or keyval == c.GDK_KEY_q) {
        window.closeCurrentWorkspace();
        return 1;
    }

    // Ctrl+Shift+`: Last workspace (most recently used)
    if (keyval == c.GDK_KEY_grave) {
        window.lastWorkspace();
        return 1;
    }

    return 0; // Not handled
}
