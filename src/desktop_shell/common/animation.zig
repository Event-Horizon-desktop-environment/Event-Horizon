const std = @import("std");

pub fn clamp01(t: f64) f64 {
    return @max(0.0, @min(1.0, t));
}

pub fn linear(t: f64) f64 {
    return clamp01(t);
}

pub fn easeOutCubic(t: f64) f64 {
    const c = clamp01(t);
    return 1.0 - std.math.pow(f64, 1.0 - c, 3.0);
}

pub fn easeInOutCubic(t: f64) f64 {
    const c = clamp01(t);
    if (c < 0.5) return 4.0 * c * c * c;
    return 1.0 - std.math.pow(f64, -2.0 * c + 2.0, 3.0) / 2.0;
}

pub fn lerp(a: f64, b: f64, t: f64, comptime ease: fn (f64) f64) f64 {
    return a + (b - a) * ease(t);
}

pub const Animator = struct {
    from: f64 = 0,
    to: f64 = 1,
    duration_ms: i64 = 250,
    start_ms: i64 = 0,
    running: bool = false,

    pub fn start(self: *Animator, from: f64, to: f64, duration_ms: i64, now_ms: i64) void {
        self.from = from;
        self.to = to;
        self.duration_ms = @max(1, duration_ms);
        self.start_ms = now_ms;
        self.running = true;
    }

    pub fn value(self: *Animator, now_ms: i64) f64 {
        if (!self.running) return self.to;
        const t = @as(f64, @floatFromInt(now_ms - self.start_ms)) / @as(f64, @floatFromInt(self.duration_ms));
        if (t >= 1.0) {
            self.running = false;
            return self.to;
        }
        return lerp(self.from, self.to, t, easeOutCubic);
    }
};

test "animation: curves and animator" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 0.0), easeOutCubic(0.0));
    try t.expectEqual(@as(f64, 1.0), easeOutCubic(1.0));
    try t.expect(easeOutCubic(0.5) > 0.5);
    try t.expectEqual(@as(f64, 0.5), easeInOutCubic(0.5));
    var a = Animator{};
    a.start(0, 100, 1000, 0);
    try t.expectEqual(@as(f64, 0.0), a.value(0));
    try t.expect(a.value(500) > 50.0);
    try t.expectEqual(@as(f64, 100.0), a.value(1000));
    try t.expect(!a.running);
}
