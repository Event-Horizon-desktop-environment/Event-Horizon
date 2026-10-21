const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const m3_box = @import("../../m3/core/primitives/box.zig");
const m3_button = @import("../../m3/controls/containers/button.zig");
const icon_themes = @import("../../desktop_shell/common/icon_themes.zig");

// The Icons tab — the Zig port of src/ux/settings/settings_tab_icons/*.
//
// Like the Wallpaper and Bing tabs this is a *page*, not a card list:
// `ui_content.Content` has no rows for it and delegates here (`Content.icons`).
// The page owns the theme grid — cards with live icon previews — plus the
// preview cache and the Apply/Cancel backup; the window owns `Settings` and
// applies the picked theme.
//
// Same design as the C++: every card is an m3 glass box (accent when current,
// panel otherwise, both hover-brightened) with an accent stroke, a green dot
// and up to four previews rasterized from the theme's own icons; picking
// selects live, Apply persists and pushes the theme out to GNOME/Qt/KDE, and
// Cancel restores the backup taken on the first paint. Leaving the tab clears
// the preview cache and the backup (C++ `clear_icons_preview_cache()` +
// `icons_backup_reset()` on every tab change away from 44).

pub const tab_id: i32 = 44;
// Grid geometry (`kIconCardW`, `kIconCardH`, …).
const card_w: i32 = 320;
const card_h: i32 = 140;
const preview_px: i32 = 56;
const preview_gap: i32 = 12;
const preview_pad_top: i32 = 24;
const grid_gap: i32 = 12;
/// The strip above the first row, and the allowance below the last row (or
/// the empty state) for the Apply/Cancel block — both `60` in
/// `icons_tab_layout`.
const k_grid_top_offset: i32 = 60;
const k_bottom_block: i32 = 60;
/// `colsFor` insets the content width by this before packing cards
/// (`availableW = contentW - 32`).
const k_grid_inset: i32 = 32;
/// First card row: `kContentTop + kSpacingL + kGridTopOffset`.
const grid_top: i32 = common.content_top + common.spacing_l + k_grid_top_offset; // 92
const btn_w: i32 = 110;
const btn_h: i32 = 36;
/// Apply sits this far left of Cancel; the row this far below the grid.
const k_btn_gap_x: i32 = 12;
const k_btn_row_gap: i32 = 16;
/// How many preview icons one card shows.
const previews_per_card: usize = 4;
/// `ensurePreviews` tries at most this many names before falling back to a
/// directory scan (C++ `tried.reserve(16)` + `>= 16` cap).
const k_tried_cap: usize = 16;
/// `theme_find_any_icons` asks for this many fallback names.
const k_fallback_scan: usize = 8;

// Paint constants — the C++ paints these inline per card.
/// Card surface fill alphas: accent when current, panel otherwise, each
/// hover-brightened. `f32`: that is what `m3_box.setColor` takes.
const k_acc_hover_a: f32 = 0.30;
const k_acc_a: f32 = 0.22;
const k_card_hover_a: f32 = 0.92;
const k_card_a: f32 = 0.85;
const k_card_radius: f64 = 10.0;
/// Stroke: the accent, 2px when current; the white m3 hairline otherwise.
const k_sel_stroke_a: f64 = 0.60;
const k_sel_stroke_w: f64 = 2.0;
const k_card_hairline_a: f64 = 0.08;
const k_card_hairline_w: f64 = 1.0;
/// The m3 hairline is white at every call site (`paint_src_glass_hi`).
const k_hairline_rgb: f64 = 1.0;
/// Current-theme dot (C++ `dotSize`, inset into the card corner).
const k_dot_size: f64 = 10.0;
const k_dot_inset: f64 = 18.0;
const k_dot_r: f64 = 0.35;
const k_dot_g: f64 = 0.85;
const k_dot_b: f64 = 0.45;
const k_dot_alpha: f64 = 1.0;
/// The page's one card surface never shrinks below this.
const k_card_min_h: f64 = 200.0;
/// Card header labels, measured from the card top.
const k_cat_label_dy: f64 = 22.0;
const k_setting_label_dy: f64 = 46.0; // + kSpacingL
/// Empty-state line.
const k_empty_text_dy: i32 = 160;
const k_empty_text_alpha: f64 = 0.7;
/// Card labels: the name and the (dimmer) directory id, from the card
/// bottom — the id sits higher because the name is stacked above it.
const k_name_font_sp: f32 = 13;
const k_id_font_sp: f32 = 10;
const k_weight_regular: c_uint = 400;
const k_weight_bold: c_uint = 700;
const k_name_alpha: f64 = 1.0;
const k_id_alpha: f64 = 0.55;
const k_id_label_dy: f64 = 42.0;
const k_name_label_dy: f64 = 18.0;
/// A one-line label (theme without a distinct name) sits slightly lower.
const k_name_single_dy: f64 = 20.0;
/// No animation clock reaches the page, so the buttons paint idle.
const k_no_anim_ms: u64 = 0;

/// The preview names every card tries, in order, after the theme's own
/// `Example=` entry (`kPreviewIconNames`).
const k_preview_icons = [_][]const u8{
    "folder",          "text-x-generic",      "computer",             "application-x-executable",
    "media-optical",   "input-mouse",         "preferences-system",   "help-browser",
    "document",        "user",                "system-search",        "internet-web-browser",
};

/// Content-column geometry, passed in rather than read from `Content` so
/// this module stays free of a cycle back into `ui_content`.
pub const Geo = struct {
    content_x: i32,
    content_w: i32,
    win_h: i32,
};

/// One Icons-tab press, translated into what the window must do.
pub const Action = union(enum) {
    /// A theme card was picked by index into the page's theme list.
    pick_theme: usize,
    /// Apply: persist the picked theme and push it to the toolkits.
    apply,
    /// Cancel: restore the backup taken on the first paint.
    cancel,
};

pub const Layout = struct {
    cols: i32,
    grid_left: i32,
    /// First card row — `kContentTop + kSpacingL + kGridTopOffset`, same at
    /// every width.
    grid_top: i32 = grid_top,
};

/// `icons_tab_layout` — as many 320px cards per row as the column fits,
/// grid centred.
pub fn colsFor(content_w: i32) i32 {
    return @max(1, @divTrunc(content_w - k_grid_inset, card_w + grid_gap));
}

pub fn layout(content_x: i32, content_w: i32, n: usize) Layout {
    const cols = colsFor(content_w);
    const total_w: i32 = if (n > 0) cols * card_w + (cols - 1) * grid_gap else 0;
    return .{
        .cols = cols,
        .grid_left = content_x + @divTrunc(content_w - total_w, 2),
    };
}

fn rowCount(n: usize, cols: i32) i32 {
    if (n == 0) return 0;
    return @divTrunc(@as(i32, @intCast(n)) + cols - 1, cols);
}

/// The card rectangle for grid index `i`.
fn cardRect(lay: Layout, i: usize) common.Rect {
    const cols_u: usize = @intCast(lay.cols);
    const col: i32 = @intCast(i % cols_u);
    const row: i32 = @intCast(i / cols_u);
    return .{
        .x = lay.grid_left + col * (card_w + grid_gap),
        .y = lay.grid_top + row * (card_h + grid_gap),
        .w = card_w,
        .h = card_h,
    };
}

/// `icons_tab_content_bottom_px` — the scroll extent, measured past the
/// Apply/Cancel row (the paint-side card height stops one gap shorter).
fn contentBottom(g: Geo, n: usize) i32 {
    if (n == 0) return common.content_top + common.spacing_l + k_grid_top_offset + k_bottom_block;
    const lay = layout(g.content_x, g.content_w, n);
    const rows = rowCount(n, lay.cols);
    return lay.grid_top + rows * (card_h + grid_gap) + common.spacing_l + k_bottom_block;
}

const PreviewList = std.ArrayListUnmanaged(*cairo.cairo_surface_t);

pub const Page = struct {
    alloc: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    /// Installed themes for the current frame — re-listed at the top of every
    /// entry point, exactly like the C++ which calls
    /// `list_installed_icon_themes()` on every paint, hit-test and scroll
    /// measure, so the grid follows installs/removals while the tab is open.
    themes: []icon_themes.ThemeInfo = &.{},
    /// Rasterized preview icons per theme id (C++ `s_previewCache`).
    previews: std.StringHashMapUnmanaged(PreviewList) = .{},
    /// Apply/Cancel backup of `Settings.icon_theme` (C++ `s_backupIconTheme`).
    backup_theme: []const u8 = "",
    backup_inited: bool = false,
    /// Button rects from the last paint (C++ file statics).
    apply_btn: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    cancel_btn: common.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn init(self: *Page, alloc: std.mem.Allocator, io: std.Io) void {
        self.* = .{ .alloc = alloc, .io = io };
    }

    pub fn deinit(self: *Page) void {
        self.freeThemes();
        self.clearPreviews();
        self.backupReset();
    }

    /// `clear_icons_preview_cache()` + `icons_backup_reset()` — the C++ runs
    /// both together on every tab change away from 44, so one call carries
    /// both here too.
    pub fn resetSession(self: *Page) void {
        self.clearPreviews();
        self.backupReset();
    }

    pub fn backupReset(self: *Page) void {
        // The captured slice always points at a string the window's arena (or
        // a static) owns, so it never has to be freed here.
        self.backup_theme = "";
        self.backup_inited = false;
    }

    /// `icons_backup_init` — snapshot the live value on first paint.
    fn backupInit(self: *Page, current: []const u8) void {
        if (self.backup_inited) return;
        self.backup_theme = current;
        self.backup_inited = true;
    }

    /// Apply commits the current value as the new backup.
    pub fn backupCommit(self: *Page, current: []const u8) void {
        self.backup_theme = current;
        self.backup_inited = true;
    }

    pub fn hasChanges(self: *const Page, current: []const u8) bool {
        return self.backup_inited and !std.mem.eql(u8, current, self.backup_theme);
    }

    fn freeThemes(self: *Page) void {
        icon_themes.freeThemes(self.alloc, self.themes);
        self.themes = &.{};
    }

    fn refreshThemes(self: *Page) void {
        self.freeThemes();
        self.themes = icon_themes.listInstalledThemes(self.alloc, self.io) catch &.{};
    }

    // ----------------------------------------------------------- previews --

    fn clearPreviews(self: *Page) void {
        var it = self.previews.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |s| cairo.cairo_surface_destroy(s);
            e.value_ptr.deinit(self.alloc);
            self.alloc.free(e.key_ptr.*);
        }
        // `HashMapUnmanaged.deinit` leaves the struct `undefined`, so restore
        // a real empty map — this runs again on window deinit after a
        // tab-leave `resetSession`, and must stay idempotent.
        self.previews.deinit(self.alloc);
        self.previews = .{};
    }

    /// Build one theme's preview row on first sight (C++ builds per theme id
    /// in `s_previewCache`): the theme's `Example=`, then the shared name
    /// list, then whatever icons the theme actually ships.
    fn ensurePreviews(self: *Page, theme: icon_themes.ThemeInfo) void {
        const gop = self.previews.getOrPut(self.alloc, theme.id) catch return;
        if (gop.found_existing) return;
        gop.key_ptr.* = self.alloc.dupe(u8, theme.id) catch {
            _ = self.previews.remove(theme.id);
            return;
        };
        // Everything built below is transient except the surfaces, so all the
        // name strings live in a per-build arena.
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var list: PreviewList = .empty;
        if (theme.path.len > 0) {
            var tried: [k_tried_cap][]const u8 = undefined;
            var tried_n: usize = 0;
            if (icon_themes.themeExampleIconName(a, self.io, theme.path)) |example| {
                // C++ only queues a non-empty Example (an empty value means
                // the theme declared the key without a value).
                if (example.len > 0) {
                    tried[tried_n] = example;
                    tried_n += 1;
                }
            }
            for (k_preview_icons) |pn| {
                if (tried_n >= tried.len) break;
                var dup = false;
                for (tried[0..tried_n]) |t| {
                    if (std.mem.eql(u8, t, pn)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) {
                    tried[tried_n] = pn;
                    tried_n += 1;
                }
            }
            for (tried[0..tried_n]) |nm| {
                if (list.items.len >= previews_per_card) break;
                if (icon_themes.loadThemePreviewIcon(a, self.io, theme.path, nm, preview_px)) |s| {
                    list.append(self.alloc, s) catch {
                        cairo.cairo_surface_destroy(s);
                        break;
                    };
                }
            }
            if (list.items.len < previews_per_card) {
                if (icon_themes.themeFindAnyIcons(a, self.io, theme.path, k_fallback_scan)) |found| {
                    for (found) |nm| {
                        if (list.items.len >= previews_per_card) break;
                        var dup = false;
                        for (tried[0..tried_n]) |t| {
                            if (std.mem.eql(u8, t, nm)) {
                                dup = true;
                                break;
                            }
                        }
                        if (dup) continue;
                        if (icon_themes.loadThemePreviewIcon(a, self.io, theme.path, nm, preview_px)) |s| {
                            list.append(self.alloc, s) catch {
                                cairo.cairo_surface_destroy(s);
                                break;
                            };
                        }
                    }
                } else |_| {
                    // No index.theme or no declared directories: the theme
                    // simply has no fallback previews.
                }
            }
        }
        gop.value_ptr.* = list;
    }

    // ------------------------------------------------------ scroll height --

    /// What the scroll extent is measured to (`icons_tab_content_bottom_px`,
    /// converted into the below-`y0` space `Content` measures pages in).
    pub fn totalHeight(self: *Page, g: Geo) i32 {
        self.refreshThemes();
        return contentBottom(g, self.themes.len) - common.content_top;
    }

    // ---------------------------------------------------------------- paint --

    pub fn paint(
        self: *Page,
        cr: ?*cairo.cairo_t,
        g: Geo,
        px: f64,
        ly: f64,
        glass_ov: f64,
        current: []const u8,
    ) void {
        const c = cr orelse return;
        self.refreshThemes();
        const t = common.Theme;
        const n = self.themes.len;
        const lay = layout(g.content_x, g.content_w, n);
        const rows = rowCount(n, lay.cols);

        // One card surface under the whole page (C++ `settings_card`).
        const card_top: f64 = @floatFromInt(common.content_top);
        const content_bottom: f64 = @floatFromInt(if (n > 0)
            lay.grid_top + rows * (card_h + grid_gap) + common.spacing_l
        else
            common.content_top + common.spacing_l + k_grid_top_offset + k_bottom_block);
        const card_ht = @max(
            k_card_min_h,
            @max(
                content_bottom - card_top + @as(f64, @floatFromInt(common.spacing_l)),
                @as(f64, @floatFromInt(g.win_h)) - card_top - @as(f64, @floatFromInt(common.spacing_l)),
            ),
        );
        ui_paint.card(c, @floatFromInt(g.content_x), card_top, @floatFromInt(g.content_w), card_ht, glass_ov);
        ui_paint.catLabel(
            c,
            @floatFromInt(g.content_x + common.card_pad),
            card_top + k_cat_label_dy,
            "Icons",
        );
        ui_paint.settingLabel(
            c,
            @floatFromInt(g.content_x + common.card_pad),
            card_top + @as(f64, @floatFromInt(common.spacing_l)) + k_setting_label_dy,
            "Select an icon theme",
            "",
        );

        if (n == 0) {
            ui_paint.showText(
                c,
                @floatFromInt(g.content_x + common.card_pad),
                @floatFromInt(common.content_top + k_empty_text_dy),
                "No icon themes found.",
                k_name_font_sp,
                k_weight_regular,
                t.text_r,
                t.text_g,
                t.text_b,
                k_empty_text_alpha,
            );
            return;
        }

        for (self.themes, 0..) |theme, i| {
            self.ensurePreviews(theme);
            const r = cardRect(lay, i);
            const cx: f64 = @floatFromInt(r.x);
            const cy: f64 = @floatFromInt(r.y);
            const is_current = std.mem.eql(u8, theme.id, current);
            const hover = px >= cx and px < cx + @as(f64, @floatFromInt(card_w)) and
                ly >= cy and ly < cy + @as(f64, @floatFromInt(card_h));

            {
                var box: m3_box.Box = .{};
                if (is_current) {
                    box.setColor(
                        @floatCast(t.acc_r),
                        @floatCast(t.acc_g),
                        @floatCast(t.acc_b),
                        if (hover) k_acc_hover_a else k_acc_a,
                    );
                } else {
                    box.setColor(
                        @floatCast(t.bg_r),
                        @floatCast(t.bg_g),
                        @floatCast(t.bg_b),
                        if (hover) k_card_hover_a else k_card_a,
                    );
                }
                box.setRadius(k_card_radius);
                box.setGeometry(
                    @floatCast(cx),
                    @floatCast(cy),
                    @floatFromInt(card_w),
                    @floatFromInt(card_h),
                );
                box.setGlassy(true);
                box.paint(c);
            }

            ui_paint.roundRect(c, cx, cy, @floatFromInt(card_w), @floatFromInt(card_h), k_card_radius);
            if (is_current) {
                cairo.cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, k_sel_stroke_a);
                cairo.cairo_set_line_width(c, k_sel_stroke_w);
            } else {
                // `paint_src_glass_hi` — the white hairline every m3 surface
                // uses for its edge.
                cairo.cairo_set_source_rgba(c, k_hairline_rgb, k_hairline_rgb, k_hairline_rgb, k_card_hairline_a);
                cairo.cairo_set_line_width(c, k_card_hairline_w);
            }
            cairo.cairo_stroke(c);

            if (is_current) {
                cairo.cairo_set_source_rgba(c, k_dot_r, k_dot_g, k_dot_b, k_dot_alpha);
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

            // Previews on a 56px pitch, centred (the C++ squashes each icon
            // into its 56px slot; at the sizes themes ship that is a fit).
            if (self.previews.get(theme.id)) |list| {
                const count: i32 = @intCast(list.items.len);
                if (count > 0) {
                    const total_w: f64 = @floatFromInt(count * (preview_px + preview_gap) - preview_gap);
                    const px0 = cx + (@as(f64, @floatFromInt(card_w)) - total_w) * 0.5;
                    for (list.items, 0..) |surf, pi| {
                        const sw = cairo.cairo_image_surface_get_width(surf);
                        const sh = cairo.cairo_image_surface_get_height(surf);
                        if (sw <= 0 or sh <= 0) continue;
                        const sx = px0 + @as(f64, @floatFromInt(@as(i32, @intCast(pi)) * (preview_px + preview_gap)));
                        const sy = cy + @as(f64, @floatFromInt(preview_pad_top));
                        const sc_x = @as(f64, @floatFromInt(preview_px)) / @as(f64, @floatFromInt(sw));
                        const sc_y = @as(f64, @floatFromInt(preview_px)) / @as(f64, @floatFromInt(sh));
                        cairo.cairo_save(c);
                        cairo.cairo_rectangle(
                            c,
                            sx,
                            sy,
                            @floatFromInt(preview_px),
                            @floatFromInt(preview_px),
                        );
                        cairo.cairo_clip(c);
                        cairo.cairo_translate(c, sx, sy);
                        cairo.cairo_scale(c, sc_x, sc_y);
                        cairo.cairo_set_source_surface(c, surf, 0, 0);
                        cairo.cairo_paint(c);
                        cairo.cairo_restore(c);
                    }
                }
            }

            // Labels: the directory id (dim) above the display name, or just
            // the name when the theme does not carry a distinct one.
            const display_name = if (theme.name.len > 0) theme.name else theme.id;
            const weight: c_uint = if (is_current) k_weight_bold else k_weight_regular;
            if (theme.name.len > 0 and !std.mem.eql(u8, theme.name, theme.id)) {
                const iw = ui_paint.textWidthPx(c, theme.id, k_id_font_sp, k_weight_regular);
                const id_x = cx + (@as(f64, @floatFromInt(card_w)) - @as(f64, @floatFromInt(iw))) * 0.5;
                ui_paint.showText(c, id_x, cy + @as(f64, @floatFromInt(card_h)) - k_id_label_dy, theme.id, k_id_font_sp, k_weight_regular, t.text_r, t.text_g, t.text_b, k_id_alpha);
                const nw = ui_paint.textWidthPx(c, display_name, k_name_font_sp, weight);
                const text_x = cx + (@as(f64, @floatFromInt(card_w)) - @as(f64, @floatFromInt(nw))) * 0.5;
                ui_paint.showText(c, text_x, cy + @as(f64, @floatFromInt(card_h)) - k_name_label_dy, display_name, k_name_font_sp, weight, t.text_r, t.text_g, t.text_b, k_name_alpha);
            } else {
                const nw = ui_paint.textWidthPx(c, display_name, k_name_font_sp, weight);
                const text_x = cx + (@as(f64, @floatFromInt(card_w)) - @as(f64, @floatFromInt(nw))) * 0.5;
                ui_paint.showText(c, text_x, cy + @as(f64, @floatFromInt(card_h)) - k_name_single_dy, display_name, k_name_font_sp, weight, t.text_r, t.text_g, t.text_b, k_name_alpha);
            }
        }

        // Apply / Cancel (m3 Outlined XS, Apply gated on the backup delta).
        self.backupInit(current);
        {
            const grid_bottom = lay.grid_top + rows * (card_h + grid_gap) - grid_gap;
            const btn_y = grid_bottom + k_btn_row_gap;
            self.cancel_btn = .{
                .x = g.content_x + g.content_w - common.card_pad - btn_w,
                .y = btn_y,
                .w = btn_w,
                .h = btn_h,
            };
            self.apply_btn = .{
                .x = self.cancel_btn.x - btn_w - k_btn_gap_x,
                .y = btn_y,
                .w = btn_w,
                .h = btn_h,
            };
            const has_changes = self.hasChanges(current);

            var apply: m3_button.Button = .{};
            apply.setMinSize(0, 0);
            apply.setLabel("Apply");
            apply.setGeometry(
                @floatFromInt(self.apply_btn.x),
                @floatFromInt(self.apply_btn.y),
                @floatFromInt(btn_w),
                @floatFromInt(btn_h),
            );
            apply.setStyle(.outlined);
            apply.setSize(.xs);
            apply.setEnabled(has_changes);
            apply.setAccentColor(@floatCast(t.acc_r), @floatCast(t.acc_g), @floatCast(t.acc_b));
            apply.setOutlineColor(@floatCast(t.outline_r), @floatCast(t.outline_g), @floatCast(t.outline_b));
            apply.setHovered(common.pointInRect(px, ly, self.apply_btn));
            apply.paint(c, k_no_anim_ms);

            var cancel: m3_button.Button = .{};
            cancel.setMinSize(0, 0);
            cancel.setLabel("Cancel");
            cancel.setGeometry(
                @floatFromInt(self.cancel_btn.x),
                @floatFromInt(self.cancel_btn.y),
                @floatFromInt(btn_w),
                @floatFromInt(btn_h),
            );
            cancel.setStyle(.outlined);
            cancel.setSize(.xs);
            cancel.setEnabled(true);
            cancel.setAccentColor(@floatCast(t.acc_r), @floatCast(t.acc_g), @floatCast(t.acc_b));
            cancel.setOutlineColor(@floatCast(t.outline_r), @floatCast(t.outline_g), @floatCast(t.outline_b));
            cancel.setHovered(common.pointInRect(px, ly, self.cancel_btn));
            cancel.paint(c, k_no_anim_ms);
        }
    }

    // ----------------------------------------------------------------- hit --

    pub fn hit(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        self.refreshThemes();
        const n = self.themes.len;
        if (n > 0) {
            const lay = layout(g.content_x, g.content_w, n);
            for (self.themes, 0..) |_, i| {
                if (common.pointInRect(px, ly, cardRect(lay, i))) return .{ .pick_theme = i };
            }
        }
        if (common.pointInRect(px, ly, self.apply_btn)) return .apply;
        if (common.pointInRect(px, ly, self.cancel_btn)) return .cancel;
        return null;
    }
};

test "settings-icons-tab: grid layout follows the specified arrangement" {
    const t = std.testing;
    // 592px column: (592-kGridInset)/332 = 1 column, centred in the column.
    try t.expectEqual(@as(i32, 1), colsFor(592));
    var lay = layout(292, 592, 3);
    try t.expectEqual(@as(i32, 292 + (592 - card_w) / 2), lay.grid_left);
    try t.expectEqual(@as(i32, grid_top), cardRect(lay, 0).y);
    try t.expectEqual(@as(i32, grid_top + card_h + grid_gap), cardRect(lay, 1).y);
    // A 1000px column fits two 320px cards with the 12px gap.
    try t.expectEqual(@as(i32, 2), colsFor(1000));
    lay = layout(292, 1000, 3);
    try t.expectEqual(@as(i32, 292 + (1000 - (2 * card_w + grid_gap)) / 2), lay.grid_left);
    try t.expectEqual(@as(i32, card_w + grid_gap), cardRect(lay, 1).x - cardRect(lay, 0).x);
    // Zero themes centres on nothing (totalW 0, like the C++ paint path).
    lay = layout(292, 592, 0);
    try t.expectEqual(@as(i32, 292 + 592 / 2), lay.grid_left);
}

test "settings-icons-tab: scroll extent lands past the button row" {
    const t = std.testing;
    const g = Geo{ .content_x = 292, .content_w = 592, .win_h = 980 };
    // Empty state: `kContentTop + kSpacingL + topOffset + bottomBlock`,
    // measured below y0.
    try t.expectEqual(@as(i32, common.content_top + common.spacing_l + k_grid_top_offset + k_bottom_block - common.content_top), contentBottom(g, 0) - common.content_top);
    // One row of one column: gridTop + 1*(140+12) + kSpacingL + bottomBlock,
    // below y0.
    const one_row = contentBottom(g, 1) - common.content_top;
    try t.expectEqual(@as(i32, grid_top + (card_h + grid_gap) + common.spacing_l + k_bottom_block - common.content_top), one_row);
    // Two rows add exactly one card pitch.
    try t.expectEqual(@as(i32, one_row + card_h + grid_gap), contentBottom(g, 2) - common.content_top);
}

test "settings-icons-tab: backup follows init/commit/reset rules" {
    const t = std.testing;
    var p: Page = .{};
    p.init(t.allocator, std.testing.io);
    defer p.deinit();

    // First paint snapshots, and a matching value means no changes.
    p.backupInit("Adwaita");
    try t.expect(p.backup_inited);
    try t.expect(!p.hasChanges("Adwaita"));
    try t.expect(p.hasChanges("Papirus"));

    // A second init (later paints) must not overwrite the snapshot.
    p.backupInit("Papirus");
    try t.expectEqualStrings("Adwaita", p.backup_theme);
    try t.expect(p.hasChanges("Papirus"));

    // Apply commits; a reset (tab left) clears both the flag and the value.
    p.backupCommit("Papirus");
    try t.expect(!p.hasChanges("Papirus"));
    p.resetSession();
    try t.expect(!p.backup_inited);
    try t.expectEqualStrings("", p.backup_theme);
    try t.expect(!p.hasChanges("Papirus"));
}

// ---------------------------------------------------------------------------
// Tab models (placeholders for the Themes / Color Themes pages, kept from the
// original stub so `eh.settings_icons_themes_tab` keeps exporting them).
// ---------------------------------------------------------------------------

pub const IconsModel = struct {
    theme: []const u8 = "",
    picker_open: bool = false,
};

pub const QtScheme = enum { auto, light, dark };

pub const ThemesModel = struct {
    gtk_theme: []const u8 = "",
    qt_scheme: QtScheme = .auto,
    cursor_theme: []const u8 = "",
    cursor_size: i32 = 24,
    plasma_theme: []const u8 = "",

    pub fn clampAll(self: *ThemesModel) void {
        self.cursor_size = common.clampInt(self.cursor_size, 16, 64);
    }
};

pub const ColorThemesModel = struct {
    active_preset: []const u8 = "",
    matugen_active: bool = true,
    editor_open: bool = false,
    brightness_pct: i32 = 100,
    contrast_pct: i32 = 100,
    vibrance_pct: i32 = 100,
};
