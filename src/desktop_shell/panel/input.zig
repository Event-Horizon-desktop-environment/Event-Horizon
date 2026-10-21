//! Panel input — port of the pointer half of
//! `src/desktop_shell/panel/core/panel.cpp:151-326`.
//!
//! Pure: hit lookup against the painter's hit rects, press/release routing
//! (slot click vs dead zone), and the scroll-volume gate. The binary owns
//! the Wayland listeners; everything branchy is pinned here without a
//! compositor.

const std = @import("std");
const types = @import("types.zig");
const core = @import("core.zig");

pub const Zone = enum { none, left_dead, middle_dead, right_dead, widget };

/// Legacy zone classification kept for the dead-zone fallback path: outer
/// 16 px on each side plus a 16 px middle band (GNOME-style). Real slot
/// picking uses the painter's hit rects (`classifyPress`); this only decides
/// which dead-zone action a click on empty bar space fires.
pub fn hitTest(x: i32, w: i32, dead_left_w: i32, dead_right_w: i32) Zone {
    if (x < 0 or x >= w) return .none;
    if (x < dead_left_w) return .left_dead;
    if (x >= w - dead_right_w) return .right_dead;
    const mid_l = @divTrunc(w, 2) - 8;
    const mid_r = @divTrunc(w, 2) + 8;
    if (x >= mid_l and x < mid_r) return .middle_dead;
    return .widget;
}

pub const Click = struct {
    button: u8,
    zone: Zone,
};

pub const PressTarget = enum { none, slot, dead };

/// Classify a press: a painted slot first, else the dead-zone band under the
/// pointer (C++ :295-311: press records the slot, release dispatches slot
/// click on match or dead-zone action on miss).
pub fn classifyPress(hits: []const types.WidgetHit, px: f64, py: f64) struct {
    target: PressTarget,
    index: i32,
} {
    const idx = types.hitIndexAt(hits, px, py);
    if (idx >= 0) return .{ .target = .slot, .index = idx };
    return .{ .target = .dead, .index = -1 };
}

/// Release routing (C++ :302-311): slot release on the pressed slot clicks
/// it, anything else on empty space fires the dead zone.
pub const Release = enum { none, click_slot, dead_zone };

pub fn classifyRelease(hit_idx: i32, pressed_idx: i32) Release {
    if (hit_idx >= 0 and hit_idx == pressed_idx) return .click_slot;
    if (hit_idx < 0) return .dead_zone;
    return .none;
}

/// Vertical scroll over empty bar space adjusts the sink (C++ :315-326).
/// Null when the event is not a volume scroll.
pub fn scrollVolume(delta: f64, hover_slot: i32, scroll_volume: bool, cur_01: f64) ?f64 {
    return core.scrollVolumeNext(scroll_volume, hover_slot, true, delta, cur_01);
}

test "panel-input: dead zones + widget" {
    const t = std.testing;
    try t.expectEqual(Zone.left_dead, hitTest(5, 1920, 16, 16));
    try t.expectEqual(Zone.right_dead, hitTest(1910, 1920, 16, 16));
    try t.expectEqual(Zone.middle_dead, hitTest(960, 1920, 16, 16));
    try t.expectEqual(Zone.widget, hitTest(500, 1920, 16, 16));
    try t.expectEqual(Zone.none, hitTest(-1, 1920, 16, 16));
    try t.expectEqual(Zone.none, hitTest(1920, 1920, 16, 16));
}

test "panel-input: press prefers slots, release routes clicks" {
    const t = std.testing;
    const hits = [_]types.WidgetHit{
        .{ .widget_id = "clock", .x = 16, .y = 0, .w = 80, .h = 36 },
        .{ .widget_id = "tray", .x = 96, .y = 0, .w = 44, .h = 36 },
    };
    try t.expectEqual(PressTarget.slot, classifyPress(&hits, 20, 18).target);
    try t.expectEqual(@as(i32, 0), classifyPress(&hits, 20, 18).index);
    try t.expectEqual(PressTarget.dead, classifyPress(&hits, 4, 18).target);
    try t.expectEqual(Release.click_slot, classifyRelease(0, 0));
    try t.expectEqual(Release.none, classifyRelease(1, 0));
    try t.expectEqual(Release.dead_zone, classifyRelease(-1, 0));
    try t.expectEqual(@as(?f64, 0.55), scrollVolume(-15, -1, true, 0.5));
    try t.expect(scrollVolume(-15, 2, true, 0.5) == null);
}
