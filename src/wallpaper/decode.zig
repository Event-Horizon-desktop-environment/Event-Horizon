const std = @import("std");

extern fn stbi_load(filename: [*c]const u8, x: *c_int, y: *c_int, channels: *c_int, req_channels: c_int) ?[*]u8;
extern fn stbi_info(filename: [*c]const u8, x: *c_int, y: *c_int, channels: *c_int) c_int;
extern fn stbi_image_free(data: ?*anyopaque) void;
extern fn stbi_failure_reason() [*c]const u8;

pub const Image = struct {
    w: i32,
    h: i32,
    pixels: []u8,

    pub fn free(self: *Image, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
    }
};

/// Decode a wallpaper within the pixel budget, returning allocator-owned RGBA.
pub fn loadRgba(alloc: std.mem.Allocator, path: []const u8) ?Image {
    var zbuf: [1024:0]u8 = @as([1024:0]u8, @splat(0));
    if (path.len >= zbuf.len) return null;
    @memcpy(zbuf[0..path.len], path);
    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    if (stbi_info(&zbuf, &w, &h, &ch) == 0) return null;
    if (w <= 0 or h <= 0 or @as(i64, w) * @as(i64, h) > 16 * 1024 * 1024) return null;
    const data = stbi_load(&zbuf, &w, &h, &ch, 4) orelse return null;
    defer stbi_image_free(data);
    if (w <= 0 or h <= 0 or @as(i64, w) * @as(i64, h) > 16 * 1024 * 1024) return null;
    const nbytes: usize = @intCast(w * h * 4);
    const out = alloc.dupe(u8, data[0..nbytes]) catch return null;
    return .{ .w = w, .h = h, .pixels = out };
}

test "decode: missing file returns null" {
    const t = std.testing;
    try t.expect(loadRgba(t.allocator, "/nonexistent-xyz.png") == null);
}
