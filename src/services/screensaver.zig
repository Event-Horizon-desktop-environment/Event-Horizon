const std = @import("std");

pub const State = struct {
    active: bool = false,
    idle_since_ms: i64 = 0,
    idle_timeout_ms: i64 = 300000,

    pub fn markActive(self: *State, now_ms: i64) void {
        self.active = false;
        self.idle_since_ms = now_ms;
    }

    pub fn check(self: *State, now_ms: i64) bool {
        if (self.active) return false;
        if (now_ms - self.idle_since_ms >= self.idle_timeout_ms) {
            self.active = true;
            return true;
        }
        return false;
    }
};

test "screensaver: idle trip + reset" {
    const t = std.testing;
    var s = State{};
    s.markActive(0);
    try t.expect(!s.check(1000));
    try t.expect(s.check(300001));
    try t.expect(!s.check(400000));
    s.markActive(400000);
    try t.expect(!s.active);
}
