const std = @import("std");
const prefs = @import("preferences.zig");
const icon_item = @import("icon_item.zig");
const menu = @import("menu.zig");
const icon_menu = @import("icon_menu.zig");

/// Desktop layer + app state machine (Wayland-free), plus the
/// dispatch priorities and pointer buttons.
///
/// Real Wayland surfaces/fds stay in the standalone binary; this module owns
/// every decision the UI makes: which layer the pointer is on, marquee drag
/// state, icon drag group, which menu is open, and the press/motion/release
/// routing order (open-with → world-clock → mount dialog → icon menu →
/// desktop menu → icons → marquee).
pub const LayerTarget = enum { auto, all, named };

/// Whether a targeted repaint may touch this surface. Pointer hot paths pass
/// the surface the gesture started on; `null` means a full repaint.
pub fn surfaceSelected(only_surf: ?usize, surf_idx: usize) bool {
    if (only_surf) |only| return surf_idx == only;
    return true;
}

/// The marquee is anchored to the surface where the drag started. It must
/// never be mirrored onto another output's icon layer.
pub fn marqueeOnSurface(marquee_dragging: bool, marquee_layer: usize, surf_idx: usize) bool {
    return marquee_dragging and marquee_layer == surf_idx;
}

/// Surface-local rectangle used for incremental icon-layer damage. The icon
/// drag hot path clears and repaints only the old and new cell rectangles
/// instead of clearing the full 2560x1440 layer every motion frame.
pub const DamageRect = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
};

/// One icon cell expanded by `bleed` (antialiasing/text overshoot) and
/// clipped to the surface. null when the cell is entirely off-surface.
pub fn damageCell(
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    bleed: f64,
    surf_w: i32,
    surf_h: i32,
) ?DamageRect {
    if (w <= 0 or h <= 0 or surf_w <= 0 or surf_h <= 0) return null;
    const sw: f64 = @floatFromInt(surf_w);
    const sh: f64 = @floatFromInt(surf_h);
    const r = DamageRect{
        .x0 = @max(0.0, x - bleed),
        .y0 = @max(0.0, y - bleed),
        .x1 = @min(sw, x + w + bleed),
        .y1 = @min(sh, y + h + bleed),
    };
    if (r.x1 <= r.x0 or r.y1 <= r.y0) return null;
    return r;
}

pub fn damageRectUnion(a: DamageRect, b: DamageRect) DamageRect {
    return .{
        .x0 = @min(a.x0, b.x0),
        .y0 = @min(a.y0, b.y0),
        .x1 = @max(a.x1, b.x1),
        .y1 = @max(a.y1, b.y1),
    };
}

pub fn damageRectArea(r: DamageRect) f64 {
    return @max(0.0, r.x1 - r.x0) * @max(0.0, r.y1 - r.y0);
}

pub fn damageRectsOverlap(a: DamageRect, b: DamageRect) bool {
    return a.x1 > b.x0 and a.x0 < b.x1 and a.y1 > b.y0 and a.y0 < b.y1;
}

/// One pooled icon buffer's baseline: the dragged icon index and cell origin
/// that the pixels in that slot currently show.
pub const IconDragSlot = struct {
    valid: bool = false,
    drag_idx: i32 = -1,
    drag_x: f64 = 0,
    drag_y: f64 = 0,
};

/// Per-surface, per-pool-slot drag baselines. A slot painted before the drag
/// starts must be fully repainted once; only after that may its next frame be
/// an old/new-cell repair. Full paints caused by the drag itself must not
/// invalidate already-caught-up slots or the pool never warms up.
pub const IconDragBuffers = struct {
    slots: [3]IconDragSlot = .{ .{}, .{}, .{} },

    pub fn reset(self: *IconDragBuffers) void {
        self.slots = .{ .{}, .{}, .{} };
    }

    pub fn get(self: *const IconDragBuffers, index: usize) IconDragSlot {
        if (index >= self.slots.len) return .{};
        return self.slots[index];
    }

    pub fn eligible(self: *const IconDragBuffers, index: usize, drag_idx: i32) bool {
        const s = self.get(index);
        return s.valid and s.drag_idx == drag_idx;
    }

    pub fn recordPartial(self: *IconDragBuffers, index: usize, drag_idx: i32, x: f64, y: f64) void {
        if (index >= self.slots.len) return;
        self.slots[index] = .{ .valid = true, .drag_idx = drag_idx, .drag_x = x, .drag_y = y };
    }

    /// A full icon-layer paint. `scene_changed` means the pixels of every
    /// other slot are stale too (press, hover, rescan); a catch-up full paint
    /// during an active drag only updates the slot it painted.
    pub fn recordFull(self: *IconDragBuffers, index: usize, drag_idx: i32, x: f64, y: f64, scene_changed: bool) void {
        if (scene_changed) self.reset();
        if (drag_idx >= 0) self.recordPartial(index, drag_idx, x, y);
    }
};

/// Output target selection (`create_layers`: `trim(dock.outputName||app.outputName)`,
/// auto/empty → min global, `all` → all, else name match).
pub fn selectOutputs(
    alloc: std.mem.Allocator,
    wanted: []const u8,
    names: []const []const u8,
    global_x: []const i32,
) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(alloc);
    const w = std.mem.trim(u8, wanted, " \t");
    if (w.len == 0 or std.mem.eql(u8, w, "auto")) {
        if (names.len == 0) return out.toOwnedSlice(alloc);
        var best: usize = 0;
        for (1..names.len) |i| {
            if (global_x[i] < global_x[best]) best = i;
        }
        try out.append(alloc, best);
        return out.toOwnedSlice(alloc);
    }
    if (std.mem.eql(u8, w, "all")) {
        for (0..names.len) |i| try out.append(alloc, i);
        return out.toOwnedSlice(alloc);
    }
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, std.mem.trim(u8, n, " \t"), w)) try out.append(alloc, i);
    }
    return out.toOwnedSlice(alloc);
}

pub const MenuKind = enum { none, desktop, icon, mount_dialog, open_with };

/// Minimal app state for routing (pointer, drag, and menu flags).
pub const AppState = struct {
    pointer_layer: usize = 0,
    marquee_dragging: bool = false,
    marquee_layer: usize = 0,
    icon_dragging: bool = false,
    desktop_menu_open: bool = false,
    icon_menu_open: bool = false,
    mount_dialog_open: bool = false,
    open_with_open: bool = false,
    world_clock_open: bool = false,
    left_down: bool = false,

    /// Motion priority (`pointer_motion_marquee`, `:76-91`).
    pub fn motionTarget(self: AppState) MenuKind {
        if (self.open_with_open) return .open_with;
        if (self.world_clock_open) return .open_with;
        if (self.mount_dialog_open) return .mount_dialog;
        if (self.icon_menu_open) return .icon;
        if (self.desktop_menu_open) return .desktop;
        if (self.icon_dragging) return .none;
        if (self.marquee_dragging) return .none;
        return .none;
    }

    /// Release priority (`pointer_button_left_release_marquee`, `:93-122`).
    pub fn releaseTarget(self: AppState, left_button: bool) MenuKind {
        if (!left_button) return .none;
        if (self.mount_dialog_open) return .mount_dialog;
        if (self.world_clock_open) return .open_with;
        if (self.icon_menu_open) return .icon;
        if (self.desktop_menu_open) return .desktop;
        if (self.icon_dragging) return .none;
        if (self.marquee_dragging) return .none;
        return .none;
    }

    /// Press priority (`desktop_left_press_marquee`, `:124-154`).
    pub fn pressTarget(self: AppState) MenuKind {
        if (self.open_with_open) return .open_with;
        if (self.world_clock_open) return .open_with;
        if (self.icon_menu_open) return .icon;
        if (self.desktop_menu_open) return .desktop;
        if (self.mount_dialog_open) return .mount_dialog;
        if (self.icon_dragging) return .none;
        return .none;
    }
};

/// Layer enabled flag (`layer_enabled`: `EH_DISABLE_DESKTOP_LAYER != 1`).
pub fn layerEnabled(env_val: ?[]const u8) bool {
    const e = env_val orelse return true;
    return !(e.len > 0 and e[0] == '1');
}

/// Icons enabled flag (`EH_DISABLE_DESKTOP_ICONS != 1` + prefs visible).
pub fn iconsEnabled(env_val: ?[]const u8, prefs_visible: bool) bool {
    if (env_val) |e| {
        if (e.len > 0 and e[0] == '1') return false;
    }
    return prefs_visible;
}

test "app: output selection" {
    const t = std.testing;
    const names = [_][]const u8{ "HDMI-1", "DP-1" };
    const gx = [_]i32{ 1920, 0 };
    const a = try selectOutputs(t.allocator, "", &names, &gx);
    defer t.allocator.free(a);
    try t.expectEqual(@as(usize, 1), a.len);
    try t.expectEqual(@as(usize, 1), a[0]);
    const b = try selectOutputs(t.allocator, "all", &names, &gx);
    defer t.allocator.free(b);
    try t.expectEqual(@as(usize, 2), b.len);
    const c = try selectOutputs(t.allocator, "HDMI-1", &names, &gx);
    defer t.allocator.free(c);
    try t.expectEqual(@as(usize, 1), c.len);
}

test "app: dispatch priorities" {
    const t = std.testing;
    var s = AppState{ .icon_menu_open = true, .desktop_menu_open = true };
    try t.expectEqual(MenuKind.icon, s.pressTarget());
    try t.expectEqual(MenuKind.icon, s.releaseTarget(true));
    s = .{ .marquee_dragging = true };
    try t.expectEqual(MenuKind.none, s.motionTarget());
    try t.expect(s.pressTarget() == .none);
    try t.expect(layerEnabled(null));
    try t.expect(!layerEnabled("1"));
    try t.expect(iconsEnabled(null, true));
    try t.expect(!iconsEnabled("1", true));
    try t.expect(!iconsEnabled(null, false));
    _ = prefs.metricsFor(.medium);
    _ = icon_item.margin;
    _ = menu.rowCount(.main);
    _ = icon_menu.compress_sub_rows;
}

test "app: targeted repaint stays on the drag surface" {
    const t = std.testing;
    const surfaces = 3;
    const drag_surface = 1;

    // Count which surfaces a motion frame would visit. The hot path passes
    // `drag_surface`; a full repaint passes null.
    var targeted: usize = 0;
    var full: usize = 0;
    var marquee: usize = 0;
    for (0..surfaces) |si| {
        if (surfaceSelected(drag_surface, si)) targeted += 1;
        if (surfaceSelected(null, si)) full += 1;
        if (marqueeOnSurface(true, drag_surface, si)) marquee += 1;
    }
    try t.expectEqual(@as(usize, 1), targeted);
    try t.expectEqual(@as(usize, surfaces), full);
    try t.expectEqual(@as(usize, 1), marquee);

    // No marquee paints when the gesture ended, and the selected surface is
    // still the only one touched after the pointer moves to another output.
    for (0..surfaces) |si| {
        try t.expect(!marqueeOnSurface(false, drag_surface, si));
    }
    var moved: usize = 0;
    for (0..surfaces) |si| {
        if (surfaceSelected(drag_surface, si)) moved += 1;
    }
    try t.expectEqual(@as(usize, 1), moved);
}

test "app: benchmark targeted vs full repaint surface visits" {
    const t = std.testing;
    const surfaces = 3;
    const frames = 100_000;
    var full_visits: usize = 0;
    var targeted_visits: usize = 0;
    for (0..frames) |_| {
        for (0..surfaces) |si| {
            if (surfaceSelected(null, si)) full_visits += 1;
            if (surfaceSelected(1, si)) targeted_visits += 1;
        }
    }
    // A 3-output drag used to visit 3x the surfaces for every motion frame.
    try t.expectEqual(frames * surfaces, full_visits);
    try t.expectEqual(frames, targeted_visits);
}

test "app: icon drag damage is a padded cell clipped to the surface" {
    const t = std.testing;
    // Medium metrics: 104x88 cells on a 2560x1440 output, 4px bleed.
    const cell = damageCell(100, 200, 104, 88, 4, 2560, 1440).?;
    try t.expectEqual(@as(f64, 96), cell.x0);
    try t.expectEqual(@as(f64, 196), cell.y0);
    try t.expectEqual(@as(f64, 208), cell.x1);
    try t.expectEqual(@as(f64, 292), cell.y1);

    // A cell crossing the bottom/right edge is clipped, not dropped.
    const edge = damageCell(2550, 1430, 104, 88, 4, 2560, 1440).?;
    try t.expectEqual(@as(f64, 2560), edge.x1);
    try t.expectEqual(@as(f64, 1440), edge.y1);

    // Fully off-surface cells produce no damage.
    try t.expect(damageCell(-300, 100, 104, 88, 4, 2560, 1440) == null);
    try t.expect(damageCell(100, 1500, 104, 88, 4, 2560, 1440) == null);

    const moved = damageCell(120, 216, 104, 88, 4, 2560, 1440).?;
    const dirty = damageRectUnion(cell, moved);
    try t.expectEqual(@as(f64, 96), dirty.x0);
    try t.expectEqual(@as(f64, 196), dirty.y0);
    try t.expectEqual(@as(f64, 228), dirty.x1);
    try t.expectEqual(@as(f64, 308), dirty.y1);
    try t.expect(damageRectsOverlap(cell, moved));
    try t.expect(!damageRectsOverlap(cell, damageCell(800, 800, 104, 88, 4, 2560, 1440).?));
}

test "app: icon drag pool slots catch up then repair incrementally" {
    const t = std.testing;
    var bufs: IconDragBuffers = .{};
    try t.expect(!bufs.eligible(0, 7));

    // Press paints slot 0 and changes the scene (selection/pressed plate);
    // every other slot is now stale.
    bufs.recordFull(0, 7, 100, 100, true);
    try t.expect(bufs.eligible(0, 7));
    try t.expect(!bufs.eligible(1, 7));
    try t.expect(!bufs.eligible(2, 7));

    // The first motion frames land on the cold slots. These full paints are
    // part of the drag, so slot 0 must keep its baseline instead of being
    // invalidated by the catch-up.
    bufs.recordFull(1, 7, 104, 100, false);
    bufs.recordFull(2, 7, 108, 100, false);
    for (0..3) |i| try t.expect(bufs.eligible(i, 7));

    // All slots warm: every subsequent frame is an old/new-cell repair.
    bufs.recordPartial(1, 7, 112, 100);
    try t.expectEqual(@as(f64, 112), bufs.get(1).drag_x);
    try t.expectEqual(@as(i32, 7), bufs.get(1).drag_idx);

    // A new scene (hover/press/rescan) invalidates every slot again.
    bufs.recordFull(0, 7, 116, 100, true);
    try t.expect(bufs.eligible(0, 7));
    try t.expect(!bufs.eligible(1, 7));
    try t.expect(!bufs.eligible(2, 7));

    // A different icon can never inherit the previous drag's baseline.
    try t.expect(!bufs.eligible(0, 8));
}

test "app: benchmark icon drag damage stays under 2% of the layer" {
    const t = std.testing;
    const frames = 100_000;
    const surf_w = 2560;
    const surf_h = 1440;
    const surf_area: f64 = @as(f64, @floatFromInt(surf_w)) * @as(f64, @floatFromInt(surf_h));
    var worst: f64 = 0;
    var total: f64 = 0;
    for (0..frames) |f| {
        // A normal 400Hz motion step moves the cell a few pixels; sweep the
        // whole 40px range to bound the worst case.
        const step: f64 = @floatFromInt(f % 40);
        const old = damageCell(100, 200, 104, 88, 4, surf_w, surf_h).?;
        const new = damageCell(100 + step, 200 + step * 0.5, 104, 88, 4, surf_w, surf_h).?;
        const area = damageRectArea(damageRectUnion(old, new));
        worst = @max(worst, area);
        total += area;
    }
    // A full icon-layer clear is 3,686,400 px. Incremental drag damage is two
    // ~112x96 cells; even the worst 40px step remains far below 2%.
    try t.expect(worst < surf_area * 0.02);
    try t.expect(total / @as(f64, @floatFromInt(frames)) < surf_area * 0.01);
}
