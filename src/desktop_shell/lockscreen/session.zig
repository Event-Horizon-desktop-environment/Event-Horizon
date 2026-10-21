const std = @import("std");

pub const LockState = enum { unlocked, locking, locked, unlocking };

pub const Session = struct {
    state: LockState = .unlocked,
    auth_pending: bool = false,
    failures: u32 = 0,

    pub fn requestLock(self: *Session) void {
        if (self.state == .unlocked) self.state = .locking;
    }

    pub fn lockShown(self: *Session) void {
        if (self.state == .locking) self.state = .locked;
    }

    pub fn authBegin(self: *Session) void {
        if (self.state == .locked) self.auth_pending = true;
    }

    pub fn authResult(self: *Session, ok: bool) void {
        self.auth_pending = false;
        if (ok and self.state == .locked) {
            self.state = .unlocking;
            self.failures = 0;
        } else if (!ok) {
            self.failures += 1;
        }
    }

    pub fn unlockDone(self: *Session) void {
        if (self.state == .unlocking) self.state = .unlocked;
    }

    pub fn inputBlocked(self: *const Session) bool {
        return self.state == .locked or self.state == .locking;
    }
};

test "lockscreen: full cycle + failure count" {
    const t = std.testing;
    var s = Session{};
    try t.expect(!s.inputBlocked());
    s.requestLock();
    try t.expect(s.inputBlocked());
    s.lockShown();
    s.authBegin();
    s.authResult(false);
    try t.expectEqual(@as(u32, 1), s.failures);
    try t.expect(s.inputBlocked());
    s.authResult(true);
    s.unlockDone();
    try t.expect(!s.inputBlocked());
}
