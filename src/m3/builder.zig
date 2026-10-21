//! Builder helpers for assembling display controls.
//!
//! Three things are here: the *seed* factory functions (`box()`, `label()`,
//! `glyph()`, `separator()`, `spacer()`), the fluent `LabelBuilder`, and the
//! fluent `FlexBuilder`.
//!
//! ## Seeds
//!
//! Seed factories return a freshly-defaulted value on every call,
//! object — but they all alias *one* object per function, and two live
//! results refer to the same storage. Zig has no such static (a function-local
//! `var` is a plain local), so these return **by value**: every call is
//! independent. For the only intended use — seed one widget, configure it,
//! hand it to a `Flex` — that is indistinguishable; it is only different if
//! you deliberately hold two results at once.
//!
//! ## `FlexBuilder.add`
//!
//! Child-type resolution hands `&child` to `Flex::addChild`. Here the child is
//! `anytype` and must already be a pointer (`&my_button`), because Zig has no
//! reference-to-reference deduction; `kindFor` is the `typeFor` analogue.
//!
//! The `minW`, `minH` and `flexGrow` defaults of `0, 0, 0` have no Zig
//! equivalent, so `add` spells them out and `addAuto` covers the
//! single-argument `add(child)` form.
//!
//! ## What changed in the mapping
//!
//! Child-type resolution returned one of ~30 type enumerators.
//! `m3/core/primitives/flex.zig` collapsed all of them into seven core kinds
//! plus `.custom`, because Zig has no RTTI with which to downcast an
//! erased `void*` back to `Button` and friends inside paint dispatch.
//! So `kindFor` returns `.box`/`.label`/`.glyph`/`.separator`/`.spacer`/
//! `.flex` for the six core types and `.custom` for everything else — and
//! each `.custom` child now carries a **type-specialised `paint_fn`** that
//! does the `setGeometry` + `paint` dispatch. That is the same
//! structural deviation the `Flex` port documents, reached from the other
//! side.
//!
//! A type that is neither core nor a widget with `setGeometry` and `paint`
//! still maps to `.custom`, but with `paint_fn = null` —
//! then skipped, which is the fallback for a type with no paint branch.
//!
//! ## The `padding` rename
//!
//! Overloads `padding(float)` and `padding(float, float, float, float)` are merged:
//! Zig cannot, so the uniform form keeps the name (`padding`) and the
//! four-argument one is `paddingEdges`.

const std = @import("std");
const cairo = @import("../wl/buffer/shm.zig").cairo;

const box_mod = @import("core/primitives/box.zig");
const flex_mod = @import("core/primitives/flex.zig");
const separator_mod = @import("core/primitives/separator.zig");
const spacer_mod = @import("core/primitives/spacer.zig");
const glyph_mod = @import("core/glyph.zig");
const label_mod = @import("core/label.zig");

const button_mod = @import("controls/containers/button.zig");
const card_mod = @import("controls/containers/card.zig");
const fab_mod = @import("controls/containers/fab.zig");
const checkbox_mod = @import("controls/input/checkbox.zig");
const chip_mod = @import("controls/input/chip.zig");
const date_picker_mod = @import("controls/input/date_picker.zig");
const input_mod = @import("controls/input/input.zig");
const radio_button_mod = @import("controls/input/radio_button.zig");
const select_mod = @import("controls/input/select.zig");
const slider_mod = @import("controls/input/slider.zig");
const time_picker_mod = @import("controls/input/time_picker.zig");
const toggle_mod = @import("controls/input/toggle.zig");
const banner_mod = @import("controls/display/banner.zig");
const bottom_sheet_mod = @import("controls/display/bottom_sheet.zig");
const carousel_mod = @import("controls/display/carousel.zig");
const dialog_mod = @import("controls/display/dialog.zig");
const snackbar_mod = @import("controls/display/snackbar.zig");
const bottom_app_bar_mod = @import("controls/navigation/bottom_app_bar.zig");
const nav_bar_mod = @import("controls/navigation/nav_bar.zig");
const nav_drawer_mod = @import("controls/navigation/nav_drawer.zig");
const nav_rail_mod = @import("controls/navigation/nav_rail.zig");
const search_bar_mod = @import("controls/navigation/search_bar.zig");
const tabs_mod = @import("controls/navigation/tabs.zig");
const top_app_bar_mod = @import("controls/navigation/top_app_bar.zig");

pub const Box = box_mod.Box;
pub const Flex = flex_mod.Flex;
pub const Separator = separator_mod.Separator;
pub const Spacer = spacer_mod.Spacer;
pub const Glyph = glyph_mod.Glyph;
pub const Label = label_mod.Label;
pub const FontConfig = label_mod.FontConfig;

pub const Button = button_mod.Button;
pub const Card = card_mod.Card;
pub const FAB = fab_mod.FAB;
pub const Checkbox = checkbox_mod.Checkbox;
pub const Chip = chip_mod.Chip;
pub const DatePicker = date_picker_mod.DatePicker;
pub const Input = input_mod.Input;
pub const RadioButton = radio_button_mod.RadioButton;
pub const Select = select_mod.Select;
pub const Slider = slider_mod.Slider;
pub const TimePicker = time_picker_mod.TimePicker;
pub const Toggle = toggle_mod.Toggle;
pub const Banner = banner_mod.Banner;
pub const BottomSheet = bottom_sheet_mod.BottomSheet;
pub const Carousel = carousel_mod.Carousel;
pub const Dialog = dialog_mod.Dialog;
pub const Snackbar = snackbar_mod.Snackbar;
pub const BottomAppBar = bottom_app_bar_mod.BottomAppBar;
pub const NavBar = nav_bar_mod.NavBar;
pub const NavDrawer = nav_drawer_mod.NavDrawer;
pub const NavRail = nav_rail_mod.NavRail;
pub const SearchBar = search_bar_mod.SearchBar;
pub const Tabs = tabs_mod.Tabs;
pub const TopAppBar = top_app_bar_mod.TopAppBar;

// ————— seed factories —————

/// A fresh, default-constructed `Label`.
/// a reference to a shared function-local static, this returns a value.
pub fn label() Label {
    return .{};
}

/// A fresh, default-constructed `Glyph`.
pub fn glyph() Glyph {
    return .{};
}

/// A fresh, default-constructed `Box`.
pub fn box() Box {
    return .{};
}

/// A fresh, default-constructed `Separator`.
pub fn separator() Separator {
    return .{};
}

/// A fresh, default-constructed `Spacer`.
pub fn spacer() Spacer {
    return .{};
}

// ————— fluent label builder —————

/// Fluent `Label` builder. Every setter returns `*self` so calls chain; the
/// Returns the builder for chaining.
///
/// Hold it in a named `var`. Conversion returns a
/// reference into the builder, so `labelBuilder().text("x")` as an rvalue
/// already dangles there; the same is true of `get()` here.
pub const LabelBuilder = struct {
    widget: Label = .{},

    pub fn text(self: *LabelBuilder, t: []const u8) *LabelBuilder {
        self.widget.setText(t);
        return self;
    }

    pub fn font(self: *LabelBuilder, fc: FontConfig) *LabelBuilder {
        self.widget.setFontConfig(fc);
        return self;
    }

    pub fn fontSize(self: *LabelBuilder, sp: f32) *LabelBuilder {
        self.widget.setFontSize(sp);
        return self;
    }

    /// Color with optional alpha — Zig has no default arguments,
    /// so the alpha is spelled out.
    pub fn color(self: *LabelBuilder, r: f32, g: f32, b: f32, a: f32) *LabelBuilder {
        self.widget.setColor(r, g, b, a);
        return self;
    }

    /// Conversion: a pointer to the widget being built.
    pub fn get(self: *LabelBuilder) *Label {
        return &self.widget;
    }
};

pub fn labelBuilder() LabelBuilder {
    return .{};
}

// ————— fluent flex builder —————

/// Fluent `Flex` builder, mirroring `m3::FlexBuilder`.
pub const FlexBuilder = struct {
    alloc: std.mem.Allocator,
    inner: Flex = .{},

    pub fn init(allocator: std.mem.Allocator) FlexBuilder {
        return .{ .alloc = allocator };
    }

    pub fn horizontal(self: *FlexBuilder) *FlexBuilder {
        self.inner.setDirection(.horizontal);
        return self;
    }

    pub fn vertical(self: *FlexBuilder) *FlexBuilder {
        self.inner.setDirection(.vertical);
        return self;
    }

    pub fn spacing(self: *FlexBuilder, s: f32) *FlexBuilder {
        self.inner.setSpacing(s);
        return self;
    }

    /// Uniform padding.
    pub fn padding(self: *FlexBuilder, all: f32) *FlexBuilder {
        self.inner.setPaddingUniform(all);
        return self;
    }

    /// Per-edge padding, renamed because Zig cannot
    /// overload on arity.
    pub fn paddingEdges(self: *FlexBuilder, t: f32, r: f32, b: f32, l: f32) *FlexBuilder {
        self.inner.setPadding(t, r, b, l);
        return self;
    }

    pub fn mainAlign(self: *FlexBuilder, a: Flex.Alignment) *FlexBuilder {
        self.inner.setMainAlignment(a);
        return self;
    }

    pub fn crossAlign(self: *FlexBuilder, a: Flex.Alignment) *FlexBuilder {
        self.inner.setCrossAlignment(a);
        return self;
    }

    pub fn geometry(self: *FlexBuilder, gx: f32, gy: f32, gw: f32, gh: f32) *FlexBuilder {
        self.inner.setGeometry(gx, gy, gw, gh);
        return self;
    }

    /// Append a child. `child` must be a pointer —
    /// stores `&child`; Zig takes the address itself because there is no
    /// reference-to-pointer deduction.
    ///
    /// Returns a pointer to this builder so calls chain, or the allocator
    /// error from `Flex::addChild`.
    pub fn add(
        self: *FlexBuilder,
        child: anytype,
        min_w: f32,
        min_h: f32,
        flex_grow: f32,
    ) !*FlexBuilder {
        const info = @typeInfo(@TypeOf(child));
        if (info != .pointer or info.pointer.size != .one) {
            @compileError("FlexBuilder.add expects a single-item pointer to the child widget");
        }
        const T = info.pointer.child;

        _ = try self.inner.addChild(self.alloc, .{
            .widget = @ptrCast(child),
            .kind = kindFor(T),
            .min_w = min_w,
            .min_h = min_h,
            .flex_grow = flex_grow,
            .paint_fn = if (kindFor(T) == .custom) widgetPaintFn(T) else null,
        });
        return self;
    }

    /// The single-argument `add(child)` form, where `minW`/`minH`/`flexGrow` default to
    /// `0, 0, 0`.
    pub fn addAuto(self: *FlexBuilder, child: anytype) !*FlexBuilder {
        return try self.add(child, 0.0, 0.0, 0.0);
    }

    /// Conversion to the built widget.
    pub fn flex(self: *FlexBuilder) *Flex {
        return &self.inner;
    }

    /// Release the child array. Nothing else here owns memory.
    pub fn deinit(self: *FlexBuilder) void {
        self.inner.deinit(self.alloc);
    }
};

/// The `flex()` factory — but `FlexBuilder` needs an allocator to hand
/// `Flex::addChild`, backed by an internal growable array.
pub fn flex(allocator: std.mem.Allocator) FlexBuilder {
    return FlexBuilder.init(allocator);
}

// ————— type mapping (the `typeFor<T>()` analogue) —————

/// Which `Flex.Kind` a concrete type gets. The six core types keep their own
/// kind; every other type is `.custom`, carrying a widget `paint_fn`.
fn kindFor(comptime T: type) Flex.Kind {
    if (T == Box) return .box;
    if (T == Label) return .label;
    if (T == Glyph) return .glyph;
    if (T == Separator) return .separator;
    if (T == Spacer) return .spacer;
    if (T == Flex) return .flex;
    return .custom;
}

/// Build the type-specialised paint function for a `.custom` child: set the
/// layout geometry, then paint. `null` for anything without both, matching
/// a `Child::Custom` case having no branch to draw with.
fn widgetPaintFn(comptime T: type) ?*const fn (?*anyopaque, ?*cairo.cairo_t, f32, f32, f32, f32) void {
    if (!@hasDecl(T, "setGeometry")) return null;
    if (!@hasDecl(T, "paint")) return null;

    // Controls animate through a `now_ms` argument (Button, Slider, …); the
    // rest take only the context. `paintStatic` exists on the former to
    // forward `0`, which is exactly what a static draw wants.
    const takes_time = blk: {
        const fn_info = @typeInfo(@TypeOf(@field(T, "paint"))).@"fn";
        break :blk fn_info.params.len >= 3;
    };

    return struct {
        fn paint(ctx: ?*anyopaque, cr: ?*cairo.cairo_t, x: f32, y: f32, w: f32, h: f32) void {
            const p: *T = @ptrCast(@alignCast(ctx orelse return));
            p.setGeometry(x, y, w, h);
            if (comptime takes_time) {
                p.paint(cr, 0);
            } else {
                p.paint(cr);
            }
        }
    }.paint;
}

// ————— tests —————

const testing = std.testing;

test "m3-builder: seeds hand back independent defaults" {
    const t = testing;

    // Seeds return independent values, so two
    // live results alias; here they are separate values. What both share is
    // the *default* on every call, which is the point of the reset.
    var a = label();
    const b = label();
    a.setText("one");
    try t.expectEqualStrings("one", a.text);
    try t.expectEqualStrings("", b.text);
    // Re-seeding gives a default again.
    a = label();
    try t.expectEqualStrings("", a.text);

    var x = box();
    x.setRadius(8);
    try t.expectEqual(@as(f32, 8.0), x.radius);
    x = box();
    try t.expectEqual(@as(f32, 0.0), x.radius);

    // The rest are here to prove they exist and default-construct.
    const s = separator();
    const p = spacer();
    const g = glyph();
    _ = s;
    _ = p;
    _ = g;
}

test "m3-builder: LabelBuilder chains, and get() hands back the widget" {
    const t = testing;
    var lb = labelBuilder();
    const out = lb
        .text("Hello")
        .fontSize(22.0)
        .color(0.5, 0.6, 0.7, 0.9);

    // Chaining returns the builder, so one call reaches the widget.
    try t.expect(out == &lb);
    const l = lb.get();
    try t.expect(l == &lb.widget);
    try t.expectEqualStrings("Hello", l.text);
    try t.expectEqual(@as(f32, 22.0), l.fc.size);
    try t.expectEqual(@as(f32, 0.5), l.r);
    try t.expectEqual(@as(f32, 0.9), l.a);
}

test "m3-builder: FlexBuilder fluent setters reach the Flex" {
    const t = testing;
    var fb = flex(testing.allocator);
    defer fb.deinit();

    const out = fb
        .vertical()
        .spacing(9.0)
        .padding(12.0)
        .geometry(1, 2, 3, 4)
        .mainAlign(.center)
        .crossAlign(.end);

    try t.expect(out == &fb);
    const f = fb.flex();
    try t.expect(f.direction() == .vertical);
    try t.expectEqual(@as(f32, 9.0), f.spacing);
    try t.expectEqual(@as(f32, 12.0), f.pad_t);
    try t.expectEqual(@as(f32, 12.0), f.pad_l);
    try t.expectEqual(@as(f32, 1.0), f.xPos());
    try t.expectEqual(@as(f32, 4.0), f.height());
    try t.expect(f.main_align == .center);
    try t.expect(f.cross_align == .end);

    // The four-edge overload.
    _ = fb.paddingEdges(1, 2, 3, 4);
    try t.expectEqual(@as(f32, 1.0), f.pad_t);
    try t.expectEqual(@as(f32, 2.0), f.pad_r);
    try t.expectEqual(@as(f32, 3.0), f.pad_b);
    try t.expectEqual(@as(f32, 4.0), f.pad_l);
    _ = fb.horizontal();
    try t.expect(f.direction() == .horizontal);
}

test "m3-builder: add maps core types to their kind and controls to .custom" {
    const t = testing;
    var fb = flex(testing.allocator);
    defer fb.deinit();

    var b = Box{};
    var l = Label{};
    var s = Spacer{};
    var btn = Button{};

    try t.expect((try fb.addAuto(&b)) == &fb);
    try t.expect((try fb.add(&l, 10, 20, 0)) == &fb);
    try t.expect((try fb.addAuto(&s)) == &fb);
    try t.expect((try fb.add(&btn, 0, 0, 1)) == &fb);

    const kids = fb.flex().children.items;
    try t.expectEqual(@as(usize, 4), kids.len);
    try t.expect(kids[0].kind == .box);
    try t.expect(kids[0].paint_fn == null);
    try t.expect(kids[1].kind == .label);
    try t.expectEqual(@as(f32, 10.0), kids[1].min_w);
    try t.expectEqual(@as(f32, 20.0), kids[1].min_h);
    try t.expect(kids[2].kind == .spacer);
    // Controls are `.custom`, and they carry the synthesised paint function
    // that replaces the 24-way switch.
    try t.expect(kids[3].kind == .custom);
    try t.expect(kids[3].paint_fn != null);
    try t.expectEqual(@as(f32, 1.0), kids[3].flex_grow);
    try t.expect(kids[3].widget == @as(?*anyopaque, @ptrCast(&btn)));
}

test "m3-builder: a widget-shaped child of unknown type still lands as .custom" {
    const t = testing;
    var fb = flex(testing.allocator);
    defer fb.deinit();

    const Odd = struct {
        x: f32 = 0,
        y: f32 = 0,
        w: f32 = 0,
        h: f32 = 0,
        painted: bool = false,

        pub fn setGeometry(self: *@This(), gx: f32, gy: f32, gw: f32, gh: f32) void {
            self.x = gx;
            self.y = gy;
            self.w = gw;
            self.h = gh;
        }

        pub fn paint(self: *@This(), c: ?*cairo.cairo_t) void {
            self.painted = c != null;
        }
    };
    var odd = Odd{};

    _ = try fb.addAuto(&odd);
    const kid = fb.flex().children.items[0];
    try t.expect(kid.kind == .custom);
    try t.expect(kid.paint_fn != null);

    // Drive the synthesised function the way Flex::paintChild does.
    const surface = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 40, 40);
    defer cairo.cairo_surface_destroy(surface);
    const cr = cairo.cairo_create(surface);
    defer cairo.cairo_destroy(cr);

    kid.paint_fn.?(kid.widget, cr, 5, 6, 7, 8);
    try t.expectEqual(@as(f32, 5.0), odd.x);
    try t.expectEqual(@as(f32, 8.0), odd.h);
    try t.expect(odd.painted);

    // A type with no `paint` at all gets a null function instead —
    // `Child::Custom` case, which has nothing to draw.
    const Blank = struct {
        fn unused() void {}
    };
    var blank = Blank{};
    _ = &blank;
    _ = try fb.addAuto(&blank);
    try t.expect(fb.flex().children.items[1].kind == .custom);
    try t.expect(fb.flex().children.items[1].paint_fn == null);
}

test "m3-builder: an end-to-end flex of controls paints without error" {
    const t = testing;
    var fb = flex(testing.allocator);
    defer fb.deinit();

    var head = Label{};
    head.setText("Header");
    var sep = Separator{};
    var card = Card{};
    var check = Checkbox{};
    var tab_bar = Tabs{};

    _ = fb
        .vertical()
        .spacing(8)
        .padding(16)
        .geometry(0, 0, 320, 240);
    _ = try fb.addAuto(&head);
    _ = try fb.addAuto(&sep);
    _ = try fb.addAuto(&card);
    _ = try fb.addAuto(&check);
    _ = try fb.addAuto(&tab_bar);

    const surface = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 320, 240);
    defer cairo.cairo_surface_destroy(surface);
    const cr = cairo.cairo_create(surface);
    defer cairo.cairo_destroy(cr);

    fb.flex().paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // An empty builder paints nothing at all.
    var bare = flex(testing.allocator);
    defer bare.deinit();
    bare.flex().paint(null);
    bare.flex().paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}
