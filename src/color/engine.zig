//! Horizon Colors engine: wallpaper image (or explicit seed) →
//! full M3 scheme → chrome colors + the 47 template roles.
//!
//! Fidelity notes:
//!   * The 112×112 triangle resize reproduces the reference filter in `f32`
//!     with plain IEEE evaluation. The inner product is marked
//!     `volatile` to stop GCC fusing it into an FMA; Zig never fuses without
//!     explicitly requested fast-math, so plain arithmetic already matches.
//!     (`@round` is half-away-from-zero like C `round`.)
//!   * JPEGs may pick a different seed (libjpeg-turbo IDCT
//!     rounds ±3 off stb on ~1.7% of pixels). PNG/BMP decode stb on both sides
//!     and are exact.
//!   * The palette disk cache shares the file layout
//!     (`$XDG_STATE_HOME/event-horizon/palette-cache/%016x.palette` with
//!     `seed=`/`key=` lines) so a cached seed is a hit here.

const std = @import("std");
const cam = @import("mcu/cam.zig");
const dynamic = @import("mcu/dynamic.zig");
const palette = @import("mcu/palette.zig");
const quantize = @import("mcu/quantize.zig");
const score = @import("mcu/score.zig");
const utils = @import("mcu/utils.zig");
const decode = @import("../wallpaper/decode.zig");

pub const SchemeVariant = enum {
    tonal_spot,
    vibrant,
    expressive,
    content,
    fidelity,
    monochrome,
    neutral,
    rainbow,
    fruit_salad,
};

/// What the full pipeline produces, with `f32` channels.
pub const PaletteResult = struct {
    ok: bool = false,
    dock_fill: [3]f32 = .{ 0, 0, 0 },
    panel_fill: [3]f32 = .{ 0, 0, 0 },
    drawer_dim: [3]f32 = .{ 0, 0, 0 },
    outline: [3]f32 = .{ 0, 0, 0 },
    accent: [3]f32 = .{ 0, 0, 0 },
    text: [3]f32 = .{ 0, 0, 0 },
    notif_critical_bg: [3]f32 = .{ 0, 0, 0 },
    notif_critical_outline: [3]f32 = .{ 0, 0, 0 },
    source_color_argb: u32 = 0,
    /// The 47 M3 roles in `scheme_to_result` order (0=primary … 46).
    roles: [47]u32 = @as([47]u32, @splat(0)),
};

/// Fixed resample grid edge, regardless of source aspect.
pub const target_dim: i32 = 112;

/// Triangle (bilinear) resample of ARGB `src` (`sw`×`sh`) into `dst`
/// (`nw`×`nh`): vertical pass to float triplets, then horizontal back to
/// bytes — the reference pipeline's filter, including its rounding.
pub fn resizeTriangleToGrid(
    alloc: std.mem.Allocator,
    src: []const u32,
    sw: i32,
    sh: i32,
    dst: []u32,
    nw: i32,
    nh: i32,
) !void {
    std.debug.assert(dst.len >= @as(usize, @intCast(nw * nh)));
    const tmp = try alloc.alloc(f32, @as(usize, @intCast(sw * nh * 4)));
    defer alloc.free(tmp);
    // Largest tap count on either pass, plus slack.
    const taps: usize = @intCast(2 * (@divTrunc(@max(sw, sh) + nh - 1, nh) + 2) + 4);
    const ws = try alloc.alloc(f32, taps);
    defer alloc.free(ws);

    // Pass 1, vertical: 8-bit pixels to (sw × nh) floats.
    const ratio_v: f32 = @as(f32, @floatFromInt(sh)) / @as(f32, @floatFromInt(nh));
    const sratio_v: f32 = if (ratio_v < 1.0) 1.0 else ratio_v;
    var outy: i32 = 0;
    while (outy < nh) : (outy += 1) {
        var inputy = (@as(f32, @floatFromInt(outy)) + 0.5) * ratio_v;
        var left: i64 = @intFromFloat(@floor(inputy - sratio_v));
        left = std.math.clamp(left, 0, @as(i64, sh) - 1);
        var right: i64 = @intFromFloat(@ceil(inputy + sratio_v));
        right = std.math.clamp(right, left + 1, @as(i64, sh));
        inputy -= 0.5;

        var sum: f32 = 0.0;
        var i = left;
        while (i < right) : (i += 1) {
            const x = (@as(f32, @floatFromInt(i)) - inputy) / sratio_v;
            const w: f32 = if (@abs(x) < 1.0) 1.0 - @abs(x) else 0.0;
            ws[@intCast(i - left)] = w;
            sum += w;
        }
        i = left;
        while (i < right) : (i += 1) {
            ws[@intCast(i - left)] /= sum;
        }

        var x: i32 = 0;
        while (x < sw) : (x += 1) {
            var t0: f32 = 0.0;
            var t1: f32 = 0.0;
            var t2: f32 = 0.0;
            var t3: f32 = 0.0;
            i = left;
            while (i < right) : (i += 1) {
                const px = src[@as(usize, @intCast(x + i * sw))];
                const w = ws[@intCast(i - left)];
                t0 += @as(f32, @floatFromInt((px >> 24) & 0xFF)) * w;
                t1 += @as(f32, @floatFromInt((px >> 16) & 0xFF)) * w;
                t2 += @as(f32, @floatFromInt((px >> 8) & 0xFF)) * w;
                t3 += @as(f32, @floatFromInt(px & 0xFF)) * w;
            }
            const o: usize = @intCast((x + outy * sw) * 4);
            tmp[o] = t0;
            tmp[o + 1] = t1;
            tmp[o + 2] = t2;
            tmp[o + 3] = t3;
        }
    }

    // Pass 2, horizontal: floats back to 8-bit at the final width.
    const ratio_h: f32 = @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(nw));
    const sratio_h: f32 = if (ratio_h < 1.0) 1.0 else ratio_h;
    var outx: i32 = 0;
    while (outx < nw) : (outx += 1) {
        var inputx = (@as(f32, @floatFromInt(outx)) + 0.5) * ratio_h;
        var left: i64 = @intFromFloat(@floor(inputx - sratio_h));
        left = std.math.clamp(left, 0, @as(i64, sw) - 1);
        var right: i64 = @intFromFloat(@ceil(inputx + sratio_h));
        right = std.math.clamp(right, left + 1, @as(i64, sw));
        inputx -= 0.5;

        var sum: f32 = 0.0;
        var i = left;
        while (i < right) : (i += 1) {
            const x = (@as(f32, @floatFromInt(i)) - inputx) / sratio_h;
            const w: f32 = if (@abs(x) < 1.0) 1.0 - @abs(x) else 0.0;
            ws[@intCast(i - left)] = w;
            sum += w;
        }
        i = left;
        while (i < right) : (i += 1) {
            ws[@intCast(i - left)] /= sum;
        }

        var y: i32 = 0;
        while (y < nh) : (y += 1) {
            var t0: f32 = 0.0;
            var t1: f32 = 0.0;
            var t2: f32 = 0.0;
            var t3: f32 = 0.0;
            i = left;
            while (i < right) : (i += 1) {
                const p: usize = @intCast((i + y * sw) * 4);
                const w = ws[@intCast(i - left)];
                t0 += tmp[p] * w;
                t1 += tmp[p + 1] * w;
                t2 += tmp[p + 2] * w;
                t3 += tmp[p + 3] * w;
            }
            dst[@intCast(outx + y * nw)] =
                (@as(u32, roundU8(t0)) << 24) |
                (@as(u32, roundU8(t1)) << 16) |
                (@as(u32, roundU8(t2)) << 8) |
                @as(u32, roundU8(t3));
        }
    }
}

fn u32Less(_: void, a: u32, b: u32) bool {
    return a < b;
}

fn roundU8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 255.0)));
}

/// Builds a `DynamicScheme` the way `create_scheme` does — including the
/// hand-built Vibrant (neutral ramps at chroma 10, not the vendored 12).
pub fn createScheme(
    alloc: std.mem.Allocator,
    hct: cam.Hct,
    variant: SchemeVariant,
    is_dark: bool,
    contrast_level: f64,
) !dynamic.DynamicScheme {
    switch (variant) {
        .tonal_spot => return dynamic.tonalSpotScheme(hct, is_dark, contrast_level),
        .vibrant => {
            const hues = [_]f64{ 0.0, 41.0, 61.0, 101.0, 131.0, 181.0, 251.0, 301.0, 360.0 };
            const sec = [_]f64{ 18.0, 15.0, 10.0, 12.0, 15.0, 18.0, 15.0, 12.0, 12.0 };
            const ter = [_]f64{ 35.0, 30.0, 20.0, 25.0, 30.0, 35.0, 30.0, 25.0, 25.0 };
            return dynamic.DynamicScheme.init(
                hct,
                .vibrant,
                contrast_level,
                is_dark,
                palette.TonalPalette.fromHueChroma(hct.hue, 200.0),
                palette.TonalPalette.fromHueChroma(dynamic.DynamicScheme.getRotatedHue(hct, &hues, &sec), 24.0),
                palette.TonalPalette.fromHueChroma(dynamic.DynamicScheme.getRotatedHue(hct, &hues, &ter), 32.0),
                palette.TonalPalette.fromHueChroma(hct.hue, 10.0),
                palette.TonalPalette.fromHueChroma(hct.hue, 10.0),
                null,
            );
        },
        .expressive => return dynamic.expressiveScheme(hct, is_dark, contrast_level),
        .content => return dynamic.contentScheme(alloc, hct, is_dark, contrast_level),
        .fidelity => return dynamic.fidelityScheme(hct, is_dark, contrast_level),
        .monochrome => return dynamic.monochromeScheme(hct, is_dark, contrast_level),
        .neutral => return dynamic.neutralScheme(hct, is_dark, contrast_level),
        .rainbow => return dynamic.rainbowScheme(hct, is_dark, contrast_level),
        .fruit_salad => return dynamic.fruitSaladScheme(hct, is_dark, contrast_level),
    }
}

fn roleFloat(c: u32, shift: u5) f32 {
    return @as(f32, @floatFromInt((c >> shift) & 0xFF)) / 255.0;
}

/// Flattens a scheme into a `PaletteResult`, pairing M3 roles onto the
/// shell's chrome fields, role by role.
pub fn schemeToResult(scheme: *const dynamic.DynamicScheme, source_argb: u32, is_dark: bool) PaletteResult {
    var r = PaletteResult{ .ok = true, .source_color_argb = source_argb };
    const surface_container = scheme.getSurfaceContainer();
    r.dock_fill = .{ roleFloat(surface_container, 16), roleFloat(surface_container, 8), roleFloat(surface_container, 0) };
    r.panel_fill = r.dock_fill;
    const surface_variant = scheme.getSurfaceVariant();
    r.drawer_dim = .{ roleFloat(surface_variant, 16), roleFloat(surface_variant, 8), roleFloat(surface_variant, 0) };
    const outline = scheme.getOutline();
    r.outline = .{ roleFloat(outline, 16), roleFloat(outline, 8), roleFloat(outline, 0) };
    const primary = scheme.getPrimary();
    r.accent = .{ roleFloat(primary, 16), roleFloat(primary, 8), roleFloat(primary, 0) };
    const text_v: f32 = if (is_dark) 1.0 else 0.0;
    r.text = .{ text_v, text_v, text_v };
    const err_container = scheme.getErrorContainer();
    r.notif_critical_bg = .{ roleFloat(err_container, 16), roleFloat(err_container, 8), roleFloat(err_container, 0) };
    const err = scheme.getError();
    r.notif_critical_outline = .{ roleFloat(err, 16), roleFloat(err, 8), roleFloat(err, 0) };

    const getters = [_]*const fn (*const dynamic.DynamicScheme) u32{
        dynamic.DynamicScheme.getPrimary,
        dynamic.DynamicScheme.getOnPrimary,
        dynamic.DynamicScheme.getPrimaryContainer,
        dynamic.DynamicScheme.getOnPrimaryContainer,
        dynamic.DynamicScheme.getSecondary,
        dynamic.DynamicScheme.getOnSecondary,
        dynamic.DynamicScheme.getSecondaryContainer,
        dynamic.DynamicScheme.getOnSecondaryContainer,
        dynamic.DynamicScheme.getTertiary,
        dynamic.DynamicScheme.getOnTertiary,
        dynamic.DynamicScheme.getTertiaryContainer,
        dynamic.DynamicScheme.getOnTertiaryContainer,
        dynamic.DynamicScheme.getError,
        dynamic.DynamicScheme.getOnError,
        dynamic.DynamicScheme.getErrorContainer,
        dynamic.DynamicScheme.getOnErrorContainer,
        dynamic.DynamicScheme.getSurface,
        dynamic.DynamicScheme.getOnSurface,
        dynamic.DynamicScheme.getSurfaceVariant,
        dynamic.DynamicScheme.getOnSurfaceVariant,
        dynamic.DynamicScheme.getSurfaceDim,
        dynamic.DynamicScheme.getSurfaceBright,
        dynamic.DynamicScheme.getSurfaceContainerLowest,
        dynamic.DynamicScheme.getSurfaceContainerLow,
        dynamic.DynamicScheme.getSurfaceContainer,
        dynamic.DynamicScheme.getSurfaceContainerHigh,
        dynamic.DynamicScheme.getSurfaceContainerHighest,
        dynamic.DynamicScheme.getInverseSurface,
        dynamic.DynamicScheme.getInverseOnSurface,
        dynamic.DynamicScheme.getInversePrimary,
        dynamic.DynamicScheme.getOutline,
        dynamic.DynamicScheme.getOutlineVariant,
        dynamic.DynamicScheme.getShadow,
        dynamic.DynamicScheme.getScrim,
        dynamic.DynamicScheme.getSurfaceTint,
        dynamic.DynamicScheme.getPrimaryFixed,
        dynamic.DynamicScheme.getPrimaryFixedDim,
        dynamic.DynamicScheme.getOnPrimaryFixed,
        dynamic.DynamicScheme.getOnPrimaryFixedVariant,
        dynamic.DynamicScheme.getSecondaryFixed,
        dynamic.DynamicScheme.getSecondaryFixedDim,
        dynamic.DynamicScheme.getOnSecondaryFixed,
        dynamic.DynamicScheme.getOnSecondaryFixedVariant,
        dynamic.DynamicScheme.getTertiaryFixed,
        dynamic.DynamicScheme.getTertiaryFixedDim,
        dynamic.DynamicScheme.getOnTertiaryFixed,
        dynamic.DynamicScheme.getOnTertiaryFixedVariant,
    };
    for (getters, 0..) |g, i| r.roles[i] = g(scheme);
    return r;
}

/// Full image pipeline: decode, resample to the 112 grid, Celebi quantize,
/// chroma filter, score, scheme.
pub fn generatePaletteFromImage(
    alloc: std.mem.Allocator,
    image_path: []const u8,
    variant: SchemeVariant,
    is_dark: bool,
    contrast_level: f64,
    max_colors: u16,
) !PaletteResult {
    var img = decode.loadRgba(alloc, image_path) orelse return .{};
    defer img.free(alloc);
    if (img.w <= 0 or img.h <= 0) return .{};

    var argb = try alloc.alloc(u32, @as(usize, @intCast(img.w * img.h)));
    defer alloc.free(argb);
    for (0..argb.len) |i| {
        const o = i * 4;
        argb[i] = (@as(u32, img.pixels[o + 3]) << 24) |
            (@as(u32, img.pixels[o]) << 16) |
            (@as(u32, img.pixels[o + 1]) << 8) |
            @as(u32, img.pixels[o + 2]);
    }

    const grid = try alloc.alloc(u32, @as(usize, target_dim * target_dim));
    defer alloc.free(grid);
    try resizeTriangleToGrid(alloc, argb, img.w, img.h, grid, target_dim, target_dim);

    var q = try quantize.quantizeCelebi(alloc, grid, @min(max_colors, 256));
    defer q.deinit();
    if (q.color_to_count.count() == 0) return .{};

    // Near-greys never win the seed vote (chroma cutoff 5.0).
    var keys = std.ArrayList(u32).empty;
    defer keys.deinit(alloc);
    var kit = q.color_to_count.iterator();
    while (kit.next()) |e| try keys.append(alloc, e.key_ptr.*);
    std.mem.sort(u32, keys.items, {}, u32Less);
    for (keys.items) |k| {
        if (cam.Hct.fromInt(k).chroma < 5.0) {
            _ = q.color_to_count.remove(k);
        }
    }
    if (q.color_to_count.count() == 0) return .{};

    var ranked = try score.rankedSuggestions(alloc, &q.color_to_count, .{ .desired = 4 });
    defer ranked.deinit(alloc);
    if (ranked.items.len == 0) return .{};
    return generatePaletteFromColor(alloc, ranked.items[0], variant, is_dark, contrast_level);
}

/// Same, starting from an explicit seed color (also what a cache hit rebuilds).
pub fn generatePaletteFromColor(
    alloc: std.mem.Allocator,
    source_color: u32,
    variant: SchemeVariant,
    is_dark: bool,
    contrast_level: f64,
) !PaletteResult {
    if (source_color == 0) return .{};
    const hct = cam.Hct.fromInt(source_color);
    var scheme = try createScheme(alloc, hct, variant, is_dark, contrast_level);
    return schemeToResult(&scheme, source_color, is_dark);
}

/// `scheme_variant_from_name`: lowercase, optional `scheme-` prefix, lax
/// aliases, Content fallback.
pub fn schemeVariantFromName(name: []const u8) SchemeVariant {
    var lower_buf: [32]u8 = undefined;
    const lower = std.ascii.lowerString(lower_buf[0..@min(name.len, lower_buf.len)], name[0..@min(name.len, lower_buf.len)]);
    var s: []const u8 = lower;
    if (s.len > 7 and std.mem.startsWith(u8, s, "scheme-")) s = s["scheme-".len..];
    // Tolerate the `m3-` prefix some configs use.
    if (s.len > 4 and std.mem.startsWith(u8, s, "m3-")) s = s["m3-".len..];
    if (std.mem.eql(u8, s, "tonal-spot") or std.mem.eql(u8, s, "tonal_spot")) return .tonal_spot;
    if (std.mem.eql(u8, s, "vibrant")) return .vibrant;
    if (std.mem.eql(u8, s, "expressive")) return .expressive;
    if (std.mem.eql(u8, s, "content")) return .content;
    if (std.mem.eql(u8, s, "fidelity") or std.mem.eql(u8, s, "faithful")) return .fidelity;
    if (std.mem.eql(u8, s, "monochrome")) return .monochrome;
    if (std.mem.eql(u8, s, "neutral")) return .neutral;
    if (std.mem.eql(u8, s, "rainbow")) return .rainbow;
    if (std.mem.eql(u8, s, "fruit-salad") or std.mem.eql(u8, s, "fruitsalad")) return .fruit_salad;
    return .content;
}

pub fn schemeVariantName(v: SchemeVariant) []const u8 {
    return switch (v) {
        .tonal_spot => "scheme-tonal-spot",
        .vibrant => "scheme-vibrant",
        .expressive => "scheme-expressive",
        .content => "scheme-content",
        .fidelity => "scheme-fidelity",
        .monochrome => "scheme-monochrome",
        .neutral => "scheme-neutral",
        .rainbow => "scheme-rainbow",
        .fruit_salad => "scheme-fruit-salad",
    };
}

/// `#rrggbb`, lowercase.
pub fn hexFromArgb(c: u32, out: *[7]u8) []u8 {
    const digits = "0123456789abcdef";
    out[0] = '#';
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        out[1 + i] = digits[(c >> @intCast((5 - i) * 4)) & 0xF];
    }
    return out[0..7];
}

pub fn rgbStringFromArgb(c: u32, out: []u8) ![]u8 {
    return std.fmt.bufPrint(out, "rgb({d}, {d}, {d})", .{
        (c >> 16) & 0xFF,
        (c >> 8) & 0xFF,
        c & 0xFF,
    });
}

pub fn rgbaStringFromArgb(c: u32, alpha: u8, out: []u8) ![]u8 {
    return std.fmt.bufPrint(out, "rgba({d}, {d}, {d}, {d})", .{
        (c >> 16) & 0xFF,
        (c >> 8) & 0xFF,
        c & 0xFF,
        alpha,
    });
}

/// `hsl(H, S%, L%)` with C `%.0f` rounding (half away from zero).
pub fn hslStringFromArgb(c: u32, out: []u8) ![]u8 {
    const r: f64 = @as(f64, @floatFromInt((c >> 16) & 0xFF)) / 255.0;
    const g: f64 = @as(f64, @floatFromInt((c >> 8) & 0xFF)) / 255.0;
    const b: f64 = @as(f64, @floatFromInt(c & 0xFF)) / 255.0;
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    const l = (mx + mn) / 2.0;
    var h: f64 = 0.0;
    var s: f64 = 0.0;
    if (mx != mn) {
        const d = mx - mn;
        s = if (l > 0.5) d / (2.0 - mx - mn) else d / (mx + mn);
        if (mx == r) {
            h = (g - b) / d + (if (g < b) @as(f64, 6.0) else @as(f64, 0.0));
        } else if (mx == g) {
            h = (b - r) / d + 2.0;
        } else {
            h = (r - g) / d + 4.0;
        }
        h /= 6.0;
    }
    return std.fmt.bufPrint(out, "hsl({d}, {d}%, {d}%)", .{
        @as(i32, @intFromFloat(@round(h * 360.0))),
        @as(i32, @intFromFloat(@round(s * 100.0))),
        @as(i32, @intFromFloat(@round(l * 100.0))),
    });
}

/// Process cache: wallpaper state → picked seed, so config reloads share one
/// decode. Caller-owned (ownership here
/// sits with the worker that runs generation, which is single-threaded).
pub const SeedCache = struct {
    mem: std.AutoHashMap(u64, u32),
    dir: []const u8,

    pub fn init(alloc: std.mem.Allocator, dir: []const u8) SeedCache {
        return .{ .mem = std.AutoHashMap(u64, u32).init(alloc), .dir = dir };
    }

    pub fn deinit(self: *SeedCache) void {
        self.mem.deinit();
    }
};

fn fnvMix(h: *u64, bytes: []const u8) void {
    for (bytes) |b| {
        h.* ^= b;
        h.* *%= 1099511628211;
    }
}

/// Cache key over every input that can change the seed: `path` bytes + NUL, mtime ns i64 LE, size u64 LE, variant u8,
/// dark u8, contrast bits u32 LE, max_colors i32 LE).
pub fn seedKey(
    path: []const u8,
    mtime_ns: i64,
    size: u64,
    variant: SchemeVariant,
    is_dark: bool,
    contrast_level: f32,
    max_colors: i32,
) u64 {
    var h: u64 = 0x9e3779b97f4a7c15;
    fnvMix(&h, path);
    fnvMix(&h, &[_]u8{0});
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(i64, &tmp, mtime_ns, .little);
    fnvMix(&h, &tmp);
    std.mem.writeInt(u64, &tmp, size, .little);
    fnvMix(&h, &tmp);
    fnvMix(&h, &[_]u8{@intFromEnum(variant)});
    fnvMix(&h, &[_]u8{if (is_dark) 1 else 0});
    std.mem.writeInt(u32, tmp[0..4], @bitCast(contrast_level), .little);
    fnvMix(&h, tmp[0..4]);
    var tmp4: [4]u8 = undefined;
    std.mem.writeInt(i32, &tmp4, max_colors, .little);
    fnvMix(&h, &tmp4);
    return h;
}

fn cacheFileName(key: u64, out: *[32]u8) []u8 {
    const digits = "0123456789abcdef";
    for (0..16) |i| {
        out[i] = digits[(key >> @intCast((15 - i) * 4)) & 0xF];
    }
    @memcpy(out[16..24], ".palette");
    return out[0..24];
}

fn loadSeedFile(io: std.Io, file: []const u8, key: u64) ?u32 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, file, std.heap.page_allocator, .limited(512)) catch return null;
    defer std.heap.page_allocator.free(data);
    // `seed=0x........\nkey=<u64>\n`
    if (data.len < 7 or !std.mem.startsWith(u8, data, "seed=0x")) return null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    const seed_line = lines.next() orelse return null;
    const key_line = lines.next() orelse return null;
    if (seed_line.len != 15) return null;
    const seed = std.fmt.parseInt(u32, seed_line[7..15], 16) catch return null;
    if (!std.mem.startsWith(u8, key_line, "key=")) return null;
    const stored = std.fmt.parseInt(u64, key_line[4..], 10) catch return null;
    if (stored != key or seed == 0) return null;
    return seed;
}

fn storeSeedFile(io: std.Io, dir: []const u8, file: []const u8, key: u64, seed: u32) void {
    std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    var tmp_name: [64]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_name, "{s}.tmp.{d}", .{ file, std.os.linux.getpid() }) catch return;
    var content: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&content, "seed=0x{x:0>8}\nkey={d}\n", .{ seed, key }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = body }) catch return;
    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), file, io) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    };
}

/// Image pipeline with the mem + disk seed cache in front.
pub fn generatePaletteFromImageCached(
    cache: *SeedCache,
    alloc: std.mem.Allocator,
    io: std.Io,
    image_path: []const u8,
    variant: SchemeVariant,
    is_dark: bool,
    contrast_level: f32,
    max_colors: u16,
) !PaletteResult {
    const st = std.Io.Dir.cwd().statFile(io, image_path, .{}) catch return .{};
    if (st.kind != .file) return .{};
    const mtime: i64 = @truncate(st.mtime.nanoseconds);
    const key = seedKey(image_path, mtime, st.size, variant, is_dark, contrast_level, max_colors);

    if (cache.mem.get(key)) |seed| {
        return generatePaletteFromColor(alloc, seed, variant, is_dark, contrast_level);
    }
    var name_buf: [32]u8 = undefined;
    const name = cacheFileName(key, &name_buf);
    const file = try std.fs.path.join(alloc, &.{ cache.dir, name });
    defer alloc.free(file);
    if (loadSeedFile(io, file, key)) |seed| {
        try cache.mem.put(key, seed);
        return generatePaletteFromColor(alloc, seed, variant, is_dark, contrast_level);
    }

    const result = try generatePaletteFromImage(alloc, image_path, variant, is_dark, contrast_level, max_colors);
    if (!result.ok or result.source_color_argb == 0) return result;
    try cache.mem.put(key, result.source_color_argb);
    storeSeedFile(io, cache.dir, file, key, result.source_color_argb);
    return result;
}
test "mcu-engine: wallpaper images match the reference renders" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);

    const two = try writeBmp(alloc, io, root, "two.bmp", 64, 64, .two_tone);
    defer alloc.free(two);
    const quad = try writeBmp(alloc, io, root, "quad.bmp", 64, 64, .quad);
    defer alloc.free(quad);
    const grad = try writeBmp(alloc, io, root, "grad.bmp", 200, 150, .grad);
    defer alloc.free(grad);

    {
        const r = try generatePaletteFromImage(alloc, two, .content, true, 0.0, 128);
        try t.expect(r.ok);
        try t.expectEqual(@as(u32, 0xFF1E50C8), r.source_color_argb);
        try expectF3(t, r.dock_fill, 0.117647, 0.121569, 0.152941);
        try expectF3(t, r.panel_fill, 0.117647, 0.121569, 0.152941);
        try expectF3(t, r.drawer_dim, 0.262745, 0.274510, 0.329412);
        try expectF3(t, r.outline, 0.552941, 0.564706, 0.623529);
        try expectF3(t, r.accent, 0.709804, 0.768627, 1.000000);
        try expectF3(t, r.text, 1.000000, 1.000000, 1.000000);
        try expectF3(t, r.notif_critical_bg, 0.576471, 0.000000, 0.039216);
        try expectF3(t, r.notif_critical_outline, 1.000000, 0.705882, 0.670588);
        const want_roles = [_]u32{
            0xFFB5C4FF, 0xFF00297B, 0xFF1E50C8, 0xFFC4D0FF, 0xFFB7C5F9, 0xFF202E59, 0xFF394774, 0xFFA9B7EA, 0xFFB5C4FF, 0xFF00287D, 0xFF2250C8, 0xFFC5D0FF, 0xFFFFB4AB, 0xFF690005, 0xFF93000A, 0xFFFFDAD6, 0xFF11131A, 0xFFE2E1EC, 0xFF434654, 0xFFC4C5D6, 0xFF11131A, 0xFF373941, 0xFF0C0E15, 0xFF1A1B23, 0xFF1E1F27, 0xFF282A31, 0xFF33343C, 0xFFE2E1EC, 0xFF2E3038, 0xFF2555CD, 0xFF8D909F, 0xFF434654, 0xFF000000, 0xFF000000, 0xFFB5C4FF, 0xFFDBE1FF, 0xFFB5C4FF, 0xFF00164D, 0xFF003CAC, 0xFFDBE1FF, 0xFFB7C5F9, 0xFF081843, 0xFF374571, 0xFFDCE1FF, 0xFFB5C4FF, 0xFF00164E, 0xFF003BAF,
        };
        for (want_roles, 0..) |w, i| try t.expectEqual(w, r.roles[i]);
    }
    {
        const r = try generatePaletteFromImage(alloc, two, .vibrant, true, 0.0, 128);
        try t.expect(r.ok);
        try t.expectEqual(@as(u32, 0xFF1E50C8), r.source_color_argb);
        try expectF3(t, r.dock_fill, 0.113725, 0.121569, 0.160784);
        try expectF3(t, r.panel_fill, 0.113725, 0.121569, 0.160784);
        try expectF3(t, r.drawer_dim, 0.266667, 0.274510, 0.317647);
        try expectF3(t, r.outline, 0.556863, 0.564706, 0.611765);
        try expectF3(t, r.accent, 0.709804, 0.768627, 1.000000);
        try expectF3(t, r.text, 1.000000, 1.000000, 1.000000);
        try expectF3(t, r.notif_critical_bg, 0.576471, 0.000000, 0.039216);
        try expectF3(t, r.notif_critical_outline, 1.000000, 0.705882, 0.670588);
        const want_roles = [_]u32{
            0xFFB5C4FF, 0xFF00297B, 0xFF003CAC, 0xFFDBE1FF, 0xFFC6C2EA, 0xFF2E2D4D, 0xFF454364, 0xFFE3DFFF, 0xFFD2BDF5, 0xFF382856, 0xFF4F3E6E, 0xFFEBDCFF, 0xFFFFB4AB, 0xFF690005, 0xFF93000A, 0xFFFFDAD6, 0xFF11131C, 0xFFE1E1EF, 0xFF444651, 0xFFC5C6D3, 0xFF11131C, 0xFF363943, 0xFF0B0E17, 0xFF191B25, 0xFF1D1F29, 0xFF272A34, 0xFF32343F, 0xFFE1E1EF, 0xFF2E303A, 0xFF0051E0, 0xFF8E909C, 0xFF444651, 0xFF000000, 0xFF000000, 0xFFB5C4FF, 0xFFDBE1FF, 0xFFB5C4FF, 0xFF00164D, 0xFF003CAC, 0xFFE3DFFF, 0xFFC6C2EA, 0xFF191836, 0xFF454364, 0xFFEBDCFF, 0xFFD2BDF5, 0xFF22123F, 0xFF4F3E6E,
        };
        for (want_roles, 0..) |w, i| try t.expectEqual(w, r.roles[i]);
    }
    {
        const r = try generatePaletteFromImage(alloc, quad, .content, true, 0.0, 128);
        try t.expect(r.ok);
        try t.expectEqual(@as(u32, 0xFF28B43C), r.source_color_argb);
        try expectF3(t, r.dock_fill, 0.101961, 0.133333, 0.098039);
        try expectF3(t, r.panel_fill, 0.101961, 0.133333, 0.098039);
        try expectF3(t, r.drawer_dim, 0.243137, 0.290196, 0.231373);
        try expectF3(t, r.outline, 0.529412, 0.584314, 0.509804);
        try expectF3(t, r.accent, 0.360784, 0.878431, 0.384314);
        try expectF3(t, r.text, 1.000000, 1.000000, 1.000000);
        try expectF3(t, r.notif_critical_bg, 0.576471, 0.000000, 0.039216);
        try expectF3(t, r.notif_critical_outline, 1.000000, 0.705882, 0.670588);
        const want_roles = [_]u32{
            0xFF5CE062, 0xFF003909, 0xFF28B43C, 0xFF003E0B, 0xFF98D691, 0xFF003909, 0xFF1B541E, 0xFF8AC784, 0xFF55E166, 0xFF00390D, 0xFF19B440, 0xFF003D0F, 0xFFFFB4AB, 0xFF690005, 0xFF93000A, 0xFFFFDAD6, 0xFF0E150D, 0xFFDDE5D7, 0xFF3E4A3B, 0xFFBDCBB6, 0xFF0E150D, 0xFF343B31, 0xFF091008, 0xFF161D15, 0xFF1A2219, 0xFF242C23, 0xFF2F372D, 0xFFDDE5D7, 0xFF2B3229, 0xFF006E1B, 0xFF879582, 0xFF3E4A3B, 0xFF000000, 0xFF000000, 0xFF5CE062, 0xFF79FE7B, 0xFF5CE062, 0xFF002204, 0xFF005312, 0xFFB3F2AB, 0xFF98D691, 0xFF002204, 0xFF18511C, 0xFF74FE7F, 0xFF55E166, 0xFF002105, 0xFF005317,
        };
        for (want_roles, 0..) |w, i| try t.expectEqual(w, r.roles[i]);
    }
    {
        const r = try generatePaletteFromImage(alloc, quad, .vibrant, true, 0.0, 128);
        try t.expect(r.ok);
        try t.expectEqual(@as(u32, 0xFF28B43C), r.source_color_argb);
        try expectF3(t, r.dock_fill, 0.101961, 0.133333, 0.094118);
        try expectF3(t, r.panel_fill, 0.101961, 0.133333, 0.094118);
        try expectF3(t, r.drawer_dim, 0.254902, 0.286275, 0.243137);
        try expectF3(t, r.outline, 0.541176, 0.576471, 0.525490);
        try expectF3(t, r.accent, 0.000000, 0.898039, 0.262745);
        try expectF3(t, r.text, 1.000000, 1.000000, 1.000000);
        try expectF3(t, r.notif_critical_bg, 0.576471, 0.000000, 0.039216);
        try expectF3(t, r.notif_critical_outline, 1.000000, 0.705882, 0.670588);
        const want_roles = [_]u32{
            0xFF00E543, 0xFF003909, 0xFF005312, 0xFF71FF75, 0xFFA8D0B5, 0xFF133724, 0xFF2A4E39, 0xFFC4ECD0, 0xFF91D4BE, 0xFF00382C, 0xFF005141, 0xFFACF0DA, 0xFFFFB4AB, 0xFF690005, 0xFF93000A, 0xFFFFDAD6, 0xFF0E150C, 0xFFDCE5D6, 0xFF41493E, 0xFFC0C9BA, 0xFF0E150C, 0xFF333B31, 0xFF081008, 0xFF161E14, 0xFF1A2218, 0xFF242C22, 0xFF2F372C, 0xFFDCE5D6, 0xFF2A3328, 0xFF006E1B, 0xFF8A9386, 0xFF41493E, 0xFF000000, 0xFF000000, 0xFF00E543, 0xFF71FF75, 0xFF00E543, 0xFF002204, 0xFF005312, 0xFFC4ECD0, 0xFFA8D0B5, 0xFF002111, 0xFF2A4E39, 0xFFACF0DA, 0xFF91D4BE, 0xFF002019, 0xFF005141,
        };
        for (want_roles, 0..) |w, i| try t.expectEqual(w, r.roles[i]);
    }
    {
        const r = try generatePaletteFromImage(alloc, grad, .content, true, 0.0, 128);
        try t.expect(r.ok);
        try t.expectEqual(@as(u32, 0xFFF32299), r.source_color_argb);
        try expectF3(t, r.dock_fill, 0.168627, 0.105882, 0.129412);
        try expectF3(t, r.panel_fill, 0.168627, 0.105882, 0.129412);
        try expectF3(t, r.drawer_dim, 0.349020, 0.247059, 0.286275);
        try expectF3(t, r.outline, 0.658824, 0.533333, 0.576471);
        try expectF3(t, r.accent, 1.000000, 0.690196, 0.807843);
        try expectF3(t, r.text, 1.000000, 1.000000, 1.000000);
        try expectF3(t, r.notif_critical_bg, 0.576471, 0.000000, 0.039216);
        try expectF3(t, r.notif_critical_outline, 1.000000, 0.705882, 0.670588);
        const want_roles = [_]u32{
            0xFFFFB0CE, 0xFF63003B, 0xFFFF44A6, 0xFF3C0021, 0xFFFFB0CE, 0xFF63003B, 0xFF861653, 0xFFFF94C1, 0xFFFFB0CD, 0xFF640039, 0xFFFF45A3, 0xFF3B0020, 0xFFFFB4AB, 0xFF690005, 0xFF93000A, 0xFFFFDAD6, 0xFF1E0F15, 0xFFF8DBE4, 0xFF593F49, 0xFFE1BDC9, 0xFF1E0F15, 0xFF46343B, 0xFF180A10, 0xFF27171D, 0xFF2B1B21, 0xFF36252C, 0xFF423036, 0xFFF8DBE4, 0xFF3D2C32, 0xFFB70070, 0xFFA88893, 0xFF593F49, 0xFF000000, 0xFF000000, 0xFFFFB0CE, 0xFFFFD9E5, 0xFFFFB0CE, 0xFF3E0022, 0xFF8C0055, 0xFFFFD9E5, 0xFFFFB0CE, 0xFF3E0022, 0xFF861653, 0xFFFFD9E4, 0xFFFFB0CD, 0xFF3E0022, 0xFF8C0053,
        };
        for (want_roles, 0..) |w, i| try t.expectEqual(w, r.roles[i]);
    }
    {
        const r = try generatePaletteFromImage(alloc, grad, .vibrant, true, 0.0, 128);
        try t.expect(r.ok);
        try t.expectEqual(@as(u32, 0xFFF32299), r.source_color_argb);
        try expectF3(t, r.dock_fill, 0.160784, 0.109804, 0.129412);
        try expectF3(t, r.panel_fill, 0.160784, 0.109804, 0.129412);
        try expectF3(t, r.drawer_dim, 0.325490, 0.258824, 0.282353);
        try expectF3(t, r.outline, 0.627451, 0.545098, 0.572549);
        try expectF3(t, r.accent, 1.000000, 0.690196, 0.807843);
        try expectF3(t, r.text, 1.000000, 1.000000, 1.000000);
        try expectF3(t, r.notif_critical_bg, 0.576471, 0.000000, 0.039216);
        try expectF3(t, r.notif_critical_outline, 1.000000, 0.705882, 0.670588);
        const want_roles = [_]u32{
            0xFFFFB0CE, 0xFF63003B, 0xFF8C0055, 0xFFFFD9E5, 0xFFF2B7C1, 0xFF4B252D, 0xFF653B43, 0xFFFFD9DE, 0xFFFFB3B0, 0xFF532020, 0xFF6F3635, 0xFFFFDAD8, 0xFFFFB4AB, 0xFF690005, 0xFF93000A, 0xFFFFDAD6, 0xFF1C1015, 0xFFF5DCE3, 0xFF534248, 0xFFD8C1C7, 0xFF1C1015, 0xFF45353A, 0xFF160B0F, 0xFF25181D, 0xFF291C21, 0xFF34262B, 0xFF403136, 0xFFF5DCE3, 0xFF3B2C32, 0xFFB70070, 0xFFA08B92, 0xFF534248, 0xFF000000, 0xFF000000, 0xFFFFB0CE, 0xFFFFD9E5, 0xFFFFB0CE, 0xFF3E0022, 0xFF8C0055, 0xFFFFD9DE, 0xFFF2B7C1, 0xFF321018, 0xFF653B43, 0xFFFFDAD8, 0xFFFFB3B0, 0xFF380B0D, 0xFF6F3635,
        };
        for (want_roles, 0..) |w, i| try t.expectEqual(w, r.roles[i]);
    }
    {
        const r = try generatePaletteFromImage(alloc, two, .content, false, 0.0, 128);
        try t.expect(r.ok);
        try t.expectEqual(@as(u32, 0xFF1E50C8), r.source_color_argb);
        try expectF3(t, r.dock_fill, 0.929412, 0.929412, 0.968627);
        try expectF3(t, r.panel_fill, 0.929412, 0.929412, 0.968627);
        try expectF3(t, r.drawer_dim, 0.878431, 0.882353, 0.949020);
        try expectF3(t, r.outline, 0.454902, 0.462745, 0.521569);
        try expectF3(t, r.accent, 0.000000, 0.223529, 0.639216);
        try expectF3(t, r.text, 0.000000, 0.000000, 0.000000);
        try expectF3(t, r.notif_critical_bg, 1.000000, 0.854902, 0.839216);
        try expectF3(t, r.notif_critical_outline, 0.729412, 0.101961, 0.101961);
        const want_roles = [_]u32{
            0xFF0039A3, 0xFFFFFFFF, 0xFF1E50C8, 0xFFC4D0FF, 0xFF4F5C8B, 0xFFFFFFFF, 0xFFBDCAFF, 0xFF475482, 0xFF0038A6, 0xFFFFFFFF, 0xFF2250C8, 0xFFC5D0FF, 0xFFBA1A1A, 0xFFFFFFFF, 0xFFFFDAD6, 0xFF93000A, 0xFFFAF8FF, 0xFF1A1B23, 0xFFE0E1F2, 0xFF434654, 0xFFD9D9E3, 0xFFFAF8FF, 0xFFFFFFFF, 0xFFF3F3FD, 0xFFEDEDF7, 0xFFE8E7F2, 0xFFE2E1EC, 0xFF2E3038, 0xFFF0F0FA, 0xFFB5C4FF, 0xFF747685, 0xFFC4C5D6, 0xFF000000, 0xFF000000, 0xFF2555CD, 0xFFDBE1FF, 0xFFB5C4FF, 0xFF00164D, 0xFF003CAC, 0xFFDBE1FF, 0xFFB7C5F9, 0xFF081843, 0xFF374571, 0xFFDCE1FF, 0xFFB5C4FF, 0xFF00164E, 0xFF003BAF,
        };
        for (want_roles, 0..) |w, i| try t.expectEqual(w, r.roles[i]);
    }
}

fn expectF3(t: anytype, got: [3]f32, w0: f32, w1: f32, w2: f32) !void {
    try t.expectApproxEqAbs(w0, got[0], 1e-6);
    try t.expectApproxEqAbs(w1, got[1], 1e-6);
    try t.expectApproxEqAbs(w2, got[2], 1e-6);
}

const BmpKind = enum { two_tone, quad, grad };

/// 24-bit BMP writer mirroring the python reference images byte-for-byte.
fn writeBmp(alloc: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8, w: i32, h: i32, kind: BmpKind) ![]u8 {
    const path = try std.fs.path.join(alloc, &.{ dir, name });
    errdefer alloc.free(path);
    const uw: usize = @intCast(w);
    const uh: usize = @intCast(h);
    const row = uw * 3;
    const pad = (4 - row % 4) % 4;
    var data = std.ArrayList(u8).empty;
    defer data.deinit(alloc);
    var y: usize = uh;
    while (y > 0) {
        y -= 1;
        for (0..uw) |x| {
            const px = bmpPixel(kind, @intCast(x), @intCast(y));
            try data.appendSlice(alloc, &.{ px[2], px[1], px[0] });
        }
        for (0..pad) |_| try data.append(alloc, 0);
    }
    var hdr: [54]u8 = undefined;
    std.mem.writeInt(u16, hdr[0..2], 0x4D42, .little);
    std.mem.writeInt(u32, hdr[2..6], @intCast(54 + data.items.len), .little);
    std.mem.writeInt(u32, hdr[6..10], 0, .little);
    std.mem.writeInt(u32, hdr[10..14], 54, .little);
    std.mem.writeInt(u32, hdr[14..18], 40, .little);
    std.mem.writeInt(i32, hdr[18..22], w, .little);
    std.mem.writeInt(i32, hdr[22..26], h, .little);
    std.mem.writeInt(u16, hdr[26..28], 1, .little);
    std.mem.writeInt(u16, hdr[28..30], 24, .little);
    std.mem.writeInt(u32, hdr[30..34], 0, .little);
    std.mem.writeInt(u32, hdr[34..38], @intCast(data.items.len), .little);
    std.mem.writeInt(i32, hdr[38..42], 2835, .little);
    std.mem.writeInt(i32, hdr[42..46], 2835, .little);
    std.mem.writeInt(u32, hdr[46..50], 0, .little);
    std.mem.writeInt(u32, hdr[50..54], 0, .little);
    var file = std.ArrayList(u8).empty;
    defer file.deinit(alloc);
    try file.appendSlice(alloc, &hdr);
    try file.appendSlice(alloc, data.items);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file.items });
    return path;
}

fn bmpPixel(kind: BmpKind, x: i32, y: i32) [3]u8 {
    return switch (kind) {
        .two_tone => if (x >= 16 and x < 48 and y >= 16 and y < 48) .{ 200, 30, 30 } else .{ 30, 80, 200 },
        .quad => if (x < 32 and y < 32) .{ 200, 60, 40 } else if (x >= 32 and y < 32) .{ 40, 180, 60 } else if (x < 32) .{ 60, 80, 200 } else .{ 220, 200, 60 },
        .grad => .{
            @intCast(@divTrunc(x * 255, 199)),
            @intCast(@divTrunc(y * 255, 149)),
            @intCast(@divTrunc((x + y) * 255, 348)),
        },
    };
}
test "mcu-engine: variant names round-trip the specified spellings" {
    const t = std.testing;
    try t.expectEqual(SchemeVariant.content, schemeVariantFromName("content"));
    try t.expectEqual(SchemeVariant.vibrant, schemeVariantFromName("Vibrant"));
    try t.expectEqual(SchemeVariant.tonal_spot, schemeVariantFromName("scheme-tonal-spot"));
    try t.expectEqual(SchemeVariant.tonal_spot, schemeVariantFromName("tonal_spot"));
    try t.expectEqual(SchemeVariant.fidelity, schemeVariantFromName("faithful"));
    try t.expectEqual(SchemeVariant.fidelity, schemeVariantFromName("m3-fidelity"));
    try t.expectEqual(SchemeVariant.fruit_salad, schemeVariantFromName("fruitsalad"));
    try t.expectEqual(SchemeVariant.content, schemeVariantFromName("garbage"));
    try t.expectEqualStrings("scheme-rainbow", schemeVariantName(.rainbow));
    try t.expectEqualStrings("scheme-content", schemeVariantName(.content));
}

test "mcu-engine: color string helpers match the specified formats" {
    const t = std.testing;
    var hexb: [7]u8 = undefined;
    try t.expectEqualStrings("#4285f4", hexFromArgb(0xFF4285F4, &hexb));
    try t.expectEqualStrings("#000000", hexFromArgb(0xFF000000, &hexb));
    var sbuf: [48]u8 = undefined;
    try t.expectEqualStrings("rgb(66, 133, 244)", try rgbStringFromArgb(0xFF4285F4, &sbuf));
    try t.expectEqualStrings("rgba(66, 133, 244, 128)", try rgbaStringFromArgb(0xFF4285F4, 128, &sbuf));
    try t.expectEqualStrings("hsl(0, 65%, 51%)", try hslStringFromArgb(0xFFD32F2F, &sbuf));
}
