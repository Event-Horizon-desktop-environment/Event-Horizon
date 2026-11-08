//! Hyprland animation entries with Zoolander's inline curve editor.
//!
//! Each Hyprland `hl.animation({ leaf = … })` entry gets one compact row:
//! label, the `speed, curve[, style]` summary, a curve
//! thumbnail, the enable switch and a chevron. Opening a row reveals its
//! editor in place — a speed stepper with a Default reset, a draggable
//! cubic-Bézier curve graph with the shipped Hyprland curve presets and a
//! live preview strip, and the entry's own style chips. One entry is open at
//! a time; the chevron replaces the old 3-dot popup, which this editor
//! subsumes (same controls, no separate window).
//!
//! Like `zoolander_anim`, this is a bespoke subview rather than a
//! declarative row: paint, hit-test and the expanded row height all live
//! here so they cannot drift apart. `rows.rowHeightFor` adds `extraFor` to
//! the open row so the cards and the scroll extent grow with the editor.
//!
//! Hand-dragged curves are session state: Hyprland configs reference curves
//! by name only (there is no `bezier = …` writer), so a dragged curve is
//! persisted as the name `eh_custom` and its control points are rebuilt from
//! the preset the entry was last showing.

const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const data = @import("hyprland_data.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;

pub const entry_count = data.k_anim_entries.len;

/// Matches `rows.anim_row_h`; kept local so this module never imports
/// `rows.zig`, which imports this one for the expanded height.
const row_h: i32 = 60;

const pad: i32 = common.card_pad;
const thumb_w: i32 = 64;
const thumb_h: i32 = 34;
const switch_w: i32 = 40;
const switch_h: i32 = 24;
const chevron_w: i32 = 20;
const pill_w: i32 = 66;
const pill_h: i32 = 24;
const step_box_w: i32 = 116;
const step_box_h: i32 = 28;
const step_zone: i32 = 32;
/// Hyprland's own default for an animation entry's speed factor.
const speed_default: f64 = 3.0;
const speed_min: f64 = 0.1;
const speed_max: f64 = 10.0;
const speed_step: f64 = 0.5;

/// Editor band heights: speed stepper, curve head, graph body, style chips.
const speed_h: i32 = 54;
const curve_head_h: i32 = 38;
const graph_w: i32 = 218;
const graph_h: i32 = 178;
const curve_body_h: i32 = graph_h + 20;
const style_h: i32 = 62;
const editor_h: i32 = speed_h + curve_head_h + curve_body_h + style_h + 16;

/// The curve presets offered as chips. Every label is a real Hyprland curve
/// name, so picking one persists as that name; `smooth` is left out because
/// its control points duplicate `default`.
pub const preset_names = [_][]const u8{ "default", "linear", "overshot", "easeInOut", "easeIn", "easeOut", "easeOutBack", "easeInBack" };

/// One expanded row at a time, like the Zoolander reference. `-1` closes all.
pub var open: i32 = -1;
/// Index of the curve control point under the pointer (0 = P1, 1 = P2).
pub var drag_point: i32 = -1;

/// Reset transient UI state when the page or sub-tab changes.
pub fn reset() void {
    open = -1;
    drag_point = -1;
}

/// Extra height the row for `entry` carries this frame (its inline editor),
/// read by `rows.rowHeightFor` so layout, hit bands and the scroll extent
/// all grow with the open editor.
pub fn extraFor(entry: u8) i32 {
    if (open >= 0 and open == @as(i32, entry)) return editor_h;
    return 0;
}

// Per-entry hand-drawn curve state (see the module comment for why it is
// session-only). `g_curve_set` says the entry shows a dragged table rather
// than the preset behind its stored curve name.
var g_curve_set = [_]bool{false} ** entry_count;
var g_curve = [_][4]f64{.{ 0.25, 0.1, 0.25, 1.0 }} ** entry_count;

// Last painted open-row rect, so mouse motion can map into the curve graph
// without the caller re-deriving the row geometry.
var g_x: i32 = 0;
var g_y: i32 = 0;
var g_w: i32 = 0;

const Rect = common.Rect;

fn inRect(px: f64, py: f64, r: Rect) bool {
    return common.pointInRect(px, py, r);
}

fn nameOf(entry: usize) []const u8 {
    return data.k_anim_entries[entry].name;
}

/// The curve the row shows: its dragged table when set, otherwise the
/// preset behind the entry's stored curve name. Paint, hit-test and
/// dragging all read this, so the handle you grab is the handle you see.
pub fn effectiveCurve(entry: usize) [4]f64 {
    if (g_curve_set[entry]) return g_curve[entry];
    if (data.bezierForCurve(data.animCurve(nameOf(entry)))) |p| {
        return .{ p.p1x, p.p1y, p.p2x, p.p2y };
    }
    return .{ 0.25, 0.1, 0.25, 1.0 };
}

/// The entry's style chips: `Default` (the empty style, Hyprland's own
/// behaviour for the animation type) followed by the styles the shipped
/// table allows for it. Values index straight into `setAnimStyle`.
const StyleChips = struct {
    vals: [4][]const u8 = .{ "", "", "", "" },
    n: usize = 1,
};

fn styleChips(entry: usize) StyleChips {
    var out: StyleChips = .{};
    const raw = data.k_anim_entries[entry].styles;
    if (raw.len == 0) return out;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= raw.len and out.n < out.vals.len) : (i += 1) {
        if (i == raw.len or raw[i] == ',') {
            var tok = raw[start..i];
            start = i + 1;
            while (tok.len > 0 and tok[0] == ' ') tok = tok[1..];
            while (tok.len > 0 and tok[tok.len - 1] == ' ') tok = tok[0 .. tok.len - 1];
            if (tok.len > 0) {
                out.vals[out.n] = tok;
                out.n += 1;
            }
        }
    }
    return out;
}

// Geometry helpers, shared by paint and hit-test.

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

fn editorTop(y: i32) i32 {
    return y + row_h;
}

fn graphRect(x: i32, y: i32) Rect {
    return .{ .x = x + pad + 8, .y = editorTop(y) + speed_h + curve_head_h + 10, .w = graph_w, .h = graph_h };
}

/// Speed stepper geometry: a Default pill, then one container split into
/// minus / value / plus zones — the Zoolander duration stepper shape.
const StepGeo = struct {
    def: Rect,
    box: Rect,
    minus: Rect,
    value: Rect,
    plus: Rect,
};

fn stepGeo(x: i32, w: i32, ry: i32) StepGeo {
    const right = x + w - pad - 8;
    const box = Rect{ .x = right - step_box_w, .y = ry + 4, .w = step_box_w, .h = step_box_h };
    const def = Rect{ .x = box.x - 8 - pill_w, .y = ry + 6, .w = pill_w, .h = pill_h };
    const minus = Rect{ .x = box.x, .y = box.y, .w = step_zone, .h = box.h };
    const value = Rect{ .x = box.x + step_zone, .y = box.y, .w = step_box_w - 2 * step_zone, .h = box.h };
    const plus = Rect{ .x = box.x + step_box_w - step_zone, .y = box.y, .w = step_zone, .h = box.h };
    return .{ .def = def, .box = box, .minus = minus, .value = value, .plus = plus };
}

/// Preset-chip wrapping, computed identically for paint and hit. Fills
/// `out` in order and returns the count placed. A card too narrow for the
/// right column paints no chips at all, so it offers no chip hits either.
fn presetChipRects(c: ?*cairo.cairo_t, x: i32, w: i32, gr: Rect, out: *[preset_names.len]Rect) usize {
    const col_x = gr.x + gr.w + 16;
    const col_w = x + w - pad - col_x;
    if (col_w <= 140) return 0;
    var n: usize = 0;
    var chip_y = gr.y + 40;
    var chip_x = col_x;
    for (preset_names, 0..) |nm, i| {
        const cw = ui_paint.textWidthPx(c, nm, 10, 500) + 20;
        if (chip_x + cw > col_x + col_w and chip_x > col_x) {
            chip_x = col_x;
            chip_y += 30;
        }
        out[n] = Rect{ .x = chip_x, .y = chip_y, .w = cw, .h = 24 };
        n += 1;
        chip_x += cw + 6;
        _ = i;
    }
    return n;
}

fn styleChipRect(x: i32, w: i32, ry: i32, i: usize, n: usize) Rect {
    const inner_x = x + pad;
    const inner_w = w - 2 * pad;
    const nn: i32 = @intCast(n);
    const cw = @divTrunc((inner_w - 16) - (nn - 1) * 8, nn);
    return .{
        .x = inner_x + 8 + @as(i32, @intCast(i)) * (cw + 8),
        .y = ry + 30,
        .w = cw,
        .h = 24,
    };
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

/// Draw a cubic Bézier line in `r` from the four control points. The graph
/// shows `y ∈ [-0.25, 1.25]` so overshot curves stay inside the box.
fn curvePath(c: ?*cairo.cairo_t, r: Rect, p: [4]f64) void {
    const cr = c orelse return;
    const t = common.Theme;
    const padx: f64 = 12;
    const pady: f64 = 10;
    const x0 = @as(f64, @floatFromInt(r.x)) + padx;
    const y0 = @as(f64, @floatFromInt(r.y + r.h)) - pady;
    const wd = @as(f64, @floatFromInt(r.w)) - 2 * padx;
    const ht = @as(f64, @floatFromInt(r.h)) - 2 * pady;
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
    cairo.cairo_move_to(cr, mapx(0, x0, wd), mapy(0, y0, ht, lo, hi));
    cairo.cairo_curve_to(
        cr,
        mapx(p[0], x0, wd),
        mapy(p[1], y0, ht, lo, hi),
        mapx(p[2], x0, wd),
        mapy(p[3], y0, ht, lo, hi),
        mapx(1, x0, wd),
        mapy(1, y0, ht, lo, hi),
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
    const wd = @as(f64, @floatFromInt(r.w)) - 2 * padx;
    const ht = @as(f64, @floatFromInt(r.h)) - 2 * pady;
    const lo: f64 = -0.25;
    const hi: f64 = 1.25;
    const cx = p[which * 2];
    const cy = p[which * 2 + 1];
    const px = x0 + cx * wd;
    const py = y0 - (cy - lo) / (hi - lo) * ht;
    cairo.cairo_save(cr);
    cairo.cairo_arc(cr, px, py, 5.0, 0, std.math.tau);
    cairo.cairo_set_source_rgba(cr, t.bg_r, t.bg_g, t.bg_b, 1.0);
    cairo.cairo_fill(cr);
    cairo.cairo_arc(cr, px, py, 4.0, 0, std.math.tau);
    cairo.cairo_set_source_rgba(cr, t.acc_r, t.acc_g, t.acc_b, 1.0);
    cairo.cairo_fill(cr);
    cairo.cairo_restore(cr);
}

fn handlePos(r: Rect, cp: [4]f64, which: usize) struct { x: f64, y: f64 } {
    const padx: f64 = 12;
    const pady: f64 = 10;
    const x0 = @as(f64, @floatFromInt(r.x)) + padx;
    const y0 = @as(f64, @floatFromInt(r.y + r.h)) - pady;
    const wd = @as(f64, @floatFromInt(r.w)) - 2 * padx;
    const ht = @as(f64, @floatFromInt(r.h)) - 2 * pady;
    const lo: f64 = -0.25;
    const hi: f64 = 1.25;
    return .{
        .x = x0 + cp[which * 2] * wd,
        .y = y0 - (cp[which * 2 + 1] - lo) / (hi - lo) * ht,
    };
}

fn defaultPill(c: ?*cairo.cairo_t, x: i32, y: i32, hovered: bool) void {
    const t = common.Theme;
    ui_paint.glassBox(c, @floatFromInt(x), @floatFromInt(y), @floatFromInt(pill_w), @floatFromInt(pill_h), 12, t.text_r, t.text_g, t.text_b, if (hovered) 0.14 else 0.07);
    const tw = ui_paint.textWidthPx(c, "Default", 10, 500);
    ui_paint.showText(c, @as(f64, @floatFromInt(x + @divTrunc(pill_w - tw, 2))), @floatFromInt(y + 16), "Default", 10, 500, t.text_r, t.text_g, t.text_b, 0.62);
}

// The row header plus its inline editor. `x`,`y` is the row rect inside the
// card (the y `placeCards` gave this entry), `w` the card width.

pub fn paint(c: ?*cairo.cairo_t, x: i32, y: i32, w: i32, entry: u8, px: f64, py: f64) void {
    const ei: usize = entry;
    if (ei >= entry_count) return;
    const t = common.Theme;
    const r = Rect{ .x = x, .y = y, .w = w, .h = row_h };
    const is_open = open == @as(i32, entry);
    const en = data.animEnabled(nameOf(ei));
    const inherited = data.animIsInherited(nameOf(ei));

    // Hover tint on the whole closed row, like the Zoolander leaves.
    if (!is_open and inRect(px, py, r)) {
        ui_paint.glassBox(c, @floatFromInt(r.x + 4), @floatFromInt(r.y + 2), @floatFromInt(r.w - 8), @floatFromInt(r.h - 4), 8, t.acc_r, t.acc_g, t.acc_b, 0.035);
    }

    ui_paint.showText(
        c,
        @floatFromInt(r.x + pad),
        @as(f64, @floatFromInt(r.y)) + 22,
        data.k_anim_entries[ei].label,
        14,
        500,
        t.text_r,
        t.text_g,
        t.text_b,
        if (en) 0.93 else 0.46,
    );
    var info_buf: [128]u8 = undefined;
    const info: []const u8 = if (inherited)
        "Inherited (3.0, default)"
    else blk: {
        const speed = data.animSpeed(nameOf(ei));
        const curve = data.animCurve(nameOf(ei));
        const style = data.animStyle(nameOf(ei));
        const custom = g_curve_set[ei];
        break :blk if (style.len > 0)
            (if (custom)
                std.fmt.bufPrint(&info_buf, "{d:.1}, {s} (custom), {s}", .{ speed, curve, style }) catch ""
            else
                std.fmt.bufPrint(&info_buf, "{d:.1}, {s}, {s}", .{ speed, curve, style }) catch "")
        else
            (if (custom)
                std.fmt.bufPrint(&info_buf, "{d:.1}, {s} (custom)", .{ speed, curve }) catch ""
            else
                std.fmt.bufPrint(&info_buf, "{d:.1}, {s}", .{ speed, curve }) catch "");
    };
    if (info.len > 0) ui_paint.showText(
        c,
        @floatFromInt(r.x + pad),
        @as(f64, @floatFromInt(r.y)) + 42,
        info,
        11,
        400,
        t.text_r,
        t.text_g,
        t.text_b,
        if (!en) 0.20 else if (inherited) 0.40 else 0.50,
    );

    // Curve thumbnail.
    const tr = thumbRect(r);
    ui_paint.glassBox(c, @floatFromInt(tr.x), @floatFromInt(tr.y), @floatFromInt(tr.w), @floatFromInt(tr.h), 6, t.text_r, t.text_g, t.text_b, 0.06);
    curvePath(c, tr, effectiveCurve(ei));

    const sr = switchRect(r);
    ui_paint.paintSwitch(c, sr.x, sr.y, sr.w, sr.h, en);
    const cr = chevronRect(r);
    chevron(c, cr.x + @divTrunc(cr.w, 2), cr.y + @divTrunc(cr.h, 2), is_open);

    if (is_open) {
        g_x = x;
        g_y = y;
        g_w = w;
        paintEditor(c, x, y, w, ei, px, py);
    }
}

fn paintEditor(c: ?*cairo.cairo_t, x: i32, y: i32, w: i32, ei: usize, px: f64, py: f64) void {
    const t = common.Theme;
    const top = editorTop(y);
    const inner_x = x + pad;

    // Inset well holding the whole editor.
    ui_paint.glassBox(c, @floatFromInt(x + 8), @floatFromInt(top + 4), @floatFromInt(w - 16), @floatFromInt(editor_h - 8), 10, t.text_r, t.text_g, t.text_b, 0.045);

    var ry = top + 8;

    // Speed: Default, then one stepper with three evenly weighted zones.
    // Hyprland's speed is a factor, not a duration — the line reads
    // `name, on, speed, …` — so the value is the bare number.
    ui_paint.showText(c, @floatFromInt(inner_x + 8), @floatFromInt(ry + 22), "Speed", 12, 500, t.text_r, t.text_g, t.text_b, 0.72);
    const sg = stepGeo(x, w, ry);
    defaultPill(c, sg.def.x, sg.def.y, inRect(px, py, sg.def));
    ui_paint.glassBox(c, @floatFromInt(sg.box.x), @floatFromInt(sg.box.y), @floatFromInt(sg.box.w), @floatFromInt(sg.box.h), 6, t.text_r, t.text_g, t.text_b, 0.07);
    if (inRect(px, py, sg.minus))
        ui_paint.glassBox(c, @floatFromInt(sg.minus.x), @floatFromInt(sg.minus.y), @floatFromInt(sg.minus.w), @floatFromInt(sg.minus.h), 6, t.text_r, t.text_g, t.text_b, 0.08);
    if (inRect(px, py, sg.plus))
        ui_paint.glassBox(c, @floatFromInt(sg.plus.x), @floatFromInt(sg.plus.y), @floatFromInt(sg.plus.w), @floatFromInt(sg.plus.h), 6, t.text_r, t.text_g, t.text_b, 0.08);
    ui_paint.glassBox(c, @floatFromInt(sg.value.x), @floatFromInt(sg.box.y + 6), 1, @floatFromInt(step_box_h - 12), 0, t.text_r, t.text_g, t.text_b, 0.1);
    ui_paint.glassBox(c, @floatFromInt(sg.value.x + sg.value.w), @floatFromInt(sg.box.y + 6), 1, @floatFromInt(step_box_h - 12), 0, t.text_r, t.text_g, t.text_b, 0.1);
    const minus_tw = ui_paint.textWidthPx(c, "−", 15, 500);
    ui_paint.showText(c, @as(f64, @floatFromInt(sg.minus.x + @divTrunc(sg.minus.w - minus_tw, 2))), @floatFromInt(sg.box.y + 19), "−", 15, 500, t.text_r, t.text_g, t.text_b, 0.7);
    var val_buf: [32]u8 = undefined;
    const val = std.fmt.bufPrint(&val_buf, "{d:.1}", .{data.animSpeed(nameOf(ei))}) catch "";
    const val_tw = ui_paint.textWidthPx(c, val, 11.5, 500);
    ui_paint.showText(c, @as(f64, @floatFromInt(sg.value.x + @divTrunc(sg.value.w - val_tw, 2))), @floatFromInt(sg.box.y + 19), val, 11.5, 500, t.text_r, t.text_g, t.text_b, 0.86);
    const plus_tw = ui_paint.textWidthPx(c, "+", 15, 500);
    ui_paint.showText(c, @as(f64, @floatFromInt(sg.plus.x + @divTrunc(sg.plus.w - plus_tw, 2))), @floatFromInt(sg.box.y + 19), "+", 15, 500, t.text_r, t.text_g, t.text_b, 0.7);
    ry += speed_h;

    // Curve head: the entry's stored name tells you what is persisted;
    // "(dragged)" marks a table that will be written back as `eh_custom`.
    var head_buf: [64]u8 = undefined;
    const head = if (g_curve_set[ei])
        std.fmt.bufPrint(&head_buf, "Curve · {s} (dragged)", .{data.animCurve(nameOf(ei))}) catch "Curve"
    else
        std.fmt.bufPrint(&head_buf, "Curve · {s}", .{data.animCurve(nameOf(ei))}) catch "Curve";
    ui_paint.showText(c, @floatFromInt(inner_x + 8), @floatFromInt(ry + 22), head, 12, 500, t.text_r, t.text_g, t.text_b, 0.72);
    const curve_def = Rect{ .x = x + w - pad - 8 - pill_w, .y = ry + 6, .w = pill_w, .h = pill_h };
    defaultPill(c, curve_def.x, curve_def.y, inRect(px, py, curve_def));
    ry += curve_head_h;

    // Graph.
    const gr = graphRect(x, y);
    ui_paint.glassBox(c, @floatFromInt(gr.x), @floatFromInt(gr.y), @floatFromInt(gr.w), @floatFromInt(gr.h), 8, t.text_r, t.text_g, t.text_b, 0.06);
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
    const cp = effectiveCurve(ei);
    curvePath(c, gr, cp);
    curvePoint(c, gr, cp, 0);
    curvePoint(c, gr, cp, 1);

    // Right column: expression, presets, preview.
    const col_x = gr.x + gr.w + 16;
    const col_w = x + w - pad - col_x;
    if (col_w > 140) {
        var ebuf: [96]u8 = undefined;
        const expr = std.fmt.bufPrint(&ebuf, "cubic-bezier({d:.2}, {d:.2}, {d:.2}, {d:.2})", .{ cp[0], cp[1], cp[2], cp[3] }) catch "";
        ui_paint.glassBox(c, @floatFromInt(col_x), @floatFromInt(gr.y), @floatFromInt(col_w), 28, 6, t.text_r, t.text_g, t.text_b, 0.08);
        ui_paint.showText(c, @floatFromInt(col_x + 10), @floatFromInt(gr.y + 18), expr, 10.5, 400, t.text_r, t.text_g, t.text_b, 0.8);

        // Preset chips: the shipped Hyprland curve names.
        var chips: [preset_names.len]Rect = undefined;
        const n = presetChipRects(c, x, w, gr, &chips);
        const stored = data.animCurve(nameOf(ei));
        for (0..n) |i| {
            const cr2 = chips[i];
            const chosen = !g_curve_set[ei] and std.mem.eql(u8, stored, preset_names[i]);
            const hov = inRect(px, py, cr2);
            ui_paint.glassBox(c, @floatFromInt(cr2.x), @floatFromInt(cr2.y), @floatFromInt(cr2.w), @floatFromInt(cr2.h), 12, if (chosen) t.acc_r else t.text_r, if (chosen) t.acc_g else t.text_g, if (chosen) t.acc_b else t.text_b, if (chosen) 0.22 else if (hov) 0.14 else 0.07);
            ui_paint.showText(c, @floatFromInt(cr2.x + 10), @floatFromInt(cr2.y + 16), preset_names[i], 10, if (chosen) 600 else 500, t.text_r, t.text_g, t.text_b, if (chosen) 0.95 else 0.7);
        }

        // Preview strip.
        const pv_y = gr.y + gr.h - 34;
        var pl: [48]u8 = undefined;
        const plabel = std.fmt.bufPrint(&pl, "Preview · {d:.1}×", .{data.animSpeed(nameOf(ei))}) catch "Preview";
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
    }
    ry += curve_body_h;

    // Style chips: the entry's own list, led by the Default (empty) style.
    const chips = styleChips(ei);
    const sel_style = data.animStyle(nameOf(ei));
    var sel: usize = 0;
    for (0..chips.n) |i| {
        if (std.mem.eql(u8, chips.vals[i], sel_style)) {
            sel = i;
            break;
        }
    }
    ui_paint.showText(c, @floatFromInt(inner_x + 8), @floatFromInt(ry + 20), "Style", 12, 500, t.text_r, t.text_g, t.text_b, 0.72);
    for (0..chips.n) |i| {
        const sr2 = styleChipRect(x, w, ry, i, chips.n);
        const chosen = i == sel;
        const hov = inRect(px, py, sr2);
        const label = if (i == 0) "Default" else chips.vals[i];
        ui_paint.glassBox(c, @floatFromInt(sr2.x), @floatFromInt(sr2.y), @floatFromInt(sr2.w), @floatFromInt(sr2.h), 6, if (chosen) t.acc_r else t.text_r, if (chosen) t.acc_g else t.text_g, if (chosen) t.acc_b else t.text_b, if (chosen) 0.22 else if (hov) 0.12 else 0.055);
        const lw = ui_paint.textWidthPx(c, label, 10, if (chosen) 600 else 400);
        ui_paint.showText(c, @as(f64, @floatFromInt(sr2.x + @divTrunc(sr2.w, 2))) - @as(f64, @floatFromInt(@divTrunc(lw, 2))), @floatFromInt(sr2.y + 16), label, 10, if (chosen) 600 else 400, t.text_r, t.text_g, t.text_b, if (chosen) 0.95 else 0.62);
    }
    ry += style_h;
}

// Map the pointer into a curve point. `which` selects P1 or P2; x stays in
// [0, 1] (a cubic Bézier must), y may overshoot within [-1, 2].
fn curveFromPointer(px: f64, py: f64, r: Rect, which: usize) [2]f64 {
    _ = which;
    const padx: f64 = 12;
    const pady: f64 = 10;
    const x0 = @as(f64, @floatFromInt(r.x)) + padx;
    const y0 = @as(f64, @floatFromInt(r.y + r.h)) - pady;
    const wd = @as(f64, @floatFromInt(r.w)) - 2 * padx;
    const ht = @as(f64, @floatFromInt(r.h)) - 2 * pady;
    const lo: f64 = -0.25;
    const hi: f64 = 1.25;
    const cx = std.math.clamp((px - x0) / wd, 0.0, 1.0);
    const cy = std.math.clamp(lo + (y0 - py) / ht * (hi - lo), -1.0, 2.0);
    return .{ cx, cy };
}

pub const Action = union(enum) {
    expand: u8,
    toggle: u8,
    speed_step: struct { entry: u8, delta: f64 },
    speed_default: u8,
    curve_default: u8,
    curve_drag: struct { entry: u8, point: u8 },
    curve_preset: struct { entry: u8, idx: u8 },
    style: struct { entry: u8, idx: u8 },
    none,
};

pub fn hit(x: i32, y: i32, w: i32, entry: u8, px: f64, py: f64) Action {
    const ei: usize = entry;
    if (ei >= entry_count) return .none;
    const r = Rect{ .x = x, .y = y, .w = w, .h = row_h };
    if (inRect(px, py, switchRect(r))) return .{ .toggle = entry };
    if (inRect(px, py, chevronRect(r))) return .{ .expand = entry };
    if (inRect(px, py, r)) return .{ .expand = entry };

    if (open != @as(i32, entry)) return .none;

    // Speed stepper.
    const top = editorTop(y);
    var ry = top + 8;
    const sg = stepGeo(x, w, ry);
    if (inRect(px, py, sg.def)) return .{ .speed_default = entry };
    if (inRect(px, py, sg.minus)) return .{ .speed_step = .{ .entry = entry, .delta = -speed_step } };
    if (inRect(px, py, sg.plus)) return .{ .speed_step = .{ .entry = entry, .delta = speed_step } };
    ry += speed_h;

    // Curve Default.
    const curve_def = Rect{ .x = x + w - pad - 8 - pill_w, .y = ry + 6, .w = pill_w, .h = pill_h };
    if (inRect(px, py, curve_def)) return .{ .curve_default = entry };
    ry += curve_head_h;

    // Graph: control points first, with a generous hit radius.
    const gr = graphRect(x, y);
    const cp = effectiveCurve(ei);
    for (0..2) |k| {
        const hp = handlePos(gr, cp, k);
        if (@abs(px - hp.x) <= 10 and @abs(py - hp.y) <= 10) {
            return .{ .curve_drag = .{ .entry = entry, .point = @intCast(k) } };
        }
    }

    // Preset chips.
    var chips: [preset_names.len]Rect = undefined;
    const n = presetChipRects(null, x, w, gr, &chips);
    for (0..n) |i| {
        if (inRect(px, py, chips[i])) return .{ .curve_preset = .{ .entry = entry, .idx = @intCast(i) } };
    }
    ry += curve_body_h;

    // Style chips.
    const sc = styleChips(ei);
    for (0..sc.n) |i| {
        if (inRect(px, py, styleChipRect(x, w, ry, i, sc.n))) return .{ .style = .{ .entry = entry, .idx = @intCast(i) } };
    }
    return .none;
}

/// Apply an action. Returns true when the page height changed and the
/// caller must relayout.
pub fn apply(a: Action) bool {
    switch (a) {
        .none => return false,
        .expand => |e| {
            open = if (open == @as(i32, e)) -1 else @as(i32, e);
            drag_point = -1;
            return true;
        },
        .toggle => |e| {
            if (e >= entry_count) return false;
            data.setAnimEnabled(nameOf(e), !data.animEnabled(nameOf(e)));
            return false;
        },
        .speed_step => |st| {
            if (st.entry >= entry_count) return false;
            const next = std.math.clamp(data.animSpeed(nameOf(st.entry)) + st.delta, speed_min, speed_max);
            data.setAnimSpeed(nameOf(st.entry), next);
            return false;
        },
        .speed_default => |e| {
            if (e >= entry_count) return false;
            data.setAnimSpeed(nameOf(e), speed_default);
            return false;
        },
        .curve_default => |e| {
            if (e >= entry_count) return false;
            g_curve_set[e] = false;
            data.setAnimCurve(nameOf(e), "default");
            return false;
        },
        .curve_drag => |d| {
            if (d.entry >= entry_count) return false;
            if (!g_curve_set[d.entry]) {
                // Seed the table from the preset the entry was showing, so
                // the first grab does not jump the handle.
                g_curve[d.entry] = effectiveCurve(d.entry);
                g_curve_set[d.entry] = true;
                data.setAnimCurve(nameOf(d.entry), "eh_custom");
            }
            drag_point = d.point;
            open = @as(i32, d.entry);
            return false;
        },
        .curve_preset => |cp| {
            if (cp.entry >= entry_count or cp.idx >= preset_names.len) return false;
            g_curve_set[cp.entry] = false;
            data.setAnimCurve(nameOf(cp.entry), preset_names[cp.idx]);
            return false;
        },
        .style => |s| {
            if (s.entry >= entry_count) return false;
            const chips = styleChips(s.entry);
            if (s.idx >= chips.n) return false;
            data.setAnimStyle(nameOf(s.entry), chips.vals[s.idx]);
            return false;
        },
    }
}

/// Follow a curve-handle drag. Returns true when a drag was in progress.
pub fn motion(px: f64, py: f64) bool {
    if (drag_point < 0 or open < 0 or open >= entry_count) return false;
    const gr = graphRect(g_x, g_y);
    const ei: usize = @intCast(open);
    const cp = curveFromPointer(px, py, gr, @intCast(drag_point));
    const k: usize = @intCast(drag_point * 2);
    g_curve[ei][k] = cp[0];
    g_curve[ei][k + 1] = cp[1];
    return true;
}

pub fn endDrag() void {
    drag_point = -1;
}

pub fn isDragging() bool {
    return drag_point >= 0;
}

test "hyprland-anim-curve: every row can open and the editor is the extra height" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 31), entry_count);
    try t.expectEqual(@as(i32, 0), extraFor(0));
    open = 5;
    defer reset();
    try t.expectEqual(editor_h, extraFor(5));
    try t.expectEqual(@as(i32, 0), extraFor(4));
    try t.expectEqual(@as(i32, 0), extraFor(6));
    // The chevron and switch live inside the 60px header band.
    const r = Rect{ .x = 0, .y = 0, .w = 600, .h = row_h };
    try t.expect(switchRect(r).y + switch_h <= row_h);
    try t.expect(thumbRect(r).x < switchRect(r).x);
}

test "hyprland-anim-curve: style chips lead with Default and split the table list" {
    const t = std.testing;
    const global = styleChips(0); // "global": no styles
    try t.expectEqual(@as(usize, 1), global.n);
    try t.expectEqualStrings("", global.vals[0]);
    const layers_in = styleChips(6); // "layersIn": slide, slidevert, fade
    try t.expectEqual(@as(usize, 4), layers_in.n);
    try t.expectEqualStrings("slide", layers_in.vals[1]);
    try t.expectEqualStrings("slidevert", layers_in.vals[2]);
    try t.expectEqualStrings("fade", layers_in.vals[3]);
    // Preset chip labels are all real curve names.
    for (preset_names) |nm| {
        try t.expect(data.bezierForCurve(nm) != null);
    }
}

test "hyprland-anim-curve: apply changes only what it names" {
    const t = std.testing;
    defer reset();
    defer data.clearAnimStateForTests();
    // Expand/collapse is the only action that changes layout; value pokes
    // return false and must still land on the data module.
    try t.expect(apply(.{ .expand = 3 }));
    try t.expectEqual(@as(i32, 3), open);
    try t.expect(apply(.{ .expand = 3 }));
    try t.expectEqual(@as(i32, -1), open);
    // The shipped table has no stored lines in a test process, so entries
    // start inherited: default curve, speed 3.0.
    try t.expectApproxEqAbs(@as(f64, 3.0), data.animSpeed("global"), 0.0001);
    try t.expectEqualStrings("default", data.animCurve("global"));
    try t.expectApproxEqAbs(effectiveCurve(0)[0], 0.25, 0.0001);
    // A preset chip picks a real Hyprland curve name.
    try t.expect(!apply(.{ .curve_preset = .{ .entry = 0, .idx = 1 } })); // linear
    try t.expectEqualStrings("linear", data.animCurve("global"));
    try t.expectApproxEqAbs(effectiveCurve(0)[0], 0.0, 0.0001);
    // Dragging then seeds the table and names it `eh_custom`.
    try t.expect(!apply(.{ .curve_drag = .{ .entry = 0, .point = 0 } }));
    try t.expectEqualStrings("eh_custom", data.animCurve("global"));
    try t.expect(isDragging());
    endDrag();
    try t.expect(!isDragging());
    // Curve Default clears the hand-drawn table and restores the name.
    try t.expect(!apply(.{ .curve_default = 0 }));
    try t.expectEqualStrings("default", data.animCurve("global"));
    // Speed steps round-trip through the f64 field.
    try t.expect(!apply(.{ .speed_step = .{ .entry = 0, .delta = 0.5 } }));
    try t.expectApproxEqAbs(@as(f64, 3.5), data.animSpeed("global"), 0.0001);
    try t.expect(!apply(.{ .speed_default = 0 }));
    try t.expectApproxEqAbs(@as(f64, 3.0), data.animSpeed("global"), 0.0001);
    // Style: idx 0 is the empty (Default) style.
    try t.expect(!apply(.{ .style = .{ .entry = 2, .idx = 1 } })); // windowsIn -> slide
    try t.expectEqualStrings("slide", data.animStyle("windowsIn"));
}
