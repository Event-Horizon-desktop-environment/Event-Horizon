const std = @import("std");
const repetition = @import("../../compat/repetition.zig");

pub fn blitScaled(dst: []u32, dw: i32, dh: i32, dx: i32, dy: i32, slot: i32, src: []const u8, sw: i32, sh: i32) void {
    if (sw <= 0 or sh <= 0 or slot <= 0 or dw <= 0 or dh <= 0) return;
    if (src.len < @as(usize, @intCast(sw * sh * 4))) return;
    if (dst.len < @as(usize, @intCast(dw * dh))) return;
    var y: i32 = 0;
    while (y < slot) : (y += 1) {
        const sy: i32 = @intCast(@divTrunc(@as(i64, y) * @as(i64, sh), @as(i64, slot)));
        const gy = dy + y;
        if (gy < 0 or gy >= dh) continue;
        var x: i32 = 0;
        while (x < slot) : (x += 1) {
            const sx: i32 = @intCast(@divTrunc(@as(i64, x) * @as(i64, sw), @as(i64, slot)));
            const gx = dx + x;
            if (gx < 0 or gx >= dw) continue;
            const si: usize = @intCast((sy * sw + sx) * 4);
            const r: u32 = src[si];
            const g: u32 = src[si + 1];
            const b: u32 = src[si + 2];
            const a: u32 = src[si + 3];
            const di: usize = @intCast(gy * dw + gx);
            if (a >= 255) {
                dst[di] = (@as(u32, 0xFF) << 24) | (r << 16) | (g << 8) | b;
            } else if (a == 0) {
                dst[di] = 0;
            } else {
                dst[di] = (a << 24) | (((r * a + 127) / 255) << 16) | (((g * a + 127) / 255) << 8) | ((b * a + 127) / 255);
            }
        }
    }
}

test "icon-blit: scale down solid + transparent" {
    const t = std.testing;
    var dst: [16]u32 = @as([16]u32, @splat(0xFF000000));
    const red = repetition.repeatBytes(64, &.{ 255, 0, 0, 255 });
    blitScaled(&dst, 4, 4, 0, 0, 4, &red, 2, 2);
    for (dst) |px| try t.expectEqual(@as(u32, 0xFFFF0000), px);
    const clear = repetition.repeatBytes(16, &.{ 9, 9, 9, 0 });
    blitScaled(&dst, 4, 4, 0, 0, 2, &clear, 2, 2);
    try t.expectEqual(@as(u32, 0), dst[0]);
}
