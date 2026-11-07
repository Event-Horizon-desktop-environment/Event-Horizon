//! Animation leaves (Zoolander `set_animation_leaf`).
//!
//! One compact row per transition: label, the easing and style summary, a
//! small curve thumbnail, the enable switch and a chevron. Opening a row
//! reveals the leaf editor in place — duration with a Default reset, an
//! easing segmented control, a draggable cubic-Bézier curve editor with
//! presets and a live preview strip, the style chips and the travel
//! distance.
//!
//! This is a bespoke subview rather than a declarative card: the reference
//! behaviour (one expanded row at a time, a draggable curve) needs state the
//! row table cannot express. Paint, hit-test and heights all live here so
//! they cannot drift apart; `ui_content` only forwards the pointer and the
//! placement rect.

const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const fields = @import("fields.zig");
const data = @import("zoolander_data.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;

pub const leaf_count: usize = 9;

const Leaf = struct {
    key: []const u8,
    label: []const u8,
    enabled: fields.Field,
    duration: fields.Field,
    easing: fields.Field,
    style: fields.Field,
    percent: fields.Field,
};

/// Mirrors the schema's `set_animation_leaf` leaf order. Kept explicit so a
/// future leaf cannot silently shift the curve state indices.
pub const leaves = [_]Leaf{
    .{ .key = "windows_in", .label = "Windows in", .enabled = .zool_anim_leaf_windows_in_enabled, .duration = .zool_anim_leaf_windows_in_duration, .easing = .zool_anim_leaf_windows_in_easing, .style = .zool_anim_leaf_windows_in_style, .percent = .zool_anim_leaf_windows_in_percent },
    .{ .key = "windows_out", .label = "Windows out", .enabled = .zool_anim_leaf_windows_out_enabled, .duration = .zool_anim_leaf_windows_out_duration, .easing = .zool_anim_leaf_windows_out_easing, .style = .zool_anim_leaf_windows_out_style, .percent = .zool_anim_leaf_windows_out_percent },
    .{ .key = "windows_move", .label = "Windows move", .enabled = .zool_anim_leaf_windows_move_enabled, .duration = .zool_anim_leaf_windows_move_duration, .easing = .zool_anim_leaf_windows_move_easing, .style = .zool_anim_leaf_windows_move_style, .percent = .zool_anim_leaf_windows_move_percent },
    .{ .key = "fade", .label = "Fade", .enabled = .zool_anim_leaf_fade_enabled, .duration = .zool_anim_leaf_fade_duration, .easing = .zool_anim_leaf_fade_easing, .style = .zool_anim_leaf_fade_style, .percent = .zool_anim_leaf_fade_percent },
    .{ .key = "layers", .label = "Layers", .enabled = .zool_anim_leaf_layers_enabled, .duration = .zool_anim_leaf_layers_duration, .easing = .zool_anim_leaf_layers_easing, .style = .zool_anim_leaf_layers_style, .percent = .zool_anim_leaf_layers_percent },
    .{ .key = "workspaces", .label = "Workspaces", .enabled = .zool_anim_leaf_workspaces_enabled, .duration = .zool_anim_leaf_workspaces_duration, .easing = .zool_anim_leaf_workspaces_easing, .style = .zool_anim_leaf_workspaces_style, .percent = .zool_anim_leaf_workspaces_percent },
    .{ .key = "camera", .label = "Camera", .enabled = .zool_anim_leaf_camera_enabled, .duration = .zool_anim_leaf_camera_duration, .easing = .zool_anim_leaf_camera_easing, .style = .zool_anim_leaf_camera_style, .percent = .zool_anim_leaf_camera_percent },
    .{ .key = "layout", .label = "Layout", .enabled = .zool_anim_leaf_layout_enabled, .duration = .zool_anim_leaf_layout_duration, .easing = .zool_anim_leaf_layout_easing, .style = .zool_anim_leaf_layout_style, .percent = .zool_anim_leaf_layout_percent },
    .{ .key = "windows_minimize", .label = "Windows minimize", .enabled = .zool_anim_leaf_windows_minimize_enabled, .duration = .zool_anim_leaf_windows_minimize_duration, .easing = .zool_anim_leaf_windows_minimize_easing, .style = .zool_anim_leaf_windows_minimize_style, .percent = .zool_anim_leaf_windows_minimize_percent },
};

const easing_values = [_][]const u8{ "linear", "ease_out_cubic", "ease_in_out_cubic" };
const easing_labels = [_][]const u8{ "Linear", "Ease out cubic", "Ease in out cubic" };
const style_values = [_][]const u8{ "slide", "popin", "slide_left", "slide_right", "slide_top", "slide_bottom", "fade", "minimize" };
const style_labels = [_][]const u8{ "Slide", "Popin", "Slide left", "Slide right", "Slide top", "Slide bottom", "Fade", "Minimize" };

const CurvePreset = struct {
    label: []const u8,
    p: [4]f64,
};
const curve_presets = [_]CurvePreset{
    .{ .label = "Linear", .p = .{ 0.0, 0.0, 1.0, 1.0 } },
    .{ .label = "Ease", .p = .{ 0.25, 0.1, 0.25, 1.0 } },
    .{ .label = "Ease in", .p = .{ 0.42, 0.0, 1.0, 1.0 } },
    .{ .label = "Ease out", .p = .{ 0.0, 0.0, 0.58, 1.0 } },
    .{ .label = "Ease in-out", .p = .{ 0.42, 0.0, 0.58, 1.0 } },
    .{ .label = "Fluent decelerate", .p = .{ 0.1, 0.9, 0.2, 1.0 } },
    .{ .label = "Overshoot", .p = .{ 0.34, 1.56, 0.64, 1.0 } },
};

// Metrics.

const row_h: i32 = 56;
const thumb_w: i32 = 64;
const thumb_h: i32 = 34;
const switch_w: i32 = 40;
const switch_h: i32 = 24;
const chevron_w: i32 = 20;
const pad: i32 = 16;
const pill_w: i32 = 66;
const pill_h: i32 = 24;
const dur_box_w: i32 = 116;
const dur_box_h: i32 = 28;
const dur_zone: i32 = 32;
const dist_value_w: i32 = 84;
/// Editor band heights.
const duration_h: i32 = 54;
const easing_h: i32 = 74;
const curve_head_h: i32 = 38;
const graph_w: i32 = 218;
const graph_h: i32 = 178;
const curve_body_h: i32 = graph_h + 20;
const style_h: i32 = 92;
const distance_h: i32 = 64;
const editor_h: i32 = duration_h + easing_h + curve_head_h + curve_body_h + style_h + distance_h + 16;

pub fn height() i32 {
    return row_h * @as(i32, @intCast(leaf_count)) + if (open >= 0) editor_h else 0;
}

/// One expanded row at a time, like the reference. `-1` closes all.
pub var open: i32 = -1;
/// Index of the curve control point under the pointer (0 = P1, 1 = P2).
pub var drag_point: i32 = -1;

/// Reset transient UI state when the page changes or the window closes.
pub fn reset() void {
    open = -1;
    drag_point = -1;
}

// Last painted rect, so mouse motion can map into the curve graph without
// the caller re-deriving the row geometry.
var g_x: i32 = 0;
var g_y: i32 = 0;
var g_w: i32 = 0;

const Rect = common.Rect;

/// Rows after the open leaf sit below the editor, so the editor always
/// appears directly under the row that was clicked (reference behaviour)
/// instead of at the bottom of the list.
fn rowOffset(i: usize) i32 {
    if (open >= 0 and i > @as(usize, @intCast(open))) return editor_h;
    return 0;
}

fn rowRect(x: i32, y: i32, w: i32, i: usize) Rect {
    const ii: i32 = @intCast(i);
    return .{ .x = x, .y = y + ii * row_h + rowOffset(i), .w = w, .h = row_h };
}

/// Duration stepper geometry: a Default pill, then one container split into
/// minus / value / plus zones. Shared by paint and hit so they cannot drift.
const DurGeo = struct {
    def: Rect,
    box: Rect,
    minus: Rect,
    value: Rect,
    plus: Rect,
};

fn durGeo(x: i32, w: i32, ry: i32) DurGeo {
    const right = x + w - pad - 8;
    const box = Rect{ .x = right - dur_box_w, .y = ry + 4, .w = dur_box_w, .h = dur_box_h };
    const def = Rect{ .x = box.x - 8 - pill_w, .y = ry + 6, .w = pill_w, .h = pill_h };
    const minus = Rect{ .x = box.x, .y = box.y, .w = dur_zone, .h = box.h };
    const value = Rect{ .x = box.x + dur_zone, .y = box.y, .w = dur_box_w - 2 * dur_zone, .h = box.h };
    const plus = Rect{ .x = box.x + dur_box_w - dur_zone, .y = box.y, .w = dur_zone, .h = box.h };
    return .{ .def = def, .box = box, .minus = minus, .value = value, .plus = plus };
}

/// Distance geometry: label column on the left, then the rail, the Default
/// pill and the value box on the right. The label column grows with the card
/// but never eats the rail; a narrow card keeps a usable track.
const DistGeo = struct {
    def: Rect,
    value: Rect,
    track: Rect,
};

fn distGeo(x: i32, w: i32, ry: i32) DistGeo {
    const right = x + w - pad - 8;
    const value = Rect{ .x = right - dist_value_w, .y = ry + 8, .w = dist_value_w, .h = 26 };
    const def = Rect{ .x = value.x - 8 - pill_w, .y = ry + 9, .w = pill_w, .h = pill_h };
    const label_w = @min(188, @max(80, w - 302));
    const left = x + pad + 8 + label_w;
    const tw = @max(40, def.x - 16 - left);
    const track = Rect{ .x = left, .y = ry + 21, .w = tw, .h = 4 };
    return .{ .def = def, .value = value, .track = track };
}

fn thumbRect(r: Rect) Rect {
    return .{
        .x = r.x + r.w - pad - chevron_w - 8 - switch_w - 12 - thumb_w,
        .y = r.y + @divTrunc(row_h - thumb_h, 2),
        .w = thumb_w,
        .h = thumb_h,
    };
}

fn switchRect(r: Rect) Rect {
    return .{
        .x = r.x + r.w - pad - chevron_w - 8 - switch_w,
        .y = r.y + @divTrunc(row_h - switch_h, 2),
        .w = switch_w,
        .h = switch_h,
    };
}

fn chevronRect(r: Rect) Rect {
    return .{ .x = r.x + r.w - pad - chevron_w, .y = r.y, .w = chevron_w, .h = row_h };
}

fn editorTop(x: i32, y: i32) i32 {
    _ = x;
    if (open >= 0 and open < leaf_count) {
        return y + (@as(i32, @intCast(open)) + 1) * row_h;
    }
    return y + row_h * @as(i32, @intCast(leaf_count));
}

fn graphRect(x: i32, y: i32, w: i32) Rect {
    _ = w;
    const top = editorTop(x, y);
    return .{ .x = x + pad + 8, .y = top + duration_h + easing_h + curve_head_h + 10, .w = graph_w, .h = graph_h };
}

// Data helpers.

fn slot(f: fields.Field) u16 {
    return f.zoolSlot() orelse 0;
}

fn boolOf(f: fields.Field) bool {
    return data.getBool(slot(f));
}

fn intOf(f: fields.Field) i32 {
    return data.getInt(slot(f));
}

fn strOf(f: fields.Field) []const u8 {
    return data.getStr(slot(f));
}

fn easingIndex(s: []const u8) usize {
    for (easing_values, 0..) |v, i| {
        if (std.mem.eql(u8, v, s)) return i;
    }
    return 0;
}

fn styleIndex(s: []const u8) usize {
    for (style_values, 0..) |v, i| {
        if (std.mem.eql(u8, v, s)) return i;
    }
    return 0;
}

// Painting helpers.

fn chevron(c: ?*cairo.cairo_t, x: i32, y: i32, open_now: bool) void {
    const cr = c orelse return;
    const t = common.Theme;
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    cairo.cairo_save(cr);
    cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.55);
    cairo.cairo_set_line_width(cr, 1.6);
    cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
    if (open_now) {
        cairo.cairo_move_to(cr, xf - 4, yf + 2);
        cairo.cairo_line_to(cr, xf, yf - 2);
        cairo.cairo_line_to(cr, xf + 4, yf + 2);
    } else {
        cairo.cairo_move_to(cr, xf - 2, yf - 4);
        cairo.cairo_line_to(cr, xf + 2, yf);
        cairo.cairo_line_to(cr, xf - 2, yf + 4);
    }
    cairo.cairo_stroke(cr);
    cairo.cairo_restore(cr);
}

/// Draw a cubic Bézier line in `r` from the four control points.
fn curvePath(c: ?*cairo.cairo_t, r: Rect, p: [4]f64) void {
    const cr = c orelse return;
    const t = common.Theme;
    const padx: f64 = 12;
    const pady: f64 = 10;
    const x0 = @as(f64, @floatFromInt(r.x)) + padx;
    const y0 = @as(f64, @floatFromInt(r.y + r.h)) - pady;
    const w = @as(f64, @floatFromInt(r.w)) - 2 * padx;
    const h = @as(f64, @floatFromInt(r.h)) - 2 * pady;
    const lo: f64 = -0.25;
    const hi: f64 = 1.25;
    const mapx = struct {
        fn f(x: f64, base: f64, width: f64) f64 {
            return base + x * width;
        }
    }.f;
    const mapy = struct {
        fn f(y: f64, base: f64, span: f64, lo_: f64, hi_: f64) f64 {
            return base - (y - lo_) / (hi_ - lo_) * span;
        }
    }.f;
    cairo.cairo_save(cr);
    cairo.cairo_set_source_rgba(cr, t.acc_r, t.acc_g, t.acc_b, 0.95);
    cairo.cairo_set_line_width(cr, 1.8);
    cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_move_to(cr, mapx(0, x0, w), mapy(0, y0, h, lo, hi));
    cairo.cairo_curve_to(
        cr,
        mapx(p[0], x0, w),
        mapy(p[1], y0, h, lo, hi),
        mapx(p[2], x0, w),
        mapy(p[3], y0, h, lo, hi),
        mapx(1, x0, w),
        mapy(1, y0, h, lo, hi),
    );
    cairo.cairo_stroke(cr);
    cairo.cairo_restore(cr);
}

fn curvePoint(c: ?*cairo.cairo_t, r: Rect, p: [4]f64, which: usize) void {
    const cr = c orelse return;
    const t = common.Theme;
    const padx: f64 = 12;
    const pady: f64 = 10;
    const x0 = @as(f64, @floatFromInt(r.x)) + padx;
    const y0 = @as(f64, @floatFromInt(r.y + r.h)) - pady;
    const w = @as(f64, @floatFromInt(r.w)) - 2 * padx;
    const h = @as(f64, @floatFromInt(r.h)) - 2 * pady;
    const lo: f64 = -0.25;
    const hi: f64 = 1.25;
    const cx = p[which * 2];
    const cy = p[which * 2 + 1];
    const px = x0 + cx * w;
    const py = y0 - (cy - lo) / (hi - lo) * h;
    cairo.cairo_save(cr);
    cairo.cairo_arc(cr, px, py, 5.0, 0, std.math.tau);
    cairo.cairo_set_source_rgba(cr, t.bg_r, t.bg_g, t.bg_b, 1.0);
    cairo.cairo_fill(cr);
    cairo.cairo_arc(cr, px, py, 4.0, 0, std.math.tau);
    cairo.cairo_set_source_rgba(cr, t.acc_r, t.acc_g, t.acc_b, 1.0);
    cairo.cairo_fill(cr);
    cairo.cairo_restore(cr);
}

fn defaultPill(c: ?*cairo.cairo_t, x: i32, y: i32, hovered: bool) void {
    const t = common.Theme;
    ui_paint.glassBox(c, @floatFromInt(x), @floatFromInt(y), @floatFromInt(pill_w), @floatFromInt(pill_h), 12, t.text_r, t.text_g, t.text_b, if (hovered) 0.14 else 0.07);
    const tw = ui_paint.textWidthPx(c, "Default", 10, 500);
    ui_paint.showText(c, @as(f64, @floatFromInt(x + @divTrunc(pill_w - tw, 2))), @floatFromInt(y + 16), "Default", 10, 500, t.text_r, t.text_g, t.text_b, 0.62);
}

/// The compact list plus the open editor. `x`,`y` is the row area inside the
/// card (below its title band); `w` is the card width.
pub fn paint(c: ?*cairo.cairo_t, x: i32, y: i32, w: i32, px: f64, py: f64) void {
    g_x = x;
    g_y = y;
    g_w = w;
    const t = common.Theme;
    for (leaves, 0..) |lf, i| {
        const r = rowRect(x, y, w, i);
        const is_open = open == @as(i32, @intCast(i));
        if (i > 0) {
            ui_paint.glassBox(c, @floatFromInt(r.x + pad), @floatFromInt(r.y), @floatFromInt(r.w - 2 * pad), 1, 0, t.text_r, t.text_g, t.text_b, 0.05);
        }
        // Hover tint on the whole row.
        if (common.pointInRect(px, py, r) and !is_open) {
            ui_paint.glassBox(c, @floatFromInt(r.x + 4), @floatFromInt(r.y + 2), @floatFromInt(r.w - 8), @floatFromInt(r.h - 4), 8, t.acc_r, t.acc_g, t.acc_b, 0.035);
        }
        ui_paint.showText(c, @floatFromInt(r.x + pad), @floatFromInt(r.y + 22), lf.label, 13, 500, t.text_r, t.text_g, t.text_b, 0.92);
        var sub_buf: [160]u8 = undefined;
        const ease_lbl = easing_labels[easingIndex(strOf(lf.easing))];
        const style_lbl = style_labels[styleIndex(strOf(lf.style))];
        const sub = if (is_open)
            (if (data.leafCurveSet(@intCast(i)))
                std.fmt.bufPrint(&sub_buf, "{d} ms · {s} · Custom curve · {s} · {d}%", .{ intOf(lf.duration), ease_lbl, style_lbl, intOf(lf.percent) }) catch ""
            else
                std.fmt.bufPrint(&sub_buf, "{d} ms · {s} · {s} · {d}%", .{ intOf(lf.duration), ease_lbl, style_lbl, intOf(lf.percent) }) catch "")
        else
            std.fmt.bufPrint(&sub_buf, "{s} · {s}", .{ ease_lbl, style_lbl }) catch "";
        ui_paint.showText(c, @floatFromInt(r.x + pad), @floatFromInt(r.y + 40), sub, 10.5, 400, t.text_r, t.text_g, t.text_b, 0.48);

        // Thumbnail curve.
        const tr = thumbRect(r);
        ui_paint.glassBox(c, @floatFromInt(tr.x), @floatFromInt(tr.y), @floatFromInt(tr.w), @floatFromInt(tr.h), 6, t.text_r, t.text_g, t.text_b, 0.06);
        paintCurveForThumb(c, tr, @intCast(i));

        const sr = switchRect(r);
        ui_paint.paintSwitch(c, sr.x, sr.y, sr.w, sr.h, boolOf(lf.enabled));
        const cr = chevronRect(r);
        chevron(c, cr.x + @divTrunc(cr.w, 2), cr.y + @divTrunc(cr.h, 2), is_open);
        if (is_open) paintEditor(c, x, y, w, @intCast(open), px, py);
    }
}

/// The curve the leaf is showing: its stored table when set, otherwise the
/// easing preset it falls back to. Hit-testing, paint and dragging all read
/// this, so the handle you grab is the handle you see.
fn effectiveCurve(lnum: u8) [4]f64 {
    if (data.leafCurveSet(lnum)) {
        return .{ data.leafCurvePoint(lnum, 0), data.leafCurvePoint(lnum, 1), data.leafCurvePoint(lnum, 2), data.leafCurvePoint(lnum, 3) };
    }
    return switch (easingIndex(strOf(leaves[lnum].easing))) {
        0 => .{ 0, 0, 1, 1 },
        1 => .{ 0.25, 0.1, 0.25, 1 },
        else => .{ 0.42, 0, 0.58, 1 },
    };
}

fn paintCurveForThumb(c: ?*cairo.cairo_t, r: Rect, lnum: u8) void {
    curvePath(c, r, effectiveCurve(lnum));
}

fn paintEditor(c: ?*cairo.cairo_t, x: i32, y: i32, w: i32, lnum: u8, px: f64, py: f64) void {
    const t = common.Theme;
    const lf = leaves[lnum];
    const top = editorTop(x, y);
    const inner_x = x + pad;
    const inner_w = w - 2 * pad;

    // Inset well holding the whole editor.
    ui_paint.glassBox(c, @floatFromInt(x + 8), @floatFromInt(top + 4), @floatFromInt(w - 16), @floatFromInt(editor_h - 8), 10, t.text_r, t.text_g, t.text_b, 0.045);

    var ry = top + 8;

    // Duration: Default, then one stepper with three evenly weighted zones.
    ui_paint.showText(c, @floatFromInt(inner_x + 8), @floatFromInt(ry + 22), "Duration", 12, 500, t.text_r, t.text_g, t.text_b, 0.72);
    const dg = durGeo(x, w, ry);
    defaultPill(c, dg.def.x, dg.def.y, common.pointInRect(px, py, dg.def));
    ui_paint.glassBox(c, @floatFromInt(dg.box.x), @floatFromInt(dg.box.y), @floatFromInt(dg.box.w), @floatFromInt(dg.box.h), 6, t.text_r, t.text_g, t.text_b, 0.07);
    if (common.pointInRect(px, py, dg.minus))
        ui_paint.glassBox(c, @floatFromInt(dg.minus.x), @floatFromInt(dg.minus.y), @floatFromInt(dg.minus.w), @floatFromInt(dg.minus.h), 6, t.text_r, t.text_g, t.text_b, 0.08);
    if (common.pointInRect(px, py, dg.plus))
        ui_paint.glassBox(c, @floatFromInt(dg.plus.x), @floatFromInt(dg.plus.y), @floatFromInt(dg.plus.w), @floatFromInt(dg.plus.h), 6, t.text_r, t.text_g, t.text_b, 0.08);
    ui_paint.glassBox(c, @floatFromInt(dg.value.x), @floatFromInt(dg.box.y + 6), 1, @floatFromInt(dur_box_h - 12), 0, t.text_r, t.text_g, t.text_b, 0.1);
    ui_paint.glassBox(c, @floatFromInt(dg.value.x + dg.value.w), @floatFromInt(dg.box.y + 6), 1, @floatFromInt(dur_box_h - 12), 0, t.text_r, t.text_g, t.text_b, 0.1);
    const minus_tw = ui_paint.textWidthPx(c, "−", 15, 500);
    ui_paint.showText(c, @as(f64, @floatFromInt(dg.minus.x + @divTrunc(dg.minus.w - minus_tw, 2))), @floatFromInt(dg.box.y + 19), "−", 15, 500, t.text_r, t.text_g, t.text_b, 0.7);
    var val_buf: [32]u8 = undefined;
    const val = std.fmt.bufPrint(&val_buf, "{d} ms", .{intOf(lf.duration)}) catch "";
    const val_tw = ui_paint.textWidthPx(c, val, 11.5, 500);
    ui_paint.showText(c, @as(f64, @floatFromInt(dg.value.x + @divTrunc(dg.value.w - val_tw, 2))), @floatFromInt(dg.box.y + 19), val, 11.5, 500, t.text_r, t.text_g, t.text_b, 0.86);
    const plus_tw = ui_paint.textWidthPx(c, "+", 15, 500);
    ui_paint.showText(c, @as(f64, @floatFromInt(dg.plus.x + @divTrunc(dg.plus.w - plus_tw, 2))), @floatFromInt(dg.box.y + 19), "+", 15, 500, t.text_r, t.text_g, t.text_b, 0.7);
    ry += duration_h;

    // Easing segmented control.
    ui_paint.showText(c, @floatFromInt(inner_x + 8), @floatFromInt(ry + 18), "Easing", 12, 500, t.text_r, t.text_g, t.text_b, 0.72);
    ui_paint.showText(c, @floatFromInt(inner_x + 8), @floatFromInt(ry + 34), "Unset keeps the current curve.", 10, 400, t.text_r, t.text_g, t.text_b, 0.42);
    const ease_def = Rect{ .x = x + w - pad - 8 - 66, .y = ry + 4, .w = 66, .h = 24 };
    defaultPill(c, ease_def.x, ease_def.y, common.pointInRect(px, py, ease_def));
    const seg_y = ry + 40;
    const seg_x = inner_x + 8;
    const seg_w = inner_w - 16;
    const sel = easingIndex(strOf(lf.easing));
    const seg_gap: i32 = 6;
    const each = @divTrunc(seg_w - seg_gap * 2, 3);
    for (0..3) |i| {
        const sr = Rect{ .x = seg_x + @as(i32, @intCast(i)) * (each + seg_gap), .y = seg_y, .w = if (i == 2) seg_w - 2 * (each + seg_gap) else each, .h = 26 };
        const chosen = i == sel;
        const hov = common.pointInRect(px, py, sr);
        ui_paint.glassBox(c, @floatFromInt(sr.x), @floatFromInt(sr.y), @floatFromInt(sr.w), @floatFromInt(sr.h), 6, if (chosen) t.acc_r else t.text_r, if (chosen) t.acc_g else t.text_g, if (chosen) t.acc_b else t.text_b, if (chosen) 0.22 else if (hov) 0.12 else 0.055);
        const lw = ui_paint.textWidthPx(c, easing_labels[i], 10, if (chosen) 600 else 400);
        ui_paint.showText(c, @as(f64, @floatFromInt(sr.x + @divTrunc(sr.w, 2))) - @as(f64, @floatFromInt(@divTrunc(lw, 2))), @floatFromInt(sr.y + 17), easing_labels[i], 10, if (chosen) 600 else 400, t.text_r, t.text_g, t.text_b, if (chosen) 0.95 else 0.62);
    }
    ry += easing_h;

    // Curve header.
    ui_paint.showText(c, @floatFromInt(inner_x + 8), @floatFromInt(ry + 22), "Curve", 12, 500, t.text_r, t.text_g, t.text_b, 0.72);
    const maybe_curve = Rect{ .x = x + w - pad - 8 - 66, .y = ry + 6, .w = 66, .h = 24 };
    defaultPill(c, maybe_curve.x, maybe_curve.y, common.pointInRect(px, py, maybe_curve));
    ry += curve_head_h;

    // Graph + right column.
    const gr = graphRect(x, y, w);
    ui_paint.glassBox(c, @floatFromInt(gr.x), @floatFromInt(gr.y), @floatFromInt(gr.w), @floatFromInt(gr.h), 8, t.text_r, t.text_g, t.text_b, 0.06);
    // Grid.
    cairo.cairo_save(c);
    if (c) |cr| {
        cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.08);
        cairo.cairo_set_line_width(cr, 1);
        for (1..4) |k| {
            const gx = gr.x + @divTrunc(gr.w * @as(i32, @intCast(k)), 4);
            cairo.cairo_move_to(cr, @floatFromInt(gx), @floatFromInt(gr.y + 6));
            cairo.cairo_line_to(cr, @floatFromInt(gx), @floatFromInt(gr.y + gr.h - 6));
            cairo.cairo_stroke(cr);
            const gy = gr.y + @divTrunc(gr.h * @as(i32, @intCast(k)), 4);
            cairo.cairo_move_to(cr, @floatFromInt(gr.x + 6), @floatFromInt(gy));
            cairo.cairo_line_to(cr, @floatFromInt(gr.x + gr.w - 6), @floatFromInt(gy));
            cairo.cairo_stroke(cr);
        }
    }
    cairo.cairo_restore(c);
    // Reference line: the identity (linear) curve, so the bend is readable.
    if (c) |cr| {
        const padx: f64 = 12;
        const pady: f64 = 10;
        const x0 = @as(f64, @floatFromInt(gr.x)) + padx;
        const y0 = @as(f64, @floatFromInt(gr.y + gr.h)) - pady;
        const gw = @as(f64, @floatFromInt(gr.w)) - 2 * padx;
        const gh = @as(f64, @floatFromInt(gr.h)) - 2 * pady;
        const dashes = [_]f64{ 4, 4 };
        cairo.cairo_save(cr);
        cairo.cairo_set_dash(cr, &dashes, 2, 0);
        cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.16);
        cairo.cairo_set_line_width(cr, 1);
        cairo.cairo_move_to(cr, x0, y0);
        cairo.cairo_line_to(cr, x0 + gw, y0 - gh);
        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
    }
    const curve_p = effectiveCurve(lnum);
    curvePath(c, gr, curve_p);
    curvePoint(c, gr, curve_p, 0);
    curvePoint(c, gr, curve_p, 1);

    // Right column: expression, presets, preview.
    const col_x = gr.x + gr.w + 16;
    const col_w = x + w - pad - col_x;
    var ebuf: [96]u8 = undefined;
    const expr = std.fmt.bufPrint(&ebuf, "cubic-bezier({d:.2}, {d:.2}, {d:.2}, {d:.2})", .{ curve_p[0], curve_p[1], curve_p[2], curve_p[3] }) catch "";
    ui_paint.glassBox(c, @floatFromInt(col_x), @floatFromInt(gr.y), @floatFromInt(col_w), 28, 6, t.text_r, t.text_g, t.text_b, 0.08);
    ui_paint.showText(c, @floatFromInt(col_x + 10), @floatFromInt(gr.y + 18), expr, 10.5, 400, t.text_r, t.text_g, t.text_b, 0.8);

    // Preset chips: two rows.
    var chip_y = gr.y + 40;
    var chip_x = col_x;
    for (curve_presets, 0..) |cp, i| {
        const cw = ui_paint.textWidthPx(c, cp.label, 10, 500) + 20;
        if (chip_x + cw > col_x + col_w and chip_x > col_x) {
            chip_x = col_x;
            chip_y += 30;
        }
        const cr = Rect{ .x = chip_x, .y = chip_y, .w = cw, .h = 24 };
        const hov = common.pointInRect(px, py, cr);
        ui_paint.glassBox(c, @floatFromInt(cr.x), @floatFromInt(cr.y), @floatFromInt(cr.w), @floatFromInt(cr.h), 12, t.text_r, t.text_g, t.text_b, if (hov) 0.14 else 0.07);
        ui_paint.showText(c, @floatFromInt(cr.x + 10), @floatFromInt(cr.y + 16), cp.label, 10, 500, t.text_r, t.text_g, t.text_b, 0.7);
        chip_x += cw + 6;
        _ = i;
    }

    // Preview strip.
    const pv_y = gr.y + gr.h - 34;
    var pl: [40]u8 = undefined;
    const plabel = std.fmt.bufPrint(&pl, "Preview · {d} ms", .{intOf(lf.duration)}) catch "Preview";
    ui_paint.showText(c, @floatFromInt(col_x), @floatFromInt(pv_y - 6), plabel, 10, 500, t.text_r, t.text_g, t.text_b, 0.5);
    ui_paint.glassBox(c, @floatFromInt(col_x), @floatFromInt(pv_y + 4), @floatFromInt(col_w), 24, 5, t.text_r, t.text_g, t.text_b, 0.06);
    if (c) |cr| {
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.25);
        cairo.cairo_set_line_width(cr, 1);
        for (1..10) |k| {
            const tx = col_x + @divTrunc(col_w * @as(i32, @intCast(k)), 10);
            cairo.cairo_move_to(cr, @floatFromInt(tx), @floatFromInt(pv_y + 10));
            cairo.cairo_line_to(cr, @floatFromInt(tx), @floatFromInt(pv_y + 22));
            cairo.cairo_stroke(cr);
        }
        cairo.cairo_restore(cr);
    }
    ui_paint.glassBox(c, @floatFromInt(col_x + col_w - 18), @floatFromInt(pv_y + 10), 12, 12, 6, t.acc_r, t.acc_g, t.acc_b, 0.9);
    ry += curve_body_h;

    // Style chips (four per row).
    ui_paint.showText(c, @floatFromInt(inner_x + 8), @floatFromInt(ry + 20), "Style", 12, 500, t.text_r, t.text_g, t.text_b, 0.72);
    const st_sel = styleIndex(strOf(lf.style));
    const chip_w = @divTrunc(inner_w - 16 - 3 * 8, 4);
    for (0..2) |row_i| {
        for (0..4) |col_i| {
            const i = row_i * 4 + col_i;
            if (i >= style_values.len) break;
            const sr = Rect{ .x = inner_x + 8 + @as(i32, @intCast(col_i)) * (chip_w + 8), .y = ry + 30 + @as(i32, @intCast(row_i)) * 28, .w = chip_w, .h = 24 };
            const chosen = i == st_sel;
            const hov = common.pointInRect(px, py, sr);
            ui_paint.glassBox(c, @floatFromInt(sr.x), @floatFromInt(sr.y), @floatFromInt(sr.w), @floatFromInt(sr.h), 6, if (chosen) t.acc_r else t.text_r, if (chosen) t.acc_g else t.text_g, if (chosen) t.acc_b else t.text_b, if (chosen) 0.22 else if (hov) 0.12 else 0.055);
            const lw = ui_paint.textWidthPx(c, style_labels[i], 10, if (chosen) 600 else 400);
            ui_paint.showText(c, @as(f64, @floatFromInt(sr.x + @divTrunc(sr.w, 2))) - @as(f64, @floatFromInt(@divTrunc(lw, 2))), @floatFromInt(sr.y + 16), style_labels[i], 10, if (chosen) 600 else 400, t.text_r, t.text_g, t.text_b, if (chosen) 0.95 else 0.62);
        }
    }
    ry += style_h;

    // Distance.
    ui_paint.showText(c, @floatFromInt(inner_x + 8), @floatFromInt(ry + 20), "Distance", 12, 500, t.text_r, t.text_g, t.text_b, 0.72);
    ui_paint.showText(c, @floatFromInt(inner_x + 8), @floatFromInt(ry + 36), "How far slides and pop-ins travel.", 10, 400, t.text_r, t.text_g, t.text_b, 0.42);
    const dgeo = distGeo(x, w, ry);
    defaultPill(c, dgeo.def.x, dgeo.def.y, common.pointInRect(px, py, dgeo.def));
    ui_paint.glassBox(c, @floatFromInt(dgeo.value.x), @floatFromInt(dgeo.value.y), @floatFromInt(dgeo.value.w), @floatFromInt(dgeo.value.h), 6, t.text_r, t.text_g, t.text_b, 0.07);
    var db: [16]u8 = undefined;
    const dtxt = std.fmt.bufPrint(&db, "{d} %", .{intOf(lf.percent)}) catch "";
    const dtxt_w = ui_paint.textWidthPx(c, dtxt, 11, 500);
    ui_paint.showText(c, @as(f64, @floatFromInt(dgeo.value.x + @divTrunc(dgeo.value.w - dtxt_w, 2))), @floatFromInt(dgeo.value.y + 17), dtxt, 11, 500, t.text_r, t.text_g, t.text_b, 0.86);
    ui_paint.glassBox(c, @floatFromInt(dgeo.track.x), @floatFromInt(dgeo.track.y), @floatFromInt(dgeo.track.w), @floatFromInt(dgeo.track.h), 2, t.text_r, t.text_g, t.text_b, 0.14);
    const frac = @as(f64, @floatFromInt(intOf(lf.percent) - 1)) / 99.0;
    const knob_x = dgeo.track.x + @as(i32, @intFromFloat(frac * @as(f64, @floatFromInt(dgeo.track.w))));
    ui_paint.glassBox(c, @floatFromInt(dgeo.track.x), @floatFromInt(dgeo.track.y), @floatFromInt(@max(1, knob_x - dgeo.track.x)), @floatFromInt(dgeo.track.h), 2, t.acc_r, t.acc_g, t.acc_b, 0.55);
    const knob_cy = dgeo.track.y + @divTrunc(dgeo.track.h, 2);
    ui_paint.glassBox(c, @floatFromInt(knob_x - 7), @floatFromInt(knob_cy - 7), 14, 14, 7, t.acc_r, t.acc_g, t.acc_b, 0.95);
}

// Actions.

pub const Action = union(enum) {
    expand: u8,
    toggle: u8,
    duration_step: struct { leaf: u8, delta: i32 },
    duration_default: u8,
    easing: struct { leaf: u8, idx: u8 },
    easing_default: u8,
    curve_default: u8,
    curve_drag: struct { leaf: u8, point: u8 },
    curve_preset: struct { leaf: u8, idx: u8 },
    style: struct { leaf: u8, idx: u8 },
    percent_default: u8,
    none,
};

fn inRect(px: f64, py: f64, r: Rect) bool {
    return common.pointInRect(px, py, r);
}

/// Map the pointer into a curve point. `which` selects P1 or P2.
fn curveFromPointer(px: f64, py: f64, r: Rect, which: usize) [2]f64 {
    _ = which;
    const padx: f64 = 12;
    const pady: f64 = 10;
    const x0 = @as(f64, @floatFromInt(r.x)) + padx;
    const y0 = @as(f64, @floatFromInt(r.y + r.h)) - pady;
    const w = @as(f64, @floatFromInt(r.w)) - 2 * padx;
    const h = @as(f64, @floatFromInt(r.h)) - 2 * pady;
    const lo: f64 = -0.25;
    const hi: f64 = 1.25;
    const cx = std.math.clamp((px - x0) / w, 0.0, 1.0);
    const cy = lo + (y0 - py) / h * (hi - lo);
    return .{ cx, cy };
}

pub fn hit(x: i32, y: i32, w: i32, px: f64, py: f64) Action {
    for (leaves, 0..) |_, i| {
        const r = rowRect(x, y, w, i);
        if (!inRect(px, py, r)) continue;
        const lnum: u8 = @intCast(i);
        if (inRect(px, py, switchRect(r))) return .{ .toggle = lnum };
        if (inRect(px, py, chevronRect(r))) {
            return .{ .expand = lnum };
        }
        return .{ .expand = lnum };
    }
    if (open < 0 or open >= leaf_count) return .none;
    const lnum: u8 = @intCast(open);
    const top = editorTop(x, y);
    const inner_x = x + pad;
    var ry = top + 8;

    // Duration.
    const dg = durGeo(x, w, ry);
    if (inRect(px, py, dg.def)) return .{ .duration_default = lnum };
    if (inRect(px, py, dg.minus)) return .{ .duration_step = .{ .leaf = lnum, .delta = -10 } };
    if (inRect(px, py, dg.plus)) return .{ .duration_step = .{ .leaf = lnum, .delta = 10 } };
    ry += duration_h;

    // Easing.
    const ease_def = Rect{ .x = x + w - pad - 8 - 66, .y = ry + 4, .w = 66, .h = 24 };
    if (inRect(px, py, ease_def)) return .{ .easing_default = lnum };
    const seg_y = ry + 40;
    const seg_x = inner_x + 8;
    const seg_w = w - 2 * pad - 16;
    const seg_gap: i32 = 6;
    const each = @divTrunc(seg_w - seg_gap * 2, 3);
    for (0..3) |i| {
        const sr = Rect{ .x = seg_x + @as(i32, @intCast(i)) * (each + seg_gap), .y = seg_y, .w = if (i == 2) seg_w - 2 * (each + seg_gap) else each, .h = 26 };
        if (inRect(px, py, sr)) return .{ .easing = .{ .leaf = lnum, .idx = @intCast(i) } };
    }
    ry += easing_h;

    // Curve.
    const maybe_curve = Rect{ .x = x + w - pad - 8 - 66, .y = ry + 6, .w = 66, .h = 24 };
    if (inRect(px, py, maybe_curve)) return .{ .curve_default = lnum };
    ry += curve_head_h;

    const gr = graphRect(x, y, w);
    // Control points first: their hit radius is generous.
    const cp = effectiveCurve(lnum);
    const padx: f64 = 12;
    const pady: f64 = 10;
    const gx0 = @as(f64, @floatFromInt(gr.x)) + padx;
    const gy0 = @as(f64, @floatFromInt(gr.y + gr.h)) - pady;
    const gw = @as(f64, @floatFromInt(gr.w)) - 2 * padx;
    const gh = @as(f64, @floatFromInt(gr.h)) - 2 * pady;
    const lo: f64 = -0.25;
    const hi: f64 = 1.25;
    for (0..2) |k| {
        const cx = gx0 + cp[k * 2] * gw;
        const cy = gy0 - (cp[k * 2 + 1] - lo) / (hi - lo) * gh;
        if (@abs(px - cx) <= 10 and @abs(py - cy) <= 10) {
            return .{ .curve_drag = .{ .leaf = lnum, .point = @intCast(k) } };
        }
    }

    // Preset chips.
    const col_x = gr.x + gr.w + 16;
    const col_w = x + w - pad - col_x;
    var chip_y = gr.y + 40;
    var chip_x = col_x;
    for (curve_presets, 0..) |cpr, i| {
        const cw = ui_paint.textWidthPx(null, cpr.label, 10, 500) + 20;
        if (chip_x + cw > col_x + col_w and chip_x > col_x) {
            chip_x = col_x;
            chip_y += 30;
        }
        const cr = Rect{ .x = chip_x, .y = chip_y, .w = cw, .h = 24 };
        if (inRect(px, py, cr)) return .{ .curve_preset = .{ .leaf = lnum, .idx = @intCast(i) } };
        chip_x += cw + 6;
    }
    ry += curve_body_h;

    // Style chips.
    const st_chip_w = @divTrunc((w - 2 * pad - 16) - 3 * 8, 4);
    for (0..2) |row_i| {
        for (0..4) |col_i| {
            const i = row_i * 4 + col_i;
            if (i >= style_values.len) break;
            const sr = Rect{ .x = inner_x + 8 + @as(i32, @intCast(col_i)) * (st_chip_w + 8), .y = ry + 30 + @as(i32, @intCast(row_i)) * 28, .w = st_chip_w, .h = 24 };
            if (inRect(px, py, sr)) return .{ .style = .{ .leaf = lnum, .idx = @intCast(i) } };
        }
    }
    ry += style_h;

    // Distance.
    const dgeo = distGeo(x, w, ry);
    if (inRect(px, py, dgeo.def)) return .{ .percent_default = lnum };
    return .none;
}

/// Distance slider, exposed as the generic slider hit so the pointer can drag
/// the knob (press alone already lands the value through `applyHit`).
pub const SliderSpec = struct {
    field: fields.Field,
    min: i32,
    max: i32,
    track_x: i32,
    track_w: i32,
};

pub fn sliderHit(x: i32, y: i32, w: i32, px: f64, py: f64) ?SliderSpec {
    if (open < 0 or open >= leaf_count) return null;
    const lnum: u8 = @intCast(open);
    const top = editorTop(x, y);
    var ry = top + 8;
    ry += duration_h + easing_h + curve_head_h + curve_body_h + style_h;
    const dgeo = distGeo(x, w, ry);
    if (dgeo.track.w <= 0) return null;
    if (!inRect(px, py, Rect{ .x = dgeo.track.x - 8, .y = dgeo.track.y - 10, .w = dgeo.track.w + 16, .h = 24 })) return null;
    return .{ .field = leaves[lnum].percent, .min = 1, .max = 100, .track_x = dgeo.track.x, .track_w = dgeo.track.w };
}

/// Apply an action. Returns true when the page height changed and the caller
/// must relayout.
pub fn apply(a: Action) bool {
    switch (a) {
        .none => return false,
        .expand => |lnum| {
            open = if (open == @as(i32, lnum)) -1 else @as(i32, lnum);
            drag_point = -1;
            return true;
        },
        .toggle => |lnum| {
            const lf = leaves[lnum];
            data.setBool(slot(lf.enabled), !boolOf(lf.enabled));
            return false;
        },
        .duration_step => |st| {
            const lf = leaves[st.leaf];
            const next = std.math.clamp(intOf(lf.duration) + st.delta, 1, 5000);
            data.setInt(slot(lf.duration), next);
            return false;
        },
        .duration_default => |lnum| {
            data.resetSlot(slot(leaves[lnum].duration));
            return false;
        },
        .easing => |e| {
            if (e.idx < easing_values.len) data.setStr(slot(leaves[e.leaf].easing), easing_values[e.idx]);
            return false;
        },
        .easing_default => |lnum| {
            data.resetSlot(slot(leaves[lnum].easing));
            return false;
        },
        .curve_default => |lnum| {
            data.clearLeafCurve(lnum);
            return false;
        },
        .curve_drag => |d| {
            data.beginLeafCurve(d.leaf, effectiveCurve(d.leaf));
            drag_point = d.point;
            open = @as(i32, d.leaf);
            return false;
        },
        .curve_preset => |cp| {
            if (cp.idx >= curve_presets.len) return false;
            const p = curve_presets[cp.idx].p;
            for (0..4) |k| data.setLeafCurvePoint(cp.leaf, k, p[k]);
            return false;
        },
        .style => |s| {
            if (s.idx < style_values.len) data.setStr(slot(leaves[s.leaf].style), style_values[s.idx]);
            return false;
        },
        .percent_default => |lnum| {
            data.resetSlot(slot(leaves[lnum].percent));
            return false;
        },
    }
}

/// Follow a curve-handle drag. Returns true when a drag was in progress.
pub fn motion(px: f64, py: f64) bool {
    if (drag_point < 0 or open < 0 or open >= leaf_count) return false;
    const gr = graphRect(g_x, g_y, g_w);
    const cp = curveFromPointer(px, py, gr, @intCast(drag_point));
    const lnum: u8 = @intCast(open);
    const k: usize = @intCast(drag_point * 2);
    data.setLeafCurvePoint(lnum, k, cp[0]);
    data.setLeafCurvePoint(lnum, k + 1, cp[1]);
    return true;
}

pub fn endDrag() void {
    drag_point = -1;
}

pub fn isDragging() bool {
    return drag_point >= 0;
}

test "zoolander-anim: leaves map to a full slot block" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 9), leaves.len);
    try t.expect(data.anim_leaf_count == leaf_count);
    // Every leaf field belongs to the zoolander block.
    for (leaves) |lf| {
        try t.expect(lf.enabled.isZool());
        try t.expect(lf.duration.isZool());
        try t.expect(lf.easing.isZool());
        try t.expect(lf.style.isZool());
        try t.expect(lf.percent.isZool());
    }
}
