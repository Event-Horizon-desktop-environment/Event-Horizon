const std = @import("std");
const night = @import("nightlight_tab.zig");

// Notifications tab — Zig port of src/ux/settings/settings_tab_notifications/*.
// Same design: DND toggle + timeout/slider + position combo + test button.

pub const Model = night.NotificationsModel;
pub const toast_positions = night.toast_positions;

test "settings-notifications-tab: defaults" {
    const t = std.testing;
    const m = Model{};
    try t.expect(m.dbus_enabled);
    try t.expectEqualStrings("top_right", m.toast_position);
}
