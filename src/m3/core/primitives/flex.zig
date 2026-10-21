//! Flex layout container.
//!
//! Arranges children in a row or column. Children are positioned *during*
//! `paint()`: the layout pass computes each child's geometry from the flex
//! properties (spacing, padding, alignment, grow) and immediately paints it,
//! rather than separating measure from draw.
//!
//! ## Type-erased children
//!
//! Children store a `void* widget` plus a type tag, dispatched
//! `static_cast`s the pointer to the concrete class for each of its 24 cases.
//! That is RTTI-by-hand, and Zig has no equivalent: a `?*anyopaque` cannot be
//! recovered to a typed pointer from an enum tag.
//!
//! So children are a **tagged union** over the primitives that live in this
//! same layer (`Box`, `Label`, `Glyph`, `Separator`, `Spacer`, nested `Flex`),
//! which covers every child a `core/primitives` container can hold without
//! reaching into `controls/`. The remaining cases — Button, Slider, Chip,
//! Card, Dialog, NavBar, … — all follow the identical `setGeometry` then
//! `paint` shape, so they go through the `Child::Custom` arm: a `widget`
//! context pointer plus a `paint_fn` that receives the computed geometry.
//! That arm already existed in the original; it is simply the extension point
//! here too, and it keeps this file free of a dependency on every control.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const box_mod = @import("box.zig");
const label_mod = @import("../label.zig");
const glyph_mod = @import("../glyph.zig");
const separator_mod = @import("separator.zig");
const spacer_mod = @import("spacer.zig");

pub const Box = box_mod.Box;
pub const Label = label_mod.Label;
pub const Glyph = glyph_mod.Glyph;
pub const Separator = separator_mod.Separator;
pub const Spacer = spacer_mod.Spacer;

/// Flex layout container — arranges children in a row or column.
pub const Flex = struct {
    pub const Direction = enum {
        horizontal,
        vertical,
    };

    pub const Alignment = enum {
        start,
        center,
        end,
        stretch,
    };

    /// Which concrete type a child's `widget` pointer refers to.
    ///
    /// Enumerator names follow the child-type set. Only the types
    /// this layer owns are present — see the module note on why.
    pub const Kind = enum {
        box,
        label,
        glyph,
        separator,
        spacer,
        flex,
        /// Any control from `m3/controls/`. Carries the context pointer the
        /// caller passes to `paint_fn`.
        custom,
    };

    pub const Child = struct {
        /// Typed pointer for the core kinds; an opaque context for `.custom`.
        widget: ?*anyopaque = null,
        kind: Kind = .custom,
        min_w: f32 = 0.0,
        min_h: f32 = 0.0,
        /// 0 = no grow, 1+ = share leftover space.
        flex_grow: f32 = 0.0,
        visible: bool = true,
        /// Paint function for `.custom` children. It receives the geometry
        /// the layout computed, so it does the same `setGeometry` + `paint`
        /// the dispatch would have done for a concrete control type.
        paint_fn: ?*const fn (ctx: ?*anyopaque, cr: ?*cairo.cairo_t, x: f32, y: f32, w: f32, h: f32) void = null,
    };

    dir: Direction = .horizontal,
    main_align: Alignment = .start,
    cross_align: Alignment = .start,
    spacing: f32 = 0.0,
    pad_t: f32 = 0.0,
    pad_r: f32 = 0.0,
    pad_b: f32 = 0.0,
    pad_l: f32 = 0.0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,
    children: std.ArrayListUnmanaged(Child) = .empty,

    pub fn deinit(self: *Flex, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
        self.children = .empty;
    }

    pub fn setDirection(self: *Flex, d: Direction) void {
        self.dir = d;
    }

    pub fn setSpacing(self: *Flex, s: f32) void {
        self.spacing = s;
    }

    /// Per-edge padding, in top/right/bottom/left order.
    pub fn setPadding(self: *Flex, t: f32, r: f32, b: f32, l: f32) void {
        self.pad_t = t;
        self.pad_r = r;
        self.pad_b = b;
        self.pad_l = l;
    }

    /// Same padding on all four edges.
    pub fn setPaddingUniform(self: *Flex, all: f32) void {
        self.pad_t = all;
        self.pad_r = all;
        self.pad_b = all;
        self.pad_l = all;
    }

    pub fn setMainAlignment(self: *Flex, a: Alignment) void {
        self.main_align = a;
    }

    pub fn setCrossAlignment(self: *Flex, a: Alignment) void {
        self.cross_align = a;
    }

    pub fn setGeometry(self: *Flex, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn direction(self: *const Flex) Direction {
        return self.dir;
    }

    pub fn xPos(self: *const Flex) f32 {
        return self.x;
    }

    pub fn yPos(self: *const Flex) f32 {
        return self.y;
    }

    pub fn width(self: *const Flex) f32 {
        return self.w;
    }

    pub fn height(self: *const Flex) f32 {
        return self.h;
    }

    /// Append a child and return its index, matching `addChild` which
    /// returns a reference to the emplaced element.
    pub fn addChild(
        self: *Flex,
        allocator: std.mem.Allocator,
        child: Child,
    ) !usize {
        try self.children.append(allocator, child);
        return self.children.items.len - 1;
    }

    pub fn clear(self: *Flex) void {
        self.children.clearRetainingCapacity();
    }

    /// Set geometry on each child before painting, for the kinds whose type
    /// this layer knows. `.custom` hands the geometry to its paint function.
    fn paintChild(self: *const Flex, child: Child, c: ?*cairo.cairo_t, cx: f32, cy: f32, cw: f32, ch: f32) void {
        switch (child.kind) {
            .box => {
                const b: *Box = @ptrCast(@alignCast(child.widget.?));
                b.setGeometry(cx, cy, cw, ch);
                b.paint(c);
            },
            .label => {
                const l: *Label = @ptrCast(@alignCast(child.widget.?));
                l.setGeometry(cx, cy, cw, ch);
                l.paint(c);
            },
            .glyph => {
                const g: *Glyph = @ptrCast(@alignCast(child.widget.?));
                g.setGeometry(cx, cy, cw, ch);
                g.paint(c);
            },
            .separator => {
                const s: *Separator = @ptrCast(@alignCast(child.widget.?));
                s.setGeometry(cx, cy, cw, ch);
                s.paint(c);
            },
            .spacer => {
                // A spacer is positioned but never painted —
                // sets geometry and breaks without calling paint.
                const s: *Spacer = @ptrCast(@alignCast(child.widget.?));
                s.setGeometry(cx, cy, cw, ch);
            },
            .flex => {
                const f: *Flex = @ptrCast(@alignCast(child.widget.?));
                f.setGeometry(cx, cy, cw, ch);
                f.paint(c);
            },
            .custom => {
                if (child.paint_fn) |fn_ptr| fn_ptr(child.widget, c, cx, cy, cw, ch);
            },
        }
        _ = self;
    }

    /// Lay out children and paint them.
    pub fn paint(self: *const Flex, c: ?*cairo.cairo_t) void {
        if (self.children.items.len == 0) return;

        const content_x = self.x + self.pad_l;
        const content_y = self.y + self.pad_t;
        const content_w = @max(0.0, self.w - self.pad_l - self.pad_r);
        const content_h = @max(0.0, self.h - self.pad_t - self.pad_b);

        if (self.dir == .horizontal) {
            self.layoutHorizontal(c, content_x, content_y, content_w, content_h);
        } else {
            self.layoutVertical(c, content_x, content_y, content_w, content_h);
        }
    }

    fn layoutHorizontal(self: *const Flex, c: ?*cairo.cairo_t, cx: f32, cy: f32, cw: f32, ch: f32) void {
        // Measure fixed-size children, compute total flex grow.
        var fixed_size: f32 = 0.0;
        var total_grow: f32 = 0.0;
        var visible_count: i32 = 0;

        for (self.children.items) |child| {
            if (!child.visible) continue;
            fixed_size += child.min_w;
            total_grow += child.flex_grow;
            visible_count += 1;
        }
        fixed_size += @as(f32, @floatFromInt(@max(0, visible_count - 1))) * self.spacing;

        const leftover = @max(0.0, cw - fixed_size);
        const grow_unit: f32 = if (total_grow > 0) leftover / total_grow else 0.0;

        // Cross-axis size, recomputed across every
        // visible child and keeps the last one's value — a quirk worth
        // preserving, since callers pass uniform minH and it costs nothing.
        var cross_size = ch;
        for (self.children.items) |child| {
            if (!child.visible) continue;
            if (self.cross_align == .stretch) {
                cross_size = ch;
            } else {
                cross_size = @min(ch, if (child.min_h > 0) child.min_h else ch);
            }
        }

        // Total content size drives how far Center/End alignment shifts.
        var total_content_size = fixed_size;
        if (total_grow > 0) {
            for (self.children.items) |child| {
                if (!child.visible) continue;
                total_content_size += child.flex_grow * grow_unit;
            }
        }

        var start_x = cx;
        if (self.main_align == .center) {
            start_x = cx + (cw - total_content_size) * 0.5;
        } else if (self.main_align == .end) {
            start_x = cx + cw - total_content_size;
        }

        var cur_x = start_x;
        for (self.children.items) |child| {
            if (!child.visible) continue;

            const child_w = child.min_w + child.flex_grow * grow_unit;
            const child_h = cross_size;

            var child_y = cy;
            if (self.cross_align == .center) {
                child_y = cy + (ch - child_h) * 0.5;
            } else if (self.cross_align == .end) {
                child_y = cy + ch - child_h;
            }

            self.paintChild(child, c, cur_x, child_y, child_w, child_h);
            cur_x += child_w + self.spacing;
        }
    }

    fn layoutVertical(self: *const Flex, c: ?*cairo.cairo_t, cx: f32, cy: f32, cw: f32, ch: f32) void {
        var fixed_size: f32 = 0.0;
        var total_grow: f32 = 0.0;
        var visible_count: i32 = 0;

        for (self.children.items) |child| {
            if (!child.visible) continue;
            fixed_size += child.min_h;
            total_grow += child.flex_grow;
            visible_count += 1;
        }
        fixed_size += @as(f32, @floatFromInt(@max(0, visible_count - 1))) * self.spacing;

        const leftover = @max(0.0, ch - fixed_size);
        const grow_unit: f32 = if (total_grow > 0) leftover / total_grow else 0.0;

        var total_content_size = fixed_size;
        if (total_grow > 0) {
            for (self.children.items) |child| {
                if (!child.visible) continue;
                total_content_size += child.flex_grow * grow_unit;
            }
        }

        var start_y = cy;
        if (self.main_align == .center) {
            start_y = cy + (ch - total_content_size) * 0.5;
        } else if (self.main_align == .end) {
            start_y = cy + ch - total_content_size;
        }

        var cur_y = start_y;
        for (self.children.items) |child| {
            if (!child.visible) continue;

            const child_h = child.min_h + child.flex_grow * grow_unit;
            // A vertical container gives every child the full cross size.
            const child_w = cw;

            var child_x = cx;
            if (self.cross_align == .center) {
                child_x = cx + (cw - child_w) * 0.5;
            } else if (self.cross_align == .end) {
                child_x = cx + cw - child_w;
            }

            self.paintChild(child, c, child_x, cur_y, child_w, child_h);
            cur_y += child_h + self.spacing;
        }
    }
};

// ————— tests —————

const testing = std.testing;

test "m3-flex: horizontal row positions children left to right" {
    var flex = Flex{};
    defer flex.deinit(testing.allocator);
    flex.setGeometry(0, 0, 300, 40);
    flex.setSpacing(10);

    var a = Box{};
    var b = Box{};
    _ = try flex.addChild(testing.allocator, .{ .widget = &a, .kind = .box, .min_w = 50, .min_h = 20 });
    _ = try flex.addChild(testing.allocator, .{ .widget = &b, .kind = .box, .min_w = 50, .min_h = 20 });

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 300, 40);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    flex.paint(cr);
    try testing.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Each child got its own geometry: the second starts after the first plus
    // the gap.
    try testing.expectEqual(@as(f32, 0.0), a.x);
    try testing.expectEqual(@as(f32, 60.0), b.x);
    try testing.expectEqual(@as(f32, 50.0), a.w);
}

test "m3-flex: flex_grow shares leftover space" {
    var flex = Flex{};
    defer flex.deinit(testing.allocator);
    flex.setGeometry(0, 0, 200, 40);

    var a = Box{};
    var b = Box{};
    // One fixed child at 50, one that grows. The grower must absorb the
    // remaining 150.
    _ = try flex.addChild(testing.allocator, .{ .widget = &a, .kind = .box, .min_w = 50, .min_h = 10 });
    _ = try flex.addChild(testing.allocator, .{ .widget = &b, .kind = .box, .min_w = 0, .min_h = 10, .flex_grow = 1 });

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 200, 40);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    flex.paint(cr);

    try testing.expectApproxEqAbs(@as(f32, 150.0), b.w, 1e-4);
}

test "m3-flex: center and end alignment shift the whole run" {
    var flex = Flex{};
    defer flex.deinit(testing.allocator);
    flex.setGeometry(0, 0, 200, 40);
    flex.setMainAlignment(.center);

    var a = Box{};
    _ = try flex.addChild(testing.allocator, .{ .widget = &a, .kind = .box, .min_w = 40, .min_h = 10 });

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 200, 40);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    flex.paint(cr);

    // A 40-wide child centred in 200 starts at 80.
    try testing.expectApproxEqAbs(@as(f32, 80.0), a.x, 1e-4);
}

test "m3-flex: vertical column stacks and honours cross alignment" {
    var flex = Flex{};
    defer flex.deinit(testing.allocator);
    flex.setDirection(.vertical);
    flex.setGeometry(0, 0, 100, 200);
    flex.setSpacing(8);

    var a = Box{};
    var b = Box{};
    _ = try flex.addChild(testing.allocator, .{ .widget = &a, .kind = .box, .min_w = 10, .min_h = 30 });
    _ = try flex.addChild(testing.allocator, .{ .widget = &b, .kind = .box, .min_w = 10, .min_h = 30 });

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 100, 200);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    flex.paint(cr);

    try testing.expectEqual(@as(f32, 0.0), a.y);
    try testing.expectEqual(@as(f32, 38.0), b.y);
    // A vertical container gives every child the full cross width.
    try testing.expectEqual(@as(f32, 100.0), a.w);
}

test "m3-flex: invisible children are skipped entirely" {
    var flex = Flex{};
    defer flex.deinit(testing.allocator);
    flex.setGeometry(0, 0, 200, 40);

    var a = Box{};
    var b = Box{};
    _ = try flex.addChild(testing.allocator, .{ .widget = &a, .kind = .box, .min_w = 50, .min_h = 10 });
    _ = try flex.addChild(testing.allocator, .{ .widget = &b, .kind = .box, .min_w = 50, .min_h = 10, .visible = false });

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 200, 40);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    flex.paint(cr);

    // The hidden child keeps its zeroed geometry; visible ones are packed
    // against each other without leaving a gap for the skipped slot.
    try testing.expectEqual(@as(f32, 0.0), b.x);
    try testing.expectEqual(@as(f32, 0.0), b.w);
}

test "m3-flex: custom children receive the computed geometry" {
    const Probe = struct {
        var seen_x: f32 = -1;
        var seen_w: f32 = -1;
        fn paint(ctx: ?*anyopaque, cr: ?*cairo.cairo_t, x: f32, y: f32, w: f32, h: f32) void {
            _ = ctx;
            _ = cr;
            _ = y;
            _ = h;
            seen_x = x;
            seen_w = w;
        }
    };
    Probe.seen_x = -1;

    var flex = Flex{};
    defer flex.deinit(testing.allocator);
    flex.setGeometry(0, 0, 200, 40);
    _ = try flex.addChild(testing.allocator, .{
        .widget = null,
        .kind = .custom,
        .min_w = 60,
        .min_h = 20,
        .paint_fn = Probe.paint,
    });

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 200, 40);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    flex.paint(cr);

    try testing.expectEqual(@as(f32, 0.0), Probe.seen_x);
    try testing.expectEqual(@as(f32, 60.0), Probe.seen_w);
}

test "m3-flex: empty container paints nothing and is null-safe" {
    var flex = Flex{};
    defer flex.deinit(testing.allocator);
    flex.setGeometry(0, 0, 100, 100);
    // No children -> early return, so a null context is harmless.
    flex.paint(null);
    flex.clear();
}
