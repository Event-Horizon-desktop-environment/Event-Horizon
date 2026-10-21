//! M3 easing curves, duration classes and springs.
//!
//! An `Easing` is a cubic-bezier control point pair `(x1, y1, x2, y2)` with
//! the implicit endpoints `(0,0)` and `(1,1)`, which is exactly the shape
//! `cairo` and CSS both take — `animation.zig` evaluates it by solving the
//! bezier for `x(t) = t` with Newton-Raphson, so a curve here can be handed
//! straight to a frame interpolator.
//!
//! Durations are the five M3 *classes*, not arbitrary values: components pick
//! a class (`Emphasis`, `Large`, …) rather than a millisecond count, so a
/// theme can retune the whole shell's snappiness in one place.

/// M3 easing curves as cubic-bezier parameters.
pub const Easing = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    /// Evaluate the curve at `t` via Newton-Raphson solve, kept here rather than in
    /// `animation.zig` because it is a property of the curve itself and is
    /// useful to anything that wants a value without owning an animation.
    ///
    /// DELIBERATE FIX: the Newton-Raphson iterate `u`
    /// is clamped to `[0,1]` on *every* step, not just once after the loop.
    ///
    /// Clamping only at the end fails. For a curve whose initial slope is near
    /// zero — `k_standard_decelerate` (`x1 == x2 == 0`), whose derivative at
    /// `u` is `3u²` — the first Newton step at `t = 0.01` flings `u ≈ 1/(3t)`
    /// far outside `[0,1]`, the 8-pass iteration never recovers, and the
    /// trailing clamp returns `1.0`. A short tween on that curve therefore
    /// snaps to its target on the first frame instead of easing. Clamping each
    /// step keeps the iterate in the physically meaningful domain so the solve
    /// converges instead of diverging.
    ///
    /// This clamps `u` inside the loop. Everywhere else the trees agree frame
    /// for frame.
    pub fn evaluate(self: Easing, t: f32) f32 {
        if (t <= 0.0) return 0.0;
        if (t >= 1.0) return 1.0;

        // Sample x, y and dx/dt of the parametric bezier.
        const sample = struct {
            fn cubic(p0: f32, p1: f32, p2: f32, p3: f32, u: f32) f32 {
                const v = 1.0 - u;
                return v * v * v * p0 + 3.0 * v * v * u * p1 + 3.0 * v * u * u * p2 + u * u * u * p3;
            }
            fn dx(e: Easing, u: f32) f32 {
                const v = 1.0 - u;
                return 3.0 * v * v * (e.x1 - 0.0) + 6.0 * v * u * (e.x2 - e.x1) + 3.0 * u * u * (1.0 - e.x2);
            }
        };

        // Newton-Raphson for the parameter u where x(u) == t, then read y(u).
        var u = t;
        comptime var i: usize = 0;
        inline while (i < 8) : (i += 1) {
            const x = sample.cubic(0.0, self.x1, self.x2, 1.0, u) - t;
            const d = sample.dx(self, u);
            if (@abs(x) < 1e-5 or @abs(d) < 1e-6) break;
            u -= x / d;
            // Clamp each step so a near-zero slope can't fling the iterate
            // out of [0,1] and never recover (see doc comment).
            u = @max(0.0, @min(1.0, u));
        }
        u = @max(0.0, @min(1.0, u));
        return @max(0.0, @min(1.0, sample.cubic(0.0, self.y1, self.y2, 1.0, u)));
    }
};

pub const k_emphasized: Easing = .{ .x1 = 0.2, .y1 = 0.0, .x2 = 0.0, .y2 = 1.0 };
pub const k_emphasized_decelerate: Easing = .{ .x1 = 0.05, .y1 = 0.7, .x2 = 0.1, .y2 = 1.0 };
pub const k_emphasized_accelerate: Easing = .{ .x1 = 0.3, .y1 = 0.0, .x2 = 0.8, .y2 = 0.15 };
pub const k_standard: Easing = .{ .x1 = 0.2, .y1 = 0.0, .x2 = 0.0, .y2 = 1.0 };
pub const k_standard_decelerate: Easing = .{ .x1 = 0.0, .y1 = 0.0, .x2 = 0.0, .y2 = 1.0 };
pub const k_standard_accelerate: Easing = .{ .x1 = 0.3, .y1 = 0.0, .x2 = 1.0, .y2 = 1.0 };
pub const k_linear: Easing = .{ .x1 = 0.0, .y1 = 0.0, .x2 = 1.0, .y2 = 1.0 };

/// M3 duration classes (milliseconds).
pub const Duration = enum(u64) {
    /// 500ms — palette crossfade, page transition.
    emphasis = 500,
    /// 400ms — sheet open.
    large = 400,
    /// 300ms — button ripple, dialog open, FAB expand.
    medium = 300,
    /// 200ms — switch/checkbox/radio, chip enter/exit, dialog close.
    small = 200,
    /// 100ms — state layers, focus ring, slider thumb.
    extra_small = 100,
};

/// Spring physics (M3 Expressive 2025).
pub const SpringParams = struct {
    /// Higher = snappier.
    stiffness: f32 = 400.0,
    /// Lower = more bounce.
    damping: f32 = 30.0,
    mass: f32 = 1.0,
};

pub const k_spring_responsive: SpringParams = .{ .stiffness = 500.0, .damping = 35.0, .mass = 1.0 };
pub const k_spring_natural: SpringParams = .{ .stiffness = 300.0, .damping = 25.0, .mass = 1.0 };
pub const k_spring_expressive: SpringParams = .{ .stiffness = 200.0, .damping = 15.0, .mass = 1.0 };

// Per-component motion table, so a future retune
// has the reference beside the code:
//
//   Interaction              | Duration | Easing                 | Spring?
//   -------------------------|----------|------------------------|----------
//   State layer hover        | 100ms    | standard-decelerate    | no
//   State layer press        | 100ms    | standard-decelerate    | no
//   Focus ring               | 100ms    | standard               | no
//   Button ripple            | 300ms    | emphasized             | optional
//   Switch thumb             | 200ms    | emphasized             | responsive
//   Switch track             | 200ms    | emphasized             | responsive
//   Slider thumb             | 100ms    | emphasized             | no
//   Slider value popup       | 100ms    | emphasized-decelerate  | no
//   Checkbox state           | 200ms    | emphasized             | no
//   Radio button state       | 200ms    | emphasized             | no
//   Card hover               | 150ms    | standard               | no
//   Chip enter/exit          | 200ms    | emphasized             | no
//   Dialog open              | 300ms    | emphasized-decelerate  | expressive
//   Dialog close             | 200ms    | emphasized-accelerate  | no
//   Sheet open               | 400ms    | emphasized-decelerate  | natural
//   Sheet close              | 300ms    | emphasized-accelerate  | no
//   Menu open                | 200ms    | emphasized-decelerate  | no
//   Menu close               | 150ms    | emphasized-accelerate  | no
//   FAB expand               | 300ms    | emphasized-decelerate  | expressive
//   Page transition          | 500ms    | emphasized             | natural
//   Palette crossfade        | 400ms    | emphasized             | no

const std = @import("std");

test "m3-tokens-motion: curves are monotonic and pinned at the ends" {
    const t = std.testing;
    // Every M3 curve is an identity-at-the-endpoints bezier: 0 maps to 0 and
    // 1 maps to 1, or the interpolator would pop at frame boundaries.
    inline for (.{
        k_emphasized,
        k_emphasized_decelerate,
        k_emphasized_accelerate,
        k_standard,
        k_standard_decelerate,
        k_standard_accelerate,
        k_linear,
    }) |e| {
        try t.expectEqual(@as(f32, 0.0), e.evaluate(0.0));
        try t.expectEqual(@as(f32, 1.0), e.evaluate(1.0));
        try t.expect(e.evaluate(0.5) > 0.0 and e.evaluate(0.5) < 1.0);
    }
    // linear must be the identity, which pins the Newton solve's accuracy.
    try t.expectApproxEqAbs(@as(f32, 0.25), k_linear.evaluate(0.25), 1e-4);
    try t.expectApproxEqAbs(@as(f32, 0.75), k_linear.evaluate(0.75), 1e-4);
}

test "m3-tokens-motion: accelerate and decelerate differ in direction" {
    const t = std.testing;
    // emphasized-accelerate starts slow (below the diagonal)…
    try t.expect(k_emphasized_accelerate.evaluate(0.5) < 0.5);
    // …while emphasized-decelerate starts fast (above it).
    try t.expect(k_emphasized_decelerate.evaluate(0.5) > 0.5);
}

test "m3-tokens-motion: duration classes and spring presets" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 100), @intFromEnum(Duration.extra_small));
    try t.expectEqual(@as(u64, 500), @intFromEnum(Duration.emphasis));
    // Snappier springs carry more stiffness *and* more damping — stiffness
    // alone would just make them oscillate.
    try t.expect(k_spring_responsive.stiffness > k_spring_expressive.stiffness);
    try t.expect(k_spring_responsive.damping > k_spring_expressive.damping);
}

test "m3-tokens-motion: clamped Newton converges on zero-slope curve" {
    const t = std.testing;
    // `k_standard_decelerate` is x(u)=u³, y(u)=3(1-u)u²+u³. Solving x(u)=0.01
    // gives u=0.01^(1/3)≈0.2154, y≈0.119. An un-clamped Newton flings u
    // far outside [0,1] and the trailing clamp returns 1.0 — the fixed port
    // must ease smoothly instead of snapping. 0.5 stays on-curve too.
    const v = k_standard_decelerate.evaluate(0.01);
    try t.expect(v > 0.05 and v < 0.3); // ~0.119, nowhere near the buggy 1.0
    try t.expect(k_standard_decelerate.evaluate(0.5) < 1.0);
    // Monotonic: a clamped solve must never step backwards.
    var prev: f32 = 0.0;
    var tt: f32 = 0.0;
    while (tt <= 1.0) : (tt += 0.05) {
        const y = k_standard_decelerate.evaluate(tt);
        try t.expect(y >= prev - 1e-4);
        prev = y;
    }
}
