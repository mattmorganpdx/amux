const std = @import("std");
const c = @import("c.zig");
const TerminalWidget = @import("terminal_widget.zig");

const log = std.log.scoped(.clipboard);

/// Context for an async clipboard read, passed through g_idle_add and the GDK async callback.
const ClipboardReadContext = struct {
    surface: c.ghostty_surface_t,
    clipboard_type: c.ghostty_clipboard_e,
    request: ?*anyopaque,
};

/// Read from the system clipboard.
/// Called by Ghostty when the user pastes (Ctrl+Shift+V, middle-click, etc.).
/// May be called from the renderer thread, so we dispatch to the main thread.
pub fn readCallback(
    surface_userdata: ?*anyopaque,
    clipboard_type: c.ghostty_clipboard_e,
    request: ?*anyopaque,
) callconv(.c) void {
    const tw: *TerminalWidget = @ptrCast(@alignCast(surface_userdata orelse return));
    if (tw.surface == null) return;

    const ctx = std.heap.c_allocator.create(ClipboardReadContext) catch return;
    ctx.* = .{
        .surface = tw.surface,
        .clipboard_type = clipboard_type,
        .request = request,
    };

    // Dispatch to GTK main thread for GDK clipboard access
    _ = c.g_idle_add(&doClipboardRead, @ptrCast(ctx));
}

/// Runs on the GTK main thread: initiates the async clipboard read.
fn doClipboardRead(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *ClipboardReadContext = @ptrCast(@alignCast(userdata));

    const display = c.gdk_display_get_default() orelse {
        // Can't get display — complete with null to unblock Ghostty
        c.ghostty_surface_complete_clipboard_request(ctx.surface, null, ctx.request, false);
        std.heap.c_allocator.destroy(ctx);
        return c.G_SOURCE_REMOVE;
    };

    const clipboard = switch (ctx.clipboard_type) {
        c.GHOSTTY_CLIPBOARD_STANDARD => c.gdk_display_get_clipboard(display),
        c.GHOSTTY_CLIPBOARD_SELECTION => c.gdk_display_get_primary_clipboard(display),
        else => {
            c.ghostty_surface_complete_clipboard_request(ctx.surface, null, ctx.request, false);
            std.heap.c_allocator.destroy(ctx);
            return c.G_SOURCE_REMOVE;
        },
    };

    if (clipboard == null) {
        c.ghostty_surface_complete_clipboard_request(ctx.surface, null, ctx.request, false);
        std.heap.c_allocator.destroy(ctx);
        return c.G_SOURCE_REMOVE;
    }

    // Start async clipboard read — the finish callback will complete the Ghostty request
    c.gdk_clipboard_read_text_async(clipboard, null, &onClipboardReadFinish, @ptrCast(ctx));

    return c.G_SOURCE_REMOVE;
}

/// GAsyncReadyCallback for clipboard read completion. Runs on the main thread.
fn onClipboardReadFinish(
    source_object: ?*c.GObject,
    result: ?*c.GAsyncResult,
    userdata: c.gpointer,
) callconv(.c) void {
    const ctx: *ClipboardReadContext = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(ctx);

    var err: ?*c.GError = null;
    const text = c.gdk_clipboard_read_text_finish(@ptrCast(source_object), result, &err);

    if (err != null) {
        if (err.?.*.message != null) {
            log.warn("Clipboard read failed: {s}", .{err.?.*.message});
        }
        c.g_error_free(err.?);
        c.ghostty_surface_complete_clipboard_request(ctx.surface, null, ctx.request, false);
        return;
    }

    // gdk_clipboard_read_text_finish can return null with no error when the
    // clipboard is empty — handle that explicitly.
    if (text == null) {
        c.ghostty_surface_complete_clipboard_request(ctx.surface, null, ctx.request, false);
        return;
    }

    // Complete the Ghostty clipboard request with the text
    c.ghostty_surface_complete_clipboard_request(ctx.surface, text, ctx.request, false);
    c.g_free(@ptrCast(@constCast(text)));
}

/// Confirm clipboard read (security check).
/// Auto-confirm for now — pass the content straight through.
pub fn confirmReadCallback(
    surface_userdata: ?*anyopaque,
    content: [*c]const u8,
    request: ?*anyopaque,
    request_type: c.ghostty_clipboard_request_e,
) callconv(.c) void {
    _ = request_type;

    const tw: *TerminalWidget = @ptrCast(@alignCast(surface_userdata orelse return));
    if (tw.surface == null) return;

    // Auto-confirm: complete the request immediately
    c.ghostty_surface_complete_clipboard_request(tw.surface, content, request, true);
}

/// Write to the system clipboard.
/// C typedef: void (*)(void*, ghostty_clipboard_e, const ghostty_clipboard_content_s*, size_t, bool)
pub fn writeCallback(
    surface_userdata: ?*anyopaque,
    clipboard_type: c.ghostty_clipboard_e,
    content: [*c]const c.ghostty_clipboard_content_s,
    content_len: usize,
    confirm: bool,
) callconv(.c) void {
    _ = surface_userdata;
    _ = confirm;

    if (content_len == 0) return;

    // Get the display's clipboard
    const display = c.gdk_display_get_default() orelse return;
    const clipboard = switch (clipboard_type) {
        c.GHOSTTY_CLIPBOARD_STANDARD => c.gdk_display_get_clipboard(display),
        c.GHOSTTY_CLIPBOARD_SELECTION => c.gdk_display_get_primary_clipboard(display),
        else => return,
    };

    if (clipboard == null) return;

    // Use the first content entry's data as the clipboard text
    const first = content[0];
    if (first.data != null) {
        c.gdk_clipboard_set_text(clipboard, first.data);
    }
}
