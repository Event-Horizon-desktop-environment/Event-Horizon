//! Opaque base layer for the overview: blurred wallpaper, then dim.
//!
//! The compositor blurs a dedicated wallpaper surface under a dim backdrop;
//! on a single surface those two reduce to one opaque paint — wallpaper
//! cover-fit with SOURCE so frames never stack, then black at 55% OVER. The
//! image decodes once per path change, downscales to a thumbnail, and takes
//! a three-pass box blur there; cairo's upscale each frame is the blur's
//! final pass. With no wallpaper configured the base is the flat background
//! color instead.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const decode = @import("../../wallpaper/decode.zig");
const blit = @import("../../wallpaper/blit.zig");

/// Frosted-glass base: small enough that a box blur reads as the
/// compositor's blur once cairo scales it back up.
const blur_w: i32 = 480;
const blur_passes: usize = 3;
const blur_radius: i32 = 6;

/// One separable box pass over premultiplied pixels. Wallpaper is opaque,
/// so channels blur independently and alpha stays put.
fn blurPass(dst: []u32, src: []const u32, w: i32, h: i32, horizontal: bool) void {
    const r = blur_radius;
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            var a: u32 = 0;
            var rr: u32 = 0;
            var gg: u32 = 0;
            var bb: u32 = 0;
            var k: i32 = -r;
            while (k <= r) : (k += 1) {
                const sx = @max(0, @min(w - 1, x + (if (horizontal) k else 0)));
                const sy = @max(0, @min(h - 1, y + (if (horizontal) 0 else k)));
                const p = src[@intCast(sy * w + sx)];
                a += (p >> 24) & 0xFF;
                rr += (p >> 16) & 0xFF;
                gg += (p >> 8) & 0xFF;
                bb += p & 0xFF;
            }
            const n: u32 = @intCast(r * 2 + 1);
            dst[@intCast(y * w + x)] = ((a / n) << 24) | ((rr / n) << 16) | ((gg / n) << 8) | (bb / n);
        }
    }
}

fn frost(gpa: std.mem.Allocator, dst: []u32, w: i32, h: i32) void {
    const n: usize = @intCast(w * h);
    const tmp = gpa.alloc(u32, n) catch return;
    defer gpa.free(tmp);
    var i: usize = 0;
    while (i < blur_passes) : (i += 1) {
        blurPass(tmp, dst, w, h, true);
        blurPass(dst, tmp, w, h, false);
    }
}

pub const Backdrop = struct {
    gpa: std.mem.Allocator,
    path: []const u8 = "",
    surf: ?*cairo.cairo_surface_t = null,
    w: i32 = 0,
    h: i32 = 0,
    /// Output-sized opaque base, repainted only when the wallpaper or the
    /// size changes. Frames blit it with SOURCE instead of re-running the
    /// upscale every time.
    full: ?*cairo.cairo_surface_t = null,
    full_w: i32 = 0,
    full_h: i32 = 0,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Self) void {
        self.clear();
    }

    fn clear(self: *Self) void {
        if (self.surf) |s| cairo.cairo_surface_destroy(s);
        self.surf = null;
        self.w = 0;
        self.h = 0;
        self.dropFull();
        if (self.path.len > 0) self.gpa.free(self.path);
        self.path = "";
    }

    fn dropFull(self: *Self) void {
        if (self.full) |f| cairo.cairo_surface_destroy(f);
        self.full = null;
        self.full_w = 0;
        self.full_h = 0;
    }

    /// Decode `path` when it is not the one already held. Empty clears back
    /// to the flat fallback. Never fails the frame: a decode that fails
    /// just leaves whatever was there (or nothing).
    pub fn ensure(self: *Self, path: []const u8) void {
        if (std.mem.eql(u8, path, self.path)) return;
        self.clear();
        if (path.len == 0) return;
        var img = decode.loadRgba(self.gpa, path) orelse return;
        defer img.free(self.gpa);
        if (img.w <= 0 or img.h <= 0) return;
        // Small first: the downscale is the blur's outer pass, and the
        // surface stays thumbnail-sized while cairo upscales per frame.
        const sc: f64 = @as(f64, @floatFromInt(blur_w)) / @as(f64, @floatFromInt(img.w));
        const cw: i32 = blur_w;
        const ch: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(img.h)) * sc))));
        const n: usize = @intCast(cw * ch);
        const dst = self.gpa.alloc(u32, n) catch return;
        defer self.gpa.free(dst);
        @memset(dst, 0);
        blit.blitCover(dst, cw, ch, img.pixels, img.w, img.h, .stretch);
        frost(self.gpa, dst, cw, ch);
        const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, cw, ch);
        if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(surf);
            return;
        }
        const bytes: usize = n * 4;
        @memcpy(cairo.cairo_image_surface_get_data(surf)[0..bytes], std.mem.sliceAsBytes(dst));
        cairo.cairo_surface_mark_dirty(surf);
        self.path = self.gpa.dupe(u8, path) catch "";
        self.surf = surf;
        self.w = cw;
        self.h = ch;
    }

    /// Opaque base + dim. SOURCE, never OVER: the buffer is shared between
    /// frames, so anything less would compound. The wallpaper upscale runs
    /// once per size into `full`; frames only blit it.
    pub fn paint(self: *Self, cr: ?*cairo.cairo_t, w: f64, h: f64, bg: [3]f64, alpha: f64) void {
        const c = cr orelse return;
        if (w <= 0.0 or h <= 0.0) return;
        // Appearance → Opacity "Overview": the whole backdrop — capture and
        // dim — is painted through this, so 0% shows the live desktop and
        // 100% is the designed opaque cover.
        if (alpha <= 0.0) return;
        const iw: i32 = @intFromFloat(@ceil(w));
        const ih: i32 = @intFromFloat(@ceil(h));
        if (self.surf != null and (self.full == null or self.full_w != iw or self.full_h != ih)) {
            self.renderFull(iw, ih, bg);
        }
        cairo.cairo_save(c);
        cairo.cairo_set_operator(c, cairo.CAIRO_OPERATOR_SOURCE);
        if (self.full) |f| {
            cairo.cairo_set_source_surface(c, f, 0, 0);
            cairo.cairo_paint_with_alpha(c, alpha);
        } else {
            cairo.cairo_set_source_rgba(c, bg[0], bg[1], bg[2], alpha);
            cairo.cairo_paint(c);
        }
        cairo.cairo_restore(c);
        cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.55 * alpha);
        cairo.cairo_rectangle(c, 0, 0, w, h);
        cairo.cairo_fill(c);
    }

    /// Render the output-sized base once: wallpaper cover-fit, or flat
    /// when there is none to draw.
    fn renderFull(self: *Self, w: i32, h: i32, bg: [3]f64) void {
        self.dropFull();
        if (w <= 0 or h <= 0) return;
        const f = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, w, h);
        if (cairo.cairo_surface_status(f) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(f);
            return;
        }
        errdefer cairo.cairo_surface_destroy(f);
        const c = cairo.cairo_create(f);
        if (cairo.cairo_status(c) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_destroy(c);
            return;
        }
        defer cairo.cairo_destroy(c);
        cairo.cairo_set_operator(c, cairo.CAIRO_OPERATOR_SOURCE);
        if (self.surf) |s| {
            const iw: f64 = @floatFromInt(self.w);
            const ih: f64 = @floatFromInt(self.h);
            if (iw > 0.0 and ih > 0.0) {
                const sc = @max(@as(f64, @floatFromInt(w)) / iw, @as(f64, @floatFromInt(h)) / ih);
                cairo.cairo_translate(c, (@as(f64, @floatFromInt(w)) - iw * sc) * 0.5, (@as(f64, @floatFromInt(h)) - ih * sc) * 0.5);
                cairo.cairo_scale(c, sc, sc);
                cairo.cairo_set_source_surface(c, s, 0, 0);
                cairo.cairo_pattern_set_filter(cairo.cairo_get_source(c), cairo.CAIRO_FILTER_GOOD);
                cairo.cairo_paint(c);
                self.full = f;
                self.full_w = w;
                self.full_h = h;
                return;
            }
        }
        cairo.cairo_set_source_rgb(c, bg[0], bg[1], bg[2]);
        cairo.cairo_paint(c);
        self.full = f;
        self.full_w = w;
        self.full_h = h;
    }
};

test "overview-backdrop: missing file clears to flat" {
    const t = std.testing;
    var b = Backdrop.init(t.allocator);
    defer b.deinit();
    b.ensure("/nonexistent-xyz.png");
    try t.expect(b.surf == null);
    try t.expectEqualStrings("", b.path);
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 64, 64);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    b.paint(cr, 64, 64, .{ 0.1, 0.1, 0.12 }, 1.0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}

test "overview-backdrop: blur keeps a solid field, spreads an edge" {
    const t = std.testing;
    // Wide enough that three passes (18px of spread) leave the far corner
    // untouched while the middle turns gray.
    const w: i32 = 64;
    const h: i32 = 16;
    const n: usize = @intCast(w * h);
    const buf = try t.allocator.alloc(u32, n);
    defer t.allocator.free(buf);
    @memset(buf, 0xFF808080);
    frost(t.allocator, buf, w, h);
    for (buf) |p| try t.expectEqual(@as(u32, 0xFF808080), p);
    @memset(buf, 0xFF000000);
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w / 2) : (x += 1) buf[@intCast(y * w + x)] = 0xFFFFFFFF;
    }
    frost(t.allocator, buf, w, h);
    // The middle column sat on a hard edge; after three passes it is gray,
    // and the corners it never touched are still pure.
    const mid = buf[@intCast(h / 2 * w + w / 2)];
    const r = (mid >> 16) & 0xFF;
    try t.expect(r > 0x40 and r < 0xC0);
    // Deep in the white half, past all three passes' reach: still pure.
    try t.expectEqual(@as(u32, 0xFFFFFFFF), buf[0]);
    // Deep in the black half: still pure.
    try t.expectEqual(@as(u32, 0xFF000000), buf[@intCast(n - 1)]);
}
