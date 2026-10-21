const std = @import("std");
const toml = @import("toml.zig");

const T = toml.Value.Table;
const V = toml.Value;

const decode = @import("decode.zig");
const childTbl = decode.childTbl;
const getBool = decode.getBool;
const getStr = decode.getStr;
const getInt = decode.getInt;
const getFloat = decode.getFloat;
const getFloatStrict = decode.getFloatStrict;
const setBool = decode.setBool;
const setInt = decode.setInt;
const setStr = decode.setStr;
const setStrArray = decode.setStrArray;
const setScale = decode.setScale;
const setOpacity = decode.setOpacity;

pub const DockSettings = struct {
    dock_show_dock: bool = true,
    dock_autohide: bool = false,
    dock_radius: i32 = 18,
    dock_icon_size: i32 = 44,
    dock_icon_spacing: i32 = 15,
    dock_bottom_gap: i32 = 6,
    dock_exclusive_zone_gap: i32 = 0,
    dock_border_enabled: bool = false,
    dock_border_size: i32 = 1,
    dock_border_hue: i32 = 200,
    dock_border_opacity: i32 = 100,
    dock_opacity: i32 = 100,
    icon_theme: []const u8 = "",
    pinned_apps: [][]const u8 = &.{},
    drawer_pinned_apps: [][]const u8 = &.{},
    start_menu_pinned_apps: [][]const u8 = &.{},
    left_widgets: [][]const u8 = &.{},
    center_widgets: [][]const u8 = &.{},
    right_widgets: [][]const u8 = &.{},
    /// Widget ids drawn as their own floating pill ("islands") instead of
    /// sharing the dock's single background bar. Each entry is one island
    /// spec: `'media'` (a widget), `'media+clock'` (linked widgets), or a
    /// section tag `@left` / `@center` / `@right` (the whole section).
    /// Empty keeps the classic one-bar look; ids not currently placed are
    /// ignored.
    islands: [][]const u8 = &.{},
    /// Px between two island pills (and between an island and the bar).
    island_gap: i32 = 9,
    output_name: []const u8 = "",
    dock_widgets_enabled: bool = true,
    dock_group_apps: bool = true,
    dock_tooltips_enabled: bool = true,
    dock_pinned_apps_tray_pill: bool = false,
    dock_running_apps_tray_pill: bool = false,
    slot_pill_opacity: i32 = 100,
    dock_liquid_glass: bool = true,
    dock_colored_glass: bool = false,
    /// Tahoe-style icon frames: full-bleed square app icons are rounded
    /// into the bar's squircle with a lifted edge and a specular rim.
    dock_icon_frames: bool = true,
    dock_scale: f64 = 1.0,
    shell_ui_scale: f64 = 1.0,
    dock_bar_follows_icons: bool = true,
    dock_manual_bar_height_px: i32 = 72,
    /// Slim Dock: trim the bar's vertical and side padding for a tighter
    /// strip (icon size and spacing stay user-configured). The settings page
    /// turns this on when an island is enabled, but it remains an
    /// independent preference: an explicit `slim_dock = false` must survive
    /// a reload even while islands are present.
    dock_slim: bool = false,
};

pub fn decodeDock(alloc: std.mem.Allocator, t: *const T, d: *DockSettings) !void {
    setBool(t, "show_dock", &d.dock_show_dock);
    setBool(t, "autohide", &d.dock_autohide);
    setBool(t, "dock_widgets_enabled", &d.dock_widgets_enabled);
    setBool(t, "group_apps", &d.dock_group_apps);
    setBool(t, "dock_tooltips_enabled", &d.dock_tooltips_enabled);
    setBool(t, "dock_pinned_apps_tray_pill", &d.dock_pinned_apps_tray_pill);
    setBool(t, "dock_running_apps_tray_pill", &d.dock_running_apps_tray_pill);
    setInt(t, "radius", &d.dock_radius, 0, 50);
    setInt(t, "icon_size", &d.dock_icon_size, 0, 50);
    setInt(t, "icon_spacing", &d.dock_icon_spacing, -50, 50);
    setInt(t, "bottom_gap", &d.dock_bottom_gap, 0, 25);
    setInt(t, "exclusive_zone_gap", &d.dock_exclusive_zone_gap, 0, 100);
    setBool(t, "border_enabled", &d.dock_border_enabled);
    setInt(t, "border_size", &d.dock_border_size, 0, 12);
    setInt(t, "border_hue", &d.dock_border_hue, 0, 359);
    setInt(t, "border_opacity", &d.dock_border_opacity, 0, 100);
    setInt(t, "opacity", &d.dock_opacity, 0, 100);
    setInt(t, "slot_pill_opacity", &d.slot_pill_opacity, 0, 100);
    setBool(t, "liquid_glass", &d.dock_liquid_glass);
    setBool(t, "colored_glass", &d.dock_colored_glass);
    setBool(t, "icon_frames", &d.dock_icon_frames);
    setScale(t, "scale", &d.dock_scale);
    setBool(t, "bar_follows_icons", &d.dock_bar_follows_icons);
    setInt(t, "manual_bar_height", &d.dock_manual_bar_height_px, 32, 200);
    setBool(t, "slim_dock", &d.dock_slim);
    try setStrArray(alloc, t, "pinned_apps", &d.pinned_apps);
    try setStrArray(alloc, t, "start_menu_pinned_apps", &d.start_menu_pinned_apps);
    try setStrArray(alloc, t, "drawer_pinned_apps", &d.drawer_pinned_apps);
    try setStrArray(alloc, t, "left_widgets", &d.left_widgets);
    try setStrArray(alloc, t, "center_widgets", &d.center_widgets);
    try setStrArray(alloc, t, "right_widgets", &d.right_widgets);
    try setStrArray(alloc, t, "islands", &d.islands);
    setInt(t, "island_gap", &d.island_gap, 0, 40);
    if (getStr(t, "output")) |v| d.output_name = try alloc.dupe(u8, std.mem.trim(u8, v, " \t\n"));
}

pub const TaskbarSettings = struct {
    enabled: bool = false,
    width_mode: i32 = 0,
    height: i32 = 48,
    radius: i32 = 12,
    opacity: i32 = 100,
    icon_size: i32 = 32,
    icon_spacing: i32 = 8,
    floating_amount: i32 = 8,
    edge_gap: i32 = 0,
    exclusive_zone_gap: i32 = 0,
    scale: f64 = 1.0,
    left_widgets: [][]const u8 = &.{},
    center_widgets: [][]const u8 = &.{},
    right_widgets: [][]const u8 = &.{},
    pinned_apps: [][]const u8 = &.{},
    group_apps: bool = true,
    show_labels: bool = false,
    collapse_when_full: bool = true,
    thumbnails_enabled: bool = true,
    thumbnail_peek_enabled: bool = true,
    thumbnail_threshold: i32 = 10,
    compact_media: bool = true,
    position_top: bool = false,
    output_name: []const u8 = "",
    slot_pill_opacity: i32 = 100,
    auto_hide: bool = false,
    tooltips_enabled: bool = true,
    pinned_apps_tray_pill: bool = false,
    running_apps_tray_pill: bool = false,
    widgets_enabled: bool = true,
    border: bool = false,
    border_size: i32 = 1,
    icon_theme: []const u8 = "",
};

pub fn decodeTaskbar(alloc: std.mem.Allocator, t: *const T, s: *TaskbarSettings) !void {
    setBool(t, "enabled", &s.enabled);
    setInt(t, "width_mode", &s.width_mode, 0, 2);
    setInt(t, "height", &s.height, 24, 120);
    setInt(t, "radius", &s.radius, 0, 50);
    setInt(t, "opacity", &s.opacity, 0, 100);
    setInt(t, "icon_size", &s.icon_size, 0, 96);
    setInt(t, "icon_spacing", &s.icon_spacing, 0, 50);
    setInt(t, "floating_amount", &s.floating_amount, 0, 50);
    setInt(t, "edge_gap", &s.edge_gap, 0, 25);
    setInt(t, "exclusive_zone_gap", &s.exclusive_zone_gap, 0, 100);
    setScale(t, "scale", &s.scale);
    try setStrArray(alloc, t, "left_widgets", &s.left_widgets);
    try setStrArray(alloc, t, "center_widgets", &s.center_widgets);
    try setStrArray(alloc, t, "right_widgets", &s.right_widgets);
    try setStrArray(alloc, t, "pinned_apps", &s.pinned_apps);
    setBool(t, "group_apps", &s.group_apps);
    setBool(t, "show_labels", &s.show_labels);
    setBool(t, "collapse_when_full", &s.collapse_when_full);
    setBool(t, "thumbnails", &s.thumbnails_enabled);
    setBool(t, "thumbnail_peek", &s.thumbnail_peek_enabled);
    setInt(t, "thumbnail_threshold", &s.thumbnail_threshold, 3, 20);
    setBool(t, "compact_media", &s.compact_media);
    setBool(t, "position_top", &s.position_top);
    if (getStr(t, "output")) |v| s.output_name = try alloc.dupe(u8, std.mem.trim(u8, v, " \t\n"));
    setInt(t, "slot_pill_opacity", &s.slot_pill_opacity, 0, 100);
    setBool(t, "auto_hide", &s.auto_hide);
    setBool(t, "tooltips", &s.tooltips_enabled);
    setBool(t, "pinned_apps_tray_pill", &s.pinned_apps_tray_pill);
    setBool(t, "running_apps_tray_pill", &s.running_apps_tray_pill);
    setBool(t, "widgets_enabled", &s.widgets_enabled);
    setBool(t, "border", &s.border);
    setInt(t, "border_size", &s.border_size, 1, 12);
    if (getStr(t, "icon_theme")) |v| s.icon_theme = try alloc.dupe(u8, std.mem.trim(u8, v, " \t\n"));
}

pub const DashboardCard = struct {
    id: []const u8 = "",
    span: i32 = 1,
};

pub const DashboardConfig = struct {
    config_version: i32 = 0,
    enabled: bool = true,
    trigger_height: i32 = 8,
    columns: i32 = 4,
    gap: i32 = 12,
    margin_x: i32 = 14,
    margin_top: i32 = 12,
    margin_bottom: i32 = 14,
    max_width: i32 = 0,
    hover_reveal: bool = false,
    cards: []DashboardCard = &.{},

    pub fn defaultCards() []const DashboardCard {
        return &[_]DashboardCard{
            .{ .id = "clock", .span = 1 },    .{ .id = "weather", .span = 1 },
            .{ .id = "calendar", .span = 2 }, .{ .id = "media", .span = 2 },
            .{ .id = "network", .span = 1 },  .{ .id = "bluetooth", .span = 1 },
            .{ .id = "volume", .span = 1 },   .{ .id = "mic", .span = 1 },
            .{ .id = "mixer", .span = 1 },    .{ .id = "system", .span = 1 },
        };
    }
};

pub fn decodeDashboard(alloc: std.mem.Allocator, t: *const T, d: *DashboardConfig) !void {
    setBool(t, "enabled", &d.enabled);
    setInt(t, "config_version", &d.config_version, 0, 99);
    setInt(t, "trigger_height", &d.trigger_height, 4, 48);
    setInt(t, "columns", &d.columns, 1, 8);
    setInt(t, "gap", &d.gap, 0, 48);
    setInt(t, "margin_x", &d.margin_x, 0, 200);
    setInt(t, "margin_top", &d.margin_top, 0, 200);
    setInt(t, "margin_bottom", &d.margin_bottom, 0, 200);
    setInt(t, "max_width", &d.max_width, 0, 7680);
    setBool(t, "hover_reveal", &d.hover_reveal);
    const v = t.get("widgets") orelse return;
    if (v != .array) return;
    var out: std.ArrayList(DashboardCard) = .empty;
    errdefer out.deinit(alloc);
    for (v.array) |item| {
        if (item != .string) continue;
        var tok = std.mem.trim(u8, item.string, " \t");
        if (tok.len == 0) continue;
        var span: i32 = 1;
        if (std.mem.lastIndexOfScalar(u8, tok, ':')) |ci| {
            span = std.fmt.parseInt(i32, std.mem.trim(u8, tok[ci + 1 ..], " \t"), 10) catch continue;
            span = @max(1, @min(8, span));
            tok = std.mem.trim(u8, tok[0..ci], " \t");
            if (tok.len == 0) continue;
        }
        try out.append(alloc, .{ .id = try alloc.dupe(u8, tok), .span = span });
    }
    if (out.items.len == 0) {
        out.deinit(alloc);
        return;
    }
    d.cards = try out.toOwnedSlice(alloc);
}
