//! `derived_chrome_colors(sc.appearance)` — the full `ChromePaintColors`
//! port: custom theme, horizon-native and matugen palettes, then
//! defaults, with `apply_color_adjustment` on the same seven groups (never
//! text) in every branch. One port, shared, so a wallpaper recolor cannot
//! move the widgets apart.

const std = @import("std");
const schema = @import("../../../config/schema.zig");
const tokens = @import("../../../m3/tokens.zig");
const libm = @import("../../../color/mcu/libm.zig");

pub const Rgb = tokens.Rgb;

pub const Chrome = struct {
    dock_fill: Rgb = .{ .r = 0.12, .g = 0.12, .b = 0.14 },
    panel_fill: Rgb = .{ .r = 0.08, .g = 0.10, .b = 0.13 },
    drawer_dim: Rgb = .{ .r = 0.11, .g = 0.11, .b = 0.13 },
    outline: Rgb = .{ .r = 0.55, .g = 0.60, .b = 0.62 },
    accent: Rgb = .{ .r = 0.90, .g = 0.90, .b = 0.90 },
    text: Rgb = tokens.Tokens.text,
    notif_bg: Rgb = .{ .r = 0.20, .g = 0.08, .b = 0.08 },
    notif_ol: Rgb = .{ .r = 0.75, .g = 0.15, .b = 0.15 },
};

fn fromF32(v: [3]f32) Rgb {
    return .{ .r = @as(f64, v[0]), .g = @as(f64, v[1]), .b = @as(f64, v[2]) };
}

fn scaled(v: Rgb, k: f64) Rgb {
    return .{ .r = v.r * k, .g = v.g * k, .b = v.b * k };
}

fn applyAdjustment(c: *Rgb, brightness: f64, contrast: f64, vibrance: f64, gamma: f64) void {
    var r = c.r * brightness;
    var g = c.g * brightness;
    var b = c.b * brightness;
    r = (r - 0.5) * contrast + 0.5;
    g = (g - 0.5) * contrast + 0.5;
    b = (b - 0.5) * contrast + 0.5;
    const gray = (r + g + b) / 3.0;
    r = gray + (r - gray) * vibrance;
    g = gray + (g - gray) * vibrance;
    b = gray + (b - gray) * vibrance;
    r = libm.pow(r, 1.0 / gamma);
    g = libm.pow(g, 1.0 / gamma);
    b = libm.pow(b, 1.0 / gamma);
    c.r = std.math.clamp(r, 0.0, 1.0);
    c.g = std.math.clamp(g, 0.0, 1.0);
    c.b = std.math.clamp(b, 0.0, 1.0);
}

fn adjustAll(c: *Chrome, sc: *const schema.ShellConfig) void {
    const a = sc.appearance;
    const b = @as(f64, a.color_brightness);
    const k = @as(f64, a.color_contrast);
    const v = @as(f64, a.color_vibrance);
    const g = @as(f64, a.color_gamma);
    applyAdjustment(&c.dock_fill, b, k, v, g);
    applyAdjustment(&c.panel_fill, b, k, v, g);
    applyAdjustment(&c.drawer_dim, b, k, v, g);
    applyAdjustment(&c.outline, b, k, v, g);
    applyAdjustment(&c.accent, b, k, v, g);
    applyAdjustment(&c.notif_bg, b, k, v, g);
    applyAdjustment(&c.notif_ol, b, k, v, g);
}

pub fn of(sc: *const schema.ShellConfig) Chrome {
    const a = sc.appearance;
    if (a.custom_theme_enabled) {
        var c = Chrome{
            .dock_fill = fromF32(a.custom_surface),
            .panel_fill = fromF32(a.custom_surface_variant),
            .drawer_dim = scaled(fromF32(a.custom_surface), 0.85),
            .outline = fromF32(a.custom_outline),
            .accent = fromF32(a.custom_primary),
            .text = fromF32(a.custom_on_surface),
            .notif_bg = fromF32(a.custom_error),
            .notif_ol = fromF32(a.custom_outline),
        };
        adjustAll(&c, sc);
        return c;
    }
    if (a.horizon_colors_native and a.horizon_colors_ok) {
        var c = Chrome{
            .dock_fill = fromF32(a.hc_dock_fill),
            .panel_fill = fromF32(a.hc_panel_fill),
            .drawer_dim = fromF32(a.hc_drawer_dim),
            .outline = fromF32(a.hc_outline),
            .accent = fromF32(a.hc_accent),
            .text = fromF32(a.hc_text),
            .notif_bg = fromF32(a.hc_notif_bg),
            .notif_ol = fromF32(a.hc_notif_ol),
        };
        adjustAll(&c, sc);
        return c;
    }
    if (a.matugen_theming and a.matugen_palette_ok) {
        var c = Chrome{
            .dock_fill = fromF32(a.matugen_dock_fill),
            .panel_fill = fromF32(a.matugen_panel_fill),
            .drawer_dim = fromF32(a.matugen_drawer_dim),
            .outline = fromF32(a.matugen_outline),
            .accent = fromF32(a.matugen_accent),
            .text = fromF32(a.matugen_text),
            .notif_bg = fromF32(a.matugen_notif_bg),
            .notif_ol = fromF32(a.matugen_notif_ol),
        };
        adjustAll(&c, sc);
        return c;
    }
    var c = Chrome{};
    adjustAll(&c, sc);
    return c;
}

test "chrome-colors: a custom theme reads the config's own triples" {
    const t = std.testing;
    var c: schema.ShellConfig = .{};
    try t.expectEqual(Rgb{ .r = 0.12, .g = 0.12, .b = 0.14 }, of(&c).dock_fill);
    c.appearance.custom_theme_enabled = true;
    c.appearance.custom_surface = .{ 0.2, 0.3, 0.4 };
    c.appearance.custom_primary = .{ 0.5, 0.6, 0.7 };
    c.appearance.custom_on_surface = .{ 0.8, 0.9, 1.0 };
    const got = of(&c);
    try t.expectApproxEqAbs(@as(f64, 0.2), got.dock_fill.r, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 0.6), got.accent.g, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 1.0), got.text.b, 1e-6);
}

test "chrome-colors: branch priority and derived fields" {
    const t = std.testing;
    var c: schema.ShellConfig = .{};
    // Default branch carries its own notif values (distinct from the field
    // defaults, which feed the palette branches).
    try t.expectApproxEqAbs(@as(f64, 0.20), of(&c).notif_bg.r, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 0.75), of(&c).notif_ol.r, 1e-6);
    // Custom wins over everything and derives panel/drawer/notif_ol.
    c.appearance.custom_theme_enabled = true;
    c.appearance.custom_surface = .{ 0.2, 0.3, 0.4 };
    c.appearance.custom_surface_variant = .{ 0.5, 0.5, 0.5 };
    c.appearance.custom_outline = .{ 0.1, 0.1, 0.1 };
    c.appearance.horizon_colors_native = true;
    c.appearance.horizon_colors_ok = true;
    c.appearance.hc_accent = .{ 0.9, 0.9, 0.9 };
    const custom = of(&c);
    try t.expectApproxEqAbs(@as(f64, 0.5), custom.panel_fill.r, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 0.2 * 0.85), custom.drawer_dim.r, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 0.1), custom.notif_ol.r, 1e-6);
    // Horizon wins over matugen.
    c.appearance.custom_theme_enabled = false;
    c.appearance.matugen_theming = true;
    c.appearance.matugen_palette_ok = true;
    c.appearance.matugen_accent = .{ 0.1, 0.2, 0.3 };
    c.appearance.hc_accent = .{ 0.7, 0.8, 0.9 };
    try t.expectApproxEqAbs(@as(f64, 0.7), of(&c).accent.r, 1e-6);
    // Matugen alone.
    c.appearance.horizon_colors_ok = false;
    try t.expectApproxEqAbs(@as(f64, 0.1), of(&c).accent.r, 1e-6);
}

test "chrome-colors: adjustment matches the probe values" {
    const t = std.testing;
    var c: schema.ShellConfig = .{};
    c.appearance.custom_theme_enabled = true;
    c.appearance.custom_surface = .{ 0.2, 0.3, 0.4 };
    c.appearance.custom_primary = .{ 0.2, 0.3, 0.4 };
    c.appearance.custom_on_surface = .{ 0.8, 0.9, 1.0 };
    c.appearance.custom_error = .{ 0.2, 0.3, 0.4 };
    c.appearance.custom_outline = .{ 0.2, 0.3, 0.4 };
    c.appearance.custom_surface_variant = .{ 0.2, 0.3, 0.4 };
    // Identity knobs leave values alone (exact at 1e-6).
    var got = of(&c);
    try t.expectApproxEqAbs(@as(f64, 0.2), got.dock_fill.r, 1e-6);
    // Worked knobs (probe: 0.143639494 0.307512187 0.481078395).
    c.appearance.color_brightness = 1.2;
    c.appearance.color_contrast = 1.1;
    c.appearance.color_vibrance = 1.3;
    c.appearance.color_gamma = 0.9;
    got = of(&c);
    try t.expectApproxEqAbs(@as(f64, 0.143639494), got.dock_fill.r, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 0.307512187), got.dock_fill.g, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 0.481078395), got.dock_fill.b, 1e-6);
    // Extreme knobs clamp (probe: 0.651920241 ×3) and text stays untouched.
    c.appearance.custom_primary = .{ 0.9, 0.9, 0.9 };
    c.appearance.color_brightness = 0.5;
    c.appearance.color_contrast = 1.5;
    c.appearance.color_vibrance = 0.0;
    c.appearance.color_gamma = 2.0;
    got = of(&c);
    try t.expectApproxEqAbs(@as(f64, 0.651920241), got.accent.r, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 0.651920241), got.accent.g, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 0.8), got.text.r, 1e-6);
}
