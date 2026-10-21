const std = @import("std");

pub const bars: usize = 24;

pub fn smooth(prev: f32, target: f32, attack: f32, release: f32) f32 {
    if (target > prev) {
        return prev + (target - prev) * attack;
    }
    return prev + (target - prev) * release;
}

pub fn normalizeLevel(v: f32, min_db: f32, max_db: f32) f32 {
    if (v <= 0) return 0;
    const db = 20.0 * std.math.log10(v);
    return @max(0.0, @min(1.0, (db - min_db) / (max_db - min_db)));
}

test "cava: smooth + normalize" {
    const t = std.testing;
    try t.expect(smooth(0.0, 1.0, 0.5, 0.1) > 0.4);
    try t.expect(smooth(1.0, 0.0, 0.5, 0.1) < 1.0);
    try t.expectEqual(@as(f32, 0.0), normalizeLevel(0, -60, 0));
    try t.expect(normalizeLevel(1.0, -60, 0) > 0.99);
}
