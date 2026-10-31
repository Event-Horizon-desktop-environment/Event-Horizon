//! Night-light scheduling math.
//!
//! The legacy C++ stored schedule fields (`schedule_mode`, start/end, the
//! second temperature) but never executed them — `[nightlight]` reduced to
//! "enabled → night temperature, period". This module makes the three
//! schedule modes real:
//!
//!   0 Manual            — enabled means night temperature, nothing else.
//!   1 Sunset to sunrise — the night window is the sun's: NOAA sunrise
//!                         equation at `latitude`/`longitude` when
//!                         `use_location` is on, else the time window.
//!   2 Scheduled         — the night window is start/end minutes-of-day,
//!                         midnight-wrap aware.
//!
//! `evaluate` folds the whole thing into one "what temperature should the
//! display be at right now" query (`null` = hands gamma back to the
//! compositor). Outside the night window the *day* temperature applies —
//! 6500K is the neutral default, so this costs nothing until the user asks
//! for a permanently cooler/warmer balance — and the crossing into and out
//! of the window is eased over ±60 minutes so the light slowly drifts
//! instead of snapping.
//!
//! Everything here is pure and unit-tested; only `localNow` touches the
//! outside world (libc `localtime_r`), and it is swapped out in tests.

const std = @import("std");
const schema2 = @import("../../config/schema2.zig");

/// Ease width over each boundary, in minutes. Night settles fully inside
/// the window past this margin and is fully off past it outside.
pub const transition_minutes: i32 = 60;

/// The time context the evaluator needs — everything `localtime_r` answers
/// about a moment, in the form the schedule math wants.
pub const Now = struct {
    /// `clock_realtime` broken down. `minute_of_day` is local.
    minute_of_day: i32,
    year: i32,
    /// 1–12.
    month: i32,
    day: i32,
    /// The zone's offset east of UTC, minutes (e.g. -300 for CDT).
    utc_offset_min: i32,
};

/// Days from 1970-01-01, Howard Hinnant's `days_from_civil` — leap years
/// without a calendar table.
pub fn daysFromCivil(y_in: i64, month: i64, day: i64) i64 {
    var y = y_in;
    if (month <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divFloor(153 * (month + (if (month > 2) @as(i64, -3) else @as(i64, 9))) + 2, 5) + day - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

const tm_t = extern struct {
    tm_sec: c_int = 0,
    tm_min: c_int = 0,
    tm_hour: c_int = 0,
    tm_mday: c_int = 0,
    tm_mon: c_int = 0,
    tm_year: c_int = 0,
    tm_wday: c_int = 0,
    tm_yday: c_int = 0,
    tm_isdst: c_int = 0,
    tm_gmtoff: c_long = 0,
    tm_zone: ?[*:0]const u8 = null,
};
extern "c" fn localtime_r(timep: ?*const i64, result: ?*tm_t) ?*tm_t;

/// Break the wall clock into the `Now` the schedule math wants, in the
/// machine's local zone.
pub fn localNow(unix_sec: i64) Now {
    var tm: tm_t = .{};
    var t = unix_sec;
    if (localtime_r(&t, &tm) == null) {
        // No zone info: fall back to UTC rather than nothing.
        const days = @divFloor(unix_sec, 86400);
        var rem = @mod(unix_sec, 86400);
        const hour = @divFloor(rem, 3600);
        rem -= hour * 3600;
        const min = @divFloor(rem, 60);
        const civil = civilFromDays(days);
        return .{
            .minute_of_day = @intCast(hour * 60 + min),
            .year = @intCast(civil.year),
            .month = @intCast(civil.month),
            .day = @intCast(civil.day),
            .utc_offset_min = 0,
        };
    }
    const gmt_off: i32 = @intCast(@divFloor(tm.tm_gmtoff, 60));
    return .{
        .minute_of_day = @intCast(tm.tm_hour * 60 + tm.tm_min),
        .year = @intCast(tm.tm_year + 1900),
        .month = @intCast(tm.tm_mon + 1),
        .day = @intCast(tm.tm_mday),
        .utc_offset_min = gmt_off,
    };
}

const Civil = struct { year: i64, month: i64, day: i64 };

pub fn civilFromDays(z_i: i64) Civil {
    var z = z_i;
    z += 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(doy * 5 + 2, 153); // [0, 11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9)); // [1, 12]
    return .{ .year = y + (if (m <= 2) @as(i64, 1) else @as(i64, 0)), .month = m, .day = d };
}

/// NOAA "sunrise equation" for one calendar day: solar transit, declination
/// from the ecliptic longitude, then the −0.83° (refraction + limb) hour
/// angle. Returns the two crossings in minutes of the *local* day. Times
/// are typically good to a couple of minutes — exactly right for a color
/// temperature, off only for anything demanding ephemeris precision.
///
/// `null` means "give up" (formally out-of-range latitude) and callers
/// fall back to the time window; polar day/night decode to the sun never
/// crossing locally.
pub const Sun = union(enum) {
    /// Local minutes-of-day for each crossing.
    crossings: struct { rise_min: i32, set_min: i32 },
    /// No sunset today: the night window is empty.
    polar_day,
    /// No sunrise today: the whole day is night.
    polar_night,
};

pub fn sunRiseSet(now: Now, lat_deg: f64, lon_deg: f64) ?Sun {
    const lat_deg_c = @max(-89.9999, @min(89.9999, lat_deg));
    if (lat_deg_c != lat_deg) return null; // deliberately out of range
    if (lon_deg > 180.0 or lon_deg < -180.0) return null;

    const lat = lat_deg_c * std.math.pi / 180.0;

    // n: days since J2000-01-01, counted for the *local* day; `n_star` is
    // the canonical Wikipedia form, corrected by the day fraction the
    // longitude eats off the UTC day.
    const local_days = daysFromCivil(now.year, now.month, now.day);
    const n: f64 = @as(f64, @floatFromInt(local_days - daysFromCivil(2000, 1, 1))) + 0.5;
    const n_star: f64 = n - lon_deg / 360.0;

    // Mean anomaly, ecliptic longitude, solar transit — all in fractions
    // of a Julian day, per the standard simplified NOAA form.
    const mean_anom_deg = 357.5291 + 0.98560028 * n_star; // deg
    const m = mean_anom_deg * std.math.pi / 180.0;
    const c = 1.9148 * @sin(m) + 0.0200 * @sin(2.0 * m) + 0.0003 * @sin(3.0 * m);
    const lambda_deg = mean_anom_deg + c + 180.0 + 102.9372;
    const lambda = lambda_deg * std.math.pi / 180.0;
    const j_transit = 2451545.0 + n_star + 0.0053 * @sin(m) - 0.0069 * @sin(lambda);

    const sin_decl = @sin(lambda) * @sin(23.4397 * std.math.pi / 180.0);
    const decl = std.math.asin(@max(-1.0, @min(1.0, sin_decl)));

    // cos ω0 = (sin(-0.833°) − sin φ sin δ) / (cos φ cos δ)
    const num = @sin(-0.833 * std.math.pi / 180.0) - @sin(lat) * sin_decl;
    const den = @cos(lat) * @cos(decl);
    if (den == 0) return null;
    const cos_w = num / den;
    if (cos_w > 1.0) return .polar_night;
    if (cos_w < -1.0) return .polar_day;
    const w0 = std.math.acos(@max(-1.0, @min(1.0, cos_w)));

    // Julian day ↔ unix seconds: unix = (JD − 2440587.5)·86400.
    const jd_to_unix = struct {
        fn f(jd: f64) i64 {
            return @intFromFloat((jd - 2440587.5) * 86400.0);
        }
    }.f;

    // Local minutes-of-day: (event − local midnight of this day) / 60.
    const local_midnight_unix = local_days * 86400 - @as(i64, now.utc_offset_min) * 60;

    const rise_unix = jd_to_unix(j_transit - w0 * (12.0 / std.math.pi));
    const set_unix = jd_to_unix(j_transit + w0 * (12.0 / std.math.pi));
    const rise_min: i32 = @intCast(@divFloor(rise_unix - local_midnight_unix, 60));
    const set_min: i32 = @intCast(@divFloor(set_unix - local_midnight_unix, 60));
    return .{ .crossings = .{ .rise_min = rise_min, .set_min = set_min } };
}

/// The night window (minutes of day) for mode 1/2, midnight-wrap aware:
/// `null` → no window (solar said polar day and the caller chose fallback),
/// equal start/end means the whole day is night.
pub const Window = struct { start: i32, end: i32 };

pub fn nightWindowFor(nl: schema2.NightLightSettings, now: Now) Window {
    if (nl.schedule_mode == 1 and nl.use_location) {
        if (sunRiseSet(now, @floatFromInt(nl.latitude), @floatFromInt(nl.longitude))) |sun| {
            switch (sun) {
                .crossings => |x| return .{ .start = x.set_min, .end = x.rise_min },
                // No local sunset: fall back to the stored window rather
                // than leaving the schedule dead in the far-north summer.
                .polar_day, .polar_night => {},
            }
        }
    }
    return .{ .start = nl.schedule_start_min, .end = nl.schedule_end_min };
}

/// Depth into the night window, signed: positive inside, negative outside,
/// measured in minutes to the nearest boundary so the ease can straddle it.
/// The weight is continuous everywhere — 0.5 exactly on a boundary, easing
/// to 0/1 as `transition_minutes` open up on either side — and it holds at
/// its extremes for winter windows wider than 12 h (plain edge deltas
/// would break there).
pub fn nightWeight(win: Window, now_min: i32) f64 {
    const width: i32 = if (win.start == win.end) 1440 else @mod(win.end - win.start, 1440);
    const past_start: i32 = @mod(now_min - win.start, 1440);

    // Signed depth into the night region: >0 inside, <0 outside, in
    // minutes to the nearest boundary so the ease can straddle it.
    var depth: i32 = undefined;
    if (past_start < width) {
        depth = @min(past_start, width - past_start); // minutes from entering / to leaving
    } else {
        const since_left = past_start - width; // through the end edge
        const to_enter = 1440 - past_start; // up to the start edge
        depth = -@min(since_left, to_enter);
    }

    const ad = @abs(depth);
    if (ad >= transition_minutes) return if (depth > 0) 1.0 else 0.0;
    const x: f64 = @as(f64, @floatFromInt(depth)) / @as(f64, transition_minutes);
    return 0.5 + 0.5 * @sin(std.math.pi / 2.0 * x);
}

/// The display temperature for `now`, or `null` when the schedule says the
/// gamma client should be off entirely (hands the ramp back to the
/// compositor). The master toggle in `[nightlight]` stays a global off on
/// top of everything.
pub fn evaluate(nl: schema2.NightLightSettings, now: Now) ?i32 {
    if (!nl.enabled) return null;
    switch (nl.schedule_mode) {
        // Manual: simply on whenever the toggle says so.
        0 => return nl.night_temperature,
        // Scheduled / Sunset: eased day↔night blend across the window.
        1, 2 => {
            const win = nightWindowFor(nl, now);
            const w = nightWeight(win, now.minute_of_day);
            const dayf: f64 = @floatFromInt(nl.day_temperature);
            const nightf: f64 = @floatFromInt(nl.night_temperature);
            return @intFromFloat(@round(dayf + (nightf - dayf) * w));
        },
        else => return nl.night_temperature,
    }
}

// ------------------------------------------------------------------ tests

const test_nl = struct {
    fn cfg(enabled: bool, mode: i32, start: i32, end: i32) schema2.NightLightSettings {
        return .{
            .enabled = enabled,
            .day_temperature = 6500,
            .night_temperature = 4000,
            .schedule_mode = mode,
            .schedule_start_min = start,
            .schedule_end_min = end,
        };
    }
};

test "schedule: manual mode is the night temperature" {
    const now = Now{ .minute_of_day = 710, .year = 2026, .month = 10, .day = 23, .utc_offset_min = -300 };
    try std.testing.expectEqual(@as(?i32, 4000), evaluate(test_nl.cfg(true, 0, 1200, 360), now));
    try std.testing.expectEqual(@as(?i32, null), evaluate(test_nl.cfg(false, 0, 1200, 360), now));
}

test "schedule: manual mode ignores the clock entirely" {
    var now = Now{ .minute_of_day = 0, .year = 2026, .month = 10, .day = 23, .utc_offset_min = -300 };
    now.minute_of_day = 22 * 60;
    try std.testing.expectEqual(@as(?i32, 4000), evaluate(test_nl.cfg(true, 0, 1200, 360), now));
}

test "schedule: scheduled window, straight through midnight" {
    // Window 20:00–06:00: night at 21:00 and 02:00, day at 12:00.
    const base = Now{ .minute_of_day = 0, .year = 2026, .month = 10, .day = 23, .utc_offset_min = -300 };
    var now = base;
    now.minute_of_day = 21 * 60;
    try std.testing.expectEqual(@as(?i32, 4000), evaluate(test_nl.cfg(true, 2, 1200, 360), now));
    now.minute_of_day = 2 * 60;
    try std.testing.expectEqual(@as(?i32, 4000), evaluate(test_nl.cfg(true, 2, 1200, 360), now));
    now.minute_of_day = 12 * 60;
    try std.testing.expectEqual(@as(?i32, 6500), evaluate(test_nl.cfg(true, 2, 1200, 360), now));
}

test "schedule: non-wrapping window" {
    // Window 06:00–20:00 is night during the day here — what matters is the
    // edges, not the label.
    const base = Now{ .minute_of_day = 0, .year = 2026, .month = 10, .day = 23, .utc_offset_min = -300 };
    var now = base;
    now.minute_of_day = 12 * 60;
    try std.testing.expectEqual(@as(?i32, 4000), evaluate(test_nl.cfg(true, 2, 360, 1200), now));
    now.minute_of_day = 22 * 60;
    try std.testing.expectEqual(@as(?i32, 6500), evaluate(test_nl.cfg(true, 2, 360, 1200), now));
}

test "schedule: blending ramps over the transition band" {
    const nl = test_nl.cfg(true, 2, 1200, 360);
    const mk = struct {
        fn f(min: i32) Now {
            return .{ .minute_of_day = min, .year = 2026, .month = 10, .day = 23, .utc_offset_min = -300 };
        }
    };
    // An hour before the window opens: fully day; thirty-one minutes before:
    // past the midpoint but not zero; inside beyond an hour: fully night.
    try std.testing.expectEqual(@as(?i32, 6500), evaluate(nl, mk.f(1200 - 61)));
    const partial = evaluate(nl, mk.f(1200 - 31)).?;
    try std.testing.expect(partial > 6500 and partial < 4000);
    try std.testing.expectEqual(@as(?i32, 4000), evaluate(nl, mk.f(1200 + 61)));
    // Dead-centre on the boundary is half-and-half (a 5250K midpoint for
    // these endpoints).
    try std.testing.expectEqual(@as(?i32, 5250), evaluate(nl, mk.f(1200)));
}

test "schedule: equal window bounds mean always night" {
    const now = Now{ .minute_of_day = 12 * 60, .year = 2026, .month = 10, .day = 23, .utc_offset_min = -300 };
    try std.testing.expectEqual(@as(?i32, 4000), evaluate(test_nl.cfg(true, 2, 600, 600), now));
}

test "schedule: solar window for Berlin on the 2024 solstice" {
    // Berlin 52.52N 13.405E, CEST (UTC+2): sunrise 04:43, sunset 21:33 local.
    var now = Now{ .minute_of_day = 12 * 60, .year = 2024, .month = 6, .day = 21, .utc_offset_min = 120 };
    _ = &now;
    const sun = sunRiseSet(now, 52.52, 13.405).?;
    const x = sun.crossings;
    try std.testing.expect(@abs(x.rise_min - (4 * 60 + 43)) <= 8);
    try std.testing.expect(@abs(x.set_min - (21 * 60 + 33)) <= 8);
}

test "schedule: polar day has no night and falls back to the window" {
    // Tromsø 69.65N 18.96E on the solstice — the sun stays up; the schedule
    // must fall back to the stored time window instead of staying dead.
    const now = Now{ .minute_of_day = 12 * 60, .year = 2024, .month = 6, .day = 21, .utc_offset_min = 120 };
    const sun = sunRiseSet(now, 69.65, 18.96).?;
    try std.testing.expectEqual(Sun.polar_day, sun);

    var nl = test_nl.cfg(true, 1, 1200, 360);
    nl.use_location = true;
    nl.latitude = 69;
    nl.longitude = 19;
    const win = nightWindowFor(nl, now);
    try std.testing.expectEqual(@as(i32, 1200), win.start);
    try std.testing.expectEqual(@as(i32, 360), win.end);
}

test "schedule: location mode uses computed crossings" {
    var nl = test_nl.cfg(true, 1, 1200, 360);
    nl.use_location = true;
    nl.latitude = 52;
    nl.longitude = 13;
    // Midnight in Berlin, June: fully past the fallback window (night band
    // is 20:00–06:00), and solar says night as well — both agree; the point
    // is the solar path decodes at all (tolerances live in the solstice test).
    const now = Now{ .minute_of_day = 0, .year = 2024, .month = 6, .day = 21, .utc_offset_min = 120 };
    try std.testing.expectEqual(@as(?i32, 4000), evaluate(nl, now));
    // Solar noon: day both ways.
    const noon = Now{ .minute_of_day = 13 * 60, .year = 2024, .month = 6, .day = 21, .utc_offset_min = 120 };
    try std.testing.expectEqual(@as(?i32, 6500), evaluate(nl, noon));
}

test "schedule: out-of-range latitude disables the solar path" {
    var nl = test_nl.cfg(true, 1, 1200, 360);
    nl.use_location = true;
    nl.latitude = 123;
    nl.longitude = 13;
    const now = Now{ .minute_of_day = 12 * 60, .year = 2024, .month = 6, .day = 21, .utc_offset_min = 120 };
    // Falls back to the stored window (20:00–06:00 → day at noon).
    try std.testing.expectEqual(@as(?i32, 6500), evaluate(nl, now));
}

test "schedule: daysFromCivil round-trips" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 19046), daysFromCivil(2022, 2, 12)); // XX: known value
    const c = civilFromDays(daysFromCivil(2026, 10, 23));
    try std.testing.expectEqual(@as(i64, 2026), c.year);
    try std.testing.expectEqual(@as(i64, 10), c.month);
    try std.testing.expectEqual(@as(i64, 23), c.day);
}
