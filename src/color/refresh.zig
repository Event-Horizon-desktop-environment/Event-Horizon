//! Wallpaper-derived palettes — external `matugen`
//! binary and the native
//! engine). Each path fills 8 chrome groups behind a mem + disk cache; the
//! router picks by `horizon_native`, mirroring
//! `refresh_wallpaper_derived_palette`.
//!
//! Fidelity notes:
//!   * The matugen JSON scan windows (4000/200 chars, 6-hex collection with
//!     its continue-on-no-hex and fail-on-short rules) are ported
//!     line-for-line; the parser is deliberately NOT a JSON parser.
//!   * Bare `abs()` on integers resolves to integer truncation (verified
//!     per-TU by probe): there is no such call left here (the ported logic
//!     never needed one), but any future one must use `@trunc(@abs(...))`.
//!   * Disk files share the `v2`/`v3` layout (`seed=`/`key=` lines in the
//!     engine cache are a different file); quoted-string escapes are honored
//!     so paths with spaces or quotes round-trip.
//!   * The matugen path never sets `text` (it keeps whatever
//!     the caller had); the native path forces white/black by mode.

const std = @import("std");
const engine = @import("engine.zig");

/// The 8 chrome groups + ok flag, with field defaults.
pub const ChromeSet = struct {
    dock_fill: [3]f32 = .{ 0.12, 0.12, 0.14 },
    panel_fill: [3]f32 = .{ 0.08, 0.10, 0.13 },
    drawer_dim: [3]f32 = .{ 0.11, 0.11, 0.13 },
    outline: [3]f32 = .{ 0.55, 0.60, 0.62 },
    accent: [3]f32 = .{ 0.90, 0.90, 0.90 },
    text: [3]f32 = .{ 0.92, 0.92, 0.95 },
    notif_bg: [3]f32 = .{ 0.18, 0.06, 0.06 },
    notif_ol: [3]f32 = .{ 0.70, 0.10, 0.10 },
    ok: bool = false,
};

pub const Inputs = struct {
    matugen_theming: bool = false,
    horizon_native: bool = true,
    scheme: []const u8 = "scheme-content",
    mode: []const u8 = "dark",
};

/// One mem-cache slot per path.
pub const CachedPalette = struct {
    path: []u8 = &.{},
    scheme: []u8 = &.{},
    mode: []u8 = &.{},
    sec: i64 = 0,
    nsec: i64 = 0,
    theming: bool = false,
    set: ChromeSet = .{},

    pub fn deinit(self: *CachedPalette, alloc: std.mem.Allocator) void {
        if (self.path.len > 0) alloc.free(self.path);
        if (self.scheme.len > 0) alloc.free(self.scheme);
        if (self.mode.len > 0) alloc.free(self.mode);
        self.* = .{};
    }

    pub fn matches(
        self: *const CachedPalette,
        path: []const u8,
        sec: i64,
        nsec: i64,
        scheme: []const u8,
        mode: []const u8,
    ) bool {
        return self.set.ok and self.theming and
            std.mem.eql(u8, self.path, path) and
            std.mem.eql(u8, self.scheme, scheme) and
            std.mem.eql(u8, self.mode, mode) and
            self.sec == sec and self.nsec == nsec;
    }
};

/// `$XDG_STATE_HOME/event-horizon`, mirroring `state_event_horizon_dir()`.
/// Note the lowercase leaf: this is the SHARED dir, not the Zig config leaf.
pub fn stateDir(alloc: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |x| {
        const s = std.mem.span(x);
        if (s.len > 0) return std.fs.path.join(alloc, &.{ s, "event-horizon" });
    }
    if (std.c.getenv("HOME")) |h| {
        const s = std.mem.span(h);
        if (s.len > 0) return std.fs.path.join(alloc, &.{ s, ".local", "state", "event-horizon" });
    }
    return alloc.dupe(u8, "/tmp/event-horizon");
}

pub fn normalizeScheme(raw: []const u8, out: []u8) []u8 {
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
        if (std.mem.eql(u8, s, k)) {
            @memcpy(out[0..k.len], k);
            return out[0..k.len];
        }
    }
    // NOTE: an `m3-` strip compares 4 chars against a 3-char literal,
    // but it compares FOUR chars against a THREE-char literal, so it never
    // matches and the strip is dead code (verified against the compiled
    // libstdc++: compare() returns 1). Replicated as-is: `m3-*` falls
    // through to the Content default, exactly like upstream.
    const canon: []const u8 = if (std.mem.eql(u8, s, "content"))
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
    @memcpy(out[0..canon.len], canon);
    return out[0..canon.len];
}

pub fn normalizeMode(raw: []const u8, out: []u8) []u8 {
    var tmp: [32]u8 = undefined;
    const len = @min(raw.len, tmp.len);
    for (raw[0..len], 0..) |c, i| tmp[i] = std.ascii.toLower(c);
    var s: []const u8 = tmp[0..len];
    while (s.len > 0 and std.ascii.isWhitespace(s[0])) s = s[1..];
    while (s.len > 0 and std.ascii.isWhitespace(s[s.len - 1])) s = s[0 .. s.len - 1];
    const canon: []const u8 = if (std.mem.eql(u8, s, "light"))
        "light"
    else if (std.mem.eql(u8, s, "auto"))
        "auto"
    else
        "dark";
    @memcpy(out[0..canon.len], canon);
    return out[0..canon.len];
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn hex6ToRgb(digits: []const u8, out: *[3]f32) bool {
    if (digits.len != 6) return false;
    var v: [3]u8 = undefined;
    for (0..3) |i| {
        const hi = hexVal(digits[i * 2]) orelse return false;
        const lo = hexVal(digits[i * 2 + 1]) orelse return false;
        v[i] = hi * 16 + lo;
    }
    out.* = .{
        @as(f32, @floatFromInt(v[0])) / 255.0,
        @as(f32, @floatFromInt(v[1])) / 255.0,
        @as(f32, @floatFromInt(v[2])) / 255.0,
    };
    return true;
}

/// The `"<key>"` … `{` … `"<branch>"` … `#rrggbb` scan, with search
/// windows (4000 past the brace, 200 past the branch) and its exact
/// collect rules: skip non-`#`, gather up to 6 hex digits (ignoring leading
/// non-hex), then succeed or fail as a whole on the count.
fn extractBranchHex(json: []const u8, key: []const u8, branch_quote: []const u8, out: *[3]f32) bool {
    var needle: [64]u8 = undefined;
    const nl = std.fmt.bufPrint(&needle, "\"{s}\"", .{key}) catch return false;
    const p = std.mem.indexOf(u8, json, nl) orelse return false;
    const zone_end = std.mem.indexOfScalarPos(u8, json, p, '{') orelse return false;
    const branch = std.mem.indexOfPos(u8, json, zone_end, branch_quote) orelse return false;
    if (branch > zone_end + 4000) return false;
    var hs = branch;
    while (hs < json.len and hs < branch + 200) : (hs += 1) {
        if (json[hs] != '#') continue;
        var buf: [6]u8 = undefined;
        var cnt: usize = 0;
        var j = hs + 1;
        while (j < json.len and cnt < 6) : (j += 1) {
            if (hexVal(json[j])) |h| {
                buf[cnt] = json[j];
                _ = h;
                cnt += 1;
            } else if (cnt > 0) {
                break;
            }
        }
        if (cnt != 6) return false;
        return hex6ToRgb(&buf, out);
    }
    return false;
}

pub fn extractColorHex(json: []const u8, key: []const u8, light: bool, out: *[3]f32) bool {
    const want: []const u8 = if (light) "\"light\"" else "\"dark\"";
    if (extractBranchHex(json, key, want, out)) return true;
    const alt: []const u8 = if (light) "\"dark\"" else "\"light\"";
    return extractBranchHex(json, key, alt, out);
}

/// Quoted-string reader: `"..."` with `\\`/`\"` escapes. Returns the value
/// (into `out`) and the offset just past the closing quote.
fn parseQuoted(s: []const u8, pos: usize, out: []u8) ?struct { val: []u8, next: usize } {
    if (pos >= s.len or s[pos] != '"') return null;
    var n: usize = 0;
    var i = pos + 1;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\') {
            if (i + 1 >= s.len) return null;
            if (n >= out.len) return null;
            out[n] = s[i + 1];
            n += 1;
            i += 2;
        } else if (c == '"') {
            return .{ .val = out[0..n], .next = i + 1 };
        } else {
            if (n >= out.len) return null;
            out[n] = c;
            n += 1;
            i += 1;
        }
    }
    return null;
}

fn skipWs(s: []const u8, pos: usize) usize {
    var i = pos;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
    return i;
}

fn parseI64(s: []const u8, pos: usize) ?struct { val: i64, next: usize } {
    var i = skipWs(s, pos);
    const neg = i < s.len and s[i] == '-';
    if (neg) i += 1;
    if (i >= s.len or s[i] < '0' or s[i] > '9') return null;
    var v: i64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + @as(i64, @intCast(s[i] - '0'));
    }
    return .{ .val = if (neg) -v else v, .next = i };
}

fn parseF32(s: []const u8, pos: usize) ?struct { val: f32, next: usize } {
    var i = skipWs(s, pos);
    const start = i;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
    var seen = false;
    while (i < s.len and ((s[i] >= '0' and s[i] <= '9') or s[i] == '.' or s[i] == 'e' or s[i] == 'E' or s[i] == '+' or s[i] == '-')) : (i += 1) {
        seen = true;
    }
    if (!seen) return null;
    const v = std.fmt.parseFloat(f32, s[start..i]) catch return null;
    return .{ .val = v, .next = i };
}

/// Read a `v2` (15 floats) or `v3` (21 floats) palette cache file. Any
/// mismatch — version, path, mtime, scheme, mode, flag, arity — is a miss.
pub fn loadDiskCache(
    alloc: std.mem.Allocator,
    io: std.Io,
    file: []const u8,
    path: []const u8,
    sec: i64,
    nsec: i64,
    scheme: []const u8,
    mode: []const u8,
) ?CachedPalette {
    const data = std.Io.Dir.cwd().readFileAlloc(io, file, alloc, .limited(65536)) catch return null;
    defer alloc.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    const ver = lines.next() orelse return null;
    const is_v3 = std.mem.eql(u8, ver, "v3");
    if (!is_v3 and !std.mem.eql(u8, ver, "v2")) return null;

    var path_buf: [1024]u8 = undefined;
    const disk_path = (lines.next() orelse return null);
    const pq = parseQuoted(disk_path, 0, &path_buf) orelse return null;
    if (!std.mem.eql(u8, pq.val, path)) return null;

    const times = lines.next() orelse return null;
    const tsec = parseI64(times, 0) orelse return null;
    const tnsec = parseI64(times, tsec.next) orelse return null;
    if (tsec.val != sec or tnsec.val != nsec) return null;

    const sm = lines.next() orelse return null;
    var sm_buf: [128]u8 = undefined;
    const qscheme = parseQuoted(sm, 0, &sm_buf) orelse return null;
    // The mode parse reuses the buffer, so lift the scheme out first.
    var scheme_buf: [64]u8 = undefined;
    if (qscheme.val.len > scheme_buf.len) return null;
    @memcpy(scheme_buf[0..qscheme.val.len], qscheme.val);
    const scheme_val = scheme_buf[0..qscheme.val.len];
    const qmode = parseQuoted(sm, skipWs(sm, qscheme.next), &sm_buf) orelse return null;
    if (!std.mem.eql(u8, scheme_val, scheme) or !std.mem.eql(u8, qmode.val, mode)) return null;

    const flag_line = lines.next() orelse return null;
    const flag = parseI64(flag_line, 0) orelse return null;
    if (flag.val != 1) return null;

    var floats: [21]f32 = undefined;
    var n: usize = 0;
    while (lines.next()) |ln| {
        var pos: usize = 0;
        while (n < floats.len) {
            const f = parseF32(ln, pos) orelse break;
            floats[n] = f.val;
            n += 1;
            pos = f.next;
        }
    }
    const want: usize = if (is_v3) 21 else 15;
    if (n != want) return null;

    var set = ChromeSet{};
    set.dock_fill = .{ floats[0], floats[1], floats[2] };
    set.panel_fill = .{ floats[3], floats[4], floats[5] };
    set.drawer_dim = .{ floats[6], floats[7], floats[8] };
    set.outline = .{ floats[9], floats[10], floats[11] };
    set.accent = .{ floats[12], floats[13], floats[14] };
    if (is_v3) {
        set.notif_bg = .{ floats[15], floats[16], floats[17] };
        set.notif_ol = .{ floats[18], floats[19], floats[20] };
    }
    set.ok = true;

    const entry = CachedPalette{
        .path = alloc.dupe(u8, path) catch return null,
        .scheme = alloc.dupe(u8, scheme) catch return null,
        .mode = alloc.dupe(u8, mode) catch return null,
        .sec = sec,
        .nsec = nsec,
        .theming = true,
        .set = set,
    };
    return entry;
}

/// Write the `v3` layout atomically (tmp + rename). Floats use
/// shortest-round-trip text: it parses back bit-exact, even though the reference
/// `setprecision(10)` rendering may differ cosmetically.
pub fn saveDiskCache(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    file: []const u8,
    entry: *const CachedPalette,
) void {
    saveDiskCacheInner(alloc, io, dir, file, entry) catch {};
}

fn appendQuoted(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try buf.append(alloc, '"');
    for (s) |c| {
        if (c == '\\' or c == '"') try buf.append(alloc, '\\');
        try buf.append(alloc, c);
    }
    try buf.append(alloc, '"');
}

fn saveDiskCacheInner(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    file: []const u8,
    entry: *const CachedPalette,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{file});
    defer alloc.free(tmp);
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "v3\n");
    try appendQuoted(&buf, alloc, entry.path);
    try buf.appendSlice(alloc, "\n");
    var num: [64]u8 = undefined;
    try buf.appendSlice(alloc, try std.fmt.bufPrint(&num, "{d} {d}\n", .{ entry.sec, entry.nsec }));
    try appendQuoted(&buf, alloc, entry.scheme);
    try buf.appendSlice(alloc, " ");
    try appendQuoted(&buf, alloc, entry.mode);
    try buf.appendSlice(alloc, "\n1\n");
    // dock/panel/drawer/outline/accent then the two notif groups (7 lines,
    // 21 floats) — `text` is NOT in the file.
    const groups = [_][3]f32{
        entry.set.dock_fill, entry.set.panel_fill, entry.set.drawer_dim,
        entry.set.outline,   entry.set.accent,     entry.set.notif_bg,
        entry.set.notif_ol,
    };
    for (groups) |g| {
        try buf.appendSlice(alloc, try std.fmt.bufPrint(&num, "{d} {d} {d}\n", .{ g[0], g[1], g[2] }));
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = buf.items });
    const cwd = std.Io.Dir.cwd();
    cwd.rename(tmp, cwd, file, io) catch {
        cwd.deleteFile(io, tmp) catch {};
    };
}

fn fileMtime(io: std.Io, path: []const u8) ?struct { sec: i64, nsec: i64 } {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.kind != .file) return null;
    const ns = st.mtime.nanoseconds;
    return .{
        .sec = @intCast(@divFloor(ns, 1_000_000_000)),
        .nsec = @intCast(@mod(ns, 1_000_000_000)),
    };
}

fn storeMem(
    alloc: std.mem.Allocator,
    slot: *?CachedPalette,
    path: []const u8,
    scheme: []const u8,
    mode: []const u8,
    sec: i64,
    nsec: i64,
    set: ChromeSet,
) void {
    const p = alloc.dupe(u8, path) catch return;
    errdefer alloc.free(p);
    const sc = alloc.dupe(u8, scheme) catch return;
    errdefer alloc.free(sc);
    const mo = alloc.dupe(u8, mode) catch return;
    errdefer alloc.free(mo);
    if (slot.*) |*old| old.deinit(alloc);
    slot.* = CachedPalette{
        .path = p,
        .scheme = sc,
        .mode = mo,
        .sec = sec,
        .nsec = nsec,
        .theming = true,
        .set = set,
    };
}

/// Run `matugen image … --dry-run` and take stdout. Null on any failure —
/// most notably the binary not being installed.
fn spawnMatugenStdout(
    alloc: std.mem.Allocator,
    io: std.Io,
    abs_image: []const u8,
    dark_mode: bool,
    scheme: []const u8,
) ?[]u8 {
    const res = std.process.run(alloc, io, .{
        .argv = &.{
            "matugen", "image", abs_image, "--json", "hex", "--dry-run",
            "-m",          if (dark_mode) "dark" else "light",
            "--source-color-index", "0",
            "--old-json-output",
            "-t",          scheme,
        },
    }) catch return null;
    defer alloc.free(res.stderr);
    errdefer alloc.free(res.stdout);
    if (res.term != .exited) {
        return null;
    }
    if (res.term.exited != 0 or res.stdout.len == 0) {
        return null;
    }
    return res.stdout;
}

pub const Refresher = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    matugen_mem: ?CachedPalette = null,
    hc_mem: ?CachedPalette = null,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Refresher {
        return .{ .alloc = alloc, .io = io };
    }

    pub fn deinit(self: *Refresher) void {
        if (self.matugen_mem) |*m| m.deinit(self.alloc);
        if (self.hc_mem) |*m| m.deinit(self.alloc);
        self.* = .{ .alloc = self.alloc, .io = self.io };
    }

    /// `refresh_wallpaper_derived_palette`: native engine when
    /// `horizon_native`, else the external binary. Each fills only its own
    /// set (writing `hc*` or `matugen*` fields).
    pub fn refresh(
        self: *Refresher,
        inputs: Inputs,
        image_path: []const u8,
        state_dir: []const u8,
        matugen_out: *ChromeSet,
        hc_out: *ChromeSet,
    ) void {
        if (inputs.horizon_native) {
            self.refreshNative(inputs, image_path, state_dir, hc_out);
            return;
        }
        self.refreshMatugen(inputs, image_path, state_dir, matugen_out);
    }

    pub fn refreshMatugen(
        self: *Refresher,
        inputs: Inputs,
        image_path: []const u8,
        state_dir: []const u8,
        out: *ChromeSet,
    ) void {
        out.ok = false;
        if (!inputs.matugen_theming) {
            if (self.matugen_mem) |*m| {
                m.theming = false;
                if (m.path.len > 0) {
                    self.alloc.free(m.path);
                    m.path = &.{};
                }
            }
            return;
        }
        if (image_path.len == 0) return;
        const mt = fileMtime(self.io, image_path) orelse return;
        var scheme_buf: [64]u8 = undefined;
        const scheme = normalizeScheme(inputs.scheme, &scheme_buf);
        var mode_buf: [32]u8 = undefined;
        const mode = normalizeMode(inputs.mode, &mode_buf);

        if (self.matugen_mem) |*m| {
            if (m.matches(image_path, mt.sec, mt.nsec, scheme, mode)) {
                out.* = m.set;
                return;
            }
        }
        const cache_file = std.fs.path.join(self.alloc, &.{ state_dir, "matugen-palette.cache" }) catch return;
        defer self.alloc.free(cache_file);
        if (loadDiskCache(self.alloc, self.io, cache_file, image_path, mt.sec, mt.nsec, scheme, mode)) |disk| {
            const d = disk;
            storeMem(self.alloc, &self.matugen_mem, image_path, scheme, mode, mt.sec, mt.nsec, d.set);
            out.* = d.set;
            self.alloc.free(d.path);
            self.alloc.free(d.scheme);
            self.alloc.free(d.mode);
            return;
        }

        const light = std.mem.eql(u8, mode, "light");
        const json = spawnMatugenStdout(self.alloc, self.io, image_path, !light, scheme) orelse return;
        defer self.alloc.free(json);

        var set = ChromeSet{};
        if (!extractColorHex(json, "surface_container", light, &set.dock_fill)) {
            if (!extractColorHex(json, "surface", light, &set.dock_fill)) return;
        }
        set.panel_fill = set.dock_fill;
        set.drawer_dim = set.dock_fill;
        _ = extractColorHex(json, "surface_variant", light, &set.drawer_dim);
        set.outline = .{ 0.55, 0.60, 0.62 };
        if (!extractColorHex(json, "outline", light, &set.outline)) {
            if (!extractColorHex(json, "outline_variant", light, &set.outline)) {
                set.outline = set.drawer_dim;
            }
        }
        _ = extractColorHex(json, "primary", light, &set.accent);
        _ = extractColorHex(json, "error_container", light, &set.notif_bg);
        _ = extractColorHex(json, "error", light, &set.notif_ol);
        set.ok = true;

        storeMem(self.alloc, &self.matugen_mem, image_path, scheme, mode, mt.sec, mt.nsec, set);
        out.* = set;
        if (self.matugen_mem) |*m| {
            saveDiskCache(self.alloc, self.io, state_dir, cache_file, m);
        }
    }

    pub fn refreshNative(
        self: *Refresher,
        inputs: Inputs,
        image_path: []const u8,
        state_dir: []const u8,
        out: *ChromeSet,
    ) void {
        out.ok = false;
        if (!inputs.horizon_native) {
            if (self.hc_mem) |*m| {
                m.theming = false;
                if (m.path.len > 0) {
                    self.alloc.free(m.path);
                    m.path = &.{};
                }
            }
            return;
        }
        if (image_path.len == 0) return;
        const mt = fileMtime(self.io, image_path) orelse return;
        var scheme_buf: [64]u8 = undefined;
        const scheme = normalizeScheme(inputs.scheme, &scheme_buf);
        var mode_buf: [32]u8 = undefined;
        const mode = normalizeMode(inputs.mode, &mode_buf);

        if (self.hc_mem) |*m| {
            if (m.matches(image_path, mt.sec, mt.nsec, scheme, mode)) {
                out.* = m.set;
                return;
            }
        }
        const cache_file = std.fs.path.join(self.alloc, &.{ state_dir, "horizon-colors-palette.cache" }) catch return;
        defer self.alloc.free(cache_file);
        const legacy_file = std.fs.path.join(self.alloc, &.{ state_dir, "matugen-palette.cache" }) catch return;
        defer self.alloc.free(legacy_file);
        // New file first, then the legacy external path (first-run migration).
        if (loadDiskCache(self.alloc, self.io, cache_file, image_path, mt.sec, mt.nsec, scheme, mode) orelse
            loadDiskCache(self.alloc, self.io, legacy_file, image_path, mt.sec, mt.nsec, scheme, mode)) |disk|
        {
            const d = disk;
            storeMem(self.alloc, &self.hc_mem, image_path, scheme, mode, mt.sec, mt.nsec, d.set);
            // The legacy file has no text row; force the mode color below.
            out.* = d.set;
            self.alloc.free(d.path);
            self.alloc.free(d.scheme);
            self.alloc.free(d.mode);
            const light = std.mem.eql(u8, mode, "light");
            out.text = if (light) .{ 0.0, 0.0, 0.0 } else .{ 1.0, 1.0, 1.0 };
            return;
        }

        const variant = engine.schemeVariantFromName(scheme);
        const light = std.mem.eql(u8, mode, "light");
        const result = engine.generatePaletteFromImage(
            self.alloc,
            image_path,
            variant,
            !light,
            0.0,
            128,
        ) catch return;
        if (!result.ok) return;

        var set = ChromeSet{};
        set.dock_fill = result.dock_fill;
        set.panel_fill = result.panel_fill;
        set.drawer_dim = result.drawer_dim;
        set.outline = result.outline;
        set.accent = result.accent;
        set.text = if (light) .{ 0.0, 0.0, 0.0 } else .{ 1.0, 1.0, 1.0 };
        set.notif_bg = result.notif_critical_bg;
        set.notif_ol = result.notif_critical_outline;
        set.ok = true;

        storeMem(self.alloc, &self.hc_mem, image_path, scheme, mode, mt.sec, mt.nsec, set);
        out.* = set;
        if (self.hc_mem) |*m| {
            saveDiskCache(self.alloc, self.io, state_dir, cache_file, m);
        }
    }
};

test "refresh: scheme and mode normalization" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("scheme-content", normalizeScheme("content", &buf));
    try t.expectEqualStrings("scheme-vibrant", normalizeScheme("Vibrant", &buf));
    try t.expectEqualStrings("scheme-tonal-spot", normalizeScheme("scheme-tonal-spot", &buf));
    try t.expectEqualStrings("scheme-tonal-spot", normalizeScheme("tonal_spot", &buf));
    try t.expectEqualStrings("scheme-fidelity", normalizeScheme("faithful", &buf));
    // The `m3-` strip compares 4 chars against a 3-char literal and never
    // fires, so `m3-*` falls through to Content — locked here, not fixed.
    try t.expectEqualStrings("scheme-content", normalizeScheme("m3-fidelity", &buf));
    try t.expectEqualStrings("scheme-fruit-salad", normalizeScheme("fruitsalad", &buf));
    try t.expectEqualStrings("scheme-content", normalizeScheme("  garbage  ", &buf));
    var mbuf: [32]u8 = undefined;
    try t.expectEqualStrings("light", normalizeMode("Light", &mbuf));
    try t.expectEqualStrings("auto", normalizeMode("auto", &mbuf));
    try t.expectEqualStrings("dark", normalizeMode("DARK", &mbuf));
    try t.expectEqualStrings("dark", normalizeMode("weird", &mbuf));
}

const matugen_fixture =
    \\{ "colors": {
    \\  "surface_container": { "dark": "#1d1b20", "light": "#f3edf7" },
    \\  "surface": { "dark": "#141218", "light": "#fef7ff" },
    \\  "surface_variant": { "dark": "#49454f", "light": "#e7e0ec" },
    \\  "outline": { "dark": "#938f99", "light": "#79747e" },
    \\  "primary": { "dark": "#d0bcff", "light": "#6750a4" },
    \\  "error_container": { "dark": "#93000a", "light": "#ffdad6" },
    \\  "error": { "dark": "#ffb4ab", "light": "#ba1a1a" }
    \\ } }
;

test "refresh: matugen JSON extraction with branch fallback" {
    const t = std.testing;
    var rgb: [3]f32 = undefined;
    try t.expect(extractColorHex(matugen_fixture, "surface_container", false, &rgb));
    try t.expectApproxEqAbs(@as(f32, 0x1d) / 255.0, rgb[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0x1b) / 255.0, rgb[1], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0x20) / 255.0, rgb[2], 1e-6);
    try t.expect(extractColorHex(matugen_fixture, "primary", true, &rgb));
    try t.expectApproxEqAbs(@as(f32, 0x67) / 255.0, rgb[0], 1e-6);
    // Missing key reads as failure; missing branch falls to the other one.
    try t.expect(!extractColorHex(matugen_fixture, "nope", false, &rgb));
    try t.expect(!extractColorHex("{\"a\": {\"dark\": \"#12\"}}", "a", false, &rgb));
}

test "refresh: palette disk cache round-trips and rejects stale files" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const file = try std.fs.path.join(alloc, &.{ root, "matugen-palette.cache" });
    defer alloc.free(file);

    var entry = CachedPalette{
        .path = try alloc.dupe(u8, "/pics/wall.png"),
        .scheme = try alloc.dupe(u8, "scheme-content"),
        .mode = try alloc.dupe(u8, "dark"),
        .sec = 1700000000,
        .nsec = 123,
        .theming = true,
        .set = .{ .dock_fill = .{ 0.1, 0.2, 0.3 }, .accent = .{ 0.9, 0.8, 0.7 }, .ok = true },
    };
    defer entry.deinit(alloc);
    saveDiskCache(alloc, io, root, file, &entry);

    var hit = loadDiskCache(alloc, io, file, "/pics/wall.png", 1700000000, 123, "scheme-content", "dark") orelse
        return error.CacheMiss;
    defer hit.deinit(alloc);
    try t.expect(hit.set.ok);
    try t.expectApproxEqAbs(@as(f32, 0.1), hit.set.dock_fill[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.7), hit.set.accent[2], 1e-6);
    // Stale on every axis.
    try t.expect(loadDiskCache(alloc, io, file, "/pics/other.png", 1700000000, 123, "scheme-content", "dark") == null);
    try t.expect(loadDiskCache(alloc, io, file, "/pics/wall.png", 1700000001, 123, "scheme-content", "dark") == null);
    try t.expect(loadDiskCache(alloc, io, file, "/pics/wall.png", 1700000000, 123, "scheme-vibrant", "dark") == null);
    try t.expect(loadDiskCache(alloc, io, file, "/pics/wall.png", 1700000000, 123, "scheme-content", "light") == null);
}

test "refresh: disabled theming and missing images stay quiet" {
    const t = std.testing;
    const alloc = t.allocator;
    var r = Refresher.init(alloc, std.testing.io);
    defer r.deinit();
    var out = ChromeSet{};
    // Theming off clears ok without touching anything.
    r.refreshMatugen(.{ .matugen_theming = false }, "/pics/wall.png", "/tmp", &out);
    try t.expect(!out.ok);
    // Missing image: no crash, no ok (and no matugen binary is needed).
    r.refreshMatugen(.{ .matugen_theming = true }, "/nonexistent-xyz.png", "/tmp", &out);
    try t.expect(!out.ok);
    r.refreshNative(.{ .horizon_native = false }, "/pics/wall.png", "/tmp", &out);
    try t.expect(!out.ok);
    r.refreshNative(.{ .horizon_native = true }, "/nonexistent-xyz.png", "/tmp", &out);
    try t.expect(!out.ok);
}
