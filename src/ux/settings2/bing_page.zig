//! The Bing Wallpaper page — design B shell.
//!
//! The tab's full port lives in `bing_tab.zig` (its six cards, the worker
//! service and the year/month archive dropdowns, all lifted from the
//! original settings tree). This file carries the design-B page identity:
//! the sidebar sub under the Wallpaper category, and the tri-line header
//! (`page_header.zig`) the cards paint below — same page shape as the
//! Hyprland sections above it:
//!
//!     WALLPAPER
//!     Bing Wallpaper
//!     Layout preview only.
//!
//! The header scrolls with the page, so `bing_tab.zig` starts its card
//! stack at `cardTop()` and measures its scroll extent from the content
//! band, not its own first card.
//!
//! Sidebar id: this page owns tab 34. Tab 16 is MangoWM's rail category —
//! sharing it alongside Bing was what made clicking Bing Wallpaper land on
//! the MangoWM page list; the move to 34 gives the MangoWM rail entry its
//! id back for good.

const std = @import("std");
const common = @import("common.zig");
const page_header = @import("page_header.zig");

/// Sidebar tab id — the Wallpaper category's second sub.
pub const tab_id: i32 = 34;

/// `.ey` line of the header: the rail category the page belongs to,
/// exactly as the design's category table names it.
pub const eyebrow = "Wallpaper";

/// `h1` of the header — the list-column page name.
pub const title = "Bing Wallpaper";

/// Design-B `s0` default subtitle.
pub const subtitle = "Layout preview only.";

/// First card top of the page: below the design-B header, inside the same
/// card column every other card page uses (content left edge + 8).
pub fn cardTop() i32 {
    return common.content_top + page_header.h;
}

/// Left edge the header aligns with — the card column's left edge, so the
/// tri-line sits flush above the General card like on every headed page.
pub fn headerX(content_x: i32) i32 {
    return content_x + 8;
}

/// The page header. Painted first by the page, inside the scroll clip, so
/// it scrolls away with the cards like the design's `.in` block.
pub fn paintHeader(c: anytype, content_x: i32, content_w: i32) void {
    _ = content_w;
    page_header.paint(c, @floatFromInt(headerX(content_x)), common.content_top, eyebrow, title, subtitle);
}

test "settings2-bing-page: identity and header geometry" {
    const t = std.testing;
    // Tab 34 belongs to Bing alone; MangoWM's rail stays on 16.
    try t.expectEqual(@as(i32, 34), tab_id);
    try t.expectEqual(page_header.contentStart(), cardTop());
    // Header aligns with the card column: content inset + 8, as every card
    // page's card column is.
    try t.expectEqual(@as(i32, 300), headerX(292));
}
