const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const dw_data = @import("../../../ux/shared/desktop_widgets_data.zig");
const glyph = @import("../../common/material_glyph.zig");
const bus = @import("media_bus.zig");
const widget = @import("widget.zig");

// Desktop media-player widget.
// design: 340x440 liquid-glass card (r28) with top sheen, 264px art,
// scrolling title/artist, 28-segment cava wave (idle sine drift without a
// feed), seek bar + stamps, shuffle/prev/play/next/repeat with a frosted
// play disc. Reads the `media_bus` snapshot; clicks dispatch through it.
//
// The cava feed arrives via `feedWave` (the desktop layer pushes reader
// values); without it the strip idles on a sine drift
// when the reader is unavailable.

const kw: f64 = 340.0;
const kh: f64 = 440.0;
const outer_r: f64 = 28.0;
const pad: f64 = 20.0;
const art_s: f64 = 264.0;
const art_x: f64 = (kw - art_s) * 0.5;
const art_y: f64 = 20.0;
const art_r: f64 = 20.0;
const text_x: f64 = 30.0;
const text_w: f64 = kw - 30.0 - 30.0;
const title_y: f64 = 292.0;
const artist_y: f64 = 316.0;
const wave_x0: f64 = 30.0;
const wave_x1: f64 = kw - 30.0;
const wave_w: f64 = wave_x1 - wave_x0;
const wave_mid_y: f64 = 351.0;
const wave_half_h: f64 = 11.0;
const seek_x0: f64 = 30.0;
const seek_x1: f64 = kw - 30.0;
const seek_w: f64 = seek_x1 - seek_x0;
const bar_y: f64 = 370.0;
const bar_h: f64 = 4.0;
const knob_r: f64 = 5.0;
const seek_top: f64 = 362.0;
const seek_bot: f64 = 380.0;
const stamps_y: f64 = 380.0;
const ctrl_cy: f64 = 410.0;
const shuffle_cx: f64 = 65.0;
const prev_cx: f64 = 113.0;
const play_cx: f64 = 170.0;
const next_cx: f64 = 227.0;
const repeat_cx: f64 = 275.0;
const wave_n: usize = 28;

const Hover = enum { none, play, prev, next, shuffle, repeat, seekbar };

pub const State = struct {
    active: bool = false,
    can_prev: bool = false,
    can_next: bool = false,
    can_play: bool = false,
    can_pause: bool = false,
    shuffle: bool = false,
    loop_mode: []const u8 = "",
    playing: bool = false,
    marquee_active: bool = false,
    hover: Hover = .none,
    wave: [wave_n]f64 = [_]f64{0} ** wave_n,
    has_wave: bool = false,
    idle_phase: f64 = 0,
    last_ms: i64 = 0,
};

pub fn stateFromConfig(cfg: dw_data.WidgetConfig) State {
    _ = cfg;
    return .{};
}

pub fn refresh(s: *State, io: std.Io) void {
    _ = io;
    const snap = bus.get();
    s.active = snap.realActive();
    if (s.active) {
        s.can_prev = snap.can_go_previous;
        s.can_next = snap.can_go_next;
        s.can_play = snap.can_play;
        s.can_pause = snap.can_pause;
        s.shuffle = snap.shuffle;
        s.loop_mode = snap.loop_status;
        s.playing = snap.playing();
    } else {
        s.can_prev = false;
        s.can_next = false;
        s.can_play = false;
        s.can_pause = false;
        s.shuffle = false;
        s.loop_mode = "";
        s.playing = false;
    }
}

/// Cava feed: 28 smoothed 0..1 levels pushed by the desktop layer.
pub fn feedWave(s: *State, levels: [wave_n]f64) void {
    s.wave = levels;
    s.has_wave = true;
}

/// Second-tick refresh (C++ `wantsSecondTicks`): the bus snapshot is the
/// state source, so it must be re-read every service tick — without this the
/// widget keeps the empty startup snapshot and never leaves its idle state.
pub fn ticks(_: *const State) bool {
    return true;
}

pub fn anim(s: *const State) u32 {
    if (s.marquee_active and s.active) return 33;
    if (s.has_wave and s.playing) return 33;
    return 0;
}

pub fn size(s: *const State) [2]i32 {
    _ = s;
    return .{ 340, 440 };
}

fn hitCircle(px: f64, py: f64, cx: f64, cy: f64, r: f64) bool {
    const dx = px - cx;
    const dy = py - cy;
    return dx * dx + dy * dy <= r * r;
}

fn hoverAt(s: *const State, x: f64, y: f64) Hover {
    if (!s.active) return .none;
    if (hitCircle(x, y, play_cx, ctrl_cy, 24.0)) return .play;
    if (hitCircle(x, y, prev_cx, ctrl_cy, 20.0)) return .prev;
    if (hitCircle(x, y, next_cx, ctrl_cy, 20.0)) return .next;
    if (hitCircle(x, y, shuffle_cx, ctrl_cy, 20.0)) return .shuffle;
    if (hitCircle(x, y, repeat_cx, ctrl_cy, 20.0)) return .repeat;
    if (y >= seek_top and y < seek_bot and x >= seek_x0 and x <= seek_x1) return .seekbar;
    return .none;
}

pub fn click(s: *State, x: f64, y: f64) bool {
    const part = hoverAt(s, x, y);
    if (!s.active) return false;
    switch (part) {
        .play => {
            _ = bus.dispatch(.play_pause, 0);
            return true;
        },
        .prev => {
            if (s.can_prev) _ = bus.dispatch(.previous, 0);
            return true;
        },
        .next => {
            if (s.can_next) _ = bus.dispatch(.next, 0);
            return true;
        },
        .shuffle => {
            _ = bus.dispatch(.shuffle, 0);
            return true;
        },
        .repeat => {
            _ = bus.dispatch(.loop, 0);
            return true;
        },
        .seekbar => {
            const snap = bus.get();
            if (snap.duration_us > 0) {
                const pct = std.math.clamp((x - seek_x0) / seek_w, 0.0, 1.0);
                _ = bus.dispatch(.seek, @intFromFloat(@as(f64, @floatFromInt(snap.duration_us)) * pct));
                return true;
            }
            return false;
        },
        .none => return false,
    }
}

pub fn motion(s: *State, x: f64, y: f64) void {
    if (x < 0 or y < 0) {
        s.hover = .none;
        return;
    }
    s.hover = hoverAt(s, x, y);
}

fn scrolledLine(s: *State, c: ?*cairo.cairo_t, y: f64, str: []const u8, fd: []const u8, r: f64, g: f64, b: f64, a: f64, phase: f64) void {
    const cr = c orelse return;
    var nat = widget.makeLine(cr, fd, str);
    defer nat.destroy();
    const nat_w = nat.pixelSize().w;
    var l = widget.makeLine(cr, fd, str);
    defer l.destroy();
    const line_h = l.pixelSize().h;
    const tsec: f64 = @as(f64, @floatFromInt(widget.monotonicMs())) / 1000.0;
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    if (@as(f64, @floatFromInt(nat_w)) > text_w + 0.5) {
        s.marquee_active = true;
        const off = bus.marqueeOffset(@as(f64, @floatFromInt(nat_w)) - text_w, tsec + phase, 9.0);
        cairo.cairo_save(c);
        cairo.cairo_rectangle(c, text_x, y - 2.0, text_w, @as(f64, @floatFromInt(line_h)) + 4.0);
        cairo.cairo_clip(c);
        cairo.cairo_move_to(c, text_x - off, y);
        if (l.layout) |lo| text.pango_cairo_show_layout(c, lo);
        cairo.cairo_restore(c);
    } else {
        cairo.cairo_move_to(c, text_x, y);
        if (l.layout) |lo| text.pango_cairo_show_layout(c, lo);
    }
}

pub fn paint(s: *State, cr: ?*cairo.cairo_t, ctx: widget.Ctx) void {
    const c = cr orelse return;
    const snap = bus.get();
    const now_ms: i64 = @intCast(widget.monotonicMs());
    const dt: f64 = if (s.last_ms == 0) 16.0 else @as(f64, @floatFromInt(now_ms - s.last_ms));
    s.last_ms = now_ms;
    if (!s.playing) s.idle_phase += dt * 0.001;

    // Liquid-glass card + sheen.
    cairo.cairo_save(c);
    widget.glassCard(c, kw, kh, outer_r, ctx, 0.78 * ctx.overlay_widget_card);
    cairo.cairo_save(c);
    widget.roundRect(c, 0, 0, kw, kh, outer_r);
    cairo.cairo_clip(c);
    const sheen = cairo.cairo_pattern_create_linear(0, 0, 0, 64.0);
    cairo.cairo_pattern_add_color_stop_rgba(sheen, 0.0, 1, 1, 1, 0.14);
    cairo.cairo_pattern_add_color_stop_rgba(sheen, 1.0, 1, 1, 1, 0.0);
    cairo.cairo_rectangle(c, 0, 0, kw, 64.0);
    cairo.cairo_set_source(c, sheen);
    cairo.cairo_fill(c);
    cairo.cairo_pattern_destroy(sheen);
    cairo.cairo_restore(c);
    widget.roundRect(c, 0, 0, kw, kh, outer_r);
    cairo.cairo_clip(c);

    if (!s.active) {
        cairo.cairo_save(c);
        widget.roundRect(c, art_x, art_y, art_s, art_s, art_r);
        cairo.cairo_set_source_rgba(c, ctx.dock_fill_r, ctx.dock_fill_g, ctx.dock_fill_b, 1.0);
        cairo.cairo_fill(c);
        cairo.cairo_restore(c);
        _ = glyph.draw(c, "music_note", art_x + art_s * 0.5, art_y + art_s * 0.5, 56.0, ctx.text_r, ctx.text_g, ctx.text_b, 0.40);
        var l = widget.makeLine(c, "Inter 15", "No media playing");
        defer l.destroy();
        widget.showPlain(c, &l, (kw - @as(f64, @floatFromInt(l.pixelSize().w))) * 0.5, art_y + art_s + 16.0, ctx.text_r, ctx.text_g, ctx.text_b, 0.60);
        cairo.cairo_restore(c);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    if (!bus.paintArt(c, ctx.io, snap, art_x, art_y, art_s, art_r)) {
        const grad = cairo.cairo_pattern_create_linear(art_x, art_y, art_x + art_s, art_y + art_s);
        cairo.cairo_pattern_add_color_stop_rgba(grad, 0.0, 0.55, 0.25, 0.65, 1.0);
        cairo.cairo_pattern_add_color_stop_rgba(grad, 1.0, 0.25, 0.35, 0.80, 1.0);
        cairo.cairo_save(c);
        widget.roundRect(c, art_x, art_y, art_s, art_s, art_r);
        cairo.cairo_set_source(c, grad);
        cairo.cairo_fill(c);
        cairo.cairo_restore(c);
        cairo.cairo_pattern_destroy(grad);
        _ = glyph.draw(c, "music_note", art_x + art_s * 0.5, art_y + art_s * 0.5, 56.0, ctx.text_r, ctx.text_g, ctx.text_b, 0.70);
    }
    cairo.cairo_save(c);
    widget.roundRect(c, art_x, art_y, art_s, art_s, art_r);
    cairo.cairo_set_source_rgba(c, ctx.text_r, ctx.text_g, ctx.text_b, 0.12);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);

    const title: []const u8 = if (snap.title.len > 0) snap.title else "Unknown Track";
    s.marquee_active = false;
    scrolledLine(s, c, title_y, title, "Inter Bold 17", ctx.text_r, ctx.text_g, ctx.text_b, 0.95, 0.0);
    if (snap.artist.len > 0)
        scrolledLine(s, c, artist_y, snap.artist, "Inter 14", ctx.text_r, ctx.text_g, ctx.text_b, 0.62, 2.7);

    // Cava wave (mirrored accent line + faint fill; idle sine drift).
    {
        var pts: [wave_n][2]f64 = undefined;
        if (s.has_wave and s.playing) {
            for (&pts, 0..) |*p, i| {
                const level = std.math.clamp(s.wave[i], 0.0, 1.0);
                p.* = .{ wave_x0 + wave_w * @as(f64, @floatFromInt(i)) / 27.0, wave_mid_y - wave_half_h * level };
            }
        } else {
            for (&pts, 0..) |*p, i| {
                const x01 = @as(f64, @floatFromInt(i)) / 27.0;
                p.* = .{ wave_x0 + wave_w * x01, wave_mid_y + @sin(s.idle_phase * 2.0 + x01 * 6.2831) * 1.5 };
            }
        }
        const wave_a: f64 = if (s.has_wave and s.playing) 0.95 else 0.25;
        cairo.cairo_save(c);
        cairo.cairo_new_path(c);
        cairo.cairo_move_to(c, pts[0][0], wave_mid_y + wave_half_h);
        cairo.cairo_line_to(c, pts[0][0], pts[0][1]);
        var i: usize = 0;
        while (i < 27) : (i += 1) {
            const p0 = if (i > 0) pts[i - 1] else pts[0];
            const p1 = pts[i];
            const p2 = pts[i + 1];
            const p3 = if (i + 2 < 28) pts[i + 2] else pts[27];
            cairo.cairo_curve_to(c, p1[0] + (p2[0] - p0[0]) * 0.5 / 3.0, p1[1] + (p2[1] - p0[1]) * 0.5 / 3.0, p2[0] - (p3[0] - p1[0]) * 0.5 / 3.0, p2[1] - (p3[1] - p1[1]) * 0.5 / 3.0, p2[0], p2[1]);
        }
        cairo.cairo_line_to(c, pts[27][0], wave_mid_y + wave_half_h);
        cairo.cairo_close_path(c);
        cairo.cairo_set_source_rgba(c, ctx.acc_r, ctx.acc_g, ctx.acc_b, 0.10 * wave_a / 0.95);
        cairo.cairo_fill(c);
        cairo.cairo_restore(c);
        var pass: i32 = 1;
        while (pass >= 0) : (pass -= 1) {
            cairo.cairo_save(c);
            cairo.cairo_new_path(c);
            cairo.cairo_move_to(c, pts[0][0], pts[0][1]);
            var j: usize = 0;
            while (j < 27) : (j += 1) {
                const p0 = if (j > 0) pts[j - 1] else pts[0];
                const p1 = pts[j];
                const p2 = pts[j + 1];
                const p3 = if (j + 2 < 28) pts[j + 2] else pts[27];
                cairo.cairo_curve_to(c, p1[0] + (p2[0] - p0[0]) * 0.5 / 3.0, p1[1] + (p2[1] - p0[1]) * 0.5 / 3.0, p2[0] - (p3[0] - p1[0]) * 0.5 / 3.0, p2[1] - (p3[1] - p1[1]) * 0.5 / 3.0, p2[0], p2[1]);
            }
            if (pass == 1) {
                cairo.cairo_set_source_rgba(c, ctx.acc_r, ctx.acc_g, ctx.acc_b, 0.18 * wave_a);
                cairo.cairo_set_line_width(c, 5.0);
            } else {
                cairo.cairo_set_source_rgba(c, ctx.acc_r, ctx.acc_g, ctx.acc_b, wave_a);
                cairo.cairo_set_line_width(c, 2.0);
            }
            cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);
            cairo.cairo_set_line_join(c, cairo.CAIRO_LINE_JOIN_ROUND);
            cairo.cairo_stroke(c);
            cairo.cairo_restore(c);
        }
    }

    const pct: f64 = if (snap.duration_us > 0)
        std.math.clamp(@as(f64, @floatFromInt(snap.position_us)) / @as(f64, @floatFromInt(snap.duration_us)), 0.0, 1.0)
    else
        0.0;
    const fill_w = seek_w * pct;
    const seek_hov = s.hover == .seekbar;
    cairo.cairo_save(c);
    widget.roundRect(c, seek_x0, bar_y, seek_w, bar_h, bar_h / 2.0);
    cairo.cairo_set_source_rgba(c, ctx.text_r, ctx.text_g, ctx.text_b, 0.22);
    cairo.cairo_fill(c);
    if (fill_w > 0.5) {
        widget.roundRect(c, seek_x0, bar_y, fill_w, bar_h, bar_h / 2.0);
        cairo.cairo_set_source_rgba(c, ctx.text_r, ctx.text_g, ctx.text_b, if (seek_hov) 1.0 else 0.95);
        cairo.cairo_fill(c);
    }
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, seek_x0 + fill_w, bar_y + bar_h / 2.0, knob_r, 0, std.math.pi * 2.0);
    cairo.cairo_set_source_rgba(c, ctx.text_r, ctx.text_g, ctx.text_b, if (seek_hov) 1.0 else 0.95);
    cairo.cairo_fill(c);
    cairo.cairo_restore(c);

    var sb0: [16]u8 = undefined;
    var sb1: [16]u8 = undefined;
    const start_txt = bus.formatMmss(&sb0, snap.position_us, false);
    const remain_us: i64 = if (snap.duration_us > 0) @max(@as(i64, 0), snap.duration_us - snap.position_us) else 0;
    const rem_txt = bus.formatMmss(&sb1, remain_us, true);
    var sl = widget.makeLine(c, "Inter 11", start_txt);
    defer sl.destroy();
    widget.showPlain(c, &sl, seek_x0, stamps_y, ctx.text_r, ctx.text_g, ctx.text_b, 0.55);
    var rl = widget.makeLine(c, "Inter 11", rem_txt);
    defer rl.destroy();
    widget.showPlain(c, &rl, seek_x1 - @as(f64, @floatFromInt(rl.pixelSize().w)), stamps_y, ctx.text_r, ctx.text_g, ctx.text_b, 0.55);

    const loop_on = std.mem.eql(u8, snap.loop_status, "Track") or std.mem.eql(u8, snap.loop_status, "Playlist");
    _ = glyph.draw(c, "shuffle", shuffle_cx, ctrl_cy, 24.0, ctx.text_r, ctx.text_g, ctx.text_b, if (s.shuffle) 1.0 else 0.45);
    _ = glyph.draw(c, "skip_previous", prev_cx, ctrl_cy, 28.0, ctx.text_r, ctx.text_g, ctx.text_b, if (s.can_prev) 1.0 else 0.30);
    cairo.cairo_save(c);
    cairo.cairo_arc(c, play_cx, ctrl_cy, 22.0, 0, std.math.pi * 2.0);
    cairo.cairo_set_source_rgba(c, ctx.dock_fill_r, ctx.dock_fill_g, ctx.dock_fill_b, 0.55);
    cairo.cairo_fill(c);
    cairo.cairo_set_source_rgba(c, ctx.text_r, ctx.text_g, ctx.text_b, 0.20);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);
    _ = glyph.draw(c, if (s.playing) "pause" else "play_arrow", play_cx, ctrl_cy, 34.0, ctx.text_r, ctx.text_g, ctx.text_b, if (s.can_play or s.can_pause or s.playing) 1.0 else 0.30);
    _ = glyph.draw(c, "skip_next", next_cx, ctrl_cy, 28.0, ctx.text_r, ctx.text_g, ctx.text_b, if (s.can_next) 1.0 else 0.30);
    _ = glyph.draw(c, if (std.mem.eql(u8, snap.loop_status, "Track")) "repeat_one" else "repeat", repeat_cx, ctrl_cy, 24.0, ctx.text_r, ctx.text_g, ctx.text_b, if (loop_on) 1.0 else 0.45);

    cairo.cairo_restore(c);
}
