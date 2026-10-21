const std = @import("std");

pub const dock_left = [_][]const u8{ "smenu", "media" };
pub const dock_center = [_][]const u8{ "app_drawer", "pinned_apps", "running_apps", "trash" };
pub const dock_right = [_][]const u8{ "tray", "weather", "clock", "pear_center", "settings_button" };

pub const taskbar_left = [_][]const u8{ "smenu", "win7_tasks" };
pub const taskbar_center = [_][]const u8{};
pub const taskbar_right = [_][]const u8{ "tray", "weather", "clock", "pear_center", "settings_button" };


test "widget-defaults: every bar has a left and right" {
    const t = std.testing;
    try t.expect(dock_left.len > 0);
    try t.expect(dock_center.len > 0);
    try t.expect(dock_right.len > 0);
    try t.expect(taskbar_left.len > 0);
    try t.expect(taskbar_right.len > 0);
}
