//! The pear slot: one pill with the quick-settings status glyphs. Pear is
//! fully separated from the legacy control-center, so this is standalone
//! code (not an import of `controlcenter/slot.zig`) — same widget settings
//! (`show_network/show_audio/show_mic/show_bluetooth`), same glyph choices
//! and tints for a single pill shared by both widget types.

const std = @import("std");
const schema = @import("../../config/schema.zig");
const dock_widgets = @import("../dock/widgets.zig");
const tokens = @import("../../m3/tokens.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const widget_pill = @import("../widgets/shared/pill.zig");
const pear_glyphs = @import("glyphs.zig");

pub const Cfg = struct {
    show_net: bool = true,
    show_audio: bool = true,
    show_mic: bool = true,
    show_bt: bool = true,
};

/// Backend snapshot the pill reads. The dock fills this from the same live
/// caches as the legacy pill; defaults are neutral.
pub const Runtime = struct {
    net_up: bool = false,
    net_wifi: bool = false,
    bt_connected: bool = false,
    bt_powered: bool = false,
    sink_muted: bool = false,
    sink_volume_pct: i32 = 100,
    mic_running: bool = false,
    mic_muted: bool = false,
};

pub fn loadCfg(cfg: *const schema.ShellConfig, instance_id: []const u8) Cfg {
    return .{
        .show_net = dock_widgets.settingBool(cfg, instance_id, "show_network", true),
        .show_audio = dock_widgets.settingBool(cfg, instance_id, "show_audio", true),
        .show_mic = dock_widgets.settingBool(cfg, instance_id, "show_mic", true),
        .show_bt = dock_widgets.settingBool(cfg, instance_id, "show_bluetooth", true),
    };
}

pub fn iconCount(c: Cfg, rt: Runtime) usize {
    var n: usize = 0;
    if (c.show_net) n += 1;
    if (c.show_audio) n += 1;
    if (c.show_mic and rt.mic_running) n += 1;
    if (c.show_bt) n += 1;
    return @max(1, n);
}

/// Same arithmetic as `dock_control_center_slot_width`.
pub fn slotWidth(icon_ref_px: f64, bar_h: f64, n: usize) f64 {
    const s = icon_ref_px / 30.0;
    const hpad = @max(6.0, 8.0 * s);
    const cc_gap = @max(5.0, 6.0 * s);
    const glyph = dock_widgets.clampf(icon_ref_px * 0.45, 12.0, 24.0);
    const nf: f64 = @floatFromInt(n);
    const w = hpad * 2.0 + nf * glyph + @max(0.0, nf - 1.0) * cc_gap;
    return dock_widgets.clampf(w, 48.0, @min(bar_h * 6.5, 240.0));
}

pub const Glyph = struct {
    name: []const u8,
    r: f64,
    g: f64,
    b: f64,
};

pub fn glyphs(c: Cfg, rt: Runtime, buf: *[4]Glyph) []Glyph {
    var n: usize = 0;
    if (c.show_net) {
        const name: []const u8 = if (!rt.net_up) "signal_wifi_off" else if (rt.net_wifi) "wifi" else "lan";
        const accent = std.mem.eql(u8, name, "lan");
        const warn = std.mem.eql(u8, name, "signal_wifi_off");
        buf[n] = .{
            .name = name,
            .r = if (warn) 0.80 else if (accent) 0.90 else 0.93,
            .g = if (warn) 0.28 else if (accent) 0.90 else 0.93,
            .b = if (warn) 0.30 else if (accent) 0.90 else 0.93,
        };
        n += 1;
    }
    if (c.show_audio) {
        const name: []const u8 = if (rt.sink_muted or rt.sink_volume_pct <= 0)
            "volume_off"
        else if (rt.sink_volume_pct < 33)
            "volume_down"
        else
            "volume_up";
        buf[n] = .{ .name = name, .r = 0.93, .g = 0.93, .b = 0.93 };
        n += 1;
    }
    if (c.show_mic and rt.mic_running) {
        const name: []const u8 = if (rt.mic_muted) "mic_off" else "mic";
        const hot = std.mem.eql(u8, name, "mic");
        buf[n] = .{
            .name = name,
            .r = if (hot) 0.92 else 0.93,
            .g = if (hot) 0.22 else 0.93,
            .b = if (hot) 0.24 else 0.93,
        };
        n += 1;
    }
    if (c.show_bt) {
        const name: []const u8 = if (rt.bt_powered) "bluetooth" else "bluetooth_disabled";
        const accent = std.mem.eql(u8, name, "bluetooth");
        const warn = std.mem.eql(u8, name, "bluetooth_disabled");
        buf[n] = .{
            .name = name,
            .r = if (warn) 0.80 else if (accent) 0.90 else 0.93,
            .g = if (warn) 0.28 else if (accent) 0.90 else 0.93,
            .b = if (warn) 0.30 else if (accent) 0.90 else 0.93,
        };
        n += 1;
    }
    if (n == 0) {
        buf[0] = .{ .name = "settings", .r = 0.93, .g = 0.93, .b = 0.93 };
        n = 1;
    }
    return buf[0..n];
}

pub fn signature(c: Cfg, rt: Runtime) i64 {
    var sig: i64 = 0;
    const vals = [_]i64{
        if (c.show_net) 1 else 0,
        if (c.show_audio) 1 else 0,
        if (c.show_mic) 1 else 0,
        if (c.show_bt) 1 else 0,
        if (rt.net_up) 1 else 0,
        if (rt.net_wifi) 1 else 0,
        if (rt.bt_connected) 1 else 0,
        if (rt.bt_powered) 1 else 0,
        if (rt.sink_muted) 1 else 0,
        @as(i64, std.math.clamp(rt.sink_volume_pct, 0, 200)),
        if (rt.mic_running) 1 else 0,
        if (rt.mic_muted) 1 else 0,
    };
    for (vals) |v| sig = sig *% 131 +% v;
    return sig;
}

pub fn signatureChanged(io_sig: *i64, c: Cfg, rt: Runtime) bool {
    const s = signature(c, rt);
    if (s != io_sig.*) {
        io_sig.* = s;
        return true;
    }
    return false;
}

pub fn paintSlot(
    cr: ?*cairo.cairo_t,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    icon_ref_px: f64,
    list: []const Glyph,
    pill_rgb: tokens.Rgb,
    pill_alpha: f64,
) void {
    const c = cr orelse return;
    if (w <= 1.0 or h <= 1.0 or list.len == 0) return;
    // The shared pill shape (shadow + frosted layers), not a flat fill —
    // pear's slot has to sit in the bar looking like every other widget pill.
    widget_pill.paintPillColored(c, x, y, w, h, pill_rgb, pill_alpha);

    const s = icon_ref_px / 30.0;
    const hpad = @max(6.0, 8.0 * s);
    const cc_gap = @max(5.0, 6.0 * s);
    const glyph_px = dock_widgets.clampf(icon_ref_px * 0.45, 12.0, 24.0);
    const cy = y + h * 0.5;
    const run_w = @as(f64, @floatFromInt(list.len)) * glyph_px +
        @as(f64, @floatFromInt(list.len -| 1)) * cc_gap;
    var cx = x + hpad + glyph_px * 0.5 + @max(0.0, (w - 2.0 * hpad - run_w) * 0.5);
    for (list) |g| {
        if (!pear_glyphs.draw(c, g.name, cx, cy, glyph_px, g.r, g.g, g.b)) {
            cairo.cairo_arc(c, cx, cy, glyph_px * 0.28, 0, 6.283185307179586);
            cairo.cairo_set_source_rgba(c, g.r, g.g, g.b, 0.85);
            cairo.cairo_fill(c);
        }
        cx += glyph_px + cc_gap;
    }
}

test "pear-slot: counts, widths and glyphs mirror the shared rules" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 3), iconCount(.{}, .{}));
    try t.expectEqual(@as(usize, 4), iconCount(.{}, .{ .mic_running = true }));
    try t.expectApproxEqAbs(@as(f64, 100.47), slotWidth(44.0, 72.0, 3), 0.05);
    var buf: [4]Glyph = undefined;
    const off = glyphs(.{}, .{}, &buf);
    try t.expectEqualStrings("signal_wifi_off", off[0].name);
    try t.expectEqualStrings("bluetooth_disabled", off[2].name);
    var sig: i64 = 0;
    try t.expect(signatureChanged(&sig, .{}, .{}));
    try t.expect(!signatureChanged(&sig, .{}, .{}));
}
