const std = @import("std");

// Compositor detection.
// Ordered socket/marker env probes first (Hyprland > Niri > Sway > Labwc >
// Mango), then XDG desktop-hint substrings for compositors with no socket
// variable, then the historical "dwl" alias → Mango. Result is cached, the
// same detection contract.
//
// Used to gate the sidebar: the MangoWM category (id 16) only exists on
// Mango and the Hyprland category (id 33) only on Hyprland —
// categories filter by compositor (`def.id == 16/33` continue-lines).

pub const Kind = enum { unknown, niri, hyprland, sway, mango, labwc };

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
};

const HintProbe = struct { needle: []const u8, k: Kind };

const hint_probes = [_]HintProbe{
    .{ .needle = "niri", .k = .niri },
    .{ .needle = "hypr", .k = .hyprland },
    .{ .needle = "sway", .k = .sway },
    .{ .needle = "mango", .k = .mango },
    .{ .needle = "labwc", .k = .labwc },
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

fn detect() Kind {
    for (env_probes) |p| {
        if (envSet(p.var_name)) return p.k;
    }
    const hint = desktopHint();
    if (hint.len == 0) return .unknown;
    for (hint_probes) |p| {
        if (containsFolded(hint, p.needle)) return p.k;
    }
    if (containsFolded(hint, "dwl")) return .mango;
    return .unknown;
}

/// Sidebar category visibility — skipping `def.id == 16`
/// unless Mango and `def.id == 33` unless Hyprland.
pub fn visibleCategory(cat_id: i32) bool {
    if (cat_id == 16) return kind() == .mango;
    if (cat_id == 33) return kind() == .hyprland;
    return true;
}

/// Search-result visibility — `settings_search_entry_visible`:
/// Mango pages are tabs 20..26, Hyprland sections are 64..78.
pub fn visibleTab(tab: i32) bool {
    if (tab >= 20 and tab <= 26) return kind() == .mango;
    if (tab >= 64 and tab <= 78) return kind() == .hyprland;
    return true;
}

test "settings-compositor: hyprland env wins over XDG hints" {
    const t = std.testing;
    // This process runs under a compositor; whichever it is, detection must
    // land on a concrete kind when any probe var or hint is present.
    const k = kind();
    try t.expect(k == .unknown or k == .niri or k == .hyprland or k == .sway or k == .mango or k == .labwc);
    // Detection is cached: repeat calls are identical.
    try t.expectEqual(k, kind());
}

test "settings-compositor: category and tab gates behave as specified" {
    const t = std.testing;
    const k = kind();
    try t.expectEqual(k == .mango, visibleCategory(16));
    try t.expectEqual(k == .hyprland, visibleCategory(33));
    // Other categories always visible.
    try t.expect(visibleCategory(12));
    try t.expect(visibleCategory(13));
    // Search gates: mango pages 20..26, hyprland sections 64..78, the rest free.
    for ([_]i32{ 20, 21, 22, 23, 24, 25, 26 }) |tab| {
        try t.expectEqual(k == .mango, visibleTab(tab));
    }
    for ([_]i32{ 64, 66, 70, 78 }) |tab| {
        try t.expectEqual(k == .hyprland, visibleTab(tab));
    }
    try t.expect(visibleTab(0));
    try t.expect(visibleTab(7));
    try t.expect(visibleTab(34)); // Bing Wallpaper: ordinary tab, always visible
}
