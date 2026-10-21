const std = @import("std");

// Global settings search — Zig port of
// src/ux/settings/utils/search/settings_search.hpp.
// Same layout: search bar 36px, result rows 48px tall on a 52px pitch,
// bar at (24,24) size (244x36), tabs start at y=68.

pub const search_bar_h: i32 = 36;
pub const search_result_h: i32 = 48;
pub const search_result_pitch: i32 = 52;

pub fn searchBarGeom() struct { x: i32, y: i32, w: i32, h: i32 } {
    return .{ .x = 24, .y = 24, .w = 244, .h = search_bar_h };
}

pub fn sidebarTabsBaseY() i32 {
    return 68;
}

pub const SearchEntry = struct {
    tab: i32,
    title: []const u8,
    section: []const u8,
    keywords: []const u8,
    glyph: []const u8,
};

pub const entries = [_]SearchEntry{
    .{ .tab = 0, .title = "Dock", .section = "Panels & UI", .keywords = "dock bar app launcher", .glyph = "dock_to_bottom" },
    .{ .tab = 1, .title = "Panel", .section = "Panels & UI", .keywords = "panel top bar indicators", .glyph = "dock_to_top" },
    .{ .tab = 11, .title = "Taskbar", .section = "Panels & UI", .keywords = "taskbar window list", .glyph = "dock_to_bottom" },
    .{ .tab = 9, .title = "Launcher", .section = "Panels & UI", .keywords = "launcher app grid overview", .glyph = "apps" },
    // Launcher child options (mirror settings_search.hpp tab-9 rows verbatim,
    // plus the rows the C++ paints but never indexed).
    .{ .tab = 9, .title = "Layout scale", .section = "Launcher", .keywords = "launcher layout scale size", .glyph = "search" },
    .{ .tab = 9, .title = "Icon size", .section = "Launcher", .keywords = "launcher icon size", .glyph = "apps" },
    .{ .tab = 9, .title = "Icon spacing", .section = "Launcher", .keywords = "launcher icon spacing gap folders", .glyph = "horizontal_rule" },
    .{ .tab = 9, .title = "Folder size", .section = "Launcher", .keywords = "launcher folder size", .glyph = "photo_library" },
    .{ .tab = 9, .title = "Folder spacing", .section = "Launcher", .keywords = "launcher folder spacing gap", .glyph = "horizontal_rule" },
    .{ .tab = 9, .title = "Folder columns", .section = "Launcher", .keywords = "launcher folder columns grid", .glyph = "grid_view" },
    .{ .tab = 9, .title = "Folder rows", .section = "Launcher", .keywords = "launcher folder rows grid", .glyph = "grid_view" },
    .{ .tab = 9, .title = "Columns", .section = "Launcher", .keywords = "launcher grid columns", .glyph = "grid_view" },
    .{ .tab = 9, .title = "Rows", .section = "Launcher", .keywords = "launcher grid rows", .glyph = "grid_view" },
    .{ .tab = 9, .title = "DPI scale", .section = "Launcher", .keywords = "launcher dpi scale", .glyph = "search" },
    .{ .tab = 9, .title = "Widget opacity", .section = "Launcher", .keywords = "launcher widget opacity", .glyph = "palette" },
    .{ .tab = 9, .title = "Number of workspaces", .section = "Launcher", .keywords = "launcher workspaces number count slots", .glyph = "view_module" },
    .{ .tab = 9, .title = "Max workspace icons", .section = "Launcher", .keywords = "launcher workspaces max icons", .glyph = "apps" },
    .{ .tab = 9, .title = "Show app icons", .section = "Launcher", .keywords = "launcher workspaces show app icons", .glyph = "apps" },
    .{ .tab = 9, .title = "Live updates", .section = "Launcher", .keywords = "overview live updates stream", .glyph = "play_arrow" },
    .{ .tab = 9, .title = "Multi-monitor", .section = "Launcher", .keywords = "overview multi monitor", .glyph = "monitor" },
    .{ .tab = 9, .title = "Capture mode", .section = "Launcher", .keywords = "overview capture snapshot screencopy", .glyph = "desktop_windows" },
    .{ .tab = 9, .title = "Scroll axis", .section = "Launcher", .keywords = "overview scroll axis vertical horizontal", .glyph = "vertical_split" },
    .{ .tab = 9, .title = "Card scale", .section = "Launcher", .keywords = "overview card scale size", .glyph = "search" },
    .{ .tab = 9, .title = "Card spacing", .section = "Launcher", .keywords = "overview card spacing gap", .glyph = "horizontal_rule" },
    .{ .tab = 9, .title = "Scroll settle delay", .section = "Launcher", .keywords = "overview scroll settle delay ms", .glyph = "schedule" },
    .{ .tab = 9, .title = "Close button size", .section = "Launcher", .keywords = "overview close button size", .glyph = "close" },
    .{ .tab = 9, .title = "Search bar width", .section = "Launcher", .keywords = "overview search width", .glyph = "search" },
    .{ .tab = 29, .title = "Desktop", .section = "Panels & UI", .keywords = "desktop icons menu", .glyph = "desktop_windows" },
    .{ .tab = 27, .title = "Desktop Widgets", .section = "Panels & UI", .keywords = "desktop widgets clock weather", .glyph = "widgets" },
    .{ .tab = 7, .title = "Monitors", .section = "Display", .keywords = "monitors displays resolution refresh", .glyph = "monitor" },
    .{ .tab = 2, .title = "Appearance", .section = "Display", .keywords = "appearance theme matugen colors opacity", .glyph = "palette" },
    .{ .tab = 45, .title = "Themes", .section = "Display", .keywords = "themes gtk qt cursor plasma", .glyph = "palette" },
    .{ .tab = 50, .title = "Color Themes", .section = "Display", .keywords = "color themes custom matugen", .glyph = "colorize" },
    .{ .tab = 44, .title = "Icons", .section = "Display", .keywords = "icons theme", .glyph = "photo_library" },
    .{ .tab = 19, .title = "Nightlight", .section = "Display", .keywords = "night light temperature schedule", .glyph = "dark_mode" },
    .{ .tab = 5, .title = "Notifications", .section = "System", .keywords = "notifications dnd toast banner", .glyph = "notifications" },
    .{ .tab = 8, .title = "Sound", .section = "System", .keywords = "sound audio volume output input", .glyph = "volume_up" },
    .{ .tab = 10, .title = "Default Apps", .section = "System", .keywords = "default apps browser email terminal", .glyph = "app_registration" },
    .{ .tab = 30, .title = "Time", .section = "System", .keywords = "time clock date timezone ntp", .glyph = "schedule" },
    .{ .tab = 31, .title = "Keyboard & Language", .section = "System", .keywords = "keyboard language layout repeat locale", .glyph = "keyboard" },
    .{ .tab = 47, .title = "Bluetooth", .section = "System", .keywords = "bluetooth adapter devices pairing", .glyph = "bluetooth" },
    .{ .tab = 32, .title = "Power", .section = "System", .keywords = "power sleep suspend battery performance", .glyph = "power_settings_new" },
    .{ .tab = 46, .title = "Accounts", .section = "System", .keywords = "accounts users password hostname", .glyph = "account_circle" },
    .{ .tab = 48, .title = "Startup", .section = "System", .keywords = "startup autostart login apps", .glyph = "play_arrow" },
    .{ .tab = 51, .title = "Updates", .section = "System", .keywords = "updates upgrade version release install", .glyph = "system_update" },
    // Updates child options (mirror settings_search.hpp tab-51 rows).
    .{ .tab = 51, .title = "Check for updates", .section = "Updates", .keywords = "updates check github release version", .glyph = "system_update" },
    .{ .tab = 51, .title = "Download update", .section = "Updates", .keywords = "updates download package rpm deb pacman", .glyph = "download" },
    .{ .tab = 51, .title = "Install update", .section = "Updates", .keywords = "updates install pkexec sudo package", .glyph = "install_desktop" },
    .{ .tab = 51, .title = "Restart shell", .section = "Updates", .keywords = "updates restart shell reboot apply", .glyph = "restart_alt" },
    .{ .tab = 51, .title = "Auto-check", .section = "Updates", .keywords = "updates auto check background notify", .glyph = "autorenew" },
    .{ .tab = 6, .title = "Wallpaper", .section = "Wallpaper Settings", .keywords = "wallpaper background image gallery", .glyph = "wallpaper" },
    .{ .tab = 16, .title = "Bing Wallpaper", .section = "Wallpaper Settings", .keywords = "bing wallpaper daily archive", .glyph = "photo_library" },
    .{ .tab = 17, .title = "Wi-Fi", .section = "Network", .keywords = "wifi wireless network", .glyph = "wifi" },
    .{ .tab = 18, .title = "Wired", .section = "Network", .keywords = "wired ethernet ipv4 ipv6", .glyph = "lan" },
    .{ .tab = 28, .title = "VPN", .section = "Network", .keywords = "vpn tunnel", .glyph = "vpn_key" },
    .{ .tab = 33, .title = "Hyprland", .section = "Hyprland", .keywords = "hyprland compositor decoration input binds", .glyph = "view_module" },
    .{ .tab = 20, .title = "MangoWM Decoration", .section = "MangoWM", .keywords = "mango decoration borders opacity", .glyph = "border_style" },
};

fn matches(entry: SearchEntry, query_lower: []const u8) bool {
    if (query_lower.len == 0) return true;
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for ([_][]const u8{ entry.title, entry.section, entry.keywords }) |part| {
        if (len + part.len + 1 >= buf.len) break;
        for (part) |c| {
            if (len >= buf.len) break;
            buf[len] = std.ascii.toLower(c);
            len += 1;
        }
        if (len < buf.len) {
            buf[len] = ' ';
            len += 1;
        }
    }
    return std.mem.indexOf(u8, buf[0..len], query_lower) != null;
}

pub fn collect(alloc: std.mem.Allocator, query: []const u8) ![]i32 {
    var qbuf: [128]u8 = undefined;
    const qlen: usize = @min(query.len, qbuf.len);
    const qlower = std.ascii.lowerString(qbuf[0..qlen], query[0..qlen]);
    var out: std.ArrayList(i32) = .empty;
    errdefer out.deinit(alloc);
    for (entries) |e| {
        if (!@import("compositor.zig").visibleTab(e.tab)) continue;
        if (matches(e, qlower)) try out.append(alloc, e.tab);
    }
    return out.toOwnedSlice(alloc);
}

test "settings-search: geometry follows the specified layout" {
    const t = std.testing;
    const g = searchBarGeom();
    try t.expectEqual(@as(i32, 24), g.x);
    try t.expectEqual(@as(i32, 36), g.h);
    try t.expectEqual(@as(i32, 68), sidebarTabsBaseY());
}

test "settings-search: collect filters" {
    const t = std.testing;
    const all = try collect(t.allocator, "");
    defer t.allocator.free(all);
    var expected: usize = 0;
    for (entries) |e| {
        if (@import("compositor.zig").visibleTab(e.tab)) expected += 1;
    }
    try t.expect(all.len == expected);
    const wifi = try collect(t.allocator, "wifi");
    defer t.allocator.free(wifi);
    try t.expect(wifi.len >= 1);
    try t.expect(wifi[0] == 17);
    const none = try collect(t.allocator, "zzz-no-match");
    defer t.allocator.free(none);
    try t.expectEqual(@as(usize, 0), none.len);
}
