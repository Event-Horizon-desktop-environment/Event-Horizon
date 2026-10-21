const std = @import("std");

// Per-tab child (sub) tab bars —
// paint_wired_child_tab_bar / appearance+power child bars. Same geometry:
// strip at (contentX+8, kContentTop, contentW-16, 40) radius 8 (text 0.04),
// tabs at strip+4 (h 34) radius 6 when selected (text 0.10), labels 13px
// weight 600/400 at alpha 0.90/0.55.

pub const Bar = struct {
    labels: []const []const u8,
    tab_w: i32 = 130,
    gap: i32 = 0,
    /// Power centers its two tabs inside the strip; dock/panel/taskbar start
    /// at strip+4.
    centered: bool = false,
};

/// The child bar for a tab, or null when it has none.
pub fn barFor(tab: i32) ?Bar {
    return switch (tab) {
        // Dock / Panel / Taskbar — Settings | Widgets | Appearance
        0, 1, 11 => .{ .labels = &.{ "Settings", "Widgets", "Appearance" } },
        // Launcher — Launcher | Workspaces | Overview:
        // kLauncherChildCount=3, kLauncherTabW=130, gap 8, left-aligned).
        9 => .{ .labels = &.{ "Launcher", "Workspaces", "Overview" }, .tab_w = 130, .gap = 8 },
        // Power — Sleep & Power | Performance (centered, 150 wide, gap 6)
        32 => .{ .labels = &.{ "Sleep & Power", "Performance" }, .tab_w = 150, .gap = 6, .centered = true },
        // Wired — Status | IPv4 | IPv6 | Ethernet | Security | Advanced
        18 => .{ .labels = &.{ "Status", "IPv4", "IPv6", "Ethernet", "Security", "Advanced" }, .gap = 4, .centered = true },
        else => null,
    };
}

pub fn count(tab: i32) usize {
    const b = barFor(tab) orelse return 0;
    return b.labels.len;
}

test "settings-subtabs: bars carry the specified labels" {
    const t = std.testing;
    const d = barFor(0).?;
    try t.expectEqual(@as(usize, 3), d.labels.len);
    try t.expectEqualStrings("Widgets", d.labels[1]);
    const p = barFor(1).?;
    try t.expectEqualStrings("Settings", p.labels[0]);
    const tb = barFor(11).?;
    try t.expectEqualStrings("Appearance", tb.labels[2]);
    // Appearance is a rail category now: General | Opacity | Color |
    // Templates read as list rows, so the tabs have no in-page child bar.
    try t.expect(barFor(2) == null);
    try t.expect(barFor(3) == null);
    try t.expect(barFor(79) == null);
    try t.expect(barFor(80) == null);
    const pw = barFor(32).?;
    try t.expect(pw.centered);
    try t.expectEqual(@as(usize, 0), count(7));
    // Launcher: Launcher | Workspaces | Overview, 130 wide, gap 8.
    const l = barFor(9).?;
    try t.expectEqual(@as(usize, 3), l.labels.len);
    try t.expectEqualStrings("Launcher", l.labels[0]);
    try t.expectEqualStrings("Workspaces", l.labels[1]);
    try t.expectEqualStrings("Overview", l.labels[2]);
    try t.expectEqual(@as(i32, 130), l.tab_w);
    try t.expectEqual(@as(i32, 8), l.gap);
    try t.expectEqual(@as(usize, 3), count(9));
}
