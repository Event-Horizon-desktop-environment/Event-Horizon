//! The M3 15-step type scale.
//!
//! Every step carries four numbers: size in sp, weight, line-height in dp and
//! letter-spacing in dp (which may be negative — the display steps pull
//! tighter than default so large text does not read as loose). Line height
//! is tracked separately from size because the paint code lays text out by
//! line box, not by font em.
//!
//! `family` is a semantic slot, not a font name: "brand" and "plain" resolve
//! against whatever the theme installs, so swapping the shell's typeface is
//! a palette-level change and no component names a font.

/// Which installed typeface family a step resolves against. These are the
/// *semantic slot names* stored in `FontConfig::family` — a string,
/// not an enum, because `Label` and `Glyph` also put a real pango family in
/// that same field (see the note on `FontConfig.family`).
pub const Family = struct {
    pub const brand: []const u8 = "brand";
    pub const plain: []const u8 = "plain";
    pub const mono: []const u8 = "mono";
};

/// One step of the type scale. All sizes are sp, line-height and
/// letter-spacing are dp.
pub const FontConfig = struct {
    /// sp (scaled pixels).
    size: f32,
    /// 100–900.
    weight: c_uint,
    /// dp.
    line_height: f32,
    /// dp (can be negative).
    letter_spacing: f32,
    /// Semantic slot name ("brand"/"plain"/"mono") *or* a literal pango
    /// family like "Inter", read both ways:
    /// read both ways: the type scale stores a slot name, while `Label`
    /// treats it as a font family and falls back to "Inter" when empty.
    family: []const u8,
};

/// M3 15-step typescale. All values match the Material Design type scale spec.
pub const TypeScale = struct {
    // Display — largest, shortest-lived (hero text, splash)
    pub const display_large: FontConfig = .{ .size = 57, .weight = 400, .line_height = 64, .letter_spacing = -0.25, .family = Family.brand };
    pub const display_medium: FontConfig = .{ .size = 45, .weight = 400, .line_height = 52, .letter_spacing = 0.0, .family = Family.brand };
    pub const display_small: FontConfig = .{ .size = 36, .weight = 400, .line_height = 44, .letter_spacing = 0.0, .family = Family.brand };

    // Headline — medium emphasis, moderate lifespan
    pub const headline_large: FontConfig = .{ .size = 32, .weight = 400, .line_height = 40, .letter_spacing = 0.0, .family = Family.brand };
    pub const headline_medium: FontConfig = .{ .size = 28, .weight = 400, .line_height = 36, .letter_spacing = 0.0, .family = Family.brand };
    pub const headline_small: FontConfig = .{ .size = 24, .weight = 400, .line_height = 32, .letter_spacing = 0.0, .family = Family.brand };

    // Title — medium emphasis, persistent
    pub const title_large: FontConfig = .{ .size = 22, .weight = 400, .line_height = 28, .letter_spacing = 0.0, .family = Family.plain };
    pub const title_medium: FontConfig = .{ .size = 16, .weight = 500, .line_height = 24, .letter_spacing = 0.15, .family = Family.plain };
    pub const title_small: FontConfig = .{ .size = 14, .weight = 500, .line_height = 20, .letter_spacing = 0.1, .family = Family.plain };

    // Body — high emphasis, long lifespan
    pub const body_large: FontConfig = .{ .size = 16, .weight = 400, .line_height = 24, .letter_spacing = 0.5, .family = Family.plain };
    pub const body_medium: FontConfig = .{ .size = 14, .weight = 400, .line_height = 20, .letter_spacing = 0.25, .family = Family.plain };
    pub const body_small: FontConfig = .{ .size = 12, .weight = 400, .line_height = 16, .letter_spacing = 0.4, .family = Family.plain };

    // Label — small, utilitarian (buttons, captions, chips)
    pub const label_large: FontConfig = .{ .size = 14, .weight = 500, .line_height = 20, .letter_spacing = 0.1, .family = Family.plain };
    pub const label_medium: FontConfig = .{ .size = 12, .weight = 500, .line_height = 16, .letter_spacing = 0.5, .family = Family.plain };
    pub const label_small: FontConfig = .{ .size = 11, .weight = 500, .line_height = 16, .letter_spacing = 0.5, .family = Family.plain };

    /// Every step, largest first. Useful for anything that walks the scale
    /// (a type-spec preview, a font-loading pass) without repeating names.
    pub const all = [_]FontConfig{
        display_large, display_medium, display_small,
        headline_large, headline_medium, headline_small,
        title_large, title_medium, title_small,
        body_large, body_medium, body_small,
        label_large, label_medium, label_small,
    };
};

// Current → M3 mapping, so the migration
// table survives the port:
//
//   fontSizeMini    (11)  → labelSmall   (11sp medium)
//   fontSizeCaption (13)  → bodyMedium   (14sp regular)
//   fontSizeBody    (14)  → bodyMedium   (14sp regular)
//   fontSizeTitle   (16)  → titleMedium  (16sp medium)
//   fontSizeHeader  (20)  → headlineSmall(24sp regular)
//   button text     (13)  → labelLarge   (14sp medium)
//   tab label              → titleSmall  (14sp medium)

const std = @import("std");

test "m3-tokens-type-scale: 15 steps, descending within each family" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 15), TypeScale.all.len);
    // The scale descends *within* a family, not across the whole ladder —
    // titleSmall (14) is smaller than bodyLarge (16), so a global monotonic
    // check would be wrong. Each family is a run of three, largest first.
    var fam: usize = 0;
    while (fam < 5) : (fam += 1) {
        const base = fam * 3;
        try t.expect(TypeScale.all[base + 1].size < TypeScale.all[base].size);
        try t.expect(TypeScale.all[base + 2].size < TypeScale.all[base + 1].size);
    }
    // The family *heads* do descend globally — that is the ladder's shape.
    try t.expect(TypeScale.display_large.size > TypeScale.headline_large.size);
    try t.expect(TypeScale.headline_large.size > TypeScale.title_large.size);
    try t.expect(TypeScale.title_large.size > TypeScale.body_large.size);
    try t.expect(TypeScale.body_large.size > TypeScale.label_large.size);
}

test "m3-tokens-type-scale: line-height always exceeds size" {
    const t = std.testing;
    // A step whose line box is tighter than its em would clip descenders.
    for (TypeScale.all) |fc| {
        try t.expect(fc.line_height > fc.size);
        try t.expect(fc.weight >= 100 and fc.weight <= 900);
    }
    // DisplayLarge pulls its tracking in — the only negative letter-spacing
    // in the scale, and the reason letter_spacing is a per-step field.
    try t.expect(TypeScale.display_large.letter_spacing < 0.0);
}
