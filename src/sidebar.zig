const std = @import("std");
const c = @import("c.zig");
const TabManager = @import("tab_manager.zig");
const Workspace = @import("workspace.zig");

const log = std.log.scoped(.sidebar);

const Sidebar = @This();

const Allocator = std.mem.Allocator;

/// Helper to cast any GTK widget subtype to *GtkWidget with proper alignment.
inline fn asWidget(ptr: anytype) *c.GtkWidget {
    return @ptrCast(@alignCast(ptr));
}

/// Key for storing the real workspace index on each GtkListBoxRow.
const ws_index_key = "ws-idx";

/// Callback type for when the user selects a workspace in the sidebar.
pub const SelectCallback = *const fn (index: usize, userdata: ?*anyopaque) void;

/// The outer container (vertical box: header + scrolled list).
container: *c.GtkBox,

/// The scrolled window containing the list box.
scrolled: *c.GtkScrolledWindow,

/// The GtkListBox holding workspace rows.
list_box: *c.GtkListBox,

/// Reference to the tab manager for reading workspace data.
tab_manager: *TabManager,

/// Workspace selection callback.
on_select: ?SelectCallback = null,
on_select_userdata: ?*anyopaque = null,

/// Whether we're programmatically updating selection (to avoid re-entrant callbacks).
updating: bool = false,

alloc: Allocator,

pub fn create(alloc: Allocator, tab_manager: *TabManager) !*Sidebar {
    const self = try alloc.create(Sidebar);

    // Create the sidebar container (vertical box)
    const container: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0));
    c.gtk_widget_set_size_request(asWidget(container), 200, -1);
    c.gtk_widget_add_css_class(asWidget(container), "sidebar");

    // Create header label
    const header_box: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0));
    c.gtk_widget_set_margin_start(asWidget(header_box), 12);
    c.gtk_widget_set_margin_end(asWidget(header_box), 12);
    c.gtk_widget_set_margin_top(asWidget(header_box), 8);
    c.gtk_widget_set_margin_bottom(asWidget(header_box), 8);

    const header_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new("Workspaces")));
    c.gtk_label_set_xalign(header_label, 0.0);
    c.gtk_widget_set_hexpand(asWidget(header_label), 1);
    c.gtk_widget_add_css_class(asWidget(header_label), "heading");
    c.gtk_box_append(header_box, asWidget(header_label));

    c.gtk_box_append(container, asWidget(header_box));

    // Add a separator
    const sep: *c.GtkSeparator = @ptrCast(@alignCast(c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL)));
    c.gtk_box_append(container, asWidget(sep));

    // Create the scrolled window for the list
    const scrolled: *c.GtkScrolledWindow = @ptrCast(@alignCast(c.gtk_scrolled_window_new()));
    c.gtk_scrolled_window_set_policy(scrolled, c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_vexpand(asWidget(scrolled), 1);

    // Create the list box — not focusable so clicking rows doesn't steal
    // keyboard focus from the terminal surface.
    const list_box: *c.GtkListBox = @ptrCast(@alignCast(c.gtk_list_box_new()));
    c.gtk_list_box_set_selection_mode(list_box, c.GTK_SELECTION_SINGLE);
    c.gtk_widget_set_focusable(asWidget(list_box), 0);
    c.gtk_widget_set_can_focus(asWidget(list_box), 0);

    c.gtk_scrolled_window_set_child(scrolled, asWidget(list_box));
    c.gtk_box_append(container, asWidget(scrolled));

    self.* = .{
        .container = container,
        .scrolled = scrolled,
        .list_box = list_box,
        .tab_manager = tab_manager,
        .alloc = alloc,
    };

    // Connect row-selected signal
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(list_box)),
        "row-selected",
        @as(c.GCallback, @ptrCast(&onRowSelected)),
        @ptrCast(self),
        null,
        0,
    );

    // Build initial rows
    self.rebuild();

    return self;
}

pub fn deinit(self: *Sidebar) void {
    self.alloc.destroy(self);
}

/// Get the sidebar's top-level widget for embedding in a container.
pub fn widget(self: *Sidebar) *c.GtkWidget {
    return asWidget(self.container);
}

/// Set the workspace selection callback.
pub fn setSelectCallback(self: *Sidebar, cb: SelectCallback, userdata: ?*anyopaque) void {
    self.on_select = cb;
    self.on_select_userdata = userdata;
}

/// Rebuild the sidebar list from the tab manager's workspace list.
/// Call this after workspace create/close/reorder/pin operations.
/// Pinned workspaces are sorted to the top.
pub fn rebuild(self: *Sidebar) void {
    // Remove all existing rows
    while (true) {
        const row = c.gtk_list_box_get_row_at_index(self.list_box, 0);
        if (row == null) break;
        c.gtk_list_box_remove(self.list_box, asWidget(row));
    }

    // Two-pass: pinned workspaces first, then non-pinned
    for (self.tab_manager.workspaces.items, 0..) |ws, i| {
        if (ws.pinned) {
            appendWorkspaceRow(self.list_box, ws, i);
        }
    }
    for (self.tab_manager.workspaces.items, 0..) |ws, i| {
        if (!ws.pinned) {
            appendWorkspaceRow(self.list_box, ws, i);
        }
    }

    // Select the current workspace's row
    self.syncSelection();
}

/// Update the selection highlight to match the tab manager's selected workspace.
pub fn syncSelection(self: *Sidebar) void {
    self.updating = true;
    defer self.updating = false;

    if (self.tab_manager.selected_index) |target_idx| {
        // Find the visual row that holds this workspace index
        const row = self.findRowByWorkspaceIndex(target_idx);
        c.gtk_list_box_select_row(self.list_box, row);
    } else {
        c.gtk_list_box_select_row(self.list_box, null);
    }
}

/// Update a single workspace row's content (e.g., after rename or metadata change).
pub fn updateRow(self: *Sidebar, index: usize) void {
    if (index >= self.tab_manager.workspaces.items.len) return;

    const ws = self.tab_manager.workspaces.items[index];

    // Find the visual row that corresponds to this workspace index
    const row = self.findRowByWorkspaceIndex(index);
    if (row == null) return;

    // Replace the row's child with updated content
    const content = createRowContentBox(ws);
    c.gtk_list_box_row_set_child(row, asWidget(content));

    // Force the row to recalculate its size after content change
    c.gtk_widget_queue_resize(asWidget(row));
}

/// Find a GtkListBoxRow by its stored workspace index.
fn findRowByWorkspaceIndex(self: *Sidebar, target: usize) ?*c.GtkListBoxRow {
    var visual_idx: c.gint = 0;
    while (true) {
        const row = c.gtk_list_box_get_row_at_index(self.list_box, visual_idx);
        if (row == null) return null;
        const stored = getRowWorkspaceIndex(row);
        if (stored == target) return row;
        visual_idx += 1;
    }
}

// ------------------------------------------------------------------
// Row creation
// ------------------------------------------------------------------

/// Create a workspace row and append it to the list box, storing the real index.
fn appendWorkspaceRow(list_box: *c.GtkListBox, ws: *const Workspace, data_index: usize) void {
    const row: *c.GtkListBoxRow = @ptrCast(@alignCast(c.gtk_list_box_row_new()));
    const content = createRowContentBox(ws);
    c.gtk_list_box_row_set_child(row, asWidget(content));

    // Store the real workspace index on the row
    c.g_object_set_data(
        @as([*c]c.GObject, @ptrCast(row)),
        ws_index_key,
        @ptrFromInt(data_index),
    );

    c.gtk_list_box_append(list_box, asWidget(row));
}

/// Read the workspace index stored on a row.
fn getRowWorkspaceIndex(row: ?*c.GtkListBoxRow) usize {
    if (row == null) return 0;
    const ptr = c.g_object_get_data(
        @as([*c]c.GObject, @ptrCast(row.?)),
        ws_index_key,
    );
    return @intFromPtr(ptr);
}

fn createRowContentBox(ws: *const Workspace) *c.GtkBox {
    // Each row is a vertical box with:
    // - Title label (with pin indicator if pinned)
    // - Subtitle label (git branch + dirty, or pane count)
    // - Status entries (if any)
    // - Progress bar (if active)
    // - Last log entry (if any)
    const vbox: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2));
    c.gtk_widget_set_margin_start(asWidget(vbox), 12);
    c.gtk_widget_set_margin_end(asWidget(vbox), 12);
    c.gtk_widget_set_margin_top(asWidget(vbox), 6);
    c.gtk_widget_set_margin_bottom(asWidget(vbox), 6);

    // Title - with pin indicator if pinned
    const title = ws.getTitle();
    var title_z: [261]u8 = undefined;
    var title_pos: usize = 0;

    if (ws.pinned) {
        // Prefix with pin emoji
        const pin = "\xf0\x9f\x93\x8c "; // 📌 in UTF-8
        @memcpy(title_z[0..pin.len], pin);
        title_pos = pin.len;
    }

    const title_len = @min(title.len, title_z.len - title_pos - 1);
    @memcpy(title_z[title_pos..][0..title_len], title[0..title_len]);
    title_pos += title_len;
    title_z[title_pos] = 0;

    const title_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new(&title_z)));
    c.gtk_label_set_xalign(title_label, 0.0);
    c.gtk_label_set_ellipsize(title_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_set_hexpand(asWidget(title_label), 1);
    c.gtk_box_append(vbox, asWidget(title_label));

    // Subtitle: git branch (with dirty indicator) or pane count
    var subtitle_buf: [256]u8 = undefined;
    const pane_count = ws.paneCount();
    const subtitle_slice = if (ws.getGitBranch()) |branch| blk: {
        if (ws.git_dirty) {
            break :blk std.fmt.bufPrint(&subtitle_buf, "{s} *", .{branch}) catch "...";
        } else {
            break :blk std.fmt.bufPrint(&subtitle_buf, "{s}", .{branch}) catch "...";
        }
    } else std.fmt.bufPrint(&subtitle_buf, "{d} pane{s}", .{
        pane_count,
        @as([]const u8, if (pane_count != 1) "s" else ""),
    }) catch "...";

    appendDimLabel(vbox, subtitle_slice);

    // Status entries row (if any)
    if (ws.status_count > 0) {
        var status_text_buf: [512]u8 = undefined;
        var status_pos: usize = 0;
        var iter = ws.statusIterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) {
                if (status_pos + 3 <= status_text_buf.len) {
                    @memcpy(status_text_buf[status_pos..][0..3], " | ");
                    status_pos += 3;
                }
            }
            first = false;
            // "key: value"
            const needed = entry.key.len + 2 + entry.value.len;
            if (status_pos + needed <= status_text_buf.len) {
                @memcpy(status_text_buf[status_pos..][0..entry.key.len], entry.key);
                status_pos += entry.key.len;
                @memcpy(status_text_buf[status_pos..][0..2], ": ");
                status_pos += 2;
                @memcpy(status_text_buf[status_pos..][0..entry.value.len], entry.value);
                status_pos += entry.value.len;
            }
        }
        if (status_pos > 0) {
            appendDimLabel(vbox, status_text_buf[0..status_pos]);
        }
    }

    // Progress bar (if active)
    if (ws.progress > 0.0) {
        const maybe_widget = c.gtk_progress_bar_new();
        if (maybe_widget) |pw| {
            const progress_bar: *c.GtkProgressBar = @ptrCast(@alignCast(pw));
            const fraction: f64 = @floatCast(ws.progress);
            c.gtk_progress_bar_set_fraction(progress_bar, fraction);
            if (ws.getProgressLabel()) |label| {
                var label_z: [129]u8 = undefined;
                const label_len = @min(label.len, 128);
                @memcpy(label_z[0..label_len], label[0..label_len]);
                label_z[label_len] = 0;
                c.gtk_progress_bar_set_text(progress_bar, &label_z);
                c.gtk_progress_bar_set_show_text(progress_bar, 1);
            }
            c.gtk_widget_set_hexpand(asWidget(progress_bar), 1);
            c.gtk_widget_set_size_request(asWidget(progress_bar), -1, 10);
            c.gtk_box_append(vbox, asWidget(progress_bar));
        }
    }

    // Last log entry (if any)
    if (ws.lastLogEntry()) |entry| {
        var log_buf: [256]u8 = undefined;
        const log_slice = std.fmt.bufPrint(&log_buf, "> {s}", .{entry}) catch "...";
        appendDimLabel(vbox, log_slice);
    }

    // Wrap in hbox with color accent bar if workspace has a color
    if (ws.getColor()) |color_name| {
        const hbox: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0));

        // Create a narrow accent bar (4px wide, full height)
        const accent: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0));
        c.gtk_widget_set_size_request(asWidget(accent), 4, -1);

        // Apply the CSS class "ws-accent-<color>"
        var css_class_buf: [48]u8 = undefined;
        const css_class = std.fmt.bufPrint(&css_class_buf, "ws-accent-{s}", .{color_name}) catch "ws-accent-red";
        // Null-terminate for C
        var css_z: [49]u8 = undefined;
        const css_len = @min(css_class.len, css_z.len - 1);
        @memcpy(css_z[0..css_len], css_class[0..css_len]);
        css_z[css_len] = 0;
        c.gtk_widget_add_css_class(asWidget(accent), &css_z);

        c.gtk_box_append(hbox, asWidget(accent));
        c.gtk_widget_set_hexpand(asWidget(vbox), 1);
        c.gtk_box_append(hbox, asWidget(vbox));

        return hbox;
    }

    return vbox;
}

/// Helper to append a dim (secondary) label to a vbox.
fn appendDimLabel(vbox: *c.GtkBox, text: []const u8) void {
    var z_buf: [513]u8 = undefined;
    const len = @min(text.len, z_buf.len - 1);
    @memcpy(z_buf[0..len], text[0..len]);
    z_buf[len] = 0;

    const label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new(&z_buf)));
    c.gtk_label_set_xalign(label, 0.0);
    c.gtk_label_set_ellipsize(label, c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_add_css_class(asWidget(label), "dim-label");
    c.gtk_box_append(vbox, asWidget(label));
}

// ------------------------------------------------------------------
// Signal handlers
// ------------------------------------------------------------------

fn onRowSelected(
    _: *c.GtkListBox,
    row: ?*c.GtkListBoxRow,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *Sidebar = @ptrCast(@alignCast(userdata));

    // Ignore programmatic selection updates
    if (self.updating) return;

    if (row) |r| {
        // Read the real workspace index stored on this row
        const index = getRowWorkspaceIndex(r);
        if (self.on_select) |cb| {
            cb(index, self.on_select_userdata);
        }
    }
}
