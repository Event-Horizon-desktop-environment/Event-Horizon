const std = @import("std");

pub const Rgb = struct {
    r: f64,
    g: f64,
    b: f64,
};

pub fn blend(a: Rgb, b: Rgb, t: f64) Rgb {
    const c = @max(0.0, @min(1.0, t));
    return .{
        .r = a.r + (b.r - a.r) * c,
        .g = a.g + (b.g - a.g) * c,
        .b = a.b + (b.b - a.b) * c,
    };
}

pub fn average(pixels: []const Rgb) Rgb {
    if (pixels.len == 0) return .{ .r = 0, .g = 0, .b = 0 };
    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;
    for (pixels) |p| {
        r += p.r;
        g += p.g;
        b += p.b;
    }
    const n: f64 = @floatFromInt(pixels.len);
    return .{ .r = r / n, .g = g / n, .b = b / n };
}

pub fn luminance(c: Rgb) f64 {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

pub fn contrastRatio(a: Rgb, b: Rgb) f64 {
    const l1 = luminance(a);
    const l2 = luminance(b);
    const hi = @max(l1, l2);
    const lo = @min(l1, l2);
    return (hi + 0.05) / (lo + 0.05);
}

test "palette-blend: average + contrast" {
    const t = std.testing;
    const ps = [_]Rgb{ .{ .r = 1, .g = 0, .b = 0 }, .{ .r = 0, .g = 0, .b = 1 } };
    const avg = average(&ps);
    try t.expectEqual(@as(f64, 0.5), avg.r);
    const m = blend(.{ .r = 0, .g = 0, .b = 0 }, .{ .r = 1, .g = 1, .b = 1 }, 0.5);
    try t.expectEqual(@as(f64, 0.5), m.r);
    try t.expect(contrastRatio(.{ .r = 1, .g = 1, .b = 1 }, .{ .r = 0, .g = 0, .b = 0 }) > 20.0);
}
