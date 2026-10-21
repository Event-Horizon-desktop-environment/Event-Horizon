//! The App menu's rail panel: a 540x420 card with the categories down a 52 px
//! rail on the left, the search field across the top of the main column, one
//! 38 px row per app and the highlighted app's description along the bottom.
//!
//! The reference panel (`launcher_paint`) and this one read the same `View`;
//! the host picks between them with the view's style, and the two share the
//! confirmation card, the row menu and the row icon blitter. Everything here
//! is the design's own geometry, drawn from the shell's chrome tokens, so the
//! custom theme, the Horizon palette and matugen all arrive for free.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const text = @import("../../text/layout.zig");
const helpers = @import("../shared/cairo_helpers.zig");
const layout = @import("launcher_layout.zig");
const ref = @import("launcher_paint.zig");
const chrome = @import("shared/chrome_colors.zig");
const cat = @import("../../services/app_catalog.zig");

const k_placeholder = "Search apps";
const k_esc = "Esc";
const k_enter = "Enter";
const k_open = "Open";
const k_all_apps = "All apps";

const tau: f64 = 2.0 * std.math.pi;

/// The design's palette, as fractions of the foreground colour: every
/// hairline, hover, field and highlight in the mockup is the text colour at
/// low alpha, which is what makes them flip with the theme rather than being
/// baked white.
const line_a: f64 = 0.08;
const border_a: f64 = 0.10;
const hover_a: f64 = 0.06;
const field_a: f64 = 0.05;
const sel_a: f64 = 0.14;
const dim_a: f64 = 0.55;
/// A rail glyph at rest (the design's `--dim`) and lit (`--text` / accent).
const glyph_a: f64 = 0.60;
const glyph_hot_a: f64 = 0.95;
/// The letter tile's plate, and the scrollbar's thumb.
const tile_a: f64 = 0.08;
const thumb_a: f64 = 0.16;
/// The tooltip's plate — the design's `--text` background.
const tip_plate_a: f64 = 0.95;
/// The card's nominal fill; `card_alpha` scales it the way the host's
/// overlay-opacity scale does.
const card_a: f64 = 0.92;
/// The card is the dock fill a long way down — the same `* 0.30` the
/// reference panel's own card uses — and the rail is the same treatment of
/// the drawer's dim fill, a fixed step below the card: the relationship the
/// design's own dark pair has (#0b0b0e under #101014).
const panel_k: f64 = 0.30;
const rail_k: f64 = panel_k * 0.86;
/// Glyph box and stroke of the design's `24` viewBox at `stroke-width: 1.7`;
/// the rails draw them at 18 px, so the stroke lands at 1.275 px.
const glyph_box: f64 = 24.0;
const glyph_stroke: f64 = 1.7;

fn lum(c: chrome.Rgb) f64 {
    return c.r * 0.299 + c.g * 0.587 + c.b * 0.114;
}

/// The foreground the hairlines, hovers and text lean on. The palette's own
/// `text` is used whenever it actually contrasts with the card; the card is
/// the dock fill scaled down, which on a light palette can land the two on
/// top of each other, and then plain white (or near-black) ink is the only
/// honest choice — the white the reference card paints its rules with.
fn inkOn(panel: chrome.Rgb, t: chrome.Rgb) chrome.Rgb {
    const lp = lum(panel);
    if (@abs(lp - lum(t)) >= 0.25) return t;
    return if (lp < 0.45)
        chrome.Rgb{ .r = 1.0, .g = 1.0, .b = 1.0 }
    else
        chrome.Rgb{ .r = 0.06, .g = 0.06, .b = 0.09 };
}

fn setInk(c: ?*cairo.cairo_t, col: chrome.Rgb, a: f64) void {
    const cr = c orelse return;
    cairo.cairo_set_source_rgba(cr, col.r, col.g, col.b, a);
}

/// `ref.drawRun` paints white; the rail's text is the ink, which is dark on
/// a light card, so every run here sets its own colour.
fn drawInk(cr: ?*cairo.cairo_t, l: *text.Layout, x: f64, top: f64, col: chrome.Rgb, a: f64) void {
    const c = cr orelse return;
    cairo.cairo_move_to(c, x, top);
    setInk(c, col, a);
    l.show(c);
}

// Paint

pub fn paint(cr: ?*cairo.cairo_t, v: ref.View, card_alpha: f64) void {
    const c = cr orelse return;
    const g = v.rgeo;
    const d = v.colors.dock_fill;
    const panel = chrome.Rgb{ .r = d.r * panel_k, .g = d.g * panel_k, .b = d.b * panel_k };
    const dd = v.colors.drawer_dim;
    const rail = chrome.Rgb{ .r = dd.r * rail_k, .g = dd.g * rail_k, .b = dd.b * rail_k };
    const ink = inkOn(panel, v.colors.text);

    // The card: the dock's fill a long way down, at the same 0.92 the
    // reference panel uses, so the compositor's blur reads through it the
    // same way. The rail strip is painted over it as a slightly darker band.
    cairo.cairo_save(c);
    helpers.roundedRect(c, 0.0, 0.0, g.w, g.h, layout.rail_r);
    setInk(c, panel, card_a * card_alpha);
    cairo.cairo_fill_preserve(c);
    setInk(c, ink, border_a);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);
    helpers.roundedRect(c, 0.0, 0.0, g.w, g.h, layout.rail_r);
    cairo.cairo_clip(c);

    paintStrip(c, v, rail, ink, card_alpha);
    paintSearch(c, v, ink);
    paintMeta(c, v, ink);
    paintList(c, v, ink);
    paintFoot(c, v, ink);
    // The tooltip is the design's one thing that sits over the panels
    // (`z-index:5`), and the row menu and the confirmation card sit over
    // even that.
    paintTooltip(c, v, panel, ink);
    if (v.ctx_row >= 0) ref.paintCtxMenu(c, v);
    if (v.confirm >= 0) ref.paintConfirm(c, v);

    cairo.cairo_restore(c);
}

// The rail

fn catGlyph(i: usize) Glyph {
    return switch (i) {
        0 => .grid,
        1 => .check_circle,
        2 => .pen,
        3 => .play_circle,
        4 => .gamepad,
        5 => .code,
        6 => .sliders,
        else => .dots,
    };
}

fn sessGlyph(i: usize) Glyph {
    return switch (i) {
        0 => .lock,
        1 => .logout,
        2 => .reload,
        3 => .power,
        else => .sun,
    };
}

const sess_power: usize = 3;

fn paintStrip(c: ?*cairo.cairo_t, v: ref.View, rail: chrome.Rgb, ink: chrome.Rgb, card_alpha: f64) void {
    const cr = c orelse return;
    const g = v.rgeo;

    // The strip, and the hairline down its right edge that separates it from
    // the main column (the design's `border-right`).
    cairo.cairo_rectangle(cr, 0.0, 0.0, g.strip.w, g.h);
    setInk(cr, rail, card_a * card_alpha);
    cairo.cairo_fill(cr);
    setInk(cr, ink, line_a);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_move_to(cr, g.strip.w - 0.5, 0.0);
    cairo.cairo_line_to(cr, g.strip.w - 0.5, g.h);
    cairo.cairo_stroke(cr);

    // The categories. The active one keeps the accent and the tint whether or
    // not the pointer is on it; the rest light to the text colour on hover.
    const on: i32 = if (v.sel_pill < 0) 0 else v.sel_pill;
    for (g.cat, 0..) |r, i| {
        const idx: i32 = @intCast(i);
        const active = idx == on;
        const hover = v.hover_pill == idx;
        if (active or hover) {
            helpers.roundedRect(cr, r.x, r.y, r.w, r.h, layout.strip_btn_r);
            if (active) {
                setInk(cr, v.colors.accent, sel_a);
            } else {
                setInk(cr, ink, hover_a);
            }
            cairo.cairo_fill(cr);
        }
        const hot = active or hover;
        const col = if (active) v.colors.accent else ink;
        paintGlyph(cr, catGlyph(i), r.x + r.w * 0.5, r.y + r.h * 0.5, layout.strip_icon, col, if (hot) glyph_hot_a else glyph_a);
    }

    // The session group. Power turns to the danger colour under the pointer,
    // the way the design's own `.pwr:hover` does.
    for (g.sess, 0..) |r, i| {
        const hover = v.hover_power == @as(i32, @intCast(i));
        if (hover) {
            helpers.roundedRect(cr, r.x, r.y, r.w, r.h, layout.strip_btn_r);
            setInk(cr, ink, hover_a);
            cairo.cairo_fill(cr);
        }
        const col: chrome.Rgb = if (hover and i == sess_power) v.colors.notif_ol else ink;
        paintGlyph(cr, sessGlyph(i), r.x + r.w * 0.5, r.y + r.h * 0.5, layout.strip_icon, col, if (hover) glyph_hot_a else glyph_a);
    }

    // The hairline between the two groups, wherever the flexible gap left it.
    setInk(cr, ink, line_a);
    cairo.cairo_set_line_width(cr, layout.strip_sep_h);
    cairo.cairo_move_to(cr, (g.strip.w - layout.strip_sep_w) * 0.5, g.sep_y + layout.strip_sep_h * 0.5);
    cairo.cairo_line_to(cr, (g.strip.w + layout.strip_sep_w) * 0.5, g.sep_y + layout.strip_sep_h * 0.5);
    cairo.cairo_stroke(cr);

    // The category indicator: a 2x20 bar rounded on its right side only,
    // sliding between the buttons as one tween (`bar_y` is already eased).
    const by = v.bar_y;
    const r = layout.strip_bar_r;
    const w = layout.strip_bar_w;
    const h = layout.strip_bar_h;
    cairo.cairo_new_sub_path(cr);
    cairo.cairo_move_to(cr, 0.0, by);
    cairo.cairo_line_to(cr, w - r, by);
    cairo.cairo_arc(cr, w - r, by + r, r, -std.math.pi * 0.5, 0.0);
    cairo.cairo_line_to(cr, w, by + h - r);
    cairo.cairo_arc(cr, w - r, by + h - r, r, 0.0, std.math.pi * 0.5);
    cairo.cairo_line_to(cr, 0.0, by + h);
    cairo.cairo_close_path(cr);
    setInk(cr, v.colors.accent, 0.95);
    cairo.cairo_fill(cr);
}

// The search field

fn paintSearch(c: ?*cairo.cairo_t, v: ref.View, ink: chrome.Rgb) void {
    const cr = c orelse return;
    const f = v.rgeo.search;

    helpers.roundedRect(cr, f.x, f.y, f.w, f.h, layout.rail_search_r);
    setInk(cr, ink, field_a);
    cairo.cairo_fill(cr);
    // The design's focus ring: 1.5 px of accent riding the field's edge.
    if (v.focused) {
        helpers.roundedRect(cr, f.x + 0.75, f.y + 0.75, f.w - 1.5, f.h - 1.5, layout.rail_search_r - 0.75);
        setInk(cr, v.colors.accent, 0.85);
        cairo.cairo_set_line_width(cr, 1.5);
        cairo.cairo_stroke(cr);
    }

    const mid = f.y + f.h * 0.5;
    const glyph_x = f.x + layout.rail_search_pad_x + layout.rail_search_icon * 0.5;
    paintGlyph(cr, .find, glyph_x, mid, layout.rail_search_icon, ink, if (v.focused) 0.85 else 0.55);

    // The Esc keycap, right-aligned in the field.
    var kb: [24]u8 = undefined;
    var cap = ref.makeLayout(cr, ref.fontDesc(&kb, "Medium", 11.0));
    defer cap.destroy();
    cap.setText(k_esc);
    const cap_w = ref.runWidth(&cap) + 12.0;
    const cap_h: f64 = @as(f64, @floatFromInt(cap.pixelSize().h)) + 8.0;
    const cap_x = f.x + f.w - layout.rail_search_pad_x - cap_w;
    const cap_y = mid - cap_h * 0.5;
    helpers.roundedRect(cr, cap_x, cap_y, cap_w, cap_h, 5.0);
    setInk(cr, ink, line_a);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_stroke(cr);
    drawInk(cr, &cap, cap_x + 6.0, ref.midTop(&cap, mid), ink, dim_a);

    const text_x = f.x + layout.rail_search_pad_x + layout.rail_search_icon + layout.rail_search_gap;
    var buf: [32]u8 = undefined;
    var l = ref.makeLayout(cr, ref.fontDesc(&buf, "", 14.0));
    defer l.destroy();
    var caret_x = text_x;
    if (v.query.len == 0) {
        l.setText(k_placeholder);
        drawInk(cr, &l, text_x, ref.midTop(&l, mid), ink, 0.45);
        // A hair of air, so the bar does not touch the placeholder's letter.
        caret_x = text_x + 2.0;
    } else {
        const max_w = @max(0.0, cap_x - 8.0 - text_x);
        l.setText(ref.shrinkTo(&l, v.query, max_w));
        drawInk(cr, &l, text_x, ref.midTop(&l, mid), ink, 0.96);
        caret_x = text_x + ref.runWidth(&l) + 1.0;
    }
    if (v.focused and v.caret_on) {
        cairo.cairo_set_line_width(cr, 1.5);
        setInk(cr, ink, 0.90);
        cairo.cairo_move_to(cr, caret_x, mid - 9.0);
        cairo.cairo_line_to(cr, caret_x, mid + 9.0);
        cairo.cairo_stroke(cr);
    }
}

// The section header

fn metaTitle(v: ref.View) []const u8 {
    if (v.sel_pill <= 0) return k_all_apps;
    const i: usize = @intCast(v.sel_pill - 1);
    return cat.bucket_labels[@min(i, cat.bucket_count - 1)];
}

fn paintMeta(c: ?*cairo.cairo_t, v: ref.View, ink: chrome.Rgb) void {
    const cr = c orelse return;
    const g = v.rgeo;
    const mid = g.meta_mid;

    var buf: [40]u8 = undefined;
    var title = ref.makeLayout(cr, ref.fontDesc(&buf, "SemiBold", 12.0));
    defer title.destroy();
    title.setText(metaTitle(v));
    drawInk(cr, &title, layout.strip_w + layout.rail_meta_pad_x, ref.midTop(&title, mid), ink, 0.95);

    var nbuf: [48]u8 = undefined;
    const n = v.hits.len;
    const count = std.fmt.bufPrint(&nbuf, "{d} {s}", .{ n, if (n == 1) "app" else "apps" }) catch "0 apps";
    var num = ref.makeLayout(cr, ref.fontDesc(&buf, "", 12.0));
    defer num.destroy();
    num.setText(count);
    drawInk(cr, &num, g.w - layout.rail_meta_pad_x - ref.runWidth(&num), ref.midTop(&num, mid), ink, dim_a);
}

// The list

/// The hit index the viewport starts at: whole rows only, because the surface
/// holds the list from this row down and the fraction into it is applied at
/// blit time. That is what makes the wheel scroll smoothly instead of in
/// 38 px steps.
fn firstVisible(v: ref.View) usize {
    if (v.hits.len == 0) return 0;
    const row: f64 = @floor(@max(0.0, v.scroll) / layout.rail_row_h);
    return @min(@as(usize, @intFromFloat(row)), v.hits.len - 1);
}

fn ensureList(v: ref.View, ink: chrome.Rgb) ?*cairo.cairo_surface_t {
    const res = v.res;
    const b0 = v.rgeo.body;
    const cw: i32 = @intFromFloat(@ceil(b0.w));
    const ch: i32 = @intFromFloat(@ceil(@max(1.0, b0.h)));
    const first = firstVisible(v);
    const b = &res.rail_body;
    if (b.cr == null or b.w != cw or b.h != ch or b.gen != v.gen or b.first != first) {
        b.rebuild(cw, ch, v.gen, true);
        b.first = first;
        if (b.cr) |bcr| paintListContent(bcr, v, ink, first);
    }
    return b.surf;
}

fn paintList(c: ?*cairo.cairo_t, v: ref.View, ink: chrome.Rgb) void {
    const cr = c orelse return;
    const b = v.rgeo.body;
    cairo.cairo_save(cr);
    cairo.cairo_rectangle(cr, b.x, b.y, b.w, b.h);
    cairo.cairo_clip(cr);
    if (ensureList(v, ink)) |surf| {
        const first = @as(f64, @floatFromInt(firstVisible(v))) * layout.rail_row_h;
        cairo.cairo_set_source_surface(cr, surf, b.x, b.y - (v.scroll - first));
        cairo.cairo_paint(cr);
    }
    paintScrollbar(cr, v, ink);
    cairo.cairo_restore(cr);
}

/// Draws the rows the surface holds, in surface-local coordinates: row `first`
/// is at the top of the surface and the scroll's fraction into it is applied
/// where the surface is blitted.
fn paintListContent(cr: ?*cairo.cairo_t, v: ref.View, ink: chrome.Rgb, first: usize) void {
    if (v.hits.len == 0) {
        paintEmpty(cr, v, ink);
        return;
    }
    const band = v.rgeo.body.h;
    var i = first;
    while (i < v.hits.len) : (i += 1) {
        const y = @as(f64, @floatFromInt(i - first)) * layout.rail_row_h;
        if (y >= band) break;
        paintRow(cr, v, ink, v.hits[i], i, y);
    }
}

fn paintEmpty(cr: ?*cairo.cairo_t, v: ref.View, ink: chrome.Rgb) void {
    const c = cr orelse return;
    const b = v.rgeo.body;
    const q = std.mem.trim(u8, v.query, " \t");
    var buf: [192]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "No apps match \u{201C}{s}\u{201D}. Clear the search or pick another category.",
        .{q},
    ) catch "No apps match. Clear the search or pick another category.";

    var fbuf: [32]u8 = undefined;
    var l = ref.makeLayout(c, ref.fontDesc(&fbuf, "", 13.0));
    defer l.destroy();
    l.setText(msg);
    // The design centres its empty state in the list's own width and lets it
    // take the lines it needs.
    l.setWidthUnits(@intFromFloat((b.w - 40.0) * 1024.0));
    l.setAlignment(1); // PANGO_ALIGN_CENTER
    drawInk(c, &l, 20.0, 36.0, ink, dim_a);
}

fn paintRow(cr: ?*cairo.cairo_t, v: ref.View, ink: chrome.Rgb, idx: usize, i: usize, y: f64) void {
    const c = cr orelse return;
    const w = v.rgeo.body.w;
    const h = layout.rail_row_h;
    const mid = y + h * 0.5;

    if (v.sel == @as(i32, @intCast(i))) {
        helpers.roundedRect(c, 0.0, y, w, h, layout.rail_row_r);
        setInk(c, v.colors.accent, sel_a);
        cairo.cairo_fill(cr);
    }

    const e = v.entries[idx];
    const tx = layout.rail_row_pad_x;
    const ty = y + (h - layout.rail_tile) * 0.5;
    if (!ref.paintIcon(c, v, e, tx, ty, layout.rail_tile)) {
        paintTile(c, ink, e.name, tx, ty);
    }

    const name_x = tx + layout.rail_tile + layout.rail_row_gap;
    var max_w = w - name_x - layout.rail_row_pad_x;
    if (v.sel_pill <= 0) {
        // "All apps": the row carries its category on the right, the way the
        // design does, and the name stops short of it.
        const label = cat.bucket_labels[@min(@intFromEnum(e.bucket), cat.bucket_count - 1)];
        var cbuf: [24]u8 = undefined;
        var cl = ref.makeLayout(c, ref.fontDesc(&cbuf, "", 12.0));
        defer cl.destroy();
        cl.setText(label);
        const cw = ref.runWidth(&cl);
        drawInk(c, &cl, w - layout.rail_row_pad_x - cw, ref.midTop(&cl, mid), ink, dim_a);
        max_w = @max(0.0, max_w - cw - 12.0);
    }

    var buf: [32]u8 = undefined;
    var name = ref.makeLayout(c, ref.fontDesc(&buf, "Medium", 14.0));
    defer name.destroy();
    name.setText(ref.shrinkTo(&name, e.name, @max(0.0, max_w)));
    drawInk(c, &name, name_x, ref.midTop(&name, mid), ink, 0.96);
}

/// The plate an entry with no icon of its own shows: a rounded tile with the
/// first letter of its name, in the panel's own ink rather than a colour of
/// the tile's own — the design's per-app hues have no place in a palette that
/// comes from matugen.
fn paintTile(cr: ?*cairo.cairo_t, ink: chrome.Rgb, name: []const u8, x: f64, y: f64) void {
    const c = cr orelse return;
    helpers.roundedRect(c, x, y, layout.rail_tile, layout.rail_tile, layout.rail_tile_r);
    setInk(c, ink, tile_a);
    cairo.cairo_fill(c);

    const rune = ref.firstRune(name);
    if (rune.len == 0) return;
    var up: [4]u8 = undefined;
    const glyph = upperRune(rune, &up);
    var buf: [24]u8 = undefined;
    var l = ref.makeLayout(c, ref.fontDesc(&buf, "SemiBold", 13.0));
    defer l.destroy();
    l.setText(glyph);
    const w = ref.runWidth(&l);
    drawInk(c, &l, x + (layout.rail_tile - w) * 0.5, ref.midTop(&l, y + layout.rail_tile * 0.5), ink, 0.85);
}

/// The mockup uppercases the tile's letter (`a.n[0].toUpperCase()`); a rune
/// longer than one byte is left alone rather than guessed at.
fn upperRune(rune: []const u8, buf: *[4]u8) []const u8 {
    if (rune.len != 1) return rune;
    if (!std.ascii.isLower(rune[0])) return rune;
    buf[0] = std.ascii.toUpper(rune[0]);
    return buf[0..1];
}

fn paintScrollbar(c: ?*cairo.cairo_t, v: ref.View, ink: chrome.Rgb) void {
    const cr = c orelse return;
    const g = v.rgeo;
    const content = layout.railContentHeight(v.hits.len);
    if (content <= g.body.h) return;
    const thumb_h = @max(24.0, g.body.h * g.body.h / content);
    const frac = std.math.clamp(v.scroll / @max(1.0, content - g.body.h), 0.0, 1.0);
    const y = g.body.y + frac * (g.body.h - thumb_h);
    const w = layout.rail_scroll_w;
    helpers.roundedRect(cr, g.body.x + g.body.w - w, y, w, thumb_h, w * 0.5);
    setInk(cr, ink, thumb_a);
    cairo.cairo_fill(cr);
}

// The footer

fn footText(v: ref.View) []const u8 {
    if (v.sel < 0) return "";
    const hit: usize = @intCast(v.sel);
    if (hit >= v.hits.len) return "";
    const e = v.entries[v.hits[hit]];
    return if (e.comment.len > 0) e.comment else e.generic;
}

fn paintFoot(c: ?*cairo.cairo_t, v: ref.View, ink: chrome.Rgb) void {
    const cr = c orelse return;
    const g = v.rgeo;
    const mid = g.foot_y + layout.rail_foot_h * 0.5;

    // The hairline spans the main column only: the strip's own edge carries on
    // to the corner, which is what the design's two-panel split looks like.
    setInk(cr, ink, line_a);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_move_to(cr, layout.strip_w, g.foot_y + 0.5);
    cairo.cairo_line_to(cr, g.w, g.foot_y + 0.5);
    cairo.cairo_stroke(cr);

    // "Enter  Open", right-aligned.
    var obuf: [16]u8 = undefined;
    var open = ref.makeLayout(cr, ref.fontDesc(&obuf, "", 12.0));
    defer open.destroy();
    open.setText(k_open);
    const open_w = ref.runWidth(&open);

    var ebuf: [24]u8 = undefined;
    var cap = ref.makeLayout(cr, ref.fontDesc(&ebuf, "Medium", 11.0));
    defer cap.destroy();
    cap.setText(k_enter);
    const cap_w = ref.runWidth(&cap) + 12.0;
    const cap_h: f64 = @as(f64, @floatFromInt(cap.pixelSize().h)) + 8.0;
    const hint_right = g.w - layout.rail_foot_pad_x;
    const open_x = hint_right - open_w;
    const cap_x = open_x - 6.0 - cap_w;
    helpers.roundedRect(cr, cap_x, mid - cap_h * 0.5, cap_w, cap_h, 5.0);
    setInk(cr, ink, line_a);
    cairo.cairo_stroke(cr);
    drawInk(cr, &cap, cap_x + 6.0, ref.midTop(&cap, mid), ink, dim_a);
    drawInk(cr, &open, open_x, ref.midTop(&open, mid), ink, dim_a);

    // The highlighted app's description, or the note that just took its
    // place ("Opening Foo", "Shell reloaded").
    const note = v.toast.len > 0;
    const body_text = if (note) v.toast else footText(v);
    if (body_text.len == 0) return;
    const x = layout.strip_w + layout.rail_foot_pad_x;
    const max_w = @max(0.0, cap_x - 12.0 - x);
    var tbuf: [32]u8 = undefined;
    var l = ref.makeLayout(cr, ref.fontDesc(&tbuf, "", 12.0));
    defer l.destroy();
    l.setText(ref.shrinkTo(&l, body_text, max_w));
    drawInk(cr, &l, x, ref.midTop(&l, mid), ink, if (note) 0.75 else dim_a);
}

// The tooltip

fn paintTooltip(c: ?*cairo.cairo_t, v: ref.View, panel: chrome.Rgb, ink: chrome.Rgb) void {
    const cr = c orelse return;
    if (v.tip_a <= 0.0) return;
    const g = v.rgeo;
    var r: layout.Rect = .{};
    var nbuf: [48]u8 = undefined;
    var label: []const u8 = "";
    if (v.hover_pill >= 0) {
        const i: usize = @min(@as(usize, @intCast(v.hover_pill)), layout.strip_cat_count - 1);
        r = g.cat[i];
        const base: []const u8 = if (i == 0) "All" else cat.bucket_labels[@min(i - 1, cat.bucket_count - 1)];
        const n = if (i == 0) v.total else v.buckets[@min(i - 1, cat.bucket_count - 1)];
        // The design's own tooltip carries the category's count.
        label = std.fmt.bufPrint(&nbuf, "{s} ({d})", .{ base, n }) catch base;
    } else if (v.hover_power >= 0) {
        const i: usize = @min(@as(usize, @intCast(v.hover_power)), layout.strip_sess_count - 1);
        r = g.sess[i];
        label = layout.strip_sess[i];
    } else return;

    var buf: [24]u8 = undefined;
    var l = ref.makeLayout(cr, ref.fontDesc(&buf, "Medium", 12.0));
    defer l.destroy();
    l.setText(label);
    const box_w = ref.runWidth(&l) + layout.rail_tooltip_pad_x * 2.0;
    const box_h = layout.rail_tooltip_h;
    const x = r.x + r.w + layout.rail_tooltip_gap;
    const y = r.y + r.h * 0.5 - box_h * 0.5;

    setInk(cr, ink, tip_plate_a * v.tip_a);
    helpers.roundedRect(cr, x, y, box_w, box_h, layout.rail_tooltip_r);
    cairo.cairo_fill(cr);
    // The design paints the tooltip's text in `--panel`, the card's own fill.
    drawInk(cr, &l, x + layout.rail_tooltip_pad_x, ref.midTop(&l, y + box_h * 0.5), panel, 0.98 * v.tip_a);
}

// Glyphs
//
// The rail's own figures, drawn rather than loaded: the design's set is
// Lucide-shaped but several of them are not in the vendored raster set (a
// circled check, a pen, a sliders pair), and drawing them keeps the rail off
// the raster path entirely. Every figure is the design's 24-unit path, so the
// 1.7 stroke scales down with it.

const Glyph = enum {
    grid,
    check_circle,
    pen,
    play_circle,
    gamepad,
    code,
    sliders,
    dots,
    lock,
    logout,
    reload,
    power,
    sun,
    find,
};

fn paintGlyph(c: ?*cairo.cairo_t, which: Glyph, cx: f64, cy: f64, px: f64, col: chrome.Rgb, a: f64) void {
    const cr = c orelse return;
    cairo.cairo_save(cr);
    cairo.cairo_translate(cr, cx - px * 0.5, cy - px * 0.5);
    cairo.cairo_scale(cr, px / glyph_box, px / glyph_box);
    setInk(cr, col, a);
    cairo.cairo_set_line_width(cr, glyph_stroke);
    cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
    cairo.cairo_set_line_join(cr, cairo.CAIRO_LINE_JOIN_ROUND);

    switch (which) {
        .grid => {
            helpers.roundedRect(cr, 3, 3, 7, 7, 1.5);
            helpers.roundedRect(cr, 14, 3, 7, 7, 1.5);
            helpers.roundedRect(cr, 3, 14, 7, 7, 1.5);
            helpers.roundedRect(cr, 14, 14, 7, 7, 1.5);
            cairo.cairo_stroke(cr);
        },
        .check_circle => {
            cairo.cairo_new_sub_path(cr);
            cairo.cairo_arc(cr, 12, 12, 9, 0, tau);
            cairo.cairo_move_to(cr, 8, 12);
            cairo.cairo_line_to(cr, 11, 15);
            cairo.cairo_line_to(cr, 16, 9);
            cairo.cairo_stroke(cr);
        },
        .pen => {
            // The nib's corner: SVG widens the design's 2.1 radius to the
            // half-circle the two points allow, so cairo gets exactly that.
            cairo.cairo_new_sub_path(cr);
            cairo.cairo_arc(cr, 18, 5, 2.1213, -2.3562, 0.7854);
            cairo.cairo_line_to(cr, 7, 19);
            cairo.cairo_line_to(cr, 3, 20);
            cairo.cairo_line_to(cr, 4, 16);
            cairo.cairo_close_path(cr);
            cairo.cairo_move_to(cr, 12, 20);
            cairo.cairo_line_to(cr, 21, 20);
            cairo.cairo_stroke(cr);
        },
        .play_circle => {
            cairo.cairo_new_sub_path(cr);
            cairo.cairo_arc(cr, 12, 12, 9, 0, tau);
            cairo.cairo_move_to(cr, 10, 8.5);
            cairo.cairo_line_to(cr, 15.5, 12);
            cairo.cairo_line_to(cr, 10, 15.5);
            cairo.cairo_close_path(cr);
            cairo.cairo_stroke(cr);
        },
        .gamepad => {
            helpers.roundedRect(cr, 2.5, 7, 19, 10, 5);
            cairo.cairo_move_to(cr, 7, 10);
            cairo.cairo_line_to(cr, 7, 14);
            cairo.cairo_move_to(cr, 5, 12);
            cairo.cairo_line_to(cr, 9, 12);
            cairo.cairo_stroke(cr);
            // The pad's buttons are single dots in the design (`h.01`): the
            // round cap of a zero-length segment, which cairo draws as a
            // filled circle instead.
            cairo.cairo_new_sub_path(cr);
            cairo.cairo_arc(cr, 16, 11.5, 0.85, 0, tau);
            cairo.cairo_fill(cr);
            cairo.cairo_new_sub_path(cr);
            cairo.cairo_arc(cr, 18, 13, 0.85, 0, tau);
            cairo.cairo_fill(cr);
        },
        .code => {
            cairo.cairo_move_to(cr, 8, 8);
            cairo.cairo_line_to(cr, 4, 12);
            cairo.cairo_line_to(cr, 8, 16);
            cairo.cairo_move_to(cr, 16, 8);
            cairo.cairo_line_to(cr, 20, 12);
            cairo.cairo_line_to(cr, 16, 16);
            cairo.cairo_stroke(cr);
        },
        .sliders => {
            cairo.cairo_move_to(cr, 4, 7);
            cairo.cairo_line_to(cr, 14, 7);
            cairo.cairo_move_to(cr, 18, 7);
            cairo.cairo_line_to(cr, 20, 7);
            cairo.cairo_move_to(cr, 4, 17);
            cairo.cairo_line_to(cr, 6, 17);
            cairo.cairo_move_to(cr, 10, 17);
            cairo.cairo_line_to(cr, 20, 17);
            cairo.cairo_new_sub_path(cr);
            cairo.cairo_arc(cr, 16, 7, 2, 0, tau);
            cairo.cairo_new_sub_path(cr);
            cairo.cairo_arc(cr, 8, 17, 2, 0, tau);
            cairo.cairo_stroke(cr);
        },
        .dots => {
            cairo.cairo_new_sub_path(cr);
            cairo.cairo_arc(cr, 5, 12, 1.2, 0, tau);
            cairo.cairo_new_sub_path(cr);
            cairo.cairo_arc(cr, 12, 12, 1.2, 0, tau);
            cairo.cairo_new_sub_path(cr);
            cairo.cairo_arc(cr, 19, 12, 1.2, 0, tau);
            cairo.cairo_stroke(cr);
        },
        .lock => {
            helpers.roundedRect(cr, 5, 11, 14, 9, 2);
            cairo.cairo_move_to(cr, 8, 11);
            cairo.cairo_line_to(cr, 8, 8);
            cairo.cairo_arc(cr, 12, 8, 4, std.math.pi, 2.0 * std.math.pi);
            cairo.cairo_line_to(cr, 16, 11);
            cairo.cairo_stroke(cr);
        },
        .logout => {
            cairo.cairo_move_to(cr, 9, 4);
            cairo.cairo_line_to(cr, 6, 4);
            cairo.cairo_arc_negative(cr, 6, 6, 2, -std.math.pi * 0.5, -std.math.pi);
            cairo.cairo_line_to(cr, 4, 18);
            cairo.cairo_arc_negative(cr, 6, 18, 2, std.math.pi, std.math.pi * 0.5);
            cairo.cairo_line_to(cr, 9, 20);
            cairo.cairo_move_to(cr, 15, 8);
            cairo.cairo_line_to(cr, 19, 12);
            cairo.cairo_line_to(cr, 15, 16);
            cairo.cairo_move_to(cr, 19, 12);
            cairo.cairo_line_to(cr, 9, 12);
            cairo.cairo_stroke(cr);
        },
        .reload => {
            // Three quarters of a circle from under the tick, counter-
            // clockwise, ending where the tick's own corner points.
            cairo.cairo_new_sub_path(cr);
            cairo.cairo_arc_negative(cr, 12, 11.09, 8, 0.0, 0.7854 - tau);
            cairo.cairo_move_to(cr, 20, 5);
            cairo.cairo_line_to(cr, 20, 11);
            cairo.cairo_line_to(cr, 14, 11);
            cairo.cairo_stroke(cr);
        },
        .power => {
            cairo.cairo_move_to(cr, 12, 3);
            cairo.cairo_line_to(cr, 12, 11);
            // The design's arc runs 269 degrees counter-clockwise around a
            // centre a hair below the glyph's own.
            cairo.cairo_new_sub_path(cr);
            cairo.cairo_arc_negative(cr, 12, 12.11, 8, -2.364, -0.777 - tau);
            cairo.cairo_stroke(cr);
        },
        .sun => {
            cairo.cairo_new_sub_path(cr);
            cairo.cairo_arc(cr, 12, 12, 4, 0, tau);
            cairo.cairo_move_to(cr, 12, 2);
            cairo.cairo_line_to(cr, 12, 4);
            cairo.cairo_move_to(cr, 12, 20);
            cairo.cairo_line_to(cr, 12, 22);
            cairo.cairo_move_to(cr, 4.9, 4.9);
            cairo.cairo_line_to(cr, 6.3, 6.3);
            cairo.cairo_move_to(cr, 17.7, 17.7);
            cairo.cairo_line_to(cr, 19.1, 19.1);
            cairo.cairo_move_to(cr, 2, 12);
            cairo.cairo_line_to(cr, 4, 12);
            cairo.cairo_move_to(cr, 20, 12);
            cairo.cairo_line_to(cr, 22, 12);
            cairo.cairo_move_to(cr, 4.9, 19.1);
            cairo.cairo_line_to(cr, 6.3, 17.7);
            cairo.cairo_move_to(cr, 17.7, 6.3);
            cairo.cairo_line_to(cr, 19.1, 4.9);
            cairo.cairo_stroke(cr);
        },
        .find => {
            cairo.cairo_new_sub_path(cr);
            cairo.cairo_arc(cr, 11, 11, 7, 0, tau);
            cairo.cairo_move_to(cr, 20, 20);
            cairo.cairo_line_to(cr, 16.5, 16.5);
            cairo.cairo_stroke(cr);
        },
    }
    cairo.cairo_restore(cr);
}

// Tests

const t_view_w = layout.rail_w;
const t_view_h = layout.rail_h;

/// A rail view over a surface of the panel's own size, with a palette light
/// enough that the strip and the main column read apart in premultiplied
/// pixels (the shipped dark palette is a hair's width from black).
fn testView(res: *ref.Resources) ref.View {
    var v = ref.View{
        .geo = layout.Geo.of(layout.preferred_w, layout.preferred_h),
        .res = res,
        .style = .rail,
        .rgeo = layout.RailGeo.of(t_view_w, t_view_h),
        .sel_pill = -1,
        .total = 2,
        .buckets = @splat(0),
    };
    v.colors = chrome.Chrome{
        .dock_fill = .{ .r = 0.60, .g = 0.62, .b = 0.70 },
        .drawer_dim = .{ .r = 0.42, .g = 0.43, .b = 0.50 },
        .text = .{ .r = 0.95, .g = 0.95, .b = 0.98 },
        .accent = .{ .r = 0.90, .g = 0.20, .b = 0.30 },
        .notif_ol = .{ .r = 0.95, .g = 0.35, .b = 0.40 },
    };
    return v;
}

fn testSurface() ?*cairo.cairo_surface_t {
    const w: i32 = @intFromFloat(t_view_w);
    const h: i32 = @intFromFloat(t_view_h);
    return cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, w, h);
}

/// The pixel at (`x`, `y`) as (r, g, b), premultiplied by cairo.
fn testPixel(surf: *cairo.cairo_surface_t, x: i32, y: i32) [3]u8 {
    _ = cairo.cairo_surface_flush(surf);
    const data: [*]const u8 = @ptrCast(cairo.cairo_image_surface_get_data(surf));
    const stride: i32 = @intCast(cairo.cairo_image_surface_get_stride(surf));
    const i = @as(usize, @intCast(y)) * @as(usize, @intCast(stride)) + @as(usize, @intCast(x)) * 4;
    // Little-endian ARGB32: blue, green, red, alpha.
    return .{ data[i + 2], data[i + 1], data[i] };
}

fn testClear(surf: *cairo.cairo_surface_t) void {
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_SOURCE);
    cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo.cairo_paint(cr);
}

test "launcher-rail: the strip is a darker band under a hairline, inside the card" {
    const t = std.testing;
    var res = ref.Resources.init(t.allocator, std.testing.io);
    defer res.deinit();
    const surf = testSurface() orelse return error.TestUnexpectedResult;
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    testClear(surf);
    paint(cr, testView(&res), 1.0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);

    // The left edge carries the card's own outline; the strip beside it is
    // darker than the main column, and both are inside the rounded corner.
    const edge = testPixel(surf, 0, 210);
    const strip = testPixel(surf, 26, 210);
    const main = testPixel(surf, 300, 210);
    try t.expect(@as(u32, edge[0]) > @as(u32, strip[0]));
    try t.expect(@as(u32, strip[0]) < @as(u32, main[0]));
    // Above the card's corner radius nothing is drawn at all.
    const corner = testPixel(surf, 0, 0);
    try t.expectEqual(@as(u8, 0), corner[0]);
}

test "launcher-rail: the indicator rides bar_y in the accent, at the strip's edge" {
    const t = std.testing;
    var res = ref.Resources.init(t.allocator, std.testing.io);
    defer res.deinit();
    const surf = testSurface() orelse return error.TestUnexpectedResult;
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var v = testView(&res);
    const g = v.rgeo;
    v.bar_y = g.barY(2);
    testClear(surf);
    paint(cr, v, 1.0);

    // Inside the bar, and beside it at the same height on the button: the
    // accent's red channel is the giveaway.
    const on_bar = testPixel(surf, 1, @intFromFloat(g.barY(2) + layout.strip_bar_h * 0.5));
    const strip = testPixel(surf, 30, @intFromFloat(g.barY(2) + layout.strip_bar_h * 0.5));
    try t.expect(@as(u32, on_bar[0]) > 150);
    try t.expect(@as(u32, on_bar[0]) > @as(u32, strip[0]) + 60);
    // And it is only at `bar_y`: the first button's own middle is strip and a
    // little of the active button's own tint, never the bar's accent.
    const elsewhere = testPixel(surf, 1, @intFromFloat(g.barY(0) + layout.strip_bar_h * 0.5));
    try t.expect(@as(u32, elsewhere[0]) < 150);
}

test "launcher-rail: the tooltip plate follows the fade and the hovered button" {
    const t = std.testing;
    var res = ref.Resources.init(t.allocator, std.testing.io);
    defer res.deinit();
    const surf = testSurface() orelse return error.TestUnexpectedResult;
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var v = testView(&res);
    const g = v.rgeo;
    const r = g.cat[1];
    const px: i32 = @intFromFloat(r.x + r.w + layout.rail_tooltip_gap + 6.0);
    const py: i32 = @intFromFloat(r.y + r.h * 0.5);

    testClear(surf);
    paint(cr, v, 1.0);
    const off = testPixel(surf, px, py);

    v.hover_pill = 1;
    v.tip_a = 1.0;
    testClear(surf);
    paint(cr, v, 1.0);
    const on = testPixel(surf, px, py);
    // The plate is the ink at 0.95: unmistakably lighter than the card.
    try t.expect(@as(u32, on[0]) > @as(u32, off[0]) + 100);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}

test "launcher-rail: rows come from the hits, and the highlighted one is tinted" {
    const t = std.testing;
    var res = ref.Resources.init(t.allocator, std.testing.io);
    defer res.deinit();
    const surf = testSurface() orelse return error.TestUnexpectedResult;
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    const entries = [_]cat.Entry{
        .{ .name = "Affinity", .comment = "Photo editing" },
        .{ .name = "Alacritty", .comment = "A terminal" },
    };
    const hits = [_]usize{ 0, 1 };

    var v = testView(&res);
    v.entries = &entries;
    v.hits = &hits;
    v.sel = 1;
    v.scroll = 0.0;
    testClear(surf);
    paint(cr, v, 1.0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);

    const g = v.rgeo;
    const row_y = @as(i32, @intFromFloat(g.body.y + layout.rail_row_h * 1.5));
    // The row's right end, past the name: the selection tint alone.
    const sel = testPixel(surf, @intFromFloat(g.body.x + g.body.w - 30.0), row_y);
    const plain = testPixel(surf, @intFromFloat(g.body.x + g.body.w - 30.0), @intFromFloat(g.body.y + layout.rail_row_h * 0.5));
    try t.expect(@as(u32, sel[0]) > @as(u32, plain[0]));
    // The tile's letter plate is drawn over the tint.
    const tile = testPixel(surf, @intFromFloat(g.body.x + layout.rail_row_pad_x + 4.0), row_y);
    try t.expect(@as(u32, tile[0]) > @as(u32, sel[0]));

    // A scrolled view keeps the same rows; the surface is keyed on the row the
    // viewport starts at, so a full row of scroll rebuilds nothing visible.
    v.scroll = layout.rail_row_h;
    testClear(surf);
    paint(cr, v, 1.0);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
}
