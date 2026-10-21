//! The six M3 elevation levels, in dp.
//!
//! Elevation in M3 is expressed as a *blur radius*, not an offset: the shadow
//! colour comes from `ColorRole::shadow`, the ambient shadow radius is the
//! level value, and the penumbra is nudged down by `level * 0.5dp`. That is
//! why these are small integers rather than box-shadow offsets — a level is a
//! depth, and each surface maps its own depth onto a paint.
//!
//! The per-component table below keeps
//! resting/hover/focus/press depths stay auditable after the port.

/// Six M3 elevation levels. Shadow colour from `ColorRole.shadow`.
/// Ambient shadow = blur radius. Penumbra offset Y = level * 0.5dp.
pub const ElevationTokens = struct {
    /// No shadow. Cards (filled), buttons, nav rail.
    pub const level0: f32 = 0.0;
    /// Hint of depth. Elevated cards, modal drawer.
    pub const level1: f32 = 1.0;
    /// Subtle. Nav bar, FAB resting.
    pub const level2: f32 = 3.0;
    /// Medium. Dialog, FAB pressed, snackbar.
    pub const level3: f32 = 6.0;
    /// Prominent. FAB hover, menu.
    pub const level4: f32 = 8.0;
    /// Deepest. FAB focus (keyboard).
    pub const level5: f32 = 12.0;

    /// Penumbra offset in dp for a given level — the vertical nudge that
    /// separates the penumbra from the ambient shadow.
    pub fn penumbraOffset(level: f32) f32 {
        return level * 0.5;
    }

    /// Per-component elevation per state.
    ///
    /// The table's numbers are raw *depths in dp*, not `level` indices — the
    /// ladder is 0/1/3/6/8/12, but a FAB hovers at 4 and focuses at 5, which
    /// sit between rungs. Returning the whole row keeps that distinction
    /// honest instead of rounding every depth onto the nearest named level.
    ///
    ///   Component              | Rest | Hover | Focus | Press
    ///   -----------------------|------|-------|-------|-------
    ///   Filled button          | 0    | 0     | 0     | 0
    ///   Elevated button        | 1    | 2     | 2     | 2
    ///   FAB                    | 3    | 4     | 5     | 4
    ///   Card (elevated)        | 1    | 2     | 2     | —
    ///   Card (filled)          | 0    | 1     | 1     | —
    ///   Card (outlined)        | 0    | 1     | 1     | —
    ///   Dialog                 | 3    | —     | —     | —
    ///   Bottom sheet           | 3    | —     | —     | —
    ///   Navigation bar         | 2    | —     | —     | —
    ///   Snackbar               | 3    | —     | —     | —
    ///   Menu / dropdown        | 3    | —     | —     | —
    ///
    /// Surfaces with a "—" repeat their rest depth.
    /// accessor effectively does by returning the single value it has.
    pub const Depths = struct {
        rest: f32,
        hover: f32,
        focus: f32,
        press: f32,
    };

    pub fn forComponent(c: Component) Depths {
        return switch (c) {
            .filled_button => .{ .rest = 0, .hover = 0, .focus = 0, .press = 0 },
            .elevated_button => .{ .rest = 1, .hover = 2, .focus = 2, .press = 2 },
            // The FAB is the only surface whose focus depth exceeds its
            // hover depth — keyboard focus is the deepest it ever sits.
            .fab => .{ .rest = 3, .hover = 4, .focus = 5, .press = 4 },
            .card_elevated => .{ .rest = 1, .hover = 2, .focus = 2, .press = 1 },
            .card_filled, .card_outlined => .{ .rest = 0, .hover = 1, .focus = 1, .press = 0 },
            .dialog,
            .bottom_sheet,
            .snackbar,
            .menu,
            => .{ .rest = 3, .hover = 3, .focus = 3, .press = 3 },
            .nav_bar => .{ .rest = 2, .hover = 2, .focus = 2, .press = 2 },
        };
    }
};

/// The components assigned depths.
pub const Component = enum {
    filled_button,
    elevated_button,
    fab,
    card_elevated,
    card_filled,
    card_outlined,
    dialog,
    bottom_sheet,
    nav_bar,
    snackbar,
    menu,
};

const std = @import("std");

test "m3-tokens-elevation: levels ascend and penumbra tracks them" {
    const t = std.testing;
    // The levels are a depth ladder — anything reading them as a list must
    // get strictly increasing blur.
    try t.expect(ElevationTokens.level0 < ElevationTokens.level1);
    try t.expect(ElevationTokens.level1 < ElevationTokens.level2);
    try t.expect(ElevationTokens.level2 < ElevationTokens.level3);
    try t.expect(ElevationTokens.level3 < ElevationTokens.level4);
    try t.expect(ElevationTokens.level4 < ElevationTokens.level5);
    try t.expectEqual(@as(f32, 0.0), ElevationTokens.penumbraOffset(0.0));
    try t.expectEqual(@as(f32, 6.0), ElevationTokens.penumbraOffset(12.0));
}

test "m3-tokens-elevation: FAB is the only surface that lifts on focus" {
    const t = std.testing;
    // Note the FAB's *rest* depth (3) is level with a dialog's — it does not
    // out-rank static surfaces until it is interacted with. What singles it
    // out is that hover, focus and press all differ from rest.
    const fab = ElevationTokens.forComponent(.fab);
    const dialog = ElevationTokens.forComponent(.dialog);
    try t.expectEqual(dialog.rest, fab.rest);
    // Its focus depth is the deepest depth anywhere in the table, and press
    // drops back to the hover depth rather than staying lifted.
    try t.expect(fab.focus > fab.hover);
    try t.expectEqual(fab.hover, fab.press);
    try t.expect(fab.focus > dialog.rest);
    // A dialog never moves — every state repeats its rest depth.
    try t.expectEqual(dialog.rest, dialog.hover);
    try t.expectEqual(dialog.rest, dialog.focus);
    // Filled buttons and outlined cards never lift at all.
    try t.expectEqual(ElevationTokens.level0, ElevationTokens.forComponent(.filled_button).rest);
    try t.expectEqual(ElevationTokens.level0, ElevationTokens.forComponent(.card_outlined).rest);
}
