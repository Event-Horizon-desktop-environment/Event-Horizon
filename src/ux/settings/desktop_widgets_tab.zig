const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const ui_widgets = @import("ui_widgets.zig");
const display_picker = @import("display_picker.zig");
const dw_data = @import("desktop_widgets_data.zig");
const dw_persist = @import("desktop_widgets_persist.zig");
const world_clock_popup = @import("world_clock_popup.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;

// Desktop Widgets tab (id 27) — Zig port of
// `settings_tab_desktop_widgets/settings_tab_desktop_widgets.cpp` (+ the
// world-clock popup wiring; the dialog itself lives in
// `world_clock_popup.zig`). Same design: a Display-output card, then a
// widget-list card whose rows carry a drag grip, a 32px icon plate, a
// 52x26 accent toggle, a remove button and — on world_clock rows only — a
// 26px settings cog, plus an "Add widget" button.
//
// Like the C++, every entry point reloads `desktop_widgets_layout.txt`
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
const cog_hit: f64 = 26.0;
const cog_gap: f64 = 8.0;
const right_pad: f64 = 16.0;

const display_card_h: i32 = 52 + 60 + 24; // 136
const display_card_top: i32 = common.content_top + 12; // 28

pub const Geo = struct {
    content_x: i32,
    content_w: i32,
    win_h: i32,
    /// Current vertical scroll: the page paints scrolled, but the
    /// world-clock modal is window-fixed (like the C++, which paints it
    /// outside the scroll translate).
    scroll_px: i32 = 0,
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
    cog_x: f64,
    cog_y: f64,
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
        .cog_x = tx - cog_gap - cog_hit,
        .cog_y = y + @as(f64, row_h) * 0.5 - cog_hit * 0.5,
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
    wc_arena: std.heap.ArenaAllocator = undefined,
    inited: bool = false,
    display_open: bool = false,
    display_hover: i32 = -1,
    wc: world_clock_popup.Popup = .{},

    pub fn init(self: *Page, gpa: std.mem.Allocator, io: std.Io) void {
        if (self.inited) return;
        self.* = .{
            .gpa = gpa,
            .io = io,
            .cfg_arena = std.heap.ArenaAllocator.init(gpa),
            .wc_arena = std.heap.ArenaAllocator.init(gpa),
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
        // The world-clock dialog is a window-space modal; it never extends
        // the scroll extent.
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
        win_w: i32,
        win_h: i32,
    ) void {
        const cr = c orelse return;
        const t = common.Theme;
        const configs = self.loadConfigs();
        const card_x = g.content_x + 8;
        const card_w = g.content_w - 16;

        // Display-output card.
        ui_paint.card(cr, @floatFromInt(card_x), @floatFromInt(display_card_top), @floatFromInt(card_w), @floatFromInt(display_card_h), 1.0);
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
        ui_paint.card(cr, @floatFromInt(card_x), @floatFromInt(cy), @floatFromInt(card_w), @floatFromInt(card_h), 1.0);
        ui_paint.showText(cr, @floatFromInt(card_x + common.card_pad), @floatFromInt(cy + 24), "Desktop widgets", 14, 700, t.text_r, t.text_g, t.text_b, 0.96);

        for (configs, 0..) |cfg, i| {
            self.paintRow(cr, g, cfg, disabled, i, px, py);
        }

        // Add-widget button.
        const add_y = cy + card_h - 16 - add_btn_h - list_pad_b;
        const abx: f64 = @floatFromInt(card_x + 24);
        const hov_add = px >= abx and px < abx + add_btn_w and py >= @as(f64, @floatFromInt(add_y)) and py < @as(f64, @floatFromInt(add_y + add_btn_h));
        ui_paint.paintBtn(cr, card_x + 24, add_y, add_btn_w, add_btn_h, "Add widget", hov_add);
        // Glyph inside the outlined button (C++ sets both glyph + label).
        ui_paint.glyph(cr, abx + 24.0, @as(f64, @floatFromInt(add_y)) + @as(f64, add_btn_h) * 0.5, 18.0, "add", t.text_r, t.text_g, t.text_b, 0.9);

        // World-clock popup paints above the page while open, fixed
        // against the scroll translate (window-space pointer to match).
        if (self.wc.open) {
            cairo.cairo_save(cr);
            cairo.cairo_translate(cr, 0, @as(f64, @floatFromInt(g.scroll_px)));
            self.paintWorldClock(cr, win_w, win_h, px, py - @as(f64, @floatFromInt(g.scroll_px)));
            cairo.cairo_restore(cr);
        }
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
        // Cog on world_clock rows.
        if (std.mem.eql(u8, wid, "world_clock")) {
            const hov_cog = px >= rg.cog_x and px < rg.cog_x + cog_hit and py >= rg.cog_y and py < rg.cog_y + cog_hit;
            ui_paint.glassBox(cr, rg.cog_x, rg.cog_y, cog_hit, cog_hit, 8, t.bg_r, t.bg_g, t.bg_b, if (hov_cog) 0.96 else 0.90);
            ui_paint.glyph(cr, rg.cog_x + cog_hit * 0.5, rg.cog_y + cog_hit * 0.5 + 0.5, cog_hit * 0.62, "settings", t.text_r, t.text_g, t.text_b, if (hov_cog) 0.9 else 0.52);
        }
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
        // Display dropdown first (it swallows while open, like the C++).
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
        for (configs, 0..) |cfg, i| {
            const rg = rowGeom(g.content_x, g.content_w, listY0(), i);
            if (px >= rg.remove_x and px < rg.remove_x + remove_hit and
                ly >= rg.remove_y and ly < rg.remove_y + remove_hit)
            {
                return .{ .remove = i };
            }
            const wid = dw_data.slotId(cfg);
            if (std.mem.eql(u8, wid, "world_clock") and
                px >= rg.cog_x and px < rg.cog_x + cog_hit and
                ly >= rg.cog_y and ly < rg.cog_y + cog_hit)
            {
                self.openWorldClock();
                return null;
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

    /// World-clock modal press. Returns true when consumed.
    pub fn wcDown(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) bool {
        if (!self.wc.open) return false;
        self.wc.just_opened = false;
        const l = world_clock_popup.computeLayout(&self.wc, win_w, win_h);
        self.wc.arm_item = world_clock_popup.hitItem(&self.wc, px, py, l);
        self.wc.search_focus = (self.wc.arm_item == -4);
        return true;
    }

    /// World-clock modal release. Returns true when consumed.
    pub fn wcUp(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) bool {
        if (!self.wc.open) return false;
        if (self.wc.just_opened) {
            self.wc.just_opened = false;
            return true;
        }
        const l = world_clock_popup.computeLayout(&self.wc, win_w, win_h);
        const armed = self.wc.arm_item;
        self.wc.arm_item = -1;
        const item = world_clock_popup.hitItem(&self.wc, px, py, l);
        const inside = px >= l.dlg_x and px <= l.dlg_x + l.dlg_w and py >= l.dlg_y and py <= l.dlg_y + l.dlg_h;
        const was_open = self.wc.open_dropdown >= 0;
        if (item == -1 and inside) {
            if (was_open) {
                self.wc.open_dropdown = -1;
                self.wc.dd_hover = -1;
            }
            return true;
        }
        if (item != armed or !inside) {
            if (!inside) self.closeWorldClock();
            return true;
        }
        if (item == -3) {
            self.closeWorldClock();
        } else if (item == -5) {
            self.wc.search_len = 0;
            world_clock_popup.rebuildFilter(&self.wc, self.wc_arena.allocator());
            self.wc.open_dropdown = -1;
            self.wc.dd_hover = -1;
            self.wc.search_focus = true;
        } else if (item >= 10000) {
            const idx: usize = @intCast(item - 10000);
            const row = self.wc.open_dropdown;
            const list = self.wc.activeList();
            if (row >= 0 and row < self.wc.tzs.items.len and idx < list.len) {
                const picked = list[idx];
                const a = self.wc_arena.allocator();
                self.wc.tzs.items[@intCast(row)] = a.dupe(u8, picked) catch picked;
                self.wc.cities.items[@intCast(row)] = a.dupe(u8, cityLabel(picked)) catch picked;
            }
            self.wc.open_dropdown = -1;
            self.wc.dd_hover = -1;
        } else if (item >= 1) {
            const row = item - 1;
            if (self.wc.open_dropdown == row) {
                self.wc.open_dropdown = -1;
                self.wc.dd_hover = -1;
            } else {
                self.wc.open_dropdown = row;
                self.wc.dd_scroll = 0;
            }
        } else if (item == -2) {
            world_clock_popup.saveConfig(self.gpa, self.io, self.wc.cities.items, self.wc.tzs.items);
            self.closeWorldClock();
        } else {
            if (was_open) {
                self.wc.open_dropdown = -1;
                self.wc.dd_hover = -1;
            }
        }
        return true;
    }

    pub fn wcMotion(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) bool {
        if (!self.wc.open) return false;
        const l = world_clock_popup.computeLayout(&self.wc, win_w, win_h);
        const prev = self.wc.hover_item;
        const cur = world_clock_popup.hitItem(&self.wc, px, py, l);
        self.wc.hover_item = cur;
        if (self.wc.open_dropdown >= 0) {
            const dprev = self.wc.dd_hover;
            self.wc.dd_hover = if (cur >= 10000) cur - 10000 else -1;
            return dprev != self.wc.dd_hover or prev != cur;
        }
        return prev != cur;
    }

    pub fn wcScroll(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64, dy: f64) bool {
        if (!self.wc.open or self.wc.open_dropdown < 0) return false;
        const l = world_clock_popup.computeLayout(&self.wc, win_w, win_h);
        if (px < l.list_x or px >= l.list_x + l.list_w or py < l.list_y or py >= l.list_y + l.list_h)
            return false;
        var steps: i32 = @intFromFloat(@round(dy / world_clock_popup.tz_item_h));
        if (steps < -2) steps = -2;
        if (steps > 2) steps = 2;
        if (steps == 0 and @abs(dy) >= 8.0) steps = if (dy > 0.0) 1 else -1;
        if (steps != 0) {
            self.wc.dd_scroll = std.math.clamp(self.wc.dd_scroll - steps, 0, l.max_scroll);
            return true;
        }
        return true;
    }

    pub fn wcKey(self: *Page, sym: u32, is_repeat: bool, utf8: []const u8) bool {
        if (!self.wc.open) return false;
        _ = is_repeat;
        const esc: u32 = 0xff1b;
        const back: u32 = 0xff08;
        var printable = utf8.len > 0;
        for (utf8) |ch| {
            if (ch < 0x20) {
                printable = false;
                break;
            }
        }
        if (!self.wc.search_focus) {
            if (sym == esc) {
                self.closeWorldClock();
                return true;
            }
            if (!printable) return false;
            self.wc.search_focus = true;
        }
        var changed = false;
        if (sym == esc) {
            if (self.wc.search_len > 0) {
                self.wc.search_len = 0;
                changed = true;
            } else if (self.wc.open_dropdown >= 0) {
                self.wc.open_dropdown = -1;
                self.wc.dd_hover = -1;
                changed = true;
            } else {
                self.closeWorldClock();
                return true;
            }
        } else if (sym == back) {
            if (self.wc.search_len > 0) {
                var n = self.wc.search_len;
                while (n > 0 and (self.wc.search_buf[n - 1] & 0xC0) == 0x80) n -= 1;
                if (n > 0) n -= 1;
                self.wc.search_len = n;
                changed = true;
            }
        } else if (printable) {
            const room = self.wc.search_buf.len - self.wc.search_len;
            const n = @min(room, utf8.len);
            @memcpy(self.wc.search_buf[self.wc.search_len .. self.wc.search_len + n], utf8[0..n]);
            self.wc.search_len += n;
            changed = true;
        }
        if (!changed) return true;
        world_clock_popup.rebuildFilter(&self.wc, self.wc_arena.allocator());
        if (self.wc.search_len > 0 and self.wc.open_dropdown < 0)
            self.wc.open_dropdown = 0;
        self.wc.dd_scroll = 0;
        self.wc.dd_hover = -1;
        return true;
    }

    fn openWorldClock(self: *Page) void {
        self.wc_arena.deinit();
        self.wc_arena = std.heap.ArenaAllocator.init(self.gpa);
        const a = self.wc_arena.allocator();
        self.wc.reset();
        world_clock_popup.loadConfig(a, self.io, &self.wc.cities, &self.wc.tzs);
        if (self.wc.cities.items.len == 0) {
            for ([_][]const u8{ "Cupertino", "Tokyo", "Sydney", "Paris" }) |c| {
                self.wc.cities.append(a, c) catch break;
            }
            for ([_][]const u8{ "America/Los_Angeles", "Asia/Tokyo", "Australia/Sydney", "Europe/Paris" }) |z| {
                self.wc.tzs.append(a, z) catch break;
            }
        }
        if (self.wc.tz_list.items.len == 0)
            world_clock_popup.enumerateZoneinfo(a, self.io, &self.wc.tz_list);
        self.wc.open = true;
        self.wc.just_opened = true;
        self.wc.caret_half = @divTrunc(@as(u64, @intCast(wcMillis())), 530);
    }

    fn closeWorldClock(self: *Page) void {
        self.wc.open = false;
        self.wc.just_opened = false;
        self.wc.hover_item = -1;
        self.wc.arm_item = -1;
        self.wc.open_dropdown = -1;
        self.wc.dd_scroll = 0;
        self.wc.dd_hover = -1;
        self.wc.search_len = 0;
        self.wc.search_focus = false;
        self.wc.tz_filtered.clearRetainingCapacity();
    }

    fn paintWorldClock(
        self: *Page,
        c: ?*cairo.cairo_t,
        win_w: i32,
        win_h: i32,
        px: f64,
        py: f64,
    ) void {
        const cr = c orelse return;
        const t = common.Theme;
        const l = world_clock_popup.computeLayout(&self.wc, win_w, win_h);
        // Dim veil.
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0.38);
        cairo.cairo_rectangle(cr, 0, 0, @floatFromInt(win_w), @floatFromInt(win_h));
        cairo.cairo_fill(cr);
        // Panel.
        ui_paint.glassBox(cr, l.dlg_x, l.dlg_y, l.dlg_w, l.dlg_h, world_clock_popup.panel_r, t.bg_r, t.bg_g, t.bg_b, 0.96);
        // Header.
        const hx = l.dlg_x + 20.0;
        const hy = l.dlg_y + 20.0;
        ui_paint.glassBox(cr, hx, hy + 3.0, world_clock_popup.icon_box_s, world_clock_popup.icon_box_s, 10, t.acc_r * 0.45 + 0.42, t.acc_g * 0.45 + 0.42, t.acc_b * 0.45 + 0.42, 0.85);
        ui_paint.glyph(cr, hx + world_clock_popup.icon_box_s * 0.5, hy + 3.0 + world_clock_popup.icon_box_s * 0.5 + 0.5, world_clock_popup.icon_box_s * 0.6, "public", t.text_r, t.text_g, t.text_b, 0.95);
        ui_paint.showText(cr, hx + world_clock_popup.icon_box_s + 12, hy + 23, "World Clock Settings", 16, 700, t.text_r, t.text_g, t.text_b, 0.95);
        ui_paint.showText(cr, hx + world_clock_popup.icon_box_s + 12, hy + 40, "Timezones shown by the world_clock widget", 11, 400, t.text_r, t.text_g, t.text_b, 0.55);
        // Close.
        const close_x = l.dlg_x + l.dlg_w - 20.0 - world_clock_popup.close_s;
        const close_y = l.dlg_y + 20.0 - 2.0;
        const hov_close = self.wc.hover_item == -3;
        ui_paint.glassBox(cr, close_x, close_y, world_clock_popup.close_s, world_clock_popup.close_s, 6, t.bg_r, t.bg_g, t.bg_b, if (hov_close) 0.30 else 0.08);
        ui_paint.glyph(cr, close_x + world_clock_popup.close_s * 0.5, close_y + world_clock_popup.close_s * 0.5, 20, "close", t.text_r, t.text_g, t.text_b, 1.0);
        // Search field.
        ui_paint.glassBox(cr, l.search_x, l.search_y, l.search_w, l.search_h, 12, t.bg_r * 0.88, t.bg_g * 0.90, t.bg_b * 0.95, 1.0);
        ui_paint.glyph(cr, l.search_x + 18.0, l.search_y + l.search_h * 0.5 + 0.5, 18.0, "search", t.text_r, t.text_g, t.text_b, 0.5);
        const text_x = l.search_x + 46.0;
        const text_y = l.search_y + (l.search_h + 15.0) * 0.5;
        cairo.cairo_save(cr);
        cairo.cairo_rectangle(cr, text_x, l.search_y + 6.0, l.clear_x - 6.0 - text_x, l.search_h - 12.0);
        cairo.cairo_clip(cr);
        if (self.wc.search_len == 0) {
            if (!self.wc.search_focus)
                ui_paint.showText(cr, text_x, text_y, "Search timezone...", 13, 400, t.text_r, t.text_g, t.text_b, 0.42);
        } else {
            ui_paint.showText(cr, text_x, text_y, self.wc.searchSlice(), 13, 400, t.text_r, t.text_g, t.text_b, 0.92);
        }
        if (self.wc.search_focus and caretOn()) {
            const caret_x = text_x + @as(f64, @floatFromInt(ui_paint.textWidthPx(cr, self.wc.searchSlice(), 13, 400))) + 1.5;
            cairo.cairo_set_line_width(cr, 1.6);
            cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.85);
            cairo.cairo_move_to(cr, caret_x, l.search_y + 12.0);
            cairo.cairo_line_to(cr, caret_x, l.search_y + l.search_h - 12.0);
            cairo.cairo_stroke(cr);
        }
        cairo.cairo_restore(cr);
        if (self.wc.search_len > 0) {
            const hov_clear = self.wc.hover_item == -5;
            ui_paint.glassBox(cr, l.clear_x, l.clear_y, world_clock_popup.clear_w, world_clock_popup.clear_h, 13, if (hov_clear) t.acc_r else t.text_r, if (hov_clear) t.acc_g else t.text_g, if (hov_clear) t.acc_b else t.text_b, if (hov_clear) 0.92 else 0.08);
            ui_paint.glyph(cr, l.clear_x + world_clock_popup.clear_w * 0.5, l.clear_y + world_clock_popup.clear_h * 0.5 + 0.5, 16.0, "close", if (hov_clear) 1 else t.text_r, if (hov_clear) 1 else t.text_g, if (hov_clear) 1 else t.text_b, if (hov_clear) 0.95 else 0.65);
        }
        // City rows.
        for (self.wc.cities.items, 0..) |city, i| {
            const row_y = l.rows_y + @as(f64, @floatFromInt(i)) * world_clock_popup.row_h;
            const row_hov = self.wc.hover_item == @as(i32, @intCast(1 + i));
            ui_paint.showText(cr, l.dlg_x + 20.0, row_y + world_clock_popup.row_h * 0.5 + 5.0, city, 14, 600, t.text_r, t.text_g, t.text_b, if (row_hov) 1.0 else 0.92);
            const box_x = l.dlg_x + l.dlg_w - 20.0 - world_clock_popup.box_w;
            const box_y = row_y + (world_clock_popup.row_h - world_clock_popup.box_h) * 0.5;
            var br = t.bg_r * 0.88;
            var bg = t.bg_g * 0.90;
            var bb = t.bg_b * 0.95;
            if (row_hov) {
                br = @min(1.0, br + (t.acc_r - br) * 0.16);
                bg = @min(1.0, bg + (t.acc_g - bg) * 0.16);
                bb = @min(1.0, bb + (t.acc_b - bb) * 0.16);
            }
            ui_paint.glassBox(cr, box_x, box_y, world_clock_popup.box_w, world_clock_popup.box_h, world_clock_popup.card_r, br, bg, bb, 1.0);
            if (row_hov) {
                cairo.cairo_save(cr);
                ui_paint.roundRect(cr, box_x + 0.5, box_y + 0.5, world_clock_popup.box_w - 1.0, world_clock_popup.box_h - 1.0, world_clock_popup.card_r);
                cairo.cairo_set_source_rgba(cr, t.acc_r, t.acc_g, t.acc_b, 0.55);
                cairo.cairo_set_line_width(cr, 1.0);
                cairo.cairo_stroke(cr);
                cairo.cairo_restore(cr);
            }
            if (self.wc.open_dropdown == @as(i32, @intCast(i))) {
                cairo.cairo_save(cr);
                cairo.cairo_set_source_rgba(cr, t.acc_r, t.acc_g, t.acc_b, 0.6);
                cairo.cairo_set_line_width(cr, 1.2);
                ui_paint.roundRect(cr, box_x + 0.5, box_y + 0.5, world_clock_popup.box_w - 1.0, world_clock_popup.box_h - 1.0, world_clock_popup.card_r);
                cairo.cairo_stroke(cr);
                cairo.cairo_restore(cr);
            }
            const tz = if (i < self.wc.tzs.items.len) self.wc.tzs.items[i] else "";
            ui_paint.showText(cr, box_x + 10.0, box_y + world_clock_popup.box_h * 0.5 + 5.0, ellipsize(cr, tz, world_clock_popup.box_w - 36.0), 12, 400, t.text_r, t.text_g, t.text_b, 0.9);
            ui_paint.glyph(cr, box_x + world_clock_popup.box_w - 13.0, box_y + world_clock_popup.box_h * 0.5 + 0.5, 16.0, if (self.wc.open_dropdown == @as(i32, @intCast(i))) "expand_less" else "expand_more", t.text_r, t.text_g, t.text_b, 0.55);
            _ = px;
            _ = py;
        }
        // Dropdown list.
        if (self.wc.open_dropdown >= 0 and l.visible_items > 0) {
            ui_paint.glassBox(cr, l.list_x, l.list_y, l.list_w, l.list_h, 12, t.bg_r * 0.88, t.bg_g * 0.90, t.bg_b * 0.95, 0.98);
            cairo.cairo_save(cr);
            cairo.cairo_rectangle(cr, l.list_x, l.list_y, l.list_w, l.list_h);
            cairo.cairo_clip(cr);
            const list = self.wc.activeList();
            var r: i32 = 0;
            while (r < l.visible_items) : (r += 1) {
                const idx = self.wc.dd_scroll + r;
                if (idx < 0 or idx >= list.len) break;
                const iy = l.list_y + 4.0 + @as(f64, @floatFromInt(r)) * world_clock_popup.tz_item_h;
                if (self.wc.dd_hover == idx) {
                    cairo.cairo_set_source_rgba(cr, t.acc_r, t.acc_g, t.acc_b, 0.18);
                    ui_paint.roundRect(cr, l.list_x + 3.0, iy, l.list_w - 6.0, world_clock_popup.tz_item_h - 2.0, 6.0);
                    cairo.cairo_fill(cr);
                }
                ui_paint.showText(cr, l.list_x + 10.0, iy + 17.0, list[@intCast(idx)], 12, 400, t.text_r, t.text_g, t.text_b, 0.92);
            }
            cairo.cairo_restore(cr);
            if (l.max_scroll > 0) {
                const content_h = @as(f64, @floatFromInt(list.len)) * world_clock_popup.tz_item_h + 8.0;
                const thumb_h = @max(24.0, l.list_h * l.list_h / @max(content_h, l.list_h));
                const norm = @as(f64, @floatFromInt(self.wc.dd_scroll)) / @as(f64, @floatFromInt(l.max_scroll));
                cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.30);
                ui_paint.roundRect(cr, l.list_x + l.list_w - 7.0, l.list_y + (l.list_h - thumb_h) * norm, 4.0, thumb_h, 2.0);
                cairo.cairo_fill(cr);
            }
        }
        // Save button.
        {
            const hov = self.wc.hover_item == -2;
            const ax: f64 = if (hov) @min(1.0, t.acc_r * 1.12) else t.acc_r;
            const ag: f64 = if (hov) @min(1.0, t.acc_g * 1.12) else t.acc_g;
            const ab: f64 = if (hov) @min(1.0, t.acc_b * 1.12) else t.acc_b;
            ui_paint.glassBox(cr, l.done_x, l.done_y, world_clock_popup.done_w, world_clock_popup.done_h, 8, ax, ag, ab, if (hov) 0.95 else 0.9);
            const tw = ui_paint.textWidthPx(cr, "Save", 12, 700);
            ui_paint.showText(cr, l.done_x + (world_clock_popup.done_w - @as(f64, @floatFromInt(tw))) * 0.5, l.done_y + world_clock_popup.done_h * 0.5 + 5.0, "Save", 12, 700, 1, 1, 1, 0.97);
        }
        // Footer.
        {
            const tw = ui_paint.textWidthPx(cr, "Esc or click outside to close", 11, 400);
            ui_paint.showText(cr, l.dlg_x + (l.dlg_w - @as(f64, @floatFromInt(tw))) * 0.5, l.foot_y, "Esc or click outside to close", 11, 400, t.text_r, t.text_g, t.text_b, 0.45);
        }
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

fn cityLabel(tz: []const u8) []const u8 {
    // Set on save; the popup owns a dupe, so returning a slice is fine here
    // only because the caller dupes it (see `wcUp`).
    if (std.mem.lastIndexOfScalar(u8, tz, '/')) |i| return tz[i + 1 ..];
    return tz;
}

fn wcMillis() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * 1000 +
        @as(u64, @intCast(@max(ts.nsec, 0))) / 1_000_000;
}

fn caretOn() bool {
    return wcMillis() / 530 % 2 == 0;
}

var ellipsize_buf: [256]u8 = [_]u8{0} ** 256;

/// Ellipsize to `max_w` px at 12px/400, appending "..." like the C++.
fn ellipsize(c: ?*cairo.cairo_t, tz: []const u8, max_w: f64) []const u8 {
    const cr = c orelse return tz;
    if (@as(f64, @floatFromInt(ui_paint.textWidthPx(cr, tz, 12, 400))) <= max_w) return tz;
    var n = tz.len;
    while (n > 0) {
        const w = ui_paint.textWidthPx(cr, tz[0..n], 12, 400);
        if (@as(f64, @floatFromInt(w)) + @as(f64, @floatFromInt(ui_paint.textWidthPx(cr, "...", 12, 400))) <= max_w) break;
        n -= 1;
    }
    @memcpy(ellipsize_buf[0..n], tz[0..n]);
    @memcpy(ellipsize_buf[n .. n + 3], "...");
    return ellipsize_buf[0 .. n + 3];
}

test "settings-desktop-widgets-tab: geometry follows the specified layout" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 27), tab_id);
    try t.expectEqual(@as(i32, 28), display_card_top);
    try t.expectEqual(@as(i32, 136), display_card_h);
    try t.expectEqual(@as(i32, 176), listCardTop());
    try t.expectEqual(@as(i32, 0), listContentHeight(0));
    try t.expectEqual(@as(i32, 56), listContentHeight(1));
    try t.expectEqual(@as(i32, 120), listContentHeight(2));
    const rg = rowGeom(292, 592, 216, 0);
    try t.expectApproxEqAbs(@as(f64, 292 + 8 + 24), rg.x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 592 - 16 - 48), rg.w, 1e-9);
    try t.expectApproxEqAbs(rg.x + rg.w - 16.0 - 32.0, rg.remove_x, 1e-9);
    try t.expectApproxEqAbs(rg.remove_x - 8.0 - 52.0, rg.toggle_x, 1e-9);
    try t.expectApproxEqAbs(rg.toggle_x - 8.0 - 26.0, rg.cog_x, 1e-9);
    const cb = displayComboRect(292, 592, 80);
    try t.expectEqual(@as(i32, 200), cb.w);
    try t.expectEqual(@as(i32, 28), cb.h);
    try t.expectEqual(@as(i32, 0), selectedIndex("", &.{ "DP-1" }));
    try t.expectEqual(@as(i32, 1), selectedIndex("all", &.{ "DP-1" }));
    try t.expectEqual(@as(i32, 2), selectedIndex("DP-1", &.{ "DP-1" }));
    try t.expectEqual(@as(i32, 0), selectedIndex("NOPE", &.{ "DP-1" }));
}
