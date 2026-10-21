const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const dw_data = @import("../../../ux/shared/desktop_widgets_data.zig");
const glyph = @import("../../common/material_glyph.zig");
const bus = @import("media_bus.zig");
const widget = @import("widget.zig");

// Desktop media-compact widget.
// Same design: 400x188 glass card (r28), 64px art + scrolling title/artist,
// seek bar with knob + stamps, shuffle/prev/play/next/repeat transport.
// Reads the `media_bus` snapshot (published by whoever polls MPRIS); clicks
// dispatch through the bus handler and always consume their zone.

const kw: f64 = 400.0;
const kh: f64 = 188.0;
const outer_r: f64 = 28.0;
const pad: f64 = 20.0;
const art_s: f64 = 64.0;
const art_x: f64 = pad;
const art_y: f64 = pad;
const art_r: f64 = 12.0;
const text_x: f64 = art_x + art_s + 14.0;
const text_w: f64 = kw - pad - text_x;
const title_y: f64 = 28.0;
const artist_y: f64 = 56.0;
const seek_x0: f64 = pad;
const seek_x1: f64 = kw - pad;
const seek_w: f64 = seek_x1 - seek_x0;
const bar_y: f64 = 102.0;
const bar_h: f64 = 4.0;
const knob_r: f64 = 5.0;
const stamps_y: f64 = 114.0;
const ctrl_cy: f64 = 154.0;
const shuffle_cx: f64 = 80.0;
const prev_cx: f64 = 136.0;
const play_cx: f64 = 200.0;
const next_cx: f64 = 264.0;
const repeat_cx: f64 = 320.0;

pub const State = struct {
    active: bool = false,
    can_prev: bool = false,
    can_next: bool = false,
    duration_us: i64 = 0,
    is_stream: bool = false,
    marquee_active: bool = false,
    hover_btn: i32 = -1,
    hover_prog: bool = false,
};

pub fn stateFromConfig(cfg: dw_data.WidgetConfig) State {
    _ = cfg;
    return .{};
}

pub fn refresh(s: *State, io: std.Io) void {
    _ = io;
    const snap = bus.get();
    s.active = snap.realActive();
    s.can_prev = s.active and snap.can_go_previous;
    s.can_next = s.active and snap.can_go_next;
    s.duration_us = if (s.active) snap.duration_us else 0;
    s.is_stream = s.active and std.mem.indexOf(u8, snap.track_url, "twitch.tv") != null;
}

/// Second-tick refresh (C++ `wantsSecondTicks`): the cached `active` /
/// `duration_us` / `is_stream` fields drive hit-testing, so they must be
/// re-read every service tick or every click is dropped on a stale `active`.
pub fn ticks(_: *const State) bool {
    return true;
}

pub fn anim(s: *const State) u32 {
    return if (s.marquee_active and s.active) 33 else 0;
}

pub fn size(s: *const State) [2]i32 {
    _ = s;
    return .{ 400, 188 };
}

fn hitBtn(s: *const State, x: f64, y: f64) i32 {
    if (!s.active) return -1;
    if (s.duration_us > 0 and !s.is_stream) {
        if (y >= 92.0 and y <= 112.0 and x >= seek_x0 and x <= seek_x1) return 3;
    }
    if (hitCircle(x, y, play_cx, ctrl_cy, 24.0)) return 1;
    if (hitCircle(x, y, prev_cx, ctrl_cy, 20.0)) return 0;
    if (hitCircle(x, y, next_cx, ctrl_cy, 20.0)) return 2;
    if (hitCircle(x, y, shuffle_cx, ctrl_cy, 20.0)) return 4;
    if (hitCircle(x, y, repeat_cx, ctrl_cy, 20.0)) return 5;
    return -1;
}

fn hitCircle(px: f64, py: f64, cx: f64, cy: f64, r: f64) bool {
    const dx = px - cx;
    const dy = py - cy;
    return dx * dx + dy * dy <= r * r;
}

pub fn click(s: *State, x: f64, y: f64) bool {
    const zone = hitBtn(s, x, y);
    if (zone == 3) {
        const snap = bus.get();
        if (snap.duration_us > 0) {
            const frac = std.math.clamp((x - seek_x0) / seek_w, 0.0, 1.0);
            _ = bus.dispatch(.seek, @intFromFloat(@as(f64, @floatFromInt(snap.duration_us)) * frac));
        }
        return true;
    }
    if (zone < 0) return false;
    switch (zone) {
        0 => {
            if (s.can_prev) _ = bus.dispatch(.previous, 0);
            return true;
        },
        1 => {
            _ = bus.dispatch(.play_pause, 0);
            return true;
        },
        2 => {
            if (s.can_next) _ = bus.dispatch(.next, 0);
            return true;
        },
        4 => {
            _ = bus.dispatch(.shuffle, 0);
            return true;
        },
        5 => {
            _ = bus.dispatch(.loop, 0);
            return true;
        },
        else => return false,
    }
}

pub fn motion(s: *State, x: f64, y: f64) void {
    if (x < 0 or y < 0) {
        s.hover_btn = -1;
        s.hover_prog = false;
        return;
    }
    const btn = hitBtn(s, x, y);
    if (btn == 3) {
        s.hover_btn = -1;
        s.hover_prog = true;
    } else {
        s.hover_btn = btn;
        s.hover_prog = false;
    }
}

fn scrolledLine(s: *State, cr: ?*cairo.cairo_t, y: f64, max_w: f64, str: []const u8, fd: []const u8, r: f64, g: f64, b: f64, a: f64, phase: f64) void {
    const c = cr orelse return;
    var nat = widget.makeLine(c, fd, str);
    defer nat.destroy();
    const nat_px = nat.pixelSize();
    var l = widget.makeLine(c, fd, str);
    defer l.destroy();
    const line_h = l.pixelSize().h;
    const tsec: f64 = @as(f64, @floatFromInt(widget.monotonicMs())) / 1000.0;
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    if (@as(f64, @floatFromInt(nat_px.w)) > max_w + 0.5) {
        s.marquee_active = true;
        const range = @as(f64, @floatFromInt(nat_px.w)) - max_w;
        const off = bus.marqueeOffset(range, tsec + phase, 9.0);
        cairo.cairo_save(c);
        cairo.cairo_rectangle(c, text_x, y - 2.0, max_w, @as(f64, @floatFromInt(line_h)) + 4.0);
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
    const active = snap.realActive();
    const title: []const u8 = if (active) (if (snap.title.len > 0) snap.title else "Unknown Track") else "";
    const artist: []const u8 = if (active) snap.artist else "";
    const playing = std.mem.eql(u8, snap.status, "Playing");
    const shuffle_on = active and snap.shuffle;
    const loop_on = active and (std.mem.eql(u8, snap.loop_status, "Track") or std.mem.eql(u8, snap.loop_status, "Playlist"));

    s.marquee_active = false;
    widget.glassCard(c, kw, kh, outer_r, ctx, 0.92 * ctx.overlay_widget_card);
    cairo.cairo_save(c);
    widget.roundRect(c, 0, 0, kw, kh, outer_r);
    cairo.cairo_clip(c);

    if (!active) {
        _ = glyph.draw(c, "music_note", kw * 0.5, 74.0, 30.0, ctx.text_r, ctx.text_g, ctx.text_b, 0.45);
        var l = widget.makeLine(c, "Inter 15", "No media playing");
        defer l.destroy();
        const tw = l.pixelSize().w;
        widget.showPlain(c, &l, (kw - @as(f64, @floatFromInt(tw))) * 0.5, 112.0, ctx.text_r, ctx.text_g, ctx.text_b, 0.70);
        cairo.cairo_restore(c);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    if (!bus.paintArt(c, ctx.io, snap, art_x, art_y, art_s, art_r)) {
        cairo.cairo_save(c);
        widget.roundRect(c, art_x, art_y, art_s, art_s, art_r);
        cairo.cairo_set_source_rgba(c, ctx.dock_fill_r, ctx.dock_fill_g, ctx.dock_fill_b, 1.0);
        cairo.cairo_fill(c);
        cairo.cairo_restore(c);
        _ = glyph.draw(c, "music_note", art_x + art_s * 0.5, art_y + art_s * 0.5, 28.0, ctx.text_r, ctx.text_g, ctx.text_b, 0.60);
    }

    scrolledLine(s, c, title_y, text_w, title, "Inter Bold 18", ctx.text_r, ctx.text_g, ctx.text_b, 0.95, 0.0);
    if (artist.len > 0)
        scrolledLine(s, c, artist_y, text_w, artist, "Inter 14", ctx.text_r, ctx.text_g, ctx.text_b, 0.62, 2.7);

    const pct: f64 = if (snap.duration_us > 0)
        std.math.clamp(@as(f64, @floatFromInt(snap.position_us)) / @as(f64, @floatFromInt(snap.duration_us)), 0.0, 1.0)
    else
        0.0;
    const fill_w = seek_w * pct;
    cairo.cairo_save(c);
    widget.roundRect(c, seek_x0, bar_y, seek_w, bar_h, bar_h / 2.0);
    cairo.cairo_set_source_rgba(c, ctx.text_r, ctx.text_g, ctx.text_b, 0.22);
    cairo.cairo_fill(c);
    if (fill_w > 0.5) {
        widget.roundRect(c, seek_x0, bar_y, fill_w, bar_h, bar_h / 2.0);
        cairo.cairo_set_source_rgba(c, ctx.text_r, ctx.text_g, ctx.text_b, if (s.hover_prog) 1.0 else 0.95);
        cairo.cairo_fill(c);
    }
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, seek_x0 + fill_w, bar_y + bar_h / 2.0, knob_r, 0, std.math.pi * 2.0);
    cairo.cairo_set_source_rgba(c, ctx.text_r, ctx.text_g, ctx.text_b, if (s.hover_prog) 1.0 else 0.95);
    cairo.cairo_fill(c);
    cairo.cairo_restore(c);

    var sb0: [16]u8 = undefined;
    var sb1: [16]u8 = undefined;
    const start_txt = bus.formatMmss(&sb0, snap.position_us, false);
    var rem_txt: []const u8 = "-0:00";
    if (snap.duration_us > 0) {
        const rem = @max(@as(i64, 0), snap.duration_us - snap.position_us);
        rem_txt = bus.formatMmss(&sb1, rem, true);
    }
    var sl = widget.makeLine(c, "Inter 11", start_txt);
    defer sl.destroy();
    widget.showPlain(c, &sl, seek_x0, stamps_y, ctx.text_r, ctx.text_g, ctx.text_b, 0.55);
    var rl = widget.makeLine(c, "Inter 11", rem_txt);
    defer rl.destroy();
    widget.showPlain(c, &rl, seek_x1 - @as(f64, @floatFromInt(rl.pixelSize().w)), stamps_y, ctx.text_r, ctx.text_g, ctx.text_b, 0.55);

    _ = glyph.draw(c, "shuffle", shuffle_cx, ctrl_cy, 26.0, ctx.text_r, ctx.text_g, ctx.text_b, if (shuffle_on) 1.0 else 0.45);
    _ = glyph.draw(c, "skip_previous", prev_cx, ctrl_cy, 30.0, ctx.text_r, ctx.text_g, ctx.text_b, if (snap.can_go_previous) 1.0 else 0.30);
    _ = glyph.draw(c, if (playing) "pause" else "play_arrow", play_cx, ctrl_cy, 40.0, ctx.text_r, ctx.text_g, ctx.text_b, if (snap.can_play or snap.can_pause or playing) 1.0 else 0.30);
    _ = glyph.draw(c, "skip_next", next_cx, ctrl_cy, 30.0, ctx.text_r, ctx.text_g, ctx.text_b, if (snap.can_go_next) 1.0 else 0.30);
    _ = glyph.draw(c, if (std.mem.eql(u8, snap.loop_status, "Track")) "repeat_one" else "repeat", repeat_cx, ctrl_cy, 26.0, ctx.text_r, ctx.text_g, ctx.text_b, if (loop_on) 1.0 else 0.45);

    cairo.cairo_restore(c);
}
