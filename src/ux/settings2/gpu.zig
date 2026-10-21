const std = @import("std");

// GPU / renderer helpers.
// Same design: renderer string parse (vulkan/vk/gl->vulkan, cairo fallback),
// damage-region helper for the settings surface.

pub const Renderer = enum { vulkan, cairo };

pub fn parseRenderer(s: []const u8) Renderer {
    var lower: [16]u8 = undefined;
    const n: usize = @min(s.len, lower.len);
    const l = std.ascii.lowerString(lower[0..n], s[0..n]);
    if (std.mem.eql(u8, l, "vulkan") or std.mem.eql(u8, l, "vk") or std.mem.eql(u8, l, "gl")) return .vulkan;
    if (std.mem.eql(u8, l, "cairo")) return .cairo;
    return .cairo;
}

pub fn rendererName(r: Renderer) []const u8 {
    return switch (r) {
        .vulkan => "vulkan",
        .cairo => "cairo",
    };
}

pub const DamageRect = struct { x: i32, y: i32, w: i32, h: i32 };

pub fn unionDamage(a: DamageRect, b: DamageRect) DamageRect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + a.w, b.x + b.w);
    const y1 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

test "settings-gpu: renderer parse" {
    const t = std.testing;
    try t.expectEqual(Renderer.vulkan, parseRenderer("Vulkan"));
    try t.expectEqual(Renderer.vulkan, parseRenderer("vk"));
    try t.expectEqual(Renderer.cairo, parseRenderer("bogus"));
    const u = unionDamage(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .x = 5, .y = 5, .w = 10, .h = 10 });
    try t.expectEqual(@as(i32, 15), u.w);
}
