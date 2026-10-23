const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const text = @import("../../text/layout.zig");
const helpers = @import("../../desktop_shell/shared/cairo_helpers.zig");
const svg_icons = @import("svg_icons.zig");

// Settings drawing primitives — shared text/label/card/round-rect helpers
// plus the material-glyph draw path. Same geometry: the
// pango description uses `set_size(px * PANGO_SCALE)`,
// and y is the C++ "baseline-ish" anchor (translate to y - ph + 2).

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

// Material Symbols registration: the C++ hands the bundled TTF to
// fontconfig and clears pango's fc font-map cache. Both libraries are
// linked here, so the Zig settings app resolves glyphs even when the host
// has never installed the family.
extern fn FcConfigGetCurrent() ?*anyopaque;
extern fn FcConfigAppFontAddFile(cfg: ?*anyopaque, file: [*c]const u8) c_int;
extern fn FcConfigBuildFonts(cfg: ?*anyopaque) c_int;
extern fn pango_cairo_font_map_get_default() ?*anyopaque;
extern fn pango_fc_font_map_cache_clear(map: ?*anyopaque) void;

const kMaterialFamily = "Material Symbols Rounded";
const libc = @import("c_stdlib");
var g_font_registered = false;

// `liga` feature attribute — the C++ draw path enables the ligature feature
// explicitly (pango_attr_font_features_new("liga") over the whole layout);
// without it some Material Symbols ligatures resolve as literal text.
extern fn pango_attr_font_features_new(features: [*c]const u8) ?*text.PangoAttribute;

pub const Theme = @import("common.zig").Theme;

/// `material_symbols_ttf_path()` — candidate order: env
/// override, repo-relative, exe-relative, XDG data dirs.
/// Path join without an allocator handed in — the material font lookup runs
/// once, so the temp join allocates from the page allocator and copies back.
fn joinInto(buf: []u8, parts: []const []const u8) ?[]const u8 {
    const p = std.fs.path.join(std.heap.page_allocator, parts) catch return null;
    defer std.heap.page_allocator.free(p);
    if (p.len >= buf.len) return null;
    @memcpy(buf[0..p.len], p);
    return buf[0..p.len];
}

fn materialFontPath(buf: []u8) ?[]const u8 {
    const cand = [_][]const u8{
        "src/assets/fonts/MF/MaterialSymbolsRounded.ttf",
        "../src/assets/fonts/MF/MaterialSymbolsRounded.ttf",
        "../../src/assets/fonts/MF/MaterialSymbolsRounded.ttf",
        "/usr/share/event-horizon/assets/fonts/MF/MaterialSymbolsRounded.ttf",
        "/usr/local/share/event-horizon/assets/fonts/MF/MaterialSymbolsRounded.ttf",
    };
    if (libc.getenv("EH_ASSETS_DIR")) |d| {
        const dir = std.mem.span(d);
        if (joinInto(buf, &.{ dir, "fonts/MF/MaterialSymbolsRounded.ttf" })) |p| {
            if (fileExists(p)) return p;
        }
    }
    for (cand) |p| {
        if (fileExists(p)) return std.fmt.bufPrint(buf, "{s}", .{p}) catch null;
    }
    if (libc.getenv("HOME")) |hm| {
        const home = std.mem.span(hm);
        if (joinInto(buf, &.{ home, ".local/share/event-horizon/assets/fonts/MF/MaterialSymbolsRounded.ttf" })) |p| {
            if (fileExists(p)) return p;
        }
    }
    return null;
}

fn fileExists(p: []const u8) bool {
    var zbuf: [1024:0]u8 = @as([1024:0]u8, @splat(0));
    if (p.len >= zbuf.len) return false;
    @memcpy(zbuf[0..p.len], p);
    return std.os.linux.errno(std.os.linux.access(&zbuf, std.os.linux.R_OK)) == .SUCCESS;
}

/// `register_material_symbols_font_once()` + the pango cache clear.
pub fn registerMaterialFont() void {
    if (g_font_registered) return;
    g_font_registered = true;
    var buf: [1024]u8 = undefined;
    const path = materialFontPath(&buf) orelse return;
    const zpath: [:0]const u8 = std.fmt.bufPrintSentinel(buf[900..], "{s}", .{path}, 0) catch return;
    const cfg = FcConfigGetCurrent() orelse return;
    if (FcConfigAppFontAddFile(cfg, zpath) != 0) {
        _ = FcConfigBuildFonts(cfg);
        pango_fc_font_map_cache_clear(pango_cairo_font_map_get_default());
    }
}

/// `settings_show_text` — Inter, size in the C++ units, y is the C++
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
    var l = text.Layout.createForCairo(c);
    defer l.destroy();
    const desc = pango_font_description_new() orelse return;
    defer freeDesc(desc);
    pango_font_description_set_family(desc, "Inter");
    pango_font_description_set_size(desc, @intFromFloat(@round(size * pango_scale)));
    pango_font_description_set_weight(desc, weight);
    if (l.layout) |lo| pango_layout_set_font_description(lo, desc);
    l.setText(str);
    const s = l.pixelSize();
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
) struct { w: i32, h: i32 } {
    if (str.len == 0) return .{ .w = 0, .h = 0 };
    var l = text.Layout.createForCairo(cr);
    defer l.destroy();
    const desc = pango_font_description_new() orelse return .{ .w = 0, .h = 0 };
    defer freeDesc(desc);
    pango_font_description_set_family(desc, "Inter");
    pango_font_description_set_size(desc, @intFromFloat(@round(size * pango_scale)));
    pango_font_description_set_weight(desc, weight);
    if (l.layout) |lo| pango_layout_set_font_description(lo, desc);
    l.setText(str);
    const s = l.pixelSize();
    return .{ .w = s.w, .h = s.h };
}

/// Left-to-right pixel width of `showText` output (for the search caret).
pub fn textWidthPx(cr: ?*cairo.cairo_t, str: []const u8, size: f32, weight: c_uint) i32 {
    return textSizePx(cr, str, size, weight).w;
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
    var l = text.Layout.createForCairo(c);
    defer l.destroy();
    const desc = pango_font_description_new() orelse return;
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
    if (ellipsize) l.setEllipsize(text.ELLIPSIZE_END);
    cairo.cairo_save(c);
    cairo.cairo_translate(c, x, y);
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    l.show(c);
    cairo.cairo_restore(c);
}

/// `settings_show_text_w` — `showText` with a maximum width: the text is
/// ellipsised at the end instead of wrapping (the Bluetooth tab's status
/// and alias lines). Same C++ y anchor as `showText`.
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
    var l = text.Layout.createForCairo(c);
    defer l.destroy();
    const desc = pango_font_description_new() orelse return;
    defer freeDesc(desc);
    pango_font_description_set_family(desc, "Inter");
    pango_font_description_set_size(desc, @intFromFloat(@round(size * pango_scale)));
    pango_font_description_set_weight(desc, weight);
    if (l.layout) |lo| pango_layout_set_font_description(lo, desc);
    l.setText(str);
    if (max_w > 0.0) {
        l.setWidthUnits(@intFromFloat(@round(max_w * pango_scale)));
        l.setEllipsize(text.ELLIPSIZE_END);
    }
    const s = l.pixelSize();
    cairo.cairo_save(c);
    cairo.cairo_translate(c, x, y - @as(f64, @floatFromInt(s.h)) + 2.0);
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    l.show(c);
    cairo.cairo_restore(c);
}

/// Pixel width of Inter text measured on a throwaway 8x8 surface — for layout
/// passes that must size the widget picker without a live paint context (the
/// C++ `picker_text_width_px` does the same).
pub fn measureTextWidth(str: []const u8, size: f32, weight: c_uint) i32 {
    if (str.len == 0) return 0;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 8, 8);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    return textSizePx(cr, str, size, weight).w;
}

/// Wrapped line count of Inter text at `wrap_w` px on a throwaway surface (the
/// C++ `picker_wrapped_line_count`). Used to size the picker cards to the
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

/// `material_symbols_draw_glyph` — ligature centred on (cx, cy). The layout carries a `liga` feature attribute, and each ligature is
/// measured individually — if it measures like fallback *text* (far wider
/// than an icon), that one glyph substitutes a neutral dot instead of
/// leaking literal text over the row label.
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

/// Same as `glyph` but mirrored vertically — used for the Panel row icon,
/// which is the taskbar's `dock_to_bottom` upside down.
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
    // `dock_to_top` is not a ligature in Material Symbols Rounded — the
    // intended icon is `dock_to_bottom` mirrored, drawn flipped below.
    var flip = flip_y;
    var lig_buf: [32]u8 = undefined;
    const lig: []const u8 = if (std.mem.eql(u8, ligature, "dock_to_top")) blk: {
        @memcpy(lig_buf[0..14], "dock_to_bottom");
        flip = true;
        break :blk lig_buf[0..14];
    } else ligature;
    if (lig.len == 0) return;
    const c = cr orelse return;
    // Lucide SVG first: every glyph name the settings UI draws maps to a
    // vendored icon (see svg_icons.zig), so the font path below is only a
    // fallback for names outside the table.
    if (svg_icons.draw(c, lig, cx, cy, px, r, g, b, a, flip)) return;
    registerMaterialFont();
    var l = text.Layout.createForCairo(c);
    defer l.destroy();
    const desc = pango_font_description_new() orelse return;
    defer freeDesc(desc);
    pango_font_description_set_family(desc, kMaterialFamily);
    pango_font_description_set_weight(desc, text.WEIGHT_NORMAL);
    pango_font_description_set_absolute_size(desc, px * pango_scale);
    if (l.layout) |lo| {
        pango_layout_set_font_description(lo, desc);
        // Same liga feature request as material_glyph.cpp.
        const attrs = text.pango_attr_list_new();
        if (attrs) |al| {
            defer text.pango_attr_list_unref(al);
            if (pango_attr_font_features_new("liga")) |fea| {
                text.pango_attr_list_insert(al, fea);
                text.pango_layout_set_attributes(lo, al);
            }
        }
    }
    l.setText(lig);
    const s = l.pixelSize();
    // An icon ligature at px renders ~px wide; fallback text is far wider.
    if (s.w > @as(i32, @intFromFloat(px * 2.2))) {
        cairo.cairo_save(c);
        cairo.cairo_set_source_rgba(c, r, g, b, a * 0.7);
        cairo.cairo_arc(c, cx, cy, @max(2.0, px * 0.22), 0, std.math.pi * 2.0);
        cairo.cairo_fill(c);
        cairo.cairo_restore(c);
        return;
    }
    cairo.cairo_save(c);
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    cairo.cairo_translate(c, cx, cy);
    if (flip) cairo.cairo_scale(c, 1.0, -1.0);
    cairo.cairo_move_to(
        c,
        -@as(f64, @floatFromInt(s.w)) * 0.5,
        -@as(f64, @floatFromInt(s.h)) * 0.5,
    );
    l.show(c);
    cairo.cairo_restore(c);
}

/// Measures a ligature like the draw path does: true when it would render
/// as literal fallback text (invalid/missing name). Lets tests assert that
/// known-good names resolve and `dock_to_top` is caught before it leaks.
pub fn glyphMeasuresAsText(px: f64, ligature: []const u8, cr: ?*cairo.cairo_t) bool {
    registerMaterialFont();
    var l = text.Layout.createForCairo(cr);
    defer l.destroy();
    const desc = pango_font_description_new() orelse return true;
    defer freeDesc(desc);
    pango_font_description_set_family(desc, kMaterialFamily);
    pango_font_description_set_weight(desc, text.WEIGHT_NORMAL);
    pango_font_description_set_absolute_size(desc, px * pango_scale);
    if (l.layout) |lo| pango_layout_set_font_description(lo, desc);
    l.setText(ligature);
    const s = l.pixelSize();
    return s.w > @as(i32, @intFromFloat(px * 2.2));
}

pub fn roundRect(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, rad: f64) void {
    helpers.roundedRect(cr, x, y, w, h, rad);
}

/// `m3::Box` paint (glassy): soft drop shadow, flat fill, milky wash,
/// gradient inner rim (soft on top, bright along the bottom), faint outer
/// glow. Every glassy card and pill in settings goes through here, so the
/// constants match `box.hpp` verbatim — a gradient-shaded fill with a flat
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

/// Accent/white/text source helpers from settings_common.hpp (fallback
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
    // Valid ligatures measure like icons; the invalid `dock_to_top` is
    // caught per-glyph (it must never leak literal text over a label).
    try t.expect(!glyphMeasuresAsText(18, "search", cr));
    try t.expect(!glyphMeasuresAsText(18, "dock_to_bottom", cr));
    try t.expect(glyphMeasuresAsText(18, "dock_to_top", cr));
    glassBox(cr, 0, 0, 30, 30, 8, 0.2, 0.2, 0.3, 0.5);
    card(cr, 0, 32, 60, 30, 1.0);
    catLabel(cr, 0, 0, "DISPLAY");
    groupHeader(cr, 0, 0, 60, "Visibility");
    settingLabel(cr, 0, 20, "Show dock", "Adds the dock.");
    try t.expect(true);
}
