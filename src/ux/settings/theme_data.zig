const std = @import("std");

// Theme presets — Zig port of src/ux/settings/theme_data.hpp.
// 16-color palettes stored as normalized float triples; hex helpers for TOML.
// Same design: built-in presets grouped by source (catppuccin/google/gruvbox)
// plus the M3 dark default fallback.

pub const Palette = struct {
    primary: [3]f32 = .{ 0.769, 0.659, 0.941 },
    on_primary: [3]f32 = .{ 1, 1, 1 },
    secondary: [3]f32 = .{ 0.239, 0.125, 0.439 },
    on_secondary: [3]f32 = .{ 1, 1, 1 },
    tertiary: [3]f32 = .{ 0.910, 0.522, 0.290 },
    on_tertiary: [3]f32 = .{ 1, 1, 1 },
    err: [3]f32 = .{ 0.910, 0.416, 0.353 },
    on_error: [3]f32 = .{ 1, 1, 1 },
    surface: [3]f32 = .{ 0.102, 0.075, 0.188 },
    on_surface: [3]f32 = .{ 1, 1, 1 },
    surface_variant: [3]f32 = .{ 0.133, 0.102, 0.227 },
    on_surface_variant: [3]f32 = .{ 1, 1, 1 },
    outline: [3]f32 = .{ 0.478, 0.416, 0.588 },
    shadow: [3]f32 = .{ 0.031, 0.020, 0.063 },
    hover: [3]f32 = .{ 0.212, 0.165, 0.337 },
    on_hover: [3]f32 = .{ 1, 1, 1 },
};

pub const Preset = struct {
    name: []const u8,
    source: []const u8,
    variant: []const u8,
    palette: Palette,
};

pub const catppuccin_mocha = Palette{
    .primary = .{ 0.761, 0.600, 0.941 },
    .surface = .{ 0.117, 0.117, 0.180 },
    .on_surface = .{ 0.796, 0.817, 0.960 },
    .surface_variant = .{ 0.184, 0.184, 0.274 },
    .outline = .{ 0.454, 0.454, 0.631 },
    .hover = .{ 0.184, 0.184, 0.274 },
    .on_hover = .{ 0.796, 0.817, 0.960 },
};

pub const gruvbox_dark = Palette{
    .primary = .{ 0.984, 0.792, 0.364 },
    .secondary = .{ 0.666, 0.533, 0.333 },
    .surface = .{ 0.156, 0.156, 0.156 },
    .on_surface = .{ 0.921, 0.858, 0.752 },
    .surface_variant = .{ 0.235, 0.235, 0.235 },
    .outline = .{ 0.454, 0.419, 0.384 },
    .hover = .{ 0.235, 0.235, 0.235 },
    .on_hover = .{ 0.921, 0.858, 0.752 },
};

pub const presets = [_]Preset{
    .{ .name = "M3 Dark Default", .source = "google", .variant = "dark", .palette = .{} },
    .{ .name = "Catppuccin Latte", .source = "catppuccin", .variant = "latte", .palette = .{ .surface = .{ 0.937, 0.945, 0.961 }, .on_surface = .{ 0.298, 0.310, 0.412 } } },
    .{ .name = "Catppuccin Frappe", .source = "catppuccin", .variant = "frappe", .palette = .{ .surface = .{ 0.188, 0.192, 0.250 }, .on_surface = .{ 0.796, 0.817, 0.960 } } },
    .{ .name = "Catppuccin Macchiato", .source = "catppuccin", .variant = "macchiato", .palette = .{ .surface = .{ 0.141, 0.141, 0.197 }, .on_surface = .{ 0.796, 0.817, 0.960 } } },
    .{ .name = "Catppuccin Mocha", .source = "catppuccin", .variant = "mocha", .palette = catppuccin_mocha },
    .{ .name = "Google Material Light", .source = "google", .variant = "light", .palette = .{ .primary = .{ 0.404, 0.278, 0.800 }, .surface = .{ 0.988, 0.988, 0.988 }, .on_surface = .{ 0.102, 0.102, 0.102 } } },
    .{ .name = "Google Material Dark", .source = "google", .variant = "dark", .palette = .{} },
    .{ .name = "Gruvbox Dark", .source = "gruvbox", .variant = "dark", .palette = gruvbox_dark },
    .{ .name = "Gruvbox Light", .source = "gruvbox", .variant = "light", .palette = .{ .primary = .{ 0.717, 0.521, 0.141 }, .surface = .{ 0.984, 0.949, 0.886 }, .on_surface = .{ 0.235, 0.219, 0.203 } } },
    .{ .name = "Rose Pine", .source = "rose-pine", .variant = "dark", .palette = .{ .primary = .{ 0.784, 0.639, 0.906 }, .surface = .{ 0.094, 0.094, 0.141 }, .on_surface = .{ 0.902, 0.882, 0.929 } } },
    .{ .name = "Rose Pine Moon", .source = "rose-pine", .variant = "moon", .palette = .{ .primary = .{ 0.784, 0.639, 0.906 }, .surface = .{ 0.137, 0.137, 0.196 }, .on_surface = .{ 0.902, 0.882, 0.929 } } },
    .{ .name = "Rose Pine Dawn", .source = "rose-pine", .variant = "dawn", .palette = .{ .primary = .{ 0.435, 0.345, 0.608 }, .surface = .{ 0.980, 0.968, 0.945 }, .on_surface = .{ 0.341, 0.305, 0.388 } } },
    .{ .name = "Google Brand Dark", .source = "google", .variant = "brand-dark", .palette = .{ .primary = .{ 0.659, 0.800, 1.0 }, .surface = .{ 0.066, 0.094, 0.156 } } },
    .{ .name = "Google Brand Light", .source = "google", .variant = "brand-light", .palette = .{ .primary = .{ 0.043, 0.298, 0.800 }, .surface = .{ 0.972, 0.976, 1.0 } } },
};

pub fn findPreset(name: []const u8) ?Preset {
    for (presets) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

pub fn rgbToHex(rgb: [3]f32, buf: []u8) ![]u8 {
    const r: u8 = @intFromFloat(@round(@min(1, @max(0, rgb[0])) * 255));
    const g: u8 = @intFromFloat(@round(@min(1, @max(0, rgb[1])) * 255));
    const b: u8 = @intFromFloat(@round(@min(1, @max(0, rgb[2])) * 255));
    return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b });
}

test "settings-theme-data: presets + hex" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 14), presets.len);
    try t.expect(findPreset("Catppuccin Mocha") != null);
    try t.expect(findPreset("Rose Pine") != null);
    try t.expect(findPreset("nope") == null);
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("#FFFFFF", try rgbToHex(.{ 1, 1, 1 }, &buf));
}
