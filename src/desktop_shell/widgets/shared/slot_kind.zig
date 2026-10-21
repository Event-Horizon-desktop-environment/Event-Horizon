//! Slot-kind enumeration shared by the panel, dock and taskbar paint code.
//!
//! The enum is `uint8_t` and the host code compares widget indices
//! against it, so the discriminants are
//! kept in the same order even where Zig's `dock.Kind` spells them
//! differently.

const std = @import("std");

pub const SlotKind = enum(u8) {
    app,
    tray,
    settings,
    spotlight,
    app_menu,
    app_drawer,
    clock,
    weather,
    media,
    control_center,
    workspaces,
    trash,
    volume_mixer,
    separator,
    battery,
    bluetooth,
    vpn,
    layout,
    smenu,
    world_clock,
    overview,
    clipstack,

    /// True for the kinds that represent a launchable application rather
    /// than a widget — the running-dot gate in the dock.
    pub fn isApp(self: SlotKind) bool {
        return self == .app;
    }
};

test "slot-kind: discriminant order is stable" {
    const t = std.testing;
    try t.expectEqual(@as(u8, 0), @intFromEnum(SlotKind.app));
    try t.expectEqual(@as(u8, 8), @intFromEnum(SlotKind.media));
    try t.expectEqual(@as(u8, 12), @intFromEnum(SlotKind.volume_mixer));
    // `layout` sits between `vpn` and `smenu`
    // — and everything after it would be off by one without it.
    try t.expectEqual(@as(u8, 17), @intFromEnum(SlotKind.layout));
    try t.expectEqual(@as(u8, 18), @intFromEnum(SlotKind.smenu));
    try t.expectEqual(@as(u8, 20), @intFromEnum(SlotKind.overview));
    try t.expect(SlotKind.app.isApp());
    try t.expect(!SlotKind.clock.isApp());
    try t.expectEqualStrings("control_center", @tagName(SlotKind.control_center));
}
