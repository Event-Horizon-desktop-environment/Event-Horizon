//! Every number the launcher panel is drawn with, and the hit tests that go
//! with them. The panel is a fixed design size, but the compositor is free to
//! grant a different one, so all geometry is derived from the configured
//! width and height rather than baked in.
//!
//! Nothing here touches cairo: the paint module asks for a `Geo`, and the
//! input module asks for an index under a pointer. Both answers therefore
//! agree by construction.

const std = @import("std");

pub const preferred_w: f64 = 858.0;
pub const preferred_h: f64 = 680.0;

pub const margin: f64 = 20.0;
pub const search_h: f64 = 46.0;
pub const field_r: f64 = 14.0;
pub const card_r: f64 = 24.0;
pub const body_gap: f64 = 12.0;

pub const pill_h: f64 = 30.0;
pub const pill_gap: f64 = 6.0;
pub const pill_pad_x: f64 = 10.0;
pub const pill_r: f64 = pill_h * 0.5;
/// "All" plus the seven buckets.
pub const pill_count: usize = 8;

pub const cols: usize = 6;
pub const grid_gap: f64 = 8.0;
pub const icon_grid: f64 = 60.0;
pub const cell_h: f64 = 100.0;
pub const row_h: f64 = 64.0;
pub const icon_row: f64 = 46.0;
pub const row_r: f64 = 12.0;
pub const cell_r: f64 = 16.0;

pub const footer_h: f64 = 40.0;
pub const footer_bottom_margin: f64 = 8.0;
pub const power_sz: f64 = 32.0;
pub const power_r: f64 = 8.0;
pub const power_gap: f64 = 4.0;
/// Four power actions plus the nightlight toggle, which the paint sets off
/// with a hairline separator (`C++ kFooterBtnCount = 5`).
pub const power_count: usize = 5;
pub const nightlight_idx: usize = power_count - 1;

pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

pub const Geo = struct {
    w: f64 = preferred_w,
    h: f64 = preferred_h,

    search: Rect = .{},
    divider_y: f64 = 0,
    pills_y: f64 = 0,

    body: Rect = .{},
    content_bottom: f64 = 0,
    footer_divider_y: f64 = 0,
    footer_y: f64 = 0,

    cell_w: f64 = 0,
    cell_pitch: f64 = 0,
    row_pitch: f64 = 0,

    power: [power_count]Rect = @splat(.{}),

    pub fn of(w: f64, h: f64) Geo {
        var g = Geo{ .w = w, .h = h };
        g.search = .{ .x = margin, .y = margin, .w = @max(1.0, w - margin * 2.0), .h = search_h };
        g.divider_y = margin + search_h + body_gap;
        g.pills_y = g.divider_y + body_gap;
        g.body = .{
            .x = margin,
            .y = g.pills_y + pill_h + body_gap,
            .w = @max(1.0, w - margin * 2.0),
            .h = 1.0,
        };
        g.footer_y = h - footer_bottom_margin - footer_h;
        g.content_bottom = g.footer_y - 4.0;
        g.footer_divider_y = g.footer_y - 2.0;
        g.body.h = @max(1.0, g.content_bottom - g.body.y);

        g.cell_w = g.cellWidth();
        g.cell_pitch = g.cell_w + grid_gap;
        g.row_pitch = row_h;

        const total: f64 = @floatFromInt(power_count);
        const span = total * power_sz + (total - 1.0) * power_gap;
        const x0 = (w - span) * 0.5;
        const py = g.footer_y + (footer_h - power_sz) * 0.5;
        for (0..power_count) |i| {
            const off: f64 = @floatFromInt(i);
            g.power[i] = .{ .x = x0 + off * (power_sz + power_gap), .y = py, .w = power_sz, .h = power_sz };
        }
        return g;
    }

    pub fn cellWidth(self: Geo) f64 {
        const n: f64 = @floatFromInt(cols);
        return (self.body.w - grid_gap * (n - 1.0)) / n;
    }

    pub fn maxScroll(self: Geo, n: usize, list_mode: bool) f64 {
        return @max(0.0, contentHeight(n, list_mode) - self.body.h);
    }

    /// X of the hairline the paint draws between the power group and the
    /// nightlight toggle — where the C++ panel put its separator: just past
    /// the last power button's right edge.
    pub fn powerSeparatorX(self: Geo) f64 {
        return self.power[nightlight_idx - 1].x + power_sz + power_gap * 1.5;
    }
};

/// How tall the scrollable content is for `n` entries. Grid rows are a fixed
/// height, so this is the same number whatever the panel was sized to.
pub fn contentHeight(n: usize, list_mode: bool) f64 {
    if (n == 0) return 0.0;
    if (list_mode) return @as(f64, @floatFromInt(n)) * row_h;
    const per: f64 = @floatFromInt(cols);
    const rows = @ceil(@as(f64, @floatFromInt(n)) / per);
    return rows * (cell_h + grid_gap);
}

pub const Zone = enum { none, search, pill, row, power };

/// The order matters only in that the regions do not overlap; the search
/// field, the pill band and the body band are stacked, and the power strip
/// sits below all of them.
pub fn zoneAt(g: Geo, lx: f64, ly: f64) Zone {
    if (g.search.contains(lx, ly)) return .search;
    if (lx >= g.body.x and lx < g.body.x + g.body.w) {
        if (ly >= g.pills_y and ly < g.pills_y + pill_h) return .pill;
        if (ly >= g.body.y and ly <= g.content_bottom) return .row;
    }
    for (g.power) |r| {
        if (r.contains(lx, ly)) return .power;
    }
    return .none;
}

pub fn powerIndexAt(g: Geo, lx: f64, ly: f64) ?usize {
    for (g.power, 0..) |r, i| {
        if (r.contains(lx, ly)) return i;
    }
    return null;
}

/// The grid cell under a point, `scroll` pixels of content already moved up.
pub fn cellIndexAt(g: Geo, lx: f64, ly: f64, scroll: f64, n: usize) ?usize {
    const rel_x = lx - g.body.x;
    if (rel_x < 0 or rel_x >= g.body.w) return null;
    const col_i = rel_x / g.cell_pitch;
    const col: usize = @intFromFloat(@floor(col_i));
    if (col >= cols) return null;
    if (col_i - @floor(col_i) > g.cell_w / g.cell_pitch) return null;
    const rel_y = ly - g.body.y + scroll;
    if (rel_y < 0) return null;
    const pitch = cell_h + grid_gap;
    const row: usize = @intFromFloat(@floor(rel_y / pitch));
    const idx = row * cols + col;
    if (idx >= n) return null;
    return idx;
}

/// The list row under a point, in list (rather than grid) mode.
pub fn rowIndexAt(g: Geo, lx: f64, ly: f64, scroll: f64, n: usize) ?usize {
    const rel_x = lx - g.body.x;
    if (rel_x < 0 or rel_x >= g.body.w) return null;
    const rel_y = ly - g.body.y + scroll;
    if (rel_y < 0) return null;
    const idx: usize = @intFromFloat(@floor(rel_y / row_h));
    if (idx >= n) return null;
    return idx;
}

/// Where each pill starts inside a `band_w`-wide run. When the run is wider
/// than the band the selected pill is pulled to the middle instead of being
/// left off the edge, so the active category is always visible.
pub fn pillOffsets(out: []f64, widths: []const f64, band_w: f64, selected: i32) void {
    var total: f64 = 0;
    for (widths, 0..) |w, i| {
        out[i] = total;
        total += w + pill_gap;
    }
    if (widths.len > 0) total -= pill_gap;
    var shift: f64 = 0;
    if (total <= band_w) {
        shift = (band_w - total) * 0.5;
    } else if (selected >= 0 and selected < @as(i32, @intCast(widths.len))) {
        const sel: usize = @intCast(selected);
        shift = band_w * 0.5 - (out[sel] + widths[sel] * 0.5);
        shift = std.math.clamp(shift, band_w - total, 0.0);
    }
    for (widths, 0..) |_, i| out[i] += shift;
}

/// Which pill covers a point. The gaps between pills belong to no pill, so
/// the band alone does not decide.
pub fn pillIndexAt(g: Geo, offsets: []const f64, widths: []const f64, lx: f64, ly: f64) ?i32 {
    if (ly < g.pills_y or ly >= g.pills_y + pill_h) return null;
    if (lx < g.body.x or lx >= g.body.x + g.body.w) return null;
    for (offsets, widths, 0..) |ox, pw, i| {
        const x0 = g.body.x + ox;
        if (lx >= x0 and lx < x0 + pw) return @intCast(i);
    }
    return null;
}

/// Left edge of pill `i` in card coordinates.
pub fn pillLeft(g: Geo, offsets: []const f64, i: usize) f64 {
    return g.body.x + offsets[i];
}

/// Which launcher panel is being drawn. The App menu opens the rail panel;
/// the reference panel still serves the App drawer and the start menu, and
/// the two share nothing but the confirmation card and the row menu.
pub const Style = enum { classic, rail };

// ---------------------------------------------------------------------
// The rail panel (the App menu)
// ---------------------------------------------------------------------
//
// A 540x420 card with the categories on a 52 px rail down the left edge, the
// search field across the top of the main column, one 38 px row per app and
// the highlighted app's description along the bottom. The design sizes
// everything; the compositor may still hand over a smaller drawable, so the
// derived numbers follow `w`/`h` the same way `Geo` does.

pub const rail_w: f64 = 540.0;
pub const rail_h: f64 = 420.0;
pub const rail_r: f64 = 14.0;

pub const strip_w: f64 = 52.0;
pub const strip_pad_v: f64 = 10.0;
/// The design's 36x36. Thirteen buttons plus the separator do not fit a
/// 420 px rail, so this is the ceiling, not the size: `stripBtnFor` follows
/// the panel the way the mockup's flex column does (about 26 px at 420).
pub const strip_btn_max: f64 = 36.0;
pub const strip_btn_r: f64 = 9.0;
pub const strip_btn_gap: f64 = 4.0;
pub const strip_icon: f64 = 18.0;
pub const strip_bar_w: f64 = 2.0;
pub const strip_bar_h: f64 = 20.0;
pub const strip_bar_r: f64 = 2.0;
pub const strip_sep_w: f64 = 20.0;
pub const strip_sep_h: f64 = 1.0;
pub const strip_sep_gap: f64 = 4.0;
/// "All" plus the seven buckets, then the four session controls and the
/// theme toggle.
pub const strip_cat_count: usize = pill_count;
pub const strip_sess_count: usize = 5;
/// The bottom group's tooltips, and what the host logs when one is pressed.
pub const strip_sess = [strip_sess_count][]const u8{ "Lock", "Log out", "Reload shell", "Power", "Toggle theme" };

/// Everything in the rail that is not a button: the two paddings, the
/// fourteen gaps between the fifteen children (the flexible spacer and the
/// separator take one each), and the separator with its margins.
pub const strip_fixed_h: f64 = strip_pad_v * 2.0 +
    @as(f64, @floatFromInt(strip_cat_count + strip_sess_count + 1)) * strip_btn_gap +
    strip_sep_h + strip_sep_gap * 2.0;

/// The height of one rail button in an `h`-tall panel.
pub fn stripBtnFor(h: f64) f64 {
    const n: f64 = @floatFromInt(strip_cat_count + strip_sess_count);
    return @min(strip_btn_max, @max(16.0, (h - strip_fixed_h) / n));
}

pub const rail_search_margin: f64 = 10.0;
pub const rail_search_h: f64 = 40.0;
pub const rail_search_r: f64 = 10.0;
pub const rail_search_pad_x: f64 = 12.0;
pub const rail_search_icon: f64 = 18.0;
pub const rail_search_gap: f64 = 10.0;

pub const rail_meta_pad_x: f64 = 18.0;
pub const rail_meta_pad_top: f64 = 12.0;
pub const rail_meta_pad_bottom: f64 = 6.0;
pub const rail_meta_line: f64 = 16.0;

pub const rail_body_pad_x: f64 = 8.0;
pub const rail_body_pad_bottom: f64 = 6.0;
pub const rail_row_h: f64 = 38.0;
pub const rail_row_r: f64 = 9.0;
pub const rail_row_pad_x: f64 = 10.0;
pub const rail_row_gap: f64 = 12.0;
pub const rail_tile: f64 = 26.0;
pub const rail_tile_r: f64 = 7.0;

pub const rail_foot_h: f64 = 36.0;
pub const rail_foot_pad_x: f64 = 16.0;

pub const rail_tooltip_gap: f64 = 10.0;
pub const rail_tooltip_h: f64 = 22.0;
pub const rail_tooltip_pad_x: f64 = 8.0;
pub const rail_tooltip_r: f64 = 7.0;

/// The wheel's scrollbar, drawn only when the list overflows.
pub const rail_scroll_w: f64 = 3.0;

pub const RailGeo = struct {
    w: f64 = rail_w,
    h: f64 = rail_h,

    /// The strip itself, 52 px of the card's left edge.
    strip: Rect = .{},
    /// One rect per rail button: the eight categories at the top, then the
    /// four session controls and the theme toggle at the bottom.
    cat: [strip_cat_count]Rect = @splat(.{}),
    sess: [strip_sess_count]Rect = @splat(.{}),
    /// Top edge of the hairline above the session group, wherever the
    /// flexible gap between the groups leaves it.
    sep_y: f64 = 0,

    search: Rect = .{},
    /// Vertical centre of the section title / count line.
    meta_mid: f64 = 0,
    body: Rect = .{},
    /// Where the footer's hairline sits — also the top of the footer band.
    foot_y: f64 = 0,

    pub fn of(w: f64, h: f64) RailGeo {
        var g = RailGeo{ .w = w, .h = h };
        g.strip = .{ .x = 0, .y = 0, .w = strip_w, .h = h };

        // Categories stack from the top, session controls from the bottom,
        // and the separator sits just above the session group; the flexible
        // gap falls wherever the two ends leave it.
        const size = stripBtnFor(h);
        const bx = (strip_w - strip_btn_max) * 0.5;
        for (0..strip_cat_count) |i| {
            const y = strip_pad_v + @as(f64, @floatFromInt(i)) * (size + strip_btn_gap);
            g.cat[i] = .{ .x = bx, .y = y, .w = strip_btn_max, .h = size };
        }
        const n: f64 = @floatFromInt(strip_sess_count);
        const sess_span = n * size + (n - 1.0) * strip_btn_gap;
        const sess_y0 = h - strip_pad_v - sess_span;
        for (0..strip_sess_count) |i| {
            const y = sess_y0 + @as(f64, @floatFromInt(i)) * (size + strip_btn_gap);
            g.sess[i] = .{ .x = bx, .y = y, .w = strip_btn_max, .h = size };
        }
        g.sep_y = @max(strip_pad_v + size, sess_y0 - strip_sep_gap - strip_sep_h);

        g.search = .{
            .x = strip_w + rail_search_margin,
            .y = rail_search_margin,
            .w = @max(1.0, w - strip_w - rail_search_margin * 2.0),
            .h = rail_search_h,
        };
        g.meta_mid = g.search.y + g.search.h + rail_meta_pad_top + rail_meta_line * 0.5;
        g.foot_y = h - rail_foot_h;
        g.body = .{
            .x = strip_w + rail_body_pad_x,
            .y = g.search.y + g.search.h + rail_meta_pad_top + rail_meta_line + rail_meta_pad_bottom,
            .w = @max(1.0, w - strip_w - rail_body_pad_x * 2.0),
            .h = 1.0,
        };
        g.body.h = @max(1.0, g.foot_y - g.body.y - rail_body_pad_bottom);
        return g;
    }

    /// Y of the category indicator when it sits on button `i`. The bar is
    /// centred on its button; the paint slides between two of these.
    pub fn barY(self: RailGeo, i: usize) f64 {
        const r = self.cat[@min(i, strip_cat_count - 1)];
        return r.y + (r.h - strip_bar_h) * 0.5;
    }

    pub fn maxScroll(self: RailGeo, n: usize) f64 {
        return @max(0.0, railContentHeight(n) - self.body.h);
    }

    /// Whole rows the body has room for — one `PageUp`/`PageDown` step.
    pub fn pageRows(self: RailGeo) usize {
        return @max(1, @as(usize, @intFromFloat(@floor(self.body.h / rail_row_h))));
    }
};

/// How tall the rail's scrollable content is for `n` entries.
pub fn railContentHeight(n: usize) f64 {
    return @as(f64, @floatFromInt(n)) * rail_row_h;
}

pub fn railCatAt(g: RailGeo, lx: f64, ly: f64) ?usize {
    for (g.cat, 0..) |r, i| {
        if (r.contains(lx, ly)) return i;
    }
    return null;
}

pub fn railSessAt(g: RailGeo, lx: f64, ly: f64) ?usize {
    for (g.sess, 0..) |r, i| {
        if (r.contains(lx, ly)) return i;
    }
    return null;
}

/// The list row under a point, in the rail's own pitch. The body band clips
/// the answer: a press in the footer is not a row.
pub fn railRowIndexAt(g: RailGeo, lx: f64, ly: f64, scroll: f64, n: usize) ?usize {
    if (!g.body.contains(lx, ly)) return null;
    const rel_y = ly - g.body.y + scroll;
    if (rel_y < 0) return null;
    const idx: usize = @intFromFloat(@floor(rel_y / rail_row_h));
    if (idx >= n) return null;
    return idx;
}

// The menu a right press on a row asks for: 232 px wide however short the
// label, 28 px per item, 8 px of padding, and kept `margin` inside the card
// whatever corner of it the press landed in. The reference panel allows up to
// three items; this panel's menu has one.
pub const ctx_item_h: f64 = 28.0;
pub const ctx_pad: f64 = 8.0;
pub const ctx_min_w: f64 = 232.0;
pub const ctx_r: f64 = 10.0;
pub const ctx_item_r: f64 = 6.0;
pub const ctx_inset: f64 = 4.0;
pub const ctx_text_x: f64 = 12.0;
pub const ctx_items: i32 = 1;

/// The menu's rect for a press anchored at (`ax`, `ay`), clamped to the card.
/// The rect is derived from the anchor on every frame rather than stored, so
/// the panel, the painter and the picker can never disagree about where it is.
pub fn ctxRect(g: Geo, ax: f64, ay: f64) Rect {
    const w = ctx_min_w;
    const h = ctx_pad * 2.0 + @as(f64, @floatFromInt(ctx_items)) * ctx_item_h;
    const x = @min(@max(ax, margin), @max(margin, g.w - w - margin));
    const y = @min(@max(ay, margin), @max(margin, g.h - h - margin));
    return .{ .x = x, .y = y, .w = w, .h = h };
}

/// The item under a point, or -1 when the point is outside the menu or in its
/// padding.
pub fn ctxPick(r: Rect, lx: f64, ly: f64) i32 {
    if (!r.contains(lx, ly)) return -1;
    const rel = ly - r.y - ctx_pad;
    if (rel < 0) return -1;
    const i: i32 = @intFromFloat(@floor(rel / ctx_item_h));
    return if (i >= 0 and i < ctx_items) i else -1;
}

/// The confirmation card that stands between a power button and the action
/// it asks for. Fixed height, centred in the panel.
pub const Modal = struct {
    box: Rect = .{},
    title_y: f64 = 0,
    body_y: f64 = 0,
    cancel: Rect = .{},
    confirm: Rect = .{},
};

pub const ModalBtn = enum { none, cancel, confirm };

pub const modal_h: f64 = 192.0;
pub const modal_w_max: f64 = 400.0;
pub const modal_btn_h: f64 = 48.0;
pub const modal_gap: f64 = 10.0;
pub const modal_pad: f64 = 20.0;

pub fn modalOf(g: Geo) Modal {
    const w = @min(modal_w_max, g.w - 32.0);
    const x = (g.w - w) * 0.5;
    const y = (g.h - modal_h) * 0.5;
    const inner_w = w - modal_pad * 2.0;
    const half = (inner_w - modal_gap) * 0.5;
    const btn_y = y + modal_h - modal_pad - modal_btn_h;
    return .{
        .box = .{ .x = x, .y = y, .w = w, .h = modal_h },
        .title_y = y + modal_pad,
        .body_y = y + modal_pad + 36.0 + 8.0,
        .cancel = .{ .x = x + modal_pad, .y = btn_y, .w = half, .h = modal_btn_h },
        .confirm = .{ .x = x + modal_pad + half + modal_gap, .y = btn_y, .w = half, .h = modal_btn_h },
    };
}

pub fn modalHit(g: Geo, lx: f64, ly: f64) ModalBtn {
    const m = modalOf(g);
    if (m.cancel.contains(lx, ly)) return .cancel;
    if (m.confirm.contains(lx, ly)) return .confirm;
    return .none;
}

const utf8_cont: u8 = 0xC0;

pub fn runeCount(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if ((c & utf8_cont) != 0x80) n += 1;
    }
    return n;
}

pub fn truncRunes(s: []const u8, max: usize) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if ((s[i] & utf8_cont) == 0x80) continue;
        if (n == max) return s[0..i];
        n += 1;
    }
    return s;
}

fn runeOffset(s: []const u8, index: usize) ?usize {
    var n: usize = 0;
    var i: usize = 0;
    if (index == 0) return 0;
    while (i < s.len) : (i += 1) {
        if ((s[i] & utf8_cont) == 0x80) continue;
        n += 1;
        if (n == index) return i;
    }
    return null;
}

/// The one or two label lines a grid cell shows. Long names break at the
/// space nearest the middle and the tail is shortened to one line's worth.
/// `buf` carries the shortened tail; when no shortening is needed the second
/// line is a slice of `name` and `buf` is left alone.
pub fn labelLines(buf: *[80]u8, name: []const u8) [2][]const u8 {
    const total = runeCount(name);
    if (total <= 16) return .{ name, "" };

    const mid = name.len / 2;
    var best: ?usize = null;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] != ' ') continue;
        if (i == 0 or i + 1 >= name.len) continue;
        const d = if (i > mid) i - mid else mid - i;
        const bd = if (best) |b| (if (b > mid) b - mid else mid - b) else std.math.maxInt(usize);
        if (d < bd) best = i;
    }
    const cut = best orelse (runeOffset(name, total / 2) orelse name.len);
    const head = name[0..cut];
    var tail = std.mem.trim(u8, name[cut..], " ");
    if (runeCount(tail) > 18) {
        tail = truncRunes(tail, 17);
        const n = @min(tail.len, buf.len -| 3);
        @memcpy(buf[0..n], tail[0..n]);
        @memcpy(buf[n .. n + 3], "\u{2026}");
        tail = buf[0 .. n + 3];
    }
    return .{ head, tail };
}

test "launcher-layout: the stacked regions land on whole numbers" {
    const t = std.testing;
    const g = Geo.of(preferred_w, preferred_h);
    try t.expectApproxEqAbs(@as(f64, 78.0), g.divider_y, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 90.0), g.pills_y, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 132.0), g.body.y, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 632.0), g.footer_y, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 628.0), g.content_bottom, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 496.0), g.body.h, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 129.666666), g.cell_w, 1e-4);
    try t.expectApproxEqAbs(@as(f64, 137.666666), g.cell_pitch, 1e-4);
    try t.expectApproxEqAbs(@as(f64, 341.0), g.power[0].x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 636.0), g.power[0].y, 1e-9);
    // Five buttons: the nightlight toggle is last, with the separator just
    // past the fourth button's right edge.
    try t.expectApproxEqAbs(@as(f64, 485.0), g.power[nightlight_idx].x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 487.0), g.powerSeparatorX(), 1e-9);
}

test "launcher-layout: zones stack without overlapping" {
    const t = std.testing;
    const g = Geo.of(preferred_w, preferred_h);
    try t.expectEqual(Zone.search, zoneAt(g, 100, 40));
    try t.expectEqual(Zone.pill, zoneAt(g, 100, 95));
    try t.expectEqual(Zone.row, zoneAt(g, 100, 200));
    try t.expectEqual(Zone.power, zoneAt(g, g.power[2].x + 4, g.power[2].y + 4));
    try t.expectEqual(Zone.none, zoneAt(g, 5, 300));
    try t.expectEqual(Zone.none, zoneAt(g, 100, 660));
    try t.expectEqual(@as(?usize, 2), powerIndexAt(g, g.power[2].x + 4, g.power[2].y + 4));
    try t.expectEqual(@as(?usize, nightlight_idx), powerIndexAt(g, g.power[nightlight_idx].x + 4, g.power[nightlight_idx].y + 4));
}

test "launcher-layout: grid and list picking round-trip through the scroll" {
    const t = std.testing;
    const g = Geo.of(preferred_w, preferred_h);
    const n = 40;
    try t.expectEqual(@as(?usize, 0), cellIndexAt(g, g.body.x + 1, g.body.y + 1, 0, n));
    try t.expectEqual(@as(?usize, 1), cellIndexAt(g, g.body.x + g.cell_pitch + 1, g.body.y + 1, 0, n));
    try t.expect(cellIndexAt(g, g.body.x + g.cell_pitch - 1, g.body.y + 1, 0, n) == null);
    // Scrolling 108px brings the second row up to where the first was.
    try t.expectEqual(@as(?usize, 6), cellIndexAt(g, g.body.x + 1, g.body.y + 1, 108, n));
    try t.expectEqual(@as(?usize, 6), cellIndexAt(g, g.body.x + g.cell_w * 0.5, g.body.y + (cell_h + grid_gap) + 4, 0, n));
    try t.expectEqual(@as(?usize, 35), cellIndexAt(g, g.body.x + g.cell_pitch * 5 + 1, g.body.y + 99 + 108 * 5, 0, n));

    try t.expectEqual(@as(?usize, 0), rowIndexAt(g, g.body.x + 5, g.body.y + 5, 0, n));
    try t.expectEqual(@as(?usize, 1), rowIndexAt(g, g.body.x + 5, g.body.y + 5, 64, n));

    try t.expectApproxEqAbs(@as(f64, 7 * 108), contentHeight(40, false), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 40 * 64), contentHeight(40, true), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 7 * 108 - 496), g.maxScroll(40, false), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 0), g.maxScroll(2, false), 1e-9);
}

test "launcher-layout: a short pill run centers, a long one follows the selection" {
    const t = std.testing;
    const widths = [3]f64{ 60.0, 40.0, 50.0 };
    var xs: [3]f64 = undefined;

    pillOffsets(&xs, &widths, 400, 0);
    const short_total = 60.0 + 6.0 + 40.0 + 6.0 + 50.0;
    try t.expectApproxEqAbs((400.0 - short_total) * 0.5, xs[0], 1e-9);
    try t.expectApproxEqAbs(xs[0] + 66.0, xs[1], 1e-9);

    const wide = [3]f64{ 300.0, 300.0, 300.0 };
    pillOffsets(&xs, &wide, 400, 1);
    const total = 300.0 * 3 + 6.0 * 2;
    const sel_cx = xs[1] + 150.0;
    try t.expectApproxEqAbs(200.0, sel_cx, 1e-9);
    try t.expect(xs[0] <= 0.0);
    try t.expect(xs[0] >= 400.0 - total);
}

test "launcher-layout: long labels break once and get an ellipsis" {
    const t = std.testing;
    var buf: [80]u8 = undefined;
    const short = labelLines(&buf, "Files");
    try t.expectEqualStrings("Files", short[0]);
    try t.expectEqualStrings("", short[1]);

    const long = labelLines(&buf, "Ultimate Advanced Vector Graphics Editor Pro");
    try t.expect(long[1].len > 0);
    try t.expect(runeCount(long[0]) <= 24);
    try t.expect(runeCount(long[1]) <= 18);
    try t.expect(std.mem.endsWith(u8, long[1], "\u{2026}"));

    const wide = labelLines(&buf, "\u{6f22}\u{5b57}\u{306e}\u{540d}\u{524d}\u{3068}\u{3044}\u{3046}\u{9577}\u{3044}\u{30c6}\u{30ad}\u{30b9}\u{30c8}\u{304c}\u{3042}\u{308b}");
    try t.expect(wide[1].len <= buf.len);
}

test "launcher-layout: the rail panel lands on the design's numbers" {
    const t = std.testing;
    const g = RailGeo.of(rail_w, rail_h);
    try t.expectApproxEqAbs(@as(f64, 52.0), g.strip.w, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 8.0), g.cat[0].x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 36.0), g.cat[0].w, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 10.0), g.cat[0].y, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 468.0), g.search.w, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 62.0), g.search.x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 70.0), g.meta_mid, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 384.0), g.foot_y, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 84.0), g.body.y, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 472.0), g.body.w, 1e-9);
    // Seven whole rows and a bit: the design's "about eight rows".
    try t.expectApproxEqAbs(@as(f64, 294.0), g.body.h, 1e-9);
    try t.expectEqual(@as(usize, 7), g.pageRows());

    // Thirteen buttons do not fit a 420 px strip at the design's 36 px, and
    // the mockup's flex column shrinks them rather than scrolling. The
    // math is the browser's: the leftover after paddings, gaps and the
    // separator, split thirteen ways.
    try t.expectApproxEqAbs(@as(f64, 335.0 / 13.0), g.cat[0].h, 1e-6);
    try t.expectApproxEqAbs(10.0 + 7.0 * (335.0 / 13.0 + 4.0), g.cat[7].y, 1e-6);
    // The session group ends exactly on the bottom padding, and the
    // separator clears the last category.
    try t.expectApproxEqAbs(@as(f64, 410.0), g.sess[strip_sess_count - 1].y + g.sess[0].h, 1e-6);
    try t.expect(g.sep_y > g.cat[strip_cat_count - 1].y + g.cat[0].h);
    try t.expect(g.sep_y < g.sess[0].y);
    // A taller panel gives the buttons their 36 px back, and no more.
    try t.expectApproxEqAbs(@as(f64, 36.0), stripBtnFor(600.0), 1e-9);

    // The indicator is centred on its button, wherever the shrink left it.
    try t.expectApproxEqAbs(g.cat[0].y + (g.cat[0].h - strip_bar_h) * 0.5, g.barY(0), 1e-9);
    try t.expectApproxEqAbs(g.cat[7].y + (g.cat[7].h - strip_bar_h) * 0.5, g.barY(7), 1e-9);
}

test "launcher-layout: rail picks follow the panel's bands" {
    const t = std.testing;
    const g = RailGeo.of(rail_w, rail_h);
    try t.expectEqual(@as(?usize, 0), railCatAt(g, 26, 20));
    try t.expectEqual(@as(?usize, 7), railCatAt(g, 26, g.cat[7].y + 4));
    try t.expectEqual(@as(?usize, null), railCatAt(g, 26, g.sep_y + 4));
    try t.expectEqual(@as(?usize, null), railCatAt(g, 2, 20));
    try t.expectEqual(@as(?usize, 3), railSessAt(g, 26, g.sess[3].y + 4));
    try t.expectEqual(@as(?usize, null), railSessAt(g, 26, 415));
    // Rows start under the search field and stop at the footer.
    try t.expectEqual(@as(?usize, 0), railRowIndexAt(g, 100, g.body.y + 1, 0, 40));
    try t.expectEqual(@as(?usize, 1), railRowIndexAt(g, 100, g.body.y + 1, rail_row_h, 40));
    try t.expectEqual(@as(?usize, null), railRowIndexAt(g, 100, 40, 0, 40)); // the search field
    try t.expectEqual(@as(?usize, null), railRowIndexAt(g, 100, g.foot_y + 4, 0, 40)); // the footer
    try t.expectEqual(@as(?usize, null), railRowIndexAt(g, 20, 200, 0, 40)); // the strip
    try t.expectEqual(@as(?usize, null), railRowIndexAt(g, 100, g.body.y + 1, 40.0 * rail_row_h, 40));
    // Scrolled to the end, the last row lies flush with the body's bottom.
    const end = g.maxScroll(40);
    try t.expectApproxEqAbs(40.0 * rail_row_h - 294.0, end, 1e-9);
    try t.expectEqual(@as(?usize, 39), railRowIndexAt(g, 100, g.body.y + 294.0 - 1, end, 40));
    try t.expectApproxEqAbs(@as(f64, 0.0), RailGeo.of(rail_w, rail_h).maxScroll(7), 1e-9);
}
