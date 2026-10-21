//! The overview's quick-select rail: workspace thumbs plus add slot.
//!
//! Thumbs sit centered as a row (horizontal axis) or column (vertical) with
//! the add-workspace slot counted, so the group — and everything centered
//! on it — lands on the true middle. Each thumb shows its windows as mini
//! tinted cells; the selected and active ones get accent rings, the hovered
//! one lifts three pixels. The add slot is dashed dim with a plus glyph.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const dw = @import("../dock/widgets_paint.zig");
const glyph = @import("../common/material_glyph.zig");
const cairo_helpers = @import("../shared/cairo_helpers.zig");
const types = @import("types.zig");
const pick = @import("pick.zig");
const tiles = @import("tiles.zig");

const Colors = types.Colors;
const Strip = types.Strip;

pub const Thumb = struct {
    app_ids: []const []const u8 = &.{},
    /// Window addresses parallel to `app_ids`, for live frames.
    addrs: []const []const u8 = &.{},
    label: []const u8 = "",
    active: bool = false,
    /// The workspace's monitor: the cache key for its screen shot.
    monitor: []const u8 = "",
    /// The monitor's screen shot, painted behind the mini cells when the
    /// capture has one; without it the thumb keeps its flat fill.
    shot: ?tiles.LiveFrame = null,
    /// What `shot` actually is (monitor copy or wallpaper file): the paint
    /// cache key. Empty thumbs borrow the wallpaper, so the kind says so.
    shot_kind: tiles.SrcKind = .monitor,
    shot_id: u64 = 0,
};

fn showZ(c: *cairo.cairo_t, text: []const u8) void {
    var buf: [64]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    cairo.cairo_show_text(c, buf[0..n :0]);
}

fn measure(c: *cairo.cairo_t, text: []const u8) f64 {
    var buf: [64]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    var ex: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
    cairo.cairo_text_extents(c, buf[0..n :0], &ex);
    return ex.x_advance;
}

pub fn paintStrip(
    cr: ?*cairo.cairo_t,
    cache: *tiles.ScaledCache,
    s: *const Strip,
    ui: f64,
    colors: Colors,
    thumbs: []const Thumb,
    frames: ?tiles.FrameLookup,
    scroll: f64,
    selected: i32,
    hovered_qs: i32,
    alpha: f64,
) void {
    const c = cr orelse return;
    if (alpha <= 0.0 or thumbs.len == 0) return;
    const n: i32 = @intCast(thumbs.len);
    for (thumbs, 0..) |th, k| {
        const i: i32 = @intCast(k);
        const r = pick.stripThumb(s, n, i, scroll);
        // Culled thumbs never paint: the scrolled column outgrows the
        // strip, and cairo already clips anything past the surface.
        if (r.x + r.w < s.x or r.x > s.x + s.w) continue;
        if (r.y + r.h < s.y or r.y > s.y + s.h) continue;
        paintThumb(c, cache, s, ui, colors, th, frames, r, i == hovered_qs, i == selected, alpha);
    }
    const add = pick.stripAddRect(s, n, scroll);
    if (add.x + add.w >= s.x and add.x <= s.x + s.w and add.y + add.h >= s.y and add.y <= s.y + s.h) {
        paintAdd(c, s, add, ui, colors, hovered_qs == types.strip_add_idx, alpha);
    }
}

/// One window per mini cell. Without a monitor shot each cell is its app
/// tint; with one the shot is the backdrop, so a cell shows its window's
/// live frame instead — and a window still without a frame leaves its
/// cell open so the screenshot shows through. Tints must never cover the
/// shot: that is what buried the screencopy under colored boxes.
fn miniCells(
    c: *cairo.cairo_t,
    cache: *tiles.ScaledCache,
    tx: f64,
    ty: f64,
    s: *const Strip,
    ui: f64,
    colors: Colors,
    ids: []const []const u8,
    addrs: []const []const u8,
    frames: ?tiles.FrameLookup,
    has_shot: bool,
    alpha: f64,
) void {
    if (ids.len == 0) return;
    const pad = 3.0 * ui;
    const iw = s.thumb_w - pad * 2.0;
    const ih = s.thumb_h - pad * 2.0;
    if (iw <= 0.0 or ih <= 0.0) return;
    const nn: f64 = @floatFromInt(ids.len);
    const cols: i32 = @min(3, @max(1, @as(i32, @intFromFloat(@ceil(@sqrt(nn))))));
    const rows: i32 = @divTrunc(@as(i32, @intCast(ids.len)) + cols - 1, cols);
    const gap = 2.0 * ui;
    const fc: f64 = @floatFromInt(cols);
    const fr: f64 = @floatFromInt(rows);
    const cw = (iw - (fc - 1.0) * gap) / fc;
    const ch = (ih - (fr - 1.0) * gap) / fr;
    const bg = colors.card_bg;
    for (ids, 0..) |id, k| {
        const col: i32 = @rem(@as(i32, @intCast(k)), cols);
        const row: i32 = @divTrunc(@as(i32, @intCast(k)), cols);
        const x = tx + pad + @as(f64, @floatFromInt(col)) * (cw + gap);
        const y = ty + pad + @as(f64, @floatFromInt(row)) * (ch + gap);
        if (has_shot) {
            const lk = frames orelse continue;
            if (k >= addrs.len) continue;
            const live = lk.call(lk.ctx, addrs[k]) orelse continue;
            tiles.paintFrameCached(cache, c, .window, tiles.hashId(addrs[k]), .{ .x = x, .y = y, .w = cw, .h = ch }, live, alpha, 3.0 * ui);
            continue;
        }
        const tint = tiles.appTint(id);
        cairo.cairo_set_source_rgba(
            c,
            tint[0] * 0.6 + bg[0] * 0.4,
            tint[1] * 0.6 + bg[1] * 0.4,
            tint[2] * 0.6 + bg[2] * 0.4,
            0.85 * alpha,
        );
        cairo_helpers.roundedRect(c, x, y, cw, ch, 3.0 * ui);
        cairo.cairo_fill(c);
    }
}

fn paintThumb(
    c: *cairo.cairo_t,
    cache: *tiles.ScaledCache,
    s: *const Strip,
    ui: f64,
    colors: Colors,
    th: Thumb,
    frames: ?tiles.FrameLookup,
    thumb: types.Rect,
    hovered: bool,
    selected: bool,
    alpha: f64,
) void {
    var tx = thumb.x;
    var ty = thumb.y;
    if (hovered) {
        if (s.horizontal) ty -= 3.0 * ui else tx -= 3.0 * ui;
    }
    if (th.shot) |fr| {
        const r: types.Rect = .{ .x = tx, .y = ty, .w = s.thumb_w, .h = s.thumb_h };
        tiles.paintFrameCached(cache, c, th.shot_kind, th.shot_id, r, fr, 0.9 * alpha, s.radius);
    } else {
        const bg = colors.card_bg;
        cairo.cairo_set_source_rgba(c, bg[0], bg[1], bg[2], 0.9 * alpha);
        cairo_helpers.roundedRect(c, tx, ty, s.thumb_w, s.thumb_h, s.radius);
        cairo.cairo_fill(c);
    }
    miniCells(c, cache, tx, ty, s, ui, colors, th.app_ids, th.addrs, frames, th.shot != null, alpha);
    if (s.thumb_h > 40.0 * ui) dw.paintGlassLayers(c, tx, ty, s.thumb_w, s.thumb_h, alpha * 0.7, s.radius);
    if (th.label.len > 0) {
        cairo.cairo_select_font_face(c, "sans-serif", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
        cairo.cairo_set_font_size(c, 9.0 * ui);
        const adv = measure(c, th.label);
        const lw = @min(adv, s.thumb_w - 4.0 * ui);
        const fg = colors.fg;
        cairo.cairo_set_source_rgba(c, fg[0], fg[1], fg[2], 0.8 * alpha);
        cairo.cairo_save(c);
        if (s.horizontal) {
            const lx = tx + (s.thumb_w - lw) * 0.5;
            const ly = ty + s.thumb_h + 12.0 * ui;
            cairo.cairo_rectangle(c, tx, ty + s.thumb_h, s.thumb_w, 16.0 * ui);
            cairo.cairo_clip(c);
            cairo.cairo_move_to(c, lx, ly);
        } else {
            const lx = tx + s.thumb_w + 6.0 * ui;
            const ly = ty + s.thumb_h * 0.5 + 3.0 * ui;
            cairo.cairo_rectangle(c, tx + s.thumb_w, ty, 60.0 * ui, s.thumb_h);
            cairo.cairo_clip(c);
            cairo.cairo_move_to(c, lx, ly);
        }
        showZ(c, th.label);
        cairo.cairo_restore(c);
    }
    if (hovered) {
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.12 * alpha);
        cairo_helpers.roundedRect(c, tx, ty, s.thumb_w, s.thumb_h, s.radius);
        cairo.cairo_fill(c);
    }
    if (selected or th.active) {
        const acc = colors.accent;
        const ring: f64 = if (selected) 0.9 else 0.55;
        cairo.cairo_set_source_rgba(c, acc[0], acc[1], acc[2], ring * alpha);
        cairo.cairo_set_line_width(c, 2.0 * ui);
        cairo_helpers.roundedRect(c, tx, ty, s.thumb_w, s.thumb_h, s.radius);
        cairo.cairo_stroke(c);
    }
}

fn paintAdd(c: *cairo.cairo_t, s: *const Strip, add: types.Rect, ui: f64, colors: Colors, hovered: bool, alpha: f64) void {
    var ax = add.x;
    var ay = add.y;
    if (hovered) {
        if (s.horizontal) ay -= 3.0 * ui else ax -= 3.0 * ui;
    }
    const aw = add.w;
    const ah = add.h;
    const tb = colors.thumb_bg;
    const dim = colors.dim_fg;
    const acc = colors.accent;
    if (hovered) {
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.12 * alpha);
        cairo_helpers.roundedRect(c, ax, ay, aw, ah, s.radius);
        cairo.cairo_fill(c);
        cairo.cairo_set_source_rgba(c, acc[0], acc[1], acc[2], 0.95 * alpha);
        cairo.cairo_set_line_width(c, 2.0 * ui);
        cairo_helpers.roundedRect(c, ax, ay, aw, ah, s.radius);
        cairo.cairo_stroke(c);
    } else {
        cairo.cairo_set_source_rgba(c, tb[0], tb[1], tb[2], 0.55 * alpha);
        cairo_helpers.roundedRect(c, ax, ay, aw, ah, s.radius);
        cairo.cairo_fill(c);
        const dash: f64 = @max(2.0, 3.0 * ui);
        var dashes = [_]f64{ dash, dash };
        cairo.cairo_set_dash(c, &dashes, 2, 0);
        cairo.cairo_set_line_width(c, 1.4 * ui);
        cairo.cairo_set_source_rgba(c, dim[0], dim[1], dim[2], 0.55 * alpha);
        cairo_helpers.roundedRect(c, ax + 0.7 * ui, ay + 0.7 * ui, aw - 1.4 * ui, ah - 1.4 * ui, s.radius);
        cairo.cairo_stroke(c);
        cairo.cairo_set_dash(c, null, 0, 0);
    }
    const gp = @min(aw, ah) * 0.42;
    if (hovered) {
        _ = glyph.draw(c, "add", ax + aw * 0.5, ay + ah * 0.5, gp, acc[0], acc[1], acc[2], 0.95 * alpha);
    } else {
        _ = glyph.draw(c, "add", ax + aw * 0.5, ay + ah * 0.5, gp, dim[0], dim[1], dim[2], 0.8 * alpha);
    }
}

test "overview-strip: rail paints without error" {
    const t = std.testing;
    const lay = @import("layout.zig");
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 1920, 1080);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    var l: types.Layout = .{};
    lay.compute(&l, 1920, 1080, 2, 1.0, .vertical, 0.5, 24, 34, 420);
    const ids = [_][]const u8{ "a", "b" };
    const thumbs = [_]Thumb{
        .{ .app_ids = &ids, .label = "1", .active = true },
        .{ .app_ids = &.{}, .label = "2" },
    };
    var cache = tiles.ScaledCache.init(t.allocator);
    defer cache.deinit();
    paintStrip(cr, &cache, &l.strip, 1.0, .{}, &thumbs, null, 0.0, 0, 1, 1.0);
    paintStrip(cr, &cache, &l.strip, 1.0, .{}, &thumbs, null, 0.0, 0, types.strip_add_idx, 1.0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}
