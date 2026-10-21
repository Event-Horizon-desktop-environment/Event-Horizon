//! M3 navigation drawer, in
//! its Modal (scrim + slide) and Standard (inline) forms.
//!
//! The drawer's width is `min(drawerW, sw * 0.85)` and then
//! `max(drawerW, 280)`, applied *inside `paint`*. Two consequences worth
//! knowing when reading this:
//!
//!   * `paint` mutates `drawer_w`. The clamps are latched on the first frame
//!     and then sticky: once it has been pushed up to 280 on a narrow screen,
//!     widening the geometry later will not shrink it back, because `min`
//!     runs first and `max` afterwards.
//!   * With `sw * 0.85 < 280` the two clamps disagree and `max` wins, so the
//!     drawer ends up wider than the 85% the first line asked for. Both order
//!     and outcome are preserved.
//!
//! `anim_offset` is `0` when open and `-drawer_w` when closed — a hard
//! snap, not an eased slide, despite the name. Because it reads `drawer_w`,
//! it reflects whatever the last `paint` clamped it to.
//!
//! `itemAt` carries a final guard, `py - listY - idx * itemH > itemH`, which
//! can never be true: `idx` is the truncated quotient, so the remainder is in
//! `[0, itemH)`. It is ported verbatim so the two stay comparable.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;

/// One drawer item. `icon` and `label` are borrowed slices.
pub const Item = struct {
    icon: []const u8 = "",
    label: []const u8 = "",
    on_activate: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

/// M3 Navigation Drawer — Modal (scrim + slide) or Standard (inline).
pub const NavDrawer = struct {
    pub const kDefaultDrawerW: f32 = 360.0;
    /// Width is clamped to at most 85% of the geometry, but never below this.
    pub const kMinDrawerW: f32 = 280.0;
    pub const kWidthFraction: f32 = 0.85;

    pub const kItemHeight: f32 = 48.0;
    /// List top padding inside the drawer.
    pub const kListTop: f32 = 24.0;
    pub const kIconSize: f32 = 24.0;
    /// Icon and label x offsets from the drawer's left edge.
    pub const kIconX: f32 = 28.0;
    pub const kLabelX: f32 = 72.0;
    pub const kLabelFont: f32 = 14.0;
    /// Active-item indicator inset and radius.
    pub const kIndicatorInset: f32 = 8.0;
    pub const kIndicatorVInset: f32 = 4.0;
    pub const kIndicatorRadius: f32 = 12.0;
    pub const kIndicatorAlpha: f32 = 0.16;
    pub const kActiveIconAlpha: f32 = 1.0;
    pub const kInactiveIconAlpha: f32 = 0.66;
    pub const kActiveLabelAlpha: f32 = 0.93;
    pub const kInactiveLabelAlpha: f32 = 0.66;
    /// Modal scrim colour and alpha, and the right-edge shadow width.
    pub const kScrimR: f32 = 0.071;
    pub const kScrimG: f32 = 0.047;
    pub const kScrimB: f32 = 0.149;
    pub const kScrimAlpha: f32 = 0.32;
    pub const kEdgeShadowW: f32 = 2.0;

    items: []const Item = &.{},
    active_idx: i32 = 0,
    modal: bool = true,
    open: bool = false,

    /// The geometry is the *scrim* bounds, not the drawer's — hence the `s`
    /// prefix (scrim, not drawer).
    sx: f32 = 0.0,
    sy: f32 = 0.0,
    sw: f32 = 0.0,
    sh: f32 = 0.0,
    drawer_w: f32 = kDefaultDrawerW,
    drawer_h: f32 = 0.0,

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

    pub fn setItems(self: *NavDrawer, list: []const Item) void {
        self.items = list;
        self.setActiveIndex(self.active_idx);
    }

    pub fn setActiveIndex(self: *NavDrawer, i: i32) void {
        if (self.items.len == 0) {
            self.active_idx = 0;
            return;
        }
        const last: i32 = @intCast(self.items.len - 1);
        self.active_idx = std.math.clamp(i, 0, last);
    }

    pub fn setModal(self: *NavDrawer, m: bool) void {
        self.modal = m;
    }

    pub fn setOpen(self: *NavDrawer, o: bool) void {
        self.open = o;
    }

    pub fn setGeometry(self: *NavDrawer, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.sx = gx;
        self.sy = gy;
        self.sw = gw;
        self.sh = gh;
    }

    pub fn setAccentColor(self: *NavDrawer, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *NavDrawer, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *NavDrawer, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *NavDrawer, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn isOpen(self: *const NavDrawer) bool {
        return self.open;
    }

    pub fn isModal(self: *const NavDrawer) bool {
        return self.modal;
    }

    /// The slide offset: flush at `sx` when open, one drawer-width off to the
    /// left when closed. A snap, not an ease.
    pub fn animOffset(self: *const NavDrawer) f32 {
        return if (self.open) 0.0 else -self.drawer_w;
    }

    /// The drawer's left edge in screen coordinates.
    pub fn drawerX(self: *const NavDrawer) f32 {
        return self.sx + self.animOffset();
    }

    /// The item under a point, or -1. Closed, outside the drawer, or above
    /// the list: all -1.
    pub fn itemAt(self: *const NavDrawer, px: f32, py: f32) i32 {
        if (!self.open) return -1;
        const dx = self.drawerX();
        const list_y = self.sy + kListTop;
        if (px < dx or px > dx + self.drawer_w or py < list_y) return -1;
        const idx_f = (py - list_y) / kItemHeight;
        if (idx_f < 0) return -1;
        const idx: i32 = @intFromFloat(@trunc(idx_f));
        if (idx < 0 or idx >= @as(i32, @intCast(self.items.len))) return -1;
        // The remainder is always < itemH.
        if (py - list_y - @as(f32, @floatFromInt(idx)) * kItemHeight > kItemHeight) return -1;
        return idx;
    }

    /// True when a point is inside the geometry but *outside* the drawer —
    /// i.e. it would dismiss a modal drawer. Only modal drawers have a scrim.
    pub fn hitScrim(self: *const NavDrawer, px: f32, py: f32) bool {
        if (!self.open or !self.modal) return false;
        const dx = self.drawerX();
        const in_geom = px >= self.sx and px < self.sx + self.sw and py >= self.sy and py < self.sy + self.sh;
        return in_geom and (px < dx or px > dx + self.drawer_w);
    }

    /// Presses do nothing — both coordinates ignored. Dismissal is
    /// `hitScrim`'s caller's job.
    pub fn handlePointerDown(self: *NavDrawer, px: f32, py: f32) bool {
        _ = self;
        _ = px;
        _ = py;
        return false;
    }

    /// Selects the row under the point and fires its
    /// `on_activate`.
    pub fn activateAt(self: *NavDrawer, px: f32, py: f32) bool {
        const idx = self.itemAt(px, py);
        if (idx < 0) return false;
        self.setActiveIndex(idx);
        const it = self.items[@intCast(idx)];
        if (it.on_activate) |cb| cb(it.ctx);
        return true;
    }

    /// Note this takes `*NavDrawer`, not `*const` — the width clamps mutate
    /// `drawer_w`.
    pub fn paint(self: *NavDrawer, c: ?*cairo.cairo_t) void {
        if (!self.open or self.sw <= 0.0) return;
        const cr = c orelse return;

        // Latched clamps — see the module note on why the order matters.
        self.drawer_w = @min(self.drawer_w, self.sw * kWidthFraction);
        self.drawer_w = @max(self.drawer_w, kMinDrawerW);
        self.drawer_h = self.sh;

        const dx = self.drawerX();
        const item_h = kItemHeight;
        const icon_size = kIconSize;

        // Scrim (modal only).
        if (self.modal) {
            cairo.cairo_save(cr);
            cairo.cairo_set_source_rgba(cr, kScrimR, kScrimG, kScrimB, kScrimAlpha);
            cairo.cairo_rectangle(cr, self.sx, self.sy, self.sw, self.sh);
            cairo.cairo_fill(cr);
            cairo.cairo_restore(cr);
        }

        // Drawer surface, plus its right-edge shadow when modal.
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, self.surface_r, self.surface_g, self.surface_b, 1.0);
        cairo.cairo_rectangle(cr, dx, self.sy, self.drawer_w, self.drawer_h);
        cairo.cairo_fill(cr);

        if (self.modal) {
            cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0.08);
            cairo.cairo_rectangle(cr, dx + self.drawer_w - kEdgeShadowW, self.sy, kEdgeShadowW, self.drawer_h);
            cairo.cairo_fill(cr);
        }
        cairo.cairo_restore(cr);

        // Items.
        for (self.items, 0..) |item, i| {
            const iy = self.sy + kListTop + @as(f32, @floatFromInt(i)) * item_h;
            const active = @as(i32, @intCast(i)) == self.active_idx;

            // Active indicator — a 12dp-radius rounded rect inset 8dp
            // horizontally and 4dp vertically.
            if (active) {
                cairo.cairo_save(cr);
                const rr = kIndicatorRadius;
                const ix = dx + kIndicatorInset;
                const iy0 = iy + kIndicatorVInset;
                const iw = self.drawer_w - kIndicatorInset * 2.0;
                const ih = item_h - kIndicatorVInset * 2.0;
                cairo.cairo_new_path(cr);
                cairo.cairo_arc(cr, ix + rr, iy0 + rr, rr, std.math.pi, 1.5 * std.math.pi);
                cairo.cairo_arc(cr, ix + iw - rr, iy0 + rr, rr, 1.5 * std.math.pi, 2.0 * std.math.pi);
                cairo.cairo_arc(cr, ix + iw - rr, iy0 + ih - rr, rr, 0.0, 0.5 * std.math.pi);
                cairo.cairo_arc(cr, ix + rr, iy0 + ih - rr, rr, 0.5 * std.math.pi, std.math.pi);
                cairo.cairo_close_path(cr);
                cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, kIndicatorAlpha);
                cairo.cairo_fill(cr);
                cairo.cairo_restore(cr);
            }

            // Icon.
            cairo.cairo_save(cr);
            cairo.cairo_select_font_face(
                cr,
                "Symbols Nerd Font",
                cairo.CAIRO_FONT_SLANT_NORMAL,
                cairo.CAIRO_FONT_WEIGHT_NORMAL,
            );
            cairo.cairo_set_font_size(cr, icon_size);
            const ic_r: f32 = if (active) self.accent_r else self.text_r;
            const ic_g: f32 = if (active) self.accent_g else self.text_g;
            const ic_b: f32 = if (active) self.accent_b else self.text_b;
            cairo.cairo_set_source_rgba(cr, ic_r, ic_g, ic_b, if (active) kActiveIconAlpha else kInactiveIconAlpha);
            cairo.cairo_move_to(cr, dx + kIconX, iy + item_h * 0.5 + icon_size * 0.3);
            var icon_buf: [256:0]u8 = undefined;
            cairo.cairo_show_text(cr, toCString(item.icon, &icon_buf));
            cairo.cairo_restore(cr);

            // Label.
            cairo.cairo_save(cr);
            cairo.cairo_select_font_face(
                cr,
                "Sans",
                cairo.CAIRO_FONT_SLANT_NORMAL,
                cairo.CAIRO_FONT_WEIGHT_NORMAL,
            );
            cairo.cairo_set_font_size(cr, kLabelFont);
            cairo.cairo_set_source_rgba(
                cr,
                self.text_r,
                self.text_g,
                self.text_b,
                if (active) kActiveLabelAlpha else kInactiveLabelAlpha,
            );
            cairo.cairo_move_to(cr, dx + kLabelX, iy + item_h * 0.5 + 5);
            var label_buf: [256:0]u8 = undefined;
            cairo.cairo_show_text(cr, toCString(item.label, &label_buf));
            cairo.cairo_restore(cr);
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

const kItems = [_]Item{
    .{ .icon = "home", .label = "Home" },
    .{ .icon = "search", .label = "Search" },
    .{ .icon = "settings", .label = "Settings" },
    .{ .icon = "person", .label = "Profile" },
};

test "m3-nav-drawer: anim offset snaps and follows the clamped width" {
    const t = testing;
    var d = NavDrawer{};
    d.setItems(&kItems);
    d.setGeometry(0, 0, 1200, 800);

    // Before any paint the width is still the default 360.
    try t.expect(!d.isOpen());
    try t.expectEqual(@as(f32, -360.0), d.animOffset());
    d.setOpen(true);
    try t.expectEqual(@as(f32, 0.0), d.animOffset());
    try t.expectEqual(@as(f32, 0.0), d.drawerX());
}

test "m3-nav-drawer: paint latches the width clamps, and they are sticky" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 500, 400);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var d = NavDrawer{};
    d.setItems(&kItems);
    d.setOpen(true);
    // 500 * 0.85 = 425, which is wider than the 360 default, so `min` keeps
    // the default and `max` leaves it alone.
    d.setGeometry(0, 0, 500, 400);
    d.paint(cr);
    try t.expectEqual(@as(f32, 360.0), d.drawer_w);

    // A geometry narrower than 360 / 0.85 does pull it down to 85%.
    var medium = NavDrawer{};
    medium.setItems(&kItems);
    medium.setOpen(true);
    medium.setGeometry(0, 0, 400, 400);
    medium.paint(cr);
    try t.expectEqual(@as(f32, 340.0), medium.drawer_w);

    // Narrow geometry: min gives 120*0.85 = 102, but max pulls it back to
    // 280 — the floor wins, so the drawer exceeds the 85% the first clamp
    // asked for. This is the disagreement noted in the module header.
    var narrow = NavDrawer{};
    narrow.setItems(&kItems);
    narrow.setOpen(true);
    narrow.setGeometry(0, 0, 120, 400);
    narrow.paint(cr);
    try t.expectEqual(@as(f32, 280.0), narrow.drawer_w);

    // …and it stays there once the geometry widens again: `min` runs on the
    // already-latched value, so nothing ever pulls it back down.
    narrow.setGeometry(0, 0, 2000, 400);
    narrow.paint(cr);
    try t.expectEqual(@as(f32, 280.0), narrow.drawer_w);

    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}

test "m3-nav-drawer: itemAt maps rows, and hitScrim catches the outside" {
    const t = testing;
    var d = NavDrawer{};
    d.setItems(&kItems);
    d.setOpen(true);
    d.setGeometry(0, 0, 800, 600);

    // `paint(null)` bails before the width clamps run, so the drawer is still
    // the 360 default — which is what the row math below assumes.
    d.paint(null);
    try t.expectEqual(@as(f32, 360.0), d.drawer_w);

    // Rows start 24dp down, 48dp each, inside that 360dp drawer.
    try t.expectEqual(@as(i32, 0), d.itemAt(100, 30));
    try t.expectEqual(@as(i32, 1), d.itemAt(100, 90));
    try t.expectEqual(@as(i32, 3), d.itemAt(100, 180));
    // Past the last item, above the list, or to the right of the drawer.
    try t.expectEqual(@as(i32, -1), d.itemAt(100, 300));
    try t.expectEqual(@as(i32, -1), d.itemAt(100, 10));
    try t.expectEqual(@as(i32, -1), d.itemAt(500, 30));

    // The scrim is everything in the geometry that is not the drawer, and
    // only while modal and open.
    try t.expect(d.hitScrim(600, 300));
    try t.expect(!d.hitScrim(100, 300));
    d.setModal(false);
    try t.expect(!d.hitScrim(600, 300));
    d.setModal(true);
    d.setOpen(false);
    try t.expect(!d.hitScrim(600, 300));
    // Closed, nothing is hit-testable at all.
    try t.expectEqual(@as(i32, -1), d.itemAt(100, 30));
}

test "m3-nav-drawer: a press is ignored, activateAt selects and notifies" {
    const t = testing;
    const S = struct {
        var activations: usize = 0;
        fn onActivate(ctx: ?*anyopaque) void {
            _ = ctx;
            activations += 1;
        }
    };
    S.activations = 0;

    var items = [_]Item{
        .{ .icon = "home", .label = "Home", .on_activate = S.onActivate },
        .{ .icon = "settings", .label = "Settings", .on_activate = S.onActivate },
    };

    var d = NavDrawer{};
    d.setItems(&items);
    d.setOpen(true);
    d.setGeometry(0, 0, 800, 600);

    try t.expect(!d.handlePointerDown(100, 30));
    try t.expectEqual(@as(i32, 0), d.active_idx);
    try t.expectEqual(@as(usize, 0), S.activations);

    try t.expect(d.activateAt(100, 90));
    try t.expectEqual(@as(i32, 1), d.active_idx);
    try t.expectEqual(@as(usize, 1), S.activations);
}

test "m3-nav-drawer: paints modal and standard, open, with items" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 500, 400);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    inline for (.{ true, false }) |modal| {
        var d = NavDrawer{};
        d.setItems(&kItems);
        d.setModal(modal);
        d.setOpen(true);
        d.setGeometry(0, 0, 480, 380);
        d.setActiveIndex(2);
        d.paint(cr);
        try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    }

    // Closed drawers paint nothing at all.
    var shut = NavDrawer{};
    shut.setItems(&kItems);
    shut.setOpen(false);
    shut.setGeometry(0, 0, 480, 380);
    shut.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Zero-width geometry paints nothing, so a null context is safe.
    var degenerate = NavDrawer{};
    degenerate.setOpen(true);
    degenerate.paint(null);
    degenerate.paint(cr);
}

test "m3-nav-drawer: setActiveIndex clamps into range" {
    const t = testing;
    var d = NavDrawer{};
    d.setItems(&kItems);
    d.setActiveIndex(-3);
    try t.expectEqual(@as(i32, 0), d.active_idx);
    d.setActiveIndex(99);
    try t.expectEqual(@as(i32, 3), d.active_idx);

    var empty = NavDrawer{};
    empty.setActiveIndex(2);
    try t.expectEqual(@as(i32, 0), empty.active_idx);
}
