const std = @import("std");

pub const Kind = enum {
    hyprland,
    niri,
    mango,
    sway,
    labwc,
    zoolander,
    unknown,

    /// Environment probes in historical precedence, then the desktop-hint
    /// substrings, then the `dwl` alias. An unset and an empty variable are
    /// both "absent", matching `getenv(...)[0] != '\0'` semantics.
    ///
    /// The hints are checked variable by variable rather than against one
    /// joined `a:b:c` string. No probe contains a `:`, and
    /// `containsFolded` only ever matches within one string, so a match
    /// cannot straddle a separator — the same answers, with no allocation.
    pub fn detectWithMap(env: *const std.process.Environ.Map) Kind {
        // Zoolander strips `HYPRLAND_INSTANCE_SIGNATURE` (and the other
        // foreign-IPC markers) from every process it spawns, so a shell it
        // starts usually has no compositor marker at all. `ZOOLANDER_WSI` is
        // the one variable it does export to those children; the XDG hint and
        // the control-socket probe cover sessions started another way.
        const zoolander_probes = [_][]const u8{
            "ZOOLANDER_WSI",
            "ZOOLANDER_INSTANCE_SIGNATURE",
            "ZOOLANDER_SOCKET",
        };
        for (zoolander_probes) |key| {
            if (env.get(key)) |v| {
                if (v.len != 0) return .zoolander;
            }
        }

        const probes = [_]struct { env_key: []const u8, kind: Kind }{
            .{ .env_key = "HYPRLAND_INSTANCE_SIGNATURE", .kind = .hyprland },
            .{ .env_key = "NIRI_SOCKET", .kind = .niri },
            .{ .env_key = "SWAYSOCK", .kind = .sway },
            .{ .env_key = "LABWC_PID", .kind = .labwc },
            // mango, last of the five: it is the only one of them whose
            // variable names an *instance* rather than a socket.
            .{ .env_key = "MANGO_INSTANCE_SIGNATURE", .kind = .mango },
        };
        for (probes) |p| {
            if (env.get(p.env_key)) |v| {
                if (v.len != 0) return p.kind;
            }
        }

        const hints = [_]struct { text: []const u8, kind: Kind }{
            .{ .text = "niri", .kind = .niri },
            .{ .text = "hypr", .kind = .hyprland },
            .{ .text = "sway", .kind = .sway },
            .{ .text = "mango", .kind = .mango },
            .{ .text = "labwc", .kind = .labwc },
            .{ .text = "zoolander", .kind = .zoolander },
        };
        const vars = [_][]const u8{ "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "DESKTOP_SESSION" };
        // The hint may name both Zoolander and Hyprland; check Zoolander
        // first for the same compatibility reason as the env probes.
        for (hints) |h| {
            if (h.kind != .zoolander) continue;
            for (vars) |v| {
                if (env.get(v)) |value| {
                    if (containsFolded(value, h.text)) return h.kind;
                }
            }
        }
        for (hints) |h| {
            if (h.kind == .zoolander) continue;
            for (vars) |v| {
                if (env.get(v)) |value| {
                    if (containsFolded(value, h.text)) return h.kind;
                }
            }
        }
        // `dwl` is the alias hint that has always mapped onto mango's
        // tag-based backend.
        for (vars) |v| {
            if (env.get(v)) |value| {
                if (containsFolded(value, "dwl")) return .mango;
            }
        }
        return .unknown;
    }

    /// `contains_folded`: a case-insensitive substring search, byte by byte.
    /// `std.ascii.toLower` folds only `A`–`Z`, matching the default-C-locale
    /// behaviour for `unsigned char` input.
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

    pub fn detectFromFlags(hyprland: bool, niri: bool, mango: bool, sway: bool) Kind {
        if (hyprland) return .hyprland;
        if (niri) return .niri;
        if (mango) return .mango;
        if (sway) return .sway;
        return .unknown;
    }
};

/// `$XDG_RUNTIME_DIR/zoolander-<basename WAYLAND_DISPLAY>.sock`, written into
/// `buf`. Zoolander names its control socket after the Wayland socket, so the
/// path is derivable from the environment alone. Null when either variable is
/// missing, empty, or the result does not fit.
pub fn zoolanderControlPath(buf: []u8, env: *const std.process.Environ.Map) ?[]const u8 {
    const rt = env.get("XDG_RUNTIME_DIR") orelse return null;
    const disp = env.get("WAYLAND_DISPLAY") orelse return null;
    if (rt.len == 0 or disp.len == 0) return null;
    const base = std.fs.path.basename(disp);
    if (base.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/zoolander-{s}.sock", .{ rt, base }) catch null;
}

/// Whether the control socket exists. Its presence beside the Wayland socket
/// is the definitive Zoolander signal when no marker or hint is set.
pub fn zoolanderSocketPresent(io: std.Io, env: *const std.process.Environ.Map) bool {
    var buf: [256]u8 = undefined;
    const path = zoolanderControlPath(&buf, env) orelse return false;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .unix_domain_socket;
}

/// Full detection: environment first, then the control-socket probe. Callers
/// with an `io` should prefer this over `detectWithMap`, so a Zoolander session
/// started without any marker (the common case) still resolves.
pub fn detect(io: std.Io, env: *const std.process.Environ.Map) Kind {
    const k = Kind.detectWithMap(env);
    if (k != .unknown) return k;
    if (zoolanderSocketPresent(io, env)) return .zoolander;
    return .unknown;
}

pub const Capabilities = struct {
    workspaces: bool = false,
    toplevel_tracking: bool = false,
    output_config: bool = false,
};

pub fn capabilitiesFor(kind: Kind) Capabilities {
    return switch (kind) {
        .hyprland => .{ .workspaces = true, .toplevel_tracking = true, .output_config = true },
        .niri => .{ .workspaces = true, .toplevel_tracking = true, .output_config = false },
        .mango => .{ .workspaces = true, .toplevel_tracking = true, .output_config = false },
        .sway => .{ .workspaces = true, .toplevel_tracking = true, .output_config = true },
        .zoolander => .{ .workspaces = true, .toplevel_tracking = true, .output_config = true },
        .labwc, .unknown => .{},
    };
}

test "backends: capability matrix is sane" {
    const t = std.testing;
    try t.expect(capabilitiesFor(.hyprland).workspaces);
    try t.expect(!capabilitiesFor(.unknown).workspaces);
}

test "backends: flag detection order follows backend priority" {
    const t = std.testing;
    try t.expectEqual(Kind.hyprland, Kind.detectFromFlags(true, true, false, false));
    try t.expectEqual(Kind.niri, Kind.detectFromFlags(false, true, false, false));
    try t.expectEqual(Kind.unknown, Kind.detectFromFlags(false, false, false, false));
}

test "backends: detection probes the variables in precedence order" {
    const t = std.testing;

    // Hyprland wins over everything, mango loses to all of them — the
    // Env-probe precedence. Blanking a key with
    // `put(key, "")` is how this map says "unset", which is the same test
    // `getenv(...)[0] != '\0'` performed.
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HYPRLAND_INSTANCE_SIGNATURE", "abc");
    try env.put("SWAYSOCK", "/run/sway.sock");
    try env.put("MANGO_INSTANCE_SIGNATURE", "/run/mango.sock");
    try t.expectEqual(Kind.hyprland, Kind.detectWithMap(&env));
    try env.put("HYPRLAND_INSTANCE_SIGNATURE", "");
    try t.expectEqual(Kind.sway, Kind.detectWithMap(&env));
    try env.put("SWAYSOCK", "");
    try t.expectEqual(Kind.mango, Kind.detectWithMap(&env));

    // mango's variable is the instance signature, not a socket path —
    // `MANGO_SOCKET` alone never selects mango either.
    var other = std.process.Environ.Map.init(t.allocator);
    defer other.deinit();
    try other.put("MANGO_SOCKET", "/run/mango.sock");
    try t.expectEqual(Kind.unknown, Kind.detectWithMap(&other));
    try other.put("LABWC_PID", "1234");
    try t.expectEqual(Kind.labwc, Kind.detectWithMap(&other));

    // An empty value counts as unset, so the next probe gets its turn.
    var empty = std.process.Environ.Map.init(t.allocator);
    defer empty.deinit();
    try empty.put("NIRI_SOCKET", "");
    try empty.put("MANGO_INSTANCE_SIGNATURE", "/run/mango.sock");
    try t.expectEqual(Kind.mango, Kind.detectWithMap(&empty));

    // No sockets at all: the desktop hint decides, case-insensitively, and
    // the `dwl` alias still means mango.
    var hint = std.process.Environ.Map.init(t.allocator);
    defer hint.deinit();
    try hint.put("XDG_CURRENT_DESKTOP", "Hyprland");
    try t.expectEqual(Kind.hyprland, Kind.detectWithMap(&hint));
    try hint.put("XDG_CURRENT_DESKTOP", "Niri:Wayland");
    try t.expectEqual(Kind.niri, Kind.detectWithMap(&hint));
    try hint.put("XDG_CURRENT_DESKTOP", "");
    try hint.put("DESKTOP_SESSION", "dwl");
    try t.expectEqual(Kind.mango, Kind.detectWithMap(&hint));
    try hint.put("DESKTOP_SESSION", "");
    try t.expectEqual(Kind.unknown, Kind.detectWithMap(&hint));
}

test "backends: zoolander wins over the Hyprland compatibility marker" {
    const t = std.testing;
    // A nested Zoolander strips the Hyprland marker from its clients, but a
    // process that still carries both counts as Zoolander.
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HYPRLAND_INSTANCE_SIGNATURE", "hypr-compat");
    try env.put("ZOOLANDER_WSI", "1");
    try t.expectEqual(Kind.zoolander, Kind.detectWithMap(&env));

    // A hint naming both still resolves to Zoolander.
    var hinted = std.process.Environ.Map.init(t.allocator);
    defer hinted.deinit();
    try hinted.put("XDG_CURRENT_DESKTOP", "Hyprland:Zoolander");
    try t.expectEqual(Kind.zoolander, Kind.detectWithMap(&hinted));

    try t.expect(capabilitiesFor(.zoolander).workspaces);
}

test "backends: zoolander control socket path follows the Wayland socket" {
    const t = std.testing;
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var buf: [256]u8 = undefined;

    try t.expect(zoolanderControlPath(&buf, &env) == null);
    try env.put("XDG_RUNTIME_DIR", "/run/user/1000");
    try t.expect(zoolanderControlPath(&buf, &env) == null);
    try env.put("WAYLAND_DISPLAY", "wayland-3");
    try t.expectEqualStrings("/run/user/1000/zoolander-wayland-3.sock", zoolanderControlPath(&buf, &env).?);

    // An absolute WAYLAND_DISPLAY still keys the control socket by basename.
    try env.put("WAYLAND_DISPLAY", "/run/user/1000/wayland-7");
    try t.expectEqualStrings("/run/user/1000/zoolander-wayland-7.sock", zoolanderControlPath(&buf, &env).?);
}
