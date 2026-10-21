//! Output assignment — which output a
//! popup belongs to and the margins that put it there.
//!
//! Wayland objects are deliberately absent: the caller resolves the layer
//! index to a `wl_output*` itself. What is tested here is the selection
//! order (pressed → pointer → first configured → first layer) and the margin
//! math (delegate to `shared/popup_position.zig`, clearance from settings).

const std = @import("std");
const popup_position = @import("../shared/popup_position.zig");
const settings_mod = @import("settings.zig");

pub const PlacedPopup = struct {
    margin_left: i32 = 0,
    margin_bottom: i32 = 0,
    clearance: i32 = 0,
};

/// Pick the reference layer index for popups:
/// pressed layer first, then the pointer layer, then the first configured
/// one, then layer 0 when nothing is configured.
pub fn refLayer(
    pressed_idx: i32,
    pointer_idx: usize,
    configured: []const bool,
    layer_count: usize,
) ?usize {
    if (pressed_idx >= 0 and @as(usize, @intCast(pressed_idx)) < layer_count) {
        if (@as(usize, @intCast(pressed_idx)) < configured.len and configured[@as(usize, @intCast(pressed_idx))])
            return @intCast(pressed_idx);
    }
    if (pointer_idx < layer_count) {
        if (pointer_idx < configured.len and configured[pointer_idx]) return pointer_idx;
    }
    for (configured, 0..) |c, i| {
        if (c and i < layer_count) return i;
    }
    if (layer_count > 0) return 0;
    return null;
}

/// Layer width for popup clamping: the configured width of the reference
/// layer, or 0 when there is none.
pub fn layerWidth(ref: ?usize, widths: []const i32) i32 {
    const r = ref orelse return 0;
    if (r < widths.len and widths[r] > 0) return widths[r];
    return 0;
}

/// Center `popup_w` on `anchor_x` inside a `layer_w`-wide bar. Output width
/// is unknown to the taskbar child (compositor picks the output), so the
/// bar's own width is the clamp — `output_w = 0` in shared terms.
pub fn computePopupPosition(
    anchor_x: i32,
    popup_w: i32,
    layer_w: i32,
    s: *const settings_mod.Settings,
) PlacedPopup {
    const clearance = settings_mod.popupBottomClearancePx(s);
    const placed = popup_position.place(.{
        .anchor_x = @floatFromInt(anchor_x),
        .popup_w = @floatFromInt(@max(1, popup_w)),
        .layer_w = @floatFromInt(@max(0, layer_w)),
        .layer_origin_x = 0.0,
        .output_w = 0.0,
        .bottom_clearance = @floatFromInt(clearance),
    });
    return .{
        .margin_left = @intFromFloat(@round(placed.margin_left)),
        .margin_bottom = @intFromFloat(@round(placed.margin_bottom)),
        .clearance = clearance,
    };
}

test "taskbar-position: ref layer order" {
    const t = std.testing;
    const cfg = [_]bool{ false, true, true };
    try t.expectEqual(@as(?usize, 1), refLayer(1, 2, &cfg, 3));
    try t.expectEqual(@as(?usize, 2), refLayer(-1, 2, &cfg, 3));
    try t.expectEqual(@as(?usize, 1), refLayer(-1, 0, &cfg, 3));
    try t.expectEqual(@as(?usize, 0), refLayer(-1, 5, &[_]bool{false}, 1));
    try t.expect(refLayer(-1, 0, &[_]bool{}, 0) == null);
}

test "taskbar-position: popup clamps to the bar" {
    const t = std.testing;
    const s = settings_mod.Settings{ .height = 48, .width_mode = 1 };
    const mid = computePopupPosition(500, 200, 1000, &s);
    try t.expectEqual(@as(i32, 400), mid.margin_left);
    try t.expectEqual(@as(i32, 48), mid.margin_bottom);
    const edge = computePopupPosition(0, 200, 1000, &s);
    try t.expectEqual(@as(i32, 0), edge.margin_left);
}
