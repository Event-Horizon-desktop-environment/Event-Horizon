//! Scratch: paint one toast card at three countdown states and sample the
//! progress-bar row: full (f=1), half (f=0.5), empty (f=0), timeless (none).
const std = @import("std");
const cairo = @import("wl/buffer/shm.zig").cairo;
const cards = @import("desktop_shell/notifications/toast_cards.zig");
const manager_mod = @import("services/notify_manager.zig");
const chrome_colors = @import("desktop_shell/widgets/shared/chrome_colors.zig");
const schema = @import("config/schema.zig");

fn paintBar(gpa: std.mem.Allocator, received: i64, expiry: ?i64, now_ms: i64) ![64]u8 {
    const m = cards.Metrics{};
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 420, 200 ) orelse return error.NoSurface;
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf ) orelse return error.NoSurface;
    defer cairo.cairo_destroy(cr);
    // Flat dark bg so the bar reads clearly.
    cairo.cairo_set_source_rgba(cr, 0.05, 0.05, 0.06, 1.0);
    cairo.cairo_paint(cr);
    var cfg = schema.ShellConfig{};
    const ch = chrome_colors.of(&cfg);
    const n = manager_mod.Notification{
        .id = 1,
        .app_name = "a",
        .summary = "Title",
        .body = "Body text here",
        .timeout_ms = 6000,
        .received_ms = received,
        .expiry_ms = expiry,
    };
    const card = cards.Card{ .id = 1, .x = 10, .y = 10, .w = 400, .h = 140 };
    cards.paintCard(cr, gpa, card, &n, ch, m, 1.0, now_ms, false);
    cairo.cairo_surface_flush(surf);
    const data = cairo.cairo_image_surface_get_data(surf);
    const stride: usize = @intCast(cairo.cairo_image_surface_get_stride(surf));
    // Progress bar y: card.y + card.h - 3 - 8 + 1 (middle of the 3px bar).
    const by: usize = 10 + 140 - 3 - 8 + 1;
    // Sample 64 points across the bar width (pad insets 18px each side).
    var out: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const x: usize = 10 + 18 + (i * (400 - 36)) / 63;
        const o = by * stride + x * 4;
        // Accent fill is bright; bg is dim. Use R channel (accent reddish/white).
        out[i] = data[o + 2];
    }
    return out;
}

test "scratch: progress bar states" {
    const gpa = std.testing.allocator;
    const full = try paintBar(gpa, 0, 6000, 0);
    const half = try paintBar(gpa, 0, 6000, 3000);
    const empty = try paintBar(gpa, 0, 6000, 6000);
    const timeless = try paintBar(gpa, 0, null, 99999);
    var desc: [256]u8 = undefined;
    const show = struct {
        fn s(row: [64]u8, buf: []u8) []u8 {
            var n: usize = 0;
            for (row) |v| {
                buf[n] = if (v > 100) '#' else '.';
                n += 1;
            }
            return buf[0..n];
        }
    }.s;
    std.debug.print("\nfull:     {s}\n", .{show(full, &desc)});
    std.debug.print("half:     {s}\n", .{show(half, &desc)});
    std.debug.print("empty:    {s}\n", .{show(empty, &desc)});
    std.debug.print("timeless: {s}\n", .{show(timeless, &desc)});
    // Full bar: nearly all bright. Empty/timeless: nearly all dim.
    var bright_full: usize = 0;
    var bright_half: usize = 0;
    var bright_empty: usize = 0;
    var bright_timeless: usize = 0;
    for (full) |v| bright_full += @intFromBool(v > 100);
    for (half) |v| bright_half += @intFromBool(v > 100);
    for (empty) |v| bright_empty += @intFromBool(v > 100);
    for (timeless) |v| bright_timeless += @intFromBool(v > 100);
    std.debug.print("bright counts: full={d} half={d} empty={d} timeless={d}\n", .{ bright_full, bright_half, bright_empty, bright_timeless });
    try std.testing.expect(bright_full > 55);
    try std.testing.expect(bright_half > 20 and bright_half < 44);
    try std.testing.expect(bright_empty < 8);
    try std.testing.expect(bright_timeless < 8);
}
