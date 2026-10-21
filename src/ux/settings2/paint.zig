const std = @import("std");
const app_mod = @import("app.zig");

// Paint dispatch.
// (paint_dock_tab / ... per activeTab).
// Same design: tab id selects the painter; sidebar + search + content cards
// share the 900x980 / 260px-sidebar geometry. This file owns the routing
// table so paint, hit-test, and scroll-clamp can never disagree on ids.

pub const Painter = enum {
    dock,
    panel,
    taskbar,
    launcher,
    desktop,
    desktop_widgets,
    monitors,
    appearance,
    themes,
    color_themes,
    icons,
    nightlight,
    mango,
    hyprland,
    notifications,
    sound,
    default_apps,
    time,
    keyboard,
    bluetooth,
    power,
    accounts,
    autostart,
    wallpaper,
    bing,
    wifi,
    wired,
    vpn,
    workspaces,
    taskflip,
    dashboard,
    live_wallpaper,
    updater,
    unknown,
};

pub fn painterFor(tab: i32) Painter {
    return switch (tab) {
        0 => .dock,
        1 => .panel,
        11 => .taskbar,
        9 => .launcher,
        29 => .desktop,
        27 => .desktop_widgets,
        7 => .monitors,
        2 => .appearance,
        // The Appearance category's Opacity (79) and Color (80) pages route
        // like General (2).
        79, 80 => .appearance,
        45 => .themes,
        50 => .color_themes,
        44 => .icons,
        19 => .nightlight,
        20, 21, 22, 23, 24, 25, 26 => .mango,
        33 => .hyprland,
        5 => .notifications,
        8 => .sound,
        10 => .default_apps,
        30 => .time,
        31 => .keyboard,
        47 => .bluetooth,
        32 => .power,
        46 => .accounts,
        48 => .autostart,
        51 => .updater,
        6 => .wallpaper,
        34 => .bing,
        17 => .wifi,
        18 => .wired,
        28 => .vpn,
        61 => .workspaces,
        60 => .taskflip,
        62 => .dashboard,
        63 => .live_wallpaper,
        else => .unknown,
    };
}

pub fn needsPipewire(tab: i32) bool {
    return painterFor(tab) == .sound;
}

pub fn needsBluetooth(tab: i32) bool {
    return painterFor(tab) == .bluetooth;
}

pub fn isCompositorTab(tab: i32) bool {
    const p = painterFor(tab);
    return p == .mango or p == .hyprland;
}

test "settings-paint: dispatch covers every branch" {
    const t = std.testing;
    try t.expectEqual(Painter.dock, painterFor(0));
    try t.expectEqual(Painter.appearance, painterFor(79));
    try t.expectEqual(Painter.appearance, painterFor(80));
    try t.expectEqual(Painter.mango, painterFor(24));
    try t.expectEqual(Painter.hyprland, painterFor(33));
    try t.expectEqual(Painter.unknown, painterFor(999));
    try t.expect(needsPipewire(8));
    try t.expect(!needsPipewire(0));
    try t.expect(isCompositorTab(20));
    try t.expect(!isCompositorTab(5));
    try t.expectEqualStrings("Dock", app_mod.tabTitle(0).?);
}
