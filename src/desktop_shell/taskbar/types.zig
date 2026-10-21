//! Taskbar shared types: popup kinds, hit
//! records, and the Win7 hover-preview geometry shared by paint, motion and
//! click so the three can never disagree.

const std = @import("std");

pub const chevron_key = "__eh_chevron";

pub const PopupKind = enum(u8) {
    none = 0,
    tray = 1,
    app = 2,
    calendar = 3,
    weather = 4,
    volume_mixer = 5,
    app_drawer = 6,
    control_center = 7,
    vpn = 8,
    battery = 9,
    media_player = 10,
    power_confirm = 11,
    bluetooth = 12,
    spotlight = 13,
    thumbs = 14,
    layout = 15,
};

pub const PopupItem = struct {
    id: i32 = 0,
    label: []const u8 = "",
    enabled: bool = true,

    pub fn isSeparator(self: *const PopupItem) bool {
        return self.id < 0;
    }
};

/// One painted slot's input rect. `slot_kind == 0` marks app slots (the only
/// ones pin-drag considers); `chosen_serial` avoids dangling toplevel
/// handles by naming the window instead of pointing at it.
pub const WidgetHit = struct {
    widget_id: []const u8 = "",
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    chosen_serial: u64 = 0,
    is_pinned: bool = false,
    slot_kind: i32 = 0,

    pub fn contains(self: *const WidgetHit, px: f64, py: f64) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
};

pub const thumb_pad: f64 = 10.0;
pub const thumb_gap: f64 = 8.0;
pub const thumb_card_w: f64 = 200.0;
pub const thumb_title_h: f64 = 26.0;
pub const thumb_preview_h: f64 = 96.0;
pub const thumb_close_sz: f64 = 22.0;
pub const thumb_list_row_h: f64 = 30.0;
pub const thumb_list_w: f64 = 300.0;

pub const ThumbGeom = struct {
    list: bool = false,
    cols: i32 = 1,
    rows: i32 = 0,
    card_w: f64 = thumb_card_w,
    card_h: f64 = thumb_title_h + thumb_preview_h,
    w: f64 = 0,
    h: f64 = 0,
};

pub fn thumbsGeom(n: usize, list_mode: bool) ThumbGeom {
    var g = ThumbGeom{};
    g.list = list_mode;
    if (list_mode) {
        g.rows = @intCast(n);
        g.w = thumb_list_w;
        g.h = thumb_pad * 2.0 + @as(f64, @floatFromInt(n)) * thumb_list_row_h + 4.0;
        return g;
    }
    var cols: i32 = 1;
    if (n <= 1) cols = 1 else if (n <= 2) cols = 2 else if (n <= 4) cols = 2 else if (n <= 6) cols = 3 else if (n <= 9) cols = 3 else cols = 4;
    g.cols = cols;
    const nf: f64 = @floatFromInt(n);
    const cf: f64 = @floatFromInt(cols);
    g.rows = @intFromFloat(@ceil(nf / cf));
    g.w = thumb_pad * 2.0 + cf * g.card_w + (cf - 1.0) * thumb_gap;
    g.h = thumb_pad * 2.0 + @as(f64, @floatFromInt(g.rows)) * g.card_h + @as(f64, @floatFromInt(@max(g.rows - 1, 0))) * thumb_gap + 4.0;
    return g;
}

pub fn thumbsCardRect(g: *const ThumbGeom, idx: usize) struct { x: f64, y: f64 } {
    const col: usize = idx % @as(usize, @intCast(g.cols));
    const row: usize = idx / @as(usize, @intCast(g.cols));
    return .{
        .x = thumb_pad + @as(f64, @floatFromInt(col)) * (g.card_w + thumb_gap),
        .y = thumb_pad + @as(f64, @floatFromInt(row)) * (g.card_h + thumb_gap),
    };
}

/// Row under popup-local (px,py), or -1.
pub fn thumbsRowAt(g: *const ThumbGeom, n: usize, px: f64, py: f64) i32 {
    if (g.list) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ry = thumb_pad + @as(f64, @floatFromInt(i)) * thumb_list_row_h;
            if (px >= thumb_pad and px < thumb_pad + (g.w - thumb_pad * 2.0) and py >= ry and py < ry + thumb_list_row_h)
                return @intCast(i);
        }
        return -1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = thumbsCardRect(g, i);
        if (px >= c.x and px < c.x + g.card_w and py >= c.y and py < c.y + g.card_h)
            return @intCast(i);
    }
    return -1;
}

pub fn thumbsCloseRect(g: *const ThumbGeom, idx: usize) struct { x: f64, y: f64 } {
    if (g.list) {
        const ry = thumb_pad + @as(f64, @floatFromInt(idx)) * thumb_list_row_h;
        return .{ .x = g.w - thumb_pad - thumb_close_sz, .y = ry + (thumb_list_row_h - thumb_close_sz) * 0.5 };
    }
    const c = thumbsCardRect(g, idx);
    return .{
        .x = c.x + g.card_w - thumb_close_sz - 4.0,
        .y = c.y + (thumb_title_h - thumb_close_sz) * 0.5,
    };
}

pub fn thumbsPointInClose(g: *const ThumbGeom, idx: usize, px: f64, py: f64) bool {
    const c = thumbsCloseRect(g, idx);
    return px >= c.x and px < c.x + thumb_close_sz and py >= c.y and py < c.y + thumb_close_sz;
}

/// Paint slot shared by the measure and paint passes.
pub const SlotKind = enum(u8) {
    app = 0,
    tray = 1,
    settings = 2,
    spotlight = 3,
    app_menu = 4,
    app_drawer = 5,
    clock = 6,
    weather = 7,
    media = 8,
    workspaces = 9,
    control_center = 10,
    trash = 11,
    volume_mixer = 12,
    battery = 13,
    bluetooth = 14,
    vpn = 15,
    layout = 16,
    world_clock = 17,
    overview = 18,
    separator = 19,
    smenu = 20,
    clipstack = 21,
    pear_center = 22,
    audio_center = 23,
};

pub const PaintSlot = struct {
    kind: SlotKind = .app,
    key: []const u8 = "",
    icon_id: []const u8 = "",
    chosen_serial: u64 = 0,
    any_activated: bool = false,
    is_pinned: bool = false,
    win7: bool = false,
};

test "taskbar-types: thumb grid classes" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 300.0), thumbsGeom(3, true).w);
    try t.expectEqual(@as(i32, 1), thumbsGeom(1, false).cols);
    try t.expectEqual(@as(i32, 2), thumbsGeom(4, false).cols);
    try t.expectEqual(@as(i32, 3), thumbsGeom(6, false).cols);
    try t.expectEqual(@as(i32, 4), thumbsGeom(12, false).cols);
}

test "taskbar-types: thumb hit routing" {
    const t = std.testing;
    const g = thumbsGeom(4, false);
    // First card starts at pad,pad.
    try t.expectEqual(@as(i32, 0), thumbsRowAt(&g, 4, thumb_pad + 1, thumb_pad + 1));
    try t.expectEqual(@as(i32, -1), thumbsRowAt(&g, 4, 1, 1));
    const gl = thumbsGeom(3, true);
    try t.expectEqual(@as(i32, 1), thumbsRowAt(&gl, 3, thumb_pad + 5, thumb_pad + thumb_list_row_h + 2));
    try t.expect(thumbsPointInClose(&gl, 0, gl.w - thumb_pad - thumb_close_sz + 1, thumb_pad + 5));
}
