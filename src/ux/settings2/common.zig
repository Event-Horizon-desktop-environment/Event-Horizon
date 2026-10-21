const std = @import("std");

// Shared settings drawing primitives.
// Same design and layout: M3 dark defaults, spacing/card constants,
// sidebar geometry, toggle/slider/combo geometry, color resolution order
// (custom theme > matugen > horizon > default).

/// Window chrome colors. `var`, not `const`: the window resolves the
/// active palette once per frame (`resolveColors` over the settings fields)
/// and publishes it here, so every paint site follows the wallpaper without
/// signature changes. Initial values are the M3 dark fallbacks, which is also
/// what a fresh resolve produces with everything disabled.
pub const Theme = struct {
    pub var bg_r: f64 = 0.102;
    pub var bg_g: f64 = 0.075;
    pub var bg_b: f64 = 0.188;
    pub var text_r: f64 = 1.0;
    pub var text_g: f64 = 1.0;
    pub var text_b: f64 = 1.0;
    pub var acc_r: f64 = 0.769;
    pub var acc_g: f64 = 0.659;
    pub var acc_b: f64 = 0.941;
    // M3 outline (dark): tracks and combo strokes when no matugen override.
    pub var outline_r: f64 = 0.58;
    pub var outline_g: f64 = 0.56;
    pub var outline_b: f64 = 0.60;
};

pub const spacing_xs: i32 = 4;
pub const spacing_s: i32 = 8;
pub const spacing_m: i32 = 12;
pub const spacing_l: i32 = 16;
pub const spacing_xl: i32 = 24;

// Design B (rail and list): the content column starts right under the close
// pill (pill spans spacing_l..spacing_l+28); there is no page header any
// more — it read as clutter on every tab.
pub const content_top: i32 = 48;
pub const card_pad: i32 = 16;
pub const card_gap: i32 = 12;
pub const card_radius: f64 = 18.0;

// Nav columns: a 96px icon rail plus a 264px page list, flush full-height
// columns like the HTML design (rail darker, hairline borders). `sidebar_w`
// keeps its name (widget_add insets and events.regionFor all read it) but is
// now the full nav width: rail + list, no gap.
pub const rail_w: i32 = 96;
pub const list_w: i32 = 264;
pub const rail_x: i32 = 0;
pub const list_x: i32 = rail_w; // 96
pub const sidebar_w: i32 = rail_w + list_w; // 360

// Left edge of the content column: nav width plus the gutter before the card
// area. The window's `Content` and the embed geometry both start here, so the
// two cannot disagree about where the card column begins.
pub const content_x: i32 = 386;

// Rail buttons: icon over an 11px label, rail padding 14px 8px like HTML.
pub const rail_btn_h: i32 = 58;
pub const rail_pitch_y: i32 = 62;
pub const rail_base_y: i32 = 14;

// Page-list rows inside the list column: search bar, h3 title, 36px rows.
pub const list_title_y: i32 = 86; // baseline of the category h3
pub const list_row_base_y: i32 = 100;
pub const list_row_h: i32 = 36;
pub const list_row_pitch_y: i32 = 38;

pub const settings_combo_w: i32 = 200;
pub const settings_combo_h: i32 = 28;
pub const tab_bar_h: i32 = 36;
pub const settings_dd_row_h: i32 = 26;
pub const slider_row_h: i32 = 68;

// Child (sub) tab bar — kDockChildTabH=34 + 6px strip, cards start at
// kContentTop + kDockChildTabH + 12 (=62) for the tab rows.
pub const child_tab_h: i32 = 34;
pub const child_bar_h: i32 = child_tab_h + 6;
pub const child_content_top: i32 = content_top + child_tab_h + 12; // 94
pub const child_tab_w: i32 = 130;

// m3 Toggle Size::L — 40x24 (kDockVisRowPitch rows centre it).
pub const toggle_w: i32 = 40;
pub const toggle_h: i32 = 24;

pub const group_gap: i32 = 6;

pub const ResolvedColors = struct {
    accent_r: f32,
    accent_g: f32,
    accent_b: f32,
    text_r: f32,
    text_g: f32,
    text_b: f32,
    surface_r: f32,
    surface_g: f32,
    surface_b: f32,
    outline_r: f32,
    outline_g: f32,
    outline_b: f32,
};

pub const ColorSource = enum { custom, matugen, horizon, fallback };

pub const ColorInputs = struct {
    custom_enabled: bool = false,
    theme_primary: [3]f32 = .{ 0.769, 0.659, 0.941 },
    theme_on_surface: [3]f32 = .{ 1, 1, 1 },
    theme_surface: [3]f32 = .{ 0.102, 0.075, 0.188 },
    theme_outline: [3]f32 = .{ 0.478, 0.416, 0.588 },
    matugen_enabled: bool = false,
    matugen_ok: bool = false,
    matugen_accent: [3]f32 = .{ 0.9, 0.9, 0.9 },
    matugen_text: [3]f32 = .{ 0.92, 0.92, 0.95 },
    matugen_surface: [3]f32 = .{ 0.12, 0.12, 0.14 },
    matugen_outline: [3]f32 = .{ 0.55, 0.60, 0.62 },
    horizon_enabled: bool = true,
    horizon_ok: bool = false,
    horizon_accent: [3]f32 = .{ 0.9, 0.9, 0.9 },
    horizon_surface: [3]f32 = .{ 0.12, 0.12, 0.14 },
    horizon_outline: [3]f32 = .{ 0.55, 0.60, 0.62 },
};

pub fn resolveColors(inp: ColorInputs) struct { colors: ResolvedColors, source: ColorSource } {
    if (inp.custom_enabled) {
        return .{
            .colors = .{
                .accent_r = inp.theme_primary[0],
                .accent_g = inp.theme_primary[1],
                .accent_b = inp.theme_primary[2],
                .text_r = inp.theme_on_surface[0],
                .text_g = inp.theme_on_surface[1],
                .text_b = inp.theme_on_surface[2],
                .surface_r = inp.theme_surface[0],
                .surface_g = inp.theme_surface[1],
                .surface_b = inp.theme_surface[2],
                .outline_r = inp.theme_outline[0],
                .outline_g = inp.theme_outline[1],
                .outline_b = inp.theme_outline[2],
            },
            .source = .custom,
        };
    }
    if (inp.matugen_enabled and inp.matugen_ok) {
        return .{
            .colors = .{
                .accent_r = inp.matugen_accent[0],
                .accent_g = inp.matugen_accent[1],
                .accent_b = inp.matugen_accent[2],
                .text_r = inp.matugen_text[0],
                .text_g = inp.matugen_text[1],
                .text_b = inp.matugen_text[2],
                .surface_r = inp.matugen_surface[0],
                .surface_g = inp.matugen_surface[1],
                .surface_b = inp.matugen_surface[2],
                .outline_r = inp.matugen_outline[0],
                .outline_g = inp.matugen_outline[1],
                .outline_b = inp.matugen_outline[2],
            },
            .source = .matugen,
        };
    }
    if (inp.horizon_enabled and inp.horizon_ok) {
        return .{
            .colors = .{
                .accent_r = inp.horizon_accent[0],
                .accent_g = inp.horizon_accent[1],
                .accent_b = inp.horizon_accent[2],
                .text_r = 1.0,
                .text_g = 1.0,
                .text_b = 1.0,
                .surface_r = inp.horizon_surface[0],
                .surface_g = inp.horizon_surface[1],
                .surface_b = inp.horizon_surface[2],
                .outline_r = inp.horizon_outline[0],
                .outline_g = inp.horizon_outline[1],
                .outline_b = inp.horizon_outline[2],
            },
            .source = .horizon,
        };
    }
    return .{
        .colors = .{
            .accent_r = @floatCast(Theme.acc_r),
            .accent_g = @floatCast(Theme.acc_g),
            .accent_b = @floatCast(Theme.acc_b),
            .text_r = @floatCast(Theme.text_r),
            .text_g = @floatCast(Theme.text_g),
            .text_b = @floatCast(Theme.text_b),
            .surface_r = @floatCast(Theme.bg_r),
            .surface_g = @floatCast(Theme.bg_g),
            .surface_b = @floatCast(Theme.bg_b),
            .outline_r = 0.5,
            .outline_g = 0.5,
            .outline_b = 0.5,
        },
        .source = .fallback,
    };
}

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub fn toggleGeom(cx: i32, card_y: i32, card_w: i32, card_h: i32) Rect {
    return .{
        .x = cx + card_w - toggle_w - spacing_xl,
        .y = card_y + @divTrunc(card_h - toggle_h, 2),
        .w = toggle_w,
        .h = toggle_h,
    };
}

pub fn pointInRect(px: f64, py: f64, r: Rect) bool {
    return px >= @as(f64, @floatFromInt(r.x)) and px < @as(f64, @floatFromInt(r.x + r.w)) and
        py >= @as(f64, @floatFromInt(r.y)) and py < @as(f64, @floatFromInt(r.y + r.h));
}

pub fn sliderValueFromX(px: f64, tr_x: i32, tr_w: i32, min_v: i32, max_v: i32) i32 {
    if (tr_w <= 0) return min_v;
    var t: f64 = (px - @as(f64, @floatFromInt(tr_x))) / @as(f64, @floatFromInt(tr_w));
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    const span: f64 = @floatFromInt(max_v - min_v);
    return min_v + @as(i32, @intFromFloat(@round(t * span)));
}

pub fn clampInt(v: i32, lo: i32, hi: i32) i32 {
    return @max(lo, @min(hi, v));
}

test "settings-common: layout constants are stable" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 0), rail_x);
    try t.expectEqual(@as(i32, 96), rail_w);
    try t.expectEqual(@as(i32, 96), list_x);
    try t.expectEqual(@as(i32, 264), list_w);
    try t.expectEqual(@as(i32, 360), sidebar_w);
    try t.expectEqual(@as(i32, 14), rail_base_y);
    try t.expectEqual(@as(i32, 86), list_title_y);
    try t.expectEqual(@as(i32, 100), list_row_base_y);
    try t.expectEqual(@as(i32, 48), content_top);
    try t.expectEqual(@as(i32, 68), slider_row_h);
    try t.expectEqual(@as(i32, 94), child_content_top);
    const g = toggleGeom(386, 112, 498, 64);
    try t.expectEqual(@as(i32, 40), g.w);
    try t.expectEqual(@as(i32, 24), g.h);
    try t.expectEqual(@as(i32, 386 + 498 - 40 - 24), g.x);
    try t.expect(sliderValueFromX(50, 0, 100, 0, 200) == 100);
    try t.expect(pointInRect(10, 10, .{ .x = 0, .y = 0, .w = 20, .h = 20 }));
}

test "settings-common: color resolution order" {
    const t = std.testing;
    const fall = resolveColors(.{});
    try t.expectEqual(ColorSource.fallback, fall.source);
    const mat = resolveColors(.{ .matugen_enabled = true, .matugen_ok = true });
    try t.expectEqual(ColorSource.matugen, mat.source);
    const cus = resolveColors(.{ .custom_enabled = true, .matugen_enabled = true, .matugen_ok = true });
    try t.expectEqual(ColorSource.custom, cus.source);
}

test "settings-common: horizon and matugen payloads resolve" {
    const t = std.testing;
    // Horizon branch forces white text, ignoring any payload.
    const hor = resolveColors(.{
        .horizon_enabled = true,
        .horizon_ok = true,
        .horizon_accent = .{ 0.1, 0.2, 0.3 },
        .horizon_surface = .{ 0.4, 0.5, 0.6 },
        .horizon_outline = .{ 0.7, 0.8, 0.9 },
    });
    try t.expectEqual(ColorSource.horizon, hor.source);
    try t.expectApproxEqAbs(@as(f32, 0.1), hor.colors.accent_r, 1e-9);
    try t.expectApproxEqAbs(@as(f32, 0.5), hor.colors.surface_g, 1e-9);
    try t.expectApproxEqAbs(@as(f32, 1.0), hor.colors.text_r, 1e-9);
    // Matugen wins over horizon here (the settings resolver checks matugen
    // first — note `derived_chrome_colors` orders them the other way).
    const both = resolveColors(.{
        .matugen_enabled = true,
        .matugen_ok = true,
        .matugen_accent = .{ 0.9, 0.9, 0.9 },
        .horizon_enabled = true,
        .horizon_ok = true,
        .horizon_accent = .{ 0.1, 0.1, 0.1 },
    });
    try t.expectEqual(ColorSource.matugen, both.source);
    try t.expectApproxEqAbs(@as(f32, 0.9), both.colors.accent_r, 1e-9);
    // Disabled flags fall through even with payloads present.
    const off = resolveColors(.{
        .matugen_enabled = false,
        .matugen_ok = true,
        .horizon_enabled = true,
        .horizon_ok = false,
    });
    try t.expectEqual(ColorSource.fallback, off.source);
}

test "settings-common: Theme vars accept a resolved palette" {
    const t = std.testing;
    const save_r = Theme.acc_r;
    const save_g = Theme.acc_g;
    const save_b = Theme.acc_b;
    defer {
        Theme.acc_r = save_r;
        Theme.acc_g = save_g;
        Theme.acc_b = save_b;
    }
    const res = resolveColors(.{ .matugen_enabled = true, .matugen_ok = true });
    Theme.acc_r = @as(f64, res.colors.accent_r);
    Theme.acc_g = @as(f64, res.colors.accent_g);
    Theme.acc_b = @as(f64, res.colors.accent_b);
    // The chrome palette is f32, so the widened value only matches 0.9 to
    // f32 precision (~1e-8); 1e-6 clears it without masking real drift.
    try t.expectApproxEqAbs(@as(f64, 0.9), Theme.acc_r, 1e-6);
}
