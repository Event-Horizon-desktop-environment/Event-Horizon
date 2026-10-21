//! material-color-utilities `cpp/utils`: ARGB helpers, sRGB transfer
//! functions, CIE L\\* and the small math kit everything else builds on.
//! Direct port of `third_party/material-color-utilities/cpp/utils/utils.cc`.
//!
//! Bit-parity notes:
//!   * `sanitizeDegreesDouble` uses `@rem` (C `fmod`/truncated semantics);
//!     `@mod` would floor and diverge for negatives.
//!   * `delinearized` rounds half away from zero via `@round`, like C `round`.

const std = @import("std");
const libm = @import("libm.zig");

pub const Argb = u32;

pub const Vec3 = struct { a: f64 = 0.0, b: f64 = 0.0, c: f64 = 0.0 };

pub const k_pi: f64 = 3.141592653589793;
pub const k_white_point_d65 = [_]f64{ 95.047, 100.0, 108.883 };

pub fn redFromInt(argb: Argb) u8 {
    return @intCast((argb & 0x00ff0000) >> 16);
}

pub fn greenFromInt(argb: Argb) u8 {
    return @intCast((argb & 0x0000ff00) >> 8);
}

pub fn blueFromInt(argb: Argb) u8 {
    return @intCast(argb & 0x000000ff);
}

pub fn alphaFromInt(argb: Argb) u8 {
    return @intCast((argb & 0xff000000) >> 24);
}

pub fn argbFromRgb(r: i32, g: i32, b: i32) Argb {
    return 0xFF000000 |
        (@as(u32, @intCast(r & 0xff)) << 16) |
        (@as(u32, @intCast(g & 0xff)) << 8) |
        @as(u32, @intCast(b & 0xff));
}

pub fn argbFromLinrgb(lin: Vec3) Argb {
    const r = delinearized(lin.a);
    const g = delinearized(lin.b);
    const b = delinearized(lin.c);
    return 0xFF000000 |
        (@as(u32, @intCast(r & 0x0ff)) << 16) |
        (@as(u32, @intCast(g & 0x0ff)) << 8) |
        @as(u32, @intCast(b & 0x0ff));
}

pub fn isOpaque(argb: Argb) bool {
    return alphaFromInt(argb) == 255;
}

pub fn delinearized(rgb_component: f64) i32 {
    const normalized = rgb_component / 100.0;
    const d = if (normalized <= 0.0031308)
        normalized * 12.92
    else
        1.055 * libm.pow(normalized, 1.0 / 2.4) - 0.055;
    return std.math.clamp(@as(i32, @intFromFloat(@round(d * 255.0))), 0, 255);
}

pub fn linearized(rgb_component: i32) f64 {
    const normalized: f64 = @as(f64, @floatFromInt(rgb_component)) / 255.0;
    if (normalized <= 0.040449936) {
        return normalized / 12.92 * 100.0;
    }
    return libm.pow((normalized + 0.055) / 1.055, 2.4) * 100.0;
}

pub fn lstarFromArgb(argb: Argb) f64 {
    const r = linearized(@as(i32, redFromInt(argb)));
    const g = linearized(@as(i32, greenFromInt(argb)));
    const b = linearized(@as(i32, blueFromInt(argb)));
    return lstarFromY(0.2126 * r + 0.7152 * g + 0.0722 * b);
}

pub fn yFromLstar(lstar: f64) f64 {
    if (lstar > 8.0) {
        const c = (lstar + 16.0) / 116.0;
        return c * c * c * 100.0;
    }
    return lstar / (24389.0 / 27.0) * 100.0;
}

pub fn lstarFromY(y: f64) f64 {
    const yn = y / 100.0;
    if (yn <= 216.0 / 24389.0) {
        return (24389.0 / 27.0) * yn;
    }
    return 116.0 * libm.pow(yn, 1.0 / 3.0) - 16.0;
}

pub fn intFromLstar(lstar: f64) Argb {
    const c = delinearized(yFromLstar(lstar));
    return argbFromRgb(c, c, c);
}

/// Lowercase, unpadded, no prefix (`absl::Hex` defaults): `0xff012345` → "ff012345".
pub fn hexFromArgb(argb: Argb, out: []u8) []u8 {
    var v: u64 = argb;
    if (v == 0) {
        out[0] = '0';
        return out[0..1];
    }
    var len: usize = 0;
    var t = v;
    while (t != 0) : (t >>= 4) len += 1;
    const digits = "0123456789abcdef";
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        out[i] = digits[v & 0xF];
        v >>= 4;
    }
    return out[0..len];
}

pub fn sanitizeDegreesInt(degrees: i32) i32 {
    // Integer `%` truncates toward zero: `@rem`, not `@mod`.
    if (degrees < 0) {
        return @rem(degrees, 360) + 360;
    } else if (degrees >= 360) {
        return @rem(degrees, 360);
    }
    return degrees;
}

pub fn sanitizeDegreesDouble(degrees: f64) f64 {
    if (degrees < 0.0) {
        return @rem(degrees, 360.0) + 360.0;
    } else if (degrees >= 360.0) {
        return @rem(degrees, 360.0);
    }
    return degrees;
}

pub fn diffDegrees(a: f64, b: f64) f64 {
    return 180.0 - @abs(@abs(a - b) - 180.0);
}

pub fn rotationDirection(from: f64, to: f64) f64 {
    return if (sanitizeDegreesDouble(to - from) <= 180.0) 1.0 else -1.0;
}

pub fn signum(num: f64) i32 {
    if (num < 0.0) return -1;
    if (num == 0.0) return 0;
    return 1;
}

pub fn lerp(start: f64, stop: f64, amount: f64) f64 {
    return (1.0 - amount) * start + amount * stop;
}

pub fn matrixMultiply(in: Vec3, matrix: [3][3]f64) Vec3 {
    return .{
        .a = in.a * matrix[0][0] + in.b * matrix[0][1] + in.c * matrix[0][2],
        .b = in.a * matrix[1][0] + in.b * matrix[1][1] + in.c * matrix[1][2],
        .c = in.a * matrix[2][0] + in.b * matrix[2][1] + in.c * matrix[2][2],
    };
}

// Expected values from the reference oracle,
// section), printed with the same `%.6f` formatting the driver uses.

test "mcu-utils: channels and lowercase hex" {
    const t = std.testing;
    try t.expectEqual(@as(u8, 1), redFromInt(0xFF012345));
    try t.expectEqual(@as(u8, 35), greenFromInt(0xFF012345));
    try t.expectEqual(@as(u8, 69), blueFromInt(0xFF012345));
    try t.expectEqual(@as(u8, 255), alphaFromInt(0xFF012345));
    try t.expect(isOpaque(0xFF012345));
    try t.expect(!isOpaque(0x80012345));
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("ff012345", hexFromArgb(0xFF012345, &buf));
    try t.expectEqualStrings("ff000000", hexFromArgb(0xFF000000, &buf));
    try t.expectEqualStrings("ffffffff", hexFromArgb(0xFFFFFFFF, &buf));
    try t.expectEqual(@as(Argb, 0xFF4285F4), argbFromRgb(0x42, 0x85, 0xF4));
}

test "mcu-utils: transfer functions against the oracle" {
    const t = std.testing;
    // L* of the oracle colors.
    try t.expectApproxEqAbs(0.0, lstarFromArgb(0xFF000000), 1e-6);
    try t.expectApproxEqAbs(100.0, lstarFromArgb(0xFFFFFFFF), 1e-6);
    try t.expectApproxEqAbs(56.550349, lstarFromArgb(0xFF4285F4), 1e-6);
    try t.expectApproxEqAbs(26.843491, lstarFromArgb(0xFF563925), 1e-6);
    try t.expectApproxEqAbs(13.460891, lstarFromArgb(0xFF012345), 1e-6);
    // Linearized spot values.
    try t.expectApproxEqAbs(0.0, linearized(0), 1e-6);
    try t.expectApproxEqAbs(0.303527, linearized(10), 1e-6);
    try t.expectApproxEqAbs(21.586050, linearized(128), 1e-6);
    try t.expectApproxEqAbs(57.758044, linearized(200), 1e-6);
    try t.expectApproxEqAbs(100.0, linearized(255), 1e-6);
    // Delinearized spot values.
    try t.expectEqual(@as(i32, 0), delinearized(0.0));
    try t.expectEqual(@as(i32, 16), delinearized(0.5));
    try t.expectEqual(@as(i32, 63), delinearized(5.0));
    try t.expectEqual(@as(i32, 188), delinearized(50.0));
    try t.expectEqual(@as(i32, 255), delinearized(100.0));
    // Y <-> L*.
    try t.expectApproxEqAbs(0.0, yFromLstar(0.0), 1e-6);
    try t.expectApproxEqAbs(0.885645, yFromLstar(8.0), 1e-6);
    try t.expectApproxEqAbs(2.518041, yFromLstar(18.0), 1e-6);
    try t.expectApproxEqAbs(18.418652, yFromLstar(50.0), 1e-6);
    try t.expectApproxEqAbs(100.0, yFromLstar(100.0), 1e-6);
    try t.expectEqual(@as(Argb, 0xFF000000), intFromLstar(0.0));
    try t.expectEqual(@as(Argb, 0xFF181818), intFromLstar(8.0));
    try t.expectEqual(@as(Argb, 0xFF2C2C2C), intFromLstar(18.0));
    try t.expectEqual(@as(Argb, 0xFF777777), intFromLstar(50.0));
    try t.expectEqual(@as(Argb, 0xFFFFFFFF), intFromLstar(100.0));
    try t.expectApproxEqAbs(0.0, lstarFromY(0.0), 1e-6);
    try t.expectApproxEqAbs(4.516481, lstarFromY(0.5), 1e-6);
    try t.expectApproxEqAbs(49.496108, lstarFromY(18.0), 1e-6);
    try t.expectApproxEqAbs(76.069261, lstarFromY(50.0), 1e-6);
    try t.expectApproxEqAbs(100.0, lstarFromY(100.0), 1e-6);
}

test "mcu-utils: degree sanitizers, diff, rotation, lerp" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 350), sanitizeDegreesInt(-10));
    try t.expectEqual(@as(i32, 10), sanitizeDegreesInt(370));
    try t.expectEqual(@as(i32, 0), sanitizeDegreesInt(0));
    try t.expectApproxEqAbs(314.5, sanitizeDegreesDouble(-45.5), 1e-9);
    try t.expectApproxEqAbs(0.25, sanitizeDegreesDouble(720.25), 1e-9);
    try t.expectApproxEqAbs(20.0, diffDegrees(10.0, 350.0), 1e-9);
    try t.expectApproxEqAbs(-1.0, rotationDirection(10.0, 350.0), 1e-9);
    try t.expectApproxEqAbs(1.0, rotationDirection(350.0, 10.0), 1e-9);
    try t.expectApproxEqAbs(12.5, lerp(10.0, 20.0, 0.25), 1e-9);
    try t.expectEqual(@as(i32, -1), signum(-0.5));
    try t.expectEqual(@as(i32, 0), signum(0.0));
    try t.expectEqual(@as(i32, 1), signum(2.0));
}


