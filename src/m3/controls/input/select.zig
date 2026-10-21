//! The M3 dropdown: trigger plus popup menu.
//!
//! The trigger is a filled field like `Input`, with a caret glyph that flips
//! between `expand_more` and `expand_less` depending on whether the menu is
//! open. Opening it drops a menu two pixels below the trigger, capped at
//! `maxVisible` rows of `optH` each — rows beyond that are simply not drawn,
//! and there is no scrolling, so a longer list is unreachable.
//!
//! Selection happens on *pointer down*, not release: `handlePointerDown`
//! resolves the row under the cursor and immediately selects it, which also
//! closes the menu. The release is what toggles the trigger itself.
//!
//! A 3dp accent bar marks the selected row, and a faint accent wash marks the
//! hovered one.
//!
//! The menu's shadow is an offset rectangle rather than a real blurred drop
//! shadow — Cairo needs a shadow filter it does
//! not have here, so it fakes one with a translated fill.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const label_mod = @import("../../core/label.zig");
const glyph_mod = @import("../../core/glyph.zig");
const box_mod = @import("../../core/primitives/box.zig");
const state_layer_mod = @import("../../core/primitives/state_layer.zig");

pub const Label = label_mod.Label;
pub const Glyph = glyph_mod.Glyph;
pub const Box = box_mod.Box;
pub const StateLayer = state_layer_mod.StateLayer;
pub const FocusRing = state_layer_mod.FocusRing;

/// `onSelect` sink. `label` is borrowed and only valid for the call.
pub const SelectCallback = *const fn (ctx: ?*anyopaque, index: usize, label: []const u8) void;

/// M3 Select (Dropdown) — trigger with caret, popup menu, state layers.
pub const Select = struct {
    /// Sentinel for "no selection"/"no row under the cursor":
    /// `size_t(-1)`; `maxInt(usize)` is the same value.
    pub const kNpos = std.math.maxInt(usize);

    /// Menu drop shadow depth — `elevation.level2` in the token table.
    pub const kMenuElevation: f32 = 3.0;
    /// Menu corner radius — `corner.extra-small`.
    pub const kMenuRadius: f32 = 4.0;
    /// Gap between the trigger's bottom edge and the menu's top.
    pub const kDropGap: f32 = 2.0;
    /// Selected-row indicator bar width.
    pub const kIndicatorW: f32 = 3.0;
    /// Caret glyph size.
    pub const kCaretSize: f32 = 20.0;

    /// Options. Borrowed — the caller owns the strings and must keep them
    /// alive for as long as this `Select` is painted.
    options: []const []const u8 = &.{},
    sel: usize = kNpos,
    hovered_idx: usize = kNpos,
    placeholder: []const u8 = "",

    enabled: bool = true,
    open: bool = false,
    trig_hovered: bool = false,
    trig_pressed: bool = false,
    focused: bool = false,

    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,
    opt_h: f32 = 32.0,
    padding: f32 = 12.0,
    font_size: f32 = 14.0,
    max_visible: usize = 6,

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

    state_layer: StateLayer = .{},
    focus_ring: FocusRing = .{},

    on_select: ?SelectCallback = null,
    cb_ctx: ?*anyopaque = null,

    /// Replace the option list, pulling the selection back into range.
    ///
    /// Clamped to `options_.size() - 1`, which
    /// underflows to `npos` when the list is empty — an accident that happens
    /// to give the right answer, since `npos` *is* "no selection". The Zig
    /// version branches on emptiness instead of relying on the wrap.
    pub fn setOptions(self: *Select, items: []const []const u8) void {
        self.options = items;
        if (items.len == 0) {
            self.sel = kNpos;
        } else if (self.sel >= items.len) {
            self.sel = items.len - 1;
        }
    }

    pub fn setSelectedIndex(self: *Select, idx: usize) void {
        self.sel = idx;
    }

    pub fn setPlaceholder(self: *Select, text: []const u8) void {
        self.placeholder = text;
    }

    /// Disabling also closes an open menu.
    pub fn setEnabled(self: *Select, e: bool) void {
        self.enabled = e;
        if (!e) self.open = false;
    }

    pub fn setGeometry(self: *Select, gx: f32, gy: f32, gw: f32, gh: f32) void {
        self.x = gx;
        self.y = gy;
        self.w = gw;
        self.h = gh;
    }

    pub fn setMaxVisible(self: *Select, rows: usize) void {
        self.max_visible = rows;
    }

    pub fn setAccentColor(self: *Select, r: f32, g: f32, b: f32) void {
        self.accent_r = r;
        self.accent_g = g;
        self.accent_b = b;
    }

    pub fn setSurfaceColor(self: *Select, r: f32, g: f32, b: f32) void {
        self.surface_r = r;
        self.surface_g = g;
        self.surface_b = b;
    }

    pub fn setTextColor(self: *Select, r: f32, g: f32, b: f32) void {
        self.text_r = r;
        self.text_g = g;
        self.text_b = b;
    }

    pub fn setOutlineColor(self: *Select, r: f32, g: f32, b: f32) void {
        self.outline_r = r;
        self.outline_g = g;
        self.outline_b = b;
    }

    pub fn setOnSelect(self: *Select, cb: ?SelectCallback) void {
        self.on_select = cb;
    }

    pub fn setCallbackContext(self: *Select, ctx: ?*anyopaque) void {
        self.cb_ctx = ctx;
    }

    pub fn setTriggerHovered(self: *Select, h: bool) void {
        self.trig_hovered = h;
    }

    pub fn setTriggerPressed(self: *Select, p: bool) void {
        self.trig_pressed = p;
    }

    pub fn setFocused(self: *Select, f: bool) void {
        self.focused = f;
    }

    pub fn selectedIndex(self: *const Select) usize {
        return self.sel;
    }

    /// The selected option's text, or an empty slice when out of range.
    pub fn selectedText(self: *const Select) []const u8 {
        if (self.sel >= self.options.len) return "";
        return self.options[self.sel];
    }

    pub fn isEnabled(self: *const Select) bool {
        return self.enabled;
    }

    pub fn isOpen(self: *const Select) bool {
        return self.open;
    }

    pub fn xPos(self: *const Select) f32 {
        return self.x;
    }

    pub fn yPos(self: *const Select) f32 {
        return self.y;
    }

    pub fn width(self: *const Select) f32 {
        return self.w;
    }

    pub fn height(self: *const Select) f32 {
        return self.h;
    }

    /// Menu height — the visible rows, capped by `max_visible`.
    pub fn menuHeight(self: *const Select) f32 {
        const n = @min(self.options.len, self.max_visible);
        return @as(f32, @floatFromInt(n)) * self.opt_h;
    }

    /// The menu's top edge: the trigger's bottom, plus the 2dp gap.
    fn dropTop(self: *const Select) f32 {
        return self.y + self.h + kDropGap;
    }

    pub fn containsPoint(self: *const Select, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    pub fn containsMenuPoint(self: *const Select, px: f32, py: f32) bool {
        if (!self.open) return false;
        const my = self.dropTop();
        const mh = self.menuHeight();
        return px >= self.x and px < self.x + self.w and py >= my and py < my + mh;
    }

    pub fn close(self: *Select) void {
        self.open = false;
    }

    /// Opening is refused while disabled.
    pub fn toggle(self: *Select) void {
        if (self.enabled) self.open = !self.open;
    }

    /// The row under a point, or `kNpos`.
    ///
    /// Note this divides by `opt_h` and checks only that the resulting index
    /// is in range — it does not re-test `containsMenuPoint`, so a point far
    /// *below* the menu can still resolve to the last row. `handlePointerDown`
    /// calls it only after `containsMenuPoint` succeeds, so that quirk is not
    /// reachable from the normal path.
    fn optionAt(self: *const Select, px: f32, py: f32) usize {
        _ = px;
        if (!self.open or self.options.len == 0) return kNpos;
        const my = self.dropTop();
        const idx_f = (py - my) / self.opt_h;
        if (idx_f < 0) return kNpos;
        const idx: usize = @intFromFloat(@trunc(idx_f));
        if (idx >= self.options.len) return kNpos;
        return idx;
    }

    /// Commit a selection: store it, close the menu, notify.
    fn selectIndex(self: *Select, idx: usize) void {
        if (idx >= self.options.len) return;
        self.sel = idx;
        self.open = false;
        if (self.on_select) |cb| cb(self.cb_ctx, idx, self.options[idx]);
    }

    pub fn handlePointerEnter(self: *Select, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.enabled) return false;
        self.trig_hovered = true;
        return true;
    }

    pub fn handlePointerLeave(self: *Select) bool {
        self.trig_hovered = false;
        self.trig_pressed = false;
        return true;
    }

    /// Pressing inside the open menu selects that row immediately; pressing
    /// the trigger arms it for the release to toggle.
    pub fn handlePointerDown(self: *Select, px: f32, py: f32) bool {
        if (!self.enabled) return false;
        if (self.containsMenuPoint(px, py)) {
            const idx = self.optionAt(px, py);
            if (idx != kNpos) self.selectIndex(idx);
            return true;
        }
        if (self.containsPoint(px, py)) {
            self.trig_pressed = true;
            return true;
        }
        return false;
    }

    /// Hover tracking over the open menu.
    pub fn handlePointerMove(self: *Select, px: f32, py: f32) bool {
        if (!self.enabled) return false;
        if (self.open) {
            self.hovered_idx = self.optionAt(px, py);
        }
        return true;
    }

    /// The release toggles the menu — the selection itself happened on press.
    pub fn handlePointerUp(self: *Select, px: f32, py: f32) bool {
        _ = px;
        _ = py;
        if (!self.enabled) return false;
        if (self.trig_pressed) {
            self.trig_pressed = false;
            self.open = !self.open;
            return true;
        }
        return false;
    }

    pub fn paint(self: *Select, c: ?*cairo.cairo_t) void {
        self.paintTrigger(c);
        if (self.open) self.paintMenu(c);
    }

    fn paintTrigger(self: *Select, c: ?*cairo.cairo_t) void {
        const cr = c orelse return;
        const input_h = self.h;
        // `corner.extra-small` — the same radius `Input` uses.
        const r: f32 = 4.0;

        cairo.cairo_save(cr);

        // Background via Box for the glassy inner design, with the same 1.05
        // surface lift `Input` applies.
        const bg_a: f32 = if (self.enabled) 1.0 else 0.38;
        var bg_box = Box{};
        bg_box.setColor(self.surface_r * 1.05, self.surface_g * 1.05, self.surface_b * 1.05, bg_a);
        bg_box.setRadius(r);
        bg_box.setGeometry(self.x, self.y, self.w, input_h);
        bg_box.setGlassy(true);
        bg_box.paint(c);

        // Bottom indicator line, accent when focused.
        const line_r: f32 = if (self.focused) self.accent_r else self.outline_r;
        const line_g: f32 = if (self.focused) self.accent_g else self.outline_g;
        const line_b: f32 = if (self.focused) self.accent_b else self.outline_b;
        cairo.cairo_set_source_rgba(cr, line_r, line_g, line_b, if (self.enabled) 1.0 else 0.38);
        cairo.cairo_set_line_width(cr, if (self.focused) 2.0 else 1.0);
        cairo.cairo_move_to(cr, self.x, self.y + input_h);
        cairo.cairo_line_to(cr, self.x + self.w, self.y + input_h);
        cairo.cairo_stroke(cr);

        cairo.cairo_restore(cr);

        // Label — the selected option, or the placeholder when nothing is
        // selected. An empty placeholder falls back to "Select...".
        if (self.sel < self.options.len) {
            var lbl = Label{};
            lbl.setText(self.options[self.sel]);
            lbl.setFontSize(self.font_size);
            lbl.setColor(self.text_r, self.text_g, self.text_b, if (self.enabled) 1.0 else 0.38);
            lbl.paintAt(c, self.x + self.padding, self.y + (input_h - 18.0) * 0.5);
        } else {
            var lbl = Label{};
            lbl.setText(if (self.placeholder.len == 0) "Select..." else self.placeholder);
            lbl.setFontSize(self.font_size);
            lbl.setColor(self.text_r, self.text_g, self.text_b, if (self.enabled) 0.4 else 0.2);
            lbl.paintAt(c, self.x + self.padding, self.y + (input_h - 18.0) * 0.5);
        }

        // Caret, flipping with the open state.
        var caret = Glyph{};
        caret.setGlyph(if (self.open) "expand_less" else "expand_more");
        caret.setSize(kCaretSize);
        caret.setColor(self.text_r, self.text_g, self.text_b, if (self.enabled) 1.0 else 0.38);
        caret.paintAt(c, self.x + self.w - self.padding - kCaretSize, self.y + (input_h - kCaretSize) * 0.5);

        // State layer.
        self.state_layer.setColor(self.text_r, self.text_g, self.text_b);
        self.state_layer.setRadius(r);
        self.state_layer.setGeometry(self.x, self.y, self.w, input_h);
        self.state_layer.setHovered(self.trig_hovered);
        self.state_layer.setPressed(self.trig_pressed);
        self.state_layer.setFocused(self.focused);
        self.state_layer.paint(c, 0);

        // Focus ring.
        self.focus_ring.setFocused(self.focused);
        self.focus_ring.setColor(self.accent_r, self.accent_g, self.accent_b);
        self.focus_ring.setRadius(r);
        self.focus_ring.paint(c, self.x, self.y, self.w, input_h);
    }

    fn paintMenu(self: *Select, c: ?*cairo.cairo_t) void {
        const cr = c orelse return;
        const my = self.dropTop();
        const n = @min(self.options.len, self.max_visible);
        const mh = @as(f32, @floatFromInt(n)) * self.opt_h;

        cairo.cairo_save(cr);

        // Shadow — a rectangle offset down-right, standing in for a real
        // blurred drop shadow that this Cairo setup cannot produce.
        cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0.2);
        cairo.cairo_rectangle(cr, self.x + 2, my + 2, self.w, mh);
        cairo.cairo_fill(cr);

        // Menu background, at the menu's own tighter radius.
        cairo.cairo_set_source_rgba(
            cr,
            self.surface_r * 1.05,
            self.surface_g * 1.05,
            self.surface_b * 1.05,
            1.0,
        );
        cairo.cairo_new_path(cr);
        const r = kMenuRadius;
        cairo.cairo_arc(cr, self.x + r, my + r, r, std.math.pi, 1.5 * std.math.pi);
        cairo.cairo_arc(cr, self.x + self.w - r, my + r, r, 1.5 * std.math.pi, 2.0 * std.math.pi);
        cairo.cairo_arc(cr, self.x + self.w - r, my + mh - r, r, 0.0, 0.5 * std.math.pi);
        cairo.cairo_arc(cr, self.x + r, my + mh - r, r, 0.5 * std.math.pi, std.math.pi);
        cairo.cairo_close_path(cr);
        cairo.cairo_fill(cr);

        cairo.cairo_restore(cr);

        // Rows.
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const iy = my + @as(f32, @floatFromInt(i)) * self.opt_h;

            // Hover wash.
            if (i == self.hovered_idx) {
                cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, 0.08);
                cairo.cairo_rectangle(cr, self.x, iy, self.w, self.opt_h);
                cairo.cairo_fill(cr);
            }

            // Selected indicator — a 3dp bar down the left edge.
            if (i == self.sel) {
                cairo.cairo_set_source_rgba(cr, self.accent_r, self.accent_g, self.accent_b, 0.12);
                cairo.cairo_rectangle(cr, self.x, iy, kIndicatorW, self.opt_h);
                cairo.cairo_fill(cr);
            }

            // Label, one point smaller than the trigger's.
            var lbl = Label{};
            lbl.setText(self.options[i]);
            lbl.setFontSize(self.font_size - 1.0);
            lbl.setColor(self.text_r, self.text_g, self.text_b, 1.0);
            lbl.paintAt(c, self.x + self.padding, iy + (self.opt_h - 16.0) * 0.5);
        }
    }
};

// ————— tests —————

const testing = std.testing;

const kOptions = [_][]const u8{ "Alpha", "Beta", "Gamma", "Delta" };

test "m3-select: menu height is capped by max_visible" {
    const t = testing;
    var sel = Select{};
    sel.setOptions(&kOptions);
    sel.opt_h = 32.0;

    // Four options at 32dp each, no cap in the way.
    sel.setMaxVisible(6);
    try t.expectEqual(@as(f32, 128.0), sel.menuHeight());

    // Capped to two rows — the remaining options are simply not shown, and
    // there is no scrolling to reach them.
    sel.setMaxVisible(2);
    try t.expectEqual(@as(f32, 64.0), sel.menuHeight());
}

test "m3-select: setOptions pulls an out-of-range selection back in" {
    const t = testing;
    var sel = Select{};
    sel.setOptions(&kOptions);
    sel.setSelectedIndex(3);
    try t.expectEqual(@as(usize, 3), sel.selectedIndex());
    try t.expectEqualStrings("Delta", sel.selectedText());

    // Shrinking the list must not leave the index dangling.
    sel.setOptions(kOptions[0..2]);
    try t.expectEqual(@as(usize, 1), sel.selectedIndex());

    // An empty list resolves to "no selection" rather than wrapping around.
    sel.setOptions(&.{});
    try t.expectEqual(Select.kNpos, sel.selectedIndex());
    try t.expectEqualStrings("", sel.selectedText());
}

test "m3-select: pressing the menu selects and closes; release toggles" {
    const t = testing;
    const S = struct {
        var picks: usize = 0;
        var last_idx: usize = 0;
        var last_label: [32]u8 = undefined;
        var last_len: usize = 0;
        fn onSelect(ctx: ?*anyopaque, idx: usize, label: []const u8) void {
            _ = ctx;
            picks += 1;
            last_idx = idx;
            const n = @min(label.len, last_label.len);
            @memcpy(last_label[0..n], label[0..n]);
            last_len = n;
        }
    };
    S.picks = 0;
    S.last_idx = 0;
    S.last_len = 0;

    var sel = Select{};
    sel.setOptions(&kOptions);
    sel.setGeometry(0, 0, 120, 40);
    sel.opt_h = 32.0;
    sel.setOnSelect(S.onSelect);

    // A press on the trigger arms it; the release opens the menu.
    try t.expect(sel.handlePointerDown(10, 20));
    try t.expect(sel.handlePointerUp(10, 20));
    try t.expect(sel.isOpen());

    // Pressing the second row (menu top is 42, so row 1 runs 74..106) selects
    // it at once and closes the menu — selection is on press, not release.
    try t.expect(sel.handlePointerDown(10, 80));
    try t.expectEqual(@as(usize, 1), S.picks);
    try t.expectEqual(@as(usize, 1), S.last_idx);
    try t.expectEqualStrings("Beta", S.last_label[0..S.last_len]);
    try t.expect(!sel.isOpen());
    try t.expectEqualStrings("Beta", sel.selectedText());

    // The release after a menu press finds nothing armed, so it must not
    // reopen the menu.
    try t.expect(!sel.handlePointerUp(10, 80));
    try t.expect(!sel.isOpen());

    // Disabling closes an open menu and refuses to re-open.
    _ = sel.handlePointerDown(10, 20);
    _ = sel.handlePointerUp(10, 20);
    try t.expect(sel.isOpen());
    sel.setEnabled(false);
    try t.expect(!sel.isOpen());
    sel.toggle();
    try t.expect(!sel.isOpen());
}

test "m3-select: pointer move tracks the hovered row" {
    const t = testing;
    var sel = Select{};
    sel.setOptions(&kOptions);
    sel.setGeometry(0, 0, 120, 40);
    sel.opt_h = 32.0;
    sel.open = true;

    // The menu drops 2dp below the 40dp trigger, so row 0 runs 42..74 and
    // row 1 runs 74..106.
    _ = sel.handlePointerMove(10, 80);
    try t.expectEqual(@as(usize, 1), sel.hovered_idx);

    // Outside the menu resolves to nothing.
    _ = sel.handlePointerMove(10, 400);
    try t.expectEqual(Select.kNpos, sel.hovered_idx);

    // While closed, moves never update the hover index.
    sel.close();
    _ = sel.handlePointerMove(10, 80);
    try t.expectEqual(Select.kNpos, sel.hovered_idx);
}

test "m3-select: trigger and open menu paint cleanly" {
    const t = testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 200, 320);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var sel = Select{};
    sel.setOptions(&kOptions);
    sel.setGeometry(10, 10, 160, 40);
    sel.setFocused(true);
    sel.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Open, with a hovered row and one selected.
    sel.open = true;
    sel.setSelectedIndex(1);
    sel.hovered_idx = 2;
    sel.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Nothing selected — the placeholder branch, including its default text.
    var bare = Select{};
    bare.setOptions(&kOptions);
    bare.setGeometry(10, 10, 160, 40);
    bare.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);

    // Disabled dims the trigger.
    var off = Select{};
    off.setOptions(&kOptions);
    off.setEnabled(false);
    off.setGeometry(10, 10, 160, 40);
    off.paint(cr);
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}
