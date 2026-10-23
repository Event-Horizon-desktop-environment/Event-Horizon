const std = @import("std");
const common = @import("common.zig");

// Hyprland tab — Zig port of settings_tab_hyprland/* (incl. m3 sub-states,
// anim popup, bezier editor). Same design: child tabs per section, card
// sliders mirror hyprland.conf keys, bezier P1/P2 drag in a 200x200 pad.
//
// Geometry mirrors `settings_tab_hyprland.cpp` + `m3/hyprland_m3_layout.hpp`
// exactly: 68% centered column, content top 122, child bar
// (contentX+8, 16, contentW-16, 42) r10 with 108x34 tabs at gap 8,
// Layout combo 140 wide, anim 3-dot at card-right minus (pad+12).

/// Sidebar tab id (`app.TabId.hyprland`).
pub const tab_id: i32 = 33;

/// Content top below the tab's own child-tab strip — hardcoded 122 in C++
/// (`kHyprlandContentTop = kContentTop + kDockChildTabH + 12` with the
/// Hyprland strip 72px taller than the generic one because the strip itself
/// is 42px, not 40px, and cards start 64px below it).
pub const content_top: i32 = 122;

/// C++ `kHyprChildLabels` order — the dispatch switch order in
/// `settings_tab_hyprland.cpp` (General=0 … Quirks=14).
pub const child_tabs = [_][]const u8{
    "General", "Decoration", "Input",   "Binds",   "Dwindle",
    "Master",  "Scrolling",  "Animations", "Misc", "Render",
    "Cursor",  "Group",      "XWayland", "OpenGL", "Quirks",
};

/// Child-tab bar metrics (`kTabW`, `kChildTabGap`, `kDockChildTabH`).
pub const tab_w: i32 = 108;
pub const tab_gap: i32 = 8;
pub const tab_h: i32 = 34;
pub const bar_h: i32 = tab_h + 8; // 42
pub const bar_radius: f64 = 10.0;
pub const bar_hit_pad: i32 = 6;

/// Width of the Layout dropdown on the General tab (`kComboW`).
pub const layout_combo_w: i32 = 140;
pub const layout_options = [_][]const u8{ "dwindle", "master", "scrolling", "monocle" };

/// Anim 3-dot trigger geometry (`kHyprAnimDotRight/HitW/HitH`).
pub const anim_dot_right: i32 = common.card_pad + 12; // 28
pub const anim_dot_hit_w: i32 = 12;
pub const anim_dot_hit_h: i32 = 12;

/// Bezier editor popup (`hyprland_bezier.cpp`).
pub const bezier_pop_w: i32 = 360;
pub const bezier_pop_h: i32 = 360;
pub const bezier_grid_off_x: i32 = 50;
pub const bezier_grid_off_y: i32 = 45;
pub const bezier_grid_size: i32 = 230;

/// Anim editor popup (`hyprland_anim_popup.cpp`).
pub const anim_pop_w: i32 = 340;
pub const anim_pop_h: i32 = 300;

/// Total width of all 15 tabs including gaps: 15*108 + 14*8 = 1732.
pub fn tabsW() i32 {
    const n: i32 = @intCast(child_tabs.len);
    return n * tab_w + (n - 1) * tab_gap;
}

/// Horizontal overflow of the tab strip inside a content box.
pub fn tabBarOverflowPx(content_w: i32) i32 {
    const bar_w = content_w - 16;
    return @max(0, tabsW() - (bar_w - 8));
}

pub fn clampTabScroll(scroll_px: i32, content_w: i32) i32 {
    const overflow = tabBarOverflowPx(content_w);
    return std.math.clamp(scroll_px, 0, overflow);
}

/// Center the active tab in the visible strip (C++ `hyprland_center_active_tab`).
pub fn centerActiveTab(child: i32, content_w: i32) i32 {
    const overflow = tabBarOverflowPx(content_w);
    if (overflow <= 0) return 0;
    const tab_center = child * (tab_w + tab_gap) + @divTrunc(tab_w, 2);
    const bar_w = content_w - 16;
    const visible_center = @divTrunc(bar_w - 8, 2);
    return std.math.clamp(tab_center - visible_center, 0, overflow);
}

/// Paint-time tab origin: barX+5, centered when everything fits, otherwise
/// scrolled (`paint_hyprland_child_tab_bar`). Note the hit-test sibling uses
/// barX+4 — the C++ has the same 1px paint/hit asymmetry, kept here so the
/// two agree with their C++ counterparts.
pub fn paintStartX(content_x: i32, content_w: i32, scroll_px: i32) i32 {
    const bar_x = content_x + 8;
    const bar_w = content_w - 16;
    var start_x = bar_x + 5;
    if (tabsW() < bar_w - 10) {
        start_x += @divTrunc(bar_w - 10 - tabsW(), 2);
    } else {
        start_x -= scroll_px;
    }
    return start_x;
}

/// Hit-test tab origin (`hyprland_hit_child_tab`): barX+4, centered when the
/// strip fits, otherwise scrolled.
pub fn hitStartX(content_x: i32, content_w: i32, scroll_px: i32) i32 {
    const bar_x = content_x + 8;
    const bar_w = content_w - 16;
    var start_x = bar_x + 4;
    if (tabsW() < bar_w - 8) {
        start_x += @divTrunc(bar_w - 8 - tabsW(), 2);
    } else {
        start_x -= scroll_px;
    }
    return start_x;
}

/// Child tab index at a window-space point, or -1 (`hyprland_hit_child_tab`).
/// barY = kContentTop+4, tabH = kDockChildTabH.
pub fn hitChildTab(px: f64, py: f64, content_x: i32, content_w: i32, scroll_px: i32) i32 {
    const bar_y: i32 = common.content_top + 4;
    const start_x = hitStartX(content_x, content_w, scroll_px);
    var i: i32 = 0;
    while (i < child_tabs.len) : (i += 1) {
        const tx = start_x + i * (tab_w + tab_gap);
        if (px >= @as(f64, @floatFromInt(tx)) and
            px < @as(f64, @floatFromInt(tx + tab_w)) and
            py >= @as(f64, @floatFromInt(bar_y)) and
            py < @as(f64, @floatFromInt(bar_y + tab_h)))
        {
            return i;
        }
    }
    return -1;
}

/// Window-space hit rect of the scrollable tab strip (C++
/// `hyprland_handle_tab_bar_scroll`: bar + 6px pad on every side).
pub const BarHitRect = struct { x: i32, y: i32, w: i32, h: i32 };

pub fn tabBarHitRect(content_x: i32, content_w: i32) BarHitRect {
    return .{
        .x = content_x + 8,
        .y = common.content_top - bar_hit_pad,
        .w = content_w - 16,
        .h = bar_h + bar_hit_pad * 2,
    };
}

pub fn pointInBarHit(px: f64, py: f64, content_x: i32, content_w: i32) bool {
    const r = tabBarHitRect(content_x, content_w);
    return px >= @as(f64, @floatFromInt(r.x)) and
        px < @as(f64, @floatFromInt(r.x + r.w)) and
        py >= @as(f64, @floatFromInt(r.y)) and
        py < @as(f64, @floatFromInt(r.y + r.h));
}

/// Layout combo rect on the General tab: right-aligned 140px box centered
/// in the 60px row (`hyprland_general_m3.hpp` Layout group).
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub fn layoutComboRect(card_x: i32, card_w: i32, row_y: i32) Rect {
    return .{
        .x = card_x + card_w - common.card_pad - layout_combo_w,
        .y = row_y + @divTrunc(60 - common.settings_combo_h, 2),
        .w = layout_combo_w,
        .h = common.settings_combo_h,
    };
}

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

/// Bezier popup rect. The C++ ignores `contentX` here
/// (`(void)contentX; int popX = (contentW - popW) / 2`), so the port keeps
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

// ---------------------------------------------------------------------------
// Per-window Hyprland UI state (C++ `App::hyprland*` fields). The data layer
// (`hyprland_data`) is already module-global; this mirrors the m3 singleton
// states. `child_tab` itself lives in `Content.sub_for[33]` (the generic
// sub-tab slot), everything else lives here.
// ---------------------------------------------------------------------------

pub var tab_scroll_px: i32 = 0;
/// `k_anim_entries` index under edit, or -1. Resolved by name against
/// `hyprland_data` (the C++ indexes the file-order vector with this, which
/// mismatches when entries are missing; name lookup is the fix).
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
/// open/hover state like the C++ `hyprlandLayoutDropdown*` fields.

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

test "settings-hyprland-tab: bar geometry follows the specified layout" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 33), tab_id);
    try t.expectEqual(@as(i32, 122), content_top);
    try t.expectEqual(@as(usize, 15), child_tabs.len);
    try t.expectEqualStrings("Dwindle", child_tabs[4]);
    try t.expectEqualStrings("Animations", child_tabs[7]);
    try t.expectEqualStrings("Quirks", child_tabs[14]);
    try t.expectEqual(@as(i32, 15 * 108 + 14 * 8), tabsW());
    // Wide content: centered strip.
    try t.expect(tabBarOverflowPx(2000) == 0);
    try t.expectEqual(@as(i32, 0), clampTabScroll(99, 2000));
    // Narrow content: overflow, clamp + center math.
    const ov = tabBarOverflowPx(592);
    try t.expectEqual(@as(i32, 1732 - (592 - 16 - 8)), ov);
    try t.expectEqual(ov, clampTabScroll(ov + 50, 592));
    try t.expectEqual(@as(i32, 0), clampTabScroll(-5, 592));
    const c = centerActiveTab(7, 592);
    try t.expect(c >= 0 and c <= ov);
    // Centered strips coincide: paint centers in barW-10 from barX+5 while
    // hit centers in barW-8 from barX+4, which is the same x by construction.
    // The 1px paint/hit asymmetry (barX+5 vs +4) only shows while scrolled.
    try t.expectEqual(paintStartX(292, 2000, 0), hitStartX(292, 2000, 0));
    try t.expectEqual(paintStartX(292, 592, 10) - 1, hitStartX(292, 592, 10));
    try t.expectEqual(@as(i32, -1), hitChildTab(0, 0, 292, 592, 0));
    // Layout combo: 140 wide, right-aligned, vertically centered in 60px.
    const lr = layoutComboRect(100, 400, 200);
    try t.expectEqual(@as(i32, 140), lr.w);
    try t.expectEqual(@as(i32, 100 + 400 - 16 - 140), lr.x);
    try t.expectEqual(@as(i32, 200 + @divTrunc(60 - common.settings_combo_h, 2)), lr.y);
}
