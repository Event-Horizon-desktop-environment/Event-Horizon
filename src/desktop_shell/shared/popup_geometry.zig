const std = @import("std");

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

pub const Anchor = enum { top_left, top_right, bottom_left, bottom_right, top_center, bottom_center };

pub fn placePopup(anchor_x: i32, anchor_y: i32, w: i32, h: i32, anchor: Anchor, out_w: i32, out_h: i32, margin: i32) Rect {
    var r = Rect{ .w = w, .h = h };
    switch (anchor) {
        .top_left => {
            r.x = anchor_x;
            r.y = anchor_y;
        },
        .top_right => {
            r.x = anchor_x - w;
            r.y = anchor_y;
        },
        .bottom_left => {
            r.x = anchor_x;
            r.y = anchor_y - h;
        },
        .bottom_right => {
            r.x = anchor_x - w;
            r.y = anchor_y - h;
        },
        .top_center => {
            r.x = anchor_x - @divTrunc(w, 2);
            r.y = anchor_y;
        },
        .bottom_center => {
            r.x = anchor_x - @divTrunc(w, 2);
            r.y = anchor_y - h;
        },
    }
    r.x = @max(margin, @min(r.x, out_w - w - margin));
    r.y = @max(margin, @min(r.y, out_h - h - margin));
    if (r.w > out_w - 2 * margin) {
        r.x = margin;
        r.w = out_w - 2 * margin;
    }
    if (r.h > out_h - 2 * margin) {
        r.y = margin;
        r.h = out_h - 2 * margin;
    }
    return r;
}

test "popup: anchors and output clamping" {
    const t = std.testing;
    const a = placePopup(100, 40, 200, 100, .bottom_left, 1920, 1080, 8);
    try t.expectEqual(@as(i32, 100), a.x);
    try t.expectEqual(@as(i32, 8), a.y);
    const b = placePopup(1900, 40, 200, 100, .top_left, 1920, 1080, 8);
    try t.expectEqual(@as(i32, 1920 - 200 - 8), b.x);
    const c = placePopup(960, 0, 300, 200, .top_center, 1920, 1080, 8);
    try t.expectEqual(@as(i32, 960 - 150), c.x);
    try t.expectEqual(@as(i32, 8), c.y);
}
