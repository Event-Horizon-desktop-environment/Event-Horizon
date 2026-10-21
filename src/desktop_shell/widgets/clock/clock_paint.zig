//! Dock clock slot:
//! one pill with the time and optional date, per-instance settings overrides,
//! and a per-second (or per-minute) tick.
//!
//! What could not come across verbatim, and why:
//!
//! * **Timezone resolution.** A configured IANA
//!   timezone through the system tz database. Zig's standard library has no
//!   tz database, so `resolveTime` handles exactly what is resolvable
//!   without one: an empty zone means `localtime_r` (the common case) and
//!   the zero-offset names (`UTC`, `GMT`, `Etc/UTC`, `Etc/GMT` — the same
//!   list `world_clock_paint.zig` uses) mean `gmtime_r`. Any other name falls
//!   back to local time, which is also the fallback when zone lookup fails.
//! * **Arbitrary `strftime` formats.** The custom-`format` path is real, but
//!   it goes through the small `renderCustom` conversion table below
//!   instead of libc: the directives the shell's own configs use
//!   (`%a %A %w %d %e %b %B %h %m %y %Y %H %I %M %S %p %R %T %F %D %x %X
//!   `%c %j %u %U %W %C %z %Z %%`) render exactly; anything else passes
//!   through literally (`%q` stays `%q`), the way glibc leaves unknown
//!   conversions alone. `%Z` reads the zone abbreviation out of the
//!   `tm_zone` glibc keeps in `struct tm` (empty when libc has none), and
//!   `%z` formats `tm_gmtoff` as `±HHMM`.
//! * **The static line cache.** An unbounded
//!   `unordered_map<instance:tick, lines>` and evicts every entry whose tick
//!   is stale once it holds more than four. `Cache` below is that map with
//!   the same eviction rule, bounded and owning its strings.
//! * **The `ClockLayoutCache`.** Folded into the shared `layout_cache.zig`
//!   plus a small per-instance sizes entry, the same split
//!   `battery_paint.zig` uses — the paint below reads through both.
//!
//! The time/date tables themselves are not duplicated here:
//! `formatTime`/`formatDate`/`dateStyle` already live in
//! `desktop/clock.zig`, which documents the `append_date_formatted` arms.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const schema = @import("../../../config/schema.zig");
const pill = @import("../shared/pill.zig");
const wset = @import("../shared/widget_settings.zig");
const lcache = @import("../shared/layout_cache.zig");
const measure = @import("../shared/measure_scratch.zig");
const dock_widgets = @import("../../dock/widgets.zig");
const clock_fmt = @import("../../desktop/clock.zig");

/// `struct tm` from <time.h>, laid out for glibc on Linux — the same block
/// `world_clock_paint.zig` and `bin/dock.zig` declare.
const CTm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: [*:0]const u8,
};

extern fn localtime_r(t: [*c]const i64, out: *CTm) ?*CTm;
extern fn gmtime_r(t: [*c]const i64, out: *CTm) ?*CTm;

/// Wall-clock seconds —
/// the same `clock_gettime(CLOCK_REALTIME)` the dock already uses.
pub fn nowSeconds() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @intCast(ts.sec);
}

/// The zone names whose UTC offset is zero by definition — the same list
/// `world_clock_paint.zig` uses.
fn isUtcName(tz: []const u8) bool {
    if (std.mem.eql(u8, tz, "UTC")) return true;
    if (std.mem.eql(u8, tz, "Etc/UTC")) return true;
    if (std.mem.eql(u8, tz, "GMT")) return true;
    if (std.mem.eql(u8, tz, "Etc/GMT")) return true;
    return false;
}

/// Broken-down wall time plus the zone fields `%z`/`%Z` need. All fields
/// are clamped the way `localTime()` in `bin/dock.zig` clamps them so a
/// malformed `tm` can never reach an `@intCast`.
pub const BrokenTime = struct {
    year: i32 = 1970,
    /// 0-based month, like `tm_mon`.
    mon: u8 = 0,
    /// 1-based day of month.
    mday: u8 = 1,
    /// 0=Sun.
    wday: u8 = 0,
    hour: u8 = 0,
    min: u8 = 0,
    sec: u8 = 0,
    /// Seconds east of UTC, from `tm_gmtoff` (0 when libc has none).
    gmtoff_sec: i64 = 0,
    zone: [16]u8 = [_]u8{0} ** 16,
    zone_len: usize = 0,

    pub fn zoneName(self: *const BrokenTime) []const u8 {
        return self.zone[0..self.zone_len];
    }
};

fn brokenFromTm(tm: CTm) BrokenTime {
    const cl = std.math.clamp;
    var out = BrokenTime{
        .year = 1900 + @as(i32, tm.tm_year),
        .mon = @intCast(cl(@as(i32, tm.tm_mon), 0, 11)),
        .mday = @intCast(cl(@as(i32, tm.tm_mday), 1, 31)),
        .wday = @intCast(cl(@as(i32, tm.tm_wday), 0, 6)),
        .hour = @intCast(cl(@as(i32, tm.tm_hour), 0, 23)),
        .min = @intCast(cl(@as(i32, tm.tm_min), 0, 59)),
        .sec = @intCast(cl(@as(i32, tm.tm_sec), 0, 59)),
        .gmtoff_sec = @intCast(tm.tm_gmtoff),
    };
    const z = std.mem.span(tm.tm_zone);
    const n = @min(z.len, out.zone.len);
    @memcpy(out.zone[0..n], z[0..n]);
    out.zone_len = n;
    return out;
}

/// `safe_localtime` — `localtime_r` for the empty zone, `gmtime_r` for the
/// zero-offset names, local time for anything else (see the module doc).
/// Null when libc refuses the date.
pub fn resolveTime(now_sec: i64, timezone: []const u8) ?BrokenTime {
    var ts = now_sec;
    var tm: CTm = undefined;
    if (timezone.len == 0) {
        if (localtime_r(&ts, &tm) == null) return null;
        return brokenFromTm(tm);
    }
    if (isUtcName(timezone)) {
        if (gmtime_r(&ts, &tm) == null) return null;
        return brokenFromTm(tm);
    }
    if (localtime_r(&ts, &tm) == null) return null;
    return brokenFromTm(tm);
}

/// The `format_clock_lines` inputs: per-instance overrides already resolved
/// against `sc.time`.
pub const Options = struct {
    show_seconds: bool = false,
    use_24h: bool = false,
    compact: bool = false,
    show_date: bool = true,
    date_format: i32 = 0,
    custom_format: []const u8 = "",
};

/// Reads the clock options for one widget instance: each `widget_setting`
/// wins over the matching `sc.time` field, absent or malformed values fall
/// back — `date_format` clamps to `[0, 3]`.
pub fn optionsFor(sc: *const schema.ShellConfig, instance_id: []const u8) Options {
    return .{
        .show_seconds = wset.settingBool(sc, instance_id, "show_seconds", sc.time.show_seconds),
        .use_24h = wset.settingBool(sc, instance_id, "use_24h", sc.time.use_24h),
        .compact = wset.settingBool(sc, instance_id, "compact", false),
        .show_date = wset.settingBool(sc, instance_id, "show_date", sc.time.show_date),
        .date_format = @intCast(wset.settingInt(sc, instance_id, "date_format", 0, 3, sc.time.date_format)),
        .custom_format = blk: {
            const per = wset.widgetSetting(sc, instance_id, "format");
            break :blk if (per.len > 0) per else sc.time.custom_format;
        },
    };
}

/// The four standard formats recognised and then *ignored*: a custom
/// format equal to one of these takes the standard path instead.
fn isStdFormat(s: []const u8) bool {
    if (std.mem.eql(u8, s, "%H:%M")) return true;
    if (std.mem.eql(u8, s, "%H:%M:%S")) return true;
    if (std.mem.eql(u8, s, "%I:%M %p")) return true;
    if (std.mem.eql(u8, s, "%I:%M:%S %p")) return true;
    return false;
}

fn twoDigits(buf: *[2]u8, v: u8) []const u8 {
    buf[0] = '0' + v / 10;
    buf[1] = '0' + v % 10;
    return buf[0..2];
}

/// Leap years in the proleptic Gregorian calendar, for `%j`/`%U`/`%W`.
fn isLeapYear(year: i32) bool {
    if (@rem(year, 400) == 0) return true;
    if (@rem(year, 100) == 0) return false;
    return @rem(year, 4) == 0;
}

/// 0-based day of year, from month lengths — what `tm_yday` carries.
fn dayOfYear(tm: BrokenTime) i32 {
    const lens = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var yday: i32 = tm.mday - 1;
    for (lens[0..tm.mon]) |l| yday += l;
    if (tm.mon >= 2 and isLeapYear(tm.year)) yday += 1;
    return yday;
}

/// `%U` — week number, Sunday-first: days before the first Sunday are 00.
fn weekSun(tm: BrokenTime) i32 {
    return @divFloor(dayOfYear(tm) - @as(i32, tm.wday) + 7, 7);
}

/// `%W` — week number, Monday-first.
fn weekMon(tm: BrokenTime) i32 {
    const mon_wday: i32 = @mod(@as(i32, tm.wday) + 6, 7);
    return @divFloor(dayOfYear(tm) - mon_wday + 7, 7);
}

/// One `strftime` conversion from the supported table (see the module doc).
/// Unknown conversions pass through literally. Everything appends into
/// `out`; numbers never allocate.
fn renderDirective(out: *std.ArrayList(u8), alloc: std.mem.Allocator, tm: BrokenTime, c: u8) !void {
    var num: [16]u8 = undefined;
    var two: [2]u8 = undefined;
    switch (c) {
        'a', 'A', 'w' => {
            const days_short = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
            const days_long = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
            if (c == 'w') {
                try out.appendSlice(alloc, try std.fmt.bufPrint(&num, "{d}", .{tm.wday}));
            } else if (c == 'a') {
                try out.appendSlice(alloc, days_short[tm.wday]);
            } else {
                try out.appendSlice(alloc, days_long[tm.wday]);
            }
        },
        'd' => try out.appendSlice(alloc, twoDigits(&two, tm.mday)),
        'e' => try out.appendSlice(alloc, try std.fmt.bufPrint(&num, "{d:2}", .{tm.mday})),
        'b', 'h' => {
            const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            try out.appendSlice(alloc, months[tm.mon]);
        },
        'B' => {
            const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
            try out.appendSlice(alloc, months[tm.mon]);
        },
        'm' => try out.appendSlice(alloc, twoDigits(&two, tm.mon + 1)),
        'y' => try out.appendSlice(alloc, twoDigits(&two, @intCast(@rem(tm.year, 100)))),
        'Y' => try out.appendSlice(alloc, try std.fmt.bufPrint(&num, "{d}", .{tm.year})),
        'C' => try out.appendSlice(alloc, try std.fmt.bufPrint(&num, "{d}", .{@divFloor(tm.year, 100)})),
        'H' => try out.appendSlice(alloc, twoDigits(&two, tm.hour)),
        'I' => {
            const h12: u8 = if (tm.hour % 12 == 0) 12 else tm.hour % 12;
            try out.appendSlice(alloc, twoDigits(&two, h12));
        },
        'M' => try out.appendSlice(alloc, twoDigits(&two, tm.min)),
        'S' => try out.appendSlice(alloc, twoDigits(&two, tm.sec)),
        'p' => try out.appendSlice(alloc, if (tm.hour < 12) "AM" else "PM"),
        'R' => {
            try out.appendSlice(alloc, twoDigits(&two, tm.hour));
            try out.append(alloc, ':');
            try out.appendSlice(alloc, twoDigits(&two, tm.min));
        },
        'T' => {
            try out.appendSlice(alloc, twoDigits(&two, tm.hour));
            try out.append(alloc, ':');
            try out.appendSlice(alloc, twoDigits(&two, tm.min));
            try out.append(alloc, ':');
            try out.appendSlice(alloc, twoDigits(&two, tm.sec));
        },
        'F' => {
            try out.appendSlice(alloc, try std.fmt.bufPrint(&num, "{d}-", .{tm.year}));
            try out.appendSlice(alloc, twoDigits(&two, tm.mon + 1));
            try out.append(alloc, '-');
            try out.appendSlice(alloc, twoDigits(&two, tm.mday));
        },
        'D' => {
            try out.appendSlice(alloc, twoDigits(&two, tm.mon + 1));
            try out.append(alloc, '/');
            try out.appendSlice(alloc, twoDigits(&two, tm.mday));
            try out.append(alloc, '/');
            try out.appendSlice(alloc, twoDigits(&two, @intCast(@rem(tm.year, 100))));
        },
        'x' => {
            try out.appendSlice(alloc, twoDigits(&two, tm.mon + 1));
            try out.append(alloc, '/');
            try out.appendSlice(alloc, twoDigits(&two, tm.mday));
            try out.append(alloc, '/');
            try out.appendSlice(alloc, try std.fmt.bufPrint(&num, "{d}", .{tm.year}));
        },
        'X' => {
            try out.appendSlice(alloc, twoDigits(&two, tm.hour));
            try out.append(alloc, ':');
            try out.appendSlice(alloc, twoDigits(&two, tm.min));
            try out.append(alloc, ':');
            try out.appendSlice(alloc, twoDigits(&two, tm.sec));
        },
        'c' => {
            const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            const days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
            try out.appendSlice(alloc, days[tm.wday]);
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, months[tm.mon]);
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, try std.fmt.bufPrint(&num, "{d:2}", .{tm.mday}));
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, twoDigits(&two, tm.hour));
            try out.append(alloc, ':');
            try out.appendSlice(alloc, twoDigits(&two, tm.min));
            try out.append(alloc, ':');
            try out.appendSlice(alloc, twoDigits(&two, tm.sec));
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, try std.fmt.bufPrint(&num, "{d}", .{tm.year}));
        },
        'j' => {
            const doy: i64 = dayOfYear(tm) + 1;
            var jbuf: [3]u8 = undefined;
            jbuf[0] = '0' + @as(u8, @intCast(@divTrunc(doy, 100)));
            jbuf[1] = '0' + @as(u8, @intCast(@divTrunc(@mod(doy, 100), 10)));
            jbuf[2] = '0' + @as(u8, @intCast(@mod(doy, 10)));
            try out.appendSlice(alloc, &jbuf);
        },
        'u' => try out.appendSlice(alloc, try std.fmt.bufPrint(&num, "{d}", .{if (tm.wday == 0) @as(u8, 7) else tm.wday})),
        'U' => {
            const w: u8 = @intCast(@min(@max(weekSun(tm), 0), 99));
            try out.appendSlice(alloc, twoDigits(&two, w));
        },
        'W' => {
            const w: u8 = @intCast(@min(@max(weekMon(tm), 0), 99));
            try out.appendSlice(alloc, twoDigits(&two, w));
        },
        'z' => {
            const off = tm.gmtoff_sec;
            var zbuf: [5]u8 = undefined;
            zbuf[0] = if (off < 0) '-' else '+';
            const mag: i64 = if (off < 0) -off else off;
            const hh: u8 = @intCast(@min(@divTrunc(mag, 3600), 99));
            const mm: u8 = @intCast(@min(@divTrunc(@mod(mag, 3600), 60), 99));
            zbuf[1] = '0' + hh / 10;
            zbuf[2] = '0' + hh % 10;
            zbuf[3] = '0' + mm / 10;
            zbuf[4] = '0' + mm % 10;
            try out.appendSlice(alloc, &zbuf);
        },
        'Z' => try out.appendSlice(alloc, tm.zoneName()),
        '%' => try out.append(alloc, '%'),
        else => {
            // glibc leaves unknown conversions alone.
            try out.append(alloc, '%');
            try out.append(alloc, c);
        },
    }
}

/// Renders `fmt` the way `strftime` would for the supported table. A lone
/// trailing `%` is kept literally, as glibc keeps it.
pub fn renderCustom(alloc: std.mem.Allocator, tm: BrokenTime, fmt: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%' or i + 1 >= fmt.len) {
            try out.append(alloc, fmt[i]);
            i += 1;
            continue;
        }
        try renderDirective(&out, alloc, tm, fmt[i + 1]);
        i += 2;
    }
    return out.toOwnedSlice(alloc);
}

/// `format_clock_lines` without the clock or the cache: pure time in,
/// owned lines out. Branching order — custom format,
/// 24-hour, 12-hour with the `compact` single-line rule.
pub fn formatLines(alloc: std.mem.Allocator, tm: BrokenTime, opts: Options) ![][]u8 {
    var lines = std.ArrayList([]u8).empty;
    errdefer {
        for (lines.items) |l| alloc.free(l);
        lines.deinit(alloc);
    }
    const custom = if (isStdFormat(opts.custom_format)) "" else opts.custom_format;
    if (custom.len > 0) {
        try lines.append(alloc, try renderCustom(alloc, tm, custom));
        return lines.toOwnedSlice(alloc);
    }
    if (opts.use_24h) {
        const t = try clock_fmt.formatTime(alloc, tm.hour, tm.min, tm.sec, true, opts.show_seconds);
        errdefer alloc.free(t);
        if (opts.show_date and !opts.compact) {
            const d = try clock_fmt.formatDate(alloc, tm.wday, tm.mday, tm.mon, tm.year, clock_fmt.dateStyle(opts.date_format));
            defer alloc.free(d);
            const both = try std.fmt.allocPrint(alloc, "{s} {s}", .{ t, d });
            alloc.free(t);
            try lines.append(alloc, both);
        } else {
            try lines.append(alloc, t);
        }
        return lines.toOwnedSlice(alloc);
    }
    const t = try clock_fmt.formatTime(alloc, tm.hour, tm.min, tm.sec, false, opts.show_seconds);
    errdefer alloc.free(t);
    if (opts.compact or !opts.show_date) {
        try lines.append(alloc, t);
        return lines.toOwnedSlice(alloc);
    }
    const d = try clock_fmt.formatDate(alloc, tm.wday, tm.mday, tm.mon, tm.year, clock_fmt.dateStyle(opts.date_format));
    defer alloc.free(d);
    // U+00B7 MIDDLE DOT separator.
    const both = try std.fmt.allocPrint(alloc, "{s} \u{00b7} {s}", .{ t, d });
    alloc.free(t);
    try lines.append(alloc, both);
    return lines.toOwnedSlice(alloc);
}

pub fn freeLines(alloc: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |l| alloc.free(l);
    alloc.free(lines);
}

/// The 1 s vs 60 s granularity key: `now / granularity`.
pub fn tickKey(now_sec: i64, show_seconds: bool) i64 {
    return @divFloor(now_sec, if (show_seconds) @as(i64, 1) else @as(i64, 60));
}

/// `clock_tick_signature_changed` without the config: seconds-of-day when
/// seconds show, minutes-of-day otherwise.
pub fn tickSignature(tm: BrokenTime, show_seconds: bool) i32 {
    const h: i32 = tm.hour;
    const m: i32 = tm.min;
    if (show_seconds) return h * 3600 + m * 60 + @as(i32, tm.sec);
    return h * 60 + m;
}

/// Updates `*cached` and reports whether the visible tick moved.
pub fn tickSignatureChanged(cached: *i32, tm: BrokenTime, show_seconds: bool) bool {
    const sig = tickSignature(tm, show_seconds);
    if (sig == cached.*) return false;
    cached.* = sig;
    return true;
}

/// Tick-signature check: resolves the instance's time
/// itself (honouring its `show_seconds` and the configured timezone) and
/// reports whether the visible tick moved. False when libc refuses the
/// date.
pub fn tickSignatureChangedNow(cached: *i32, sc: *const schema.ShellConfig, instance_id: []const u8, now_sec: i64) bool {
    const show_seconds = wset.settingBool(sc, instance_id, "show_seconds", sc.time.show_seconds);
    const tm = resolveTime(now_sec, sc.time.timezone) orelse return false;
    return tickSignatureChanged(cached, tm, show_seconds);
}

// Tick cache (`s_cache`)

const CacheEntry = struct {
    instance: []u8,
    tick: i64,
    lines: [][]u8,
};

/// String cache keyed by
/// `instance:tick`, and once it holds more than four entries every entry
/// from an older tick is evicted. Returned slices are owned by the cache —
/// valid until the next call or `deinit`, never to be freed by the caller.
pub const Cache = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(CacheEntry) = .empty,

    pub fn init(alloc: std.mem.Allocator) Cache {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |*e| {
            self.alloc.free(e.instance);
            freeLines(self.alloc, e.lines);
        }
        self.entries.deinit(self.alloc);
    }

    pub fn reset(self: *Cache) void {
        for (self.entries.items) |*e| {
            self.alloc.free(e.instance);
            freeLines(self.alloc, e.lines);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Lines for one instance at `now_sec`, formatted with `opts`. A hit
    /// returns the stored slices; a miss formats, stores and returns.
    pub fn lines(self: *Cache, tm: BrokenTime, opts: Options, instance_id: []const u8, now_sec: i64) ![]const []u8 {
        const tick = tickKey(now_sec, opts.show_seconds);
        for (self.entries.items) |*e| {
            if (e.tick == tick and std.mem.eql(u8, e.instance, instance_id)) return e.lines;
        }
        if (self.entries.items.len > 4) {
            var kept: usize = 0;
            for (self.entries.items) |*e| {
                if (e.tick == tick) {
                    self.entries.items[kept] = e.*;
                    kept += 1;
                } else {
                    self.alloc.free(e.instance);
                    freeLines(self.alloc, e.lines);
                }
            }
            self.entries.shrinkRetainingCapacity(kept);
        }
        const fresh = try formatLines(self.alloc, tm, opts);
        errdefer freeLines(self.alloc, fresh);
        const owned_id = try self.alloc.dupe(u8, instance_id);
        errdefer self.alloc.free(owned_id);
        try self.entries.append(self.alloc, .{ .instance = owned_id, .tick = tick, .lines = fresh });
        return self.entries.items[self.entries.items.len - 1].lines;
    }
};

var g_cache: Cache = .{ .alloc = std.heap.page_allocator };
var g_cache_ready: bool = false;

fn sharedCache() *Cache {
    if (!g_cache_ready) {
        g_cache = Cache.init(std.heap.page_allocator);
        g_cache_ready = true;
    }
    return &g_cache;
}

/// Drops every module-level cache, kept for the life of the
/// process; `reset` exists for tests and for a host that wants a clean slate.
pub fn reset() void {
    if (g_cache_ready) g_cache.reset();
    if (g_sizes_ready) {
        var it = g_sizes.keyIterator();
        while (it.next()) |k| std.heap.page_allocator.free(k.*);
        g_sizes.clearRetainingCapacity();
    }
    if (g_layouts_ready) g_layouts.clear();
}

// Module caches (`g_clockLayoutCache`)

/// The measured half of one `ClockLayoutCache` entry: the joined-lines key,
/// the font size, and one width/height per line (growable; a
/// clock face never needs more than a handful of lines).
const Sizes = struct {
    key: [256]u8 = [_]u8{0} ** 256,
    key_len: usize = 0,
    font_px: i32 = 0,
    widths: [8]i32 = [_]i32{0} ** 8,
    heights: [8]i32 = [_]i32{0} ** 8,
    n: usize = 0,
    total_h: i32 = 0,
    max_w: i32 = 0,

    fn matches(self: *const Sizes, key: []const u8, font_px: i32) bool {
        return self.font_px == font_px and self.key_len == key.len and
            std.mem.eql(u8, self.key[0..self.key_len], key);
    }

    fn set(self: *Sizes, key: []const u8, font_px: i32) void {
        const nlen = @min(key.len, self.key.len);
        @memcpy(self.key[0..nlen], key[0..nlen]);
        self.key_len = nlen;
        self.font_px = font_px;
        self.n = 0;
        self.total_h = 0;
        self.max_w = 0;
    }
};

var g_sizes: std.StringHashMap(Sizes) = undefined;
var g_sizes_ready: bool = false;
var g_layouts: lcache.LayoutCache = undefined;
var g_layouts_ready: bool = false;

fn sizesMap() *std.StringHashMap(Sizes) {
    if (!g_sizes_ready) {
        g_sizes = std.StringHashMap(Sizes).init(std.heap.page_allocator);
        g_sizes_ready = true;
    }
    return &g_sizes;
}

fn sizesFind(id: []const u8) ?*Sizes {
    if (!g_sizes_ready) return null;
    return g_sizes.getPtr(id);
}

fn sizesStore(id: []const u8, key: []const u8, font_px: i32) ?*Sizes {
    const m = sizesMap();
    if (m.getPtr(id)) |e| {
        e.set(key, font_px);
        return e;
    }
    const owned = std.heap.page_allocator.dupe(u8, id) catch return null;
    const gop = m.getOrPut(owned) catch {
        std.heap.page_allocator.free(owned);
        return null;
    };
    if (gop.found_existing) {
        std.heap.page_allocator.free(owned);
    } else {
        gop.key_ptr.* = owned;
    }
    gop.value_ptr.set(key, font_px);
    return gop.value_ptr;
}

fn layouts() *lcache.LayoutCache {
    if (!g_layouts_ready) {
        g_layouts = lcache.LayoutCache.init(std.heap.page_allocator);
        g_layouts_ready = true;
    }
    return &g_layouts;
}

/// `dock_ui_scale(sc.dock)` — the dock module owns the formula.
fn uiScale(sc: *const schema.ShellConfig) f64 {
    return dock_widgets.uiScale(sc);
}

/// `"Inter " + int(fontPx)`.
fn fontDesc(buf: *[32]u8, font_px: f64) []const u8 {
    return std.fmt.bufPrint(buf, "Inter {d}", .{@as(i32, @intFromFloat(font_px))}) catch unreachable;
}

fn joinKey(buf: *[256]u8, lines: []const []const u8) []const u8 {
    var n: usize = 0;
    for (lines) |ln| {
        for (ln) |c| {
            if (n >= buf.len) break;
            buf[n] = c;
            n += 1;
        }
        if (n >= buf.len) break;
        buf[n] = '\n';
        n += 1;
    }
    return buf[0..n];
}

// Public API

/// `widget_list_contains_clock` — does any id in `list` resolve to the
/// `clock` implementation?
pub fn widgetListContainsClock(sc: *const schema.ShellConfig, list: []const []const u8) bool {
    return wset.listContainsImpl(sc, list, "clock");
}

/// `dock_clock_slot_width` — `max(56, icon*2.4)` on an empty face, else the
/// widest line plus 10 px pads each side, clamped to
/// `[max(icon*1.25, 52), min(bar*6, 220)]`.
pub fn dockClockSlotWidth(
    measure_cr: ?*cairo.cairo_t,
    sc: *const schema.ShellConfig,
    instance_id: []const u8,
    icon_ref_px: f64,
    bar_height: f64,
) f64 {
    const mcr = measure_cr orelse measure.measureCr();
    const opts = optionsFor(sc, instance_id);
    const tm = resolveTime(nowSeconds(), sc.time.timezone) orelse return @max(56.0, icon_ref_px * 2.4);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const lines = formatLines(arena.allocator(), tm, opts) catch return @max(56.0, icon_ref_px * 2.4);
    if (lines.len == 0) return @max(56.0, icon_ref_px * 2.4);

    const font_px = std.math.clamp(icon_ref_px * 0.38, 11.0, 15.0);
    var fbuf: [32]u8 = undefined;
    const fd = fontDesc(&fbuf, font_px);
    var text_max_w: i32 = 0;
    {
        var l = text.Layout.createForCairo(mcr);
        defer l.destroy();
        l.setFont(fd);
        l.setWrap(text.WRAP_WORD_CHAR);
        for (lines) |ln| {
            l.setText(ln);
            const s = l.pixelSize();
            text_max_w = @max(text_max_w, s.w);
        }
    }
    const pad_x = 10.0;
    const min_w = @max(icon_ref_px * 1.25, 52.0);
    const max_cap = @min(bar_height * 6.0, 220.0);
    const inner: f64 = @as(f64, @floatFromInt(text_max_w)) + pad_x * 2.0;
    return std.math.clamp(inner, min_w, max_cap);
}

/// `paint_clock_slot` — pill plus the lines centred, the first of several
/// semibold. `hovered`/`pressed` are accepted and ignored
/// (the pill fill does not react to them).
pub fn paintClockSlot(
    cr: ?*cairo.cairo_t,
    sc: *const schema.ShellConfig,
    instance_id: []const u8,
    x: f64,
    y: f64,
    slot_w: f64,
    slot_h: f64,
    icon_ref_px: f64,
    hovered: bool,
    pressed: bool,
) void {
    _ = hovered;
    _ = pressed;
    const c = cr orelse return;
    const opts = optionsFor(sc, instance_id);
    const tm = resolveTime(nowSeconds(), sc.time.timezone) orelse return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const lines = formatLines(arena.allocator(), tm, opts) catch return;
    if (lines.len == 0) return;

    cairo.cairo_save(c);
    defer cairo.cairo_restore(c);
    pill.paintPill(c, x, y, slot_w, slot_h);

    const font_px = std.math.clamp(icon_ref_px * 0.38, 11.0, 15.0);
    var fbuf: [32]u8 = undefined;
    const fd = fontDesc(&fbuf, font_px);

    var kbuf: [256]u8 = undefined;
    const key = joinKey(&kbuf, lines);

    const found = sizesFind(instance_id);
    var lo = text.Layout{ .layout = layouts().get(c, fd, @intFromFloat(font_px), instance_id) };
    lo.setAlignment(text.ALIGN_LEFT);
    lo.setWrap(text.WRAP_WORD_CHAR);

    var entry: *Sizes = undefined;
    var cache_hit = false;
    if (found) |e| {
        if (e.matches(key, @intFromFloat(font_px))) {
            entry = e;
            cache_hit = true;
        }
    }
    if (!cache_hit) {
        entry = sizesStore(instance_id, key, @intFromFloat(font_px)) orelse return;
        for (lines) |ln| {
            if (entry.n >= entry.widths.len) break;
            lo.setText(ln);
            const s = lo.pixelSize();
            entry.widths[entry.n] = s.w;
            entry.heights[entry.n] = s.h;
            entry.total_h += s.h;
            entry.max_w = @max(entry.max_w, s.w);
            entry.n += 1;
        }
        if (lines.len > 1) entry.total_h += @intCast((lines.len - 1) * 2);
    }

    var ty = y + (slot_h - @as(f64, @floatFromInt(entry.total_h))) / 2.0;
    for (lines, 0..) |ln, i| {
        if (i >= entry.n) break;
        lo.setText(ln);
        if (i == 0 and lines.len > 1) {
            lo.setWeight(text.WEIGHT_SEMIBOLD);
        } else {
            lo.setWeight(null);
        }
        const lw: f64 = @floatFromInt(entry.widths[i]);
        const h: f64 = @floatFromInt(entry.heights[i]);
        cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 1.0);
        cairo.cairo_move_to(c, x + (slot_w - lw) * 0.5, ty);
        lo.show(c);
        ty += h + @as(f64, if (i + 1 < lines.len) 2.0 else 0.0);
    }
}

// Tests

fn testOptions() Options {
    return .{ .show_seconds = false, .use_24h = true, .compact = false, .show_date = true, .date_format = 0, .custom_format = "" };
}

fn testTm() BrokenTime {
    // Wed 2026-10-07 14:05:09 +02:00 (CEST).
    return .{ .year = 2026, .mon = 9, .mday = 7, .wday = 3, .hour = 14, .min = 5, .sec = 9, .gmtoff_sec = 7200, .zone = [_]u8{ 'C', 'E', 'S', 'T', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .zone_len = 4 };
}

test "clock-paint: 24h line with date" {
    const t = std.testing;
    const lines = try formatLines(t.allocator, testTm(), testOptions());
    defer freeLines(t.allocator, lines);
    try t.expectEqual(@as(usize, 1), lines.len);
    try t.expectEqualStrings("14:05 Wed 7", lines[0]);
}

test "clock-paint: 12h line joins with middle dot" {
    const t = std.testing;
    var o = testOptions();
    o.use_24h = false;
    const lines = try formatLines(t.allocator, testTm(), o);
    defer freeLines(t.allocator, lines);
    try t.expectEqual(@as(usize, 1), lines.len);
    try t.expectEqualStrings("2:05 PM \u{00b7} Wed 7", lines[0]);
}

test "clock-paint: compact drops the date" {
    const t = std.testing;
    var o = testOptions();
    o.compact = true;
    const lines = try formatLines(t.allocator, testTm(), o);
    defer freeLines(t.allocator, lines);
    try t.expectEqualStrings("14:05", lines[0]);
}

test "clock-paint: full and iso date styles" {
    const t = std.testing;
    var o = testOptions();
    o.date_format = 1;
    const full = try formatLines(t.allocator, testTm(), o);
    defer freeLines(t.allocator, full);
    try t.expectEqualStrings("14:05 Wed 7 Oct 2026", full[0]);
    o.date_format = 2;
    const iso = try formatLines(t.allocator, testTm(), o);
    defer freeLines(t.allocator, iso);
    try t.expectEqualStrings("14:05 2026-10-07", iso[0]);
}

test "clock-paint: custom strftime renders, std formats take the normal path" {
    const t = std.testing;
    var o = testOptions();
    o.custom_format = "%H:%M:%S %Z (%z)";
    const custom = try formatLines(t.allocator, testTm(), o);
    defer freeLines(t.allocator, custom);
    try t.expectEqualStrings("14:05:09 CEST (+0200)", custom[0]);

    // A custom format equal to a standard one is ignored (isStdFormat).
    o.custom_format = "%H:%M";
    const std1 = try formatLines(t.allocator, testTm(), o);
    defer freeLines(t.allocator, std1);
    try t.expectEqualStrings("14:05 Wed 7", std1[0]);

    // Unknown conversions pass through literally.
    o.custom_format = "%Q o'clock";
    const lit = try formatLines(t.allocator, testTm(), o);
    defer freeLines(t.allocator, lit);
    try t.expectEqualStrings("%Q o'clock", lit[0]);
}

test "clock-paint: tick key and signature granularity" {
    const t = std.testing;
    try t.expectEqual(@as(i64, 61), tickKey(61, true));
    try t.expectEqual(@as(i64, 1), tickKey(61, false));
    try t.expectEqual(@as(i64, 1), tickKey(119, false));
    const tm = testTm();
    try t.expectEqual(@as(i32, 14 * 3600 + 5 * 60 + 9), tickSignature(tm, true));
    try t.expectEqual(@as(i32, 14 * 60 + 5), tickSignature(tm, false));
    var cached: i32 = -1;
    try t.expect(tickSignatureChanged(&cached, tm, false));
    try t.expect(!tickSignatureChanged(&cached, tm, false));
    try t.expect(tickSignatureChanged(&cached, tm, true));
}

test "clock-paint: calendar week directives" {
    const t = std.testing;
    // Wed 2026-10-07: day 280 of a common year, week 40 either counting.
    const tm = testTm();
    try t.expect(isLeapYear(2024));
    try t.expect(!isLeapYear(2026));
    try t.expect(!isLeapYear(1900));
    try t.expect(isLeapYear(2000));
    try t.expectEqual(@as(i32, 279), dayOfYear(tm));
    try t.expectEqual(@as(i32, 40), weekSun(tm));
    try t.expectEqual(@as(i32, 40), weekMon(tm));
    // 2026-01-01 is a Thursday: week 00 on either counting (the first
    // Sunday is Jan 4, the first Monday Jan 5).
    const jan1 = BrokenTime{ .year = 2026, .mon = 0, .mday = 1, .wday = 4 };
    try t.expectEqual(@as(i32, 0), dayOfYear(jan1));
    try t.expectEqual(@as(i32, 0), weekSun(jan1));
    try t.expectEqual(@as(i32, 0), weekMon(jan1));

    var o = testOptions();
    o.custom_format = "%j %U %W %u %e";
    const got = try formatLines(t.allocator, tm, o);
    defer freeLines(t.allocator, got);
    try t.expectEqualStrings("280 40 40 3  7", got[0]);
}

test "clock-paint: compound and locale directives" {
    const t = std.testing;
    const tm = testTm();
    var o = testOptions();
    o.custom_format = "%R %T %F %D %C %y";
    const got = try formatLines(t.allocator, tm, o);
    defer freeLines(t.allocator, got);
    try t.expectEqualStrings("14:05 14:05:09 2026-10-07 10/07/26 20 26", got[0]);

    o.custom_format = "%x %X %c";
    const loc = try formatLines(t.allocator, tm, o);
    defer freeLines(t.allocator, loc);
    try t.expectEqualStrings("10/07/2026 14:05:09 Wed Oct  7 14:05:09 2026", loc[0]);
}

test "clock-paint: tickSignatureChangedNow honors instance settings" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator,
        \\[time]
        \\timezone = "UTC"
        \\[widget.clock]
        \\show_seconds = "true"
    );
    defer loaded.deinit();
    var cached: i32 = -1;
    // 1791374400 = 12:00:00, seconds visible: signature is seconds-of-day.
    try t.expect(tickSignatureChangedNow(&cached, &loaded.cfg, "clock", 1791374400));
    try t.expectEqual(@as(i32, 12 * 3600), cached);
    try t.expect(!tickSignatureChangedNow(&cached, &loaded.cfg, "clock", 1791374400));
    // One minute later the tick moved.
    try t.expect(tickSignatureChangedNow(&cached, &loaded.cfg, "clock", 1791374460));
}

test "clock-paint: cache hits by instance and tick, evicts stale ticks" {
    const t = std.testing;
    var c = Cache.init(t.allocator);
    defer c.deinit();
    const tm = testTm();
    const o = testOptions();
    const a = try c.lines(tm, o, "clock", 120);
    const b = try c.lines(tm, o, "clock", 120);
    try t.expect(a.ptr == b.ptr);
    // Fill past capacity with an older tick, then read a fresh tick: the
    // miss evicts everything stale, leaving only the new entry.
    var i: i64 = 0;
    while (i < 6) : (i += 1) {
        var idbuf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&idbuf, "w{d}", .{i});
        _ = try c.lines(tm, o, id, 0);
    }
    _ = try c.lines(tm, o, "clock", 180);
    // `testOptions` hides seconds, so ticks are minutes: 180s is tick 3.
    const want = tickKey(180, o.show_seconds);
    for (c.entries.items) |*e| try t.expectEqual(want, e.tick);
}

test "clock-paint: options resolve per-instance overrides over sc.time" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator,
        \\[time]
        \\use_24h = false
        \\show_seconds = true
        \\[widget.clock]
        \\use_24h = "true"
    );
    defer loaded.deinit();
    const o = optionsFor(&loaded.cfg, "clock");
    try t.expect(o.use_24h);
    try t.expect(o.show_seconds);
    try t.expect(!optionsFor(&loaded.cfg, "other").use_24h);
}

test "clock-paint: resolveTime handles empty and UTC zones" {
    const t = std.testing;
    // 2026-10-07 12:00:00 UTC.
    const utc = resolveTime(1791374400, "UTC") orelse return error.NoZone;
    try t.expectEqual(@as(u8, 12), utc.hour);
    try t.expectEqual(@as(u8, 0), utc.min);
    const local = resolveTime(1791374400, "") orelse return error.NoZone;
    // Local zone is environment-dependent; it must at least be a sane time.
    try t.expect(local.hour <= 23);
    try t.expect(local.min <= 59);
}

test "clock-paint: widget list detection" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator,
        \\[widget.mine]
        \\type = "clock"
    );
    defer loaded.deinit();
    const list = [_][]const u8{"mine"};
    try t.expect(widgetListContainsClock(&loaded.cfg, &list));
    const other = [_][]const u8{"media"};
    try t.expect(!widgetListContainsClock(&loaded.cfg, &other));
}

test "clock-paint: slot width clamps" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator, "");
    defer loaded.deinit();
    // No cairo context and an empty face still answer within the clamps.
    const w = dockClockSlotWidth(null, &loaded.cfg, "clock", 44.0, 200.0);
    try t.expect(w >= @max(44.0 * 1.25, 52.0));
    try t.expect(w <= @min(200.0 * 6.0, 220.0));
}
