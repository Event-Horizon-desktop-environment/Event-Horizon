//! Taskbar section expansion: widget tokens → paint slots.
//!
//! Slot-assembly half (pinned/running/tray collection plus the
//! `win7_slot_descs` override). Sources borrow from the config and the live
//! trackers; the returned lists are owned.

const std = @import("std");
const schema = @import("../../config/schema.zig");
const dw = @import("../dock/widgets.zig");
const paths = @import("../common/paths.zig");
const types = @import("types.zig");

pub const Slot = types.PaintSlot;

pub const Pin = struct {
    raw: []const u8 = "",
    norm: []const u8 = "",
};

/// One running group: an app id (or a per-window `__eh_tl_<serial>` key when
/// grouping is off) with the window to show/activate and its state.
pub const Group = struct {
    key: []const u8 = "",
    icon_id: []const u8 = "",
    serial: u64 = 0,
    active: bool = false,
};

pub const Ctx = struct {
    pinned: []const Pin = &.{},
    running: []const Group = &.{},
    tray_keys: []const []const u8 = &.{},
};

fn isWin7Token(cfg: *const schema.ShellConfig, wid: []const u8) bool {
    if (std.mem.eql(u8, wid, "win7_tasks")) return true;
    return std.mem.eql(u8, dw.implType(cfg, wid), "win7_tasks");
}

/// A placed + enabled Win7 tasklist supersedes the classic pinned/running
/// strips bar-wide — otherwise every window renders twice.
pub fn win7Active(cfg: *const schema.ShellConfig) bool {
    const sections = [_][]const []const u8{
        cfg.taskbar.left_widgets,
        cfg.taskbar.center_widgets,
        cfg.taskbar.right_widgets,
    };
    for (sections) |sec| {
        for (sec) |wid| {
            if (!isWin7Token(cfg, wid)) continue;
            if (dw.instanceEnabled(cfg, wid)) return true;
        }
    }
    return false;
}

/// Taskbar `widget_blocked`: with widgets off only the structural app/tray
/// buttons survive. This rule applies in both measure and paint.
pub fn blocked(widgets_enabled: bool, cfg: *const schema.ShellConfig, token: []const u8) bool {
    if (widgets_enabled) return false;
    if (std.mem.eql(u8, token, "pinned_apps") or
        std.mem.eql(u8, token, "running_apps") or
        std.mem.eql(u8, token, "win7_tasks")) return false;
    if (dw.tokenIsSystemTray(cfg, token)) return false;
    if (std.mem.eql(u8, token, "settings_button") or
        std.mem.eql(u8, token, "audio_center_button") or
        std.mem.eql(u8, token, "distro_spotlight") or
        std.mem.eql(u8, token, "app_menu") or
        std.mem.eql(u8, token, "trash")) return false;
    const impl = dw.implType(cfg, token);
    const ornamental = [_][]const u8{
        "clock", "world_clock", "weather", "media", "workspaces",
        "control_center", "notifications", "volume_mixer",
        "app_drawer", "overview", "layout",
    };
    for (ornamental) |o| {
        if (std.mem.eql(u8, impl, o)) return true;
    }
    return false;
}

/// Pin → running-group identity. Grouped groups carry the app id in `key`;
/// ungrouped (`__eh_tl_<serial>`) groups carry it in `icon_id`. Both must
/// match a pin, mirroring C++'s `pinMatchKey` merge.
fn pinMatchesGroup(p: Pin, g: Group) bool {
    if (paths.sameAppId(p.norm, g.key) or paths.sameAppId(p.raw, g.key)) return true;
    if (g.icon_id.len == 0) return false;
    return paths.sameAppId(p.norm, g.icon_id) or paths.sameAppId(p.raw, g.icon_id);
}

fn coveredByPin(pins: []const Pin, g: Group) bool {
    for (pins) |p| {
        if (pinMatchesGroup(p, g)) return true;
    }
    return false;
}

/// Unified Win7 buttons: pins in settings order (with running state), then
/// running groups no pin covers — one slot per app, launch-or-switch.
fn appendWin7(
    alloc: std.mem.Allocator,
    cfg: *const schema.ShellConfig,
    ctx: *const Ctx,
    out: *std.ArrayList(Slot),
) !void {
    for (ctx.pinned) |p| {
        if (std.mem.eql(u8, p.norm, "unknown")) continue;
        if (std.mem.eql(u8, p.norm, "event-horizon-settings") or
            std.mem.eql(u8, p.norm, "event-horizon-rail-settings")) continue;
        var s = Slot{ .kind = .app, .key = p.norm, .icon_id = p.raw, .is_pinned = true, .win7 = true };
        for (ctx.running) |rg| {
            if (pinMatchesGroup(p, rg)) {
                s.chosen_serial = rg.serial;
                s.any_activated = rg.active;
                if (rg.icon_id.len > 0) s.icon_id = rg.icon_id;
                break;
            }
        }
        _ = cfg;
        try out.append(alloc, s);
    }
    for (ctx.running) |rg| {
        if (coveredByPin(ctx.pinned, rg)) continue;
        try out.append(alloc, .{
            .kind = .app,
            .key = rg.key,
            .icon_id = rg.icon_id,
            .chosen_serial = rg.serial,
            .any_activated = rg.active,
            .win7 = true,
        });
    }
}

fn appendToken(
    alloc: std.mem.Allocator,
    cfg: *const schema.ShellConfig,
    ctx: *const Ctx,
    win7: bool,
    token: []const u8,
    out: *std.ArrayList(Slot),
) !void {
    if (std.mem.eql(u8, token, "pinned_apps")) {
        if (win7) return;
        for (ctx.pinned) |p| {
            if (std.mem.eql(u8, p.norm, "unknown")) continue;
            if (std.mem.eql(u8, p.norm, "event-horizon-settings") or
            std.mem.eql(u8, p.norm, "event-horizon-rail-settings")) continue;
            var s = Slot{ .kind = .app, .key = p.norm, .icon_id = p.raw, .is_pinned = true };
            for (ctx.running) |rg| {
                if (pinMatchesGroup(p, rg)) {
                    s.chosen_serial = rg.serial;
                    s.any_activated = rg.active;
                    if (rg.icon_id.len > 0) s.icon_id = rg.icon_id;
                    break;
                }
            }
            try out.append(alloc, s);
        }
    } else if (std.mem.eql(u8, token, "running_apps")) {
        if (win7) return;
        for (ctx.running) |rg| {
            if (coveredByPin(ctx.pinned, rg)) continue;
            try out.append(alloc, .{
                .kind = .app,
                .key = rg.key,
                .icon_id = rg.icon_id,
                .chosen_serial = rg.serial,
                .any_activated = rg.active,
            });
        }
    } else if (isWin7Token(cfg, token)) {
        try appendWin7(alloc, cfg, ctx, out);
    } else if (dw.tokenIsSystemTray(cfg, token)) {
        for (ctx.tray_keys) |k| try out.append(alloc, .{ .kind = .tray, .key = k });
    } else if (std.mem.eql(u8, token, "settings_button") or
        std.mem.eql(u8, token, "rail_settings"))
    {
        try out.append(alloc, .{ .kind = .settings, .key = token });
    } else if (std.mem.eql(u8, token, "audio_center_button") or
        std.mem.eql(u8, dw.implType(cfg, token), "audio_center"))
    {
        try out.append(alloc, .{ .kind = .audio_center, .key = token });
    } else if (std.mem.eql(u8, token, "distro_spotlight")) {
        try out.append(alloc, .{ .kind = .spotlight, .key = token });
    } else if (std.mem.eql(u8, token, "app_menu")) {
        try out.append(alloc, .{ .kind = .app_menu, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "app_drawer")) {
        try out.append(alloc, .{ .kind = .app_drawer, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "smenu")) {
        try out.append(alloc, .{ .kind = .smenu, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "clock")) {
        try out.append(alloc, .{ .kind = .clock, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "weather")) {
        try out.append(alloc, .{ .kind = .weather, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "media")) {
        try out.append(alloc, .{ .kind = .media, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "workspaces")) {
        try out.append(alloc, .{ .kind = .workspaces, .key = token });
    } else if (dw.isPearInstance(cfg, token)) {
        // Pear before the shared `control_center` implementation mapping:
        // `implType` keeps reporting "control_center" for the legacy
        // consumers, the raw instance is what decides here.
        try out.append(alloc, .{ .kind = .pear_center, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "control_center")) {
        try out.append(alloc, .{ .kind = .control_center, .key = token });
    } else if (std.mem.eql(u8, token, "trash") or std.mem.eql(u8, dw.implType(cfg, token), "trash")) {
        try out.append(alloc, .{ .kind = .trash, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "volume_mixer")) {
        try out.append(alloc, .{ .kind = .volume_mixer, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "battery")) {
        try out.append(alloc, .{ .kind = .battery, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "bluetooth")) {
        try out.append(alloc, .{ .kind = .bluetooth, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "vpn")) {
        try out.append(alloc, .{ .kind = .vpn, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "layout")) {
        try out.append(alloc, .{ .kind = .layout, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "overview")) {
        try out.append(alloc, .{ .kind = .overview, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "world_clock")) {
        try out.append(alloc, .{ .kind = .world_clock, .key = token });
    } else if (std.mem.eql(u8, dw.implType(cfg, token), "clipstack")) {
        try out.append(alloc, .{ .kind = .clipstack, .key = token });
    }
}

pub fn buildSection(
    alloc: std.mem.Allocator,
    cfg: *const schema.ShellConfig,
    tokens: []const []const u8,
    ctx: *const Ctx,
    win7: bool,
    out: *std.ArrayList(Slot),
) !void {
    for (tokens) |tok| {
        if (!dw.instanceEnabled(cfg, tok)) continue;
        if (blocked(cfg.taskbar.widgets_enabled, cfg, tok)) continue;
        try appendToken(alloc, cfg, ctx, win7, tok, out);
    }
}

pub const Sections = struct {
    left: []Slot = &.{},
    center: []Slot = &.{},
    right: []Slot = &.{},
    all: []Slot = &.{},
    win7: bool = false,

    pub fn deinit(self: *Sections, alloc: std.mem.Allocator) void {
        alloc.free(self.left);
        alloc.free(self.center);
        alloc.free(self.right);
        alloc.free(self.all);
        self.* = .{};
    }
};

/// Expand the taskbar's three widget lists. `all` concatenates the sections
/// for the overflow/measure pass.
pub fn buildAll(
    alloc: std.mem.Allocator,
    cfg: *const schema.ShellConfig,
    ctx: *const Ctx,
) !Sections {
    const win7 = win7Active(cfg);
    var left: std.ArrayList(Slot) = .empty;
    errdefer left.deinit(alloc);
    var center: std.ArrayList(Slot) = .empty;
    errdefer center.deinit(alloc);
    var right: std.ArrayList(Slot) = .empty;
    errdefer right.deinit(alloc);
    try buildSection(alloc, cfg, cfg.taskbar.left_widgets, ctx, win7, &left);
    try buildSection(alloc, cfg, cfg.taskbar.center_widgets, ctx, win7, &center);
    try buildSection(alloc, cfg, cfg.taskbar.right_widgets, ctx, win7, &right);
    var all: std.ArrayList(Slot) = .empty;
    errdefer all.deinit(alloc);
    try all.appendSlice(alloc, left.items);
    try all.appendSlice(alloc, center.items);
    try all.appendSlice(alloc, right.items);
    return .{
        .left = try left.toOwnedSlice(alloc),
        .center = try center.toOwnedSlice(alloc),
        .right = try right.toOwnedSlice(alloc),
        .all = try all.toOwnedSlice(alloc),
        .win7 = win7,
    };
}

fn load(text: []const u8) !schema.Loaded {
    return schema.loadText(std.testing.allocator, text);
}

test "taskbar-strip: pinned then running, pins cover" {
    const t = std.testing;
    var cfg = try load(
        \\[taskbar]
        \\left_widgets = ["pinned_apps", "running_apps"]
    );
    defer cfg.deinit();
    const pins = [_]Pin{.{ .raw = "firefox", .norm = "firefox" }};
    const running = [_]Group{
        .{ .key = "firefox", .icon_id = "firefox", .serial = 7, .active = true },
        .{ .key = "kitty", .icon_id = "kitty", .serial = 9 },
    };
    const ctx = Ctx{ .pinned = &pins, .running = &running };
    var sec = try buildAll(t.allocator, &cfg.cfg, &ctx);
    defer sec.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), sec.left.len);
    try t.expect(sec.left[0].is_pinned);
    try t.expectEqual(@as(u64, 7), sec.left[0].chosen_serial);
    try t.expect(sec.left[0].any_activated);
    try t.expect(!sec.left[1].is_pinned);
    try t.expectEqualStrings("kitty", sec.left[1].key);
}

test "taskbar-strip: win7 supersedes classic strips" {
    const t = std.testing;
    var cfg = try load(
        \\[taskbar]
        \\left_widgets = ["pinned_apps", "running_apps", "win7_tasks"]
    );
    defer cfg.deinit();
    const pins = [_]Pin{.{ .raw = "firefox", .norm = "firefox" }};
    const running = [_]Group{.{ .key = "kitty", .icon_id = "kitty", .serial = 3 }};
    const ctx = Ctx{ .pinned = &pins, .running = &running };
    var sec = try buildAll(t.allocator, &cfg.cfg, &ctx);
    defer sec.deinit(t.allocator);
    try t.expect(sec.win7);
    // One win7 slot per app, each flagged — never doubled.
    try t.expectEqual(@as(usize, 2), sec.left.len);
    for (sec.left) |s| try t.expect(s.win7);
}

test "taskbar-strip: win7 merges pins with per-window groups" {
    const t = std.testing;
    var cfg = try load(
        \\[taskbar]
        \\left_widgets = ["win7_tasks"]
    );
    defer cfg.deinit();
    const pins = [_]Pin{.{ .raw = "firefox", .norm = "firefox" }};
    const running = [_]Group{
        .{ .key = "__eh_tl_3", .icon_id = "firefox", .serial = 3 },
        .{ .key = "__eh_tl_7", .icon_id = "firefox", .serial = 7, .active = true },
        .{ .key = "__eh_tl_9", .icon_id = "kitty", .serial = 9 },
    };
    const ctx = Ctx{ .pinned = &pins, .running = &running };
    var sec = try buildAll(t.allocator, &cfg.cfg, &ctx);
    defer sec.deinit(t.allocator);
    try t.expect(sec.win7);
    // The pin merges onto its app's windows (matching C++ `pinMatchKey` even
    // when grouping is off), so `__eh_tl_3` is covered; kitty's window stays.
    try t.expectEqual(@as(usize, 2), sec.left.len);
    try t.expect(sec.left[0].is_pinned);
    try t.expectEqualStrings("firefox", sec.left[0].key);
    try t.expectEqual(@as(u64, 3), sec.left[0].chosen_serial);
    try t.expectEqualStrings("__eh_tl_9", sec.left[1].key);
}

test "taskbar-strip: widgets off blocks ornaments" {
    const t = std.testing;
    var cfg = try load(
        \\[taskbar]
        \\widgets_enabled = false
        \\left_widgets = ["pinned_apps", "clock", "settings_button"]
    );
    defer cfg.deinit();
    const pins = [_]Pin{.{ .raw = "a", .norm = "a" }};
    const ctx = Ctx{ .pinned = &pins };
    var sec = try buildAll(t.allocator, &cfg.cfg, &ctx);
    defer sec.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), sec.left.len);
    try t.expectEqual(types.SlotKind.app, sec.left[0].kind);
    try t.expectEqual(types.SlotKind.settings, sec.left[1].kind);
}

test "taskbar-strip: rail_settings is a settings-kind rail slot" {
    const t = std.testing;
    var cfg = try load(
        \\[taskbar]
        \\left_widgets = ["rail_settings"]
    );
    defer cfg.deinit();
    const ctx = Ctx{};
    var sec = try buildAll(t.allocator, &cfg.cfg, &ctx);
    defer sec.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), sec.left.len);
    try t.expectEqual(types.SlotKind.settings, sec.left[0].kind);
    try t.expectEqualStrings("rail_settings", sec.left[0].key);
}
