//! The dock's media pill: an artwork disc, the track's title and artist, three
//! transport buttons, and a progress border that snakes around the pill while
//! a track plays.
//!
//! Layout is driven by the reference icon size alone (`s = icon / 30`), so the
//! pill is a fixed proportion of the dock's icon slot at every size. Text runs
//! share one line and are only allowed to scroll when a row genuinely
//! overflows, which keeps short titles perfectly still.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const pill = @import("../shared/pill.zig");
const wset = @import("../shared/widget_settings.zig");
const glyphs = @import("../../common/material_glyph.zig");
const mclient = @import("../../../services/mpris_client.zig");
const schema = @import("../../../config/schema.zig");
const perf = @import("media_perf.zig");

const tau: f64 = 2.0 * std.math.pi;
const k_btn_small_d: f64 = 16.0;
const k_btn_play_d: f64 = 19.0;
const k_outer_hpad: f64 = 4.0;
const k_scroll_floor: f64 = 72.0;
const k_marquee_period: f64 = 12.0;
const k_min_seg: f64 = 8.0;
const k_dot: []const u8 = " \u{2022} ";
const k_sep_min: f64 = 6.0;
const k_text_alpha: f64 = 1.0;
const k_btn_bg: f64 = 0.22;
const k_btn_bg_on: f64 = 0.55;
const k_ring_btn: f64 = 0.6;
const k_ring_art: f64 = 0.7;

// Pango enums the shared text wrapper does not model.
const wrap_none: c_int = 3;
const ellipsize_end: c_int = 3;
const pango_scale: f64 = 1024.0;

extern fn pango_layout_set_ellipsize(layout: ?*text.PangoLayout, e: c_int) void;
extern fn pango_font_description_from_string(s: [*c]const u8) ?*text.PangoFontDescription;
extern fn pango_font_description_free(d: ?*text.PangoFontDescription) void;
extern fn pango_layout_set_font_description(layout: ?*text.PangoLayout, d: ?*const text.PangoFontDescription) void;

/// A decoded cover, already in cairo's own premultiplied B,G,R,A byte order.
pub const Art = struct {
    pixels: []const u8 = &.{},
    w: i32 = 0,
    h: i32 = 0,

    pub fn present(self: Art) bool {
        return self.pixels.len > 0 and self.w > 0 and self.h > 0;
    }
};

/// Everything the pill's width and text layout depend on, measured once per
/// track rather than on every frame.
pub const Measured = struct {
    /// The natural text run, already capped at the width budget.
    text_w: f64 = 0.0,
    title_nat_w: f64 = 0.0,
    artist_nat_w: f64 = 0.0,
    /// Width of the " • " between the two runs.
    between_w: f64 = 0.0,
};

pub const Geometry = struct {
    x: f64 = 0.0,
    y: f64 = 0.0,
    slot_w: f64 = 0.0,
    slot_h: f64 = 0.0,
    icon_px: f64 = 0.0,
};

pub const Pill = struct {
    snap: mclient.Snapshot = .{},
    art: Art = .{},
    measured: Measured = .{},
    /// Index of the hovered transport button, or -1. Derived from `hitZone`.
    hover_btn: i32 = -1,
    /// Pointer position in slot-local pixels, or a negative value when the
    /// pointer is elsewhere — only the artwork disc reacts to it.
    pointer_x: f64 = -1.0,
    pointer_y: f64 = -1.0,
    show_text: bool = true,
    /// `max_title_scale` in config units, already resolved from the widget's
    /// settings.
    title_scale: f64 = 352.0,
    /// Monotonic seconds, for the marquee.
    now_sec: f64 = 0.0,
    /// The same instant in nanoseconds, for the playhead projection.
    now_ns: i64 = 0,
};

pub const Result = struct {
    /// True while a row is actually scrolling; the caller keeps frames coming.
    wants_marquee: bool = false,
    /// True while the progress border is being drawn; the caller arms the
    /// slow repaint that advances it.
    progress_tick: bool = false,
};

// Geometry

pub fn scaleOf(icon_px: f64) f64 {
    return icon_px / 30.0;
}

pub fn artDiameter(icon_px: f64) f64 {
    return icon_px * 0.78;
}

pub fn gapBefore(s: f64) f64 {
    return @max(8.0, 10.0 * s);
}

pub fn gapBetweenButtons(s: f64) f64 {
    return @max(4.0, 6.0 * s);
}

pub fn smallRadius(s: f64) f64 {
    return k_btn_small_d * s * 0.5;
}

pub fn playRadius(s: f64) f64 {
    return k_btn_play_d * s * 0.5;
}

/// Width of the prev/play/next group, including both gaps.
pub fn ctrlRowWidth(s: f64) f64 {
    return 4.0 * smallRadius(s) + 2.0 * gapBetweenButtons(s) + 2.0 * playRadius(s);
}

pub fn titleFontPx(s: f64) f64 {
    return @round(10.0 * s);
}

pub fn artistFontPx(s: f64) f64 {
    return @round(9.0 * s);
}

pub fn sepFloor(s: f64) f64 {
    return @max(k_sep_min, 8.0 * s);
}

/// How wide the text may get once the disc and the button row have taken
/// their share of the pill.
pub fn textBudget(slot_w: f64, inner: f64, art_dia: f64, i_gap: f64, ctrl_w: f64, max_text: f64) f64 {
    const room = slot_w - inner - art_dia - i_gap - i_gap - ctrl_w - inner + 1.0;
    return @max(48.0, @min(max_text, room));
}

/// The triangle wave behind the marquee: out to the end of the overflow, then
/// back, once every `period_sec`.
pub fn marqueeOffset(range_px: f64, now_sec: f64, period_sec: f64) f64 {
    if (range_px <= 0.5) return 0.0;
    const u = @mod(now_sec / period_sec, 1.0);
    const tri = if (u < 0.5) u * 2.0 else 2.0 - u * 2.0;
    return tri * range_px;
}

/// Perimeter of the rounded rect the progress border is drawn along.
pub fn progressPerimeter(slot_w: f64, pill_h: f64, rad: f64) f64 {
    const sw = @max(0.0, slot_w - 2.0 * rad);
    const sh = @max(0.0, pill_h - 2.0 * rad);
    return 2.0 * sw + 2.0 * sh + 4.0 * (std.math.pi * 0.5 * rad);
}

/// Which control the pointer is over, as an index into the transport row.
/// The artwork disc is its own zone; -1 means "the pill, but nothing on it".
/// Zones are geometric, so they stay valid while no player is running.
pub fn hitZone(local_x: f64, slot_w: f64, icon_px: f64) i32 {
    if (slot_w <= 1.0 or icon_px <= 0.0) return -1;
    const s = scaleOf(icon_px);
    const bsr = smallRadius(s);
    const bpr = playRadius(s);
    const btn_gap = gapBetweenButtons(s);
    const rad = @max(2.0, @min(icon_px, slot_w) * 0.22);
    const inner = rad + k_outer_hpad;
    const art_dia = artDiameter(icon_px);

    const ctrl_right = slot_w - inner;
    const next_cx = ctrl_right - bsr;
    const play_cx = next_cx - bsr - btn_gap - bpr;
    const prev_cx = play_cx - bpr - btn_gap - bsr;

    if (local_x >= prev_cx - bsr and local_x <= prev_cx + bsr) return 0;
    if (local_x >= play_cx - bpr and local_x <= play_cx + bpr) return 1;
    if (local_x >= next_cx - bsr and local_x <= next_cx + bsr) return 2;
    if (local_x >= inner and local_x < inner + art_dia) return 3;
    return -1;
}

// Measuring

/// `max_title_scale` from the widget's settings: the ceiling on how much of
/// the pill the text row may claim, in `s` units.
pub fn titleScaleLimit(cfg: *const schema.ShellConfig, id: []const u8) f64 {
    const raw = wset.widgetSetting(cfg, id, "max_title_scale");
    if (raw.len == 0) return 352.0;
    const v = std.fmt.parseFloat(f64, raw) catch return 352.0;
    return std.math.clamp(v, 80.0, 660.0);
}

/// Measure the text run for one track. `cr` is the dock's scratch context,
/// which exists precisely so widths can be measured without a live surface.
pub fn measure(
    cr: ?*cairo.cairo_t,
    cfg: *const schema.ShellConfig,
    id: []const u8,
    icon_px: f64,
    snap: mclient.Snapshot,
    compact: bool,
) Measured {
    var m = Measured{};
    const c = cr orelse return m;
    if (compact or !wset.settingBool(cfg, id, "show_text", true)) return m;

    const s = scaleOf(icon_px);
    const max_text = titleScaleLimit(cfg, id) * s;
    const real_active = snap.realActive();

    const title_m: []const u8 = displayTitle(snap);
    const artist_m: []const u8 = if (real_active) snap.artist else "";

    const title_nat: f64 = @floatFromInt(naturalWidth(c, title_m, titleFontPx(s)));
    const artist_nat: f64 = if (artist_m.len == 0) 0.0 else @floatFromInt(naturalWidth(c, artist_m, artistFontPx(s)));
    const between: f64 = if (artist_m.len == 0) 0.0 else sepWidth(c, s);

    const natural = if (artist_m.len == 0) title_nat else title_nat + between + artist_nat;
    m.title_nat_w = title_nat;
    m.artist_nat_w = artist_nat;
    m.between_w = between;
    m.text_w = @min(max_text, natural);
    return m;
}

/// The row the pill shows: the track's title, or the resting label.
pub fn displayTitle(snap: mclient.Snapshot) []const u8 {
    if (!snap.realActive()) return "No Media";
    if (snap.title.len == 0) return "Unknown title";
    return snap.title;
}

/// Width of one line of `value` at `px`, with no wrapping or ellipsis.
fn naturalWidth(cr: ?*cairo.cairo_t, value: []const u8, px: f64) i32 {
    var lay = newLayout(cr, px);
    defer lay.destroy();
    lay.setWidthUnits(-1);
    lay.setWrap(wrap_none);
    pango_layout_set_ellipsize(lay.layout, 0);
    lay.setText(value);
    return lay.pixelSize().w;
}

/// Width of the " • " separator, which is drawn with the artist's font. The
/// widest of a handful of sizes is cached, because the dock measures this on
/// every relayout and the value cannot drift between two runs of one size.
var dot_cache: [16]struct { px: i32, w: i32 } = undefined;
var dot_cache_len: usize = 0;

fn sepWidth(cr: ?*cairo.cairo_t, s: f64) f64 {
    const floor = sepFloor(s);
    const c = cr orelse return floor;
    const px: i32 = @intFromFloat(@max(1.0, artistFontPx(s)));
    for (dot_cache[0..dot_cache_len]) |e| {
        if (e.px == px) return @max(floor, @as(f64, @floatFromInt(e.w)));
    }
    var lay = newLayout(c, @as(f64, @floatFromInt(px)));
    defer lay.destroy();
    lay.setWidthUnits(-1);
    lay.setWrap(wrap_none);
    pango_layout_set_ellipsize(lay.layout, 0);
    lay.setText(k_dot);
    const w = lay.pixelSize().w;
    if (dot_cache_len < dot_cache.len) {
        dot_cache[dot_cache_len] = .{ .px = px, .w = w };
        dot_cache_len += 1;
    }
    return @max(floor, @as(f64, @floatFromInt(w)));
}

fn newLayout(cr: ?*cairo.cairo_t, px: f64) text.Layout {
    var l = text.Layout.createForCairo(cr);
    const size: c_int = @intFromFloat(@max(1.0, px));
    var zbuf: [64:0]u8 = [_:0]u8{0} ** 64;
    const desc = std.fmt.bufPrint(&zbuf, "Inter SemiBold {d}", .{size}) catch return l;
    zbuf[desc.len] = 0;
    const fd = pango_font_description_from_string(zbuf[0..desc.len :0]);
    if (fd != null) {
        pango_layout_set_font_description(l.layout, fd);
        pango_font_description_free(fd);
    }
    l.setWrap(text.WRAP_WORD_CHAR);
    pango_layout_set_ellipsize(l.layout, ellipsize_end);
    l.setAlignment(text.ALIGN_LEFT);
    return l;
}

// Position

/// Where the playhead is between two D-Bus readings. MPRIS only reports
/// `Position` when asked for, so the time since the last authoritative value
/// stands in for it; a jump larger than two seconds is treated as a seek and
/// resynchronises instead of being smoothed over.
pub const Position = struct {
    track: [640]u8 = undefined,
    track_len: usize = 0,
    pos_us: i64 = 0,
    last_raw: i64 = 0,
    at_ns: i64 = 0,

    pub fn reset(self: *Position) void {
        self.track_len = 0;
        self.pos_us = 0;
        self.last_raw = 0;
        self.at_ns = 0;
    }

    pub fn project(self: *Position, snap: mclient.Snapshot, now_ns: i64) i64 {
        var key: [640]u8 = undefined;
        const key_len = trackKey(&key, snap);
        const same = self.track_len == key_len and
            std.mem.eql(u8, self.track[0..key_len], key[0..key_len]);

        var raw = snap.position_us;
        if (raw == 0 and self.pos_us > 2_000_000 and same) raw = self.last_raw;

        var seek = false;
        if (self.last_raw > 0 and same) {
            const delta = raw - self.last_raw;
            seek = delta > 2_000_000 or delta < -2_000_000;
        }

        if (!same or seek) {
            @memcpy(self.track[0..key_len], key[0..key_len]);
            self.track_len = key_len;
            self.pos_us = raw;
        } else if (snap.playing()) {
            self.pos_us += @divTrunc(now_ns - self.at_ns, 1000);
        }
        // `at_ns` is refreshed either way, so a pause costs no time when the
        // track starts moving again: the reading resumes where the player
        // says it is rather than where the wall clock got to.
        self.at_ns = now_ns;
        self.last_raw = raw;
        if (snap.duration_us <= 0) return self.pos_us;
        return @min(self.pos_us, snap.duration_us);
    }
};

fn trackKey(out: []u8, snap: mclient.Snapshot) usize {
    var n: usize = 0;
    for (snap.track_id) |c| {
        if (n >= out.len) break;
        out[n] = c;
        n += 1;
    }
    if (n < out.len) {
        out[n] = 0x1f;
        n += 1;
    }
    for (snap.title) |c| {
        if (n >= out.len) break;
        out[n] = c;
        n += 1;
    }
    return n;
}

// Painting

pub fn paint(cr: ?*cairo.cairo_t, g: Geometry, p: Pill, pos: *Position) Result {
    var out: Result = .{};
    const c = cr orelse return out;
    if (g.slot_w <= 1.0 or g.icon_px <= 0.0) return out;

    // ph0 "body" covers frame setup, the pill, the disc and the artwork;
    // ph1 "content" the text run; ph2 "ring" the progress border.
    const probe = perf.get(.dock);
    probe.begin("body");

    const s = scaleOf(g.icon_px);
    const art_dia = artDiameter(g.icon_px);
    const art_r = art_dia * 0.5;
    const i_gap = gapBefore(s);
    const btn_gap = gapBetweenButtons(s);
    const pill_h = g.slot_h * pill.pill_height_mul;
    const pill_y = g.y + (g.slot_h - pill_h) * 0.5;
    const cy = pill_y + pill_h * 0.5;
    const rad = pill.cornerRadius(pill_h, g.slot_w);
    const inner = rad + k_outer_hpad;

    const real_active = p.snap.realActive();
    const ctrl_w: f64 = if (real_active) ctrlRowWidth(s) else 0.0;
    const max_text = textBudget(g.slot_w, inner, art_dia, i_gap, ctrl_w, p.title_scale * s);
    const title_m = displayTitle(p.snap);
    const artist_m: []const u8 = if (real_active) p.snap.artist else "";

    cairo.cairo_save(c);
    pill.paintPill(c, g.x, pill_y, g.slot_w, pill_h);
    pill.pillClipPath(c, g.x, pill_y, g.slot_w, pill_h);
    cairo.cairo_clip(c);

    const art_cx = g.x + inner + art_r;

    // The disc the artwork sits in, always drawn: the cover replaces it, the
    // placeholder pair leaves it showing.
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, art_cx, cy, art_r, 0, tau);
    cairo.cairo_set_source_rgba(c, 0.18, 0.20, 0.22, 1.0);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.12);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);

    const text_x = g.x + inner + art_dia + i_gap;
    probe.milestone(1, "content");
    out.wants_marquee = paintContent(c, .{
        .art_cx = art_cx,
        .cy = cy,
        .art_r = art_r,
        .art_dia = art_dia,
        .text_x = text_x,
        .title = title_m,
        .artist = artist_m,
        .active = real_active,
        .show_text = p.show_text,
        .alpha = k_text_alpha,
        .art = p.art,
        .m = p.measured,
        .max_text = max_text,
        .s = s,
        .now_sec = p.now_sec,
    });

    if (p.pointer_x >= 0.0) {
        const dx = p.pointer_x - art_cx;
        const dy = p.pointer_y - cy;
        if (dx * dx + dy * dy <= art_r * art_r) {
            ring(c, art_cx, cy, art_r - 1.0, pill.style.hover_accent_r, pill.style.hover_accent_g, pill.style.hover_accent_b, k_ring_art, 2.5);
        }
    }

    if (real_active) {
        const bsr = smallRadius(s);
        const bpr = playRadius(s);
        const ctrl_right = g.x + g.slot_w - inner;
        const next_cx = ctrl_right - bsr;
        const play_cx = next_cx - bsr - btn_gap - bpr;
        const prev_cx = play_cx - bpr - btn_gap - bsr;
        const playing = p.snap.playing();
        const g_small: f64 = std.math.clamp(13.0 * s, 12.0, 18.0);
        const g_play: f64 = std.math.clamp(16.0 * s, 14.0, 21.0);

        const st = pill.style;
        fillCircle(c, prev_cx, cy, bsr, st.media_btn_r, st.media_btn_g, st.media_btn_b, if (p.snap.can_go_previous) k_btn_bg_on else k_btn_bg);
        if (p.hover_btn == 0) ring(c, prev_cx, cy, bsr - 1.0, st.hover_accent_r, st.hover_accent_g, st.hover_accent_b, k_ring_btn, 2.0);
        _ = glyphs.draw(c, "skip_previous", prev_cx, cy, g_small, st.media_glyph_r, st.media_glyph_g, st.media_glyph_b, 1.0);

        fillCircle(c, play_cx, cy, bpr, st.hover_accent_r, st.hover_accent_g, st.hover_accent_b, if (playing) 0.95 else k_btn_bg);
        if (p.hover_btn == 1) ring(c, play_cx, cy, bpr - 1.0, st.hover_accent_r, st.hover_accent_g, st.hover_accent_b, k_ring_btn, 2.0);
        if (playing) {
            _ = glyphs.draw(c, "pause", play_cx, cy, g_play, st.media_on_accent_r, st.media_on_accent_g, st.media_on_accent_b, 1.0);
        } else {
            _ = glyphs.draw(c, "play_arrow", play_cx, cy, g_play, st.media_glyph_r, st.media_glyph_g, st.media_glyph_b, 1.0);
        }

        fillCircle(c, next_cx, cy, bsr, st.media_btn_r, st.media_btn_g, st.media_btn_b, if (p.snap.can_go_next) k_btn_bg_on else k_btn_bg);
        if (p.hover_btn == 2) ring(c, next_cx, cy, bsr - 1.0, st.hover_accent_r, st.hover_accent_g, st.hover_accent_b, k_ring_btn, 2.0);
        _ = glyphs.draw(c, "skip_next", next_cx, cy, g_small, st.media_glyph_r, st.media_glyph_g, st.media_glyph_b, 1.0);
    }

    cairo.cairo_restore(c);

    probe.milestone(2, "ring");
    out.progress_tick = paintProgress(c, .{
        .x = g.x,
        .pill_y = pill_y,
        .slot_w = g.slot_w,
        .pill_h = pill_h,
        .rad = rad,
        .snap = p.snap,
        .active = real_active,
        .pos = pos,
        .now_ns = p.now_ns,
    });
    probe.end(.{
        .playing = p.snap.playing(),
        .est_us = pos.pos_us,
        .snap_us = p.snap.position_us,
        .dur_us = p.snap.duration_us,
    });
    return out;
}

const ContentInputs = struct {
    art_cx: f64,
    cy: f64,
    art_r: f64,
    art_dia: f64,
    text_x: f64,
    title: []const u8,
    artist: []const u8,
    active: bool,
    show_text: bool,
    alpha: f64,
    art: Art,
    m: Measured,
    max_text: f64,
    s: f64,
    now_sec: f64,
};

fn paintContent(cr: ?*cairo.cairo_t, in: ContentInputs) bool {
    const c = cr orelse return false;
    var wants = false;

    if (in.active and in.art.present()) {
        paintArt(c, in.art, in.art_cx, in.cy, in.art_dia);
    } else {
        cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, in.alpha);
        const nr = in.art_r * 0.28;
        cairo.cairo_new_path(c);
        cairo.cairo_arc(c, in.art_cx - in.art_r * 0.08, in.cy + in.art_r * 0.06, nr, 0, tau);
        cairo.cairo_fill(c);
        cairo.cairo_new_path(c);
        cairo.cairo_arc(c, in.art_cx + in.art_r * 0.10, in.cy - in.art_r * 0.02, nr * 0.85, 0, tau);
        cairo.cairo_fill(c);
    }

    if (!in.show_text) return wants;

    const title_nat = in.m.title_nat_w;
    const artist_nat = in.m.artist_nat_w;
    const between = in.m.between_w;

    var title_alloc: f64 = 0.0;
    var artist_alloc: f64 = 0.0;
    if (in.artist.len == 0) {
        title_alloc = @min(title_nat, in.max_text);
    } else {
        const need = title_nat + artist_nat + between;
        if (need <= in.max_text + 0.5) {
            title_alloc = title_nat;
            artist_alloc = artist_nat;
        } else {
            const room = @max(0.0, in.max_text - between);
            const sum = title_nat + artist_nat;
            if (sum <= 0.5 or room <= 0.5) {
                title_alloc = room * 0.5;
                artist_alloc = room - title_alloc;
            } else {
                title_alloc = @floor(room * title_nat / sum);
                artist_alloc = room - title_alloc;
                if (title_alloc < k_min_seg) {
                    title_alloc = k_min_seg;
                    artist_alloc = @max(k_min_seg, room - title_alloc);
                } else if (artist_alloc < k_min_seg) {
                    artist_alloc = k_min_seg;
                    title_alloc = @max(k_min_seg, room - artist_alloc);
                }
            }
        }
    }

    var lt = newLayout(c, titleFontPx(in.s));
    defer lt.destroy();
    lt.setWidthUnits(@intFromFloat(title_alloc * pango_scale));
    lt.setWrap(text.WRAP_WORD_CHAR);
    pango_layout_set_ellipsize(lt.layout, ellipsize_end);
    lt.setText(in.title);
    const th: f64 = @floatFromInt(lt.pixelSize().h);

    const title_scroll = title_nat > title_alloc + 0.5 and title_nat > k_scroll_floor * in.s;
    if (title_scroll) wants = true;

    var la = newLayout(c, artistFontPx(in.s));
    defer la.destroy();
    var artist_h: f64 = 0.0;
    if (in.artist.len > 0) {
        la.setWidthUnits(@intFromFloat(artist_alloc * pango_scale));
        la.setWrap(text.WRAP_WORD_CHAR);
        pango_layout_set_ellipsize(la.layout, ellipsize_end);
        la.setText(in.artist);
        artist_h = @floatFromInt(la.pixelSize().h);
    }
    const artist_scroll = in.artist.len > 0 and
        artist_nat > artist_alloc + 0.5 and
        artist_nat > k_scroll_floor * in.s;

    const row_h = @max(th, artist_h);
    const row_top = in.cy - row_h * 0.5;
    const title_y = row_top + (row_h - th) * 0.5 + 1.0;
    const artist_x = in.text_x + title_alloc + between;
    const artist_y = row_top + (row_h - artist_h) * 0.5 + 1.0;

    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, in.alpha);
    if (title_scroll) {
        const range = title_nat - title_alloc;
        const off = marqueeOffset(range, in.now_sec, k_marquee_period);
        cairo.cairo_save(c);
        cairo.cairo_rectangle(c, in.text_x, row_top - 1.0, title_alloc, th + 3.0);
        cairo.cairo_clip(c);
        naturalSingleLine(&lt);
        lt.setText(in.title);
        cairo.cairo_move_to(c, in.text_x - off, title_y);
        lt.show(c);
        cairo.cairo_restore(c);
        lt.setWidthUnits(@intFromFloat(title_alloc * pango_scale));
        lt.setWrap(text.WRAP_WORD_CHAR);
        pango_layout_set_ellipsize(lt.layout, ellipsize_end);
    } else {
        cairo.cairo_move_to(c, in.text_x, title_y);
        lt.show(c);
    }

    if (in.artist.len > 0) {
        var dot = newLayout(c, artistFontPx(in.s));
        defer dot.destroy();
        naturalSingleLine(&dot);
        dot.setText(k_dot);
        const ds = dot.pixelSize();
        const dot_w: f64 = @floatFromInt(ds.w);
        const dot_h: f64 = @floatFromInt(ds.h);
        cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, in.alpha);
        cairo.cairo_move_to(c, in.text_x + title_alloc + (between - dot_w) * 0.5, row_top + (row_h - dot_h) * 0.5);
        dot.show(c);
    }

    if (in.artist.len > 0) {
        cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, in.alpha);
        if (artist_scroll) {
            wants = true;
            const range = artist_nat - artist_alloc;
            const off = marqueeOffset(range, in.now_sec + 2.7, k_marquee_period);
            cairo.cairo_save(c);
            cairo.cairo_rectangle(c, artist_x, row_top - 1.0, artist_alloc, artist_h + 3.0);
            cairo.cairo_clip(c);
            naturalSingleLine(&la);
            la.setText(in.artist);
            cairo.cairo_move_to(c, artist_x - off, artist_y);
            la.show(c);
            cairo.cairo_restore(c);
        } else {
            cairo.cairo_move_to(c, artist_x, artist_y);
            la.show(c);
        }
    }
    return wants;
}

fn naturalSingleLine(l: *text.Layout) void {
    l.setWidthUnits(-1);
    l.setWrap(wrap_none);
    pango_layout_set_ellipsize(l.layout, 0);
}

/// The cover, drawn into the disc: cover-scaled so the art fills the circle
/// without distortion, with the edges padded rather than wrapped.
pub fn paintArt(cr: ?*cairo.cairo_t, art: Art, cx: f64, cy: f64, dia: f64) void {
    const c = cr orelse return;
    if (!art.present()) return;
    const surf = cairo.cairo_image_surface_create_for_data(
        @constCast(art.pixels.ptr),
        cairo.CAIRO_FORMAT_ARGB32,
        art.w,
        art.h,
        art.w * 4,
    );
    defer cairo.cairo_surface_destroy(surf);
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) return;

    cairo.cairo_save(c);
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, cx, cy, dia * 0.5, 0, tau);
    cairo.cairo_clip(c);
    const sc = @max(dia / @as(f64, @floatFromInt(art.w)), dia / @as(f64, @floatFromInt(art.h)));
    cairo.cairo_translate(c, cx - dia * 0.5, cy - dia * 0.5);
    cairo.cairo_scale(c, sc, sc);
    cairo.cairo_set_source_surface(c, surf, 0.0, 0.0);
    cairo.cairo_pattern_set_extend(cairo.cairo_get_source(c), cairo.CAIRO_EXTEND_PAD);
    cairo.cairo_paint(c);
    cairo.cairo_restore(c);
}

const ProgressInputs = struct {
    x: f64,
    pill_y: f64,
    slot_w: f64,
    pill_h: f64,
    rad: f64,
    snap: mclient.Snapshot,
    active: bool,
    pos: *Position,
    now_ns: i64,
};

/// A single dash wrapped around the pill, long enough to cover the fraction
/// already played. Live streams have no duration to divide by, so they stay
/// borderless.
fn paintProgress(cr: ?*cairo.cairo_t, in: ProgressInputs) bool {
    const c = cr orelse return false;
    if (!in.active) return false;
    if (!in.snap.playing() or in.snap.duration_us <= 0) return false;
    if (std.mem.indexOf(u8, in.snap.track_url, "twitch.tv") != null) return false;

    const pos_us = in.pos.project(in.snap, in.now_ns);
    const frac = std.math.clamp(@as(f64, @floatFromInt(pos_us)) / @as(f64, @floatFromInt(in.snap.duration_us)), 0.0, 1.0);
    if (frac <= 0.005) return false;

    const peri = progressPerimeter(in.slot_w, in.pill_h, in.rad);
    var dashes = [2]f64{ peri * frac, peri * 1.0e6 };
    cairo.cairo_save(c);
    cairo.cairo_set_dash(c, &dashes, 2, 0.0);
    cairo.cairo_set_line_width(c, 2.5);
    cairo.cairo_set_source_rgba(c, pill.style.hover_accent_r, pill.style.hover_accent_g, pill.style.hover_accent_b, 0.7);
    cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);

    const x = in.x;
    const pill_y = in.pill_y;
    const rad = in.rad;
    const sw = in.slot_w;
    const ph = in.pill_h;
    cairo.cairo_new_path(c);
    cairo.cairo_move_to(c, x + rad, pill_y);
    cairo.cairo_line_to(c, x + sw - rad, pill_y);
    cairo.cairo_arc(c, x + sw - rad, pill_y + rad, rad, -std.math.pi * 0.5, 0.0);
    cairo.cairo_line_to(c, x + sw, pill_y + ph - rad);
    cairo.cairo_arc(c, x + sw - rad, pill_y + ph - rad, rad, 0.0, std.math.pi * 0.5);
    cairo.cairo_line_to(c, x + rad, pill_y + ph);
    cairo.cairo_arc(c, x + rad, pill_y + ph - rad, rad, std.math.pi * 0.5, std.math.pi);
    cairo.cairo_line_to(c, x, pill_y + rad);
    cairo.cairo_arc(c, x + rad, pill_y + rad, rad, std.math.pi, 3.0 * std.math.pi * 0.5);
    cairo.cairo_stroke(c);
    cairo.cairo_set_dash(c, null, 0, 0.0);
    cairo.cairo_restore(c);
    return true;
}

fn fillCircle(cr: ?*cairo.cairo_t, cx: f64, cy: f64, r: f64, rr: f64, gg: f64, bb: f64, aa: f64) void {
    const c = cr orelse return;
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, cx, cy, r, 0, tau);
    cairo.cairo_set_source_rgba(c, rr, gg, bb, aa);
    cairo.cairo_fill(c);
}

fn ring(cr: ?*cairo.cairo_t, cx: f64, cy: f64, r: f64, rr: f64, gg: f64, bb: f64, aa: f64, width: f64) void {
    const c = cr orelse return;
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, cx, cy, r, 0, tau);
    cairo.cairo_close_path(c);
    cairo.cairo_set_source_rgba(c, rr, gg, bb, aa);
    cairo.cairo_set_line_width(c, width);
    cairo.cairo_stroke(c);
}

test "media pill: the 44 px reference size lands on the documented geometry" {
    const t = std.testing;
    const s = scaleOf(44.0);
    try t.expectApproxEqAbs(@as(f64, 1.466667), s, 1e-4);
    try t.expectApproxEqAbs(@as(f64, 34.32), artDiameter(44.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 14.66667), gapBefore(s) + gapBetweenButtons(s) - 8.8, 1e-3);
    // 4 small + 2 play + both gaps.
    try t.expectApproxEqAbs(@as(f64, 4 * 11.73333 + 2 * 8.8 + 2 * 13.93333), ctrlRowWidth(s), 1e-3);
    try t.expectEqual(@as(f64, 15.0), titleFontPx(s));
    try t.expectEqual(@as(f64, 13.0), artistFontPx(s));
}

test "media pill: hit zones run previous, play, next, then the disc" {
    const t = std.testing;
    const w: f64 = 200.0;
    const icon: f64 = 44.0;
    // Disc first, then the gap, then the three controls right-aligned.
    try t.expectEqual(@as(i32, 3), hitZone(20.0, w, icon));
    try t.expectEqual(@as(i32, -1), hitZone(70.0, w, icon));
    try t.expectEqual(@as(i32, 0), hitZone(105.0, w, icon));
    try t.expectEqual(@as(i32, 1), hitZone(140.0, w, icon));
    try t.expectEqual(@as(i32, 2), hitZone(175.0, w, icon));
    try t.expectEqual(@as(i32, -1), hitZone(196.0, w, icon));
    // Degenerate slots never report a control.
    try t.expectEqual(@as(i32, -1), hitZone(10.0, 0.5, icon));
    try t.expectEqual(@as(i32, -1), hitZone(10.0, w, 0.0));
}

test "media pill: the marquee is a triangle wave over the period" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f64, 0.0), marqueeOffset(0.0, 3.0, 12.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 0.0), marqueeOffset(100.0, 0.0, 12.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 50.0), marqueeOffset(100.0, 3.0, 12.0), 1e-9);
    // Halfway through it has run all the way out, and then it returns.
    try t.expectApproxEqAbs(@as(f64, 100.0), marqueeOffset(100.0, 6.0, 12.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 50.0), marqueeOffset(100.0, 9.0, 12.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 0.0), marqueeOffset(100.0, 12.0, 12.0), 1e-9);
}

test "media pill: the text budget never starves and never overruns the slot" {
    const t = std.testing;
    // A narrow slot bottoms out at 48 px rather than collapsing.
    try t.expectApproxEqAbs(@as(f64, 48.0), textBudget(60.0, 10.0, 34.0, 14.0, 92.0, 500.0), 1e-9);
    // A wide slot is capped by the configured limit, not by the room.
    try t.expectApproxEqAbs(@as(f64, 500.0), textBudget(900.0, 10.0, 34.0, 14.0, 92.0, 500.0), 1e-9);
}

test "media pill: the resting row names what is missing" {
    const t = std.testing;
    try t.expectEqualStrings("No Media", displayTitle(.{}));
    // A running player with nothing to say still rests.
    try t.expectEqualStrings("No Media", displayTitle(.{ .have_player = true }));
    // A player with only an artist still gets the fallback title.
    try t.expectEqualStrings("Unknown title", displayTitle(.{ .have_player = true, .artist = "Someone" }));
    try t.expectEqualStrings("Song", displayTitle(.{ .have_player = true, .title = "Song", .artist = "Someone" }));
}

test "media pill: the playhead is projected between readings" {
    const t = std.testing;
    var pos = Position{};
    const base: i64 = 1_000_000;
    const dur: i64 = 10_000_000;
    var snap = mclient.Snapshot{
        .have_player = true,
        .title = "Song",
        .track_id = "/track/1",
        .status = "Playing",
        .position_us = base,
        .duration_us = dur,
    };

    // The first reading is taken as-is.
    try t.expectEqual(@as(i64, base), pos.project(snap, 1_000_000_000));
    // Two seconds later, with no new reading, the elapsed time stands in.
    try t.expectEqual(@as(i64, base + 2_000_000), pos.project(snap, 3_000_000_000));
    // It never runs past the end of the track.
    try t.expectEqual(dur, pos.project(snap, 40_000_000_000));

    // A jump of more than two seconds is a seek, not drift, and resynchronises.
    snap.position_us = 6_000_000;
    try t.expectEqual(@as(i64, 6_000_000), pos.project(snap, 41_000_000_000));

    // A zero reading on the same track keeps projecting from the last good one.
    snap.position_us = 0;
    try t.expectEqual(@as(i64, 8_000_000), pos.project(snap, 43_000_000_000));

    // Another track starts over.
    snap.title = "Next Song";
    snap.position_us = 500_000;
    try t.expectEqual(@as(i64, 500_000), pos.project(snap, 44_000_000_000));
}
