const std = @import("std");
const common = @import("common.zig");

// Hyprland tab (incl. m3 sub-states, anim popup, bezier editor). The
// sections are the rail's sub pages — one sidebar tab each
// (`app.hyprland_subs`, General=64 … Quirks=78) — so there is no in-page
// child strip: the content column starts at the design-B page top like
// every other card page. Card sliders mirror hyprland.conf keys, bezier
// P1/P2 drag in a 230x230 pad.

/// Sidebar tab ids of the section pages (`app.TabId.hyprland_first/last`).
pub const first_tab_id: i32 = 64;
pub const last_tab_id: i32 = 78;

/// Section order (`child_tabs`, General=0 … Quirks=14) — the rail subs
/// (`app.hyprland_subs`) walk these in the same order.
pub const child_tabs = [_][]const u8{
    "General", "Decoration", "Input",   "Binds",   "Dwindle",
    "Master",  "Scrolling",  "Animations", "Misc", "Render",
    "Cursor",  "Group",      "XWayland", "OpenGL", "Quirks",
};

/// True when `tab` selects a Hyprland section page.
pub fn isSectionTab(tab: i32) bool {
    return tab >= first_tab_id and tab <= last_tab_id;
}

/// Section index of an active tab id (0 when it is not a section page).
pub fn sectionOf(tab: i32) i32 {
    if (!isSectionTab(tab)) return 0;
    return tab - first_tab_id;
}

/// Width of the Layout dropdown on the General tab (`kComboW`).
pub const layout_combo_w: i32 = 140;
pub const layout_options = [_][]const u8{ "dwindle", "master", "scrolling", "monocle" };

/// Anim 3-dot trigger geometry (`kHyprAnimDotRight/HitW/HitH`).
pub const anim_dot_right: i32 = common.card_pad + 12; // 28
pub const anim_dot_hit_w: i32 = 12;
pub const anim_dot_hit_h: i32 = 12;

/// Bezier editor popup.
pub const bezier_pop_w: i32 = 360;
pub const bezier_pop_h: i32 = 360;
pub const bezier_grid_off_x: i32 = 50;
pub const bezier_grid_off_y: i32 = 45;
pub const bezier_grid_size: i32 = 230;

/// Anim editor popup.
pub const anim_pop_w: i32 = 340;
pub const anim_pop_h: i32 = 300;

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Anim 3-dot center for a 60px toggle-pitch row (`hyprland_paint_anim_card`).
pub fn animDotCenter(card_x: i32, card_w: i32, row_y: i32) struct { x: i32, cy: i32 } {
    return .{
        .x = card_x + card_w - anim_dot_right,
        .cy = row_y + @divTrunc(60, 2),
    };
}

pub fn hitAnimDot(px: f64, py: f64, card_x: i32, card_w: i32, row_y: i32) bool {
    const d = animDotCenter(card_x, card_w, row_y);
    const dx = px - @as(f64, @floatFromInt(d.x));
    const dy = py - @as(f64, @floatFromInt(d.cy));
    return @abs(dx) < @as(f64, anim_dot_hit_w) and @abs(dy) < @as(f64, anim_dot_hit_h);
}

/// Anim popup rect: centered in the content box, top at kContentTop+40.
pub fn animPopupRect(content_x: i32, content_w: i32) Rect {
    return .{
        .x = content_x + @divTrunc(content_w - anim_pop_w, 2),
        .y = common.content_top + 40,
        .w = anim_pop_w,
        .h = anim_pop_h,
    };
}

/// Bezier popup rect. `contentX` is ignored here
/// (`popX = (contentW - popW) / 2`), keeping
/// the same formula for paint/hit agreement; see the doc note in
/// `hyprland_bezier.zig`.
pub fn bezierPopupRect(content_w: i32) Rect {
    return .{
        .x = @divTrunc(content_w - bezier_pop_w, 2),
        .y = common.content_top + 20,
        .w = bezier_pop_w,
        .h = bezier_pop_h,
    };
}

// Per-window Hyprland UI state. The data layer
// (`hyprland_data`) is already module-global; this mirrors the m3 singleton
// states. The open section is the sidebar tab itself (`Content.active_tab`
// naming one of the rail sub ids), everything else lives here.

/// `k_anim_entries` index under edit, or -1. Resolved by name against
/// `hyprland_data` (name lookup, since index lookup
/// mismatches when entries are missing).
pub var anim_edit_idx: i32 = -1;
pub var anim_curve_open: bool = false;
pub var anim_curve_hover: i32 = -1;
pub var anim_style_open: bool = false;
pub var anim_style_hover: i32 = -1;
pub var anim_speed_active: bool = false;
pub var anim_speed_buf: [32]u8 = @as([32]u8, @splat(0));
pub var anim_speed_len: usize = 0;
pub var bezier_open: bool = false;
pub var bezier_drag: i32 = -1;
pub var bezier_p1x: f64 = 0.25;
pub var bezier_p1y: f64 = 0.1;
pub var bezier_p2x: f64 = 0.25;
pub var bezier_p2y: f64 = 1.0;

/// The Layout dropdown rides the generic combo machinery (`open_combo` with
/// a 140px box — see `ui_content.comboPopupRect`), so it needs no separate
/// open/hover state.

pub fn resetPopups() void {
    anim_edit_idx = -1;
    anim_curve_open = false;
    anim_curve_hover = -1;
    anim_style_open = false;
    anim_style_hover = -1;
    anim_speed_active = false;
    anim_speed_len = 0;
    bezier_open = false;
    bezier_drag = -1;
}

pub fn animSpeedSlice() []const u8 {
    return anim_speed_buf[0..@min(anim_speed_len, anim_speed_buf.len)];
}

pub fn setAnimSpeedBuf(s: []const u8) void {
    const n = @min(s.len, anim_speed_buf.len);
    @memcpy(anim_speed_buf[0..n], s[0..n]);
    anim_speed_len = n;
}

test "settings-hyprland-tab: section ids and popup geometry" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 15), child_tabs.len);
    try t.expectEqualStrings("Dwindle", child_tabs[4]);
    try t.expectEqualStrings("Animations", child_tabs[7]);
    try t.expectEqualStrings("Quirks", child_tabs[14]);
    // Section ids: General=64 … Quirks=78, contiguous.
    try t.expect(!isSectionTab(63));
    try t.expect(isSectionTab(64));
    try t.expect(isSectionTab(78));
    try t.expect(!isSectionTab(79));
    try t.expectEqual(@as(i32, 6), sectionOf(70));
    try t.expectEqual(@as(i32, 0), sectionOf(33));
    // Anim popup: centered in the content box, below the page header.
    const ar = animPopupRect(292, 592);
    try t.expectEqual(@as(i32, 292 + @divTrunc(592 - anim_pop_w, 2)), ar.x);
    try t.expectEqual(common.content_top + 40, ar.y);
    // Bezier popup: centered over the content width.
    const br = bezierPopupRect(592);
    try t.expectEqual(@as(i32, @divTrunc(592 - bezier_pop_w, 2)), br.x);
    try t.expectEqual(common.content_top + 20, br.y);
    // Anim 3-dot on a 60px row.
    const d = animDotCenter(100, 400, 200);
    try t.expectEqual(@as(i32, 100 + 400 - anim_dot_right), d.x);
    try t.expect(hitAnimDot(@floatFromInt(d.x), 230, 100, 400, 200));
    // Popup state reset.
    anim_edit_idx = 3;
    bezier_open = true;
    resetPopups();
    try t.expectEqual(@as(i32, -1), anim_edit_idx);
    try t.expect(!bezier_open);
}
