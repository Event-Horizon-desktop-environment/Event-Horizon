const std = @import("std");

/// Pointer coordinate mapping across per-output desktop layers.
/// Pointer-to-local coordinate conversion.
///
/// Each layer lives on one output with a global origin (`global_x/global_y`).
/// When the pointer is over the wanted layer the local coords are the raw
/// pointer coords; otherwise they are translated through global space:
/// `gx = under.global + pointer; local = gx - want.global`.

pub const OutputBounds = struct {
    global_x: i32,
    global_y: i32,
};

/// Returns local coords in the wanted layer, or null when the mapping is
/// impossible (bad index / missing output).
pub fn localXy(
    pointer_x: f64,
    pointer_y: f64,
    pointer_layer: usize,
    want_layer: usize,
    bounds_by_layer: []const ?OutputBounds,
) ?struct { x: f64, y: f64 } {
    if (want_layer >= bounds_by_layer.len) return null;
    if (pointer_layer >= bounds_by_layer.len) return null;
    const want = bounds_by_layer[want_layer] orelse return null;
    const under = bounds_by_layer[pointer_layer] orelse return null;
    if (pointer_layer == want_layer) return .{ .x = pointer_x, .y = pointer_y };
    const gx = @as(f64, @floatFromInt(under.global_x)) + pointer_x;
    const gy = @as(f64, @floatFromInt(under.global_y)) + pointer_y;
    return .{
        .x = gx - @as(f64, @floatFromInt(want.global_x)),
        .y = gy - @as(f64, @floatFromInt(want.global_y)),
    };
}

/// Convert a drag position from one layer's coords to another's
/// (coordinate conversion).
pub fn convertBetweenLayers(
    x: f64,
    y: f64,
    from: ?OutputBounds,
    to: ?OutputBounds,
) ?struct { x: f64, y: f64 } {
    const f = from orelse return null;
    const t = to orelse return null;
    const gx = @as(f64, @floatFromInt(f.global_x)) + x;
    const gy = @as(f64, @floatFromInt(f.global_y)) + y;
    return .{
        .x = gx - @as(f64, @floatFromInt(t.global_x)),
        .y = gy - @as(f64, @floatFromInt(t.global_y)),
    };
}

test "pointer: same layer is identity" {
    const t = std.testing;
    const bounds = [_]?OutputBounds{ .{ .global_x = 0, .global_y = 0 }, .{ .global_x = 1920, .global_y = 0 } };
    const p = localXy(100, 200, 0, 0, &bounds).?;
    try t.expectEqual(@as(f64, 100), p.x);
    try t.expectEqual(@as(f64, 200), p.y);
}

test "pointer: cross-output translation" {
    const t = std.testing;
    const bounds = [_]?OutputBounds{ .{ .global_x = 0, .global_y = 0 }, .{ .global_x = 1920, .global_y = 0 } };
    // Pointer at x=100 on output 1 (global 2020) seen from output 0.
    const p = localXy(100, 50, 1, 0, &bounds).?;
    try t.expectEqual(@as(f64, 2020), p.x);
    try t.expectEqual(@as(f64, 50), p.y);
    try t.expect(localXy(0, 0, 5, 0, &bounds) == null);
    try t.expect(convertBetweenLayers(10, 10, null, bounds[0]) == null);
}
