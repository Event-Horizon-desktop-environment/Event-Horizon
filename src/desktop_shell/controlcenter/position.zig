//! Popup placement: where a popup's
//! layer surface goes: centered on the spawning slot's anchor X, clamped
//! onto the dock surface and the output. Paint and hit-testing never see
//! these output coordinates (everything they do is surface-local); only
//! the layer-surface margins carry the placement
//! (`dock_popup_compute_layer_margins` + `compute_popup_position`).

const std = @import("std");

pub const Input = struct {
    /// Slot centre X in dock-surface coordinates.
    anchor_x: i32 = 0,
    popup_w: i32 = 0,
    popup_h: i32 = 0,
    /// Output logical width (0 when unknown — falls back to the layer).
    output_w: i32 = 0,
    /// Dock layer surface width.
    layer_w: i32 = 0,
    /// Dock surface's X offset on the output (centered dock).
    layer_origin_x: i32 = 0,
    /// Bottom margin: dock height + gap above it.
    bottom_clearance: i32 = 0,
};

pub const Output = struct {
    margin_left: i32 = 0,
    margin_bottom: i32 = 0,
};

pub fn computeMargins(in: Input) Output {
    var out = Output{ .margin_bottom = in.bottom_clearance };
    const want_left = in.anchor_x - @divTrunc(in.popup_w, 2);
    const max_from_layer = @max(0, in.layer_w - in.popup_w);
    const max_from_output = if (in.output_w > 0)
        @max(0, in.output_w - in.popup_w - in.layer_origin_x)
    else
        max_from_layer;
    const max_want = @max(max_from_layer, max_from_output);
    out.margin_left = in.layer_origin_x + std.math.clamp(want_left, 0, max_want);
    return out;
}

/// Dock surface origin on the output when centered (`dock_layer_origin_x_
/// on_output`: half the leftover, floored at zero).
pub fn layerOriginX(output_w: i32, layer_w: i32) i32 {
    if (output_w <= 0 or layer_w <= 0) return 0;
    return @max(0, @divTrunc(output_w - layer_w, 2));
}

/// Logical output width from a physical mode + scale (`wl_output` gives no
/// logical size without xdg-output; mode/scale is the honest approximation).
pub fn logicalW(mode_w: i32, scale: i32) i32 {
    if (mode_w <= 0) return 0;
    return @max(1, @divTrunc(mode_w, @max(1, scale)));
}

test "cc-position: popup centers on the anchor" {
    const t = std.testing;
    // 1920 output, 1000 dock centered (origin 460), slot at dock x 800,
    // 620 popup: want 800-310=490, clamps pass, margin = 460+490 = 950.
    const m = computeMargins(.{
        .anchor_x = 800,
        .popup_w = 620,
        .popup_h = 600,
        .output_w = 1920,
        .layer_w = 1000,
        .layer_origin_x = 460,
        .bottom_clearance = 80,
    });
    try t.expectEqual(@as(i32, 950), m.margin_left);
    try t.expectEqual(@as(i32, 80), m.margin_bottom);
}

test "cc-position: clamps to the layer and output edges" {
    const t = std.testing;
    // Slot at the dock's left edge: want goes negative, clamps to the dock
    // origin (clamped to `[0, max_want]`).
    const l = computeMargins(.{
        .anchor_x = 10,
        .popup_w = 620,
        .popup_h = 600,
        .output_w = 1920,
        .layer_w = 1000,
        .layer_origin_x = 460,
        .bottom_clearance = 80,
    });
    try t.expectEqual(@as(i32, 460), l.margin_left);
    // No output info: layer clamp only (1000-620=380).
    const r = computeMargins(.{
        .anchor_x = 990,
        .popup_w = 620,
        .popup_h = 600,
        .output_w = 0,
        .layer_w = 1000,
        .layer_origin_x = 0,
        .bottom_clearance = 80,
    });
    try t.expectEqual(@as(i32, 380), r.margin_left);
    // Popup wider than the dock: hugs the dock's left edge, never negative.
    const w = computeMargins(.{
        .anchor_x = 500,
        .popup_w = 1200,
        .popup_h = 600,
        .output_w = 1920,
        .layer_w = 1000,
        .layer_origin_x = 460,
        .bottom_clearance = 80,
    });
    try t.expectEqual(@as(i32, 460), w.margin_left);
}

test "cc-position: origin and logical width helpers" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 460), layerOriginX(1920, 1000));
    try t.expectEqual(@as(i32, 0), layerOriginX(0, 1000));
    try t.expectEqual(@as(i32, 0), layerOriginX(800, 1000));
    try t.expectEqual(@as(i32, 1920), logicalW(1920, 1));
    try t.expectEqual(@as(i32, 960), logicalW(1920, 2));
    try t.expectEqual(@as(i32, 0), logicalW(0, 1));
}
