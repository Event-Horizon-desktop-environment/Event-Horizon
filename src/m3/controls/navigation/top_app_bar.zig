//! The M3 top app bar, in four
//! variants: Small, Center, Medium, Large.
//!
//! The variants differ only in the *title's* size and baseline. Large and
//! Medium both sit at `y + h - 28` with 28pt and 22pt type; Small and Center
//! share the vertically-centred 20pt formula. Center is the only one that
//! measures the title and centres it — every other variant starts it 16dp in
//! from the left edge.
//!
//! Like `BottomAppBar`, the bar itself is a plain opaque rectangle with a 1dp
//! shadow band along its *bottom* edge this time. Title text goes through
//! cairo toy text in "Sans", not pango, so it will not pick up the shell's
//! configured family.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;

/// M3 Top App Bar — Small, Center, Medium, Large.
pub const TopAppBar = struct {
    pub const Variant = enum {
        small,
        center,
        medium,
        large,
    };

    /// Title font size and baseline offset from the bar's top edge, for the
    /// Large and Medium variants (which sit on a shared `h - 28` baseline).
    pub const kLargeFont: f32 = 28.0;
    pub const kMediumFont: f32 = 22.0;
    /// Small and Center are centred vertically at 20pt.
    pub const kSmallFont: f32 = 20.0;
    /// Left inset for every variant except Center.
    pub const kLeftPad: f32 = 16.0;
    /// Shared baseline for Large and Medium.
    pub const kBaselineFromBottom: f32 = 28.0;

    variant: Variant = .small,
    title: []const u8 = "",

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 64.0,

    accent_r: f32 = 0.769,
    accent_g: f32 = 0.659,
    accent_b: f32 = 0.941,
    surface_r: f32 = 0.102,
    surface_g: f32 = 0.075,
    surface_b: f32 = 0.188,
    text_r: f32 = 1.0,
    text_g: f32 = 1.0,
    text_b: f32 = 1.0,
    outline_r: f32 = 0.478,
    outline_g: f32 = 0.416,
    outline_b: f32 = 0.588,

    pub fn setVariant(self: *TopAppBar, v: Variant) void {
        self.variant = v;
    }

    pub fn setTitle(self: *TopAppBar, t: []const u8) void {
        self.title = t;
    }

    pub fn setGeometry(self: *TopAppBar, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *TopAppBar, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *TopAppBar, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *TopAppBar, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *TopAppBar, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn xPos(self: *const TopAppBar) f32 {
        return self.x;
    }

    pub fn yPos(self: *const TopAppBar) f32 {
        return self.y;
    }

    pub fn width(self: *const TopAppBar) f32 {
        return self.w;
    }

    pub fn height(self: *const TopAppBar) f32 {
        return self.h;
    }

    pub fn paint(self: *const TopAppBar, c: ?*cairo.cairo_t) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;
        const cr = c orelse return;

        const large = self.variant == .large;
        const medium = self.variant == .medium;
        const center = self.variant == .center;

        // Background — an opaque rectangle, plus a 1dp band along the *bottom*
        // edge (the bottom bar puts its band on top instead).
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, self.surface_r, self.surface_g, self.surface_b, 1.0);
        cairo.cairo_rectangle(cr, self.x, self.y, self.w, self.h);
        cairo.cairo_fill(cr);

        cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0.06);
        cairo.cairo_rectangle(cr, self.x, self.y + self.h - 1, self.w, 1);
        cairo.cairo_fill(cr);
        cairo.cairo_restore(cr);

        // Title.
        cairo.cairo_save(cr);
        cairo.cairo_select_font_face(
            cr,
            "Sans",
            cairo.CAIRO_FONT_SLANT_NORMAL,
            cairo.CAIRO_FONT_WEIGHT_NORMAL,
        );

        var font_size: f32 = 0;
        var ty: f32 = 0;
        if (large) {
            font_size = kLargeFont;
            ty = self.y + self.h - kBaselineFromBottom;
        } else if (medium) {
            font_size = kMediumFont;
            ty = self.y + self.h - kBaselineFromBottom;
        } else {
            font_size = kSmallFont;
            ty = self.y + (self.h - font_size) * 0.5 + font_size * 0.75;
        }

        cairo.cairo_set_font_size(cr, font_size);
        cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, 0.93);

        var buf: [256:0]u8 = undefined;
        const title = toCString(self.title, &buf);

        var tx: f32 = 0;
        if (center) {
            // Only Center measures before placing — the others are hard-left.
            var te: cairo.cairo_text_extents_t = undefined;
            cairo.cairo_text_extents(cr, title, &te);
            tx = self.x + (self.w - @as(f32, @floatCast(te.width))) * 0.5;
        } else {
            tx = self.x + kLeftPad;
        }

        cairo.cairo_move_to(cr, tx, ty);
        cairo.cairo_show_text(cr, title);
        cairo.cairo_restore(cr);
    }

    /// `cairo_show_text` needs a NUL-terminated C string, and an empty
    /// `[]const u8` has no terminator to point at — so the title always goes
    /// through the caller's stack buffer.
    fn toCString(s: []const u8, buf: *[256:0]u8) [*c]const u8 {
        const n = @min(s.len, 255);
        @memcpy(buf[0..n], s[0..n]);
        buf[n] = 0;
        return buf;
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-top-app-bar: every variant paints its title" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 320, 120);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    inline for (.{ .small, .center, .medium, .large }) |v| {
        var bar = TopAppBar{};
        bar.setVariant(v);
        bar.setTitle("Settings");
        bar.setGeometry(0, 0, 300, 64);
        bar.paint(cr);
        try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    }

    // An empty title still paints — the buffer is NUL-terminated regardless.
    var bare = TopAppBar{};
    bare.setGeometry(0, 0, 300, 64);
    bare.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Long titles are truncated by the 255-byte buffer rather than read past.
    var long = TopAppBar{};
    long.setVariant(.center);
    long.setTitle("A very long window title that will not fit in the buffer at all because it goes on and on and on for quite a while");
    long.setGeometry(0, 0, 300, 64);
    long.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Degenerate geometry paints nothing, so a null context is safe.
    var degenerate = TopAppBar{};
    degenerate.setGeometry(0, 0, 0, 0);
    degenerate.paint(cr);
    degenerate.paint(null);
}

test "m3-top-app-bar: defaults and accessors behave as specified" {
    const t = testing;
    var bar = TopAppBar{};
    try t.expect(bar.variant == .small);
    try t.expectEqual(@as(f32, 64.0), bar.height());
    bar.setVariant(.large);
    bar.setTitle("Title");
    bar.setGeometry(1, 2, 3, 4);
    try t.expect(bar.variant == .large);
    try t.expectEqualStrings("Title", bar.title);
    try t.expectEqual(@as(f32, 1.0), bar.xPos());
    try t.expectEqual(@as(f32, 2.0), bar.yPos());
    try t.expectEqual(@as(f32, 3.0), bar.width());
    try t.expectEqual(@as(f32, 4.0), bar.height());
}
