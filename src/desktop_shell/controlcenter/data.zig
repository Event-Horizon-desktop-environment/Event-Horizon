//! Control-center live data: the snapshot structs behind every card in
//! the legacy popup (`controlcenter/widgets/*`). Each struct carries the
//! fields its card paints; the
//! dock host fills them from D-Bus / PipeWire / MPRIS / Open-Meteo, and
//! tests construct them by hand.

const std = @import("std");

pub const NetworkState = struct {
    connected: bool = false,
    ethernet: bool = false,
    wifi: bool = false,
    iface: []const u8 = "",
    ssid: []const u8 = "",
    wifi_signal_pct: i32 = -1,
};

pub const WifiAp = struct {
    active: bool = false,
    ssid: []const u8 = "",
    signal_pct: i32 = -1,
    needs_password: bool = true,
};

pub const BluetoothState = struct {
    powered: bool = false,
    connected: bool = false,
    paired_count: i32 = 0,
    battery_pct: i32 = -1,
    /// The adapter's `Discovering` property (an active scan).
    discovering: bool = false,
};

pub const BluetoothDevice = struct {
    address: []const u8 = "",
    alias: []const u8 = "",
    paired: bool = false,
    connected: bool = false,
    kind: []const u8 = "bluetooth",
    /// BlueZ `Battery1.Percentage` for this device, or -1 when it reports
    /// none — the row paints its glyph and `%` off this.
    battery_pct: i32 = -1,
};

pub const AudioOutput = struct {
    muted: bool = false,
    volume_pct: i32 = 0,
    /// Live drag override in 0..1, or negative when idle.
    fill_t_override: f64 = -1.0,
    device_name: []const u8 = "",
};

pub const AudioInput = struct {
    muted: bool = false,
    volume_pct: i32 = 0,
    fill_t_override: f64 = -1.0,
    device_name: []const u8 = "",
};

pub const OutputDevice = struct {
    sink_name: []const u8 = "",
    display_name: []const u8 = "",
    is_default: bool = false,
};

pub const InputDevice = struct {
    source_name: []const u8 = "",
    display_name: []const u8 = "",
    is_default: bool = false,
};

pub const MixerStream = struct {
    sink_input_id: i32 = -1,
    volume_pct: i32 = 0,
    muted: bool = false,
    app_name: []const u8 = "",
    /// Theme icon raster (ARGB32, `icon_w`×`icon_h`) resolved by the dock;
    /// empty when no icon matched (paint draws the gray dot).
    icon_argb: []const u8 = &.{},
    icon_w: i32 = 0,
    icon_h: i32 = 0,
};

pub const MediaState = struct {
    active: bool = false,
    title: []const u8 = "",
    artist: []const u8 = "",
    playing: bool = false,
    can_go_previous: bool = false,
    can_go_next: bool = false,
    can_play_pause: bool = false,
    has_art: bool = false,
    /// Rasterized `file://` art (ARGB32), empty when remote/unavailable.
    art_argb: []const u8 = &.{},
    art_w: i32 = 0,
    art_h: i32 = 0,
};

pub const ForecastDay = struct {
    day: []const u8 = "",
    hi: i32 = 0,
    lo: i32 = 0,
    icon: []const u8 = "cloud",
};

pub const WeatherState = struct {
    available: bool = false,
    location: []const u8 = "",
    temp: i32 = 0,
    feels_like: i32 = 0,
    humidity_pct: i32 = 0,
    wind_kmh: i32 = 0,
    visibility_m: i32 = 0,
    icon: []const u8 = "cloud",
    fahrenheit: bool = false,
    forecast: []const ForecastDay = &.{},
};

/// Everything one popup frame paints. Slices borrow from the host (D-Bus
/// caches, the weather reading, the mixer lists) and must outlive the
/// paint call only.
pub const Snapshot = struct {
    net: NetworkState = .{},
    aps: []const WifiAp = &.{},
    bt: BluetoothState = .{},
    bt_devs: []const BluetoothDevice = &.{},
    out: AudioOutput = .{},
    in: AudioInput = .{},
    out_devs: []const OutputDevice = &.{},
    in_devs: []const InputDevice = &.{},
    out_streams: []const MixerStream = &.{},
    in_streams: []const MixerStream = &.{},
    media: MediaState = .{},
    weather: WeatherState = .{},
    wifi_error: []const u8 = "",
    wifi_password_prompt: bool = false,
    /// SSID awaiting a password + masked password being typed. Owned by the
    /// host arena (see `Host.pw_*`); paint shows bullets, never the text.
    wifi_pending_ssid: []const u8 = "",
    wifi_password: []const u8 = "",
    bt_error: []const u8 = "",
};

pub fn netTitle(s: Snapshot) []const u8 {
    if (s.net.wifi) {
        if (s.net.ssid.len > 0) return s.net.ssid;
        return "Wi-Fi";
    }
    if (s.net.ethernet) return "Ethernet";
    return "Network";
}

pub fn netGlyph(s: Snapshot) []const u8 {
    if (!s.net.connected) return "signal_wifi_off";
    return if (s.net.wifi) "wifi" else "lan";
}

pub fn btGlyph(s: Snapshot) []const u8 {
    return if (s.bt.powered) "bluetooth" else "bluetooth_disabled";
}

pub fn outGlyph(s: Snapshot) []const u8 {
    const pct = if (s.out.fill_t_override >= 0.0 and s.out.fill_t_override <= 1.0)
        @as(i32, @intFromFloat(@round(s.out.fill_t_override * 100.0)))
    else
        s.out.volume_pct;
    if (s.out.muted or pct <= 0) return "volume_off";
    if (pct < 34) return "volume_down";
    return "volume_up";
}

pub fn inGlyph(s: Snapshot) []const u8 {
    return if (s.in.muted) "mic_off" else "mic";
}

pub fn outPct(s: Snapshot) i32 {
    if (s.out.fill_t_override >= 0.0 and s.out.fill_t_override <= 1.0)
        return @as(i32, @intFromFloat(@round(s.out.fill_t_override * 100.0)));
    return s.out.volume_pct;
}

pub fn inPct(s: Snapshot) i32 {
    if (s.in.fill_t_override >= 0.0 and s.in.fill_t_override <= 1.0)
        return @as(i32, @intFromFloat(@round(s.in.fill_t_override * 100.0)));
    return s.in.volume_pct;
}

test "cc-data: titles and glyphs follow connection state" {
    const t = std.testing;
    try t.expectEqualStrings("Network", netTitle(.{}));
    try t.expectEqualStrings("signal_wifi_off", netGlyph(.{}));
    try t.expectEqualStrings("Ethernet", netTitle(.{ .net = .{ .connected = true, .ethernet = true } }));
    try t.expectEqualStrings("lan", netGlyph(.{ .net = .{ .connected = true } }));
    try t.expectEqualStrings("wifi", netGlyph(.{ .net = .{ .connected = true, .wifi = true } }));
    try t.expectEqualStrings("MyWifi", netTitle(.{ .net = .{ .wifi = true, .ssid = "MyWifi" } }));
    try t.expectEqualStrings("bluetooth_disabled", btGlyph(.{}));
    try t.expectEqualStrings("bluetooth", btGlyph(.{ .bt = .{ .powered = true } }));
    try t.expectEqualStrings("volume_off", outGlyph(.{ .out = .{ .muted = true, .volume_pct = 80 } }));
    try t.expectEqualStrings("volume_down", outGlyph(.{ .out = .{ .volume_pct = 10 } }));
    try t.expectEqualStrings("volume_up", outGlyph(.{ .out = .{ .volume_pct = 80 } }));
    try t.expectEqualStrings("mic_off", inGlyph(.{ .in = .{ .muted = true } }));
    try t.expectEqualStrings("mic", inGlyph(.{}));
}
