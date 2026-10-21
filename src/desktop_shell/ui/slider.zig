const std = @import("std");

pub const Slider = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    min: f64 = 0.0,
    max: f64 = 100.0,
    value: f64 = 0.0,
    dragging: bool = false,

    pub fn setValue(self: *Slider, v: f64) void {
        self.value = @max(self.min, @min(self.max, v));
    }

    pub fn ratio(self: *const Slider) f64 {
        if (self.max <= self.min) return 0.0;
        return (self.value - self.min) / (self.max - self.min);
    }

    pub fn knobX(self: *const Slider) i32 {
        return self.x + @as(i32, @intFromFloat(@round(self.ratio() * @as(f64, @floatFromInt(self.w)))));
    }

    pub fn dragTo(self: *Slider, px: i32) void {
        if (self.w <= 0) return;
        const r = @as(f64, @floatFromInt(px - self.x)) / @as(f64, @floatFromInt(self.w));
        self.setValue(self.min + r * (self.max - self.min));
    }

    pub fn onPress(self: *Slider, px: i32, py: i32) bool {
        _ = py;
        if (px < self.x or px > self.x + self.w) return false;
        self.dragging = true;
        self.dragTo(px);
        return true;
    }

    pub fn onRelease(self: *Slider) void {
        self.dragging = false;
    }
};

test "slider: value mapping and clamps" {
    const t = std.testing;
    var s = Slider{ .x = 0, .w = 200, .min = 0, .max = 50, .value = 25 };
    try t.expectEqual(@as(f64, 0.5), s.ratio());
    try t.expectEqual(@as(i32, 100), s.knobX());
    s.dragTo(200);
    try t.expectEqual(@as(f64, 50.0), s.value);
    s.dragTo(-50);
    try t.expectEqual(@as(f64, 0.0), s.value);
    try t.expect(!s.onPress(500, 0));
    try t.expect(s.onPress(100, 0));
    try t.expect(s.dragging);
}
