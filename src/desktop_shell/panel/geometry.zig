const std = @import("std");
const cfg = @import("../../config/schema1.zig");

pub const Placement = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    anchor: u32 = 0,
    exclusive_zone: i32 = 0,
};

pub const ANCHOR_TOP: u32 = 1;
pub const ANCHOR_BOTTOM: u32 = 2;
pub const ANCHOR_LEFT: u32 = 4;
pub const ANCHOR_RIGHT: u32 = 8;

pub fn effectiveHeight(s: *const cfg.PanelSettings) i32 {
    const breathing = @max(0, s.icon_size + 12 - s.height);
    return s.height + breathing;
}

pub fn placeBar(s: *const cfg.PanelSettings, output_w: i32, output_h: i32) Placement {
    const h = @max(1, effectiveHeight(s));
    var p = Placement{ .h = h };
    const span_w = switch (s.width_mode) {
        0 => @max(1, output_w - 2 * s.floating_amount),
        2 => @max(1, output_w - 2 * s.edge_gap),
        else => output_w,
    };
    p.w = span_w;
    if (s.position_top) {
        p.anchor = ANCHOR_TOP | ANCHOR_LEFT | ANCHOR_RIGHT;
        p.x = @divTrunc(output_w - span_w, 2);
        p.y = s.edge_gap;
        p.exclusive_zone = if (s.reserve_space) h + s.edge_gap + s.exclusive_zone_gap else 0;
    } else {
        p.anchor = ANCHOR_BOTTOM | ANCHOR_LEFT | ANCHOR_RIGHT;
        p.x = @divTrunc(output_w - span_w, 2);
        p.y = output_h - h - s.edge_gap;
        p.exclusive_zone = if (s.reserve_space) h + s.edge_gap + s.exclusive_zone_gap else 0;
    }
    return p;
}

test "panel-geometry: top full-bleed bar" {
    const t = std.testing;
    var s = cfg.PanelSettings{ .height = 36, .width_mode = 1, .position_top = true, .edge_gap = 0 };
    const p = placeBar(&s, 1920, 1080);
    try t.expectEqual(@as(i32, 0), p.x);
    try t.expectEqual(@as(i32, 0), p.y);
    try t.expectEqual(@as(i32, 1920), p.w);
    try t.expectEqual(@as(i32, 36), p.h);
    try t.expectEqual(ANCHOR_TOP | ANCHOR_LEFT | ANCHOR_RIGHT, p.anchor);
    try t.expectEqual(@as(i32, 36), p.exclusive_zone);
}

test "panel-geometry: bottom floating pill with gap" {
    const t = std.testing;
    var s = cfg.PanelSettings{ .height = 36, .width_mode = 0, .position_top = false, .floating_amount = 8, .edge_gap = 4 };
    const p = placeBar(&s, 1920, 1080);
    try t.expectEqual(@as(i32, 1904), p.w);
    try t.expectEqual(@as(i32, 8), p.x);
    try t.expectEqual(@as(i32, 1080 - 36 - 4), p.y);
    try t.expectEqual(@as(i32, 36 + 4), p.exclusive_zone);
}

test "panel-geometry: icon breathing room grows bar" {
    const t = std.testing;
    var s = cfg.PanelSettings{ .height = 20, .icon_size = 32 };
    try t.expectEqual(@as(i32, 32 + 12), effectiveHeight(&s));
}
