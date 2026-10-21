//! The M3 spacing scale.
//!
//! Base unit is 8dp, expressed as 18 named levels on a linear scale. The names
//! encode the raw dp value (`space24` is 24dp) rather than a semantic role,
//! because the semantic roles live in the conventions table below and callers
//! reach for "24dp of dialog padding" far more often than they reach for
//! "dialog padding".
//!
//! Nothing here is stateful — it is a scale, so it stays a plain namespace of
//! constants.

/// Base unit = 8dp. 18 named levels on a linear scale.
pub const SpacingTokens = struct {
    /// 0×    — none.
    pub const space0: f32 = 0.0;
    /// 0.25× — micro gap.
    pub const space2: f32 = 2.0;
    /// 0.5×  — tight.
    pub const space4: f32 = 4.0;
    /// 0.75× — nested.
    pub const space6: f32 = 6.0;
    /// 1×    — default small.
    pub const space8: f32 = 8.0;
    /// 1.25× — nested.
    pub const space10: f32 = 10.0;
    /// 1.5×  — medium.
    pub const space12: f32 = 12.0;
    /// 2×    — standard padding.
    pub const space16: f32 = 16.0;
    /// 2.5×  — large inner.
    pub const space20: f32 = 20.0;
    /// 3×    — wide padding (dialog).
    pub const space24: f32 = 24.0;
    /// 3.5×  — extra.
    pub const space28: f32 = 28.0;
    /// 4×    — section.
    pub const space32: f32 = 32.0;
    /// 4.5×.
    pub const space36: f32 = 36.0;
    /// 5×    — large section.
    pub const space40: f32 = 40.0;
    /// 6×    — touch target minimum.
    pub const space48: f32 = 48.0;
    /// 7×    — FAB diameter.
    pub const space56: f32 = 56.0;
    /// 8×.
    pub const space64: f32 = 64.0;
    /// 9×.
    pub const space72: f32 = 72.0;

    /// Semantic spacing conventions:
    ///
    ///   Context                    | Value
    ///   ---------------------------|------
    ///   Card internal padding      | 16dp
    ///   Card gap                   | 12dp
    ///   Dialog internal padding    | 24dp
    ///   List item vertical padding | 12dp
    ///   Button internal padding    | 24dp (horizontal)
    ///   Icon-to-label gap          | 8dp
    ///   Section separator gap      | 32dp
    ///   Screen edge inset          | 16dp
    ///   Minimum touch target       | 48dp
    pub const touch_target_min: f32 = space48;
    pub const screen_inset: f32 = space16;
    pub const icon_label_gap: f32 = space8;
    pub const card_padding: f32 = space16;
    pub const card_gap: f32 = space12;
    pub const dialog_padding: f32 = space24;
};

const std = @import("std");

test "m3-tokens-spacing: linear 8dp scale" {
    const t = std.testing;
    // The scale is linear off the 8dp base, so every level is a clean
    // multiple of 2 and the named value equals the dp count in its name.
    try t.expectEqual(@as(f32, 24.0), SpacingTokens.space24);
    try t.expectEqual(@as(f32, 48.0), SpacingTokens.space48);
    try t.expectEqual(SpacingTokens.space8 * 3.0, SpacingTokens.space24);
    // Touch targets are never below 48dp — an accessibility floor, not a
    // style preference.
    try t.expect(SpacingTokens.touch_target_min >= 48.0);
    try t.expectEqual(@as(f32, 4.0), SpacingTokens.space8 / 2.0);
}
