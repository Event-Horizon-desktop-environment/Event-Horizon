//! Where a dock popup sits, expressed as the two layer-shell margins that put
//! it there.
//!
//! A layer surface anchored into a corner is positioned entirely by margins,
//! so "centre this on the slot that opened it, but never let it leave the
//! screen" turns out to be a small arithmetic problem rather than a layout
//! one. Solving it here, alone, is what lets the answer be pinned down by
//! tests instead of by looking at a running shell.
//!
//! The units are the compositor's surface-local ones — the same units the
//! popup's own size and the dock's configured width are measured in.

const std = @import("std");

pub const Input = struct {
    /// Where the thing that opened the popup runs to horizontally. The popup
    /// is centred on it, so this is the slot's centre rather than its edge.
    anchor_x: f64,
    /// How big the popup wants to be.
    popup_w: f64,
    /// How wide the dock is, and where the dock's own left edge sits on the
    /// output. The panel may hang past the end of the dock — a slot near one
    /// end would otherwise shove it off the screen — but never past the edge
    /// of the output itself.
    layer_w: f64,
    layer_origin_x: f64,
    /// The output's width, or 0 when it is not known, in which case the
    /// dock's own width is all there is to clamp against. A compositor that
    /// picks the output leaves a client with no way to ask which one it was
    /// given, so 0 is a state this has to handle rather than an error.
    output_w: f64 = 0,
    /// How far the popup's bottom edge sits above the output's bottom edge —
    /// the dock's own height plus whatever gap makes it read as hovering.
    bottom_clearance: f64,
};

pub const Placed = struct {
    margin_left: f64,
    margin_bottom: f64,
};

/// The margins that centre a `popup_w`-wide popup on `anchor_x` while keeping
/// it on screen.
///
/// Centring first and clamping afterwards is the whole design: an unclamped
/// centre puts a panel near the end of a short dock half off the output, and
/// a clamp applied to the *anchor* rather than to the offset would drag the
/// panel away from the slot it belongs to. Clamping the offset means the panel
/// only stops being centred when it has to.
pub fn place(in: Input) Placed {
    const want_left = in.anchor_x - in.popup_w * 0.5;

    // Two ceilings, and the panel obeys the looser one. Staying inside the
    // dock is the everyday case; staying inside the output is what allows a
    // slot near the dock's end to pull the panel out over the empty space
    // beside it, which is where the dock being narrower than the output
    // actually matters.
    const max_from_layer = @max(0.0, in.layer_w - in.popup_w);
    const max_from_output = if (in.output_w > 0)
        @max(0.0, in.output_w - in.popup_w - in.layer_origin_x)
    else
        max_from_layer;

    return .{
        .margin_left = in.layer_origin_x + std.math.clamp(want_left, 0.0, @max(max_from_layer, max_from_output)),
        .margin_bottom = in.bottom_clearance,
    };
}

test "popup-position: a centred panel lands under its anchor" {
    const t = std.testing;
    const p = place(.{
        .anchor_x = 500.0,
        .popup_w = 200.0,
        .layer_w = 1000.0,
        .layer_origin_x = 0.0,
        .bottom_clearance = 90.0,
    });
    try t.expectEqual(@as(f64, 400.0), p.margin_left);
    try t.expectEqual(@as(f64, 90.0), p.margin_bottom);
}

test "popup-position: the panel is moved by the dock's own offset on the output" {
    const t = std.testing;
    // A dock 400 px wide, centred on a 1200 px output, starts at x=400. A slot
    // 100 px along the dock is at 500 on the output, and a 200 px panel
    // centred on it starts at 400 on the output — 0 further along the dock.
    const p = place(.{
        .anchor_x = 100.0,
        .popup_w = 200.0,
        .layer_w = 400.0,
        .layer_origin_x = 400.0,
        .output_w = 1200.0,
        .bottom_clearance = 0.0,
    });
    try t.expectEqual(@as(f64, 400.0), p.margin_left);
}

test "popup-position: a panel that would fall off either end is held on" {
    const t = std.testing;
    const in = Input{
        .anchor_x = 0.0,
        .popup_w = 200.0,
        .layer_w = 1000.0,
        .layer_origin_x = 0.0,
        .output_w = 0.0,
        .bottom_clearance = 0.0,
    };
    // Left of the first slot there is nowhere to put half a panel, so it
    // lines up with the dock's edge instead.
    try t.expectEqual(@as(f64, 0.0), place(in).margin_left);

    // And past the last slot it stops at the dock's right edge.
    var right = in;
    right.anchor_x = 980.0;
    try t.expectEqual(@as(f64, 800.0), place(right).margin_left);
}

test "popup-position: the output lets a narrow dock's panel reach past its end" {
    const t = std.testing;
    // A 400 px dock on a 1200 px output starts at 400, so there is room to the
    // right of the dock that the panel may use before it has to stop centring.
    const p = place(.{
        .anchor_x = 390.0,
        .popup_w = 200.0,
        .layer_w = 400.0,
        .layer_origin_x = 400.0,
        .output_w = 1200.0,
        .bottom_clearance = 0.0,
    });
    // Centred that would be 290 along the dock, which is past the dock's own
    // 200 px ceiling but inside the output's 600 px one.
    try t.expectEqual(@as(f64, 690.0), p.margin_left);
}

test "popup-position: an unknown output falls back to the dock's own width" {
    const t = std.testing;
    // `output_w == 0` is the state a client is stuck in when the compositor
    // chose the output. The clamp still has to hold the panel on screen.
    const p = place(.{
        .anchor_x = 980.0,
        .popup_w = 200.0,
        .layer_w = 1000.0,
        .layer_origin_x = 0.0,
        .bottom_clearance = 12.0,
    });
    try t.expectEqual(@as(f64, 800.0), p.margin_left);
    try t.expectEqual(@as(f64, 12.0), p.margin_bottom);
}
