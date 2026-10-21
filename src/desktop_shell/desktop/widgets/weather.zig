const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const dw_data = @import("../../../ux/shared/desktop_widgets_data.zig");
const weather_svc = @import("../../../services/weather.zig");
const glyph = @import("../../common/material_glyph.zig");
const widget = @import("widget.zig");

// Desktop weather widget.
// card (r24), city / big temp + unit / condition / hi-lo lines, accent icon
// medallion on the right, dimmed to 0.45 while the reading is unavailable.

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

fn reading() struct { ok: bool, r: weather_svc.Reading } {
    var r = weather_svc.Reading{};
    if (weather_svc.take(&r)) return .{ .ok = r.available, .r = r };
    return .{ .ok = false, .r = r };
}

pub fn size(s: *const State) [2]i32 {
    return .{ s.width, s.height };
}

pub fn paint(s: *State, cr: ?*cairo.cairo_t, ctx: widget.Ctx) void {
    const c = cr orelse return;
    const rd = reading();
    const ok = rd.ok;
    const r = rd.r;
    const dim_a: f64 = if (ok) 1.0 else 0.45;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const city_full = r.placeName();
    const city: []const u8 = if (std.mem.indexOfScalar(u8, city_full, ',')) |ci| city_full[0..ci] else city_full;
    const temp_txt = std.fmt.allocPrint(alloc, "{d}", .{if (ok) r.temp else 0}) catch "--";
    const temp_show: []const u8 = if (ok) temp_txt else "--";
    var hl_buf: [32]u8 = undefined;
    const hl_txt: []const u8 = if (ok)
        std.fmt.bufPrint(&hl_buf, "H:{d}°  L:{d}°", .{ r.hi, r.lo }) catch "--"
    else
        "--";
    var unit_buf: [8]u8 = undefined;
    const unit_txt = std.fmt.bufPrint(&unit_buf, "°{c}", .{if (r.fahrenheit) @as(u8, 'F') else @as(u8, 'C')}) catch "°C";
    const cond_txt: []const u8 = if (ok) r.conditionText() else "Loading…";

    var city_l = widget.makeLine(c, "Inter SemiBold 13", city);
    defer city_l.destroy();
    var temp_l = widget.makeLine(c, "Inter Light 52", temp_show);
    defer temp_l.destroy();
    var unit_l = widget.makeLine(c, "Inter 15", unit_txt);
    defer unit_l.destroy();
    var cond_l = widget.makeLine(c, "Inter 13", cond_txt);
    defer cond_l.destroy();
    var hl_l = widget.makeLine(c, "Inter 13", hl_txt);
    defer hl_l.destroy();
    const city_px = city_l.pixelSize();
    const temp_px = temp_l.pixelSize();
    const unit_px = unit_l.pixelSize();
    const cond_px = cond_l.pixelSize();
    const hl_px = hl_l.pixelSize();

    const pad = 18.0;
    const icon_px = 54.0;
    const text_w: f64 = @floatFromInt(@max(@max(temp_px.w + unit_px.w, cond_px.w), @max(hl_px.w, city_px.w)));
    s.width = @intFromFloat(@ceil(pad * 2.0 + text_w + 12.0 + icon_px));
    s.height = @intFromFloat(@ceil(pad * 2.0 + (if (city.len > 0) @as(f64, @floatFromInt(city_px.h)) + 6.0 else 0.0) +
        @as(f64, @floatFromInt(temp_px.h)) + 4.0 + @as(f64, @floatFromInt(cond_px.h)) + 4.0 + @as(f64, @floatFromInt(hl_px.h))));

    widget.glassCard(c, @floatFromInt(s.width), @floatFromInt(s.height), 24.0, ctx, 0.92 * ctx.overlay_widget_card * dim_a);

    var y: f64 = pad;
    if (city.len > 0) {
        widget.showPlain(c, &city_l, pad, y, ctx.text_r, ctx.text_g, ctx.text_b, 0.75 * dim_a);
        y += @as(f64, @floatFromInt(city_px.h)) + 6.0;
    }
    widget.showPlain(c, &temp_l, pad, y, ctx.text_r, ctx.text_g, ctx.text_b, 0.95 * dim_a);
    widget.showPlain(c, &unit_l, pad + @as(f64, @floatFromInt(temp_px.w)) + 2.0, y + @as(f64, @floatFromInt(temp_px.h - unit_px.h)) - 2.0, ctx.text_r, ctx.text_g, ctx.text_b, 0.80 * dim_a);
    y += @as(f64, @floatFromInt(temp_px.h)) + 4.0;
    widget.showPlain(c, &cond_l, pad, y, ctx.text_r, ctx.text_g, ctx.text_b, 0.70 * dim_a);
    y += @as(f64, @floatFromInt(cond_px.h)) + 4.0;
    widget.showPlain(c, &hl_l, pad, y, ctx.text_r, ctx.text_g, ctx.text_b, 0.70 * dim_a);

    const icon_cx = pad + text_w + 12.0 + icon_px * 0.5;
    const icon_cy = pad + @as(f64, @floatFromInt(city_px.h)) + 6.0 + @as(f64, @floatFromInt(temp_px.h)) * 0.5;
    cairo.cairo_save(c);
    cairo.cairo_new_path(c);
    cairo.cairo_arc(c, icon_cx, icon_cy, icon_px * 0.5, 0, std.math.pi * 2.0);
    cairo.cairo_set_source_rgba(c, ctx.acc_r, ctx.acc_g, ctx.acc_b, 0.14 * dim_a);
    cairo.cairo_fill(c);
    cairo.cairo_restore(c);
    _ = glyph.draw(c, if (ok) r.glyph else "cloud_off", icon_cx, icon_cy, icon_px, ctx.acc_r, ctx.acc_g, ctx.acc_b, 0.95 * dim_a);
}
