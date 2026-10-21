//! The local wall clock as a plain date, without pulling the C library's
//! `tm` through every caller. Anything that needs "what day is it" — the
//! calendar card, a date-formatted clock — reads it here.

const std = @import("std");
const linux = std.os.linux;

/// The C `struct tm` fields the date conversion needs. Only the ones this
/// module reads are modelled; the rest stay zero.
const CTm = extern struct {
    tm_sec: c_int = 0,
    tm_min: c_int = 0,
    tm_hour: c_int = 0,
    tm_mday: c_int = 0,
    /// 0=Jan.
    tm_mon: c_int = 0,
    /// Years since 1900.
    tm_year: c_int = 0,
    tm_wday: c_int = 0,
    tm_yday: c_int = 0,
    tm_isdst: c_int = 0,
    tm_gmtoff: c_long = 0,
    tm_zone: ?[*:0]const u8 = null,
};

extern fn localtime_r(t: [*c]const i64, out: *CTm) ?*CTm;

/// One calendar day. `month` is 1-based, matching every other month number
/// in the shell's config.
pub const Date = struct {
    year: i32 = 1970,
    month: u8 = 1,
    day: u8 = 1,

    pub fn eql(a: Date, b: Date) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }
};

/// The machine's current local date, or 1970-01-01 when the clock cannot be
/// read — a wrong date on a calendar is bad, a panicked shell is worse.
pub fn today() Date {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.REALTIME, &ts) != 0) return .{};
    const t: i64 = @intCast(ts.sec);
    var out: CTm = undefined;
    if (localtime_r(&t, &out) == null) return .{};
    return .{
        .year = 1900 + @as(i32, @intCast(out.tm_year)),
        .month = @intCast(std.math.clamp(@as(i32, out.tm_mon) + 1, 1, 12)),
        .day = @intCast(std.math.clamp(@as(i32, out.tm_mday), 1, 31)),
    };
}

test "local-time: today is a sane calendar date" {
    const t = std.testing;
    const d = today();
    try t.expect(d.year >= 2020);
    try t.expect(d.month >= 1 and d.month <= 12);
    try t.expect(d.day >= 1 and d.day <= 31);
}

test "local-time: equality is all three fields" {
    const t = std.testing;
    const a = Date{ .year = 2026, .month = 10, .day = 7 };
    const b = Date{ .year = 2026, .month = 10, .day = 7 };
    try t.expect(a.eql(b));
    try t.expect(!a.eql(.{ .year = 2026, .month = 10, .day = 8 }));
    try t.expect(!a.eql(.{ .year = 2025, .month = 10, .day = 7 }));
}
