//! Color quantization: Lab, Wu, WSMeans and Celebi.
//!
//! Bit-parity notes:
//!   * WSMeans draws from `rand.zig`, seeded 42688 for glibc `rand()` bit-parity.
//!   * `pixel_to_count` membership preserves first-occurrence order for the
//!     `pixels`/`points` vectors (only counts ride in
//!     the map; order never comes from it).
//!   * All downstream iteration is key-ordered, so the
//!     result maps are plain hash maps here and consumers sort keys.
//!   * Float `xx - hypotenuse / volume` keeps IEEE semantics: a zero weight
//!     yields NaN/inf in both languages and compares false the same way.

const std = @import("std");
const rand = @import("rand.zig");
const utils = @import("utils.zig");
const libm = @import("libm.zig");

pub const Lab = struct {
    l: f64 = 0.0,
    a: f64 = 0.0,
    b: f64 = 0.0,

    pub fn deltaE(self: Lab, other: Lab) f64 {
        const dl = self.l - other.l;
        const da = self.a - other.a;
        const db = self.b - other.b;
        return dl * dl + da * da + db * db;
    }
};

pub fn intFromLab(lab: Lab) utils.Argb {
    const e = 216.0 / 24389.0;
    const kappa = 24389.0 / 27.0;
    const ke = 8.0;
    const fy = (lab.l + 16.0) / 116.0;
    const fx = lab.a / 500.0 + fy;
    const fz = fy - lab.b / 200.0;
    const fx3 = fx * fx * fx;
    const x_norm = if (fx3 > e) fx3 else (116.0 * fx - 16.0) / kappa;
    const y_norm = if (lab.l > ke) fy * fy * fy else lab.l / kappa;
    const fz3 = fz * fz * fz;
    const z_norm = if (fz3 > e) fz3 else (116.0 * fz - 16.0) / kappa;
    const x = x_norm * utils.k_white_point_d65[0];
    const y = y_norm * utils.k_white_point_d65[1];
    const z = z_norm * utils.k_white_point_d65[2];
    const r_l = 3.2406 * x - 1.5372 * y - 0.4986 * z;
    const g_l = -0.9689 * x + 1.8758 * y + 0.0415 * z;
    const b_l = 0.0557 * x - 0.2040 * y + 1.0570 * z;
    return utils.argbFromRgb(
        utils.delinearized(r_l),
        utils.delinearized(g_l),
        utils.delinearized(b_l),
    );
}

pub fn labFromInt(argb: utils.Argb) Lab {
    const r_l = utils.linearized(@as(i32, utils.redFromInt(argb)));
    const g_l = utils.linearized(@as(i32, utils.greenFromInt(argb)));
    const b_l = utils.linearized(@as(i32, utils.blueFromInt(argb)));
    const x = 0.41233895 * r_l + 0.35762064 * g_l + 0.18051042 * b_l;
    const y = 0.2126 * r_l + 0.7152 * g_l + 0.0722 * b_l;
    const z = 0.01932141 * r_l + 0.11916382 * g_l + 0.95034478 * b_l;
    const e = 216.0 / 24389.0;
    const kappa = 24389.0 / 27.0;
    const y_norm = y / utils.k_white_point_d65[1];
    const fy = if (y_norm > e)
        libm.pow(y_norm, 1.0 / 3.0)
    else
        (kappa * y_norm + 16.0) / 116.0;
    const x_norm = x / utils.k_white_point_d65[0];
    const fx = if (x_norm > e)
        libm.pow(x_norm, 1.0 / 3.0)
    else
        (kappa * x_norm + 16.0) / 116.0;
    const z_norm = z / utils.k_white_point_d65[2];
    const fz = if (z_norm > e)
        libm.pow(z_norm, 1.0 / 3.0)
    else
        (kappa * z_norm + 16.0) / 116.0;
    return .{
        .l = 116.0 * fy - 16.0,
        .a = 500.0 * (fx - fy),
        .b = 200.0 * (fy - fz),
    };
}

const index_bits: usize = 5;
const index_count: usize = (1 << index_bits) + 1; // 33
const wu_total_size: usize = index_count * index_count * index_count; // 35937
const wu_max_colors: usize = 256;

const Box = struct {
    r0: i32 = 0,
    r1: i32 = 0,
    g0: i32 = 0,
    g1: i32 = 0,
    b0: i32 = 0,
    b1: i32 = 0,
    vol: i32 = 0,
};

const Direction = enum { red, green, blue };

fn getIndex(r: usize, g: usize, b: usize) usize {
    return (r << (index_bits * 2)) + (r << (index_bits + 1)) + (g << index_bits) + r + g + b;
}

fn wuTop(cube: Box, dir: Direction, pos: usize, moment: []const i64) i64 {
    const r0: usize = @intCast(cube.r0);
    const r1: usize = @intCast(cube.r1);
    const g0: usize = @intCast(cube.g0);
    const g1: usize = @intCast(cube.g1);
    const b0: usize = @intCast(cube.b0);
    const b1: usize = @intCast(cube.b1);
    return switch (dir) {
        .red => moment[getIndex(pos, g1, b1)] - moment[getIndex(pos, g1, b0)] -
            moment[getIndex(pos, g0, b1)] + moment[getIndex(pos, g0, b0)],
        .green => moment[getIndex(r1, pos, b1)] - moment[getIndex(r1, pos, b0)] -
            moment[getIndex(r0, pos, b1)] + moment[getIndex(r0, pos, b0)],
        .blue => moment[getIndex(r1, g1, pos)] - moment[getIndex(r1, g0, pos)] -
            moment[getIndex(r0, g1, pos)] + moment[getIndex(r0, g0, pos)],
    };
}

fn wuBottom(cube: Box, dir: Direction, moment: []const i64) i64 {
    const r0: usize = @intCast(cube.r0);
    const r1: usize = @intCast(cube.r1);
    const g0: usize = @intCast(cube.g0);
    const g1: usize = @intCast(cube.g1);
    const b0: usize = @intCast(cube.b0);
    const b1: usize = @intCast(cube.b1);
    return switch (dir) {
        .red => -moment[getIndex(r0, g1, b1)] + moment[getIndex(r0, g1, b0)] +
            moment[getIndex(r0, g0, b1)] - moment[getIndex(r0, g0, b0)],
        .green => -moment[getIndex(r1, g0, b1)] + moment[getIndex(r1, g0, b0)] +
            moment[getIndex(r0, g0, b1)] - moment[getIndex(r0, g0, b0)],
        .blue => -moment[getIndex(r1, g1, b0)] + moment[getIndex(r1, g0, b0)] +
            moment[getIndex(r0, g1, b0)] - moment[getIndex(r0, g0, b0)],
    };
}

fn wuVol(cube: Box, moment: []const i64) i64 {
    const r0: usize = @intCast(cube.r0);
    const r1: usize = @intCast(cube.r1);
    const g0: usize = @intCast(cube.g0);
    const g1: usize = @intCast(cube.g1);
    const b0: usize = @intCast(cube.b0);
    const b1: usize = @intCast(cube.b1);
    return moment[getIndex(r1, g1, b1)] - moment[getIndex(r1, g1, b0)] -
        moment[getIndex(r1, g0, b1)] + moment[getIndex(r1, g0, b0)] -
        moment[getIndex(r0, g1, b1)] + moment[getIndex(r0, g1, b0)] +
        moment[getIndex(r0, g0, b1)] - moment[getIndex(r0, g0, b0)];
}

fn wuVariance(cube: Box, weights: []const i64, m_r: []const i64, m_g: []const i64, m_b: []const i64, moments: []const f64) f64 {
    const dr: f64 = @floatFromInt(wuVol(cube, m_r));
    const dg: f64 = @floatFromInt(wuVol(cube, m_g));
    const db: f64 = @floatFromInt(wuVol(cube, m_b));
    const r0: usize = @intCast(cube.r0);
    const r1: usize = @intCast(cube.r1);
    const g0: usize = @intCast(cube.g0);
    const g1: usize = @intCast(cube.g1);
    const b0: usize = @intCast(cube.b0);
    const b1: usize = @intCast(cube.b1);
    const xx = moments[getIndex(r1, g1, b1)] - moments[getIndex(r1, g1, b0)] -
        moments[getIndex(r1, g0, b1)] + moments[getIndex(r1, g0, b0)] -
        moments[getIndex(r0, g1, b1)] + moments[getIndex(r0, g1, b0)] +
        moments[getIndex(r0, g0, b1)] - moments[getIndex(r0, g0, b0)];
    const hyp = dr * dr + dg * dg + db * db;
    const vol: f64 = @floatFromInt(wuVol(cube, weights));
    return xx - hyp / vol;
}

fn wuMaximize(
    cube: Box,
    dir: Direction,
    first: i32,
    last: i32,
    cut: *i32,
    whole_w: i64,
    whole_r: i64,
    whole_g: i64,
    whole_b: i64,
    weights: []const i64,
    m_r: []const i64,
    m_g: []const i64,
    m_b: []const i64,
) f64 {
    const br = wuBottom(cube, dir, m_r);
    const bg = wuBottom(cube, dir, m_g);
    const bb = wuBottom(cube, dir, m_b);
    const bw = wuBottom(cube, dir, weights);
    var max: f64 = 0.0;
    cut.* = -1;
    var i = first;
    while (i < last) : (i += 1) {
        const pos: usize = @intCast(i);
        var half_r = br + wuTop(cube, dir, pos, m_r);
        var half_g = bg + wuTop(cube, dir, pos, m_g);
        var half_b = bb + wuTop(cube, dir, pos, m_b);
        var half_w = bw + wuTop(cube, dir, pos, weights);
        if (half_w == 0) continue;
        var temp = (@as(f64, @floatFromInt(half_r)) * @as(f64, @floatFromInt(half_r)) +
            @as(f64, @floatFromInt(half_g)) * @as(f64, @floatFromInt(half_g)) +
            @as(f64, @floatFromInt(half_b)) * @as(f64, @floatFromInt(half_b))) /
            @as(f64, @floatFromInt(half_w));
        half_r = whole_r - half_r;
        half_g = whole_g - half_g;
        half_b = whole_b - half_b;
        half_w = whole_w - half_w;
        if (half_w == 0) continue;
        temp += (@as(f64, @floatFromInt(half_r)) * @as(f64, @floatFromInt(half_r)) +
            @as(f64, @floatFromInt(half_g)) * @as(f64, @floatFromInt(half_g)) +
            @as(f64, @floatFromInt(half_b)) * @as(f64, @floatFromInt(half_b))) /
            @as(f64, @floatFromInt(half_w));
        if (temp > max) {
            max = temp;
            cut.* = i;
        }
    }
    return max;
}

fn wuCut(
    box1: *Box,
    box2: *Box,
    weights: []const i64,
    m_r: []const i64,
    m_g: []const i64,
    m_b: []const i64,
) bool {
    const whole_r = wuVol(box1.*, m_r);
    const whole_g = wuVol(box1.*, m_g);
    const whole_b = wuVol(box1.*, m_b);
    const whole_w = wuVol(box1.*, weights);
    var cut_r: i32 = -1;
    var cut_g: i32 = -1;
    var cut_b: i32 = -1;
    const max_r = wuMaximize(box1.*, .red, box1.r0 + 1, box1.r1, &cut_r, whole_w, whole_r, whole_g, whole_b, weights, m_r, m_g, m_b);
    const max_g = wuMaximize(box1.*, .green, box1.g0 + 1, box1.g1, &cut_g, whole_w, whole_r, whole_g, whole_b, weights, m_r, m_g, m_b);
    const max_b = wuMaximize(box1.*, .blue, box1.b0 + 1, box1.b1, &cut_b, whole_w, whole_r, whole_g, whole_b, weights, m_r, m_g, m_b);
    const dir: Direction = if (max_r >= max_g and max_r >= max_b) .red else if (max_g >= max_r and max_g >= max_b) .green else .blue;
    if (dir == .red and cut_r < 0) return false;

    box2.r1 = box1.r1;
    box2.g1 = box1.g1;
    box2.b1 = box1.b1;
    switch (dir) {
        .red => {
            box2.r0 = cut_r;
            box1.r1 = cut_r;
            box2.g0 = box1.g0;
            box2.b0 = box1.b0;
        },
        .green => {
            box2.r0 = box1.r0;
            box2.g0 = cut_g;
            box1.g1 = cut_g;
            box2.b0 = box1.b0;
        },
        .blue => {
            box2.r0 = box1.r0;
            box2.g0 = box1.g0;
            box2.b0 = cut_b;
            box1.b1 = cut_b;
        },
    }
    box1.vol = (box1.r1 - box1.r0) * (box1.g1 - box1.g0) * (box1.b1 - box1.b0);
    box2.vol = (box2.r1 - box2.r0) * (box2.g1 - box2.g0) * (box2.b1 - box2.b0);
    return true;
}

pub fn quantizeWu(alloc: std.mem.Allocator, pixels: []const utils.Argb, max_colors: u16) !std.ArrayList(utils.Argb) {
    var out = std.ArrayList(utils.Argb).empty;
    if (max_colors == 0 or max_colors > wu_max_colors or pixels.len == 0) return out;

    const weights = try alloc.alloc(i64, wu_total_size);
    defer alloc.free(weights);
    const m_r = try alloc.alloc(i64, wu_total_size);
    defer alloc.free(m_r);
    const m_g = try alloc.alloc(i64, wu_total_size);
    defer alloc.free(m_g);
    const m_b = try alloc.alloc(i64, wu_total_size);
    defer alloc.free(m_b);
    const moments = try alloc.alloc(f64, wu_total_size);
    defer alloc.free(moments);
    @memset(weights, 0);
    @memset(m_r, 0);
    @memset(m_g, 0);
    @memset(m_b, 0);
    @memset(moments, 0.0);

    for (pixels) |px| {
        const r = utils.redFromInt(px);
        const g = utils.greenFromInt(px);
        const b = utils.blueFromInt(px);
        const ir: usize = @as(usize, r >> 3) + 1;
        const ig: usize = @as(usize, g >> 3) + 1;
        const ib: usize = @as(usize, b >> 3) + 1;
        const idx = getIndex(ir, ig, ib);
        weights[idx] += 1;
        m_r[idx] += r;
        m_g[idx] += g;
        m_b[idx] += b;
        moments[idx] += @as(f64, @floatFromInt(@as(i32, r) * @as(i32, r) + @as(i32, g) * @as(i32, g) + @as(i32, b) * @as(i32, b)));
    }

    // Summed-area table over r, then g, then b (ComputeMoments).
    var r: usize = 1;
    while (r < index_count) : (r += 1) {
        var area = @as([index_count]i64, @splat(0));
        var area_r = @as([index_count]i64, @splat(0));
        var area_g = @as([index_count]i64, @splat(0));
        var area_b = @as([index_count]i64, @splat(0));
        var area_2 = @as([index_count]f64, @splat(0.0));
        var g: usize = 1;
        while (g < index_count) : (g += 1) {
            var line: i64 = 0;
            var line_r: i64 = 0;
            var line_g: i64 = 0;
            var line_b: i64 = 0;
            var line_2: f64 = 0.0;
            var b: usize = 1;
            while (b < index_count) : (b += 1) {
                const idx = getIndex(r, g, b);
                line += weights[idx];
                line_r += m_r[idx];
                line_g += m_g[idx];
                line_b += m_b[idx];
                line_2 += moments[idx];
                area[b] += line;
                area_r[b] += line_r;
                area_g[b] += line_g;
                area_b[b] += line_b;
                area_2[b] += line_2;
                const prev = getIndex(r - 1, g, b);
                weights[idx] = weights[prev] + area[b];
                m_r[idx] = m_r[prev] + area_r[b];
                m_g[idx] = m_g[prev] + area_g[b];
                m_b[idx] = m_b[prev] + area_b[b];
                moments[idx] = moments[prev] + area_2[b];
            }
        }
    }

    var cubes = try alloc.alloc(Box, wu_max_colors);
    defer alloc.free(cubes);
    for (cubes) |*c| c.* = .{};
    cubes[0].r1 = index_count - 1;
    cubes[0].g1 = index_count - 1;
    cubes[0].b1 = index_count - 1;
    var volume_variance = try alloc.alloc(f64, wu_max_colors);
    defer alloc.free(volume_variance);
    @memset(volume_variance, 0.0);

    var mc: usize = max_colors;
    var next: usize = 0;
    var i: usize = 1;
    while (i < mc) {
        if (wuCut(&cubes[next], &cubes[i], weights, m_r, m_g, m_b)) {
            volume_variance[next] = if (cubes[next].vol > 1)
                wuVariance(cubes[next], weights, m_r, m_g, m_b, moments)
            else
                0.0;
            volume_variance[i] = if (cubes[i].vol > 1)
                wuVariance(cubes[i], weights, m_r, m_g, m_b, moments)
            else
                0.0;
            i += 1;
        } else {
            volume_variance[next] = 0.0;
        }
        next = 0;
        var temp = volume_variance[0];
        // `j <= i` reads one past the freshly cut cube; the slot
        // is zero-initialised and stays zero until its own cut, so the bound
        // is load-bearing for identical behavior.
        var j: usize = 1;
        while (j <= i) : (j += 1) {
            if (volume_variance[j] > temp) {
                temp = volume_variance[j];
                next = j;
            }
        }
        if (temp <= 0.0) {
            mc = i + 1;
            break;
        }
    }

    for (cubes[0..mc]) |cube| {
        const w = wuVol(cube, weights);
        if (w > 0) {
            const red: i32 = @intCast(@divTrunc(wuVol(cube, m_r), w));
            const green: i32 = @intCast(@divTrunc(wuVol(cube, m_g), w));
            const blue: i32 = @intCast(@divTrunc(wuVol(cube, m_b), w));
            try out.append(alloc, utils.argbFromRgb(red, green, blue));
        }
    }
    return out;
}

pub const QuantizerResult = struct {
    color_to_count: std.AutoHashMap(utils.Argb, u32),
    input_pixel_to_cluster_pixel: std.AutoHashMap(utils.Argb, utils.Argb),

    pub fn deinit(self: *QuantizerResult) void {
        self.color_to_count.deinit();
        self.input_pixel_to_cluster_pixel.deinit();
    }
};

const ws_max_iterations: usize = 100;
const ws_min_delta_e: f64 = 3.0;

const Swatch = struct {
    argb: utils.Argb,
    population: i32,
};

fn swatchLess(_: void, a: Swatch, b: Swatch) bool {
    return a.population > b.population;
}

const DistIdx = struct {
    distance: f64,
    index: usize,
};

fn distIdxLess(_: void, a: DistIdx, b: DistIdx) bool {
    return a.distance < b.distance;
}

pub fn quantizeWsmeans(
    alloc: std.mem.Allocator,
    input_pixels: []const utils.Argb,
    starting_clusters: []const utils.Argb,
    max_colors: u16,
) !QuantizerResult {
    var result = QuantizerResult{
        .color_to_count = std.AutoHashMap(utils.Argb, u32).init(alloc),
        .input_pixel_to_cluster_pixel = std.AutoHashMap(utils.Argb, utils.Argb).init(alloc),
    };
    errdefer result.deinit();
    if (max_colors == 0 or input_pixels.len == 0) return result;
    var mc: usize = max_colors;
    if (mc > 256) mc = 256;

    var pixel_to_count = std.AutoHashMap(utils.Argb, i32).init(alloc);
    defer pixel_to_count.deinit();
    var pixels = std.ArrayList(utils.Argb).empty;
    defer pixels.deinit(alloc);
    var points = std.ArrayList(Lab).empty;
    defer points.deinit(alloc);
    for (input_pixels) |px| {
        const e = try pixel_to_count.getOrPut(px);
        if (e.found_existing) {
            e.value_ptr.* += 1;
        } else {
            e.value_ptr.* = 1;
            try pixels.append(alloc, px);
            try points.append(alloc, labFromInt(px));
        }
    }

    var cluster_count: usize = @min(mc, points.items.len);
    if (starting_clusters.len > 0) {
        cluster_count = @min(cluster_count, starting_clusters.len);
    }

    var pixel_count_sums = try alloc.alloc(i32, 256);
    defer alloc.free(pixel_count_sums);
    @memset(pixel_count_sums, 0);

    var clusters = std.ArrayList(Lab).empty;
    defer clusters.deinit(alloc);
    for (starting_clusters) |c| try clusters.append(alloc, labFromInt(c));

    var rng = rand.Rand31.seed(42688);
    const additional = if (cluster_count >= clusters.items.len) cluster_count - clusters.items.len else 0;
    if (starting_clusters.len == 0 and additional > 0) {
        for (0..additional) |_| {
            try clusters.append(alloc, .{
                .l = rng.nextUnit() * 100.0,
                .a = rng.nextUnit() * 200.0 - 100.0,
                .b = rng.nextUnit() * 200.0 - 100.0,
            });
        }
    }

    var cluster_indices = std.ArrayList(usize).empty;
    defer cluster_indices.deinit(alloc);
    var rng2 = rand.Rand31.seed(42688);
    for (points.items) |_| {
        try cluster_indices.append(alloc, @as(usize, @intCast(@rem(rng2.next(), @as(i32, @intCast(cluster_count))))));
    }

    var index_matrix = try alloc.alloc(usize, cluster_count * cluster_count);
    defer alloc.free(index_matrix);
    var dist_matrix = try alloc.alloc(DistIdx, cluster_count * cluster_count);
    defer alloc.free(dist_matrix);

    // `component_*_sums[256]` + `pixel_count_sums` are refreshed every pass.
    var comp_a = try alloc.alloc(f64, 256);
    defer alloc.free(comp_a);
    var comp_b = try alloc.alloc(f64, 256);
    defer alloc.free(comp_b);
    var comp_c = try alloc.alloc(f64, 256);
    defer alloc.free(comp_c);

    var row = std.ArrayList(DistIdx).empty;
    defer row.deinit(alloc);

    var iteration: usize = 0;
    while (iteration < ws_max_iterations) : (iteration += 1) {
        for (0..cluster_count) |ii| {
            dist_matrix[ii * cluster_count + ii] = .{ .distance = 0.0, .index = ii };
            for (ii + 1..cluster_count) |jj| {
                const d = clusters.items[ii].deltaE(clusters.items[jj]);
                dist_matrix[jj * cluster_count + ii] = .{ .distance = d, .index = ii };
                dist_matrix[ii * cluster_count + jj] = .{ .distance = d, .index = jj };
            }
            row.clearRetainingCapacity();
            for (0..cluster_count) |jj| try row.append(alloc, dist_matrix[ii * cluster_count + jj]);
            std.mem.sort(DistIdx, row.items, {}, distIdxLess);
            for (0..cluster_count) |jj| index_matrix[ii * cluster_count + jj] = row.items[jj].index;
        }

        var color_moved = false;
        for (points.items, 0..) |point, pi| {
            const prev_idx = cluster_indices.items[pi];
            const prev_dist = point.deltaE(clusters.items[prev_idx]);
            var min_dist = prev_dist;
            var new_idx: ?usize = null;
            for (0..cluster_count) |jj| {
                if (dist_matrix[prev_idx * cluster_count + jj].distance >= 4.0 * prev_dist) continue;
                const d = point.deltaE(clusters.items[jj]);
                if (d < min_dist) {
                    min_dist = d;
                    new_idx = jj;
                }
            }
            if (new_idx) |ni| {
                // Integer `abs()` truncates toward zero — so a
                // 3.62 change reads as 3 and does NOT move. `@trunc` replicates
                // the truncation; plain `@abs` moved a pixel too eagerly.
                const change = @trunc(@abs(@sqrt(min_dist) - @sqrt(prev_dist)));
                if (change > ws_min_delta_e) {
                    color_moved = true;
                    cluster_indices.items[pi] = ni;
                }
            }
        }

        if (!color_moved and iteration != 0) break;

        @memset(comp_a, 0.0);
        @memset(comp_b, 0.0);
        @memset(comp_c, 0.0);
        @memset(pixel_count_sums, 0);
        for (points.items, 0..) |point, pi| {
            const ci = cluster_indices.items[pi];
            const count = pixel_to_count.get(pixels.items[pi]).?;
            pixel_count_sums[ci] += count;
            comp_a[ci] += point.l * @as(f64, @floatFromInt(count));
            comp_b[ci] += point.a * @as(f64, @floatFromInt(count));
            comp_c[ci] += point.b * @as(f64, @floatFromInt(count));
        }
        for (0..cluster_count) |ci| {
            const count = pixel_count_sums[ci];
            if (count == 0) {
                clusters.items[ci] = .{ .l = 0.0, .a = 0.0, .b = 0.0 };
                continue;
            }
            clusters.items[ci] = .{
                .l = comp_a[ci] / @as(f64, @floatFromInt(count)),
                .a = comp_b[ci] / @as(f64, @floatFromInt(count)),
                .b = comp_c[ci] / @as(f64, @floatFromInt(count)),
            };
        }
    }

    var swatches = std.ArrayList(Swatch).empty;
    defer swatches.deinit(alloc);
    var cluster_argbs = std.ArrayList(utils.Argb).empty;
    defer cluster_argbs.deinit(alloc);
    var all_cluster_argbs = std.ArrayList(utils.Argb).empty;
    defer all_cluster_argbs.deinit(alloc);
    for (clusters.items, 0..) |cl, ci| {
        const cand = intFromLab(cl);
        try all_cluster_argbs.append(alloc, cand);
        const count = pixel_count_sums[ci];
        if (count == 0) continue;
        var merged = false;
        for (swatches.items) |*sw| {
            if (sw.argb == cand) {
                sw.population += count;
                merged = true;
                break;
            }
        }
        if (merged) continue;
        try cluster_argbs.append(alloc, cand);
        try swatches.append(alloc, .{ .argb = cand, .population = count });
    }
    std.mem.sort(Swatch, swatches.items, {}, swatchLess);

    for (swatches.items) |sw| {
        try result.color_to_count.put(sw.argb, @intCast(sw.population));
    }
    for (points.items, 0..) |_, pi| {
        try result.input_pixel_to_cluster_pixel.put(pixels.items[pi], all_cluster_argbs.items[cluster_indices.items[pi]]);
    }
    return result;
}

pub fn quantizeCelebi(
    alloc: std.mem.Allocator,
    pixels: []const utils.Argb,
    max_colors: u16,
) !QuantizerResult {
    if (max_colors == 0 or pixels.len == 0) {
        return QuantizerResult{
            .color_to_count = std.AutoHashMap(utils.Argb, u32).init(alloc),
            .input_pixel_to_cluster_pixel = std.AutoHashMap(utils.Argb, utils.Argb).init(alloc),
        };
    }
    var mc = max_colors;
    if (mc > 256) mc = 256;

    var opaque_px = std.ArrayList(utils.Argb).empty;
    defer opaque_px.deinit(alloc);
    for (pixels) |px| {
        if (utils.isOpaque(px)) try opaque_px.append(alloc, px);
    }

    var wu = try quantizeWu(alloc, opaque_px.items, mc);
    defer wu.deinit(alloc);
    return try quantizeWsmeans(alloc, opaque_px.items, wu.items, mc);
}

const CountPair = struct {
    c: utils.Argb,
    n: u32,
};

fn countPairLess(_: void, a: CountPair, b: CountPair) bool {
    return a.c < b.c;
}

fn sortedCounts(
    alloc: std.mem.Allocator,
    map: *std.AutoHashMap(utils.Argb, u32),
    out: *std.ArrayList(CountPair),
) !void {
    var it = map.iterator();
    while (it.next()) |e| try out.append(alloc, .{ .c = e.key_ptr.*, .n = e.value_ptr.* });
    std.mem.sort(CountPair, out.items, {}, countPairLess);
}

test "mcu-quantize: eight flat colors survive celebi" {
    const t = std.testing;
    const alloc = t.allocator;
    const pal = [_]utils.Argb{ 0xFFD32F2F, 0xFF1976D2, 0xFF388E3C, 0xFFFBC02D, 0xFF7B1FA2, 0xFF0097A3, 0xFF5D4037, 0xFF455A64 };
    var px = std.ArrayList(utils.Argb).empty;
    defer px.deinit(alloc);
    for (0..112 * 112) |i| {
        const k: usize = (@as(u32, @intCast(i)) *% 2654435761) >> 8;
        try px.append(alloc, pal[k % 8]);
    }
    var q = try quantizeCelebi(alloc, px.items, 128);
    defer q.deinit();
    var got = std.ArrayList(CountPair).empty;
    defer got.deinit(alloc);
    try sortedCounts(alloc, &q.color_to_count, &got);
    const want = [_]CountPair{
        .{ .c = 0xFF0097A3, .n = 1570 },
        .{ .c = 0xFF1976D2, .n = 1568 },
        .{ .c = 0xFF388E3C, .n = 1567 },
        .{ .c = 0xFF455A64, .n = 1568 },
        .{ .c = 0xFF5D4037, .n = 1567 },
        .{ .c = 0xFF7B1FA2, .n = 1566 },
        .{ .c = 0xFFD32F2F, .n = 1568 },
        .{ .c = 0xFFFBC02D, .n = 1570 },
    };
    try t.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| {
        try t.expectEqual(w.c, g.c);
        try t.expectEqual(w.n, g.n);
    }
}

test "mcu-quantize: gradient celebi matches the oracle exactly" {
    const t = std.testing;
    const alloc = t.allocator;
    var px = std.ArrayList(utils.Argb).empty;
    defer px.deinit(alloc);
    for (0..112) |y| {
        for (0..112) |x| {
            const r: u32 = @intCast((x * 255) / 111);
            const g: u32 = @intCast((y * 255) / 111);
            const b: u32 = @intCast(((x + y) * 255) / 222);
            try px.append(alloc, 0xFF000000 | (r << 16) | (g << 8) | b);
        }
    }
    var q = try quantizeCelebi(alloc, px.items, 128);
    defer q.deinit();
    var got = std.ArrayList(CountPair).empty;
    defer got.deinit(alloc);
    try sortedCounts(alloc, &q.color_to_count, &got);
    const want = [_]CountPair{
        .{ .c = 0xFF07EE7A, .n = 78 },
        .{ .c = 0xFF082316, .n = 46 },
        .{ .c = 0xFF0B0F0D, .n = 100 },
        .{ .c = 0xFF0B6F3D, .n = 87 },
        .{ .c = 0xFF0B904D, .n = 74 },
        .{ .c = 0xFF0C3621, .n = 88 },
        .{ .c = 0xFF0D472A, .n = 96 },
        .{ .c = 0xFF0F5D35, .n = 119 },
        .{ .c = 0xFF0FA057, .n = 89 },
        .{ .c = 0xFF0FC469, .n = 118 },
        .{ .c = 0xFF108148, .n = 96 },
        .{ .c = 0xFF11B260, .n = 107 },
        .{ .c = 0xFF11DA74, .n = 138 },
        .{ .c = 0xFF17F887, .n = 88 },
        .{ .c = 0xFF18251E, .n = 97 },
        .{ .c = 0xFF1A0811, .n = 82 },
        .{ .c = 0xFF233F31, .n = 103 },
        .{ .c = 0xFF23774D, .n = 96 },
        .{ .c = 0xFF23985D, .n = 102 },
        .{ .c = 0xFF245B3F, .n = 101 },
        .{ .c = 0xFF2A1E24, .n = 84 },
        .{ .c = 0xFF2CCA7A, .n = 99 },
        .{ .c = 0xFF2DF38F, .n = 131 },
        .{ .c = 0xFF2EB471, .n = 125 },
        .{ .c = 0xFF2EDB84, .n = 114 },
        .{ .c = 0xFF351525, .n = 98 },
        .{ .c = 0xFF393537, .n = 110 },
        .{ .c = 0xFF399064, .n = 101 },
        .{ .c = 0xFF3A0821, .n = 92 },
        .{ .c = 0xFF3A7055, .n = 96 },
        .{ .c = 0xFF3B4540, .n = 95 },
        .{ .c = 0xFF3C5C4C, .n = 124 },
        .{ .c = 0xFF3D805E, .n = 92 },
        .{ .c = 0xFF3DA06E, .n = 86 },
        .{ .c = 0xFF41B279, .n = 85 },
        .{ .c = 0xFF44D08A, .n = 111 },
        .{ .c = 0xFF45F29B, .n = 117 },
        .{ .c = 0xFF4F2A3C, .n = 107 },
        .{ .c = 0xFF51062C, .n = 68 },
        .{ .c = 0xFF533E49, .n = 103 },
        .{ .c = 0xFF535C57, .n = 100 },
        .{ .c = 0xFF537865, .n = 110 },
        .{ .c = 0xFF541736, .n = 87 },
        .{ .c = 0xFF549776, .n = 112 },
        .{ .c = 0xFF56B686, .n = 92 },
        .{ .c = 0xFF57CE92, .n = 106 },
        .{ .c = 0xFF59F0A4, .n = 126 },
        .{ .c = 0xFF63E7A5, .n = 86 },
        .{ .c = 0xFF645A5F, .n = 98 },
        .{ .c = 0xFF682646, .n = 93 },
        .{ .c = 0xFF69B28D, .n = 125 },
        .{ .c = 0xFF6A0D3B, .n = 119 },
        .{ .c = 0xFF6A736F, .n = 114 },
        .{ .c = 0xFF6A9C83, .n = 95 },
        .{ .c = 0xFF6B8A7A, .n = 101 },
        .{ .c = 0xFF6C4358, .n = 105 },
        .{ .c = 0xFF6ECB9C, .n = 111 },
        .{ .c = 0xFF765B68, .n = 75 },
        .{ .c = 0xFF773958, .n = 96 },
        .{ .c = 0xFF77E0AC, .n = 101 },
        .{ .c = 0xFF7BF6B9, .n = 102 },
        .{ .c = 0xFF7F0F46, .n = 105 },
        .{ .c = 0xFF7F2652, .n = 91 },
        .{ .c = 0xFF817179, .n = 84 },
        .{ .c = 0xFF82A191, .n = 75 },
        .{ .c = 0xFF858D89, .n = 118 },
        .{ .c = 0xFF86C7A6, .n = 103 },
        .{ .c = 0xFF88B69F, .n = 113 },
        .{ .c = 0xFF895C72, .n = 83 },
        .{ .c = 0xFF91476C, .n = 101 },
        .{ .c = 0xFF91DAB6, .n = 103 },
        .{ .c = 0xFF92064C, .n = 75 },
        .{ .c = 0xFF943363, .n = 91 },
        .{ .c = 0xFF947484, .n = 82 },
        .{ .c = 0xFF948A8F, .n = 94 },
        .{ .c = 0xFF94F3C3, .n = 126 },
        .{ .c = 0xFF961B58, .n = 95 },
        .{ .c = 0xFF965A78, .n = 86 },
        .{ .c = 0xFF97ACA1, .n = 82 },
        .{ .c = 0xFFA3A9A6, .n = 66 },
        .{ .c = 0xFFA5F0CA, .n = 78 },
        .{ .c = 0xFFA7336D, .n = 93 },
        .{ .c = 0xFFA81960, .n = 110 },
        .{ .c = 0xFFAA4B7A, .n = 102 },
        .{ .c = 0xFFAB7E95, .n = 94 },
        .{ .c = 0xFFABCABA, .n = 132 },
        .{ .c = 0xFFAD9FA6, .n = 76 },
        .{ .c = 0xFFADDDC5, .n = 112 },
        .{ .c = 0xFFAE6A8C, .n = 117 },
        .{ .c = 0xFFAF91A0, .n = 91 },
        .{ .c = 0xFFB2065C, .n = 85 },
        .{ .c = 0xFFB3BAB6, .n = 73 },
        .{ .c = 0xFFB8F5D7, .n = 74 },
        .{ .c = 0xFFBD3378, .n = 103 },
        .{ .c = 0xFFBF1C6D, .n = 104 },
        .{ .c = 0xFFBF4D86, .n = 106 },
        .{ .c = 0xFFC36996, .n = 133 },
        .{ .c = 0xFFC387A5, .n = 106 },
        .{ .c = 0xFFC3B1BA, .n = 90 },
        .{ .c = 0xFFC9C9C9, .n = 105 },
        .{ .c = 0xFFCADAD2, .n = 97 },
        .{ .c = 0xFFCDF3E0, .n = 125 },
        .{ .c = 0xFFD09DB7, .n = 103 },
        .{ .c = 0xFFD22179, .n = 92 },
        .{ .c = 0xFFD30B6E, .n = 126 },
        .{ .c = 0xFFD53685, .n = 83 },
        .{ .c = 0xFFD54C90, .n = 122 },
        .{ .c = 0xFFD5B3C4, .n = 93 },
        .{ .c = 0xFFD785AE, .n = 115 },
        .{ .c = 0xFFD968A0, .n = 120 },
        .{ .c = 0xFFE0EFE8, .n = 100 },
        .{ .c = 0xFFE4CDD8, .n = 109 },
        .{ .c = 0xFFE6B1CB, .n = 65 },
        .{ .c = 0xFFE73A90, .n = 76 },
        .{ .c = 0xFFE90C7A, .n = 87 },
        .{ .c = 0xFFEE268A, .n = 107 },
        .{ .c = 0xFFEEA0C7, .n = 110 },
        .{ .c = 0xFFEFE1E8, .n = 106 },
        .{ .c = 0xFFF050A0, .n = 96 },
        .{ .c = 0xFFF180B8, .n = 88 },
        .{ .c = 0xFFF260A9, .n = 80 },
        .{ .c = 0xFFF26FB1, .n = 81 },
        .{ .c = 0xFFF28FC0, .n = 92 },
        .{ .c = 0xFFF3F4F4, .n = 75 },
        .{ .c = 0xFFF5CADF, .n = 91 },
        .{ .c = 0xFFF6B5D5, .n = 69 },
        .{ .c = 0xFFF83D9B, .n = 80 },
        .{ .c = 0xFFF91485, .n = 102 },
    };
    try t.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| {
        try t.expectEqual(w.c, g.c);
        try t.expectEqual(w.n, g.n);
    }
}
