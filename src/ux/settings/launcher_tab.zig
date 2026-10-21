const std = @import("std");
const common = @import("common.zig");

// Launcher tab (id 9) — Zig port of
// src/ux/settings/settings_tab_launcher/settings_tab_launcher.{hpp,cpp} and
// src/ux/settings/settings_tab_launcher/launcher_tab_m3.hpp.
//
// Same design and UX: a 3-way child bar
// (Launcher | Workspaces | Overview, 130x34 tabs at gap 8) above a centered
// 68% column of Hyprland-style section cards (header 52px, toggle rows 60px,
// slider rows 68px, bottom pad 24px, card gap 12px). Every slider range,
// label, value format, toggle description and segmented-chip option below
// mirrors the paint functions line for line, so paint, hit-test, scroll
// height and persistence can never disagree.
//
// Child 0 "Launcher":
//   Layout group (0 toggles, 7 sliders): Layout scale 70-150 "%d %%",
//     Icon size 30-95 "%d %%", Icon spacing 0-24 "%d px",
//     Folder size 50-200 "%d %%", Folder spacing 4-48 "%d px",
//     Folder columns 2-8 "%d", Folder rows 1-6 "%d"
//   Grid group (0,3): Columns 4-12 "%d", Rows 3-10 "%d",
//     DPI scale 50-300 "%d %%"
//   Appearance group (1,1): Widget opacity 0-100 "%d %%" (one slider drives
//     both dock.slotPillOpacity and taskbar.slotPillOpacity, like C++ case 7)
// Child 1 "Workspaces" (1 toggle, 2 sliders):
//   Show app icons toggle ("Show running applications as icons in the
//     workspace strip"), Number of workspaces 0-16 (0 renders "Auto",
//     else "%d"), Max workspace icons 1-8 "%d"
// Child 2 "Overview" (3 toggles-slots, 6 slider-slots = 9 rows):
//   Live updates + Multi-monitor toggles, Capture mode chips
//     (Snapshot|Screencopy), Scroll axis chips (Vertical|Horizontal),
//   Card scale 20-80 "%d %%", Card spacing 8-80 "%d px",
//   Scroll settle delay 50-500 "%d ms", Close button size 20-60 "%d px",
//   Search bar width 200-800 "%d px"
//
// This file owns geometry, ranges, formatting and scroll math only. Live
// values live in `app.Settings` and route through `fields` (see
// rows_panels.launcher_*); paint goes through the generic renderer in
// ui_content.zig, persistence through appearance/launcher persist.

pub const tab_id: i32 = 9;

pub const child_tabs = [_][]const u8{ "Launcher", "Workspaces", "Overview" };

/// Child-bar metrics (launcher_tab_m3.hpp: kLauncherTabW/kLauncherChildGap).
pub const tab_w: i32 = 130;
pub const tab_gap: i32 = 8;
pub const tab_h: i32 = common.child_tab_h; // 34
pub const bar_h: i32 = common.child_bar_h; // 40

/// Cards start below the child strip (settings_tab_launcher.cpp:
/// kLauncherContentTop = kContentTop + kDockChildTabH + 12).
pub const content_top: i32 = common.child_content_top; // 62

// ---------------------------------------------------------------------------
// Section-card layout (hyprland_m3_layout.hpp: HyprlandCardLayout).
// ---------------------------------------------------------------------------

pub const section_header_h: i32 = 52;
pub const toggle_row_h: i32 = 60;
pub const slider_row_h: i32 = 68;
pub const section_pad_b: i32 = 24;
pub const section_gap: i32 = 12;

pub fn sectionCardH(n_toggles: i32, n_sliders: i32) i32 {
    return section_header_h + n_toggles * toggle_row_h + n_sliders * slider_row_h + section_pad_b;
}

pub fn columnFor(content_x: i32, content_w: i32) struct { x: i32, w: i32 } {
    const w = @divTrunc(content_w * 68, 100);
    return .{ .x = content_x + @divTrunc(content_w - w, 2), .w = w };
}

/// Top of row `r` inside a card with `n_toggles` toggle rows first.
pub fn rowTop(card_y: i32, n_toggles: i32, r: i32) i32 {
    if (r < n_toggles) return card_y + section_header_h + r * toggle_row_h;
    return card_y + section_header_h + n_toggles * toggle_row_h + (r - n_toggles) * slider_row_h;
}

// ---------------------------------------------------------------------------
// Child-bar hit testing (launcher_hit_child_tab).
// ---------------------------------------------------------------------------

/// Child index at a window-space point, or -1.
/// barX = contentX+8, barY = kContentTop+3, tabs at barX+4 (h 34).
pub fn hitChildTab(px: f64, py: f64, content_x: i32) i32 {
    const bar_x = content_x + 8;
    const bar_y = common.content_top + 3;
    var i: i32 = 0;
    while (i < child_tabs.len) : (i += 1) {
        const tx: i32 = bar_x + 4 + i * (tab_w + tab_gap);
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

// ---------------------------------------------------------------------------
// Slider / toggle / chip specs.
// ---------------------------------------------------------------------------

pub const SliderSpec = struct {
    /// Index within the child tab.
    idx: u8,
    label: []const u8,
    min: i32,
    max: i32,
    /// printf-style format from the C++ paint call, or null for the
    /// workspaces slot labels (Auto/1..16).
    fmt: ?[]const u8 = null,
};

pub const launcher_layout_sliders = [_]SliderSpec{
    .{ .idx = 0, .label = "Layout scale", .min = 70, .max = 150, .fmt = "%d %%" },
    .{ .idx = 1, .label = "Icon size", .min = 30, .max = 95, .fmt = "%d %%" },
    .{ .idx = 2, .label = "Icon spacing", .min = 0, .max = 24, .fmt = "%d px" },
    .{ .idx = 3, .label = "Folder size", .min = 50, .max = 200, .fmt = "%d %%" },
    .{ .idx = 4, .label = "Folder spacing", .min = 4, .max = 48, .fmt = "%d px" },
    .{ .idx = 9, .label = "Folder columns", .min = 2, .max = 8, .fmt = "%d" },
    .{ .idx = 10, .label = "Folder rows", .min = 1, .max = 6, .fmt = "%d" },
};

pub const launcher_grid_sliders = [_]SliderSpec{
    .{ .idx = 5, .label = "Columns", .min = 4, .max = 12, .fmt = "%d" },
    .{ .idx = 6, .label = "Rows", .min = 3, .max = 10, .fmt = "%d" },
    .{ .idx = 8, .label = "DPI scale", .min = 50, .max = 300, .fmt = "%d %%" },
};

pub const launcher_appearance_sliders = [_]SliderSpec{
    .{ .idx = 7, .label = "Widget opacity", .min = 0, .max = 100, .fmt = "%d %%" },
};

pub const workspaces_sliders = [_]SliderSpec{
    // fmt null: value_labels table (Auto,1..16) in the C++ paint call.
    .{ .idx = 0, .label = "Number of workspaces", .min = 0, .max = 16 },
    .{ .idx = 1, .label = "Max workspace icons", .min = 1, .max = 8, .fmt = "%d" },
};

pub const overview_sliders = [_]SliderSpec{
    .{ .idx = 0, .label = "Card scale", .min = 20, .max = 80, .fmt = "%d %%" },
    .{ .idx = 1, .label = "Card spacing", .min = 8, .max = 80, .fmt = "%d px" },
    .{ .idx = 2, .label = "Scroll settle delay", .min = 50, .max = 500, .fmt = "%d ms" },
    .{ .idx = 3, .label = "Close button size", .min = 20, .max = 60, .fmt = "%d px" },
    .{ .idx = 4, .label = "Search bar width", .min = 200, .max = 800, .fmt = "%d px" },
};

pub const ws_slot_labels = [_][]const u8{
    "Auto", "1", "2", "3", "4", "5", "6", "7", "8",
    "9",  "10", "11", "12", "13", "14", "15", "16",
};

pub const capture_labels = [_][]const u8{ "Snapshot", "Screencopy" };
pub const axis_labels = [_][]const u8{ "Vertical", "Horizontal" };

// Group headers, verbatim from the C++ beginGroup calls.
pub const layout_title = "Layout";
pub const layout_sub = "Scale and spacing for the launcher grid";
pub const grid_title = "Grid";
pub const grid_sub = "Columns, rows, and DPI scaling";
pub const appearance_title = "Appearance";
pub const appearance_sub = "Widget opacity";
pub const workspaces_title = "Workspaces";
pub const workspaces_sub = "Workspace slots and app icons";
pub const overview_title = "Overview";
pub const overview_sub = "Workspace overview layout and behavior";

pub const ws_toggle_title = "Show app icons";
pub const ws_toggle_desc = "Show running applications as icons in the workspace strip";
pub const ov_live_title = "Live updates";
pub const ov_live_desc = "Stream live per-window frames while the overview is open";
pub const ov_multi_title = "Multi-monitor";
pub const ov_multi_desc = "Show the overview on all monitors at once";
pub const capture_row_title = "Capture mode";
pub const axis_row_title = "Scroll axis";

// Toggle switch geometry (hyprland_paint_toggle_card: 40x24, right-aligned).
pub const toggle_w: i32 = 40;
pub const toggle_h: i32 = 24;

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Right-aligned 40x24 switch inside a card row.
pub fn toggleRect(card_x: i32, card_w: i32, row_y: i32) Rect {
    return .{
        .x = card_x + card_w - common.card_pad - toggle_w,
        .y = row_y + @divTrunc(toggle_row_h - toggle_h, 2),
        .w = toggle_w,
        .h = toggle_h,
    };
}

/// M3 slider track inside a card row (hyprland_paint_slider_card:
/// x=cardX+16, y=rowY+40-10, w=cardW-32, h=36).
pub fn sliderTrack(card_x: i32, card_w: i32, row_y: i32) Rect {
    return .{
        .x = card_x + common.card_pad,
        .y = row_y + 40 - 10,
        .w = card_w - 2 * common.card_pad,
        .h = 36,
    };
}

// Segmented chips (paintOptionRow): 30px tall, 8px gaps, 14px side pad,
// widest-label width floored at 64px, right-aligned in the card.
pub const chip_h: f64 = 30.0;
pub const chip_gap: f64 = 8.0;
pub const chip_pad_x: f64 = 14.0;
pub const chip_min_w: f64 = 64.0;

pub fn chipWidth(label_w: f64) f64 {
    return @max(chip_min_w, label_w + 2.0 * chip_pad_x);
}

pub fn optionRowCy(row_y: i32) f64 {
    return @as(f64, @floatFromInt(row_y)) + (@as(f64, @floatFromInt(toggle_row_h)) - chip_h) * 0.5;
}

/// Left edge of the chip strip for `count` chips of width `chip_w` in a card.
pub fn chipsStartX(card_x: i32, card_w: i32, count: usize, chip_w: f64) f64 {
    const total = @as(f64, @floatFromInt(count)) * chip_w +
        @as(f64, @floatFromInt(count - 1)) * chip_gap;
    return @as(f64, @floatFromInt(card_x + card_w - common.card_pad)) - total;
}

pub fn chipRectAt(start_x: f64, cy: f64, i: usize, chip_w: f64) Rect {
    const x: f64 = start_x + @as(f64, @floatFromInt(i)) * (chip_w + chip_gap);
    return .{
        .x = @intFromFloat(@round(x)),
        .y = @intFromFloat(@round(cy)),
        .w = @intFromFloat(@round(chip_w)),
        .h = @intFromFloat(chip_h),
    };
}

pub fn hitChip(rects: []const Rect, px: f64, py: f64) i32 {
    for (rects, 0..) |r, i| {
        if (px >= @as(f64, @floatFromInt(r.x)) and
            px < @as(f64, @floatFromInt(r.x + r.w)) and
            py >= @as(f64, @floatFromInt(r.y)) and
            py < @as(f64, @floatFromInt(r.y + r.h)))
        {
            return @intCast(i);
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------
// Value text (one snprintf-style format per row).
// ---------------------------------------------------------------------------

/// Render a slider value into `buf` using that row's format.
/// The workspaces slot slider (child 1, idx 0) prints "Auto" at 0.
pub fn formatSliderValue(child: u8, idx: u8, v: i32, buf: []u8) []const u8 {
    if (child == 1 and idx == 0) {
        if (v <= 0) return "Auto";
        return std.fmt.bufPrint(buf, "{d}", .{v}) catch "";
    }
    const spec = specFor(child, idx) orelse
        return std.fmt.bufPrint(buf, "{d}", .{v}) catch "";
    const fmt = spec.fmt orelse return std.fmt.bufPrint(buf, "{d}", .{v}) catch "";
    if (std.mem.eql(u8, fmt, "%d %%")) return std.fmt.bufPrint(buf, "{d} %", .{v}) catch "";
    if (std.mem.eql(u8, fmt, "%d px")) return std.fmt.bufPrint(buf, "{d} px", .{v}) catch "";
    if (std.mem.eql(u8, fmt, "%d ms")) return std.fmt.bufPrint(buf, "{d} ms", .{v}) catch "";
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "";
}

pub fn specFor(child: u8, idx: u8) ?SliderSpec {
    if (child == 0) {
        for (launcher_layout_sliders) |s| if (s.idx == idx) return s;
        for (launcher_grid_sliders) |s| if (s.idx == idx) return s;
        for (launcher_appearance_sliders) |s| if (s.idx == idx) return s;
        return null;
    }
    if (child == 1) {
        for (workspaces_sliders) |s| if (s.idx == idx) return s;
        return null;
    }
    for (overview_sliders) |s| if (s.idx == idx) return s;
    return null;
}

// ---------------------------------------------------------------------------
// Content height (group accumulation plus inter-group spacing).
// ---------------------------------------------------------------------------

/// Scrollable height below `content_top` for a child tab.
pub fn contentHeight(child: i32) i32 {
    if (child == 0) {
        return sectionCardH(0, 7) + section_gap +
            sectionCardH(0, 3) + section_gap +
            sectionCardH(1, 1) + common.spacing_l;
    }
    if (child == 1) {
        return sectionCardH(1, 2) + common.spacing_l;
    }
    return sectionCardH(3, 6) + common.spacing_l;
}

/// Clamp a scroll offset for a child tab against a viewport height.
pub fn clampScroll(scroll_px: i32, child: i32, viewport_h: i32) i32 {
    const max: i32 = @max(0, contentHeight(child) - viewport_h);
    return @min(@max(scroll_px, 0), max);
}

// ---------------------------------------------------------------------------
// Range clamps (mirror shell_config.cpp assign clamps + serialize clamps).
// ---------------------------------------------------------------------------

pub fn clampLayoutScale(v: i32) i32 {
    return common.clampInt(v, 70, 150);
}
pub fn clampIconFill(v: i32) i32 {
    return common.clampInt(v, 30, 95);
}
pub fn clampCellGap(v: i32) i32 {
    return common.clampInt(v, 0, 24);
}
pub fn clampFolderSize(v: i32) i32 {
    return common.clampInt(v, 50, 200);
}
pub fn clampFolderGap(v: i32) i32 {
    return common.clampInt(v, 4, 48);
}
pub fn clampFolderColumns(v: i32) i32 {
    return common.clampInt(v, 2, 8);
}
pub fn clampFolderRows(v: i32) i32 {
    return common.clampInt(v, 1, 6);
}
pub fn clampGridColumns(v: i32) i32 {
    return common.clampInt(v, 4, 12);
}
pub fn clampGridRows(v: i32) i32 {
    return common.clampInt(v, 3, 10);
}
pub fn clampDpiScale(v: i32) i32 {
    return common.clampInt(v, 50, 300);
}
pub fn clampSlotPill(v: i32) i32 {
    return common.clampInt(v, 0, 100);
}
pub fn clampWsSlots(v: i32) i32 {
    return common.clampInt(v, 0, 16);
}
pub fn clampWsIcons(v: i32) i32 {
    return common.clampInt(v, 1, 8);
}
pub fn clampCardScale(v: i32) i32 {
    return common.clampInt(v, 20, 80);
}
pub fn clampCardGap(v: i32) i32 {
    return common.clampInt(v, 8, 80);
}
pub fn clampScrollDelay(v: i32) i32 {
    return common.clampInt(v, 50, 500);
}
pub fn clampCloseBtn(v: i32) i32 {
    return common.clampInt(v, 20, 60);
}
pub fn clampSearchWidth(v: i32) i32 {
    return common.clampInt(v, 200, 800);
}

// ---------------------------------------------------------------------------
// Legacy small models (kept for workspaces/taskflip/dashboard tab homes).
// Ranges now match the C++ clamps above.
// ---------------------------------------------------------------------------

pub const LauncherModel = struct {
    grid_columns: i32 = 8,
    grid_rows: i32 = 5,
    icon_fill_pct: i32 = 58,
    layout_scale_pct: i32 = 100,
    cell_gap_px: i32 = 0,
    folder_size_pct: i32 = 100,
    folder_gap_px: i32 = 16,
    folder_columns: i32 = 3,
    folder_rows: i32 = 3,
    dpi_scale_pct: i32 = 100,
    slot_pill_opacity: i32 = 100,
    view_mode: i32 = 0, // 0=icons grid, 1=list

    pub fn clampAll(self: *LauncherModel) void {
        self.grid_columns = clampGridColumns(self.grid_columns);
        self.grid_rows = clampGridRows(self.grid_rows);
        self.icon_fill_pct = clampIconFill(self.icon_fill_pct);
        self.layout_scale_pct = clampLayoutScale(self.layout_scale_pct);
        self.cell_gap_px = clampCellGap(self.cell_gap_px);
        self.folder_size_pct = clampFolderSize(self.folder_size_pct);
        self.folder_gap_px = clampFolderGap(self.folder_gap_px);
        self.folder_columns = clampFolderColumns(self.folder_columns);
        self.folder_rows = clampFolderRows(self.folder_rows);
        self.dpi_scale_pct = clampDpiScale(self.dpi_scale_pct);
        self.slot_pill_opacity = clampSlotPill(self.slot_pill_opacity);
    }
};

pub const WorkspacesModel = struct {
    max_slots: i32 = 5,
    show_apps: bool = true,
    max_icons: i32 = 4,

    pub fn clampAll(self: *WorkspacesModel) void {
        self.max_slots = clampWsSlots(self.max_slots);
        self.max_icons = clampWsIcons(self.max_icons);
    }
};

pub const OverviewModel = struct {
    axis: i32 = 0,
    capture_mode: i32 = 0,
    live_updates: bool = false,
    multi_monitor: bool = false,
    card_scale_pct: i32 = 50,
    card_gap_px: i32 = 24,
    scroll_delay_ms: i32 = 200,
    close_btn_size_px: i32 = 34,
    search_width_px: i32 = 420,

    pub fn clampAll(self: *OverviewModel) void {
        if (self.axis < 0 or self.axis > 1) self.axis = 0;
        if (self.capture_mode < 0 or self.capture_mode > 1) self.capture_mode = 0;
        self.card_scale_pct = clampCardScale(self.card_scale_pct);
        self.card_gap_px = clampCardGap(self.card_gap_px);
        self.scroll_delay_ms = clampScrollDelay(self.scroll_delay_ms);
        self.close_btn_size_px = clampCloseBtn(self.close_btn_size_px);
        self.search_width_px = clampSearchWidth(self.search_width_px);
    }
};

pub const TaskflipModel = struct {
    gallery_style: bool = true,
    mru_order: bool = true,
    show_caption: bool = true,
    show_count: bool = true,
    show_icons: bool = true,
};

pub const DashboardModel = struct {
    enabled: bool = true,
    columns: i32 = 4,
    gap: i32 = 12,

    pub fn clampAll(self: *DashboardModel) void {
        self.columns = common.clampInt(self.columns, 1, 8);
        self.gap = common.clampInt(self.gap, 0, 32);
    }
};

test "settings-launcher: child bar follows the specified layout" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 3), child_tabs.len);
    try t.expectEqualStrings("Launcher", child_tabs[0]);
    try t.expectEqualStrings("Workspaces", child_tabs[1]);
    try t.expectEqualStrings("Overview", child_tabs[2]);
    try t.expectEqual(@as(i32, 130), tab_w);
    try t.expectEqual(@as(i32, 62), content_top);
    // barX+4 origin, 34px tall.
    try t.expectEqual(@as(i32, 0), hitChildTab(312 + 4 + 65, 19 + 3 + 10, 300));
    try t.expectEqual(@as(i32, 1), hitChildTab(312 + 4 + 130 + 8 + 65, 19 + 3 + 10, 300));
    try t.expectEqual(@as(i32, 2), hitChildTab(312 + 4 + 2 * (130 + 8) + 65, 19 + 3 + 10, 300));
    try t.expectEqual(@as(i32, -1), hitChildTab(0, 0, 300));
}

test "settings-launcher: section heights track section counts" {
    const t = std.testing;
    // Layout (0,7): 52 + 7*68 + 24
    try t.expectEqual(@as(i32, 52 + 7 * 68 + 24), sectionCardH(0, 7));
    // Appearance (1,1): 52 + 60 + 68 + 24 (the C++ reserves a toggle row).
    try t.expectEqual(@as(i32, 52 + 60 + 68 + 24), sectionCardH(1, 1));
    // Workspaces (1,2): 52 + 60 + 136 + 24
    try t.expectEqual(@as(i32, 52 + 60 + 2 * 68 + 24), sectionCardH(1, 2));
    // Overview (3,6): 52 + 180 + 408 + 24
    try t.expectEqual(@as(i32, 52 + 3 * 60 + 6 * 68 + 24), sectionCardH(3, 6));
    // Row tops: toggles first, then sliders.
    try t.expectEqual(@as(i32, 100 + 52), rowTop(100, 1, 0));
    try t.expectEqual(@as(i32, 100 + 52 + 60), rowTop(100, 1, 1));
    try t.expectEqual(@as(i32, 100 + 52 + 60 + 68), rowTop(100, 1, 2));
    // Content heights include the 12px card gap + 16px bottom pad.
    try t.expect(contentHeight(0) > contentHeight(1));
    try t.expect(contentHeight(2) > contentHeight(1));
}

test "settings-launcher: slider ranges cover the painted range" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 7), launcher_layout_sliders.len);
    try t.expectEqual(@as(i32, 70), launcher_layout_sliders[0].min);
    try t.expectEqual(@as(i32, 150), launcher_layout_sliders[0].max);
    try t.expectEqualStrings("Layout scale", launcher_layout_sliders[0].label);
    try t.expectEqual(@as(usize, 3), launcher_grid_sliders.len);
    try t.expectEqual(@as(i32, 50), launcher_grid_sliders[2].min);
    try t.expectEqual(@as(i32, 300), launcher_grid_sliders[2].max);
    try t.expectEqual(@as(usize, 2), workspaces_sliders.len);
    try t.expectEqual(@as(i32, 0), workspaces_sliders[0].min);
    try t.expectEqual(@as(i32, 16), workspaces_sliders[0].max);
    try t.expectEqual(@as(usize, 5), overview_sliders.len);
    try t.expectEqual(@as(i32, 200), overview_sliders[4].min);
    try t.expectEqual(@as(i32, 800), overview_sliders[4].max);
    try t.expectEqual(@as(usize, 17), ws_slot_labels.len);
    try t.expectEqualStrings("Auto", ws_slot_labels[0]);
    try t.expectEqualStrings("16", ws_slot_labels[16]);
}

test "settings-launcher: value text uses the specified format" {
    const t = std.testing;
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("Auto", formatSliderValue(1, 0, 0, &buf));
    try t.expectEqualStrings("5", formatSliderValue(1, 0, 5, &buf));
    try t.expectEqualStrings("100 %", formatSliderValue(0, 0, 100, &buf));
    try t.expectEqualStrings("12 px", formatSliderValue(0, 2, 12, &buf));
    try t.expectEqualStrings("200 ms", formatSliderValue(2, 2, 200, &buf));
    try t.expectEqualStrings("8", formatSliderValue(0, 5, 8, &buf));
}

test "settings-launcher: toggle + slider + chip geometry" {
    const t = std.testing;
    const tg = toggleRect(100, 400, 200);
    try t.expectEqual(@as(i32, 100 + 400 - 16 - 40), tg.x);
    try t.expectEqual(@as(i32, 200 + @divTrunc(60 - 24, 2)), tg.y);
    const tr = sliderTrack(100, 400, 200);
    try t.expectEqual(@as(i32, 116), tr.x);
    try t.expectEqual(@as(i32, 200 + 30), tr.y);
    try t.expectEqual(@as(i32, 400 - 32), tr.w);
    // Chips: 30px tall, vertically centered in the 60px row.
    try t.expectApproxEqAbs(@as(f64, 200 + 15), optionRowCy(200), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 64), chipWidth(10), 1e-9);
    try t.expect(chipWidth(100) > 64);
    const rects = [_]Rect{
        .{ .x = 0, .y = 0, .w = 64, .h = 30 },
        .{ .x = 72, .y = 0, .w = 64, .h = 30 },
    };
    try t.expectEqual(@as(i32, 1), hitChip(&rects, 80, 10));
    try t.expectEqual(@as(i32, -1), hitChip(&rects, 200, 10));
}

test "settings-launcher: clamps mirror shell_config.cpp" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 70), clampLayoutScale(-99));
    try t.expectEqual(@as(i32, 150), clampLayoutScale(999));
    try t.expectEqual(@as(i32, 0), clampWsSlots(-1));
    try t.expectEqual(@as(i32, 16), clampWsSlots(99));
    try t.expectEqual(@as(i32, 1), clampWsIcons(0));
    try t.expectEqual(@as(i32, 500), clampScrollDelay(9999));
    var l = LauncherModel{ .grid_columns = 99, .dpi_scale_pct = -5 };
    l.clampAll();
    try t.expectEqual(@as(i32, 12), l.grid_columns);
    try t.expectEqual(@as(i32, 50), l.dpi_scale_pct);
    var w = WorkspacesModel{ .max_slots = 99, .max_icons = 0 };
    w.clampAll();
    try t.expectEqual(@as(i32, 16), w.max_slots);
    try t.expectEqual(@as(i32, 1), w.max_icons);
    var o = OverviewModel{ .axis = 9, .card_scale_pct = 999 };
    o.clampAll();
    try t.expectEqual(@as(i32, 0), o.axis);
    try t.expectEqual(@as(i32, 80), o.card_scale_pct);
    var d = DashboardModel{};
    d.clampAll();
    try t.expect(d.enabled);
    try t.expectEqual(@as(i32, 0), clampScroll(9999, 1, 99999));
    try t.expect(clampScroll(0, 0, 400) >= 0);
}
