//! Slot assembly and section widths (measure half).
//!
//! The paint pass and `taskbar_measure_sections` share one source of truth:
//! pinned slots in settings order, then running groups not covered by a pin,
//! tray items packed together, and the gap rules below. Win7 tasklist mode
//! supersedes the classic pinned/running strips bar-wide.

const std = @import("std");
const types = @import("types.zig");
const settings_mod = @import("settings.zig");

pub const Slot = struct {
    kind: types.SlotKind = .app,
    key: []const u8 = "",
    chosen_serial: u64 = 0,
    is_pinned: bool = false,
    win7: bool = false,
};

/// Gap between two adjacent slots. Tray items pack together; app groups pack
/// only when their tray pill is on. Everything else takes `gap`.
pub fn gapBetween(a: *const Slot, b: *const Slot, gap: f64, pinned_pill: bool, running_pill: bool) f64 {
    if (a.kind == .tray and b.kind == .tray) return 0;
    if (a.kind == .app and a.is_pinned and b.kind == .app and b.is_pinned)
        return if (pinned_pill) 0 else gap;
    if (a.kind == .app and !a.is_pinned and b.kind == .app and !b.is_pinned)
        return if (running_pill) 0 else gap;
    return gap;
}

pub fn sectionWidth(slots: []const Slot, widths: []const f64, gap: f64, pinned_pill: bool, running_pill: bool) f64 {
    var tw: f64 = 0;
    for (slots, 0..) |*s, i| {
        tw += widths[i];
        if (i + 1 < slots.len) tw += gapBetween(s, &slots[i + 1], gap, pinned_pill, running_pill);
    }
    return tw;
}

/// Side-section anchors. The left group starts at the padded edge and the
/// right group ends at the padded edge, unconditionally: an empty center
/// never slides the left group toward the right one (C++ panel parity —
/// `panelLeftX = x + stripPad`, `panelRightX = x + boxW - stripPad - rw`).
/// When the center is present it is balanced in the free run between these
/// two anchors; when the sections cannot fit the caller falls back to the
/// centered strip.
pub fn sideAnchors(box_w: f64, strip_pad: f64, rw: f64) struct { left_x: f64, right_x: f64 } {
    return .{
        .left_x = strip_pad,
        .right_x = box_w - strip_pad - rw,
    };
}

/// Uniform scale when the strip overflows the bar. 1.0 when it fits.
pub fn stripHScale(box_w: f64, total_w: f64, inner: f64) f64 {
    const avail = @max(1.0, box_w - inner);
    if (total_w <= avail) return 1.0;
    return avail / total_w;
}

/// Shrink-to-fit label budget: narrow each label's max width by an equal
/// share of the overflow, floored at the minimum. 0 labels → full width.
pub fn shrinkLabelMaxW(max_w: f64, min_w: f64, overflow: f64, n_labeled: usize) f64 {
    if (n_labeled == 0 or overflow <= 0) return max_w;
    return @max(min_w, max_w - overflow / @as(f64, @floatFromInt(n_labeled)));
}

pub fn labelMaxW(ui_scale: f64, eff_max_w: f64) f64 {
    if (eff_max_w > 0) return eff_max_w;
    return 140.0 * ui_scale;
}

pub fn labelMinW(ui_scale: f64) f64 {
    return 40.0 * ui_scale;
}

pub fn labelFontPx(ui_scale: f64) f64 {
    return 12.0 * ui_scale;
}

/// Extra slot width for a label: icon gap + capped text + trailing pad.
/// 0 when the slot stays icon-only.
pub fn labelExtraW(label_w: f64, ui_scale: f64) f64 {
    if (label_w <= 0) return 0;
    return 6.0 * ui_scale + label_w + 8.0 * ui_scale;
}

/// Icon side clamped to fit the bar with 4 px breathing room per side —
/// the same clamp the paint pass applies before measuring.
pub fn clampIcon(icon_raw: f64, box_h: f64) f64 {
    return std.math.clamp(icon_raw, 8.0, @max(8.0, box_h - 8.0));
}

pub fn uiScale(taskbar_scale: f64, global_scale: f64) f64 {
    return std.math.clamp(taskbar_scale, 0.5, 2.0) * std.math.clamp(global_scale, 0.5, 2.0);
}

test "taskbar-slots: gaps pack pills" {
    const t = std.testing;
    const a = Slot{ .kind = .tray };
    const b = Slot{ .kind = .tray };
    try t.expectEqual(@as(f64, 0), gapBetween(&a, &b, 8, false, false));
    const p1 = Slot{ .kind = .app, .is_pinned = true };
    const p2 = Slot{ .kind = .app, .is_pinned = true };
    try t.expectEqual(@as(f64, 0), gapBetween(&p1, &p2, 8, true, false));
    try t.expectEqual(@as(f64, 8), gapBetween(&p1, &p2, 8, false, false));
    const r1 = Slot{ .kind = .app };
    const r2 = Slot{ .kind = .app };
    try t.expectEqual(@as(f64, 0), gapBetween(&r1, &r2, 8, false, true));
}

test "taskbar-slots: side anchors stay at the padded edges" {
    const t = std.testing;
    // The left group keeps the padded start and the right group the padded
    // end even with an empty center: sections never slide together.
    const a = sideAnchors(1000, 16, 240);
    try t.expectEqual(@as(f64, 16), a.left_x);
    try t.expectEqual(@as(f64, 744), a.right_x);
    // Narrow bar: same anchors, the caller's fit check handles the overlap.
    const b = sideAnchors(400, 16, 240);
    try t.expectEqual(@as(f64, 16), b.left_x);
    try t.expectEqual(@as(f64, 144), b.right_x);
}

test "taskbar-slots: strip shrink + label budgets" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 1.0), stripHScale(800, 400, 32));
    try t.expect(stripHScale(400, 800, 32) < 1.0);
    try t.expectEqual(@as(f64, 90.0), shrinkLabelMaxW(140, 40, 100, 2));
    try t.expectEqual(@as(f64, 40.0), shrinkLabelMaxW(140, 40, 1000, 2));
    try t.expectEqual(@as(f64, 32.0), clampIcon(64, 40));
    _ = settings_mod.stripPadPx(1.0);
}
