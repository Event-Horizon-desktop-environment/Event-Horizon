//! Settings ▸ Network — Wi-Fi (17), Wired (18) and VPN (28).
//!
//! One self-painting page owns all three rail entries, the way
//! `sound_tab` owns its four. The reference pages
//! (`settings_tab_wifi.cpp`, `wired_*_m3.hpp`, `settings_tab_network.cpp`)
//! are reproduced here in the settings2 card idiom: cards sit at
//! `content_x + 8` with `content_w - 16` width, the Wi-Fi access-point list
//! scrolls with the page instead of inside the card, and the Wired pages
//! keep the C++ sub-tab bar (6 tabs, tab 18's bar in `subtabs.zig`).
//!
//! Live data comes from `live_network.settingsQuery` (one D-Bus snapshot
//! for radio state, the uncapped AP list, the saved-SSID set and the wired
//! device block) and `live_vpn` (nmcli reads plus detached writes). The VPN
//! list is polled at 2 s and reconciled by UUID with an optimistic 8 s
//! pending window, exactly like the C++ page, so a row does not flip back
//! while `nmcli` is still dialling.
//!
//! Writes are fire-and-forget threads. The Wi-Fi password prompt and the
//! VPN Add dialog are window-space modals (painted after the translated
//! content, like `accounts_tab`), and the VPN dialog's file import runs the
//! blocking picker inline before handing the path to a detached importer;
//! its outcome lands in the shared status mailbox and is shown under the
//! VPN card.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const app_mod = @import("app.zig");
const xkb = @import("../../wl/seat.zig").xkb;
const live_net = @import("../../desktop_shell/controlcenter/live_network.zig");
const live_vpn = @import("../../desktop_shell/controlcenter/live_vpn.zig");
const clipboard = @import("../../wl/input/clipboard.zig");
const wl = @import("../../wl/c.zig").wl;

pub const wifi_tab: i32 = app_mod.TabId.wifi;
pub const wired_tab: i32 = app_mod.TabId.wired;
pub const vpn_tab: i32 = app_mod.TabId.vpn;

pub fn ownsTab(tab: i32) bool {
    return tab == wifi_tab or tab == wired_tab or tab == vpn_tab;
}

pub const Geo = struct {
    content_x: i32 = common.content_x,
    content_w: i32 = 498,
    win_w: i32 = app_mod.window_width,
    win_h: i32 = app_mod.window_height,
    scroll_px: i32 = 0,
    /// The active rail tab (17 / 18 / 28) — the page serves all three.
    tab: i32 = wifi_tab,
    /// Active Wired child page (0 Status … 5 Advanced).
    sub: i32 = 0,
};

/// Every press is applied by the page itself (the verbs are backend writes,
/// not `Settings` fields), so the window only has to repaint.
pub const Action = enum { repaint };

const k_top: i32 = common.content_top;
const k_pad: i32 = common.card_pad;
const k_gap: i32 = common.card_gap;
const k_child_top: i32 = common.child_content_top;
const k_bottom: i32 = common.spacing_xl;

const k_wifi_card_h: i32 = 100;
const k_ap_row_h: i32 = 52;
const k_ap_header_h: i32 = 52;

// ---------------------------------------------------------------------------
// VPN redesign constants (design doc §4 / §11)
// ---------------------------------------------------------------------------

const k_vpn_left_inset: i32 = 8;
const k_vpn_right_inset: i32 = 8;
const k_vpn_hero_r: f64 = 24.0;
const k_vpn_row_r: f64 = 16.0;
const k_vpn_btn_r: f64 = 12.0;
const k_vpn_row_gap: i32 = 10;
const k_vpn_hit: i32 = 44;
const k_vpn_hero_pad_x: i32 = 40;
const k_vpn_hero_pad_y: i32 = 28;
const k_vpn_row_pad_l: i32 = 20;
const k_vpn_row_pad_r: i32 = 16;
const k_vpn_gap: i32 = 16;
const k_vpn_mid_w: i32 = 260;
const k_vpn_wide_min: i32 = 820;
const k_vpn_stage_start = [_]f32{ 0.05, 0.30, 0.55, 0.85 };
const k_vpn_stage_label = [_][]const u8{ "Preparing", "Configuring", "Handshake", "Verifying" };
const k_vpn_connect_timeout_ms: i64 = 30_000;
const k_vpn_cancel_suppress_ms: i64 = 12_000;
const k_vpn_delete_confirm_ms: i64 = 4_000;
const k_vpn_auto_pending_ms: i64 = 8_000;

const VpnUi = struct {
    const text = Col{ .r = 0.9255, .g = 0.9216, .b = 0.9608 };
    const muted = Col{ .r = 0.6353, .g = 0.6314, .b = 0.7216 };
    const idle_dot = Col{ .r = 0.4196, .g = 0.4157, .b = 0.5020 };
    const accent = Col{ .r = 0.6157, .g = 0.6078, .b = 1.0 };
    const accent_text = Col{ .r = 0.7882, .g = 0.7843, .b = 1.0 };
    const on_accent = Col{ .r = 0.0431, .g = 0.0431, .b = 0.0667 };
    const ok = Col{ .r = 0.2902, .g = 0.8706, .b = 0.5020 };
    const danger_text = Col{ .r = 1.0, .g = 0.6078, .b = 0.6078 };
    const row_surface = Col{ .r = 0.0863, .g = 0.0863, .b = 0.1333 };
    const hero_surface = Col{ .r = 0.0863, .g = 0.0863, .b = 0.1333 };
    // Connected-card spec palette.
    const card_border = Col{ .r = 0.1216, .g = 0.4196, .b = 0.2902 }; // #1f6b4a
    const card_a = Col{ .r = 0.0706, .g = 0.0784, .b = 0.1647 }; // #12142a
    const card_b = Col{ .r = 0.0902, .g = 0.0745, .b = 0.1686 }; // #17132b
    const card_c = Col{ .r = 0.0784, .g = 0.0706, .b = 0.1490 }; // #141226
    const divider = Col{ .r = 0.1647, .g = 0.1765, .b = 0.2902 }; // #2a2d4a
    const shield_bg = Col{ .r = 0.0706, .g = 0.1882, .b = 0.1216 }; // #12301f
    const status = Col{ .r = 0.2392, .g = 0.8627, .b = 0.5176 }; // #3ddc84
    const copy_bg = Col{ .r = 0.1098, .g = 0.1216, .b = 0.2275 }; // #1c1f3a
    const copy_border = Col{ .r = 0.1843, .g = 0.2000, .b = 0.3451 }; // #2f3358
    const down = Col{ .r = 0.4980, .g = 0.7059, .b = 1.0 }; // #7fb4ff
    const up = Col{ .r = 1.0, .g = 0.7216, .b = 0.4196 }; // #ffb86b
    const disconnect_text = Col{ .r = 1.0, .g = 0.6039, .b = 0.6039 }; // #ff9a9a
    const disconnect_bg = Col{ .r = 0.2275, .g = 0.0941, .b = 0.1373 }; // #3a1823
    const disconnect_border = Col{ .r = 0.4784, .g = 0.1804, .b = 0.2510 }; // #7a2e40
};

fn setCol(c: *cairo.cairo_t, col: Col, a: f64) void {
    cairo.cairo_set_source_rgba(c, col.r, col.g, col.b, a);
}

fn fillRound(c: *cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, rad: f64, col: Col, a: f64) void {
    if (w <= 0 or h <= 0 or a <= 0.001) return;
    ui_paint.roundRect(c, x, y, w, h, rad);
    setCol(c, col, a);
    cairo.cairo_fill(c);
}

fn strokeRound(c: *cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, rad: f64, col: Col, a: f64) void {
    if (w <= 0 or h <= 0 or a <= 0.001) return;
    cairo.cairo_save(c);
    ui_paint.roundRect(c, x + 0.5, y + 0.5, w - 1.0, h - 1.0, @max(0.5, rad - 0.5));
    cairo.cairo_set_line_width(c, 1.0);
    setCol(c, col, a);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);
}

fn fillCircle(c: *cairo.cairo_t, cx: f64, cy: f64, rad: f64, col: Col, a: f64) void {
    setCol(c, col, a);
    cairo.cairo_arc(c, cx, cy, rad, 0, std.math.tau);
    cairo.cairo_fill(c);
}

fn strokeCircle(c: *cairo.cairo_t, cx: f64, cy: f64, rad: f64, col: Col, a: f64) void {
    cairo.cairo_save(c);
    cairo.cairo_arc(c, cx, cy, rad, 0, std.math.tau);
    cairo.cairo_set_line_width(c, 1.0);
    setCol(c, col, a);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);
}

fn fillRect(c: *cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, col: Col, a: f64) void {
    if (w <= 0 or h <= 0 or a <= 0.001) return;
    cairo.cairo_rectangle(c, x, y, w, h);
    setCol(c, col, a);
    cairo.cairo_fill(c);
}

fn colorFromRgb24(rgb: u32) Col {
    return .{
        .r = @as(f64, @floatFromInt((rgb >> 16) & 0xff)) / 255.0,
        .g = @as(f64, @floatFromInt((rgb >> 8) & 0xff)) / 255.0,
        .b = @as(f64, @floatFromInt(rgb & 0xff)) / 255.0,
    };
}

fn nowMs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * 1000 + @divTrunc(@as(i64, @intCast(@max(ts.nsec, 0))), 1_000_000);
}

/// Exit-IP lookup endpoint. The feature contacts a third party, so it has a
/// real off switch:
///   EH_VPN_EXIT_IP=0          disable completely
///   EH_VPN_EXIT_IP_URL=…      use another plain-text endpoint
/// An explicitly empty URL also disables it.
fn vpnExitEndpoint() []const u8 {
    if (std.c.getenv("EH_VPN_EXIT_IP")) |v| {
        const s = std.mem.span(v);
        if (s.len > 0 and (std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "off") or std.ascii.eqlIgnoreCase(s, "false"))) return "";
    }
    if (std.c.getenv("EH_VPN_EXIT_IP_URL")) |v| return std.mem.span(v);
    return "https://api.ipify.org";
}

fn inRect(px: f64, py: f64, r: common.Rect) bool {
    return common.pointInRect(px, py, r);
}

fn f(i: i32) f64 {
    return @floatFromInt(i);
}

/// C++ `band_label`: 2.4G / 5G / 6G by frequency.
pub fn bandLabel(freq: u32) []const u8 {
    if (freq == 0) return "";
    return if (freq < 3000) "2.4G" else if (freq < 6000) "5G" else "6G";
}

/// Action button width for an AP row — the bluetooth page's rule exactly:
/// measured label at 12/500 plus 24px, so paint and hit agree and the
/// right-aligned buttons never collide.
fn apPillW(label: []const u8) i32 {
    return ui_paint.measureTextWidth(label, 12, 500) + 24;
}

/// Signal % colour — the bluetooth page's battery ladder, so quality
/// reads at a glance.
fn signalColor(pct: i32) Col {
    if (pct <= 20) return .{ .r = 1.00, .g = 0.43, .b = 0.38 };
    if (pct <= 50) return .{ .r = 0.96, .g = 0.72, .b = 0.30 };
    return .{ .r = 0.45, .g = 0.85, .b = 0.50 };
}

// ---------------------------------------------------------------------------
// Layout models
// ---------------------------------------------------------------------------

const WifiLay = struct {
    card_x: i32,
    card_w: i32,
    toggle: common.Rect,
    scan: ?common.Rect,
    status_y: i32,
    status_h: i32,
    ap_y: i32,
    list_y: i32,
    ap_h: i32,
    right_x: i32,
    rows: usize,
    connected: bool,
};

fn wifiLay(q: ?*const live_net.SettingsSnapshot, g: Geo) WifiLay {
    const card_x = g.content_x + 8;
    const card_w = g.content_w - 16;
    const on = if (q) |s| s.wireless_enabled else true;
    const connected = if (q) |s| s.connected and s.kind == .wifi else false;
    const status_y = k_top + k_wifi_card_h + k_gap;
    const status_h: i32 = if (connected) 110 else 52;
    const ap_y = status_y + status_h + k_gap;
    const rows: usize = if (on and q != null) q.?.aps.items.len else 0;
    const right_x = card_x + card_w - k_pad;
    return .{
        .card_x = card_x,
        .card_w = card_w,
        .toggle = .{ .x = right_x - 52, .y = k_top + 10, .w = 52, .h = 26 },
        .scan = if (on) common.Rect{
            .x = right_x - 52 - common.spacing_l - 80,
            .y = k_top + 9,
            .w = 80,
            .h = 28,
        } else null,
        .status_y = status_y,
        .status_h = status_h,
        .ap_y = ap_y,
        .list_y = ap_y + k_ap_header_h,
        .ap_h = k_ap_header_h + @as(i32, @intCast(rows)) * k_ap_row_h,
        .right_x = right_x,
        .rows = rows,
        .connected = connected,
    };
}

fn apRowRect(l: WifiLay, i: usize) common.Rect {
    return .{
        .x = l.card_x + k_pad,
        .y = l.list_y + @as(i32, @intCast(i)) * k_ap_row_h,
        .w = l.card_w - 2 * k_pad,
        .h = k_ap_row_h,
    };
}

pub fn wiredPageH(sub: i32) i32 {
    return switch (sub) {
        1, 2 => 708, // IPv4/IPv6 settings + Advanced cards
        3 => 280, // Ethernet
        4 => 280, // 802.1X Security
        5 => 436, // Connection Profile + Proxy
        else => 800, // Status
    };
}

// ---------------------------------------------------------------------------
// Wi-Fi password prompt
// ---------------------------------------------------------------------------

const WifiDlg = struct {
    open: bool = false,
    ssid: [128]u8 = undefined,
    ssid_len: usize = 0,
    pw: [128]u8 = undefined,
    pw_len: usize = 0,
    hover: u8 = 0,
    press: u8 = 0,

    fn ssidText(self: *const WifiDlg) []const u8 {
        return self.ssid[0..self.ssid_len];
    }

    fn pwText(self: *const WifiDlg) []const u8 {
        return self.pw[0..self.pw_len];
    }
};

const DlgLay = struct { x: i32, y: i32, w: i32, h: i32 };

fn wifiDlgLay(win_w: i32, win_h: i32) DlgLay {
    const w: i32 = 400;
    const h: i32 = 245;
    return .{
        .x = @divTrunc(win_w - w, 2),
        .y = @divTrunc(win_h - h, 2),
        .w = w,
        .h = h,
    };
}

const WifiDlgRects = struct {
    close: common.Rect,
    field: common.Rect,
    cancel: common.Rect,
    confirm: common.Rect,
};

fn wifiDlgRects(l: DlgLay) WifiDlgRects {
    const pad: i32 = 20;
    const btn_y = l.y + l.h - pad - 36;
    const btn_right = l.x + l.w - pad;
    return .{
        .close = .{ .x = btn_right - 28, .y = l.y + pad - 4, .w = 28, .h = 28 },
        .field = .{ .x = l.x + pad, .y = l.y + pad + 88, .w = l.w - 2 * pad, .h = 36 },
        .confirm = .{ .x = btn_right - 130, .y = btn_y, .w = 130, .h = 36 },
        .cancel = .{ .x = btn_right - 130 - 10 - 100, .y = btn_y, .w = 100, .h = 36 },
    };
}

// ---------------------------------------------------------------------------
// VPN Add dialog — field/type tables (C++ parity)
// ---------------------------------------------------------------------------

const field_count = 15;

const FieldId = enum(u8) {
    name = 0,
    priv_key,
    server_pub,
    endpoint,
    allowed_ips,
    client_ip,
    dns,
    remote,
    port,
    user,
    pass,
    gateway,
    host,
    address,
    ipsec_psk,
};

const FieldSpec = struct {
    id: FieldId,
    label: []const u8,
    placeholder: []const u8,
    secret: bool = false,
    data_key: []const u8 = "",
};

const VpnTypeSpec = struct {
    label: []const u8,
    desc: []const u8,
    service_type: []const u8 = "",
    pkg: []const u8 = "",
    import_label: []const u8 = "",
    import_ext: []const u8 = "",
    fields: []const FieldSpec,
};

const wg_fields = [_]FieldSpec{
    .{ .id = .name, .label = "Connection Name", .placeholder = "My WireGuard VPN" },
    .{ .id = .priv_key, .label = "Private Key", .placeholder = "Enter private key", .secret = true },
    .{ .id = .server_pub, .label = "Server Public Key", .placeholder = "Enter server public key" },
    .{ .id = .endpoint, .label = "Endpoint", .placeholder = "host:port" },
    .{ .id = .allowed_ips, .label = "Allowed IPs", .placeholder = "0.0.0.0/0, ::/0" },
    .{ .id = .client_ip, .label = "Client IP (optional)", .placeholder = "10.0.0.2/32" },
    .{ .id = .dns, .label = "DNS (optional)", .placeholder = "1.1.1.1" },
};

const ovpn_fields = [_]FieldSpec{
    .{ .id = .name, .label = "Connection Name", .placeholder = "My OpenVPN" },
    .{ .id = .remote, .label = "Server", .placeholder = "vpn.example.com", .data_key = "remote" },
    .{ .id = .port, .label = "Port", .placeholder = "1194", .data_key = "port" },
    .{ .id = .user, .label = "Username", .placeholder = "user", .data_key = "username" },
    .{ .id = .pass, .label = "Password", .placeholder = "password", .secret = true, .data_key = "password" },
};

const ikev2_fields = [_]FieldSpec{
    .{ .id = .name, .label = "Connection Name", .placeholder = "My IKEv2" },
    .{ .id = .address, .label = "Server Address", .placeholder = "vpn.example.com", .data_key = "address" },
    .{ .id = .user, .label = "Username", .placeholder = "user", .data_key = "username" },
    .{ .id = .pass, .label = "Password", .placeholder = "password", .secret = true, .data_key = "password" },
};

const l2tp_fields = [_]FieldSpec{
    .{ .id = .name, .label = "Connection Name", .placeholder = "My L2TP" },
    .{ .id = .gateway, .label = "Gateway", .placeholder = "vpn.example.com", .data_key = "gateway" },
    .{ .id = .user, .label = "Username", .placeholder = "user", .data_key = "user" },
    .{ .id = .pass, .label = "Password", .placeholder = "password", .secret = true, .data_key = "password" },
    .{ .id = .ipsec_psk, .label = "IPsec Pre-Shared Key (optional)", .placeholder = "shared secret", .secret = true, .data_key = "ipsec-psk" },
};

const pptp_fields = [_]FieldSpec{
    .{ .id = .name, .label = "Connection Name", .placeholder = "My PPTP" },
    .{ .id = .gateway, .label = "Gateway", .placeholder = "vpn.example.com", .data_key = "gateway" },
    .{ .id = .user, .label = "Username", .placeholder = "user", .data_key = "user" },
    .{ .id = .pass, .label = "Password", .placeholder = "password", .secret = true, .data_key = "password" },
};

const anyconnect_fields = [_]FieldSpec{
    .{ .id = .name, .label = "Connection Name", .placeholder = "My AnyConnect" },
    .{ .id = .host, .label = "VPN Host", .placeholder = "vpn.example.com", .data_key = "vpnhost" },
    .{ .id = .user, .label = "Username", .placeholder = "user", .data_key = "user" },
    .{ .id = .pass, .label = "Password", .placeholder = "password", .secret = true, .data_key = "password" },
};

const vpn_types = [_]VpnTypeSpec{
    .{
        .label = "WireGuard",
        .desc = "Secure, fast point-to-point tunnel",
        .import_label = "Import .conf file",
        .import_ext = ".conf",
        .fields = &wg_fields,
    },
    .{
        .label = "OpenVPN",
        .desc = "Open-source VPN protocol",
        .service_type = "org.freedesktop.NetworkManager.openvpn",
        .pkg = "networkmanager-openvpn",
        .import_label = "Import .ovpn file",
        .import_ext = ".ovpn",
        .fields = &ovpn_fields,
    },
    .{
        .label = "IKEv2",
        .desc = "IPsec-based VPN (strongSwan)",
        .service_type = "org.freedesktop.NetworkManager.strongswan",
        .pkg = "networkmanager-strongswan",
        .fields = &ikev2_fields,
    },
    .{
        .label = "L2TP/IPsec",
        .desc = "L2TP tunneled over IPsec",
        .service_type = "org.freedesktop.NetworkManager.l2tp",
        .pkg = "networkmanager-l2tp",
        .fields = &l2tp_fields,
    },
    .{
        .label = "PPTP",
        .desc = "Legacy point-to-point tunneling",
        .service_type = "org.freedesktop.NetworkManager.pptp",
        .pkg = "networkmanager-pptp",
        .fields = &pptp_fields,
    },
    .{
        .label = "AnyConnect",
        .desc = "Cisco AnyConnect client",
        .service_type = "org.freedesktop.NetworkManager.anyconnect",
        .pkg = "networkmanager-anyconnect",
        .fields = &anyconnect_fields,
    },
};

const FieldBuf = struct {
    len: usize = 0,
    buf: [160]u8 = undefined,

    fn text(self: *const FieldBuf) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *FieldBuf, s: []const u8) void {
        const n = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
    }

    fn push(self: *FieldBuf, s: []const u8) void {
        const room = self.buf.len - self.len;
        const n = @min(s.len, room);
        if (n == 0) return;
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
    }

    fn pop(self: *FieldBuf) void {
        if (self.len == 0) return;
        self.len -= 1;
        // Drop UTF-8 continuation bytes so a pasted codepoint stays whole.
        while (self.len > 0 and (self.buf[self.len] & 0xC0) == 0x80) self.len -= 1;
    }
};

const VpnDlg = struct {
    open: bool = false,
    type_i: usize = 0,
    values: [field_count]FieldBuf = @as([field_count]FieldBuf, @splat(.{})),
    /// 0 = none, else `@intFromEnum(id) + 1`.
    focus: u8 = 0,
    hover: i32 = 0,
    press: i32 = 0,
    note: [180]u8 = undefined,
    note_len: usize = 0,

    fn val(self: *const VpnDlg, id: FieldId) []const u8 {
        return self.values[@intFromEnum(id)].text();
    }

    fn setNote(self: *VpnDlg, msg: []const u8) void {
        const n = @min(msg.len, self.note.len);
        @memcpy(self.note[0..n], msg[0..n]);
        self.note_len = n;
    }

    fn clearNote(self: *VpnDlg) void {
        self.note_len = 0;
    }

    fn focusedField(self: *const VpnDlg) ?FieldId {
        if (self.focus == 0) return null;
        const idx = self.focus - 1;
        if (idx >= field_count) return null;
        return @enumFromInt(idx);
    }

    fn fieldBuf(self: *VpnDlg, id: FieldId) *FieldBuf {
        return &self.values[@intFromEnum(id)];
    }
};

const vpn_pad: i32 = 20;
const vpn_field_h: i32 = 34;
const vpn_field_label_h: i32 = 13;
const vpn_field_gap: i32 = 7;
const vpn_field_row_gap: i32 = 12;
const vpn_row_pitch: i32 = vpn_field_label_h + vpn_field_gap + vpn_field_h + vpn_field_row_gap; // 66
const vpn_tab_h: i32 = 32;
const vpn_tab_gap: i32 = 8;
const vpn_tab_min_w: i32 = 88;
const vpn_btn_h: i32 = 34;
const vpn_title_h: i32 = 68;
const vpn_footer_h: i32 = 20;
const vpn_bottom_chrome_h: i32 = 108;
const vpn_gen_w: i32 = 88;
const vpn_gen_gap: i32 = 14;
const vpn_field_min_w: i32 = 460;

const VpnDlgLay = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    tabs: [vpn_types.len]common.Rect,
    field_top: i32,
    field_w: i32,
    btn_area_top: i32,
    add: common.Rect,
    cancel: common.Rect,
    import_btn: ?common.Rect,
    gen: ?common.Rect,
    close: common.Rect,
};

var tab_widths: [vpn_types.len]i32 = @splat(0);
var tab_widths_ready = false;

fn vpnTabWidths() [vpn_types.len]i32 {
    if (!tab_widths_ready) {
        for (vpn_types, 0..) |t, i| {
            tab_widths[i] = @max(vpn_tab_min_w, ui_paint.measureTextWidth(t.label, 11, 500) + 28);
        }
        tab_widths_ready = true;
    }
    return tab_widths;
}

pub fn vpnDialogH(type_i: usize) i32 {
    const n: i32 = @intCast(vpn_types[type_i].fields.len);
    return vpn_title_h + vpn_tab_h + vpn_pad + (n - 1) * vpn_row_pitch + vpn_field_gap +
        vpn_field_h + vpn_bottom_chrome_h;
}

fn vpnDlgLay(type_i: usize, win_w: i32, win_h: i32) VpnDlgLay {
    const tw = vpnTabWidths();
    var tabs_w: i32 = 0;
    for (tw) |w| tabs_w += w;
    tabs_w += @as(i32, @intCast(vpn_types.len - 1)) * vpn_tab_gap;
    const w = @max(vpn_field_min_w + 2 * vpn_pad, tabs_w + 2 * vpn_pad);
    const h = vpnDialogH(type_i);
    const x = @max(20, @divTrunc(win_w - w, 2));
    const y = @max(20, @divTrunc(win_h - h, 2));

    var tabs: [vpn_types.len]common.Rect = undefined;
    var tx = x + vpn_pad;
    const tab_y = y + vpn_title_h + 4;
    for (tw, 0..) |tab_w, i| {
        tabs[i] = .{ .x = tx, .y = tab_y, .w = tab_w, .h = vpn_tab_h };
        tx += tab_w + vpn_tab_gap;
    }

    const btn_area_top = y + h - vpn_footer_h - 16 - vpn_btn_h;
    const add_w: i32 = 120;
    const cancel_w: i32 = 100;
    const add = common.Rect{
        .x = x + w - vpn_pad - add_w,
        .y = btn_area_top,
        .w = add_w,
        .h = vpn_btn_h,
    };
    const cancel = common.Rect{
        .x = add.x - 10 - cancel_w,
        .y = btn_area_top,
        .w = cancel_w,
        .h = vpn_btn_h,
    };
    const spec = &vpn_types[type_i];
    const has_import = spec.import_label.len > 0;
    return .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .tabs = tabs,
        .field_top = y + vpn_title_h + vpn_tab_h + vpn_pad,
        .field_w = w - 2 * vpn_pad,
        .btn_area_top = btn_area_top,
        .add = add,
        .cancel = cancel,
        .import_btn = if (has_import) common.Rect{
            .x = x + vpn_pad,
            .y = btn_area_top,
            .w = 170,
            .h = vpn_btn_h,
        } else null,
        .gen = if (type_i == 0) common.Rect{
            .x = x + vpn_pad + (w - 2 * vpn_pad) - vpn_gen_w,
            .y = 0, // resolved per-field in fieldRect/genRect
            .w = vpn_gen_w,
            .h = vpn_field_h,
        } else null,
        .close = .{ .x = x + w - vpn_pad - 28, .y = y + vpn_pad - 6, .w = 28, .h = 28 },
    };
}

fn vpnFieldRect(l: VpnDlgLay, type_i: usize, field_i: usize) common.Rect {
    const y = l.field_top + @as(i32, @intCast(field_i)) * vpn_row_pitch + vpn_field_gap;
    var w = l.field_w;
    if (type_i == 0 and vpn_types[type_i].fields[field_i].id == .priv_key) {
        w -= vpn_gen_w + vpn_gen_gap;
    }
    return .{ .x = l.x + vpn_pad, .y = y, .w = w, .h = vpn_field_h };
}

fn vpnGenRect(l: VpnDlgLay, type_i: usize) ?common.Rect {
    if (type_i != 0) return null;
    const r = vpnFieldRect(l, type_i, 1);
    return .{
        .x = l.x + vpn_pad + l.field_w - vpn_gen_w,
        .y = r.y,
        .w = vpn_gen_w,
        .h = vpn_field_h,
    };
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

const VpnShown = enum { idle, connecting, connected, disconnecting, failed };
const VpnPhase = enum { backend, connecting, disconnecting, failed };

const VpnRow = struct {
    uuid: [64]u8 = undefined,
    uuid_len: usize = 0,
    name: [200]u8 = undefined,
    name_len: usize = 0,
    active: bool = false,
    autoconnect: bool = false,

    /// Backend snapshot carried by the live read.
    device: [64]u8 = undefined,
    device_len: usize = 0,
    tunnel: [64]u8 = undefined,
    tunnel_len: usize = 0,
    timestamp: i64 = 0,
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
    sample_ms: i64 = 0,
    rx_bps: u64 = 0,
    tx_bps: u64 = 0,
    hist_rx: [60]u64 = @splat(0),
    hist_tx: [60]u64 = @splat(0),
    hist_n: u8 = 0,
    hist_i: u8 = 0,

    /// UI state machine. `backend` follows the live roster; the other three
    /// are transient overrides owned by the page.
    phase: VpnPhase = .backend,
    progress: f32 = 0,
    connect_started_ms: i64 = 0,
    settle_until_ms: i64 = 0,
    disconnect_started_ms: i64 = 0,
    active_since_ms: i64 = 0,
    suppress_active_until_ms: i64 = 0,
    fail_buf: [160]u8 = undefined,
    fail_len: usize = 0,

    /// Public exit address, cached for this connection session.
    exit_buf: [64]u8 = undefined,
    exit_len: usize = 0,
    exit_failed: bool = false,
    exit_requested: bool = false,
    exit_started_ms: i64 = 0,

    /// Cached wrapped-name line count for the current content width. Layout
    /// runs three times a frame (height, paint, hit) and a Pango measure per
    /// row per pass would be wasteful.
    name_lines: u8 = 0,
    name_lines_w: i32 = -1,
    name_size: f32 = 15,

    /// Optimistic auto-toggle window (the write is a detached nmcli verb).
    pending_auto: bool = false,
    auto_target: bool = false,
    auto_since: i64 = 0,
    auto_error_until_ms: i64 = 0,
    auto_error_buf: [96]u8 = undefined,
    auto_error_len: usize = 0,

    fn uuidText(self: *const VpnRow) []const u8 {
        return self.uuid[0..self.uuid_len];
    }

    fn nameText(self: *const VpnRow) []const u8 {
        return self.name[0..self.name_len];
    }

    fn deviceText(self: *const VpnRow) []const u8 {
        return self.device[0..self.device_len];
    }

    fn tunnelText(self: *const VpnRow) []const u8 {
        return self.tunnel[0..self.tunnel_len];
    }

    fn failText(self: *const VpnRow) []const u8 {
        return self.fail_buf[0..self.fail_len];
    }

    fn exitText(self: *const VpnRow) []const u8 {
        return self.exit_buf[0..self.exit_len];
    }

    fn autoErrorText(self: *const VpnRow) []const u8 {
        return self.auto_error_buf[0..self.auto_error_len];
    }

    fn setUuid(self: *VpnRow, s: []const u8) void {
        const n = @min(s.len, self.uuid.len);
        @memcpy(self.uuid[0..n], s[0..n]);
        self.uuid_len = n;
    }

    fn setName(self: *VpnRow, s: []const u8) void {
        const n = @min(s.len, self.name.len);
        @memcpy(self.name[0..n], s[0..n]);
        self.name_len = n;
    }

    fn setDevice(self: *VpnRow, s: []const u8) void {
        const n = @min(s.len, self.device.len);
        @memcpy(self.device[0..n], s[0..n]);
        self.device_len = n;
    }

    fn setTunnel(self: *VpnRow, s: []const u8) void {
        const n = @min(s.len, self.tunnel.len);
        @memcpy(self.tunnel[0..n], s[0..n]);
        self.tunnel_len = n;
    }

    fn setFail(self: *VpnRow, s: []const u8) void {
        const n = @min(s.len, self.fail_buf.len);
        @memcpy(self.fail_buf[0..n], s[0..n]);
        self.fail_len = n;
    }

    fn clearFail(self: *VpnRow) void {
        self.fail_len = 0;
    }

    fn setExit(self: *VpnRow, s: []const u8, ok: bool) void {
        const n = @min(s.len, self.exit_buf.len);
        @memcpy(self.exit_buf[0..n], s[0..n]);
        self.exit_len = if (ok) n else 0;
        self.exit_failed = !ok;
    }

    fn clearExit(self: *VpnRow) void {
        self.exit_len = 0;
        self.exit_failed = false;
        self.exit_requested = false;
        self.exit_started_ms = 0;
    }

    fn nameLineCount(self: *VpnRow, wrap_w: i32) u8 {
        if (self.name_lines_w == wrap_w and self.name_lines > 0) return self.name_lines;
        const w = @max(20, wrap_w);
        var step: u8 = 0;
        while (step <= 7) : (step += 1) {
            const size: f32 = 15.0 - @as(f32, @floatFromInt(step)) * 0.5;
            if (ui_paint.measureTextWidth(self.nameText(), size, 600) <= w) {
                self.name_size = size;
                self.name_lines = 1;
                self.name_lines_w = wrap_w;
                return 1;
            }
        }
        self.name_size = 11.5;
        const n = ui_paint.measureWrappedLines(self.nameText(), 11.5, 600, w);
        self.name_lines = @intCast(@max(1, @min(n, 6)));
        self.name_lines_w = wrap_w;
        return self.name_lines;
    }

    fn shownAuto(self: *const VpnRow, now: i64) bool {
        if (self.pending_auto and now - self.auto_since < k_vpn_auto_pending_ms) return self.auto_target;
        return self.autoconnect;
    }

    fn shownState(self: *const VpnRow, now: i64) VpnShown {
        if (now < self.suppress_active_until_ms) return .idle;
        return switch (self.phase) {
            .backend => if (self.active) .connected else .idle,
            .connecting => blk: {
                if (self.active and self.settle_until_ms != 0 and now >= self.settle_until_ms) break :blk .connected;
                break :blk .connecting;
            },
            .disconnecting => .disconnecting,
            .failed => .failed,
        };
    }

    /// Uptime in ms. `connection.timestamp` is the real activation wall
    /// clock, so an already-connected row is right on first paint; the
    /// observed monotonic instant is the fallback.
    fn uptimeMs(self: *const VpnRow, now: i64) i64 {
        if (self.phase != .backend and self.phase != .connecting) return 0;
        if (!self.active) return 0;
        const base = if (self.timestamp > 0) self.timestamp * 1000 else self.active_since_ms;
        if (base <= 0) return 0;
        return @max(0, now - base);
    }

    fn stage(self: *const VpnRow, now: i64) u8 {
        if (self.active) return 3;
        const elapsed = @max(0, now - self.connect_started_ms);
        if (elapsed < 700) return 0;
        if (elapsed < 2200) return 1;
        if (elapsed < 5000) return 2;
        return 3;
    }

    fn updateThroughput(self: *VpnRow, rx: u64, tx: u64, now: i64) void {
        if (!self.active) {
            self.rx_bytes = 0;
            self.tx_bytes = 0;
            self.sample_ms = 0;
            self.rx_bps = 0;
            self.tx_bps = 0;
            self.hist_n = 0;
            self.hist_i = 0;
            return;
        }
        if (self.sample_ms == 0 or now <= self.sample_ms or rx < self.rx_bytes or tx < self.tx_bytes) {
            self.rx_bytes = rx;
            self.tx_bytes = tx;
            self.sample_ms = now;
            return;
        }
        const dt_ms = now - self.sample_ms;
        if (dt_ms >= 250) {
            const drx = rx - self.rx_bytes;
            const dtx = tx - self.tx_bytes;
            const drx_bps = @divTrunc(drx * 1000, @as(u64, @intCast(dt_ms)));
            const dtx_bps = @divTrunc(dtx * 1000, @as(u64, @intCast(dt_ms)));
            self.hist_rx[self.hist_i] = drx_bps;
            self.hist_tx[self.hist_i] = dtx_bps;
            self.hist_i = @intCast((@as(usize, self.hist_i) + 1) % self.hist_rx.len);
            if (@as(usize, self.hist_n) < self.hist_rx.len) self.hist_n += 1;
            // Keep the displayed rate responsive: average the newest three
            // samples, while the full ring feeds the sparkline.
            const smooth_n = @min(self.hist_n, 3);
            var sx: u64 = 0;
            var st: u64 = 0;
            var k: usize = 0;
            while (k < smooth_n) : (k += 1) {
                const idx = (self.hist_i + self.hist_rx.len - 1 - k) % self.hist_rx.len;
                sx += self.hist_rx[idx];
                st += self.hist_tx[idx];
            }
            self.rx_bps = sx / smooth_n;
            self.tx_bps = st / smooth_n;
            self.rx_bytes = rx;
            self.tx_bytes = tx;
            self.sample_ms = now;
        }
    }

    fn observeBackend(self: *VpnRow, was_active: bool, now: i64) void {
        if (self.active) {
            if (self.phase == .failed) {
                self.phase = .backend;
                self.clearFail();
                self.clearExit();
            }
            if (self.phase == .backend) {
                if (!was_active or self.active_since_ms == 0) {
                    self.active_since_ms = if (self.timestamp > 0) self.timestamp * 1000 else now;
                }
            } else if (self.phase == .connecting) {
                if (self.settle_until_ms == 0) self.settle_until_ms = now + 300;
                if (self.uptimeMs(now) == 0 and self.active_since_ms == 0) {
                    self.active_since_ms = if (self.timestamp > 0) self.timestamp * 1000 else now;
                }
            }
        } else {
            if (self.phase == .disconnecting) {
                self.phase = .backend;
                self.clearFail();
                self.clearExit();
                self.active_since_ms = 0;
            } else if (self.phase == .backend and was_active) {
                self.phase = .failed;
                self.setFail("Connection lost");
                self.clearExit();
                self.active_since_ms = 0;
            } else if (self.phase == .backend) {
                self.active_since_ms = 0;
            }
        }
    }
};

const VpnFocusKind = enum { add, hero_copy, hero_disconnect, row_auto, row_action, row_delete };

const VpnFocus = struct {
    kind: VpnFocusKind,
    row: usize = 0,

    fn eql(a: VpnFocus, b: VpnFocus) bool {
        return a.kind == b.kind and a.row == b.row;
    }
};

const VpnRowLay = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    dot_x: i32 = 0,
    dot_y: i32 = 0,
    name_x: i32 = 0,
    name_y: i32 = 0,
    name_w: i32 = 0,
    status_y: i32 = 0,
    mid_x: i32 = 0,
    mid_y: i32 = 0,
    mid_w: i32 = 0,
    auto_hit: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    auto_switch: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    action: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    delete: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

const VpnHeroCellKind = enum { identity, ip, connected, tunnel, throughput, action };

const VpnHeroCell = struct {
    kind: VpnHeroCellKind = .identity,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    pad_l: i32 = 0,
    pad_r: i32 = 0,
    divider: bool = false,
};

const VpnLay = struct {
    compact: bool = false,
    page_x: i32 = 0,
    page_w: i32 = 0,
    header_h: i32 = 0,
    add: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    hero: bool = false,
    hero_y: i32 = 0,
    hero_h: i32 = 0,
    hero_row: usize = 0,
    hero_cells: [9]VpnHeroCell = @splat(.{}),
    hero_cells_n: usize = 0,
    hero_split: bool = false,
    hero_sparkline: bool = false,
    hero_rates_stacked: bool = false,
    hero_name_size: f32 = 38,
    hero_iface_size: f32 = 20,
    hero_ip_size: f32 = 44,
    hero_value_size: f32 = 34,
    hero_rate_size: f32 = 24,
    hero_pad_x: i32 = 40,
    hero_pad_y: i32 = 28,
    hero_button_w: i32 = 180,
    hero_button_h: i32 = 60,
    hero_copy: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    hero_disconnect: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    section_y: i32 = 0,
    section_h: i32 = 0,
    list_y: i32 = 0,
    status_y: i32 = 0,
    status_h: i32 = 0,
    total_h: i32 = 0,
    rows_n: usize = 0,
};

const VpnBtnKind = enum { primary, secondary, danger, ghost };

pub const Page = struct {
    alloc: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    inited: bool = false,
    /// Last rail tab the page was laid out/painted for (guards the modals
    /// against surviving a sidebar switch).
    cur_tab: i32 = wifi_tab,

    /// Latest D-Bus snapshot. `have_q` guards `deinit` — the snapshot's own
    /// `deinit` invalidates the struct.
    q: live_net.SettingsSnapshot = undefined,
    have_q: bool = false,
    last_query_ms: i64 = 0,
    last_vpn_req_ms: i64 = 0,

    scan_until_ms: i64 = 0,
    /// Request-time `LastScan` baseline from the scan worker; the Scanning
    /// label ends when a snapshot's `wifi_last_scan` passes it (0 = pending
    /// or unknown, covered by the wall-clock cap above).
    scan_baseline: u64 = 0,

    vpn_rows: std.ArrayList(VpnRow) = .empty,
    /// True once at least one VPN poll answered, so an empty list is not
    /// mistaken for "not read yet".
    vpn_have: bool = false,
    /// UUIDs with a delete in flight — hidden until NM stops reporting them
    /// (the C++ page's `s_removing` set; four are enough for click bursts).
    removing: [4][64]u8 = undefined,
    removing_len: [4]usize = @splat(0),
    /// When each marker was set; a failed `nmcli delete` must not hide the
    /// row forever (the poll re-adds it after the window).
    removing_at: [4]i64 = @splat(0),
    removing_n: usize = 0,
    /// Button top edge after the last Wired Status paint (the reference puts
    /// Disconnect under the final row; hit-testing reuses the painted edge).
    wired_btn_y: i32 = 0,

    wifi: WifiDlg = .{},
    vpn: VpnDlg = .{},

    /// VPN keyboard focus (ordinal into the visual order) and transient
    /// interaction state.
    vpn_focus: i32 = -1,
    /// True once focus was moved by the keyboard; mouse clicks suppress the
    /// ring without discarding the focus target.
    vpn_keyboard: bool = false,
    vpn_delete_uuid: [64]u8 = undefined,
    vpn_delete_len: usize = 0,
    vpn_delete_until_ms: i64 = 0,
    vpn_copy_until_ms: i64 = 0,
    vpn_exit_url: []const u8 = "",
    vpn_clip: clipboard.Service = undefined,
    vpn_clip_ready: bool = false,

    /// Layout filled by `layoutVpn`, shared by paint / hit / focus. Capped at
    /// 64 saved VPNs; beyond that the scroll list still works but focus and
    /// hit only cover the visible prefix (nobody has that many).
    vpn_row_lay: [64]VpnRowLay = @splat(.{}),
    vpn_lay: VpnLay = .{},
    /// Last Network geometry seen by height/paint/hit, so the keyboard handler
    /// (which has no geometry argument) can lay the page out itself.
    cur_geo: Geo = .{},

    status_buf: [220]u8 = undefined,
    status_len: usize = 0,
    status_failed: bool = false,
    status_until_ms: i64 = 0,
    /// Which card the line belongs to — VPN writes land under the VPN card,
    /// a scan failure under the Wi-Fi card.
    status_src: enum(u8) { none, vpn, scan } = .none,

    pick_buf: [1024]u8 = undefined,

    pub fn init(self: *Page, alloc: std.mem.Allocator, io: std.Io) void {
        self.* = .{ .alloc = alloc, .io = io };
        self.vpn_clip = clipboard.Service.init(alloc);
        self.vpn_exit_url = vpnExitEndpoint();
        self.inited = true;
        live_vpn.clearStatus();
        // The first layout/paint pass on a Network tab queries immediately
        // (`last_query_ms` starts at 0); no need to block window startup on a
        // D-Bus round trip the user may never open.
    }

    pub fn deinit(self: *Page) void {
        if (!self.inited) return;
        self.vpn_rows.deinit(self.alloc);
        if (self.have_q) self.q.deinit();
        self.have_q = false;
        self.vpn_clip.deinit();
        live_vpn.shutdown();
        self.inited = false;
    }

    /// The settings window owns the data-control manager/seat; hand them to
    /// the page once the registry is bound so Copy can write the selection.
    pub fn bindClipboard(self: *Page, manager: *anyopaque, backend: clipboard.Backend, seat: ?*wl.wl_seat, display: ?*wl.wl_display) void {
        if (!self.inited) return;
        self.vpn_clip_ready = self.vpn_clip.bind(manager, backend, seat, display);
    }

    fn qPtr(self: *Page) ?*const live_net.SettingsSnapshot {
        return if (self.have_q) &self.q else null;
    }

    fn scanning(self: *const Page) bool {
        if (nowMs() >= self.scan_until_ms) return false;
        // Faithful to the reference: `Scanning` ends when a snapshot reports
        // `LastScan` newer than the request-time baseline — the label tracks
        // the real scan, not a blind timer. The wall-clock window is only a
        // safety cap so a wedged device cannot hold the button forever.
        if (self.scan_baseline != 0 and self.have_q) {
            if (self.q.wifi_last_scan > self.scan_baseline) return false;
        }
        return true;
    }

    /// Poll the live backends. Throttled: the D-Bus snapshot every 1.5 s and
    /// the nmcli VPN read every 2 s, plus the non-blocking drains. Safe to
    /// call from every layout/paint/hit pass.
    fn refresh(self: *Page, force: bool) void {
        if (!self.inited) return;
        const now = nowMs();
        // Scan result first: a failed request reverts the button at once, and
        // a completed one is worth an immediate re-read instead of waiting
        // out the 1.5 s snapshot tick.
        var scan_force = false;
        {
            var sbuf: [96]u8 = undefined;
            var ok = false;
            var baseline: u64 = 0;
            if (live_net.takeScanResult(&sbuf, &ok, &baseline)) |n| {
                // The request-time `LastScan` baseline is what ends the
                // button's Scanning state once a snapshot passes it.
                self.scan_baseline = if (ok) baseline else 0;
                if (ok) {
                    scan_force = true;
                } else {
                    const c_len = @min(n, self.status_buf.len);
                    @memcpy(self.status_buf[0..c_len], sbuf[0..c_len]);
                    self.status_len = c_len;
                    self.status_failed = true;
                    self.status_src = .scan;
                    self.status_until_ms = now + 6000;
                    self.scan_until_ms = 0;
                }
            }
        }
        if (force or scan_force or now - self.last_query_ms >= 1500) {
            self.last_query_ms = now;
            if (live_net.settingsQuery(self.alloc)) |q| {
                if (self.have_q) self.q.deinit();
                self.q = q;
                self.have_q = true;
            }
        }
        // The VPN page wants throughput once a second; the other Network
        // pages can stay on the cheaper two-second roster poll.
        const vpn_interval: i64 = if (self.cur_tab == vpn_tab) 1000 else 2000;
        if (force or now - self.last_vpn_req_ms >= vpn_interval) {
            self.last_vpn_req_ms = now;
            _ = live_vpn.request(self.alloc, self.io);
        }
        var landed: ?[]live_vpn.Connection = null;
        if (live_vpn.take(&landed)) {
            if (landed) |rows| {
                self.adoptVpn(rows);
                live_vpn.freeConnections(self.alloc, rows);
            }
        }
        // Detached verb outcomes: connect failures move the row to Failed
        // before the 30 s timeout, auto failures revert immediately, and a
        // failed delete releases its optimistic hiding marker.
        while (live_vpn.takeVerbResult()) |res| {
            switch (res.kind) {
                .up => {
                    if (!res.ok) {
                        if (self.findVpn(res.uuidText())) |cr| {
                            const r: *VpnRow = @constCast(cr);
                            if (r.phase == .connecting) {
                                r.phase = .failed;
                                r.setFail(connectReason(res.msgText()));
                                r.progress = 0;
                            }
                        }
                    }
                },
                .down, .cancel => {},
                .auto => {
                    if (self.findVpn(res.uuidText())) |cr| {
                        const r: *VpnRow = @constCast(cr);
                        if (r.pending_auto) {
                            if (!res.ok) {
                                r.pending_auto = false;
                                const msg = if (res.msgText().len > 0) res.msgText() else "Could not update auto-connect";
                                const n = @min(msg.len, r.auto_error_buf.len);
                                @memcpy(r.auto_error_buf[0..n], msg[0..n]);
                                r.auto_error_len = n;
                                r.auto_error_until_ms = now + 4000;
                            } else {
                                r.pending_auto = false;
                                r.autoconnect = r.auto_target;
                            }
                        }
                    }
                },
                .delete => {
                    if (!res.ok) {
                        self.forgetRemoving(res.uuidText());
                        const msg = if (res.msgText().len > 0) res.msgText() else "Could not delete the VPN";
                        const n = @min(msg.len, self.status_buf.len);
                        @memcpy(self.status_buf[0..n], msg[0..n]);
                        self.status_len = n;
                        self.status_failed = true;
                        self.status_src = .vpn;
                        self.status_until_ms = now + 6000;
                    }
                },
            }
        }
        if (live_vpn.takeExitIp()) |x| {
            if (self.findVpn(x.uuidText())) |cr| {
                const r: *VpnRow = @constCast(cr);
                if (r.active or r.phase == .connecting) r.setExit(x.textText(), x.ok);
            }
        }
        self.tickVpn(now);
        var sbuf: [220]u8 = undefined;
        var failed = false;
        if (live_vpn.takeStatus(&sbuf, &failed)) |n| {
            @memcpy(self.status_buf[0..n], sbuf[0..n]);
            self.status_len = n;
            self.status_failed = failed;
            self.status_src = .vpn;
            self.status_until_ms = now + 6000;
        }
    }

    fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > hay.len) return false;
        var i: usize = 0;
        while (i + needle.len <= hay.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    fn connectReason(raw: []const u8) []const u8 {
        if (raw.len == 0) return "Connection failed";
        if (containsIgnoreCase(raw, "secret") or containsIgnoreCase(raw, "auth")) return "Authentication failed";
        if (containsIgnoreCase(raw, "timeout") or containsIgnoreCase(raw, "timed out")) return "Connection timed out";
        if (containsIgnoreCase(raw, "not found") or containsIgnoreCase(raw, "does not exist")) return "Connection no longer exists";
        return raw;
    }

    fn forgetRemoving(self: *Page, uuid: []const u8) void {
        for (self.removing[0..self.removing_n], 0..) |u, i| {
            if (!std.mem.eql(u8, u[0..self.removing_len[i]], uuid)) continue;
            var j = i;
            while (j + 1 < self.removing_n) : (j += 1) {
                self.removing[j] = self.removing[j + 1];
                self.removing_len[j] = self.removing_len[j + 1];
                self.removing_at[j] = self.removing_at[j + 1];
            }
            self.removing_n -= 1;
            return;
        }
    }

    /// Advance every transient VPN state from the wall clock. Called from
    /// `refresh` on each layout/paint, and therefore at 16 ms while the page
    /// reports `animating()`.
    fn tickVpn(self: *Page, now: i64) void {
        if (self.vpn_delete_len > 0 and now >= self.vpn_delete_until_ms) self.clearDeleteConfirm();
        for (self.vpn_rows.items) |*r| {
            switch (r.phase) {
                .connecting => {
                    if (r.active) {
                        r.progress = 1.0;
                        if (r.settle_until_ms == 0) r.settle_until_ms = now + 300;
                        if (now >= r.settle_until_ms) {
                            r.phase = .backend;
                            r.active_since_ms = if (r.timestamp > 0) r.timestamp * 1000 else now;
                        }
                    } else if (now - r.connect_started_ms >= k_vpn_connect_timeout_ms) {
                        r.phase = .failed;
                        r.setFail("Connection timed out");
                        r.progress = 0;
                        live_vpn.cancelThread(self.io, r.uuidText());
                    } else {
                        const stage = r.stage(now);
                        const lo = k_vpn_stage_start[stage];
                        const hi: f32 = if (stage + 1 < k_vpn_stage_start.len) k_vpn_stage_start[stage + 1] else 1.0;
                        const secs = @as(f32, @floatFromInt(@max(0, now - r.connect_started_ms))) / 1000.0;
                        const target = lo + (hi - lo) * 0.9 * (1.0 - @exp(-secs / 3.0));
                        if (target > r.progress) r.progress = target;
                        if (r.progress < k_vpn_stage_start[0]) r.progress = k_vpn_stage_start[0];
                        if (r.progress > 0.995) r.progress = 0.995;
                    }
                },
                .disconnecting => {
                    if (!r.active) {
                        r.phase = .backend;
                        r.clearFail();
                        r.clearExit();
                        r.active_since_ms = 0;
                    } else if (now - r.disconnect_started_ms >= 12000) {
                        r.phase = .failed;
                        r.setFail("Disconnect timed out");
                    }
                },
                .backend => {
                    if (r.active) {
                        if (r.active_since_ms == 0) r.active_since_ms = if (r.timestamp > 0) r.timestamp * 1000 else now;
                        self.tickExit(r, now);
                    }
                },
                .failed => {},
            }
            // A failed public-IP lookup is a UI fact, not a backend fact.
            if (r.phase == .backend and r.active and r.exit_len == 0 and !r.exit_failed and
                r.exit_requested and now - r.exit_started_ms >= 5000)
            {
                r.exit_failed = true;
            }
            // Cancel can take a moment to queue behind the activation verb;
            // once it lands the row is idle. Suppress a brief active blip so
            // Cancel does not flash Connected.
            if (r.suppress_active_until_ms > 0 and now >= r.suppress_active_until_ms) r.suppress_active_until_ms = 0;
        }
    }

    fn tickExit(self: *Page, r: *VpnRow, now: i64) void {
        if (self.vpn_exit_url.len == 0 or r.exit_len > 0 or r.exit_failed or r.exit_requested) return;
        if (r.phase != .backend or !r.active) return;
        r.exit_started_ms = now;
        if (live_vpn.requestExitIp(self.io, r.uuidText(), self.vpn_exit_url)) {
            r.exit_requested = true;
        }
    }

    pub fn animating(self: *const Page) bool {
        if (self.cur_tab != vpn_tab) return false;
        for (self.vpn_rows.items) |*r| {
            const now = nowMs();
            if (r.shownState(now) == .connecting) return true;
            if (r.phase == .connecting) return true;
            if (self.vpn_copy_until_ms > now) return true;
        }
        return false;
    }

    fn findVpn(self: *const Page, uuid: []const u8) ?*const VpnRow {
        for (self.vpn_rows.items) |*r| {
            if (std.mem.eql(u8, r.uuidText(), uuid)) return r;
        }
        return null;
    }

    fn markRemoving(self: *Page, uuid: []const u8) void {
        for (self.removing[0..self.removing_n], 0..) |u, i| {
            if (std.mem.eql(u8, u[0..self.removing_len[i]], uuid)) return;
        }
        if (self.removing_n >= self.removing.len) return;
        const i = self.removing_n;
        const n = @min(uuid.len, self.removing[i].len);
        @memcpy(self.removing[i][0..n], uuid[0..n]);
        self.removing_len[i] = n;
        self.removing_at[i] = nowMs();
        self.removing_n += 1;
    }

    fn isRemoving(self: *const Page, uuid: []const u8) bool {
        for (self.removing[0..self.removing_n], 0..) |u, i| {
            if (std.mem.eql(u8, u[0..self.removing_len[i]], uuid)) return true;
        }
        return false;
    }

    /// UUID-anchored reconcile: the roster order is the backend's name
    /// order, while every transient UI field (phase, progress, focus, exit
    /// IP, throughput history, delete arm) is carried across by UUID so a
    /// poll can never make the page jump or lose a connecting animation.
    fn adoptVpn(self: *Page, rows: []const live_vpn.Connection) void {
        const now = nowMs();
        // Retire delete markers once NM stops reporting the UUID.
        var keep: [4][64]u8 = undefined;
        var keep_len: [4]usize = @splat(0);
        var keep_at: [4]i64 = @splat(0);
        var keep_n: usize = 0;
        for (self.removing[0..self.removing_n], 0..) |u, ui| {
            const uu = u[0..self.removing_len[ui]];
            var still = false;
            for (rows) |c| {
                if (std.mem.eql(u8, c.uuid, uu)) {
                    still = true;
                    break;
                }
            }
            const fresh = now - self.removing_at[ui] < 8000;
            if (still and fresh and keep_n < keep.len) {
                keep[keep_n] = u;
                keep_len[keep_n] = self.removing_len[ui];
                keep_at[keep_n] = self.removing_at[ui];
                keep_n += 1;
            }
        }
        self.removing = keep;
        self.removing_len = keep_len;
        self.removing_at = keep_at;
        self.removing_n = keep_n;

        var out: std.ArrayList(VpnRow) = .empty;
        for (rows) |c| {
            if (self.isRemoving(c.uuid)) continue;
            var r: VpnRow = if (self.findVpn(c.uuid)) |old| old.* else .{};
            const was_active = r.active;
            r.setUuid(c.uuid);
            r.setName(c.name);
            r.setDevice(c.device);
            r.setTunnel(c.tunnel_ip);
            r.active = c.active;
            r.autoconnect = c.autoconnect;
            r.timestamp = c.timestamp;
            r.updateThroughput(c.rx_bytes, c.tx_bytes, now);
            r.observeBackend(was_active, now);
            out.append(self.alloc, r) catch {};
        }
        self.vpn_rows.deinit(self.alloc);
        self.vpn_rows = out;
        self.vpn_have = true;

        // A profile that vanished (deleted elsewhere) must not leave a stale
        // confirm prompt behind.
        if (self.vpn_delete_len > 0 and self.findVpn(self.vpn_delete_uuid[0..self.vpn_delete_len]) == null) {
            self.vpn_delete_len = 0;
            self.vpn_delete_until_ms = 0;
        }
    }

    pub fn totalHeight(self: *Page, g: Geo) i32 {
        self.cur_tab = g.tab;
        self.refresh(false);
        // Like the placed pages, the extent is measured from the scroll
        // clip's layout top (`Content.y0()`), so the last card keeps the
        // usual bottom pad instead of gaining the top offset again.
        if (g.tab == wired_tab) {
            const h: i32 = if (g.sub == 0 and (self.qPtr() == null or !self.q.wired.present))
                120
            else
                wiredPageH(g.sub);
            return h + k_bottom;
        }
        if (g.tab == vpn_tab) {
            self.cur_geo = g;
            return self.layoutVpn(g).total_h;
        }
        const l = wifiLay(self.qPtr(), g);
        const q = self.qPtr();
        const on = if (q) |s| s.wireless_enabled else true;
        if (!on) return k_wifi_card_h + k_bottom;
        return (l.ap_y - k_top) + l.ap_h + k_bottom;
    }

    // -----------------------------------------------------------------
    // Paint
    // -----------------------------------------------------------------

    pub fn paint(self: *Page, c: *cairo.cairo_t, g: Geo, px: f64, ly: f64, glass_ov: f64) void {
        self.cur_tab = g.tab;
        self.refresh(false);
        // A dialog belongs to one rail page; a sidebar switch (rare while a
        // modal is up, but possible) dismisses it rather than leaving an
        // invisible click-blocker behind.
        if (g.tab != wifi_tab) self.wifi.open = false;
        if (g.tab != vpn_tab) self.vpn.open = false;

        switch (g.tab) {
            wifi_tab => self.paintWifi(c, g, px, ly, glass_ov),
            wired_tab => self.paintWired(c, g, glass_ov),
            vpn_tab => self.paintVpn(c, g, px, ly, glass_ov),
            else => {},
        }

        if (self.wifi.open and g.tab == wifi_tab) {
            cairo.cairo_save(c);
            cairo.cairo_translate(c, 0, f(g.scroll_px));
            cairo.cairo_reset_clip(c);
            self.paintWifiModal(c, g);
            cairo.cairo_restore(c);
        }
        if (self.vpn.open and g.tab == vpn_tab) {
            cairo.cairo_save(c);
            cairo.cairo_translate(c, 0, f(g.scroll_px));
            cairo.cairo_reset_clip(c);
            self.paintVpnModal(c, g);
            cairo.cairo_restore(c);
        }
    }

    // -----------------------------------------------------------------
    // Wi-Fi
    // -----------------------------------------------------------------

    fn paintWifi(self: *Page, c: *cairo.cairo_t, g: Geo, px: f64, ly: f64, glass_ov: f64) void {
        const t = common.Theme;
        const q = self.qPtr();
        const l = wifiLay(q, g);
        const on = if (q) |s| s.wireless_enabled else true;

        ui_paint.card(c, f(l.card_x), f(k_top), f(l.card_w), f(k_wifi_card_h), glass_ov);
        ui_paint.showText(c, f(l.card_x + k_pad), f(k_top + 30), "Wi-Fi", 14, 700, t.text_r, t.text_g, t.text_b, 1.0);
        ui_paint.paintSwitch(c, l.toggle.x, l.toggle.y, l.toggle.w, l.toggle.h, on);

        if (l.scan) |sr| {
            const hovered = inRect(px, ly, sr);
            if (self.scanning()) {
                ui_paint.paintBtnDisabled(c, sr.x, sr.y, sr.w, sr.h, "Scanning");
            } else {
                ui_paint.paintBtn(c, sr.x, sr.y, sr.w, sr.h, "Scan", hovered);
            }
        }
        // A failed scan request explains itself right here (the C++ error
        // line lives in the same card), in red.
        if (self.status_src == .scan and self.status_len > 0 and nowMs() < self.status_until_ms) {
            ui_paint.showTextW(
                c,
                f(l.card_x + k_pad),
                f(k_top + 64),
                self.status_buf[0..self.status_len],
                11,
                400,
                f(l.card_w - 2 * k_pad),
                0.95,
                0.35,
                0.30,
                0.9,
            );
        }

        if (!on) return;

        // Connection status card.
        ui_paint.card(c, f(l.card_x), f(l.status_y), f(l.card_w), f(l.status_h), glass_ov);
        if (l.connected) {
            const s = q.?;
            ui_paint.showText(c, f(l.card_x + k_pad), f(l.status_y + 30), "Connected to Wi-Fi", 14, 700, t.acc_r, t.acc_g, t.acc_b, 1.0);
            ui_paint.glyph(c, f(l.card_x + l.card_w - k_pad - 30), f(l.status_y + 62), 28, "wifi", t.text_r, t.text_g, t.text_b, 0.85);
            ui_paint.showText(c, f(l.card_x + k_pad), f(l.status_y + 58), s.ssid, 13, 400, t.text_r, t.text_g, t.text_b, 1.0);
            var pbuf: [16]u8 = undefined;
            const pct = std.fmt.bufPrint(&pbuf, "{d}%", .{@max(0, s.signal_pct)}) catch "";
            ui_paint.showText(c, f(l.card_x + k_pad + 4), f(l.status_y + 78), pct, 10, 400, t.text_r, t.text_g, t.text_b, 1.0);
            if (s.iface.len > 0) {
                var ibuf: [192]u8 = undefined;
                const line = std.fmt.bufPrint(&ibuf, "Interface: {s}", .{s.iface}) catch s.iface;
                ui_paint.showText(c, f(l.card_x + k_pad), f(l.status_y + 98), line, 11, 400, t.text_r, t.text_g, t.text_b, 1.0);
            }
        } else {
            ui_paint.showText(c, f(l.card_x + k_pad), f(l.status_y + 30), "Not connected", 13, 400, t.text_r, t.text_g, t.text_b, 1.0);
        }

        // Access points.
        ui_paint.card(c, f(l.card_x), f(l.ap_y), f(l.card_w), f(l.ap_h), glass_ov);
        ui_paint.showText(c, f(l.card_x + k_pad), f(l.ap_y + 30), "Available Networks", 14, 700, t.text_r, t.text_g, t.text_b, 1.0);

        const aps = if (q) |s| s.aps.items else &.{};
        for (aps, 0..) |ap, i| {
            if (i >= l.rows) break;
            const row = apRowRect(l, i);
            // Bluetooth-list hover: a flat 5% wash across the card, no box.
            if (inRect(px, ly, row)) {
                cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.05);
                cairo.cairo_rectangle(c, f(l.card_x), f(row.y), f(l.card_w), f(row.h));
                cairo.cairo_fill(c);
            }
            const cy = row.y + @divTrunc(k_ap_row_h, 2);
            ui_paint.glyph(c, f(row.x + 20), f(cy), 20, "wifi", t.text_r, t.text_g, t.text_b, 1.0);

            // Right side first: the bluetooth rows' outlined button —
            // auto-width from the measured label at 12/500, vertically
            // centred, one spacing_s inside the card's right edge; the
            // left text run keeps clear of it.
            const label = if (ap.active) "Disconnect" else "Connect";
            const act_h: i32 = 24;
            const act_y: i32 = row.y + @divTrunc(k_ap_row_h - act_h, 2);
            const act_w = apPillW(label);
            const act_x: i32 = l.right_x - common.spacing_s - act_w;
            const run_max = f(act_x) - 20.0;

            // SSID + band + security + signal %, one inline run like the
            // bluetooth alias + battery line; the % borrows the battery
            // colour ladder so quality reads at a glance.
            const run_left = f(row.x + 48);
            const ssid_max = run_max - run_left;
            ui_paint.showTextW(c, run_left, f(cy + 6), ap.ssid, 13, 400, ssid_max, t.text_r, t.text_g, t.text_b, 1.0);
            var lx = run_left + @min(f(ui_paint.measureTextWidth(ap.ssid, 13, 400)), ssid_max) + 4.0;
            const band = bandLabel(ap.frequency);
            if (band.len > 0) {
                const bw = f(ui_paint.measureTextWidth(band, 9, 400));
                if (lx + bw + 20.0 <= run_max) {
                    ui_paint.showText(c, lx, f(cy + 4), band, 9, 400, t.text_r, t.text_g, t.text_b, 1.0);
                    lx += bw + 4.0;
                }
            }
            const sec = ap.security.label();
            if (sec.len > 0) {
                const sw = f(ui_paint.measureTextWidth(sec, 9, 400));
                if (lx + sw + 20.0 <= run_max) {
                    ui_paint.showText(c, lx, f(cy + 4), sec, 9, 400, t.text_r, t.text_g, t.text_b, 1.0);
                    lx += sw + 6.0;
                }
            }
            var pbuf: [16]u8 = undefined;
            const pct = std.fmt.bufPrint(&pbuf, "{d}%", .{ap.strength}) catch "";
            if (pct.len > 0) {
                const pw = f(ui_paint.measureTextWidth(pct, 10, 400));
                if (lx + pw + 4.0 <= run_max) {
                    const sc = signalColor(@as(i32, ap.strength));
                    ui_paint.showText(c, lx, f(cy + 5), pct, 10, 500, sc.r, sc.g, sc.b, 0.95);
                }
            }

            const act_hov = inRect(px, ly, .{ .x = act_x, .y = act_y, .w = act_w, .h = act_h });
            ui_paint.paintBtn(c, act_x, act_y, act_w, act_h, label, act_hov);
        }
    }

    fn paintWifiModal(self: *Page, c: *cairo.cairo_t, g: Geo) void {
        const t = common.Theme;
        const l = wifiDlgLay(g.win_w, g.win_h);
        const r = wifiDlgRects(l);
        const pad: i32 = 20;

        cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.42);
        cairo.cairo_rectangle(c, 0, 0, f(g.win_w), f(g.win_h));
        cairo.cairo_fill(c);

        ui_paint.glassBox(c, f(l.x), f(l.y), f(l.w), f(l.h), 16, t.bg_r, t.bg_g, t.bg_b, 0.97);
        cairo.cairo_save(c);
        ui_paint.roundRect(c, f(l.x) + 0.5, f(l.y) + 0.5, f(l.w) - 1, f(l.h) - 1, 15.5);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.35);
        cairo.cairo_stroke(c);
        cairo.cairo_restore(c);

        ui_paint.glyph(c, f(l.x + pad + 11), f(l.y + pad + 14), 22, "lock", t.acc_r, t.acc_g, t.acc_b, 0.95);
        ui_paint.showText(c, f(l.x + pad + 40), f(l.y + pad + 22), "Connect to Wi-Fi", 17, 700, t.text_r, t.text_g, t.text_b, 1.0);
        const close_hov = self.wifi.hover == 3;
        ui_paint.glassBox(c, f(r.close.x), f(r.close.y), f(r.close.w), f(r.close.h), 8, t.bg_r, t.bg_g, t.bg_b, if (close_hov) 0.62 else 0.45);
        const close_a: f64 = if (close_hov) 1.0 else 0.8;
        ui_paint.glyph(c, f(r.close.x + 14), f(r.close.y + 14), 18, "close", t.text_r, t.text_g, t.text_b, close_a);

        var nb: [192]u8 = undefined;
        const net = std.fmt.bufPrint(&nb, "Network: {s}", .{self.wifi.ssidText()}) catch self.wifi.ssidText();
        ui_paint.showText(c, f(l.x + pad), f(l.y + pad + 52), net, 13, 400, t.text_r, t.text_g, t.text_b, 1.0);
        ui_paint.showText(c, f(l.x + pad), f(l.y + pad + 74), "Enter password", 11.5, 400, t.text_r, t.text_g, t.text_b, 1.0);
        paintField(c, r.field, self.wifi.pwText(), "", true, true);

        const has_pw = self.wifi.pw_len > 0;
        ui_paint.paintBtn(c, r.cancel.x, r.cancel.y, r.cancel.w, r.cancel.h, "Cancel", self.wifi.hover == 1);
        if (has_pw) {
            ui_paint.paintBtn(c, r.confirm.x, r.confirm.y, r.confirm.w, r.confirm.h, "Confirm", self.wifi.hover == 2);
        } else {
            ui_paint.paintBtnDisabled(c, r.confirm.x, r.confirm.y, r.confirm.w, r.confirm.h, "Confirm");
        }
    }

    fn hitWifi(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        const q = self.qPtr();
        const l = wifiLay(q, g);
        if (inRect(px, ly, l.toggle)) {
            const on = if (q) |s| s.wireless_enabled else true;
            _ = live_net.setWifiEnabled(self.io, !on);
            self.scan_until_ms = 0;
            self.scan_baseline = 0;
            self.refresh(true);
            return .repaint;
        }
        if (l.scan) |sr| {
            if (inRect(px, ly, sr) and !self.scanning()) {
                live_net.rescanThread();
                // Fresh request, fresh baseline: the worker publishes the
                // request-time `LastScan` with the outcome a moment later.
                self.scan_baseline = 0;
                self.scan_until_ms = nowMs() + 15000;
                return .repaint;
            }
        }
        const s = q orelse return null;
        if (!s.wireless_enabled) return null;
        for (s.aps.items, 0..) |ap, i| {
            if (i >= l.rows) break;
            if (!inRect(px, ly, apRowRect(l, i))) continue;
            if (ap.active) {
                live_net.disconnectThread(self.io, s.iface);
            } else if (ap.secured and !s.hasSaved(ap.ssid)) {
                self.openWifiPrompt(ap.ssid);
            } else {
                live_net.connectThread(self.io, ap.ssid, "");
            }
            return .repaint;
        }
        return null;
    }

    fn openWifiPrompt(self: *Page, ssid: []const u8) void {
        const n = @min(ssid.len, self.wifi.ssid.len);
        @memcpy(self.wifi.ssid[0..n], ssid[0..n]);
        self.wifi.ssid_len = n;
        self.wifi.pw_len = 0;
        self.wifi.hover = 0;
        self.wifi.press = 0;
        self.wifi.open = true;
    }

    fn submitWifi(self: *Page) void {
        if (self.wifi.pw_len == 0) return;
        live_net.connectThread(self.io, self.wifi.ssidText(), self.wifi.pwText());
        self.wifi.open = false;
    }

    // -----------------------------------------------------------------
    // Wired
    // -----------------------------------------------------------------

    fn paintWired(self: *Page, c: *cairo.cairo_t, g: Geo, glass_ov: f64) void {
        const q = self.qPtr();
        switch (g.sub) {
            0 => self.paintWiredStatus(c, g, q, glass_ov),
            1 => self.paintIpv4(c, g, glass_ov),
            2 => self.paintIpv6(c, g, glass_ov),
            3 => self.paintEthernet(c, g, glass_ov),
            4 => self.paintSecurity(c, g, glass_ov),
            5 => self.paintAdvanced(c, g, glass_ov),
            else => {},
        }
    }

    fn paintWiredStatus(self: *Page, c: *cairo.cairo_t, g: Geo, q: ?*const live_net.SettingsSnapshot, glass_ov: f64) void {
        const t = common.Theme;
        const cx = g.content_x + 8;
        const cw = g.content_w - 16;
        const present = if (q) |s| s.wired.present else false;
        if (!present) {
            self.wired_btn_y = 0;
            ui_paint.card(c, f(cx), f(k_child_top), f(cw), 120, glass_ov);
            ui_paint.catLabel(c, f(cx + k_pad), f(k_child_top + 22), "Wired Connection");
            ui_paint.showText(c, f(cx + k_pad), f(k_child_top + 52 + 16), "No wired device found", 13, 400, t.text_r, t.text_g, t.text_b, 0.46);
            return;
        }
        const d = &q.?.wired;
        ui_paint.card(c, f(cx), f(k_child_top), f(cw), 800, glass_ov);
        ui_paint.catLabel(c, f(cx + k_pad), f(k_child_top + 22), "Wired Connection");

        var row_y: i32 = k_child_top + 52;
        addWiredRow(c, cx, &row_y, "Interface", d.interface);
        addWiredRow(c, cx, &row_y, "Status", if (d.carrier) "Connected" else "Disconnected");
        if (d.speed > 0) {
            var sbuf: [32]u8 = undefined;
            const speed = std.fmt.bufPrint(&sbuf, "{d} Mbps", .{d.speed}) catch "";
            addWiredRow(c, cx, &row_y, "Speed", speed);
        }
        addWiredRow(c, cx, &row_y, "Duplex", d.duplex);
        addWiredRow(c, cx, &row_y, "Auto-negotiate", if (d.auto_negotiate) "Yes" else "No");
        addWiredRow(c, cx, &row_y, "MAC", d.hw_address);
        addWiredRow(c, cx, &row_y, "Permanent MAC", d.perm_hw_address);
        addWiredRow(c, cx, &row_y, "IPv4", d.ipv4);
        addWiredRow(c, cx, &row_y, "Gateway", d.ipv4_gateway);
        addWiredRow(c, cx, &row_y, "IPv6", d.ipv6);
        addWiredRow(c, cx, &row_y, "IPv6 Gateway", d.ipv6_gateway);
        for (d.dns[0..d.dns_len], 0..) |v, i| {
            addWiredRow(c, cx, &row_y, if (i == 0) "DNS" else "", v);
        }
        for (d.domains[0..d.domains_len], 0..) |v, i| {
            addWiredRow(c, cx, &row_y, if (i == 0) "Search domain" else "", v);
        }
        addWiredRow(c, cx, &row_y, "Driver", d.driver);
        addWiredRow(c, cx, &row_y, "Driver version", d.driver_version);
        addWiredRow(c, cx, &row_y, "Firmware", d.firmware_version);
        addWiredRow(c, cx, &row_y, "Vendor", d.vendor);
        addWiredRow(c, cx, &row_y, "Product", d.product);
        if (d.mtu > 0) {
            var mbuf: [24]u8 = undefined;
            const mtu = std.fmt.bufPrint(&mbuf, "{d}", .{d.mtu}) catch "";
            addWiredRow(c, cx, &row_y, "MTU", mtu);
        }
        if (d.device_state > 0) {
            var sbuf: [24]u8 = undefined;
            const ds = std.fmt.bufPrint(&sbuf, "{d}", .{d.device_state}) catch "";
            addWiredRow(c, cx, &row_y, "Device state", ds);
        }

        if (d.carrier and (q.?.kind == .wired)) {
            self.wired_btn_y = row_y + 8;
            const br = self.wiredDisconnectRect(g);
            ui_paint.paintBtn(c, br.x, br.y, br.w, br.h, "Disconnect", false);
        } else {
            self.wired_btn_y = 0;
        }
    }

    fn wiredDisconnectRect(self: *Page, g: Geo) common.Rect {
        const cx = g.content_x + 8;
        const cw = g.content_w - 16;
        // The reference places Disconnect under the final row (`rowY + 8`),
        // so the button follows the device report.
        return .{
            .x = cx + cw - k_pad - 100,
            .y = if (self.wired_btn_y > 0) self.wired_btn_y else k_child_top + 800 - k_pad - 30,
            .w = 100,
            .h = 30,
        };
    }

    fn paintIpv4(self: *Page, c: *cairo.cairo_t, g: Geo, glass_ov: f64) void {
        _ = self;
        const card_x = g.content_x + 8;
        const card_w = g.content_w - 16;
        const h0 = 52 + 4 * common.slider_row_h + common.spacing_xl;
        ui_paint.card(c, f(card_x), f(k_child_top), f(card_w), f(h0), glass_ov);
        ui_paint.catLabel(c, f(card_x + k_pad), f(k_child_top + 15), "IPv4 Settings");
        const band = k_child_top + 52;
        paintWiredSlider(c, card_x, card_w, band + 0 * common.slider_row_h, "DNS priority", 0, -100, 100);
        paintWiredSlider(c, card_x, card_w, band + 1 * common.slider_row_h, "DHCP timeout (s)", 30, 0, 120);
        paintWiredToggle(c, card_x, card_w, band, 2, true, "Send hostname", "Send hostname to DHCP server");
        paintWiredToggle(c, card_x, card_w, band, 3, false, "Ignore auto DNS", "Use manual DNS only");

        const cy1 = k_child_top + h0 + k_gap;
        ui_paint.card(c, f(card_x), f(cy1), f(card_w), f(h0), glass_ov);
        ui_paint.catLabel(c, f(card_x + k_pad), f(cy1 + 15), "Advanced");
        const aband = cy1 + 52;
        paintWiredToggle(c, card_x, card_w, aband, 0, false, "Never use as default route", "Do not set as default gateway");
        paintWiredToggle(c, card_x, card_w, aband, 1, true, "May fail", "Connection succeeds even if IPv4 fails");
        paintWiredSlider(c, card_x, card_w, aband + 2 * common.slider_row_h, "Route metric", 100, 0, 10000);
        paintWiredSlider(c, card_x, card_w, aband + 3 * common.slider_row_h, "Required timeout (ms)", 5000, 0, 60000);
    }

    fn paintIpv6(self: *Page, c: *cairo.cairo_t, g: Geo, glass_ov: f64) void {
        _ = self;
        const card_x = g.content_x + 8;
        const card_w = g.content_w - 16;
        const h0 = 52 + 3 * common.slider_row_h + common.spacing_xl;
        ui_paint.card(c, f(card_x), f(k_child_top), f(card_w), f(h0), glass_ov);
        ui_paint.catLabel(c, f(card_x + k_pad), f(k_child_top + 15), "IPv6 Settings");
        const band = k_child_top + 52;
        paintWiredSlider(c, card_x, card_w, band + 0 * common.slider_row_h, "DNS priority", 0, -100, 100);
        paintWiredSlider(c, card_x, card_w, band + 1 * common.slider_row_h, "DHCP timeout (s)", 30, 0, 120);
        paintWiredSlider(c, card_x, card_w, band + 2 * common.slider_row_h, "RA timeout (s)", 0, 0, 60);

        const cy1 = k_child_top + h0 + k_gap;
        const h1 = 52 + 5 * common.slider_row_h + common.spacing_xl;
        ui_paint.card(c, f(card_x), f(cy1), f(card_w), f(h1), glass_ov);
        ui_paint.catLabel(c, f(card_x + k_pad), f(cy1 + 15), "Advanced");
        const aband = cy1 + 52;
        paintWiredToggle(c, card_x, card_w, aband, 0, true, "Send hostname", "Send hostname to DHCP server");
        paintWiredToggle(c, card_x, card_w, aband, 1, false, "Ignore auto DNS", "Use manual DNS only");
        paintWiredToggle(c, card_x, card_w, aband, 2, false, "Never use as default route", "Do not set as default gateway");
        paintWiredToggle(c, card_x, card_w, aband, 3, true, "May fail", "Connection succeeds even if IPv6 fails");
        paintWiredSlider(c, card_x, card_w, aband + 4 * common.slider_row_h, "Route metric", 100, 0, 10000);
    }

    fn paintEthernet(self: *Page, c: *cairo.cairo_t, g: Geo, glass_ov: f64) void {
        _ = self;
        const card_x = g.content_x + 8;
        const card_w = g.content_w - 16;
        const h0 = 52 + 3 * common.slider_row_h + common.spacing_xl;
        ui_paint.card(c, f(card_x), f(k_child_top), f(card_w), f(h0), glass_ov);
        ui_paint.catLabel(c, f(card_x + k_pad), f(k_child_top + 15), "Ethernet");
        const band = k_child_top + 52;
        paintWiredSlider(c, card_x, card_w, band + 0 * common.slider_row_h, "MTU", 1500, 68, 9000);
        paintWiredToggle(c, card_x, card_w, band, 1, true, "Auto-negotiate", "Automatically negotiate speed and duplex");
        paintWiredToggle(c, card_x, card_w, band, 2, false, "Accept all MACs", "Accept frames from any MAC address");
    }

    fn paintSecurity(self: *Page, c: *cairo.cairo_t, g: Geo, glass_ov: f64) void {
        _ = self;
        const t = common.Theme;
        const card_x = g.content_x + 8;
        const card_w = g.content_w - 16;
        const h0 = 52 + 3 * common.slider_row_h + common.spacing_xl;
        ui_paint.card(c, f(card_x), f(k_child_top), f(card_w), f(h0), glass_ov);
        ui_paint.catLabel(c, f(card_x + k_pad), f(k_child_top + 15), "802.1X Security");
        const band = k_child_top + 52;
        paintWiredToggle(c, card_x, card_w, band, 0, false, "Enable 802.1X", "Use IEEE 802.1X authentication");
        paintWiredToggle(c, card_x, card_w, band, 1, true, "System CA certificates", "Use system CA certificate store");
        const note_y = k_child_top + 52 + 2 * common.slider_row_h + 12;
        ui_paint.showTextW(
            c,
            f(card_x + k_pad),
            f(note_y),
            "Text entry fields (EAP method, identity, password) require keyboard input support.",
            12,
            400,
            f(card_w - 2 * k_pad),
            t.text_r,
            t.text_g,
            t.text_b,
            0.46,
        );
    }

    fn paintAdvanced(self: *Page, c: *cairo.cairo_t, g: Geo, glass_ov: f64) void {
        _ = self;
        const t = common.Theme;
        const card_x = g.content_x + 8;
        const card_w = g.content_w - 16;
        const h0 = 52 + 2 * common.slider_row_h + common.spacing_xl;
        ui_paint.card(c, f(card_x), f(k_child_top), f(card_w), f(h0), glass_ov);
        ui_paint.catLabel(c, f(card_x + k_pad), f(k_child_top + 15), "Connection Profile");
        const band = k_child_top + 52;
        paintWiredToggle(c, card_x, card_w, band, 0, true, "Auto-connect", "Automatically connect to this network");
        paintWiredSlider(c, card_x, card_w, band + 1 * common.slider_row_h, "Auto-connect priority", 0, -1000, 1000);

        const cy1 = k_child_top + h0 + k_gap;
        ui_paint.card(c, f(card_x), f(cy1), f(card_w), f(h0), glass_ov);
        ui_paint.catLabel(c, f(card_x + k_pad), f(cy1 + 15), "Proxy");
        const pband = cy1 + 52;
        paintWiredToggle(c, card_x, card_w, pband, 0, false, "Browser only", "Proxy applies to browser only");
        ui_paint.showTextW(
            c,
            f(card_x + k_pad),
            f(pband + common.slider_row_h + 12),
            "Proxy text fields (PAC URL, HTTP/HTTPS/SOCKS) require keyboard input support.",
            12,
            400,
            f(card_w - 2 * k_pad),
            t.text_r,
            t.text_g,
            t.text_b,
            0.46,
        );
    }

    fn hitWired(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        if (g.sub != 0) return null;
        const q = self.qPtr() orelse return null;
        if (!q.wired.present or !q.wired.carrier or q.kind != .wired) return null;
        if (!inRect(px, ly, self.wiredDisconnectRect(g))) return null;
        live_net.disconnectThread(self.io, q.wired.interface);
        return .repaint;
    }

    // -----------------------------------------------------------------
    // VPN page
    // -----------------------------------------------------------------

    fn heroIndex(self: *const Page, now: i64) ?usize {
        for (self.vpn_rows.items, 0..) |*r, i| {
            if (r.shownState(now) == .connected) return i;
        }
        return null;
    }

    fn heroAddCell(
        l: *VpnLay,
        kind: VpnHeroCellKind,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        pad_l: i32,
        pad_r: i32,
        divider: bool,
    ) void {
        if (l.hero_cells_n >= l.hero_cells.len) return;
        l.hero_cells[l.hero_cells_n] = .{
            .kind = kind,
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .pad_l = pad_l,
            .pad_r = pad_r,
            .divider = divider,
        };
        l.hero_cells_n += 1;
    }

    fn fitHeroNameSize(r: *const VpnRow, start: f32, max_w: i32) f32 {
        var size = start;
        while (size > 20.0 and ui_paint.measureTextWidth(r.nameText(), size, 600) > max_w) {
            size -= 2.0;
        }
        return size;
    }

    fn fitHeroIpSize(str: []const u8, start: f32, max_w: i32) f32 {
        var size = start;
        while (size > 22.0 and ui_paint.measureMonoTextWidth(str, size, 500) > max_w) {
            size -= 2.0;
        }
        return size;
    }

    /// Single-row connected card from `vpn-connected-card.md`: six dividered
    /// cells, one flex throughput cell, 220px fixed height. Narrower widths
    /// drop the sparkline, then Tunnel, then Connected for, and only then
    /// shrink the identity cell.
    fn layoutVpnHeroRow(self: *Page, l: *VpnLay, r: *const VpnRow, page_x: i32, page_w: i32) void {
        l.hero_split = false;
        l.hero_h = 220;
        l.hero_pad_x = 40;
        l.hero_pad_y = 28;
        l.hero_name_size = 38;
        l.hero_iface_size = 20;
        l.hero_ip_size = 44;
        l.hero_value_size = 24;
        l.hero_rate_size = 24;
        l.hero_button_w = 180;
        l.hero_button_h = 60;

        const inner_x = page_x + l.hero_pad_x;
        const inner_w = page_w - 2 * l.hero_pad_x;
        const inner_y = l.hero_y + l.hero_pad_y;
        const inner_h = l.hero_h - 2 * l.hero_pad_y;

        const show_tunnel = page_w >= 1888;
        const show_connected = page_w >= 1668;
        const action_w: i32 = 188;
        var identity_w: i32 = 480;
        var fixed = identity_w + 480 + (if (show_connected) @as(i32, 220) else 0) +
            (if (show_tunnel) @as(i32, 220) else 0) + action_w;
        var throughput_w = inner_w - fixed;
        if (throughput_w < 220) {
            const deficit = 220 - throughput_w;
            identity_w = @max(232, identity_w - deficit);
            fixed = identity_w + 480 + (if (show_connected) @as(i32, 220) else 0) +
                (if (show_tunnel) @as(i32, 220) else 0) + action_w;
            throughput_w = inner_w - fixed;
        }
        if (throughput_w < 180) {
            // Caller normally chooses the split layout below 1200px; keep a
            // safety net so a very narrow page never produces negative cells.
            self.layoutVpnHeroSplit(l, r, page_x, page_w);
            return;
        }

        const throughput_content = throughput_w - 80;
        l.hero_sparkline = throughput_content >= 300;
        l.hero_rates_stacked = throughput_content < 300;

        // Identity name shrinks only after cells have been dropped.
        const identity_text_w = identity_w - 40 - 76 - 24;
        l.hero_name_size = fitHeroNameSize(r, 38, @max(60, identity_text_w));

        var x = inner_x;
        heroAddCell(l, .identity, x, inner_y, identity_w, inner_h, 0, 40, false);
        x += identity_w;
        heroAddCell(l, .ip, x, inner_y, 480, inner_h, 40, 40, true);

        const ip_x = x;
        const ip_str = if (r.exit_len > 0) r.exitText() else "Unavailable";
        const ip_max_w = 480 - 80 - 12 - 44;
        l.hero_ip_size = fitHeroIpSize(ip_str, 44, ip_max_w);
        const ip_w = ui_paint.measureMonoTextWidth(ip_str, l.hero_ip_size, 500);
        const ip_h: i32 = @intFromFloat(@as(f64, l.hero_ip_size) * 1.45);
        const ip_content_h: i32 = 24 + 10 + @max(ip_h, 44);
        const ip_top = inner_y + @divTrunc(inner_h - ip_content_h, 2);
        if (r.exit_len > 0) {
            l.hero_copy = .{
                .x = ip_x + 40 + ip_w + 12,
                .y = ip_top + 24 + 10 + @divTrunc(ip_h - 44, 2),
                .w = 44,
                .h = 44,
            };
        }
        x += 480;

        if (show_connected) {
            heroAddCell(l, .connected, x, inner_y, 220, inner_h, 24, 24, true);
            x += 220;
        }
        if (show_tunnel) {
            heroAddCell(l, .tunnel, x, inner_y, 220, inner_h, 24, 24, true);
            x += 220;
        }
        heroAddCell(l, .throughput, x, inner_y, throughput_w, inner_h, 40, 40, true);

        const action_x = inner_x + inner_w - action_w;
        heroAddCell(l, .action, action_x, inner_y, action_w, inner_h, 0, 0, false);
        l.hero_disconnect = .{
            .x = action_x + action_w - l.hero_button_w,
            .y = inner_y + @divTrunc(inner_h - l.hero_button_h, 2),
            .w = l.hero_button_w,
            .h = l.hero_button_h,
        };
    }

    /// Two-row fallback used at half-screen and below. Keeps every datum:
    /// identity / VPN IP / Disconnect in row one, the remaining stats in row
    /// two. The card grows vertically instead of clipping fixed cells.
    fn layoutVpnHeroSplit(self: *Page, l: *VpnLay, r: *const VpnRow, page_x: i32, page_w: i32) void {
        _ = self;
        l.hero_split = true;
        l.hero_h = 300;
        l.hero_pad_x = 32;
        l.hero_pad_y = 24;
        l.hero_name_size = 32;
        l.hero_iface_size = 16;
        l.hero_ip_size = 40;
        l.hero_value_size = 28;
        l.hero_rate_size = 18;
        l.hero_button_w = 160;
        l.hero_button_h = 52;
        l.hero_sparkline = false;
        l.hero_rates_stacked = false;

        const inner_x = page_x + l.hero_pad_x;
        const inner_w = page_w - 2 * l.hero_pad_x;
        const inner_y = l.hero_y + l.hero_pad_y;
        const inner_h = l.hero_h - 2 * l.hero_pad_y;
        const row1_h: i32 = 122;
        const row_gap: i32 = 16;
        const row2_y = inner_y + row1_h + row_gap;
        const row2_h = inner_h - row1_h - row_gap;

        const action_w: i32 = 172;
        const ip_w = @min(@as(i32, 470), @max(@as(i32, 300), inner_w - action_w - 280));
        const identity_w = inner_w - ip_w - action_w;

        const identity_text_w = identity_w - 24 - 64 - 18;
        l.hero_name_size = fitHeroNameSize(r, 32, @max(60, identity_text_w));

        heroAddCell(l, .identity, inner_x, inner_y, identity_w, row1_h, 0, 24, false);
        heroAddCell(l, .ip, inner_x + identity_w, inner_y, ip_w, row1_h, 24, 16, true);
        const action_x = inner_x + inner_w - action_w;
        heroAddCell(l, .action, action_x, inner_y, action_w, row1_h, 0, 0, true);

        const ip_str = if (r.exit_len > 0) r.exitText() else "Unavailable";
        const ip_max_w = ip_w - 24 - 16 - 12 - 44;
        l.hero_ip_size = fitHeroIpSize(ip_str, 40, @max(60, ip_max_w));
        const ip_text_w = ui_paint.measureMonoTextWidth(ip_str, l.hero_ip_size, 500);
        const ip_h: i32 = @intFromFloat(@as(f64, l.hero_ip_size) * 1.45);
        const ip_content_h: i32 = 20 + 8 + @max(ip_h, 44);
        const ip_top = inner_y + @divTrunc(row1_h - ip_content_h, 2);
        if (r.exit_len > 0) {
            l.hero_copy = .{
                .x = inner_x + identity_w + 24 + ip_text_w + 12,
                .y = ip_top + 20 + 8 + @divTrunc(ip_h - 44, 2),
                .w = 44,
                .h = 44,
            };
        }

        l.hero_disconnect = .{
            .x = action_x + action_w - l.hero_button_w,
            .y = inner_y + @divTrunc(row1_h - l.hero_button_h, 2),
            .w = l.hero_button_w,
            .h = l.hero_button_h,
        };

        const third = @divTrunc(inner_w, 3);
        heroAddCell(l, .connected, inner_x, row2_y, third, row2_h, 24, 24, false);
        heroAddCell(l, .tunnel, inner_x + third, row2_y, third, row2_h, 24, 24, true);
        heroAddCell(l, .throughput, inner_x + 2 * third, row2_y, inner_w - 2 * third, row2_h, 24, 24, true);
    }

    fn layoutVpn(self: *Page, g: Geo) VpnLay {
        const now = nowMs();
        // A delete confirmation is a four-second modal affordance on the row.
        if (self.vpn_delete_len > 0 and now >= self.vpn_delete_until_ms) {
            self.vpn_delete_len = 0;
            self.vpn_delete_until_ms = 0;
        }

        const page_x = g.content_x + k_vpn_left_inset;
        const page_w = @max(280, g.content_w - k_vpn_left_inset - k_vpn_right_inset);
        const compact = page_w < k_vpn_wide_min;
        var l = VpnLay{
            .compact = compact,
            .page_x = page_x,
            .page_w = page_w,
        };

        // Header: title + subtitle on the left, Add VPN on the right.
        const add_w = @max(ui_paint.measureTextWidth("Add VPN", 13, 600) + 44, 118);
        const add_h: i32 = 44;
        l.add = .{ .x = page_x + page_w - add_w, .y = k_top + 2, .w = add_w, .h = add_h };
        l.header_h = 56 + 24;

        // Connected hero. Only a row that has actually reached Connected
        // owns the hero; connecting and failed rows stay in the list.
        if (self.heroIndex(now)) |hi| {
            const hr = &self.vpn_rows.items[hi];
            l.hero = true;
            l.hero_row = hi;
            l.hero_y = k_top + l.header_h;
            l.hero_cells_n = 0;
            if (page_w >= 1200) {
                self.layoutVpnHeroRow(&l, hr, page_x, page_w);
            } else {
                self.layoutVpnHeroSplit(&l, hr, page_x, page_w);
            }
        }

        const header_bottom = k_top + l.header_h;
        l.section_y = if (l.hero) l.hero_y + l.hero_h + 24 else header_bottom;
        l.list_y = l.section_y + 30;

        var y = l.list_y;
        const n = @min(self.vpn_rows.items.len, self.vpn_row_lay.len);
        l.rows_n = n;
        for (self.vpn_rows.items[0..n], 0..) |*r, i| {
            const state = r.shownState(now);
            const row_x = page_x;
            const row_w = page_w;
            const pad_l: i32 = 20;
            const pad_r: i32 = 16;
            const right = row_x + row_w - pad_r;
            const action_w: i32 = 124;
            const auto_w: i32 = 96;
            const delete_rect = common.Rect{ .x = right - 44, .y = 0, .w = 44, .h = 44 };
            const action_rect = common.Rect{ .x = delete_rect.x - 12 - action_w, .w = action_w, .h = 44, .y = 0 };
            const auto_rect = common.Rect{ .x = action_rect.x - 12 - auto_w, .w = auto_w, .h = 44, .y = 0 };
            const name_x = row_x + 42;

            var rl = VpnRowLay{
                .x = row_x,
                .y = y,
                .w = row_w,
                .dot_x = row_x + pad_l,
                .name_x = name_x,
            };

            if (compact) {
                rl.name_w = @max(120, auto_rect.x - name_x - 12);
                const lines = r.nameLineCount(rl.name_w);
                const name_h = @as(i32, lines) * 20;
                const auto_error = r.auto_error_until_ms > now and state != .connecting;
                if (state == .connecting) {
                    rl.name_y = y + 16;
                    rl.mid_x = name_x;
                    rl.mid_y = rl.name_y + name_h + 12;
                    rl.mid_w = right - name_x;
                    rl.h = (rl.mid_y - y) + 42 + 12;
                    rl.status_y = rl.mid_y;
                } else if (state == .failed or auto_error) {
                    rl.name_y = y + 16;
                    rl.status_y = rl.name_y + name_h + 2;
                    rl.h = @max(@as(i32, 84), (rl.status_y - y) + 18 + 16);
                } else {
                    rl.h = @max(@as(i32, 72), 16 + name_h + 16);
                    rl.name_y = y + @divTrunc(rl.h - name_h, 2);
                    rl.status_y = rl.name_y + name_h + 2;
                }
                rl.dot_y = if (state == .connecting or state == .failed or auto_error)
                    rl.name_y + 10
                else
                    y + @divTrunc(rl.h, 2);
                const cy = y + @divTrunc(rl.h - 44, 2);
                rl.action = .{ .x = action_rect.x, .y = cy, .w = action_w, .h = 44 };
                rl.delete = .{ .x = delete_rect.x, .y = cy, .w = 44, .h = 44 };
                rl.auto_hit = .{ .x = auto_rect.x, .y = cy, .w = auto_w, .h = 44 };
            } else {
                const mid_x = auto_rect.x - 16 - k_vpn_mid_w;
                const want_mid = state == .connecting;
                const name_avail = if (want_mid) mid_x - name_x - 16 else auto_rect.x - 16 - name_x;
                rl.name_w = @max(120, name_avail);
                const lines = r.nameLineCount(rl.name_w);
                const auto_error = r.auto_error_until_ms > now and state != .connecting;
                const status_h: i32 = if (state == .failed or auto_error) 20 else 0;
                const min_h: i32 = if (state == .failed or auto_error or want_mid) 84 else 72;
                rl.h = @max(min_h, @as(i32, lines) * 20 + status_h + 32);
                const content_h = @as(i32, lines) * 20 + status_h;
                rl.name_y = y + @divTrunc(rl.h - content_h, 2);
                rl.status_y = rl.name_y + @as(i32, lines) * 20 + 2;
                rl.dot_y = if (status_h > 0) rl.name_y + 10 else y + @divTrunc(rl.h, 2);
                rl.mid_x = mid_x;
                rl.mid_y = y + @divTrunc(rl.h, 2) - 26;
                rl.mid_w = k_vpn_mid_w;
                const cy = y + @divTrunc(rl.h - 44, 2);
                rl.action = .{ .x = action_rect.x, .y = cy, .w = action_w, .h = 44 };
                rl.delete = .{ .x = delete_rect.x, .y = cy, .w = 44, .h = 44 };
                rl.auto_hit = .{ .x = auto_rect.x, .y = cy, .w = auto_w, .h = 44 };
            }
            rl.auto_switch = .{
                .x = rl.auto_hit.x + 48,
                .y = rl.auto_hit.y + 10,
                .w = 40,
                .h = 24,
            };
            self.vpn_row_lay[i] = rl;
            y += rl.h + k_vpn_row_gap;
        }
        if (n == 0) y += 96;

        const list_end = if (n == 0) y else y - k_vpn_row_gap;
        l.status_y = list_end + 20;
        l.status_h = 26;
        l.total_h = @max(list_end, l.status_y + l.status_h) - k_top + k_bottom;
        self.vpn_lay = l;
        return l;
    }

    // ---- formatting -----------------------------------------------------

    fn fmtUptime(ms: i64) []const u8 {
        const S = struct {
            var buf: [24]u8 = undefined;
        };
        const secs = @divTrunc(@max(0, ms), 1000);
        const h = @divTrunc(secs, 3600);
        const m = @divTrunc(@mod(secs, 3600), 60);
        const s = @mod(secs, 60);
        return std.fmt.bufPrint(&S.buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "00:00:00";
    }

    fn fmtRate(bps: u64) []const u8 {
        const S = struct {
            var buf: [32]u8 = undefined;
        };
        if (bps >= 1_000_000) {
            const tenths = bps / 100_000;
            return std.fmt.bufPrint(&S.buf, "{d}.{d} MB/s", .{ tenths / 10, tenths % 10 }) catch "0 B/s";
        }
        if (bps >= 1_000) {
            return std.fmt.bufPrint(&S.buf, "{d} KB/s", .{bps / 1_000}) catch "0 B/s";
        }
        return std.fmt.bufPrint(&S.buf, "{d} B/s", .{bps}) catch "0 B/s";
    }

    fn fmtSaved(n: usize) []const u8 {
        const S = struct {
            var buf: [32]u8 = undefined;
        };
        return std.fmt.bufPrint(&S.buf, "{d} saved", .{n}) catch "0 saved";
    }

    fn fmtPercent(p: f32) []const u8 {
        const S = struct {
            var buf: [8]u8 = undefined;
        };
        const pct: i32 = @intFromFloat(@round(@min(@max(p, 0.0), 1.0) * 100.0));
        return std.fmt.bufPrint(&S.buf, "{d}%", .{pct}) catch "0%";
    }

    fn fmtInterface(r: *const VpnRow) []const u8 {
        const S = struct {
            var buf: [96]u8 = undefined;
        };
        if (r.device_len == 0) return "Tunnel active";
        return std.fmt.bufPrint(&S.buf, "Interface · {s}", .{r.deviceText()}) catch "Tunnel active";
    }

    fn fmtThroughputDown(r: *const VpnRow) []const u8 {
        const S = struct {
            var buf: [40]u8 = undefined;
        };
        return std.fmt.bufPrint(&S.buf, "↓ {s}", .{fmtRate(r.rx_bps)}) catch "↓ 0 B/s";
    }

    fn fmtThroughputUp(r: *const VpnRow) []const u8 {
        const S = struct {
            var buf: [40]u8 = undefined;
        };
        return std.fmt.bufPrint(&S.buf, "↑ {s}", .{fmtRate(r.tx_bps)}) catch "↑ 0 B/s";
    }

    // ---- primitives -----------------------------------------------------

    fn centeredText(c: *cairo.cairo_t, rect: common.Rect, label: []const u8, size: f32, weight: c_uint, col: Col, a: f64) void {
        const ts = ui_paint.textSizePx(c, label, size, weight);
        ui_paint.showWrapped(
            c,
            f(rect.x + @divTrunc(rect.w - ts.w, 2)),
            f(rect.y + @divTrunc(rect.h - ts.h, 2)),
            label,
            size,
            weight,
            col.r,
            col.g,
            col.b,
            a,
            rect.w,
            false,
        );
    }

    fn focusRing(c: *cairo.cairo_t, rect: common.Rect, rad: f64) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        cairo.cairo_save(c);
        ui_paint.roundRect(c, f(rect.x - 2), f(rect.y - 2), f(rect.w + 4), f(rect.h + 4), rad + 2);
        cairo.cairo_set_line_width(c, 2.0);
        setCol(c, VpnUi.accent, 1.0);
        cairo.cairo_stroke(c);
        cairo.cairo_restore(c);
    }

    fn paintVpnButton(
        c: *cairo.cairo_t,
        rect: common.Rect,
        label: []const u8,
        kind: VpnBtnKind,
        hovered: bool,
        focused: bool,
        enabled: bool,
    ) void {
        const r = f(rect.w);
        var fill = VpnUi.accent;
        var fill_a: f64 = 0.08;
        var border = VpnUi.accent;
        var border_a: f64 = 0.45;
        var text = VpnUi.accent_text;
        switch (kind) {
            .primary => {
                fill_a = 0.95;
                border_a = 1.0;
                text = VpnUi.on_accent;
            },
            .secondary => {},
            .danger => {
                fill = Col{ .r = 1.0, .g = 0.4196, .b = 0.4196 };
                fill_a = 0.10;
                border = fill;
                border_a = 0.45;
                text = VpnUi.danger_text;
            },
            .ghost => {
                fill = Col{ .r = 1.0, .g = 1.0, .b = 1.0 };
                fill_a = 0.04;
                border = fill;
                border_a = 0.16;
                text = VpnUi.text;
            },
        }
        if (!enabled) {
            fill_a *= 0.4;
            border_a *= 0.4;
        } else if (hovered) {
            fill_a = @min(1.0, fill_a + 0.06);
            border_a = @min(1.0, border_a + 0.08);
        }
        fillRound(c, f(rect.x), f(rect.y), f(rect.w), f(rect.h), k_vpn_btn_r, fill, fill_a);
        strokeRound(c, f(rect.x), f(rect.y), f(rect.w), f(rect.h), k_vpn_btn_r, border, border_a);
        centeredText(c, rect, label, 13, 600, text, if (enabled) 1.0 else 0.4);
        if (focused and enabled) focusRing(c, rect, k_vpn_btn_r);
        _ = r;
    }

    fn paintVpnIconButton(
        c: *cairo.cairo_t,
        rect: common.Rect,
        glyph: []const u8,
        hovered: bool,
        focused: bool,
        danger: bool,
    ) void {
        if (hovered) fillRound(c, f(rect.x), f(rect.y), f(rect.w), f(rect.h), k_vpn_btn_r, Col{ .r = 1.0, .g = 1.0, .b = 1.0 }, 0.06);
        const col = if (danger) VpnUi.danger_text else if (hovered) VpnUi.text else VpnUi.muted;
        ui_paint.glyph(c, f(rect.x + @divTrunc(rect.w, 2)), f(rect.y + @divTrunc(rect.h, 2)), 20, glyph, col.r, col.g, col.b, if (hovered) 1.0 else 0.76);
        if (focused) focusRing(c, rect, k_vpn_btn_r);
    }

    fn paintVpnSwitch(c: *cairo.cairo_t, rect: common.Rect, on: bool) void {
        const track = if (on) VpnUi.accent else Col{ .r = 1.0, .g = 1.0, .b = 1.0 };
        fillRound(c, f(rect.x), f(rect.y), 40, 24, 12, track, if (on) 0.95 else 0.16);
        const kx = if (on) rect.x + 19 else rect.x + 3;
        fillCircle(c, f(kx + 9), f(rect.y + 12), 9, VpnUi.text, 1.0);
    }

    fn paintVpnDot(c: *cairo.cairo_t, x: i32, cy: i32, state: VpnShown, pulse: f64) void {
        switch (state) {
            .connected => {
                fillCircle(c, f(x), f(cy), 9, VpnUi.ok, 0.16);
                fillCircle(c, f(x), f(cy), 5, VpnUi.ok, 1.0);
            },
            .connecting => {
                fillCircle(c, f(x), f(cy), 9, VpnUi.accent, 0.20 * pulse);
                fillCircle(c, f(x), f(cy), 5, VpnUi.accent, 0.45 + 0.55 * pulse);
            },
            .failed => fillCircle(c, f(x), f(cy), 5, VpnUi.danger_text, 1.0),
            else => fillCircle(c, f(x), f(cy), 5, VpnUi.idle_dot, 1.0),
        }
    }

    fn paintVpnProgress(c: *cairo.cairo_t, r: *const VpnRow, now: i64, x: i32, y: i32, w: i32) void {
        const stage = r.stage(now);
        const label = k_vpn_stage_label[stage];
        const pct = fmtPercent(r.progress);
        ui_paint.showWrapped(c, f(x), f(y), label, 12, 500, VpnUi.accent_text.r, VpnUi.accent_text.g, VpnUi.accent_text.b, 1.0, w, false);
        const pct_w = ui_paint.measureMonoTextWidth(pct, 12, 500);
        ui_paint.showMonoWrapped(c, f(x + w - pct_w), f(y), pct, 12, 500, VpnUi.accent_text.r, VpnUi.accent_text.g, VpnUi.accent_text.b, 1.0, pct_w, false);
        const bar_y = y + 20;
        fillRound(c, f(x), f(bar_y), f(w), 6, 3, Col{ .r = 1.0, .g = 1.0, .b = 1.0 }, 0.10);
        const fill_w = @max(4.0, @as(f64, @floatFromInt(w)) * @min(@max(r.progress, 0.0), 1.0));
        fillRound(c, f(x), f(bar_y), fill_w, 6, 3, VpnUi.accent, 1.0);
    }

    // ---- hero -----------------------------------------------------------

    fn heroText(
        c: *cairo.cairo_t,
        x: i32,
        y: i32,
        str: []const u8,
        size: f32,
        weight: c_uint,
        col: Col,
        a: f64,
        max_w: i32,
        mono: bool,
    ) void {
        if (str.len == 0 or max_w <= 0) return;
        if (mono) {
            const h = ui_paint.monoTextSizePx(c, str, size, weight).h;
            ui_paint.showMonoTextW(c, f(x), f(y + h - 2), str, size, weight, f(max_w), col.r, col.g, col.b, a);
        } else {
            const h = ui_paint.textSizePx(c, str, size, weight).h;
            ui_paint.showTextW(c, f(x), f(y + h - 2), str, size, weight, f(max_w), col.r, col.g, col.b, a);
        }
    }

    fn paintHeroCard(c: *cairo.cairo_t, l: VpnLay) void {
        cairo.cairo_save(c);
        ui_paint.roundRect(c, f(l.page_x), f(l.hero_y), f(l.page_w), f(l.hero_h), k_vpn_hero_r);
        const pat = cairo.cairo_pattern_create_linear(
            f(l.page_x),
            f(l.hero_y),
            f(l.page_x + l.page_w),
            f(l.hero_y) + f(l.hero_h) * 0.55,
        );
        cairo.cairo_pattern_add_color_stop_rgba(pat, 0.0, VpnUi.card_a.r, VpnUi.card_a.g, VpnUi.card_a.b, 1.0);
        cairo.cairo_pattern_add_color_stop_rgba(pat, 0.45, VpnUi.card_b.r, VpnUi.card_b.g, VpnUi.card_b.b, 1.0);
        cairo.cairo_pattern_add_color_stop_rgba(pat, 1.0, VpnUi.card_c.r, VpnUi.card_c.g, VpnUi.card_c.b, 1.0);
        cairo.cairo_set_source(c, pat);
        cairo.cairo_fill(c);
        cairo.cairo_pattern_destroy(pat);
        cairo.cairo_restore(c);
        strokeRound(c, f(l.page_x), f(l.hero_y), f(l.page_w), f(l.hero_h), k_vpn_hero_r, VpnUi.card_border, 1.0);
    }

    fn paintHeroDivider(c: *cairo.cairo_t, cell: VpnHeroCell) void {
        if (!cell.divider) return;
        fillRect(c, f(cell.x), f(cell.y + 22), 1.0, f(cell.h - 44), VpnUi.divider, 1.0);
    }

    fn paintVpnSparkline(c: *cairo.cairo_t, r: *const VpnRow, x: i32, y: i32, w: i32, h: i32) void {
        if (w < 48 or h < 20 or r.hist_n < 2) return;
        var peak: u64 = 1;
        for (0..r.hist_n) |i| {
            peak = @max(peak, @max(r.hist_rx[i], r.hist_tx[i]));
        }
        const n: usize = r.hist_n;
        const base = (r.hist_i + r.hist_rx.len - n) % r.hist_rx.len;
        const fw = f(w);
        const fh = f(h);
        const px = f(x);
        const py = f(y);

        // Area fill first, then the two strokes.
        const series = [_]struct { data: *const [60]u64, col: Col, alpha: f64 }{
            .{ .data = &r.hist_rx, .col = VpnUi.down, .alpha = 0.35 },
            .{ .data = &r.hist_tx, .col = VpnUi.up, .alpha = 0.30 },
        };
        for (series) |sd| {
            const grad = cairo.cairo_pattern_create_linear(px, py, px, py + fh);
            cairo.cairo_pattern_add_color_stop_rgba(grad, 0.0, sd.col.r, sd.col.g, sd.col.b, sd.alpha);
            cairo.cairo_pattern_add_color_stop_rgba(grad, 1.0, sd.col.r, sd.col.g, sd.col.b, 0.0);
            cairo.cairo_move_to(c, px, py + fh);
            for (0..n) |i| {
                const idx = (base + i) % r.hist_rx.len;
                const v = @min(sd.data[idx], peak);
                const cx = px + fw * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
                const cy = py + fh - fh * @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(peak));
                cairo.cairo_line_to(c, cx, cy);
            }
            cairo.cairo_line_to(c, px + fw, py + fh);
            cairo.cairo_close_path(c);
            cairo.cairo_set_source(c, grad);
            cairo.cairo_fill(c);
            cairo.cairo_pattern_destroy(grad);
        }
        for (series) |sd| {
            cairo.cairo_set_source_rgba(c, sd.col.r, sd.col.g, sd.col.b, 1.0);
            cairo.cairo_set_line_width(c, 2.0);
            cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);
            cairo.cairo_set_line_join(c, cairo.CAIRO_LINE_JOIN_ROUND);
            for (0..n) |i| {
                const idx = (base + i) % r.hist_rx.len;
                const v = @min(sd.data[idx], peak);
                const cx = px + fw * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
                const cy = py + fh - fh * @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(peak));
                if (i == 0) cairo.cairo_move_to(c, cx, cy) else cairo.cairo_line_to(c, cx, cy);
            }
            cairo.cairo_stroke(c);
        }
    }

    fn paintHeroCopy(self: *Page, c: *cairo.cairo_t, px: f64, ly: f64, l: VpnLay, now: i64) void {
        if (l.hero_copy.w <= 0) return;
        const visual = common.Rect{
            .x = l.hero_copy.x + 2,
            .y = l.hero_copy.y + 2,
            .w = l.hero_copy.w - 4,
            .h = l.hero_copy.h - 4,
        };
        const hover = inRect(px, ly, l.hero_copy);
        const copied = now < self.vpn_copy_until_ms;
        const focused = self.vpn_keyboard and self.vpn_focus >= 0 and
            self.vpnFocusAt(l, self.vpn_focus) != null and self.vpnFocusAt(l, self.vpn_focus).?.kind == .hero_copy;
        fillRound(c, f(visual.x), f(visual.y), f(visual.w), f(visual.h), 10.0, VpnUi.copy_bg, if (hover) 1.0 else 0.92);
        strokeRound(c, f(visual.x), f(visual.y), f(visual.w), f(visual.h), 10.0, VpnUi.copy_border, 1.0);
        const col = if (hover or copied) VpnUi.text else Col{ .r = 0.7843, .g = 0.7922, .b = 0.8784 };
        ui_paint.glyph(
            c,
            f(visual.x + @divTrunc(visual.w, 2)),
            f(visual.y + @divTrunc(visual.h, 2)),
            20,
            if (copied) "check" else "content_copy",
            col.r,
            col.g,
            col.b,
            1.0,
        );
        if (focused) focusRing(c, visual, 10.0);
    }

    fn paintHeroDisconnect(self: *Page, c: *cairo.cairo_t, px: f64, ly: f64, l: VpnLay) void {
        if (l.hero_disconnect.w <= 0) return;
        const hover = inRect(px, ly, l.hero_disconnect);
        const focused = self.vpn_keyboard and self.vpn_focus >= 0 and
            self.vpnFocusAt(l, self.vpn_focus) != null and self.vpnFocusAt(l, self.vpn_focus).?.kind == .hero_disconnect;
        const bg = if (hover) Col{ .r = 0.2706, .g = 0.1137, .b = 0.1647 } else VpnUi.disconnect_bg;
        fillRound(c, f(l.hero_disconnect.x), f(l.hero_disconnect.y), f(l.hero_disconnect.w), f(l.hero_disconnect.h), 16.0, bg, 1.0);
        strokeRound(c, f(l.hero_disconnect.x), f(l.hero_disconnect.y), f(l.hero_disconnect.w), f(l.hero_disconnect.h), 16.0, VpnUi.disconnect_border, 1.0);
        const size: f32 = if (l.hero_split) 19.0 else 21.0;
        const ts = ui_paint.textSizePx(c, "Disconnect", size, 600);
        heroText(
            c,
            l.hero_disconnect.x + @divTrunc(l.hero_disconnect.w - ts.w, 2),
            l.hero_disconnect.y + @divTrunc(l.hero_disconnect.h - ts.h, 2),
            "Disconnect",
            size,
            600,
            VpnUi.disconnect_text,
            1.0,
            l.hero_disconnect.w,
            false,
        );
        if (focused) focusRing(c, l.hero_disconnect, 16.0);
    }

    fn paintVpnHero(self: *Page, c: *cairo.cairo_t, px: f64, ly: f64, l: VpnLay, now: i64) void {
        if (!l.hero or l.hero_row >= self.vpn_rows.items.len) return;
        const r = &self.vpn_rows.items[l.hero_row];
        paintHeroCard(c, l);

        for (l.hero_cells[0..l.hero_cells_n]) |cell| {
            paintHeroDivider(c, cell);
            const content_x = cell.x + cell.pad_l;
            const content_w = cell.w - cell.pad_l - cell.pad_r;
            switch (cell.kind) {
                .identity => {
                    const shield: i32 = if (l.hero_split) 64 else 76;
                    const gap: i32 = if (l.hero_split) 18 else 24;
                    const cx = content_x + @divTrunc(shield, 2);
                    const cy = cell.y + @divTrunc(cell.h, 2);
                    fillCircle(c, f(cx), f(cy), f(@divTrunc(shield, 2)), VpnUi.shield_bg, 1.0);
                    strokeCircle(c, f(cx), f(cy), f(@divTrunc(shield, 2)), VpnUi.card_border, 1.0);
                    ui_paint.glyph(c, f(cx), f(cy), if (l.hero_split) 32 else 38, "shield", VpnUi.status.r, VpnUi.status.g, VpnUi.status.b, 1.0);

                    const tx = content_x + shield + gap;
                    const tw = cell.x + cell.w - cell.pad_r - tx;
                    const status_size: f32 = 16;
                    const status_h: i32 = @intFromFloat(status_size * 1.45);
                    const name_h: i32 = @intFromFloat(l.hero_name_size * 1.45);
                    const iface_h: i32 = @intFromFloat(l.hero_iface_size * 1.45);
                    const gap_v: i32 = 6;
                    const total = status_h + gap_v + name_h + gap_v + iface_h;
                    const top = cell.y + @divTrunc(cell.h - total, 2);

                    fillCircle(c, f(tx + 5), f(top + @divTrunc(status_h, 2)), 5.0, VpnUi.status, 1.0);
                    heroText(c, tx + 20, top, "CONNECTED", status_size, 600, VpnUi.status, 1.0, tw - 20, false);
                    heroText(c, tx, top + status_h + gap_v, r.nameText(), l.hero_name_size, 600, VpnUi.text, 1.0, tw, false);

                    const iface_y = top + status_h + gap_v + name_h + gap_v;
                    if (r.device_len > 0) {
                        const prefix = "Interface · ";
                        const pw = ui_paint.measureTextWidth(prefix, l.hero_iface_size, 400);
                        heroText(c, tx, iface_y, prefix, l.hero_iface_size, 400, VpnUi.muted, 1.0, tw, false);
                        heroText(c, tx + pw, iface_y, r.deviceText(), l.hero_iface_size, 500, VpnUi.muted, 1.0, tw - pw, true);
                    } else {
                        heroText(c, tx, iface_y, "Tunnel active", l.hero_iface_size, 400, VpnUi.muted, 1.0, tw, false);
                    }
                },
                .ip => {
                    const label_h: i32 = if (l.hero_split) 20 else 24;
                    const gap_v: i32 = if (l.hero_split) 8 else 10;
                    const ip_h: i32 = @intFromFloat(@as(f64, l.hero_ip_size) * 1.45);
                    const total = label_h + gap_v + @max(ip_h, 44);
                    const top = cell.y + @divTrunc(cell.h - total, 2);
                    heroText(c, content_x, top, "VPN IP", if (l.hero_split) 14 else 16, 400, VpnUi.muted, 1.0, content_w, false);
                    const value_y = top + label_h + gap_v;
                    const copy_reserve: i32 = if (r.exit_len > 0) 56 else 0;
                    if (r.exit_len > 0) {
                        heroText(c, content_x, value_y, r.exitText(), l.hero_ip_size, 500, VpnUi.text, 1.0, content_w - copy_reserve, true);
                    } else if (r.exit_failed or self.vpn_exit_url.len == 0) {
                        heroText(c, content_x, value_y, "Unavailable", 20, 400, VpnUi.muted, 1.0, content_w, false);
                    } else {
                        fillRound(c, f(content_x), f(value_y + 6), 140, 20, 6, Col{ .r = 1.0, .g = 1.0, .b = 1.0 }, 0.07);
                    }
                },
                .connected => {
                    const label_h: i32 = if (l.hero_split) 20 else 24;
                    const gap_v: i32 = if (l.hero_split) 8 else 10;
                    const value_h: i32 = @intFromFloat(l.hero_value_size * 1.45);
                    const total = label_h + gap_v + value_h;
                    const top = cell.y + @divTrunc(cell.h - total, 2);
                    heroText(c, content_x, top, "Connected for", if (l.hero_split) 14 else 16, 400, VpnUi.muted, 1.0, content_w, false);
                    heroText(c, content_x, top + label_h + gap_v, fmtUptime(r.uptimeMs(now)), l.hero_value_size, 400, VpnUi.text, 1.0, content_w, true);
                },
                .tunnel => {
                    const label_h: i32 = if (l.hero_split) 20 else 24;
                    const gap_v: i32 = if (l.hero_split) 8 else 10;
                    const value_h: i32 = @intFromFloat(l.hero_value_size * 1.45);
                    const total = label_h + gap_v + value_h;
                    const top = cell.y + @divTrunc(cell.h - total, 2);
                    heroText(c, content_x, top, "Tunnel", if (l.hero_split) 14 else 16, 400, VpnUi.muted, 1.0, content_w, false);
                    const tunnel = if (r.tunnel_len > 0) r.tunnelText() else "—";
                    heroText(c, content_x, top + label_h + gap_v, tunnel, l.hero_value_size, 400, VpnUi.text, 1.0, content_w, true);
                },
                .throughput => {
                    const label_h: i32 = if (l.hero_split) 20 else 24;
                    const gap_v: i32 = if (l.hero_split) 8 else 10;
                    const rate_h: i32 = @intFromFloat(l.hero_rate_size * 1.45);
                    const spark_h: i32 = if (l.hero_sparkline) 64 else 0;
                    const rates_h: i32 = if (l.hero_rates_stacked) rate_h * 2 + 4 else rate_h;
                    var total = label_h + gap_v + rates_h;
                    if (l.hero_sparkline) total += gap_v + spark_h;
                    const top = cell.y + @divTrunc(cell.h - total, 2);
                    heroText(c, content_x, top, "Throughput", if (l.hero_split) 14 else 16, 400, VpnUi.muted, 1.0, content_w, false);
                    const down = fmtThroughputDown(r);
                    const up = fmtThroughputUp(r);
                    const rates_y = top + label_h + gap_v;
                    if (l.hero_rates_stacked) {
                        heroText(c, content_x, rates_y, down, l.hero_rate_size, 400, VpnUi.down, 1.0, content_w, true);
                        heroText(c, content_x, rates_y + rate_h + 4, up, l.hero_rate_size, 400, VpnUi.up, 1.0, content_w, true);
                    } else {
                        heroText(c, content_x, rates_y, down, l.hero_rate_size, 400, VpnUi.down, 1.0, content_w, true);
                        const dw = ui_paint.measureMonoTextWidth(down, l.hero_rate_size, 400);
                        const gap_rates: i32 = if (l.hero_split) 16 else 32;
                        heroText(c, content_x + dw + gap_rates, rates_y, up, l.hero_rate_size, 400, VpnUi.up, 1.0, content_w - dw - gap_rates, true);
                    }
                    if (l.hero_sparkline) {
                        paintVpnSparkline(c, r, content_x, rates_y + rates_h + gap_v, content_w, spark_h);
                    }
                },
                .action => {},
            }
        }

        paintHeroCopy(self, c, px, ly, l, now);
        paintHeroDisconnect(self, c, px, ly, l);
    }

    // ---- page -----------------------------------------------------------

    fn paintVpn(self: *Page, c: *cairo.cairo_t, g: Geo, px: f64, ly: f64, glass_ov: f64) void {
        _ = glass_ov;
        self.cur_geo = g;
        const l = self.layoutVpn(g);
        const now = nowMs();
        const pulse = 0.5 + 0.5 * @sin(@as(f64, @floatFromInt(now)) / 1400.0 * std.math.tau);

        // Page title + subtitle.
        ui_paint.showWrapped(c, f(l.page_x), f(k_top), "VPN", 28, 700, VpnUi.text.r, VpnUi.text.g, VpnUi.text.b, 1.0, l.page_w - 160, false);
        ui_paint.showWrapped(c, f(l.page_x), f(k_top + 36), "Encrypted tunnels for this device", 13, 400, VpnUi.muted.r, VpnUi.muted.g, VpnUi.muted.b, 1.0, l.page_w - 160, true);
        const add_hover = inRect(px, ly, l.add);
        paintVpnButton(c, l.add, "Add VPN", .primary, add_hover, self.vpn_keyboard and self.vpn_focus >= 0 and self.vpnFocusAt(l, self.vpn_focus) != null and self.vpnFocusAt(l, self.vpn_focus).?.kind == .add, true);

        if (l.hero) self.paintVpnHero(c, px, ly, l, now);

        // Section header.
        ui_paint.showWrapped(c, f(l.page_x), f(l.section_y), "Connections", 16, 600, VpnUi.text.r, VpnUi.text.g, VpnUi.text.b, 1.0, 220, false);
        const cw = ui_paint.measureTextWidth("Connections", 16, 600);
        const saved = fmtSaved(self.vpn_rows.items.len);
        ui_paint.showWrapped(c, f(l.page_x + cw + 10), f(l.section_y + 3), saved, 13, 400, VpnUi.muted.r, VpnUi.muted.g, VpnUi.muted.b, 1.0, 120, false);

        if (l.rows_n == 0) {
            const er = common.Rect{ .x = l.page_x, .y = l.list_y, .w = l.page_w, .h = 96 };
            fillRound(c, f(er.x), f(er.y), f(er.w), f(er.h), k_vpn_row_r, VpnUi.row_surface, 0.36);
            strokeRound(c, f(er.x), f(er.y), f(er.w), f(er.h), k_vpn_row_r, VpnUi.text, 0.08);
            ui_paint.showWrapped(c, f(er.x + 20), f(er.y + 36), "No VPN connections yet", 14, 500, VpnUi.text.r, VpnUi.text.g, VpnUi.text.b, 0.9, er.w - 40, false);
            ui_paint.showWrapped(c, f(er.x + 20), f(er.y + 58), "Add a profile or import a configuration to get started.", 12, 400, VpnUi.muted.r, VpnUi.muted.g, VpnUi.muted.b, 1.0, er.w - 40, true);
        }

        for (self.vpn_rows.items[0..l.rows_n], 0..) |*r, i| {
            const rl = self.vpn_row_lay[i];
            const state = r.shownState(now);
            const armed = self.vpn_delete_len > 0 and std.mem.eql(u8, self.vpn_delete_uuid[0..self.vpn_delete_len], r.uuidText()) and now < self.vpn_delete_until_ms;
            var border = VpnUi.text;
            var border_a: f64 = 0.08;
            switch (state) {
                .connected => {
                    border = VpnUi.ok;
                    border_a = 0.28;
                },
                .connecting => {
                    border = VpnUi.accent;
                    border_a = 0.40;
                },
                .failed => {
                    border = Col{ .r = 1.0, .g = 0.4196, .b = 0.4196 };
                    border_a = 0.30;
                },
                else => {},
            }
            fillRound(c, f(rl.x), f(rl.y), f(rl.w), f(rl.h), k_vpn_row_r, VpnUi.row_surface, 0.60);
            strokeRound(c, f(rl.x), f(rl.y), f(rl.w), f(rl.h), k_vpn_row_r, border, border_a);

            paintVpnDot(c, rl.dot_x, rl.dot_y, state, pulse);

            // Name. The dot is row-centered for ordinary rows; centre the
            // glyph ink on that same line so font leading cannot make the
            // text sit visibly high or low.
            var name_draw_y = rl.name_y;
            const has_secondary = state == .connecting or state == .failed or
                (r.auto_error_until_ms > now and state != .connecting);
            if (!has_secondary and r.name_lines == 1) {
                const m = ui_paint.textMetricsPx(c, r.nameText(), r.name_size, 600, @floatFromInt(rl.name_w));
                if (m.ink_h > 0) {
                    name_draw_y = rl.y + @divTrunc(rl.h, 2) - m.ink_y - @divTrunc(m.ink_h, 2);
                }
            }
            ui_paint.showWrapped(c, f(rl.name_x), f(name_draw_y), r.nameText(), r.name_size, 600, VpnUi.text.r, VpnUi.text.g, VpnUi.text.b, 1.0, rl.name_w, false);
            // Idle and connected rows are self-explanatory: the dot and the
            // action label carry the state. Only failed/auto-error rows spend
            // a line on text.
            var status_buf: [180]u8 = undefined;
            if (state == .failed) {
                const status = std.fmt.bufPrint(&status_buf, "Failed: {s}", .{r.failText()}) catch "Failed";
                ui_paint.showWrapped(c, f(rl.name_x), f(rl.status_y), status, 13, 400, VpnUi.danger_text.r, VpnUi.danger_text.g, VpnUi.danger_text.b, 1.0, rl.name_w, true);
            } else if (r.auto_error_until_ms > now and state != .connecting) {
                const status = std.fmt.bufPrint(&status_buf, "Auto-connect: {s}", .{r.autoErrorText()}) catch "Auto-connect failed";
                ui_paint.showWrapped(c, f(rl.name_x), f(rl.status_y), status, 13, 400, VpnUi.danger_text.r, VpnUi.danger_text.g, VpnUi.danger_text.b, 1.0, rl.name_w, true);
            }

            // Middle slot.
            if (state == .connecting) {
                paintVpnProgress(c, r, now, rl.mid_x, rl.mid_y, rl.mid_w);
            }

            // Auto label + switch.
            const auto_on = r.shownAuto(now);
            ui_paint.showWrapped(c, f(rl.auto_hit.x), f(rl.auto_hit.y + 14), "Auto", 12, 400, VpnUi.muted.r, VpnUi.muted.g, VpnUi.muted.b, 1.0, 50, false);
            paintVpnSwitch(c, rl.auto_switch, auto_on);
            if (self.vpn_keyboard and self.vpn_focus >= 0) {
                if (self.vpnFocusAt(l, self.vpn_focus)) |foc| {
                    if (foc.kind == .row_auto and foc.row == i) focusRing(c, rl.auto_hit, 10);
                }
            }

            // Action button, or the inline delete confirm when armed.
            if (armed) {
                const right = rl.delete.x + rl.delete.w;
                const del_rect = common.Rect{ .x = rl.action.x, .y = rl.action.y, .w = right - rl.action.x, .h = rl.action.h };
                paintVpnButton(c, del_rect, "Delete?", .danger, inRect(px, ly, del_rect), self.vpn_keyboard and self.vpn_focus >= 0 and self.vpnFocusAt(l, self.vpn_focus) != null and self.vpnFocusAt(l, self.vpn_focus).?.kind == .row_delete and self.vpnFocusAt(l, self.vpn_focus).?.row == i, true);
            } else {
                const action_label: []const u8 = switch (state) {
                    .idle => "Connect",
                    .connecting => "Cancel",
                    .connected => "Disconnect",
                    .disconnecting => "Disconnecting",
                    .failed => "Retry",
                };
                const kind: VpnBtnKind = switch (state) {
                    .idle, .failed => .secondary,
                    .connecting => .ghost,
                    .connected => .danger,
                    .disconnecting => .ghost,
                };
                paintVpnButton(c, rl.action, action_label, kind, inRect(px, ly, rl.action) and state != .disconnecting, self.vpn_keyboard and self.vpn_focus >= 0 and self.vpnFocusAt(l, self.vpn_focus) != null and self.vpnFocusAt(l, self.vpn_focus).?.kind == .row_action and self.vpnFocusAt(l, self.vpn_focus).?.row == i, state != .disconnecting);
                paintVpnIconButton(c, rl.delete, "delete", inRect(px, ly, rl.delete), self.vpn_keyboard and self.vpn_focus >= 0 and self.vpnFocusAt(l, self.vpn_focus) != null and self.vpnFocusAt(l, self.vpn_focus).?.kind == .row_delete and self.vpnFocusAt(l, self.vpn_focus).?.row == i, false);
            }
        }

        // Async status under the list.
        if (self.status_src == .vpn and self.status_len > 0 and now < self.status_until_ms) {
            const col = if (self.status_failed) VpnUi.danger_text else VpnUi.accent_text;
            ui_paint.showWrapped(c, f(l.page_x), f(l.status_y), self.status_buf[0..self.status_len], 12, 400, col.r, col.g, col.b, 0.92, l.page_w, true);
        }
    }

    /// The delete hit target grows to the combined action+trash width while
    /// the confirmation is showing, so the second click lands on "Delete?".
    fn vpnDeleteRectAt(self: *Page, idx: usize) common.Rect {
        if (idx >= self.vpn_lay.rows_n) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const rl = self.vpn_row_lay[idx];
        const now = nowMs();
        if (idx < self.vpn_rows.items.len and self.vpn_delete_len > 0 and now < self.vpn_delete_until_ms and
            std.mem.eql(u8, self.vpn_delete_uuid[0..self.vpn_delete_len], self.vpn_rows.items[idx].uuidText()))
        {
            const right = rl.delete.x + rl.delete.w;
            return .{ .x = rl.action.x, .y = rl.action.y, .w = right - rl.action.x, .h = rl.action.h };
        }
        return rl.delete;
    }

    fn clearDeleteConfirm(self: *Page) void {
        self.vpn_delete_len = 0;
        self.vpn_delete_until_ms = 0;
    }

    fn isDeleteArmed(self: *Page, uuid: []const u8) bool {
        return self.vpn_delete_len > 0 and nowMs() < self.vpn_delete_until_ms and
            std.mem.eql(u8, self.vpn_delete_uuid[0..self.vpn_delete_len], uuid);
    }

    fn removeVpnAt(self: *Page, idx: usize) void {
        if (idx >= self.vpn_rows.items.len) return;
        const uuid_buf = self.vpn_rows.items[idx].uuid;
        const uuid_len = self.vpn_rows.items[idx].uuid_len;
        self.markRemoving(uuid_buf[0..uuid_len]);
        live_vpn.removeThread(self.io, uuid_buf[0..uuid_len]);
        var j = idx;
        while (j + 1 < self.vpn_rows.items.len) : (j += 1) self.vpn_rows.items[j] = self.vpn_rows.items[j + 1];
        self.vpn_rows.items.len -= 1;
        self.clearDeleteConfirm();
        self.vpn_focus = -1;
    }

    fn armOrDelete(self: *Page, idx: usize) void {
        if (idx >= self.vpn_rows.items.len) return;
        const now = nowMs();
        const uuid = self.vpn_rows.items[idx].uuidText();
        if (self.isDeleteArmed(uuid)) {
            self.removeVpnAt(idx);
            return;
        }
        const n = @min(uuid.len, self.vpn_delete_uuid.len);
        @memcpy(self.vpn_delete_uuid[0..n], uuid[0..n]);
        self.vpn_delete_len = n;
        self.vpn_delete_until_ms = now + k_vpn_delete_confirm_ms;
    }

    fn connectVpnAt(self: *Page, idx: usize) void {
        if (idx >= self.vpn_rows.items.len) return;
        const now = nowMs();
        // Exclusivity: leave at most one live row, matching the serialized
        // activation worker. The rows update immediately so two green rows
        // never appear while nmcli catches up.
        for (self.vpn_rows.items, 0..) |*other, oi| {
            if (oi == idx) continue;
            const st = other.shownState(now);
            if (st == .connected or st == .connecting) {
                if (st == .connecting) {
                    live_vpn.cancelThread(self.io, other.uuidText());
                } else {
                    live_vpn.deactivateThread(self.io, other.uuidText());
                }
                live_vpn.setAutoconnectThread(self.io, other.uuidText(), false);
                other.phase = .disconnecting;
                other.disconnect_started_ms = now;
                other.progress = 0;
                other.clearExit();
                other.pending_auto = true;
                other.auto_target = false;
                other.auto_since = now;
            }
        }
        const r = &self.vpn_rows.items[idx];
        r.phase = .connecting;
        r.progress = k_vpn_stage_start[0];
        r.connect_started_ms = now;
        r.settle_until_ms = 0;
        r.suppress_active_until_ms = 0;
        r.clearFail();
        r.clearExit();
        r.auto_error_until_ms = 0;
        live_vpn.activateThread(self.io, r.uuidText());
        self.clearDeleteConfirm();
    }

    fn disconnectVpnAt(self: *Page, idx: usize) void {
        if (idx >= self.vpn_rows.items.len) return;
        const now = nowMs();
        const r = &self.vpn_rows.items[idx];
        r.phase = .disconnecting;
        r.disconnect_started_ms = now;
        r.progress = 0;
        r.clearExit();
        r.clearFail();
        live_vpn.deactivateThread(self.io, r.uuidText());
        live_vpn.setAutoconnectThread(self.io, r.uuidText(), false);
        r.pending_auto = true;
        r.auto_target = false;
        r.auto_since = now;
        self.clearDeleteConfirm();
    }

    fn cancelVpnAt(self: *Page, idx: usize) void {
        if (idx >= self.vpn_rows.items.len) return;
        const now = nowMs();
        const r = &self.vpn_rows.items[idx];
        r.phase = .backend;
        r.progress = 0;
        r.settle_until_ms = 0;
        r.clearFail();
        r.clearExit();
        r.suppress_active_until_ms = now + k_vpn_cancel_suppress_ms;
        live_vpn.cancelThread(self.io, r.uuidText());
        self.clearDeleteConfirm();
    }

    fn toggleVpnAutoAt(self: *Page, idx: usize) void {
        if (idx >= self.vpn_rows.items.len) return;
        const now = nowMs();
        const r = &self.vpn_rows.items[idx];
        const on = r.shownAuto(now);
        r.pending_auto = true;
        r.auto_target = !on;
        r.auto_since = now;
        r.auto_error_until_ms = 0;
        live_vpn.setAutoconnectThread(self.io, r.uuidText(), !on);
    }

    fn copyVpnExit(self: *Page, idx: usize) bool {
        if (idx >= self.vpn_rows.items.len) return false;
        const r = &self.vpn_rows.items[idx];
        if (r.exit_len == 0) return false;
        if (!self.vpn_clip.copyText(r.exitText())) return false;
        self.vpn_copy_until_ms = nowMs() + 1200;
        return true;
    }

    fn activateVpnFocus(self: *Page, foc: VpnFocus, now: i64) void {
        _ = now;
        switch (foc.kind) {
            .add => self.openVpnDialog(),
            .hero_copy => _ = self.copyVpnExit(self.vpn_lay.hero_row),
            .hero_disconnect => self.disconnectVpnAt(self.vpn_lay.hero_row),
            .row_auto => self.toggleVpnAutoAt(foc.row),
            .row_action => {
                if (foc.row >= self.vpn_rows.items.len) return;
                const r = &self.vpn_rows.items[foc.row];
                switch (r.shownState(nowMs())) {
                    .idle => self.connectVpnAt(foc.row),
                    .connecting => self.cancelVpnAt(foc.row),
                    .connected => self.disconnectVpnAt(foc.row),
                    .failed => self.connectVpnAt(foc.row),
                    .disconnecting => {},
                }
            },
            .row_delete => self.armOrDelete(foc.row),
        }
    }

    // ---- focus ----------------------------------------------------------

    fn vpnHeroCopyVisible(self: *Page, l: VpnLay) bool {
        _ = self;
        return l.hero and l.hero_copy.w > 0;
    }

    fn vpnRowActionFocusable(self: *const Page, l: VpnLay, i: usize) bool {
        _ = l;
        if (i >= self.vpn_rows.items.len) return false;
        return self.vpn_rows.items[i].shownState(nowMs()) != .disconnecting;
    }

    fn vpnFocusCount(self: *Page, l: VpnLay) usize {
        var n: usize = 1; // Add VPN
        if (l.hero) {
            if (self.vpnHeroCopyVisible(l)) n += 1;
            n += 1; // Disconnect
        }
        for (0..l.rows_n) |i| {
            n += 1; // Auto
            if (self.vpnRowActionFocusable(l, i)) n += 1;
            n += 1; // Delete
        }
        return n;
    }

    fn vpnFocusAt(self: *Page, l: VpnLay, ordinal: i32) ?VpnFocus {
        if (ordinal < 0) return null;
        var n: usize = @intCast(ordinal);
        if (n == 0) return .{ .kind = .add };
        n -= 1;
        if (l.hero) {
            if (self.vpnHeroCopyVisible(l)) {
                if (n == 0) return .{ .kind = .hero_copy };
                n -= 1;
            }
            if (n == 0) return .{ .kind = .hero_disconnect };
            n -= 1;
        }
        for (0..l.rows_n) |i| {
            if (n == 0) return .{ .kind = .row_auto, .row = i };
            n -= 1;
            if (self.vpnRowActionFocusable(l, i)) {
                if (n == 0) return .{ .kind = .row_action, .row = i };
                n -= 1;
            }
            if (n == 0) return .{ .kind = .row_delete, .row = i };
            n -= 1;
        }
        return null;
    }

    fn vpnFocusRect(self: *Page, foc: VpnFocus) ?common.Rect {
        const l = self.vpn_lay;
        switch (foc.kind) {
            .add => return l.add,
            .hero_copy => return if (l.hero_copy.w > 0) l.hero_copy else null,
            .hero_disconnect => return if (l.hero) l.hero_disconnect else null,
            .row_auto => if (foc.row < l.rows_n) return self.vpn_row_lay[foc.row].auto_hit else return null,
            .row_action => if (foc.row < l.rows_n) return self.vpn_row_lay[foc.row].action else return null,
            .row_delete => if (foc.row < l.rows_n) return self.vpnDeleteRectAt(foc.row) else return null,
        }
    }

    /// Rect the window should scroll into view after a keyboard focus move.
    pub fn vpnFocusScrollRect(self: *Page) ?common.Rect {
        if (self.cur_tab != vpn_tab or self.vpn_focus < 0) return null;
        _ = self.layoutVpn(self.cur_geo);
        const foc = self.vpnFocusAt(self.vpn_lay, self.vpn_focus) orelse return null;
        return self.vpnFocusRect(foc);
    }

    fn keyVpn(self: *Page, sym: u32, text: []const u8) bool {
        _ = text;
        const l = self.layoutVpn(self.cur_geo);
        const count = self.vpnFocusCount(l);
        if (count == 0) return false;
        switch (sym) {
            xkb.XKB_KEY_Tab, xkb.XKB_KEY_ISO_Left_Tab => {
                const shift = sym == xkb.XKB_KEY_ISO_Left_Tab;
                var cur = self.vpn_focus;
                if (cur < 0 or cur >= @as(i32, @intCast(count))) {
                    self.vpn_focus = if (shift) @as(i32, @intCast(count - 1)) else 0;
                } else if (shift) {
                    cur -= 1;
                    if (cur < 0) cur = @as(i32, @intCast(count - 1));
                    self.vpn_focus = cur;
                } else {
                    cur += 1;
                    if (cur >= @as(i32, @intCast(count))) cur = 0;
                    self.vpn_focus = cur;
                }
                self.vpn_keyboard = true;
                return true;
            },
            xkb.XKB_KEY_Escape => {
                if (self.vpn_delete_len > 0) {
                    self.clearDeleteConfirm();
                    return true;
                }
                if (self.vpn_focus >= 0) {
                    self.vpn_focus = -1;
                    self.vpn_keyboard = false;
                    return true;
                }
                return false;
            },
            xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter, xkb.XKB_KEY_space => {
                if (self.vpn_focus < 0 or self.vpn_focus >= @as(i32, @intCast(count))) return false;
                const foc = self.vpnFocusAt(l, self.vpn_focus) orelse return false;
                self.vpn_keyboard = true;
                self.activateVpnFocus(foc, nowMs());
                return true;
            },
            else => return false,
        }
    }

    // ---- hit ------------------------------------------------------------

    fn hitVpn(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        self.cur_geo = g;
        const l = self.layoutVpn(g);
        self.vpn_keyboard = false;
        const now = nowMs();
        _ = now;

        if (inRect(px, ly, l.add)) {
            self.openVpnDialog();
            return .repaint;
        }
        if (l.hero) {
            if (l.hero_copy.w > 0 and inRect(px, ly, l.hero_copy)) {
                _ = self.copyVpnExit(l.hero_row);
                return .repaint;
            }
            if (inRect(px, ly, l.hero_disconnect)) {
                self.disconnectVpnAt(l.hero_row);
                return .repaint;
            }
        }
        for (self.vpn_rows.items[0..l.rows_n], 0..) |*r, i| {
            const rl = self.vpn_row_lay[i];
            const del = self.vpnDeleteRectAt(i);
            if (inRect(px, ly, del)) {
                if (self.isDeleteArmed(r.uuidText())) {
                    self.removeVpnAt(i);
                } else {
                    self.armOrDelete(i);
                }
                return .repaint;
            }
            if (inRect(px, ly, rl.auto_hit)) {
                self.toggleVpnAutoAt(i);
                return .repaint;
            }
            const state = r.shownState(nowMs());
            if (state != .disconnecting and inRect(px, ly, rl.action)) {
                switch (state) {
                    .idle, .failed => self.connectVpnAt(i),
                    .connecting => self.cancelVpnAt(i),
                    .connected => self.disconnectVpnAt(i),
                    .disconnecting => {},
                }
                return .repaint;
            }
        }
        return null;
    }

    fn openVpnDialog(self: *Page) void {
        self.vpn.type_i = 0;
        self.vpn.focus = 0;
        self.vpn.hover = 0;
        self.vpn.press = 0;
        self.vpn.note_len = 0;
        for (&self.vpn.values) |*v| v.len = 0;
        self.vpn.values[@intFromEnum(FieldId.allowed_ips)].set("0.0.0.0/0, ::/0");
        self.vpn.open = true;
    }

    // -----------------------------------------------------------------
    // VPN Add dialog
    // -----------------------------------------------------------------

    fn paintVpnModal(self: *Page, c: *cairo.cairo_t, g: Geo) void {
        const t = common.Theme;
        const ti = self.vpn.type_i;
        const l = vpnDlgLay(ti, g.win_w, g.win_h);
        const spec = &vpn_types[ti];

        cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.42);
        cairo.cairo_rectangle(c, 0, 0, f(g.win_w), f(g.win_h));
        cairo.cairo_fill(c);

        ui_paint.glassBox(c, f(l.x), f(l.y), f(l.w), f(l.h), 16, t.bg_r, t.bg_g, t.bg_b, 0.97);
        cairo.cairo_save(c);
        ui_paint.roundRect(c, f(l.x) + 0.5, f(l.y) + 0.5, f(l.w) - 1, f(l.h) - 1, 15.5);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.35);
        cairo.cairo_stroke(c);
        cairo.cairo_restore(c);

        // Header.
        ui_paint.glassBox(c, f(l.x + vpn_pad), f(l.y + vpn_pad + 3), 38, 38, 10, t.acc_r, t.acc_g, t.acc_b, 0.14);
        ui_paint.glyph(c, f(l.x + vpn_pad + 19), f(l.y + vpn_pad + 22), 22, "vpn_key", t.acc_r, t.acc_g, t.acc_b, 0.95);
        ui_paint.showText(c, f(l.x + vpn_pad + 50), f(l.y + vpn_pad + 23), "Add VPN Connection", 16, 700, t.text_r, t.text_g, t.text_b, 0.95);
        ui_paint.showTextW(c, f(l.x + vpn_pad + 50), f(l.y + vpn_pad + 40), spec.desc, 11, 400, f(l.w - vpn_pad * 2 - 50), t.text_r, t.text_g, t.text_b, 0.55);
        const close_hov = self.vpn.hover == 5;
        ui_paint.glassBox(c, f(l.close.x), f(l.close.y), f(l.close.w), f(l.close.h), 8, t.bg_r, t.bg_g, t.bg_b, if (close_hov) 0.14 else 0.06);
        cairo.cairo_save(c);
        ui_paint.roundRect(c, f(l.close.x) + 0.5, f(l.close.y) + 0.5, f(l.close.w) - 1, f(l.close.h) - 1, 7.5);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.45);
        cairo.cairo_stroke(c);
        cairo.cairo_restore(c);
        ui_paint.glyph(c, f(l.close.x + 14), f(l.close.y + 14), 18, "close", t.text_r, t.text_g, t.text_b, if (close_hov) 1.0 else 0.8);

        // Type tabs.
        for (vpn_types, 0..) |vt, i| {
            const r = l.tabs[i];
            const sel = i == ti;
            if (sel) {
                ui_paint.glassBox(c, f(r.x), f(r.y), f(r.w), f(r.h), 8, t.acc_r, t.acc_g, t.acc_b, 0.14);
            } else if (self.vpn.hover == 10 + @as(i32, @intCast(i))) {
                ui_paint.glassBox(c, f(r.x), f(r.y), f(r.w), f(r.h), 8, 1, 1, 1, 0.05);
            }
            const tw = ui_paint.measureTextWidth(vt.label, if (sel) 11 else 10.5, if (sel) 700 else 400);
            ui_paint.showText(
                c,
                f(r.x) + (f(r.w) - f(tw)) / 2.0,
                f(r.y + 20),
                vt.label,
                if (sel) 11 else 10.5,
                if (sel) 700 else 400,
                t.text_r,
                t.text_g,
                t.text_b,
                if (sel) 0.95 else 0.50,
            );
        }

        // Plugin hint (non-WireGuard).
        if (!pluginAvailable(spec)) {
            var hb: [220]u8 = undefined;
            const hint = std.fmt.bufPrint(&hb, "Install \"{s}\" to enable {s} VPN support.", .{ spec.pkg, spec.label }) catch "";
            ui_paint.showTextW(c, f(l.x + vpn_pad), f(l.y + 104), hint, 10.5, 400, f(l.w - 2 * vpn_pad), t.text_r, t.text_g, t.text_b, 0.45);
        }

        // Fields.
        for (spec.fields, 0..) |fd, fi| {
            const fr = vpnFieldRect(l, ti, fi);
            ui_paint.showText(c, f(l.x + vpn_pad), f(fr.y - 7), fd.label, 11.5, 400, t.text_r, t.text_g, t.text_b, 0.60);
            paintField(c, fr, self.vpn.val(fd.id), fd.placeholder, fd.secret, self.vpn.focusedField() == fd.id);
        }
        if (vpnGenRect(l, ti)) |gr| {
            ui_paint.paintBtn(c, gr.x, gr.y, gr.w, gr.h, "Generate", self.vpn.hover == 3);
        }

        // Status / error line (accent, like the C++ dialog).
        if (self.vpn.note_len > 0) {
            ui_paint.showTextW(
                c,
                f(l.x + vpn_pad),
                f(l.btn_area_top - 22),
                self.vpn.note[0..self.vpn.note_len],
                11,
                400,
                f(l.w - 2 * vpn_pad),
                t.acc_r,
                t.acc_g,
                t.acc_b,
                0.9,
            );
        }

        // Footer buttons.
        if (l.import_btn) |ir| {
            ui_paint.paintBtn(c, ir.x, ir.y, ir.w, ir.h, spec.import_label, self.vpn.hover == 4);
        }
        ui_paint.paintBtn(c, l.cancel.x, l.cancel.y, l.cancel.w, l.cancel.h, "Cancel", self.vpn.hover == 2);
        const has_name = self.vpn.val(.name).len > 0;
        if (has_name) {
            paintFilledBtn(c, l.add.x, l.add.y, l.add.w, l.add.h, "Add", true, self.vpn.hover == 1);
        } else {
            paintFilledBtn(c, l.add.x, l.add.y, l.add.w, l.add.h, "Add", false, false);
        }

        // Footer hint, centered like the reference.
        const hint = "Esc or click outside to close";
        const hint_w = ui_paint.measureTextWidth(hint, 11, 400);
        ui_paint.showText(c, f(l.x) + (f(l.w) - f(hint_w)) / 2.0, f(l.y + l.h - vpn_footer_h + 2), hint, 11, 400, t.text_r, t.text_g, t.text_b, 0.40);
    }

    fn vpnSubmit(self: *Page) void {
        const ti = self.vpn.type_i;
        const spec = &vpn_types[ti];
        const name = self.vpn.val(.name);
        if (name.len == 0) {
            self.vpn.setNote("Enter a connection name.");
            return;
        }
        if (ti == 0) {
            const priv = self.vpn.val(.priv_key);
            if (priv.len == 0) {
                self.vpn.setNote("Enter or generate a private key.");
                return;
            }
            const pub_key = self.vpn.val(.server_pub);
            if (pub_key.len == 0) {
                self.vpn.setNote("Enter the server public key.");
                return;
            }
            const endpoint = self.vpn.val(.endpoint);
            if (endpoint.len == 0) {
                self.vpn.setNote("Enter the endpoint (host:port).");
                return;
            }
            const allowed = self.vpn.val(.allowed_ips);
            if (allowed.len == 0) {
                self.vpn.setNote("Enter the allowed IPs.");
                return;
            }
            self.vpn.open = false;
            live_vpn.addWireguardThread(self.io, .{
                .name = name,
                .private_key = priv,
                .server_public_key = pub_key,
                .endpoint = endpoint,
                .allowed_ips = allowed,
                .client_ip = self.vpn.val(.client_ip),
                .dns = self.vpn.val(.dns),
            });
            return;
        }

        if (!pluginAvailable(spec)) {
            var eb: [180]u8 = undefined;
            const msg = std.fmt.bufPrint(&eb, "VPN plugin not installed. Install the \"{s}\" package, then retry.", .{spec.pkg}) catch "";
            self.vpn.setNote(msg);
            return;
        }

        // Required fields: everything except name/port/password/user/PSK,
        // exactly like the C++ validation.
        for (spec.fields) |fd| {
            if (fd.id == .name or fd.id == .port or fd.id == .pass or fd.id == .user or fd.id == .ipsec_psk) continue;
            if (self.vpn.val(fd.id).len == 0) {
                var eb: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&eb, "Enter the {s}.", .{fd.label}) catch "Missing field.";
                self.vpn.setNote(msg);
                return;
            }
        }

        var data_pairs: [8][]const u8 = undefined;
        var data_bufs: [8][200]u8 = undefined;
        var data_n: usize = 0;
        var sec_pairs: [8][]const u8 = undefined;
        var sec_bufs: [8][200]u8 = undefined;
        var sec_n: usize = 0;
        for (spec.fields) |fd| {
            if (fd.id == .name or fd.data_key.len == 0) continue;
            const v = self.vpn.val(fd.id);
            if (v.len == 0) continue;
            if (fd.secret) {
                if (sec_n < sec_pairs.len) {
                    sec_pairs[sec_n] = std.fmt.bufPrint(&sec_bufs[sec_n], "{s}={s}", .{ fd.data_key, v }) catch continue;
                    sec_n += 1;
                }
            } else {
                if (data_n < data_pairs.len) {
                    data_pairs[data_n] = std.fmt.bufPrint(&data_bufs[data_n], "{s}={s}", .{ fd.data_key, v }) catch continue;
                    data_n += 1;
                }
            }
        }
        if (ti == 3 and self.vpn.val(.ipsec_psk).len > 0) {
            if (data_n < data_pairs.len) {
                data_pairs[data_n] = "ipsec-enabled=yes";
                data_n += 1;
            }
        }
        if (ti == 1 and self.vpn.val(.port).len == 0) {
            if (data_n < data_pairs.len) {
                data_pairs[data_n] = "port=1194";
                data_n += 1;
            }
        }

        self.vpn.open = false;
        live_vpn.addVpnThread(self.io, .{
            .name = name,
            .service_type = spec.service_type,
            .data = data_pairs[0..data_n],
            .secrets = sec_pairs[0..sec_n],
        });
    }

    fn vpnGenerate(self: *Page) void {
        const kp = std.crypto.dh.X25519.KeyPair.generate(self.io);
        var priv_b64: [44]u8 = undefined;
        var pub_b64: [44]u8 = undefined;
        const priv = std.base64.standard.Encoder.encode(&priv_b64, &kp.secret_key);
        const pub_key = std.base64.standard.Encoder.encode(&pub_b64, &kp.public_key);
        self.vpn.fieldBuf(.priv_key).set(priv);
        var nb: [180]u8 = undefined;
        const msg = std.fmt.bufPrint(&nb, "Key generated. Your public key (send to the server): {s}", .{pub_key}) catch "";
        self.vpn.setNote(msg);
    }

    /// The file picker, run inline (the dialog closes while it is up). Tries
    /// kdialog, then zenity, then qarma; a missing binary falls through on
    /// `FileNotFound`. Returns a slice into `pick_buf`.
    fn pickVpnFile(self: *Page, wireguard: bool) ?[]const u8 {
        const home = std.c.getenv("HOME");
        const start: []const u8 = if (home) |h| std.mem.span(h) else ".";
        const filter = if (wireguard) "*.conf" else "*.ovpn";

        var kb: [96]u8 = undefined;
        const kfilter = std.fmt.bufPrintSentinel(&kb, "{s}|VPN configs", .{filter}, 0) catch filter;
        const kd = std.process.run(self.alloc, self.io, .{ .argv = &.{
            "kdialog", "--getopenfilename", start, kfilter,
        } }) catch null;
        if (kd) |res| {
            defer self.alloc.free(res.stdout);
            defer self.alloc.free(res.stderr);
            if (res.term == .exited and res.term.exited != 0) return null;
            return self.takePickedPath(res.stdout);
        }

        var zb: [64]u8 = undefined;
        const zfilter = std.fmt.bufPrint(&zb, "--file-filter={s}", .{filter}) catch "--file-filter=*";
        const zn = std.process.run(self.alloc, self.io, .{ .argv = &.{
            "zenity", "--file-selection", "--title=Import VPN Configuration", zfilter,
        } }) catch null;
        if (zn) |res| {
            defer self.alloc.free(res.stdout);
            defer self.alloc.free(res.stderr);
            if (res.term == .exited and res.term.exited != 0) return null;
            return self.takePickedPath(res.stdout);
        }

        const qr = std.process.run(self.alloc, self.io, .{ .argv = &.{
            "qarma", "--file-selection", "--title=Import VPN Configuration", zfilter,
        } }) catch null;
        if (qr) |res| {
            defer self.alloc.free(res.stdout);
            defer self.alloc.free(res.stderr);
            if (res.term == .exited and res.term.exited != 0) return null;
            return self.takePickedPath(res.stdout);
        }
        self.vpn.setNote("Install zenity or kdialog to import a VPN file.");
        return null;
    }

    fn takePickedPath(self: *Page, stdout: []u8) ?[]const u8 {
        const path = std.mem.trim(u8, stdout, " \t\r\n");
        if (path.len == 0 or path.len >= self.pick_buf.len) return null;
        @memcpy(self.pick_buf[0..path.len], path);
        return self.pick_buf[0..path.len];
    }

    fn vpnImport(self: *Page) void {
        const ti = self.vpn.type_i;
        if (ti != 0 and ti != 1) return;
        const spec = &vpn_types[ti];
        const path = self.pickVpnFile(ti == 0) orelse return;
        const dot = std.mem.lastIndexOfScalar(u8, path, '.');
        const ext = if (dot) |d| path[d..] else "";
        if (!std.ascii.eqlIgnoreCase(ext, spec.import_ext)) {
            var eb: [120]u8 = undefined;
            const msg = std.fmt.bufPrint(&eb, "Expected a {s} file.", .{spec.import_ext}) catch "";
            self.vpn.setNote(msg);
            return;
        }
        self.vpn.open = false;
        live_vpn.importThread(self.io, path, ti == 0);
    }

    // -----------------------------------------------------------------
    // Hit test
    // -----------------------------------------------------------------

    pub fn hit(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        self.cur_tab = g.tab;
        self.refresh(false);
        if (self.wifi.open or self.vpn.open) return null;
        return switch (g.tab) {
            wifi_tab => self.hitWifi(g, px, ly),
            wired_tab => self.hitWired(g, px, ly),
            vpn_tab => self.hitVpn(g, px, ly),
            else => null,
        };
    }

    // -----------------------------------------------------------------
    // Modals
    // -----------------------------------------------------------------

    pub fn modalActive(self: *const Page) bool {
        if (self.wifi.open and self.cur_tab == wifi_tab) return true;
        if (self.vpn.open and self.cur_tab == vpn_tab) return true;
        return false;
    }

    pub fn modalDown(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) bool {
        if (self.wifi.open and self.cur_tab == wifi_tab) {
            const l = wifiDlgLay(win_w, win_h);
            const r = wifiDlgRects(l);
            const inside = px >= f(l.x) and px < f(l.x + l.w) and py >= f(l.y) and py < f(l.y + l.h);
            if (!inside) {
                self.wifi.open = false;
                return true;
            }
            self.wifi.press = if (inRect(px, py, r.close))
                3
            else if (inRect(px, py, r.cancel))
                1
            else if (inRect(px, py, r.confirm) and self.wifi.pw_len > 0)
                2
            else
                0;
            return true;
        }
        if (self.vpn.open and self.cur_tab == vpn_tab) {
            const l = vpnDlgLay(self.vpn.type_i, win_w, win_h);
            const inside = px >= f(l.x) and px < f(l.x + l.w) and py >= f(l.y) and py < f(l.y + l.h);
            if (!inside) {
                self.vpn.open = false;
                return true;
            }
            if (inRect(px, py, l.close)) {
                self.vpn.press = 5;
                return true;
            }
            if (py >= f(l.y) and py < f(l.y + vpn_title_h)) {
                self.vpn.press = 0;
                return true;
            }
            for (l.tabs, 0..) |tr, i| {
                if (inRect(px, py, tr)) {
                    self.vpn.type_i = i;
                    self.vpn.press = 0;
                    self.vpn.focus = 0;
                    self.vpn.clearNote();
                    return true;
                }
            }
            const spec = &vpn_types[self.vpn.type_i];
            for (spec.fields, 0..) |fd, fi| {
                if (inRect(px, py, vpnFieldRect(l, self.vpn.type_i, fi))) {
                    self.vpn.focus = @intFromEnum(fd.id) + 1;
                    self.vpn.press = 0;
                    return true;
                }
            }
            if (vpnGenRect(l, self.vpn.type_i)) |gr| {
                if (inRect(px, py, gr)) {
                    self.vpn.press = 3;
                    return true;
                }
            }
            if (l.import_btn) |ir| {
                if (inRect(px, py, ir)) {
                    self.vpn.press = 4;
                    return true;
                }
            }
            self.vpn.focus = 0;
            if (inRect(px, py, l.cancel)) {
                self.vpn.press = 2;
                return true;
            }
            if (inRect(px, py, l.add) and self.vpn.val(.name).len > 0) {
                self.vpn.press = 1;
                return true;
            }
            return true;
        }
        return false;
    }

    pub fn modalUp(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) bool {
        if (self.wifi.open and self.cur_tab == wifi_tab) {
            const l = wifiDlgLay(win_w, win_h);
            const r = wifiDlgRects(l);
            const btn = self.wifi.press;
            self.wifi.press = 0;
            if (btn == 1 and inRect(px, py, r.cancel)) self.wifi.open = false;
            if (btn == 2 and inRect(px, py, r.confirm)) self.submitWifi();
            if (btn == 3 and inRect(px, py, r.close)) self.wifi.open = false;
            return true;
        }
        if (self.vpn.open and self.cur_tab == vpn_tab) {
            const l = vpnDlgLay(self.vpn.type_i, win_w, win_h);
            const btn = self.vpn.press;
            self.vpn.press = 0;
            if (btn == 1 and inRect(px, py, l.add)) self.vpnSubmit();
            if (btn == 2 and inRect(px, py, l.cancel)) self.vpn.open = false;
            if (btn == 3) {
                if (vpnGenRect(l, self.vpn.type_i)) |gr| {
                    if (inRect(px, py, gr)) self.vpnGenerate();
                }
            }
            if (btn == 4) {
                if (l.import_btn) |ir| {
                    if (inRect(px, py, ir)) self.vpnImport();
                }
            }
            if (btn == 5 and inRect(px, py, l.close)) self.vpn.open = false;
            return true;
        }
        return false;
    }

    pub fn modalMotion(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) void {
        if (self.wifi.open and self.cur_tab == wifi_tab) {
            const l = wifiDlgLay(win_w, win_h);
            const r = wifiDlgRects(l);
            self.wifi.hover = if (inRect(px, py, r.close))
                3
            else if (inRect(px, py, r.cancel))
                1
            else if (inRect(px, py, r.confirm) and self.wifi.pw_len > 0)
                2
            else
                0;
            return;
        }
        if (self.vpn.open and self.cur_tab == vpn_tab) {
            const l = vpnDlgLay(self.vpn.type_i, win_w, win_h);
            if (inRect(px, py, l.add) and self.vpn.val(.name).len > 0) {
                self.vpn.hover = 1;
            } else if (inRect(px, py, l.cancel)) {
                self.vpn.hover = 2;
            } else if (vpnGenRect(l, self.vpn.type_i)) |gr| {
                self.vpn.hover = if (inRect(px, py, gr)) 3 else self.vpnTabHover(l, px, py);
            } else if (l.import_btn) |ir| {
                self.vpn.hover = if (inRect(px, py, ir)) 4 else self.vpnTabHover(l, px, py);
            } else if (inRect(px, py, l.close)) {
                self.vpn.hover = 5;
            } else {
                self.vpn.hover = self.vpnTabHover(l, px, py);
            }
        }
    }

    fn vpnTabHover(self: *Page, l: VpnDlgLay, px: f64, py: f64) i32 {
        _ = self;
        for (l.tabs, 0..) |tr, i| {
            if (inRect(px, py, tr)) return 10 + @as(i32, @intCast(i));
        }
        return 0;
    }

    pub fn modalAxis(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64, delta: f64) bool {
        _ = delta;
        if (self.wifi.open and self.cur_tab == wifi_tab) {
            const l = wifiDlgLay(win_w, win_h);
            return px >= f(l.x) and px <= f(l.x + l.w) and py >= f(l.y) and py <= f(l.y + l.h);
        }
        if (self.vpn.open and self.cur_tab == vpn_tab) {
            const l = vpnDlgLay(self.vpn.type_i, win_w, win_h);
            return px >= f(l.x) and px <= f(l.x + l.w) and py >= f(l.y) and py <= f(l.y + l.h);
        }
        return false;
    }

    pub fn key(self: *Page, sym: u32, text: []const u8) bool {
        if (!self.inited) return false;
        if (self.wifi.open and self.cur_tab == wifi_tab) {
            switch (sym) {
                xkb.XKB_KEY_Escape => self.wifi.open = false,
                xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => self.submitWifi(),
                xkb.XKB_KEY_BackSpace => {
                    if (self.wifi.pw_len > 0) {
                        self.wifi.pw_len -= 1;
                        while (self.wifi.pw_len > 0 and (self.wifi.pw[self.wifi.pw_len] & 0xC0) == 0x80) self.wifi.pw_len -= 1;
                    }
                },
                else => {
                    if (text.len > 0) {
                        const room = self.wifi.pw.len - self.wifi.pw_len;
                        const n = @min(text.len, room);
                        @memcpy(self.wifi.pw[self.wifi.pw_len..][0..n], text[0..n]);
                        self.wifi.pw_len += n;
                    }
                },
            }
            return true;
        }
        if (self.vpn.open and self.cur_tab == vpn_tab) {
            switch (sym) {
                xkb.XKB_KEY_Escape => self.vpn.open = false,
                xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => {
                    if (self.vpn.val(.name).len > 0) self.vpnSubmit();
                },
                xkb.XKB_KEY_Tab => {
                    const spec = &vpn_types[self.vpn.type_i];
                    if (spec.fields.len == 0) return true;
                    if (self.vpn.focus == 0) {
                        self.vpn.focus = @intFromEnum(spec.fields[0].id) + 1;
                    } else {
                        var found = false;
                        for (spec.fields, 0..) |fd, i| {
                            if (@intFromEnum(fd.id) + 1 == self.vpn.focus) {
                                const next = (i + 1) % spec.fields.len;
                                self.vpn.focus = @intFromEnum(spec.fields[next].id) + 1;
                                found = true;
                                break;
                            }
                        }
                        if (!found) self.vpn.focus = @intFromEnum(spec.fields[0].id) + 1;
                    }
                },
                xkb.XKB_KEY_BackSpace => {
                    if (self.vpn.focusedField()) |id| self.vpn.fieldBuf(id).pop();
                },
                else => {
                    if (self.vpn.focusedField()) |id| {
                        if (text.len > 0) self.vpn.fieldBuf(id).push(text);
                    }
                },
            }
            return true;
        }
        if (self.cur_tab == vpn_tab) return self.keyVpn(sym, text);
        return false;
    }
};

// ---------------------------------------------------------------------------
// Shared painters
// ---------------------------------------------------------------------------

const Col = struct { r: f64, g: f64, b: f64 };

/// An outlined pill row button. The VPN/Wi-Fi rows use 11px labels (the C++
/// `Button::Size::XS`) and a caller-chosen tone, so "Disconnect" can be red.
fn paintPillBtn(
    c: *cairo.cairo_t,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    label: []const u8,
    hovered: bool,
    enabled: bool,
    col: Col,
) void {
    const t = common.Theme;
    const xf = f(x);
    const yf = f(y);
    const wf = f(w);
    const hf = f(h);
    const rad = @min(wf, hf) * 0.5;
    ui_paint.glassBox(c, xf, yf, wf, hf, rad, 0.102, 0.075, 0.188, if (enabled) 0.08 else 0.06);
    if (enabled and hovered) ui_paint.glassBox(c, xf, yf, wf, hf, rad, t.acc_r, t.acc_g, t.acc_b, 0.08);
    cairo.cairo_save(c);
    ui_paint.roundRect(c, xf + 0.5, yf + 0.5, wf - 1, hf - 1, @max(0.5, rad - 0.5));
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, if (enabled) 1.0 else 0.12);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);

    const ts = ui_paint.textSizePx(c, label, 11, 500);
    const lx = xf + (wf - f(ts.w)) / 2.0;
    const top = yf + (hf - f(ts.h)) / 2.0;
    const a: f64 = if (enabled) 1.0 else 0.38;
    ui_paint.showText(c, lx + 1, top + f(ts.h) - 2 + 1, label, 11, 500, 0, 0, 0, a * 0.35);
    ui_paint.showText(c, lx, top + f(ts.h) - 2, label, 11, 500, col.r, col.g, col.b, a);
}

/// Accent-filled primary button (the dialog's Add).
fn paintFilledBtn(c: *cairo.cairo_t, x: i32, y: i32, w: i32, h: i32, label: []const u8, enabled: bool, hovered: bool) void {
    const t = common.Theme;
    const xf = f(x);
    const yf = f(y);
    const wf = f(w);
    const hf = f(h);
    const rad = @min(wf, hf) * 0.5;
    const a: f64 = if (!enabled) 0.10 else if (hovered) 0.92 else 1.0;
    ui_paint.glassBox(c, xf, yf, wf, hf, rad, t.acc_r, t.acc_g, t.acc_b, a);
    const ts = ui_paint.textSizePx(c, label, 12, 500);
    const lx = xf + (wf - f(ts.w)) / 2.0;
    const top = yf + (hf - f(ts.h)) / 2.0;
    const fg = if (enabled) Col{ .r = t.bg_r * 0.55, .g = t.bg_g * 0.55, .b = t.bg_b * 0.55 } else Col{ .r = t.text_r, .g = t.text_g, .b = t.text_b };
    ui_paint.showText(c, lx, top + f(ts.h) - 2, label, 12, 500, fg.r, fg.g, fg.b, if (enabled) 1.0 else 0.38);
}

fn paintWiredToggle(
    c: *cairo.cairo_t,
    card_x: i32,
    card_w: i32,
    band_top: i32,
    local_row: i32,
    on: bool,
    label: []const u8,
    desc: ?[]const u8,
) void {
    const t = common.Theme;
    const band = band_top + local_row * common.slider_row_h;
    if (local_row > 0) {
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.15);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_move_to(c, f(card_x + k_pad + 8), f(band));
        cairo.cairo_line_to(c, f(card_x + card_w - k_pad - 8), f(band));
        cairo.cairo_stroke(c);
    }
    const title_y = band + 36;
    ui_paint.showText(c, f(card_x + k_pad), f(title_y), label, 14, 500, t.text_r, t.text_g, t.text_b, 0.93);
    if (desc) |d| {
        ui_paint.showText(c, f(card_x + k_pad), f(title_y + 17), d, 11, 400, t.text_r, t.text_g, t.text_b, 0.46);
    }
    const tg_w: i32 = 40;
    const tg_x = card_x + card_w - k_pad - tg_w;
    const tg_y = band + @divTrunc(common.slider_row_h, 2) - 12;
    ui_paint.paintSwitch(c, tg_x, tg_y, tg_w, 24, on);
}

fn paintWiredSlider(
    c: *cairo.cairo_t,
    card_x: i32,
    card_w: i32,
    band: i32,
    label: []const u8,
    value: i32,
    lo: i32,
    hi: i32,
) void {
    const t = common.Theme;
    ui_paint.showText(c, f(card_x + k_pad), f(band + 24), label, 14, 500, t.text_r, t.text_g, t.text_b, 0.93);

    var vbuf: [32]u8 = undefined;
    const vs = std.fmt.bufPrint(&vbuf, "{d}", .{value}) catch "";
    const pill_w = ui_paint.measureTextWidth(vs, 11, 500) + 16;
    const pill_h: i32 = 20;
    const pill_x = card_x + card_w - k_pad - pill_w;
    const pill_y = band + 14;
    ui_paint.roundRect(c, f(pill_x), f(pill_y), f(pill_w), f(pill_h), f(@divTrunc(pill_h, 2)));
    cairo.cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, 0.08);
    cairo.cairo_fill(c);
    ui_paint.showText(c, f(pill_x + 8), f(pill_y + @divTrunc(pill_h, 2) + 4), vs, 11, 500, t.text_r, t.text_g, t.text_b, 0.60);

    const tr_x = card_x + 8;
    const tr_w = card_w - 84;
    const tr_cy = band + 40 + 14;
    cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.30);
    cairo.cairo_set_line_width(c, 4.0);
    cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_move_to(c, f(tr_x), f(tr_cy));
    cairo.cairo_line_to(c, f(tr_x + tr_w), f(tr_cy));
    cairo.cairo_stroke(c);

    const span: f64 = @floatFromInt(@max(1, hi - lo));
    const frac = std.math.clamp(@as(f64, @floatFromInt(value - lo)) / span, 0.0, 1.0);
    const knob_x = f(tr_x) + f(tr_w) * frac;
    if (frac > 0) {
        cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 1.0);
        cairo.cairo_set_line_width(c, 4.0);
        cairo.cairo_move_to(c, f(tr_x), f(tr_cy));
        cairo.cairo_line_to(c, knob_x, f(tr_cy));
        cairo.cairo_stroke(c);
    }
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.96);
    cairo.cairo_arc(c, knob_x, f(tr_cy), 7, 0, 6.283185307179586);
    cairo.cairo_fill(c);
}

/// A text field with the settings2 focus treatment. `value` is masked when
/// `secret`; the caret is painted at the end while `focused`.
fn paintField(c: *cairo.cairo_t, r: common.Rect, value: []const u8, placeholder: []const u8, secret: bool, focused: bool) void {
    const t = common.Theme;
    const xf = f(r.x);
    const yf = f(r.y);
    const wf = f(r.w);
    const hf = f(r.h);
    ui_paint.glassBox(c, xf, yf, wf, hf, 8, 0.102, 0.075, 0.188, 0.10);
    cairo.cairo_save(c);
    ui_paint.roundRect(c, xf + 0.5, yf + 0.5, wf - 1, hf - 1, 7.5);
    cairo.cairo_set_line_width(c, 1.0);
    if (focused) {
        cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.80);
    } else {
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.45);
    }
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);

    const text_y = yf + hf * 0.5 + 5;
    const max_w = wf - 16;
    if (value.len == 0) {
        if (!focused) {
            ui_paint.showTextW(c, xf + 8, text_y, placeholder, 13, 400, max_w, t.text_r, t.text_g, t.text_b, 0.35);
            return;
        }
        ui_paint.showText(c, xf + 8, text_y, "|", 13, 400, t.text_r, t.text_g, t.text_b, 0.70);
        return;
    }

    var mask: [64]u8 = undefined;
    var shown: []const u8 = value;
    if (secret) {
        const n = @min(value.len, 16);
        var k: usize = 0;
        for (0..n) |_| {
            mask[k] = 0xe2;
            mask[k + 1] = 0x80;
            mask[k + 2] = 0xa2;
            k += 3;
        }
        shown = mask[0..k];
    }
    ui_paint.showTextW(c, xf + 8, text_y, shown, 13, 400, max_w - 6, t.text_r, t.text_g, t.text_b, 0.90);
    if (focused) {
        const tw = @min(ui_paint.measureTextWidth(shown, 13, 400), @as(i32, @intFromFloat(max_w)) - 6);
        ui_paint.showText(c, xf + 8 + f(tw), text_y, "|", 13, 400, t.text_r, t.text_g, t.text_b, 0.70);
    }
}

fn addWiredRow(c: *cairo.cairo_t, card_x: i32, row_y: *i32, label: []const u8, value: []const u8) void {
    if (value.len == 0) return;
    const t = common.Theme;
    if (label.len == 0) {
        // Continuation of a multi-value row (DNS / search domains) — indent
        // instead of the reference's bare ": value".
        ui_paint.showTextW(c, f(card_x + k_pad + 12), f(row_y.* + 16), value, 13, 400, f(620), t.text_r, t.text_g, t.text_b, 1.0);
        row_y.* += 26;
        return;
    }
    var buf: [400]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s}: {s}", .{ label, value }) catch return;
    ui_paint.showTextW(c, f(card_x + k_pad), f(row_y.* + 16), text, 13, 400, f(620), t.text_r, t.text_g, t.text_b, 1.0);
    row_y.* += 26;
}

// ---------------------------------------------------------------------------
// VPN plugin probe / file helpers
// ---------------------------------------------------------------------------

fn pluginAvailable(spec: *const VpnTypeSpec) bool {
    if (spec.pkg.len == 0) return true;
    const name = if (std.mem.startsWith(u8, spec.pkg, "networkmanager-"))
        spec.pkg["networkmanager-".len..]
    else
        spec.pkg;
    // The plugin file and its `.name` service descriptor live together; the
    // directory differs by distro (Fedora/Arch: directly under
    // NetworkManager; Debian: the multiarch triplet directory).
    const dirs = [_][]const u8{
        "/usr/lib/NetworkManager/VPN/",
        "/usr/lib/NetworkManager/",
        "/usr/lib64/NetworkManager/VPN/",
        "/usr/lib64/NetworkManager/",
        "/usr/lib/x86_64-linux-gnu/NetworkManager/VPN/",
        "/usr/lib/x86_64-linux-gnu/NetworkManager/",
        "/usr/lib/aarch64-linux-gnu/NetworkManager/VPN/",
        "/usr/lib/aarch64-linux-gnu/NetworkManager/",
    };
    var buf: [224]u8 = undefined;
    for (dirs) |dir| {
        const lib = std.fmt.bufPrintSentinel(&buf, "{s}libnm-vpn-plugin-{s}.so", .{ dir, name }, 0) catch continue;
        if (std.c.access(@ptrCast(lib.ptr), std.c.R_OK) == 0) return true;
        const svc = std.fmt.bufPrintSentinel(&buf, "{s}nm-{s}-service.name", .{ dir, name }, 0) catch continue;
        if (std.c.access(@ptrCast(svc.ptr), std.c.R_OK) == 0) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "network: band labels follow the reference thresholds" {
    const t = std.testing;
    try t.expectEqualStrings("", bandLabel(0));
    try t.expectEqualStrings("2.4G", bandLabel(2412));
    try t.expectEqualStrings("5G", bandLabel(5180));
    try t.expectEqualStrings("6G", bandLabel(6115));
}

test "network: VPN row state machine moves connecting to connected" {
    const t = std.testing;
    var r = VpnRow{};
    const now: i64 = 1_000_000;
    try t.expectEqual(VpnShown.idle, r.shownState(now));
    r.phase = .connecting;
    r.connect_started_ms = now;
    r.progress = 0.05;
    try t.expectEqual(VpnShown.connecting, r.shownState(now + 100));
    r.active = true;
    r.timestamp = 900;
    r.settle_until_ms = now + 300;
    try t.expectEqual(VpnShown.connecting, r.shownState(now + 299));
    try t.expectEqual(VpnShown.connected, r.shownState(now + 300));
    try t.expectEqual(@as(i64, 100_300), r.uptimeMs(now + 300));
    r.phase = .backend;
    r.active = false;
    r.observeBackend(true, now + 400);
    try t.expectEqual(VpnShown.failed, r.shownState(now + 400));
    try t.expectEqualStrings("Connection lost", r.failText());
}

test "network: VPN format helpers keep the design's mono fields" {
    const t = std.testing;
    try t.expectEqualStrings("01:01:01", Page.fmtUptime(3_661_000));
    try t.expectEqualStrings("2.4 MB/s", Page.fmtRate(2_400_000));
    try t.expectEqualStrings("310 KB/s", Page.fmtRate(310_000));
    try t.expectEqualStrings("3 saved", Page.fmtSaved(3));
    try t.expectEqualStrings("62%", Page.fmtPercent(0.62));
}

test "network: VPN dialog hugs each type's form" {
    const t = std.testing;
    // WireGuard has seven 66px rows; the plugin forms have four or five.
    try t.expectEqual(@as(i32, 120 + 6 * 66 + 7 + 34 + 108), vpnDialogH(0));
    try t.expectEqual(@as(i32, 120 + 4 * 66 + 7 + 34 + 108), vpnDialogH(1));
    try t.expectEqual(@as(i32, 120 + 3 * 66 + 7 + 34 + 108), vpnDialogH(2));
}

test "network: dialog geometry stays inside the window" {
    const t = std.testing;
    const l = vpnDlgLay(0, app_mod.window_width, app_mod.window_height);
    try t.expect(l.x >= 20);
    try t.expect(l.y >= 20);
    try t.expect(l.x + l.w <= app_mod.window_width);
    try t.expect(l.y + l.h <= app_mod.window_height);
    try t.expectEqual(@as(i32, 88), vpnGenRect(l, 0).?.w);
    try t.expect(vpnGenRect(l, 1) == null);
}

test "network: field tables match the reference" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 7), wg_fields.len);
    try t.expectEqual(@as(usize, 5), ovpn_fields.len);
    try t.expectEqual(@as(usize, 4), ikev2_fields.len);
    try t.expectEqual(@as(usize, 5), l2tp_fields.len);
    try t.expectEqual(@as(usize, 4), pptp_fields.len);
    try t.expectEqual(@as(usize, 4), anyconnect_fields.len);
    try t.expectEqualStrings("remote", ovpn_fields[1].data_key);
    try t.expectEqualStrings("vpnhost", anyconnect_fields[1].data_key);
    try t.expect(l2tp_fields[4].secret);
}
