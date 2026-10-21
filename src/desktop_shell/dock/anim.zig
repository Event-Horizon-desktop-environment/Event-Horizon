//! The one animation the dock actually runs.
//!
//! There is no magnification curve in the dock: hovering an app slot
//! raises it by a fixed 5 px over 165 ms of ease-out-cubic, and pressing
//! snaps the icon to 0.92 scale with a 2 px press lift. Everything here is a
//! single eased scalar so the rest of the shell can stay synchronous.

const std = @import("std");

/// `kDockHoverLiftMax` — the rise a hovered app slot reaches.
pub const kHoverLiftPx = 5.0;
/// `dock_anim_start_hover_lift` passes `165.f` ms.
pub const kHoverLiftNs: u64 = 165 * std.time.ns_per_ms;
/// `kDockPressIconScale`.
pub const kPressIconScale = 0.92;
/// `kDockPressLiftPx`.
pub const kPressLiftPx = 2.0;

/// `Easing::EaseOutCubic`: `f³ + 1` with `f = t - 1`, i.e. `1 - (1-t)³`.
pub fn easeOutCubic(t: f64) f64 {
    const u = std.math.clamp(t, 0.0, 1.0);
    const f = u - 1.0;
    return f * f * f + 1.0;
}

/// A value tweened from wherever it currently sits to `to`, driven by an
/// external monotonic clock (the dock arms a 16 ms timer only while
/// `running`, so an idle dock never spins).
pub const Tween = struct {
    value: f64 = 0.0,
    from: f64 = 0.0,
    to: f64 = 0.0,
    start_ns: u64 = 0,
    dur_ns: u64 = kHoverLiftNs,
    running: bool = false,

    /// Starts a new tween from the *current* value.
    /// snaps the lift to 0 before doing this, so callers that want the
    /// "pop then rise" behaviour set `value = 0` first.
    pub fn begin(self: *Tween, to: f64, now_ns: u64, dur_ns: u64) void {
        self.from = self.value;
        self.to = to;
        self.start_ns = now_ns;
        self.dur_ns = dur_ns;
        self.running = self.value != to;
        if (!self.running) self.value = to;
    }

    /// Advance to `now_ns`; returns true while more ticks are needed.
    pub fn step(self: *Tween, now_ns: u64) bool {
        if (!self.running) return false;
        const elapsed: f64 = @floatFromInt(now_ns -| self.start_ns);
        const total: f64 = @floatFromInt(self.dur_ns);
        const u = if (total <= 0.0) 1.0 else elapsed / total;
        const t = std.math.clamp(u, 0.0, 1.0);
        self.value = self.from + (self.to - self.from) * easeOutCubic(t);
        if (t >= 1.0) {
            self.value = self.to;
            self.running = false;
            return false;
        }
        return true;
    }

    /// Teleport — used when the pointer leaves the layer or a reload resets
    /// geometry, where a slide would look like a glitch.
    pub fn jump(self: *Tween, v: f64) void {
        self.value = v;
        self.from = v;
        self.to = v;
        self.running = false;
    }
};

pub fn monotonicNs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const s: u64 = @intCast(@max(ts.sec, 0));
    const n: u64 = @intCast(@max(ts.nsec, 0));
    return s * std.time.ns_per_s + n;
}

test "dock-anim: easeOutCubic eases cubic" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f64, 0.0), easeOutCubic(0.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 1.0), easeOutCubic(1.0), 1e-9);
    // 1 - (1-0.5)³ = 0.875 — fast out of the gate, slow into the target.
    try t.expectApproxEqAbs(@as(f64, 0.875), easeOutCubic(0.5), 1e-9);
    // Out-of-range input is clamped rather than extrapolated.
    try t.expectApproxEqAbs(@as(f64, 1.0), easeOutCubic(4.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 0.0), easeOutCubic(-1.0), 1e-9);
}

test "dock-anim: tween reaches its target and stops asking for ticks" {
    const t = std.testing;
    var tw: Tween = .{};
    tw.begin(kHoverLiftPx, 1_000_000, kHoverLiftNs);
    try t.expect(tw.running);

    // Halfway through, the ease-out has covered 7/8 of the distance.
    try t.expect(tw.step(1_000_000 + kHoverLiftNs / 2));
    try t.expectApproxEqAbs(@as(f64, 4.375), tw.value, 1e-6);

    // Past the duration it lands exactly on the target and goes idle.
    try t.expect(!tw.step(1_000_000 + kHoverLiftNs * 2));
    try t.expectApproxEqAbs(kHoverLiftPx, tw.value, 1e-9);
    try t.expect(!tw.running);
    try t.expect(!tw.step(1_000_000 + kHoverLiftNs * 3));
}

test "dock-anim: no-op retarget and jumps leave the tween idle" {
    const t = std.testing;
    var tw = Tween{ .value = 5.0 };
    tw.begin(5.0, 0, kHoverLiftNs);
    try t.expect(!tw.running);

    tw.jump(0.0);
    try t.expectApproxEqAbs(@as(f64, 0.0), tw.value, 1e-9);
    try t.expect(!tw.running);

    // Leaving a slot animates down from wherever the lift had got to.
    tw.value = 3.0;
    tw.begin(0.0, 0, kHoverLiftNs);
    try t.expect(tw.running);
    try t.expectApproxEqAbs(@as(f64, 3.0), tw.value, 1e-9);
    try t.expect(!tw.step(kHoverLiftNs));
    try t.expectApproxEqAbs(@as(f64, 0.0), tw.value, 1e-9);
}
