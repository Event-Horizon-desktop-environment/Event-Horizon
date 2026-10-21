//! The M3 text field.
//!
//! Two variants. `Filled` is a surface-tinted box with an indicator line along
//! its bottom edge that thickens when focused; `Outlined` is a full border
//! that thickens instead. Both go to the error colour when `invalid`.
//!
//! A leading icon shifts the text start right by `kIconSize + 8`, and a
//! trailing icon reserves room on the right. Helper text sits *below* the
//! field, and the optional character counter sits below that on the right —
//! neither is inside the 56dp box, which is why the counter is drawn at
//! `contentY + inputH + 4`.
//!
//! The caret is a straight vertical stroke placed by measuring the text and
//! appending its width — with no caret-position model, only
//! ever render a cursor at the end of the string.
//!
//! Text and icons go through pango via `m3/core/label.zig` and
//! `m3/core/glyph.zig`, unlike the FAB, which still uses cairo toy text.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const label_mod = @import("../../core/label.zig");
const glyph_mod = @import("../../core/glyph.zig");
const state_layer_mod = @import("../../core/primitives/state_layer.zig");

pub const Label = label_mod.Label;
pub const Glyph = glyph_mod.Glyph;
pub const FocusRing = state_layer_mod.FocusRing;

/// Text-sink as a function pointer plus context.
/// Zig form takes a borrowed slice, valid only for the duration of the call.
pub const TextCallback = *const fn (ctx: ?*anyopaque, text: []const u8) void;

/// M3 Text Field — Filled and Outlined variants, helper text, char counter,
/// leading/trailing icons.
pub const Input = struct {
    pub const Variant = enum {
        filled,
        outlined,
    };

    /// Field height, and horizontal padding inside it.
    pub const kHeight: f32 = 56.0;
    pub const kHPad: f32 = 16.0;
    pub const kIconSize: f32 = 24.0;
    /// Gap between a leading icon and the text.
    pub const kIconGap: f32 = 8.0;
    /// Corner radius for both variants.
    pub const kRadius: f32 = 4.0;
    /// Indicator/border widths, unfocused and focused.
    pub const kLineInactive: f32 = 1.0;
    pub const kLineActive: f32 = 2.0;

    /// The error colour, used for the line, border, helper text and caret
    /// whenever `invalid` is set.
    pub const kErrorR: f32 = 0.91;
    pub const kErrorG: f32 = 0.42;
    pub const kErrorB: f32 = 0.35;

    variant: Variant = .filled,
    enabled: bool = true,
    hovered: bool = false,
    focused: bool = false,
    invalid: bool = false,
    show_counter: bool = false,
    max_length: i32 = 0,

    text: []const u8 = "",
    placeholder: []const u8 = "",
    helper_text: []const u8 = "",
    leading_icon: []const u8 = "",
    trailing_icon: []const u8 = "",

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 56.0,

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

    focus_ring: FocusRing = .{},

    on_text_changed: ?TextCallback = null,
    on_activate: ?TextCallback = null,
    cb_ctx: ?*anyopaque = null,

    pub fn setText(self: *Input, t: []const u8) void {
        self.text = t;
    }

    pub fn setPlaceholder(self: *Input, p: []const u8) void {
        self.placeholder = p;
    }

    pub fn setHelperText(self: *Input, h: []const u8) void {
        self.helper_text = h;
    }

    pub fn setMaxLength(self: *Input, max: i32) void {
        self.max_length = max;
    }

    pub fn setShowCounter(self: *Input, s: bool) void {
        self.show_counter = s;
    }

    pub fn setVariant(self: *Input, v: Variant) void {
        self.variant = v;
    }

    pub fn setEnabled(self: *Input, e: bool) void {
        self.enabled = e;
    }

    pub fn setFocused(self: *Input, f: bool) void {
        self.focused = f;
    }

    pub fn setHovered(self: *Input, h: bool) void {
        self.hovered = h;
    }

    pub fn setInvalid(self: *Input, i: bool) void {
        self.invalid = i;
    }

    pub fn setLeadingIcon(self: *Input, name: []const u8) void {
        self.leading_icon = name;
    }

    pub fn setTrailingIcon(self: *Input, name: []const u8) void {
        self.trailing_icon = name;
    }

    pub fn setGeometry(self: *Input, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *Input, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *Input, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *Input, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *Input, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn setOnTextChanged(self: *Input, cb: ?TextCallback) void {
        self.on_text_changed = cb;
    }

    pub fn setOnActivate(self: *Input, cb: ?TextCallback) void {
        self.on_activate = cb;
    }

    pub fn setCallbackContext(self: *Input, ctx: ?*anyopaque) void {
        self.cb_ctx = ctx;
    }

    pub fn textOf(self: *const Input) []const u8 {
        return self.text;
    }

    pub fn isFocused(self: *const Input) bool {
        return self.focused;
    }

    pub fn isEnabled(self: *const Input) bool {
        return self.enabled;
    }

    pub fn containsPoint(self: *const Input, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    /// Non-animated paint — forwards to the timestamped overload at 0.
    pub fn paintStatic(self: *const Input, c: ?*cairo.cairo_t) void {
        // Reuses the mutating `paint` body via a const-cast.
        const mutable: *Input = @constCast(self);
        mutable.paint(c, 0);
    }

    pub fn paint(self: *Input, c: ?*cairo.cairo_t, now_ms: u64) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;
        const cr = c orelse return;
        const input_h = kHeight;
        const iy = self.y;

        // Content start shifts right past a leading icon.
        var content_x = self.x;

        if (self.variant == .filled) {
            content_x = self.drawFilled(cr);
        } else {
            content_x = self.drawOutlined(cr);
        }

        self.drawContent(cr, content_x, iy, self.w - (content_x - self.x) - kHPad);
        self.drawHelper(cr);

        // Focus ring — error-tinted when invalid, otherwise the accent.
        self.focus_ring.setFocused(self.focused);
        if (self.invalid) {
            self.focus_ring.setColor(kErrorR, kErrorG, kErrorB);
        } else {
            self.focus_ring.setColor(self.accent_r, self.accent_g, self.accent_b);
        }
        self.focus_ring.setRadius(kRadius);
        self.focus_ring.paint(cr, self.x, iy, self.w, input_h);
        _ = now_ms;
    }

    /// Filled variant: a surface-tinted body with rounded top corners only,
    /// plus a bottom indicator line. Returns the x where content should start.
    fn drawFilled(self: *Input, cr: ?*cairo.cairo_t) f32 {
        const input_h = kHeight;
        const active_h = kLineActive;
        const inactive_h = kLineInactive;
        const r = kRadius;

        const has_leading = self.leading_icon.len != 0;
        const out_cx = self.x + kHPad + (if (has_leading) kIconSize + kIconGap else 0);

        cairo.cairo_save(cr);

        // Container background, "filled" style — slightly lighter than the
        // surface. Note the 1.05 lift applied to the surface channels, and
        // that the path rounds only the *top* two corners: the bottom edge is
        // square because the indicator line runs along it.
        const bg_a: f32 = if (self.enabled) 1.0 else 0.38;
        cairo.cairo_set_source_rgba(
            cr,
            self.surface_r * 1.05,
            self.surface_g * 1.05,
            self.surface_b * 1.05,
            bg_a,
        );
        cairo.cairo_new_path(cr);
        cairo.cairo_arc(cr, self.x + r, self.y + r, r, std.math.pi, 1.5 * std.math.pi);
        cairo.cairo_arc(cr, self.x + self.w - r, self.y + r, r, 1.5 * std.math.pi, 2.0 * std.math.pi);
        cairo.cairo_line_to(cr, self.x + self.w, self.y + input_h);
        cairo.cairo_line_to(cr, self.x, self.y + input_h);
        cairo.cairo_close_path(cr);
        cairo.cairo_fill(cr);

        // Bottom indicator — error, then focused accent, then resting outline.
        var line_r: f32 = 0;
        var line_g: f32 = 0;
        var line_b: f32 = 0;
        if (self.invalid) {
            line_r = kErrorR;
            line_g = kErrorG;
            line_b = kErrorB;
        } else if (self.focused) {
            line_r = self.accent_r;
            line_g = self.accent_g;
            line_b = self.accent_b;
        } else {
            line_r = self.outline_r;
            line_g = self.outline_g;
            line_b = self.outline_b;
        }

        cairo.cairo_set_source_rgba(cr, line_r, line_g, line_b, if (self.enabled) 1.0 else 0.38);
        cairo.cairo_set_line_width(cr, if (self.focused) active_h else inactive_h);
        cairo.cairo_move_to(cr, self.x, self.y + input_h);
        cairo.cairo_line_to(cr, self.x + self.w, self.y + input_h);
        cairo.cairo_stroke(cr);

        cairo.cairo_restore(cr);
        return out_cx;
    }

    /// Outlined variant: a full rounded border, thickening when focused.
    /// Returns the x where content should start.
    fn drawOutlined(self: *Input, cr: ?*cairo.cairo_t) f32 {
        const input_h = kHeight;
        const r = kRadius;

        const has_leading = self.leading_icon.len != 0;
        const out_cx = self.x + kHPad + (if (has_leading) kIconSize + kIconGap else 0);

        cairo.cairo_save(cr);

        var border_r: f32 = 0;
        var border_g: f32 = 0;
        var border_b: f32 = 0;
        if (self.invalid) {
            border_r = kErrorR;
            border_g = kErrorG;
            border_b = kErrorB;
        } else if (self.focused) {
            border_r = self.accent_r;
            border_g = self.accent_g;
            border_b = self.accent_b;
        } else {
            border_r = self.outline_r;
            border_g = self.outline_g;
            border_b = self.outline_b;
        }

        const bw: f32 = if (self.focused) kLineActive else kLineInactive;
        cairo.cairo_set_source_rgba(cr, border_r, border_g, border_b, if (self.enabled) 1.0 else 0.38);
        cairo.cairo_set_line_width(cr, bw);

        // `r - bw * 0.5` insets the arcs so a 2dp border straddles the corner
        // instead of bulging outside it.
        cairo.cairo_new_path(cr);
        cairo.cairo_arc(cr, self.x + r, self.y + r, r - bw * 0.5, std.math.pi, 1.5 * std.math.pi);
        cairo.cairo_arc(cr, self.x + self.w - r, self.y + r, r - bw * 0.5, 1.5 * std.math.pi, 2.0 * std.math.pi);
        cairo.cairo_arc(cr, self.x + self.w - r, self.y + input_h - r, r - bw * 0.5, 0.0, 0.5 * std.math.pi);
        cairo.cairo_arc(cr, self.x + r, self.y + input_h - r, r - bw * 0.5, 0.5 * std.math.pi, std.math.pi);
        cairo.cairo_close_path(cr);
        cairo.cairo_stroke(cr);

        cairo.cairo_restore(cr);
        return out_cx;
    }

    fn drawContent(self: *const Input, c: ?*cairo.cairo_t, content_x: f32, content_y: f32, content_w: f32) void {
        const input_h = kHeight;
        const has_text = self.text.len != 0;

        // Leading icon, vertically centred in the field.
        if (self.leading_icon.len != 0) {
            var gl = Glyph{};
            gl.setGlyph(self.leading_icon);
            gl.setSize(kIconSize);
            gl.setColor(self.text_r, self.text_g, self.text_b, if (self.enabled) 0.6 else 0.38);
            gl.paintAt(c, self.x + kHPad, content_y + (input_h - kIconSize) * 0.5);
        }

        // Trailing icon (or the counter beneath it). `trailing_x` walks left
        // as each right-aligned element claims its width.
        var trailing_x = self.x + self.w - kHPad;

        if (self.trailing_icon.len != 0) {
            var gl = Glyph{};
            gl.setGlyph(self.trailing_icon);
            gl.setSize(kIconSize);
            gl.setColor(self.text_r, self.text_g, self.text_b, if (self.enabled) 0.6 else 0.38);
            gl.paintAt(c, trailing_x - kIconSize, content_y + (input_h - kIconSize) * 0.5);
            trailing_x -= kIconSize + 4.0;
        }

        // Char counter, drawn *below* the field.
        if (self.show_counter and self.max_length > 0) {
            var counter_buf: [32]u8 = undefined;
            const counter = std.fmt.bufPrint(
                &counter_buf,
                "{d}/{d}",
                .{ self.text.len, self.max_length },
            ) catch "";
            var lbl = Label{};
            lbl.setText(counter);
            lbl.setFontSize(12);
            lbl.setColor(self.text_r, self.text_g, self.text_b, 0.6);

            var cw: f32 = 0;
            var ch: f32 = 0;
            lbl.measureExtents(&cw, &ch);
            _ = content_w;
            lbl.paintAt(c, trailing_x - cw, content_y + input_h + 4.0);
        }

        // Text, or placeholder when empty, substituting a single space
        // for an empty placeholder so the layout still gets a line to draw.
        if (has_text) {
            var lbl = Label{};
            lbl.setText(self.text);
            lbl.setFontSize(16);
            lbl.setColor(self.text_r, self.text_g, self.text_b, if (self.enabled) 1.0 else 0.38);
            lbl.paintAt(c, content_x, content_y + (input_h - 20.0) * 0.5);
        } else {
            var lbl = Label{};
            lbl.setText(if (self.placeholder.len == 0) " " else self.placeholder);
            lbl.setFontSize(16);
            lbl.setColor(self.text_r, self.text_g, self.text_b, if (self.enabled) 0.4 else 0.2);
            lbl.paintAt(c, content_x, content_y + (input_h - 20.0) * 0.5);
        }

        // Caret — always at the end of the text, because there is no caret
        // position model to place it anywhere else.
        if (self.focused) {
            var cursor_x = content_x;
            if (has_text) {
                var lbl = Label{};
                lbl.setText(self.text);
                lbl.setFontSize(16);
                var tw: f32 = 0;
                var th: f32 = 0;
                lbl.measureExtents(&tw, &th);
                cursor_x += tw;
            }
            cairo.cairo_save(c);
            cairo.cairo_set_source_rgba(c, self.accent_r, self.accent_g, self.accent_b, 1.0);
            cairo.cairo_set_line_width(c, 1.5);
            cairo.cairo_move_to(c, cursor_x, content_y + 8.0);
            cairo.cairo_line_to(c, cursor_x, content_y + input_h - 8.0);
            cairo.cairo_stroke(c);
            cairo.cairo_restore(c);
        }
    }

    fn drawHelper(self: *const Input, c: ?*cairo.cairo_t) void {
        if (self.helper_text.len == 0) return;
        var lbl = Label{};
        lbl.setText(self.helper_text);
        lbl.setFontSize(12);
        // Error-tinted when invalid, at the same 60% the normal helper uses.
        lbl.setColor(
            if (self.invalid) kErrorR else self.text_r,
            if (self.invalid) kErrorG else self.text_g,
            if (self.invalid) kErrorB else self.text_b,
            0.6,
        );
        lbl.paintAt(c, self.x + kHPad, self.y + kHeight + 2.0);
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-input: both variants paint with icons, text and helper" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 320, 120);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    inline for (.{ .filled, .outlined }) |v| {
        var inp = Input{};
        inp.setVariant(v);
        inp.setGeometry(10, 10, 280, 56);
        inp.setText("Hello");
        inp.setLeadingIcon("search");
        inp.setTrailingIcon("close");
        inp.setHelperText("Helper");
        inp.setShowCounter(true);
        inp.setMaxLength(20);
        inp.setFocused(true);
        inp.paintStatic(cr);
        try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    }

    // Invalid goes to the error colour on the line, helper and caret.
    var bad = Input{};
    bad.setInvalid(true);
    bad.setGeometry(10, 10, 280, 56);
    bad.setHelperText("Bad value");
    bad.paintStatic(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Empty text with no placeholder — substituting a single space so
    // the branch is exercised rather than skipped.
    var bare = Input{};
    bare.setGeometry(10, 10, 280, 56);
    bare.setFocused(true);
    bare.paintStatic(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Disabled dims everything.
    var off = Input{};
    off.setEnabled(false);
    off.setGeometry(10, 10, 280, 56);
    off.setText("Disabled");
    off.paint(cr, 0);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Degenerate geometry paints nothing, so a null context is safe.
    var degenerate = Input{};
    degenerate.paintStatic(null);
    degenerate.paint(null, 0);
}

test "m3-input: hit testing and accessors" {
    const t = testing;
    var inp = Input{};
    inp.setGeometry(20, 20, 200, 56);
    inp.setText("typed");
    inp.setFocused(true);

    try t.expect(inp.containsPoint(30, 30));
    try t.expect(!inp.containsPoint(5, 5));
    try t.expectEqualStrings("typed", inp.textOf());
    try t.expect(inp.isFocused());
    try t.expect(inp.isEnabled());
}
