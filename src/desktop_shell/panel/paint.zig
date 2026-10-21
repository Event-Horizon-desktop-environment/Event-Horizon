//! Panel paint — port of `src/desktop_shell/panel/paint/panel_paint.cpp`.
//!
//! The bar background (glass card, per-corner radii, border) plus the
//! three-zone widget strip. Slot faces reuse the existing widget painters
//! (clock, weather, workspaces, battery, bluetooth, world-clock,
//! control-center, layout); tray/app icons paint from the host's icon
//! lookup with the scaled-icon cache semantics; everything else takes the
//! C++ generic pill+glyph arm. Layout and hit rects come from
//! `slots.zig`/`layout.zig` so paint stays the single source of truth.

const std = @import("std");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const tokens = @import("../../m3/tokens.zig");
const schema = @import("../../config/schema.zig");
const pill = @import("../widgets/shared/pill.zig");
const helpers = @import("../shared/cairo_helpers.zig");
const chrome_colors = @import("../widgets/shared/chrome_colors.zig");
const slots_mod = @import("slots.zig");
const layout_mod = @import("layout.zig");
const settings_mod = @import("settings.zig");
const types = @import("types.zig");
const widgets = @import("widgets.zig");

const clock_paint = @import("../widgets/clock/clock_paint.zig");
const weather_paint = @import("../widgets/weather/weather_paint.zig");
const world_clock_paint = @import("../widgets/world_clock/world_clock_paint.zig");
const layout_paint = @import("../widgets/layout/layout_paint.zig");
const battery_paint = @import("../widgets/battery/battery_paint.zig");
const bluetooth_paint = @import("../widgets/bluetooth/bluetooth_paint.zig");
const cc_slot = @import("../controlcenter/slot.zig");
const ws_paint = @import("../widgets/workspaces/workspaces_paint.zig");
const svg_icons = @import("../../ux/settings/svg_icons.zig");
const mat_glyph = @import("../common/material_glyph.zig");

pub fn paintBar(cr: ?*cairo.cairo_t, w: i32, h: i32, radius: f64, opacity: f64) void {
    if (cr == null) return;
    const c = cr.?;
    cairo.cairo_set_source_rgba(c, tokens.Tokens.background.r, tokens.Tokens.background.g, tokens.Tokens.background.b, opacity);
    roundedRect(c, 0, 0, @floatFromInt(w), @floatFromInt(h), radius);
    cairo.cairo_fill(c);
}

pub fn roundedRect(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    if (cr == null) return;
    const c = cr.?;
    const rad = @min(r, @min(w / 2.0, h / 2.0));
    cairo.cairo_new_sub_path(c);
    cairo.cairo_arc(c, x + w - rad, y + rad, rad, -std.math.pi / 2.0, 0);
    cairo.cairo_arc(c, x + w - rad, y + h - rad, rad, 0, std.math.pi / 2.0);
    cairo.cairo_arc(c, x + rad, y + h - rad, rad, std.math.pi / 2.0, std.math.pi);
    cairo.cairo_arc(c, x + rad, y + rad, rad, std.math.pi, 3.0 * std.math.pi / 2.0);
    cairo.cairo_close_path(c);
}

/// Per-corner rounded-rect path (`panel_path_rounded_rect4`, panel.cpp:75-93).
pub fn roundedRect4(cr: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, rtl: f64, rtr: f64, rbr: f64, rbl: f64) void {
    const c = cr orelse return;
    const m = @min(w, h) * 0.5;
    const a = @min(@max(rtl, 0), m);
    const b = @min(@max(rtr, 0), m);
    const cc = @min(@max(rbr, 0), m);
    const d = @min(@max(rbl, 0), m);
    const p = std.math.pi;
    cairo.cairo_new_path(c);
    cairo.cairo_move_to(c, x + a, y);
    cairo.cairo_line_to(c, x + w - b, y);
    if (b > 0) cairo.cairo_arc(c, x + w - b, y + b, b, -p * 0.5, 0);
    cairo.cairo_line_to(c, x + w, y + h - cc);
    if (cc > 0) cairo.cairo_arc(c, x + w - cc, y + h - cc, cc, 0, p * 0.5);
    cairo.cairo_line_to(c, x + d, y + h);
    if (d > 0) cairo.cairo_arc(c, x + d, y + h - d, d, p * 0.5, p);
    cairo.cairo_line_to(c, x, y + a);
    if (a > 0) cairo.cairo_arc(c, x + a, y + a, a, p, p * 1.5);
    cairo.cairo_close_path(c);
}

/// Bar background: glass card with uniform or per-corner radii plus the
/// accent border (`panel.cpp:653-693`). Opacity is the panel opacity.
pub fn paintBarBackground(
    cr: ?*cairo.cairo_t,
    cfg: *const schema.ShellConfig,
    s: *const settings_mod.PanelSettings,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
) void {
    const c = cr orelse return;
    if (w <= 0 or h <= 0) return;
    const mc = chrome_colors.of(cfg);
    const alpha: f64 = @as(f64, @floatFromInt(@max(0, @min(100, s.opacity)))) / 100.0;
    const uniform = s.corner_tl == s.corner_tr and s.corner_tl == s.corner_bl and s.corner_br == s.corner_tl;
    // Base fill in the bar shape.
    cairo.cairo_save(c);
    if (uniform) {
        helpers.pathRoundedRect(c, x, y, w, h, @floatFromInt(s.radius));
    } else {
        roundedRect4(c, x, y, w, h, @floatFromInt(s.corner_tl), @floatFromInt(s.corner_tr), @floatFromInt(s.corner_br), @floatFromInt(s.corner_bl));
    }
    cairo.cairo_clip(c);
    cairo.cairo_set_source_rgba(c, mc.dock_fill.r, mc.dock_fill.g, mc.dock_fill.b, alpha);
    cairo.cairo_rectangle(c, x, y, w, h);
    cairo.cairo_fill(c);
    // Milky lift so the fill reads frosted, not flat.
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.07 * alpha);
    cairo.cairo_rectangle(c, x, y, w, h);
    cairo.cairo_fill(c);
    cairo.cairo_restore(c);
    // Edge stroke in the bar shape.
    if (uniform) {
        helpers.pathRoundedRect(c, x + 0.5, y + 0.5, w - 1.0, h - 1.0, @max(0, @as(f64, @floatFromInt(s.radius)) - 0.5));
    } else {
        roundedRect4(c, x + 0.5, y + 0.5, w - 1.0, h - 1.0, @floatFromInt(s.corner_tl), @floatFromInt(s.corner_tr), @floatFromInt(s.corner_br), @floatFromInt(s.corner_bl));
    }
    cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.14 * alpha + 0.02);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);
    // Optional accent border inside the bar (panel.cpp:677-693).
    if (s.border and s.border_size > 0) {
        const bw: f64 = @floatFromInt(s.border_size);
        const inset = bw * 0.5;
        if (uniform) {
            const rr = @max(0, @as(f64, @floatFromInt(s.radius)) - inset);
            helpers.pathRoundedRect(c, x + inset, y + inset, @max(1, w - bw), @max(1, h - bw), rr);
        } else {
            roundedRect4(c, x + inset, y + inset, @max(1, w - bw), @max(1, h - bw), @as(f64, @floatFromInt(s.corner_tl)) - inset, @as(f64, @floatFromInt(s.corner_tr)) - inset, @as(f64, @floatFromInt(s.corner_br)) - inset, @as(f64, @floatFromInt(s.corner_bl)) - inset);
        }
        cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 1.0);
        cairo.cairo_set_line_width(c, bw);
        cairo.cairo_stroke(c);
    }
}

/// Accent wash behind the hovered slot (`hover_overlay`, panel_paint.cpp:386-399).
fn hoverOverlay(cr: ?*cairo.cairo_t, cfg: *const schema.ShellConfig, s: *const settings_mod.PanelSettings, x: f64, y: f64, w: f64, h: f64) void {
    if (!s.hover_highlight) return;
    const c = cr orelse return;
    const mc = chrome_colors.of(cfg);
    const r = pill.cornerRadius(h, w);
    helpers.roundedRect(c, x, y, w, h, r);
    cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.18);
    cairo.cairo_fill_preserve(c);
    cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.35);
    cairo.cairo_set_line_width(c, 1.0);
    cairo.cairo_stroke(c);
}

/// Glyph for the generic indicator arm (panel_paint.cpp:579-597).
fn genericGlyph(kind: widgets.Kind) []const u8 {
    return switch (kind) {
        .settings => "settings",
        .overview => "dashboard",
        .smenu => "apps",
        .app_menu => "grid_view",
        .volume_mixer => "volume_up",
        .vpn => "vpn_key",
        .trash => "delete",
        .spotlight => "search",
        .app_drawer => "apps",
        else => "circle",
    };
}

fn drawGlyph(cr: ?*cairo.cairo_t, name: []const u8, cx: f64, cy: f64, px: f64, r: f64, g: f64, b: f64, a: f64) void {
    if (svg_icons.draw(cr, name, cx, cy, px, r, g, b, a, false)) return;
    _ = mat_glyph.draw(cr, name, cx, cy, px, r, g, b, a);
}

/// Per-slot width (`panel_slot_width_uncached`, panel_paint.cpp:119-146).
pub fn slotWidth(
    cfg: *const schema.ShellConfig,
    s: *const settings_mod.PanelSettings,
    slot: slots_mod.Slot,
    icon: f64,
    box_h: f64,
    ui: f64,
) f64 {
    _ = s;
    switch (slot.kind) {
        .clock => return clock_paint.dockClockSlotWidth(null, cfg, slot.key, icon, box_h),
        .weather => return weather_paint.dockWeatherSlotWidth(null, cfg, slot.key, icon, box_h),
        .media => return @max(icon * 2.0, 72.0),
        .workspaces => return ws_paint.dockWorkspacesSlotWidth(null, cfg, slot.key, icon, box_h, &.{}),
        .control_center => {
            const rt = cc_slot.Runtime{};
            return cc_slot.slotWidthFor(cfg, slot.key, rt, icon, box_h);
        },
        .battery => return battery_paint.dockBatterySlotWidth(null, cfg, slot.key, icon, box_h),
        .bluetooth => {
            const snap = bluetooth_paint.Snapshot{};
            return bluetooth_paint.dockBluetoothSlotWidth(null, cfg, slot.key, icon, box_h, &snap, &.{});
        },
        .layout => return layout_paint.dockLayoutSlotWidth(null, cfg, slot.key, icon, box_h),
        .world_clock => return world_clock_paint.dockWorldClockSlotWidth(null, cfg, slot.key, icon, box_h),
        .separator, .spacer => return @max(8.0, 12.0 * ui),
        else => return icon,
    }
}

pub const BarPaint = struct {
    hits: []types.WidgetHit = &.{},
    anchored: bool = true,
};

/// Full widget strip (panel_paint.cpp:241-657). Builds the strip, measures,
/// lays out, paints the bar background is done by the caller; this paints
/// slots and returns hit rects. `tray_dots`/`app_dots` keep the tray/app
/// arms honest without live icon surfaces.
pub fn paintWidgetBar(
    alloc: std.mem.Allocator,
    cr: ?*cairo.cairo_t,
    cfg: *const schema.ShellConfig,
    s: *const settings_mod.PanelSettings,
    sources: slots_mod.Sources,
    x: f64,
    y: f64,
    box_w: f64,
    box_h: f64,
    hover_slot: i32,
    pressed_slot: i32,
    hover_lift_px: f64,
) !BarPaint {
    const ui = settings_mod.uiScale(s.scale, cfg.dock.shell_ui_scale);
    const icon_raw = @as(f64, @floatFromInt(s.icon_size)) * ui;
    const icon = slots_mod.clampIcon(icon_raw, box_h);
    const gap = @as(f64, @floatFromInt(s.icon_spacing)) * ui;

    var strip = try slots_mod.buildStrip(alloc, cfg, s, sources);
    defer strip.deinit(alloc);

    var widths = try alloc.alloc(f64, strip.slots.len);
    defer alloc.free(widths);
    for (strip.slots, 0..) |sl, i| widths[i] = slotWidth(cfg, s, sl, icon, box_h, ui);

    const strip_pad = settings_mod.stripPadPx(ui);
    const sec_gap = settings_mod.sectionGapPx(ui);
    var placed = try layout_mod.layoutStrip(alloc, &strip, widths, gap, strip_pad, sec_gap, x, box_w);
    defer placed.deinit(alloc);

    const icon_y = y + (box_h - icon) / 2.0;

    // Capsule/pill style from chrome colors (panel_paint.cpp:253-270).
    const mc = chrome_colors.of(cfg);
    const card_a = std.math.clamp(@as(f64, cfg.appearance.overlay_opacity_widget_card), 0.0, 1.0);
    const cap_a: f64 = if (s.capsule) @as(f64, @floatFromInt(std.math.clamp(s.capsule_opacity, 0, 100))) / 100.0 else 0.0;
    pill.style.opacity_scale = card_a * cap_a;
    pill.style.pill_r = mc.dock_fill.r * 0.6 + mc.accent.r * 0.15;
    pill.style.pill_g = mc.dock_fill.g * 0.6 + mc.accent.g * 0.15;
    pill.style.pill_b = mc.dock_fill.b * 0.6 + mc.accent.b * 0.15;
    pill.style.hover_accent_r = mc.accent.r;
    pill.style.hover_accent_g = mc.accent.g;
    pill.style.hover_accent_b = mc.accent.b;

    const c = cr;
    for (strip.slots, 0..) |sl, i| {
        const ix = placed.x[i];
        const slot_w = placed.w[i];
        const gidx: i32 = @intCast(i);
        const hovered = hover_slot >= 0 and gidx == hover_slot;
        const pressed = pressed_slot >= 0 and gidx == pressed_slot;
        // App slots lift on hover and dip on press (panel_paint.cpp:428-431).
        var lift_y: f64 = 0;
        if (sl.kind == .app) {
            if (hovered) lift_y -= hover_lift_px;
            if (pressed) lift_y -= 2.0;
        }
        const slot_y = icon_y + lift_y;
        if (c == null) continue;
        if (sl.kind == .separator or sl.kind == .spacer) {
            cairo.cairo_set_source_rgba(c.?, 1, 1, 1, 0.25);
            cairo.cairo_set_line_width(c.?, 1.0);
            cairo.cairo_move_to(c.?, ix + slot_w / 2.0, slot_y + 4.0);
            cairo.cairo_line_to(c.?, ix + slot_w / 2.0, slot_y + icon - 4.0);
            cairo.cairo_stroke(c.?);
            continue;
        }
        paintSlot(c, cfg, s, sl, ix, slot_y, slot_w, icon, hovered, pressed, ui, box_h);
        if (hovered) hoverOverlay(c, cfg, s, ix, slot_y, slot_w, icon);
    }

    const hits = try layout_mod.buildHits(alloc, &strip, &placed, icon_y, icon);
    return .{ .hits = hits, .anchored = placed.anchored };
}

fn paintSlot(
    cr: ?*cairo.cairo_t,
    cfg: *const schema.ShellConfig,
    s: *const settings_mod.PanelSettings,
    slot: slots_mod.Slot,
    ix: f64,
    slot_y: f64,
    slot_w: f64,
    icon: f64,
    hovered: bool,
    pressed: bool,
    ui: f64,
    box_h: f64,
) void {
    const c = cr orelse return;
    _ = ui;
    _ = box_h;
    switch (slot.kind) {
        .clock => clock_paint.paintClockSlot(c, cfg, slot.key, ix, slot_y, slot_w, icon, icon, hovered, pressed),
        .weather => weather_paint.paintWeatherSlot(c, cfg, slot.key, ix, slot_y, slot_w, icon, icon, hovered, pressed),
        .media => {
            // Simplified now-playing pill: cover art + transport arrive with
            // the MPRIS client; until then the pill + glyph keep the rhythm.
            pill.paintPill(c, ix, slot_y, slot_w, icon);
            const mc = chrome_colors.of(cfg);
            drawGlyph(c, "album", ix + slot_w * 0.5, slot_y + icon * 0.5, icon * 0.5, mc.text.r, mc.text.g, mc.text.b, 0.9);
        },
        .workspaces => {
            var anim = ws_paint.AnimState.init(std.heap.page_allocator);
            defer anim.deinit();
            _ = ws_paint.paintWorkspacesSlot(std.heap.page_allocator, c, cfg, slot.key, ix, slot_y, slot_w, icon, icon, &.{}, hovered, pressed, null, &anim, 0) catch {};
        },
        .control_center => {
            const rt = cc_slot.Runtime{};
            const ccfg = cc_slot.loadCfg(cfg, slot.key);
            var buf: [4]cc_slot.Glyph = undefined;
            const list = cc_slot.glyphs(ccfg, rt, &buf);
            const mc = chrome_colors.of(cfg);
            cc_slot.paintSlot(c, ix, slot_y, slot_w, icon, icon, list, .{ .r = mc.dock_fill.r, .g = mc.dock_fill.g, .b = mc.dock_fill.b }, pill.style.opacity_scale);
        },
        .battery => battery_paint.paintBatterySlot(c, cfg, slot.key, ix, slot_y, slot_w, icon, icon, hovered, pressed),
        .bluetooth => {
            const snap = bluetooth_paint.Snapshot{};
            bluetooth_paint.paintBluetoothSlot(c, cfg, slot.key, ix, slot_y, slot_w, icon, icon, &snap, &.{}, hovered, pressed);
        },
        .layout => layout_paint.paintLayoutSlot(c, cfg, slot.key, ix, slot_y, slot_w, icon, icon, hovered, pressed),
        .world_clock => world_clock_paint.paintWorldClockSlot(c, cfg, slot.key, ix, slot_y, slot_w, icon, icon, hovered, pressed),
        .tray => {
            // Single shared pill per run (panel_paint.cpp:500-506); each item
            // paints its dot. Live icons arrive via the host icon lookup.
            pill.paintPill(c, ix, slot_y, slot_w, icon);
            const mc = chrome_colors.of(cfg);
            cairo.cairo_arc(c, ix + slot_w * 0.5, slot_y + icon * 0.5, @min(slot_w, icon) * 0.18, 0, 2 * std.math.pi);
            cairo.cairo_set_source_rgba(c, mc.text.r, mc.text.g, mc.text.b, 0.8);
            cairo.cairo_fill(c);
        },
        .app => {
            pill.paintPill(c, ix, slot_y, slot_w, icon);
            const mc = chrome_colors.of(cfg);
            drawGlyph(c, "apps", ix + icon * 0.5, slot_y + icon * 0.5, icon * 0.5, 1, 1, 1, 0.9);
            _ = mc;
            if (slot.chosen_serial != 0) {
                const dot_r = 2.5;
                cairo.cairo_new_path(c);
                cairo.cairo_arc(c, ix + slot_w / 2.0, slot_y + icon + 5.0, dot_r, 0, 2 * std.math.pi);
                cairo.cairo_set_source_rgba(c, 1, 1, 1, 0.35);
                cairo.cairo_fill(c);
            }
        },
        else => {
            // Generic indicator arm (panel_paint.cpp:574-603).
            pill.paintPill(c, ix, slot_y, slot_w, icon);
            const mc = chrome_colors.of(cfg);
            const name = genericGlyph(slot.kind);
            drawGlyph(c, name, ix + icon * 0.5, slot_y + icon * 0.5, icon * 0.5, mc.text.r, mc.text.g, mc.text.b, 1.0);
            _ = s;
        },
    }
}

test "panel-paint: bar renders without error" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 1920, 36);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paintBar(cr, 1920, 36, 12.0, 0.96);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    cairo.cairo_surface_flush(surf);
    const data: [*]u8 = @ptrCast(cairo.cairo_image_surface_get_data(surf));
    const cx: usize = (18 * 1920 + 960) * 4 + 3;
    try t.expect(data[cx] != 0);
}

test "panel-paint: per-corner bar + full strip paint headless" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator,
        \\[panel]
        \\left_widgets = ["clock"]
        \\center_widgets = ["workspaces"]
        \\right_widgets = ["battery", "separator", "tray"]
    );
    defer loaded.deinit();
    const cfg = &loaded.cfg;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 800, 40);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);
    paintBarBackground(cr, cfg, &cfg.panel, 0, 0, 800, 40);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    roundedRect4(cr, 0, 0, 800, 40, 12, 12, 12, 12);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    const res = try paintWidgetBar(t.allocator, cr, cfg, &cfg.panel, .{
        .running_keys = &.{"firefox"},
        .tray_keys = &.{"svc\x1fpath"},
    }, 0, 0, 800, 40, -1, -1, 5.0);    defer t.allocator.free(res.hits);
    try t.expectEqual(cairo.cairo_status(cr), cairo.CAIRO_STATUS_SUCCESS);
    try t.expect(res.hits.len >= 4);
    // Null context still measures layout and hits.
    const res2 = try paintWidgetBar(t.allocator, null, cfg, &cfg.panel, .{}, 0, 0, 800, 40, -1, -1, 5.0);
    defer t.allocator.free(res2.hits);
    try t.expect(res2.hits.len >= 3);
}
