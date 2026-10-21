const std = @import("std");

fn two(alloc: std.mem.Allocator, v: u8) ![]u8 {
    if (v < 10) return std.fmt.allocPrint(alloc, "0{d}", .{v});
    return std.fmt.allocPrint(alloc, "{d}", .{v});
}

const kDays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const kMonths = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// The three date layouts. Unrecognised config values fall through to
/// `.weekday_day`, which is the `default:` arm there.
pub const DateStyle = enum { weekday_day, full, iso };

/// `wday` is 0=Sun, `mon` is 0=Jan, `year` is the full year (2026).
pub fn formatDate(
    alloc: std.mem.Allocator,
    wday: u8,
    mday: u8,
    mon: u8,
    year: i32,
    style: DateStyle,
) ![]u8 {
    const day = if (wday < kDays.len) kDays[wday] else "";
    const month = if (mon < kMonths.len) kMonths[mon] else "";
    return switch (style) {
        .weekday_day => std.fmt.allocPrint(alloc, "{s} {d}", .{ day, mday }),
        .full => std.fmt.allocPrint(alloc, "{s} {d} {s} {d}", .{ day, mday, month, year }),
        .iso => blk: {
            const mo = try two(alloc, mon +% 1);
            defer alloc.free(mo);
            const dd = try two(alloc, mday);
            defer alloc.free(dd);
            break :blk try std.fmt.allocPrint(alloc, "{d}-{s}-{s}", .{ year, mo, dd });
        },
    };
}

pub fn dateStyle(date_format: i32) DateStyle {
    return switch (date_format) {
        1 => .full,
        2 => .iso,
        else => .weekday_day,
    };
}

pub fn formatTime(alloc: std.mem.Allocator, hour: u8, min: u8, sec: u8, use_24h: bool, show_seconds: bool) ![]u8 {
    if (use_24h) {
        const hh = try two(alloc, hour);
        defer alloc.free(hh);
        const mm = try two(alloc, min);
        defer alloc.free(mm);
        if (show_seconds) {
            const ss = try two(alloc, sec);
            defer alloc.free(ss);
            return std.fmt.allocPrint(alloc, "{s}:{s}:{s}", .{ hh, mm, ss });
        }
        return std.fmt.allocPrint(alloc, "{s}:{s}", .{ hh, mm });
    }
    const h12: u8 = if (hour % 12 == 0) 12 else hour % 12;
    const suffix: []const u8 = if (hour < 12) "AM" else "PM";
    const mm = try two(alloc, min);
    defer alloc.free(mm);
    if (show_seconds) {
        const ss = try two(alloc, sec);
        defer alloc.free(ss);
        return std.fmt.allocPrint(alloc, "{d}:{s}:{s} {s}", .{ h12, mm, ss, suffix });
    }
    return std.fmt.allocPrint(alloc, "{d}:{s} {s}", .{ h12, mm, suffix });
}

test "clock: 12/24h formats" {
    const t = std.testing;
    const a = try formatTime(t.allocator, 14, 5, 9, true, false);
    defer t.allocator.free(a);
    try t.expectEqualStrings("14:05", a);
    const b = try formatTime(t.allocator, 14, 5, 9, false, true);
    defer t.allocator.free(b);
    try t.expectEqualStrings("2:05:09 PM", b);
    const c = try formatTime(t.allocator, 0, 0, 0, false, false);
    defer t.allocator.free(c);
    try t.expectEqualStrings("12:00 AM", c);
}

test "clock: date styles match append_date_formatted" {
    const t = std.testing;
    // 2026-10-07 is a Wednesday: wday=3, mday=7, mon=9.
    const a = try formatDate(t.allocator, 3, 7, 9, 2026, .weekday_day);
    defer t.allocator.free(a);
    try t.expectEqualStrings("Wed 7", a);

    const b = try formatDate(t.allocator, 3, 7, 9, 2026, .full);
    defer t.allocator.free(b);
    try t.expectEqualStrings("Wed 7 Oct 2026", b);

    const c = try formatDate(t.allocator, 3, 7, 9, 2026, .iso);
    defer t.allocator.free(c);
    try t.expectEqualStrings("2026-10-07", c);

    // Single-digit day pads; January rolls to month index 12 via +%1.
    const d = try formatDate(t.allocator, 4, 5, 0, 2026, .iso);
    defer t.allocator.free(d);
    try t.expectEqualStrings("2026-01-05", d);

    try t.expectEqual(DateStyle.weekday_day, dateStyle(0));
    try t.expectEqual(DateStyle.full, dateStyle(1));
    try t.expectEqual(DateStyle.iso, dateStyle(2));
    try t.expectEqual(DateStyle.weekday_day, dateStyle(99));
}
