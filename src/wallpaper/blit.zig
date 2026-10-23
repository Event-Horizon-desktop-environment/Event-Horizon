const std = @import("std");
const repetition = @import("../compat/repetition.zig");

pub const Fit = enum { stretch, fit, fill };

pub fn blitCover(dst: []u32, dw: i32, dh: i32, src: []const u8, sw: i32, sh: i32, mode: Fit) void {
    if (dw <= 0 or dh <= 0 or sw <= 0 or sh <= 0) return;
    if (src.len < @as(usize, @intCast(sw * sh * 4))) return;
    if (dst.len < @as(usize, @intCast(dw * dh))) return;
    const dwf: f64 = @floatFromInt(dw);
    const dhf: f64 = @floatFromInt(dh);
    const swf: f64 = @floatFromInt(sw);
    const shf: f64 = @floatFromInt(sh);
    var sc: f64 = 1.0;
    var dx: f64 = 0.0;
    var dy: f64 = 0.0;
    switch (mode) {
        .stretch => {},
        .fit => {
            sc = @min(dwf / swf, dhf / shf);
            dx = (dwf - swf * sc) / 2.0;
            dy = (dhf - shf * sc) / 2.0;
        },
        .fill => {
            sc = @max(dwf / swf, dhf / shf);
            dx = (dwf - swf * sc) / 2.0;
            dy = (dhf - shf * sc) / 2.0;
        },
    }
    const sx_scale = 1.0 / sc;
    const sy_scale = 1.0 / sc;
    const ox = -dx * sx_scale;
    const oy = -dy * sy_scale;
    var y: i32 = 0;
    while (y < dh) : (y += 1) {
        var sy_i: i32 = @intFromFloat(oy + @as(f64, @floatFromInt(y)) * sy_scale);
        sy_i = @max(0, @min(sh - 1, sy_i));
        var x: i32 = 0;
        while (x < dw) : (x += 1) {
            var sx_i: i32 = @intFromFloat(ox + @as(f64, @floatFromInt(x)) * sx_scale);
            sx_i = @max(0, @min(sw - 1, sx_i));
            const si: usize = @intCast((sy_i * sw + sx_i) * 4);
            const r: u32 = src[si];
            const g: u32 = src[si + 1];
            const b: u32 = src[si + 2];
            const a: u32 = src[si + 3];
            const di: usize = @intCast(y * dw + x);
            if (mode == .stretch) {
                const fx: i32 = @intCast(@divTrunc(@as(i64, x) * @as(i64, sw), @as(i64, dw)));
                const fy: i32 = @intCast(@divTrunc(@as(i64, y) * @as(i64, sh), @as(i64, dh)));
                const s2: usize = @intCast((fy * sw + fx) * 4);
                const r2: u32 = src[s2];
                const g2: u32 = src[s2 + 1];
                const b2: u32 = src[s2 + 2];
                const a2: u32 = src[s2 + 3];
                dst[di] = premult(r2, g2, b2, a2);
            } else {
                dst[di] = premult(r, g, b, a);
            }
        }
    }
}

fn premult(r: u32, g: u32, b: u32, a: u32) u32 {
    if (a >= 255) return (@as(u32, 0xFF) << 24) | (r << 16) | (g << 8) | b;
    if (a == 0) return 0;
    const rr = (r * a + 127) / 255;
    const gg = (g * a + 127) / 255;
    const bb = (b * a + 127) / 255;
    return (a << 24) | (rr << 16) | (gg << 8) | bb;
}

test "blit: cover samples the full source width, not a squeezed slice" {
    const t = std.testing;
    // 6x4 source, R = column: cover onto 4x3 keeps every column reachable.
    // The old `sw / (dw * sc)` scale squeezed the source into the left of dst
    // and smeared the last texel across the rest (the UHD streaks).
    var src: [6 * 4 * 4]u8 = undefined;
    for (0..4) |y| {
        for (0..6) |x| {
            const o = (y * 6 + x) * 4;
            src[o] = @intCast(x * 40);
            src[o + 1] = @intCast(y * 40);
            src[o + 2] = 0;
            src[o + 3] = 255;
        }
    }
    var dst: [4 * 3]u32 = @as([(4 * 3)]u32, @splat(0));
    blitCover(&dst, 4, 3, &src, 6, 4, .fill);
    // Left edge samples column 0, right edge column 4 (not a clamped 5).
    try t.expectEqual(@as(u32, 0xFF000000), dst[0]);
    try t.expectEqual(@as(u32, 0xFFA02800), dst[1 * 4 + 3]);
    // No smear: the top row spans more than one source column.
    try t.expect(dst[0] != dst[3]);
}

test "blit: solid fill + stretch + premult" {
    const t = std.testing;
    var dst: [16]u32 = @as([16]u32, @splat(0));
    const src = repetition.repeatBytes(64, &.{ 255, 0, 0, 255 });
    blitCover(&dst, 4, 4, &src, 2, 2, .fill);
    for (dst) |px| try t.expectEqual(@as(u32, 0xFFFF0000), px);
    var dst2: [4]u32 = @as([4]u32, @splat(0));
    const src2 = [_]u8{ 100, 150, 200, 128, 0, 0, 0, 0 };
    blitCover(&dst2, 2, 1, &src2, 2, 1, .stretch);
    try t.expectEqual(premult(100, 150, 200, 128), dst2[0]);
}
