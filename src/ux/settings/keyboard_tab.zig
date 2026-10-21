const std = @import("std");

pub const Model = struct {
    layouts: [4][]const u8 = .{ "", "", "", "" },
    count: usize = 0,
    active: usize = 0,
    test_text: []const u8 = "",

    pub fn setLayouts(self: *Model, layouts: []const []const u8) void {
        self.count = @min(layouts.len, 4);
        for (layouts[0..self.count], 0..) |l, i| self.layouts[i] = l;
        if (self.active >= self.count and self.count > 0) self.active = 0;
    }

    pub fn cycle(self: *Model) void {
        if (self.count == 0) return;
        self.active = (self.active + 1) % self.count;
    }

    pub fn activeLayout(self: *const Model) []const u8 {
        if (self.active < self.count) return self.layouts[self.active];
        return "";
    }
};

test "settings-keyboard: cycle layouts" {
    const t = std.testing;
    var m = Model{};
    m.setLayouts(&[_][]const u8{ "us", "de" });
    try t.expectEqualStrings("us", m.activeLayout());
    m.cycle();
    try t.expectEqualStrings("de", m.activeLayout());
    m.cycle();
    try t.expectEqualStrings("us", m.activeLayout());
}
