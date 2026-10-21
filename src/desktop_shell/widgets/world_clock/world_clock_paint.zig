//! World-clock dock slot: a pill carrying one Apple-style analog face per
//! configured city, with the city name, a day label and an offset label
//! under each face.
//!
//! Two platform facilities have no Zig equivalent here, and both degrade
//! gracefully when their data is missing:
//!
//! * **No timezone database.** System timezone lookup resolves names
//!   such as `America/Los_Angeles` against the system tzdb; Zig ships
//!   nothing like it. A named zone therefore resolves to *this machine's*
//!   local time — the same fallback as a failed lookup — but
//!   with `offset_known = false`, so `format_offset_label` prints nothing
//!   instead of a confident `+0HRS`. The names whose offset is zero by
//!   definition (`UTC`, `GMT`, `Etc/UTC`, `Etc/GMT`) are resolved exactly,
//!   and an empty zone is local time with its real `tm_gmtoff`.
//! * **No `timeapi.io` fetch thread.** A background thread that kept
//!   `g_apiCache` warm with `currentUtcOffset` (curl, every 30 minutes) is
//!   not ported: a paint module must not own an HTTP client, and there is
//!   no curl binding. The cache it wrote survives here as a fixed
//!   table; `cacheZoneOffset` is the one write that thread used to perform
//!   and `reset` drops it. A future fetch layer can populate it and every
//!   clock in this file starts showing real offsets with no other change.
//!
//! The zone arithmetic itself is *not* reimplemented: the hour and minute of
//! each face come from `widgets/worldclock.zig`'s `localMinutes`, which is
//! the widget's own model of "shift local time by (zone − local)". That
//! file's `Zone` has no source for `offset_min` without a tz database
//! (offsets come from the cache or `tm_gmtoff` instead) and `formatOffset`
//! prints absolute `UTC±HH:MM` labels while this widget prints
//! relative `+5HRS` labels, so neither is used here.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const schema = @import("../../../config/schema.zig");
const pill = @import("../shared/pill.zig");
const wset = @import("../shared/widget_settings.zig");
const measure = @import("../shared/measure_scratch.zig");
const worldclock = @import("../worldclock.zig");

// Pi and degrees-to-radians constants.
const k_pi = 3.14159265358979323846;
const k_deg_to_rad = k_pi / 180.0;

/// `interCellGap`, `outerPad`, `clockToLabelGap` — the three constants that
/// make `dock_world_clock_slot_width` and `paint_world_clock_slot` agree.
const k_inter_cell_gap = 18.0;
const k_outer_pad = 16.0;
const k_clock_to_label_gap = 6.0;

/// City configs and the API cache are bounded here. Neither is worth an
/// allocator here, so both get a fixed cap (32 cities is already generous
/// for a dock strip) and anything past it is dropped rather than realloc'd.
const k_max_cities = 32;
const k_max_cached_zones = 32;
const k_max_zone_name = 64;
/// `label.size() > 10 → label.substr(0, 10)` for a label derived from the
/// zone name. Only reached when `city_<n>_label` is absent.
const k_max_derived_label = 10;

/// Clamp with floor-degradation: `lo > hi` is reachable — a big icon in a
/// short bar — and this degrades to the floor instead of asserting.
fn clampf(v: f64, lo: f64, hi: f64) f64 {
    return @max(lo, @min(hi, v));
}

// Fonts (`cityFd` / `smallFd` / `numFd`)

/// Clamped `icon_ref_px * 0.26` in [10.0, 15.0] — the city-line size.
fn cityFontPx(icon_ref_px: f64) f64 {
    return clampf(icon_ref_px * 0.26, 10.0, 15.0);
}

/// Clamped `icon_ref_px * 0.20` in [8.0, 12.0] — the day/offset line.
fn smallFontPx(icon_ref_px: f64) f64 {
    return clampf(icon_ref_px * 0.20, 8.0, 12.0);
}

/// Clamped `lay.diameter * 0.16` in [7.0, 13.0] — the clock numerals,
/// "set per-clock, proportional to diameter" in `WorldClockLayout`.
fn numFontPx(diameter: f64) f64 {
    return clampf(diameter * 0.16, 7.0, 13.0);
}

/// `cityFd << "Inter SemiBold " << int(px)` etc. `weight` is empty for the
/// plain `Inter <px>` description. Truncation is `@intFromFloat`, and a buffer overrun falls back to the family
/// name rather than aborting a frame.
fn fontDesc(buf: []u8, weight: []const u8, px: f64) []const u8 {
    const whole: i32 = @intFromFloat(px);
    if (weight.len == 0) {
        return std.fmt.bufPrint(buf, "Inter {d}", .{whole}) catch return "Inter";
    }
    return std.fmt.bufPrint(buf, "Inter {s} {d}", .{ weight, whole }) catch return "Inter";
}

// API-fetched offset cache (`g_apiCache`)

/// `g_apiCache` — zone name → UTC offset, written by `wc_api_thread_main`
/// and read first by `resolve_city_time`. The table, the lookup and the
/// public `cacheZoneOffset` / `reset` live at the end of the file, with the
/// rest of the public API.
const CachedZone = struct {
    name: [k_max_zone_name]u8 = undefined,
    len: usize = 0,
    offset_seconds: i64 = 0,
};

var g_cached_zones: [k_max_cached_zones]CachedZone = [_]CachedZone{.{}} ** k_max_cached_zones;
var g_cached_count: usize = 0;

/// Cache lookup for `g_apiCache[tz]`. With no fetch thread the table is plain state: the
/// shell fills it through `cacheZoneOffset` before it paints.
fn cachedOffset(tz: []const u8) ?i64 {
    if (tz.len == 0) return null;
    for (g_cached_zones[0..g_cached_count]) |*z| {
        if (std.mem.eql(u8, z.name[0..z.len], tz)) return z.offset_seconds;
    }
    return null;
}

/// The zone names whose UTC offset is zero by definition, resolved without
/// a tz database even though the answer is `0`:
/// even though the answer is `0` — see the module doc.
fn isUtcName(tz: []const u8) bool {
    if (std.mem.eql(u8, tz, "UTC")) return true;
    if (std.mem.eql(u8, tz, "Etc/UTC")) return true;
    if (std.mem.eql(u8, tz, "GMT")) return true;
    if (std.mem.eql(u8, tz, "Etc/GMT")) return true;
    return false;
}

// Time resolution

/// `struct tm` from <time.h>, laid out for glibc on Linux — the same block
/// `bin/dock.zig` and `logz.zig` declare.
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

/// Wall-clock seconds via `clock_gettime(CLOCK_REALTIME)`.
fn nowSeconds() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @intCast(ts.sec);
}

/// `localtime_r` for an epoch second, or null when libc refuses the date.
fn localTm(t: i64) ?CTm {
    var ts = t;
    var tm: CTm = undefined;
    if (localtime_r(&ts, &tm) == null) return null;
    return tm;
}

/// `gmtime_r` for an epoch second.
fn gmTm(t: i64) ?CTm {
    var ts = t;
    var tm: CTm = undefined;
    if (gmtime_r(&ts, &tm) == null) return null;
    return tm;
}

const DayParts = struct {
    hour: u8,
    minute: u8,
    second: u8,
    year: i32,
    month: u8,
    day: u8,
};

/// The `tm` fields, clamped the way `localTime()` in `bin/dock.zig` clamps
/// them so a malformed `tm` can never reach `@intCast`.
fn dayParts(tm: CTm) DayParts {
    const cl = std.math.clamp;
    return .{
        .hour = @intCast(cl(@as(i32, tm.tm_hour), 0, 23)),
        .minute = @intCast(cl(@as(i32, tm.tm_min), 0, 59)),
        .second = @intCast(cl(@as(i32, tm.tm_sec), 0, 59)),
        .year = 1900 + @as(i32, tm.tm_year),
        .month = @intCast(cl(@as(i32, tm.tm_mon) + 1, 1, 12)),
        .day = @intCast(cl(@as(i32, tm.tm_mday), 1, 31)),
    };
}

/// `CityEntry` — `city_<n>_label` over `city_<n>_tz`. An empty `tz` means
/// "this machine's local time" (empty zone, `Local` label).
const City = struct {
    label: []const u8,
    tz: []const u8,
};

/// `CityTimeInfo` — wall-clock time, calendar date and the zone's UTC
/// offset, with the same defaults (`1970-01-01`, offset unknown).
const CityTime = struct {
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    year: i32 = 1970,
    month: u8 = 1,
    day: u8 = 1,
    offset_seconds: i64 = 0,
    offset_known: bool = false,
};

/// City-time resolution against an epoch second, trying in order: the fetched-offset cache, then the local zone,
/// then system lookup, then the unknown-zone fallback (see the
/// module doc for how the last two collapse without a tz database).
///
/// The `tm` comes from `gmtime_r(now + offset)` when the
/// offset is known and `localtime_r` otherwise. The date still comes from
/// exactly those branches; the hour and minute come from
/// `worldclock.localMinutes`, which is the same shift expressed as the
/// widget's own zone math, and the second is the reference's — every real
/// offset is a whole number of minutes, so the seconds hand agrees.
fn resolveCityTime(city: City, now: i64) CityTime {
    var out = CityTime{};

    // The local reference for this instant: `localtime_r(&now, &tm)`.
    const base = localTm(now) orelse return out;
    const bp = dayParts(base);

    // 1) Offset. The cache wins outright (`g_apiCache[city.timezone]`), then
    //    the empty zone takes `tm.tm_gmtoff`, then
    //    the zero-offset names. Anything else falls through unknown.
    var offset_sec: i64 = 0;
    var have_offset = false;
    if (cachedOffset(city.tz)) |o| {
        offset_sec = o;
        have_offset = true;
    } else if (city.tz.len == 0) {
        offset_sec = @intCast(base.tm_gmtoff);
        have_offset = true;
    } else if (isUtcName(city.tz)) {
        have_offset = true; // offset_sec stays 0
    }

    // 2) Wall clock. `localMinutes` shifts the local hour/minute by the
    //    difference between the zone's offset and the local one; an
    //    unresolved zone passes the local offset through unchanged.
    const base_min: i32 = @intCast(@divTrunc(@as(i64, @intCast(base.tm_gmtoff)), 60));
    const zone_min: i32 = if (have_offset) @intCast(@divTrunc(offset_sec, 60)) else base_min;
    const hm = worldclock.localMinutes(bp.hour, bp.minute, zone_min, base_min);
    out.hour = hm.h;
    out.minute = hm.m;
    out.second = bp.second;

    // 3) Date: `gmtime_r(now + offset)` when
    //    the offset is known, the local date otherwise.
    const dp = dayParts(if (have_offset) (gmTm(now + offset_sec) orelse base) else base);
    out.year = dp.year;
    out.month = dp.month;
    out.day = dp.day;

    out.offset_seconds = offset_sec;
    out.offset_known = have_offset;
    return out;
}

// Labels

/// `days_from_civil` — Howard Hinnant's public-domain days-since-1970-01-01
/// (`@divTrunc` matches truncating division).
fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y = y0 - (if (m <= 2) @as(i64, 1) else 0);
    const era = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divTrunc(@as(i64, 153) * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// `format_day_label` — `Today` / `Tomorrow` / `Yesterday` / `+N Days`,
/// written into `buf` (24 bytes).
/// Zig's `std.fmt` has no `%+d` sign flag, so the `+`/`-` is spelled out.
fn formatDayLabel(buf: []u8, city: CityTime, reference: CityTime) []const u8 {
    const diff = daysFromCivil(city.year, city.month, city.day) -
        daysFromCivil(reference.year, reference.month, reference.day);
    if (diff == 0) return "Today";
    if (diff == 1) return "Tomorrow";
    if (diff == -1) return "Yesterday";
    const body = std.fmt.bufPrint(buf[1..], "{d} Days", .{@abs(diff)}) catch return "";
    buf[0] = if (diff < 0) '-' else '+';
    return buf[0 .. body.len + 1];
}

/// `format_offset_label` — `Same Time` / `+5HRS` / `+5.5HRS`, written into
/// `buf` (16 bytes), or empty when either side has no
/// offset. The sign is spelled with `%+d` / `%+.1f`; Zig has neither, so
/// the sign is one byte in front of an absolute value, and `std.math.round`
/// is round-half-away-from-zero (so 45 minutes reports `+1HRS`).
fn formatOffsetLabel(buf: []u8, city: CityTime, reference: CityTime) []const u8 {
    if (!city.offset_known or !reference.offset_known) return "";
    const diff_hours = @as(f64, @floatFromInt(city.offset_seconds - reference.offset_seconds)) / 3600.0;
    const rounded = std.math.round(diff_hours * 2.0) / 2.0;
    if (rounded == 0.0) return "Same Time";
    if (@floor(rounded) == rounded) {
        const v: i64 = @intFromFloat(rounded);
        const body = std.fmt.bufPrint(buf[1..], "{d}HRS", .{@abs(v)}) catch return "";
        buf[0] = if (v < 0) '-' else '+';
        return buf[0 .. body.len + 1];
    }
    const body = std.fmt.bufPrint(buf[1..], "{d:.1}HRS", .{@abs(rounded)}) catch return "";
    buf[0] = if (rounded < 0) '-' else '+';
    return buf[0 .. body.len + 1];
}

/// `is_daytime` — the Apple-style light face: daylight hours are 07:00
/// through 18:59.
fn isDaytime(t: CityTime) bool {
    return t.hour >= 7 and t.hour < 19;
}

// Pango helpers (`wc_make_layout` and friends)

/// `wc_make_layout` — a fresh layout with the font description set and
/// word-char wrapping, created fresh and released per frame.
fn makeLayout(cr: ?*cairo.cairo_t, font_desc: []const u8) text.Layout {
    var l = text.Layout.createForCairo(cr);
    l.setFont(font_desc);
    l.setWrap(text.WRAP_WORD_CHAR);
    return l;
}

/// `measure_text_width` — pango's pixel width of `s` in `layout`.
fn measureTextWidth(layout: *text.Layout, s: []const u8) f64 {
    layout.setText(s);
    const sz = layout.pixelSize();
    return @as(f64, @floatFromInt(sz.w));
}

/// `draw_centered_text` — centres `s` on `center_x` at `top_y` and reports
/// the rendered height through `out_h` so the caller can stack lines.
fn drawCenteredText(
    cr: ?*cairo.cairo_t,
    layout: *text.Layout,
    s: []const u8,
    center_x: f64,
    top_y: f64,
    r: f64,
    g: f64,
    b: f64,
    alpha: f64,
    out_h: ?*f64,
) void {
    const c = cr orelse return;
    layout.setText(s);
    const sz = layout.pixelSize();
    cairo.cairo_save(c);
    cairo.cairo_set_source_rgba(c, r, g, b, alpha);
    cairo.cairo_move_to(c, center_x - (@as(f64, @floatFromInt(sz.w)) / 2.0), top_y);
    layout.show(c);
    cairo.cairo_restore(c);
    if (out_h) |h| h.* = @as(f64, @floatFromInt(sz.h));
}

// Analog face drawing

/// `draw_clock_face` — the dial: filled disc, hairline rim, the 55 minor
/// tick marks (the hour positions are left clear for the numerals), and the
/// numerals themselves.
fn drawClockFace(cr: ?*cairo.cairo_t, num_layout: *text.Layout, cx: f64, cy: f64, radius: f64, light: bool) void {
    const c = cr orelse return;
    cairo.cairo_save(c);

    cairo.cairo_arc(c, cx, cy, radius, 0.0, 2.0 * k_pi);
    if (light) {
        cairo.cairo_set_source_rgb(c, 1.0, 1.0, 1.0);
    } else {
        cairo.cairo_set_source_rgb(c, 0.173, 0.173, 0.180); // #2c2c2e
    }
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_line_width(c, 1.0);
    if (light) {
        cairo.cairo_set_source_rgba(c, 0.0, 0.0, 0.0, 0.10);
    } else {
        cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.10);
    }
    cairo.cairo_stroke(c);

    // Minor tick marks (skip positions that will carry a number).
    const tick_color: f64 = if (light) 0.0 else 1.0;
    var i: i32 = 0;
    while (i < 60) : (i += 1) {
        if (@mod(i, 5) == 0) continue;
        const angle = @as(f64, @floatFromInt(i)) * 6.0 * k_deg_to_rad;
        const outer_r = radius * 0.94;
        const inner_r = radius * 0.88;
        const x1 = cx + outer_r * @sin(angle);
        const y1 = cy - outer_r * @cos(angle);
        const x2 = cx + inner_r * @sin(angle);
        const y2 = cy - inner_r * @cos(angle);
        cairo.cairo_set_source_rgba(c, tick_color, tick_color, tick_color, 0.35);
        cairo.cairo_set_line_width(c, @max(0.6, radius * 0.012));
        cairo.cairo_move_to(c, x1, y1);
        cairo.cairo_line_to(c, x2, y2);
        cairo.cairo_stroke(c);
    }

    // Hour numerals.
    var n: i32 = 1;
    while (n <= 12) : (n += 1) {
        const angle = @as(f64, @floatFromInt(n)) * 30.0 * k_deg_to_rad;
        const r = radius * 0.74;
        const px = cx + r * @sin(angle);
        const py = cy - r * @cos(angle);
        var buf: [4]u8 = undefined;
        const digits = std.fmt.bufPrint(&buf, "{d}", .{n}) catch continue;
        num_layout.setText(digits);
        const sz = num_layout.pixelSize();
        const v: f64 = if (light) 0.0 else 1.0;
        cairo.cairo_set_source_rgb(c, v, v, v);
        cairo.cairo_move_to(c, px - (@as(f64, @floatFromInt(sz.w)) / 2.0), py - (@as(f64, @floatFromInt(sz.h)) / 2.0));
        num_layout.show(c);
    }

    cairo.cairo_restore(c);
}

/// `draw_clock_hands` — hour, minute and the orange second hand with its
/// short counterweight tail, then the centre dot.
fn drawClockHands(
    cr: ?*cairo.cairo_t,
    cx: f64,
    cy: f64,
    radius: f64,
    hour24: u8,
    minute: u8,
    second: u8,
    light: bool,
) void {
    const c = cr orelse return;
    const min_f = @as(f64, @floatFromInt(minute));
    const sec_f = @as(f64, @floatFromInt(second));
    const hour12 = @as(f64, @floatFromInt(@mod(hour24, 12)));
    const hour_angle = (hour12 * 30.0 + min_f * 0.5) * k_deg_to_rad;
    const minute_angle = (min_f * 6.0 + sec_f * 0.1) * k_deg_to_rad;
    const second_angle = sec_f * 6.0 * k_deg_to_rad;

    const hour_len = radius * 0.50;
    const min_len = radius * 0.72;
    const sec_len = radius * 0.80;
    const sec_tail = radius * 0.16;

    const hand_shade: f64 = if (light) 0.0 else 1.0;

    cairo.cairo_save(c);
    cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);

    cairo.cairo_set_source_rgb(c, hand_shade, hand_shade, hand_shade);
    cairo.cairo_set_line_width(c, @max(1.4, radius * 0.06));
    cairo.cairo_move_to(c, cx, cy);
    cairo.cairo_line_to(c, cx + hour_len * @sin(hour_angle), cy - hour_len * @cos(hour_angle));
    cairo.cairo_stroke(c);

    cairo.cairo_set_line_width(c, @max(1.1, radius * 0.045));
    cairo.cairo_move_to(c, cx, cy);
    cairo.cairo_line_to(c, cx + min_len * @sin(minute_angle), cy - min_len * @cos(minute_angle));
    cairo.cairo_stroke(c);

    // Orange second hand, with a short tail like the reference design.
    cairo.cairo_set_source_rgb(c, 1.0, 0.624, 0.039); // #ff9f0a
    cairo.cairo_set_line_width(c, @max(0.9, radius * 0.022));
    cairo.cairo_move_to(c, cx - sec_tail * @sin(second_angle), cy + sec_tail * @cos(second_angle));
    cairo.cairo_line_to(c, cx + sec_len * @sin(second_angle), cy - sec_len * @cos(second_angle));
    cairo.cairo_stroke(c);

    cairo.cairo_arc(c, cx, cy, @max(1.2, radius * 0.055), 0.0, 2.0 * k_pi);
    cairo.cairo_set_source_rgb(c, hand_shade, hand_shade, hand_shade);
    cairo.cairo_fill(c);

    cairo.cairo_restore(c);
}

// Shared layout metrics (kept identical between measure & paint)

const WorldClockLayout = struct {
    diameter: f64 = 0.0,
    cell_w: f64 = 0.0,
    font_city_px: f64 = 0.0,
    font_small_px: f64 = 0.0,
    /// Set per-clock, proportional to the diameter — recomputed in paint with `numFontPx`.
    font_num_px: f64 = 0.0,
    label_block_h: f64 = 0.0,
    top_pad: f64 = 0.0,
};

/// `compute_layout` — the face diameter (clamped 24…120) and the cell width,
/// which is the diameter plus breathing room or the widest label, whichever
/// is larger. `city_layout` / `small_layout` supply the measurements.
fn computeLayout(
    cities: []const City,
    icon_ref_px: f64,
    slot_h: f64,
    city_layout: *text.Layout,
    small_layout: *text.Layout,
) WorldClockLayout {
    var lay = WorldClockLayout{};
    lay.font_city_px = cityFontPx(icon_ref_px);
    lay.font_small_px = smallFontPx(icon_ref_px);
    lay.font_num_px = 0.0; // set per-clock, proportional to diameter

    const city_line_h = lay.font_city_px * 1.3;
    const small_line_h = lay.font_small_px * 1.3;
    const line_gap = 2.0;
    lay.label_block_h = city_line_h + small_line_h + small_line_h + line_gap * 2.0;

    lay.top_pad = @max(6.0, slot_h * 0.06);
    const bottom_pad = @max(6.0, slot_h * 0.05);
    const clock_to_label_gap = k_clock_to_label_gap;

    lay.diameter = clampf(
        slot_h - lay.top_pad - clock_to_label_gap - lay.label_block_h - bottom_pad,
        24.0,
        120.0,
    );

    var max_label_w: f64 = 0.0;
    for (cities) |city| {
        max_label_w = @max(max_label_w, measureTextWidth(city_layout, city.label));
    }
    max_label_w = @max(max_label_w, measureTextWidth(small_layout, "Tomorrow"));
    max_label_w = @max(max_label_w, measureTextWidth(small_layout, "+16HRS"));

    lay.cell_w = @max(lay.diameter + 12.0, max_label_w + 10.0);
    return lay;
}

// City configuration (`parse_cities`)

/// `parse_cities` — `city_<n>_tz` must be present or the walk stops (it does
/// not scan ahead for later indices), `city_<n>_label` otherwise falls back
/// to the text after the first `/` of the zone name, truncated to 10
/// characters, and an empty list becomes `Local` + `UTC`. Results land in
/// `out` — capped at `out.len` (callers pass `k_max_cities`).
///
/// No fetch is started here; that belongs to the fetch layer of the module doc.
/// Nothing here allocates: the slices point into `sc`.
fn parseCities(sc: *const schema.ShellConfig, instance_id: []const u8, out: []City) []const City {
    var n: usize = 0;
    var idx: usize = 1;
    while (n < out.len) : (idx += 1) {
        var kbuf: [32]u8 = undefined;
        const tz_key = std.fmt.bufPrint(&kbuf, "city_{d}_tz", .{idx}) catch break;
        const tz = wset.widgetSetting(sc, instance_id, tz_key);
        if (tz.len == 0) break;

        var lbuf: [40]u8 = undefined;
        const label_key = std.fmt.bufPrint(&lbuf, "city_{d}_label", .{idx}) catch break;
        var label = wset.widgetSetting(sc, instance_id, label_key);
        if (label.len == 0) {
            label = if (std.mem.indexOfScalar(u8, tz, '/')) |pos| tz[pos + 1 ..] else tz;
            if (label.len > k_max_derived_label) label = label[0..k_max_derived_label];
        }
        out[n] = .{ .label = label, .tz = tz };
        n += 1;
    }

    if (n == 0) {
        // `cities.push_back({"Local", ""}); cities.push_back({"UTC", "UTC"});`
        if (out.len > 0) {
            out[0] = .{ .label = "Local", .tz = "" };
            n = 1;
        }
        if (out.len > 1) {
            out[1] = .{ .label = "UTC", .tz = "UTC" };
            n = 2;
        }
    }
    return out[0..n];
}

// Public API

/// `world_clock_tick_signature_changed` — the seconds hand is always
/// visible now, so the slot ticks every whole second: true when `now`,
/// truncated to an integer, has moved past `cached_signature`. `sc` and
/// `instance_id` are deliberately unused.
pub fn worldClockTickSignatureChanged(
    cached: *i32,
    cfg: *const schema.ShellConfig,
    instance_id: []const u8,
) bool {
    _ = cfg;
    _ = instance_id;
    const sig: i32 = @truncate(nowSeconds());
    if (sig == cached.*) return false;
    cached.* = sig;
    return true;
}

/// `dock_world_clock_slot_width` —
/// `cellW * n + interCellGap * (n - 1) + outerPad * 2` over the configured
/// cities, clamped between `max(icon_ref_px * 1.5, 64)` and
/// `min(bar_height * 12, 640)`. A null `measure_cr` falls back to the shared
/// 1 × 1 measuring context.
pub fn dockWorldClockSlotWidth(
    measure_cr: ?*cairo.cairo_t,
    cfg: *const schema.ShellConfig,
    instance_id: []const u8,
    icon_ref_px: f64,
    bar_height: f64,
) f64 {
    var buf: [k_max_cities]City = undefined;
    const cities = parseCities(cfg, instance_id, &buf);

    var cr: ?*cairo.cairo_t = measure_cr;
    if (cr == null) cr = measure.measureCr();

    const slot_h = @max(bar_height, icon_ref_px * 3.0);

    var city_buf: [48]u8 = undefined;
    var small_buf: [48]u8 = undefined;
    const city_fd = fontDesc(&city_buf, "SemiBold", cityFontPx(icon_ref_px));
    const small_fd = fontDesc(&small_buf, "", smallFontPx(icon_ref_px));

    var city_layout = makeLayout(cr, city_fd);
    defer city_layout.destroy();
    var small_layout = makeLayout(cr, small_fd);
    defer small_layout.destroy();

    const lay = computeLayout(cities, icon_ref_px, slot_h, &city_layout, &small_layout);

    const n = @as(f64, @floatFromInt(@max(cities.len, 1)));
    const gap_n = @as(f64, @floatFromInt(if (cities.len > 0) cities.len - 1 else 0));
    const inner = lay.cell_w * n + k_inter_cell_gap * gap_n + k_outer_pad * 2.0;

    const min_w = @max(icon_ref_px * 1.5, 64.0);
    const max_cap = @min(bar_height * 12.0, 640.0);
    return clampf(inner, min_w, max_cap);
}

/// `paint_world_clock_slot` — the pill, then one face plus three stacked
/// labels (city, day, offset) per configured city, centred in the slot.
/// `hovered` and `pressed` are deliberately unused: state never touches this widget.
pub fn paintWorldClockSlot(
    cr: ?*cairo.cairo_t,
    cfg: *const schema.ShellConfig,
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

    var buf: [k_max_cities]City = undefined;
    const cities = parseCities(cfg, instance_id, &buf);
    if (cities.len == 0) return;

    const now = nowSeconds();
    const reference = resolveCityTime(.{ .label = "", .tz = "" }, now);

    cairo.cairo_save(c);
    pill.paintPill(c, x, y, slot_w, slot_h);

    var city_buf: [48]u8 = undefined;
    var small_buf: [48]u8 = undefined;
    const city_fd = fontDesc(&city_buf, "SemiBold", cityFontPx(icon_ref_px));
    const small_fd = fontDesc(&small_buf, "", smallFontPx(icon_ref_px));

    var city_layout = makeLayout(c, city_fd);
    defer city_layout.destroy();
    var small_layout = makeLayout(c, small_fd);
    defer small_layout.destroy();

    const lay = computeLayout(cities, icon_ref_px, slot_h, &city_layout, &small_layout);

    var num_buf: [48]u8 = undefined;
    const num_fd = fontDesc(&num_buf, "SemiBold", numFontPx(lay.diameter));
    var num_layout = makeLayout(c, num_fd);
    defer num_layout.destroy();

    const city_n = @as(f64, @floatFromInt(cities.len));
    const gap_n = @as(f64, @floatFromInt(if (cities.len > 0) cities.len - 1 else 0));
    const total_content_w = lay.cell_w * city_n + k_inter_cell_gap * gap_n;
    var cursor_x = x + (slot_w - total_content_w) / 2.0;
    if (cursor_x < x + k_outer_pad * 0.5) cursor_x = x + k_outer_pad * 0.5;

    const clock_cy = y + lay.top_pad + lay.diameter / 2.0;
    const label_top_y = clock_cy + lay.diameter / 2.0 + k_clock_to_label_gap;

    for (cities) |city| {
        const cell_cx = cursor_x + lay.cell_w / 2.0;

        const t = resolveCityTime(city, now);
        const light = isDaytime(t);

        drawClockFace(c, &num_layout, cell_cx, clock_cy, lay.diameter / 2.0, light);
        drawClockHands(c, cell_cx, clock_cy, lay.diameter / 2.0, t.hour, t.minute, t.second, light);

        var day_buf: [24]u8 = undefined;
        var off_buf: [16]u8 = undefined;
        var h1: f64 = 0.0;
        var h2: f64 = 0.0;
        var h3: f64 = 0.0;
        var ty = label_top_y;
        drawCenteredText(c, &city_layout, city.label, cell_cx, ty, 1.0, 1.0, 1.0, 1.0, &h1);
        ty += h1 + 2.0;
        drawCenteredText(c, &small_layout, formatDayLabel(&day_buf, t, reference), cell_cx, ty, 0.60, 0.60, 0.62, 1.0, &h2);
        ty += h2 + 1.0;
        drawCenteredText(c, &small_layout, formatOffsetLabel(&off_buf, t, reference), cell_cx, ty, 0.60, 0.60, 0.62, 1.0, &h3);

        cursor_x += lay.cell_w + k_inter_cell_gap;
    }

    cairo.cairo_restore(c);
}

/// Cache write for `g_apiCache[tz] = {offset, true}` — exposed so a fetch layer (or
/// a test) can publish a zone offset. The empty zone is ignored, and a repeat name overwrites rather than
/// duplicating. Zone names longer than `k_max_zone_name` are truncated, and
/// a full table drops the write instead of growing.
pub fn cacheZoneOffset(tz: []const u8, offset_seconds: i64) void {
    if (tz.len == 0) return;
    for (g_cached_zones[0..g_cached_count]) |*z| {
        if (std.mem.eql(u8, z.name[0..z.len], tz)) {
            z.offset_seconds = offset_seconds;
            return;
        }
    }
    if (g_cached_count == k_max_cached_zones) return;
    const slot = &g_cached_zones[g_cached_count];
    const n = @min(tz.len, k_max_zone_name);
    @memcpy(slot.name[0..n], tz[0..n]);
    slot.len = n;
    slot.offset_seconds = offset_seconds;
    g_cached_count += 1;
}

/// `reset` — drops the module's offset cache. It exists so tests and a
/// restarting shell can clear what `cacheZoneOffset` published.
pub fn reset() void {
    g_cached_count = 0;
}

// Tests

fn loadCfg(src: []const u8) !schema.Loaded {
    return schema.loadText(std.testing.allocator, src);
}

test "world-clock-paint: tick signature changes once per second" {
    const t = std.testing;
    var cfg = try loadCfg("[widget.world_clock]");
    defer cfg.deinit();
    const c = &cfg.cfg;

    // A signature an hour behind the clock always trips, and the cache is
    // updated to the current second.
    const stale: i32 = @truncate(nowSeconds() - 3600);
    var sig: i32 = stale;
    try t.expect(worldClockTickSignatureChanged(&sig, c, "world_clock"));
    try t.expect(sig != stale);

    // Reading the current second back reports "unchanged". If the wall clock
    // ticks between the two reads the call legitimately returns true, so
    // retry — the contract is "once per second", not "never flaky".
    var stable = false;
    var attempt: usize = 0;
    while (attempt < 64) : (attempt += 1) {
        sig = @truncate(nowSeconds());
        if (!worldClockTickSignatureChanged(&sig, c, "world_clock")) {
            stable = true;
            break;
        }
    }
    try t.expect(stable);
}

test "world-clock-paint: parse_cities reads settings, labels and defaults" {
    const t = std.testing;
    var cfg = try loadCfg(
        \\[widget.world_clock]
        \\city_1_tz = "America/Los_Angeles"
        \\city_2_tz = "Asia/Tokyo"
        \\city_2_label = "Tokyo"
        \\city_3_tz = "UTC"
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    var buf: [k_max_cities]City = undefined;
    const cities = parseCities(c, "world_clock", &buf);
    try t.expectEqual(@as(usize, 3), cities.len);
    // Derived from the zone name, first `/` onwards, truncated to 10 chars.
    try t.expectEqualStrings("Los_Angele", cities[0].label);
    try t.expectEqualStrings("America/Los_Angeles", cities[0].tz);
    // A configured label is never truncated.
    try t.expectEqualStrings("Tokyo", cities[1].label);
    // No `/` in "UTC" keeps the whole name.
    try t.expectEqualStrings("UTC", cities[2].label);
    try t.expectEqualStrings("UTC", cities[2].tz);

    // No settings at all → the `Local` + `UTC` fallback pair.
    const defaults = parseCities(c, "some_other_widget", &buf);
    try t.expectEqual(@as(usize, 2), defaults.len);
    try t.expectEqualStrings("Local", defaults[0].label);
    try t.expectEqualStrings("", defaults[0].tz);
    try t.expectEqualStrings("UTC", defaults[1].label);
    try t.expectEqualStrings("UTC", defaults[1].tz);
}

test "world-clock-paint: parse_cities stops at the first gap" {
    const t = std.testing;
    var cfg = try loadCfg(
        \\[widget.world_clock]
        \\city_1_tz = "Europe/Berlin"
        \\city_3_tz = "Asia/Tokyo"
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    var buf: [k_max_cities]City = undefined;
    const cities = parseCities(c, "world_clock", &buf);
    // Parsing breaks on the empty `city_2_tz`; it never
    // scans ahead to index 3.
    try t.expectEqual(@as(usize, 1), cities.len);
    try t.expectEqualStrings("Berlin", cities[0].label);
}

test "world-clock-paint: days_from_civil matches the civil algorithm" {
    const t = std.testing;
    try t.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try t.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    // Known anchors: Y2K and the day after the 2000 leap February.
    try t.expectEqual(@as(i64, 10957), daysFromCivil(2000, 1, 1));
    try t.expectEqual(@as(i64, 11017), daysFromCivil(2000, 3, 1));
    // Today's date: 26 years on.
    try t.expectEqual(@as(i64, 20733), daysFromCivil(2026, 10, 7));
    // Pre-1970 keeps the era math honest.
    try t.expectEqual(@as(i64, -365), daysFromCivil(1969, 1, 1));
}

test "world-clock-paint: day label matches format_day_label" {
    const t = std.testing;
    var buf: [24]u8 = undefined;
    const ref = CityTime{ .year = 2026, .month = 10, .day = 7 };
    var city = ref;

    try t.expectEqualStrings("Today", formatDayLabel(&buf, city, ref));
    city.day = 8;
    try t.expectEqualStrings("Tomorrow", formatDayLabel(&buf, city, ref));
    city.day = 6;
    try t.expectEqualStrings("Yesterday", formatDayLabel(&buf, city, ref));
    city.day = 30;
    city.month = 9;
    try t.expectEqualStrings("-7 Days", formatDayLabel(&buf, city, ref));
    // 2026-01-01 is 279 days before 2026-10-07, 2027-01-01 is 86 after.
    city = .{ .year = 2026, .month = 1, .day = 1 };
    try t.expectEqualStrings("-279 Days", formatDayLabel(&buf, city, ref));
    city = .{ .year = 2027, .month = 1, .day = 1 };
    try t.expectEqualStrings("+86 Days", formatDayLabel(&buf, city, ref));
}

test "world-clock-paint: offset label matches format_offset_label" {
    const t = std.testing;
    var buf: [16]u8 = undefined;
    const ref = CityTime{ .offset_seconds = 0, .offset_known = true };
    var city = CityTime{ .offset_seconds = 5 * 3600, .offset_known = true };

    try t.expectEqualStrings("+5HRS", formatOffsetLabel(&buf, city, ref));
    city.offset_seconds = 5 * 3600 + 1800;
    try t.expectEqualStrings("+5.5HRS", formatOffsetLabel(&buf, city, ref));
    city.offset_seconds = -(3 * 3600 + 1800);
    try t.expectEqualStrings("-3.5HRS", formatOffsetLabel(&buf, city, ref));
    city.offset_seconds = 0;
    try t.expectEqualStrings("Same Time", formatOffsetLabel(&buf, city, ref));
    city.offset_seconds = 30 * 60;
    try t.expectEqualStrings("+0.5HRS", formatOffsetLabel(&buf, city, ref));
    // Round-half-away-from-zero, so 45 minutes lands on a whole hour.
    city.offset_seconds = 45 * 60;
    try t.expectEqualStrings("+1HRS", formatOffsetLabel(&buf, city, ref));
    city.offset_seconds = -(45 * 60);
    try t.expectEqualStrings("-1HRS", formatOffsetLabel(&buf, city, ref));
    // Half an hour below zero keeps its sign instead of becoming "+0.5".
    city.offset_seconds = -(30 * 60);
    try t.expectEqualStrings("-0.5HRS", formatOffsetLabel(&buf, city, ref));

    // Either side without an offset prints nothing — this is the path a
    // named zone without cached data takes (see the module doc).
    city.offset_known = false;
    try t.expectEqualStrings("", formatOffsetLabel(&buf, city, ref));
    city.offset_known = true;
    const unknown_ref = CityTime{ .offset_seconds = 3600, .offset_known = false };
    try t.expectEqualStrings("", formatOffsetLabel(&buf, city, unknown_ref));
}

test "world-clock-paint: offset cache stands in for g_apiCache" {
    const t = std.testing;
    defer reset();
    reset();

    try t.expect(cachedOffset("Asia/Tokyo") == null);
    cacheZoneOffset("Asia/Tokyo", 9 * 3600);
    try t.expectEqual(@as(?i64, 32400), cachedOffset("Asia/Tokyo"));

    // A repeat name overwrites instead of duplicating.
    cacheZoneOffset("Asia/Tokyo", 8 * 3600);
    try t.expectEqual(@as(?i64, 28800), cachedOffset("Asia/Tokyo"));

    // The empty zone is never cached.
    cacheZoneOffset("", 0);
    try t.expect(cachedOffset("") == null);

    // Fixed table: a full one drops writes rather than growing.
    reset();
    var i: usize = 0;
    while (i < k_max_cached_zones + 1) : (i += 1) {
        var nb: [24]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "Z{d}", .{i}) catch break;
        cacheZoneOffset(name, @intCast(i));
    }
    try t.expectEqual(@as(usize, k_max_cached_zones), g_cached_count);

    reset();
    try t.expect(cachedOffset("Asia/Tokyo") == null);
    try t.expectEqual(@as(usize, 0), g_cached_count);
}

test "world-clock-paint: resolve_city_time prefers the cached offset" {
    const t = std.testing;
    defer reset();
    reset();

    const now: i64 = 1_760_000_000; // 2025-10-09T04:53:20Z
    const base = localTm(now).?;
    const bp = dayParts(base);
    var off_buf: [16]u8 = undefined;

    // A named zone with no cached offset: system local time, offset unknown
    // (the module doc's tz-data gap), so the "+HRS" label stays blank.
    const named = resolveCityTime(.{ .label = "LA", .tz = "America/Los_Angeles" }, now);
    const local_ref = resolveCityTime(.{ .label = "", .tz = "" }, now);
    try t.expect(!named.offset_known);
    try t.expectEqual(bp.hour, named.hour);
    try t.expectEqual(bp.minute, named.minute);
    try t.expectEqual(bp.second, named.second);
    try t.expectEqual(bp.year, named.year);
    try t.expectEqual(bp.month, named.month);
    try t.expectEqual(bp.day, named.day);
    try t.expectEqualStrings("", formatOffsetLabel(&off_buf, named, local_ref));

    // The cache wins outright, and the wall clock it produces has to agree
    // with `gmtime_r(now + offset)`.
    cacheZoneOffset("Asia/Tokyo", 9 * 3600);
    const cached = resolveCityTime(.{ .label = "Tokyo", .tz = "Asia/Tokyo" }, now);
    try t.expect(cached.offset_known);
    try t.expectEqual(@as(i64, 32400), cached.offset_seconds);
    const gp = dayParts(gmTm(now + 32400).?);
    try t.expectEqual(gp.hour, cached.hour);
    try t.expectEqual(gp.minute, cached.minute);
    try t.expectEqual(gp.second, cached.second);
    try t.expectEqual(gp.year, cached.year);
    try t.expectEqual(gp.month, cached.month);
    try t.expectEqual(gp.day, cached.day);

    // "UTC" needs no tz database: offset zero, wall clock from `gmtime`.
    const utc = resolveCityTime(.{ .label = "UTC", .tz = "UTC" }, now);
    try t.expect(utc.offset_known);
    try t.expectEqual(@as(i64, 0), utc.offset_seconds);
    const gmp = dayParts(gmTm(now).?);
    try t.expectEqual(gmp.hour, utc.hour);
    try t.expectEqual(gmp.minute, utc.minute);
    try t.expectEqual(gmp.day, utc.day);

    // The local entry keeps the system offset (`tm_gmtoff`).
    const local = resolveCityTime(.{ .label = "Local", .tz = "" }, now);
    try t.expect(local.offset_known);
    try t.expectEqual(@as(i64, @intCast(base.tm_gmtoff)), local.offset_seconds);
    try t.expectEqual(bp.hour, local.hour);
    try t.expectEqual(bp.year, local.year);
}

test "world-clock-paint: layout metrics clamp like compute_layout" {
    const t = std.testing;
    const cr = measure.measureCr().?;
    const cities = [_]City{.{ .label = "Local", .tz = "" }};

    var city_buf: [48]u8 = undefined;
    var small_buf: [48]u8 = undefined;
    var city_layout = makeLayout(cr, fontDesc(&city_buf, "SemiBold", cityFontPx(32.0)));
    defer city_layout.destroy();
    var small_layout = makeLayout(cr, fontDesc(&small_buf, "", smallFontPx(32.0)));
    defer small_layout.destroy();

    // Font clamps: 0.26 → [10, 15], 0.20 → [8, 12].
    try t.expectEqual(@as(f64, 10.0), cityFontPx(32.0));
    try t.expectEqual(@as(f64, 15.0), cityFontPx(60.0));
    try t.expectEqual(@as(f64, 8.0), smallFontPx(10.0));
    try t.expectApproxEqAbs(@as(f64, 10.4), smallFontPx(52.0), 1e-9);

    // Starved slot: the diameter never drops under 24.
    const tiny = computeLayout(&cities, 32.0, 10.0, &city_layout, &small_layout);
    try t.expectEqual(@as(f64, 24.0), tiny.diameter);
    try t.expectEqual(@as(f64, 6.0), tiny.top_pad);
    try t.expect(tiny.cell_w >= tiny.diameter + 12.0);

    // Roomy slot: capped at 120, top pad grows with the slot.
    const huge = computeLayout(&cities, 32.0, 1000.0, &city_layout, &small_layout);
    try t.expectEqual(@as(f64, 120.0), huge.diameter);
    try t.expectApproxEqAbs(@as(f64, 60.0), huge.top_pad, 1e-9);

    // The label block is city + 2 × small lines + two 2 px gaps.
    try t.expectApproxEqAbs(@as(f64, 10.0) * 1.3 + 2.0 * (@as(f64, 8.0) * 1.3) + 4.0, huge.label_block_h, 1e-9);
}

test "world-clock-paint: slot width clamps like dock/widgets.zig" {
    const t = std.testing;
    var cfg = try loadCfg(
        \\[widget.world_clock]
        \\city_1_tz = "Asia/Tokyo"
        \\city_1_label = "Tokyo"
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    const w = dockWorldClockSlotWidth(null, c, "world_clock", 32.0, 64.0);
    try t.expect(std.math.isFinite(w));
    try t.expect(w >= 64.0); // max(icon * 1.5, 64)
    try t.expect(w <= 640.0); // min(bar * 12, 640)

    // The null context falls back to the same shared measuring context, so
    // passing it explicitly measures identically.
    const w2 = dockWorldClockSlotWidth(measure.measureCr(), c, "world_clock", 32.0, 64.0);
    try t.expectEqual(w, w2);

    // A 4 px bar caps the slot at 48 while the floor is 150: `lo > hi`, and
    // `clampf` keeps the floor the way dock/widgets.zig does.
    const w3 = dockWorldClockSlotWidth(null, c, "world_clock", 100.0, 4.0);
    try t.expectEqual(@as(f64, 150.0), w3);

    // Unknown instance → Local + UTC, still a sane width.
    const w4 = dockWorldClockSlotWidth(null, c, "no_such_widget", 32.0, 64.0);
    try t.expect(w4 >= 64.0 and w4 <= 640.0);
}

test "world-clock-paint: daytime is 07:00 through 18:59" {
    const t = std.testing;
    try t.expect(isDaytime(.{ .hour = 7 }));
    try t.expect(isDaytime(.{ .hour = 18 }));
    try t.expect(!isDaytime(.{ .hour = 19 }));
    try t.expect(!isDaytime(.{ .hour = 6 }));
    try t.expect(!isDaytime(.{}));
}

test "world-clock-paint: paint draws the slot" {
    const t = std.testing;
    var cfg = try loadCfg(
        \\[widget.world_clock]
        \\city_1_tz = "Asia/Tokyo"
        \\city_1_label = "Tokyo"
        \\city_2_tz = "America/Los_Angeles"
        \\city_2_label = "LA"
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 420, 140);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    // Two configured cities, hovered but not pressed — both flags ignored.
    paintWorldClockSlot(cr, c, "world_clock", 8, 8, 360, 120, 32.0, true, false);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Same slot with hover and press cleared draws through the same path.
    paintWorldClockSlot(cr, c, "world_clock", 8, 8, 360, 120, 32.0, false, false);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // The Local + UTC defaults of an unconfigured instance.
    paintWorldClockSlot(cr, c, "some_other_widget", 8, 8, 300, 100, 24.0, false, false);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // A null context is a no-op rather than a crash.
    paintWorldClockSlot(null, c, "world_clock", 0, 0, 100, 80, 24.0, false, false);

    // `reset` clears the cache the paint path reads.
    cacheZoneOffset("Asia/Tokyo", 9 * 3600);
    reset();
    paintWorldClockSlot(cr, c, "world_clock", 8, 8, 360, 120, 32.0, false, false);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}
