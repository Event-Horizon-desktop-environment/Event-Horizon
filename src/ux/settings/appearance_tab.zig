const std = @import("std");

pub const OpacityRow = struct {
    key: []const u8,
    value_pct: i32 = 100,
};

pub const Model = struct {
    theme: []const u8 = "system",
    dark_mode: bool = true,
    opacities: [6]OpacityRow = .{
        .{ .key = "dock" },     .{ .key = "panel" },         .{ .key = "menus" },
        .{ .key = "overview" }, .{ .key = "notifications" }, .{ .key = "tooltip" },
    },
    scale_pct: i32 = 100,

    pub fn setOpacity(self: *Model, key: []const u8, pct: i32) bool {
        for (&self.opacities) |*o| {
            if (std.mem.eql(u8, o.key, key)) {
                o.value_pct = @max(0, @min(100, pct));
                return true;
            }
        }
        return false;
    }
};

test "settings-appearance: opacity rows" {
    const t = std.testing;
    var m = Model{};
    try t.expect(m.setOpacity("dock", 80));
    try t.expectEqual(@as(i32, 80), m.opacities[0].value_pct);
    try t.expect(m.setOpacity("dock", 999));
    try t.expectEqual(@as(i32, 100), m.opacities[0].value_pct);
    try t.expect(!m.setOpacity("nope", 50));
}
