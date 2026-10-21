//! PearCenter compact widget settings. Pear is a fully separated
//! widget: these keys live on the `pear_center` instance (never shared with
//! the legacy control-center), and absent keys fall back to the defaults
//! below so existing installs are unaffected.

const std = @import("std");
const schema = @import("../../config/schema.zig");
const wset = @import("../widgets/shared/widget_settings.zig");

pub const Config = struct {
    /// Compact `scale` (100 = 360 px wide popup).
    scale_pct: i32 = 100,
    transparency: bool = false,
    /// -1 = auto from theme luminance.
    is_dark_theme: i32 = -1,
    main_icon_name: []const u8 = "configure",
    main_icon_height: i32 = 24,
    light_theme: []const u8 = "Light",
    dark_theme: []const u8 = "Dark",
    play_volume_feedback: bool = true,
    show_device_link: bool = false,
    device_link_cmd: []const u8 = "",
    device_link_title: []const u8 = "Device Link",
    device_link_icon: []const u8 = "smartphone",
    show_night_color: bool = true,
    show_color_switcher: bool = true,
    show_dnd: bool = true,
    show_volume: bool = true,
    show_input: bool = true,
    show_brightness: bool = true,
    show_media_player: bool = true,
    show_camera: bool = true,
    camera_cmd: []const u8 = "",
    show_redeye: bool = true,
    show_cmd1: bool = false,
    show_cmd2: bool = false,
    show_percentage: bool = false,
    cmd_run1: []const u8 = "",
    cmd_title1: []const u8 = "Command Button",
    cmd_icon1: []const u8 = "system-run-symbolic",
    cmd_run2: []const u8 = "",
    cmd_title2: []const u8 = "Command Button",
    cmd_icon2: []const u8 = "system-run-symbolic",
};

fn getStr(cfg: *const schema.ShellConfig, id: []const u8, key: []const u8, fb: []const u8) []const u8 {
    const v = wset.widgetSetting(cfg, id, key);
    return if (v.len == 0) fb else v;
}

fn getBool(cfg: *const schema.ShellConfig, id: []const u8, key: []const u8, fb: bool) bool {
    // Accepts `1/true/yes/on` as true and `0/false/no/off` as false.
    const v = wset.widgetSetting(cfg, id, key);
    if (v.len == 0) return fb;
    if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or
        std.mem.eql(u8, v, "yes") or std.mem.eql(u8, v, "on")) return true;
    if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false") or
        std.mem.eql(u8, v, "no") or std.mem.eql(u8, v, "off")) return false;
    return fb;
}

fn getInt(cfg: *const schema.ShellConfig, id: []const u8, key: []const u8, fb: i32) i32 {
    return @intCast(wset.settingInt(cfg, id, key, std.math.minInt(i32), std.math.maxInt(i32), fb));
}

/// `pear_center_config` — values from `[widget.<id>]`, defaults otherwise.
pub fn load(cfg: *const schema.ShellConfig, widget_id: []const u8) Config {
    var c = Config{};
    c.scale_pct = std.math.clamp(getInt(cfg, widget_id, "pear_scale", 100), 50, 200);
    c.transparency = getBool(cfg, widget_id, "pear_transparency", false);
    c.is_dark_theme = getInt(cfg, widget_id, "pear_is_dark_theme", -1);
    c.main_icon_name = getStr(cfg, widget_id, "pear_main_icon", "configure");
    c.main_icon_height = getInt(cfg, widget_id, "pear_main_icon_height", 24);
    c.light_theme = getStr(cfg, widget_id, "pear_light_theme", "Light");
    c.dark_theme = getStr(cfg, widget_id, "pear_dark_theme", "Dark");
    c.play_volume_feedback = getBool(cfg, widget_id, "pear_play_volume_feedback", true);
    c.show_device_link = getBool(cfg, widget_id, "pear_show_device_link", false);
    c.device_link_cmd = getStr(cfg, widget_id, "pear_device_link_cmd", "");
    c.device_link_title = getStr(cfg, widget_id, "pear_device_link_title", "Device Link");
    c.device_link_icon = getStr(cfg, widget_id, "pear_device_link_icon", "smartphone");
    c.show_night_color = getBool(cfg, widget_id, "pear_show_nightcolor", true);
    c.show_color_switcher = getBool(cfg, widget_id, "pear_show_colorswitcher", true);
    c.show_dnd = getBool(cfg, widget_id, "pear_show_dnd", true);
    c.show_volume = getBool(cfg, widget_id, "pear_show_volume", true);
    c.show_input = getBool(cfg, widget_id, "pear_show_input", true);
    c.show_brightness = getBool(cfg, widget_id, "pear_show_brightness", true);
    c.show_media_player = getBool(cfg, widget_id, "pear_show_mediaplayer", true);
    c.show_camera = getBool(cfg, widget_id, "pear_show_camera", true);
    c.camera_cmd = getStr(cfg, widget_id, "pear_camera_cmd", "");
    c.show_redeye = getBool(cfg, widget_id, "pear_show_redeye", true);
    c.show_cmd1 = getBool(cfg, widget_id, "pear_show_cmd1", false);
    c.show_cmd2 = getBool(cfg, widget_id, "pear_show_cmd2", false);
    c.show_percentage = getBool(cfg, widget_id, "pear_show_percentage", false);
    c.cmd_run1 = getStr(cfg, widget_id, "pear_cmd1_run", "");
    c.cmd_title1 = getStr(cfg, widget_id, "pear_cmd1_title", "Command Button");
    c.cmd_icon1 = getStr(cfg, widget_id, "pear_cmd1_icon", "system-run-symbolic");
    c.cmd_run2 = getStr(cfg, widget_id, "pear_cmd2_run", "");
    c.cmd_title2 = getStr(cfg, widget_id, "pear_cmd2_title", "Command Button");
    c.cmd_icon2 = getStr(cfg, widget_id, "pear_cmd2_icon", "system-run-symbolic");
    return c;
}

/// `pear_center_scale` — 100% → 1.0.
pub fn scaleOf(c: Config) f64 {
    return @as(f64, @floatFromInt(c.scale_pct)) * 0.01;
}

test "pear-config: defaults match the specified values" {
    const t = std.testing;
    const c = Config{};
    try t.expectEqual(@as(i32, 100), c.scale_pct);
    try t.expect(!c.show_device_link);
    try t.expect(c.show_night_color and c.show_dnd and c.show_volume);
    try t.expect(!c.show_cmd1 and !c.show_cmd2);
    try t.expectEqual(@as(f64, 1.0), scaleOf(c));
}

test "pear-config: load clamps scale and reads flags" {
    const t = std.testing;
    var cfg = try schema.loadText(t.allocator,
        \\[widget.pear_center]
        \\pear_scale = 300
        \\pear_show_dnd = "0"
        \\pear_show_cmd1 = "1"
        \\pear_cmd1_run = "xterm"
    );
    defer cfg.deinit();
    const c = load(&cfg.cfg, "pear_center");
    try t.expectEqual(@as(i32, 200), c.scale_pct);
    try t.expect(!c.show_dnd);
    try t.expect(c.show_cmd1);
    try t.expectEqualStrings("xterm", c.cmd_run1);
    // Unknown widget id: all defaults.
    const d = load(&cfg.cfg, "nope");
    try t.expectEqual(@as(i32, 100), d.scale_pct);
    try t.expect(d.show_dnd);
}
