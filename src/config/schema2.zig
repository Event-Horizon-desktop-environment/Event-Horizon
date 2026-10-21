const std = @import("std");
const toml = @import("toml.zig");
const decode = @import("decode.zig");
const T = toml.Value.Table;
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

pub const ToastSettings = struct {
    layer_shell_enabled: bool = true,
    position: []const u8 = "top_right",
    margin_px: i32 = 16,
    corner_radius_px: i32 = 12,
    max_width_px: i32 = 420,
    scale_pct: i32 = 100,
};

pub const NotificationRule = struct {
    name: []const u8 = "",
    match: []const u8 = "",
    show_toast: bool = true,
    save_history: bool = true,
    play_sound: bool = false,
    bypass_dnd: bool = false,
    allow_low: bool = true,
    allow_normal: bool = true,
    allow_critical: bool = true,
};

pub const NotificationsSettings = struct {
    dbus_enabled: bool = true,
    do_not_disturb: bool = false,
    output_name: []const u8 = "",
    default_timeout_ms: i32 = 6000,
    toast: ToastSettings = .{},
    rules: []NotificationRule = &.{},
};

pub fn decodeToast(alloc: std.mem.Allocator, t: *const T, s: *ToastSettings) !void {
    if (getBool(t, "enabled")) |v| s.layer_shell_enabled = v;
    if (getBool(t, "layer_shell_enabled")) |v| s.layer_shell_enabled = v;
    try setStr(alloc, t, "position", &s.position);
    setInt(t, "margin_px", &s.margin_px, 8, 64);
    setInt(t, "corner_radius_px", &s.corner_radius_px, 0, 40);
    setInt(t, "max_width_px", &s.max_width_px, 200, 900);
    setInt(t, "scale_pct", &s.scale_pct, 50, 200);
}

pub fn decodeNotifications(alloc: std.mem.Allocator, t: *const T, s: *NotificationsSettings) !void {
    if (getBool(t, "dbus")) |v| s.dbus_enabled = v;
    if (getBool(t, "dbus_enabled")) |v| s.dbus_enabled = v;
    setBool(t, "do_not_disturb", &s.do_not_disturb);
    if (getStr(t, "output")) |v| s.output_name = try alloc.dupe(u8, std.mem.trim(u8, v, " \t\n"));
    setInt(t, "default_timeout_ms", &s.default_timeout_ms, 1000, 600000);
    if (childTbl(t, "toast")) |tt| try decodeToast(alloc, tt, &s.toast);
    if (childTbl(t, "rules")) |rt| {
        var it = rt.iterator();
        var out: std.ArrayList(NotificationRule) = .empty;
        errdefer out.deinit(alloc);
        while (it.next()) |e| {
            if (e.value_ptr.* != .table) continue;
            const st = &e.value_ptr.table;
            const match = getStr(st, "match") orelse "";
            if (match.len == 0) continue;
            var r = NotificationRule{ .name = try alloc.dupe(u8, e.key_ptr.*), .match = try alloc.dupe(u8, match) };
            if (getBool(st, "show_toast")) |v| r.show_toast = v;
            if (getBool(st, "save_history")) |v| r.save_history = v;
            if (getBool(st, "play_sound")) |v| r.play_sound = v;
            if (getBool(st, "bypass_dnd")) |v| r.bypass_dnd = v;
            if (st.get("allowed_urgencies")) |av| {
                r.allow_low = false;
                r.allow_normal = false;
                r.allow_critical = false;
                if (av == .array) {
                    for (av.array) |item| {
                        if (item != .string) continue;
                        var lb: [16]u8 = undefined;
                        const low = std.ascii.lowerString(lb[0..@min(item.string.len, 16)], item.string[0..@min(item.string.len, 16)]);
                        if (std.mem.eql(u8, low, "low")) r.allow_low = true;
                        if (std.mem.eql(u8, low, "normal")) r.allow_normal = true;
                        if (std.mem.eql(u8, low, "critical")) r.allow_critical = true;
                    }
                }
            }
            try out.append(alloc, r);
        }
        s.rules = try out.toOwnedSlice(alloc);
    }
}

pub const DefaultApps = struct {
    web: []const u8 = "",
    mail: []const u8 = "",
    calendar: []const u8 = "",
    file_manager: []const u8 = "",
    terminal: []const u8 = "",
    music: []const u8 = "",
    video: []const u8 = "",
    images: []const u8 = "",
    pdf: []const u8 = "",
};

pub fn decodeDefaultApps(alloc: std.mem.Allocator, t: *const T, s: *DefaultApps) !void {
    inline for (.{ "web", "mail", "calendar", "file_manager", "terminal", "music", "video", "images", "pdf" }) |k| {
        if (getStr(t, k)) |v| @field(s.*, k) = try alloc.dupe(u8, std.mem.trim(u8, v, " \t\n"));
    }
}

pub const TimeSettings = struct {
    use_24h: bool = false,
    show_seconds: bool = false,
    show_date: bool = true,
    date_format: i32 = 0,
    custom_format: []const u8 = "",
    timezone: []const u8 = "",
};

pub fn decodeTime(alloc: std.mem.Allocator, t: *const T, s: *TimeSettings) !void {
    setBool(t, "use_24h", &s.use_24h);
    setBool(t, "show_seconds", &s.show_seconds);
    setBool(t, "show_date", &s.show_date);
    setInt(t, "date_format", &s.date_format, 0, 3);
    try setStr(alloc, t, "custom_format", &s.custom_format);
    try setStr(alloc, t, "timezone", &s.timezone);
}

pub const TaskflipSettings = struct {
    gallery_style: bool = true,
    mru_order: bool = true,
    show_caption: bool = true,
    show_count: bool = true,
    show_icons: bool = true,
};

pub fn decodeTaskflip(t: *const T, s: *TaskflipSettings) !void {
    setBool(t, "gallery_style", &s.gallery_style);
    setBool(t, "mru_order", &s.mru_order);
    setBool(t, "show_caption", &s.show_caption);
    setBool(t, "show_count", &s.show_count);
    setBool(t, "show_icons", &s.show_icons);
}

pub const KeyboardSettings = struct {
    layout: []const u8 = "us",
    layouts: [][]const u8 = &.{},
    switch_shortcut: i32 = 0,
    show_layout: bool = false,
    numlock: bool = true,
    input_method: bool = false,
    caps_lock_behavior: i32 = 0,
    compose_key: i32 = 0,
    middle_click_paste: bool = true,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
};

pub fn decodeKeyboard(alloc: std.mem.Allocator, t: *const T, s: *KeyboardSettings) !void {
    try setStr(alloc, t, "layout", &s.layout);
    try setStrArray(alloc, t, "layouts", &s.layouts);
    setInt(t, "switch_shortcut", &s.switch_shortcut, 0, 6);
    setBool(t, "show_layout", &s.show_layout);
    setBool(t, "numlock", &s.numlock);
    setBool(t, "input_method", &s.input_method);
    setInt(t, "caps_lock_behavior", &s.caps_lock_behavior, 0, 3);
    setInt(t, "compose_key", &s.compose_key, 0, 4);
    setBool(t, "middle_click_paste", &s.middle_click_paste);
    setInt(t, "repeat_rate", &s.repeat_rate, 15, 50);
    setInt(t, "repeat_delay", &s.repeat_delay, 150, 1000);
    if (s.layouts.len == 0) {
        const one = try alloc.alloc([]const u8, 1);
        one[0] = try alloc.dupe(u8, "us");
        s.layouts = one;
    }
}

pub const PowerSettings = struct {
    display_sleep: bool = true,
    display_sleep_timeout_min: i32 = 10,
    idle_suspend: bool = true,
    idle_suspend_timeout_min: i32 = 30,
    redeye_enabled: bool = false,
    power_button_action: i32 = 0,
    lid_close_action: i32 = 1,
    show_battery_percentage: bool = true,
    tuned_profile: []const u8 = "desktop",
    epp: i32 = 2,
};

pub fn decodePower(alloc: std.mem.Allocator, t: *const T, s: *PowerSettings) !void {
    setBool(t, "display_sleep", &s.display_sleep);
    setInt(t, "display_sleep_timeout", &s.display_sleep_timeout_min, 1, 120);
    setBool(t, "idle_suspend", &s.idle_suspend);
    setInt(t, "idle_suspend_timeout", &s.idle_suspend_timeout_min, 5, 240);
    setBool(t, "redeye_enabled", &s.redeye_enabled);
    setInt(t, "power_button_action", &s.power_button_action, 0, 3);
    setInt(t, "lid_close_action", &s.lid_close_action, 0, 2);
    setBool(t, "show_battery_percentage", &s.show_battery_percentage);
    try setStr(alloc, t, "tuned_profile", &s.tuned_profile);
    setInt(t, "epp", &s.epp, 0, 4);
}

pub const BluetoothSettings = struct {
    auto_reconnect: bool = true,
};

pub const VramBoostSettings = struct {
    enabled: bool = true,
    only_fullscreen: bool = true,
};

pub const NightLightSettings = struct {
    enabled: bool = false,
    day_temperature: i32 = 6500,
    night_temperature: i32 = 4000,
    schedule_mode: i32 = 0,
    schedule_start_min: i32 = 1200,
    schedule_end_min: i32 = 360,
};

pub fn decodeNightLight(t: *const T, s: *NightLightSettings) !void {
    setBool(t, "enabled", &s.enabled);
    setInt(t, "day_temperature", &s.day_temperature, 4000, 6500);
    setInt(t, "night_temperature", &s.night_temperature, 2500, 4000);
    setInt(t, "schedule_mode", &s.schedule_mode, 0, 2);
    setInt(t, "schedule_start_min", &s.schedule_start_min, 0, 1439);
    setInt(t, "schedule_end_min", &s.schedule_end_min, 0, 1439);
}

pub const IdleBehavior = struct {
    name: []const u8 = "",
    timeout_sec: i32 = 0,
    command: []const u8 = "",
    resume_command: []const u8 = "",
    enabled: bool = true,
};

pub fn decodeIdle(alloc: std.mem.Allocator, t: *const T, out: *[]IdleBehavior) !void {
    const bt = childTbl(t, "behavior") orelse return;
    var it = bt.iterator();
    var list: std.ArrayList(IdleBehavior) = .empty;
    errdefer list.deinit(alloc);
    while (it.next()) |e| {
        if (e.value_ptr.* != .table) continue;
        const st = &e.value_ptr.table;
        var b = IdleBehavior{ .name = try alloc.dupe(u8, e.key_ptr.*) };
        setInt(st, "timeout", &b.timeout_sec, 0, std.math.maxInt(i32));
        if (b.timeout_sec <= 0) {
            alloc.free(b.name);
            continue;
        }
        try setStr(alloc, st, "command", &b.command);
        try setStr(alloc, st, "resume_command", &b.resume_command);
        setBool(st, "enabled", &b.enabled);
        try list.append(alloc, b);
    }
    out.* = try list.toOwnedSlice(alloc);
}

pub const AudioSettings = struct {
    default_sink_name: []const u8 = "",
    default_source_name: []const u8 = "",
    default_sink_volume_pct: i32 = 100,
    default_sink_muted: bool = false,
    default_source_volume_pct: i32 = 100,
    default_source_muted: bool = false,
    engine_clock_rate_hz: i32 = 48000,
    engine_force_rate_hz: i32 = 0,
    engine_allowed_rates_hz: []i32 = &.{},
    engine_quantum: i32 = 0,
    engine_force_quantum: i32 = 0,
    compat_pcm_format: i32 = 0,
    allow_over_amplification: bool = false,
};

pub fn decodeAudio(alloc: std.mem.Allocator, t: *const T, s: *AudioSettings) !void {
    try setStr(alloc, t, "default_sink_name", &s.default_sink_name);
    try setStr(alloc, t, "default_source_name", &s.default_source_name);
    setInt(t, "default_sink_volume_pct", &s.default_sink_volume_pct, 0, 150);
    setBool(t, "default_sink_muted", &s.default_sink_muted);
    setInt(t, "default_source_volume_pct", &s.default_source_volume_pct, 0, 150);
    setBool(t, "default_source_muted", &s.default_source_muted);
    setInt(t, "engine_clock_rate_hz", &s.engine_clock_rate_hz, 0, 384000);
    setInt(t, "engine_force_rate_hz", &s.engine_force_rate_hz, 0, 384000);
    if (t.get("engine_allowed_rates_hz")) |v| {
        if (v == .array) {
            var out: std.ArrayList(i32) = .empty;
            errdefer out.deinit(alloc);
            for (v.array) |item| {
                if (item != .integer) continue;
                try out.append(alloc, @intCast(item.integer));
            }
            s.engine_allowed_rates_hz = try out.toOwnedSlice(alloc);
        }
    }
    setInt(t, "engine_quantum", &s.engine_quantum, 0, 65536);
    setInt(t, "engine_force_quantum", &s.engine_force_quantum, 0, 65536);
    setInt(t, "compat_pcm_format", &s.compat_pcm_format, 0, 3);
    setBool(t, "allow_over_amplification", &s.allow_over_amplification);
}
