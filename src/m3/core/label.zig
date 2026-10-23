//! A text label drawn through a pango layout.
//!
//! Every label builds its own layout per paint. That sounds wasteful, and it
//! is why `measureExtents` sits in front of it: button-like labels are
//! measured twice a frame, so short static strings go through the bounded
//! extent cache and a shared thread-local scratch context (`m3/core/measure`)
//! instead of creating a surface each time.
//!
//! `FontConfig.family` is read as a **literal pango family name**, not a
//! semantic slot — an empty family falls back to "Inter". The same family
//! field holds "plain"/"brand" for the type scale and a real font name here.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const text = @import("../../text/layout.zig");
const measure = @import("measure.zig");
const type_scale = @import("../tokens/type_scale.zig");

pub const FontConfig = type_scale.FontConfig;

/// Default font `{14.0f, 400, 20.0f, 0.25f, "plain"}`
/// — bodyMedium's metrics with the semantic slot name as the family.
const default_font = FontConfig{
    .size = 14.0,
    .weight = 400,
    .line_height = 20.0,
    .letter_spacing = 0.25,
    .family = "plain",
};

/// The family used when `FontConfig.family` is empty.
const fallback_family = "Inter";

/// Text label using Pango layout. Supports M3 FontConfig or direct font props.
pub const Label = struct {
    text: []const u8 = "",
    fc: FontConfig = default_font,
    r: f32 = 0.94,
    g: f32 = 0.94,
    b: f32 = 0.96,
    a: f32 = 1.0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,

    pub fn setText(self: *Label, t: []const u8) void {
        self.text = t;
    }

    pub fn setFontConfig(self: *Label, fc: FontConfig) void {
        self.fc = fc;
    }

    pub fn setFontSize(self: *Label, sp: f32) void {
        self.fc.size = sp;
    }

    pub fn setFontWeight(self: *Label, weight: c_uint) void {
        self.fc.weight = weight;
    }

    pub fn setFontFamily(self: *Label, f: []const u8) void {
        self.fc.family = f;
    }

    /// `a` defaults to fully opaque.
    pub fn setColor(self: *Label, red: f32, green: f32, blue: f32, alpha: f32) void {
        self.r = red;
        self.g = green;
        self.b = blue;
        self.a = alpha;
    }

    pub fn setGeometry(self: *Label, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn xPos(self: *const Label) f32 {
        return self.x;
    }

    pub fn yPos(self: *const Label) f32 {
        return self.y;
    }

    pub fn width(self: *const Label) f32 {
        return self.w;
    }

    pub fn height(self: *const Label) f32 {
        return self.h;
    }

    pub fn labelText(self: *const Label) []const u8 {
        return self.text;
    }

    /// Copy the family into a NUL-terminated buffer — pango takes a C string,
    /// and the caller's slice is not guaranteed to be terminated.
    fn familyZ(self: *const Label, buf: *[256:0]u8) [*c]const u8 {
        const fam = if (self.fc.family.len == 0) fallback_family else self.fc.family;
        const n = @min(fam.len, 255);
        @memcpy(buf[0..n], fam[0..n]);
        buf[n] = 0;
        return buf;
    }

    /// Build the pango size in pango units. `PANGO_SCALE` is 1024 units per
    /// pixel, and a size of 0 is passed through untouched.
    fn pangoSize(self: *const Label) c_int {
        return @intFromFloat(@round(@as(f64, self.fc.size) * text.PANGO_SCALE));
    }

    /// Build a layout for this label's font and text. Returns null when there
    /// is nothing to draw or cairo could not hand us a context. The caller
    /// owns the layout and must `g_object_unref` it.
    ///
    /// Layout preparation without the draw callback:
    /// a draw callback, but every caller here just sets a source colour and
    /// shows the layout, so the draw step stays with the caller.
    fn prepareLayout(self: *const Label, cr: ?*cairo.cairo_t) ?*text.PangoLayout {
        if (self.text.len == 0) return null;
        const c = cr orelse return null;
        const lo = text.pango_cairo_create_layout(c) orelse return null;
        const desc = text.pango_font_description_new() orelse {
            text.g_object_unref(lo);
            return null;
        };

        var fam_buf: [256:0]u8 = @as([256:0]u8, @splat(0));
        text.pango_font_description_set_family(desc, self.familyZ(&fam_buf));
        text.pango_font_description_set_size(desc, self.pangoSize());
        text.pango_font_description_set_weight(desc, self.fc.weight);
        text.pango_layout_set_font_description(lo, desc);
        text.pango_layout_set_text(lo, self.text.ptr, @intCast(self.text.len));
        // A positive width tells pango to wrap; zero means "no wrapping",
        // which is pango's own default.
        if (self.w > 0) {
            text.pango_layout_set_width(lo, @intFromFloat(@round(@as(f64, self.w) * text.PANGO_SCALE)));
        }
        text.pango_font_description_free(desc);
        return lo;
    }

    /// Measure text extent without painting.
    pub fn measureExtents(self: *const Label, out_w: *f32, out_h: *f32) void {
        if (self.text.len == 0) {
            out_w.* = 0;
            out_h.* = 0;
            return;
        }

        // Fast path: short static labels (buttons, combo titles) are measured
        // every frame; a bounded cache turns repeats into a hash lookup and a
        // shared scratch context avoids per-call surface create/destroy.
        const cacheable = self.text.len <= 48;
        if (cacheable) {
            var key_buf: [512]u8 = undefined;
            if (buildKey(self, &key_buf)) |key| {
                if (measure.lookup(key, out_w, out_h)) return;
            }
        }

        const cr = measure.scratch_cr();
        const lo = self.prepareLayout(cr) orelse {
            out_w.* = 0;
            out_h.* = 0;
            return;
        };
        var pw: c_int = 0;
        var ph: c_int = 0;
        text.pango_layout_get_pixel_size(lo, &pw, &ph);
        out_w.* = @floatFromInt(pw);
        out_h.* = @floatFromInt(ph);
        text.g_object_unref(lo);

        if (cacheable) {
            var key_buf: [512]u8 = undefined;
            if (buildKey(self, &key_buf)) |key| measure.store(key, out_w.*, out_h.*);
        }
    }

    /// Assemble the extent-cache key: family, then a separator
    /// (`\x1f`, ASCII unit separator), then "size|weight|width|", then the
    /// text. The width is part of the key because a wrapped label's height
    /// depends on how much room it was given.
    fn buildKey(self: *const Label, buf: []u8) ?[]const u8 {
        const fam = if (self.fc.family.len == 0) fallback_family else self.fc.family;
        return std.fmt.bufPrint(
            buf,
            "{s}\x1f{d:.2}|{d}|{d:.1}|{s}",
            .{ fam, self.fc.size, self.fc.weight, self.w, self.text },
        ) catch null;
    }

    pub fn paint(self: *const Label, c: ?*cairo.cairo_t) void {
        // Guard on w_/h_ as well as the text, so an un-sized label
        // draws nothing from `paint` — use `paintAt` for that.
        if (self.text.len == 0 or self.w <= 0 or self.h <= 0) return;
        const cr = c orelse return;
        const lo = self.prepareLayout(cr) orelse return;
        defer text.g_object_unref(lo);

        cairo.cairo_set_source_rgba(cr, self.r, self.g, self.b, self.a);
        text.pango_cairo_show_layout(cr, lo);
    }

    /// Paint at arbitrary position (ignores x, y).
    pub fn paintAt(self: *const Label, c: ?*cairo.cairo_t, px: f32, py: f32) void {
        if (self.text.len == 0) return;
        const cr = c orelse return;
        cairo.cairo_save(cr);
        cairo.cairo_translate(cr, px, py);
        const lo = self.prepareLayout(cr) orelse {
            cairo.cairo_restore(cr);
            return;
        };
        cairo.cairo_set_source_rgba(cr, self.r, self.g, self.b, self.a);
        text.pango_cairo_show_layout(cr, lo);
        text.g_object_unref(lo);
        cairo.cairo_restore(cr);
    }
};

test "m3-label: measures and paints real text" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 200, 60);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var l = Label{};
    l.setText("Add widget");
    l.setFontSize(14.0);
    l.setFontWeight(600);
    l.setGeometry(4, 4, 180, 24);

    var w: f32 = 0;
    var h: f32 = 0;
    l.measureExtents(&w, &h);
    // Measuring real text must produce a real extent, not a zero box.
    try t.expect(w > 0 and h > 0);
    // The measured height is at most a couple of lines at 14sp.
    try t.expect(h < 80);

    l.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    l.paintAt(cr, 10, 30);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}

test "m3-label: empty or un-sized labels draw nothing" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 40, 40);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var empty = Label{};
    empty.setGeometry(0, 0, 20, 20);
    var w: f32 = 1;
    var h: f32 = 1;
    empty.measureExtents(&w, &h);
    try t.expectEqual(@as(f32, 0.0), w);
    try t.expectEqual(@as(f32, 0.0), h);
    empty.paint(cr);
    empty.paintAt(cr, 0, 0);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Sized zero, `paint` bails — but `paintAt` ignores geometry and draws.
    var unsized = Label{};
    unsized.setText("x");
    unsized.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}

test "m3-label: getters and setters round-trip" {
    const t = std.testing;
    var l = Label{};
    l.setText("hello");
    l.setFontSize(20.0);
    l.setFontWeight(700);
    l.setFontFamily("Inter");
    l.setColor(1, 0, 0, 0.5);
    l.setGeometry(1, 2, 3, 4);
    try t.expectEqualStrings("hello", l.labelText());
    try t.expectEqual(@as(f32, 20.0), l.fc.size);
    try t.expectEqual(@as(c_uint, 700), l.fc.weight);
    try t.expectEqual(@as(f32, 4.0), l.height());
    try t.expectEqual(@as(f32, 0.5), l.a);
}
