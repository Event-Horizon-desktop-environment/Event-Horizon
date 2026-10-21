//! Panel shared types — port of
//! `src/desktop_shell/panel/layout/panel_types.hpp`.
//!
//! The C++ aliases `PanelTrayItem`/`PanelRunningGroup` to the tray and shared
//! snapshot types; the Zig port keeps only what the panel owns (popup kinds,
//! popup rows, hit rects) and borrows the service types at the call site, so
//! this file has no service imports.

const std = @import("std");

/// `PanelPopupKind` (`panel_types.hpp:15-27`): every popup the bar can open.
/// Values are pinned to the C++ order — they are compared across the
/// press/release toggle-close path (`pressDismissedKind`).
pub const PopupKind = enum(u8) {
    none = 0,
    tray = 1,
    calendar = 2,
    weather = 3,
    volume_mixer = 4,
    control_center = 5,
    vpn = 6,
    battery = 7,
    media_player = 8,
    bluetooth = 9,
    layout = 10,

    pub fn title(self: PopupKind) []const u8 {
        return switch (self) {
            .none => "Panel",
            .tray => "Tray",
            .calendar => "Calendar",
            .weather => "Weather",
            .volume_mixer => "Volume",
            .control_center => "Control Center",
            .vpn => "VPN",
            .battery => "Battery",
            .media_player => "Media",
            .bluetooth => "Bluetooth",
            .layout => "Layout",
        };
    }
};

/// `PanelPopupItem` (`panel_types.hpp:29-33`): one dbusmenu row in the tray
/// popup. `id < 0` is a separator (`panel.cpp:1403`, `1611-1619`).
pub const PopupItem = struct {
    id: i32 = 0,
    label: []const u8 = "",
    enabled: bool = true,

    pub fn isSeparator(self: PopupItem) bool {
        return self.id < 0;
    }
};

/// `PanelWidgetHit` (`panel_types.hpp:39-44`): the rect the painter recorded
/// for one slot. Input picking reads these — paint stays the single source of
/// truth for slot geometry (`panel.hpp:238-242`).
pub const WidgetHit = struct {
    widget_id: []const u8 = "",
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    chosen_serial: u64 = 0,
    slot_kind: u8 = 0,

    pub fn contains(self: WidgetHit, px: f64, py: f64) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
};

/// Index of the hit under `(px, py)`, or -1 (`panel.cpp:100-106`).
pub fn hitIndexAt(hits: []const WidgetHit, px: f64, py: f64) i32 {
    for (hits, 0..) |h, i| {
        if (h.contains(px, py)) return @intCast(i);
    }
    return -1;
}

test "panel-types: popup kind values follow the specified order" {
    const t = std.testing;
    try t.expectEqual(@as(u8, 0), @intFromEnum(PopupKind.none));
    try t.expectEqual(@as(u8, 1), @intFromEnum(PopupKind.tray));
    try t.expectEqual(@as(u8, 10), @intFromEnum(PopupKind.layout));
    try t.expectEqualStrings("Calendar", PopupKind.calendar.title());
}

test "panel-types: hit picking follows paint order" {
    const t = std.testing;
    const hits = [_]WidgetHit{
        .{ .widget_id = "clock", .x = 16, .y = 0, .w = 80, .h = 36 },
        .{ .widget_id = "tray", .x = 96, .y = 0, .w = 44, .h = 36 },
    };
    try t.expectEqual(@as(i32, 0), hitIndexAt(&hits, 20, 18));
    try t.expectEqual(@as(i32, 1), hitIndexAt(&hits, 100, 18));
    try t.expectEqual(@as(i32, -1), hitIndexAt(&hits, 4, 18));
    try t.expect((PopupItem{ .id = -1 }).isSeparator());
    try t.expect(!(PopupItem{ .id = 3 }).isSeparator());
}
