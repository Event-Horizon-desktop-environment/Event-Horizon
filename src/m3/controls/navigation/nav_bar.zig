//! The M3 navigation bar, 3–5
//! destinations with an active indicator pill.
//!
//! Each destination is a segment of the bar. The active one gets an accent
//! pill 24dp narrower than its segment at 16% alpha, its icon shifts up 4dp
//! and takes the accent colour at full alpha, and its label is always drawn.
//! Inactive labels only appear when there are at most 3 destinations
//! (`n <= 3.5`) — beyond that the bar is icon-only for everything but the
//! selection.
//!
//! Two notes on faithfulness:
//!
//!   * Three parallel vectors in `setDestinations` —
//!     `indicators_` (StateLayer), `labels_` (Label) and `icons_` (Glyph) —
//!     and never reads any of them. `paint` draws with cairo toy text
//!     directly. The vectors are therefore not ported: they have no
//!     observable effect, and carrying them would mean allocating three
//!     arrays per destination for dead storage. This is the one structural
//!     omission in this file.
//!   * `handlePointerDown`/`handlePointerUp` only track a press flag; they
//!     never select a destination. Selection is `setActiveIndex`'s job, or
//!     `activateAt` below.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;

/// One destination. `label` and `icon` are borrowed slices.
pub const Destination = struct {
    label: []const u8 = "",
    /// Glyph icon name.
    icon: []const u8 = "",
    on_activate: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

/// M3 Navigation Bar — 3–5 destinations, active indicator pill, icon + label.
pub const NavBar = struct {
    pub const kPillHeight: f32 = 32.0;
    /// Horizontal inset of the pill inside its segment, on each side.
    pub const kPillInset: f32 = 24.0;
    pub const kPillTop: f32 = 8.0;
    pub const kPillAlpha: f32 = 0.16;
    pub const kIconSize: f32 = 24.0;
    /// Icon top edge shift when active versus resting.
    pub const kIconActiveY: f32 = 6.0;
    pub const kIconRestY: f32 = 10.0;
    /// Label cap height, and its baseline offset from the bar's bottom.
    pub const kLabelH: f32 = 12.0;
    pub const kLabelFromBottom: f32 = 14.0;
    pub const kActiveAlpha: f32 = 1.0;
    pub const kInactiveAlpha: f32 = 0.66;
    /// Above this many destinations the inactive labels disappear.
    pub const kLabelCountLimit: f32 = 3.5;

    dests: []const Destination = &.{},
    active_idx: i32 = 0,
    hovered: bool = false,
    pressed: bool = false,

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 80.0,

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

    pub fn setDestinations(self: *NavBar, list: []const Destination) void {
        self.dests = list;
        self.setActiveIndex(self.active_idx);
    }

    /// Clamps into `[0, dests.len - 1]`; an empty list leaves 0 in place.
    pub fn setActiveIndex(self: *NavBar, i: i32) void {
        if (self.dests.len == 0) {
            self.active_idx = 0;
            return;
        }
        const last: i32 = @intCast(self.dests.len - 1);
        self.active_idx = std.math.clamp(i, 0, last);
    }

    pub fn setGeometry(self: *NavBar, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *NavBar, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *NavBar, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *NavBar, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *NavBar, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn setHovered(self: *NavBar, h: bool) void {
        self.hovered = h;
    }

    pub fn setPressed(self: *NavBar, p: bool) void {
        self.pressed = p;
    }

    pub fn activeIndex(self: *const NavBar) i32 {
        return self.active_idx;
    }

    pub fn xPos(self: *const NavBar) f32 {
        return self.x;
    }

    pub fn yPos(self: *const NavBar) f32 {
        return self.y;
    }

    pub fn width(self: *const NavBar) f32 {
        return self.w;
    }

    pub fn height(self: *const NavBar) f32 {
        return self.h;
    }

    pub fn containsPoint(self: *const NavBar, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    /// The destination under a point, or -1. The y coordinate is ignored.
    pub fn destAt(self: *const NavBar, px: f32, py: f32) i32 {
        _ = py;
        if (self.dests.len == 0) return -1;
        const seg_w = self.w / @as(f32, @floatFromInt(self.dests.len));
        const idx_f = (px - self.x) / seg_w;
        if (idx_f < 0) return -1;
        const idx: i32 = @intFromFloat(@trunc(idx_f));
        if (idx < 0 or idx >= @as(i32, @intCast(self.dests.len))) return -1;
        return idx;
    }

    pub fn handlePointerDown(self: *NavBar, px: f32, py: f32) bool {
        if (!self.containsPoint(px, py)) return false;
        self.pressed = true;
        return true;
    }

    pub fn handlePointerUp(self: *NavBar, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.pressed) return false;
        self.pressed = false;
        return true;
    }

    /// Selects the segment under `px` and fires its
    /// `on_activate`, so a caller can wire a press in one call.
    pub fn activateAt(self: *NavBar, px: f32, py: f32) bool {
        const idx = self.destAt(px, py);
        if (idx < 0) return false;
        self.setActiveIndex(idx);
        const d = self.dests[@intCast(idx)];
        if (d.on_activate) |cb| cb(d.ctx);
        return true;
    }

    pub fn paint(self: *const NavBar, c: ?*cairo.cairo_t) void {
        if (self.w <= 0.0 or self.h <= 0.0 or self.dests.len == 0) return;
        const cr = c orelse return;

        const n: f32 = @floatFromInt(self.dests.len);
        const seg_w = self.w / n;
        const pill_h = kPillHeight;
        const pill_r = pill_h * 0.5;
        const icon_size = kIconSize;
        const label_h = kLabelH;

        // Background.
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, self.surface_r, self.surface_g, self.surface_b, 1.0);
        cairo.cairo_rectangle(cr, self.x, self.y, self.w, self.h);
        cairo.cairo_fill(cr);
        cairo.cairo_restore(cr);

        for (self.dests, 0..) |dest, i| {
            const seg_x = self.x + @as(f32, @floatFromInt(i)) * seg_w;
            const active = @as(i32, @intCast(i)) == self.active_idx;

            // Active indicator pill — 16% accent, inset 12dp each side.
            if (active) {
                const pill_w: f32 = seg_w - kPillInset;
                const pill_x = seg_x + (seg_w - pill_w) * 0.5;
                const pill_y = self.y + kPillTop;
                cairo.cairo_save(cr);
                cairo.cairo_new_path(cr);
                cairo.cairo_arc(cr, pill_x + pill_r, pill_y + pill_r, pill_r, std.math.pi, 1.5 * std.math.pi);
                cairo.cairo_arc(cr, pill_x + pill_w - pill_r, pill_y + pill_r, pill_r, 1.5 * std.math.pi, 2.0 * std.math.pi);
                cairo.cairo_arc(cr, pill_x + pill_w - pill_r, pill_y + pill_h - pill_r, pill_r, 0.0, 0.5 * std.math.pi);
                cairo.cairo_arc(cr, pill_x + pill_r, pill_y + pill_h - pill_r, pill_r, 0.5 * std.math.pi, std.math.pi);
                cairo.cairo_close_path(cr);
                cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, kPillAlpha);
                cairo.cairo_fill(cr);
                cairo.cairo_restore(cr);
            }

            // Icon — accented and lifted 4dp when active.
            const icon_x = seg_x + (seg_w - icon_size) * 0.5;
            const icon_y = self.y + (if (active) kIconActiveY else kIconRestY);
            const ic_r: f32 = if (active) self.accent_r else self.text_r;
            const ic_g: f32 = if (active) self.accent_g else self.text_g;
            const ic_b: f32 = if (active) self.accent_b else self.text_b;
            const ic_a: f32 = if (active) kActiveAlpha else kInactiveAlpha;

            if (dest.icon.len != 0) {
                cairo.cairo_save(cr);
                cairo.cairo_select_font_face(
                    cr,
                    "Symbols Nerd Font",
                    cairo.CAIRO_FONT_SLANT_NORMAL,
                    cairo.CAIRO_FONT_WEIGHT_NORMAL,
                );
                cairo.cairo_set_font_size(cr, icon_size);
                cairo.cairo_set_source_rgba(cr, ic_r, ic_g, ic_b, ic_a);
                cairo.cairo_move_to(cr, icon_x, icon_y + icon_size * 0.75);
                var icon_buf: [256:0]u8 = undefined;
                cairo.cairo_show_text(cr, toCString(dest.icon, &icon_buf));
                cairo.cairo_restore(cr);
            }

            // Label — always when active, otherwise only in a bar of at most
            // three destinations.
            if (active or n <= kLabelCountLimit) {
                cairo.cairo_save(cr);
                cairo.cairo_select_font_face(
                    cr,
                    "Sans",
                    cairo.CAIRO_FONT_SLANT_NORMAL,
                    cairo.CAIRO_FONT_WEIGHT_NORMAL,
                );
                cairo.cairo_set_font_size(cr, label_h);
                cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, if (active) kActiveAlpha else kInactiveAlpha);

                var label_buf: [256:0]u8 = undefined;
                const label = toCString(dest.label, &label_buf);

                var te: cairo.cairo_text_extents_t = undefined;
                cairo.cairo_text_extents(cr, label, &te);
                const lx = seg_x + (seg_w - @as(f32, @floatCast(te.width))) * 0.5;
                const ly = self.y + self.h - kLabelFromBottom;
                cairo.cairo_move_to(cr, lx, ly);
                cairo.cairo_show_text(cr, label);
                cairo.cairo_restore(cr);
            }
        }
    }

    fn toCString(s: []const u8, buf: *[256:0]u8) [*c]const u8 {
        const n = @min(s.len, 255);
        @memcpy(buf[0..n], s[0..n]);
        buf[n] = 0;
        return buf;
    }
};

// ————— tests —————

const testing = std.testing;

const kDests = [_]Destination{
    .{ .label = "Home", .icon = "home" },
    .{ .label = "Search", .icon = "search" },
    .{ .label = "Lib", .icon = "library_music" },
    .{ .label = "You", .icon = "person" },
    .{ .label = "More", .icon = "more_horiz" },
};

test "m3-nav-bar: destAt divides the bar into equal segments" {
    const t = testing;
    var bar = NavBar{};
    bar.setDestinations(&kDests);
    bar.setGeometry(0, 0, 500, 80);

    // 500 / 5 = 100dp segments; y is deliberately ignored.
    try t.expectEqual(@as(i32, 0), bar.destAt(10, -999));
    try t.expectEqual(@as(i32, 3), bar.destAt(350, 0));
    try t.expectEqual(@as(i32, 4), bar.destAt(499, 0));
    try t.expectEqual(@as(i32, -1), bar.destAt(-1, 0));
    try t.expectEqual(@as(i32, -1), bar.destAt(501, 0));

    var empty = NavBar{};
    try t.expectEqual(@as(i32, -1), empty.destAt(50, 0));
}

test "m3-nav-bar: press tracks, and activateAt selects and notifies" {
    const t = testing;
    const S = struct {
        var activations: usize = 0;
        fn onActivate(ctx: ?*anyopaque) void {
            _ = ctx;
            activations += 1;
        }
    };
    S.activations = 0;

    var dests = [_]Destination{
        .{ .label = "Home", .icon = "home", .on_activate = S.onActivate },
        .{ .label = "Search", .icon = "search", .on_activate = S.onActivate },
    };

    var bar = NavBar{};
    bar.setDestinations(&dests);
    bar.setGeometry(0, 0, 200, 80);

    // A press outside arms nothing.
    try t.expect(!bar.handlePointerDown(500, 500));
    try t.expect(!bar.handlePointerUp(500, 500));
    try t.expect(!bar.pressed);

    // Inside arms it; release disarms and reports true.
    try t.expect(bar.handlePointerDown(50, 20));
    try t.expect(bar.pressed);
    try t.expect(bar.handlePointerUp(50, 20));
    try t.expect(!bar.pressed);

    // Selection itself is `activateAt`'s job.
    try t.expectEqual(@as(i32, 0), bar.activeIndex());
    try t.expect(bar.activateAt(150, 20));
    try t.expectEqual(@as(i32, 1), bar.activeIndex());
    try t.expectEqual(@as(usize, 1), S.activations);
}

test "m3-nav-bar: setActiveIndex clamps into range" {
    const t = testing;
    var bar = NavBar{};
    bar.setDestinations(&kDests);
    bar.setActiveIndex(-2);
    try t.expectEqual(@as(i32, 0), bar.activeIndex());
    bar.setActiveIndex(99);
    try t.expectEqual(@as(i32, 4), bar.activeIndex());

    var empty = NavBar{};
    empty.setActiveIndex(3);
    try t.expectEqual(@as(i32, 0), empty.activeIndex());
}

test "m3-nav-bar: paints five destinations with the active one selected" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 520, 90);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var bar = NavBar{};
    bar.setDestinations(&kDests);
    bar.setGeometry(4, 4, 500, 80);
    bar.setActiveIndex(2);
    bar.setHovered(true);
    bar.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Three or fewer destinations: the inactive labels draw too.
    var short = NavBar{};
    short.setDestinations(kDests[0..3]);
    short.setGeometry(4, 4, 300, 80);
    short.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // No destinations: paint returns before touching the context.
    var empty = NavBar{};
    empty.setGeometry(4, 4, 300, 80);
    empty.paint(null);
    empty.paint(cr);
}
