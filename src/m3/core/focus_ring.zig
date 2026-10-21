//! Focus-ring re-export.
//!
//! `FocusRing` is *defined* over
//! there alongside `StateLayer` rather than in this file. The Zig port keeps
//! the file so the tree stays a 1:1 mirror of `src/m3/`, and re-exports the
//! type so `@import("focus_ring.zig").FocusRing` reads the same.

pub const FocusRing = @import("primitives/state_layer.zig").FocusRing;
pub const StateLayer = @import("primitives/state_layer.zig").StateLayer;

const std = @import("std");

test "m3-focus-ring: the shim exposes the state_layer type" {
    const t = std.testing;
    // Re-exporting must be the *same* type, not a copy — a distinct type
    // here would silently break anything storing both spellings.
    try t.expect(FocusRing == @import("primitives/state_layer.zig").FocusRing);
    var ring = FocusRing{};
    ring.setFocused(true);
    try t.expect(ring.focused);
}
