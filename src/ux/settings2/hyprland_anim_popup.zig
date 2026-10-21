const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const hyprland_data = @import("hyprland_data.zig");
const hyprland_tab = @import("hyprland_tab.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;

// Animation entry editor.
// pointer-down, motion). Same design: 340x300 card centered in the content
// box at kContentTop+40, title + close glyph, "Bezier Curve Editor" button,
// Speed stepper + text field, Curve combo + dropdown, Style combo +
// dropdown when the entry has styles.
//
// The entry is `hyprland_tab.anim_edit_idx` (an index into
// `k_anim_entries`, resolved by name — file-vector indices are not reused. All values read/write
// `hyprland_data` by name, so unknown entries survive untouched.

const dd_row_h: i32 = 24;

fn entryName() ?[]const u8 {
    const ei = hyprland_tab.anim_edit_idx;
    if (ei < 0 or ei >= hyprland_data.k_anim_entries.len) return null;
    return hyprland_data.k_anim_entries[@intCast(ei)].name;
}

fn styleCount(name: []const u8) usize {
    // "none" + each style the entry declares.
    var n: usize = 1;
    const raw: []const u8 = blk: {
        for (hyprland_data.k_anim_entries) |e| {
            if (std.mem.eql(u8, e.name, name)) break :blk e.styles;
        }
        break :blk "";
    };
    if (raw.len == 0) return 1;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        if (std.mem.trim(u8, part, " ").len > 0) n += 1;
    }
    return n;
}

fn styleAt(name: []const u8, idx: usize) []const u8 {
    // idx 0 is "none"; the rest follow the entry's style list in order.
    if (idx == 0) return "";
    var want = idx - 1;
    const raw: []const u8 = blk: {
        for (hyprland_data.k_anim_entries) |e| {
            if (std.mem.eql(u8, e.name, name)) break :blk e.styles;
        }
        break :blk "";
    };
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " ");
        if (t.len == 0) continue;
        if (want == 0) return t;
        want -= 1;
    }
    return "";
}

/// Outlined  XS button with a centered glyph (`m3::Button` Style::Outlined
/// + `setGlyph`, as the popup's close/minus/plus buttons use it).
fn iconBtn(
    c: ?*cairo.cairo_t,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    glyph: []const u8,
    px: f64,
    py: f64,
) void {
    const cr = c orelse return;
    const t = common.Theme;
    const hov = px >= @as(f64, @floatFromInt(x)) and px < @as(f64, @floatFromInt(x + w)) and
        py >= @as(f64, @floatFromInt(y)) and py < @as(f64, @floatFromInt(y + h));
    ui_paint.glassBox(cr, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h), 6, t.bg_r, t.bg_g, t.bg_b, if (hov) 0.30 else 0.08);
    cairo.cairo_save(cr);
    ui_paint.roundRect(cr, @as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5, @as(f64, @floatFromInt(w)) - 1.0, @as(f64, @floatFromInt(h)) - 1.0, 5.5);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_set_source_rgba(cr, t.outline_r, t.outline_g, t.outline_b, 1.0);
    cairo.cairo_stroke(cr);
    cairo.cairo_restore(cr);
    if (hov) ui_paint.glassBox(cr, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h), 6, t.acc_r, t.acc_g, t.acc_b, 0.08);
    ui_paint.glyph(cr, @as(f64, @floatFromInt(x)) + @as(f64, @floatFromInt(w)) * 0.5, @as(f64, @floatFromInt(y)) + @as(f64, @floatFromInt(h)) * 0.5, 20, glyph, t.text_r, t.text_g, t.text_b, 1.0);
}

fn drawChevron(c: ?*cairo.cairo_t, x: i32, y: i32) void {
    const cr = c orelse return;
    const t = common.Theme;
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    cairo.cairo_save(cr);
    cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.50);
    cairo.cairo_move_to(cr, xf, yf - 3);
    cairo.cairo_line_to(cr, xf + 8, yf - 3);
    cairo.cairo_line_to(cr, xf + 4, yf + 3);
    cairo.cairo_close_path(cr);
    cairo.cairo_fill(cr);
    cairo.cairo_restore(cr);
}

pub fn paint(content_x: i32, content_w: i32, px: f64, py: f64, c: ?*cairo.cairo_t, glass_ov: f64) void {
    const name = entryName() orelse return;
    const cr = c orelse return;
    const t = common.Theme;
    const r = hyprland_tab.animPopupRect(content_x, content_w);
    const pop_x = r.x;
    const pop_y = r.y;
    const pop_w = r.w;

    ui_paint.card(cr, @floatFromInt(pop_x), @floatFromInt(pop_y), @floatFromInt(pop_w), @floatFromInt(r.h), glass_ov);
    ui_paint.showText(cr, @floatFromInt(pop_x + 16), @floatFromInt(pop_y + 22), name, 14, 400, t.text_r, t.text_g, t.text_b, 0.93);
    iconBtn(c, pop_x + pop_w - 32, pop_y + 8, 20, 20, "close", px, py);

    var ry = pop_y + 50;
    // Bezier Curve Editor button.
    ui_paint.paintBtn(cr, pop_x + 16, ry, pop_w - 32, 28, "Bezier Curve Editor", px >= @as(f64, @floatFromInt(pop_x + 16)) and px < @as(f64, @floatFromInt(pop_x + pop_w - 16)) and py >= @as(f64, @floatFromInt(ry)) and py < @as(f64, @floatFromInt(ry + 28)));
    ry += 42;

    // Speed row.
    ui_paint.showText(cr, @floatFromInt(pop_x + 16), @floatFromInt(ry + 14), "Speed:", 12, 400, t.text_r, t.text_g, t.text_b, 0.70);
    iconBtn(c, pop_x + 72, ry - 2, 28, 28, "remove", px, py);
    const speed_x = pop_x + 104;
    const speed_w = pop_w - 104 - 56;
    cairo.cairo_save(cr);
    cairo.cairo_set_source_rgba(cr, t.bg_r, t.bg_g, t.bg_b, if (hyprland_tab.anim_speed_active) 0.30 else 0.15);
    cairo.cairo_rectangle(cr, @floatFromInt(speed_x), @floatFromInt(ry - 2), @floatFromInt(speed_w), 28);
    cairo.cairo_fill(cr);
    cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.50);
    cairo.cairo_set_line_width(cr, 1);
    cairo.cairo_rectangle(cr, @floatFromInt(speed_x), @floatFromInt(ry - 2), @floatFromInt(speed_w), 28);
    cairo.cairo_stroke(cr);
    cairo.cairo_restore(cr);
    var sp_buf: [32]u8 = undefined;
    const sp_txt: []const u8 = if (hyprland_tab.anim_speed_active)
        hyprland_tab.animSpeedSlice()
    else
        std.fmt.bufPrint(&sp_buf, "{d:.1}", .{hyprland_data.animSpeed(name)}) catch "";
    ui_paint.showText(cr, @floatFromInt(speed_x + 8), @floatFromInt(ry + 18), sp_txt, 13, 400, t.text_r, t.text_g, t.text_b, 0.85);
    iconBtn(c, pop_x + pop_w - 16 - 28, ry - 2, 28, 28, "add", px, py);
    ry += 40;

    // Curve row.
    const curve = hyprland_data.animCurve(name);
    ui_paint.showText(cr, @floatFromInt(pop_x + 16), @floatFromInt(ry + 14), "Curve:", 12, 400, t.text_r, t.text_g, t.text_b, 0.70);
    const cb_x = pop_x + 72;
    const cb_w = pop_w - 72 - 16;
    const cb_h = common.settings_combo_h;
    cairo.cairo_save(cr);
    cairo.cairo_set_source_rgba(cr, t.bg_r, t.bg_g, t.bg_b, if (hyprland_tab.anim_curve_open) 0.30 else 0.15);
    cairo.cairo_rectangle(cr, @floatFromInt(cb_x), @floatFromInt(ry - 2), @floatFromInt(cb_w), @floatFromInt(cb_h));
    cairo.cairo_fill(cr);
    cairo.cairo_restore(cr);
    ui_paint.showText(cr, @floatFromInt(cb_x + 8), @floatFromInt(ry + @divTrunc(cb_h, 2) + 4), curve, 11, 400, t.text_r, t.text_g, t.text_b, 0.50);
    drawChevron(c, cb_x + cb_w - 16, ry + @divTrunc(cb_h, 2));
    if (hyprland_tab.anim_curve_open) {
        const dd_top = ry + cb_h + 2;
        const dd_h: i32 = @as(i32, @intCast(hyprland_data.k_curve_names.len)) * dd_row_h;
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, t.bg_r, t.bg_g, t.bg_b, 0.95);
        cairo.cairo_rectangle(cr, @floatFromInt(cb_x), @floatFromInt(dd_top), @floatFromInt(cb_w), @floatFromInt(dd_h));
        cairo.cairo_fill(cr);
        cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.50);
        cairo.cairo_set_line_width(cr, 1);
        cairo.cairo_rectangle(cr, @floatFromInt(cb_x), @floatFromInt(dd_top), @floatFromInt(cb_w), @floatFromInt(dd_h));
        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
        for (hyprland_data.k_curve_names, 0..) |cn, i| {
            const row_y = dd_top + @as(i32, @intCast(i)) * dd_row_h;
            if (@as(i32, @intCast(i)) == hyprland_tab.anim_curve_hover) {
                ui_paint.glassBox(cr, @floatFromInt(cb_x), @floatFromInt(row_y), @floatFromInt(cb_w), @floatFromInt(dd_row_h), 0, t.acc_r, t.acc_g, t.acc_b, 0.20);
            }
            ui_paint.showText(cr, @floatFromInt(cb_x + 8), @floatFromInt(row_y + @divTrunc(dd_row_h, 2) + 4), cn, 11, 400, t.text_r, t.text_g, t.text_b, 0.70);
            if (std.mem.eql(u8, curve, cn)) {
                ui_paint.showText(cr, @floatFromInt(cb_x + cb_w - 20), @floatFromInt(row_y + @divTrunc(dd_row_h, 2) + 4), "✓", 11, 400, t.acc_r, t.acc_g, t.acc_b, 0.80);
            }
        }
    }
    ry += cb_h + 12;

    // Style row (only when the entry declares styles).
    if (styleCount(name) > 1) {
        const style = hyprland_data.animStyle(name);
        ui_paint.showText(cr, @floatFromInt(pop_x + 16), @floatFromInt(ry + 14), "Style:", 12, 400, t.text_r, t.text_g, t.text_b, 0.70);
        const st_x = pop_x + 72;
        const st_w = pop_w - 72 - 16;
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, t.bg_r, t.bg_g, t.bg_b, if (hyprland_tab.anim_style_open) 0.30 else 0.15);
        cairo.cairo_rectangle(cr, @floatFromInt(st_x), @floatFromInt(ry - 2), @floatFromInt(st_w), @floatFromInt(cb_h));
        cairo.cairo_fill(cr);
        cairo.cairo_restore(cr);
        const disp: []const u8 = if (style.len == 0) "none" else style;
        ui_paint.showText(cr, @floatFromInt(st_x + 8), @floatFromInt(ry + @divTrunc(cb_h, 2) + 4), disp, 11, 400, t.text_r, t.text_g, t.text_b, 0.50);
        drawChevron(c, st_x + st_w - 16, ry + @divTrunc(cb_h, 2));
        if (hyprland_tab.anim_style_open) {
            const dd_top = ry + cb_h + 2;
            const n: i32 = @intCast(styleCount(name));
            const dd_h = n * dd_row_h;
            cairo.cairo_save(cr);
            cairo.cairo_set_source_rgba(cr, t.bg_r, t.bg_g, t.bg_b, 0.95);
            cairo.cairo_rectangle(cr, @floatFromInt(st_x), @floatFromInt(dd_top), @floatFromInt(st_w), @floatFromInt(dd_h));
            cairo.cairo_fill(cr);
            cairo.cairo_set_source_rgba(cr, t.text_r, t.text_g, t.text_b, 0.50);
            cairo.cairo_set_line_width(cr, 1);
            cairo.cairo_rectangle(cr, @floatFromInt(st_x), @floatFromInt(dd_top), @floatFromInt(st_w), @floatFromInt(dd_h));
            cairo.cairo_stroke(cr);
            cairo.cairo_restore(cr);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const row_y = dd_top + @as(i32, @intCast(i)) * dd_row_h;
                if (@as(i32, @intCast(i)) == hyprland_tab.anim_style_hover) {
                    ui_paint.glassBox(cr, @floatFromInt(st_x), @floatFromInt(row_y), @floatFromInt(st_w), @floatFromInt(dd_row_h), 0, t.acc_r, t.acc_g, t.acc_b, 0.20);
                }
                const opt: []const u8 = if (i == 0) "none" else styleAt(name, i);
                ui_paint.showText(cr, @floatFromInt(st_x + 8), @floatFromInt(row_y + @divTrunc(dd_row_h, 2) + 4), opt, 11, 400, t.text_r, t.text_g, t.text_b, 0.70);
                const sel = (i == 0 and style.len == 0) or (i > 0 and std.mem.eql(u8, style, opt));
                if (sel) {
                    ui_paint.showText(cr, @floatFromInt(st_x + st_w - 20), @floatFromInt(row_y + @divTrunc(dd_row_h, 2) + 4), "✓", 11, 400, t.acc_r, t.acc_g, t.acc_b, 0.80);
                }
            }
        }
    }
}

fn inRect(px: f64, py: f64, x: i32, y: i32, w: i32, h: i32) bool {
    return px >= @as(f64, @floatFromInt(x)) and px < @as(f64, @floatFromInt(x + w)) and
        py >= @as(f64, @floatFromInt(y)) and py < @as(f64, @floatFromInt(y + h));
}

/// Pointer-down. Returns true when the press was consumed (the window must
/// then repaint and skip content hit-testing). Commits config on every
/// accepted value edit, like `hyprland_commit_cfg`.
pub fn hitDown(content_x: i32, content_w: i32, px: f64, py: f64, commit: *bool) bool {
    const name = entryName() orelse return false;
    const r = hyprland_tab.animPopupRect(content_x, content_w);
    const pop_x = r.x;
    const pop_y = r.y;
    const pop_w = r.w;
    const pop_h = r.h;
    const cb_h = common.settings_combo_h;

    const bezier_y = pop_y + 50;
    const speed_y = bezier_y + 42;
    const curve_y = speed_y + 40;
    const style_y = curve_y + cb_h + 12;
    const cb_x = pop_x + 72;
    const cb_w = pop_w - 72 - 16;

    const inside = inRect(px, py, pop_x, pop_y, pop_w, pop_h);
    var in_curve_dd = false;
    if (hyprland_tab.anim_curve_open) {
        const dd_top = curve_y + cb_h + 2;
        const dd_h: i32 = @as(i32, @intCast(hyprland_data.k_curve_names.len)) * dd_row_h;
        in_curve_dd = inRect(px, py, cb_x, dd_top, cb_w, dd_h);
    }
    var in_style_dd = false;
    if (hyprland_tab.anim_style_open) {
        const n: i32 = @intCast(styleCount(name));
        const dd_top = style_y + cb_h + 2;
        in_style_dd = inRect(px, py, cb_x, dd_top, cb_w, n * dd_row_h);
    }
    if (!inside and !in_curve_dd and !in_style_dd) {
        hyprland_tab.anim_edit_idx = -1;
        hyprland_tab.anim_speed_active = false;
        hyprland_tab.anim_curve_open = false;
        hyprland_tab.anim_curve_hover = -1;
        hyprland_tab.anim_style_open = false;
        hyprland_tab.anim_style_hover = -1;
        return true;
    }
    // Close glyph.
    if (inRect(px, py, pop_x + pop_w - 32, pop_y + 8, 20, 20)) {
        hyprland_tab.anim_edit_idx = -1;
        hyprland_tab.anim_speed_active = false;
        return true;
    }
    // Bezier Curve Editor button.
    if (inRect(px, py, pop_x + 16, bezier_y, pop_w - 32, 28)) {
        if (hyprland_data.bezierForCurve(hyprland_data.animCurve(name))) |bz| {
            hyprland_tab.bezier_p1x = bz.p1x;
            hyprland_tab.bezier_p1y = bz.p1y;
            hyprland_tab.bezier_p2x = bz.p2x;
            hyprland_tab.bezier_p2y = bz.p2y;
        } else {
            hyprland_tab.bezier_p1x = 0.25;
            hyprland_tab.bezier_p1y = 0.1;
            hyprland_tab.bezier_p2x = 0.25;
            hyprland_tab.bezier_p2y = 1.0;
        }
        hyprland_tab.bezier_open = true;
        hyprland_tab.bezier_drag = -1;
        hyprland_tab.anim_curve_open = false;
        hyprland_tab.anim_curve_hover = -1;
        hyprland_tab.anim_style_open = false;
        hyprland_tab.anim_style_hover = -1;
        return true;
    }
    // Speed minus.
    if (inRect(px, py, pop_x + 72, speed_y - 2, 28, 28)) {
        var v = hyprland_data.animSpeed(name) - 0.5;
        if (v < 0.5) v = 0.5;
        if (v < 0.1) v = 0.5;
        hyprland_data.setAnimSpeed(name, v);
        hyprland_tab.anim_speed_active = false;
        commit.* = true;
        return true;
    }
    // Speed text field.
    const speed_x = pop_x + 104;
    const speed_w = pop_w - 104 - 56;
    if (inRect(px, py, speed_x, speed_y - 2, speed_w, 28)) {
        hyprland_tab.anim_speed_active = true;
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.1}", .{hyprland_data.animSpeed(name)}) catch "";
        hyprland_tab.setAnimSpeedBuf(s);
        return true;
    }
    // Speed plus.
    if (inRect(px, py, pop_x + pop_w - 16 - 28, speed_y - 2, 28, 28)) {
        hyprland_data.setAnimSpeed(name, @min(30.0, hyprland_data.animSpeed(name) + 0.5));
        hyprland_tab.anim_speed_active = false;
        commit.* = true;
        return true;
    }
    // Curve combo box.
    if (inRect(px, py, cb_x, curve_y - 2, cb_w, cb_h)) {
        if (hyprland_tab.anim_curve_open) {
            if (hyprland_tab.anim_curve_hover >= 0 and hyprland_tab.anim_curve_hover < hyprland_data.k_curve_names.len) {
                hyprland_data.setAnimCurve(name, hyprland_data.k_curve_names[@intCast(hyprland_tab.anim_curve_hover)]);
                commit.* = true;
            }
            hyprland_tab.anim_curve_open = false;
            hyprland_tab.anim_curve_hover = -1;
        } else {
            hyprland_tab.anim_curve_open = true;
            hyprland_tab.anim_style_open = false;
            hyprland_tab.anim_style_hover = -1;
        }
        return true;
    }
    // Style combo box.
    if (styleCount(name) > 1 and inRect(px, py, cb_x, style_y - 2, cb_w, cb_h)) {
        const n: i32 = @intCast(styleCount(name));
        if (hyprland_tab.anim_style_open) {
            if (hyprland_tab.anim_style_hover >= 0 and hyprland_tab.anim_style_hover < n) {
                hyprland_data.setAnimStyle(name, styleAt(name, @intCast(hyprland_tab.anim_style_hover)));
                commit.* = true;
            }
            hyprland_tab.anim_style_open = false;
            hyprland_tab.anim_style_hover = -1;
        } else {
            hyprland_tab.anim_style_open = true;
            hyprland_tab.anim_curve_open = false;
            hyprland_tab.anim_curve_hover = -1;
        }
        return true;
    }
    // Curve dropdown rows.
    if (hyprland_tab.anim_curve_open) {
        const dd_top = curve_y + cb_h + 2;
        const dd_h: i32 = @as(i32, @intCast(hyprland_data.k_curve_names.len)) * dd_row_h;
        if (inRect(px, py, cb_x, dd_top, cb_w, dd_h)) {
            const idx = @divTrunc(@as(i32, @intFromFloat(py)) - dd_top, dd_row_h);
            if (idx >= 0 and idx < hyprland_data.k_curve_names.len) {
                hyprland_data.setAnimCurve(name, hyprland_data.k_curve_names[@intCast(idx)]);
                commit.* = true;
            }
            hyprland_tab.anim_curve_open = false;
            hyprland_tab.anim_curve_hover = -1;
            return true;
        }
    }
    // Style dropdown rows.
    if (hyprland_tab.anim_style_open) {
        const n: i32 = @intCast(styleCount(name));
        const dd_top = style_y + cb_h + 2;
        if (inRect(px, py, cb_x, dd_top, cb_w, n * dd_row_h)) {
            const idx = @divTrunc(@as(i32, @intFromFloat(py)) - dd_top, dd_row_h);
            if (idx >= 0 and idx < n) {
                hyprland_data.setAnimStyle(name, styleAt(name, @intCast(idx)));
                commit.* = true;
            }
            hyprland_tab.anim_style_open = false;
            hyprland_tab.anim_style_hover = -1;
            return true;
        }
    }
    return false;
}

/// Pointer motion: dropdown hover rows. Returns true when hover moved.
pub fn motion(content_x: i32, content_w: i32, px: f64, py: f64) bool {
    const name = entryName() orelse {
        var changed = false;
        if (hyprland_tab.anim_curve_hover != -1) {
            hyprland_tab.anim_curve_hover = -1;
            changed = true;
        }
        if (hyprland_tab.anim_style_hover != -1) {
            hyprland_tab.anim_style_hover = -1;
            changed = true;
        }
        return changed;
    };
    const r = hyprland_tab.animPopupRect(content_x, content_w);
    const cb_h = common.settings_combo_h;
    const curve_y = r.y + 132;
    const style_y = curve_y + cb_h + 12;
    const cb_x = r.x + 72;
    const cb_w = r.w - 72 - 16;
    var changed = false;
    if (hyprland_tab.anim_curve_open) {
        const dd_top = curve_y + cb_h + 2;
        const nr = ddRow(px, py, cb_x, dd_top, cb_w, hyprland_data.k_curve_names.len);
        if (nr != hyprland_tab.anim_curve_hover) {
            hyprland_tab.anim_curve_hover = nr;
            changed = true;
        }
    } else if (hyprland_tab.anim_curve_hover != -1) {
        hyprland_tab.anim_curve_hover = -1;
        changed = true;
    }
    if (hyprland_tab.anim_style_open) {
        const dd_top = style_y + cb_h + 2;
        const nr = ddRow(px, py, cb_x, dd_top, cb_w, styleCount(name));
        if (nr != hyprland_tab.anim_style_hover) {
            hyprland_tab.anim_style_hover = nr;
            changed = true;
        }
    } else if (hyprland_tab.anim_style_hover != -1) {
        hyprland_tab.anim_style_hover = -1;
        changed = true;
    }
    return changed;
}

fn ddRow(px: f64, py: f64, x: i32, top: i32, w: i32, n: usize) i32 {
    if (!inRect(px, py, x, top, w, @as(i32, @intCast(n)) * dd_row_h)) return -1;
    return @divTrunc(@as(i32, @intFromFloat(py)) - top, dd_row_h);
}

test "settings-hyprland-anim-popup: style tables" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 1), styleCount("global"));
    try t.expectEqual(@as(usize, 3), styleCount("windowsIn"));
    try t.expectEqualStrings("", styleAt("windowsIn", 0));
    try t.expectEqualStrings("slide", styleAt("windowsIn", 1));
    try t.expectEqualStrings("slidevert", styleAt("windowsIn", 2));
    try t.expectEqualStrings("popin", styleAt("fadePopupsIn", 1));
}
