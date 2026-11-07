const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const m3_button = @import("../../m3/controls/containers/button.zig");
const theming = @import("../../desktop_shell/common/system_theming.zig");

// The Themes page (tab 45).
//
// Port of `settings_tab_themes.cpp`: four sub-tabs (GTK, QT, Cursor, Plasma)
// over a grid of 480x230 theme cards, each painting a live application
// preview built from the theme's own colours and shapes. The page owns the
// pending/backup state and the preview caches; the window only forwards the
// press, the cursor-slider drag and the repaint.
//
// Everything is file-backed and best-effort: a missing toolkit leaves an
// empty sub-tab, an unreadable theme paints the neutral fallback preview, and
// Apply never fails the settings app.

pub const tab_id: i32 = 45;

pub const Sub = enum { gtk, qt, cursor, plasma };

const card_w: i32 = 480;
const card_h: i32 = 230;
const card_gap: i32 = 8;
const card_radius: f64 = 10;
const preview_w: i32 = 400;
const preview_h: i32 = 176;
const preview_title_h: i32 = 32;
const k_card_pad_x: i32 = 20;
const k_sub_label_y: i32 = 38;
const k_grid_inset: i32 = 32;
const grid_top: i32 = common.content_top + common.tab_bar_h + common.spacing_l + 60; // 160
const btn_w: i32 = 110;
const btn_h: i32 = 36;
const btn_gap_x: i32 = 12;
const combo_h: i32 = common.settings_combo_h; // 28
const slider_band_h: i32 = 28;
const k_dot_size: f64 = 10;
const k_dot_inset: f64 = 14;
const k_no_anim_ms: u64 = 0;
const k_empty_alpha: f64 = 0.7;

const k_cursor_shapes = [_][]const u8{ "left_ptr", "hand2", "xterm", "crosshair", "watch", "fleur" };
const k_cursor_source_px: i32 = 32;
const k_cursor_max_px: f64 = 56;
const k_cursor_label_h: f64 = 14;

const k_name_font_sp: f32 = 13;
const k_id_font_sp: f32 = 10;
const k_weight_regular: c_uint = 400;
const k_weight_bold: c_uint = 700;

/// Content-column geometry, passed in rather than read from `Content` so the
/// page does not import `ui_content` back.
pub const Geo = struct {
    content_x: i32,
    content_w: i32,
    win_h: i32,
};

/// One Themes-page press, translated into what the window must do.
pub const Action = union(enum) {
    /// Theme card by index in the active sub-tab's list.
    pick: usize,
    /// Sub-tab bar.
    subtab: usize,
    apply,
    cancel,
    /// Open/close the Qt colour-scheme dropdown.
    qt_scheme_toggle,
    /// Pick an entry from the Qt colour-scheme dropdown (0 = None).
    qt_scheme_pick: usize,
    /// A click outside the open dropdown: close it and swallow the press.
    dismiss,
    /// Cursor-size slider value (press starts a drag).
    cursor_size: i32,
};

pub const Layout = struct {
    cols: i32,
    grid_left: i32,
    grid_top: i32 = grid_top,
};

pub fn colsFor(content_w: i32) i32 {
    return @max(1, @divTrunc(content_w - k_grid_inset, card_w + card_gap));
}

pub fn layout(content_x: i32, content_w: i32, n: usize) Layout {
    const cols = colsFor(content_w);
    const total_w: i32 = if (n > 0) cols * card_w + (cols - 1) * card_gap else 0;
    return .{
        .cols = cols,
        .grid_left = content_x + @divTrunc(content_w - total_w, 2),
    };
}

fn rowCount(n: usize, cols: i32) i32 {
    if (n == 0) return 0;
    return @divTrunc(@as(i32, @intCast(n)) + cols - 1, cols);
}

fn cardRect(lay: Layout, i: usize) common.Rect {
    const cols_u: usize = @intCast(lay.cols);
    const col: i32 = @intCast(i % cols_u);
    const row: i32 = @intCast(i / cols_u);
    return .{
        .x = lay.grid_left + col * (card_w + card_gap),
        .y = lay.grid_top + row * (card_h + card_gap),
        .w = card_w,
        .h = card_h,
    };
}

/// Grid bottom for the active sub-tab's item count, in layout space. Mirrors
/// the C++ `gridTop + rows * (kThemeCardH + kThemeCardGap) - kThemeCardGap`.
fn gridBottom(lay: Layout, n: usize) i32 {
    const rows = rowCount(n, lay.cols);
    return lay.grid_top + rows * (card_h + card_gap) - card_gap;
}

const GtkLook = struct {
    colors: theming.Colors = .{},
    design: theming.Design = .{},
};

const PreviewItem = struct {
    name: [32]u8 = @splat(0),
    name_len: usize = 0,
    surface: *cairo.cairo_surface_t,
};

const PreviewList = std.ArrayListUnmanaged(PreviewItem);

fn stateOwned(self: *Page, slot: *[]u8, value: []const u8) void {
    if (slot.len > 0) self.alloc.free(slot.*);
    slot.* = self.alloc.dupe(u8, value) catch &.{};
}

const State = struct {
    pending: []u8 = &.{},
    backup: []u8 = &.{},
    inited: bool = false,
};

pub const Page = struct {
    alloc: std.mem.Allocator = undefined,
    io: std.Io = undefined,

    sub: Sub = .gtk,
    /// Installed lists, refreshed at every entry point so installs/removals
    /// show up while the page is open.
    gtk: []theming.ThemeInfo = &.{},
    qt_styles: [][]const u8 = &.{},
    cursor_themes: []theming.ThemeInfo = &.{},
    plasma_themes: []theming.ThemeInfo = &.{},

    gtk_state: State = .{},
    qt_style_state: State = .{},
    qt_scheme_state: State = .{},
    plasma_state: State = .{},
    cursor_state: State = .{},

    cursor_size: i32 = 24,
    backup_cursor_size: i32 = 24,
    cursor_by_size: bool = false,

    qt_schemes: [][]const u8 = &.{},
    schemes_open: bool = false,
    scheme_hover: i32 = -1,

    gtk_cache: std.StringHashMapUnmanaged(GtkLook) = .{},
    qt_cache: std.StringHashMapUnmanaged(theming.Colors) = .{},
    plasma_cache: std.StringHashMapUnmanaged(theming.Colors) = .{},
    cursor_cache: std.StringHashMapUnmanaged(PreviewList) = .{},

    subtab_rects: [4]common.Rect = @splat(.{ .x = 0, .y = 0, .w = 0, .h = 0 }),
    apply_btn: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    cancel_btn: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    combo_rect: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    slider_rect: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Slider track from the last paint (band geometry).
    slider_track_x: i32 = 0,
    slider_track_w: i32 = 0,

    pub fn init(self: *Page, alloc: std.mem.Allocator, io: std.Io) void {
        self.* = .{ .alloc = alloc, .io = io };
    }

    pub fn deinit(self: *Page) void {
        self.freeLists();
        self.backupResetAll();
        self.freeCaches();
    }

    /// Drop every preview cache and every pending/backup on leaving the tab.
    pub fn resetSession(self: *Page) void {
        self.freeCaches();
        self.backupResetAll();
        self.schemes_open = false;
        self.cursor_by_size = false;
    }

    fn freeLists(self: *Page) void {
        theming.freeThemes(self.alloc, self.gtk);
        theming.freeThemes(self.alloc, self.cursor_themes);
        theming.freeThemes(self.alloc, self.plasma_themes);
        theming.freeNames(self.alloc, self.qt_styles);
        theming.freeNames(self.alloc, self.qt_schemes);
        self.gtk = &.{};
        self.cursor_themes = &.{};
        self.plasma_themes = &.{};
        self.qt_styles = &.{};
        self.qt_schemes = &.{};
    }

    fn refreshLists(self: *Page) void {
        self.freeLists();
        self.gtk = theming.listGtkThemes(self.alloc, self.io) catch &.{};
        self.qt_styles = theming.knownQtStyles(self.alloc, self.io) catch &.{};
        self.cursor_themes = theming.listCursorThemes(self.alloc, self.io) catch &.{};
        self.plasma_themes = theming.listPlasmaThemes(self.alloc, self.io) catch &.{};
        self.qt_schemes = theming.listQtColorSchemes(self.alloc, self.io) catch &.{};
    }

    // ------------------------------------------------------ backup state --

    fn backupResetAll(self: *Page) void {
        inline for (.{ "gtk_state", "qt_style_state", "qt_scheme_state", "plasma_state", "cursor_state" }) |name| {
            const st = &@field(self, name);
            if (st.pending.len > 0) self.alloc.free(st.pending);
            if (st.backup.len > 0) self.alloc.free(st.backup);
            st.* = .{};
        }
        self.cursor_by_size = false;
    }

    fn ensureState(self: *Page, sub: Sub) void {
        switch (sub) {
            .gtk => {
                if (self.gtk_state.inited) return;
                const cur = theming.detectGtkTheme(self.alloc, self.io) orelse "";
                stateOwned(self, &self.gtk_state.pending, cur);
                stateOwned(self, &self.gtk_state.backup, cur);
                if (cur.len > 0) self.alloc.free(cur);
                self.gtk_state.inited = true;
            },
            .qt => {
                if (self.qt_style_state.inited) return;
                const style = theming.detectQtStyle(self.alloc, self.io) orelse "";
                stateOwned(self, &self.qt_style_state.pending, style);
                stateOwned(self, &self.qt_style_state.backup, style);
                if (style.len > 0) self.alloc.free(style);
                const scheme = theming.detectQtColorScheme(self.alloc, self.io) orelse "";
                stateOwned(self, &self.qt_scheme_state.pending, scheme);
                stateOwned(self, &self.qt_scheme_state.backup, scheme);
                if (scheme.len > 0) self.alloc.free(scheme);
                self.qt_style_state.inited = true;
                self.qt_scheme_state.inited = true;
            },
            .cursor => {
                if (self.cursor_state.inited) return;
                const cur = theming.detectCursorTheme(self.alloc, self.io) orelse "";
                stateOwned(self, &self.cursor_state.pending, cur);
                stateOwned(self, &self.cursor_state.backup, cur);
                if (cur.len > 0) self.alloc.free(cur);
                self.cursor_size = theming.detectCursorSize(self.alloc, self.io);
                self.backup_cursor_size = self.cursor_size;
                self.cursor_state.inited = true;
            },
            .plasma => {
                if (self.plasma_state.inited) return;
                const cur = theming.detectPlasmaTheme(self.alloc, self.io) orelse "";
                stateOwned(self, &self.plasma_state.pending, cur);
                stateOwned(self, &self.plasma_state.backup, cur);
                if (cur.len > 0) self.alloc.free(cur);
                self.plasma_state.inited = true;
            },
        }
    }

    fn hasChanges(self: *Page) bool {
        return switch (self.sub) {
            .gtk => !std.mem.eql(u8, self.gtk_state.pending, self.gtk_state.backup),
            .qt => !std.mem.eql(u8, self.qt_style_state.pending, self.qt_style_state.backup) or
                !std.mem.eql(u8, self.qt_scheme_state.pending, self.qt_scheme_state.backup),
            .cursor => !std.mem.eql(u8, self.cursor_state.pending, self.cursor_state.backup) or
                self.cursor_size != self.backup_cursor_size,
            .plasma => !std.mem.eql(u8, self.plasma_state.pending, self.plasma_state.backup),
        };
    }

    fn pendingId(self: *const Page) []const u8 {
        return switch (self.sub) {
            .gtk => self.gtk_state.pending,
            .qt => self.qt_style_state.pending,
            .cursor => self.cursor_state.pending,
            .plasma => self.plasma_state.pending,
        };
    }

    // ----------------------------------------------------------- actions --

    pub fn handle(self: *Page, act: Action) void {
        switch (act) {
            .subtab => |i| self.selectSubtab(i),
            .pick => |i| self.pick(i),
            .apply => self.apply(),
            .cancel => self.cancel(),
            .qt_scheme_toggle => self.schemes_open = !self.schemes_open,
            .qt_scheme_pick => |i| {
                const value = if (i == 0) "" else if (i - 1 < self.qt_schemes.len) self.qt_schemes[i - 1] else "";
                stateOwned(self, &self.qt_scheme_state.pending, value);
                self.schemes_open = false;
            },
            .dismiss => self.schemes_open = false,
            .cursor_size => |v| {
                self.cursor_size = common.clampInt(v, 16, 64);
                self.cursor_by_size = true;
            },
        }
    }

    fn selectSubtab(self: *Page, i: usize) void {
        if (i >= 4) return;
        const next: Sub = @enumFromInt(i);
        if (next == self.sub) return;
        // C++ resets the other family's backup on every cross-tab move, so
        // switching away and back re-reads the system value.
        if (self.sub == .cursor and next != .cursor) {
            self.cursor_state.inited = false;
        }
        if (self.sub != .cursor and next == .cursor) {
            self.gtk_state.inited = false;
            self.qt_style_state.inited = false;
            self.qt_scheme_state.inited = false;
            self.plasma_state.inited = false;
        }
        self.sub = next;
        self.schemes_open = false;
        self.cursor_by_size = false;
    }

    fn pick(self: *Page, i: usize) void {
        switch (self.sub) {
            .gtk => {
                if (i >= self.gtk.len) return;
                stateOwned(self, &self.gtk_state.pending, self.gtk[i].id);
            },
            .qt => {
                if (i >= self.qt_styles.len) return;
                stateOwned(self, &self.qt_style_state.pending, self.qt_styles[i]);
            },
            .cursor => {
                if (i >= self.cursor_themes.len) return;
                stateOwned(self, &self.cursor_state.pending, self.cursor_themes[i].id);
            },
            .plasma => {
                if (i >= self.plasma_themes.len) return;
                stateOwned(self, &self.plasma_state.pending, self.plasma_themes[i].id);
            },
        }
        self.schemes_open = false;
    }

    fn apply(self: *Page) void {
        self.ensureState(self.sub);
        if (!self.hasChanges()) return;
        switch (self.sub) {
            .gtk => {
                theming.applyGtkTheme(self.io, self.gtk_state.pending);
                stateOwned(self, &self.gtk_state.backup, self.gtk_state.pending);
            },
            .qt => {
                theming.applyQtStyle(self.io, self.qt_style_state.pending);
                theming.applyQtColorScheme(self.io, self.qt_scheme_state.pending);
                stateOwned(self, &self.qt_style_state.backup, self.qt_style_state.pending);
                stateOwned(self, &self.qt_scheme_state.backup, self.qt_scheme_state.pending);
            },
            .cursor => {
                theming.applyCursorConfig(self.alloc, self.io, self.cursor_state.pending, self.cursor_size);
                stateOwned(self, &self.cursor_state.backup, self.cursor_state.pending);
                self.backup_cursor_size = self.cursor_size;
            },
            .plasma => {
                theming.applyPlasmaTheme(self.alloc, self.io, self.plasma_state.pending);
                stateOwned(self, &self.plasma_state.backup, self.plasma_state.pending);
            },
        }
    }

    fn cancel(self: *Page) void {
        self.ensureState(self.sub);
        switch (self.sub) {
            .gtk => stateOwned(self, &self.gtk_state.pending, self.gtk_state.backup),
            .qt => {
                stateOwned(self, &self.qt_style_state.pending, self.qt_style_state.backup);
                stateOwned(self, &self.qt_scheme_state.pending, self.qt_scheme_state.backup);
            },
            .cursor => {
                stateOwned(self, &self.cursor_state.pending, self.cursor_state.backup);
                self.cursor_size = self.backup_cursor_size;
            },
            .plasma => stateOwned(self, &self.plasma_state.pending, self.plasma_state.backup),
        }
        self.schemes_open = false;
    }

    /// Cursor-size drag from `Win.onMotion`; true when the press was on the
    /// slider and the value moved.
    pub fn dragMotion(self: *Page, g: Geo, px: f64) bool {
        if (!self.cursor_by_size or self.sub != .cursor) return false;
        const v = common.sliderValueFromX(px, self.slider_track_x, self.slider_track_w, 16, 64);
        if (v == self.cursor_size) return false;
        self.cursor_size = v;
        _ = g;
        return true;
    }

    pub fn endDrag(self: *Page) bool {
        if (!self.cursor_by_size) return false;
        self.cursor_by_size = false;
        return true;
    }

    // ----------------------------------------------------------- caches --

    fn freeCaches(self: *Page) void {
        var it = self.gtk_cache.iterator();
        while (it.next()) |e| self.alloc.free(e.key_ptr.*);
        self.gtk_cache.deinit(self.alloc);
        self.gtk_cache = .{};

        var qit = self.qt_cache.iterator();
        while (qit.next()) |e| self.alloc.free(e.key_ptr.*);
        self.qt_cache.deinit(self.alloc);
        self.qt_cache = .{};

        var pit = self.plasma_cache.iterator();
        while (pit.next()) |e| self.alloc.free(e.key_ptr.*);
        self.plasma_cache.deinit(self.alloc);
        self.plasma_cache = .{};

        var cit = self.cursor_cache.iterator();
        while (cit.next()) |e| {
            for (e.value_ptr.items) |item| cairo.cairo_surface_destroy(item.surface);
            e.value_ptr.deinit(self.alloc);
            self.alloc.free(e.key_ptr.*);
        }
        self.cursor_cache.deinit(self.alloc);
        self.cursor_cache = .{};
    }

    fn gtkLook(self: *Page, path: []const u8) GtkLook {
        if (path.len == 0) return .{};
        const gop = self.gtk_cache.getOrPut(self.alloc, path) catch return .{};
        if (!gop.found_existing) {
            gop.key_ptr.* = self.alloc.dupe(u8, path) catch {
                _ = self.gtk_cache.remove(path);
                return .{};
            };
            gop.value_ptr.* = .{
                .colors = theming.extractGtkColors(self.alloc, self.io, path),
                .design = theming.extractGtkDesign(self.alloc, self.io, path),
            };
        }
        return gop.value_ptr.*;
    }

    fn plasmaColors(self: *Page, path: []const u8) theming.Colors {
        if (path.len == 0) return .{};
        const gop = self.plasma_cache.getOrPut(self.alloc, path) catch return .{};
        if (!gop.found_existing) {
            gop.key_ptr.* = self.alloc.dupe(u8, path) catch {
                _ = self.plasma_cache.remove(path);
                return .{};
            };
            gop.value_ptr.* = theming.extractPlasmaColors(self.alloc, self.io, path);
        }
        return gop.value_ptr.*;
    }

    fn qtColors(self: *Page, style: []const u8) theming.Colors {
        if (style.len == 0) return .{};
        const gop = self.qt_cache.getOrPut(self.alloc, style) catch return theming.qtStyleColors(style);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.alloc.dupe(u8, style) catch {
                _ = self.qt_cache.remove(style);
                return theming.qtStyleColors(style);
            };
            gop.value_ptr.* = theming.qtStyleColors(style);
        }
        return gop.value_ptr.*;
    }

    fn ensureCursorPreview(self: *Page, path: []const u8) ?*const PreviewList {
        if (path.len == 0) return null;
        const gop = self.cursor_cache.getOrPut(self.alloc, path) catch return null;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.alloc.dupe(u8, path) catch {
                _ = self.cursor_cache.remove(path);
                return null;
            };
            var list: PreviewList = .empty;
            for (k_cursor_shapes) |shape| {
                const surf = theming.loadCursorShape(self.alloc, self.io, path, shape, k_cursor_source_px) orelse continue;
                var item: PreviewItem = .{ .surface = surf };
                const n = @min(shape.len, item.name.len);
                @memcpy(item.name[0..n], shape[0..n]);
                item.name_len = n;
                list.append(self.alloc, item) catch {
                    cairo.cairo_surface_destroy(surf);
                    break;
                };
            }
            gop.value_ptr.* = list;
        }
        return gop.value_ptr;
    }

    // ------------------------------------------------------ scroll height --

    fn itemCount(self: *const Page) usize {
        return switch (self.sub) {
            .gtk => self.gtk.len,
            .qt => self.qt_styles.len,
            .cursor => self.cursor_themes.len,
            .plasma => self.plasma_themes.len,
        };
    }

    fn contentBottomFor(self: *const Page, g: Geo, n: usize) i32 {
        if (n == 0) return common.content_top + common.tab_bar_h + common.spacing_l + 60 + 60;
        const lay = layout(g.content_x, g.content_w, n);
        var bottom = gridBottom(lay, n);
        switch (self.sub) {
            .qt => bottom += 12 + combo_h + 8 + 40 + common.spacing_l,
            .cursor => bottom += 12 + common.slider_row_h + 8 + 40 + common.spacing_l,
            .gtk, .plasma => bottom += 12 + 8 + 40 + common.spacing_l,
        }
        return bottom + common.spacing_l;
    }

    pub fn totalHeight(self: *Page, g: Geo) i32 {
        self.refreshLists();
        self.ensureState(self.sub);
        return self.contentBottomFor(g, self.itemCount()) - common.content_top;
    }

    // ------------------------------------------------------------- paint --

    pub fn paint(
        self: *Page,
        cr: ?*cairo.cairo_t,
        g: Geo,
        px: f64,
        ly: f64,
        glass_ov: f64,
    ) void {
        const c = cr orelse return;
        self.refreshLists();
        self.ensureState(self.sub);
        const t = common.Theme;
        const n = self.itemCount();
        const lay = layout(g.content_x, g.content_w, n);
        const sub_i: usize = @intFromEnum(self.sub);

        const full_bottom = self.contentBottomFor(g, n);
        const card_top: f64 = @floatFromInt(common.content_top);
        const card_ht = @max(
            200.0,
            @max(
                @as(f64, @floatFromInt(full_bottom - common.content_top + common.spacing_l)),
                @as(f64, @floatFromInt(g.win_h)) - card_top - @as(f64, @floatFromInt(common.spacing_l)),
            ),
        );
        ui_paint.card(c, @floatFromInt(g.content_x), card_top, @floatFromInt(g.content_w), card_ht, glass_ov);
        ui_paint.catLabel(c, @floatFromInt(g.content_x + common.card_pad), card_top + 22.0, "Themes");

        // Sub-tab bar.
        const labels = [_][]const u8{ "GTK", "QT", "Cursor", "Plasma" };
        var tab_x = g.content_x + k_card_pad_x;
        const tab_y = common.content_top + k_sub_label_y;
        for (labels, 0..) |label, i| {
            const is_cur = i == sub_i;
            const weight: c_uint = if (is_cur) 700 else 400;
            const tw = ui_paint.textWidthPx(c, label, 13, weight) + 24;
            self.subtab_rects[i] = .{ .x = tab_x, .y = tab_y, .w = tw, .h = common.tab_bar_h };
            const fill_r = if (is_cur) t.acc_r else t.bg_r;
            const fill_g = if (is_cur) t.acc_g else t.bg_g;
            const fill_b = if (is_cur) t.acc_b else t.bg_b;
            ui_paint.glassBox(
                c,
                @floatFromInt(tab_x),
                @floatFromInt(tab_y),
                @floatFromInt(tw),
                @floatFromInt(common.tab_bar_h),
                6,
                fill_r,
                fill_g,
                fill_b,
                if (is_cur) 0.35 else 0.15,
            );
            const tx = @as(f64, @floatFromInt(tab_x)) + (@as(f64, @floatFromInt(tw)) - @as(f64, @floatFromInt(ui_paint.textWidthPx(c, label, 13, weight)))) * 0.5;
            ui_paint.showText(
                c,
                tx,
                @as(f64, @floatFromInt(tab_y + common.tab_bar_h / 2)) + 7.0,
                label,
                13,
                weight,
                t.text_r,
                t.text_g,
                t.text_b,
                if (is_cur) 1.0 else 0.7,
            );
            tab_x += tw + 4;
        }

        // Empty states.
        if (n == 0) {
            const msg: []const u8 = switch (self.sub) {
                .gtk => "No GTK themes found.",
                .qt => "No QT styles available.",
                .cursor => "No cursor themes found.",
                .plasma => "No Plasma themes found.",
            };
            ui_paint.showText(
                c,
                @floatFromInt(g.content_x + k_card_pad_x),
                @floatFromInt(common.content_top + common.tab_bar_h + 80),
                msg,
                13,
                k_weight_regular,
                t.text_r,
                t.text_g,
                t.text_b,
                k_empty_alpha,
            );
            if (self.sub == .qt) self.paintQtScheme(c, g, common.content_top + common.tab_bar_h + common.spacing_l + 120, px, ly);
            return;
        }

        for (0..n) |i| {
            const r = cardRect(lay, i);
            const id = switch (self.sub) {
                .gtk => self.gtk[i].id,
                .qt => self.qt_styles[i],
                .cursor => self.cursor_themes[i].id,
                .plasma => self.plasma_themes[i].id,
            };
            const name = switch (self.sub) {
                .gtk => self.gtk[i].name,
                .qt => self.qt_styles[i],
                .cursor => self.cursor_themes[i].name,
                .plasma => self.plasma_themes[i].name,
            };
            const path = switch (self.sub) {
                .gtk => self.gtk[i].path,
                .cursor => self.cursor_themes[i].path,
                .plasma => self.plasma_themes[i].path,
                .qt => "",
            };

            const cx: f64 = @floatFromInt(r.x);
            const cy: f64 = @floatFromInt(r.y);
            const is_cur = std.mem.eql(u8, id, self.pendingId());
            const hover = px >= cx and px < cx + @as(f64, @floatFromInt(card_w)) and
                ly >= cy and ly < cy + @as(f64, @floatFromInt(card_h));

            ui_paint.glassBox(
                c,
                cx,
                cy,
                @floatFromInt(card_w),
                @floatFromInt(card_h),
                card_radius,
                if (is_cur) t.acc_r else t.bg_r,
                if (is_cur) t.acc_g else t.bg_g,
                if (is_cur) t.acc_b else t.bg_b,
                if (is_cur) (if (hover) 0.30 else 0.22) else (if (hover) 0.92 else 0.85),
            );
            ui_paint.roundRect(c, cx, cy, @floatFromInt(card_w), @floatFromInt(card_h), card_radius);
            if (is_cur) {
                cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 0.60);
                cairo.cairo_set_line_width(c, 2.0);
            } else {
                cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.08);
                cairo.cairo_set_line_width(c, 1.0);
            }
            cairo.cairo_stroke(c);

            if (is_cur) {
                cairo.cairo_set_source_rgba(c, 0.35, 0.85, 0.45, 1.0);
                cairo.cairo_arc(
                    c,
                    cx + @as(f64, @floatFromInt(card_w)) - k_dot_inset,
                    cy + k_dot_inset,
                    k_dot_size * 0.5,
                    0,
                    2 * std.math.pi,
                );
                cairo.cairo_fill(c);
            }

            switch (self.sub) {
                .cursor => self.drawCursorPreview(c, cx, cy, path),
                .qt => {
                    var colors = self.qtColors(name);
                    if (is_cur and
                        !std.mem.eql(u8, self.qt_scheme_state.pending, self.qt_scheme_state.backup) and
                        self.qt_scheme_state.pending.len > 0)
                    {
                        const sc = theming.qtColorSchemeColors(self.alloc, self.io, self.qt_scheme_state.pending);
                        if (sc.valid) colors = sc;
                    }
                    self.drawQtPreview(c, cx, cy, name, colors);
                },
                .plasma => {
                    const colors = self.plasmaColors(path);
                    self.drawMiniPreview(c, cx, cy, colors, .{});
                },
                .gtk => {
                    const look = self.gtkLook(path);
                    self.drawMiniPreview(c, cx, cy, look.colors, look.design);
                },
            }

            const weight: c_uint = if (is_cur) k_weight_bold else k_weight_regular;
            const nw = ui_paint.textWidthPx(c, name, k_name_font_sp, weight);
            const text_x = cx + (@as(f64, @floatFromInt(card_w)) - @as(f64, @floatFromInt(nw))) * 0.5;
            ui_paint.showText(
                c,
                text_x,
                cy + @as(f64, @floatFromInt(preview_h + 8 + 20 + 5)),
                name,
                k_name_font_sp,
                weight,
                t.text_r,
                t.text_g,
                t.text_b,
                1.0,
            );
            if (self.sub != .cursor and name.len > 0 and !std.mem.eql(u8, name, id)) {
                const iw = ui_paint.textWidthPx(c, id, k_id_font_sp, k_weight_regular);
                const id_x = cx + (@as(f64, @floatFromInt(card_w)) - @as(f64, @floatFromInt(iw))) * 0.5;
                ui_paint.showText(
                    c,
                    id_x,
                    cy + @as(f64, @floatFromInt(preview_h + 8 + 20 + 22)),
                    id,
                    k_id_font_sp,
                    k_weight_regular,
                    t.text_r,
                    t.text_g,
                    t.text_b,
                    0.55,
                );
            }
        }

        const gb = gridBottom(lay, n);
        switch (self.sub) {
            .qt => self.paintQtScheme(c, g, gb, px, ly),
            .cursor => self.paintCursorControls(c, g, gb, px, ly),
            .gtk, .plasma => self.paintApplyCancel(c, g, gb + 12 + 8, px, ly),
        }
    }

    fn paintQtScheme(self: *Page, c: *cairo.cairo_t, g: Geo, gb: i32, px: f64, ly: f64) void {
        const t = common.Theme;
        const cbx = g.content_x + k_card_pad_x + 140;
        var cbw = g.content_w - k_card_pad_x - 140 - 28;
        if (cbw < 100) cbw = 100;
        const cby = gb + 12;
        self.combo_rect = .{ .x = cbx, .y = cby, .w = cbw, .h = combo_h };
        ui_paint.showText(
            c,
            @floatFromInt(g.content_x + k_card_pad_x),
            @floatFromInt(cby + 10),
            "Color scheme",
            15,
            k_weight_regular,
            t.text_r,
            t.text_g,
            t.text_b,
            0.93,
        );

        const value = if (self.qt_scheme_state.pending.len == 0) "None" else self.qt_scheme_state.pending;
        const hovered = px >= @as(f64, @floatFromInt(cbx)) and px < @as(f64, @floatFromInt(cbx + cbw)) and
            ly >= @as(f64, @floatFromInt(cby)) and ly < @as(f64, @floatFromInt(cby + combo_h));
        self.drawCombo(c, cbx, cby, cbw, combo_h, value, hovered or self.schemes_open);
        // Qt applies both the style card and the colour scheme, so it needs
        // the same Apply/Cancel row as GTK and Plasma. Paint it before the
        // popup so the open dropdown overlays the buttons.
        self.paintApplyCancel(c, g, cby + combo_h + 8, px, ly);
        if (self.schemes_open) self.paintSchemePopup(c, px, ly);
    }

    fn paintSchemePopup(self: *Page, c: *cairo.cairo_t, px: f64, ly: f64) void {
        const t = common.Theme;
        const total = self.qt_schemes.len + 1;
        const h: i32 = @intCast(@as(usize, @intCast(total)) * @as(usize, @intCast(common.settings_dd_row_h)));
        const x = self.combo_rect.x;
        const y = self.combo_rect.y + self.combo_rect.h;
        ui_paint.glassBox(
            c,
            @floatFromInt(x),
            @floatFromInt(y),
            @floatFromInt(self.combo_rect.w),
            @floatFromInt(h),
            8,
            t.bg_r,
            t.bg_g,
            t.bg_b,
            0.96,
        );
        for (0..total) |i| {
            const row_y = y + @as(i32, @intCast(i)) * common.settings_dd_row_h;
            const row_hover = px >= @as(f64, @floatFromInt(x)) and px < @as(f64, @floatFromInt(x + self.combo_rect.w)) and
                ly >= @as(f64, @floatFromInt(row_y)) and ly < @as(f64, @floatFromInt(row_y + common.settings_dd_row_h));
            if (row_hover) {
                ui_paint.glassBox(
                    c,
                    @floatFromInt(x + 2),
                    @floatFromInt(row_y + 1),
                    @floatFromInt(self.combo_rect.w - 4),
                    @floatFromInt(common.settings_dd_row_h - 2),
                    6,
                    t.acc_r,
                    t.acc_g,
                    t.acc_b,
                    0.18,
                );
                self.scheme_hover = @intCast(i);
            }
            const label = if (i == 0) "None" else self.qt_schemes[i - 1];
            ui_paint.showText(
                c,
                @floatFromInt(x + 12),
                @floatFromInt(row_y + common.settings_dd_row_h - 8),
                label,
                12,
                k_weight_regular,
                t.text_r,
                t.text_g,
                t.text_b,
                0.9,
            );
        }
        if (!(px >= @as(f64, @floatFromInt(x)) and px < @as(f64, @floatFromInt(x + self.combo_rect.w)) and
            ly >= @as(f64, @floatFromInt(y)) and ly < @as(f64, @floatFromInt(y + h))))
        {
            self.scheme_hover = -1;
        }
    }

    fn paintCursorControls(self: *Page, c: *cairo.cairo_t, g: Geo, gb: i32, px: f64, ly: f64) void {
        const t = common.Theme;
        const sl_y = gb + 12;
        ui_paint.showText(
            c,
            @floatFromInt(g.content_x + k_card_pad_x),
            @floatFromInt(sl_y + 10),
            "Cursor size",
            15,
            k_weight_regular,
            t.text_r,
            t.text_g,
            t.text_b,
            0.93,
        );
        const tr_x = g.content_x + k_card_pad_x;
        var tr_w = g.content_w - k_card_pad_x - k_card_pad_x - 52;
        if (tr_w < 40) tr_w = 40;
        self.slider_track_x = tr_x;
        self.slider_track_w = tr_w;
        self.slider_rect = .{ .x = tr_x - 6, .y = sl_y + 20, .w = tr_w + 12, .h = slider_band_h };
        self.drawSlider(c, tr_x, sl_y + 20, tr_w, self.cursor_size, self.cursor_by_size, px, ly);
        // Value readout at the right end of the slider row.
        var buf: [8]u8 = undefined;
        const val = std.fmt.bufPrint(&buf, "{d}", .{self.cursor_size}) catch "24";
        ui_paint.showText(
            c,
            @floatFromInt(g.content_x + g.content_w - k_card_pad_x - 30),
            @floatFromInt(sl_y + 30),
            val,
            12,
            k_weight_regular,
            t.text_r,
            t.text_g,
            t.text_b,
            0.7,
        );

        self.paintApplyCancel(c, g, sl_y + 20 + slider_band_h + 8, px, ly);
    }

    fn paintApplyCancel(self: *Page, c: *cairo.cairo_t, g: Geo, btn_y: i32, px: f64, ly: f64) void {
        const t = common.Theme;
        self.cancel_btn = .{
            .x = g.content_x + g.content_w - k_card_pad_x - btn_w,
            .y = btn_y,
            .w = btn_w,
            .h = btn_h,
        };
        self.apply_btn = .{
            .x = self.cancel_btn.x - btn_w - btn_gap_x,
            .y = btn_y,
            .w = btn_w,
            .h = btn_h,
        };
        const has_changes = self.hasChanges();

        var apply_ctl: m3_button.Button = .{};
        apply_ctl.setMinSize(0, 0);
        apply_ctl.setLabel("Apply");
        apply_ctl.setGeometry(
            @floatFromInt(self.apply_btn.x),
            @floatFromInt(self.apply_btn.y),
            @floatFromInt(btn_w),
            @floatFromInt(btn_h),
        );
        apply_ctl.setStyle(.filled);
        apply_ctl.setSize(.s);
        apply_ctl.setEnabled(has_changes);
        apply_ctl.setAccentColor(@floatCast(t.acc_r), @floatCast(t.acc_g), @floatCast(t.acc_b));
        apply_ctl.setHovered(common.pointInRect(px, ly, self.apply_btn));
        apply_ctl.paint(c, k_no_anim_ms);

        var cancel_ctl: m3_button.Button = .{};
        cancel_ctl.setMinSize(0, 0);
        cancel_ctl.setLabel("Cancel");
        cancel_ctl.setGeometry(
            @floatFromInt(self.cancel_btn.x),
            @floatFromInt(self.cancel_btn.y),
            @floatFromInt(btn_w),
            @floatFromInt(btn_h),
        );
        cancel_ctl.setStyle(.outlined);
        cancel_ctl.setSize(.s);
        cancel_ctl.setEnabled(has_changes);
        cancel_ctl.setAccentColor(@floatCast(t.text_r), @floatCast(t.text_g), @floatCast(t.text_b));
        cancel_ctl.setOutlineColor(@floatCast(t.outline_r), @floatCast(t.outline_g), @floatCast(t.outline_b));
        cancel_ctl.setHovered(common.pointInRect(px, ly, self.cancel_btn));
        cancel_ctl.paint(c, k_no_anim_ms);
    }

    fn drawCombo(self: *Page, c: *cairo.cairo_t, x: i32, y: i32, w: i32, h: i32, text: []const u8, hovered: bool) void {
        _ = self;
        const t = common.Theme;
        const xf: f64 = @floatFromInt(x);
        const yf: f64 = @floatFromInt(y);
        ui_paint.glassBox(c, xf, yf, @floatFromInt(w), @floatFromInt(h), 8, 1, 1, 1, if (hovered) 0.12 else 0.05);
        ui_paint.roundRect(c, xf + 0.5, yf + 0.5, @as(f64, @floatFromInt(w)) - 1.0, @as(f64, @floatFromInt(h)) - 1.0, 7.5);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, if (hovered) 0.9 else 0.55);
        cairo.cairo_stroke(c);
        cairo.cairo_save(c);
        cairo.cairo_rectangle(c, xf + 8, yf + 2, @as(f64, @floatFromInt(w)) - 34, @as(f64, @floatFromInt(h)) - 4);
        cairo.cairo_clip(c);
        ui_paint.showText(c, xf + 12, yf + @as(f64, @floatFromInt(h)) - 7.0, text, 12, k_weight_regular, t.text_r, t.text_g, t.text_b, 0.9);
        cairo.cairo_restore(c);
        ui_paint.glyph(c, xf + @as(f64, @floatFromInt(w)) - 14.0, yf + @as(f64, @floatFromInt(h)) * 0.5, 16, "expand_more", t.text_r, t.text_g, t.text_b, 0.7);
    }

    fn drawSlider(self: *Page, c: *cairo.cairo_t, tr_x: i32, tr_y: i32, tr_w: i32, value: i32, active: bool, px: f64, ly: f64) void {
        const t = common.Theme;
        const rail_inset: i32 = 10;
        const tl: f64 = @floatFromInt(tr_x + rail_inset);
        const tw: f64 = @floatFromInt(@max(0, tr_w - 2 * rail_inset));
        const ty: f64 = @as(f64, @floatFromInt(tr_y)) + @as(f64, @floatFromInt(slider_band_h)) * 0.5;
        const span: f64 = @max(1.0, @as(f64, @floatFromInt(64 - 16)));
        const norm = @max(0.0, @min(1.0, @as(f64, @floatFromInt(value - 16)) / span));
        const tc = tl + norm * tw;
        cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);
        cairo.cairo_set_source_rgba(c, t.bg_r, t.bg_g, t.bg_b, 0.35);
        cairo.cairo_set_line_width(c, 4.0);
        cairo.cairo_move_to(c, tl, ty);
        cairo.cairo_line_to(c, tl + tw, ty);
        cairo.cairo_stroke(c);
        if (tc > tl + 0.5) {
            cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 1.0);
            cairo.cairo_set_line_width(c, 4.0);
            cairo.cairo_move_to(c, tl, ty);
            cairo.cairo_line_to(c, tc, ty);
            cairo.cairo_stroke(c);
        }
        const hovered = common.pointInRect(px, ly, self.slider_rect);
        const r: f64 = if (active) 10.0 else if (hovered) 9.0 else 8.0;
        cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 1.0);
        cairo.cairo_arc(c, tc, ty, r, 0, 2 * std.math.pi);
        cairo.cairo_fill(c);
        cairo.cairo_set_source_rgba(c, t.bg_r, t.bg_g, t.bg_b, 0.45);
        cairo.cairo_arc(c, tl + tw, ty, 2.5, 0, 2 * std.math.pi);
        cairo.cairo_fill(c);
    }

    // ---------------------------------------------------------- previews --

    fn drawMiniPreview(self: *Page, c: *cairo.cairo_t, card_x: f64, card_y: f64, colors: theming.Colors, design: theming.Design) void {
        _ = self;
        const p_x = card_x + @as(f64, @floatFromInt((card_w - preview_w) / 2));
        const p_y = card_y + 8.0;
        const p_w: f64 = @floatFromInt(preview_w);
        const p_h: f64 = @floatFromInt(preview_h);

        ui_paint.glassBox(c, p_x, p_y, p_w, p_h, 4, 0, 0, 0, 0.08);

        const h_bg = if (colors.valid) colors.header_bg else .{ 0.85, 0.85, 0.85 };
        const h_fg = if (colors.valid) colors.header_fg else .{ 0.20, 0.20, 0.20 };
        const bg = if (colors.valid) colors.bg else .{ 0.96, 0.96, 0.96 };
        const accent = if (colors.valid) colors.accent else .{ 0.30, 0.50, 0.85 };
        const fg = if (colors.valid) colors.fg else .{ 0.15, 0.15, 0.15 };
        const text = if (colors.valid) colors.text else .{ 0.40, 0.40, 0.40 };
        const base = if (colors.valid) colors.base else .{ 1.0, 1.0, 1.0 };
        const entry_rad = if (design.valid) design.entry_rad else 2.0;
        const border_w: f64 = @floatFromInt(if (design.valid) design.border_w else 1);
        const title_h: f64 = 32.0;

        cairo.cairo_save(c);
        ui_paint.roundRect(c, p_x, p_y, p_w, p_h, 4.0);
        cairo.cairo_clip(c);
        cairo.cairo_set_source_rgba(c, h_bg[0], h_bg[1], h_bg[2], 1.0);
        cairo.cairo_rectangle(c, p_x, p_y, p_w, title_h);
        cairo.cairo_fill(c);
        cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.08);
        cairo.cairo_rectangle(c, p_x, p_y + title_h - 1, p_w, 1);
        cairo.cairo_fill(c);
        cairo.cairo_set_source_rgba(c, bg[0], bg[1], bg[2], 1.0);
        cairo.cairo_rectangle(c, p_x, p_y + title_h, p_w, p_h - title_h);
        cairo.cairo_fill(c);
        cairo.cairo_restore(c);

        drawDot(c, p_x + p_w - 26, p_y + title_h * 0.5, 0.9, 0.3, 0.3);
        drawDot(c, p_x + p_w - 44, p_y + title_h * 0.5, 0.85, 0.75, 0.2);
        drawDot(c, p_x + p_w - 62, p_y + title_h * 0.5, 0.35, 0.8, 0.35);
        ui_paint.showText(c, p_x + 12, p_y + title_h * 0.5 + 6, "Application", 12, 600, h_fg[0], h_fg[1], h_fg[2], 0.85);

        const pad_x = 18.0;
        const col_w = p_w - pad_x * 2;
        var y_pos = p_y + title_h + 12;

        ui_paint.roundRect(c, p_x + pad_x, y_pos, col_w, 26, entry_rad);
        cairo.cairo_set_source_rgba(c, base[0], base[1], base[2], 1.0);
        cairo.cairo_fill(c);
        ui_paint.roundRect(c, p_x + pad_x, y_pos, col_w, 26, entry_rad);
        cairo.cairo_set_source_rgba(c, 0.5, 0.5, 0.5, 0.3);
        cairo.cairo_set_line_width(c, @max(0.5, border_w * 0.5));
        cairo.cairo_stroke(c);
        ui_paint.showText(c, p_x + pad_x + 8, y_pos + 18, "Search or type...", 11, 400, text[0], text[1], text[2], 0.5);
        y_pos += 26 + 12;

        const ch_h = 22.0;
        const ch_size = 16.0;
        ui_paint.roundRect(c, p_x + pad_x, y_pos + (ch_h - ch_size) * 0.5, ch_size, ch_size, 3);
        cairo.cairo_set_source_rgba(c, accent[0], accent[1], accent[2], 0.7);
        cairo.cairo_fill(c);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 1);
        cairo.cairo_set_line_width(c, 2.0);
        cairo.cairo_move_to(c, p_x + pad_x + 4, y_pos + ch_h * 0.5);
        cairo.cairo_line_to(c, p_x + pad_x + 7, y_pos + ch_h * 0.5 + 4);
        cairo.cairo_line_to(c, p_x + pad_x + 12, y_pos + ch_h * 0.5 - 3);
        cairo.cairo_stroke(c);
        ui_paint.showText(c, p_x + pad_x + ch_size + 12, y_pos + 16, "Remember me", 11, 400, fg[0], fg[1], fg[2], 0.65);
        y_pos += ch_h + 12;

        ui_paint.roundRect(c, p_x + pad_x, y_pos, col_w, 28, 4);
        cairo.cairo_set_source_rgba(c, accent[0], accent[1], accent[2], 0.9);
        cairo.cairo_fill(c);
        ui_paint.showText(c, p_x + pad_x + col_w * 0.5 - 24, y_pos + 19, "Continue", 12, 600, 1, 1, 1, 0.95);
        y_pos += 28 + 12;

        cairo.cairo_set_source_rgba(c, 0.5, 0.5, 0.5, 0.12);
        cairo.cairo_set_line_width(c, 1);
        cairo.cairo_move_to(c, p_x + pad_x, y_pos + 2);
        cairo.cairo_line_to(c, p_x + pad_x + col_w, y_pos + 2);
        cairo.cairo_stroke(c);
        y_pos += 10;
        ui_paint.showText(c, p_x + pad_x, y_pos, "Ready", 9, 400, text[0], text[1], text[2], 0.35);
    }

    fn drawQtPreview(self: *Page, c: *cairo.cairo_t, card_x: f64, card_y: f64, style_name: []const u8, colors: theming.Colors) void {
        _ = self;
        const p_x = card_x + @as(f64, @floatFromInt((card_w - preview_w) / 2));
        const p_y = card_y + 8.0;
        const p_w: f64 = @floatFromInt(preview_w);
        const p_h: f64 = @floatFromInt(preview_h);
        const style = qtStyleKind(style_name);
        var entry_rad: f64 = 2;
        var border_w: f64 = 1;
        switch (style) {
            .breeze => {
                entry_rad = 3;
                border_w = 1.5;
            },
            .kvantum => {
                entry_rad = 4;
                border_w = 2.0;
            },
            .windows => {
                entry_rad = 0;
                border_w = 2.0;
            },
            .material => {
                entry_rad = 0;
                border_w = 0;
            },
            .rounded => {
                entry_rad = 4;
                border_w = 1.0;
            },
            .flat => {
                entry_rad = 2;
                border_w = 1.0;
            },
        }

        ui_paint.glassBox(c, p_x, p_y, p_w, p_h, 4, 0, 0, 0, 0.08);

        const h_bg = if (colors.valid) colors.header_bg else .{ 0.85, 0.85, 0.85 };
        const h_fg = if (colors.valid) colors.header_fg else .{ 0.20, 0.20, 0.20 };
        const bg = if (colors.valid) colors.bg else .{ 0.96, 0.96, 0.96 };
        const accent = if (colors.valid) colors.accent else .{ 0.30, 0.50, 0.85 };
        const fg = if (colors.valid) colors.fg else .{ 0.15, 0.15, 0.15 };
        const text = if (colors.valid) colors.text else .{ 0.40, 0.40, 0.40 };
        const base = if (colors.valid) colors.base else .{ 1.0, 1.0, 1.0 };
        const title_h: f64 = 32.0;

        cairo.cairo_save(c);
        ui_paint.roundRect(c, p_x, p_y, p_w, p_h, 4.0);
        cairo.cairo_clip(c);
        cairo.cairo_set_source_rgba(c, h_bg[0], h_bg[1], h_bg[2], 1.0);
        cairo.cairo_rectangle(c, p_x, p_y, p_w, title_h);
        cairo.cairo_fill(c);
        cairo.cairo_set_source_rgba(c, 0, 0, 0, 0.08);
        cairo.cairo_rectangle(c, p_x, p_y + title_h - 1, p_w, 1);
        cairo.cairo_fill(c);
        cairo.cairo_set_source_rgba(c, bg[0], bg[1], bg[2], 1.0);
        cairo.cairo_rectangle(c, p_x, p_y + title_h, p_w, p_h - title_h);
        cairo.cairo_fill(c);
        cairo.cairo_restore(c);

        drawDot(c, p_x + p_w - 26, p_y + title_h * 0.5, 0.9, 0.3, 0.3);
        drawDot(c, p_x + p_w - 44, p_y + title_h * 0.5, 0.85, 0.75, 0.2);
        drawDot(c, p_x + p_w - 62, p_y + title_h * 0.5, 0.35, 0.8, 0.35);
        ui_paint.showText(c, p_x + 12, p_y + title_h * 0.5 + 6, "Application", 12, 600, h_fg[0], h_fg[1], h_fg[2], 0.85);

        const pad_x = 18.0;
        const col_w = p_w - pad_x * 2;
        var y_pos = p_y + title_h + 12;

        ui_paint.roundRect(c, p_x + pad_x, y_pos, col_w, 26, entry_rad);
        cairo.cairo_set_source_rgba(c, base[0], base[1], base[2], 1.0);
        cairo.cairo_fill(c);
        ui_paint.roundRect(c, p_x + pad_x, y_pos, col_w, 26, entry_rad);
        cairo.cairo_set_source_rgba(c, 0.5, 0.5, 0.5, 0.3);
        cairo.cairo_set_line_width(c, @max(0.5, border_w * 0.5));
        cairo.cairo_stroke(c);
        ui_paint.showText(c, p_x + pad_x + 8, y_pos + 18, "Search or type...", 11, 400, text[0], text[1], text[2], 0.5);
        y_pos += 26 + 12;

        const ch_h = 22.0;
        const ch_size = 16.0;
        ui_paint.roundRect(c, p_x + pad_x, y_pos + (ch_h - ch_size) * 0.5, ch_size, ch_size, 3);
        cairo.cairo_set_source_rgba(c, accent[0], accent[1], accent[2], 0.7);
        cairo.cairo_fill(c);
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 1);
        cairo.cairo_set_line_width(c, 2.0);
        cairo.cairo_move_to(c, p_x + pad_x + 4, y_pos + ch_h * 0.5);
        cairo.cairo_line_to(c, p_x + pad_x + 7, y_pos + ch_h * 0.5 + 4);
        cairo.cairo_line_to(c, p_x + pad_x + 12, y_pos + ch_h * 0.5 - 3);
        cairo.cairo_stroke(c);
        ui_paint.showText(c, p_x + pad_x + ch_size + 12, y_pos + 16, "Remember me", 11, 400, fg[0], fg[1], fg[2], 0.65);
        y_pos += ch_h + 12;

        ui_paint.roundRect(c, p_x + pad_x, y_pos, col_w, 28, 4);
        cairo.cairo_set_source_rgba(c, accent[0], accent[1], accent[2], 0.9);
        cairo.cairo_fill(c);
        ui_paint.showText(c, p_x + pad_x + col_w * 0.5 - 24, y_pos + 19, "Continue", 12, 600, 1, 1, 1, 0.95);
        y_pos += 28 + 12;

        cairo.cairo_set_source_rgba(c, 0.5, 0.5, 0.5, 0.12);
        cairo.cairo_set_line_width(c, 1);
        cairo.cairo_move_to(c, p_x + pad_x, y_pos + 2);
        cairo.cairo_line_to(c, p_x + pad_x + col_w, y_pos + 2);
        cairo.cairo_stroke(c);
        y_pos += 10;
        ui_paint.showText(c, p_x + pad_x, y_pos, "Ready", 9, 400, text[0], text[1], text[2], 0.35);
    }

    fn drawCursorPreview(self: *Page, c: *cairo.cairo_t, card_x: f64, card_y: f64, path: []const u8) void {
        const p_x = card_x + @as(f64, @floatFromInt((card_w - preview_w) / 2));
        const p_y = card_y + 8.0;
        const p_w: f64 = @floatFromInt(preview_w);
        const p_h: f64 = @floatFromInt(preview_h);
        ui_paint.glassBox(c, p_x, p_y, p_w, p_h, 4, 0, 0, 0, 0.08);
        ui_paint.glassBox(c, p_x, p_y, p_w, p_h, 4, 0.96, 0.96, 0.96, 1.0);

        const list = self.ensureCursorPreview(path);
        const has = list != null and list.?.items.len > 0;
        if (!has) {
            ui_paint.showText(c, p_x + 10, p_y + p_h * 0.5 + 3, "No preview", 9, 400, 0.6, 0.6, 0.6, 0.5);
            return;
        }
        const items = list.?.items;
        const n_cols: usize = 3;
        const n_rows: usize = 2;
        const cell_w = p_w / @as(f64, @floatFromInt(n_cols));
        const cell_h = p_h / @as(f64, @floatFromInt(n_rows));
        for (items, 0..) |item, i| {
            if (i >= n_cols * n_rows) break;
            const col: usize = i % n_cols;
            const row: usize = i / n_cols;
            const cell_x = p_x + @as(f64, @floatFromInt(col)) * cell_w;
            const cell_y = p_y + @as(f64, @floatFromInt(row)) * cell_h;
            const iw = cairo.cairo_image_surface_get_width(item.surface);
            const ih = cairo.cairo_image_surface_get_height(item.surface);
            if (iw <= 0 or ih <= 0) continue;
            var scale = @min(k_cursor_max_px / @as(f64, @floatFromInt(iw)), (cell_h - k_cursor_label_h - 4.0) / @as(f64, @floatFromInt(ih)));
            scale = @min(scale, 3.0);
            scale = @max(scale, 0.3);
            const dw = @as(f64, @floatFromInt(iw)) * scale;
            const dh = @as(f64, @floatFromInt(ih)) * scale;
            const dx = cell_x + (cell_w - dw) * 0.5;
            const dy = cell_y + (cell_h - k_cursor_label_h - dh) * 0.5;
            cairo.cairo_save(c);
            cairo.cairo_translate(c, dx, dy);
            cairo.cairo_scale(c, scale, scale);
            cairo.cairo_set_source_surface(c, item.surface, 0, 0);
            cairo.cairo_paint(c);
            cairo.cairo_restore(c);
            const label = item.name[0..item.name_len];
            const lw = ui_paint.textWidthPx(c, label, 7, 400);
            ui_paint.showText(
                c,
                cell_x + (cell_w - @as(f64, @floatFromInt(lw))) * 0.5,
                cell_y + cell_h - 3,
                label,
                7,
                400,
                0.5,
                0.5,
                0.5,
                0.6,
            );
        }
    }

    // --------------------------------------------------------------- hit --

    pub fn hit(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        self.refreshLists();
        self.ensureState(self.sub);
        const n = self.itemCount();
        const lay = layout(g.content_x, g.content_w, n);

        // The open Qt dropdown sits above everything else in the page.
        if (self.schemes_open) {
            const total = self.qt_schemes.len + 1;
            const x = self.combo_rect.x;
            const y = self.combo_rect.y + self.combo_rect.h;
            const h: i32 = @intCast(@as(usize, @intCast(total)) * @as(usize, @intCast(common.settings_dd_row_h)));
            if (px >= @as(f64, @floatFromInt(x)) and px < @as(f64, @floatFromInt(x + self.combo_rect.w)) and
                ly >= @as(f64, @floatFromInt(y)) and ly < @as(f64, @floatFromInt(y + h)))
            {
                const idx: i32 = @divTrunc(@as(i32, @intFromFloat(ly)) - y, common.settings_dd_row_h);
                if (idx >= 0 and idx < total) return .{ .qt_scheme_pick = @intCast(idx) };
            }
            return .dismiss;
        }

        for (self.subtab_rects, 0..) |r, i| {
            if (r.w > 0 and common.pointInRect(px, ly, r)) return .{ .subtab = i };
        }

        if (n > 0) {
            for (0..n) |i| {
                if (common.pointInRect(px, ly, cardRect(lay, i))) return .{ .pick = i };
            }
        }

        if (self.sub == .qt and common.pointInRect(px, ly, self.combo_rect)) return .qt_scheme_toggle;

        if (self.sub == .cursor and common.pointInRect(px, ly, self.slider_rect)) {
            const v = common.sliderValueFromX(px, self.slider_track_x, self.slider_track_w, 16, 64);
            return .{ .cursor_size = v };
        }

        if (common.pointInRect(px, ly, self.apply_btn)) return .apply;
        if (common.pointInRect(px, ly, self.cancel_btn)) return .cancel;
        return null;
    }
};

fn drawDot(c: *cairo.cairo_t, x: f64, y: f64, r: f64, g: f64, b: f64) void {
    cairo.cairo_set_source_rgba(c, r, g, b, 0.8);
    cairo.cairo_arc(c, x, y, 4.0, 0, 2 * std.math.pi);
    cairo.cairo_fill(c);
}

const QtStyleKind = enum { flat, rounded, windows, breeze, kvantum, material };

fn qtStyleKind(name: []const u8) QtStyleKind {
    var buf: [128]u8 = undefined;
    const n = @min(name.len, buf.len);
    for (name[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const s = buf[0..n];
    if (std.mem.indexOf(u8, s, "breeze") != null) return .breeze;
    if (std.mem.indexOf(u8, s, "kvantum") != null or std.mem.indexOf(u8, s, "kvantom") != null) return .kvantum;
    if (std.mem.indexOf(u8, s, "windows") != null) return .windows;
    if (std.mem.indexOf(u8, s, "material") != null) return .material;
    if (std.mem.indexOf(u8, s, "fusion") != null) return .flat;
    if (std.mem.indexOf(u8, s, "oxygen") != null) return .rounded;
    if (std.mem.indexOf(u8, s, "fluent") != null) return .material;
    if (std.mem.indexOf(u8, s, "gtk") != null) return .rounded;
    return .flat;
}

test "settings-themes-tab: one 480px card column is centred" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 1), colsFor(592));
    var lay = layout(292, 592, 3);
    try t.expectEqual(@as(i32, 292 + (592 - 480) / 2), lay.grid_left);
    try t.expectEqual(@as(i32, grid_top), cardRect(lay, 0).y);
    try t.expectEqual(@as(i32, grid_top + card_h + card_gap), cardRect(lay, 1).y);
    try t.expectEqual(@as(i32, 1), colsFor(1000));
    lay = layout(292, 1000, 3);
    try t.expectEqual(@as(i32, 292 + (1000 - 480) / 2), lay.grid_left);
}

test "settings-themes-tab: content bottom follows the sub-tab controls" {
    const t = std.testing;
    var p: Page = .{};
    p.init(t.allocator, std.testing.io);
    defer p.deinit();
    const g = Geo{ .content_x = 292, .content_w = 592, .win_h = 980 };

    p.sub = .gtk;
    try t.expectEqual(
        @as(i32, common.content_top + common.tab_bar_h + common.spacing_l + 120),
        p.contentBottomFor(g, 0),
    );

    // 3 items in one column: gridBottom (3 rows minus the trailing gap) plus
    // the control block and the page's bottom spacing.
    const bottom_gtk = p.contentBottomFor(g, 3);
    try t.expectEqual(@as(i32, grid_top + 3 * (card_h + card_gap) - card_gap + 12 + 8 + 40 + common.spacing_l + common.spacing_l), bottom_gtk);
    p.sub = .cursor;
    const bottom_cursor = p.contentBottomFor(g, 3);
    try t.expectEqual(@as(i32, grid_top + 3 * (card_h + card_gap) - card_gap + 12 + common.slider_row_h + 8 + 40 + common.spacing_l + common.spacing_l), bottom_cursor);

    // Qt reserves the scheme combo plus the same Apply/Cancel row.
    p.sub = .qt;
    const bottom_qt = p.contentBottomFor(g, 3);
    try t.expectEqual(@as(i32, grid_top + 3 * (card_h + card_gap) - card_gap + 12 + combo_h + 8 + 40 + common.spacing_l + common.spacing_l), bottom_qt);
}

test "settings-themes-tab: pending/backup rules" {
    const t = std.testing;
    var p: Page = .{};
    p.init(t.allocator, std.testing.io);
    defer p.deinit();
    p.sub = .gtk;
    stateOwned(&p, &p.gtk_state.pending, "Adwaita");
    stateOwned(&p, &p.gtk_state.backup, "Adwaita");
    p.gtk_state.inited = true;
    try t.expect(!p.hasChanges());
    stateOwned(&p, &p.gtk_state.pending, "Papirus");
    try t.expect(p.hasChanges());
    p.cancel();
    try t.expectEqualStrings("Adwaita", p.gtk_state.pending);
    stateOwned(&p, &p.gtk_state.pending, "Papirus");
    stateOwned(&p, &p.gtk_state.backup, "Papirus");
    try t.expect(!p.hasChanges());
}
