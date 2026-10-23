//! Array-repetition helpers shared by code that must build on Zig 0.16 and
//! 0.17. Zig 0.17 removed `value ** count`; `@splat` replaces it for scalar
//! and aggregate elements, but it cannot flatten a multi-element unit.

const std = @import("std");

/// Repeat `unit` until `count` bytes are produced. `count` must be a multiple
/// of `unit.len`; the result is a flat array, matching the removed `**`
/// behaviour for byte patterns such as RGBA pixels.
pub fn repeatBytes(comptime count: usize, comptime unit: []const u8) [count]u8 {
    @setEvalBranchQuota(100_000);
    comptime std.debug.assert(unit.len > 0);
    comptime std.debug.assert(count % unit.len == 0);
    var out: [count]u8 = undefined;
    inline for (0..count) |i| {
        out[i] = unit[i % unit.len];
    }
    return out;
}
