//! The M3 search bar.
//!
//! A pill-shaped field: a `Box` at radius `h/2` with the glassy inner rim, a
//! 2dp accent outline while focused, a leading magnifier glyph, then either
//! the query or the hint.
//!
//! Everything here is cairo toy text rather than pango — the icon explicitly
//! asks for "Symbols Nerd Font" and the text for "Sans" — so the bar will not
//! follow the shell's configured typeface.
//!
//! One port note: the icon was spelled as the surrogate pair
//! `"\uD83D\uDD0D"`, whose intent is U+1F50D (magnifying glass tilted left).
//! This port writes the literal UTF-8 `🔍` instead — the same code point, but
//! unambiguous rather than relying on how a compiler happens to pair
//! surrogates.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const box_mod = @import("../../core/primitives/box.zig");

pub const Box = box_mod.Box;

/// `onSubmit` sink; `text` is borrowed and valid only for the call.
pub const SubmitCallback = *const fn (ctx: ?*anyopaque, text: []const u8) void;

/// M3 Search Bar — input-style bar with leading icon and optional trailing action.
pub const SearchBar = struct {
    /// Leading magnifier glyph, U+1F50D.
    pub const kSearchIcon = "\u{1F50D}";
    pub const kIconSize: f32 = 20.0;
    /// Left inset for the icon, and the text start past it.
    pub const kIconX: f32 = 16.0;
    pub const kTextX: f32 = 48.0;
    /// Font size for both query and hint.
    pub const kFontSize: f32 = 16.0;
    /// Focused outline width.
    pub const kOutlineWidth: f32 = 2.0;

    text: []const u8 = "",
    hint: []const u8 = "",
    focused: bool = false,

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 48.0,

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

    on_submit: ?SubmitCallback = null,
    cb_ctx: ?*anyopaque = null,

    pub fn setText(self: *SearchBar, t: []const u8) void {
        self.text = t;
    }

    pub fn setHint(self: *SearchBar, h: []const u8) void {
        self.hint = h;
    }

    pub fn setGeometry(self: *SearchBar, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *SearchBar, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *SearchBar, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *SearchBar, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *SearchBar, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn setFocused(self: *SearchBar, f: bool) void {
        self.focused = f;
    }

    pub fn setOnSubmit(self: *SearchBar, cb: ?SubmitCallback) void {
        self.on_submit = cb;
    }

    pub fn setCallbackContext(self: *SearchBar, ctx: ?*anyopaque) void {
        self.cb_ctx = ctx;
    }

    pub fn xPos(self: *const SearchBar) f32 {
        return self.x;
    }

    pub fn yPos(self: *const SearchBar) f32 {
        return self.y;
    }

    pub fn width(self: *const SearchBar) f32 {
        return self.w;
    }

    pub fn height(self: *const SearchBar) f32 {
        return self.h;
    }

    pub fn containsPoint(self: *const SearchBar, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    /// Fire `on_submit` with the current query, as Enter would.
    pub fn submit(self: *SearchBar) void {
        if (self.on_submit) |cb| cb(self.cb_ctx, self.text);
    }

    pub fn paint(self: *const SearchBar, c: ?*cairo.cairo_t) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;
        const cr = c orelse return;

        // Full pill: the corner radius is half the height.
        const r = self.h * 0.5;

        cairo.cairo_save(cr);

        // Container via Box for the frosted inner rim.
        var bg_box = Box{};
        bg_box.setColor(self.surface_r, self.surface_g, self.surface_b, 1.0);
        bg_box.setRadius(r);
        bg_box.setGeometry(self.x, self.y, self.w, self.h);
        bg_box.setGlassy(true);
        bg_box.paint(c);

        // Focused outline — 2dp on the pill edge.
        if (self.focused) {
            cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, 1.0);
            cairo.cairo_set_line_width(cr, kOutlineWidth);
            cairo.cairo_new_path(cr);
            cairo.cairo_arc(cr, self.x + r, self.y + r, r, std.math.pi, 1.5 * std.math.pi);
            cairo.cairo_arc(cr, self.x + self.w - r, self.y + r, r, 1.5 * std.math.pi, 2.0 * std.math.pi);
            cairo.cairo_arc(cr, self.x + self.w - r, self.y + self.h - r, r, 0.0, 0.5 * std.math.pi);
            cairo.cairo_arc(cr, self.x + r, self.y + self.h - r, r, 0.5 * std.math.pi, std.math.pi);
            cairo.cairo_close_path(cr);
            cairo.cairo_stroke(cr);
        }

        cairo.cairo_restore(cr);

        // Leading magnifier, baseline nudged down by a third of its size.
        cairo.cairo_save(cr);
        cairo.cairo_select_font_face(
            cr,
            "Symbols Nerd Font",
            cairo.CAIRO_FONT_SLANT_NORMAL,
            cairo.CAIRO_FONT_WEIGHT_NORMAL,
        );
        cairo.cairo_set_font_size(cr, kIconSize);
        cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, 0.46);
        cairo.cairo_move_to(cr, self.x + kIconX, self.y + self.h * 0.5 + kIconSize * 0.3);
        cairo.cairo_show_text(cr, kSearchIcon);
        cairo.cairo_restore(cr);

        // Query, or hint when empty.
        cairo.cairo_save(cr);
        cairo.cairo_select_font_face(
            cr,
            "Sans",
            cairo.CAIRO_FONT_SLANT_NORMAL,
            cairo.CAIRO_FONT_WEIGHT_NORMAL,
        );
        cairo.cairo_set_font_size(cr, kFontSize);
        var buf: [256:0]u8 = undefined;
        const shown = if (self.text.len == 0)
            (if (self.hint.len == 0) "Search" else self.hint)
        else
            self.text;
        const alpha: f32 = if (self.text.len == 0) 0.38 else 0.93;
        cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, alpha);
        cairo.cairo_move_to(cr, self.x + kTextX, self.y + self.h * 0.5 + 6);
        cairo.cairo_show_text(cr, toCString(shown, &buf));
        cairo.cairo_restore(cr);
    }

    /// `cairo_show_text` needs a NUL-terminated string; empty slices have no
    /// terminator to point at, so everything passes through a buffer.
    fn toCString(s: []const u8, buf: *[256:0]u8) [*c]const u8 {
        const n = @min(s.len, 255);
        @memcpy(buf[0..n], s[0..n]);
        buf[n] = 0;
        return buf;
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-search-bar: paints focused and unfilled, query and hint" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 320, 60);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var resting = SearchBar{};
    resting.setGeometry(4, 4, 300, 48);
    resting.setHint("Search apps");
    resting.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Focused adds the accent outline; a query replaces the hint.
    var active = SearchBar{};
    active.setGeometry(4, 4, 300, 48);
    active.setFocused(true);
    active.setText("wifi");
    active.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // No hint at all falls back to the hard-coded "Search".
    var bare = SearchBar{};
    bare.setGeometry(4, 4, 300, 48);
    bare.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Degenerate geometry paints nothing, so a null context is safe.
    var degenerate = SearchBar{};
    degenerate.setGeometry(0, 0, 0, 0);
    degenerate.paint(null);
}

test "m3-search-bar: hit testing and submit carry the query" {
    const t = testing;
    const S = struct {
        var last: [64]u8 = undefined;
        var len: usize = 0;
        var calls: usize = 0;
        fn onSubmit(ctx: ?*anyopaque, text: []const u8) void {
            _ = ctx;
            calls += 1;
            const n = @min(text.len, last.len);
            @memcpy(last[0..n], text[0..n]);
            len = n;
        }
    };
    S.calls = 0;
    S.len = 0;

    var bar = SearchBar{};
    bar.setGeometry(10, 10, 200, 48);
    bar.setText("volume");
    bar.setOnSubmit(S.onSubmit);

    try t.expect(bar.containsPoint(20, 20));
    try t.expect(!bar.containsPoint(5, 5));
    try t.expectEqual(@as(f32, 200.0), bar.width());

    bar.submit();
    try t.expectEqual(@as(usize, 1), S.calls);
    try t.expectEqualStrings("volume", S.last[0..S.len]);
}
