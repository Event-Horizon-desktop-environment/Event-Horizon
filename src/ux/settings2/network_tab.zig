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

fn nowMs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * 1000 + @divTrunc(@as(i64, @intCast(@max(ts.nsec, 0))), 1_000_000);
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
    btn_x: i32,
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
        .btn_x = right_x - 22 - 64 - 10,
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

fn apBtnRect(l: WifiLay, i: usize) common.Rect {
    return .{
        .x = l.btn_x,
        .y = l.list_y + @as(i32, @intCast(i)) * k_ap_row_h + 5,
        .w = 64,
        .h = 24,
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

const VpnRow = struct {
    uuid: [64]u8 = undefined,
    uuid_len: usize = 0,
    name: [200]u8 = undefined,
    name_len: usize = 0,
    active: bool = false,
    autoconnect: bool = false,

    pending_active: bool = false,
    active_target: bool = false,
    active_since: i64 = 0,
    pending_auto: bool = false,
    auto_target: bool = false,
    auto_since: i64 = 0,

    fn uuidText(self: *const VpnRow) []const u8 {
        return self.uuid[0..self.uuid_len];
    }

    fn nameText(self: *const VpnRow) []const u8 {
        return self.name[0..self.name_len];
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

    fn shownActive(self: *const VpnRow) bool {
        return if (self.pending_active) self.active_target else self.active;
    }

    fn shownAuto(self: *const VpnRow) bool {
        return if (self.pending_auto) self.auto_target else self.autoconnect;
    }
};

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

    status_buf: [220]u8 = undefined,
    status_len: usize = 0,
    status_failed: bool = false,
    status_until_ms: i64 = 0,

    pick_buf: [1024]u8 = undefined,

    pub fn init(self: *Page, alloc: std.mem.Allocator, io: std.Io) void {
        self.* = .{ .alloc = alloc, .io = io };
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
        live_vpn.shutdown();
        self.inited = false;
    }

    fn qPtr(self: *Page) ?*const live_net.SettingsSnapshot {
        return if (self.have_q) &self.q else null;
    }

    fn scanning(self: *const Page) bool {
        return nowMs() < self.scan_until_ms;
    }

    /// Poll the live backends. Throttled: the D-Bus snapshot every 1.5 s and
    /// the nmcli VPN read every 2 s, plus the non-blocking drains. Safe to
    /// call from every layout/paint/hit pass.
    fn refresh(self: *Page, force: bool) void {
        if (!self.inited) return;
        const now = nowMs();
        if (force or now - self.last_query_ms >= 1500) {
            self.last_query_ms = now;
            if (live_net.settingsQuery(self.alloc)) |q| {
                if (self.have_q) self.q.deinit();
                self.q = q;
                self.have_q = true;
            }
        }
        if (force or now - self.last_vpn_req_ms >= 2000) {
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
        var sbuf: [220]u8 = undefined;
        var failed = false;
        if (live_vpn.takeStatus(&sbuf, &failed)) |n| {
            @memcpy(self.status_buf[0..n], sbuf[0..n]);
            self.status_len = n;
            self.status_failed = failed;
            self.status_until_ms = now + 6000;
        }
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

    /// UUID-anchored reconcile with the optimistic pending windows, like the
    /// C++ `VpnEntry` list: keep the shown value until NM confirms it or 8 s
    /// elapse, so a click never flips back while `nmcli` is in flight.
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
            var r = VpnRow{ .active = c.active, .autoconnect = c.autoconnect };
            r.setUuid(c.uuid);
            r.setName(c.name);
            if (self.findVpn(c.uuid)) |old| {
                if (old.pending_active and c.active != old.active_target and now - old.active_since < 8000) {
                    r.pending_active = true;
                    r.active_target = old.active_target;
                    r.active_since = old.active_since;
                }
                if (old.pending_auto and c.autoconnect != old.auto_target and now - old.auto_since < 8000) {
                    r.pending_auto = true;
                    r.auto_target = old.auto_target;
                    r.auto_since = old.auto_since;
                }
            }
            out.append(self.alloc, r) catch {};
        }
        self.vpn_rows.deinit(self.alloc);
        self.vpn_rows = out;
        self.vpn_have = true;
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
            const rows: usize = self.vpn_rows.items.len;
            return vpnCardH(rows) + k_bottom;
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
            if (inRect(px, ly, row)) {
                ui_paint.glassBox(c, f(row.x + 2), f(row.y), f(row.w - 4), f(row.h), 8, t.bg_r, t.bg_g, t.bg_b, 0.18);
            }
            const cy = row.y + @divTrunc(k_ap_row_h, 2);
            ui_paint.glyph(c, f(row.x + 20), f(cy), 20, "wifi", t.text_r, t.text_g, t.text_b, 1.0);

            const ssid_x = row.x + 48;
            const ssid_y = cy + 6;
            ui_paint.showText(c, f(ssid_x), f(ssid_y), ap.ssid, 13, 400, t.text_r, t.text_g, t.text_b, 1.0);
            const ssid_w = ui_paint.measureTextWidth(ap.ssid, 13, 400);
            var label_x = ssid_x + 4 + ssid_w + 4;
            const band = bandLabel(ap.frequency);
            if (band.len > 0) {
                ui_paint.showText(c, f(label_x), f(cy + 4), band, 9, 400, t.text_r, t.text_g, t.text_b, 1.0);
                label_x += ui_paint.measureTextWidth(band, 9, 400) + 4;
            }
            const sec = ap.security.label();
            if (sec.len > 0) {
                ui_paint.showText(c, f(label_x), f(cy + 4), sec, 9, 400, t.text_r, t.text_g, t.text_b, 1.0);
            }

            var pbuf: [16]u8 = undefined;
            const pct = std.fmt.bufPrint(&pbuf, "{d}%", .{ap.strength}) catch "";
            const pct_w = ui_paint.measureTextWidth(pct, 10, 400);
            ui_paint.showText(c, f(l.right_x - pct_w), f(cy + 5), pct, 10, 400, t.text_r, t.text_g, t.text_b, 1.0);

            const br = apBtnRect(l, i);
            const label = if (ap.active) "Disconnect" else "Connect";
            const col = if (ap.active)
                Col{ .r = 0.95, .g = 0.30, .b = 0.25 }
            else
                Col{ .r = t.acc_r, .g = t.acc_g, .b = t.acc_b };
            paintPillBtn(c, br.x, br.y, br.w, br.h, label, inRect(px, ly, br), true, col);
            if (ap.active) {
                cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.95);
                cairo.cairo_arc(c, f(br.x - 42), f(cy), 4, 0, 6.283185307179586);
                cairo.cairo_fill(c);
            }
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
            self.refresh(true);
            return .repaint;
        }
        if (l.scan) |sr| {
            if (inRect(px, ly, sr) and !self.scanning()) {
                live_net.rescanThread(self.io);
                self.scan_until_ms = nowMs() + 6000;
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
    // VPN
    // -----------------------------------------------------------------

    fn vpnBtnW() i32 {
        const w1 = ui_paint.measureTextWidth("Connect", 11, 500);
        const w2 = ui_paint.measureTextWidth("Disconnect", 11, 500);
        return @max(@max(w1, w2) + 8, 64);
    }

    fn vpnCardH(rows: usize) i32 {
        return 52 + @as(i32, @intCast(rows)) * 44 + 8 + 44 + common.spacing_l;
    }

    fn paintVpn(self: *Page, c: *cairo.cairo_t, g: Geo, px: f64, ly: f64, glass_ov: f64) void {
        const t = common.Theme;
        const card_x = g.content_x + 8;
        const card_w = g.content_w - 16;
        const rows = self.vpn_rows.items.len;
        const card_h = vpnCardH(rows);
        ui_paint.card(c, f(card_x), f(k_top), f(card_w), f(card_h), glass_ov);
        ui_paint.showText(c, f(card_x + k_pad), f(k_top + 30), "VPN Connections", 14, 700, t.text_r, t.text_g, t.text_b, 1.0);

        const btn_w = vpnBtnW();
        const btn_x = card_x + card_w - k_pad - btn_w - 12 - 28;
        for (self.vpn_rows.items, 0..) |*r, i| {
            const vry = k_top + 52 + @as(i32, @intCast(i)) * 44;
            const btn_y = vry + 10;
            const pill_x = card_x + k_pad;
            const pill_w = btn_x - 12 - 44 - 8 - pill_x;
            const pill_h: i32 = 40;
            const rad = @max(2.0, @as(f64, @floatFromInt(@min(40, pill_w))) * 0.22);

            // Pill: the reference fills with the panel colour and outlines
            // with the surface/accent blend.
            const pr = t.bg_r * 0.8 + t.acc_r * 0.2;
            const pg = t.bg_g * 0.8 + t.acc_g * 0.2;
            const pb = t.bg_b * 0.8 + t.acc_b * 0.2;
            ui_paint.glassBox(c, f(pill_x), f(vry + 2), f(pill_w), f(pill_h), rad, t.bg_r, t.bg_g, t.bg_b, 0.35);
            cairo.cairo_save(c);
            ui_paint.roundRect(c, f(pill_x) + 0.5, f(vry + 2) + 0.5, f(pill_w) - 1, f(pill_h) - 1, @max(0.5, rad - 0.5));
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_set_source_rgba(c, pr, pg, pb, 0.35);
            cairo.cairo_stroke(c);
            cairo.cairo_restore(c);
            const pill = common.Rect{ .x = pill_x, .y = vry + 2, .w = pill_w, .h = pill_h };
            if (inRect(px, ly, pill)) {
                ui_paint.glassBox(c, f(pill_x), f(vry + 2), f(pill_w), f(pill_h), rad, t.bg_r, t.bg_g, t.bg_b, 0.18);
                cairo.cairo_save(c);
                ui_paint.roundRect(c, f(pill_x) + 0.5, f(vry + 2) + 0.5, f(pill_w) - 1, f(pill_h) - 1, @max(0.5, rad - 0.5));
                cairo.cairo_set_line_width(c, 1.0);
                cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.35);
                cairo.cairo_stroke(c);
                cairo.cairo_restore(c);
            }

            const dot_cx = pill_x + 16;
            const mid_y = vry + 22;
            const active = r.shownActive();
            cairo.cairo_set_source_rgba(
                c,
                if (active) t.acc_r else t.text_r,
                if (active) t.acc_g else t.text_g,
                if (active) t.acc_b else t.text_b,
                if (active) 0.95 else 0.35,
            );
            cairo.cairo_arc(c, f(dot_cx), f(mid_y), 4, 0, 6.283185307179586);
            cairo.cairo_fill(c);

            const name_x = dot_cx + 16;
            const name_w = pill_x + pill_w - name_x - 12;
            ui_paint.showTextW(c, f(name_x), f(mid_y + 5), r.nameText(), 13, 400, f(name_w), t.text_r, t.text_g, t.text_b, 1.0);

            const br = common.Rect{ .x = btn_x, .y = btn_y, .w = btn_w, .h = 24 };
            const label = if (active) "Disconnect" else "Connect";
            const col = if (active)
                Col{ .r = 0.95, .g = 0.30, .b = 0.25 }
            else
                Col{ .r = t.acc_r, .g = t.acc_g, .b = t.acc_b };
            paintPillBtn(c, br.x, br.y, br.w, br.h, label, inRect(px, ly, br), true, col);

            const auto_x = btn_x - 12 - 44;
            const auto_y = btn_y;
            ui_paint.paintSwitch(c, auto_x, auto_y, 44, 24, r.shownAuto());
            const auto_lbl_w = ui_paint.measureTextWidth("auto", 10, 400);
            ui_paint.showText(c, f(auto_x - 6 - auto_lbl_w), f(mid_y + 4), "auto", 10, 400, t.text_r, t.text_g, t.text_b, 0.55);

            const re = self.vpnRemoveRect(btn_x, btn_w, btn_y);
            const remove_hov = inRect(px, ly, re);
            ui_paint.glassBox(c, f(re.x), f(re.y), f(re.w), f(re.h), 7, t.bg_r, t.bg_g, t.bg_b, if (remove_hov) 0.40 else 0.20);
            cairo.cairo_save(c);
            ui_paint.roundRect(c, f(re.x) + 0.5, f(re.y) + 0.5, f(re.w) - 1, f(re.h) - 1, 7);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_set_source_rgba(c, 0.85, 0.25, 0.20, if (remove_hov) 0.55 else 0.30);
            cairo.cairo_stroke(c);
            cairo.cairo_restore(c);
            ui_paint.glyph(c, f(re.x + 14), f(re.y + 14), 16, "delete", t.text_r, t.text_g, t.text_b, if (remove_hov) 0.85 else 0.55);
        }

        // "+ Add VPN" row.
        const add_area_y = k_top + 52 + @as(i32, @intCast(rows)) * 44 + 8;
        const add_w = @max(ui_paint.measureTextWidth("+ Add VPN", 12, 500) + 8, 64);
        const add_y = add_area_y + 10;
        const add_x = card_x + card_w - k_pad - add_w;
        ui_paint.paintBtn(c, add_x, add_y, add_w, 24, "+ Add VPN", inRect(px, ly, .{ .x = add_x, .y = add_y, .w = add_w, .h = 24 }));

        // Async verb / import result, transient.
        if (self.status_len > 0 and nowMs() < self.status_until_ms) {
            const col = if (self.status_failed)
                Col{ .r = 0.95, .g = 0.35, .b = 0.30 }
            else
                Col{ .r = t.acc_r, .g = t.acc_g, .b = t.acc_b };
            ui_paint.showTextW(
                c,
                f(card_x),
                f(k_top + card_h + 20),
                self.status_buf[0..self.status_len],
                11,
                400,
                f(card_w),
                col.r,
                col.g,
                col.b,
                0.9,
            );
        }
    }

    fn vpnRemoveRect(self: *Page, btn_x: i32, btn_w: i32, btn_y: i32) common.Rect {
        _ = self;
        return .{ .x = btn_x + btn_w + 12, .y = btn_y - 2, .w = 28, .h = 28 };
    }

    fn vpnAddRect(self: *Page, g: Geo) common.Rect {
        const card_x = g.content_x + 8;
        const card_w = g.content_w - 16;
        const rows = self.vpn_rows.items.len;
        const add_area_y = k_top + 52 + @as(i32, @intCast(rows)) * 44 + 8;
        const add_w = @max(ui_paint.measureTextWidth("+ Add VPN", 12, 500) + 8, 64);
        return .{
            .x = card_x + card_w - k_pad - add_w,
            .y = add_area_y + 10,
            .w = add_w,
            .h = 24,
        };
    }

    fn hitVpn(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        const card_x = g.content_x + 8;
        const card_w = g.content_w - 16;
        const btn_w = vpnBtnW();
        const btn_x = card_x + card_w - k_pad - btn_w - 12 - 28;
        const now = nowMs();
        for (self.vpn_rows.items, 0..) |*r, i| {
            const vry = k_top + 52 + @as(i32, @intCast(i)) * 44;
            const btn_y = vry + 10;
            const re = self.vpnRemoveRect(btn_x, btn_w, btn_y);
            if (inRect(px, ly, re)) {
                live_vpn.removeThread(self.io, r.uuidText());
                self.markRemoving(r.uuidText());
                // Drop just this row; the next poll either confirms the
                // deletion or re-adds it (the marker keeps it hidden while
                // its `nmcli delete` is still running).
                var j = i;
                while (j + 1 < self.vpn_rows.items.len) : (j += 1) {
                    self.vpn_rows.items[j] = self.vpn_rows.items[j + 1];
                }
                self.vpn_rows.items.len -= 1;
                return .repaint;
            }
            const br = common.Rect{ .x = btn_x, .y = btn_y, .w = btn_w, .h = 24 };
            if (inRect(px, ly, br)) {
                const active = r.shownActive();
                r.pending_active = true;
                r.active_target = !active;
                r.active_since = now;
                if (active) {
                    live_vpn.deactivateThread(self.io, r.uuidText());
                    live_vpn.setAutoconnectThread(self.io, r.uuidText(), false);
                    r.pending_auto = true;
                    r.auto_target = false;
                    r.auto_since = now;
                } else {
                    live_vpn.activateThread(self.io, r.uuidText());
                }
                return .repaint;
            }
            const auto = common.Rect{ .x = btn_x - 12 - 44, .y = btn_y, .w = 44, .h = 24 };
            if (inRect(px, ly, auto)) {
                const on = r.shownAuto();
                r.pending_auto = true;
                r.auto_target = !on;
                r.auto_since = now;
                live_vpn.setAutoconnectThread(self.io, r.uuidText(), !on);
                return .repaint;
            }
        }
        if (inRect(px, ly, self.vpnAddRect(g))) {
            self.openVpnDialog();
            return .repaint;
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

test "network: VPN card height tracks the roster" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 52 + 8 + 44 + 16), Page.vpnCardH(0));
    try t.expectEqual(@as(i32, 52 + 8 + 44 + 16 + 88), Page.vpnCardH(2));
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
