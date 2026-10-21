const std = @import("std");
const fields = @import("fields.zig");
const sound_tab = @import("sound_tab.zig");
const templates_tab = @import("templates_tab.zig");
const time_tab = @import("time_tab.zig");

// Declarative content rows — one table per tab describing its cards and rows. Each
// tab describes its cards/rows once, here; the generic renderer in
// ui_content.zig paints them with the shared-helper geometry and routes
// input back through `fields`. Paint, hit-test and scroll height all derive
// from the same table, so they can never disagree.
//
// Card geometry matches the section cards:
// cat label at cardTop+21, subtitle at +38, first band at +52 with a 60px
// pitch (sliders 68), divider lines between bands, 24px bottom pad.

pub const Field = fields.Field;

pub const ToggleRow = struct {
    label: []const u8,
    desc: []const u8 = "",
    field: Field,
};

pub const SliderRow = struct {
    label: []const u8,
    desc: []const u8 = "",
    field: Field,
    min: i32,
    max: i32,
    unit: []const u8 = "px",
    /// How the value is rendered next to the label. The monitors form uses
    /// (`"%.2f"`, `"%.4f"`,
    /// `"%d nits"`, `"%g×"`); `.int` keeps the plain `"<v> <unit>"` every
    /// other tab uses.
    fmt: SliderFmt = .int,
};

pub const SliderFmt = enum {
    /// `"<value> <unit>"` (px / % / K / min).
    int,
    /// `"%.2f"` — SDR brightness / saturation.
    div100,
    /// `"%.4f"` — min-luminance pairs.
    div10000,
    /// `"%d nits"` — max-luminance pairs.
    nits,
    /// `"%g×"` — the monitors scale slider.
    scale,
};

pub const ComboRow = struct {
    label: []const u8,
    desc: []const u8 = "",
    field: Field,
    options: []const []const u8,
    /// Optional display strings (dropdowns show labels while storing
    /// values, e.g. renderer vulkan -> "Vulkan (GPU)"); falls back to
    /// `options` when empty.
    labels: []const []const u8 = &.{},
    /// Optional themed icon names parallel to `options` (the default-apps
    /// dropdown shows each application's icon). Empty = no icons; a "" entry
    /// means "no icon for this option" and draws the generic apps glyph.
    icons: []const []const u8 = &.{},
};

pub const ButtonRow = struct {
    label: []const u8,
    glyph: []const u8 = "",
};

/// Toggle inside an appearance tile (92px grid card). The dock draws the
/// wide 52x26 switch on the title band; panel/taskbar draw the standard
/// 40x24 switch vertically centered.
pub const TileToggleStyle = enum { title_band, centered };

pub const TileToggleRow = struct {
    label: []const u8,
    field: Field,
    style: TileToggleStyle = .centered,
};

/// Three-column widget board (Dock/Panel/Taskbar "Widgets" child tab) —
/// LEFT / CENTER / RIGHT column titles with widget cards + Add buttons.
pub const WidgetBoard = struct {
    left: []const []const u8 = &.{},
    center: []const []const u8 = &.{},
    right: []const []const u8 = &.{},
};

/// Toolbar button strip (monitors tab: Refresh / Portals / Apply / Revert).
pub const ToolbarRow = struct {
    buttons: []const []const u8,
};

/// Animation entry row (Hyprland Animations child tab). The label and the
/// `speed, curve, style` info line come from `hyprland_data` by name, the
/// switch toggles the entry, and the 3-dot button opens the entry editor
/// (`hyprland_anim_popup`). `entry` indexes `hyprland_data.k_anim_entries`.
pub const AnimRow = struct {
    entry: u8,
};

/// Arrange canvas (monitors tab). Payload-free: the live page paints the
/// outputs straight from `monitors_state.State` (see `ui_content.paintRow`);
/// the payload-free row exists so the canvas keeps the same declarative
/// placement/height every other row gets.
pub const CanvasRow = struct {};

/// Output selection pills (monitors tab).
pub const PillsRow = struct {
    pills: []const []const u8,
};

pub const Row = union(enum) {
    toggle: ToggleRow,
    slider: SliderRow,
    combo: ComboRow,
    /// Appearance-grid slider tile (Dock/Panel/Taskbar Appearance child tab).
    tile_slider: SliderRow,
    /// Appearance-grid toggle tile.
    tile_toggle: TileToggleRow,
    /// Read-only description line (44px row).
    info: []const u8,
    /// Action button rendered as a filled pill (visual affordance).
    button: ButtonRow,
    widget_board: WidgetBoard,
    toolbar: ToolbarRow,
    canvas: CanvasRow,
    pills: PillsRow,
    /// Hyprland animation entry (toggle + info + 3-dot editor menu).
    anim: AnimRow,
};

pub const Card = struct {
    /// Small dim category label above the rows (settings_cat_label +21).
    title: []const u8 = "",
    /// 11px 0.46 description line under the title (+38).
    subtitle: []const u8 = "",
    rows: []const Row = &.{},
    /// 2-column tile grid: each row
    /// is its own 92px card laid out col = i%2, row = i/2 in a centered 68%
    /// column. Grid cards carry no title band of their own.
    grid: bool = false,
};

pub const rows_panels = @import("rows_panels.zig");
pub const rows_display = @import("rows_display.zig");
pub const rows_appearance = @import("rows_appearance.zig");
pub const rows_system = @import("rows_system.zig");
pub const rows_wall_net = @import("rows_wall_net.zig");
pub const rows_compositor = @import("rows_compositor.zig");
pub const rows_hyprland = @import("rows_hyprland.zig");
pub const subtabs = @import("subtabs.zig");

/// The card list for a tab's active child tab; `&.{}` when no page exists.
pub fn cardsFor(tab: i32, sub: i32) []const Card {
    return switch (tab) {
        0 => switch (sub) { // Dock
            1 => &rows_panels.dock_widgets,
            2 => &rows_panels.dock_appearance,
            else => &rows_panels.dock_settings,
        },
        11 => switch (sub) { // Taskbar
            1 => &rows_panels.taskbar_widgets,
            2 => &rows_panels.taskbar_appearance,
            else => &rows_panels.taskbar_settings,
        },
        9 => switch (sub) { // Launcher: Launcher | Workspaces | Overview
            1 => &rows_panels.launcher_workspaces,
            2 => &rows_panels.launcher_overview,
            else => &rows_panels.launcher_main,
        },
        29 => &rows_panels.desktop,
        27 => &rows_panels.desktop_widgets,
        7 => &rows_display.monitors,
        // Appearance rail category: General (tab 2) | Opacity (79) | Color
        // (80) | Templates (tab 3). The Opacity list here is the
        // Advanced-off overlay grid; the window swaps in `opacity_advanced`
        // from `Content.cards` (see ui_content).
        2 => &rows_appearance.general,
        79 => &rows_appearance.opacity,
        80 => &rows_appearance.color,
        // Templates (tab 3) is a dedicated self-painted page
        // (`templates_tab.zig`): its grouped roster is not a card list.
        3 => &.{},
        45 => &rows_display.themes,
        50 => &rows_display.color_themes,
        44 => &rows_display.icons,
        19 => &rows_display.nightlight,
        5 => &rows_system.notifications,
        10 => &rows_system.default_apps,
        30 => &rows_system.time,
        31 => &rows_system.keyboard,
        47 => &rows_system.bluetooth,
        32 => if (sub == 1) &rows_system.power_performance else &rows_system.power,
        46 => &rows_system.accounts,
        48 => &rows_system.autostart,
        51 => &rows_system.updater,
        // Sound rail: Devices (8) | Bluetooth Audio (81) | Apps (82) |
        // Engine (83) are four self-painted live pages (sound_tab.zig).
        // `ui_content` dispatches to the page before `cardsFor`, so the
        // generic card list here stays empty.
        sound_tab.devices_tab, sound_tab.bt_audio_tab, sound_tab.apps_tab, sound_tab.engine_tab => &.{},
        6 => &rows_wall_net.wallpaper,
        34 => &rows_wall_net.bing,
        17 => &rows_wall_net.wifi,
        18 => &rows_wall_net.wired,
        28 => &rows_wall_net.vpn,
        60 => &rows_wall_net.taskflip,
        61 => &rows_wall_net.workspaces,
        62 => &rows_wall_net.dashboard,
        63 => &rows_wall_net.live_wallpaper,
        // Hyprland sections — one rail sub page each (order General …
        // Quirks); the in-page child strip is gone.
        64 => &rows_hyprland.general,
        65 => &rows_hyprland.decoration,
        66 => &rows_hyprland.input,
        67 => &rows_hyprland.binds,
        68 => &rows_hyprland.dwindle,
        69 => &rows_hyprland.master,
        70 => &rows_hyprland.scrolling,
        71 => &rows_hyprland.animations,
        72 => &rows_hyprland.misc,
        73 => &rows_hyprland.render,
        74 => &rows_hyprland.cursor,
        75 => &rows_hyprland.group,
        76 => &rows_hyprland.xwayland,
        77 => &rows_hyprland.opengl,
        78 => &rows_hyprland.quirks,
        20 => &rows_compositor.mango_decoration,
        21 => &rows_compositor.mango_colors,
        22 => &rows_compositor.mango_animations,
        23 => &rows_compositor.mango_keybinds,
        24 => &rows_compositor.mango_layout,
        25 => &rows_compositor.mango_input,
        26 => &rows_compositor.mango_misc,
        else => &.{},
    };
}

/// Row heights in px — shared by paint, hit-test and the scroll clamp.
/// Toggle/combo bands use kDockVisRowPitch (60); sliders kSliderRowH (68).
pub const toggle_row_h: i32 = 60;
pub const slider_row_h: i32 = 68;
pub const combo_row_h: i32 = 60;
pub const info_row_h: i32 = 44;
pub const button_row_h: i32 = 60;
pub const toolbar_h: i32 = 48;
/// Hyprland animation rows with `kAnimRowH =
/// 48`, but nothing uses it for layout: the category groups declare every
/// entry as a toggle (`beginGroup(..., entry_count, 0)`), so rows sit at the
/// 60px toggle pitch — and `hyprland_paint_anim_card`/`hitDot` paint and hit
/// them there too. This is that pitch.
pub const anim_row_h: i32 = 60;
pub const pills_h: i32 = 44;
pub const canvas_h: i32 = 340;
pub const card_title_band: i32 = 52;
pub const card_pad_y: i32 = 24;
pub const card_gap: i32 = 12;
/// Appearance grid tiles (top margin 72 / card 92 / gap 12): the first
/// tile lands at y0 + 26 (absolute 88 = kContentTop 16 + kTopMargin 72), the
/// pitch is 104, and the page keeps 32px under the last row — matching
/// `kTopMargin + rows*(kCardH+kGap) + 20` from kContentTop exactly.
pub const tile_h: i32 = 92;
pub const tile_gap: i32 = 12;
pub const grid_top: i32 = 26;
pub const grid_bottom: i32 = 32;
pub const tile_pad_x: i32 = 20; // kPad
pub const tile_title_y: i32 = 28; // kTitleY
pub const tile_slider_y: i32 = 50; // kSliderY

pub fn gridCardHeight(n: usize, band: i32) i32 {
    if (n == 0) return 0;
    // `n` is the tile count; the grid lays them out two per row. `band` is
    // the titled-card band above the tiles (0 for the bare dock/panel/taskbar
    // grids, `card_title_band` when the grid title is painted — the
    // Appearance page's "Color adjustment" grid).
    const rows_n: i32 = @intCast((n + 1) / 2);
    return band + grid_top + rows_n * (tile_h + tile_gap) - tile_gap + grid_bottom;
}

/// Top band of a card: titled cards reserve 52px for the label + subtitle,
/// untitled grids/toggle cards start immediately. Shared by `cardHeightFor`,
/// `placeCards` and the painter so height and placement can never disagree.
pub fn topBand(c: Card) i32 {
    if (c.title.len > 0 or c.subtitle.len > 0) return card_title_band;
    return 0;
}
/// Widget board: column titles + n*(54+8) cards + Add-widget button + reset.
pub const widget_card_h: i32 = 54;
pub const widget_card_gap: i32 = 8;
pub const widget_add_h: i32 = 38;
pub const widget_reset_gap: i32 = 10;
pub const widget_reset_h: i32 = 38;

pub fn widgetBoardHeight(w: WidgetBoard) i32 {
    return widgetBoardHeightFor(maxBoardList(w));
}

/// Height for a live (data-driven) board with `max_n` the tallest column.
/// `place` passes the settings lists' max; 0 is never passed (callers fall
/// back to the static row — see `rowHeightFor`).
pub fn widgetBoardHeightFor(max_n: usize) i32 {
    // Column headers (26) + n cards on a 62px pitch + Add-widget button +
    // gap + reset-to-defaults row.
    return 26 + @as(i32, @intCast(max_n)) * (widget_card_h + widget_card_gap) +
        widget_add_h + widget_reset_gap + widget_reset_h;
}

fn maxBoardList(w: WidgetBoard) usize {
    return @max(w.left.len, @max(w.center.len, w.right.len));
}

pub fn rowHeight(r: Row) i32 {
    return rowHeightFor(r, 0);
}

/// Row height with a live widget-board max: pass the settings lists' tallest
/// column (from `ui_widgets.maxColLen`) when the page shows a data-driven
/// board, else 0 to size from the row's own static lists.
pub fn rowHeightFor(r: Row, board_max: usize) i32 {
    return switch (r) {
        .toggle => toggle_row_h,
        .slider => slider_row_h,
        .combo => combo_row_h,
        .tile_slider, .tile_toggle => tile_h,
        .info => info_row_h,
        .button => button_row_h,
        .widget_board => |w| if (board_max > 0) widgetBoardHeightFor(board_max) else widgetBoardHeight(w),
        .toolbar => toolbar_h,
        .canvas => canvas_h,
        .pills => pills_h,
        .anim => anim_row_h,
    };
}

pub fn cardHeight(c: Card) i32 {
    return cardHeightFor(c, 0);
}

pub fn cardHeightFor(c: Card, board_max: usize) i32 {
    // Grid cards size as a whole (2-col tile grid), not as stacked bands;
    // a titled grid keeps its label band above the tiles.
    if (c.grid) return gridCardHeight(c.rows.len, topBand(c));
    // Titled cards reserve the 52px label+subtitle band and 24px bottom pad;
    // untitled cards (embedded-widget toggles) start immediately with 16px.
    const titled = topBand(c) > 0;
    var h: i32 = if (titled) card_title_band else 0;
    for (c.rows) |r| h += rowHeightFor(r, board_max);
    return h + (if (titled) card_pad_y else 16);
}

/// Total scrollable content height for a tab's child page.
pub fn contentHeight(tab: i32, sub: i32) i32 {
    return contentHeightFor(tab, sub, 0);
}

pub fn contentHeightFor(tab: i32, sub: i32, board_max: usize) i32 {
    return contentHeightOf(cardsFor(tab, sub), board_max);
}

/// Height of an explicit card list — the live monitors page builds its cards
/// into `Content.page`, so its scroll height cannot go through `cardsFor`.
pub fn contentHeightOf(cards: []const Card, board_max: usize) i32 {
    var h: i32 = 0;
    for (cards, 0..) |c, i| {
        h += cardHeightFor(c, board_max);
        if (i + 1 < cards.len) h += card_gap;
    }
    return h;
}

test "settings-rows: every sidebar tab resolves a page" {
    const t = std.testing;
    const app_mod = @import("app.zig");
    for (app_mod.sidebar_categories) |cat| {
        if (cat.subs.len == 0) {
            try t.expect(cardsFor(cat.id, 0).len > 0);
            continue;
        }
        for (cat.subs) |s| {
            // Sound's four pages are self-painted live pages (sound_tab.zig),
            // not generic card lists — skip them here; ui_content has the
            // dedicated coverage.
            if (sound_tab.isSoundTab(s.tab_id)) continue;
            // The Time pages (System Time | World Clock) are self-painted
            // too (time_tab.zig); their generic card lists are intentionally
            // empty.
            if (time_tab.ownsTab(s.tab_id)) continue;
            // The Templates page is self-painted too (templates_tab.zig);
            // its generic card list is intentionally empty.
            if (templates_tab.ownsTab(s.tab_id)) continue;
            try t.expect(cardsFor(s.tab_id, 0).len > 0);
        }
    }
    try t.expectEqual(@as(usize, 0), cardsFor(999, 0).len);
}

test "settings-rows: child tabs have their own pages" {
    const t = std.testing;
    // Dock: Settings / Widgets / Appearance are three distinct pages.
    try t.expect(cardsFor(0, 0).ptr != cardsFor(0, 1).ptr);
    try t.expect(cardsFor(0, 1).ptr != cardsFor(0, 2).ptr);
    try t.expect(cardsFor(0, 0).len > 0);
    try t.expect(cardsFor(0, 1).len > 0);
    try t.expect(cardsFor(0, 2).len > 0);
    // Taskbar likewise.
    try t.expect(cardsFor(11, 2).ptr != cardsFor(11, 0).ptr);
    // Appearance / power child pages.
    // Appearance is a rail category with four pages (General | Opacity |
    // Color | Templates); Templates is self-painted, so its list is empty.
    try t.expect(cardsFor(3, 0).ptr != cardsFor(2, 0).ptr);
    try t.expect(cardsFor(79, 0).ptr != cardsFor(80, 0).ptr);
    try t.expectEqual(@as(usize, 0), cardsFor(3, 0).len);
    try t.expect(cardsFor(79, 0).len > 0);
    try t.expect(cardsFor(80, 0).len > 0);
    try t.expect(cardsFor(32, 1).ptr != cardsFor(32, 0).ptr);
    // Launcher: Launcher | Workspaces | Overview are three distinct pages.
    try t.expect(cardsFor(9, 0).ptr != cardsFor(9, 1).ptr);
    try t.expect(cardsFor(9, 1).ptr != cardsFor(9, 2).ptr);
    try t.expect(cardsFor(9, 0).len == 3);
    try t.expectEqualStrings("Layout", cardsFor(9, 0)[0].title);
    try t.expectEqualStrings("Grid", cardsFor(9, 0)[1].title);
    try t.expectEqualStrings("Appearance", cardsFor(9, 0)[2].title);
    try t.expectEqualStrings("Workspaces", cardsFor(9, 1)[0].title);
    try t.expectEqualStrings("Overview", cardsFor(9, 2)[0].title);
    // Dock settings card matches the Visibility & behavior card.
    const c = cardsFor(0, 0)[0];
    try t.expectEqualStrings("Visibility & behavior", c.title);
    try t.expect(c.rows.len == 8);
    try t.expect(contentHeight(0, 0) > contentHeight(0, 1) - 400);
}

test "settings-rows: heights and content total" {
    const t = std.testing;
    const cards = cardsFor(0, 0);
    try t.expect(cards.len > 0);
    var sum: i32 = 0;
    for (cards, 0..) |c, i| {
        sum += cardHeight(c);
        if (i + 1 < cards.len) sum += card_gap;
    }
    try t.expectEqual(sum, contentHeight(0, 0));
    try t.expect(contentHeight(0, 0) > 400);
    // The Time pages are self-painted (time_tab.zig): their card lists are
    // empty and the scroll extent comes from `Page.totalHeight`.
    try t.expectEqual(@as(i32, 0), contentHeight(30, 0));
    try t.expectEqual(@as(i32, 0), contentHeight(84, 0));
}
