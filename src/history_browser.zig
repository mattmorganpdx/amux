const std = @import("std");
const c = @import("c.zig");
const Window = @import("window.zig");
const history = @import("history.zig");

const log = std.log.scoped(.history_browser);

const HistoryBrowser = @This();

const Allocator = std.mem.Allocator;

/// Helper to cast any GTK widget subtype to *GtkWidget with proper alignment.
inline fn asWidget(ptr: anytype) *c.GtkWidget {
    return @ptrCast(@alignCast(ptr));
}

/// The outer container for the overlay.
container: *c.GtkBox,

/// Search entry for filtering.
search_entry: *c.GtkSearchEntry,

/// List box showing history entries.
list_box: *c.GtkListBox,

/// Scrolled window for the list.
list_scrolled: *c.GtkScrolledWindow,

/// Preview text view (monospace, read-only). Stored as GtkWidget
/// because GtkTextView is not exported through c.zig.
preview_view: *c.GtkWidget,

/// Scrolled window for preview.
preview_scrolled: *c.GtkScrolledWindow,

/// Restore button.
restore_button: *c.GtkButton,

/// Whether the browser is currently visible.
visible: bool = false,

/// Reference to the window.
window: *Window,

/// Allocator.
alloc: Allocator,

/// Cached entry IDs for the current list (stored as g_object_set_data on rows).
/// We keep a list so we can free the heap-duped strings on repopulate.
cached_ids: std.ArrayListUnmanaged([]const u8) = .{},

pub fn create(alloc: Allocator, window: *Window) !*HistoryBrowser {
    const self = try alloc.create(HistoryBrowser);

    // Outer container: vertical box
    const container: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0));
    c.gtk_widget_add_css_class(asWidget(container), "history-browser");

    // Fill most of the overlay area
    c.gtk_widget_set_halign(asWidget(container), c.GTK_ALIGN_FILL);
    c.gtk_widget_set_valign(asWidget(container), c.GTK_ALIGN_FILL);
    c.gtk_widget_set_margin_start(asWidget(container), 40);
    c.gtk_widget_set_margin_end(asWidget(container), 40);
    c.gtk_widget_set_margin_top(asWidget(container), 30);
    c.gtk_widget_set_margin_bottom(asWidget(container), 30);

    // ---- Header bar ----
    const header: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8));
    c.gtk_widget_set_margin_start(asWidget(header), 12);
    c.gtk_widget_set_margin_end(asWidget(header), 12);
    c.gtk_widget_set_margin_top(asWidget(header), 8);
    c.gtk_widget_set_margin_bottom(asWidget(header), 4);

    // Title
    const title_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new("Terminal History")));
    c.gtk_widget_add_css_class(asWidget(title_label), "title-3");
    c.gtk_widget_add_css_class(asWidget(title_label), "history-title");
    c.gtk_widget_set_hexpand(asWidget(title_label), 0);
    c.gtk_box_append(header, asWidget(title_label));

    // Search entry
    const search_entry: *c.GtkSearchEntry = @ptrCast(@alignCast(c.gtk_search_entry_new()));
    c.gtk_widget_set_hexpand(asWidget(search_entry), 1);
    c.gtk_box_append(header, asWidget(search_entry));

    // Close button
    const close_btn: *c.GtkButton = @ptrCast(@alignCast(c.gtk_button_new_with_label("Close")));
    c.gtk_box_append(header, asWidget(close_btn));

    c.gtk_box_append(container, asWidget(header));

    // Separator
    const sep: *c.GtkSeparator = @ptrCast(@alignCast(c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL)));
    c.gtk_box_append(container, asWidget(sep));

    // ---- Content: GtkPaned (list | preview) ----
    const paned: *c.GtkPaned = @ptrCast(@alignCast(c.gtk_paned_new(c.GTK_ORIENTATION_HORIZONTAL)));
    c.gtk_widget_set_vexpand(asWidget(paned), 1);
    c.gtk_widget_set_hexpand(asWidget(paned), 1);

    // Left: list
    const list_box: *c.GtkListBox = @ptrCast(@alignCast(c.gtk_list_box_new()));
    c.gtk_list_box_set_selection_mode(list_box, c.GTK_SELECTION_SINGLE);

    const list_scrolled: *c.GtkScrolledWindow = @ptrCast(@alignCast(c.gtk_scrolled_window_new()));
    c.gtk_scrolled_window_set_policy(list_scrolled, c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_size_request(asWidget(list_scrolled), 320, -1);
    c.gtk_scrolled_window_set_child(list_scrolled, asWidget(list_box));
    c.gtk_paned_set_start_child(paned, asWidget(list_scrolled));
    c.gtk_paned_set_resize_start_child(paned, 0);
    c.gtk_paned_set_shrink_start_child(paned, 0);

    // Right: preview
    const preview_view: *c.GtkWidget = @ptrCast(@alignCast(c.gtk_text_view_new()));
    c.gtk_text_view_set_editable(@ptrCast(@alignCast(preview_view)), 0);
    c.gtk_text_view_set_cursor_visible(@ptrCast(@alignCast(preview_view)), 0);
    c.gtk_text_view_set_monospace(@ptrCast(@alignCast(preview_view)), 1);
    c.gtk_text_view_set_wrap_mode(@ptrCast(@alignCast(preview_view)), c.GTK_WRAP_NONE);
    c.gtk_widget_set_margin_start(preview_view, 4);
    c.gtk_widget_set_margin_end(preview_view, 4);
    c.gtk_widget_set_margin_top(preview_view, 4);
    c.gtk_widget_set_margin_bottom(preview_view, 4);

    const preview_scrolled: *c.GtkScrolledWindow = @ptrCast(@alignCast(c.gtk_scrolled_window_new()));
    c.gtk_scrolled_window_set_policy(preview_scrolled, c.GTK_POLICY_AUTOMATIC, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_child(preview_scrolled, preview_view);
    c.gtk_paned_set_end_child(paned, asWidget(preview_scrolled));
    c.gtk_paned_set_resize_end_child(paned, 1);
    c.gtk_paned_set_shrink_end_child(paned, 0);

    c.gtk_box_append(container, asWidget(paned));

    // ---- Footer: restore button ----
    const footer: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8));
    c.gtk_widget_set_margin_start(asWidget(footer), 12);
    c.gtk_widget_set_margin_end(asWidget(footer), 12);
    c.gtk_widget_set_margin_top(asWidget(footer), 4);
    c.gtk_widget_set_margin_bottom(asWidget(footer), 8);
    c.gtk_widget_set_halign(asWidget(footer), c.GTK_ALIGN_END);

    const restore_button: *c.GtkButton = @ptrCast(@alignCast(c.gtk_button_new_with_label("Restore as Workspace")));
    c.gtk_widget_add_css_class(asWidget(restore_button), "suggested-action");
    c.gtk_box_append(footer, asWidget(restore_button));

    c.gtk_box_append(container, asWidget(footer));

    // Start hidden
    c.gtk_widget_set_visible(asWidget(container), 0);

    self.* = .{
        .container = container,
        .search_entry = search_entry,
        .list_box = list_box,
        .list_scrolled = list_scrolled,
        .preview_view = preview_view,
        .preview_scrolled = preview_scrolled,
        .restore_button = restore_button,
        .window = window,
        .alloc = alloc,
    };

    // Connect signals

    // Search changed → filter
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(search_entry)),
        "search-changed",
        @as(c.GCallback, @ptrCast(&onSearchChanged)),
        @ptrCast(self),
        null,
        0,
    );

    // Row selected → show preview
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(list_box)),
        "row-selected",
        @as(c.GCallback, @ptrCast(&onRowSelected)),
        @ptrCast(self),
        null,
        0,
    );

    // Restore button
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(restore_button)),
        "clicked",
        @as(c.GCallback, @ptrCast(&onRestoreClicked)),
        @ptrCast(self),
        null,
        0,
    );

    // Close button
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(close_btn)),
        "clicked",
        @as(c.GCallback, @ptrCast(&onCloseClicked)),
        @ptrCast(self),
        null,
        0,
    );

    // Key press on search entry (Escape to close)
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

pub fn deinit(self: *HistoryBrowser) void {
    self.freeCachedIds();
    self.alloc.destroy(self);
}

/// Get the widget for embedding in the overlay.
pub fn widget(self: *HistoryBrowser) *c.GtkWidget {
    return asWidget(self.container);
}

/// Show the history browser.
pub fn show(self: *HistoryBrowser) void {
    self.visible = true;
    c.gtk_widget_set_visible(asWidget(self.container), 1);

    // Clear search, populate with all entries
    c.gtk_editable_set_text(@ptrCast(self.search_entry), "");
    self.populateResults("");

    // Clear preview
    self.setPreviewText("Select a session to preview its scrollback.");

    // Focus search
    _ = c.gtk_widget_grab_focus(asWidget(self.search_entry));
}

/// Hide the browser and return focus to the terminal.
pub fn hide(self: *HistoryBrowser) void {
    self.visible = false;
    c.gtk_widget_set_visible(asWidget(self.container), 0);
    self.window.focusCurrentTerminal();
}

/// Toggle visibility.
pub fn toggle(self: *HistoryBrowser) void {
    if (self.visible) {
        self.hide();
    } else {
        self.show();
    }
}

// ------------------------------------------------------------------
// Internal
// ------------------------------------------------------------------

fn freeCachedIds(self: *HistoryBrowser) void {
    for (self.cached_ids.items) |id| {
        self.alloc.free(id);
    }
    self.cached_ids.deinit(self.alloc);
    self.cached_ids = .{};
}

fn populateResults(self: *HistoryBrowser, query: []const u8) void {
    // Remove all existing rows
    while (true) {
        const row = c.gtk_list_box_get_row_at_index(self.list_box, 0);
        if (row == null) break;
        c.gtk_list_box_remove(self.list_box, asWidget(row));
    }

    // Free old cached IDs
    self.freeCachedIds();
    self.cached_ids = .{};

    // Load index
    var index = history.loadIndex(self.alloc) catch {
        self.setPreviewText("No history found.");
        return;
    };
    defer history.freeIndex(self.alloc, &index);

    // Iterate in reverse (newest first), filter by query
    var i: usize = index.entries.items.len;
    var row_idx: usize = 0;
    while (i > 0) {
        i -= 1;
        const entry = index.entries.items[i];

        if (query.len > 0) {
            // Simple filter: workspace title, cwd, id, reason
            if (!containsIgnoreCase(entry.workspace_title, query) and
                !containsIgnoreCase(entry.cwd, query) and
                !containsIgnoreCase(entry.id, query) and
                !containsIgnoreCase(entry.reason, query))
            {
                continue;
            }
        }

        // Dupe the entry ID for storage
        const duped_id = self.alloc.dupe(u8, entry.id) catch continue;
        self.cached_ids.append(self.alloc, duped_id) catch {
            self.alloc.free(duped_id);
            continue;
        };

        self.appendEntryRow(&entry, row_idx);
        row_idx += 1;
    }

    // Select first row
    if (row_idx > 0) {
        const first = c.gtk_list_box_get_row_at_index(self.list_box, 0);
        c.gtk_list_box_select_row(self.list_box, first);
    }
}

fn appendEntryRow(self: *HistoryBrowser, entry: *const history.HistoryEntry, idx: usize) void {
    const row: *c.GtkListBoxRow = @ptrCast(@alignCast(c.gtk_list_box_row_new()));

    const vbox: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2));
    c.gtk_widget_set_margin_start(asWidget(vbox), 8);
    c.gtk_widget_set_margin_end(asWidget(vbox), 8);
    c.gtk_widget_set_margin_top(asWidget(vbox), 6);
    c.gtk_widget_set_margin_bottom(asWidget(vbox), 6);

    // Top line: workspace title + line count
    const hbox: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8));

    // Title
    var title_buf: [300]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "{s}", .{
        entry.workspace_title,
    }) catch "?";
    const title_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new(title.ptr)));
    c.gtk_label_set_xalign(title_label, 0.0);
    c.gtk_widget_set_hexpand(asWidget(title_label), 1);
    c.gtk_label_set_ellipsize(title_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(hbox, asWidget(title_label));

    // Line count (right-aligned, dim)
    var lines_buf: [64]u8 = undefined;
    const lines_str = std.fmt.bufPrintZ(&lines_buf, "{d} lines", .{entry.lines}) catch "?";
    const lines_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new(lines_str.ptr)));
    c.gtk_widget_add_css_class(asWidget(lines_label), "dim-label");
    c.gtk_box_append(hbox, asWidget(lines_label));

    c.gtk_box_append(vbox, asWidget(hbox));

    // Second line: cwd (dim)
    var cwd_buf: [512]u8 = undefined;
    const cwd_str = std.fmt.bufPrintZ(&cwd_buf, "{s}", .{entry.cwd}) catch "?";
    const cwd_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new(cwd_str.ptr)));
    c.gtk_label_set_xalign(cwd_label, 0.0);
    c.gtk_label_set_ellipsize(cwd_label, c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_widget_add_css_class(asWidget(cwd_label), "dim-label");
    c.gtk_box_append(vbox, asWidget(cwd_label));

    // Third line: timestamp + reason (dim, small)
    var meta_buf: [128]u8 = undefined;
    const meta_str = std.fmt.bufPrintZ(&meta_buf, "{s}  |  {s}", .{
        formatTimestamp(entry.closed_at),
        entry.reason,
    }) catch "?";
    const meta_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new(meta_str.ptr)));
    c.gtk_label_set_xalign(meta_label, 0.0);
    c.gtk_widget_add_css_class(asWidget(meta_label), "dim-label");
    c.gtk_box_append(vbox, asWidget(meta_label));

    c.gtk_list_box_row_set_child(row, asWidget(vbox));
    c.gtk_list_box_append(self.list_box, asWidget(row));

    // Store the index into cached_ids
    c.g_object_set_data(
        @as([*c]c.GObject, @ptrCast(row)),
        "entry-idx",
        @ptrFromInt(idx),
    );
}

fn formatTimestamp(ts: i64) []const u8 {
    // Simple: just show seconds ago / minutes ago / hours ago / days ago
    const now = std.time.timestamp();
    const diff = now - ts;
    const Static = struct {
        var buf: [64]u8 = undefined;
    };
    if (diff < 60) {
        return std.fmt.bufPrint(&Static.buf, "{d}s ago", .{diff}) catch "?";
    } else if (diff < 3600) {
        return std.fmt.bufPrint(&Static.buf, "{d}m ago", .{@divTrunc(diff, 60)}) catch "?";
    } else if (diff < 86400) {
        return std.fmt.bufPrint(&Static.buf, "{d}h ago", .{@divTrunc(diff, 3600)}) catch "?";
    } else {
        return std.fmt.bufPrint(&Static.buf, "{d}d ago", .{@divTrunc(diff, 86400)}) catch "?";
    }
}

fn setPreviewText(self: *HistoryBrowser, text: []const u8) void {
    const buffer = c.gtk_text_view_get_buffer(@ptrCast(@alignCast(self.preview_view)));
    c.gtk_text_buffer_set_text(buffer, text.ptr, @intCast(text.len));
}

fn getSelectedEntryId(self: *HistoryBrowser) ?[]const u8 {
    const row = c.gtk_list_box_get_selected_row(self.list_box) orelse return null;
    const idx = @intFromPtr(c.g_object_get_data(
        @as([*c]c.GObject, @ptrCast(row)),
        "entry-idx",
    ));
    if (idx >= self.cached_ids.items.len) return null;
    return self.cached_ids.items[idx];
}

fn loadAndShowPreview(self: *HistoryBrowser, entry_id: []const u8) void {
    const text = history.loadEntryText(self.alloc, entry_id) catch {
        self.setPreviewText("Failed to load scrollback.");
        return;
    };
    defer self.alloc.free(text);

    // Truncate preview to avoid overwhelming the text view
    const max_preview: usize = 64 * 1024; // 64KB
    const show_text = if (text.len > max_preview) text[text.len - max_preview ..] else text;
    self.setPreviewText(show_text);
}

fn restoreSelectedEntry(self: *HistoryBrowser) void {
    const entry_id = self.getSelectedEntryId() orelse return;

    // Load entry metadata to get cwd and workspace title
    var index = history.loadIndex(self.alloc) catch return;
    defer history.freeIndex(self.alloc, &index);

    var target_entry: ?history.HistoryEntry = null;
    for (index.entries.items) |e| {
        if (std.mem.eql(u8, e.id, entry_id)) {
            target_entry = e;
            break;
        }
    }

    const entry = target_entry orelse return;

    // Hide the browser first
    self.hide();

    // Create a new workspace
    const ws = self.window.tab_manager.createWorkspace() catch return;

    // Set title from history entry
    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "{s}", .{entry.workspace_title}) catch "Restored";
    ws.setTitle(title);

    // Set cwd
    if (entry.cwd.len > 0) {
        ws.setCwd(entry.cwd);
    }

    // Set the command for the root pane to replay scrollback
    if (ws.pane_tree.focused_pane) |pane_id| {
        // Store the history ID so buildWorkspaceWidgets picks it up
        const duped = self.alloc.dupe(u8, entry_id) catch return;
        self.window.pane_history_ids.put(pane_id, duped) catch {
            self.alloc.free(duped);
        };
    }

    // Select the new workspace
    self.window.tab_manager.selectIndex(self.window.tab_manager.workspaces.items.len - 1);

    // Build widgets (this will use pane_history_ids to set the restore command)
    self.window.buildWorkspaceWidgets(ws) catch |err| {
        log.warn("Failed to build workspace widgets for history restore: {}", .{err});
        return;
    };
    self.window.showWorkspaceInStack(ws.id);

    // Update sidebar and focus
    self.window.sidebar.rebuild();
    if (ws.pane_tree.focused_pane) |pane_id| {
        if (self.window.pane_widgets.get(pane_id)) |tw| {
            _ = c.gtk_widget_grab_focus(tw.widget());
        }
    }

    log.info("Restored history entry {s} as workspace '{s}'", .{ entry_id, title });
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Scroll the list so the given row is visible.
fn scrollRowIntoView(self: *HistoryBrowser, row: *c.GtkListBoxRow) void {
    const adj = c.gtk_scrolled_window_get_vadjustment(self.list_scrolled) orelse return;

    var row_point = c.graphene_point_t{ .x = 0, .y = 0 };
    var list_point: c.graphene_point_t = undefined;
    if (c.gtk_widget_compute_point(asWidget(row), asWidget(self.list_box), &row_point, &list_point) == 0)
        return;

    const row_y: f64 = @floatCast(list_point.y);
    const row_height: f64 = @floatFromInt(c.gtk_widget_get_height(asWidget(row)));
    const visible_top = c.gtk_adjustment_get_value(adj);
    const page_size = c.gtk_adjustment_get_page_size(adj);
    const visible_bottom = visible_top + page_size;

    if (row_y + row_height > visible_bottom) {
        c.gtk_adjustment_set_value(adj, row_y + row_height - page_size);
    } else if (row_y < visible_top) {
        c.gtk_adjustment_set_value(adj, row_y);
    }
}

// ------------------------------------------------------------------
// Signal handlers
// ------------------------------------------------------------------

fn onSearchChanged(
    _: *c.GtkSearchEntry,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *HistoryBrowser = @ptrCast(@alignCast(userdata));
    const text_ptr = c.gtk_editable_get_text(@ptrCast(self.search_entry));
    if (text_ptr == null) return;
    const text = std.mem.span(text_ptr.?);
    self.populateResults(text);
}

fn onRowSelected(
    _: *c.GtkListBox,
    row: ?*c.GtkListBoxRow,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *HistoryBrowser = @ptrCast(@alignCast(userdata));
    if (row == null) return;

    const idx = @intFromPtr(c.g_object_get_data(
        @as([*c]c.GObject, @ptrCast(row.?)),
        "entry-idx",
    ));
    if (idx >= self.cached_ids.items.len) return;

    self.loadAndShowPreview(self.cached_ids.items[idx]);
}

fn onRestoreClicked(
    _: *c.GtkButton,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *HistoryBrowser = @ptrCast(@alignCast(userdata));
    self.restoreSelectedEntry();
}

fn onCloseClicked(
    _: *c.GtkButton,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *HistoryBrowser = @ptrCast(@alignCast(userdata));
    self.hide();
}

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    _: c.GdkModifierType,
    userdata: c.gpointer,
) callconv(.c) c.gboolean {
    const self: *HistoryBrowser = @ptrCast(@alignCast(userdata));

    if (keyval == c.GDK_KEY_Escape) {
        self.hide();
        return 1;
    }

    // Enter: restore the selected entry
    if (keyval == c.GDK_KEY_Return) {
        self.restoreSelectedEntry();
        return 1;
    }

    // Arrow down: move selection down in list
    if (keyval == c.GDK_KEY_Down) {
        const selected = c.gtk_list_box_get_selected_row(self.list_box);
        if (selected) |row| {
            const idx = c.gtk_list_box_row_get_index(row);
            const next = c.gtk_list_box_get_row_at_index(self.list_box, idx + 1);
            if (next) |n| {
                c.gtk_list_box_select_row(self.list_box, n);
                self.scrollRowIntoView(n);
            }
        }
        return 1;
    }

    // Arrow up: move selection up in list
    if (keyval == c.GDK_KEY_Up) {
        const selected = c.gtk_list_box_get_selected_row(self.list_box);
        if (selected) |row| {
            const idx = c.gtk_list_box_row_get_index(row);
            if (idx > 0) {
                const prev = c.gtk_list_box_get_row_at_index(self.list_box, idx - 1);
                if (prev) |p| {
                    c.gtk_list_box_select_row(self.list_box, p);
                    self.scrollRowIntoView(p);
                }
            }
        }
        return 1;
    }

    return 0;
}
