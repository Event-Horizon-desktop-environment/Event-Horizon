const std = @import("std");

pub const Kind = enum {
    hyprland,
    niri,
    mango,
    sway,
    labwc,
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
        };
        const vars = [_][]const u8{ "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "DESKTOP_SESSION" };
        for (hints) |h| {
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
