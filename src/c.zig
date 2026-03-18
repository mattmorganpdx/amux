// C imports for GTK4 and Ghostty.
// This file provides a single import point for all C interop.
//
// Usage: const c = @import("c.zig");
//        c.gtk_window_new(...)
//        c.ghostty_init(...)

const raw = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("ghostty.h");
    @cInclude("libnotify/notify.h");
});

// Re-export all C declarations so callers use `c.symbol_name`.
pub const GtkApplication = raw.GtkApplication;
pub const GtkApplicationWindow = raw.GtkApplicationWindow;
pub const GtkWindow = raw.GtkWindow;
pub const GtkWidget = raw.GtkWidget;
pub const GtkGLArea = raw.GtkGLArea;
pub const GtkEventControllerKey = raw.GtkEventControllerKey;
pub const GtkEventControllerScroll = raw.GtkEventControllerScroll;
pub const GtkEventControllerMotion = raw.GtkEventControllerMotion;
pub const GtkGestureClick = raw.GtkGestureClick;
pub const GApplication = raw.GApplication;
pub const GdkGLContext = raw.GdkGLContext;
pub const GdkModifierType = raw.GdkModifierType;

pub const gpointer = raw.gpointer;
pub const gboolean = raw.gboolean;
pub const gint = raw.gint;
pub const guint = raw.guint;
pub const gdouble = raw.gdouble;
pub const GCallback = raw.GCallback;

// GTK functions
pub const gtk_application_new = raw.gtk_application_new;
pub const gtk_application_window_new = raw.gtk_application_window_new;
pub const gtk_window_set_title = raw.gtk_window_set_title;
pub const gtk_window_set_default_size = raw.gtk_window_set_default_size;
pub const gtk_window_set_child = raw.gtk_window_set_child;
pub const gtk_window_present = raw.gtk_window_present;
pub const gtk_window_destroy = raw.gtk_window_destroy;
pub const gtk_box_new = raw.gtk_box_new;
pub const gtk_box_append = raw.gtk_box_append;
pub const gtk_box_remove = raw.gtk_box_remove;
pub const gtk_paned_new = raw.gtk_paned_new;
pub const gtk_paned_set_start_child = raw.gtk_paned_set_start_child;
pub const gtk_paned_set_end_child = raw.gtk_paned_set_end_child;
pub const gtk_paned_set_position = raw.gtk_paned_set_position;
pub const gtk_paned_set_shrink_start_child = raw.gtk_paned_set_shrink_start_child;
pub const gtk_paned_set_shrink_end_child = raw.gtk_paned_set_shrink_end_child;
pub const gtk_paned_set_resize_start_child = raw.gtk_paned_set_resize_start_child;
pub const gtk_paned_set_resize_end_child = raw.gtk_paned_set_resize_end_child;
pub const gtk_stack_new = raw.gtk_stack_new;
pub const gtk_stack_add_named = raw.gtk_stack_add_named;
pub const gtk_stack_remove = raw.gtk_stack_remove;
pub const gtk_stack_set_visible_child_name = raw.gtk_stack_set_visible_child_name;
pub const gtk_stack_set_transition_type = raw.gtk_stack_set_transition_type;
pub const GTK_STACK_TRANSITION_TYPE_NONE = raw.GTK_STACK_TRANSITION_TYPE_NONE;
pub const gtk_label_new = raw.gtk_label_new;
pub const GtkButton = raw.GtkButton;
pub const gtk_button_new_with_label = raw.gtk_button_new_with_label;
pub const gtk_widget_set_size_request = raw.gtk_widget_set_size_request;
pub const gtk_widget_set_visible = raw.gtk_widget_set_visible;
pub const gtk_widget_get_parent = raw.gtk_widget_get_parent;
pub const gtk_widget_set_margin_start = raw.gtk_widget_set_margin_start;
pub const gtk_widget_set_margin_end = raw.gtk_widget_set_margin_end;
pub const gtk_widget_set_margin_top = raw.gtk_widget_set_margin_top;
pub const gtk_widget_set_margin_bottom = raw.gtk_widget_set_margin_bottom;
pub const gtk_widget_add_css_class = raw.gtk_widget_add_css_class;
pub const gtk_widget_remove_css_class = raw.gtk_widget_remove_css_class;
pub const GTK_ORIENTATION_HORIZONTAL = raw.GTK_ORIENTATION_HORIZONTAL;
pub const GTK_ORIENTATION_VERTICAL = raw.GTK_ORIENTATION_VERTICAL;
pub const GtkBox = raw.GtkBox;
pub const GtkPaned = raw.GtkPaned;
pub const GtkStack = raw.GtkStack;

// Sidebar-related widgets
pub const GtkListBox = raw.GtkListBox;
pub const GtkListBoxRow = raw.GtkListBoxRow;
pub const GtkScrolledWindow = raw.GtkScrolledWindow;
pub const GtkSeparator = raw.GtkSeparator;
pub const GtkLabel = raw.GtkLabel;
pub const gtk_list_box_new = raw.gtk_list_box_new;
pub const gtk_list_box_append = raw.gtk_list_box_append;
pub const gtk_list_box_remove = raw.gtk_list_box_remove;
pub const gtk_list_box_row_new = raw.gtk_list_box_row_new;
pub const gtk_list_box_row_set_child = raw.gtk_list_box_row_set_child;
pub const gtk_list_box_select_row = raw.gtk_list_box_select_row;
pub const gtk_list_box_get_selected_row = raw.gtk_list_box_get_selected_row;
pub const gtk_list_box_get_row_at_index = raw.gtk_list_box_get_row_at_index;
pub const gtk_list_box_row_get_index = raw.gtk_list_box_row_get_index;
pub const gtk_scrolled_window_new = raw.gtk_scrolled_window_new;
pub const gtk_scrolled_window_set_child = raw.gtk_scrolled_window_set_child;
pub const gtk_scrolled_window_set_policy = raw.gtk_scrolled_window_set_policy;
pub const gtk_scrolled_window_get_vadjustment = raw.gtk_scrolled_window_get_vadjustment;

// GtkAdjustment
pub const gtk_adjustment_get_value = raw.gtk_adjustment_get_value;
pub const gtk_adjustment_set_value = raw.gtk_adjustment_set_value;
pub const gtk_adjustment_get_page_size = raw.gtk_adjustment_get_page_size;

// Graphene (bundled with GTK4)
pub const graphene_point_t = raw.graphene_point_t;

// Widget coordinate transform
pub const gtk_widget_compute_point = raw.gtk_widget_compute_point;
pub const gtk_separator_new = raw.gtk_separator_new;
pub const gtk_label_set_text = raw.gtk_label_set_text;
pub const gtk_label_set_xalign = raw.gtk_label_set_xalign;
pub const gtk_label_set_ellipsize = raw.gtk_label_set_ellipsize;
pub const GTK_POLICY_NEVER = raw.GTK_POLICY_NEVER;
pub const GTK_POLICY_AUTOMATIC = raw.GTK_POLICY_AUTOMATIC;
pub const GTK_SELECTION_SINGLE = raw.GTK_SELECTION_SINGLE;
pub const gtk_list_box_set_selection_mode = raw.gtk_list_box_set_selection_mode;

// GtkProgressBar
pub const GtkProgressBar = raw.GtkProgressBar;
pub const gtk_progress_bar_new = raw.gtk_progress_bar_new;
pub const gtk_progress_bar_set_fraction = raw.gtk_progress_bar_set_fraction;
pub const gtk_progress_bar_set_text = raw.gtk_progress_bar_set_text;
pub const gtk_progress_bar_set_show_text = raw.gtk_progress_bar_set_show_text;

// Pango
pub const PANGO_ELLIPSIZE_END = raw.PANGO_ELLIPSIZE_END;

// Event controller propagation
pub const gtk_event_controller_set_propagation_phase = raw.gtk_event_controller_set_propagation_phase;
pub const GTK_PHASE_CAPTURE = raw.GTK_PHASE_CAPTURE;
pub const GTK_PHASE_BUBBLE = raw.GTK_PHASE_BUBBLE;
pub const GTK_PHASE_TARGET = raw.GTK_PHASE_TARGET;

// GDK key symbols
pub const GDK_KEY_T = raw.GDK_KEY_T;
pub const GDK_KEY_t = raw.GDK_KEY_t;
pub const GDK_KEY_W = raw.GDK_KEY_W;
pub const GDK_KEY_w = raw.GDK_KEY_w;
pub const GDK_KEY_D = raw.GDK_KEY_D;
pub const GDK_KEY_d = raw.GDK_KEY_d;
pub const GDK_KEY_E = raw.GDK_KEY_E;
pub const GDK_KEY_e = raw.GDK_KEY_e;
pub const GDK_KEY_B = raw.GDK_KEY_B;
pub const GDK_KEY_b = raw.GDK_KEY_b;
pub const GDK_KEY_Left = raw.GDK_KEY_Left;
pub const GDK_KEY_Right = raw.GDK_KEY_Right;
pub const GDK_KEY_Up = raw.GDK_KEY_Up;
pub const GDK_KEY_Down = raw.GDK_KEY_Down;
pub const GDK_KEY_bracketleft = raw.GDK_KEY_bracketleft;
pub const GDK_KEY_bracketright = raw.GDK_KEY_bracketright;
pub const GDK_KEY_P = raw.GDK_KEY_P;
pub const GDK_KEY_p = raw.GDK_KEY_p;
pub const GDK_KEY_F = raw.GDK_KEY_F;
pub const GDK_KEY_f = raw.GDK_KEY_f;
pub const GDK_KEY_Q = raw.GDK_KEY_Q;
pub const GDK_KEY_q = raw.GDK_KEY_q;
pub const GDK_KEY_grave = raw.GDK_KEY_grave;
pub const GDK_KEY_Escape = raw.GDK_KEY_Escape;
pub const GDK_KEY_Return = raw.GDK_KEY_Return;
pub const gtk_widget_set_hexpand = raw.gtk_widget_set_hexpand;
pub const gtk_widget_set_vexpand = raw.gtk_widget_set_vexpand;
pub const gtk_widget_queue_resize = raw.gtk_widget_queue_resize;
pub const gtk_widget_set_focusable = raw.gtk_widget_set_focusable;
pub const gtk_widget_set_can_focus = raw.gtk_widget_set_can_focus;
pub const gtk_widget_grab_focus = raw.gtk_widget_grab_focus;
pub const gtk_widget_get_scale_factor = raw.gtk_widget_get_scale_factor;
pub const gtk_widget_get_width = raw.gtk_widget_get_width;
pub const gtk_widget_get_height = raw.gtk_widget_get_height;
pub const gtk_widget_add_controller = raw.gtk_widget_add_controller;
pub const gtk_gl_area_new = raw.gtk_gl_area_new;
pub const gtk_gl_area_set_required_version = raw.gtk_gl_area_set_required_version;
pub const gtk_gl_area_set_has_depth_buffer = raw.gtk_gl_area_set_has_depth_buffer;
pub const gtk_gl_area_set_has_stencil_buffer = raw.gtk_gl_area_set_has_stencil_buffer;
pub const gtk_gl_area_set_auto_render = raw.gtk_gl_area_set_auto_render;
pub const gtk_gl_area_make_current = raw.gtk_gl_area_make_current;
pub const gtk_gl_area_get_error = raw.gtk_gl_area_get_error;
pub const gtk_gl_area_queue_render = raw.gtk_gl_area_queue_render;
pub const gtk_event_controller_key_new = raw.gtk_event_controller_key_new;
pub const gtk_event_controller_scroll_new = raw.gtk_event_controller_scroll_new;
pub const gtk_event_controller_motion_new = raw.gtk_event_controller_motion_new;
pub const gtk_gesture_click_new = raw.gtk_gesture_click_new;
pub const gtk_gesture_single_set_button = raw.gtk_gesture_single_set_button;
pub const gtk_gesture_single_get_current_button = raw.gtk_gesture_single_get_current_button;

// GtkCssProvider (theming)
pub const GtkCssProvider = raw.GtkCssProvider;
pub const gtk_css_provider_new = raw.gtk_css_provider_new;
pub const gtk_css_provider_load_from_string = raw.gtk_css_provider_load_from_string;
pub const gtk_style_context_add_provider_for_display = raw.gtk_style_context_add_provider_for_display;
pub const GTK_STYLE_PROVIDER_PRIORITY_APPLICATION = raw.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION;

// GtkOverlay
pub const GtkOverlay = raw.GtkOverlay;
pub const gtk_overlay_new = raw.gtk_overlay_new;
pub const gtk_overlay_set_child = raw.gtk_overlay_set_child;
pub const gtk_overlay_add_overlay = raw.gtk_overlay_add_overlay;

// GtkSearchEntry
pub const GtkSearchEntry = raw.GtkSearchEntry;
pub const gtk_search_entry_new = raw.gtk_search_entry_new;
pub const gtk_search_entry_get_text = raw.gtk_search_entry_get_text;

// GtkEditable (interface for entries/search entries)
pub const gtk_editable_get_text = raw.gtk_editable_get_text;
pub const gtk_editable_set_text = raw.gtk_editable_set_text;

// Widget alignment
pub const gtk_widget_set_halign = raw.gtk_widget_set_halign;
pub const gtk_widget_set_valign = raw.gtk_widget_set_valign;
pub const GTK_ALIGN_START = raw.GTK_ALIGN_START;
pub const GTK_ALIGN_END = raw.GTK_ALIGN_END;
pub const GTK_ALIGN_CENTER = raw.GTK_ALIGN_CENTER;
pub const GTK_ALIGN_FILL = raw.GTK_ALIGN_FILL;

// GType checking
pub const GTypeInstance = raw.GTypeInstance;
pub const g_type_is_a = raw.g_type_is_a;
pub const gtk_paned_get_type = raw.gtk_paned_get_type;
pub const gtk_paned_get_start_child = raw.gtk_paned_get_start_child;
pub const gtk_paned_get_end_child = raw.gtk_paned_get_end_child;
pub const gtk_box_get_type = raw.gtk_box_get_type;

// Widget tree traversal
pub const gtk_widget_get_first_child = raw.gtk_widget_get_first_child;
pub const gtk_widget_get_next_sibling = raw.gtk_widget_get_next_sibling;

// GLib/GObject functions
pub const g_application_run = raw.g_application_run;
pub const g_object_ref = raw.g_object_ref;
pub const g_object_unref = raw.g_object_unref;
pub const g_object_set_data = raw.g_object_set_data;
pub const g_object_get_data = raw.g_object_get_data;
pub const g_signal_connect_data = raw.g_signal_connect_data;
pub const g_idle_add = raw.g_idle_add;
pub const g_timeout_add = raw.g_timeout_add;
pub const g_timeout_add_seconds = raw.g_timeout_add_seconds;
pub const g_error_free = raw.g_error_free;
pub const g_free = raw.g_free;
pub const GAsyncResult = raw.GAsyncResult;
pub const GObject = raw.GObject;
pub const GError = raw.GError;

// GDK clipboard
pub const gdk_display_get_default = raw.gdk_display_get_default;
pub const gdk_display_get_clipboard = raw.gdk_display_get_clipboard;
pub const gdk_display_get_primary_clipboard = raw.gdk_display_get_primary_clipboard;
pub const gdk_clipboard_set_text = raw.gdk_clipboard_set_text;
pub const gdk_clipboard_read_text_async = raw.gdk_clipboard_read_text_async;
pub const gdk_clipboard_read_text_finish = raw.gdk_clipboard_read_text_finish;

// GTK constants
pub const G_APPLICATION_DEFAULT_FLAGS = raw.G_APPLICATION_DEFAULT_FLAGS;
pub const G_SOURCE_REMOVE = raw.G_SOURCE_REMOVE;
pub const GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES = raw.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES;
pub const GTK_EVENT_CONTROLLER_SCROLL_DISCRETE = raw.GTK_EVENT_CONTROLLER_SCROLL_DISCRETE;
pub const GDK_SHIFT_MASK = raw.GDK_SHIFT_MASK;
pub const GDK_CONTROL_MASK = raw.GDK_CONTROL_MASK;
pub const GDK_ALT_MASK = raw.GDK_ALT_MASK;
pub const GDK_SUPER_MASK = raw.GDK_SUPER_MASK;

// Ghostty types and functions
pub const ghostty_app_t = raw.ghostty_app_t;
pub const ghostty_config_t = raw.ghostty_config_t;
pub const ghostty_surface_t = raw.ghostty_surface_t;
pub const ghostty_runtime_config_s = raw.ghostty_runtime_config_s;
pub const ghostty_surface_config_s = raw.ghostty_surface_config_s;
pub const ghostty_input_key_s = raw.ghostty_input_key_s;
pub const ghostty_clipboard_e = raw.ghostty_clipboard_e;
pub const ghostty_clipboard_content_s = raw.ghostty_clipboard_content_s;
pub const ghostty_clipboard_request_e = raw.ghostty_clipboard_request_e;
pub const ghostty_input_mods_t = raw.ghostty_input_mods_e;
pub const ghostty_input_mouse_button_e = raw.ghostty_input_mouse_button_e;
pub const ghostty_action_split_direction_e = raw.ghostty_action_split_direction_e;
pub const ghostty_target_s = raw.ghostty_target_s;
pub const ghostty_action_s = raw.ghostty_action_s;

pub const ghostty_init = raw.ghostty_init;
pub const ghostty_config_new = raw.ghostty_config_new;
pub const ghostty_config_free = raw.ghostty_config_free;
pub const ghostty_config_load_default_files = raw.ghostty_config_load_default_files;
pub const ghostty_config_load_recursive_files = raw.ghostty_config_load_recursive_files;
pub const ghostty_config_finalize = raw.ghostty_config_finalize;
pub const ghostty_app_new = raw.ghostty_app_new;
pub const ghostty_app_free = raw.ghostty_app_free;
pub const ghostty_app_tick = raw.ghostty_app_tick;
pub const ghostty_surface_config_new = raw.ghostty_surface_config_new;
pub const ghostty_surface_new = raw.ghostty_surface_new;
pub const ghostty_surface_free = raw.ghostty_surface_free;
pub const ghostty_surface_draw = raw.ghostty_surface_draw;
pub const ghostty_surface_set_size = raw.ghostty_surface_set_size;
pub const ghostty_surface_set_content_scale = raw.ghostty_surface_set_content_scale;
pub const ghostty_surface_key = raw.ghostty_surface_key;
pub const ghostty_surface_mouse_button = raw.ghostty_surface_mouse_button;
pub const ghostty_surface_mouse_pos = raw.ghostty_surface_mouse_pos;
pub const ghostty_surface_mouse_scroll = raw.ghostty_surface_mouse_scroll;
pub const ghostty_surface_text = raw.ghostty_surface_text;

pub const ghostty_surface_userdata = raw.ghostty_surface_userdata;
pub const ghostty_surface_binding_action = raw.ghostty_surface_binding_action;
pub const ghostty_surface_complete_clipboard_request = raw.ghostty_surface_complete_clipboard_request;

// Text reading types and functions
pub const ghostty_text_s = raw.ghostty_text_s;
pub const ghostty_selection_s = raw.ghostty_selection_s;
pub const ghostty_point_s = raw.ghostty_point_s;
pub const ghostty_point_tag_e = raw.ghostty_point_tag_e;
pub const ghostty_point_coord_e = raw.ghostty_point_coord_e;
pub const ghostty_surface_read_text = raw.ghostty_surface_read_text;
pub const ghostty_surface_free_text = raw.ghostty_surface_free_text;
pub const ghostty_surface_has_selection = raw.ghostty_surface_has_selection;
pub const ghostty_surface_read_selection = raw.ghostty_surface_read_selection;

// Environment variable type
pub const ghostty_env_var_s = raw.ghostty_env_var_s;

// Ghostty constants
pub const GHOSTTY_SUCCESS = raw.GHOSTTY_SUCCESS;
pub const GHOSTTY_PLATFORM_LINUX = raw.GHOSTTY_PLATFORM_LINUX;
pub const GHOSTTY_ACTION_RENDER = raw.GHOSTTY_ACTION_RENDER;
pub const GHOSTTY_ACTION_SET_TITLE = raw.GHOSTTY_ACTION_SET_TITLE;
pub const GHOSTTY_ACTION_NEW_SPLIT = raw.GHOSTTY_ACTION_NEW_SPLIT;
pub const GHOSTTY_ACTION_CLOSE_WINDOW = raw.GHOSTTY_ACTION_CLOSE_WINDOW;
pub const GHOSTTY_ACTION_CELL_SIZE = raw.GHOSTTY_ACTION_CELL_SIZE;
pub const GHOSTTY_ACTION_PWD = raw.GHOSTTY_ACTION_PWD;
pub const GHOSTTY_ACTION_START_SEARCH = raw.GHOSTTY_ACTION_START_SEARCH;
pub const GHOSTTY_ACTION_END_SEARCH = raw.GHOSTTY_ACTION_END_SEARCH;
pub const GHOSTTY_ACTION_SEARCH_TOTAL = raw.GHOSTTY_ACTION_SEARCH_TOTAL;
pub const GHOSTTY_ACTION_SEARCH_SELECTED = raw.GHOSTTY_ACTION_SEARCH_SELECTED;
pub const GHOSTTY_TARGET_SURFACE = raw.GHOSTTY_TARGET_SURFACE;
pub const GHOSTTY_SPLIT_DIRECTION_RIGHT = raw.GHOSTTY_SPLIT_DIRECTION_RIGHT;
pub const GHOSTTY_SPLIT_DIRECTION_DOWN = raw.GHOSTTY_SPLIT_DIRECTION_DOWN;
pub const GHOSTTY_SPLIT_DIRECTION_LEFT = raw.GHOSTTY_SPLIT_DIRECTION_LEFT;
pub const GHOSTTY_SPLIT_DIRECTION_UP = raw.GHOSTTY_SPLIT_DIRECTION_UP;
pub const GHOSTTY_CLIPBOARD_STANDARD = raw.GHOSTTY_CLIPBOARD_STANDARD;
pub const GHOSTTY_CLIPBOARD_SELECTION = raw.GHOSTTY_CLIPBOARD_SELECTION;
pub const GHOSTTY_MODS_NONE = raw.GHOSTTY_MODS_NONE;
pub const GHOSTTY_MODS_SHIFT = raw.GHOSTTY_MODS_SHIFT;
pub const GHOSTTY_MODS_CTRL = raw.GHOSTTY_MODS_CTRL;
pub const GHOSTTY_MODS_ALT = raw.GHOSTTY_MODS_ALT;
pub const GHOSTTY_MODS_SUPER = raw.GHOSTTY_MODS_SUPER;
pub const GHOSTTY_MOUSE_LEFT = raw.GHOSTTY_MOUSE_LEFT;
pub const GHOSTTY_MOUSE_MIDDLE = raw.GHOSTTY_MOUSE_MIDDLE;
pub const GHOSTTY_MOUSE_RIGHT = raw.GHOSTTY_MOUSE_RIGHT;
pub const GHOSTTY_MOUSE_FOUR = raw.GHOSTTY_MOUSE_FOUR;
pub const GHOSTTY_MOUSE_FIVE = raw.GHOSTTY_MOUSE_FIVE;
pub const GHOSTTY_MOUSE_UNKNOWN = raw.GHOSTTY_MOUSE_UNKNOWN;
pub const GHOSTTY_MOUSE_PRESS = raw.GHOSTTY_MOUSE_PRESS;
pub const GHOSTTY_MOUSE_RELEASE = raw.GHOSTTY_MOUSE_RELEASE;
pub const GHOSTTY_MOUSE_MOMENTUM_NONE = raw.GHOSTTY_MOUSE_MOMENTUM_NONE;
pub const GHOSTTY_ACTION_PRESS = raw.GHOSTTY_ACTION_PRESS;
pub const GHOSTTY_ACTION_RELEASE = raw.GHOSTTY_ACTION_RELEASE;

// Point tag and coord constants
pub const GHOSTTY_POINT_VIEWPORT = raw.GHOSTTY_POINT_VIEWPORT;
pub const GHOSTTY_POINT_SCREEN = raw.GHOSTTY_POINT_SCREEN;
pub const GHOSTTY_POINT_ACTIVE = raw.GHOSTTY_POINT_ACTIVE;
pub const GHOSTTY_POINT_SURFACE = raw.GHOSTTY_POINT_SURFACE;
pub const GHOSTTY_POINT_COORD_EXACT = raw.GHOSTTY_POINT_COORD_EXACT;
pub const GHOSTTY_POINT_COORD_TOP_LEFT = raw.GHOSTTY_POINT_COORD_TOP_LEFT;
pub const GHOSTTY_POINT_COORD_BOTTOM_RIGHT = raw.GHOSTTY_POINT_COORD_BOTTOM_RIGHT;

// GDK frame clock and tick callbacks
pub const GdkFrameClock = raw.GdkFrameClock;
pub const gtk_widget_add_tick_callback = raw.gtk_widget_add_tick_callback;

// GDK key utilities
pub const gdk_keyval_to_unicode = raw.gdk_keyval_to_unicode;
pub const gdk_keyval_to_lower = raw.gdk_keyval_to_lower;

// GtkWindow icon
pub const gtk_window_set_icon_name = raw.gtk_window_set_icon_name;

// GLib file utilities
pub const g_get_user_data_dir = raw.g_get_user_data_dir;
pub const g_mkdir_with_parents = raw.g_mkdir_with_parents;
pub const g_file_test = raw.g_file_test;
pub const G_FILE_TEST_EXISTS = raw.G_FILE_TEST_EXISTS;

// GApplication
pub const g_application_quit = raw.g_application_quit;

// libnotify
pub const notify_init = raw.notify_init;
pub const notify_uninit = raw.notify_uninit;
pub const notify_notification_new = raw.notify_notification_new;
pub const notify_notification_show = raw.notify_notification_show;
