const std = @import("std");
const common = @import("common.zig");

// Desktop + Desktop Widgets tabs — Zig port of settings_tab_desktop/* and
// settings_tab_desktop_widgets/* (incl. world_clock_popup geometry).
// Same design: desktop toggle + icon prefs + widget list with per-widget
// enable + world-clock city picker modal.

pub const DesktopModel = struct {
    enabled: bool = true,
    show_icons: bool = true,
    icon_size: i32 = 48,
    grid_spacing: i32 = 12,

    pub fn clampAll(self: *DesktopModel) void {
        self.icon_size = common.clampInt(self.icon_size, 16, 128);
        self.grid_spacing = common.clampInt(self.grid_spacing, 0, 48);
    }
};

pub const WidgetKind = enum {
    clock,
    calendar,
    weather,
    weather_fancy,
    world_clock,
    fetch,
    system_monitor,
    media,
    media_compact,
};

pub const widget_names = [_][]const u8{
    "Clock", "Calendar",       "Weather", "Weather Fancy", "World Clock",
    "Fetch", "System Monitor", "Media",   "Media Compact",
};

pub const DesktopWidgetsModel = struct {
    enabled: [9]bool = .{true} ** 9,

    pub fn setEnabled(self: *DesktopWidgetsModel, kind: WidgetKind, v: bool) void {
        self.enabled[@intFromEnum(kind)] = v;
    }

    pub fn isEnabled(self: *const DesktopWidgetsModel, kind: WidgetKind) bool {
        return self.enabled[@intFromEnum(kind)];
    }

    pub fn enabledCount(self: *const DesktopWidgetsModel) usize {
        var n: usize = 0;
        for (self.enabled) |e| {
            if (e) n += 1;
        }
        return n;
    }
};

pub const world_popup_w: i32 = 420;
pub const world_popup_h: i32 = 480;

test "settings-desktop-tabs: widgets" {
    const t = std.testing;
    var m = DesktopWidgetsModel{};
    try t.expectEqual(@as(usize, 9), m.enabledCount());
    m.setEnabled(.weather, false);
    try t.expect(!m.isEnabled(.weather));
    try t.expectEqual(@as(usize, 8), m.enabledCount());
    try t.expectEqualStrings("Clock", widget_names[@intFromEnum(WidgetKind.clock)]);
}
