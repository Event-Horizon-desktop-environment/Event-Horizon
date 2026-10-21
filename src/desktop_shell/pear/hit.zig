//! Hit-testing for the compact popup. Every function takes the computed
//! `Layout` so paint and dispatch share one geometry and clicks land on
//! pixels. Anything on the main pages returns false while `overlay` (the
//! networks page) is up, and vice versa.

const std = @import("std");
const layout = @import("layout.zig");

fn inRect(px: f64, py: f64, x: f64, y: f64, w: f64, h: f64) bool {
    return px >= x and px <= x + w and py >= y and py <= y + h;
}

pub fn networkCardHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) bool {
    if (overlay != .none) return false;
    return inRect(px, py, l.net_x, l.row1_y, l.net_w, l.row1_h);
}

pub fn bluetoothCardHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) bool {
    if (overlay != .none) return false;
    return inRect(px, py, l.bt_x, l.row1_y, l.bt_w, l.row1_h);
}

pub fn settingsRowHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) bool {
    if (overlay != .none) return false;
    return inRect(px, py, l.set_x, l.row2_y, l.set_w, l.row2_h);
}

pub fn dndCardHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) bool {
    if (overlay != .none or !l.show_dnd) return false;
    return inRect(px, py, l.dnd_x, l.row2_y, l.dnd_w, l.row2_h);
}

/// Toggle index into `Layout.toggles`, or null.
pub fn toggleHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) ?usize {
    if (overlay != .none) return null;
    for (l.toggles, 0..) |_, i| {
        if (inRect(px, py, layout.toggleX(l, i), l.tog_y, l.tog_w, l.tog_h)) return i;
    }
    return null;
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

fn rowSliderGeom(l: layout.Layout, row_y: f64) SliderGeom {
    const tx = l.pad + layout.row_track_pad_x * l.us;
    const tw = l.w - l.pad * 2.0 - layout.row_track_pad_x * 2.0 * l.us;
    const ty = row_y + layout.row_track_y * l.us;
    const th = layout.row_track_h * l.us;
    return .{
        .track_x = tx,
        .track_y = ty,
        .track_w = tw,
        .track_h = th,
        .hit_x = tx - layout.row_hit_pad * l.us,
        .hit_y = ty - layout.row_hit_pad * l.us,
        .hit_w = tw + 2.0 * layout.row_hit_pad * l.us,
        .hit_h = th + 2.0 * layout.row_hit_pad * l.us,
    };
}

fn sliderHit(g: SliderGeom, px: f64, py: f64) ?f64 {
    if (!inRect(px, py, g.hit_x, g.hit_y, g.hit_w, g.hit_h)) return null;
    return layoutSliderT(g.track_x, g.track_w, px);
}

pub fn layoutSliderT(sx: f64, sw: f64, px: f64) f64 {
    if (sw <= 0) return 0.0;
    return std.math.clamp((px - sx) / sw, 0.0, 1.0);
}

pub fn volumeSliderGeom(l: layout.Layout) SliderGeom {
    return rowSliderGeom(l, l.vol_y);
}

pub fn volumeSliderHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) ?f64 {
    if (overlay != .none or !l.show_volume) return null;
    return sliderHit(rowSliderGeom(l, l.vol_y), px, py);
}

pub fn volumeMuteHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) bool {
    if (overlay != .none or !l.show_volume) return false;
    return circleHit(l.pad + layout.row_icon_cx * l.us, l.vol_y + layout.row_icon_cy * l.us, layout.row_icon_r * l.us + 4.0, px, py);
}

pub fn volumeRowHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) bool {
    if (overlay != .none or !l.show_volume) return false;
    return inRect(px, py, l.pad, l.vol_y, l.w - l.pad * 2.0, l.vol_h);
}

fn circleHit(cx: f64, cy: f64, r: f64, px: f64, py: f64) bool {
    const dx = px - cx;
    const dy = py - cy;
    return dx * dx + dy * dy <= r * r;
}

pub fn outputDeviceRowHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) ?i32 {
    if (overlay != .none) return null;
    var i: i32 = 0;
    while (i < l.out_dev_rows) : (i += 1) {
        const ry = layout.devRowY(l.out_dev_y, i);
        if (inRect(px, py, l.pad + 10.0 * l.us, ry + 6.0 * l.us, l.w - l.pad * 2.0 - 20.0 * l.us, 24.0 * l.us)) return i;
    }
    return null;
}

pub fn inputSliderGeom(l: layout.Layout) SliderGeom {
    return rowSliderGeom(l, l.in_y);
}

pub fn inputSliderHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) ?f64 {
    if (overlay != .none or !l.show_input) return null;
    return sliderHit(rowSliderGeom(l, l.in_y), px, py);
}

pub fn inputMuteHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) bool {
    if (overlay != .none or !l.show_input) return false;
    return circleHit(l.pad + layout.row_icon_cx * l.us, l.in_y + layout.row_icon_cy * l.us, layout.row_icon_r * l.us + 4.0, px, py);
}

pub fn inputRowHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) bool {
    if (overlay != .none or !l.show_input) return false;
    return inRect(px, py, l.pad, l.in_y, l.w - l.pad * 2.0, l.in_h);
}

pub fn inputDeviceRowHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) ?i32 {
    if (overlay != .none) return null;
    var i: i32 = 0;
    while (i < l.in_dev_rows) : (i += 1) {
        const ry = layout.devRowY(l.in_dev_y, i);
        if (inRect(px, py, l.pad + 10.0 * l.us, ry + 6.0 * l.us, l.w - l.pad * 2.0 - 20.0 * l.us, 24.0 * l.us)) return i;
    }
    return null;
}

pub fn brightnessSliderGeom(l: layout.Layout) SliderGeom {
    return rowSliderGeom(l, l.bri_y);
}

pub fn brightnessSliderHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) ?f64 {
    if (overlay != .none or !l.show_brightness) return null;
    return sliderHit(rowSliderGeom(l, l.bri_y), px, py);
}

pub fn mediaButtonHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) ?usize {
    if (overlay != .none or !l.show_media) return null;
    const cy = layout.mediaBtnCy(l);
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const cx = layout.mediaBtnCx(l, i);
        const dx = px - cx;
        const dy = py - cy;
        const r = 14.0 * l.us + 4.0;
        if (dx * dx + dy * dy <= r * r) return i;
    }
    return null;
}

/// Back arrow — shared by both overlay pages.
pub fn backHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) bool {
    if (overlay == .none) return false;
    return inRect(px, py, l.pad, l.pad, 32.0 * l.us, 32.0 * l.us);
}

/// Header checkbox: the Wi-Fi radio on the networks page, the bluetooth
/// power on the bluetooth page. Same rect on both.
pub fn wifiToggleHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) bool {
    if (overlay != .network) return false;
    return inRect(px, py, l.w - l.pad - 30.0 * l.us, l.pad + 6.0 * l.us, 30.0 * l.us, 30.0 * l.us);
}

pub fn btPowerToggleHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) bool {
    if (overlay != .bluetooth) return false;
    return inRect(px, py, l.w - l.pad - 30.0 * l.us, l.pad + 6.0 * l.us, 30.0 * l.us, 30.0 * l.us);
}

fn overlayRowIdx(l: layout.Layout, rows: i32, px: f64, py: f64) ?i32 {
    var i: i32 = 0;
    while (i < rows) : (i += 1) {
        const ry = l.pad + layout.net_header_h * l.us + @as(f64, @floatFromInt(i)) * layout.button_h * l.us;
        if (inRect(px, py, l.pad + 10.0 * l.us, ry + 6.0 * l.us, l.w - l.pad * 2.0 - 20.0 * l.us, 36.0 * l.us)) return i;
    }
    return null;
}

pub fn networkRowHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) ?i32 {
    if (overlay != .network) return null;
    return overlayRowIdx(l, l.wifi_rows, px, py);
}

pub fn btDeviceRowHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) ?i32 {
    if (overlay != .bluetooth) return null;
    return overlayRowIdx(l, l.bt_rows, px, py);
}

/// Which right-hand control of a bluetooth row the press landed on. Callers
/// test the forget `×` first (it sits inside the row rect), then fall back to
/// the row itself — the row body is the Connect/Disconnect/Pair action.
pub const BtCtl = enum { action, forget };

pub fn btCtlHit(l: layout.Layout, overlay: layout.Overlay, px: f64, py: f64) ?struct { idx: i32, ctl: BtCtl } {
    if (overlay != .bluetooth) return null;
    var i: i32 = 0;
    while (i < l.bt_rows) : (i += 1) {
        const r = layout.overlayRow(l, i);
        if (py < r.row_y or py > r.row_y + r.row_h) continue;
        if (px >= r.forget_x and px <= r.forget_x + r.forget_w) return .{ .idx = i, .ctl = .forget };
        if (px >= r.row_x and px <= r.row_x + r.row_w) return .{ .idx = i, .ctl = .action };
    }
    return null;
}

test "pear-hit: main cards gate on the overlay" {
    const t = std.testing;
    const state_mod = @import("state.zig");
    const cfg_mod = @import("config.zig");
    _ = state_mod;
    var tog: [7]layout.Toggle = undefined;
    const l = layout.computeLayout(360, false, false, .none, cfg_mod.Config{}, 1.0, .{}, true, &tog);
    try t.expect(networkCardHit(l, .none, 30, 30));
    try t.expect(!networkCardHit(l, .network, 30, 30));
    try t.expect(bluetoothCardHit(l, .none, 300, 30));
    try t.expect(settingsRowHit(l, .none, 30, l.row2_y + 10));
    try t.expect(dndCardHit(l, .none, 300, l.row2_y + 10));
    try t.expectEqual(@as(?usize, 0), toggleHit(l, .none, layout.toggleX(l, 0) + 4, l.tog_y + 4));
    try t.expect(toggleHit(l, .network, layout.toggleX(l, 0) + 4, l.tog_y + 4) == null);
    const g = volumeSliderGeom(l);
    try t.expect(volumeSliderHit(l, .none, g.track_x + 4, g.track_y) != null);
    try t.expect(volumeMuteHit(l, .none, l.pad + layout.row_icon_cx, l.vol_y + layout.row_icon_cy));
    try t.expect(mediaButtonHit(l, .none, layout.mediaBtnCx(l, 1), layout.mediaBtnCy(l)) == 1);
}

test "pear-hit: overlay rows and wifi toggle" {
    const t = std.testing;
    const cfg_mod = @import("config.zig");
    var tog: [7]layout.Toggle = undefined;
    const l = layout.computeLayout(360, false, false, .network, cfg_mod.Config{}, 1.0, .{ .wifi_aps = 2 }, true, &tog);
    try t.expect(backHit(l, .network, l.pad + 4, l.pad + 4));
    try t.expect(backHit(l, .bluetooth, l.pad + 4, l.pad + 4));
    try t.expect(!backHit(l, .none, l.pad + 4, l.pad + 4));
    try t.expect(wifiToggleHit(l, .network, l.w - l.pad - 20, l.pad + 10));
    try t.expect(networkRowHit(l, .network, 100, l.pad + layout.net_header_h + 10) == 0);
    try t.expect(networkRowHit(l, .none, 100, l.pad + layout.net_header_h + 10) == null);
}

test "pear-hit: bluetooth page rows and power" {
    const t = std.testing;
    const cfg_mod = @import("config.zig");
    var tog: [7]layout.Toggle = undefined;
    const l = layout.computeLayout(360, false, false, .bluetooth, cfg_mod.Config{}, 1.0, .{ .bt_devices = 3 }, true, &tog);
    try t.expectEqual(@as(i32, 3), l.bt_rows);
    try t.expect(btPowerToggleHit(l, .bluetooth, l.w - l.pad - 20, l.pad + 10));
    try t.expect(!btPowerToggleHit(l, .network, l.w - l.pad - 20, l.pad + 10));
    try t.expectEqual(@as(?i32, 1), btDeviceRowHit(l, .bluetooth, 100, l.pad + layout.net_header_h + layout.button_h + 10));
    try t.expect(btDeviceRowHit(l, .network, 100, l.pad + layout.net_header_h + 10) == null);
    // Within a row: the body is the Connect/Disconnect/Pair action, the `×`
    // to its left is forget.
    const r = layout.overlayRow(l, 1);
    const body = btCtlHit(l, .bluetooth, r.row_x + 4.0, r.row_y + 4.0);
    try t.expect(body != null and body.?.idx == 1 and body.?.ctl == .action);
    const cross = btCtlHit(l, .bluetooth, r.forget_x + 2.0, r.row_y + 4.0);
    try t.expect(cross != null and cross.?.ctl == .forget);
    try t.expect(btCtlHit(l, .network, r.row_x + 4.0, r.row_y + 4.0) == null);
    // The networks rows do not answer on the bluetooth page, and the main
    // page stays inert while either overlay is up.
    try t.expect(networkRowHit(l, .bluetooth, 100, l.pad + layout.net_header_h + 10) == null);
    try t.expect(!networkCardHit(l, .bluetooth, 30, 30));
    try t.expect(!networkCardHit(l, .network, 30, 30));
    try t.expect(networkCardHit(l, .none, 30, 30));
}
