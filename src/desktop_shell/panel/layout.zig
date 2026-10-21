//! Panel three-zone layout — port of the geometry half of
//! `panel_paint_widget_bar` (`src/desktop_shell/panel/paint/panel_paint.cpp:338-372,610-657`).
//!
//! Pure: given per-slot widths, answers where each slot paints and which hit
//! rect it owns. Anchored left/center/right when the sections fit; otherwise
//! the single centered strip with horizontal compression (hits scaled to
//! match, C++ :650-655).

const std = @import("std");
const slots_mod = @import("slots.zig");
const types = @import("types.zig");

pub const Placed = struct {
    /// Surface x of each slot, parallel to the strip slots.
    x: []f64,
    /// Surface width of each slot (already compressed when scaled).
    w: []f64,
    /// Left edge of the section the slot belongs to (for debugging).
    section_x: f64 = 0,
    /// Whether the anchored three-zone path was taken.
    anchored: bool = true,
    /// Compression applied in fallback mode (1.0 when anchored).
    hscale: f64 = 1.0,
    /// Strip origin the fallback scaled about.
    origin_x: f64 = 0,

    pub fn deinit(self: *Placed, alloc: std.mem.Allocator) void {
        alloc.free(self.x);
        alloc.free(self.w);
        self.* = .{ .x = &.{}, .w = &.{}, .anchored = true };
    }
};

/// Lay out one strip. `widths` parallels `strip.slots`; `gap` is the
/// inter-slot gap, `strip_pad`/`sec_gap` the section paddings.
pub fn layoutStrip(
    alloc: std.mem.Allocator,
    strip: *const slots_mod.Strip,
    widths: []const f64,
    gap: f64,
    strip_pad: f64,
    sec_gap: f64,
    box_x: f64,
    box_w: f64,
) !Placed {
    var xs = try alloc.alloc(f64, strip.slots.len);
    errdefer alloc.free(xs);
    var ws = try alloc.alloc(f64, strip.slots.len);
    errdefer alloc.free(ws);

    const lw = sectionW(strip, widths, 0, strip.left_n, gap);
    const cw = sectionW(strip, widths, strip.left_n, strip.center_n, gap);
    const rw = sectionW(strip, widths, strip.left_n + strip.center_n, strip.right_n, gap);
    const anchored = slots_mod.panelFits(lw, cw, rw, box_w, strip_pad, sec_gap, strip.left_n > 0, strip.center_n > 0, strip.right_n > 0);

    if (anchored) {
        const left_x = box_x + strip_pad;
        const center_x = box_x + (box_w - cw) / 2.0;
        const right_x = box_x + box_w - strip_pad - rw;
        placeSection(strip, widths, gap, 0, strip.left_n, left_x, xs, ws);
        placeSection(strip, widths, gap, strip.left_n, strip.center_n, center_x, xs, ws);
        placeSection(strip, widths, gap, strip.left_n + strip.center_n, strip.right_n, right_x, xs, ws);
        return .{ .x = xs, .w = ws, .anchored = true, .hscale = 1.0, .origin_x = box_x };
    }

    // Fallback: single centered strip with horizontal compression.
    var total: f64 = 0;
    for (strip.slots, 0..) |sl, i| {
        total += widths[i];
        if (i + 1 < strip.slots.len) total += slots_mod.gapBetween(sl, strip.slots[i + 1], gap);
    }
    const hscale = slots_mod.stripHScale(box_w, total, strip_pad);
    const cx = box_x + (box_w - total * hscale) / 2.0;
    for (strip.slots, 0..) |_, i| {
        // Layout in uncompressed space, then scale about cx (C++ :644-648).
        const lx = rawX(strip, widths, gap, i);
        xs[i] = cx + (lx - cx) * hscale;
        ws[i] = widths[i] * hscale;
    }
    return .{ .x = xs, .w = ws, .anchored = false, .hscale = hscale, .origin_x = cx };
}

fn sectionW(strip: *const slots_mod.Strip, widths: []const f64, from: usize, n: usize, gap: f64) f64 {
    var tw: f64 = 0;
    for (0..n) |k| {
        tw += widths[from + k];
        if (k + 1 < n) tw += slots_mod.gapBetween(strip.slots[from + k], strip.slots[from + k + 1], gap);
    }
    return tw;
}

fn placeSection(
    strip: *const slots_mod.Strip,
    widths: []const f64,
    gap: f64,
    from: usize,
    n: usize,
    x0: f64,
    xs: []f64,
    ws: []f64,
) void {
    var cur = x0;
    for (0..n) |k| {
        xs[from + k] = cur;
        ws[from + k] = widths[from + k];
        cur += widths[from + k];
        if (k + 1 < n) cur += slots_mod.gapBetween(strip.slots[from + k], strip.slots[from + k + 1], gap);
    }
}

/// Uncompressed x of slot i in strip order (fallback path).
fn rawX(strip: *const slots_mod.Strip, widths: []const f64, gap: f64, idx: usize) f64 {
    var x: f64 = 0;
    for (0..idx) |k| {
        x += widths[k];
        x += slots_mod.gapBetween(strip.slots[k], strip.slots[k + 1], gap);
    }
    return x;
}

/// Build hit rects from a placement. `icon_y`/`icon_h` is the slot row;
/// `y` is the bar top (hits live in surface coords, C++ :409-419).
pub fn buildHits(
    alloc: std.mem.Allocator,
    strip: *const slots_mod.Strip,
    placed: *const Placed,
    icon_y: f64,
    icon_h: f64,
) ![]types.WidgetHit {
    var out: std.ArrayList(types.WidgetHit) = .empty;
    errdefer out.deinit(alloc);
    for (strip.slots, 0..) |sl, i| {
        try out.append(alloc, .{
            .widget_id = sl.key,
            .x = placed.x[i],
            .y = icon_y,
            .w = placed.w[i],
            .h = icon_h,
            .chosen_serial = sl.chosen_serial,
            .slot_kind = @intFromEnum(slotKindFor(sl.kind)),
        });
    }
    return out.toOwnedSlice(alloc);
}

const SharedKind = @import("../widgets/shared/slot_kind.zig").SlotKind;

fn slotKindFor(k: @import("widgets.zig").Kind) SharedKind {
    return switch (k) {
        .app => .app,
        .tray => .tray,
        .settings => .settings,
        .spotlight => .spotlight,
        .app_menu => .app_menu,
        .app_drawer => .app_drawer,
        .clock => .clock,
        .weather => .weather,
        .media => .media,
        .workspaces => .workspaces,
        .control_center => .control_center,
        .trash => .trash,
        .volume_mixer => .volume_mixer,
        .vpn => .vpn,
        .layout => .layout,
        .battery => .battery,
        .bluetooth => .bluetooth,
        .smenu => .smenu,
        .world_clock => .world_clock,
        .overview => .overview,
        .separator, .spacer, .unknown => .separator,
    };
}

test "panel-layout: anchored sections keep their zones" {
    const t = std.testing;
    const slots_arr = [_]slots_mod.Slot{
        .{ .kind = .clock, .key = "clock" },
        .{ .kind = .battery, .key = "battery" },
    };
    const strip = slots_mod.Strip{ .slots = @constCast(&slots_arr), .left_n = 1, .center_n = 0, .right_n = 1 };
    const widths = [_]f64{ 100, 80 };
    var p = try layoutStrip(t.allocator, &strip, &widths, 8, 16, 20, 0, 1920);
    defer p.deinit(t.allocator);
    try t.expect(p.anchored);
    try t.expectEqual(@as(f64, 16), p.x[0]);
    try t.expectEqual(@as(f64, 1920 - 16 - 80), p.x[1]);
    const hits = try buildHits(t.allocator, &strip, &p, 0, 22);
    defer t.allocator.free(hits);
    try t.expectEqual(@as(i32, 0), types.hitIndexAt(hits, 20, 11));
    try t.expectEqual(@as(i32, 1), types.hitIndexAt(hits, 1900, 11));
}

test "panel-layout: overflow falls back to compressed center" {
    const t = std.testing;
    var slots_arr = [_]slots_mod.Slot{
        .{ .kind = .clock, .key = "a" },
        .{ .kind = .clock, .key = "b" },
    };
    const strip = slots_mod.Strip{ .slots = &slots_arr, .left_n = 1, .center_n = 1, .right_n = 0 };
    const widths = [_]f64{ 800, 800 };
    var p = try layoutStrip(t.allocator, &strip, &widths, 8, 16, 20, 0, 1000);
    defer p.deinit(t.allocator);
    try t.expect(!p.anchored);
    try t.expect(p.hscale < 1.0);
    // Compressed widths sum to the available span.
    try t.expectApproxEqAbs(@as(f64, 1000 - 32), p.w[0] + p.w[1] + 8 * p.hscale, 1e-6);
}
