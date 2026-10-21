const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const ui_widgets = @import("ui_widgets.zig");
const display_picker = @import("display_picker.zig");
const dw_data = @import("desktop_widgets_data.zig");
const dw_persist = @import("desktop_widgets_persist.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;

// Desktop Widgets tab (id 27). Settings live in
// `desktop_widgets_layout.txt` (see `desktop_widgets_persist.zig`): a
// Display-output card, then a widget-list card whose rows carry a drag
// grip, a 32px icon plate, a 52x26 accent toggle and a remove button,
// plus an "Add widget" button. World-clock cities are edited in the Time
// tab, not here.
//
// Every entry point reloads `desktop_widgets_layout.txt`
// from disk, so the tab follows external edits while open. Config strings
// live in a per-call arena owned here.

pub const tab_id: i32 = 27;

const row_h: i32 = 56;
const row_gap: i32 = 8;
const add_btn_h: i32 = 40;
const add_btn_w: i32 = 168;
const list_pad_b: i32 = 8;

const toggle_w: f64 = 52.0;
const toggle_h: f64 = 26.0;
const remove_hit: f64 = 32.0;
const toggle_remove_gap: f64 = 8.0;
const right_pad: f64 = 16.0;

const display_card_h: i32 = 52 + 60 + 24; // 136
const display_card_top: i32 = common.content_top + 12; // 60

pub const Geo = struct {
    content_x: i32,
    content_w: i32,
    win_h: i32,
};

pub const Action = union(enum) {
    remove: usize,
    toggle: usize,
    add,
    display_trigger,
    display_pick: usize,
};

pub const RowGeom = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    toggle_x: f64,
    toggle_y: f64,
    remove_x: f64,
    remove_y: f64,
};

pub fn listCardTop() i32 {
    return display_card_top + display_card_h + 12;
}

pub fn listContentHeight(n: usize) i32 {
    if (n == 0) return 0;
    return @as(i32, @intCast(n)) * row_h + (@as(i32, @intCast(n)) - 1) * row_gap;
}

pub fn listCardH(n: usize) i32 {
    return 12 + 20 + 8 + listContentHeight(n) + 18 + add_btn_h + list_pad_b + 16;
}

pub fn listY0() i32 {
    return listCardTop() + 12 + 20 + 8;
}

pub fn rowGeom(content_x: i32, content_w: i32, list_y0: i32, i: usize) RowGeom {
    const card_x: f64 = @floatFromInt(content_x + 8);
    const card_w: f64 = @floatFromInt(content_w - 16);
    const row_x = card_x + 24.0;
    const row_w = card_w - 48.0;
    const y: f64 = @as(f64, @floatFromInt(list_y0)) + @as(f64, @floatFromInt(i)) * @as(f64, row_h + row_gap);
    const rx = row_x + row_w - right_pad - remove_hit;
    const ry = y + @as(f64, row_h) * 0.5 - remove_hit * 0.5;
    const tx = rx - toggle_remove_gap - toggle_w;
    return .{
        .x = row_x,
        .y = y,
        .w = row_w,
        .h = @floatFromInt(row_h),
        .toggle_x = tx,
        .toggle_y = y + @as(f64, row_h) * 0.5 - toggle_h * 0.5,
        .remove_x = rx,
        .remove_y = ry,
    };
}

/// Display-combo trigger rect: right-aligned 200x28 in the 60px band at
/// `bandTop` (`combo_geom` in the shared display-dropdown helper).
pub fn displayComboRect(content_x: i32, content_w: i32, band_top: i32) common.Rect {
    return .{
        .x = content_x + 8 + (content_w - 16) - common.card_pad - common.settings_combo_w,
        .y = band_top + @divTrunc(60 - common.settings_combo_h, 2),
        .w = common.settings_combo_w,
        .h = common.settings_combo_h,
    };
}

pub fn displayBandTop() i32 {
    return display_card_top + 52;
}

pub const Page = struct {
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    cfg_arena: std.heap.ArenaAllocator = undefined,
    inited: bool = false,
    display_open: bool = false,
    display_hover: i32 = -1,

    pub fn init(self: *Page, gpa: std.mem.Allocator, io: std.Io) void {
        if (self.inited) return;
        self.* = .{
            .gpa = gpa,
            .io = io,
            .cfg_arena = std.heap.ArenaAllocator.init(gpa),
            .inited = true,
        };
    }

    fn loadConfigs(self: *Page) []dw_data.WidgetConfig {
        self.cfg_arena.deinit();
        self.cfg_arena = std.heap.ArenaAllocator.init(self.gpa);
        return dw_data.load(self.gpa, self.io, self.cfg_arena.allocator());
    }

    pub fn totalHeight(self: *Page) i32 {
        const configs = self.loadConfigs();
        return listCardTop() + listCardH(configs.len);
    }

    pub fn paint(
        self: *Page,
        c: ?*cairo.cairo_t,
        g: Geo,
        settings_output: []const u8,
        disabled: []const []const u8,
        outputs: []const []const u8,
        px: f64,
        py: f64,
        glass_ov: f64,
    ) void {
        const cr = c orelse return;
        const t = common.Theme;
        const configs = self.loadConfigs();
        const card_x = g.content_x + 8;
        const card_w = g.content_w - 16;

        // Display-output card.
        ui_paint.card(cr, @floatFromInt(card_x), @floatFromInt(display_card_top), @floatFromInt(card_w), @floatFromInt(display_card_h), glass_ov);
        ui_paint.catLabel(cr, @floatFromInt(card_x + common.card_pad), @floatFromInt(display_card_top + 21), "Display");
        ui_paint.showText(cr, @floatFromInt(card_x + common.card_pad), @floatFromInt(display_card_top + 38), "Choose which display desktop widgets appear on.", 11, 400, t.text_r, t.text_g, t.text_b, 0.46);
        const band = displayBandTop();
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.15);
        cairo.cairo_set_line_width(cr, 1.0);
        cairo.cairo_move_to(cr, @floatFromInt(card_x + common.card_pad + 8), @floatFromInt(band));
        cairo.cairo_line_to(cr, @floatFromInt(card_x + card_w - common.card_pad - 8), @floatFromInt(band));
        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
        ui_paint.showText(cr, @floatFromInt(card_x + common.card_pad), @floatFromInt(band + 36), "Display", 14, 500, t.text_r, t.text_g, t.text_b, 0.93);
        ui_paint.showText(cr, @floatFromInt(card_x + common.card_pad), @floatFromInt(band + 53), "Auto = one monitor, All = every display.", 11, 400, t.text_r, t.text_g, t.text_b, 0.46);
        self.paintDisplayCombo(cr, g, settings_output, outputs, px, py);

        // Widget-list card.
        const cy = listCardTop();
        const card_h = listCardH(configs.len);
        ui_paint.card(cr, @floatFromInt(card_x), @floatFromInt(cy), @floatFromInt(card_w), @floatFromInt(card_h), glass_ov);
        ui_paint.showText(cr, @floatFromInt(card_x + common.card_pad), @floatFromInt(cy + 24), "Desktop widgets", 14, 700, t.text_r, t.text_g, t.text_b, 0.96);

        for (configs, 0..) |cfg, i| {
            self.paintRow(cr, g, cfg, disabled, i, px, py);
        }

        // Add-widget button.
        const add_y = cy + card_h - 16 - add_btn_h - list_pad_b;
        const abx: f64 = @floatFromInt(card_x + 24);
        const hov_add = px >= abx and px < abx + add_btn_w and py >= @as(f64, @floatFromInt(add_y)) and py < @as(f64, @floatFromInt(add_y + add_btn_h));
        ui_paint.paintBtn(cr, card_x + 24, add_y, add_btn_w, add_btn_h, "Add widget", hov_add);
        // Glyph inside the outlined button.
        ui_paint.glyph(cr, abx + 24.0, @as(f64, @floatFromInt(add_y)) + @as(f64, add_btn_h) * 0.5, 18.0, "add", t.text_r, t.text_g, t.text_b, 0.9);
    }

    fn paintRow(
        self: *Page,
        c: ?*cairo.cairo_t,
        g: Geo,
        cfg: dw_data.WidgetConfig,
        disabled: []const []const u8,
        i: usize,
        px: f64,
        py: f64,
    ) void {
        const cr = c orelse return;
        const t = common.Theme;
        const rg = rowGeom(g.content_x, g.content_w, listY0(), i);
        _ = self;
        // Row box.
        ui_paint.glassBox(cr, rg.x, rg.y, rg.w, rg.h, 10, t.bg_r, t.bg_g, t.bg_b, 0.90);
        cairo.cairo_save(cr);
        ui_paint.roundRect(cr, rg.x, rg.y, rg.w, rg.h, 10);
        cairo.cairo_set_source_rgba(cr, 1, 1, 1, 0.11);
        cairo.cairo_set_line_width(cr, 1.0);
        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
        // Drag grip (2x3 dots).
        cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.38);
        const grip_cx = rg.x + 8.0;
        const oy0 = rg.y + rg.h * 0.5 - 8.0;
        var gc: i32 = 0;
        while (gc < 2) : (gc += 1) {
            var gr: i32 = 0;
            while (gr < 3) : (gr += 1) {
                cairo.cairo_arc(cr, grip_cx + @as(f64, @floatFromInt(gc)) * 8.0, oy0 + @as(f64, @floatFromInt(gr)) * 8.0, 2.0, 0, std.math.pi * 2.0);
                cairo.cairo_fill(cr);
            }
        }
        // Icon plate + glyph.
        const ix = rg.x + 32.0;
        const iy = rg.y + (rg.h - 32.0) * 0.5;
        ui_paint.glassBox(cr, ix, iy, 32, 32, 8, t.bg_r, t.bg_g, t.bg_b, 0.05);
        const wid = dw_data.slotId(cfg);
        const meta = ui_widgets.widgetMeta(wid);
        ui_paint.glyph(cr, ix + 16.0, iy + 16.5, 23.0, meta.glyph, 0.88, 0.93, 0.96, 0.95);
        // Title (trimmed single line).
        var tbuf: [64]u8 = undefined;
        const title = std.fmt.bufPrint(&tbuf, "{s}", .{meta.title}) catch meta.title;
        ui_paint.showText(cr, ix + 40.0, rg.y + 32.5, title, 13, 700, t.text_r, t.text_g, t.text_b, 1.0);
        // Accent toggle 52x26.
        const on = !isDisabled(disabled, wid);
        const hov_tg = px >= rg.toggle_x and px < rg.toggle_x + toggle_w and py >= rg.toggle_y and py < rg.toggle_y + toggle_h;
        _ = hov_tg;
        paintAccentToggle(cr, rg.toggle_x, rg.toggle_y, on);
        // Remove button.
        const hov_rm = px >= rg.remove_x and px < rg.remove_x + remove_hit and py >= rg.remove_y and py < rg.remove_y + remove_hit;
        ui_paint.glassBox(cr, rg.remove_x, rg.remove_y, remove_hit, remove_hit, 8, t.bg_r, t.bg_g, t.bg_b, if (hov_rm) 0.96 else 0.90);
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, if (hov_rm) 0.9 else 0.52);
        cairo.cairo_set_line_width(cr, 2.0);
        const inset = 8.0;
        cairo.cairo_move_to(cr, rg.remove_x + inset, rg.remove_y + inset);
        cairo.cairo_line_to(cr, rg.remove_x + remove_hit - inset, rg.remove_y + remove_hit - inset);
        cairo.cairo_move_to(cr, rg.remove_x + remove_hit - inset, rg.remove_y + inset);
        cairo.cairo_line_to(cr, rg.remove_x + inset, rg.remove_y + remove_hit - inset);
        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
    }

    fn paintDisplayCombo(
        self: *Page,
        c: ?*cairo.cairo_t,
        g: Geo,
        settings_output: []const u8,
        outputs: []const []const u8,
        px: f64,
        py: f64,
    ) void {
        const cr = c orelse return;
        const t = common.Theme;
        const r = displayComboRect(g.content_x, g.content_w, displayBandTop());
        const idx = selectedIndex(settings_output, outputs);
        var picker = display_picker.DisplayPicker{};
        const disp = picker.labelFor(self.gpa, rowName(outputs, idx)) catch rowName(outputs, idx);
        defer {
            if (disp.ptr != rowName(outputs, idx).ptr) self.gpa.free(disp);
        }
        const hov = px >= @as(f64, @floatFromInt(r.x)) and px < @as(f64, @floatFromInt(r.x + r.w)) and
            py >= @as(f64, @floatFromInt(r.y)) and py < @as(f64, @floatFromInt(r.y + r.h));
        ui_paint.glassBox(cr, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h), 8, 1, 1, 1, if (hov or self.display_open) 0.12 else 0.05);
        cairo.cairo_save(cr);
        ui_paint.roundRect(cr, @as(f64, @floatFromInt(r.x)) + 0.5, @as(f64, @floatFromInt(r.y)) + 0.5, @as(f64, @floatFromInt(r.w)) - 1.0, @as(f64, @floatFromInt(r.h)) - 1.0, 7.5);
        cairo.cairo_set_line_width(cr, 1.0);
        cairo.cairo_set_source_rgba(cr, t.outline_r, t.outline_g, t.outline_b, if (hov or self.display_open) 0.9 else 0.55);
        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
        ui_paint.showText(cr, @as(f64, @floatFromInt(r.x)) + 12, @as(f64, @floatFromInt(r.y + r.h)) - 7.0, disp, 12, 400, t.text_r, t.text_g, t.text_b, 0.9);
        ui_paint.glyph(cr, @as(f64, @floatFromInt(r.x + r.w)) - 14.0, @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h)) * 0.5, 16, "expand_more", t.text_r, t.text_g, t.text_b, 0.9);
        if (!self.display_open) return;
        // Popup rows below the trigger.
        const n: i32 = @intCast(2 + outputs.len);
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            const ry = r.y + r.h + 2 + i * common.settings_dd_row_h;
            const hov_row = px >= @as(f64, @floatFromInt(r.x)) and px < @as(f64, @floatFromInt(r.x + r.w)) and
                py >= @as(f64, @floatFromInt(ry)) and py < @as(f64, @floatFromInt(ry + common.settings_dd_row_h));
            if (i == idx or hov_row or i == self.display_hover) {
                ui_paint.glassBox(cr, @floatFromInt(r.x + 4), @floatFromInt(ry), @floatFromInt(r.w - 8), @floatFromInt(common.settings_dd_row_h), 6, t.acc_r, t.acc_g, t.acc_b, if (i == idx) 0.22 else 0.12);
            }
            ui_paint.showText(cr, @floatFromInt(r.x + 14), @floatFromInt(ry + 18), rowName(outputs, i), 12, if (i == idx) 600 else 400, t.text_r, t.text_g, t.text_b, if (i == idx) 0.95 else 0.8);
        }
    }

    pub fn hit(
        self: *Page,
        g: Geo,
        settings_output: []const u8,
        outputs: []const []const u8,
        px: f64,
        ly: f64,
    ) ?Action {
        const configs = self.loadConfigs();
        // Display dropdown first (it swallows while open).
        const r = displayComboRect(g.content_x, g.content_w, displayBandTop());
        if (self.display_open) {
            const n: i32 = @intCast(2 + outputs.len);
            var i: i32 = 0;
            while (i < n) : (i += 1) {
                const ry = r.y + r.h + 2 + i * common.settings_dd_row_h;
                if (px >= @as(f64, @floatFromInt(r.x)) and px < @as(f64, @floatFromInt(r.x + r.w)) and
                    ly >= @as(f64, @floatFromInt(ry)) and ly < @as(f64, @floatFromInt(ry + common.settings_dd_row_h)))
                {
                    return .{ .display_pick = @intCast(i) };
                }
            }
            if (px >= @as(f64, @floatFromInt(r.x)) and px < @as(f64, @floatFromInt(r.x + r.w)) and
                ly >= @as(f64, @floatFromInt(r.y)) and ly < @as(f64, @floatFromInt(r.y + r.h)))
            {
                return .display_trigger;
            }
            self.display_open = false;
            return null;
        }
        if (px >= @as(f64, @floatFromInt(r.x)) and px < @as(f64, @floatFromInt(r.x + r.w)) and
            ly >= @as(f64, @floatFromInt(r.y)) and ly < @as(f64, @floatFromInt(r.y + r.h)))
        {
            return .display_trigger;
        }
        _ = settings_output;
        for (configs, 0..) |_, i| {
            const rg = rowGeom(g.content_x, g.content_w, listY0(), i);
            if (px >= rg.remove_x and px < rg.remove_x + remove_hit and
                ly >= rg.remove_y and ly < rg.remove_y + remove_hit)
            {
                return .{ .remove = i };
            }
            if (px >= rg.toggle_x and px < rg.toggle_x + toggle_w and
                ly >= rg.toggle_y and ly < rg.toggle_y + toggle_h)
            {
                return .{ .toggle = i };
            }
        }
        // Add-widget button.
        const cy = listCardTop();
        const card_h = listCardH(configs.len);
        const add_y: f64 = @floatFromInt(cy + card_h - 16 - add_btn_h - list_pad_b);
        const abx: f64 = @floatFromInt(g.content_x + 8 + 24);
        if (px >= abx and px < abx + add_btn_w and ly >= add_y and ly < add_y + add_btn_h) {
            return .add;
        }
        return null;
    }

};

fn isDisabled(disabled: []const []const u8, id: []const u8) bool {
    for (disabled) |d| {
        if (std.mem.eql(u8, d, id)) return true;
    }
    return false;
}

/// `settings_draw_widget_accent_toggle`: an `m3::Toggle` at its default
/// Size::M (32x20 track, 16px thumb) centered in the 52x26 hit box.
fn paintAccentToggle(c: ?*cairo.cairo_t, x: f64, y: f64, on: bool) void {
    const cr = c orelse return;
    const t = common.Theme;
    const tw: f64 = 32.0;
    const th: f64 = 20.0;
    const td: f64 = 16.0;
    const tlx = x + (toggle_w - tw) * 0.5;
    const tly = y + (toggle_h - th) * 0.5;
    ui_paint.glassBox(cr, tlx, tly, tw, th, th * 0.5, t.acc_r, t.acc_g, t.acc_b, if (on) 1.0 else 0.0);
    if (!on) {
        ui_paint.glassBox(cr, tlx, tly, tw, th, th * 0.5, 1, 1, 1, 0.06);
        cairo.cairo_save(cr);
        ui_paint.roundRect(cr, tlx + 0.5, tly + 0.5, tw - 1.0, th - 1.0, th * 0.5 - 0.5);
        cairo.cairo_set_line_width(cr, 1.4);
        cairo.cairo_set_source_rgba(cr, t.outline_r, t.outline_g, t.outline_b, 0.8);
        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
    }
    const hr = td * 0.5;
    const hx = if (on) tlx + tw - hr else tlx + hr;
    const hy = tly + th * 0.5;
    if (on) {
        cairo.cairo_set_source_rgba(cr, 1, 1, 1, 1.0);
    } else {
        cairo.cairo_set_source_rgba(cr, t.outline_r, t.outline_g, t.outline_b, 1.0);
    }
    cairo.cairo_arc(cr, hx, hy, hr, 0, std.math.pi * 2.0);
    cairo.cairo_fill(cr);
}

/// Display row index for an output name: 0 Auto, 1 All, 2+i outputs.
fn selectedIndex(output_name: []const u8, outputs: []const []const u8) i32 {
    if (output_name.len == 0) return 0;
    if (std.mem.eql(u8, output_name, "all")) return 1;
    for (outputs, 0..) |o, i| {
        if (std.mem.eql(u8, o, output_name)) return @as(i32, @intCast(i)) + 2;
    }
    return 0;
}

fn rowName(outputs: []const []const u8, idx: i32) []const u8 {
    if (idx == 0) return display_picker.auto_label;
    if (idx == 1) return display_picker.all_label;
    const oi: usize = @intCast(idx - 2);
    if (oi < outputs.len) return outputs[oi];
    return "";
}

test "settings-desktop-widgets-tab: geometry follows the specified layout" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 27), tab_id);
    try t.expectEqual(@as(i32, 60), display_card_top);
    try t.expectEqual(@as(i32, 136), display_card_h);
    try t.expectEqual(@as(i32, 208), listCardTop());
    try t.expectEqual(@as(i32, 0), listContentHeight(0));
    try t.expectEqual(@as(i32, 56), listContentHeight(1));
    try t.expectEqual(@as(i32, 120), listContentHeight(2));
    const rg = rowGeom(292, 592, 216, 0);
    try t.expectApproxEqAbs(@as(f64, 292 + 8 + 24), rg.x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 592 - 16 - 48), rg.w, 1e-9);
    try t.expectApproxEqAbs(rg.x + rg.w - 16.0 - 32.0, rg.remove_x, 1e-9);
    try t.expectApproxEqAbs(rg.remove_x - 8.0 - 52.0, rg.toggle_x, 1e-9);
    const cb = displayComboRect(292, 592, 80);
    try t.expectEqual(@as(i32, 200), cb.w);
    try t.expectEqual(@as(i32, 28), cb.h);
    try t.expectEqual(@as(i32, 0), selectedIndex("", &.{"DP-1"}));
    try t.expectEqual(@as(i32, 1), selectedIndex("all", &.{"DP-1"}));
    try t.expectEqual(@as(i32, 2), selectedIndex("DP-1", &.{"DP-1"}));
    try t.expectEqual(@as(i32, 0), selectedIndex("NOPE", &.{"DP-1"}));
}
