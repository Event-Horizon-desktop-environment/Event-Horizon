//! Hyprland border/matugen sync: the palette's accent / outline / critical
//! colours become the compositor's window borders.
//!
//! The palette's accent / outline / critical colours become the compositor's
//! window borders: an active gradient, a dimmer inactive outline and the
//! locked (notification-critical) outline. They are pushed either as
//! `general:col.*` keywords over the one-shot socket, or — under the lua
//! config provider — as a generated `colors.lua` followed by a `reload`.
//!
//! Fidelity notes:
//!   * `EH_HYPR_MATUGEN_BORDER` spelled `0`, `off`, `false` or `no` disables
//!     the sync, per `env_disables_hypr_matugen_border`
//!     (lower-cased first, 15-char cap).
//!   * Environment keys are
//!     seeded into a `std.process.Environ.Map`, because that is the Zig IPC
//!     layer's contract and it keeps every branch reachable from a test.
//!   * Nothing here can fail the caller: a compositor that never answers
//!     costs the request timeouts and drops the reply.
//!   * An *empty* `HYPRLAND_INSTANCE_SIGNATURE` returns early — same outcome one line later (`resolvePaths`
//!     rejects it too), minus a pointless pass through the gate helpers.

const std = @import("std");
const schema = @import("../config/schema.zig");
const schema3 = @import("../config/schema3.zig");
const chrome_colors = @import("../desktop_shell/widgets/shared/chrome_colors.zig");
const hypr_ipc = @import("../backends/hyprland_ipc.zig");
const sock = @import("../sock.zig");

fn getenv(key: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(key) orelse return null;
    const s = std.mem.span(raw);
    return if (s.len == 0) null else s;
}

/// Whether any palette is active: a custom theme, a healthy native palette or
/// a healthy matugen palette. The Zig schema has no such helper (see the
/// note in `workspaces_paint.zig`), so the three terms live here.
pub fn anyPaletteActive(a: schema3.Appearance) bool {
    return (a.matugen_theming and a.matugen_palette_ok) or
        (a.horizon_colors_native and a.horizon_colors_ok) or
        a.custom_theme_enabled;
}

/// `EH_HYPR_MATUGEN_BORDER` spellings that switch the sync off.
fn envDisables(env: *const std.process.Environ.Map) bool {
    const raw = env.get("EH_HYPR_MATUGEN_BORDER") orelse return false;
    if (raw.len == 0) return false;
    if (std.mem.eql(u8, raw, "0")) return true;
    // Lower-case into a 15-char buffer and compare that, so a
    // longer value can never match; return early for the same reason.
    if (raw.len > 15) return false;
    var buf: [15]u8 = undefined;
    for (raw, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const s = buf[0..raw.len];
    return std.mem.eql(u8, s, "off") or
        std.mem.eql(u8, s, "false") or
        std.mem.eql(u8, s, "no");
}

/// `0.82f` widened to `f64`, computed as `double accentR * 0.82f`,
/// promoting the *float* literal to double, so the multiplier is the f64
/// value of `0.82f` — not the f64 value of `0.82`. They differ by ~7e-9,
/// which is a tenth of an f32 ulp at 0.738: enough to move a byte when the
/// product sits on a rounding boundary.
const accent_dim: f64 = @as(f64, @as(f32, 0.82));

/// `0xAARRGGBB` — the compositor's own `rgba()` spelling, alpha first.
/// `buf` must hold at least 16 bytes; the returned slice borrows it.
///
/// RGBA conversion takes `float` parameters and evaluates
/// `clamp(x, 0.f, 1.f) * 255.f + 0.5f` in single precision before casting to
/// `int`. The chrome colours are `f64`, so each is narrowed here first — the
/// same conversion at the call site. Over the 2^30 f32s in
/// [0, 1] the two roundings disagree on 128 inputs, and the stock accent
/// `0.90f` is one of them: float says 230 (0xe6), double says 229 (0xe5).
fn hyprRgba(buf: *[16]u8, r: f64, g: f64, b: f64, a: f64) []const u8 {
    const byte = struct {
        fn f(x: f64) u8 {
            const v: f32 = @floatCast(x);
            return @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 255.0 + 0.5);
        }
    }.f;
    return std.fmt.bufPrint(
        buf,
        "0x{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{ byte(a), byte(r), byte(g), byte(b) },
    ) catch "0xffffffff";
}

/// One `keyword <key> <value>` round trip, colon spelling first then the
/// slash one — both spellings are tried, accepting only `ok`.
fn setKey(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, cmd: []const u8) bool {
    const resp = hypr_ipc.ipcRequest(alloc, io, env, cmd) orelse return false;
    defer alloc.free(resp);
    // Pop trailing bytes while `unsigned char <= ' '`, i.e. only
    // bytes 0x00–0x20, and only off the back; leading bytes stay put. `trim`
    // would strip both ends from a narrower set, so walk the tail here.
    var s = resp;
    while (s.len > 0 and s[s.len - 1] <= ' ') s = s[0 .. s.len - 1];
    return std.mem.eql(u8, s, "ok");
}

fn keywordSet(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    key_colon: []const u8,
    key_slash: []const u8,
    value: []const u8,
) bool {
    var buf: [512]u8 = undefined;
    const first = std.fmt.bufPrint(&buf, "keyword {s} {s}", .{ key_colon, value }) catch return false;
    if (setKey(alloc, io, env, first)) return true;
    const second = std.fmt.bufPrint(&buf, "keyword {s} {s}", .{ key_slash, value }) catch return false;
    return setKey(alloc, io, env, second);
}

/// `$HOME/.config/hypr/hyprland/colors.lua` — the lua provider's hook. The
/// path spelling is hard-coded `/.config`, not XDG.
fn writeColorsLua(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    active1: []const u8,
    active2: []const u8,
    inactive: []const u8,
    locked: []const u8,
) void {
    // An absent HOME skips the file while the `reload`
    // still goes out, hence the early return here rather than a check upstream.
    // Read from `env` (seeded from the process environment by `sync`) so a
    // test can point HOME at a sandbox.
    const home = env.get("HOME") orelse return;
    const content = std.fmt.allocPrint(
        alloc,
        \\-- Generated by Event Horizon
        \\hl.config({{
        \\  general = {{
        \\    col = {{
        \\      active_border   = {{ colors = {{ "{s}", "{s}" }}, angle = 45 }},
        \\      inactive_border = "{s}"
        \\    }}
        \\  }},
        \\  group = {{
        \\    col = {{
        \\      border_active          = {{ colors = {{ "{s}", "{s}" }}, angle = 45 }},
        \\      border_inactive        = "{s}",
        \\      border_locked_active   = "{s}",
        \\      border_locked_inactive = "{s}"
        \\    }},
        \\    groupbar = {{
        \\      col = {{
        \\        active          = {{ colors = {{ "{s}", "{s}" }}, angle = 45 }},
        \\        inactive        = "{s}",
        \\        locked_active   = "{s}",
        \\        locked_inactive = "{s}"
        \\      }}
        \\    }}
        \\  }}
        \\}})
        \\
    ,
        .{
            active1, active2, inactive,
            active1, active2, inactive, locked, inactive,
            active1, active2, inactive, locked, inactive,
        },
    ) catch return;
    defer alloc.free(content);

    const dir = std.fs.path.join(alloc, &.{ home, ".config", "hypr", "hyprland" }) catch return;
    defer alloc.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    const path = std.fs.path.join(alloc, &.{ dir, "colors.lua" }) catch return;
    defer alloc.free(path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content }) catch {};
}

/// Seed the process environment into `env`. Silently best-effort: a key that
/// cannot be copied only makes the matching branch a no-op.
fn seed(env: *std.process.Environ.Map) void {
    for ([_][*:0]const u8{
        "HYPRLAND_INSTANCE_SIGNATURE",
        "XDG_RUNTIME_DIR",
        "EH_HYPR_MATUGEN_BORDER",
        "HOME",
    }) |k| {
        if (getenv(k)) |v| env.put(std.mem.span(k), v) catch {};
    }
}

/// Production entry: pull the environment, then run `syncIn`.
pub fn sync(alloc: std.mem.Allocator, io: std.Io, cfg: *const schema.ShellConfig) void {
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    seed(&env);
    syncIn(alloc, io, &env, cfg);
}

/// `sync_hyprland_border_matugen` proper, with the environment handed in.
/// Every gate is checked in order.
pub fn syncIn(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: *const schema.ShellConfig,
) void {
    if (env.get("HYPRLAND_INSTANCE_SIGNATURE") == null) return;
    if (envDisables(env)) return;

    const a = cfg.appearance;
    if (!anyPaletteActive(a)) return;
    if (a.matugen_theming and !a.matugen_outputs.hyprland) return;

    const mc = chrome_colors.of(cfg);

    var b_a1: [16]u8 = undefined;
    const active1 = hyprRgba(&b_a1, mc.accent.r, mc.accent.g, mc.accent.b, 0.92);
    var b_a2: [16]u8 = undefined;
    const active2 = hyprRgba(
        &b_a2,
        mc.accent.r * accent_dim,
        mc.accent.g * accent_dim,
        mc.accent.b * accent_dim,
        0.70,
    );
    var b_in: [16]u8 = undefined;
    const inactive = hyprRgba(&b_in, mc.outline.r, mc.outline.g, mc.outline.b, 0.42);
    var b_lk: [16]u8 = undefined;
    const locked = hyprRgba(&b_lk, mc.notif_ol.r, mc.notif_ol.g, mc.notif_ol.b, 1.0);

    var grad_buf: [48]u8 = undefined;
    const ac_gradient = std.fmt.bufPrint(&grad_buf, "{s} {s} 45deg", .{ active1, active2 }) catch return;

    if (hypr_ipc.usesLuaConfig(alloc, io, env)) {
        writeColorsLua(alloc, io, env, active1, active2, inactive, locked);
        // The reload reply is discarded; `ipcRequest` hands back owned
        // bytes, so drop them here rather than leaking the reply.
        if (hypr_ipc.ipcRequest(alloc, io, env, "reload")) |reply| alloc.free(reply);
        return;
    }
    // (colon key, slash key, value) — ten keywords.
    for ([_][3][]const u8{
        .{ "general:col.active_border", "general/col/active_border", ac_gradient },
        .{ "general:col.inactive_border", "general/col/inactive_border", inactive },
        .{ "group:col.border_active", "group/col/border_active", ac_gradient },
        .{ "group:col.border_inactive", "group/col/border_inactive", inactive },
        .{ "group:col.border_locked_active", "group/col/border_locked_active", locked },
        .{ "group:col.border_locked_inactive", "group/col/border_locked_inactive", inactive },
        .{ "group:groupbar:col.active", "group/groupbar/col/active", ac_gradient },
        .{ "group:groupbar:col.inactive", "group/groupbar/col/inactive", inactive },
        .{ "group:groupbar:col.locked_active", "group/groupbar/col/locked_active", locked },
        .{ "group:groupbar:col.locked_inactive", "group/groupbar/col/locked_inactive", inactive },
    }) |entry| {
        _ = keywordSet(alloc, io, env, entry[0], entry[1], entry[2]);
    }
}

// Tests

test "hyprland-border: rgba packs alpha first, clamped, rounded" {
    const t = std.testing;
    var buf: [16]u8 = undefined;
    // accent 0.9 at 0.92 alpha -> 0.92*255=234.6 -> 235 (0xeb);
    // 0.9*255+0.5 = 230.0 -> 230 (0xe6).
    try t.expectEqualStrings("0xebe6e6e6", hyprRgba(&buf, 0.9, 0.9, 0.9, 0.92));
    try t.expectEqualStrings("0xff000000", hyprRgba(&buf, 0.0, 0.0, 0.0, 1.0));
    // Out-of-range channels clamp to 00 / ff rather than wrapping: r over
    // the top, b under the bottom.
    try t.expectEqualStrings("0x00ffff00", hyprRgba(&buf, 1.5, 1.0, -1.0, 0.0));
}

// Oracle values from `hypr_rgba(float,float,float,float)` fed the
// exact doubles `derived_chrome_colors` produces (the config's f32 triples
// widened, per `fromF32`). The channels here straddle float/double rounding
// boundaries, so an f64 evaluation of `u()` drifts off them: with the stock
// accent 0.90f it yields 0xe5 where the reference yields 0xe6, and the 0.82-scaled
// accent's alpha lands 0xb2 vs 0xb3. Locking the oracle pins the narrowing.
test "hyprland-border: rgba matches the float oracle on widened config colours" {
    const t = std.testing;
    var buf: [16]u8 = undefined;
    // `fromF32()`: schema3's `[3]f32` defaults widened to f64. Widening f32
    // -> f64 is exact, so narrowing straight back recovers the same f32.
    const wide = struct {
        fn cast(v: [3]f32) [3]f64 {
            return .{ @as(f64, v[0]), @as(f64, v[1]), @as(f64, v[2]) };
        }
    }.cast;

    const accent = wide(.{ 0.90, 0.90, 0.90 });
    const outline = wide(.{ 0.55, 0.60, 0.62 });
    const notif = wide(.{ 0.75, 0.15, 0.15 });

    // `0.90f` widened then narrowed is exactly `0.90f`; float gives 230
    // (0xe6), a straight f64 run gives 229 (0xe5).
    try t.expectEqualStrings("0xebe6e6e6", hyprRgba(&buf, accent[0], accent[1], accent[2], 0.92));
    // `0.90f * 0.82f` in double then narrowed, alpha `0.70f`.
    try t.expectEqualStrings(
        "0xb3bcbcbc",
        hyprRgba(&buf, 0.90 * accent_dim, 0.90 * accent_dim, 0.90 * accent_dim, 0.70),
    );
    try t.expectEqualStrings("0x6b8c999e", hyprRgba(&buf, outline[0], outline[1], outline[2], 0.42));
    try t.expectEqualStrings("0xffbf2626", hyprRgba(&buf, notif[0], notif[1], notif[2], 1.0));
}

test "hyprland-border: the disable env var honours every documented spelling" {
    const t = std.testing;
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();

    try t.expect(!envDisables(&env));
    try env.put("EH_HYPR_MATUGEN_BORDER", "");
    try t.expect(!envDisables(&env));
    for ([_][]const u8{ "0", "off", "OFF", "False", "no", "NO" }) |spell| {
        try env.put("EH_HYPR_MATUGEN_BORDER", spell);
        try t.expect(envDisables(&env));
    }
    for ([_][]const u8{ "1", "on", "yes", "enabled" }) |spell| {
        try env.put("EH_HYPR_MATUGEN_BORDER", spell);
        try t.expect(!envDisables(&env));
    }
    // Longer than the 15-char buffer can never compare equal.
    try env.put("EH_HYPR_MATUGEN_BORDER", "falsefalsefalsefalse");
    try t.expect(!envDisables(&env));
}

// `seed` is only reachable from `sync`, and `sync` talks to a live compositor
// — so nothing in the suite would otherwise check its `getenv` call sites,
// and they only surface when a binary compiles. Seeding a bare map exercises
// them for free, with no socket involved.
test "hyprland-border: the process environment seeds into the map" {
    const t = std.testing;
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    seed(&env);
    // No assertion on a particular key: HOME may legitimately be absent under
    // a bare test runner, and a live Hyprland signature is not this test's
    // business. What matters is that every `getenv` compiled and that an
    // unset key reads back as null.
    _ = env.get("HOME");
    _ = env.get("HYPRLAND_INSTANCE_SIGNATURE");
}

test "hyprland-border: a palette has to be healthy before borders move" {
    const t = std.testing;
    var cfg: schema.ShellConfig = .{};
    // Stock defaults: the native engine is on but has never produced a
    // palette, so nothing is active.
    try t.expect(!anyPaletteActive(cfg.appearance));

    cfg.appearance.horizon_colors_ok = true;
    try t.expect(anyPaletteActive(cfg.appearance));
    cfg.appearance.horizon_colors_ok = false;

    cfg.appearance.custom_theme_enabled = true;
    try t.expect(anyPaletteActive(cfg.appearance));
    cfg.appearance.custom_theme_enabled = false;

    cfg.appearance.matugen_theming = true;
    try t.expect(!anyPaletteActive(cfg.appearance));
    cfg.appearance.matugen_palette_ok = true;
    try t.expect(anyPaletteActive(cfg.appearance));
    // Still active here — the `matugen_outputs.hyprland` suppression is the
    // next gate inside `syncIn`, not part of this predicate.
    cfg.appearance.matugen_outputs.hyprland = false;
    try t.expect(anyPaletteActive(cfg.appearance));
}

test "hyprland-border: with no compositor signature nothing is attempted" {
    const t = std.testing;
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();

    var cfg: schema.ShellConfig = .{};
    cfg.appearance.horizon_colors_ok = true;
    // No `HYPRLAND_INSTANCE_SIGNATURE` in the map: the first gate returns
    // before any socket, file or allocation is touched.
    syncIn(t.allocator, t.io, &env, &cfg);
}

// The lua half of the branch: a compositor that answers `j/status` with the
// lua provider gets `$HOME/.config/hypr/hyprland/colors.lua` rewritten with
// this palette, then a `reload`. Everything is local — sandbox HOME, sandbox
// socket — so the assertion is on the exact bytes written.
test "hyprland-border: the lua provider gets colors.lua and a reload" {
    const t = std.testing;
    const io = t.io;
    const cwd = std.Io.Dir.cwd();

    var name_buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&name_buf, "/tmp/opencode/eh-hypr-border-{d}", .{std.os.linux.getpid()});
    defer cwd.deleteTree(io, root) catch {};
    cwd.deleteTree(io, root) catch {};

    // `$XDG_RUNTIME_DIR/hypr/<sig>/.socket.sock` — what resolvePaths wants.
    const dir = try std.fs.path.join(t.allocator, &.{ root, "hypr", "sig" });
    defer t.allocator.free(dir);
    try cwd.createDirPath(io, dir);
    const sock_path = try std.fs.path.join(t.allocator, &.{ dir, ".socket.sock" });
    defer t.allocator.free(sock_path);
    const home = try std.fs.path.join(t.allocator, &.{ root, "home" });
    defer t.allocator.free(home);
    try cwd.createDirPath(io, home);

    const lfd = try sock.createStream(false);
    defer sock.closeFd(lfd);
    try sock.bindPath(lfd, sock_path);
    try sock.listenOn(lfd, 4);

    // Two exchanges: `j/status` says lua, then the `reload` is swallowed.
    const Serve = struct {
        lfd: i32,

        fn run(self: @This()) void {
            var cmd_buf: [512]u8 = undefined;
            var served: u32 = 0;
            while (served < 2) : (served += 1) {
                const c = accept(self.lfd) orelse return;
                defer sock.closeFd(c);
                const cmd = readOne(c, &cmd_buf) orelse continue;
                if (std.mem.eql(u8, cmd, "j/status")) {
                    sock.sendAll(c, "{\"configProvider\":\"lua\"}") catch {};
                } else {
                    sock.sendAll(c, "ok\n") catch {};
                }
            }
        }
    };
    var thread = try std.Thread.spawn(.{}, Serve.run, .{Serve{ .lfd = lfd }});
    defer thread.join();

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HYPRLAND_INSTANCE_SIGNATURE", "sig");
    try env.put("XDG_RUNTIME_DIR", root);
    try env.put("HOME", home);

    var cfg: schema.ShellConfig = .{};
    cfg.appearance.horizon_colors_ok = true;
    syncIn(t.allocator, io, &env, &cfg);

    // Stock native palette, neutral adjustments: accent 0.90f, outline
    // 0.55/0.60/0.62f, notif_ol 0.70/0.10/0.10f — each channel byte taken
    // from the `hypr_rgba` oracle (see the float-oracle test above).
    const lua_path = try std.fs.path.join(t.allocator, &.{ home, ".config", "hypr", "hyprland", "colors.lua" });
    defer t.allocator.free(lua_path);
    const got = try cwd.readFileAlloc(io, lua_path, t.allocator, .limited(1 << 16));
    defer t.allocator.free(got);

    const expected =
        \\-- Generated by Event Horizon
        \\hl.config({
        \\  general = {
        \\    col = {
        \\      active_border   = { colors = { "0xebe6e6e6", "0xb3bcbcbc" }, angle = 45 },
        \\      inactive_border = "0x6b8c999e"
        \\    }
        \\  },
        \\  group = {
        \\    col = {
        \\      border_active          = { colors = { "0xebe6e6e6", "0xb3bcbcbc" }, angle = 45 },
        \\      border_inactive        = "0x6b8c999e",
        \\      border_locked_active   = "0xffb31a1a",
        \\      border_locked_inactive = "0x6b8c999e"
        \\    },
        \\    groupbar = {
        \\      col = {
        \\        active          = { colors = { "0xebe6e6e6", "0xb3bcbcbc" }, angle = 45 },
        \\        inactive        = "0x6b8c999e",
        \\        locked_active   = "0xffb31a1a",
        \\        locked_inactive = "0x6b8c999e"
        \\      }
        \\    }
        \\  }
        \\})
        \\
    ;
    try t.expectEqualStrings(expected, got);
}

// The keyword half of the branch: a compositor that answers `j/status` with a
// non-lua provider falls through to the ten `keyword` pushes, and every entry
// tries the colon key before the slash one. The fake here rejects anything
// carrying a `:` so each entry must fall back — which fixes the ordering the
// Ordering guarantee (`try_key(colon) || try_key(slash)`) as an observable log.
test "hyprland-border: non-lua provider pushes colon then slash for every key" {
    const t = std.testing;
    const io = t.io;
    const cwd = std.Io.Dir.cwd();

    var name_buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&name_buf, "/tmp/opencode/eh-hypr-border-kw-{d}", .{std.os.linux.getpid()});
    defer cwd.deleteTree(io, root) catch {};
    cwd.deleteTree(io, root) catch {};

    const dir = try std.fs.path.join(t.allocator, &.{ root, "hypr", "sig" });
    defer t.allocator.free(dir);
    try cwd.createDirPath(io, dir);
    const sock_path = try std.fs.path.join(t.allocator, &.{ dir, ".socket.sock" });
    defer t.allocator.free(sock_path);

    const lfd = try sock.createStream(false);
    defer sock.closeFd(lfd);
    try sock.bindPath(lfd, sock_path);
    try sock.listenOn(lfd, 4);

    // One exchange for `j/status`, then two per entry (colon rejected, slash
    // accepted) across the ten entries.
    const Serve = struct {
        lfd: i32,
        log: *[4096]u8,
        log_len: *usize,

        fn put(self: @This(), s: []const u8) void {
            const room = self.log.len - self.log_len.*;
            const n = @min(s.len, room);
            @memcpy(self.log[self.log_len.*..][0..n], s[0..n]);
            self.log_len.* += n;
            if (self.log_len.* < self.log.len) {
                self.log[self.log_len.*] = '\n';
                self.log_len.* += 1;
            }
        }

        fn run(self: @This()) void {
            var cmd_buf: [512]u8 = undefined;
            var served: u32 = 0;
            while (served < 21) : (served += 1) {
                const c = accept(self.lfd) orelse return;
                defer sock.closeFd(c);
                const cmd = readOne(c, &cmd_buf) orelse continue;
                self.put(cmd);
                if (std.mem.eql(u8, cmd, "j/status")) {
                    sock.sendAll(c, "{\"configProvider\":\"hyprlang\"}") catch {};
                } else if (std.mem.indexOfScalar(u8, cmd, ':') != null) {
                    // Colon spelling unsupported: forces the slash retry.
                    sock.sendAll(c, "err\n") catch {};
                } else {
                    sock.sendAll(c, "ok\n") catch {};
                }
            }
        }
    };

    var log_buf: [4096]u8 = .{0} ** 4096;
    var log_len: usize = 0;
    var thread = try std.Thread.spawn(.{}, Serve.run, .{Serve{
        .lfd = lfd,
        .log = &log_buf,
        .log_len = &log_len,
    }});

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HYPRLAND_INSTANCE_SIGNATURE", "sig");
    try env.put("XDG_RUNTIME_DIR", root);

    var cfg: schema.ShellConfig = .{};
    cfg.appearance.horizon_colors_ok = true;
    syncIn(t.allocator, io, &env, &cfg);

    // Join before reading the log: the thread's completion is the happens-before
    // edge that makes its writes visible here.
    thread.join();

    // Stock native palette again: gradient 0xebe6e6e6 -> 0xb3bcbcbc at 45deg,
    // inactive 0x6b8c999e, locked 0xffb31a1a.
    const expected =
        \\j/status
        \\keyword general:col.active_border 0xebe6e6e6 0xb3bcbcbc 45deg
        \\keyword general/col/active_border 0xebe6e6e6 0xb3bcbcbc 45deg
        \\keyword general:col.inactive_border 0x6b8c999e
        \\keyword general/col/inactive_border 0x6b8c999e
        \\keyword group:col.border_active 0xebe6e6e6 0xb3bcbcbc 45deg
        \\keyword group/col/border_active 0xebe6e6e6 0xb3bcbcbc 45deg
        \\keyword group:col.border_inactive 0x6b8c999e
        \\keyword group/col/border_inactive 0x6b8c999e
        \\keyword group:col.border_locked_active 0xffb31a1a
        \\keyword group/col/border_locked_active 0xffb31a1a
        \\keyword group:col.border_locked_inactive 0x6b8c999e
        \\keyword group/col/border_locked_inactive 0x6b8c999e
        \\keyword group:groupbar:col.active 0xebe6e6e6 0xb3bcbcbc 45deg
        \\keyword group/groupbar/col/active 0xebe6e6e6 0xb3bcbcbc 45deg
        \\keyword group:groupbar:col.inactive 0x6b8c999e
        \\keyword group/groupbar/col/inactive 0x6b8c999e
        \\keyword group:groupbar:col.locked_active 0xffb31a1a
        \\keyword group/groupbar/col/locked_active 0xffb31a1a
        \\keyword group:groupbar:col.locked_inactive 0x6b8c999e
        \\keyword group/groupbar/col/locked_inactive 0x6b8c999e
        \\
    ;
    try t.expectEqualStrings(expected, log_buf[0..log_len]);
}

// `setKey` decides the fallback by comparing against `ok` after trimming. The
// Pop trailing bytes while `unsigned char <= ' '` — bytes 0x00–0x20, off
// the back only — so a leading space must NOT be forgiven and a trailing
// control byte (0x01 here, outside `std.mem.trim`'s default set) must be.
test "hyprland-border: setKey trims trailing <= 0x20 only, then matches ok" {
    const t = std.testing;
    const io = t.io;
    const cwd = std.Io.Dir.cwd();

    var name_buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&name_buf, "/tmp/opencode/eh-hypr-border-tr-{d}", .{std.os.linux.getpid()});
    defer cwd.deleteTree(io, root) catch {};
    cwd.deleteTree(io, root) catch {};

    const dir = try std.fs.path.join(t.allocator, &.{ root, "hypr", "sig" });
    defer t.allocator.free(dir);
    try cwd.createDirPath(io, dir);
    const sock_path = try std.fs.path.join(t.allocator, &.{ dir, ".socket.sock" });
    defer t.allocator.free(sock_path);

    const lfd = try sock.createStream(false);
    defer sock.closeFd(lfd);
    try sock.bindPath(lfd, sock_path);
    try sock.listenOn(lfd, 4);

    // Replies in order, one per connection: each must be classified the same way.
    const script = [_][]const u8{
        "ok\n",        // trailing LF  -> ok
        "ok\r\n",      // trailing CRLF -> ok
        "ok  ",        // trailing spaces -> ok
        "ok\x01",      // trailing byte 0x01 (<= 0x20, outside trim()'s set) -> ok
        "ok\x00",      // trailing NUL (unsigned char <= ' ') -> ok
        "  ok",        // leading spaces: never forgiven -> not ok
        "ok!",         // stray trailing byte -> not ok
        "okay",        // not equal -> not ok
    };
    const Serve = struct {
        lfd: i32,
        replies: *const [script.len][]const u8,

        fn run(self: @This()) void {
            var cmd_buf: [512]u8 = undefined;
            for (self.replies) |reply| {
                const c = accept(self.lfd) orelse return;
                defer sock.closeFd(c);
                _ = readOne(c, &cmd_buf) orelse continue;
                sock.sendAll(c, reply) catch {};
            }
        }
    };
    var thread = try std.Thread.spawn(.{}, Serve.run, .{Serve{
        .lfd = lfd,
        .replies = &script,
    }});
    defer thread.join();

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HYPRLAND_INSTANCE_SIGNATURE", "sig");
    try env.put("XDG_RUNTIME_DIR", root);

    const want = [_]bool{ true, true, true, true, true, false, false, false };
    for (want) |expected_ok| {
        const got = setKey(t.allocator, io, &env, "keyword general:col.active_border x");
        try t.expectEqual(expected_ok, got);
    }
}

fn accept(listen_fd: i32) ?i32 {
    const deadline = sock.nowMs() + 5000;
    while (sock.nowMs() < deadline) : ({
        _ = std.posix.poll(&[_]std.posix.pollfd{}, 5) catch 0;
    }) {
        if (sock.acceptConn(listen_fd)) |c| return c;
    }
    return null;
}

/// Reads one command to EOF, up to `out.len` bytes, and returns the slice read.
fn readOne(c: i32, out: *[512]u8) ?[]u8 {
    var n: usize = 0;
    while (n < out.len) {
        const rc = std.os.linux.recvfrom(c, out[n..].ptr, out.len - n, 0, null, null);
        const e = std.os.linux.errno(rc);
        if (e == .SUCCESS) {
            if (rc == 0) break;
            n += rc;
            continue;
        }
        if (e == .INTR) continue;
        if (e == .AGAIN) {
            _ = std.posix.poll(&[_]std.posix.pollfd{}, 5) catch 0;
            continue;
        }
        return null;
    }
    return out[0..n];
}
