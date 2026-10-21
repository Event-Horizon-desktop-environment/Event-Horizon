//! The Hyprland settings page — design B.
//!
//! The whole Hyprland tab from the original settings tree (`ux/settings`)
//! lives in this tree: `hyprland_data.zig` carries the live compositor
//! config model and `rows_hyprland.zig` carries the 15 section card tables
//! the generic renderer (`ui_content.zig`) places. This file is the
//! design-B page seen in the mockups: the rail category spills into
//! fifteen section pages — one row per section in the list column — and
//! every section page opens on the standard tri-line header
//! (`page_header.zig`) above its centered 68% card column.
//!
//! Section → page routing is `hyprland_tab.zig`'s `first_tab_id ..=
//! last_tab_id` band (General = 64 … Quirks = 78); `compositor.visibleTab`
//! shows the band only while Hyprland itself is running, exactly like the
//! rail category gate `compositor.visibleCategory(33)`.

const std = @import("std");
const common = @import("common.zig");
const page_header = @import("page_header.zig");
const hyprland_tab = @import("hyprland_tab.zig");

/// One Hyprland section page: a list-column row and a sidebar tab in one.
pub const Section = struct {
    label: []const u8,
    glyph: []const u8,
    tab_id: i32,
};

/// First sidebar tab of the section band (`hyprland_tab.first_tab_id`).
const first = hyprland_tab.first_tab_id;

/// The fifteen section pages, in `hyprland_tab.child_tabs` dispatch order
/// (General → Quirks). Glyphs are the Material symbols the list-column
/// rows and the matching search entries already resolve.
pub const sections = [_]Section{
    .{ .label = "General", .glyph = "tune", .tab_id = first },
    .{ .label = "Decoration", .glyph = "border_style", .tab_id = first + 1 },
    .{ .label = "Input", .glyph = "mouse", .tab_id = first + 2 },
    .{ .label = "Binds", .glyph = "keyboard", .tab_id = first + 3 },
    .{ .label = "Dwindle", .glyph = "view_column", .tab_id = first + 4 },
    .{ .label = "Master", .glyph = "view_agenda", .tab_id = first + 5 },
    .{ .label = "Scrolling", .glyph = "vertical_split", .tab_id = first + 6 },
    .{ .label = "Animations", .glyph = "play_arrow", .tab_id = first + 7 },
    .{ .label = "Misc", .glyph = "blocks", .tab_id = first + 8 },
    .{ .label = "Render", .glyph = "memory", .tab_id = first + 9 },
    .{ .label = "Cursor", .glyph = "mouse", .tab_id = first + 10 },
    .{ .label = "Group", .glyph = "splitscreen", .tab_id = first + 11 },
    .{ .label = "XWayland", .glyph = "desktop_windows", .tab_id = first + 12 },
    .{ .label = "OpenGL", .glyph = "rocket_launch", .tab_id = first + 13 },
    .{ .label = "Quirks", .glyph = "component", .tab_id = first + 14 },
};

/// True when `tab` is a Hyprland section page (one per rail row).
pub fn ownsTab(tab: i32) bool {
    return hyprland_tab.isSectionTab(tab);
}

/// Section title of a section page (`h1` of the header), or null elsewhere.
pub fn labelOf(tab: i32) ?[]const u8 {
    if (!ownsTab(tab)) return null;
    return sections[@intCast(hyprland_tab.sectionOf(tab))].label;
}

/// Card column for a section page: the same centered 68% column the
/// section cards sit in, so the header aligns with the cards beneath it.
/// Null for any other tab (`ui_content.columnFor` routes through here).
pub const Column = struct { x: i32, w: i32 };

pub fn column(tab: i32, content_x: i32, content_w: i32) ?Column {
    if (!ownsTab(tab)) return null;
    const w = @divTrunc(content_w * 68, 100);
    return .{ .x = content_x + @divTrunc(content_w - w, 2), .w = w };
}

/// First card top of a section page — `relayout` and `paint` both take
/// their placement `y0` from here (`ui_content.y0`).
pub fn pageTop() i32 {
    return common.content_top;
}

test "settings2-hyprland-page: sections mirror the dispatch tables" {
    const t = std.testing;
    const rows_hyprland = @import("rows_hyprland.zig");
    // One section per child tab, same order, same ids.
    try t.expectEqual(hyprland_tab.child_tabs.len, sections.len);
    try t.expectEqual(rows_hyprland.child_labels.len, sections.len);
    for (sections, 0..) |sec, i| {
        try t.expectEqualStrings(hyprland_tab.child_tabs[i], sec.label);
        try t.expectEqualStrings(rows_hyprland.child_labels[i], sec.label);
        try t.expectEqual(hyprland_tab.first_tab_id + @as(i32, @intCast(i)), sec.tab_id);
        try t.expect(hyprland_tab.isSectionTab(sec.tab_id));
        try t.expect(ownsTab(sec.tab_id));
    }
    // Off-band ids are not section pages.
    try t.expect(!ownsTab(hyprland_tab.first_tab_id - 1));
    try t.expect(!ownsTab(hyprland_tab.last_tab_id + 1));
    try t.expect(!ownsTab(0));
    // Titles resolve off the band; the mockup example first.
    try t.expectEqualStrings("Binds", labelOf(67).?);
    try t.expectEqualStrings("General", labelOf(64).?);
    try t.expectEqualStrings("Quirks", labelOf(78).?);
    try t.expect(labelOf(33) == null);
}

test "settings2-hyprland-page: column and header geometry" {
    const t = std.testing;
    // The 68% column is centered, exactly the geometry the section cards
    // already use (`ui_content.columnFor`).
    const col = column(67, 292, 592).?;
    try t.expectEqual(@as(i32, 402), col.w);
    try t.expectEqual(@as(i32, 292 + @divTrunc(592 - 402, 2)), col.x);
    try t.expect(column(0, 292, 592) == null);
    try t.expect(column(33, 292, 592) == null);
    // No page header on the section pages: the cards start at the content
    // top itself (the list column already names the section).
    try t.expectEqual(common.content_top, pageTop());
    try t.expect(pageTop() < page_header.contentStart());
}
