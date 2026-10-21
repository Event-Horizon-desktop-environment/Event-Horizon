//! Control-center layout.
//! single source of truth for the legacy control-center popup vertical
//! stack. Paint, hit-testing, dispatch and popup sizing ALL consume
//! `Layout`, so a click always lands where the pixels are.
//!
//! Layout queries live backends for row counts and
//! mutates the animation timers. This port takes the counts as parameters
//! (`Counts`) so layout stays pure and unit-testable; the dock host fills
//! them from live services and passes `now_ms` from the monotonic clock.
//! Animation settling (`now - start >= 200` clears the timer) is preserved
//! verbatim.

const std = @import("std");
const cc_state = @import("state.zig");

pub const pad: f64 = 18.0;
pub const gap: f64 = 12.0;
pub const card_r: f64 = 20.0;
pub const row_r: f64 = 14.0;
pub const grid_y: f64 = 18.0;
pub const tile_h: f64 = 46.0;
pub const audio_h: f64 = 92.0;
pub const media_h: f64 = 92.0;
pub const weather_h: f64 = 240.0;
pub const net_header_h: f64 = 32.0;
pub const net_header_err_h: f64 = 50.0;
pub const row_pitch: f64 = 34.0;
/// Vertical room for the one-line "nothing here" note in an empty panel.
pub const note_h: f64 = 26.0;
pub const header_h: f64 = 32.0;
pub const anim_ms: u64 = 200;

// Shared slider metrics — shared by paint + hit so the widget
// box and the hit box cannot drift (see Docs/hit-testing.md).
pub const audio_track_x_pad: f64 = 18.0;
pub const audio_track_h: f64 = 8.0;
pub const audio_track_y_from_card_top: f64 = 30.0 + (92.0 - 30.0 - 8.0) / 2.0;
pub const audio_hit_pad_v: f64 = 15.0;
pub const audio_hit_pad_h: f64 = 6.0;
pub const audio_thumb_r: f64 = 9.0;

pub const mixer_header_h: f64 = 36.0;
pub const mixer_section_h: f64 = 28.0;
pub const mixer_row_h: f64 = 46.0;
pub const mixer_more_h: f64 = 26.0;
pub const mixer_icon_left: f64 = 32.0;
pub const mixer_name_left: f64 = 58.0;
pub const mixer_icon_y: f64 = 15.0;
pub const mixer_name_baseline: f64 = 27.0;
pub const mixer_slider_cy: f64 = 23.0;

/// Row counts + error flags the layout needs. The host builds this from
/// live backends (`wifi_scan`, bluetooth devices, output/input devices,
/// mixer streams) so layout itself never touches D-Bus.
pub const Counts = struct {
    net_rows: i32 = 0,
    bt_rows: i32 = 0,
    out_dev_rows: i32 = 0,
    in_dev_rows: i32 = 0,
    mix_total_out: i32 = 0,
    mix_total_in: i32 = 0,
    wifi_error: bool = false,
    wifi_password_prompt: bool = false,
};

pub const MixerRow = struct {
    y: f64 = 0,
    is_input: bool = false,
    stream_idx: i32 = 0,
};

pub const Layout = struct {
    w: f64 = 0,
    tile_w: f64 = 0,
    net_x: f64 = pad,
    bt_x: f64 = 0,

    net_y: f64 = 0,
    net_h: f64 = 0,
    net_rows: i32 = 0,
    net_header_h: f64 = net_header_h,

    bt_y: f64 = 0,
    bt_h: f64 = 0,
    bt_rows: i32 = 0,

    audio_y: f64 = 0,
    out_dev_y: f64 = 0,
    out_dev_h: f64 = 0,
    out_dev_rows: i32 = 0,
    in_dev_y: f64 = 0,
    in_dev_h: f64 = 0,
    in_dev_rows: i32 = 0,

    mixer_y: f64 = 0,
    mixer_h: f64 = 0,
    mix_total_out: i32 = 0,
    mix_total_in: i32 = 0,
    mix_show_out: i32 = 0,
    mix_show_in: i32 = 0,
    mix_more: bool = false,

    media_y: f64 = 0,
    weather_y: f64 = 0,
    total_h: f64 = 0,
};

/// `cc_anim_panel_h` — 200 ms ease for expand/collapse panels.
pub fn animH(now_ms: u64, start_ms: u64, from: bool, to: bool, full_h: f64) f64 {
    if (start_ms == 0) return if (to) full_h else 0.0;
    if (now_ms < start_ms) return if (from) full_h else 0.0;
    const dt = now_ms - start_ms;
    if (dt >= anim_ms) return if (to) full_h else 0.0;
    const t: f64 = @as(f64, @floatFromInt(dt)) / @as(f64, anim_ms);
    // smoothstep so panels ease in/out rather than popping.
    const e = t * t * (3.0 - 2.0 * t);
    const a: f64 = if (from) full_h else 0.0;
    const b: f64 = if (to) full_h else 0.0;
    return a + (b - a) * e;
}

pub fn computeLayout(
    popup_w: f64,
    state: *cc_state.State,
    counts: Counts,
    now_ms: u64,
    resolve_anims: bool,
    alloc: std.mem.Allocator,
    mix_rows: *std.ArrayList(MixerRow),
) Layout {
    var l = Layout{ .w = popup_w };
    l.tile_w = (popup_w - pad * 2.0 - gap) * 0.5;
    l.bt_x = pad + l.tile_w + gap;

    var y = grid_y + tile_h + gap;

    // Network panel.
    {
        l.net_rows = @min(8, counts.net_rows);
        l.net_header_h = if (counts.wifi_error) net_header_err_h else net_header_h;
        var full_h = l.net_header_h + @as(f64, @floatFromInt(l.net_rows)) * row_pitch + 12.0;
        if (counts.wifi_password_prompt) full_h += 56.0;
        // An empty panel still earns a line of explanation ("No Wi-Fi
        // adapter found" / "No networks found") instead of opening as a bare
        // header.
        if (l.net_rows == 0 and !counts.wifi_password_prompt and !counts.wifi_error) full_h += note_h;
        const to = if (state.net_anim_start_ms != 0) state.net_anim_to_expanded else state.network_expanded;
        const from = if (state.net_anim_start_ms != 0) state.net_anim_from_expanded else state.network_expanded;
        if (resolve_anims) {
            l.net_h = if (to) full_h else 0.0;
        } else {
            l.net_h = animH(now_ms, state.net_anim_start_ms, from, to, full_h);
            if (state.net_anim_start_ms != 0 and now_ms -% state.net_anim_start_ms >= anim_ms) {
                state.net_anim_start_ms = 0;
                state.net_anim_from_expanded = state.network_expanded;
                state.net_anim_to_expanded = state.network_expanded;
            }
        }
        l.net_y = y;
        if (l.net_h > 2.0) {
            y += l.net_h + gap;
        } else l.net_h = 0.0;
    }

    // Bluetooth panel.
    {
        l.bt_rows = @min(8, counts.bt_rows);
        var full_h = 44.0 + @as(f64, @floatFromInt(l.bt_rows)) * row_pitch + 12.0;
        // Same rationale as the network panel: an empty device list still
        // says so ("No devices found") rather than opening as a bare header.
        if (l.bt_rows == 0) full_h += note_h;
        const to = if (state.bt_anim_start_ms != 0) state.bt_anim_to_expanded else state.bluetooth_expanded;
        const from = if (state.bt_anim_start_ms != 0) state.bt_anim_from_expanded else state.bluetooth_expanded;
        if (resolve_anims) {
            l.bt_h = if (to) full_h else 0.0;
        } else {
            l.bt_h = animH(now_ms, state.bt_anim_start_ms, from, to, full_h);
            if (state.bt_anim_start_ms != 0 and now_ms -% state.bt_anim_start_ms >= anim_ms) {
                state.bt_anim_start_ms = 0;
                state.bt_anim_from_expanded = state.bluetooth_expanded;
                state.bt_anim_to_expanded = state.bluetooth_expanded;
            }
        }
        l.bt_y = y;
        if (l.bt_h > 2.0) {
            y += l.bt_h + gap;
        } else l.bt_h = 0.0;
    }

    // Audio cards.
    l.audio_y = y;
    y += audio_h + gap;

    // Output devices panel.
    {
        l.out_dev_rows = @min(12, counts.out_dev_rows);
        l.out_dev_h = if (state.output_devices_expanded)
            32.0 + @as(f64, @floatFromInt(l.out_dev_rows)) * row_pitch + 12.0
        else
            0.0;
        l.out_dev_y = y;
        if (l.out_dev_h > 2.0) {
            y += l.out_dev_h + gap;
        } else l.out_dev_h = 0.0;
    }

    // Input devices panel.
    {
        l.in_dev_rows = @min(12, counts.in_dev_rows);
        l.in_dev_h = if (state.input_devices_expanded)
            32.0 + @as(f64, @floatFromInt(l.in_dev_rows)) * row_pitch + 12.0
        else
            0.0;
        l.in_dev_y = y;
        if (l.in_dev_h > 2.0) {
            y += l.in_dev_h + gap;
        } else l.in_dev_h = 0.0;
    }

    // Mixer.
    {
        l.mix_total_out = counts.mix_total_out;
        l.mix_total_in = counts.mix_total_in;
        l.mix_show_out = if (state.mixer_expanded)
            @min(4, l.mix_total_out)
        else
            @min(1, l.mix_total_out);
        l.mix_show_in = if (state.mixer_expanded) @min(3, l.mix_total_in) else 0;
        l.mix_more = !state.mixer_expanded and l.mix_total_out > 1;
        var body = mixer_header_h;
        var ry: f64 = 0.0;
        if (l.mix_show_out > 0) {
            if (state.mixer_expanded) {
                body += mixer_section_h;
                ry = mixer_header_h + mixer_section_h;
            } else {
                ry = mixer_header_h;
            }
            var i: i32 = 0;
            while (i < l.mix_show_out) : (i += 1) {
                mix_rows.append(alloc, .{ .y = ry, .is_input = false, .stream_idx = i }) catch {};
                ry += mixer_row_h;
            }
            body += @as(f64, @floatFromInt(l.mix_show_out)) * mixer_row_h;
        }
        if (l.mix_more) {
            body += mixer_more_h;
            ry += mixer_more_h;
        }
        if (state.mixer_expanded and l.mix_show_in > 0) {
            body += mixer_section_h;
            ry += mixer_section_h;
            var i: i32 = 0;
            while (i < l.mix_show_in) : (i += 1) {
                mix_rows.append(alloc, .{ .y = ry, .is_input = true, .stream_idx = i }) catch {};
                ry += mixer_row_h;
            }
            body += @as(f64, @floatFromInt(l.mix_show_in)) * mixer_row_h;
        }
        l.mixer_y = y;
        l.mixer_h = body + pad;
        for (mix_rows.items) |*r| r.y += l.mixer_y;
        y += l.mixer_h + gap;
    }

    l.media_y = y;
    y += media_h + gap;

    l.weather_y = y;
    y += weather_h + pad;

    l.total_h = y;
    return l;
}

/// Full-width hit band for panel row `idx` (34 px pitch, 32 px header).
pub fn panelRowY(panel_y: f64, idx: i32) f64 {
    return panel_y + header_h + @as(f64, @floatFromInt(idx)) * row_pitch;
}

pub const BtBtns = struct {
    action_x: f64 = 0,
    action_w: f64 = 76.0,
    forget_x: f64 = -1.0,
    forget_w: f64 = 32.0,
    show_forget: bool = false,
};

/// Bluetooth row action geometry (mirrors paint): one uniform action button
/// + a small icon button for Forget.
pub fn btBtns(paired: bool, right_edge: f64) BtBtns {
    var b = BtBtns{};
    b.show_forget = paired;
    if (b.show_forget) {
        b.forget_x = right_edge - 8.0 - b.forget_w;
        b.action_x = b.forget_x - 6.0 - b.action_w;
    } else {
        b.action_x = right_edge - 8.0 - b.action_w;
    }
    return b;
}

/// Media transport buttons (mirrors paint).
pub fn mediaBtnCx(card_x: f64, card_w: f64, idx: usize) f64 {
    const btn_r: f64 = 14.0;
    const btn_gap: f64 = 10.0;
    const cx2 = card_x + card_w - 22.0;
    return cx2 - @as(f64, @floatFromInt(2 - idx)) * (btn_r * 2.0 + btn_gap);
}

pub fn mediaBtnCy(card_y: f64, card_h: f64) f64 {
    return card_y + card_h - 24.0;
}

/// Audio slider widget box inside a card at `card_x` (mirrors
/// `control_center_audio_slider_layout`).
pub fn audioSliderGeom(card_x: f64, card_y: f64, tile_w: f64) struct { x: f64, y: f64, w: f64, h: f64 } {
    const sx = card_x + audio_track_x_pad - audio_hit_pad_h;
    const sy = (card_y + audio_track_y_from_card_top) - audio_hit_pad_v;
    const sw = tile_w - 2.0 * audio_track_x_pad + 2.0 * audio_hit_pad_h;
    const sh = audio_track_h + 2.0 * audio_hit_pad_v;
    return .{ .x = sx, .y = sy, .w = sw, .h = sh };
}

pub fn sliderTFromX(sx: f64, sw: f64, px: f64) f64 {
    if (sw <= 0) return 0.0;
    return std.math.clamp((px - sx) / sw, 0.0, 1.0);
}

test "cc-layout: collapsed panels stack tiles + audio + mixer + media + weather" {
    const t = std.testing;
    var st = cc_state.State{};
    var rows: std.ArrayList(MixerRow) = .empty;
    defer rows.deinit(t.allocator);
    const l = computeLayout(400, &st, .{ .mix_total_out = 1 }, 0, true, t.allocator, &rows);
    try t.expectApproxEqAbs(@as(f64, 176.0), l.tile_w, 1e-9);
    try t.expectEqual(@as(f64, 0.0), l.net_h);
    try t.expectEqual(@as(f64, 0.0), l.bt_h);
    // audioY = gridY + tileH + gap
    try t.expectApproxEqAbs(@as(f64, 76.0), l.audio_y, 1e-9);
    // mixer collapsed with 1 stream: 36 + 46 + 18 pad
    try t.expectApproxEqAbs(@as(f64, 100.0), l.mixer_h, 1e-9);
    try t.expectEqual(@as(i32, 1), l.mix_show_out);
    try t.expect(!l.mix_more);
    try t.expectEqual(@as(usize, 1), rows.items.len);
    // tiles(76) + audio(104) + mixer(112) + media(104) + weather(258) = 654.
    try t.expect(l.total_h > 600 and l.total_h < 700);
}

test "cc-layout: network panel grows with rows + password prompt" {
    const t = std.testing;
    var st = cc_state.State{ .network_expanded = true };
    var rows: std.ArrayList(MixerRow) = .empty;
    defer rows.deinit(t.allocator);
    const l = computeLayout(400, &st, .{ .net_rows = 3 }, 0, true, t.allocator, &rows);
    try t.expectEqual(@as(i32, 3), l.net_rows);
    try t.expectApproxEqAbs(@as(f64, 32.0 + 3 * 34.0 + 12.0), l.net_h, 1e-9);
    var st2 = cc_state.State{ .network_expanded = true };
    var rows2: std.ArrayList(MixerRow) = .empty;
    defer rows2.deinit(t.allocator);
    const l2 = computeLayout(400, &st2, .{ .net_rows = 3, .wifi_password_prompt = true }, 0, true, t.allocator, &rows2);
    try t.expectApproxEqAbs(l.net_h + 56.0, l2.net_h, 1e-9);
}

test "cc-layout: mixer expanded shows output + input sections" {
    const t = std.testing;
    var st = cc_state.State{ .mixer_expanded = true };
    var rows: std.ArrayList(MixerRow) = .empty;
    defer rows.deinit(t.allocator);
    const l = computeLayout(400, &st, .{ .mix_total_out = 3, .mix_total_in = 2 }, 0, true, t.allocator, &rows);
    try t.expectEqual(@as(i32, 3), l.mix_show_out);
    try t.expectEqual(@as(i32, 2), l.mix_show_in);
    try t.expect(!l.mix_more);
    try t.expectEqual(@as(usize, 5), rows.items.len);
    try t.expect(!rows.items[0].is_input);
    try t.expect(rows.items[3].is_input);
}

test "cc-layout: animation settles after 200ms" {
    const t = std.testing;
    var st = cc_state.State{
        .network_expanded = true,
        .net_anim_start_ms = 1000,
        .net_anim_from_expanded = false,
        .net_anim_to_expanded = true,
    };
    var rows: std.ArrayList(MixerRow) = .empty;
    defer rows.deinit(t.allocator);
    const mid = computeLayout(400, &st, .{ .net_rows = 2 }, 1100, false, t.allocator, &rows);
    try t.expect(mid.net_h > 0 and mid.net_h < (32.0 + 2 * 34.0 + 12.0));
    rows.clearRetainingCapacity();
    const done = computeLayout(400, &st, .{ .net_rows = 2 }, 1300, false, t.allocator, &rows);
    try t.expectApproxEqAbs(@as(f64, 32.0 + 2 * 34.0 + 12.0), done.net_h, 1e-9);
    try t.expectEqual(@as(u64, 0), st.net_anim_start_ms);
}
