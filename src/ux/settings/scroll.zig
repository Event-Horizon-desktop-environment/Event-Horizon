const std = @import("std");

// Frame-synced vertical scroll controller — exact Zig port of
// src/ux/settings/utils/scroll/settings_scroll_controller.hpp.
// Tabs never do scroll math directly: they feed content bounds via setMax
// and wheel deltas via scrollBy; easing/clamping/paint offset live here.
// Easing is wall-clock exponential decay (tau 40ms) so 60/120/144Hz animate
// identically. tick() is called once per compositor frame callback.

pub const tau_ms: f64 = 40.0;

pub const ScrollController = struct {
    current: f64 = 0.0,
    target: f64 = 0.0,
    anim_from: f64 = 0.0,
    anim_start_ns: u64 = 0,
    max_px: i32 = 0,
    animating: bool = false,
    now_ns_fn: ?*const fn () u64 = null,

    fn nowNs(self: *const ScrollController) u64 {
        if (self.now_ns_fn) |f| return f();
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
        if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
        const s: u64 = @intCast(@max(ts.sec, 0));
        const n: u64 = @intCast(@max(ts.nsec, 0));
        return s * std.time.ns_per_s + n;
    }

    pub fn setMax(self: *ScrollController, max_px: i32) void {
        const m: i32 = @max(0, max_px);
        self.max_px = m;
        const bound: f64 = @floatFromInt(m);
        if (self.target > bound) self.target = bound;
        if (self.current > bound) {
            self.current = bound;
            self.anim_from = bound;
            self.animating = false;
        }
    }

    pub fn snapTo(self: *ScrollController, px: f64) void {
        const v: f64 = @max(0.0, px);
        self.target = v;
        self.current = v;
        self.anim_from = v;
        self.animating = false;
    }

    pub fn scrollTo(self: *ScrollController, px: f64) void {
        const bound: f64 = @floatFromInt(self.max_px);
        const nt: f64 = @min(@max(px, 0.0), bound);
        if (@abs(nt - self.current) < 0.01) {
            self.target = nt;
            self.animating = false;
            return;
        }
        if (@abs(nt - self.target) < 0.01) return;
        self.anim_from = self.current;
        self.anim_start_ns = self.nowNs();
        self.target = nt;
        self.animating = true;
    }

    pub fn scrollBy(self: *ScrollController, delta_px: f64) void {
        self.scrollTo(self.target - delta_px);
    }

    pub fn tick(self: *ScrollController) void {
        if (!self.animating) return;
        const now = self.nowNs();
        const elapsed_ms: f64 = @as(f64, @floatFromInt(now -% self.anim_start_ns)) / 1_000_000.0;
        const factor: f64 = 1.0 - std.math.exp(-elapsed_ms / tau_ms);
        self.current = self.anim_from + (self.target - self.anim_from) * factor;
        if (@abs(self.target - self.current) <= 0.5) {
            self.current = self.target;
            self.animating = false;
        }
    }

    pub fn currentPx(self: *const ScrollController) i32 {
        return @intFromFloat(@round(self.current));
    }
};

var fake_now: u64 = 0;
fn fakeNow() u64 {
    return fake_now;
}

test "settings-scroll: clamp + snap + wheel" {
    const t = std.testing;
    var s = ScrollController{};
    s.setMax(1000);
    s.snapTo(100);
    try t.expectEqual(@as(i32, 100), s.currentPx());
    s.scrollBy(-50); // wheel down -> target grows
    try t.expect(s.target > 100);
    s.setMax(50);
    try t.expect(s.target <= 50.1);
    try t.expect(s.current <= 50.1);
}

test "settings-scroll: easing converges with fake clock" {
    const t = std.testing;
    var s = ScrollController{ .now_ns_fn = fakeNow };
    fake_now = 0;
    s.setMax(2000);
    s.snapTo(0);
    fake_now = 0;
    s.scrollTo(1000);
    try t.expect(s.animating);
    fake_now = 500 * 1_000_000; // 500ms >> tau
    s.tick();
    try t.expect(!s.animating);
    try t.expectEqual(@as(i32, 1000), s.currentPx());
}
