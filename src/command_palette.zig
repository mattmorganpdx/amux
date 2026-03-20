const std = @import("std");
const c = @import("c.zig");
const Window = @import("window.zig");
const PaneTree = @import("pane_tree.zig");

const log = std.log.scoped(.command_palette);

const CommandPalette = @This();

const Allocator = std.mem.Allocator;

/// Helper to cast any GTK widget subtype to *GtkWidget with proper alignment.
inline fn asWidget(ptr: anytype) *c.GtkWidget {
    return @ptrCast(@alignCast(ptr));
}

/// A command palette action.
pub const Action = struct {
    name: []const u8,
    description: []const u8,
    shortcut: []const u8,
    callback: *const fn (*Window) void,
};

/// Registered actions.
const actions = [_]Action{
    .{ .name = "New Workspace", .description = "Create a new workspace", .shortcut = "Ctrl+Shift+T", .callback = &doNewWorkspace },
    .{ .name = "Close Workspace", .description = "Close the current workspace", .shortcut = "Ctrl+Shift+Q", .callback = &doCloseWorkspace },
    .{ .name = "Last Workspace", .description = "Switch to the most recently used workspace", .shortcut = "Ctrl+Shift+`", .callback = &doLastWorkspace },
    .{ .name = "Split Right", .description = "Split the focused pane to the right", .shortcut = "Ctrl+Shift+D", .callback = &doSplitRight },
    .{ .name = "Split Down", .description = "Split the focused pane downward", .shortcut = "Ctrl+Shift+E", .callback = &doSplitDown },
    .{ .name = "Split Left", .description = "Split the focused pane to the left", .shortcut = "", .callback = &doSplitLeft },
    .{ .name = "Split Up", .description = "Split the focused pane upward", .shortcut = "", .callback = &doSplitUp },
    .{ .name = "Close Pane", .description = "Close the focused pane", .shortcut = "Ctrl+Shift+W", .callback = &doClosePane },
    .{ .name = "Next Workspace", .description = "Switch to the next workspace", .shortcut = "Ctrl+Shift+]", .callback = &doNextWorkspace },
    .{ .name = "Previous Workspace", .description = "Switch to the previous workspace", .shortcut = "Ctrl+Shift+[", .callback = &doPreviousWorkspace },
    .{ .name = "Toggle Sidebar", .description = "Show or hide the sidebar", .shortcut = "Ctrl+Shift+B", .callback = &doToggleSidebar },
    .{ .name = "Navigate Left", .description = "Move focus to the pane on the left", .shortcut = "Ctrl+Shift+Left", .callback = &doNavLeft },
    .{ .name = "Navigate Right", .description = "Move focus to the pane on the right", .shortcut = "Ctrl+Shift+Right", .callback = &doNavRight },
    .{ .name = "Navigate Up", .description = "Move focus to the pane above", .shortcut = "Ctrl+Shift+Up", .callback = &doNavUp },
    .{ .name = "Navigate Down", .description = "Move focus to the pane below", .shortcut = "Ctrl+Shift+Down", .callback = &doNavDown },
    .{ .name = "Terminal Search", .description = "Find text in the terminal", .shortcut = "Ctrl+Shift+F", .callback = &doSearch },
    .{ .name = "Show History", .description = "Browse and restore past terminal sessions", .shortcut = "Ctrl+Shift+H", .callback = &doShowHistory },
};

// Action callbacks
fn doNewWorkspace(w: *Window) void {
    w.createWorkspace() catch |err| log.warn("Failed to create workspace: {}", .{err});
}
fn doCloseWorkspace(w: *Window) void {
    w.closeCurrentWorkspace();
}
fn doLastWorkspace(w: *Window) void {
    w.lastWorkspace();
}
fn doSplitRight(w: *Window) void {
    w.splitFocused(.right) catch |err| log.warn("Failed to split right: {}", .{err});
}
fn doSplitDown(w: *Window) void {
    w.splitFocused(.down) catch |err| log.warn("Failed to split down: {}", .{err});
}
fn doSplitLeft(w: *Window) void {
    w.splitFocused(.left) catch |err| log.warn("Failed to split left: {}", .{err});
}
fn doSplitUp(w: *Window) void {
    w.splitFocused(.up) catch |err| log.warn("Failed to split up: {}", .{err});
}
fn doClosePane(w: *Window) void {
    w.closeFocused() catch |err| log.warn("Failed to close pane: {}", .{err});
}
fn doNextWorkspace(w: *Window) void {
    w.nextWorkspace();
}
fn doPreviousWorkspace(w: *Window) void {
    w.previousWorkspace();
}
fn doToggleSidebar(w: *Window) void {
    w.toggleSidebar();
}
fn doNavLeft(w: *Window) void {
    w.navigateFocus(.left);
}
fn doNavRight(w: *Window) void {
    w.navigateFocus(.right);
}
fn doNavUp(w: *Window) void {
    w.navigateFocus(.up);
}
fn doNavDown(w: *Window) void {
    w.navigateFocus(.down);
}
fn doSearch(w: *Window) void {
    w.showSearch();
}
fn doShowHistory(w: *Window) void {
    w.toggleHistory();
}

/// The outer container for the palette overlay widget.
container: *c.GtkBox,

/// The search entry.
search_entry: *c.GtkSearchEntry,

/// The list box showing filtered results.
list_box: *c.GtkListBox,

/// The scrolled window containing the list box.
scrolled_window: *c.GtkScrolledWindow,

/// Whether the palette is currently visible.
visible: bool = false,

/// Reference to the window.
window: *Window,

/// Allocator.
alloc: Allocator,

pub fn create(alloc: Allocator, window: *Window) !*CommandPalette {
    const self = try alloc.create(CommandPalette);

    // Outer container: a vertical box with the command-palette CSS class
    const container: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4));
    c.gtk_widget_add_css_class(asWidget(container), "command-palette");
    c.gtk_widget_set_size_request(asWidget(container), 400, -1);

    // Position at the top center of the overlay
    c.gtk_widget_set_halign(asWidget(container), c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_valign(asWidget(container), c.GTK_ALIGN_START);

    // Margins from top
    c.gtk_widget_set_margin_top(asWidget(container), 40);

    // Search entry
    const search_entry: *c.GtkSearchEntry = @ptrCast(@alignCast(c.gtk_search_entry_new()));
    c.gtk_box_append(container, asWidget(search_entry));

    // Results list box
    const list_box: *c.GtkListBox = @ptrCast(@alignCast(c.gtk_list_box_new()));
    c.gtk_list_box_set_selection_mode(list_box, c.GTK_SELECTION_SINGLE);

    // Scrolled window for results
    const scrolled: *c.GtkScrolledWindow = @ptrCast(@alignCast(c.gtk_scrolled_window_new()));
    c.gtk_scrolled_window_set_policy(scrolled, c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_size_request(asWidget(scrolled), -1, 300);
    c.gtk_scrolled_window_set_child(scrolled, asWidget(list_box));
    c.gtk_box_append(container, asWidget(scrolled));

    // Start hidden
    c.gtk_widget_set_visible(asWidget(container), 0);

    self.* = .{
        .container = container,
        .search_entry = search_entry,
        .list_box = list_box,
        .scrolled_window = scrolled,
        .window = window,
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

    // Connect row-activated for click execution
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(list_box)),
        "row-activated",
        @as(c.GCallback, @ptrCast(&onRowActivated)),
        @ptrCast(self),
        null,
        0,
    );

    // Connect activate signal on search entry for Enter key execution
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(search_entry)),
        "activate",
        @as(c.GCallback, @ptrCast(&onActivate)),
        @ptrCast(self),
        null,
        0,
    );

    // Connect key-pressed on search entry for Escape and arrow keys
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

    // Populate with all actions initially
    self.populateResults("");

    return self;
}

pub fn deinit(self: *CommandPalette) void {
    self.alloc.destroy(self);
}

/// Get the palette's widget for embedding in the overlay.
pub fn widget(self: *CommandPalette) *c.GtkWidget {
    return asWidget(self.container);
}

/// Show the palette.
pub fn show(self: *CommandPalette) void {
    self.visible = true;
    c.gtk_widget_set_visible(asWidget(self.container), 1);

    // Clear the search entry and populate with all actions
    c.gtk_editable_set_text(@ptrCast(self.search_entry), "");
    self.populateResults("");

    // Focus the search entry
    _ = c.gtk_widget_grab_focus(asWidget(self.search_entry));
}

/// Hide the palette and return focus to the terminal.
pub fn hide(self: *CommandPalette) void {
    self.visible = false;
    c.gtk_widget_set_visible(asWidget(self.container), 0);
    self.window.focusCurrentTerminal();
}

/// Toggle visibility.
pub fn toggle(self: *CommandPalette) void {
    if (self.visible) {
        self.hide();
    } else {
        self.show();
    }
}

/// Execute an action by name (fuzzy match). Used by socket handler.
pub fn executeByName(self: *CommandPalette, name: []const u8) bool {
    // Exact match first
    for (actions) |action| {
        if (std.ascii.eqlIgnoreCase(action.name, name)) {
            action.callback(self.window);
            return true;
        }
    }
    // Fuzzy match: case-insensitive substring
    for (actions) |action| {
        if (containsIgnoreCase(action.name, name) or containsIgnoreCase(action.description, name)) {
            action.callback(self.window);
            return true;
        }
    }
    return false;
}

/// Get the list of all registered actions.
pub fn getActions() []const Action {
    return &actions;
}

// ------------------------------------------------------------------
// Internal
// ------------------------------------------------------------------

/// Scroll the scrolled window so that the given row is visible.
fn scrollRowIntoView(self: *CommandPalette, row: *c.GtkListBoxRow) void {
    const adj = c.gtk_scrolled_window_get_vadjustment(self.scrolled_window) orelse return;

    // Compute the row's position relative to the list box using graphene point transform.
    var row_point = c.graphene_point_t{ .x = 0, .y = 0 };
    var list_point: c.graphene_point_t = undefined;
    if (c.gtk_widget_compute_point(asWidget(row), asWidget(self.list_box), &row_point, &list_point) == 0)
        return;

    const row_y: f64 = @floatCast(list_point.y);
    const row_height: f64 = @floatFromInt(c.gtk_widget_get_height(asWidget(row)));
    const visible_top = c.gtk_adjustment_get_value(adj);
    const page_size = c.gtk_adjustment_get_page_size(adj);
    const visible_bottom = visible_top + page_size;

    // Scroll down if the row extends below the visible area
    if (row_y + row_height > visible_bottom) {
        c.gtk_adjustment_set_value(adj, row_y + row_height - page_size);
    }
    // Scroll up if the row is above the visible area
    else if (row_y < visible_top) {
        c.gtk_adjustment_set_value(adj, row_y);
    }
}

fn populateResults(self: *CommandPalette, query: []const u8) void {
    // Remove all existing rows
    while (true) {
        const row = c.gtk_list_box_get_row_at_index(self.list_box, 0);
        if (row == null) break;
        c.gtk_list_box_remove(self.list_box, asWidget(row));
    }

    // Add matching actions
    var count: usize = 0;
    for (actions) |action| {
        if (query.len == 0 or matchesQuery(action, query)) {
            appendActionRow(self.list_box, action);
            count += 1;
        }
    }

    // Select the first row
    if (count > 0) {
        const first_row = c.gtk_list_box_get_row_at_index(self.list_box, 0);
        c.gtk_list_box_select_row(self.list_box, first_row);
    }
}

fn matchesQuery(action: Action, query: []const u8) bool {
    return containsIgnoreCase(action.name, query) or containsIgnoreCase(action.description, query);
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

fn appendActionRow(list_box: *c.GtkListBox, action: Action) void {
    const row: *c.GtkListBoxRow = @ptrCast(@alignCast(c.gtk_list_box_row_new()));

    // Horizontal box: left side (name + description) and right side (shortcut)
    const hbox: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8));
    c.gtk_widget_set_margin_start(asWidget(hbox), 8);
    c.gtk_widget_set_margin_end(asWidget(hbox), 8);
    c.gtk_widget_set_margin_top(asWidget(hbox), 4);
    c.gtk_widget_set_margin_bottom(asWidget(hbox), 4);

    // Left side: name + description stacked vertically
    const vbox: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2));
    c.gtk_widget_set_hexpand(asWidget(vbox), 1);

    // Name label
    var name_z: [128]u8 = undefined;
    const name_len = @min(action.name.len, name_z.len - 1);
    @memcpy(name_z[0..name_len], action.name[0..name_len]);
    name_z[name_len] = 0;
    const name_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new(&name_z)));
    c.gtk_label_set_xalign(name_label, 0.0);
    c.gtk_box_append(vbox, asWidget(name_label));

    // Description label (dim)
    var desc_z: [256]u8 = undefined;
    const desc_len = @min(action.description.len, desc_z.len - 1);
    @memcpy(desc_z[0..desc_len], action.description[0..desc_len]);
    desc_z[desc_len] = 0;
    const desc_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new(&desc_z)));
    c.gtk_label_set_xalign(desc_label, 0.0);
    c.gtk_widget_add_css_class(asWidget(desc_label), "dim-label");
    c.gtk_box_append(vbox, asWidget(desc_label));

    c.gtk_box_append(hbox, asWidget(vbox));

    // Right side: shortcut label
    if (action.shortcut.len > 0) {
        var shortcut_z: [64]u8 = undefined;
        const sc_len = @min(action.shortcut.len, shortcut_z.len - 1);
        @memcpy(shortcut_z[0..sc_len], action.shortcut[0..sc_len]);
        shortcut_z[sc_len] = 0;
        const shortcut_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new(&shortcut_z)));
        c.gtk_label_set_xalign(shortcut_label, 1.0);
        c.gtk_widget_set_valign(asWidget(shortcut_label), c.GTK_ALIGN_CENTER);
        c.gtk_widget_add_css_class(asWidget(shortcut_label), "dim-label");
        c.gtk_box_append(hbox, asWidget(shortcut_label));
    }

    c.gtk_list_box_row_set_child(row, asWidget(hbox));
    c.gtk_list_box_append(list_box, asWidget(row));

    // Store the action index on the row
    const idx = getActionIndex(action.name);
    c.g_object_set_data(
        @as([*c]c.GObject, @ptrCast(row)),
        "action-idx",
        @ptrFromInt(idx),
    );
}

fn getActionIndex(name: []const u8) usize {
    for (actions, 0..) |a, i| {
        if (std.mem.eql(u8, a.name, name)) return i;
    }
    return 0;
}

fn executeSelectedAction(self: *CommandPalette) void {
    const selected_row = c.gtk_list_box_get_selected_row(self.list_box);
    if (selected_row == null) return;

    const idx = @intFromPtr(c.g_object_get_data(
        @as([*c]c.GObject, @ptrCast(selected_row.?)),
        "action-idx",
    ));

    if (idx < actions.len) {
        self.hide();
        actions[idx].callback(self.window);
    }
}

// ------------------------------------------------------------------
// Signal handlers
// ------------------------------------------------------------------

fn onRowActivated(
    _: *c.GtkListBox,
    row: *c.GtkListBoxRow,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *CommandPalette = @ptrCast(@alignCast(userdata));

    const idx = @intFromPtr(c.g_object_get_data(
        @as([*c]c.GObject, @ptrCast(row)),
        "action-idx",
    ));

    if (idx < actions.len) {
        self.hide();
        actions[idx].callback(self.window);
    }
}

fn onActivate(
    _: *c.GtkSearchEntry,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *CommandPalette = @ptrCast(@alignCast(userdata));
    self.executeSelectedAction();
}

fn onSearchChanged(
    _: *c.GtkSearchEntry,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *CommandPalette = @ptrCast(@alignCast(userdata));
    const text_ptr = c.gtk_editable_get_text(@ptrCast(self.search_entry));
    if (text_ptr == null) return;

    // Read the C string into a Zig slice
    const text = std.mem.span(text_ptr.?);
    self.populateResults(text);
}

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    _: c.GdkModifierType,
    userdata: c.gpointer,
) callconv(.c) c.gboolean {
    const self: *CommandPalette = @ptrCast(@alignCast(userdata));

    if (keyval == c.GDK_KEY_Escape) {
        self.hide();
        return 1;
    }

    // Arrow down: move selection in list box
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

    // Arrow up: move selection in list box
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
