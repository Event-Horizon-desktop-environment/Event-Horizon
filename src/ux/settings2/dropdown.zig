const std = @import("std");

// Self-contained dropdown/combobox.
// Owns labels, selection, hover, anchor, popup geometry (flips above anchor
// on overflow), and hit tests. Tabs only feed labels/selection/anchor per
// frame; position/hover/hit state never goes stale.

pub const default_row_h: i32 = 26;
pub const default_max_popup_h: i32 = 360;

pub const Dropdown = struct {
    selected: i32 = 0,
    hover_row: i32 = -1,
    open: bool = false,
    row_h: i32 = default_row_h,
    max_popup_h: i32 = default_max_popup_h,
    ax: i32 = 0,
    ay: i32 = 0,
    aw: i32 = 200,
    ah: i32 = 28,
    count: usize = 0,

    pub fn setAnchor(self: *Dropdown, x: i32, y: i32, w: i32, h: i32) void {
        self.ax = x;
        self.ay = y;
        self.aw = w;
        self.ah = h;
    }

    pub fn openPopup(self: *Dropdown) void {
        self.open = true;
    }

    pub fn close(self: *Dropdown) void {
        self.open = false;
        self.hover_row = -1;
    }

    pub fn displayIndex(self: *const Dropdown) usize {
        if (self.count == 0) return 0;
        const s: i64 = self.selected;
        if (s < 0) return 0;
        if (s >= @as(i64, @intCast(self.count))) return self.count - 1;
        return @intCast(s);
    }

    pub const PopupGeom = struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        flipped: bool,
    };

    /// Screen-space popup box. Flips above the anchor when it would overflow
    /// window_h; honors no scroll offset here (caller passes screen coords).
    pub fn popupGeom(self: *const Dropdown, window_h: i32) PopupGeom {
        const want_h: i32 = @min(self.max_popup_h, @as(i32, @intCast(self.count)) * self.row_h);
        const below: i32 = self.ay + self.ah;
        if (below + want_h <= window_h) {
            return .{ .x = self.ax, .y = below, .w = self.aw, .h = want_h, .flipped = false };
        }
        return .{ .x = self.ax, .y = @max(0, self.ay - want_h), .w = self.aw, .h = want_h, .flipped = true };
    }

    pub fn hitTrigger(self: *const Dropdown, px: i32, py: i32) bool {
        return px >= self.ax and px < self.ax + self.aw and py >= self.ay and py < self.ay + self.ah;
    }

    pub fn hitRow(self: *const Dropdown, px: i32, py: i32, window_h: i32) i32 {
        if (!self.open) return -1;
        const g = self.popupGeom(window_h);
        if (px < g.x or px >= g.x + g.w or py < g.y or py >= g.y + g.h) return -1;
        if (self.row_h <= 0) return -1;
        const row: i32 = @divTrunc(py - g.y, self.row_h);
        if (row < 0 or row >= @as(i32, @intCast(self.count))) return -1;
        return row;
    }
};

test "settings-dropdown: popup flips on overflow" {
    const t = std.testing;
    var d = Dropdown{ .count = 10, .row_h = 26, .max_popup_h = 360 };
    d.setAnchor(100, 100, 200, 28);
    const g = d.popupGeom(980);
    try t.expect(!g.flipped);
    try t.expectEqual(@as(i32, 128), g.y);
    d.setAnchor(100, 900, 200, 28);
    const g2 = d.popupGeom(980);
    try t.expect(g2.flipped);
    try t.expect(d.hitTrigger(150, 910));
    try t.expect(!d.hitTrigger(10, 10));
}

test "settings-dropdown: hit rows" {
    const t = std.testing;
    var d = Dropdown{ .count = 4, .row_h = 26 };
    d.setAnchor(0, 0, 200, 28);
    d.openPopup();
    try t.expectEqual(@as(i32, 1), d.hitRow(10, 28 + 30, 980));
    try t.expectEqual(@as(i32, -1), d.hitRow(500, 500, 980));
    d.close();
    try t.expectEqual(@as(i32, -1), d.hitRow(10, 40, 980));
}
