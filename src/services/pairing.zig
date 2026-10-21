const std = @import("std");

pub const Method = enum { none, pin_code, passkey_display, passkey_confirm, just_works };

pub const Pairing = struct {
    state: State = .idle,
    method: Method = .none,
    passkey: u32 = 0,

    pub const State = enum { idle, waiting_pin, displaying_passkey, confirming, done, failed, cancelled };

    pub fn beginPin(self: *Pairing) void {
        self.state = .waiting_pin;
        self.method = .pin_code;
    }

    pub fn beginPasskey(self: *Pairing, passkey: u32) void {
        self.state = .displaying_passkey;
        self.method = .passkey_display;
        self.passkey = passkey % 1000000;
    }

    pub fn beginConfirm(self: *Pairing, passkey: u32) void {
        self.state = .confirming;
        self.method = .passkey_confirm;
        self.passkey = passkey % 1000000;
    }

    pub fn answer(self: *Pairing, accept: bool) void {
        if (self.state == .waiting_pin or self.state == .confirming or self.state == .displaying_passkey) {
            self.state = if (accept) .done else .failed;
        }
    }

    pub fn cancel(self: *Pairing) void {
        if (self.state != .done) self.state = .cancelled;
    }

    pub fn isSettled(self: *const Pairing) bool {
        return self.state == .done or self.state == .failed or self.state == .cancelled;
    }
};

test "pairing: flows settle correctly" {
    const t = std.testing;
    var p = Pairing{};
    p.beginPin();
    try t.expect(!p.isSettled());
    p.answer(true);
    try t.expect(p.isSettled());
    try t.expectEqual(Pairing.State.done, p.state);
    var q = Pairing{};
    q.beginConfirm(1234567);
    try t.expectEqual(@as(u32, 234567), q.passkey);
    q.answer(false);
    try t.expectEqual(Pairing.State.failed, q.state);
    var r = Pairing{};
    r.beginPasskey(42);
    r.cancel();
    try t.expectEqual(Pairing.State.cancelled, r.state);
}
