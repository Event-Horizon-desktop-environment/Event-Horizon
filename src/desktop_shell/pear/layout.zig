//! Compact popup geometry. All values scale with the combined `us`
//! (`dock_ui_scale × pear_scale`).
//!
//! Counts (device rows, AP rows) arrive as parameters so layout stays pure;
//! brightness availability arrives as a bool (the sysfs scan lives in
//! `brightness.zig`). Reference metrics: popup 360 × scale, pills row 1 at
//! 64 × scale, row 2 at 56 × scale, Section B rows 90 × scale each.

const std = @import("std");
const pear_config = @import("config.zig");

// Base (scale=100) constants.
pub const base_width: f64 = 360.0;
pub const slider_row_h: f64 = 90.0;
pub const media_row_h: f64 = 90.0;
pub const large_spacing: f64 = 12.0;
pub const medium_spacing: f64 = 8.0;
pub const small_spacing: f64 = 6.0;
pub const button_h: f64 = 48.0;
pub const dnd_h: f64 = 56.0;
pub const max_wifi_rows: i32 = 8;
pub const net_header_h: f64 = 48.0;

// Slider track geometry inside a 90 px Section B row (shared paint+hit).
pub const row_track_pad_x: f64 = 16.0;
pub const row_track_y: f64 = 56.0;
pub const row_track_h: f64 = 12.0;
pub const row_hit_pad: f64 = 10.0;
pub const row_icon_cx: f64 = 28.0;
pub const row_icon_cy: f64 = 28.0;
pub const row_icon_r: f64 = 14.0;

/// Quick-toggle slots, left to right (mirrors `PearToggle` order).
pub const Toggle = enum(u8) {
    device_link = 0,
    night_color = 1,
    color_scheme = 2,
    camera = 3,
    redeye = 4,
    cmd1 = 5,
    cmd2 = 6,
};

/// Which full-page overlay is up. Pear has no mixer/weather; the networks
/// page exists; the bluetooth page is the same geometry with a
/// power checkbox and device rows (the compact layout only has the power
/// toggle on the card itself).
pub const Overlay = enum { none, network, bluetooth };

pub const Layout = struct {
    w: f64 = 0,
    us: f64 = 1.0,
    pad: f64 = 12.0,
    gap_m: f64 = 8.0,
    gap_s: f64 = 6.0,
    // Row 1: Network + Bluetooth pills.
    row1_y: f64 = 12.0,
    row1_h: f64 = 64.0,
    net_x: f64 = 12.0,
    net_w: f64 = 162.0,
    bt_x: f64 = 0.0,
    bt_w: f64 = 162.0,
    // Row 2: Settings + Do Not Disturb pills.
    row2_y: f64 = 0.0,
    row2_h: f64 = 56.0,
    set_x: f64 = 12.0,
    set_w: f64 = 162.0,
    dnd_x: f64 = 0.0,
    dnd_w: f64 = 162.0,
    show_dnd: bool = true,
    // Toggles row (full width, 0 height when empty).
    tog_x: f64 = 12.0,
    tog_y: f64 = 0.0,
    tog_h: f64 = 64.0,
    tog_w: f64 = 0.0,
    toggles: []const Toggle = &.{},
    // Section B rows (full width, 0 height when hidden).
    show_volume: bool = true,
    vol_y: f64 = 0.0,
    vol_h: f64 = 90.0,
    out_dev_rows: i32 = 0,
    out_dev_y: f64 = 0.0,
    out_dev_h: f64 = 0.0,
    show_input: bool = true,
    in_y: f64 = 0.0,
    in_h: f64 = 90.0,
    in_dev_rows: i32 = 0,
    in_dev_y: f64 = 0.0,
    in_dev_h: f64 = 0.0,
    show_brightness: bool = true,
    bri_y: f64 = 0.0,
    bri_h: f64 = 90.0,
    show_media: bool = true,
    media_y: f64 = 0.0,
    media_h: f64 = 90.0,
    // Networks overlay (either page: same header + row pitch).
    wifi_rows: i32 = 0,
    bt_rows: i32 = 0,
    overlay_h: f64 = 0.0,
    total_h: f64 = 0.0,
};

pub const Counts = struct {
    out_dev_total: i32 = 0,
    in_dev_total: i32 = 0,
    wifi_aps: i32 = 0,
    bt_devices: i32 = 0,
};

pub fn toggleX(l: Layout, idx: usize) f64 {
    return l.tog_x + @as(f64, @floatFromInt(idx)) * (l.tog_w + l.gap_s);
}

/// Device-panel row geometry (34 px pitch, 32 px header), mirrors paint.
pub fn devRowY(panel_y: f64, idx: i32) f64 {
    return panel_y + 32.0 + @as(f64, @floatFromInt(idx)) * 34.0;
}

/// Row + right-hand controls inside an overlay page. The networks page uses
/// the row box only (its readout is free-floating); the bluetooth page adds
/// the action pill (Connect/Disconnect/Pair) and the forget `×`. Paint and
/// hit both come here so a click lands on the pixels.
pub const OverlayRow = struct {
    row_x: f64 = 0,
    row_y: f64 = 0,
    row_w: f64 = 0,
    row_h: f64 = 36.0,
    action_x: f64 = 0,
    action_w: f64 = 0,
    forget_x: f64 = 0,
    forget_w: f64 = 0,
};

pub fn overlayRow(l: Layout, idx: i32) OverlayRow {
    const ry = l.pad + net_header_h * l.us + @as(f64, @floatFromInt(idx)) * button_h * l.us + 6.0 * l.us;
    const rx = l.pad + 10.0 * l.us;
    const rw = l.w - l.pad * 2.0 - 20.0 * l.us;
    const action_w = 84.0 * l.us;
    const forget_w = 26.0 * l.us;
    return .{
        .row_x = rx,
        .row_y = ry,
        .row_w = rw,
        .action_x = rx + rw - 10.0 * l.us - action_w,
        .action_w = action_w,
        .forget_x = rx + rw - 10.0 * l.us - action_w - forget_w - 6.0 * l.us,
        .forget_w = forget_w,
    };
}

/// Media transport buttons: right-aligned prev/play/next in the media row.
/// NOTE: `pear_media_btn_cx` ignores `us` (uses raw 14/10/22
/// constants) — mirrored here so paint+hit agree.
pub fn mediaBtnCx(l: Layout, idx: usize) f64 {
    const right = l.w - l.pad - 22.0;
    return right - @as(f64, @floatFromInt(2 - idx)) * (14.0 * 2.0 + 10.0);
}

pub fn mediaBtnCy(l: Layout) f64 {
    return l.media_y + l.media_h - 24.0;
}

/// `cc_compute_pear_layout` with injected counts. `toggles_buf` backs the
/// toggle list (max 7); callers pass a fixed buffer so no allocation happens.
pub fn computeLayout(
    popup_w: f64,
    state_out_expanded: bool,
    state_in_expanded: bool,
    overlay: Overlay,
    cfg: pear_config.Config,
    ui_scale: f64,
    counts: Counts,
    bri_available: bool,
    toggles_buf: *[7]Toggle,
) Layout {
    var l = Layout{ .w = popup_w };
    const us = @max(0.5, ui_scale * pear_config.scaleOf(cfg));
    l.us = us;
    l.pad = large_spacing * us;
    l.gap_m = medium_spacing * us;
    l.gap_s = small_spacing * us;

    l.row1_y = l.pad;
    l.row1_h = 64.0 * us;
    l.net_w = (popup_w - l.pad * 2.0 - l.gap_m) * 0.5;
    l.bt_w = l.net_w;
    l.net_x = l.pad;
    l.bt_x = l.pad + l.net_w + l.gap_m;

    l.row2_y = l.row1_y + l.row1_h + l.gap_m;
    l.row2_h = 56.0 * us;
    l.set_w = l.net_w;
    l.dnd_w = l.set_w;
    l.set_x = l.pad;
    l.dnd_x = l.pad + l.set_w + l.gap_m;

    l.show_dnd = cfg.show_dnd;
    var n_tog: usize = 0;
    if (cfg.show_device_link and cfg.device_link_cmd.len > 0) {
        toggles_buf[n_tog] = .device_link;
        n_tog += 1;
    }
    if (cfg.show_night_color) {
        toggles_buf[n_tog] = .night_color;
        n_tog += 1;
    }
    if (cfg.show_color_switcher) {
        toggles_buf[n_tog] = .color_scheme;
        n_tog += 1;
    }
    if (cfg.show_camera) {
        toggles_buf[n_tog] = .camera;
        n_tog += 1;
    }
    if (cfg.show_redeye) {
        toggles_buf[n_tog] = .redeye;
        n_tog += 1;
    }
    if (cfg.show_cmd1 and cfg.cmd_run1.len > 0) {
        toggles_buf[n_tog] = .cmd1;
        n_tog += 1;
    }
    if (cfg.show_cmd2 and cfg.cmd_run2.len > 0) {
        toggles_buf[n_tog] = .cmd2;
        n_tog += 1;
    }
    l.toggles = toggles_buf[0..n_tog];
    l.tog_x = l.pad;
    l.tog_y = l.row2_y + l.row2_h + l.gap_m;
    l.tog_h = if (n_tog == 0) 0.0 else 64.0 * us;
    l.tog_w = if (n_tog == 0) 0.0 else (popup_w - l.pad * 2.0 - @as(f64, @floatFromInt(n_tog - 1)) * l.gap_s) / @as(f64, @floatFromInt(n_tog));

    var y = l.tog_y + l.tog_h + (if (n_tog == 0) 0.0 else l.gap_m);
    l.show_volume = cfg.show_volume;
    l.vol_y = y;
    l.vol_h = if (l.show_volume) slider_row_h * us else 0.0;
    if (l.show_volume) y += l.vol_h + l.gap_m;

    l.out_dev_rows = if (state_out_expanded) @min(8, counts.out_dev_total) else 0;
    l.out_dev_y = y;
    l.out_dev_h = if (l.out_dev_rows > 0) (32.0 + @as(f64, @floatFromInt(l.out_dev_rows)) * 34.0 + 12.0) * us else 0.0;
    if (l.out_dev_h > 0.0) y += l.out_dev_h + l.gap_m;

    l.show_input = cfg.show_input;
    l.in_y = y;
    l.in_h = if (l.show_input) slider_row_h * us else 0.0;
    if (l.show_input) y += l.in_h + l.gap_m;

    l.in_dev_rows = if (state_in_expanded) @min(8, counts.in_dev_total) else 0;
    l.in_dev_y = y;
    l.in_dev_h = if (l.in_dev_rows > 0) (32.0 + @as(f64, @floatFromInt(l.in_dev_rows)) * 34.0 + 12.0) * us else 0.0;
    if (l.in_dev_h > 0.0) y += l.in_dev_h + l.gap_m;

    l.show_brightness = cfg.show_brightness and bri_available;
    l.bri_y = y;
    l.bri_h = if (l.show_brightness) slider_row_h * us else 0.0;
    if (l.show_brightness) y += l.bri_h + l.gap_m;

    l.show_media = cfg.show_media_player;
    l.media_y = y;
    l.media_h = if (l.show_media) media_row_h * us else 0.0;
    if (l.show_media) y += l.media_h + l.gap_m;
    y += l.pad - l.gap_m;

    // The overlay page (networks or bluetooth) covers the popup: same 48 px
    // header, same 48 px rows, capped at `max_wifi_rows`.
    const ov_rows: i32 = switch (overlay) {
        .network => @min(max_wifi_rows, counts.wifi_aps),
        .bluetooth => @min(max_wifi_rows, counts.bt_devices),
        .none => 0,
    };
    l.wifi_rows = if (overlay == .network) ov_rows else 0;
    l.bt_rows = if (overlay == .bluetooth) ov_rows else 0;
    l.overlay_h = l.pad + net_header_h * us + @as(f64, @floatFromInt(ov_rows)) * button_h * us + l.pad;
    l.total_h = if (overlay != .none) @max(y, l.overlay_h) else y;
    return l;
}

test "pear-layout: default sections stack at scale 100" {
    const t = std.testing;
    var tog: [7]Toggle = undefined;
    const l = computeLayout(360, false, false, .none, .{}, 1.0, .{}, true, &tog);
    try t.expectApproxEqAbs(@as(f64, 1.0), l.us, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 12.0), l.pad, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 164.0), l.net_w, 1e-9);
    try t.expectEqual(@as(usize, 4), l.toggles.len); // night, scheme, camera, redeye
    try t.expect(l.toggles[0] == .night_color);
    try t.expectApproxEqAbs(@as(f64, 90.0), l.vol_h, 1e-9);
    try t.expect(l.show_brightness);
    try t.expect(l.show_media);
    // 12+64+8+56+8+64(toggles)+8+90+8+90+8+90+8+90+8 then pad-gap adjust:
    // y ends at media end + gap, total = y + pad - gap.
    try t.expect(l.total_h > 600 and l.total_h < 700);
}

test "pear-layout: overlay covers with wifi rows" {
    const t = std.testing;
    var tog: [7]Toggle = undefined;
    const l = computeLayout(360, false, false, .network, .{}, 1.0, .{ .wifi_aps = 3 }, true, &tog);
    try t.expectEqual(@as(i32, 3), l.wifi_rows);
    try t.expectApproxEqAbs(@as(f64, 12.0 + 48.0 + 3 * 48.0 + 12.0), l.overlay_h, 1e-9);
    try t.expect(l.total_h >= l.overlay_h);
}

test "pear-layout: the bluetooth page reuses the overlay geometry" {
    const t = std.testing;
    var tog: [7]Toggle = undefined;
    const l = computeLayout(360, false, false, .bluetooth, .{}, 1.0, .{ .bt_devices = 12 }, true, &tog);
    try t.expectEqual(@as(i32, 8), l.bt_rows); // capped like the wifi page
    try t.expectEqual(@as(i32, 0), l.wifi_rows);
    try t.expectApproxEqAbs(@as(f64, 12.0 + 48.0 + 8 * 48.0 + 12.0), l.overlay_h, 1e-9);
    try t.expect(l.total_h >= l.overlay_h);
}

test "pear-layout: device panels expand to 8 rows max" {
    const t = std.testing;
    var tog: [7]Toggle = undefined;
    const l = computeLayout(360, true, false, .none, .{}, 1.0, .{ .out_dev_total = 20 }, true, &tog);
    try t.expectEqual(@as(i32, 8), l.out_dev_rows);
    try t.expectApproxEqAbs(@as(f64, 32.0 + 8 * 34.0 + 12.0), l.out_dev_h, 1e-9);
    var tog2: [7]Toggle = undefined;
    const l2 = computeLayout(360, false, false, .none, .{}, 1.0, .{ .out_dev_total = 20 }, true, &tog2);
    try t.expectEqual(@as(f64, 0.0), l2.out_dev_h);
}
