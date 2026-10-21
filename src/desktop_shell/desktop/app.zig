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
