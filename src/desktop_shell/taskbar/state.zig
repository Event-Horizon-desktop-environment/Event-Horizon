//! Runtime
//! state behind the bar: hover/press routing across output layers, autohide,
//! tooltips, launch bounce, hover previews and per-frame label budgets.
//!
//! Wayland handles live one layer up (`bin/taskbar.zig`); this is the logic
//! that can be tested without a compositor.

const std = @import("std");
const types = @import("types.zig");

/// Which layer the pointer is on (`tb_pointer_layer`): the tracked
/// index wins when it names a live layer, else layer 0, else none.
pub fn pointerLayer(tracked: usize, layer_count: usize) ?usize {
    if (tracked < layer_count) return tracked;
    if (layer_count > 0) return 0;
    return null;
}

/// Hits for one output layer. With output=all each monitor keeps its own
/// geometry; fall back to the first non-empty layer, then empty.
pub fn hitsForLayer(
    layers: []const []const types.WidgetHit,
    layer: i32,
) []const types.WidgetHit {
    if (layer >= 0 and @as(usize, @intCast(layer)) < layers.len) return layers[@as(usize, @intCast(layer))];
    for (layers) |l| {
        if (l.len > 0) return l;
    }
    return &.{};
}

pub fn hitAt(hits: []const types.WidgetHit, px: f64, py: f64) ?usize {
    for (hits, 0..) |*h, i| {
        if (h.contains(px, py)) return i;
    }
    return null;
}

pub const Autohide = struct {
    reveal: bool = false,
    offset_px: f64 = 0,
    target_px: f64 = 0,

    /// Apply the auto-hide state: revealed bars sit at 0, hidden bars park
    /// one bar-height below (or above when `position_top`).
    pub fn apply(self: *Autohide, auto_hide: bool, bar_h: f64) void {
        if (!auto_hide) {
            self.reveal = true;
            self.offset_px = 0;
            self.target_px = 0;
            return;
        }
        self.target_px = if (self.reveal) 0 else bar_h;
    }
};

// The damped-sine icon bounce the dock plays on activation (`cold_start`
// = longer/shallower when launched from scratch).

pub const bounce_id_none: u32 = 0;

pub fn bounceLift(elapsed_ms: f64, cold_start: bool) f64 {
    const dur: f64 = if (cold_start) 700 else 420;
    if (elapsed_ms < 0 or elapsed_ms >= dur) return 0;
    const t = elapsed_ms / dur;
    const amp: f64 = if (cold_start) 14 else 8;
    return amp * @sin(t * std.math.pi * 2.0) * (1.0 - t);
}

pub const tooltip_delay_ms: u64 = 500;

pub fn tooltipDue(hover_slot: i32, hover_start_ms: u64, shown_slot: i32, now_ms: u64, enabled: bool) bool {
    if (!enabled or hover_slot < 0 or hover_slot == shown_slot) return false;
    return now_ms -| hover_start_ms >= tooltip_delay_ms;
}

pub const ThumbState = struct {
    group_key: []const u8 = "",
    anchor_x: i32 = 0,
    hover_row: i32 = -1,
    close_hover: bool = false,
    list_mode: bool = false,
    window_count: usize = 0,

    pub fn clear(self: *ThumbState) void {
        self.* = .{};
    }

    /// Decide list vs card mode from the window count and the threshold
    /// (`clamp(threshold, 3, 20)`).
    pub fn decideListMode(count: usize, threshold: i32) bool {
        return @as(i32, @intCast(count)) > std.math.clamp(threshold, 3, 20);
    }
};

/// Strip `%x` field codes from an Exec line (`%%` → `%`), trimming trailing
/// whitespace, per `strip_field_codes`.
pub fn stripFieldCodes(gpa: std.mem.Allocator, exec: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < exec.len) : (i += 1) {
        if (exec[i] == '%' and i + 1 < exec.len) {
            if (exec[i + 1] == '%') try out.append(gpa, '%');
            i += 1;
            continue;
        }
        try out.append(gpa, exec[i]);
    }
    while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\t')) {
        _ = out.pop();
    }
    return out.toOwnedSlice(gpa);
}

test "taskbar-state: layer routing" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 1), pointerLayer(1, 3));
    try t.expectEqual(@as(?usize, 0), pointerLayer(9, 3));
    try t.expect(pointerLayer(0, 0) == null);
    const l0 = [_]types.WidgetHit{.{ .x = 0, .y = 0, .w = 10, .h = 10 }};
    const layers = [_][]const types.WidgetHit{ &.{}, &l0 };
    try t.expectEqual(@as(usize, 1), hitsForLayer(&layers, 5).len);
    try t.expectEqual(@as(?usize, 0), hitAt(&l0, 5, 5));
    try t.expect(hitAt(&l0, 50, 5) == null);
}

test "taskbar-state: bounce and tooltip" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 0), bounceLift(9999, true));
    try t.expect(bounceLift(50, false) != 0);
    try t.expect(tooltipDue(2, 0, -1, 600, true));
    try t.expect(!tooltipDue(2, 0, 2, 600, true));
    try t.expect(!tooltipDue(2, 0, -1, 100, true));
    var ah = Autohide{ .reveal = false };
    ah.apply(true, 48);
    try t.expectEqual(@as(f64, 48), ah.target_px);
}

test "taskbar-state: thumbs and exec" {
    const t = std.testing;
    try t.expect(ThumbState.decideListMode(11, 10));
    try t.expect(!ThumbState.decideListMode(3, 10));
    const s = try stripFieldCodes(t.allocator, "firefox %U  ");
    defer t.allocator.free(s);
    try t.expectEqualStrings("firefox", s);
    const pct = try stripFieldCodes(t.allocator, "a %% b");
    defer t.allocator.free(pct);
    try t.expectEqualStrings("a % b", pct);
}
