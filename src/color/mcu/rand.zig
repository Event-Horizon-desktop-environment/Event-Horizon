//! glibc `srand`/`rand` (TYPE_3 additive-feedback generator), reimplemented
//! exactly so `quantize` draws the same sequence for `wsmeans`
//! (`srand(42688)` + `rand()`), which seeds cluster assignment.
//!
//! Verified two ways: the construction below was derived from disassembling
//! the system libc (`fill = degree = 31 words via Schrage, fptr = state+3,
//! 310 warm-up discards, unsigned add with the top bit chucked`), and the
//! test cross-checks the first outputs against the real libc at test time.

const std = @import("std");

pub const rand_max: f64 = 2147483647.0;

pub const Rand31 = struct {
    state: [32]i32 = [_]i32{0} ** 32,
    f: usize = 3,
    r: usize = 0,

    const degree: usize = 31;
    const sep: usize = 3;

    pub fn seed(s: u32) Rand31 {
        var g = Rand31{};
        var word: i32 = @bitCast(s);
        if (word == 0) word = 1;
        g.state[0] = word;
        for (1..degree) |i| {
            const hi: i64 = @divTrunc(@as(i64, word), 127773);
            const lo: i64 = @mod(@as(i64, word), 127773);
            word = @intCast(16807 * lo - 2836 * hi);
            if (word < 0) word += 2147483647;
            g.state[i] = word;
        }
        g.f = sep;
        g.r = 0;
        for (0..10 * degree) |_| _ = g.next();
        return g;
    }

    pub fn next(self: *Rand31) i32 {
        self.state[self.f] +%= self.state[self.r];
        const v: u32 = @bitCast(self.state[self.f]);
        self.f += 1;
        if (self.f >= degree) {
            self.f = 0;
            self.r += 1;
        } else {
            self.r += 1;
            if (self.r >= degree) self.r = 0;
        }
        return @intCast(v >> 1);
    }

    /// `rand() / RAND_MAX`, exactly as `wsmeans.cc` scales it.
    pub fn nextUnit(self: *Rand31) f64 {
        return @as(f64, @floatFromInt(self.next())) / rand_max;
    }
};

extern fn srand(seed: c_uint) void;
extern fn rand() c_int;

test "mcu-rand: sequence matches the platform libc" {
    const t = std.testing;
    // Apart from locking the algorithm, this guards the case where a
    // different libc ever changes `rand()` out from under the port.
    for ([_]u32{ 42688, 1, 0, 123456789 }) |s| {
        var g = Rand31.seed(s);
        srand(s);
        for (0..64) |_| {
            try t.expectEqual(@as(i32, rand()), g.next());
        }
    }
}
