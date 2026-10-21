const std = @import("std");

// Slider appliers.
// Pure-logic mapping from slider pixel position to setting value and back,
// shared by every tab so drag physics never diverge per tab.

pub const SliderSpec = struct {
    min_v: i32,
    max_v: i32,
    track_x: i32,
    track_w: i32,
};

pub fn valueFromX(spec: SliderSpec, px: f64) i32 {
    if (spec.track_w <= 0) return spec.min_v;
    var t: f64 = (px - @as(f64, @floatFromInt(spec.track_x))) / @as(f64, @floatFromInt(spec.track_w));
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    const span: f64 = @floatFromInt(spec.max_v - spec.min_v);
    return spec.min_v + @as(i32, @intFromFloat(@round(t * span)));
}

pub fn normFromValue(spec: SliderSpec, v: i32) f64 {
    if (spec.max_v <= spec.min_v) return 0;
    const span: f64 = @floatFromInt(spec.max_v - spec.min_v);
    const off: f64 = @floatFromInt(v - spec.min_v);
    const t = off / span;
    if (t < 0) return 0;
    if (t > 1) return 1;
    return t;
}

pub fn xFromValue(spec: SliderSpec, v: i32) f64 {
    return @as(f64, @floatFromInt(spec.track_x)) + normFromValue(spec, v) * @as(f64, @floatFromInt(spec.track_w));
}

pub fn clampOpacityPct(v: i32) i32 {
    return @max(0, @min(100, v));
}

pub fn clampVolumePct(v: i32, allow_overamp: bool) i32 {
    const hi: i32 = if (allow_overamp) 150 else 100;
    return @max(@as(i32, 0), @min(hi, v));
}

test "settings-slider-appliers: round-trip" {
    const t = std.testing;
    const spec = SliderSpec{ .min_v = 0, .max_v = 100, .track_x = 10, .track_w = 200 };
    try t.expectEqual(@as(i32, 50), valueFromX(spec, 110));
    try t.expectApproxEqAbs(@as(f64, 0.5), normFromValue(spec, 50), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 110), xFromValue(spec, 50), 1e-9);
    try t.expectEqual(@as(i32, 100), clampOpacityPct(999));
    try t.expectEqual(@as(i32, 150), clampVolumePct(999, true));
    try t.expectEqual(@as(i32, 100), clampVolumePct(999, false));
}
