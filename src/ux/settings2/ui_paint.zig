const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const text = @import("../../text/layout.zig");
const helpers = @import("../../desktop_shell/shared/cairo_helpers.zig");
const svg_icons = @import("svg_icons.zig");

// Settings drawing primitives — shared text/label/card/round-rect helpers
// plus the material-glyph draw path. Same geometry: the
// pango description uses `set_size(px * PANGO_SCALE)`,
// and y is the "baseline-ish" anchor (translate to y - ph + 2).

const pango_scale: f64 = 1024.0;

// `text/layout.zig` keeps its font-description externs private; the settings
// helper needs family + size + weight on one description, which from_string
// cannot express (it parses points).
extern fn pango_font_description_new() ?*text.PangoFontDescription;
extern fn pango_font_description_set_family(desc: ?*text.PangoFontDescription, family: [*c]const u8) void;
extern fn pango_font_description_set_size(desc: ?*text.PangoFontDescription, size: c_int) void;
extern fn pango_font_description_set_weight(desc: ?*text.PangoFontDescription, weight: c_uint) void;
extern fn pango_font_description_set_absolute_size(desc: ?*text.PangoFontDescription, size: f64) void;
extern fn pango_font_description_free(desc: ?*text.PangoFontDescription) void;
extern fn pango_layout_set_font_description(layout: ?*text.PangoLayout, desc: ?*const text.PangoFontDescription) void;

// Glyphs are vendored Lucide SVGs (svg_icons.zig); the Material Symbols
// font is no longer registered or drawn anywhere in this app. The pango
// externs above stay for the Inter text helpers.

pub const Theme = @import("common.zig").Theme;

// ── shaped-text cache ───────────────────────────────────────────────────────
//
// The shell repaints the same strings every frame, and every call used to
// build a fresh PangoContext, font description and layout — by far the
// hottest cost in a frame (the audio center holds itself to a 1 ms budget).
// Layouts are kept per (size, weight, width, wrap, ellipsize, text) and
// re-shaped only when the key changes, so a steady frame is just
// `pango_cairo_show_layout` into cairo's glyph cache.
//
// Single UI thread only, like the rest of the painters.

const text_cache_slots = 256;
/// Longest string the cache stores; longer ones are truncated here, matching
/// the 1023-byte truncation the old one-layout-per-call path applied.
const text_cache_max_len = 1024;

const CachedText = struct {
    layout: ?*text.PangoLayout = null,
    size: f32 = 0,
    weight: c_uint = 0,
    width: c_int = -1,
    wrap: c_int = -1,
    ellipsize: c_int = -1,
    len: u32 = 0,
    stamp: u64 = 0,
    /// Pixel size of the shaped layout, measured once. -1 = not measured yet
    /// (a re-shaped slot forgets, so the next measure is against the new text).
    sz_w: i32 = -1,
    sz_h: i32 = -1,
    buf: [text_cache_max_len]u8 = undefined,
};

var text_cache: [text_cache_slots]CachedText = .{CachedText{}} ** text_cache_slots;
var text_cache_stamp: u64 = 0;
/// CTM scale the cached layouts were built under; changing display scale
/// invalidates every entry (a fresh miss re-applies the whole key).
var text_cache_scale: f64 = 0;

fn textCacheScale(cr: *cairo.cairo_t) f64 {
    var m: cairo.cairo_matrix_t = undefined;
    cairo.cairo_get_matrix(cr, &m);
    return m.xx;
}

fn cachedLayoutMatches(e: *const CachedText, str: []const u8, size: f32, weight: c_uint, width: c_int, wrap: c_int, ellipsize: c_int) bool {
    return e.layout != null and
        e.size == size and
        e.weight == weight and
        e.width == width and
        e.wrap == wrap and
        e.ellipsize == ellipsize and
        e.len == str.len and
        std.mem.eql(u8, e.buf[0..str.len], str);
}

/// A shaped layout for `str` under the given key, or null when the string is
/// too long for the cache (callers fall back to nothing, exactly as they would
/// have anyway). On a miss the least-recently-used slot is re-shaped — font
/// description, text, width, wrap and ellipsize are all re-applied, so no
/// configuration can leak from the previous owner. Returns the cache entry, so
/// callers can also read the memoized pixel size without re-measuring.
fn cachedLayout(
    cr: ?*cairo.cairo_t,
    str: []const u8,
    size: f32,
    weight: c_uint,
    width: c_int,
    wrap: c_int,
    ellipsize: c_int,
) ?*CachedText {
    const c = cr orelse return null;
    if (str.len == 0) return null;
    const s = if (str.len > text_cache_max_len) str[0..text_cache_max_len] else str;

    const scale = textCacheScale(c);
    if (scale != text_cache_scale) {
        text_cache_scale = scale;
        for (&text_cache) |*e| e.len = 0;
    }

    text_cache_stamp += 1;
    var victim: *CachedText = &text_cache[0];
    for (&text_cache) |*e| {
        if (cachedLayoutMatches(e, s, size, weight, width, wrap, ellipsize)) {
            e.stamp = text_cache_stamp;
            return e;
        }
        if (e.layout == null) {
            victim = e;
            break;
        }
        if (e.stamp < victim.stamp) victim = e;
    }

    if (victim.layout == null) {
        victim.layout = text.pango_cairo_create_layout(c) orelse return null;
    }
    const lo = victim.layout.?;
    const desc = pango_font_description_new() orelse return null;
    defer freeDesc(desc);
    pango_font_description_set_family(desc, "Inter");
    pango_font_description_set_size(desc, @intFromFloat(@round(size * pango_scale)));
    pango_font_description_set_weight(desc, weight);
    pango_layout_set_font_description(lo, desc);
    text.pango_layout_set_text(lo, s.ptr, @intCast(s.len));
    text.pango_layout_set_width(lo, width);
    text.pango_layout_set_wrap(lo, wrap);
    text.pango_layout_set_ellipsize(lo, ellipsize);

    @memcpy(victim.buf[0..s.len], s);
    victim.len = @intCast(s.len);
    victim.size = size;
    victim.weight = weight;
    victim.width = width;
    victim.wrap = wrap;
    victim.ellipsize = ellipsize;
    victim.stamp = text_cache_stamp;
    victim.sz_w = -1;
    victim.sz_h = -1;
    return victim;
}

/// Pixel size of a shaped run, in whole pixels.
const SizePx = struct { w: i32, h: i32 };

/// Memoized pixel size of a cache entry's layout: measuring is a Pango call
/// and callers re-measure the same strings every paint (the rail labels are
/// the worst: five `textWidthPx` per frame just to centre them).
fn cachedPixelSize(e: *CachedText) SizePx {
    if (e.sz_w < 0 or e.sz_h < 0) {
        var l = text.Layout{ .layout = e.layout.? };
        const px = l.pixelSize();
        e.sz_w = px.w;
        e.sz_h = px.h;
    }
    return .{ .w = e.sz_w, .h = e.sz_h };
}

/// `settings_show_text` — Inter, size in pixels, y is the
/// anchor. Weight is a raw Pango weight (400/700...).
pub fn showText(
    cr: ?*cairo.cairo_t,
    x: f64,
    y: f64,
    str: []const u8,
    size: f32,
    weight: c_uint,
    r: f64,
    g: f64,
    b: f64,
    a: f64,
) void {
    if (str.len == 0) return;
    const c = cr orelse return;
    const e = cachedLayout(c, str, size, weight, -1, text.WRAP_WORD, text.ELLIPSIZE_NONE) orelse return;
    var l = text.Layout{ .layout = e.layout.? };
    const s = cachedPixelSize(e);
    cairo.cairo_save(c);
    cairo.cairo_translate(c, x, y - @as(f64, @floatFromInt(s.h)) + 2.0);
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    l.show(c);
    cairo.cairo_restore(c);
}

/// Pixel size of `showText` output (width and height, for the value pill).
pub fn textSizePx(
    cr: ?*cairo.cairo_t,
    str: []const u8,
    size: f32,
    weight: c_uint,
) SizePx {
    if (str.len == 0) return .{ .w = 0, .h = 0 };
    const c = cr orelse return .{ .w = 0, .h = 0 };
    const e = cachedLayout(c, str, size, weight, -1, text.WRAP_WORD, text.ELLIPSIZE_NONE) orelse return .{ .w = 0, .h = 0 };
    return cachedPixelSize(e);
}

/// Left-to-right pixel width of `showText` output (for the search caret).
pub fn textWidthPx(cr: ?*cairo.cairo_t, str: []const u8, size: f32, weight: c_uint) i32 {
    return textSizePx(cr, str, size, weight).w;
}

/// A shaped run's logical line box (`w`/`h` — what `showText` anchors
/// against) plus its ink extents: the glyph box the eye actually sees.
pub const MetricsPx = struct {
    w: i32,
    h: i32,
    ink_x: i32,
    ink_y: i32,
    ink_w: i32,
    ink_h: i32,
};

/// `textSizePx` plus ink extents, keyed exactly like `showTextW` when
/// `max_w > 0` so the metrics describe the layout that will be painted.
///
/// Centring callers should anchor on the ink, not the line box: the box
/// carries font leading (~23px at 12px Inter) that depends on the string,
/// so fixed baselines drift between rows and chips even though the run
/// itself is stable. Both measurements are taken under an identity
/// transform — a previous `pango_cairo_show_layout` on a scaled context
/// leaves device metrics behind otherwise — and the memoised size is
/// refreshed from that same pass, so the `h` returned here is the `h`
/// `showText` will use to place the run.
pub fn textMetricsPx(
    cr: ?*cairo.cairo_t,
    str: []const u8,
    size: f32,
    weight: c_uint,
    max_w: f64,
) MetricsPx {
    const zero = MetricsPx{ .w = 0, .h = 0, .ink_x = 0, .ink_y = 0, .ink_w = 0, .ink_h = 0 };
    if (str.len == 0) return zero;
    const c = cr orelse return zero;
    const width: c_int = if (max_w > 0.0) @intFromFloat(@round(max_w * pango_scale)) else -1;
    const ell: c_int = if (max_w > 0.0) text.ELLIPSIZE_END else text.ELLIPSIZE_NONE;
    const e = cachedLayout(c, str, size, weight, width, text.WRAP_WORD, ell) orelse return zero;
    var l = text.Layout{ .layout = e.layout.? };
    cairo.cairo_save(c);
    cairo.cairo_identity_matrix(c);
    l.update(c);
    const px = l.pixelSize();
    const ink = l.pixelInk();
    cairo.cairo_restore(c);
    e.sz_w = px.w;
    e.sz_h = px.h;
    return .{
        .w = px.w,
        .h = px.h,
        .ink_x = ink.x,
        .ink_y = ink.y,
        .ink_w = ink.width,
        .ink_h = ink.height,
    };
}

/// `picker_show_wrapped` — word-wrapped Inter text drawn top-aligned at (x, y),
/// wrapped to `wrap_w` px and ellipsised at the end when it overflows. The
/// add-widget picker cards use it for multi-line titles and descriptions.
/// Unlike `showText`, y is the *top* of the block.
pub fn showWrapped(
    cr: ?*cairo.cairo_t,
    x: f64,
    y: f64,
    str: []const u8,
    size: f32,
    weight: c_uint,
    r: f64,
    g: f64,
    b: f64,
    a: f64,
    wrap_w: i32,
    ellipsize: bool,
) void {
    if (str.len == 0) return;
    const c = cr orelse return;
    const width: c_int = if (wrap_w > 0) wrap_w * 1024 else -1;
    const wrap: c_int = if (wrap_w > 0) text.WRAP_WORD_CHAR else text.WRAP_WORD;
    const ell: c_int = if (ellipsize) text.ELLIPSIZE_END else text.ELLIPSIZE_NONE;
    const e = cachedLayout(c, str, size, weight, width, wrap, ell) orelse return;
    var l = text.Layout{ .layout = e.layout.? };
    cairo.cairo_save(c);
    cairo.cairo_translate(c, x, y);
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    l.show(c);
    cairo.cairo_restore(c);
}

/// `settings_show_text_w` — `showText` with a maximum width: the text is
/// ellipsised at the end instead of wrapping (the Bluetooth tab's status
/// and alias lines). Same y anchor as `showText`.
pub fn showTextW(
    cr: ?*cairo.cairo_t,
    x: f64,
    y: f64,
    str: []const u8,
    size: f32,
    weight: c_uint,
    max_w: f64,
    r: f64,
    g: f64,
    b: f64,
    a: f64,
) void {
    if (str.len == 0) return;
    const c = cr orelse return;
    const width: c_int = if (max_w > 0.0) @intFromFloat(@round(max_w * pango_scale)) else -1;
    const ell: c_int = if (max_w > 0.0) text.ELLIPSIZE_END else text.ELLIPSIZE_NONE;
    const e = cachedLayout(c, str, size, weight, width, text.WRAP_WORD, ell) orelse return;
    var l = text.Layout{ .layout = e.layout.? };
    const s = cachedPixelSize(e);
    cairo.cairo_save(c);
    cairo.cairo_translate(c, x, y - @as(f64, @floatFromInt(s.h)) + 2.0);
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    l.show(c);
    cairo.cairo_restore(c);
}

/// Pixel width of Inter text measured on a throwaway 8x8 surface — for layout
/// passes that must size the widget picker without a live paint context.
pub fn measureTextWidth(str: []const u8, size: f32, weight: c_uint) i32 {
    if (str.len == 0) return 0;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 8, 8);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    return textSizePx(cr, str, size, weight).w;
}

/// Wrapped line count of Inter text at `wrap_w` px on a throwaway surface.
/// Used to size the picker cards to the
/// longest description.
pub fn measureWrappedLines(str: []const u8, size: f32, weight: c_uint, wrap_w: i32) i32 {
    if (str.len == 0) return 1;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 8, 8);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    var l = text.Layout.createForCairo(cr);
    defer l.destroy();
    const desc = pango_font_description_new() orelse return 1;
    defer freeDesc(desc);
    pango_font_description_set_family(desc, "Inter");
    pango_font_description_set_size(desc, @intFromFloat(@round(size * pango_scale)));
    pango_font_description_set_weight(desc, weight);
    if (l.layout) |lo| pango_layout_set_font_description(lo, desc);
    l.setText(str);
    if (wrap_w > 0) {
        l.setWidthUnits(wrap_w * 1024);
        l.setWrap(text.WRAP_WORD_CHAR);
    }
    const nl = l.lineCount();
    return if (nl < 1) 1 else nl;
}

fn freeDesc(desc: ?*text.PangoFontDescription) void {
    pango_font_description_free(desc);
}

/// `material_symbols_draw_glyph` — icon centred on (cx, cy). Every name
/// resolves to a vendored Lucide SVG (svg_icons.zig); a name with no mapping
/// paints nothing rather than leaking literal text over a row label.
pub fn glyph(
    cr: ?*cairo.cairo_t,
    cx: f64,
    cy: f64,
    px: f64,
    ligature: []const u8,
    r: f64,
    g: f64,
    b: f64,
    a: f64,
) void {
    drawGlyphInner(cr, cx, cy, px, ligature, r, g, b, a, false);
}

/// Same as `glyph` but usable for an icon that should mirror vertically —
/// e.g. the Panel row draws `dock_to_bottom` flipped into the taskbar's
/// top-edge shape.
pub fn glyphFlippedY(
    cr: ?*cairo.cairo_t,
    cx: f64,
    cy: f64,
    px: f64,
    ligature: []const u8,
    r: f64,
    g: f64,
    b: f64,
    a: f64,
) void {
    drawGlyphInner(cr, cx, cy, px, ligature, r, g, b, a, true);
}

fn drawGlyphInner(
    cr: ?*cairo.cairo_t,
    cx: f64,
    cy: f64,
    px: f64,
    ligature: []const u8,
    r: f64,
    g: f64,
    b: f64,
    a: f64,
    flip_y: bool,
) void {
    if (ligature.len == 0) return;
    // Every glyph name the settings UI draws maps to a vendored Lucide icon
    // (see svg_icons.zig); a miss paints nothing.
    _ = svg_icons.draw(cr, ligature, cx, cy, px, r, g, b, a, flip_y);
}

/// True when a name has no Lucide mapping and would therefore draw nothing.
/// Lets tests assert that every name the UI asks for resolves.
pub fn glyphMeasuresAsText(px: f64, ligature: []const u8, cr: ?*cairo.cairo_t) bool {
    _ = px;
    _ = cr;
    if (ligature.len == 0) return true;
    return svg_icons.lucideName(ligature) == null;
}

pub fn roundRect(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, rad: f64) void {
    helpers.roundedRect(cr, x, y, w, h, rad);
}

/// `m3::Box` paint (glassy): soft drop shadow, flat fill, milky wash,
/// gradient inner rim (soft on top, bright along the bottom), faint outer
/// glow. Every glassy card and pill in settings goes through here, so the
/// constants match — a gradient-shaded fill with a flat
/// hairline is a different look (flatter, darker, no frost).
pub fn glassBox(
    cr: ?*cairo.cairo_t,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    rad: f64,
    r: f64,
    g: f64,
    b: f64,
    a: f64,
) void {
    const c = cr orelse return;
    if (w <= 0 or h <= 0 or a <= 0.001) return;
    cairo.cairo_save(c);
    cairo.cairo_translate(c, x, y);
    // Soft drop shadow (Hyprland handles blur; this offset fill reads as lift).
    helpers.pathRoundedRect(c, 0, 2.0, w, h, rad);
    cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.22);
    cairo.cairo_fill(c);
    // Flat fill.
    helpers.pathRoundedRect(c, 0, 0, w, h, rad);
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    cairo.cairo_fill(c);
    const op = a;
    // Milky lift — faint white wash so the fill reads frosted, not dark.
    cairo.cairo_save(c);
    helpers.pathRoundedRect(c, 0, 0, w, h, rad);
    cairo.cairo_clip(c);
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.07 * op);
    cairo.cairo_rectangle(c, 0, 0, w, h);
    cairo.cairo_fill(c);
    cairo.cairo_restore(c);
    // Edge light — inner 1px stroke, soft on top, bright along the bottom.
    const rim = cairo.cairo_pattern_create_linear(0, 0, 0, h);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 0.0, 1.0, 1.0, 1.0, 0.12 * op);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 0.5, 1.0, 1.0, 1.0, 0.05 * op);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 1.0, 1.0, 1.0, 1.0, 0.42 * op);
    cairo.cairo_set_source(c, rim);
    cairo.cairo_set_line_width(c, 1.0);
    helpers.pathRoundedRect(c, 1.0, 1.0, w - 2.0, h - 2.0, rad - 1.0);
    cairo.cairo_stroke(c);
    cairo.cairo_pattern_destroy(rim);
    // Faint outer glow so the edge lifts off the wallpaper.
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.08 * op);
    cairo.cairo_set_line_width(c, 1.0);
    helpers.pathRoundedRect(c, 0.5, 0.5, w - 1.0, h - 1.0, rad);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);
}

/// `settings_card` — card surface (Bg * 0.35, alpha 0.78 * glassOv).
pub fn card(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, glass_ov: f64) void {
    const r = Theme.bg_r * 0.35;
    const g = Theme.bg_g * 0.35;
    const b = Theme.bg_b * 0.35;
    glassBox(cr, x, y, w, h, @import("common.zig").card_radius, r, g, b, 0.78 * glass_ov);
}

/// `settings_cat_label` — the small dim label above a card group.
pub fn catLabel(cr: ?*cairo.cairo_t, x: f64, y: f64, str: []const u8) void {
    if (str.len == 0) return;
    showText(cr, x, y, str, 10, text.WEIGHT_NORMAL, Theme.text_r, Theme.text_g, Theme.text_b, 0.42);
}

/// `settings_group_header` — 32px bar, bold 12px text at 0.60 alpha.
pub fn groupHeader(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, str: []const u8) void {
    const c = cr orelse return;
    glassBox(c, x, y, w, 32, 6, Theme.bg_r, Theme.bg_g, Theme.bg_b, 0.10);
    if (str.len > 0) {
        showText(c, x + 12, y + 20, str, 12, 700, Theme.text_r, Theme.text_g, Theme.text_b, 0.60);
    }
}

/// `settings_label` — 15px title with an optional 11px description.
pub fn settingLabel(cr: ?*cairo.cairo_t, x: f64, title_y: f64, title: []const u8, desc: []const u8) void {
    showText(cr, x, title_y, title, 15, 400, Theme.text_r, Theme.text_g, Theme.text_b, 0.93);
    if (desc.len > 0) {
        showText(cr, x, title_y + 16, desc, 11, 400, Theme.text_r, Theme.text_g, Theme.text_b, 0.46);
    }
}

/// `settings_switch` — pill track with a sliding knob (m3 Switch, S size
/// 52x26 as every settings toggle uses).
pub fn paintSwitch(cr: ?*cairo.cairo_t, x: i32, y: i32, w: i32, h: i32, on: bool) void {
    const c = cr orelse return;
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    const wf: f64 = @floatFromInt(w);
    const hf: f64 = @floatFromInt(h);
    if (on) {
        glassBox(c, xf, yf, wf, hf, hf / 2.0, Theme.acc_r, Theme.acc_g, Theme.acc_b, 1.0);
    } else {
        glassBox(c, xf, yf, wf, hf, hf / 2.0, 1, 1, 1, 0.06);
        cairo.cairo_save(c);
        roundRect(c, xf + 0.5, yf + 0.5, wf - 1.0, hf - 1.0, hf / 2.0 - 0.5);
        cairo.cairo_set_line_width(c, 1.4);
        cairo.cairo_set_source_rgba(c, Theme.outline_r, Theme.outline_g, Theme.outline_b, 0.8);
        cairo.cairo_stroke(c);
        cairo.cairo_restore(c);
    }
    const knob_r: f64 = if (on) hf * 0.42 else hf * 0.34;
    const kx = if (on) xf + wf - hf * 0.5 else xf + hf * 0.5;
    glassBox(c, kx - knob_r, yf + hf / 2.0 - knob_r, knob_r * 2, knob_r * 2, knob_r, 1, 1, 1, 1.0);
}

/// Outlined pill button (m3 Button Style::Outlined, Size::XS): dark
/// default-surface body, accent state layer on hover, full-strength 1px
/// outline, 12px/500 accent label over a soft black offset pass. The
/// Bluetooth tab's Scan/Forget/Connect pills (and the tabs that carry
/// their own copies) draw through here so the hover/disabled response
/// stays identical everywhere.
pub fn paintBtn(
    cr: ?*cairo.cairo_t,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    label: []const u8,
    hovered: bool,
) void {
    btnBody(cr, x, y, w, h, label, hovered, false);
}

/// Same button with `setEnabled(false)`: no hover response, dimmer label.
pub fn paintBtnDisabled(
    cr: ?*cairo.cairo_t,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    label: []const u8,
) void {
    btnBody(cr, x, y, w, h, label, false, true);
}

fn btnBody(
    cr: ?*cairo.cairo_t,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    label: []const u8,
    hovered: bool,
    disabled: bool,
) void {
    const c = cr orelse return;
    if (w <= 0 or h <= 0) return;
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    const wf: f64 = @floatFromInt(w);
    const hf: f64 = @floatFromInt(h);
    const rad = @min(wf, hf) * 0.5;
    const hover = hovered and !disabled;
    // m3 Outlined container parity: the dark default-surface backing (the
    // callers never override it), an accent state layer on hover, and a
    // full-strength 1px outline — not the fainter custom values.
    glassBox(c, xf, yf, wf, hf, rad, 0.102, 0.075, 0.188, if (disabled) 0.06 else 0.08);
    if (hover) glassBox(c, xf, yf, wf, hf, rad, Theme.acc_r, Theme.acc_g, Theme.acc_b, 0.08);
    cairo.cairo_save(c);
    roundRect(c, xf + 0.5, yf + 0.5, wf - 1.0, hf - 1.0, @max(0.5, rad - 0.5));
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_set_source_rgba(
        c,
        Theme.outline_r,
        Theme.outline_g,
        Theme.outline_b,
        if (disabled) 0.12 else 1.0,
    );
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);

    const font_px: f32 = 12;
    // m3 label centering: measure once, then pin the layout top at
    // (h - lh)/2. showText anchors its top at (y - ph + 2), so passing
    // y = top + ph - 2 lands the text exactly there. (The old
    // `+ font_px * 0.36` fudge assumed a 15px line box; Pango reports 23,
    // which parked the ink ~5px high.)
    const ts = textSizePx(c, label, font_px, 500);
    const tw_f: f64 = @floatFromInt(ts.w);
    const th_f: f64 = @floatFromInt(ts.h);
    const lx = xf + (wf - tw_f) / 2.0;
    const top = yf + (hf - th_f) / 2.0;
    const fg_a: f64 = if (disabled) 0.38 else 1.0;
    // m3 label depth: a soft black offset pass, then the accent label.
    showText(c, lx + 1.0, top + th_f - 2.0 + 1.0, label, font_px, 500, 0, 0, 0, fg_a * 0.35);
    showText(
        c,
        lx,
        top + th_f - 2.0,
        label,
        font_px,
        500,
        Theme.acc_r,
        Theme.acc_g,
        Theme.acc_b,
        fg_a,
    );
}

/// Accent/white/text source helpers (fallback
/// theme only — matugen inputs arrive through common.resolveColors).
pub fn srcAccent(a: f64) void {
    _ = a;
}

test "settings-ui-paint: text width and glyph probe are finite" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 64, 64);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    const w = textWidthPx(cr, "Search settings", 13, 400);
    try t.expect(w > 0);
    showText(cr, 0, 20, "Dock", 14, 700, 1, 1, 1, 1);
    glyph(cr, 20, 20, 18, "search", 1, 1, 1, 1);
    // Every name the UI draws is mapped; an unmapped name would be caught
    // here because it would draw nothing.
    try t.expect(!glyphMeasuresAsText(18, "search", cr));
    try t.expect(!glyphMeasuresAsText(18, "dock_to_bottom", cr));
    try t.expect(!glyphMeasuresAsText(18, "dock_to_top", cr));
    try t.expect(glyphMeasuresAsText(18, "definitely-not-a-glyph", cr));
    glassBox(cr, 0, 0, 30, 30, 8, 0.2, 0.2, 0.3, 0.5);
    card(cr, 0, 32, 60, 30, 1.0);
    catLabel(cr, 0, 0, "DISPLAY");
    groupHeader(cr, 0, 0, 60, "Visibility");
    settingLabel(cr, 0, 20, "Show dock", "Adds the dock.");
    try t.expect(true);
}
