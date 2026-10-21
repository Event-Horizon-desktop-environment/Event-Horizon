//! material-color-utilities `cpp/cam`: viewing conditions, CAM16 forward and
//! reverse (`cam.cc` + `viewing_conditions.cc`), and the HCT solver
//! (`hct_solver.cc`) with the `Hct` type (`hct.cc`). Tables live in
//! Viewing-condition tables.
//!
//! Bit-parity notes:
//!   * `@rem` for every C `fmod` (`sanitizeRadians`, `SanitizeDegreesDouble`
//!     in utils); `@mod` would floor and diverge on negatives.
//!   * C `abs` on doubles is `@abs`; on ints `@abs` too.
//!   * `(int)floor/ceil` truncate toward zero after the rounding —
//!     `@intFromFloat(@floor(...))` matches.

const std = @import("std");
const utils = @import("utils.zig");
const tables = @import("cam_tables.zig");
const libm = @import("libm.zig");

pub const ViewingConditions = struct {
    adapting_luminance: f64 = 0.0,
    background_lstar: f64 = 0.0,
    surround: f64 = 0.0,
    discounting_illuminant: bool = false,
    background_y_to_white_point_y: f64 = 0.0,
    aw: f64 = 0.0,
    nbb: f64 = 0.0,
    ncb: f64 = 0.0,
    c: f64 = 0.0,
    n_c: f64 = 0.0,
    fl: f64 = 0.0,
    fl_root: f64 = 0.0,
    z: f64 = 0.0,
    white_point: [3]f64 = .{ 0.0, 0.0, 0.0 },
    rgb_d: [3]f64 = .{ 0.0, 0.0, 0.0 },
};

pub const k_default_viewing_conditions = ViewingConditions{
    .adapting_luminance = 11.725676537,
    .background_lstar = 50.0,
    .surround = 2.0,
    .discounting_illuminant = false,
    .background_y_to_white_point_y = 0.184186503,
    .aw = 29.981000900,
    .nbb = 1.016919255,
    .ncb = 1.016919255,
    .c = 0.689999998,
    .n_c = 1.0,
    .fl = 0.388481468,
    .fl_root = 0.789482653,
    .z = 1.909169555,
    .white_point = .{ 95.047, 100.0, 108.883 },
    .rgb_d = .{ 1.021177769, 0.986307740, 0.933960497 },
};

fn vcLerp(start: f64, stop: f64, amount: f64) f64 {
    return (1.0 - amount) * start + amount * stop;
}

pub fn createViewingConditions(
    white_point: [3]f64,
    adapting_luminance: f64,
    background_lstar: f64,
    surround: f64,
    discounting_illuminant: bool,
) ViewingConditions {
    const bl_corrected = if (background_lstar < 30.0) 30.0 else background_lstar;
    const rgb_w = [_]f64{
        0.401288 * white_point[0] + 0.650173 * white_point[1] - 0.051461 * white_point[2],
        -0.250268 * white_point[0] + 1.204414 * white_point[1] + 0.045854 * white_point[2],
        -0.002079 * white_point[0] + 0.048952 * white_point[1] + 0.953127 * white_point[2],
    };
    const f = 0.8 + (surround / 10.0);
    const c = if (f >= 0.9)
        vcLerp(0.59, 0.69, (f - 0.9) * 10.0)
    else
        vcLerp(0.525, 0.59, (f - 0.8) * 10.0);
    var d: f64 = if (discounting_illuminant)
        1.0
    else
        f * (1.0 - ((1.0 / 3.6) * libm.exp((-adapting_luminance - 42.0) / 92.0)));
    d = if (d > 1.0) 1.0 else if (d < 0.0) 0.0 else d;
    const rgb_d = [_]f64{
        d * (100.0 / rgb_w[0]) + 1.0 - d,
        d * (100.0 / rgb_w[1]) + 1.0 - d,
        d * (100.0 / rgb_w[2]) + 1.0 - d,
    };
    const k = 1.0 / (5.0 * adapting_luminance + 1.0);
    const k4 = k * k * k * k;
    const k4f = 1.0 - k4;
    const fl = (k4 * adapting_luminance) +
        (0.1 * k4f * k4f * libm.pow(5.0 * adapting_luminance, 1.0 / 3.0));
    const fl_root = libm.pow(fl, 0.25);
    const n = utils.yFromLstar(bl_corrected) / white_point[1];
    const z = 1.48 + @sqrt(n);
    const nbb = 0.725 / libm.pow(n, 0.2);
    const rgb_a_factors = [_]f64{
        libm.pow(fl * rgb_d[0] * rgb_w[0] / 100.0, 0.42),
        libm.pow(fl * rgb_d[1] * rgb_w[1] / 100.0, 0.42),
        libm.pow(fl * rgb_d[2] * rgb_w[2] / 100.0, 0.42),
    };
    const rgb_a = [_]f64{
        400.0 * rgb_a_factors[0] / (rgb_a_factors[0] + 27.13),
        400.0 * rgb_a_factors[1] / (rgb_a_factors[1] + 27.13),
        400.0 * rgb_a_factors[2] / (rgb_a_factors[2] + 27.13),
    };
    const aw = (40.0 * rgb_a[0] + 20.0 * rgb_a[1] + rgb_a[2]) / 20.0 * nbb;
    return .{
        .adapting_luminance = adapting_luminance,
        .background_lstar = bl_corrected,
        .surround = surround,
        .discounting_illuminant = discounting_illuminant,
        .background_y_to_white_point_y = n,
        .aw = aw,
        .nbb = nbb,
        .ncb = nbb,
        .c = c,
        .n_c = f,
        .fl = fl,
        .fl_root = fl_root,
        .z = z,
        .white_point = white_point,
        .rgb_d = rgb_d,
    };
}

pub fn defaultWithBackgroundLstar(background_lstar: f64) ViewingConditions {
    return createViewingConditions(
        .{ 95.047, 100.0, 108.883 },
        200.0 / utils.k_pi * utils.yFromLstar(50.0) / 100.0,
        background_lstar,
        2.0,
        false,
    );
}

pub const Cam = struct {
    hue: f64 = 0.0,
    chroma: f64 = 0.0,
    j: f64 = 0.0,
    q: f64 = 0.0,
    m: f64 = 0.0,
    s: f64 = 0.0,
    jstar: f64 = 0.0,
    astar: f64 = 0.0,
    bstar: f64 = 0.0,
};

pub fn camFromUcsAndViewingConditions(
    jstar: f64,
    astar: f64,
    bstar: f64,
    vc: ViewingConditions,
) Cam {
    const m = @sqrt(astar * astar + bstar * bstar);
    const m_2 = (libm.exp(m * 0.0228) - 1.0) / 0.0228;
    const c = m_2 / vc.fl_root;
    var h = libm.atan2(bstar, astar) * (180.0 / utils.k_pi);
    if (h < 0.0) h += 360.0;
    const j = jstar / (1.0 - (jstar - 100.0) * 0.007);
    return camFromJchAndViewingConditions(j, c, h, vc);
}

pub fn camFromIntAndViewingConditions(argb: utils.Argb, vc: ViewingConditions) Cam {
    const r_l = utils.linearized(@as(i32, utils.redFromInt(argb)));
    const g_l = utils.linearized(@as(i32, utils.greenFromInt(argb)));
    const b_l = utils.linearized(@as(i32, utils.blueFromInt(argb)));
    const x = 0.41233895 * r_l + 0.35762064 * g_l + 0.18051042 * b_l;
    const y = 0.2126 * r_l + 0.7152 * g_l + 0.0722 * b_l;
    const z = 0.01932141 * r_l + 0.11916382 * g_l + 0.95034478 * b_l;
    return camFromXyzAndViewingConditions(x, y, z, vc);
}

pub fn camFromInt(argb: utils.Argb) Cam {
    return camFromIntAndViewingConditions(argb, k_default_viewing_conditions);
}

fn camFromJchAndViewingConditions(j: f64, c: f64, h: f64, vc: ViewingConditions) Cam {
    const q = (4.0 / vc.c) * @sqrt(j / 100.0) * (vc.aw + 4.0) * vc.fl_root;
    const m = c * vc.fl_root;
    const alpha = c / @sqrt(j / 100.0);
    const s = 50.0 * @sqrt((alpha * vc.c) / (vc.aw + 4.0));
    const hue_radians = h * utils.k_pi / 180.0;
    const jstar = (1.0 + 100.0 * 0.007) * j / (1.0 + 0.007 * j);
    const mstar = 1.0 / 0.0228 * libm.log(1.0 + 0.0228 * m);
    return .{
        .hue = h,
        .chroma = c,
        .j = j,
        .q = q,
        .m = m,
        .s = s,
        .jstar = jstar,
        .astar = mstar * libm.cos(hue_radians),
        .bstar = mstar * libm.sin(hue_radians),
    };
}

pub fn camDistance(a: Cam, b: Cam) f64 {
    const d_j = a.jstar - b.jstar;
    const d_a = a.astar - b.astar;
    const d_b = a.bstar - b.bstar;
    const d_e_prime = @sqrt(d_j * d_j + d_a * d_a + d_b * d_b);
    return 1.41 * libm.pow(d_e_prime, 0.63);
}

pub fn intFromCamAndViewingConditions(cam: Cam, vc: ViewingConditions) utils.Argb {
    const alpha = if (cam.chroma == 0.0 or cam.j == 0.0) 0.0 else cam.chroma / @sqrt(cam.j / 100.0);
    const t = std.math.pow(
        f64,
        alpha / libm.pow(1.64 - libm.pow(0.29, vc.background_y_to_white_point_y), 0.73),
        1.0 / 0.9,
    );
    const h_rad = cam.hue * utils.k_pi / 180.0;
    const e_hue = 0.25 * (libm.cos(h_rad + 2.0) + 3.8);
    const ac = vc.aw * libm.pow(cam.j / 100.0, 1.0 / vc.c / vc.z);
    const p1 = e_hue * (50000.0 / 13.0) * vc.n_c * vc.ncb;
    const p2 = ac / vc.nbb;
    const h_sin = libm.sin(h_rad);
    const h_cos = libm.cos(h_rad);
    const gamma = 23.0 * (p2 + 0.305) * t / (23.0 * p1 + 11.0 * t * h_cos + 108.0 * t * h_sin);
    const a = gamma * h_cos;
    const b = gamma * h_sin;
    const r_a = (460.0 * p2 + 451.0 * a + 288.0 * b) / 1403.0;
    const g_a = (460.0 * p2 - 891.0 * a - 261.0 * b) / 1403.0;
    const b_a = (460.0 * p2 - 220.0 * a - 6300.0 * b) / 1403.0;

    const r_c_base = @max(0.0, (27.13 * @abs(r_a)) / (400.0 - @abs(r_a)));
    const r_c = @as(f64, @floatFromInt(utils.signum(r_a))) * (100.0 / vc.fl) * libm.pow(r_c_base, 1.0 / 0.42);
    const g_c_base = @max(0.0, (27.13 * @abs(g_a)) / (400.0 - @abs(g_a)));
    const g_c = @as(f64, @floatFromInt(utils.signum(g_a))) * (100.0 / vc.fl) * libm.pow(g_c_base, 1.0 / 0.42);
    const b_c_base = @max(0.0, (27.13 * @abs(b_a)) / (400.0 - @abs(b_a)));
    const b_c = @as(f64, @floatFromInt(utils.signum(b_a))) * (100.0 / vc.fl) * libm.pow(b_c_base, 1.0 / 0.42);
    const r_x = r_c / vc.rgb_d[0];
    const g_x = g_c / vc.rgb_d[1];
    const b_x = b_c / vc.rgb_d[2];
    const x = 1.86206786 * r_x - 1.01125463 * g_x + 0.14918677 * b_x;
    const y = 0.38752654 * r_x + 0.62144744 * g_x - 0.00897398 * b_x;
    const z = -0.01584150 * r_x - 0.03412294 * g_x + 1.04996444 * b_x;

    const r_l = 3.2406 * x - 1.5372 * y - 0.4986 * z;
    const g_l = -0.9689 * x + 1.8758 * y + 0.0415 * z;
    const b_l = 0.0557 * x - 0.2040 * y + 1.0570 * z;
    return utils.argbFromRgb(utils.delinearized(r_l), utils.delinearized(g_l), utils.delinearized(b_l));
}

pub fn intFromCam(cam: Cam) utils.Argb {
    return intFromCamAndViewingConditions(cam, k_default_viewing_conditions);
}

pub fn intFromHcl(hue: f64, chroma: f64, lstar: f64) utils.Argb {
    return solveToInt(hue, chroma, lstar);
}

pub fn camFromXyzAndViewingConditions(x: f64, y: f64, z: f64, vc: ViewingConditions) Cam {
    const r_c = 0.401288 * x + 0.650173 * y - 0.051461 * z;
    const g_c = -0.250268 * x + 1.204414 * y + 0.045854 * z;
    const b_c = -0.002079 * x + 0.048952 * y + 0.953127 * z;
    const r_d = vc.rgb_d[0] * r_c;
    const g_d = vc.rgb_d[1] * g_c;
    const b_d = vc.rgb_d[2] * b_c;
    const r_af = libm.pow(vc.fl * @abs(r_d) / 100.0, 0.42);
    const g_af = libm.pow(vc.fl * @abs(g_d) / 100.0, 0.42);
    const b_af = libm.pow(vc.fl * @abs(b_d) / 100.0, 0.42);
    const r_a = @as(f64, @floatFromInt(utils.signum(r_d))) * 400.0 * r_af / (r_af + 27.13);
    const g_a = @as(f64, @floatFromInt(utils.signum(g_d))) * 400.0 * g_af / (g_af + 27.13);
    const b_a = @as(f64, @floatFromInt(utils.signum(b_d))) * 400.0 * b_af / (b_af + 27.13);
    const a = (11.0 * r_a + -12.0 * g_a + b_a) / 11.0;
    const b = (r_a + g_a - 2.0 * b_a) / 9.0;
    const u = (20.0 * r_a + 20.0 * g_a + 21.0 * b_a) / 20.0;
    const p2 = (40.0 * r_a + 20.0 * g_a + b_a) / 20.0;
    const hue = utils.sanitizeDegreesDouble(libm.atan2(b, a) * 180.0 / utils.k_pi);
    const hue_radians = hue * utils.k_pi / 180.0;
    const ac = p2 * vc.nbb;
    const j = 100.0 * libm.pow(ac / vc.aw, vc.c * vc.z);
    const q = (4.0 / vc.c) * @sqrt(j / 100.0) * (vc.aw + 4.0) * vc.fl_root;
    const hue_prime = if (hue < 20.14) hue + 360.0 else hue;
    const e_hue = 0.25 * (libm.cos(hue_prime * utils.k_pi / 180.0 + 2.0) + 3.8);
    const p1 = 50000.0 / 13.0 * e_hue * vc.n_c * vc.ncb;
    const t = p1 * @sqrt(a * a + b * b) / (u + 0.305);
    const alpha = libm.pow(t, 0.9) *
        libm.pow(1.64 - libm.pow(0.29, vc.background_y_to_white_point_y), 0.73);
    const c = alpha * @sqrt(j / 100.0);
    const m = c * vc.fl_root;
    const s = 50.0 * @sqrt((alpha * vc.c) / (vc.aw + 4.0));
    const jstar = (1.0 + 100.0 * 0.007) * j / (1.0 + 0.007 * j);
    const mstar = 1.0 / 0.0228 * libm.log(1.0 + 0.0228 * m);
    return .{
        .hue = hue,
        .chroma = c,
        .j = j,
        .q = q,
        .m = m,
        .s = s,
        .jstar = jstar,
        .astar = mstar * libm.cos(hue_radians),
        .bstar = mstar * libm.sin(hue_radians),
    };
}

fn sanitizeRadians(angle: f64) f64 {
    return @rem(angle + utils.k_pi * 8.0, utils.k_pi * 2.0);
}

fn trueDelinearized(rgb_component: f64) f64 {
    const normalized = rgb_component / 100.0;
    const d = if (normalized <= 0.0031308)
        normalized * 12.92
    else
        1.055 * libm.pow(normalized, 1.0 / 2.4) - 0.055;
    return d * 255.0;
}

fn chromaticAdaptation(component: f64) f64 {
    const af = libm.pow(@abs(component), 0.42);
    return @as(f64, @floatFromInt(utils.signum(component))) * 400.0 * af / (af + 27.13);
}

fn hueOf(linrgb: utils.Vec3) f64 {
    const sd = utils.matrixMultiply(linrgb, tables.k_scaled_discount_from_linrgb);
    const r_a = chromaticAdaptation(sd.a);
    const g_a = chromaticAdaptation(sd.b);
    const b_a = chromaticAdaptation(sd.c);
    const a = (11.0 * r_a + -12.0 * g_a + b_a) / 11.0;
    const b = (r_a + g_a - 2.0 * b_a) / 9.0;
    return libm.atan2(b, a);
}

fn areInCyclicOrder(a: f64, b: f64, c: f64) bool {
    return sanitizeRadians(b - a) < sanitizeRadians(c - a);
}

fn intercept(source: f64, mid: f64, target: f64) f64 {
    return (mid - source) / (target - source);
}

fn lerpPoint(source: utils.Vec3, t: f64, target: utils.Vec3) utils.Vec3 {
    return .{
        .a = source.a + (target.a - source.a) * t,
        .b = source.b + (target.b - source.b) * t,
        .c = source.c + (target.c - source.c) * t,
    };
}

fn getAxis(v: utils.Vec3, axis: usize) f64 {
    return switch (axis) {
        0 => v.a,
        1 => v.b,
        2 => v.c,
        else => -1.0,
    };
}

fn setCoordinate(source: utils.Vec3, coordinate: f64, target: utils.Vec3, axis: usize) utils.Vec3 {
    return lerpPoint(source, intercept(getAxis(source, axis), coordinate, getAxis(target, axis)), target);
}

fn isBounded(x: f64) bool {
    return 0.0 <= x and x <= 100.0;
}

fn nthVertex(y: f64, n: usize) utils.Vec3 {
    const k_r = tables.k_y_from_linrgb[0];
    const k_g = tables.k_y_from_linrgb[1];
    const k_b = tables.k_y_from_linrgb[2];
    const coord_a: f64 = if (n % 4 <= 1) 0.0 else 100.0;
    const coord_b: f64 = if (n % 2 == 0) 0.0 else 100.0;
    if (n < 4) {
        const r = (y - coord_a * k_g - coord_b * k_b) / k_r;
        if (isBounded(r)) return .{ .a = r, .b = coord_a, .c = coord_b };
        return .{ .a = -1.0, .b = -1.0, .c = -1.0 };
    } else if (n < 8) {
        const g = (y - coord_b * k_r - coord_a * k_b) / k_g;
        if (isBounded(g)) return .{ .a = coord_b, .b = g, .c = coord_a };
        return .{ .a = -1.0, .b = -1.0, .c = -1.0 };
    }
    const b = (y - coord_a * k_r - coord_b * k_g) / k_b;
    if (isBounded(b)) return .{ .a = coord_a, .b = coord_b, .c = b };
    return .{ .a = -1.0, .b = -1.0, .c = -1.0 };
}

fn bisectToSegment(y: f64, target_hue: f64, out: *[2]utils.Vec3) void {
    var left = utils.Vec3{ .a = -1.0, .b = -1.0, .c = -1.0 };
    var right = left;
    var left_hue: f64 = 0.0;
    var right_hue: f64 = 0.0;
    var initialized = false;
    var uncut = true;
    for (0..12) |n| {
        const mid = nthVertex(y, n);
        if (mid.a < 0.0) continue;
        const mid_hue = hueOf(mid);
        if (!initialized) {
            left = mid;
            right = mid;
            left_hue = mid_hue;
            right_hue = mid_hue;
            initialized = true;
            continue;
        }
        if (uncut or areInCyclicOrder(left_hue, mid_hue, right_hue)) {
            uncut = false;
            if (areInCyclicOrder(left_hue, target_hue, mid_hue)) {
                right = mid;
                right_hue = mid_hue;
            } else {
                left = mid;
                left_hue = mid_hue;
            }
        }
    }
    out[0] = left;
    out[1] = right;
}

fn midpoint(a: utils.Vec3, b: utils.Vec3) utils.Vec3 {
    return .{ .a = (a.a + b.a) / 2.0, .b = (a.b + b.b) / 2.0, .c = (a.c + b.c) / 2.0 };
}

fn criticalPlaneBelow(x: f64) i32 {
    return @intFromFloat(@floor(x - 0.5));
}

fn criticalPlaneAbove(x: f64) i32 {
    return @intFromFloat(@ceil(x - 0.5));
}

fn bisectToLimit(y: f64, target_hue: f64) utils.Vec3 {
    var segment: [2]utils.Vec3 = undefined;
    bisectToSegment(y, target_hue, &segment);
    var left = segment[0];
    var left_hue = hueOf(left);
    var right = segment[1];
    for (0..3) |axis| {
        if (getAxis(left, axis) != getAxis(right, axis)) {
            var l_plane: i32 = -1;
            var r_plane: i32 = 255;
            if (getAxis(left, axis) < getAxis(right, axis)) {
                l_plane = criticalPlaneBelow(trueDelinearized(getAxis(left, axis)));
                r_plane = criticalPlaneAbove(trueDelinearized(getAxis(right, axis)));
            } else {
                l_plane = criticalPlaneAbove(trueDelinearized(getAxis(left, axis)));
                r_plane = criticalPlaneBelow(trueDelinearized(getAxis(right, axis)));
            }
            for (0..8) |_| {
                if (@abs(r_plane - l_plane) <= 1) break;
                const m_plane: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(l_plane + r_plane)) / 2.0));
                const mid_coord = tables.k_critical_planes[@intCast(m_plane)];
                const mid = setCoordinate(left, mid_coord, right, axis);
                const mid_hue = hueOf(mid);
                if (areInCyclicOrder(left_hue, target_hue, mid_hue)) {
                    right = mid;
                    r_plane = m_plane;
                } else {
                    left = mid;
                    left_hue = mid_hue;
                    l_plane = m_plane;
                }
            }
        }
    }
    return midpoint(left, right);
}

fn inverseChromaticAdaptation(adapted: f64) f64 {
    const base = @max(0.0, 27.13 * @abs(adapted) / (400.0 - @abs(adapted)));
    return @as(f64, @floatFromInt(utils.signum(adapted))) * libm.pow(base, 1.0 / 0.42);
}

fn findResultByJ(hue_radians: f64, chroma: f64, y: f64) utils.Argb {
    var j = @sqrt(y) * 11.0;
    const vc = k_default_viewing_conditions;
    const t_inner_coeff = 1.0 / std.math.pow(
        f64,
        1.64 - libm.pow(0.29, vc.background_y_to_white_point_y),
        0.73,
    );
    const e_hue = 0.25 * (libm.cos(hue_radians + 2.0) + 3.8);
    const p1 = e_hue * (50000.0 / 13.0) * vc.n_c * vc.ncb;
    const h_sin = libm.sin(hue_radians);
    const h_cos = libm.cos(hue_radians);
    for (0..5) |round| {
        const j_norm = j / 100.0;
        const alpha = if (chroma == 0.0 or j == 0.0) 0.0 else chroma / @sqrt(j_norm);
        const t = libm.pow(alpha * t_inner_coeff, 1.0 / 0.9);
        const ac = vc.aw * libm.pow(j_norm, 1.0 / vc.c / vc.z);
        const p2 = ac / vc.nbb;
        const gamma = 23.0 * (p2 + 0.305) * t / (23.0 * p1 + 11.0 * t * h_cos + 108.0 * t * h_sin);
        const a = gamma * h_cos;
        const b = gamma * h_sin;
        const r_a = (460.0 * p2 + 451.0 * a + 288.0 * b) / 1403.0;
        const g_a = (460.0 * p2 - 891.0 * a - 261.0 * b) / 1403.0;
        const b_a = (460.0 * p2 - 220.0 * a - 6300.0 * b) / 1403.0;
        const scaled = utils.Vec3{
            .a = inverseChromaticAdaptation(r_a),
            .b = inverseChromaticAdaptation(g_a),
            .c = inverseChromaticAdaptation(b_a),
        };
        const linrgb = utils.matrixMultiply(scaled, tables.k_linrgb_from_scaled_discount);
        if (linrgb.a < 0.0 or linrgb.b < 0.0 or linrgb.c < 0.0) return 0;
        const fnj = tables.k_y_from_linrgb[0] * linrgb.a +
            tables.k_y_from_linrgb[1] * linrgb.b +
            tables.k_y_from_linrgb[2] * linrgb.c;
        if (fnj <= 0.0) return 0;
        if (round == 4 or @abs(fnj - y) < 0.002) {
            if (linrgb.a > 100.01 or linrgb.b > 100.01 or linrgb.c > 100.01) return 0;
            return utils.argbFromLinrgb(linrgb);
        }
        j = j - (fnj - y) * j / (2.0 * fnj);
    }
    return 0;
}

pub fn solveToInt(hue_degrees: f64, chroma: f64, lstar: f64) utils.Argb {
    if (chroma < 0.0001 or lstar < 0.0001 or lstar > 99.9999) {
        return utils.intFromLstar(lstar);
    }
    const hue = utils.sanitizeDegreesDouble(hue_degrees);
    const hue_radians = hue / 180.0 * utils.k_pi;
    const y = utils.yFromLstar(lstar);
    const exact = findResultByJ(hue_radians, chroma, y);
    if (exact != 0) return exact;
    return utils.argbFromLinrgb(bisectToLimit(y, hue_radians));
}

pub fn solveToCam(hue_degrees: f64, chroma: f64, lstar: f64) Cam {
    return camFromInt(solveToInt(hue_degrees, chroma, lstar));
}

pub const Hct = struct {
    hue: f64 = 0.0,
    chroma: f64 = 0.0,
    tone: f64 = 0.0,
    argb: utils.Argb = 0,

    pub fn fromHct(hue: f64, chroma: f64, tone: f64) Hct {
        var h = Hct{};
        h.setInternalState(solveToInt(hue, chroma, tone));
        return h;
    }

    pub fn fromInt(argb: utils.Argb) Hct {
        var h = Hct{};
        h.setInternalState(argb);
        return h;
    }

    pub fn toInt(self: *const Hct) utils.Argb {
        return self.argb;
    }

    pub fn setHue(self: *Hct, v: f64) void {
        self.setInternalState(solveToInt(v, self.chroma, self.tone));
    }

    pub fn setChroma(self: *Hct, v: f64) void {
        self.setInternalState(solveToInt(self.hue, v, self.tone));
    }

    pub fn setTone(self: *Hct, v: f64) void {
        self.setInternalState(solveToInt(self.hue, self.chroma, v));
    }

    fn setInternalState(self: *Hct, argb: utils.Argb) void {
        self.argb = argb;
        const cam = camFromInt(argb);
        self.hue = cam.hue;
        self.chroma = cam.chroma;
        self.tone = utils.lstarFromArgb(argb);
    }
};

test "mcu-cam: viewing conditions match the reference values" {
    const t = std.testing;
    // NOTE: `adapting_luminance` (11.725676537) is stale —
    // the formula yields 11.725677949 in both languages, bit-identical. What
    // matters is that every *derived* field matches the recomputed values
    // row below (`DefaultWithBackgroundLstar(50)` printed at %.9f).
    const vc = defaultWithBackgroundLstar(50.0);
    try t.expectApproxEqAbs(11.725677949, vc.adapting_luminance, 1e-9);
    try t.expectApproxEqAbs(0.184186519, vc.background_y_to_white_point_y, 1e-9);
    try t.expectApproxEqAbs(29.980997194, vc.aw, 1e-9);
    try t.expectApproxEqAbs(1.016919180, vc.nbb, 1e-9);
    try t.expectApproxEqAbs(1.016919180, vc.ncb, 1e-9);
    try t.expectApproxEqAbs(0.69, vc.c, 1e-9);
    try t.expectApproxEqAbs(0.388481454, vc.fl, 1e-9);
    try t.expectApproxEqAbs(0.789482618, vc.fl_root, 1e-9);
    try t.expectApproxEqAbs(1.909169568, vc.z, 1e-9);
    try t.expectApproxEqAbs(1.021177703, vc.rgb_d[0], 1e-9);
    try t.expectApproxEqAbs(0.986307729, vc.rgb_d[1], 1e-9);
    try t.expectApproxEqAbs(0.933960508, vc.rgb_d[2], 1e-9);
}

test "mcu-cam: hue and chroma match the oracle" {
    const t = std.testing;
    // (argb, hue, chroma) from the driver's `hct` lines.
    const cases = [_]struct { c: utils.Argb, h: f64, ch: f64 }{
        .{ .c = 0xFF4285F4, .h = 265.979403, .ch = 62.269111 },
        .{ .c = 0xFF563925, .h = 53.185119, .ch = 18.705037 },
        .{ .c = 0xFFD32F2F, .h = 23.563744, .ch = 83.318981 },
        .{ .c = 0xFF00BCD4, .h = 212.442995, .ch = 49.961008 },
    };
    for (cases) |cs| {
        const cam = camFromInt(cs.c);
        try t.expectApproxEqAbs(cs.h, cam.hue, 1e-4);
        try t.expectApproxEqAbs(cs.ch, cam.chroma, 1e-4);
    }
    // Black carries no hue information; white is near-achromatic.
    try t.expectApproxEqAbs(0.0, camFromInt(0xFF000000).chroma, 1e-9);
    try t.expectApproxEqAbs(100.0, Hct.fromInt(0xFFFFFFFF).tone, 1e-9);
}

test "mcu-hct: tone of the oracle colors" {
    const t = std.testing;
    try t.expectApproxEqAbs(56.550349, Hct.fromInt(0xFF4285F4).tone, 1e-6);
    try t.expectApproxEqAbs(26.843491, Hct.fromInt(0xFF563925).tone, 1e-6);
    try t.expectApproxEqAbs(47.088620, Hct.fromInt(0xFFD32F2F).tone, 1e-6);
}

test "mcu-hct: solver round-trips hue/chroma/tone" {
    const t = std.testing;
    // (hue, chroma, tone) -> argb -> back. Tones from the oracle `tone` lines.
    const cases = [_]struct { h: f64, c: f64, tone: f64, want: utils.Argb }{
        .{ .h = 250.0, .c = 48.0, .tone = 50.0, .want = 0xFF287CBC },
        .{ .h = 25.0, .c = 84.0, .tone = 50.0, .want = 0xFFDE3730 },
        .{ .h = 0.0, .c = 0.0, .tone = 50.0, .want = 0xFF777777 },
        .{ .h = 250.0, .c = 48.0, .tone = 90.0, .want = 0xFFCFE5FF },
        .{ .h = 25.0, .c = 84.0, .tone = 10.0, .want = 0xFF410002 },
    };
    for (cases) |cs| {
        try t.expectEqual(cs.want, solveToInt(cs.h, cs.c, cs.tone));
    }
}


