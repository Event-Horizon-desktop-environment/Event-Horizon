const rows = @import("rows.zig");
const Row = rows.Row;
const Card = rows.Card;

// Wallpaper, Network and solo pages — Wallpaper, Bing, Wi-Fi, Wired, VPN,
// Taskflip, Workspaces, Dashboard, Live wallpaper. Mirrors the C++ wallpaper
// and network tabs: mode combos, path rows, and scan lists.

pub const wallpaper = [_]Card{
    .{
        .title = "Wallpaper",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Wallpaper enabled", .desc = "Paints the configured image on the background layer.", .field = .wallpaper_enabled } },
            .{ .combo = .{ .label = "Scale mode", .field = .wallpaper_mode, .options = &[_][]const u8{ "Fill", "Fit", "Stretch", "Center", "Tile" } } },
            .{ .info = "Image path — choose a picture from the gallery below." },
            .{ .button = .{ .label = "Browse images", .glyph = "photo_library" } },
        },
    },
    .{
        .title = "Slideshow folder",
        .rows = &[_]Row{
            .{ .info = "A folder cycles wallpapers at the interval set in the shell config." },
            .{ .button = .{ .label = "Choose folder" } },
        },
    },
};

pub const bing = [_]Card{
    .{
        .title = "Bing daily wallpaper",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Enabled", .desc = "Downloads the daily Bing image.", .field = .bing_enabled } },
            .{ .toggle = .{ .label = "Apply daily", .desc = "Sets the downloaded image as wallpaper automatically.", .field = .bing_daily_enabled } },
            .{ .combo = .{ .label = "Filter", .field = .bing_filter, .options = &[_][]const u8{ "All markets", "United States", "United Kingdom", "Germany", "Japan" } } },
        },
    },
    .{
        .title = "Archive",
        .rows = &[_]Row{
            .{ .info = "Downloaded images land in the archive folder and stay available offline." },
            .{ .button = .{ .label = "Open archive folder" } },
        },
    },
};

pub const wifi = [_]Card{
    .{
        .title = "Wi-Fi",
        .rows = &[_]Row{
            .{ .info = "NetworkManager lists nearby access points with strength and lock state." },
            .{ .info = "Known networks auto-connect in priority order." },
            .{ .button = .{ .label = "Scan for networks" } },
        },
    },
};

pub const wired = [_]Card{
    .{
        .title = "Wired",
        .rows = &[_]Row{
            .{ .info = "Ethernet devices are shown with link speed and IPv4/IPv6 addresses." },
            .{ .info = "Toggle a device to bring it up or down through NetworkManager." },
        },
    },
};

pub const vpn = [_]Card{
    .{
        .title = "VPN",
        .rows = &[_]Row{
            .{ .info = "Saved tunnels are read from NetworkManager VPN connections." },
            .{ .button = .{ .label = "Add VPN connection" } },
        },
    },
};

pub const taskflip = [_]Card{
    .{
        .title = "Task flip",
        .rows = &[_]Row{
            .{ .info = "Alt+Tab style window cycling with previews on the taskbar." },
            .{ .info = "Ordering follows most-recently-used or stable client order." },
        },
    },
};

pub const workspaces = [_]Card{
    .{
        .title = "Workspaces",
        .rows = &[_]Row{
            .{ .slider = .{ .label = "Workspace slots", .desc = "Number of workspace buttons in the strip.", .field = .workspaces_max_slots, .min = 2, .max = 10, .unit = "" } },
            .{ .toggle = .{ .label = "Show running apps", .desc = "Lists windows on the active workspace in the strip.", .field = .workspaces_show_apps } },
        },
    },
};

pub const dashboard = [_]Card{
    .{
        .title = "Dashboard",
        .rows = &[_]Row{
            .{ .toggle = .{ .label = "Enabled", .desc = "Shows the quick-settings dashboard overlay.", .field = .dashboard_enabled } },
            .{ .slider = .{ .label = "Columns", .field = .dashboard_columns, .min = 2, .max = 8, .unit = "" } },
        },
    },
};

pub const live_wallpaper = [_]Card{
    .{
        .title = "Live wallpaper",
        .rows = &[_]Row{
            .{ .info = "Video wallpapers decode through ffmpeg into the background layer." },
            .{ .info = "Supported extensions: mp4, webm, mkv and gif." },
            .{ .button = .{ .label = "Choose video" } },
        },
    },
};
