const std = @import("std");
const common = @import("common.zig");
const app_mod = @import("app.zig");
const ui_paint = @import("ui_paint.zig");
const ui_widgets = @import("ui_widgets.zig");
const widget_lists = @import("widget_lists.zig");
const catalog = @import("widget_catalog.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const m3_box = @import("../../m3/core/primitives/box.zig");
const m3_button = @import("../../m3/controls/containers/button.zig");

// The "add widget" popup — an in-window modal card.
// The layout grows to fit its content — width from the measured widest title/description, card height from
// the longest wrapped description (clamped 72–96px), panel height capped at 82%
// of the viewport — all centred in the content area to the right of the sidebar,
// with pixel scrolling. Visually it is the dim scrim, glassy r=16 panel, header
// (icon box + title + count), outlined close button, 44px search field with a
// clear chip, 2-column clipped scrollable card grid, empty state and footer.
//
// DELIBERATE DIVERGENCE: there the picker is its own blurred
// *layer surface* (`event-horizon-settings-widget-picker`) composited over the
// settings window. Here it is a modal painted into the settings toplevel's own
// buffer, so it never becomes a layer and the Hyprland blur rule for that
// namespace does not apply to it. Everything else — geometry, fonts, colours,
// copy, and the content-driven sizing.

// M3 design constants.
const pad: i32 = 20; // kPickerPad
const header_h: i32 = 56; // kPickerHeaderH
const gap_search: i32 = 12; // kPickerGapSearch
const search_h: i32 = 44; // kPickerSearchH
const gap_grid: i32 = 12; // kPickerGapGrid
const footer_h: i32 = 22; // kPickerFooterH
const panel_r: f64 = 16.0; // kPickerPanelR
const card_r: f64 = 12.0; // kPickerCardR
const card_pad: i32 = 16; // kPickerCardPad
const icon_box: i32 = 38; // kPickerIconBox
const icon_r: f64 = 10.0; // kPickerIconR
const col_gap: i32 = 12;
const row_gap: i32 = 12;
const cols: usize = 2;
const close_w: i32 = 28; // close button
const clear_w: i32 = 26; // search clear chip
const add_chip: i32 = 24; // per-card add chip
/// Upper bound on `collect`'s output (the whole catalogue).
pub const max_candidates = catalog.ids.len;

/// Desktop-widget ids the Add flow offers on the Desktop Widgets tab
/// (desktop-only pick ids).
pub const desktop_ids = [_][]const u8{
    "clock", "weather",       "weather_fancy", "calendar", "system_monitor",
    "media", "media_compact", "world_clock",   "fetch",    "cider",
};

pub const State = struct {
    bar: widget_lists.Bar = .dock,
    col: usize = 0,
    /// Desktop Add flow: offer `desktop_ids` (no placed-exclusion — the
    /// desktop allows several clocks with distinct widget ids).
    for_desktop: bool = false,
    filter: [48]u8 = undefined,
    filter_len: usize = 0,
    /// Vertical scroll of the grid, in pixels.
    scroll_px: i32 = 0,
    /// Last grid index the pointer sat on while painting (hover hint).
    hover: usize = std.math.maxInt(usize),

    pub fn filterSlice(self: *const State) []const u8 {
        return self.filter[0..self.filter_len];
    }

    pub fn setFilter(self: *State, text: []const u8) void {
        const n = @min(text.len, self.filter.len);
        @memcpy(self.filter[0..n], text[0..n]);
        self.filter_len = n;
    }
};

/// Picker layout — every sub-rect of the panel, computed
/// from the content each frame.
pub const Layout = struct {
    px: i32 = 0,
    py: i32 = 0,
    pw: i32 = 0,
    ph: i32 = 0,
    close_x: i32 = 0,
    close_y: i32 = 0,
    close_w: i32 = close_w,
    close_h: i32 = close_w,
    search_x: i32 = 0,
    search_y: i32 = 0,
    search_w: i32 = 0,
    search_h: i32 = search_h,
    clear_x: i32 = 0,
    clear_y: i32 = 0,
    clear_w: i32 = clear_w,
    clear_h: i32 = clear_w,
    grid_x: i32 = 0,
    grid_y: i32 = 0,
    grid_w: i32 = 0,
    grid_clip_h: i32 = 0,
    grid_content_h: i32 = 0,
    grid_scroll_max: i32 = 0,
    card_w: i32 = 0,
    card_h: i32 = 0,
    col_gap: i32 = col_gap,
    row_gap: i32 = row_gap,

    pub fn panelRect(self: Layout) common.Rect {
        return .{ .x = self.px, .y = self.py, .w = self.pw, .h = self.ph };
    }
    pub fn closeRect(self: Layout) common.Rect {
        return .{ .x = self.close_x, .y = self.close_y, .w = self.close_w, .h = self.close_h };
    }
    pub fn clearRect(self: Layout) common.Rect {
        return .{ .x = self.clear_x, .y = self.clear_y, .w = self.clear_w, .h = self.clear_h };
    }
    pub fn searchRect(self: Layout) common.Rect {
        return .{ .x = self.search_x, .y = self.search_y, .w = self.search_w, .h = self.search_h };
    }
    pub fn gridRect(self: Layout) common.Rect {
        return .{ .x = self.grid_x, .y = self.grid_y, .w = self.grid_w, .h = self.grid_clip_h };
    }
};

// Measurement caches (single-threaded, repaint-driven). Title widths are stable
// per widget id; description line counts are re-measured when the wrap width
// changes — title-width and description-line-count caches.
var g_title_w: [catalog.ids.len]i32 = @splat(0);
var g_desc_wrap: i32 = -1;
var g_desc_lines: [catalog.ids.len]i32 = @splat(0);

fn idIndex(wid: []const u8) ?usize {
    for (catalog.ids, 0..) |id, i| {
        if (std.mem.eql(u8, id, wid)) return i;
    }
    return null;
}

/// Cached max(title width @14/600, description width @11/400) for a widget id.
fn widTextWidth(wid: []const u8) i32 {
    const i = idIndex(wid) orelse return 0;
    if (g_title_w[i] != 0) return g_title_w[i];
    const meta = ui_widgets.widgetMeta(wid);
    const tw = ui_paint.measureTextWidth(meta.title, 14, 600);
    const dw = ui_paint.measureTextWidth(ui_widgets.widgetDesc(wid), 11, 400);
    const m = @max(tw, dw);
    g_title_w[i] = m;
    return m;
}

/// Cached wrapped description line count for a widget id at a given wrap width.
fn widDescLines(wid: []const u8, wrap_w: i32) i32 {
    const i = idIndex(wid) orelse return 1;
    if (g_desc_wrap != wrap_w) {
        g_desc_wrap = wrap_w;
        g_desc_lines = @splat(0);
    }
    if (g_desc_lines[i] != 0) return g_desc_lines[i];
    const nl = ui_paint.measureWrappedLines(ui_widgets.widgetDesc(wid), 11, 400, wrap_w);
    g_desc_lines[i] = nl;
    return nl;
}

/// Panel layout: sizes the panel from the measured
/// content and the viewport, centred in the content area right of the sidebar.
pub fn layoutFor(
    st: *const State,
    s: *const app_mod.Settings,
    win_w: i32,
    win_h: i32,
) Layout {
    var lay: Layout = .{};
    const inset: i32 = app_mod.AppState.contentX(); // left of the content column
    var out: [max_candidates][]const u8 = undefined;
    const n = collectInto(st, s, &out);

    const content_avail_w = win_w - inset - 24;
    const viewport_cap = @max(360, content_avail_w);

    // Width: grow from measured text so titles and descriptions have room.
    var max_text_w: i32 = 0;
    for (out[0..n]) |wid| max_text_w = @max(max_text_w, widTextWidth(wid));
    const card_w_needed = card_pad + icon_box + 12 + max_text_w + 12 + add_chip + card_pad;
    const desired_pw = 2 * card_w_needed + col_gap + 2 * pad;
    const pw = std.math.clamp(desired_pw, @min(500, viewport_cap), viewport_cap);
    const card_w = @max(170, @divTrunc(pw - pad * 2 - col_gap, 2));

    // Height: wrap each description to the actual card text width and size the
    // cards uniformly to the longest one.
    const desc_wrap_w = @max(60, card_w - (card_pad + icon_box + 12) - (12 + add_chip + card_pad));
    var desc_lines: i32 = 1;
    for (out[0..n]) |wid| desc_lines = @max(desc_lines, widDescLines(wid, desc_wrap_w));
    desc_lines = std.math.clamp(desc_lines, 1, 3);
    const card_h = std.math.clamp(52 + desc_lines * 15, 72, 96);

    const max_ph = @max(300, @min(win_h - 48, @divTrunc(win_h * 82, 100)));
    const chrome = pad + header_h + gap_search + search_h + gap_grid + footer_h + pad;
    const grid_avail = @max(80, max_ph - chrome);

    const rows: i32 = if (n <= 0) 0 else @divTrunc(@as(i32, @intCast(n)) + 1, 2);
    const grid_content_h: i32 = if (rows <= 0) 0 else rows * card_h + (rows - 1) * row_gap;
    const grid_clip_h: i32 = if (rows <= 0) @min(grid_avail, 150) else @min(grid_content_h, grid_avail);
    const grid_scroll_max = @max(0, grid_content_h - grid_clip_h);

    const ph = pad + header_h + gap_search + search_h + gap_grid + grid_clip_h + footer_h + pad;

    lay.pw = pw;
    lay.ph = ph;
    const content_w = win_w - inset - 16;
    lay.px = inset + @max(0, @divTrunc(content_w - pw, 2));
    lay.py = @max(16, @divTrunc(win_h - ph, 2));

    lay.close_x = lay.px + lay.pw - pad - close_w;
    lay.close_y = lay.py + pad - 2;
    lay.search_x = lay.px + pad;
    lay.search_y = lay.py + pad + header_h;
    lay.search_w = lay.pw - pad * 2;
    lay.clear_x = lay.search_x + lay.search_w - 14 - clear_w;
    lay.clear_y = lay.search_y + @divTrunc(search_h - clear_w, 2);
    lay.grid_x = lay.px + pad;
    lay.grid_y = lay.search_y + lay.search_h + gap_grid;
    lay.grid_w = lay.pw - pad * 2;
    lay.grid_clip_h = grid_clip_h;
    lay.grid_content_h = grid_content_h;
    lay.grid_scroll_max = grid_scroll_max;
    lay.card_w = card_w;
    lay.card_h = card_h;
    return lay;
}

/// Catalogue ids the popup shows, in catalogue order: filter matches minus
/// everything already placed in the target column. Returns the count.
pub fn collect(
    st: *const State,
    s: *const app_mod.Settings,
    out: *[catalog.ids.len][]const u8,
) usize {
    const needle = st.filterSlice();
    var n: usize = 0;
    if (st.for_desktop) {
        for (desktop_ids) |id| {
            const meta = ui_widgets.widgetMeta(id);
            if (!matches(id, meta.title, ui_widgets.widgetDesc(id), needle)) continue;
            out[n] = id;
            n += 1;
        }
        return n;
    }
    for (catalog.ids) |id| {
        if (widget_lists.hasId(s, st.bar, id)) continue;
        const meta = ui_widgets.widgetMeta(id);
        if (!matches(id, meta.title, ui_widgets.widgetDesc(id), needle)) continue;
        out[n] = id;
        n += 1;
    }
    return n;
}

/// Matches on id, title *and* description (folds the whole "title + desc"
/// haystack), case-insensitively.
fn matches(id: []const u8, title: []const u8, desc: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return foldHas(id, needle) or foldHas(title, needle) or foldHas(desc, needle);
}

fn foldHas(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Grid index under (lx, ly), or null. Pixel scrolling is already applied to
/// `st.scroll_px`, so this works in the panel's own coordinate space.
pub fn hit(
    lay: Layout,
    st: *const State,
    s: *const app_mod.Settings,
    lx: f64,
    ly: f64,
) ?usize {
    if (!common.pointInRect(lx, ly, lay.gridRect())) return null;
    var out: [max_candidates][]const u8 = undefined;
    const n = collect(st, s, &out);
    var slot: usize = 0;
    while (slot < n) : (slot += 1) {
        const row: i32 = @intCast(slot / cols);
        const col: i32 = @intCast(slot % cols);
        const cx = lay.grid_x + col * (lay.card_w + lay.col_gap);
        const cy = lay.grid_y + row * (lay.card_h + lay.row_gap) - st.scroll_px;
        if (cy + lay.card_h < lay.grid_y or cy >= lay.grid_y + lay.grid_clip_h) continue;
        if (common.pointInRect(lx, ly, .{ .x = cx, .y = cy, .w = lay.card_w, .h = lay.card_h })) return slot;
    }
    return null;
}

/// Move the grid by `delta` pixels (a wheel notch), clamped to the content.
pub fn scrollByPx(st: *State, lay: Layout, delta: i32) void {
    var cur = st.scroll_px + delta;
    if (cur < 0) cur = 0;
    if (cur > lay.grid_scroll_max) cur = lay.grid_scroll_max;
    st.scroll_px = cur;
}

/// The grid's full result set (paint and hit need the same numbering).
pub fn collectInto(
    st: *const State,
    s: *const app_mod.Settings,
    out: *[max_candidates][]const u8,
) usize {
    return collect(st, s, out);
}

/// Accent-tinted rounded icon box with a centred Material ligature —
/// used for the header and every card.
fn iconBox(c: ?*cairo.cairo_t, x: i32, y: i32, sz: i32, ligature: []const u8) void {
    const t = common.Theme;
    const ir: f32 = @floatCast(@min(1.0, t.acc_r * 0.45 + 0.42));
    const ig: f32 = @floatCast(@min(1.0, t.acc_g * 0.45 + 0.42));
    const ib: f32 = @floatCast(@min(1.0, t.acc_b * 0.45 + 0.42));
    var b: m3_box.Box = .{};
    b.setColor(ir, ig, ib, 0.85);
    b.setRadius(@floatCast(icon_r));
    b.setGeometry(@floatFromInt(x), @floatFromInt(y), @floatFromInt(sz), @floatFromInt(sz));
    b.setGlassy(true);
    b.paint(c);
    ui_paint.glyph(
        c,
        @as(f64, @floatFromInt(x)) + @as(f64, @floatFromInt(sz)) * 0.5,
        @as(f64, @floatFromInt(y)) + @as(f64, @floatFromInt(sz)) * 0.5 + 0.5,
        @as(f64, @floatFromInt(sz)) * 0.6,
        ligature,
        t.text_r,
        t.text_g,
        t.text_b,
        0.95,
    );
}

pub fn paint(
    cr: ?*cairo.cairo_t,
    st: *State,
    s: *const app_mod.Settings,
    pointer_x: f64,
    pointer_y: f64,
    win_w: i32,
    win_h: i32,
) void {
    const c = cr orelse return;
    const t = common.Theme;
    const lay = layoutFor(st, s, win_w, win_h);

    // Colours.
    const a_r = t.acc_r;
    const a_g = t.acc_g;
    const a_b = t.acc_b;
    const tx_r = t.text_r;
    const tx_g = t.text_g;
    const tx_b = t.text_b;
    // Card surface: bg tinted like the picker card source (the
    // non-matugen branch — this modal always uses the static theme).
    const cf_r = t.bg_r * 0.88;
    const cf_g = t.bg_g * 0.90;
    const cf_b = t.bg_b * 0.95;

    // Scrim: dim the page behind the modal (flat 0.38 black).
    cairo.cairo_set_operator(c, cairo.CAIRO_OPERATOR_OVER);
    cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.38);
    cairo.cairo_rectangle(c, 0, 0, @floatFromInt(win_w), @floatFromInt(win_h));
    cairo.cairo_fill(c);

    // Panel.
    {
        var b: m3_box.Box = .{};
        b.setColor(@floatCast(t.bg_r), @floatCast(t.bg_g), @floatCast(t.bg_b), 0.96);
        b.setRadius(@floatCast(panel_r));
        b.setGeometry(@floatFromInt(lay.px), @floatFromInt(lay.py), @floatFromInt(lay.pw), @floatFromInt(lay.ph));
        b.setGlassy(true);
        b.paint(c);
    }

    // Header: icon box + "Add widget" + count.
    const hx = lay.px + pad;
    const hy = lay.py + pad;
    iconBox(c, hx, hy + 3, icon_box, "widgets");
    ui_paint.showText(
        c,
        @floatFromInt(hx + icon_box + 12),
        @floatFromInt(hy + 23),
        "Add widget",
        16,
        700,
        tx_r,
        tx_g,
        tx_b,
        0.95,
    );
    {
        var count_buf: [32]u8 = undefined;
        const sub = std.fmt.bufPrint(&count_buf, "{d} widgets available", .{catalog.ids.len}) catch "";
        ui_paint.showText(
            c,
            @floatFromInt(hx + icon_box + 12),
            @floatFromInt(hy + 40),
            sub,
            11,
            400,
            tx_r,
            tx_g,
            tx_b,
            0.55,
        );
    }

    // Close button (outlined XS).
    {
        const crct = lay.closeRect();
        const hov = common.pointInRect(pointer_x, pointer_y, crct);
        var btn: m3_button.Button = .{};
        btn.setMinSize(0, 0);
        btn.setGlyph("close");
        btn.setGeometry(@floatFromInt(crct.x), @floatFromInt(crct.y), @floatFromInt(crct.w), @floatFromInt(crct.h));
        btn.setStyle(.outlined);
        btn.setSize(.xs);
        btn.setAccentColor(@floatCast(a_r), @floatCast(a_g), @floatCast(a_b));
        btn.setOutlineColor(@floatCast(t.outline_r), @floatCast(t.outline_g), @floatCast(t.outline_b));
        btn.setTextColor(@floatCast(tx_r), @floatCast(tx_g), @floatCast(tx_b));
        btn.setHovered(hov);
        btn.paint(c, 0);
    }

    // Search field.
    const sr = lay.searchRect();
    {
        var b: m3_box.Box = .{};
        b.setColor(@floatCast(cf_r), @floatCast(cf_g), @floatCast(cf_b), 1.0);
        b.setRadius(12.0);
        b.setGeometry(@floatFromInt(sr.x), @floatFromInt(sr.y), @floatFromInt(sr.w), @floatFromInt(sr.h));
        b.setGlassy(true);
        b.paint(c);
    }
    ui_paint.glyph(
        c,
        @floatFromInt(sr.x + 18),
        @as(f64, @floatFromInt(sr.y)) + @as(f64, @floatFromInt(search_h)) * 0.5 + 0.5,
        18.0,
        "search",
        tx_r,
        tx_g,
        tx_b,
        0.5,
    );
    {
        const q = st.filterSlice();
        const text_x = sr.x + 46;
        const text_y = sr.y + @divTrunc(search_h + 15, 2);
        const clear_r = lay.clearRect();
        // Text + caret, clipped so long input never runs under the clear chip.
        cairo.cairo_save(c);
        cairo.cairo_rectangle(
            c,
            @floatFromInt(text_x),
            @floatFromInt(sr.y + 6),
            @floatFromInt(clear_r.x - 6 - text_x),
            @floatFromInt(search_h - 12),
        );
        cairo.cairo_clip(c);
        if (q.len == 0) {
            ui_paint.showText(
                c,
                @floatFromInt(text_x),
                @floatFromInt(text_y),
                "Search widgets by name or description...",
                13,
                400,
                tx_r,
                tx_g,
                tx_b,
                0.42,
            );
        } else {
            ui_paint.showText(
                c,
                @floatFromInt(text_x),
                @floatFromInt(text_y),
                q,
                13,
                400,
                tx_r,
                tx_g,
                tx_b,
                0.92,
            );
        }
        // Steady caret (the modal always has search focus).
        const caret_x = @as(f64, @floatFromInt(text_x)) +
            @as(f64, @floatFromInt(ui_paint.textWidthPx(c, q, 13, 400))) + 1.5;
        cairo.cairo_set_line_width(c, 1.6);
        cairo.cairo_set_source_rgba(c, tx_r, tx_g, tx_b, 0.85);
        cairo.cairo_move_to(c, caret_x, @floatFromInt(sr.y + 12));
        cairo.cairo_line_to(c, caret_x, @floatFromInt(sr.y + search_h - 12));
        cairo.cairo_stroke(c);
        cairo.cairo_restore(c);

        // Clear chip (only when there is something to clear).
        if (q.len > 0) {
            const clear_hov = common.pointInRect(pointer_x, pointer_y, clear_r);
            var cb: m3_box.Box = .{};
            if (clear_hov)
                cb.setColor(@floatCast(a_r), @floatCast(a_g), @floatCast(a_b), 0.92)
            else
                cb.setColor(@floatCast(tx_r), @floatCast(tx_g), @floatCast(tx_b), 0.08);
            cb.setRadius(13.0);
            cb.setGeometry(@floatFromInt(clear_r.x), @floatFromInt(clear_r.y), @floatFromInt(clear_r.w), @floatFromInt(clear_r.h));
            cb.setGlassy(true);
            cb.paint(c);
            const gcx = @as(f64, @floatFromInt(clear_r.x)) + @as(f64, @floatFromInt(clear_r.w)) * 0.5;
            const gcy = @as(f64, @floatFromInt(clear_r.y)) + @as(f64, @floatFromInt(clear_r.h)) * 0.5 + 0.5;
            if (clear_hov)
                ui_paint.glyph(c, gcx, gcy, 16.0, "close", 1, 1, 1, 0.95)
            else
                ui_paint.glyph(c, gcx, gcy, 16.0, "close", tx_r, tx_g, tx_b, 0.65);
        }
    }

    // Widget grid (clipped + scrollable).
    var out: [max_candidates][]const u8 = undefined;
    const n = collectInto(st, s, &out);
    if (st.scroll_px > lay.grid_scroll_max) st.scroll_px = lay.grid_scroll_max;
    st.hover = std.math.maxInt(usize);

    cairo.cairo_save(c);
    cairo.cairo_rectangle(
        c,
        @floatFromInt(lay.grid_x),
        @floatFromInt(lay.grid_y),
        @floatFromInt(lay.grid_w),
        @floatFromInt(lay.grid_clip_h),
    );
    cairo.cairo_clip(c);

    if (n == 0) {
        // Empty state.
        const ex = @as(f64, @floatFromInt(lay.grid_x)) + @as(f64, @floatFromInt(lay.grid_w)) * 0.5;
        ui_paint.glyph(c, ex, @floatFromInt(lay.grid_y + 30), 40.0, "search_off", tx_r, tx_g, tx_b, 0.22);
        const tw = ui_paint.textWidthPx(c, "No matching widgets", 14, 600);
        ui_paint.showText(
            c,
            ex - @as(f64, @floatFromInt(tw)) * 0.5,
            @floatFromInt(lay.grid_y + 64),
            "No matching widgets",
            14,
            600,
            tx_r,
            tx_g,
            tx_b,
            0.6,
        );
        const sw = ui_paint.textWidthPx(c, "Try a different search term", 11, 400);
        ui_paint.showText(
            c,
            ex - @as(f64, @floatFromInt(sw)) * 0.5,
            @floatFromInt(lay.grid_y + 86),
            "Try a different search term",
            11,
            400,
            tx_r,
            tx_g,
            tx_b,
            0.4,
        );
    }

    var slot: usize = 0;
    while (slot < n) : (slot += 1) {
        const row: i32 = @intCast(slot / cols);
        const col: i32 = @intCast(slot % cols);
        const cx = lay.grid_x + col * (lay.card_w + lay.col_gap);
        const cy_top = lay.grid_y + row * (lay.card_h + lay.row_gap) - st.scroll_px;
        if (cy_top + lay.card_h < lay.grid_y or cy_top >= lay.grid_y + lay.grid_clip_h) continue;
        const wid = out[slot];
        const meta = ui_widgets.widgetMeta(wid);
        const hover = common.pointInRect(pointer_x, pointer_y, .{
            .x = cx,
            .y = cy_top,
            .w = lay.card_w,
            .h = lay.card_h,
        });
        if (hover) st.hover = slot;

        // Card surface (hover tints toward the accent).
        var br = cf_r;
        var bg = cf_g;
        var bb = cf_b;
        if (hover) {
            br = @min(1.0, br + (a_r - br) * 0.16);
            bg = @min(1.0, bg + (a_g - bg) * 0.16);
            bb = @min(1.0, bb + (a_b - bb) * 0.16);
        }
        {
            var b: m3_box.Box = .{};
            b.setColor(@floatCast(br), @floatCast(bg), @floatCast(bb), 1.0);
            b.setRadius(@floatCast(card_r));
            b.setGeometry(@floatFromInt(cx), @floatFromInt(cy_top), @floatFromInt(lay.card_w), @floatFromInt(lay.card_h));
            b.setGlassy(true);
            b.paint(c);
        }
        if (hover) {
            ui_paint.roundRect(
                c,
                @as(f64, @floatFromInt(cx)) + 0.5,
                @as(f64, @floatFromInt(cy_top)) + 0.5,
                @floatFromInt(lay.card_w - 1),
                @floatFromInt(lay.card_h - 1),
                card_r,
            );
            cairo.cairo_set_source_rgba(c, a_r, a_g, a_b, 0.55);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_stroke(c);
        }

        // Icon box.
        iconBox(c, cx + card_pad, cy_top + @divTrunc(lay.card_h - icon_box, 2), icon_box, meta.glyph);

        // Title (wrapped, ellipsised) — clipped to its column.
        const tx = cx + card_pad + icon_box + 12;
        const title_wrap_w = lay.card_w - (card_pad + icon_box + 12) - card_pad;
        cairo.cairo_save(c);
        cairo.cairo_rectangle(
            c,
            @floatFromInt(tx),
            @floatFromInt(cy_top + 14),
            @floatFromInt(lay.card_w - card_pad - (tx - cx)),
            @floatFromInt(lay.card_h - 26),
        );
        cairo.cairo_clip(c);
        ui_paint.showWrapped(
            c,
            @floatFromInt(tx),
            @floatFromInt(cy_top + 15),
            meta.title,
            14,
            600,
            tx_r,
            tx_g,
            tx_b,
            if (hover) 1.0 else 0.92,
            title_wrap_w,
            true,
        );
        cairo.cairo_restore(c);

        // Description (wrapped, ellipsised, dim).
        const desc_wrap_w = lay.card_w - (card_pad + icon_box + 12) - (12 + add_chip + card_pad);
        cairo.cairo_save(c);
        cairo.cairo_rectangle(
            c,
            @floatFromInt(tx),
            @floatFromInt(cy_top + 34),
            @floatFromInt(lay.card_w - card_pad - (tx - cx)),
            @floatFromInt(lay.card_h - 46),
        );
        cairo.cairo_clip(c);
        ui_paint.showWrapped(
            c,
            @floatFromInt(tx),
            @floatFromInt(cy_top + 36),
            ui_widgets.widgetDesc(wid),
            11,
            400,
            tx_r,
            tx_g,
            tx_b,
            0.5,
            desc_wrap_w,
            true,
        );
        cairo.cairo_restore(c);

        // Add chip (right side).
        const abx = cx + lay.card_w - 16 - add_chip;
        const aby = cy_top + @divTrunc(lay.card_h - add_chip, 2);
        {
            var ab: m3_box.Box = .{};
            if (hover)
                ab.setColor(@floatCast(a_r), @floatCast(a_g), @floatCast(a_b), 0.92)
            else
                ab.setColor(@floatCast(tx_r), @floatCast(tx_g), @floatCast(tx_b), 0.07);
            ab.setRadius(12.0);
            ab.setGeometry(@floatFromInt(abx), @floatFromInt(aby), add_chip, add_chip);
            ab.setGlassy(true);
            ab.paint(c);
        }
        if (hover)
            ui_paint.glyph(c, @as(f64, @floatFromInt(abx + 12)), @as(f64, @floatFromInt(aby)) + 12.5, 18.0, "add", 1, 1, 1, 0.95)
        else
            ui_paint.glyph(c, @as(f64, @floatFromInt(abx + 12)), @as(f64, @floatFromInt(aby)) + 12.5, 18.0, "add", tx_r, tx_g, tx_b, 0.65);
    }

    // Scroll thumb.
    if (lay.grid_scroll_max > 0) {
        const thumb_h = @max(
            24.0,
            @as(f64, @floatFromInt(lay.grid_clip_h)) * @as(f64, @floatFromInt(lay.grid_clip_h)) /
                @as(f64, @floatFromInt(lay.grid_content_h)),
        );
        const norm = @as(f64, @floatFromInt(st.scroll_px)) / @as(f64, @floatFromInt(lay.grid_scroll_max));
        const thumb_y = @as(f64, @floatFromInt(lay.grid_y)) + (@as(f64, @floatFromInt(lay.grid_clip_h)) - thumb_h) * norm;
        const thumb_x = @as(f64, @floatFromInt(lay.grid_x + lay.grid_w - 7));
        cairo.cairo_set_source_rgba(c, tx_r, tx_g, tx_b, 0.30);
        ui_paint.roundRect(c, thumb_x, thumb_y, 4.0, thumb_h, 2.0);
        cairo.cairo_fill(c);
    }

    cairo.cairo_restore(c);

    // Footer.
    const foot_y = lay.py + lay.ph - footer_h + 2;
    const fw = ui_paint.textWidthPx(c, "Esc or click outside to close", 11, 400);
    ui_paint.showText(
        c,
        @as(f64, @floatFromInt(lay.px)) + (@as(f64, @floatFromInt(lay.pw)) - @as(f64, @floatFromInt(fw))) * 0.5,
        @floatFromInt(foot_y),
        "Esc or click outside to close",
        11,
        400,
        tx_r,
        tx_g,
        tx_b,
        0.45,
    );
}

test "widget-add: layout grows to fit content" {
    const t = std.testing;
    var st: State = .{ .bar = .dock, .col = 0 };
    const s: app_mod.Settings = .{};
    // A typical desktop window. The panel must sit inside the content area
    // (right of the 260px sidebar + spacing) and be capped at 82% height.
    const lay = layoutFor(&st, &s, 1600, 1000);
    const inset = app_mod.AppState.contentX();
    try t.expect(lay.px >= inset);
    try t.expect(lay.py >= 16);
    try t.expect(lay.ph <= 1000 - 48);
    // Chrome + clipped grid exactly fills the panel height.
    const chrome = pad + header_h + gap_search + search_h + gap_grid + footer_h + pad;
    try t.expectEqual(@as(i32, lay.ph), chrome + lay.grid_clip_h);
    // 24 ids / 2 cols = 12 rows; at ~76px each they overflow the viewport cap,
    // so the grid is clipped and scrollable.
    try t.expect(lay.grid_scroll_max > 0);
    try t.expect(lay.card_w >= 170);
    try t.expect(lay.card_h >= 72 and lay.card_h <= 96);
}

test "widget-add: filter narrows the grid and dedupes placed ids" {
    const t = std.testing;
    var st: State = .{ .bar = .dock, .col = 0 };
    var out: [catalog.ids.len][]const u8 = undefined;
    const empty: app_mod.Settings = .{};

    const all = collect(&st, &empty, &out);
    try t.expectEqual(@as(usize, catalog.ids.len), all);

    st.setFilter("MED");
    const med = collect(&st, &empty, &out);
    // "med" matches media (title/id) plus control_center and pear_center,
    // whose descriptions both mention "media" — the filter folds the
    // whole "title + desc" haystack, so those match too.
    try t.expectEqual(@as(usize, 3), med);
    var found_media = false;
    for (out[0..med]) |id| {
        if (std.mem.eql(u8, id, "media")) found_media = true;
    }
    try t.expect(found_media);

    st.setFilter("");
    var s2: app_mod.Settings = .{};
    const placed = [_][]const u8{"media"};
    s2.dock_left_widgets = @constCast(&placed);
    const left = collect(&st, &s2, &out);
    try t.expectEqual(@as(usize, catalog.ids.len - 1), left);
    for (out[0..left]) |id| try t.expect(!std.mem.eql(u8, id, "media"));
}

test "widget-add: pixel scroll clamps and grid hits track scroll" {
    const t = std.testing;
    var st: State = .{};
    const s: app_mod.Settings = .{};
    const lay = layoutFor(&st, &s, 1600, 1000);

    // First card at the grid origin is hit before any scrolling.
    const r0x = lay.grid_x;
    const r0y = lay.grid_y;
    try t.expectEqual(@as(?usize, 0), hit(lay, &st, &s, @floatFromInt(r0x + 4), @floatFromInt(r0y + 4)));
    // Outside the clipped grid -> no hit.
    try t.expect(hit(lay, &st, &s, 0, 0) == null);

    // Scroll down one notch: the origin pixels now carry a lower row's card.
    scrollByPx(&st, lay, lay.card_h + lay.row_gap);
    const moved = hit(lay, &st, &s, @floatFromInt(r0x + 4), @floatFromInt(r0y + 4));
    try t.expect(moved != null and moved.? > 0);

    // Overshoot clamps to the content extent; negative clamps to 0.
    scrollByPx(&st, lay, 100000);
    try t.expectEqual(lay.grid_scroll_max, st.scroll_px);
    scrollByPx(&st, lay, -100000);
    try t.expectEqual(@as(i32, 0), st.scroll_px);
}
