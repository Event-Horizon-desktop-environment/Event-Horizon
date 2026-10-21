//! Window tiles and card furniture for the overview.
//!
//! Each window is a tinted glass tile: drop shadow, per-app tint blended
//! over the card fill, the app icon top-left, a title pill along the bottom,
//! and an accent ring when focused. A tile whose window is hovered also gets
//! a close button straddling its top-right corner. Cards carry a centered
//! label pill with the workspace name.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const dw = @import("../dock/widgets_paint.zig");
const types = @import("types.zig");
const cairo_helpers = @import("../shared/cairo_helpers.zig");

const Colors = types.Colors;
const Rect = types.Rect;

pub const IconPx = struct {
    data: []const u8 = &.{},
    w: i32 = 0,
    h: i32 = 0,
};

/// A captured window frame: premultiplied BGRA in CAIRO_FORMAT_ARGB32
/// order, top-down. Painted in place of the tinted tile body so the
/// window's real content shows in the card.
pub const LiveFrame = struct {
    data: []const u8 = &.{},
    w: i32 = 0,
    h: i32 = 0,
    /// Source generation: bumped every time the owner replaces the pixels.
    /// Paint caches key on this, never on the data pointer (which an
    /// allocator may reuse), so a fresh capture can never paint stale.
    gen: u64 = 0,
};

/// Where a window's captured frame comes from at paint time. The capture
/// store answers by window address; a miss leaves the cell open.
pub const FrameLookup = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, addr: []const u8) ?LiveFrame,
};

/// Content hash for cache keys: window addresses and monitor names.
pub fn hashId(s: []const u8) u64 {
    return std.hash_map.hashString(s);
}

/// Source kinds for the scaled cache below. Kinds keep two different
/// sources apart when every other key bit matches.
pub const SrcKind = enum(u8) {
    window = 1,
    monitor = 2,
    wallpaper = 3,
};

/// Pre-scaled paint cache: each captured image is scaled once (per target
/// size) and every later paint blits it 1:1 instead of rescaling the
/// compositor-sized copy on the CPU again. Keys carry the source's
/// generation, so replacing pixels always misses and closed windows age
/// out through LRU eviction. Bounded: past 32 entries the stalest goes.
pub const ScaledCache = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        kind: u8,
        id: u64,
        gen: u64,
        rw: i32,
        rh: i32,
        fw: i32,
        fh: i32,
        surf: ?*cairo.cairo_surface_t,
    };

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |e| {
            if (e.surf) |s| cairo.cairo_surface_destroy(s);
        }
        self.entries.deinit(self.alloc);
    }

    fn find(self: *Self, kind: u8, id: u64, gen: u64, rw: i32, rh: i32) ?*Entry {
        for (self.entries.items, 0..) |*e, i| {
            if (e.kind == kind and e.id == id and e.gen == gen and e.rw == rw and e.rh == rh) {
                // Most-recently-used to the front; eviction takes the back.
                if (i > 0) {
                    const ent = self.entries.orderedRemove(i);
                    self.entries.insert(self.alloc, 0, ent) catch {
                        self.entries.append(self.alloc, ent) catch return null;
                        return &self.entries.items[self.entries.items.len - 1];
                    };
                    return &self.entries.items[0];
                }
                return e;
            }
        }
        return null;
    }

    fn insertScaled(
        self: *Self,
        kind: u8,
        id: u64,
        gen: u64,
        rw: i32,
        rh: i32,
        fw: i32,
        fh: i32,
        surf: ?*cairo.cairo_surface_t,
    ) ?*Entry {
        while (self.entries.items.len >= 32) {
            const old = self.entries.pop() orelse break;
            if (old.surf) |s| cairo.cairo_surface_destroy(s);
        }
        self.entries.insert(self.alloc, 0, .{
            .kind = kind,
            .id = id,
            .gen = gen,
            .rw = rw,
            .rh = rh,
            .fw = fw,
            .fh = fh,
            .surf = surf,
        }) catch {
            self.entries.append(self.alloc, .{
                .kind = kind,
                .id = id,
                .gen = gen,
                .rw = rw,
                .rh = rh,
                .fw = fw,
                .fh = fh,
                .surf = surf,
            }) catch return null;
            return &self.entries.items[self.entries.items.len - 1];
        };
        return &self.entries.items[0];
    }
};

/// A fitted image ready to blit: the cached surface plus its size and
/// centering offset relative to the target rect's origin.
pub const Fitted = struct {
    surf: ?*cairo.cairo_surface_t = null,
    fw: i32 = 0,
    fh: i32 = 0,
    dx: f64 = 0,
    dy: f64 = 0,
};

/// Look up (or scale once) the fitted surface for `frame` in a `rect_w`
/// by `rect_h` box. Null when the frame is unusable.
pub fn fittedSurface(
    cache: *ScaledCache,
    kind: SrcKind,
    id: u64,
    rect_w: f64,
    rect_h: f64,
    frame: LiveFrame,
) Fitted {
    if (rect_w <= 0.0 or rect_h <= 0.0) return .{};
    if (frame.data.len == 0 or frame.w <= 0 or frame.h <= 0) return .{};
    const need = @as(usize, @intCast(frame.w)) * @as(usize, @intCast(frame.h)) * 4;
    if (frame.data.len < need) return .{};
    const rw: i32 = @intFromFloat(@ceil(rect_w));
    const rh: i32 = @intFromFloat(@ceil(rect_h));
    if (rw <= 0 or rh <= 0) return .{};
    const iw: f64 = @floatFromInt(frame.w);
    const ih: f64 = @floatFromInt(frame.h);
    const scale = @min(rect_w / iw, rect_h / ih);
    const fw: i32 = @max(1, @as(i32, @intFromFloat(iw * scale)));
    const fh: i32 = @max(1, @as(i32, @intFromFloat(ih * scale)));
    const k: u8 = @intFromEnum(kind);
    const ent = cache.find(k, id, frame.gen, rw, rh) orelse blk: {
        const surf = scaleTo(frame, fw, fh) orelse return .{};
        break :blk cache.insertScaled(k, id, frame.gen, rw, rh, fw, fh, surf) orelse {
            cairo.cairo_surface_destroy(surf);
            return .{};
        };
    };
    const surf = ent.surf orelse return .{};
    return .{
        .surf = surf,
        .fw = fw,
        .fh = fh,
        .dx = (rect_w - @as(f64, @floatFromInt(fw))) * 0.5,
        .dy = (rect_h - @as(f64, @floatFromInt(fh))) * 0.5,
    };
}

/// A captured image fitted into a rounded rectangle, served from the
/// scaled cache: the first paint for a (source, size) scales once, later
/// paints blit 1:1. Same contain-fit geometry as `paintFrameFitted`.
pub fn paintFrameCached(
    cache: *ScaledCache,
    cr: ?*cairo.cairo_t,
    kind: SrcKind,
    id: u64,
    rect: Rect,
    frame: LiveFrame,
    alpha: f64,
    r: f64,
) void {
    const c = cr orelse return;
    if (alpha <= 0.0 or rect.w <= 0.0 or rect.h <= 0.0) return;
    const f = fittedSurface(cache, kind, id, rect.w, rect.h, frame);
    const surf = f.surf orelse {
        // Slow path, still correct: scale straight onto the target.
        paintFrameFitted(c, rect, frame, alpha, r);
        return;
    };
    cairo.cairo_save(c);
    cairo_helpers.roundedRect(c, rect.x, rect.y, rect.w, rect.h, r);
    cairo.cairo_clip(c);
    cairo.cairo_set_source_surface(c, surf, rect.x + f.dx, rect.y + f.dy);
    cairo.cairo_paint_with_alpha(c, @floatCast(alpha));
    cairo.cairo_restore(c);
}

/// One box-filtered shrink of a capture into its own surface. Runs once
/// per (source, size) — every later paint blits the result 1:1.
fn scaleTo(frame: LiveFrame, fw: i32, fh: i32) ?*cairo.cairo_surface_t {
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, fw, fh);
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    const cc = cairo.cairo_create(surf);
    const tmp = cairo.cairo_image_surface_create_for_data(
        @constCast(frame.data.ptr),
        cairo.CAIRO_FORMAT_ARGB32,
        frame.w,
        frame.h,
        frame.w * 4,
    );
    if (cairo.cairo_surface_status(tmp) == cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_scale(cc, @as(f64, @floatFromInt(fw)) / @as(f64, @floatFromInt(frame.w)), @as(f64, @floatFromInt(fh)) / @as(f64, @floatFromInt(frame.h)));
        cairo.cairo_set_source_surface(cc, tmp, 0, 0);
        cairo.cairo_paint(cc);
    }
    cairo.cairo_surface_destroy(tmp);
    cairo.cairo_destroy(cc);
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    return surf;
}

/// One captured image fitted inside a rounded rectangle: clipped to the
/// corners, scaled to fit (never cropped), centered, painted with alpha.
/// Shared by the window tiles, the workspace cards, and the rail thumbs —
/// anywhere a screenshot becomes a backdrop.
pub fn paintFrameFitted(
    cr: ?*cairo.cairo_t,
    rect: Rect,
    frame: LiveFrame,
    alpha: f64,
    r: f64,
) void {
    const c = cr orelse return;
    if (alpha <= 0.0 or rect.w <= 0.0 or rect.h <= 0.0) return;
    if (frame.data.len == 0 or frame.w <= 0 or frame.h <= 0) return;
    const need = @as(usize, @intCast(frame.w)) * @as(usize, @intCast(frame.h)) * 4;
    if (frame.data.len < need) return;
    const iw: f64 = @floatFromInt(frame.w);
    const ih: f64 = @floatFromInt(frame.h);
    const scale = @min(rect.w / iw, rect.h / ih);
    const fw = iw * scale;
    const fh = ih * scale;
    const dx = rect.x + (rect.w - fw) * 0.5;
    const dy = rect.y + (rect.h - fh) * 0.5;
    cairo.cairo_save(c);
    cairo_helpers.roundedRect(c, rect.x, rect.y, rect.w, rect.h, r);
    cairo.cairo_clip(c);
    const surf = cairo.cairo_image_surface_create_for_data(
        @constCast(frame.data.ptr),
        cairo.CAIRO_FORMAT_ARGB32,
        frame.w,
        frame.h,
        frame.w * 4,
    );
    if (cairo.cairo_surface_status(surf) == cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_translate(c, dx, dy);
        cairo.cairo_scale(c, scale, scale);
        cairo.cairo_set_source_surface(c, surf, 0, 0);
        cairo.cairo_paint_with_alpha(c, @floatCast(alpha));
    }
    cairo.cairo_surface_destroy(surf);
    cairo.cairo_restore(c);
}

/// Streamed window content fitted into a tile: clipped to the tile's
/// rounded corners, scaled to fit (never cropped — the tile is normalized
/// to the card's aspect, so cover-fitting would cut 16:9 content), and
/// centered. No shadow or tinted backing: the frame floats directly on the
/// card. A focused window keeps its accent ring on top.
pub fn paintLiveFrame(
    cr: ?*cairo.cairo_t,
    tile: Rect,
    ui: f64,
    frame: LiveFrame,
    alpha: f64,
    colors: Colors,
    focused: bool,
) void {
    const c = cr orelse return;
    if (alpha <= 0.0 or tile.w <= 0.0 or tile.h <= 0.0) return;
    const r = 12.0 * ui;
    paintFrameFitted(c, tile, frame, alpha, r);
    if (focused) paintFocusRing(c, tile, ui, colors, alpha);
}

/// The accent ring for a focused window's tile, stroked over whatever the
/// tile already shows (live frame or tint).
pub fn paintFocusRing(
    cr: ?*cairo.cairo_t,
    tile: Rect,
    ui: f64,
    colors: Colors,
    alpha: f64,
) void {
    const c = cr orelse return;
    if (alpha <= 0.0 or tile.w <= 0.0 or tile.h <= 0.0) return;
    const acc = colors.accent;
    cairo.cairo_set_source_rgba(c, acc[0], acc[1], acc[2], 0.85 * alpha);
    cairo.cairo_set_line_width(c, 2.0 * ui);
    cairo_helpers.roundedRect(c, tile.x, tile.y, tile.w, tile.h, 12.0 * ui);
    cairo.cairo_stroke(c);
}

fn hue2rgb(p: f64, q: f64, t: f64) f64 {
    var tt = t;
    if (tt < 0.0) tt += 1.0;
    if (tt > 1.0) tt -= 1.0;
    if (tt < 1.0 / 6.0) return p + (q - p) * 6.0 * tt;
    if (tt < 1.0 / 2.0) return q;
    if (tt < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - tt) * 6.0;
    return p;
}

fn hslToRgb(h: f64, s: f64, l: f64) [3]f64 {
    if (s <= 0.0) return .{ l, l, l };
    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;
    return .{ hue2rgb(p, q, h + 1.0 / 3.0), hue2rgb(p, q, h), hue2rgb(p, q, h - 1.0 / 3.0) };
}

/// Stable tint per app id; empty ids get a neutral gray.
pub fn appTint(app_id: []const u8) [3]f64 {
    if (app_id.len == 0) return hslToRgb(0.0, 0.0, 0.55);
    var h: u32 = 2166136261;
    for (app_id) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return hslToRgb(@as(f64, @floatFromInt(h % 360)) / 360.0, 0.42, 0.58);
}

fn showZ(c: *cairo.cairo_t, text: []const u8) void {
    var buf: [256]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    cairo.cairo_show_text(c, buf[0..n :0]);
}

fn measure(c: *cairo.cairo_t, text: []const u8) f64 {
    var buf: [256]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    var ex: cairo.cairo_text_extents_t = std.mem.zeroes(cairo.cairo_text_extents_t);
    cairo.cairo_text_extents(c, buf[0..n :0], &ex);
    return ex.x_advance;
}

pub fn paintTile(
    cr: ?*cairo.cairo_t,
    tile: Rect,
    colors: Colors,
    ui: f64,
    tint: [3]f64,
    alpha: f64,
    focused: bool,
    hovered: bool,
) void {
    const c = cr orelse return;
    if (alpha <= 0.0 or tile.w <= 0.0 or tile.h <= 0.0) return;
    const r = 12.0 * ui;
    cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.28 * alpha);
    cairo_helpers.roundedRect(c, tile.x + 2.0 * ui, tile.y + 3.0 * ui, tile.w, tile.h, r);
    cairo.cairo_fill(c);
    const k_bg = 0.45;
    const bg = colors.card_bg;
    cairo.cairo_set_source_rgba(
        c,
        tint[0] * k_bg + bg[0] * (1.0 - k_bg),
        tint[1] * k_bg + bg[1] * (1.0 - k_bg),
        tint[2] * k_bg + bg[2] * (1.0 - k_bg),
        0.95 * alpha,
    );
    cairo_helpers.roundedRect(c, tile.x, tile.y, tile.w, tile.h, r);
    cairo.cairo_fill(c);
    dw.paintGlassLayers(c, tile.x, tile.y, tile.w, tile.h, alpha * 0.9, r);
    if (hovered) {
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.10 * alpha);
        cairo_helpers.roundedRect(c, tile.x, tile.y, tile.w, tile.h, r);
        cairo.cairo_fill(c);
    }
    if (focused) {
        const acc = colors.accent;
        cairo.cairo_set_source_rgba(c, acc[0], acc[1], acc[2], 0.85 * alpha);
        cairo.cairo_set_line_width(c, 2.0 * ui);
        cairo_helpers.roundedRect(c, tile.x, tile.y, tile.w, tile.h, r);
        cairo.cairo_stroke(c);
    }
}

pub fn paintTileIcon(cr: ?*cairo.cairo_t, tile: Rect, ui: f64, icon: IconPx, alpha: f64) void {
    const c = cr orelse return;
    if (icon.data.len == 0 or icon.w <= 0 or icon.h <= 0) return;
    const box = @min(tile.w * 0.30, tile.h * 0.34);
    const sz = @min(30.0 * ui, @max(16.0 * ui, box));
    const iw: f64 = @floatFromInt(icon.w);
    const ih: f64 = @floatFromInt(icon.h);
    const sc = sz / @max(1.0, @max(iw, ih));
    const surf = cairo.cairo_image_surface_create_for_data(
        @constCast(icon.data.ptr),
        cairo.CAIRO_FORMAT_ARGB32,
        icon.w,
        icon.h,
        icon.w * 4,
    );
    defer cairo.cairo_surface_destroy(surf);
    cairo.cairo_save(c);
    cairo.cairo_translate(c, tile.x + 6.0 * ui, tile.y + 6.0 * ui);
    cairo.cairo_scale(c, sc, sc);
    cairo.cairo_set_source_surface(c, surf, 0, 0);
    cairo.cairo_paint_with_alpha(c, @floatCast(alpha));
    cairo.cairo_restore(c);
}

pub fn titlePill(tile: Rect, ui: f64, text_w: f64) Rect {
    const pill_w = text_w + 16.0 * ui;
    const pill_h = 14.0 * ui + 6.0 * ui;
    return .{
        .w = pill_w,
        .h = pill_h,
        .x = tile.x + (tile.w - pill_w) * 0.5,
        .y = tile.y + tile.h - pill_h - 5.0 * ui,
    };
}

pub fn paintTitlePill(
    cr: ?*cairo.cairo_t,
    tile: Rect,
    ui: f64,
    title: []const u8,
    alpha: f64,
) void {
    const c = cr orelse return;
    if (title.len == 0 or alpha <= 0.0) return;
    cairo.cairo_select_font_face(c, "sans-serif", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(c, 11.0 * ui);
    const max_w: f64 = @max(1.0, tile.w - 10.0 * ui);
    const pill = titlePill(tile, ui, @min(measure(c, title), max_w));
    cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.72 * alpha);
    cairo_helpers.roundedRect(c, pill.x, pill.y, pill.w, pill.h, pill.h * 0.5);
    cairo.cairo_fill(c);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, alpha);
    cairo.cairo_save(c);
    cairo.cairo_rectangle(c, pill.x, pill.y, pill.w, pill.h);
    cairo.cairo_clip(c);
    cairo.cairo_move_to(c, pill.x + 8.0 * ui, pill.y + pill.h - 3.0 * ui - 2.0 * ui);
    showZ(c, title);
    cairo.cairo_restore(c);
}

pub fn paintClose(
    cr: ?*cairo.cairo_t,
    tile: Rect,
    close_sz: f64,
    ui: f64,
    hovered: bool,
    alpha: f64,
) void {
    const c = cr orelse return;
    if (alpha <= 0.0) return;
    const bs = close_sz * 0.72;
    const bx = tile.x + tile.w - bs * 0.5;
    const by = tile.y - bs * 0.5;
    const shade: f64 = @as(f64, if (hovered) 0.55 else 0.35);
    cairo.cairo_set_source_rgba(c, 0, 0, 0, shade * alpha);
    cairo.cairo_arc(c, bx + bs * 0.5, by + bs * 0.5, bs * 0.5, 0, std.math.pi * 2.0);
    cairo.cairo_fill(c);
    cairo.cairo_set_source_rgba(c, 1, 1, 1, alpha);
    cairo.cairo_set_line_width(c, 1.8 * ui);
    cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);
    const pad = bs * 0.30;
    cairo.cairo_move_to(c, bx + pad, by + pad);
    cairo.cairo_line_to(c, bx + bs - pad, by + bs - pad);
    cairo.cairo_move_to(c, bx + bs - pad, by + pad);
    cairo.cairo_line_to(c, bx + pad, by + bs - pad);
    cairo.cairo_stroke(c);
    cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_BUTT);
}

pub fn paintCardLabel(
    cr: ?*cairo.cairo_t,
    card: Rect,
    ui: f64,
    colors: Colors,
    label: []const u8,
    alpha: f64,
) void {
    const c = cr orelse return;
    if (label.len == 0 or alpha <= 0.0) return;
    cairo.cairo_select_font_face(c, "sans-serif", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(c, 12.0 * ui);
    const adv = measure(c, label);
    const pill_w: f64 = @max(40.0 * ui, adv + 24.0 * ui);
    const pill_h = 20.0 * ui;
    const px = card.x + (card.w - pill_w) * 0.5;
    const py = card.y + card.h - pill_h - 10.0 * ui;
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.10 * alpha);
    cairo_helpers.roundedRect(c, px, py, pill_w, pill_h, pill_h * 0.5);
    cairo.cairo_fill(c);
    const fg = colors.fg;
    cairo.cairo_set_source_rgba(c, fg[0], fg[1], fg[2], alpha);
    cairo.cairo_move_to(c, px + (pill_w - adv) * 0.5, py + pill_h - 5.0 * ui);
    showZ(c, label);
}

test "overview-tiles: tint is stable, gray when anonymous" {
    const t = std.testing;
    const a = appTint("org.mozilla.firefox");
    const b = appTint("org.mozilla.firefox");
    try t.expectEqual(a, b);
    try t.expect(!(a[0] == appTint("org.gnome.Terminal")[0] and a[1] == appTint("org.gnome.Terminal")[1] and a[2] == appTint("org.gnome.Terminal")[2]));
    const gray = appTint("");
    try t.expectEqual([3]f64{ 0.55, 0.55, 0.55 }, gray);
}

test "overview-tiles: pills sit inside their tile" {
    const t = std.testing;
    const tile = Rect{ .x = 100, .y = 100, .w = 300, .h = 200 };
    const pill = titlePill(tile, 1.0, 120);
    try t.expectEqual(@as(f64, 136), pill.w);
    try t.expectEqual(@as(f64, 100 + (300 - 136) * 0.5), pill.x);
    try t.expectEqual(@as(f64, 100 + 200 - 20 - 5), pill.y);
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 640, 480);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    const colors: Colors = .{};
    paintTile(cr, tile, colors, 1.0, appTint("x"), 1.0, true, false);
    paintTileIcon(cr, tile, 1.0, .{}, 1.0);
    paintTitlePill(cr, tile, 1.0, "Terminal", 1.0);
    paintClose(cr, tile, 34, 1.0, false, 1.0);
    paintCardLabel(cr, tile, 1.0, colors, "Workspace 1", 1.0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}
