//! Panel widget registry — port of `panel_kind_for_token`
//! (`src/desktop_shell/panel/paint/panel_paint.cpp:94-117`).
//!
//! Maps a config token to the slot kind the strip paints. Tray detection and
//! `type` overrides resolve through the shared widget-settings helper (the
//! same `widget_implementation_type` the C++ reads), so custom instances keep
//! working without a table update here.

const std = @import("std");
const wset = @import("../widgets/shared/widget_settings.zig");
const schema = @import("../../config/schema.zig");

pub const Kind = enum {
    clock,
    weather,
    media,
    workspaces,
    control_center,
    battery,
    bluetooth,
    layout,
    world_clock,
    volume_mixer,
    vpn,
    overview,
    tray,
    app,
    settings,
    trash,
    smenu,
    app_menu,
    app_drawer,
    spotlight,
    separator,
    spacer,
    unknown,
};

/// `panel_kind_for_token` in the C++ order: tray first, then the `type`
/// mapping, then the literal ids, `spacer`/`separator` as separators, and
/// anything else as a running-app slot.
pub fn kindFromId(cfg: *const schema.ShellConfig, id: []const u8) Kind {
    if (wset.listContainsImpl(cfg, &.{id}, "system_tray")) return .tray;
    if (std.mem.eql(u8, id, "system_tray") or std.mem.eql(u8, id, "tray")) return .tray;
    const impl = wset.implementationType(cfg, id);
    if (std.mem.eql(u8, impl, "clock")) return .clock;
    if (std.mem.eql(u8, impl, "weather")) return .weather;
    if (std.mem.eql(u8, impl, "media")) return .media;
    if (std.mem.eql(u8, impl, "workspaces")) return .workspaces;
    if (std.mem.eql(u8, impl, "control_center")) return .control_center;
    if (std.mem.eql(u8, impl, "battery")) return .battery;
    if (std.mem.eql(u8, impl, "bluetooth")) return .bluetooth;
    if (std.mem.eql(u8, impl, "world_clock")) return .world_clock;
    if (std.mem.eql(u8, impl, "volume_mixer")) return .volume_mixer;
    if (std.mem.eql(u8, impl, "vpn")) return .vpn;
    if (std.mem.eql(u8, impl, "layout")) return .layout;
    if (std.mem.eql(u8, impl, "overview")) return .overview;
    if (std.mem.eql(u8, impl, "smenu")) return .smenu;
    if (std.mem.eql(u8, impl, "trash")) return .trash;
    if (std.mem.eql(u8, impl, "app_drawer")) return .app_drawer;
    if (std.mem.eql(u8, impl, "app_menu")) return .app_menu;
    if (std.mem.eql(u8, id, "settings_button")) return .settings;
    if (std.mem.eql(u8, id, "distro_spotlight")) return .spotlight;
    if (std.mem.eql(u8, id, "spacer") or std.mem.eql(u8, id, "separator")) return .separator;
    if (std.mem.eql(u8, impl, "spacer") or std.mem.eql(u8, impl, "separator")) return .separator;
    return .unknown;
}

/// Plain-id mapping without a config (tests and hosts with no widget table).
/// Repeats the literal arms of `kindFromId` above.
pub fn kindFromPlainId(id: []const u8) Kind {
    if (std.mem.eql(u8, id, "clock")) return .clock;
    if (std.mem.eql(u8, id, "workspaces")) return .workspaces;
    if (std.mem.eql(u8, id, "tray") or std.mem.eql(u8, id, "system_tray")) return .tray;
    if (std.mem.eql(u8, id, "battery")) return .battery;
    if (std.mem.eql(u8, id, "network")) return .control_center;
    if (std.mem.eql(u8, id, "volume")) return .volume_mixer;
    if (std.mem.eql(u8, id, "bluetooth")) return .bluetooth;
    if (std.mem.eql(u8, id, "media")) return .media;
    if (std.mem.eql(u8, id, "weather")) return .weather;
    if (std.mem.eql(u8, id, "world_clock")) return .world_clock;
    if (std.mem.eql(u8, id, "vpn")) return .vpn;
    if (std.mem.eql(u8, id, "layout")) return .layout;
    if (std.mem.eql(u8, id, "overview")) return .overview;
    if (std.mem.eql(u8, id, "control_center")) return .control_center;
    if (std.mem.eql(u8, id, "settings_button")) return .settings;
    if (std.mem.eql(u8, id, "trash")) return .trash;
    if (std.mem.eql(u8, id, "spacer") or std.mem.eql(u8, id, "separator")) return .spacer;
    return .unknown;
}

pub const Slot = struct {
    id: []const u8,
    kind: Kind,
    width: i32 = 0,
};

pub fn resolveSlots(alloc: std.mem.Allocator, ids: []const []const u8, widths: []const i32) ![]Slot {
    var out: std.ArrayList(Slot) = .empty;
    errdefer out.deinit(alloc);
    for (ids, 0..) |id, i| {
        try out.append(alloc, .{
            .id = id,
            .kind = kindFromPlainId(id),
            .width = if (i < widths.len) widths[i] else 0,
        });
    }
    return out.toOwnedSlice(alloc);
}

test "panel-widgets: kind registry" {
    const t = std.testing;
    try t.expectEqual(Kind.clock, kindFromPlainId("clock"));
    try t.expectEqual(Kind.tray, kindFromPlainId("system_tray"));
    try t.expectEqual(Kind.unknown, kindFromPlainId("frobnicator"));
    const slots = try resolveSlots(t.allocator, &[_][]const u8{ "clock", "nope" }, &[_]i32{80});
    defer t.allocator.free(slots);
    try t.expectEqual(Kind.clock, slots[0].kind);
    try t.expectEqual(@as(i32, 80), slots[0].width);
    try t.expectEqual(Kind.unknown, slots[1].kind);
}

test "panel-widgets: full token mapping" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator,
        \\[widget.myclock]
        \\type = "clock"
        \\[widget.mytray]
        \\type = "system_tray"
    );
    defer loaded.deinit();
    const c = &loaded.cfg;
    try t.expectEqual(Kind.clock, kindFromId(c, "myclock"));
    try t.expectEqual(Kind.tray, kindFromId(c, "mytray"));
    try t.expectEqual(Kind.tray, kindFromId(c, "tray"));
    try t.expectEqual(Kind.clock, kindFromId(c, "clock"));
    try t.expectEqual(Kind.weather, kindFromId(c, "weather"));
    try t.expectEqual(Kind.media, kindFromId(c, "media"));
    try t.expectEqual(Kind.workspaces, kindFromId(c, "workspaces"));
    try t.expectEqual(Kind.control_center, kindFromId(c, "control_center"));
    try t.expectEqual(Kind.battery, kindFromId(c, "battery"));
    try t.expectEqual(Kind.bluetooth, kindFromId(c, "bluetooth"));
    try t.expectEqual(Kind.world_clock, kindFromId(c, "world_clock"));
    try t.expectEqual(Kind.volume_mixer, kindFromId(c, "volume_mixer"));
    try t.expectEqual(Kind.vpn, kindFromId(c, "vpn"));
    try t.expectEqual(Kind.layout, kindFromId(c, "layout"));
    try t.expectEqual(Kind.overview, kindFromId(c, "overview"));
    try t.expectEqual(Kind.smenu, kindFromId(c, "smenu"));
    try t.expectEqual(Kind.trash, kindFromId(c, "trash"));
    try t.expectEqual(Kind.app_drawer, kindFromId(c, "app_drawer"));
    try t.expectEqual(Kind.app_menu, kindFromId(c, "app_menu"));
    try t.expectEqual(Kind.settings, kindFromId(c, "settings_button"));
    try t.expectEqual(Kind.spotlight, kindFromId(c, "distro_spotlight"));
    try t.expectEqual(Kind.separator, kindFromId(c, "spacer"));
    try t.expectEqual(Kind.separator, kindFromId(c, "separator"));
    // AppMenu/Smenu/Spotlight/AppDrawer expand but are skipped by the strip
    // builder (panel_paint.cpp:174-176); the mapping itself still resolves.
    try t.expectEqual(Kind.unknown, kindFromId(c, "frobnicator"));
}
