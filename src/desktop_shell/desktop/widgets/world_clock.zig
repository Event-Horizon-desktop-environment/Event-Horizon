const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const dw_data = @import("../../../ux/shared/desktop_widgets_data.zig");
const clock_paint = @import("../../widgets/clock/clock_paint.zig");
const cal_card = @import("../../widgets/calendar_card.zig");
const wc_popup = @import("../../../ux/shared/world_clock_popup.zig");
const widget = @import("widget.zig");

// Desktop world-clock widget.
// one analog face (r42) per configured city with day/offset labels below, in
// a glass card. Cities come from the shared WorldClock file (defaults
// seeded when missing); per-city times resolve through the
// shell's timezone helper.

pub const State = struct {
    widget_id: []const u8 = "",
    width: i32 = 0,
    height: i32 = 0,
};

pub fn stateFromConfig(cfg: dw_data.WidgetConfig) State {
    return .{ .widget_id = cfg.id };
}

pub fn refresh(s: *State, io: std.Io) void {
    _ = io;
    _ = s;
}

pub fn ticks(s: *const State) bool {
    _ = s;
    return true;
}

pub fn size(s: *const State) [2]i32 {
    return .{ s.width, s.height };
}

const City = struct {
    label: []const u8,
    tz: []const u8,
    dark: bool,
    hour: u8,
    min: u8,
    sec: u8,
    yday: i32,
    year: i32,
    offset_sec: i64,
};

fn ydayOf(year: i32, mon: u8, mday: u8) i32 {
    const d0 = cal_card.daysFromCivil(year, mon, mday);
    const j0 = cal_card.daysFromCivil(year, 1, 1);
    return @intCast(d0 - j0);
}

fn loadCities(alloc: std.mem.Allocator, io: std.Io, out: *std.ArrayListUnmanaged(City)) void {
    out.clearRetainingCapacity();
    var cities: std.ArrayListUnmanaged([]const u8) = .empty;
    defer cities.deinit(alloc);
    var tzs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer tzs.deinit(alloc);
    wc_popup.loadConfig(alloc, io, &cities, &tzs);
    if (cities.items.len == 0) {
        const defs = [_][2][]const u8{
            .{ "Cupertino", "America/Los_Angeles" },
            .{ "Tokyo", "Asia/Tokyo" },
            .{ "Sydney", "Australia/Sydney" },
            .{ "Paris", "Europe/Paris" },
        };
        for (defs, 0..) |d, i| {
            out.append(alloc, .{ .label = d[0], .tz = d[1], .dark = i > 0, .hour = 0, .min = 0, .sec = 0, .yday = 0, .year = 0, .offset_sec = 0 }) catch break;
        }
        return;
    }
    for (cities.items, 0..) |label, i| {
        if (i >= tzs.items.len) break;
        out.append(alloc, .{ .label = label, .tz = tzs.items[i], .dark = i > 0, .hour = 0, .min = 0, .sec = 0, .yday = 0, .year = 0, .offset_sec = 0 }) catch break;
    }
}

fn resolveCity(c: *City) void {
    const now = clock_paint.nowSeconds();
    if (c.tz.len == 0) {
        if (clock_paint.resolveTime(now, "")) |tm| {
            c.hour = tm.hour;
            c.min = tm.min;
            c.sec = tm.sec;
            c.yday = ydayOf(tm.year, tm.mon +% 1, tm.mday);
            c.year = tm.year;
            c.offset_sec = tm.gmtoff_sec;
        }
        return;
    }
    if (clock_paint.resolveTime(now, c.tz)) |tm| {
        c.hour = tm.hour;
        c.min = tm.min;
        c.sec = tm.sec;
        c.yday = ydayOf(tm.year, tm.mon +% 1, tm.mday);
        c.year = tm.year;
        c.offset_sec = tm.gmtoff_sec;
    } else if (clock_paint.resolveTime(now, "")) |tm| {
        c.hour = tm.hour;
        c.min = tm.min;
        c.sec = tm.sec;
        c.yday = ydayOf(tm.year, tm.mon +% 1, tm.mday);
        c.year = tm.year;
        c.offset_sec = tm.gmtoff_sec;
    }
}

fn drawFace(cr: *cairo.cairo_t, cx: f64, cy: f64, r: f64, hour24: u8, minute: u8, second: u8, dark: bool, ctx: widget.Ctx) void {
    // Dial colors come from the color engine: a light face is the text
    // color with the dock fill as ink, the dark face the reverse.
    const light = [3]f64{ ctx.text_r, ctx.text_g, ctx.text_b };
    const dark_c = [3]f64{ ctx.dock_fill_r, ctx.dock_fill_g, ctx.dock_fill_b };
    const bg = if (dark) dark_c else light;
    const fg = if (dark) light else dark_c;
    cairo.cairo_save(cr);
    cairo.cairo_set_source_rgba(cr, bg[0], bg[1], bg[2], 1.0);
    cairo.cairo_arc(cr, cx, cy, r, 0, std.math.pi * 2.0);
    cairo.cairo_fill(cr);
    if (dark) {
        cairo.cairo_set_source_rgba(cr, fg[0], fg[1], fg[2], 0.25);
        cairo.cairo_set_line_width(cr, 1.0);
        cairo.cairo_arc(cr, cx, cy, r, 0, std.math.pi * 2.0);
        cairo.cairo_stroke(cr);
    }
    var i: i32 = 0;
    while (i < 60) : (i += 1) {
        const angle = (@as(f64, @floatFromInt(i)) * 6.0 - 90.0) * std.math.pi / 180.0;
        const is_hour = @mod(i, 5) == 0;
        const inner_r = if (is_hour) r - r * 0.20 else r - r * 0.10;
        const outer_r = r - 1.5;
        if (!is_hour) {
            cairo.cairo_set_source_rgba(cr, fg[0], fg[1], fg[2], 0.35);
            cairo.cairo_set_line_width(cr, 0.6);
        } else {
            cairo.cairo_set_source_rgba(cr, fg[0], fg[1], fg[2], 0.8);
            cairo.cairo_set_line_width(cr, 1.2);
        }
        cairo.cairo_move_to(cr, cx + outer_r * @cos(angle), cy + outer_r * @sin(angle));
        cairo.cairo_line_to(cr, cx + inner_r * @cos(angle), cy + inner_r * @sin(angle));
        cairo.cairo_stroke(cr);
    }
    // Numerals via pango, centered.
    var n: i32 = 1;
    while (n <= 12) : (n += 1) {
        const angle = (@as(f64, @floatFromInt(n)) * 30.0 - 90.0) * std.math.pi / 180.0;
        const nr = r - r * 0.28;
        var num_buf: [4]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch "?";
        var fd_buf: [32]u8 = undefined;
        const fd = std.fmt.bufPrint(&fd_buf, "Inter Bold {d}", .{@max(1, @as(i32, @intFromFloat(r * 0.20)))}) catch "Inter Bold 8";
        var l = widget.makeLine(cr, fd, num);
        defer l.destroy();
        const px = l.pixelSize();
        widget.showPlain(cr, &l, cx + nr * @cos(angle) - @as(f64, @floatFromInt(px.w)) * 0.5, cy + nr * @sin(angle) - @as(f64, @floatFromInt(px.h)) * 0.5 + 2.0, fg[0], fg[1], fg[2], 0.85);
    }
    const h12: u8 = if (hour24 % 12 == 0) 12 else hour24 % 12;
    const hour_a = (@as(f64, @floatFromInt(h12)) * 30.0 + @as(f64, @floatFromInt(minute)) * 0.5 - 90.0) * std.math.pi / 180.0;
    const min_a = (@as(f64, @floatFromInt(minute)) * 6.0 + @as(f64, @floatFromInt(second)) * 0.1 - 90.0) * std.math.pi / 180.0;
    const sec_a = (@as(f64, @floatFromInt(second)) * 6.0 - 90.0) * std.math.pi / 180.0;
    cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_set_source_rgba(cr, fg[0], fg[1], fg[2], 0.9);
    cairo.cairo_set_line_width(cr, r * 0.065);
    cairo.cairo_move_to(cr, cx, cy);
    cairo.cairo_line_to(cr, cx + r * 0.48 * @cos(hour_a), cy + r * 0.48 * @sin(hour_a));
    cairo.cairo_stroke(cr);
    cairo.cairo_set_source_rgba(cr, fg[0], fg[1], fg[2], 0.85);
    cairo.cairo_set_line_width(cr, r * 0.040);
    cairo.cairo_move_to(cr, cx, cy);
    cairo.cairo_line_to(cr, cx + r * 0.68 * @cos(min_a), cy + r * 0.68 * @sin(min_a));
    cairo.cairo_stroke(cr);
    cairo.cairo_set_source_rgba(cr, ctx.acc_r, ctx.acc_g, ctx.acc_b, 0.9);
    cairo.cairo_set_line_width(cr, r * 0.020);
    cairo.cairo_move_to(cr, cx - r * 0.12 * @cos(sec_a), cy - r * 0.12 * @sin(sec_a));
    cairo.cairo_line_to(cr, cx + r * 0.76 * @cos(sec_a), cy + r * 0.76 * @sin(sec_a));
    cairo.cairo_stroke(cr);
    cairo.cairo_set_source_rgba(cr, fg[0], fg[1], fg[2], 0.95);
    cairo.cairo_arc(cr, cx, cy, r * 0.050, 0, std.math.pi * 2.0);
    cairo.cairo_fill(cr);
    cairo.cairo_restore(cr);
}

fn centeredText(cr: *cairo.cairo_t, str: []const u8, cx: f64, y: f64, px_size: f64, bold: bool, a: f64, ctx: widget.Ctx) void {
    if (str.len == 0) return;
    var fd_buf: [32]u8 = undefined;
    const fd = if (bold)
        std.fmt.bufPrint(&fd_buf, "Inter Bold {d}", .{@as(i32, @intFromFloat(px_size))}) catch "Inter Bold 12"
    else
        std.fmt.bufPrint(&fd_buf, "Inter {d}", .{@as(i32, @intFromFloat(px_size))}) catch "Inter 12";
    var l = widget.makeLine(cr, fd, str);
    defer l.destroy();
    widget.showPlain(cr, &l, cx - @as(f64, @floatFromInt(l.pixelSize().w)) * 0.5, y, ctx.text_r, ctx.text_g, ctx.text_b, a);
}

fn dayLabel(city_yday: i32, city_year: i32, local_yday: i32, local_year: i32) []const u8 {
    if (city_year == local_year) {
        const diff = city_yday - local_yday;
        if (diff == 0) return "Today";
        if (diff == 1) return "Tomorrow";
        if (diff == -1) return "Yesterday";
    }
    return "";
}

fn offsetLabel(buf: []u8, city_off: i64, local_off: i64) []const u8 {
    const diff_h = (@as(f64, @floatFromInt(city_off)) - @as(f64, @floatFromInt(local_off))) / 3600.0;
    if (@abs(diff_h) < 0.01) return "Same";
    const rounded = @round(diff_h * 2.0) / 2.0;
    if (rounded > 0) {
        return std.fmt.bufPrint(buf, "+{d:.1}H", .{rounded}) catch "Same";
    }
    return std.fmt.bufPrint(buf, "{d:.1}H", .{rounded}) catch "Same";
}

pub fn paint(s: *State, cr: ?*cairo.cairo_t, ctx: widget.Ctx) void {
    const c = cr orelse return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var list: std.ArrayListUnmanaged(City) = .empty;
    loadCities(alloc, ctx.io, &list);
    if (list.items.len == 0) return;
    for (list.items) |*city| resolveCity(city);

    var local = City{ .label = "", .tz = "", .dark = false, .hour = 0, .min = 0, .sec = 0, .yday = 0, .year = 0, .offset_sec = 0 };
    resolveCity(&local);

    const us = ctx.ui_scale;
    const n: f64 = @floatFromInt(list.items.len);
    const clock_r = 42.0 * us;
    const cell_w = clock_r * 2.0 + 16.0 * us;
    const cell_gap = 18.0 * us;
    const pad_x = 18.0 * us;
    const pad_y = 16.0 * us;
    const city_font = 14.0 * us;
    const dim_font = 12.0 * us;
    const city_gap = 8.0 * us;
    const line_gap = 2.0 * us;
    const label_h = city_gap + city_font + line_gap + dim_font + line_gap + dim_font + 4.0 * us;
    const total_w = n * cell_w + (n - 1.0) * cell_gap + pad_x * 2.0;
    const total_h = pad_y + clock_r * 2.0 + 4.0 * us + label_h + pad_y;
    s.width = @intFromFloat(@ceil(total_w));
    s.height = @intFromFloat(@ceil(total_h));

    widget.glassCard(c, total_w, total_h, 14.0 * us, ctx, ctx.overlay_widget_card);
    for (list.items, 0..) |*rd, i| {
        const cell_x = pad_x + @as(f64, @floatFromInt(i)) * (cell_w + cell_gap);
        const face_cx = cell_x + cell_w * 0.5;
        const face_cy = pad_y + clock_r;
        drawFace(c, face_cx, face_cy, clock_r, rd.hour, rd.min, rd.sec, rd.dark, ctx);
        const text_y0 = face_cy + clock_r + 4.0 * us + city_gap;
        var cfd_buf: [32]u8 = undefined;
        const cfd = std.fmt.bufPrint(&cfd_buf, "Inter Bold {d}", .{@as(i32, @intFromFloat(city_font))}) catch "Inter Bold 14";
        var cl = widget.makeLine(c, cfd, rd.label);
        defer cl.destroy();
        widget.showPlain(c, &cl, face_cx - @as(f64, @floatFromInt(cl.pixelSize().w)) * 0.5, text_y0 - @as(f64, @floatFromInt(cl.pixelSize().h)) + 2.0, ctx.text_r, ctx.text_g, ctx.text_b, 0.95);
        const day_y = text_y0 + city_font + line_gap;
        centeredText(c, dayLabel(rd.yday, rd.year, local.yday, local.year), face_cx, day_y, dim_font, false, 0.8, ctx);
        const off_y = day_y + dim_font + line_gap;
        var off_buf: [16]u8 = undefined;
        centeredText(c, offsetLabel(&off_buf, rd.offset_sec, local.offset_sec), face_cx, off_y, dim_font, false, 0.8, ctx);
    }
}
