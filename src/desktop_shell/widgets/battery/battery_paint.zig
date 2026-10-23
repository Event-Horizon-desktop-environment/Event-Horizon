//! Battery dock slot (width + paint), the battery popup, and the widget
//! lifecycle hooks.
//!
//! What could not come across verbatim, and why:
//!
//! * **The UPower poll thread.** The earlier implementation owns a system-bus connection, three
//!   wake-up signal subscriptions and a 5 s `poll()` loop behind
//!   `battery_widget_init/poll/shutdown`. The Zig shell has no system-bus
//!   client behind the widgets — `services/upower.zig` only publishes the
//!   flat `Battery` view — so the polled snapshot lives in the `pub var
//!   state` below and **the host fills it in** (see `State`). The lifecycle
//!   functions keep their refcount contract and the `EH_BATTERY_DEBUG`
//!   override, so the developer knobs behave the same.
//! * **`ensure_material_symbols_font_registered`.** The Material Symbols
//!   font is no longer used anywhere in the Zig shell: every glyph name
//!   resolves to a vendored Lucide SVG through
//!   `common/material_glyph.zig`, so there is no family to register and the
//!   old helper is gone.
//! * **`derived_chrome_colors`.** Read off the shared `chrome_colors.of`
//!   port, which now carries all four branches (custom, horizon-native,
//!   matugen, defaults) including `apply_color_adjustment`.
//! * **The glyph surface cache in `draw_material_glyph`.** The Lucide SVG
//!   bank caches one raster per (icon, px) behind the shared
//!   `common/material_glyph.zig` draw, so this port keeps the cached-mask
//!   behaviour with none of the per-frame pango work.
//!
//! Per-level battery logic is **not** reimplemented here: `battery.zig`
//! owns `levelFor`/`iconName`/`timeRemainingMin` and this file reaches them
//! through `State.level()`, `State.themedIconName()` and
//! `State.timeRemaining()`.

const std = @import("std");
const stdlib = @import("c_stdlib");

const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const schema = @import("../../../config/schema.zig");
const pill = @import("../shared/pill.zig");
const chrome_colors = @import("../shared/chrome_colors.zig");
const wset = @import("../shared/widget_settings.zig");
const lcache = @import("../shared/layout_cache.zig");
const measure = @import("../shared/measure_scratch.zig");
const battery = @import("../battery.zig");
const helpers = @import("../../shared/cairo_helpers.zig");
const dock_widgets = @import("../../dock/widgets.zig");
const upower = @import("../../../services/upower.zig");
const glyphs = @import("../../common/material_glyph.zig");
const svg_icons = @import("../../../ux/shared/svg_icons.zig");

// Glyph plumbing
//
// Every glyph name resolves through the shared Lucide bank
// (`common/material_glyph.zig`); the Material Symbols font is gone from the
// Zig shell, so an unmapped name measures zero and draws nothing.

/// The glyph box's width in px. Lucide icons are square, so a mapped name
/// measures `glyph_px`; an unmapped one measures zero (nothing would paint).
fn glyphPixelWidth(cr: ?*cairo.cairo_t, ligature: []const u8, glyph_px: f64) i32 {
    _ = cr;
    if (ligature.len == 0) return 0;
    if (svg_icons.lucideName(ligature) == null) return 0;
    return @intFromFloat(@round(@max(glyph_px, 1.0)));
}

/// `draw_material_glyph` — the icon centred on `cx,cy` in the requested
/// colour, rasterised once per (icon, px) by the SVG bank.
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
    _ = glyphs.draw(cr, ligature, cx, cy, px, r, g, b, a);
}

// Polled state

/// `enum class BatteryState` — discriminants keep the UPower wire values so
/// `fromRaw` stays a `decodeState` switch.
pub const BatteryState = enum(u8) {
    unknown = 0,
    charging = 1,
    discharging = 2,
    empty = 3,
    fully_charged = 4,
    pending_charge = 5,
    pending_discharge = 6,

    /// `decodeState` — anything outside 1..6 is `Unknown`.
    pub fn fromRaw(raw: u32) BatteryState {
        return switch (raw) {
            1 => .charging,
            2 => .discharging,
            3 => .empty,
            4 => .fully_charged,
            5 => .pending_charge,
            6 => .pending_discharge,
            else => .unknown,
        };
    }
};

/// `UPowerState` — exactly the four fields the paint reads. **The host fills
/// this in**: the poll thread that produced these values is not part of
/// the Zig shell yet (see the module doc), so whatever polls UPower writes
/// `state` between frames.
pub const State = struct {
    percentage: f64 = 0.0,
    state: BatteryState = .unknown,
    is_present: bool = false,
    on_battery: bool = false,

    /// Bridges `services/upower.zig`'s flat view into the richer state the
    /// paint wants: a `Battery` that exists is present, and only a charging
    /// one can be off mains. The six-way UPower state cannot be recovered
    /// from it, which is why the raw enum stays authoritative here.
    pub fn fromUpower(b: upower.Battery) State {
        return .{
            .percentage = @floatFromInt(b.pct),
            .state = if (b.charging) .charging else .discharging,
            .is_present = true,
            .on_battery = !b.charging,
        };
    }

    /// The flat `upower.Battery` view of this state, for `upower.displayText`
    /// and anything else that consumes the service-shaped struct. An absent
    /// battery reads 0 % rather than the struct default of 100 %.
    pub fn toUpower(self: State) upower.Battery {
        return .{
            .pct = if (self.is_present) roundPct(self.percentage) else 0,
            .charging = isCharging(self.state),
        };
    }

    /// `battery.levelFor` — reused, not reimplemented: an absent battery has
    /// no level at all, everything else is the pure per-level ladder
    /// `widgets/battery.zig` already owns. (No C++ counterpart in this file.)
    pub fn level(self: State) battery.Level {
        if (!self.is_present) return .unknown;
        return battery.levelFor(roundPct(self.percentage), isCharging(self.state));
    }

    /// `battery.iconName` — the themed-icon name for this state, the
    /// counterpart to the glyph the slot itself draws. (No C++
    /// counterpart in this file.)
    pub fn themedIconName(self: State) []const u8 {
        return battery.iconName(self.level(), isCharging(self.state));
    }

    /// `battery.timeRemainingMin` — reused for the host's ETA readout; no
    /// battery means no estimate. (No C++ counterpart in this file.)
    pub fn timeRemaining(self: State, rate_pct_per_hour: f64) ?u32 {
        if (!self.is_present) return null;
        return battery.timeRemainingMin(roundPct(self.percentage), rate_pct_per_hour, isCharging(self.state));
    }
};

/// The process-wide snapshot. Single-threaded by contract: the host writes
/// it between frames under the host lock.
pub var state: State = .{};

// Lifecycle (`battery_widget_init` / `_poll` / `_shutdown`)

var g_refcount: i32 = 0;
var g_running: bool = false;
var g_debug_start_ms: i64 = 0;

/// `CLOCK_MONOTONIC` in whole milliseconds — the source the `EH_BATTERY_DEBUG`
/// ramp measures its 14 s-per-percent steps against. `std.time` in Zig 0.16
/// exposes constants only, so the clock is read the way `dock/anim.zig`'s
/// `monotonicNs` reads it; a monotonic source is also what an elapsed-time
/// ramp wants, since a wall-clock step cannot rewind it.
fn monotonicMs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const sec: i64 = @intCast(@max(ts.sec, 0));
    const nsec: i64 = @intCast(@max(ts.nsec, 0));
    return sec * std.time.ms_per_s + @divTrunc(nsec, std.time.ns_per_ms);
}

/// `battery_widget_init` — refcounted; only the first consumer "starts the
/// thread". There is no thread to start in the Zig shell, so the marker
/// just gates `battery_widget_poll` the way `g_wakeFd >= 0` did.
pub fn batteryWidgetInit() void {
    const prev = g_refcount;
    g_refcount = prev + 1;
    if (prev > 0) return;
    g_running = true;
}

/// `battery_widget_poll` — without a poller to wake, this only applies the
/// `EH_BATTERY_DEBUG` override under lock
/// (`if (debug_state(g_cachedState)) return;` before writing the eventfd).
pub fn batteryWidgetPoll() void {
    if (!g_running) return;
    if (debugState(&state)) return;
}

/// `battery_widget_shutdown` — the last consumer stops the poller.
pub fn batteryWidgetShutdown() void {
    if (g_refcount <= 0) return;
    const prev = g_refcount;
    g_refcount = prev - 1;
    if (prev > 1) return;
    g_running = false;
}

/// `debug_state` — the `EH_BATTERY_DEBUG` override, reading the live
/// environment.
fn debugState(out: *State) bool {
    const p = stdlib.getenv("EH_BATTERY_DEBUG");
    if (p == null) return debugStateFrom(null, out);
    return debugStateFrom(std.mem.span(p), out);
}

/// `debug_state` with the environment value handed in, so the mapping is
/// testable without touching the process environment. `"charging"` ramps from
/// 1 % at 1 % per 14 s off a start time captured on first use.
fn debugStateFrom(env: ?[]const u8, out: *State) bool {
    const v = env orelse return false;
    if (v.len == 0) return false;
    out.* = .{
        .is_present = true,
        .on_battery = true,
        .state = .discharging,
        .percentage = 75.0,
    };
    if (std.mem.eql(u8, v, "charging")) {
        // `CLOCK_MONOTONIC` in ms — see `monotonicMs`.
        const now = monotonicMs();
        if (g_debug_start_ms == 0) g_debug_start_ms = now;
        const elapsed_s: i64 = @divTrunc(now - g_debug_start_ms, 1000);
        const pct: i64 = 1 + @divTrunc(elapsed_s, 14);
        if (pct >= 100) {
            out.state = .fully_charged;
            out.percentage = 100.0;
        } else {
            out.state = .charging;
            out.percentage = @floatFromInt(pct);
        }
    } else if (std.mem.eql(u8, v, "discharging")) {
        out.state = .discharging;
        out.percentage = 65.0;
    } else if (std.mem.eql(u8, v, "low")) {
        out.state = .discharging;
        out.percentage = 8.0;
    } else if (std.mem.eql(u8, v, "full")) {
        out.state = .fully_charged;
        out.percentage = 100.0;
    } else if (std.mem.eql(u8, v, "absent")) {
        out.is_present = false;
    }
    return true;
}

// Module caches (`g_batteryTextCache`)

const Measured = struct {
    tw: i32 = 0,
    th: i32 = 0,
    gw: i32 = 0,
};

/// Text/glyph measurement cache entry, keyed by widget instance id. The other half
/// (`layout` + `lastFontPx`) is `text.LayoutCache`, which owns it.
const Sizes = struct {
    text: [24]u8 = @as([24]u8, @splat(0)),
    text_len: usize = 0,
    glyph: [32]u8 = @as([32]u8, @splat(0)),
    glyph_len: usize = 0,
    tw: i32 = 0,
    th: i32 = 0,
    gw: i32 = 0,

    fn matches(self: *const Sizes, txt: []const u8, glyph: []const u8) bool {
        return self.text_len == txt.len and
            self.glyph_len == glyph.len and
            std.mem.eql(u8, self.text[0..self.text_len], txt) and
            std.mem.eql(u8, self.glyph[0..self.glyph_len], glyph);
    }

    fn set(self: *Sizes, txt: []const u8, glyph: []const u8, tw: i32, th: i32, gw: i32) void {
        const tn = @min(txt.len, self.text.len);
        @memcpy(self.text[0..tn], txt[0..tn]);
        self.text_len = tn;
        const gn = @min(glyph.len, self.glyph.len);
        @memcpy(self.glyph[0..gn], glyph[0..gn]);
        self.glyph_len = gn;
        self.tw = tw;
        self.th = th;
        self.gw = gw;
    }
};

var g_sizes: std.StringHashMap(Sizes) = undefined;
var g_sizes_ready: bool = false;
var g_layouts: lcache.LayoutCache = undefined;
var g_layouts_ready: bool = false;

/// The per-instance measurement cache, created on first use.
fn sizesMap() *std.StringHashMap(Sizes) {
    if (!g_sizes_ready) {
        g_sizes = std.StringHashMap(Sizes).init(std.heap.page_allocator);
        g_sizes_ready = true;
    }
    return &g_sizes;
}

/// `g_batteryTextCache.find(id)` — null until something was measured.
fn sizesFind(id: []const u8) ?*Sizes {
    if (!g_sizes_ready) return null;
    return g_sizes.getPtr(id);
}

/// `g_batteryTextCache[id] = …` — insert or update, owning the key copy.
fn sizesStore(id: []const u8, txt: []const u8, glyph: []const u8, tw: i32, th: i32, gw: i32) void {
    const m = sizesMap();
    if (m.getPtr(id)) |e| {
        e.set(txt, glyph, tw, th, gw);
        return;
    }
    const owned = std.heap.page_allocator.dupe(u8, id) catch return;
    const gop = m.getOrPut(owned) catch {
        std.heap.page_allocator.free(owned);
        return;
    };
    if (gop.found_existing) {
        std.heap.page_allocator.free(owned);
    } else {
        gop.key_ptr.* = owned;
    }
    gop.value_ptr.set(txt, glyph, tw, th, gw);
}

/// The `layout` + `lastFontPx` half of `BatteryTextCache`, one entry per
/// instance id, rebuilt when the font description changes — see
/// `shared/layout_cache.zig`.
fn layouts() *lcache.LayoutCache {
    if (!g_layouts_ready) {
        g_layouts = lcache.LayoutCache.init(std.heap.page_allocator);
        g_layouts_ready = true;
    }
    return &g_layouts;
}

/// Drops every module-level cache, kept for the life of the
/// process; `reset` exists for tests and for a host that wants a clean slate.
pub fn reset() void {
    if (g_sizes_ready) {
        var it = g_sizes.keyIterator();
        while (it.next()) |k| std.heap.page_allocator.free(k.*);
        g_sizes.clearRetainingCapacity();
    }
    if (g_layouts_ready) g_layouts.clear();
    g_debug_start_ms = 0;
}

// Small numeric helpers this file leans on

/// `dock_ui_scale(sc.dock)` — the dock module owns the formula.
fn uiScale(sc: *const schema.ShellConfig) f64 {
    return dock_widgets.uiScale(sc);
}

const Chrome = chrome_colors.Chrome;

/// `derived_chrome_colors`, shared — the battery paint reads dock_fill,
/// accent and text off it. (This used to be a local 3-branch clone; the
/// matugen/horizon branches it could not express now live in the shared
/// port, so the clone is gone.)
/// Overlay alpha scale for the Battery kind, resolving to
/// `overlay_opacity_master` (not one of the advanced per-surface kinds), so
/// only the clamp is left to do.
fn batteryOverlayAlpha(sc: *const schema.ShellConfig) f64 {
    return std.math.clamp(@as(f64, sc.appearance.overlay_opacity_master), 0.0, 1.0);
}

/// Truncating round without undefined behaviour:
/// non-finite input collapses to 0 (what the cast produced in practice) and
/// out-of-range magnitudes saturate instead of being UB.
fn roundPct(v: f64) i32 {
    const r = std.math.round(v);
    if (!std.math.isFinite(r)) return 0;
    return @intFromFloat(std.math.clamp(r, -2147483648.0, 2147483647.0));
}

/// `is_charging` — the three states that draw as "charging".
fn isCharging(s: BatteryState) bool {
    return s == .charging or s == .fully_charged or s == .pending_charge;
}

/// Battery glyph ladder: charging wins over a nonsense percentage, `Unknown`/non-finite
/// wins over every threshold).
fn batteryGlyphFor(pct: f64, s: BatteryState) []const u8 {
    if (isCharging(s)) return "battery_charging_full";
    if (s == .unknown or !std.math.isFinite(pct)) return "battery_unknown";
    if (pct >= 95.0) return "battery_full";
    if (pct >= 80.0) return "battery_6_bar";
    if (pct >= 60.0) return "battery_5_bar";
    if (pct >= 40.0) return "battery_4_bar";
    if (pct >= 20.0) return "battery_3_bar";
    if (pct >= 10.0) return "battery_2_bar";
    if (pct >= 5.0) return "battery_1_bar";
    return "battery_0_bar";
}

/// `snprintf(buf, sizeof(buf), "%d%%", pct)` — the widget's `75%` label.
/// NUL-terminated because cairo/pango want C strings; i32's worst case is
/// 12 bytes, so the 16-byte buffer cannot overflow.
fn percentText(buf: *[16]u8, pct: i32) [:0]u8 {
    const s = std.fmt.bufPrint(buf, "{d}%", .{pct}) catch unreachable;
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// `"Inter <rounded px>"`.
fn fontDesc(buf: *[32]u8, font_px: f64) []const u8 {
    return std.fmt.bufPrint(buf, "Inter {d}", .{@as(i32, @intFromFloat(font_px))}) catch unreachable;
}

/// The label+glyph run measured by `dock_battery_slot_width`'s cache-miss
/// branch: a throwaway layout for the text and the glyph bank's square box
/// for the icon. With no measuring context at all degrades to zeroes (pango
/// calls reject a null layout), which the caller turns into the minimum
/// width.
fn measureRun(cr: ?*cairo.cairo_t, icon_ref_px: f64, us: f64, txt: []const u8, glyph: []const u8) Measured {
    var out = Measured{};
    const c = cr orelse return out;

    const font_px = std.math.clamp(icon_ref_px * 0.38, 11.0 * us, 15.0 * us);
    var fbuf: [32]u8 = undefined;
    var l = text.Layout.createForCairo(c);
    l.setFont(fontDesc(&fbuf, font_px));
    l.setWrap(text.WRAP_WORD_CHAR);
    l.setText(txt);
    const s = l.pixelSize();
    out.tw = s.w;
    out.th = s.h;
    l.destroy();

    out.gw = glyphPixelWidth(c, glyph, icon_ref_px * 0.52);
    return out;
}

/// `g_batteryTextCache[id].layout` — the layout cached across frames for one
/// widget instance, or null when cairo could not build one. The returned
/// wrapper is only a view: the cache owns the layout and releases it in
/// `reset`, so it must not be `destroy`ed by the caller.
fn paintLayout(c: ?*cairo.cairo_t, font_desc: []const u8, font_px: f64, id: []const u8) text.Layout {
    return .{ .layout = layouts().get(c, font_desc, @intFromFloat(font_px), id) };
}

// Public API

/// `widget_list_contains_battery` — does any id in `list` resolve to the
/// `battery` implementation?
pub fn widgetListContainsBattery(sc: *const schema.ShellConfig, list: []const []const u8) bool {
    return wset.listContainsImpl(sc, list, "battery");
}

/// `dock_battery_slot_width` — the slot width for one battery instance.
/// `bar_height` is unused.
pub fn dockBatterySlotWidth(
    measure_cr: ?*cairo.cairo_t,
    sc: *const schema.ShellConfig,
    instance_id: []const u8,
    icon_ref_px: f64,
    bar_height: f64,
) f64 {
    _ = bar_height;
    const us = uiScale(sc);
    const show_percent = wset.settingBool(sc, instance_id, "show_percent", true);

    if (!show_percent) {
        return icon_ref_px + 4.0 * us;
    }

    const mcr = measure_cr orelse measure.measureCr();

    const st = state;
    const pct: i32 = if (st.is_present) roundPct(st.percentage) else 0;
    var buf: [16]u8 = undefined;
    const txt = percentText(&buf, pct);
    const glyph = batteryGlyphFor(st.percentage, st.state);

    var m: Measured = undefined;
    var cache_hit = false;
    if (sizesFind(instance_id)) |e| {
        if (e.matches(txt, glyph)) {
            m = .{ .tw = e.tw, .th = e.th, .gw = e.gw };
            cache_hit = true;
        }
    }
    if (!cache_hit) {
        m = measureRun(mcr, icon_ref_px, us, txt, glyph);
        sizesStore(instance_id, txt, glyph, m.tw, m.th, m.gw);
    }

    const pad_x = 6.0 * us;
    const gap = 6.0 * us;
    const glyph_w: f64 = @floatFromInt(m.gw);
    const text_w: f64 = @floatFromInt(m.tw);
    const min_w = @max(icon_ref_px * 1.25, 40.0 * us);
    const total: f64 = glyph_w + gap + text_w + pad_x * 2.0;
    return @max(min_w, total);
}

/// `paint_battery_slot` — pill + material glyph + optional `75%` label.
/// `hovered`/`pressed` are accepted and ignored (the pill
/// fill does not react to them).
pub fn paintBatterySlot(
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
    const us = uiScale(sc);
    const show_percent = wset.settingBool(sc, instance_id, "show_percent", true);
    const raw_threshold = wset.settingInt(sc, instance_id, "warning_threshold", 0, 2147483647, 10);
    const warning_threshold: i64 = if (raw_threshold <= 0) 10 else raw_threshold;

    const st = state;

    const c = cr orelse return;
    cairo.cairo_save(c);
    pill.paintPill(c, x, y, slot_w, slot_h);

    const mc = chrome_colors.of(sc);
    const glyph_px = icon_ref_px * 0.52;

    if (!st.is_present) {
        drawMaterialGlyph(
            c,
            x + slot_w * 0.5,
            y + slot_h * 0.5,
            glyph_px,
            batteryGlyphFor(0.0, .unknown),
            mc.text.r,
            mc.text.g,
            mc.text.b,
            0.5,
        );
        cairo.cairo_restore(c);
        return;
    }

    const pct = roundPct(st.percentage);
    const charging = isCharging(st.state);
    const warning = @as(i64, pct) <= warning_threshold and !charging;

    var fg = mc.text;
    if (warning) {
        fg = .{ .r = 1.0, .g = 0.4, .b = 0.4 };
    } else if (charging) {
        fg = mc.accent;
    }

    const gx = x + slot_w * 0.5;
    const gy = y + slot_h * 0.5;

    if (show_percent) {
        const font_px = std.math.clamp(icon_ref_px * 0.38, 11.0 * us, 15.0 * us);
        var fbuf: [32]u8 = undefined;
        const fd = fontDesc(&fbuf, font_px);

        var buf: [16]u8 = undefined;
        const txt = percentText(&buf, pct);
        const glyph = batteryGlyphFor(st.percentage, st.state);

        // Lookup happens before insert, so a brand-new
        // entry counts as a miss even though it exists by the time the sizes
        // are written; `sizesFind` before `sizesStore` keeps that order.
        const found = sizesFind(instance_id);

        var lo = paintLayout(c, fd, font_px, instance_id);
        lo.setText(txt);
        lo.setAlignment(text.ALIGN_LEFT);
        lo.setWrap(text.WRAP_WORD_CHAR);

        var m: Measured = undefined;
        var cache_hit = false;
        if (found) |e| {
            if (e.matches(txt, glyph)) {
                m = .{ .tw = e.tw, .th = e.th, .gw = e.gw };
                cache_hit = true;
            }
        }
        if (!cache_hit) {
            // `pixelSize` is {0,0} when there is no layout.
            const s = lo.pixelSize();
            m = .{ .tw = s.w, .th = s.h, .gw = glyphPixelWidth(c, glyph, glyph_px) };
            sizesStore(instance_id, txt, glyph, m.tw, m.th, m.gw);
        }

        const label_y = y + (slot_h - @as(f64, @floatFromInt(m.th))) * 0.5;

        const glyph_w: f64 = @floatFromInt(m.gw);
        const gap = 6.0 * us;
        const total_inner = glyph_w + gap + @as(f64, @floatFromInt(m.tw));
        const inner_x = x + (slot_w - total_inner) * 0.5;
        const glyph_cx = inner_x + glyph_w * 0.5;
        const glyph_cy = y + slot_h * 0.5;

        drawMaterialGlyph(c, glyph_cx, glyph_cy, glyph_px, glyph, fg.r, fg.g, fg.b, 1.0);

        const label_x = inner_x + glyph_w + gap;
        cairo.cairo_set_source_rgba(c, fg.r, fg.g, fg.b, 1.0);
        cairo.cairo_move_to(c, label_x, label_y);
        lo.show(c);
    } else {
        const glyph = batteryGlyphFor(st.percentage, st.state);
        drawMaterialGlyph(c, gx, gy, glyph_px, glyph, fg.r, fg.g, fg.b, 1.0);
    }

    cairo.cairo_restore(c);
}

/// `kBatteryPopupW` — the popup's fixed width in logical px.
pub const kBatteryPopupW: i32 = 260;

/// `battery_popup_height` — the popup's fixed height in logical px.
pub fn batteryPopupHeight() i32 {
    return 160;
}

/// `dock_battery_popup_paint` — shadow, body, close button, title, percent,
/// bar and status text. The early return for an absent battery leaves no
/// save outstanding.
pub fn dockBatteryPopupPaint(
    pointer_x: f64,
    pointer_y: f64,
    cr: ?*cairo.cairo_t,
    sc: *const schema.ShellConfig,
) void {
    const c = cr orelse return;
    const w: f64 = @floatFromInt(kBatteryPopupW);
    const h: f64 = @floatFromInt(batteryPopupHeight());

    const mc = chrome_colors.of(sc);
    const shell_ov = batteryOverlayAlpha(sc);

    const us = uiScale(sc);
    const k_pad = 16.0 * us;
    const k_corner = 14.0 * us;
    const k_shad_x = 2.0 * us;
    const k_shad_y = 4.0 * us;
    const k_shad_alpha = 0.28;

    const st = state;

    cairo.cairo_save(c);
    helpers.roundedRect(c, k_shad_x, k_shad_y, w, h, k_corner);
    // Scales with the battery/master knob like the fill below it.
    cairo.cairo_set_source_rgba(c, 0.0, 0.0, 0.0, k_shad_alpha * shell_ov);
    cairo.cairo_fill(c);
    cairo.cairo_restore(c);

    helpers.roundedRect(c, 0.0, 0.0, w, h, k_corner);
    cairo.cairo_set_source_rgba(
        c,
        mc.dock_fill.r * 0.30,
        mc.dock_fill.g * 0.30,
        mc.dock_fill.b * 0.30,
        0.92 * shell_ov,
    );
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.14);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);

    const cb_w = 24.0 * us;
    const cb_x = w - k_pad - cb_w;
    const cb_y = k_pad;
    const hc = pointer_x >= cb_x and pointer_x < cb_x + cb_w and
        pointer_y >= cb_y and pointer_y < cb_y + cb_w;
    helpers.roundedRect(c, cb_x, cb_y, cb_w, cb_w, 7.0 * us);
    cairo.cairo_set_source_rgba(c, 0.3, 0.3, 0.35, if (hc) 0.75 else 0.45);
    cairo.cairo_fill(c);
    drawMaterialGlyph(
        c,
        cb_x + cb_w * 0.5,
        cb_y + cb_w * 0.5,
        14.0 * us,
        "close",
        mc.text.r,
        mc.text.g,
        mc.text.b,
        if (hc) 1.0 else 0.85,
    );

    cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.92);
    cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_BOLD);
    cairo.cairo_set_font_size(c, 14.0 * us);
    var title_te: cairo.cairo_text_extents_t = undefined;
    cairo.cairo_text_extents(c, "Battery", &title_te);
    cairo.cairo_move_to(c, k_pad, k_pad + 22.0 * us);
    cairo.cairo_show_text(c, "Battery");

    if (!st.is_present) {
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.5);
        cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
        cairo.cairo_set_font_size(c, 13.0 * us);
        cairo.cairo_move_to(c, k_pad, 70.0 * us);
        cairo.cairo_show_text(c, "No battery detected");
        return;
    }

    const pct = roundPct(st.percentage);
    const charging = isCharging(st.state);

    {
        var buf: [16]u8 = undefined;
        const txt = percentText(&buf, pct);
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 1.0);
        cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_BOLD);
        cairo.cairo_set_font_size(c, 36.0 * us);
        var te: cairo.cairo_text_extents_t = undefined;
        cairo.cairo_text_extents(c, txt, &te);
        cairo.cairo_move_to(c, (w - te.x_advance) * 0.5, 82.0 * us);
        cairo.cairo_show_text(c, txt);
    }

    const bar_x = k_pad;
    const bar_w = w - k_pad * 2.0;
    const bar_h = 10.0 * us;
    const bar_y = 98.0 * us;
    const bar_r = bar_h * 0.5;
    helpers.roundedRect(c, bar_x, bar_y, bar_w, bar_h, bar_r);
    cairo.cairo_set_source_rgba(c, 0.15, 0.15, 0.18, 0.5);
    cairo.cairo_fill(c);

    if (pct > 0) {
        const fill_w = @max(bar_h, bar_w * (@as(f64, @floatFromInt(pct)) / 100.0));
        var fg = mc.accent;
        if (pct <= 10 and !charging) {
            fg = .{ .r = 1.0, .g = 0.4, .b = 0.4 };
        }
        helpers.roundedRect(c, bar_x, bar_y, fill_w, bar_h, bar_r);
        cairo.cairo_set_source_rgba(c, fg.r, fg.g, fg.b, 0.85);
        cairo.cairo_fill(c);
    }

    {
        const status: [:0]const u8 = switch (st.state) {
            .charging, .pending_charge => "Charging",
            .fully_charged => "Fully charged",
            .empty => "Empty",
            .pending_discharge => "Discharging",
            .unknown, .discharging => if (st.on_battery) "Discharging" else "Not charging",
        };
        cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.7);
        cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
        cairo.cairo_set_font_size(c, 13.0 * us);
        var te: cairo.cairo_text_extents_t = undefined;
        cairo.cairo_text_extents(c, status, &te);
        cairo.cairo_move_to(c, (w - te.x_advance) * 0.5, bar_y + bar_h + 22.0 * us);
        cairo.cairo_show_text(c, status);
    }

    const glyph = batteryGlyphFor(st.percentage, st.state);
    drawMaterialGlyph(
        c,
        k_pad + title_te.x_advance + 10.0 * us,
        k_pad + 16.0 * us,
        18.0 * us,
        glyph,
        mc.text.r,
        mc.text.g,
        mc.text.b,
        0.85,
    );
}

/// What the host should do after `dockBatteryPopupHandleClick`.
/// The intent comes back as a value
/// instead. There is no redraw action.
pub const ClickResult = enum {
    /// Click landed inside the popup but not on the close button — do
    /// nothing.
    none,
    /// `popup_close(app)` — tear the popup surface down. Both the
    /// outside-the-popup test and the close button hit-test end here.
    close,
};

/// `dock_battery_popup_handle_click` — the same scaled metrics as the paint
/// (see `Docs/hit-testing.md`), which is why the config comes in as a
/// parameter instead of a config snapshot. The trailing serial has no meaning here.
pub fn dockBatteryPopupHandleClick(
    sc: *const schema.ShellConfig,
    x: f64,
    y: f64,
) ClickResult {
    const w: f64 = @floatFromInt(kBatteryPopupW);
    const h: f64 = @floatFromInt(batteryPopupHeight());

    if (x < 0 or x >= w or y < 0 or y >= h) {
        return .close;
    }

    const us = uiScale(sc);
    const k_pad = 16.0 * us;
    const cb_x = w - k_pad - 24.0 * us;
    const cb_y = k_pad;
    if (x >= cb_x and x < cb_x + 24.0 * us and y >= cb_y and y < cb_y + 24.0 * us) {
        return .close;
    }
    return .none;
}

// Tests

fn load(alloc: std.mem.Allocator, cfg_text: []const u8) !schema.Loaded {
    return schema.loadText(alloc, cfg_text);
}

test "battery-paint: widget list detection" {
    const t = std.testing;
    var cfg = try load(t.allocator,
        \\[widget.battery]
        \\show_percent = "true"
        \\[widget.custom]
        \\type = "battery"
        \\[widget.clock]
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    const with_battery = [_][]const u8{ "media", "battery" };
    try t.expect(widgetListContainsBattery(c, &with_battery));

    const without = [_][]const u8{ "media", "clock" };
    try t.expect(!widgetListContainsBattery(c, &without));

    // A custom id whose `type` is `battery` counts too.
    const custom = [_][]const u8{"custom"};
    try t.expect(widgetListContainsBattery(c, &custom));

    const empty = [_][]const u8{};
    try t.expect(!widgetListContainsBattery(c, &empty));
}

test "battery-paint: slot width without a percent label is icon + padding" {
    const t = std.testing;
    var cfg = try load(t.allocator,
        \\[dock]
        \\scale = 2.0
        \\[widget.battery]
        \\show_percent = "false"
    );
    defer cfg.deinit();

    // us = clamp(2.0) * clamp(1.0) = 2 → 44 + 4 * 2 = 52.
    const w = dockBatterySlotWidth(null, &cfg.cfg, "battery", 44.0, 60.0);
    try t.expectApproxEqAbs(@as(f64, 52.0), w, 1e-9);
}

test "battery-paint: slot width with a percent label is measured and cached" {
    const t = std.testing;
    var cfg = try load(t.allocator,
        \\[widget.battery]
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    defer state = .{};
    state = .{ .percentage = 75.0, .state = .discharging, .is_present = true, .on_battery = true };

    const icon = 44.0;
    const min_w = @max(icon * 1.25, 40.0); // us = 1
    const w1 = dockBatterySlotWidth(null, c, "battery", icon, 60.0);
    try t.expect(w1 >= min_w);

    // Same state, same instance: the measurement cache returns the same
    // width rather than re-measuring.
    const w2 = dockBatterySlotWidth(null, c, "battery", icon, 60.0);
    try t.expectEqual(w1, w2);

    // An explicit measuring context is accepted too.
    const w3 = dockBatterySlotWidth(measure.measureCr(), c, "battery", icon, 60.0);
    try t.expectEqual(w1, w3);

    // A changed percentage invalidates the cached run.
    state.percentage = 7.0;
    const w4 = dockBatterySlotWidth(null, c, "battery", icon, 60.0);
    try t.expect(w4 >= min_w);

    // Absent battery: the label reads `0%` and the width still floors out.
    state = .{};
    const w5 = dockBatterySlotWidth(null, c, "battery", icon, 60.0);
    try t.expect(w5 >= min_w);
}

test "battery-paint: glyph ladder and rounding follow the specified steps" {
    const t = std.testing;

    try t.expectEqualStrings("battery_charging_full", batteryGlyphFor(50.0, .charging));
    try t.expectEqualStrings("battery_charging_full", batteryGlyphFor(100.0, .fully_charged));
    try t.expectEqualStrings("battery_charging_full", batteryGlyphFor(3.0, .pending_charge));
    try t.expectEqualStrings("battery_unknown", batteryGlyphFor(50.0, .unknown));
    try t.expectEqualStrings("battery_unknown", batteryGlyphFor(std.math.nan(f64), .discharging));

    try t.expectEqualStrings("battery_full", batteryGlyphFor(95.0, .discharging));
    try t.expectEqualStrings("battery_6_bar", batteryGlyphFor(94.9, .discharging));
    try t.expectEqualStrings("battery_6_bar", batteryGlyphFor(80.0, .discharging));
    try t.expectEqualStrings("battery_5_bar", batteryGlyphFor(79.9, .discharging));
    try t.expectEqualStrings("battery_5_bar", batteryGlyphFor(60.0, .discharging));
    try t.expectEqualStrings("battery_4_bar", batteryGlyphFor(59.9, .discharging));
    try t.expectEqualStrings("battery_4_bar", batteryGlyphFor(40.0, .discharging));
    try t.expectEqualStrings("battery_3_bar", batteryGlyphFor(39.9, .discharging));
    try t.expectEqualStrings("battery_3_bar", batteryGlyphFor(20.0, .discharging));
    try t.expectEqualStrings("battery_2_bar", batteryGlyphFor(19.9, .discharging));
    try t.expectEqualStrings("battery_2_bar", batteryGlyphFor(10.0, .discharging));
    try t.expectEqualStrings("battery_1_bar", batteryGlyphFor(9.9, .discharging));
    try t.expectEqualStrings("battery_1_bar", batteryGlyphFor(5.0, .discharging));
    try t.expectEqualStrings("battery_0_bar", batteryGlyphFor(4.9, .discharging));
    try t.expectEqualStrings("battery_0_bar", batteryGlyphFor(0.0, .empty));

    // Truncating round, ties away from zero, with the UB
    // cases pinned down.
    try t.expectEqual(@as(i32, 75), roundPct(74.5));
    try t.expectEqual(@as(i32, -75), roundPct(-74.5));
    try t.expectEqual(@as(i32, 74), roundPct(74.4));
    try t.expectEqual(@as(i32, 0), roundPct(std.math.nan(f64)));
    try t.expectEqual(@as(i32, 0), roundPct(std.math.inf(f64)));
    try t.expectEqual(@as(i32, 2147483647), roundPct(1e30));
}

test "battery-paint: State bridges to upower and battery.zig" {
    const t = std.testing;

    const b = upower.Battery{ .pct = 42, .charging = true };
    const st = State.fromUpower(b);
    try t.expectEqual(@as(f64, 42.0), st.percentage);
    try t.expect(st.is_present);
    try t.expectEqual(BatteryState.charging, st.state);
    try t.expect(!st.on_battery);

    // Per-level logic stays in battery.zig — level, themed name and ETA are
    // one-line bridges, never a second copy of the thresholds.
    try t.expectEqual(battery.Level.medium, st.level());
    try t.expectEqualStrings("battery-charging", st.themedIconName());
    // Charging measures the time *to full*: (100 − 42) / 50 %/h → 69 min.
    try t.expectEqual(@as(?u32, 69), st.timeRemaining(50.0));

    const discharging = State{ .percentage = 50.0, .state = .discharging, .is_present = true };
    try t.expectEqual(battery.Level.medium, discharging.level());
    try t.expectEqualStrings("battery-medium", discharging.themedIconName());
    try t.expectEqual(@as(?u32, 60), discharging.timeRemaining(50.0));
    try t.expect(discharging.timeRemaining(0.0) == null);

    // An absent battery has no level and no estimate.
    const absent = State{};
    try t.expectEqual(battery.Level.unknown, absent.level());
    try t.expectEqualStrings("battery-missing", absent.themedIconName());
    try t.expect(absent.timeRemaining(50.0) == null);

    // …and the flat view round-trips for `upower.displayText`.
    const back = discharging.toUpower();
    try t.expectEqual(@as(i32, 50), back.pct);
    try t.expect(!back.charging);
    const shown = try upower.displayText(back, t.allocator);
    defer t.allocator.free(shown);
    try t.expectEqualStrings("50%", shown);
    try t.expectEqual(@as(i32, 0), absent.toUpower().pct);

    // The UPower wire values decode the way `decodeState` did.
    try t.expectEqual(BatteryState.charging, BatteryState.fromRaw(1));
    try t.expectEqual(BatteryState.pending_discharge, BatteryState.fromRaw(6));
    try t.expectEqual(BatteryState.unknown, BatteryState.fromRaw(0));
    try t.expectEqual(BatteryState.unknown, BatteryState.fromRaw(99));
}

test "battery-paint: EH_BATTERY_DEBUG maps onto State" {
    const t = std.testing;
    var s = State{};

    try t.expect(!debugStateFrom(null, &s));
    try t.expect(!debugStateFrom("", &s));

    try t.expect(debugStateFrom("low", &s));
    try t.expect(s.is_present and s.on_battery);
    try t.expectEqual(BatteryState.discharging, s.state);
    try t.expectEqual(@as(f64, 8.0), s.percentage);

    try t.expect(debugStateFrom("full", &s));
    try t.expectEqual(BatteryState.fully_charged, s.state);
    try t.expectEqual(@as(f64, 100.0), s.percentage);

    try t.expect(debugStateFrom("discharging", &s));
    try t.expectEqual(@as(f64, 65.0), s.percentage);

    // An unrecognised value keeps the base 75 % discharge.
    try t.expect(debugStateFrom("something", &s));
    try t.expectEqual(@as(f64, 75.0), s.percentage);

    try t.expect(debugStateFrom("absent", &s));
    try t.expect(!s.is_present);

    // "charging" ramps 1 % per 14 s off a start captured on first use, so
    // the very first reading is 1 %.
    try t.expect(debugStateFrom("charging", &s));
    try t.expectEqual(BatteryState.charging, s.state);
    try t.expect(s.percentage >= 1.0 and s.percentage < 100.0);
}

test "battery-paint: lifecycle is refcounted" {
    const t = std.testing;

    // Polling before anyone started is a no-op, like `g_wakeFd < 0`.
    batteryWidgetPoll();
    try t.expect(!g_running);

    batteryWidgetInit();
    try t.expect(g_running);
    batteryWidgetInit();
    batteryWidgetPoll();
    batteryWidgetShutdown();
    // One consumer still holds the poller.
    try t.expect(g_running);
    batteryWidgetShutdown();
    try t.expect(!g_running);
    batteryWidgetPoll();

    // Extra shutdowns below zero are ignored rather than underflowing.
    batteryWidgetShutdown();
    try t.expectEqual(@as(i32, 0), g_refcount);
}

test "battery-paint: reset drops the module caches" {
    const t = std.testing;
    var cfg = try load(t.allocator,
        \\[widget.battery]
    );
    defer cfg.deinit();

    defer state = .{};
    state = .{ .percentage = 40.0, .state = .discharging, .is_present = true };

    _ = dockBatterySlotWidth(null, &cfg.cfg, "battery", 44.0, 60.0);
    try t.expect(sizesFind("battery") != null);

    reset();
    try t.expect(sizesFind("battery") == null);
}

test "battery-paint: slot paint draws every branch" {
    const t = std.testing;
    var cfg = try load(t.allocator,
        \\[widget.battery]
        \\warning_threshold = "30"
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 240, 60);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    defer state = .{};
    // Charging + percent label: pill, glyph, label, cache fill.
    state = .{ .percentage = 55.0, .state = .charging, .is_present = true };
    paintBatterySlot(cr, c, "battery", 8, 8, 72, 44, 44, false, false);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Under the warning threshold and not charging → the red foreground.
    state = .{ .percentage = 20.0, .state = .discharging, .is_present = true, .on_battery = true };
    paintBatterySlot(cr, c, "battery", 88, 8, 72, 44, 44, true, true);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Above the threshold: the normal text colour.
    state.percentage = 90.0;
    paintBatterySlot(cr, c, "battery", 168, 8, 72, 44, 44, false, false);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Absent battery: the faint `battery_unknown` glyph, then return.
    state = .{};
    paintBatterySlot(cr, c, "battery", 8, 8, 44, 44, 44, false, false);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // A null context is a no-op rather than a crash.
    paintBatterySlot(null, c, "battery", 0, 0, 44, 44, 44, false, false);
}

test "battery-paint: slot paint without the percent label" {
    const t = std.testing;
    var cfg = try load(t.allocator,
        \\[widget.battery]
        \\show_percent = "0"
    );
    defer cfg.deinit();

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 64, 60);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    defer state = .{};
    state = .{ .percentage = 88.0, .state = .discharging, .is_present = true, .on_battery = true };
    paintBatterySlot(cr, &cfg.cfg, "battery", 8, 8, 44, 44, 44, false, false);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}

test "battery-paint: popup geometry uses the specified constants" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 260), kBatteryPopupW);
    try t.expectEqual(@as(i32, 160), batteryPopupHeight());
}

test "battery-paint: popup paints present and absent batteries" {
    const t = std.testing;
    var cfg = try load(t.allocator,
        \\[appearance]
        \\overlay_opacity_master = 0.8
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 300, 220);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    defer state = .{};
    // Present, discharging, low → red bar fill.
    state = .{ .percentage = 8.0, .state = .discharging, .is_present = true, .on_battery = true };
    dockBatteryPopupPaint(10.0, 10.0, cr, c);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Hovering the close button brightens it, nothing else changes.
    state.percentage = 96.0;
    state.state = .charging;
    dockBatteryPopupPaint(230.0, 20.0, cr, c);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Absent battery takes the early return after the title.
    state = .{};
    dockBatteryPopupPaint(0.0, 0.0, cr, c);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // A null context is a no-op rather than a crash.
    dockBatteryPopupPaint(0.0, 0.0, null, c);
}

test "battery-paint: popup clicks route to close or nothing" {
    const t = std.testing;
    var cfg = try load(t.allocator,
        \\[dock]
        \\scale = 2.0
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    // us = 2: kPad = 32, close button spans x∈[180,228), y∈[32,80).
    try t.expectEqual(ClickResult.close, dockBatteryPopupHandleClick(c, 190.0, 40.0));
    try t.expectEqual(ClickResult.none, dockBatteryPopupHandleClick(c, 100.0, 100.0));
    // Inside the popup, past the button.
    try t.expectEqual(ClickResult.none, dockBatteryPopupHandleClick(c, 250.0, 100.0));
    // Outside the 260 × 160 box → `popup_close`.
    try t.expectEqual(ClickResult.close, dockBatteryPopupHandleClick(c, 300.0, 10.0));
    try t.expectEqual(ClickResult.close, dockBatteryPopupHandleClick(c, -1.0, 5.0));
    try t.expectEqual(ClickResult.close, dockBatteryPopupHandleClick(c, 100.0, 160.0));
    try t.expectEqual(ClickResult.close, dockBatteryPopupHandleClick(c, 100.0, -0.5));

    // The bottom-right corner of the popup never contains the button.
    try t.expectEqual(ClickResult.none, dockBatteryPopupHandleClick(c, 259.0, 159.0));
}
