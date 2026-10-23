//! The external matugen template table — the data model behind the
//! redesigned Appearance ▸ Templates page.
//!
//! One entry per `[appearance.matugen_templates]` switch, in the same order
//! as the old `rows_appearance` tile grid (the `slot` is the index into
//! `Settings.matugen_templates`, so a page toggle and a placed toggle share
//! one bit). Each entry carries the roster group the page renders under, the
//! template file it renders from, the output it writes, its post-apply hook
//! and the gate rule that decides whether the application exists on this
//! system — the same predicates the apply path runs (`color/apply.zig`
//! `gateTableWith`, spelled out per template so the page can list which rows
//! are installed and which are off-system).
//!
//! Pure data and helpers: no cairo, no page state. Filesystem and
//! environment probes arrive as a `Probes` vtable, so `detected`, `status`
//! and the path resolution run identically against fixtures in tests and
//! against the real system from the page.

const std = @import("std");

/// One roster group on the page.
pub const Group = struct {
    label: []const u8,
};

pub const groups = [_]Group{
    .{ .label = "Compositors" },
    .{ .label = "Terminals" },
    .{ .label = "Toolkits" },
    .{ .label = "Editors and TUI" },
    .{ .label = "Browsers" },
    .{ .label = "Chat, games and media" },
    .{ .label = "Event Horizon" },
};

pub const group_count = groups.len;

/// How "is this application installed" is answered. One arm per distinct
/// gate predicate in `color/apply.zig` `gateTableWith`.
pub const Check = enum {
    /// No gate — the template always applies (GTK CSS, the GTK colors, the
    /// KDE scheme, the otter-term conf, the Ptyxis palette).
    always,
    /// `$HYPRLAND_INSTANCE_SIGNATURE` set in the session (`hyprSig`).
    hypr_sig,
    /// One binary on `PATH` (`exeOnPath`).
    bin,
    /// `vesktopFull`: vesktop on `PATH` **and** `$CONFIG_DIR/vesktop`.
    vesktop,
    /// A directory under `$CONFIG_DIR` (`dirEquibop`, `dirZed`, `dirEh`,
    /// `dirHcal`).
    cfg_dir,
    /// `dirZen`: `$HOME/.zen`.
    home_dir,
    /// `dirSteam`: `$HOME/.steam` or `$HOME/.local/share/Steam`.
    home_dir_either,
    /// `vscodeOk`: code/codium/cursor on `PATH`, or one of the editor
    /// config dirs under `$CONFIG_DIR`.
    vscode,
    /// `obsFull`: obs or obs-studio on `PATH`, or the Flatpak config dir
    /// `$HOME/.var/app/com.obsproject.Studio/config/obs-studio`.
    obs,
    /// `heroicFull`: heroic or `com.heroicgameslauncher.hgl` on `PATH`, or
    /// `$CONFIG_DIR/heroic`.
    heroic,
    /// `fluxerFull`: fluxer-canary or fluxer on `PATH`, or
    /// `$CONFIG_DIR/fluxercanary` or `$CONFIG_DIR/fluxer`.
    fluxer,
    /// `owlerFull`: owler on `PATH` or `$CONFIG_DIR/owler`.
    owler,
};

/// One external template.
pub const Config = struct {
    label: []const u8,
    /// Group index into `groups`.
    group: u8,
    /// Index into `Settings.matugen_templates` — also the
    /// `fields.Field.matugen_tpl_N` number, so the page reaches the toggle
    /// both through the array and through `setBool`.
    slot: u8,
    /// Source file inside the bundle's `matugen/templates/`, shown in the
    /// row's detail panel. "built-in (native)" for the packs the color
    /// engine writes without a template file.
    input: []const u8,
    /// Output the apply path writes, in the bundle tokens the merged config
    /// uses (`CONFIG_DIR`, `HOME_DIR`, …). Status checks resolve this
    /// against the env and stat the file's mtime. When a template renders
    /// several outputs this is the first one.
    output: []const u8,
    /// Second destination for the same template when its app ships in a
    /// Flatpak sandbox (OBS). Selected by `activeOutput` when `alt_root`
    /// exists.
    output_alt: []const u8 = "",
    /// Token path whose existence selects `output_alt` — the Flatpak app's
    /// sandbox root.
    alt_root: []const u8 = "",
    /// Post-apply hook command, when the template runs one.
    hook: []const u8 = "",
    check: Check,
    /// The binary a `.bin` gate probes on `PATH`.
    bin: []const u8 = "",
    /// Directory relative to `$CONFIG_DIR` (`.vesktop`, `.cfg_dir`).
    cfg_dir: []const u8 = "",
    /// Directory relative to `$HOME` (`.home_dir`, `.home_dir_either`).
    home_dir: []const u8 = "",
    /// Second candidate for `.home_dir_either` (Steam's data dir).
    home_dir2: []const u8 = "",

    /// The name the detail panel quotes when a row is off-system
    /// ("no kitty on PATH").
    pub fn probeName(self: *const Config) []const u8 {
        return if (self.bin.len > 0) self.bin else self.label;
    }
};

// ---------------------------------------------------------------------------
// The 37 templates. Order = the old tile order = the
// `Settings.matugen_templates` layout; `appearance_persist` maps the array
// to `appearance.toml` by name, so a permutation here would silently
// retarget other rows' toggles — the tests below pin every slot.
//
// Groups (7): 0 compositors, 1 terminals, 2 toolkits, 3 editors and TUI,
// 4 browsers, 5 chat/games/media, 6 Event Horizon. Group order follows the
// mockup roster; rows inside each group keep tile order.
// ---------------------------------------------------------------------------

pub const templates = [_]Config{
    // --- Compositors ---------------------------------------------------------
    .{ .label = "Niri", .group = 0, .slot = 0, .input = "niri-colors.kdl", .output = "CONFIG_DIR/niri/eh/colors.kdl", .check = .bin, .bin = "niri" },
    .{ .label = "Hyprland", .group = 0, .slot = 1, .input = "hypr-colors.conf", .output = "CONFIG_DIR/hypr/eh/colors.conf", .check = .hypr_sig },
    .{ .label = "Mango", .group = 0, .slot = 2, .input = "mango-colors.conf", .output = "CONFIG_DIR/mango/hyprmango/colors.matugen.conf", .hook = "mmsg -d reload_config", .check = .bin, .bin = "mmsg" },
    // --- Terminals -----------------------------------------------------------
    .{ .label = "Kitty theme", .group = 1, .slot = 9, .input = "kitty.conf", .output = "CONFIG_DIR/kitty/event-theme.conf", .check = .bin, .bin = "kitty" },
    .{ .label = "Kitty tabs", .group = 1, .slot = 10, .input = "kitty-tabs.conf", .output = "CONFIG_DIR/kitty/event-tabs.conf", .check = .bin, .bin = "kitty" },
    .{ .label = "Ghostty", .group = 1, .slot = 11, .input = "ghostty.conf", .output = "CONFIG_DIR/ghostty/themes/eventcolors", .check = .bin, .bin = "ghostty" },
    .{ .label = "WezTerm", .group = 1, .slot = 12, .input = "wezterm.toml", .output = "CONFIG_DIR/wezterm/colors/event.toml", .check = .bin, .bin = "wezterm" },
    .{ .label = "Alacritty", .group = 1, .slot = 13, .input = "alacritty.toml", .output = "CONFIG_DIR/alacritty/event-theme.toml", .check = .bin, .bin = "alacritty" },
    .{ .label = "Foot", .group = 1, .slot = 14, .input = "foot.ini", .output = "CONFIG_DIR/foot/event-colors.ini", .check = .bin, .bin = "foot" },
    .{ .label = "Otter term", .group = 1, .slot = 15, .input = "otter-term-matugen.conf", .output = "CONFIG_DIR/otter-shell/otter-term-matugen.conf", .check = .always },
    .{ .label = "Ptyxis", .group = 1, .slot = 29, .input = "ptyxis.palette", .output = "DATA_DIR/org.gnome.Ptyxis/palettes/Event-Horizon.palette", .check = .always },
    // --- Toolkits ------------------------------------------------------------
    .{ .label = "GTK shell CSS", .group = 2, .slot = 3, .input = "gtk.css", .output = "CONFIG_DIR/gtk-4.0/gtk.css", .check = .always },
    .{ .label = "GTK colors (light)", .group = 2, .slot = 4, .input = "gtk-colors.css", .output = "CONFIG_DIR/gtk-3.0/event-colors.css", .check = .always },
    .{ .label = "GTK colors (dark)", .group = 2, .slot = 5, .input = "gtk-colors.css", .output = "CONFIG_DIR/gtk-3.0/event-colors.css", .check = .always },
    .{ .label = "KDE colors", .group = 2, .slot = 6, .input = "kcolorscheme.colors", .output = "DATA_DIR/color-schemes/EventMatugen.colors", .check = .always },
    .{ .label = "Qt5ct", .group = 2, .slot = 7, .input = "qtct-colors.conf", .output = "CONFIG_DIR/qt5ct/colors/matugen.conf", .check = .bin, .bin = "qt5ct" },
    .{ .label = "Qt6ct", .group = 2, .slot = 8, .input = "qtct-colors.conf", .output = "CONFIG_DIR/qt6ct/colors/matugen.conf", .check = .bin, .bin = "qt6ct" },
    // --- Editors and TUI -------------------------------------------------------
    .{ .label = "btop", .group = 3, .slot = 16, .input = "btop.theme", .output = "CONFIG_DIR/btop/themes/eh-matugen.theme", .check = .bin, .bin = "btop" },
    .{ .label = "Neovim", .group = 3, .slot = 17, .input = "neovim.lua", .output = "CONFIG_DIR/nvim/colors/eh.lua", .check = .bin, .bin = "nvim" },
    .{ .label = "VS Code material", .group = 3, .slot = 18, .input = "vscode.json", .output = "VSCODE_USER_DIR/material-code-colors.matugen.json", .check = .vscode },
    .{ .label = "VS Code themes", .group = 3, .slot = 19, .input = "vscode-eh-dark.json", .output = "VSCODE_EXT_EH_THEMES_DIR/matugen-eh-dark.json", .check = .vscode },
    .{ .label = "dgop", .group = 3, .slot = 26, .input = "dgop.json", .output = "CONFIG_DIR/dgop/colors.json", .check = .bin, .bin = "dgop" },
    .{ .label = "Emacs", .group = 3, .slot = 27, .input = "event-emacs.el", .output = "EMACS_DIR/themes/event-emacs-theme.el", .check = .bin, .bin = "emacs" },
    .{ .label = "Zed", .group = 3, .slot = 28, .input = "event-zed.json", .output = "CONFIG_DIR/zed/themes/event-zed-theme.json", .check = .cfg_dir, .cfg_dir = "zed" },
    // --- Browsers --------------------------------------------------------------
    .{ .label = "Firefox", .group = 4, .slot = 20, .input = "firefox-userchrome.css", .output = "CONFIG_DIR/EventHorizon/firefox.css", .check = .bin, .bin = "firefox" },
    .{ .label = "Zen", .group = 4, .slot = 21, .input = "zen-userchrome.css", .output = "CONFIG_DIR/EventHorizon/zen-userchrome.css", .check = .home_dir, .home_dir = ".zen" },
    .{ .label = "PyWalFox", .group = 4, .slot = 24, .input = "pywalfox-colors.json", .output = "CACHE_DIR/wal/event-pywalfox.json", .hook = "pywalfox update", .check = .bin, .bin = "pywalfox" },
    // --- Chat, games and media ---------------------------------------------------
    .{ .label = "Vesktop", .group = 5, .slot = 22, .input = "vesktop.css", .output = "HOME_DIR/.config/vesktop/themes/midnight.theme.css", .check = .vesktop, .cfg_dir = "vesktop" },
    .{ .label = "Equibop", .group = 5, .slot = 23, .input = "vesktop.css", .output = "CONFIG_DIR/equibop/themes/event-discord.css", .check = .cfg_dir, .cfg_dir = "equibop" },
    .{ .label = "Steam", .group = 5, .slot = 25, .input = "steam.css", .output = "HOME_DIR/.config/steam/matugen-colors.css", .check = .home_dir_either, .home_dir = ".steam", .home_dir2 = ".local/share/Steam" },
    .{ .label = "OBS Studio", .group = 5, .slot = 31, .input = "obs.obt", .output = "HOME_DIR/.config/obs-studio/themes/event-horizon.obt", .output_alt = "HOME_DIR/.var/app/com.obsproject.Studio/config/obs-studio/themes/event-horizon.obt", .alt_root = "HOME_DIR/.var/app/com.obsproject.Studio", .check = .obs },
    .{ .label = "Heroic", .group = 5, .slot = 32, .input = "heroic.css", .output = "HOME_DIR/.config/heroic/themes/event-horizon.css", .check = .heroic },
    .{ .label = "Fluxer", .group = 5, .slot = 35, .input = "fluxer.css", .output = "CONFIG_DIR/fluxer/themes/event-horizon.css", .check = .fluxer },
    .{ .label = "Owler", .group = 5, .slot = 36, .input = "built-in (native pack)", .output = "CONFIG_DIR/owler/themes/matugen.json", .check = .owler },
    // --- Event Horizon -----------------------------------------------------------
    .{ .label = "Horizon Files", .group = 6, .slot = 30, .input = "horizon-files-matugen.conf", .output = "CONFIG_DIR/event-horizon/horizon-files-matugen.conf", .check = .cfg_dir, .cfg_dir = "event-horizon" },
    .{ .label = "Horizon Photo", .group = 6, .slot = 33, .input = "horizon-photo-matugen.conf", .output = "CONFIG_DIR/event-horizon/horizon-photo-matugen.conf", .check = .cfg_dir, .cfg_dir = "event-horizon" },
    .{ .label = "Horizon Calendar", .group = 6, .slot = 34, .input = "horizon-calendar-matugen.conf", .output = "CONFIG_DIR/event-horizon/horizon-calendar-matugen.conf", .check = .cfg_dir, .cfg_dir = "horizon-calendar" },
};

pub const template_count = templates.len;

/// The entry owning a `Settings.matugen_templates` slot. The page hits this
/// for every toggle write; `slot` values are unique (pinned by the tests).
pub fn bySlot(slot: usize) *const Config {
    for (&templates) |*tpl| {
        if (tpl.slot == slot) return tpl;
    }
    unreachable;
}

comptime {
    if (template_count != 37) @compileError("templates_registry: the external template table must list all 37 matugen toggles");
}

// ---------------------------------------------------------------------------
// Probes — the filesystem/environment seams the page fills in.
// ---------------------------------------------------------------------------

pub const Probes = struct {
    ctx: ?*anyopaque = null,
    /// Environment variable as the session exposes it (`""` = unset). The
    /// name arrives as a Zig slice; the implementation null-terminates.
    envFn: *const fn (?*anyopaque, name: []const u8) []const u8,
    /// Binary reachable through `PATH` (the production probe scans `PATH`
    /// and probes each candidate with X_OK).
    binFn: *const fn (?*anyopaque, name: []const u8) bool,
    /// Path exists (file or directory).
    pathFn: *const fn (?*anyopaque, path: []const u8) bool,
    /// File mtime in seconds; 0 when absent — drives "Applied 2m ago".
    mtimeFn: *const fn (?*anyopaque, path: []const u8) i64,
};

/// The gate answer for one template under `env`. Mirrors the predicates in
/// `color/apply.zig` `gateTableWith` — binary probes go through `binFn`
/// (which owns the PATH scan), directories are composed from `env` and
/// answered through `pathFn`.
pub fn detected(probes: Probes, t: *const Config, env: Env) bool {
    return switch (t.check) {
        .always => true,
        .hypr_sig => probes.envFn(probes.ctx, "HYPRLAND_INSTANCE_SIGNATURE").len > 0,
        .bin => probes.binFn(probes.ctx, t.bin),
        .vesktop => probes.binFn(probes.ctx, "vesktop") and
            dirUnder(probes, env.cfg_main, t.cfg_dir),
        .cfg_dir => dirUnder(probes, env.cfg_main, t.cfg_dir),
        .home_dir => dirUnder(probes, env.home, t.home_dir),
        .home_dir_either => dirUnder(probes, env.home, t.home_dir) or
            dirUnder(probes, env.home, t.home_dir2),
        .vscode => blk: {
            for ([_][]const u8{ "code", "codium", "cursor" }) |b| {
                if (probes.binFn(probes.ctx, b)) break :blk true;
            }
            for ([_][]const u8{ "Code", "Cursor", "VSCodium", "Code - OSS", "Code - Insiders" }) |d| {
                if (dirUnder(probes, env.cfg_main, d)) break :blk true;
            }
            break :blk false;
        },
        .obs => blk: {
            if (probes.binFn(probes.ctx, "obs") or probes.binFn(probes.ctx, "obs-studio")) break :blk true;
            break :blk dirUnder(probes, env.home, ".var/app/com.obsproject.Studio/config/obs-studio");
        },
        .heroic => blk: {
            if (probes.binFn(probes.ctx, "heroic") or probes.binFn(probes.ctx, "com.heroicgameslauncher.hgl")) break :blk true;
            break :blk dirUnder(probes, env.cfg_main, "heroic");
        },
        .fluxer => blk: {
            if (probes.binFn(probes.ctx, "fluxer-canary") or probes.binFn(probes.ctx, "fluxer")) break :blk true;
            break :blk dirUnder(probes, env.cfg_main, "fluxercanary") or
                dirUnder(probes, env.cfg_main, "fluxer");
        },
        .owler => probes.binFn(probes.ctx, "owler") or dirUnder(probes, env.cfg_main, "owler"),
    };
}

fn dirUnder(probes: Probes, base: []const u8, rel: []const u8) bool {
    if (base.len == 0 or rel.len == 0) return false;
    var buf: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ base, rel }) catch return false;
    return probes.pathFn(probes.ctx, p);
}

// ---------------------------------------------------------------------------
// Environment — `$HOME`, `$XDG_CONFIG_HOME` and the two VS Code paths the
// apply path computes (`vscodeUserDir` / `vscodeMarketplaceDir`).
// ---------------------------------------------------------------------------

pub const Env = struct {
    home: []const u8 = "",
    cfg_main: []const u8 = "",
    /// `VSCODE_USER_DIR` — the editor's …/User config directory.
    vscode_user: []const u8 = "",
    /// `VSCODE_EXT_EH_THEMES_DIR` — `<marketplace>/eh-matugen-themes`.
    vscode_ext: []const u8 = "",
};

/// Backing storage `fillEnv` writes its slices into. 4 × 512 B is far above
/// any real path set; embedding keeps the page allocation-free.
pub const EnvBufs = struct {
    home: [512]u8 = undefined,
    cfg: [512]u8 = undefined,
    vscode_user: [512]u8 = undefined,
    vscode_ext: [512]u8 = undefined,
    n_home: usize = 0,
    n_cfg: usize = 0,
    n_vscode_user: usize = 0,
    n_vscode_ext: usize = 0,

    pub fn env(self: *const EnvBufs) Env {
        return .{
            .home = self.home[0..self.n_home],
            .cfg_main = self.cfg[0..self.n_cfg],
            .vscode_user = self.vscode_user[0..self.n_vscode_user],
            .vscode_ext = self.vscode_ext[0..self.n_vscode_ext],
        };
    }
};

/// Resolve the env strings once per detection pass. `vscodeUserDir`'s
/// preference order is ported: exe+dir pairs first, then dir-only, then
/// exe-only, then the `Code` default.
pub fn fillEnv(probes: Probes, bufs: *EnvBufs) Env {
    const home = probes.envFn(probes.ctx, "HOME");
    if (home.len == 0) return .{};
    bufs.n_home = copyInto(&bufs.home, home);

    var cfg = probes.envFn(probes.ctx, "XDG_CONFIG_HOME");
    if (cfg.len == 0) {
        const fb = std.fmt.bufPrint(&bufs.cfg, "{s}/.config", .{home}) catch return .{};
        bufs.n_cfg = fb.len;
    } else {
        bufs.n_cfg = copyInto(&bufs.cfg, cfg);
    }
    cfg = bufs.cfg[0..bufs.n_cfg];

    // exe+dir pairs first (vscodeUserDir's preferred matches)…
    var user_dir: ?[]const u8 = null;
    const pairs = [_]struct { bin: []const u8, dir: []const u8 }{
        .{ .bin = "cursor", .dir = "Cursor" },
        .{ .bin = "code", .dir = "Code" },
        .{ .bin = "codium", .dir = "VSCodium" },
    };
    for (pairs) |pr| {
        if (probes.binFn(probes.ctx, pr.bin) and dirUnder(probes, cfg, pr.dir)) {
            user_dir = std.fmt.bufPrint(&bufs.vscode_user, "{s}/{s}/User", .{ cfg, pr.dir }) catch null;
            if (user_dir != null) break;
        }
    }
    // …then a bare config dir (Cursor, Code, VSCodium, Code - OSS,
    // Code - Insiders)…
    if (user_dir == null) {
        for ([_][]const u8{ "Cursor", "Code", "VSCodium", "Code - OSS", "Code - Insiders" }) |d| {
            if (dirUnder(probes, cfg, d)) {
                user_dir = std.fmt.bufPrint(&bufs.vscode_user, "{s}/{s}/User", .{ cfg, d }) catch null;
                if (user_dir != null) break;
            }
        }
    }
    // …then a bare executable naming its expected dir…
    if (user_dir == null) {
        for (pairs) |pr| {
            if (probes.binFn(probes.ctx, pr.bin)) {
                user_dir = std.fmt.bufPrint(&bufs.vscode_user, "{s}/{s}/User", .{ cfg, pr.dir }) catch null;
                if (user_dir != null) break;
            }
        }
    }
    // …and the `Code/User` default the C++ path ends on.
    if (user_dir == null)
        user_dir = std.fmt.bufPrint(&bufs.vscode_user, "{s}/Code/User", .{cfg}) catch "";
    bufs.n_vscode_user = if (user_dir) |u| u.len else 0;
    const vd = bufs.vscode_user[0..bufs.n_vscode_user];

    // The marketplace dir follows the editor the user dir picked
    // (vscodeMarketplaceDir), plus the `eh-matugen-themes` extension folder.
    const ext_base: []const u8 = if (std.mem.indexOf(u8, vd, "/Cursor/") != null)
        ".cursor/extensions"
    else if (std.mem.indexOf(u8, vd, "/VSCodium/") != null)
        ".vscode-oss/extensions"
    else if (std.mem.indexOf(u8, vd, "/Code - Insiders/") != null)
        ".vscode-insiders/extensions"
    else if (std.mem.indexOf(u8, vd, "/Code - OSS/") != null)
        ".vscode-oss/extensions"
    else
        ".vscode/extensions";
    const ext = std.fmt.bufPrint(&bufs.vscode_ext, "{s}/{s}/eh-matugen-themes", .{ home, ext_base }) catch "";
    bufs.n_vscode_ext = ext.len;

    return bufs.env();
}

fn copyInto(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

// ---------------------------------------------------------------------------
// Path resolution — bundle tokens to real filesystem paths.
// ---------------------------------------------------------------------------

/// Resolve one `output` string (the bundle tokens) against `env`. Returns
/// null when the env the token needs is unset (no `$HOME`, no config dir —
/// the status then stays "Not applied yet" rather than guessing).
pub fn resolvePath(buf: []u8, env: Env, output: []const u8) ?[]const u8 {
    if (startsWithToken(output, "CONFIG_DIR")) {
        if (env.cfg_main.len == 0) return null;
        return appendTo(buf, env.cfg_main, output["CONFIG_DIR".len..]);
    }
    if (env.home.len == 0 and !startsWithToken(output, "VSCODE_USER_DIR") and
        !startsWithToken(output, "VSCODE_EXT_EH_THEMES_DIR"))
    {
        return null;
    }
    if (startsWithToken(output, "DATA_DIR"))
        return appendHomeRel(buf, env, ".local/share", output["DATA_DIR".len..]);
    if (startsWithToken(output, "CACHE_DIR"))
        return appendHomeRel(buf, env, ".cache", output["CACHE_DIR".len..]);
    if (startsWithToken(output, "EMACS_DIR"))
        return appendHomeRel(buf, env, ".emacs.d", output["EMACS_DIR".len..]);
    if (startsWithToken(output, "HOME_DIR"))
        return appendTo(buf, env.home, output["HOME_DIR".len..]);
    if (startsWithToken(output, "VSCODE_USER_DIR")) {
        if (env.vscode_user.len == 0) return null;
        return appendTo(buf, env.vscode_user, output["VSCODE_USER_DIR".len..]);
    }
    if (startsWithToken(output, "VSCODE_EXT_EH_THEMES_DIR")) {
        if (env.vscode_ext.len == 0) return null;
        return appendTo(buf, env.vscode_ext, output["VSCODE_EXT_EH_THEMES_DIR".len..]);
    }
    if (output.len > 0 and output[0] == '~')
        return appendTo(buf, env.home, output[1..]);
    return null;
}

fn startsWithToken(s: []const u8, tok: []const u8) bool {
    return s.len > tok.len and std.mem.eql(u8, s[0..tok.len], tok) and s[tok.len] == '/';
}

fn appendTo(buf: []u8, base: []const u8, rel: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ base, rel }) catch null;
}

fn appendHomeRel(buf: []u8, env: Env, fixed: []const u8, rel: []const u8) ?[]const u8 {
    if (env.home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ env.home, fixed, rel }) catch null;
}

/// The path as the page shows it: `$HOME` collapses to `~`, matching the
/// mockup's `~/.config/…` style. Overridden XDG roots stay absolute.
pub fn displayPath(buf: []u8, env: Env, resolved: []const u8) []const u8 {
    if (env.home.len > 0 and resolved.len > env.home.len and
        std.mem.startsWith(u8, resolved, env.home) and resolved[env.home.len] == '/')
    {
        return std.fmt.bufPrint(buf, "~{s}", .{resolved[env.home.len..]}) catch resolved;
    }
    return resolved;
}

/// The destination that is actually live for this template. OBS is the one
/// dual-destination row: a Flatpak install reads inside its sandbox, so the
/// page shows and stats `output_alt` whenever the sandbox tree exists.
/// `buf` holds the resolved path, `root_buf` the sandbox probe.
pub fn activeOutput(
    probes: Probes,
    t: *const Config,
    env: Env,
    buf: []u8,
    root_buf: []u8,
) ?[]const u8 {
    if (t.output_alt.len > 0 and t.alt_root.len > 0) {
        if (resolvePath(root_buf, env, t.alt_root)) |root| {
            if (probes.pathFn(probes.ctx, root)) {
                if (resolvePath(buf, env, t.output_alt)) |alt| return alt;
            }
        }
    }
    return resolvePath(buf, env, t.output);
}

// ---------------------------------------------------------------------------
// Status — the per-row state text the page renders.
// ---------------------------------------------------------------------------

pub const Status = enum {
    /// Toggle off.
    disabled,
    /// Enabled but the gate failed — application not on this system.
    not_detected,
    /// Output file present (mtime valid).
    applied,
    /// Enabled, detected, output not written yet (apply pending / never ran).
    pending,

    pub fn text(buf: []u8, self: Status, mtime_s: i64, now_s: i64) []const u8 {
        return switch (self) {
            .disabled => "Disabled",
            .not_detected => "Not detected",
            .pending => "Not applied yet",
            .applied => relTime(buf, mtime_s, now_s),
        };
    }
};

/// One row's resolved state: status plus, when applied, the mtime the text
/// was built from (the page re-formats relative times as it repaints).
pub const StatusInfo = struct {
    status: Status = .pending,
    mtime: i64 = 0,
};

/// Resolve a row's status: disabled → gate → output mtime.
pub fn statusInfo(probes: Probes, t: *const Config, env: Env, enabled: bool) StatusInfo {
    if (!enabled) return .{ .status = .disabled };
    if (!detected(probes, t, env)) return .{ .status = .not_detected };
    var buf: [4096]u8 = undefined;
    var root_buf: [4096]u8 = undefined;
    const path = activeOutput(probes, t, env, &buf, &root_buf) orelse return .{ .status = .pending };
    const mt = probes.mtimeFn(probes.ctx, path);
    if (mt <= 0) return .{ .status = .pending };
    return .{ .status = .applied, .mtime = mt };
}

/// "just now" / "12s ago" / "2m ago" / "3h ago" / "5d ago" — clock skew
/// collapses to "just now".
pub fn relTime(buf: []u8, mtime_s: i64, now_s: i64) []const u8 {
    const d = now_s - mtime_s;
    if (d <= 10) return "just now";
    if (d < 60) return std.fmt.bufPrint(buf, "{d}s ago", .{d}) catch "just now";
    if (d < 3600) return std.fmt.bufPrint(buf, "{d}m ago", .{@divTrunc(d, 60)}) catch "just now";
    if (d < 86400) return std.fmt.bufPrint(buf, "{d}h ago", .{@divTrunc(d, 3600)}) catch "just now";
    return std.fmt.bufPrint(buf, "{d}d ago", .{@divTrunc(d, 86400)}) catch "just now";
}

// ---------------------------------------------------------------------------
// Filter — the page's status segments.
// ---------------------------------------------------------------------------

pub const Segment = enum { all, enabled, disabled, off_system };

pub fn segmentLabel(s: Segment) []const u8 {
    return switch (s) {
        .all => "All",
        .enabled => "Enabled",
        .disabled => "Disabled",
        .off_system => "Off-system",
    };
}

// ---------------------------------------------------------------------------
// Fixtures + tests
// ---------------------------------------------------------------------------

const Fixture = struct {
    vars: []const [2][]const u8 = &.{},
    bins: []const []const u8 = &.{},
    paths: []const []const u8 = &.{},
    mtime: i64 = 8888,

    fn has(varr: []const [2][]const u8, name: []const u8) ?[]const u8 {
        for (varr) |kv| if (std.mem.eql(u8, kv[0], name)) return kv[1];
        return null;
    }

    fn probes(self: *const Fixture) Probes {
        return .{
            .ctx = @constCast(@ptrCast(self)),
            .envFn = fxEnv,
            .binFn = fxBin,
            .pathFn = fxPath,
            .mtimeFn = fxMtime,
        };
    }
};

fn fxEnv(ctx: ?*anyopaque, name: []const u8) []const u8 {
    const f: *const Fixture = @ptrCast(@alignCast(ctx.?));
    return Fixture.has(f.vars, name) orelse "";
}

fn fxBin(ctx: ?*anyopaque, name: []const u8) bool {
    const f: *const Fixture = @ptrCast(@alignCast(ctx.?));
    for (f.bins) |b| if (std.mem.eql(u8, b, name)) return true;
    return false;
}

fn fxPath(ctx: ?*anyopaque, path: []const u8) bool {
    const f: *const Fixture = @ptrCast(@alignCast(ctx.?));
    for (f.paths) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}

fn fxMtime(ctx: ?*anyopaque, path: []const u8) i64 {
    const f: *const Fixture = @ptrCast(@alignCast(ctx.?));
    for (f.paths) |p| if (std.mem.eql(u8, p, path)) return f.mtime;
    return 0;
}

test "registry: 37 templates, unique slots, groups in range" {
    const t = std.testing;
    var seen = @as([37]bool, @splat(false));
    for (templates) |tpl| {
        try t.expect(tpl.slot < 37);
        try t.expect(!seen[tpl.slot]);
        seen[tpl.slot] = true;
        try t.expect(tpl.group < group_count);
        try t.expect(tpl.label.len > 0);
        try t.expect(tpl.input.len > 0);
        try t.expect(tpl.output.len > 0);
    }
    for (seen) |s| try t.expect(s);
}

test "registry: roster order and groups match the old tile order" {
    const t = std.testing;
    // Tile order → slot: niri 0, hyprland 1, mango 2, … owler 36 (the
    // horizon_files 30 / photo 33 / calendar 34 / obs 31 / heroic 32 cluster
    // is the appearance_persist workaround order).
    try t.expectEqualStrings("Niri", templates[0].label);
    try t.expectEqualStrings("Hyprland", templates[1].label);
    try t.expectEqualStrings("Mango", templates[2].label);
    // Slots stay the old tile-enum order (the roster array itself is
    // group-ordered, so slots — the settings indexes — are what's pinned).
    try t.expectEqualStrings("Steam", bySlot(25).label);
    try t.expectEqualStrings("Horizon Files", bySlot(30).label);
    try t.expectEqualStrings("OBS Studio", bySlot(31).label);
    try t.expectEqualStrings("Heroic", bySlot(32).label);
    try t.expectEqualStrings("Horizon Photo", bySlot(33).label);
    try t.expectEqualStrings("Horizon Calendar", bySlot(34).label);
    try t.expectEqualStrings("Fluxer", bySlot(35).label);
    try t.expectEqualStrings("Owler", bySlot(36).label);
    // The first group is the compositors, as the mockup roster starts.
    for (templates[0..3]) |tpl| try t.expectEqual(@as(u8, 0), tpl.group);
    // Every group holds at least one template.
    var counts = @as([group_count]usize, @splat(0));
    for (templates) |tpl| counts[tpl.group] += 1;
    for (counts) |c| try t.expect(c > 0);
}

const fx_home = "/fx/home";
const fx_cfg = "/fx/cfg";

const fx_base = Fixture{
    .vars = &.{ .{ "HOME", fx_home }, .{ "XDG_CONFIG_HOME", fx_cfg } },
};

fn envOf(f: *const Fixture, bufs: *EnvBufs) Env {
    return fillEnv(f.probes(), bufs);
}

test "registry: detection mirrors the apply gate table" {
    const t = std.testing;
    var bufs: EnvBufs = .{};
    const env = envOf(&fx_base, &bufs);
    try t.expectEqualStrings(fx_home, env.home);
    try t.expectEqualStrings(fx_cfg, env.cfg_main);
    const st = struct {
        fn s(slot: usize) *const Config {
            return bySlot(slot);
        }
    }.s;

    // No bins, no paths: the always-nothing baseline.
    const none = fx_base.probes();
    try t.expect(!detected(none, st(0), env)); // niri: bin
    try t.expect(!detected(none, st(1), env)); // hypr: sig
    try t.expect(detected(none, st(3), env)); // gtk shell css: always
    try t.expect(!detected(none, st(22), env)); // vesktop (22): bin AND dir
    try t.expect(!detected(none, st(25), env)); // steam (25): .steam

    // One config dir flips the passives.
    const with_dirs = Fixture{
        .vars = &.{ .{ "HOME", fx_home }, .{ "XDG_CONFIG_HOME", fx_cfg } },
        .paths = &.{ fx_cfg ++ "/vesktop", fx_cfg ++ "/equibop", fx_cfg ++ "/zed", fx_home ++ "/.zen", fx_home ++ "/.steam", fx_cfg ++ "/event-horizon", fx_cfg ++ "/horizon-calendar" },
    };
    const dp = with_dirs.probes();
    try t.expect(!detected(dp, st(22), env)); // vesktop (22) still needs the binary
    try t.expect(detected(dp, st(23), env)); // equibop (23): cfg dir
    try t.expect(detected(dp, st(28), env)); // zed: cfg dir
    try t.expect(detected(dp, st(21), env)); // zen: ~/.zen
    try t.expect(detected(dp, st(25), env)); // steam: ~/.steam
    try t.expect(detected(dp, st(30), env)); // horizon files
    try t.expect(detected(dp, st(34), env)); // horizon calendar
    try t.expect(!detected(dp, st(36), env)); // owler: bin or cfg

    // Hyprland via the session variable.
    const hypr = Fixture{ .vars = &.{ .{ "HOME", fx_home }, .{ "XDG_CONFIG_HOME", fx_cfg }, .{ "HYPRLAND_INSTANCE_SIGNATURE", "s1" } } };
    try t.expect(detected(hypr.probes(), st(1), env));

    // Steam's data dir alternative.
    const steam2 = Fixture{
        .vars = &.{ .{ "HOME", fx_home }, .{ "XDG_CONFIG_HOME", fx_cfg } },
        .paths = &.{fx_home ++ "/.local/share/Steam"},
    };
    try t.expect(detected(steam2.probes(), st(25), env));

    // Vesktop: binary and dir together.
    const vesktop = Fixture{
        .vars = &.{ .{ "HOME", fx_home }, .{ "XDG_CONFIG_HOME", fx_cfg } },
        .bins = &.{"vesktop"},
        .paths = &.{fx_cfg ++ "/vesktop"},
    };
    try t.expect(detected(vesktop.probes(), st(22), env));

    // vscode: editor dir under CONFIG_DIR.
    const vsc = Fixture{
        .vars = &.{ .{ "HOME", fx_home }, .{ "XDG_CONFIG_HOME", fx_cfg } },
        .paths = &.{fx_cfg ++ "/Code"},
    };
    try t.expect(detected(vsc.probes(), st(18), env));

    // obs via the Flatpak config dir; owler via its config dir.
    const misc = Fixture{
        .vars = &.{ .{ "HOME", fx_home }, .{ "XDG_CONFIG_HOME", fx_cfg } },
        .paths = &.{ fx_home ++ "/.var/app/com.obsproject.Studio/config/obs-studio", fx_cfg ++ "/owler" },
    };
    try t.expect(detected(misc.probes(), st(31), env));
    try t.expect(detected(misc.probes(), st(36), env));

    // fluxer: binary names or the canary config dir.
    const flux = Fixture{
        .vars = &.{ .{ "HOME", fx_home }, .{ "XDG_CONFIG_HOME", fx_cfg } },
        .bins = &.{"fluxer-canary"},
    };
    try t.expect(detected(flux.probes(), st(35), env));
    const flux_dir = Fixture{
        .vars = &.{ .{ "HOME", fx_home }, .{ "XDG_CONFIG_HOME", fx_cfg } },
        .paths = &.{fx_cfg ++ "/fluxercanary"},
    };
    try t.expect(detected(flux_dir.probes(), st(35), env));
}

test "registry: fillEnv resolves XDG and the vscode dirs" {
    const t = std.testing;
    var bufs: EnvBufs = .{};
    // XDG unset → $HOME/.config, and every derived path follows that root.
    const fx1 = Fixture{ .vars = &.{.{ "HOME", fx_home }} };
    const env1 = envOf(&fx1, &bufs);
    try t.expectEqualStrings(fx_home ++ "/.config", env1.cfg_main);
    // No editor dirs → the Code/User default; marketplace home/.vscode.
    try t.expectEqualStrings(fx_home ++ "/.config/Code/User", env1.vscode_user);
    try t.expectEqualStrings(fx_home ++ "/.vscode/extensions/eh-matugen-themes", env1.vscode_ext);

    // Cursor dir wins and reroutes the marketplace.
    const fx2 = Fixture{
        .vars = &.{ .{ "HOME", fx_home }, .{ "XDG_CONFIG_HOME", fx_cfg } },
        .paths = &.{fx_cfg ++ "/Cursor"},
    };
    const env2 = envOf(&fx2, &bufs);
    try t.expectEqualStrings(fx_cfg ++ "/Cursor/User", env2.vscode_user);
    try t.expectEqualStrings(fx_home ++ "/.cursor/extensions/eh-matugen-themes", env2.vscode_ext);

    // exe-only install (cursor on PATH, no dir yet).
    const fx3 = Fixture{
        .vars = &.{ .{ "HOME", fx_home }, .{ "XDG_CONFIG_HOME", fx_cfg } },
        .bins = &.{"cursor"},
    };
    const env3 = envOf(&fx3, &bufs);
    try t.expectEqualStrings(fx_cfg ++ "/Cursor/User", env3.vscode_user);

    // No $HOME → empty env.
    const fx4 = Fixture{};
    try t.expect(envOf(&fx4, &bufs).home.len == 0);
}

test "registry: resolvePath handles every token" {
    const t = std.testing;
    const env = Env{
        .home = "/h",
        .cfg_main = "/c",
        .vscode_user = "/c/Code/User",
        .vscode_ext = "/h/.vscode/extensions/eh-matugen-themes",
    };
    var buf: [512]u8 = undefined;
    try t.expectEqualStrings("/c/hypr/eh/colors.conf", resolvePath(&buf, env, "CONFIG_DIR/hypr/eh/colors.conf").?);
    try t.expectEqualStrings("/h/.local/share/color-schemes/EventMatugen.colors", resolvePath(&buf, env, "DATA_DIR/color-schemes/EventMatugen.colors").?);
    try t.expectEqualStrings("/h/.cache/wal/event-pywalfox.json", resolvePath(&buf, env, "CACHE_DIR/wal/event-pywalfox.json").?);
    try t.expectEqualStrings("/h/.emacs.d/themes/event-emacs-theme.el", resolvePath(&buf, env, "EMACS_DIR/themes/event-emacs-theme.el").?);
    try t.expectEqualStrings("/h/.config/steam/matugen-colors.css", resolvePath(&buf, env, "HOME_DIR/.config/steam/matugen-colors.css").?);
    try t.expectEqualStrings("/h/.config/steam/matugen-colors.css", resolvePath(&buf, env, "~/.config/steam/matugen-colors.css").?);
    try t.expectEqualStrings("/c/Code/User/material-code-colors.matugen.json", resolvePath(&buf, env, "VSCODE_USER_DIR/material-code-colors.matugen.json").?);
    try t.expectEqualStrings("/h/.vscode/extensions/eh-matugen-themes/matugen-eh-dark.json", resolvePath(&buf, env, "VSCODE_EXT_EH_THEMES_DIR/matugen-eh-dark.json").?);
    // Missing env pieces answer null, never a crash.
    try t.expect(resolvePath(&buf, .{}, "CONFIG_DIR/x") == null);
    try t.expect(resolvePath(&buf, .{ .home = "/h" }, "VSCODE_USER_DIR/x") == null);
    try t.expect(resolvePath(&buf, .{ .home = "/h" }, "VSCODE_EXT_EH_THEMES_DIR/x") == null);
}

test "registry: every template's output resolves against a plain env" {
    // Catches typo'd tokens: all 37 outputs must resolve (or stay null only
    // when the env piece is genuinely absent — with a full env none may).
    const env = Env{
        .home = "/h",
        .cfg_main = "/c",
        .vscode_user = "/c/Code/User",
        .vscode_ext = "/h/.vs/extensions/eh",
    };
    var buf: [512]u8 = undefined;
    for (&templates) |*tpl| {
        const got = resolvePath(&buf, env, tpl.output);
        try std.testing.expect(got != null);
    }
}

test "registry: displayPath collapses the home prefix" {
    const t = std.testing;
    const env = Env{ .home = "/home/u", .cfg_main = "/home/u/.config" };
    var resolved: [512]u8 = undefined;
    var shown: [512]u8 = undefined;
    const r = resolvePath(&resolved, env, "CONFIG_DIR/niri/eh/colors.kdl").?;
    try t.expectEqualStrings("~/.config/niri/eh/colors.kdl", displayPath(&shown, env, r));
    // Unrelated roots stay absolute.
    try t.expectEqualStrings("/opt/other/thing", displayPath(&shown, env, "/opt/other/thing"));
}

test "registry: status buckets" {
    const t = std.testing;
    var bufs: EnvBufs = .{};
    const env = envOf(&fx_base, &bufs);
    var sb: [64]u8 = undefined;

    // Disabled wins before anything else.
    try t.expectEqual(Status.disabled, statusInfo(fx_base.probes(), &templates[0], env, false).status);
    try t.expectEqualStrings("Disabled", Status.text(&sb, .disabled, 0, 0));

    // Enabled + no gate → not detected.
    try t.expectEqual(Status.not_detected, statusInfo(fx_base.probes(), &templates[0], env, true).status);
    try t.expectEqualStrings("Not detected", Status.text(&sb, .not_detected, 0, 0));

    // Enabled + detected (always-on) + output present → applied.
    const applied = Fixture{
        .vars = &.{ .{ "HOME", fx_home }, .{ "XDG_CONFIG_HOME", fx_cfg } },
        .paths = &.{fx_cfg ++ "/gtk-4.0/gtk.css"},
        .mtime = 3600 * 100,
    };
    const si = statusInfo(applied.probes(), bySlot(3), env, true);
    try t.expectEqual(Status.applied, si.status);
    try t.expectEqualStrings("40s ago", Status.text(&sb, .applied, si.mtime, si.mtime + 40));
    try t.expectEqualStrings("2m ago", Status.text(&sb, .applied, si.mtime, si.mtime + 125));
    try t.expectEqualStrings("3h ago", Status.text(&sb, .applied, si.mtime, si.mtime + 11000));
    try t.expectEqualStrings("5d ago", Status.text(&sb, .applied, si.mtime, si.mtime + 500000));
    try t.expectEqualStrings("just now", Status.text(&sb, .applied, si.mtime, si.mtime + 3));
    // Clock skew stays friendly.
    try t.expectEqualStrings("just now", relTime(&sb, si.mtime, si.mtime - 10));

    // Enabled + detected + missing output → pending.
    try t.expectEqual(Status.pending, statusInfo(fx_base.probes(), bySlot(3), env, true).status);
    try t.expectEqualStrings("Not applied yet", Status.text(&sb, .pending, 0, 0));
}

test "registry: OBS follows the Flatpak sandbox when it exists" {
    const t = std.testing;
    var bufs: EnvBufs = .{};
    const env = envOf(&fx_base, &bufs);
    const obs = bySlot(31);
    var buf: [512]u8 = undefined;
    var root: [512]u8 = undefined;

    // Native install: the ~/.config destination is the live one.
    const native = activeOutput(fx_base.probes(), obs, env, &buf, &root).?;
    try t.expectEqualStrings("/fx/home/.config/obs-studio/themes/event-horizon.obt", native);

    // Flatpak sandbox present: the output moves inside ~/.var/app.
    const flatpak = Fixture{
        .vars = fx_base.vars,
        .paths = &.{"/fx/home/.var/app/com.obsproject.Studio"},
    };
    const out = activeOutput(flatpak.probes(), obs, env, &buf, &root).?;
    try t.expectEqualStrings("/fx/home/.var/app/com.obsproject.Studio/config/obs-studio/themes/event-horizon.obt", out);

    // Status stats the live destination: the sandbox output's mtime applies
    // even when the native file is absent.
    const applied = Fixture{
        .vars = fx_base.vars,
        .paths = &.{
            "/fx/home/.var/app/com.obsproject.Studio",
            "/fx/home/.var/app/com.obsproject.Studio/config/obs-studio",
            "/fx/home/.var/app/com.obsproject.Studio/config/obs-studio/themes/event-horizon.obt",
        },
        .mtime = 5000,
    };
    const si = statusInfo(applied.probes(), obs, env, true);
    try t.expectEqual(Status.applied, si.status);
    try t.expectEqual(@as(i64, 5000), si.mtime);
}

test "registry: segment labels" {
    const t = std.testing;
    try t.expectEqualStrings("All", segmentLabel(.all));
    try t.expectEqualStrings("Enabled", segmentLabel(.enabled));
    try t.expectEqualStrings("Disabled", segmentLabel(.disabled));
    try t.expectEqualStrings("Off-system", segmentLabel(.off_system));
}
