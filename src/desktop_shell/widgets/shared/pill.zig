//! Single place
//! dock widget pills come from.
//!
//! Every widget in `src/desktop_shell/widgets/` that renders as a dock slot
//! (battery, bluetooth, clock, media, weather, workspaces …) goes through
//! `paintPill`, so they all get the frosted treatment automatically. The
//! globals mirror the shared state, assigned
//! them from the pill colour and `slot_pill_opacity` before every slot.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const box_mod = @import("../../../m3/core/primitives/box.zig");
const helpers = @import("../../shared/cairo_helpers.zig");
const tokens = @import("../../../m3/tokens.zig");

pub const pill_height_mul: f64 = 1.0;

/// Style state, mutated by the dock before it paints a strip.
pub const Style = struct {
    opacity_scale: f64 = 1.0,
    pill_r: f64 = 1.0,
    pill_g: f64 = 1.0,
    pill_b: f64 = 1.0,
    hover_accent_r: f64 = 1.0,
    hover_accent_g: f64 = 1.0,
    hover_accent_b: f64 = 1.0,
    media_btn_r: f64 = 0.22,
    media_btn_g: f64 = 0.24,
    media_btn_b: f64 = 0.26,
    media_glyph_r: f64 = 1.0,
    media_glyph_g: f64 = 1.0,
    media_glyph_b: f64 = 1.0,
    media_on_accent_r: f64 = 0.10,
    media_on_accent_g: f64 = 0.10,
    media_on_accent_b: f64 = 0.10,
};

/// The process-wide style.
pub var style: Style = .{};

/// `corner_radius` — 22 % of the shorter side, never under 2 px.
pub fn cornerRadius(pill_h: f64, slot_w: f64) f64 {
    return @max(2.0, @min(pill_h, slot_w) * 0.22);
}

/// The `slot_pill_opacity` setting (0-100) as a fill alpha, straight: 0
/// paints nothing at all (the m3 box early-returns on a zero alpha, so the
/// drop shadow and the glass layers go with the fill) and 100 is fully
/// opaque. Both bars feed every slot pill they draw through this — the
/// launcher page's "Widget opacity" slider writes one value to both.
pub fn settingAlpha(pct: i32) f64 {
    return @as(f64, @floatFromInt(std.math.clamp(pct, 0, 100))) / 100.0;
}

/// `set_fill_for_state` — the state arguments are deliberately unused: the
/// pill fill does not change under hover or press, the accent wash does.
pub fn setFillForState(cr: ?*cairo.cairo_t, hovered: bool, pressed: bool) void {
    _ = hovered;
    _ = pressed;
    const c = cr orelse return;
    cairo.cairo_set_source_rgba(c, style.pill_r, style.pill_g, style.pill_b, style.opacity_scale);
}

/// `stroke_pill_after_fill_preserve` — a 1 px stroke in the fill colour over
/// the path the fill left preserved.
pub fn strokePillAfterFillPreserve(cr: ?*cairo.cairo_t, hovered: bool, pressed: bool) void {
    _ = hovered;
    _ = pressed;
    const c = cr orelse return;
    cairo.cairo_set_source_rgba(c, style.pill_r, style.pill_g, style.pill_b, style.opacity_scale);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);
}

/// `paint_glass_layers` — the flat frosted treatment laid over an existing
/// fill: a milky white wash clipped to the shape, a bottom-weighted rim
/// gradient, and a faint outer glow. `opacity` scales the highlights and
/// `outer_radius` overrides the computed corner radius (pass the pill's own
/// radius so the rim follows the fill exactly).
pub fn paintGlassLayers(
    c: ?*cairo.cairo_t,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    opacity: f64,
    outer_radius: f64,
) void {
    glassLayers(c, x, y, w, h, style.opacity_scale * opacity, outer_radius);
}

/// The same three layers with the opacity already resolved, so the explicit
/// pill below does not have to route its alpha through the process globals.
fn glassLayers(
    c: ?*cairo.cairo_t,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    op: f64,
    outer_radius: f64,
) void {
    const cr = c orelse return;
    const rad: f64 = if (outer_radius > 0) outer_radius else cornerRadius(h, w);
    // The frosted layers fade with the fill's opacity — but only by its
    // square root, so a low `slot_pill_opacity` still keeps its specular
    // edge instead of collapsing to a flat gray sticker. 0 still paints
    // nothing and 1 is unchanged.
    const gop: f64 = @sqrt(@min(@max(op, 0.0), 1.0));

    // Milky lift — faint white wash so the fill reads frosted, not dark.
    cairo.cairo_save(cr);
    helpers.pathRoundedRect(cr, x, y, w, h, rad);
    cairo.cairo_clip(cr);
    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.09 * gop);
    cairo.cairo_rectangle(cr, x, y, w, h);
    cairo.cairo_fill(cr);
    cairo.cairo_restore(cr);

    // Edge light — inner 1 px stroke, soft on top, bright along the bottom.
    cairo.cairo_save(cr);
    const rim = cairo.cairo_pattern_create_linear(0, y, 0, y + h);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 0.0, 1.0, 1.0, 1.0, 0.20 * gop);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 0.5, 1.0, 1.0, 1.0, 0.04 * gop);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 1.0, 1.0, 1.0, 1.0, 0.42 * gop);
    cairo.cairo_set_source(cr, rim);
    cairo.cairo_set_line_width(cr, 1.0);
    helpers.pathRoundedRect(cr, x + 1.0, y + 1.0, w - 2.0, h - 2.0, @max(0.0, rad - 1.0));
    cairo.cairo_stroke(cr);
    cairo.cairo_pattern_destroy(rim);
    cairo.cairo_restore(cr);

    // Faint outer glow so the edge lifts off the wallpaper.
    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.10 * gop);
    cairo.cairo_set_line_width(cr, 1.0);
    helpers.pathRoundedRect(cr, x + 0.5, y + 0.5, w - 1.0, h - 1.0, rad);
    cairo.cairo_stroke(cr);
}

/// `paint_pill` — the m3 box fill (which draws the drop shadow) plus the
/// glass layers, passing the pill's own radius so the two agree exactly.
pub fn paintPill(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64) void {
    const c = cr orelse return;
    const rad = cornerRadius(h, w);

    var b = box_mod.Box{};
    b.setColor(
        @floatCast(style.pill_r),
        @floatCast(style.pill_g),
        @floatCast(style.pill_b),
        @floatCast(style.opacity_scale),
    );
    b.setRadius(@floatCast(rad));
    b.setGeometry(@floatCast(x), @floatCast(y), @floatCast(w), @floatCast(h));
    b.paint(c);

    paintGlassLayers(c, x, y, w, h, 1.0, rad);
}

/// The same `paint_pill` treatment with the fill passed in rather than read
/// from the process-wide style. The dock hands the control-center and pear
/// slots their pill colour as an argument each frame, but the shape they
/// paint has to be *this* one — drop shadow plus the frosted layers — so a
/// status pill sits in the bar with the same shadow and frosted layers as
/// the widget pills beside it.
pub fn paintPillColored(
    cr: ?*cairo.cairo_t,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    rgb: tokens.Rgb,
    alpha: f64,
) void {
    const c = cr orelse return;
    if (w <= 1.0 or h <= 1.0) return;
    const rad = cornerRadius(h, w);

    var b = box_mod.Box{};
    b.setColor(@floatCast(rgb.r), @floatCast(rgb.g), @floatCast(rgb.b), @floatCast(alpha));
    b.setRadius(@floatCast(rad));
    b.setGeometry(@floatCast(x), @floatCast(y), @floatCast(w), @floatCast(h));
    b.paint(c);

    glassLayers(c, x, y, w, h, alpha, rad);
}

/// `pill_clip_path` — the same rounded rect as a path, for clipping.
pub fn pillClipPath(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64) void {
    const c = cr orelse return;
    const rad = cornerRadius(h, w);
    helpers.pathRoundedRect(c, x, y, w, h, rad);
}

test "slot-pill: corner radius is 22% of the short side with a 2 px floor" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f64, 2.0), cornerRadius(8.0, 8.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 9.68), cornerRadius(44.0, 44.0), 1e-9);
    // The floor wins on a tall, narrow slot.
    try t.expectApproxEqAbs(@as(f64, 2.0), cornerRadius(44.0, 6.0), 1e-9);
}

test "slot-pill: setting alpha is straight, not halved" {
    const t = std.testing;
    // Endpoints: 0 paints nothing, 100 is fully opaque. 61 is the value the
    // live config carries — there must be no extra scale between slider and
    // fill (the taskbar once carried an x 0.5 here, capping 100% at 50%).
    try t.expectApproxEqAbs(@as(f64, 0.0), settingAlpha(0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 0.61), settingAlpha(61), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 1.0), settingAlpha(100), 1e-9);
    // Out-of-range values clamp at the ends.
    try t.expectApproxEqAbs(@as(f64, 0.0), settingAlpha(-5), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 1.0), settingAlpha(140), 1e-9);
}

test "slot-pill: fill, stroke, pill and glass all draw" {
    const t = std.testing;
    style.opacity_scale = 0.5;
    defer style = .{};

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 160, 60);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    paintPill(cr, 8, 8, 44, 44);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // The explicit-fill pill the control-center and pear slots paint: same
    // shadow + glass treatment, colour passed in rather than read globally.
    paintPillColored(cr, 60, 8, 44, 44, .{ .r = 0.2, .g = 0.2, .b = 0.2 }, 0.5);
    paintPillColored(null, 0, 0, 0, 0, .{ .r = 0.0, .g = 0.0, .b = 0.0 }, 0.0);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    cairo.cairo_rectangle(cr, 60, 8, 44, 44);
    setFillForState(cr, true, false);
    cairo.cairo_fill_preserve(cr);
    strokePillAfterFillPreserve(cr, true, false);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    paintGlassLayers(cr, 110, 8, 44, 44, 1.0, -1.0);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    pillClipPath(cr, 8, 8, 44, 44);
    cairo.cairo_clip(cr);
    cairo.cairo_paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    paintPill(null, 0, 0, 10, 10);
}
