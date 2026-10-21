//! Full legacy popup: two top tiles
//! (network + bluetooth), output + input slider cards, the expandable
//! volume mixer, the media card and the weather card.
//!
//! Geometry comes from `layout.computeLayout` (the single source of truth
//! paint *and* hit share); colours come from `chrome.of` + the card helpers
//! below. Text uses the
//! cairo toy API with Inter; glyphs go through the vendored
//! Lucide set with a soft-dot fallback so a missing name never blanks.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const cairo_helpers = @import("../shared/cairo_helpers.zig");
const cc_layout = @import("layout.zig");
const cc_state = @import("state.zig");
const cc_data = @import("data.zig");
const chrome = @import("../widgets/shared/chrome_colors.zig");
const schema = @import("../../config/schema.zig");
const overlay = @import("../../config/overlay.zig");
const svg_icons = @import("../../ux/shared/svg_icons.zig");

pub const accent_lime = struct {
    pub const r: f64 = 0.72;
    pub const g: f64 = 0.90;
    pub const b: f64 = 0.30;
};

fn rrect(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    cairo_helpers.roundedRect(cr, x, y, w, h, @min(r, 0.5 * @min(w, h)));
}

fn glassCard(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64, ch: chrome.Chrome, ov: f64) void {
    const c = cr orelse return;
    rrect(c, x, y + 2.0, w, h, r);
    cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.22 * ov);
    cairo.cairo_fill(c);
    rrect(c, x, y, w, h, r);
    // Fill `drawerDim`, not `dock_fill` — the card body is the dimmer
    // drawer tone so the milky lift reads frosted.
    cairo.cairo_set_source_rgba(c, ch.drawer_dim.r, ch.drawer_dim.g, ch.drawer_dim.b, 0.55 * ov);
    cairo.cairo_fill(c);
    cairo.cairo_save(c);
    rrect(c, x, y, w, h, r);
    cairo.cairo_clip(c);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.07 * ov);
    cairo.cairo_rectangle(c, x, y, w, h);
    cairo.cairo_fill(c);
    cairo.cairo_restore(c);
    // Bright inner rim, bottom-weighted: soft on top, bright along the
    // bottom edge. This is the glassy outline (`cc_paint_glass_card_mc`).
    const rim = cairo.cairo_pattern_create_linear(0, y, 0, y + h);
    defer cairo.cairo_pattern_destroy(rim);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 0.0, 1.0, 1.0, 1.0, 0.12 * ov);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 0.5, 1.0, 1.0, 1.0, 0.05 * ov);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 1.0, 1.0, 1.0, 1.0, 0.42 * ov);
    cairo.cairo_set_source(c, rim);
    cairo.cairo_set_line_width(c, 1.0);
    rrect(c, x + 1.0, y + 1.0, @max(1.0, w - 2.0), @max(1.0, h - 2.0), @max(0.0, r - 1.0));
    cairo.cairo_stroke(c);
    // Faint outer glow so the edge lifts off the wallpaper.
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.08 * ov);
    cairo.cairo_set_line_width(c, 1.0);
    rrect(c, x + 0.5, y + 0.5, @max(1.0, w - 1.0), @max(1.0, h - 1.0), r);
    cairo.cairo_stroke(c);
}

fn rowBg(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64) void {
    const c = cr orelse return;
    rrect(c, x, y, w, h, 14.0);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.07);
    cairo.cairo_fill(c);
}

fn selectedBg(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, ch: chrome.Chrome) void {
    const c = cr orelse return;
    rrect(c, x, y, w, h, 14.0);
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
    if (svg_icons.draw(c, name, cx, cy, px, r, g, b, 1.0, false)) return;
    // Fresh path: `cairo_arc` joins the current point to the arc start, so
    // any leftover move_to (text, a previous shape) would paint a streak.
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, cx, cy, px * 0.28, 0, 6.283185307179586);
    cairo.cairo_set_source_rgba(c, r, g, b, 0.9);
    cairo.cairo_fill(c);
}

/// Aspect-fit blit of ARGB32 pixels (tray pixmaps, mixer theme icons, MPRIS
/// art) into an `w × h` box at `x, y`, centred.
fn blitArgb(cr: ?*cairo.cairo_t, pixels: []const u8, pw: i32, ph: i32, x: f64, y: f64, w: f64, h: f64) void {
    const c = cr orelse return;
    if (pixels.len == 0 or pw <= 0 or ph <= 0 or w <= 0 or h <= 0) return;
    const iw: f64 = @floatFromInt(pw);
    const ih: f64 = @floatFromInt(ph);
    const scale = @min(w / iw, h / ih);
    const dw = iw * scale;
    const dh = ih * scale;
    const surf = cairo.cairo_image_surface_create_for_data(
        @constCast(pixels.ptr),
        cairo.CAIRO_FORMAT_ARGB32,
        pw,
        ph,
        pw * 4,
    );
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        return;
    }
    defer cairo.cairo_surface_destroy(surf);
    cairo.cairo_save(c);
    cairo.cairo_translate(c, x + (w - dw) * 0.5, y + (h - dh) * 0.5);
    cairo.cairo_scale(c, scale, scale);
    cairo.cairo_set_source_surface(c, surf, 0, 0);
    cairo.cairo_pattern_set_extend(cairo.cairo_get_source(c), cairo.CAIRO_EXTEND_NONE);
    cairo.cairo_paint(c);
    cairo.cairo_restore(c);
}

fn text(cr: ?*cairo.cairo_t, s: []const u8, size: f64, x: f64, y: f64, r: f64, g: f64, b: f64, a: f64) void {
    const c = cr orelse return;
    if (s.len == 0) return;
    cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(c, size);
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    // cairo toy API wants NUL-terminated text.
    var buf: [256:0]u8 = undefined;
    const n = @min(s.len, 255);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    cairo.cairo_move_to(c, x, y);
    cairo.cairo_show_text(c, @ptrCast(&buf));
}

/// Scratch context for measuring text — the static
/// 1×1 surface behind `mixer_slider_xw` / `spotlight_truncate_to_width`.
/// Never shown; process-lifetime, frame-thread only.
var measure_cr: ?*cairo.cairo_t = null;
fn measurer() ?*cairo.cairo_t {
    if (measure_cr) |c| return c;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 1, 1);
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    const c = cairo.cairo_create(surf);
    cairo.cairo_surface_destroy(surf); // the context holds its own ref
    if (cairo.cairo_status(c) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_destroy(c);
        return null;
    }
    measure_cr = c;
    return c;
}

/// The face `text()` draws with, selected on the measuring context.
fn selectMeasureFont(c: *cairo.cairo_t, size: f64) void {
    cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(c, size);
}

/// Advance of `s` when painted at `size` in the same face.
pub fn textAdvance(size: f64, s: []const u8) f64 {
    const c = measurer() orelse return 0.0;
    selectMeasureFont(c, size);
    var buf: [256:0]u8 = undefined;
    const n = @min(s.len, 255);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    var ex: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
    cairo.cairo_text_extents(c, buf[0..n :0], &ex);
    return ex.x_advance;
}

/// Text truncation: drop codepoints from the end until the
/// advance fits `max_w` (popping bytes, no ellipsis).
/// Result borrows `buf` (NUL-terminated inside it, one byte reserved).
pub fn truncateToWidth(size: f64, max_w: f64, s: []const u8, buf: []u8) []const u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    var end: usize = n;
    const c = measurer() orelse return buf[0..end];
    selectMeasureFont(c, size);
    while (end > 0) {
        buf[end] = 0;
        var ex: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
        cairo.cairo_text_extents(c, buf[0..end :0], &ex);
        if (ex.x_advance <= max_w or end < 4) break;
        end -= 1;
        while (end > 0 and (buf[end - 1] & 0xC0) == 0x80) end -= 1;
    }
    return buf[0..end];
}

/// The mixer slider origin off the painted name:
/// name advance (after the `W − name_left − 68` budget) + 10. `buf`
/// receives the truncated copy for the measure; the caller paints its own.
pub fn mixerSliderX(popup_w: f64, name: []const u8, buf: []u8) f64 {
    const shown = truncateToWidth(12.0, popup_w - cc_layout.mixer_name_left - 68.0, name, buf);
    return cc_layout.mixer_name_left + textAdvance(12.0, shown) + 10.0;
}

/// Slider widget: a 4 px round-cap track inset half a thumb
/// from each geometry edge, thumb radius 8 riding that inset span. The
/// rectangle is the widget box — hit tests keep mapping `t` across the full
/// box (`t = (px − tx) / tw`).
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
    // Track dim, fill accent @ 0.85, solid thumb.
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

pub const PaintArgs = struct {
    cfg: *const schema.ShellConfig,
    state: *cc_state.State,
    layout: cc_layout.Layout,
    mix_rows: []const cc_layout.MixerRow,
    snap: cc_data.Snapshot,
    /// Frame clock for the just-applied mixer ignore window (`nowMs <
    /// mixerIgnoreStateUntilMs` in the row painter). The host passes its
    /// last tick; a stale-by-a-tick clock only holds the applied value just
    /// longer, it never misplaces a row.
    now_ms: u64 = 0,
};

/// Paint the whole popup into `cr` (already sized to `layout.total_h`).
/// Section order: shadow +
/// shell glass, tiles, network/bt panels, audio cards, device panels,
/// mixer, media, weather.
pub fn paint(cr: ?*cairo.cairo_t, popup_w: f64, args: PaintArgs) void {
    const c = cr orelse return;
    const l = args.layout;
    const st = args.state;
    const s = args.snap;
    const ch = chrome.of(args.cfg);
    // Shell vs. inner glass: `ccShellOv` is the control-center overlay knob,
    // `ccInnerGlass` the inner-cards knob (master-gated when Advanced is
    // off). Both are 1.0 at defaults, so nothing above changes by default.
    const shell_ov = overlay.scale(&args.cfg.appearance, .control_center);
    const inner_ov = overlay.controlCenterInnerAlpha(&args.cfg.appearance);

    // Shadow + shell. The shadow follows the shell knob too: at 0% the whole
    // surface has to be gone, shadow included, or the slider bottoms out at
    // a visible smudge.
    rrect(c, 2.0, 3.0, popup_w, l.total_h, 24.0);
    cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.22 * shell_ov);
    cairo.cairo_fill(c);
    glassCard(c, 0, 0, popup_w, l.total_h, 24.0, ch, shell_ov);
    cairo.cairo_save(c);
    rrect(c, 0, 0, popup_w, l.total_h, 24.0);
    cairo.cairo_clip(c);

    // Section 1: tiles.
    const net_title = cc_data.netTitle(s);
    paintTile(c, l.net_x, cc_layout.grid_y, l.tile_w, cc_layout.tile_h, cc_data.netGlyph(s), net_title, s.net.connected, ch, st.hover_target == .network_card, inner_ov);
    paintTile(c, l.bt_x, cc_layout.grid_y, l.tile_w, cc_layout.tile_h, cc_data.btGlyph(s), "Bluetooth", s.bt.powered, ch, st.hover_target == .bluetooth_card, inner_ov);

    // Section 2: network panel.
    if (l.net_h > 2.0) {
        glassCard(c, cc_layout.pad, l.net_y, popup_w - cc_layout.pad * 2.0, l.net_h, 20.0, ch, inner_ov);
        var hdr_buf: [128]u8 = undefined;
        const hdr = if (s.net.wifi)
            std.fmt.bufPrint(&hdr_buf, "Wi-Fi \xE2\x80\xA2 {s}", .{if (s.net.ssid.len > 0) s.net.ssid else s.net.iface}) catch "Wi-Fi"
        else if (s.net.ethernet)
            std.fmt.bufPrint(&hdr_buf, "Ethernet \xE2\x80\xA2 {s}", .{s.net.iface}) catch "Ethernet"
        else
            "Network";
        text(c, hdr, 12.0, cc_layout.pad + 12.0, l.net_y + 18.0, 0.93, 0.96, 0.98, 0.95);
        var i: i32 = 0;
        while (i < l.net_rows and @as(usize, @intCast(i)) < s.aps.len) : (i += 1) {
            const ap = s.aps[@intCast(i)];
            const ry = l.net_y + l.net_header_h + @as(f64, @floatFromInt(i)) * cc_layout.row_pitch;
            const hov = st.hover_target == .network_row and st.hover_row_idx == i;
            if (hov) hoverHl(c, cc_layout.pad + 10.0, ry + 6.0, popup_w - cc_layout.pad * 2.0 - 20.0, 24.0, 14.0, ch) else if (ap.active) selectedBg(c, cc_layout.pad + 10.0, ry + 6.0, popup_w - cc_layout.pad * 2.0 - 20.0, 24.0, ch) else rowBg(c, cc_layout.pad + 10.0, ry + 6.0, popup_w - cc_layout.pad * 2.0 - 20.0, 24.0);
            glyph(c, "wifi", cc_layout.pad + 18.0, ry + 34.0 * 0.55, 16.0, 0.85, 0.88, 0.90);
            text(c, if (ap.ssid.len > 0) ap.ssid else "(hidden)", 12.0, cc_layout.pad + 38.0, ry + 20.0, 0.93, 0.96, 0.98, 1.0);
            if (ap.needs_password) glyph(c, "lock", popup_w - cc_layout.pad - 18.0, ry + 34.0 * 0.55, 14.0, 0.86, 0.90, 0.94);
        }
        // An open panel with nothing in it explains itself: a box without a
        // wifi device can never list networks, and an empty scan says so
        // rather than showing a blank card.
        if (l.net_rows == 0 and !s.wifi_password_prompt and s.wifi_error.len == 0) {
            const note: []const u8 = if (!s.net.wifi) "No Wi-Fi adapter found" else "No networks found";
            text(c, note, 12.0, cc_layout.pad + 12.0, l.net_y + l.net_header_h + 14.0, 0.80, 0.86, 0.92, 0.85);
        }
        if (s.wifi_error.len > 0) text(c, s.wifi_error, 12.0, cc_layout.pad + 12.0, l.net_y + 36.0, 0.86, 0.42, 0.42, 0.92);
        // Password prompt (56 px reserved by the layout when the host has a
        // pending SSID): prompt line + masked bullets.
        if (s.wifi_password_prompt) {
            const py = l.net_y + l.net_header_h + @as(f64, @floatFromInt(l.net_rows)) * cc_layout.row_pitch + 8.0;
            rowBg(c, cc_layout.pad + 10.0, py, popup_w - cc_layout.pad * 2.0 - 20.0, 40.0);
            var prompt_buf: [160]u8 = undefined;
            const prompt = if (s.wifi_pending_ssid.len > 0)
                std.fmt.bufPrint(&prompt_buf, "Password for {s}", .{s.wifi_pending_ssid}) catch "Password for Wi-Fi"
            else
                "Password for Wi-Fi";
            text(c, prompt, 12.0, cc_layout.pad + 16.0, py + 16.0, 0.86, 0.90, 0.94, 1.0);
            var dots_buf: [129]u8 = undefined;
            const n = @min(s.wifi_password.len, 128);
            @memset(dots_buf[0..n], '*');
            const dots: []const u8 = if (n > 0) dots_buf[0..n] else "…";
            text(c, dots, 12.0, cc_layout.pad + 16.0, py + 32.0, 0.86, 0.90, 0.94, 1.0);
        }
    }

    // Section 2b: bluetooth panel.
    if (l.bt_h > 2.0) {
        glassCard(c, cc_layout.pad, l.bt_y, popup_w - cc_layout.pad * 2.0, l.bt_h, 20.0, ch, inner_ov);
        text(c, "Bluetooth", 12.0, cc_layout.pad + 12.0, l.bt_y + 18.0, 0.93, 0.96, 0.98, 0.95);
        var i: i32 = 0;
        while (i < l.bt_rows and @as(usize, @intCast(i)) < s.bt_devs.len) : (i += 1) {
            const d = s.bt_devs[@intCast(i)];
            const ry = cc_layout.panelRowY(l.bt_y, i);
            const hov = st.hover_target == .bluetooth_row and st.hover_row_idx == i;
            if (hov) hoverHl(c, cc_layout.pad + 10.0, ry + 6.0, popup_w - cc_layout.pad * 2.0 - 20.0, 24.0, 14.0, ch) else if (d.connected) selectedBg(c, cc_layout.pad + 10.0, ry + 6.0, popup_w - cc_layout.pad * 2.0 - 20.0, 24.0, ch) else rowBg(c, cc_layout.pad + 10.0, ry + 6.0, popup_w - cc_layout.pad * 2.0 - 20.0, 24.0);
            glyph(c, "bluetooth", cc_layout.pad + 22.0, ry + 17.0, 15.0, 0.80, 0.84, 0.86);
            text(c, if (d.alias.len > 0) d.alias else d.address, 12.0, cc_layout.pad + 42.0, ry + 21.0, 0.93, 0.96, 0.98, 1.0);
            const right = popup_w - cc_layout.pad - 10.0;
            const b = cc_layout.btBtns(d.paired, right);
            const label: []const u8 = if (d.connected) "Disconnect" else if (d.paired) "Connect" else "Pair";
            rrect(c, b.action_x, ry + 5.0, b.action_w, 24.0, 8.0);
            if (d.connected or d.paired) {
                cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, 0.85);
            } else {
                cairo.cairo_set_source_rgba(c, 0.22, 0.22, 0.28, 0.7);
            }
            cairo.cairo_fill(c);
            text(c, label, 10.0, b.action_x + 8.0, ry + 21.0, 0.05, 0.05, 0.07, 1.0);
        }
        // Same as the network panel: an empty device list says why.
        if (l.bt_rows == 0) {
            const note: []const u8 = if (!s.bt.powered) "Bluetooth is off" else "No devices found";
            text(c, note, 12.0, cc_layout.pad + 12.0, cc_layout.panelRowY(l.bt_y, 0) + 14.0, 0.80, 0.86, 0.92, 0.85);
        }
    }

    // Section 3: audio cards.
    paintAudioCard(c, cc_layout.pad, l.audio_y, l.tile_w, true, s, ch, st, inner_ov);
    paintAudioCard(c, cc_layout.pad + l.tile_w + cc_layout.gap, l.audio_y, l.tile_w, false, s, ch, st, inner_ov);

    // Section 3b: device panels.
    paintDevicePanel(c, popup_w, l.out_dev_y, l.out_dev_h, l.out_dev_rows, "Output device", s.out_devs, .output_device_row, st, ch, inner_ov);
    paintDevicePanel(c, popup_w, l.in_dev_y, l.in_dev_h, l.in_dev_rows, "Input device", s.in_devs, .input_device_row, st, ch, inner_ov);

    // Section 4: mixer.
    paintMixer(c, popup_w, args, ch, inner_ov);

    // Section 5: media.
    paintMedia(c, popup_w, l, s, ch, st, inner_ov);

    // Section 6: weather.
    paintWeather(c, popup_w, l, s, ch, st, inner_ov);

    cairo.cairo_restore(c);
}

fn paintTile(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, icon: []const u8, title: []const u8, active: bool, ch: chrome.Chrome, hovered: bool, ov: f64) void {
    const c = cr orelse return;
    glassCard(c, x, y, w, h, 20.0, ch, ov);
    if (hovered) hoverHl(c, x, y, w, h, 20.0, ch);
    const icx = x + 20.0;
    const icy = y + h * 0.5;
    rrect(c, icx - 14.0, icy - 14.0, 28.0, 28.0, 10.0);
    cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, if (active) 0.20 else 0.09);
    cairo.cairo_fill(c);
    glyph(c, icon, icx, icy + 1.0, 20.0, if (active) ch.accent.r else 0.65, if (active) ch.accent.g else 0.68, if (active) ch.accent.b else 0.72);
    text(c, title, 13.0, x + 38.0, y + 30.0, 0.93, 0.96, 0.98, 0.95);
}

fn paintAudioCard(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, is_output: bool, s: cc_data.Snapshot, ch: chrome.Chrome, st: *cc_state.State, ov: f64) void {
    const c = cr orelse return;
    glassCard(c, x, y, w, cc_layout.audio_h, 20.0, ch, ov);
    const muted = if (is_output) s.out.muted else s.in.muted;
    const icon = if (is_output) cc_data.outGlyph(s) else cc_data.inGlyph(s);
    const name = if (is_output) s.out.device_name else s.in.device_name;
    const pct = if (is_output) cc_data.outPct(s) else cc_data.inPct(s);
    const t: f64 = std.math.clamp(@as(f64, @floatFromInt(pct)) / 100.0, 0.0, 1.0);
    const icx = x + 24.0;
    const icy = y + 28.0;
    rrect(c, icx - 14.0, icy - 14.0, 28.0, 28.0, 10.0);
    cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, if (muted) 0.09 * ov else 0.20 * ov);
    cairo.cairo_fill(c);
    glyph(c, icon, icx, icy + 1.0, 20.0, if (muted) 0.65 else ch.accent.r, if (muted) 0.68 else ch.accent.g, if (muted) 0.72 else ch.accent.b);
    var trunc: [96]u8 = undefined;
    const n = @min(name.len, trunc.len);
    @memcpy(trunc[0..n], name[0..n]);
    text(c, if (n > 0) trunc[0..n] else if (is_output) "Output" else "Input", 14.0, x + 48.0, y + 30.0, 0.93, 0.96, 0.98, 0.95);
    slider(c, x + cc_layout.audio_track_x_pad - cc_layout.audio_hit_pad_h, y + cc_layout.audio_track_y_from_card_top - cc_layout.audio_hit_pad_v, w - 2.0 * cc_layout.audio_track_x_pad + 2.0 * cc_layout.audio_hit_pad_h, cc_layout.audio_track_h + 2.0 * cc_layout.audio_hit_pad_v, t, ch);
    _ = st;
}

/// One device dropdown. `devs` is the snapshot's output *or* input list
/// (both shapes carry `display_name` + `is_default`); `hover` selects which
/// hover target lights the rows up. An empty list still paints the header
/// and the row slots, so the panel never collapses to nothing.
fn paintDevicePanel(cr: ?*cairo.cairo_t, popup_w: f64, py: f64, ph: f64, rows: i32, header: []const u8, devs: anytype, hover: cc_state.HoverTarget, st: *cc_state.State, ch: chrome.Chrome, ov: f64) void {
    if (ph <= 2.0) return;
    const c = cr orelse return;
    glassCard(c, cc_layout.pad, py, popup_w - cc_layout.pad * 2.0, ph, 20.0, ch, ov);
    text(c, header, 12.0, cc_layout.pad + 12.0, py + 18.0, 0.93, 0.96, 0.98, 1.0);
    var i: i32 = 0;
    while (i < rows) : (i += 1) {
        const ry = cc_layout.panelRowY(py, i);
        const hov = st.hover_target == hover and st.hover_row_idx == i;
        // The radio follows the backend's default marker; without one (an
        // empty list, a backend that does not report it) the first row wins.
        var label: []const u8 = "Device";
        var is_def = i == 0;
        if (@as(usize, @intCast(i)) < devs.len) {
            is_def = devs[@intCast(i)].is_default;
            if (devs[@intCast(i)].display_name.len > 0) label = devs[@intCast(i)].display_name;
        }
        if (hov) hoverHl(c, cc_layout.pad + 10.0, ry + 6.0, popup_w - cc_layout.pad * 2.0 - 20.0, 24.0, 14.0, ch) else if (is_def) selectedBg(c, cc_layout.pad + 10.0, ry + 6.0, popup_w - cc_layout.pad * 2.0 - 20.0, 24.0, ch) else rowBg(c, cc_layout.pad + 10.0, ry + 6.0, popup_w - cc_layout.pad * 2.0 - 20.0, 24.0);
        glyph(c, if (is_def) "radio_checked" else "radio_unchecked", cc_layout.pad + 18.0, ry + 17.0, 14.0, ch.accent.r, ch.accent.g, ch.accent.b);
        text(c, label, 12.0, cc_layout.pad + 38.0, ry + 20.0, 0.93, 0.96, 0.98, 1.0);
    }
}

fn paintMixer(cr: ?*cairo.cairo_t, popup_w: f64, args: PaintArgs, ch: chrome.Chrome, ov: f64) void {
    const c = cr orelse return;
    const l = args.layout;
    const st = args.state;
    const s = args.snap;
    glassCard(c, cc_layout.pad, l.mixer_y, popup_w - cc_layout.pad * 2.0, l.mixer_h, 20.0, ch, ov);
    if (st.hover_target == .mixer_card) hoverHl(c, cc_layout.pad, l.mixer_y, popup_w - cc_layout.pad * 2.0, l.mixer_h, 20.0, ch);
    glyph(c, if (st.mixer_expanded) "expand_less" else "expand_more", cc_layout.mixer_icon_left + 8.0, l.mixer_y + cc_layout.mixer_header_h * 0.5 + 1.0, 18.0, 0.88, 0.93, 0.96);
    text(c, "Volume Mixer", 15.0, cc_layout.mixer_name_left, l.mixer_y + cc_layout.mixer_header_h * 0.5 + 5.0, 0.93, 0.96, 0.98, 1.0);
    // Section labels over the 28 px bands the layout reserves when expanded
    // (same y math: `ry + kMixerSectionH * 0.5 + 4` for Output,
    // above the first input row for Input).
    if (st.mixer_expanded and l.mix_show_out > 0) {
        text(c, "Output", 12.0, cc_layout.mixer_name_left, l.mixer_y + cc_layout.mixer_header_h + cc_layout.mixer_section_h * 0.5 + 4.0, 0.80, 0.84, 0.88, 1.0);
    }
    if (st.mixer_expanded and l.mix_show_in > 0) {
        for (args.mix_rows) |r| {
            if (!r.is_input) continue;
            text(c, "Input", 12.0, cc_layout.mixer_name_left, r.y - cc_layout.mixer_section_h * 0.5 + 4.0, 0.80, 0.84, 0.88, 1.0);
            break;
        }
    }
    for (args.mix_rows) |r| {
        const list = if (r.is_input) s.in_streams else s.out_streams;
        if (r.stream_idx < 0 or @as(usize, @intCast(r.stream_idx)) >= list.len) continue;
        const stream = list[@intCast(r.stream_idx)];
        // Theme icon when the dock resolved one, else the plain gray dot —
        // the row painter's fallback (`cairo_arc(iconX + 8, iconY + 8,
        // 6.0)`), not a note glyph.
        if (stream.icon_argb.len > 0 and stream.icon_w > 0 and stream.icon_h > 0) {
            blitArgb(c, stream.icon_argb, stream.icon_w, stream.icon_h, cc_layout.mixer_icon_left, r.y + cc_layout.mixer_icon_y, 16.0, 16.0);
        } else {
            // Standalone dot: clear the path first or the arc stitches a
            // line from whatever `blitArgb`/text left behind.
            cairo.cairo_new_path(c);
            cairo.cairo_arc(c, cc_layout.mixer_icon_left + 8.0, r.y + cc_layout.mixer_icon_y + 8.0, 6.0, 0, 6.283185307179586);
            cairo.cairo_set_source_rgba(c, 0.72, 0.76, 0.80, 0.92);
            cairo.cairo_fill(c);
        }
        // The name truncates to budget (`W − name_left − 68`) and the
        // slider origin follows the painted advance (`mixer_slider_xw`):
        // name_end = name_left + measured + 10 — long names run into their
        // own track instead of through it.
        var name_buf: [256]u8 = undefined;
        const shown = truncateToWidth(12.0, popup_w - cc_layout.mixer_name_left - 68.0, stream.app_name, &name_buf);
        text(c, shown, 12.0, cc_layout.mixer_name_left, r.y + cc_layout.mixer_name_baseline, 0.93, 0.96, 0.98, 0.92);
        // The row percent is the backend value, overridden by an active drag
        // (`mixerDragUiPct`), and just after an apply by the last applied
        // value until the backend catches up (`mixerIgnoreStateUntilMs`) —
        // row math. The thumb then follows the visual drag
        // position whenever one is running.
        var row_pct = stream.volume_pct;
        if (st.mixer_drag_active and st.mixer_drag_is_input == r.is_input and st.mixer_drag_stream_id == stream.sink_input_id and st.mixer_drag_ui_pct >= 0) {
            row_pct = st.mixer_drag_ui_pct;
        } else if (st.mixer_drag_is_input == r.is_input and st.mixer_drag_stream_id == stream.sink_input_id and st.mixer_last_applied_pct >= 0 and args.now_ms < st.mixer_ignore_state_until_ms) {
            row_pct = st.mixer_last_applied_pct;
        }
        var t: f64 = std.math.clamp(@as(f64, @floatFromInt(row_pct)) / 100.0, 0.0, 1.0);
        if (st.mixer_drag_active and st.mixer_drag_is_input == r.is_input and st.mixer_drag_stream_id == stream.sink_input_id) {
            if (st.mixer_drag_visual_t >= 0.0) t = std.math.clamp(st.mixer_drag_visual_t, 0.0, 1.0);
        }
        const sx = cc_layout.mixer_name_left + textAdvance(12.0, shown) + 10.0;
        const sw = @max(60.0, popup_w - 28.0 - sx);
        slider(c, sx, r.y + cc_layout.mixer_slider_cy - 19.0, sw, 38.0, t, ch);
    }
    if (l.mix_more) {
        var more_buf: [32]u8 = undefined;
        const more = std.fmt.bufPrint(&more_buf, "+{d} more", .{l.mix_total_out - 1}) catch "+ more";
        // `ry + kMixerMoreH * 0.5 + 4` with ry past the single out row.
        text(c, more, 12.0, cc_layout.mixer_name_left, l.mixer_y + cc_layout.mixer_header_h + @as(f64, @floatFromInt(l.mix_show_out)) * cc_layout.mixer_row_h + 17.0, 0.72, 0.78, 0.82, 0.90);
    }
}

fn paintMedia(cr: ?*cairo.cairo_t, popup_w: f64, l: cc_layout.Layout, s: cc_data.Snapshot, ch: chrome.Chrome, st: *cc_state.State, ov: f64) void {
    const c = cr orelse return;
    glassCard(c, cc_layout.pad, l.media_y, popup_w - cc_layout.pad * 2.0, cc_layout.media_h, 20.0, ch, ov);
    if (st.hover_target == .media_card) hoverHl(c, cc_layout.pad, l.media_y, popup_w - cc_layout.pad * 2.0, cc_layout.media_h, 20.0, ch);
    const art_x = cc_layout.pad + 12.0;
    const art_y = l.media_y + 14.0;
    const art_s: f64 = 56.0;
    rrect(c, art_x, art_y, art_s, art_s, 12.0);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.07);
    cairo.cairo_fill(c);
    // Cover art only for a live player (`active && ms.art`); with
    // no pixels the card shows the note, full stop — there is no tinted
    // halfway box.
    if (s.media.active and s.media.art_argb.len > 0 and s.media.art_w > 0 and s.media.art_h > 0) {
        // Cover-fit art under the same rounded clip.
        cairo.cairo_save(c);
        rrect(c, art_x, art_y, art_s, art_s, 12.0);
        cairo.cairo_clip(c);
        const iw: f64 = @floatFromInt(s.media.art_w);
        const ih: f64 = @floatFromInt(s.media.art_h);
        const sc = art_s / @max(1.0, @max(iw, ih));
        const surf = cairo.cairo_image_surface_create_for_data(
            @constCast(s.media.art_argb.ptr),
            cairo.CAIRO_FORMAT_ARGB32,
            s.media.art_w,
            s.media.art_h,
            s.media.art_w * 4,
        );
        if (cairo.cairo_surface_status(surf) == cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_translate(c, art_x + (art_s - iw * sc) * 0.5, art_y + (art_s - ih * sc) * 0.5);
            cairo.cairo_scale(c, sc, sc);
            cairo.cairo_set_source_surface(c, surf, 0, 0);
            cairo.cairo_paint(c);
        }
        cairo.cairo_surface_destroy(surf);
        cairo.cairo_restore(c);
    } else {
        glyph(c, "music_note", art_x + art_s * 0.5, art_y + art_s * 0.55, 22.0, 0.88, 0.93, 0.96);
    }
    const tx = cc_layout.pad + 80.0;
    const text_max_w = popup_w - cc_layout.pad - tx;
    // An active player with no names yet reads as unknown
    // (`"Unknown title"` / `"Unknown artist"`); an idle card reads "No
    // Media" on both lines.
    const title: []const u8 = if (!s.media.active) "No Media" else if (s.media.title.len > 0) s.media.title else "Unknown title";
    var text_y = l.media_y + 30.0;
    if (textAdvance(13.0, title) <= text_max_w) {
        text(c, title, 13.0, tx, text_y, 0.93, 0.96, 0.98, 1.0);
        text_y += 17.0;
    } else {
        // Too wide for the card: split near the middle at a space and stack
        // two lines — split search around `len / 2`.
        const mid = title.len / 2;
        var split: ?usize = null;
        var off: usize = 0;
        while (off < mid) : (off += 1) {
            if (mid + off < title.len and title[mid + off] == ' ') {
                split = mid + off;
                break;
            }
            if (mid > off + 1 and title[mid - off - 1] == ' ') {
                split = mid - off - 1;
                break;
            }
        }
        if (split) |sp| {
            text(c, title[0..sp], 13.0, tx, text_y, 0.93, 0.96, 0.98, 1.0);
            text_y += 17.0;
            text(c, if (sp + 1 < title.len) title[sp + 1 ..] else "", 13.0, tx, text_y, 0.93, 0.96, 0.98, 1.0);
            text_y += 17.0;
        } else {
            text(c, title[0..mid], 13.0, tx, text_y, 0.93, 0.96, 0.98, 1.0);
            text_y += 17.0;
            text(c, title[mid..], 13.0, tx, text_y, 0.93, 0.96, 0.98, 1.0);
            text_y += 17.0;
        }
    }
    const artist: []const u8 = if (!s.media.active) "No Media" else if (s.media.artist.len > 0) s.media.artist else "Unknown artist";
    text(c, artist, 12.0, tx, text_y, 0.72, 0.78, 0.82, 0.92);
    if (s.media.active) {
        const cy = cc_layout.mediaBtnCy(l.media_y, cc_layout.media_h);
        paintMediaBtn(c, cc_layout.mediaBtnCx(cc_layout.pad, popup_w - cc_layout.pad * 2.0, 0), cy, "skip_previous", s.media.can_go_previous, st.hover_target == .media_prev, false, ch);
        paintMediaBtn(c, cc_layout.mediaBtnCx(cc_layout.pad, popup_w - cc_layout.pad * 2.0, 1), cy, if (s.media.playing) "pause" else "play_arrow", s.media.can_play_pause, st.hover_target == .media_play_pause, true, ch);
        paintMediaBtn(c, cc_layout.mediaBtnCx(cc_layout.pad, popup_w - cc_layout.pad * 2.0, 2), cy, "skip_next", s.media.can_go_next, st.hover_target == .media_next, false, ch);
    }
}

fn paintMediaBtn(cr: ?*cairo.cairo_t, cx: f64, cy: f64, icon: []const u8, enabled: bool, hovered: bool, primary: bool, ch: chrome.Chrome) void {
    const c = cr orelse return;
    // Every button opens with `cairo_new_path`: without it the arc
    // stitches a line from the artist text's leftover move_to to the first
    // disc — the streak across the card.
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, cx, cy, 14.0, 0, 6.283185307179586);
    if (primary) {
        cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, if (hovered) 0.95 else if (enabled) 0.85 else 0.30);
        cairo.cairo_fill(c);
        glyph(c, icon, cx, cy + 0.5, 18.0, 0.05, 0.05, 0.07);
        return;
    }
    if (hovered) {
        cairo.cairo_set_source_rgba(c, ch.accent.r, ch.accent.g, ch.accent.b, 0.18);
        cairo.cairo_fill(c);
    } else {
        // Flat disc plus the 1 px outline ring — painted
        // `fill_preserve` + `outline @ 0.13` under every idle transport.
        cairo.cairo_set_source_rgba(c, 1, 1, 1, if (enabled) 0.10 else 0.04);
        cairo.cairo_fill_preserve(c);
        cairo.cairo_set_source_rgba(c, ch.outline.r, ch.outline.g, ch.outline.b, 0.13);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_stroke(c);
    }
    glyph(c, icon, cx, cy + 0.5, 18.0, 0.88, 0.93, 0.96);
}

fn paintWeather(cr: ?*cairo.cairo_t, popup_w: f64, l: cc_layout.Layout, s: cc_data.Snapshot, ch: chrome.Chrome, st: *cc_state.State, ov: f64) void {
    const c = cr orelse return;
    glassCard(c, cc_layout.pad, l.weather_y, popup_w - cc_layout.pad * 2.0, cc_layout.weather_h, 20.0, ch, ov);
    if (st.hover_target == .weather_card) hoverHl(c, cc_layout.pad, l.weather_y, popup_w - cc_layout.pad * 2.0, cc_layout.weather_h, 20.0, ch);
    const w = s.weather;
    const unit: []const u8 = if (w.fahrenheit) "F" else "C";
    var temp_buf: [32]u8 = undefined;
    const temp = if (w.available) std.fmt.bufPrint(&temp_buf, "{d}\xC2\xB0{s}", .{ w.temp, unit }) catch "--" else "--";
    // No reading → cloud_off; a live reading with no icon name → the plain
    // cloud when the icon is empty, never a fallback dot.
    const hero: []const u8 = if (!w.available) "cloud_off" else if (w.icon.len > 0) w.icon else "cloud";
    glyph(c, hero, cc_layout.pad + 24.0, l.weather_y + 32.0, 34.0, 0.94, 0.96, 0.98);
    text(c, temp, 44.0, cc_layout.pad + 56.0, l.weather_y + 46.0, 0.93, 0.96, 0.98, 1.0);
    // City right-aligned, stripping ", State" — "Toronto,
    // Ontario" paints as "Toronto" — so the measure and the draw share the
    // stripped slice.
    const city = if (std.mem.indexOfScalar(u8, w.location, ',')) |ci| w.location[0..ci] else w.location;
    var city_w: f64 = 0;
    {
        cairo.cairo_select_font_face(c, "Inter", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
        cairo.cairo_set_font_size(c, 14.0);
        var ext: cairo.cairo_text_extents_t = undefined;
        var cbuf: [128:0]u8 = undefined;
        const n = @min(city.len, 127);
        @memcpy(cbuf[0..n], city[0..n]);
        cbuf[n] = 0;
        cairo.cairo_text_extents(c, @ptrCast(&cbuf), &ext);
        city_w = ext.x_advance;
    }
    text(c, city, 14.0, popup_w - cc_layout.pad - 12.0 - city_w, l.weather_y + 46.0, 0.93, 0.96, 0.98, 1.0);
    text(c, if (w.fahrenheit) "Fahrenheit" else "Celsius", 12.0, cc_layout.pad + 56.0, l.weather_y + 65.0, 0.72, 0.78, 0.82, 0.92);
    // Four detail chips.
    const inner_x = cc_layout.pad + 12.0;
    const inner_w = popup_w - cc_layout.pad * 2.0 - 24.0;
    const chip_gap: f64 = 10.0;
    const chip_w = (inner_w - chip_gap * 3.0) / 4.0;
    const chip_y = l.weather_y + 80.0;
    var feels_buf: [32]u8 = undefined;
    var hum_buf: [32]u8 = undefined;
    var wind_buf: [32]u8 = undefined;
    var vis_buf: [32]u8 = undefined;
    paintChip(c, inner_x, chip_y, chip_w, "Feels like", if (w.available) std.fmt.bufPrint(&feels_buf, "{d}\xC2\xB0{s}", .{ w.feels_like, unit }) catch "--" else "--");
    paintChip(c, inner_x + (chip_w + chip_gap), chip_y, chip_w, "Humidity", if (w.available) std.fmt.bufPrint(&hum_buf, "{d}%", .{w.humidity_pct}) catch "--" else "--");
    paintChip(c, inner_x + (chip_w + chip_gap) * 2, chip_y, chip_w, "Wind", if (w.available) std.fmt.bufPrint(&wind_buf, "{d} km/h", .{w.wind_kmh}) catch "--" else "--");
    paintChip(c, inner_x + (chip_w + chip_gap) * 3, chip_y, chip_w, "Visibility", if (w.available) std.fmt.bufPrint(&vis_buf, "{d}", .{w.visibility_m}) catch "--" else "--");
    text(c, "5-Day Forecast", 12.0, inner_x, l.weather_y + 142.0, 0.72, 0.78, 0.82, 0.92);
    const f_gap: f64 = 8.0;
    const fw = (inner_w - f_gap * 4.0) / 5.0;
    const fy0 = l.weather_y + 152.0;
    const n = @min(5, w.forecast.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const d = w.forecast[i];
        const fx = inner_x + @as(f64, @floatFromInt(i)) * (fw + f_gap);
        rrect(c, fx, fy0, fw, 78.0, 12.0);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.06);
        cairo.cairo_fill(c);
        // Both lines center by measured advance
        // `-advance * 0.5`), not a fixed offset — long day names ("Wednesday")
        // drift visibly otherwise.
        text(c, d.day, 11.0, fx + fw * 0.5 - textAdvance(11.0, d.day) * 0.5, fy0 + 16.0, 0.72, 0.78, 0.82, 0.92);
        glyph(c, d.icon, fx + fw * 0.5, fy0 + 36.0, 18.0, 0.88, 0.93, 0.96);
        var mm_buf: [32]u8 = undefined;
        const mm = std.fmt.bufPrint(&mm_buf, "{d}\xC2\xB0/{d}\xC2\xB0", .{ d.hi, d.lo }) catch "";
        text(c, mm, 12.0, fx + fw * 0.5 - textAdvance(12.0, mm) * 0.5, fy0 + 62.0, 0.93, 0.96, 0.98, 1.0);
    }
}

fn paintChip(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, label: []const u8, value: []const u8) void {
    const c = cr orelse return;
    rrect(c, x, y, w, 46.0, 12.0);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.06);
    cairo.cairo_fill(c);
    text(c, label, 11.0, x + 12.0, y + 16.0, 0.72, 0.78, 0.82, 0.90);
    text(c, value, 16.0, x + 12.0, y + 38.0, 0.93, 0.96, 0.98, 1.0);
}

test "cc-paint: full popup renders onto a surface" {
    const t = std.testing;
    var cfg: schema.ShellConfig = .{};
    var st = cc_state.State{};
    var rows: std.ArrayList(cc_layout.MixerRow) = .empty;
    defer rows.deinit(t.allocator);
    const aps = [_]cc_data.WifiAp{.{ .ssid = "Home", .signal_pct = 80, .active = true }};
    const devs = [_]cc_data.OutputDevice{.{ .display_name = "Speakers", .is_default = true }};
    const streams = [_]cc_data.MixerStream{.{ .app_name = "speech-dispatcher-dummy", .volume_pct = 90 }};
    const days = [_]cc_data.ForecastDay{
        .{ .day = "Tue", .hi = 26, .lo = 16 },
        .{ .day = "Wed", .hi = 17, .lo = 10 },
    };
    const snap = cc_data.Snapshot{
        .net = .{ .connected = true, .ethernet = true, .iface = "eth0" },
        .aps = &aps,
        .bt = .{ .powered = true },
        .out = .{ .volume_pct = 80, .device_name = "Heavys H1H" },
        .in = .{ .volume_pct = 70, .device_name = "UMC202HD 192k Input 1" },
        .out_devs = &devs,
        .out_streams = &streams,
        .media = .{ .active = true, .title = "liMous1ne (feat. AURORA)", .artist = "Bring Me The Horizon", .playing = true, .can_go_previous = true, .can_go_next = true, .can_play_pause = true },
        .weather = .{ .available = true, .location = "Toronto", .temp = 25, .feels_like = 27, .humidity_pct = 74, .wind_kmh = 15, .visibility_m = 21300, .forecast = &days },
    };
    const counts = cc_layout.Counts{ .net_rows = 1, .bt_rows = 0, .out_dev_rows = 1, .mix_total_out = 1 };
    const l = cc_layout.computeLayout(460, &st, counts, 0, true, t.allocator, &rows);
    const w: i32 = 460;
    const h: i32 = @intFromFloat(@ceil(l.total_h));
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, w, h);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paint(cr, 460, .{ .cfg = &cfg, .state = &st, .layout = l, .mix_rows = rows.items, .snap = snap });
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    // Net title helper now takes no scratch buffer.
    try t.expectEqualStrings("Ethernet", cc_data.netTitle(.{ .net = .{ .ethernet = true } }));
}
