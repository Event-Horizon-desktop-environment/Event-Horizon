//! The dock's widget model: which widget tokens exist, how the three sections
//! expand into concrete slots, how wide each slot paints, and the strip
//! geometry shared by painting and hit-testing.
//!
//! Widget-list expansion (disabled/blocked filtering, token ordering),
//! strip geometry (side-by-side layout, horizontal compression), effective
//! icon/gap/height, widget-strip content width, and per-kind slot widths.
//!
//! Everything here is pure: measurements that need pango at runtime (clock
//! text, weather readouts, media titles) arrive through `Measured`, which has
//! defaults that degrade to "no measurement available" fallbacks.

const std = @import("std");
const reflection = @import("../../compat/reflection.zig");
const schema = @import("../../config/schema.zig");
const defaults = @import("../../ux/shared/widget_defaults.zig");
const island_specs = @import("island_specs.zig");

const ShellConfig = schema.ShellConfig;

pub const Kind = enum {
    app,
    tray,
    settings,
    /// The Audio Center launcher: a shell component like `settings` (no
    /// desktop entry), wearing a themed app icon instead of a glyph.
    audio_center,
    spotlight,
    app_menu,
    app_drawer,
    smenu,
    clock,
    weather,
    media,
    workspaces,
    control_center,
    pear_center,
    trash,
    volume_mixer,
    vpn,
    layout,
    battery,
    bluetooth,
    world_clock,
    overview,
    clipstack,
};

pub const Slot = struct {
    kind: Kind,
    /// Launch id / tray key / widget instance id. Borrows from the config or
    /// the `Sources` it was built from, so both must outlive the slot.
    key: []const u8 = "",
    /// The section-list id that expanded this slot (`pinned_apps`, `clock`,
    /// …). `key` cannot answer for app and tray runs — there it carries the
    /// app — so `[dock] islands` membership hangs off this.
    token: []const u8 = "",
    /// Which of the three dock sections this slot came from. Whole-section
    /// island specs (`@left`, `@center`, `@right`) use this instead of the
    /// token list, so a duplicated token in another section stays put.
    section: island_specs.Section = .left,
    is_pinned: bool = false,
};

/// The runtime data a section expands over. Everything borrows from the
/// config, so `sources` must not outlive it needlessly.
pub const Sources = struct {
    pinned: []const []const u8 = &.{},
    running: []const []const u8 = &.{},
    tray: []const []const u8 = &.{},
};

// Widget registry

pub fn findInstance(cfg: *const ShellConfig, id: []const u8) ?*const schema.WidgetInstance {
    for (cfg.widgets) |*w| {
        if (std.mem.eql(u8, w.id, id)) return w;
    }
    return null;
}

/// `widget_implementation_type` — resolves an instance id to the implementation
/// that actually draws it. `pear_center` is the user-facing name for the
/// quick-settings widget and shares `control_center`.
pub fn implType(cfg: *const ShellConfig, id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, "pear_center")) {
        if (findInstance(cfg, id)) |w| {
            if (w.type.len == 0 or std.mem.eql(u8, w.type, "pear_center")) return "control_center";
            return w.type;
        }
        return "control_center";
    }
    if (findInstance(cfg, id)) |w| {
        if (std.mem.eql(u8, w.type, "pear_center")) return "control_center";
        return w.type;
    }
    return id;
}

/// Whether `token` names a PearCenter compact widget instance. Pear is a
/// fully separated widget here: `pear_center` has its own implementation and only the
/// popup layout differs), the strip carries its own `Kind.pear_center` so
/// the dock can paint the compact popup. Raw type only — the shared
/// `implType` mapping stays untouched for every other consumer.
pub fn isPearInstance(cfg: *const ShellConfig, id: []const u8) bool {
    if (std.mem.eql(u8, id, "pear_center")) {
        if (findInstance(cfg, id)) |w| {
            return w.type.len == 0 or std.mem.eql(u8, w.type, "pear_center");
        }
        return true;
    }
    if (findInstance(cfg, id)) |w| {
        return std.mem.eql(u8, w.type, "pear_center");
    }
    return false;
}

pub fn tokenIsSystemTray(cfg: *const ShellConfig, token: []const u8) bool {
    if (std.mem.eql(u8, token, "system_tray") or std.mem.eql(u8, token, "tray")) return true;
    return std.mem.eql(u8, implType(cfg, token), "system_tray");
}

pub fn settingStr(cfg: *const ShellConfig, id: []const u8, key: []const u8) ?[]const u8 {
    const w = findInstance(cfg, id) orelse return null;
    for (w.settings) |s| {
        if (std.mem.eql(u8, s.key, key)) return s.value;
    }
    return null;
}

/// `parse_bool_setting` semantics: absent/empty falls back to `dflt`, and a
/// leading `0`/`f`/`n` (any case) is false, anything else is true.
pub fn settingBool(cfg: *const ShellConfig, id: []const u8, key: []const u8, dflt: bool) bool {
    const v = settingStr(cfg, id, key) orelse return dflt;
    if (v.len == 0) return dflt;
    return !isFalseWord(v[0]);
}

fn isFalseWord(c: u8) bool {
    const l = std.ascii.toLower(c);
    return l == '0' or l == 'f' or l == 'n';
}

/// `widget_instance_enabled` — instances default to enabled.
pub fn instanceEnabled(cfg: *const ShellConfig, id: []const u8) bool {
    const w = findInstance(cfg, id) orelse return true;
    return instanceEnabledBySettings(w.settings);
}

/// The same rule over a raw settings slice, for callers (like the settings
/// app's widget tab) that hold an instance without a full config.
pub fn instanceEnabledBySettings(settings: []const schema.WidgetInstance.Setting) bool {
    for (settings) |s| {
        if (!std.mem.eql(u8, s.key, "enabled")) continue;
        if (s.value.len == 0) return true;
        return !isFalseWord(s.value[0]);
    }
    return true;
}

/// `dock_strip_widget_blocked` — when `dock_widgets_enabled` is off, only the
/// core structural widgets survive.
pub fn stripWidgetBlocked(cfg: *const ShellConfig, token: []const u8) bool {
    if (cfg.dock.dock_widgets_enabled) return false;
    if (std.mem.eql(u8, token, "pinned_apps") or std.mem.eql(u8, token, "running_apps")) return false;
    if (tokenIsSystemTray(cfg, token)) return false;
    if (std.mem.eql(u8, token, "settings_button") or
        std.mem.eql(u8, token, "audio_center_button") or
        std.mem.eql(u8, token, "distro_spotlight") or
        std.mem.eql(u8, token, "app_menu") or
        std.mem.eql(u8, token, "trash")) return false;
    const impl = implType(cfg, token);
    const structural = [_][]const u8{
        "clock",          "world_clock",   "weather",      "media",      "workspaces",
        "control_center", "notifications", "volume_mixer", "app_drawer", "overview",
        "layout",
    };
    for (structural) |s| {
        if (std.mem.eql(u8, impl, s)) return true;
    }
    // Pear is separated from control_center in the strip, but it is just as
    // ornamental when widgets are off.
    if (isPearInstance(cfg, token)) return true;
    return false;
}

// Section defaults

pub const default_left = defaults.dock_left;
pub const default_center = defaults.dock_center;
pub const default_right = defaults.dock_right;

pub const Sections = struct {
    left: []const []const u8,
    center: []const []const u8,
    right: []const []const u8,
};

/// `apply_dock_defaults_if_needed` — defaults only apply when all three lists
/// are empty, so a half-configured dock keeps exactly what the user wrote.
pub fn sections(cfg: *const ShellConfig) Sections {
    if (cfg.dock.left_widgets.len == 0 and
        cfg.dock.center_widgets.len == 0 and
        cfg.dock.right_widgets.len == 0)
    {
        return .{ .left = &default_left, .center = &default_center, .right = &default_right };
    }
    return .{
        .left = cfg.dock.left_widgets,
        .center = cfg.dock.center_widgets,
        .right = cfg.dock.right_widgets,
    };
}

// Section expansion

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

/// The application id a slot launches, or `null` when it has no launchable
/// target yet — the Zig shell has no model for starting menus, workspaces or
/// tray popups, so those report instead of silently doing nothing.
pub fn launchTarget(s: Slot) ?[]const u8 {
    return switch (s.kind) {
        .app => if (s.key.len > 0) s.key else null,
        // The `rail_settings` variant tracks the redesigned `settings`
        // binary's window (its own app id — `namespaces.rail_settings_app_id`),
        // so a running dot only lights on the button that opened the window.
        .settings => if (std.mem.eql(u8, s.key, "rail_settings"))
            "event-horizon-rail-settings"
        else
            "event-horizon-settings",
        // The mixer launcher is a shell component too: the app id is what
        // `focusExisting`/running dots match against its window.
        .audio_center => if (s.key.len > 0) "event-horizon-audio-center" else null,
        else => null,
    };
}

/// `append_tokens_for_widget`, in chain-test order.
fn appendToken(
    alloc: std.mem.Allocator,
    cfg: *const ShellConfig,
    w: []const u8,
    sources: Sources,
    out: *std.ArrayList(Slot),
) !void {
    // Every slot this token expands into carries the token, which is what
    // makes the `[dock] islands` split exact (see `islandEdge`).
    const start = out.items.len;
    const impl = implType(cfg, w);
    if (std.mem.eql(u8, w, "pinned_apps")) {
        for (sources.pinned) |id| try out.append(alloc, .{ .kind = .app, .key = id, .is_pinned = true });
    } else if (std.mem.eql(u8, w, "running_apps")) {
        for (sources.running) |id| try out.append(alloc, .{ .kind = .app, .key = id });
    } else if (tokenIsSystemTray(cfg, w)) {
        for (sources.tray) |k| try out.append(alloc, .{ .kind = .tray, .key = k });
    } else if (std.mem.eql(u8, w, "settings_button")) {
        try out.append(alloc, .{ .kind = .settings, .key = w });
    } else if (std.mem.eql(u8, w, "rail_settings")) {
        // Same slot kind (shared click flow, width, right-click menu); the
        // dock branches on the key for icon + which settings binary opens.
        try out.append(alloc, .{ .kind = .settings, .key = w });
    } else if (std.mem.eql(u8, w, "audio_center_button") or std.mem.eql(u8, impl, "audio_center")) {
        // A bare launcher slot, shaped exactly like the settings button.
        try out.append(alloc, .{ .kind = .audio_center, .key = w });
    } else if (std.mem.eql(u8, w, "distro_spotlight")) {
        try out.append(alloc, .{ .kind = .spotlight, .key = w });
    } else if (std.mem.eql(u8, w, "app_menu")) {
        try out.append(alloc, .{ .kind = .app_menu, .key = w });
    } else if (std.mem.eql(u8, impl, "app_drawer")) {
        try out.append(alloc, .{ .kind = .app_drawer, .key = w });
    } else if (std.mem.eql(u8, impl, "smenu")) {
        try out.append(alloc, .{ .kind = .smenu, .key = w });
    } else if (std.mem.eql(u8, impl, "clock")) {
        try out.append(alloc, .{ .kind = .clock, .key = w });
    } else if (std.mem.eql(u8, impl, "weather")) {
        try out.append(alloc, .{ .kind = .weather, .key = w });
    } else if (std.mem.eql(u8, impl, "media")) {
        try out.append(alloc, .{ .kind = .media, .key = w });
    } else if (std.mem.eql(u8, impl, "workspaces")) {
        try out.append(alloc, .{ .kind = .workspaces, .key = w });
    } else if (isPearInstance(cfg, w)) {
        try out.append(alloc, .{ .kind = .pear_center, .key = w });
    } else if (std.mem.eql(u8, impl, "control_center")) {
        try out.append(alloc, .{ .kind = .control_center, .key = w });
    } else if (std.mem.eql(u8, w, "trash") or std.mem.eql(u8, impl, "trash")) {
        try out.append(alloc, .{ .kind = .trash, .key = w });
    } else if (std.mem.eql(u8, impl, "volume_mixer")) {
        try out.append(alloc, .{ .kind = .volume_mixer, .key = w });
    } else if (std.mem.eql(u8, impl, "vpn")) {
        try out.append(alloc, .{ .kind = .vpn, .key = w });
    } else if (std.mem.eql(u8, impl, "battery")) {
        try out.append(alloc, .{ .kind = .battery, .key = w });
    } else if (std.mem.eql(u8, impl, "bluetooth")) {
        try out.append(alloc, .{ .kind = .bluetooth, .key = w });
    } else if (std.mem.eql(u8, impl, "layout")) {
        try out.append(alloc, .{ .kind = .layout, .key = w });
    } else if (std.mem.eql(u8, impl, "overview")) {
        try out.append(alloc, .{ .kind = .overview, .key = w });
    } else if (std.mem.eql(u8, impl, "world_clock")) {
        try out.append(alloc, .{ .kind = .world_clock, .key = w });
    } else if (std.mem.eql(u8, impl, "clipstack")) {
        try out.append(alloc, .{ .kind = .clipstack, .key = w });
    }
    for (out.items[start..]) |*s| s.token = w;
}

/// Expands one widget list, dropping disabled and blocked instances first
/// (same order as `build_section`).
pub fn buildSection(
    alloc: std.mem.Allocator,
    cfg: *const ShellConfig,
    tokens: []const []const u8,
    sources: Sources,
    out: *std.ArrayList(Slot),
) !void {
    for (tokens) |tok| {
        if (!instanceEnabled(cfg, tok)) continue;
        if (stripWidgetBlocked(cfg, tok)) continue;
        try appendToken(alloc, cfg, tok, sources, out);
    }
}

/// Expands left, center and right into one flat strip with per-section counts.
pub fn buildStrip(
    alloc: std.mem.Allocator,
    cfg: *const ShellConfig,
    sources: Sources,
) !Strip {
    const sec = sections(cfg);
    var list: std.ArrayList(Slot) = .empty;
    errdefer list.deinit(alloc);

    try buildSection(alloc, cfg, sec.left, sources, &list);
    for (list.items[0..]) |*s| s.section = .left;
    const left_n = list.items.len;
    try buildSection(alloc, cfg, sec.center, sources, &list);
    for (list.items[left_n..]) |*s| s.section = .center;
    const center_n = list.items.len - left_n;
    try buildSection(alloc, cfg, sec.right, sources, &list);
    for (list.items[left_n + center_n ..]) |*s| s.section = .right;
    const right_n = list.items.len - left_n - center_n;

    return .{
        .slots = try list.toOwnedSlice(alloc),
        .left_n = left_n,
        .center_n = center_n,
        .right_n = right_n,
    };
}

// Effective sizing

pub fn clampf(v: f64, lo: f64, hi: f64) f64 {
    // Deliberately not `std.math.clamp`: `lo > hi` is reachable when a large
    // icon scale outgrows a small bar, and this degrades to `lo` instead of
    // asserting on invalid ranges.
    return @max(lo, @min(hi, v));
}

fn round(v: f64) f64 {
    return std.math.round(v);
}

pub fn uiScale(cfg: *const ShellConfig) f64 {
    return clampf(cfg.dock.dock_scale, 0.5, 2.0) * clampf(cfg.dock.shell_ui_scale, 0.5, 2.0);
}

pub fn effectiveIcon(cfg: *const ShellConfig) i32 {
    const base = clampf(@floatFromInt(@min(@max(cfg.dock.dock_icon_size, 0), 50)), 0, 50);
    const v: f64 = round(base * uiScale(cfg));
    return @intFromFloat(clampf(v, 1, 96));
}

pub fn effectiveGap(cfg: *const ShellConfig) i32 {
    const raw0 = @min(@max(cfg.dock.dock_icon_spacing, -50), 50);
    const raw: f64 = round(@as(f64, @floatFromInt(raw0)) * uiScale(cfg));
    const raw_i: i32 = @intFromFloat(raw);
    if (raw_i < 0) return @min(@max(raw_i, -50), -1);
    if (raw_i <= 1) return raw_i;
    const scaled: f64 = round(raw * 0.6);
    return @intFromFloat(clampf(scaled, 0, 50));
}

pub fn heightForIcon(icon_px: i32, slim: bool) i32 {
    // 24 px of vertical padding (12 top, 12 bottom) around the art. The old
    // +28 left a 44 px icon sitting in a 72 px bar with 14 px above and
    // below — macOS-ish docks run closer to 3/4 art-to-bar, and the tighter
    // frame is what makes the strip read as one glass ledge instead of a
    // shelf with icons parked on it. The Slim Dock toggle halves that pad:
    // 5 px top and bottom, so the ledge hugs the icons.
    return @min(200, @max(32, icon_px + (if (slim) @as(i32, 10) else 24)));
}

pub fn effectiveBarHeight(cfg: *const ShellConfig) i32 {
    const icon_px = effectiveIcon(cfg);
    if (cfg.dock.dock_bar_follows_icons) return heightForIcon(icon_px, cfg.dock.dock_slim);
    const min_h = @min(@max(icon_px + 4, 32), 200);
    return @min(@max(cfg.dock.dock_manual_bar_height_px, min_h), 200);
}

pub fn effectiveBottomGap(cfg: *const ShellConfig) i32 {
    return @min(@max(cfg.dock.dock_bottom_gap, 0), 25);
}

pub fn effectiveRadius(cfg: *const ShellConfig) i32 {
    const base = @min(@max(cfg.dock.dock_radius, 0), 50);
    const v: f64 = round(@as(f64, @floatFromInt(base)) * uiScale(cfg));
    return @intFromFloat(clampf(v, 0, 76));
}

/// Inner horizontal padding of the widget strip inside the pill.
pub fn stripInnerMargin(cfg: *const ShellConfig) f64 {
    // Slim Dock trims the strip's inner margin as well, so widgets and app
    // pills sit closer to the pill's rounded ends.
    return (if (cfg.dock.dock_slim) @as(f64, 7.0) else 12.0) * uiScale(cfg);
}

// Measurements that need pango at runtime

pub const Measured = struct {
    /// Widest clock line, in px. `0` means "no text" and picks the fallback.
    clock_max_w: f64 = 0,
    /// `iconPx + gap + tempW + gap + pillW` for the weather readout.
    weather_inner: f64 = 0,
    /// Final (already scale-capped) media title+artist run.
    media_text_w: f64 = 0,
    /// Control-row width for the media transport buttons, `0` when inactive.
    media_ctrl_w: f64 = 0,
    battery_text_w: f64 = 0,
    battery_glyph_w: f64 = 0,
    bluetooth_text_w: f64 = 0,
    bluetooth_has_label: bool = false,
    /// `cellW * n + interCellGap * (n-1) + outerPad * 2`.
    world_clock_inner: f64 = 0,
    workspace_count: usize = 0,
    workspace_w: f64 = 0,
    /// Number of control-center glyphs shown; `0` means the default of three
    /// (net + audio + bluetooth, mic only while it is running).
    cc_icons: u8 = 0,
    /// Same for a pear_center slot (separate pill, same shape).
    pear_icons: u8 = 0,
};

pub const Metrics = struct {
    icon: f64,
    gap: f64,
    /// Px between two island pills, already scaled by `fit`. Defaults to 0
    /// for the hand-built metrics in tests that predate islands.
    island_gap: f64 = 0,
    bar_h: f64,
    ui_scale: f64,
    strip_inner: f64,
    pill_x: f64,
    box_w: f64,
    /// Output fit factor (output height / 1440, clamped) every metric above
    /// has been scaled by. The dock is authored for a 1440-tall output; this
    /// is what keeps the strip the same fraction of the screen at any
    /// resolution. Widgets and fonts read it through `ui_scale`.
    fit: f64 = 1.0,

    pub fn midX(self: Metrics) f64 {
        return self.pill_x + self.box_w * 0.5;
    }

    pub fn of(cfg: *const ShellConfig, pill_x: f64, box_w: f64, fit: f64) Metrics {
        const sc = uiScale(cfg) * fit;
        return .{
            .icon = @as(f64, @floatFromInt(effectiveIcon(cfg))) * fit,
            .gap = @as(f64, @floatFromInt(effectiveGap(cfg))) * fit,
            .island_gap = @as(f64, @floatFromInt(effectiveIslandGap(cfg))) * fit,
            .bar_h = @as(f64, @floatFromInt(effectiveBarHeight(cfg))) * fit,
            .ui_scale = sc,
            .strip_inner = stripInnerMargin(cfg) * fit,
            .pill_x = pill_x,
            .box_w = box_w,
            .fit = fit,
        };
    }
};

fn pillCorner(pill_h: f64, slot_w: f64) f64 {
    return @max(2.0, @min(pill_h, slot_w) * 0.22);
}

/// Per-kind slot width. `cfg` supplies the per-instance settings, `m` the
/// dock-level metrics, `meas` the values only pango could have produced.
pub fn slotWidth(cfg: *const ShellConfig, s: Slot, m: Metrics, meas: Measured) f64 {
    const icon = m.icon;
    switch (s.kind) {
        .clock => {
            // `format_clock_lines` yields nothing when the label is off.
            if (!settingBool(cfg, s.key, "show_text", true)) return @max(56.0, icon * 2.4);
            if (meas.clock_max_w <= 0) return @max(56.0, icon * 2.4);
            return clampf(meas.clock_max_w + 20.0, @max(icon * 1.25, 52.0), @min(m.bar_h * 6.0, 220.0));
        },
        .weather => return clampf(meas.weather_inner + 20.0, @max(icon * 1.25, 72.0), @min(m.bar_h * 6.0, 220.0)),
        .media => {
            const w0 = mediaWidthFor(icon, m.bar_h, meas.media_ctrl_w, meas.media_text_w);
            return clampf(
                w0,
                mediaMinWidth(icon, m.bar_h, meas.media_ctrl_w, meas.media_text_w),
                mediaCapWidth(m.bar_h),
            );
        },
        .workspaces => {
            if (meas.workspace_count == 0) return @min(m.bar_h * 3.5, 120.0);
            return meas.workspace_w;
        },
        .control_center => {
            const sc = icon / 30.0;
            const hpad = @max(6.0, 8.0 * sc);
            const gap = @max(5.0, 6.0 * sc);
            const glyph = clampf(icon * 0.45, 12.0, 24.0);
            const n: f64 = @floatFromInt(if (meas.cc_icons == 0) 3 else meas.cc_icons);
            const w = hpad * 2.0 + n * glyph + @max(0.0, n - 1.0) * gap;
            return clampf(w, 48.0, @min(m.bar_h * 6.5, 240.0));
        },
        .pear_center => {
            const sc = icon / 30.0;
            const hpad = @max(6.0, 8.0 * sc);
            const gap = @max(5.0, 6.0 * sc);
            const glyph = clampf(icon * 0.45, 12.0, 24.0);
            const n: f64 = @floatFromInt(if (meas.pear_icons == 0) 3 else meas.pear_icons);
            const w = hpad * 2.0 + n * glyph + @max(0.0, n - 1.0) * gap;
            return clampf(w, 48.0, @min(m.bar_h * 6.5, 240.0));
        },
        .battery => {
            if (!settingBool(cfg, s.key, "show_percent", true)) return icon + 4.0 * m.ui_scale;
            const us = m.ui_scale;
            const pad_x = 6.0 * us;
            const gap = 6.0 * us;
            const min_w = @max(icon * 1.25, 40.0 * us);
            return @max(min_w, meas.battery_glyph_w + gap + meas.battery_text_w + pad_x * 2.0);
        },
        .bluetooth => {
            if (!settingBool(cfg, s.key, "show_label", false) or !meas.bluetooth_has_label) {
                return icon + 4.0 * m.ui_scale;
            }
            const us = m.ui_scale;
            const pad_x = 6.0 * us;
            const gap = 6.0 * us;
            const min_w = @max(icon * 1.25, 40.0 * us);
            return @max(min_w, icon + gap + meas.bluetooth_text_w + pad_x * 2.0);
        },
        .clipstack => return icon + 4.0 * m.ui_scale,
        .world_clock => return clampf(meas.world_clock_inner, @max(icon * 1.5, 64.0), @min(m.bar_h * 12.0, 640.0)),
        // `dock_layout_slot_width`, inlined the way bluetooth's no-label arm
        // is — and it really does differ from bluetooth's: clamping
        // `shellUiScale` alone here where bluetooth uses `dock_ui_scale`,
        // which multiplies in `dockScale` too. The dock's own width pass
        // re-runs `layout_paint.dockLayoutSlotWidth` over this value, so the
        // two have to agree.
        .layout => return icon + 4.0 * clampf(cfg.dock.shell_ui_scale, 0.5, 2.0),
        else => return icon,
    }
}

/// `slotWidth`'s media arithmetic for a run of `text_w`: the two
/// `pillCorner` passes, kept here so the pill's width and its
/// floor (below) can never answer differently.
fn mediaWidthFor(icon: f64, bar_h: f64, ctrl_w: f64, text_w: f64) f64 {
    const sc = icon / 30.0;
    const art_dia = icon * 0.78;
    const i_gap = @max(8.0, 10.0 * sc);
    const pill_h = icon; // kPillHeightMul == 1
    var inner = pillCorner(pill_h, mediaCapWidth(bar_h)) + 4.0; // kMediaOuterHPad
    var w0 = inner + art_dia + i_gap + text_w + i_gap + ctrl_w + inner;
    inner = pillCorner(pill_h, w0) + 4.0;
    w0 = inner + art_dia + i_gap + text_w + i_gap + ctrl_w + inner;
    return w0;
}

/// The media pill's ceiling — `min(bar*22, 920)`, i.e. the widget gives up
/// its title before it eats the dock.
fn mediaCapWidth(bar_h: f64) f64 {
    return @min(bar_h * 22.0, 920.0);
}

/// `slotWidth`'s media `min0`: the pill with nothing to say, cover art and
/// the transport row still taking their share. This is the width the fit
/// pass (`slotFloorWidth`) shrinks the media slot to, which is what turns a
/// long title into a marquee instead of a wider dock.
pub fn mediaMinWidth(icon: f64, bar_h: f64, ctrl_w: f64, text_w: f64) f64 {
    const inner = pillCorner(icon, mediaWidthFor(icon, bar_h, ctrl_w, text_w)) + 4.0;
    const sc = icon / 30.0;
    const art_dia = icon * 0.78;
    const i_gap = @max(8.0, 10.0 * sc);
    return inner + art_dia + i_gap + i_gap + ctrl_w + inner;
}

/// `fit`'s floor for one slot: the narrowest `width` may be squeezed to
/// before the pass stops taking from that widget. The label painters centre
/// their run in the box without clipping it, so a text slot answers with the
/// width of what it actually draws — losing padding, never the text, which
/// would spill across the neighbouring slot. The media pill answers with
/// `min0`, its textless width. Workspaces answers with the widget's width
/// floor, because `layoutCells` scales its cells into whatever it is handed.
/// Everything else answers with `width` itself: its content *is* its width
/// (battery and bluetooth measure their label outside `Measured`, so the only
/// width that could be trusted is the one already in hand).
pub fn slotFloorWidth(cfg: *const ShellConfig, s: Slot, m: Metrics, meas: Measured, width: f64) f64 {
    const icon = m.icon;
    return switch (s.kind) {
        .media => @min(width, mediaMinWidth(icon, m.bar_h, meas.media_ctrl_w, meas.media_text_w)),
        .clock => if (!settingBool(cfg, s.key, "show_text", true) or meas.clock_max_w <= 0)
            width
        else
            @min(width, @max(@max(icon * 1.25, 52.0), meas.clock_max_w + 4.0)),
        .weather => @min(width, @max(@max(icon * 1.25, 72.0), meas.weather_inner + 4.0)),
        .world_clock => @min(width, @max(@max(icon * 1.5, 64.0), meas.world_clock_inner + 4.0)),
        // `dockWorkspacesSlotWidth`'s own lower clamp: below it the cells
        // are scaled down to illegibility anyway.
        .workspaces => @min(width, 60.0),
        else => width,
    };
}

// Gap rules (dock_gap_after_pick / gap_after_slots)

fn isApp(s: Slot) bool {
    return s.kind == .app;
}

/// `dock_gap_after_pick`. The last slot never has a gap after it.
pub fn gapAfter(cfg: *const ShellConfig, slots: []const Slot, idx: usize, def_gap: f64) f64 {
    if (idx + 1 >= slots.len) return 0.0;
    const a = slots[idx];
    const b = slots[idx + 1];
    if (a.kind == .tray and b.kind == .tray) return 0.0;
    if (cfg.dock.dock_pinned_apps_tray_pill and isApp(a) and a.is_pinned and isApp(b) and b.is_pinned) return 0.0;
    if (cfg.dock.dock_running_apps_tray_pill and isApp(a) and !a.is_pinned and isApp(b) and !b.is_pinned) return 0.0;
    if (isApp(a) and a.is_pinned and isApp(b) and !b.is_pinned) return round(def_gap * 1.5);
    return def_gap;
}

// Widget islands (`[dock] islands`)

/// `[dock] island_gap` in device px, scaled like the icon gap so a scaled
/// dock keeps its proportions. 0 keeps the pills touching (one seam).
pub fn effectiveIslandGap(cfg: *const ShellConfig) i32 {
    const raw: f64 = @floatFromInt(@min(@max(cfg.dock.island_gap, 0), 40));
    return @intFromFloat(clampf(round(raw * uiScale(cfg)), 0, 80));
}

/// The island group a slot belongs to, or 0 when it shares the bar.
/// Equal groups are linked into one pill; specs are first-match, so a
/// whole-section entry can own slots before a later explicit group.
fn islandGroup(cfg: *const ShellConfig, slot: Slot) usize {
    const idx = island_specs.groupIndex(cfg.dock.islands, slot.token, slot.section) orelse return 0;
    return idx + 1;
}

/// Whether this slot is an island's own run (its spec put it in a group).
pub fn slotIsIsland(cfg: *const ShellConfig, slot: Slot) bool {
    return islandGroup(cfg, slot) != 0;
}

/// True when the gap between slots `idx` and `idx + 1` is a pill edge.
///
/// Slots in the same island group always share a pill, whether the group is
/// one widget, a `'media+clock'` link, or a whole-section spec. A change of
/// group is an edge whenever at least one side is an island: that splits
/// separate islands and cuts the surrounding bar pill around them. Two
/// ungrouped neighbours keep the plain bar seam-less join they always had.
pub fn islandEdge(cfg: *const ShellConfig, slots: []const Slot, idx: usize) bool {
    if (idx + 1 >= slots.len) return false;
    const a = islandGroup(cfg, slots[idx]);
    const b = islandGroup(cfg, slots[idx + 1]);
    return a != b and (a != 0 or b != 0);
}

/// The layout gap between slots `idx` and `idx + 1`. A pill edge pays the
/// pill's own inner padding on both sides in addition to the configured
/// island gap, so two pills read as separate surfaces (and the bar keeps the
/// same content inset it always had). Identical to `gapAfter` otherwise.
pub fn gapStyled(
    cfg: *const ShellConfig,
    slots: []const Slot,
    idx: usize,
    def_gap: f64,
    island_gap: f64,
    pad: f64,
) f64 {
    if (!islandEdge(cfg, slots, idx)) return gapAfter(cfg, slots, idx, def_gap);
    return pad + island_gap + pad;
}

/// Last slot of the pill that starts at `first`: it runs to the last slot
/// before the next island edge. Degenerates to the final slot of the whole
/// strip when `[dock] islands` is empty, so the classic single bar is one
/// pill and every downstream caller keeps its old geometry.
pub fn pillLast(cfg: *const ShellConfig, slots: []const Slot, first: usize) usize {
    var last = first;
    while (last + 1 < slots.len and !islandEdge(cfg, slots, last)) : (last += 1) {}
    return last;
}

/// `firstPinnedInRun` / `firstRunningInRun` / `firstTrayInRun`: when
/// `dock_pinned_apps_tray_pill` (or its running counterpart) is on, one
/// shared pill is painted under a whole run of adjacent apps of the same
/// pinnedness. Tray items always share one pill per run. Returns the number
/// of slots that pill covers — or 0 when `idx` does not start one. The trash
/// is never a run tail: it owns a pill of its own (`ownsPill`), and a run
/// pill reaching over it would both composite a pill over a pill and stretch
/// across the island edge when either side is islanded.
pub fn runPillLen(cfg: *const ShellConfig, slots: []const Slot, idx: usize) usize {
    if (idx >= slots.len) return 0;
    const s = slots[idx];
    if (s.kind == .tray) {
        if (idx > 0 and slots[idx - 1].kind == .tray) return 0;
        var n: usize = 1;
        while (idx + n < slots.len and slots[idx + n].kind == .tray) : (n += 1) {}
        return n;
    }
    if (!isApp(s)) return 0;
    const shared = if (s.is_pinned)
        cfg.dock.dock_pinned_apps_tray_pill
    else
        cfg.dock.dock_running_apps_tray_pill;
    if (!shared) return 0;
    if (idx > 0) {
        const p = slots[idx - 1];
        if (isApp(p) and p.is_pinned == s.is_pinned) return 0;
    }
    var n: usize = 1;
    while (idx + n < slots.len) : (n += 1) {
        const t = slots[idx + n];
        if (!isApp(t) or t.is_pinned != s.is_pinned) break;
    }
    return n;
}

/// Which slots paint a pill *of their own*. Deliberately not "every non-app slot":
///
/// - `Settings`, `VolumeMixer`, `Vpn` and `Overview` call `paint_pill`
///   outright, and every widget whose face a `paint_*_slot` owns paints one
///   inside it, so they fall through to `true`.
/// - `Smenu` and `Trash` paint through the generic `paintSlot` arm and take
///   that arm's pill: they read like the widgets beside them, and that pill
///   is also what floats when they are islands.
/// - `App` and `Tray` never own one — their whole run does (`runPillLen`).
///   A hovered cell gets the accent wash only: a pill of its own would
///   composite over the run's and read as one darker capsule mid-bar.
/// - `Spotlight`, `AppDrawer` and `AppMenu` paint their
///   face on the bare bar with the hover wash behind it and nothing else.
pub fn ownsPill(kind: Kind) bool {
    return switch (kind) {
        .app, .tray, .spotlight, .app_drawer, .app_menu => false,
        else => true,
    };
}

pub fn sectionWidth(
    cfg: *const ShellConfig,
    slots: []const Slot,
    widths: []const f64,
    from: usize,
    count: usize,
    def_gap: f64,
    fit: f64,
) f64 {
    const island_gap = @as(f64, @floatFromInt(effectiveIslandGap(cfg))) * fit;
    const pad = stripInnerMargin(cfg) * fit;
    var total: f64 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        total += widths[from + i];
        if (i + 1 < count) total += gapStyled(cfg, slots, from + i, def_gap, island_gap, pad);
    }
    return total;
}

pub fn concatWidth(
    cfg: *const ShellConfig,
    slots: []const Slot,
    widths: []const f64,
    def_gap: f64,
    fit: f64,
) f64 {
    const island_gap = @as(f64, @floatFromInt(effectiveIslandGap(cfg))) * fit;
    const pad = stripInnerMargin(cfg) * fit;
    var total: f64 = 0;
    for (slots, 0..) |_, i| {
        total += widths[i];
        if (i + 1 < slots.len) total += gapStyled(cfg, slots, i, def_gap, island_gap, pad);
    }
    return total;
}

// Strip geometry

pub const LrStrip = struct {
    side_by_side: bool = false,
    x_left: f64 = 0,
    x_right: f64 = 0,
};

/// Side-by-side left/right placement, only reachable when there is no center.
pub fn lrStripLayout(
    pill_x: f64,
    pill_box_w: f64,
    strip_inner_full: f64,
    left_total_w: f64,
    center_total_w: f64,
    right_total_w: f64,
    section_gap_px: f64,
) LrStrip {
    const l: LrStrip = .{};
    if (center_total_w > 1e-6) return l;
    const half_strip = strip_inner_full * 0.5;
    const min_x = pill_x + half_strip;
    const max_r = pill_x + pill_box_w - half_strip;
    const need = left_total_w + section_gap_px + right_total_w;
    if (need > max_r - min_x + 1e-9) return l;
    const right_start = max_r - right_total_w;
    const ideal_left = right_start - left_total_w - section_gap_px;
    if (ideal_left < min_x - 1e-9) return l;
    return .{ .side_by_side = true, .x_left = ideal_left, .x_right = right_start };
}

/// Compresses the strip toward `midX` when it is wider than the pill.
pub fn widgetStripHScale(box_w: f64, total_w: f64, inner_margin_px: f64) f64 {
    const avail = @max(1.0, box_w - inner_margin_px);
    if (total_w <= avail) return 1.0;
    return avail / total_w;
}

/// Pointer surface x → uncompressed layout x.
pub fn surfaceXToLayout(sx: f64, mid_x: f64, h_scale: f64) f64 {
    return mid_x + (sx - mid_x) / h_scale;
}

/// Uncompressed layout x → painted surface x.
pub fn layoutXToSurface(lx: f64, mid_x: f64, h_scale: f64) f64 {
    return mid_x + (lx - mid_x) * h_scale;
}

pub const Geom = struct {
    m: Metrics,
    slots: []const Slot,
    widths: []const f64,
    left_n: usize,
    center_n: usize,
    right_n: usize,
    concat_total: f64 = 0,
    start_x: f64 = 0,
    left_w: f64 = 0,
    center_w: f64 = 0,
    right_w: f64 = 0,
    sec_gap: f64 = 0,
    use_lr: bool = false,
    xl: f64 = 0,
    xr: f64 = 0,
    total_for_scale: f64 = 0,
    h_scale: f64 = 1,
    mid_x: f64 = 0,
};

pub fn computeGeom(
    cfg: *const ShellConfig,
    slots: []const Slot,
    widths: []const f64,
    left_n: usize,
    center_n: usize,
    right_n: usize,
    m: Metrics,
) Geom {
    var g = Geom{
        .m = m,
        .slots = slots,
        .widths = widths,
        .left_n = left_n,
        .center_n = center_n,
        .right_n = right_n,
        .mid_x = m.midX(),
    };
    g.concat_total = concatWidth(cfg, slots, widths, m.gap, m.fit);
    // Each pill carries `strip_inner` of padding around its content, so the
    // row is the styled concat plus one pad per row end. With no islands
    // `box_w` is exactly `concat + 2 * pad` and this reduces to the plain
    // centering the single bar has always used.
    g.start_x = m.pill_x + m.strip_inner + (m.box_w - (g.concat_total + m.strip_inner * 2.0)) * 0.5;
    g.total_for_scale = g.concat_total;
    g.h_scale = widgetStripHScale(m.box_w, g.total_for_scale, m.strip_inner);

    if (left_n + center_n + right_n != slots.len or slots.len == 0) return g;

    g.left_w = sectionWidth(cfg, slots, widths, 0, left_n, m.gap, m.fit);
    g.center_w = sectionWidth(cfg, slots, widths, left_n, center_n, m.gap, m.fit);
    g.right_w = sectionWidth(cfg, slots, widths, left_n + center_n, right_n, m.gap, m.fit);
    g.sec_gap = round(m.gap * 1.5);

    // Side-by-side left/right placement is an edge-anchoring trick for the
    // single bar; islands anchor each pill to its own content instead.
    if (cfg.dock.islands.len == 0 and center_n == 0 and left_n > 0 and right_n > 0) {
        const lr = lrStripLayout(m.pill_x, m.box_w, m.strip_inner, g.left_w, 0, g.right_w, g.sec_gap);
        if (lr.side_by_side) {
            g.use_lr = true;
            g.xl = lr.x_left;
            g.xr = lr.x_right;
            g.total_for_scale = g.left_w + g.sec_gap + g.right_w;
            g.h_scale = widgetStripHScale(m.box_w, g.total_for_scale, m.strip_inner);
        }
    }
    return g;
}

/// `dock_slot_layout_x` — uncompressed layout x of slot `idx`.
pub fn slotLayoutX(cfg: *const ShellConfig, g: *const Geom, idx: usize) f64 {
    if (idx >= g.slots.len) return 0.0;
    const lc = g.left_n;
    const cc = g.center_n;
    if (g.use_lr and cc == 0) {
        if (idx < lc) {
            var c = g.xl;
            var i: usize = 0;
            while (i < idx) : (i += 1) {
                c += g.widths[i];
                if (i + 1 < lc) c += gapStyled(cfg, g.slots, i, g.m.gap, g.m.island_gap, g.m.strip_inner);
            }
            return c;
        }
        var c = g.xl + g.left_w + g.sec_gap;
        var i: usize = lc;
        while (i < idx) : (i += 1) {
            c += g.widths[i];
            if (i + 1 < g.slots.len) c += gapStyled(cfg, g.slots, i, g.m.gap, g.m.island_gap, g.m.strip_inner);
        }
        return c;
    }
    var c = g.start_x;
    var i: usize = 0;
    while (i < idx) : (i += 1) {
        c += g.widths[i];
        if (i + 1 < g.slots.len) c += gapStyled(cfg, g.slots, i, g.m.gap, g.m.island_gap, g.m.strip_inner);
    }
    return c;
}

/// Layout x of the *left edge of the compressed* strip for slot `idx`.
pub fn slotSurfaceX(cfg: *const ShellConfig, g: *const Geom, idx: usize) f64 {
    return layoutXToSurface(slotLayoutX(cfg, g, idx), g.mid_x, g.h_scale);
}

/// Layout x just past slot `idx`'s content.
pub fn slotEndLayoutX(cfg: *const ShellConfig, g: *const Geom, idx: usize) f64 {
    if (idx >= g.slots.len) return 0.0;
    return slotLayoutX(cfg, g, idx) + g.widths[idx];
}

/// One pill's uncompressed layout span, inner padding included: what the
/// paint loop turns into a rounded dock background for every run, islands
/// included.
pub const PillBounds = struct {
    first: usize,
    last: usize,
    x0: f64,
    x1: f64,
};

pub fn pillBounds(cfg: *const ShellConfig, g: *const Geom, first: usize) PillBounds {
    const last = pillLast(cfg, g.slots, first);
    return .{
        .first = first,
        .last = last,
        .x0 = slotLayoutX(cfg, g, first) - g.m.strip_inner,
        .x1 = slotEndLayoutX(cfg, g, last) + g.m.strip_inner,
    };
}

/// Hit-test an uncompressed layout x against the slot rows.
pub fn slotAtLayout(cfg: *const ShellConfig, g: *const Geom, lx: f64) ?usize {
    for (g.slots, 0..) |_, i| {
        const left = slotLayoutX(cfg, g, i);
        if (lx >= left and lx < left + g.widths[i]) return i;
    }
    return null;
}

// Pill geometry and content width

pub const Pill = struct {
    x: f64,
    y: f64,
    box_w: f64,
    box_h: f64,
};

/// The pill's own padding: what `contentWidth` adds around the strip on both
/// sides. The fit pass needs the same number to know what the strip may
/// claim from an output, so it is a helper rather than a second copy of the
/// `24.0 * sc`.
pub fn outerPad(cfg: *const ShellConfig, fit: f64) i32 {
    const sc = uiScale(cfg) * fit;
    const base: f64 = if (cfg.dock.dock_slim) 14.0 else 24.0;
    return @max(8, @as(i32, @intFromFloat(round(base * sc))));
}

/// Bar geometry inside the layer surface. The surface is taller than the bar
/// by exactly the bottom gap (`desiredSize`) and is anchored to the screen's
/// bottom edge, so the bar sits at the surface's *top*: the padding below it
/// is the dock margin, and the compositor never has to know about it (the
/// surface's strut covers the whole footprint in `syncExclusive`).
/// Bottom-aligning the bar in the padded surface — an earlier shape of this —
/// put the gap *above* the bar, where it renders as nothing, and left the bar
/// flush with the screen edge: moving the margin slider then moved nothing.
pub fn pillGeometry(cfg: *const ShellConfig, cfg_w: i32, cfg_h: i32, dock_h: i32, anim_offset_px: i32, fit: f64) Pill {
    const w: f64 = @floatFromInt(cfg_w);
    const sc = uiScale(cfg) * fit;
    const box_h: f64 = @floatFromInt(dock_h);
    const side: f64 = if (cfg.dock.dock_slim) 14.0 else 24.0;
    const side_px = side * sc;
    const box_w = @max(120.0 * sc, w - side_px);
    // The configured height says how much surface there is under the bar,
    // not where the bar is: `anim_offset_px` slides it from the top edge.
    _ = cfg_h;
    return .{
        .x = (w - box_w) / 2.0,
        .y = @as(f64, @floatFromInt(anim_offset_px)),
        .box_w = box_w,
        .box_h = box_h,
    };
}

/// `dock_compute_widget_strip_width` — the layer surface's content width.
pub fn contentWidth(cfg: *const ShellConfig, total_px: f64, fit: f64) i32 {
    const outer = outerPad(cfg, fit);
    const mid: i32 = outer + @as(i32, @intFromFloat(@ceil(total_px))) + outer;
    return @min(@max(mid, 120), 4800);
}
// Tests

fn load(text: []const u8) !schema.Loaded {
    return schema.loadText(std.testing.allocator, text);
}

test "widgets: implementation type resolves pear_center and overrides" {
    const t = std.testing;
    var cfg = try load(
        \\[widget.pear_center]
        \\[widget.custom]
        \\type = "clock"
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    try t.expectEqualStrings("control_center", implType(c, "pear_center"));
    try t.expectEqualStrings("clock", implType(c, "custom"));
    // Unknown ids pass through unchanged.
    try t.expectEqualStrings("volume_mixer", implType(c, "volume_mixer"));
}

test "widgets: explicit pear_center type override and system tray alias" {
    const t = std.testing;
    var cfg = try load(
        \\[widget.pear_center]
        \\type = "pear_center"
        \\[widget.tray]
        \\type = "system_tray"
        \\[widget.sneaky]
        \\type = "system_tray"
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    try t.expectEqualStrings("control_center", implType(c, "pear_center"));
    try t.expect(tokenIsSystemTray(c, "tray"));
    try t.expect(tokenIsSystemTray(c, "system_tray"));
    try t.expect(tokenIsSystemTray(c, "sneaky"));
    try t.expect(!tokenIsSystemTray(c, "clock"));
}

test "widgets: instance enabled honours the enabled setting" {
    const t = std.testing;
    var cfg = try load(
        \\[widget.off]
        \\enabled = false
        \\[widget.also_off]
        \\enabled = "n"
        \\[widget.on]
        \\enabled = true
        \\[widget.unset]
        \\explicit = 1
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    try t.expect(!instanceEnabled(c, "off"));
    try t.expect(!instanceEnabled(c, "also_off"));
    try t.expect(instanceEnabled(c, "on"));
    try t.expect(instanceEnabled(c, "unset"));
    // No instance at all still means enabled.
    try t.expect(instanceEnabled(c, "missing"));

    // Empty string is truthy (front-char rule).
    var blank = try load(
        \\[widget.blank]
        \\enabled = ""
    );
    defer blank.deinit();
    try t.expect(instanceEnabled(&blank.cfg, "blank"));
}

test "widgets: dock_widgets_enabled gates the ornamental widgets" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\dock_widgets_enabled = false
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    try t.expect(!stripWidgetBlocked(c, "pinned_apps"));
    try t.expect(!stripWidgetBlocked(c, "running_apps"));
    try t.expect(!stripWidgetBlocked(c, "tray"));
    try t.expect(!stripWidgetBlocked(c, "settings_button"));
    try t.expect(!stripWidgetBlocked(c, "trash"));
    try t.expect(stripWidgetBlocked(c, "clock"));
    try t.expect(stripWidgetBlocked(c, "weather"));
    try t.expect(stripWidgetBlocked(c, "overview"));

    var on = try load(
        \\[dock]
        \\dock_widgets_enabled = true
    );
    defer on.deinit();
    try t.expect(!stripWidgetBlocked(&on.cfg, "clock"));
}

test "widgets: defaults only when every section is empty" {
    const t = std.testing;
    var empty = try load("");
    defer empty.deinit();
    const e = sections(&empty.cfg);
    try t.expectEqual(@as(usize, 2), e.left.len);
    try t.expectEqual(@as(usize, 4), e.center.len);
    try t.expectEqual(@as(usize, 6), e.right.len);

    var partial = try load(
        \\[dock]
        \\left_widgets = ["smenu"]
    );
    defer partial.deinit();
    const p = sections(&partial.cfg);
    try t.expectEqual(@as(usize, 1), p.left.len);
    try t.expectEqual(@as(usize, 0), p.center.len);
}

test "widgets: section expansion flattens the widget lists" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\left_widgets = ["smenu", "media"]
        \\center_widgets = ["pinned_apps", "running_apps", "trash"]
        \\right_widgets = ["tray", "clock", "pear_center"]
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    const sources = Sources{
        .pinned = &.{ "firefox", "kitty" },
        .running = &.{"spotify"},
        .tray = &.{ "org.example.One", "org.example.Two" },
    };
    var strip = try buildStrip(t.allocator, c, sources);
    defer strip.deinit(t.allocator);

    try t.expectEqual(@as(usize, 2), strip.left_n);
    try t.expectEqual(@as(usize, 4), strip.center_n);
    try t.expectEqual(@as(usize, 4), strip.right_n);
    try t.expectEqual(@as(usize, 10), strip.slots.len);

    try t.expectEqual(Kind.smenu, strip.slots[0].kind);
    try t.expectEqual(Kind.media, strip.slots[1].kind);
    try t.expectEqual(Kind.app, strip.slots[2].kind);
    try t.expect(strip.slots[2].is_pinned);
    try t.expectEqualStrings("firefox", strip.slots[2].key);
    try t.expect(!strip.slots[4].is_pinned);
    try t.expectEqual(Kind.trash, strip.slots[5].kind);
    try t.expectEqual(Kind.tray, strip.slots[6].kind);
    try t.expectEqual(Kind.clock, strip.slots[8].kind);
    try t.expectEqual(Kind.pear_center, strip.slots[9].kind);
}

test "widgets: disabled instances never reach the strip" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\center_widgets = ["pinned_apps", "trash"]
        \\[widget.trash]
        \\enabled = false
    );
    defer cfg.deinit();
    var strip = try buildStrip(t.allocator, &cfg.cfg, .{ .pinned = &.{"a"} });
    defer strip.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), strip.slots.len);
    try t.expectEqual(Kind.app, strip.slots[0].kind);
}

test "widgets: effective sizing" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\icon_size = 44
        \\icon_spacing = 15
        \\radius = 35
        \\bottom_gap = 2
        \\scale = 1.0
        \\bar_follows_icons = true
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    try t.expectEqual(@as(f64, 1.0), uiScale(c));
    try t.expectEqual(@as(i32, 44), effectiveIcon(c));
    // 15 * 1.0 = 15 > 1, so the 0.6 compression applies: round(9) = 9.
    try t.expectEqual(@as(i32, 9), effectiveGap(c));
    try t.expectEqual(@as(i32, 68), heightForIcon(44, false));
    try t.expectEqual(@as(i32, 68), effectiveBarHeight(c));
    try t.expectEqual(@as(i32, 2), effectiveBottomGap(c));
    try t.expectEqual(@as(i32, 35), effectiveRadius(c));
    try t.expectEqual(@as(f64, 12.0), stripInnerMargin(c));
}

test "widgets: slim dock trims the bar and the side padding" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\icon_size = 44
        \\scale = 1.0
        \\bar_follows_icons = true
        \\slim_dock = true
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    try t.expectEqual(@as(i32, 54), heightForIcon(44, true));
    try t.expectEqual(@as(i32, 54), effectiveBarHeight(c));
    try t.expectEqual(@as(f64, 7.0), stripInnerMargin(c));
    try t.expectEqual(@as(i32, 14), outerPad(c, 1.0));
}

test "widgets: only the kinds whose arm paints one own a pill" {
    const t = std.testing;
    // The five kinds painted on the bare bar: the three bare logo slots get
    // only the hover wash, and app/tray are covered by their run pill
    // instead (`runPillLen`) — a cell with a pill of its own would composite
    // over the run's and read as one darker capsule mid-bar.
    for ([_]Kind{ .app, .tray, .spotlight, .app_drawer, .app_menu }) |k| {
        try t.expect(!ownsPill(k));
    }
    // Smenu and the trash ride the generic `paintSlot` arm, which paints the
    // pill for them the same way it does for the widgets beside them.
    try t.expect(ownsPill(.smenu));
    try t.expect(ownsPill(.trash));
    // Enumerating the whole enum proves the five above are *exactly* the
    // five: anything else that answered false would push `bare` past it.
    var bare: usize = 0;
    var owned: usize = 0;
    inline for (reflection.enumFields(Kind)) |f| {
        if (ownsPill(@enumFromInt(f.value))) owned += 1 else bare += 1;
    }
    try t.expectEqual(@as(usize, 5), bare);
    // The rest — settings, overview, volume mixer, vpn, clipstack, layout,
    // audio center and every widget whose `paint_*_slot` calls `paint_pill`
    // itself. `layout` sits here because its own painter draws the pill the
    // same way bluetooth's and battery's do.
    try t.expectEqual(@as(usize, 18), owned);
}

test "widgets: gap rules" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\dock_pinned_apps_tray_pill = true
        \\dock_running_apps_tray_pill = true
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    const pinned = Slot{ .kind = .app, .key = "a", .is_pinned = true };
    const running = Slot{ .kind = .app, .key = "b" };
    const tray = Slot{ .kind = .tray, .key = "x" };
    const clock = Slot{ .kind = .clock, .key = "clock" };

    // Last slot is always 0.
    try t.expectEqual(@as(f64, 0.0), gapAfter(c, &.{clock}, 0, 10.0));
    // pinned -> pinned collapses under the pill setting.
    try t.expectEqual(@as(f64, 0.0), gapAfter(c, &.{ pinned, pinned }, 0, 10.0));
    // running -> running collapses too.
    try t.expectEqual(@as(f64, 0.0), gapAfter(c, &.{ running, running }, 0, 10.0));
    // pinned -> running gets the widened gap.
    try t.expectEqual(@as(f64, 15.0), gapAfter(c, &.{ pinned, running }, 0, 10.0));
    // tray -> tray collapses.
    try t.expectEqual(@as(f64, 0.0), gapAfter(c, &.{ tray, tray }, 0, 10.0));
    // plain gap otherwise.
    try t.expectEqual(@as(f64, 10.0), gapAfter(c, &.{ clock, tray }, 0, 10.0));
    // Without the pill settings pinned -> pinned keeps the default gap.
    var plain = try load("");
    defer plain.deinit();
    try t.expectEqual(@as(f64, 10.0), gapAfter(&plain.cfg, &.{ pinned, pinned }, 0, 10.0));
}

test "widgets: shared run pills cover a whole run, and only its first slot" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\dock_pinned_apps_tray_pill = true
        \\dock_running_apps_tray_pill = true
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    var plain = try load("");
    defer plain.deinit();

    const pinned = Slot{ .kind = .app, .key = "a", .is_pinned = true };
    const running = Slot{ .kind = .app, .key = "b" };
    const tray = Slot{ .kind = .tray, .key = "x" };
    const clock = Slot{ .kind = .clock, .key = "clock" };
    const trash = Slot{ .kind = .trash, .key = "trash" };

    // The pinned run starts at 0; slot 1 is inside it, not the start of one.
    try t.expectEqual(@as(usize, 2), runPillLen(c, &.{ pinned, pinned, clock }, 0));
    try t.expectEqual(@as(usize, 0), runPillLen(c, &.{ pinned, pinned, clock }, 1));
    try t.expectEqual(@as(usize, 0), runPillLen(c, &.{ pinned, pinned, clock }, 2));
    // pinned -> running splits the run in two.
    try t.expectEqual(@as(usize, 1), runPillLen(c, &.{ pinned, running }, 0));
    try t.expectEqual(@as(usize, 1), runPillLen(c, &.{ pinned, running }, 1));
    // The trash is its own widget pill, never a run tail.
    try t.expectEqual(@as(usize, 2), runPillLen(c, &.{ running, running, trash }, 0));
    try t.expectEqual(@as(usize, 0), runPillLen(c, &.{ running, running, trash }, 2));
    // Tray items always share, with no config gate.
    try t.expectEqual(@as(usize, 2), runPillLen(c, &.{ tray, tray, clock }, 0));
    try t.expectEqual(@as(usize, 2), runPillLen(&plain.cfg, &.{ tray, tray, clock }, 0));
    // App runs need the pill settings.
    try t.expectEqual(@as(usize, 0), runPillLen(&plain.cfg, &.{ pinned, pinned }, 0));
    // Widgets never start an app run.
    try t.expectEqual(@as(usize, 0), runPillLen(c, &.{ clock, tray }, 0));
    // Out of range is empty, not a panic.
    try t.expectEqual(@as(usize, 0), runPillLen(c, &.{pinned}, 1));
}

test "widgets: slot widths" {
    const t = std.testing;
    var cfg = try load(
        \\[widget.bluetooth]
        \\[widget.battery]
        \\show_percent = false
        \\[widget.clock]
        \\show_text = false
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    const m = Metrics{
        .icon = 44,
        .gap = 9,
        .bar_h = 72,
        .ui_scale = 1.0,
        .strip_inner = 12,
        .pill_x = 0,
        .box_w = 800,
    };
    const meas = Measured{};

    // Default: icon only.
    try t.expectEqual(@as(f64, 44), slotWidth(c, .{ .kind = .app, .key = "x" }, m, meas));
    try t.expectEqual(@as(f64, 44), slotWidth(c, .{ .kind = .settings, .key = "settings_button" }, m, meas));
    // Clock with text off (or with nothing to measure) takes the wide fallback.
    const clock_fallback = @max(56.0, m.icon * 2.4);
    try t.expectEqual(clock_fallback, slotWidth(c, .{ .kind = .clock, .key = "clock" }, m, meas));
    // Control center defaults to three glyphs.
    const sc = 44.0 / 30.0;
    const hpad = @max(6.0, 8.0 * sc);
    const cc_gap = @max(5.0, 6.0 * sc);
    const glyph = clampf(44.0 * 0.45, 12.0, 24.0);
    const want = clampf(hpad * 2.0 + 3 * glyph + 2 * cc_gap, 48.0, @min(72.0 * 6.5, 240.0));
    try t.expectEqual(want, slotWidth(c, .{ .kind = .control_center, .key = "pear_center" }, m, meas));
    // Bluetooth without a label is icon + 4 * ui scale.
    try t.expectEqual(@as(f64, 48), slotWidth(c, .{ .kind = .bluetooth, .key = "bluetooth" }, m, meas));
    // Battery with the percentage hidden is the same shape.
    try t.expectEqual(@as(f64, 48), slotWidth(c, .{ .kind = .battery, .key = "battery" }, m, meas));
    // Empty workspaces use the compact fallback: min(bar_h * 3.5, 120).
    try t.expectEqual(@as(f64, 120.0), slotWidth(c, .{ .kind = .workspaces, .key = "workspaces" }, m, meas));
    // Weather with no reading still gets its minimum.
    try t.expectEqual(@as(f64, 72.0), slotWidth(c, .{ .kind = .weather, .key = "weather" }, m, meas));

    // Clock with text on and a real measurement clamps into its band.
    var plain = try load("");
    defer plain.deinit();
    const measured = Measured{ .clock_max_w = 90 };
    try t.expectEqual(@as(f64, 110.0), slotWidth(&plain.cfg, .{ .kind = .clock, .key = "clock" }, m, measured));
    // No measurement at all takes the same wide fallback.
    try t.expectEqual(clock_fallback, slotWidth(&plain.cfg, .{ .kind = .clock, .key = "clock" }, m, Measured{}));
}

test "widgets: the media floor is the pill with its title taken off" {
    const t = std.testing;
    var plain = try load("");
    defer plain.deinit();
    const m = Metrics{
        .icon = 44,
        .gap = 9,
        .bar_h = 72,
        .ui_scale = 1.0,
        .strip_inner = 12,
        .pill_x = 0,
        .box_w = 2400,
    };
    const s = Slot{ .kind = .media, .key = "media" };
    const wide = Measured{ .media_text_w = 300, .media_ctrl_w = 60 };
    const w_wide = slotWidth(&plain.cfg, s, m, wide);
    // 13.68*2 (inner) + 34.32 (art) + 14.667*2 (gaps) + 60 (transport).
    const want_floor = 151.0133;
    try t.expectApproxEqAbs(want_floor, mediaMinWidth(44.0, 72.0, 60.0, 300.0), 1e-3);
    // The floor is the *textless* pill: art and the transport row keep their
    // share, the title gives up all of its.
    try t.expectApproxEqAbs(want_floor, slotWidth(&plain.cfg, s, m, .{ .media_text_w = 0, .media_ctrl_w = 60 }), 1e-3);
    try t.expectApproxEqAbs(want_floor, mediaMinWidth(44.0, 72.0, 60.0, 0.0), 1e-3);
    // The title is what makes the pill wide, so the wide pill is wide by
    // almost exactly the title's own width.
    try t.expectApproxEqAbs(300.0, w_wide - want_floor, 1e-3);
    // And the ceiling still caps it: 920, whatever the title asks for.
    try t.expectEqual(@as(f64, 920.0), mediaCapWidth(72.0));
    try t.expectEqual(@as(f64, 920.0), slotWidth(&plain.cfg, s, m, .{ .media_text_w = 5000, .media_ctrl_w = 60 }));
    // The floor is also the width `slotWidth` answers with when there is
    // nothing to say, which is what keeps the two from ever disagreeing.
    try t.expectApproxEqAbs(want_floor, mediaMinWidth(44.0, 72.0, 60.0, 1234.0), 1e-3);
}

test "widgets: a slot's floor is what the fit pass may take from it" {
    const t = std.testing;
    var plain = try load("");
    defer plain.deinit();
    const m = Metrics{
        .icon = 44,
        .gap = 9,
        .bar_h = 72,
        .ui_scale = 1.0,
        .strip_inner = 12,
        .pill_x = 0,
        .box_w = 2400,
    };
    const media = Slot{ .kind = .media, .key = "media" };
    const clock = Slot{ .kind = .clock, .key = "clock" };
    const workspaces = Slot{ .kind = .workspaces, .key = "workspaces" };
    const app = Slot{ .kind = .app, .key = "firefox" };
    const bluetooth = Slot{ .kind = .bluetooth, .key = "bluetooth" };
    const meas = Measured{ .media_text_w = 300, .media_ctrl_w = 60, .clock_max_w = 90, .workspace_count = 5, .workspace_w = 346 };

    // Media: the title is all there is to give — the floor is the textless
    // pill, so the marquee takes over before the transport row does.
    const media_w = slotWidth(&plain.cfg, media, m, meas);
    try t.expectApproxEqAbs(mediaMinWidth(44.0, 72.0, 60.0, 300.0), slotFloorWidth(&plain.cfg, media, m, meas, media_w), 1e-9);
    // Clock: it gives up the padding either side of the time, never the time.
    const clock_w = slotWidth(&plain.cfg, clock, m, meas);
    // 110 - (90 + 4) = 16 of padding, and the run itself survives.
    try t.expectApproxEqAbs(94.0, slotFloorWidth(&plain.cfg, clock, m, meas, clock_w), 1e-9);
    try t.expect(slotFloorWidth(&plain.cfg, clock, m, meas, clock_w) >= meas.clock_max_w);
    // Workspaces scales its cells, so its floor is the widget's own minimum.
    const ws_w = slotWidth(&plain.cfg, workspaces, m, meas);
    try t.expectApproxEqAbs(60.0, slotFloorWidth(&plain.cfg, workspaces, m, meas, ws_w), 1e-9);
    // An app icon has no smaller version: its floor is itself.
    const app_w = slotWidth(&plain.cfg, app, m, meas);
    try t.expectApproxEqAbs(app_w, slotFloorWidth(&plain.cfg, app, m, meas, app_w), 1e-9);
    // Neither does a bluetooth label, which `Measured` never sees — the width
    // in hand is the only one that could be trusted.
    const bt_w = slotWidth(&plain.cfg, bluetooth, m, meas);
    try t.expectApproxEqAbs(bt_w, slotFloorWidth(&plain.cfg, bluetooth, m, meas, bt_w), 1e-9);
    // Every floor stays a floor: never above the width it belongs to, and
    // never negative, so the fit pass's arithmetic cannot go wrong way round.
    for ([_]Slot{ media, clock, workspaces, app, bluetooth }) |s| {
        const w = slotWidth(&plain.cfg, s, m, meas);
        const floor = slotFloorWidth(&plain.cfg, s, m, meas, w);
        try t.expect(floor > 0.0 and floor <= w);
    }
}

test "widgets: strip geometry compresses and splits" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\icon_size = 44
        \\icon_spacing = 15
        \\left_widgets = ["smenu"]
        \\center_widgets = []
        \\right_widgets = ["clock"]
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    const slots = [_]Slot{
        .{ .kind = .smenu, .key = "smenu" },
        .{ .kind = .clock, .key = "clock" },
    };
    const widths = [_]f64{ 44, 110 };
    const m = Metrics.of(c, 100, 400, 1.0);
    const g = computeGeom(c, &slots, &widths, 1, 0, 1, m);

    try t.expect(g.use_lr);
    try t.expectEqual(@as(f64, 1), g.h_scale);
    // Side-by-side anchors the right edge to the pill's inner bound.
    const half = m.strip_inner * 0.5;
    try t.expectEqual(100 + 400 - half - 110, g.xr);

    // Slot layout x agrees with the walk.
    try t.expectEqual(g.xl, slotLayoutX(c, &g, 0));
    try t.expectEqual(g.xl + g.left_w + g.sec_gap, slotLayoutX(c, &g, 1));

    // Narrow pill: no side-by-side placement fits, so we fall back to centered.
    const gn = computeGeom(c, &slots, &widths, 1, 0, 1, Metrics.of(c, 0, 60, 1.0));
    try t.expect(!gn.use_lr);

    // Compression scale kicks in only past the pill's inner width.
    try t.expectEqual(@as(f64, 1), widgetStripHScale(400, 100, 12));
    const compressed = widgetStripHScale(400, 500, 12);
    try t.expect(compressed < 1.0);
    try t.expectApproxEqAbs(@as(f64, 0.776), compressed, 1e-9);
}

test "widgets: surface and layout x round trip" {
    const t = std.testing;
    const mid = 250.0;
    const sc = 0.75;
    const lx = 123.5;
    const sx = layoutXToSurface(lx, mid, sc);
    try t.expectApproxEqAbs(lx, surfaceXToLayout(sx, mid, sc), 1e-9);
}

test "widgets: pill geometry and content width" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\scale = 1.0
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    const p = pillGeometry(c, 1920, 1080, 72, 0, 1.0);
    try t.expectEqual(@as(f64, 1896), p.box_w);
    try t.expectEqual(@as(f64, 12), p.x);
    // The bar hugs the *top* of the surface: the surface is taller than the
    // bar by the bottom gap, and that padding below the bar is the margin.
    try t.expectEqual(@as(f64, 0), p.y);
    // The animation slide offsets it from that same top edge.
    try t.expectEqual(@as(f64, 9), pillGeometry(c, 1920, 1080, 72, 9, 1.0).y);
    try t.expectEqual(@as(f64, 72), p.box_h);
    try t.expectEqual(@as(i32, 120), contentWidth(c, 0, 1.0));
    try t.expect(contentWidth(c, 600, 1.0) > 600);
    try t.expectEqual(@as(i32, 4800), contentWidth(c, 99999, 1.0));
}

test "widgets: launch targets" {
    const t = std.testing;
    try t.expectEqualStrings("firefox", launchTarget(.{ .kind = .app, .key = "firefox" }) orelse "");
    try t.expectEqualStrings("event-horizon-settings", launchTarget(.{ .kind = .settings, .key = "settings_button" }) orelse "");
    try t.expectEqualStrings("event-horizon-rail-settings", launchTarget(.{ .kind = .settings, .key = "rail_settings" }) orelse "");
    try t.expectEqualStrings("event-horizon-audio-center", launchTarget(.{ .kind = .audio_center, .key = "audio_center_button" }) orelse "");
    try t.expect(launchTarget(.{ .kind = .audio_center, .key = "" }) == null);
    try t.expect(launchTarget(.{ .kind = .clock, .key = "clock" }) == null);
    try t.expect(launchTarget(.{ .kind = .app, .key = "" }) == null);
}

test "widgets: audio_center_button is a launcher slot" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\right_widgets = ["audio_center_button"]
    );
    defer cfg.deinit();
    var strip = try buildStrip(t.allocator, &cfg.cfg, .{});
    defer strip.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), strip.slots.len);
    try t.expectEqual(Kind.audio_center, strip.slots[0].kind);
    try t.expectEqualStrings("audio_center_button", strip.slots[0].key);
    // The impl name works too, for configs written by hand.
    var cfg2 = try load(
        \\[dock]
        \\right_widgets = ["audio_center"]
    );
    defer cfg2.deinit();
    var strip2 = try buildStrip(t.allocator, &cfg2.cfg, .{});
    defer strip2.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), strip2.slots.len);
    try t.expectEqual(Kind.audio_center, strip2.slots[0].kind);
}

test "widgets: rail_settings is a settings-kind rail slot" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\right_widgets = ["rail_settings"]
    );
    defer cfg.deinit();
    var strip = try buildStrip(t.allocator, &cfg.cfg, .{});
    defer strip.deinit(t.allocator);
    // One slot of the shared settings kind, keyed by its own token.
    try t.expectEqual(@as(usize, 1), strip.slots.len);
    try t.expectEqual(Kind.settings, strip.slots[0].kind);
    try t.expectEqualStrings("rail_settings", strip.slots[0].key);
}

test "widgets: pear_center is its own strip kind" {
    const t = std.testing;
    var cfg = try load(
        \\[widget.pear_center]
        \\[widget.legacy]
        \\type = "control_center"
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    // Raw pear instances separate; explicit legacy type stays legacy.
    try t.expect(isPearInstance(c, "pear_center"));
    try t.expect(!isPearInstance(c, "legacy"));
    try t.expect(!isPearInstance(c, "clock"));
    // The shared impl mapping is untouched (other consumers keep working).
    try t.expectEqualStrings("control_center", implType(c, "pear_center"));

    var strip = try buildStrip(t.allocator, c, .{});
    defer strip.deinit(t.allocator);
    // Dock defaults carry pear_center (right) and no legacy control_center.
    var found_pear = false;
    var found_cc = false;
    for (strip.slots) |s| {
        if (s.kind == .pear_center) found_pear = true;
        if (s.kind == .control_center) found_cc = true;
    }
    try t.expect(found_pear);
    try t.expect(!found_cc);

    // Explicit legacy widget keeps the legacy kind.
    var cfg2 = try load(
        \\[dock]
        \\right_widgets = ["legacy"]
        \\[widget.legacy]
        \\type = "control_center"
    );
    defer cfg2.deinit();
    var strip2 = try buildStrip(t.allocator, &cfg2.cfg, .{});
    defer strip2.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), strip2.slots.len);
    try t.expectEqual(Kind.control_center, strip2.slots[0].kind);
}

test "widgets: pear slot width matches the shared pill math" {
    const t = std.testing;
    var cfg = try load("");
    defer cfg.deinit();
    const c = &cfg.cfg;
    const m = Metrics{
        .icon = 44,
        .gap = 9,
        .bar_h = 72,
        .ui_scale = 1.0,
        .strip_inner = 12,
        .pill_x = 0,
        .box_w = 800,
    };
    const sc = 44.0 / 30.0;
    const hpad = @max(6.0, 8.0 * sc);
    const cc_gap = @max(5.0, 6.0 * sc);
    const glyph = clampf(44.0 * 0.45, 12.0, 24.0);
    const want = clampf(hpad * 2.0 + 3 * glyph + 2 * cc_gap, 48.0, @min(72.0 * 6.5, 240.0));
    try t.expectEqual(want, slotWidth(c, .{ .kind = .pear_center, .key = "pear_center" }, m, .{}));
    try t.expectEqual(
        slotWidth(c, .{ .kind = .control_center, .key = "x" }, m, .{}),
        slotWidth(c, .{ .kind = .pear_center, .key = "x" }, m, .{}),
    );
}

test "widgets: islands split the bar into pills and keep the pad math" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\islands = ["media", "pinned_apps"]
        \\island_gap = 10
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    // 15 -> gap 9 (`effectiveGap`), island gap 10, pad 12 (`strip_inner`).
    try t.expectEqual(@as(i32, 9), effectiveGap(c));
    try t.expectEqual(@as(i32, 10), effectiveIslandGap(c));

    const slots = [_]Slot{
        .{ .kind = .smenu, .key = "smenu", .token = "smenu" },
        .{ .kind = .media, .key = "media", .token = "media" },
        .{ .kind = .app, .key = "a", .token = "pinned_apps", .is_pinned = true },
        .{ .kind = .app, .key = "b", .token = "pinned_apps", .is_pinned = true },
        .{ .kind = .clock, .key = "clock", .token = "clock" },
    };
    const widths = [_]f64{ 44, 120, 44, 44, 90 };

    // Edges around the two islands; the pinned run stays whole inside its
    // island even while both its slots are islands (`pinned_apps`).
    try t.expect(islandEdge(c, &slots, 0));
    try t.expect(islandEdge(c, &slots, 1));
    try t.expect(!islandEdge(c, &slots, 2));
    try t.expect(islandEdge(c, &slots, 3));
    try t.expectEqual(@as(usize, 0), pillLast(c, &slots, 0));
    try t.expectEqual(@as(usize, 1), pillLast(c, &slots, 1));
    try t.expectEqual(@as(usize, 3), pillLast(c, &slots, 2));
    try t.expectEqual(@as(usize, 4), pillLast(c, &slots, 4));

    // Styled width: 34 at every pill edge (12 + 10 + 12), 9 inside runs.
    try t.expectEqual(@as(f64, 34), gapStyled(c, &slots, 0, 9, 10, 12));
    try t.expectEqual(@as(f64, 9), gapStyled(c, &slots, 2, 9, 10, 12));
    const total = concatWidth(c, &slots, &widths, 9, 1.0);
    try t.expectEqual(@as(f64, 453), total);

    const m = Metrics.of(c, 100, 500, 1.0);
    const g = computeGeom(c, &slots, &widths, 1, 3, 1, m);
    try t.expectEqual(total, g.concat_total);
    // Centered row: pad, then equal slack each side.
    try t.expectEqual(@as(f64, 123.5), g.start_x);

    // Pill bounds: edge to edge exactly `island_gap` apart, every pill
    // padded by `strip_inner`.
    const p0 = pillBounds(c, &g, 0);
    const p1 = pillBounds(c, &g, 1);
    const p2 = pillBounds(c, &g, 2);
    const p3 = pillBounds(c, &g, 4);
    try t.expectEqual(@as(f64, 111.5), p0.x0);
    try t.expectEqual(@as(f64, 179.5), p0.x1);
    try t.expectEqual(@as(f64, 189.5), p1.x0);
    try t.expectEqual(@as(f64, 333.5), p1.x1);
    try t.expectEqual(@as(f64, 343.5), p2.x0);
    try t.expectEqual(@as(f64, 464.5), p2.x1);
    try t.expectEqual(@as(f64, 474.5), p3.x0);
    try t.expectEqual(@as(f64, 588.5), p3.x1);
    try t.expectApproxEqAbs(@as(f64, 10), p1.x0 - p0.x1, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 10), p2.x0 - p1.x1, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 10), p3.x0 - p2.x1, 1e-9);

    // The paint pass draws the dock background for every pill, island or not;
    // the air between two pills is not a slot: clicks fall through.
    try t.expectEqual(@as(?usize, null), slotAtLayout(c, &g, 185.0));
    try t.expectEqual(@as(?usize, 1), slotAtLayout(c, &g, 250.0));

    // No islands: one pill, and the geometry is exactly what it always was
    // (`pill_x + (box_w - concat) / 2`).
    var plain = try load(
        \\[dock]
        \\island_gap = 10
    );
    defer plain.deinit();
    const pc = &plain.cfg;
    const pg = computeGeom(pc, &slots, &widths, 1, 3, 1, Metrics.of(pc, 100, 500, 1.0));
    try t.expectEqual(@as(f64, 378), pg.concat_total);
    try t.expectEqual(@as(f64, 161), pg.start_x);
    try t.expectEqual(@as(usize, slots.len - 1), pillLast(pc, &slots, 0));
}

test "widgets: section islands own every slot in that section only" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\islands = ["@center"]
        \\island_gap = 10
    );
    defer cfg.deinit();
    const c = &cfg.cfg;

    // The same token (`clock`) also sits in LEFT: the section spec must not
    // island that copy just because it matched the center one.
    const slots = [_]Slot{
        .{ .kind = .clock, .key = "clock-l", .token = "clock", .section = .left },
        .{ .kind = .clock, .key = "clock-c", .token = "clock", .section = .center },
        .{ .kind = .app, .key = "a", .token = "pinned_apps", .section = .center, .is_pinned = true },
        .{ .kind = .trash, .key = "trash", .token = "trash", .section = .center },
        .{ .kind = .media, .key = "media", .token = "media", .section = .right },
    };

    try t.expect(!slotIsIsland(c, slots[0]));
    try t.expect(slotIsIsland(c, slots[1]));
    try t.expect(slotIsIsland(c, slots[3]));
    try t.expect(islandEdge(c, &slots, 0));
    try t.expect(!islandEdge(c, &slots, 1));
    try t.expect(!islandEdge(c, &slots, 2));
    try t.expect(islandEdge(c, &slots, 3));
    try t.expectEqual(@as(usize, 3), pillLast(c, &slots, 1));
}

test "widgets: a '+' group links adjacent widgets into one island" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\islands = ["media+clock"]
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    const slots = [_]Slot{
        .{ .kind = .media, .key = "media", .token = "media", .section = .center },
        .{ .kind = .clock, .key = "clock", .token = "clock", .section = .center },
        .{ .kind = .trash, .key = "trash", .token = "trash", .section = .center },
    };
    try t.expect(slotIsIsland(c, slots[0]));
    try t.expect(slotIsIsland(c, slots[1]));
    try t.expect(!slotIsIsland(c, slots[2]));
    try t.expect(!islandEdge(c, &slots, 0));
    try t.expect(islandEdge(c, &slots, 1));
    try t.expectEqual(@as(usize, 1), pillLast(c, &slots, 0));
}

test "widgets: buildStrip stamps tokens so island membership follows the widget" {
    const t = std.testing;
    var cfg = try load(
        \\[dock]
        \\center_widgets = ["pinned_apps", "trash"]
        \\islands = ["pinned_apps"]
    );
    defer cfg.deinit();
    const c = &cfg.cfg;
    var strip = try buildStrip(t.allocator, c, .{ .pinned = &.{ "a", "b" } });
    defer strip.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), strip.slots.len);
    // `key` carries the app; `token` is what the island list matches.
    try t.expectEqualStrings("a", strip.slots[0].key);
    try t.expectEqualStrings("pinned_apps", strip.slots[0].token);
    try t.expectEqualStrings("pinned_apps", strip.slots[1].token);
    try t.expectEqualStrings("trash", strip.slots[2].token);
    try t.expect(slotIsIsland(c, strip.slots[0]));
    try t.expect(!slotIsIsland(c, strip.slots[2]));
    try t.expect(!islandEdge(c, strip.slots, 0));
    try t.expect(islandEdge(c, strip.slots, 1));
}
