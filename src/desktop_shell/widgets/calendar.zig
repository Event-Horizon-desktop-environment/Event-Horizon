//! The month grid the desktop calendar widget lays out: which dates sit in
//! which of the 42 cells. The underlying day arithmetic lives in
//! `calendar_math.zig` so the weather forecast's weekday labels use the same
//! rules.

const std = @import("std");
const math = @import("../../calendar_math.zig");

pub const isLeapYear = math.isLeapYear;
pub const daysInMonth = math.daysInMonth;
pub const weekday = math.weekday;

/// Six rows of seven dates, `0` where the previous or next month shows.
pub fn monthGrid(alloc: std.mem.Allocator, y: i32, m: u8) ![42]i8 {
    var grid: [42]i8 = [_]i8{0} ** 42;
    const dim = daysInMonth(y, m);
    const first = weekday(y, m, 1);
    var d: u8 = 1;
    var i: usize = first;
    while (d <= dim) : ({
        d += 1;
        i += 1;
    }) {
        grid[i] = @intCast(d);
    }
    _ = alloc;
    return grid;
}

test "calendar: leap, grid, weekday" {
    const t = std.testing;
    try t.expect(isLeapYear(2024));
    try t.expect(!isLeapYear(1900));
    try t.expect(isLeapYear(2000));
    try t.expectEqual(@as(u8, 29), daysInMonth(2024, 2));
    try t.expectEqual(@as(u8, 3), weekday(2026, 9, 30));
    const g = try monthGrid(t.allocator, 2026, 9);
    try t.expectEqual(@as(i8, 1), g[2]);
}
