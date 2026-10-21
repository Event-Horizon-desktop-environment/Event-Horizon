//! Compact popup: Section A pills (Network,
//! Bluetooth, Settings, DND) + quick-toggles row, Section B slider rows
//! (Volume / Input / Brightness) with device switchers, the media row, and
//! the SectionNetworks overlay. Standalone port: same order, same geometry
//! (from `layout.computeLayout`), same glass treatment. Glyphs resolve
//! through `glyphs.draw` (Lucide first, pear-local primitives second).

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const pear_layout = @import("layout.zig");
const pear_config = @import("config.zig");
const pear_data = @import("data.zig");
const cairo_helpers = @import("../shared/cairo_helpers.zig");
const pear_glyphs = @import("glyphs.zig");
const cc_data = @import("../controlcenter/data.zig");
const chrome = @import("../widgets/shared/chrome_colors.zig");
const overlay = @import("../../config/overlay.zig");
const schema = @import("../../config/schema.zig");

fn rrect(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    cairo_helpers.roundedRect(cr, x, y, w, h, @min(r, 0.5 * @min(w, h)));
}

fn glassCard(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64, ch: chrome.Chrome, ov: f64) void {
    const c = cr orelse return;
    rrect(c, x, y + 2.0, w, h, r);
    cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.22 * ov);
    cairo.cairo_fill(c);
    rrect(c, x, y, w, h, r);
    // Fill `drawerDim`, not `dock_fill` (same frosted body as CC).
    cairo.cairo_set_source_rgba(c, ch.drawer_dim.r, ch.drawer_dim.g, ch.drawer_dim.b, 0.55 * ov);
    cairo.cairo_fill(c);
    cairo.cairo_save(c);
    rrect(c, x, y, w, h, r);
    cairo.cairo_clip(c);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.07 * ov);
    cairo.cairo_rectangle(c, x, y, w, h);
    cairo.cairo_fill(c);
    cairo.cairo_restore(c);
    // Bright inner rim, bottom-weighted, plus the faint outer glow — the
    // glassy outline (`cc_paint_glass_card_mc`, mirrored from CC paint).
    const rim = cairo.cairo_pattern_create_linear(0, y, 0, y + h);
    defer cairo.cairo_pattern_destroy(rim);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 0.0, 1.0, 1.0, 1.0, 0.12 * ov);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 0.5, 1.0, 1.0, 1.0, 0.05 * ov);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 1.0, 1.0, 1.0, 1.0, 0.42 * ov);
    cairo.cairo_set_source(c, rim);
    cairo.cairo_set_line_width(c, 1.0);
    rrect(c, x + 1.0, y + 1.0, @max(1.0, w - 2.0), @max(1.0, h - 2.0), @max(0.0, r - 1.0));
    cairo.cairo_stroke(c);
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.08 * ov);
    cairo.cairo_set_line_width(c, 1.0);
    rrect(c, x + 0.5, y + 0.5, @max(1.0, w - 1.0), @max(1.0, h - 1.0), r);
    cairo.cairo_stroke(c);
}

fn rowBg(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    const c = cr orelse return;
    rrect(c, x, y, w, h, r);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.07);
    cairo.cairo_fill(c);
}

fn selectedBg(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64, ch: chrome.Chrome) void {
    const c = cr orelse return;
    rrect(c, x, y, w, h, r);
    cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, 0.16);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, 0.40);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);
}

fn hoverHl(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64, ch: chrome.Chrome) void {
    const c = cr orelse return;
    rrect(c, x, y, w, h, r);
    cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, 0.18);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, 0.35);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);
}

fn glyph(cr: ?*cairo.cairo_t, name: []const u8, cx: f64, cy: f64, px: f64, r: f64, g: f64, b: f64) void {
    const c = cr orelse return;
    if (pear_glyphs.draw(c, name, cx, cy, px, r, g, b)) return;
    // Fresh path (see CC paint): `arc` stitches from a leftover move_to.
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, cx, cy, px * 0.28, 0, 6.283185307179586);
    cairo.cairo_set_source_rgba(c, r, g, b, 0.9);
    cairo.cairo_fill(c);
}

fn text(cr: ?*cairo.cairo_t, s: []const u8, size: f64, x: f64, y: f64, r: f64, g: f64, b: f64, a: f64) void {
    const c = cr orelse return;
    if (s.len == 0) return;
    cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(c, size);
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    var buf: [256:0]u8 = undefined;
    const n = @min(s.len, 255);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    cairo.cairo_move_to(c, x, y);
    cairo.cairo_show_text(c, @ptrCast(&buf));
}

/// Centred single-line text (toggle labels).
fn textCentred(cr: ?*cairo.cairo_t, s: []const u8, size: f64, cx: f64, y: f64) void {
    const c = cr orelse return;
    if (s.len == 0) return;
    cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(c, size);
    var buf: [128:0]u8 = undefined;
    const n = @min(s.len, 127);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    var te: cairo.cairo_text_extents_t = undefined;
    cairo.cairo_text_extents(c, @ptrCast(&buf), &te);
    cairo.cairo_set_source_rgba(c, 0.93, 0.96, 0.98, 0.95);
    cairo.cairo_move_to(c, cx - te.x_advance * 0.5, y);
    cairo.cairo_show_text(c, @ptrCast(&buf));
}

/// Slider rows painted with
/// `slider_row`): 4 px round-cap track inset half a thumb from each geometry
/// edge, thumb radius 8. (x, y, w, h) is the widget box; hit keeps mapping
/// `t` across the full box.
fn slider(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, t: f64, ch: chrome.Chrome) void {
    const c = cr orelse return;
    if (w <= 0 or h <= 0) return;
    const ts: f64 = 16.0;
    const tl = x + ts * 0.5;
    const tw = @max(0.0, w - ts);
    const cy = y + h * 0.5;
    const tc = tl + std.math.clamp(t, 0.0, 1.0) * tw;
    cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_set_line_width(c, 4.0);
    cairo.cairo_set_source_rgba(c, ch.drawer_dim.r, ch.drawer_dim.g, ch.drawer_dim.b, 0.35);
    cairo.cairo_move_to(c, tl, cy);
    cairo.cairo_line_to(c, tl + tw, cy);
    cairo.cairo_stroke(c);
    if (tc > tl) {
        cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, 0.85);
        cairo.cairo_move_to(c, tl, cy);
        cairo.cairo_line_to(c, tc, cy);
        cairo.cairo_stroke(c);
    }
    cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_BUTT);
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, tc, cy, ts * 0.5, 0, 6.283185307179586);
    cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, 1.0);
    cairo.cairo_fill(c);
    cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_BUTT);
}

/// Hover tags for the main page (the overlay reuses `toggle_idx` for rows).
/// Matches the order `host.zig` assigns in `motion`.
pub const Hov = enum(u8) {
    none = 0,
    network_card = 1,
    bluetooth_card = 2,
    settings_row = 3,
    dnd_card = 4,
    volume_slider = 5,
    volume_mute = 6,
    input_slider = 7,
    input_mute = 8,
    brightness_slider = 9,
    output_device_row = 10,
    input_device_row = 11,
    toggle_card = 12,
    media_prev = 13,
    media_play_pause = 14,
    media_next = 15,
    media_card = 16,
    networks_back = 17,
    wifi_toggle = 18,
    network_row = 19,
    bt_device_row = 20,
};

pub const PaintArgs = struct {
    cfg: *const schema.ShellConfig,
    pear: pear_config.Config,
    overlay: pear_layout.Overlay = .none,
    hover_main: Hov = .none,
    /// Toggle index, device row index, or AP row index depending on context.
    hover_idx: i32 = -1,
    layout: pear_layout.Layout,
    view: pear_data.View,
};

/// Paint the compact popup.
pub fn paint(cr: ?*cairo.cairo_t, popup_w: f64, args: PaintArgs) void {
    const c = cr orelse return;
    const l = args.layout;
    const v = args.view;
    const s = v.snap;
    const ch = chrome.of(args.cfg);
    const us = l.us;
    // Shell vs. inner glass, exactly like the legacy popup (and the C++
    // pear): the shell card takes `overlay_opacity_control_center`, the
    // pills/rows/cards the inner knob (master-gated while Advanced is off).
    // Both are 1.0 at defaults.
    const shell_ov = overlay.scale(&args.cfg.appearance, .control_center);
    const inner_ov = overlay.controlCenterInnerAlpha(&args.cfg.appearance);

    cairo.cairo_save(c);
    rrect(c, 2.0, 3.0, popup_w, l.total_h, 24.0);
    // Scaled like the shell fill: 0% must take the shadow with it.
    cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.22 * shell_ov);
    cairo.cairo_fill(c);
    cairo.cairo_restore(c);
    glassCard(c, 0, 0, popup_w, l.total_h, 24.0, ch, shell_ov);
    cairo.cairo_save(c);
    rrect(c, 0, 0, popup_w, l.total_h, 24.0);
    cairo.cairo_clip(c);

    if (args.overlay != .none) {
        paintOverlay(c, popup_w, args, ch);
        cairo.cairo_restore(c);
        return;
    }

    // ── Section A row 1: Network + Bluetooth pills.
    const net_sub: []const u8 = if (s.net.connected)
        (if (s.net.ssid.len > 0) s.net.ssid else "Connected")
    else
        "Disconnected";
    paintLongButton(c, l.net_x, l.row1_y, l.net_w, l.row1_h, cc_data.netGlyph(s), "Network", net_sub, s.net.connected, ch, us, args.hover_main == .network_card, inner_ov);
    var bt_sub_buf: [64]u8 = undefined;
    paintLongButton(c, l.bt_x, l.row1_y, l.bt_w, l.row1_h, cc_data.btGlyph(s), "Bluetooth", btSubtitle(s, &bt_sub_buf), s.bt.powered, ch, us, args.hover_main == .bluetooth_card, inner_ov);

    // ── Row 2: Settings + Do Not Disturb pills.
    paintLongButton(c, l.set_x, l.row2_y, l.set_w, l.row2_h, "settings", "Settings", "System Settings", false, ch, us, args.hover_main == .settings_row, inner_ov);
    if (l.show_dnd) {
        paintLongButton(c, l.dnd_x, l.row2_y, l.dnd_w, l.row2_h, if (v.dnd_on) "notifications_off" else "notifications", "Do Not Disturb", if (v.dnd_on) "On" else "Off", v.dnd_on, ch, us, args.hover_main == .dnd_card, inner_ov);
    }

    // ── Toggles row.
    for (l.toggles, 0..) |tog, i| {
        paintToggle(c, l, tog, i, args, ch, args.hover_main == .toggle_card and args.hover_idx == @as(i32, @intCast(i)), inner_ov);
    }

    // ── Section B rows.
    if (l.show_volume) {
        paintSliderRow(c, l, l.vol_y, cc_data.outGlyph(s), "Volume", s.out.device_name, cc_data.outPct(s), s.out.muted, args.pear.show_percentage, if (l.out_dev_h > 2.0) 1 else 0, ch, args.hover_main == .volume_slider, args.hover_main == .volume_mute, inner_ov);
    }
    if (l.out_dev_h > 2.0) {
        paintDevicePanel(c, popup_w, l, l.out_dev_y, l.out_dev_h, l.out_dev_rows, "Output device", s.out_devs, ch, args.hover_main == .output_device_row, args.hover_idx, inner_ov);
    }
    if (l.show_input) {
        paintSliderRow(c, l, l.in_y, cc_data.inGlyph(s), "Input", s.in.device_name, cc_data.inPct(s), s.in.muted, args.pear.show_percentage, if (l.in_dev_h > 2.0) 1 else 0, ch, args.hover_main == .input_slider, args.hover_main == .input_mute, inner_ov);
    }
    if (l.in_dev_h > 2.0) {
        paintInDevicePanel(c, popup_w, l, s, ch, args.hover_main == .input_device_row, args.hover_idx, inner_ov);
    }
    if (l.show_brightness) {
        paintSliderRow(c, l, l.bri_y, "brightness_high", "Display Brightness", "", v.brightness_pct, false, args.pear.show_percentage, -1, ch, args.hover_main == .brightness_slider, false, inner_ov);
    }
    if (l.show_media) {
        paintMedia(c, popup_w, l, s, ch, args.hover_main, inner_ov);
    }

    cairo.cairo_restore(c);
}

fn btSubtitle(s: cc_data.Snapshot, buf: []u8) []const u8 {
    if (!s.bt.powered) return "Off";
    for (s.bt_devs) |d| {
        if (d.connected) {
            const name = if (d.alias.len > 0) d.alias else d.address;
            const n = @min(name.len, buf.len);
            @memcpy(buf[0..n], name[0..n]);
            return buf[0..n];
        }
    }
    return "On";
}

fn paintLongButton(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, icon: []const u8, title: []const u8, subtitle: []const u8, active: bool, ch: chrome.Chrome, us: f64, hovered: bool, ov: f64) void {
    const c = cr orelse return;
    glassCard(c, x, y, w, h, 20.0, ch, ov);
    if (hovered) hoverHl(c, x, y, w, h, 20.0, ch);
    const icx = x + 8.0 + 20.0 * us;
    const icy = y + h * 0.5;
    cairo.cairo_save(c);
    rrect(c, icx - 14.0 * us, icy - 14.0 * us, 28.0 * us, 28.0 * us, 10.0 * us);
    cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, if (active) 0.20 else 0.09);
    cairo.cairo_fill(c);
    cairo.cairo_restore(c);
    glyph(c, icon, icx, icy + 1.0, 20.0 * us, if (active) ch.accent.r else 0.65, if (active) ch.accent.g else 0.68, if (active) ch.accent.b else 0.72);
    text(c, title, 13.0 * us, x + (8.0 + 44.0) * us, y + h * 0.5 - 2.0 * us, 0.93, 0.96, 0.98, 0.95);
    var sbuf: [48]u8 = undefined;
    const n = @min(subtitle.len, 40);
    @memcpy(sbuf[0..n], subtitle[0..n]);
    text(c, sbuf[0..n], 11.0 * us, x + (8.0 + 44.0) * us, y + h * 0.5 + 13.0 * us, 0.72, 0.78, 0.82, 0.90);
}

fn paintToggle(cr: ?*cairo.cairo_t, l: pear_layout.Layout, tog: pear_layout.Toggle, idx: usize, args: PaintArgs, ch: chrome.Chrome, hovered: bool, ov: f64) void {
    const us = l.us;
    const x = pear_layout.toggleX(l, idx);
    const v = args.view;
    const pc = args.pear;
    const g: []const u8 = switch (tog) {
        .device_link => if (pc.device_link_icon.len > 0) pc.device_link_icon else "smartphone",
        .night_color => if (v.night_on) "nightlight" else "nightlight_off",
        .color_scheme => if (v.is_dark) "light_mode" else "dark_mode",
        .camera => "photo_camera",
        .redeye => if (v.redeye_on) "visibility" else "visibility_off",
        .cmd1 => if (pc.cmd_icon1.len > 0) pc.cmd_icon1 else "terminal",
        .cmd2 => if (pc.cmd_icon2.len > 0) pc.cmd_icon2 else "terminal",
    };
    const title: []const u8 = switch (tog) {
        .device_link => pc.device_link_title,
        .night_color => "Night Color",
        .color_scheme => "Scheme",
        .camera => "Camera",
        .redeye => "Redeye",
        .cmd1 => pc.cmd_title1,
        .cmd2 => pc.cmd_title2,
    };
    const active = switch (tog) {
        .night_color => v.night_on,
        .redeye => v.redeye_on,
        else => false,
    };
    glassCard(cr, x, l.tog_y, l.tog_w, l.tog_h, 20.0, ch, ov);
    if (hovered) hoverHl(cr, x, l.tog_y, l.tog_w, l.tog_h, 20.0, ch);
    glyph(cr, g, x + l.tog_w * 0.5, l.tog_y + l.tog_h * 0.5 - 8.0 * us, 22.0 * us, if (active) ch.accent.r else 0.80, if (active) ch.accent.g else 0.84, if (active) ch.accent.b else 0.86);
    textCentred(cr, title, @max(10.0, 12.0 * us), x + l.tog_w * 0.5, l.tog_y + l.tog_h - 8.0 * us);
}

fn paintSliderRow(cr: ?*cairo.cairo_t, l: pear_layout.Layout, row_y: f64, icon: []const u8, title: []const u8, subtitle: []const u8, pct: i32, muted: bool, show_pct: bool, chevron: i32, ch: chrome.Chrome, hover_slider: bool, hover_mute: bool, ov: f64) void {
    const c = cr orelse return;
    const us = l.us;
    const w = l.w;
    glassCard(c, l.pad, row_y, w - l.pad * 2.0, pear_layout.slider_row_h * us, 20.0, ch, ov);
    if (hover_slider) hoverHl(c, l.pad, row_y, w - l.pad * 2.0, pear_layout.slider_row_h * us, 20.0, ch);
    const icx = l.pad + pear_layout.row_icon_cx * us;
    const icy = row_y + pear_layout.row_icon_cy * us;
    if (hover_mute) {
        cairo.cairo_new_path(c);
        cairo.cairo_arc(c, icx, icy, pear_layout.row_icon_r * us, 0, 6.283185307179586);
        cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, 0.18);
        cairo.cairo_fill(c);
    }
    glyph(c, icon, icx, icy + 1.0, 20.0 * us, if (muted) 0.65 else ch.accent.r, if (muted) 0.68 else ch.accent.g, if (muted) 0.72 else ch.accent.b);
    text(c, title, 13.0 * us, l.pad + 48.0 * us, row_y + 30.0 * us, 0.93, 0.96, 0.98, 0.95);
    if (subtitle.len > 0) {
        var sbuf: [48]u8 = undefined;
        const n = @min(subtitle.len, 40);
        @memcpy(sbuf[0..n], subtitle[0..n]);
        text(c, sbuf[0..n], 11.0 * us, l.pad + 48.0 * us, row_y + 46.0 * us, 0.72, 0.78, 0.82, 0.92);
    }
    if (chevron >= 0) {
        glyph(c, if (chevron > 0) "expand_less" else "expand_more", w - l.pad - 20.0 * us, row_y + 30.0 * us, 18.0 * us, 0.80, 0.84, 0.86);
    }
    if (show_pct) {
        var pbuf: [16]u8 = undefined;
        const ps = std.fmt.bufPrint(&pbuf, "{d}%", .{pct}) catch "100%";
        cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
        cairo.cairo_set_font_size(c, 12.0 * us);
        var te: cairo.cairo_text_extents_t = undefined;
        var tbuf: [16:0]u8 = undefined;
        @memcpy(tbuf[0..ps.len], ps);
        tbuf[ps.len] = 0;
        cairo.cairo_text_extents(c, @ptrCast(&tbuf), &te);
        cairo.cairo_set_source_rgba(c, 0.72, 0.78, 0.82, 0.92);
        const xoff: f64 = if (chevron >= 0) 40.0 else 12.0;
        cairo.cairo_move_to(c, w - l.pad - xoff * us - te.x_advance, row_y + 30.0 * us);
        cairo.cairo_show_text(c, @ptrCast(&tbuf));
    }
    slider(c, l.pad + pear_layout.row_track_pad_x * us, row_y + pear_layout.row_track_y * us, w - l.pad * 2.0 - pear_layout.row_track_pad_x * 2.0 * us, pear_layout.row_track_h * us, std.math.clamp(@as(f64, @floatFromInt(pct)) / 100.0, 0.0, 1.0), ch);
}

fn paintDevicePanel(cr: ?*cairo.cairo_t, popup_w: f64, l: pear_layout.Layout, py: f64, ph: f64, rows: i32, header: []const u8, devs: []const cc_data.OutputDevice, ch: chrome.Chrome, row_hover: bool, hover_row: i32, ov: f64) void {
    const c = cr orelse return;
    const us = l.us;
    glassCard(c, l.pad, py, popup_w - l.pad * 2.0, ph, 20.0, ch, ov);
    text(c, header, 12.0 * us, l.pad + 12.0 * us, py + 18.0 * us, 0.93, 0.96, 0.98, 1.0);
    var i: i32 = 0;
    while (i < rows and @as(usize, @intCast(i)) < devs.len) : (i += 1) {
        const d = devs[@intCast(i)];
        const ry = pear_layout.devRowY(py, i);
        const hov = row_hover and hover_row == i;
        if (hov) hoverHl(c, l.pad + 10.0 * us, ry + 6.0 * us, popup_w - l.pad * 2.0 - 20.0 * us, 24.0 * us, 12.0, ch) else if (d.is_default) selectedBg(c, l.pad + 10.0 * us, ry + 6.0 * us, popup_w - l.pad * 2.0 - 20.0 * us, 24.0 * us, 12.0, ch) else rowBg(c, l.pad + 10.0 * us, ry + 6.0 * us, popup_w - l.pad * 2.0 - 20.0 * us, 24.0 * us, 12.0);
        glyph(c, if (d.is_default) "radio_checked" else "radio_unchecked", l.pad + 20.0 * us, ry + 18.0 * us, 15.0 * us, ch.accent.r, ch.accent.g, ch.accent.b);
        text(c, d.display_name, 12.0 * us, l.pad + 40.0 * us, ry + 22.0 * us, 0.93, 0.96, 0.98, 1.0);
    }
}

fn paintInDevicePanel(cr: ?*cairo.cairo_t, popup_w: f64, l: pear_layout.Layout, s: cc_data.Snapshot, ch: chrome.Chrome, row_hover: bool, hover_row: i32, ov: f64) void {
    const us = l.us;
    glassCard(cr, l.pad, l.in_dev_y, popup_w - l.pad * 2.0, l.in_dev_h, 20.0, ch, ov);
    text(cr, "Input device", 12.0 * us, l.pad + 12.0 * us, l.in_dev_y + 18.0 * us, 0.93, 0.96, 0.98, 1.0);
    var i: i32 = 0;
    while (i < l.in_dev_rows and @as(usize, @intCast(i)) < s.in_devs.len) : (i += 1) {
        const d = s.in_devs[@intCast(i)];
        const ry = pear_layout.devRowY(l.in_dev_y, i);
        const hov = row_hover and hover_row == i;
        if (hov) hoverHl(cr, l.pad + 10.0 * us, ry + 6.0 * us, popup_w - l.pad * 2.0 - 20.0 * us, 24.0 * us, 12.0, ch) else if (d.is_default) selectedBg(cr, l.pad + 10.0 * us, ry + 6.0 * us, popup_w - l.pad * 2.0 - 20.0 * us, 24.0 * us, 12.0, ch) else rowBg(cr, l.pad + 10.0 * us, ry + 6.0 * us, popup_w - l.pad * 2.0 - 20.0 * us, 24.0 * us, 12.0);
        glyph(cr, if (d.is_default) "radio_checked" else "radio_unchecked", l.pad + 20.0 * us, ry + 18.0 * us, 15.0 * us, ch.accent.r, ch.accent.g, ch.accent.b);
        text(cr, d.display_name, 12.0 * us, l.pad + 40.0 * us, ry + 22.0 * us, 0.93, 0.96, 0.98, 1.0);
    }
}

fn paintMedia(cr: ?*cairo.cairo_t, popup_w: f64, l: pear_layout.Layout, s: cc_data.Snapshot, ch: chrome.Chrome, hov: Hov, ov: f64) void {
    const c = cr orelse return;
    const us = l.us;
    glassCard(c, l.pad, l.media_y, popup_w - l.pad * 2.0, l.media_h, 20.0, ch, ov);
    const m = s.media;
    const art_s = 56.0 * us;
    const art_x = l.pad + 12.0 * us;
    const art_y = l.media_y + (l.media_h - art_s) * 0.5;
    rrect(c, art_x, art_y, art_s, art_s, 12.0 * us);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.07);
    cairo.cairo_fill(c);
    if (m.art_argb.len > 0 and m.art_w > 0 and m.art_h > 0) {
        cairo.cairo_save(c);
        rrect(c, art_x, art_y, art_s, art_s, 12.0 * us);
        cairo.cairo_clip(c);
        const iw: f64 = @floatFromInt(m.art_w);
        const ih: f64 = @floatFromInt(m.art_h);
        const sc = art_s / @max(1.0, @max(iw, ih));
        const surf = cairo.cairo_image_surface_create_for_data(@constCast(m.art_argb.ptr), cairo.CAIRO_FORMAT_ARGB32, m.art_w, m.art_h, m.art_w * 4);
        if (cairo.cairo_surface_status(surf) == cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_translate(c, art_x + (art_s - iw * sc) * 0.5, art_y + (art_s - ih * sc) * 0.5);
            cairo.cairo_scale(c, sc, sc);
            cairo.cairo_set_source_surface(c, surf, 0, 0);
            cairo.cairo_paint(c);
        }
        cairo.cairo_surface_destroy(surf);
        cairo.cairo_restore(c);
    } else {
        glyph(c, "music_note", art_x + art_s * 0.5, art_y + art_s * 0.55, 22.0 * us, 0.88, 0.93, 0.96);
    }
    const text_x = art_x + art_s + 12.0 * us;
    const tt = if (m.active) (if (m.title.len > 0) m.title else "Unknown Media") else "No Media";
    var tbuf: [40]u8 = undefined;
    const tn = @min(tt.len, 32);
    @memcpy(tbuf[0..tn], tt[0..tn]);
    cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_BOLD);
    cairo.cairo_set_font_size(c, 15.0 * us);
    cairo.cairo_set_source_rgba(c, 0.93, 0.96, 0.98, 1.0);
    cairo.cairo_move_to(c, text_x, l.media_y + 34.0 * us);
    // Bold toy text needs its own NUL buffer (text() uses NORMAL weight).
    var bbuf: [40:0]u8 = undefined;
    @memcpy(bbuf[0..tn], tbuf[0..tn]);
    bbuf[tn] = 0;
    cairo.cairo_show_text(c, @ptrCast(&bbuf));
    const at = if (m.active) (if (m.artist.len > 0) m.artist else "Unknown Artist") else "No Media";
    text(c, at, 12.0 * us, text_x, l.media_y + 54.0 * us, 0.72, 0.78, 0.82, 0.92);
    if (m.active) {
        const cy = pear_layout.mediaBtnCy(l);
        paintMediaBtn(c, pear_layout.mediaBtnCx(l, 0), cy, "skip_previous", m.can_go_previous, hov == .media_prev, false, ch, us);
        paintMediaBtn(c, pear_layout.mediaBtnCx(l, 1), cy, if (m.playing) "pause" else "play_arrow", m.can_play_pause, hov == .media_play_pause, true, ch, us);
        paintMediaBtn(c, pear_layout.mediaBtnCx(l, 2), cy, "skip_next", m.can_go_next, hov == .media_next, false, ch, us);
    }
}

fn paintMediaBtn(cr: ?*cairo.cairo_t, cx: f64, cy: f64, icon: []const u8, enabled: bool, hovered: bool, primary: bool, ch: chrome.Chrome, us: f64) void {
    const c = cr orelse return;
    // Fresh path like CC's buttons: the slider rows paint text just above.
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, cx, cy, 14.0 * us, 0, 6.283185307179586);
    if (primary) {
        cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, if (hovered) 0.95 else if (enabled) 0.85 else 0.30);
        cairo.cairo_fill(c);
        glyph(c, icon, cx, cy + 0.5, 18.0 * us, 0.05, 0.05, 0.07);
        return;
    }
    if (hovered) {
        cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, 0.18);
        cairo.cairo_fill(c);
    } else {
        cairo.cairo_set_source_rgba(c, 1, 1, 1, if (enabled) 0.10 else 0.04);
        cairo.cairo_fill(c);
    }
    glyph(c, icon, cx, cy + 0.5, 18.0 * us, 0.88, 0.93, 0.96);
}

fn paintOverlay(cr: ?*cairo.cairo_t, popup_w: f64, args: PaintArgs, ch: chrome.Chrome) void {
    const c = cr orelse return;
    const l = args.layout;
    const s = args.view.snap;
    const us = l.us;
    const hx = l.pad;
    const hy = l.pad;
    glyph(c, "arrow_back", hx + 16.0 * us, hy + 24.0 * us, 20.0 * us, 0.88, 0.93, 0.96);
    if (args.hover_main == .networks_back) hoverHl(c, hx, hy, 32.0 * us, 32.0 * us, 10.0 * us, ch);
    if (args.overlay == .bluetooth) {
        paintBluetoothOverlay(c, popup_w, args, ch);
        return;
    }
    text(c, "Network Connections", 18.0 * us, hx + 44.0 * us, hy + 30.0 * us, 0.93, 0.96, 0.98, 1.0);
    const tgl_x = popup_w - l.pad - 30.0 * us;
    glyph(c, if (s.net.wifi) "check_box" else "check_box_outline_blank", tgl_x + 11.0 * us, hy + 24.0 * us, 22.0 * us, ch.accent.r, ch.accent.g, ch.accent.b);
    if (args.hover_main == .wifi_toggle) hoverHl(c, tgl_x, hy + 6.0 * us, 30.0 * us, 30.0 * us, 8.0, ch);
    if (s.wifi_error.len > 0) {
        text(c, s.wifi_error, 12.0 * us, hx + 12.0 * us, hy + 52.0 * us, 0.86, 0.42, 0.42, 0.92);
    }
    var i: i32 = 0;
    while (i < l.wifi_rows and @as(usize, @intCast(i)) < s.aps.len) : (i += 1) {
        const ap = s.aps[@intCast(i)];
        const ry = hy + pear_layout.net_header_h * us + @as(f64, @floatFromInt(i)) * pear_layout.button_h * us;
        const hov = args.hover_main == .network_row and args.hover_idx == i;
        if (hov) hoverHl(c, l.pad + 10.0 * us, ry + 6.0 * us, popup_w - l.pad * 2.0 - 20.0 * us, 36.0 * us, 14.0, ch) else if (ap.active) selectedBg(c, l.pad + 10.0 * us, ry + 6.0 * us, popup_w - l.pad * 2.0 - 20.0 * us, 36.0 * us, 14.0, ch) else rowBg(c, l.pad + 10.0 * us, ry + 6.0 * us, popup_w - l.pad * 2.0 - 20.0 * us, 36.0 * us, 14.0);
        glyph(c, "wifi", l.pad + 20.0 * us, ry + 24.0 * us, 16.0 * us, if (ap.active) 0.94 else 0.80, if (ap.active) 0.97 else 0.84, if (ap.active) 0.98 else 0.86);
        text(c, if (ap.ssid.len > 0) ap.ssid else "(hidden)", 12.0 * us, l.pad + 42.0 * us, ry + 29.0 * us, 0.93, 0.96, 0.98, 1.0);
        var pct_buf: [16]u8 = undefined;
        const pct = std.fmt.bufPrint(&pct_buf, "{d}%", .{ap.signal_pct}) catch "?";
        text(c, pct, 12.0 * us, popup_w - l.pad - 58.0 * us, ry + 29.0 * us, 0.93, 0.96, 0.98, 1.0);
    }
    if (s.wifi_password_prompt) {
        const py = hy + pear_layout.net_header_h * us + @as(f64, @floatFromInt(l.wifi_rows)) * pear_layout.button_h * us + 8.0 * us;
        rowBg(c, l.pad + 10.0 * us, py, popup_w - l.pad * 2.0 - 20.0 * us, 44.0 * us, 14.0);
        var prompt_buf: [160]u8 = undefined;
        const prompt = if (s.wifi_pending_ssid.len > 0)
            std.fmt.bufPrint(&prompt_buf, "Password for {s}", .{s.wifi_pending_ssid}) catch "Password for Wi-Fi"
        else
            "Password for Wi-Fi";
        text(c, prompt, 12.0 * us, l.pad + 18.0 * us, py + 18.0 * us, 0.86, 0.90, 0.94, 1.0);
        var dots_buf: [129]u8 = undefined;
        const n = @min(s.wifi_password.len, 128);
        @memset(dots_buf[0..n], '*');
        text(c, if (n > 0) dots_buf[0..n] else "…", 12.0 * us, l.pad + 18.0 * us, py + 36.0 * us, 0.86, 0.90, 0.94, 1.0);
    }
}

/// The bluetooth page: the networks page's header band (back arrow, title,
/// right checkbox — which is the *power* here rather than the radio), a scan
/// status line that never overlaps a row, then one row per device with its
/// Connect/Disconnect/Pair pill and, for paired ones, the forget `×`.
fn paintBluetoothOverlay(cr: ?*cairo.cairo_t, popup_w: f64, args: PaintArgs, ch: chrome.Chrome) void {
    const c = cr orelse return;
    const l = args.layout;
    const s = args.view.snap;
    const us = l.us;
    const hx = l.pad;
    const hy = l.pad;
    text(c, "Bluetooth", 18.0 * us, hx + 44.0 * us, hy + 24.0 * us, 0.93, 0.96, 0.98, 1.0);
    const tgl_x = popup_w - l.pad - 30.0 * us;
    glyph(c, if (s.bt.powered) "check_box" else "check_box_outline_blank", tgl_x + 11.0 * us, hy + 22.0 * us, 22.0 * us, ch.accent.r, ch.accent.g, ch.accent.b);
    if (args.hover_main == .wifi_toggle) hoverHl(c, tgl_x, hy + 4.0 * us, 30.0 * us, 30.0 * us, 8.0, ch);
    // One sub-title line inside the 48 px header band (never below it, or it
    // would land on the main page's content when the band is empty): the scan
    // state while devices are listed, the reason they are not when they are not.
    const sub: []const u8 = if (l.bt_rows > 0)
        (if (!s.bt.powered) "Off \xE2\x80\xA2 turn on to scan" else if (s.bt.discovering) "Scanning for devices\xE2\x80\xA6" else "On")
    else if (!s.bt.powered)
        "No devices \xE2\x80\xA2 turn Bluetooth on"
    else if (s.bt.discovering)
        "Scanning\xE2\x80\xA6"
    else
        "No devices found";
    text(c, sub, 11.0 * us, hx + 44.0 * us, hy + 40.0 * us, 0.80, 0.86, 0.92, 0.9);
    var i: i32 = 0;
    while (i < l.bt_rows and @as(usize, @intCast(i)) < s.bt_devs.len) : (i += 1) {
        const d = s.bt_devs[@intCast(i)];
        const r = pear_layout.overlayRow(l, i);
        const hov = args.hover_main == .bt_device_row and args.hover_idx == i;
        if (hov) hoverHl(c, r.row_x, r.row_y, r.row_w, r.row_h, 14.0, ch) else if (d.connected) selectedBg(c, r.row_x, r.row_y, r.row_w, r.row_h, 14.0, ch) else rowBg(c, r.row_x, r.row_y, r.row_w, r.row_h, 14.0);
        glyph(c, "bluetooth", l.pad + 20.0 * us, r.row_y + 18.0 * us, 16.0 * us, if (d.connected) 0.94 else 0.80, if (d.connected) 0.97 else 0.84, if (d.connected) 0.98 else 0.86);
        text(c, if (d.alias.len > 0) d.alias else d.address, 12.0 * us, l.pad + 42.0 * us, r.row_y + 23.0 * us, 0.93, 0.96, 0.98, 1.0);
        const label: []const u8 = if (d.connected) "Disconnect" else if (d.paired) "Connect" else "Pair";
        rrect(c, r.action_x, r.row_y + 6.0 * us, r.action_w, 24.0 * us, 8.0 * us);
        if (d.connected or d.paired) {
            cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, 0.85);
        } else {
            cairo.cairo_set_source_rgba(c, 0.22, 0.22, 0.28, 0.7);
        }
        cairo.cairo_fill(c);
        text(c, label, 10.0 * us, r.action_x + 8.0 * us, r.row_y + 22.0 * us, 0.05, 0.05, 0.07, 1.0);
        if (d.paired) {
            const fx = r.forget_x + r.forget_w * 0.5;
            glyph(c, "close", fx, r.row_y + 18.0 * us, 14.0 * us, 0.80, 0.86, 0.92);
            if (hov) hoverHl(c, r.forget_x, r.row_y + 6.0 * us, r.forget_w, 24.0 * us, 8.0, ch);
        }
    }
}

test "pear-paint: full compact popup renders onto a surface" {
    const t = std.testing;
    var cfg: schema.ShellConfig = .{};
    const pc = pear_config.Config{};
    var tog: [7]pear_layout.Toggle = undefined;
    const l = pear_layout.computeLayout(360, false, false, .none, pc, 1.0, .{}, true, &tog);
    const aps = [_]cc_data.WifiAp{.{ .ssid = "Home", .signal_pct = 80, .active = true }};
    const devs = [_]cc_data.OutputDevice{.{ .display_name = "Speakers", .is_default = true }};
    const snap = cc_data.Snapshot{
        .net = .{ .connected = true, .ethernet = true, .iface = "eth0" },
        .aps = &aps,
        .bt = .{ .powered = true },
        .out = .{ .volume_pct = 80, .device_name = "Speakers" },
        .in = .{ .volume_pct = 60, .device_name = "Mic" },
        .out_devs = &devs,
        .media = .{ .active = true, .title = "Song", .artist = "Band", .playing = true, .can_go_previous = true, .can_go_next = true, .can_play_pause = true },
    };
    const w: i32 = 360;
    const h: i32 = @intFromFloat(@ceil(l.total_h));
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, w, h);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paint(cr, 360, .{ .cfg = &cfg, .pear = pc, .layout = l, .view = .{ .snap = snap, .brightness_pct = 70 } });
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    // Overlay variant renders too.
    var tog2: [7]pear_layout.Toggle = undefined;
    const lo = pear_layout.computeLayout(360, false, false, .network, pc, 1.0, .{ .wifi_aps = 1 }, true, &tog2);
    paint(cr, 360, .{ .cfg = &cfg, .pear = pc, .overlay = .network, .layout = lo, .view = .{ .snap = snap } });
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}
