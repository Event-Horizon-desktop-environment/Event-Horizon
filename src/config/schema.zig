const std = @import("std");
const toml = @import("toml.zig");
const decode = @import("decode.zig");
const T = toml.Value.Table;
const childTbl = decode.childTbl;
const getBool = decode.getBool;
const getStr = decode.getStr;
const getInt = decode.getInt;
const getFloat = decode.getFloat;
const setBool = decode.setBool;
const setInt = decode.setInt;
const setStr = decode.setStr;
const setStrArray = decode.setStrArray;
const s1 = @import("schema1.zig");
const s2 = @import("schema2.zig");
const s3 = @import("schema3.zig");

pub const WidgetInstance = struct {
    /// The `[widget.<id>]` table key. `type` may override the implementation
    /// type, but the id is what the dock's widget lists reference, so it is
    /// kept separately.
    id: []const u8 = "",
    type: []const u8 = "",
    settings: []Setting = &.{},

    pub const Setting = struct {
        key: []const u8,
        value: []const u8,
    };
};

fn upsertWidget(
    alloc: std.mem.Allocator,
    list: *std.ArrayList(WidgetInstance),
    inst: WidgetInstance,
) !void {
    for (list.items) |*existing| {
        if (!std.mem.eql(u8, existing.id, inst.id)) continue;
        // Same id seen again: keep the first settings entry for each key and
        // let later docs contribute only the keys they actually define.
        for (inst.settings) |s| {
            var dup = false;
            for (existing.settings) |es| {
                if (std.mem.eql(u8, es.key, s.key)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            existing.settings = try std.mem.concat(alloc, WidgetInstance.Setting, &.{ existing.settings, &.{s} });
        }
        if (inst.type.len > 0 and !std.mem.eql(u8, inst.type, inst.id)) {
            existing.type = inst.type;
        }
        return;
    }
    try list.append(alloc, inst);
}

fn decodeWidgets(alloc: std.mem.Allocator, t: *const T, out: *[]WidgetInstance) !void {
    var list: std.ArrayList(WidgetInstance) = .empty;
    errdefer list.deinit(alloc);
    var it = t.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .table) continue;
        const st = &e.value_ptr.table;
        const id = try alloc.dupe(u8, e.key_ptr.*);
        var inst = WidgetInstance{
            .id = id,
            // A missing/empty `type` means "the id names the implementation".
            .type = id,
        };
        if (getStr(st, "type")) |ty| {
            if (ty.len > 0) inst.type = try alloc.dupe(u8, ty);
        }
        var sit = st.iterator();
        var sset: std.ArrayList(WidgetInstance.Setting) = .empty;
        errdefer sset.deinit(alloc);
        while (sit.next()) |se| {
            if (std.mem.eql(u8, se.key_ptr.*, "type")) continue;
            const sv = se.value_ptr.*;
            const s: []const u8 = switch (sv) {
                .string => |x| try alloc.dupe(u8, x),
                .boolean => |x| try alloc.dupe(u8, if (x) "true" else "false"),
                .integer => |x| try std.fmt.allocPrint(alloc, "{d}", .{x}),
                .float => |x| try std.fmt.allocPrint(alloc, "{d}", .{x}),
                .array => |arr| blk: {
                    var parts: std.ArrayList(u8) = .empty;
                    errdefer parts.deinit(alloc);
                    for (arr, 0..) |item, k| {
                        if (k > 0) try parts.append(alloc, ',');
                        if (item == .string) try parts.appendSlice(alloc, item.string);
                    }
                    break :blk try parts.toOwnedSlice(alloc);
                },
                .table => continue,
            };
            try sset.append(alloc, .{ .key = try alloc.dupe(u8, se.key_ptr.*), .value = s });
        }
        inst.settings = try sset.toOwnedSlice(alloc);
        try upsertWidget(alloc, &list, inst);
    }
    out.* = try list.toOwnedSlice(alloc);
}

pub const FileBrowser = struct {
    zoom_pct: f64 = 100.0,
    folders_before_files: bool = true,
    surface_opacity_pct: i32 = 100,
    sidebar_opacity_pct: i32 = 100,
    topbar_opacity_pct: i32 = 100,
    statusbar_opacity_pct: i32 = 100,
    preview_opacity_pct: i32 = 100,
    default_terminal: []const u8 = "",
    view_mode: i32 = 0,
    sort_field: i32 = 0,
    sort_descending: bool = false,
    show_hidden: bool = false,
    favorites: [][]const u8 = &.{},
    window_controls_left: bool = false,
};

fn decodeFileBrowser(alloc: std.mem.Allocator, t: *const T, s: *FileBrowser) !void {
    if (getFloat(t, "zoom_pct")) |v| s.zoom_pct = @max(50.0, @min(200.0, v));
    setBool(t, "folders_before_files", &s.folders_before_files);
    setInt(t, "surface_opacity_pct", &s.surface_opacity_pct, 0, 100);
    setInt(t, "sidebar_opacity_pct", &s.sidebar_opacity_pct, 0, 100);
    setInt(t, "topbar_opacity_pct", &s.topbar_opacity_pct, 0, 100);
    setInt(t, "statusbar_opacity_pct", &s.statusbar_opacity_pct, 0, 100);
    setInt(t, "preview_opacity_pct", &s.preview_opacity_pct, 0, 100);
    try setStr(alloc, t, "default_terminal", &s.default_terminal);
    setInt(t, "view_mode", &s.view_mode, 0, 1);
    setInt(t, "sort_field", &s.sort_field, 0, 3);
    setBool(t, "sort_descending", &s.sort_descending);
    setBool(t, "show_hidden", &s.show_hidden);
    try setStrArray(alloc, t, "favorites", &s.favorites);
    setBool(t, "window_controls_left", &s.window_controls_left);
}

pub const ShellConfig = struct {
    renderer: Renderer = .vulkan,
    dock: s1.DockSettings = .{},
    dashboard: s1.DashboardConfig = .{},
    appearance: s3.Appearance = .{},
    wallpaper_enabled: bool = false,
    wallpaper_mode: i32 = 0,
    wallpaper_image: []const u8 = "",
    wallpaper_folder: []const u8 = "",
    wallpaper_video_player_cmd: []const u8 = "",
    bing_enabled: bool = false,
    bing_daily_enabled: bool = false,
    bing_download_path: []const u8 = "",
    bing_filter: i32 = 0,
    bing_blocked_keywords: []const u8 = "",
    wallpaper_folder_picker_mode: i32 = 0,
    mpris_blacklist: []const u8 = "",
    mpris_preferred: []const u8 = "",
    mpris_now_playing_notify: bool = true,
    night_light: s2.NightLightSettings = .{},
    notifications: s2.NotificationsSettings = .{},
    taskbar: s1.TaskbarSettings = .{},
    desktop_enabled: bool = true,
    desktop_output_name: []const u8 = "",
    desktop_widgets_output_name: []const u8 = "",
    plasma_theme: []const u8 = "",
    widgets: []WidgetInstance = &.{},
    default_apps: s2.DefaultApps = .{},
    time: s2.TimeSettings = .{},
    taskflip: s2.TaskflipSettings = .{},
    idle_behaviors: []s2.IdleBehavior = &.{},
    keyboard: s2.KeyboardSettings = .{},
    power: s2.PowerSettings = .{},
    bluetooth: s2.BluetoothSettings = .{},
    vram_boost: s2.VramBoostSettings = .{},
    audio: s2.AudioSettings = .{},
    file_browser: FileBrowser = .{},
    avatar_path: []const u8 = "",
    autostart_enabled: bool = true,

    pub const Renderer = enum { vulkan, cairo };

    pub fn initDefault(alloc: std.mem.Allocator) !ShellConfig {
        var c = ShellConfig{};
        c.notifications.toast.position = try alloc.dupe(u8, "top_right");
        c.keyboard.layout = try alloc.dupe(u8, "us");
        const one = try alloc.alloc([]const u8, 1);
        one[0] = try alloc.dupe(u8, "us");
        c.keyboard.layouts = one;
        c.power.tuned_profile = try alloc.dupe(u8, "desktop");
        c.appearance.font_family = try alloc.dupe(u8, "Inter");
        c.appearance.matugen_scheme = try alloc.dupe(u8, "scheme-content");
        c.appearance.matugen_mode = try alloc.dupe(u8, "dark");
        return c;
    }
};

pub const Loaded = struct {
    arena: *std.heap.ArenaAllocator,
    cfg: ShellConfig,

    pub fn deinit(self: *Loaded) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }
};

pub fn loadText(alloc: std.mem.Allocator, text: []const u8) !Loaded {
    var doc = try toml.parse(alloc, text);
    defer doc.deinit();
    return loadRoot(alloc, &doc.root);
}

/// Decodes one (already deep-merged) TOML root into a fresh `Loaded`.
///
/// `root` is only read here; everything the returned `cfg` references is duped
/// into the `Loaded` arena, so callers may free the source documents as soon as
/// this returns.
pub fn loadRoot(alloc: std.mem.Allocator, root: *const T) !Loaded {
    const arena = try alloc.create(std.heap.ArenaAllocator);
    errdefer alloc.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var cfg = try ShellConfig.initDefault(aa);

    if (childTbl(root, "general")) |g| {
        if (getStr(g, "icon_theme")) |v| cfg.dock.icon_theme = try aa.dupe(u8, v);
        if (getStr(g, "avatar_path")) |v| {
            if (v.len > 0) cfg.avatar_path = try aa.dupe(u8, v);
        }
    }
    if (childTbl(root, "shell")) |sh| {
        if (getStr(sh, "renderer")) |v| cfg.renderer = parseRenderer(v);
        if (getStr(sh, "font_family")) |v| {
            aa.free(cfg.appearance.font_family);
            cfg.appearance.font_family = try aa.dupe(u8, v);
        }
        if (getFloat(sh, "ui_scale")) |d| {
            if (std.math.isFinite(d)) cfg.dock.shell_ui_scale = @max(0.5, @min(2.0, d));
        } else if (getInt(sh, "ui_scale")) |i| {
            cfg.dock.shell_ui_scale = @max(0.5, @min(2.0, @as(f64, @floatFromInt(i))));
        }
    }
    if (childTbl(root, "dock")) |t| try s1.decodeDock(aa, t, &cfg.dock);
    if (childTbl(root, "taskbar")) |t| try s1.decodeTaskbar(aa, t, &cfg.taskbar);
    if (childTbl(root, "dashboard")) |t| try s1.decodeDashboard(aa, t, &cfg.dashboard);
    if (childTbl(root, "desktop")) |t| {
        setBool(t, "enabled", &cfg.desktop_enabled);
        if (getStr(t, "output")) |v| cfg.desktop_output_name = try aa.dupe(u8, std.mem.trim(u8, v, " \t\n"));
    }
    if (childTbl(root, "autostart")) |t| setBool(t, "enabled", &cfg.autostart_enabled);
    if (childTbl(root, "wallpaper")) |t| {
        setBool(t, "enabled", &cfg.wallpaper_enabled);
        setInt(t, "mode", &cfg.wallpaper_mode, 0, 4);
        try setStr(aa, t, "image", &cfg.wallpaper_image);
        try setStr(aa, t, "folder", &cfg.wallpaper_folder);
        try setStr(aa, t, "player_cmd", &cfg.wallpaper_video_player_cmd);
        setBool(t, "bing_enabled", &cfg.bing_enabled);
        setBool(t, "bing_daily_enabled", &cfg.bing_daily_enabled);
        try setStr(aa, t, "bing_download_path", &cfg.bing_download_path);
        setInt(t, "bing_filter", &cfg.bing_filter, 0, 3);
        try setStr(aa, t, "bing_blocked_keywords", &cfg.bing_blocked_keywords);
        setInt(t, "folder_picker_mode", &cfg.wallpaper_folder_picker_mode, 0, 3);
    }
    if (childTbl(root, "mpris")) |t| {
        try setStr(aa, t, "blacklist", &cfg.mpris_blacklist);
        try setStr(aa, t, "preferred", &cfg.mpris_preferred);
        setBool(t, "now_playing_notify", &cfg.mpris_now_playing_notify);
    }
    if (childTbl(root, "notifications")) |t| try s2.decodeNotifications(aa, t, &cfg.notifications);
    if (childTbl(root, "default_apps")) |t| try s2.decodeDefaultApps(aa, t, &cfg.default_apps);
    if (childTbl(root, "time")) |t| try s2.decodeTime(aa, t, &cfg.time);
    if (childTbl(root, "taskflip")) |t| try s2.decodeTaskflip(t, &cfg.taskflip);
    if (childTbl(root, "keyboard")) |t| try s2.decodeKeyboard(aa, t, &cfg.keyboard);
    if (childTbl(root, "power")) |t| try s2.decodePower(aa, t, &cfg.power);
    if (childTbl(root, "bluetooth")) |t| setBool(t, "auto_reconnect", &cfg.bluetooth.auto_reconnect);
    if (childTbl(root, "vram_boost")) |t| {
        setBool(t, "enabled", &cfg.vram_boost.enabled);
        setBool(t, "only_fullscreen", &cfg.vram_boost.only_fullscreen);
    }
    if (childTbl(root, "nightlight")) |t| try s2.decodeNightLight(t, &cfg.night_light);
    if (childTbl(root, "idle")) |t| try s2.decodeIdle(aa, t, &cfg.idle_behaviors);
    if (childTbl(root, "audio")) |t| try s2.decodeAudio(aa, t, &cfg.audio);
    if (childTbl(root, "appearance")) |t| try s3.decodeAppearance(aa, t, &cfg.appearance);
    if (childTbl(root, "widget")) |t| try decodeWidgets(aa, t, &cfg.widgets);
    if (childTbl(root, "filebrowser")) |t| try decodeFileBrowser(aa, t, &cfg.file_browser);
    if (childTbl(root, "file_browser")) |t| try decodeFileBrowser(aa, t, &cfg.file_browser);
    return .{ .arena = arena, .cfg = cfg };
}

pub fn parseRenderer(s: []const u8) ShellConfig.Renderer {
    var lb: [16]u8 = undefined;
    if (s.len > lb.len) return .cairo;
    const low = std.ascii.lowerString(lb[0..s.len], s);
    if (std.mem.eql(u8, low, "gl")) return .vulkan;
    if (std.mem.eql(u8, low, "vulkan") or std.mem.eql(u8, low, "vk")) return .vulkan;
    return .cairo;
}

test "schema: renderer parse accepts known backends" {
    const t = std.testing;
    try t.expectEqual(ShellConfig.Renderer.vulkan, parseRenderer("vulkan"));
    try t.expectEqual(ShellConfig.Renderer.vulkan, parseRenderer("vk"));
    try t.expectEqual(ShellConfig.Renderer.vulkan, parseRenderer("gl"));
    try t.expectEqual(ShellConfig.Renderer.vulkan, parseRenderer("GL"));
    try t.expectEqual(ShellConfig.Renderer.cairo, parseRenderer("cairo"));
    try t.expectEqual(ShellConfig.Renderer.cairo, parseRenderer("bogus"));
}

test "schema: defaults match the specified values" {
    const t = std.testing;
    const cfg = try ShellConfig.initDefault(t.allocator);
    defer {
        t.allocator.free(cfg.notifications.toast.position);
        t.allocator.free(cfg.keyboard.layout);
        t.allocator.free(cfg.keyboard.layouts[0]);
        t.allocator.free(cfg.keyboard.layouts);
        t.allocator.free(cfg.power.tuned_profile);
        t.allocator.free(cfg.appearance.font_family);
        t.allocator.free(cfg.appearance.matugen_scheme);
        t.allocator.free(cfg.appearance.matugen_mode);
    }
    try t.expectEqualStrings("Inter", cfg.appearance.font_family);
    try t.expectEqual(@as(i32, 44), cfg.dock.dock_icon_size);
    try t.expectEqual(@as(i32, 6000), cfg.notifications.default_timeout_ms);
    try t.expectEqual(@as(usize, 10), s1.DashboardConfig.defaultCards().len);
    try t.expect(cfg.taskbar.collapse_when_full);
}

test "schema: full decode with clamps" {
    const t = std.testing;
    var loaded = try loadText(t.allocator,
        \\renderer = "vulkan"
        \\[shell]
        \\renderer = "gl"
        \\ui_scale = 3.0
        \\[dock]
        \\icon_size = 999
        \\icon_spacing = -999
        \\autohide = true
        \\pinned_apps = ["a", "b"]
        \\[notifications]
        \\do_not_disturb = true
        \\[notifications.toast]
        \\position = "bottom_left"
        \\scale_pct = 999
        \\[notifications.rules.work]
        \\match = "x"
        \\play_sound = true
        \\[keyboard]
        \\layouts = ["us", "de"]
        \\repeat_rate = 999
        \\[appearance]
        \\matugen_theming = true
        \\overlay_opacity_master = 42
        \\launchpad_grid_columns = 99
        \\color_theme_enabled = true
        \\color_theme_primary_r = 0.5
        \\[appearance.matugen_templates]
        \\firefox = false
        \\[dashboard]
        \\widgets = ["clock:2", "media"]
        \\[widget.tray]
        \\type = "system_tray"
        \\foo = "bar"
        \\[audio]
        \\engine_allowed_rates_hz = [44100, 48000]
        \\
    );
    defer loaded.deinit();
    const c = loaded.cfg;
    try t.expectEqual(ShellConfig.Renderer.vulkan, c.renderer);
    try t.expectEqual(@as(f64, 2.0), c.dock.shell_ui_scale);
    try t.expectEqual(@as(i32, 50), c.dock.dock_icon_size);
    try t.expectEqual(@as(i32, -50), c.dock.dock_icon_spacing);
    try t.expect(c.dock.dock_autohide);
    try t.expectEqual(@as(usize, 2), c.dock.pinned_apps.len);
    try t.expect(c.notifications.do_not_disturb);
    try t.expectEqualStrings("bottom_left", c.notifications.toast.position);
    try t.expectEqual(@as(i32, 200), c.notifications.toast.scale_pct);
    try t.expectEqual(@as(usize, 1), c.notifications.rules.len);
    try t.expect(c.notifications.rules[0].play_sound);
    try t.expectEqual(@as(usize, 2), c.keyboard.layouts.len);
    try t.expectEqual(@as(i32, 50), c.keyboard.repeat_rate);
    try t.expect(c.appearance.matugen_theming);
    try t.expectEqual(@as(f32, 0.42), c.appearance.overlay_opacity_master);
    try t.expectEqual(@as(i32, 12), c.appearance.launchpad_grid_columns);
    try t.expect(c.appearance.custom_theme_enabled);
    try t.expectEqual(@as(f32, 0.5), c.appearance.custom_primary[0]);
    try t.expect(!c.appearance.matugen_outputs.firefox);
    try t.expectEqual(@as(usize, 2), c.dashboard.cards.len);
    try t.expectEqual(@as(i32, 2), c.dashboard.cards[0].span);
    try t.expectEqual(@as(usize, 1), c.widgets.len);
    try t.expectEqualStrings("system_tray", c.widgets[0].type);
    try t.expectEqual(@as(usize, 2), c.audio.engine_allowed_rates_hz.len);
}

test "schema: slim dock is independent of island membership" {
    const t = std.testing;
    {
        // Islands no longer force the bar to slim: the key is authoritative.
        var loaded = try loadText(t.allocator,
            \\[dock]
            \\islands = ["media"]
            \\
        );
        defer loaded.deinit();
        try t.expect(!loaded.cfg.dock.dock_slim);
    }
    {
        // An explicit off survives a reload even with a stale island id.
        var loaded = try loadText(t.allocator,
            \\[dock]
            \\slim_dock = false
            \\islands = ["clock"]
            \\
        );
        defer loaded.deinit();
        try t.expect(!loaded.cfg.dock.dock_slim);
    }
    {
        // An explicit on works with or without islands.
        var loaded = try loadText(t.allocator,
            \\[dock]
            \\slim_dock = true
            \\islands = ["media"]
            \\
        );
        defer loaded.deinit();
        try t.expect(loaded.cfg.dock.dock_slim);
    }
    {
        var loaded = try loadText(t.allocator,
            \\[dock]
            \\slim_dock = true
            \\
        );
        defer loaded.deinit();
        try t.expect(loaded.cfg.dock.dock_slim);
    }
    const dflt = s1.DockSettings{};
    try t.expect(!dflt.dock_slim);
}
