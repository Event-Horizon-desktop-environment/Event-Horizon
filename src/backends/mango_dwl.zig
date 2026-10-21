const std = @import("std");

pub const Tag = struct {
    index: u32,
    active: bool = false,
    urgent: bool = false,
    count: u32 = 0,
};

pub const State = struct {
    tags: [32]Tag,
    layout: []const u8 = "[]=",
    title: []const u8 = "",

    pub fn init() State {
        var s = State{ .tags = undefined };
        for (&s.tags, 0..) |*t, i| t.* = .{ .index = @intCast(i) };
        return s;
    }

    pub fn activeTag(self: *const State) ?u32 {
        for (self.tags) |t| {
            if (t.active) return t.index;
        }
        return null;
    }
};

test "dwl-ipc: tag model" {
    const t = std.testing;
    var s = State.init();
    s.tags[2].active = true;
    s.tags[2].count = 3;
    try t.expectEqual(@as(?u32, 2), s.activeTag());
    try t.expectEqual(@as(u32, 3), s.tags[2].count);
}
