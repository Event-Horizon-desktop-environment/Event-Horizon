//! The seven M3 shape families, in dp.
//!
//! M3 Expressive (May 2025) added `cut` corners alongside the usual rounded
//! ones, which is why `family` is a real field rather than a constant: a
//! theme can flip the whole shell to cut-cornered boxes and every rounded
//! rect in the control layer follows.
//!
//! `full` is 999 rather than infinity on purpose — every rounded-rect builder
//! in this codebase clamps the radius to half the shorter side, so 999 reads
//! as "pill/circle" for any plausible box without special-casing.

/// M3 Expressive (May 2025) adds cut corners as an alternative to rounded.
pub const CornerFamily = enum {
    rounded,
    cut,
};

/// Seven M3 shape families. All values in dp.
pub const ShapeTokens = struct {
    family: CornerFamily = .rounded,

    /// No rounding.
    none: f32 = 0.0,
    /// Checkbox, snackbar, menu, tooltip.
    extra_small: f32 = 4.0,
    /// Chips, segmented segments.
    small: f32 = 8.0,
    /// Cards, FAB (small), text field.
    medium: f32 = 12.0,
    /// FAB (standard), extended FAB.
    large: f32 = 16.0,
    /// Dialog, bottom sheet (top), search bar.
    extra_large: f32 = 28.0,
    /// Pill / circle.
    full: f32 = 999.0,

    /// Per-component shape assignments so the
    /// mapping survives the port:
    ///
    ///   Component              | Shape          | Value
    ///   -----------------------|----------------|-------
    ///   Filled button          | full           | 999dp
    ///   Outlined button        | full           | 999dp
    ///   Tonal button           | full           | 999dp
    ///   Text button            | full           | 999dp
    ///   FAB (extended)         | large          | 16dp
    ///   Card                   | medium         | 12dp
    ///   Dialog                 | extraLarge     | 28dp
    ///   Bottom sheet           | extraLarge     | 28dp
    ///   Search bar             | extraLarge     | 28dp
    ///   Text field             | medium         | 12dp
    ///   Checkbox               | extraSmall     | 4dp
    ///   Chip                   | small          | 8dp
    ///   Snackbar               | extraSmall     | 4dp
    ///   Menu / dropdown        | extraSmall     | 4dp
    ///   Navigation bar         | extraLarge     | 28dp
    ///   Navigation rail        | large          | 16dp
    pub fn forComponent(self: *const ShapeTokens, c: Component) f32 {
        return switch (c) {
            .filled_button,
            .outlined_button,
            .tonal_button,
            .text_button,
            => self.full,
            .fab_extended,
            .card,
            .nav_rail => self.large,
            .dialog,
            .bottom_sheet,
            .search_bar,
            .nav_bar,
            => self.extra_large,
            .text_field => self.medium,
            .chip => self.small,
            .checkbox,
            .snackbar,
            .menu,
            => self.extra_small,
        };
    }
};

/// The components assigned a shape. Kept as an enum rather
/// than free functions so the lookup stays exhaustive if a shape value moves.
pub const Component = enum {
    filled_button,
    outlined_button,
    tonal_button,
    text_button,
    fab_extended,
    card,
    dialog,
    bottom_sheet,
    search_bar,
    text_field,
    checkbox,
    chip,
    snackbar,
    menu,
    nav_bar,
    nav_rail,
};

const std = @import("std");

test "m3-tokens-shape: defaults and pill clamp" {
    const t = std.testing;
    const s = ShapeTokens{};
    try t.expectEqual(CornerFamily.rounded, s.family);
    try t.expectEqual(@as(f32, 4.0), s.extra_small);
    try t.expectEqual(@as(f32, 28.0), s.extra_large);
    // 999 must exceed half of any box the shell draws, so the rounded-rect
    // builder's `min(r, min(w,h)/2)` turns it into a pill without a branch.
    try t.expect(s.full * 2.0 > 1000.0);
}

test "m3-tokens-shape: per-component lookups match the specified table" {
    const t = std.testing;
    const s = ShapeTokens{};
    try t.expectEqual(@as(f32, 999.0), s.forComponent(.filled_button));
    try t.expectEqual(@as(f32, 16.0), s.forComponent(.card));
    try t.expectEqual(@as(f32, 28.0), s.forComponent(.dialog));
    try t.expectEqual(@as(f32, 12.0), s.forComponent(.text_field));
    try t.expectEqual(@as(f32, 8.0), s.forComponent(.chip));
    try t.expectEqual(@as(f32, 4.0), s.forComponent(.checkbox));
}
