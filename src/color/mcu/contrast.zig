//! material-color-utilities `cpp/contrast` (`contrast.cc`). Tone-based
//! contrast ratios and the lighter/darker solvers.

const std = @import("std");
const utils = @import("utils.zig");

pub const ratio_epsilon: f64 = 0.04;
pub const luminance_gamut_map_tolerance: f64 = 0.4;

pub fn ratioOfYs(y1: f64, y2: f64) f64 {
    const light = if (y1 > y2) y1 else y2;
    const dark = if (light == y2) y1 else y2;
    return (light + 5.0) / (dark + 5.0);
}

pub fn ratioOfTones(tone_a: f64, tone_b: f64) f64 {
    return ratioOfYs(
        utils.yFromLstar(std.math.clamp(tone_a, 0.0, 100.0)),
        utils.yFromLstar(std.math.clamp(tone_b, 0.0, 100.0)),
    );
}

pub fn lighter(tone: f64, ratio: f64) f64 {
    if (tone < 0.0 or tone > 100.0) return -1.0;
    const dark_y = utils.yFromLstar(tone);
    const light_y = ratio * (dark_y + 5.0) - 5.0;
    const real_contrast = ratioOfYs(light_y, dark_y);
    // Integer-`abs` TU (verified by probe): the difference truncates
    // toward zero before the epsilon comparison.
    if (real_contrast < ratio and @trunc(@abs(real_contrast - ratio)) > ratio_epsilon) return -1.0;
    const value = utils.lstarFromY(light_y) + luminance_gamut_map_tolerance;
    if (value < 0.0 or value > 100.0) return -1.0;
    return value;
}

pub fn darker(tone: f64, ratio: f64) f64 {
    if (tone < 0.0 or tone > 100.0) return -1.0;
    const light_y = utils.yFromLstar(tone);
    const dark_y = (light_y + 5.0) / ratio - 5.0;
    const real_contrast = ratioOfYs(light_y, dark_y);
    // Integer-`abs` TU (verified by probe): the difference truncates
    // toward zero before the epsilon comparison.
    if (real_contrast < ratio and @trunc(@abs(real_contrast - ratio)) > ratio_epsilon) return -1.0;
    const value = utils.lstarFromY(dark_y) - luminance_gamut_map_tolerance;
    if (value < 0.0 or value > 100.0) return -1.0;
    return value;
}

pub fn lighterUnsafe(tone: f64, ratio: f64) f64 {
    const v = lighter(tone, ratio);
    return if (v < 0.0) 100.0 else v;
}

pub fn darkerUnsafe(tone: f64, ratio: f64) f64 {
    const v = darker(tone, ratio);
    return if (v < 0.0) 0.0 else v;
}

test "mcu-contrast: ratios match the oracle" {
    const t = std.testing;
    try t.expectApproxEqAbs(
        21.0,
        ratioOfTones(utils.lstarFromArgb(0xFFFFFFFF), utils.lstarFromArgb(0xFF000000)),
        1e-6,
    );
    try t.expectApproxEqAbs(
        3.563555,
        ratioOfTones(utils.lstarFromArgb(0xFF4285F4), utils.lstarFromArgb(0xFFFFFFFF)),
        1e-6,
    );
    try t.expectApproxEqAbs(
        2.007652,
        ratioOfTones(utils.lstarFromArgb(0xFF563925), utils.lstarFromArgb(0xFF000000)),
        1e-6,
    );
}
