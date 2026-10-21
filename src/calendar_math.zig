//! Proleptic-Gregorian day arithmetic with no host and no clock: leap years,
//! month lengths and the day of a week a date falls on. The calendar card,
//! the weather forecast's weekday labels and anything else that needs "which
//! day was that" reads it here so the three cannot disagree.

const std = @import("std");

pub fn isLeapYear(y: i32) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

pub fn daysInMonth(y: i32, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(y)) 29 else 28,
        else => 0,
    };
}

/// 0=Sunday, matching C `tm_wday`.
pub fn weekday(y: i32, m: u8, d: u8) u8 {
    var yy = y;
    var mm: i32 = m;
    if (mm < 3) {
        mm += 12;
        yy -= 1;
    }
    const k: i32 = @mod(yy, 100);
    const j: i32 = @divTrunc(yy, 100);
    const h = @mod(d + @divTrunc(13 * (mm + 1), 5) + k + @divTrunc(k, 4) + @divTrunc(j, 4) + 5 * j, 7);
    return @intCast(@mod(h + 6, 7));
}

test "calendar-math: leap years" {
    const t = std.testing;
    try t.expect(isLeapYear(2024));
    try t.expect(!isLeapYear(1900));
    try t.expect(isLeapYear(2000));
    try t.expectEqual(@as(u8, 29), daysInMonth(2024, 2));
    try t.expectEqual(@as(u8, 28), daysInMonth(1900, 2));
    try t.expectEqual(@as(u8, 31), daysInMonth(2026, 1));
    try t.expectEqual(@as(u8, 30), daysInMonth(2026, 9));
    try t.expectEqual(@as(u8, 0), daysInMonth(2026, 0));
}

test "calendar-math: weekdays are 0=Sunday and advance by one" {
    const t = std.testing;
    try t.expectEqual(@as(u8, 4), weekday(1970, 1, 1));
    try t.expectEqual(@as(u8, 3), weekday(2026, 9, 30));
    // Every consecutive pair differs by exactly one, wrapping 6 -> 0.
    var y: i32 = 2024;
    while (y <= 2027) : (y += 1) {
        var m: u8 = 1;
        while (m <= 12) : (m += 1) {
            var d: u8 = 1;
            const dim = daysInMonth(y, m);
            while (d < dim) : (d += 1) {
                const a = weekday(y, m, d);
                const b = weekday(y, m, d + 1);
                try t.expect(b == (if (a == 6) @as(u8, 0) else a + 1));
            }
        }
    }
}
