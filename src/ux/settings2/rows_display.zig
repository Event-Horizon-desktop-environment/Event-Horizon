const rows = @import("rows.zig");
const Row = rows.Row;
const Card = rows.Card;

// Display pages — Monitors (static fallback), Themes, Color Themes, Icons,
// Nightlight.
//
// The Monitors tab is the one data-driven page: when the window has a live
// `monitors_state.State` it builds its cards from it in `monitors_page.zig`
// and this list is never consulted. What stays here is the fallback for
// callers with no monitors state at all (tests, bare `Content`) — the arrange
// canvas and output pills are state painters, so they do not appear.

pub const monitors = [_]Card{
    .{
        .title = "Monitors",
        .subtitle = "Arrange outputs and set their mode, scale and colour.",
        .rows = &[_]Row{
            .{ .info = "No monitor state is connected. Open the Monitors tab in the settings window to arrange outputs here." },
        },
    },
};

pub const themes = [_]Card{
    .{
        .title = "Theme",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Custom color theme", .desc = "Overrides GTK/Qt/shell colors with a preset below.", .field = .color_theme_enabled } },
            .{ .combo = .{ .label = "Preset", .desc = "Catppuccin, Google, Gruvbox and Rose Pine palettes.", .field = .color_theme_name, .options = &theme_names } },
        },
    },
    .{
        .title = "Applies to",
        .rows = &[_]Row{
            .{ .info = "Shell surfaces, GTK theme, Qt theme, cursor and icons." },
            .{ .info = "Palette colors resolve in order: custom > matugen > horizon > default." },
        },
    },
};

pub const color_themes = [_]Card{
    .{
        .title = "Color themes",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Enabled", .desc = "Applies the selected preset to the whole shell.", .field = .color_theme_enabled } },
            .{ .combo = .{ .label = "Palette", .field = .color_theme_name, .options = &theme_names } },
        },
    },
    .{
        .title = "Notes",
        .rows = &[_]Row{
            .{ .info = "Each preset is a 16-role Material 3 palette (primary to on-hover)." },
            .{ .info = "Hex values are written to config.toml by the settings app." },
        },
    },
};

pub const icons = [_]Card{
    .{
        .title = "Icon theme",
        .rows = &[_]Row{
            .{ .combo = .{ .label = "Theme", .desc = "Icon pack used by the dock, launcher and file manager.", .field = .icon_theme, .options = &[_][]const u8{ "", "Adwaita", "Papirus", "Tela", "Numix" } } },
        },
    },
    .{
        .title = "Notes",
        .rows = &[_]Row{
            .{ .info = "Themes are searched in XDG_DATA_HOME/icons and XDG_DATA_DIRS/icons." },
        },
    },
};

pub const nightlight = [_]Card{
    .{
        .title = "Nightlight",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Enabled", .desc = "Warms the display by adjusting gamma at night.", .field = .nightlight_enabled } },
            .{ .combo = .{ .label = "Schedule", .field = .nightlight_schedule, .options = &[_][]const u8{ "Manual", "Sunset to sunrise", "Scheduled" } } },
        },
    },
    .{
        .title = "Temperature",
        .rows = &[_]Row{
            .{ .slider = .{ .label = "Day temperature", .desc = "Kelvin used during daylight hours.", .field = .nightlight_day_temp, .min = 2500, .max = 7500, .unit = "K" } },
            .{ .slider = .{ .label = "Night temperature", .field = .nightlight_night_temp, .min = 2500, .max = 7500, .unit = "K" } },
        },
    },
    .{
        .title = "Scheduled window",
        .rows = &[_]Row{
            .{ .slider = .{ .label = "Start", .desc = "Minutes after midnight.", .field = .nightlight_start_min, .min = 0, .max = 1439, .unit = "min" } },
            .{ .slider = .{ .label = "End", .field = .nightlight_end_min, .min = 0, .max = 1439, .unit = "min" } },
        },
    },
};

const theme_names = [_][]const u8{
    "Catppuccin Latte",
    "Catppuccin Frappe",
    "Catppuccin Macchiato",
    "Catppuccin Mocha",
    "Google Material Light",
    "Google Material Dark",
    "Gruvbox Dark",
    "Gruvbox Light",
    "Rose Pine",
    "Rose Pine Moon",
    "Rose Pine Dawn",
    "Google Brand Dark",
    "Google Brand Light",
};
