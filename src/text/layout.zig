const std = @import("std");
const cairo = @import("../wl/buffer/shm.zig").cairo;

pub const PangoLayout = opaque {};
pub const PangoFontDescription = opaque {};
pub const PangoAttrList = opaque {};

/// `PangoAttribute` has a public C layout, unlike the other pango types:
///
///     typedef struct _PangoAttribute {
///       const PangoAttrClass *klass;
///       guint start_index;
///       guint end_index;
///     } PangoAttribute;
///
/// It must be an extern struct (not `opaque`) because `Glyph` sets the index
/// range on a font-features attribute after creating it, and pango offers no
/// setter for those two fields.
pub const PangoAttribute = extern struct {
    klass: ?*const anyopaque,
    start_index: c_uint,
    end_index: c_uint,
};

// `PangoAlignment` / `PangoWrapMode` / `PangoWeight` values, which are plain
// enums in the headers.
pub const ALIGN_LEFT: c_int = 0;
pub const ALIGN_CENTER: c_int = 1;
pub const ALIGN_RIGHT: c_int = 2;
pub const WRAP_WORD: c_int = 0;
pub const WRAP_CHAR: c_int = 1;
pub const WRAP_WORD_CHAR: c_int = 2;

/// `PangoEllipsizeMode` — `END` truncates and appends "…" when the layout is
/// too wide for its set width, which is how the picker card titles/descriptions
/// are kept inside their column.
pub const ELLIPSIZE_NONE: c_int = 0;
pub const ELLIPSIZE_START: c_int = 1;
pub const ELLIPSIZE_MIDDLE: c_int = 2;
pub const ELLIPSIZE_END: c_int = 3;
pub const WEIGHT_NORMAL: c_uint = 400;
pub const WEIGHT_BOLD: c_uint = 700;
pub const WEIGHT_SEMIBOLD: c_uint = 600;

pub extern fn pango_cairo_create_layout(cr: ?*cairo.cairo_t) ?*PangoLayout;
pub extern fn pango_layout_set_text(layout: ?*PangoLayout, text: [*c]const u8, length: c_int) void;
pub extern fn pango_layout_get_pixel_size(layout: ?*PangoLayout, width: ?*c_int, height: ?*c_int) void;
pub extern fn pango_cairo_show_layout(cr: ?*cairo.cairo_t, layout: ?*PangoLayout) void;
extern fn pango_font_description_from_string(str: [*c]const u8) ?*PangoFontDescription;
pub extern fn pango_font_description_free(desc: ?*PangoFontDescription) void;
pub extern fn pango_layout_set_font_description(layout: ?*PangoLayout, desc: ?*const PangoFontDescription) void;
pub extern fn g_object_unref(object: ?*anyopaque) void;

// Font-description constructors and mutators. `Label` and `Glyph` build a
// description out of a `FontConfig` (family + size + weight separately) rather
// than parsing a pango description string, so they drive these directly.
pub extern fn pango_font_description_new() ?*PangoFontDescription;
pub extern fn pango_font_description_set_family(desc: ?*PangoFontDescription, family: [*c]const u8) void;
pub extern fn pango_font_description_set_size(desc: ?*PangoFontDescription, size: c_int) void;
pub extern fn pango_font_description_set_weight(desc: ?*PangoFontDescription, weight: c_uint) void;
/// Absolute size in *device* units, bypassing the DPI scale. The glyph font
/// uses this so an icon is exactly N px regardless of display scaling.
pub extern fn pango_font_description_set_absolute_size(desc: ?*PangoFontDescription, size: f64) void;
/// Selects an OpenType feature by tag — `Glyph` asks for `liga` so the ligature
/// that turns a name like `close` into a single icon renders.
pub extern fn pango_attr_font_features_new(features: [*c]const u8) ?*PangoAttribute;

/// Pango's unit scale: one pixel is 1024 font units, so sizes and widths must
/// be multiplied by this before handing them to pango.
pub const PANGO_SCALE: f64 = 1024.0;
/// `G_MAXUINT` — the sentinel end index meaning "apply to the rest of the
/// string". Used for whole-layout attribute ranges.
pub const G_MAXUINT: c_uint = 0xFFFFFFFF;

/// The rest are `pub` because the widget paints drive pango directly: they
/// cache a layout across frames, weight the clock's first line, and wrap
/// media titles, none of which the `Layout` wrapper models.
pub extern fn pango_cairo_update_layout(cr: ?*cairo.cairo_t, layout: ?*PangoLayout) void;
pub extern fn pango_layout_set_alignment(layout: ?*PangoLayout, alignment: c_int) void;
pub extern fn pango_layout_set_wrap(layout: ?*PangoLayout, wrap: c_int) void;
pub extern fn pango_layout_set_width(layout: ?*PangoLayout, width: c_int) void;
pub extern fn pango_layout_set_ellipsize(layout: ?*PangoLayout, mode: c_int) void;
pub extern fn pango_layout_set_attributes(layout: ?*PangoLayout, attrs: ?*PangoAttrList) void;
/// Single-paragraph mode: the dialog painter keeps each row on one line and
/// lets ellipsize handle overflow.
pub extern fn pango_layout_set_single_paragraph_mode(layout: ?*PangoLayout, setting: c_int) void;
/// `pango_layout_set_height` uses pango's negative convention: -N caps the
/// layout at N lines (the message/details rows).
pub extern fn pango_layout_set_height(layout: ?*PangoLayout, height: c_int) void;
pub extern fn pango_attr_list_new() ?*PangoAttrList;
pub extern fn pango_attr_list_unref(list: ?*PangoAttrList) void;
pub extern fn pango_attr_list_insert(list: ?*PangoAttrList, attr: ?*PangoAttribute) void;
pub extern fn pango_attr_weight_new(weight: c_uint) ?*PangoAttribute;
pub extern fn pango_layout_get_line_count(layout: ?*PangoLayout) c_int;
/// Baseline distance from the layout's top edge, in pango units.
pub extern fn pango_layout_get_baseline(layout: ?*PangoLayout) c_int;

/// Ink extents for the two-line row-block math in the Bluetooth popup paint
/// (reading `pango_layout_get_pixel_extents`, not the logical size).
pub const PangoRectangle = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};
pub extern fn pango_layout_get_pixel_extents(
    layout: ?*PangoLayout,
    ink_rect: ?*PangoRectangle,
    logical_rect: ?*PangoRectangle,
) void;
pub const PANGO_SCALE_INT: c_int = 1024;

pub const Layout = struct {
    layout: ?*PangoLayout = null,

    pub fn createForCairo(cr: ?*cairo.cairo_t) Layout {
        var l = Layout{};
        if (cr) |c| {
            l.layout = pango_cairo_create_layout(c);
        }
        return l;
    }

    pub fn destroy(self: *Layout) void {
        if (self.layout) |lo| {
            g_object_unref(lo);
            self.layout = null;
        }
    }

    pub fn setText(self: *Layout, text: []const u8) void {
        if (self.layout) |lo| {
            var zbuf: [1024:0]u8 = [_:0]u8{0} ** 1024;
            const n = @min(text.len, 1023);
            @memcpy(zbuf[0..n], text[0..n]);
            pango_layout_set_text(lo, &zbuf, @intCast(n));
        }
    }

    pub fn setFont(self: *Layout, desc: []const u8) void {
        if (self.layout) |lo| {
            var zbuf: [256:0]u8 = [_:0]u8{0} ** 256;
            const n = @min(desc.len, 255);
            @memcpy(zbuf[0..n], desc[0..n]);
            const fd = pango_font_description_from_string(&zbuf);
            if (fd != null) {
                pango_layout_set_font_description(lo, fd);
                pango_font_description_free(fd);
            }
        }
    }

    pub fn pixelSize(self: *Layout) struct { w: i32, h: i32 } {
        if (self.layout) |lo| {
            var w: c_int = 0;
            var h: c_int = 0;
            pango_layout_get_pixel_size(lo, &w, &h);
            return .{ .w = w, .h = h };
        }
        return .{ .w = 0, .h = 0 };
    }

    /// Ink extents of the drawn glyphs — the box that is actually painted,
    /// unlike `pixelSize`'s logical line box. Callers use this to center
    /// text optically inside pills and chips.
    pub fn pixelInk(self: *Layout) PangoRectangle {
        if (self.layout) |lo| {
            var ink = PangoRectangle{ .x = 0, .y = 0, .width = 0, .height = 0 };
            pango_layout_get_pixel_extents(lo, &ink, null);
            return ink;
        }
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    pub fn show(self: *Layout, cr: ?*cairo.cairo_t) void {
        if (self.layout) |lo| {
            if (cr) |c| pango_cairo_show_layout(c, lo);
        }
    }

    /// `pango_cairo_update_layout` — re-reads the cairo transform before the
    /// layout is measured or shown again. Cached layouts need this after the
    /// caller has moved or scaled the context.
    pub fn update(self: *Layout, cr: ?*cairo.cairo_t) void {
        if (self.layout) |lo| {
            if (cr) |c| pango_cairo_update_layout(c, lo);
        }
    }

    pub fn setAlignment(self: *Layout, alignment: c_int) void {
        if (self.layout) |lo| pango_layout_set_alignment(lo, alignment);
    }

    pub fn setWrap(self: *Layout, wrap: c_int) void {
        if (self.layout) |lo| pango_layout_set_wrap(lo, wrap);
    }

    /// `pango_layout_set_width` in Pango units (1024 per pixel); a negative
    /// width means "no wrapping", which is pango's default.
    pub fn setWidthUnits(self: *Layout, units: c_int) void {
        if (self.layout) |lo| pango_layout_set_width(lo, units);
    }

    /// `pango_layout_set_ellipsize` — pass `ELLIPSIZE_END` to truncate with an
    /// ellipsis when the text exceeds the layout's set width.
    pub fn setEllipsize(self: *Layout, mode: c_int) void {
        if (self.layout) |lo| pango_layout_set_ellipsize(lo, mode);
    }

    /// Keep the whole layout on one line (newlines are still honoured).
    pub fn setSingleParagraph(self: *Layout, on: bool) void {
        if (self.layout) |lo| pango_layout_set_single_paragraph_mode(lo, if (on) 1 else 0);
    }

    /// Cap the layout at `lines` lines; pango's negative-height convention.
    pub fn setMaxLines(self: *Layout, lines: u32) void {
        if (self.layout) |lo| pango_layout_set_height(lo, -@as(c_int, @intCast(lines)));
    }

    /// Applies a single font-weight attribute to the whole layout. Passing
    /// `null` clears the attribute list, which is how the clock switches its
    /// first line back to normal weight.
    pub fn setWeight(self: *Layout, weight: ?c_uint) void {
        if (self.layout) |lo| {
            if (weight) |w| {
                const attrs = pango_attr_list_new() orelse return;
                defer pango_attr_list_unref(attrs);
                if (pango_attr_weight_new(w)) |attr| pango_attr_list_insert(attrs, attr);
                pango_layout_set_attributes(lo, attrs);
            } else {
                pango_layout_set_attributes(lo, null);
            }
        }
    }

    pub fn lineCount(self: *Layout) c_int {
        if (self.layout) |lo| return pango_layout_get_line_count(lo);
        return 0;
    }

    /// Applies a whole-layout font-features attribute, e.g. `tnum 1` for
    /// tabular numerals. Like `setWeight` this replaces the attribute list,
    /// so bake weights into the font description when both are needed.
    pub fn setFontFeatures(self: *Layout, features: []const u8) void {
        if (self.layout) |lo| {
            var zbuf: [128:0]u8 = [_:0]u8{0} ** 128;
            const n = @min(features.len, 127);
            @memcpy(zbuf[0..n], features[0..n]);
            const attrs = pango_attr_list_new() orelse return;
            defer pango_attr_list_unref(attrs);
            if (pango_attr_font_features_new(&zbuf)) |attr| pango_attr_list_insert(attrs, attr);
            pango_layout_set_attributes(lo, attrs);
        }
    }

    /// Baseline of the first line, in pixels from the layout's top edge.
    pub fn baseline(self: *Layout) f64 {
        if (self.layout) |lo| {
            return @as(f64, @floatFromInt(pango_layout_get_baseline(lo))) / PANGO_SCALE;
        }
        return 0;
    }

    /// Frees the underlying layout without touching the struct, for caches
    /// that own a layout across frames.
    pub fn release(layout: ?*PangoLayout) void {
        if (layout) |lo| g_object_unref(lo);
    }
};

test "text: null-safe layout ops" {
    const t = std.testing;
    var l = Layout.createForCairo(null);
    defer l.destroy();
    l.setText("hello");
    l.setFont("Inter 12");
    const s = l.pixelSize();
    try t.expectEqual(@as(i32, 0), s.w);
    l.show(null);
}
