const std = @import("std");
const launcher = @import("launcher_tab.zig");

// Dashboard tab.
// Same design: enable toggle + columns/gap sliders.

pub const Model = launcher.DashboardModel;

test "settings-dashboard-tab: clamp" {
    const t = std.testing;
    var m = Model{};
    m.clampAll();
    try t.expectEqual(@as(i32, 4), m.columns);
}
