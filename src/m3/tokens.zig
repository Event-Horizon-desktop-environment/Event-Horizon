//! The shell's *static* token palette — the handful of hardcoded colours,
//! corner radii and spacing steps the dock, taskbar and panel paints read.
//!
//! This is deliberately not the same thing as the M3 token system ported
//! under `m3/tokens/` (`color`, `shape`, `spacing`, `motion`, `elevation`,
//! `type_scale`). Those model Material 3's *dynamic* system, where every
//! colour is a semantic role resolved from a source colour at runtime. This
//! file is the opposite: a fixed palette chosen once, with no theme engine
//! behind it, because the desktop shell paints with a small set of constants.
//!
//! The two coexist by design. A control that wants the full M3 model imports
//! `m3/tokens/<family>.zig`; a widget pill that just needs "the surface
//! colour" imports this. They share no state and must not be conflated.

const std = @import("std");

pub const Rgb = struct {
    r: f64,
    g: f64,
    b: f64,
};

pub const Tokens = struct {
    pub const background = Rgb{ .r = 0.11, .g = 0.11, .b = 0.13 };
    pub const surface = Rgb{ .r = 0.16, .g = 0.16, .b = 0.19 };
    pub const accent = Rgb{ .r = 0.90, .g = 0.90, .b = 0.90 };
    pub const text = Rgb{ .r = 0.92, .g = 0.92, .b = 0.95 };
    pub const outline = Rgb{ .r = 0.55, .g = 0.60, .b = 0.62 };

    pub const corner_xs: f64 = 4.0;
    pub const corner_sm: f64 = 8.0;
    pub const corner_md: f64 = 12.0;
    pub const corner_lg: f64 = 16.0;

    pub const space_1: i32 = 4;
    pub const space_2: i32 = 8;
    pub const space_3: i32 = 12;
    pub const space_4: i32 = 16;
    pub const space_6: i32 = 24;

    pub fn lerp(a: Rgb, b: Rgb, t: f64) Rgb {
        const c = @max(0.0, @min(1.0, t));
        return .{
            .r = a.r + (b.r - a.r) * c,
            .g = a.g + (b.g - a.g) * c,
            .b = a.b + (b.b - a.b) * c,
        };
    }

    pub fn withAlpha(c: Rgb, a: f64) struct { r: f64, g: f64, b: f64, a: f64 } {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = @max(0.0, @min(1.0, a)) };
    }
};

test "m3-tokens: lerp and alpha" {
    const t = std.testing;
    const m = Tokens.lerp(Tokens.background, Tokens.text, 0.5);
    try t.expect(m.r > Tokens.background.r and m.r < Tokens.text.r);
    const e0 = Tokens.lerp(Tokens.accent, Tokens.text, 0.0);
    try t.expectEqual(Tokens.accent.r, e0.r);
    const wa = Tokens.withAlpha(Tokens.accent, 2.0);
    try t.expectEqual(@as(f64, 1.0), wa.a);
}
