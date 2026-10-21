const std = @import("std");

/// Marquee (rubber-band) selection rect logic.

pub const Rect = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
};

/// Enforce the 2px minimum (center-expand) then clamp into `[0,w]x[0,h]`.
pub fn normalizeFinalRect(fx0: *f64, fy0: *f64, fx1: *f64, fy1: *f64, w: i32, h: i32) void {
    if (w <= 0 or h <= 0) return;
    if (fx1.* - fx0.* < 2.0) {
        const m = (fx0.* + fx1.*) * 0.5;
        fx0.* = m - 1.0;
        fx1.* = m + 1.0;
    }
    if (fy1.* - fy0.* < 2.0) {
        const m = (fy0.* + fy1.*) * 0.5;
        fy0.* = m - 1.0;
        fy1.* = m + 1.0;
    }
    const max_x: f64 = @floatFromInt(@max(0, w - 2));
    const w_f: f64 = @floatFromInt(w);
    const max_y: f64 = @floatFromInt(@max(0, h - 2));
    const h_f: f64 = @floatFromInt(h);
    fx0.* = std.math.clamp(fx0.*, 0.0, max_x);
    fx1.* = std.math.clamp(fx1.*, fx0.* + 2.0, w_f);
    fy0.* = std.math.clamp(fy0.*, 0.0, max_y);
    fy1.* = std.math.clamp(fy1.*, fy0.* + 2.0, h_f);
}

pub fn ordered(r: Rect) Rect {
    return .{
        .x0 = @min(r.x0, r.x1),
        .y0 = @min(r.y0, r.y1),
        .x1 = @max(r.x0, r.x1),
        .y1 = @max(r.y0, r.y1),
    };
}

/// Cell-overlap test.
pub fn cellOverlapsRect(cell_x: f64, cell_y: f64, cell_w: f64, cell_h: f64, r: Rect) bool {
    const o = ordered(r);
    return !(cell_x + cell_w < o.x0 or cell_x > o.x1 or cell_y + cell_h < o.y0 or cell_y > o.y1);
}

/// Clamp a marquee drag end into the start layer.
pub fn clampDragEnd(v: f64, extent: i32) f64 {
    if (extent > 0) return std.math.clamp(v, 0.0, @as(f64, @floatFromInt(extent)));
    return v;
}

/// Marquee paint visibility rule: the rect paints while dragging, otherwise the
/// finalized `Fx` rect paints (`desktop_layer` paints `(X0,Y0,X1,Y1)` while
/// dragging else `(Fx0..)`; rect needs w,h >= 2).
pub fn shouldPaintRect(r: Rect) bool {
    const o = ordered(r);
    return o.x1 - o.x0 >= 2.0 and o.y1 - o.y0 >= 2.0;
}

/// Marquee fill/stroke from `desktop_marquee` paint path.
pub const paint_fill = [4]f64{ 0.25, 0.55, 1.0, 0.14 };
pub const paint_stroke = [4]f64{ 0.4, 0.65, 1.0, 0.85 };
pub const paint_dash: [2]f64 = .{ 4.0, 4.0 };

test "marquee: normalize enforces 2px + clamps" {
    const t = std.testing;
    var x0: f64 = 5;
    var y0: f64 = 5;
    var x1: f64 = 5.5;
    var y1: f64 = 5.5;
    normalizeFinalRect(&x0, &y0, &x1, &y1, 800, 600);
    try t.expect(x1 - x0 >= 2.0);
    try t.expect(y1 - y0 >= 2.0);
    var a: f64 = -50;
    var b: f64 = -40;
    var c: f64 = 900;
    var d: f64 = 700;
    normalizeFinalRect(&a, &c, &b, &d, 800, 600);
    try t.expect(a >= 0 and b <= 800 and c >= 0 and d <= 600);
}

test "marquee: overlap + paint rule" {
    const t = std.testing;
    try t.expect(cellOverlapsRect(0, 0, 104, 88, .{ .x0 = 50, .y0 = 50, .x1 = 200, .y1 = 200 }));
    try t.expect(!cellOverlapsRect(500, 500, 104, 88, .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 }));
    try t.expect(shouldPaintRect(.{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 }));
    try t.expect(!shouldPaintRect(.{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 }));
    try t.expectApproxEqAbs(@as(f64, 800), clampDragEnd(900, 800), 1e-9);
}
