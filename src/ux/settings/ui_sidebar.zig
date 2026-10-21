const std = @import("std");
const app_mod = @import("app.zig");
const common = @import("common.zig");
const compositor = @import("compositor.zig");
const search = @import("search.zig");
const ui_paint = @import("ui_paint.zig");

// Sidebar paint + hit-test — Zig port of the sidebar block in
// settings_app.cpp (draw_sidebar_tab / draw_sidebar_subtab / search bar /
// search-results list, lines ~1793-2135). Same geometry: panel at
// (16,16,260,H-32) radius 18, rows from y=68 pitch 48 (sub 36, indent 28),
// fixed search bar (24,24,244,36), results on pitch 52.

const sidebar_x: i32 = 16;
const tab_x: i32 = sidebar_x + 8; // 24
const tab_w: i32 = common.sidebar_w - 16; // 244
const sub_indent: i32 = 28;
const sub_x: i32 = sidebar_x + sub_indent; // 44
const sub_w: i32 = common.sidebar_w - sub_indent - 16; // 216
const max_results: usize = 40;

pub const Action = union(enum) {
    none,
    select_tab: i32,
    toggle_category: usize,
    focus_search,
    clear_search,
    pick_result: usize,
};

pub const Sidebar = struct {
    expanded: [app_mod.sidebar_categories.len]bool = .{
        true, true, true, false, true, false, false,
    },
    scroll_px: i32 = 0,
    active_tab: i32 = 0,
    query: [128]u8 = undefined,
    query_len: usize = 0,
    search_focused: bool = false,
    search_sel: usize = 0,
    pointer_x: f64 = -1,
    pointer_y: f64 = -1,
    win_h: i32 = app_mod.window_height,
    /// Indices into `search.entries` matching the current query.
    results: [max_results]i32 = undefined,
    results_len: usize = 0,

    pub fn querySlice(self: *const Sidebar) []const u8 {
        return self.query[0..self.query_len];
    }

    pub fn setQuery(self: *Sidebar, q: []const u8) void {
        const n = @min(q.len, self.query.len);
        @memcpy(self.query[0..n], q[0..n]);
        self.query_len = n;
        self.recompute();
        self.search_sel = 0;
    }

    /// Rebuild `results` from the query (search.zig matching, fixed buffer —
    /// no allocation in the paint path).
    pub fn recompute(self: *Sidebar) void {
        const q = self.querySlice();
        var qbuf: [128]u8 = undefined;
        const qlen = @min(q.len, qbuf.len);
        const lower = std.ascii.lowerString(qbuf[0..qlen], q[0..qlen]);
        self.results_len = 0;
        if (lower.len == 0) return;
        for (search.entries, 0..) |e, i| {
            if (self.results_len >= max_results) break;
            // `settings_search_entry_visible`: mango pages 20..26, hyprland 33.
            if (!compositor.visibleTab(e.tab)) continue;
            if (entryMatches(e, lower)) {
                self.results[self.results_len] = @intCast(i);
                self.results_len += 1;
            }
        }
        if (self.search_sel >= self.results_len) self.search_sel = 0;
    }

    pub fn searching(self: *const Sidebar) bool {
        return self.query_len > 0;
    }

    /// `compute_sidebar_total_height()`.
    pub fn totalHeight(self: *const Sidebar) i32 {
        if (self.searching()) {
            if (self.results_len == 0) return common.sidebar_tab_base_y + 60;
            return common.sidebar_tab_base_y + @as(i32, @intCast(self.results_len)) * search.search_result_pitch + 8;
        }
        var h: i32 = common.sidebar_tab_base_y;
        for (app_mod.sidebar_categories, 0..) |cat, i| {
            // Compositor-gated categories (MangoWM / Hyprland) don't take
            // rows — same `continue` as settings_app.cpp height math.
            if (!compositor.visibleCategory(cat.id)) continue;
            h += common.sidebar_tab_pitch_y;
            if (cat.subs.len > 0 and self.expanded[i]) {
                h += @as(i32, @intCast(cat.subs.len)) * common.sidebar_sub_h;
            }
        }
        return h;
    }

    pub fn clampScroll(self: *Sidebar) void {
        const view_h: i32 = self.win_h - common.content_top - common.spacing_l;
        const max: i32 = @max(0, self.totalHeight() - view_h);
        self.scroll_px = common.clampInt(self.scroll_px, 0, max);
    }

    fn searchingHit(self: *const Sidebar, px: f64, py: f64) ?Action {
        const bar = search.searchBarGeom();
        const bx: f64 = @floatFromInt(bar.x);
        const by: f64 = @floatFromInt(bar.y);
        const br: f64 = bx + @as(f64, @floatFromInt(bar.w));
        const bb: f64 = by + @as(f64, @floatFromInt(bar.h));
        if (px >= bx and px < br and py >= by and py < bb) {
            if (self.searching() and px >= @as(f64, @floatFromInt(bar.x + bar.w - 29)) and
                px < @as(f64, @floatFromInt(bar.x + bar.w - 7)) and
                py >= @as(f64, @floatFromInt(bar.y + 7)) and
                py < @as(f64, @floatFromInt(bar.y + 29)))
            {
                return .{ .clear_search = {} };
            }
            return .{ .focus_search = {} };
        }
        return null;
    }

    /// Window-space pointer -> action. `py` is corrected for sidebar scroll.
    pub fn hitTest(self: *const Sidebar, px: f64, py: f64) Action {
        if (self.searchingHit(px, py)) |a| return a;
        if (px < sidebar_x or px >= sidebar_x + common.sidebar_w) return .none;
        const layout_y: i32 = @as(i32, @intFromFloat(py)) + self.scroll_px;
        if (self.searching()) {
            const base = common.sidebar_tab_base_y;
            if (layout_y < base or self.results_len == 0) return .none;
            const idx: usize = @intCast(@divTrunc(layout_y - base, search.search_result_pitch));
            if (idx >= self.results_len) return .none;
            return .{ .pick_result = idx };
        }
        if (layout_y < common.sidebar_tab_base_y) return .none;
        var y: i32 = common.sidebar_tab_base_y;
        for (app_mod.sidebar_categories, 0..) |cat, i| {
            if (!compositor.visibleCategory(cat.id)) continue;
            if (layout_y >= y and layout_y < y + common.sidebar_tab_h) {
                if (px < tab_x or px >= tab_x + tab_w) return .none;
                if (cat.subs.len == 0) return .{ .select_tab = cat.id };
                return .{ .toggle_category = i };
            }
            y += common.sidebar_tab_pitch_y;
            if (cat.subs.len > 0 and self.expanded[i]) {
                for (cat.subs) |s| {
                    if (layout_y >= y and layout_y < y + common.sidebar_sub_h) {
                        if (px < sub_x or px >= sub_x + sub_w) return .none;
                        return .{ .select_tab = s.tab_id };
                    }
                    y += common.sidebar_sub_h;
                }
            }
        }
        return .none;
    }

    pub fn paint(self: *Sidebar, cr: ?*@import("../../wl/buffer/shm.zig").cairo.cairo_t) void {
        const c = cr orelse return;
        const h: f64 = @floatFromInt(self.win_h);
        // Panel: Bg * 0.35, alpha 0.78 (settings_app.cpp sidebar bg box).
        ui_paint.glassBox(
            c,
            @floatFromInt(sidebar_x),
            @floatFromInt(common.content_top),
            @floatFromInt(common.sidebar_w),
            h - @as(f64, @floatFromInt(common.content_top)) - @as(f64, @floatFromInt(common.spacing_l)),
            18,
            common.Theme.bg_r * 0.35,
            common.Theme.bg_g * 0.35,
            common.Theme.bg_b * 0.35,
            0.78,
        );
        cairo_save(c);
        ui_paint.roundRect(
            c,
            @floatFromInt(sidebar_x),
            @floatFromInt(common.content_top),
            @floatFromInt(common.sidebar_w),
            h - @as(f64, @floatFromInt(common.content_top)) - @as(f64, @floatFromInt(common.spacing_l)),
            18,
        );
        cairo_clip(c);
        cairo_translate(c, 0, -@as(f64, @floatFromInt(self.scroll_px)));
        if (self.searching()) {
            self.paintResults(c);
        } else {
            self.paintCategories(c);
        }
        cairo_restore(c);

        self.paintSearchBar(c);
    }

    fn paintCategories(self: *Sidebar, c: anytype) void {
        const px = self.pointer_x;
        const py = self.pointer_y;
        var y: i32 = common.sidebar_tab_base_y;
        for (app_mod.sidebar_categories, 0..) |cat, i| {
            if (!compositor.visibleCategory(cat.id)) continue;
            const yf: f64 = @floatFromInt(y);
            const sel = tabSelected(self.active_tab, cat);
            const hov = rowHover(px, py, tab_x, y, tab_w, common.sidebar_tab_h);
            pill(c, tab_x, y, tab_w, common.sidebar_tab_h, 8, sel, hov, false);
            drawSidebarGlyph(c, @floatFromInt(tab_x + 18), yf + 20, 18, cat.glyph);
            ui_paint.showText(c, @floatFromInt(tab_x + 44), yf + 26, cat.label, 14, 700, 1, 1, 1, 1);
            y += common.sidebar_tab_pitch_y;
            if (cat.subs.len > 0 and self.expanded[i]) {
                for (cat.subs) |s| {
                    const syf: f64 = @floatFromInt(y);
                    const ssel = self.active_tab == s.tab_id;
                    const shov = rowHover(px, py, sub_x, y, sub_w, common.sidebar_sub_h);
                    pill(c, sub_x, y, sub_w, common.sidebar_sub_h, 6, ssel, shov, false);
                    drawSidebarGlyph(c, @floatFromInt(sub_x + 14), syf + 18, 16, s.glyph);
                    ui_paint.showText(c, @floatFromInt(sub_x + 32), syf + 23, s.label, 12, 700, 1, 1, 1, 1);
                    y += common.sidebar_sub_h;
                }
            }
        }
    }

    fn paintResults(self: *Sidebar, c: anytype) void {
        const t = common.Theme;
        if (self.results_len == 0) {
            ui_paint.showText(
                c,
                sidebar_x + 24,
                common.sidebar_tab_base_y + 30,
                "No matching settings",
                13,
                700,
                t.text_r,
                t.text_g,
                t.text_b,
                0.75,
            );
            ui_paint.showText(
                c,
                sidebar_x + 24,
                common.sidebar_tab_base_y + 50,
                "Try a different search term",
                11,
                400,
                t.text_r,
                t.text_g,
                t.text_b,
                0.45,
            );
            return;
        }
        const px = self.pointer_x;
        const py = self.pointer_y;
        for (0..self.results_len) |ri| {
            const e = search.entries[@intCast(self.results[ri])];
            const ry = common.sidebar_tab_base_y + @as(i32, @intCast(ri)) * search.search_result_pitch;
            const rx = tab_x;
            const sel = ri == self.search_sel;
            const hov = rowHover(px, py, rx, ry, tab_w, search.search_result_h) or sel;
            const active = e.tab == self.active_tab;
            pill(c, rx, ry, tab_w, search.search_result_h, 8, sel, hov, active);
            const ryf: f64 = @floatFromInt(ry);
            drawSidebarGlyph(c, @floatFromInt(rx + 18), ryf + 24, 18, e.glyph);
            ui_paint.showText(c, @floatFromInt(rx + 42), ryf + 21, e.title, 13, 700, 1, 1, 1, 0.95);
            ui_paint.showText(c, @floatFromInt(rx + 42), ryf + 39, e.section, 11, 400, 1, 1, 1, 0.5);
        }
    }

    fn paintSearchBar(self: *Sidebar, c: anytype) void {
        const bar = search.searchBarGeom();
        const t = common.Theme;
        const bx: f64 = @floatFromInt(bar.x);
        const by: f64 = @floatFromInt(bar.y);
        const bw: f64 = @floatFromInt(bar.w);
        const bh: f64 = @floatFromInt(bar.h);
        const hov = rowHover(self.pointer_x, self.pointer_y, bar.x, bar.y, bar.w, bar.h);
        if (self.search_focused) {
            ui_paint.glassBox(c, bx, by, bw, bh, 10, t.acc_r, t.acc_g, t.acc_b, 0.22);
        } else if (hov) {
            ui_paint.glassBox(c, bx, by, bw, bh, 10, t.acc_r, t.acc_g, t.acc_b, 0.12);
        } else {
            ui_paint.glassBox(c, bx, by, bw, bh, 10, 1, 1, 1, 0.07);
        }
        const empty = self.query_len == 0;
        ui_paint.glyph(
            c,
            bx + 18,
            by + bh * 0.5 + 0.5,
            18,
            "search",
            t.text_r,
            t.text_g,
            t.text_b,
            if (empty) 0.45 else 0.9,
        );
        const text_x = bx + 44;
        const baseline = by + @as(f64, @floatFromInt(@divTrunc(bar.h + 15, 2)));
        const clear_w: f64 = if (empty) 0 else 30;
        cairo_save(c);
        cairo_rectangle(c, text_x, by + 5, bw - (text_x - bx) - clear_w - 8, bh - 10);
        cairo_clip(c);
        if (empty) {
            ui_paint.showText(c, text_x, baseline, "Search settings", 13, 400, t.text_r, t.text_g, t.text_b, 0.42);
        } else {
            ui_paint.showText(c, text_x, baseline, self.querySlice(), 13, 400, t.text_r, t.text_g, t.text_b, 0.92);
        }
        if (self.search_focused) {
            const tw = ui_paint.textWidthPx(c, self.querySlice(), 13, 400);
            const caret = text_x + @as(f64, @floatFromInt(tw)) + 1.5;
            cairo_set_line_width(c, 1.6);
            cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, 0.85);
            cairo_move_to(c, caret, by + 9.0);
            cairo_line_to(c, caret, by + @as(f64, @floatFromInt(bar.h)) - 9.0);
            cairo_stroke(c);
        }
        cairo_restore(c);
        if (!empty) {
            const cs: f64 = 22;
            const cx = bx + bw - cs - 7;
            const cy = by + (@as(f64, @floatFromInt(bar.h)) - cs) * 0.5;
            const chov = rowHover(
                self.pointer_x,
                self.pointer_y,
                bar.x + bar.w - 29,
                bar.y + 7,
                22,
                22,
            );
            ui_paint.glassBox(c, cx, cy, cs, cs, cs * 0.5, 1, 1, 1, if (chov) 0.16 else 0.08);
            ui_paint.glyph(c, cx + cs * 0.5, cy + cs * 0.5 + 0.5, 14, "close", t.text_r, t.text_g, t.text_b, 0.8);
        }
    }
};

/// Sidebar icon draw. The C++ uses the ligature name `dock_to_top` for the
/// Panel row, but that name does not exist in Material Symbols Rounded (it
/// renders as literal text) — the intended icon is the taskbar's
/// `dock_to_bottom` mirrored upside down, so flip it here.
fn drawSidebarGlyph(c: anytype, cx: f64, cy: f64, px: f64, name: []const u8) void {
    if (std.mem.eql(u8, name, "dock_to_top")) {
        ui_paint.glyphFlippedY(c, cx, cy, px, "dock_to_bottom", 1, 1, 1, 1);
    } else {
        ui_paint.glyph(c, cx, cy, px, name, 1, 1, 1, 1);
    }
}

fn tabSelected(active: i32, cat: app_mod.SidebarCategory) bool {
    if (cat.subs.len == 0) return active == cat.id;
    if (active == cat.id) return true;
    for (cat.subs) |s| {
        if (s.tab_id == active) return true;
    }
    return false;
}

fn rowHover(px: f64, py: f64, x: i32, y: i32, w: i32, h: i32) bool {
    return common.pointInRect(px, py, .{ .x = x, .y = y, .w = w, .h = h });
}

/// Accent pill behind a row: 0.20 selected, 0.12 hover, 0.07 active-tab
/// tint (search results only) — settings_app.cpp draw_sidebar_tab.
fn pill(c: anytype, x: i32, y: i32, w: i32, h: i32, rad: f64, sel: bool, hov: bool, active: bool) void {
    const t = common.Theme;
    const a: f64 = if (sel) 0.20 else if (hov) 0.12 else if (active) 0.07 else 0;
    if (a <= 0) return;
    ui_paint.glassBox(
        c,
        @floatFromInt(x),
        @floatFromInt(y),
        @floatFromInt(w),
        @floatFromInt(h),
        rad,
        t.acc_r,
        t.acc_g,
        t.acc_b,
        a,
    );
}

fn entryMatches(e: search.SearchEntry, query_lower: []const u8) bool {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for ([_][]const u8{ e.title, e.section, e.keywords }) |part| {
        if (len + part.len + 1 >= buf.len) break;
        for (part) |ch| {
            if (len >= buf.len) break;
            buf[len] = std.ascii.toLower(ch);
            len += 1;
        }
        if (len < buf.len) {
            buf[len] = ' ';
            len += 1;
        }
    }
    return std.mem.indexOf(u8, buf[0..len], query_lower) != null;
}

const cairo = @import("../../wl/buffer/shm.zig").cairo;
const cairo_save = cairo.cairo_save;
const cairo_restore = cairo.cairo_restore;
const cairo_clip = cairo.cairo_clip;
const cairo_translate = cairo.cairo_translate;
const cairo_rectangle = cairo.cairo_rectangle;
const cairo_set_line_width = cairo.cairo_set_line_width;
const cairo_set_source_rgba = cairo.cairo_set_source_rgba;
const cairo_move_to = cairo.cairo_move_to;
const cairo_line_to = cairo.cairo_line_to;
const cairo_stroke = cairo.cairo_stroke;

test "settings-ui-sidebar: totals, clamps and hit rows" {
    const t = std.testing;
    var sb = Sidebar{};
    try t.expect(sb.totalHeight() > common.sidebar_tab_base_y);
    sb.clampScroll();
    try t.expectEqual(@as(i32, 0), sb.scroll_px);
    sb.scroll_px = 99999;
    sb.clampScroll();
    try t.expect(sb.scroll_px >= 0);
    sb.scroll_px = 0;
    // Category row hit at base y -> toggle (Panels & UI has subs).
    const a = sb.hitTest(tab_x + 4, common.sidebar_tab_base_y + 4);
    try t.expect(a == .toggle_category);
    try t.expectEqual(@as(usize, 0), a.toggle_category);
    // Search bar hit.
    const b = sb.hitTest(30, 30);
    try t.expect(b == .focus_search);
    // Searching: query filters results and rows become picks.
    sb.setQuery("wifi");
    try t.expect(sb.searching());
    try t.expect(sb.results_len >= 1);
    const c = sb.hitTest(tab_x + 4, common.sidebar_tab_base_y + 4);
    try t.expect(c == .pick_result);
    sb.setQuery("zzz-no-match");
    try t.expectEqual(@as(usize, 0), sb.results_len);
}
