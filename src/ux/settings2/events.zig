const std = @import("std");
const app_mod = @import("app.zig");
const common = @import("common.zig");

// Event routing.
// table only; per-tab hit tests live in their tab files).
// Same design: pointer down/move/up + wheel + keys route by region
// (sidebar vs content vs dropdown popup vs modal), with draw-coalescing
// input marking.

pub const Region = enum {
    sidebar,
    content,
    dropdown_popup,
    modal,
    chrome,
};

pub fn regionFor(px: i32, py: i32, width: i32, sidebar_w: i32) Region {
    _ = width;
    if (px < sidebar_w + 16) return .sidebar;
    if (py < 48) return .chrome;
    return .content;
}

pub const PointerButton = enum { left, middle, right };

pub const DispatchResult = struct {
    consumed: bool,
    needs_redraw: bool,
    new_tab: ?i32 = null,
};

pub fn dispatchPointerDown(region: Region, tab: i32) DispatchResult {
    switch (region) {
        .sidebar => return .{ .consumed = true, .needs_redraw = true, .new_tab = tab },
        .content => return .{ .consumed = true, .needs_redraw = true },
        .dropdown_popup => return .{ .consumed = true, .needs_redraw = true },
        .modal => return .{ .consumed = true, .needs_redraw = true },
        .chrome => return .{ .consumed = false, .needs_redraw = false },
    }
}

pub fn railRowAt(py: i32, scroll_px: i32) ?usize {
    const base: i32 = common.rail_base_y - scroll_px;
    if (py < base) return null;
    const idx: i32 = @divTrunc(py - base, common.rail_pitch_y);
    if (idx < 0 or idx >= app_mod.sidebar_categories.len) return null;
    return @intCast(idx);
}

pub fn wheelDeltaToScroll(notch: f64) f64 {
    // Matches settings_scroll wheel step: 3 lines * ~20px.
    return notch * 60.0;
}

test "settings-events: regions + rail rows" {
    const t = std.testing;
    try t.expectEqual(Region.sidebar, regionFor(10, 200, 900, 360));
    try t.expectEqual(Region.content, regionFor(500, 200, 900, 360));
    const r = dispatchPointerDown(.sidebar, 8);
    try t.expect(r.consumed and r.needs_redraw);
    try t.expectEqual(@as(i32, 14), common.rail_base_y);
    try t.expect(railRowAt(14, 0) != null);
    try t.expect(railRowAt(10, 0) == null);
    try t.expectEqual(@as(f64, 60), wheelDeltaToScroll(1));
}
