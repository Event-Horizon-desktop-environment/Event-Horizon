//! The Zoolander settings page — design B.
//!
//! Zoolander's config is a set of Lua setters, so the rail category opens
//! one page per group of related setters. The pages use the same centered
//! 68% card column as the Hyprland sections, and the list column already
//! names the page, so there is no extra in-page strip or tri-line header.

const std = @import("std");
const common = @import("common.zig");

/// First sidebar tab of the Zoolander range (Keyboard … XWayland). Displays
/// deliberately live under the live Monitors tab, which owns the same
/// `output_rule` + `set_presentation` keys with the confirm flow.
pub const first_tab_id: i32 = 86;
/// Last sidebar tab of the range.
pub const last_tab_id: i32 = 93;

/// One Zoolander page: a list-column row and a sidebar tab in one.
pub const Section = struct {
    label: []const u8,
    glyph: []const u8,
    tab_id: i32,
};

pub const sections = [_]Section{
    .{ .label = "Keyboard", .glyph = "keyboard", .tab_id = first_tab_id },
    .{ .label = "Mouse & Touchpad", .glyph = "mouse", .tab_id = first_tab_id + 1 },
    .{ .label = "Windows & Borders", .glyph = "border_style", .tab_id = first_tab_id + 2 },
    .{ .label = "Effects", .glyph = "foggy", .tab_id = first_tab_id + 3 },
    .{ .label = "Animations", .glyph = "play_arrow", .tab_id = first_tab_id + 4 },
    .{ .label = "Decorations", .glyph = "palette", .tab_id = first_tab_id + 5 },
    .{ .label = "Workspaces & Layouts", .glyph = "grid_view", .tab_id = first_tab_id + 6 },
    .{ .label = "XWayland", .glyph = "desktop_windows", .tab_id = first_tab_id + 7 },
};

/// True when `tab` selects a Zoolander page.
pub fn ownsTab(tab: i32) bool {
    return tab >= first_tab_id and tab <= last_tab_id;
}

/// Page title (the list row already shows it; kept for search and tests).
pub fn labelOf(tab: i32) ?[]const u8 {
    if (!ownsTab(tab)) return null;
    return sections[@intCast(tab - first_tab_id)].label;
}

pub const Column = struct { x: i32, w: i32 };

/// Same centered 68% column as the Hyprland section cards.
pub fn column(tab: i32, content_x: i32, content_w: i32) ?Column {
    if (!ownsTab(tab)) return null;
    const w = @divTrunc(content_w * 68, 100);
    return .{ .x = content_x + @divTrunc(content_w - w, 2), .w = w };
}

/// First card top: the list column names the page, so cards start at the
/// content top exactly like the Hyprland sections.
pub fn pageTop() i32 {
    return common.content_top;
}

test "settings2-zoolander-page: sections cover the range" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 8), sections.len);
    for (sections, 0..) |s, i| {
        try t.expectEqual(first_tab_id + @as(i32, @intCast(i)), s.tab_id);
        try t.expect(ownsTab(s.tab_id));
        try t.expectEqualStrings(s.label, labelOf(s.tab_id).?);
    }
    try t.expect(!ownsTab(first_tab_id - 1));
    try t.expect(!ownsTab(last_tab_id + 1));
    const col = column(first_tab_id + 2, 292, 592).?;
    try t.expectEqual(@as(i32, 402), col.w);
    try t.expectEqual(@as(i32, 292 + @divTrunc(592 - 402, 2)), col.x);
    try t.expect(column(0, 292, 592) == null);
}
