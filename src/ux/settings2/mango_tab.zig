const std = @import("std");
const common = @import("common.zig");

// Mango tab (7 sub-tabs).
// Same design: one scroll offset, per-section cards, shared MangoConfig.

pub const sections = [_][]const u8{
    "Decoration", "Colors", "Animations", "Keybinds", "Layout", "Input", "Misc",
};

pub const MangoModel = struct {
    section_tab: i32 = 0,
    scroll_px: i32 = 0,
    border_width: i32 = 2,
    gaps: i32 = 8,
    rounding: i32 = 8,
    master_ratio_pct: i32 = 55,

    pub fn clampAll(self: *MangoModel) void {
        if (self.section_tab < 0 or self.section_tab >= sections.len) self.section_tab = 0;
        self.border_width = common.clampInt(self.border_width, 0, 16);
        self.gaps = common.clampInt(self.gaps, 0, 64);
        self.rounding = common.clampInt(self.rounding, 0, 32);
        self.master_ratio_pct = common.clampInt(self.master_ratio_pct, 20, 80);
        if (self.scroll_px < 0) self.scroll_px = 0;
    }
};

// Network tabs: Wi-Fi / Wired (6 child tabs) / VPN.
// settings_tab_network/*, tabs/*, dialogs/*, m3/* (logic only).
// Same design: wifi list + password prompt state, wired child tabs,
// VPN type combo + per-type fields.

pub const wired_children = [_][]const u8{
    "Status", "IPv4", "IPv6", "Ethernet", "Security", "Advanced",
};

pub const vpn_types = [_][]const u8{
    "WireGuard", "OpenVPN", "VPNC", "OpenConnect", "L2TP", "PPTP", "StrongSwan", "AnyConnect",
};

pub const NetworkModel = struct {
    wifi_enabled: bool = true,
    wired_child: i32 = 0,
    vpn_type: i32 = 0,
    show_password: bool = false,

    pub fn clampAll(self: *NetworkModel) void {
        if (self.wired_child < 0 or self.wired_child >= wired_children.len) self.wired_child = 0;
        if (self.vpn_type < 0 or self.vpn_type >= vpn_types.len) self.vpn_type = 0;
    }
};

test "settings-mango-network: sections" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 7), sections.len);
    var m = MangoModel{};
    m.clampAll();
    try t.expectEqual(@as(i32, 0), m.section_tab);
    var n = NetworkModel{ .wired_child = 99, .vpn_type = -1 };
    n.clampAll();
    try t.expectEqual(@as(i32, 0), n.wired_child);
    try t.expectEqual(@as(usize, 8), vpn_types.len);
}
