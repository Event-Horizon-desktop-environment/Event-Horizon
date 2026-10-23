const std = @import("std");
const compositor = @import("compositor.zig");
const hypr_ipc = @import("../../backends/hyprland_ipc.zig");
const autostart = @import("../../services/autostart.zig");

// Monitors data layer.
//
// Same design: one MonitorRow per output (fixed buffers, no allocation while
// a drag is in flight), an OutputCaps table derived from hyprctl's
// `availableModes`, and a config round trip (read → strip our blocks → overlay
// the parsed bodies → preamble; save → preamble + rebuilt blocks → reload).
// hyprctl's JSON
// is the sole capability source, which is the same result on this machine.
//
// Scope: the Hyprland path is complete (the only compositor running here).
// Niri/Mango answer with a status line for an unsupported kind.

// Fixed-buffer string

/// A length-prefixed byte buffer. Zero-initialised so `.{}` is a valid empty
/// value and copying a whole struct (the baseline snapshot) is safe.
pub fn Str(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = @as([cap]u8, @splat(0)),
        len: usize = 0,

        const Self = @This();

        pub fn set(self: *Self, s: []const u8) void {
            const n = @min(s.len, cap);
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn eql(self: *const Self, other: []const u8) bool {
            return std.mem.eql(u8, self.slice(), other);
        }

        pub fn empty(self: *const Self) bool {
            return self.len == 0;
        }
    };
}

// Capacity constants

pub const max_outputs: usize = 8;
/// Mode list budget: resolutions × refresh rates per resolution.
pub const max_res: usize = 24;
pub const max_hz: usize = 12;

pub const name_cap = 40;
pub const short_cap = 32;
pub const num_cap = 24;
pub const icc_cap = 512;
pub const path_cap = 384;
pub const status_cap = 240;

/// The CM preset tokens the UI offers.
pub const cm_labels = [_][]const u8{
    "auto", "srgb", "dcip3", "dp3", "adobe", "wide", "edid", "hdr", "hdredid",
};

// Row + capabilities

pub const MonitorRow = struct {
    name: Str(name_cap) = .{},
    resolution: Str(short_cap) = .{},
    refresh_rate: Str(short_cap) = .{},
    position: Str(short_cap) = .{},
    scale: Str(num_cap) = .{},
    transform: Str(tiny) = .{},
    disabled: bool = false,
    bitdepth: Str(tiny) = .{},
    cm: Str(short_cap) = .{},
    icc: Str(icc_cap) = .{},
    vrr: Str(tiny) = .{},
    mirror: Str(name_cap) = .{},
    sdrbrightness: Str(num_cap) = .{},
    sdrsaturation: Str(num_cap) = .{},
    sdr_eotf: Str(tiny) = .{},
    supports_hdr: Str(tiny) = .{},
    supports_wide_color: Str(tiny) = .{},
    sdr_min_luminance: Str(num_cap) = .{},
    sdr_max_luminance: Str(num_cap) = .{},
    min_luminance: Str(num_cap) = .{},
    max_luminance: Str(num_cap) = .{},
    max_avg_luminance: Str(num_cap) = .{},

    const tiny = 8;
};

pub const OutputCaps = struct {
    n_res: usize = 0,
    res: [max_res][16]u8 = @as([max_res][16]u8, @splat(@as([16]u8, @splat(0)))),
    res_len: [max_res]u8 = @as([max_res]u8, @splat(0)),
    hz: [max_res][max_hz]f64 = @as([max_res][max_hz]f64, @splat(@as([max_hz]f64, @splat(0)))),
    hz_len: [max_res]u8 = @as([max_res]u8, @splat(0)),
    vrr_capable: bool = false,
    hdr_hint: bool = false,
    width: i32 = 0,
    height: i32 = 0,
    current_hz: f64 = 0,

    pub fn resolution(self: *const OutputCaps, i: usize) []const u8 {
        if (i >= self.n_res) return "";
        return self.res[i][0..self.res_len[i]];
    }

    pub fn hzList(self: *OutputCaps, i: usize) []f64 {
        if (i >= self.n_res) return &.{};
        return self.hz[i][0..self.hz_len[i]];
    }

    pub fn findResolution(self: *const OutputCaps, s: []const u8) ?usize {
        var i: usize = 0;
        while (i < self.n_res) : (i += 1) {
            if (std.mem.eql(u8, self.resolution(i), s)) return i;
        }
        return null;
    }

    /// `merge_caps_from_hypr_monitor`'s dedup insert: a resolution appears
    /// once, a refresh rate once per resolution and once overall.
    pub fn addMode(self: *OutputCaps, w: i32, h: i32, hz: f64) void {
        if (w <= 0 or h <= 0) return;
        var rbuf: [16]u8 = undefined;
        const rk = std.fmt.bufPrint(&rbuf, "{d}x{d}", .{ w, h }) catch return;
        const ri = self.findResolution(rk) orelse blk: {
            if (self.n_res >= max_res) return;
            const at = self.n_res;
            const n = @min(rk.len, 16);
            @memcpy(self.res[at][0..n], rk[0..n]);
            self.res_len[at] = @intCast(n);
            self.n_res += 1;
            break :blk at;
        };
        if (hz <= 0) return;
        const n = self.hz_len[ri];
        for (self.hz[ri][0..n]) |v| {
            if (v == hz) return;
        }
        if (n >= max_hz) return;
        self.hz[ri][n] = hz;
        self.hz_len[ri] = n + 1;
    }

    /// Sorts resolutions by pixel area (descending) and each resolution's
    /// refresh rates descending.
    pub fn sortModes(self: *OutputCaps) void {
        var i: usize = 1;
        while (i < self.n_res) : (i += 1) {
            var j = i;
            while (j > 0 and area(self, j) > area(self, j - 1)) : (j -= 1) self.swapRes(j, j - 1);
        }
        var r: usize = 0;
        while (r < self.n_res) : (r += 1) {
            const list = self.hzList(r);
            var a: usize = 1;
            while (a < list.len) : (a += 1) {
                var b = a;
                while (b > 0 and list[b] > list[b - 1]) : (b -= 1) {
                    const tmp = list[b];
                    list[b] = list[b - 1];
                    list[b - 1] = tmp;
                }
            }
        }
    }

    fn area(self: *const OutputCaps, i: usize) i64 {
        const s = self.resolution(i);
        const x = std.mem.indexOfScalar(u8, s, 'x') orelse return 0;
        const w = std.fmt.parseInt(i64, s[0..x], 10) catch 0;
        const h = std.fmt.parseInt(i64, s[x + 1 ..], 10) catch 0;
        return w * h;
    }

    fn swapRes(self: *OutputCaps, a: usize, b: usize) void {
        const r = self.res[a];
        self.res[a] = self.res[b];
        self.res[b] = r;
        const rl = self.res_len[a];
        self.res_len[a] = self.res_len[b];
        self.res_len[b] = rl;
        const hl = self.hz_len[a];
        self.hz_len[a] = self.hz_len[b];
        self.hz_len[b] = hl;
        const hz = self.hz[a];
        self.hz[a] = self.hz[b];
        self.hz[b] = hz;
    }
};

pub const CapEntry = struct {
    name: Str(name_cap) = .{},
    caps: OutputCaps = .{},
};

/// The parsed `monitorv2 { … }` / `hl.monitor({ … })` body: the row it
/// describes plus the key set the file actually mentions
/// (used so an overlay only touches keys the config owns).
pub const ParsedBlock = struct {
    row: MonitorRow = .{},
    keys: [40][]const u8 = undefined,
    keys_len: usize = 0,

    pub fn has(self: *const ParsedBlock, key: []const u8) bool {
        for (self.keys[0..self.keys_len]) |k| {
            if (std.mem.eql(u8, k, key)) return true;
        }
        return false;
    }
};

// JSON helpers (string-scanning variants, slice-returning)

fn jsonKeyIndex(hay: []const u8, key: []const u8) ?usize {
    var buf: [130]u8 = undefined;
    buf[0] = '"';
    const n = @min(key.len, 128);
    @memcpy(buf[1 .. 1 + n], key[0..n]);
    buf[n + 1] = '"';
    return std.mem.indexOf(u8, hay, buf[0 .. n + 2]);
}

fn afterColon(hay: []const u8, key: []const u8) ?usize {
    const p = jsonKeyIndex(hay, key) orelse return null;
    const start = p + key.len + 2;
    const c = std.mem.indexOfScalarPos(u8, hay, start, ':') orelse return null;
    var i = c + 1;
    while (i < hay.len and std.ascii.isWhitespace(hay[i])) : (i += 1) {}
    return if (i < hay.len) i else null;
}

fn scanString(hay: []const u8, key: []const u8) ?[]const u8 {
    var i = afterColon(hay, key) orelse return null;
    if (hay[i] != '"') return null;
    const begin = i + 1;
    i = begin;
    while (i < hay.len) : (i += 1) {
        if (hay[i] == '\\') {
            i += 1;
            continue;
        }
        if (hay[i] == '"') return hay[begin..i];
    }
    return null;
}

fn jsonNumber(hay: []const u8, key: []const u8) ?f64 {
    const i = afterColon(hay, key) orelse return null;
    var e = i;
    while (e < hay.len) : (e += 1) {
        const ch = hay[e];
        const ok = std.ascii.isDigit(ch) or ch == '-' or ch == '+' or ch == '.' or ch == 'e' or ch == 'E';
        if (!ok) break;
    }
    if (e == i) return null;
    return std.fmt.parseFloat(f64, hay[i..e]) catch null;
}

fn scanBool(hay: []const u8, key: []const u8) ?bool {
    const i = afterColon(hay, key) orelse return null;
    if (std.mem.startsWith(u8, hay[i..], "true")) return true;
    if (std.mem.startsWith(u8, hay[i..], "false")) return false;
    return null;
}

/// Inner text of the first array value stored under `key`.
fn jsonArrayInner(hay: []const u8, key: []const u8) ?[]const u8 {
    const p = jsonKeyIndex(hay, key) orelse return null;
    const b = std.mem.indexOfScalarPos(u8, hay, p + key.len + 2, '[') orelse return null;
    return bracedInner(hay, b, '[', ']');
}

/// Content between `open` and its matching close, string-aware.
fn bracedInner(hay: []const u8, open: usize, l: u8, r: u8) ?[]const u8 {
    const begin = open + 1;
    var depth: i32 = 1;
    var in_str = false;
    var esc = false;
    var i = begin;
    while (i < hay.len) : (i += 1) {
        const c = hay[i];
        if (esc) {
            esc = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') {
            in_str = true;
            continue;
        }
        if (c == l) depth += 1 else if (c == r) {
            depth -= 1;
            if (depth == 0) return hay[begin..i];
        }
    }
    return null;
}

/// Inner text of the document's root `[ … ]`.
pub fn jsonRootArrayInner(doc: []const u8) ?[]const u8 {
    const b = std.mem.indexOfScalar(u8, doc, '[') orelse return null;
    return bracedInner(doc, b, '[', ']');
}

/// Top-level `{ … }` members of a JSON array body.
pub fn splitTopObjects(inner: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < inner.len and std.ascii.isWhitespace(inner[i])) : (i += 1) {}
    while (i < inner.len and n < out.len) {
        if (inner[i] != '{') break;
        const inside = bracedInner(inner, i, '{', '}') orelse break;
        const obj = inner[i .. i + 2 + inside.len];
        out[n] = obj;
        n += 1;
        i += obj.len;
        while (i < inner.len and (std.ascii.isWhitespace(inner[i]) or inner[i] == ',')) : (i += 1) {}
    }
    return n;
}

// Hyprland value normalizers

pub const ModeSpec = struct { w: i32 = 0, h: i32 = 0, hz: f64 = 0 };

/// `"2560x1440@239.97Hz"` → width/height/refresh. Split on `@`, then `x`,
/// then drop the trailing `Hz`.
pub fn parseHyprModeString(s: []const u8) ModeSpec {
    var m: ModeSpec = .{};
    const at = std.mem.indexOfScalar(u8, s, '@');
    const res = if (at) |a| s[0..a] else s;
    if (std.mem.indexOfScalar(u8, res, 'x')) |x| {
        m.w = parseIntI32(res[0..x]);
        m.h = parseIntI32(res[x + 1 ..]);
    }
    if (at) |a| {
        var hzp = s[a + 1 ..];
        if (hzp.len >= 2 and std.mem.endsWith(u8, hzp, "Hz")) hzp = hzp[0 .. hzp.len - 2];
        m.hz = std.fmt.parseFloat(f64, hzp) catch 0;
    }
    return m;
}

fn parseIntI32(s: []const u8) i32 {
    return std.fmt.parseInt(i32, s, 10) catch 0;
}

/// Normalise a compositor CM preset to a monitorv2 token ("" when unknown).
pub fn hyprCmTokenFromPreset(preset: []const u8) []const u8 {
    var buf: [96]u8 = undefined;
    const s = lowerCopy(&buf, std.mem.trim(u8, preset, " \t\r\n"));
    if (s.len == 0) return "";
    for (cm_labels) |k| {
        if (std.mem.eql(u8, s, k)) return k;
    }
    if (std.mem.indexOf(u8, s, "hdr") != null) {
        if (std.mem.indexOf(u8, s, "edid") != null) return "hdredid";
        return "hdr";
    }
    if (std.mem.eql(u8, s, "dci-p3") or std.mem.eql(u8, s, "dci_p3")) return "dcip3";
    if (std.mem.indexOf(u8, s, "dcip3") != null or
        (std.mem.indexOf(u8, s, "dci") != null and std.mem.indexOf(u8, s, "p3") != null)) return "dcip3";
    if ((std.mem.indexOf(u8, s, "display") != null and std.mem.indexOf(u8, s, "p3") != null) or
        std.mem.eql(u8, s, "p3")) return "dp3";
    if (std.mem.indexOf(u8, s, "adobe") != null) return "adobe";
    if (std.mem.indexOf(u8, s, "wide") != null) return "wide";
    if (std.mem.indexOf(u8, s, "edid") != null) return "edid";
    if (std.mem.indexOf(u8, s, "srgb") != null) return "srgb";
    if (std.mem.indexOf(u8, s, "auto") != null) return "auto";
    return "";
}

/// `sdr_eotf` → internal token: "" follow, "1" sRGB, "2" Gamma 2.2.
pub fn hyprSdrEotfToken(val: []const u8) []const u8 {
    var buf: [32]u8 = undefined;
    var s = std.mem.trim(u8, val, " \t\r\n");
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
    const v = lowerCopy(&buf, s);
    if (v.len == 0 or std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "default") or std.mem.eql(u8, v, "follow")) return "";
    if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "srgb") or std.mem.eql(u8, v, "piecewise")) return "1";
    if (std.mem.eql(u8, v, "2") or std.mem.eql(u8, v, "gamma22") or std.mem.eql(u8, v, "gamma2.2")) return "2";
    return "";
}

/// Config value: drop a trailing `# …`, trim, strip surrounding quotes.
pub fn hyprConfValueToken(val: []const u8) []const u8 {
    var s = val;
    if (std.mem.indexOfScalar(u8, s, '#')) |i| s = s[0..i];
    s = std.mem.trim(u8, s, " \t\r\n");
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = s[1 .. s.len - 1];
    return s;
}

fn lowerCopy(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Leading blank lines only — a stripped file's preamble starts at real content.
pub fn trimLeadingBlankLines(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const nl = std.mem.indexOfScalarPos(u8, s, i, '\n');
        const line = if (nl) |n| s[i..n] else s[i..];
        if (trim(line).len != 0) break;
        i = if (nl) |n| n + 1 else s.len;
    }
    return s[i..];
}

// hyprctl `j/monitors` → rows + caps

/// `row_from_hypr_json` — one monitor object to a row. Returns false when the
/// object carries no name (nameless objects are skipped).
pub fn rowFromHyprJson(mobj: []const u8, out: *MonitorRow) bool {
    out.* = .{};
    if (scanString(mobj, "name")) |n| out.name.set(n);
    if (out.name.empty()) return false;

    const w: i32 = if (jsonNumber(mobj, "width")) |v| @intFromFloat(@trunc(v)) else 0;
    const h: i32 = if (jsonNumber(mobj, "height")) |v| @intFromFloat(@trunc(v)) else 0;
    if (w > 0 and h > 0) {
        var b: [32]u8 = undefined;
        out.resolution.set(std.fmt.bufPrint(&b, "{d}x{d}", .{ w, h }) catch "");
    }
    const hz = jsonNumber(mobj, "refreshRate") orelse jsonNumber(mobj, "refresh") orelse 0;
    if (hz > 0) {
        var b: [32]u8 = undefined;
        out.refresh_rate.set(fmtG(&b, hz));
    }

    const ix: i32 = if (jsonNumber(mobj, "x")) |v| @intFromFloat(@trunc(v)) else 0;
    const iy: i32 = if (jsonNumber(mobj, "y")) |v| @intFromFloat(@trunc(v)) else 0;
    {
        var b: [32]u8 = undefined;
        out.position.set(std.fmt.bufPrint(&b, "{d}x{d}", .{ ix, iy }) catch "");
    }
    if (jsonNumber(mobj, "scale")) |v| {
        var b: [32]u8 = undefined;
        out.scale.set(fmtG(&b, v));
    }
    if (jsonNumber(mobj, "transform")) |v| {
        var b: [16]u8 = undefined;
        out.transform.set(std.fmt.bufPrint(&b, "{d}", .{@as(i32, @intFromFloat(@trunc(v)))}) catch "");
    }
    if (scanBool(mobj, "disabled")) |b| out.disabled = b;
    if (scanString(mobj, "bitDepth")) |s| out.bitdepth.set(s) else if (scanString(mobj, "bitdepth")) |s| out.bitdepth.set(s);
    if (scanString(mobj, "cm")) |s| out.cm.set(hyprCmTokenFromPreset(s));
    if (out.cm.empty()) {
        if (scanString(mobj, "colorManagementPreset")) |s| out.cm.set(hyprCmTokenFromPreset(s));
    }
    if (scanString(mobj, "icc")) |s| out.icc.set(s);
    // hyprctl reports the *current* vrr state as a boolean ("vrr": true), while
    // a config block carries the requested mode as a number. Accept both, or
    // the row is stuck on "Off" for every live output.
    if (jsonNumber(mobj, "vrr")) |v| {
        var b: [16]u8 = undefined;
        out.vrr.set(std.fmt.bufPrint(&b, "{d}", .{@as(i32, @intFromFloat(@trunc(v)))}) catch "");
    } else if (scanBool(mobj, "vrr")) |b| {
        out.vrr.set(if (b) "1" else "0");
    }
    if (scanString(mobj, "mirror")) |s| out.mirror.set(s) else if (scanString(mobj, "mirrorOf")) |s| out.mirror.set(s);

    setG(&out.sdrbrightness, mobj, &.{ "sdrbrightness", "sdrBrightness" });
    setG(&out.sdrsaturation, mobj, &.{ "sdrsaturation", "sdrSaturation" });

    if (jsonNumber(mobj, "sdr_eotf")) |v| {
        setIntStr(&out.sdr_eotf, v);
    } else if (jsonNumber(mobj, "sdrEotf")) |v| {
        setIntStr(&out.sdr_eotf, v);
    } else if (scanString(mobj, "sdr_eotf")) |s| {
        out.sdr_eotf.set(hyprSdrEotfToken(s));
    } else if (scanString(mobj, "sdrEotf")) |s| {
        out.sdr_eotf.set(hyprSdrEotfToken(s));
    }
    if (jsonNumber(mobj, "supports_hdr")) |v| setIntStr(&out.supports_hdr, v) else if (jsonNumber(mobj, "supportsHDR")) |v| setIntStr(&out.supports_hdr, v);
    if (jsonNumber(mobj, "supports_wide_color")) |v| setIntStr(&out.supports_wide_color, v) else if (jsonNumber(mobj, "supportsWideColor")) |v| setIntStr(&out.supports_wide_color, v);
    setG(&out.sdr_min_luminance, mobj, &.{ "sdr_min_luminance", "sdrMinLuminance" });
    setG(&out.sdr_max_luminance, mobj, &.{ "sdr_max_luminance", "sdrMaxLuminance" });
    setG(&out.min_luminance, mobj, &.{ "min_luminance", "minLuminance" });
    if (jsonNumber(mobj, "max_luminance")) |v| setIntStr(&out.max_luminance, v) else if (jsonNumber(mobj, "maxLuminance")) |v| setIntStr(&out.max_luminance, v);
    if (jsonNumber(mobj, "max_avg_luminance")) |v| setIntStr(&out.max_avg_luminance, v) else if (jsonNumber(mobj, "maxAvgLuminance")) |v| setIntStr(&out.max_avg_luminance, v);
    return true;
}

fn setIntStr(field: anytype, v: f64) void {
    var b: [32]u8 = undefined;
    field.set(std.fmt.bufPrint(&b, "{d}", .{@as(i32, @intFromFloat(@trunc(v)))}) catch "");
}

fn setG(dest: anytype, mobj: []const u8, keys: []const []const u8) void {
    for (keys) |k| {
        if (jsonNumber(mobj, k)) |v| {
            var b: [32]u8 = undefined;
            dest.set(fmtG(&b, v));
            return;
        }
    }
}

/// `"%g"` — six significant digits, fixed or exponential, trailing zeros
/// dropped (the `"%g"` contract every rate/scale goes through).
pub fn fmtG(buf: []u8, v: f64) []const u8 {
    if (std.math.isNan(v) or std.math.isInf(v)) return buf[0..0];
    var ebuf: [64]u8 = undefined;
    const e = std.fmt.bufPrint(&ebuf, "{e:.5}", .{v}) catch return buf[0..0];
    const ei = std.mem.indexOfScalar(u8, e, 'e') orelse return copyInto(buf, e);
    const mant = e[0..ei];
    const exp = std.fmt.parseInt(i32, e[ei + 1 ..], 10) catch 0;
    const negative = mant.len > 0 and mant[0] == '-';
    const m = if (negative) mant[1..] else mant;
    var int_part: []const u8 = m;
    var frac_part: []const u8 = "";
    if (std.mem.indexOfScalar(u8, m, '.')) |dot| {
        int_part = m[0..dot];
        frac_part = m[dot + 1 ..];
    }

    if (exp < -4 or exp >= 6) {
        const trimmed = trimZeros(m);
        var n: usize = 0;
        if (negative) {
            buf[n] = '-';
            n += 1;
        }
        @memcpy(buf[n .. n + trimmed.len], trimmed);
        n += trimmed.len;
        if (n + 8 >= buf.len) return buf[0..n];
        buf[n] = 'e';
        n += 1;
        const es = std.fmt.bufPrint(buf[n..], "{d}", .{exp}) catch return buf[0..n];
        return buf[0 .. n + es.len];
    }

    var digits: [40]u8 = undefined;
    const total = int_part.len + frac_part.len;
    if (total > digits.len) return copyInto(buf, m);
    @memcpy(digits[0..int_part.len], int_part);
    @memcpy(digits[int_part.len..total], frac_part[0..]);
    const point: i32 = @as(i32, @intCast(int_part.len)) + exp;

    var out: [64]u8 = undefined;
    var n: usize = 0;
    if (negative) {
        out[n] = '-';
        n += 1;
    }
    var frac_start: usize = 0;
    if (point <= 0) {
        @memcpy(out[n .. n + 2], "0.");
        n += 2;
        var z: i32 = -point;
        while (z > 0) : (z -= 1) {
            out[n] = '0';
            n += 1;
        }
        @memcpy(out[n .. n + total], digits[0..total]);
        n += total;
        frac_start = n - total;
    } else if (point >= @as(i32, @intCast(total))) {
        @memcpy(out[n .. n + total], digits[0..total]);
        n += total;
        var z: i32 = point - @as(i32, @intCast(total));
        while (z > 0) : (z -= 1) {
            out[n] = '0';
            n += 1;
        }
        frac_start = n;
    } else {
        const ip: usize = @intCast(point);
        @memcpy(out[n .. n + ip], digits[0..ip]);
        n += ip;
        out[n] = '.';
        n += 1;
        @memcpy(out[n .. n + (total - ip)], digits[ip..total]);
        n += total - ip;
        frac_start = n - (total - ip);
    }
    // %g drops trailing fractional zeros, then the point itself.
    if (frac_start < n) {
        while (n > frac_start and out[n - 1] == '0') n -= 1;
        if (n > 0 and out[n - 1] == '.') n -= 1;
    }
    return copyInto(buf, out[0..n]);
}

fn trimZeros(s: []const u8) []const u8 {
    var n = s.len;
    while (n > 0 and s[n - 1] == '0') n -= 1;
    if (n > 0 and s[n - 1] == '.') n -= 1;
    return s[0..n];
}

fn copyInto(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

/// `merge_caps_from_hypr_monitor` — capabilities straight off one hyprctl
/// monitor object, then sorted (resolutions, then rates).
pub fn mergeCapsFromHyprMonitor(mobj: []const u8, caps: *OutputCaps) void {
    if (jsonArrayInner(mobj, "availableModes")) |inner| {
        var it = std.mem.splitScalar(u8, inner, '"');
        _ = it.next();
        while (it.next()) |raw| {
            if (raw.len == 0) continue;
            const m = parseHyprModeString(raw);
            caps.addMode(m.w, m.h, m.hz);
            // `splitScalar` alternates: even pieces are outside quotes.
            _ = it.next();
        }
    }
    if (scanBool(mobj, "vrr")) |b| caps.vrr_capable = b;
    if (scanBool(mobj, "hdr")) |b| caps.hdr_hint = b;
    if (scanString(mobj, "colorManagementPreset")) |s| {
        var b: [96]u8 = undefined;
        const sl = lowerCopy(&b, s);
        if (std.mem.indexOf(u8, sl, "hdr") != null) caps.hdr_hint = true;
    }
    if (jsonNumber(mobj, "width")) |v| caps.width = @intFromFloat(@trunc(v));
    if (jsonNumber(mobj, "height")) |v| caps.height = @intFromFloat(@trunc(v));
    caps.current_hz = jsonNumber(mobj, "refreshRate") orelse jsonNumber(mobj, "refresh") orelse 0;
    caps.sortModes();
}

// monitorv2 / lua config bodies

/// `parse_hypr_monitorv2_inner_body`.
pub fn parseV2Inner(inner: []const u8, out: *ParsedBlock) bool {
    out.* = .{};
    var it = std.mem.splitScalar(u8, inner, '\n');
    while (it.next()) |ln| {
        const t = trim(ln);
        if (t.len == 0 or t[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const key = trim(t[0..eq]);
        const val = hyprConfValueToken(t[eq + 1 ..]);
        if (out.keys_len < out.keys.len) {
            out.keys[out.keys_len] = key;
            out.keys_len += 1;
        }
        if (std.mem.eql(u8, key, "output")) {
            out.row.name.set(val);
        } else if (std.mem.eql(u8, key, "disabled")) {
            var b: [8]u8 = undefined;
            const vl = lowerCopy(&b, val);
            out.row.disabled = std.mem.eql(u8, vl, "true") or std.mem.eql(u8, vl, "1") or std.mem.eql(u8, vl, "yes");
        } else if (std.mem.eql(u8, key, "mode")) {
            if (std.mem.indexOfScalar(u8, val, '@')) |at| {
                out.row.resolution.set(trim(val[0..at]));
                out.row.refresh_rate.set(trim(val[at + 1 ..]));
            } else out.row.resolution.set(val);
        } else if (std.mem.eql(u8, key, "position")) out.row.position.set(val) else if (std.mem.eql(u8, key, "scale")) out.row.scale.set(val) else if (std.mem.eql(u8, key, "transform")) out.row.transform.set(val) else if (std.mem.eql(u8, key, "bitdepth")) out.row.bitdepth.set(val) else if (std.mem.eql(u8, key, "cm")) out.row.cm.set(hyprCmTokenFromPreset(val)) else if (std.mem.eql(u8, key, "icc")) out.row.icc.set(val) else if (std.mem.eql(u8, key, "vrr")) out.row.vrr.set(val) else if (std.mem.eql(u8, key, "mirror")) out.row.mirror.set(val) else if (std.mem.eql(u8, key, "sdrbrightness")) out.row.sdrbrightness.set(val) else if (std.mem.eql(u8, key, "sdrsaturation")) out.row.sdrsaturation.set(val) else if (std.mem.eql(u8, key, "sdr_eotf")) out.row.sdr_eotf.set(hyprSdrEotfToken(val)) else if (std.mem.eql(u8, key, "supports_hdr")) out.row.supports_hdr.set(val) else if (std.mem.eql(u8, key, "supports_wide_color")) out.row.supports_wide_color.set(val) else if (std.mem.eql(u8, key, "sdr_min_luminance")) out.row.sdr_min_luminance.set(val) else if (std.mem.eql(u8, key, "sdr_max_luminance")) out.row.sdr_max_luminance.set(val) else if (std.mem.eql(u8, key, "min_luminance")) out.row.min_luminance.set(val) else if (std.mem.eql(u8, key, "max_luminance")) out.row.max_luminance.set(val) else if (std.mem.eql(u8, key, "max_avg_luminance")) out.row.max_avg_luminance.set(val);
    }
    return !out.row.name.empty();
}

/// Copy every key `p` mentions onto `base` — an overlay that leaves keys the
/// file never wrote untouched.
pub fn overlayFileFields(base: *MonitorRow, p: *const ParsedBlock) void {
    inline for (.{ "disabled", "position", "scale", "transform", "bitdepth", "cm", "icc", "vrr", "mirror", "sdrbrightness", "sdrsaturation", "sdr_eotf", "supports_hdr", "supports_wide_color", "sdr_min_luminance", "sdr_max_luminance", "min_luminance", "max_luminance", "max_avg_luminance" }) |key| {
        if (p.has(key)) {
            if (std.mem.eql(u8, key, "disabled")) {
                base.disabled = p.row.disabled;
            } else {
                setFieldByKey(base, key, &p.row);
            }
        }
    }
    if (p.has("mode")) {
        if (!p.row.resolution.empty()) base.resolution.set(p.row.resolution.slice());
        if (!p.row.refresh_rate.empty()) base.refresh_rate.set(p.row.refresh_rate.slice());
    }
}

fn setFieldByKey(base: *MonitorRow, key: []const u8, src: *const MonitorRow) void {
    inline for (.{ "position", "scale", "transform", "bitdepth", "cm", "icc", "vrr", "mirror", "sdrbrightness", "sdrsaturation", "sdr_eotf", "supports_hdr", "supports_wide_color", "sdr_min_luminance", "sdr_max_luminance", "min_luminance", "max_luminance", "max_avg_luminance" }) |k| {
        if (std.mem.eql(u8, key, k)) {
            @field(base, k).set(@field(src, k).slice());
        }
    }
}

const BlockStyle = enum { lua, v2 };

fn opener(style: BlockStyle) []const u8 {
    return switch (style) {
        .lua => "hl.monitor(",
        .v2 => "monitorv2",
    };
}

/// Inner bodies of every `monitorv2 { … }` / `hl.monitor({ … })` block, as
/// slices of `content` (no copy — the caller parses them immediately).
pub fn extractBodies(
    alloc: std.mem.Allocator,
    content: []const u8,
    style: BlockStyle,
    out: *std.ArrayList([]const u8),
) !void {
    var pos: usize = 0;
    while (pos < content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, pos, '\n');
        const line_end = nl orelse content.len;
        const t = trim(content[pos..line_end]);
        const is_start = std.mem.startsWith(u8, t, opener(style)) and
            std.mem.indexOfScalar(u8, t, '{') != null;
        const body_begin = if (nl) |n| n + 1 else content.len;
        if (is_start) {
            var brace: i32 = 1;
            var p = body_begin;
            while (p < content.len and brace > 0) {
                const n2 = std.mem.indexOfScalarPos(u8, content, p, '\n');
                const le = n2 orelse content.len;
                for (content[p..le]) |ch| {
                    if (ch == '{') brace += 1 else if (ch == '}') brace -= 1;
                }
                p = if (n2) |x| x + 1 else content.len;
            }
            if (p > body_begin) try out.append(alloc, content[body_begin..p]);
            pos = p;
            continue;
        }
        pos = if (nl) |n| n + 1 else content.len;
    }
}

/// Drop every monitor block (and the legacy `monitor=` / `monitor:` lines),
/// keeping the preamble. Blank separator lines between two removed blocks go
/// too, so the preamble cannot grow on a load→strip→save cycle.
pub fn stripBlocks(
    alloc: std.mem.Allocator,
    content: []const u8,
    style: BlockStyle,
) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    if (content.len > 0) {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |ln| try lines.append(alloc, ln);
        if (std.mem.endsWith(u8, content, "\n")) _ = lines.pop();
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < lines.items.len) {
        const t = trim(lines.items[i]);
        if (style == .v2 and std.mem.startsWith(u8, t, "monitor=")) {
            i += 1;
            while (i < lines.items.len and std.mem.startsWith(u8, trim(lines.items[i]), "monitor:")) i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, t, opener(style)) and std.mem.indexOfScalar(u8, t, '{') != null) {
            i += 1;
            var brace: i32 = 1;
            while (i < lines.items.len and brace > 0) : (i += 1) {
                for (lines.items[i]) |ch| {
                    if (ch == '{') brace += 1 else if (ch == '}') brace -= 1;
                }
            }
            var j = i;
            while (j < lines.items.len and trim(lines.items[j]).len == 0) j += 1;
            const nt = if (j < lines.items.len) trim(lines.items[j]) else "";
            if (std.mem.startsWith(u8, nt, opener(style)) and std.mem.indexOfScalar(u8, nt, '{') != null) {
                i = j;
                continue;
            }
            while (i < j) : (i += 1) try out.appendSlice(alloc, lines.items[i]);
            continue;
        }
        try out.appendSlice(alloc, lines.items[i]);
        try out.append(alloc, '\n');
        i += 1;
    }
    return try out.toOwnedSlice(alloc);
}

/// Inner body of an `hl.monitor({ … })` → `key = value` lines.
pub fn luaInnerToHyprlang(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |raw_ln| {
        var ln = raw_ln;
        if (std.mem.indexOf(u8, ln, "--")) |dd| ln = ln[0..dd];
        var t = trim(ln);
        if (t.len == 0) continue;
        if (t[t.len - 1] == ',') t = trim(t[0 .. t.len - 1]);
        if (t.len == 0) continue;
        try out.appendSlice(alloc, t);
        try out.append(alloc, '\n');
    }
    return try out.toOwnedSlice(alloc);
}

/// Rebuild one row's config block.
pub fn buildBlock(alloc: std.mem.Allocator, m: *const MonitorRow, style: BlockStyle) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    errdefer o.deinit(alloc);
    switch (style) {
        .v2 => try o.appendSlice(alloc, "monitorv2 {\n"),
        .lua => try o.appendSlice(alloc, "hl.monitor({\n"),
    }
    const q = style == .lua;
    const comma: []const u8 = if (q) "," else "";

    if (q) {
        try emitKV(&o, alloc, "output", m.name.slice(), true, comma);
    } else if (std.mem.indexOfAny(u8, m.name.slice(), " \t") != null) {
        try o.appendSlice(alloc, "  output = \"");
        try o.appendSlice(alloc, m.name.slice());
        try o.appendSlice(alloc, "\"\n");
    } else {
        try o.appendSlice(alloc, "  output = ");
        try o.appendSlice(alloc, m.name.slice());
        try o.append(alloc, '\n');
    }

    if (m.disabled) {
        try o.appendSlice(alloc, "  disabled = true");
        try o.appendSlice(alloc, comma);
        try o.append(alloc, '\n');
    } else {
        if (!m.resolution.empty()) {
            try o.appendSlice(alloc, "  mode = ");
            if (q) try o.append(alloc, '"');
            try o.appendSlice(alloc, m.resolution.slice());
            if (!m.refresh_rate.empty()) {
                try o.append(alloc, '@');
                try o.appendSlice(alloc, m.refresh_rate.slice());
            }
            if (q) try o.append(alloc, '"');
            try o.appendSlice(alloc, comma);
            try o.append(alloc, '\n');
        }
        try emitKV(&o, alloc, "position", m.position.slice(), q, comma);
        if (!m.scale.empty() and !m.scale.eql("1")) try emitKV(&o, alloc, "scale", m.scale.slice(), false, comma);
        if (!m.transform.empty() and !m.transform.eql("0")) try emitKV(&o, alloc, "transform", m.transform.slice(), false, comma);
        if (!m.bitdepth.empty()) try emitKV(&o, alloc, "bitdepth", m.bitdepth.slice(), false, comma);
        if (!m.cm.empty()) try emitKV(&o, alloc, "cm", m.cm.slice(), true, comma);
        if (!m.icc.empty()) try emitKV(&o, alloc, "icc", m.icc.slice(), true, comma);
        if (!m.vrr.empty() and !m.vrr.eql("0")) try emitKV(&o, alloc, "vrr", m.vrr.slice(), false, comma);
        if (!m.mirror.empty()) {
            const quote = q or std.mem.indexOfAny(u8, m.mirror.slice(), " \t") != null;
            try emitKV(&o, alloc, "mirror", m.mirror.slice(), quote, comma);
        }
        inline for (.{ "sdrbrightness", "sdrsaturation", "supports_hdr", "supports_wide_color", "sdr_min_luminance", "sdr_max_luminance", "min_luminance", "max_luminance", "max_avg_luminance" }) |key| {
            const v = @field(m, key).slice();
            if (v.len > 0) try emitKV(&o, alloc, key, v, false, comma);
        }
        if (!m.sdr_eotf.empty()) {
            if (q) {
                var eotf: []const u8 = "default";
                if (m.sdr_eotf.eql("1")) eotf = "srgb" else if (m.sdr_eotf.eql("2")) eotf = "gamma22";
                try emitKV(&o, alloc, "sdr_eotf", eotf, true, comma);
            } else {
                try emitKV(&o, alloc, "sdr_eotf", m.sdr_eotf.slice(), false, comma);
            }
        }
    }
    try o.appendSlice(alloc, if (q) "})\n" else "}\n");
    return try o.toOwnedSlice(alloc);
}

fn emitKV(
    o: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    key: []const u8,
    val: []const u8,
    quote: bool,
    comma: []const u8,
) !void {
    if (val.len == 0) return;
    try o.appendSlice(alloc, "  ");
    try o.appendSlice(alloc, key);
    try o.appendSlice(alloc, " = ");
    if (quote) try o.append(alloc, '"');
    try o.appendSlice(alloc, val);
    if (quote) try o.append(alloc, '"');
    try o.appendSlice(alloc, comma);
    try o.append(alloc, '\n');
}

// State

pub const State = struct {
    kind: compositor.Kind = .unknown,
    outputs: [max_outputs]MonitorRow = @as([max_outputs]MonitorRow, @splat(.{})),
    outputs_len: usize = 0,
    caps: [max_outputs]CapEntry = @as([max_outputs]CapEntry, @splat(.{})),
    caps_len: usize = 0,
    conf_path: Str(path_cap) = .{},
    /// Everything before the first monitor block, as read.
    preamble: ?[]u8 = null,
    status: Str(status_cap) = .{},
    dirty: bool = false,
    selected: usize = 0,
    baseline_outputs: [max_outputs]MonitorRow = @as([max_outputs]MonitorRow, @splat(.{})),
    baseline_outputs_len: usize = 0,
    baseline_preamble: ?[]u8 = null,
    did_refresh: bool = false,

    // Canvas / form interaction.
    zoom: f64 = 1.0,
    pan_x: f64 = 0,
    pan_y: f64 = 0,
    layout_ready: bool = false,
    geom_w: i32 = 0,
    geom_h: i32 = 0,
    drag_idx: i32 = -1,
    anchor_x: i32 = 0,
    anchor_y: i32 = 0,
    press_x: f64 = 0,
    press_y: f64 = 0,
    pan_armed: bool = false,
    pan_grab_x: f64 = 0,
    pan_grab_y: f64 = 0,
    scale_drag: bool = false,
    hypr_slider: i32 = -1,
    drag_norm_t: f64 = 0,
    active_dd: i32 = -1,
    dd_hover_row: i32 = -1,
    /// Fit frozen while a position drag runs.
    fz_valid: bool = false,
    fz_min_x: f64 = 0,
    fz_min_y: f64 = 0,
    fz_sf: f64 = 1,
    fz_w: i32 = 0,
    fz_h: i32 = 0,
    fz_n: usize = 0,

    gpa: std.mem.Allocator = std.heap.page_allocator,
    io: std.Io = undefined,
    env: ?*const std.process.Environ.Map = null,

    pub fn deinit(self: *State) void {
        self.freePreamble(&self.preamble);
        self.freePreamble(&self.baseline_preamble);
    }

    fn freePreamble(self: *State, slot: *?[]u8) void {
        if (slot.*) |p| {
            self.gpa.free(p);
            slot.* = null;
        }
    }

    pub fn row(self: *State, i: usize) *MonitorRow {
        return &self.outputs[i];
    }

    pub fn capsFor(self: *State, name: []const u8) ?*OutputCaps {
        for (self.caps[0..self.caps_len]) |*e| {
            if (e.name.eql(name)) return &e.caps;
        }
        return null;
    }

    pub fn capsForIdx(self: *State, i: usize) ?*OutputCaps {
        if (i >= self.outputs_len) return null;
        return self.capsFor(self.outputs[i].name.slice());
    }

    /// Insert (or replace) one output's capability table.
    pub fn pushCap(self: *State, name: []const u8, oc: OutputCaps) void {
        if (self.caps_len >= max_outputs) return;
        for (self.caps[0..self.caps_len]) |*e| {
            if (e.name.eql(name)) {
                e.caps = oc;
                return;
            }
        }
        self.caps[self.caps_len].name.set(name);
        self.caps[self.caps_len].caps = oc;
        self.caps_len += 1;
    }

    fn setPreamble(self: *State, slot: *?[]u8, s: []const u8) void {
        self.freePreamble(slot);
        if (s.len == 0) return;
        slot.* = self.gpa.dupe(u8, s) catch null;
    }

    pub fn supportsColorHdrUi(self: *const State) bool {
        return self.kind == .hyprland;
    }

    pub fn supportsBitdepthUi(self: *const State) bool {
        return self.kind == .hyprland or self.kind == .niri;
    }

    // -- refresh ----------------------------------------------------------

    /// Re-read the compositor and the config file. Resets edit state.
    pub fn refresh(self: *State) void {
        self.dirty = false;
        self.status.clear();
        self.outputs_len = 0;
        self.caps_len = 0;
        self.freePreamble(&self.preamble);
        self.selected = 0;
        self.active_dd = -1;
        self.dd_hover_row = -1;
        self.scale_drag = false;
        self.hypr_slider = -1;
        self.drag_idx = -1;
        self.pan_armed = false;
        self.zoom = 1.0;
        self.layout_ready = false;
        self.fz_valid = false;
        self.kind = compositor.kind();
        self.did_refresh = true;

        const env = self.env orelse {
            self.status.set("No environment attached");
            self.captureBaseline();
            return;
        };
        const home = env.get("HOME") orelse {
            self.status.set("HOME not set");
            self.captureBaseline();
            return;
        };
        if (self.kind != .hyprland) {
            self.status.set("Compositor not supported for monitor config (Hyprland, Niri, or Mango required)");
            self.captureBaseline();
            return;
        }

        const lua = luaConfigActive(home);
        var pbuf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(
            &pbuf,
            "{s}/.config/hypr/{s}",
            .{ home, if (lua) "monitors.lua" else "monitors.conf" },
        ) catch {
            self.status.set("Config path too long");
            self.captureBaseline();
            return;
        };
        self.conf_path.set(path);

        if (hypr_ipc.ipcRequest(self.gpa, self.io, env, "j/monitors")) |text| {
            defer self.gpa.free(text);
            self.applyHyprJson(text);
        }

        const cwd = std.Io.Dir.cwd();
        const content = cwd.readFileAlloc(self.io, path, self.gpa, .limited(1 << 20)) catch "";
        if (content.len > 0) {
            defer self.gpa.free(content);
            self.applyConfFile(content, lua);
        } else if (self.outputs_len == 0) {
            self.status.set("No monitors from hyprctl (is Hyprland running?) and no monitor blocks in config");
        }
        if (self.selected >= self.outputs_len) self.selected = 0;
        self.captureBaseline();
    }

    /// hyprctl `j/monitors` → rows + capability table.
    pub fn applyHyprJson(self: *State, doc: []const u8) void {
        const inner = jsonRootArrayInner(doc) orelse return;
        var objs: [16][]const u8 = undefined;
        const n = splitTopObjects(inner, &objs);
        for (objs[0..n]) |mobj| {
            if (self.outputs_len >= max_outputs) break;
            var r: MonitorRow = .{};
            if (!rowFromHyprJson(mobj, &r)) continue;
            var oc: OutputCaps = .{};
            mergeCapsFromHyprMonitor(mobj, &oc);
            self.outputs[self.outputs_len] = r;
            self.outputs_len += 1;
            self.pushCap(r.name.slice(), oc);
        }
    }

    /// The config file's monitor bodies over the rows hyprctl reported (or a
    /// fresh list when hyprctl had nothing).
    pub fn applyConfFile(self: *State, content: []const u8, lua: bool) void {
        const style: BlockStyle = if (lua) .lua else .v2;
        const stripped = stripBlocks(self.gpa, content, style) catch return;
        defer self.gpa.free(stripped);
        self.setPreamble(&self.preamble, trimLeadingBlankLines(stripped));

        var bodies: std.ArrayList([]const u8) = .empty;
        defer bodies.deinit(self.gpa);
        extractBodies(self.gpa, content, style, &bodies) catch return;

        const had_json = self.outputs_len > 0;
        for (bodies.items) |body| {
            var hypr_buf: ?[]u8 = null;
            defer if (hypr_buf) |b| self.gpa.free(b);
            var src: []const u8 = body;
            if (lua) {
                const conv = luaInnerToHyprlang(self.gpa, body) catch continue;
                hypr_buf = conv;
                src = conv;
            }
            var pb: ParsedBlock = .{};
            if (!parseV2Inner(src, &pb)) continue;
            if (had_json) {
                for (self.outputs[0..self.outputs_len]) |*existing| {
                    if (existing.name.eql(pb.row.name.slice())) {
                        overlayFileFields(existing, &pb);
                        break;
                    }
                }
            } else {
                if (self.outputs_len >= max_outputs) break;
                self.outputs[self.outputs_len] = pb.row;
                self.outputs_len += 1;
                if (self.capsFor(pb.row.name.slice()) == null) self.pushCap(pb.row.name.slice(), .{});
            }
        }
    }

    // -- save / revert ----------------------------------------------------

    /// Write `preamble + blocks` and ask the compositor to reload. Returns
    /// false (with `status` set) on any failure.
    pub fn saveAndReload(self: *State) bool {
        if (self.kind != .hyprland) {
            self.status.set("Unsupported compositor");
            return false;
        }
        if (self.conf_path.empty()) {
            self.status.set("No config path");
            return false;
        }
        const env = self.env orelse {
            self.status.set("No environment attached");
            return false;
        };
        const home = env.get("HOME") orelse {
            self.status.set("HOME not set");
            return false;
        };
        const lua = luaConfigActive(home);
        const style: BlockStyle = if (lua) .lua else .v2;
        const pre = trimLeadingBlankLines(self.preamble orelse "");

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        body.appendSlice(self.gpa, pre) catch {
            self.status.set("Out of memory");
            return false;
        };
        if (pre.len > 0 and pre[pre.len - 1] != '\n') body.append(self.gpa, '\n') catch {};
        for (self.outputs[0..self.outputs_len]) |*m| {
            const blk = buildBlock(self.gpa, m, style) catch continue;
            defer self.gpa.free(blk);
            body.appendSlice(self.gpa, blk) catch {};
        }

        const path = self.conf_path.slice();
        const cwd = std.Io.Dir.cwd();
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |sl| {
            cwd.createDirPath(self.io, path[0..sl]) catch {};
        }
        cwd.writeFile(self.io, .{ .sub_path = path, .data = body.items }) catch {
            self.status.set(if (lua) "Failed to write monitors.lua" else "Failed to write monitors.conf");
            return false;
        };

        if (hypr_ipc.ipcRequest(self.gpa, self.io, env, "reload")) |reply| {
            self.gpa.free(reply);
        }

        self.dirty = false;
        self.setPreamble(&self.preamble, pre);
        self.status.clear();
        self.captureBaseline();
        return true;
    }

    /// Drop every edit made since the last refresh/save.
    pub fn revertEdits(self: *State) void {
        @memcpy(self.outputs[0..max_outputs], self.baseline_outputs[0..max_outputs]);
        self.outputs_len = self.baseline_outputs_len;
        self.freePreamble(&self.preamble);
        if (self.baseline_preamble) |p| {
            self.preamble = self.gpa.dupe(u8, p) catch null;
        }
        self.dirty = false;
        self.status.clear();
        if (self.selected >= self.outputs_len) self.selected = 0;
    }

    pub fn captureBaseline(self: *State) void {
        @memcpy(self.baseline_outputs[0..max_outputs], self.outputs[0..max_outputs]);
        self.baseline_outputs_len = self.outputs_len;
        self.freePreamble(&self.baseline_preamble);
        if (self.preamble) |p| {
            self.baseline_preamble = self.gpa.dupe(u8, p) catch null;
        }
    }

    /// Detached `systemctl --user restart …` for both portal services.
    pub fn restartPortals(self: *State) void {
        autostart.spawnDetached(self.io, &.{
            "/bin/sh",
            "-c",
            "systemctl --user restart xdg-desktop-portal && systemctl --user restart xdg-desktop-portal-hyprland",
        }) catch return;
    }
};

/// `hyprland_lua_config_active` — plain existence of `~/.config/hypr/hyprland.lua`.
pub fn luaConfigActive(home: []const u8) bool {
    // One pass into a null-terminated buffer: writing the path into `buf`
    // and then re-printing that slice back into `buf` would make the source
    // and destination of the copy the same memory.
    var buf: [1024]u8 = undefined;
    const z: [:0]const u8 = std.fmt.bufPrintSentinel(&buf, "{s}/.config/hypr/hyprland.lua", .{home}, 0) catch return false;
    return std.c.access(@ptrCast(z.ptr), std.c.R_OK) == 0;
}

// Tests

test "monitors-state: mode strings parse to width/height/hz" {
    const t = std.testing;
    const m = parseHyprModeString("2560x1440@239.97Hz");
    try t.expectEqual(@as(i32, 2560), m.w);
    try t.expectEqual(@as(i32, 1440), m.h);
    try t.expect(std.math.approxEqAbs(f64, 239.97, m.hz, 0.001));
    const bare = parseHyprModeString("1920x1080");
    try t.expectEqual(@as(i32, 1920), bare.w);
    try t.expectEqual(@as(f64, 0), bare.hz);
    try t.expectEqual(@as(i32, 0), parseHyprModeString("preferred").w);
}

test "monitors-state: caps derive unique sorted resolutions and rates" {
    const t = std.testing;
    var oc: OutputCaps = .{};
    oc.addMode(1920, 1080, 60);
    oc.addMode(1920, 1080, 144);
    oc.addMode(2560, 1440, 60);
    oc.addMode(1920, 1080, 60);
    oc.addMode(1920, 1080, 0);
    oc.sortModes();
    try t.expectEqual(@as(usize, 2), oc.n_res);
    try t.expectEqualStrings("2560x1440", oc.resolution(0));
    try t.expectEqualStrings("1920x1080", oc.resolution(1));
    try t.expectEqual(@as(usize, 2), oc.hzList(1).len);
    try t.expect(std.math.approxEqAbs(f64, 144, oc.hzList(1)[0], 0.001));
    try t.expectEqual(@as(usize, 1), oc.hzList(0).len);
}

const fixture_json =
    \\[{"id":0,"name":"DP-1","make":"AOC","model":"27G2","description":"AOC 27G2","width":2560,"height":1440,"refreshRate":239.969997,"x":2560,"y":0,"scale":1.25,"transform":0,"disabled":false,"vrr":true,"hdr":false,"mirrorOf":"","bitDepth":"10","availableModes":["2560x1440@239.97Hz","2560x1440@144Hz","1920x1080@60Hz"]},
    \\ {"id":1,"name":"HDMI-A-1","make":"DEL","model":"U2720Q","description":"","width":1920,"height":1080,"refreshRate":60.000000,"x":0,"y":0,"scale":1,"transform":0,"disabled":false,"vrr":false,"mirrorOf":"","availableModes":["1920x1080@60Hz","1280x720@60Hz"]}]
;

test "monitors-state: hyprctl json becomes rows and caps" {
    const t = std.testing;
    var s = State{ .gpa = t.allocator };
    defer s.deinit();
    s.applyHyprJson(fixture_json);
    try t.expectEqual(@as(usize, 2), s.outputs_len);
    try t.expectEqualStrings("DP-1", s.outputs[0].name.slice());
    try t.expectEqualStrings("2560x1440", s.outputs[0].resolution.slice());
    try t.expectEqualStrings("2560x0", s.outputs[0].position.slice());
    try t.expectEqualStrings("1.25", s.outputs[0].scale.slice());
    try t.expectEqualStrings("10", s.outputs[0].bitdepth.slice());
    try t.expectEqualStrings("HDMI-A-1", s.outputs[1].name.slice());
    // hyprctl ships vrr as a *boolean*; both must land on the row.
    try t.expectEqualStrings("1", s.outputs[0].vrr.slice());
    try t.expectEqualStrings("0", s.outputs[1].vrr.slice());
    const oc = s.capsFor("DP-1").?;
    try t.expectEqual(@as(usize, 2), oc.n_res);
    try t.expect(oc.vrr_capable);
    try t.expect(!oc.hdr_hint);
    try t.expectEqual(@as(i32, 2560), oc.width);
    try t.expect(std.math.approxEqAbs(f64, 239.97, oc.current_hz, 0.01));
    // Refresh rate is "%g" of the JSON float.
    try t.expectEqualStrings("239.97", s.outputs[0].refresh_rate.slice());
}

test "monitors-state: lua block round trips through strip, extract and overlay" {
    const t = std.testing;
    var s = State{ .gpa = t.allocator };
    defer s.deinit();
    s.applyHyprJson(fixture_json);

    const file =
        \\-- monitors, edited by hand
        \\local dpi = 96
        \\
        \\hl.monitor({
        \\  output = "DP-1",
        \\  mode = "2560x1440@144",
        \\  position = "0x0",
        \\  scale = 1,
        \\  cm = "hdr",
        \\})
        \\
        \\hl.monitor({
        \\  output = "HDMI-A-1",
        \\  disabled = true,
        \\})
    ;
    s.applyConfFile(file, true);

    // Preamble keeps the hand-written lines and drops every block.
    const pre = s.preamble.?;
    try t.expect(std.mem.indexOf(u8, pre, "local dpi = 96") != null);
    try t.expect(std.mem.indexOf(u8, pre, "hl.monitor") == null);

    // Overlay landed on the hyprctl rows in file order.
    try t.expectEqualStrings("2560x1440", s.outputs[0].resolution.slice());
    try t.expectEqualStrings("144", s.outputs[0].refresh_rate.slice());
    try t.expectEqualStrings("0x0", s.outputs[0].position.slice());
    try t.expectEqualStrings("hdr", s.outputs[0].cm.slice());
    try t.expect(s.outputs[1].disabled);

    // Saving rebuilds both blocks from the merged rows.
    const blk = try buildBlock(t.allocator, &s.outputs[0], .lua);
    defer t.allocator.free(blk);
    try t.expect(std.mem.indexOf(u8, blk, "hl.monitor({") != null);
    try t.expect(std.mem.indexOf(u8, blk, "output = \"DP-1\"") != null);
    try t.expect(std.mem.indexOf(u8, blk, "mode = \"2560x1440@144\"") != null);
    try t.expect(std.mem.indexOf(u8, blk, "position = \"0x0\"") != null);
    try t.expect(std.mem.indexOf(u8, blk, "cm = \"hdr\"") != null);
    try t.expect(std.mem.indexOf(u8, blk, "scale") == null); // scale 1 is omitted

    const blk1 = try buildBlock(t.allocator, &s.outputs[1], .lua);
    defer t.allocator.free(blk1);
    try t.expect(std.mem.indexOf(u8, blk1, "disabled = true") != null);

    // Stripping the rebuilt file leaves exactly the original preamble: the
    // load→strip→save cycle must not grow the leading section.
    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(t.allocator);
    try rebuilt.appendSlice(t.allocator, pre);
    try rebuilt.appendSlice(t.allocator, blk);
    try rebuilt.appendSlice(t.allocator, blk1);
    const again = try stripBlocks(t.allocator, rebuilt.items, .lua);
    defer t.allocator.free(again);
    try t.expectEqualStrings(trimLeadingBlankLines(pre), trimLeadingBlankLines(again));
}

test "monitors-state: monitorv2 conf blocks strip and parse" {
    const t = std.testing;
    var s = State{ .gpa = t.allocator };
    defer s.deinit();
    s.applyHyprJson(fixture_json);

    const file =
        \\# my monitors
        \\monitor=DP-1,2560x1440@144,0x0,1
        \\monitorv2 {
        \\  output = DP-1
        \\  mode = 2560x1440@144
        \\  position = 100x0
        \\  scale = 1.5
        \\  bitdepth = 10
        \\}
        \\
        \\monitorv2 {
        \\  output = HDMI-A-1
        \\  disabled = true
        \\}
    ;
    s.applyConfFile(file, false);
    try t.expectEqualStrings("100x0", s.outputs[0].position.slice());
    try t.expectEqualStrings("1.5", s.outputs[0].scale.slice());
    try t.expectEqualStrings("144", s.outputs[0].refresh_rate.slice());
    try t.expect(s.outputs[1].disabled);
    try t.expect(std.mem.indexOf(u8, s.preamble.?, "monitorv2") == null);
    try t.expect(std.mem.indexOf(u8, s.preamble.?, "monitor =") == null);
    try t.expect(std.mem.indexOf(u8, s.preamble.?, "# my monitors") != null);

    const blk = try buildBlock(t.allocator, &s.outputs[0], .v2);
    defer t.allocator.free(blk);
    try t.expect(std.mem.startsWith(u8, blk, "monitorv2 {\n"));
    try t.expect(std.mem.indexOf(u8, blk, "scale = 1.5\n") != null);
    try t.expect(std.mem.indexOf(u8, blk, "bitdepth = 10\n") != null);
    try t.expect(std.mem.indexOf(u8, blk, "})") == null);
}

test "monitors-state: token normalizers produce the specified forms" {
    const t = std.testing;
    try t.expectEqualStrings("dcip3", hyprCmTokenFromPreset("DCI-P3"));
    try t.expectEqualStrings("hdredid", hyprCmTokenFromPreset("HDR EDID"));
    try t.expectEqualStrings("hdr", hyprCmTokenFromPreset("hdr"));
    try t.expectEqualStrings("srgb", hyprCmTokenFromPreset("sRGB"));
    try t.expectEqualStrings("", hyprCmTokenFromPreset("banana"));
    try t.expectEqualStrings("", hyprSdrEotfToken("default"));
    try t.expectEqualStrings("1", hyprSdrEotfToken("srgb"));
    try t.expectEqualStrings("2", hyprSdrEotfToken("gamma2.2"));
    try t.expectEqualStrings("DP-1", hyprConfValueToken("  \"DP-1\" # primary \n"));
    try t.expectEqualStrings("2560x1440", hyprConfValueToken("2560x1440"));
}

test "monitors-state: revert restores the captured baseline" {
    const t = std.testing;
    var s = State{ .gpa = t.allocator };
    defer s.deinit();
    s.applyHyprJson(fixture_json);
    s.preamble = try t.allocator.dupe(u8, "-- kept\n");
    s.captureBaseline();

    s.outputs[0].position.set("500x500");
    s.outputs[0].disabled = true;
    s.dirty = true;
    s.status.set("edited");
    s.freePreamble(&s.preamble);
    s.preamble = try t.allocator.dupe(u8, "-- clobbered\n");

    s.revertEdits();
    try t.expectEqualStrings("2560x0", s.outputs[0].position.slice());
    try t.expect(!s.outputs[0].disabled);
    try t.expect(!s.dirty);
    try t.expect(s.status.empty());
    try t.expectEqualStrings("-- kept\n", s.preamble.?);
}

test "monitors-state: an unsupported compositor reports instead of writing" {
    const t = std.testing;
    var s = State{ .gpa = t.allocator, .kind = .sway };
    defer s.deinit();
    s.conf_path.set("/tmp/should-not-be-written");
    try t.expect(!s.saveAndReload());
    try t.expect(std.mem.indexOf(u8, s.status.slice(), "Unsupported") != null);
}

test "monitors-state: the lua config probe formats its path in one pass" {
    const t = std.testing;
    // Regression: the path was printed into `buf` and then re-printed from
    // `buf` back into `buf`, which is an overlapping @memcpy and panics the
    // moment the Monitors tab is opened.
    try t.expect(!luaConfigActive("/nonexistent-eh-lua-probe"));
}

test "monitors-state: config alone seeds rows when hyprctl gave nothing" {
    const t = std.testing;
    var s = State{ .gpa = t.allocator };
    defer s.deinit();
    // No applyHyprJson: hyprctl may be unreachable (locked session, socket
    // gone) and the config is still the source of truth for the user.
    s.applyConfFile(
        \\hl.monitor({
        \\  output = "DP-1",
        \\  mode = "2560x1440@239.97",
        \\  position = "2560x0",
        \\  bitdepth = 10,
        \\  cm = "srgb",
        \\  mirror = "none",
        \\  sdrbrightness = 1,
        \\  sdrsaturation = 1,
        \\  sdr_min_luminance = 0.2,
        \\  sdr_max_luminance = 400,
        \\  min_luminance = 0.0005,
        \\  max_luminance = 1434,
        \\  max_avg_luminance = 2000,
        \\})
        \\hl.monitor({
        \\  output = "DP-2",
        \\  mode = "2560x1440@180",
        \\  position = "0x0",
        \\  cm = "srgb",
        \\})
    , true);

    try t.expectEqual(@as(usize, 2), s.outputs_len);
    try t.expectEqualStrings("DP-1", s.outputs[0].name.slice());
    try t.expectEqualStrings("2560x1440", s.outputs[0].resolution.slice());
    try t.expectEqualStrings("239.97", s.outputs[0].refresh_rate.slice());
    try t.expectEqualStrings("2560x0", s.outputs[0].position.slice());
    // Unquoted numeric keys must survive the lua -> hyprlang conversion.
    try t.expectEqualStrings("10", s.outputs[0].bitdepth.slice());
    try t.expectEqualStrings("400", s.outputs[0].sdr_max_luminance.slice());
    try t.expectEqualStrings("0.0005", s.outputs[0].min_luminance.slice());
    try t.expectEqualStrings("1434", s.outputs[0].max_luminance.slice());
    try t.expectEqualStrings("srgb", s.outputs[0].cm.slice());
    try t.expectEqualStrings("180", s.outputs[1].refresh_rate.slice());
    try t.expectEqualStrings("0x0", s.outputs[1].position.slice());
    // Caps exist so the resolution/refresh combos have something to show.
    try t.expect(s.capsFor("DP-1") != null);
    try t.expect(s.capsFor("DP-2") != null);
    // The blocks are gone from the preamble, so saving cannot duplicate them
    // (a file with no hand-written preamble keeps it null).
    if (s.preamble) |pre| try t.expect(std.mem.indexOf(u8, pre, "hl.monitor") == null);
}

test "monitors-state: the config overlays the live hyprctl rows" {
    const t = std.testing;
    var s = State{ .gpa = t.allocator };
    defer s.deinit();
    s.applyHyprJson(fixture_json);
    const n = s.outputs_len;
    s.applyConfFile(
        \\hl.monitor({
        \\  output = "DP-1",
        \\  mode = "2560x1440@144",
        \\  position = "0x0",
        \\  vrr = 2,
        \\})
    , true);
    try t.expectEqual(n, s.outputs_len);
    try t.expectEqualStrings("144", s.outputs[0].refresh_rate.slice());
    try t.expectEqualStrings("0x0", s.outputs[0].position.slice());
    try t.expectEqualStrings("2", s.outputs[0].vrr.slice());
    // Untouched by the block: the live mode and the other output.
    try t.expectEqualStrings("2560x1440", s.outputs[0].resolution.slice());
    try t.expectEqualStrings("HDMI-A-1", s.outputs[1].name.slice());
}
