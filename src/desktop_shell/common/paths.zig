const std = @import("std");
const config = @import("../../config.zig");

/// Settings roots share `config.leafName()` (`Event-Horizon`), so
/// `EH_ZIG_ISOLATED` moves them together. These mirror `config.zig`'s helpers
/// for callers that live outside the config stack. Zig *settings* live ONLY
/// under `configDir`/`settingsDir` (`~/.config/Event-Horizon`); nothing is
/// read from or written to `~/.local/state/...`.
pub fn configDir(alloc: std.mem.Allocator, xdg_config_home: ?[]const u8, home: ?[]const u8) ![]u8 {
    const leaf = config.leafName();
    if (xdg_config_home) |v| return std.fs.path.join(alloc, &.{ v, leaf });
    if (home) |h| return std.fs.path.join(alloc, &.{ h, ".config", leaf });
    return std.fs.path.join(alloc, &.{ "/tmp", leaf });
}

/// Settings root — same as `configDir` (`~/.config/Event-Horizon`).
pub fn settingsDir(alloc: std.mem.Allocator, xdg_config_home: ?[]const u8, home: ?[]const u8) ![]u8 {
    return configDir(alloc, xdg_config_home, home);
}

pub fn cacheDir(alloc: std.mem.Allocator, xdg_cache_home: ?[]const u8, home: ?[]const u8) ![]u8 {
    const leaf = config.leafName();
    if (xdg_cache_home) |v| return std.fs.path.join(alloc, &.{ v, leaf });
    if (home) |h| return std.fs.path.join(alloc, &.{ h, ".cache", leaf });
    return std.fs.path.join(alloc, &.{ "/tmp", leaf });
}

pub fn runtimeDir(xdg_runtime: ?[]const u8) []const u8 {
    return xdg_runtime orelse "/tmp";
}

/// Normalizes a desktop app id — lower-cases it, drops a trailing `.desktop`,
/// and never answers with an empty string (returns `"unknown"`).
///
/// The empty result is `alloc`ated as `"unknown"` so callers can free the
/// return value uniformly.
pub fn normalizeAppId(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len == 0) return alloc.dupe(u8, "unknown");
    var lower = try alloc.alloc(u8, s.len);
    defer alloc.free(lower);
    for (s, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    // The trimmed view must not be returned directly: it would be freed as a
    // subslice, which the allocator rejects.
    const trimmed = if (lower.len > 8 and std.mem.endsWith(u8, lower, ".desktop"))
        lower[0 .. lower.len - ".desktop".len]
    else
        lower;
    if (trimmed.len == 0) return alloc.dupe(u8, "unknown");
    return alloc.dupe(u8, trimmed);
}

/// True when `hay` ends with `needle` on a `.`/`-` token boundary. Empty and
/// case are handled by the caller.
fn tokenSuffix(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;
    const off = hay.len - needle.len;
    if (!std.ascii.eqlIgnoreCase(hay[off..], needle)) return false;
    if (off == 0) return true;
    const sep = hay[off - 1];
    return sep == '.' or sep == '-';
}

/// Do these two names denote the same application?
///
/// The pinned list holds desktop-file ids (`event-horizon-settings`,
/// `sh.cider.Cider`) while the compositor reports whatever the window's own
/// `app_id` is (`horizon-settings`, `cider`), and neither side is guaranteed
/// to carry a `.desktop` suffix. So: normalise both the way
/// `normalize_desktop_app_id` does, then accept a match when either
/// normalised id is a token-boundary suffix of the other — which is the
/// reverse-DNS / prefix disagreement, and nothing looser. No allocation, so
/// this can sit on the click path and inside the tracker's `isRunning`.
pub fn sameAppId(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const na = stripDesktopSuffix(a);
    const nb = stripDesktopSuffix(b);
    if (na.len == 0 or nb.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(na, nb)) return true;
    return tokenSuffix(na, nb) or tokenSuffix(nb, na);
}

/// The `.desktop` removal `normalizeAppId` does, without the allocation.
fn stripDesktopSuffix(s: []const u8) []const u8 {
    if (s.len > 8 and std.ascii.endsWithIgnoreCase(s, ".desktop")) return s[0 .. s.len - ".desktop".len];
    return s;
}

test "paths: sameAppId agrees on ids the two sides spell differently" {
    const t = std.testing;
    // Exact, with and without the case the desktop file uses.
    try t.expect(sameAppId("steam", "steam"));
    try t.expect(sameAppId("Steam", "steam"));
    try t.expect(sameAppId("Comfy Desktop", "comfy desktop"));
    // `.desktop` on one side only.
    try t.expect(sameAppId("firefox.desktop", "firefox"));
    try t.expect(sameAppId("Firefox", "firefox.desktop"));
    // Reverse-DNS desktop id vs the bare app_id the window reports.
    try t.expect(sameAppId("sh.cider.Cider", "cider"));
    try t.expect(sameAppId("org.gnome.Ptyxis", "ptyxis"));
    // A prefix the desktop file carries and the window does not.
    try t.expect(sameAppId("event-horizon-settings", "horizon-settings"));
    // Empty never matches, not even itself.
    try t.expect(!sameAppId("", ""));
    try t.expect(!sameAppId("", "steam"));
    // A token boundary is required: `iles` may not ride along on the end of
    // `horizon-files`, but a whole `-files` component may — that boundary is
    // what makes `event-horizon-settings` find `horizon-settings`.
    try t.expect(sameAppId("files", "horizon-files"));
    try t.expect(!sameAppId("iles", "horizon-files"));
    try t.expect(!sameAppId("horizon-files", "horizon-filesv2"));
    try t.expect(!sameAppId("obs", "steam"));
    // One must be a suffix, not a prefix: the launcher id is longer here.
    try t.expect(!sameAppId("steam", "steam-native"));
}

test "paths: xdg precedence" {
    const t = std.testing;
    const c = try configDir(t.allocator, "/xdg", "/home/u");
    defer t.allocator.free(c);
    try t.expectEqualStrings("/xdg/Event-Horizon", c);
    const c2 = try configDir(t.allocator, null, "/home/u");
    defer t.allocator.free(c2);
    try t.expectEqualStrings("/home/u/.config/Event-Horizon", c2);
    const sd = try settingsDir(t.allocator, "/xdg", "/home/u");
    defer t.allocator.free(sd);
    try t.expectEqualStrings("/xdg/Event-Horizon", sd);
    try t.expectEqualStrings("/tmp", runtimeDir(null));
}

test "paths: normalizeAppId lowercases and strips suffix" {
    const t = std.testing;
    const a = try normalizeAppId(t.allocator, "org.gnome.Nautilus.desktop");
    defer t.allocator.free(a);
    try t.expectEqualStrings("org.gnome.nautilus", a);

    const b = try normalizeAppId(t.allocator, "Firefox");
    defer t.allocator.free(b);
    try t.expectEqualStrings("firefox", b);

    // Exactly 8 chars never matches the suffix test.
    const c = try normalizeAppId(t.allocator, ".desktop");
    defer t.allocator.free(c);
    try t.expectEqualStrings(".desktop", c);

    const d = try normalizeAppId(t.allocator, "");
    defer t.allocator.free(d);
    try t.expectEqualStrings("unknown", d);

    const e = try normalizeAppId(t.allocator, "   ");
    defer t.allocator.free(e);
    try t.expectEqualStrings("   ", e);
}
