const rows = @import("rows.zig");
const Row = rows.Row;
const Card = rows.Card;

// Panels & UI pages — Dock, Panel, Taskbar, Launcher, Desktop, Desktop
// Widgets. Row lists mirror the C++ paint order in dock_tab_m3 /
// panel_tab_m3 / taskbar_tab_m3 (Settings / Widgets / Appearance child
// tabs): Visibility card with 60px bands and dividers, then the Renderer
// card; Widgets = embedded toggle + three-column widget board; Appearance =
// the slider set from paint_dock_appearance_tab / paintAppearance.

const width_mode_options = [_][]const u8{ "Floating", "Edge-to-edge", "Fill" };
const output_options = [_][]const u8{ "Auto", "All", "DP-1", "DP-2", "HDMI-A-1" };
// Panel dead-zone actions, spelled exactly as `panel_dispatch_dead_zone`
// reads them (`panel.cpp:1553-1567`); "none" disables the zone.
const deadzone_options = [_][]const u8{ "none", "control-center", "calendar", "tray" };

// ---------------------------------------------------------------- Dock ---

pub const dock_settings = [_]Card{
    .{
        .title = "Visibility & behavior",
        .subtitle = "Control how your dock appears and behaves",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Show dock", .desc = "Render the dock strip; turns off reserve when hidden.", .field = .dock_show_dock } },
            .{ .toggle = .{ .label = "Auto-hide dock", .desc = "Hide until pointer reaches the trigger zone.", .field = .dock_auto_hide } },
            .{ .toggle = .{ .label = "Group running windows", .desc = "One dock icon merges all windows per application.", .field = .dock_group_apps } },
            .{ .toggle = .{ .label = "Dock tooltips", .desc = "Show tooltips when hovering dock icons.", .field = .dock_tooltips_enabled } },
            .{ .toggle = .{ .label = "Pinned apps tray pill", .desc = "One capsule behind consecutive pinned icons (like the tray).", .field = .dock_pinned_apps_tray_pill } },
            .{ .toggle = .{ .label = "Running apps tray pill", .desc = "One capsule behind consecutive running app icons.", .field = .dock_running_apps_tray_pill } },
            .{ .combo = .{ .label = "Display", .desc = "Auto = one monitor, All = every display.", .field = .dock_output_name, .options = &output_options } },
        },
    },
    .{
        .title = "Renderer",
        .subtitle = "Vulkan uses the GPU pipeline; Cairo renders in software with far lower memory.",
        .rows = &[_]Row{
            .{ .combo = .{
                .label = "Shell renderer",
                .desc = "Applies live; switching to Vulkan maps GPU drivers on next frame.",
                .field = .renderer,
                .options = &.{ "vulkan", "cairo" },
                .labels = &.{ "Vulkan (GPU)", "Cairo (CPU, low memory)" },
            } },
        },
    },
};

pub const dock_widgets = [_]Card{
    .{
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Embedded dock widgets", .desc = "Clock, media, workspaces, and control-center tiles in the dock strip.", .field = .dock_widgets_enabled } },
            .{ .widget_board = .{
                .left = &.{ "app_menu", "settings_button" },
                .center = &.{ "clock", "media", "weather" },
                .right = &.{ "notifications", "control_center", "volume_mixer" },
            } },
        },
    },
};

pub const dock_appearance = [_]Card{
    .{
        .grid = true,
        .rows = &[_]Row{
            .{ .tile_slider = .{ .label = "Corner Radius", .field = .dock_radius, .min = 0, .max = 50 } },
            .{ .tile_slider = .{ .label = "Dock Scale", .field = .dock_scale_pct, .min = 50, .max = 150, .unit = "%" } },
            .{ .tile_slider = .{ .label = "Icon Size", .field = .dock_icon_size, .min = 0, .max = 50 } },
            .{ .tile_slider = .{ .label = "Icon Spacing", .field = .dock_icon_spacing, .min = -50, .max = 50 } },
            .{ .tile_slider = .{ .label = "Dock Opacity", .field = .dock_opacity, .min = 0, .max = 100, .unit = "%" } },
            .{ .tile_toggle = .{ .label = "Dock Border", .field = .dock_border_enabled, .style = .title_band } },
            .{ .tile_slider = .{ .label = "Border Size", .field = .dock_border_size, .min = 0, .max = 12 } },
            .{ .tile_slider = .{ .label = "Border Opacity", .field = .dock_border_opacity, .min = 0, .max = 100, .unit = "%" } },
            .{ .tile_toggle = .{ .label = "Liquid Glass", .field = .dock_liquid_glass, .style = .title_band } },
            .{ .tile_toggle = .{ .label = "Colored Glass", .field = .dock_colored_glass, .style = .title_band } },
            .{ .tile_slider = .{ .label = "Dock Margin", .field = .dock_bottom_gap, .min = 0, .max = 25 } },
            .{ .tile_slider = .{ .label = "Exclusive Zone", .field = .dock_exclusive_zone_gap, .min = 0, .max = 100 } },
        },
    },
};

// ----------------------------------------------------------------Panel ---

pub const panel_settings = [_]Card{
    .{
        .title = "Panel",
        .subtitle = "Control how your panel appears and behaves",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Show panel", .desc = "Render the top/bottom indicator bar.", .field = .panel_enabled } },
            .{ .combo = .{ .label = "Width mode", .desc = "Floating, edge-to-edge, or content fill.", .field = .panel_width_mode, .options = &width_mode_options } },
            .{ .toggle = .{ .label = "Position at top", .desc = "Place the panel at the top edge (off = bottom).", .field = .panel_position_top } },
            .{ .toggle = .{ .label = "Auto-hide", .desc = "Hide the panel until the edge is hovered.", .field = .panel_auto_hide } },
            .{ .toggle = .{ .label = "Tooltips", .desc = "Show tooltips when hovering panel widgets.", .field = .panel_tooltips_enabled } },
            .{ .toggle = .{ .label = "Embedded widgets", .desc = "Show widgets inside the panel strip.", .field = .panel_widgets_enabled } },
            .{ .combo = .{ .label = "Display", .desc = "Auto = one monitor, All = every display.", .field = .panel_output_name, .options = &output_options } },
            .{ .toggle = .{ .label = "Overlay layer", .desc = "Float above fullscreen windows instead of the top layer.", .field = .panel_overlay_layer } },
            .{ .toggle = .{ .label = "Hover highlight", .desc = "Tint the widget under the pointer.", .field = .panel_hover_highlight } },
            .{ .toggle = .{ .label = "Smart auto-hide", .desc = "Hide when any workspace has windows; show when all are empty.", .field = .panel_smart_auto_hide } },
            .{ .toggle = .{ .label = "Reveal on workspace switch", .desc = "Briefly reveal a hidden bar when the active workspace changes.", .field = .panel_reveal_on_switch } },
            .{ .toggle = .{ .label = "Scroll changes volume", .desc = "Vertical scroll over empty bar space adjusts the sink volume.", .field = .panel_scroll_volume } },
            .{ .combo = .{ .label = "Left dead-zone action", .desc = "What a left-click on empty bar space opens.", .field = .panel_deadzone_left, .options = &deadzone_options } },
            .{ .combo = .{ .label = "Middle dead-zone action", .desc = "What a middle-click on empty bar space opens.", .field = .panel_deadzone_middle, .options = &deadzone_options } },
            .{ .combo = .{ .label = "Right dead-zone action", .desc = "What a right-click on empty bar space opens.", .field = .panel_deadzone_right, .options = &deadzone_options } },
        },
    },
};

pub const panel_widgets = [_]Card{
    .{
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Embedded panel widgets", .desc = "Show widgets inside the panel strip.", .field = .panel_widgets_enabled } },
            .{ .widget_board = .{
                .left = &.{ "workspaces" },
                .center = &.{ "clock", "media" },
                .right = &.{ "notifications", "control_center" },
            } },
        },
    },
};

// C++ paintAppearance: 10-tile grid, toggle at index 5 (40x24 centered).
pub const panel_appearance = [_]Card{
    .{
        .grid = true,
        .rows = &[_]Row{
            .{ .tile_slider = .{ .label = "Height", .field = .panel_height, .min = 20, .max = 120 } },
            .{ .tile_slider = .{ .label = "Corner Radius", .field = .panel_radius, .min = 0, .max = 50 } },
            .{ .tile_slider = .{ .label = "Opacity", .field = .panel_opacity, .min = 0, .max = 100, .unit = "%" } },
            .{ .tile_slider = .{ .label = "Icon Size", .field = .panel_icon_size, .min = 8, .max = 96 } },
            .{ .tile_slider = .{ .label = "Icon Spacing", .field = .panel_icon_spacing, .min = 0, .max = 50 } },
            .{ .tile_toggle = .{ .label = "Panel Border", .field = .panel_border, .style = .centered } },
            .{ .tile_slider = .{ .label = "Scale", .field = .panel_scale_pct, .min = 50, .max = 150, .unit = "%" } },
            .{ .tile_slider = .{ .label = "Border Size", .field = .panel_border_size, .min = 1, .max = 12 } },
            .{ .tile_slider = .{ .label = "Panel Margin", .field = .panel_edge_gap, .min = 0, .max = 25 } },
            .{ .tile_slider = .{ .label = "Exclusive Zone", .field = .panel_exclusive_zone_gap, .min = 0, .max = 100 } },
            .{ .tile_slider = .{ .label = "Floating Inset", .field = .panel_floating_amount, .min = 0, .max = 50 } },
            .{ .tile_toggle = .{ .label = "Capsule Pills", .field = .panel_capsule, .style = .centered } },
            .{ .tile_slider = .{ .label = "Capsule Opacity", .field = .panel_capsule_opacity, .min = 0, .max = 100, .unit = "%" } },
            .{ .tile_slider = .{ .label = "Corner TL", .field = .panel_corner_tl, .min = 0, .max = 50 } },
            .{ .tile_slider = .{ .label = "Corner TR", .field = .panel_corner_tr, .min = 0, .max = 50 } },
            .{ .tile_slider = .{ .label = "Corner BL", .field = .panel_corner_bl, .min = 0, .max = 50 } },
            .{ .tile_slider = .{ .label = "Corner BR", .field = .panel_corner_br, .min = 0, .max = 50 } },
            .{ .combo = .{ .label = "Icon Theme", .desc = "Icon pack for panel widgets (empty = dock theme).", .field = .panel_icon_theme, .options = &[_][]const u8{ "", "Adwaita", "Papirus", "Tela", "Numix" } } },
        },
    },
};

// -------------------------------------------------------------- Taskbar ---

pub const taskbar_settings = [_]Card{
    .{
        .title = "Taskbar",
        .subtitle = "Control how your taskbar appears and behaves",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Show taskbar", .desc = "Render the taskbar at the bottom or top.", .field = .taskbar_enabled } },
            .{ .combo = .{ .label = "Width mode", .desc = "Floating, edge-to-edge, or full fill.", .field = .taskbar_width_mode, .options = &width_mode_options } },
            .{ .toggle = .{ .label = "Position at top", .desc = "Place the taskbar at the top edge of the screen.", .field = .taskbar_position_top } },
            .{ .toggle = .{ .label = "Group running windows", .desc = "Group windows from the same app together.", .field = .taskbar_group_apps } },
            .{ .toggle = .{ .label = "Auto-hide", .desc = "Automatically hide the taskbar when not in use.", .field = .taskbar_auto_hide } },
            .{ .toggle = .{ .label = "Tooltips", .desc = "Show tooltips when hovering over app icons.", .field = .taskbar_tooltips_enabled } },
            .{ .toggle = .{ .label = "Pinned apps tray pill", .desc = "Draw a pill-shaped background behind pinned apps.", .field = .taskbar_pinned_apps_tray_pill } },
            .{ .toggle = .{ .label = "Running apps tray pill", .desc = "Draw a pill-shaped background behind running apps.", .field = .taskbar_running_apps_tray_pill } },
            .{ .combo = .{ .label = "Display", .desc = "Auto = one monitor, All = every display.", .field = .taskbar_output_name, .options = &output_options } },
            .{ .toggle = .{ .label = "Show window labels", .desc = "Show window titles on running buttons.", .field = .taskbar_show_labels } },
            .{ .toggle = .{ .label = "Collapse when full", .desc = "Fall back to grouped icons when the bar overflows.", .field = .taskbar_collapse_when_full } },
            .{ .toggle = .{ .label = "Window previews", .desc = "Hover a running app to preview its windows.", .field = .taskbar_thumbnails_enabled } },
            .{ .toggle = .{ .label = "Enlarge preview on hover", .desc = "Zoom the hovered window card (Aero Peek style).", .field = .taskbar_thumbnail_peek_enabled } },
            .{ .combo = .{ .label = "Preview threshold", .desc = "Past this many windows, show a compact list.", .field = .taskbar_thumbnail_threshold, .options = &.{ "3", "5", "8", "10", "15", "20" } } },
            .{ .toggle = .{ .label = "Compact media", .desc = "Art + transport only; title lives in the hover popup.", .field = .taskbar_compact_media } },
        },
    },
};

pub const taskbar_widgets = [_]Card{
    .{
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Embedded taskbar widgets", .desc = "Show widgets inside the taskbar strip.", .field = .taskbar_widgets_enabled } },
            .{ .widget_board = .{
                .left = &.{ "pinned_apps" },
                .center = &.{ "clock", "media" },
                .right = &.{ "running_apps", "notifications" },
            } },
        },
    },
};

// C++ paintAppearance: 10-tile grid, toggle at index 5 (40x24 centered).
pub const taskbar_appearance = [_]Card{
    .{
        .grid = true,
        .rows = &[_]Row{
            .{ .tile_slider = .{ .label = "Height", .field = .taskbar_height, .min = 24, .max = 120 } },
            .{ .tile_slider = .{ .label = "Corner Radius", .field = .taskbar_radius, .min = 0, .max = 50 } },
            .{ .tile_slider = .{ .label = "Opacity", .field = .taskbar_opacity, .min = 0, .max = 100, .unit = "%" } },
            .{ .tile_slider = .{ .label = "Icon Size", .field = .taskbar_icon_size, .min = 0, .max = 96 } },
            .{ .tile_slider = .{ .label = "Icon Spacing", .field = .taskbar_icon_spacing, .min = 0, .max = 50 } },
            .{ .tile_toggle = .{ .label = "Taskbar Border", .field = .taskbar_border, .style = .centered } },
            .{ .tile_slider = .{ .label = "Scale", .field = .taskbar_scale_pct, .min = 50, .max = 150, .unit = "%" } },
            .{ .tile_slider = .{ .label = "Border Size", .field = .taskbar_border_size, .min = 1, .max = 12 } },
            .{ .tile_slider = .{ .label = "Taskbar Margin", .field = .taskbar_edge_gap, .min = 0, .max = 25 } },
            .{ .tile_slider = .{ .label = "Exclusive Zone", .field = .taskbar_exclusive_zone_gap, .min = 0, .max = 100 } },
        },
    },
};

// ------------------------------------------------- Launcher / Desktop -----
// Launcher tab (id 9) — three child pages mirroring launcher_tab_m3.hpp:
// sub 0 Launcher (Layout + Grid + Appearance), sub 1 Workspaces,
// sub 2 Overview. Ranges, labels and descriptions are verbatim from the C++
// paint calls so the generic renderer hooks every option. Slider rows carry
// no per-row desc (the C++ `hyprland_paint_slider_card` has none — the value
// pill carries the value); toggles keep their C++ description lines.

const launcher_layout_rows = [_]Row{
    .{ .slider = .{ .label = "Layout scale", .field = .launchpad_layout_scale_pct, .min = 70, .max = 150, .unit = "%" } },
    .{ .slider = .{ .label = "Icon size", .field = .launchpad_icon_fill_pct, .min = 30, .max = 95, .unit = "%" } },
    .{ .slider = .{ .label = "Icon spacing", .field = .launchpad_cell_gap_px, .min = 0, .max = 24, .unit = "px" } },
    .{ .slider = .{ .label = "Folder size", .field = .launchpad_folder_size_pct, .min = 50, .max = 200, .unit = "%" } },
    .{ .slider = .{ .label = "Folder spacing", .field = .launchpad_folder_gap_px, .min = 4, .max = 48, .unit = "px" } },
    .{ .slider = .{ .label = "Folder columns", .field = .launchpad_folder_columns, .min = 2, .max = 8, .unit = "" } },
    .{ .slider = .{ .label = "Folder rows", .field = .launchpad_folder_rows, .min = 1, .max = 6, .unit = "" } },
};

const launcher_grid_rows = [_]Row{
    .{ .slider = .{ .label = "Columns", .field = .launchpad_grid_columns, .min = 4, .max = 12, .unit = "" } },
    .{ .slider = .{ .label = "Rows", .field = .launchpad_grid_rows, .min = 3, .max = 10, .unit = "" } },
    .{ .slider = .{ .label = "DPI scale", .field = .launchpad_dpi_scale_pct, .min = 50, .max = 300, .unit = "%" } },
};

const launcher_appearance_rows = [_]Row{
    .{ .slider = .{ .label = "Widget opacity", .field = .slot_pill_opacity, .min = 0, .max = 100, .unit = "%" } },
};

/// Full Launcher child page (sub 0): Layout + Grid + Appearance cards.
pub const launcher_main = [_]Card{
    .{
        .title = "Layout",
        .subtitle = "Scale and spacing for the launcher grid",
        .rows = &launcher_layout_rows,
    },
    .{
        .title = "Grid",
        .subtitle = "Columns, rows, and DPI scaling",
        .rows = &launcher_grid_rows,
    },
    .{
        .title = "Appearance",
        .subtitle = "Widget opacity",
        .rows = &launcher_appearance_rows,
    },
};

pub const launcher_workspaces = [_]Card{
    .{
        .title = "Workspaces",
        .subtitle = "Workspace slots and app icons",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Show app icons", .desc = "Show running applications as icons in the workspace strip.", .field = .workspaces_show_apps } },
            .{ .slider = .{ .label = "Number of workspaces", .field = .workspaces_max_slots, .min = 0, .max = 16, .unit = "" } },
            .{ .slider = .{ .label = "Max workspace icons", .field = .workspaces_max_icons, .min = 1, .max = 8, .unit = "" } },
        },
    },
};

pub const launcher_overview = [_]Card{
    .{
        .title = "Overview",
        .subtitle = "Workspace overview layout and behavior",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Live updates", .desc = "Stream live per-window frames while the overview is open.", .field = .overview_live_updates } },
            .{ .toggle = .{ .label = "Multi-monitor", .desc = "Show the overview on all monitors at once.", .field = .overview_multi_monitor } },
            .{ .combo = .{ .label = "Capture mode", .field = .overview_capture_mode, .options = &[_][]const u8{ "Snapshot", "Screencopy" } } },
            .{ .combo = .{ .label = "Scroll axis", .field = .overview_axis, .options = &[_][]const u8{ "Vertical", "Horizontal" } } },
            .{ .slider = .{ .label = "Card scale", .field = .overview_card_scale_pct, .min = 20, .max = 80, .unit = "%" } },
            .{ .slider = .{ .label = "Card spacing", .field = .overview_card_gap_px, .min = 8, .max = 80, .unit = "px" } },
            .{ .slider = .{ .label = "Scroll settle delay", .field = .overview_scroll_delay_ms, .min = 50, .max = 500, .unit = "ms" } },
            .{ .slider = .{ .label = "Close button size", .field = .overview_close_btn_size_px, .min = 20, .max = 60, .unit = "px" } },
            .{ .slider = .{ .label = "Search bar width", .field = .overview_search_width_px, .min = 200, .max = 800, .unit = "px" } },
        },
    },
};

pub const desktop = [_]Card{
    .{
        .title = "Desktop",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Show desktop", .desc = "Desktop icons, right-click menu, and widgets on the desktop background.", .field = .desktop_enabled } },
        },
    },
};

pub const desktop_widgets = [_]Card{
    .{
        .title = "Desktop widgets",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Widgets enabled", .desc = "Shows pinned widgets above the wallpaper.", .field = .dock_widgets_enabled } },
            .{ .info = "Widget types: clock, weather, system monitor, calendar, media, world clock." },
            .{ .info = "Positions are stored per widget as x,y with an output name and scale." },
        },
    },
    .{
        .title = "Layout",
        .rows = &[_]Row{
            .{ .info = "Open the widget picker from the desktop context menu to add widgets." },
        },
    },
};
