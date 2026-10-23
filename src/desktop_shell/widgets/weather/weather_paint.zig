//! Weather dock slot: width, paint, and shared measurement.
//!
//! What could not come across verbatim, and why:
//!
//! * **Weather state.** The reading comes out
//!   of the weather fetch service, which that call starts lazily. The Zig
//!   shell has no weather service yet, so the reading lives in the `pub var
//!   state` below and **the host fills it in** (see `State` / `weatherState`).
//! * **`weather_unit`.** The service derives `fahrenheit` from the
//!   per-instance setting on every read. `weatherState` applies the setting
//!   the same way (lower-cased, `"f"` / `"fahrenheit"`); when the setting is
//!   absent it falls back to the host's own `fahrenheit`, because here the
//!   reading is the only other source for the flag.
//! * **Glyphs.** The Material Symbols font is gone from the Zig shell:
//!   every weather icon name (`sunny`, `rainy`, …) resolves to a vendored
//!   Lucide SVG through the shared bank, so the old fontconfig
//!   registration has no counterpart and the glyph cache lives in the SVG
//!   renderer.
//! * **`derived_chrome_colors(sc.appearance).accent*`.** Read off the shared
//!   `chrome_colors.of` port, which now carries all four branches (custom,
//!   horizon-native, matugen, defaults).
//! * **Text cache** is unbounded upstream. It is a
//!   fixed 8-entry table here; a full table evicts round-robin, and the key is
//!   truncated at 64 bytes (widget ids are far shorter).

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const schema = @import("../../../config/schema.zig");
const pill = @import("../shared/pill.zig");
const chrome_colors = @import("../shared/chrome_colors.zig");
const wset = @import("../shared/widget_settings.zig");
const measure = @import("../shared/measure_scratch.zig");
const tokens = @import("../../../m3/tokens.zig");
const dock_widgets = @import("../../dock/widgets.zig");
const svg_icons = @import("../../../ux/shared/svg_icons.zig");

// The reading

/// The weather state subset this paint reads:
/// `available`, `temp`, `fahrenheit`, `icon`. Everything else the struct
/// carries (location, humidity, forecast …) never reaches this file, so it is
/// deliberately not modelled.
pub const State = struct {
    /// No reading yet — the slot shows "--" and dims.
    available: bool = false,
    /// Integer temperature in the unit the reading was fetched in.
    temp: i32 = 0,
    /// Which letter goes in the unit pill, "F" or "C".
    fahrenheit: bool = false,
    /// Glyph name ("sunny", "rainy", …), resolved to a Lucide SVG by the
    /// paint path. Borrowed from the host, which must keep it alive; empty
    /// falls back to "cloud".
    icon: []const u8 = "",
};

/// The reading every weather slot paints until a Zig weather service exists.
/// The host fills this before painting; nothing in this module writes it.
pub var state: State = .{};

/// `control_center_weather_state(sc, instance_id)` — the reading, with the
/// per-instance `weather_unit` widget setting applied the same way:
/// lower-cased, `"f"` / `"fahrenheit"` mean
/// Fahrenheit and anything else means Celsius. When the setting is absent the
/// host's own `fahrenheit` stands, because here the reading is the only other
/// source for the flag.
pub fn weatherState(cfg: *const schema.ShellConfig, instance_id: []const u8) State {
    var out = state;
    const raw = wset.widgetSetting(cfg, instance_id, "weather_unit");
    if (raw.len == 0) return out;
    var buf: [16]u8 = undefined;
    if (raw.len > buf.len) {
        // Longer than "fahrenheit" itself, so it can never match.
        out.fahrenheit = false;
        return out;
    }
    const lowered = std.ascii.lowerString(&buf, raw);
    out.fahrenheit = std.mem.eql(u8, lowered, "f") or std.mem.eql(u8, lowered, "fahrenheit");
    return out;
}

// Small helpers

/// `static_cast<int>(px)` — pango and the cache store whole pixels.
fn truncToInt(px: f64) i32 {
    return @intFromFloat(@trunc(px));
}

/// `"Inter Medium <rounded px>"` — pango reads
/// the trailing number as the size and the rest as the family name.
fn mediumFont(buf: []u8, font_px: f64) []const u8 {
    const s = std.fmt.bufPrint(buf, "Inter Medium {d}", .{truncToInt(font_px)}) catch return "Inter Medium 13";
    return s;
}

/// `weatherTempDisplay` — "--" without a reading, otherwise the integer
/// temperature followed by U+00B0. The unit letter lives in the pill, so it
/// is deliberately *not* appended here (which is why `weather.zig`'s
/// `formatTemp`, that does append it, is not used).
fn weatherTempDisplay(buf: []u8, ws: State) []const u8 {
    if (!ws.available) return "--";
    const s = std.fmt.bufPrint(buf, "{d}°", .{ws.temp}) catch return "--";
    return s;
}

/// Clamped via the dock's shared `clampf`, which degrades to `lo` when
/// `lo > hi` (reachable here: a tall minimum against a short bar) instead of
/// asserting the way `std.math.clamp` would.
const clampf = dock_widgets.clampf;

/// `make_layout` — a pango layout for `cr` carrying the font description and
/// `PANGO_WRAP_WORD_CHAR`, always set. The caller owns the
/// result and releases it through `text.Layout.destroy` or
/// `text.Layout.release`.
fn makeLayout(cr: ?*cairo.cairo_t, font_desc: []const u8) text.Layout {
    var l = text.Layout.createForCairo(cr);
    l.setFont(font_desc);
    l.setWrap(text.WRAP_WORD_CHAR);
    return l;
}

// `g_weatherTextCache`

/// Text-measurement cache —
/// pixel sizes plus the two persistent pango layouts, one entry per widget
/// instance. Fixed capacity instead of an unbounded map: the shell has a
/// handful of weather slots, and a full table evicts round-robin.
const max_text_cache = 8;

const TextCache = struct {
    used: bool = false,
    id: [64]u8 = undefined,
    id_len: usize = 0,
    temp: [16]u8 = undefined,
    temp_len: usize = 0,
    /// 0 until the entry has been written, else 'F' or 'C'.
    unit: u8 = 0,
    temp_w: c_int = 0,
    temp_h: c_int = 0,
    unit_w: c_int = 0,
    unit_h: c_int = 0,
    temp_font_px: f64 = 0,
    unit_font_px: f64 = 0,
    temp_layout: ?*text.PangoLayout = null,
    unit_layout: ?*text.PangoLayout = null,

    fn idSlice(self: *const TextCache) []const u8 {
        return self.id[0..self.id_len];
    }

    /// The cache hit test `it->second.tempStr == tempStr && … .unit == unit`.
    fn matches(self: *const TextCache, temp_str: []const u8, unit: u8) bool {
        if (!self.used or self.unit != unit) return false;
        return std.mem.eql(u8, self.temp[0..self.temp_len], temp_str);
    }

    /// Claiming a slot: the map key lives with the entry.
    fn adopt(self: *TextCache, instance_id: []const u8) void {
        const n = @min(instance_id.len, self.id.len);
        @memcpy(self.id[0..n], instance_id[0..n]);
        self.id_len = n;
        self.used = true;
    }

    /// The `g_weatherTextCache[kid] = {…}` write at the bottom of
    /// `weather_layout_inner`. The layouts are untouched: paint owns them.
    fn setReading(self: *TextCache, temp_str: []const u8, unit: u8) void {
        const n = @min(temp_str.len, self.temp.len);
        @memcpy(self.temp[0..n], temp_str[0..n]);
        self.temp_len = n;
        self.unit = unit;
    }

    /// Dropping an entry — the `~WeatherTextCache` destructor.
    fn release(self: *TextCache) void {
        text.Layout.release(self.temp_layout);
        text.Layout.release(self.unit_layout);
        self.temp_layout = null;
        self.unit_layout = null;
        self.used = false;
        self.id_len = 0;
        self.temp_len = 0;
        self.unit = 0;
        self.temp_w = 0;
        self.temp_h = 0;
        self.unit_w = 0;
        self.unit_h = 0;
        self.temp_font_px = 0;
        self.unit_font_px = 0;
    }
};

var g_text_cache = @as([max_text_cache]TextCache, @splat(.{}));
var g_next_slot: usize = 0;

/// `g_weatherTextCache.find(kid)` — never inserts, so a measurement pass that
/// cannot measure leaves the table alone.
fn findEntry(instance_id: []const u8) ?*TextCache {
    for (0..max_text_cache) |i| {
        const e = &g_text_cache[i];
        if (!e.used) continue;
        if (std.mem.eql(u8, e.idSlice(), instance_id)) return e;
    }
    return null;
}

/// `g_weatherTextCache[kid]` — the entry for `instance_id`, taking a free
/// slot or, when the table is full, evicting round-robin
/// without bound).
fn entryFor(instance_id: []const u8) *TextCache {
    if (findEntry(instance_id)) |e| return e;
    var slot: ?usize = null;
    for (0..max_text_cache) |i| {
        if (!g_text_cache[i].used) {
            slot = i;
            break;
        }
    }
    const idx = slot orelse blk: {
        const i = g_next_slot;
        g_next_slot = (g_next_slot + 1) % max_text_cache;
        break :blk i;
    };
    g_text_cache[idx].release();
    g_text_cache[idx].adopt(instance_id);
    return &g_text_cache[idx];
}

// `weather_layout_inner`

/// The five out-parameters of `weather_layout_inner`.
const WeatherLayout = struct {
    icon_px: f64 = 0,
    gap1: f64 = 0,
    temp_w: f64 = 0,
    pill_w: f64 = 0,
    pill_h: f64 = 0,
};

/// `weather_layout_inner` — icon size, gap, temperature width and unit-pill
/// box for one weather slot, measured through `measure_cr` (or the shared
/// scratch context when it is null) and served from `g_weatherTextCache` when
/// the reading has not changed.
fn weatherLayoutInner(
    measure_cr: ?*cairo.cairo_t,
    instance_id: []const u8,
    icon_ref_px: f64,
    ws: State,
    out: *WeatherLayout,
) void {
    const mcr = if (measure_cr) |c| c else measure.measureCr();

    const font_px = clampf(icon_ref_px * 0.38, 11.0, 15.0);
    out.icon_px = std.math.round(clampf(icon_ref_px * 0.42, 13.0, 18.0));
    out.gap1 = @max(3.0, std.math.round(icon_ref_px * 0.09));

    var tbuf: [16]u8 = undefined;
    const temp_str = weatherTempDisplay(&tbuf, ws);
    const unit_str: []const u8 = if (ws.fahrenheit) "F" else "C";
    const unit: u8 = unit_str[0];

    // Cache hit: the unit pill's height and width come straight from the
    // stored measurement, and nothing is measured again.
    if (findEntry(instance_id)) |e| {
        if (e.matches(temp_str, unit)) {
            out.temp_w = @floatFromInt(e.temp_w);
            const pill_font = @max(8.0, std.math.round(font_px * 0.72));
            out.pill_h = @max(14.0, pill_font + 4.0);
            out.pill_w = @as(f64, @floatFromInt(e.unit_w)) + std.math.round(@max(4.0, font_px * 0.35)) * 2.0;
            return;
        }
    }

    out.temp_w = 36.0;
    var temp_h: c_int = 0;
    if (mcr) |cr| {
        var fbuf: [32]u8 = undefined;
        var l = makeLayout(cr, mediumFont(&fbuf, font_px));
        defer l.destroy();
        l.setText(temp_str);
        const sz = l.pixelSize();
        out.temp_w = @floatFromInt(sz.w);
        temp_h = sz.h;
    }

    const pill_font = @max(8.0, std.math.round(font_px * 0.72));
    out.pill_h = @max(14.0, pill_font + 4.0);
    out.pill_w = 18.0;
    var unit_h: c_int = 0;
    if (mcr) |cr| {
        var fbuf: [32]u8 = undefined;
        var l = makeLayout(cr, mediumFont(&fbuf, pill_font));
        defer l.destroy();
        l.setText(unit_str);
        const sz = l.pixelSize();
        out.pill_w = @as(f64, @floatFromInt(sz.w)) + std.math.round(@max(4.0, font_px * 0.35)) * 2.0;
        unit_h = sz.h;
    }

    // Only a real context stores measurements.
    if (mcr != null) {
        const pad = std.math.round(@max(4.0, font_px * 0.35));
        const e = entryFor(instance_id);
        e.setReading(temp_str, unit);
        e.temp_w = truncToInt(out.temp_w);
        e.temp_h = temp_h;
        e.unit_w = truncToInt(out.pill_w - pad * 2.0);
        e.unit_h = unit_h;
    }
}

/// The measured inner run — `icon_px + gap1 + temp_w + gap1 + pill_w` — that
/// `dock_weather_slot_width` pads out to a full slot. The dock feeds this into
/// `dock.widgets.Measured.weather_inner` so the strip's width pass and the
/// paint pass agree on how wide the slot has to be.
pub fn weatherInnerWidth(
    measure_cr: ?*cairo.cairo_t,
    cfg: *const schema.ShellConfig,
    instance_id: []const u8,
    icon_ref_px: f64,
) f64 {
    var inner = WeatherLayout{};
    weatherLayoutInner(measure_cr, instance_id, icon_ref_px, weatherState(cfg, instance_id), &inner);
    return inner.icon_px + inner.gap1 + inner.temp_w + inner.gap1 + inner.pill_w;
}

// `dock_weather_slot_width`

/// `dock_weather_slot_width` — the slot's wanted width: the inner run plus
/// 10 px of padding on each side, clamped between `max(icon_ref_px * 1.25, 72)`
/// and `min(bar_height * 6, 220)`.
pub fn dockWeatherSlotWidth(
    measure_cr: ?*cairo.cairo_t,
    cfg: *const schema.ShellConfig,
    instance_id: []const u8,
    icon_ref_px: f64,
    bar_height: f64,
) f64 {
    const mcr = if (measure_cr) |c| c else measure.measureCr();
    const ws = weatherState(cfg, instance_id);

    var inner = WeatherLayout{};
    weatherLayoutInner(mcr, instance_id, icon_ref_px, ws, &inner);

    const content = inner.icon_px + inner.gap1 + inner.temp_w + inner.gap1 + inner.pill_w;
    const pad_x = 10.0;
    const min_w = @max(icon_ref_px * 1.25, 72.0);
    const max_cap = @min(bar_height * 6.0, 220.0);
    return clampf(content + pad_x * 2.0, min_w, max_cap);
}

// `paint_weather_slot`

/// `derived_chrome_colors(sc.appearance).accent*` — the only colour this paint
/// reads, via the shared port (which now carries the horizon/matugen branches
/// too).

/// `paint_weather_slot` — pill, weather glyph, temperature and the unit pill.
///
/// `hovered` / `pressed` are part of the signature but discarded
/// too (`(void)hovered; (void)pressed;`): the pill fill does not change under
/// the pointer, only the accent wash does, and painting that is the dock's
/// job. A null `cr` is a no-op, matching every other
/// paint entry point in this shell.
pub fn paintWeatherSlot(
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

    const ws = weatherState(cfg, instance_id);
    var inner = WeatherLayout{};
    weatherLayoutInner(null, instance_id, icon_ref_px, ws, &inner);

    cairo.cairo_save(c);
    pill.paintPill(c, x, y, slot_w, slot_h);

    const content_w = inner.icon_px + inner.gap1 + inner.temp_w + inner.gap1 + inner.pill_w;
    const pad_x = (slot_w - content_w) * 0.5;
    const base_x = x + @max(6.0, pad_x);
    const cy = y + slot_h * 0.5;

    const glyph: []const u8 = if (ws.icon.len > 0) ws.icon else "cloud";
    const g_alpha: f64 = if (ws.available) 0.92 else 0.45;
    // `derived_chrome_colors(sc.appearance).accent*`.
    const accent = chrome_colors.of(cfg).accent;
    const gcx = base_x + inner.icon_px * 0.5;
    // Every weather glyph resolves through the Lucide bank; an unmapped
    // name simply paints nothing.
    _ = svg_icons.draw(c, glyph, gcx, cy, inner.icon_px, accent.r, accent.g, accent.b, g_alpha, false);

    const font_px = clampf(icon_ref_px * 0.38, 11.0, 15.0);
    var fbuf: [32]u8 = undefined;
    const fd = mediumFont(&fbuf, font_px);
    var tbuf: [16]u8 = undefined;
    const temp_str = weatherTempDisplay(&tbuf, ws);
    const unit_str: []const u8 = if (ws.fahrenheit) "F" else "C";
    const unit: u8 = unit_str[0];

    const e = entryFor(instance_id);
    if (e.temp_layout == null or e.temp_font_px != font_px) {
        text.Layout.release(e.temp_layout);
        // The layout's ownership moves into the cache entry.
        e.temp_layout = makeLayout(c, fd).layout;
        e.temp_font_px = font_px;
    } else {
        text.pango_cairo_update_layout(c, e.temp_layout);
    }

    var temp_layout = text.Layout{ .layout = e.temp_layout };
    temp_layout.setText(temp_str);
    temp_layout.setAlignment(text.ALIGN_LEFT);
    var tw: c_int = 0;
    var th: c_int = 0;
    if (e.matches(temp_str, unit)) {
        tw = e.temp_w;
        th = e.temp_h;
    } else {
        const sz = temp_layout.pixelSize();
        tw = sz.w;
        th = sz.h;
    }
    const tx = base_x + inner.icon_px + inner.gap1;
    const ty = y + (slot_h - @as(f64, @floatFromInt(th))) * 0.5;
    const text_alpha: f64 = if (ws.available) 1.0 else 0.55;
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, text_alpha);
    cairo.cairo_move_to(c, tx, ty);
    temp_layout.show(c);

    // The unit pill: a 10 % white stadium with the letter centred in it.
    const pill_x = tx + @as(f64, @floatFromInt(tw)) + inner.gap1;
    const pill_y = y + (slot_h - inner.pill_h) * 0.5;
    const pill_r = inner.pill_h * 0.5;
    const half_pi = std.math.pi / 2.0;
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, pill_x + inner.pill_w - pill_r, pill_y + pill_r, pill_r, -half_pi, half_pi);
    cairo.cairo_arc(c, pill_x + pill_r, pill_y + pill_r, pill_r, half_pi, 3.0 * half_pi);
    cairo.cairo_close_path(c);
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.10);
    cairo.cairo_fill(c);

    const pill_font = @max(8.0, std.math.round(font_px * 0.72));
    var ubuf: [32]u8 = undefined;
    const fd_u = mediumFont(&ubuf, pill_font);
    if (e.unit_layout == null or e.unit_font_px != pill_font) {
        text.Layout.release(e.unit_layout);
        e.unit_layout = makeLayout(c, fd_u).layout;
        e.unit_font_px = pill_font;
    } else {
        text.pango_cairo_update_layout(c, e.unit_layout);
    }

    var unit_layout = text.Layout{ .layout = e.unit_layout };
    unit_layout.setText(unit_str);
    var uw: c_int = 0;
    var uh: c_int = 0;
    if (e.matches(temp_str, unit)) {
        uw = e.unit_w;
        uh = e.unit_h;
    } else {
        const sz = unit_layout.pixelSize();
        uw = sz.w;
        uh = sz.h;
    }
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.90);
    cairo.cairo_move_to(
        c,
        pill_x + (inner.pill_w - @as(f64, @floatFromInt(uw))) * 0.5,
        pill_y + (inner.pill_h - @as(f64, @floatFromInt(uh))) * 0.5,
    );
    unit_layout.show(c);

    cairo.cairo_restore(c);
}

// Glyph helpers
//
// Every weather glyph name resolves through the shared Lucide bank
// (`ux/shared/svg_icons.zig`); the Material Symbols font is gone from the
// Zig shell, so the glyph cache lives in the SVG renderer and this module
// only forwards.

/// `draw_material_glyph` — the icon at `px`, centred on (`cx`, `cy`) and
/// tinted `r,g,b,a`. An unmapped name paints nothing.
fn drawMaterialGlyph(
    cr: ?*cairo.cairo_t,
    cx: f64,
    cy: f64,
    px: f64,
    ligature: []const u8,
    r: f64,
    g: f64,
    b: f64,
    a: f64,
) void {
    _ = svg_icons.draw(cr, ligature, cx, cy, px, r, g, b, a, false);
}

// Cache maintenance

/// Drops every cache this module owns: the pango layouts and measurements
/// behind `weather_layout_inner` (entries
/// only die with the process). `state` is the host's and is left alone;
/// the glyph surfaces belong to the shared SVG bank.
pub fn reset() void {
    for (0..max_text_cache) |i| {
        g_text_cache[i].release();
    }
    g_next_slot = 0;
}

// Tests

fn load(text_in: []const u8) !schema.Loaded {
    return schema.loadText(std.testing.allocator, text_in);
}

test "weather-paint: temp display shows dashes with no reading" {
    const t = std.testing;
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("--", weatherTempDisplay(&buf, .{}));
    // A reading that never arrived stays "--" whatever the temperature field says.
    try t.expectEqualStrings("--", weatherTempDisplay(&buf, .{ .available = false, .temp = 21 }));
    try t.expectEqualStrings("21°", weatherTempDisplay(&buf, .{ .available = true, .temp = 21 }));
    try t.expectEqualStrings("-4°", weatherTempDisplay(&buf, .{ .available = true, .temp = -4 }));
    // Even the widest i32 fits the buffer, so bufPrint never falls back.
    try t.expectEqualStrings(
        "-2147483648°",
        weatherTempDisplay(&buf, .{ .available = true, .temp = std.math.minInt(i32) }),
    );
}

test "weather-paint: weather_unit decides the flag" {
    const t = std.testing;
    var cfg = try load(
        \\[widget.weather]
        \\weather_unit = "F"
        \\[widget.other_weather]
        \\weather_unit = "celsius"
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    state = .{ .available = true, .temp = 21, .fahrenheit = false, .icon = "sunny" };
    defer state = .{};

    // The setting wins and is matched case-insensitively, like `lower_copy`.
    const w = weatherState(c, "weather");
    try t.expect(w.fahrenheit);
    try t.expect(w.available);
    try t.expectEqual(@as(i32, 21), w.temp);
    try t.expectEqualStrings("sunny", w.icon);
    // Anything that is not "f"/"fahrenheit" is Celsius.
    try t.expect(!weatherState(c, "other_weather").fahrenheit);
    // Without a setting the host's own flag stands.
    try t.expect(!weatherState(c, "no_such_widget").fahrenheit);
    state.fahrenheit = true;
    try t.expect(weatherState(c, "no_such_widget").fahrenheit);
    try t.expect(weatherState(c, "weather").fahrenheit);
    // An absurdly long value can never match either unit word.
    state.fahrenheit = false;
    var long_cfg = try load(
        \\[widget.weather]
        \\weather_unit = "fahrenheit_fahrenheit"
    );
    defer long_cfg.deinit();
    try t.expect(!weatherState(&long_cfg.cfg, "weather").fahrenheit);
}

test "weather-paint: text cache keys on instance id and reading" {
    const t = std.testing;
    reset();
    defer reset();

    const e = entryFor("weather");
    // Claimed but not yet written: `unit == 0` never matches 'C'.
    try t.expect(e.used);
    try t.expect(!e.matches("21°", 'C'));

    e.setReading("21°", 'C');
    try t.expect(e.matches("21°", 'C'));
    try t.expect(!e.matches("22°", 'C'));
    try t.expect(!e.matches("21°", 'F'));

    // A second instance id gets its own entry.
    const other = entryFor("dashboard_weather");
    try t.expect(other != e);
    try t.expect(!other.matches("21°", 'C'));

    // Entries are only written with whole pixels, as static_cast<int> is.
    e.temp_w = truncToInt(36.0);
    try t.expectEqual(@as(c_int, 36), e.temp_w);

    reset();
    try t.expect(!e.used);
    try t.expect(findEntry("weather") == null);
}

test "weather-paint: slot width clamps like dock_weather_slot_width" {
    const t = std.testing;
    var cfg = try load(
        \\[widget.weather]
        \\weather_unit = "C"
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    state = .{};
    defer state = .{};
    reset();
    defer reset();

    // A bar too short for the floor: maxCap (bar_h * 6 = 48) drops under the
    // 72 px minimum and the floor wins, the way clampf degrades to `lo`.
    try t.expectEqual(@as(f64, 72.0), dockWeatherSlotWidth(null, c, "weather", 44.0, 8.0));

    const w = dockWeatherSlotWidth(null, c, "weather", 44.0, 72.0);
    try t.expect(w >= 72.0 and w <= 220.0);
    // The measurement cache must not change the answer…
    try t.expectEqual(w, dockWeatherSlotWidth(null, c, "weather", 44.0, 72.0));
    // …and neither may dropping it.
    reset();
    try t.expectEqual(w, dockWeatherSlotWidth(null, c, "weather", 44.0, 72.0));

    // A real reading is measured at least as wide as the "--" placeholder.
    state = .{ .available = true, .temp = 21 };
    const reading = dockWeatherSlotWidth(null, c, "weather", 44.0, 72.0);
    try t.expect(reading >= w);
    try t.expect(reading <= 220.0);
}

test "weather-paint: weather glyphs resolve through the Lucide bank" {
    const t = std.testing;
    reset();
    defer reset();

    // Every WMO name a reading can carry is mapped; the fallback name used
    // when there is no reading is mapped too.
    const names = [_][]const u8{ "sunny", "foggy", "partly_cloudy_day", "rainy", "thunderstorm", "weather_snowy", "cloud", "cloud_off" };
    for (names) |n| {
        try t.expect(svg_icons.lucideName(n) != null);
    }
    try t.expect(svg_icons.lucideName("definitely-not-a-glyph") == null);

    // An empty ligature is a no-op on a live context.
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 32, 32);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    drawMaterialGlyph(cr, 16.0, 16.0, 18.0, "", 1.0, 1.0, 1.0, 1.0);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}

test "weather-paint: chrome accent follows derived_chrome_colors" {
    const t = std.testing;

    // The default branch: `derived_chrome_colors`' 0.90/0.90/0.90, which is
    // `Tokens.accent` (and what the un-touched appearance decodes to).
    var plain = try load("");
    defer plain.deinit();
    const a = chrome_colors.of(&plain.cfg).accent;
    try t.expectEqual(tokens.Tokens.accent, a);

    // The custom-theme branch: `customPrimary*`, only `_r` overridden here and
    // `apply_color_adjustment`'s inputs left at their 1.0 defaults.
    var custom = try load(
        \\[appearance]
        \\color_theme_enabled = true
        \\color_theme_primary_r = 0.5
    );
    defer custom.deinit();
    const b = chrome_colors.of(&custom.cfg).accent;
    const want_g: f32 = 0.659;
    const want_b: f32 = 0.941;
    try t.expectEqual(@as(f64, 0.5), b.r);
    try t.expectEqual(@as(f64, want_g), b.g);
    try t.expectEqual(@as(f64, want_b), b.b);
}

test "weather-paint: paints an available and an unavailable slot" {
    const t = std.testing;
    var cfg = try load(
        \\[widget.weather]
        \\weather_unit = "F"
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    state = .{ .available = true, .temp = 21, .icon = "sunny" };
    defer state = .{};
    reset();
    defer reset();

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 240, 56);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    const w = dockWeatherSlotWidth(null, c, "weather", 44.0, 72.0);
    paintWeatherSlot(cr, c, "weather", 8.0, 6.0, w, 44.0, 44.0, true, false);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // No reading, no icon: "--" plus the "cloud" fallback, pressed state.
    state = .{};
    paintWeatherSlot(cr, c, "weather", 8.0, 6.0, w, 44.0, 44.0, false, true);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // A second frame hits the cached layouts and the cached measurements.
    paintWeatherSlot(cr, c, "weather", 8.0, 6.0, w, 44.0, 44.0, false, false);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // A null context is a no-op rather than a crash.
    paintWeatherSlot(null, c, "weather", 0.0, 0.0, 10.0, 10.0, 44.0, false, false);
    drawMaterialGlyph(cr, 20.0, 20.0, 18.0, "", 1.0, 1.0, 1.0, 1.0);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}
