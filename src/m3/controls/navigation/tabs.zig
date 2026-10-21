//! M3 tabs, Primary or Secondary.
//!
//! Primary is full-width with an icon above each label and an indicator bar
//! spanning the whole segment; Secondary is compact, has no icons, and its
//! indicator is only half a segment wide, centred.
//!
//! `tabAt` divides the bar into equal segments and returns the index under a
//! point — but `handlePointerDown` always returns false, so activating a tab is the caller's job;
//! `activateAt` is provided here to make that wiring a one-liner without
//! changing what the control itself does on a press.
//!
//! `setActiveIndex` clamps into `[0, tabs.len - 1]`. When the list is empty
//! it returns early with 0 instead of clamping into an empty range.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const state_layer_mod = @import("../../core/primitives/state_layer.zig");

pub const FocusRing = state_layer_mod.FocusRing;

pub const Callback = *const fn (ctx: ?*anyopaque) void;

/// One tab. `label` and `icon` are borrowed slices.
pub const Tab = struct {
    label: []const u8 = "",
    /// Optional, primary variant only.
    icon: []const u8 = "",
    on_activate: ?Callback = null,
    ctx: ?*anyopaque = null,
};

/// M3 Tabs — Primary (full-width, indicator bar) or Secondary (compact).
pub const Tabs = struct {
    pub const Variant = enum {
        primary,
        secondary,
    };

    pub const kFontPrimary: f32 = 14.0;
    pub const kFontSecondary: f32 = 12.0;
    pub const kIconSize: f32 = 20.0;
    /// Indicator thickness.
    pub const kBarHeight: f32 = 3.0;
    /// Active/inactive label alpha.
    pub const kActiveAlpha: f32 = 0.93;
    pub const kInactiveAlpha: f32 = 0.66;

    tabs: []const Tab = &.{},
    active_idx: i32 = 0,
    variant: Variant = .primary,

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

    pub fn setTabs(self: *Tabs, list: []const Tab) void {
        self.tabs = list;
        // Keep the selection in range when the list shrinks under it.
        self.setActiveIndex(self.active_idx);
    }

    /// Clamps into `[0, tabs.len - 1]`; with no tabs it leaves 0 in place.
    pub fn setActiveIndex(self: *Tabs, i: i32) void {
        if (self.tabs.len == 0) {
            self.active_idx = 0;
            return;
        }
        const last: i32 = @intCast(self.tabs.len - 1);
        self.active_idx = std.math.clamp(i, 0, last);
    }

    pub fn setVariant(self: *Tabs, v: Variant) void {
        self.variant = v;
    }

    pub fn setGeometry(self: *Tabs, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setAccentColor(self: *Tabs, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *Tabs, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *Tabs, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *Tabs, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn activeIndex(self: *const Tabs) i32 {
        return self.active_idx;
    }

    pub fn containsPoint(self: *const Tabs, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    /// The index of the segment under a point, or -1 when there are no tabs
    /// or the point falls outside the column run.
    pub fn tabAt(self: *const Tabs, px: f32) i32 {
        if (self.tabs.len == 0) return -1;
        const seg_w = self.w / @as(f32, @floatFromInt(self.tabs.len));
        const idx_f = (px - self.x) / seg_w;
        if (idx_f < 0) return -1;
        const idx: i32 = @intFromFloat(@trunc(idx_f));
        if (idx < 0 or idx >= @as(i32, @intCast(self.tabs.len))) return -1;
        return idx;
    }

    /// Presses do nothing — both coordinates ignored, returns false.
    pub fn handlePointerDown(self: *Tabs, px: f32, py: f32) bool {
        _ = self;
        _ = px;
        _ = py;
        return false;
    }

    /// Convenience wiring described in the module note.
    /// Selects the segment under `px` and fires its `on_activate`.
    pub fn activateAt(self: *Tabs, px: f32) bool {
        const idx = self.tabAt(px);
        if (idx < 0) return false;
        self.setActiveIndex(idx);
        const tab = self.tabs[@intCast(idx)];
        if (tab.on_activate) |cb| cb(tab.ctx);
        return true;
    }

    pub fn paint(self: *const Tabs, c: ?*cairo.cairo_t) void {
        if (self.w <= 0.0 or self.h <= 0.0 or self.tabs.len == 0) return;
        const cr = c orelse return;

        const n: f32 = @floatFromInt(self.tabs.len);
        const seg_w = self.w / n;
        const primary = self.variant == .primary;
        const font_size: f32 = if (primary) kFontPrimary else kFontSecondary;
        const bar_h = kBarHeight;

        // Background.
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, self.surface_r, self.surface_g, self.surface_b, 1.0);
        cairo.cairo_rectangle(cr, self.x, self.y, self.w, self.h);
        cairo.cairo_fill(cr);
        cairo.cairo_restore(cr);

        for (self.tabs, 0..) |tab, i| {
            const seg_x = self.x + @as(f32, @floatFromInt(i)) * seg_w;
            const active = @as(i32, @intCast(i)) == self.active_idx;

            // Indicator bar — full segment for primary, half for secondary.
            if (active) {
                const bar_w: f32 = seg_w * (if (primary) @as(f32, 1.0) else 0.5);
                const bar_x = seg_x + (seg_w - bar_w) * 0.5;
                const bar_y = self.y + self.h - bar_h;
                cairo.cairo_save(cr);
                cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, 1.0);
                cairo.cairo_rectangle(cr, bar_x, bar_y, bar_w, bar_h);
                cairo.cairo_fill(cr);
                cairo.cairo_restore(cr);
            }

            // Icon — primary only.
            if (primary and tab.icon.len != 0) {
                cairo.cairo_save(cr);
                cairo.cairo_select_font_face(
                    cr,
                    "Symbols Nerd Font",
                    cairo.CAIRO_FONT_SLANT_NORMAL,
                    cairo.CAIRO_FONT_WEIGHT_NORMAL,
                );
                cairo.cairo_set_font_size(cr, kIconSize);
                cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, if (active) kActiveAlpha else kInactiveAlpha);
                cairo.cairo_move_to(cr, seg_x + (seg_w - kIconSize) * 0.5, self.y + self.h * 0.3 + kIconSize * 0.3);
                var icon_buf: [256:0]u8 = undefined;
                cairo.cairo_show_text(cr, toCString(tab.icon, &icon_buf));
                cairo.cairo_restore(cr);
            }

            // Label.
            cairo.cairo_save(cr);
            cairo.cairo_select_font_face(
                cr,
                "Sans",
                cairo.CAIRO_FONT_SLANT_NORMAL,
                cairo.CAIRO_FONT_WEIGHT_NORMAL,
            );
            cairo.cairo_set_font_size(cr, font_size);
            cairo.cairo_set_source_rgba(cr, self.text_r, self.text_g, self.text_b, if (active) kActiveAlpha else kInactiveAlpha);

            var label_buf: [256:0]u8 = undefined;
            const label = toCString(tab.label, &label_buf);

            var te: cairo.cairo_text_extents_t = undefined;
            cairo.cairo_text_extents(cr, label, &te);
            const lx = seg_x + (seg_w - @as(f32, @floatCast(te.width))) * 0.5;
            // Primary drops the label lower to clear the icon above it.
            const ly = if (primary)
                self.y + self.h * 0.72 + font_size * 0.35
            else
                self.y + self.h * 0.5 + font_size * 0.35;
            cairo.cairo_move_to(cr, lx, ly);
            cairo.cairo_show_text(cr, label);
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

const kTabList = [_]Tab{
    .{ .label = "One", .icon = "looks_one" },
    .{ .label = "Two", .icon = "looks_2" },
    .{ .label = "Three", .icon = "looks_3" },
};

test "m3-tabs: tabAt maps a point to its segment, or -1 outside" {
    const t = testing;
    var tabs = Tabs{};
    tabs.setTabs(&kTabList);
    tabs.setGeometry(0, 0, 300, 48);

    // 300 / 3 = 100dp segments.
    try t.expectEqual(@as(i32, 0), tabs.tabAt(10));
    try t.expectEqual(@as(i32, 1), tabs.tabAt(150));
    try t.expectEqual(@as(i32, 2), tabs.tabAt(299));
    // Exactly at the boundary belongs to the next segment (truncation).
    try t.expectEqual(@as(i32, 1), tabs.tabAt(100));
    // Left of the bar is -1; so is a point past the last segment.
    try t.expectEqual(@as(i32, -1), tabs.tabAt(-5));
    try t.expectEqual(@as(i32, -1), tabs.tabAt(301));

    // With no tabs there is nothing to hit.
    var empty = Tabs{};
    try t.expectEqual(@as(i32, -1), empty.tabAt(50));
}

test "m3-tabs: setActiveIndex clamps, including the empty-list case" {
    const t = testing;
    var tabs = Tabs{};
    tabs.setTabs(&kTabList);

    tabs.setActiveIndex(-4);
    try t.expectEqual(@as(i32, 0), tabs.activeIndex());
    tabs.setActiveIndex(99);
    try t.expectEqual(@as(i32, 2), tabs.activeIndex());

    // Empty list keeps 0 instead of clamping into an empty range.
    var empty = Tabs{};
    empty.setActiveIndex(5);
    try t.expectEqual(@as(i32, 0), empty.activeIndex());

    // Shrinking the list pulls the selection back in range.
    tabs.setActiveIndex(2);
    tabs.setTabs(kTabList[0..2]);
    try t.expectEqual(@as(i32, 1), tabs.activeIndex());
}

test "m3-tabs: a press is ignored, but activateAt selects and notifies" {
    const t = testing;
    const S = struct {
        var activations: usize = 0;
        fn onActivate(ctx: ?*anyopaque) void {
            _ = ctx;
            activations += 1;
        }
    };
    S.activations = 0;

    var list = [_]Tab{
        .{ .label = "One", .on_activate = S.onActivate },
        .{ .label = "Two", .on_activate = S.onActivate },
    };

    var tabs = Tabs{};
    tabs.setTabs(&list);
    tabs.setGeometry(0, 0, 300, 48);

    // Faithful: `handlePointerDown` never does anything.
    try t.expect(!tabs.handlePointerDown(150, 20));
    try t.expectEqual(@as(i32, 0), tabs.activeIndex());
    try t.expectEqual(@as(usize, 0), S.activations);

    // The helper the module note describes does the wiring.
    try t.expect(tabs.activateAt(150));
    try t.expectEqual(@as(i32, 1), tabs.activeIndex());
    try t.expectEqual(@as(usize, 1), S.activations);

    // Off the end selects nothing.
    try t.expect(!tabs.activateAt(500));
    try t.expectEqual(@as(i32, 1), tabs.activeIndex());
    try t.expectEqual(@as(usize, 1), S.activations);
}

test "m3-tabs: both variants paint, and an empty bar paints nothing" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 320, 60);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    inline for (.{ .primary, .secondary }) |v| {
        var tabs = Tabs{};
        tabs.setVariant(v);
        tabs.setTabs(&kTabList);
        tabs.setGeometry(4, 4, 300, 48);
        tabs.setActiveIndex(1);
        tabs.paint(cr);
        try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
    }

    // No tabs: paint returns before touching the context.
    var empty = Tabs{};
    empty.setGeometry(4, 4, 300, 48);
    empty.paint(null);
    empty.paint(cr);
}
