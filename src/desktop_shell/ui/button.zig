const std = @import("std");

pub const State = enum { idle, hover, pressed, disabled };

pub const Button = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    state: State = .idle,
    enabled: bool = true,

    pub fn contains(self: *const Button, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    pub fn onMotion(self: *Button, px: i32, py: i32) void {
        if (!self.enabled) {
            self.state = .disabled;
            return;
        }
        if (self.state == .pressed) return;
        self.state = if (self.contains(px, py)) .hover else .idle;
    }

    pub fn onPress(self: *Button, px: i32, py: i32) bool {
        if (!self.enabled or !self.contains(px, py)) return false;
        self.state = .pressed;
        return true;
    }

    pub fn onRelease(self: *Button, px: i32, py: i32) bool {
        const was = self.state == .pressed;
        self.state = if (!self.enabled) .disabled else if (self.contains(px, py)) .hover else .idle;
        return was and self.enabled and self.contains(px, py);
    }
};

test "button: press/release inside fires" {
    const t = std.testing;
    var b = Button{ .x = 10, .y = 10, .w = 100, .h = 30 };
    b.onMotion(50, 20);
    try t.expectEqual(State.hover, b.state);
    try t.expect(b.onPress(50, 20));
    try t.expect(b.onRelease(50, 20));
    try t.expect(!b.onPress(500, 500));
    try t.expect(!b.onRelease(500, 500));
    b.enabled = false;
    b.onMotion(50, 20);
    try t.expectEqual(State.disabled, b.state);
}
