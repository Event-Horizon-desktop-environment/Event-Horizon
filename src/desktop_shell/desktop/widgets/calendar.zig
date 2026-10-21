const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const dw_data = @import("../../../ux/shared/desktop_widgets_data.zig");
const card = @import("../../widgets/calendar_card.zig");
const chrome = @import("../../widgets/shared/chrome_colors.zig");
const local_time = @import("../local_time.zig");
const widget = @import("widget.zig");

// Desktop calendar widget.
// shared 320x370 month card (`calendar_card.paintCard`), prev/next chevrons
// shift the displayed month, clicking a day selects it.

pub const State = struct {
    display: card.Date = .{},
    selected: card.Date = .{},
    inited: bool = false,
};

pub fn stateFromConfig(cfg: dw_data.WidgetConfig) State {
    _ = cfg;
    return .{};
}

pub fn refresh(s: *State, io: std.Io) void {
    _ = io;
    if (!s.inited) {
        const t = local_time.today();
        s.display = t;
        s.selected = t;
        s.inited = true;
    }
}

pub fn size(s: *const State) [2]i32 {
    _ = s;
    return .{ 320, 370 };
}

fn shiftMonth(s: *State, delta: i32) void {
    var m: i32 = @as(i32, s.display.month) + delta;
    var y = s.display.year;
    while (m < 1) {
        m += 12;
        y -= 1;
    }
    while (m > 12) {
        m -= 12;
        y += 1;
    }
    s.display.month = @intCast(m);
    s.display.year = y;
    s.display.day = 1;
}

pub fn click(s: *State, x: f64, y: f64) bool {
    const us = 1.0;
    switch (card.navHit(card.width, x, y, us)) {
        -1 => shiftMonth(s, -1),
        1 => shiftMonth(s, 1),
        else => {},
    }
    if (card.navHit(card.width, x, y, us) != 0) return true;
    if (card.cellAt(x, y, us)) |idx| {
        const d = card.cellDate(s.display, idx);
        // Only in-month days select.
        if (d.month == s.display.month) s.selected = d;
        return true;
    }
    return false;
}

pub fn paint(s: *const State, cr: ?*cairo.cairo_t, ctx: widget.Ctx) void {
    const c = cr orelse return;
    const cc = chrome.Chrome{
        .dock_fill = .{ .r = ctx.dock_fill_r, .g = ctx.dock_fill_g, .b = ctx.dock_fill_b },
        .accent = .{ .r = ctx.acc_r, .g = ctx.acc_g, .b = ctx.acc_b },
        .text = .{ .r = ctx.text_r, .g = ctx.text_g, .b = ctx.text_b },
    };
    // `paint_calendar_card` reads the display/selected dates; overlay comes
    // from the shell appearance like every other desktop widget.
    var disp = s.display;
    var sel = s.selected;
    if (!s.inited) {
        disp = local_time.today();
        sel = disp;
    }
    card.paintCard(c, card.width, card.height, ctx.ui_scale, cc, ctx.overlay_widget_card, disp, sel, local_time.today());
}
