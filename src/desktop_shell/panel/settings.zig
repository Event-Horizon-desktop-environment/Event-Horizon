//! Panel settings helpers — port of
//! `src/desktop_shell/panel/core/panel_settings.hpp:72-103`.
//!
//! Storage lives in `config/schema1.zig:PanelSettings` (snake_case); this
//! file is the behavior: effective height, paddings, exclusive-zone gap,
//! popup clearance, and the width-mode predicates. All formulas are the C++
//! ones, including the clamp ranges.

const std = @import("std");
const schema1 = @import("../../config/schema1.zig");

pub const PanelSettings = schema1.PanelSettings;

fn clampF(v: f64, lo: f64, hi: f64) f64 {
    return @min(hi, @max(lo, v));
}

/// `panel_effective_height_px` (`panel_settings.hpp:74-78`): guarantees
/// breathing room above/below the icon square so widgets never paint flush
/// against the rounded ends.
pub fn effectiveHeightPx(s: *const PanelSettings, global_scale: f64) i32 {
    const ui = clampF(s.scale, 0.5, 2.0) * clampF(global_scale, 0.5, 2.0);
    const need_f: f64 = @ceil(@as(f64, @floatFromInt(s.icon_size)) * ui) + 2.0 * @ceil(6.0 * ui);
    const need: i32 = @intFromFloat(@round(need_f));
    return @max(s.height, need);
}

/// `panel_strip_pad_px` (`:83`): inner padding between the widget strip and
/// the bar's rounded ends.
pub fn stripPadPx(ui_scale: f64) f64 {
    return 16.0 * ui_scale;
}

/// `panel_section_gap_px` (`:84`): minimum gap between left/center/right.
pub fn sectionGapPx(ui_scale: f64) f64 {
    return 20.0 * ui_scale;
}

/// `panel_exclusive_zone_gap_px` (`:86-88`).
pub fn exclusiveZoneGapPx(s: *const PanelSettings) i32 {
    return @max(0, @min(100, s.exclusive_zone_gap));
}

/// `panel_edge_gap_px` (`:90`).
pub fn edgeGapPx(s: *const PanelSettings) i32 {
    return @max(0, @min(25, s.edge_gap));
}

/// `panel_popup_clearance_px` (`:95-99`): clearance a popup needs to clear
/// the bar — edge margin (+ floating inset) plus painted bar height. Mirrors
/// the layer margins set at surface creation.
pub fn popupClearancePx(s: *const PanelSettings) i32 {
    const floating = s.width_mode == 0;
    const bar_h = s.height + if (floating) @as(i32, 4) else 0;
    return (if (floating) s.floating_amount else 0) + edgeGapPx(s) + bar_h;
}

/// `panel_is_floating` (`:101`).
pub fn isFloating(s: *const PanelSettings) bool {
    return s.width_mode == 0;
}

/// `panel_is_fill` (`:102`).
pub fn isFill(s: *const PanelSettings) bool {
    return s.width_mode == 2;
}

/// Combined UI scale the painter uses (`panel_paint.cpp:76-79`):
/// `clamp(settings.scale) * clamp(global)`.
pub fn uiScale(panel_scale: f64, global_scale: f64) f64 {
    return clampF(panel_scale, 0.5, 2.0) * clampF(global_scale, 0.5, 2.0);
}

test "panel-settings: effective height guarantees breathing room" {
    const t = std.testing;
    var s = PanelSettings{ .height = 20, .icon_size = 22, .scale = 1.0 };
    // need = ceil(22) + 2*ceil(6) = 34 > height 20
    try t.expectEqual(@as(i32, 34), effectiveHeightPx(&s, 1.0));
    s.height = 48;
    try t.expectEqual(@as(i32, 48), effectiveHeightPx(&s, 1.0));
    // 2x UI scale doubles the need: ceil(44)+2*ceil(12) = 68
    var s2 = PanelSettings{ .height = 20, .icon_size = 22, .scale = 2.0 };
    try t.expectEqual(@as(i32, 68), effectiveHeightPx(&s2, 1.0));
}

test "panel-settings: popup clearance mirrors layer margins" {
    const t = std.testing;
    var s = PanelSettings{ .height = 36, .width_mode = 1, .edge_gap = 0, .floating_amount = 8 };
    try t.expectEqual(@as(i32, 36), popupClearancePx(&s));
    s.width_mode = 0; // floating: inset + edge + (height+4)
    try t.expectEqual(@as(i32, 8 + 0 + 40), popupClearancePx(&s));
    s.edge_gap = 4;
    try t.expectEqual(@as(i32, 8 + 4 + 40), popupClearancePx(&s));
    try t.expect(isFloating(&s));
    try t.expect(!isFill(&s));
    s.width_mode = 2;
    try t.expect(isFill(&s));
}

test "panel-settings: gap clamps" {
    const t = std.testing;
    var s = PanelSettings{ .edge_gap = 99, .exclusive_zone_gap = 999 };
    try t.expectEqual(@as(i32, 25), edgeGapPx(&s));
    try t.expectEqual(@as(i32, 100), exclusiveZoneGapPx(&s));
    try t.expectEqual(@as(f64, 16.0), stripPadPx(1.0));
    try t.expectEqual(@as(f64, 20.0), sectionGapPx(1.0));
    try t.expectEqual(@as(f64, 4.0), uiScale(2.0, 2.0));
}
