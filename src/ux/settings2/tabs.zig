const std = @import("std");

pub const Tab = struct {
    id: []const u8,
    title: []const u8,
};

pub const all_tabs = [_]Tab{
    .{ .id = "appearance", .title = "Appearance" },
    .{ .id = "sound", .title = "Sound" },
    .{ .id = "network", .title = "Network" },
    .{ .id = "bluetooth", .title = "Bluetooth" },
    .{ .id = "keyboard", .title = "Keyboard" },
    .{ .id = "dock", .title = "Dock" },
    .{ .id = "taskbar", .title = "Taskbar" },
    .{ .id = "panel", .title = "Panel" },
    .{ .id = "wallpaper", .title = "Wallpaper" },
    .{ .id = "notifications", .title = "Notifications" },
    .{ .id = "power", .title = "Power" },
    .{ .id = "monitors", .title = "Monitors" },
    .{ .id = "time", .title = "Time" },
    .{ .id = "nightlight", .title = "Night Light" },
    .{ .id = "autostart", .title = "Autostart" },
    .{ .id = "default_apps", .title = "Default Apps" },
    .{ .id = "desktop", .title = "Desktop" },
    .{ .id = "launcher", .title = "Launcher" },
    .{ .id = "workspaces", .title = "Workspaces" },
    .{ .id = "icons", .title = "Icons" },
    .{ .id = "themes", .title = "Color Themes" },
    .{ .id = "accounts", .title = "Accounts" },
    .{ .id = "taskflip", .title = "Task Switcher" },
    .{ .id = "bing", .title = "Bing Wallpaper" },
    .{ .id = "hyprland", .title = "Hyprland" },
    .{ .id = "mango", .title = "Mango" },
    .{ .id = "desktop_widgets", .title = "Desktop Widgets" },
    .{ .id = "updates", .title = "Updates" },
};

pub fn find(id: []const u8) ?Tab {
    for (all_tabs) |tab| {
        if (std.mem.eql(u8, tab.id, id)) return tab;
    }
    return null;
}

test "settings-tabs: registry complete" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 28), all_tabs.len);
    try t.expectEqualStrings("Sound", find("sound").?.title);
    try t.expectEqualStrings("Updates", find("updates").?.title);
    try t.expect(find("nope") == null);
}
