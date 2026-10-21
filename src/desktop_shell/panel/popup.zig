//! Panel popups — port of the popup half of
//! `src/desktop_shell/panel/core/panel.cpp:1145-1670`.
//!
//! Pure: popup sizes per kind, toggle-close, dead-zone mapping, tray row
//! heights, and tooltip text. Surface creation and painting stay in
//! `bin/panel.zig`; everything branchy is pinned here without a compositor.

const std = @import("std");
const types = @import("types.zig");
const core = @import("core.zig");

/// Fixed popup sizes (C++ `panel_open_popup_for_slot` :1247-1432).
pub const Size = struct { w: i32, h: i32 };

pub const calendar_size: Size = .{ .w = 320, .h = 340 };
pub const volume_mixer_size: Size = .{ .w = 300, .h = 440 };
pub const battery_size: Size = .{ .w = 260, .h = 160 };
pub const bluetooth_size: Size = .{ .w = 300, .h = 380 };
pub const tray_size: Size = .{ .w = 280, .h = 360 };
pub const media_size: Size = .{ .w = 360, .h = 200 };
pub const weather_size: Size = .{ .w = 340, .h = 380 };
pub const control_center_size: Size = .{ .w = 360, .h = 620 };
pub const layout_size: Size = .{ .w = 300, .h = 320 };
pub const vpn_size: Size = .{ .w = 320, .h = 300 };

/// Size for a popup kind. Tray with menu rows uses the row-measured height
/// (C++ :1418-1421); control-center clamps to the output below.
pub fn sizeFor(kind: types.PopupKind, tray_items: []const types.PopupItem) Size {
    return switch (kind) {
        .calendar => calendar_size,
        .weather => weather_size,
        .volume_mixer => volume_mixer_size,
        .control_center => control_center_size,
        .vpn => vpn_size,
        .battery => battery_size,
        .media_player => media_size,
        .bluetooth => bluetooth_size,
        .layout => layout_size,
        .tray => if (tray_items.len > 0)
            .{ .w = tray_size.w, .h = core.trayPopupHeight(tray_items) }
        else
            tray_size,
        .none => .{ .w = 0, .h = 0 },
    };
}

/// Which popup a slot kind opens (C++ `panel_open_popup_for_slot`
/// :1247-1447, minus the Wayland open). Null for kinds handled elsewhere
/// (overview toggle, workspaces switch, media transport, app activate,
/// settings launch, trash open).
pub fn popupForSlotKind(slot_kind: u8) ?types.PopupKind {
    const K = core.SlotKind;
    return switch (slot_kind) {
        @intFromEnum(K.clock), @intFromEnum(K.world_clock) => .calendar,
        @intFromEnum(K.control_center) => .control_center,
        @intFromEnum(K.weather) => .weather,
        @intFromEnum(K.volume_mixer) => .volume_mixer,
        @intFromEnum(K.battery) => .battery,
        @intFromEnum(K.bluetooth) => .bluetooth,
        @intFromEnum(K.vpn) => .vpn,
        @intFromEnum(K.layout) => .layout,
        @intFromEnum(K.tray) => .tray,
        else => null,
    };
}

/// Dead-zone popup sizes (C++ `panel_dispatch_dead_zone` :1543-1571).
pub fn deadZoneSize(kind: types.PopupKind) ?Size {
    return switch (kind) {
        .control_center => .{ .w = 360, .h = 620 },
        .calendar => calendar_size,
        .tray => .{ .w = 280, .h = 200 },
        else => null,
    };
}

/// Anchor center-x for a slot hit (C++ :1248).
pub fn anchorXFor(hit: types.WidgetHit) i32 {
    return @intFromFloat(@round(hit.x + hit.w * 0.5));
}

test "panel-popup: every slot kind maps to its popup" {
    const t = std.testing;
    const K = core.SlotKind;
    try t.expectEqual(types.PopupKind.calendar, popupForSlotKind(@intFromEnum(K.clock)).?);
    try t.expectEqual(types.PopupKind.calendar, popupForSlotKind(@intFromEnum(K.world_clock)).?);
    try t.expectEqual(types.PopupKind.control_center, popupForSlotKind(@intFromEnum(K.control_center)).?);
    try t.expectEqual(types.PopupKind.weather, popupForSlotKind(@intFromEnum(K.weather)).?);
    try t.expectEqual(types.PopupKind.volume_mixer, popupForSlotKind(@intFromEnum(K.volume_mixer)).?);
    try t.expectEqual(types.PopupKind.battery, popupForSlotKind(@intFromEnum(K.battery)).?);
    try t.expectEqual(types.PopupKind.bluetooth, popupForSlotKind(@intFromEnum(K.bluetooth)).?);
    try t.expectEqual(types.PopupKind.vpn, popupForSlotKind(@intFromEnum(K.vpn)).?);
    try t.expectEqual(types.PopupKind.layout, popupForSlotKind(@intFromEnum(K.layout)).?);
    try t.expectEqual(types.PopupKind.tray, popupForSlotKind(@intFromEnum(K.tray)).?);
    try t.expect(popupForSlotKind(@intFromEnum(K.app)) == null);
    try t.expect(popupForSlotKind(@intFromEnum(K.media)) == null);
    try t.expect(popupForSlotKind(@intFromEnum(K.workspaces)) == null);
    try t.expect(popupForSlotKind(@intFromEnum(K.overview)) == null);
}

test "panel-popup: sizes match the specified constants" {
    const t = std.testing;
    try t.expectEqual(calendar_size, sizeFor(.calendar, &.{}));
    try t.expectEqual(volume_mixer_size, sizeFor(.volume_mixer, &.{}));
    try t.expectEqual(battery_size, sizeFor(.battery, &.{}));
    const items = [_]types.PopupItem{ .{ .id = 1 }, .{ .id = -1 }, .{ .id = 2 } };
    try t.expectEqual(@as(i32, 73), sizeFor(.tray, &items).h);
    try t.expectEqual(@as(i32, 360), sizeFor(.tray, &.{}).h);
    try t.expectEqual(@as(i32, 140), anchorXFor(.{ .x = 100, .w = 80 }));
}
