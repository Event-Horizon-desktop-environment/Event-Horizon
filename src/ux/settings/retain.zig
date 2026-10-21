const std = @import("std");

// Retained surfaces + logo + trace — Zig port of
// src/ux/settings/common/retain/retained_surface.hpp,
// src/ux/settings/common/logo/settings_logo.*, and
// src/ux/settings/common/trace/settings_trace.hpp.
// Same design: thumb LRU cache, static logo path, trace spans.

pub const max_retained: usize = 32;

pub const RetainedCache = struct {
    count: usize = 0,
    hits: u64 = 0,
    misses: u64 = 0,

    pub fn lookup(self: *RetainedCache, found: bool) void {
        if (found) {
            self.hits += 1;
        } else {
            self.misses += 1;
            if (self.count < max_retained) self.count += 1;
        }
    }

    pub fn hitRate(self: *const RetainedCache) f64 {
        const total: f64 = @floatFromInt(self.hits + self.misses);
        if (total == 0) return 1.0;
        return @as(f64, @floatFromInt(self.hits)) / total;
    }
};

pub const logo_rel_path: []const u8 = "src/Resources/Event-Horizon-logo.png";

pub const TraceSpan = struct {
    name: []const u8,
    start_ms: u64 = 0,
    end_ms: u64 = 0,

    pub fn elapsedMs(self: *const TraceSpan) u64 {
        return self.end_ms -% self.start_ms;
    }
};

test "settings-retain-logo-trace: cache + spans" {
    const t = std.testing;
    var c = RetainedCache{};
    c.lookup(true);
    c.lookup(false);
    try t.expectApproxEqAbs(@as(f64, 0.5), c.hitRate(), 1e-9);
    const s = TraceSpan{ .name = "paint", .start_ms = 10, .end_ms = 25 };
    try t.expectEqual(@as(u64, 15), s.elapsedMs());
    try t.expectEqualStrings("src/Resources/Event-Horizon-logo.png", logo_rel_path);
}
