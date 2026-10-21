//! Temperature-cache complement sets around an input color.
//! Complements and analogous sets around an input color.
//!
//! Bit-parity notes:
//!   * The temp map keys by `Hct` hue only. Every
//!     table entry shares the input's chroma/tone, so a hue *is* the key:
//!     non-integer hues can only be the input itself, which has its own slot.
//!   * By-temperature ordering uses the same unstable sort;
//!     exact temp ties (symmetric hues around 50°) may order differently,
//!     but the oracle's expressive/content/fidelity scheme tables pin the
//!     outcomes the shell actually consumes.

const std = @import("std");
const cam = @import("cam.zig");
const quantize = @import("quantize.zig");
const utils = @import("utils.zig");
const libm = @import("libm.zig");

pub const TemperatureCache = struct {
    input: cam.Hct,
    input_temp: f64,
    hcts_by_hue: [361]cam.Hct,
    temps_by_hue: [361]f64,
    /// Indices into the 361 hues plus 361 == input, ascending by temperature.
    by_temp: [362]u16,
    complement: ?cam.Hct = null,

    pub fn init(input: cam.Hct) TemperatureCache {
        var tc = TemperatureCache{
            .input = input,
            .input_temp = 0.0,
            .hcts_by_hue = undefined,
            .temps_by_hue = undefined,
            .by_temp = undefined,
        };
        for (0..361) |i| {
            const h = cam.Hct.fromHct(@floatFromInt(i), input.chroma, input.tone);
            tc.hcts_by_hue[i] = h;
            tc.temps_by_hue[i] = rawTemperature(h);
        }
        tc.input_temp = rawTemperature(input);
        for (0..362) |i| tc.by_temp[i] = @intCast(i);
        const ctx = ByTemp{ .tc = &tc };
        std.mem.sort(u16, &tc.by_temp, ctx, ByTemp.less);
        return tc;
    }

    fn tempAt(tc: *const TemperatureCache, idx: usize) f64 {
        return if (idx == 361) tc.input_temp else tc.temps_by_hue[idx];
    }

    fn hctAt(tc: *const TemperatureCache, idx: usize) cam.Hct {
        return if (idx == 361) tc.input else tc.hcts_by_hue[idx];
    }

    /// Temperature of any color the cache can name: the input's own slot, or
    /// the integer-hue table.
    pub fn tempOf(tc: *const TemperatureCache, h: cam.Hct) f64 {
        if (h.hue == tc.input.hue and h.chroma == tc.input.chroma and h.tone == tc.input.tone) {
            return tc.input_temp;
        }
        const i: usize = @intFromFloat(@round(h.hue));
        return tc.temps_by_hue[@min(i, 360)];
    }

    pub fn coldest(tc: *const TemperatureCache) cam.Hct {
        return tc.hctAt(tc.by_temp[0]);
    }

    pub fn warmest(tc: *const TemperatureCache) cam.Hct {
        return tc.hctAt(tc.by_temp[361]);
    }

    pub fn relativeTemperature(tc: *const TemperatureCache, h: cam.Hct) f64 {
        const range = tc.tempOf(tc.warmest()) - tc.tempOf(tc.coldest());
        if (range == 0.0) return 0.5;
        return (tc.tempOf(h) - tc.tempOf(tc.coldest())) / range;
    }

    pub fn getComplement(tc: *TemperatureCache) cam.Hct {
        if (tc.complement) |c| return c;
        const coldest_hue = tc.coldest().hue;
        const coldest_temp = tc.tempOf(tc.coldest());
        const warmest_hue = tc.warmest().hue;
        const warmest_temp = tc.tempOf(tc.warmest());
        const range = warmest_temp - coldest_temp;
        const start_coldest_to_warmest = isBetween(tc.input.hue, coldest_hue, warmest_hue);
        const start_hue = if (start_coldest_to_warmest) warmest_hue else coldest_hue;
        const end_hue = if (start_coldest_to_warmest) coldest_hue else warmest_hue;
        var smallest_error: f64 = 1000.0;
        var answer = tc.hcts_by_hue[@min(@as(usize, @intFromFloat(@round(tc.input.hue))), 360)];
        const compl_rel = 1.0 - tc.relativeTemperature(tc.input);
        var addend: f64 = 0.0;
        while (addend <= 360.0) : (addend += 1.0) {
            const hue = utils.sanitizeDegreesDouble(start_hue + addend);
            if (!isBetween(hue, start_hue, end_hue)) continue;
            const possible = tc.hcts_by_hue[@min(@as(usize, @intFromFloat(@round(hue))), 360)];
            const rel = (tc.tempOf(possible) - coldest_temp) / range;
            // Same integer-`abs` truncation (verified by probe):
            // sub-1.0 errors all read as 0.0, so the first-visited hue wins ties.
            const err = @trunc(@abs(compl_rel - rel));
            if (err < smallest_error) {
                smallest_error = err;
                answer = possible;
            }
        }
        tc.complement = answer;
        return answer;
    }

    pub fn getAnalogousColors(
        tc: *const TemperatureCache,
        alloc: std.mem.Allocator,
        count: i32,
        divisions: i32,
    ) !std.ArrayList(cam.Hct) {
        var all = std.ArrayList(cam.Hct).empty;
        defer all.deinit(alloc);
        if (count <= 0 or divisions <= 0) {
            return std.ArrayList(cam.Hct).empty;
        }
        const div_us: usize = @intCast(divisions);
        const start_hue: i32 = @intFromFloat(@round(tc.input.hue));
        const start_hct = tc.hcts_by_hue[@min(@as(usize, @intCast(start_hue)), 360)];
        var last_temp = tc.relativeTemperature(start_hct);
        try all.append(alloc, start_hct);

        var total: f64 = 0.0;
        for (0..360) |i| {
            const hue = utils.sanitizeDegreesInt(start_hue + @as(i32, @intCast(i)));
            const h = tc.hcts_by_hue[@intCast(hue)];
            const temp = tc.relativeTemperature(h);
            total += @trunc(@abs(temp - last_temp));
            last_temp = temp;
        }

        var hue_addend: i32 = 1;
        const temp_step = total / @as(f64, @floatFromInt(divisions));
        var total_delta: f64 = 0.0;
        last_temp = tc.relativeTemperature(start_hct);
        while (all.items.len < div_us) {
            const hue = utils.sanitizeDegreesInt(start_hue + hue_addend);
            const h = tc.hcts_by_hue[@intCast(hue)];
            const temp = tc.relativeTemperature(h);
            total_delta += @trunc(@abs(temp - last_temp));
            var desired = @as(f64, @floatFromInt(all.items.len)) * temp_step;
            var satisfied = total_delta >= desired;
            var index_addend: i32 = 1;
            while (satisfied and all.items.len < div_us) {
                try all.append(alloc, h);
                desired = (@as(f64, @floatFromInt(all.items.len)) + @as(f64, @floatFromInt(index_addend))) * temp_step;
                satisfied = total_delta >= desired;
                index_addend += 1;
            }
            last_temp = temp;
            hue_addend += 1;
            if (hue_addend > 360) {
                while (all.items.len < div_us) try all.append(alloc, h);
                break;
            }
        }

        var answers = std.ArrayList(cam.Hct).empty;
        errdefer answers.deinit(alloc);
        try answers.append(alloc, tc.input);
        const ccw_count: i32 = @intFromFloat(@floor((@as(f64, @floatFromInt(count)) - 1.0) / 2.0));
        var i: i32 = 1;
        while (i < ccw_count + 1) : (i += 1) {
            var index: i32 = 0 - i;
            while (index < 0) index += @as(i32, @intCast(all.items.len));
            if (index >= @as(i32, @intCast(all.items.len))) index = @mod(index, @as(i32, @intCast(all.items.len)));
            try answers.insert(alloc, 0, all.items[@intCast(index)]);
        }
        const cw_count = count - ccw_count - 1;
        var j: usize = 1;
        while (j < @as(usize, @intCast(cw_count)) + 1) : (j += 1) {
            var index = j;
            if (index >= all.items.len) index = index % all.items.len;
            try answers.append(alloc, all.items[index]);
        }
        // `answers` holds copies; the scratch table drops via the `defer`.
        return answers;
    }

    pub fn rawTemperature(color: cam.Hct) f64 {
        const lab = quantize.labFromInt(color.toInt());
        const hue = utils.sanitizeDegreesDouble(libm.atan2(lab.b, lab.a) * 180.0 / utils.k_pi);
        const chroma = @sqrt(lab.a * lab.a + lab.b * lab.b);
        return -0.5 + 0.02 * libm.pow(chroma, 1.07) *
            libm.cos(utils.sanitizeDegreesDouble(hue - 50.0) * utils.k_pi / 180.0);
    }

    pub fn isBetween(angle: f64, a: f64, b: f64) bool {
        if (a < b) return a <= angle and angle <= b;
        return a <= angle or angle <= b;
    }
};

const ByTemp = struct {
    tc: *const TemperatureCache,

    fn less(ctx: ByTemp, a: u16, b: u16) bool {
        return ctx.tc.tempAt(a) < ctx.tc.tempAt(b);
    }
};

test "mcu-temperature: complement and analogues match the oracle" {
    const t = std.testing;
    const alloc = t.allocator;
    var tc = TemperatureCache.init(cam.Hct.fromInt(0xFF4285F4));
    try t.expectEqual(@as(utils.Argb, 0xFFD66900), tc.getComplement().toInt());
    var an = try tc.getAnalogousColors(alloc, 5, 12);
    defer an.deinit(alloc);
    const want = [_]utils.Argb{ 0xFF4684F4, 0xFF4684F4, 0xFF4285F4, 0xFF4684F4, 0xFF4684F4 };
    try t.expectEqual(want.len, an.items.len);
    for (want, an.items) |w, g| try t.expectEqual(w, g.toInt());
}
