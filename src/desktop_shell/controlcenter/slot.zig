//! Control-center dock slot: one pill with 3–4 status glyphs (network,
//! audio, mic-while-running, bluetooth) instead of a single app icon.
//!
//! `paint_control_center_slot` + `dock_control_center_slot_width` +
//! `control_center_tick_signature_changed`, with the same widget settings
//! (`show_network/show_audio/show_mic/show_bluetooth`), the same 260 ms
//! runtime cache, the same glyph choices and the same accent/warn/hot-mic
//! tint rules. Drawing goes through the vendored Lucide set
//! (`ux/shared/svg_icons.zig`) because the Material Symbols font is not
//! guaranteed to be installed; an unmapped name falls back to the next
//! glyph so the pill never blanks.

const std = @import("std");
const schema = @import("../../config/schema.zig");
const dock_widgets = @import("../dock/widgets.zig");
const tokens = @import("../../m3/tokens.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const widget_pill = @import("../widgets/shared/pill.zig");
const svg_icons = @import("../../ux/shared/svg_icons.zig");

pub const Cfg = struct {
    show_net: bool = true,
    show_audio: bool = true,
    show_mic: bool = true,
    show_bt: bool = true,
};

/// Live backend snapshot the pill reads. The dock host fills this from
/// NetworkManager / PipeWire / BlueZ; defaults are neutral (nothing up,
/// volume 100 unmuted) so the pill still paints before any service starts
/// — backends start lazily, so defaults must paint cleanly before they do.
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

/// `dock_control_center_slot_width` — verbatim arithmetic.
pub fn slotWidth(icon_ref_px: f64, bar_h: f64, n: usize) f64 {
    const s = icon_ref_px / 30.0;
    const hpad = @max(6.0, 8.0 * s);
    const cc_gap = @max(5.0, 6.0 * s);
    const glyph = dock_widgets.clampf(icon_ref_px * 0.45, 12.0, 24.0);
    const nf: f64 = @floatFromInt(n);
    const w = hpad * 2.0 + nf * glyph + @max(0.0, nf - 1.0) * cc_gap;
    return dock_widgets.clampf(w, 48.0, @min(bar_h * 6.5, 240.0));
}

pub fn slotWidthFor(cfg: *const schema.ShellConfig, instance_id: []const u8, rt: Runtime, icon_ref_px: f64, bar_h: f64) f64 {
    return slotWidth(icon_ref_px, bar_h, iconCount(loadCfg(cfg, instance_id), rt));
}

pub const Glyph = struct {
    name: []const u8,
    r: f64,
    g: f64,
    b: f64,
};

/// Glyph row in paint order, with tint per glyph:
/// `lan`/`bluetooth` take the primary tint, `signal_wifi_off` /
/// `bluetooth_disabled` the warn tint, a live `mic` the hot-mic red, and
/// everything else the surface tint.
pub fn glyphs(c: Cfg, rt: Runtime, buf: *[4]Glyph) []Glyph {
    var n: usize = 0;
    if (c.show_net) {
        const name: []const u8 = if (!rt.net_up) "signal_wifi_off" else if (rt.net_wifi) "wifi" else "lan";
        const accent = std.mem.eql(u8, name, "lan") or std.mem.eql(u8, name, "bluetooth");
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

/// `control_center_tick_signature_changed` — the dock timer skips repaints
/// when nothing the pill shows changed.
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

/// Paint the pill + glyph row into an already-cleared bar. `pill_rgb` /
/// `pill_alpha` are the shared `slot_pill_style` fill the dock passes every
/// widget slot, and the pill itself is the shared `paint_pill` — drop shadow
/// plus frosted layers — so the status pill is indistinguishable from the
/// battery/clock/weather pills beside it rather than a flat lozenge.
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
        // Lucide set first (the Material font is not guaranteed); a missing
        // name keeps the slot's rhythm with a soft dot rather than text.
        if (!svg_icons.draw(c, g.name, cx, cy, glyph_px, g.r, g.g, g.b, 1.0, false)) {
            cairo.cairo_arc(c, cx, cy, glyph_px * 0.28, 0, 6.283185307179586);
            cairo.cairo_set_source_rgba(c, g.r, g.g, g.b, 0.85);
            cairo.cairo_fill(c);
        }
        cx += glyph_px + cc_gap;
    }
}

test "cc-slot: three glyphs by default, four while the mic runs" {
    const t = std.testing;
    const c = Cfg{};
    try t.expectEqual(@as(usize, 3), iconCount(c, .{}));
    try t.expectEqual(@as(usize, 4), iconCount(c, .{ .mic_running = true }));
    try t.expectEqual(@as(usize, 1), iconCount(.{
        .show_net = false,
        .show_audio = false,
        .show_mic = false,
        .show_bt = false,
    }, .{}));
}

test "cc-slot: width matches the specified clamp" {
    const t = std.testing;
    // icon 44, bar 72, 3 glyphs: hpad=11.73, gap=8.8, glyph=19.8 → 100.47.
    const w = slotWidth(44.0, 72.0, 3);
    try t.expectApproxEqAbs(@as(f64, 100.47), w, 0.05);
    try t.expect(slotWidth(44.0, 72.0, 1) >= 48.0);
    try t.expect(slotWidth(44.0, 72.0, 8) <= 240.0);
}

test "cc-slot: glyph choice follows backend state" {
    const t = std.testing;
    var buf: [4]Glyph = undefined;
    const off = glyphs(.{}, .{}, &buf);
    try t.expectEqual(@as(usize, 3), off.len);
    try t.expectEqualStrings("signal_wifi_off", off[0].name);
    try t.expectEqualStrings("volume_up", off[1].name);
    try t.expectEqualStrings("bluetooth_disabled", off[2].name);

    const on = glyphs(.{}, .{
        .net_up = true,
        .net_wifi = false,
        .sink_volume_pct = 10,
        .bt_powered = true,
        .mic_running = true,
        .mic_muted = false,
    }, &buf);
    try t.expectEqual(@as(usize, 4), on.len);
    try t.expectEqualStrings("lan", on[0].name);
    try t.expectEqualStrings("volume_down", on[1].name);
    try t.expectEqualStrings("mic", on[2].name);
    try t.expectEqualStrings("bluetooth", on[3].name);

    const muted = glyphs(.{}, .{ .sink_muted = true, .bt_powered = true }, &buf);
    try t.expectEqualStrings("volume_off", muted[1].name);
}

test "cc-slot: signature moves only when a visible input does" {
    const t = std.testing;
    var sig: i64 = 0;
    try t.expect(signatureChanged(&sig, .{}, .{}));
    try t.expect(!signatureChanged(&sig, .{}, .{}));
    try t.expect(signatureChanged(&sig, .{}, .{ .net_up = true }));
    try t.expect(!signatureChanged(&sig, .{}, .{ .net_up = true }));
}

test "cc-slot: paints onto a surface" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 200, 60);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    var buf: [4]Glyph = undefined;
    const list = glyphs(.{}, .{ .net_up = true, .bt_powered = true }, &buf);
    paintSlot(cr, 4, 8, 120, 44, 44, list, .{ .r = 0.2, .g = 0.2, .b = 0.2 }, 0.5);
    // Degenerate geometry is ignored.
    paintSlot(cr, 0, 0, 0, 0, 44, list, .{ .r = 0, .g = 0, .b = 0 }, 0.5);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}
