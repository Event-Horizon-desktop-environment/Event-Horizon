const std = @import("std");
const app_mod = @import("app.zig");
const zoolander_page = @import("zoolander_page.zig");

// Compositor detection.
// Ordered socket/marker env probes first (Hyprland > Niri > Sway > Labwc >
// Mango), then XDG desktop-hint substrings for compositors with no socket
// variable, then the historical "dwl" alias → Mango. Result is cached, the
// same detection contract.
//
// Used to gate the sidebar: the MangoWM category (id 16) only exists on
// Mango and the Hyprland category (id 33) only on Hyprland —
// categories filter by compositor (`def.id == 16/33` continue-lines).

pub const Kind = enum { unknown, niri, hyprland, sway, mango, labwc, zoolander };

var cached: ?Kind = null;

pub fn kind() Kind {
    if (cached) |k| return k;
    cached = detect();
    return cached.?;
}

const EnvProbe = struct { var_name: []const u8, k: Kind };

const env_probes = [_]EnvProbe{
    .{ .var_name = "HYPRLAND_INSTANCE_SIGNATURE", .k = .hyprland },
    .{ .var_name = "NIRI_SOCKET", .k = .niri },
    .{ .var_name = "SWAYSOCK", .k = .sway },
    .{ .var_name = "LABWC_PID", .k = .labwc },
    .{ .var_name = "MANGO_INSTANCE_SIGNATURE", .k = .mango },
    // Zoolander exports `ZOOLANDER_WSI` to the processes it spawns. A shell
    // it did not start has no marker, so the XDG hint and the control-socket
    // probe below cover those sessions.
    .{ .var_name = "ZOOLANDER_WSI", .k = .zoolander },
    .{ .var_name = "ZOOLANDER_INSTANCE_SIGNATURE", .k = .zoolander },
    .{ .var_name = "ZOOLANDER_SOCKET", .k = .zoolander },
};

const HintProbe = struct { needle: []const u8, k: Kind };

const hint_probes = [_]HintProbe{
    .{ .needle = "niri", .k = .niri },
    .{ .needle = "hypr", .k = .hyprland },
    .{ .needle = "sway", .k = .sway },
    .{ .needle = "mango", .k = .mango },
    .{ .needle = "labwc", .k = .labwc },
    .{ .needle = "zoolander", .k = .zoolander },
};

fn envSet(name: []const u8) bool {
    return getEnv(name).len > 0;
}

fn getEnv(name: []const u8) []const u8 {
    const p = std.c.getenv(@ptrCast(name.ptr)) orelse return "";
    return std.mem.span(p);
}

var hint_buf: [512]u8 = undefined;

/// Combined XDG hint string: XDG_CURRENT_DESKTOP:XDG_SESSION_DESKTOP:DESKTOP_SESSION.
fn desktopHint() []const u8 {
    const vars = [_][]const u8{ "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "DESKTOP_SESSION" };
    var len: usize = 0;
    for (vars) |v| {
        const val = getEnv(v);
        if (val.len == 0) continue;
        if (len > 0 and len < hint_buf.len) {
            hint_buf[len] = ':';
            len += 1;
        }
        const n = @min(val.len, hint_buf.len - len);
        @memcpy(hint_buf[len .. len + n], val[0..n]);
        len += n;
    }
    return hint_buf[0..len];
}

fn containsFolded(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var hit = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                hit = false;
                break;
            }
        }
        if (hit) return true;
    }
    return false;
}

/// Zoolander names its control socket after the Wayland socket, so its
/// presence is provable from the environment alone. It is the definitive
/// signal for a session that carries no marker or hint.
fn zoolanderSocketPresent() bool {
    const dir = getEnv("XDG_RUNTIME_DIR");
    const disp = getEnv("WAYLAND_DISPLAY");
    if (dir.len == 0 or disp.len == 0) return false;
    const base = std.fs.path.basename(disp);
    if (base.len == 0) return false;
    var buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/zoolander-{s}.sock", .{ dir, base }) catch return false;
    const rc = std.os.linux.access(path.ptr, std.posix.F_OK);
    return std.os.linux.errno(rc) == .SUCCESS;
}

fn detect() Kind {
    // A Zoolander hint or marker must win outright: a nested session may
    // still carry the Hyprland marker in its own environment, but a shell it
    // spawned has that marker stripped and lands on the socket probe below.
    for (env_probes) |p| {
        if (p.k == .zoolander and envSet(p.var_name)) return .zoolander;
    }
    const hint = desktopHint();
    if (hint.len > 0) {
        for (hint_probes) |p| {
            if (p.k == .zoolander and containsFolded(hint, p.needle)) return .zoolander;
        }
    }
    for (env_probes) |p| {
        if (p.k != .zoolander and envSet(p.var_name)) return p.k;
    }
    if (hint.len == 0) return if (zoolanderSocketPresent()) .zoolander else .unknown;
    for (hint_probes) |p| {
        if (p.k != .zoolander and containsFolded(hint, p.needle)) return p.k;
    }
    if (containsFolded(hint, "dwl")) return .mango;
    return if (zoolanderSocketPresent()) .zoolander else .unknown;
}

/// Temporary development switch: show the Zoolander pages on every
/// compositor so the parity work can be previewed outside a Zoolander session.
/// Set back to false (and restore the `kind() == .zoolander` gates) when the
/// pages are ready to ship.
pub const unlock_zoolander_pages = true;

/// Sidebar category visibility — skipping `def.id == 16`
/// unless Mango and `def.id == 33` unless Hyprland.
pub fn visibleCategory(cat_id: i32) bool {
    if (cat_id == 16) return kind() == .mango;
    if (cat_id == 33) return kind() == .hyprland;
    if (cat_id == app_mod.zoolander_category_id) return unlock_zoolander_pages or kind() == .zoolander;
    return true;
}

/// Search-result visibility — `settings_search_entry_visible`:
/// Mango pages are tabs 20..26, Hyprland sections are 64..78, and the
/// Zoolander page band comes from `zoolander_page`.
pub fn visibleTab(tab: i32) bool {
    if (tab >= 20 and tab <= 26) return kind() == .mango;
    if (tab >= 64 and tab <= 78) return kind() == .hyprland;
    if (zoolander_page.ownsTab(tab)) return unlock_zoolander_pages or kind() == .zoolander;
    return true;
}

test "settings-compositor: hyprland env wins over XDG hints" {
    const t = std.testing;
    // This process runs under a compositor; whichever it is, detection must
    // land on a concrete kind when any probe var or hint is present.
    const k = kind();
    try t.expect(k == .unknown or k == .niri or k == .hyprland or k == .sway or k == .mango or k == .labwc or k == .zoolander);
    // Detection is cached: repeat calls are identical.
    try t.expectEqual(k, kind());
}

test "settings-compositor: category and tab gates behave as specified" {
    const t = std.testing;
    const k = kind();
    try t.expectEqual(k == .mango, visibleCategory(16));
    try t.expectEqual(k == .hyprland, visibleCategory(33));
    try t.expectEqual(unlock_zoolander_pages or k == .zoolander, visibleCategory(app_mod.zoolander_category_id));
    // Other categories always visible.
    try t.expect(visibleCategory(12));
    try t.expect(visibleCategory(13));
    // Search gates: mango pages 20..26, hyprland sections 64..78, the
    // Zoolander page band, the rest free.
    for ([_]i32{ 20, 21, 22, 23, 24, 25, 26 }) |tab| {
        try t.expectEqual(k == .mango, visibleTab(tab));
    }
    for ([_]i32{ 64, 66, 70, 78 }) |tab| {
        try t.expectEqual(k == .hyprland, visibleTab(tab));
    }
    for ([_]i32{ zoolander_page.first_tab_id, zoolander_page.first_tab_id + 2, zoolander_page.first_tab_id + 4, zoolander_page.last_tab_id }) |tab| {
        try t.expectEqual(unlock_zoolander_pages or k == .zoolander, visibleTab(tab));
    }
    try t.expect(visibleTab(0));
    try t.expect(visibleTab(7));
    try t.expect(visibleTab(34)); // Bing Wallpaper: ordinary tab, always visible
}
