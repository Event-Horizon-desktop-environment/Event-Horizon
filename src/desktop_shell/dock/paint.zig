const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const repetition = @import("../../compat/repetition.zig");
const tokens = @import("../../m3/tokens.zig");
const cairo_helpers = @import("../shared/cairo_helpers.zig");

pub const IconPx = struct {
    pixels: []const u8 = &.{},
    w: i32 = 0,
    h: i32 = 0,
    /// Paint the raster's alpha channel as a mask over this flat colour
    /// instead of blitting its own pixels, so the distro mark follows the wallpaper instead of sitting at
    /// its shipped brand colour. Null keeps the icon's own colours.
    tint: ?tokens.Rgb = null,
};

pub fn paintDock(cr: ?*cairo.cairo_t, w: i32, h: i32, icons: []const IconPx, icon_size: i32, spacing: i32) void {
    if (cr == null) return;
    cairo_helpers.paintBar(cr, w, h, 18.0, 1.0);
    const c = cr.?;
    var x: i32 = spacing;
    for (icons) |icon| {
        const y: i32 = @divTrunc(h - icon_size, 2);
        if (icon.pixels.len > 0 and icon.w > 0 and icon.h > 0) {
            const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, icon_size, icon_size);
            defer cairo.cairo_surface_destroy(surf);
            const scr = cairo.cairo_create(surf);
            defer cairo.cairo_destroy(scr);
            scaleBlit(scr, icon, icon_size);
            cairo.cairo_set_source_surface(c, surf, @floatFromInt(x), @floatFromInt(y));
            cairo.cairo_paint(c);
        } else {
            cairo.cairo_set_source_rgba(c, tokens.Tokens.accent.r, tokens.Tokens.accent.g, tokens.Tokens.accent.b, 0.9);
            cairo_helpers.roundedRect(c, @floatFromInt(x), @floatFromInt(y), @floatFromInt(icon_size), @floatFromInt(icon_size), 12.0);
            cairo.cairo_fill(c);
        }
        x += icon_size + spacing;
    }
}

fn scaleBlit(cr: ?*cairo.cairo_t, icon: IconPx, size: i32) void {
    if (cr == null) return;
    const c = cr.?;
    cairo.cairo_scale(c, @as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(icon.w)), @as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(icon.h)));
    const tmp = cairo.cairo_image_surface_create_for_data(
        @constCast(icon.pixels.ptr),
        cairo.CAIRO_FORMAT_ARGB32,
        icon.w,
        icon.h,
        icon.w * 4,
    );
    defer cairo.cairo_surface_destroy(tmp);
    cairo.cairo_set_source_surface(c, tmp, 0, 0);
    cairo.cairo_pattern_set_extend(cairo.cairo_get_source(c), cairo.CAIRO_EXTEND_NONE);
    cairo.cairo_paint(c);
}

test "dock-paint: icons render" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 400, 72);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    const red = repetition.repeatBytes(256, &.{ 0, 0, 255, 255 });
    const icons = [_]IconPx{
        .{ .pixels = &red, .w = 8, .h = 8 },
        .{},
        .{ .pixels = &red, .w = 8, .h = 8 },
    };
    paintDock(cr, 400, 72, &icons, 48, 8);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}
