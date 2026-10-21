const std = @import("std");

pub const SliderId = enum { volume, mic, brightness, night_temp };

pub const Slider = struct {
    id: SliderId,
    min: f64 = 0,
    max: f64 = 100,
    value: f64 = 50,
    step: f64 = 5,

    pub fn nudge(self: *Slider, dir: i32) f64 {
        self.value = @max(self.min, @min(self.max, self.value + @as(f64, @floatFromInt(dir)) * self.step));
        return self.value;
    }

    pub fn set(self: *Slider, v: f64) void {
        self.value = @max(self.min, @min(self.max, v));
    }
};

pub const MixerChannel = struct {
    name: []const u8,
    volume: f64 = 100,
    muted: bool = false,
};

pub fn toggleMute(muted: *bool) bool {
    muted.* = !muted.*;
    return muted.*;
}

test "cc-sliders: nudge clamp + mute" {
    const t = std.testing;
    var s = Slider{ .id = .volume };
    try t.expectEqual(@as(f64, 55.0), s.nudge(1));
    s.set(200);
    try t.expectEqual(@as(f64, 100.0), s.value);
    var m = false;
    try t.expect(toggleMute(&m));
    try t.expect(!toggleMute(&m));
}
