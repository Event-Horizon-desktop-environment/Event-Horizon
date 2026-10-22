//! Native + external template apply: bundle discovery, gated TOML merge,
//! wallpaper palette (shared seed cache), dual-mode rebuild, the render
//! loop, the external-`matugen` runner, and the file-output post-hooks,
//! including the four JSON-merge hooks (vesktop/vscode/heroic/fluxer).
//! Everything here is best-effort file surgery that never fails the caller.
//!
//! Fidelity notes:
//!   * `weakly_canonical` on bundle candidates is skipped: all candidates
//!     are probed for existence first, and raw paths address the same files.
//!   * Insertion order for hash-map iteration (replacement tables)
//!     is fixed here; TOML key order is semantically irrelevant.
//!   * Upstream keeps `_after_matugen` twins of most post-hooks; one
//!     native-flavored implementation serves both paths here. The twins
//!     differ in three places: the vesktop theme-css guard (kept), otter's
//!     skip-when-unchanged write (dropped; same bytes when nothing
//!     matched), and the horizon-files table (the 54-key native table is
//!     used; the external twin still maps only the 8 legacy chrome keys).
//!   * Bundle fragments must spell `key = 'value'` with single spaces: this
//!     parser and the C++ one both require the literal `"key = "` needle, so
//!     a `key  = ` line is dropped silently by the native render loop (that
//!     is how gtk.css/gtk-dark.css/steam.css went unrendered until the
//!     bundle was fixed to match).
//!   * The matugen CLI `-t` value comes from `schemeCliName`, an exact
//!     `normalize_matugen_scheme` port (whitespace trim, known list, and
//!     the never-matching `m3-` strip) — not the engine's
//!     `schemeVariantFromName`, which serves palette generation.

const std = @import("std");
const engine = @import("engine.zig");
const templates = @import("templates.zig");
const schema3 = @import("../config/schema3.zig");

const linux = std.os.linux;

pub const Env = struct {
    /// `$HOME` ("" when unknown; gates needing it stay off).
    home: []const u8 = "",
    /// `$XDG_CONFIG_HOME` or `$HOME/.config`.
    cfg_main: []const u8 = "",
    /// Shared state dir for the palette seed cache.
    state_dir: []const u8 = "",
};

/// Production environment from the process environment. All owned.
pub fn defaultEnv(alloc: std.mem.Allocator) !Env {
    const home = getenvAny("HOME");
    const cfg_main = if (getenvXdg()) |x|
        try alloc.dupe(u8, x)
    else if (home.len > 0)
        try std.fs.path.join(alloc, &.{ home, ".config" })
    else
        try alloc.dupe(u8, "/tmp");
    errdefer alloc.free(cfg_main);
    const state_dir = if (std.c.getenv("XDG_STATE_HOME")) |x| s: {
        const v = std.mem.span(x);
        if (v.len > 0) break :s try std.fs.path.join(alloc, &.{ v, "event-horizon" });
        break :s try alloc.dupe(u8, "/tmp/event-horizon");
    } else if (home.len > 0)
        try std.fs.path.join(alloc, &.{ home, ".local", "state", "event-horizon" })
    else
        try alloc.dupe(u8, "/tmp/event-horizon");
    errdefer alloc.free(state_dir);
    return .{
        .home = try alloc.dupe(u8, home),
        .cfg_main = cfg_main,
        .state_dir = state_dir,
    };
}

fn getenv() ?[]const u8 {
    const raw = std.c.getenv("HOME") orelse return null;
    return std.mem.span(raw);
}

fn getenvXdg() ?[]const u8 {
    const raw = std.c.getenv("XDG_CONFIG_HOME") orelse return null;
    const s = std.mem.span(raw);
    return if (s.len > 0) s else null;
}

fn getenvAny(name: [*:0]const u8) []const u8 {
    const raw = std.c.getenv(name) orelse return "";
    return std.mem.span(raw);
}

fn exeOnPath(exe: []const u8) bool {
    if (exe.len == 0) return false;
    const path_env = getenvAny("PATH");
    if (path_env.len == 0) return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    var cand: [4096]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0 or dir.len + 1 + exe.len + 1 > cand.len) continue;
        @memcpy(cand[0..dir.len], dir);
        cand[dir.len] = '/';
        @memcpy(cand[dir.len + 1 ..][0..exe.len], exe);
        cand[dir.len + 1 + exe.len] = 0;
        const z: [*:0]const u8 = @ptrCast(&cand);
        if (linux.access(z, linux.X_OK) == 0) return true;
    }
    return false;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    _ = st;
    return true;
}

fn isRegular(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

fn joinPath(alloc: std.mem.Allocator, parts: []const []const u8) ?[]u8 {
    return std.fs.path.join(alloc, parts) catch null;
}

/// `$root/matugen/configs/gtk.toml` missing/non-regular/unreadable counts as
/// current; otherwise it must contain the `[templates.ehgtk_shell_gtk4]` table.
fn gtkLayoutCurrent(alloc: std.mem.Allocator, io: std.Io, root: []const u8) bool {
    const gtk = joinPath(alloc, &.{ root, "matugen", "configs", "gtk.toml" }) orelse return true;
    defer alloc.free(gtk);
    if (!isRegular(io, gtk)) return true;
    const data = std.Io.Dir.cwd().readFileAlloc(io, gtk, alloc, .limited(1 << 20)) catch return true;
    defer alloc.free(data);
    return std.mem.indexOf(u8, data, "[templates.ehgtk_shell_gtk4]") != null;
}

fn hasBundle(alloc: std.mem.Allocator, io: std.Io, root: []const u8) bool {
    const base = joinPath(alloc, &.{ root, "matugen", "configs", "base.toml" }) orelse return false;
    defer alloc.free(base);
    return isRegular(io, base) and gtkLayoutCurrent(alloc, io, root);
}

/// `EH_MATUGEN_ROOT` → walk up from the executable (plus `share/event-horizon`
/// at each level) → `$HOME/.config/quickshell`. Each candidate needs
/// `base.toml` and a current GTK layout. (`EH_SYSTEM_MATUGEN_BUNDLE` is a
/// compile-time define upstream; honoring it as a runtime env fallback is a
/// compatible superset.)
pub fn bundleRoot(alloc: std.mem.Allocator, io: std.Io) ?[]u8 {
    const er = getenvAny("EH_MATUGEN_ROOT");
    if (er.len > 0) {
        const owned = alloc.dupe(u8, er) catch null;
        if (owned) |o| {
            if (hasBundle(alloc, io, o)) return o;
            alloc.free(o);
        }
    }
    var buf: [8192]u8 = undefined;
    const n: isize = @bitCast(linux.readlink("/proc/self/exe", &buf, buf.len - 1));
    if (n > 0) {
        var probe = std.fs.path.dirname(buf[0..@intCast(n)]) orelse "";
        var depth: usize = 0;
        while (depth < 12) : (depth += 1) {
            if (probe.len == 0) break;
            if (hasBundle(alloc, io, probe)) return alloc.dupe(u8, probe) catch null;
            const share = joinPath(alloc, &.{ probe, "share", "event-horizon" }) orelse break;
            defer alloc.free(share);
            // NOTE: `share` must outlive the check only.
            if (hasBundle(alloc, io, share)) return alloc.dupe(u8, share) catch null;
            const parent = std.fs.path.dirname(probe) orelse break;
            if (parent.len >= probe.len) break;
            probe = parent;
        }
    }
    const sys = getenvAny("EH_SYSTEM_MATUGEN_BUNDLE");
    if (sys.len > 0 and hasBundle(alloc, io, sys)) {
        return alloc.dupe(u8, sys) catch null;
    }
    const home = getenvAny("HOME");
    if (home.len == 0) return null;
    const qs = joinPath(alloc, &.{ home, ".config", "quickshell" }) orelse return null;
    defer alloc.free(qs);
    if (hasBundle(alloc, io, qs)) return alloc.dupe(u8, qs) catch null;
    return null;
}

const GateCtx = struct {
    home: []const u8,
    cfg_main: []const u8,
    io: std.Io,
};

const GatePred = *const fn (*const GateCtx) bool;

fn always(_: *const GateCtx) bool {
    return true;
}
fn exeNiri(_: *const GateCtx) bool {
    return exeOnPath("niri");
}
fn hyprSig(_: *const GateCtx) bool {
    return getenvAny("HYPRLAND_INSTANCE_SIGNATURE").len > 0;
}
fn exeMmsg(_: *const GateCtx) bool {
    return exeOnPath("mmsg");
}
fn exeQt5(_: *const GateCtx) bool {
    return exeOnPath("qt5ct");
}
fn exeQt6(_: *const GateCtx) bool {
    return exeOnPath("qt6ct");
}
fn exeKitty(_: *const GateCtx) bool {
    return exeOnPath("kitty");
}
fn exeGhostty(_: *const GateCtx) bool {
    return exeOnPath("ghostty");
}
fn exeWezterm(_: *const GateCtx) bool {
    return exeOnPath("wezterm");
}
fn exeAlacritty(_: *const GateCtx) bool {
    return exeOnPath("alacritty");
}
fn exeFoot(_: *const GateCtx) bool {
    return exeOnPath("foot");
}
fn exeBtop(_: *const GateCtx) bool {
    return exeOnPath("btop");
}
fn exeNvim(_: *const GateCtx) bool {
    return exeOnPath("nvim");
}
fn exeFirefox(_: *const GateCtx) bool {
    return exeOnPath("firefox");
}
fn exePywalfox(_: *const GateCtx) bool {
    return exeOnPath("pywalfox");
}
fn dirZen(c: *const GateCtx) bool {
    var b: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&b, "{s}/.zen", .{c.home}) catch return false;
    return pathExists(c.io, p);
}
fn vesktopFull(c: *const GateCtx) bool {
    if (!exeOnPath("vesktop")) return false;
    var b: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&b, "{s}/vesktop", .{c.cfg_main}) catch return false;
    return pathExists(c.io, p);
}
fn dirEquibop(c: *const GateCtx) bool {
    var b: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&b, "{s}/equibop", .{c.cfg_main}) catch return false;
    return pathExists(c.io, p);
}
fn dirZed(c: *const GateCtx) bool {
    var b: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&b, "{s}/zed", .{c.cfg_main}) catch return false;
    return pathExists(c.io, p);
}
fn dirSteam(c: *const GateCtx) bool {
    var b: [4096]u8 = undefined;
    const p1 = std.fmt.bufPrint(&b, "{s}/.steam", .{c.home}) catch return false;
    if (pathExists(c.io, p1)) return true;
    var b2: [4096]u8 = undefined;
    const p2 = std.fmt.bufPrint(&b2, "{s}/.local/share/Steam", .{c.home}) catch return false;
    return pathExists(c.io, p2);
}
fn exeEmacs(_: *const GateCtx) bool {
    return exeOnPath("emacs");
}
fn exeDgop(_: *const GateCtx) bool {
    return exeOnPath("dgop");
}
fn obsFull(c: *const GateCtx) bool {
    if (exeOnPath("obs") or exeOnPath("obs-studio")) return true;
    var b: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&b, "{s}/.var/app/com.obsproject.Studio/config/obs-studio", .{c.home}) catch return false;
    return pathExists(c.io, p);
}
/// Flatpak OBS keeps its theme tree inside the sandbox. When that tree is
/// present the merged config also renders `obs-flatpak.toml` (its own
/// template entry), so a sandboxed install picks the theme up alongside a
/// native one — both can exist.
fn obsFlatpakInstalled(c: *const GateCtx) bool {
    var b: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&b, "{s}/.var/app/com.obsproject.Studio", .{c.home}) catch return false;
    return pathExists(c.io, p);
}
fn heroicFull(c: *const GateCtx) bool {
    if (exeOnPath("heroic") or exeOnPath("com.heroicgameslauncher.hgl")) return true;
    var b: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&b, "{s}/heroic", .{c.cfg_main}) catch return false;
    return pathExists(c.io, p);
}
fn fluxerFull(c: *const GateCtx) bool {
    if (exeOnPath("fluxer-canary") or exeOnPath("fluxer")) return true;
    var b: [4096]u8 = undefined;
    const p1 = std.fmt.bufPrint(&b, "{s}/fluxercanary", .{c.cfg_main}) catch return false;
    if (pathExists(c.io, p1)) return true;
    var b2: [4096]u8 = undefined;
    const p2 = std.fmt.bufPrint(&b2, "{s}/fluxer", .{c.cfg_main}) catch return false;
    return pathExists(c.io, p2);
}
fn owlerFull(c: *const GateCtx) bool {
    if (exeOnPath("owler")) return true;
    var b: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&b, "{s}/owler", .{c.cfg_main}) catch return false;
    return pathExists(c.io, p);
}
fn dirEh(c: *const GateCtx) bool {
    var b: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&b, "{s}/event-horizon", .{c.cfg_main}) catch return false;
    return pathExists(c.io, p);
}
fn dirHcal(c: *const GateCtx) bool {
    var b: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&b, "{s}/horizon-calendar", .{c.cfg_main}) catch return false;
    return pathExists(c.io, p);
}
fn vscodeOk(c: *const GateCtx) bool {
    if (exeOnPath("code") or exeOnPath("codium") or exeOnPath("cursor")) return true;
    const dirs = [_][]const u8{ "Code", "Cursor", "VSCodium", "Code - OSS", "Code - Insiders" };
    for (dirs) |d| {
        var b: [4096]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "{s}/{s}", .{ c.cfg_main, d }) catch continue;
        if (pathExists(c.io, p)) return true;
    }
    return false;
}

const Gate = struct {
    flag: bool,
    file: []const u8,
    pred: GatePred,
};

/// The kitty-theme gate file is the *only* difference between the native
/// table (`kitty.toml`) and the external-matugen one (`kitty-theme.toml`);
/// everything else is identical.
fn gateTableWith(t: *const schema3.MatugenToggles, kitty_theme_file: []const u8) [37]Gate {
    return .{
        .{ .flag = t.niri, .file = "niri.toml", .pred = exeNiri },
        .{ .flag = t.hyprland, .file = "hyprland.toml", .pred = hyprSig },
        .{ .flag = t.mango, .file = "mangowc.toml", .pred = exeMmsg },
        .{ .flag = t.gtk_shell_css, .file = "gtk.toml", .pred = always },
        .{ .flag = t.gtk_event_colors_light, .file = "gtk3-light.toml", .pred = always },
        .{ .flag = t.gtk_event_colors_dark, .file = "gtk3-dark.toml", .pred = always },
        .{ .flag = t.kcolorscheme, .file = "kcolorscheme.toml", .pred = always },
        .{ .flag = t.qt5ct, .file = "qt5ct.toml", .pred = exeQt5 },
        .{ .flag = t.qt6ct, .file = "qt6ct.toml", .pred = exeQt6 },
        .{ .flag = t.kitty_theme, .file = kitty_theme_file, .pred = exeKitty },
        .{ .flag = t.kitty_tabs, .file = "kitty-tabs.toml", .pred = exeKitty },
        .{ .flag = t.ghostty, .file = "ghostty.toml", .pred = exeGhostty },
        .{ .flag = t.wezterm, .file = "wezterm.toml", .pred = exeWezterm },
        .{ .flag = t.alacritty, .file = "alacritty.toml", .pred = exeAlacritty },
        .{ .flag = t.foot, .file = "foot.toml", .pred = exeFoot },
        .{ .flag = t.otter_term, .file = "otter-term.toml", .pred = always },
        .{ .flag = t.btop, .file = "btop.toml", .pred = exeBtop },
        .{ .flag = t.neovim, .file = "neovim.toml", .pred = exeNvim },
        .{ .flag = t.vscode_material, .file = "vscode-material.toml", .pred = vscodeOk },
        .{ .flag = t.vscode_color_themes, .file = "vscode-color-themes.toml", .pred = vscodeOk },
        .{ .flag = t.firefox, .file = "firefox.toml", .pred = exeFirefox },
        .{ .flag = t.pywalfox, .file = "pywalfox.toml", .pred = exePywalfox },
        .{ .flag = t.zenbrowser, .file = "zenbrowser.toml", .pred = dirZen },
        .{ .flag = t.vesktop, .file = "vesktop.toml", .pred = vesktopFull },
        .{ .flag = t.equibop, .file = "equibop.toml", .pred = dirEquibop },
        .{ .flag = t.zed, .file = "zed.toml", .pred = dirZed },
        .{ .flag = t.steam, .file = "steam.toml", .pred = dirSteam },
        .{ .flag = t.emacs, .file = "emacs.toml", .pred = exeEmacs },
        .{ .flag = t.dgop, .file = "dgop.toml", .pred = exeDgop },
        .{ .flag = t.ptyxis, .file = "ptyxis.toml", .pred = always },
        .{ .flag = t.obs, .file = "obs.toml", .pred = obsFull },
        .{ .flag = t.heroic, .file = "heroic.toml", .pred = heroicFull },
        .{ .flag = t.fluxer, .file = "fluxer.toml", .pred = fluxerFull },
        .{ .flag = t.owler, .file = "owler.toml", .pred = owlerFull },
        .{ .flag = t.horizon_files, .file = "horizon-files.toml", .pred = dirEh },
        .{ .flag = t.horizon_photo, .file = "horizon-photo.toml", .pred = dirEh },
        .{ .flag = t.horizon_calendar, .file = "horizon-calendar.toml", .pred = dirHcal },
    };
}

/// Native gate table: kitty's theme lives in `kitty.toml`.
fn gateTable(t: *const schema3.MatugenToggles) [37]Gate {
    return gateTableWith(t, "kitty.toml");
}

/// External-matugen gate table: kitty's theme lives in `kitty-theme.toml`.
fn gateTableExternal(t: *const schema3.MatugenToggles) [37]Gate {
    return gateTableWith(t, "kitty-theme.toml");
}

fn appendFile(alloc: std.mem.Allocator, io: std.Io, out: *std.ArrayList(u8), path: []const u8) bool {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 << 20)) catch return false;
    defer alloc.free(data);
    out.appendSlice(alloc, data) catch return false;
    out.append(alloc, '\n') catch return false;
    return true;
}

fn replaceAll(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    if (from.len == 0) return;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, buf.items, pos, from)) |at| {
        try buf.replaceRange(alloc, at, from.len, to);
        pos = at + to.len;
    }
}

/// Literal path rewrites on the merged TOML, in order (including
/// consolidating the legacy quickshell template tree onto the bundle tree).
fn fixPaths(
    alloc: std.mem.Allocator,
    body: *std.ArrayList(u8),
    root: []const u8,
    cfg_main: []const u8,
    home: []const u8,
    vscode_ud: []const u8,
    vscode_ext_eh: []const u8,
    bundle_tpl: []const u8,
) !void {
    try replaceAll(body, alloc, "SHELL_DIR", root);
    try replaceAll(body, alloc, "CONFIG_DIR", cfg_main);
    try replaceAll(body, alloc, "VSCODE_USER_DIR", vscode_ud);
    try replaceAll(body, alloc, "VSCODE_EXT_EH_THEMES_DIR", vscode_ext_eh);
    try replaceAll(body, alloc, "HOME_DIR", home);
    var tmp: [4096]u8 = undefined;
    const cache_dir = try std.fmt.bufPrint(&tmp, "{s}/.cache", .{home});
    try replaceAll(body, alloc, "CACHE_DIR", cache_dir);
    const data_dir = try std.fmt.bufPrint(&tmp, "{s}/.local/share", .{home});
    try replaceAll(body, alloc, "DATA_DIR", data_dir);
    const emacs_dir = try std.fmt.bufPrint(&tmp, "{s}/.emacs.d", .{home});
    try replaceAll(body, alloc, "EMACS_DIR", emacs_dir);
    try replaceAll(body, alloc, "input_path = '~/", try std.fmt.bufPrint(&tmp, "input_path = '{s}/", .{home}));
    // NOTE: the pattern is "input_path = '~\\./" — a literal backslash
    // before the dot (port exactly; see the m3- precedent).
    try replaceAll(body, alloc, "input_path = '~\\./", try std.fmt.bufPrint(&tmp, "input_path = '{s}/.", .{home}));
    try replaceAll(body, alloc, "input_path = './matugen/templates/", try std.fmt.bufPrint(&tmp, "input_path = '{s}/", .{bundle_tpl}));
    var tmp_b: [4096]u8 = undefined;
    const qs_from = try std.fmt.bufPrint(&tmp, "input_path = '{s}/.config/quickshell/matugen/templates/", .{home});
    const qs_to = try std.fmt.bufPrint(&tmp_b, "input_path = '{s}/", .{bundle_tpl});
    try replaceAll(body, alloc, qs_from, qs_to);
    try replaceAll(body, alloc, "output_path = '~/", try std.fmt.bufPrint(&tmp, "output_path = '{s}/", .{home}));
    // Same literal-backslash quirk as the input_path rule above.
    try replaceAll(body, alloc, "output_path = '~\\./", try std.fmt.bufPrint(&tmp, "output_path = '{s}/.", .{home}));
}

pub const video_exts = [_][]const u8{ ".mp4", ".webm", ".mkv", ".mov", ".avi" };

fn hasVideoExt(path: []const u8) bool {
    for (video_exts) |ext| {
        if (path.len >= ext.len and std.ascii.eqlIgnoreCase(path[path.len - ext.len ..], ext)) return true;
    }
    return false;
}

fn videoFramePng(alloc: std.mem.Allocator) ?[]u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |x| {
        const v = std.mem.span(x);
        if (v.len > 0) return std.fs.path.join(alloc, &.{ v, "event-horizon", "video-frame.png" }) catch null;
    }
    if (std.c.getenv("HOME")) |h| {
        const v = std.mem.span(h);
        if (v.len > 0) return std.fs.path.join(alloc, &.{ v, ".local", "state", "event-horizon", "video-frame.png" }) catch null;
    }
    return std.fs.path.join(alloc, &.{"/tmp/event-horizon/video-frame.png"}) catch null;
}

/// Empty stays empty; videos resolve to the cached frame when present;
/// existing paths keep their (lexical) spelling — no `realpath` exists in
/// this toolchain, and identity only affects cache keys, never colors.
pub fn normalizeWallpaperPath(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (path.len == 0) return alloc.dupe(u8, "");
    if (hasVideoExt(path)) {
        if (videoFramePng(alloc)) |frame| {
            defer alloc.free(frame);
            if (pathExists(io, frame)) return alloc.dupe(u8, frame);
        }
    }
    return alloc.dupe(u8, path);
}

pub fn vscodeUserDir(alloc: std.mem.Allocator, io: std.Io, cfg_main: []const u8) ![]u8 {
    const dirs = [_][]const u8{ "Cursor", "Code", "VSCodium", "Code - OSS", "Code - Insiders" };
    // exe+dir pairs first.
    if (exeOnPath("cursor")) {
        if (joinPath(alloc, &.{ cfg_main, "Cursor" })) |d| {
            defer alloc.free(d);
            if (pathExists(io, d)) return joinPath(alloc, &.{ cfg_main, "Cursor", "User" }) orelse error.OutOfMemory;
        }
    }
    if (exeOnPath("code")) {
        if (joinPath(alloc, &.{ cfg_main, "Code" })) |d| {
            defer alloc.free(d);
            if (pathExists(io, d)) return joinPath(alloc, &.{ cfg_main, "Code", "User" }) orelse error.OutOfMemory;
        }
    }
    if (exeOnPath("codium")) {
        if (joinPath(alloc, &.{ cfg_main, "VSCodium" })) |d| {
            defer alloc.free(d);
            if (pathExists(io, d)) return joinPath(alloc, &.{ cfg_main, "VSCodium", "User" }) orelse error.OutOfMemory;
        }
    }
    for (dirs) |d| {
        const c = joinPath(alloc, &.{ cfg_main, d }) orelse continue;
        defer alloc.free(c);
        if (pathExists(io, c)) return joinPath(alloc, &.{ cfg_main, d, "User" }) orelse error.OutOfMemory;
    }
    if (exeOnPath("cursor")) return joinPath(alloc, &.{ cfg_main, "Cursor", "User" }) orelse error.OutOfMemory;
    if (exeOnPath("code")) return joinPath(alloc, &.{ cfg_main, "Code", "User" }) orelse error.OutOfMemory;
    if (exeOnPath("codium")) return joinPath(alloc, &.{ cfg_main, "VSCodium", "User" }) orelse error.OutOfMemory;
    return joinPath(alloc, &.{ cfg_main, "Code", "User" }) orelse error.OutOfMemory;
}

pub fn vscodeMarketplaceDir(alloc: std.mem.Allocator, home: []const u8, user_dir: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, user_dir, "/Cursor/") != null)
        return joinPath(alloc, &.{ home, ".cursor", "extensions" }) orelse error.OutOfMemory;
    if (std.mem.indexOf(u8, user_dir, "/VSCodium/") != null)
        return joinPath(alloc, &.{ home, ".vscode-oss", "extensions" }) orelse error.OutOfMemory;
    if (std.mem.indexOf(u8, user_dir, "/Code - Insiders/") != null)
        return joinPath(alloc, &.{ home, ".vscode-insiders", "extensions" }) orelse error.OutOfMemory;
    if (std.mem.indexOf(u8, user_dir, "/Code - OSS/") != null)
        return joinPath(alloc, &.{ home, ".vscode-oss", "extensions" }) orelse error.OutOfMemory;
    return joinPath(alloc, &.{ home, ".vscode", "extensions" }) orelse error.OutOfMemory;
}

pub const Applier = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    seed_cache: engine.SeedCache,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, cache_dir: []const u8) Applier {
        return .{ .alloc = alloc, .io = io, .seed_cache = engine.SeedCache.init(alloc, cache_dir) };
    }

    pub fn deinit(self: *Applier) void {
        self.seed_cache.deinit();
    }

    pub const Inputs = struct {
        wallpaper_image: []const u8,
        scheme: []const u8,
        mode: []const u8,
        horizon_native: bool,
        horizon_ok: bool,
        /// External-matugen gate: `matugenThemingEnabled && matugenPaletteOk`.
        /// Only `applyExternal` reads these; the native path is independent.
        matugen_theming: bool = false,
        matugen_palette_ok: bool = false,
        toggles: *const schema3.MatugenToggles,
        env: Env,
    };

    /// Full native pass. Best-effort: returns rendered template count.
    pub fn apply(self: *Applier, in: Inputs) usize {
        if (!in.horizon_native or !in.horizon_ok) return 0;
        const root = bundleRoot(self.alloc, self.io) orelse return 0;
        defer self.alloc.free(root);
        if (in.env.home.len == 0) return 0;

        const vscode_ud = vscodeUserDir(self.alloc, self.io, in.env.cfg_main) catch return 0;
        defer self.alloc.free(vscode_ud);
        const marketplace = vscodeMarketplaceDir(self.alloc, in.env.home, vscode_ud) catch return 0;
        defer self.alloc.free(marketplace);
        const vscode_ext_eh = joinPath(self.alloc, &.{ marketplace, "eh-matugen-themes" }) orelse return 0;
        defer self.alloc.free(vscode_ext_eh);

        const ctx = GateCtx{ .home = in.env.home, .cfg_main = in.env.cfg_main, .io = self.io };
        const want_vscode = (in.toggles.vscode_material or in.toggles.vscode_color_themes) and vscodeOk(&ctx);
        if (want_vscode) {
            self.ensureVscodeEhThemeExtension(root, vscode_ext_eh);
            std.Io.Dir.cwd().createDirPath(self.io, vscode_ud) catch {};
        }

        var merged = std.ArrayList(u8).empty;
        defer merged.deinit(self.alloc);
        const cfgd = joinPath(self.alloc, &.{ root, "matugen", "configs" }) orelse return 0;
        defer self.alloc.free(cfgd);
        if (in.toggles.run_bundled_toml) {
            const base = joinPath(self.alloc, &.{ cfgd, "base.toml" }) orelse return 0;
            defer self.alloc.free(base);
            if (!appendFile(self.alloc, self.io, &merged, base)) return 0;
        } else {
            merged.appendSlice(self.alloc, "[config]\n\n[templates]\n\n") catch return 0;
        }
        for (gateTable(in.toggles)) |gate| {
            if (!gate.flag or !gate.pred(&ctx)) continue;
            const fp = joinPath(self.alloc, &.{ cfgd, gate.file }) orelse continue;
            defer self.alloc.free(fp);
            _ = appendFile(self.alloc, self.io, &merged, fp);
        }
        if (in.toggles.obs and obsFlatpakInstalled(&ctx)) {
            if (joinPath(self.alloc, &.{ cfgd, "obs-flatpak.toml" })) |fp| {
                defer self.alloc.free(fp);
                _ = appendFile(self.alloc, self.io, &merged, fp);
            }
        }

        const bundle_tpl = joinPath(self.alloc, &.{ root, "matugen", "templates" }) orelse return 0;
        defer self.alloc.free(bundle_tpl);
        fixPaths(self.alloc, &merged, root, in.env.cfg_main, in.env.home, vscode_ud, vscode_ext_eh, bundle_tpl) catch return 0;

        const wp = normalizeWallpaperPath(self.alloc, self.io, in.wallpaper_image) catch return 0;
        defer self.alloc.free(wp);
        if (wp.len == 0 or !pathExists(self.io, wp)) return 0;

        // NOTE: refresh.zig is intentionally not imported here; the two
        // normalization helpers it owns are five lines each and the direction
        // (apply -> refresh) would tangle the layering. Palettes take the
        // engine's variant; the matugen CLI value comes from the local
        // `schemeCliName`, an exact `normalize_matugen_scheme` port.

        const variant = engine.schemeVariantFromName(in.scheme);
        const is_dark = modeIsDark(in.mode);
        const palette = engine.generatePaletteFromImageCached(
            &self.seed_cache,
            self.alloc,
            self.io,
            wp,
            variant,
            is_dark,
            0.0,
            128,
        ) catch return 0;
        if (!palette.ok) return 0;

        var entries = templates.parseTemplateEntries(self.alloc, merged.items) catch return 0;
        defer {
            for (entries.items) |*e| e.deinit(self.alloc);
            entries.deinit(self.alloc);
        }

        // Dual-mode templates (Ptyxis, Zed, Firefox, Vesktop) carry explicit
        // .light./.dark. placeholders; build the opposite palette too, but only
        // when some merged template needs it (shared seed via the cache).
        const roles = palette.roles;
        const base16 = templates.generateBase16(roles, is_dark);
        var roles_other = roles;
        var base16_other = base16;
        {
            const probe: []const u8 = if (is_dark) ".light." else ".dark.";
            if (std.mem.indexOf(u8, merged.items, probe) != null) {
                const other = engine.generatePaletteFromImageCached(
                    &self.seed_cache,
                    self.alloc,
                    self.io,
                    wp,
                    variant,
                    !is_dark,
                    0.0,
                    128,
                ) catch engine.PaletteResult{};
                if (other.ok) {
                    roles_other = other.roles;
                    base16_other = templates.generateBase16(other.roles, !is_dark);
                }
            }
        }
        const roles_dark: *const [47]u32 = if (is_dark) &roles else &roles_other;
        const roles_light: *const [47]u32 = if (is_dark) &roles_other else &roles;
        const base16_dark: *const [16]u32 = if (is_dark) &base16 else &base16_other;
        const base16_light: *const [16]u32 = if (is_dark) &base16_other else &base16;

        var processed: usize = 0;
        for (entries.items) |entry| {
            if (entry.input_path.len == 0 or entry.output_path.len == 0) continue;
            if (!isRegular(self.io, entry.input_path)) continue;
            const content = std.Io.Dir.cwd().readFileAlloc(
                self.io,
                entry.input_path,
                self.alloc,
                .limited(4 << 20),
            ) catch continue;
            defer self.alloc.free(content);
            const rendered = templates.processTemplate(
                self.alloc,
                content,
                roles_dark,
                base16_dark,
                roles_light,
                base16_light,
                palette.source_color_argb,
                is_dark,
            ) catch continue;
            defer self.alloc.free(rendered);
            if (std.fs.path.dirname(entry.output_path)) |dirp| {
                std.Io.Dir.cwd().createDirPath(self.io, dirp) catch continue;
            }
            std.Io.Dir.cwd().writeFile(self.io, .{
                .sub_path = entry.output_path,
                .data = rendered,
            }) catch continue;
            processed += 1;
        }

        self.runPostHooks(in.toggles, in.env.home, in.env.cfg_main, want_vscode, vscode_ud, vscode_ext_eh, is_dark);
        return processed;
    }

        /// Shared post-matugen dispatch: the Ptyxis legacy-palette migration
        /// plus every gated sync/merge hook. Used by both the native render
        /// pass (`apply`) and the external-`matugen` runner (`applyExternal`),
        /// whose `_after_matugen` siblings duplicate
        /// these methods. `is_dark` drives the VS Code light/dark theme name.
        fn runPostHooks(
            self: *Applier,
            toggles: *const schema3.MatugenToggles,
            home: []const u8,
            cfg_main: []const u8,
            want_vscode: bool,
            vscode_ud: []const u8,
            vscode_ext_eh: []const u8,
            is_dark: bool,
        ) void {
            // Migrate legacy Ptyxis palette name: Event-Horizon.palette is the
            // canonical wallpaper-driven output; drop the old eh-ptyxis.palette.
            if (toggles.ptyxis and home.len > 0) {
                var b1: [4096]u8 = undefined;
                if (std.fmt.bufPrint(&b1, "{s}/.local/share/org.gnome.Ptyxis/palettes", .{home})) |pal_dir| {
                    var b2: [4300]u8 = undefined;
                    var b3: [4300]u8 = undefined;
                    if (std.fmt.bufPrint(&b2, "{s}/eh-ptyxis.palette", .{pal_dir})) |legacy| {
                        if (std.fmt.bufPrint(&b3, "{s}/Event-Horizon.palette", .{pal_dir})) |canonical| {
                            if (isRegular(self.io, canonical) and isRegular(self.io, legacy)) {
                                std.Io.Dir.cwd().deleteFile(self.io, legacy) catch {};
                            }
                        } else |_| {}
                    } else |_| {}
                } else |_| {}
            }

            // Post-hooks: best-effort file surgery.
            if (toggles.otter_term) self.syncOtterTerm(cfg_main);
            if (toggles.horizon_files) self.syncHorizonFiles(cfg_main);
            if (toggles.horizon_photo) self.syncHorizonPhoto(cfg_main, home);
            if (toggles.horizon_calendar) self.syncHorizonCalendar(cfg_main);
            if (toggles.btop and exeOnPath("btop")) self.syncBtop(cfg_main);
            if (toggles.vesktop) {
                var b: [4096]u8 = undefined;
                if (std.fmt.bufPrint(&b, "{s}/vesktop", .{cfg_main})) |vd| {
                    if (pathExists(self.io, vd)) {
                        self.mergeVesktopVencordSettings(vd);
                        var b2: [4200]u8 = undefined;
                        if (std.fmt.bufPrint(&b2, "{s}/themes/midnight.theme.css", .{vd})) |css| {
                            bumpMtimeNow(self.io, css);
                        } else |_| {}
                    }
                } else |_| {}
            }
            if (want_vscode) {
                var mj: [4300]u8 = undefined;
                if (std.fmt.bufPrint(&mj, "{s}/material-code-colors.matugen.json", .{vscode_ud})) |material_json| {
                    self.mergeVscodeUserSettings(
                        vscode_ud,
                        material_json,
                        toggles.vscode_material,
                        toggles.vscode_color_themes,
                        !is_dark,
                    );
                } else |_| {}
                touchVscodeThemeExtensionOutputs(self.io, vscode_ext_eh);
                var b: [4300]u8 = undefined;
                if (std.fmt.bufPrint(&b, "{s}/settings.json", .{vscode_ud})) |sp| {
                    bumpMtimeNow(self.io, sp);
                } else |_| {}
            }
            if (toggles.heroic) {
                var b: [4096]u8 = undefined;
                if (std.fmt.bufPrint(&b, "{s}/heroic/themes/event-horizon.css", .{cfg_main})) |hp| {
                    if (pathExists(self.io, hp)) {
                        var b2: [4100]u8 = undefined;
                        if (std.fmt.bufPrint(&b2, "{s}/heroic", .{cfg_main})) |hd| {
                            self.mergeHeroicPrefs(hd);
                        } else |_| {}
                    }
                } else |_| {}
            }
            if (toggles.alacritty) {
                var b: [4096]u8 = undefined;
                if (std.fmt.bufPrint(&b, "{s}/alacritty/event-theme.toml", .{cfg_main})) |et| {
                    if (pathExists(self.io, et)) self.syncAlacritty(cfg_main);
                } else |_| {}
            }
            if (toggles.fluxer) {
                var b: [4096]u8 = undefined;
                if (std.fmt.bufPrint(&b, "{s}/fluxer/themes/event-horizon.css", .{cfg_main})) |fp| {
                    if (pathExists(self.io, fp)) self.mergeFluxerPrefs(cfg_main, home);
                } else |_| {}
            }
        }

        /// External-`matugen` pass: gated TOML merge (kitty uses
        /// `kitty-theme.toml`) → fixPaths → legacy-template sanitization →
        /// mkstemp config → spawn `matugen image` → cleanup → post-hooks.
        /// Best-effort; returns whether matugen exited 0.
        pub fn applyExternal(self: *Applier, in: Inputs) bool {
            if (!in.matugen_theming or !in.matugen_palette_ok) return false;
            const root = bundleRoot(self.alloc, self.io) orelse return false;
            defer self.alloc.free(root);
            if (!exeOnPath("matugen")) return false;
            if (in.env.home.len == 0) return false;

            const wp = normalizeWallpaperPath(self.alloc, self.io, in.wallpaper_image) catch return false;
            defer self.alloc.free(wp);
            if (wp.len == 0 or !pathExists(self.io, wp)) return false;

            const vscode_ud = vscodeUserDir(self.alloc, self.io, in.env.cfg_main) catch return false;
            defer self.alloc.free(vscode_ud);
            const marketplace = vscodeMarketplaceDir(self.alloc, in.env.home, vscode_ud) catch return false;
            defer self.alloc.free(marketplace);
            const vscode_ext_eh = joinPath(self.alloc, &.{ marketplace, "eh-matugen-themes" }) orelse return false;
            defer self.alloc.free(vscode_ext_eh);

            const ctx = GateCtx{ .home = in.env.home, .cfg_main = in.env.cfg_main, .io = self.io };
            const want_vscode = (in.toggles.vscode_material or in.toggles.vscode_color_themes) and vscodeOk(&ctx);

            const cfgd = joinPath(self.alloc, &.{ root, "matugen", "configs" }) orelse return false;
            defer self.alloc.free(cfgd);
            var merged = std.ArrayList(u8).empty;
            defer merged.deinit(self.alloc);
            if (in.toggles.run_bundled_toml) {
                const base = joinPath(self.alloc, &.{ cfgd, "base.toml" }) orelse return false;
                defer self.alloc.free(base);
                if (!appendFile(self.alloc, self.io, &merged, base)) return false;
            } else {
                merged.appendSlice(self.alloc, "[config]\n\n[templates]\n\n") catch return false;
            }
            for (gateTableExternal(in.toggles)) |gate| {
                if (!gate.flag or !gate.pred(&ctx)) continue;
                const fp = joinPath(self.alloc, &.{ cfgd, gate.file }) orelse continue;
                defer self.alloc.free(fp);
                _ = appendFile(self.alloc, self.io, &merged, fp);
            }
            if (in.toggles.obs and obsFlatpakInstalled(&ctx)) {
                if (joinPath(self.alloc, &.{ cfgd, "obs-flatpak.toml" })) |fp| {
                    defer self.alloc.free(fp);
                    _ = appendFile(self.alloc, self.io, &merged, fp);
                }
            }

            if (want_vscode) {
                self.ensureVscodeEhThemeExtension(root, vscode_ext_eh);
                std.Io.Dir.cwd().createDirPath(self.io, vscode_ud) catch {};
            }

            const bundle_tpl = joinPath(self.alloc, &.{ root, "matugen", "templates" }) orelse return false;
            defer self.alloc.free(bundle_tpl);
            fixPaths(self.alloc, &merged, root, in.env.cfg_main, in.env.home, vscode_ud, vscode_ext_eh, bundle_tpl) catch return false;

            // Legacy `event16` placeholders: sanitize a temp copy of the
            // template tree and repoint the merged config at it.
            var san_dir: ?[]u8 = null;
            defer if (san_dir) |d| {
                std.Io.Dir.cwd().deleteTree(self.io, d) catch {};
                self.alloc.free(d);
            };
            if (templateTreeHasLegacyEvent16(self.alloc, self.io, bundle_tpl)) {
                const d = mkdtempPath(self.alloc, "/tmp/eh-mtpl-XXXXXX") orelse return false;
                if (!copyTemplatesSanitized(self.alloc, self.io, bundle_tpl, d)) return false;
                san_dir = d;
                replaceAll(&merged, self.alloc, bundle_tpl, d) catch return false;
            }

            const tmp = mkstempPath(self.alloc, "/tmp/eh-matugen-tpl-XXXXXX") orelse return false;
            defer self.alloc.free(tmp.path);
            {
                const data = merged.items;
                var p: usize = 0;
                while (p < data.len) {
                    const nw = linux.write(tmp.fd, data.ptr + p, data.len - p);
                    if (linux.errno(nw) != .SUCCESS or nw == 0) {
                        _ = linux.close(tmp.fd);
                        std.Io.Dir.cwd().deleteFile(self.io, tmp.path) catch {};
                        return false;
                    }
                    p += @intCast(nw);
                }
                _ = linux.close(tmp.fd);
            }

            const scheme = schemeCliName(in.scheme);
            const m_arg: []const u8 = if (modeIsDark(in.mode)) "dark" else "light";
            const ok = runMatugenImage(self.io, root, tmp.path, wp, m_arg, scheme);
            std.Io.Dir.cwd().deleteFile(self.io, tmp.path) catch {};
            if (ok) {
                self.runPostHooks(in.toggles, in.env.home, in.env.cfg_main, want_vscode, vscode_ud, vscode_ext_eh, modeIsDark(in.mode));
            }
            return ok;
        }

        // ------------------------------------------------------- post-hooks ---

        /// `sync_btop`: force the eh-matugen color theme and signal btop.
        fn syncBtop(self: *Applier, cfg_main: []const u8) void {
            const alloc = self.alloc;
            var b1: [4096]u8 = undefined;
            const conf = std.fmt.bufPrint(&b1, "{s}/btop/btop.conf", .{cfg_main}) catch return;
            if (std.fs.path.dirname(conf)) |d| {
                std.Io.Dir.cwd().createDirPath(self.io, d) catch {};
            }
            var lines = readFileLines(alloc, self.io, conf) catch return;
            defer freeLines(alloc, &lines);
            const theme_line = "color_theme = \"eh-matugen\"";
            const replaced = replaceFirstPrefixed(alloc, &lines, "color_theme", theme_line) catch false;
            if (!replaced) {
                const nw = alloc.dupe(u8, theme_line) catch return;
                lines.append(alloc, nw) catch {
                    alloc.free(nw);
                    return;
                };
            }
            const data = joinLines(alloc, &lines) catch return;
            defer alloc.free(data);
            writeAll(self.io, conf, data);
            const res = std.process.run(alloc, self.io, .{
                .argv = &.{ "pkill", "-SIGUSR2", "-x", "btop" },
            }) catch return;
            defer alloc.free(res.stdout);
            defer alloc.free(res.stderr);
        }

        /// `sync_otter_term`: port colors_* from the matugen conf into
        /// otter-term.conf, preserving each line's existing alpha suffix
        /// (colors_background always gets "BF").
        fn syncOtterTerm(self: *Applier, cfg_main: []const u8) void {
            const alloc = self.alloc;
            var b1: [4096]u8 = undefined;
            const matugen_file = std.fmt.bufPrint(&b1, "{s}/otter-shell/otter-term-matugen.conf", .{cfg_main}) catch return;
            if (!isRegular(self.io, matugen_file)) return;
            const mdata = std.Io.Dir.cwd().readFileAlloc(self.io, matugen_file, alloc, .limited(1 << 20)) catch return;
            defer alloc.free(mdata);
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(alloc);
            var hexes: std.ArrayList([]const u8) = .empty;
            defer hexes.deinit(alloc);
            {
                var it = std.mem.splitScalar(u8, mdata, '\n');
                while (it.next()) |raw| {
                    var ln = raw;
                    if (ln.len > 0 and ln[ln.len - 1] == '\r') ln = ln[0 .. ln.len - 1];
                    const eq = std.mem.indexOfScalar(u8, ln, '=') orelse continue;
                    if (eq == 0) continue;
                    const key = trimTrail(ln[0..eq]);
                    if (key.len < 7 or !std.mem.startsWith(u8, key, "colors_")) continue;
                    const val = trimLead(ln[eq + 1 ..]);
                    if (val.len >= 8 and val[0] == '"' and val[1] == '#') {
                        if (std.mem.indexOfScalarPos(u8, val, 2, '"')) |end| {
                            keys.append(alloc, key) catch return;
                            hexes.append(alloc, val[2..end]) catch return;
                        }
                    }
                }
            }
            if (keys.items.len == 0) return;
            var b2: [4096]u8 = undefined;
            const conf_path = std.fmt.bufPrint(&b2, "{s}/otter-shell/otter-term.conf", .{cfg_main}) catch return;
            if (!isRegular(self.io, conf_path)) return;
            var lines = readFileLines(alloc, self.io, conf_path) catch return;
            defer freeLines(alloc, &lines);
            for (lines.items) |*lp| {
                const eq = std.mem.indexOfScalar(u8, lp.*, '=') orelse continue;
                if (eq == 0) continue;
                const key = trimTrail(lp.*[0..eq]);
                if (key.len < 7 or !std.mem.startsWith(u8, key, "colors_")) continue;
                for (keys.items, hexes.items) |k, hx| {
                    if (!std.mem.eql(u8, key, k)) continue;
                    var existing_alpha: []const u8 = "";
                    if (std.mem.eql(u8, key, "colors_background")) {
                        existing_alpha = "BF";
                    } else {
                        const oval = trimLead(lp.*[eq + 1 ..]);
                        if (oval.len >= 11 and oval[0] == '"' and oval[1] == '#' and oval[10] == '"') {
                            existing_alpha = oval[8..10];
                        }
                    }
                    const nw = std.fmt.allocPrint(alloc, "{s} = \"#{s}{s}\"", .{ key, hx, existing_alpha }) catch return;
                    alloc.free(lp.*);
                    lp.* = nw;
                    break;
                }
            }
            const data = joinLines(alloc, &lines) catch return;
            defer alloc.free(data);
            writeAll(self.io, conf_path, data);
        }

        /// `sync_horizon_files`: float RGB into state-settings.toml
        /// [appearance]. Misplaced occurrences (outside [appearance] when the
        /// header exists) are dropped; missing keys are inserted right after
        /// the header, never at EOF. Rewrites only when bytes differ.
        fn syncHorizonFiles(self: *Applier, cfg_main: []const u8) void {
            const alloc = self.alloc;
            var b1: [4096]u8 = undefined;
            const eh = std.fmt.bufPrint(&b1, "{s}/event-horizon", .{cfg_main}) catch return;
            var b2: [4300]u8 = undefined;
            const matugen_file = std.fmt.bufPrint(&b2, "{s}/horizon-files-matugen.conf", .{eh}) catch return;
            if (!isRegular(self.io, matugen_file)) return;
            const mdata = std.Io.Dir.cwd().readFileAlloc(self.io, matugen_file, alloc, .limited(1 << 20)) catch return;
            defer alloc.free(mdata);
            var hex_map = parseHexConf(alloc, mdata) catch return;
            defer hexMapDeinit(alloc, &hex_map);
            if (hex_map.count() == 0) return;

            const nrep = files_map.len * 3;
            // `fmtFloat6` answers with a slice into the buffer it was handed,
            // so the buffers live here and `reps` carries those slices: the
            // length rides along with the bytes. Storing the buffer itself
            // would throw it away, and `{s}` on a `[32]u8` prints the whole
            // array — the ~24 undefined bytes after every float, which in the
            // shipped build are 0xaa and leave state-settings.toml invalid
            // UTF-8/TOML.
            var rbufs: [nrep][32]u8 = undefined;
            var reps: [nrep]?[]const u8 = .{null} ** nrep;
            for (files_map, 0..) |m, i| {
                const hex = hex_map.get(m.hex_key) orelse continue;
                var rgb: [3]f64 = undefined;
                if (!hexToRgbF64(hex, &rgb)) continue;
                const chans = [_][]const u8{ m.r, m.g, m.b };
                for (chans, 0..) |_, c| {
                    reps[i * 3 + c] = fmtFloat6(&rbufs[i * 3 + c], rgb[c]);
                }
            }
            var any_rep = false;
            for (reps) |r| {
                if (r != null) {
                    any_rep = true;
                    break;
                }
            }
            if (!any_rep) return;

            var b3: [4300]u8 = undefined;
            const settings_path = std.fmt.bufPrint(&b3, "{s}/state-settings.toml", .{eh}) catch return;
            var settings = readFileLines(alloc, self.io, settings_path) catch return;
            defer freeLines(alloc, &settings);

            var has_header = false;
            for (settings.items) |l| {
                if (std.mem.eql(u8, l, "[appearance]")) {
                    has_header = true;
                    break;
                }
            }

            var out: std.ArrayList([]u8) = .empty;
            defer freeLines(alloc, &out);
            var pending: std.ArrayList(usize) = .empty;
            defer pending.deinit(alloc);
            for (0..nrep) |i| {
                if (reps[i] != null) pending.append(alloc, i) catch {};
            }

            var inside = false;
            var header_emitted = false;
            for (settings.items) |line| {
                if (line.len > 0 and line[0] == '[') {
                    if (inside) flushPending(alloc, &out, &reps, &pending);
                    inside = std.mem.eql(u8, line, "[appearance]");
                    if (inside) header_emitted = true;
                    out.append(alloc, alloc.dupe(u8, line) catch return) catch return;
                    continue;
                }
                const eq = std.mem.indexOfScalar(u8, line, '=');
                if (eq == null or eq.? == 0) {
                    out.append(alloc, alloc.dupe(u8, line) catch return) catch return;
                    continue;
                }
                const key = trimTrail(line[0 .. eq.?]);
                const mi = hfRepIndex(key);
                if (mi == null) {
                    out.append(alloc, alloc.dupe(u8, line) catch return) catch return;
                    continue;
                }
                if (inside or !has_header) {
                    // A role with no hex in this pass has a null slot; nothing
                    // is found in `replacements` and the stored
                    // line alone, so unwrap nothing here.
                    if (reps[mi.?]) |rep| {
                        const nl = std.fmt.allocPrint(alloc, "{s} = {s}", .{ key, rep }) catch return;
                        out.append(alloc, nl) catch {
                            alloc.free(nl);
                            return;
                        };
                    } else {
                        out.append(alloc, alloc.dupe(u8, line) catch return) catch return;
                    }
                }
                for (pending.items, 0..) |pi, idx| {
                    if (pi == mi.?) {
                        _ = pending.orderedRemove(idx);
                        break;
                    }
                }
            }
            if (!header_emitted) {
                out.append(alloc, alloc.dupe(u8, "[appearance]") catch return) catch return;
            }
            if (pending.items.len > 0) flushPending(alloc, &out, &reps, &pending);

            for (out.items) |*lp| {
                if (std.mem.indexOf(u8, lp.*, "matugenPaletteOk") != null) {
                    const nw = alloc.dupe(u8, "matugenPaletteOk = true") catch return;
                    alloc.free(lp.*);
                    lp.* = nw;
                    break;
                }
            }

            const body = joinLines(alloc, &out) catch return;
            defer alloc.free(body);
            writeAllIfChanged(alloc, self.io, settings_path, body);
        }

        /// `sync_horizon_photo`: float RGB to Horizon Photo's runtime file.
        fn syncHorizonPhoto(self: *Applier, cfg_main: []const u8, home: []const u8) void {
            const alloc = self.alloc;
            if (home.len == 0) return;
            var b1: [4096]u8 = undefined;
            const matugen_file = std.fmt.bufPrint(&b1, "{s}/event-horizon/horizon-photo-matugen.conf", .{cfg_main}) catch return;
            if (!isRegular(self.io, matugen_file)) return;
            const mdata = std.Io.Dir.cwd().readFileAlloc(self.io, matugen_file, alloc, .limited(1 << 20)) catch return;
            defer alloc.free(mdata);
            var hex_map = parseHexConf(alloc, mdata) catch return;
            defer hexMapDeinit(alloc, &hex_map);
            if (hex_map.count() == 0) return;

            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(alloc);
            body.appendSlice(alloc, "# Auto-generated by Event Horizon color engine\n" ++
                "# Wallpaper-derived M3 theme colors (float RGB 0.0-1.0)\n\n") catch return;
            for (photo_map) |m| {
                const hex = hex_map.get(m.hex_key) orelse continue;
                var rgb: [3]f64 = undefined;
                if (!hexToRgbF64(hex, &rgb)) continue;
                const chans = [_][]const u8{ m.r, m.g, m.b };
                for (chans, 0..) |k, c| {
                    var fb: [32]u8 = undefined;
                    const s6 = fmtFloat6(&fb, rgb[c]);
                    var lb: [128]u8 = undefined;
                    const line = std.fmt.bufPrint(&lb, "{s} = {s}\n", .{ k, s6 }) catch break;
                    body.appendSlice(alloc, line) catch break;
                }
                body.append(alloc, '\n') catch break;
            }
            var b2: [4096]u8 = undefined;
            const color_path = std.fmt.bufPrint(&b2, "{s}/.local/state/event-horizon/Horizon-photo/theme-colors.toml", .{home}) catch return;
            writeAll(self.io, color_path, body.items);
        }

        /// `sync_horizon_calendar`: write theme.toml under the section matching
        /// the configured matugen_mode; skip when unchanged.
        fn syncHorizonCalendar(self: *Applier, cfg_main: []const u8) void {
            const alloc = self.alloc;
            var b1: [4096]u8 = undefined;
            const matugen_file = std.fmt.bufPrint(&b1, "{s}/event-horizon/horizon-calendar-matugen.conf", .{cfg_main}) catch return;
            if (!isRegular(self.io, matugen_file)) return;
            const mdata = std.Io.Dir.cwd().readFileAlloc(self.io, matugen_file, alloc, .limited(1 << 20)) catch return;
            defer alloc.free(mdata);
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(alloc);
            var vals: std.ArrayList([]const u8) = .empty;
            defer vals.deinit(alloc);
            {
                var it = std.mem.splitScalar(u8, mdata, '\n');
                while (it.next()) |raw| {
                    var ln = raw;
                    if (ln.len > 0 and ln[ln.len - 1] == '\r') ln = ln[0 .. ln.len - 1];
                    const eq = std.mem.indexOfScalar(u8, ln, '=') orelse continue;
                    if (eq == 0) continue;
                    const key = trimTrail(ln[0..eq]);
                    if (key.len == 0 or key[0] == '#') continue;
                    var val = trimLead(ln[eq + 1 ..]);
                    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') val = val[1 .. val.len - 1];
                    if (val.len == 0) continue;
                    keys.append(alloc, key) catch return;
                    vals.append(alloc, val) catch return;
                }
            }
            if (keys.items.len == 0) return;

            var section: []const u8 = "dark";
            var b3: [4300]u8 = undefined;
            const sp = std.fmt.bufPrint(&b3, "{s}/event-horizon/state-settings.toml", .{cfg_main}) catch return;
            if (isRegular(self.io, sp)) {
                var slines = readFileLines(alloc, self.io, sp) catch return;
                defer freeLines(alloc, &slines);
                var in_ap = false;
                for (slines.items) |ln| {
                    const t = trimLead(ln);
                    if (t.len == 0) continue;
                    if (t[0] == '[') {
                        in_ap = std.mem.startsWith(u8, t, "[appearance]");
                        continue;
                    }
                    if (!in_ap) continue;
                    const eq = std.mem.indexOfScalar(u8, ln, '=') orelse continue;
                    if (eq == 0) continue;
                    if (!std.mem.eql(u8, trimTrail(ln[0..eq]), "matugen_mode")) continue;
                    var mode = trimLead(ln[eq + 1 ..]);
                    if (mode.len >= 2 and mode[0] == '"' and mode[mode.len - 1] == '"') mode = mode[1 .. mode.len - 1];
                    section = if (std.mem.eql(u8, mode, "light")) "light" else "dark";
                    break;
                }
            }

            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(alloc);
            body.appendSlice(alloc, "# Horizon Calendar theme\n" ++
                "# Auto-generated by Event Horizon from the wallpaper palette;\n" ++
                "# manual edits are overwritten on the next palette pass.\n\n[") catch return;
            body.appendSlice(alloc, section) catch return;
            body.appendSlice(alloc, "]\n") catch return;
            for (keys.items, vals.items) |k, v| {
                var lb: [512]u8 = undefined;
                const line = std.fmt.bufPrint(&lb, "{s} = \"{s}\"\n", .{ k, v }) catch continue;
                body.appendSlice(alloc, line) catch break;
            }
            var b4: [4300]u8 = undefined;
            const theme_path = std.fmt.bufPrint(&b4, "{s}/horizon-calendar/theme.toml", .{cfg_main}) catch return;
            writeAllIfChanged(alloc, self.io, theme_path, body.items);
        }

        /// `sync_alacritty`: ensure alacritty.toml imports event-theme.toml
        /// under [general] (existing inline or multi-line arrays are extended).
        fn syncAlacritty(self: *Applier, cfg_main: []const u8) void {
            const alloc = self.alloc;
            var b1: [4096]u8 = undefined;
            const conf = std.fmt.bufPrint(&b1, "{s}/alacritty/alacritty.toml", .{cfg_main}) catch return;
            const existed = isRegular(self.io, conf);
            var lines = readFileLines(alloc, self.io, conf) catch return;
            defer freeLines(alloc, &lines);
            if (existed) {
                for (lines.items) |ln| {
                    if (std.mem.indexOf(u8, ln, "event-theme.toml") != null) return;
                }
            }
            var patched = false;
            var hdr: ?usize = null;
            for (lines.items, 0..) |ln, i| {
                if (std.mem.eql(u8, trimTrail(ln), "[general]")) {
                    hdr = i;
                    break;
                }
            }
            if (hdr) |h| {
                const hline = lines.items[h];
                const indent = hline[0 .. hline.len - trimLead(hline).len];
                var block_end = lines.items.len;
                for (lines.items[h + 1 ..], h + 1 ..) |ln, i| {
                    if (std.mem.startsWith(u8, trimLead(ln), "[")) {
                        block_end = i;
                        break;
                    }
                }
                var found_import = false;
                var i = h + 1;
                while (i < block_end) : (i += 1) {
                    const raw = lines.items[i];
                    const tt = trimLead(raw);
                    if (!std.mem.startsWith(u8, tt, "import")) continue;
                    if (tt.len <= 7 or (tt[6] != '=' and tt[6] != ' ')) continue;
                    found_import = true;
                    const lb = std.mem.indexOfScalar(u8, raw, '[') orelse break;
                    const te = trimTrail(tt);
                    if (te.len > 0 and te[te.len - 1] == ']') {
                        const last = std.mem.lastIndexOfScalar(u8, raw, ']') orelse break;
                        const inner = trimTrail(trimLead(raw[lb + 1 .. last]));
                        if (inner.len == 0) {
                            const lead = raw[0 .. raw.len - tt.len];
                            const nw = std.fmt.allocPrint(alloc, "{s}import = [\"event-theme.toml\"]", .{lead}) catch return;
                            alloc.free(lines.items[i]);
                            lines.items[i] = nw;
                        } else {
                            const nw = std.fmt.allocPrint(alloc, "{s}, \"event-theme.toml\"{s}", .{ raw[0..last], raw[last..] }) catch return;
                            alloc.free(lines.items[i]);
                            lines.items[i] = nw;
                        }
                        patched = true;
                    } else if (std.mem.lastIndexOfScalar(u8, raw, ']') == null) {
                        var j = i + 1;
                        while (j < block_end) : (j += 1) {
                            const ct = lines.items[j];
                            const ctt = trimLead(ct);
                            if (ctt.len > 0 and ctt[0] == ']') {
                                const cl = ct.len - ctt.len;
                                const elem_indent: []const u8 = if (cl > 0) ct[0..cl] else "  ";
                                const nw = std.fmt.allocPrint(alloc, "{s}\"event-theme.toml\",", .{elem_indent}) catch return;
                                lines.insert(alloc, j, nw) catch {
                                    alloc.free(nw);
                                    return;
                                };
                                patched = true;
                                break;
                            }
                        }
                    }
                    break;
                }
                if (!found_import) {
                    const nw = std.fmt.allocPrint(alloc, "{s}import = [\"event-theme.toml\"]", .{indent}) catch return;
                    lines.insert(alloc, h + 1, nw) catch {
                        alloc.free(nw);
                        return;
                    };
                    patched = true;
                }
            } else {
                if (lines.items.len > 0 and lines.items[lines.items.len - 1].len > 0) {
                    const blank = alloc.dupe(u8, "") catch return;
                    lines.append(alloc, blank) catch {
                        alloc.free(blank);
                        return;
                    };
                }
                const h1 = alloc.dupe(u8, "[general]") catch return;
                lines.append(alloc, h1) catch {
                    alloc.free(h1);
                    return;
                };
                const h2 = alloc.dupe(u8, "import = [\"event-theme.toml\"]") catch return;
                lines.append(alloc, h2) catch {
                    alloc.free(h2);
                    return;
                };
                patched = true;
            }
            if (!patched) return;
            const data = joinLines(alloc, &lines) catch return;
            defer alloc.free(data);
            writeAll(self.io, conf, data);
        }

        // ------------------------------------------------------ json merges ---

        /// `ensure_vscode_eh_theme_extension`: seed the extension manifest so
        /// the template outputs land inside a VS Code-recognised extension.
        fn ensureVscodeEhThemeExtension(self: *Applier, root: []const u8, ext_dir: []const u8) void {
            std.Io.Dir.cwd().createDirPath(self.io, ext_dir) catch {};
            const src = joinPath(self.alloc, &.{ root, "matugen", "vscode-eh-themes", "package.json" }) orelse return;
            defer self.alloc.free(src);
            if (!isRegular(self.io, src)) return;
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, src, self.alloc, .limited(1 << 20)) catch return;
            defer self.alloc.free(data);
            var b: [4300]u8 = undefined;
            const dst = std.fmt.bufPrint(&b, "{s}/package.json", .{ext_dir}) catch return;
            writeAll(self.io, dst, data);
        }

        /// `merge_vesktop_vencord_settings`: make Vencord enable our theme.
        fn mergeVesktopVencordSettings(self: *Applier, vesktop_data_dir: []const u8) void {
            const alloc = self.alloc;
            var arena_state: std.heap.ArenaAllocator = .init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var b1: [4096]u8 = undefined;
            const theme_css = std.fmt.bufPrint(&b1, "{s}/themes/midnight.theme.css", .{vesktop_data_dir}) catch return;
            if (!isRegular(self.io, theme_css)) return;

            var b2: [4300]u8 = undefined;
            const settings_path = std.fmt.bufPrint(&b2, "{s}/settings/settings.json", .{vesktop_data_dir}) catch return;
            var root = loadJsonObject(arena, self.io, settings_path);
            // Indexing a non-object root is undefined; these
            // files are always objects, so bail out instead of guessing.
            if (root != .object) return;

            const gop = root.object.getOrPut(arena, "enabledThemes") catch return;
            if (!gop.found_existing or gop.value_ptr.* != .array) {
                gop.value_ptr.* = .{ .array = .init(arena) };
            }
            var found = false;
            for (gop.value_ptr.*.array.items) |x| {
                if (x == .string and std.mem.eql(u8, x.string, "midnight.theme.css")) {
                    found = true;
                    break;
                }
            }
            if (!found) gop.value_ptr.*.array.append(.{ .string = "midnight.theme.css" }) catch return;

            var b3: [4400]u8 = undefined;
            if (std.fmt.bufPrint(&b3, "{s}/settings", .{vesktop_data_dir})) |sd| {
                std.Io.Dir.cwd().createDirPath(self.io, sd) catch {};
            } else |_| {}
            writeJsonObject(arena, self.io, settings_path, root);
        }

        /// `merge_heroic_prefs`: select our store theme and point Heroic's
        /// custom-themes directory at ours.
        ///
        /// Heroic stores a custom-theme selection as the CSS file name
        /// (`event-horizon.css`), not the body class it derives from it:
        /// `getThemeCSS` joins the stored value onto `customThemesPath`.
        /// Writing the bare `event-horizon` makes that lookup miss, so the
        /// stylesheet is empty and Heroic boots with its default light
        /// palette. Keep the `.css` suffix.
        fn mergeHeroicPrefs(self: *Applier, heroic_dir: []const u8) void {
            const alloc = self.alloc;
            var arena_state: std.heap.ArenaAllocator = .init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const theme_value = "event-horizon.css";

            var b1: [4096]u8 = undefined;
            const store_path = std.fmt.bufPrint(&b1, "{s}/store/config.json", .{heroic_dir}) catch return;
            if (isRegular(self.io, store_path)) {
                var root = loadJsonObject(arena, self.io, store_path);
                if (root == .object) {
                    const need = blk: {
                        const v = root.object.get("theme") orelse break :blk true;
                        break :blk !(v == .string and std.mem.eql(u8, v.string, theme_value));
                    };
                    if (need) {
                        root.object.put(arena, "theme", .{ .string = theme_value }) catch return;
                        writeJsonObject(arena, self.io, store_path, root);
                    }
                }
            }

            var b2: [4300]u8 = undefined;
            const cfg_path = std.fmt.bufPrint(&b2, "{s}/config.json", .{heroic_dir}) catch return;
            if (isRegular(self.io, cfg_path)) {
                var root = loadJsonObject(arena, self.io, cfg_path);
                if (root == .object) {
                    if (root.object.getPtr("defaultSettings")) |ds| {
                        if (ds.* == .object) {
                            const gop = ds.object.getOrPut(arena, "customThemesPath") catch return;
                            const bad = !gop.found_existing or gop.value_ptr.* != .string or
                                gop.value_ptr.*.string.len == 0;
                            if (bad) {
                                const p = std.fmt.allocPrint(arena, "{s}/themes", .{heroic_dir}) catch return;
                                gop.value_ptr.* = .{ .string = p };
                                writeJsonObject(arena, self.io, cfg_path, root);
                            }
                        }
                    }
                }
            }
        }

        /// `merge_fluxer_prefs`: seed both Fluxer flavours with the master
        /// theme and allowlist it in their settings.
        fn mergeFluxerPrefs(self: *Applier, cfg_main: []const u8, home: []const u8) void {
            const alloc = self.alloc;
            var b1: [4096]u8 = undefined;
            const master = std.fmt.bufPrint(&b1, "{s}/fluxer/themes/event-horizon.css", .{cfg_main}) catch return;
            if (!isRegular(self.io, master)) return;
            const want = std.Io.Dir.cwd().readFileAlloc(self.io, master, alloc, .limited(4 << 20)) catch return;
            defer alloc.free(want);
            if (want.len == 0) return;

            const names = [_][]const u8{ "fluxercanary", "fluxer" };
            for (names) |name| {
                var b2: [4096]u8 = undefined;
                const user_dir = std.fmt.bufPrint(&b2, "{s}/.config/{s}", .{ home, name }) catch continue;
                if (!isDirectory(self.io, user_dir)) continue;
                var b3: [4300]u8 = undefined;
                const theme_dir = std.fmt.bufPrint(&b3, "{s}/themes", .{user_dir}) catch continue;
                std.Io.Dir.cwd().createDirPath(self.io, theme_dir) catch continue;
                var b4: [4400]u8 = undefined;
                const theme_path = std.fmt.bufPrint(&b4, "{s}/event-horizon.css", .{theme_dir}) catch continue;

                if (!fileEquals(self.alloc, self.io, theme_path, want)) {
                    writeAll(self.io, theme_path, want);
                }

                var arena_state: std.heap.ArenaAllocator = .init(alloc);
                defer arena_state.deinit();
                const arena = arena_state.allocator();

                var b5: [4400]u8 = undefined;
                const settings_path = std.fmt.bufPrint(&b5, "{s}/settings.json", .{user_dir}) catch continue;
                var root = loadJsonObject(arena, self.io, settings_path);
                if (root != .object) root = .{ .object = .{} };

                var present = false;
                if (root.object.get("theme_allowed_local_files")) |arr| {
                    if (arr == .array) {
                        for (arr.array.items) |sv| {
                            if (sv == .string and std.mem.eql(u8, sv.string, theme_path)) {
                                present = true;
                                break;
                            }
                        }
                    }
                }
                if (!present) {
                    const gop = root.object.getOrPut(arena, "theme_allowed_local_files") catch continue;
                    if (!gop.found_existing or gop.value_ptr.* != .array) {
                        gop.value_ptr.* = .{ .array = .init(arena) };
                    }
                    const entry = arena.dupe(u8, theme_path) catch continue;
                    gop.value_ptr.*.array.append(.{ .string = entry }) catch continue;
                    writeJsonObject(arena, self.io, settings_path, root);
                }
            }
        }

        /// `merge_vscode_user_settings`: fold the material palette into the
        /// user settings and pin the workbench colour theme.
        fn mergeVscodeUserSettings(
            self: *Applier,
            user_dir: []const u8,
            material_json: []const u8,
            merge_material: bool,
            set_workbench_theme: bool,
            mode_light: bool,
        ) void {
            const alloc = self.alloc;
            var arena_state: std.heap.ArenaAllocator = .init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var b1: [4300]u8 = undefined;
            const settings_path = std.fmt.bufPrint(&b1, "{s}/settings.json", .{user_dir}) catch return;
            var root = loadJsonObject(arena, self.io, settings_path);
            if (root != .object) return;

            if (merge_material and isRegular(self.io, material_json)) {
                // The material file parses *outside* the inner try: a
                // malformed palette aborts the whole merge without writing.
                const raw = std.Io.Dir.cwd().readFileAlloc(self.io, material_json, arena, .limited(4 << 20)) catch return;
                const stripped = stripJsonComments(arena, raw) catch return;
                const mat = std.json.parseFromSliceLeaky(std.json.Value, arena, stripped, .{}) catch return;
                if (mat == .object) {
                    if (mat.object.get("material-code.colors")) |mc| {
                        if (mc == .object) root.object.put(arena, "material-code.colors", mc) catch return;
                    }
                }
            }
            if (set_workbench_theme) {
                const tname: []const u8 = if (mode_light) "Event Horizon Light" else "Event Horizon Dark";
                root.object.put(arena, "workbench.colorTheme", .{ .string = tname }) catch return;
            }
            std.Io.Dir.cwd().createDirPath(self.io, user_dir) catch {};
            writeJsonObject(arena, self.io, settings_path, root);
        }
    };

const HfMapping = struct { hex_key: []const u8, r: []const u8, g: []const u8, b: []const u8 };

/// Legacy chrome keys first (older horizon-files builds), then the full M3
/// role set in m3::ColorRole order (outline has no duplicate row).
const files_map = [_]HfMapping{
    .{ .hex_key = "dock_fill", .r = "matugenDockFillR", .g = "matugenDockFillG", .b = "matugenDockFillB" },
    .{ .hex_key = "panel_fill", .r = "matugenPanelFillR", .g = "matugenPanelFillG", .b = "matugenPanelFillB" },
    .{ .hex_key = "drawer_dim", .r = "matugenDrawerDimR", .g = "matugenDrawerDimG", .b = "matugenDrawerDimB" },
    .{ .hex_key = "outline", .r = "matugenOutlineR", .g = "matugenOutlineG", .b = "matugenOutlineB" },
    .{ .hex_key = "accent", .r = "matugenAccentR", .g = "matugenAccentG", .b = "matugenAccentB" },
    .{ .hex_key = "text", .r = "matugenTextR", .g = "matugenTextG", .b = "matugenTextB" },
    .{ .hex_key = "notif_critical_bg", .r = "matugenNotifCriticalBgR", .g = "matugenNotifCriticalBgG", .b = "matugenNotifCriticalBgB" },
    .{ .hex_key = "notif_critical_outline", .r = "matugenNotifCriticalOutlineR", .g = "matugenNotifCriticalOutlineG", .b = "matugenNotifCriticalOutlineB" },
    .{ .hex_key = "primary", .r = "matugenPrimaryR", .g = "matugenPrimaryG", .b = "matugenPrimaryB" },
    .{ .hex_key = "on_primary", .r = "matugenOnPrimaryR", .g = "matugenOnPrimaryG", .b = "matugenOnPrimaryB" },
    .{ .hex_key = "primary_container", .r = "matugenPrimaryContainerR", .g = "matugenPrimaryContainerG", .b = "matugenPrimaryContainerB" },
    .{ .hex_key = "on_primary_container", .r = "matugenOnPrimaryContainerR", .g = "matugenOnPrimaryContainerG", .b = "matugenOnPrimaryContainerB" },
    .{ .hex_key = "secondary", .r = "matugenSecondaryR", .g = "matugenSecondaryG", .b = "matugenSecondaryB" },
    .{ .hex_key = "on_secondary", .r = "matugenOnSecondaryR", .g = "matugenOnSecondaryG", .b = "matugenOnSecondaryB" },
    .{ .hex_key = "secondary_container", .r = "matugenSecondaryContainerR", .g = "matugenSecondaryContainerG", .b = "matugenSecondaryContainerB" },
    .{ .hex_key = "on_secondary_container", .r = "matugenOnSecondaryContainerR", .g = "matugenOnSecondaryContainerG", .b = "matugenOnSecondaryContainerB" },
    .{ .hex_key = "tertiary", .r = "matugenTertiaryR", .g = "matugenTertiaryG", .b = "matugenTertiaryB" },
    .{ .hex_key = "on_tertiary", .r = "matugenOnTertiaryR", .g = "matugenOnTertiaryG", .b = "matugenOnTertiaryB" },
    .{ .hex_key = "tertiary_container", .r = "matugenTertiaryContainerR", .g = "matugenTertiaryContainerG", .b = "matugenTertiaryContainerB" },
    .{ .hex_key = "on_tertiary_container", .r = "matugenOnTertiaryContainerR", .g = "matugenOnTertiaryContainerG", .b = "matugenOnTertiaryContainerB" },
    .{ .hex_key = "error", .r = "matugenErrorR", .g = "matugenErrorG", .b = "matugenErrorB" },
    .{ .hex_key = "on_error", .r = "matugenOnErrorR", .g = "matugenOnErrorG", .b = "matugenOnErrorB" },
    .{ .hex_key = "error_container", .r = "matugenErrorContainerR", .g = "matugenErrorContainerG", .b = "matugenErrorContainerB" },
    .{ .hex_key = "on_error_container", .r = "matugenOnErrorContainerR", .g = "matugenOnErrorContainerG", .b = "matugenOnErrorContainerB" },
    .{ .hex_key = "surface", .r = "matugenSurfaceR", .g = "matugenSurfaceG", .b = "matugenSurfaceB" },
    .{ .hex_key = "on_surface", .r = "matugenOnSurfaceR", .g = "matugenOnSurfaceG", .b = "matugenOnSurfaceB" },
    .{ .hex_key = "surface_variant", .r = "matugenSurfaceVariantR", .g = "matugenSurfaceVariantG", .b = "matugenSurfaceVariantB" },
    .{ .hex_key = "on_surface_variant", .r = "matugenOnSurfaceVariantR", .g = "matugenOnSurfaceVariantG", .b = "matugenOnSurfaceVariantB" },
    .{ .hex_key = "surface_dim", .r = "matugenSurfaceDimR", .g = "matugenSurfaceDimG", .b = "matugenSurfaceDimB" },
    .{ .hex_key = "surface_bright", .r = "matugenSurfaceBrightR", .g = "matugenSurfaceBrightG", .b = "matugenSurfaceBrightB" },
    .{ .hex_key = "surface_container_lowest", .r = "matugenSurfaceContainerLowestR", .g = "matugenSurfaceContainerLowestG", .b = "matugenSurfaceContainerLowestB" },
    .{ .hex_key = "surface_container_low", .r = "matugenSurfaceContainerLowR", .g = "matugenSurfaceContainerLowG", .b = "matugenSurfaceContainerLowB" },
    .{ .hex_key = "surface_container", .r = "matugenSurfaceContainerR", .g = "matugenSurfaceContainerG", .b = "matugenSurfaceContainerB" },
    .{ .hex_key = "surface_container_high", .r = "matugenSurfaceContainerHighR", .g = "matugenSurfaceContainerHighG", .b = "matugenSurfaceContainerHighB" },
    .{ .hex_key = "surface_container_highest", .r = "matugenSurfaceContainerHighestR", .g = "matugenSurfaceContainerHighestG", .b = "matugenSurfaceContainerHighestB" },
    .{ .hex_key = "inverse_surface", .r = "matugenInverseSurfaceR", .g = "matugenInverseSurfaceG", .b = "matugenInverseSurfaceB" },
    .{ .hex_key = "inverse_on_surface", .r = "matugenInverseOnSurfaceR", .g = "matugenInverseOnSurfaceG", .b = "matugenInverseOnSurfaceB" },
    .{ .hex_key = "inverse_primary", .r = "matugenInversePrimaryR", .g = "matugenInversePrimaryG", .b = "matugenInversePrimaryB" },
    .{ .hex_key = "outline_variant", .r = "matugenOutlineVariantR", .g = "matugenOutlineVariantG", .b = "matugenOutlineVariantB" },
    .{ .hex_key = "shadow", .r = "matugenShadowR", .g = "matugenShadowG", .b = "matugenShadowB" },
    .{ .hex_key = "scrim", .r = "matugenScrimR", .g = "matugenScrimG", .b = "matugenScrimB" },
    .{ .hex_key = "surface_tint", .r = "matugenSurfaceTintR", .g = "matugenSurfaceTintG", .b = "matugenSurfaceTintB" },
    .{ .hex_key = "primary_fixed", .r = "matugenPrimaryFixedR", .g = "matugenPrimaryFixedG", .b = "matugenPrimaryFixedB" },
    .{ .hex_key = "primary_fixed_dim", .r = "matugenPrimaryFixedDimR", .g = "matugenPrimaryFixedDimG", .b = "matugenPrimaryFixedDimB" },
    .{ .hex_key = "on_primary_fixed", .r = "matugenOnPrimaryFixedR", .g = "matugenOnPrimaryFixedG", .b = "matugenOnPrimaryFixedB" },
    .{ .hex_key = "on_primary_fixed_variant", .r = "matugenOnPrimaryFixedVariantR", .g = "matugenOnPrimaryFixedVariantG", .b = "matugenOnPrimaryFixedVariantB" },
    .{ .hex_key = "secondary_fixed", .r = "matugenSecondaryFixedR", .g = "matugenSecondaryFixedG", .b = "matugenSecondaryFixedB" },
    .{ .hex_key = "secondary_fixed_dim", .r = "matugenSecondaryFixedDimR", .g = "matugenSecondaryFixedDimG", .b = "matugenSecondaryFixedDimB" },
    .{ .hex_key = "on_secondary_fixed", .r = "matugenOnSecondaryFixedR", .g = "matugenOnSecondaryFixedG", .b = "matugenOnSecondaryFixedB" },
    .{ .hex_key = "on_secondary_fixed_variant", .r = "matugenOnSecondaryFixedVariantR", .g = "matugenOnSecondaryFixedVariantG", .b = "matugenOnSecondaryFixedVariantB" },
    .{ .hex_key = "tertiary_fixed", .r = "matugenTertiaryFixedR", .g = "matugenTertiaryFixedG", .b = "matugenTertiaryFixedB" },
    .{ .hex_key = "tertiary_fixed_dim", .r = "matugenTertiaryFixedDimR", .g = "matugenTertiaryFixedDimG", .b = "matugenTertiaryFixedDimB" },
    .{ .hex_key = "on_tertiary_fixed", .r = "matugenOnTertiaryFixedR", .g = "matugenOnTertiaryFixedG", .b = "matugenOnTertiaryFixedB" },
    .{ .hex_key = "on_tertiary_fixed_variant", .r = "matugenOnTertiaryFixedVariantR", .g = "matugenOnTertiaryFixedVariantG", .b = "matugenOnTertiaryFixedVariantB" },
};

const photo_map = [_]HfMapping{
    .{ .hex_key = "surface", .r = "surface_r", .g = "surface_g", .b = "surface_b" },
    .{ .hex_key = "surface_container", .r = "surface_container_r", .g = "surface_container_g", .b = "surface_container_b" },
    .{ .hex_key = "surface_container_high", .r = "surface_container_high_r", .g = "surface_container_high_g", .b = "surface_container_high_b" },
    .{ .hex_key = "on_surface", .r = "on_surface_r", .g = "on_surface_g", .b = "on_surface_b" },
    .{ .hex_key = "on_surface_variant", .r = "on_surface_variant_r", .g = "on_surface_variant_g", .b = "on_surface_variant_b" },
    .{ .hex_key = "primary", .r = "primary_r", .g = "primary_g", .b = "primary_b" },
    .{ .hex_key = "primary_container", .r = "primary_container_r", .g = "primary_container_g", .b = "primary_container_b" },
    .{ .hex_key = "on_primary_container", .r = "on_primary_container_r", .g = "on_primary_container_g", .b = "on_primary_container_b" },
    .{ .hex_key = "outline", .r = "outline_r", .g = "outline_g", .b = "outline_b" },
    .{ .hex_key = "outline_variant", .r = "outline_variant_r", .g = "outline_variant_g", .b = "outline_variant_b" },
    .{ .hex_key = "tonal_container", .r = "tonal_container_r", .g = "tonal_container_g", .b = "tonal_container_b" },
};

fn hfKey(i: usize) []const u8 {
    const m = files_map[i / 3];
    return switch (i % 3) {
        0 => m.r,
        1 => m.g,
        else => m.b,
    };
}

fn hfRepIndex(key: []const u8) ?usize {
    for (0..files_map.len * 3) |i| {
        if (std.mem.eql(u8, hfKey(i), key)) return i;
    }
    return null;
}

fn flushPending(
    alloc: std.mem.Allocator,
    out: *std.ArrayList([]u8),
    reps: *const [files_map.len * 3]?[]const u8,
    pending: *std.ArrayList(usize),
) void {
    for (pending.items) |i| {
        const line = std.fmt.allocPrint(alloc, "{s} = {s}", .{ hfKey(i), reps[i].? }) catch continue;
        out.append(alloc, line) catch {
            alloc.free(line);
        };
    }
    pending.clearRetainingCapacity();
}

/// Whole file as owned lines, `\r` stripped, trailing newline not producing a
/// final empty line. Missing file → empty list.
fn readFileLines(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeLines(alloc, &out);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 << 20)) catch return out;
    defer alloc.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        var ln = raw;
        if (ln.len > 0 and ln[ln.len - 1] == '\r') ln = ln[0 .. ln.len - 1];
        try out.append(alloc, try alloc.dupe(u8, ln));
    }
    // splitScalar yields a trailing "" for data ending in '\n'; getline does not.
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0 and
        data.len > 0 and data[data.len - 1] == '\n')
    {
        const last = out.items[out.items.len - 1];
        alloc.free(last);
        out.items.len -= 1;
    }
    return out;
}

fn freeLines(alloc: std.mem.Allocator, lines: *std.ArrayList([]u8)) void {
    for (lines.items) |l| alloc.free(l);
    lines.deinit(alloc);
}

/// Lines joined with '\n' after each.
fn joinLines(alloc: std.mem.Allocator, lines: *const std.ArrayList([]u8)) ![]u8 {
    var total: usize = 0;
    for (lines.items) |l| total += l.len + 1;
    const out = try alloc.alloc(u8, total);
    var i: usize = 0;
    for (lines.items) |l| {
        @memcpy(out[i .. i + l.len], l);
        i += l.len;
        out[i] = '\n';
        i += 1;
    }
    return out;
}

fn trimLead(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
}

fn trimTrail(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0 and (s[e - 1] == ' ' or s[e - 1] == '\t')) e -= 1;
    return s[0..e];
}

fn writeAll(io: std.Io, path: []const u8, data: []const u8) void {
    if (std.fs.path.dirname(path)) |d| {
        std.Io.Dir.cwd().createDirPath(io, d) catch return;
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch {};
}

/// Rewrite the file only when bytes differ (config dir is inotify-watched;
/// identical rewrites loop reloads forever).
fn writeAllIfChanged(alloc: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) void {
    if (std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 << 20))) |cur| {
        defer alloc.free(cur);
        if (std.mem.eql(u8, cur, data)) return;
    } else |_| {}
    writeAll(io, path, data);
}

/// `color_theme` etc: first line whose leading-trimmed form starts with the key.
fn replaceFirstPrefixed(
    alloc: std.mem.Allocator,
    lines: *std.ArrayList([]u8),
    prefix: []const u8,
    replacement: []const u8,
) !bool {
    for (lines.items) |*ln| {
        if (std.mem.startsWith(u8, trimLead(ln.*), prefix)) {
            const nw = try alloc.dupe(u8, replacement);
            alloc.free(ln.*);
            ln.* = nw;
            return true;
        }
    }
    return false;
}

/// `key = "#RRGGBB"` conf parse: strips quotes, drops empty values.
fn parseHexConf(alloc: std.mem.Allocator, data: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .{};
    errdefer {
        var it = map.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        map.deinit(alloc);
    }
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        var ln = raw;
        if (ln.len > 0 and ln[ln.len - 1] == '\r') ln = ln[0 .. ln.len - 1];
        const eq = std.mem.indexOfScalar(u8, ln, '=') orelse continue;
        if (eq == 0) continue;
        const key = trimTrail(ln[0..eq]);
        var val = trimLead(ln[eq + 1 ..]);
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') val = val[1 .. val.len - 1];
        if (key.len == 0 or val.len == 0) continue;
        const k = try alloc.dupe(u8, key);
        errdefer alloc.free(k);
        const v = try alloc.dupe(u8, val);
        try map.put(alloc, k, v);
    }
    return map;
}

fn hexMapDeinit(alloc: std.mem.Allocator, map: *std.StringHashMapUnmanaged([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |e| {
        alloc.free(e.key_ptr.*);
        alloc.free(e.value_ptr.*);
    }
    map.deinit(alloc);
}

fn hexToRgbF64(hex: []const u8, out: *[3]f64) bool {
    var h = hex;
    if (h.len > 0 and h[0] == '#') h = h[1..];
    if (h.len != 6) return false;
    const v = std.fmt.parseInt(u32, h, 16) catch return false;
    out.* = .{
        @as(f64, @floatFromInt((v >> 16) & 0xFF)) / 255.0,
        @as(f64, @floatFromInt((v >> 8) & 0xFF)) / 255.0,
        @as(f64, @floatFromInt(v & 0xFF)) / 255.0,
    };
    return true;
}

/// C `snprintf("%.6f")`.
fn fmtFloat6(buf: *[32]u8, v: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.6}", .{v}) catch "";
}

/// `normalize_matugen_mode` subset used for is_dark: only "light" is light.
fn modeIsDark(raw: []const u8) bool {
    var buf: [32]u8 = undefined;
    const len = @min(raw.len, buf.len);
    for (raw[0..len], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    var s: []const u8 = buf[0..len];
    while (s.len > 0 and std.ascii.isWhitespace(s[0])) s = s[1..];
    while (s.len > 0 and std.ascii.isWhitespace(s[s.len - 1])) s = s[0 .. s.len - 1];
    return !std.mem.eql(u8, s, "light");
}

/// `normalize_matugen_scheme` for the external matugen `-t` argument. Not
/// the engine's `schemeVariantFromName`: upstream trims whitespace, keeps
/// an already-known `scheme-*` string, and its `m3-` strip never matches
/// (four chars compared against a three-char literal), so `m3-*` falls
/// through to the Content default. Mirrors `refresh.normalizeScheme` (the
/// same port, quirks included) so the palette dry-run and the template
/// render hand matugen the identical string.
fn schemeCliName(raw: []const u8) []const u8 {
    var tmp: [64]u8 = undefined;
    const len = @min(raw.len, tmp.len);
    for (raw[0..len], 0..) |c, i| tmp[i] = std.ascii.toLower(c);
    var s: []const u8 = tmp[0..len];
    while (s.len > 0 and std.ascii.isWhitespace(s[0])) s = s[1..];
    while (s.len > 0 and std.ascii.isWhitespace(s[s.len - 1])) s = s[0 .. s.len - 1];
    const known = [_][]const u8{
        "scheme-content",    "scheme-expressive", "scheme-fidelity",   "scheme-fruit-salad",
        "scheme-monochrome", "scheme-neutral",    "scheme-rainbow",    "scheme-tonal-spot",
        "scheme-vibrant",
    };
    for (known) |k| {
        if (std.mem.eql(u8, s, k)) return k;
    }
    // The upstream `m3-` strip is dead code (see the doc comment); every
    // remaining alias maps to its canonical `scheme-*` name.
    return if (std.mem.eql(u8, s, "content"))
        known[0]
    else if (std.mem.eql(u8, s, "expressive"))
        known[1]
    else if (std.mem.eql(u8, s, "fidelity") or std.mem.eql(u8, s, "faithful"))
        known[2]
    else if (std.mem.eql(u8, s, "fruit-salad") or std.mem.eql(u8, s, "fruitsalad"))
        known[3]
    else if (std.mem.eql(u8, s, "monochrome"))
        known[4]
    else if (std.mem.eql(u8, s, "neutral"))
        known[5]
    else if (std.mem.eql(u8, s, "rainbow"))
        known[6]
    else if (std.mem.eql(u8, s, "tonal-spot") or std.mem.eql(u8, s, "tonal_spot"))
        known[7]
    else if (std.mem.eql(u8, s, "vibrant"))
        known[8]
    else
        known[0];
}

fn bumpMtimeNow(io: std.Io, path: []const u8) void {
    _ = io; // raw syscall; kept for call-site symmetry with the other helpers
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    const times = [_]linux.timespec{ linux.UTIME.NOW, linux.UTIME.NOW };
    _ = linux.utimensat(linux.AT.FDCWD, z, &times, 0);
}

fn touchVscodeThemeExtensionOutputs(io: std.Io, ext_dir: []const u8) void {
    const names = [_][]const u8{ "matugen-eh-dark.json", "matugen-eh-light.json", "matugen-eh-default.json" };
    for (names) |n| {
        var b: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&b, "{s}/{s}", .{ ext_dir, n })) |f| {
            if (isRegular(io, f)) bumpMtimeNow(io, f);
        } else |_| {}
    }
}

/// These settings files parse with comments enabled (VS Code's
/// settings.json is JSONC); Zig's parser has no comment support, so strip
/// `//` and `/* */` comments outside string literals first.
fn stripJsonComments(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    var in_str = false;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (in_str) {
            try out.append(alloc, c);
            if (c == '\\' and i + 1 < raw.len) {
                i += 1;
                try out.append(alloc, raw[i]);
            } else if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') {
            in_str = true;
            try out.append(alloc, c);
            continue;
        }
        if (c == '/' and i + 1 < raw.len and raw[i + 1] == '/') {
            while (i < raw.len and raw[i] != '\n') i += 1;
            if (i < raw.len) try out.append(alloc, '\n');
            continue;
        }
        if (c == '/' and i + 1 < raw.len and raw[i + 1] == '*') {
            i += 2;
            while (i + 1 < raw.len and !(raw[i] == '*' and raw[i + 1] == '/')) i += 1;
            i += 1; // land on the closing '/' (or the last byte when unterminated)
            continue;
        }
        try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

/// Read + parse a settings file the way every merge hook does: comments
/// allowed, parse failure falls back to an empty object.
fn loadJsonObject(arena: std.mem.Allocator, io: std.Io, path: []const u8) std.json.Value {
    const empty: std.json.Value = .{ .object = .{} };
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20)) catch return empty;
    const stripped = stripJsonComments(arena, raw) catch return empty;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, stripped, .{}) catch empty;
}

/// JSON dump with 2-space indent. Key order differs (sorted vs insertion order)
/// sorts, Zig preserves insertion order) — semantically identical JSON, and
/// every reader here only re-parses the file.
fn writeJsonObject(arena: std.mem.Allocator, io: std.Io, path: []const u8, v: std.json.Value) void {
    const data = std.json.Stringify.valueAlloc(arena, v, .{ .whitespace = .indent_2 }) catch return;
    const full = arena.alloc(u8, data.len + 1) catch return;
    @memcpy(full[0..data.len], data);
    full[data.len] = '\n';
    writeAll(io, path, full);
}

fn isDirectory(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

fn fileEquals(alloc: std.mem.Allocator, io: std.Io, path: []const u8, want: []const u8) bool {
    const cur = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 << 20)) catch return false;
    defer alloc.free(cur);
    return std.mem.eql(u8, cur, want);
}

/// Fill the trailing `XXXXXX` of a temp template with random alphanumeric
/// bytes (getrandom, matching `mkdtemp`/`mkstemp` entropy).
fn fillTempX(buf: []u8) void {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var rnd: [6]u8 = undefined;
    var off: usize = 0;
    while (off < rnd.len) {
        const n = linux.getrandom(rnd[off..].ptr, rnd.len - off, 0);
        if (linux.errno(n) != .SUCCESS) break;
        const got: usize = @intCast(n);
        if (got == 0) break;
        off += got;
    }
    for (rnd[off..]) |*b| b.* = 0;
    for (buf, 0..) |*c, i| c.* = alphabet[rnd[i % rnd.len] % alphabet.len];
}

/// `mkdtemp(3)`: create a unique directory from a `…XXXXXX` template.
/// Returns the created path (owned) or null.
fn mkdtempPath(alloc: std.mem.Allocator, template: []const u8) ?[]u8 {
    if (template.len < 6) return null;
    var buf: [512]u8 = undefined;
    if (template.len > buf.len - 1) return null;
    @memcpy(buf[0..template.len], template);
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        fillTempX(buf[template.len - 6 .. template.len]);
        buf[template.len] = 0;
        const z: [*:0]const u8 = @ptrCast(&buf);
        const rc = linux.mkdir(z, 0o700);
        if (linux.errno(rc) == .SUCCESS) {
            return alloc.dupe(u8, buf[0..template.len]) catch null;
        }
        if (linux.errno(rc) != .EXIST) return null;
    }
    return null;
}

/// `mkstemp(3)`: create and open a unique file from a `…XXXXXX` template.
/// Returns the created path (owned) plus the write fd, or null.
fn mkstempPath(alloc: std.mem.Allocator, template: []const u8) ?struct { path: []u8, fd: i32 } {
    if (template.len < 6) return null;
    var buf: [512]u8 = undefined;
    if (template.len > buf.len - 1) return null;
    @memcpy(buf[0..template.len], template);
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        fillTempX(buf[template.len - 6 .. template.len]);
        buf[template.len] = 0;
        const z: [*:0]const u8 = @ptrCast(&buf);
        const fd = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
        if (linux.errno(fd) == .SUCCESS) {
            const path = alloc.dupe(u8, buf[0..template.len]) catch {
                _ = linux.close(@intCast(fd));
                return null;
            };
            return .{ .path = path, .fd = @intCast(fd) };
        }
        if (linux.errno(fd) != .EXIST) return null;
    }
    return null;
}

/// `rewrite_legacy_event16`: legacy `event16.colorN.` slots → `base16.baseXX.`.
/// The 16-entry map, applied highest index first.
fn rewriteLegacyEvent16(buf: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    if (std.mem.indexOf(u8, buf.items, "event16.color") == null) return;
    const kMap = [_][]const u8{
        "base00", "base08", "base0b", "base0a", "base0d", "base0e", "base0c", "base05",
        "base03", "base08", "base0b", "base0a", "base0d", "base0e", "base0c", "base07",
    };
    var i: isize = 15;
    while (i >= 0) : (i -= 1) {
        var from_b: [24]u8 = undefined;
        var to_b: [24]u8 = undefined;
        const from = try std.fmt.bufPrint(&from_b, "event16.color{d}.", .{@as(usize, @intCast(i))});
        const to = try std.fmt.bufPrint(&to_b, "base16.{s}.", .{kMap[@intCast(i)]});
        try replaceAll(buf, alloc, from, to);
    }
}

/// `normalize_base16_default_variant`: `base16.base0X.default.` →
/// `base16.base0X.dark.`. The hex-digit table covers both cases (0-9a-fA-F).
fn normalizeBase16DefaultVariant(buf: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    const kHexDigits = "0123456789abcdefABCDEF";
    // Iterate `h + 1 < len` (length includes the NUL, so
    // h runs over all 22 hex chars); replicate the range exactly.
    var h: usize = 0;
    while (h + 1 < kHexDigits.len + 1) : (h += 1) {
        var pre_b: [24]u8 = undefined;
        var from_b: [40]u8 = undefined;
        var to_b: [40]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&pre_b, "base16.base0{c}.", .{kHexDigits[h]});
        const from = try std.fmt.bufPrint(&from_b, "{s}default.", .{prefix});
        const to = try std.fmt.bufPrint(&to_b, "{s}dark.", .{prefix});
        try replaceAll(buf, alloc, from, to);
    }
}

/// `template_tree_has_legacy_event16`: recursive walk; true on the first
/// regular file whose bytes contain `event16.color`.
fn templateTreeHasLegacyEvent16(alloc: std.mem.Allocator, io: std.Io, root: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .directory) {
            var b: [4096]u8 = undefined;
            const sub = std.fmt.bufPrint(&b, "{s}/{s}", .{ root, e.name }) catch continue;
            if (templateTreeHasLegacyEvent16(alloc, io, sub)) return true;
        } else if (e.kind == .file or e.kind == .sym_link) {
            var b: [4096]u8 = undefined;
            const fp = std.fmt.bufPrint(&b, "{s}/{s}", .{ root, e.name }) catch continue;
            const data = std.Io.Dir.cwd().readFileAlloc(io, fp, alloc, .limited(4 << 20)) catch continue;
            defer alloc.free(data);
            if (std.mem.indexOf(u8, data, "event16.color") != null) return true;
        }
    }
    return false;
}

/// `copy_templates_sanitized`: recursive copy of the template tree applying
/// the legacy `event16` rewrite + base16 default-variant normalization.
fn copyTemplatesSanitized(alloc: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8) bool {
    std.Io.Dir.cwd().createDirPath(io, dst) catch return false;
    var dir = std.Io.Dir.cwd().openDir(io, src, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .directory) {
            var b: [4096]u8 = undefined;
            var b2: [4096]u8 = undefined;
            const sub = std.fmt.bufPrint(&b, "{s}/{s}", .{ src, e.name }) catch continue;
            const sub_dst = std.fmt.bufPrint(&b2, "{s}/{s}", .{ dst, e.name }) catch continue;
            if (!copyTemplatesSanitized(alloc, io, sub, sub_dst)) return false;
        } else if (e.kind == .file or e.kind == .sym_link) {
            var b: [4096]u8 = undefined;
            var b2: [4096]u8 = undefined;
            const fp = std.fmt.bufPrint(&b, "{s}/{s}", .{ src, e.name }) catch continue;
            const out_path = std.fmt.bufPrint(&b2, "{s}/{s}", .{ dst, e.name }) catch continue;
            if (std.fs.path.dirname(out_path)) |od| {
                std.Io.Dir.cwd().createDirPath(io, od) catch return false;
            }
            const data = std.Io.Dir.cwd().readFileAlloc(io, fp, alloc, .limited(4 << 20)) catch return false;
            defer alloc.free(data);
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(alloc);
            buf.appendSlice(alloc, data) catch return false;
            rewriteLegacyEvent16(&buf, alloc) catch return false;
            normalizeBase16DefaultVariant(&buf, alloc) catch return false;
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = buf.items }) catch return false;
        }
    }
    return true;
}

/// `run_matugen_image`: spawn `matugen` with the merged config, cwd at the
/// bundle root, stdin `/dev/null`, stdout/stderr inherited.
/// redirects stdin via `posix_spawn_file_actions_addopen`). True on exit 0.
fn runMatugenImage(io: std.Io, cwd: []const u8, cfg_file: []const u8, image_abs: []const u8, mode_arg: []const u8, scheme: []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{
            "matugen",         "-c",          cfg_file, "image",
            image_abs,         "--source-color-index", "0", "-m",
            mode_arg,          "-t",          scheme,
        },
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    if (term != .exited) return false;
    return term.exited == 0;
}

test "apply: gate table covers every toggles file gate" {
    // run_bundled_toml is a merge switch, not a file gate; every other field
    // maps to exactly one bundled TOML.
    const toggles = schema3.MatugenToggles{};
    const table = gateTable(&toggles);
    try std.testing.expectEqual(@as(usize, 37), table.len);
    for (table) |g| try std.testing.expect(g.flag);
}

test "apply: mode normalization matches normalize_matugen_mode subset" {
    try std.testing.expect(modeIsDark("dark"));
    try std.testing.expect(modeIsDark("Dark"));
    try std.testing.expect(modeIsDark("auto"));
    try std.testing.expect(modeIsDark("weird"));
    try std.testing.expect(modeIsDark("  garbage  "));
    try std.testing.expect(!modeIsDark("light"));
    try std.testing.expect(!modeIsDark("Light"));
    try std.testing.expect(!modeIsDark("  light  "));
}

test "apply: scheme CLI normalization matches normalize_matugen_scheme" {
    const t = std.testing;
    try t.expectEqualStrings("scheme-vibrant", schemeCliName("vibrant"));
    try t.expectEqualStrings("scheme-vibrant", schemeCliName("  Scheme-Vibrant  "));
    try t.expectEqualStrings("scheme-tonal-spot", schemeCliName("tonal_spot"));
    try t.expectEqualStrings("scheme-fruit-salad", schemeCliName("fruitsalad"));
    try t.expectEqualStrings("scheme-fidelity", schemeCliName("faithful"));
    try t.expectEqualStrings("scheme-neutral", schemeCliName("scheme-neutral"));
    // Upstream's `m3-` strip never matches; Content is the fallback.
    try t.expectEqualStrings("scheme-content", schemeCliName("m3-vibrant"));
    try t.expectEqualStrings("scheme-content", schemeCliName("nonsense"));
}

test "apply: fixPaths rewrites every placeholder in order" {
    const t = std.testing;
    const alloc = t.allocator;
    var body = std.ArrayList(u8).empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc,
        \\[templates.demo]
        \\input_path = 'SHELL_DIR/matugen/templates/demo.toml'
        \\output_path = 'CONFIG_DIR/demo-out.toml'
        \\vsc = 'VSCODE_USER_DIR/settings.json'
        \\ext = 'VSCODE_EXT_EH_THEMES_DIR/theme.json'
        \\home = 'HOME_DIR/notes.txt'
        \\cache = 'CACHE_DIR/demo'
        \\data = 'DATA_DIR/demo'
        \\emacs = 'EMACS_DIR/init.el'
        \\input_path = '~/tpl/a.toml'
        \\input_path = '~\./tpl/b.toml'
        \\input_path = './matugen/templates/c.toml'
        \\input_path = '/home/u/.config/quickshell/matugen/templates/d.toml'
        \\output_path = '~/out/e.css'
        \\output_path = '~\./out/f.css'
        \\
    );
    try fixPaths(alloc, &body, "/root", "/cfg", "/home/u", "/vscode-user", "/vscode-ext", "/root/matugen/templates");
    const want =
        \\[templates.demo]
        \\input_path = '/root/matugen/templates/demo.toml'
        \\output_path = '/cfg/demo-out.toml'
        \\vsc = '/vscode-user/settings.json'
        \\ext = '/vscode-ext/theme.json'
        \\home = '/home/u/notes.txt'
        \\cache = '/home/u/.cache/demo'
        \\data = '/home/u/.local/share/demo'
        \\emacs = '/home/u/.emacs.d/init.el'
        \\input_path = '/home/u/tpl/a.toml'
        \\input_path = '/home/u/.tpl/b.toml'
        \\input_path = '/root/matugen/templates/c.toml'
        \\input_path = '/root/matugen/templates/d.toml'
        \\output_path = '/home/u/out/e.css'
        \\output_path = '/home/u/.out/f.css'
        \\
    ;
    try t.expectEqualStrings(want, body.items);
}

test "apply: readFileLines/joinLines round-trip matches getline semantics" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const file = try std.fs.path.join(alloc, &.{ root, "x.txt" });
    defer alloc.free(file);

    // Trailing newline must not yield a final empty line; \r is stripped.
    writeAll(io, file, "a\r\nb\n");
    var lines = try readFileLines(alloc, io, file);
    defer freeLines(alloc, &lines);
    try t.expectEqual(@as(usize, 2), lines.items.len);
    try t.expectEqualStrings("a", lines.items[0]);
    try t.expectEqualStrings("b", lines.items[1]);

    const joined = try joinLines(alloc, &lines);
    defer alloc.free(joined);
    try t.expectEqualStrings("a\nb\n", joined);

    // Missing file → empty list, not an error.
    const missing = try std.fs.path.join(alloc, &.{ root, "nope.txt" });
    defer alloc.free(missing);
    var none = try readFileLines(alloc, io, missing);
    defer freeLines(alloc, &none);
    try t.expectEqual(@as(usize, 0), none.items.len);
}

test "apply: hex conf parse and float formatting match the specified forms" {
    const t = std.testing;
    const alloc = t.allocator;
    var map = try parseHexConf(alloc,
        \\just a plain comment line
        \\dock_fill = "#1a2b3c"
        \\spaced  =   "  #ffffff"   
        \\empty =
        \\unterminated = "#12345
        \\
    );
    defer hexMapDeinit(alloc, &map);
    try t.expectEqual(@as(usize, 3), map.count());
    try t.expectEqualStrings("#1a2b3c", map.get("dock_fill").?);
    // Quote stripping happens before the trim, so leading spaces stay inside.
    // Trailing spaces survive the front-trim, so the quote strip does not
    // fire — trailing spaces block the quote strip for this input.
    try t.expectEqualStrings("\"  #ffffff\"   ", map.get("spaced").?);
    // Unterminated quote → no strip (both ends checked).
    try t.expectEqualStrings("\"#12345", map.get("unterminated").?);

    var rgb: [3]f64 = undefined;
    try t.expect(hexToRgbF64("#1a2b3c", &rgb));
    try t.expectApproxEqAbs(@as(f64, 0x1a) / 255.0, rgb[0], 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0x2b) / 255.0, rgb[1], 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0x3c) / 255.0, rgb[2], 1e-12);
    try t.expect(hexToRgbF64("aabbcc", &rgb));
    try t.expect(!hexToRgbF64("#abc", &rgb));
    try t.expect(!hexToRgbF64("#zzzzzz", &rgb));

    // snprintf("%.6f") parity.
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("0.101961", fmtFloat6(&buf, 26.0 / 255.0));
    try t.expectEqualStrings("1.000000", fmtFloat6(&buf, 1.0));
    try t.expectEqualStrings("0.000000", fmtFloat6(&buf, 0.0));
}

test "apply: horizon-files mapping keys are unique and indexed" {
    const t = std.testing;
    // No two rows may claim the same settings key (hfRepIndex returns the
    // first match, so a duplicate would silently shadow the later row).
    for (0..files_map.len * 3) |i| {
        for (i + 1 .. files_map.len * 3) |j| {
            try t.expect(!std.mem.eql(u8, hfKey(i), hfKey(j)));
        }
    }
    try t.expectEqual(@as(usize, 54), files_map.len);
    try t.expectEqual(@as(usize, 11), photo_map.len);
    try t.expectEqualStrings("matugenDockFillR", hfKey(hfRepIndex("matugenDockFillR").?));
    try t.expect(hfRepIndex("matugenNopeR") == null);
}

test "apply: syncHorizonFiles patches appearance, drops strays, sets ok" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const eh = try std.fs.path.join(alloc, &.{ root, "event-horizon" });
    defer alloc.free(eh);
    try std.Io.Dir.cwd().createDirPath(io, eh);

    const mfile = try std.fs.path.join(alloc, &.{ eh, "horizon-files-matugen.conf" });
    defer alloc.free(mfile);
    writeAll(io, mfile, "dock_fill = \"#000000\"\nprimary = \"#ffffff\"\n");

    const sfile = try std.fs.path.join(alloc, &.{ eh, "state-settings.toml" });
    defer alloc.free(sfile);
    writeAll(io, sfile,
        \\[dock]
        \\matugenDockFillR = 0.5
        \\
        \\[appearance]
        \\matugenPrimaryR = 0.1
        \\matugenPaletteOk = false
        \\unrelated = "keep"
        \\
    );

    var ap = Applier.init(alloc, io, root);
    defer ap.deinit();
    ap.syncHorizonFiles(root);

    const got = std.Io.Dir.cwd().readFileAlloc(io, sfile, alloc, .limited(1 << 20)) catch
        return error.MissingResult;
    defer alloc.free(got);
    // The stray [dock] occurrence is dropped (header exists), the in-place
    // primary row is rewritten, missing keys land inside [appearance], and
    // matugenPaletteOk is injected.
    try t.expect(std.mem.indexOf(u8, got, "matugenDockFillR = 0.5") == null);
    try t.expect(std.mem.indexOf(u8, got, "matugenPrimaryR = 1.000000") != null);
    try t.expect(std.mem.indexOf(u8, got, "unrelated = \"keep\"") != null);
    try t.expect(std.mem.indexOf(u8, got, "matugenDockFillG") != null);
    try t.expect(std.mem.indexOf(u8, got, "matugenPaletteOk = true") != null);
    // [appearance] is the last table here, so flushed keys land at EOF but
    // still inside it (never in [dock], which precedes it).
    const ap_at = std.mem.indexOf(u8, got, "[appearance]").?;
    const dock_at = std.mem.indexOf(u8, got, "[dock]").?;
    try t.expect(dock_at < ap_at);
    try t.expect(std.mem.indexOf(u8, got, "matugenDockFillG").? > ap_at);

    // The stray drop means pass 1 is not yet converged (cleared per pass
    // pending entry even for a misplaced line, so the key returns on the next
    // pass); from the converged state on, identical inputs never rewrite
    // (inotify loop guard).
    ap.syncHorizonFiles(root);
    const converged = std.Io.Dir.cwd().readFileAlloc(io, sfile, alloc, .limited(1 << 20)) catch
        return error.MissingResult;
    defer alloc.free(converged);
    try t.expect(std.mem.indexOf(u8, converged, "matugenDockFillR = 0.000000") != null);
    const mtime_before = (try std.Io.Dir.cwd().statFile(io, sfile, .{})).mtime;
    ap.syncHorizonFiles(root);
    const mtime_after = (try std.Io.Dir.cwd().statFile(io, sfile, .{})).mtime;
    try t.expectEqual(mtime_before.nanoseconds, mtime_after.nanoseconds);
}

/// The whole line for `key`, byte for byte — nothing on it past the value.
fn expectLine(got: []const u8, key: []const u8, want: []const u8) !void {
    var it = std.mem.splitScalar(u8, got, '\n');
    while (it.next()) |ln| {
        if (!std.mem.startsWith(u8, ln, key)) continue;
        if (ln.len == key.len or ln[key.len] != ' ') continue;
        try std.testing.expectEqualStrings(want, ln);
        return;
    }
    return error.LineMissing;
}

test "apply: syncHorizonFiles writes floats, never bytes past them" {
    // Regression: the replacement slot was a fixed [32]u8 and only the float's
    // bytes were copied in, so the length died on the spot; `{s}` on an array
    // prints all 32. Every matugen line trailed ~24 bytes of undefined memory
    // (0xaa in the shipped build), which left state-settings.toml invalid
    // UTF-8/TOML — a parse failure aborts the entire read
    // was abandoned. A substring probe sails right past that; this one does not.
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const eh = try std.fs.path.join(alloc, &.{ root, "event-horizon" });
    defer alloc.free(eh);
    try std.Io.Dir.cwd().createDirPath(io, eh);

    const mfile = try std.fs.path.join(alloc, &.{ eh, "horizon-files-matugen.conf" });
    defer alloc.free(mfile);
    // `panel_fill` is deliberately absent: its role has no replacement this
    // pass, which is the second half of the bug (a null slot, unwrapped).
    writeAll(io, mfile, "accent = \"#ff0000\"\nprimary = \"#ffffff\"\n");

    const sfile = try std.fs.path.join(alloc, &.{ eh, "state-settings.toml" });
    defer alloc.free(sfile);
    writeAll(io, sfile,
        \\[appearance]
        \\matugenAccentR = 0.5
        \\matugenAccentG = 0.5
        \\matugenAccentB = 0.5
        \\matugenPanelFillR = 0.3
        \\matugenPaletteOk = false
        \\
    );

    var ap = Applier.init(alloc, io, root);
    defer ap.deinit();
    ap.syncHorizonFiles(root);

    const got = std.Io.Dir.cwd().readFileAlloc(io, sfile, alloc, .limited(1 << 20)) catch
        return error.MissingResult;
    defer alloc.free(got);

    // In-place rows, rewritten; missing rows, flushed into [appearance].
    try expectLine(got, "matugenAccentR", "matugenAccentR = 1.000000");
    try expectLine(got, "matugenAccentG", "matugenAccentG = 0.000000");
    try expectLine(got, "matugenAccentB", "matugenAccentB = 0.000000");
    try expectLine(got, "matugenPrimaryR", "matugenPrimaryR = 1.000000");
    try expectLine(got, "matugenPrimaryG", "matugenPrimaryG = 1.000000");
    try expectLine(got, "matugenPrimaryB", "matugenPrimaryB = 1.000000");
    // No hex for panel_fill: the stored line stands.
    // key it finds no replacement for — nothing is unwrapped, nothing is lost.
    try expectLine(got, "matugenPanelFillR", "matugenPanelFillR = 0.3");

    // And the file still has to be something the other side can parse.
    try t.expect(std.mem.indexOfScalar(u8, got, 0xaa) == null);
    try t.expect(std.unicode.utf8ValidateSlice(got));
}

test "apply: syncAlacritty creates, extends, and skips" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const dir = try std.fs.path.join(alloc, &.{ root, "alacritty" });
    defer alloc.free(dir);
    const conf = try std.fs.path.join(alloc, &.{ dir, "alacritty.toml" });
    defer alloc.free(conf);

    var ap = Applier.init(alloc, io, root);
    defer ap.deinit();

    // No config at all → [general] + import appended.
    ap.syncAlacritty(root);
    const got1 = std.Io.Dir.cwd().readFileAlloc(io, conf, alloc, .limited(1 << 20)) catch
        return error.MissingResult;
    defer alloc.free(got1);
    try t.expectEqualStrings("[general]\nimport = [\"event-theme.toml\"]\n", got1);

    // Existing inline array is extended in place.
    writeAll(io, conf, "[general]\nimport = [\"other.toml\"]\n");
    ap.syncAlacritty(root);
    const got2 = std.Io.Dir.cwd().readFileAlloc(io, conf, alloc, .limited(1 << 20)) catch
        return error.MissingResult;
    defer alloc.free(got2);
    try t.expectEqualStrings("[general]\nimport = [\"other.toml\", \"event-theme.toml\"]\n", got2);

    // Already imported → untouched.
    writeAll(io, conf, "[general]\nimport = [\"event-theme.toml\"]\nsomething = 1\n");
    ap.syncAlacritty(root);
    const got3 = std.Io.Dir.cwd().readFileAlloc(io, conf, alloc, .limited(1 << 20)) catch
        return error.MissingResult;
    defer alloc.free(got3);
    try t.expectEqualStrings("[general]\nimport = [\"event-theme.toml\"]\nsomething = 1\n", got3);
}

test "apply: syncHorizonCalendar selects the section from matugen_mode" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const eh = try std.fs.path.join(alloc, &.{ root, "event-horizon" });
    defer alloc.free(eh);
    try std.Io.Dir.cwd().createDirPath(io, eh);

    const mfile = try std.fs.path.join(alloc, &.{ eh, "horizon-calendar-matugen.conf" });
    defer alloc.free(mfile);
    writeAll(io, mfile, "day_bg = \"#101010\"\nday_fg = \"#f0f0f0\"\n");
    const sfile = try std.fs.path.join(alloc, &.{ eh, "state-settings.toml" });
    defer alloc.free(sfile);
    writeAll(io, sfile, "[appearance]\nmatugen_mode = \"light\"\n");

    var ap = Applier.init(alloc, io, root);
    defer ap.deinit();
    ap.syncHorizonCalendar(root);

    const theme = try std.fs.path.join(alloc, &.{ root, "horizon-calendar", "theme.toml" });
    defer alloc.free(theme);
    const got = std.Io.Dir.cwd().readFileAlloc(io, theme, alloc, .limited(1 << 20)) catch
        return error.MissingResult;
    defer alloc.free(got);
    try t.expect(std.mem.indexOf(u8, got, "[light]") != null);
    try t.expect(std.mem.indexOf(u8, got, "day_bg = \"#101010\"") != null);
    try t.expect(std.mem.indexOf(u8, got, "[dark]") == null);
}

test "apply: syncHorizonPhoto writes float RGB under the state dir" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const eh = try std.fs.path.join(alloc, &.{ root, "event-horizon" });
    defer alloc.free(eh);
    try std.Io.Dir.cwd().createDirPath(io, eh);
    const mfile = try std.fs.path.join(alloc, &.{ eh, "horizon-photo-matugen.conf" });
    defer alloc.free(mfile);
    writeAll(io, mfile, "surface = \"#000000\"\non_surface = \"#ffffff\"\n");

    var ap = Applier.init(alloc, io, root);
    defer ap.deinit();
    ap.syncHorizonPhoto(root, root);

    const out = try std.fs.path.join(alloc, &.{ root, ".local/state/event-horizon/Horizon-photo/theme-colors.toml" });
    defer alloc.free(out);
    const got = std.Io.Dir.cwd().readFileAlloc(io, out, alloc, .limited(1 << 20)) catch
        return error.MissingResult;
    defer alloc.free(got);
    try t.expect(std.mem.indexOf(u8, got, "surface_r = 0.000000") != null);
    try t.expect(std.mem.indexOf(u8, got, "on_surface_r = 1.000000") != null);
    try t.expect(std.mem.indexOf(u8, got, "on_surface_b = 1.000000") != null);
}

test "apply: syncOtterTerm preserves per-line alpha and forces background BF" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const dir = try std.fs.path.join(alloc, &.{ root, "otter-shell" });
    defer alloc.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const mfile = try std.fs.path.join(alloc, &.{ dir, "otter-term-matugen.conf" });
    defer alloc.free(mfile);
    writeAll(io, mfile,
        \\colors_background = "#101010"
        \\colors_foreground = "#eeeeee"
        \\not_a_color = "#000000"
        \\
    );
    const cfile = try std.fs.path.join(alloc, &.{ dir, "otter-term.conf" });
    defer alloc.free(cfile);
    writeAll(io, cfile,
        \\colors_background = "#000000FF"
        \\colors_foreground = "#11111180"
        \\other = "keep"
        \\
    );

    var ap = Applier.init(alloc, io, root);
    defer ap.deinit();
    ap.syncOtterTerm(root);

    const got = std.Io.Dir.cwd().readFileAlloc(io, cfile, alloc, .limited(1 << 20)) catch
        return error.MissingResult;
    defer alloc.free(got);
    try t.expectEqualStrings(
        \\colors_background = "#101010BF"
        \\colors_foreground = "#eeeeee80"
        \\other = "keep"
        \\
    , got);
}

test "apply: syncBtop replaces or appends the color_theme line" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const dir = try std.fs.path.join(alloc, &.{ root, "btop" });
    defer alloc.free(dir);
    const conf = try std.fs.path.join(alloc, &.{ dir, "btop.conf" });
    defer alloc.free(conf);
    writeAll(io, conf, "color_theme = \"default\"\npreset = \"cpu\"\n");

    // Exercise the line surgery directly; the pkill tail would signal a real
    // process, so only the shared helpers are under test here.
    var lines = try readFileLines(alloc, io, conf);
    defer freeLines(alloc, &lines);
    try t.expect(try replaceFirstPrefixed(alloc, &lines, "color_theme", "color_theme = \"eh-matugen\""));
    const joined = try joinLines(alloc, &lines);
    defer alloc.free(joined);
    try t.expectEqualStrings("color_theme = \"eh-matugen\"\npreset = \"cpu\"\n", joined);
    // Absent key → no replacement, and the caller appends instead.
    var lines2 = try readFileLines(alloc, io, conf);
    defer freeLines(alloc, &lines2);
    try t.expect(!try replaceFirstPrefixed(alloc, &lines2, "missing_key", "missing_key = \"x\""));
    const nw = try alloc.dupe(u8, "missing_key = \"x\"");
    try lines2.append(alloc, nw);
    const joined2 = try joinLines(alloc, &lines2);
    defer alloc.free(joined2);
    try t.expectEqualStrings("color_theme = \"default\"\npreset = \"cpu\"\nmissing_key = \"x\"\n", joined2);
}

test "apply: video wallpaper paths resolve to the cached frame" {
    const t = std.testing;
    const alloc = t.allocator;
    try t.expect(hasVideoExt("/w/a.MP4"));
    try t.expect(hasVideoExt("/w/a.webm"));
    try t.expect(!hasVideoExt("/w/a.png"));
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    // The cached frame lives under the real $HOME, which the test cannot
    // control: either the path resolves to the frame or stays verbatim.
    const got = try normalizeWallpaperPath(alloc, io, "/w/clip.mkv");
    defer alloc.free(got);
    if (!std.mem.eql(u8, got, "/w/clip.mkv")) {
        try t.expect(std.mem.endsWith(u8, got, "/event-horizon/video-frame.png"));
    }
    const empty = try normalizeWallpaperPath(alloc, io, "");
    defer alloc.free(empty);
    try t.expectEqualStrings("", empty);
}

test "apply: stripJsonComments keeps strings and drops both comment forms" {
    const t = std.testing;
    const alloc = t.allocator;
    const got = try stripJsonComments(alloc,
        \\{"url": "http://x//y", /* block */ "a": 1, // line
        \\ "b": "still /* here */", "c": "esc \"//\" ok"}
    );
    defer alloc.free(got);
    try t.expectEqualStrings(
        \\{"url": "http://x//y",  "a": 1, 
        \\ "b": "still /* here */", "c": "esc \"//\" ok"}
    , got);
    // Unterminated block comments swallow the tail.
    const cut = try stripJsonComments(alloc, "{\"a\": 1} /* never closed");
    defer alloc.free(cut);
    try t.expectEqualStrings("{\"a\": 1} ", cut);
    // A JSON value with no comments passes through byte-for-byte.
    const plain = try stripJsonComments(alloc, "{\"a\": [1, 2]}");
    defer alloc.free(plain);
    try t.expectEqualStrings("{\"a\": [1, 2]}", plain);
}

test "apply: merge vesktop enables midnight.theme.css once" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    var bb: [4096]u8 = undefined;
    const dir = try std.fmt.bufPrint(&bb, "{s}/vesktop", .{root});
    var b1: [4200]u8 = undefined;
    const theme_css = try std.fmt.bufPrint(&b1, "{s}/themes/midnight.theme.css", .{dir});
    writeAll(io, theme_css, "body{}\n");

    var ap = Applier.init(alloc, io, root);
    defer ap.deinit();

    // No settings file yet -> created with the theme listed.
    ap.mergeVesktopVencordSettings(dir);
    var b2: [4300]u8 = undefined;
    const p1 = try std.fmt.bufPrint(&b2, "{s}/settings/settings.json", .{dir});
    const g1 = std.Io.Dir.cwd().readFileAlloc(io, p1, alloc, .limited(1 << 20)) catch return error.MissingResult;
    defer alloc.free(g1);
    try t.expect(std.mem.indexOf(u8, g1, "\"midnight.theme.css\"") != null);

    // Second pass must not duplicate the entry.
    ap.mergeVesktopVencordSettings(dir);
    const g2 = std.Io.Dir.cwd().readFileAlloc(io, p1, alloc, .limited(1 << 20)) catch return error.MissingResult;
    defer alloc.free(g2);
    const first = std.mem.indexOf(u8, g2, "\"midnight.theme.css\"").?;
    try t.expect(std.mem.indexOfPos(u8, g2, first + 1, "\"midnight.theme.css\"") == null);

    // Missing theme css -> the hook stays out of the way.
    writeAll(io, p1, "{\"enabledThemes\": []}\n");
    std.Io.Dir.cwd().deleteFile(io, theme_css) catch {};
    ap.mergeVesktopVencordSettings(dir);
    const g3 = std.Io.Dir.cwd().readFileAlloc(io, p1, alloc, .limited(1 << 20)) catch return error.MissingResult;
    defer alloc.free(g3);
    try t.expectEqualStrings("{\"enabledThemes\": []}\n", g3);
}

test "apply: merge heroic selects the css file and seeds customThemesPath" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    var bb: [4096]u8 = undefined;
    const dir = try std.fmt.bufPrint(&bb, "{s}/heroic", .{root});
    var b1: [4200]u8 = undefined;
    const store = try std.fmt.bufPrint(&b1, "{s}/store/config.json", .{dir});
    writeAll(io, store, "{\"theme\": \"default\"}\n");
    var b2: [4200]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&b2, "{s}/config.json", .{dir});
    writeAll(io, cfg, "{\"defaultSettings\": {\"customThemesPath\": \"\", \"other\": 1}}");

    var ap = Applier.init(alloc, io, root);
    defer ap.deinit();
    ap.mergeHeroicPrefs(dir);

    const g1 = std.Io.Dir.cwd().readFileAlloc(io, store, alloc, .limited(1 << 20)) catch return error.MissingResult;
    defer alloc.free(g1);
    try t.expect(std.mem.indexOf(u8, g1, "\"theme\": \"event-horizon.css\"") != null);

    const g2 = std.Io.Dir.cwd().readFileAlloc(io, cfg, alloc, .limited(1 << 20)) catch return error.MissingResult;
    defer alloc.free(g2);
    var b3: [4200]u8 = undefined;
    const want_path = try std.fmt.bufPrint(&b3, "{s}/themes", .{dir});
    try t.expect(std.mem.indexOf(u8, g2, want_path) != null);
    // Sibling keys survive the rewrite.
    try t.expect(std.mem.indexOf(u8, g2, "\"other\": 1") != null);

    // Older Event Horizon builds wrote the bare body class. Heroic joins
    // the stored value onto customThemesPath, so it must be repaired to
    // the actual CSS file name or the custom stylesheet stays unloaded.
    writeAll(io, store, "{\"theme\": \"event-horizon\"}\n");
    ap.mergeHeroicPrefs(dir);
    const g3 = std.Io.Dir.cwd().readFileAlloc(io, store, alloc, .limited(1 << 20)) catch return error.MissingResult;
    defer alloc.free(g3);
    try t.expect(std.mem.indexOf(u8, g3, "\"theme\": \"event-horizon.css\"") != null);

    // Already correct -> no rewrite (mtime loop guard).
    const mt1 = (try std.Io.Dir.cwd().statFile(io, store, .{})).mtime;
    ap.mergeHeroicPrefs(dir);
    const mt2 = (try std.Io.Dir.cwd().statFile(io, store, .{})).mtime;
    try t.expectEqual(mt1.nanoseconds, mt2.nanoseconds);
}

test "apply: merge fluxer copies the theme and allowlists it" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    var bb: [4096]u8 = undefined;
    const master = try std.fmt.bufPrint(&bb, "{s}/fluxer/themes/event-horizon.css", .{root});
    writeAll(io, master, ".eh { color: red; }\n");
    // Only fluxer exists; fluxercanary is skipped.
    var b1: [4200]u8 = undefined;
    const udir = try std.fmt.bufPrint(&b1, "{s}/.config/fluxer", .{root});
    std.Io.Dir.cwd().createDirPath(io, udir) catch {};
    var b2: [4300]u8 = undefined;
    const sp = try std.fmt.bufPrint(&b2, "{s}/settings.json", .{udir});
    writeAll(io, sp, "{\"unrelated\": true}");

    var ap = Applier.init(alloc, io, root);
    defer ap.deinit();
    ap.mergeFluxerPrefs(root, root);

    var b3: [4400]u8 = undefined;
    const theme = try std.fmt.bufPrint(&b3, "{s}/themes/event-horizon.css", .{udir});
    const g1 = std.Io.Dir.cwd().readFileAlloc(io, theme, alloc, .limited(1 << 20)) catch return error.MissingResult;
    defer alloc.free(g1);
    try t.expectEqualStrings(".eh { color: red; }\n", g1);

    const g2 = std.Io.Dir.cwd().readFileAlloc(io, sp, alloc, .limited(1 << 20)) catch return error.MissingResult;
    defer alloc.free(g2);
    try t.expect(std.mem.indexOf(u8, g2, theme) != null);
    try t.expect(std.mem.indexOf(u8, g2, "\"unrelated\": true") != null);

    // Second pass: theme already matches and the entry exists -> untouched.
    const mt = (try std.Io.Dir.cwd().statFile(io, sp, .{})).mtime;
    ap.mergeFluxerPrefs(root, root);
    const mt2 = (try std.Io.Dir.cwd().statFile(io, sp, .{})).mtime;
    try t.expectEqual(mt.nanoseconds, mt2.nanoseconds);
}

test "apply: merge vscode folds material colors and pins the theme" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    var bb: [4096]u8 = undefined;
    const udir = try std.fmt.bufPrint(&bb, "{s}/Code/User", .{root});
    var b1: [4200]u8 = undefined;
    const sp = try std.fmt.bufPrint(&b1, "{s}/settings.json", .{udir});
    writeAll(io, sp, "{\"editor.tabSize\": 4}");
    var b2: [4300]u8 = undefined;
    const mjson = try std.fmt.bufPrint(&b2, "{s}/material-code-colors.matugen.json", .{udir});
    // JSONC on disk: comments must not break the merge.
    writeAll(io, mjson, "// palette\n{\"material-code.colors\": {\"primary\": \"#ff0000\"}}");

    var ap = Applier.init(alloc, io, root);
    defer ap.deinit();
    ap.mergeVscodeUserSettings(udir, mjson, true, true, false);

    const g1 = std.Io.Dir.cwd().readFileAlloc(io, sp, alloc, .limited(1 << 20)) catch return error.MissingResult;
    defer alloc.free(g1);
    try t.expect(std.mem.indexOf(u8, g1, "\"editor.tabSize\": 4") != null);
    try t.expect(std.mem.indexOf(u8, g1, "material-code.colors") != null);
    try t.expect(std.mem.indexOf(u8, g1, "Event Horizon Dark") != null);

    // Light mode flips the pinned theme name.
    ap.mergeVscodeUserSettings(udir, mjson, false, true, true);
    const g2 = std.Io.Dir.cwd().readFileAlloc(io, sp, alloc, .limited(1 << 20)) catch return error.MissingResult;
    defer alloc.free(g2);
    try t.expect(std.mem.indexOf(u8, g2, "Event Horizon Light") != null);
    try t.expect(std.mem.indexOf(u8, g2, "Event Horizon Dark") == null);

    // Malformed palette aborts the merge without touching settings.json.
    writeAll(io, mjson, "{ not json");
    const mt = (try std.Io.Dir.cwd().statFile(io, sp, .{})).mtime;
    ap.mergeVscodeUserSettings(udir, mjson, true, true, false);
    const mt2 = (try std.Io.Dir.cwd().statFile(io, sp, .{})).mtime;
    try t.expectEqual(mt.nanoseconds, mt2.nanoseconds);
}

test "apply: ensure vscode extension seeds package.json from the bundle" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    var bb: [4096]u8 = undefined;
    const pkg = try std.fmt.bufPrint(&bb, "{s}/matugen/vscode-eh-themes/package.json", .{root});
    writeAll(io, pkg, "{\"name\": \"eh-matugen-themes\"}");
    var b1: [4200]u8 = undefined;
    const ext = try std.fmt.bufPrint(&b1, "{s}/ext", .{root});

    var ap = Applier.init(alloc, io, root);
    defer ap.deinit();
    ap.ensureVscodeEhThemeExtension(root, ext);

    var b2: [4300]u8 = undefined;
    const dst = try std.fmt.bufPrint(&b2, "{s}/package.json", .{ext});
    const got = std.Io.Dir.cwd().readFileAlloc(io, dst, alloc, .limited(1 << 20)) catch return error.MissingResult;
    defer alloc.free(got);
    try t.expectEqualStrings("{\"name\": \"eh-matugen-themes\"}", got);

    // No bundle manifest -> nothing is written.
    var b3: [4300]u8 = undefined;
    const ext2 = try std.fmt.bufPrint(&b3, "{s}/ext2", .{root});
    std.Io.Dir.cwd().deleteFile(io, pkg) catch {};
    ap.ensureVscodeEhThemeExtension(root, ext2);
    var b4: [4400]u8 = undefined;
    const dst2 = try std.fmt.bufPrint(&b4, "{s}/package.json", .{ext2});
    if (std.Io.Dir.cwd().statFile(io, dst2, .{})) |_| return error.UnexpectedFile else |_| {}
}

test "apply: external gate table differs from native only in the kitty file" {
    const t = std.testing;
    const toggles = schema3.MatugenToggles{};
    const nat = gateTable(&toggles);
    const ext = gateTableExternal(&toggles);
    try t.expectEqual(@as(usize, 37), ext.len);
    for (nat, ext) |n, e| {
        try t.expectEqual(n.flag, e.flag);
        try t.expectEqual(n.pred, e.pred);
        if (std.mem.eql(u8, n.file, "kitty.toml")) {
            try t.expectEqualStrings("kitty-theme.toml", e.file);
        } else {
            try t.expectEqualStrings(n.file, e.file);
        }
    }
}

test "apply: legacy event16 rewrite and base16 default-variant normalization" {
    const t = std.testing;
    const alloc = t.allocator;
    var body = std.ArrayList(u8).empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc,
        \\[theme]
        \\color = "event16.color15."
        \\c0 = "event16.color0."
        \\c1 = "event16.color1."
        \\c15 = "event16.color15."
        \\dark = "base16.base00.default."
        \\up = "base16.base0A.default."
        \\already = "base16.base02.dark."
        \\
    );
    try rewriteLegacyEvent16(&body, alloc);
    try normalizeBase16DefaultVariant(&body, alloc);
    const got = body.items;
    // kMap[15] = base07, kMap[0] = base00, kMap[1] = base08.
    try t.expect(std.mem.indexOf(u8, got, "event16.color") == null);
    try t.expect(std.mem.indexOf(u8, got, "\"base16.base07.\"") != null);
    try t.expect(std.mem.indexOf(u8, got, "\"base16.base00.\"") != null);
    try t.expect(std.mem.indexOf(u8, got, "\"base16.base08.\"") != null);
    // default -> dark for both cases; already-dark untouched.
    try t.expect(std.mem.indexOf(u8, got, "base16.base00.dark.") != null);
    try t.expect(std.mem.indexOf(u8, got, "base16.base0A.dark.") != null);
    try t.expect(std.mem.indexOf(u8, got, "base16.base00.default.") == null);
    try t.expect(std.mem.indexOf(u8, got, "base16.base02.dark.") != null);
    // idempotent.
    const snap = try alloc.dupe(u8, got);
    defer alloc.free(snap);
    try rewriteLegacyEvent16(&body, alloc);
    try normalizeBase16DefaultVariant(&body, alloc);
    try t.expectEqualStrings(snap, body.items);
}

test "apply: template-tree legacy detection and sanitized copy apply both rewrites" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);

    var b1: [4300]u8 = undefined;
    const src = try std.fmt.bufPrint(&b1, "{s}/templates", .{root});
    try std.Io.Dir.cwd().createDirPath(io, src);
    var b2: [4400]u8 = undefined;
    const sub = try std.fmt.bufPrint(&b2, "{s}/nested", .{src});
    try std.Io.Dir.cwd().createDirPath(io, sub);
    var b3: [4500]u8 = undefined;
    const clean = try std.fmt.bufPrint(&b3, "{s}/clean.toml", .{src});
    writeAll(io, clean, "hello = \"world\"\n");
    var b4: [4500]u8 = undefined;
    const leg = try std.fmt.bufPrint(&b4, "{s}/nested/legacy.toml", .{src});
    writeAll(io, leg, "c15 = \"event16.color15.\"\nd = \"base16.base00.default.\"\n");

    // Detection walks the tree (including nested) and finds the marker.
    try t.expect(templateTreeHasLegacyEvent16(alloc, io, src));

    // Sanitized copy applies both rewriters; clean files pass through.
    var b5: [4300]u8 = undefined;
    const dst = try std.fmt.bufPrint(&b5, "{s}/san", .{root});
    try t.expect(copyTemplatesSanitized(alloc, io, src, dst));
    var b6: [4400]u8 = undefined;
    const got_clean = try std.fmt.bufPrint(&b6, "{s}/clean.toml", .{dst});
    const clean_got = std.Io.Dir.cwd().readFileAlloc(io, got_clean, alloc, .limited(1 << 20)) catch return error.MissingResult;
    defer alloc.free(clean_got);
    try t.expectEqualStrings("hello = \"world\"\n", clean_got);
    var b7: [4500]u8 = undefined;
    const got_leg = try std.fmt.bufPrint(&b7, "{s}/nested/legacy.toml", .{dst});
    const leg_got = std.Io.Dir.cwd().readFileAlloc(io, got_leg, alloc, .limited(1 << 20)) catch return error.MissingResult;
    defer alloc.free(leg_got);
    try t.expect(std.mem.indexOf(u8, leg_got, "event16.color") == null);
    try t.expect(std.mem.indexOf(u8, leg_got, "\"base16.base07.\"") != null);
    try t.expect(std.mem.indexOf(u8, leg_got, "base16.base00.dark.") != null);

    // No marker -> no detection.
    std.Io.Dir.cwd().deleteFile(io, leg) catch {};
    try t.expect(!templateTreeHasLegacyEvent16(alloc, io, src));
}

test "apply: mkdtemp and mkstemp create unique paths" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;
    const d = mkdtempPath(alloc, "/tmp/eh-apply-test-XXXXXX") orelse return error.NoTempDir;
    defer {
        std.Io.Dir.cwd().deleteTree(io, d) catch {};
        alloc.free(d);
    }
    try t.expect(d.len == "/tmp/eh-apply-test-".len + 6);
    try t.expect(isDirectory(io, d));

    const f = mkstempPath(alloc, "/tmp/eh-apply-file-XXXXXX") orelse return error.NoTempFile;
    defer {
        std.Io.Dir.cwd().deleteFile(io, f.path) catch {};
        alloc.free(f.path);
    }
    _ = linux.close(f.fd);
    try t.expect(isRegular(io, f.path));
    try t.expect(!std.mem.eql(u8, d, f.path));
}

// End-to-end smoke for the external-`matugen` runner: real bundle, real
// merge + `fixPaths` + legacy-event16 sanitize, and a stub `matugen` that
// records its argv and keeps a copy of the `-c` config. The stub is put
// first on `PATH`; spawn resolves `argv[0]` against the I/O instance's
// environment snapshot, so the test hands the applier a fresh
// `Io.Threaded` built from the live `environ`. Skips when no bundle is
// discoverable (out-of-tree runs).
test "apply: external runner merges the bundle and spawns matugen" {
    const t = std.testing;
    const alloc = t.allocator;

    const bundle = bundleRoot(alloc, t.io) orelse return;
    defer alloc.free(bundle);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_rel = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root_rel);
    try std.Io.Dir.cwd().createDirPath(t.io, root_rel);
    var cbuf: [4096]u8 = undefined;
    const n: isize = @bitCast(linux.readlink("/proc/self/cwd", &cbuf, cbuf.len - 1));
    try t.expect(n > 0);
    const cwd = cbuf[0..@intCast(n)];
    const root = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ cwd, root_rel });
    defer alloc.free(root);

    const home = try std.fs.path.join(alloc, &.{ root, "home" });
    defer alloc.free(home);
    const cfg_main = try std.fs.path.join(alloc, &.{ home, ".config" });
    defer alloc.free(cfg_main);
    try std.Io.Dir.cwd().createDirPath(t.io, cfg_main);
    const wall = try std.fs.path.join(alloc, &.{ root, "wall.png" });
    defer alloc.free(wall);
    writeAll(t.io, wall, "\x89PNG\r\n\x1a\n");

    // Stub matugen: record argv, keep a copy of the `-c` config.
    const bin = try std.fs.path.join(alloc, &.{ root, "bin" });
    defer alloc.free(bin);
    try std.Io.Dir.cwd().createDirPath(t.io, bin);
    const fake = try std.fs.path.join(alloc, &.{ bin, "matugen" });
    defer alloc.free(fake);
    const args_out = try std.fs.path.join(alloc, &.{ root, "args.txt" });
    defer alloc.free(args_out);
    const conf_copy = try std.fs.path.join(alloc, &.{ root, "merged.toml" });
    defer alloc.free(conf_copy);
    const script = try std.fmt.allocPrint(alloc,
        \\#!/bin/sh
        \\printf '%s\n' "$@" > '{s}'
        \\prev=''
        \\for a in "$@"; do
        \\  if [ "$prev" = '-c' ]; then cp "$a" '{s}'; fi
        \\  prev="$a"
        \\done
        \\exit 0
        \\
    , .{ args_out, conf_copy });
    defer alloc.free(script);
    writeAll(t.io, fake, script);
    var fb: [4200]u8 = undefined;
    const fakez = try std.fmt.bufPrintZ(&fb, "{s}", .{fake});
    _ = linux.chmod(fakez, 0o755);

    // PATH: stub first, restored after the run.
    const old_path = getenvAny("PATH");
    const oldz = try alloc.dupeZ(u8, old_path);
    defer alloc.free(oldz);
    const path0 = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ bin, old_path });
    defer alloc.free(path0);
    const pathz = try alloc.dupeZ(u8, path0);
    defer alloc.free(pathz);
    {
        const c = @cImport(@cInclude("stdlib.h"));
        _ = c.setenv("PATH", pathz.ptr, 1);
    }
    defer {
        const c = @cImport(@cInclude("stdlib.h"));
        _ = c.setenv("PATH", oldz.ptr, 1);
    }

    // A fresh I/O instance whose spawn resolution reads the live `environ`
    // (the shared `std.testing.io` snapshotted PATH before the setenv above).
    const env_slice: [:null]const ?[*:0]const u8 =
        std.mem.span(@as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ)));
    var io2 = std.Io.Threaded.init(alloc, .{
        .environ = .{ .block = .{ .slice = env_slice } },
    });
    defer io2.deinit();

    var toggles = schema3.MatugenToggles{};
    toggles.btop = false; // no `pkill btop` from a test

    var ap = Applier.init(alloc, io2.io(), root);
    defer ap.deinit();
    const ok = ap.applyExternal(.{
        .wallpaper_image = wall,
        .scheme = "  Vibrant  ",
        .mode = "light",
        .horizon_native = false,
        .horizon_ok = false,
        .matugen_theming = true,
        .matugen_palette_ok = true,
        .toggles = &toggles,
        .env = .{ .home = home, .cfg_main = cfg_main, .state_dir = root },
    });
    try t.expect(ok);

    const args = try std.Io.Dir.cwd().readFileAlloc(t.io, args_out, alloc, .limited(1 << 16));
    defer alloc.free(args);
    try t.expect(std.mem.indexOf(u8, args, "\nimage\n") != null);
    try t.expect(std.mem.indexOf(u8, args, "\n--source-color-index\n0\n") != null);
    try t.expect(std.mem.indexOf(u8, args, "\n-m\nlight\n") != null);
    // `normalize_matugen_scheme` semantics: trimmed, aliased to `scheme-*`.
    try t.expect(std.mem.indexOf(u8, args, "\n-t\nscheme-vibrant\n") != null);

    const conf = try std.Io.Dir.cwd().readFileAlloc(t.io, conf_copy, alloc, .limited(1 << 20));
    defer alloc.free(conf);
    // The gated fragments merged (gtk is an always-on gate) ...
    try t.expect(std.mem.indexOf(u8, conf, "[templates.ehgtk_shell_gtk4]") != null);
    // ... with every `fixPaths` macro substituted to the scratch env ...
    for ([_][]const u8{
        "SHELL_DIR", "CONFIG_DIR", "VSCODE_USER_DIR", "VSCODE_EXT_EH_THEMES_DIR",
        "HOME_DIR",  "CACHE_DIR",  "DATA_DIR",       "EMACS_DIR",
    }) |macro| {
        try t.expect(std.mem.indexOf(u8, conf, macro) == null);
    }
    try t.expect(std.mem.indexOf(u8, conf, cfg_main) != null);
    // Every input the config names resolves to a readable file: either the
    // bundle templates or the sanitized temp copy (reaped after the run).
    var it = std.mem.splitScalar(u8, conf, '\n');
    var inputs: usize = 0;
    while (it.next()) |line| {
        const key = "input_path = '";
        if (std.mem.indexOf(u8, line, key) == null) continue;
        const start = std.mem.indexOf(u8, line, key).? + key.len;
        const end = std.mem.indexOfScalarPos(u8, line, start, '\'') orelse continue;
        const p = line[start..end];
        inputs += 1;
        if (std.mem.startsWith(u8, p, "/tmp/eh-mtpl-")) continue;
        if (!isRegular(t.io, p)) {
            std.debug.print("missing template input: {s}\n", .{p});
            return error.TestUnexpectedResult;
        }
    }
    try t.expect(inputs > 0);
}

// Native-engine end-to-end smoke: the real bundle rendered by the engine into
// a scratch env. Pre-creates the `event-horizon` and `owler` config dirs so
// the `dirEh` and `owlerFull` gates fire, then asserts the always-on template
// outputs land resolved (no `{{`), the Owler pack carries the Event Horizon
// names, and the horizon-files post-hook patched `state-settings.toml`.
// Skips when no bundle is discoverable (out-of-tree runs).
test "apply: native engine renders the bundle into the scratch config" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;

    const bundle = bundleRoot(alloc, io) orelse return;
    defer alloc.free(bundle);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_rel = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root_rel);
    try std.Io.Dir.cwd().createDirPath(io, root_rel);
    var cbuf: [4096]u8 = undefined;
    const n: isize = @bitCast(linux.readlink("/proc/self/cwd", &cbuf, cbuf.len - 1));
    try t.expect(n > 0);
    const cwd = cbuf[0..@intCast(n)];
    const root = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ cwd, root_rel });
    defer alloc.free(root);

    const home = try std.fs.path.join(alloc, &.{ root, "home" });
    defer alloc.free(home);
    const cfg_main = try std.fs.path.join(alloc, &.{ home, ".config" });
    defer alloc.free(cfg_main);
    try std.Io.Dir.cwd().createDirPath(io, cfg_main);

    const wall = try std.fs.path.join(alloc, &.{ root, "wall.bmp" });
    defer alloc.free(wall);
    try writeTwoToneBmp(alloc, io, wall);

    // Gates that read the config tree up front: the horizon-files fragment
    // and the Owler pack both stay off unless their dirs exist. Seed them,
    // plus a settings file for the horizon-files post-hook to patch.
    const eh_dir = try std.fs.path.join(alloc, &.{ cfg_main, "event-horizon" });
    defer alloc.free(eh_dir);
    try std.Io.Dir.cwd().createDirPath(io, eh_dir);
    const owler_dir = try std.fs.path.join(alloc, &.{ cfg_main, "owler" });
    defer alloc.free(owler_dir);
    try std.Io.Dir.cwd().createDirPath(io, owler_dir);
    const steam_dir = try std.fs.path.join(alloc, &.{ home, ".steam" });
    defer alloc.free(steam_dir);
    try std.Io.Dir.cwd().createDirPath(io, steam_dir);
    const settings = try std.fs.path.join(alloc, &.{ eh_dir, "state-settings.toml" });
    defer alloc.free(settings);
    writeAll(io, settings,
        \\[appearance]
        \\matugenPaletteOk = false
        \\matugenDockFillR = 0.0
        \\matugenDockFillG = 0.0
        \\matugenDockFillB = 0.0
        \\
    );

    var toggles = schema3.MatugenToggles{};
    toggles.btop = false; // no `pkill btop` from a test

    var ap = Applier.init(alloc, io, root);
    defer ap.deinit();
    const processed = ap.apply(.{
        .wallpaper_image = wall,
        .scheme = "content",
        .mode = "dark",
        .horizon_native = true,
        .horizon_ok = true,
        .matugen_theming = false,
        .matugen_palette_ok = false,
        .toggles = &toggles,
        .env = .{ .home = home, .cfg_main = cfg_main, .state_dir = root },
    });
    try t.expect(processed > 0);

    // Always-on gates across the template formats: GTK CSS (CONFIG_DIR), the
    // KDE scheme and the Ptyxis palette (DATA_DIR, dual-mode), otter-term
    // (`base16.* | lighten`), and the horizon-files hex map. `gtk.toml` and
    // `steam.toml` previously wrote `input_path  = ` with alignment spaces,
    // which both this parser and the C++ one drop silently (native mode never
    // rendered gtk.css/gtk-dark.css/steam.css); the bundle now uses ` = `.
    const outputs = [_][]const u8{
        try std.fs.path.join(alloc, &.{ cfg_main, "gtk-4.0", "gtk.css" }),
        try std.fs.path.join(alloc, &.{ cfg_main, "gtk-3.0", "gtk-dark.css" }),
        try std.fs.path.join(alloc, &.{ cfg_main, "gtk-4.0", "event-colors.css" }),
        try std.fs.path.join(alloc, &.{ cfg_main, "otter-shell", "otter-term-matugen.conf" }),
        try std.fs.path.join(alloc, &.{ eh_dir, "horizon-files-matugen.conf" }),
        try std.fs.path.join(alloc, &.{ home, ".local", "share", "color-schemes", "EventMatugen.colors" }),
        try std.fs.path.join(alloc, &.{ home, ".local", "share", "org.gnome.Ptyxis", "palettes", "Event-Horizon.palette" }),
    };
    for (outputs) |p| {
        defer alloc.free(p);
        try expectRendered(io, alloc, p);
    }
    // steam.css carries `<* *>` blocks, which native mode (like C++) leaves
    // raw; existence alone proves the entry now parses and renders.
    const steam_css = try std.fs.path.join(alloc, &.{ cfg_main, "steam", "matugen-colors.css" });
    defer alloc.free(steam_css);
    try t.expect(isRegular(io, steam_css));

    // The Owler pack is dual-mode: the light half exercises the opposite-mode
    // palette, and both halves carry the requested branding.
    const owl = try std.fs.path.join(alloc, &.{ owler_dir, "themes", "matugen.json" });
    defer alloc.free(owl);
    const owl_json = try std.Io.Dir.cwd().readFileAlloc(io, owl, alloc, .limited(1 << 20));
    defer alloc.free(owl_json);
    try t.expect(std.mem.indexOf(u8, owl_json, "Event Horizon Dark") != null);
    try t.expect(std.mem.indexOf(u8, owl_json, "Event Horizon Light") != null);
    try t.expect(std.mem.indexOf(u8, owl_json, "{{") == null);

    // The horizon-files post-hook replaces the `[appearance]` floats in
    // place and flips the ok flag.
    const st = try std.Io.Dir.cwd().readFileAlloc(io, settings, alloc, .limited(1 << 20));
    defer alloc.free(st);
    try t.expect(std.mem.indexOf(u8, st, "matugenPaletteOk = true") != null);
    var found_r = false;
    var lines = std.mem.splitScalar(u8, st, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "matugenDockFillR")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const val = std.fmt.parseFloat(f64, std.mem.trim(u8, line[eq + 1 ..], " \t")) catch continue;
        try t.expect(val > 0.001);
        found_r = true;
    }
    try t.expect(found_r);
}

/// Test helper: a rendered output exists and every `{{...}}` placeholder was
/// substituted (and no `fixPaths` macro leaked into a template body).
fn expectRendered(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !void {
    const body = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 << 20)) catch |e| {
        std.debug.print("template output missing: {s} ({s})\n", .{ path, @errorName(e) });
        return error.TestUnexpectedResult;
    };
    defer alloc.free(body);
    if (std.mem.indexOf(u8, body, "{{") != null) {
        std.debug.print("unresolved placeholder in {s}\n", .{path});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(std.mem.indexOf(u8, body, "SHELL_DIR") == null);
}

/// Test helper: a minimal 24-bit BMP fixture (the engine reference tests use
/// the same two-tone shape) so the native palette generation has a real image.
fn writeTwoToneBmp(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const w: usize = 64;
    const h: usize = 64;
    var data = std.ArrayList(u8).empty;
    defer data.deinit(alloc);
    var y: usize = h;
    while (y > 0) {
        y -= 1;
        for (0..w) |x| {
            const px: [3]u8 = if (x >= 16 and x < 48 and y >= 16 and y < 48)
                .{ 200, 30, 30 }
            else
                .{ 30, 80, 200 };
            try data.appendSlice(alloc, &.{ px[2], px[1], px[0] });
        }
    }
    var hdr = [_]u8{0} ** 54;
    std.mem.writeInt(u16, hdr[0..2], 0x4D42, .little);
    std.mem.writeInt(u32, hdr[2..6], @intCast(54 + data.items.len), .little);
    std.mem.writeInt(u32, hdr[10..14], 54, .little);
    std.mem.writeInt(u32, hdr[14..18], 40, .little);
    std.mem.writeInt(i32, hdr[18..22], @intCast(w), .little);
    std.mem.writeInt(i32, hdr[22..26], @intCast(h), .little);
    std.mem.writeInt(u16, hdr[26..28], 1, .little);
    std.mem.writeInt(u16, hdr[28..30], 24, .little);
    std.mem.writeInt(u32, hdr[34..38], @intCast(data.items.len), .little);
    std.mem.writeInt(i32, hdr[38..42], 2835, .little);
    std.mem.writeInt(i32, hdr[42..46], 2835, .little);
    var file = std.ArrayList(u8).empty;
    defer file.deinit(alloc);
    try file.appendSlice(alloc, &hdr);
    try file.appendSlice(alloc, data.items);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file.items });
}
