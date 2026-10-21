//! Design-B page header — the tri-line that sits at the top of a page and
//! scrolls with it (`pg()` in event-horizon-settings-designs.html):
//!
//!     HYPRLAND        ← `.ey`  — 12px/600 accent, letter-spaced, uppercase
//!     Binds           ← `h1`   — 28px/600 text
//!     Layout preview only.   ← `.s0` — 14px/400 secondary
//!
//! The settings canvas draws with pango, which has no letter-spacing
//! primitive, so `.ey` is drawn glyph by glyph with a fixed advance added
//! after each character (12px * .04em ≈ extra 1.6px, per the CSS).
//!
//! Pages that show the header start their content at
//! `common.content_top + h`. The header is part of the page flow: it
//! scrolls up and away exactly like the cards under it.

const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");

/// Eyebrow baseline, relative to the page top (`common.content_top`).
pub const eyebrow_baseline: i32 = 20;
/// `h1` baseline, relative to the page top.
pub const title_baseline: i32 = 56;
/// `.s0` baseline, relative to the page top.
pub const subtitle_baseline: i32 = 82;
/// Vertical space the header consumes: the first card, row or tile of a
/// headed page starts at `common.content_top + h`.
pub const h: i32 = 92;
/// The same band without the `.s0` subtitle line (pages that pass an empty
/// subtitle — the Hyprland sections dropped theirs).
pub const h_no_subtitle: i32 = 66;

/// Fixed extra advance between the eyebrow's glyphs (CSS `letter-spacing:
/// .04em` at 12px, rounded up so the tracking reads at pixel scales).
const eyebrow_tracking_px: f64 = 1.6;

/// One `.ey` glyph per call site scratch buffer — HYPRLAND/WALLPAPER fit
/// with room for any category name up to 48 characters.
const eyebrow_buf_len: usize = 48;

/// Uppercase + letter-spaced `.ey` line, accent-colored.
pub fn paintEyebrow(c: anytype, x: f64, baseline_y: f64, text: []const u8) void {
    if (text.len == 0) return;
    const t = common.Theme;
    var upper: [eyebrow_buf_len]u8 = undefined;
    var n: usize = 0;
    for (text) |ch| {
        if (n >= upper.len) break;
        upper[n] = std.ascii.toUpper(ch);
        n += 1;
    }
    var cx = x;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const glyph: []const u8 = upper[i .. i + 1];
        ui_paint.showText(c, cx, baseline_y, glyph, 12, 600, t.acc_r, t.acc_g, t.acc_b, 0.95);
        cx += @as(f64, @floatFromInt(ui_paint.textWidthPx(c, glyph, 12, 600))) + eyebrow_tracking_px;
    }
}

/// The whole tri-line, drawn at design-B metrics. `x` is the left edge the
/// page's cards align with (the 68% column for Hyprland sections, the card
/// column everywhere else).
pub fn paint(
    c: anytype,
    x: f64,
    page_top: i32,
    eyebrow: []const u8,
    title: []const u8,
    subtitle: []const u8,
) void {
    const t = common.Theme;
    const top_f: f64 = @floatFromInt(page_top);
    paintEyebrow(c, x, top_f + @as(f64, @floatFromInt(eyebrow_baseline)), eyebrow);
    ui_paint.showText(
        c,
        x,
        top_f + @as(f64, @floatFromInt(title_baseline)),
        title,
        28,
        600,
        t.text_r,
        t.text_g,
        t.text_b,
        0.95,
    );
    if (subtitle.len > 0) {
        ui_paint.showText(
            c,
            x,
            top_f + @as(f64, @floatFromInt(subtitle_baseline)),
            subtitle,
            14,
            400,
            t.text_r,
            t.text_g,
            t.text_b,
            0.55,
        );
    }
}

test "settings2-page-header: the tri-line occupies a fixed band" {
    const t = std.testing;
    // Baselines are in order under the page top, and cards start below the
    // subtitle with its `.s0` 8px bottom margin.
    try t.expect(eyebrow_baseline < title_baseline);
    try t.expect(title_baseline < subtitle_baseline);
    try t.expect(subtitle_baseline < h);
    // Every category name the app routes through the eyebrow fits the
    // upper-case scratch buffer without truncation.
    const names = [_][]const u8{
        "Panels & UI", "Display",  "Hyprland",     "MangoWM",
        "System",      "Wallpaper", "Network",      "Time",
        "Default Apps", "Accounts", "Updates",
    };
    for (names) |n| {
        try t.expect(n.len <= eyebrow_buf_len);
    }
    // Tracking is a plain f64 constant so the math stays board-stable.
    try t.expect(eyebrow_tracking_px > 0.0);
    // `h` is the one offset pages consume (content_top + h = first card top).
    try t.expectEqual(common.content_top + h, contentStart());
}

/// Where a headed page's cards begin — the formula every consumer applies.
pub fn contentStart() i32 {
    return common.content_top + h;
}

/// The same, for a page that paints no `.s0` line (empty subtitle).
pub fn contentStartNoSubtitle() i32 {
    return common.content_top + h_no_subtitle;
}
