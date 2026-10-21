//! Easing evaluation, springs, and tween tracks.
//!
//! Three layers, each built on the one below:
//!
//!   * `evaluateEasing` solves a cubic-bezier curve to get a 0..1 progress
//!     value. Newton-Raphson on the bezier's x, because the control points
//!     parameterise x and y independently and there is no closed form for
//!     "the y at x = t".
//!   * `Tween` animates a single float between two values over a duration.
//!   * `AnimationManager` runs many tweens at once, addressed by id, and
//!     retires them when they finish.
//!
//! Everything takes an explicit `nowMs` rather than reading a clock. That
//! keeps the whole system deterministic and testable — the caller owns time,
//! so a frame loop, a headless test, or a replay all drive it identically.

const std = @import("std");
const motion = @import("../tokens/motion.zig");

pub const Easing = motion.Easing;
pub const SpringParams = motion.SpringParams;
pub const kEmphasized = motion.k_emphasized;
pub const kEmphasizedDecelerate = motion.k_emphasized_decelerate;
pub const kEmphasizedAccelerate = motion.k_emphasized_accelerate;
pub const kStandard = motion.k_standard;
pub const kStandardDecelerate = motion.k_standard_decelerate;
pub const kStandardAccelerate = motion.k_standard_accelerate;
pub const kLinear = motion.k_linear;

/// Evaluate an M3 easing curve at t in [0,1] using cubic bezier approximation.
///
/// The maths lives on `Easing.evaluate` in the motion tokens; this free
/// function forwards to `Easing.evaluate` so call sites read uniformly.
pub fn evaluateEasing(e: Easing, t: f32) f32 {
    return e.evaluate(t);
}

/// Evaluate spring physics using implicit Euler integration.
///
/// `velocity` is in/out by pointer: the caller's velocity
/// is advanced by this step and remains the spring's momentum for the next
/// frame. The 1ms sub-step is what makes the integration stable — a larger
/// step at this stiffness overshoots and rings.
pub fn evaluateSpring(
    from: f32,
    to: f32,
    velocity: *f32,
    spring: SpringParams,
    dt_sec: f32,
) f32 {
    var pos = from - to;
    var t: f32 = 0.0;
    while (t < dt_sec) : (t += 0.001) {
        const step = @min(0.001, dt_sec - t);
        const force = -spring.stiffness * pos - spring.damping * velocity.*;
        velocity.* += (force / spring.mass) * step;
        pos += velocity.* * step;
    }
    return to + pos;
}

/// Simple tween track for a single float value.
pub const Tween = struct {
    from: f32 = 0.0,
    to: f32 = 0.0,
    start_ms: u64 = 0,
    duration_ms: u64 = 0,
    easing: Easing = kEmphasized,
    active: bool = false,

    pub fn start(
        self: *Tween,
        from_val: f32,
        to_val: f32,
        now_ms: u64,
        dur_ms: u64,
        ease: Easing,
    ) void {
        self.from = from_val;
        self.to = to_val;
        self.start_ms = now_ms;
        self.duration_ms = dur_ms;
        self.easing = ease;
        self.active = true;
    }

    /// `start` with default easing (emphasized), so callers that do
    /// not care about the curve do not have to name one.
    pub fn startDefault(
        self: *Tween,
        from_val: f32,
        to_val: f32,
        now_ms: u64,
        dur_ms: u64,
    ) void {
        self.start(from_val, to_val, now_ms, dur_ms, kEmphasized);
    }

    pub fn value(self: *const Tween, now_ms: u64) f32 {
        if (!self.active) return self.to;
        // A zero duration, or "no clock yet", snaps straight to the target.
        if (self.duration_ms == 0 or now_ms == 0) return self.to;
        const elapsed = now_ms - self.start_ms;
        if (elapsed >= self.duration_ms) return self.to;
        const t: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.duration_ms));
        return self.from + (self.to - self.from) * evaluateEasing(self.easing, t);
    }

    pub fn finished(self: *const Tween, now_ms: u64) bool {
        // An inactive tween is by definition done; subtraction is unsigned,
        // without guarding the underflow, so this stays an unsigned sub.
        return !self.active or (now_ms - self.start_ms) >= self.duration_ms;
    }

    pub fn stop(self: *Tween) void {
        self.active = false;
    }
};

/// A tween sink: a setter function pointer plus an opaque context.
/// function pointer plus an opaque context. `ctx` is handed back untouched.
pub const SetterFn = *const fn (ctx: ?*anyopaque, v: f32) void;
/// Completion callback, the same shape.
pub const CompleteFn = *const fn (ctx: ?*anyopaque) void;

/// AnimationManager manages multiple Tween animations by ID.
///
/// `animate` takes a setter/completion pair as
/// a function pointer plus a shared `ctx`. Callers that need several distinct
/// sinks dispatch on `ctx` themselves — see `entry.ctx`.
pub const AnimationManager = struct {
    pub const Id = u32;

    const Entry = struct {
        id: Id,
        from: f32,
        to: f32,
        duration_ms: u64,
        easing: Easing,
        setter: SetterFn,
        /// Null means no completion callback — a no-op rather than an error.
        onComplete: ?CompleteFn,
        ctx: ?*anyopaque,
        start_ms: u64 = 0,
        start_set: bool = false,
        finished: bool = false,
    };

    entries: std.ArrayListUnmanaged(Entry) = .empty,
    next_id: Id = 1,

    pub fn deinit(self: *AnimationManager, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.entries = .empty;
    }

    pub fn animate(
        self: *AnimationManager,
        allocator: std.mem.Allocator,
        from: f32,
        to: f32,
        duration_ms: u64,
        easing: Easing,
        setter: SetterFn,
        ctx: ?*anyopaque,
        onComplete: ?CompleteFn,
    ) !Id {
        const id = self.next_id;
        self.next_id += 1;
        try self.entries.append(allocator, .{
            .id = id,
            .from = from,
            .to = to,
            .duration_ms = duration_ms,
            .easing = easing,
            .setter = setter,
            .onComplete = onComplete,
            .ctx = ctx,
        });
        return id;
    }

    pub fn cancel(self: *AnimationManager, id: Id) void {
        for (self.entries.items) |*e| {
            if (e.id == id) {
                e.finished = true;
                break;
            }
        }
    }

    pub fn cancelAll(self: *AnimationManager) void {
        self.entries.clearRetainingCapacity();
    }

    pub fn tick(self: *AnimationManager, allocator: std.mem.Allocator, now_ms: u64) void {
        for (self.entries.items) |*e| {
            if (e.finished) continue;
            // The start time is latched on the first tick, not at `animate`
            // time, so an animation queued mid-frame does not begin already
            // part-elapsed.
            if (!e.start_set) {
                e.start_ms = now_ms;
                e.start_set = true;
            }
            const elapsed = now_ms - e.start_ms;
            if (elapsed >= e.duration_ms) {
                e.setter(e.ctx, e.to);
                e.finished = true;
                if (e.onComplete) |cb| cb(e.ctx);
            } else {
                const t: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(e.duration_ms));
                const v = e.from + (e.to - e.from) * evaluateEasing(e.easing, t);
                e.setter(e.ctx, v);
            }
        }
        // Retire finished entries in place.
        var kept: usize = 0;
        for (self.entries.items) |e| {
            if (!e.finished) {
                self.entries.items[kept] = e;
                kept += 1;
            }
        }
        self.entries.items.len = kept;
        _ = allocator;
    }

    pub fn hasActive(self: *const AnimationManager) bool {
        return self.entries.items.len != 0;
    }
};

// ————— tests —————

const testing = std.testing;

/// Collects the last value a tween produced, so a sink can be asserted on.
const SinkProbe = struct {
    last: f32 = 0.0,
    calls: usize = 0,
    completed: usize = 0,

    fn set(ctx: ?*anyopaque, v: f32) void {
        const self: *SinkProbe = @ptrCast(@alignCast(ctx.?));
        self.last = v;
        self.calls += 1;
    }
    fn done(ctx: ?*anyopaque) void {
        const self: *SinkProbe = @ptrCast(@alignCast(ctx.?));
        self.completed += 1;
    }
};

test "m3-animation: easing solve matches the curve's endpoints" {
    // The bezier solve must pin 0 and 1 exactly, and stay monotonic between.
    try testing.expectEqual(@as(f32, 0.0), evaluateEasing(kStandard, 0.0));
    try testing.expectEqual(@as(f32, 1.0), evaluateEasing(kStandard, 1.0));
    // linear is the identity — a good check on the Newton iteration's accuracy.
    try testing.expectApproxEqAbs(@as(f32, 0.5), evaluateEasing(kLinear, 0.5), 1e-4);
}

test "m3-animation: spring settles toward the target" {
    var vel: f32 = 0.0;
    // Start 1 unit away with no momentum; a damped spring must move toward
    // the target rather than away from it.
    const moved = evaluateSpring(0.0, 1.0, &vel, .{ .stiffness = 400, .damping = 30, .mass = 1 }, 0.016);
    try testing.expect(moved > 0.0 and moved < 1.0);
    try testing.expect(vel > 0.0);
}

test "m3-animation: tween snaps to target when inactive or zero-duration" {
    var twn = Tween{};
    // Inactive -> the target, immediately. Seed `to` first; a default-constructed
    // tween's target is 0, and `value()` returns it verbatim when not running.
    twn.to = 7.0;
    try testing.expectEqual(@as(f32, 7.0), twn.value(1000));
    // A zero-duration tween also snaps (zero duration guarded).
    twn.start(0.0, 7.0, 100, 0, kStandard);
    try testing.expectEqual(@as(f32, 7.0), twn.value(150));
}

test "m3-animation: tween interpolates and then settles" {
    var twn = Tween{};
    twn.start(0.0, 10.0, 1000, 500, kLinear);
    // Mid-flight, linear easing means half the duration is half the distance.
    try testing.expectApproxEqAbs(@as(f32, 5.0), twn.value(1250), 1e-3);
    // Past the end it clamps to the target rather than overshooting.
    try testing.expectEqual(@as(f32, 10.0), twn.value(2000));
    try testing.expect(twn.finished(2000));
    twn.stop();
    try testing.expect(!twn.active);
}

test "m3-animation: manager runs, reports and retires entries" {
    var mgr = AnimationManager{};
    var probe = SinkProbe{};
    defer mgr.deinit(testing.allocator);

    const id = try mgr.animate(
        testing.allocator,
        0.0,
        1.0,
        100,
        kLinear,
        SinkProbe.set,
        &probe,
        SinkProbe.done,
    );
    try testing.expect(mgr.hasActive());

    // The first tick latches the start time at *this* instant, so an
    // animation is at 0 on its first frame rather than part-elapsed.
    mgr.tick(testing.allocator, 5000);
    try testing.expectEqual(@as(f32, 0.0), probe.last);

    // A later tick inside the duration interpolates.
    mgr.tick(testing.allocator, 5050);
    try testing.expectApproxEqAbs(@as(f32, 0.5), probe.last, 1e-3);

    // Past the duration it lands on the target, fires completion, and is
    // dropped from the list so `hasActive` goes false.
    mgr.tick(testing.allocator, 5200);
    try testing.expectEqual(@as(f32, 1.0), probe.last);
    try testing.expectEqual(@as(usize, 1), probe.completed);
    try testing.expect(!mgr.hasActive());

    // An id can still be cancelled after it is gone — that is a no-op, not a
    // crash — cancelling a gone id simply finds nothing.
    mgr.cancel(id);
}

test "m3-animation: cancel stops an entry before it completes" {
    var mgr = AnimationManager{};
    var probe = SinkProbe{};
    defer mgr.deinit(testing.allocator);

    const id = try mgr.animate(
        testing.allocator,
        0.0,
        1.0,
        100,
        kLinear,
        SinkProbe.set,
        &probe,
        null,
    );
    mgr.tick(testing.allocator, 1000);
    mgr.cancel(id);
    mgr.tick(testing.allocator, 1200);
    // The completion callback must not fire for a cancelled entry.
    try testing.expectEqual(@as(usize, 0), probe.completed);
    try testing.expect(!mgr.hasActive());
}
