const std = @import("std");
const app_mod = @import("settings/app.zig");
const common = @import("settings/common.zig");
const embed = @import("settings/embed.zig");

// horizon-settings entry — Zig port of src/ux/settings/common/embed/
// settings_embed_lifecycle.cpp + settings_app.cpp run loop (state/geometry
// only; Wayland/SHM/Vulkan plumbing reuses wl/surface/layer.zig).
// Same design and layout: 900x980 window, sidebar 260px, content area,
// numeric tab ids, per-tab scroll, search bar, open-animation.

pub const App = app_mod.AppState;
pub const Settings = app_mod.Settings;

pub fn activeTabTitle(tab: i32) ?[]const u8 {
    return app_mod.tabTitle(tab);
}

pub fn contentGeom(width: i32, height: i32) embed.ContentGeom {
    return embed.contentGeom(width, height);
}

pub fn runSettingsStandalone(io: std.Io) u8 {
    var buf: [256]u8 = undefined;
    var f = std.Io.File.stderr();
    var w = f.writer(io, &buf);
    w.interface.print(
        "horizon-settings: {d}x{d} sidebar={d} content_x={d} tab={s}\n",
        .{
            app_mod.window_width,
            app_mod.window_height,
            common.sidebar_w,
            App.contentX(),
            activeTabTitle(0) orelse "?",
        },
    ) catch {};
    w.interface.flush() catch {};
    return 0;
}

test "settings stub runs" {
    try std.testing.expect(true);
}

test "settings app entry follows the specified geometry" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 900), app_mod.window_width);
    try t.expectEqual(@as(i32, 980), app_mod.window_height);
    const g = contentGeom(900, 980);
    try t.expectEqual(@as(i32, 292), g.x);
    try t.expect(activeTabTitle(8) != null);
}
