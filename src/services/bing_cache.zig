const std = @import("std");

pub const DayEntry = struct {
    date: []const u8,
    url: []const u8,
};

pub fn isCacheFresh(today: []const u8, cached_date: []const u8, max_age_days: u32) bool {
    if (today.len < 10 or cached_date.len < 10) return false;
    const ty = std.fmt.parseInt(u32, today[0..4], 10) catch return false;
    const tm = std.fmt.parseInt(u32, today[5..7], 10) catch return false;
    const td = std.fmt.parseInt(u32, today[8..10], 10) catch return false;
    const cy = std.fmt.parseInt(u32, cached_date[0..4], 10) catch return false;
    const cm = std.fmt.parseInt(u32, cached_date[5..7], 10) catch return false;
    const cd = std.fmt.parseInt(u32, cached_date[8..10], 10) catch return false;
    const now_days = ty * 372 + tm * 31 + td;
    const then_days = cy * 372 + cm * 31 + cd;
    if (now_days < then_days) return false;
    return now_days - then_days <= max_age_days;
}

test "bing-cache: freshness windows" {
    const t = std.testing;
    try t.expect(isCacheFresh("2026-10-07", "2026-10-07", 1));
    try t.expect(isCacheFresh("2026-10-07", "2026-10-06", 1));
    try t.expect(!isCacheFresh("2026-10-07", "2026-10-01", 1));
    try t.expect(!isCacheFresh("bogus", "2026-10-07", 7));
}
