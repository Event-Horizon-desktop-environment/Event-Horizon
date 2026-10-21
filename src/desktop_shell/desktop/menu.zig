const std = @import("std");
const prefs = @import("preferences.zig");

/// Workspace (empty-area) right-click menu:
/// panels/rows/labels/separators/chevrons, geometry (measure/clamp/cascade),
/// hit-testing, hover switching, disabled + check states, and action dispatch.
///
/// Reference values (all scaled by dock `us`):
/// `RowH=28*us, Pad=10*us, MinW=120*us, RightPad=6*us, Corner=8*us,
///  Hl=5*us, Gap=4*us, TextLeft=Pad+22*us, ChevronGap=8*us`,
/// font `Inter 13*us` (chevron `14*us` `›`), highlight `0.18,0.22,0.3,0.85`,
/// text `0.92,0.93,0.95,0.95`, dimmed `0.45,0.46,0.48,0.75`.

pub const Panel = enum(u8) {
    main = 0,
    view = 1,
    sort_by = 2,
    add_new = 3,
};

pub const row_h: f64 = 28.0;
pub const pad: f64 = 10.0;
pub const min_menu_w: f64 = 120.0;
pub const menu_right_pad: f64 = 6.0;
pub const corner_radius: f64 = 8.0;
pub const hl_radius: f64 = 5.0;
pub const cascade_gap: f64 = 4.0;
pub const text_left_offset: f64 = 22.0;
pub const chevron_gap: f64 = 8.0;
pub const clamp_margin: f64 = 4.0;

pub fn rowCount(p: Panel) usize {
    return switch (p) {
        .main => 14,
        .view => 6,
        .sort_by => 7,
        .add_new => 2,
    };
}

pub fn isSeparator(p: Panel, row: i32) bool {
    return switch (p) {
        .main => row == 2 or row == 6,
        .view => row == 2,
        .sort_by => row == 4,
        .add_new => false,
    };
}

pub fn isSubmenuChevron(p: Panel, row: i32) bool {
    if (p != .main) return false;
    return row == 0 or row == 1 or row == 13;
}

/// Row label. Empty string = separator slot.
pub fn rowLabel(p: Panel, row: i32) []const u8 {
    return switch (p) {
        .main => switch (row) {
            0 => "View",
            1 => "Sort by",
            3 => "Copy",
            4 => "Paste",
            5 => "Undo paste",
            7 => "Delete",
            8 => "Refresh",
            9 => "Display settings",
            10 => "Open settings",
            11 => "Wallpaper",
            12 => "Live wallpaper",
            13 => "New",
            else => "",
        },
        .view => switch (row) {
            0 => "Show desktop icons",
            1 => "Don't show desktop icons",
            3 => "Large icons",
            4 => "Medium icons",
            5 => "Small icons",
            else => "",
        },
        .sort_by => switch (row) {
            0 => "Auto arrange icons",
            1 => "Align icons to grid",
            2 => "Stack left",
            3 => "Stack right",
            5 => "Sort by name",
            6 => "Sort by type",
            else => "",
        },
        .add_new => switch (row) {
            0 => "Text document",
            1 => "Folder",
            else => "",
        },
    };
}

pub fn menuHeight(p: Panel, us: f64) f64 {
    return @as(f64, @floatFromInt(rowCount(p))) * row_h * us + pad * us * 2.0;
}

pub fn mainBounds(x: f64, y: f64, main_w: f64, us: f64) struct { x: f64, y: f64, w: f64, h: f64 } {
    return .{ .x = x, .y = y, .w = @max(main_w, min_menu_w * us), .h = menuHeight(.main, us) };
}

/// Cascade placement: right of main, flip left on overflow, clamp vertically
/// (`layout_cascade_position`, `:132-163`).
pub fn cascadePos(
    mx: f64,
    my: f64,
    mw: f64,
    anchor_row: i32,
    sub_w: f64,
    sub_h: f64,
    layer_w: i32,
    layer_h: i32,
    us: f64,
) struct { x: f64, y: f64 } {
    const anchor_y = my + pad * us + @as(f64, @floatFromInt(anchor_row)) * row_h * us;
    var sx = mx + mw + cascade_gap * us;
    if (layer_w > 0 and sx + sub_w > @as(f64, @floatFromInt(layer_w)) - clamp_margin * us)
        sx = mx - sub_w - cascade_gap * us;
    var sy = anchor_y;
    if (layer_h > 0) {
        sy = std.math.clamp(sy, clamp_margin * us, @max(clamp_margin * us, @as(f64, @floatFromInt(layer_h)) - sub_h - clamp_margin * us));
    } else {
        sy = @max(clamp_margin * us, sy);
    }
    return .{ .x = sx, .y = sy };
}

/// Clamp the main menu into the layer (`clamp_main_menu_to_layer`, `:165-176`).
pub fn clampMain(x: *f64, y: *f64, mw: f64, mh: f64, layer_w: i32, layer_h: i32, us: f64) void {
    if (layer_w > 0 and x.* + mw > @as(f64, @floatFromInt(layer_w)) - clamp_margin * us)
        x.* = @max(clamp_margin * us, @as(f64, @floatFromInt(layer_w)) - mw - clamp_margin * us);
    if (layer_h > 0 and y.* + mh > @as(f64, @floatFromInt(layer_h)) - clamp_margin * us)
        y.* = @max(clamp_margin * us, @as(f64, @floatFromInt(layer_h)) - mh - clamp_margin * us);
    if (x.* < clamp_margin * us) x.* = clamp_margin * us;
    if (y.* < clamp_margin * us) y.* = clamp_margin * us;
}

/// Hit test: `-2` outside, `-1` separator/pad/out-of-range, else row
/// (`hit_main_menu_row` / `hit_cascade_menu_row`, `:178-212`).
pub fn hitRow(lx: f64, ly: f64, mx: f64, my: f64, mw: f64, mh: f64, panel: Panel, us: f64) i32 {
    if (lx < mx or ly < my or lx >= mx + mw or ly >= my + mh) return -2;
    const rel = ly - my - pad * us;
    const row: i32 = @intFromFloat(@floor(rel / (row_h * us)));
    const n: i32 = @intCast(rowCount(panel));
    if (row < 0 or row >= n) return -1;
    if (isSeparator(panel, row)) return -1;
    return row;
}

pub fn inAnyBounds(
    lx: f64,
    ly: f64,
    mx: f64,
    my: f64,
    mw: f64,
    mh: f64,
    cascade_open: bool,
    sx: f64,
    sy: f64,
    sw: f64,
    sh: f64,
) bool {
    if (lx >= mx and ly >= my and lx < mx + mw and ly < my + mh) return true;
    if (!cascade_open) return false;
    return lx >= sx and ly >= sy and lx < sx + sw and ly < sy + sh;
}

/// Chevron cascade mapping (`desktop_menu_left_release`, `rel_main == 0/1/13`).
/// Maps a main-menu chevron row to its cascade panel, or null when the row
/// has no cascade.
pub fn chevronPanel(main_row: i32) ?Panel {
    return switch (main_row) {
        0 => .view,
        1 => .sort_by,
        13 => .add_new,
        else => null,
    };
}

/// Hover update with auto cascade switching (`update_hover_from_pointer`, `:230-263`).
/// Returns the new cascade panel.
pub fn hoverCascade(main_row: i32, current: Panel) Panel {
    if (main_row == 0) return .view;
    if (main_row == 1) return .sort_by;
    if (main_row == 13) return .add_new;
    if (main_row < 0) return current;
    return .main;
}

/// Disabled rows: Undo paste (5) with empty undo stack, Delete (7) with empty
/// marquee selection (`paint_menu_panel`, `:410-411` + `:444-446`).
pub fn isRowDisabled(panel: Panel, row: i32, undo_empty: bool, marquee_empty: bool) bool {
    if (panel != .main) return false;
    if (row == 5 and undo_empty) return true;
    if (row == 7 and marquee_empty) return true;
    return false;
}

/// Check marks (`paint_menu_panel`, `:462-476`).
pub fn viewCheck(row: i32, icons_visible: bool, size: prefs.SizeKind) bool {
    if (row == 0) return icons_visible;
    if (row == 1) return !icons_visible;
    if (row == 3) return size == .large;
    if (row == 4) return size == .medium;
    if (row == 5) return size == .small;
    return false;
}

pub fn sortCheck(row: i32, arr: prefs.Arrangement, sort: prefs.Sort) bool {
    if (row == 0) return arr == .auto_arrange;
    if (row == 1) return arr == .align_to_grid;
    if (row == 2) return arr == .stacked;
    if (row == 3) return arr == .stacked_right;
    if (row == 5) return sort == .name;
    if (row == 6) return sort == .@"type";
    return false;
}

/// Action dispatch for the main panel (`apply_main_menu_action`, `:305-317`).
pub const MainAction = enum {
    none,
    copy,
    paste,
    undo_paste,
    delete,
    refresh,
    display_settings,
    open_settings,
    wallpaper,
    live_wallpaper,
};

pub fn mainActionForRow(row: i32) MainAction {
    return switch (row) {
        3 => .copy,
        4 => .paste,
        5 => .undo_paste,
        7 => .delete,
        8 => .refresh,
        9 => .display_settings,
        10 => .open_settings,
        11 => .wallpaper,
        12 => .live_wallpaper,
        else => .none,
    };
}

/// Action dispatch for cascades (`apply_cascade_menu_action`, `:319-345`).
pub const CascadeAction = enum {
    none,
    icons_show,
    icons_hide,
    size_large,
    size_medium,
    size_small,
    arrange_auto,
    arrange_align,
    arrange_stacked,
    arrange_stacked_right,
    sort_name,
    sort_type,
    new_text,
    new_folder,
};

pub fn cascadeActionForRow(panel: Panel, row: i32) CascadeAction {
    return switch (panel) {
        .view => switch (row) {
            0 => .icons_show,
            1 => .icons_hide,
            3 => .size_large,
            4 => .size_medium,
            5 => .size_small,
            else => .none,
        },
        .sort_by => switch (row) {
            0 => .arrange_auto,
            1 => .arrange_align,
            2 => .arrange_stacked,
            3 => .arrange_stacked_right,
            5 => .sort_name,
            6 => .sort_type,
            else => .none,
        },
        .add_new => switch (row) {
            0 => .new_text,
            1 => .new_folder,
            else => .none,
        },
        .main => .none,
    };
}

/// Apply a cascade action to prefs (pure part of `apply_cascade_menu_action`).
pub const CascadeState = struct {
    visible: bool,
    size: prefs.SizeKind,
    arrangement: prefs.Arrangement,
    sort: prefs.Sort,
    new_text: bool,
    new_folder: bool,
};

pub fn applyCascadeToPrefs(panel: Panel, row: i32, state: *CascadeState) bool {
    switch (cascadeActionForRow(panel, row)) {
        .icons_show => state.visible = true,
        .icons_hide => state.visible = false,
        .size_large => state.size = .large,
        .size_medium => state.size = .medium,
        .size_small => state.size = .small,
        .arrange_auto => state.arrangement = .auto_arrange,
        .arrange_align => state.arrangement = .align_to_grid,
        .arrange_stacked => state.arrangement = .stacked,
        .arrange_stacked_right => state.arrangement = .stacked_right,
        .sort_name => state.sort = .name,
        .sort_type => state.sort = .@"type",
        .new_text => state.new_text = true,
        .new_folder => state.new_folder = true,
        .none => return false,
    }
    return true;
}

/// Press/motion/release arm state (`desktop_menu_handle_left_press`,
/// `desktop_menu_pointer_motion`, `desktop_menu_left_release`, `:482-597`).
/// Press outside closes; press inside arms; release on the same row fires.
/// Chevron rows (0,1,13) open the cascade instead of closing.
pub const Press = struct {
    arm_main: i32 = -1,
    arm_sub: i32 = -1,
    hover_main: i32 = -1,
    hover_sub: i32 = -1,
    cascade: Panel = .main,
    anchor_row: i32 = 0,

    pub fn press(self: *Press, main_row: i32, sub_row: i32, in_any: bool) bool {
        // Returns true when the press was consumed (menu open), false when
        // the caller should close the menu (pressed outside).
        if (!in_any) return false;
        if (main_row == -1 and sub_row == -1) {
            self.arm_main = -1;
            self.arm_sub = -1;
            return true;
        }
        if (sub_row >= 0) {
            self.arm_main = -1;
            self.arm_sub = sub_row;
            return true;
        }
        if (main_row >= 0) {
            self.arm_main = main_row;
            self.arm_sub = -1;
            return true;
        }
        self.arm_main = -1;
        self.arm_sub = -1;
        return true;
    }

    pub fn releaseMain(self: *Press, rel_main: i32) ?MainAction {
        if (rel_main < 0 or self.arm_main < 0 or rel_main != self.arm_main or self.arm_sub >= 0) return null;
        if (rel_main == 0 or rel_main == 1 or rel_main == 13) {
            // Chevron: switch cascade, stay open.
            self.cascade = if (rel_main == 0) Panel.view else if (rel_main == 1) Panel.sort_by else Panel.add_new;
            self.anchor_row = rel_main;
            self.arm_main = -1;
            self.arm_sub = -1;
            return null;
        }
        return mainActionForRow(rel_main);
    }

    pub fn releaseSub(self: *Press, rel_sub: i32, cascade: Panel) ?CascadeAction {
        if (rel_sub < 0 or self.arm_sub < 0 or rel_sub != self.arm_sub) return null;
        return cascadeActionForRow(cascade, rel_sub);
    }
};

test "menu: rows + labels + separators + chevrons" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 14), rowCount(.main));
    try t.expectEqual(@as(usize, 6), rowCount(.view));
    try t.expectEqual(@as(usize, 7), rowCount(.sort_by));
    try t.expectEqual(@as(usize, 2), rowCount(.add_new));
    try t.expect(isSeparator(.main, 2));
    try t.expect(isSeparator(.main, 6));
    try t.expect(isSeparator(.view, 2));
    try t.expect(isSeparator(.sort_by, 4));
    try t.expect(!isSeparator(.add_new, 0));
    try t.expect(isSubmenuChevron(.main, 0));
    try t.expect(isSubmenuChevron(.main, 13));
    try t.expect(!isSubmenuChevron(.view, 0));
    try t.expectEqualStrings("View", rowLabel(.main, 0));
    try t.expectEqualStrings("Undo paste", rowLabel(.main, 5));
    try t.expectEqualStrings("Live wallpaper", rowLabel(.main, 12));
    try t.expectEqualStrings("Show desktop icons", rowLabel(.view, 0));
    try t.expectEqualStrings("Stack right", rowLabel(.sort_by, 3));
    try t.expectEqualStrings("Folder", rowLabel(.add_new, 1));
    try t.expectEqualStrings("", rowLabel(.main, 2));
}

test "menu: geometry + hit" {
    const t = std.testing;
    const us: f64 = 1.0;
    try t.expectApproxEqAbs(@as(f64, 14 * 28 + 20), menuHeight(.main, us), 1e-9);
    const b = mainBounds(100, 100, 200, us);
    try t.expectEqual(@as(f64, 200), b.w);
    // Inside first row.
    try t.expectEqual(@as(i32, 0), hitRow(110, 100 + 10 + 5, b.x, b.y, b.w, b.h, .main, us));
    // Separator row 2.
    try t.expectEqual(@as(i32, -1), hitRow(110, 100 + 10 + 2 * 28 + 5, b.x, b.y, b.w, b.h, .main, us));
    // Outside.
    try t.expectEqual(@as(i32, -2), hitRow(0, 0, b.x, b.y, b.w, b.h, .main, us));
    // Cascade flips left near right edge.
    const c = cascadePos(1700, 100, 200, 0, 200, 100, 1920, 1080, us);
    try t.expect(c.x < 1700);
    var x: f64 = 1800;
    var y: f64 = 1000;
    clampMain(&x, &y, 200, 400, 1920, 1080, us);
    try t.expect(x + 200 <= 1920 + 1e-9);
    try t.expect(inAnyBounds(110, 115, b.x, b.y, b.w, b.h, false, 0, 0, 0, 0));
    try t.expect(!inAnyBounds(0, 0, b.x, b.y, b.w, b.h, false, 0, 0, 0, 0));
}

test "menu: disabled + checks + actions" {
    const t = std.testing;
    try t.expect(isRowDisabled(.main, 5, true, false));
    try t.expect(isRowDisabled(.main, 7, false, true));
    try t.expect(!isRowDisabled(.main, 4, true, true));
    try t.expect(!isRowDisabled(.view, 0, true, true));
    try t.expect(viewCheck(0, true, .medium));
    try t.expect(viewCheck(4, true, .medium));
    try t.expect(sortCheck(0, .auto_arrange, .name));
    try t.expect(sortCheck(6, .align_to_grid, .@"type"));
    try t.expectEqual(MainAction.copy, mainActionForRow(3));
    try t.expectEqual(MainAction.live_wallpaper, mainActionForRow(12));
    try t.expectEqual(MainAction.none, mainActionForRow(0));
    try t.expectEqual(CascadeAction.size_large, cascadeActionForRow(.view, 3));
    try t.expectEqual(CascadeAction.sort_type, cascadeActionForRow(.sort_by, 6));
    try t.expectEqual(CascadeAction.new_folder, cascadeActionForRow(.add_new, 1));
    var st: CascadeState = .{ .visible = true, .size = prefs.SizeKind.medium, .arrangement = prefs.Arrangement.align_to_grid, .sort = prefs.Sort.name, .new_text = false, .new_folder = false };
    try t.expect(applyCascadeToPrefs(.view, 1, &st));
    try t.expect(!st.visible);
    try t.expect(!applyCascadeToPrefs(.main, 3, &st));
}

test "menu: press/motion/release state machine" {
    const t = std.testing;
    var pr = Press{};
    // Outside press -> caller closes.
    try t.expect(!pr.press(-2, -2, false));
    // Inside main row arms.
    try t.expect(pr.press(4, -2, true));
    try t.expectEqual(@as(i32, 4), pr.arm_main);
    // Chevron release switches cascade, stays open.
    pr.arm_main = 0;
    try t.expect(pr.releaseMain(0) == null);
    try t.expectEqual(Panel.view, pr.cascade);
    // Normal release fires.
    pr.arm_main = 4;
    pr.arm_sub = -1;
    try t.expectEqual(MainAction.paste, pr.releaseMain(4).?);
    // Sub release fires.
    pr.arm_sub = 3;
    try t.expectEqual(CascadeAction.size_large, pr.releaseSub(3, .view).?);
}

test "menu: chevronPanel + hoverCascade rows" {
    const t = std.testing;
    try t.expectEqual(Panel.view, chevronPanel(0).?);
    try t.expectEqual(Panel.sort_by, chevronPanel(1).?);
    try t.expectEqual(Panel.add_new, chevronPanel(13).?);
    try t.expect(chevronPanel(2) == null);
    try t.expect(chevronPanel(3) == null);
    try t.expect(chevronPanel(-1) == null);
    try t.expect(chevronPanel(12) == null);
    try t.expectEqual(Panel.view, hoverCascade(0, .main));
    try t.expectEqual(Panel.sort_by, hoverCascade(1, .main));
    try t.expectEqual(Panel.add_new, hoverCascade(13, .main));
    try t.expectEqual(Panel.view, hoverCascade(-1, .view));
    try t.expectEqual(Panel.main, hoverCascade(-1, .main));
    try t.expectEqual(Panel.sort_by, hoverCascade(-2, .sort_by));
    try t.expectEqual(Panel.main, hoverCascade(3, .view));
    try t.expectEqual(Panel.main, hoverCascade(5, .sort_by));
    try t.expectEqual(Panel.main, hoverCascade(2, .main));
}
