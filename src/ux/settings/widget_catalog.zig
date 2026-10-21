const std = @import("std");

/// Ids the add-widget popup offers. One catalogue for every bar: the dock,
/// taskbar and panel all read the same widget instances, so a section array
/// only ever names ids from this list.
pub const ids = [_][]const u8{
    "pinned_apps",
    "running_apps",
    "win7_tasks",
    "tray",
    "settings_button",
    "app_menu",
    "app_drawer",
    "smenu",
    "distro_spotlight",
    "clock",
    "weather",
    "media",
    "workspaces",
    "world_clock",
    "control_center",
    "pear_center",
    "notifications",
    "overview",
    "spacer",
    "trash",
    "volume_mixer",
    "vpn",
    "battery",
    "bluetooth",
    // `kDockWidgetPickIds` in the C++ keeps it last too.
    "layout",
};

pub fn contains(needle: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, needle)) return true;
    }
    return false;
}

test "widget-catalog: unique and searchable" {
    const t = std.testing;
    try t.expect(ids.len > 10);
    for (ids, 0..) |id, i| {
        for (ids[i + 1 ..]) |other| try t.expect(!std.mem.eql(u8, id, other));
    }
    try t.expect(contains("media"));
    try t.expect(!contains("no_such_widget"));
}
