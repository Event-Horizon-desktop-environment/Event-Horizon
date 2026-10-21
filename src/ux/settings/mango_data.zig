const std = @import("std");

// Compositor config data: Mango — Zig port of
// src/ux/settings/data/mango/settings_mango_data.{hpp,cpp} (logic only).
// Same design: 7 sub-tabs share one MangoConfig; file is line-oriented.

pub const Config = struct {
    border_width: i32 = 2,
    gaps: i32 = 8,
    rounding: i32 = 8,
    blur: bool = false,
    shadows: bool = true,
    master_ratio: f64 = 0.55,
    focus_follows_mouse: bool = true,
};

pub fn clampMasterRatio(v: f64) f64 {
    if (v < 0.2) return 0.2;
    if (v > 0.8) return 0.8;
    return v;
}

pub fn applyLine(cfg: *Config, line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] == '#') return false;
    var it = std.mem.splitScalar(u8, trimmed, '=');
    const k = std.mem.trim(u8, it.next() orelse return false, " \t");
    const v = std.mem.trim(u8, it.next() orelse return false, " \t");
    if (std.mem.eql(u8, k, "border_width")) {
        cfg.border_width = std.fmt.parseInt(i32, v, 10) catch cfg.border_width;
        return true;
    }
    if (std.mem.eql(u8, k, "gaps")) {
        cfg.gaps = std.fmt.parseInt(i32, v, 10) catch cfg.gaps;
        return true;
    }
    if (std.mem.eql(u8, k, "rounding")) {
        cfg.rounding = std.fmt.parseInt(i32, v, 10) catch cfg.rounding;
        return true;
    }
    if (std.mem.eql(u8, k, "master_ratio")) {
        cfg.master_ratio = clampMasterRatio(std.fmt.parseFloat(f64, v) catch cfg.master_ratio);
        return true;
    }
    return false;
}

test "settings-mango-data: lines" {
    const t = std.testing;
    var c = Config{};
    try t.expect(applyLine(&c, "gaps=12"));
    try t.expectEqual(@as(i32, 12), c.gaps);
    try t.expect(!applyLine(&c, "# comment"));
    try t.expect(!applyLine(&c, "unknown=1"));
    c.master_ratio = clampMasterRatio(9);
    try t.expectEqual(@as(f64, 0.8), c.master_ratio);
}
