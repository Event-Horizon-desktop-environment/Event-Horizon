//! Taskbar input: search filtering plus the hit routing shared by press,
//! motion and release, plus thumb geometry.

const std = @import("std");
const types = @import("types.zig");

pub const Filter = enum { all, visible, hidden, minimized };

pub fn matches(title: []const u8, app: []const u8, query: []const u8, filter: Filter, minimized: bool, visible: bool) bool {
    switch (filter) {
        .all => {},
        .visible => if (!visible) return false,
        .hidden => if (visible) return false,
        .minimized => if (!minimized) return false,
    }
    if (query.len == 0) return true;
    var qb: [128]u8 = undefined;
    const q = std.ascii.lowerString(qb[0..@min(query.len, 128)], query[0..@min(query.len, 128)]);
    var tb: [256]u8 = undefined;
    const tl = std.ascii.lowerString(tb[0..@min(title.len, 256)], title[0..@min(title.len, 256)]);
    if (std.mem.indexOf(u8, tl, q) != null) return true;
    var ab: [128]u8 = undefined;
    const al = std.ascii.lowerString(ab[0..@min(app.len, 128)], app[0..@min(app.len, 128)]);
    return std.mem.indexOf(u8, al, q) != null;
}

pub const PressTarget = enum {
    none,
    slot,
    chevron,
    tray,
};

/// Classify a press on the bar's hit list.
pub fn classifyPress(hits: []const types.WidgetHit, px: f64, py: f64) struct {
    target: PressTarget,
    index: ?usize,
} {
    for (hits, 0..) |*h, i| {
        if (!h.contains(px, py)) continue;
        if (std.mem.eql(u8, h.widget_id, types.chevron_key)) return .{ .target = .chevron, .index = i };
        if (h.slot_kind == 1) return .{ .target = .tray, .index = i };
        return .{ .target = .slot, .index = i };
    }
    return .{ .target = .none, .index = null };
}

pub const ThumbClick = enum {
    none,
    row,
    close,
};

/// Click inside the hover-preview popup: close button first (Win7 shows it
/// on hover), then the row/card, else none.
pub fn classifyThumbClick(g: *const types.ThumbGeom, n: usize, px: f64, py: f64, hover_row: i32) struct {
    what: ThumbClick,
    row: i32,
} {
    const row = types.thumbsRowAt(g, n, px, py);
    if (row < 0) return .{ .what = .none, .row = -1 };
    if (row == hover_row and types.thumbsPointInClose(g, @intCast(row), px, py))
        return .{ .what = .close, .row = row };
    return .{ .what = .row, .row = row };
}

/// Motion inside the preview: which row is hot, and whether the close box
/// of the hovered row is hot.
pub fn thumbMotion(g: *const types.ThumbGeom, n: usize, px: f64, py: f64) struct {
    row: i32,
    close_hover: bool,
} {
    const row = types.thumbsRowAt(g, n, px, py);
    if (row < 0) return .{ .row = -1, .close_hover = false };
    return .{ .row = row, .close_hover = types.thumbsPointInClose(g, @intCast(row), px, py) };
}

test "taskbar-input: filter + match" {
    const t = std.testing;
    try t.expect(matches("Firefox", "firefox", "fox", .all, false, true));
    try t.expect(!matches("Firefox", "firefox", "fox", .hidden, false, true));
    try t.expect(matches("Firefox", "firefox", "", .minimized, true, true));
    try t.expect(!matches("Firefox", "firefox", "zzz", .all, false, true));
}

test "taskbar-input: press classification" {
    const t = std.testing;
    const hits = [_]types.WidgetHit{
        .{ .widget_id = "firefox", .x = 0, .y = 0, .w = 40, .h = 40 },
        .{ .widget_id = types.chevron_key, .x = 40, .y = 0, .w = 20, .h = 40 },
        .{ .widget_id = "tray:x", .x = 60, .y = 0, .w = 30, .h = 40, .slot_kind = 1 },
    };
    try t.expectEqual(PressTarget.slot, classifyPress(&hits, 5, 5).target);
    try t.expectEqual(PressTarget.chevron, classifyPress(&hits, 45, 5).target);
    try t.expectEqual(PressTarget.tray, classifyPress(&hits, 65, 5).target);
    try t.expectEqual(PressTarget.none, classifyPress(&hits, 200, 5).target);
}

test "taskbar-input: thumb click routing" {
    const t = std.testing;
    const g = types.thumbsGeom(2, false);
    // Top-left of the first card is a row hit, not the close box.
    const r = classifyThumbClick(&g, 2, types.thumb_pad + 2, types.thumb_pad + 2, 0);
    try t.expectEqual(ThumbClick.row, r.what);
    // Close box of row 0 while hovering row 0.
    const c = types.thumbsCloseRect(&g, 0);
    const cc = classifyThumbClick(&g, 2, c.x + 1, c.y + 1, 0);
    try t.expectEqual(ThumbClick.close, cc.what);
    try t.expectEqual(ThumbClick.none, classifyThumbClick(&g, 2, 1, 1, -1).what);
}
