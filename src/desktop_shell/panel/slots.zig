//! Panel slot expansion — port of `panel_append_widget` +
//! `panel_widget_blocked` + `panel_measure_sections`
//! (`src/desktop_shell/panel/paint/panel_paint.cpp:81-239`).
//!
//! Pure: the config supplies widget tokens, the host supplies the running
//! app keys and tray keys. Blocked/disabled instances never reach the strip;
//! `pinned_apps`/`running_apps` expand to one app slot per running group;
//! tray tokens expand to one slot per tray item; `app_menu`/`smenu`/
//! `spotlight`/`app_drawer` resolve but are skipped (C++ :174-176).

const std = @import("std");
const schema = @import("../../config/schema.zig");
const wset = @import("../widgets/shared/widget_settings.zig");
const widgets = @import("widgets.zig");
const settings_mod = @import("settings.zig");

pub const Slot = struct {
    kind: widgets.Kind = .unknown,
    /// Borrowed: config token, running key, or `service\x1fpath` tray key.
    key: []const u8 = "",
    chosen_serial: u64 = 0,
};

pub const Sources = struct {
    running_keys: []const []const u8 = &.{},
    running_serials: []const u64 = &.{},
    tray_keys: []const []const u8 = &.{},
};

/// `panel_widget_blocked` (:81-92): with widgets off, only the structural
/// tokens survive.
pub fn widgetBlocked(widgets_enabled: bool, cfg: *const schema.ShellConfig, token: []const u8) bool {
    if (widgets_enabled) return false;
    if (std.mem.eql(u8, token, "pinned_apps") or std.mem.eql(u8, token, "running_apps")) return false;
    if (wset.listContainsImpl(cfg, &.{token}, "system_tray")) return false;
    if (std.mem.eql(u8, token, "tray") or std.mem.eql(u8, token, "system_tray")) return false;
    if (std.mem.eql(u8, token, "settings_button") or std.mem.eql(u8, token, "trash") or
        std.mem.eql(u8, token, "spacer") or std.mem.eql(u8, token, "separator")) return false;
    const impl = wset.implementationType(cfg, token);
    const blocked = [_][]const u8{
        "clock", "world_clock", "weather", "media", "workspaces",
        "control_center", "notifications", "volume_mixer", "battery",
        "bluetooth", "vpn", "layout", "overview",
    };
    for (blocked) |b| {
        if (std.mem.eql(u8, impl, b)) return true;
    }
    return false;
}

fn appendToken(
    alloc: std.mem.Allocator,
    cfg: *const schema.ShellConfig,
    widgets_enabled: bool,
    token: []const u8,
    sources: Sources,
    out: *std.ArrayList(Slot),
) !void {
    if (widgetBlocked(widgets_enabled, cfg, token)) return;
    if (std.mem.eql(u8, token, "pinned_apps") or std.mem.eql(u8, token, "running_apps")) {
        for (sources.running_keys, 0..) |k, i| {
            try out.append(alloc, .{
                .kind = .app,
                .key = k,
                .chosen_serial = if (i < sources.running_serials.len) sources.running_serials[i] else 0,
            });
        }
        return;
    }
    if (wset.listContainsImpl(cfg, &.{token}, "system_tray") or
        std.mem.eql(u8, token, "tray") or std.mem.eql(u8, token, "system_tray"))
    {
        for (sources.tray_keys) |k| try out.append(alloc, .{ .kind = .tray, .key = k });
        return;
    }
    const kind = widgets.kindFromId(cfg, token);
    // Skipped kinds (C++ :174-176): resolved but never painted on the panel.
    switch (kind) {
        .app_menu, .smenu, .spotlight, .app_drawer => return,
        else => {},
    }
    try out.append(alloc, .{ .kind = kind, .key = token });
}

/// Expand one widget list, dropping blocked instances first.
pub fn buildSection(
    alloc: std.mem.Allocator,
    cfg: *const schema.ShellConfig,
    s: *const settings_mod.PanelSettings,
    tokens: []const []const u8,
    sources: Sources,
    out: *std.ArrayList(Slot),
) !void {
    for (tokens) |tok| {
        // Per-instance `enabled = false` drops the token (dock parity).
        var enabled = true;
        for (cfg.widgets) |*w| {
            if (!std.mem.eql(u8, w.id, tok)) continue;
            for (w.settings) |st| {
                if (!std.mem.eql(u8, st.key, "enabled")) continue;
                if (st.value.len == 0) break;
                const c = std.ascii.toLower(st.value[0]);
                enabled = !(c == '0' or c == 'f' or c == 'n');
                break;
            }
            break;
        }
        if (!enabled) continue;
        try appendToken(alloc, cfg, s.widgets_enabled, tok, sources, out);
    }
}

pub const Strip = struct {
    slots: []Slot = &.{},
    left_n: usize = 0,
    center_n: usize = 0,
    right_n: usize = 0,

    pub fn deinit(self: *Strip, alloc: std.mem.Allocator) void {
        alloc.free(self.slots);
        self.* = .{};
    }
};

/// Expand left/center/right into one flat strip with per-section counts.
pub fn buildStrip(
    alloc: std.mem.Allocator,
    cfg: *const schema.ShellConfig,
    s: *const settings_mod.PanelSettings,
    sources: Sources,
) !Strip {
    var list: std.ArrayList(Slot) = .empty;
    errdefer list.deinit(alloc);
    try buildSection(alloc, cfg, s, s.left_widgets, sources, &list);
    const left_n = list.items.len;
    try buildSection(alloc, cfg, s, s.center_widgets, sources, &list);
    const center_n = list.items.len - left_n;
    try buildSection(alloc, cfg, s, s.right_widgets, sources, &list);
    return .{
        .slots = try list.toOwnedSlice(alloc),
        .left_n = left_n,
        .center_n = center_n,
        .right_n = list.items.len -| left_n -| center_n,
    };
}

/// Gap between two adjacent slots: tray icons pack with no gap (single pill),
/// everything else takes `gap` (C++ :219-225).
pub fn gapBetween(a: Slot, b: Slot, gap: f64) f64 {
    if (a.kind == .tray and b.kind == .tray) return 0;
    return gap;
}

pub fn sectionWidth(slots: []const Slot, widths: []const f64, gap: f64) f64 {
    var tw: f64 = 0;
    for (slots, 0..) |sl, i| {
        tw += widths[i];
        if (i + 1 < slots.len) tw += gapBetween(sl, slots[i + 1], gap);
    }
    return tw;
}

/// Three-zone collision check (C++ :357-371): anchored sections downgrade to
/// the centered fallback strip when they would collide or leave the box.
pub fn panelFits(
    lw: f64,
    cw: f64,
    rw: f64,
    box_w: f64,
    strip_pad: f64,
    sec_gap: f64,
    has_l: bool,
    has_c: bool,
    has_r: bool,
) bool {
    const left_x = strip_pad;
    const center_x = (box_w - cw) / 2.0;
    const right_x = box_w - strip_pad - rw;
    const inner_l = strip_pad;
    const inner_r = box_w - strip_pad;
    if (has_l and has_r and left_x + lw + sec_gap > right_x) return false;
    if (has_l and has_c and left_x + lw + sec_gap > center_x) return false;
    if (has_c and has_r and center_x + cw + sec_gap > right_x) return false;
    if (has_l and left_x + lw > inner_r + 1e-9) return false;
    if (has_c and (center_x < inner_l - 1e-9 or center_x + cw > inner_r + 1e-9)) return false;
    if (has_r and (right_x < inner_l - 1e-9 or right_x + rw > inner_r + 1e-9)) return false;
    return true;
}

/// Uniform horizontal compression when the strip overflows the box (C++
/// :641-642). 1.0 when it fits.
pub fn stripHScale(box_w: f64, total_w: f64, strip_pad: f64) f64 {
    const avail = @max(1.0, box_w - strip_pad * 2.0);
    if (total_w <= avail) return 1.0;
    return avail / total_w;
}

/// Icon side clamped to the bar with breathing room (C++ :198, :279).
pub fn clampIcon(icon_raw: f64, box_h: f64) f64 {
    return std.math.clamp(icon_raw, 8.0, @max(8.0, box_h - 4.0));
}

test "panel-slots: tray packs, apps keep the gap" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 0), gapBetween(.{ .kind = .tray }, .{ .kind = .tray }, 8));
    try t.expectEqual(@as(f64, 8), gapBetween(.{ .kind = .clock }, .{ .kind = .tray }, 8));
    try t.expectEqual(@as(f64, 36), clampIcon(64, 40)); // clamp(64, 8, 40-4)
    try t.expectEqual(@as(f64, 1.0), stripHScale(800, 400, 16));
    try t.expect(stripHScale(400, 800, 16) < 1.0);
}

test "panel-slots: blocked widgets never reach the strip" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator,
        \\[panel]
        \\widgets_enabled = false
        \\left_widgets = ["clock", "pinned_apps", "tray"]
    );
    defer loaded.deinit();
    const c = &loaded.cfg;
    try t.expect(widgetBlocked(false, c, "clock"));
    try t.expect(!widgetBlocked(false, c, "pinned_apps"));
    try t.expect(!widgetBlocked(false, c, "tray"));
    try t.expect(!widgetBlocked(true, c, "clock"));
    var strip = try buildStrip(t.allocator, c, &c.panel, .{
        .running_keys = &.{"firefox"},
        .tray_keys = &.{"svc\x1fpath"},
    });
    defer strip.deinit(t.allocator);
    // clock blocked, pinned_apps -> 1 app, tray -> 1 tray
    try t.expectEqual(@as(usize, 2), strip.slots.len);
    try t.expectEqual(widgets.Kind.app, strip.slots[0].kind);
    try t.expectEqual(widgets.Kind.tray, strip.slots[1].kind);
}

test "panel-slots: skipped kinds resolve but never paint" {
    const t = std.testing;
    var loaded = try schema.loadText(t.allocator,
        \\[panel]
        \\left_widgets = ["app_menu", "clock"]
    );
    defer loaded.deinit();
    const c = &loaded.cfg;
    var strip = try buildStrip(t.allocator, c, &c.panel, .{});
    defer strip.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), strip.slots.len);
    try t.expectEqual(widgets.Kind.clock, strip.slots[0].kind);
}

test "panel-slots: panelFits downgrades on collision" {
    const t = std.testing;
    try t.expect(panelFits(100, 200, 100, 1920, 16, 20, true, true, true));
    try t.expect(!panelFits(800, 800, 800, 1000, 16, 20, true, true, true));
    try t.expect(!panelFits(900, 0, 900, 1000, 16, 20, true, false, true));
}
