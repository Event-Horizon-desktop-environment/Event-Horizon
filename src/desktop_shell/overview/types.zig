//! Shared value types for the workspace overview.
//!
//! Plain data only: rectangles, the computed card strip, the app grid, the
//! quick-select strip, and the palette. Layout math lives in `layout.zig`
//! and `grid.zig`; hit testing in `pick.zig`; pixels in `paint.zig`.

pub const Axis = enum { vertical, horizontal };

pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,

    pub fn contains(self: Rect, mx: f64, my: f64) bool {
        return mx >= self.x and mx <= self.x + self.w and
            my >= self.y and my <= self.y + self.h;
    }
};

pub const Grid = struct {
    start_x: f64 = 0,
    start_y: f64 = 0,
    cell_w: f64 = 0,
    cell_h: f64 = 0,
    icon_size: f64 = 0,
    font_size: f64 = 0,
    cols: i32 = 0,
    rows: i32 = 0,
    scroll_max: f64 = 0,
};

pub const Strip = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    thumb_w: f64 = 0,
    thumb_h: f64 = 0,
    gap: f64 = 8,
    pad_x: f64 = 16,
    pad_y: f64 = 12,
    radius: f64 = 8,
    horizontal: bool = true,
    add: Rect = .{},
    /// How far the column/row may scroll when the thumbs outgrow it.
    /// Zero means everything fits and all positions stay centered.
    scroll_max: f64 = 0,
};

pub const Layout = struct {
    axis: Axis = .vertical,
    w: f64 = 0,
    h: f64 = 0,
    ui: f64 = 1,
    scale: f64 = 0.5,
    card_w: f64 = 0,
    card_h: f64 = 0,
    gap: f64 = 24,
    pitch: f64 = 0,
    center_x: f64 = 0,
    center_y: f64 = 0,
    close_sz: f64 = 34,
    search_y: f64 = 20,
    search_w: f64 = 420,
    search_h: f64 = 40,
    apps_btn: Rect = .{},
    grid: Grid = .{},
    modal: Grid = .{},
    strip: Strip = .{},
};

/// Window geometry for one tile: absolute pixels (`x/y/w/h`) when the
/// backend reports them, or monitor-normalized (`nx/ny/nw/nh`) when it does.
/// Either pair being zero falls through to the even grid below it.
pub const WinBox = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    nx: f64 = 0,
    ny: f64 = 0,
    nw: f64 = 0,
    nh: f64 = 0,
};

pub const Colors = struct {
    bg: [3]f64 = .{ 0.102, 0.102, 0.125 },
    search_bg: [3]f64 = .{ 0.165, 0.165, 0.196 },
    card_bg: [3]f64 = .{ 0.133, 0.133, 0.157 },
    thumb_bg: [3]f64 = .{ 0.184, 0.184, 0.220 },
    thumb_active: [3]f64 = .{ 0.208, 0.208, 0.247 },
    tile_bg: [3]f64 = .{ 0.145, 0.145, 0.169 },
    tile_title_bg: [3]f64 = .{ 0.122, 0.122, 0.141 },
    close_bg: [3]f64 = .{ 0.235, 0.235, 0.267 },
    accent: [3]f64 = .{ 0.431, 0.620, 1.0 },
    fg: [3]f64 = .{ 0.867, 0.867, 0.878 },
    dim_fg: [3]f64 = .{ 0.627, 0.627, 0.647 },
};

pub const apps_btn_h: f64 = 38.0;
pub const apps_btn_gap: f64 = 10.0;
pub const apps_btn_bottom: f64 = 12.0;
pub const dock_spacing: f64 = 25.0;

/// Sentinel for the strip's add-workspace slot.
pub const strip_add_idx: i32 = -2;

const chrome = @import("../widgets/shared/chrome_colors.zig");

fn mul(v: chrome.Rgb, k: f64) [3]f64 {
    return .{ v.r * k, v.g * k, v.b * k };
}

/// Palette derived from the shell chrome, so a custom theme repaints the
/// overview with it: cards off the panel fill, thumbs off the drawer dim,
/// text and accent straight through.
pub fn themeColors(c: chrome.Chrome) Colors {
    return .{
        .bg = .{ c.panel_fill.r, c.panel_fill.g, c.panel_fill.b },
        .search_bg = .{ c.drawer_dim.r, c.drawer_dim.g, c.drawer_dim.b },
        .card_bg = mul(c.panel_fill, 1.15),
        .thumb_bg = mul(c.drawer_dim, 1.3),
        .thumb_active = .{ c.dock_fill.r, c.dock_fill.g, c.dock_fill.b },
        .tile_bg = .{ c.drawer_dim.r, c.drawer_dim.g, c.drawer_dim.b },
        .tile_title_bg = mul(c.panel_fill, 0.9),
        .close_bg = .{ c.outline.r, c.outline.g, c.outline.b },
        .accent = .{ c.accent.r, c.accent.g, c.accent.b },
        .fg = .{ c.text.r, c.text.g, c.text.b },
        .dim_fg = .{ c.outline.r, c.outline.g, c.outline.b },
    };
}

test "overview-types: rect contains edges" {
    const t = @import("std").testing;
    const r = Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    try t.expect(r.contains(10, 20));
    try t.expect(r.contains(110, 70));
    try t.expect(!r.contains(9.9, 20));
    try t.expect(!r.contains(10, 70.1));
}
