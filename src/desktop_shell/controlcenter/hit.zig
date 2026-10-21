//! Pure
//! hit-testing for the legacy popup. Every function takes the already
//! computed `Layout` (plus the counts it was built from) so tests never
//! need a compositor or D-Bus; the dock host computes the layout once per
//! frame and reuses it for paint *and* hit, which is what keeps clicks on
//! the pixels.

const std = @import("std");
const layout = @import("layout.zig");

fn inRect(px: f64, py: f64, x: f64, y: f64, w: f64, h: f64) bool {
    return px >= x and px <= x + w and py >= y and py <= y + h;
}

pub fn networkCardHit(l: layout.Layout, px: f64, py: f64) bool {
    return inRect(px, py, l.net_x, layout.grid_y, l.tile_w, layout.tile_h);
}

pub fn bluetoothCardHit(l: layout.Layout, px: f64, py: f64) bool {
    return inRect(px, py, l.bt_x, layout.grid_y, l.tile_w, layout.tile_h);
}

pub fn audioCardHit(l: layout.Layout, is_output: bool, px: f64, py: f64) bool {
    const x = if (is_output) layout.pad else layout.pad + l.tile_w + layout.gap;
    return inRect(px, py, x, l.audio_y, l.tile_w, layout.audio_h);
}

pub const SliderGeom = struct {
    track_x: f64 = 0,
    track_y: f64 = 0,
    track_w: f64 = 0,
    track_h: f64 = 0,
    hit_x: f64 = 0,
    hit_y: f64 = 0,
    hit_w: f64 = 0,
    hit_h: f64 = 0,
};

pub fn audioSliderGeom(l: layout.Layout, is_output: bool) SliderGeom {
    const card_x = if (is_output) layout.pad else layout.pad + l.tile_w + layout.gap;
    const tx = card_x + layout.audio_track_x_pad;
    const ty = l.audio_y + layout.audio_track_y_from_card_top;
    const tw = @max(1.0, l.tile_w - 2.0 * layout.audio_track_x_pad);
    return .{
        .track_x = tx,
        .track_y = ty,
        .track_w = tw,
        .track_h = layout.audio_track_h,
        .hit_x = tx - layout.audio_hit_pad_h,
        .hit_y = ty - layout.audio_hit_pad_v,
        .hit_w = tw + 2.0 * layout.audio_hit_pad_h,
        .hit_h = layout.audio_track_h + 2.0 * layout.audio_hit_pad_v,
    };
}

pub fn audioSliderHit(l: layout.Layout, is_output: bool, px: f64, py: f64) ?f64 {
    const g = audioSliderGeom(l, is_output);
    if (!inRect(px, py, g.hit_x, g.hit_y, g.hit_w, g.hit_h)) return null;
    return layout.sliderTFromX(g.track_x, g.track_w, px);
}

pub fn audioMuteHit(l: layout.Layout, is_output: bool, px: f64, py: f64) bool {
    const card_x = if (is_output) layout.pad else layout.pad + l.tile_w + layout.gap;
    const cx = card_x + 24.0;
    const cy = l.audio_y + 28.0;
    return inRect(px, py, cx - 14.0, cy - 14.0, 28.0, 28.0);
}

pub fn networkRowHit(l: layout.Layout, px: f64, py: f64) ?i32 {
    if (l.net_h <= 2.0) return null;
    var i: i32 = 0;
    while (i < l.net_rows) : (i += 1) {
        const ry = l.net_y + l.net_header_h + @as(f64, @floatFromInt(i)) * layout.row_pitch;
        if (inRect(px, py, layout.pad, ry, l.w - layout.pad * 2.0, layout.row_pitch)) return i;
    }
    return null;
}

pub fn outputDeviceRowHit(l: layout.Layout, px: f64, py: f64) ?i32 {
    if (l.out_dev_h <= 2.0) return null;
    var i: i32 = 0;
    while (i < l.out_dev_rows) : (i += 1) {
        if (inRect(px, py, layout.pad, layout.panelRowY(l.out_dev_y, i), l.w - layout.pad * 2.0, layout.row_pitch)) return i;
    }
    return null;
}

pub fn inputDeviceRowHit(l: layout.Layout, px: f64, py: f64) ?i32 {
    if (l.in_dev_h <= 2.0) return null;
    var i: i32 = 0;
    while (i < l.in_dev_rows) : (i += 1) {
        if (inRect(px, py, layout.pad, layout.panelRowY(l.in_dev_y, i), l.w - layout.pad * 2.0, layout.row_pitch)) return i;
    }
    return null;
}

pub fn bluetoothRowHit(l: layout.Layout, px: f64, py: f64) ?i32 {
    if (l.bt_h <= 2.0) return null;
    var i: i32 = 0;
    while (i < l.bt_rows) : (i += 1) {
        if (inRect(px, py, layout.pad, layout.panelRowY(l.bt_y, i), l.w - layout.pad * 2.0, layout.row_pitch)) return i;
    }
    return null;
}

/// Forget (×) button inside bluetooth row `idx`. Hit rule for
/// `control_center_bluetooth_row_forget_hit`: only when the row is paired,
/// and the row body itself answers false there (the caller tries this first).
pub fn bluetoothForgetHit(l: layout.Layout, idx: i32, paired: bool, px: f64, py: f64) bool {
    if (l.bt_h <= 2.0 or !paired) return false;
    if (idx < 0 or idx >= l.bt_rows) return false;
    const right_edge = l.w - layout.pad - 10.0;
    const b = layout.btBtns(true, right_edge);
    const ry = layout.panelRowY(l.bt_y, idx);
    return px >= b.forget_x and px < b.forget_x + b.forget_w and
        py >= ry and py < ry + layout.row_pitch;
}

pub fn mixerHeaderHit(l: layout.Layout, px: f64, py: f64) bool {
    return inRect(px, py, layout.pad, l.mixer_y, l.w - layout.pad * 2.0, layout.mixer_header_h);
}

/// Mixer row slider hit. `name_end_x` is the slider origin paint measured
/// from the stream name; the caller supplies it
/// so this stays pure. Returns the 0..1 value under the pointer.
pub fn mixerRowHit(row_y: f64, name_end_x: f64, popup_w: f64, px: f64, py: f64) ?f64 {
    const tw = @max(60.0, popup_w - 28.0 - name_end_x);
    const track_y = row_y + layout.mixer_slider_cy - 8.0 * 0.5;
    if (!inRect(px, py, name_end_x - 4.0, track_y - 15.0, tw + 8.0, 8.0 + 30.0)) return null;
    return layout.sliderTFromX(name_end_x, tw, px);
}

pub fn mediaButtonHit(l: layout.Layout, px: f64, py: f64) ?usize {
    if (!inRect(px, py, layout.pad, l.media_y, l.w - layout.pad * 2.0, layout.media_h)) return null;
    const cy = layout.mediaBtnCy(l.media_y, layout.media_h);
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const cx = layout.mediaBtnCx(layout.pad, l.w - layout.pad * 2.0, i);
        const dx = px - cx;
        const dy = py - cy;
        if (dx * dx + dy * dy <= 14.0 * 14.0) return i;
    }
    return null;
}

pub fn weatherCardHit(l: layout.Layout, px: f64, py: f64) bool {
    return inRect(px, py, layout.pad, l.weather_y, l.w - layout.pad * 2.0, layout.weather_h);
}

test "cc-hit: cards and audio sliders" {
    const t = std.testing;
    const state_mod = @import("state.zig");
    var st = state_mod.State{};
    var rows: std.ArrayList(layout.MixerRow) = .empty;
    defer rows.deinit(t.allocator);
    const l = layout.computeLayout(400, &st, .{ .mix_total_out = 1 }, 0, true, t.allocator, &rows);
    try t.expect(networkCardHit(l, 30, 30));
    try t.expect(!networkCardHit(l, 350, 30));
    try t.expect(bluetoothCardHit(l, 300, 30));
    try t.expect(audioCardHit(l, true, 40, l.audio_y + 10));
    try t.expect(audioCardHit(l, false, 250, l.audio_y + 10));
    try t.expect(audioMuteHit(l, true, layout.pad + 24.0, l.audio_y + 28.0));
    const g = audioSliderGeom(l, true);
    try t.expect(audioSliderHit(l, true, g.track_x + g.track_w * 0.5, g.track_y) != null);
    try t.expect(audioSliderHit(l, true, 5, 5) == null);
}

test "cc-hit: rows gate on expansion" {
    const t = std.testing;
    const state_mod = @import("state.zig");
    var st = state_mod.State{ .network_expanded = true, .output_devices_expanded = true };
    var rows: std.ArrayList(layout.MixerRow) = .empty;
    defer rows.deinit(t.allocator);
    const l = layout.computeLayout(400, &st, .{ .net_rows = 2, .out_dev_rows = 1, .mix_total_out = 1 }, 0, true, t.allocator, &rows);
    try t.expect(networkRowHit(l, 100, l.net_y + l.net_header_h + 5) == 0);
    try t.expect(networkRowHit(l, 100, l.net_y + l.net_header_h + 40) == 1);
    try t.expect(outputDeviceRowHit(l, 100, layout.panelRowY(l.out_dev_y, 0) + 5) == 0);
    var shut = state_mod.State{};
    var rows2: std.ArrayList(layout.MixerRow) = .empty;
    defer rows2.deinit(t.allocator);
    const l2 = layout.computeLayout(400, &shut, .{ .net_rows = 2, .mix_total_out = 1 }, 0, true, t.allocator, &rows2);
    try t.expect(networkRowHit(l2, 100, 100) == null);
}

test "cc-hit: media buttons are three circles" {
    const t = std.testing;
    const state_mod = @import("state.zig");
    var st = state_mod.State{};
    var rows: std.ArrayList(layout.MixerRow) = .empty;
    defer rows.deinit(t.allocator);
    const l = layout.computeLayout(400, &st, .{ .mix_total_out = 1 }, 0, true, t.allocator, &rows);
    const cx1 = layout.mediaBtnCx(layout.pad, l.w - layout.pad * 2.0, 1);
    const cy = layout.mediaBtnCy(l.media_y, layout.media_h);
    try t.expectEqual(@as(usize, 1), mediaButtonHit(l, cx1, cy).?);
    try t.expect(mediaButtonHit(l, layout.pad + 5, l.media_y + 5) == null);
    try t.expect(weatherCardHit(l, 200, l.weather_y + 10));
}

test "cc-hit: forget button only on paired rows" {
    const t = std.testing;
    const state_mod = @import("state.zig");
    var st = state_mod.State{ .bluetooth_expanded = true };
    var rows: std.ArrayList(layout.MixerRow) = .empty;
    defer rows.deinit(t.allocator);
    const l = layout.computeLayout(400, &st, .{ .bt_rows = 1, .mix_total_out = 1 }, 0, true, t.allocator, &rows);
    const b = layout.btBtns(true, l.w - layout.pad - 10.0);
    const ry = layout.panelRowY(l.bt_y, 0);
    try t.expect(bluetoothForgetHit(l, 0, true, b.forget_x + 4, ry + 10));
    try t.expect(!bluetoothForgetHit(l, 0, false, b.forget_x + 4, ry + 10));
    try t.expect(!bluetoothForgetHit(l, 3, true, b.forget_x + 4, ry + 10));
}
