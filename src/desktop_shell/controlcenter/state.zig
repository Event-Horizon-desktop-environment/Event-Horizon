//! Popup interaction state.
//! popup's interaction state. One value lives on the dock for the lifetime
//! of the control-center popup and is threaded through layout, paint, hit
//! and dispatch so a click always lands where the pixels are.
//!
//! Drag suppress windows, pending device switches,
//! wifi/bluetooth error lines, expansion flags, panel animations and hover
//! tracking. Every field below is one of those, with the same name and the
//! same default, minus string payloads (owned slices would force
//! an allocator through every pure layout call — the popup host keeps those
//! next to the state instead).

const std = @import("std");

/// `CcModal` — which modal overlay (if any) covers the popup. The legacy
/// popup never opens one (it expands
/// panels in place); the value is kept so hit/dispatch can reject clicks
/// the same way when a modal is up.
pub const Modal = enum(u8) {
    none = 0,
    network = 1,
    bluetooth = 2,
    audio_output = 3,
    audio_input = 4,
    mixer = 5,
};

/// `CcHoverTarget` — what the pointer is over. Names and numbering follow
/// exactly, so logs line up.
pub const HoverTarget = enum(u8) {
    none = 0,
    network_grid = 1,
    network_card = 2,
    network_row = 3,
    bluetooth_grid = 4,
    bluetooth_card = 5,
    bluetooth_row = 6,
    audio_output_grid = 7,
    audio_input_grid = 8,
    output_audio_slider = 9,
    output_audio_mute = 10,
    input_audio_slider = 11,
    input_audio_mute = 12,
    output_device_row = 13,
    input_device_row = 14,
    mixer_card = 15,
    mixer_slider = 16,
    media_prev = 17,
    media_play_pause = 18,
    media_next = 19,
    media_card = 20,
    weather_card = 21,
    settings_row = 22,
    dnd_card = 23,
    device_link_card = 24,
    night_color_card = 25,
    color_scheme_card = 26,
    camera_card = 27,
    redeye_card = 28,
    cmd_card1 = 29,
    cmd_card2 = 30,
    volume_card = 31,
    input_card = 32,
    brightness_card = 33,
    networks_back = 34,
    wifi_toggle = 35,
};

pub const State = struct {
    active_modal: Modal = .none,

    // Audio output drag (volume card / output slider).
    audio_drag_active: bool = false,
    audio_drag_visual_t: f64 = -1.0,
    audio_last_logged_pct: i32 = -1,
    audio_drag_ui_pct: i32 = -1,
    audio_last_applied_pct: i32 = -1,
    audio_last_apply_ms: u64 = 0,
    audio_ignore_state_until_ms: u64 = 0,

    // Audio input drag.
    input_drag_active: bool = false,
    input_drag_visual_t: f64 = -1.0,
    input_last_logged_pct: i32 = -1,
    input_drag_ui_pct: i32 = -1,
    input_last_applied_pct: i32 = -1,
    input_last_apply_ms: u64 = 0,
    input_ignore_state_until_ms: u64 = 0,

    // Brightness drag (pear layout keeps its own; legacy shares the slot).
    pear_bri_drag_active: bool = false,
    pear_bri_drag_t: f64 = -1.0,
    pear_bri_last_apply_ms: u64 = 0,
    pear_bri_last_applied_pct: i32 = -1,
    pear_bri_last_logged_pct: i32 = -1,

    // Mixer drag.
    mixer_drag_active: bool = false,
    mixer_drag_visual_t: f64 = -1.0,
    mixer_drag_stream_id: i32 = -1,
    mixer_drag_is_input: bool = false,
    mixer_last_logged_pct: i32 = -1,
    mixer_drag_ui_pct: i32 = -1,
    mixer_last_applied_pct: i32 = -1,
    mixer_last_apply_ms: u64 = 0,
    mixer_ignore_state_until_ms: u64 = 0,
    mixer_drag_sx: f64 = 0.0,
    mixer_drag_sw: f64 = 1.0,

    // Expansion states — the five toggles the screenshot shows open/closed.
    mixer_expanded: bool = false,
    network_expanded: bool = false,
    bluetooth_expanded: bool = false,
    output_devices_expanded: bool = false,
    input_devices_expanded: bool = false,
    weather_expanded: bool = false,
    networks_overlay: bool = false,

    // Panel open/close animations (200 ms).
    net_anim_start_ms: u64 = 0,
    net_anim_from_expanded: bool = false,
    net_anim_to_expanded: bool = false,
    bt_anim_start_ms: u64 = 0,
    bt_anim_from_expanded: bool = false,
    bt_anim_to_expanded: bool = false,
    weather_anim_start_ms: u64 = 0,
    weather_anim_from_expanded: bool = false,
    weather_anim_to_expanded: bool = false,

    hover_target: HoverTarget = .none,
    hover_row_idx: i32 = -1,
    hover_stream_id: i32 = -1,

    cc_last_settle_resize_ms: u64 = 0,

    open_bench_start_ms: u64 = 0,
    open_bench_logged_first_configure: bool = false,
    open_bench_logged_first_paint: bool = false,

    pub fn resetDrag(self: *State) void {
        self.audio_drag_active = false;
        self.audio_drag_visual_t = -1.0;
        self.input_drag_active = false;
        self.input_drag_visual_t = -1.0;
        self.mixer_drag_active = false;
        self.mixer_drag_visual_t = -1.0;
        self.mixer_drag_stream_id = -1;
        self.pear_bri_drag_active = false;
        self.pear_bri_drag_t = -1.0;
    }

    pub fn clearHover(self: *State) void {
        self.hover_target = .none;
        self.hover_row_idx = -1;
        self.hover_stream_id = -1;
    }
};

test "cc-state: defaults match the specified initial state" {
    const t = std.testing;
    const s = State{};
    try t.expect(s.active_modal == .none);
    try t.expect(!s.audio_drag_active);
    try t.expectEqual(@as(f64, -1.0), s.audio_drag_visual_t);
    try t.expectEqual(@as(i32, -1), s.audio_last_logged_pct);
    try t.expect(!s.mixer_expanded);
    try t.expect(!s.network_expanded);
    try t.expect(!s.networks_overlay);
    try t.expect(s.hover_target == .none);
    try t.expectEqual(@as(i32, -1), s.hover_row_idx);
}

test "cc-state: resetDrag clears all three drags" {
    const t = std.testing;
    var s = State{
        .audio_drag_active = true,
        .input_drag_active = true,
        .mixer_drag_active = true,
        .mixer_drag_stream_id = 7,
    };
    s.resetDrag();
    try t.expect(!s.audio_drag_active);
    try t.expect(!s.input_drag_active);
    try t.expect(!s.mixer_drag_active);
    try t.expectEqual(@as(i32, -1), s.mixer_drag_stream_id);
}
