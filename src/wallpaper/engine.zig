const std = @import("std");

pub const Mode = enum { image, folder, bing, off, video };

pub const Engine = struct {
    mode: Mode = .image,
    current: []const u8 = "",
    error_count: u32 = 0,
    last_apply_ms: i64 = 0,

    pub fn requestSet(self: *Engine, path: []const u8, now_ms: i64) void {
        self.current = path;
        self.last_apply_ms = now_ms;
        self.error_count = 0;
    }

    pub fn reportError(self: *Engine) void {
        self.error_count += 1;
    }

    pub fn backoffMs(self: *const Engine) u64 {
        return switch (self.error_count) {
            0 => 0,
            1 => 1000,
            2 => 5000,
            else => 30000,
        };
    }
};

test "wallpaper-engine: set + backoff" {
    const t = std.testing;
    var e = Engine{};
    e.requestSet("/a.png", 100);
    try t.expectEqualStrings("/a.png", e.current);
    try t.expectEqual(@as(u64, 0), e.backoffMs());
    e.reportError();
    e.reportError();
    try t.expectEqual(@as(u64, 5000), e.backoffMs());
}
