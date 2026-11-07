//! Theme presets for the Color Themes page.
//!
//! The 268-palette roster is generated from the C++ reference
//! `theme_data.hpp` and lives in `theme_presets.zig`; this module re-exports
//! it and adds the small formatting helpers the page and TOML writer need.
//! Keeping the generated table separate means the page never pays for the
//! parser, and regenerating the roster cannot disturb unrelated code.

const std = @import("std");
const generated = @import("theme_presets.zig");

pub const Palette = generated.Palette;
pub const Preset = generated.Preset;
pub const presets = generated.presets;
pub const find = generated.find;
pub const findIn = generated.findIn;

/// Backwards-compatible alias used by `theme_manager.zig`.
pub fn findPreset(name: []const u8) ?Preset {
    return find(name);
}

/// Format a normalized triple as `#RRGGBB` for the TOML writer.
pub fn rgbToHex(rgb: [3]f32, buf: []u8) ![]u8 {
    const r: u8 = @intFromFloat(@round(@min(1, @max(0, rgb[0])) * 255));
    const g: u8 = @intFromFloat(@round(@min(1, @max(0, rgb[1])) * 255));
    const b: u8 = @intFromFloat(@round(@min(1, @max(0, rgb[2])) * 255));
    return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b });
}

/// Parse `#RRGGBB` (or `RRGGBB`) into a normalized triple.
pub fn hexToRgb(text: []const u8) ?[3]f32 {
    var s = std.mem.trim(u8, text, " \t\r\n");
    if (s.len > 0 and s[0] == '#') s = s[1..];
    if (s.len != 6) return null;
    const v = std.fmt.parseInt(u24, s, 16) catch return null;
    return .{
        @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt(v & 0xff)) / 255.0,
    };
}

test "settings-theme-data: presets + hex" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 268), presets.len);
    try t.expect(findPreset("Catppuccin Mocha") != null);
    try t.expect(findPreset("Rosé Pine") != null);
    try t.expect(findPreset("nope") == null);
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("#FFFFFF", try rgbToHex(.{ 1, 1, 1 }, &buf));
    try t.expect(hexToRgb("#FFFFFF") != null);
    try t.expectApproxEqAbs(@as(f32, 1.0), hexToRgb("#FFFFFF").?[0], 1e-6);
    try t.expect(hexToRgb("bad") == null);
}
