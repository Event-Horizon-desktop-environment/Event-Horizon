const std = @import("std");
const launcher = @import("launcher_tab.zig");

// Task Switcher tab.
// Same design: gallery-style toggle + MRU + caption/count/icons toggles.

pub const Model = launcher.TaskflipModel;

test "settings-taskflip-tab: defaults" {
    const t = std.testing;
    const m = Model{};
    try t.expect(m.gallery_style and m.mru_order);
}
