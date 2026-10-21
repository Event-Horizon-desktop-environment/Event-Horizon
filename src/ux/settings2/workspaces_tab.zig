const std = @import("std");
const launcher = @import("launcher_tab.zig");

// Workspaces tab.
// Same layout as launcher child: slot-count slider + show-apps toggle.
// Logic lives in launcher_tab.WorkspacesModel; this file is the 1:1 tab home.

pub const Model = launcher.WorkspacesModel;

test "settings-workspaces-tab: clamp" {
    const t = std.testing;
    var m = Model{};
    m.clampAll();
    try t.expectEqual(@as(i32, 5), m.max_slots);
}
