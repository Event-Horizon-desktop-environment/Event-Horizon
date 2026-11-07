//! The Color Themes page (tab 50).
//!
//! Port of `settings_tab_color_themes.cpp`: one COLOR SOURCE card with three
//! pills (Matugen / Color Engine / Custom Theme), then — only while Custom
//! Theme is active — the built-in presets grouped by source with their
//! dark/light sub-sections, the scanned user-theme list, and an ACTIVE THEME
//! summary card. The page owns the user-theme scan and the pill hover state;
//! the window owns `Settings` and the `[appearance]` write.
//!
//! The built-in roster is the full 268-palette set from `theme_data.zig`, so a
//! preset picked here paints exactly like the C++ reference.

const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const theme_data = @import("theme_data.zig");
const theme_manager = @import("theme_manager.zig");

pub const tab_id: i32 = 50;

const card_inset: i32 = 8;
const mode_card_h: i32 = 52 + 56 + common.spacing_xl; // 132
const mode_toggle_y: i32 = common.content_top + 52 + 8;
const pill_h: i32 = 38;
const pill_gap: i32 = 12;
const preset_card_w: i32 = 220;
const preset_card_h: i32 = 140;
const preset_swatch_h: i32 = 50;
const preset_gap: i32 = 10;
const sub_header_h: i32 = 30;

/// Content-column geometry, passed in rather than read from `Content` so the
/// page does not import `ui_content` back.
pub const Geo = struct {
    content_x: i32,
    content_w: i32,
    win_h: i32,
};

/// Current source selection, mirrored from `Settings` by `ui_content`.
pub const View = struct {
    matugen: bool = false,
    color_engine: bool = true,
    custom: bool = false,
    active_name: []const u8 = "",
    active_source: []const u8 = "",
};

pub const Mode = enum { matugen, color_engine, custom };

/// One Color Themes press. The window applies it to `Settings` and persists
/// the `[appearance]` section; the page only translates geometry.
pub const Action = union(enum) {
    mode: Mode,
    /// Index into `theme_data.presets`.
    pick_preset: usize,
    /// Index into the page's scanned user-theme list.
    pick_user: usize,
};

const Group = struct {
    source: []const u8,
    dark: []usize,
    light: []usize,
};

const PillGeom = struct {
    rects: [3]common.Rect,
    w: [3]i32,
};

fn isLightVariant(variant: []const u8) bool {
    return std.mem.eql(u8, variant, "light") or
        std.mem.eql(u8, variant, "latte") or
        std.mem.eql(u8, variant, "dawn") or
        std.mem.eql(u8, variant, "brand-light");
}

fn gridCols(card_w: i32) i32 {
    return @max(1, @divTrunc(card_w - common.card_pad * 2, preset_card_w + preset_gap));
}

fn gridRows(count: usize, cols: i32) i32 {
    if (count == 0) return 0;
    const c: usize = @intCast(cols);
    return @intCast(@divTrunc(count + c - 1, c));
}

fn gridHeight(count: usize, cols: i32) i32 {
    const rows = gridRows(count, cols);
    return rows * preset_card_h + @max(0, rows - 1) * preset_gap;
}

fn groupCardHeight(dark: usize, light: usize, cols: i32) i32 {
    var h: i32 = 52 + common.spacing_xl;
    if (dark > 0) h += sub_header_h + gridHeight(dark, cols);
    if (light > 0) h += sub_header_h + gridHeight(light, cols);
    return h;
}

pub const Page = struct {
    alloc: std.mem.Allocator = undefined,
    io: std.Io = undefined,

    groups: []Group = &.{},
    groups_built: bool = false,
    user_themes: []theme_manager.UserTheme = &.{},
    needs_refresh: bool = true,

    pill_rects: [3]common.Rect = @splat(.{ .x = 0, .y = 0, .w = 0, .h = 0 }),
    hover_pill: i32 = -1,

    pub fn init(self: *Page, alloc: std.mem.Allocator, io: std.Io) void {
        self.* = .{ .alloc = alloc, .io = io };
    }

    pub fn deinit(self: *Page) void {
        self.freeGroups();
        self.freeUserThemes();
    }

    /// Leaving and re-entering the tab rescans the user-theme directory, so
    /// an externally added/removed `.toml` shows up without a restart.
    pub fn resetSession(self: *Page) void {
        self.freeUserThemes();
        self.needs_refresh = true;
        self.hover_pill = -1;
    }

    fn freeUserThemes(self: *Page) void {
        theme_manager.freeUserThemes(self.alloc, self.user_themes);
        self.user_themes = &.{};
    }

    fn refreshUserThemes(self: *Page) void {
        if (!self.needs_refresh) return;
        self.freeUserThemes();
        self.user_themes = theme_manager.scanUserThemes(self.alloc, self.io) catch &.{};
        self.needs_refresh = false;
    }

    fn freeGroups(self: *Page) void {
        for (self.groups) |g| {
            self.alloc.free(g.dark);
            self.alloc.free(g.light);
        }
        if (self.groups.len > 0) self.alloc.free(self.groups);
        self.groups = &.{};
        self.groups_built = false;
    }

    /// Build the source groups once, preserving the reference roster's
    /// insertion order (Catppuccin first, then Google, Gruvbox, ...).
    fn ensureGroups(self: *Page) void {
        if (self.groups_built) return;
        self.groups_built = true;

        var list: std.ArrayList(Group) = .empty;
        errdefer {
            for (list.items) |g| {
                self.alloc.free(g.dark);
                self.alloc.free(g.light);
            }
            list.deinit(self.alloc);
        }
        var dark_lists: std.ArrayList(std.ArrayList(usize)) = .empty;
        var light_lists: std.ArrayList(std.ArrayList(usize)) = .empty;
        defer {
            for (dark_lists.items) |*l| l.deinit(self.alloc);
            for (light_lists.items) |*l| l.deinit(self.alloc);
            dark_lists.deinit(self.alloc);
            light_lists.deinit(self.alloc);
        }

        for (theme_data.presets, 0..) |p, i| {
            var gi: usize = 0;
            var found = false;
            for (list.items, 0..) |g, idx| {
                if (std.mem.eql(u8, g.source, p.source)) {
                    gi = idx;
                    found = true;
                    break;
                }
            }
            if (!found) {
                list.append(self.alloc, .{
                    .source = p.source,
                    .dark = &.{},
                    .light = &.{},
                }) catch return;
                dark_lists.append(self.alloc, .empty) catch return;
                light_lists.append(self.alloc, .empty) catch return;
                gi = list.items.len - 1;
            }
            if (isLightVariant(p.variant)) {
                light_lists.items[gi].append(self.alloc, i) catch return;
            } else {
                dark_lists.items[gi].append(self.alloc, i) catch return;
            }
        }

        for (list.items, 0..) |*g, i| {
            g.dark = dark_lists.items[i].toOwnedSlice(self.alloc) catch &.{};
            g.light = light_lists.items[i].toOwnedSlice(self.alloc) catch &.{};
        }
        self.groups = list.toOwnedSlice(self.alloc) catch &.{};
    }

    // ------------------------------------------------------------- layout --

    fn pillGeom(self: *Page, c: ?*cairo.cairo_t, card_x: i32, card_w: i32) PillGeom {
        _ = self;
        const labels = [_][]const u8{ "Matugen", "Color Engine", "Custom Theme" };
        var widths: [3]i32 = undefined;
        for (labels, 0..) |label, i| {
            const tw = ui_paint.textWidthPx(c, label, 13, 600) + 36;
            widths[i] = common.clampInt(tw, 100, 170);
        }
        const gap = pill_gap;
        const avail = card_w - common.card_pad * 2;
        if (widths[0] + widths[1] + widths[2] + 2 * gap > avail) {
            const max_w = @max(1, @divTrunc(avail - 2 * gap, 3));
            for (&widths) |*w| w.* = @min(w.*, max_w);
        }
        const group_w = widths[0] + widths[1] + widths[2] + 2 * gap;
        const group_x = card_x + @divTrunc(card_w - group_w, 2);
        return .{
            .rects = .{
                .{ .x = group_x, .y = mode_toggle_y, .w = widths[0], .h = pill_h },
                .{ .x = group_x + widths[0] + gap, .y = mode_toggle_y, .w = widths[1], .h = pill_h },
                .{ .x = group_x + widths[0] + gap + widths[1] + gap, .y = mode_toggle_y, .w = widths[2], .h = pill_h },
            },
            .w = widths,
        };
    }

    fn contentBottom(self: *Page, g: Geo, view: View) i32 {
        const card_w = g.content_w - 16;
        var bottom = common.content_top + mode_card_h;
        if (!view.custom) return bottom + common.spacing_l;

        self.ensureGroups();
        const cols = gridCols(card_w);
        var next_top = common.content_top + mode_card_h + common.card_gap;
        for (self.groups) |grp| {
            if (grp.dark.len == 0 and grp.light.len == 0) continue;
            next_top += groupCardHeight(grp.dark.len, grp.light.len, cols) + common.card_gap;
        }
        if (self.user_themes.len > 0) {
            next_top += 52 + @as(i32, @intCast(self.user_themes.len)) * 44 + common.spacing_xl + common.card_gap;
        }
        next_top += 52 + 40 + common.spacing_xl;
        bottom = next_top;
        return bottom + common.spacing_l;
    }

    pub fn totalHeight(self: *Page, g: Geo, view: View) i32 {
        self.refreshUserThemes();
        self.ensureGroups();
        return self.contentBottom(g, view) - common.content_top;
    }

    // -------------------------------------------------------------- paint --

    pub fn paint(
        self: *Page,
        cr: ?*cairo.cairo_t,
        g: Geo,
        px: f64,
        ly: f64,
        glass_ov: f64,
        view: View,
    ) void {
        const c = cr orelse return;
        self.refreshUserThemes();
        self.ensureGroups();
        const card_x = g.content_x + card_inset;
        const card_w = g.content_w - 16;

        // Hover only tracks the three pills; leaving them clears the state.
        const pg = self.pillGeom(c, card_x, card_w);
        self.pill_rects = pg.rects;
        if (common.pointInRect(px, ly, self.pill_rects[0])) {
            self.hover_pill = 0;
        } else if (common.pointInRect(px, ly, self.pill_rects[1])) {
            self.hover_pill = 1;
        } else if (common.pointInRect(px, ly, self.pill_rects[2])) {
            self.hover_pill = 2;
        } else {
            self.hover_pill = -1;
        }

        // Card 1: COLOR SOURCE.
        ui_paint.card(c, @floatFromInt(card_x), @floatFromInt(common.content_top), @floatFromInt(card_w), @floatFromInt(mode_card_h), glass_ov);
        ui_paint.catLabel(c, @floatFromInt(card_x + common.card_pad), @floatFromInt(common.content_top + 22), "COLOR SOURCE");

        const labels = [_][]const u8{ "Matugen", "Color Engine", "Custom Theme" };
        const active = [3]bool{ view.matugen, !view.custom and !view.matugen, view.custom };
        for (labels, 0..) |label, i| {
            self.paintPill(c, pg.rects[i], label, active[i], self.hover_pill == @as(i32, @intCast(i)));
        }

        if (!view.custom) return;

        var next_top = common.content_top + mode_card_h + common.card_gap;
        const cols = gridCols(card_w);

        // Cards 2+: built-in presets grouped by source.
        for (self.groups) |grp| {
            if (grp.dark.len == 0 and grp.light.len == 0) continue;
            const gh = groupCardHeight(grp.dark.len, grp.light.len, cols);
            const group_top = next_top;
            ui_paint.card(c, @floatFromInt(card_x), @floatFromInt(group_top), @floatFromInt(card_w), @floatFromInt(gh), glass_ov);

            var header_buf: [64]u8 = undefined;
            const n = @min(grp.source.len, header_buf.len);
            @memcpy(header_buf[0..n], grp.source[0..n]);
            if (n > 0 and header_buf[0] >= 'a' and header_buf[0] <= 'z') header_buf[0] -= 32;
            ui_paint.catLabel(c, @floatFromInt(card_x + common.card_pad), @floatFromInt(group_top + 22), header_buf[0..n]);

            var content_y = group_top + 52;
            if (grp.dark.len > 0) {
                ui_paint.showText(c, @floatFromInt(card_x + common.card_pad), @floatFromInt(content_y + 16), "Dark", 11, 600, common.Theme.text_r, common.Theme.text_g, common.Theme.text_b, 0.55);
                content_y += sub_header_h;
                content_y = self.paintGrid(c, card_x, card_w, content_y, cols, grp.dark, view, glass_ov);
            }
            if (grp.light.len > 0) {
                ui_paint.showText(c, @floatFromInt(card_x + common.card_pad), @floatFromInt(content_y + 16), "Light", 11, 600, common.Theme.text_r, common.Theme.text_g, common.Theme.text_b, 0.55);
                content_y += sub_header_h;
                _ = self.paintGrid(c, card_x, card_w, content_y, cols, grp.light, view, glass_ov);
            }

            next_top = group_top + gh + common.card_gap;
        }

        // Card: user themes.
        if (self.user_themes.len > 0) {
            const user_top = next_top;
            const user_h = 52 + @as(i32, @intCast(self.user_themes.len)) * 44 + common.spacing_xl;
            ui_paint.card(c, @floatFromInt(card_x), @floatFromInt(user_top), @floatFromInt(card_w), @floatFromInt(user_h), glass_ov);
            ui_paint.catLabel(c, @floatFromInt(card_x + common.card_pad), @floatFromInt(user_top + 22), "USER THEMES");

            const item_x = card_x + common.card_pad;
            const item_w = card_w - common.card_pad * 2;
            var row_y = user_top + 56;
            for (self.user_themes) |entry| {
                const selected = std.mem.eql(u8, view.active_name, entry.name) and
                    std.mem.eql(u8, view.active_source, entry.source);
                if (selected) {
                    ui_paint.glassBox(c, @floatFromInt(item_x), @floatFromInt(row_y), @floatFromInt(item_w), 38, 8, common.Theme.acc_r, common.Theme.acc_g, common.Theme.acc_b, 0.20);
                }
                ui_paint.showText(c, @floatFromInt(item_x + 12), @floatFromInt(row_y + 26), entry.name, 14, 500, 1, 1, 1, if (selected) 0.95 else 0.70);
                ui_paint.showText(c, @floatFromInt(item_x + item_w - 60), @floatFromInt(row_y + 26), entry.source, 11, 400, 0.5, 0.5, 0.5, 0.5);
                row_y += 44;
            }
            next_top = user_top + user_h + common.card_gap;
        }

        // Card: ACTIVE THEME.
        {
            const info_top = next_top;
            const info_h = 52 + 40 + common.spacing_xl;
            ui_paint.card(c, @floatFromInt(card_x), @floatFromInt(info_top), @floatFromInt(card_w), @floatFromInt(info_h), glass_ov);
            ui_paint.catLabel(c, @floatFromInt(card_x + common.card_pad), @floatFromInt(info_top + 22), "ACTIVE THEME");
            var info_buf: [256]u8 = undefined;
            const info = std.fmt.bufPrint(&info_buf, "{s}  ({s})", .{ view.active_name, view.active_source }) catch view.active_name;
            ui_paint.showText(c, @floatFromInt(card_x + common.card_pad), @floatFromInt(info_top + 56), info, 15, 500, common.Theme.text_r, common.Theme.text_g, common.Theme.text_b, 0.90);
        }
    }

    fn paintGrid(
        self: *Page,
        c: *cairo.cairo_t,
        card_x: i32,
        card_w: i32,
        content_y: i32,
        cols: i32,
        indices: []const usize,
        view: View,
        glass_ov: f64,
    ) i32 {
        const total_w = cols * preset_card_w + @max(0, cols - 1) * preset_gap;
        const grid_x = card_x + @divTrunc(card_w - total_w, 2);
        for (indices, 0..) |pi, i| {
            const col = @mod(@as(i32, @intCast(i)), cols);
            const row = @divTrunc(@as(i32, @intCast(i)), cols);
            const px_ = grid_x + col * (preset_card_w + preset_gap);
            const py_ = content_y + row * (preset_card_h + preset_gap);
            const preset = theme_data.presets[pi];
            const selected = std.mem.eql(u8, view.active_name, preset.name) and
                std.mem.eql(u8, view.active_source, preset.source);
            self.paintPresetCard(c, px_, py_, preset, selected, glass_ov);
        }
        const rows = gridRows(indices.len, cols);
        return content_y + rows * preset_card_h + @max(0, rows - 1) * preset_gap;
    }

    fn paintPill(self: *Page, c: *cairo.cairo_t, r: common.Rect, label: []const u8, active: bool, hovered: bool) void {
        _ = self;
        const x: f64 = @floatFromInt(r.x);
        const y: f64 = @floatFromInt(r.y);
        const w: f64 = @floatFromInt(r.w);
        const h: f64 = @floatFromInt(r.h);
        const rad = @min(10.0, h * 0.5);
        if (active) {
            ui_paint.glassBox(c, x, y, w, h, rad, common.Theme.acc_r, common.Theme.acc_g, common.Theme.acc_b, if (hovered) 1.0 else 0.85);
        } else {
            ui_paint.glassBox(c, x, y, w, h, rad, 0.5, 0.5, 0.5, if (hovered) 0.26 else 0.15);
            ui_paint.roundRect(c, x, y, w, h, rad);
            cairo.cairo_set_source_rgba(c, 0.5, 0.5, 0.5, if (hovered) 0.55 else 0.30);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_stroke(c);
        }
        if (hovered) {
            ui_paint.roundRect(c, x, y, w, h, rad);
            cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.08);
            cairo.cairo_fill(c);
        }
        const tw = ui_paint.textWidthPx(c, label, 13, 600);
        const tx = x + (w - @as(f64, @floatFromInt(tw))) * 0.5;
        ui_paint.showText(c, tx, y + h * 0.5 + 7.0, label, 13, 600, if (active) 1 else 0.5, if (active) 1 else 0.5, if (active) 1 else 0.5, if (active) (if (hovered) 1.0 else 0.95) else (if (hovered) 0.9 else 0.7));
    }

    fn paintPresetCard(self: *Page, c: *cairo.cairo_t, cx: i32, cy: i32, preset: theme_data.Preset, selected: bool, glass_ov: f64) void {
        _ = self;
        const x: f64 = @floatFromInt(cx);
        const y: f64 = @floatFromInt(cy);
        const w: f64 = @floatFromInt(preset_card_w);
        const h: f64 = @floatFromInt(preset_card_h);
        if (selected) {
            ui_paint.glassBox(c, x - 2, y - 2, w + 4, h + 4, 10, common.Theme.acc_r, common.Theme.acc_g, common.Theme.acc_b, 0.30);
        }
        ui_paint.card(c, x, y, w, h, glass_ov);

        const p = preset.palette;
        const cols = [_][3]f32{ p.primary, p.secondary, p.tertiary, p.surface, p.outline };
        const sw = preset_card_w / 5;
        for (cols, 0..) |col, i| {
            cairo.cairo_rectangle(c, x + @as(f64, @floatFromInt(i * sw)), y, @floatFromInt(sw), preset_swatch_h);
            cairo.cairo_set_source_rgba(c, col[0], col[1], col[2], 1.0);
            cairo.cairo_fill(c);
        }
        const tx: f64 = x + 10;
        ui_paint.showText(c, tx, y + preset_swatch_h + 22, preset.name, 13, 600, 1, 1, 1, 0.90);
        ui_paint.showText(c, tx, y + preset_swatch_h + 40, preset.source, 11, 400, 1, 1, 1, 0.45);
        if (preset.variant.len > 0) {
            ui_paint.showText(c, tx, y + preset_swatch_h + 56, preset.variant, 10, 400, 1, 1, 1, 0.35);
        }
    }

    // ---------------------------------------------------------------- hit --

    pub fn hit(self: *Page, g: Geo, px: f64, ly: f64, view: View) ?Action {
        self.refreshUserThemes();
        self.ensureGroups();
        const card_x = g.content_x + card_inset;
        const card_w = g.content_w - 16;

        if (common.pointInRect(px, ly, self.pill_rects[0])) return .{ .mode = .matugen };
        if (common.pointInRect(px, ly, self.pill_rects[1])) return .{ .mode = .color_engine };
        if (common.pointInRect(px, ly, self.pill_rects[2])) return .{ .mode = .custom };
        if (!view.custom) return null;

        const cols = gridCols(card_w);
        var next_top = common.content_top + mode_card_h + common.card_gap;
        for (self.groups) |grp| {
            if (grp.dark.len == 0 and grp.light.len == 0) continue;
            const gh = groupCardHeight(grp.dark.len, grp.light.len, cols);
            const group_top = next_top;
            var content_y = group_top + 52;
            if (grp.dark.len > 0) {
                content_y += sub_header_h;
                if (hitGrid(card_x, card_w, content_y, cols, grp.dark, px, ly)) |gi| return .{ .pick_preset = gi };
                const rows = gridRows(grp.dark.len, cols);
                content_y += rows * preset_card_h + @max(0, rows - 1) * preset_gap;
            }
            if (grp.light.len > 0) {
                content_y += sub_header_h;
                if (hitGrid(card_x, card_w, content_y, cols, grp.light, px, ly)) |gi| return .{ .pick_preset = gi };
            }
            next_top = group_top + gh + common.card_gap;
        }

        if (self.user_themes.len > 0) {
            const user_top = next_top;
            const item_x = card_x + common.card_pad;
            const item_w = card_w - common.card_pad * 2;
            var row_y = user_top + 56;
            for (self.user_themes, 0..) |_, i| {
                if (common.pointInRect(px, ly, .{ .x = item_x, .y = row_y, .w = item_w, .h = 38 })) {
                    return .{ .pick_user = i };
                }
                row_y += 44;
            }
        }
        return null;
    }

    pub fn presetAt(self: *Page, index: usize) ?theme_data.Preset {
        _ = self;
        if (index >= theme_data.presets.len) return null;
        return theme_data.presets[index];
    }

    pub fn userAt(self: *Page, index: usize) ?theme_manager.UserTheme {
        if (index >= self.user_themes.len) return null;
        return self.user_themes[index];
    }
};

fn hitGrid(card_x: i32, card_w: i32, content_y: i32, cols: i32, indices: []const usize, px: f64, ly: f64) ?usize {
    const total_w = cols * preset_card_w + @max(0, cols - 1) * preset_gap;
    const grid_x = card_x + @divTrunc(card_w - total_w, 2);
    for (indices, 0..) |pi, i| {
        const col = @mod(@as(i32, @intCast(i)), cols);
        const row = @divTrunc(@as(i32, @intCast(i)), cols);
        const x = grid_x + col * (preset_card_w + preset_gap);
        const y = content_y + row * (preset_card_h + preset_gap);
        if (common.pointInRect(px, ly, .{ .x = x, .y = y, .w = preset_card_w, .h = preset_card_h })) return pi;
    }
    return null;
}

test "settings-color-themes: groups preserve roster order and split dark/light" {
    const t = std.testing;
    var p: Page = .{};
    p.init(t.allocator, std.testing.io);
    defer p.deinit();
    p.ensureGroups();
    try t.expect(p.groups.len > 0);
    try t.expectEqualStrings("catppuccin", p.groups[0].source);
    // Catppuccin has Latte (light) plus nine seed-derived dark variants.
    try t.expectEqual(@as(usize, 1), p.groups[0].light.len);
    try t.expectEqual(@as(usize, 9), p.groups[0].dark.len);
    // The index points back into the generated roster.
    try t.expectEqualStrings("Catppuccin Latte", theme_data.presets[p.groups[0].light[0]].name);
    try t.expectEqual(@as(usize, 268), theme_data.presets.len);
}

test "settings-color-themes: scroll height only grows for custom source" {
    const t = std.testing;
    var p: Page = .{};
    p.init(t.allocator, std.testing.io);
    defer p.deinit();
    const g: Geo = .{ .content_x = 386, .content_w = 498, .win_h = 980 };
    const off = p.totalHeight(g, .{});
    const on = p.totalHeight(g, .{ .custom = true });
    try t.expect(on > off);
}
