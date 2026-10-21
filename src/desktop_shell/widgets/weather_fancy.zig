const std = @import("std");

pub const Hour = struct {
    hour: u8,
    temp_c: f64,
    icon: []const u8 = "",
};

pub fn dayRange(hours: []const Hour) struct { hi: f64, lo: f64 } {
    var hi: f64 = -1000;
    var lo: f64 = 1000;
    for (hours) |h| {
        hi = @max(hi, h.temp_c);
        lo = @min(lo, h.temp_c);
    }
    if (hours.len == 0) {
        hi = 0;
        lo = 0;
    }
    return .{ .hi = hi, .lo = lo };
}

pub fn sparkChar(temp: f64, lo: f64, hi: f64) u8 {
    if (hi <= lo) return '-';
    const f = (temp - lo) / (hi - lo);
    if (f < 0.2) return '_';
    if (f < 0.4) return '.';
    if (f < 0.6) return '-';
    if (f < 0.8) return '=';
    return '#';
}

test "weather-fancy: range + spark" {
    const t = std.testing;
    const hs = [_]Hour{ .{ .hour = 0, .temp_c = 10 }, .{ .hour = 12, .temp_c = 22 } };
    const r = dayRange(&hs);
    try t.expectEqual(@as(f64, 22.0), r.hi);
    try t.expectEqual(@as(u8, '_'), sparkChar(10, 10, 22));
    try t.expectEqual(@as(u8, '#'), sparkChar(22, 10, 22));
}
