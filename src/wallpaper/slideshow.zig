const std = @import("std");

pub const Mode = enum { image, folder, off };

pub const State = struct {
    mode: Mode = .image,
    image_path: []const u8 = "",
    folder: []const u8 = "",
    interval_sec: u32 = 300,
    last_switch_ms: i64 = 0,
    index: usize = 0,

    pub fn shouldAdvance(self: *const State, now_ms: i64) bool {
        if (self.mode != .folder) return false;
        if (self.interval_sec == 0) return false;
        return now_ms - self.last_switch_ms >= @as(i64, self.interval_sec) * 1000;
    }

    pub fn advanced(self: *State, now_ms: i64, count: usize) void {
        if (count == 0) return;
        self.index = (self.index + 1) % count;
        self.last_switch_ms = now_ms;
    }
};

test "wallpaper-slideshow: advance timing and wrap" {
    const t = std.testing;
    var s = State{ .mode = .folder, .interval_sec = 60 };
    try t.expect(!s.shouldAdvance(59 * 1000));
    try t.expect(s.shouldAdvance(61 * 1000));
    s.advanced(61 * 1000, 3);
    try t.expectEqual(@as(usize, 1), s.index);
    s.advanced(130 * 1000, 3);
    s.advanced(200 * 1000, 3);
    try t.expectEqual(@as(usize, 0), s.index);
    var off = State{ .mode = .off };
    try t.expect(!off.shouldAdvance(999999999));
}
