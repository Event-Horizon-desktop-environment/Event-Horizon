//! material-color-utilities `cpp/blend` (`blend.cc`): harmonize and the two
//! UCS interpolations.

const std = @import("std");
const cam = @import("cam.zig");
const utils = @import("utils.zig");

pub fn blendHarmonize(design_color: utils.Argb, key_color: utils.Argb) utils.Argb {
    var from_hct = cam.Hct.fromInt(design_color);
    const to_hct = cam.Hct.fromInt(key_color);
    const diff = utils.diffDegrees(from_hct.hue, to_hct.hue);
    const rotation = @min(diff * 0.5, 15.0);
    const output_hue = utils.sanitizeDegreesDouble(
        from_hct.hue + rotation * utils.rotationDirection(from_hct.hue, to_hct.hue),
    );
    from_hct.setHue(output_hue);
    return from_hct.toInt();
}

pub fn blendHctHue(from: utils.Argb, to: utils.Argb, amount: f64) utils.Argb {
    const ucs = blendCam16Ucs(from, to, amount);
    const ucs_hue = cam.Hct.fromInt(ucs).hue;
    var from_hct = cam.Hct.fromInt(from);
    from_hct.setHue(ucs_hue);
    return from_hct.toInt();
}

pub fn blendCam16Ucs(from: utils.Argb, to: utils.Argb, amount: f64) utils.Argb {
    const from_cam = cam.camFromInt(from);
    const to_cam = cam.camFromInt(to);
    const blended = cam.camFromUcsAndViewingConditions(
        from_cam.jstar + (to_cam.jstar - from_cam.jstar) * amount,
        from_cam.astar + (to_cam.astar - from_cam.astar) * amount,
        from_cam.bstar + (to_cam.bstar - from_cam.bstar) * amount,
        cam.k_default_viewing_conditions,
    );
    return cam.intFromCam(blended);
}

test "mcu-blend: harmonize and UCS blends match the oracle" {
    const t = std.testing;
    try t.expectEqual(@as(utils.Argb, 0xFFD3275C), blendHarmonize(0xFFD32F2F, 0xFF4285F4));
    try t.expectEqual(@as(utils.Argb, 0xFFBE27BD), blendHctHue(0xFFD32F2F, 0xFF4285F4, 0.5));
    try t.expectEqual(@as(utils.Argb, 0xFF9B6E94), blendCam16Ucs(0xFFD32F2F, 0xFF4285F4, 0.5));
    try t.expectEqual(@as(utils.Argb, 0xFF523B20), blendHarmonize(0xFF563925, 0xFFFBC02D));
    try t.expectEqual(@as(utils.Argb, 0xFF503C1E), blendHctHue(0xFF563925, 0xFFFBC02D, 0.5));
    try t.expectEqual(@as(utils.Argb, 0xFFA27835), blendCam16Ucs(0xFF563925, 0xFFFBC02D, 0.5));
}
