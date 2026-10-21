//! A horizontal snap-scrolling strip
//! of cards with a page-indicator row.
//!
//! The carousel does not own a scroll offset; it owns a *count* and an
//! *active index*, and derives everything from that:
//!
//!   * Each card is `w * 0.7` by `h * 0.85` at a 12dp radius, with a 12dp
//!     gap between neighbours. Cards are laid out in a row centred on the
//!     *active* card, so the active one sits at `x + w/2` and the rest
//!     march off either side.
//!   * Only cards whose box still overlaps `[x, x+w]` are drawn — the row is
//!     clipped to the carousel's bounds as well, so a card can be half in
//!     and half out.
//!   * The active card is full size and opaque; every other card scales to
//!     90% about its own centre and drops to 70% surface alpha.
//!   * Below the row, `count` 4dp dots on 12dp centres are centred across
//!     the carousel at `y + h - 12`. The active dot is the accent colour at
//!     full alpha; the rest are the text colour at 38%.
//!
//! `set_active_index` clamps into `[0, count - 1]`. When the count is 0 it
//! returns early with 0 instead of clamping into an empty range.
//!
//! The card pass does `cairo_reset_clip` immediately before `cairo_restore`,
//! so the bounds clip is cleared twice over — harmless, and kept so the two
//! stay comparable. Note the dots are drawn *after* the restore, so they are
//! deliberately outside that clip.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;

/// M3 Carousel — horizontal scrollable container with snap points.
pub const Carousel = struct {
    /// Card size as a fraction of the carousel's own width and height.
    pub const kItemWFrac: f32 = 0.7;
    pub const kItemHFrac: f32 = 0.85;
    /// Card corner radius, and the gap between neighbours.
    pub const kItemRadius: f32 = 12.0;
    pub const kGap: f32 = 12.0;
    /// Inactive cards shrink about their centre by this factor.
    pub const kInactiveScale: f32 = 0.9;
    /// Inactive cards draw at this surface alpha.
    pub const kInactiveAlpha: f32 = 0.7;
    /// Indicator dots: radius, centre spacing, and baseline from the bottom.
    pub const kDotRadius: f32 = 4.0;
    pub const kDotGap: f32 = 12.0;
    pub const kDotsFromBottom: f32 = 12.0;
    pub const kInactiveDotAlpha: f32 = 0.38;

    count: i32 = 0,
    active_idx: i32 = 0,

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 200.0,

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

    pub fn setItemCount(self: *Carousel, n: i32) void {
        self.count = @max(n, 0);
    }

    /// Clamps into `[0, count - 1]`; with no items it leaves 0 in place
    /// rather than clamping into an empty range.
    pub fn setActiveIndex(self: *Carousel, i: i32) void {
        if (self.count <= 0) {
            self.active_idx = 0;
            return;
        }
        self.active_idx = std.math.clamp(i, 0, self.count - 1);
    }

    pub fn setGeometry(self: *Carousel, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *Carousel, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *Carousel, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *Carousel, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *Carousel, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn itemCount(self: *const Carousel) i32 {
        return self.count;
    }

    pub fn activeIndex(self: *const Carousel) i32 {
        return self.active_idx;
    }

    /// Hit test — the only sensible reading of "does a
    /// point fall on this carousel" given the bounds `paint` clips to.
    pub fn containsPoint(self: *const Carousel, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    /// The card width and height at full (active) scale.
    pub fn itemWidth(self: *const Carousel) f32 {
        return self.w * kItemWFrac;
    }

    pub fn itemHeight(self: *const Carousel) f32 {
        return self.h * kItemHFrac;
    }

    /// Where a card's box starts, before its own inactive shrink. `i` is
    /// clamped by the caller's loop, so an out-of-range index just lands off
    /// the row — the same arithmetic done inline in `paint`.
    pub fn itemX(self: *const Carousel, i: i32) f32 {
        const offset = @as(f32, @floatFromInt(i - self.active_idx)) * (self.itemWidth() + kGap);
        return self.x + self.w * 0.5 + offset - self.itemWidth() * 0.5;
    }

    /// True when the card's box still overlaps the carousel's horizontal run.
    /// `itemVisible` is what `paint`'s own culling check spells out.
    pub fn itemVisible(self: *const Carousel, i: i32) bool {
        const ix = self.itemX(i);
        const iw = self.itemWidth();
        return !(ix + iw < self.x or ix > self.x + self.w);
    }

    pub fn paint(self: *const Carousel, c: ?*cairo.cairo_t) void {
        if (self.w <= 0.0 or self.h <= 0.0 or self.count <= 0) return;
        const cr = c orelse return;

        const item_w = self.itemWidth();
        const item_h = self.itemHeight();

        // ——— Cards, clipped to the carousel's own bounds. ———
        cairo.cairo_save(cr);
        cairo.cairo_rectangle(cr, self.x, self.y, self.w, self.h);
        cairo.cairo_clip(cr);

        for (0..@as(usize, @intCast(self.count))) |raw| {
            const i: i32 = @intCast(raw);
            const ix = self.itemX(i);

            // Only draw visible items.
            if (ix + item_w < self.x or ix > self.x + self.w) continue;

            const active = i == self.active_idx;
            const scale: f32 = if (active) 1.0 else kInactiveScale;
            const sw = item_w * scale;
            const sh = item_h * scale;
            const sx = ix + (item_w - sw) * 0.5;
            const sy = self.y + (self.h - sh) * 0.5;
            const sr = kItemRadius * scale;

            cairo.cairo_set_source_rgba(
                cr,
                self.surface_r,
                self.surface_g,
                self.surface_b,
                if (active) 1.0 else kInactiveAlpha,
            );
            cairo.cairo_new_path(cr);
            cairo.cairo_arc(cr, sx + sr, sy + sr, sr, std.math.pi, 1.5 * std.math.pi);
            cairo.cairo_arc(cr, sx + sw - sr, sy + sr, sr, 1.5 * std.math.pi, 2.0 * std.math.pi);
            cairo.cairo_arc(cr, sx + sw - sr, sy + sh - sr, sr, 0.0, 0.5 * std.math.pi);
            cairo.cairo_arc(cr, sx + sr, sy + sh - sr, sr, 0.5 * std.math.pi, std.math.pi);
            cairo.cairo_close_path(cr);
            cairo.cairo_fill(cr);
        }

        // The clip is cleared twice — once explicitly, once by the restore
        // that also ends the outer save, and
        // why the dots below are not clipped.
        cairo.cairo_reset_clip(cr);
        cairo.cairo_restore(cr);

        // ——— Page indicator dots. ———
        const dot_r = kDotRadius;
        const dots_w = @as(f32, @floatFromInt(self.count - 1)) * kDotGap;
        const dots_x = self.x + (self.w - dots_w) * 0.5;
        const dots_y = self.y + self.h - kDotsFromBottom;

        for (0..@as(usize, @intCast(self.count))) |raw| {
            const active = @as(i32, @intCast(raw)) == self.active_idx;
            cairo.cairo_save(cr);
            if (active) {
                cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, 1.0);
            } else {
                cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, kInactiveDotAlpha);
            }
            cairo.cairo_new_path(cr);
            cairo.cairo_arc(cr, dots_x + @as(f32, @floatFromInt(raw)) * kDotGap, dots_y, dot_r, 0.0, 2.0 * std.math.pi);
            cairo.cairo_fill(cr);
            cairo.cairo_restore(cr);
        }
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-carousel: setItemCount floors at zero, and the index clamps" {
    const t = testing;
    var c = Carousel{};

    c.setItemCount(-5);
    try t.expectEqual(@as(i32, 0), c.itemCount());
    try t.expectEqual(@as(i32, 0), c.activeIndex());

    c.setItemCount(4);
    try t.expectEqual(@as(i32, 4), c.itemCount());
    c.setActiveIndex(-1);
    try t.expectEqual(@as(i32, 0), c.activeIndex());
    c.setActiveIndex(99);
    try t.expectEqual(@as(i32, 3), c.activeIndex());
    c.setActiveIndex(2);
    try t.expectEqual(@as(i32, 2), c.activeIndex());

    // Empty carousel keeps 0 instead of clamping into an empty range.
    var empty = Carousel{};
    empty.setActiveIndex(1);
    try t.expectEqual(@as(i32, 0), empty.activeIndex());
}

test "m3-carousel: cards are centred on the active one and clipped by bounds" {
    const t = testing;
    var c = Carousel{};
    c.setItemCount(5);
    c.setGeometry(0, 0, 200, 100);

    const item_w = c.itemWidth(); // 140
    const item_h = c.itemHeight(); // 85
    try t.expectApproxEqAbs(@as(f32, 140.0), item_w, 1e-4);
    try t.expectApproxEqAbs(@as(f32, 85.0), item_h, 1e-4);

    // With the middle card active, the card is centred on x + w/2 = 100:
    // 100 - 70 = 30.
    c.setActiveIndex(2);
    try t.expectApproxEqAbs(@as(f32, 30.0), c.itemX(2), 1e-4);
    // Neighbours step by 140 + 12 = 152.
    try t.expectApproxEqAbs(@as(f32, 30.0 - 152.0), c.itemX(1), 1e-4);
    try t.expectApproxEqAbs(@as(f32, 30.0 + 152.0), c.itemX(3), 1e-4);

    // Cards whose box still overlaps [0, 200] draw; the rest are culled.
    // index 0: x = -274, right edge -134 → entirely left of the bounds.
    try t.expectEqual(@as(f32, -274.0), c.itemX(0));
    try t.expect(!c.itemVisible(0));
    // index 1: x = -122, right edge 18 → 18px of it still shows.
    try t.expectEqual(@as(f32, -122.0), c.itemX(1));
    try t.expect(c.itemVisible(1));
    try t.expect(c.itemVisible(2));
    try t.expect(c.itemVisible(3)); // x = 182, 18px inside the right edge
    // index 4: x = 334 → entirely right of the bounds.
    try t.expectEqual(@as(f32, 334.0), c.itemX(4));
    try t.expect(!c.itemVisible(4));
}

test "m3-carousel: paints for several counts, and paints nothing when empty" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 320, 120);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    for ([_]i32{ 1, 2, 3, 8 }) |n| {
        var c = Carousel{};
        c.setItemCount(n);
        c.setActiveIndex(n - 1);
        c.setGeometry(4, 4, 300, 48);
        c.paint(cr);
        try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    }

    // Nothing to draw: paint returns before touching the context.
    var empty = Carousel{};
    empty.setGeometry(4, 4, 300, 48);
    empty.paint(null);
    empty.paint(cr);

    var degenerate = Carousel{};
    degenerate.setItemCount(3);
    degenerate.setGeometry(0, 0, 0, 48);
    degenerate.paint(cr);
}
