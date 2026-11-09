//! Painting for the session lock screen.
//!
//! The design is the macOS Tahoe "Liquid Glass" lock screen: the desktop
//! wallpaper under a light tint and two soft fades, a small semibold date and
//! a large tracking-tight clock (both cut from frosted glass, with the clock
//! carrying a small AM/PM suffix), and a centred login cluster built from a
//! glass avatar, the account name, a frosted password pill with a right-hand
//! submit button, and one status line.
//!
//! Deliberately plain cairo: no widget tree and no animation beyond the
//! caret, because a lock screen that depends on the rest of the shell being
//! healthy would be the wrong kind of lock. The wallpaper is always the one
//! the desktop is configured to show; there is no built-in fallback artwork.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const text = @import("../../text/layout.zig");
const local_time = @import("../desktop/local_time.zig");
const decode = @import("../../wallpaper/decode.zig");

pub const View = struct {
    clock: []const u8 = "",
    date: []const u8 = "",
    user: []const u8 = "",
    message: []const u8 = "",
    password_len: usize = 0,
    failed: bool = false,
    auth_pending: bool = false,
    /// True when the buffer already contains the wallpaper blit.
    have_backdrop: bool = false,
    /// The account photo, already decoded to an image surface. Null falls back
    /// to the frosted circle with the account initial.
    avatar: ?*cairo.cairo_surface_t = null,
};

/// Decodes an account image (PNG/JPEG/WebP) into a premultiplied ARGB32 cairo
/// surface. Same pipeline as the wallpaper decoder, so the shell's image
/// limits apply. The caller owns the surface.
pub fn loadAvatar(alloc: std.mem.Allocator, path: []const u8) ?*cairo.cairo_surface_t {
    var img = decode.loadRgba(alloc, path) orelse return null;
    defer img.free(alloc);
    if (img.w <= 0 or img.h <= 0) return null;
    const w: usize = @intCast(img.w);
    const h: usize = @intCast(img.h);
    if (img.pixels.len < w * h * 4) return null;

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, img.w, img.h);
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    const data = cairo.cairo_image_surface_get_data(surf);
    const stride = cairo.cairo_image_surface_get_stride(surf);
    if (data == null or stride <= 0) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    const dst: [*]u8 = @ptrCast(data);
    const stride_us: usize = @intCast(stride);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const si = (y * w + x) * 4;
            const a: u32 = img.pixels[si + 3];
            const r: u32 = img.pixels[si];
            const g: u32 = img.pixels[si + 1];
            const b: u32 = img.pixels[si + 2];
            const off = y * stride_us + x * 4;
            // Little-endian ARGB32 is B,G,R,A in memory.
            dst[off] = @intCast((b * a + 127) / 255);
            dst[off + 1] = @intCast((g * a + 127) / 255);
            dst[off + 2] = @intCast((r * a + 127) / 255);
            dst[off + 3] = @intCast(a);
        }
    }
    cairo.cairo_surface_mark_dirty(surf);
    return surf;
}

const Rgba = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
};

const ink: Rgba = .{ .r = 0.95, .g = 0.96, .b = 1.0, .a = 0.96 };
const glass_edge: Rgba = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 0.30 };
const accent: Rgba = .{ .r = 140.0 / 255.0, .g = 175.0 / 255.0, .b = 1.0, .a = 0.90 };
const accent_ring: Rgba = .{ .r = 140.0 / 255.0, .g = 175.0 / 255.0, .b = 1.0, .a = 0.18 };
const danger: Rgba = .{ .r = 1.0, .g = 105.0 / 255.0, .b = 105.0 / 255.0, .a = 0.90 };
const danger_ring: Rgba = .{ .r = 1.0, .g = 105.0 / 255.0, .b = 105.0 / 255.0, .a = 0.16 };

fn setRgba(cr: *cairo.cairo_t, col: Rgba) void {
    cairo.cairo_set_source_rgba(cr, col.r, col.g, col.b, col.a);
}

fn circlePath(cr: *cairo.cairo_t, cx: f64, cy: f64, r: f64) void {
    cairo.cairo_new_sub_path(cr);
    cairo.cairo_arc(cr, cx, cy, r, 0, 2.0 * std.math.pi);
    cairo.cairo_close_path(cr);
}

fn roundedRect(cr: *cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const r = @min(radius, @min(w, h) / 2.0);
    cairo.cairo_new_sub_path(cr);
    cairo.cairo_arc(cr, x + w - r, y + r, r, -std.math.pi / 2.0, 0);
    cairo.cairo_arc(cr, x + w - r, y + h - r, r, 0, std.math.pi / 2.0);
    cairo.cairo_arc(cr, x + r, y + h - r, r, std.math.pi / 2.0, std.math.pi);
    cairo.cairo_arc(cr, x + r, y + r, r, std.math.pi, 1.5 * std.math.pi);
    cairo.cairo_close_path(cr);
}

fn fillRounded(cr: *cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, radius: f64, col: Rgba) void {
    roundedRect(cr, x, y, w, h, radius);
    setRgba(cr, col);
    cairo.cairo_fill(cr);
}

fn strokeRounded(cr: *cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, radius: f64, col: Rgba, width: f64) void {
    roundedRect(cr, x, y, w, h, radius);
    setRgba(cr, col);
    cairo.cairo_set_line_width(cr, width);
    cairo.cairo_stroke(cr);
}

/// A vertical fade over the whole output. The clock reads against the
/// wallpaper without a flat scrim turning the picture into a grey rectangle.
fn verticalFade(cr: *cairo.cairo_t, y0: f64, y1: f64, a0: f64, a1: f64) void {
    const pat = cairo.cairo_pattern_create_linear(0, y0, 0, y1);
    if (pat == null) return;
    cairo.cairo_pattern_add_color_stop_rgba(pat, 0, 0, 0, 0, a0);
    cairo.cairo_pattern_add_color_stop_rgba(pat, 1, 0, 0, 0, a1);
    cairo.cairo_set_source(cr, pat);
    cairo.cairo_paint(cr);
    cairo.cairo_pattern_destroy(pat);
}

const frost_max = 64;

/// Box blur over a low-resolution copy of the backdrop. The design's
/// `backdrop-filter: blur(28px)` is what makes the glass read as glass; this
/// samples the region at a quarter resolution, blurs the cells, and scales it
/// back with bilinear filtering. It runs on the already-painted wallpaper
/// surface, so it works for every output without passing the image in.
fn frostBackdrop(cr: *cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, radius: f64, blur_radius: usize) bool {
    const target = cairo.cairo_get_target(cr);
    if (target == null) return false;
    if (cairo.cairo_surface_get_type(target) != cairo.CAIRO_SURFACE_TYPE_IMAGE) return false;
    if (x < 0 or y < 0) return false;

    const tw = cairo.cairo_image_surface_get_width(target);
    const th = cairo.cairo_image_surface_get_height(target);
    const rw: i32 = @intFromFloat(@ceil(w));
    const rh: i32 = @intFromFloat(@ceil(h));
    const x0: i32 = @intFromFloat(@floor(x));
    const y0: i32 = @intFromFloat(@floor(y));
    if (rw <= 0 or rh <= 0 or x0 + rw > tw or y0 + rh > th) return false;

    cairo.cairo_surface_flush(target);
    const data = cairo.cairo_image_surface_get_data(target) orelse return false;
    const stride = cairo.cairo_image_surface_get_stride(target);

    const gw: usize = @intCast(@max(4, @min(frost_max, @divTrunc(rw, 4))));
    const gh: usize = @intCast(@max(4, @min(frost_max, @divTrunc(rh, 4))));

    var grid: [frost_max * frost_max]u32 = undefined;
    var tmp: [frost_max * frost_max]u32 = undefined;

    const rwf: f64 = @floatFromInt(rw);
    const rhf: f64 = @floatFromInt(rh);
    var gy: usize = 0;
    while (gy < gh) : (gy += 1) {
        var gx: usize = 0;
        while (gx < gw) : (gx += 1) {
            const fx = @as(f64, @floatFromInt(x0)) + (@as(f64, @floatFromInt(gx)) + 0.5) * rwf / @as(f64, @floatFromInt(gw));
            const fy = @as(f64, @floatFromInt(y0)) + (@as(f64, @floatFromInt(gy)) + 0.5) * rhf / @as(f64, @floatFromInt(gh));
            const sx: i32 = @min(tw - 1, @max(0, @as(i32, @intFromFloat(fx))));
            const sy: i32 = @min(th - 1, @max(0, @as(i32, @intFromFloat(fy))));
            const off: usize = @intCast(sy * stride + sx * 4);
            const px: *align(1) const u32 = @ptrCast(data + off);
            grid[gy * gw + gx] = px.*;
        }
    }

    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        blurHorizontal(grid[0 .. gw * gh], tmp[0 .. gw * gh], gw, gh, blur_radius);
        blurVertical(tmp[0 .. gw * gh], grid[0 .. gw * gh], gw, gh, blur_radius);
    }

    const small = cairo.cairo_image_surface_create_for_data(
        @ptrCast(&grid),
        cairo.CAIRO_FORMAT_ARGB32,
        @intCast(gw),
        @intCast(gh),
        @intCast(gw * 4),
    );
    if (small == null) return false;
    defer cairo.cairo_surface_destroy(small);

    cairo.cairo_save(cr);
    roundedRect(cr, x, y, w, h, radius);
    cairo.cairo_clip(cr);
    // The blurred surface is `gw x gh` pixels; scale it up so those cells
    // cover the whole clipped region, not just the top-left corner.
    const gwf: f64 = @floatFromInt(gw);
    const ghf: f64 = @floatFromInt(gh);
    cairo.cairo_translate(cr, x, y);
    cairo.cairo_scale(cr, w / gwf, h / ghf);
    cairo.cairo_set_source_surface(cr, small, 0, 0);
    if (cairo.cairo_get_source(cr)) |pat| cairo.cairo_pattern_set_filter(pat, cairo.CAIRO_FILTER_BILINEAR);
    cairo.cairo_paint(cr);
    cairo.cairo_restore(cr);
    return true;
}

fn blurHorizontal(src: []const u32, dst: []u32, gw: usize, gh: usize, radius: usize) void {
    const r: i32 = @intCast(radius);
    var y: usize = 0;
    while (y < gh) : (y += 1) {
        var x: usize = 0;
        while (x < gw) : (x += 1) {
            var a: u64 = 0;
            var rr: u64 = 0;
            var gg: u64 = 0;
            var bb: u64 = 0;
            var n: u64 = 0;
            var dx: i32 = -r;
            while (dx <= r) : (dx += 1) {
                const sx: i32 = @as(i32, @intCast(x)) + dx;
                if (sx < 0 or sx >= @as(i32, @intCast(gw))) continue;
                const p = src[y * gw + @as(usize, @intCast(sx))];
                a += (p >> 24) & 0xFF;
                rr += (p >> 16) & 0xFF;
                gg += (p >> 8) & 0xFF;
                bb += p & 0xFF;
                n += 1;
            }
            if (n == 0) n = 1;
            dst[y * gw + x] = (@as(u32, @intCast(a / n)) << 24) |
                (@as(u32, @intCast(rr / n)) << 16) |
                (@as(u32, @intCast(gg / n)) << 8) |
                @as(u32, @intCast(bb / n));
        }
    }
}

fn blurVertical(src: []const u32, dst: []u32, gw: usize, gh: usize, radius: usize) void {
    const r: i32 = @intCast(radius);
    var y: usize = 0;
    while (y < gh) : (y += 1) {
        var x: usize = 0;
        while (x < gw) : (x += 1) {
            var a: u64 = 0;
            var rr: u64 = 0;
            var gg: u64 = 0;
            var bb: u64 = 0;
            var n: u64 = 0;
            var dy: i32 = -r;
            while (dy <= r) : (dy += 1) {
                const sy: i32 = @as(i32, @intCast(y)) + dy;
                if (sy < 0 or sy >= @as(i32, @intCast(gh))) continue;
                const p = src[@as(usize, @intCast(sy)) * gw + x];
                a += (p >> 24) & 0xFF;
                rr += (p >> 16) & 0xFF;
                gg += (p >> 8) & 0xFF;
                bb += p & 0xFF;
                n += 1;
            }
            if (n == 0) n = 1;
            dst[y * gw + x] = (@as(u32, @intCast(a / n)) << 24) |
                (@as(u32, @intCast(rr / n)) << 16) |
                (@as(u32, @intCast(gg / n)) << 8) |
                @as(u32, @intCast(bb / n));
        }
    }
}

/// Pango attributes used by every run on the lock screen: the design relies
/// on Inter's variable weight, on tabular numerals so the clock does not
/// jitter, and on tracking (clock `-.045em`, date `.005em`). Pango replaces
/// the whole attribute list, so weight, tracking, and features must be
/// applied together.
fn applyTypography(l: *text.Layout, tracking_px: f64, features: []const u8) void {
    const lo = l.layout orelse return;
    const attrs = text.pango_attr_list_new() orelse return;
    defer text.pango_attr_list_unref(attrs);
    if (tracking_px != 0.0) {
        const spacing: c_int = @intFromFloat(tracking_px * text.PANGO_SCALE);
        if (text.pango_attr_letter_spacing_new(spacing)) |attr| text.pango_attr_list_insert(attrs, attr);
    }
    if (features.len > 0) {
        var fbuf: [64:0]u8 = @as([64:0]u8, @splat(0));
        const n = @min(features.len, 63);
        @memcpy(fbuf[0..n], features[0..n]);
        if (text.pango_attr_font_features_new(&fbuf)) |attr| text.pango_attr_list_insert(attrs, attr);
    }
    text.pango_layout_set_attributes(lo, attrs);
}

/// A laid-out run of text plus its measured size. Owning the layout is what
/// lets the clock paint the same glyphs as a shadow and then as a gradient,
/// and lets the avatar centre its initial on the ink box rather than the
/// line box.
const Text = struct {
    layout: text.Layout,
    w: i32 = 0,
    h: i32 = 0,

    fn init(
        cr: *cairo.cairo_t,
        label: []const u8,
        size: f64,
        weight: c_uint,
        tracking_px: f64,
        features: []const u8,
    ) Text {
        var t = Text{ .layout = text.Layout.createForCairo(cr) };
        if (t.layout.layout == null or label.len == 0) return t;
        // Build the description from parts instead of a "family size" string:
        // the design leans on Inter Variable weights (600, 650), and only a
        // real weight on the description makes fontconfig pick the SemiBold
        // or Bold instance of the variable face.
        const desc = text.pango_font_description_new() orelse return t;
        defer text.pango_font_description_free(desc);
        text.pango_font_description_set_family(desc, "Inter Variable");
        text.pango_font_description_set_weight(desc, weight);
        text.pango_font_description_set_absolute_size(desc, @max(1.0, size) * text.PANGO_SCALE);
        if (t.layout.layout) |lo| text.pango_layout_set_font_description(lo, desc);
        t.layout.setText(label);
        applyTypography(&t.layout, tracking_px, features);
        const measured = t.layout.pixelSize();
        t.w = measured.w;
        t.h = measured.h;
        return t;
    }

    fn deinit(self: *Text) void {
        self.layout.destroy();
    }

    fn show(self: *const Text, cr: *cairo.cairo_t, x: f64, y: f64) void {
        if (self.layout.layout == null) return;
        cairo.cairo_move_to(cr, x, y);
        text.pango_cairo_show_layout(cr, self.layout.layout);
    }

    fn baseline(self: *Text) f64 {
        return self.layout.baseline();
    }
};

/// Soft shadow, then the text itself. Cairo has no blur filter, so a couple
/// of offset copies at decreasing alpha stand in for the design's CSS
/// `text-shadow`.
fn showShadowed(cr: *cairo.cairo_t, t: *const Text, x: f64, y: f64, off: f64, col: Rgba) void {
    if (t.layout.layout == null) return;
    // One close, faint copy. Without a blur primitive a second offset copy
    // becomes a visible grey ghost behind large glyphs.
    setRgba(cr, .{ .r = 0, .g = 0, .b = 0, .a = 0.16 });
    t.show(cr, x, y + off);
    setRgba(cr, col);
    t.show(cr, x, y);
}

fn drawCentered(
    cr: *cairo.cairo_t,
    label: []const u8,
    cx: f64,
    top: f64,
    size: f64,
    weight: c_uint,
    tracking_px: f64,
    col: Rgba,
    shadow_off: f64,
) void {
    if (label.len == 0) return;
    var t = Text.init(cr, label, size, weight, tracking_px, "");
    defer t.deinit();
    if (t.w == 0) return;
    const x = cx - @as(f64, @floatFromInt(t.w)) / 2.0;
    if (shadow_off > 0) {
        showShadowed(cr, &t, x, top, shadow_off, col);
    } else {
        setRgba(cr, col);
        t.show(cr, x, top);
    }
}

/// Fills a laid-out run as frosted glass: the glyph path becomes the clip,
/// the wallpaper behind is blurred in place, and a translucent white gradient
/// is laid over it. The result is text cut from the same glass as the
/// password pill rather than a flat white glyph.
fn paintGlassGlyphs(
    cr: *cairo.cairo_t,
    t: *Text,
    x: f64,
    y: f64,
    size: f64,
    top_alpha: f64,
    bottom_alpha: f64,
) void {
    const lo = t.layout.layout orelse return;

    const ink_rect = t.layout.pixelInk();
    const bx = x + @as(f64, @floatFromInt(ink_rect.x)) - 4.0;
    const by = y + @as(f64, @floatFromInt(ink_rect.y)) - 4.0;
    const bw = @as(f64, @floatFromInt(ink_rect.width)) + 8.0;
    const bh = @as(f64, @floatFromInt(ink_rect.height)) + 8.0;

    // The clip keeps the blur inside the letters, so the counter shapes stay
    // clear while the strokes read as glass. Blur before the rim, otherwise
    // the stamp would replace the wallpaper sample with flat white.
    cairo.cairo_save(cr);
    cairo.cairo_move_to(cr, x, y);
    text.pango_cairo_layout_path(cr, lo);
    cairo.cairo_clip(cr);
    _ = frostBackdrop(cr, bx, by, bw, bh, 0.0, 3);
    cairo.cairo_restore(cr);

    // Glass fill. A stroked rim would trace every overlapping contour inside
    // a composite glyph (visible seams across Inter's "1" and "4"), so the
    // edge is carried by the shadow and by the gradient's bright top band.
    cairo.cairo_save(cr);
    cairo.cairo_move_to(cr, x, y);
    text.pango_cairo_layout_path(cr, lo);
    cairo.cairo_clip(cr);
    const fill = cairo.cairo_pattern_create_linear(0, y, 0, y + size);
    if (fill != null) {
        cairo.cairo_pattern_add_color_stop_rgba(fill, 0, 1, 1, 1, top_alpha);
        cairo.cairo_pattern_add_color_stop_rgba(fill, 1, 1, 1, 1, bottom_alpha);
        cairo.cairo_set_source(cr, fill);
        cairo.cairo_paint(cr);
        cairo.cairo_pattern_destroy(fill);
    } else {
        setRgba(cr, .{ .r = 1, .g = 1, .b = 1, .a = top_alpha });
        cairo.cairo_paint(cr);
    }
    cairo.cairo_restore(cr);
}

fn drawDate(cr: *cairo.cairo_t, cx: f64, top: f64, size: f64, label: []const u8) void {
    if (label.len == 0) return;
    var t = Text.init(cr, label, size, 600, 0.005 * size, "");
    defer t.deinit();
    if (t.w == 0) return;
    const x = cx - @as(f64, @floatFromInt(t.w)) / 2.0;
    setRgba(cr, .{ .r = 0, .g = 0, .b = 0, .a = 0.16 });
    t.show(cr, x, top + @max(1.0, size * 0.06));
    paintGlassGlyphs(cr, &t, x, top, size, 0.70, 0.48);
}

/// The clock is split into the big gradient run and a small AM/PM suffix
/// hung near the baseline. Both are filled as frosted glass.
fn drawClock(cr: *cairo.cairo_t, cx: f64, top: f64, size: f64, label: []const u8) void {
    if (label.len == 0) return;

    var main = label;
    var suffix: []const u8 = "";
    if (label.len >= 3 and label[label.len - 3] == ' ') {
        const candidate = label[label.len - 2 ..];
        if (std.mem.eql(u8, candidate, "AM") or std.mem.eql(u8, candidate, "PM")) {
            main = label[0 .. label.len - 3];
            suffix = candidate;
        }
    }

    var t = Text.init(cr, main, size, 650, -0.045 * size, "tnum 1");
    defer t.deinit();
    if (t.w == 0) return;

    // CSS line-height:1 centres the font's em box in a box exactly `size`
    // tall. Pango's logical height is taller than the em box, so shift the
    // layout up by the difference.
    const layout_h = @as(f64, @floatFromInt(t.h));
    const y = top + (size - layout_h) / 2.0;
    const x = cx - @as(f64, @floatFromInt(t.w)) / 2.0;
    const shadow_off = @max(2.0, size * 0.012);

    const suffix_size = size * 0.24;
    var s = Text.init(cr, suffix, suffix_size, 600, 0, "");
    defer s.deinit();
    const big_baseline = y + t.baseline();
    const sx = x + @as(f64, @floatFromInt(t.w)) + size * 0.12;
    const sy = big_baseline - s.baseline() - size * 0.04;
    const has_suffix = suffix.len > 0 and s.w > 0;

    setRgba(cr, .{ .r = 0, .g = 0, .b = 0, .a = 0.16 });
    t.show(cr, x, y + shadow_off);
    if (has_suffix) {
        setRgba(cr, .{ .r = 0, .g = 0, .b = 0, .a = 0.16 });
        s.show(cr, sx, sy + @max(1.0, suffix_size * 0.05));
    }

    paintGlassGlyphs(cr, &t, x, y, size, 0.66, 0.40);
    if (has_suffix) paintGlassGlyphs(cr, &s, sx, sy, suffix_size, 0.66, 0.46);
}

/// Circle avatar. With an account photo the image is cover-cropped inside the
/// glass ring; without one the circle keeps the frosted plate and the account
/// initial.
fn drawAvatar(
    cr: *cairo.cairo_t,
    cx: f64,
    cy: f64,
    diameter: f64,
    user: []const u8,
    avatar: ?*cairo.cairo_surface_t,
) void {
    if (user.len == 0 and avatar == null) return;
    const r = diameter / 2.0;

    circlePath(cr, cx, cy + @max(2.0, diameter * 0.055), r + 1.0);
    setRgba(cr, .{ .r = 0, .g = 0, .b = 0, .a = 0.26 });
    cairo.cairo_fill(cr);
    circlePath(cr, cx, cy + @max(4.0, diameter * 0.10), r + 1.0);
    setRgba(cr, .{ .r = 0, .g = 0, .b = 0, .a = 0.10 });
    cairo.cairo_fill(cr);

    if (avatar) |surf| {
        const iw = cairo.cairo_image_surface_get_width(surf);
        const ih = cairo.cairo_image_surface_get_height(surf);
        if (iw > 0 and ih > 0) {
            const iwf: f64 = @floatFromInt(iw);
            const ihf: f64 = @floatFromInt(ih);
            const scale = @max(diameter / iwf, diameter / ihf);
            cairo.cairo_save(cr);
            circlePath(cr, cx, cy, r);
            cairo.cairo_clip(cr);
            cairo.cairo_translate(cr, cx, cy);
            cairo.cairo_scale(cr, scale, scale);
            cairo.cairo_set_source_surface(cr, surf, -iwf / 2.0, -ihf / 2.0);
            cairo.cairo_paint(cr);
            cairo.cairo_restore(cr);

            // A soft inner shade at the bottom keeps the face from floating on
            // top of the ring; the rim below supplies the outer edge.
            cairo.cairo_save(cr);
            circlePath(cr, cx, cy, r);
            cairo.cairo_clip(cr);
            const shade = cairo.cairo_pattern_create_linear(0, cy + r * 0.35, 0, cy + r);
            if (shade != null) {
                cairo.cairo_pattern_add_color_stop_rgba(shade, 0, 0, 0, 0, 0);
                cairo.cairo_pattern_add_color_stop_rgba(shade, 1, 0, 0, 0, 0.22);
                cairo.cairo_set_source(cr, shade);
                cairo.cairo_paint(cr);
                cairo.cairo_pattern_destroy(shade);
            }
            cairo.cairo_restore(cr);
        }
    } else {
        _ = frostBackdrop(cr, cx - r, cy - r, diameter, diameter, r, 3);
        circlePath(cr, cx, cy, r);
        setRgba(cr, .{ .r = 40.0 / 255.0, .g = 46.0 / 255.0, .b = 70.0 / 255.0, .a = 0.50 });
        cairo.cairo_fill(cr);

        circlePath(cr, cx, cy, r);
        const fill = cairo.cairo_pattern_create_linear(0, cy - r, 0, cy + r);
        if (fill != null) {
            cairo.cairo_pattern_add_color_stop_rgba(fill, 0, 1, 1, 1, 0.32);
            cairo.cairo_pattern_add_color_stop_rgba(fill, 1, 1, 1, 1, 0.10);
            cairo.cairo_set_source(cr, fill);
            cairo.cairo_fill(cr);
            cairo.cairo_pattern_destroy(fill);
        }
    }

    circlePath(cr, cx, cy, r);
    setRgba(cr, .{ .r = 1, .g = 1, .b = 1, .a = 0.32 });
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_stroke(cr);

    // `inset 0 1px 0 rgba(255,255,255,.25)` — a thin highlight along the top
    // inside edge.
    cairo.cairo_new_sub_path(cr);
    cairo.cairo_arc(cr, cx, cy, @max(1.0, r - 0.5), std.math.pi, 2.0 * std.math.pi);
    setRgba(cr, .{ .r = 1, .g = 1, .b = 1, .a = 0.25 });
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_stroke(cr);

    if (avatar != null or user.len == 0) return;
    const n = std.unicode.utf8ByteSequenceLength(user[0]) catch 1;
    var initial_buf: [8]u8 = undefined;
    var initial = user[0..@min(@as(usize, n), user.len)];
    if (initial.len == 1) {
        initial_buf[0] = std.ascii.toUpper(initial[0]);
        initial = initial_buf[0..1];
    }
    var t = Text.init(cr, initial, @max(diameter * 0.42, 18.0), 600, 0, "");
    defer t.deinit();
    if (t.w == 0) return;
    const ink_box = t.layout.pixelInk();
    const ix = cx - (@as(f64, @floatFromInt(ink_box.x)) + @as(f64, @floatFromInt(ink_box.width)) / 2.0);
    const iy = cy - (@as(f64, @floatFromInt(ink_box.y)) + @as(f64, @floatFromInt(ink_box.height)) / 2.0);
    setRgba(cr, ink);
    t.show(cr, ix, iy);
}

/// The frosted password pill: translucent white, a specular sheen across the
/// top, a 1px rim, the dots (or the placeholder) centred in the full width,
/// and the submit button floating at the right.
fn drawField(
    cr: *cairo.cairo_t,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    view: View,
) void {
    const r = h / 2.0;
    const pending = view.auth_pending;
    const failed = view.failed;
    const cy = y + h / 2.0;

    fillRounded(cr, x, y + 4.0, w, h, r, .{ .r = 0, .g = 0, .b = 0, .a = 0.20 });
    fillRounded(cr, x, y + 8.0, w, h, r, .{ .r = 0, .g = 0, .b = 0, .a = 0.08 });

    if (pending) {
        fillRounded(cr, x - 3.0, y - 3.0, w + 6.0, h + 6.0, r + 3.0, accent_ring);
    } else if (failed) {
        fillRounded(cr, x - 3.0, y - 3.0, w + 6.0, h + 6.0, r + 3.0, danger_ring);
    }

    // The design's backdrop blur is what separates the pill from the
    // wallpaper. Blur the same region first, then lay the white glass over
    // it; without that the rim disappears into a busy picture.
    _ = frostBackdrop(cr, x, y, w, h, r, 3);
    fillRounded(cr, x, y, w, h, r, .{ .r = 1, .g = 1, .b = 1, .a = 0.10 });

    cairo.cairo_save(cr);
    roundedRect(cr, x, y, w, h, r);
    cairo.cairo_clip(cr);
    const sheen = cairo.cairo_pattern_create_linear(0, y, 0, y + h * 0.55);
    if (sheen != null) {
        cairo.cairo_pattern_add_color_stop_rgba(sheen, 0, 1, 1, 1, 0.18);
        cairo.cairo_pattern_add_color_stop_rgba(sheen, 1, 1, 1, 1, 0.0);
        cairo.cairo_set_source(cr, sheen);
        cairo.cairo_paint(cr);
        cairo.cairo_pattern_destroy(sheen);
    }
    cairo.cairo_restore(cr);

    const edge = if (pending) accent else if (failed) danger else glass_edge;
    strokeRounded(cr, x + 0.5, y + 0.5, w - 1.0, h - 1.0, r, edge, 1.0);

    const go_d = @max(0.0, h - 8.0);
    const go_cx = x + w - 4.0 - go_d / 2.0;
    const has_text = view.password_len > 0;

    if (!has_text) {
        var p = Text.init(cr, "Enter Password", @max(h * 0.55, 11.0), 500, 0, "");
        defer p.deinit();
        if (p.w > 0) {
            cairo.cairo_move_to(
                cr,
                x + (w - @as(f64, @floatFromInt(p.w))) / 2.0,
                cy - @as(f64, @floatFromInt(p.h)) / 2.0,
            );
            setRgba(cr, .{ .r = 1, .g = 1, .b = 1, .a = 0.50 });
            if (p.layout.layout) |lo| text.pango_cairo_show_layout(cr, lo);
        }
    } else {
        const dot_d = @max(h * 0.22, 6.0);
        const max_dots: usize = @intFromFloat(@max(1.0, (w - 16.0) / (dot_d * 2.0)));
        const n = @min(view.password_len, max_dots);
        const first = x + w / 2.0 - @as(f64, @floatFromInt(n - 1)) * dot_d;
        setRgba(cr, .{ .r = 0.96, .g = 0.97, .b = 1.0, .a = 0.96 });
        var i: usize = 0;
        while (i < n) : (i += 1) {
            circlePath(cr, first + @as(f64, @floatFromInt(i)) * dot_d * 2.0, cy, dot_d / 2.0);
            cairo.cairo_fill(cr);
        }

        const blink_on = (local_time.now().second & 1) == 0;
        if (blink_on) {
            const caret_w = 1.5;
            const caret_h = @max(h * 0.56, 14.0);
            const caret_x = first + @as(f64, @floatFromInt(n - 1)) * dot_d * 2.0 + dot_d / 2.0 + 3.0;
            fillRounded(
                cr,
                caret_x,
                cy - caret_h / 2.0,
                caret_w,
                caret_h,
                caret_w / 2.0,
                .{ .r = 1, .g = 1, .b = 1, .a = 0.85 },
            );
        }
    }

    var go_fill = Rgba{ .r = 1, .g = 1, .b = 1, .a = 0.18 };
    var go_alpha: f64 = 1.0;
    if (pending) {
        go_fill = accent;
    } else if (failed) {
        go_fill = danger;
    } else if (!has_text) {
        go_alpha = 0.35;
    }

    circlePath(cr, go_cx, cy, go_d / 2.0);
    setRgba(cr, .{ .r = 0, .g = 0, .b = 0, .a = 0.16 * go_alpha });
    cairo.cairo_fill(cr);
    circlePath(cr, go_cx, cy, go_d / 2.0);
    setRgba(cr, .{ .r = go_fill.r, .g = go_fill.g, .b = go_fill.b, .a = @min(1.0, go_fill.a * go_alpha * 1.15) });
    cairo.cairo_fill(cr);
    circlePath(cr, go_cx, cy, go_d / 2.0);
    setRgba(cr, .{ .r = 1, .g = 1, .b = 1, .a = 0.30 * go_alpha });
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_stroke(cr);

    // The design's 24-unit arrow icon is drawn at 50% of the button.
    const scale = go_d * 0.5 / 24.0;
    const ox = go_cx - go_d * 0.25;
    const oy = cy - go_d * 0.25;
    setRgba(cr, .{ .r = 1, .g = 1, .b = 1, .a = go_alpha });
    cairo.cairo_set_line_width(cr, @max(1.0, 2.2 * scale));
    cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_set_line_join(cr, cairo.CAIRO_LINE_JOIN_ROUND);
    cairo.cairo_move_to(cr, ox + 5.0 * scale, oy + 12.0 * scale);
    cairo.cairo_line_to(cr, ox + 19.0 * scale, oy + 12.0 * scale);
    cairo.cairo_move_to(cr, ox + 13.0 * scale, oy + 6.0 * scale);
    cairo.cairo_line_to(cr, ox + 19.0 * scale, oy + 12.0 * scale);
    cairo.cairo_line_to(cr, ox + 13.0 * scale, oy + 18.0 * scale);
    cairo.cairo_stroke(cr);
}

fn drawHint(cr: *cairo.cairo_t, cx: f64, top: f64, size: f64, view: View) void {
    var col = Rgba{ .r = 0.80, .g = 0.83, .b = 0.90, .a = 0.92 };
    var label: []const u8 = "Press Enter to unlock";
    if (view.failed) {
        col = .{ .r = 1.0, .g = 150.0 / 255.0, .b = 150.0 / 255.0, .a = 1.0 };
        label = if (view.message.len > 0) view.message else "Incorrect password";
    } else if (view.auth_pending) {
        col = .{ .r = 200.0 / 255.0, .g = 218.0 / 255.0, .b = 1.0, .a = 1.0 };
        label = "Checking\u{2026}";
    }
    drawCentered(cr, label, cx, top, size, 500, 0, col, @max(1.0, size * 0.08));
}

pub fn paintLock(cr: ?*cairo.cairo_t, w: i32, h: i32, view: View) void {
    if (cr == null or w <= 0 or h <= 0) return;
    const c = cr.?;
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);

    if (!view.have_backdrop) {
        // Never invent a different wallpaper. This dark plate only covers the
        // interval between the first locked frame and the decode that follows.
        setRgba(c, .{ .r = 2.0 / 255.0, .g = 3.0 / 255.0, .b = 7.0 / 255.0, .a = 1.0 });
        cairo.cairo_paint(c);
    }

    // Tint plus the design's two fades: 42% from the top, 36% from the bottom.
    setRgba(c, .{ .r = 0, .g = 0, .b = 0, .a = 0.06 });
    cairo.cairo_paint(c);
    verticalFade(c, 0, fh * 0.42, 0.38, 0.0);
    verticalFade(c, fh * 0.64, fh, 0.0, 0.40);

    const date_size = @max(fh * 0.025, 11.0);
    drawDate(c, fw / 2.0, fh * 0.12, date_size, view.date);

    const clock_size = @max(fh * 0.17, 44.0);
    drawClock(c, fw / 2.0, fh * 0.16, clock_size, view.clock);

    // Login cluster. Every child is separated by the design's 1.6cqh gap;
    // the user line carries a -0.2cqh top margin.
    const gap = fh * 0.016;
    var y = fh * 0.58;

    const avatar_d = @max(fh * 0.086, 44.0);
    drawAvatar(c, fw / 2.0, y + avatar_d / 2.0, avatar_d, view.user, view.avatar);
    y += avatar_d + gap - fh * 0.002;

    const user_size = @max(fh * 0.025, 12.0);
    var user_text = Text.init(c, view.user, user_size, 600, 0, "");
    defer user_text.deinit();
    if (user_text.w > 0) {
        showShadowed(
            c,
            &user_text,
            fw / 2.0 - @as(f64, @floatFromInt(user_text.w)) / 2.0,
            y,
            @max(1.0, user_size * 0.08),
            .{ .r = 1, .g = 1, .b = 1, .a = 0.95 },
        );
    }
    y += @as(f64, @floatFromInt(user_text.h)) + gap;

    const field_w = @max(150.0, @min(240.0, fw * 0.19));
    const field_h = @max(28.0, @min(38.0, fh * 0.044));
    const field_x = (fw - field_w) / 2.0;
    const field_y = y;
    drawField(c, field_x, field_y, field_w, field_h, view);
    y = field_y + field_h + gap;

    drawHint(c, fw / 2.0, y, @max(fh * 0.019, 10.5), view);
}

test "lockscreen-paint: renders every state" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 640, 480);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paintLock(cr, 640, 480, .{ .clock = "2:05 PM", .date = "Monday, November 9", .user = "user", .password_len = 3 });
    paintLock(cr, 640, 480, .{ .clock = "14:05", .date = "Monday, November 9", .user = "user" });
    paintLock(cr, 640, 480, .{ .clock = "2:05 PM", .failed = true, .message = "Incorrect password" });
    paintLock(cr, 640, 480, .{ .clock = "2:05 PM", .auth_pending = true, .password_len = 8 });

    // The account photo path: a surface that is not square must still cover
    // the avatar circle without leaking outside it.
    const avatar = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 40, 24);
    defer cairo.cairo_surface_destroy(avatar);
    const acr = cairo.cairo_create(avatar);
    cairo.cairo_set_source_rgb(acr, 0.2, 0.6, 0.3);
    cairo.cairo_paint(acr);
    cairo.cairo_destroy(acr);
    paintLock(cr, 640, 480, .{ .clock = "2:05 PM", .user = "user", .avatar = avatar });
    paintLock(cr, 640, 480, .{ .user = "user", .avatar = avatar, .password_len = 4 });

    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}
