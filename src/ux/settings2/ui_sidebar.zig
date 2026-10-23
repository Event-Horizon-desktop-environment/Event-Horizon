const std = @import("std");
const app_mod = @import("app.zig");
const common = @import("common.zig");
const compositor = @import("compositor.zig");
const search = @import("search.zig");
const ui_paint = @import("ui_paint.zig");

// Design B — rail and list.
// Two nav columns instead of the old grouped sidebar: an 80px icon rail
// (category icon over an 11px label, one button per visible category) and a
// 224px page list (search bar, category h3, then one 36px row per page with
// the selected row marked by an accent pill and a 3px bar on the list's left
// edge). While a query is typed the page rows are replaced by global search
// results (title + category, same matching as the old sidebar).
//
// Geometry (HTML design B): flush full-height columns — rail (0,0,80,H),
// list (80,0,224,H) — search bar at list top, rows from
// common.list_row_base_y on a 38px pitch, search results on the 52px pitch.

const max_results: usize = 40;

pub const Action = union(enum) {
    none,
    select_tab: i32,
    focus_search,
    clear_search,
    pick_result: usize,
};

pub const Sidebar = struct {
    // Kept from the old model so window.zig's handlers compile unchanged;
    // the rail has no expander — category clicks jump to the page list.
    expanded: [app_mod.sidebar_categories.len]bool = @splat(true),
    scroll_px: i32 = 0,
    active_tab: i32 = 0,
    query: [128]u8 = undefined,
    query_len: usize = 0,
    search_focused: bool = false,
    search_sel: usize = 0,
    pointer_x: f64 = -1,
    pointer_y: f64 = -1,
    win_h: i32 = app_mod.window_height,
    /// Appearance → Opacity: `overlay_opacity_settings_sidebar` as a 0–1
    /// scale (raw knob, no master fallback — the C++ settings app's read).
    /// `window.zig` refreshes it every frame; 1.0 paints the default look.
    sidebar_ov: f64 = 1.0,
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

    /// Category index for a visible rail slot (invisible categories like
    /// MangoWM-on-Hyprland leave no gap — slots pack tightly).
    fn slotCategory(slot: usize) ?usize {
        var s: usize = 0;
        for (app_mod.sidebar_categories, 0..) |cat, i| {
            if (!compositor.visibleCategory(cat.id)) continue;
            if (s == slot) return i;
            s += 1;
        }
        return null;
    }

    fn slotCount() usize {
        var n: usize = 0;
        for (app_mod.sidebar_categories) |cat| {
            if (compositor.visibleCategory(cat.id)) n += 1;
        }
        return n;
    }

    /// Index into `app_mod.sidebar_categories` of the rail button lit for
    /// the active tab. Page owners win over category ids: a category id can
    /// numerically collide with another section's page (Sound's legacy id 18
    /// is the Network category's Wired page), and the page's own section is
    /// the one that must light up.
    pub fn activeCategory(self: *const Sidebar) usize {
        for (app_mod.sidebar_categories, 0..) |cat, i| {
            for (cat.subs) |s| {
                if (s.tab_id == self.active_tab) return i;
            }
        }
        for (app_mod.sidebar_categories, 0..) |cat, i| {
            if (cat.id == self.active_tab) return i;
        }
        return 0;
    }

    /// Pages shown in the list column for a category. Hyprland-style
    /// categories with no subs are one row: the category page itself.
    fn pageTab(cat: app_mod.SidebarCategory, i: usize) i32 {
        return if (cat.subs.len == 0) cat.id else cat.subs[i].tab_id;
    }

    fn pageCount(cat: app_mod.SidebarCategory) usize {
        return if (cat.subs.len == 0) 1 else cat.subs.len;
    }

    fn pageLabel(cat: app_mod.SidebarCategory, i: usize) []const u8 {
        return if (cat.subs.len == 0) cat.label else cat.subs[i].label;
    }

    fn pageGlyph(cat: app_mod.SidebarCategory, i: usize) []const u8 {
        return if (cat.subs.len == 0) cat.glyph else cat.subs[i].glyph;
    }

    /// List-column content height (rows below the search bar).
    pub fn totalHeight(self: *const Sidebar) i32 {
        if (self.searching()) {
            if (self.results_len == 0) return common.list_row_base_y + 60;
            return common.list_row_base_y + @as(i32, @intCast(self.results_len)) * search.search_result_pitch + 8;
        }
        const cat = app_mod.sidebar_categories[self.activeCategory()];
        return common.list_row_base_y + @as(i32, @intCast(pageCount(cat))) * common.list_row_pitch_y + 8;
    }

    pub fn clampScroll(self: *Sidebar) void {
        // Flush list column: rows may run to the window's bottom edge.
        const max: i32 = @max(0, self.totalHeight() - self.win_h);
        self.scroll_px = common.clampInt(self.scroll_px, 0, max);
    }

    fn searchingHit(self: *const Sidebar, px: f64, py: f64) ?Action {
        const bar = search.searchBarGeom();
        const bx: f64 = @floatFromInt(bar.x);
        const by: f64 = @floatFromInt(bar.y);
        const br = bx + @as(f64, @floatFromInt(bar.w));
        const bb = by + @as(f64, @floatFromInt(bar.h));
        if (px >= bx and px < br and py >= by and py < bb) {
            if (self.searching() and px >= @as(f64, @floatFromInt(bar.x + bar.w - 29)) and
                px < @as(f64, @floatFromInt(bar.x + bar.w - 7)) and
                py >= @as(f64, @floatFromInt(bar.y + 8)) and
                py < @as(f64, @floatFromInt(bar.y + 30)))
            {
                return .{ .clear_search = {} };
            }
            return .{ .focus_search = {} };
        }
        return null;
    }

    /// Window-space pointer -> action. `py` is corrected for list scroll.
    pub fn hitTest(self: *const Sidebar, px: f64, py: f64) Action {
        if (self.searchingHit(px, py)) |a| return a;

        // Rail: category buttons jump to that category's first page.
        // The rail is a flush full-height column (x 0..80).
        if (px >= common.rail_x and px < common.rail_x + common.rail_w and
            py >= 0 and py < @as(f64, @floatFromInt(self.win_h)))
        {
            if (py < @as(f64, @floatFromInt(common.rail_base_y))) return .none;
            const slot: usize = @intCast(@divTrunc(@as(i32, @intFromFloat(py)) - common.rail_base_y, common.rail_pitch_y));
            const ci = slotCategory(slot) orelse return .none;
            // Must land inside the button, not the gap under it.
            const btn_y = common.rail_base_y + @as(i32, @intCast(slot)) * common.rail_pitch_y;
            if (@as(i32, @intFromFloat(py)) >= btn_y + common.rail_btn_h) return .none;
            return .{ .select_tab = pageTab(app_mod.sidebar_categories[ci], 0) };
        }

        // List column: search results or page rows.
        if (px < common.list_x or px >= common.list_x + common.list_w) return .none;
        const layout_y: i32 = @as(i32, @intFromFloat(py)) + self.scroll_px;
        if (self.searching()) {
            const base = common.list_row_base_y;
            if (layout_y < base or self.results_len == 0) return .none;
            const idx: usize = @intCast(@divTrunc(layout_y - base, search.search_result_pitch));
            if (idx >= self.results_len) return .none;
            return .{ .pick_result = idx };
        }
        if (layout_y < common.list_row_base_y) return .none;
        const cat = app_mod.sidebar_categories[self.activeCategory()];
        const idx: usize = @intCast(@divTrunc(layout_y - common.list_row_base_y, common.list_row_pitch_y));
        if (idx >= pageCount(cat)) return .none;
        return .{ .select_tab = pageTab(cat, idx) };
    }

    pub fn paint(self: *Sidebar, cr: ?*@import("../../wl/buffer/shm.zig").cairo.cairo_t) void {
        const c = cr orelse return;
        const h: f64 = @floatFromInt(self.win_h);

        // Sidebar glass: the panel's own fill, mirroring the C++
        // (`Theme.Bg * 0.35` at `0.78 * settingsSidebarOv`). SOURCE so the
        // sidebar owns its alpha — the window body behind it follows the
        // `.Settings` knob. At 1.0 this is exactly the old window fill.
        cairo_save(c);
        cairo_rectangle(c, 0, 0, @floatFromInt(common.sidebar_w), h);
        cairo_set_operator(c, cairo.CAIRO_OPERATOR_SOURCE);
        cairo_set_source_rgba(c, common.Theme.bg_r * 0.35, common.Theme.bg_g * 0.35, common.Theme.bg_b * 0.35, 0.78 * self.sidebar_ov);
        cairo_fill(c);
        cairo_restore(c);

        // Rail column: darker overlay full height (HTML `.rail{background:#0003}`),
        // hairlines on the rail/list and list/content boundaries.
        cairo_rectangle(c, @floatFromInt(common.rail_x), 0, @floatFromInt(common.rail_w), h);
        cairo_set_source_rgba(c, 0, 0, 0, 0.18);
        cairo_fill(c);
        cairo_set_source_rgba(c, 1, 1, 1, 0.08);
        cairo_set_line_width(c, 1.0);
        cairo_move_to(c, @as(f64, @floatFromInt(common.rail_x + common.rail_w)) + 0.5, 0);
        cairo_line_to(c, @as(f64, @floatFromInt(common.rail_x + common.rail_w)) + 0.5, h);
        cairo_stroke(c);
        cairo_move_to(c, @as(f64, @floatFromInt(common.list_x + common.list_w)) + 0.5, 0);
        cairo_line_to(c, @as(f64, @floatFromInt(common.list_x + common.list_w)) + 0.5, h);
        cairo_stroke(c);

        self.paintRail(c);

        cairo_save(c);
        cairo_rectangle(
            c,
            @floatFromInt(common.list_x),
            0,
            @floatFromInt(common.list_w),
            h,
        );
        cairo_clip(c);
        cairo_translate(c, 0, -@as(f64, @floatFromInt(self.scroll_px)));
        if (self.searching()) {
            self.paintResults(c);
        } else {
            self.paintList(c);
        }
        cairo_restore(c);

        self.paintSearchBar(c);
    }

    fn paintRail(self: *Sidebar, c: anytype) void {
        const t = common.Theme;
        const sel = self.activeCategory();
        const cx = @as(f64, @floatFromInt(common.rail_x + @divTrunc(common.rail_w, 2)));
        // HTML rail padding: 14px 8px — buttons inset 8px.
        const bx = common.rail_x + 8;
        const bw = common.rail_w - 16;
        var slot: usize = 0;
        for (app_mod.sidebar_categories, 0..) |cat, i| {
            if (!compositor.visibleCategory(cat.id)) continue;
            const y = common.rail_base_y + @as(i32, @intCast(slot)) * common.rail_pitch_y;
            slot += 1;
            const yf: f64 = @floatFromInt(y);
            const is_sel = i == sel;
            const hov = rowHover(
                self.pointer_x,
                self.pointer_y,
                bx,
                y,
                bw,
                common.rail_btn_h,
            );
            if (is_sel) {
                ui_paint.glassBox(
                    c,
                    bx,
                    y,
                    bw,
                    common.rail_btn_h,
                    14,
                    t.acc_r,
                    t.acc_g,
                    t.acc_b,
                    0.20,
                );
            } else if (hov) {
                ui_paint.glassBox(c, bx, y, bw, common.rail_btn_h, 14, 1, 1, 1, 0.07);
            }
            drawRailGlyph(c, cx, yf + 22, 22, cat.glyph, is_sel);
            // showText left-aligns: center the 11px label under the icon,
            // clipped to the button so a wide fallback font can't bleed
            // past the rail's hairline (HTML `overflow:hidden`).
            const lbl = shortLabel(cat);
            const lbl_w: f64 = @floatFromInt(ui_paint.textWidthPx(c, lbl, 11, 400));
            cairo_save(c);
            cairo_rectangle(c, @floatFromInt(bx), yf, @floatFromInt(bw), @floatFromInt(common.rail_btn_h));
            cairo_clip(c);
            if (is_sel) {
                ui_paint.showText(c, cx - lbl_w / 2.0, yf + 48, lbl, 11, 400, t.acc_r, t.acc_g, t.acc_b, 1.0);
            } else {
                ui_paint.showText(
                    c,
                    cx - lbl_w / 2.0,
                    yf + 48,
                    lbl,
                    11,
                    400,
                    t.text_r,
                    t.text_g,
                    t.text_b,
                    0.55,
                );
            }
            cairo_restore(c);
        }
    }

    fn paintList(self: *Sidebar, c: anytype) void {
        const t = common.Theme;
        const cat = app_mod.sidebar_categories[self.activeCategory()];
        const px = self.pointer_x;
        // Rows are painted under a -scroll_px translate; hover must be
        // tested in layout coords like hitTest (add scroll back).
        const py = self.pointer_y + @as(f64, @floatFromInt(self.scroll_px));
        const lx = common.list_x + 8;
        const lw = common.list_w - 16;

        ui_paint.showText(
            c,
            @floatFromInt(lx + 4),
            @floatFromInt(common.list_title_y),
            cat.label,
            18,
            600,
            t.text_r,
            t.text_g,
            t.text_b,
            0.95,
        );

        for (0..pageCount(cat)) |i| {
            const y = common.list_row_base_y + @as(i32, @intCast(i)) * common.list_row_pitch_y;
            const tab_id = pageTab(cat, i);
            const sel = self.active_tab == tab_id;
            const hov = rowHover(px, py, lx, y, lw, common.list_row_h);
            pill(c, lx, y, lw, common.list_row_h, 10, sel, hov, false);
            if (sel) {
                // 3px accent marker on the list column's left edge
                // (HTML `.list .p.on::before{left:-12px}`).
                ui_paint.roundRect(
                    c,
                    @floatFromInt(common.list_x),
                    @floatFromInt(y + 9),
                    3.0,
                    @floatFromInt(common.list_row_h - 18),
                    2.0,
                );
                cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 1.0);
                cairo_fill(c);
            }
            // Page icon left of the label (old sidebar sub-row pattern):
            // 16px glyph, accent when selected.
            drawRowGlyph(c, @floatFromInt(lx + 22), @floatFromInt(y + 18), 16, pageGlyph(cat, i), sel);
            // Label clipped to the row so long names ("Keyboard &
            // Language") can't bleed into the content column — HTML
            // `overflow:hidden` on `.p`.
            cairo_save(c);
            cairo_rectangle(c, @floatFromInt(lx + 40), @floatFromInt(y), @floatFromInt(lw - 40 - 8), @floatFromInt(common.list_row_h));
            cairo_clip(c);
            ui_paint.showText(
                c,
                @floatFromInt(lx + 40),
                // Baseline measured against the rendered rows: 13px label
                // (1.5× scale) must put cap-center ≈ y+17 so it lines up
                // with the 16px lucide glyph centered at y+18. 23 was 6px
                // high and visibly floated the text in every row.
                @floatFromInt(y + 28),
                pageLabel(cat, i),
                13,
                if (sel) 700 else 400,
                t.text_r,
                t.text_g,
                t.text_b,
                if (sel) 0.95 else 0.62,
            );
            cairo_restore(c);
        }
    }

    fn paintResults(self: *Sidebar, c: anytype) void {
        const t = common.Theme;
        if (self.results_len == 0) {
            ui_paint.showText(
                c,
                @floatFromInt(common.list_x + 24),
                @floatFromInt(common.list_row_base_y + 30),
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
                @floatFromInt(common.list_x + 24),
                @floatFromInt(common.list_row_base_y + 50),
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
        const py = self.pointer_y + @as(f64, @floatFromInt(self.scroll_px));
        const lx = common.list_x + 8;
        const lw = common.list_w - 16;
        for (0..self.results_len) |ri| {
            const e = search.entries[@intCast(self.results[ri])];
            const y = common.list_row_base_y + @as(i32, @intCast(ri)) * search.search_result_pitch;
            const sel = ri == self.search_sel;
            const hov = rowHover(px, py, lx, y, lw, search.search_result_h) or sel;
            pill(c, lx, y, lw, search.search_result_h, 10, sel, hov, false);
            const yf: f64 = @floatFromInt(y);
            const lx12: f64 = @floatFromInt(lx);
            ui_paint.showText(c, lx12 + 12, yf + 21, e.title, 13, 700, t.text_r, t.text_g, t.text_b, 0.95);
            ui_paint.showText(c, lx12 + 12, yf + 39, e.section, 11, 400, t.text_r, t.text_g, t.text_b, 0.5);
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
            ui_paint.glassBox(c, bx, by, bw, bh, 12, t.acc_r, t.acc_g, t.acc_b, 0.22);
        } else if (hov) {
            ui_paint.glassBox(c, bx, by, bw, bh, 12, t.acc_r, t.acc_g, t.acc_b, 0.12);
        } else {
            ui_paint.glassBox(c, bx, by, bw, bh, 12, 1, 1, 1, 0.07);
        }
        const empty = self.query_len == 0;
        ui_paint.glyph(
            c,
            bx + 18,
            by + bh * 0.5 + 0.5,
            16,
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
                bar.y + 8,
                22,
                22,
            );
            ui_paint.glassBox(c, cx, cy, cs, cs, cs * 0.5, 1, 1, 1, if (chov) 0.16 else 0.08);
            ui_paint.glyph(c, cx + cs * 0.5, cy + cs * 0.5 + 0.5, 14, "close", t.text_r, t.text_g, t.text_b, 0.8);
        }
    }
};

/// Rail labels are short (the rail is 80px wide): reuse the old category
/// name minus its tail for the two wordy ones.
fn shortLabel(cat: app_mod.SidebarCategory) []const u8 {
    if (std.mem.eql(u8, cat.label, "Panels & UI")) return "Panels";
    if (std.mem.eql(u8, cat.label, "Wallpaper Settings")) return "Wallpaper";
    // The rail button clips at 80px; "Default Apps" measures 88px at the
    // rail's 11px label size. The full name stays on the list header and in
    // search results.
    if (std.mem.eql(u8, cat.label, "Default Apps")) return "Defaults";
    return cat.label;
}

/// List-row icon draw — muted text color normally, accent when the row is
/// selected. Same `dock_to_top` flip hack as the rail.
fn drawRowGlyph(c: anytype, cx: f64, cy: f64, px: f64, name: []const u8, accent: bool) void {
    const t = common.Theme;
    const r = if (accent) t.acc_r else t.text_r;
    const g = if (accent) t.acc_g else t.text_g;
    const b = if (accent) t.acc_b else t.text_b;
    const a: f64 = if (accent) 1.0 else 0.55;
    if (std.mem.eql(u8, name, "dock_to_top")) {
        ui_paint.glyphFlippedY(c, cx, cy, px, "dock_to_bottom", r, g, b, a);
    } else {
        ui_paint.glyph(c, cx, cy, px, name, r, g, b, a);
    }
}
/// Rail icon draw — muted text color normally, accent when selected
/// (HTML `.r` / `.r.on svg`), same `dock_to_top` flip hack as before.
fn drawRailGlyph(c: anytype, cx: f64, cy: f64, px: f64, name: []const u8, accent: bool) void {
    const t = common.Theme;
    const r = if (accent) t.acc_r else t.text_r;
    const g = if (accent) t.acc_g else t.text_g;
    const b = if (accent) t.acc_b else t.text_b;
    const a: f64 = if (accent) 1.0 else 0.55;
    if (std.mem.eql(u8, name, "dock_to_top")) {
        ui_paint.glyphFlippedY(c, cx, cy, px, "dock_to_bottom", r, g, b, a);
    } else {
        ui_paint.glyph(c, cx, cy, px, name, r, g, b, a);
    }
}

fn rowHover(px: f64, py: f64, x: i32, y: i32, w: i32, h: i32) bool {
    return common.pointInRect(px, py, .{ .x = x, .y = y, .w = w, .h = h });
}

/// Row pill: accent 0.20 when selected (HTML `.p.on`), a white 0.07 wash
/// on hover (HTML `.p:hover`), accent 0.07 for the active-tab tint.
fn pill(c: anytype, x: i32, y: i32, w: i32, h: i32, rad: f64, sel: bool, hov: bool, active: bool) void {
    const t = common.Theme;
    if (sel) {
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
            0.20,
        );
    } else if (hov) {
        ui_paint.glassBox(
            c,
            @floatFromInt(x),
            @floatFromInt(y),
            @floatFromInt(w),
            @floatFromInt(h),
            rad,
            1,
            1,
            1,
            0.07,
        );
    } else if (active) {
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
            0.07,
        );
    }
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
const cairo_set_operator = cairo.cairo_set_operator;
const cairo_move_to = cairo.cairo_move_to;
const cairo_line_to = cairo.cairo_line_to;
const cairo_stroke = cairo.cairo_stroke;
const cairo_fill = cairo.cairo_fill;

test "settings2-ui-sidebar: rail and list geometry" {
    const t = std.testing;
    var sb = Sidebar{};
    sb.clampScroll();
    try t.expectEqual(@as(i32, 0), sb.scroll_px);
    sb.scroll_px = 99999;
    sb.clampScroll();
    try t.expect(sb.scroll_px >= 0);
    sb.scroll_px = 0;

    // Rail button hit at base y -> first page of that category.
    const a = sb.hitTest(@floatFromInt(common.rail_x + 10), @floatFromInt(common.rail_base_y + 4));
    try t.expect(a == .select_tab);

    // List row hit -> page row of the active category (Dock).
    try t.expectEqual(@as(usize, 0), sb.activeCategory());
    const b = sb.hitTest(@floatFromInt(common.list_x + 20), @floatFromInt(common.list_row_base_y + 4));
    try t.expect(b == .select_tab);
    try t.expectEqual(@as(i32, 0), b.select_tab);

    // Search bar hit.
    const c = sb.hitTest(120, 30);
    try t.expect(c == .focus_search);

    // Searching: query filters results and rows become picks.
    sb.setQuery("wifi");
    try t.expect(sb.searching());
    try t.expect(sb.results_len >= 1);
    const d = sb.hitTest(@floatFromInt(common.list_x + 20), @floatFromInt(common.list_row_base_y + 4));
    try t.expect(d == .pick_result);
    sb.setQuery("zzz-no-match");
    try t.expectEqual(@as(usize, 0), sb.results_len);
}

test "settings2-ui-sidebar: a page wins over a colliding category id" {
    const t = std.testing;
    var sb = Sidebar{};
    // Sound's category id is 18, but the Network section owns the Wired page
    // 18; activating Wired must light (and list) Network, not Sound.
    sb.active_tab = 18;
    const ci = sb.activeCategory();
    try t.expectEqualStrings("Network", app_mod.sidebar_categories[ci].label);
    var owns = false;
    for (app_mod.sidebar_categories[ci].subs) |s| {
        if (s.tab_id == 18) owns = true;
    }
    try t.expect(owns);
    // The Sound category still resolves through one of its own pages.
    sb.active_tab = 8;
    try t.expectEqualStrings("Sound", app_mod.sidebar_categories[sb.activeCategory()].label);
}
