//! material-color-utilities `cpp/palettes`: `TonalPalette` + `KeyColor`
//! (`tones.cc`). A palette is a hue/chroma pair; `get(tone)` solves the ARGB
//! for that tone through the HCT solver.

const std = @import("std");
const cam = @import("cam.zig");
const utils = @import("utils.zig");

pub const TonalPalette = struct {
    hue: f64,
    chroma: f64,
    key_color: cam.Hct,

    pub fn fromInt(argb: utils.Argb) TonalPalette {
        const c = cam.camFromInt(argb);
        var kc = KeyColor{ .hue = c.hue, .requested_chroma = c.chroma };
        return .{ .hue = c.hue, .chroma = c.chroma, .key_color = kc.create() };
    }

    pub fn fromHct(h: cam.Hct) TonalPalette {
        return .{ .hue = h.hue, .chroma = h.chroma, .key_color = h };
    }

    pub fn fromHueChroma(hue: f64, chroma: f64) TonalPalette {
        var kc = KeyColor{ .hue = hue, .requested_chroma = chroma };
        return .{ .hue = hue, .chroma = chroma, .key_color = kc.create() };
    }

    pub fn fromHueChromaKey(hue: f64, chroma: f64, key_color: cam.Hct) TonalPalette {
        return .{ .hue = hue, .chroma = chroma, .key_color = key_color };
    }

    pub fn get(self: *const TonalPalette, tone: f64) utils.Argb {
        return cam.intFromHcl(self.hue, self.chroma, tone);
    }
};

pub const KeyColor = struct {
    hue: f64,
    requested_chroma: f64,

    const max_chroma_value: f64 = 200.0;

    pub fn create(self: *KeyColor) cam.Hct {
        const pivot_tone: i32 = 50;
        const tone_step_size: i32 = 1;
        const epsilon: f64 = 0.01;
        // Small tone->chroma memo so the binary search does not redo solves.
        var cache_keys: [128]f64 = undefined;
        var cache_vals: [128]f64 = undefined;
        var cache_len: usize = 0;

        var lower_tone: i32 = 0;
        var upper_tone: i32 = 100;
        while (lower_tone < upper_tone) {
            const mid_tone: i32 = @divTrunc(lower_tone + upper_tone, 2);
            const mc_mid = self.maxChroma(mid_tone, &cache_keys, &cache_vals, &cache_len);
            const mc_next = self.maxChroma(mid_tone + tone_step_size, &cache_keys, &cache_vals, &cache_len);
            const is_ascending = mc_mid < mc_next;
            const sufficient = mc_mid >= self.requested_chroma - epsilon;
            if (sufficient) {
                if (@abs(lower_tone - pivot_tone) < @abs(upper_tone - pivot_tone)) {
                    upper_tone = mid_tone;
                } else {
                    if (lower_tone == mid_tone) {
                        return cam.Hct.fromHct(
                            self.hue,
                            self.requested_chroma,
                            @floatFromInt(lower_tone),
                        );
                    }
                    lower_tone = mid_tone;
                }
            } else {
                if (is_ascending) {
                    lower_tone = mid_tone + tone_step_size;
                } else {
                    upper_tone = mid_tone;
                }
            }
        }
        return cam.Hct.fromHct(
            self.hue,
            self.requested_chroma,
            @floatFromInt(lower_tone),
        );
    }

    fn maxChroma(
        self: *KeyColor,
        tone: i32,
        keys: *[128]f64,
        vals: *[128]f64,
        len: *usize,
    ) f64 {
        const t: f64 = @floatFromInt(tone);
        for (keys[0..len.*], 0..) |k, i| {
            if (k == t) return vals[i];
        }
        const c = cam.Hct.fromHct(self.hue, max_chroma_value, t).chroma;
        if (len.* < keys.len) {
            keys[len.*] = t;
            vals[len.*] = c;
            len.* += 1;
        }
        return c;
    }
};

// `tone` lines of the oracle.

test "mcu-palette: tones match the oracle" {
    const t = std.testing;
    const cases = [_]struct { h: f64, c: f64, tone: f64, want: utils.Argb }{
        .{ .h = 250.0, .c = 48.0, .tone = 0.0, .want = 0xFF000000 },
        .{ .h = 250.0, .c = 48.0, .tone = 10.0, .want = 0xFF001D34 },
        .{ .h = 250.0, .c = 48.0, .tone = 50.0, .want = 0xFF287CBC },
        .{ .h = 250.0, .c = 48.0, .tone = 90.0, .want = 0xFFCFE5FF },
        .{ .h = 250.0, .c = 48.0, .tone = 100.0, .want = 0xFFFFFFFF },
        .{ .h = 25.0, .c = 84.0, .tone = 0.0, .want = 0xFF000000 },
        .{ .h = 25.0, .c = 84.0, .tone = 10.0, .want = 0xFF410002 },
        .{ .h = 25.0, .c = 84.0, .tone = 50.0, .want = 0xFFDE3730 },
        .{ .h = 25.0, .c = 84.0, .tone = 90.0, .want = 0xFFFFDAD6 },
        .{ .h = 25.0, .c = 84.0, .tone = 100.0, .want = 0xFFFFFFFF },
        .{ .h = 0.0, .c = 0.0, .tone = 0.0, .want = 0xFF000000 },
        .{ .h = 0.0, .c = 0.0, .tone = 10.0, .want = 0xFF1B1B1B },
        .{ .h = 0.0, .c = 0.0, .tone = 50.0, .want = 0xFF777777 },
        .{ .h = 0.0, .c = 0.0, .tone = 90.0, .want = 0xFFE2E2E2 },
        .{ .h = 0.0, .c = 0.0, .tone = 100.0, .want = 0xFFFFFFFF },
    };
    for (cases) |cs| {
        const p = TonalPalette.fromHueChroma(cs.h, cs.c);
        try t.expectEqual(cs.want, p.get(cs.tone));
    }
}
