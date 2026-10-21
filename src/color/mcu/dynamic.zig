//! material-color-utilities dynamic colors: `DynamicScheme`, `DynamicColor`,
//! `MaterialDynamicColors` and the 9 scheme constructors — one file because
//! the scheme getters call the factories and the factories name the scheme
//! type (`dynamic_scheme.cc` + `dynamic_color.cc` +
//! `material_dynamic_colors.cc` + `scheme_*.cc`).
//!
//! Bit-parity notes:
//!   * `dynamic_color.cc` and `material_dynamic_colors.cc` resolve bare
//!     `abs()` on doubles to an integer overload (verified per-TU by probe):
//!     the difference truncates toward zero, so `@trunc(@abs(...))` is used
//!     at the `negligible_difference` check and in `findDesiredChromaByTone`.
//!   * `M_PI` is `utils.k_pi`; clamps are `@max`/`std.math.clamp`.

const std = @import("std");
const cam = @import("cam.zig");
const contrast = @import("contrast.zig");
const dislike = @import("dislike.zig");
const libm = @import("libm.zig");
const palette = @import("palette.zig");
const temperature = @import("temperature.zig");
const utils = @import("utils.zig");

pub const Variant = enum {
    monochrome,
    neutral,
    tonal_spot,
    vibrant,
    expressive,
    fidelity,
    content,
    rainbow,
    fruit_salad,
};

pub const ContrastCurve = struct {
    low: f64,
    normal: f64,
    medium: f64,
    high: f64,

    pub fn get(self: ContrastCurve, level: f64) f64 {
        if (level <= -1.0) return self.low;
        if (level < 0.0) return curveLerp(self.low, self.normal, (level + 1.0) / 1.0);
        if (level < 0.5) return curveLerp(self.normal, self.medium, level / 0.5);
        if (level < 1.0) return curveLerp(self.medium, self.high, (level - 0.5) / 0.5);
        return self.high;
    }

    fn curveLerp(a: f64, b: f64, t: f64) f64 {
        return (1.0 - t) * a + t * b;
    }
};

pub const TonePolarity = enum { darker, lighter, nearer, farther };

pub const ToneDeltaPair = struct {
    role_a: DynamicColor,
    role_b: DynamicColor,
    delta: f64,
    polarity: TonePolarity,
    stay_together: bool,
};

pub const PaletteFn = *const fn (*const DynamicScheme) palette.TonalPalette;
pub const ToneFn = *const fn (*const DynamicScheme) f64;
pub const ColorFn = *const fn (*const DynamicScheme) DynamicColor;
pub const ToneDeltaFn = *const fn (*const DynamicScheme) ToneDeltaPair;

pub const DynamicScheme = struct {
    source_color_hct: cam.Hct,
    variant: Variant,
    is_dark: bool,
    contrast_level: f64,
    primary_palette: palette.TonalPalette,
    secondary_palette: palette.TonalPalette,
    tertiary_palette: palette.TonalPalette,
    neutral_palette: palette.TonalPalette,
    neutral_variant_palette: palette.TonalPalette,
    error_palette: palette.TonalPalette,

    pub fn init(
        source: cam.Hct,
        variant: Variant,
        contrast_level: f64,
        is_dark: bool,
        primary: palette.TonalPalette,
        secondary: palette.TonalPalette,
        tertiary: palette.TonalPalette,
        neutral: palette.TonalPalette,
        neutral_variant: palette.TonalPalette,
        err: ?palette.TonalPalette,
    ) DynamicScheme {
        return .{
            .source_color_hct = source,
            .variant = variant,
            .is_dark = is_dark,
            .contrast_level = contrast_level,
            .primary_palette = primary,
            .secondary_palette = secondary,
            .tertiary_palette = tertiary,
            .neutral_palette = neutral,
            .neutral_variant_palette = neutral_variant,
            .error_palette = err orelse palette.TonalPalette.fromHueChroma(25.0, 84.0),
        };
    }

    pub fn getRotatedHue(source: cam.Hct, hues: []const f64, rotations: []const f64) f64 {
        if (rotations.len == 1) return utils.sanitizeDegreesDouble(source.hue + rotations[0]);
        var i: usize = 0;
        while (i + 2 <= hues.len) : (i += 1) {
            if (hues[i] < source.hue and source.hue < hues[i + 1]) {
                return utils.sanitizeDegreesDouble(source.hue + rotations[i]);
            }
        }
        return source.hue;
    }

    pub fn sourceColorArgb(self: *const DynamicScheme) utils.Argb {
        return self.source_color_hct.toInt();
    }

    pub fn getPrimary(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.primary().getArgb(self);
    }
    pub fn getOnPrimary(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onPrimary().getArgb(self);
    }
    pub fn getPrimaryContainer(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.primaryContainer().getArgb(self);
    }
    pub fn getOnPrimaryContainer(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onPrimaryContainer().getArgb(self);
    }
    pub fn getSecondary(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.secondary().getArgb(self);
    }
    pub fn getOnSecondary(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onSecondary().getArgb(self);
    }
    pub fn getSecondaryContainer(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.secondaryContainer().getArgb(self);
    }
    pub fn getOnSecondaryContainer(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onSecondaryContainer().getArgb(self);
    }
    pub fn getTertiary(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.tertiary().getArgb(self);
    }
    pub fn getOnTertiary(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onTertiary().getArgb(self);
    }
    pub fn getTertiaryContainer(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.tertiaryContainer().getArgb(self);
    }
    pub fn getOnTertiaryContainer(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onTertiaryContainer().getArgb(self);
    }
    pub fn getError(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.err().getArgb(self);
    }
    pub fn getOnError(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onError().getArgb(self);
    }
    pub fn getErrorContainer(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.errorContainer().getArgb(self);
    }
    pub fn getOnErrorContainer(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onErrorContainer().getArgb(self);
    }
    pub fn getSurface(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.surface().getArgb(self);
    }
    pub fn getOnSurface(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onSurface().getArgb(self);
    }
    pub fn getSurfaceVariant(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.surfaceVariant().getArgb(self);
    }
    pub fn getOnSurfaceVariant(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onSurfaceVariant().getArgb(self);
    }
    pub fn getSurfaceDim(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.surfaceDim().getArgb(self);
    }
    pub fn getSurfaceBright(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.surfaceBright().getArgb(self);
    }
    pub fn getSurfaceContainerLowest(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.surfaceContainerLowest().getArgb(self);
    }
    pub fn getSurfaceContainerLow(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.surfaceContainerLow().getArgb(self);
    }
    pub fn getSurfaceContainer(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.surfaceContainer().getArgb(self);
    }
    pub fn getSurfaceContainerHigh(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.surfaceContainerHigh().getArgb(self);
    }
    pub fn getSurfaceContainerHighest(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.surfaceContainerHighest().getArgb(self);
    }
    pub fn getInverseSurface(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.inverseSurface().getArgb(self);
    }
    pub fn getInverseOnSurface(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.inverseOnSurface().getArgb(self);
    }
    pub fn getInversePrimary(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.inversePrimary().getArgb(self);
    }
    pub fn getOutline(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.outline().getArgb(self);
    }
    pub fn getOutlineVariant(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.outlineVariant().getArgb(self);
    }
    pub fn getShadow(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.shadow().getArgb(self);
    }
    pub fn getScrim(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.scrim().getArgb(self);
    }
    pub fn getSurfaceTint(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.surfaceTint().getArgb(self);
    }
    pub fn getPrimaryFixed(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.primaryFixed().getArgb(self);
    }
    pub fn getPrimaryFixedDim(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.primaryFixedDim().getArgb(self);
    }
    pub fn getOnPrimaryFixed(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onPrimaryFixed().getArgb(self);
    }
    pub fn getOnPrimaryFixedVariant(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onPrimaryFixedVariant().getArgb(self);
    }
    pub fn getSecondaryFixed(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.secondaryFixed().getArgb(self);
    }
    pub fn getSecondaryFixedDim(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.secondaryFixedDim().getArgb(self);
    }
    pub fn getOnSecondaryFixed(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onSecondaryFixed().getArgb(self);
    }
    pub fn getOnSecondaryFixedVariant(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onSecondaryFixedVariant().getArgb(self);
    }
    pub fn getTertiaryFixed(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.tertiaryFixed().getArgb(self);
    }
    pub fn getTertiaryFixedDim(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.tertiaryFixedDim().getArgb(self);
    }
    pub fn getOnTertiaryFixed(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onTertiaryFixed().getArgb(self);
    }
    pub fn getOnTertiaryFixedVariant(self: *const DynamicScheme) utils.Argb {
        return MaterialDynamicColors.onTertiaryFixedVariant().getArgb(self);
    }
};

pub const DynamicColor = struct {
    name: []const u8,
    palette: PaletteFn,
    tone: ToneFn,
    is_background: bool,
    background: ?ColorFn,
    second_background: ?ColorFn,
    contrast_curve: ?ContrastCurve,
    tone_delta_pair: ?ToneDeltaFn,

    pub fn fromPalette(
        name: []const u8,
        pal: PaletteFn,
        tone: ToneFn,
    ) DynamicColor {
        return .{
            .name = name,
            .palette = pal,
            .tone = tone,
            .is_background = false,
            .background = null,
            .second_background = null,
            .contrast_curve = null,
            .tone_delta_pair = null,
        };
    }

    pub fn getArgb(self: *const DynamicColor, scheme: *const DynamicScheme) utils.Argb {
        return self.palette(scheme).get(self.getTone(scheme));
    }

    pub fn getHct(self: *const DynamicColor, scheme: *const DynamicScheme) cam.Hct {
        return cam.Hct.fromInt(self.getArgb(scheme));
    }

    pub fn getTone(self: *const DynamicColor, scheme: *const DynamicScheme) f64 {
        const decreasing = scheme.contrast_level < 0.0;
        if (self.tone_delta_pair) |tdp_fn| {
            // Case 1: dual foreground with a delta constraint.
            const tdp = tdp_fn(scheme);
            const bg = self.background.?(scheme);
            const bg_tone = bg.getTone(scheme);
            const a_is_nearer = tdp.polarity == .nearer or
                (tdp.polarity == .lighter and !scheme.is_dark) or
                (tdp.polarity == .darker and scheme.is_dark);
            const nearer = if (a_is_nearer) tdp.role_a else tdp.role_b;
            const farther = if (a_is_nearer) tdp.role_b else tdp.role_a;
            const am_nearer = std.mem.eql(u8, self.name, nearer.name);
            const expansion_dir: f64 = if (scheme.is_dark) 1.0 else -1.0;

            const n_contrast = nearer.contrast_curve.?.get(scheme.contrast_level);
            const f_contrast = farther.contrast_curve.?.get(scheme.contrast_level);
            const n_initial = nearer.tone(scheme);
            var n_tone = if (contrast.ratioOfTones(bg_tone, n_initial) >= n_contrast)
                n_initial
            else
                foregroundTone(bg_tone, n_contrast);
            const f_initial = farther.tone(scheme);
            var f_tone = if (contrast.ratioOfTones(bg_tone, f_initial) >= f_contrast)
                f_initial
            else
                foregroundTone(bg_tone, f_contrast);
            if (decreasing) {
                n_tone = foregroundTone(bg_tone, n_contrast);
                f_tone = foregroundTone(bg_tone, f_contrast);
            }
            if (!((f_tone - n_tone) * expansion_dir >= tdp.delta)) {
                f_tone = std.math.clamp(n_tone + tdp.delta * expansion_dir, 0.0, 100.0);
                if (!((f_tone - n_tone) * expansion_dir >= tdp.delta)) {
                    n_tone = std.math.clamp(f_tone - tdp.delta * expansion_dir, 0.0, 100.0);
                }
            }
            avoidAwkward(&n_tone, &f_tone, tdp.delta, expansion_dir, tdp.stay_together);
            return if (am_nearer) n_tone else f_tone;
        }

        // Case 2: solve for itself, possibly against one background.
        var answer = self.tone(scheme);
        if (self.background) |bg_fn| {
            const bg = bg_fn(scheme);
            const bg_tone = bg.getTone(scheme);
            const desired = self.contrast_curve.?.get(scheme.contrast_level);
            if (!(contrast.ratioOfTones(bg_tone, answer) >= desired)) {
                answer = foregroundTone(bg_tone, desired);
            }
            if (decreasing) {
                answer = foregroundTone(bg_tone, desired);
            }
            if (self.is_background and answer >= 50.0 and answer < 60.0) {
                answer = if (contrast.ratioOfTones(49.0, bg_tone) >= desired) 49.0 else 60.0;
            }
            if (self.second_background) |bg2_fn| {
                // Case 3: adjust for dual backgrounds.
                const bg_tone_1 = bg.getTone(scheme);
                const bg_tone_2 = bg2_fn(scheme).getTone(scheme);
                const upper = @max(bg_tone_1, bg_tone_2);
                const lower = @min(bg_tone_1, bg_tone_2);
                if (contrast.ratioOfTones(upper, answer) >= desired and
                    contrast.ratioOfTones(lower, answer) >= desired)
                {
                    return answer;
                }
                const light_option = contrast.lighter(upper, desired);
                const dark_option = contrast.darker(lower, desired);
                const prefers_light = tonePrefersLightForeground(bg_tone_1) or
                    tonePrefersLightForeground(bg_tone_2);
                if (prefers_light) {
                    return if (light_option < 0.0) 100.0 else light_option;
                }
                var availables: [2]f64 = undefined;
                var n_avail: usize = 0;
                if (light_option != -1.0) {
                    availables[n_avail] = light_option;
                    n_avail += 1;
                }
                if (dark_option != -1.0) {
                    availables[n_avail] = dark_option;
                    n_avail += 1;
                }
                if (n_avail == 1) return availables[0];
                return if (dark_option < 0.0) 0.0 else dark_option;
            }
        }
        return answer;
    }
};

/// The 50-59 awkward-zone fixup shared by the case-1 tail.
fn avoidAwkward(n_tone: *f64, f_tone: *f64, delta: f64, expansion_dir: f64, stay_together: bool) void {
    if (n_tone.* >= 50.0 and n_tone.* < 60.0) {
        if (expansion_dir > 0.0) {
            n_tone.* = 60.0;
            f_tone.* = @max(f_tone.*, n_tone.* + delta * expansion_dir);
        } else {
            n_tone.* = 49.0;
            f_tone.* = @min(f_tone.*, n_tone.* + delta * expansion_dir);
        }
    } else if (f_tone.* >= 50.0 and f_tone.* < 60.0) {
        if (stay_together) {
            if (expansion_dir > 0.0) {
                n_tone.* = 60.0;
                f_tone.* = @max(f_tone.*, n_tone.* + delta * expansion_dir);
            } else {
                n_tone.* = 49.0;
                f_tone.* = @min(f_tone.*, n_tone.* + delta * expansion_dir);
            }
        } else {
            if (expansion_dir > 0.0) {
                f_tone.* = 60.0;
            } else {
                f_tone.* = 49.0;
            }
        }
    }
}

pub fn foregroundTone(bg_tone: f64, ratio: f64) f64 {
    const lighter_tone = contrast.lighterUnsafe(bg_tone, ratio);
    const darker_tone = contrast.darkerUnsafe(bg_tone, ratio);
    const lighter_ratio = contrast.ratioOfTones(lighter_tone, bg_tone);
    const darker_ratio = contrast.ratioOfTones(darker_tone, bg_tone);
    if (tonePrefersLightForeground(bg_tone)) {
        // Integer-`abs` TU (verified by probe): the difference truncates, so
        // anything under 1.0 reads as negligible.
        const negligible = @trunc(@abs(lighter_ratio - darker_ratio)) < 0.1 and
            lighter_ratio < ratio and darker_ratio < ratio;
        if (lighter_ratio >= ratio or lighter_ratio >= darker_ratio or negligible) {
            return lighter_tone;
        }
        return darker_tone;
    }
    if (darker_ratio >= ratio or darker_ratio >= lighter_ratio) {
        return darker_tone;
    }
    return lighter_tone;
}

pub fn enableLightForeground(tone: f64) f64 {
    if (tonePrefersLightForeground(tone) and !toneAllowsLightForeground(tone)) return 49.0;
    return tone;
}

pub fn tonePrefersLightForeground(tone: f64) bool {
    return @round(tone) < 60.0;
}

pub fn toneAllowsLightForeground(tone: f64) bool {
    return @round(tone) <= 49.0;
}

pub fn isFidelity(scheme: *const DynamicScheme) bool {
    return scheme.variant == .fidelity or scheme.variant == .content;
}

pub fn isMonochrome(scheme: *const DynamicScheme) bool {
    return scheme.variant == .monochrome;
}

pub fn xyzInViewingConditions(c: cam.Cam, vc: cam.ViewingConditions) utils.Vec3 {
    const alpha = if (c.chroma == 0.0 or c.j == 0.0) 0.0 else c.chroma / @sqrt(c.j / 100.0);
    const t = libm.pow(
        alpha / libm.pow(1.64 - libm.pow(0.29, vc.background_y_to_white_point_y), 0.73),
        1.0 / 0.9,
    );
    const h_rad = c.hue * utils.k_pi / 180.0;
    const e_hue = 0.25 * (libm.cos(h_rad + 2.0) + 3.8);
    const ac = vc.aw * libm.pow(c.j / 100.0, 1.0 / vc.c / vc.z);
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
    const r_f = r_c / vc.rgb_d[0];
    const g_f = g_c / vc.rgb_d[1];
    const b_f = b_c / vc.rgb_d[2];
    return .{
        .a = 1.86206786 * r_f - 1.01125463 * g_f + 0.14918677 * b_f,
        .b = 0.38752654 * r_f + 0.62144744 * g_f - 0.00897398 * b_f,
        .c = -0.01584150 * r_f - 0.03412294 * g_f + 1.04996444 * b_f,
    };
}

pub fn inViewingConditions(hct: cam.Hct, vc: cam.ViewingConditions) cam.Hct {
    const cam16 = cam.camFromInt(hct.toInt());
    const viewed = xyzInViewingConditions(cam16, vc);
    const recast = cam.camFromXyzAndViewingConditions(viewed.a, viewed.b, viewed.c, cam.k_default_viewing_conditions);
    return cam.Hct.fromHct(recast.hue, recast.chroma, utils.lstarFromY(viewed.b));
}

pub const MaterialDynamicColors = struct {
    fn highestSurface(s: *const DynamicScheme) DynamicColor {
        return if (s.is_dark) surfaceBright() else surfaceDim();
    }

    fn palPrimary(s: *const DynamicScheme) palette.TonalPalette {
        return s.primary_palette;
    }
    fn palSecondary(s: *const DynamicScheme) palette.TonalPalette {
        return s.secondary_palette;
    }
    fn palTertiary(s: *const DynamicScheme) palette.TonalPalette {
        return s.tertiary_palette;
    }
    fn palNeutral(s: *const DynamicScheme) palette.TonalPalette {
        return s.neutral_palette;
    }
    fn palNeutralVariant(s: *const DynamicScheme) palette.TonalPalette {
        return s.neutral_variant_palette;
    }
    fn palError(s: *const DynamicScheme) palette.TonalPalette {
        return s.error_palette;
    }

    fn keyTonePrimary(s: *const DynamicScheme) f64 {
        return s.primary_palette.key_color.tone;
    }
    fn keyToneSecondary(s: *const DynamicScheme) f64 {
        return s.secondary_palette.key_color.tone;
    }
    fn keyToneTertiary(s: *const DynamicScheme) f64 {
        return s.tertiary_palette.key_color.tone;
    }
    fn keyToneNeutral(s: *const DynamicScheme) f64 {
        return s.neutral_palette.key_color.tone;
    }
    fn keyToneNeutralVariant(s: *const DynamicScheme) f64 {
        return s.neutral_variant_palette.key_color.tone;
    }

    pub fn primaryPaletteKeyColor() DynamicColor {
        return DynamicColor.fromPalette("primary_palette_key_color", palPrimary, keyTonePrimary);
    }
    pub fn secondaryPaletteKeyColor() DynamicColor {
        return DynamicColor.fromPalette("secondary_palette_key_color", palSecondary, keyToneSecondary);
    }
    pub fn tertiaryPaletteKeyColor() DynamicColor {
        return DynamicColor.fromPalette("tertiary_palette_key_color", palTertiary, keyToneTertiary);
    }
    pub fn neutralPaletteKeyColor() DynamicColor {
        return DynamicColor.fromPalette("neutral_palette_key_color", palNeutral, keyToneNeutral);
    }
    pub fn neutralVariantPaletteKeyColor() DynamicColor {
        return DynamicColor.fromPalette("neutral_variant_palette_key_color", palNeutralVariant, keyToneNeutralVariant);
    }

    fn toneBackground(s: *const DynamicScheme) f64 {
        return if (s.is_dark) 6.0 else 98.0;
    }

    pub fn background() DynamicColor {
        return .{ .name = "background", .palette = palNeutral, .tone = toneBackground, .is_background = true, .background = null, .second_background = null, .contrast_curve = null, .tone_delta_pair = null };
    }

    fn toneOnBackground(s: *const DynamicScheme) f64 {
        return if (s.is_dark) 90.0 else 10.0;
    }

    pub fn onBackground() DynamicColor {
        return .{ .name = "on_background", .palette = palNeutral, .tone = toneOnBackground, .is_background = false, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 3.0, .normal = 3.0, .medium = 4.5, .high = 7.0 }, .tone_delta_pair = null };
    }

    pub fn surface() DynamicColor {
        return .{ .name = "surface", .palette = palNeutral, .tone = toneBackground, .is_background = true, .background = null, .second_background = null, .contrast_curve = null, .tone_delta_pair = null };
    }

    fn toneSurfaceDim(s: *const DynamicScheme) f64 {
        if (s.is_dark) return 6.0;
        const curve = ContrastCurve{ .low = 87.0, .normal = 87.0, .medium = 80.0, .high = 75.0 };
        return curve.get(s.contrast_level);
    }

    pub fn surfaceDim() DynamicColor {
        return .{ .name = "surface_dim", .palette = palNeutral, .tone = toneSurfaceDim, .is_background = true, .background = null, .second_background = null, .contrast_curve = null, .tone_delta_pair = null };
    }

    fn toneSurfaceBright(s: *const DynamicScheme) f64 {
        if (s.is_dark) {
            const curve = ContrastCurve{ .low = 24.0, .normal = 24.0, .medium = 29.0, .high = 34.0 };
            return curve.get(s.contrast_level);
        }
        return 98.0;
    }

    pub fn surfaceBright() DynamicColor {
        return .{ .name = "surface_bright", .palette = palNeutral, .tone = toneSurfaceBright, .is_background = true, .background = null, .second_background = null, .contrast_curve = null, .tone_delta_pair = null };
    }

    fn toneLowest(s: *const DynamicScheme) f64 {
        if (s.is_dark) {
            const curve = ContrastCurve{ .low = 4.0, .normal = 4.0, .medium = 2.0, .high = 0.0 };
            return curve.get(s.contrast_level);
        }
        return 100.0;
    }

    pub fn surfaceContainerLowest() DynamicColor {
        return .{ .name = "surface_container_lowest", .palette = palNeutral, .tone = toneLowest, .is_background = true, .background = null, .second_background = null, .contrast_curve = null, .tone_delta_pair = null };
    }

    fn toneLow(s: *const DynamicScheme) f64 {
        if (s.is_dark) {
            const curve = ContrastCurve{ .low = 10.0, .normal = 10.0, .medium = 11.0, .high = 12.0 };
            return curve.get(s.contrast_level);
        }
        const curve = ContrastCurve{ .low = 96.0, .normal = 96.0, .medium = 96.0, .high = 95.0 };
        return curve.get(s.contrast_level);
    }

    pub fn surfaceContainerLow() DynamicColor {
        return .{ .name = "surface_container_low", .palette = palNeutral, .tone = toneLow, .is_background = true, .background = null, .second_background = null, .contrast_curve = null, .tone_delta_pair = null };
    }

    fn toneContainer(s: *const DynamicScheme) f64 {
        if (s.is_dark) {
            const curve = ContrastCurve{ .low = 12.0, .normal = 12.0, .medium = 16.0, .high = 20.0 };
            return curve.get(s.contrast_level);
        }
        const curve = ContrastCurve{ .low = 94.0, .normal = 94.0, .medium = 92.0, .high = 90.0 };
        return curve.get(s.contrast_level);
    }

    pub fn surfaceContainer() DynamicColor {
        return .{ .name = "surface_container", .palette = palNeutral, .tone = toneContainer, .is_background = true, .background = null, .second_background = null, .contrast_curve = null, .tone_delta_pair = null };
    }

    fn toneHigh(s: *const DynamicScheme) f64 {
        if (s.is_dark) {
            const curve = ContrastCurve{ .low = 17.0, .normal = 17.0, .medium = 21.0, .high = 25.0 };
            return curve.get(s.contrast_level);
        }
        const curve = ContrastCurve{ .low = 92.0, .normal = 92.0, .medium = 88.0, .high = 85.0 };
        return curve.get(s.contrast_level);
    }

    pub fn surfaceContainerHigh() DynamicColor {
        return .{ .name = "surface_container_high", .palette = palNeutral, .tone = toneHigh, .is_background = true, .background = null, .second_background = null, .contrast_curve = null, .tone_delta_pair = null };
    }

    fn toneHighest(s: *const DynamicScheme) f64 {
        if (s.is_dark) {
            const curve = ContrastCurve{ .low = 22.0, .normal = 22.0, .medium = 26.0, .high = 30.0 };
            return curve.get(s.contrast_level);
        }
        const curve = ContrastCurve{ .low = 90.0, .normal = 90.0, .medium = 84.0, .high = 80.0 };
        return curve.get(s.contrast_level);
    }

    pub fn surfaceContainerHighest() DynamicColor {
        return .{ .name = "surface_container_highest", .palette = palNeutral, .tone = toneHighest, .is_background = true, .background = null, .second_background = null, .contrast_curve = null, .tone_delta_pair = null };
    }

    pub fn onSurface() DynamicColor {
        return .{ .name = "on_surface", .palette = palNeutral, .tone = toneOnBackground, .is_background = false, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 4.5, .normal = 7.0, .medium = 11.0, .high = 21.0 }, .tone_delta_pair = null };
    }

    fn toneSurfaceVariant(s: *const DynamicScheme) f64 {
        return if (s.is_dark) 30.0 else 90.0;
    }

    pub fn surfaceVariant() DynamicColor {
        return .{ .name = "surface_variant", .palette = palNeutralVariant, .tone = toneSurfaceVariant, .is_background = true, .background = null, .second_background = null, .contrast_curve = null, .tone_delta_pair = null };
    }

    fn toneOnSurfaceVariant(s: *const DynamicScheme) f64 {
        return if (s.is_dark) 80.0 else 30.0;
    }

    pub fn onSurfaceVariant() DynamicColor {
        return .{ .name = "on_surface_variant", .palette = palNeutralVariant, .tone = toneOnSurfaceVariant, .is_background = false, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 3.0, .normal = 4.5, .medium = 7.0, .high = 11.0 }, .tone_delta_pair = null };
    }

    fn toneInverseSurface(s: *const DynamicScheme) f64 {
        return if (s.is_dark) 90.0 else 20.0;
    }

    pub fn inverseSurface() DynamicColor {
        return .{ .name = "inverse_surface", .palette = palNeutral, .tone = toneInverseSurface, .is_background = false, .background = null, .second_background = null, .contrast_curve = null, .tone_delta_pair = null };
    }

    fn toneInverseOnSurface(s: *const DynamicScheme) f64 {
        return if (s.is_dark) 20.0 else 95.0;
    }
    fn bgInverseSurface(_: *const DynamicScheme) DynamicColor {
        return inverseSurface();
    }

    pub fn inverseOnSurface() DynamicColor {
        return .{ .name = "inverse_on_surface", .palette = palNeutral, .tone = toneInverseOnSurface, .is_background = false, .background = bgInverseSurface, .second_background = null, .contrast_curve = .{ .low = 4.5, .normal = 7.0, .medium = 11.0, .high = 21.0 }, .tone_delta_pair = null };
    }

    fn toneOutline(s: *const DynamicScheme) f64 {
        return if (s.is_dark) 60.0 else 50.0;
    }

    pub fn outline() DynamicColor {
        return .{ .name = "outline", .palette = palNeutralVariant, .tone = toneOutline, .is_background = false, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 1.5, .normal = 3.0, .medium = 4.5, .high = 7.0 }, .tone_delta_pair = null };
    }

    fn toneOutlineVariant(s: *const DynamicScheme) f64 {
        return if (s.is_dark) 30.0 else 80.0;
    }

    pub fn outlineVariant() DynamicColor {
        return .{ .name = "outline_variant", .palette = palNeutralVariant, .tone = toneOutlineVariant, .is_background = false, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 1.0, .normal = 1.0, .medium = 3.0, .high = 4.5 }, .tone_delta_pair = null };
    }

    fn toneZero(_: *const DynamicScheme) f64 {
        return 0.0;
    }

    pub fn shadow() DynamicColor {
        return .{ .name = "shadow", .palette = palNeutral, .tone = toneZero, .is_background = false, .background = null, .second_background = null, .contrast_curve = null, .tone_delta_pair = null };
    }

    pub fn scrim() DynamicColor {
        return .{ .name = "scrim", .palette = palNeutral, .tone = toneZero, .is_background = false, .background = null, .second_background = null, .contrast_curve = null, .tone_delta_pair = null };
    }

    fn toneSurfaceTint(s: *const DynamicScheme) f64 {
        return if (s.is_dark) 80.0 else 40.0;
    }

    pub fn surfaceTint() DynamicColor {
        return .{ .name = "surface_tint", .palette = palPrimary, .tone = toneSurfaceTint, .is_background = true, .background = null, .second_background = null, .contrast_curve = null, .tone_delta_pair = null };
    }

    fn tonePrimary(s: *const DynamicScheme) f64 {
        if (isMonochrome(s)) return if (s.is_dark) 100.0 else 0.0;
        return if (s.is_dark) 80.0 else 40.0;
    }
    fn tdpPrimary(_: *const DynamicScheme) ToneDeltaPair {
        return .{ .role_a = primaryContainer(), .role_b = primary(), .delta = 10.0, .polarity = .nearer, .stay_together = false };
    }

    pub fn primary() DynamicColor {
        return .{ .name = "primary", .palette = palPrimary, .tone = tonePrimary, .is_background = true, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 3.0, .normal = 4.5, .medium = 7.0, .high = 7.0 }, .tone_delta_pair = tdpPrimary };
    }

    fn toneOnPrimary(s: *const DynamicScheme) f64 {
        if (isMonochrome(s)) return if (s.is_dark) 10.0 else 90.0;
        return if (s.is_dark) 20.0 else 100.0;
    }
    fn bgPrimary(_: *const DynamicScheme) DynamicColor {
        return primary();
    }

    pub fn onPrimary() DynamicColor {
        return .{ .name = "on_primary", .palette = palPrimary, .tone = toneOnPrimary, .is_background = false, .background = bgPrimary, .second_background = null, .contrast_curve = .{ .low = 4.5, .normal = 7.0, .medium = 11.0, .high = 21.0 }, .tone_delta_pair = null };
    }

    fn tonePrimaryContainer(s: *const DynamicScheme) f64 {
        if (isFidelity(s)) return s.source_color_hct.tone;
        if (isMonochrome(s)) return if (s.is_dark) 85.0 else 25.0;
        return if (s.is_dark) 30.0 else 90.0;
    }

    pub fn primaryContainer() DynamicColor {
        return .{ .name = "primary_container", .palette = palPrimary, .tone = tonePrimaryContainer, .is_background = true, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 1.0, .normal = 1.0, .medium = 3.0, .high = 4.5 }, .tone_delta_pair = tdpPrimary };
    }

    fn toneOnPrimaryContainer(s: *const DynamicScheme) f64 {
        if (isFidelity(s)) return foregroundTone(primaryContainer().tone(s), 4.5);
        if (isMonochrome(s)) return if (s.is_dark) 0.0 else 100.0;
        return if (s.is_dark) 90.0 else 30.0;
    }
    fn bgPrimaryContainer(_: *const DynamicScheme) DynamicColor {
        return primaryContainer();
    }

    pub fn onPrimaryContainer() DynamicColor {
        return .{ .name = "on_primary_container", .palette = palPrimary, .tone = toneOnPrimaryContainer, .is_background = false, .background = bgPrimaryContainer, .second_background = null, .contrast_curve = .{ .low = 3.0, .normal = 4.5, .medium = 7.0, .high = 11.0 }, .tone_delta_pair = null };
    }

    fn toneInversePrimary(s: *const DynamicScheme) f64 {
        return if (s.is_dark) 40.0 else 80.0;
    }

    pub fn inversePrimary() DynamicColor {
        return .{ .name = "inverse_primary", .palette = palPrimary, .tone = toneInversePrimary, .is_background = false, .background = bgInverseSurface, .second_background = null, .contrast_curve = .{ .low = 3.0, .normal = 4.5, .medium = 7.0, .high = 7.0 }, .tone_delta_pair = null };
    }

    fn toneSecondary(s: *const DynamicScheme) f64 {
        return if (s.is_dark) 80.0 else 40.0;
    }
    fn tdpSecondary(_: *const DynamicScheme) ToneDeltaPair {
        return .{ .role_a = secondaryContainer(), .role_b = secondary(), .delta = 10.0, .polarity = .nearer, .stay_together = false };
    }

    pub fn secondary() DynamicColor {
        return .{ .name = "secondary", .palette = palSecondary, .tone = toneSecondary, .is_background = true, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 3.0, .normal = 4.5, .medium = 7.0, .high = 7.0 }, .tone_delta_pair = tdpSecondary };
    }

    fn toneOnSecondary(s: *const DynamicScheme) f64 {
        if (isMonochrome(s)) return if (s.is_dark) 10.0 else 100.0;
        return if (s.is_dark) 20.0 else 100.0;
    }
    fn bgSecondary(_: *const DynamicScheme) DynamicColor {
        return secondary();
    }

    pub fn onSecondary() DynamicColor {
        return .{ .name = "on_secondary", .palette = palSecondary, .tone = toneOnSecondary, .is_background = false, .background = bgSecondary, .second_background = null, .contrast_curve = .{ .low = 4.5, .normal = 7.0, .medium = 11.0, .high = 21.0 }, .tone_delta_pair = null };
    }

    fn toneSecondaryContainer(s: *const DynamicScheme) f64 {
        const initial: f64 = if (s.is_dark) 30.0 else 90.0;
        if (isMonochrome(s)) return if (s.is_dark) 30.0 else 85.0;
        if (!isFidelity(s)) return initial;
        return findDesiredChromaByTone(
            s.secondary_palette.hue,
            s.secondary_palette.chroma,
            initial,
            if (s.is_dark) false else true,
        );
    }

    pub fn secondaryContainer() DynamicColor {
        return .{ .name = "secondary_container", .palette = palSecondary, .tone = toneSecondaryContainer, .is_background = true, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 1.0, .normal = 1.0, .medium = 3.0, .high = 4.5 }, .tone_delta_pair = tdpSecondary };
    }

    fn toneOnSecondaryContainer(s: *const DynamicScheme) f64 {
        if (isMonochrome(s)) return if (s.is_dark) 90.0 else 10.0;
        if (!isFidelity(s)) return if (s.is_dark) 90.0 else 30.0;
        return foregroundTone(secondaryContainer().tone(s), 4.5);
    }
    fn bgSecondaryContainer(_: *const DynamicScheme) DynamicColor {
        return secondaryContainer();
    }

    pub fn onSecondaryContainer() DynamicColor {
        return .{ .name = "on_secondary_container", .palette = palSecondary, .tone = toneOnSecondaryContainer, .is_background = false, .background = bgSecondaryContainer, .second_background = null, .contrast_curve = .{ .low = 3.0, .normal = 4.5, .medium = 7.0, .high = 11.0 }, .tone_delta_pair = null };
    }

    fn toneTertiary(s: *const DynamicScheme) f64 {
        if (isMonochrome(s)) return if (s.is_dark) 90.0 else 25.0;
        return if (s.is_dark) 80.0 else 40.0;
    }
    fn tdpTertiary(_: *const DynamicScheme) ToneDeltaPair {
        return .{ .role_a = tertiaryContainer(), .role_b = tertiary(), .delta = 10.0, .polarity = .nearer, .stay_together = false };
    }

    pub fn tertiary() DynamicColor {
        return .{ .name = "tertiary", .palette = palTertiary, .tone = toneTertiary, .is_background = true, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 3.0, .normal = 4.5, .medium = 7.0, .high = 7.0 }, .tone_delta_pair = tdpTertiary };
    }

    fn toneOnTertiary(s: *const DynamicScheme) f64 {
        if (isMonochrome(s)) return if (s.is_dark) 10.0 else 90.0;
        return if (s.is_dark) 20.0 else 100.0;
    }
    fn bgTertiary(_: *const DynamicScheme) DynamicColor {
        return tertiary();
    }

    pub fn onTertiary() DynamicColor {
        return .{ .name = "on_tertiary", .palette = palTertiary, .tone = toneOnTertiary, .is_background = false, .background = bgTertiary, .second_background = null, .contrast_curve = .{ .low = 4.5, .normal = 7.0, .medium = 11.0, .high = 21.0 }, .tone_delta_pair = null };
    }

    fn toneTertiaryContainer(s: *const DynamicScheme) f64 {
        if (isMonochrome(s)) return if (s.is_dark) 60.0 else 49.0;
        if (!isFidelity(s)) return if (s.is_dark) 30.0 else 90.0;
        const proposed = cam.Hct.fromInt(s.tertiary_palette.get(s.source_color_hct.tone));
        return dislike.fixIfDisliked(proposed).tone;
    }

    pub fn tertiaryContainer() DynamicColor {
        return .{ .name = "tertiary_container", .palette = palTertiary, .tone = toneTertiaryContainer, .is_background = true, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 1.0, .normal = 1.0, .medium = 3.0, .high = 4.5 }, .tone_delta_pair = tdpTertiary };
    }

    fn toneOnTertiaryContainer(s: *const DynamicScheme) f64 {
        if (isMonochrome(s)) return if (s.is_dark) 0.0 else 100.0;
        if (!isFidelity(s)) return if (s.is_dark) 90.0 else 30.0;
        return foregroundTone(tertiaryContainer().tone(s), 4.5);
    }
    fn bgTertiaryContainer(_: *const DynamicScheme) DynamicColor {
        return tertiaryContainer();
    }

    pub fn onTertiaryContainer() DynamicColor {
        return .{ .name = "on_tertiary_container", .palette = palTertiary, .tone = toneOnTertiaryContainer, .is_background = false, .background = bgTertiaryContainer, .second_background = null, .contrast_curve = .{ .low = 3.0, .normal = 4.5, .medium = 7.0, .high = 11.0 }, .tone_delta_pair = null };
    }

    fn toneError(s: *const DynamicScheme) f64 {
        return if (s.is_dark) 80.0 else 40.0;
    }
    fn tdpError(_: *const DynamicScheme) ToneDeltaPair {
        return .{ .role_a = errorContainer(), .role_b = err(), .delta = 10.0, .polarity = .nearer, .stay_together = false };
    }

    pub fn err() DynamicColor {
        return .{ .name = "error", .palette = palError, .tone = toneError, .is_background = true, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 3.0, .normal = 4.5, .medium = 7.0, .high = 7.0 }, .tone_delta_pair = tdpError };
    }

    fn toneOnError(s: *const DynamicScheme) f64 {
        return if (s.is_dark) 20.0 else 100.0;
    }
    fn bgError(_: *const DynamicScheme) DynamicColor {
        return err();
    }

    pub fn onError() DynamicColor {
        return .{ .name = "on_error", .palette = palError, .tone = toneOnError, .is_background = false, .background = bgError, .second_background = null, .contrast_curve = .{ .low = 4.5, .normal = 7.0, .medium = 11.0, .high = 21.0 }, .tone_delta_pair = null };
    }

    fn toneErrorContainer(s: *const DynamicScheme) f64 {
        return if (s.is_dark) 30.0 else 90.0;
    }

    pub fn errorContainer() DynamicColor {
        return .{ .name = "error_container", .palette = palError, .tone = toneErrorContainer, .is_background = true, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 1.0, .normal = 1.0, .medium = 3.0, .high = 4.5 }, .tone_delta_pair = tdpError };
    }

    fn toneOnErrorContainer(s: *const DynamicScheme) f64 {
        if (isMonochrome(s)) return if (s.is_dark) 90.0 else 10.0;
        return if (s.is_dark) 90.0 else 30.0;
    }
    fn bgErrorContainer(_: *const DynamicScheme) DynamicColor {
        return errorContainer();
    }

    pub fn onErrorContainer() DynamicColor {
        return .{ .name = "on_error_container", .palette = palError, .tone = toneOnErrorContainer, .is_background = false, .background = bgErrorContainer, .second_background = null, .contrast_curve = .{ .low = 3.0, .normal = 4.5, .medium = 7.0, .high = 11.0 }, .tone_delta_pair = null };
    }

    fn tonePrimaryFixed(s: *const DynamicScheme) f64 {
        return if (isMonochrome(s)) 40.0 else 90.0;
    }
    fn tdpPrimaryFixed(_: *const DynamicScheme) ToneDeltaPair {
        return .{ .role_a = primaryFixed(), .role_b = primaryFixedDim(), .delta = 10.0, .polarity = .lighter, .stay_together = true };
    }

    pub fn primaryFixed() DynamicColor {
        return .{ .name = "primary_fixed", .palette = palPrimary, .tone = tonePrimaryFixed, .is_background = true, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 1.0, .normal = 1.0, .medium = 3.0, .high = 4.5 }, .tone_delta_pair = tdpPrimaryFixed };
    }

    fn tonePrimaryFixedDim(s: *const DynamicScheme) f64 {
        return if (isMonochrome(s)) 30.0 else 80.0;
    }

    pub fn primaryFixedDim() DynamicColor {
        return .{ .name = "primary_fixed_dim", .palette = palPrimary, .tone = tonePrimaryFixedDim, .is_background = true, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 1.0, .normal = 1.0, .medium = 3.0, .high = 4.5 }, .tone_delta_pair = tdpPrimaryFixed };
    }

    fn toneOnPrimaryFixed(s: *const DynamicScheme) f64 {
        return if (isMonochrome(s)) 100.0 else 10.0;
    }
    fn bgPrimaryFixedDim(_: *const DynamicScheme) DynamicColor {
        return primaryFixedDim();
    }
    fn bg2PrimaryFixed(_: *const DynamicScheme) DynamicColor {
        return primaryFixed();
    }

    pub fn onPrimaryFixed() DynamicColor {
        return .{ .name = "on_primary_fixed", .palette = palPrimary, .tone = toneOnPrimaryFixed, .is_background = false, .background = bgPrimaryFixedDim, .second_background = bg2PrimaryFixed, .contrast_curve = .{ .low = 4.5, .normal = 7.0, .medium = 11.0, .high = 21.0 }, .tone_delta_pair = null };
    }

    fn toneOnPrimaryFixedVariant(s: *const DynamicScheme) f64 {
        return if (isMonochrome(s)) 90.0 else 30.0;
    }

    pub fn onPrimaryFixedVariant() DynamicColor {
        return .{ .name = "on_primary_fixed_variant", .palette = palPrimary, .tone = toneOnPrimaryFixedVariant, .is_background = false, .background = bgPrimaryFixedDim, .second_background = bg2PrimaryFixed, .contrast_curve = .{ .low = 3.0, .normal = 4.5, .medium = 7.0, .high = 11.0 }, .tone_delta_pair = null };
    }

    fn toneSecondaryFixed(s: *const DynamicScheme) f64 {
        return if (isMonochrome(s)) 80.0 else 90.0;
    }
    fn tdpSecondaryFixed(_: *const DynamicScheme) ToneDeltaPair {
        return .{ .role_a = secondaryFixed(), .role_b = secondaryFixedDim(), .delta = 10.0, .polarity = .lighter, .stay_together = true };
    }

    pub fn secondaryFixed() DynamicColor {
        return .{ .name = "secondary_fixed", .palette = palSecondary, .tone = toneSecondaryFixed, .is_background = true, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 1.0, .normal = 1.0, .medium = 3.0, .high = 4.5 }, .tone_delta_pair = tdpSecondaryFixed };
    }

    fn toneSecondaryFixedDim(s: *const DynamicScheme) f64 {
        return if (isMonochrome(s)) 70.0 else 80.0;
    }

    pub fn secondaryFixedDim() DynamicColor {
        return .{ .name = "secondary_fixed_dim", .palette = palSecondary, .tone = toneSecondaryFixedDim, .is_background = true, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 1.0, .normal = 1.0, .medium = 3.0, .high = 4.5 }, .tone_delta_pair = tdpSecondaryFixed };
    }

    fn toneOnSecondaryFixed(_: *const DynamicScheme) f64 {
        return 10.0;
    }
    fn bgSecondaryFixedDim(_: *const DynamicScheme) DynamicColor {
        return secondaryFixedDim();
    }
    fn bg2SecondaryFixed(_: *const DynamicScheme) DynamicColor {
        return secondaryFixed();
    }

    pub fn onSecondaryFixed() DynamicColor {
        return .{ .name = "on_secondary_fixed", .palette = palSecondary, .tone = toneOnSecondaryFixed, .is_background = false, .background = bgSecondaryFixedDim, .second_background = bg2SecondaryFixed, .contrast_curve = .{ .low = 4.5, .normal = 7.0, .medium = 11.0, .high = 21.0 }, .tone_delta_pair = null };
    }

    fn toneOnSecondaryFixedVariant(s: *const DynamicScheme) f64 {
        return if (isMonochrome(s)) 25.0 else 30.0;
    }

    pub fn onSecondaryFixedVariant() DynamicColor {
        return .{ .name = "on_secondary_fixed_variant", .palette = palSecondary, .tone = toneOnSecondaryFixedVariant, .is_background = false, .background = bgSecondaryFixedDim, .second_background = bg2SecondaryFixed, .contrast_curve = .{ .low = 3.0, .normal = 4.5, .medium = 7.0, .high = 11.0 }, .tone_delta_pair = null };
    }

    fn toneTertiaryFixed(s: *const DynamicScheme) f64 {
        return if (isMonochrome(s)) 40.0 else 90.0;
    }
    fn tdpTertiaryFixed(_: *const DynamicScheme) ToneDeltaPair {
        return .{ .role_a = tertiaryFixed(), .role_b = tertiaryFixedDim(), .delta = 10.0, .polarity = .lighter, .stay_together = true };
    }

    pub fn tertiaryFixed() DynamicColor {
        return .{ .name = "tertiary_fixed", .palette = palTertiary, .tone = toneTertiaryFixed, .is_background = true, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 1.0, .normal = 1.0, .medium = 3.0, .high = 4.5 }, .tone_delta_pair = tdpTertiaryFixed };
    }

    fn toneTertiaryFixedDim(s: *const DynamicScheme) f64 {
        return if (isMonochrome(s)) 30.0 else 80.0;
    }

    pub fn tertiaryFixedDim() DynamicColor {
        return .{ .name = "tertiary_fixed_dim", .palette = palTertiary, .tone = toneTertiaryFixedDim, .is_background = true, .background = highestSurface, .second_background = null, .contrast_curve = .{ .low = 1.0, .normal = 1.0, .medium = 3.0, .high = 4.5 }, .tone_delta_pair = tdpTertiaryFixed };
    }

    fn toneOnTertiaryFixed(s: *const DynamicScheme) f64 {
        return if (isMonochrome(s)) 100.0 else 10.0;
    }
    fn bgTertiaryFixedDim(_: *const DynamicScheme) DynamicColor {
        return tertiaryFixedDim();
    }
    fn bg2TertiaryFixed(_: *const DynamicScheme) DynamicColor {
        return tertiaryFixed();
    }

    pub fn onTertiaryFixed() DynamicColor {
        return .{ .name = "on_tertiary_fixed", .palette = palTertiary, .tone = toneOnTertiaryFixed, .is_background = false, .background = bgTertiaryFixedDim, .second_background = bg2TertiaryFixed, .contrast_curve = .{ .low = 4.5, .normal = 7.0, .medium = 11.0, .high = 21.0 }, .tone_delta_pair = null };
    }

    fn toneOnTertiaryFixedVariant(s: *const DynamicScheme) f64 {
        return if (isMonochrome(s)) 90.0 else 30.0;
    }

    pub fn onTertiaryFixedVariant() DynamicColor {
        return .{ .name = "on_tertiary_fixed_variant", .palette = palTertiary, .tone = toneOnTertiaryFixedVariant, .is_background = false, .background = bgTertiaryFixedDim, .second_background = bg2TertiaryFixed, .contrast_curve = .{ .low = 3.0, .normal = 4.5, .medium = 7.0, .high = 11.0 }, .tone_delta_pair = null };
    }
};

pub fn findDesiredChromaByTone(hue: f64, chroma: f64, tone: f64, by_decreasing_tone: bool) f64 {
    var answer = tone;
    var closest = cam.Hct.fromHct(hue, chroma, tone);
    if (closest.chroma < chroma) {
        var chroma_peak = closest.chroma;
        while (closest.chroma < chroma) {
            answer += if (by_decreasing_tone) -1.0 else 1.0;
            const potential = cam.Hct.fromHct(hue, chroma, answer);
            if (chroma_peak > potential.chroma) break;
            // Integer-`abs` TU (verified by probe).
            if (@trunc(@abs(potential.chroma - chroma)) < 0.4) break;
            const potential_delta = @trunc(@abs(potential.chroma - chroma));
            const current_delta = @trunc(@abs(closest.chroma - chroma));
            if (potential_delta < current_delta) closest = potential;
            chroma_peak = @max(chroma_peak, potential.chroma);
        }
    }
    return answer;
}

const vibrant_hues = [_]f64{ 0.0, 41.0, 61.0, 101.0, 131.0, 181.0, 251.0, 301.0, 360.0 };
const vibrant_secondary_rotations = [_]f64{ 18.0, 15.0, 10.0, 12.0, 15.0, 18.0, 15.0, 12.0, 12.0 };
const vibrant_tertiary_rotations = [_]f64{ 35.0, 30.0, 20.0, 25.0, 30.0, 35.0, 30.0, 25.0, 25.0 };

const expressive_hues = [_]f64{ 0.0, 21.0, 51.0, 121.0, 151.0, 191.0, 271.0, 321.0, 360.0 };
const expressive_secondary_rotations = [_]f64{ 45.0, 95.0, 45.0, 20.0, 45.0, 90.0, 45.0, 45.0, 45.0 };
const expressive_tertiary_rotations = [_]f64{ 120.0, 120.0, 20.0, 45.0, 20.0, 15.0, 20.0, 120.0, 120.0 };

pub fn contentScheme(alloc: std.mem.Allocator, hct: cam.Hct, dark: bool, contrast_level: f64) !DynamicScheme {
    var tc = temperature.TemperatureCache.init(hct);
    var an = try tc.getAnalogousColors(alloc, 3, 6);
    defer an.deinit(alloc);
    return DynamicScheme.init(
        hct,
        .content,
        contrast_level,
        dark,
        palette.TonalPalette.fromHueChroma(hct.hue, hct.chroma),
        palette.TonalPalette.fromHueChroma(hct.hue, @max(hct.chroma - 32.0, hct.chroma * 0.5)),
        palette.TonalPalette.fromHct(dislike.fixIfDisliked(an.items[2])),
        palette.TonalPalette.fromHueChroma(hct.hue, hct.chroma / 8.0),
        palette.TonalPalette.fromHueChroma(hct.hue, hct.chroma / 8.0 + 4.0),
        null,
    );
}

pub fn expressiveScheme(hct: cam.Hct, dark: bool, contrast_level: f64) DynamicScheme {
    return DynamicScheme.init(
        hct,
        .expressive,
        contrast_level,
        dark,
        palette.TonalPalette.fromHueChroma(hct.hue + 240.0, 40.0),
        palette.TonalPalette.fromHueChroma(DynamicScheme.getRotatedHue(hct, &expressive_hues, &expressive_secondary_rotations), 24.0),
        palette.TonalPalette.fromHueChroma(DynamicScheme.getRotatedHue(hct, &expressive_hues, &expressive_tertiary_rotations), 32.0),
        palette.TonalPalette.fromHueChroma(hct.hue + 15.0, 8.0),
        palette.TonalPalette.fromHueChroma(hct.hue + 15.0, 12.0),
        null,
    );
}

pub fn fidelityScheme(hct: cam.Hct, dark: bool, contrast_level: f64) DynamicScheme {
    var tc = temperature.TemperatureCache.init(hct);
    return DynamicScheme.init(
        hct,
        .fidelity,
        contrast_level,
        dark,
        palette.TonalPalette.fromHueChroma(hct.hue, hct.chroma),
        palette.TonalPalette.fromHueChroma(hct.hue, @max(hct.chroma - 32.0, hct.chroma * 0.5)),
        palette.TonalPalette.fromHct(dislike.fixIfDisliked(tc.getComplement())),
        palette.TonalPalette.fromHueChroma(hct.hue, hct.chroma / 8.0),
        palette.TonalPalette.fromHueChroma(hct.hue, hct.chroma / 8.0 + 4.0),
        null,
    );
}

pub fn fruitSaladScheme(hct: cam.Hct, dark: bool, contrast_level: f64) DynamicScheme {
    return DynamicScheme.init(
        hct,
        .fruit_salad,
        contrast_level,
        dark,
        palette.TonalPalette.fromHueChroma(utils.sanitizeDegreesDouble(hct.hue - 50.0), 48.0),
        palette.TonalPalette.fromHueChroma(utils.sanitizeDegreesDouble(hct.hue - 50.0), 36.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 36.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 10.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 16.0),
        null,
    );
}

pub fn monochromeScheme(hct: cam.Hct, dark: bool, contrast_level: f64) DynamicScheme {
    return DynamicScheme.init(
        hct,
        .monochrome,
        contrast_level,
        dark,
        palette.TonalPalette.fromHueChroma(hct.hue, 0.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 0.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 0.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 0.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 0.0),
        null,
    );
}

pub fn neutralScheme(hct: cam.Hct, dark: bool, contrast_level: f64) DynamicScheme {
    return DynamicScheme.init(
        hct,
        .neutral,
        contrast_level,
        dark,
        palette.TonalPalette.fromHueChroma(hct.hue, 12.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 8.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 16.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 2.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 2.0),
        null,
    );
}

pub fn rainbowScheme(hct: cam.Hct, dark: bool, contrast_level: f64) DynamicScheme {
    return DynamicScheme.init(
        hct,
        .rainbow,
        contrast_level,
        dark,
        palette.TonalPalette.fromHueChroma(hct.hue, 48.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 16.0),
        palette.TonalPalette.fromHueChroma(utils.sanitizeDegreesDouble(hct.hue + 60.0), 24.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 0.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 0.0),
        null,
    );
}

pub fn tonalSpotScheme(hct: cam.Hct, dark: bool, contrast_level: f64) DynamicScheme {
    return DynamicScheme.init(
        hct,
        .tonal_spot,
        contrast_level,
        dark,
        palette.TonalPalette.fromHueChroma(hct.hue, 36.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 16.0),
        palette.TonalPalette.fromHueChroma(utils.sanitizeDegreesDouble(hct.hue + 60.0), 24.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 6.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 8.0),
        null,
    );
}

pub fn vibrantScheme(hct: cam.Hct, dark: bool, contrast_level: f64) DynamicScheme {
    return DynamicScheme.init(
        hct,
        .vibrant,
        contrast_level,
        dark,
        palette.TonalPalette.fromHueChroma(hct.hue, 200.0),
        palette.TonalPalette.fromHueChroma(DynamicScheme.getRotatedHue(hct, &vibrant_hues, &vibrant_secondary_rotations), 24.0),
        palette.TonalPalette.fromHueChroma(DynamicScheme.getRotatedHue(hct, &vibrant_hues, &vibrant_tertiary_rotations), 32.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 10.0),
        palette.TonalPalette.fromHueChroma(hct.hue, 12.0),
        null,
    );
}

const scheme_oracle = @import("scheme_oracle.zig");

const RoleFn = *const fn (*const DynamicScheme) utils.Argb;

const role_fns = [_]RoleFn{
    DynamicScheme.getPrimary,
    DynamicScheme.getOnPrimary,
    DynamicScheme.getPrimaryContainer,
    DynamicScheme.getOnPrimaryContainer,
    DynamicScheme.getSecondary,
    DynamicScheme.getOnSecondary,
    DynamicScheme.getSecondaryContainer,
    DynamicScheme.getOnSecondaryContainer,
    DynamicScheme.getTertiary,
    DynamicScheme.getOnTertiary,
    DynamicScheme.getTertiaryContainer,
    DynamicScheme.getOnTertiaryContainer,
    DynamicScheme.getError,
    DynamicScheme.getOnError,
    DynamicScheme.getErrorContainer,
    DynamicScheme.getOnErrorContainer,
    DynamicScheme.getSurface,
    DynamicScheme.getOnSurface,
    DynamicScheme.getSurfaceVariant,
    DynamicScheme.getOnSurfaceVariant,
    DynamicScheme.getSurfaceDim,
    DynamicScheme.getSurfaceBright,
    DynamicScheme.getSurfaceContainerLowest,
    DynamicScheme.getSurfaceContainerLow,
    DynamicScheme.getSurfaceContainer,
    DynamicScheme.getSurfaceContainerHigh,
    DynamicScheme.getSurfaceContainerHighest,
    DynamicScheme.getInverseSurface,
    DynamicScheme.getInverseOnSurface,
    DynamicScheme.getInversePrimary,
    DynamicScheme.getOutline,
    DynamicScheme.getOutlineVariant,
    DynamicScheme.getShadow,
    DynamicScheme.getScrim,
    DynamicScheme.getSurfaceTint,
    DynamicScheme.getPrimaryFixed,
    DynamicScheme.getPrimaryFixedDim,
    DynamicScheme.getOnPrimaryFixed,
    DynamicScheme.getOnPrimaryFixedVariant,
    DynamicScheme.getSecondaryFixed,
    DynamicScheme.getSecondaryFixedDim,
    DynamicScheme.getOnSecondaryFixed,
    DynamicScheme.getOnSecondaryFixedVariant,
    DynamicScheme.getTertiaryFixed,
    DynamicScheme.getTertiaryFixedDim,
    DynamicScheme.getOnTertiaryFixed,
    DynamicScheme.getOnTertiaryFixedVariant,
};

fn buildScheme(alloc: std.mem.Allocator, variant: []const u8, seed: u32, dark: bool) !DynamicScheme {
    const hct = cam.Hct.fromInt(seed);
    if (std.mem.eql(u8, variant, "content")) return contentScheme(alloc, hct, dark, 0.0);
    if (std.mem.eql(u8, variant, "vibrant")) return vibrantScheme(hct, dark, 0.0);
    if (std.mem.eql(u8, variant, "tonalspot")) return tonalSpotScheme(hct, dark, 0.0);
    if (std.mem.eql(u8, variant, "expressive")) return expressiveScheme(hct, dark, 0.0);
    if (std.mem.eql(u8, variant, "fidelity")) return fidelityScheme(hct, dark, 0.0);
    if (std.mem.eql(u8, variant, "monochrome")) return monochromeScheme(hct, dark, 0.0);
    if (std.mem.eql(u8, variant, "neutral")) return neutralScheme(hct, dark, 0.0);
    if (std.mem.eql(u8, variant, "rainbow")) return rainbowScheme(hct, dark, 0.0);
    if (std.mem.eql(u8, variant, "fruitsalad")) return fruitSaladScheme(hct, dark, 0.0);
    unreachable;
}

fn rolesHash(scheme: *const DynamicScheme) u64 {
    var h: u64 = 14695981039346656037;
    for (role_fns) |f| {
        const v = f(scheme);
        for ([_]u8{
            @intCast((v >> 24) & 0xFF),
            @intCast((v >> 16) & 0xFF),
            @intCast((v >> 8) & 0xFF),
            @intCast(v & 0xFF),
        }) |b| {
            h ^= b;
            h *%= 1099511628211;
        }
    }
    return h;
}

test "mcu-schemes: content and vibrant roles match the oracle exactly" {
    const t = std.testing;
    const alloc = t.allocator;
    for (scheme_oracle.spots) |spot| {
        var scheme = try buildScheme(alloc, spot.variant, spot.seed, spot.dark);
        for (role_fns, 0..) |f, i| {
            const got = f(&scheme);
            if (got != spot.roles[i]) {
                std.debug.print("ROLE MISMATCH {s} {s} seed={X:0>8} idx={d} want={X:0>8} got={X:0>8}\n", .{ spot.variant, if (spot.dark) "dark" else "light", spot.seed, i, spot.roles[i], got });
            }
            try t.expectEqual(spot.roles[i], got);
        }
    }
}

test "mcu-schemes: all seeds and variants hash-match the oracle" {
    const t = std.testing;
    const alloc = t.allocator;
    for (scheme_oracle.entries) |e| {
        var scheme = try buildScheme(alloc, e.variant, e.seed, e.dark);
        const got = rolesHash(&scheme);
        if (got != e.roles_hash) {
            std.debug.print("HASH MISMATCH {s} {s} seed={X:0>8} want={X:0>16} got={X:0>16}\n", .{ e.variant, if (e.dark) "dark" else "light", e.seed, e.roles_hash, got });
            for (role_fns, 0..) |f, i| {
                std.debug.print("  role {d} {X:0>8}\n", .{ i, f(&scheme) });
            }
        }
        try t.expectEqual(e.roles_hash, got);
    }
}
