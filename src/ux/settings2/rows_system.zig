const rows = @import("rows.zig");
const Row = rows.Row;
const Card = rows.Card;

// System pages — Notifications, Default Apps, Time, Keyboard,
// Bluetooth, Power, Accounts, Startup: one
// card per concern, controls on the right, descriptions under labels.

pub const toast_positions = [_][]const u8{ "top_right", "top_left", "bottom_right", "bottom_left", "top_center", "bottom_center" };
pub const notif_output_options = [_][]const u8{ "auto", "all", "DP-1", "DP-2", "HDMI-A-1" };

pub const notifications = [_]Card{
    .{
        .title = "Server",
        .subtitle = "The daemon behind org.freedesktop.Notifications.",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "DBus notification server", .desc = "Accepts org.freedesktop.Notifications calls.", .field = .notifications_dbus_enabled } },
            .{ .toggle = .{ .label = "Do not disturb", .desc = "Silences banners while keeping the history.", .field = .notifications_dnd } },
        },
    },
    .{
        .title = "Layout & Toast Appearance",
        .subtitle = "Size, placement and timing of banner cards.",
        .rows = &[_]Row{
            .{ .slider = .{ .label = "Layout scale", .desc = "Banner size as a percent of the base card.", .field = .notifications_scale_pct, .min = 50, .max = 200, .unit = "%" } },
            .{ .slider = .{ .label = "Default timeout", .desc = "How long a banner stays on screen.", .field = .notifications_timeout_ms, .min = 1000, .max = 120000, .unit = "ms" } },
            .{ .slider = .{ .label = "Edge margin", .desc = "Gap between banners and the screen edge.", .field = .notifications_margin_px, .min = 8, .max = 64, .unit = "px" } },
            .{ .slider = .{ .label = "Corner radius", .desc = "Roundness of banner corners.", .field = .notifications_corner_radius_px, .min = 0, .max = 40, .unit = "px" } },
            .{ .slider = .{ .label = "Max width", .desc = "Widest a banner grows with its title.", .field = .notifications_max_width_px, .min = 200, .max = 900, .unit = "px" } },
            .{ .toggle = .{ .label = "Layer-shell toasts", .desc = "Draw banners as layer-shell surfaces.", .field = .notifications_layer_shell } },
            .{ .combo = .{ .label = "Toast position", .desc = "Corner the banner stack anchors to.", .field = .notifications_toast_position, .options = &toast_positions } },
            .{ .combo = .{ .label = "Display", .desc = "Auto = primary monitor.", .field = .notifications_output, .options = &notif_output_options } },
        },
    },
    .{
        .title = "Test",
        .subtitle = "Send a test notification through the live daemon.",
        .rows = &[_]Row{
            .{ .button = .{ .label = "Test notification", .glyph = "notifications" } },
        },
    },
};

pub const default_apps = [_]Card{
    .{
        .title = "Default applications",
        .rows = &[_]Row{},
    },
    .{
        .title = "Associations",
        .rows = &[_]Row{
            .{ .button = .{ .label = "Reset to detected defaults" } },
        },
    },
};

// The Time page is a bespoke self-painted page (time_tab.zig): clock and
// date formats, live preview, NTP, timezone and the world-clock city list.
// The generic card list stays empty so nothing renders behind it.
pub const time = [_]Card{};

pub const keyboard = [_]Card{
    .{
        .title = "Layout",
        .rows = &[_]Row{
            .{ .combo = .{ .label = "Keyboard layout", .desc = "XKB layout id used by the compositor.", .field = .keyboard_layout, .options = &[_][]const u8{ "us", "gb", "de", "fr", "es", "it", "jp", "br" } } },
            .{ .toggle = .{ .label = "NumLock on login", .field = .keyboard_numlock } },
            .{ .toggle = .{ .label = "Middle-click paste", .desc = "Paste selection on middle click.", .field = .keyboard_middle_paste } },
        },
    },
    .{
        .title = "Repeat",
        .rows = &[_]Row{
            .{ .slider = .{ .label = "Repeat rate", .field = .keyboard_repeat_rate, .min = 0, .max = 100, .unit = "/s" } },
            .{ .slider = .{ .label = "Repeat delay", .field = .keyboard_repeat_delay_ms, .min = 100, .max = 2000, .unit = "ms" } },
            .{ .info = "Preview: holding a key repeats at the rate above after the delay." },
        },
    },
};

pub const bluetooth = [_]Card{
    .{
        .title = "Bluetooth",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Auto-reconnect", .desc = "Reconnects known devices when they come in range.", .field = .bt_auto_reconnect } },
            .{ .info = "Adapter state is read from BlueZ over DBus." },
            .{ .info = "Paired devices appear here with signal strength and battery." },
        },
    },
};

pub const power = [_]Card{
    .{
        .title = "Power saving",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Display Sleep", .desc = "Turn off the screen when inactive", .field = .power_display_sleep } },
            .{ .slider = .{ .label = "Sleep after", .field = .power_display_timeout_min, .min = 1, .max = 60, .unit = "min" } },
            .{ .toggle = .{ .label = "Idle suspend", .field = .power_idle_suspend } },
            .{ .slider = .{ .label = "Idle timeout", .field = .power_idle_timeout_min, .min = 5, .max = 120, .unit = "min" } },
            .{ .toggle = .{ .label = "Show battery percentage", .field = .power_show_battery_pct } },
        },
    },
    .{
        .title = "Buttons",
        .rows = &[_]Row{
            .{ .combo = .{ .label = "Power Button", .desc = "When power button is pressed", .field = .power_button_action, .options = &power_actions } },
            .{ .combo = .{ .label = "Lid Close", .desc = "When lid is closed", .field = .power_lid_action, .options = &power_actions } },
        },
    },
};

pub const power_performance = [_]Card{
    .{
        .title = "Performance",
        .subtitle = "Tuning profile for power versus performance under load.",
        .rows = &[_]Row{
            .{ .combo = .{ .label = "Energy Performance Preference", .desc = "Hint for the CPU governor under load.", .field = .power_perf_pref, .options = &power_prefs, .labels = &power_pref_labels } },
            .{ .toggle = .{ .label = "System Tuning Profile", .desc = "Optimized for general desktop usage", .field = .power_tuning_profile } },
            .{ .info = "Preference is forwarded to power-profiles-daemon when it is running." },
        },
    },
};

pub const accounts = [_]Card{
    .{
        .title = "Account",
        .rows = &[_]Row{
            .{ .info = "User name, avatar and hostname are shown on the header card." },
            .{ .info = "Deleting the last administrator is blocked by a guard." },
        },
    },
    .{
        .title = "Avatar",
        .rows = &[_]Row{
            .{ .info = "Pictures are resolved from ~/.face and XDG face dirs." },
            .{ .button = .{ .label = "Change avatar" } },
        },
    },
};

pub const autostart = [_]Card{
    .{
        .title = "Startup applications",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Enable autostart", .desc = "Runs entries from the autostart directory at login.", .field = .autostart_enabled } },
            .{ .info = "Entries are .desktop files in ~/.config/autostart." },
            .{ .button = .{ .label = "Add startup entry" } },
        },
    },
};

// Updates (tab 51) — three-card layout:
// This device / Software update / Release notes, same titles and descriptions.
pub const updater = [_]Card{
    .{
        .title = "This device",
        .subtitle = "Current version and update preferences",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Auto-check for updates", .desc = "Check GitHub releases in the background every 6h.", .field = .updater_auto_check } },
            .{ .info = "Package: detected from the running system." },
            .{ .info = "Last checked: never   •   Auto-check every 6h" },
        },
    },
    .{
        .title = "Software update",
        .subtitle = "Checks GitHub releases, installs with pkexec, then restarts",
        .rows = &[_]Row{
            .{ .info = "No update check yet." },
            .{ .button = .{ .label = "Check now", .glyph = "system_update" } },
            .{ .button = .{ .label = "Download", .glyph = "download" } },
            .{ .button = .{ .label = "Install update", .glyph = "install_desktop" } },
            .{ .button = .{ .label = "Restart shell", .glyph = "restart_alt" } },
        },
    },
    .{
        .title = "Release notes",
        .subtitle = "Notes for the latest release appear here after a check.",
        .rows = &[_]Row{
            .{ .info = "Check for updates to fetch the latest release notes." },
        },
    },
};

const power_actions = [_][]const u8{ "Nothing", "Suspend", "Hibernate", "Shutdown", "Reboot" };
const power_prefs = [_][]const u8{ "0", "1", "2" };
const power_pref_labels = [_][]const u8{ "power-saver", "balance-performance", "performance" };
