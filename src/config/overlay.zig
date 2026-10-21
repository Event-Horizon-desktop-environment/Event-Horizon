//! Overlay-surface alpha scaling: which `overlay_opacity_*` knob scales a
//! given overlay surface.
//!
//! Two branches: with `overlay_opacity_advanced`
//! off every surface follows `overlay_opacity_master` (the launchpad being
//! the one exception that keeps its own knob on both branches); with it on,
//! each surface kind reads its own key, and `battery` — which has no key of
//! its own — falls back to the master.
//!
//! The scale is a *multiplier* on a card's nominal alpha: the dock's
//! right-click menu paints its glass at `0.78 * scale`, so turning the master
//! down to 0.5 makes the card half as opaque and the compositor's blur twice
//! as present. Nothing here knows about cards; it only answers "how opaque
//! is this kind of surface allowed to be".
//!
//! What the Appearance → Opacity page edits, though, is opacity itself, not
//! the multiplier — 0% must leave nothing and 100% must be solid, like the
//! dock's own opacity slider. `designAlpha` bridges the two: it is the alpha
//! each knob's primary body paints at scale 1.0 (its *design*), so the page
//! shows `min(1, scale * design)` and writes back `pct / design` for 100%.
//! That is why the ceiling here is `1 / designAlpha(kind)` per kind and why
//! stored values may exceed 1.0 (up to 1/0.55 ≈ 1.82): 100% means "fully
//! opaque", not "the design". The C++ shell stopped at the design nominal
//! (its settings page wrote `pct / 100` straight into the multiplier), which
//! is what made every slider bottom out at translucent.

const std = @import("std");
const s3 = @import("schema3.zig");

/// Overlay surface-alpha kinds, in this file's snake_case.
/// A new kind needs its key plumbed in schema3
/// before it can appear here.
pub const Kind = enum {
    control_center,
    app_drawer,
    launchpad,
    settings,
    dock_menu,
    desktop_menu,
    tray_menu,
    calendar,
    weather,
    world_clock,
    tooltip,
    overview,
    notifications,
    battery,
};

/// The master scales every surface at once, so its own 100% has to clear the
/// *faintest* body it drives — the `0.55` glassCard fill the control center
/// and the pear paint. Clearing that clears every other nominal too.
pub const master_design: f64 = 0.55;

/// `overlay_opacity_widget_card` is the family knob for the cards that have
/// no surface key of their own (desktop widgets, media/bluetooth/volume
/// cards), and the cards paint their body at `0.92 * widgetCardAlpha`.
pub const widget_card_design: f64 = 0.92;

/// The body alpha kind's primary surface paints at scale 1.0 — the designed
/// translucency the settings page needs to convert percent ↔ multiplier.
/// Each number is the nominal at the call site that consumes the kind:
/// `popup_menu_paint.base_alpha` (0.78) for the menus, `glassCard`'s
/// `drawer_dim` fill (0.55) for the control center, the `0.92` widget-card
/// fill for the drawer/calendar/weather, and so on.
pub fn designAlpha(kind: Kind) f64 {
    return switch (kind) {
        // `glassCard` body fill (control center popup, pear).
        .control_center => 0.55,
        // The start menu / drawer card's 0.92 fill.
        .app_drawer => 0.92,
        // The apps page's card chrome (folder modal, tile menu) at 0.96.
        .launchpad => 0.96,
        // The settings window fill (`0.78 * glassScale()`).
        .settings => 0.78,
        // `popup_menu_paint.base_alpha`.
        .dock_menu, .desktop_menu, .tray_menu => 0.78,
        // The calendar / weather popup cards' 0.92 fill.
        .calendar, .weather => 0.92,
        // The world clock popup's plate fill (dock and taskbar copies),
        // painted at 1.0 by design: 100% is the solid plate.
        .world_clock => 1.0,
        // The tooltip's `0.96 * ov` body.
        .tooltip => 0.96,
        // The overview's backdrop capture is painted opaque by design, so
        // its knob is already a straight opacity (100% = the design).
        .overview => 1.0,
        // The toast card's `0.78 * alpha` body.
        .notifications => 0.78,
        // No key of its own: it follows the master, so it shares the
        // master's reference body.
        .battery => master_design,
    };
}

/// `overlay_surface_alpha_scale(sc, kind)` — clamped to `[0, 1/design]` so
/// the body saturates to fully opaque at 100% and never past it.
pub fn scale(a: *const s3.Appearance, kind: Kind) f64 {
    if (!a.overlay_opacity_advanced) {
        if (kind == .launchpad) return clampTo(a.overlay_opacity_launchpad, designAlpha(.launchpad));
        return clampTo(a.overlay_opacity_master, master_design);
    }
    const v: f32 = switch (kind) {
        .control_center => a.overlay_opacity_control_center,
        .app_drawer => a.overlay_opacity_app_drawer,
        .launchpad => a.overlay_opacity_launchpad,
        .settings => a.overlay_opacity_settings,
        .dock_menu => a.overlay_opacity_dock_menu,
        .desktop_menu => a.overlay_opacity_desktop_menu,
        .tray_menu => a.overlay_opacity_tray_menu,
        .calendar => a.overlay_opacity_calendar,
        .weather => a.overlay_opacity_weather,
        .world_clock => a.overlay_opacity_world_clock,
        .tooltip => a.overlay_opacity_tooltip,
        .overview => a.overlay_opacity_overview,
        .notifications => a.overlay_opacity_notifications,
        // No `overlay_opacity_battery` key exists — the `default` arm
        // and its `Battery` arm both land on the master.
        .battery => a.overlay_opacity_master,
    };
    return clampTo(v, designAlpha(kind));
}

/// `control_center_inner_glass_alpha_scale(sc)` — the scale for the control
/// center's *inner* cards (the tiles, audio/device/mixer/media/weather cards
/// of the popup and the pear). Its knob has no `Kind` of its own, so `scale`
/// cannot answer for it. Advanced on: `overlay_opacity_control_center_inner`;
/// off: the master. Both paint through the same `glassCard` body (0.55).
pub fn controlCenterInnerAlpha(a: *const s3.Appearance) f64 {
    if (!a.overlay_opacity_advanced) return clampTo(a.overlay_opacity_master, master_design);
    return clampTo(a.overlay_opacity_control_center_inner, designAlpha(.control_center));
}

/// `overlay_opacity_widget_card` — the Zig schema reads it raw. This is the
/// alpha card painters multiply their nominal `0.92` fill by directly:
/// `paint_calendar_card`, `paint_fancy_weather_card`, and the widget-card
/// popups. Its ceiling is `1 / 0.92`, so 100% is a solid body and cairo
/// saturates anything past it. The per-surface kinds (`.calendar`,
/// `.weather`, `.app_drawer`) no longer multiply through this knob: each
/// advanced-mode slider is the single authority for its own surface.
pub fn widgetCardAlpha(a: *const s3.Appearance) f64 {
    return clampTo(a.overlay_opacity_widget_card, widget_card_design);
}

/// Clamp to `[0, 1/design]`: the body alpha `design * v` can reach 1.0 but
/// no further.
fn clampTo(v: f32, design: f64) f64 {
    const max: f64 = 1.0 / design;
    return std.math.clamp(@as(f64, v), 0.0, max);
}

// The knobs live in the schema as `f32` (as every other colour/opacity does),
// while `scale` answers in `f64` for the cairo side — so a literal like `0.6`
// only survives the round trip to within ~3e-8. Every assertion below is an
// equality *within that widening*, not a bit-for-bit one.
const widen_eps = 1e-6;

test "overlay: one master knob drives everything but the launchpad" {
    const t = std.testing;
    var a = s3.Appearance{};
    a.overlay_opacity_advanced = false;
    a.overlay_opacity_master = 0.6;
    a.overlay_opacity_launchpad = 0.2;
    a.overlay_opacity_dock_menu = 0.9; // ignored while the master rules
    try t.expectApproxEqAbs(@as(f64, 0.6), scale(&a, .dock_menu), widen_eps);
    try t.expectApproxEqAbs(@as(f64, 0.6), scale(&a, .tray_menu), widen_eps);
    try t.expectApproxEqAbs(@as(f64, 0.6), scale(&a, .battery), widen_eps);
    // The launchpad keeps its own knob on *both* branches.
    try t.expectApproxEqAbs(@as(f64, 0.2), scale(&a, .launchpad), widen_eps);
}

test "overlay: advanced mode reads each kind's own key" {
    const t = std.testing;
    var a = s3.Appearance{};
    a.overlay_opacity_advanced = true;
    a.overlay_opacity_master = 1.0;
    a.overlay_opacity_dock_menu = 0.4;
    a.overlay_opacity_tray_menu = 0.55;
    a.overlay_opacity_control_center = 0.7;
    a.overlay_opacity_world_clock = 0.35;
    try t.expectApproxEqAbs(@as(f64, 0.4), scale(&a, .dock_menu), widen_eps);
    try t.expectApproxEqAbs(@as(f64, 0.55), scale(&a, .tray_menu), widen_eps);
    try t.expectApproxEqAbs(@as(f64, 0.7), scale(&a, .control_center), widen_eps);
    try t.expectApproxEqAbs(@as(f64, 0.35), scale(&a, .world_clock), widen_eps);
    // An untouched key is 1.0 — the design: the multiplier lands on the
    // nominal and the page shows it as this kind's body opacity (0.92 for
    // the calendar). The 100% end is `1 / designAlpha`, where the body
    // saturates to solid.
    try t.expectApproxEqAbs(@as(f64, 1.0), scale(&a, .calendar), widen_eps);
    a.overlay_opacity_calendar = @floatCast(1.0 / designAlpha(.calendar));
    try t.expectApproxEqAbs(@as(f64, 1.0), designAlpha(.calendar) * scale(&a, .calendar), widen_eps);
    // `battery` has no key of its own even in advanced mode.
    try t.expectApproxEqAbs(@as(f64, 1.0), scale(&a, .battery), widen_eps);
}

test "overlay: 100% clears the body, and the clamp stops there" {
    const t = std.testing;
    var a = s3.Appearance{};
    a.overlay_opacity_advanced = true;
    // The value the settings page writes for 100%: the body hits 1.0.
    a.overlay_opacity_dock_menu = @floatCast(1.0 / designAlpha(.dock_menu));
    try t.expectApproxEqAbs(@as(f64, 1.0), designAlpha(.dock_menu) * scale(&a, .dock_menu), widen_eps);
    // Past it the clamp holds; below zero it bottoms out at nothing.
    a.overlay_opacity_master = 5.0;
    a.overlay_opacity_dock_menu = -1.0;
    try t.expectApproxEqAbs(1.0 / master_design, scale(&a, .battery), widen_eps);
    try t.expectApproxEqAbs(@as(f64, 0.0), scale(&a, .dock_menu), widen_eps);
}

test "overlay: the control-center inner glass follows the master when advanced is off" {
    const t = std.testing;
    var a = s3.Appearance{};
    a.overlay_opacity_advanced = false;
    a.overlay_opacity_master = 0.45;
    a.overlay_opacity_control_center_inner = 0.9; // ignored while the master rules
    try t.expectApproxEqAbs(@as(f64, 0.45), controlCenterInnerAlpha(&a), widen_eps);
}

test "overlay: the control-center inner glass reads its own key in advanced mode" {
    const t = std.testing;
    var a = s3.Appearance{};
    a.overlay_opacity_advanced = true;
    a.overlay_opacity_master = 1.0;
    a.overlay_opacity_control_center_inner = 0.3;
    try t.expectApproxEqAbs(@as(f64, 0.3), controlCenterInnerAlpha(&a), widen_eps);
    // Clamped at the top to 1/design — 100% is a solid body, and past that
    // the multiplier has nothing left to say.
    a.overlay_opacity_control_center_inner = 2.5;
    try t.expectApproxEqAbs(1.0 / designAlpha(.control_center), controlCenterInnerAlpha(&a), widen_eps);
    a.overlay_opacity_control_center_inner = -0.5;
    try t.expectApproxEqAbs(@as(f64, 0.0), controlCenterInnerAlpha(&a), widen_eps);
}

test "overlay: the widget-card knob is its own number, clamped" {
    const t = std.testing;
    var a = s3.Appearance{};
    a.overlay_opacity_widget_card = 0.18;
    try t.expectApproxEqAbs(@as(f64, 0.18), widgetCardAlpha(&a), widen_eps);
    // Loaded raw and unbounded, so the clamp is what keeps it an *alpha*.
    a.overlay_opacity_widget_card = 3.5;
    try t.expectApproxEqAbs(1.0 / widget_card_design, widgetCardAlpha(&a), widen_eps);
    a.overlay_opacity_widget_card = -1.0;
    try t.expectApproxEqAbs(@as(f64, 0.0), widgetCardAlpha(&a), widen_eps);
}
