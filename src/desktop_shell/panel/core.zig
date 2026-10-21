//! Panel core logic — port of `src/desktop_shell/panel/core/panel.cpp`
//! (geometry application, scroll-volume, context-hide, click dispatch,
//! dead zones) and the layout helpers from `panel_paint.cpp:189-239`.
//!
//! Wayland calls stay in `bin/panel.zig`; everything here is pure and tested.
//! C++ line references are to the files above.

const std = @import("std");
const types = @import("types.zig");
const settings_mod = @import("settings.zig");
const state_mod = @import("state.zig");
const popup_pos = @import("../shared/popup_position.zig");

const PanelSettings = settings_mod.PanelSettings;

/// Painted bar height: floating mode adds 4 px so the pill floats inside the
/// layer (`panel.cpp:58,583`, `panel_settings.hpp:97-98`).
pub fn barHeight(s: *const PanelSettings) i32 {
    return s.height + if (settings_mod.isFloating(s)) @as(i32, 4) else 0;
}

/// Exclusive zone: 0 when disabled, overlaying, or hiding; else bar height +
/// gap (`panel_geometry.cpp:61-62`, `panel.cpp:583-585`).
pub fn exclusiveZone(s: *const PanelSettings, enabled: bool) i32 {
    if (!enabled or !s.reserve_space) return 0;
    if (s.auto_hide or s.smart_auto_hide) return 0;
    return barHeight(s) + settings_mod.exclusiveZoneGapPx(s);
}

/// Layer anchor + margins for the bar (`panel_geometry.cpp:45-65`).
/// `top` selects the TOP vs BOTTOM edge anchor; left|right always set.
pub const BarPlacement = struct {
    anchor_top: bool,
    margin_edge: i32,
    margin_side: i32,
    exclusive_zone: i32,
    bar_h: i32,
};

pub fn barPlacement(s: *const PanelSettings, enabled: bool) BarPlacement {
    const edge = settings_mod.edgeGapPx(s);
    const float_inset: i32 = if (settings_mod.isFloating(s)) s.floating_amount + edge else edge;
    return .{
        .anchor_top = s.position_top,
        .margin_edge = float_inset,
        .margin_side = 0,
        .exclusive_zone = exclusiveZone(s, enabled),
        .bar_h = barHeight(s),
    };
}

/// Popup layer placement: horizontally centred on `anchor_x` via the shared
/// popup-position helper, vertically clearing the bar
/// (`panel_geometry.cpp:23-43`, `panel.cpp:1193-1239`).
pub const PopupPlacement = struct {
    margin_side: i32,
    margin_edge: i32,
    clearance: i32,
};

pub fn popupPlacement(
    s: *const PanelSettings,
    layer_w: f64,
    anchor_x: i32,
    popup_w: i32,
    popup_h: i32,
) PopupPlacement {
    _ = popup_h;
    const clearance = settings_mod.popupClearancePx(s);
    const placed = popup_pos.place(.{
        .anchor_x = @floatFromInt(anchor_x),
        .popup_w = @floatFromInt(popup_w),
        .layer_w = layer_w,
        .layer_origin_x = 0,
        .output_w = 0,
        .bottom_clearance = @floatFromInt(clearance),
    });
    return .{
        .margin_side = @intFromFloat(@round(placed.margin_left)),
        .margin_edge = @intFromFloat(@round(placed.margin_bottom)),
        .clearance = clearance,
    };
}

/// Fill-mode bar width: content-sized centred pill measured from the section
/// widths (`panel.cpp:634-642`).
pub fn fillBarWidth(left: f64, center: f64, right: f64, ui_scale: f64, layer_w: f64) f64 {
    const pad = settings_mod.stripPadPx(ui_scale);
    const sec_gap = settings_mod.sectionGapPx(ui_scale);
    const half = pad + @max(left, right) + sec_gap;
    const want = center + 2.0 * half;
    return std.math.clamp(want, 80.0, layer_w);
}

/// Scroll-volume step (`panel.cpp:315-326`): vertical scroll over empty bar
/// space nudges the sink ±5 %. Returns the new 0..1 level, or null when the
/// event is not a volume scroll.
pub fn scrollVolumeNext(
    scroll_volume: bool,
    hover_slot: i32,
    axis_is_vertical: bool,
    delta: f64,
    cur_01: f64,
) ?f64 {
    if (!axis_is_vertical) return null;
    if (!scroll_volume) return null;
    if (hover_slot >= 0) return null;
    if (delta == 0) return null;
    const step: f64 = if (delta < 0) 0.05 else -0.05;
    return std.math.clamp(cur_01 + step, 0.0, 1.0);
}

/// Context-hide update (`panel.cpp:891-915`). Returns the new `reveal` value.
pub fn contextHideReveal(
    smart_auto_hide: bool,
    reveal_on_switch: bool,
    auto_hide: bool,
    any_occupied: bool,
    active_ws: i32,
    ctx: *state_mod.ContextHide,
    now_ms: u64,
    reveal: bool,
) bool {
    if (!smart_auto_hide and !reveal_on_switch) return reveal;
    var want = reveal;
    if (active_ws >= 0 and active_ws != ctx.last_active_ws) {
        ctx.last_active_ws = active_ws;
        if (reveal_on_switch and (auto_hide or smart_auto_hide)) ctx.reveal_until_ms = now_ms + 2000;
    }
    if (smart_auto_hide) want = !any_occupied;
    if (now_ms < ctx.reveal_until_ms) want = true;
    if (!auto_hide and !smart_auto_hide) want = true;
    return want;
}

/// Slot-kind numbers for dispatch. These mirror the Zig widget `SlotKind`
/// order used in the hit rects (`slot_kind` in `panel_paint.hpp:26-33` via
/// `shared_slot_paint.hpp`); only the kinds the panel acts on are named.
pub const SlotKind = enum(u8) {
    clock = 0,
    weather = 1,
    media = 2,
    workspaces = 3,
    control_center = 4,
    battery = 5,
    bluetooth = 6,
    layout = 7,
    world_clock = 8,
    volume_mixer = 9,
    vpn = 10,
    overview = 11,
    tray = 12,
    app = 13,
    settings = 14,
    trash = 15,
    other = 255,
};

/// What a slot click does (`panel.cpp:1451-1541`).
pub const ClickAction = union(enum) {
    none,
    overview_toggle,
    workspace_pick,
    media_prev,
    media_next,
    media_play_pause,
    media_popup,
    app_activate: u64, // chosenSerial
    launch_settings,
    open_trash,
    open_popup: types.PopupKind,
};

pub const Button = struct {
    pub const left: u32 = 0x110;
    pub const middle: u32 = 0x112;
    pub const right: u32 = 0x111;
};

/// `panel_dispatch_slot_click` without the Wayland side effects: maps a hit
/// + button to an action. Popup open/close I/O stays in the binary.
pub fn dispatchSlotClick(
    slot_kind: u8,
    press_button: u32,
    chosen_serial: u64,
    media_zone: i32, // DockMpris::media_hit_zone: 0 prev, 1 play, 2 next, else popup
    popup_open_kind: types.PopupKind,
) ClickAction {
    switch (slot_kind) {
        @intFromEnum(SlotKind.overview) => return .overview_toggle,
        @intFromEnum(SlotKind.workspaces) => {
            // Middle-click opens the overview (GNOME parity); left switches.
            if (press_button == Button.middle) return .overview_toggle;
            return .workspace_pick;
        },
        @intFromEnum(SlotKind.media) => {
            if (media_zone == 0) return .media_prev;
            if (media_zone == 2) return .media_next;
            if (media_zone == 1) return .media_play_pause;
            if (popup_open_kind == .media_player) return .none; // close handled by caller
            return .media_popup;
        },
        @intFromEnum(SlotKind.app) => {
            if (chosen_serial != 0) return .{ .app_activate = chosen_serial };
            return .none;
        },
        @intFromEnum(SlotKind.settings) => return .launch_settings,
        @intFromEnum(SlotKind.trash) => return .open_trash,
        @intFromEnum(SlotKind.clock), @intFromEnum(SlotKind.world_clock) => return .{ .open_popup = .calendar },
        @intFromEnum(SlotKind.control_center) => return .{ .open_popup = .control_center },
        @intFromEnum(SlotKind.weather) => return .{ .open_popup = .weather },
        @intFromEnum(SlotKind.volume_mixer) => return .{ .open_popup = .volume_mixer },
        @intFromEnum(SlotKind.battery) => return .{ .open_popup = .battery },
        @intFromEnum(SlotKind.bluetooth) => return .{ .open_popup = .bluetooth },
        @intFromEnum(SlotKind.vpn) => return .{ .open_popup = .vpn },
        @intFromEnum(SlotKind.layout) => return .{ .open_popup = .layout },
        @intFromEnum(SlotKind.tray) => {
            if (press_button == Button.left) return .{ .open_popup = .tray };
            if (press_button == Button.right) return .{ .open_popup = .tray };
            return .{ .open_popup = .tray };
        },
        else => return .none,
    }
}

/// Dead-zone click (`panel.cpp:1543-1571`): button selects which dead-zone
/// action string applies (0x110 left, 0x112 middle, 0x111 right).
pub fn deadZonePopup(button: u32, left: []const u8, middle: []const u8, right: []const u8) ?types.PopupKind {
    const action: []const u8 = if (button == Button.left)
        left
    else if (button == Button.middle)
        middle
    else if (button == Button.right)
        right
    else
        return null;
    if (std.mem.eql(u8, action, "control-center")) return .control_center;
    if (std.mem.eql(u8, action, "calendar")) return .calendar;
    if (std.mem.eql(u8, action, "tray")) return .tray;
    return null;
}

/// Tray popup row heights (`panel.cpp:1419-1420`): 26 px per item, 13 px per
/// separator, +8 px padding.
pub fn trayPopupHeight(items: []const types.PopupItem) i32 {
    var rows: i32 = 0;
    for (items) |it| rows += if (it.isSeparator()) @as(i32, 13) else @as(i32, 26);
    return rows + 8;
}

/// Tooltip text for a slot (`panel.cpp:957-1014`). App slots resolve via the
/// desktop entry name at the call site; this covers the fixed labels.
pub fn tooltipFor(kind: u8, layout_title: ?[]const u8, buf: []u8) []const u8 {
    const label: []const u8 = switch (kind) {
        @intFromEnum(SlotKind.clock) => "Clock",
        @intFromEnum(SlotKind.world_clock) => "World Clock",
        @intFromEnum(SlotKind.weather) => "Weather",
        @intFromEnum(SlotKind.media) => "Media",
        @intFromEnum(SlotKind.workspaces) => "Workspaces",
        @intFromEnum(SlotKind.overview) => "Overview",
        @intFromEnum(SlotKind.control_center) => "Control Center",
        @intFromEnum(SlotKind.battery) => "Battery",
        @intFromEnum(SlotKind.bluetooth) => "Bluetooth",
        @intFromEnum(SlotKind.volume_mixer) => "Volume",
        @intFromEnum(SlotKind.vpn) => "VPN",
        @intFromEnum(SlotKind.tray) => "Tray",
        @intFromEnum(SlotKind.settings) => "Settings",
        @intFromEnum(SlotKind.trash) => "Trash",
        @intFromEnum(SlotKind.layout) => "Window Layout",
        else => return layout_title orelse "",
    };
    if (kind == @intFromEnum(SlotKind.layout)) {
        if (layout_title) |lt| {
            const r = std.fmt.bufPrint(buf, "Window Layout: {s}", .{lt}) catch return "Window Layout";
            return r;
        }
    }
    return label;
}

test "panel-core: bar height + exclusive zone" {
    const t = std.testing;
    var s = PanelSettings{ .height = 36, .width_mode = 1, .reserve_space = true };
    try t.expectEqual(@as(i32, 36), barHeight(&s));
    s.width_mode = 0;
    try t.expectEqual(@as(i32, 40), barHeight(&s));
    s.width_mode = 1;
    s.enabled = true;
    try t.expectEqual(@as(i32, 36), exclusiveZone(&s, true));
    s.auto_hide = true;
    try t.expectEqual(@as(i32, 0), exclusiveZone(&s, true));
    s.auto_hide = false;
    s.reserve_space = false;
    try t.expectEqual(@as(i32, 0), exclusiveZone(&s, true));
    const p = barPlacement(&s, true);
    try t.expect(p.anchor_top);
    try t.expectEqual(@as(i32, 36), p.bar_h);
}

test "panel-core: popup placement centres then clamps" {
    const t = std.testing;
    var s = PanelSettings{ .height = 36, .width_mode = 1, .edge_gap = 0 };
    const p = popupPlacement(&s, 1920, 500, 320, 340);
    try t.expectEqual(@as(i32, 36), p.clearance);
    try t.expectEqual(@as(i32, 340), p.margin_side); // 500-160
    try t.expectEqual(@as(i32, 36), p.margin_edge);
    const edge = popupPlacement(&s, 1920, 10, 320, 340);
    try t.expectEqual(@as(i32, 0), edge.margin_side);
}

test "panel-core: fill bar is content-sized and clamped" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 80.0), fillBarWidth(0, 0, 0, 1.0, 1920));
    const w = fillBarWidth(100, 200, 100, 1.0, 1920);
    // pad=16, gap=20: half=16+100+20=136, want=200+272=472
    try t.expectEqual(@as(f64, 472.0), w);
    try t.expectEqual(@as(f64, 1920.0), fillBarWidth(900, 900, 900, 1.0, 1920));
}

test "panel-core: scroll volume steps 5 percent" {
    const t = std.testing;
    try t.expectEqual(@as(?f64, 0.55), scrollVolumeNext(true, -1, true, -15, 0.5));
    try t.expectEqual(@as(?f64, 0.45), scrollVolumeNext(true, -1, true, 15, 0.5));
    try t.expect(scrollVolumeNext(true, 2, true, -15, 0.5) == null); // over a slot
    try t.expect(scrollVolumeNext(false, -1, true, -15, 0.5) == null);
    try t.expect(scrollVolumeNext(true, -1, false, -15, 0.5) == null);
}

test "panel-core: context hide follows workspaces + reveal window" {
    const t = std.testing;
    var ctx = state_mod.ContextHide{};
    // smart hide: occupied hides, empty reveals
    try t.expect(!contextHideReveal(true, false, false, true, 1, &ctx, 1000, true));
    try t.expect(contextHideReveal(true, false, false, false, 1, &ctx, 1000, false));
    // workspace switch reveals for 2 s even when hidden
    var ctx2 = state_mod.ContextHide{};
    _ = contextHideReveal(false, true, true, true, 1, &ctx2, 0, false);
    try t.expect(contextHideReveal(false, true, true, true, 2, &ctx2, 1000, false));
    try t.expect(!contextHideReveal(false, true, true, true, 2, &ctx2, 5000, false));
}

test "panel-core: dispatch covers every branch" {
    const t = std.testing;
    try t.expect(dispatchSlotClick(@intFromEnum(SlotKind.overview), Button.left, 0, -1, .none) == .overview_toggle);
    try t.expect(dispatchSlotClick(@intFromEnum(SlotKind.workspaces), Button.middle, 0, -1, .none) == .overview_toggle);
    try t.expect(dispatchSlotClick(@intFromEnum(SlotKind.workspaces), Button.left, 0, -1, .none) == .workspace_pick);
    try t.expect(dispatchSlotClick(@intFromEnum(SlotKind.media), Button.left, 0, 0, .none) == .media_prev);
    try t.expect(dispatchSlotClick(@intFromEnum(SlotKind.media), Button.left, 0, 2, .none) == .media_next);
    try t.expect(dispatchSlotClick(@intFromEnum(SlotKind.media), Button.left, 0, 1, .none) == .media_play_pause);
    try t.expect(dispatchSlotClick(@intFromEnum(SlotKind.media), Button.left, 0, 9, .none) == .media_popup);
    const a = dispatchSlotClick(@intFromEnum(SlotKind.app), Button.left, 42, -1, .none);
    try t.expect(a == .app_activate and a.app_activate == 42);
    try t.expect(dispatchSlotClick(@intFromEnum(SlotKind.settings), Button.left, 0, -1, .none) == .launch_settings);
    const c = dispatchSlotClick(@intFromEnum(SlotKind.clock), Button.left, 0, -1, .none);
    try t.expect(c == .open_popup and c.open_popup == .calendar);
    try t.expect(deadZonePopup(Button.left, "calendar", "none", "none") == .calendar);
    try t.expect(deadZonePopup(Button.left, "none", "none", "none") == null);
    try t.expect(deadZonePopup(0x113, "calendar", "calendar", "calendar") == null);
    try t.expectEqual(@as(i32, 73), trayPopupHeight(&[_]types.PopupItem{ .{ .id = 1 }, .{ .id = -1 }, .{ .id = 2 } }));
}
