//! Taskbar geometry knobs plus the derived helpers every pass shares.
//! geometry knobs plus the derived helpers every pass shares.
//!
//! The struct keeps every field and default; the free
//! functions are the `inline` helpers below it. `globalScale` is the shell's
//! `dock.shellUiScale`, clamped to [0.5, 2.0].

const std = @import("std");

pub const Settings = struct {
    enabled: bool = false,
    width_mode: i32 = 1,
    height: i32 = 48,
    radius: i32 = 0,
    opacity: i32 = 65,
    icon_size: i32 = 38,
    icon_spacing: i32 = 8,
    floating_amount: i32 = 8,
    edge_gap: i32 = 0,
    exclusive_zone_gap: i32 = 0,
    scale: f64 = 1.0,
    icon_theme: []const u8 = "",
    output_name: []const u8 = "",
    group_apps: bool = true,
    show_labels: bool = true,
    collapse_when_full: bool = true,
    thumbnails_enabled: bool = true,
    thumbnail_peek_enabled: bool = true,
    thumbnail_threshold: i32 = 10,
    compact_media: bool = false,
    slot_pill_opacity: i32 = 100,
    position_top: bool = false,
    auto_hide: bool = false,
    tooltips_enabled: bool = true,
    pinned_apps_tray_pill: bool = false,
    running_apps_tray_pill: bool = false,
    widgets_enabled: bool = true,
    border: bool = false,
    border_size: i32 = 1,
    ui_global_scale: f64 = 1.0,
};

fn clampScale(v: f64) f64 {
    return std.math.clamp(v, 0.5, 2.0);
}

/// Guarantees 8 ui-scale px of breathing room above and below the icon
/// square. Idempotent with an already-normalized `height`.
pub fn effectiveHeightPx(s: *const Settings, global_scale: f64) i32 {
    const ui = clampScale(s.scale) * clampScale(global_scale);
    const need = @ceil(@as(f64, @floatFromInt(s.icon_size)) * ui) + 2.0 * @ceil(8.0 * ui);
    const need_i: i32 = @intFromFloat(@round(need));
    return @max(s.height, need_i);
}

/// Inner padding between the widget strip and the bar's rounded ends.
pub fn stripPadPx(ui_scale: f64) f64 {
    return 16.0 * ui_scale;
}

/// Minimum breathing gap between the left/center/right sections.
pub fn sectionGapPx(ui_scale: f64) f64 {
    return 20.0 * ui_scale;
}

/// Extra space for tiled/maximized windows above the bar. Clamped [0,100].
pub fn exclusiveZoneGapPx(s: *const Settings) i32 {
    return @max(0, @min(100, s.exclusive_zone_gap));
}

/// Margin between the bar and the screen edge. Clamped [0,25].
pub fn edgeGapPx(s: *const Settings) i32 {
    return @max(0, @min(25, s.edge_gap));
}

/// Bottom clearance a popup needs to clear the bar: edge margin plus the
/// floating inset plus the painted bar height (6px taller when floating).
pub fn popupBottomClearancePx(s: *const Settings) i32 {
    const floating = s.width_mode == 0;
    const bar_h = s.height + (if (floating) @as(i32, 6) else 0);
    return (if (floating) s.floating_amount else 0) + edgeGapPx(s) + bar_h;
}

/// Exclusive zone the layer surface reserves (bar height + gap).
pub fn exclusiveZonePx(s: *const Settings, global_scale: f64) i32 {
    return effectiveHeightPx(s, global_scale) + exclusiveZoneGapPx(s);
}

test "taskbar-settings: effective height grows for big icons" {
    const t = std.testing;
    var s = Settings{ .icon_size = 38, .height = 48, .scale = 1.0 };
    try t.expectEqual(@as(i32, 54), effectiveHeightPx(&s, 1.0));
    s.icon_size = 16;
    try t.expectEqual(@as(i32, 48), effectiveHeightPx(&s, 1.0));
}

test "taskbar-settings: gaps and clearances" {
    const t = std.testing;
    const s = Settings{ .edge_gap = 40, .exclusive_zone_gap = 200, .height = 48, .floating_amount = 8, .width_mode = 0 };
    try t.expectEqual(@as(i32, 25), edgeGapPx(&s));
    try t.expectEqual(@as(i32, 100), exclusiveZoneGapPx(&s));
    // floating: 8 + 25 + (48+6) = 87
    try t.expectEqual(@as(i32, 87), popupBottomClearancePx(&s));
    const e = Settings{ .width_mode = 1, .height = 48 };
    try t.expectEqual(@as(i32, 48), popupBottomClearancePx(&e));
}
