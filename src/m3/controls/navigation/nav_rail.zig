//! The M3 navigation rail: a 72dp
//! vertical bar of stacked destinations with an optional FAB slot on top.
//!
//! Each destination gets a 56dp row. The active one shows an accent pill
//! (56×32, 16% alpha), an accent icon lifted 4dp, and a 12pt label under it;
//! inactive destinations are icon-only. When `fab_visible` is set, a 56dp
//! accent circle with a "+" takes the top 72dp of the rail and pushes every
//! destination down by that plus a 12dp gap.
//!
//! Like `Tabs`, `handlePointerDown` always returns false — the rail does not
//! act on presses. `destAt` does the hit testing (y-based, and gated on
//! `containsPoint`), and `activateAt` is the one-line wiring for a caller.
//!
//! The FAB's "+" is drawn as two round-capped strokes — the rail carries no
//! icon-font dependency.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;

/// One destination. `label` and `icon` are borrowed slices.
pub const Destination = struct {
    label: []const u8 = "",
    icon: []const u8 = "",
    on_activate: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

/// M3 Navigation Rail — vertical bar, 72dp wide, stacked destinations + FAB slot.
pub const NavRail = struct {
    pub const kRailWidth: f32 = 72.0;
    /// Height of one destination row.
    pub const kDestHeight: f32 = 56.0;
    /// Top inset for the first destination, with and without the FAB slot.
    pub const kTopPad: f32 = 12.0;
    pub const kFabSize: f32 = 56.0;
    /// FAB slot height, and the gap beneath it.
    pub const kFabSlotHeight: f32 = 72.0;
    pub const kFabGap: f32 = 12.0;

    pub const kPillWidth: f32 = 56.0;
    pub const kPillHeight: f32 = 32.0;
    pub const kPillAlpha: f32 = 0.16;
    pub const kIconSize: f32 = 24.0;
    pub const kLabelFont: f32 = 12.0;
    pub const kLabelFromBottom: f32 = 6.0;
    pub const kActiveAlpha: f32 = 1.0;
    pub const kInactiveAlpha: f32 = 0.66;
    dests: []const Destination = &.{},
    active_idx: i32 = 0,
    fab_visible: bool = false,

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 72.0,
    h: f32 = 0.0,

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

    pub fn setDestinations(self: *NavRail, list: []const Destination) void {
        self.dests = list;
        self.setActiveIndex(self.active_idx);
    }

    pub fn setActiveIndex(self: *NavRail, i: i32) void {
        if (self.dests.len == 0) {
            self.active_idx = 0;
            return;
        }
        const last: i32 = @intCast(self.dests.len - 1);
        self.active_idx = std.math.clamp(i, 0, last);
    }

    pub fn setFabVisible(self: *NavRail, v: bool) void {
        self.fab_visible = v;
    }

    pub fn setGeometry(self: *NavRail, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *NavRail, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *NavRail, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *NavRail, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *NavRail, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn activeIndex(self: *const NavRail) i32 {
        return self.active_idx;
    }

    pub fn xPos(self: *const NavRail) f32 {
        return self.x;
    }

    pub fn yPos(self: *const NavRail) f32 {
        return self.y;
    }

    pub fn width(self: *const NavRail) f32 {
        return self.w;
    }

    pub fn height(self: *const NavRail) f32 {
        return self.h;
    }

    pub fn containsPoint(self: *const NavRail, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    /// Where the first destination row starts — the top pad, plus the FAB
    /// slot when it is showing.
    pub fn startY(self: *const NavRail) f32 {
        return self.y + (if (self.fab_visible) kFabSlotHeight + kFabGap else kTopPad);
    }

    /// The destination under a point, or -1. Unlike `NavBar`, this one *is*
    /// gated on `containsPoint`, and it maps y rather than x.
    pub fn destAt(self: *const NavRail, px: f32, py: f32) i32 {
        if (self.dests.len == 0 or !self.containsPoint(px, py)) return -1;
        const idx_f = (py - self.startY()) / kDestHeight;
        if (idx_f < 0) return -1;
        const idx: i32 = @intFromFloat(@trunc(idx_f));
        if (idx < 0 or idx >= @as(i32, @intCast(self.dests.len))) return -1;
        return idx;
    }

    /// Presses do nothing — both coordinates ignored.
    pub fn handlePointerDown(self: *NavRail, px: f32, py: f32) bool {
        _ = self;
        _ = px;
        _ = py;
        return false;
    }

    /// Selects the row under `(px, py)` and fires its
    /// `on_activate`.
    pub fn activateAt(self: *NavRail, px: f32, py: f32) bool {
        const idx = self.destAt(px, py);
        if (idx < 0) return false;
        self.setActiveIndex(idx);
        const d = self.dests[@intCast(idx)];
        if (d.on_activate) |cb| cb(d.ctx);
        return true;
    }

    pub fn paint(self: *const NavRail, c: ?*cairo.cairo_t) void {
        if (self.w <= 0.0 or self.h <= 0.0 or self.dests.len == 0) return;
        const cr = c orelse return;

        // The background is painted at `w_` wide, not a nominal 72 — the
        // constant only lives in the default geometry.
        const rail_w = self.w;
        const dest_h = kDestHeight;
        const icon_size = kIconSize;
        const pill_h = kPillHeight;
        const pill_r = pill_h * 0.5;
        const pill_w = kPillWidth;
        const start_y = self.startY();

        // Background.
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, self.surface_r, self.surface_g, self.surface_b, 1.0);
        cairo.cairo_rectangle(cr, self.x, self.y, rail_w, self.h);
        cairo.cairo_fill(cr);
        cairo.cairo_restore(cr);

        // FAB slot — an accent disc with a hand-drawn "+" (two round-capped
        // strokes; the rail spells no icon-font glyph).
        if (self.fab_visible) {
            const fab_d = kFabSize;
            const fab_x = self.x + (rail_w - fab_d) * 0.5;
            const fab_y = self.y + kTopPad;
            cairo.cairo_save(cr);
            cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, 1.0);
            cairo.cairo_arc(cr, fab_x + fab_d * 0.5, fab_y + fab_d * 0.5, fab_d * 0.5, 0.0, 2.0 * std.math.pi);
            cairo.cairo_fill(cr);
            const cx = fab_x + fab_d * 0.5;
            const cy = fab_y + fab_d * 0.5;
            const arm: f64 = 8.0;
            cairo.cairo_set_source_rgba(cr, 1, 1, 1, 1);
            cairo.cairo_set_line_width(cr, 2.0);
            cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
            cairo.cairo_move_to(cr, cx - arm, cy);
            cairo.cairo_line_to(cr, cx + arm, cy);
            cairo.cairo_move_to(cr, cx, cy - arm);
            cairo.cairo_line_to(cr, cx, cy + arm);
            cairo.cairo_stroke(cr);
            cairo.cairo_restore(cr);
        }

        // Destinations.
        for (self.dests, 0..) |dest, i| {
            const dy = start_y + @as(f32, @floatFromInt(i)) * dest_h;
            const active = @as(i32, @intCast(i)) == self.active_idx;

            // Active indicator pill.
            if (active) {
                const pill_x = self.x + (rail_w - pill_w) * 0.5;
                const pill_y = dy + (dest_h - pill_h) * 0.5;
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

            // Icon — centred, lifted 4dp when active.
            const icon_x = self.x + (rail_w - icon_size) * 0.5;
            const icon_y = dy + (dest_h - icon_size) * 0.5 - (if (active) @as(f32, 4.0) else 0.0);
            const ic_r: f32 = if (active) self.accent_r else self.text_r;
            const ic_g: f32 = if (active) self.accent_g else self.text_g;
            const ic_b: f32 = if (active) self.accent_b else self.text_b;
            const ic_a: f32 = if (active) kActiveAlpha else kInactiveAlpha;

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

            // Label — active destination only.
            if (active) {
                cairo.cairo_save(cr);
                cairo.cairo_select_font_face(
                    cr,
                    "Sans",
                    cairo.CAIRO_FONT_SLANT_NORMAL,
                    cairo.CAIRO_FONT_WEIGHT_NORMAL,
                );
                cairo.cairo_set_font_size(cr, kLabelFont);
                cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, kActiveAlpha);

                var label_buf: [256:0]u8 = undefined;
                const label = toCString(dest.label, &label_buf);

                var te: cairo.cairo_text_extents_t = undefined;
                cairo.cairo_text_extents(cr, label, &te);
                const lx = self.x + (rail_w - @as(f32, @floatCast(te.width))) * 0.5;
                const ly = dy + dest_h - kLabelFromBottom;
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
    .{ .label = "Radio", .icon = "radio" },
    .{ .label = "Lib", .icon = "library_music" },
};

test "m3-nav-rail: destAt is y-based and gated on the rail's own bounds" {
    const t = testing;
    var rail = NavRail{};
    rail.setDestinations(&kDests);
    rail.setGeometry(0, 0, 72, 400);

    // No FAB: rows start 12dp down, 56dp each.
    try t.expectEqual(@as(f32, 12.0), rail.startY());
    try t.expectEqual(@as(i32, 0), rail.destAt(36, 20));
    try t.expectEqual(@as(i32, 1), rail.destAt(36, 80));
    try t.expectEqual(@as(i32, 2), rail.destAt(36, 130));
    // Above the first row, past the last, or off the side: all -1.
    try t.expectEqual(@as(i32, -1), rail.destAt(36, 5));
    try t.expectEqual(@as(i32, -1), rail.destAt(36, 400));
    try t.expectEqual(@as(i32, -1), rail.destAt(500, 20));

    // The FAB slot pushes every row down by 72 + 12.
    rail.setFabVisible(true);
    try t.expectEqual(@as(f32, 84.0), rail.startY());
    try t.expectEqual(@as(i32, 0), rail.destAt(36, 90));
    // The same point that was row 0 without the slot is now above row 0.
    try t.expectEqual(@as(i32, -1), rail.destAt(36, 20));

    var empty = NavRail{};
    try t.expectEqual(@as(i32, -1), empty.destAt(36, 20));
}

test "m3-nav-rail: presses are ignored, activateAt selects and notifies" {
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
        .{ .label = "Radio", .icon = "radio", .on_activate = S.onActivate },
    };

    var rail = NavRail{};
    rail.setDestinations(&dests);
    rail.setGeometry(0, 0, 72, 400);

    try t.expect(!rail.handlePointerDown(36, 20));
    try t.expectEqual(@as(i32, 0), rail.activeIndex());
    try t.expectEqual(@as(usize, 0), S.activations);

    try t.expect(rail.activateAt(36, 80));
    try t.expectEqual(@as(i32, 1), rail.activeIndex());
    try t.expectEqual(@as(usize, 1), S.activations);

    // A point outside the rail selects nothing.
    try t.expect(!rail.activateAt(500, 80));
    try t.expectEqual(@as(usize, 1), S.activations);
}

test "m3-nav-rail: paints with and without the FAB slot" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 90, 420);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var bare = NavRail{};
    bare.setDestinations(&kDests);
    bare.setGeometry(4, 4, 72, 400);
    bare.setActiveIndex(1);
    bare.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    var with_fab = NavRail{};
    with_fab.setDestinations(&kDests);
    with_fab.setFabVisible(true);
    with_fab.setGeometry(4, 4, 72, 400);
    with_fab.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // No destinations: paint returns before touching the context.
    var empty = NavRail{};
    empty.setGeometry(4, 4, 72, 400);
    empty.paint(null);
    empty.paint(cr);
}

test "m3-nav-rail: setActiveIndex clamps into range" {
    const t = testing;
    var rail = NavRail{};
    rail.setDestinations(&kDests);
    rail.setActiveIndex(-1);
    try t.expectEqual(@as(i32, 0), rail.activeIndex());
    rail.setActiveIndex(10);
    try t.expectEqual(@as(i32, 2), rail.activeIndex());
}
