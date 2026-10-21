const std = @import("std");

pub const Toast = struct {
    id: u32,
    height: i32,
    visible_ms: i64 = 0,
};

pub fn layoutStack(toasts: []Toast, max_h: i32, gap: i32, margin: i32) i32 {
    var y = margin;
    var used: usize = 0;
    for (toasts) |toast| {
        if (y + toast.height > max_h - margin) break;
        toasts[used].height = toast.height;
        y += toast.height + gap;
        used += 1;
    }
    return @intCast(used);
}

pub fn expired(now_ms: i64, shown_ms: i64, timeout_ms: i64) bool {
    if (timeout_ms <= 0) return false;
    return now_ms - shown_ms >= timeout_ms;
}

test "toast-host: stacking + expiry" {
    const t = std.testing;
    var toasts = [_]Toast{ .{ .id = 1, .height = 100 }, .{ .id = 2, .height = 100 }, .{ .id = 3, .height = 100 } };
    try t.expectEqual(@as(i32, 2), layoutStack(&toasts, 250, 8, 16));
    try t.expect(expired(7000, 0, 6000));
    try t.expect(!expired(5000, 0, 6000));
    try t.expect(!expired(999999, 0, 0));
}
