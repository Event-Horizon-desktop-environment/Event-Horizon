//! The config-load palette pass — post-overlay block: refresh
//! the wallpaper-derived palette into `cfg.appearance`, render the native
//! templates, then push the border colours into Hyprland.
//!
//! Why this file exists: `config.loadStacked` only decodes TOML, and the
//! palette fields on `ShellAppearance` are runtime-only (written
//! to `state-settings.toml` for *other* apps but never reads them back, so
//! the decoder does not either). Until something runs the refresh *after* the
//! load, `horizon_colors_ok` / `matugen_palette_ok` stay false for the whole
//! process and every surface reading `derived_chrome_colors` through
//! `chrome_colors.of` — the dock, the control center, pear, every widget
//! popup, and the overview's tiles — paints the stock defaults forever.
//! That was the entire gap: the engine was ported, just never called.
//!
//! Fidelity notes:
//!   * This runs inside the load, and again asynchronously
//!     when the wallpaper moves. Here it is an
//!     explicit `run` after each `loadStacked`, so config tests can decode
//!     without scheduling a palette pass over the real home directory.
//!   * The two side-effecting halves — template renders and the compositor
//!     border IPC — sit behind an input fingerprint: the settings app
//!     rewrites TOML on every slider move and the file watcher reloads on
//!     each of them, so without it a single drag would re-render every
//!     template and fire ~20 compositor requests. It also closes the loop
//!     guarded with a load generation: renders
//!     that land inside the watched config dir would otherwise re-trigger
//!     their own reload forever, whereas a second pass with an unchanged
//!     fingerprint writes nothing at all.
//!   * The palette itself is re-applied unconditionally: `loadStacked`
//!     hands back a freshly decoded config whose palette fields are back at
//!     their defaults, so a cache hit still has to be copied in.
//!   * Two of the three config-loading processes need different amounts of
//!     it. `bin/app.zig` (dock, wallpaper, and every component it spawns)
//!     runs the whole `run`, because it is the process that publishes —
//!     templates and borders are its job. `bin/overview.zig` runs only
//!     `runPalette`: it is short-lived, opened per key press, and asks the
//!     config for nothing but `chrome_colors.of`, so re-rendering templates
//!     and re-pushing the borders from it would repeat work the dock has
//!     already done. `ux/settings2/window.zig` needs none of it — it never
//!     reads `cfg.appearance`, taking its colours from `common.Theme` via
//!     its own `syncPalette` instead.
//!   * Both template engines run, in the upstream `async_matugen_update`
//!     order: the external-`matugen` runner first, then the native render.
//!     Each half self-gates on its own enable + palette-ok pair, and the
//!     palette refresh fills exactly one engine's set, so normally exactly
//!     one half does work — native by default (`horizon_colors_native`).

const std = @import("std");
const reflection = @import("../compat/reflection.zig");
const refresh = @import("refresh.zig");
const apply_mod = @import("apply.zig");
const hypr_border = @import("hyprland_border.zig");
const schema = @import("../config/schema.zig");
const schema3 = @import("../config/schema3.zig");
const logz = @import("../logz.zig");

pub const Sync = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// Owned: `engine.SeedCache` stores this slice rather than copying it.
    state_dir: []u8,
    env: apply_mod.Env,
    ref: refresh.Refresher,
    applier: apply_mod.Applier,
    /// Fingerprint of the inputs the last side-effecting pass saw.
    fp: u64 = 0,
    armed: bool = false,
    /// External-`matugen` runner result from the last render pass (log only).
    matugen_ext_ok: bool = false,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) !Sync {
        const state_dir = try refresh.stateDir(alloc);
        errdefer alloc.free(state_dir);
        const env = try apply_mod.defaultEnv(alloc);
        errdefer freeEnv(alloc, env);
        return .{
            .alloc = alloc,
            .io = io,
            .state_dir = state_dir,
            .env = env,
            .ref = refresh.Refresher.init(alloc, io),
            .applier = apply_mod.Applier.init(alloc, io, state_dir),
        };
    }

    pub fn deinit(self: *Sync) void {
        self.applier.deinit();
        self.ref.deinit();
        freeEnv(self.alloc, self.env);
        self.alloc.free(self.state_dir);
        self.state_dir = "";
        self.armed = false;
    }

    /// The whole post-overlay block. Best-effort: every step swallows its
    /// own failure, because a broken wallpaper path must not stop the shell
    /// from starting on a usable (if un-themed) config.
    pub fn run(self: *Sync, cfg: *schema.ShellConfig) void {
        self.applyPalette(cfg);

        const fp = fingerprint(cfg);
        if (self.armed and fp == self.fp) return;
        self.fp = fp;
        self.armed = true;

        const rendered = self.applyTemplates(cfg);
        hypr_border.sync(self.alloc, self.io, cfg);
        logz.log(
            "palette: hc_ok={d} matugen_ok={d} templates={d} ext={d}",
            .{
                @intFromBool(cfg.appearance.horizon_colors_ok),
                @intFromBool(cfg.appearance.matugen_palette_ok),
                rendered,
                @intFromBool(self.matugen_ext_ok),
            },
        );
    }

    /// The palette half alone: refresh into `cfg.appearance` and stop, before
    /// the template renders and the compositor IPC. For a process that only
    /// *consumes* the derived colours rather than publishing them.
    ///
    /// `bin/overview.zig` is the one caller. It is short-lived — spawned per
    /// key press — and asks the config for exactly one thing,
    /// `chrome_colors.of(cfg)`, while the long-lived shell already renders
    /// the templates and pushes the borders when it loads; `run` above
    /// is the full block, and this is its read-side subset.
    pub fn runPalette(self: *Sync, cfg: *schema.ShellConfig) void {
        self.applyPalette(cfg);
    }

    /// `refresh_wallpaper_derived_palette` into the config's own appearance,
    /// then the field copy into appearance.
    fn applyPalette(self: *Sync, cfg: *schema.ShellConfig) void {
        const a = &cfg.appearance;
        const image = apply_mod.normalizeWallpaperPath(self.alloc, self.io, cfg.wallpaper_image) catch return;
        defer self.alloc.free(image);

        // `refresh` fills exactly one set: the native engine when it is on,
        // the external binary's output otherwise.
        var matugen_set = refresh.ChromeSet{};
        var hc_set = refresh.ChromeSet{};
        self.ref.refresh(
            .{
                .matugen_theming = a.matugen_theming,
                .horizon_native = a.horizon_colors_native,
                .scheme = a.matugen_scheme,
                .mode = a.matugen_mode,
            },
            image,
            self.state_dir,
            &matugen_set,
            &hc_set,
        );
        if (a.horizon_colors_native) {
            writeNative(a, &hc_set);
        } else {
            writeMatugen(a, &matugen_set);
        }
    }

    /// Rendered template count (what `Applier.apply` reports back),
    /// a trace-only number. Both halves run, upstream-order: the
    /// external-`matugen` runner first, then the native render; each
    /// self-gates on its own enable + palette-ok pair, so normally exactly
    /// one of them does work. The external result lands in `matugen_ext_ok`
    /// for the log.
    fn applyTemplates(self: *Sync, cfg: *const schema.ShellConfig) usize {
        const inputs = templateInputs(cfg, self.env);
        self.matugen_ext_ok = self.applier.applyExternal(inputs);
        return self.applier.apply(inputs);
    }
};

/// The inputs both template-engine halves read; pure, so the threading of
/// the enable/palette-ok gates and the toggles can be pinned in a test.
fn templateInputs(cfg: *const schema.ShellConfig, env: apply_mod.Env) apply_mod.Applier.Inputs {
    const a = &cfg.appearance;
    return .{
        .wallpaper_image = cfg.wallpaper_image,
        .scheme = a.matugen_scheme,
        .mode = a.matugen_mode,
        .horizon_native = a.horizon_colors_native,
        .horizon_ok = a.horizon_colors_ok,
        .matugen_theming = a.matugen_theming,
        .matugen_palette_ok = a.matugen_palette_ok,
        .toggles = &a.matugen_outputs,
        .env = env,
    };
}

fn freeEnv(alloc: std.mem.Allocator, e: apply_mod.Env) void {
    alloc.free(e.home);
    alloc.free(e.cfg_main);
    alloc.free(e.state_dir);
}

/// Cache-to-appearance copy: all eight groups, then the ok flag — copied
/// unconditionally (the colour fields keep whatever
/// the last good palette left there, and the flag is what gates their use).
fn writeNative(a: *schema3.Appearance, s: *const refresh.ChromeSet) void {
    a.hc_dock_fill = s.dock_fill;
    a.hc_panel_fill = s.panel_fill;
    a.hc_drawer_dim = s.drawer_dim;
    a.hc_outline = s.outline;
    a.hc_accent = s.accent;
    a.hc_text = s.text;
    a.hc_notif_bg = s.notif_bg;
    a.hc_notif_ol = s.notif_ol;
    a.horizon_colors_ok = s.ok;
}

fn writeMatugen(a: *schema3.Appearance, s: *const refresh.ChromeSet) void {
    a.matugen_dock_fill = s.dock_fill;
    a.matugen_panel_fill = s.panel_fill;
    a.matugen_drawer_dim = s.drawer_dim;
    a.matugen_outline = s.outline;
    a.matugen_accent = s.accent;
    a.matugen_text = s.text;
    a.matugen_notif_bg = s.notif_bg;
    a.matugen_notif_ol = s.notif_ol;
    a.matugen_palette_ok = s.ok;
}

/// Everything the template renders and the border IPC read. String fields
/// are NUL-separated so no two spellings can hash alike.
fn fingerprint(cfg: *const schema.ShellConfig) u64 {
    var h = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
    h.update(cfg.wallpaper_image);
    h.update(&[_]u8{0});
    h.update(cfg.appearance.matugen_scheme);
    h.update(&[_]u8{0});
    h.update(cfg.appearance.matugen_mode);
    h.update(&[_]u8{0});
    const a = cfg.appearance;
    h.update(&[_]u8{
        @as(u8, @intFromBool(a.matugen_theming)),
        @as(u8, @intFromBool(a.horizon_colors_native)),
        @as(u8, @intFromBool(a.horizon_colors_ok)),
        @as(u8, @intFromBool(a.matugen_palette_ok)),
        @as(u8, @intFromBool(a.custom_theme_enabled)),
    });
    inline for (reflection.structFields(schema3.MatugenToggles)) |f| {
        if (f.type == bool) {
            h.update(&[_]u8{@as(u8, @intFromBool(@field(a.matugen_outputs, f.name)))});
        }
    }
    return h.final();
}

// Tests

test "palette-sync: the fingerprint tracks every input the renders read" {
    const t = std.testing;
    var cfg: schema.ShellConfig = .{};

    const base = fingerprint(&cfg);
    try t.expect(base == fingerprint(&cfg));

    cfg.wallpaper_image = "/pics/a.png";
    const with_img = fingerprint(&cfg);
    try t.expect(with_img != base);
    try t.expect(with_img == fingerprint(&cfg));

    cfg.appearance.matugen_scheme = "scheme-expressive";
    const with_scheme = fingerprint(&cfg);
    try t.expect(with_scheme != with_img);

    cfg.appearance.matugen_mode = "light";
    const with_mode = fingerprint(&cfg);
    try t.expect(with_mode != with_scheme);

    // A flag the pipeline reads (ok is in the fp: a palette that only just
    // became healthy has to re-render even though nothing else moved).
    cfg.appearance.horizon_colors_ok = true;
    const with_ok = fingerprint(&cfg);
    try t.expect(with_ok != with_mode);

    // One of the 37 output toggles.
    cfg.appearance.matugen_outputs.hyprland = false;
    const with_toggle = fingerprint(&cfg);
    try t.expect(with_toggle != with_ok);

    // Separators matter: "ab"+"c" must not hash like "a"+"bc".
    var x: schema.ShellConfig = .{};
    x.wallpaper_image = "ab";
    x.appearance.matugen_scheme = "c";
    var y: schema.ShellConfig = .{};
    y.wallpaper_image = "a";
    y.appearance.matugen_scheme = "bc";
    try t.expect(fingerprint(&x) != fingerprint(&y));
}

test "palette-sync: template inputs thread both gates and the toggles" {
    const t = std.testing;
    var cfg: schema.ShellConfig = .{};
    cfg.wallpaper_image = "/pics/w.png";
    cfg.appearance.matugen_scheme = "scheme-vibrant";
    cfg.appearance.matugen_mode = "light";
    cfg.appearance.horizon_colors_native = false;
    cfg.appearance.matugen_theming = true;
    cfg.appearance.matugen_palette_ok = true;
    cfg.appearance.matugen_outputs.owler = false;

    const env = apply_mod.Env{ .home = "/home/u", .cfg_main = "/conf", .state_dir = "/state" };
    const in = templateInputs(&cfg, env);

    try t.expectEqualStrings("/pics/w.png", in.wallpaper_image);
    try t.expectEqualStrings("scheme-vibrant", in.scheme);
    try t.expectEqualStrings("light", in.mode);
    try t.expect(!in.horizon_native);
    try t.expect(in.matugen_theming);
    try t.expect(in.matugen_palette_ok);
    // The toggles are borrowed in place, not copied.
    try t.expect(!in.toggles.owler);
    try t.expect(in.toggles.niri);
    try t.expectEqualStrings("/conf", in.env.cfg_main);
}

test "palette-sync: a ChromeSet lands in all eight native groups" {
    const t = std.testing;
    var a: schema3.Appearance = .{};
    a.hc_accent = .{ 0.1, 0.1, 0.1 };
    a.matugen_accent = .{ 0.7, 0.7, 0.7 };

    const s = refresh.ChromeSet{
        .dock_fill = .{ 0.11, 0.12, 0.13 },
        .panel_fill = .{ 0.21, 0.22, 0.23 },
        .drawer_dim = .{ 0.31, 0.32, 0.33 },
        .outline = .{ 0.41, 0.42, 0.43 },
        .accent = .{ 0.51, 0.52, 0.53 },
        .text = .{ 0.61, 0.62, 0.63 },
        .notif_bg = .{ 0.71, 0.72, 0.73 },
        .notif_ol = .{ 0.81, 0.82, 0.83 },
        .ok = true,
    };
    writeNative(&a, &s);

    try t.expect(a.horizon_colors_ok);
    try t.expectApproxEqAbs(@as(f32, 0.11), a.hc_dock_fill[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.23), a.hc_panel_fill[2], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.32), a.hc_drawer_dim[1], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.41), a.hc_outline[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.53), a.hc_accent[2], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.61), a.hc_text[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.72), a.hc_notif_bg[1], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.83), a.hc_notif_ol[2], 1e-6);
    // The matugen half is the other branch's to write.
    try t.expect(!a.matugen_palette_ok);
    try t.expectApproxEqAbs(@as(f32, 0.7), a.matugen_accent[0], 1e-6);
}

test "palette-sync: a failed refresh copies the set and clears ok" {
    const t = std.testing;
    var a: schema3.Appearance = .{};
    a.hc_accent = .{ 0.5, 0.5, 0.5 };
    a.horizon_colors_ok = true;

    // What `refreshNative` hands back when the wallpaper is missing.
    const failed = refresh.ChromeSet{};
    writeNative(&a, &failed);
    try t.expect(!a.horizon_colors_ok);
    // Unconditional copy, like `copy_cache_to_appearance`: the field now
    // holds the set's default rather than the stale accent.
    try t.expectApproxEqAbs(@as(f32, 0.90), a.hc_accent[0], 1e-6);
}

test "palette-sync: matugen writes its own eight groups" {
    const t = std.testing;
    var a: schema3.Appearance = .{};
    a.horizon_colors_ok = true;
    const s = refresh.ChromeSet{
        .dock_fill = .{ 0.9, 0.8, 0.7 },
        .accent = .{ 0.6, 0.5, 0.4 },
        .ok = true,
    };
    writeMatugen(&a, &s);
    try t.expect(a.matugen_palette_ok);
    try t.expectApproxEqAbs(@as(f32, 0.9), a.matugen_dock_fill[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.5), a.matugen_accent[1], 1e-6);
    // The native flag belongs to the other branch.
    try t.expect(a.horizon_colors_ok);
}

test "palette-sync: no wallpaper means no palette and no side effects" {
    const t = std.testing;
    var sync = try Sync.init(t.allocator, t.io);
    defer sync.deinit();

    var cfg: schema.ShellConfig = .{};
    sync.applyPalette(&cfg);
    try t.expect(!cfg.appearance.horizon_colors_ok);
    try t.expect(!cfg.appearance.matugen_palette_ok);
}

test "palette-sync: runPalette resolves the palette and stops there" {
    const t = std.testing;
    var sync = try Sync.init(t.allocator, t.io);
    defer sync.deinit();

    var cfg: schema.ShellConfig = .{};
    // No wallpaper, so the refresh reports a failed palette — but it *did*
    // run, which is the whole point for a reader like the overview: without
    // this its `chrome_colors.of(cfg)` would see the decoded defaults and
    // never learn that the engine had nothing to hand it.
    sync.runPalette(&cfg);
    try t.expect(!cfg.appearance.horizon_colors_ok);

    // And it stopped before the publishing half: the fingerprint is still
    // unarmed, so no template was rendered and no compositor border was
    // pushed — exactly the contract `bin/overview.zig` depends on.
    try t.expect(!sync.armed);
}
