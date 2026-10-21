const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const hyprland_data = @import("hyprland_data.zig");
const hyprland_tab = @import("hyprland_tab.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;

// Bezier curve editor.
// card at kContentTop+20 with a 230px grid, clamped P1/P2 handles, live
// coordinate readout, Close/Save buttons.
//
// Deviations (documented, matching `hyprland_data`):
// * The popup x follows `(contentW - popW) / 2`, which
//   ignores `contentX`. Paint and hit-test use the same rect so they agree
//   with each other.
// * Save only ever records the curve *name* `eh_custom` (there is no
//   `bezier = …` writer); the P1/P2 values themselves are never
//   persisted.

fn gridOrigin(content_w: i32) struct { gx: i32, gy: i32, pop_x: i32, pop_y: i32 } {
    const r = hyprland_tab.bezierPopupRect(content_w);
    return .{
        .gx = r.x + hyprland_tab.bezier_grid_off_x,
        .gy = r.y + hyprland_tab.bezier_grid_off_y,
        .pop_x = r.x,
        .pop_y = r.y,
    };
}

fn handlePos(gx: i32, gy: i32, bx: f64, by: f64) struct { x: f64, y: f64 } {
    const gs: f64 = @floatFromInt(hyprland_tab.bezier_grid_size);
    return .{
        .x = @as(f64, @floatFromInt(gx)) + bx * gs,
        .y = @as(f64, @floatFromInt(gy)) + (1.0 - by) * gs,
    };
}

pub fn paint(content_w: i32, px: f64, py: f64, c: ?*cairo.cairo_t, glass_ov: f64) void {
    if (!hyprland_tab.bezier_open) return;
    const cr = c orelse return;
    const t = common.Theme;
    const g = gridOrigin(content_w);
    const pop_x = g.pop_x;
    const pop_y = g.pop_y;
    const gx = g.gx;
    const gy = g.gy;
    const gs = hyprland_tab.bezier_grid_size;

    ui_paint.card(cr, @floatFromInt(pop_x), @floatFromInt(pop_y), @floatFromInt(hyprland_tab.bezier_pop_w), @floatFromInt(hyprland_tab.bezier_pop_h), glass_ov);
    ui_paint.showText(cr, @floatFromInt(pop_x + 16), @floatFromInt(pop_y + 24), "Bezier Curve Editor", 14, 400, t.text_r, t.text_g, t.text_b, 0.93);

    // Grid body + 5x5 lines + diagonal.
    cairo.cairo_save(cr);
    cairo.cairo_set_source_rgba(cr, 0.08, 0.08, 0.08, 0.50);
    cairo.cairo_rectangle(cr, @floatFromInt(gx), @floatFromInt(gy), @floatFromInt(gs), @floatFromInt(gs));
    cairo.cairo_fill(cr);
    cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.10);
    cairo.cairo_set_line_width(cr, 0.5);
    var i: i32 = 0;
    while (i <= 4) : (i += 1) {
        const p = @as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(gs)) / 4.0;
        cairo.cairo_move_to(cr, @as(f64, @floatFromInt(gx)) + p, @floatFromInt(gy));
        cairo.cairo_line_to(cr, @as(f64, @floatFromInt(gx)) + p, @as(f64, @floatFromInt(gy + gs)));
        cairo.cairo_move_to(cr, @floatFromInt(gx), @as(f64, @floatFromInt(gy)) + p);
        cairo.cairo_line_to(cr, @as(f64, @floatFromInt(gx + gs)), @as(f64, @floatFromInt(gy)) + p);
    }
    cairo.cairo_stroke(cr);
    cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.15);
    cairo.cairo_set_line_width(cr, 0.5);
    cairo.cairo_move_to(cr, @floatFromInt(gx), @floatFromInt(gy + gs));
    cairo.cairo_line_to(cr, @floatFromInt(gx + gs), @floatFromInt(gy));
    cairo.cairo_stroke(cr);
    cairo.cairo_restore(cr);

    const p1 = handlePos(gx, gy, hyprland_tab.bezier_p1x, hyprland_tab.bezier_p1y);
    const p2 = handlePos(gx, gy, hyprland_tab.bezier_p2x, hyprland_tab.bezier_p2y);
    const cp1x = std.math.clamp(p1.x, @as(f64, @floatFromInt(gx)), @as(f64, @floatFromInt(gx + gs)));
    const cp1y = std.math.clamp(p1.y, @as(f64, @floatFromInt(gy)), @as(f64, @floatFromInt(gy + gs)));
    const cp2x = std.math.clamp(p2.x, @as(f64, @floatFromInt(gx)), @as(f64, @floatFromInt(gx + gs)));
    const cp2y = std.math.clamp(p2.y, @as(f64, @floatFromInt(gy)), @as(f64, @floatFromInt(gy + gs)));

    // Handle spokes.
    cairo.cairo_save(cr);
    cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.25);
    cairo.cairo_set_line_width(cr, 1);
    cairo.cairo_move_to(cr, @floatFromInt(gx), @floatFromInt(gy + gs));
    cairo.cairo_line_to(cr, cp1x, cp1y);
    cairo.cairo_stroke(cr);
    cairo.cairo_move_to(cr, @floatFromInt(gx + gs), @floatFromInt(gy));
    cairo.cairo_line_to(cr, cp2x, cp2y);
    cairo.cairo_stroke(cr);
    // Curve.
    cairo.cairo_set_source_rgba(cr, t.acc_r, t.acc_g, t.acc_b, 0.85);
    cairo.cairo_set_line_width(cr, 2.5);
    cairo.cairo_move_to(cr, @floatFromInt(gx), @floatFromInt(gy + gs));
    cairo.cairo_curve_to(cr, cp1x, cp1y, cp2x, cp2y, @floatFromInt(gx + gs), @floatFromInt(gy));
    cairo.cairo_stroke(cr);
    // Endpoints.
    cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.50);
    cairo.cairo_arc(cr, @floatFromInt(gx), @floatFromInt(gy + gs), 4, 0, std.math.pi * 2.0);
    cairo.cairo_fill(cr);
    cairo.cairo_arc(cr, @floatFromInt(gx + gs), @floatFromInt(gy), 4, 0, std.math.pi * 2.0);
    cairo.cairo_fill(cr);
    // Handles (r7 active, r6 idle).
    cairo.cairo_set_source_rgba(cr, t.acc_r, t.acc_g, t.acc_b, if (hyprland_tab.bezier_drag == 0) 0.95 else 0.60);
    cairo.cairo_arc(cr, cp1x, cp1y, if (hyprland_tab.bezier_drag == 0) 7 else 6, 0, std.math.pi * 2.0);
    cairo.cairo_fill(cr);
    cairo.cairo_set_source_rgba(cr, t.acc_r, t.acc_g, t.acc_b, if (hyprland_tab.bezier_drag == 1) 0.95 else 0.60);
    cairo.cairo_arc(cr, cp2x, cp2y, if (hyprland_tab.bezier_drag == 1) 7 else 6, 0, std.math.pi * 2.0);
    cairo.cairo_fill(cr);
    cairo.cairo_restore(cr);

    // Axis labels + coordinate readout.
    ui_paint.showText(cr, @floatFromInt(gx - 8), @floatFromInt(gy + gs + 14), "0", 10, 400, t.text_r, t.text_g, t.text_b, 0.45);
    ui_paint.showText(cr, @floatFromInt(gx + gs - 6), @floatFromInt(gy + gs + 14), "1", 10, 400, t.text_r, t.text_g, t.text_b, 0.45);
    ui_paint.showText(cr, @floatFromInt(gx - 16), @floatFromInt(gy + gs), "0", 10, 400, t.text_r, t.text_g, t.text_b, 0.45);
    ui_paint.showText(cr, @floatFromInt(gx - 16), @floatFromInt(gy - 3), "1", 10, 400, t.text_r, t.text_g, t.text_b, 0.45);
    var coord: [128]u8 = undefined;
    const cs = std.fmt.bufPrint(&coord, "P1: ({d:.2}, {d:.2})    P2: ({d:.2}, {d:.2})", .{ hyprland_tab.bezier_p1x, hyprland_tab.bezier_p1y, hyprland_tab.bezier_p2x, hyprland_tab.bezier_p2y }) catch "";
    ui_paint.showText(cr, @floatFromInt(pop_x + 16), @floatFromInt(gy + gs + 36), cs, 11, 400, t.text_r, t.text_g, t.text_b, 0.65);

    const close_x = pop_x + hyprland_tab.bezier_pop_w - 80 - 16;
    const close_y = pop_y + hyprland_tab.bezier_pop_h - 28 - 14;
    const save_x = close_x - 80 - 8;
    ui_paint.paintBtn(cr, close_x, close_y, 80, 28, "Close", inBtn(px, py, close_x, close_y));
    ui_paint.paintBtn(cr, save_x, close_y, 80, 28, "Save", inBtn(px, py, save_x, close_y));
}

fn inBtn(px: f64, py: f64, x: i32, y: i32) bool {
    return px >= @as(f64, @floatFromInt(x)) and px < @as(f64, @floatFromInt(x + 80)) and
        py >= @as(f64, @floatFromInt(y)) and py < @as(f64, @floatFromInt(y + 28));
}

/// Pointer-down. Returns true when consumed. `commit` is set when the curve
/// name was recorded and the config must be written + reloaded.
pub fn hitDown(content_w: i32, px: f64, py: f64, commit: *bool) bool {
    if (!hyprland_tab.bezier_open) return false;
    const g = gridOrigin(content_w);
    const pop_x = g.pop_x;
    const pop_y = g.pop_y;
    const close_x = pop_x + hyprland_tab.bezier_pop_w - 80 - 16;
    const close_y = pop_y + hyprland_tab.bezier_pop_h - 28 - 14;
    const save_x = close_x - 80 - 8;
    if (inBtn(px, py, close_x, close_y)) {
        hyprland_tab.bezier_open = false;
        hyprland_tab.bezier_drag = -1;
        return true;
    }
    if (inBtn(px, py, save_x, close_y)) {
        const ei = hyprland_tab.anim_edit_idx;
        if (ei >= 0 and ei < hyprland_data.k_anim_entries.len) {
            hyprland_data.setAnimCurve(hyprland_data.k_anim_entries[@intCast(ei)].name, "eh_custom");
            commit.* = true;
        }
        hyprland_tab.bezier_open = false;
        hyprland_tab.bezier_drag = -1;
        return true;
    }
    const p1 = handlePos(g.gx, g.gy, hyprland_tab.bezier_p1x, hyprland_tab.bezier_p1y);
    const p2 = handlePos(g.gx, g.gy, hyprland_tab.bezier_p2x, hyprland_tab.bezier_p2y);
    const dx1 = px - p1.x;
    const dy1 = py - p1.y;
    if (dx1 * dx1 + dy1 * dy1 < 12.0 * 12.0) {
        hyprland_tab.bezier_drag = 0;
        return true;
    }
    const dx2 = px - p2.x;
    const dy2 = py - p2.y;
    if (dx2 * dx2 + dy2 * dy2 < 12.0 * 12.0) {
        hyprland_tab.bezier_drag = 1;
        return true;
    }
    return false;
}

/// Pointer motion while a handle drag is armed. Returns true when a value moved.
pub fn motion(content_w: i32, px: f64, py: f64) bool {
    if (!hyprland_tab.bezier_open or hyprland_tab.bezier_drag < 0) return false;
    const g = gridOrigin(content_w);
    const gs: f64 = @floatFromInt(hyprland_tab.bezier_grid_size);
    const nx = std.math.clamp((px - @as(f64, @floatFromInt(g.gx))) / gs, 0.0, 1.0);
    const ny = std.math.clamp(1.0 - (py - @as(f64, @floatFromInt(g.gy))) / gs, 0.0, 1.0);
    if (hyprland_tab.bezier_drag == 0) {
        hyprland_tab.bezier_p1x = nx;
        hyprland_tab.bezier_p1y = ny;
    } else if (hyprland_tab.bezier_drag == 1) {
        hyprland_tab.bezier_p2x = nx;
        hyprland_tab.bezier_p2y = ny;
    }
    return true;
}

test "settings-hyprland-bezier: grid math clamps at the specified limits" {
    const t = std.testing;
    const r = hyprland_tab.bezierPopupRect(592);
    try t.expectEqual(@as(i32, @divTrunc(592 - 360, 2)), r.x);
    try t.expectEqual(@as(i32, common.content_top + 20), r.y);
    const p = handlePos(100, 100, 0.25, 0.1);
    try t.expectApproxEqAbs(@as(f64, 100 + 0.25 * 230), p.x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 100 + 0.9 * 230), p.y, 1e-9);
}
