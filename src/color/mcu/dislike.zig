//! material-color-utilities `cpp/dislike` (`dislike.cc`): the yellow-green
//! band colors that HCT cannot please, pushed up to tone 70.

const std = @import("std");
const cam = @import("cam.zig");
const utils = @import("utils.zig");

pub fn isDisliked(hct: cam.Hct) bool {
    const hue_passes = @round(hct.hue) >= 90.0 and @round(hct.hue) <= 111.0;
    const chroma_passes = @round(hct.chroma) > 16.0;
    const tone_passes = @round(hct.tone) < 65.0;
    return hue_passes and chroma_passes and tone_passes;
}

pub fn fixIfDisliked(hct: cam.Hct) cam.Hct {
    if (!isDisliked(hct)) return hct;
    return cam.Hct.fromHct(hct.hue, hct.chroma, 70.0);
}

test "mcu-dislike: band members move to tone 70, others pass through" {
    const t = std.testing;
    // (input, disliked, fixed) from the oracle `dislike` lines.
    const cases = [_]struct { c: utils.Argb, d: bool, f: utils.Argb }{
        .{ .c = 0xFF4285F4, .d = false, .f = 0xFF4285F4 },
        .{ .c = 0xFFD32F2F, .d = false, .f = 0xFFD32F2F },
        .{ .c = 0xFF000000, .d = false, .f = 0xFF000000 },
        .{ .c = 0xFF918443, .d = true, .f = 0xFFBAAC66 },
        .{ .c = 0xFF82791F, .d = true, .f = 0xFFB8AD4F },
    };
    for (cases) |cs| {
        const h = cam.Hct.fromInt(cs.c);
        try t.expectEqual(cs.d, isDisliked(h));
        try t.expectEqual(cs.f, fixIfDisliked(h).toInt());
    }
}
