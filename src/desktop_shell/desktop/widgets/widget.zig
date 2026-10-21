const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const chrome = @import("../../widgets/shared/chrome_colors.zig");
const schema = @import("../../../config/schema.zig");

// Shared desktop-widget interface.
// they use: rounded rect, glass card fill+stroke, shadowed pango text).

/// Monotonic milliseconds.
pub fn monotonicMs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(@max(ts.sec, 0))) * 1000 +
        @as(u64, @intCast(@max(ts.nsec, 0))) / 1_000_000;
}

/// Everything a desktop widget painter reads from the shell config, resolved
/// once per paint (the host builds this from
/// it so painters stay free of schema imports).
pub const Ctx = struct {
    io: std.Io,
    dock_fill_r: f64 = 0.12,
    dock_fill_g: f64 = 0.12,
    dock_fill_b: f64 = 0.14,
    acc_r: f64 = 0.90,
    acc_g: f64 = 0.90,
    acc_b: f64 = 0.90,
    text_r: f64 = 1.0,
    text_g: f64 = 1.0,
    text_b: f64 = 1.0,
    drawer_r: f64 = 0.11,
    drawer_g: f64 = 0.11,
    drawer_b: f64 = 0.13,
    overlay_widget_card: f64 = 1.0,
    ui_scale: f64 = 1.0,
    use_24h: bool = false,
    show_seconds: bool = false,
    show_date: bool = true,
    date_format: i32 = 0,
    custom_format: []const u8 = "",
    timezone: []const u8 = "",

    pub fn fromSchema(sc: *const schema.ShellConfig, io: std.Io) Ctx {
        const c = chrome.of(sc);
        return .{
            .io = io,
            .dock_fill_r = c.dock_fill.r,
            .dock_fill_g = c.dock_fill.g,
            .dock_fill_b = c.dock_fill.b,
            .acc_r = c.accent.r,
            .acc_g = c.accent.g,
            .acc_b = c.accent.b,
            .text_r = c.text.r,
            .text_g = c.text.g,
            .text_b = c.text.b,
            .drawer_r = c.drawer_dim.r,
            .drawer_g = c.drawer_dim.g,
            .drawer_b = c.drawer_dim.b,
            .overlay_widget_card = sc.appearance.overlay_opacity_widget_card,
            .ui_scale = 1.0,
            .use_24h = sc.time.use_24h,
            .show_seconds = sc.time.show_seconds,
            .show_date = sc.time.show_date,
            .date_format = sc.time.date_format,
            .custom_format = sc.time.custom_format,
            .timezone = sc.time.timezone,
        };
    }

    pub fn fallback(io: std.Io) Ctx {
        return .{ .io = io };
    }
};

/// Pango layout for one line. `desc` is a `from_string` description
/// ("Inter Light 52"). Value-semantics:
/// copy the returned `Layout` and `destroy()` it when done.
pub fn makeLine(cr: ?*cairo.cairo_t, desc: []const u8, s: []const u8) text.Layout {
    const c = cr orelse return .{};
    var l = text.Layout.createForCairo(c);
    l.setFont(desc);
    l.setText(s);
    return l;
}

/// Glass card body: rounded rect, dock-fill @ 0.30 * alpha, 1px text @ 0.14
/// stroke — the `glass_card_style` body every desktop widget paints.
pub fn glassCard(cr: ?*cairo.cairo_t, w: f64, h: f64, radius: f64, ctx: Ctx, alpha_mul: f64) void {
    const c = cr orelse return;
    cairo.cairo_save(c);
    cairo.cairo_rectangle(c, 0, 0, w, h);
    // rounded path via helper below
    roundRect(c, 0, 0, w, h, radius);
    cairo.cairo_set_source_rgba(c, ctx.dock_fill_r * 0.30, ctx.dock_fill_g * 0.30, ctx.dock_fill_b * 0.30, alpha_mul);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, ctx.text_r, ctx.text_g, ctx.text_b, 0.14);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);
}

pub fn roundRect(c: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    const cr = c orelse return;
    const rr = @min(r, @min(w, h) * 0.5);
    cairo.cairo_new_path(cr);
    cairo.cairo_arc(cr, x + w - rr, y + rr, rr, -std.math.pi * 0.5, 0);
    cairo.cairo_arc(cr, x + w - rr, y + h - rr, rr, 0, std.math.pi * 0.5);
    cairo.cairo_arc(cr, x + rr, y + h - rr, rr, std.math.pi * 0.5, std.math.pi);
    cairo.cairo_arc(cr, x + rr, y + rr, rr, std.math.pi, std.math.pi * 1.5);
    cairo.cairo_close_path(cr);
}

/// Shadowed white text: black offset pass + foreground pass.
/// `show_shadowed` lambdas.
pub fn showShadowed(cr: ?*cairo.cairo_t, l: *text.Layout, x: f64, y: f64, r: f64, g: f64, b: f64, a: f64) void {
    const c = cr orelse return;
    cairo.cairo_save(c);
    cairo.cairo_move_to(c, x + 1.0, y + 1.0);
    cairo.cairo_set_source_rgba(c, 0.0, 0.0, 0.0, 0.25);
    if (l.layout) |lo| text.pango_cairo_show_layout(c, lo);
    cairo.cairo_restore(c);
    cairo.cairo_move_to(c, x, y);
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    if (l.layout) |lo| text.pango_cairo_show_layout(c, lo);
}

pub fn showPlain(cr: ?*cairo.cairo_t, l: *text.Layout, x: f64, y: f64, r: f64, g: f64, b: f64, a: f64) void {
    const c = cr orelse return;
    cairo.cairo_move_to(c, x, y);
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    if (l.layout) |lo| text.pango_cairo_show_layout(c, lo);
}
