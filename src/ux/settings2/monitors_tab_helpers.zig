const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const ui_paint = @import("ui_paint.zig");
const mon = @import("monitors_state.zig");

// Monitors tab layout math.
//
// Same design: one main column at 68% of the content width, positions written
// as `WxH`-style `XxY` strings (an `x` separator, strtol on both sides), an
// arrange canvas whose fit is recomputed from the output rectangles, and the
// drop sequence — resolve collisions, snap to the moved output's
// edges, normalise the origin back to 0,0, then write positions back.
//
// Nothing here allocates: rects are supplied by the caller, and the state
// lives in `monitors_state.State`.

pub const ArrangeRect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

pub const Fit = struct {
    min_x: f64 = 0,
    min_y: f64 = 0,
    span_w: f64 = 1,
    span_h: f64 = 1,
    fit_scale: f64 = 1,
};

pub const MonitorsTabLayout = struct {
    toolbar_refresh_x: i32 = 0,
    toolbar_portals_x: i32 = 0,
    toolbar_portals_w: i32 = 0,
    toolbar_apply_x: i32 = 0,
    toolbar_revert_x: i32 = 0,
    toolbar_y: i32 = 0,
    toolbar_btn_w: i32 = 0,
    toolbar_btn_h: i32 = 0,
    canvas_x: i32 = 0,
    canvas_y: i32 = 0,
    canvas_w: i32 = 0,
    canvas_h: i32 = 300,
    center_btn_x: i32 = 0,
    align_top_btn_x: i32 = 0,
    aux_btn_y: i32 = 0,
    aux_btn_w: i32 = 0,
    aux_btn_h: i32 = 0,
    pills_y: i32 = 0,
    form_y: i32 = 0,
};

pub fn mainColumnWidth(content_w: i32) i32 {
    return @max(100, @divTrunc(content_w * 68, 100));
}

pub fn mainColumnLeft(content_x: i32, content_w: i32, column_w: i32) i32 {
    return content_x + @divTrunc(content_w - column_w, 2);
}

/// `strtol` semantics: optional sign, digits, everything else ignored.
fn strtolPrefix(s: []const u8) i32 {
    if (s.len == 0) return 0;
    var i: usize = 0;
    if (s[0] == '-' or s[0] == '+') i = 1;
    const digits_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == digits_start) return 0;
    return std.fmt.parseInt(i32, s[0..i], 10) catch 0;
}

/// `parse_position_xy` — split on the first `x`. Returns false when there is
/// no separator, leaving both outputs at their prior values
/// (writes through only after the separator is found).
pub fn parsePositionXy(s: []const u8, ox: *i32, oy: *i32) bool {
    const sep = std.mem.indexOfScalar(u8, s, 'x') orelse return false;
    ox.* = strtolPrefix(s);
    oy.* = strtolPrefix(s[sep + 1 ..]);
    return true;
}

/// `format_position_xy` — `%dx%d`.
pub fn formatPositionXy(x: i32, y: i32, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{d}x{d}", .{ x, y });
}

/// Physical mode pixels from the row's `resolution`, falling back to the
/// capability table and finally 1920x1080.
pub fn physicalModePx(row: *const mon.MonitorRow, cap: ?*const mon.OutputCaps, pw: *i32, ph: *i32) void {
    const res = row.resolution.slice();
    var w: i32 = 0;
    var h: i32 = 0;
    if (std.mem.indexOfScalar(u8, res, 'x')) |sep| {
        w = strtolPrefix(res);
        h = strtolPrefix(res[sep + 1 ..]);
    }
    if ((w <= 0 or h <= 0)) {
        if (cap) |c| {
            if (c.width > 0 and c.height > 0) {
                w = c.width;
                h = c.height;
            }
        }
    }
    if (w <= 0) w = 1920;
    if (h <= 0) h = 1080;
    pw.* = w;
    ph.* = h;
}

/// Logical (post-scale, post-transform) size of one output.
pub fn monitorLayoutExtents(row: *const mon.MonitorRow, cap: ?*const mon.OutputCaps, lw: *i32, lh: *i32) void {
    var pw: i32 = 0;
    var ph: i32 = 0;
    physicalModePx(row, cap, &pw, &ph);
    const sc = parseScale(row.scale.slice());
    var fw: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(pw)) / sc));
    var fh: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(ph)) / sc));
    const tr = std.math.clamp(strtolPrefix(row.transform.slice()), 0, 7);
    if (tr == 1 or tr == 3 or tr == 5 or tr == 7) {
        const t = fw;
        fw = fh;
        fh = t;
    }
    lw.* = @max(1, fw);
    lh.* = @max(1, fh);
}

/// `monitors_parse_scale_ds` — clamp into the range the UI can express.
pub fn parseScale(s: []const u8) f64 {
    const v = std.fmt.parseFloat(f64, s) catch return 1.0;
    if (!std.math.isFinite(v) or v <= 0) return 1.0;
    return std.math.clamp(v, 0.25, 8.0);
}

/// `layout_rects_from_outputs` — disabled outputs get a zero rect, which is
/// how every later pass skips them.
pub fn layoutRectsFromOutputs(s: *mon.State, out: []ArrangeRect) usize {
    const n = @min(s.outputs_len, out.len);
    for (out[0..n], 0..) |*r, i| {
        const row = &s.outputs[i];
        if (row.disabled) {
            r.* = .{};
            continue;
        }
        const cap = s.capsFor(row.name.slice());
        monitorLayoutExtents(row, cap, &r.w, &r.h);
        if (!parsePositionXy(if (row.position.empty()) "0x0" else row.position.slice(), &r.x, &r.y)) {
            r.x = 0;
            r.y = 0;
        }
    }
    return n;
}

/// `compute_canvas_fit` — bounding box of every non-empty rect, then the
/// uniform scale that fits it (with `pad_frac` breathing room) in the canvas.
pub fn computeCanvasFit(rects: []const ArrangeRect, cw: i32, ch: i32, pad_frac: f64) Fit {
    var f: Fit = .{};
    var mn_x: f64 = 0;
    var mn_y: f64 = 0;
    var mx_x: f64 = 0;
    var mx_y: f64 = 0;
    var any = false;
    for (rects) |r| {
        if (r.w <= 0 or r.h <= 0) continue;
        const x: f64 = @floatFromInt(r.x);
        const y: f64 = @floatFromInt(r.y);
        const x2: f64 = @floatFromInt(r.x + r.w);
        const y2: f64 = @floatFromInt(r.y + r.h);
        if (!any) {
            mn_x = x;
            mn_y = y;
            mx_x = x2;
            mx_y = y2;
            any = true;
        } else {
            mn_x = @min(mn_x, x);
            mn_y = @min(mn_y, y);
            mx_x = @max(mx_x, x2);
            mx_y = @max(mx_y, y2);
        }
    }
    if (!any) return f;
    const sw = @max(1.0, mx_x - mn_x);
    const sh = @max(1.0, mx_y - mn_y);
    const cw_f: f64 = @floatFromInt(cw);
    const ch_f: f64 = @floatFromInt(ch);
    const inner_w = @max(1.0, cw_f * (1.0 - 2.0 * pad_frac));
    const inner_h = @max(1.0, ch_f * (1.0 - 2.0 * pad_frac));
    f.min_x = mn_x;
    f.min_y = mn_y;
    f.span_w = sw;
    f.span_h = sh;
    f.fit_scale = @min(inner_w / sw, inner_h / sh);
    return f;
}

/// `canvas_delta_to_monitor_delta` — a pointer move in canvas pixels becomes
/// a move in logical output space.
pub fn canvasDeltaToMonitorDelta(dx: f64, dy: f64, scale_factor: f64) struct { x: f64, y: f64 } {
    const inv = if (scale_factor > 1e-9) 1.0 / scale_factor else 1.0;
    return .{ .x = dx * inv, .y = dy * inv };
}

const k_snap_px: i32 = 40;

fn aabbOverlap(a: ArrangeRect, b: ArrangeRect) bool {
    return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y;
}

/// Split an overlap down its narrower axis, each rect taking half (rounded up)
/// away from the other.
fn separatePair(a: *ArrangeRect, b: *ArrangeRect) void {
    const axc = a.x + @divTrunc(a.w, 2);
    const bxc = b.x + @divTrunc(b.w, 2);
    const ayc = a.y + @divTrunc(a.h, 2);
    const byc = b.y + @divTrunc(b.h, 2);
    const overlap_x = @min(a.x + a.w, b.x + b.w) - @max(a.x, b.x);
    const overlap_y = @min(a.y + a.h, b.y + b.h) - @max(a.y, b.y);
    if (overlap_x <= 0 or overlap_y <= 0) return;
    if (overlap_x < overlap_y) {
        const step = @divTrunc(overlap_x + 1, 2);
        if (axc < bxc) {
            a.x -= step;
            b.x += step;
        } else {
            a.x += step;
            b.x -= step;
        }
    } else {
        const step = @divTrunc(overlap_y + 1, 2);
        if (ayc < byc) {
            a.y -= step;
            b.y += step;
        } else {
            a.y += step;
            b.y -= step;
        }
    }
}

fn disabledAt(s: *mon.State, i: usize) bool {
    return i < s.outputs_len and s.outputs[i].disabled;
}

fn resolveCollisions(rects: []ArrangeRect, s: *mon.State) void {
    var iter: i32 = 0;
    while (iter < 24) : (iter += 1) {
        var moved = false;
        for (rects, 0..) |*ri, i| {
            if (disabledAt(s, i)) continue;
            if (ri.w <= 0) continue;
            for (rects[i + 1 ..], i + 1 ..) |*rj, j| {
                if (disabledAt(s, j)) continue;
                if (rj.w <= 0) continue;
                if (!aabbOverlap(ri.*, rj.*)) continue;
                separatePair(ri, rj);
                moved = true;
            }
        }
        if (!moved) break;
    }
}

fn normalizeOrigin(rects: []ArrangeRect, s: *mon.State) void {
    var mn_x: i32 = std.math.maxInt(i32);
    var mn_y: i32 = std.math.maxInt(i32);
    for (rects, 0..) |*r, i| {
        if (disabledAt(s, i)) continue;
        if (r.w <= 0) continue;
        mn_x = @min(mn_x, r.x);
        mn_y = @min(mn_y, r.y);
    }
    if (mn_x == std.math.maxInt(i32)) return;
    for (rects) |*r| {
        if (r.w <= 0) continue;
        r.x -= mn_x;
        r.y -= mn_y;
    }
}

/// Snap one value onto `target` when it is already within `threshold`.
fn trySnap(val: i32, target: i32, threshold: i32) ?i32 {
    if (@abs(val - target) <= threshold) return target;
    return null;
}

fn snapEdges(moved_idx: usize, rects: []ArrangeRect, s: *mon.State) void {
    if (moved_idx >= rects.len) return;
    if (disabledAt(s, moved_idx)) return;
    if (rects[moved_idx].w <= 0) return;
    const me = &rects[moved_idx];

    for (rects, 0..) |*op, j| {
        if (j == moved_idx) continue;
        if (disabledAt(s, j)) continue;
        if (op.w <= 0) continue;
        const o = op.*;

        if (trySnap(me.x, o.x - me.w, k_snap_px)) |v| me.x = v;
        if (trySnap(me.x, o.x + o.w, k_snap_px)) |v| me.x = v;
        if (trySnap(me.y, o.y - me.h, k_snap_px)) |v| me.y = v;
        if (trySnap(me.y, o.y + o.h, k_snap_px)) |v| me.y = v;

        if (trySnap(me.y, o.y, k_snap_px)) |v| me.y = v;
        if (trySnap(me.y + me.h, o.y + o.h, k_snap_px)) |v| me.y = v - me.h;
        const oc = o.y + @divTrunc(o.h, 2);
        const mc = me.y + @divTrunc(me.h, 2);
        if (trySnap(mc, oc, k_snap_px)) |v| me.y = v - @divTrunc(me.h, 2);

        if (trySnap(me.x, o.x, k_snap_px)) |v| me.x = v;
        if (trySnap(me.x + me.w, o.x + o.w, k_snap_px)) |v| me.x = v - me.w;
        const ocx = o.x + @divTrunc(o.w, 2);
        const mcx = me.x + @divTrunc(me.w, 2);
        if (trySnap(mcx, ocx, k_snap_px)) |v| me.x = v - @divTrunc(me.w, 2);
    }
}

fn writeRectToRow(r: ArrangeRect, row: *mon.MonitorRow) void {
    var buf: [64]u8 = undefined;
    const s = formatPositionXy(r.x, r.y, &buf) catch return;
    row.position.set(s);
}

/// `finalize_arrangement_drag` — the drop: stop overlapping, magnet to the
/// moved output's neighbours, pull the whole arrangement back to 0,0, and
/// persist the result into the rows.
pub fn finalizeArrangementDrag(s: *mon.State, moved_idx: usize) void {
    var rects: [mon.max_outputs]ArrangeRect = undefined;
    const n = layoutRectsFromOutputs(s, &rects);
    const all = rects[0..n];
    resolveCollisions(all, s);
    snapEdges(moved_idx, all, s);
    normalizeOrigin(all, s);
    for (all, 0..) |r, i| {
        if (i >= s.outputs_len) break;
        if (s.outputs[i].disabled) continue;
        writeRectToRow(r, &s.outputs[i]);
    }
}

/// `align_all_tops` — every enabled output to the highest top, then the usual
/// origin normalisation.
pub fn alignAllTops(s: *mon.State) void {
    var rects: [mon.max_outputs]ArrangeRect = undefined;
    const n = layoutRectsFromOutputs(s, &rects);
    const all = rects[0..n];
    var best_y: i32 = std.math.maxInt(i32);
    for (all, 0..) |r, i| {
        if (disabledAt(s, i)) continue;
        if (r.w <= 0) continue;
        best_y = @min(best_y, r.y);
    }
    if (best_y == std.math.maxInt(i32)) return;
    for (all, 0..) |*r, i| {
        if (disabledAt(s, i)) continue;
        if (r.w <= 0) continue;
        r.y = best_y;
    }
    normalizeOrigin(all, s);
    for (all, 0..) |r, i| {
        if (i >= s.outputs_len) break;
        if (s.outputs[i].disabled) continue;
        writeRectToRow(r, &s.outputs[i]);
    }
}

// Canvas view (pan / zoom / hit)

/// The arrangement mapped into canvas-box pixels. `min_x`/`min_y` come from
/// the fit, `sf` folds the user zoom on top, and `pan_*` positions the whole
/// arrangement inside the box. Built once per paint/hit,
/// so N outputs cost one layout + one fit.
pub const CanvasView = struct {
    rects: [mon.max_outputs]ArrangeRect = undefined,
    n: usize = 0,
    min_x: f64 = 0,
    min_y: f64 = 0,
    sf: f64 = 1,
    pan_x: f64 = 0,
    pan_y: f64 = 0,
};

pub const canvas_pad_frac: f64 = 0.1;

/// `monitors_canvas_transform` + one `layout_rects_from_outputs`. While a drag
/// is in flight the frozen fit wins (`monitors_canvas_drag_fit`), so the
/// arrangement cannot slide under the pointer mid-drag.
pub fn canvasView(s: *mon.State, box_w: i32, box_h: i32) CanvasView {
    var v: CanvasView = .{};
    v.n = layoutRectsFromOutputs(s, &v.rects);
    if (s.fz_valid) {
        v.min_x = s.fz_min_x;
        v.min_y = s.fz_min_y;
        v.sf = s.fz_sf;
    } else {
        const f = computeCanvasFit(v.rects[0..v.n], box_w, box_h, canvas_pad_frac);
        v.min_x = f.min_x;
        v.min_y = f.min_y;
        v.sf = f.fit_scale * s.zoom;
    }
    v.pan_x = s.pan_x;
    v.pan_y = s.pan_y;
    return v;
}

/// `monitors_center_canvas_view` — pan so the arrangement's bounding box sits
/// dead centre of the canvas box.
pub fn centerCanvasView(s: *mon.State, box_w: i32, box_h: i32) void {
    var rects: [mon.max_outputs]ArrangeRect = undefined;
    const n = layoutRectsFromOutputs(s, &rects);
    const f = computeCanvasFit(rects[0..n], box_w, box_h, canvas_pad_frac);
    const sf = f.fit_scale * s.zoom;
    // `canvasScreenRect` maps a world x to `(x - min_x) * sf + pan_x`, so the
    // leftmost rect already lands exactly on `pan_x` and only the span takes
    // part in the centring sum.
    // the view `min_x * sf` off-centre — invisible while the arrangement
    // starts at the origin, but a monitor configured at 1920x0 ends up
    // half off the left edge of the board.
    s.pan_x = @as(f64, @floatFromInt(box_w)) * 0.5 - f.span_w * 0.5 * sf;
    s.pan_y = @as(f64, @floatFromInt(box_h)) * 0.5 - f.span_h * 0.5 * sf;
}

/// One output's box in canvas-box pixels, or null for a disabled/absent one.
pub fn canvasScreenRect(v: *const CanvasView, i: usize) ?struct { x: f64, y: f64, w: f64, h: f64 } {
    if (i >= v.n) return null;
    const r = v.rects[i];
    if (r.w <= 0 or r.h <= 0) return null;
    return .{
        .x = (r.x - v.min_x) * v.sf + v.pan_x,
        .y = (r.y - v.min_y) * v.sf + v.pan_y,
        .w = @as(f64, @floatFromInt(r.w)) * v.sf,
        .h = @as(f64, @floatFromInt(r.h)) * v.sf,
    };
}

/// `monitors_canvas_hit_monitor` — the output under a canvas-local pointer.
pub fn canvasHitMonitor(v: *const CanvasView, px: f64, py: f64) i32 {
    var i: usize = v.n;
    while (i > 0) {
        i -= 1;
        const r = canvasScreenRect(v, i) orelse continue;
        if (px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h) return @intCast(i);
    }
    return -1;
}

/// `monitors_wheel_zoom_canvas` — zoom about the pointer, keeping the point
/// under it fixed. `delta_px` is the wheel step in canvas pixels.
pub fn wheelZoomCanvas(s: *mon.State, box_w: i32, box_h: i32, px: f64, py: f64, delta_px: f64) void {
    var rects: [mon.max_outputs]ArrangeRect = undefined;
    const n = layoutRectsFromOutputs(s, &rects);
    const f = computeCanvasFit(rects[0..n], box_w, box_h, canvas_pad_frac);
    const sf_old = f.fit_scale * s.zoom;
    const step: i32 = @intFromFloat(@round(delta_px));
    if (step == 0) return;
    const zmul: f64 = if (step > 0) 0.92 else 1.0 / 0.92;
    const znew = std.math.clamp(s.zoom * zmul, 0.35, 4.0);
    const denom = @max(sf_old, 1e-9);
    const wx = (px - s.pan_x) / denom;
    const wy = (py - s.pan_y) / denom;
    s.zoom = znew;
    const sf_new = f.fit_scale * znew;
    s.pan_x = px - wx * sf_new;
    s.pan_y = py - wy * sf_new;
}

/// `monitors_canvas_drag_move` — a pointer move during an arrangement drag:
/// the pointer delta becomes a logical delta (through the frozen fit), and the
/// dragged output's position string follows it live.
pub fn dragMoveTo(s: *mon.State, box_w: i32, box_h: i32, idx: usize, px: f64, py: f64) void {
    if (idx >= s.outputs_len) return;
    const v = canvasView(s, box_w, box_h);
    const d = canvasDeltaToMonitorDelta(px - s.press_x, py - s.press_y, v.sf);
    const nx: i32 = s.anchor_x + @as(i32, @intFromFloat(@round(d.x)));
    const ny: i32 = s.anchor_y + @as(i32, @intFromFloat(@round(d.y)));
    var buf: [64]u8 = undefined;
    const pos = formatPositionXy(nx, ny, &buf) catch return;
    s.outputs[idx].position.set(pos);
    s.dirty = true;
}

/// Begin an arrangement drag: remember which output, its anchored position and
/// where the pointer went down.
pub fn beginDrag(s: *mon.State, box_w: i32, box_h: i32, idx: usize, px: f64, py: f64) void {
    s.drag_idx = if (idx < s.outputs_len) @intCast(idx) else -1;
    s.pan_armed = false;
    if (s.drag_idx < 0) return;
    const row = &s.outputs[@intCast(s.drag_idx)];
    var ax: i32 = 0;
    var ay: i32 = 0;
    const ps: []const u8 = if (row.position.empty()) "0x0" else row.position.slice();
    _ = parsePositionXy(ps, &ax, &ay);
    s.anchor_x = ax;
    s.anchor_y = ay;
    s.press_x = px;
    s.press_y = py;
    // Freeze the fit: recomputing it every motion would slide the whole
    // arrangement under the pointer as the dragged rect moves.
    const v = canvasView(s, box_w, box_h);
    s.fz_valid = true;
    s.fz_min_x = v.min_x;
    s.fz_min_y = v.min_y;
    s.fz_sf = v.sf;
    s.fz_w = box_w;
    s.fz_h = box_h;
    s.fz_n = v.n;
}

// Tab layout

/// Width a plain toolbar button needs for `label`: Inter 12/400 measured by
/// pango, plus the 2x10px horizontal padding m3::Button adds. m3::Button
/// auto-expands past a narrower slot and recentres by shifting left, so the
/// slot must be sized from this value to keep painted and hit-tested rects
/// identical.
pub fn toolbarBtnLabelWidthPx(label: []const u8) i32 {
    if (label.len == 0) return 0;
    const surface = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 1, 1);
    defer cairo.cairo_surface_destroy(surface);
    const cr = cairo.cairo_create(surface);
    defer cairo.cairo_destroy(cr);
    return ui_paint.textWidthPx(cr, label, 12.0, 400) + 20;
}

/// This is cached in a file-scope variable; layout runs every frame
/// so measuring pango each time would be a per-paint syscall into fontconfig.
var portals_w_cache: i32 = -1;

fn portalsLabelWidth() i32 {
    if (portals_w_cache < 0) portals_w_cache = toolbarBtnLabelWidthPx("Restart portals") + 4;
    return portals_w_cache;
}

pub const k_toolbar_btn_w: i32 = 92;
pub const k_toolbar_btn_h: i32 = 30;

/// `compute_monitors_tab_layout` — toolbar slots, arrange canvas box, pill row
/// and form origin, all derived from the content column and the viewport.
pub fn computeMonitorsTabLayout(
    content_x: i32,
    content_w: i32,
    content_top: i32,
    viewport_h: i32,
) MonitorsTabLayout {
    const btn_w = k_toolbar_btn_w;
    const btn_h = k_toolbar_btn_h;
    const gap: i32 = 10;
    const center_gap: i32 = 40;
    const portals_w = portalsLabelWidth();

    const k_above_canvas: i32 = 126;
    const k_below_canvas: i32 = 88;
    const k_min_form_peek: i32 = 72;
    const k_canvas_min_h: i32 = 200;
    const k_canvas_max_h: i32 = 720;
    const k_widget_canvas_height_scale: f64 = 0.56;

    var lay: MonitorsTabLayout = .{};
    lay.toolbar_btn_w = btn_w;
    lay.toolbar_btn_h = btn_h;
    lay.toolbar_y = content_top + 56;
    lay.toolbar_refresh_x = content_x + 16;
    lay.toolbar_portals_x = lay.toolbar_refresh_x + btn_w + center_gap;
    lay.toolbar_portals_w = portals_w;
    lay.toolbar_revert_x = content_x + content_w - 16 - btn_w;
    lay.toolbar_apply_x = lay.toolbar_revert_x - gap - btn_w;
    {
        const space = lay.toolbar_apply_x - (lay.toolbar_portals_x + portals_w);
        const cg_w = 2 * btn_w + center_gap;
        const cg_x = lay.toolbar_portals_x + portals_w + @max(0, @divTrunc(space - cg_w, 2));
        lay.center_btn_x = cg_x;
        lay.align_top_btn_x = cg_x + btn_w + center_gap;
    }
    lay.canvas_y = lay.toolbar_y + btn_h + 40;
    {
        const col_w = mainColumnWidth(content_w);
        lay.canvas_w = col_w;
        lay.canvas_x = mainColumnLeft(content_x, content_w, col_w);
    }
    {
        const vh = @max(200, viewport_h);
        const avail = vh - k_above_canvas - k_below_canvas - k_min_form_peek;
        const base_h = std.math.clamp(avail, k_canvas_min_h, k_canvas_max_h);
        const scale = k_widget_canvas_height_scale;
        const lo: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(k_canvas_min_h)) * scale));
        const hi: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(k_canvas_max_h)) * scale));
        lay.canvas_h = std.math.clamp(
            @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(base_h)) * scale))),
            lo,
            hi,
        );
    }
    lay.aux_btn_y = lay.toolbar_y;
    lay.aux_btn_w = btn_w;
    lay.aux_btn_h = btn_h;
    lay.pills_y = lay.canvas_y + lay.canvas_h + 10;
    lay.form_y = lay.pills_y + 40;
    return lay;
}

test "settings-monitors-tab: main column + position strings" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 408), mainColumnWidth(600));
    try t.expectEqual(@as(i32, 100), mainColumnWidth(100));
    try t.expectEqual(@as(i32, 96), mainColumnLeft(0, 600, 408));
    try t.expectEqual(@as(i32, 260 + 100), mainColumnLeft(260, 600, 400));

    var x: i32 = -1;
    var y: i32 = -1;
    try t.expect(parsePositionXy("1920x0", &x, &y));
    try t.expectEqual(@as(i32, 1920), x);
    try t.expectEqual(@as(i32, 0), y);
    try t.expect(parsePositionXy("-1920x1080", &x, &y));
    try t.expectEqual(@as(i32, -1920), x);
    try t.expectEqual(@as(i32, 1080), y);
    // No separator → failure, both outputs untouched.
    x = 7;
    y = 9;
    try t.expect(!parsePositionXy("1920, 0", &x, &y));
    try t.expectEqual(@as(i32, 7), x);
    try t.expectEqual(@as(i32, 9), y);

    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("10x20", try formatPositionXy(10, 20, &buf));
    try t.expectEqualStrings("-2560x0", try formatPositionXy(-2560, 0, &buf));
}

test "settings-monitors-tab: extents follow resolution, scale and transform" {
    const t = std.testing;
    var row: mon.MonitorRow = .{};
    row.resolution.set("2560x1440");
    row.scale.set("1.25");
    row.transform.set("0");
    var w: i32 = 0;
    var h: i32 = 0;
    monitorLayoutExtents(&row, null, &w, &h);
    try t.expectEqual(@as(i32, 2048), w);
    try t.expectEqual(@as(i32, 1152), h);

    row.transform.set("1");
    monitorLayoutExtents(&row, null, &w, &h);
    try t.expectEqual(@as(i32, 1152), w);
    try t.expectEqual(@as(i32, 2048), h);

    // Missing resolution falls back to the capability table, then 1920x1080.
    row.resolution.clear();
    row.scale.clear();
    row.transform.clear();
    monitorLayoutExtents(&row, null, &w, &h);
    try t.expectEqual(@as(i32, 1920), w);
    try t.expectEqual(@as(i32, 1080), h);
    var caps = mon.OutputCaps{};
    caps.width = 3440;
    caps.height = 1440;
    monitorLayoutExtents(&row, &caps, &w, &h);
    try t.expectEqual(@as(i32, 3440), w);
    try t.expectEqual(@as(i32, 1440), h);

    try t.expectEqual(@as(f64, 1.0), parseScale(""));
    try t.expectEqual(@as(f64, 1.0), parseScale("banana"));
    try t.expectEqual(@as(f64, 0.25), parseScale("0.1"));
    try t.expectEqual(@as(f64, 8.0), parseScale("100"));
    try t.expectEqual(@as(f64, 1.5), parseScale("1.5"));
}

test "settings-monitors-tab: canvas fit boxes the arrangement" {
    const t = std.testing;
    const rects = [_]ArrangeRect{
        .{ .x = 0, .y = 0, .w = 1920, .h = 1080 },
        .{ .x = 1920, .y = 0, .w = 1920, .h = 1080 },
        .{ .x = 0, .y = 0, .w = 0, .h = 0 }, // disabled: skipped
    };
    const f = computeCanvasFit(&rects, 600, 300, 0.1);
    try t.expectEqual(@as(f64, 0), f.min_x);
    try t.expectEqual(@as(f64, 3840), f.span_w);
    try t.expectEqual(@as(f64, 1080), f.span_h);
    // inner = 600*0.8 x 300*0.8 = 480 x 240 → 480/3840 = 0.125 wins.
    try t.expect(std.math.approxEqAbs(f64, 0.125, f.fit_scale, 1e-9));

    const empty = computeCanvasFit(&[_]ArrangeRect{}, 600, 300, 0.1);
    try t.expectEqual(@as(f64, 1), empty.fit_scale);
    try t.expectEqual(@as(f64, 1), empty.span_w);

    const d = canvasDeltaToMonitorDelta(100, -50, 2.0);
    try t.expectEqual(@as(f64, 50), d.x);
    try t.expectEqual(@as(f64, -25), d.y);
    const z = canvasDeltaToMonitorDelta(100, 50, 0.0);
    try t.expectEqual(@as(f64, 100), z.x);
}

test "settings-monitors-tab: drops resolve, snap and normalise" {
    const t = std.testing;
    var s = mon.State{ .gpa = t.allocator };
    defer s.deinit();

    // Two outputs stacked on top of each other at 0x0.
    s.outputs_len = 2;
    s.outputs[0].name.set("DP-1");
    s.outputs[0].resolution.set("2560x1440");
    s.outputs[0].position.set("0x0");
    s.outputs[1].name.set("HDMI-A-1");
    s.outputs[1].resolution.set("1920x1080");
    s.outputs[1].position.set("0x0");

    finalizeArrangementDrag(&s, 1);
    var x0: i32 = 0;
    var y0: i32 = 0;
    var x1: i32 = 0;
    var y1: i32 = 0;
    try t.expect(parsePositionXy(s.outputs[0].position.slice(), &x0, &y0));
    try t.expect(parsePositionXy(s.outputs[1].position.slice(), &x1, &y1));
    // The drop separated the stacked outputs and renormalised the origin to
    // 0,0. Collision resolution splits the pair symmetrically, so either
    // monitor may be the one that moved — the invariant is separation with a
    // zero origin, not which row kept its slot.
    try t.expect(x0 != x1 or y0 != y1);
    try t.expectEqual(@as(i32, 0), @min(x0, x1));
    try t.expectEqual(@as(i32, 0), @min(y0, y1));

    // Align tops pulls the second output back onto the first's top edge.
    s.outputs[1].position.set("100x500");
    alignAllTops(&s);
    try t.expect(parsePositionXy(s.outputs[1].position.slice(), &x1, &y1));
    try t.expectEqual(@as(i32, 0), y1);
    try t.expect(x1 != 0);
}

test "settings-monitors-tab: a disabled output is a zero rect nobody pushes" {
    const t = std.testing;
    var s = mon.State{ .gpa = t.allocator };
    defer s.deinit();
    s.outputs_len = 2;
    s.outputs[0].name.set("DP-1");
    s.outputs[0].resolution.set("1920x1080");
    s.outputs[0].position.set("100x100");
    s.outputs[1].name.set("HDMI-A-1");
    s.outputs[1].resolution.set("1920x1080");
    s.outputs[1].position.set("100x100");
    s.outputs[1].disabled = true;

    var rects: [8]ArrangeRect = undefined;
    const n = layoutRectsFromOutputs(&s, &rects);
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqual(@as(i32, 1920), rects[0].w);
    try t.expectEqual(@as(i32, 0), rects[1].w);

    finalizeArrangementDrag(&s, 0);
    try t.expect(s.outputs[1].position.eql("100x100")); // never written
    try t.expect(!s.outputs[0].position.eql("100x100")); // moved off its twin
}

test "settings-monitors-tab: toolbar layout keeps apply/revert on the right" {
    const t = std.testing;
    const lay = computeMonitorsTabLayout(260, 640, 16, 900);
    try t.expectEqual(@as(i32, 92), lay.toolbar_btn_w);
    try t.expectEqual(@as(i32, 72), lay.toolbar_y);
    try t.expectEqual(@as(i32, 276), lay.toolbar_refresh_x);
    try t.expectEqual(@as(i32, 408), lay.toolbar_portals_x);
    try t.expectEqual(@as(i32, 260 + 640 - 16 - 92), lay.toolbar_revert_x);
    try t.expectEqual(@as(i32, lay.toolbar_revert_x - 10 - 92), lay.toolbar_apply_x);
    try t.expect(lay.toolbar_apply_x > lay.toolbar_portals_x + lay.toolbar_portals_w);
    try t.expect(lay.align_top_btn_x > lay.center_btn_x);
    // Centered 435px column in 640px: 260 + (640 - 435) / 2 (integer division).
    try t.expectEqual(@as(i32, 260 + 102), lay.canvas_x);
    try t.expectEqual(@as(i32, 640 * 68 / 100), lay.canvas_w);
    try t.expectEqual(@as(i32, lay.canvas_y + lay.canvas_h + 10), lay.pills_y);
    try t.expectEqual(@as(i32, lay.pills_y + 40), lay.form_y);
    // Canvas height: clamp(900-126-88-72 = 614, 200, 720) = 614 → *0.56 = 344.
    try t.expectEqual(@as(i32, 344), lay.canvas_h);
}

test "settings-monitors-tab: centre view lands the arrangement mid-canvas" {
    const t = std.testing;
    const bw: i32 = 900;
    const bh: i32 = 288;

    // Arrangement that starts at the origin (DP-2 at 0x0, DP-1 at 2560x0).
    var s = mon.State{ .gpa = t.allocator };
    defer s.deinit();
    s.outputs_len = 3;
    for ([_]struct { n: []const u8, p: []const u8 }{
        .{ .n = "DP-1", .p = "2560x0" },
        .{ .n = "DP-2", .p = "0x0" },
        .{ .n = "DP-3", .p = "5120x0" },
    }, 0..) |e, i| {
        s.outputs[i].name.set(e.n);
        s.outputs[i].resolution.set("2560x1440");
        s.outputs[i].position.set(e.p);
    }
    centerCanvasView(&s, bw, bh);

    const bbox = struct {
        fn of(st: *mon.State, w: i32, h: i32) [4]f64 {
            const v = canvasView(st, w, h);
            var lo_x: f64 = 1e30;
            var lo_y: f64 = 1e30;
            var hi_x: f64 = -1e30;
            var hi_y: f64 = -1e30;
            for (0..v.n) |i| {
                const r = canvasScreenRect(&v, i) orelse continue;
                if (r.w <= 0) continue;
                lo_x = @min(lo_x, r.x);
                lo_y = @min(lo_y, r.y);
                hi_x = @max(hi_x, r.x + r.w);
                hi_y = @max(hi_y, r.y + r.h);
            }
            return .{ lo_x, lo_y, hi_x, hi_y };
        }
    }.of;

    const a = bbox(&s, bw, bh);
    try t.expectApproxEqAbs(@as(f64, bw) * 0.5, (a[0] + a[2]) * 0.5, 1e-6);
    try t.expectApproxEqAbs(@as(f64, bh) * 0.5, (a[1] + a[3]) * 0.5, 1e-6);

    // A single output configured away from the origin must be centred too.
    s.outputs_len = 1;
    s.outputs[0].position.set("1920x0");
    s.outputs[0].resolution.set("2560x1440");
    centerCanvasView(&s, bw, bh);
    const b = bbox(&s, bw, bh);
    try t.expectApproxEqAbs(@as(f64, bw) * 0.5, (b[0] + b[2]) * 0.5, 1e-6);
    try t.expectApproxEqAbs(@as(f64, bh) * 0.5, (b[1] + b[3]) * 0.5, 1e-6);
}
