const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const dw_data = @import("../../../ux/shared/desktop_widgets_data.zig");
const os_logo = @import("../../common/os_logo.zig");
const icon_raster = @import("../../common/icon_raster.zig");
const widget = @import("widget.zig");

// Desktop fetch widget.
// `fastfetch -l none --pipe` with the card structure, parses `key: value`
// rows, distro logo left + title/rows right, content-measured glass card.
// Refresh runs at most every 5s (`kRefreshSeconds`); `wantsSecondTicks`
// drives the host's 1s cadence.

pub const refresh_secs: i64 = 5;

pub const Row = struct {
    key: []const u8 = "",
    value: []const u8 = "",
};

pub const State = struct {
    widget_id: []const u8 = "",
    io: std.Io = undefined,
    title: []const u8 = "fastfetch",
    rows: std.ArrayListUnmanaged(Row) = .empty,
    ok: bool = false,
    width: i32 = 440,
    height: i32 = 240,
    key_col: f64 = 74.0,
    val_max: f64 = 260.0,
    logo_box: f64 = 108.0,
    logo: ?icon_raster.Pixels = null,
    last_read_ms: i64 = 0,
    arena: std.heap.ArenaAllocator = undefined,
    inited: bool = false,
};

pub fn stateFromConfig(cfg: dw_data.WidgetConfig) State {
    return .{ .widget_id = cfg.id };
}

pub fn initState(s: *State, gpa: std.mem.Allocator, io: std.Io) void {
    if (s.inited) return;
    s.io = io;
    s.arena = std.heap.ArenaAllocator.init(gpa);
    s.inited = true;
    readFetch(s);
}

pub fn deinitState(s: *State) void {
    if (s.inited) s.arena.deinit();
    s.inited = false;
}

pub fn refresh(s: *State, io: std.Io) void {
    _ = io;
    // initState (arena + first read) runs via the host hook; without it the
    // widget stays empty rather than reading into undefined memory.
    if (!s.inited) return;
    const now: i64 = @intCast(widget.monotonicMs());
    if (s.last_read_ms != 0 and @divTrunc(now - s.last_read_ms, 1000) < refresh_secs) return;
    readFetch(s);
}

pub fn ticks(s: *const State) bool {
    _ = s;
    return true;
}

fn readFetch(s: *State) void {
    const a = s.arena.allocator();
    s.rows.clearRetainingCapacity();
    s.title = "fastfetch";
    s.ok = false;
    // `fastfetch -l none --pipe -s "<structure>"` (minus terminal-only
    // Break/Colors modules).
    const structure = "Title:Separator:OS:Host:Kernel:Uptime:Packages:Shell:Display:DE:WM:WMTheme:Theme:Icons:Font:Cursor:Terminal:TerminalFont:CPU:GPU:Memory:Swap:Disk:LocalIp:Battery:PowerAdapter:Locale";
    const res = std.process.run(a, s.io, .{ .argv = &.{ "fastfetch", "-l", "none", "--pipe", "-s", structure } }) catch {
        s.rows.append(a, .{ .key = "ERROR", .value = "fastfetch not found" }) catch {};
        return;
    };
    defer a.free(res.stdout);
    defer a.free(res.stderr);
    const out = res.stdout;
    var saw_title = false;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var all_dash = true;
        for (line) |ch| {
            if (ch != '-') {
                all_dash = false;
                break;
            }
        }
        if (all_dash) continue;
        if (std.mem.indexOf(u8, line, ": ")) |pos| {
            saw_title = true;
            s.rows.append(a, .{
                .key = a.dupe(u8, line[0..pos]) catch continue,
                .value = a.dupe(u8, line[pos + 2 ..]) catch continue,
            }) catch break;
        } else if (!saw_title) {
            s.title = a.dupe(u8, line) catch "fastfetch";
            saw_title = true;
        }
    }
    if (s.title.len == 0) s.title = "fastfetch";
    s.ok = s.rows.items.len > 0;
    if (!s.ok) s.rows.append(a, .{ .key = "ERROR", .value = "fastfetch returned no output" }) catch {};
    s.last_read_ms = @intCast(widget.monotonicMs());
}

pub fn size(s: *const State) [2]i32 {
    return .{ s.width, s.height };
}

fn measureLine(cr: ?*cairo.cairo_t, desc: []const u8, str: []const u8) [2]i32 {
    var l = widget.makeLine(cr, desc, str);
    defer l.destroy();
    const px = l.pixelSize();
    return .{ px.w, px.h };
}

fn relayout(s: *State, cr: ?*cairo.cairo_t) void {
    var key_w: f64 = 0;
    var val_w: f64 = 0;
    for (s.rows.items) |r| {
        const kw = measureLine(cr, "Inter 10", r.key);
        const vw = measureLine(cr, "Inter 11", r.value);
        key_w = @max(key_w, @as(f64, @floatFromInt(kw[0])));
        val_w = @max(val_w, @as(f64, @floatFromInt(vw[0])));
    }
    s.key_col = std.math.clamp(key_w + 6.0, 74.0, 190.0);
    s.val_max = std.math.clamp(val_w + 6.0, 200.0, 880.0);
    const title_h = measureLine(cr, "Inter Bold 18", s.title)[1];
    const rows_top: f64 = 16.0 + @as(f64, @floatFromInt(title_h)) + 12.0;
    const rows_h: f64 = 20.0 * @as(f64, @floatFromInt(s.rows.items.len));
    const content_h = rows_top + rows_h + 16.0;
    s.logo_box = std.math.clamp(content_h - 16.0 - 16.0, 108.0, 256.0);
    s.height = @intFromFloat(@ceil(@max(content_h, s.logo_box + 16.0 + 16.0)));
    const content_w = 16.0 + s.logo_box + 20.0 + s.key_col + 14.0 + s.val_max + 16.0;
    s.width = @intFromFloat(@ceil(@min(content_w, 1440.0)));
}

fn drawShadowed(cr: ?*cairo.cairo_t, desc: []const u8, str: []const u8, x: f64, y: f64, r: f64, g: f64, b: f64, a: f64) void {
    var l = widget.makeLine(cr, desc, str);
    defer l.destroy();
    const c = cr orelse return;
    cairo.cairo_save(c);
    cairo.cairo_move_to(c, x + 1.0, y + 1.0);
    cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.32);
    if (l.layout) |lo| text.pango_cairo_show_layout(c, lo);
    cairo.cairo_restore(c);
    cairo.cairo_move_to(c, x, y);
    cairo.cairo_set_source_rgba(c, r, g, b, a);
    if (l.layout) |lo| text.pango_cairo_show_layout(c, lo);
}

fn truncFit(cr: ?*cairo.cairo_t, alloc: std.mem.Allocator, desc: []const u8, str: []const u8, max_w: f64) []const u8 {
    if (@as(f64, @floatFromInt(measureLine(cr, desc, str)[0])) <= max_w) return str;
    var n = str.len;
    while (n > 4) {
        n -= 1;
        while (n > 0 and (str[n] & 0xC0) == 0x80) n -= 1;
        const cand = std.fmt.allocPrint(alloc, "{s}…", .{str[0..n]}) catch break;
        if (@as(f64, @floatFromInt(measureLine(cr, desc, cand)[0])) <= max_w) return cand;
    }
    return str[0..@min(n, str.len)];
}

pub fn paint(s: *State, cr: ?*cairo.cairo_t, ctx: widget.Ctx) void {
    const c = cr orelse return;
    relayout(s, c);
    const w: f64 = @floatFromInt(s.width);
    const h: f64 = @floatFromInt(s.height);

    widget.glassCard(c, w, h, 15.0, ctx, ctx.overlay_widget_card);

    // Distro logo with a faint backplate, vertically centered.
    const logo_top = (h - s.logo_box) * 0.5;
    cairo.cairo_save(c);
    widget.roundRect(c, 16.0, logo_top, s.logo_box, s.logo_box, s.logo_box * 0.28);
    cairo.cairo_set_source_rgba(c, ctx.text_r, ctx.text_g, ctx.text_b, 0.05);
    cairo.cairo_fill(c);
    cairo.cairo_restore(c);
    paintLogo(s, c, 16.0, logo_top, s.logo_box);

    const col_x = 16.0 + s.logo_box + 20.0;
    const val_x = col_x + s.key_col + 14.0;
    const val_max_w = @min(s.val_max, w - 16.0 - val_x);
    const title_h: f64 = @floatFromInt(measureLine(c, "Inter Bold 18", s.title)[1]);
    const rows_top = 16.0 + title_h + 12.0;

    cairo.cairo_save(c);
    cairo.cairo_set_source_rgba(c, ctx.text_r, ctx.text_g, ctx.text_b, 0.10);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_move_to(c, col_x, 16.0 + title_h + 5.5);
    cairo.cairo_line_to(c, w - 16.0, 16.0 + title_h + 5.5);
    cairo.cairo_stroke(c);
    cairo.cairo_restore(c);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    drawShadowed(c, "Inter Bold 18", s.title, col_x, 16.0, ctx.text_r, ctx.text_g, ctx.text_b, 0.95);
    for (s.rows.items, 0..) |r, i| {
        const row_top = rows_top + @as(f64, @floatFromInt(i)) * 20.0;
        const k = truncFit(c, arena.allocator(), "Inter 10", r.key, s.key_col);
        const v = truncFit(c, arena.allocator(), "Inter 11", r.value, val_max_w);
        drawShadowed(c, "Inter 10", k, col_x, row_top + 4.0, ctx.text_r, ctx.text_g, ctx.text_b, 0.50);
        drawShadowed(c, "Inter 11", v, val_x, row_top + 3.0, ctx.text_r, ctx.text_g, ctx.text_b, 0.92);
        if (i + 1 < s.rows.items.len) {
            cairo.cairo_save(c);
            cairo.cairo_set_source_rgba(c, ctx.text_r, ctx.text_g, ctx.text_b, 0.05);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_move_to(c, col_x, row_top + 20.0 - 0.5);
            cairo.cairo_line_to(c, w - 16.0, row_top + 20.0 - 0.5);
            cairo.cairo_stroke(c);
            cairo.cairo_restore(c);
        }
    }
}

fn paintLogo(s: *State, cr: ?*cairo.cairo_t, x: f64, y: f64, box: f64) void {
    const c = cr orelse return;
    // Loaded once (held for the widget's lifetime);
    // the pixels live in the state arena.
    if (s.logo == null) {
        const alloc = s.arena.allocator();
        s.logo = os_logo.loadDistroLogo(alloc, s.io, @intFromFloat(box));
    }
    const px = s.logo orelse return;
    if (px.w <= 0 or px.h <= 0) return;
    const surf = cairo.cairo_image_surface_create_for_data(
        px.data.ptr,
        cairo.CAIRO_FORMAT_ARGB32,
        px.w,
        px.h,
        px.w * 4,
    );
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) return;
    defer cairo.cairo_surface_destroy(surf);
    cairo.cairo_save(c);
    cairo.cairo_translate(c, x, y);
    cairo.cairo_scale(c, box / @as(f64, @floatFromInt(px.w)), box / @as(f64, @floatFromInt(px.h)));
    cairo.cairo_set_source_surface(c, surf, 0, 0);
    cairo.cairo_paint(c);
    cairo.cairo_restore(c);
}

test "settings-desktop-fetch: parse + measure constants" {
    const t = std.testing;
    var s = State{};
    try t.expectEqual([2]i32{ 440, 240 }, size(&s));
    try t.expect(ticks(&s));
}
