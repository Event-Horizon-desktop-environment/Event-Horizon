const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const dw_data = @import("../../../ux/shared/desktop_widgets_data.zig");
const clock_paint = @import("../../widgets/clock/clock_paint.zig");
const desktop_clock = @import("../clock.zig");
const widget = @import("widget.zig");

// Desktop clock widget.
// (r26), Inter Light time + 30% date below an 8px gap, shadowed white text,
// size measured from the laid-out lines.

pub const State = struct {
    format: []const u8 = "",
    show_seconds: bool = false,
    show_date: bool = true,
    font_size: i32 = 64,
    width: i32 = 0,
    height: i32 = 0,
};

pub fn stateFromConfig(cfg: dw_data.WidgetConfig) State {
    return .{
        .format = cfg.time_format,
        .show_seconds = cfg.show_seconds,
        .show_date = cfg.show_date,
        .font_size = if (cfg.font_size > 0) cfg.font_size else 64,
    };
}

pub fn refresh(s: *State, io: std.Io) void {
    _ = io;
    _ = s;
}

pub fn ticks(s: *const State) bool {
    return s.show_seconds or s.show_date;
}

fn isStdFormat(format: []const u8) bool {
    return std.mem.eql(u8, format, "%H:%M") or std.mem.eql(u8, format, "%H:%M:%S") or
        std.mem.eql(u8, format, "%I:%M %p") or std.mem.eql(u8, format, "%I:%M:%S %p");
}

/// Expand the four standard formats from a broken-down time.
fn expandStd(out: *[128]u8, fmt: []const u8, tm: clock_paint.BrokenTime) []const u8 {
    var n: usize = 0;
    const put = struct {
        fn b(o: *[128]u8, nn: *usize, ch: u8) void {
            if (nn.* < o.len) {
                o[nn.*] = ch;
                nn.* += 1;
            }
        }
        fn two(o: *[128]u8, nn: *usize, v: u8) void {
            b(o, nn, '0' + @divTrunc(v, 10));
            b(o, nn, '0' + @mod(v, 10));
        }
        fn str(o: *[128]u8, nn: *usize, s: []const u8) void {
            for (s) |ch| b(o, nn, ch);
        }
    };
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            const h12: u8 = if (tm.hour % 12 == 0) 12 else tm.hour % 12;
            switch (fmt[i + 1]) {
                'H' => put.two(out, &n, tm.hour),
                'M' => put.two(out, &n, tm.min),
                'S' => put.two(out, &n, tm.sec),
                'I' => put.two(out, &n, h12),
                'p' => put.str(out, &n, if (tm.hour < 12) "AM" else "PM"),
                else => {
                    put.b(out, &n, fmt[i]);
                    put.b(out, &n, fmt[i + 1]);
                },
            }
            i += 2;
        } else {
            put.b(out, &n, fmt[i]);
            i += 1;
        }
    }
    return out[0..n];
}

pub fn size(s: *const State) [2]i32 {
    return .{ s.width, s.height };
}

pub fn paint(s: *State, cr: ?*cairo.cairo_t, ctx: widget.Ctx) void {
    const c = cr orelse return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const now = clock_paint.nowSeconds();
    const tm = clock_paint.resolveTime(now, ctx.timezone) orelse {
        s.width = 200;
        s.height = 100;
        return;
    };

    // Time line: per-widget custom format wins unless it is one of the four
    // standard ones (then the shell format applies, as in `build_clock_text`).
    var time_buf: [128]u8 = undefined;
    const time_txt: []const u8 = blk: {
        if (s.format.len > 0 and !isStdFormat(s.format)) {
            break :blk clock_paint.renderCustom(alloc, tm, s.format) catch "??:??";
        }
        if (ctx.custom_format.len > 0) {
            break :blk clock_paint.renderCustom(alloc, tm, ctx.custom_format) catch "??:??";
        }
        const fmt: []const u8 = if (ctx.use_24h)
            (if (ctx.show_seconds) "%H:%M:%S" else "%H:%M")
        else
            (if (ctx.show_seconds) "%I:%M:%S %p" else "%I:%M %p");
        break :blk expandStd(&time_buf, fmt, tm);
    };

    // Date line (`append_date_formatted` via `desktop/clock.zig`).
    const date_txt: []const u8 = if (ctx.show_date)
        desktop_clock.formatDate(alloc, tm.wday, tm.mday, tm.mon, tm.year, desktop_clock.dateStyle(ctx.date_format)) catch ""
    else
        "";

    const time_px_size: i32 = @max(1, s.font_size);
    const date_px_size: i32 = @max(1, @divTrunc(time_px_size * 30, 100));
    var time_fd_buf: [32]u8 = undefined;
    const time_fd = std.fmt.bufPrint(&time_fd_buf, "Inter Light {d}", .{time_px_size}) catch "Inter Light 64";
    var time_l = widget.makeLine(c, time_fd, time_txt);
    defer time_l.destroy();
    const time_px = time_l.pixelSize();

    var date_l = widget.makeLine(c, "Inter 12", date_txt);
    defer date_l.destroy();
    if (date_txt.len > 0) {
        var date_fd_buf: [32]u8 = undefined;
        const date_fd = std.fmt.bufPrint(&date_fd_buf, "Inter {d}", .{date_px_size}) catch "Inter 12";
        date_l.setFont(date_fd);
        date_l.setText(date_txt);
    }
    const date_px = date_l.pixelSize();

    const us = ctx.ui_scale;
    const pad: f64 = 20.0 * us;
    const content_w = @max(time_px.w, date_px.w);
    const content_h = time_px.h + (if (date_txt.len > 0) @as(i32, @intFromFloat(8.0 * us)) + date_px.h else 0);
    s.width = @intFromFloat(@ceil(@as(f64, @floatFromInt(content_w)) + pad * 2.0));
    s.height = @intFromFloat(@ceil(@as(f64, @floatFromInt(content_h)) + pad * 2.0));

    widget.glassCard(c, @floatFromInt(s.width), @floatFromInt(s.height), 26.0 * us, ctx, 0.92 * ctx.overlay_widget_card);
    widget.showShadowed(c, &time_l, pad, pad, ctx.text_r, ctx.text_g, ctx.text_b, 0.95);
    if (date_txt.len > 0) {
        widget.showShadowed(c, &date_l, pad, pad + @as(f64, @floatFromInt(time_px.h)) + 8.0 * us, ctx.text_r, ctx.text_g, ctx.text_b, 0.62);
    }
}
