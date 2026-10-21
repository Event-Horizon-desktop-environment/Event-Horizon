//! Pear interaction state, shared across both
//! popups; pear is separated here with only what the compact layout reads:
//! expansion flags, slider drags, the networks overlay, the Wi-Fi prompt,
//! and hover. (Pear has no mixer, no weather card, no animations.)

const std = @import("std");
// `Overlay` lives with the geometry: layout paints and hit-tests it.
const layout_mod = @import("layout.zig");

pub const HoverTarget = enum(u8) {
    none = 0,
    network_card = 1,
    bluetooth_card = 2,
    settings_row = 3,
    dnd_card = 4,
    toggle = 5,
    volume_slider = 6,
    volume_mute = 7,
    input_slider = 8,
    input_mute = 9,
    output_device_row = 10,
    input_device_row = 11,
    brightness_slider = 12,
    media_prev = 13,
    media_play_pause = 14,
    media_next = 15,
    media_card = 16,
    networks_back = 17,
    wifi_toggle = 18,
    network_row = 19,
    bt_device_row = 20,
};

pub const State = struct {
    // Expansion flags (preserved across close/reopen).
    output_devices_expanded: bool = false,
    input_devices_expanded: bool = false,

    // Volume drag.
    vol_drag_active: bool = false,
    vol_drag_t: f64 = -1.0,
    // Input drag.
    in_drag_active: bool = false,
    in_drag_t: f64 = -1.0,
    // Brightness drag (separate so it never fights the audio rows).
    bri_drag_active: bool = false,
    bri_drag_t: f64 = -1.0,

    // Overlay pages (cover the popup, z=999). The networks page
    // is its own; the bluetooth page reuses its geometry with a power
    // checkbox in the header and one row per device (scan starts on open).
    networks_overlay: bool = false,
    bt_overlay: bool = false,

    hover_target: HoverTarget = .none,
    hover_row_idx: i32 = -1,
    hover_toggle_idx: i32 = -1,

    pub fn resetDrag(self: *State) void {
        self.vol_drag_active = false;
        self.vol_drag_t = -1.0;
        self.in_drag_active = false;
        self.in_drag_t = -1.0;
        self.bri_drag_active = false;
        self.bri_drag_t = -1.0;
    }

    pub fn clearHover(self: *State) void {
        self.hover_target = .none;
        self.hover_row_idx = -1;
        self.hover_toggle_idx = -1;
    }

    /// Which overlay page is up (the bluetooth page wins if both flags are
    /// somehow set). Layout, hit and paint all branch on this one answer.
    pub fn overlay(self: *const State) layout_mod.Overlay {
        if (self.bt_overlay) return .bluetooth;
        if (self.networks_overlay) return .network;
        return .none;
    }
};

test "pear-state: defaults are all closed and idle" {
    const t = std.testing;
    const s = State{};
    try t.expect(!s.output_devices_expanded);
    try t.expect(!s.networks_overlay);
    try t.expect(!s.bt_overlay);
    try t.expect(s.overlay() == .none);
    try t.expectEqual(@as(f64, -1.0), s.vol_drag_t);
    try t.expect(s.hover_target == .none);
}

test "pear-state: overlay() reports which page is up" {
    const t = std.testing;
    var s = State{};
    s.networks_overlay = true;
    try t.expect(s.overlay() == .network);
    s.bt_overlay = true;
    // The bluetooth page wins if both flags are somehow set.
    try t.expect(s.overlay() == .bluetooth);
    s.networks_overlay = false;
    try t.expect(s.overlay() == .bluetooth);
    s.bt_overlay = false;
    try t.expect(s.overlay() == .none);
}
