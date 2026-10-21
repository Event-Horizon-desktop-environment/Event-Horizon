const std = @import("std");

pub const Choice = enum { none, lock, logout, sleep, reboot, shutdown };

pub const Menu = struct {
    choice: Choice = .none,
    confirm_armed: bool = false,
    confirm_deadline_ms: i64 = 0,
    confirm_window_ms: i64 = 10000,

    pub fn pick(self: *Menu, c: Choice, now_ms: i64) void {
        if (self.choice == c and self.confirm_armed) return;
        self.choice = c;
        self.confirm_armed = false;
        self.confirm_deadline_ms = now_ms + self.confirm_window_ms;
    }

    pub fn confirm(self: *Menu, now_ms: i64) ?Choice {
        if (self.choice == .none) return null;
        if (now_ms > self.confirm_deadline_ms) {
            self.choice = .none;
            return null;
        }
        self.confirm_armed = true;
        return self.choice;
    }

    pub fn execute(self: *Menu) ?Choice {
        if (!self.confirm_armed) return null;
        const c = self.choice;
        self.choice = .none;
        self.confirm_armed = false;
        return c;
    }
};

test "powermenu: pick-confirm-execute with expiry" {
    const t = std.testing;
    var m = Menu{};
    m.pick(.reboot, 0);
    try t.expect(m.confirm(1000) == .reboot);
    try t.expect(m.execute() == .reboot);
    try t.expect(m.execute() == null);
    m.pick(.shutdown, 0);
    try t.expect(m.confirm(20000) == null);
}
