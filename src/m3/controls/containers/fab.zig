//! The floating action button.
//!
//! Four sizes, all circular. A FAB is drawn *about its own centre*: the box it
//! was given is only used to find that centre, and the circle is laid out from
//! the size's diameter, not the box's. An extended FAB widens into a pill and
//! places its icon left of centre with a label beside it.
//!
//! The FAB draws its icon and label through **cairo toy text**, not pango —
//! `cairo_select_font_face("Symbols Nerd Font")` for the glyph and
//! `cairo_select_font_face("Sans")` for the label. That differs from `Button`,
//! which goes through `m3/core/glyph.zig` and `m3/core/label.zig`, and is
//! faithful: the FAB predates the pango-based text layer and still calls
//! `cairo_show_text` directly.
//!
//! `lowered_` inverts the palette: the container becomes the surface colour
//! instead of the accent, and the icon/label/state layer take the surface's
//! text colour. It is the "flat, resting" look — no accent, no shadow.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const box_mod = @import("../../core/primitives/box.zig");
const state_layer_mod = @import("../../core/primitives/state_layer.zig");

pub const Box = box_mod.Box;
pub const StateLayer = state_layer_mod.StateLayer;
pub const FocusRing = state_layer_mod.FocusRing;

pub const Callback = *const fn (ctx: ?*anyopaque) void;

/// M3 FAB — Standard, Small, Large, Extended.
pub const FAB = struct {
    pub const Size = enum {
        small,
        standard,
        large,
        extended,
    };

    /// Nominal diameter, icon diameter, label font size and shadow depth per
    /// size, resolved with a table.
    /// keeps the four values side by side.
    pub const kSizeD = [_]f32{ 40.0, 56.0, 96.0, 56.0 };
    pub const kSizeIcon = [_]f32{ 24.0, 24.0, 36.0, 24.0 };
    pub const kSizeFont = [_]f32{ 14.0, 14.0, 14.0, 14.0 };
    pub const kSizeElevation = [_]f32{ 4.0, 6.0, 6.0, 6.0 };

    size: Size = .standard,
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    lowered: bool = false,

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 56.0,
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

    icon: []const u8 = "",
    label: []const u8 = "",

    state_layer: StateLayer = .{},
    focus_ring: FocusRing = .{},

    on_click: ?Callback = null,
    cb_ctx: ?*anyopaque = null,

    pub fn setSize(self: *FAB, s: Size) void {
        self.size = s;
    }

    pub fn setGeometry(self: *FAB, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *FAB, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *FAB, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *FAB, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *FAB, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn setIcon(self: *FAB, ic: []const u8) void {
        self.icon = ic;
    }

    pub fn setLabel(self: *FAB, l: []const u8) void {
        self.label = l;
    }

    pub fn setHovered(self: *FAB, h: bool) void {
        self.hovered = h;
    }

    pub fn setPressed(self: *FAB, p: bool) void {
        self.pressed = p;
    }

    pub fn setFocused(self: *FAB, f: bool) void {
        self.focused = f;
    }

    /// The flat, resting look: surface container, no accent, no shadow.
    pub fn setLowered(self: *FAB, l: bool) void {
        self.lowered = l;
    }

    pub fn setOnClick(self: *FAB, cb: ?Callback) void {
        self.on_click = cb;
    }

    pub fn setCallbackContext(self: *FAB, ctx: ?*anyopaque) void {
        self.cb_ctx = ctx;
    }

    pub fn xPos(self: *const FAB) f32 {
        return self.x;
    }

    pub fn yPos(self: *const FAB) f32 {
        return self.y;
    }

    pub fn width(self: *const FAB) f32 {
        return self.w;
    }

    pub fn height(self: *const FAB) f32 {
        return self.h;
    }

    pub fn containsPoint(self: *const FAB, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    pub fn handlePointerEnter(self: *FAB, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        self.hovered = true;
        return true;
    }

    pub fn handlePointerLeave(self: *FAB) bool {
        self.hovered = false;
        self.pressed = false;
        return true;
    }

    pub fn handlePointerDown(self: *FAB, px: f32, py: f32) bool {
        if (!self.containsPoint(px, py)) return false;
        self.pressed = true;
        return true;
    }

    pub fn handlePointerUp(self: *FAB, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (self.pressed) {
            self.pressed = false;
            if (self.on_click) |cb| cb(self.cb_ctx);
        }
        return true;
    }

    pub fn paint(self: *FAB, c: ?*cairo.cairo_t) void {
        if (self.w <= 0.0 or self.h <= 0.0) return;
        const cr = c orelse return;

        const i: usize = @intFromEnum(self.size);
        const d = kSizeD[i];
        const icon_s = kSizeIcon[i];
        const font_s = kSizeFont[i];
        const elevation = kSizeElevation[i];

        const ext = self.size == .extended;
        const r = d * 0.5;
        const cx = self.x + self.w * 0.5;
        const cy = self.y + self.h * 0.5;

        cairo.cairo_save(cr);

        // Shadow — a solid circle offset down by half the elevation depth.
        if (!self.lowered) {
            cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0.12);
            cairo.cairo_arc(cr, cx + 1, cy + elevation * 0.5, r, 0.0, 2.0 * std.math.pi);
            cairo.cairo_fill(cr);
        }

        // Container — Box at the exact circular radius so the glassy rim
        // conforms to the circle rather than a rounded square.
        {
            var bg_box = Box{};
            if (self.lowered) {
                bg_box.setColor(self.surface_r, self.surface_g, self.surface_b, 1.0);
            } else {
                bg_box.setColor(self.accent_r, self.accent_g, self.accent_b, 1.0);
            }
            bg_box.setRadius(r);
            bg_box.setGeometry(cx - r, cy - r, d, d);
            bg_box.setGlassy(true);
            bg_box.paint(c);
        }

        cairo.cairo_restore(cr);

        // Icon — toy text in "Symbols Nerd Font". On an extended FAB the icon
        // shifts left of centre to make room for the label.
        if (self.icon.len != 0) {
            cairo.cairo_save(cr);
            cairo.cairo_select_font_face(
                cr,
                "Symbols Nerd Font",
                cairo.CAIRO_FONT_SLANT_NORMAL,
                cairo.CAIRO_FONT_WEIGHT_NORMAL,
            );
            cairo.cairo_set_font_size(cr, icon_s);
            if (self.lowered) {
                cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, 1.0);
            } else {
                cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0);
            }
            const ix: f32 = if (ext) cx - d * 0.3 else cx;
            cairo.cairo_move_to(cr, ix - icon_s * 0.3, cy + icon_s * 0.3);
            var icon_buf: [256:0]u8 = undefined;
            cairo.cairo_show_text(cr, toCString(self.icon, &icon_buf));
            cairo.cairo_restore(cr);
        }

        // Label (extended only) — drawn at `cx + 0.15d`, nudged down by a
        // third of the text height so it sits on the optical centre line.
        if (ext and self.label.len != 0) {
            cairo.cairo_save(cr);
            cairo.cairo_select_font_face(
                cr,
                "Sans",
                cairo.CAIRO_FONT_SLANT_NORMAL,
                cairo.CAIRO_FONT_WEIGHT_NORMAL,
            );
            cairo.cairo_set_font_size(cr, font_s);
            if (self.lowered) {
                cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, 1.0);
            } else {
                cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0);
            }
            var te: cairo.cairo_text_extents_t = undefined;
            var label_buf: [256:0]u8 = undefined;
            const label_z = toCString(self.label, &label_buf);
            cairo.cairo_text_extents(cr, label_z, &te);
            cairo.cairo_move_to(cr, cx + d * 0.15, cy + te.height * 0.35);
            cairo.cairo_show_text(cr, label_z);
            cairo.cairo_restore(cr);
        }

        // State layer — tinted white, or the text colour when lowered.
        if (self.lowered) {
            self.state_layer.setColor(self.text_r, self.text_g, self.text_b);
        } else {
            self.state_layer.setColor(1.0, 1.0, 1.0);
        }
        self.state_layer.setRadius(r);
        self.state_layer.setGeometry(cx - r, cy - r, d, d);
        self.state_layer.setHovered(self.hovered);
        self.state_layer.setPressed(self.pressed);
        self.state_layer.setFocused(self.focused);
        self.state_layer.tick(0);
        self.state_layer.paint(c, 0);

        // Focus ring — a ring around the circle with 4dp of breathing room, so
        // it does not sit on the accent edge.
        self.focus_ring.setFocused(self.focused);
        self.focus_ring.setColor(self.outline_r, self.outline_g, self.outline_b);
        self.focus_ring.setRadius(r + 4.0);
        self.focus_ring.paint(c, cx - r - 4.0, cy - r - 4.0, d + 8.0, d + 8.0);
    }

    /// `cairo_show_text` needs a NUL-terminated C string, which a `[]const u8`
    /// is not guaranteed to be. FAB text is always a literal, but copy into the
    /// caller's stack buffer so a slice that runs on cannot be read past its
    /// end. The buffer is a parameter rather than a file-scope static so the
    /// call stays re-entrant.
    fn toCString(s: []const u8, buf: *[256:0]u8) [*c]const u8 {
        const n = @min(s.len, 255);
        @memcpy(buf[0..n], s[0..n]);
        buf[n] = 0;
        return buf;
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-fab: size table drives diameter, icon and elevation" {
    const t = testing;
    var fab = FAB{};
    fab.setSize(.small);
    try t.expectEqual(@as(f32, 40.0), FAB.kSizeD[@intFromEnum(fab.size)]);
    try t.expectEqual(@as(f32, 4.0), FAB.kSizeElevation[@intFromEnum(fab.size)]);
    fab.setSize(.large);
    try t.expectEqual(@as(f32, 96.0), FAB.kSizeD[@intFromEnum(fab.size)]);
    try t.expectEqual(@as(f32, 36.0), FAB.kSizeIcon[@intFromEnum(fab.size)]);
}

test "m3-fab: paints centred, for every size and lowered state" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 200, 200);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    inline for (.{ .small, .standard, .large, .extended }) |s| {
        var fab = FAB{};
        fab.setSize(s);
        fab.setGeometry(20, 20, 120, 120);
        fab.setIcon("edit");
        fab.setLabel("Compose");
        fab.paint(cr);
        try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    }

    // Lowered inverts the palette but must still paint cleanly.
    var low = FAB{};
    low.setLowered(true);
    low.setGeometry(20, 20, 120, 120);
    low.setIcon("edit");
    low.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}

test "m3-fab: press then release fires the click" {
    const t = testing;
    const S = struct {
        var clicks: usize = 0;
        fn onClick(_: ?*anyopaque) void {
            clicks += 1;
        }
    };
    S.clicks = 0;

    var fab = FAB{};
    fab.setGeometry(0, 0, 56, 56);
    fab.setOnClick(S.onClick);

    // A miss arms nothing.
    try t.expect(!fab.handlePointerDown(200, 200));
    _ = fab.handlePointerUp(28, 28);
    try t.expectEqual(@as(usize, 0), S.clicks);

    try t.expect(fab.handlePointerDown(28, 28));
    _ = fab.handlePointerUp(28, 28);
    try t.expectEqual(@as(usize, 1), S.clicks);
}

test "m3-fab: degenerate geometry paints nothing and is null-safe" {
    var fab = FAB{};
    fab.setGeometry(0, 0, 0, 0);
    fab.paint(null);
}
