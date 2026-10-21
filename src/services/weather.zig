//! Current conditions behind the dock's weather slot.
//!
//! Weather service: resolve a location, ask Open-Meteo for the current temperature and WMO
//! code, and turn that code into the glyph `weather_paint.zig` draws. The
//! in-memory caches collapse here into a
//! single in-flight request and a `next due` deadline held by the host, since
//! the dock only ever has one weather slot at a time.
//!
//! Everything runs off the Wayland input thread: `std.http.Client.fetch`
//! blocks, and a compositor callback may not. `request` spawns one worker;
//! the worker publishes a `Reading` through an atomic phase word and the host
//! drains it with `take` on its own tick. A `Reading` is a plain value — no
//! allocation outlives the call — so an undrained result cannot leak.

const std = @import("std");
const bing = @import("bing.zig");
const cal_math = @import("../calendar_math.zig");

/// The largest reply we will buffer for any of the three endpoints. A
/// forecast reply is under 4 KB; geocoding and the IP lookup are under 8 KB.
const kMaxReply = 64 * 1024;

/// One forecast day. `glyph` is a literal from `glyphForCode`, so the struct
/// stays trivially copyable like the reading it ships in.
pub const Day = struct {
    glyph: []const u8 = "cloud",
    hi: i32 = 0,
    lo: i32 = 0,
    /// 0=Sun, the same numbering the calendar uses.
    wday: u8 = 0,
};

/// One weather reading, sized to be copied by value across threads.
pub const Reading = struct {
    /// False when the lookup or the forecast failed. A host keeps its last
    /// good reading rather than blanking the slot.
    available: bool = false,
    /// Rounded degrees in the unit `fahrenheit` names.
    temp: i32 = 0,
    fahrenheit: bool = false,
    /// Glyph name for the WMO code (resolved to a Lucide SVG by the paint
    /// path) — a string literal, so the copy is free.
    glyph: []const u8 = "cloud",
    /// Where the reading came from, fixed size so `Reading` stays POD.
    location: [72]u8 = undefined,
    location_len: u8 = 0,

    // The detail the weather *card* shows. All scalars, all defaults, so a
    // reading that never grew them still paints sensible dashes.
    hi: i32 = 0,
    lo: i32 = 0,
    feels_like: i32 = 0,
    humidity_pct: i32 = 0,
    wind_kmh: i32 = 0,
    visibility_m: i32 = 0,
    is_day: bool = true,
    /// Human wording for the WMO code, e.g. "Light rain".
    condition: [40]u8 = undefined,
    condition_len: u8 = 0,
    days: [5]Day = @splat(.{}),
    n_days: u8 = 0,

    /// Copy `name` into the inline slot — it may point into a reply buffer
    /// that is about to be freed.
    pub fn place(self: *Reading, name: []const u8) void {
        const n = @min(name.len, self.location.len);
        @memcpy(self.location[0..n], name[0..n]);
        self.location_len = @intCast(n);
    }

    pub fn placeName(self: *const Reading) []const u8 {
        return self.location[0..self.location_len];
    }

    pub fn placeCondition(self: *Reading, s: []const u8) void {
        const n = @min(s.len, self.condition.len);
        @memcpy(self.condition[0..n], s[0..n]);
        self.condition_len = @intCast(n);
    }

    pub fn conditionText(self: *const Reading) []const u8 {
        return self.condition[0..self.condition_len];
    }
};

/// The slice of widget settings a fetch needs, snapshotted by the host before
/// it hands them to a thread — the config is arena-backed and can be swapped
/// out from under a worker by `App.reload`.
pub const Request = struct {
    /// `weather_lat` / `weather_lon`; both empty means "work it out".
    lat: []const u8 = "",
    lon: []const u8 = "",
    /// `weather_city`, used when the coordinates are absent.
    city: []const u8 = "",
    /// `weather_unit` lower-cased to "f".
    fahrenheit: bool = false,
};

/// A resolved position plus the label that goes under it. `name` points into
/// the `label` buffer the caller passed to the parser, so it is only valid
/// while that buffer is.
pub const Geo = struct {
    ok: bool = false,
    lat: f64 = 0,
    lon: f64 = 0,
    name: []const u8 = "",
};

/// `weather_glyph_for_code` — WMO code → glyph name table.
/// Every name here is mapped to a Lucide icon by
/// `ux/shared/lucide_icons.zig`; the shell draws no font ligatures, so an
/// unmapped name would simply draw nothing.
pub fn glyphForCode(code: i32) []const u8 {
    if (code == 0) return "sunny";
    if (code == 1 or code == 2) return "partly_cloudy_day";
    if (code == 3) return "cloud";
    if (code == 45 or code == 48) return "foggy";
    if ((code >= 51 and code <= 57) or (code >= 61 and code <= 67) or (code >= 80 and code <= 82)) return "rainy";
    if ((code >= 71 and code <= 77) or code == 85 or code == 86) return "weather_snowy";
    if (code >= 95 and code <= 99) return "thunderstorm";
    return "cloud";
}

/// The human wording for the same WMO code, split at the same boundaries as
/// `glyphForCode` so the card's text and its icon never disagree.
pub fn conditionForCode(code: i32) []const u8 {
    return switch (code) {
        0 => "Clear",
        1 => "Mainly clear",
        2 => "Partly cloudy",
        3 => "Overcast",
        45 => "Fog",
        48 => "Depositing rime fog",
        51 => "Light drizzle",
        53 => "Drizzle",
        55 => "Dense drizzle",
        56 => "Freezing drizzle",
        57 => "Dense freezing drizzle",
        61 => "Light rain",
        63 => "Rain",
        65 => "Heavy rain",
        66 => "Freezing rain",
        67 => "Heavy freezing rain",
        71 => "Light snow",
        73 => "Snow",
        75 => "Heavy snow",
        77 => "Snow grains",
        80 => "Light showers",
        81 => "Showers",
        82 => "Violent showers",
        85 => "Light snow showers",
        86 => "Heavy snow showers",
        95 => "Thunderstorm",
        96 => "Thunderstorm with hail",
        99 => "Thunderstorm with heavy hail",
        else => "Unknown",
    };
}

const kIdle: u8 = 0;
const kRunning: u8 = 1;
const kReady: u8 = 2;

var phase: std.atomic.Value(u8) = std.atomic.Value(u8).init(kIdle);
var result: Reading = .{};
var worker: ?std.Thread = null;

/// True when no fetch is in flight, i.e. `request` would actually start one.
pub fn idle() bool {
    return phase.load(.acquire) == kIdle;
}

/// Start a fetch unless one is already running. Returns whether a worker was
/// started; the host owns the retry deadline, so a failure cannot be retried
/// in a tight loop.
pub fn request(alloc: std.mem.Allocator, io: std.Io, req: Request) bool {
    if (phase.load(.acquire) != kIdle) return false;
    // The previous worker published its result (or gave up) before the phase
    // fell back to idle, so joining here cannot block.
    if (worker) |w| {
        w.join();
        worker = null;
    }
    const job = alloc.create(Job) catch return false;
    job.* = .{
        .alloc = alloc,
        .io = io,
        .lat = "",
        .lon = "",
        .city = "",
        .fahrenheit = req.fahrenheit,
    };
    job.lat = alloc.dupe(u8, req.lat) catch return fail(job);
    job.lon = alloc.dupe(u8, req.lon) catch return fail(job);
    job.city = alloc.dupe(u8, req.city) catch return fail(job);
    phase.store(kRunning, .release);
    worker = std.Thread.spawn(.{}, Job.run, .{job}) catch {
        phase.store(kIdle, .release);
        job.free();
        return false;
    };
    return true;
}

/// Zig has no exception stack, so the three `dupe` arms funnel their rollback
/// through here instead of repeating the same three frees.
fn fail(job: *Job) bool {
    job.free();
    return false;
}

/// Move the finished reading into `out`. Returns false when nothing has
/// landed. Nothing here keeps a claim on `out` — it is POD, so the caller owns
/// the value outright.
pub fn take(out: *Reading) bool {
    if (phase.load(.acquire) != kReady) return false;
    out.* = result;
    phase.store(kIdle, .release);
    return true;
}

/// Tests only: drain any in-flight worker so the suite can start clean.
pub fn reset() void {
    if (worker) |w| {
        w.join();
        worker = null;
    }
    result = .{};
    phase.store(kIdle, .release);
}

const Job = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    lat: []const u8,
    lon: []const u8,
    city: []const u8,
    fahrenheit: bool,

    fn free(self: *Job) void {
        if (self.lat.len > 0) self.alloc.free(self.lat);
        if (self.lon.len > 0) self.alloc.free(self.lon);
        if (self.city.len > 0) self.alloc.free(self.city);
        self.alloc.destroy(self);
    }

    fn run(self: *Job) void {
        defer self.free();
        const r = self.fetch() catch Reading{};
        result = r;
        phase.store(kReady, .release);
    }

    fn fetch(self: *Job) !Reading {
        var lat_buf: [32]u8 = undefined;
        var lon_buf: [32]u8 = undefined;
        var city_enc: [256]u8 = undefined;
        var label: [72]u8 = undefined;

        var lat: []const u8 = self.lat;
        var lon: []const u8 = self.lon;
        var place: []const u8 = "";

        if (lat.len == 0 or lon.len == 0) {
            // Both endpoints are resolved inside the scopes that own their
            // replies; only the formatted degrees and the composed label
            // survive, and both live in this frame.
            const g = try resolve(self.alloc, self.io, self.city, &city_enc, &label);
            lat = try std.fmt.bufPrint(&lat_buf, "{d:.4}", .{g.lat});
            lon = try std.fmt.bufPrint(&lon_buf, "{d:.4}", .{g.lon});
            place = g.name;
        }

        var url_buf: [512]u8 = undefined;
        const url = try buildForecastUrl(&url_buf, lat, lon, self.fahrenheit);
        const body = try bing.fetchText(self.alloc, self.io, url, kMaxReply);
        defer self.alloc.free(body);
        const s = try parseForecast(self.alloc, body);

        var out: Reading = .{
            .available = true,
            .temp = @as(i32, @intFromFloat(@round(s.temp))),
            .fahrenheit = self.fahrenheit,
            .glyph = glyphForCode(s.code),
            .hi = s.hi(),
            .lo = s.lo(),
            .feels_like = @intFromFloat(@round(s.feels_like)),
            .humidity_pct = @intFromFloat(@round(s.humidity)),
            .wind_kmh = @intFromFloat(@round(s.wind_kmh)),
            .visibility_m = @intFromFloat(@round(s.visibility_m)),
            .is_day = s.is_day,
            .days = s.days,
            .n_days = s.n_days,
        };
        out.placeCondition(conditionForCode(s.code));
        if (place.len == 0) place = self.city;
        out.place(place);
        return out;
    }
};

/// `geocode_city_open_meteo` when a city is configured, the `ipapi.co`
/// lookup when it is not. The
/// reply is freed before this returns, so the label is composed into
/// `label` and `Geo.name` borrows from there.
fn resolve(
    alloc: std.mem.Allocator,
    io: std.Io,
    city: []const u8,
    city_enc: *[256]u8,
    label: *[72]u8,
) !Geo {
    if (city.len > 0) {
        const enc = try percentEncode(city_enc, city);
        var url_buf: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buf,
            "https://geocoding-api.open-meteo.com/v1/search?name={s}&count=1&language=en&format=json",
            .{enc},
        );
        const body = try bing.fetchText(alloc, io, url, kMaxReply);
        defer alloc.free(body);
        const g = try parseGeocode(alloc, body, label);
        if (!g.ok) return error.NoGeocode;
        return g;
    }
    const body = try bing.fetchText(alloc, io, "https://ipapi.co/json/", kMaxReply);
    defer alloc.free(body);
    const g = try parseIp(alloc, body, label);
    if (!g.ok) return error.NoIpGeocode;
    return g;
}

const GeoResult = struct {
    latitude: f64 = 0,
    longitude: f64 = 0,
    name: []const u8 = "",
    country: []const u8 = "",
    admin1: []const u8 = "",
};

const GeoReply = struct {
    results: []const GeoResult = &.{},
};

const IpReply = struct {
    latitude: f64 = 0,
    longitude: f64 = 0,
    city: []const u8 = "",
    @"error": bool = false,
};

/// The `current` block of an Open-Meteo forecast reply, plus the daily arrays
/// the weather card's forecast columns read. Every field is optional in the
/// reply — Open-Meteo answers `null` for anything it could not measure — so
/// the arrays are `?f64` and a hole simply becomes a zero.
const Forecast = struct {
    const Current = struct {
        temperature_2m: f64 = 0,
        apparent_temperature: f64 = 0,
        relative_humidity_2m: f64 = 0,
        weather_code: i32 = 0,
        wind_speed_10m: f64 = 0,
        visibility: f64 = 0,
        is_day: i32 = 1,
    };
    const Daily = struct {
        time: []const []const u8 = &.{},
        weather_code: []const ?f64 = &.{},
        temperature_2m_max: []const ?f64 = &.{},
        temperature_2m_min: []const ?f64 = &.{},
    };
    current: Current = .{},
    daily: Daily = .{},
};

/// Everything the fetch pulls out of one reply. POD, so `Job.fetch` can hand
/// it straight to a `Reading`.
pub const Sample = struct {
    temp: f64 = 0,
    code: i32 = 0,
    feels_like: f64 = 0,
    humidity: f64 = 0,
    wind_kmh: f64 = 0,
    visibility_m: f64 = 0,
    is_day: bool = true,
    days: [5]Day = @splat(.{}),
    n_days: u8 = 0,

    /// Today's range, taken from the first forecast column.
    pub fn hi(self: *const Sample) i32 {
        return if (self.n_days > 0) self.days[0].hi else 0;
    }

    pub fn lo(self: *const Sample) i32 {
        return if (self.n_days > 0) self.days[0].lo else 0;
    }
};

/// The first (and only, `count=1`) result, with its label composed from
/// admin area and country, so two "Springfield"s stay
/// distinguishable.
pub fn parseGeocode(alloc: std.mem.Allocator, text: []const u8, label: []u8) !Geo {
    var parsed = try std.json.parseFromSlice(GeoReply, alloc, text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (parsed.value.results.len == 0) return .{};
    const r = parsed.value.results[0];
    return .{
        .ok = true,
        .lat = r.latitude,
        .lon = r.longitude,
        .name = composeLabel(label, r.name, r.admin1, r.country),
    };
}

/// `city, admin` when both are known, `city, country` when only the country
/// is, otherwise just whichever piece exists. Truncation is preferred over
/// failure: the label is a tooltip, not a key.
fn composeLabel(label: []u8, name: []const u8, admin1: []const u8, country: []const u8) []const u8 {
    const second = if (admin1.len > 0) admin1 else country;
    const first = if (name.len > 0) name else second;
    if (name.len == 0) return copyInto(label, first);
    if (second.len == 0) return copyInto(label, name);
    var i = copyInto(label, name).len;
    if (i + 2 <= label.len) {
        label[i] = ',';
        label[i + 1] = ' ';
        i += 2;
        i += copyInto(label[i..], second).len;
    }
    return label[0..i];
}

fn copyInto(dst: []u8, src: []const u8) []const u8 {
    const n = @min(src.len, dst.len);
    if (n > 0) @memcpy(dst[0..n], src[0..n]);
    return dst[0..n];
}

/// The `ipapi.co` reply. Its rate-limit payload is `{"error":true,...}`,
/// which lands as `ok == false`, as does an all-zero position.
pub fn parseIp(alloc: std.mem.Allocator, text: []const u8, label: []u8) !Geo {
    var parsed = try std.json.parseFromSlice(IpReply, alloc, text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const v = parsed.value;
    if (v.@"error" or (v.latitude == 0 and v.longitude == 0)) return .{};
    return .{
        .ok = true,
        .lat = v.latitude,
        .lon = v.longitude,
        .name = copyInto(label, v.city),
    };
}

/// The date half of one forecast column. Open-Meteo writes `daily.time` as
/// `YYYY-MM-DD` in the *location's* timezone (hence `timezone=auto`), so the
/// weekday comes straight off the string and needs no clock of our own.
fn parseIsoDate(s: []const u8) ?struct { year: i32, month: u8, day: u8 } {
    if (s.len < 10) return null;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    return .{ .year = year, .month = month, .day = day };
}

/// The `current` block and the first five days of an Open-Meteo forecast
/// reply.
pub fn parseForecast(alloc: std.mem.Allocator, text: []const u8) !Sample {
    var parsed = try std.json.parseFromSlice(Forecast, alloc, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const cur = parsed.value.current;
    var out: Sample = .{
        .temp = cur.temperature_2m,
        .code = cur.weather_code,
        .feels_like = cur.apparent_temperature,
        .humidity = cur.relative_humidity_2m,
        .wind_kmh = cur.wind_speed_10m,
        .visibility_m = cur.visibility,
        .is_day = cur.is_day != 0,
    };
    const d = parsed.value.daily;
    const n = @min(@min(d.time.len, d.weather_code.len), @min(d.temperature_2m_max.len, d.temperature_2m_min.len));
    var i: usize = 0;
    while (i < n and out.n_days < out.days.len) : (i += 1) {
        const code: i32 = @intFromFloat(@round(d.weather_code[i] orelse @as(f64, 0)));
        var day = Day{
            .glyph = glyphForCode(code),
            .hi = @intFromFloat(@round(d.temperature_2m_max[i] orelse @as(f64, 0))),
            .lo = @intFromFloat(@round(d.temperature_2m_min[i] orelse @as(f64, 0))),
        };
        if (parseIsoDate(d.time[i])) |dt| day.wday = cal_math.weekday(dt.year, dt.month, dt.day);
        out.days[out.n_days] = day;
        out.n_days += 1;
    }
    return out;
}

/// `latitude`/`longitude`/`current` — the two degree values are echoed back
/// as text, so a caller that just resolved
/// them can hand over its scratch buffer. `daily` and `timezone=auto` are
/// what turn one reply into the card's five forecast columns.
pub fn buildForecastUrl(
    buf: []u8,
    lat: []const u8,
    lon: []const u8,
    fahrenheit: bool,
) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "https://api.open-meteo.com/v1/forecast?latitude={s}&longitude={s}" ++
            "&current=temperature_2m,apparent_temperature,relative_humidity_2m," ++
            "weather_code,wind_speed_10m,visibility,is_day" ++
            "&daily=weather_code,temperature_2m_max,temperature_2m_min" ++
            "&forecast_days=5&timezone=auto{s}",
        .{ lat, lon, if (fahrenheit) "&temperature_unit=fahrenheit" else "" },
    );
}

/// RFC 3986 unreserved characters pass through; everything else becomes
/// `%XX`. A city name is the only free-form input any of these URLs take.
pub fn percentEncode(buf: []u8, s: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var i: usize = 0;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-_.~", ch) != null) {
            if (i >= buf.len) return error.NoSpace;
            buf[i] = ch;
            i += 1;
        } else {
            if (i + 3 > buf.len) return error.NoSpace;
            buf[i] = '%';
            buf[i + 1] = hex[ch >> 4];
            buf[i + 2] = hex[ch & 15];
            i += 3;
        }
    }
    return buf[0..i];
}

test "weather: WMO codes map to the glyph table" {
    const t = std.testing;
    try t.expectEqualStrings("sunny", glyphForCode(0));
    try t.expectEqualStrings("partly_cloudy_day", glyphForCode(1));
    try t.expectEqualStrings("cloud", glyphForCode(3));
    try t.expectEqualStrings("foggy", glyphForCode(45));
    try t.expectEqualStrings("rainy", glyphForCode(65));
    try t.expectEqualStrings("rainy", glyphForCode(81));
    try t.expectEqualStrings("weather_snowy", glyphForCode(75));
    try t.expectEqualStrings("thunderstorm", glyphForCode(96));
    try t.expectEqualStrings("cloud", glyphForCode(42));
}

test "weather: percent encoding leaves unreserved bytes alone" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("New%20York", try percentEncode(&buf, "New York"));
    try t.expectEqualStrings("s%C3%A3o-paulo", try percentEncode(&buf, "s\xC3\xA3o-paulo"));
    try t.expectEqualStrings("Bonn", try percentEncode(&buf, "Bonn"));
}

test "weather: forecast reply parses" {
    const t = std.testing;
    const body =
        \\{"latitude":52.5,"longitude":13.4,"timezone":"GMT",
        \\"current":{"time":"2025-01-01T12:00","interval":900,
        \\"temperature_2m":7.4,"weather_code":61}}
    ;
    const s = try parseForecast(t.allocator, body);
    try t.expectApproxEqAbs(@as(f64, 7.4), s.temp, 0.0001);
    try t.expectEqual(@as(i32, 61), s.code);
    try t.expectEqualStrings("rainy", glyphForCode(s.code));
    try t.expectEqualStrings("Light rain", conditionForCode(s.code));
    // Nothing else was asked for, so the detail stays at its defaults.
    try t.expectEqual(@as(u8, 0), s.n_days);
    try t.expect(s.is_day);
}

test "weather: the detail reply feeds the card and its five columns" {
    const t = std.testing;
    const body =
        \\{"latitude":52.5,"longitude":13.4,"utc_offset_seconds":7200,
        \\"timezone":"Europe/Berlin",
        \\"current":{"time":"2026-10-13T14:00","interval":900,
        \\"temperature_2m":17.2,"apparent_temperature":15.9,
        \\"relative_humidity_2m":71.0,"weather_code":3,
        \\"wind_speed_10m":12.4,"visibility":24000.0,"is_day":1},
        \\"daily":{"time":["2026-10-13","2026-10-14","2026-10-15"],
        \\"weather_code":[3,61,80],
        \\"temperature_2m_max":[19.4,14.2,12.8],
        \\"temperature_2m_min":[9.1,7.6,4.3]}}
    ;
    const s = try parseForecast(t.allocator, body);
    try t.expectEqual(@as(i32, 17), @as(i32, @intFromFloat(@round(s.temp))));
    try t.expectEqual(@as(i32, 16), @as(i32, @intFromFloat(@round(s.feels_like))));
    try t.expectEqual(@as(i32, 71), @as(i32, @intFromFloat(@round(s.humidity))));
    try t.expectEqual(@as(i32, 12), @as(i32, @intFromFloat(@round(s.wind_kmh))));
    try t.expectEqual(@as(i32, 24000), @as(i32, @intFromFloat(@round(s.visibility_m))));
    try t.expect(s.is_day);
    try t.expectEqual(@as(i32, 19), s.hi());
    try t.expectEqual(@as(i32, 9), s.lo());

    try t.expectEqual(@as(u8, 3), s.n_days);
    try t.expectEqualStrings("cloud", s.days[0].glyph);
    try t.expectEqualStrings("rainy", s.days[1].glyph);
    try t.expectEqual(@as(i32, 14), s.days[1].hi);
    try t.expectEqual(@as(i32, 4), s.days[2].lo);
    // 2026-10-13 is a Tuesday, which is what the column has to say.
    try t.expectEqual(@as(u8, 2), s.days[0].wday);
    try t.expectEqual(@as(u8, 3), s.days[1].wday);
}

test "weather: a reply with holes in the daily arrays still parses" {
    const t = std.testing;
    const body =
        \\{"current":{"temperature_2m":1.0,"weather_code":71,"is_day":0},
        \\"daily":{"time":["2026-01-05","2026-01-06"],
        \\"weather_code":[71,null],
        \\"temperature_2m_max":[-1.2,null],
        \\"temperature_2m_min":[-6.8,null]}}
    ;
    const s = try parseForecast(t.allocator, body);
    try t.expect(!s.is_day);
    try t.expectEqual(@as(u8, 2), s.n_days);
    // A hole decodes as code 0 / zero degrees rather than failing the reply.
    try t.expectEqualStrings("sunny", s.days[1].glyph);
    try t.expectEqual(@as(i32, 0), s.days[1].hi);
    try t.expectEqual(@as(i32, -1), s.days[0].hi);
    try t.expectEqual(@as(u8, 1), s.days[0].wday);
}

test "weather: every WMO code has a wording" {
    const t = std.testing;
    try t.expectEqualStrings("Clear", conditionForCode(0));
    try t.expectEqualStrings("Overcast", conditionForCode(3));
    try t.expectEqualStrings("Thunderstorm with heavy hail", conditionForCode(99));
    // Anything outside the table says so rather than showing a blank.
    try t.expectEqualStrings("Unknown", conditionForCode(7));
    try t.expect(conditionForCode(1234).len > 0);
}

test "weather: geocode reply composes the locality label" {
    const t = std.testing;
    const body =
        \\{"results":[{"latitude":52.52,"longitude":13.405,
        \\"name":"Berlin","country":"Germany","admin1":"Berlin"}]}
    ;
    var label: [72]u8 = undefined;
    const g = try parseGeocode(t.allocator, body, &label);
    try t.expect(g.ok);
    try t.expectApproxEqAbs(@as(f64, 52.52), g.lat, 0.0001);
    try t.expectEqualStrings("Berlin, Berlin", g.name);

    const bare =
        \\{"results":[{"latitude":1.0,"longitude":2.0,"name":"Nowhere"}]}
    ;
    const g2 = try parseGeocode(t.allocator, bare, &label);
    try t.expect(g2.ok);
    try t.expectEqualStrings("Nowhere", g2.name);

    const empty = try parseGeocode(t.allocator, "{}", &label);
    try t.expect(!empty.ok);
}

test "weather: ip lookup rejects the error payload" {
    const t = std.testing;
    var label: [72]u8 = undefined;
    const g = try parseIp(t.allocator, "{\"error\":true,\"reason\":\"RateLimited\"}", &label);
    try t.expect(!g.ok);
    const ok = try parseIp(t.allocator, "{\"latitude\":1.5,\"longitude\":2.5,\"city\":\"Lisbon\"}", &label);
    try t.expect(ok.ok);
    try t.expectEqualStrings("Lisbon", ok.name);
}

test "weather: forecast url carries the unit only when asked" {
    const t = std.testing;
    var buf: [512]u8 = undefined;
    const c = try buildForecastUrl(&buf, "52.5", "13.4", false);
    try t.expect(std.mem.indexOf(u8, c, "temperature_unit") == null);
    try t.expect(std.mem.indexOf(u8, c, "latitude=52.5") != null);
    const f = try buildForecastUrl(&buf, "52.5", "13.4", true);
    try t.expect(std.mem.indexOf(u8, f, "temperature_unit=fahrenheit") != null);
}

test "weather: reading is copyable across threads" {
    const t = std.testing;
    var a: Reading = .{ .available = true, .temp = -3, .glyph = "weather_snowy" };
    a.place("Reykjav\xC3\xADk");
    var b: Reading = undefined;
    b = a;
    try t.expect(b.available);
    try t.expectEqual(@as(i32, -3), b.temp);
    try t.expectEqualStrings("Reykjav\xC3\xADk", b.placeName());
    try t.expectEqualStrings("weather_snowy", b.glyph);
}

test "weather: nothing is drained before a worker publishes" {
    reset();
    var out: Reading = .{};
    try std.testing.expect(!take(&out));
    try std.testing.expect(idle());
}
