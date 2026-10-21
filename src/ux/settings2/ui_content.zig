const std = @import("std");
const app_mod = @import("app.zig");
const common = @import("common.zig");
const rows_mod = @import("rows.zig");
const fields = @import("fields.zig");
const widget_lists = @import("widget_lists.zig");
const ui_paint = @import("ui_paint.zig");
const ui_subtab = @import("ui_subtab.zig");
const ui_widgets = @import("ui_widgets.zig");
const mon_state = @import("monitors_state.zig");
const mon_tab = @import("monitors_tab_helpers.zig");
const mon_page = @import("monitors_page.zig");
const wallpaper_tab = @import("wallpaper_tab.zig");
const bing_tab = @import("bing_tab.zig");
const icons_themes_tab = @import("icons_themes_tab.zig");
const desktop_widgets_tab = @import("desktop_widgets_tab.zig");
const default_apps_tab = @import("default_apps_tab.zig");
const hyprland_data = @import("hyprland_data.zig");
const hyprland_tab = @import("hyprland_tab.zig");
const hyprland_page = @import("hyprland_page.zig");
const bluetooth_tab = @import("bluetooth_tab.zig");
const sound_tab = @import("sound_tab.zig");
const templates_tab = @import("templates_tab.zig");
const time_tab = @import("time_tab.zig");
const accounts_tab = @import("accounts_tab.zig");
const icon_cache = @import("../../desktop_shell/common/icon_cache.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;

// Content paint + input — the generic renderer for the per-tab card lists in
// rows.zig. It renders every tab with one geometry pass:
// `place()` computes every card/row rect (section-card layout: inset
// cards, cat label + subtitle band, 60px bands with dividers), paint draws it
// with the shared helpers, hit-test walks the same rects. The
// fixed child-tab bar sits above the scroll clip.

pub const content_top: i32 = common.content_top; // 48
pub const max_placed: usize = 160;

pub const PlacedRow = struct {
    row: rows_mod.Row,
    card_i: usize,
    row_i: usize,
    /// Row box in window coordinates (unscrolled).
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    card_x: i32,
    card_y: i32,
    card_w: i32,
    card_h: i32,
};

/// Top band of a card: titled cards reserve 52px for label + subtitle,
/// untitled cards (embedded-widget toggles) start rows immediately. The
/// shared helper in rows.zig is what `cardHeightFor` sizes with as well.
fn cardTopBand(c: rows_mod.Card) i32 {
    return rows_mod.topBand(c);
}

fn cardBottomPad(c: rows_mod.Card) i32 {
    return if (cardTopBand(c) > 0) rows_mod.card_pad_y else 16;
}

/// Walk an explicit card list into `out`. Returns the row count and sets
/// The column the section cards sit in. The Hyprland tab centers them in a
/// 68% column; every other tab spans the
/// content box with the usual 8px inset.
pub const Column = struct { x: i32, w: i32 };

pub fn columnFor(tab: i32, content_x: i32, content_w: i32) ?Column {
    // The Hyprland section pages center their cards — and align their page
    // headers — in one 68% column (`hyprland_page.column`); every other tab
    // spans the content box with the usual 8px inset (placeCards's default).
    const hy = hyprland_page.column(tab, content_x, content_w) orelse return null;
    return .{ .x = hy.x, .w = hy.w };
}

/// `*total_h` to the scrollable height below `y0`. `board_max` is the live
/// widget-board max column (see `rowHeightFor`); pass 0 for the static lists
/// (tests, board-less pages).
pub fn placeCards(
    cards: []const rows_mod.Card,
    content_x: i32,
    content_w: i32,
    y0: i32,
    out: []PlacedRow,
    total_h: *i32,
    board_max: usize,
    column: ?Column,
) usize {
    var n: usize = 0;
    var y: i32 = y0;
    const start_y = y;
    const card_x = if (column) |c| c.x else content_x + 8;
    const card_w = if (column) |c| c.w else content_w - 16;
    for (cards, 0..) |card_def, ci| {
        const card_h = rows_mod.cardHeightFor(card_def, board_max);
        if (card_def.grid) {
            // 2-col tile grid — dock/panel/taskbar appearance geometry:
            // centered 68% column, cardW = (colW - 12) / 2 (min 160),
            // col = i % 2, row = i / 2, tiles 92px on a 104px pitch. A
            // titled grid (Appearance "Color adjustment") keeps its label
            // band above the first tile row; untitled grids start at
            // grid_top.
            const band = cardTopBand(card_def);
            const col_w: i32 = @divTrunc(content_w * 68, 100);
            const col_x = content_x + @divTrunc(content_w - col_w, 2);
            var tile_w: i32 = @divTrunc(col_w - rows_mod.tile_gap, 2);
            if (tile_w < 160) tile_w = 160;
            for (card_def.rows, 0..) |r, ri| {
                const col: i32 = @intCast(ri % 2);
                const grow: i32 = @intCast(ri / 2);
                const tx = col_x + col * (tile_w + rows_mod.tile_gap);
                const ty = y + band + rows_mod.grid_top + grow * (rows_mod.tile_h + rows_mod.tile_gap);
                if (n < out.len) {
                    out[n] = .{
                        .row = r,
                        .card_i = ci,
                        .row_i = ri,
                        .x = tx,
                        .y = ty,
                        .w = tile_w,
                        .h = rows_mod.tile_h,
                        .card_x = col_x,
                        .card_y = y,
                        .card_w = col_w,
                        .card_h = card_h,
                    };
                    n += 1;
                }
            }
            y += card_h;
            if (ci + 1 < cards.len) y += rows_mod.card_gap;
            continue;
        }
        const band = cardTopBand(card_def);
        var row_y = y + band;
        for (card_def.rows, 0..) |r, ri| {
            const rh = rows_mod.rowHeightFor(r, board_max);
            if (n < out.len) {
                out[n] = .{
                    .row = r,
                    .card_i = ci,
                    .row_i = ri,
                    .x = card_x,
                    .y = row_y,
                    .w = card_w,
                    .h = rh,
                    .card_x = card_x,
                    .card_y = y,
                    .card_w = card_w,
                    .card_h = card_h,
                };
                n += 1;
            }
            row_y += rh;
        }
        y += card_h;
        if (ci + 1 < cards.len) y += rows_mod.card_gap;
    }
    total_h.* = y - start_y;
    return n;
}

/// The static-page entry point: resolve the page through `cardsFor` and hand
/// it to `placeCards`. Tests and the non-monitors tabs go through here.
pub fn place(
    tab: i32,
    sub: i32,
    content_x: i32,
    content_w: i32,
    y0: i32,
    out: []PlacedRow,
    total_h: *i32,
    board_max: usize,
) usize {
    return placeCards(
        rows_mod.cardsFor(tab, sub),
        content_x,
        content_w,
        y0,
        out,
        total_h,
        board_max,
        columnFor(tab, content_x, content_w),
    );
}

pub const ComboPopup = struct {
    combo: rows_mod.ComboRow,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const Drag = struct {
    field: fields.Field,
    min: i32,
    max: i32,
    track_x: i32,
    track_w: i32,
};

pub const Hit = union(enum) {
    none,
    toggle: fields.Field,
    slider: Drag,
    combo: rows_mod.ComboRow,
    /// Row picked inside an open popup (index into its options).
    combo_pick: usize,
    button: []const u8,
    /// Child tab bar selection (index into the bar's labels).
    sub_tab: usize,
    /// Widget enable switch inside a widget board (column, index).
    widget_toggle: ui_widgets.WidgetRef,
    /// Add-widget button inside a widget board (column the picker targets).
    widget_add: usize,
    /// Remove (×) inside a widget board (column, index).
    widget_remove: ui_widgets.WidgetRef,
    /// Island chip inside a widget card (dock board only): floats that
    /// widget as its own pill.
    widget_island: ui_widgets.WidgetRef,
    /// Whole-section island button in a widget-board header (dock board
    /// only): column 0..2 groups that entire section into one pill.
    widget_section_island: usize,
    /// Drag-grip press inside a widget board (column, index): arms a
    /// reorder / cross-column move, committed on release.
    widget_drag: ui_widgets.WidgetRef,
    /// Reset-to-defaults row under a widget board.
    widgets_reset,
    /// Output selection pill on the monitors tab.
    pill: usize,
    /// Monitors toolbar button (index into the toolbar's labels).
    tool: usize,
    /// Output rectangle on the arrange canvas (index into the outputs).
    canvas_mon: usize,
    /// Empty arrange canvas: pan (or clear the selection) rather than drag.
    canvas_pan,
    /// Aux button under the arrange canvas (index into the aux labels).
    canvas_btn: usize,
    /// A wallpaper-tab press. `applyHit` returns false so the window routes
    /// it to `Win.onWallpaperAction` — the page owns its own session state.
    wallpaper: wallpaper_tab.Action,
    /// A Bing-tab press. Same shape as `wallpaper`: `applyHit` returns false
    /// so the window routes it to `Win.onBingAction`.
    bing: bing_tab.Action,
    /// A Bluetooth-tab press. Same shape again: `applyHit` returns false so
    /// the window routes it to `Win.onBluetoothAction`, which owns the
    /// auto-reconnect persistence.
    bluetooth: bluetooth_tab.Action,
    /// A Sound-page press (Devices / Bluetooth / Apps / Engine). Same shape:
    /// `applyHit` returns false so the window routes it to
    /// `Win.onSoundAction`, which owns the over-amp toggle and the
    /// `audio/audio.toml` bookkeeping.
    sound: sound_tab.Action,
    /// An Icons-tab press (theme card / Apply / Cancel). Same shape again:
    /// `applyHit` returns false so the window routes it to
    /// `Win.onIconsAction`, which owns `Settings`.
    icons: icons_themes_tab.Action,
    /// A Desktop-Widgets-tab press. Same shape: `applyHit` returns false so
    /// the window routes it to `Win.onDesktopWidgetsAction`.
    desktop_widgets: desktop_widgets_tab.Action,
    /// A Time-category press (30 System Time / 84 World Clock). Same shape
    /// again: `applyHit` returns false so the window routes it to its
    /// `[time]` flush; keys go through `Win.onKey` →
    /// `time_tab.Page.key`.
    time: time_tab.Action,
    /// An Accounts-tab press (tab 46). Same shape again: `applyHit` returns
    /// false so the window routes it to its `[general]` flush — the only
    /// account action that touches `Settings` is the avatar choice.
    accounts: accounts_tab.Action,
    /// A Templates-page press (tab 3). Same shape again: `applyHit` returns
    /// false so the window routes it to `Win.onTemplatesAction`, which
    /// flushes `[appearance.matugen_templates]` (or the base-recipes flag).
    templates: templates_tab.Action,
    /// Hyprland animation toggle (entry index into `k_anim_entries`).
    anim_toggle: u8,
    /// Hyprland animation 3-dot editor trigger (entry index).
    anim_dot: u8,
};

pub const Content = struct {
    settings: *app_mod.Settings,
    active_tab: i32 = 0,
    /// Active child tab per sidebar tab (sub-tab bars keep their own state).
    /// Indexed by tab id, so the length clears the highest id in the
    /// registry (`TabId.world_clock` = 84).
    sub_for: [96]i32 = .{0} ** 96,
    scroll_px: i32 = 0,
    content_x: i32 = common.content_x,
    content_w: i32 = 498,
    win_w: i32 = app_mod.window_width,
    win_h: i32 = app_mod.window_height,
    pointer_x: f64 = -1,
    pointer_y: f64 = -1,
    /// The same pointer in layout space (scroll applied). All the placed-rect
    /// hover tests compare against this — comparing against window-space
    /// `pointer_y` silently drifts once the page is scrolled.
    pointer_ly: f64 = -1,
    drag: ?Drag = null,
    open_combo: ?ComboPopup = null,
    placed: [max_placed]PlacedRow = undefined,
    placed_len: usize = 0,
    total_h: i32 = 0,

    /// Live monitors state, borrowed from the window. Null for the tabs and
    /// tests that construct a bare `Content` — the monitors page then falls
    /// back to the static card list in `rows_display`.
    mon: ?*mon_state.State = null,
    /// The Wallpaper tab's custom page, borrowed from the window. The tab
    /// has no card list of its own (a hero preview with an overlaid
    /// toolbar, a paging gallery grid and two sub-tabs), so when it is the
    /// active tab this `Content` delegates: empty placement, the page's own
    /// scroll height, and its paint/hit-test. Null elsewhere and in tests.
    wall: ?*wallpaper_tab.Page = null,
    /// The Bing Wallpaper page when it owns tab 34 (same delegation as `wall`).
    bing: ?*bing_tab.Page = null,
    /// The Bluetooth page when it owns tab 47 (same delegation as `wall`/
    /// `bing`): the ADAPTER/DISCOVERY/DEVICES card stack, all self-painted
    /// from live BlueZ.
    bt: ?*bluetooth_tab.Page = null,
    /// The Sound pages when they own tabs 8 / 81 / 82 / 83 (same delegation
    /// as `bt`): the Audio Center's four live pages.
    snd: ?*sound_tab.Page = null,
    /// The Time pages when one of their tabs (30 System Time / 84 World
    /// Clock) is active (same delegation as `bt`): the format / date /
    /// preview / network-time / timezone cards, or the shared World clocks
    /// editor alone, all self-painted by one instance.
    tm: ?*time_tab.Page = null,
    /// The Accounts page when tab 46 is active (same delegation as `tm`):
    /// the Users list, the profile / access / this-device cards and the two
    /// window-space modal dialogs.
    acc: ?*accounts_tab.Page = null,
    /// The Templates page when tab 3 is active (same delegation as `tm`):
    /// the grouped roster, its filter bar, detail panels, footer and the
    /// base-recipes switch, all self-painted by one instance.
    tpl: ?*templates_tab.Page = null,
    /// The Icons tab's page, borrowed from the window (same delegation as
    /// `wall`/`bing`): a centered grid of theme cards with live icon
    /// previews plus Apply/Cancel, none of which is a row of controls in a
    /// card list.
    icons: ?*icons_themes_tab.Page = null,
    /// The Desktop Widgets tab's page, borrowed from the window (same
    /// delegation): a display-output card plus a widget list with
    /// drag grips, toggles, remove buttons and per-row settings cogs.
    dwt: ?*desktop_widgets_tab.Page = null,
    /// The Default Apps tab's page, borrowed from the window. Unlike the
    /// pages above, it stays on the shared card renderer: `cards()` swaps
    /// the static placeholder for the page's dynamic nine-slot list (one
    /// dropdown per category over the installed app catalog).
    dapps: ?*default_apps_tab.Page = null,
    /// Live output names for the Desktop Widgets display dropdown. The
    /// window fills these from its bound Wayland outputs
    /// — see `Win.syncDesktopOutputs`.
    dwt_outputs: [16][]const u8 = [_][]const u8{""} ** 16,
    dwt_outputs_len: usize = 0,
    /// The monitors page rebuilt into these buffers each relayout (the card
    /// lists everywhere else are compile-time constants, so the one data-
    /// driven page owns its own storage).
    page: mon_page.Page = .{},
    /// The arrange canvas board from the last paint, in layout space. The
    /// window needs it for the pan/zoom hit and for the wheel anchor.
    canvas_box: ui_widgets.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// The widget board panel from the last paint, in layout space. Drag
    /// motion needs it to resolve the target column and insert index.
    widget_board_box: ui_widgets.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Active widget-board drag (grip press → motion → release commit).
    widget_drag: ui_widgets.BoardDrag = .{},

    /// The live widget section lists for a bar tab, borrowed straight from
    /// `Settings` (no copy — the board paints whatever is on disk plus any
    /// edit since the last save).
    pub fn boardLists(self: *const Content, tab: i32) [3][]const []const u8 {
        const s = self.settings;
        return switch (tab) {
            0 => .{ s.dock_left_widgets, s.dock_center_widgets, s.dock_right_widgets },
            11 => .{ s.taskbar_left_widgets, s.taskbar_center_widgets, s.taskbar_right_widgets },
            else => .{ &.{}, &.{}, &.{} },
        };
    }

    pub fn activeSub(self: *const Content) i32 {
        return self.sub_for[@intCast(self.active_tab)];
    }

    /// The wallpaper page when it owns this tab, else null. Every delegation
    /// site goes through here so the tab id is checked in one place.
    pub fn wallPage(self: *const Content) ?*wallpaper_tab.Page {
        if (self.wall == null) return null;
        if (self.active_tab != wallpaper_tab.tab_id) return null;
        return self.wall;
    }

    /// Content-column geometry for the page, in the shape it wants.
    pub fn wallGeo(self: *const Content) wallpaper_tab.Geo {
        return .{
            .content_x = self.content_x,
            .content_w = self.content_w,
            .win_h = self.win_h,
        };
    }

    /// The Bing page when it owns this tab, else null. Same single-place
    /// tab-id check as `wallPage`.
    pub fn bingPage(self: *const Content) ?*bing_tab.Page {
        if (self.bing == null) return null;
        if (self.active_tab != bing_tab.tab_id) return null;
        return self.bing;
    }

    /// Content-column geometry for the Bing page.
    pub fn bingGeo(self: *const Content) bing_tab.Geo {
        return .{
            .content_x = self.content_x,
            .content_w = self.content_w,
            .win_h = self.win_h,
        };
    }

    /// The Bluetooth page when it owns this tab, else null. Same single-place
    /// tab-id check as `wallPage`/`bingPage`.
    pub fn btPage(self: *const Content) ?*bluetooth_tab.Page {
        if (self.bt == null) return null;
        if (self.active_tab != bluetooth_tab.tab_id) return null;
        return self.bt;
    }

    /// Content-column geometry for the Bluetooth page.
    pub fn btGeo(self: *const Content) bluetooth_tab.Geo {
        return .{
            .content_x = self.content_x,
            .content_w = self.content_w,
            .win_h = self.win_h,
        };
    }

    /// The Sound page when one of its four tabs is active, else null. Same
    /// single-place check as `btPage`; the page dispatches the rail child
    /// from the `Geo.tab` id.
    pub fn sndPage(self: *const Content) ?*sound_tab.Page {
        if (self.snd == null) return null;
        if (!sound_tab.isSoundTab(self.active_tab)) return null;
        return self.snd;
    }

    /// The Time page when either Time-category tab is active, else null.
    /// Same single-place tab-id check as `btPage` — and the same place that
    /// tells the page which of the two halves it is showing (System Time =
    /// tab 30, World Clock = tab 84), so every paint/hit/modal site reads
    /// one owner.
    pub fn timePage(self: *const Content) ?*time_tab.Page {
        const p = self.tm orelse return null;
        if (!time_tab.ownsTab(self.active_tab)) return null;
        p.setMode(if (self.active_tab == time_tab.wc_tab_id) .world else .system);
        return p;
    }

    /// Content-column geometry for the Time page. Hands the page the live
    /// scroll offset so its picker modal can undo the content translate and
    /// paint in window space, like the Desktop Widgets popup.
    pub fn timeGeo(self: *const Content) time_tab.Geo {
        return .{
            .content_x = self.content_x,
            .content_w = self.content_w,
            .win_w = self.win_w,
            .win_h = self.win_h,
            .scroll_px = self.scroll_px,
        };
    }

    /// The Accounts page when tab 46 is active, else null (same
    /// single-owner check as `timePage`).
    pub fn accountsPage(self: *const Content) ?*accounts_tab.Page {
        const p = self.acc orelse return null;
        if (!accounts_tab.ownsTab(self.active_tab)) return null;
        return p;
    }

    /// Content-column geometry for the Accounts page. Same shape as
    /// `timeGeo`, including the live scroll offset so its toast and dialogs
    /// can paint in window space.
    pub fn accountsGeo(self: *const Content) accounts_tab.Geo {
        return .{
            .content_x = self.content_x,
            .content_w = self.content_w,
            .win_w = self.win_w,
            .win_h = self.win_h,
            .scroll_px = self.scroll_px,
        };
    }

    /// The Templates page when tab 3 is active, else null. Same single-place
    /// tab-id check as `accountsPage`.
    pub fn tplPage(self: *const Content) ?*templates_tab.Page {
        const p = self.tpl orelse return null;
        if (!templates_tab.ownsTab(self.active_tab)) return null;
        return p;
    }

    /// Content-column geometry for the Templates page. No scroll offset: the
    /// page's hit test gets the layout-space y through `unscroll` already,
    /// and it paints inside the translated clip like the other pages.
    pub fn tplGeo(self: *const Content) templates_tab.Geo {
        return .{
            .content_x = self.content_x,
            .content_w = self.content_w,
            .win_h = self.win_h,
        };
    }

    /// Content-column geometry for the Sound pages. Also hands the page the
    /// live scroll offset (its dropdown popup clamps against the window
    /// bottom in document space).
    pub fn sndGeo(self: *const Content) sound_tab.Geo {
        if (self.snd) |sp| sp.scroll_px_est = self.scroll_px;
        return .{
            .content_x = self.content_x,
            .content_w = self.content_w,
            .win_w = self.win_w,
            .win_h = self.win_h,
            .tab = self.active_tab,
        };
    }

    /// The Icons page when it owns this tab, else null. Same single-place
    /// tab-id check as `wallPage`/`bingPage`.
    pub fn iconsPage(self: *const Content) ?*icons_themes_tab.Page {
        if (self.icons == null) return null;
        if (self.active_tab != icons_themes_tab.tab_id) return null;
        return self.icons;
    }

    pub fn dwtOutputs(self: *const Content) []const []const u8 {
        return self.dwt_outputs[0..self.dwt_outputs_len];
    }

    /// The Desktop Widgets page when it owns this tab, else null. Same
    /// single-place tab-id check as `wallPage`/`bingPage`.
    pub fn dwtPage(self: *const Content) ?*desktop_widgets_tab.Page {
        if (self.dwt == null) return null;
        if (self.active_tab != desktop_widgets_tab.tab_id) return null;
        return self.dwt;
    }

    /// Content-column geometry for the Desktop Widgets page.
    pub fn dwtGeo(self: *const Content) desktop_widgets_tab.Geo {
        return .{
            .content_x = self.content_x,
            .content_w = self.content_w,
            .win_h = self.win_h,
        };
    }

    /// Content-column geometry for the Icons page.
    pub fn iconsGeo(self: *const Content) icons_themes_tab.Geo {
        return .{
            .content_x = self.content_x,
            .content_w = self.content_w,
            .win_h = self.win_h,
        };
    }

    /// Layout top: below the child bar when the tab has one. Hyprland
    /// section pages reserve the design-B header band instead, so their
    /// first card sits at `common.content_top + page_header.h`.
    pub fn y0(self: *const Content) i32 {
        if (hyprland_page.ownsTab(self.active_tab)) return hyprland_page.pageTop();
        return if (ui_subtab.barRect(self.active_tab, self.content_x, self.content_w) != null)
            common.child_content_top
        else
            content_top;
    }

    /// Scroll-clip top: headed pages keep the tri-line header inside the
    /// scroll (it scrolls away with the page), so Hyprland sections clip at
    /// the content top; every other page clips at its layout top so the
    /// fixed child-tab bar stays clear of the scroll.
    pub fn clipTop(self: *const Content) i32 {
        if (hyprland_page.ownsTab(self.active_tab)) return content_top;
        return self.y0();
    }

    pub fn relayout(self: *Content) void {
        self.rebuildPage();
        // The wallpaper tab is a custom page: no cards to place, and the
        // scroll extent comes from the page's own bottom edge.
        if (self.wallPage()) |wp| {
            self.placed_len = 0;
            self.total_h = wp.totalHeight(self.wallGeo());
            return;
        }
        // Bing tab: same again — a custom page with no placed rows.
        if (self.bingPage()) |bp| {
            self.placed_len = 0;
            self.total_h = bp.totalHeight(self.bingGeo());
            return;
        }
        // Bluetooth tab: likewise — the card stack and its device rows are
        // the page's own, and its bottom edge is the scroll extent.
        if (self.btPage()) |tp| {
            self.placed_len = 0;
            self.total_h = tp.totalHeight(self.btGeo());
            return;
        }
        // Time tab: self-painted cards (the World clocks list grows with the
        // city count), bottom edge is the scroll extent.
        if (self.timePage()) |tp| {
            self.placed_len = 0;
            self.total_h = tp.totalHeight(self.timeGeo());
            return;
        }
        // Accounts tab: self-painted users list + profile / access / device
        // cards; its bottom edge is the scroll extent.
        if (self.accountsPage()) |ap| {
            self.placed_len = 0;
            self.total_h = ap.totalHeight(self.accountsGeo());
            return;
        }
        // Templates tab: the grouped roster is the page's own; its bottom
        // edge is the scroll extent.
        if (self.tplPage()) |tp| {
            self.placed_len = 0;
            self.total_h = tp.totalHeight(self.tplGeo());
            return;
        }
        // Sound pages: four self-painted live pages; their bottom edge is
        // the scroll extent.
        if (self.sndPage()) |sp| {
            self.placed_len = 0;
            self.total_h = sp.totalHeight(self.sndGeo());
            return;
        }
        // Icons tab: likewise — the grid and its Apply/Cancel row are the
        // page's own, and its bottom edge is the scroll extent.
        if (self.iconsPage()) |ip| {
            self.placed_len = 0;
            self.total_h = ip.totalHeight(self.iconsGeo());
            return;
        }
        // Desktop Widgets tab: custom display + list page.
        if (self.dwtPage()) |dp| {
            self.placed_len = 0;
            self.total_h = dp.totalHeight();
            return;
        }
        self.placed_len = placeCards(
            self.cards(),
            self.content_x,
            self.content_w,
            self.y0(),
            &self.placed,
            &self.total_h,
            self.boardMax(),
            columnFor(self.active_tab, self.content_x, self.content_w),
        );
    }

    /// The card list this content renders. The monitors page is the one
    /// data-driven list — everything else is a compile-time constant.
    pub fn cards(self: *const Content) []const rows_mod.Card {
        if (self.mon != null and self.active_tab == app_mod.TabId.monitors) {
            return self.page.cardsSlice();
        }
        // Appearance (Opacity): the overlay grid grows from master +
        // Advanced to every per-surface slider once the page's own Advanced
        // switch is on — two static lists picked here so paint, hit-test and
        // the scroll extent all see the same page in the same frame.
        if (self.active_tab == app_mod.TabId.appearance_opacity) {
            return if (self.settings.overlay_opacity_advanced)
                &rows_mod.rows_appearance.opacity_advanced
            else
                &rows_mod.rows_appearance.opacity;
        }
        // Default Apps: the page's dynamic card list whenever the window
        // wired it (bare `Content` — tests — keep the static placeholder).
        if (self.dapps != null and self.active_tab == app_mod.TabId.default_apps) {
            return self.dapps.?.cardsSlice();
        }
        return rows_mod.cardsFor(self.active_tab, self.activeSub());
    }

    /// Rebuild the monitors page buffers from the live state. Called before
    /// every placement so paint, hit-test and scroll height all agree.
    fn rebuildPage(self: *Content) void {
        if (self.active_tab == app_mod.TabId.monitors) {
            if (self.mon == null) return;
            self.page.build(self.mon.?);
        }
        // Default Apps: rebuild the dynamic rows whenever the stored ids
        // moved (picks and the reset mark the page dirty). Zero queries
        // when the per-slot system-default caches are still valid.
        if (self.dapps != null and self.active_tab == app_mod.TabId.default_apps) {
            if (self.dapps.?.dirty) self.dapps.?.build(self.settings);
        }
    }

    // -----------------------------------------------------------------------
    // Field routing
    // -----------------------------------------------------------------------
    //
    // Every other tab stores its values in `Settings`; the monitors form
    // stores them in `monitors_state.State` (one string per monitor), so the
    // `monitor_*` Field variants are dispatched here rather than in
    // `fields.zig`. Nothing else in the renderer knows about that split.

    // Hyprland slots are the live compositor config, not `Settings`: they
    // are dispatched to hyprland_data the same way the monitors fields go to
    // monitors_state.
    pub fn getBool(self: *const Content, f: fields.Field) bool {
        if (self.mon != null and mon_page.isMonitorField(f)) {
            return mon_page.fieldBool(self.mon.?, f);
        }
        if (f.hyprSlot()) |slot| return hyprland_data.getBool(slot);
        return fields.getBool(self.settings, f);
    }

    pub fn setBool(self: *Content, f: fields.Field, v: bool) void {
        if (self.mon != null and mon_page.isMonitorField(f)) {
            mon_page.setFieldBool(self.mon.?, f, v);
            return;
        }
        if (f.hyprSlot()) |slot| {
            hyprland_data.setBool(slot, v);
            return;
        }
        fields.setBool(self.settings, f, v);
    }

    pub fn getInt(self: *const Content, f: fields.Field) i32 {
        if (self.mon != null and mon_page.isMonitorField(f)) {
            return mon_page.fieldInt(self.mon.?, f);
        }
        if (f.hyprSlot()) |slot| return hyprland_data.getInt(slot);
        return fields.getInt(self.settings, f);
    }

    pub fn setInt(self: *Content, f: fields.Field, v: i32) void {
        if (self.mon != null and mon_page.isMonitorField(f)) {
            mon_page.setFieldInt(self.mon.?, f, v);
            return;
        }
        if (f.hyprSlot()) |slot| {
            hyprland_data.setInt(slot, v);
            return;
        }
        fields.setInt(self.settings, f, v);
    }

    pub fn comboIndex(self: *const Content, f: fields.Field, options: []const []const u8) usize {
        if (self.mon != null and mon_page.isMonitorField(f)) {
            return mon_page.fieldComboIndex(self.mon.?, f, options);
        }
        if (f.hyprSlot()) |slot| return hyprland_data.comboIndex(slot, options);
        return fields.comboIndex(self.settings, f, options);
    }

    pub fn setComboIndex(self: *Content, f: fields.Field, options: []const []const u8, idx: usize) void {
        if (self.mon != null and mon_page.isMonitorField(f)) {
            mon_page.setFieldComboIndex(self.mon.?, f, options, idx);
            return;
        }
        if (f.hyprSlot()) |slot| {
            hyprland_data.setComboIndex(slot, options, idx);
            return;
        }
        fields.setComboIndex(self.settings, f, options, idx);
    }

    /// Slider display string: monitor sliders carry their own unit/format
    /// (`%.2f`, `nits`, `1.5×`); plain sliders keep `<v> <unit>`.
    pub fn sliderValueText(self: *const Content, sl: rows_mod.SliderRow, buf: []u8) []const u8 {
        const v = self.getInt(sl.field);
        // Hyprland rows carry their own value table in the UI slot:
        // print `value_labels[val - lo]`, then `%d %%`, then the plain
        // number, and never a unit.
        if (sl.field.hyprSlot()) |slot| return hyprland_data.valueText(slot, v, sl.min, buf);
        // Workspaces slot count prints "Auto" at 0.
        // kWsSlotLabels[0]), like the value pill.
        if (sl.field == fields.Field.workspaces_max_slots and v == 0) return "Auto";
        return switch (sl.fmt) {
            .div100 => std.fmt.bufPrint(buf, "{d:.2}", .{@as(f64, @floatFromInt(v)) / 100.0}) catch "",
            .div10000 => std.fmt.bufPrint(buf, "{d:.4}", .{@as(f64, @floatFromInt(v)) / 10000.0}) catch "",
            .nits => std.fmt.bufPrint(buf, "{d} nits", .{v}) catch "",
            .scale => std.fmt.bufPrint(buf, "{d:.1}×", .{@as(f64, @floatFromInt(v)) / 100.0}) catch "",
            // No trailing space for unit-less values ("8", not "8 ").
            .int => if (sl.unit.len == 0)
                std.fmt.bufPrint(buf, "{d}", .{v}) catch ""
            else
                std.fmt.bufPrint(buf, "{d} {s}", .{ v, sl.unit }) catch "",
        };
    }

    /// Tallest live widget column for the active page (0 when the page shows
    /// no data-driven board): keeps scroll height, card backs and hit rows
    /// on exactly the geometry the board paints.
    pub fn boardMax(self: *const Content) usize {
        if (widget_lists.barForTab(self.active_tab) == null) return 0;
        if (self.activeSub() != 1) return 0;
        return ui_widgets.maxColLen(self.boardLists(self.active_tab));
    }

    pub fn viewportH(self: *const Content) i32 {
        return self.win_h - self.y0() - common.spacing_l;
    }

    pub fn scrollMax(self: *const Content) i32 {
        return @max(0, self.total_h - self.viewportH());
    }

    /// Scroll offset in *layout* space for a window-space y.
    fn unscroll(self: *const Content, py: f64) i32 {
        return @as(i32, @intFromFloat(py)) + self.scroll_px;
    }

    pub fn hitTest(self: *const Content, px: f64, py: f64) Hit {
        // Popup first: it floats above the rows. The rect is re-derived from
        // the live row, so a click that lands between a scroll and the next
        // repaint still hits the option the user can actually see.
        if (self.open_combo) |pop| {
            if (self.comboPopupRect(pop.combo)) |r| {
                if (common.pointInRect(px, py, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h })) {
                    const idx: i32 = @divTrunc(@as(i32, @intFromFloat(py)) - r.y - 4, common.settings_dd_row_h);
                    if (idx >= 0 and idx < pop.combo.options.len) {
                        return .{ .combo_pick = @intCast(idx) };
                    }
                    return .none;
                }
            }
        }
        // Fixed child-tab bar (window space, above the scroll clip).
        if (ui_subtab.hit(
            ui_subtab.barRect(self.active_tab, self.content_x, self.content_w),
            px,
            py,
        )) |i| {
            return .{ .sub_tab = i };
        }
        // Wallpaper tab: no placed rows — the page's own hit test, in
        // layout space like everything else below.
        if (self.wallPage()) |wp| {
            if (wp.hit(self.wallGeo(), px, self.unscroll(py))) |act| {
                return .{ .wallpaper = act };
            }
            return .none;
        }
        // Bing tab: no placed rows either — the page's own hit test.
        if (self.bingPage()) |bp| {
            if (bp.hit(self.bingGeo(), px, self.unscroll(py))) |act| {
                return .{ .bing = act };
            }
            return .none;
        }
        // Bluetooth tab: no placed rows either — the page's own hit test.
        if (self.btPage()) |tp| {
            if (tp.hit(self.btGeo(), px, self.unscroll(py))) |act| {
                return .{ .bluetooth = act };
            }
            return .none;
        }
        // Time tab: no placed rows either — the page's own hit test.
        if (self.timePage()) |tp| {
            if (tp.hit(self.timeGeo(), px, self.unscroll(py))) |act| {
                return .{ .time = act };
            }
            return .none;
        }
        // Accounts tab: no placed rows either — the page's own hit test
        // (its system verbs run inline, like Bluetooth's BlueZ writes).
        if (self.accountsPage()) |ap| {
            if (ap.hit(self.accountsGeo(), px, self.unscroll(py))) |act| {
                return .{ .accounts = act };
            }
            return .none;
        }
        // Templates tab: no placed rows either — the page's own hit test
        // (switches mutate `Settings`; the window owns the flush).
        if (self.tplPage()) |tp| {
            if (tp.hit(self.tplGeo(), px, self.unscroll(py))) |act| {
                return .{ .templates = act };
            }
            return .none;
        }
        // Sound pages: same self hit test shape (the page applies the live
        // writes inline, like Bluetooth's BlueZ verbs).
        if (self.sndPage()) |sp| {
            if (sp.hit(self.sndGeo(), px, self.unscroll(py))) |act| {
                return .{ .sound = act };
            }
            return .none;
        }
        // Icons tab: no placed rows either — the page's own hit test.
        if (self.iconsPage()) |ip| {
            if (ip.hit(self.iconsGeo(), px, self.unscroll(py))) |act| {
                return .{ .icons = act };
            }
            return .none;
        }
        // Desktop Widgets tab: display dropdown, rows, add button.
        if (self.dwtPage()) |dp| {
            const outs = self.dwtOutputs();
            if (dp.hit(
                self.dwtGeo(),
                self.settings.desktop_widgets_output_name,
                outs,
                px,
                @floatFromInt(self.unscroll(py)),
            )) |act| {
                return .{ .desktop_widgets = act };
            }
            return .none;
        }
        const lx = px;
        const ly = self.unscroll(py);
        for (self.placed[0..self.placed_len]) |p| {
            if (ly < p.y or ly >= p.y + p.h) continue;
            if (lx < p.x or lx >= p.x + p.w) continue;
            switch (p.row) {
                .toggle => |tg| return .{ .toggle = tg.field },
                .tile_toggle => |tg| return .{ .toggle = tg.field },
                .tile_slider => |sl| {
                    const tr = tileTrack(p, self.active_tab);
                    // Hit band: (trX-6, trY-10, trW+12, 36). The value
                    // maps over the inset rail, like `trackWidth` — see
                    // `drawSlider`.
                    if (ly >= tr.y - 10 and ly < tr.y + 36 and lx >= tr.x - 6 and lx <= tr.x + tr.w + 6) {
                        return .{ .slider = .{
                            .field = sl.field,
                            .min = sl.min,
                            .max = sl.max,
                            .track_x = tr.x + kRailInset,
                            .track_w = @max(0, tr.w - 2 * kRailInset),
                        } };
                    }
                    return .none;
                },
                .anim => |an| {
                    const tgx: f64 = @floatFromInt(p.x + p.w - common.card_pad - 40 - 34);
                    const tgy: f64 = @floatFromInt(p.y + @divTrunc(rows_mod.anim_row_h - 24, 2));
                    if (lx >= tgx and lx < tgx + 40 and @as(f64, @floatFromInt(ly)) >= tgy and @as(f64, @floatFromInt(ly)) < tgy + 24) {
                        return .{ .anim_toggle = an.entry };
                    }
                    const dd = hyprland_tab.animDotCenter(p.card_x, p.card_w, p.y);
                    const dx = lx - @as(f64, @floatFromInt(dd.x));
                    const dy = @as(f64, @floatFromInt(ly)) - @as(f64, @floatFromInt(dd.cy));
                    if (@abs(dx) < @as(f64, hyprland_tab.anim_dot_hit_w) and @abs(dy) < @as(f64, hyprland_tab.anim_dot_hit_h)) {
                        return .{ .anim_dot = an.entry };
                    }
                    return .none;
                },
                .slider => |sl| {
                    const tr = if (isHyprStyle(self.active_tab)) hyprSliderTrack(p) else sliderTrack(p);
                    if (lx >= tr.x - 6 and lx <= tr.x + tr.w + 6) {
                        return .{ .slider = .{
                            .field = sl.field,
                            .min = sl.min,
                            .max = sl.max,
                            .track_x = tr.x + kRailInset,
                            .track_w = @max(0, tr.w - 2 * kRailInset),
                        } };
                    }
                    return .none;
                },
                .combo => |cb| return .{ .combo = cb },
                .button => |bt| return .{ .button = bt.label },
                .widget_board => {
                    const lists = self.boardLists(self.active_tab);
                    // Whole-section island button lives in the header, so it
                    // is checked before the card controls below it. Dock
                    // board only, matching the paint.
                    if (self.active_tab == app_mod.TabId.dock) {
                        if (ui_widgets.widgetSectionIslandHit(p.x, p.y, p.w, lx, ly)) |col| {
                            return .{ .widget_section_island = col };
                        }
                    }
                    // Grip first: the drag band is the leftmost thing on the
                    // card, and a press there arms a move rather than poking
                    // a control.
                    if (ui_widgets.widgetDragHit(lists, p.x, p.y, p.w, lx, ly)) |wh| {
                        return .{ .widget_drag = wh };
                    }
                    // Remove × first (it sits inside the card, left of the
                    // toggle, so the toggle test would also catch it).
                    if (ui_widgets.widgetRemoveHit(lists, p.x, p.y, p.w, lx, ly)) |wh| {
                        return .{ .widget_remove = wh };
                    }
                    // Island chip (dock board only — other bars paint no
                    // chip, so the box would be dead air there).
                    if (self.active_tab == app_mod.TabId.dock) {
                        if (ui_widgets.widgetIslandHit(lists, p.x, p.y, p.w, lx, ly)) |wh| {
                            return .{ .widget_island = wh };
                        }
                    }
                    if (ui_widgets.widgetHit(lists, p.x, p.y, p.w, lx, ly)) |wh| {
                        return .{ .widget_toggle = wh };
                    }
                    if (ui_widgets.widgetAddHit(lists, p.x, p.y, p.w, lx, ly)) |col| {
                        return .{ .widget_add = col };
                    }
                    if (ui_widgets.widgetsResetHit(lists, p.x, p.y, p.w, lx, ly)) {
                        return .widgets_reset;
                    }
                    return .none;
                },
                .toolbar => |tb| {
                    if (ui_widgets.toolbarHit(tb.buttons.len, p.x, p.y, lx, ly)) |i| {
                        // The live monitors page routes to an action; every
                        // other toolbar is decorative and keeps `.button`.
                        if (self.mon != null and self.active_tab == app_mod.TabId.monitors) {
                            return .{ .tool = i };
                        }
                        return .{ .button = tb.buttons[i] };
                    }
                    return .none;
                },
                .canvas => {
                    if (self.mon == null) return .none;
                    const st = self.mon.?;
                    const box = ui_widgets.canvasBoxRect(p.x, p.y, p.w, p.h);
                    // Aux buttons first: they sit below the board, but they
                    // are the smaller target and must not fall through to a
                    // pan.
                    if (ui_widgets.canvasAuxHit(&mon_page.canvas_aux_buttons, p.x, p.y, p.h, lx, ly)) |i| {
                        return .{ .canvas_btn = i };
                    }
                    if (lx < box.x or lx >= box.x + box.w or ly < box.y or ly >= box.y + box.h) {
                        return .none;
                    }
                    const v = mon_tab.canvasView(st, box.w, box.h);
                    const hit = mon_tab.canvasHitMonitor(&v, lx - @as(f64, @floatFromInt(box.x)), ly - @as(f64, @floatFromInt(box.y)));
                    if (hit >= 0) return .{ .canvas_mon = @intCast(hit) };
                    return .canvas_pan;
                },
                .pills => |pl| {
                    if (ui_widgets.pillsHit(pl.pills.len, p.x, p.y, lx, ly)) |i| {
                        return .{ .pill = i };
                    }
                    return .none;
                },
                else => return .none,
            }
        }
        return .none;
    }

    /// Toggle / set the value a hit refers to. Returns true when state moved.
    pub fn applyHit(self: *Content, hit: Hit, px: f64) bool {
        switch (hit) {
            .toggle => |f| {
                const cur = self.getBool(f);
                self.setBool(f, !cur);
                return true;
            },
            .slider => |d| {
                const v = common.sliderValueFromX(px, d.track_x, d.track_w, d.min, d.max);
                self.setInt(d.field, v);
                return true;
            },
            .combo => |cb| {
                if (self.open_combo) |pop| {
                    if (std.meta.eql(pop.combo, cb)) {
                        // Second click on the open combo closes it.
                        self.open_combo = null;
                        return true;
                    }
                }
                self.open_combo = null;
                self.openComboFor(cb);
                return true;
            },
            .combo_pick => return false, // window calls selectComboIndex
            .button => return false,
            .sub_tab => |i| {
                if (self.sub_for[@intCast(self.active_tab)] == @as(i32, @intCast(i))) return false;
                self.sub_for[@intCast(self.active_tab)] = @intCast(i);
                self.scroll_px = 0;
                self.open_combo = null;
                self.relayout();
                return true;
            },
            .anim_toggle => |ei| {
                const meta = hyprland_data.k_anim_entries[ei];
                hyprland_data.setAnimEnabled(meta.name, !hyprland_data.animEnabled(meta.name));
                return true;
            },
            .anim_dot => |ei| {
                hyprland_tab.anim_edit_idx = @intCast(ei);
                hyprland_tab.anim_curve_open = false;
                hyprland_tab.anim_curve_hover = -1;
                hyprland_tab.anim_style_open = false;
                hyprland_tab.anim_style_hover = -1;
                hyprland_tab.anim_speed_active = false;
                hyprland_tab.anim_speed_len = 0;
                return true;
            },
            // Widget board hits are window-routed (they need the allocator
            // and a save afterwards); see `Win.onButton`.
            .widget_toggle => return false,
            .widget_add => return false,
            .widget_remove => return false,
            .widget_island => return false,
            .widget_section_island => return false,
            .widget_drag => return false,
            .widgets_reset => return false,
            // Monitors hits are window-routed: the toolbar actions and the
            // canvas drag/pan need the state and a repaint, not a value poke.
            .tool => return false,
            .canvas_mon => return false,
            .canvas_pan => return false,
            .canvas_btn => return false,
            // The wallpaper page owns its session state and the window owns
            // `Settings`, so this hit is routed (like the monitors ones)
            // rather than applied here.
            .wallpaper => return false,
            .bing => return false,
            // The Bluetooth page runs its own BlueZ writes; the window owns
            // the auto-reconnect persistence, so this routes there too.
            .bluetooth => return false,
            // The Sound pages run their own PipeWire writes; the window owns
            // the over-amp toggle and the audio.toml bookkeeping.
            .sound => return false,
            // The Icons page holds the theme grid, the preview cache and the
            // backup; the window owns `Settings`, so this routes there too.
            .icons => return false,
            // The Desktop Widgets page edits the layout file and `Settings`
            // output/disabled state; the window owns both, so this routes
            // there too.
            .desktop_widgets => return false,
            // The Time page runs its own system writes and world-clock file
            // saves; the window owns `[time]`, so this routes there too.
            .time => return false,
            // The Accounts page runs its own system writes (chpasswd,
            // usermod, hostnamectl); only the avatar choice touches
            // `Settings`, and the window owns `[general]`.
            .accounts => return false,
            // The Templates page flips `Settings.matugen_templates` (and the
            // recipes flag); the window owns the appearance.toml flush.
            .templates => return false,
            .pill => |i| {
                if (self.mon) |st| {
                    if (i < st.outputs_len) {
                        st.selected = @intCast(i);
                        return true;
                    }
                    return false;
                }
                return false;
            },
            .none => return false,
        }
    }

    /// Select `idx` in the currently open popup (window routes it here).
    pub fn selectComboIndex(self: *Content, idx: usize) bool {
        const pop = self.open_combo orelse return false;
        if (idx >= pop.combo.options.len) return false;
        self.setComboIndex(pop.combo.field, pop.combo.options, idx);
        self.open_combo = null;
        return true;
    }

    /// Window-space rect of the dropdown for `cb`, derived from the *live*
    /// placed row every time it is asked for.
    ///
    /// `placed` is in layout space (paint scrolls it with a cairo translate)
    /// while the popup is drawn after `cairo_restore`, i.e. in window space,
    /// so the anchor comes back through the current `scroll_px`. Deriving it
    /// on demand rather than caching it at open time is what keeps the menu
    /// glued to its own row as the page scrolls underneath it.
    ///
    /// Null when the row is not on the current page or has scrolled entirely
    /// out of the visible band — the signal to dismiss the menu.
    pub fn comboPopupRect(self: *const Content, cb: rows_mod.ComboRow) ?ComboPopup {
        const band_top = self.clipTop();
        const band_bot = self.win_h - common.spacing_l;
        for (self.placed[0..self.placed_len]) |p| {
            const r = p.row;
            if (r != .combo) continue;
            if (!std.meta.eql(r.combo, cb)) continue;
            const row_y = p.y - self.scroll_px;
            if (row_y + p.h < band_top or row_y > band_bot) return null;
            const cw: i32 = if (cb.field == fields.Field.hypr_general_layout) hyprland_tab.layout_combo_w else common.settings_combo_w;
            const cx = p.x + p.w - common.card_pad - cw;
            const cy = row_y + @divTrunc(p.h - common.settings_combo_h, 2) + common.settings_combo_h + 4;
            const rows_n: i32 = @intCast(cb.options.len);
            const ph = rows_n * common.settings_dd_row_h + 8;
            const flip = cy + ph > band_bot;
            const py = if (flip) row_y - ph - 4 else cy;
            // Clamped to the top of the clip band, never `spacing_l`: the
            // popup is unclipped, so anything higher would paint over the
            // fixed child-tab bar (or, on headed pages, over the header's
            // own top edge).
            return .{
                .combo = cb,
                .x = cx,
                .y = @max(band_top, py),
                .w = cw,
                .h = ph,
            };
        }
        return null;
    }

    pub fn openComboFor(self: *Content, cb: rows_mod.ComboRow) void {
        self.open_combo = self.comboPopupRect(cb);
    }

    /// Record the pointer. `pointer_ly` is the same point in *layout* space
    /// (scroll applied); every placed-rect hover test uses it, because a
    /// window-space y only matches layout rects while the page is unscrolled.
    pub fn setPointer(self: *Content, px: f64, py: f64) void {
        self.pointer_x = px;
        self.pointer_y = py;
        self.pointer_ly = if (py < 0) -1 else py + @as(f64, @floatFromInt(self.scroll_px));
    }

    // -----------------------------------------------------------------------
    // Arrange-canvas gesture entry points (window-routed; they need the
    // canvas board, which only the last paint recorded).
    // -----------------------------------------------------------------------

    /// Press on an output rect: select it and arm an arrangement drag from
    /// the pointer's current logical position.
    pub fn monSelect(self: *Content, i: usize) void {
        const st = self.mon orelse return;
        if (i >= st.outputs_len) return;
        st.selected = @intCast(i);
        const b = self.canvas_box;
        const lx = self.pointer_x - @as(f64, @floatFromInt(b.x));
        const ly = self.pointer_ly - @as(f64, @floatFromInt(b.y));
        st.pan_armed = false;
        mon_tab.beginDrag(st, b.w, b.h, i, lx, ly);
    }

    /// Press on empty canvas: arm a pan instead of a drag.
    pub fn monPanArm(self: *Content) void {
        const st = self.mon orelse return;
        const b = self.canvas_box;
        const lx = self.pointer_x - @as(f64, @floatFromInt(b.x));
        const ly = self.pointer_ly - @as(f64, @floatFromInt(b.y));
        st.drag_idx = -1;
        st.pan_armed = true;
        st.pan_grab_x = lx - st.pan_x;
        st.pan_grab_y = ly - st.pan_y;
    }

    /// Motion during an armed canvas gesture: live-drag the selected output,
    /// or follow the pointer with the pan.
    pub fn monMotion(self: *Content) bool {
        const st = self.mon orelse return false;
        const b = self.canvas_box;
        const lx = self.pointer_x - @as(f64, @floatFromInt(b.x));
        const ly = self.pointer_ly - @as(f64, @floatFromInt(b.y));
        if (st.drag_idx >= 0) {
            mon_tab.dragMoveTo(st, b.w, b.h, @intCast(st.drag_idx), lx, ly);
            return true;
        }
        if (st.pan_armed) {
            st.pan_x = lx - st.pan_grab_x;
            st.pan_y = ly - st.pan_grab_y;
            return true;
        }
        return false;
    }

    /// Release: commit an arrangement drag and unfreeze the fit.
    pub fn monRelease(self: *Content) bool {
        const st = self.mon orelse return false;
        const was = st.drag_idx >= 0 or st.pan_armed;
        if (st.drag_idx >= 0) mon_tab.finalizeArrangementDrag(st, @intCast(st.drag_idx));
        st.drag_idx = -1;
        st.pan_armed = false;
        st.fz_valid = false;
        return was;
    }

    // -----------------------------------------------------------------------
    // Widget-board drag entry points (window-routed; they need the board
    // panel rect, which only the last paint recorded).
    // -----------------------------------------------------------------------

    /// Grip press: arm a reorder / cross-column move. The insert index and
    /// lift follow on motion; a press without motion commits nothing.
    pub fn widgetDragArm(self: *Content, wr: ui_widgets.WidgetRef) void {
        const lists = self.boardLists(self.active_tab);
        if (wr.col > 2 or wr.idx >= lists[wr.col].len) return;
        const b = self.widget_board_box;
        if (b.w <= 0) return;
        const card = ui_widgets.cardRect(b.x, b.y, b.w, wr.col, wr.idx);
        self.widget_drag = .{
            .active = true,
            .dragging = false,
            .src_col = wr.col,
            .src_idx = wr.idx,
            .target_col = wr.col,
            .insert_before = wr.idx,
            .press_x = self.pointer_x,
            .press_y = self.pointer_ly,
            .grab_dx = self.pointer_x - @as(f64, @floatFromInt(card.x)),
            .grab_dy = self.pointer_ly - @as(f64, @floatFromInt(card.y)),
            .lift_x = @as(f64, @floatFromInt(card.x)),
            .lift_y = @as(f64, @floatFromInt(card.y)),
            .id = lists[wr.col][wr.idx],
        };
    }

    /// Motion during an armed board drag: cross the slop threshold, then
    /// track the target column + insert index and the lifted card. Returns
    /// true when a board drag consumed the motion.
    pub fn widgetDragMotion(self: *Content) bool {
        const d = &self.widget_drag;
        if (!d.active) return false;
        const b = self.widget_board_box;
        if (b.w <= 0) {
            d.active = false;
            return false;
        }
        const dx = self.pointer_x - d.press_x;
        const dy = self.pointer_ly - d.press_y;
        if (!d.dragging and (dx * dx + dy * dy) > 25.0) d.dragging = true;
        if (!d.dragging) return true;
        const tgt = ui_widgets.widgetDropTarget(
            self.boardLists(self.active_tab),
            b.x,
            b.y,
            b.w,
            self.pointer_x,
            self.pointer_ly,
            d.src_col,
            d.src_idx,
        );
        d.target_col = tgt.col;
        d.insert_before = tgt.insert_before;
        d.lift_x = self.pointer_x - d.grab_dx;
        d.lift_y = self.pointer_ly - d.grab_dy;
        return true;
    }

    /// Release: take the pending commit, if the press became a real drag.
    /// A bare grip click (never past slop) disarms with no commit.
    pub fn takeWidgetDragCommit(self: *Content) ?struct {
        src_col: usize,
        src_idx: usize,
        dst_col: usize,
        insert_before: usize,
    } {
        const d = self.widget_drag;
        self.widget_drag = .{};
        if (!d.active or !d.dragging) return null;
        return .{
            .src_col = d.src_col,
            .src_idx = d.src_idx,
            .dst_col = d.target_col,
            .insert_before = d.insert_before,
        };
    }

    /// Wheel over the canvas board: zoom about the pointer. Returns true when the wheel was
    /// consumed by the canvas rather than scrolling the page.
    pub fn monWheel(self: *Content, delta_px: f64) bool {
        const st = self.mon orelse return false;
        if (self.active_tab != app_mod.TabId.monitors) return false;
        const b = self.canvas_box;
        const lx = self.pointer_x - @as(f64, @floatFromInt(b.x));
        const ly = self.pointer_ly - @as(f64, @floatFromInt(b.y));
        if (lx < 0 or ly < 0 or lx >= @as(f64, @floatFromInt(b.w)) or ly >= @as(f64, @floatFromInt(b.h))) {
            return false;
        }
        mon_tab.wheelZoomCanvas(st, b.w, b.h, lx, ly, delta_px);
        return true;
    }

    fn accent() [3]f64 {
        const t = common.Theme;
        return .{ t.acc_r, t.acc_g, t.acc_b };
    }

    pub fn paint(self: *Content, cr: ?*cairo.cairo_t) void {
        const c = cr orelse return;
        const clip_top = self.clipTop();
        // Appearance → Opacity: the `.Settings` scale every card surface in
        // this window rides (`settings_card` at `0.78 * glassOv`), read live
        // from the same `Settings` the Opacity sliders write.
        const g_ov = self.settings.glassScale();
        cairo_save(c);
        cairo_rectangle(
            c,
            @floatFromInt(self.content_x),
            @floatFromInt(clip_top),
            @floatFromInt(self.content_w),
            @floatFromInt(self.win_h - clip_top - common.spacing_l),
        );
        cairo_clip(c);
        cairo_translate(c, 0, -@as(f64, @floatFromInt(self.scroll_px)));

        // Wallpaper tab: the page paints the whole scrollable region itself
        // (still inside the content clip and the scroll translate, so it
        // works in layout space exactly like a card list would).
        if (self.wallPage()) |wp| {
            wp.paint(
                c,
                self.wallGeo(),
                self.pointer_x,
                self.pointer_ly,
                g_ov,
            );
            cairo_restore(c);
            return;
        }

        // Bing tab: likewise paints the whole scrollable region itself.
        if (self.bingPage()) |bp| {
            bp.paint(
                c,
                self.bingGeo(),
                self.pointer_x,
                self.pointer_ly,
                g_ov,
            );
            cairo_restore(c);
            return;
        }

        // Bluetooth tab: likewise paints the whole scrollable region itself.
        if (self.btPage()) |tp| {
            tp.paint(
                c,
                self.btGeo(),
                self.pointer_x,
                self.pointer_ly,
                g_ov,
            );
            cairo_restore(c);
            return;
        }

        // Templates tab: likewise paints the whole scrollable region itself
        // — header actions, filter bar, grouped roster, details, footer.
        if (self.tplPage()) |tp| {
            tp.paint(
                c,
                self.tplGeo(),
                self.pointer_x,
                self.pointer_ly,
                g_ov,
            );
            cairo_restore(c);
            return;
        }

        // Sound pages: likewise paint the whole scrollable region themselves.
        if (self.sndPage()) |sp| {
            sp.paint(
                c,
                self.sndGeo(),
                self.pointer_x,
                self.pointer_ly,
                g_ov,
            );
            cairo_restore(c);
            return;
        }

        // Icons tab: likewise paints the whole scrollable region itself —
        // card surface, the theme grid with its previews, then the buttons.
        if (self.iconsPage()) |ip| {
            ip.paint(
                c,
                self.iconsGeo(),
                self.pointer_x,
                self.pointer_ly,
                g_ov,
                self.settings.icon_theme,
            );
            cairo_restore(c);
            return;
        }

        // Time tab: likewise paints the whole scrollable region itself (and,
        // on top, its picker modal in window space).
        if (self.timePage()) |tp| {
            tp.paint(
                c,
                self.timeGeo(),
                self.pointer_x,
                self.pointer_ly,
                g_ov,
            );
            cairo_restore(c);
            return;
        }

        // Accounts tab: likewise paints the whole scrollable region itself,
        // plus its transient toast and the two dialogs in window space.
        if (self.accountsPage()) |ap| {
            ap.paint(
                c,
                self.accountsGeo(),
                self.pointer_x,
                self.pointer_ly,
                g_ov,
            );
            cairo_restore(c);
            return;
        }

        // Desktop Widgets tab: display card + widget list (+ world-clock
        // modal while open). Pointer is layout-space, like the rows below.
        if (self.dwtPage()) |dp| {
            const outs = self.dwtOutputs();
            dp.paint(
                c,
                self.dwtGeo(),
                self.settings.desktop_widgets_output_name,
                self.settings.desktop_widget_slots_disabled,
                outs,
                self.pointer_x,
                self.pointer_ly,
                g_ov,
            );
            cairo_restore(c);
            return;
        }

        // Hyprland section pages carry no header — the list column already
        // names the section — so placement starts straight at `y0()`.

        var total: i32 = 0;
        const page_cards = self.cards();
        const n = placeCards(
            page_cards,
            self.content_x,
            self.content_w,
            self.y0(),
            &self.placed,
            &total,
            self.boardMax(),
            columnFor(self.active_tab, self.content_x, self.content_w),
        );
        self.placed_len = n;
        self.total_h = total;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = self.placed[i];
            // One card surface + title band per card, at its first row.
            // Grid cards paint their own per-tile surface in paintRow; a
            // titled grid (Appearance "Color adjustment") still paints its
            // label band, just without the card surface behind it.
            if (i == 0 or self.placed[i - 1].card_i != p.card_i) {
                const def = page_cards[p.card_i];
                if (!def.grid) {
                    ui_paint.card(
                        c,
                        @floatFromInt(p.card_x),
                        @floatFromInt(p.card_y),
                        @floatFromInt(p.card_w),
                        @floatFromInt(p.card_h),
                        g_ov,
                    );
                }
                if (def.title.len > 0) {
                    ui_paint.catLabel(
                        c,
                        @floatFromInt(p.card_x + common.card_pad),
                        @floatFromInt(p.card_y + 21),
                        def.title,
                    );
                }
                if (def.subtitle.len > 0) {
                    const t = common.Theme;
                    ui_paint.showText(
                        c,
                        @floatFromInt(p.card_x + common.card_pad),
                        @floatFromInt(p.card_y + 38),
                        def.subtitle,
                        11,
                        400,
                        t.text_r,
                        t.text_g,
                        t.text_b,
                        0.46,
                    );
                }
            }
            self.paintRow(c, p);
        }
        cairo_restore(c);
        // Fixed child-tab bar (outside the scroll clip).
        ui_subtab.paint(
            c,
            self.active_tab,
            self.content_x,
            self.content_w,
            @intCast(self.activeSub()),
            self.pointer_x,
            self.pointer_y,
        );
    }

    fn paintRow(self: *Content, c: anytype, p: PlacedRow) void {
        const t = common.Theme;
        const acc = accent();
        // Appearance tiles ride the same `.Settings` scale as the cards.
        const g_ov = self.settings.glassScale();
        const row_right: f64 = @floatFromInt(p.x + p.w - common.card_pad);
        const is_hypr = isHyprStyle(self.active_tab);
        // Band divider: Hyprland uses text@0.08 on every row after the first
        // (`hyprland_paint_row_divider`); other tabs use outline@0.15 on
        // toggle/combo bands only.
        if (p.row_i > 0) {
            if (is_hypr) {
                switch (p.row) {
                    .toggle, .slider, .combo, .anim => {
                        cairo_save(c);
                        cairo_set_line_width(c, 1.0);
                        cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, 0.08);
                        cairo_move_to(c, @floatFromInt(p.card_x + common.card_pad + 8), @floatFromInt(p.y));
                        cairo_line_to(c, @floatFromInt(p.card_x + p.card_w - common.card_pad - 8), @floatFromInt(p.y));
                        cairo_stroke(c);
                        cairo_restore(c);
                    },
                    else => {},
                }
            } else switch (p.row) {
                .toggle, .combo => {
                    cairo_save(c);
                    cairo_set_line_width(c, 1.0);
                    cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.15);
                    cairo_move_to(c, @floatFromInt(p.card_x + common.card_pad + 8), @floatFromInt(p.y));
                    cairo_line_to(c, @floatFromInt(p.card_x + p.card_w - common.card_pad - 8), @floatFromInt(p.y));
                    cairo_stroke(c);
                    cairo_restore(c);
                },
                else => {},
            }
        }
        switch (p.row) {
            .toggle => |tg| {
                const yf: f64 = @floatFromInt(p.y);
                if (is_hypr) {
                    // `hyprland_paint_toggle_card`: 14px/500 label at +22,
                    // 11px/400 desc at +42.
                    ui_paint.showText(c, @floatFromInt(p.x + common.card_pad), yf + 22, tg.label, 14, 500, t.text_r, t.text_g, t.text_b, 0.93);
                    if (tg.desc.len > 0) ui_paint.showText(c, @floatFromInt(p.x + common.card_pad), yf + 42, tg.desc, 11, 400, t.text_r, t.text_g, t.text_b, 0.46);
                } else {
                    // Same +26 label line as the slider/combo bands so
                    // mixed cards keep one baseline.
                    ui_paint.settingLabel(
                        c,
                        @floatFromInt(p.x + common.card_pad),
                        yf + 26,
                        tg.label,
                        tg.desc,
                    );
                }
                drawToggle(c, p.x + p.w - common.card_pad - common.toggle_w, p.y + @divTrunc(p.h - common.toggle_h, 2), common.toggle_w, common.toggle_h, self.getBool(tg.field), .l);
            },
            .slider => |sl| {
                const yf: f64 = @floatFromInt(p.y);
                const v = self.getInt(sl.field);
                var vbuf: [32]u8 = undefined;
                const disp = self.sliderValueText(sl, &vbuf);
                if (is_hypr) {
                    // `hyprland_paint_slider_card`: 13px/500 label at +24,
                    // shared value pill, m3 slider at (cardX+pad,
                    // rowY+30, cardW-2*pad, 36).
                    ui_paint.showText(c, @floatFromInt(p.x + common.card_pad), yf + 24, sl.label, 13, 500, t.text_r, t.text_g, t.text_b, 0.93);
                    // The pill rides 6px above the shared baseline: at max
                    // value the 20px thumb (rail center +48) reaches up into
                    // a +28-centered pill's bottom edge. Painted after the
                    // slider as well, so the thumb can never bite its corner.
                    drawSlider(c, hyprSliderTrack(p), v, sl.min, sl.max, dragActive(self.drag, sl.field), 10.0);
                    valuePill(c, p.card_x, p.y - 6, p.card_w, disp, .{ .weight = 500, .right = 16 });
                } else {
                    // Generic band: label+value on the +26 line, desc at
                    // +42, compact 16px thumb on the +58 rail — the dock
                    // appearance tile's stacking, so the knob can never
                    // ride over the description text.
                    ui_paint.settingLabel(
                        c,
                        @floatFromInt(p.x + common.card_pad),
                        yf + 26,
                        sl.label,
                        sl.desc,
                    );
                    const vw = ui_paint.textWidthPx(c, disp, 12, 400);
                    ui_paint.showText(
                        c,
                        row_right - @as(f64, @floatFromInt(vw)),
                        yf + 26,
                        disp,
                        12,
                        400,
                        t.text_r,
                        t.text_g,
                        t.text_b,
                        0.7,
                    );
                    drawSlider(c, sliderTrack(p), v, sl.min, sl.max, dragActive(self.drag, sl.field), 8.0);
                }
            },
            .combo => |cb| {
                const yf: f64 = @floatFromInt(p.y);
                ui_paint.settingLabel(
                    c,
                    @floatFromInt(p.x + common.card_pad),
                    yf + 26,
                    cb.label,
                    cb.desc,
                );
                // The Layout row is a hand-painted 140px combo,
                // not the generic 200px one.
                const bw = if (hyprland_tab.isSectionTab(self.active_tab) and cb.field == fields.Field.hypr_general_layout) hyprland_tab.layout_combo_w else common.settings_combo_w;
                const bh = common.settings_combo_h;
                const bx = p.x + p.w - common.card_pad - bw;
                const by = p.y + @divTrunc(p.h - bh, 2);
                const open = self.open_combo != null and std.meta.eql(self.open_combo.?.combo, cb);
                const hov = common.pointInRect(self.pointer_x, self.pointer_ly, .{ .x = bx, .y = by, .w = bw, .h = bh });
                const idx_opt = self.comboIndex(cb.field, cb.options);
                const disp = comboLabel(cb, idx_opt);
                drawCombo(c, bx, by, bw, bh, disp, open or hov, comboIcon(self, cb, idx_opt), cb.icons.len > 0);
            },
            .tile_slider => |sl| {
                // Appearance tile: surface,
                // 13px/500 title at +28, value pill, m3 slider on the track.
                ui_paint.card(
                    c,
                    @floatFromInt(p.x),
                    @floatFromInt(p.y),
                    @floatFromInt(p.w),
                    @floatFromInt(p.h),
                    g_ov,
                );
                ui_paint.showText(
                    c,
                    @floatFromInt(p.x + rows_mod.tile_pad_x),
                    @floatFromInt(p.y + rows_mod.tile_title_y),
                    sl.label,
                    13,
                    500,
                    t.text_r,
                    t.text_g,
                    t.text_b,
                    0.90,
                );
                const v = self.getInt(sl.field);
                var vbuf: [32]u8 = undefined;
                const disp = self.sliderValueText(sl, &vbuf);
                valuePill(c, p.x, p.y, p.w, disp, pillStyle(self.active_tab));
                drawSlider(c, tileTrack(p, self.active_tab), v, sl.min, sl.max, dragActive(self.drag, sl.field), 10.0);
            },
            .tile_toggle => |tg| {
                ui_paint.card(
                    c,
                    @floatFromInt(p.x),
                    @floatFromInt(p.y),
                    @floatFromInt(p.w),
                    @floatFromInt(p.h),
                    g_ov,
                );
                ui_paint.showText(
                    c,
                    @floatFromInt(p.x + rows_mod.tile_pad_x),
                    @floatFromInt(p.y + rows_mod.tile_title_y),
                    tg.label,
                    13,
                    500,
                    t.text_r,
                    t.text_g,
                    t.text_b,
                    0.90,
                );
                const g = tileToggleGeom(tg.style, p);
                drawToggle(c, g.x, g.y, g.w, g.h, self.getBool(tg.field), .m);
            },
            .info => |txt| {
                ui_paint.showText(
                    c,
                    @floatFromInt(p.x + common.card_pad),
                    @floatFromInt(p.y + 27),
                    txt,
                    13,
                    400,
                    t.text_r,
                    t.text_g,
                    t.text_b,
                    0.7,
                );
            },
            .button => |bt| {
                const bh: i32 = 36;
                const bw = @max(140, ui_paint.textWidthPx(c, bt.label, 13, 600) + 40);
                const bx = p.x + common.card_pad;
                const by = p.y + @divTrunc(p.h - bh, 2);
                const hov = common.pointInRect(self.pointer_x, self.pointer_ly, .{ .x = bx, .y = by, .w = bw, .h = bh });
                ui_paint.glassBox(
                    c,
                    @floatFromInt(bx),
                    @floatFromInt(by),
                    @floatFromInt(bw),
                    @floatFromInt(bh),
                    10,
                    t.acc_r,
                    t.acc_g,
                    t.acc_b,
                    if (hov) 0.30 else 0.20,
                );
                ui_paint.showText(
                    c,
                    @floatFromInt(bx + 20),
                    @floatFromInt(by + 23),
                    bt.label,
                    13,
                    600,
                    t.acc_r,
                    t.acc_g,
                    t.acc_b,
                    0.95,
                );
            },
            .widget_board => {
                // Layout-space panel rect for the drag math (motion runs
                // between paints, so the last paint's geometry is the truth).
                self.widget_board_box = .{ .x = p.x, .y = p.y, .w = p.w, .h = p.h };
                ui_widgets.paintWidgetBoard(
                    c,
                    p.x,
                    p.y,
                    p.w,
                    self.boardLists(self.active_tab),
                    self.settings.widget_states,
                    if (self.active_tab == app_mod.TabId.dock) self.settings.dock_island_widgets else null,
                    self.pointer_x,
                    self.pointer_ly,
                    &acc,
                    self.widget_drag,
                );
            },
            .toolbar => |tb| {
                ui_widgets.paintToolbar(c, p.x, p.y, tb.buttons, self.pointer_x, self.pointer_ly, &acc);
            },
            .canvas => {
                const st = self.mon orelse return;
                const box = ui_widgets.canvasBoxRect(p.x, p.y, p.w, p.h);
                self.canvas_box = box;
                // Centre the arrangement the first time the canvas box
                // is known, and again whenever it changes size. Without this
                // the outputs sit pinned to the top-left corner of the board.
                if (!st.layout_ready) {
                    st.zoom = 1.0;
                    mon_tab.centerCanvasView(st, box.w, box.h);
                    st.layout_ready = true;
                    st.geom_w = box.w;
                    st.geom_h = box.h;
                } else if (box.w != st.geom_w or box.h != st.geom_h) {
                    st.geom_w = box.w;
                    st.geom_h = box.h;
                    mon_tab.centerCanvasView(st, box.w, box.h);
                }
                ui_widgets.paintCanvas(
                    c,
                    p.x,
                    p.y,
                    p.w,
                    p.h,
                    st,
                    self.pointer_x,
                    self.pointer_ly,
                    &acc,
                );
            },
            .pills => |pl| {
                const sel: i32 = if (self.mon) |st|
                    if (st.outputs_len == 0) -1 else @intCast(@min(st.selected, st.outputs_len - 1))
                else
                    -1;
                ui_widgets.paintPills(
                    c,
                    p.x,
                    p.y,
                    pl.pills,
                    sel,
                    self.pointer_x,
                    self.pointer_ly,
                    &acc,
                );
            },
            .anim => |an| {
                // Hyprland animation entry: label + `speed, curve[, style]`
                // info + switch + 3-dot editor menu. Text baselines match;
                // the switch and dots centre in the 60px toggle-pitch row.
                const yf: f64 = @floatFromInt(p.y);
                const ei: usize = an.entry;
                const meta: hyprland_data.AnimEntry = if (ei < hyprland_data.k_anim_entries.len)
                    hyprland_data.k_anim_entries[ei]
                else
                    .{ .name = "?", .label = "?", .styles = "" };
                const en = hyprland_data.animEnabled(meta.name);
                const inherited = hyprland_data.animIsInherited(meta.name);
                ui_paint.showText(
                    c,
                    @floatFromInt(p.x + common.card_pad),
                    yf + 22,
                    meta.label,
                    14,
                    500,
                    t.text_r,
                    t.text_g,
                    t.text_b,
                    if (en) 0.93 else 0.46,
                );
                var info_buf: [128]u8 = undefined;
                const info: []const u8 = if (inherited)
                    "Inherited (3.0, default)"
                else blk: {
                    const speed = hyprland_data.animSpeed(meta.name);
                    const curve = hyprland_data.animCurve(meta.name);
                    const style = hyprland_data.animStyle(meta.name);
                    break :blk if (style.len > 0)
                        std.fmt.bufPrint(&info_buf, "{d:.1}, {s}, {s}", .{ speed, curve, style }) catch ""
                    else
                        std.fmt.bufPrint(&info_buf, "{d:.1}, {s}", .{ speed, curve }) catch "";
                };
                if (info.len > 0) ui_paint.showText(
                    c,
                    @floatFromInt(p.x + common.card_pad),
                    yf + 42,
                    info,
                    11,
                    400,
                    t.text_r,
                    t.text_g,
                    t.text_b,
                    if (!en) 0.20 else if (inherited) 0.40 else 0.50,
                );
                const tg_x: i32 = p.x + p.w - common.card_pad - 40 - 34;
                drawToggle(c, tg_x, p.y + @divTrunc(rows_mod.anim_row_h - 24, 2), 40, 24, en, .l);
                const dot_x: f64 = @floatFromInt(p.x + p.w - (common.card_pad + 12));
                const dot_cy: f64 = yf + @as(f64, @floatFromInt(rows_mod.anim_row_h)) * 0.5;
                cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, 0.40);
                cairo_arc(c, dot_x, dot_cy - 7.0, 1.8, 0, std.math.pi * 2.0);
                cairo_fill(c);
                cairo_arc(c, dot_x, dot_cy, 1.8, 0, std.math.pi * 2.0);
                cairo_fill(c);
                cairo_arc(c, dot_x, dot_cy + 7.0, 1.8, 0, std.math.pi * 2.0);
                cairo_fill(c);
            },
        }
    }

    pub fn paintPopup(self: *Content, c: ?*cairo.cairo_t) void {
        const cr = c orelse return;
        const pop = self.open_combo orelse return;
        // Re-anchored to the live row every frame, which is what keeps the
        // menu stuck to its own box while the page scrolls underneath. A row
        // that has scrolled out of the visible band dismisses the menu rather
        // than leaving it hovering over the child-tab bar.
        const r = self.comboPopupRect(pop.combo) orelse {
            self.open_combo = null;
            return;
        };
        const t = common.Theme;
        ui_paint.glassBox(
            cr,
            @floatFromInt(r.x),
            @floatFromInt(r.y),
            @floatFromInt(r.w),
            @floatFromInt(r.h),
            10,
            t.bg_r * 0.25,
            t.bg_g * 0.25,
            t.bg_b * 0.25,
            0.97,
        );
        const cur = self.comboIndex(pop.combo.field, pop.combo.options);
        for (pop.combo.options, 0..) |_, i| {
            const ry = r.y + 4 + @as(i32, @intCast(i)) * common.settings_dd_row_h;
            const hov = common.pointInRect(self.pointer_x, self.pointer_y, .{
                .x = r.x,
                .y = ry,
                .w = r.w,
                .h = common.settings_dd_row_h,
            });
            if (i == cur or hov) {
                ui_paint.glassBox(
                    cr,
                    @floatFromInt(r.x + 4),
                    @floatFromInt(ry),
                    @floatFromInt(r.w - 8),
                    @floatFromInt(common.settings_dd_row_h),
                    6,
                    t.acc_r,
                    t.acc_g,
                    t.acc_b,
                    if (i == cur) 0.22 else 0.12,
                );
            }
            // Application icon, when the row names one (default apps): 18px
            // centred in the 26px row, text indented past it. A row whose
            // icon does not resolve falls back to the generic "apps" glyph,
            // matching the C++ picker.
            var tx = r.x + 14;
            if (comboIcon(self, pop.combo, i)) |ic| {
                blitIcon(cr, ic, @floatFromInt(r.x + 12), @floatFromInt(ry + 4), 18);
                tx = r.x + 36;
            } else if (pop.combo.icons.len > i) {
                ui_paint.glyph(cr, @floatFromInt(r.x + 21), @floatFromInt(ry + 13), 16, "apps", t.text_r, t.text_g, t.text_b, 0.7);
                tx = r.x + 36;
            }
            // Long names are clipped to the row (as the closed pill clips to
            // its own box) so nothing paints over the popup edge.
            cairo_save(cr);
            cairo.cairo_rectangle(
                cr,
                @floatFromInt(r.x + 8),
                @floatFromInt(ry + 1),
                @as(f64, @floatFromInt(r.w)) - 16.0,
                @as(f64, @floatFromInt(common.settings_dd_row_h)) - 2.0,
            );
            cairo_clip(cr);
            ui_paint.showText(
                cr,
                @floatFromInt(tx),
                @floatFromInt(ry + 18),
                comboLabel(pop.combo, i),
                12,
                if (i == cur) 600 else 400,
                t.text_r,
                t.text_g,
                t.text_b,
                if (i == cur) 0.95 else 0.8,
            );
            cairo_restore(cr);
        }
    }
};

/// Display string for option `i` (combo label overrides when provided).
fn comboLabel(cb: rows_mod.ComboRow, i: usize) []const u8 {
    if (cb.labels.len > 0 and i < cb.labels.len) return cb.labels[i];
    if (i < cb.options.len) return cb.options[i];
    return "";
}

/// The themed icon for option `i` of a combo, or null when the row carries
/// no icon name (other tabs), the name does not resolve, or the default-apps
/// page is not up. Borrowed pixels: valid until the next page rebuild.
fn comboIcon(self: *const Content, cb: rows_mod.ComboRow, i: usize) ?*const icon_cache.Owned {
    if (i >= cb.icons.len) return null;
    const dp = self.dapps orelse return null;
    return dp.iconFor(cb.icons[i]);
}

fn dragActive(d: ?Drag, f: fields.Field) bool {
    const dg = d orelse return false;
    return dg.field == f;
}

const Track = struct { x: i32, y: i32, w: i32, h: i32 };

/// Tabs painted with the Hyprland section-card helpers
/// Hyprland itself plus Launcher, whose M3 tab
/// reuses `hyprland_paint_slider_card` / `hyprland_paint_toggle_card` /
/// `hyprland_paint_row_divider` verbatim (labels 13-14px/500, value pills,
/// text@0.08 dividers on every row after the first).
fn isHyprStyle(tab: i32) bool {
    return hyprland_tab.isSectionTab(tab) or tab == app_mod.TabId.launcher;
}

/// Slider track geometry: near the bottom of the 68px band.
fn sliderTrack(p: PlacedRow) Track {
    const x = p.card_x + common.card_pad;
    const w = p.card_w - 2 * common.card_pad;
    // Rail center at rowY+58 — the same band the dock appearance tile
    // uses (tileTrack dock), so the generic row reads with the tile's
    // breathing room: label/desc stack at +26/+42, rail below it.
    const y = p.y + p.h - 14;
    return .{ .x = x, .y = y, .w = w, .h = 8 };
}

/// Hyprland slider track: the m3::Slider box is
/// (cardX+pad, rowY+40-10, cardW-2*pad, 36), so the 4px rail centers at
/// rowY+48 — 8px above the generic track. Hit math uses the same box.
fn hyprSliderTrack(p: PlacedRow) Track {
    const x = p.card_x + common.card_pad;
    const w = p.card_w - 2 * common.card_pad;
    const y = p.y + 44;
    return .{ .x = x, .y = y, .w = w, .h = 8 };
}

/// Appearance-tile slider track. Dock draws `settings_slider` with its box at
/// (trY-10, h36) → track center at cardY+58; panel/taskbar use the m3 M-size
/// box at (trY, h28) → center at cardY+64. The Appearance rail category's
/// Opacity and Color pages draw their tiles with the same `settings_slider`
/// box as the dock (trY = cardY + kSliderY), so those tabs ride the dock
/// geometry too.
fn tileTrack(p: PlacedRow, tab: i32) Track {
    const dy: i32 = if (tab == 0 or
        tab == app_mod.TabId.appearance_opacity or
        tab == app_mod.TabId.appearance_color) 54 else 60;
    return .{
        .x = p.x + rows_mod.tile_pad_x,
        .y = p.y + dy,
        .w = p.w - 2 * rows_mod.tile_pad_x,
        .h = 8,
    };
}

/// Toggle switch rect inside an appearance tile: dock's wide 52x26 switch
/// sits on the title band (`settings_toggle` with cy_card = cardY-24);
/// panel/taskbar center the standard 40x24 switch.
fn tileToggleGeom(style: rows_mod.TileToggleStyle, p: PlacedRow) struct { x: i32, y: i32, w: i32, h: i32 } {
    return switch (style) {
        .title_band => .{ .x = p.x + p.w - 52 - common.spacing_xl, .y = p.y + 9, .w = 52, .h = 26 },
        .centered => .{ .x = p.x + p.w - 20 - common.toggle_w, .y = p.y + (rows_mod.tile_h - common.toggle_h) / 2, .w = common.toggle_w, .h = common.toggle_h },
    };
}

const PillStyle = struct { weight: c_uint, right: i32 };

/// Dock uses the shared `draw_value_pill` (Inter 500, right kCardPad = 16);
/// panel/taskbar their local `drawValuePill` (Inter 400, right kPad = 20).
fn pillStyle(tab: i32) PillStyle {
    return if (tab == 0) .{ .weight = 500, .right = 16 } else .{ .weight = 400, .right = 20 };
}

/// `draw_value_pill` — 11px value chip top-right of an appearance tile.
/// Box: Text@0.08, pill radius, pad 8/3; text Text@0.60; vertical center is
/// cardY + 28 in both the dock and panel/taskbar variants.
fn valuePill(c: anytype, card_x: i32, card_y: i32, card_w: i32, text: []const u8, st: PillStyle) void {
    if (text.len == 0) return;
    const t = common.Theme;
    const pad_x: i32 = 8;
    const pad_y: i32 = 3;
    const sz = ui_paint.textSizePx(c, text, 11, st.weight);
    const pill_w = sz.w + 2 * pad_x;
    const pill_h = sz.h + 2 * pad_y;
    const pill_x = card_x + card_w - st.right - pill_w;
    const pill_y = card_y + 28 - @divTrunc(sz.h, 2) - pad_y;
    ui_paint.glassBox(
        c,
        @floatFromInt(pill_x),
        @floatFromInt(pill_y),
        @floatFromInt(pill_w),
        @floatFromInt(pill_h),
        @divTrunc(pill_h, 2),
        t.text_r,
        t.text_g,
        t.text_b,
        0.08,
    );
    ui_paint.showText(
        c,
        @floatFromInt(pill_x + pad_x),
        @floatFromInt(pill_y + pad_y + sz.h - 2),
        text,
        11,
        st.weight,
        t.text_r,
        t.text_g,
        t.text_b,
        0.60,
    );
}

/// Half a Size::M thumb: the rail the
/// thumb center travels on is inset by this on each side, in paint and in
/// value math alike.
const kRailInset: i32 = 10;

/// Slider paint: 4px round-cap rails, solid accent thumb (10% bigger
/// while dragged), stop dot at the rail end. No center dot — the thumb
/// is a plain accent disc. `thumb_r` is the resting radius: 10 for the
/// dock-tile / Hyprland m3 Size::M look, 8 for generic rows where the
/// compact 16px knob keeps desc text and the row divider clear.
fn drawSlider(c: anytype, tr: Track, v: i32, min: i32, max: i32, active: bool, thumb_r: f64) void {
    const t = common.Theme;
    const tl: f64 = @as(f64, @floatFromInt(tr.x + kRailInset));
    const tw: f64 = @as(f64, @floatFromInt(@max(0, tr.w - 2 * kRailInset)));
    const ty: f64 = @as(f64, @floatFromInt(tr.y)) + 4.0;
    const span: f64 = @max(1.0, @as(f64, @floatFromInt(max - min)));
    const norm = @max(0.0, @min(1.0, @as(f64, @floatFromInt(v - min)) / span));
    const tc = tl + norm * tw;
    cairo.cairo_set_line_cap(c, cairo.CAIRO_LINE_CAP_ROUND);
    // Inactive rail.
    cairo_set_source_rgba(c, t.bg_r, t.bg_g, t.bg_b, 0.35);
    cairo.cairo_set_line_width(c, 4.0);
    cairo.cairo_move_to(c, tl, ty);
    cairo.cairo_line_to(c, tl + tw, ty);
    cairo.cairo_stroke(c);
    // Active rail.
    if (tc > tl + 0.5) {
        cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 1.0);
        cairo.cairo_set_line_width(c, 4.0);
        cairo.cairo_move_to(c, tl, ty);
        cairo.cairo_line_to(c, tc, ty);
        cairo.cairo_stroke(c);
    }
    // Stop indicator at the rail end.
    cairo_set_source_rgba(c, t.bg_r, t.bg_g, t.bg_b, 0.6);
    cairo.cairo_arc(c, tl + tw, ty, 2.0, 0, std.math.pi * 2.0);
    cairo.cairo_fill(c);
    // Thumb: solid accent disc.
    cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 1.0);
    cairo.cairo_arc(c, tc, ty, thumb_r + @as(f64, if (active) 1.0 else 0.0), 0, std.math.pi * 2.0);
    cairo.cairo_fill(c);
}

/// `m3::Toggle` paint. Classic rows use Size::L (40x24, thumb 20);
/// appearance tiles center Size::M (32x20, thumb 16) in their slot. On is
/// a flat accent track with a white knob; off is a surface track at half
/// strength with a 2px outline stroke and an outline-colored knob.
pub const ToggleSize = enum { m, l };
fn drawToggle(c: anytype, x: i32, y: i32, w: i32, h: i32, on: bool, size: ToggleSize) void {
    const t = common.Theme;
    const dims: struct { w: f64, h: f64, d: f64 } = switch (size) {
        .m => .{ .w = 32.0, .h = 20.0, .d = 16.0 },
        .l => .{ .w = 40.0, .h = 24.0, .d = 20.0 },
    };
    const tlx = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(w)) - dims.w) * 0.5;
    const tly = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(h)) - dims.h) * 0.5;
    const hr = dims.d * 0.5;
    const hx = if (on) tlx + dims.w - hr else tlx + hr;
    const hy = tly + dims.h * 0.5;
    // Track: flat fill.
    roundRectPath(c, tlx, tly, dims.w, dims.h, dims.h * 0.5);
    if (on) {
        cairo_set_source_rgba(c, t.acc_r, t.acc_g, t.acc_b, 1.0);
    } else {
        cairo_set_source_rgba(c, t.bg_r, t.bg_g, t.bg_b, 0.5);
    }
    cairo_fill(c);
    // Track outline when off.
    if (!on) {
        roundRectPath(c, tlx + 1.0, tly + 1.0, dims.w - 2.0, dims.h - 2.0, dims.h * 0.5 - 1.0);
        cairo_set_line_width(c, 2.0);
        cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 1.0);
        cairo_stroke(c);
    }
    // Knob.
    if (on) {
        cairo_set_source_rgba(c, 1, 1, 1, 1.0);
    } else {
        cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 1.0);
    }
    cairo_arc(c, hx, hy, hr, 0, std.math.pi * 2.0);
    cairo_fill(c);
}

/// `eh::ui::Dropdown` closed state: 200x28, outline, value, chevron.
/// `icon` is the resolved themed icon of the selected option; `icon_fallback`
/// says the row set carries icons at all (the generic "apps" glyph then marks
/// an option whose own icon did not resolve, as in the C++ picker).
fn drawCombo(
    c: anytype,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    text: []const u8,
    hovered: bool,
    icon: ?*const icon_cache.Owned,
    icon_fallback: bool,
) void {
    const t = common.Theme;
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    ui_paint.glassBox(
        c,
        xf,
        yf,
        @floatFromInt(w),
        @floatFromInt(h),
        8,
        1,
        1,
        1,
        if (hovered) 0.12 else 0.05,
    );
    cairo_save(c);
    roundRectPath(c, xf + 0.5, yf + 0.5, @as(f64, @floatFromInt(w)) - 1.0, @as(f64, @floatFromInt(h)) - 1.0, 7.5);
    cairo_set_line_width(c, 1.0);
    cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, if (hovered) 0.9 else 0.55);
    cairo_stroke(c);
    cairo_restore(c);
    const text_x: f64 = blk: {
        if (icon) |ic| {
            blitIcon(c, ic, xf + 8, yf + @as(f64, @floatFromInt(h)) - 8.0 - 16.0, 16);
            break :blk xf + 30;
        }
        if (icon_fallback) {
            ui_paint.glyph(c, xf + 16, yf + @as(f64, @floatFromInt(h)) * 0.5, 16, "apps", t.text_r, t.text_g, t.text_b, 0.7);
            break :blk xf + 30;
        }
        break :blk xf + 12;
    };
    cairo_save(c);
    cairo_rectangle(c, xf + 8, yf + 2, @as(f64, @floatFromInt(w)) - 34, @as(f64, @floatFromInt(h)) - 4);
    cairo_clip(c);
    ui_paint.showText(c, text_x, yf + @as(f64, @floatFromInt(h)) - 7.0, text, 12, 400, t.text_r, t.text_g, t.text_b, 0.9);
    cairo_restore(c);
    ui_paint.glyph(
        c,
        xf + @as(f64, @floatFromInt(w)) - 14.0,
        yf + @as(f64, @floatFromInt(h)) * 0.5,
        16,
        "expand_more",
        t.text_r,
        t.text_g,
        t.text_b,
        0.7,
    );
}

fn roundRectPath(c: anytype, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    ui_paint.roundRect(c, x, y, w, h, r);
}

/// Blit cached icon pixels (cairo ARGB32) into a `size`-sized square at
/// (x, y), aspect-preserved and centred. The pixels are borrowed from the
/// icon cache (or the owning page), never freed here.
fn blitIcon(c: anytype, icon: *const icon_cache.Owned, x: f64, y: f64, size: f64) void {
    if (icon.pixels.len == 0 or icon.w <= 0 or icon.h <= 0) return;
    const avail = @max(4.0, size);
    const s = avail / @as(f64, @floatFromInt(@max(1, @max(icon.w, icon.h))));
    const tw: i32 = @max(1, @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(icon.w)) * s))));
    const th: i32 = @max(1, @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(icon.h)) * s))));
    const tmp = cairo.cairo_image_surface_create_for_data(
        @constCast(icon.pixels.ptr),
        cairo.CAIRO_FORMAT_ARGB32,
        icon.w,
        icon.h,
        icon.w * 4,
    );
    defer cairo.cairo_surface_destroy(tmp);
    if (cairo.cairo_surface_status(tmp) != cairo.CAIRO_STATUS_SUCCESS) return;
    cairo_save(c);
    cairo.cairo_translate(c, x + (@as(f64, @floatFromInt(@max(icon.w, icon.h))) - @as(f64, @floatFromInt(icon.w))) * s * 0.5, y + (@as(f64, @floatFromInt(@max(icon.w, icon.h))) - @as(f64, @floatFromInt(icon.h))) * s * 0.5);
    cairo.cairo_scale(c, @as(f64, @floatFromInt(tw)) / @as(f64, @floatFromInt(icon.w)), @as(f64, @floatFromInt(th)) / @as(f64, @floatFromInt(icon.h)));
    cairo.cairo_set_source_surface(c, tmp, 0, 0);
    cairo.cairo_paint(c);
    cairo_restore(c);
}

const cairo_save = cairo.cairo_save;
const cairo_restore = cairo.cairo_restore;
const cairo_rectangle = cairo.cairo_rectangle;
const cairo_clip = cairo.cairo_clip;
const cairo_translate = cairo.cairo_translate;
const cairo_set_source_rgba = cairo.cairo_set_source_rgba;
const cairo_set_line_width = cairo.cairo_set_line_width;
const cairo_move_to = cairo.cairo_move_to;
const cairo_line_to = cairo.cairo_line_to;
const cairo_stroke = cairo.cairo_stroke;
const cairo_fill = cairo.cairo_fill;
const cairo_arc = cairo.cairo_arc;

test "settings-ui-content: place mirrors the card tables" {
    const t = std.testing;
    var out: [max_placed]PlacedRow = undefined;
    var total: i32 = 0;
    const n = place(0, 0, 292, 592, common.child_content_top, &out, &total, 0);
    try t.expect(n > 5);
    try t.expectEqual(rows_mod.contentHeight(0, 0), total);
    // First row is the first card's first band (no header rows any more).
    try t.expect(out[0].row == .toggle);
    // Cards are inset by 8px from the content edges.
    try t.expectEqual(@as(i32, 300), out[0].card_x);
    try t.expectEqual(@as(i32, 576), out[0].card_w);
    // Rows are strictly increasing.
    var i: usize = 1;
    while (i < n) : (i += 1) {
        try t.expect(out[i].y >= out[i - 1].y);
    }
    // Appearance page: slider tiles on the 2-col grid.
    const n2 = place(0, 2, 292, 592, common.child_content_top, &out, &total, 0);
    var found_slider = false;
    for (out[0..n2]) |p| {
        if (p.row == .tile_slider) {
            const tr = tileTrack(p, 0);
            try t.expect(tr.x >= p.x);
            try t.expect(tr.x + tr.w <= p.x + p.w);
            found_slider = true;
        }
    }
    try t.expect(found_slider);
    // Grid geometry: first tile at y0+26, 92px tall, centered 68% column.
    try t.expectEqual(common.child_content_top + rows_mod.grid_top, out[0].y);
    try t.expectEqual(rows_mod.tile_h, out[0].h);
    const col_w: i32 = @divTrunc(592 * 68, 100);
    try t.expectEqual(@divTrunc(col_w - rows_mod.tile_gap, 2), out[0].w);
    try t.expectEqual(292 + @divTrunc(592 - col_w, 2), out[0].x);
    // 14 tiles -> 7 rows of exact scroll height.
    try t.expectEqual(@as(usize, 14), n2);
    try t.expectEqual(rows_mod.grid_top + 7 * (rows_mod.tile_h + rows_mod.tile_gap) - rows_mod.tile_gap + rows_mod.grid_bottom, total);
    try t.expectEqual(total, rows_mod.contentHeight(0, 2));
}

test "settings-ui-content: sub tabs switch pages and reset scroll" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var content = Content{ .settings = &s };
    content.relayout();
    const first_ptr = content.placed[0].row.toggle.field;
    content.scroll_px = 400;
    try t.expect(content.applyHit(.{ .sub_tab = 1 }, 0));
    try t.expectEqual(@as(i32, 1), content.activeSub());
    try t.expectEqual(@as(i32, 0), content.scroll_px);
    // Widgets page is a different first row than Settings.
    try t.expect(content.placed[0].row == .toggle);
    try t.expect(content.placed[0].row.toggle.field != first_ptr or content.placed_len > 0);
    // Clicking the same sub tab is a no-op.
    try t.expect(!content.applyHit(.{ .sub_tab = 1 }, 0));
}

test "settings-ui-content: appearance pages split opacity and color" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var content = Content{ .settings = &s };
    // General is the top card alone — no grid tiles.
    content.active_tab = app_mod.TabId.appearance;
    content.relayout();
    try t.expectEqual(@as(usize, 1), content.cards().len);
    try t.expectEqual(@as(usize, 4), content.placed_len);
    // Opacity starts on master + Advanced and swaps in the per-surface
    // grid on the next relayout once the page's own switch is on.
    content.active_tab = app_mod.TabId.appearance_opacity;
    content.relayout();
    const cards = content.cards();
    try t.expectEqual(@as(usize, 1), cards.len);
    try t.expectEqual(@as(i32, 2), cards[0].rows.len);
    try t.expectEqual(@as(usize, 2), content.placed_len);
    s.overlay_opacity_advanced = true;
    content.relayout();
    const adv = content.cards();
    try t.expectEqual(@as(i32, 17), adv[0].rows.len);
    try t.expectEqual(@as(usize, 17), content.placed_len);
    var saw_switch = false;
    var saw_widget = false;
    for (content.placed[0..content.placed_len]) |p| {
        switch (p.row) {
            .tile_toggle => |tg| {
                if (tg.field == fields.Field.overlay_opacity_advanced) saw_switch = true;
            },
            .tile_slider => |sl| {
                if (sl.field == fields.Field.overlay_opacity_widget_card_pct) saw_widget = true;
            },
            else => {},
        }
    }
    try t.expect(saw_switch);
    try t.expect(saw_widget);
    // Color keeps its own four tiles.
    s.overlay_opacity_advanced = false;
    content.active_tab = app_mod.TabId.appearance_color;
    content.relayout();
    try t.expectEqual(@as(usize, 1), content.cards().len);
    try t.expectEqual(@as(usize, 4), content.placed_len);
}

test "settings-ui-content: hits mutate settings" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var content = Content{ .settings = &s };
    content.relayout();
    const before = s.dock_show_dock;
    var hit_i: ?usize = null;
    for (content.placed[0..content.placed_len], 0..) |p, i| {
        if (p.row == .toggle) {
            hit_i = i;
            break;
        }
    }
    const p = content.placed[hit_i.?];
    const mid_x: f64 = @floatFromInt(p.x + p.w - common.card_pad - 20);
    const mid_y: f64 = @floatFromInt(p.y + @divTrunc(p.h, 2));
    const h = content.hitTest(mid_x, mid_y);
    try t.expect(h == .toggle);
    try t.expect(content.applyHit(h, mid_x));
    try t.expect(s.dock_show_dock != before);
    // Off the right edge of a toggle row: nothing.
    const miss = content.hitTest(10, mid_y);
    try t.expect(miss == .none);
    // Widget board hits are window-routed: hit-test resolves them from the
    // live settings lists, and `applyHit` leaves them for `Win.onButton`.
    const seed_left = try t.allocator.alloc([]const u8, 2);
    defer t.allocator.free(seed_left);
    seed_left[0] = "clock";
    seed_left[1] = "media";
    s.dock_left_widgets = seed_left;
    content.sub_for[0] = 1;
    content.relayout();
    const wb_i = for (content.placed[0..content.placed_len], 0..) |q, i| {
        if (q.row == .widget_board) break i;
    } else null;
    try t.expect(wb_i != null);
    const wb = content.placed[wb_i.?];
    const lists = content.boardLists(0);
    try t.expectEqual(@as(usize, 2), lists[0].len);
    const tr = ui_widgets.toggleRect(ui_widgets.cardRect(wb.x, wb.y, wb.w, 0, 0));
    const wh = content.hitTest(@floatFromInt(tr.x + 4), @floatFromInt(tr.y + 4));
    try t.expect(wh == .widget_toggle);
    try t.expect(!content.applyHit(wh, 0));
    // Add / remove zones resolve on the same board (window-space == layout
    // space here: the scroll offset is zero).
    const add = ui_widgets.widgetAddRect(wb.x, wb.y, wb.w, 0, 2);
    const wh_add = content.hitTest(@floatFromInt(add.x + 4), @floatFromInt(add.y + 4));
    try t.expect(wh_add == .widget_add);
    try t.expectEqual(@as(usize, 0), wh_add.widget_add);
    const rr = ui_widgets.removeRect(ui_widgets.cardRect(wb.x, wb.y, wb.w, 0, 0));
    const wh_rm = content.hitTest(@floatFromInt(rr.x + 4), @floatFromInt(rr.y + 4));
    try t.expect(wh_rm == .widget_remove);
}

test "settings-ui-content: widget drag arm/motion/commit" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var s = app_mod.Settings{};
    s.dock_left_widgets = try alloc.dupe([]const u8, &.{ "clock", "media", "weather" });
    // NOTE: plain dupes, not duped strings — the test only reads them.
    s.dock_center_widgets = try alloc.dupe([]const u8, &.{"workspaces"});
    var content = Content{ .settings = &s };
    content.sub_for[0] = 1;
    content.relayout();
    const wb_i = for (content.placed[0..content.placed_len], 0..) |q, i| {
        if (q.row == .widget_board) break i;
    } else null;
    try t.expect(wb_i != null);
    const wb = content.placed[wb_i.?];
    // Mirror paint: motion resolves against the last paint's board box.
    content.widget_board_box = .{ .x = wb.x, .y = wb.y, .w = wb.w, .h = wb.h };
    // Grip press on the first card arms a drag.
    const g0 = ui_widgets.dragHandleRect(ui_widgets.cardRect(wb.x, wb.y, wb.w, 0, 0));
    const gx: f64 = @floatFromInt(g0.x + 4);
    const gy: f64 = @floatFromInt(g0.y + 4);
    content.setPointer(gx, gy);
    const hd = content.hitTest(gx, gy);
    try t.expect(hd == .widget_drag);
    content.widgetDragArm(hd.widget_drag);
    try t.expect(content.widget_drag.active);
    try t.expect(!content.widget_drag.dragging);
    try t.expectEqualStrings("clock", content.widget_drag.id);
    // Below the slop threshold: still armed, and release commits nothing.
    content.setPointer(gx + 2, gy + 2);
    try t.expect(content.widgetDragMotion());
    try t.expect(!content.widget_drag.dragging);
    try t.expect(content.takeWidgetDragCommit() == null);
    // Re-arm and drag below the second card's midpoint: reorder down one.
    content.setPointer(gx, gy);
    content.widgetDragArm(hd.widget_drag);
    const c1 = ui_widgets.cardRect(wb.x, wb.y, wb.w, 0, 1);
    content.setPointer(gx, @as(f64, @floatFromInt(c1.y)) + 27.0 + 1.0);
    try t.expect(content.widgetDragMotion());
    try t.expect(content.widget_drag.dragging);
    try t.expectEqual(@as(usize, 0), content.widget_drag.target_col);
    try t.expectEqual(@as(usize, 1), content.widget_drag.insert_before);
    const mc = content.takeWidgetDragCommit();
    try t.expect(mc != null);
    try t.expect(widget_lists.moveItem(&s, alloc, .dock, mc.?.src_col, mc.?.src_idx, mc.?.dst_col, mc.?.insert_before));
    try t.expectEqualStrings("media", s.dock_left_widgets[0]);
    try t.expectEqualStrings("clock", s.dock_left_widgets[1]);
    try t.expectEqualStrings("weather", s.dock_left_widgets[2]);
    // Across to CENTER: drop over the top half of the workspaces card.
    // The press must start on a grip: hit it, arm, then move across.
    const wc = ui_widgets.cardRect(wb.x, wb.y, wb.w, 1, 0);
    const g1 = ui_widgets.dragHandleRect(ui_widgets.cardRect(wb.x, wb.y, wb.w, 0, 0));
    content.setPointer(@floatFromInt(g1.x + 4), @floatFromInt(g1.y + 4));
    const hd2 = content.hitTest(@floatFromInt(g1.x + 4), @floatFromInt(g1.y + 4));
    try t.expect(hd2 == .widget_drag);
    content.widgetDragArm(hd2.widget_drag);
    content.setPointer(@as(f64, @floatFromInt(wc.x)) + 4.0, @as(f64, @floatFromInt(wc.y)) + 10.0);
    try t.expect(content.widgetDragMotion());
    try t.expectEqual(@as(usize, 1), content.widget_drag.target_col);
    try t.expectEqual(@as(usize, 0), content.widget_drag.insert_before);
    const mc2 = content.takeWidgetDragCommit();
    try t.expect(mc2 != null);
    try t.expect(widget_lists.moveItem(&s, alloc, .dock, mc2.?.src_col, mc2.?.src_idx, mc2.?.dst_col, mc2.?.insert_before));
    try t.expectEqual(@as(usize, 2), s.dock_left_widgets.len);
    try t.expectEqualStrings("media", s.dock_center_widgets[0]);
    try t.expectEqualStrings("workspaces", s.dock_center_widgets[1]);
}

test "settings-ui-content: combo popups track their row through the scroll" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var content = Content{ .settings = &s };
    content.relayout();

    // Find a placed combo row anywhere on the current page.
    var cb: ?rows_mod.ComboRow = null;
    for (content.placed[0..content.placed_len]) |p| {
        if (p.row == .combo) {
            cb = p.row.combo;
            break;
        }
    }
    const combo = cb orelse return error.SkipZigTest;

    content.scroll_px = 0;
    content.openComboFor(combo);
    const unscrolled = content.open_combo.?;

    // The rect is derived, so it follows a scroll without being re-opened —
    // that is what keeps the menu glued to its own box while the page moves.
    content.scroll_px = 120;
    const tracked = content.comboPopupRect(combo).?;
    try t.expectEqual(unscrolled.x, tracked.x);
    try t.expectEqual(unscrolled.h, tracked.h);
    try t.expectEqual(unscrolled.y - 120, tracked.y);

    // Scrolling and then opening agrees with opening and then scrolling.
    content.openComboFor(combo);
    try t.expectEqual(tracked.y, content.open_combo.?.y);

    // Scrolled clear past the row, there is nothing left to anchor to.
    content.scroll_px = content.total_h + content.win_h;
    try t.expect(content.comboPopupRect(combo) == null);
}

test "settings-ui-content: a Hyprland section page places, hits and dispatches" {
    const t = std.testing;
    var s = app_mod.Settings{};
    var content = Content{ .settings = &s };
    const app = app_mod.AppState{};
    content.win_w = app_mod.window_width;
    content.win_h = app_mod.window_height;
    content.content_x = app_mod.AppState.contentX();
    content.content_w = app.contentW();
    content.active_tab = 64; // General
    content.relayout();

    // The header band sits above the cards: layout top = content_top + header,
    // clip stays at the content top.
    try t.expectEqual(hyprland_page.pageTop(), content.y0());
    try t.expectEqual(content_top, content.clipTop());
    try t.expect(content.placed_len > 0);
    for (content.placed[0..content.placed_len]) |p| {
        try t.expect(p.y >= content.y0());
    }
    // The 68% column: cards inset from a centered column, not the edges.
    try t.expect(content.placed[0].card_x > content.content_x + 8);

    // The layout combo opens, its options are pickable, and the pick marks
    // the live config dirty (the release handler commits it). The combo row
    // sits below the fold — the popup anchors only to rows inside the scroll
    // band — so scroll it into view first, like a user would.
    const row = for (content.placed[0..content.placed_len]) |p| {
        if (p.row == .combo) break p;
    } else return error.SkipZigTest;
    const combo = row.row.combo;
    content.scroll_px = @min(content.scrollMax(), @max(0, row.y - content.clipTop() - 24));
    const cx: f64 = @floatFromInt(row.x + row.w - common.card_pad - hyprland_tab.layout_combo_w / 2);
    const cy: f64 = @floatFromInt(row.y - content.scroll_px + @divTrunc(row.h, 2));
    try t.expect(content.hitTest(cx, cy) == .combo);
    try t.expect(content.applyHit(.{ .combo = combo }, cx));
    const pop = content.open_combo orelse return error.TestUnexpectedResult;
    try t.expectEqual(row.x + row.w - common.card_pad - hyprland_tab.layout_combo_w, pop.x);
    // Pick "master" (row 1): the pick point is inside its row.
    const pick_y: f64 = @floatFromInt(pop.y + 4 + common.settings_dd_row_h);
    const pick = content.hitTest(pop.x, pick_y);
    try t.expect(pick == .combo_pick);
    try t.expect(content.selectComboIndex(1));
    // `.hypr_general_layout` maps 1:1 onto `hyprland_data`'s UI slot.
    const layout_slot = fields.Field.hypr_general_layout.hyprSlot().?;
    try t.expectEqualStrings("master", hyprland_data.getStr(layout_slot));
    try t.expect(hyprland_data.isDirty());
    hyprland_data.load(std.testing.io); // reset global state for other tests

    // Toggles flip the live config value the same way.
    const tr = for (content.placed[0..content.placed_len]) |p| {
        if (p.row == .toggle) break p;
    } else return error.SkipZigTest;
    const tg = tr.row.toggle;
    const before = content.getBool(tg.field);
    try t.expect(content.applyHit(.{ .toggle = tg.field }, 0));
    try t.expectEqual(!before, content.getBool(tg.field));
    hyprland_data.load(std.testing.io);
}
