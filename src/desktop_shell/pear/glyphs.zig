//! Pear-local glyphs. The shared Lucide set covers most names pear needs;
//! the rest are drawn as cairo primitives here (instead of aliasing to
//! wrong-shaped icons): back chevron, checkboxes, radio buttons, eye,
//! phone, mic, and camera. All take centre + size + colour like
//! `svg_icons.draw`.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const svg = @import("../../ux/shared/svg_icons.zig");

/// Draw `name` through Lucide first, primitives second. Returns true when
/// something was drawn.
pub fn draw(cr: ?*cairo.cairo_t, name: []const u8, cx: f64, cy: f64, px: f64, r: f64, g: f64, b: f64) bool {
    const c = cr orelse return false;
    if (svg.draw(c, name, cx, cy, px, r, g, b, 1.0, false)) return true;
    if (std.mem.eql(u8, name, "arrow_back")) {
        chevronLeft(c, cx, cy, px, r, g, b);
        return true;
    }
    if (std.mem.eql(u8, name, "check_box")) {
        checkbox(c, cx, cy, px, r, g, b, true);
        return true;
    }
    if (std.mem.eql(u8, name, "check_box_outline_blank")) {
        checkbox(c, cx, cy, px, r, g, b, false);
        return true;
    }
    if (std.mem.eql(u8, name, "radio_checked")) {
        radio(c, cx, cy, px, r, g, b, true);
        return true;
    }
    if (std.mem.eql(u8, name, "radio_unchecked")) {
        radio(c, cx, cy, px, r, g, b, false);
        return true;
    }
    if (std.mem.eql(u8, name, "visibility")) {
        eye(c, cx, cy, px, r, g, b, true);
        return true;
    }
    if (std.mem.eql(u8, name, "visibility_off")) {
        eye(c, cx, cy, px, r, g, b, false);
        return true;
    }
    if (std.mem.eql(u8, name, "smartphone")) {
        phone(c, cx, cy, px, r, g, b);
        return true;
    }
    if (std.mem.eql(u8, name, "mic")) {
        mic(c, cx, cy, px, r, g, b, false);
        return true;
    }
    if (std.mem.eql(u8, name, "mic_off")) {
        mic(c, cx, cy, px, r, g, b, true);
        return true;
    }
    if (std.mem.eql(u8, name, "photo_camera")) {
        camera(c, cx, cy, px, r, g, b);
        return true;
    }
    return false;
}

fn stroke(c: ?*cairo.cairo_t, w: f64) void {
    cairo.cairo_set_line_width(c, w);
    cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_set_line_join(c, cairo.CAIRO_LINE_JOIN_ROUND);
}

fn chevronLeft(c: ?*cairo.cairo_t, cx: f64, cy: f64, px: f64, r: f64, g: f64, b: f64) void {
    const s = px * 0.32;
    cairo.cairo_set_source_rgba(c, r, g, b, 1.0);
    stroke(c, @max(1.5, px * 0.09));
    cairo.cairo_move_to(c, cx + s * 0.6, cy - s);
    cairo.cairo_line_to(c, cx - s * 0.6, cy);
    cairo.cairo_line_to(c, cx + s * 0.6, cy + s);
    cairo.cairo_stroke(c);
}

fn checkbox(c: ?*cairo.cairo_t, cx: f64, cy: f64, px: f64, r: f64, g: f64, b: f64, on: bool) void {
    const s = px * 0.36;
    if (on) {
        cairo.cairo_rectangle(c, cx - s, cy - s, s * 2, s * 2);
        cairo.cairo_set_source_rgba(c, r, g, b, 1.0);
        cairo.cairo_fill(c);
        cairo.cairo_set_source_rgba(c, 0.05, 0.05, 0.07, 1.0);
        stroke(c, @max(1.5, px * 0.09));
        cairo.cairo_move_to(c, cx - s * 0.55, cy);
        cairo.cairo_line_to(c, cx - s * 0.1, cy + s * 0.45);
        cairo.cairo_line_to(c, cx + s * 0.6, cy - s * 0.5);
        cairo.cairo_stroke(c);
    } else {
        cairo.cairo_rectangle(c, cx - s, cy - s, s * 2, s * 2);
        cairo.cairo_set_source_rgba(c, r, g, b, 1.0);
        stroke(c, @max(1.5, px * 0.09));
        cairo.cairo_stroke(c);
    }
}

fn radio(c: ?*cairo.cairo_t, cx: f64, cy: f64, px: f64, r: f64, g: f64, b: f64, on: bool) void {
    const s = px * 0.36;
    cairo.cairo_arc(c, cx, cy, s, 0, 6.283185307179586);
    cairo.cairo_set_source_rgba(c, r, g, b, 1.0);
    stroke(c, @max(1.5, px * 0.09));
    cairo.cairo_stroke(c);
    if (on) {
        cairo.cairo_arc(c, cx, cy, s * 0.45, 0, 6.283185307179586);
        cairo.cairo_fill(c);
    }
}

fn eye(c: ?*cairo.cairo_t, cx: f64, cy: f64, px: f64, r: f64, g: f64, b: f64, on: bool) void {
    const w = px * 0.42;
    const h = px * 0.26;
    cairo.cairo_save(c);
    cairo.cairo_translate(c, cx, cy);
    cairo.cairo_scale(c, 1.0, h / @max(1.0, w));
    cairo.cairo_arc(c, 0, 0, w, 0, 6.283185307179586);
    cairo.cairo_restore(c);
    cairo.cairo_set_source_rgba(c, r, g, b, 1.0);
    stroke(c, @max(1.5, px * 0.08));
    cairo.cairo_stroke(c);
    cairo.cairo_arc(c, cx, cy, px * 0.10, 0, 6.283185307179586);
    cairo.cairo_fill(c);
    if (!on) {
        cairo.cairo_move_to(c, cx - w, cy + h);
        cairo.cairo_line_to(c, cx + w, cy - h);
        cairo.cairo_stroke(c);
    }
}

fn phone(c: ?*cairo.cairo_t, cx: f64, cy: f64, px: f64, r: f64, g: f64, b: f64) void {
    const w = px * 0.30;
    const h = px * 0.42;
    cairo.cairo_rectangle(c, cx - w, cy - h, w * 2, h * 2);
    cairo.cairo_set_source_rgba(c, r, g, b, 1.0);
    stroke(c, @max(1.5, px * 0.08));
    cairo.cairo_stroke(c);
    cairo.cairo_move_to(c, cx, cy + h * 0.72);
    cairo.cairo_line_to(c, cx, cy + h * 0.73);
    cairo.cairo_stroke(c);
}

fn mic(c: ?*cairo.cairo_t, cx: f64, cy: f64, px: f64, r: f64, g: f64, b: f64, off: bool) void {
    cairo.cairo_set_source_rgba(c, r, g, b, 1.0);
    const w = px * 0.16;
    const h = px * 0.26;
    cairo.cairo_rectangle(c, cx - w, cy - h * 1.4, w * 2, h * 2);
    cairo.cairo_fill(c);
    stroke(c, @max(1.5, px * 0.08));
    cairo.cairo_arc(c, cx, cy + h * 0.1, px * 0.26, 0.15 * 3.14159, 0.85 * 3.14159);
    cairo.cairo_stroke(c);
    cairo.cairo_move_to(c, cx, cy + h * 0.1 + px * 0.26);
    cairo.cairo_line_to(c, cx, cy + h * 1.5);
    cairo.cairo_stroke(c);
    if (off) {
        cairo.cairo_move_to(c, cx - px * 0.4, cy + h * 1.5);
        cairo.cairo_line_to(c, cx + px * 0.4, cy - h * 1.5);
        cairo.cairo_stroke(c);
    }
}

fn camera(c: ?*cairo.cairo_t, cx: f64, cy: f64, px: f64, r: f64, g: f64, b: f64) void {
    const w = px * 0.40;
    const h = px * 0.28;
    cairo.cairo_set_source_rgba(c, r, g, b, 1.0);
    stroke(c, @max(1.5, px * 0.08));
    cairo.cairo_move_to(c, cx - w * 0.5, cy - h);
    cairo.cairo_line_to(c, cx - w * 0.2, cy - h * 1.5);
    cairo.cairo_line_to(c, cx + w * 0.2, cy - h * 1.5);
    cairo.cairo_line_to(c, cx + w * 0.5, cy - h);
    cairo.cairo_stroke(c);
    cairo.cairo_rectangle(c, cx - w, cy - h, w * 2, h * 2);
    cairo.cairo_stroke(c);
    cairo.cairo_arc(c, cx, cy, px * 0.10, 0, 6.283185307179586);
    cairo.cairo_stroke(c);
}

test "pear-glyphs: every pear-only name draws onto a surface" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 64, 320);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    for ([_][]const u8{
        "arrow_back", "check_box",           "check_box_outline_blank",
        "radio_checked", "radio_unchecked",  "visibility", "visibility_off",
        "smartphone",   "mic",               "mic_off",    "photo_camera",
        "wifi",         "bluetooth",         "settings",   "volume_up",
    }) |name| {
        try t.expect(draw(cr, name, 32, 32, 20, 1, 1, 1));
    }
    try t.expect(!draw(cr, "definitely-not-a-pear-glyph", 32, 32, 20, 1, 1, 1));
    try t.expect(!draw(null, "mic", 32, 32, 20, 1, 1, 1));
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}
