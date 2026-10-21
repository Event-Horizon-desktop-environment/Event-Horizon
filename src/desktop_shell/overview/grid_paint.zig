//! Launchpad grid pixels: one cell per app, icon over name.
//!
//! Cells come from the computed grid; names and icons arrive through two
//! tiny callbacks so this file never learns what a catalog is. Missing
//! icons get the first-rune tile, overlong names clip inside the cell.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const dw = @import("../dock/widgets_paint.zig");
const types = @import("types.zig");
const grid = @import("grid.zig");
const cairo_helpers = @import("../shared/cairo_helpers.zig");

const Colors = types.Colors;
const Grid = types.Grid;

fn showZ(c: *cairo.cairo_t, text: []const u8) void {
    var buf: [128]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    cairo.cairo_show_text(c, buf[0..n :0]);
}

fn measure(c: *cairo.cairo_t, text: []const u8) f64 {
    var buf: [128]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    var ex: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
    cairo.cairo_text_extents(c, buf[0..n :0], &ex);
    return ex.x_advance;
}

fn firstRune(s: []const u8) []const u8 {
    if (s.len == 0) return "";
    var i: usize = 1;
    while (i < s.len and (s[i] & 0xC0) == 0x80) i += 1;
    return s[0..i];
}

/// Cell icon lookup the host fills from its theme cache. Surfaces are
/// built once over cached pixels, so a paint only ever blits.
pub const GridIcons = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, icon: []const u8) ?*cairo.cairo_surface_t,
};

pub const Cell = struct {
    name: []const u8 = "",
    icon: []const u8 = "",
    folder: bool = false,
    /// Stable shuffle/persist identity: `f:<id>` / `a:<path>`.
    key: []const u8 = "",
    /// Themed icon names for folder mini tiles (up to 4).
    members: [4][]const u8 = .{ "", "", "", "" },
    member_count: usize = 0,
};

/// Per-frame drag + shuffle state for one grid paint.
pub const Drag = struct {
    active: bool = false,
    /// Lifted cell index, or -1. Its slot stays empty; the ghost floats.
    drag_idx: i32 = -1,
    ghost_x: f64 = 0,
    ghost_y: f64 = 0,
    insert_show: bool = false,
    ins_x: f64 = 0,
    ins_y: f64 = 0,
    ins_h: f64 = 0,
    shuffle: []const ShuffleFrom = &.{},
    shuffle_start_ms: u64 = 0,
    now_ms: u64 = 0,
};

pub const ShuffleFrom = struct {
    key: []const u8,
    x: f64,
    y: f64,
};

fn shuffleEase(t: f64) f64 {
    const c = @min(1.0, @max(0.0, t));
    return 1.0 - (1.0 - c) * (1.0 - c) * (1.0 - c);
}

fn shuffleOffset(drag: Drag, key: []const u8, cx: f64, cy: f64) struct { x: f64, y: f64 } {
    if (drag.shuffle.len == 0 or drag.now_ms < drag.shuffle_start_ms) return .{ .x = cx, .y = cy };
    const t = shuffleEase(@as(f64, @floatFromInt(drag.now_ms - drag.shuffle_start_ms)) / 200.0);
    for (drag.shuffle) |sh| {
        if (std.mem.eql(u8, sh.key, key)) {
            return .{ .x = cx + (sh.x - cx) * (1.0 - t), .y = cy + (sh.y - cy) * (1.0 - t) };
        }
    }
    return .{ .x = cx, .y = cy };
}

pub fn paintGrid(
    cr: ?*cairo.cairo_t,
    g: *const Grid,
    ui: f64,
    colors: Colors,
    cells: []const Cell,
    hovered: i32,
    scroll: f64,
    alpha: f64,
    icons: GridIcons,
    drag: Drag,
) void {
    const c = cr orelse return;
    if (alpha <= 0.0 or g.cols <= 0 or cells.len == 0) return;
    // Cells scroll under the search bar, never over it: everything below
    // clips to the viewport the layout measured.
    cairo.cairo_save(c);
    cairo.cairo_rectangle(c, g.start_x, g.start_y, @as(f64, @floatFromInt(g.cols)) * g.cell_w, @as(f64, @floatFromInt(g.rows)) * g.cell_h);
    cairo.cairo_clip(c);
    defer cairo.cairo_restore(c);
    var idx: i32 = 0;
    while (idx < @as(i32, @intCast(cells.len))) : (idx += 1) {
        const r = grid.cellRect(g, idx, scroll);
        if (r.y + r.h < g.start_y or r.y > g.start_y + @as(f64, @floatFromInt(g.rows)) * g.cell_h) continue;
        // Lifted cell stays empty; the ghost paints it floating.
        if (idx == drag.drag_idx) continue;
        const cell = cells[@intCast(idx)];
        const off = shuffleOffset(drag, cell.key, r.x, r.y);
        const cx = off.x;
        const cy = off.y;
        if (idx == hovered) {
            cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.09 * alpha);
            cairo_helpers.roundedRect(c, cx + 4, cy + 4, r.w - 8, r.h - 8, 12.0 * ui);
            cairo.cairo_fill(c);
        }
        // Accent ring on folders while an app drag hovers them.
        if (idx == hovered and cell.folder and drag.active and drag.drag_idx != idx) {
            const acc = colors.accent;
            cairo.cairo_set_source_rgba(c, acc[0], acc[1], acc[2], 0.65 * alpha);
            cairo.cairo_set_line_width(c, 2.0 * ui);
            cairo_helpers.roundedRect(c, cx + 4, cy + 4, r.w - 8, r.h - 8, 12.0 * ui);
            cairo.cairo_stroke(c);
        }
        const name = cell.name;
        const box = g.icon_size;
        const ix = cx + (r.w - box) * 0.5;
        const iy = cy + (r.h - box - g.font_size - 6.0 * ui) * 0.5;
        if (cell.folder) {
            paintFolderTile(c, cx + (r.w - box) * 0.5, iy, box, ui, cell, name, alpha, icons);
        } else if (icons.get(icons.ctx, cell.icon)) |sf| {
            paintIcon(c, sf, ix, iy, box, alpha);
        } else {
            paintFallback(c, name, ix, iy, box, box * 0.28, alpha);
        }
        cairo.cairo_select_font_face(c, "sans-serif", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
        cairo.cairo_set_font_size(c, g.font_size);
        const fg = colors.fg;
        cairo.cairo_set_source_rgba(c, fg[0], fg[1], fg[2], 0.92 * alpha);
        const adv = measure(c, name);
        const tx = cx + (r.w - @min(adv, r.w - 8.0 * ui)) * 0.5;
        const ty = iy + box + g.font_size + 2.0 * ui;
        cairo.cairo_save(c);
        cairo.cairo_rectangle(c, cx, ty - g.font_size, r.w, g.font_size + 4.0 * ui);
        cairo.cairo_clip(c);
        cairo.cairo_move_to(c, tx, ty);
        showZ(c, name);
        cairo.cairo_restore(c);
    }
    // Reorder insertion marker: dock-style bar in the target gap.
    if (drag.insert_show and drag.ins_h > 0.0) {
        const acc = colors.accent;
        cairo.cairo_set_source_rgba(c, acc[0], acc[1], acc[2], 0.85 * alpha);
        cairo.cairo_set_line_width(c, 3.0 * ui);
        cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);
        cairo.cairo_move_to(c, drag.ins_x, drag.ins_y);
        cairo.cairo_line_to(c, drag.ins_x, drag.ins_y + drag.ins_h);
        cairo.cairo_stroke(c);
        cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_BUTT);
    }
}

/// Folder tile: rounded plate with up to 4 member icons, else the initial.
fn paintFolderTile(
    c: *cairo.cairo_t,
    x: f64,
    y: f64,
    box: f64,
    ui: f64,
    cell: Cell,
    name: []const u8,
    alpha: f64,
    icons: GridIcons,
) void {
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.11 * alpha);
    cairo_helpers.roundedRect(c, x, y, box, box, box * 0.28);
    cairo.cairo_fill(c);
    const pad = 5.0 * ui;
    const q = (box - pad * 3.0) * 0.5;
    var shown: usize = 0;
    for (cell.members[0..cell.member_count]) |icon| {
        if (shown >= 4) break;
        const sf = icons.get(icons.ctx, icon) orelse continue;
        const iw: f64 = @floatFromInt(cairo.cairo_image_surface_get_width(sf));
        const ih: f64 = @floatFromInt(cairo.cairo_image_surface_get_height(sf));
        if (iw <= 0.0 or ih <= 0.0) continue;
        const msc = q / @max(1.0, @max(iw, ih));
        const qx = x + pad + @as(f64, @floatFromInt(shown % 2)) * (q + pad);
        const qy = y + pad + @as(f64, @floatFromInt(shown / 2)) * (q + pad);
        cairo.cairo_save(c);
        cairo.cairo_translate(c, qx + (q - iw * msc) * 0.5, qy + (q - ih * msc) * 0.5);
        cairo.cairo_scale(c, msc, msc);
        cairo.cairo_set_source_surface(c, sf, 0, 0);
        cairo.cairo_paint_with_alpha(c, @floatCast(alpha));
        cairo.cairo_restore(c);
        shown += 1;
    }
    if (shown == 0 and name.len > 0) {
        cairo.cairo_set_source_rgba(c, 1, 1, 1, alpha);
        cairo.cairo_set_font_size(c, 12.5 * ui * 1.8);
        const glyph = firstRune(name);
        if (glyph.len > 0) {
            const adv = measure(c, glyph);
            cairo.cairo_move_to(c, x + (box - adv) * 0.5, y + box * 0.5 + 6.0 * ui);
            showZ(c, glyph);
        }
    }
}

/// Floating drag ghost at 1.05 scale about its own center, unclipped.
pub fn paintGhost(
    cr: ?*cairo.cairo_t,
    g: *const Grid,
    ui: f64,
    colors: Colors,
    cell: Cell,
    gx: f64,
    gy: f64,
    alpha: f64,
    icons: GridIcons,
) void {
    const c = cr orelse return;
    const gw = g.cell_w;
    const gh = g.cell_h;
    const gcx = gx + gw * 0.5;
    const gcy = gy + gh * 0.5;
    cairo.cairo_save(c);
    cairo.cairo_translate(c, gcx, gcy);
    cairo.cairo_scale(c, 1.05, 1.05);
    cairo.cairo_translate(c, -gcx, -gcy);
    if (cell.folder) {
        const ix = gx + (gw - g.icon_size) * 0.5;
        const iy = gy + 10.0 * ui;
        paintFolderTile(c, ix, iy, g.icon_size, ui, cell, cell.name, alpha * 0.95, icons);
    } else {
        cairo_helpers.roundedRect(c, gx + 6.0 * ui, gy + 4.0 * ui, gw - 12.0 * ui, gh - 8.0 * ui, 14.0 * ui);
        const bg = colors.card_bg;
        cairo.cairo_set_source_rgba(c, bg[0], bg[1], bg[2], 0.9 * alpha);
        cairo.cairo_fill(c);
        if (icons.get(icons.ctx, cell.icon)) |sf| {
            const iw: f64 = @floatFromInt(cairo.cairo_image_surface_get_width(sf));
            const ih: f64 = @floatFromInt(cairo.cairo_image_surface_get_height(sf));
            if (iw > 0.0 and ih > 0.0) {
                const sc = g.icon_size / @max(1.0, @max(iw, ih));
                cairo.cairo_save(c);
                cairo.cairo_translate(c, gcx - g.icon_size * 0.5, gy + 10.0 * ui);
                cairo.cairo_scale(c, sc, sc);
                cairo.cairo_set_source_surface(c, sf, 0, 0);
                cairo.cairo_paint_with_alpha(c, @floatCast(0.95 * alpha));
                cairo.cairo_restore(c);
            }
        }
    }
    cairo.cairo_restore(c);
}

/// Folder modal: dimmed launchpad, centered title, glass box, inner grid.
pub fn paintModal(
    cr: ?*cairo.cairo_t,
    g: *const Grid,
    w: f64,
    h: f64,
    ui: f64,
    colors: Colors,
    title: []const u8,
    cells: []const Cell,
    hovered: i32,
    scroll: f64,
    alpha: f64,
    icons: GridIcons,
    drag: Drag,
) void {
    const c = cr orelse return;
    if (alpha <= 0.0 or g.cols <= 0 or g.cell_w <= 0.0) return;
    cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.55 * alpha);
    cairo.cairo_rectangle(c, 0, 0, w, h);
    cairo.cairo_fill(c);
    const mbox = grid.modalBox(g, ui);
    cairo.cairo_set_font_size(c, 17.0 * ui);
    const fg = colors.fg;
    cairo.cairo_set_source_rgba(c, fg[0], fg[1], fg[2], alpha);
    const adv = measure(c, title);
    cairo.cairo_move_to(c, w * 0.5 - adv * 0.5, mbox.y - 14.0 * ui);
    showZ(c, title);
    const bg = colors.tile_title_bg;
    cairo.cairo_set_source_rgba(c, bg[0], bg[1], bg[2], 0.96 * alpha);
    cairo_helpers.roundedRect(c, mbox.x, mbox.y, mbox.w, mbox.h, 24.0 * ui);
    cairo.cairo_fill(c);
    dw.paintGlassLayers(c, mbox.x, mbox.y, mbox.w, mbox.h, alpha, 24.0 * ui);
    // The modal grid paints through the same cell painter.
    paintGrid(c, g, ui, colors, cells, hovered, scroll, alpha, icons, drag);
}

/// Right-click pin menu: glass box + rows, hovered row washed.
pub fn paintCtxMenu(
    cr: ?*cairo.cairo_t,
    ui: f64,
    colors: Colors,
    rect: [4]f64,
    labels: []const []const u8,
    hovered_row: i32,
    alpha: f64,
) void {
    const c = cr orelse return;
    if (alpha <= 0.0 or labels.len == 0) return;
    const bg = colors.tile_title_bg;
    cairo.cairo_set_source_rgba(c, bg[0], bg[1], bg[2], 0.96 * alpha);
    cairo_helpers.roundedRect(c, rect[0], rect[1], rect[2], rect[3], 12.0 * ui);
    cairo.cairo_fill(c);
    cairo.cairo_select_font_face(c, "sans-serif", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(c, 13.0 * ui);
    const fg = colors.fg;
    const row_h = (rect[3] - 12.0 * ui) / @as(f64, @floatFromInt(labels.len));
    for (labels, 0..) |label, i| {
        const ry = rect[1] + 6.0 * ui + @as(f64, @floatFromInt(i)) * row_h;
        if (@as(i32, @intCast(i)) == hovered_row) {
            cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.09 * alpha);
            cairo_helpers.roundedRect(c, rect[0] + 4.0 * ui, ry, rect[2] - 8.0 * ui, row_h, 8.0 * ui);
            cairo.cairo_fill(c);
        }
        cairo.cairo_set_source_rgba(c, fg[0], fg[1], fg[2], 0.92 * alpha);
        cairo.cairo_move_to(c, rect[0] + 14.0 * ui, ry + row_h * 0.66);
        showZ(c, label);
    }
}

/// Empty grid state: plain centered text, no card.
pub fn paintEmpty(cr: ?*cairo.cairo_t, g: *const Grid, w: f64, ui: f64, colors: Colors, alpha: f64) void {
    const c = cr orelse return;
    if (alpha <= 0.0) return;
    const dim = colors.dim_fg;
    cairo.cairo_set_source_rgba(c, dim[0], dim[1], dim[2], 0.9 * alpha);
    cairo.cairo_set_font_size(c, 15.0 * ui);
    const msg = "No apps found";
    const adv = measure(c, msg);
    cairo.cairo_move_to(c, w * 0.5 - adv * 0.5, g.start_y + 80.0 * ui);
    showZ(c, msg);
}

fn paintIcon(c: *cairo.cairo_t, surf: *cairo.cairo_surface_t, x: f64, y: f64, box: f64, alpha: f64) void {
    if (box <= 0.0) return;
    const iw: f64 = @floatFromInt(cairo.cairo_image_surface_get_width(surf));
    const ih: f64 = @floatFromInt(cairo.cairo_image_surface_get_height(surf));
    if (iw <= 0.0 or ih <= 0.0) return;
    const sc = @min(box / iw, box / ih);
    cairo.cairo_save(c);
    cairo.cairo_translate(c, x + (box - iw * sc) * 0.5, y + (box - ih * sc) * 0.5);
    cairo.cairo_scale(c, sc, sc);
    cairo.cairo_set_source_surface(c, surf, 0, 0);
    cairo.cairo_paint_with_alpha(c, @floatCast(alpha));
    cairo.cairo_restore(c);
}

fn paintFallback(c: *cairo.cairo_t, name: []const u8, x: f64, y: f64, box: f64, r: f64, alpha: f64) void {
    cairo_helpers.roundedRect(c, x, y, box, box, r);
    cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.10 * alpha);
    cairo.cairo_fill(c);
    const glyph = firstRune(name);
    if (glyph.len == 0) return;
    cairo.cairo_select_font_face(c, "sans-serif", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_BOLD);
    cairo.cairo_set_font_size(c, box * 0.42);
    var ex: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
    var buf: [8]u8 = undefined;
    @memcpy(buf[0..glyph.len], glyph);
    buf[glyph.len] = 0;
    cairo.cairo_text_extents(c, buf[0..glyph.len :0], &ex);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.85 * alpha);
    cairo.cairo_move_to(c, x + (box - ex.x_advance) * 0.5 - ex.x_bearing, y + box * 0.5 - ex.height * 0.5 - ex.y_bearing);
    cairo.cairo_show_text(c, buf[0..glyph.len :0]);
}

/// Page dots under the grid viewport; hidden on a single page.
pub fn paintPageDots(cr: ?*cairo.cairo_t, g: *const Grid, w: f64, ui: f64, colors: Colors, scroll: f64, alpha: f64) void {
    const c = cr orelse return;
    if (alpha <= 0.0) return;
    const pages = grid.pageCount(g);
    if (pages < 2) return;
    const active = grid.activePage(g, scroll);
    const view_bottom = g.start_y + @as(f64, @floatFromInt(g.rows)) * g.cell_h;
    const r = 4.0 * ui;
    const gap = 10.0 * ui;
    const total = @as(f64, @floatFromInt(pages)) * r * 2.0 + @as(f64, @floatFromInt(pages - 1)) * gap;
    var dx = w * 0.5 - total * 0.5;
    const dy = view_bottom + 12.0 * ui;
    const fg = colors.fg;
    var i: i32 = 0;
    while (i < pages) : (i += 1) {
        const dot: f64 = if (i == active) 0.9 else 0.35;
        cairo.cairo_set_source_rgba(c, fg[0], fg[1], fg[2], dot * alpha);
        cairo.cairo_arc(c, dx + r, dy, r, 0, std.math.pi * 2.0);
        cairo.cairo_fill(c);
        dx += r * 2.0 + gap;
    }
}

test "overview-grid-paint: grid paints without error" {
    const t = std.testing;
    const lay = @import("layout.zig");
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 1920, 1080);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    var l: types.Layout = .{};
    lay.compute(&l, 1920, 1080, 2, 1.0, .vertical, 0.5, 24, 34, 420);
    grid.computeGrid(&l.grid, 1920, 1080, l.search_y, 1.0, 3, 0);
    const cells = [_]Cell{
        .{ .name = "Files" },
        .{ .name = "Terminal" },
        .{ .name = "Browser" },
    };
    const noIcon = GridIcons{ .ctx = undefined, .get = struct {
        fn f(_: *anyopaque, _: []const u8) ?*cairo.cairo_surface_t {
            return null;
        }
    }.f };
    paintGrid(cr, &l.grid, 1.0, .{}, &cells, 1, 0, 1.0, noIcon, .{});
    paintGrid(cr, &l.grid, 1.0, .{}, &.{}, -1, 0, 1.0, noIcon, .{});
    paintPageDots(cr, &l.grid, 1920, 1.0, .{}, 0, 1.0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}

test "overview-grid-paint: modal, ctx menu and ghost paint clean" {
    const t = std.testing;
    const lay = @import("layout.zig");
    var l: types.Layout = .{};
    lay.compute(&l, 1920, 1080, 2, 1.0, .vertical, 0.5, 24, 34, 420);
    grid.computeModal(&l.modal, 1920, 1080, 1.0, 3);
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 1920, 1080);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    const noIcon = GridIcons{ .ctx = undefined, .get = struct {
        fn f(_: *anyopaque, _: []const u8) ?*cairo.cairo_surface_t {
            return null;
        }
    }.f };
    const cells = [_]Cell{
        .{ .name = "Files", .icon = "files", .key = "a:/x/files.desktop" },
        .{ .name = "Tools", .folder = true, .key = "f:bucket-5", .members = .{ "a", "b", "c", "d" }, .member_count = 2 },
    };
    // Modal with title, hovered cell and a drag ghost.
    paintModal(cr, &l.modal, 1920, 1080, 1.0, .{}, "Tools", &cells, 0, 0, 1.0, noIcon, .{ .active = true, .drag_idx = 1, .ghost_x = 900, .ghost_y = 500, .now_ms = 0 });
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    paintGhost(cr, &l.grid, 1.0, .{}, cells[0], 900, 500, 1.0, noIcon);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    // Ctx menu with hovered first row.
    const labels = [_][]const u8{ "Pin to dock", "Pin to taskbar" };
    paintCtxMenu(cr, 1.0, .{}, .{ 800, 400, 220, 80 }, &labels, 0, 1.0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    // Empty grid state.
    paintGrid(cr, &l.grid, 1.0, .{}, &.{}, -1, 0, 1.0, noIcon, .{});
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    // Insert marker + shuffle offsets.
    const shuf = [_]ShuffleFrom{.{ .key = "a:/x/files.desktop", .x = 0, .y = 0 }};
    paintGrid(cr, &l.grid, 1.0, .{}, &cells, -1, 0, 1.0, noIcon, .{
        .insert_show = true,
        .ins_x = 100,
        .ins_y = 100,
        .ins_h = 80,
        .shuffle = &shuf,
        .shuffle_start_ms = 0,
        .now_ms = 100,
    });
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}

test "overview-grid-paint: scrolled cells never reach the search bar" {
    const t = std.testing;
    const lay = @import("layout.zig");
    var l: types.Layout = .{};
    lay.compute(&l, 1920, 1080, 2, 1.0, .vertical, 0.5, 24, 34, 420);
    grid.computeGrid(&l.grid, 1920, 1080, l.search_y, 1.0, 60, 0);
    try t.expect(l.grid.scroll_max > 0);
    var names: [12]Cell = undefined;
    var nbufs: [12][16]u8 = undefined;
    for (&names, 0..) |*cl, i| {
        const nm = std.fmt.bufPrint(&nbufs[i], "App{d}", .{i}) catch "App";
        cl.* = .{ .name = nm, .icon = "" };
    }
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 1920, 1080);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    const noIcon = GridIcons{ .ctx = undefined, .get = struct {
        fn f(_: *anyopaque, _: []const u8) ?*cairo.cairo_surface_t {
            return null;
        }
    }.f };
    // Scroll a full page: row zero sits entirely above the viewport now.
    paintGrid(cr, &l.grid, 1.0, .{}, &names, -1, l.grid.scroll_max, 1.0, noIcon, .{});
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    cairo.cairo_surface_flush(surf);
    const data: [*]const u8 = @ptrCast(cairo.cairo_image_surface_get_data(surf));
    const stride = cairo.cairo_image_surface_get_stride(surf);
    // A pixel just above the viewport, inside the search bar band.
    const px: i32 = @intFromFloat(l.grid.start_x + 5);
    const py: i32 = @intFromFloat(l.grid.start_y - 8);
    const off: usize = @intCast(py * stride + px * 4);
    try t.expectEqual(@as(u8, 0), data[off]);
    try t.expectEqual(@as(u8, 0), data[off + 3]);
}
