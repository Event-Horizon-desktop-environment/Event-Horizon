//! material-color-utilities `cpp/score`: rank a color->population map for
//! theme suitability (`score.cc`). Direct port; iteration that was
//! Key-ordered; consumers sort keys explicitly here.

const std = @import("std");
const cam = @import("cam.zig");
const utils = @import("utils.zig");

pub const target_chroma: f64 = 48.0;
pub const weight_proportion: f64 = 0.7;
pub const weight_chroma_above: f64 = 0.3;
pub const weight_chroma_below: f64 = 0.1;
pub const cutoff_chroma: f64 = 5.0;
pub const cutoff_excited_proportion: f64 = 0.01;

pub const ScoreOptions = struct {
    desired: usize = 4,
    fallback_color_argb: utils.Argb = 0xFF4285F4,
    filter: bool = true,
};

const Scored = struct {
    hct: cam.Hct,
    score: f64,
};

fn argbLess(_: void, a: utils.Argb, b: utils.Argb) bool {
    return a < b;
}

fn scoredLess(_: void, a: Scored, b: Scored) bool {
    return a.score > b.score;
}

pub fn rankedSuggestions(
    alloc: std.mem.Allocator,
    argb_to_population: *const std.AutoHashMap(utils.Argb, u32),
    options: ScoreOptions,
) !std.ArrayList(utils.Argb) {
    var colors = std.ArrayList(utils.Argb).empty;
    errdefer colors.deinit(alloc);

    var hue_population = @as([360]u32, @splat(0));
    var population_sum: f64 = 0.0;

    // Key-ordered pass.
    var keys = std.ArrayList(utils.Argb).empty;
    defer keys.deinit(alloc);
    var kit = argb_to_population.iterator();
    while (kit.next()) |e| try keys.append(alloc, e.key_ptr.*);
    std.mem.sort(utils.Argb, keys.items, {}, argbLess);

    var hcts = std.ArrayList(cam.Hct).empty;
    defer hcts.deinit(alloc);
    for (keys.items) |argb| {
        const h = cam.Hct.fromInt(argb);
        try hcts.append(alloc, h);
        const pop = argb_to_population.get(argb).?;
        const hue: usize = @intFromFloat(@floor(h.hue));
        hue_population[hue % 360] += pop;
        population_sum += @as(f64, @floatFromInt(pop));
    }

    var excited = @as([360]f64, @splat(0.0));
    for (0..360) |hue| {
        const proportion = @as(f64, @floatFromInt(hue_population[hue])) / population_sum;
        var i: i32 = @as(i32, @intCast(hue)) - 14;
        while (i < @as(i32, @intCast(hue)) + 16) : (i += 1) {
            const n: usize = @intCast(utils.sanitizeDegreesInt(i));
            excited[n] += proportion;
        }
    }

    var scored = std.ArrayList(Scored).empty;
    defer scored.deinit(alloc);
    for (hcts.items) |h| {
        const hue: usize = @intCast(utils.sanitizeDegreesInt(@as(i32, @intFromFloat(@round(h.hue)))));
        const proportion = excited[hue];
        if (options.filter and (h.chroma < cutoff_chroma or proportion <= cutoff_excited_proportion)) continue;
        const proportion_score = proportion * 100.0 * weight_proportion;
        const chroma_weight = if (h.chroma < target_chroma) weight_chroma_below else weight_chroma_above;
        const chroma_score = (h.chroma - target_chroma) * chroma_weight;
        try scored.append(alloc, .{ .hct = h, .score = proportion_score + chroma_score });
    }
    std.mem.sort(Scored, scored.items, {}, scoredLess);

    var difference: i32 = 90;
    var chosen = std.ArrayList(cam.Hct).empty;
    defer chosen.deinit(alloc);
    while (difference >= 15) : (difference -= 1) {
        chosen.clearRetainingCapacity();
        for (scored.items) |entry| {
            var dupe = false;
            for (chosen.items) |ch| {
                if (utils.diffDegrees(entry.hct.hue, ch.hue) < @as(f64, @floatFromInt(difference))) {
                    dupe = true;
                    break;
                }
            }
            if (!dupe) {
                try chosen.append(alloc, entry.hct);
                if (chosen.items.len >= options.desired) break;
            }
        }
        if (chosen.items.len >= options.desired) break;
    }

    if (chosen.items.len == 0) {
        try colors.append(alloc, options.fallback_color_argb);
    }
    for (chosen.items) |h| try colors.append(alloc, h.toInt());
    return colors;
}

test "mcu-score: ranking matches the oracle" {
    const t = std.testing;
    const alloc = t.allocator;
    var m = std.AutoHashMap(utils.Argb, u32).init(alloc);
    defer m.deinit();
    const entries = [_]struct { c: utils.Argb, n: u32 }{
        .{ .c = 0xFFD32F2F, .n = 300 },
        .{ .c = 0xFF1976D2, .n = 900 },
        .{ .c = 0xFF388E3C, .n = 500 },
        .{ .c = 0xFFFBC02D, .n = 100 },
        .{ .c = 0xFF7B1FA2, .n = 700 },
        .{ .c = 0xFF9E9E9E, .n = 2000 },
        .{ .c = 0xFF212121, .n = 1500 },
        .{ .c = 0xFF0097A3, .n = 400 },
    };
    for (entries) |e| try m.put(e.c, e.n);
    var ranked = try rankedSuggestions(alloc, &m, .{ .desired = 4 });
    defer ranked.deinit(alloc);
    // Oracle `score` lines, in order.
    const want = [_]utils.Argb{ 0xFF0097A3, 0xFFD32F2F, 0xFF7B1FA2, 0xFFFBC02D };
    try t.expectEqual(want.len, ranked.items.len);
    for (want, ranked.items) |w, g| try t.expectEqual(w, g);
}
