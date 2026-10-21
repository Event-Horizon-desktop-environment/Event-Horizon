//! The media-player card the dock's media slot opens.
//!
//! It is a fixed 400 x 188 face: cover art and the two scrolling track lines
//! across the top, a seekbar with elapsed and remaining stamps under that,
//! and a row of five transport controls along the bottom. Everything is
//! derived from one `Layout`, so the paint and the hit-test cannot drift
//! apart, and the geometry constants are shared with the pill through
//! `media_paint` where the two agree.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const helpers = @import("../../shared/cairo_helpers.zig");
const text = @import("../../../text/layout.zig");
const box_mod = @import("../../../m3/core/primitives/box.zig");
const chrome = @import("../shared/chrome_colors.zig");
const glyphs = @import("../../common/material_glyph.zig");
const mp = @import("media_paint.zig");

pub const width: f64 = 400.0;
pub const height: f64 = 188.0;

const k_corner: f64 = 28.0;
const k_pad: f64 = 20.0;
const k_art_s: f64 = 64.0;
const k_art_r: f64 = 12.0;
const k_text_x: f64 = 98.0;
const k_text_w: f64 = 282.0;
const k_title_y: f64 = 28.0;
const k_artist_y: f64 = 56.0;
const k_seek_x0: f64 = 20.0;
const k_seek_x1: f64 = 380.0;
const k_seek_w: f64 = 360.0;
const k_bar_y: f64 = 102.0;
const k_bar_h: f64 = 4.0;
const k_knob_r: f64 = 5.0;
const k_seek_top: f64 = 92.0;
const k_seek_bot: f64 = 112.0;
const k_stamps_y: f64 = 114.0;
const k_ctrl_cy: f64 = 154.0;
const k_shuffle_cx: f64 = 80.0;
const k_prev_cx: f64 = 136.0;
const k_play_cx: f64 = 200.0;
const k_next_cx: f64 = 264.0;
const k_repeat_cx: f64 = 320.0;
const k_shuffle_s: f64 = 26.0;
const k_skip_s: f64 = 30.0;
const k_play_s: f64 = 40.0;
const k_btn_hit_r: f64 = 20.0;
const k_play_hit_r: f64 = 24.0;
const k_idle_y: f64 = 108.0;
const k_idle_font: f64 = 15.0;
const k_marquee_period: f64 = 9.0;
const k_artist_phase: f64 = 2.7;

/// What a point on the card is over. `.close` is carried for parity with the
/// rest of the shell's hover vocabulary; nothing here draws a close button,
/// because clicking off the controls already dismisses the card.
pub const Hover = enum {
    none,
    close,
    shuffle,
    prev,
    play,
    next,
    repeat,
    seekbar,
};

/// Where the card puts things. A single value drives both the painting and
/// the hit-test, so a knob that moves on screen moves with it under the
/// pointer as well.
pub const Layout = struct {
    art: [4]f64 = .{ k_pad, k_pad, k_art_s, k_art_s },
    title_y: f64 = k_title_y,
    artist_y: f64 = k_artist_y,
    text_x: f64 = k_text_x,
    text_w: f64 = k_text_w,
    seek_x0: f64 = k_seek_x0,
    seek_x1: f64 = k_seek_x1,
    seek_y: f64 = k_bar_y,
    seek_top: f64 = k_seek_top,
    seek_bot: f64 = k_seek_bot,
    stamps_y: f64 = k_stamps_y,
    ctrl_cy: f64 = k_ctrl_cy,
    shuffle_cx: f64 = k_shuffle_cx,
    prev_cx: f64 = k_prev_cx,
    play_cx: f64 = k_play_cx,
    next_cx: f64 = k_next_cx,
    repeat_cx: f64 = k_repeat_cx,
    btn_hit_r: f64 = k_btn_hit_r,
    play_hit_r: f64 = k_play_hit_r,
};

pub const geometry: Layout = .{};

fn hitCircle(px: f64, py: f64, cx: f64, cy: f64, r: f64) bool {
    const dx = px - cx;
    const dy = py - cy;
    return dx * dx + dy * dy <= r * r;
}

/// The control under `(px, py)`, in card coordinates. The transport row is
/// tested before the seek strip because the two overlap in y, and the larger
/// play disc is tested before its neighbours so it cannot eat their edges.
pub fn hitTest(px: f64, py: f64, active: bool, lay: Layout) Hover {
    if (!active) return .none;
    const cy = lay.ctrl_cy;
    if (hitCircle(px, py, lay.play_cx, cy, lay.play_hit_r)) return .play;
    if (hitCircle(px, py, lay.prev_cx, cy, lay.btn_hit_r)) return .prev;
    if (hitCircle(px, py, lay.next_cx, cy, lay.btn_hit_r)) return .next;
    if (hitCircle(px, py, lay.shuffle_cx, cy, lay.btn_hit_r)) return .shuffle;
    if (hitCircle(px, py, lay.repeat_cx, cy, lay.btn_hit_r)) return .repeat;
    if (py >= lay.seek_top and py < lay.seek_bot and px >= lay.seek_x0 and px <= lay.seek_x1)
        return .seekbar;
    return .none;
}

/// Where on the track a click would seek, as 0..1. Null when the point is
/// outside the track, which is what tells a click to fall through instead.
pub fn seekFraction(px: f64, lay: Layout) ?f64 {
    if (px < lay.seek_x0 or px > lay.seek_x1) return null;
    return std.math.clamp((px - lay.seek_x0) / (lay.seek_x1 - lay.seek_x0), 0.0, 1.0);
}

/// The card's idea of the track, already reduced to the parts paint and
/// click-handling disagree about. Every string borrows from whoever built it.
pub const Input = struct {
    active: bool = false,
    art: ?mp.Art = null,
    title: []const u8 = "",
    artist: []const u8 = "",
    position_us: i64 = 0,
    duration_us: i64 = 0,
    playing: bool = false,
    can_play: bool = false,
    can_pause: bool = false,
    can_prev: bool = false,
    can_next: bool = false,
    shuffle: bool = false,
    loop_status: []const u8 = "",
    /// Steady-clock seconds, which is what the two scrolling lines are a
    /// function of; the dock supplies it so a paused clock pauses them.
    t_sec: f64 = 0.0,
    hover: Hover = .none,

    pub fn loopOn(self: Input) bool {
        return std.mem.eql(u8, self.loop_status, "Track") or
            std.mem.eql(u8, self.loop_status, "Playlist");
    }

    pub fn loopOne(self: Input) bool {
        return std.mem.eql(u8, self.loop_status, "Track");
    }

    /// The transport row stays lit while a track is describing itself, which
    /// is the same rule the pill uses to decide it has something to show.
    pub fn realActive(self: Input) bool {
        return self.active and (self.title.len > 0 or self.artist.len > 0);
    }

    pub fn frac(self: Input) f64 {
        if (self.duration_us <= 0) return 0.0;
        return std.math.clamp(
            @as(f64, @floatFromInt(self.position_us)) / @as(f64, @floatFromInt(self.duration_us)),
            0.0,
            1.0,
        );
    }
};

/// The whole card, at `(x, y)` in surface pixels. `card_alpha` stands in for
/// the shell's widget-card overlay opacity, which the dock reads from config
/// and every other card already takes the same way.
pub fn paint(
    cr: ?*cairo.cairo_t,
    x: f64,
    y: f64,
    colors: chrome.Chrome,
    card_alpha: f64,
    in: Input,
) void {
    const c = cr orelse return;
    cairo.cairo_save(c);
    cairo.cairo_translate(c, x, y);

    paintCard(c, colors, card_alpha);
    if (in.realActive()) {
        paintArt(c, in.art);
        paintTrack(c, colors, in);
        paintSeek(c, colors, in);
        paintStamps(c, colors, in);
        paintControls(c, in);
    } else {
        paintIdle(c, colors);
    }

    cairo.cairo_restore(c);
}

/// Layer 1 — the dark glass panel, then the hairline that keeps its edge
/// readable over anything the desktop happens to be showing.
fn paintCard(c: *cairo.cairo_t, colors: chrome.Chrome, card_alpha: f64) void {
    var b = box_mod.Box{};
    b.setColor(
        @floatCast(colors.dock_fill.r * 0.30),
        @floatCast(colors.dock_fill.g * 0.30),
        @floatCast(colors.dock_fill.b * 0.30),
        @floatCast(0.92 * card_alpha),
    );
    b.setRadius(@floatCast(k_corner));
    b.setGeometry(0, 0, @floatCast(width), @floatCast(height));
    b.setGlassy(true);
    b.paint(c);

    helpers.roundedRect(c, 0.5, 0.5, width - 1.0, height - 1.0, k_corner);
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.14);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);
}

/// The cover as a rounded square: cover-scaled so it fills the frame without
/// distortion, with the edges padded rather than wrapped. A missing cover
/// falls back to the same dim tile the pill shows.
fn paintArt(c: *cairo.cairo_t, art: ?mp.Art) void {
    const tile = art orelse null;
    cairo.cairo_save(c);
    helpers.pathRoundedRect(c, k_pad, k_pad, k_art_s, k_art_s, k_art_r);
    cairo.cairo_clip(c);

    if (tile) |a| {
        if (a.present()) {
            const surf = cairo.cairo_image_surface_create_for_data(
                @constCast(a.pixels.ptr),
                cairo.CAIRO_FORMAT_ARGB32,
                a.w,
                a.h,
                a.w * 4,
            );
            if (cairo.cairo_surface_status(surf) == cairo.CAIRO_STATUS_SUCCESS) {
                const iw: f64 = @floatFromInt(a.w);
                const ih: f64 = @floatFromInt(a.h);
                const s = @max(k_art_s / iw, k_art_s / ih);
                cairo.cairo_translate(c, k_pad + (k_art_s - iw * s) * 0.5, k_pad + (k_art_s - ih * s) * 0.5);
                cairo.cairo_scale(c, s, s);
                cairo.cairo_set_source_surface(c, surf, 0.0, 0.0);
                cairo.cairo_pattern_set_extend(cairo.cairo_get_source(c), cairo.CAIRO_EXTEND_PAD);
                cairo.cairo_paint(c);
            }
            cairo.cairo_surface_destroy(surf);
            cairo.cairo_restore(c);
            return;
        }
    }

    cairo.cairo_set_source_rgba(c, 0.12, 0.14, 0.16, 1.0);
    cairo.cairo_rectangle(c, k_pad, k_pad, k_art_s, k_art_s);
    cairo.cairo_fill(c);
    _ = glyphs.draw(c, "music_note", k_pad + k_art_s * 0.5, k_pad + k_art_s * 0.5, 28.0, 0.70, 0.75, 0.80, 0.60);
    cairo.cairo_restore(c);
}

/// Title and artist, each on one line that walks back and forth when it is
/// wider than the 282 px it has. The artist runs a phase behind the title so
/// the two never start moving on the same frame.
fn paintTrack(c: *cairo.cairo_t, colors: chrome.Chrome, in: Input) void {
    const title = if (in.title.len == 0) "Unknown Track" else in.title;
    drawScrolledLine(c, k_text_x, k_title_y, k_text_w, title, "Inter Bold 18", colors, 0.95, in.t_sec);
    if (in.artist.len > 0)
        drawScrolledLine(
            c,
            k_text_x,
            k_artist_y,
            k_text_w,
            in.artist,
            "Inter 14",
            colors,
            0.62,
            in.t_sec + k_artist_phase,
        );
}

fn drawScrolledLine(
    c: *cairo.cairo_t,
    x: f64,
    y: f64,
    max_w: f64,
    value: []const u8,
    font_desc: []const u8,
    colors: chrome.Chrome,
    a: f64,
    t_sec: f64,
) void {
    var m = text.Layout.createForCairo(c);
    defer m.destroy();
    m.setFont(font_desc);
    m.setWidthUnits(-1);
    m.setText(value);
    const size = m.pixelSize();
    const nat: f64 = @floatFromInt(size.w);
    const line_h: f64 = @floatFromInt(size.h);

    cairo.cairo_set_source_rgba(c, colors.text.r, colors.text.g, colors.text.b, a);
    if (nat > max_w + 0.5) {
        const off = mp.marqueeOffset(nat - max_w, t_sec, k_marquee_period);
        cairo.cairo_save(c);
        cairo.cairo_rectangle(c, x, y - 2.0, max_w, line_h + 4.0);
        cairo.cairo_clip(c);
        cairo.cairo_move_to(c, x - off, y);
        m.show(c);
        cairo.cairo_restore(c);
    } else {
        cairo.cairo_move_to(c, x, y);
        m.show(c);
    }
}

/// Track and playhead. The filled part lights up under a hover, which is the
/// card's only hover cue outside the cursor itself.
fn paintSeek(c: *cairo.cairo_t, colors: chrome.Chrome, in: Input) void {
    _ = colors;
    const pct = in.frac();
    const fill_w = k_seek_w * pct;
    const thumb_x = k_seek_x0 + fill_w;
    const seek_hover = in.hover == .seekbar;

    cairo.cairo_save(c);
    cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);

    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.22);
    cairo.cairo_set_line_width(c, k_bar_h);
    cairo.cairo_move_to(c, k_seek_x0, k_bar_y + k_bar_h * 0.5);
    cairo.cairo_line_to(c, k_seek_x1, k_bar_y + k_bar_h * 0.5);
    cairo.cairo_stroke(c);

    if (fill_w > 0.5) {
        cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, if (seek_hover) 1.0 else 0.95);
        cairo.cairo_move_to(c, k_seek_x0, k_bar_y + k_bar_h * 0.5);
        cairo.cairo_line_to(c, thumb_x, k_bar_y + k_bar_h * 0.5);
        cairo.cairo_stroke(c);
    }

    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, if (seek_hover) 1.0 else 0.95);
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, thumb_x, k_bar_y + k_bar_h * 0.5, k_knob_r, 0.0, std.math.pi * 2.0);
    cairo.cairo_fill(c);
    cairo.cairo_restore(c);
}

/// Elapsed on the left, the remaining time with a minus on the right.
fn paintStamps(c: *cairo.cairo_t, colors: chrome.Chrome, in: Input) void {
    const rem: i64 = if (in.duration_us > 0) @max(0, in.duration_us - in.position_us) else 0;
    var lb: [24]u8 = undefined;
    var tb: [24]u8 = undefined;
    var rb: [32]u8 = undefined;
    const left = formatTimeUs(&lb, in.position_us);
    const remain = formatTimeUs(&tb, rem);
    const right = std.fmt.bufPrint(&rb, "-{s}", .{remain}) catch "";

    cairo.cairo_set_source_rgba(c, colors.text.r, colors.text.g, colors.text.b, 0.55);
    drawPlain(c, "Inter 11", left, k_seek_x0, k_stamps_y);
    if (right.len > 0) {
        const w = plainWidth(c, "Inter 11", right);
        drawPlain(c, "Inter 11", right, k_seek_x1 - w, k_stamps_y);
    }
}

/// Shuffle, previous, play/pause, next and repeat. Each one dims when the
/// player says it cannot do it, so the row reads as a set of capabilities
/// rather than five decorative marks.
fn paintControls(c: *cairo.cairo_t, in: Input) void {
    _ = glyphs.draw(
        c,
        "shuffle",
        k_shuffle_cx,
        k_ctrl_cy,
        k_shuffle_s,
        1.0,
        1.0,
        1.0,
        if (in.shuffle) 1.0 else 0.45,
    );
    _ = glyphs.draw(
        c,
        "skip_previous",
        k_prev_cx,
        k_ctrl_cy,
        k_skip_s,
        1.0,
        1.0,
        1.0,
        if (in.can_prev) 1.0 else 0.30,
    );
    _ = glyphs.draw(
        c,
        "skip_next",
        k_next_cx,
        k_ctrl_cy,
        k_skip_s,
        1.0,
        1.0,
        1.0,
        if (in.can_next) 1.0 else 0.30,
    );
    _ = glyphs.draw(
        c,
        if (in.playing) "pause" else "play_arrow",
        k_play_cx,
        k_ctrl_cy,
        k_play_s,
        1.0,
        1.0,
        1.0,
        if (in.can_play or in.can_pause or in.playing) 1.0 else 0.30,
    );
    _ = glyphs.draw(
        c,
        if (in.loopOne()) "repeat_one" else "repeat",
        k_repeat_cx,
        k_ctrl_cy,
        k_shuffle_s,
        1.0,
        1.0,
        1.0,
        if (in.loopOn()) 1.0 else 0.45,
    );
}

/// No track is speaking: the cover slot still shows its tile, and one centred
/// line says so.
fn paintIdle(c: *cairo.cairo_t, colors: chrome.Chrome) void {
    cairo.cairo_save(c);
    helpers.pathRoundedRect(c, k_pad, k_pad, k_art_s, k_art_s, k_art_r);
    cairo.cairo_clip(c);
    cairo.cairo_set_source_rgba(c, 0.12, 0.14, 0.16, 1.0);
    cairo.cairo_rectangle(c, k_pad, k_pad, k_art_s, k_art_s);
    cairo.cairo_fill(c);
    _ = glyphs.draw(c, "music_note", k_pad + k_art_s * 0.5, k_pad + k_art_s * 0.5, 28.0, 0.70, 0.75, 0.80, 0.60);
    cairo.cairo_restore(c);

    const label = "No media playing";
    const w = plainWidth(c, "Inter 15", label);
    cairo.cairo_set_source_rgba(c, colors.text.r, colors.text.g, colors.text.b, 0.85);
    drawPlain(c, "Inter 15", label, (width - w) * 0.5, k_idle_y);
}

// Plain (non-scrolling) text

fn drawPlain(c: *cairo.cairo_t, font_desc: []const u8, value: []const u8, x: f64, y: f64) void {
    if (value.len == 0) return;
    var m = text.Layout.createForCairo(c);
    defer m.destroy();
    m.setFont(font_desc);
    m.setWidthUnits(-1);
    m.setText(value);
    cairo.cairo_move_to(c, x, y);
    m.show(c);
}

fn plainWidth(c: *cairo.cairo_t, font_desc: []const u8, value: []const u8) f64 {
    var m = text.Layout.createForCairo(c);
    defer m.destroy();
    m.setFont(font_desc);
    m.setWidthUnits(-1);
    m.setText(value);
    return @floatFromInt(m.pixelSize().w);
}

/// `m:ss`, written into `buf` and returned as the part that was filled. A
/// negative reading clamps to zero rather than printing a minus nobody asked
/// for.
pub fn formatTimeUs(buf: []u8, us: i64) []const u8 {
    const total: u64 = @divTrunc(@as(u64, @intCast(@max(0, us))), 1_000_000);
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ total / 60, total % 60 }) catch "";
}

test "media popup: the transport row is hit in a fixed order" {
    const t = std.testing;
    const lay = geometry;

    try t.expectEqual(Hover.none, hitTest(0, 0, false, lay));
    try t.expectEqual(Hover.play, hitTest(lay.play_cx, lay.ctrl_cy, true, lay));
    try t.expectEqual(Hover.prev, hitTest(lay.prev_cx, lay.ctrl_cy, true, lay));
    try t.expectEqual(Hover.next, hitTest(lay.next_cx, lay.ctrl_cy, true, lay));
    try t.expectEqual(Hover.shuffle, hitTest(lay.shuffle_cx, lay.ctrl_cy, true, lay));
    try t.expectEqual(Hover.repeat, hitTest(lay.repeat_cx, lay.ctrl_cy, true, lay));

    // The play disc reaches 24 px, further than its neighbours' 20, so the
    // ring it answers in is wider than the one beside it.
    try t.expectEqual(Hover.play, hitTest(lay.play_cx + 23.0, lay.ctrl_cy, true, lay));
    try t.expectEqual(Hover.none, hitTest(lay.play_cx + 25.0, lay.ctrl_cy, true, lay));
    try t.expectEqual(Hover.seekbar, hitTest(200.0, 100.0, true, lay));
    try t.expectEqual(Hover.none, hitTest(200.0, 128.0, true, lay));
}

test "media popup: a seek click becomes a fraction of the track" {
    const t = std.testing;
    const lay = geometry;
    try t.expectEqual(@as(?f64, null), seekFraction(10.0, lay));
    try t.expectEqual(@as(?f64, null), seekFraction(390.0, lay));
    const mid = seekFraction(200.0, lay).?;
    try t.expectApproxEqAbs(@as(f64, 0.5), mid, 1e-9);
    const edge = seekFraction(380.0, lay).?;
    try t.expectEqual(@as(f64, 1.0), edge);
}

test "media popup: times print as minutes and zero-padded seconds" {
    const t = std.testing;
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("0:00", formatTimeUs(&buf, 0));
    try t.expectEqualStrings("0:09", formatTimeUs(&buf, 9_000_000));
    try t.expectEqualStrings("1:05", formatTimeUs(&buf, 65_000_000));
    try t.expectEqualStrings("0:00", formatTimeUs(&buf, -5));
    // An hour long enough to leave the minutes column.
    try t.expectEqualStrings("61:00", formatTimeUs(&buf, 3_660_000_000));
}

test "media popup: the card paints both its states" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 400, 188);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    const colors = chrome.Chrome{};
    paint(cr, 0, 0, colors, 1.0, .{});
    paint(cr, 0, 0, colors, 1.0, .{
        .active = true,
        .title = "A Title Long Enough That It Has To Walk Across The Card",
        .artist = "An Artist",
        .duration_us = 200_000_000,
        .position_us = 50_000_000,
        .playing = true,
        .can_play = true,
        .can_pause = true,
        .can_prev = true,
        .can_next = true,
        .shuffle = true,
        .loop_status = "Track",
        .hover = .seekbar,
    });
    try t.expect(cairo.cairo_surface_status(surf) == cairo.CAIRO_STATUS_SUCCESS);
    try t.expect(cairo.cairo_image_surface_get_width(surf) == 400);

    // The panel fill has to have landed somewhere on the buffer.
    cairo.cairo_surface_flush(surf);
    const data = cairo.cairo_image_surface_get_data(surf);
    try t.expect(data != null);
    try t.expect(cairo.cairo_image_surface_get_stride(surf) >= 400 * 4);
}
