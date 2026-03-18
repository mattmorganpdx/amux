const std = @import("std");
const c = @import("c.zig");
const TerminalWidget = @import("terminal_widget.zig");
const Window = @import("window.zig");

const log = std.log.scoped(.search_overlay);

const SearchOverlay = @This();

const Allocator = std.mem.Allocator;

/// Helper to cast any GTK widget subtype to *GtkWidget with proper alignment.
inline fn asWidget(ptr: anytype) *c.GtkWidget {
    return @ptrCast(@alignCast(ptr));
}

/// The outer container (horizontal box: entry + match count + close button).
container: *c.GtkBox,

/// The search entry field.
search_entry: *c.GtkSearchEntry,

/// The match count label ("3/17").
match_label: *c.GtkLabel,

/// Whether the overlay is currently visible.
visible: bool = false,

/// The current terminal widget being searched (for sending search commands).
current_surface: ?c.ghostty_surface_t = null,

/// Reference to the parent window for focus restoration.
window: ?*Window = null,

/// Match count state.
total_matches: i64 = 0,
selected_match: i64 = 0,

alloc: Allocator,

pub fn create(alloc: Allocator) !*SearchOverlay {
    const self = try alloc.create(SearchOverlay);

    // Container: horizontal box with search-overlay CSS class
    const container: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6));
    c.gtk_widget_add_css_class(asWidget(container), "search-overlay");
    c.gtk_widget_set_halign(asWidget(container), c.GTK_ALIGN_END);
    c.gtk_widget_set_valign(asWidget(container), c.GTK_ALIGN_START);

    // Search entry
    const search_entry: *c.GtkSearchEntry = @ptrCast(@alignCast(c.gtk_search_entry_new()));
    c.gtk_widget_set_size_request(asWidget(search_entry), 250, -1);
    c.gtk_box_append(container, asWidget(search_entry));

    // Match count label
    const match_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new("")));
    c.gtk_widget_add_css_class(asWidget(match_label), "dim-label");
    c.gtk_box_append(container, asWidget(match_label));

    // Close button
    const close_btn: *c.GtkButton = @ptrCast(@alignCast(c.gtk_button_new_with_label("×")));
    c.gtk_box_append(container, asWidget(close_btn));

    // Start hidden
    c.gtk_widget_set_visible(asWidget(container), 0);

    self.* = .{
        .container = container,
        .search_entry = search_entry,
        .match_label = match_label,
        .alloc = alloc,
    };

    // Connect search-changed signal
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(search_entry)),
        "search-changed",
        @as(c.GCallback, @ptrCast(&onSearchChanged)),
        @ptrCast(self),
        null,
        0,
    );

    // Connect close button
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(close_btn)),
        "clicked",
        @as(c.GCallback, @ptrCast(&onCloseClicked)),
        @ptrCast(self),
        null,
        0,
    );

    // Connect key-pressed on search entry for Escape/Enter/Shift+Enter
    const key_controller = c.gtk_event_controller_key_new();
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(key_controller)),
        "key-pressed",
        @as(c.GCallback, @ptrCast(&onKeyPressed)),
        @ptrCast(self),
        null,
        0,
    );
    c.gtk_widget_add_controller(asWidget(search_entry), key_controller);

    return self;
}

pub fn deinit(self: *SearchOverlay) void {
    self.alloc.destroy(self);
}

/// Get the overlay widget for embedding in a GtkOverlay.
pub fn widget(self: *SearchOverlay) *c.GtkWidget {
    return asWidget(self.container);
}

/// Show the search overlay and focus the entry.
pub fn show(self: *SearchOverlay, surface: ?c.ghostty_surface_t) void {
    self.visible = true;
    self.current_surface = surface;
    self.total_matches = 0;
    self.selected_match = 0;
    c.gtk_widget_set_visible(asWidget(self.container), 1);
    c.gtk_editable_set_text(@ptrCast(self.search_entry), "");
    updateMatchLabel(self);
    _ = c.gtk_widget_grab_focus(asWidget(self.search_entry));
}

/// Hide the search overlay and return focus to the terminal.
pub fn hide(self: *SearchOverlay) void {
    if (!self.visible) return;
    self.visible = false;
    c.gtk_widget_set_visible(asWidget(self.container), 0);

    // Tell Ghostty to end search
    if (self.current_surface) |surface| {
        _ = c.ghostty_surface_binding_action(surface, "end_search", "end_search".len);
    }
    self.current_surface = null;

    // Return focus to the terminal
    if (self.window) |w| w.focusCurrentTerminal();
}

/// Update match count from Ghostty search callback.
pub fn updateSearchTotal(self: *SearchOverlay, total: i64) void {
    self.total_matches = total;
    updateMatchLabel(self);
}

/// Update selected match index from Ghostty search callback.
pub fn updateSearchSelected(self: *SearchOverlay, selected: i64) void {
    self.selected_match = selected;
    updateMatchLabel(self);
}

// ------------------------------------------------------------------
// Internal
// ------------------------------------------------------------------

fn updateMatchLabel(self: *SearchOverlay) void {
    if (self.total_matches <= 0) {
        c.gtk_label_set_text(self.match_label, "");
    } else {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}/{d}", .{ self.selected_match, self.total_matches }) catch "";
        var z_buf: [33]u8 = undefined;
        const len = @min(text.len, z_buf.len - 1);
        @memcpy(z_buf[0..len], text[0..len]);
        z_buf[len] = 0;
        c.gtk_label_set_text(self.match_label, &z_buf);
    }
}

fn sendSearchText(self: *SearchOverlay) void {
    const surface = self.current_surface orelse return;
    const text_ptr = c.gtk_editable_get_text(@ptrCast(self.search_entry));
    if (text_ptr == null) return;
    const text = std.mem.span(text_ptr.?);

    if (text.len == 0) {
        _ = c.ghostty_surface_binding_action(surface, "end_search", "end_search".len);
        return;
    }

    // Build "search:<text>" command — Ghostty's binding action format
    var cmd_buf: [1024]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "search:{s}", .{text}) catch return;
    _ = c.ghostty_surface_binding_action(surface, cmd.ptr, cmd.len);
}

fn nextMatch(self: *SearchOverlay) void {
    const surface = self.current_surface orelse return;
    _ = c.ghostty_surface_binding_action(surface, "navigate_search:next", "navigate_search:next".len);
}

fn prevMatch(self: *SearchOverlay) void {
    const surface = self.current_surface orelse return;
    _ = c.ghostty_surface_binding_action(surface, "navigate_search:previous", "navigate_search:previous".len);
}

// ------------------------------------------------------------------
// Signal handlers
// ------------------------------------------------------------------

fn onSearchChanged(
    _: *c.GtkSearchEntry,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *SearchOverlay = @ptrCast(@alignCast(userdata));
    self.sendSearchText();
}

fn onCloseClicked(
    _: *c.GtkButton,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *SearchOverlay = @ptrCast(@alignCast(userdata));
    self.hide();
}

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    state: c.GdkModifierType,
    userdata: c.gpointer,
) callconv(.c) c.gboolean {
    const self: *SearchOverlay = @ptrCast(@alignCast(userdata));

    if (keyval == c.GDK_KEY_Escape) {
        self.hide();
        return 1;
    }

    if (keyval == c.GDK_KEY_Return) {
        const has_shift = (state & c.GDK_SHIFT_MASK) != 0;
        if (has_shift) {
            self.prevMatch();
        } else {
            self.nextMatch();
        }
        return 1;
    }

    return 0;
}
