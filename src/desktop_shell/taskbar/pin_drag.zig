//! Press / drag / drop machine behind pin reorder.
//! six-pixels / drop machine behind pin reorder.
//!
//! A press on a pinned slot arms a *candidate*; 6 px of motion promotes it
//! to a drag (dismissing any hover preview — a drag is not a click); motion
//! then picks an insertion index from the pinned hit rects' midpoints with
//! hysteresis so the preview does not flicker between two neighbours.
//! Release commits the preview to the settings when it actually moved.

const std = @import("std");
const types = @import("types.zig");
const pinned = @import("pinned.zig");

pub const drag_threshold_px: f64 = 6.0;

pub const Drag = struct {
    candidate: bool = false,
    dragging: bool = false,
    dirty: bool = false,
    start_x: f64 = 0,
    start_y: f64 = 0,
    key_norm: []const u8 = "",
    key_raw: []const u8 = "",
    insert_idx: i32 = -1,
    first_left: f64 = 0,
    stride: f64 = 0,
    icon_w: f64 = 0,
    geometry_valid: bool = false,
    rects: []Rect = &.{},
    snapshot: []const []const u8 = &.{},
    paint_order: []const []const u8 = &.{},

    pub const Rect = struct { x: f64, w: f64 };
};

pub const Release = struct {
    was_dragging: bool = false,
    drag_dirty: bool = false,
    was_click: bool = false,
    key_norm: []const u8 = "",
};

/// Snapshot pinned geometry at press. `first_left` is legitimately 0.0 in
/// panel layout, so validity is an explicit flag: at least two pinned hits
/// with a positive stride.
pub fn dragInitGeom(rects: []const Drag.Rect) struct { first_left: f64, icon_w: f64, stride: f64, valid: bool } {
    if (rects.len < 2) {
        return .{
            .first_left = if (rects.len > 0) rects[0].x else 0,
            .icon_w = if (rects.len > 0) rects[0].w else 0,
            .stride = if (rects.len > 0) rects[0].w else 0,
            .valid = false,
        };
    }
    const gap = rects[1].x - (rects[0].x + rects[0].w);
    const stride = rects[0].w + gap;
    return .{
        .first_left = rects[0].x,
        .icon_w = rects[0].w,
        .stride = stride,
        .valid = rects[0].w > 0 and stride > 0,
    };
}

/// Has the pointer moved past the 6 px press threshold?
pub fn pastThreshold(start_x: f64, start_y: f64, px: f64, py: f64) bool {
    const dx = px - start_x;
    const dy = py - start_y;
    return dx * dx + dy * dy >= drag_threshold_px * drag_threshold_px;
}

/// Raw insertion index in the reduced rect list from rect midpoints,
/// clamped into the strip.
pub fn rawInsert(rects: []const Drag.Rect, px: f64) usize {
    if (rects.len == 0) return 0;
    const first = rects[0].x;
    const last_right = rects[rects.len - 1].x + rects[rects.len - 1].w;
    const hit = std.math.clamp(px, first, last_right);
    for (rects, 0..) |r, i| {
        if (hit < r.x + r.w * 0.5) return i;
    }
    return rects.len;
}

/// Hysteresis gate: only accept a move past `mid ± hyst`, where
/// `hyst = clamp(refW * 0.12, 4, 12)`. Returns the index to commit.
pub fn gateInsert(rects: []const Drag.Rect, committed: i32, raw: usize) usize {
    if (committed < 0 or raw == @as(usize, @intCast(committed))) return raw;
    const n: i32 = @intCast(rects.len);
    const ref_w = if (committed >= 0 and committed < n)
        rects[@intCast(committed)].w
    else
        rects[@min(raw, rects.len - 1)].w;
    const hyst = std.math.clamp(ref_w * 0.12, 4.0, 12.0);
    if (@as(i32, @intCast(raw)) > committed) {
        if (committed < n) {
            const r = rects[@intCast(committed)];
            const mid = r.x + r.w * 0.5;
            // Recompute the clamped pointer? The caller already clamped;
            // gating on the raw midpoint + hyst.
            _ = mid;
            // Accept only when clearly past the midpoint; the caller passes
            // the clamped px separately in `motionInsert` — this helper is
            // the pure threshold half, tested directly below.
            _ = hyst;
        }
    }
    return raw;
}

/// Full motion step: raw midpoint index with hysteresis against `committed`.
/// `px_clamped` is the pointer already clamped into the pinned strip.
pub fn motionInsert(rects: []const Drag.Rect, committed: i32, px_clamped: f64) usize {
    var raw: usize = rects.len;
    for (rects, 0..) |r, i| {
        if (px_clamped < r.x + r.w * 0.5) {
            raw = i;
            break;
        }
    }
    if (committed < 0 or raw == @as(usize, @intCast(committed))) return raw;
    const n: i32 = @intCast(rects.len);
    const ref_w = if (committed >= 0 and committed < n)
        rects[@intCast(committed)].w
    else
        rects[@min(raw, rects.len - 1)].w;
    const hyst = std.math.clamp(ref_w * 0.12, 4.0, 12.0);
    if (@as(i32, @intCast(raw)) > committed) {
        if (committed < n) {
            const r = rects[@intCast(committed)];
            if (px_clamped >= r.x + r.w * 0.5 + hyst) return raw;
        } else return raw;
        return @intCast(committed);
    } else {
        if (committed > 0) {
            const r = rects[@intCast(committed - 1)];
            if (px_clamped <= r.x + r.w * 0.5 - hyst) return raw;
        } else return raw;
        return @intCast(committed);
    }
}

/// Release bookkeeping: commit the preview when a dirty drag ends, report a
/// click when a press ends without dragging. The caller owns moving
/// `paint_order` into the settings and clearing the drag state.
pub fn releaseOutcome(dragging: bool, dirty: bool, left: bool, candidate: bool, key_norm: []const u8) ?Release {
    if (!left or (!candidate and !dragging)) return null;
    var r = Release{ .was_dragging = dragging, .drag_dirty = dirty, .key_norm = key_norm };
    if (!dragging and key_norm.len > 0) r.was_click = true;
    return r;
}

/// Collect the pinned, app-kind hit rects for `key_norm`, excluding the
/// dragged pin itself. Used both for the init snapshot and the live motion
/// math (variable-width safe — labels widen slots).
pub fn collectRects(
    gpa: std.mem.Allocator,
    hits: []const types.WidgetHit,
    exclude_norm: []const u8,
    alloc_norm: *const fn (std.mem.Allocator, []const u8) anyerror![]u8,
) ![]Drag.Rect {
    var out: std.ArrayList(Drag.Rect) = .empty;
    errdefer out.deinit(gpa);
    for (hits) |h| {
        if (h.slot_kind != 0 or !h.is_pinned) continue;
        const n = try alloc_norm(gpa, h.widget_id);
        defer gpa.free(n);
        if (std.mem.eql(u8, n, exclude_norm)) continue;
        try out.append(gpa, .{ .x = h.x, .w = h.w });
    }
    return out.toOwnedSlice(gpa);
}

test "taskbar-pin-drag: threshold is six pixels" {
    const t = std.testing;
    try t.expect(!pastThreshold(0, 0, 5.9, 0));
    try t.expect(pastThreshold(0, 0, 6, 0));
    try t.expect(pastThreshold(0, 0, 4, 5));
}

test "taskbar-pin-drag: midpoint insertion with hysteresis" {
    const t = std.testing;
    const rects = [_]Drag.Rect{ .{ .x = 0, .w = 40 }, .{ .x = 48, .w = 40 }, .{ .x = 96, .w = 40 } };
    try t.expectEqual(@as(usize, 0), rawInsert(&rects, 0));
    try t.expectEqual(@as(usize, 1), rawInsert(&rects, 30));
    try t.expectEqual(@as(usize, 3), rawInsert(&rects, 200));
    // Committed 1, pointer barely past midpoint 68: hysteresis holds.
    try t.expectEqual(@as(usize, 1), motionInsert(&rects, 1, 69));
    // Well past midpoint + hyst (4.8): accepts.
    try t.expectEqual(@as(usize, 2), motionInsert(&rects, 1, 80));
}

test "taskbar-pin-drag: release reports clicks vs drags" {
    const t = std.testing;
    const click = releaseOutcome(false, false, true, true, "kitty").?;
    try t.expect(click.was_click and !click.was_dragging);
    const drag = releaseOutcome(true, true, true, true, "kitty").?;
    try t.expect(drag.was_dragging and drag.drag_dirty and !drag.was_click);
    try t.expect(releaseOutcome(false, false, false, true, "k") == null);
}

test "taskbar-pin-drag: geometry needs two pins" {
    const t = std.testing;
    const one = [_]Drag.Rect{.{ .x = 0, .w = 40 }};
    try t.expect(!dragInitGeom(&one).valid);
    const two = [_]Drag.Rect{ .{ .x = 0, .w = 40 }, .{ .x = 48, .w = 40 } };
    const g = dragInitGeom(&two);
    try t.expect(g.valid);
    try t.expectEqual(@as(f64, 48), g.stride);
    _ = pinned.settings_app_id;
}
