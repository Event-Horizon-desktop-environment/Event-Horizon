//! Painting one dock widget slot: the pill, then whatever the kind needs —
//! a rasterized icon, pango text for the clock, or cairo-drawn dots for the
//! control centre.
//!
//! Only the pieces the Zig shell can
//! back with real data are implemented here; the rest degrade to the same
//! faint placeholder when an icon fails to rasterize.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const text_layout = @import("../../text/layout.zig");
const tokens = @import("../../m3/tokens.zig");
const cairo_helpers = @import("../shared/cairo_helpers.zig");
const widgets = @import("widgets.zig");
const anim = @import("anim.zig");
const svg_icons = @import("../../ux/shared/svg_icons.zig");
const pill_style = @import("../widgets/shared/pill.zig");

pub const IconPx = @import("paint.zig").IconPx;
pub const Kind = widgets.Kind;

/// Clock/weather/body text sizes track the icon.
pub fn clockFontPx(icon_px: f64) f64 {
    return std.math.clamp(icon_px * 0.38, 11.0, 15.0);
}

/// Dot radius and run-indicator gap constants.
/// The dot is a fixed 4 px — it does not scale with the dock. 3 px read as
/// dust under a full-size icon, especially over a busy wallpaper.
const kIndicatorR = 4.0;
const kIndicatorGap = 0.0;

/// Centre of the running-app dot for a slot whose content sits at `y` with
/// height `h` after being lifted by `lift`. Its top edge ends up tangent to
/// the bottom of the icon box.
pub fn indicatorCenterY(y: f64, h: f64, lift: f64) f64 {
    return y - lift + h + kIndicatorGap + kIndicatorR;
}

/// Themed-icon candidates per widget kind, most specific first. The caller
/// should always fall back to the widget token itself afterwards.
pub fn iconCandidates(kind: Kind) []const []const u8 {
    return switch (kind) {
        .settings => &.{ "event-horizon-settings", "preferences-system", "settings" },
        // The Audio Center ships its own art (`event-horizon-audio-center`,
        // installed from `src/resources/icons/audio-center.svg`); the mixer
        // names keep a themed icon on screen when that install is missing.
        .audio_center => &.{ "event-horizon-audio-center", "multimedia-volume-control", "audio-volume-high" },
        .smenu => &.{ "start-here", "view-app-grid", "open-menu", "system-run" },
        .app_drawer => &.{ "view-app-grid", "view-apps", "view-list" },
        .trash => &.{ "user-trash", "user-trash-full", "edit-clear-trash" },
        .overview => &.{ "view-grid", "view-multigrid", "zoom-fit-best" },
        .bluetooth => &.{ "bluetooth-active", "bluetooth", "bluetooth-disabled" },
        .volume_mixer => &.{ "audio-volume-high", "multimedia-volume-control", "preferences-system-sound" },
        .weather => &.{ "weather-few-clouds", "weather-overcast", "weather-clear" },
        .media => &.{ "media-playback-start", "multimedia-player", "audio-x-generic" },
        .workspaces => &.{ "workspace-switcher", "preferences-desktop-workspaces" },
        .control_center => &.{ "preferences-system", "emblem-system", "quick-properties" },
        // Pear is the control center's compact variant (see `implType`), so it
        // draws the same icon.
        .pear_center => &.{ "preferences-system", "emblem-system", "quick-properties" },
        .battery => &.{ "battery", "battery-good", "battery-full" },
        .spotlight => &.{ "system-search", "edit-find" },
        .app_menu => &.{ "open-menu", "view-more", "application-menu" },
        .vpn => &.{ "network-vpn", "preferences-system-network" },
        .clipstack => &.{ "edit-paste", "content-paste" },
        .world_clock => &.{ "preferences-system-time", "clock" },
        .clock => &.{ "preferences-system-time", "clock" },
        // The layout slot paints its own glyph — the running compositor's
        // current layout — and its arm in the strip loop `continue`s before
        // the themed-icon path is ever reached, so there is no candidate name
        // to offer it.
        .layout => &.{},
        // Apps and tray items carry their own icon.
        .app, .tray => &.{},
    };
}

pub const Draw = struct {
    /// Widgets paint a pill behind their content; bare app icons do not.
    pill: bool = false,
    /// Pill fill colour/alpha — a third of the surface fill plus a touch
    /// of accent, scaled by the `slot_pill_opacity` setting.
    pill_rgb: tokens.Rgb = .{ .r = 1.0, .g = 1.0, .b = 1.0 },
    pill_alpha: f64 = 0.06,
    /// Lay the frosted glass layers over the fill the way
    /// `slot_pill_style::paint_glass_layers` does.
    glass: bool = true,
    /// Accent wash for the slot under the pointer.
    hover: bool = false,
    /// Vertical rise of the slot's *content*. The pill and
    /// the glass never move, only what sits inside them.
    lift: f64 = 0.0,
    /// Pointer-down feedback: the content scales to `kPressIconScale` about
    /// its centre, over the white/accent outline.
    press: bool = false,
    /// Running-app dot under the icon box (`Kind::App` and `Kind::Settings`).
    indicator: bool = false,
    /// Focus tint: `rgba(0.4,0.7,1.0,0.95)` instead of the idle
    /// `rgba(1,1,1,0.5)`.
    indicator_active: bool = false,
    /// Icon frame (`[dock] icon_frames`): full-bleed square art is rounded
    /// into the bar's squircle with a lifted edge and a specular rim, the
    /// same corner language every pill speaks. Shaped art (circle logos,
    /// icons with their own margins) is left alone — see `cornersOpaque`.
    frame: bool = false,
    /// Which slot this is — it picks the artwork box in `iconAvail`.
    kind: Kind = .app,
    icon: ?IconPx = null,
    label: ?[]const u8 = null,
    /// Dot-grid count per row for the app-menu slot: `dots = 3` is the
    /// nine-dot launchpad grid a bar falls back to when the distribution
    /// ships no logo we can find. The App menu button otherwise wears the
    /// distro mark, like the smenu/Spotlight/AppDrawer slots. Nothing else in
    /// the strip reaches this path — control centre and pear own their
    /// painters.
    dots: u8 = 0,
    /// Grid colour — palette accent when a palette is driving the bar, plain
    /// white otherwise.
    dot_rgb: tokens.Rgb = .{ .r = 1.0, .g = 1.0, .b = 1.0 },
    /// A Lucide SVG glyph to draw when the slot has no raster icon. The
    /// widget slots that identify themselves by a shape — control centre,
    /// start menu, media — use these instead of falling back to a bare
    /// letter, which is what `assets/UI/LICENSE-lucide.txt` covers.
    /// The value is a *material* glyph name (`tune`, `music_note`), mapped
    /// to its Lucide twin by `ux/shared/svg_icons.zig`.
    lucide: []const u8 = "",
    /// Fallback letter when nothing else could be drawn.
    letter: ?[]const u8 = null,
};

/// The box a slot's artwork is fitted into before being centred in the slot.
/// `icon_size` is the *slot* box (44 px by default); art shrinks inside it,
/// shrinks the art inside it, which is what leaves the visual gap between
/// neighbouring icons:
///
/// - apps and the brand-logo slots (`Settings`, `Spotlight`, `AppDrawer`,
///   `Smenu`, `AppMenu`, `Trash`) use `pad2 = 6.0; avail = icon - pad2 * 2.0`
///   (icon padding rule);
/// - tray art is capped by `maxSide = min(icon * 0.6, icon - 8.0)` so a
///   128 px SNI pixmap does not swallow its cell;
/// - the glyph widgets draw `draw_material_glyph(..., icon * 0.52, ...)`
///   (`glyphPx` in battery, bluetooth, …);
/// - weather clamps to `[13, 18]`, media art to `icon * 0.78`.
pub fn iconAvail(kind: Kind, icon_px: f64) f64 {
    const box = switch (kind) {
        .tray => @min(icon_px * 0.6, icon_px - 8.0),
        .volume_mixer, .vpn, .overview, .bluetooth, .battery => icon_px * 0.52,
        .weather => std.math.clamp(icon_px * 0.42, 13.0, 18.0),
        .media => icon_px * 0.78,
        // 6 px total means 3 px of breathing room per side: 44 px slots
        // used to hand the art only 32 px, which is why icons read
        // undersized in a 68–72 px bar next to their own pills.
        else => icon_px - 6.0,
    };
    // A degenerate dock (`icon_size` clamps to 1) must not hand `blitIcon` a
    // negative box.
    return @max(@as(f64, 4.0), box);
}

/// HSV-to-RGB for the configurable border tint.
pub fn hsvToRgb(h_deg: f64, s: f64, v: f64) tokens.Rgb {
    var h = std.math.mod(f64, h_deg, 360.0) catch 0.0;
    if (h < 0) h += 360.0;
    const hh = h / 60.0;
    const i: u32 = @intFromFloat(hh);
    const f = hh - @as(f64, @floatFromInt(i));
    const p = v * (1.0 - s);
    const q = v * (1.0 - s * f);
    const tv = v * (1.0 - s * (1.0 - f));
    return switch (i % 6) {
        0 => .{ .r = v, .g = tv, .b = p },
        1 => .{ .r = q, .g = v, .b = p },
        2 => .{ .r = p, .g = v, .b = tv },
        3 => .{ .r = p, .g = q, .b = v },
        4 => .{ .r = tv, .g = p, .b = v },
        else => .{ .r = v, .g = p, .b = q },
    };
}

/// The frosted treatment `slot_pill_style::paint_glass_layers` lays over a
/// fill: a milky white wash clipped to the shape, a bottom-weighted rim
/// gradient, and a faint outer glow. `scale` is the caller's opacity base.
pub fn paintGlassLayers(c: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, scale: f64, rad: f64) void {
    const cr = c orelse return;
    // The frosted layers fade with the fill's opacity — but only by its
    // square root. Linear was why a low-opacity pill read as a flat gray
    // sticker: at `slot_pill_opacity = 11` the rim landed at ~1% and
    // vanished, and the highlights are what make the fill glass. 0 still
    // paints nothing and 1 is unchanged.
    const op = @sqrt(@min(@max(scale, 0.0), 1.0));

    // Milky lift — faint white wash so the fill reads frosted, not dark.
    cairo.cairo_save(cr);
    cairo_helpers.roundedRect(cr, x, y, w, h, rad);
    cairo.cairo_clip(cr);
    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.09 * op);
    cairo.cairo_rectangle(cr, x, y, w, h);
    cairo.cairo_fill(cr);
    cairo.cairo_restore(cr);

    // Edge light — inner 1px stroke, soft on top, bright along the bottom.
    cairo.cairo_save(cr);
    const rim = cairo.cairo_pattern_create_linear(0, y, 0, y + h);
    defer cairo.cairo_pattern_destroy(rim);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 0.0, 1.0, 1.0, 1.0, 0.20 * op);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 0.5, 1.0, 1.0, 1.0, 0.04 * op);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 1.0, 1.0, 1.0, 1.0, 0.42 * op);
    cairo.cairo_set_source(cr, rim);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo_helpers.roundedRect(cr, x + 1.0, y + 1.0, @max(1.0, w - 2.0), @max(1.0, h - 2.0), @max(0.0, rad - 1.0));
    cairo.cairo_stroke(cr);
    cairo.cairo_restore(cr);

    // Faint outer glow so the edge lifts off the wallpaper.
    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.10 * op);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo_helpers.roundedRect(cr, x + 0.5, y + 0.5, @max(1.0, w - 1.0), @max(1.0, h - 1.0), rad);
    cairo.cairo_stroke(cr);
}

fn pillRadius(w: f64, h: f64) f64 {
    return @max(2.0, @min(h, w) * 0.22);
}

/// Aspect-preserving blit of a rasterized icon into `x,y,w,h`, centered.
fn blitIcon(c: ?*cairo.cairo_t, icon: IconPx, x: f64, y: f64, w: f64, h: f64) void {
    const cr = c orelse return;
    if (icon.pixels.len == 0 or icon.w <= 0 or icon.h <= 0) return;
    const iw: f64 = @floatFromInt(icon.w);
    const ih: f64 = @floatFromInt(icon.h);
    const scale = @min(w / iw, h / ih);
    const dw = iw * scale;
    const dh = ih * scale;
    const dx = x + (w - dw) * 0.5;
    const dy = y + (h - dh) * 0.5;

    cairo.cairo_save(cr);
    cairo.cairo_translate(cr, dx, dy);
    cairo.cairo_scale(cr, scale, scale);
    const surf = cairo.cairo_image_surface_create_for_data(
        @constCast(icon.pixels.ptr),
        cairo.CAIRO_FORMAT_ARGB32,
        icon.w,
        icon.h,
        icon.w * 4,
    );
    defer cairo.cairo_surface_destroy(surf);
    if (icon.tint) |t| {
        // The raster's alpha masks a solid accent source, so the mark takes the
        // palette's colour while keeping its own shape. Our pixels are
        // already premultiplied ARGB32, so the alpha byte *is* the mask
        // built by hand as a luminance alpha mask.
        cairo.cairo_set_source_rgba(cr, t.r, t.g, t.b, 1.0);
        _ = cairo.cairo_mask_surface(cr, surf, 0.0, 0.0);
    } else {
        cairo.cairo_set_source_surface(cr, surf, 0, 0);
        cairo.cairo_pattern_set_extend(cairo.cairo_get_source(cr), cairo.CAIRO_EXTEND_NONE);
        cairo.cairo_paint(cr);
    }
    cairo.cairo_restore(cr);
}

fn drawLabel(c: ?*cairo.cairo_t, text: []const u8, font_px: f64, x: f64, y: f64, w: f64, h: f64) void {
    const cr = c orelse return;
    var buf: [64]u8 = undefined;
    const fd = std.fmt.bufPrint(&buf, "Inter {d}", .{@as(i32, @intFromFloat(font_px))}) catch return;
    var l = text_layout.Layout.createForCairo(cr);
    defer l.destroy();
    l.setFont(fd);
    l.setText(text);
    const size = l.pixelSize();
    const tx = x + (w - @as(f64, @floatFromInt(size.w))) * 0.5;
    const ty = y + (h - @as(f64, @floatFromInt(size.h))) * 0.5;
    cairo.cairo_set_source_rgba(cr, tokens.Tokens.text.r, tokens.Tokens.text.g, tokens.Tokens.text.b, 0.95);
    cairo.cairo_move_to(cr, tx, ty);
    l.show(cr);
}

/// The dot grid for `Kind::AppMenu`:
/// `count` × `count` dots at an `icon / 6.8` pitch and `icon * 0.06` radius,
/// centred on the slot and filled solid. The colour is the palette accent
/// when one is driving the bar and plain white otherwise (`dockBarMatugen`),
/// never a static token — there is no pill behind this slot, so the grid is
/// the whole face.
fn drawDots(c: ?*cairo.cairo_t, count: u8, x: f64, y: f64, w: f64, h: f64, icon_px: f64, rgb: tokens.Rgb) void {
    const cr = c orelse return;
    const n: i32 = @intCast(@max(count, 1));
    const half: i32 = @divTrunc(n - 1, 2);
    const pitch = icon_px / 6.8;
    const r_dot = icon_px * 0.06;
    const gx = x + w * 0.5;
    const gy = y + h * 0.5;
    cairo.cairo_set_source_rgba(cr, rgb.r, rgb.g, rgb.b, 1.0);
    var ry: i32 = -half;
    while (ry <= half) : (ry += 1) {
        var col: i32 = -half;
        while (col <= half) : (col += 1) {
            cairo.cairo_arc(
                cr,
                gx + @as(f64, @floatFromInt(col)) * pitch,
                gy + @as(f64, @floatFromInt(ry)) * pitch,
                r_dot,
                0,
                6.283185307179586,
            );
            cairo.cairo_fill(cr);
        }
    }
}

/// Whether the artwork is full-bleed to its own corners — a square tile —
/// which is what decides if the icon frame should round it. Shaped art
/// (circle logos, icons with their own margins) leaves transparent corners
/// and must not be masked: clipping a full-bleed circle to a squircle would
/// shave its sides. Corner probes sit a couple of px in, clear of the
/// antialiased edge of already-rounded art.
fn cornersOpaque(icon: IconPx) bool {
    if (icon.w < 6 or icon.h < 6) return false;
    const w: usize = @intCast(icon.w);
    const h: usize = @intCast(icon.h);
    if (icon.pixels.len < w * h * 4) return false; // malformed raster: draw as-is
    const probes = [_][2]usize{
        .{ 2, 2 },     .{ w - 3, 2 },
        .{ 2, h - 3 }, .{ w - 3, h - 3 },
        .{ 4, 4 },     .{ w - 5, 4 },
        .{ 4, h - 5 }, .{ w - 5, h - 5 },
    };
    for (probes) |pt| {
        const alpha = icon.pixels[(pt[1] * w + pt[0]) * 4 + 3];
        if (alpha > 32) return true;
    }
    return false;
}

/// The running-app dot: a filled circle whose top edge is tangent to the
/// bottom of the icon box (`kDockRunIndicatorGapPx` is 0 and the radius is a
/// fixed 4 px, so it is never scaled with the dock).
fn drawIndicator(c: ?*cairo.cairo_t, cx: f64, cy: f64, active: bool) void {
    const cr = c orelse return;
    const col: [4]f64 = if (active) .{ 0.4, 0.7, 1.0, 0.95 } else .{ 1.0, 1.0, 1.0, 0.5 };
    cairo.cairo_set_source_rgba(cr, col[0], col[1], col[2], col[3]);
    cairo.cairo_arc(cr, cx, cy, kIndicatorR, 0, 6.283185307179586);
    cairo.cairo_fill(cr);
}

/// The white/accent box behind a pressed slot. Drawn *before*
/// the press scale, so the outline itself never shrinks.
fn pressOutline(c: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, icon_px: f64) void {
    const cr = c orelse return;
    const box = @min(icon_px, @min(w, h));
    const bx = x + (w - box) * 0.5;
    const by = y + (h - box) * 0.5;
    cairo_helpers.roundedRect(cr, bx - 2.0, by - 2.0, box + 4.0, box + 4.0, 14.0);
    cairo.cairo_set_source_rgba(cr, 1.00, 1.00, 1.00, 0.12);
    cairo.cairo_fill_preserve(cr);
    cairo.cairo_set_source_rgba(cr, 0.55, 0.80, 1.00, 0.58);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_stroke(cr);
}

/// The shared `slot_pill_style::paint_pill`: the m3 box fill — which lays
/// the drop shadow the pill lifts off the bar with — plus the frosted
/// layers. Used both for a single slot's pill and for the run pill a whole
/// run of pinned (or running) apps sits on.
///
/// This deliberately routes through `desktop_shell/widgets/shared/pill.zig`
/// rather than drawing its own rounded rect: every `paint_*_slot` under
/// `src/desktop_shell/widgets/` (battery, clock, weather, media, workspaces …)
/// already goes there, and a second shape here is what made the pills in one
/// bar disagree with each other — some lifted on a shadow, some pasted flat.
pub fn paintPill(
    c: ?*cairo.cairo_t,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    rgb: tokens.Rgb,
    alpha: f64,
    glass: bool,
) void {
    const cr = c orelse return;
    if (w <= 1.0 or h <= 1.0) return;
    if (glass) {
        pill_style.paintPillColored(cr, x, y, w, h, rgb, alpha);
        return;
    }
    // `paint_pill` always lays the glass. Kept so a
    // caller can opt out of the frosted layers and keep the flat fill.
    const rad = pillRadius(w, h);
    cairo_helpers.roundedRect(cr, x, y, w, h, rad);
    cairo.cairo_set_source_rgba(cr, rgb.r, rgb.g, rgb.b, alpha);
    cairo.cairo_fill(cr);
}

/// Hover overlay — the accent wash with its
/// brighter rim, factored out as a separate
/// lambda the widget arms call *instead of* their content pass.
///
/// That separation matters. The arms that paint their own face (control
/// center, pear, battery, bluetooth, vpn) have no content left for
/// `drawContent` to resolve, so routing their hover through `paintSlot` let
/// it fall through to the placeholder and stamp a 44 x 44 white box over the
/// status pill every time the pointer crossed it.
/// draws, because it only ever calls `hover_overlay()` there.
pub fn paintHoverOverlay(
    c: ?*cairo.cairo_t,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
) void {
    const cr = c orelse return;
    if (w <= 1.0 or h <= 1.0) return;
    const rad = pillRadius(w, h);
    const hs = pill_style.style;
    cairo_helpers.roundedRect(cr, x, y, w, h, rad);
    cairo.cairo_set_source_rgba(cr, hs.hover_accent_r, hs.hover_accent_g, hs.hover_accent_b, 0.18);
    cairo.cairo_fill_preserve(cr);
    cairo.cairo_set_source_rgba(cr, hs.hover_accent_r, hs.hover_accent_g, hs.hover_accent_b, 0.35);
    cairo.cairo_set_line_width(cr, 1.0);
    cairo.cairo_stroke(cr);
}

/// Draws a single widget/app slot into the already-cleared bar.
pub fn paintSlot(
    cr: ?*cairo.cairo_t,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    icon_px: f64,
    d: Draw,
) void {
    const c = cr orelse return;
    if (w <= 1.0 or h <= 1.0) return;

    if (d.pill) {
        paintPill(c, x, y, w, h, d.pill_rgb, d.pill_alpha, d.glass);
    }
    if (d.hover) paintHoverOverlay(c, x, y, w, h);

    // The content rides above the pill: `liftY` first, then the press
    // transform about the icon-box centre.
    const cy = y - d.lift;
    const pcx = x + w * 0.5;
    const pcy = cy + h * 0.5;
    if (d.press) pressOutline(c, x, cy, w, h, icon_px);
    if (d.press) {
        cairo.cairo_save(c);
        cairo.cairo_translate(c, pcx, pcy);
        cairo.cairo_scale(c, anim.kPressIconScale, anim.kPressIconScale);
        cairo.cairo_translate(c, -pcx, -pcy);
    }
    drawContent(c, x, cy, w, h, icon_px, d);
    if (d.press) cairo.cairo_restore(c);

    // Drawn after the restore, so a press never shrinks the dot — but it
    // does follow the lift.
    if (d.indicator) {
        drawIndicator(c, x + w * 0.5, indicatorCenterY(y, h, d.lift), d.indicator_active);
    }
}

fn drawContent(c: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, icon_px: f64, d: Draw) void {
    const cr = c orelse return;
    if (d.dots > 0) {
        drawDots(cr, d.dots, x, y, w, h, icon_px, d.dot_rgb);
        return;
    }
    if (d.label) |txt| {
        if (txt.len > 0) {
            drawLabel(cr, txt, clockFontPx(icon_px), x, y, w, h);
            return;
        }
    }
    if (d.icon) |ic| {
        if (ic.pixels.len > 0) {
            // `iconAvail`, not the raw slot box: art fits into a
            // padded sub-box so 44 px slots keep a visible gap between icons.
            const box = @min(iconAvail(d.kind, icon_px), @min(w, h));
            const bx = x + (w - box) * 0.5;
            const by = y + (h - box) * 0.5;
            if (d.frame and cornersOpaque(ic)) {
                // Icon frame (`[dock] icon_frames`, Tahoe-style): the art
                // runs to its own corners, so round it into the same
                // squircle the pills speak, lift it on a soft shadow and
                // give it a specular rim. Shaped art keeps its silhouette
                // on purpose — a uniform mask would clip a full-bleed
                // circle's sides — so only full-bleed squares are framed.
                const fr = box * 0.2237;
                cairo_helpers.paintSoftShadow(cr, bx, by, box, box, fr, 0.40, box * 0.07, box * 0.12);
                cairo.cairo_save(cr);
                cairo_helpers.pathRoundedRect(cr, bx, by, box, box, fr);
                cairo.cairo_clip(cr);
                blitIcon(cr, ic, bx, by, box, box);
                cairo.cairo_restore(cr);
                const rim = cairo.cairo_pattern_create_linear(0, by, 0, by + box);
                defer cairo.cairo_pattern_destroy(rim);
                cairo.cairo_pattern_add_color_stop_rgba(rim, 0.0, 1.0, 1.0, 1.0, 0.14);
                cairo.cairo_pattern_add_color_stop_rgba(rim, 0.5, 1.0, 1.0, 1.0, 0.02);
                cairo.cairo_pattern_add_color_stop_rgba(rim, 1.0, 1.0, 1.0, 1.0, 0.10);
                cairo.cairo_set_source(cr, rim);
                cairo.cairo_set_line_width(cr, 1.0);
                cairo_helpers.pathRoundedRect(cr, bx + 0.5, by + 0.5, box - 1.0, box - 1.0, @max(0.0, fr - 0.5));
                cairo.cairo_stroke(cr);
                return;
            }
            blitIcon(cr, ic, bx, by, box, box);
            return;
        }
    }
    if (d.lucide.len > 0) {
        // A widget identified by a shape, drawn from the vendored Lucide set:
        // the shell no longer ships or loads the Material Symbols font, so
        // an unmapped name would simply draw nothing.
        const box = @min(iconAvail(d.kind, icon_px), @min(w, h));
        const fg = tokens.Tokens.text;
        if (svg_icons.draw(cr, d.lucide, x + w * 0.5, y + h * 0.5, box, fg.r, fg.g, fg.b, 0.95, false)) return;
    }
    if (d.letter) |ch| {
        if (ch.len > 0) {
            const box = @min(icon_px, @min(w, h));
            const bx = x + (w - box) * 0.5;
            const by = y + (h - box) * 0.5;
            cairo_helpers.roundedRect(cr, bx, by, box, box, 12.0);
            cairo.cairo_set_source_rgba(cr, tokens.Tokens.accent.r, tokens.Tokens.accent.g, tokens.Tokens.accent.b, 0.14);
            cairo.cairo_fill(cr);
            drawLabel(cr, ch, clockFontPx(box), bx, by, box, box);
            return;
        }
    }
    // Nothing resolved: the same faint placeholder.
    const box = @min(icon_px, @min(w, h));
    cairo_helpers.roundedRect(cr, x + (w - box) * 0.5, y + (h - box) * 0.5, box, box, 12.0);
    cairo.cairo_set_source_rgba(cr, 1, 1, 1, 0.06);
    cairo.cairo_fill(cr);
}

test "widgets-paint: artwork is fitted into a padded sub-box of the slot" {
    const t = std.testing;
    // `icon_size = 44` is the *slot*; art fits into `icon - 2*3` so
    // neighbouring icons keep a thin visible gap.
    try t.expectApproxEqAbs(@as(f64, 38.0), iconAvail(.app, 44.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 38.0), iconAvail(.settings, 44.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 38.0), iconAvail(.trash, 44.0), 1e-9);
    // Tray: `min(icon * 0.6, icon - 8)`.
    try t.expectApproxEqAbs(@as(f64, 26.4), iconAvail(.tray, 44.0), 1e-9);
    // Glyph widgets: `draw_material_glyph(..., icon * 0.52, ...)`.
    try t.expectApproxEqAbs(@as(f64, 22.88), iconAvail(.bluetooth, 44.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 22.88), iconAvail(.overview, 44.0), 1e-9);
    // The App menu wears the distro mark like the other logo slots, so its
    // logo takes the full `icon - 12` art box; the nine-dot fallback sizes
    // itself off the raw slot (`drawDots`) and never reads this.
    try t.expectApproxEqAbs(@as(f64, 38.0), iconAvail(.app_menu, 44.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 38.0), iconAvail(.smenu, 44.0), 1e-9);
    // Weather clamps to [13, 18]; media art is 0.78 of the reference.
    try t.expectApproxEqAbs(@as(f64, 18.0), iconAvail(.weather, 44.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 13.0), iconAvail(.weather, 20.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 34.32), iconAvail(.media, 44.0), 1e-9);
    // Never collapses on a tiny dock.
    try t.expect(iconAvail(.app, 8.0) >= 4.0);
}

test "widgets-paint: clock font tracks the icon" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 11.0), clockFontPx(20));
    // 44 * 0.38 = 16.72, clamped into [11, 15].
    try t.expectEqual(@as(f64, 15.0), clockFontPx(44));
    try t.expectEqual(@as(f64, 15.0), clockFontPx(80));
}

test "widgets-paint: icon candidates cover the structural widgets" {
    const t = std.testing;
    for ([_]Kind{ .settings, .trash, .smenu, .bluetooth, .volume_mixer, .overview, .weather }) |k| {
        try t.expect(iconCandidates(k).len > 0);
    }
    try t.expectEqual(@as(usize, 0), iconCandidates(.app).len);
}

test "widgets-paint: the generic pill and the widget pill are byte-identical" {
    const t = std.testing;
    // Two fresh surfaces, the same rect on each: the dock's own path (run
    // pills, settings, overview, volume mixer) on one, the path every
    // `paint_*_slot` under `src/desktop_shell/widgets/` takes on the other.
    // They used to disagree — this one drew a bare rounded rect, those drew
    // the m3 box with its drop shadow — which is what left one bar with two
    // kinds of pill.
    const surf_a = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 80, 60);
    defer cairo.cairo_surface_destroy(surf_a);
    const surf_b = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 80, 60);
    defer cairo.cairo_surface_destroy(surf_b);
    const ca = cairo.cairo_create(surf_a);
    defer cairo.cairo_destroy(ca);
    const cb = cairo.cairo_create(surf_b);
    defer cairo.cairo_destroy(cb);

    const saved = pill_style.style;
    defer pill_style.style = saved;

    const fill = tokens.Rgb{ .r = 0.2, .g = 0.3, .b = 0.4 };
    const alpha = 0.4;
    paintPill(ca, 8, 8, 64, 44, fill, alpha, true);
    pill_style.style.pill_r = fill.r;
    pill_style.style.pill_g = fill.g;
    pill_style.style.pill_b = fill.b;
    pill_style.style.opacity_scale = alpha;
    pill_style.paintPill(cb, 8, 8, 64, 44);

    _ = cairo.cairo_surface_flush(surf_a);
    _ = cairo.cairo_surface_flush(surf_b);
    const da: [*]const u8 = @ptrCast(cairo.cairo_image_surface_get_data(surf_a));
    const db: [*]const u8 = @ptrCast(cairo.cairo_image_surface_get_data(surf_b));
    const stride: usize = @intCast(cairo.cairo_image_surface_get_stride(surf_a));
    const n = stride * @as(usize, @intCast(cairo.cairo_image_surface_get_height(surf_a)));
    try t.expect(std.mem.eql(u8, da[0..n], db[0..n]));

    // And the pill really does sit on the box's drop shadow: the row just
    // under the fill is not clear, so the capsule reads as lifted.
    const alpha_below = da[(53 * stride) + (40 * 4) + 3];
    try t.expect(alpha_below > 0);
}

test "widgets-paint: the hover wash stamps no placeholder box" {
    const t = std.testing;
    // A pure red accent over an opaque black bar, so the middle of the slot
    // can only be tinted by what the hover path actually draws.
    //
    // This is the control-center / pear / battery / bluetooth / vpn bug: those
    // arms paint their own face, so on hover they used to be routed through
    // `paintSlot` with no content at all, and `drawContent` fell through to
    // its placeholder — a 44 x 44 white box at 0.06 stamped over the status
    // pill every time the pointer crossed it.
    // `hover_overlay()` there. The white box would put 15 in the green and
    // blue channels; the wash alone leaves them at zero.
    const saved = pill_style.style;
    defer pill_style.style = saved;
    pill_style.style.hover_accent_r = 1.0;
    pill_style.style.hover_accent_g = 0.0;
    pill_style.style.hover_accent_b = 0.0;

    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 64, 64);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    cairo.cairo_set_source_rgba(cr, 0, 0, 0, 1);
    cairo.cairo_paint(cr);
    paintHoverOverlay(cr, 10, 10, 44, 44);

    _ = cairo.cairo_surface_flush(surf);
    const data: [*]const u8 = @ptrCast(cairo.cairo_image_surface_get_data(surf));
    const stride: usize = @intCast(cairo.cairo_image_surface_get_stride(surf));
    // Centre of the slot, well clear of the 1 px rim: 0.18 * 255 = 45.9.
    const off = (32 * stride) + (32 * 4);
    // CAIRO_FORMAT_ARGB32 is 0xAARRGGBB little-endian, so bytes are B,G,R,A.
    const r: i32 = data[off + 2];
    try t.expect(r >= 45 and r <= 47);
    try t.expect(data[off + 1] <= 2);
    try t.expect(data[off] <= 2);

    // And it is a wash, not nothing: the rim really is drawn, brightest
    // along the bottom of the gradient (0.42 over the 0.18 wash).
    const rim = (53 * stride) + (32 * 4);
    try t.expect(data[rim + 1] <= 2);
    try t.expect(data[rim + 2] > 60);
}

test "widgets-paint: slots render onto a surface" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 400, 90);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    const red = [_]u8{ 0, 0, 255, 255 } ** 64;
    // App slot with an icon, widget slot with text, with dots, and the
    // no-data fallback — all four paths in one pass.
    paintSlot(cr, 8, 8, 44, 44, 44, .{ .icon = .{ .pixels = &red, .w = 8, .h = 8 } });
    paintSlot(cr, 64, 8, 90, 44, 44, .{ .pill = true, .label = "12:34" });
    paintSlot(cr, 166, 8, 80, 44, 44, .{ .pill = true, .dots = 3 });
    paintSlot(cr, 258, 8, 44, 44, 44, .{ .letter = "S" });
    paintSlot(cr, 314, 8, 44, 44, 44, .{});
    // Degenerate geometry is ignored rather than drawing outside the surface.
    paintSlot(cr, 0, 0, 0, 0, 44, .{ .label = "x" });
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}

test "widgets-paint: the running dot sits tangent under a lifted icon box" {
    const t = std.testing;
    // Slot at y=30, 44 tall, lifted 5 px: 30 - 5 + 44 + 0 + 4 = 73.
    try t.expectApproxEqAbs(@as(f64, 73.0), indicatorCenterY(30, 44, 5.0), 1e-9);
    // Unlifted it hugs the box: 30 + 44 + 4 = 78.
    try t.expectApproxEqAbs(@as(f64, 78.0), indicatorCenterY(30, 44, 0.0), 1e-9);
    // A press lifts the dot too, since it follows the content.
    try t.expectApproxEqAbs(@as(f64, 76.0), indicatorCenterY(30, 44, 2.0), 1e-9);
}

test "widgets-paint: lift, press and indicators all draw" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 220, 120);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    const red = [_]u8{ 0, 0, 255, 255 } ** 64;
    // Hovered, running, focused: pill + accent wash + lifted icon + blue dot.
    paintSlot(cr, 8, 30, 44, 44, 44, .{
        .pill = true,
        .icon = .{ .pixels = &red, .w = 8, .h = 8 },
        .hover = true,
        .lift = 5.0,
        .indicator = true,
        .indicator_active = true,
    });
    // Pressed: outline plus the 0.92 scale, idle dot.
    paintSlot(cr, 70, 30, 44, 44, 44, .{
        .pill = true,
        .icon = .{ .pixels = &red, .w = 8, .h = 8 },
        .press = true,
        .indicator = true,
    });
    // Text and dots slots take the same lift path without an indicator.
    paintSlot(cr, 132, 30, 90, 44, 44, .{ .pill = true, .label = "12:34", .lift = 5.0 });
    paintSlot(cr, 132, 78, 90, 44, 44, .{ .pill = true, .dots = 3, .press = true });
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}

test "widgets-paint: only full-bleed art is framed" {
    const t = std.testing;
    // 16x16 of solid opacity: every corner probe is opaque.
    var px = [_]u8{ 0, 0, 255, 255 } ** 256;
    try t.expect(cornersOpaque(.{ .pixels = &px, .w = 16, .h = 16 }));

    // Clear the eight probe pixels — the shape of art that carries its own
    // silhouette (a circle, a logo with margins) — and the frame stays off.
    const probe = [_][2]usize{
        .{ 2, 2 },  .{ 13, 2 }, .{ 2, 13 }, .{ 13, 13 },
        .{ 4, 4 },  .{ 11, 4 }, .{ 4, 11 }, .{ 11, 11 },
    };
    for (probe) |pt| {
        const i = (pt[1] * 16 + pt[0]) * 4;
        px[i + 3] = 0;
    }
    try t.expect(!cornersOpaque(.{ .pixels = &px, .w = 16, .h = 16 }));

    // A raster too small to hold the probes is never framed.
    try t.expect(!cornersOpaque(.{ .pixels = &px, .w = 4, .h = 4 }));
}

test "widgets-paint: a framed icon paints on a surface" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 220, 120);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    // Full-bleed square art: rounded by the frame, rimmed and shadowed.
    const square = [_]u8{ 0, 0, 255, 255 } ** 64;
    paintSlot(cr, 8, 30, 44, 44, 44, .{ .icon = .{ .pixels = &square, .w = 8, .h = 8 }, .frame = true });
    // The frame flag off keeps the plain blit.
    paintSlot(cr, 70, 30, 44, 44, 44, .{ .icon = .{ .pixels = &square, .w = 8, .h = 8 } });
    // Raster too small for the corner probes: the frame is a no-op.
    const tiny = [_]u8{ 0, 0, 255, 255 } ** 16;
    paintSlot(cr, 132, 30, 44, 44, 44, .{ .icon = .{ .pixels = &tiny, .w = 4, .h = 4 }, .frame = true });
    try t.expect(cairo.cairo_status(cr) == cairo.CAIRO_STATUS_SUCCESS);
}

test "widgets-paint: hsv tint converts hue correctly" {
    const t = std.testing;
    // The dock's default `border_hue = 200` at s=0.55 v=0.92 — a sky-blue rim.
    const c = hsvToRgb(200.0, 0.55, 0.92);
    try t.expectApproxEqAbs(@as(f64, 0.414), c.r, 1e-4);
    try t.expectApproxEqAbs(@as(f64, 0.751333), c.g, 1e-4);
    try t.expectApproxEqAbs(@as(f64, 0.92), c.b, 1e-6);

    const red = hsvToRgb(0.0, 1.0, 1.0);
    try t.expectApproxEqAbs(@as(f64, 1.0), red.r, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 0.0), red.g, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 0.0), red.b, 1e-6);

    const green = hsvToRgb(120.0, 1.0, 1.0);
    try t.expectApproxEqAbs(@as(f64, 0.0), green.r, 1e-6);
    try t.expectApproxEqAbs(@as(f64, 1.0), green.g, 1e-6);

    // Hue wraps and negatives are normalised (float modulo).
    const wrapped = hsvToRgb(-160.0, 0.0, 1.0);
    const direct = hsvToRgb(200.0, 0.0, 1.0);
    try t.expectApproxEqAbs(direct.r, wrapped.r, 1e-9);
    try t.expectApproxEqAbs(direct.b, wrapped.b, 1e-9);
}
