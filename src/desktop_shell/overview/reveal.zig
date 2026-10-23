//! Off-monitor window reveal: the compositor will not copy a window whose
//! box misses its monitor, so the reveal pass briefly focuses each such
//! window (parking it on-monitor), forces a fresh capture until its frame
//! lands, then restores the saved focus. Idle → Revealed → Syncing →
//! Restoring, with bounded retries and a quiet recheck every second. It
//! runs in both capture modes — snapshot one-shots stall off-monitor
//! the same way live streams do.

const std = @import("std");

pub const State = enum { idle, revealed, syncing, restoring };

/// An address copied out of the snapshot: valid past any refresh.
pub const Target = struct {
    buf: [32]u8 = @as([32]u8, @splat(0)),
    len: usize = 0,

    pub fn slice(self: *const Target) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *Target, addr: []const u8) void {
        const n = @min(addr.len, self.buf.len);
        @memcpy(self.buf[0..n], addr[0..n]);
        self.len = n;
    }
};

/// Owner hooks. All addresses are borrowed except through `Target`.
pub const Ctx = struct {
    ptr: *anyopaque,
    /// Capture running, overlay open and settled (not apps, not dragging).
    enabled: *const fn (*anyopaque) bool,
    /// First overflow window still without a frame, if any.
    find_target: *const fn (*anyopaque) ?Target,
    /// Currently focused window address, if the snapshot names one.
    focused: *const fn (*anyopaque) ?Target,
    has_frame: *const fn (*anyopaque, []const u8) bool,
    focus: *const fn (*anyopaque, []const u8) void,
    /// Forced fresh capture for one window (budget reset + resync).
    resync: *const fn (*anyopaque, []const u8) void,
};

pub const Reveal = struct {
    state: State = .idle,
    target: Target = .{},
    orig: Target = .{},
    tries: u8 = 0,
    deadline_ms: u64 = 0,
    next_check_ms: u64 = 0,

    const Self = @This();

    /// Advance the machine. True while it owns work — the owner keeps its
    /// pulse running that long so deadlines are met without input.
    pub fn tick(self: *Self, now_ms: u64, ctx: Ctx) bool {
        switch (self.state) {
            .idle => {
                if (now_ms < self.next_check_ms) return false;
                self.next_check_ms = now_ms + 1000;
                if (!ctx.enabled(ctx.ptr)) return false;
                const t = ctx.find_target(ctx.ptr) orelse return false;
                self.target = t;
                self.orig = ctx.focused(ctx.ptr) orelse .{};
                ctx.focus(ctx.ptr, self.target.slice());
                self.state = .revealed;
                self.deadline_ms = now_ms + 500;
                return true;
            },
            .revealed => {
                if (now_ms < self.deadline_ms) return true;
                ctx.resync(ctx.ptr, self.target.slice());
                self.tries = 0;
                self.state = .syncing;
                self.deadline_ms = now_ms + 900;
                return true;
            },
            .syncing => {
                if (ctx.has_frame(ctx.ptr, self.target.slice())) {
                    ctx.focus(ctx.ptr, self.orig.slice());
                    self.state = .restoring;
                    self.deadline_ms = now_ms + 300;
                    return true;
                }
                if (now_ms < self.deadline_ms) return true;
                self.tries += 1;
                if (self.tries >= 2) {
                    ctx.focus(ctx.ptr, self.orig.slice());
                    self.state = .idle;
                    return false;
                }
                ctx.resync(ctx.ptr, self.target.slice());
                self.deadline_ms = now_ms + 900;
                return true;
            },
            .restoring => {
                if (now_ms < self.deadline_ms) return true;
                self.state = .idle;
                self.next_check_ms = now_ms + 1000;
                return false;
            },
        }
    }
};

const Fake = struct {
    enabled: bool = true,
    target: ?Target = null,
    orig: ?Target = null,
    frames: bool = false,
    focused_to: [8][]const u8 = @as([8][]const u8, @splat(undefined)),
    n_focus: usize = 0,
    resyncs: u32 = 0,

    fn ctx(self: *Fake) Ctx {
        return .{
            .ptr = self,
            .enabled = struct {
                fn f(p: *anyopaque) bool {
                    const s: *Fake = @ptrCast(@alignCast(p));
                    return s.enabled;
                }
            }.f,
            .find_target = struct {
                fn f(p: *anyopaque) ?Target {
                    const s: *Fake = @ptrCast(@alignCast(p));
                    return s.target;
                }
            }.f,
            .focused = struct {
                fn f(p: *anyopaque) ?Target {
                    const s: *Fake = @ptrCast(@alignCast(p));
                    return s.orig;
                }
            }.f,
            .has_frame = struct {
                fn f(p: *anyopaque, addr: []const u8) bool {
                    const s: *Fake = @ptrCast(@alignCast(p));
                    _ = addr;
                    return s.frames;
                }
            }.f,
            .focus = struct {
                fn f(p: *anyopaque, addr: []const u8) void {
                    const s: *Fake = @ptrCast(@alignCast(p));
                    if (s.n_focus < s.focused_to.len) {
                        s.focused_to[s.n_focus] = addr;
                        s.n_focus += 1;
                    }
                }
            }.f,
            .resync = struct {
                fn f(p: *anyopaque, addr: []const u8) void {
                    const s: *Fake = @ptrCast(@alignCast(p));
                    _ = addr;
                    s.resyncs += 1;
                }
            }.f,
        };
    }
};

test "overview-reveal: focus, capture, restore, idle" {
    const t = std.testing;
    var fake = Fake{};
    var ot = Target{};
    ot.set("0xabc");
    fake.target = ot;
    var oo = Target{};
    oo.set("0x1");
    fake.orig = oo;
    var r = Reveal{};
    const c = fake.ctx();
    try t.expect(r.tick(0, c));
    try t.expectEqual(State.revealed, r.state);
    try t.expectEqual(@as(usize, 1), fake.n_focus);
    try t.expect(r.tick(100, c));
    try t.expect(r.tick(500, c));
    try t.expectEqual(State.syncing, r.state);
    try t.expectEqual(@as(u32, 1), fake.resyncs);
    try t.expect(r.tick(600, c));
    fake.frames = true;
    try t.expect(r.tick(700, c));
    try t.expectEqual(State.restoring, r.state);
    try t.expect(r.tick(800, c));
    try t.expect(!r.tick(1000, c));
    try t.expectEqual(State.idle, r.state);
}

test "overview-reveal: two failed syncs give up and restore focus" {
    const t = std.testing;
    var fake = Fake{};
    var ot = Target{};
    ot.set("0xabc");
    fake.target = ot;
    var r = Reveal{};
    const c = fake.ctx();
    try t.expect(r.tick(0, c));
    try t.expect(r.tick(500, c));
    try t.expectEqual(State.syncing, r.state);
    try t.expect(r.tick(1400, c));
    try t.expectEqual(@as(u32, 2), fake.resyncs);
    try t.expect(!r.tick(2300, c));
    try t.expectEqual(State.idle, r.state);
    // Focus went to the target, then back to the (empty) origin.
    try t.expectEqual(@as(usize, 2), fake.n_focus);
}

test "overview-reveal: quiet when disabled or nothing overflows" {
    const t = std.testing;
    var fake = Fake{ .enabled = false };
    var r = Reveal{};
    try t.expect(!r.tick(0, fake.ctx()));
    fake.enabled = true;
    try t.expect(!r.tick(100, fake.ctx()));
}
