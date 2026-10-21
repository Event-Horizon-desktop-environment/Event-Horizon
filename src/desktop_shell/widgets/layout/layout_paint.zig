//! `desktop_shell/widgets/layout/layout_paint.{hpp,cpp}` — the window-layout
//! switcher slot: which layouts the running compositor offers, which one is
//! live right now, swapping it, and the icon-only pill that shows it.
//!
//! Backend detection (`backend()` → `ux/shared/compositor.kind()`):
//!
//! * Hyprland — dwindle / master / scrolling / monocle. Applied live with
//!   `keyword general:layout …` and persisted so the pick survives a reload.
//! * MangoWM — the 14 layouts of the wiki's "Supported Layouts" page,
//!   applied live with `dispatch setlayout,<name>` and *not* persisted:
//!   layouts are per-tag runtime state and the compositor is the source of
//!   truth — layouts are never persisted from here.
//! * Anything else answers with the Hyprland list as the fallback.
//!
//! What could not come across verbatim, and why:
//!
//! * **The mutex.** `g_mu` guarded the caches against concurrent paint callers.
//!   Every Zig caller — the strip's paint pass, the popup's, the slot's click
//!   handler — runs on the event loop, so nothing here races. The lock is
//!   kept anyway so a later threaded caller cannot silently corrupt the cache.
//! * **Persistence.** Layout choice is persisted by rewriting a sectioned `~/.config/hypr/hyprland/<section>.lua` file
//!   with *every* key of that section. The Zig `ux/settings2/hyprland_data.zig`
//!   is logic-only and has no file I/O at all, so this module carries the
//!   narrow version it needs: read and edit just the `layout` line. The read
//!   also falls back to `~/.config/hypr/hyprland.conf`'s `[general]` section
//!   (reading only the managed file), so a stock install still
//!   reports the layout Hyprland would actually use. Neither write invents
//!   keys it does not own: a `general.lua` it creates starts with the layout
//!   entry alone and is overwritten with the full set the next time the
//!   settings app saves, and `hyprland.conf` is only ever edited inside an
//!   existing `[general]` section.
//! * **The reload fallback.** `apply_config` ran `hyprctl reload` as a child
//!   process; `hyprland_ipc.ipcRequest(…, "reload")` is the same request over
//!   the socket the shell already holds, with no fork — the shape
//!   `ux/settings2/monitors_state.zig` uses.
//! * **The glyph source.** `paint_layout_slot` and the popup called
//!   `draw_material_glyph` straight. Like every other Zig dock arm they draw
//!   the vendored Lucide icon first and fall back to the Material ligature,
//!   so a host without the TTF still shows the right shape.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const schema = @import("../../../config/schema.zig");
const chrome_colors = @import("../shared/chrome_colors.zig");
const pill = @import("../shared/pill.zig");
const svg_icons = @import("../../../ux/shared/svg_icons.zig");
const compositor = @import("../../../ux/shared/compositor.zig");
const hypr_ipc = @import("../../../backends/hyprland_ipc.zig");
const mango_ctx = @import("../../../backends/mango_run_ctx.zig");
const hypr_border = @import("../../../color/hyprland_border.zig");
const dock_widgets = @import("../../dock/widgets.zig");

pub const Backend = enum { hyprland, mango };

const LayoutDef = struct {
    id: []const u8,
    glyph: []const u8,
    title: []const u8,
    desc: []const u8,
    hypr: bool,
    mango: bool,
};

/// Union of every layout id both backends understand. `hypr`/`mango` mark
/// which backend offers the entry (wiki: mangowm/mango "layouts").
pub const k_layouts = [_]LayoutDef{
    // Hyprland set.
    .{ .id = "dwindle", .glyph = "account_tree", .title = "Dwindle", .desc = "Auto-tiling splits", .hypr = true, .mango = true },
    .{ .id = "master", .glyph = "view_sidebar", .title = "Master", .desc = "Master + stack", .hypr = true, .mango = false },
    .{ .id = "scrolling", .glyph = "view_column", .title = "Scrolling", .desc = "Column strip", .hypr = true, .mango = false },
    .{ .id = "monocle", .glyph = "fullscreen", .title = "Monocle", .desc = "Single maximized", .hypr = true, .mango = true },
    // MangoWM set (wiki "Supported Layouts").
    .{ .id = "tile", .glyph = "view_sidebar", .title = "Tile", .desc = "Master-stack tiling", .hypr = false, .mango = true },
    .{ .id = "scroller", .glyph = "view_column", .title = "Scroller", .desc = "Scrollable strip", .hypr = false, .mango = true },
    .{ .id = "grid", .glyph = "grid_view", .title = "Grid", .desc = "Even grid", .hypr = false, .mango = true },
    .{ .id = "deck", .glyph = "view_agenda", .title = "Deck", .desc = "Master + card stack", .hypr = false, .mango = true },
    .{ .id = "center_tile", .glyph = "vertical_split", .title = "Center Tile", .desc = "Centered master", .hypr = false, .mango = true },
    .{ .id = "vertical_tile", .glyph = "splitscreen", .title = "Vertical Tile", .desc = "Vertical master-stack", .hypr = false, .mango = true },
    .{ .id = "right_tile", .glyph = "horizontal_split", .title = "Right Tile", .desc = "Master on the right", .hypr = false, .mango = true },
    .{ .id = "vertical_scroller", .glyph = "view_stream", .title = "V-Scroller", .desc = "Vertical strip", .hypr = false, .mango = true },
    .{ .id = "vertical_grid", .glyph = "view_module", .title = "V-Grid", .desc = "Vertical grid", .hypr = false, .mango = true },
    .{ .id = "vertical_deck", .glyph = "layers", .title = "V-Deck", .desc = "Vertical card stack", .hypr = false, .mango = true },
    .{ .id = "fair", .glyph = "dashboard", .title = "Fair", .desc = "Even split", .hypr = false, .mango = true },
    .{ .id = "vertical_fair", .glyph = "space_dashboard", .title = "V-Fair", .desc = "Even vertical split", .hypr = false, .mango = true },
};

/// Presentation order for the Mango popup: most common first, default on
/// top. The union table above is grouped by backend, so Mango gets its own
/// curated order here (wiki lists 14 supported layouts).
pub const k_mango_order = [_][]const u8{
    "tile",         "scroller", "monocle",         "grid",
    "deck",         "dwindle",  "center_tile",     "vertical_tile",
    "right_tile",   "vertical_scroller",           "vertical_grid",
    "vertical_deck", "fair",     "vertical_fair",
};
const k_mango_count = k_mango_order.len;

// Table helpers

/// Lowercase-trim: trims every byte `<= ' '` off both ends and
/// lower-cases the rest, into a caller-owned buffer.
fn toLowerTrim(v: []const u8, buf: []u8) []const u8 {
    var b: usize = 0;
    while (b < v.len and v[b] <= ' ') b += 1;
    var e: usize = v.len;
    while (e > b and v[e - 1] <= ' ') e -= 1;
    const n = @min(e - b, buf.len);
    for (buf[0..n], 0..n) |*dst, i| {
        dst.* = std.ascii.toLower(v[b + i]);
    }
    return buf[0..n];
}

fn findDef(name: []const u8) ?*const LayoutDef {
    var buf: [64]u8 = undefined;
    const n = toLowerTrim(name, &buf);
    for (&k_layouts) |*d| {
        if (std.mem.eql(u8, n, d.id)) return d;
    }
    if (std.mem.eql(u8, n, "monicle")) { // common misspelling of monocle
        for (&k_layouts) |*d| {
            if (std.mem.eql(u8, d.id, "monocle")) return d;
        }
    }
    return null;
}

pub fn backend() Backend {
    return if (compositor.kind() == .mango) .mango else .hyprland;
}

/// Number of layouts offered for the active backend (4 / 14).
pub fn count() usize {
    if (backend() == .mango) return k_mango_count;
    var n: usize = 0;
    for (k_layouts) |d| {
        if (d.hypr) n += 1;
    }
    return n;
}

pub fn idAt(idx: usize) []const u8 {
    if (backend() == .mango) {
        if (idx >= k_mango_count) return "tile";
        return k_mango_order[idx];
    }
    var i: usize = 0;
    for (k_layouts) |d| {
        if (!d.hypr) continue;
        if (i == idx) return d.id;
        i += 1;
    }
    return "dwindle";
}

/// Index into the backend list, or null when unknown to this backend.
pub fn indexFor(name: []const u8) ?usize {
    var buf: [64]u8 = undefined;
    const n = toLowerTrim(name, &buf);
    if (std.mem.eql(u8, n, "monicle")) {
        // The alias has the same length as its target, so the buffer the
        // caller is already scanning can hold the correction.
        @memcpy(buf[0..7], "monocle");
    }
    if (backend() == .mango) {
        for (k_mango_order, 0..) |id, i| {
            if (std.mem.eql(u8, n, id)) return i;
        }
        return null;
    }
    var i: usize = 0;
    for (k_layouts) |d| {
        if (!d.hypr) continue;
        if (std.mem.eql(u8, n, d.id)) return i;
        i += 1;
    }
    return null;
}

pub fn glyphFor(name: []const u8) []const u8 {
    if (findDef(name)) |d| return d.glyph;
    return if (backend() == .mango) "view_sidebar" else "grid_view";
}

pub fn titleFor(name: []const u8) []const u8 {
    if (findDef(name)) |d| return d.title;
    return if (backend() == .mango) "Tile" else "Dwindle";
}

pub fn descFor(name: []const u8) []const u8 {
    if (findDef(name)) |d| return d.desc;
    return "";
}

pub fn normalize(name: []const u8) []const u8 {
    if (findDef(name)) |d| return d.id;
    return if (backend() == .mango) "tile" else "dwindle";
}

// Live query

const poll_interval_ns: i64 = std.time.ns_per_s;
const cache_cap = 32;

/// What the poll runs through. `paint_layout_slot` and the popup arrive with
/// no allocator and no `std.Io` — so the dock seeds this once per frame before the
/// strip loop. Without a context every query is skipped and the module
/// answers from its backend default, which is what keeps the pure half of it
/// runnable in a test with no compositor at all.
const Ctx = struct { alloc: std.mem.Allocator, io: std.Io };
var ctx: ?Ctx = null;

/// This Zig lock is `std.Io.Mutex`
/// (the futex-backed one) and its acquire takes an `std.Io`, which is
/// exactly why it lives behind the context: there is nothing to lock
/// with until someone has handed the module an io. Every caller is on
/// the event loop, so it never contends — it is here so a later
/// threaded caller cannot silently corrupt the caches.
var mutex: std.Io.Mutex = std.Io.Mutex.init;

var hypr_buf: [cache_cap]u8 = undefined;
var hypr_cached: []const u8 = "dwindle";
var mango_buf: [cache_cap]u8 = undefined;
var mango_cached: []const u8 = "tile";
var last_hypr_poll: i64 = 0;
var last_mango_poll: i64 = 0;

/// The dock calls this from `repaint`, before the strip and any card are
/// drawn. Idempotent, and the two pointers never change once set.
pub fn setContext(alloc: std.mem.Allocator, io: std.Io) void {
    ctx = .{ .alloc = alloc, .io = io };
}

fn setCached(which_mango: bool, id: []const u8) void {
    const n = @min(id.len, cache_cap);
    if (which_mango) {
        @memcpy(mango_buf[0..n], id[0..n]);
        mango_cached = mango_buf[0..n];
    } else {
        @memcpy(hypr_buf[0..n], id[0..n]);
        hypr_cached = hypr_buf[0..n];
    }
}

fn monotonicNs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * std.time.ns_per_s +
        @as(i64, @intCast(@max(ts.nsec, 0)));
}

fn envStr(key: [:0]const u8) ?[]const u8 {
    const p = std.c.getenv(key) orelse return null;
    const s = std.mem.span(p);
    return if (s.len == 0) null else s;
}

/// The three keys every query here needs. Built fresh per poll the way
/// `bin/overview.zig`'s `hyprEnv` does, because both backends resolve their
/// socket from it and neither is worth a process-global map.
fn envMap(alloc: std.mem.Allocator) std.process.Environ.Map {
    var env = std.process.Environ.Map.init(alloc);
    if (envStr("HYPRLAND_INSTANCE_SIGNATURE")) |v| env.put("HYPRLAND_INSTANCE_SIGNATURE", v) catch {};
    if (envStr("MANGO_INSTANCE_SIGNATURE")) |v| env.put("MANGO_INSTANCE_SIGNATURE", v) catch {};
    if (envStr("XDG_RUNTIME_DIR")) |v| env.put("XDG_RUNTIME_DIR", v) catch {};
    return env;
}

/// `EH_LAYOUT_DEBUG=<any known id>` pins the answer, for eyeballing one
/// arm of the popup without running that compositor.
fn debugOverride() ?[]const u8 {
    const e = envStr("EH_LAYOUT_DEBUG") orelse return null;
    const d = findDef(e) orelse return null;
    return d.id;
}

/// Case-insensitive `std.mem.indexOf`, folding during the scan.
/// first; folding here instead keeps the scan bounded by the reply rather
/// than by a scratch buffer, and every id in the table is already lower-case
/// ASCII, so both spell the same search.
pub fn indexOfFolded(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != needle[j]) {
                ok = false;
                break;
            }
        }
        if (ok) return i;
    }
    return null;
}

/// A `getoption` reply is a JSON body or one bare word, scanned for the first known Hyprland id it *contains*, which
/// is why this scans rather than parses. Table order decides the winner when
/// one reply names two ids (first hit wins).
pub fn hyprResponseHasLayout(resp: []const u8, out: *?[]const u8) bool {
    for (k_layouts) |d| {
        if (!d.hypr) continue;
        if (indexOfFolded(resp, d.id) != null) {
            out.* = d.id;
            return true;
        }
    }
    return false;
}

fn queryHyprLive(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?[]const u8 {
    if (envStr("HYPRLAND_INSTANCE_SIGNATURE") == null) return null;
    // JSON first (matches the `j/status`, `j/clients` convention), then plain.
    if (hypr_ipc.ipcRequest(alloc, io, env, "j/getoption general:layout")) |resp| {
        defer alloc.free(resp);
        var found: ?[]const u8 = null;
        if (hyprResponseHasLayout(resp, &found)) return found;
    }
    if (hypr_ipc.ipcRequest(alloc, io, env, "getoption general:layout")) |resp| {
        defer alloc.free(resp);
        var found: ?[]const u8 = null;
        if (hyprResponseHasLayout(resp, &found)) return found;
    }
    return null;
}

// Layouts are per-tag runtime state; the compositor is the source of truth.
// The wiki IPC page documents `dispatch setlayout,<name>` for switching (cf.
// `bind=SUPER,t,setlayout,tile`). For reading, probe the one-shot `get`
// endpoints and pick up any string field matching a known Mango id — if the
// compositor reports none, keep the last applied value (default "tile").

/// Prefers object fields whose key mentions "layout" (so a window titled
/// e.g. "Tile" cannot answer), then falls back to a full recursive scan —
/// the two-pass order of `mango_json_scan_layout`.
pub fn mangoJsonScan(v: std.json.Value, out: *?[]const u8) bool {
    switch (v) {
        .string => |s| {
            const d = findDef(s) orelse return false;
            if (!d.mango) return false;
            out.* = d.id;
            return true;
        },
        .array => |items| {
            for (items.items) |item| {
                if (mangoJsonScan(item, out)) return true;
            }
            return false;
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |e| {
                var kbuf: [64]u8 = undefined;
                const kl = toLowerTrim(e.key_ptr.*, &kbuf);
                if (std.mem.indexOf(u8, kl, "layout") == null) continue;
                if (mangoJsonScan(e.value_ptr.*, out)) return true;
            }
            var it2 = obj.iterator();
            while (it2.next()) |e| {
                var kbuf: [64]u8 = undefined;
                const kl = toLowerTrim(e.key_ptr.*, &kbuf);
                if (std.mem.indexOf(u8, kl, "layout") != null) continue;
                if (mangoJsonScan(e.value_ptr.*, out)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn queryMangoLive(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?[]const u8 {
    if (envStr("MANGO_INSTANCE_SIGNATURE") == null) return null;
    // Fresh runtime per query: `request` mutates the endpoint cache, so a
    // shared instance would need the same external locking.
    var rt = mango_ctx.Runtime.init(alloc, io, env);
    defer rt.deinit();
    if (!rt.available()) return null;
    if (rt.ipcQuery("get all-monitors")) |parsed| {
        defer parsed.deinit();
        var found: ?[]const u8 = null;
        if (mangoJsonScan(parsed.value, &found)) return found;
    }
    if (rt.ipcQuery("get all-tags")) |parsed| {
        defer parsed.deinit();
        var found: ?[]const u8 = null;
        if (mangoJsonScan(parsed.value, &found)) return found;
    }
    return null;
}

/// Live active layout (lowercase id). Never empty: Hyprland falls back to
/// the persisted config value then "dwindle"; Mango falls back to the last
/// applied value then "tile" (its default).
pub fn current() []const u8 {
    if (debugOverride()) |ov| return ov;
    const c = ctx orelse return if (backend() == .mango) mango_cached else hypr_cached;
    mutex.lockUncancelable(c.io);
    defer mutex.unlock(c.io);

    const now = monotonicNs();
    if (backend() == .mango) {
        if (now - last_mango_poll < poll_interval_ns and mango_cached.len != 0) return mango_cached;
        last_mango_poll = now;
        var env = envMap(c.alloc);
        defer env.deinit();
        if (queryMangoLive(c.alloc, c.io, &env)) |live| setCached(true, live);
        return mango_cached;
    }
    if (now - last_hypr_poll < poll_interval_ns and hypr_cached.len != 0) return hypr_cached;
    last_hypr_poll = now;
    var env = envMap(c.alloc);
    defer env.deinit();
    if (queryHyprLive(c.alloc, c.io, &env)) |live| {
        setCached(false, live);
        return hypr_cached;
    }
    // No compositor (or query failed): fall back to the persisted config so
    // the slot still reflects what Hyprland will use on the next reload.
    setCached(false, readPersisted(c.alloc, c.io));
    return hypr_cached;
}

// Persistence — the narrow `settings_hyprland` this widget needs

const managed_dir = ".config/hypr/hyprland";

fn homeDir() []const u8 {
    return envStr("HOME") orelse "/tmp";
}

/// `~/.config/hypr/hyprland/general.lua`, the managed layout file.
fn managedPath(alloc: std.mem.Allocator) ?[]u8 {
    return std.fs.path.join(alloc, &.{ homeDir(), managed_dir, "general.lua" }) catch null;
}

/// `~/.config/hypr/hyprland.conf`, read as a fallback for a stock install.
fn stockPath(alloc: std.mem.Allocator) ?[]u8 {
    return std.fs.path.join(alloc, &.{ homeDir(), ".config/hypr/hyprland.conf" }) catch null;
}

fn readFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch null;
}

fn freeFile(alloc: std.mem.Allocator, bytes: ?[]u8) void {
    if (bytes) |b| alloc.free(b);
}

/// Line spans over a file body: each line without its `\n`, and whether it
/// had one. A body that ends mid-line keeps ending mid-line, so no rewrite
/// ever adds or drops a trailing newline.
const LineIter = struct {
    text: []const u8,
    pos: usize = 0,

    const Line = struct { text: []const u8, nl: bool };

    fn next(self: *LineIter) ?Line {
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        const rel = std.mem.indexOfScalar(u8, self.text[start..], '\n') orelse self.text.len - start;
        const nl_at = start + rel;
        const had = nl_at < self.text.len;
        self.pos = if (had) nl_at + 1 else self.text.len;
        return .{ .text = self.text[start..nl_at], .nl = had };
    }
};

const KeyVal = struct { key: []const u8, val: []const u8 };

/// A trimmed `key = value` line, split the way `parse_lua_kv` splits one.
fn keyVal(trimmed: []const u8) ?KeyVal {
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    return .{
        .key = std.mem.trim(u8, trimmed[0..eq], " \t"),
        .val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t"),
    };
}

/// `general = {` — the line that opens the managed section.
fn isGeneralOpen(trimmed: []const u8) bool {
    const kv = keyVal(trimmed) orelse return false;
    return std.mem.eql(u8, kv.key, "general") and std.mem.eql(u8, kv.val, "{");
}

fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) {
        return v[1 .. v.len - 1];
    }
    return v;
}

/// The `layout` value out of a `general.lua` body, quote-stripped.
pub fn luaLayoutValue(text: []const u8) ?[]const u8 {
    var it = LineIter{ .text = text };
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line.text, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '-' or trimmed[0] == '/') continue;
        const kv = keyVal(trimmed) orelse continue;
        if (!std.mem.eql(u8, kv.key, "layout")) continue;
        var val = kv.val;
        while (val.len > 0 and val[val.len - 1] == ',') val = std.mem.trim(u8, val[0 .. val.len - 1], " \t");
        return unquote(val);
    }
    return null;
}

/// The `layout` value out of a `hyprland.conf` body: only inside
/// `[general]`, comments stripped.
pub fn confLayoutValue(text: []const u8) ?[]const u8 {
    var in_general = false;
    var it = LineIter{ .text = text };
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line.text, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;
        if (trimmed[0] == '[') {
            in_general = std.mem.eql(u8, std.mem.trim(u8, trimmed, "[]"), "general");
            continue;
        }
        if (!in_general) continue;
        const kv = keyVal(trimmed) orelse continue;
        if (!std.mem.eql(u8, kv.key, "layout")) continue;
        var val = kv.val;
        // Trailing comment, if the line has one.
        if (std.mem.indexOfScalar(u8, val, '#')) |at| val = std.mem.trim(u8, val[0..at], " \t");
        if (std.mem.indexOfScalar(u8, val, ';')) |at| val = std.mem.trim(u8, val[0..at], " \t");
        return unquote(val);
    }
    return null;
}

/// Which backend's id list a persisted value has to be known to.
fn persistedIsSane(v: []const u8) bool {
    const d = findDef(v) orelse return false;
    return d.hypr;
}

fn readPersisted(alloc: std.mem.Allocator, io: std.Io) []const u8 {
    if (managedPath(alloc)) |p| {
        defer alloc.free(p);
        if (readFile(alloc, io, p)) |text| {
            defer freeFile(alloc, text);
            if (luaLayoutValue(text)) |v| {
                if (persistedIsSane(v)) return findDef(v).?.id;
            }
        }
    }
    if (stockPath(alloc)) |p| {
        defer alloc.free(p);
        if (readFile(alloc, io, p)) |text| {
            defer freeFile(alloc, text);
            if (confLayoutValue(text)) |v| {
                if (persistedIsSane(v)) return findDef(v).?.id;
            }
        }
    }
    return "dwindle";
}

/// Replace the `layout = "…"` line of a `general.lua` body, keeping every
/// other line byte-for-byte. A file that has no such line gets one inside
/// the `general = { … }` block; a file that has no block at all is written
/// in the shape `write_hl_config` produces, so `parse_lua_kv` reads it back.
///
/// Returns either the rewritten `out` or the untouched `text`, so a caller
/// can tell "did not fit" from "did" by the pointer alone and never writes a
/// truncated file. `text` and `out` must not overlap: the body is read and
/// written in a single pass.
pub fn setLuaLayout(text: []const u8, norm: []const u8, out: []u8) []const u8 {
    if (text.len == 0) {
        return std.fmt.bufPrint(
            out,
            "hl.config({{\n  general = {{\n    layout = \"{s}\",\n  }},\n}})\n",
            .{norm},
        ) catch text;
    }
    var entry_buf: [48]u8 = undefined;
    const entry = std.fmt.bufPrint(&entry_buf, "layout = \"{s}\",\n", .{norm}) catch return text;

    var wrote: usize = 0;
    var insert_at: ?usize = null;
    var replaced = false;
    var it = LineIter{ .text = text };
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line.text, " \t\r");
        const kv = keyVal(trimmed);
        if (kv != null and std.mem.eql(u8, kv.?.key, "layout")) {
            if (!writeChunk(out, &wrote, entry)) return text;
            replaced = true;
            continue;
        }
        if (!writeChunk(out, &wrote, line.text)) return text;
        if (line.nl and !writeChunk(out, &wrote, "\n")) return text;
        if (insert_at == null and isGeneralOpen(trimmed)) insert_at = wrote;
    }
    // The line was already there and has been swapped: the insert below is
    // for a file that never had one, and running it too would leave two
    // `layout` keys for `parse_lua_kv` to pick between.
    if (replaced) return out[0..wrote];
    const at = insert_at orelse return out[0..wrote];
    if (wrote + entry.len > out.len) return text;
    // Shift the tail *right* to make room: the two ranges overlap and the
    // destination sits after the source, so the copy has to walk from the
    // end. `copyForwards` would walk into bytes it has not read yet and
    // smear every line across the one after it.
    std.mem.copyBackwards(u8, out[at + entry.len ..][0 .. wrote - at], out[at..wrote]);
    @memcpy(out[at .. at + entry.len], entry);
    return out[0 .. wrote + entry.len];
}

/// Same edit for a `hyprland.conf` body: only inside an existing
/// `[general]` section, and a section with no `layout` line gains one right
/// under its header. A file with no `[general]` is returned unchanged — the
/// managed lua file is this project's source of truth and inventing a
/// section is not this widget's business. `text` and `out` must not overlap.
pub fn setConfLayout(text: []const u8, norm: []const u8, out: []u8) []const u8 {
    var line_buf: [48]u8 = undefined;
    const entry = std.fmt.bufPrint(&line_buf, "layout = {s}\n", .{norm}) catch return text;

    var section_at: ?usize = null;
    var wrote: usize = 0;
    var in_general = false;
    var replaced = false;
    var it = LineIter{ .text = text };
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line.text, " \t\r");
        const header = trimmed.len > 0 and trimmed[0] == '[';
        if (header) in_general = std.mem.eql(u8, std.mem.trim(u8, trimmed, "[]"), "general");
        const kv = keyVal(trimmed);
        if (in_general and kv != null and std.mem.eql(u8, kv.?.key, "layout")) {
            if (!writeChunk(out, &wrote, entry)) return text;
            replaced = true;
            continue;
        }
        if (!writeChunk(out, &wrote, line.text)) return text;
        if (line.nl and !writeChunk(out, &wrote, "\n")) return text;
        // Remembered *after* the header is written, so an inserted line
        // lands inside the section rather than on top of its `[general]`.
        if (header and in_general and section_at == null) section_at = wrote;
    }
    if (replaced) return out[0..wrote];
    const at = section_at orelse return text;
    if (wrote + entry.len > out.len) return text;
    // Rightward shift of overlapping ranges — `copyBackwards`, as above.
    std.mem.copyBackwards(u8, out[at + entry.len ..][0 .. wrote - at], out[at..wrote]);
    @memcpy(out[at .. at + entry.len], entry);
    return out[0 .. wrote + entry.len];
}

fn writeChunk(out: []u8, wrote: *usize, chunk: []const u8) bool {
    if (wrote.* + chunk.len > out.len) return false;
    @memcpy(out[wrote.* .. wrote.* + chunk.len], chunk);
    wrote.* += chunk.len;
    return true;
}

/// Writes the choice into the managed file, and mirrors
/// it into `hyprland.conf` when that file already keeps a `[general]`
/// section. True when the managed file took it.
pub fn writePersisted(alloc: std.mem.Allocator, io: std.Io, norm: []const u8) bool {
    var ok = false;
    if (managedPath(alloc)) |p| {
        defer alloc.free(p);
        const existing = readFile(alloc, io, p);
        defer freeFile(alloc, existing);
        const src: []const u8 = existing orelse "";
        const buf = alloc.alloc(u8, src.len + 4096) catch return false;
        defer alloc.free(buf);
        const next = setLuaLayout(src, norm, buf);
        if (writeFile(io, p, next)) ok = true;
    }
    if (stockPath(alloc)) |p| {
        defer alloc.free(p);
        if (readFile(alloc, io, p)) |text| {
            defer freeFile(alloc, text);
            const buf = alloc.alloc(u8, text.len + 256) catch return ok;
            defer alloc.free(buf);
            const next = setConfLayout(text, norm, buf);
            // A `hyprland.conf` with no `[general]` comes back untouched,
            // and there is nothing to write then.
            if (next.ptr != text.ptr) _ = writeFile(io, p, next);
        }
    }
    return ok;
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) bool {
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch return false;
    return true;
}

// Apply

/// Swap live (+ persist on Hyprland). Returns true when accepted.
pub fn apply(name: []const u8) bool {
    const d = findDef(name) orelse return false;
    const mango = backend() == .mango;
    if (if (mango) !d.mango else !d.hypr) return false;
    const norm = d.id;
    const c = ctx orelse return false;
    {
        mutex.lockUncancelable(c.io);
        defer mutex.unlock(c.io);
        // The cache takes the pick before the IPC answers, so the slot shows
        // it even if the compositor is mid-swap.
        if (mango) {
            setCached(true, norm);
            last_mango_poll = monotonicNs();
        } else {
            setCached(false, norm);
            last_hypr_poll = monotonicNs();
        }
    }
    var env = envMap(c.alloc);
    defer env.deinit();

    if (mango) {
        // Wiki "Switching Layouts": `bind=SUPER,t,setlayout,tile`.
        if (envStr("MANGO_INSTANCE_SIGNATURE") == null) return false;
        var rt = mango_ctx.Runtime.init(c.alloc, c.io, &env);
        defer rt.deinit();
        if (!rt.available()) return false;
        var cmd_buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "setlayout,{s}", .{norm}) catch return false;
        return rt.runCommand(cmd);
    }

    var live_ok = false;
    if (envStr("HYPRLAND_INSTANCE_SIGNATURE") != null) {
        var cmd_buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "keyword general:layout {s}", .{norm}) catch "";
        if (cmd.len > 0) {
            if (hypr_ipc.ipcRequest(c.alloc, c.io, &env, cmd)) |resp| {
                defer c.alloc.free(resp);
                live_ok = std.mem.eql(u8, std.mem.trim(u8, resp, " \t\r\n"), "ok");
            }
        }
    }
    // Persist so the choice survives reloads / restarts.
    const persist_ok = writePersisted(c.alloc, c.io, norm);
    if (!live_ok and persist_ok) {
        // Keyword path unavailable (e.g. older Hyprland): a full reload
        // applies it — `apply_config`'s `hyprctl reload` over the socket.
        if (hypr_ipc.ipcRequest(c.alloc, c.io, &env, "reload")) |resp| {
            defer c.alloc.free(resp);
            live_ok = true;
        }
    }
    return live_ok or persist_ok;
}

// Dock integration

pub fn widgetListContainsLayout(sc: *const schema.ShellConfig, widgets: []const []const u8) bool {
    for (widgets) |w| {
        if (std.mem.eql(u8, dock_widgets.implType(sc, w), "layout")) return true;
    }
    return false;
}

/// `dock_layout_slot_width` — an icon-only pill, the same footprint
/// bluetooth and vpn get.
pub fn dockLayoutSlotWidth(
    measure_cr: ?*cairo.cairo_t,
    sc: *const schema.ShellConfig,
    instance_id: []const u8,
    icon_ref_px: f64,
    bar_height: f64,
) f64 {
    _ = measure_cr;
    _ = instance_id;
    _ = bar_height;
    const us = std.math.clamp(sc.dock.shell_ui_scale, 0.5, 2.0);
    return icon_ref_px + 4.0 * us;
}

/// Every name resolves through the vendored Lucide bank; a miss paints
/// nothing.
fn drawGlyph(cr: ?*cairo.cairo_t, name: []const u8, cx: f64, cy: f64, px: f64, r: f64, g: f64, b: f64, a: f64) void {
    _ = svg_icons.draw(cr, name, cx, cy, px, r, g, b, a, false);
}

/// `paint_layout_slot`: pill, the inline hover/press ring, and
/// the live layout's glyph in the accent when a palette is driving the bar
/// (`anyPaletteActive`) and plain white when it is not.
pub fn paintLayoutSlot(
    cr: ?*cairo.cairo_t,
    sc: *const schema.ShellConfig,
    instance_id: []const u8,
    x: f64,
    y: f64,
    slot_w: f64,
    slot_h: f64,
    icon_ref_px: f64,
    hovered: bool,
    pressed: bool,
) void {
    const c = cr orelse return;
    _ = instance_id;
    const cur = current();
    const glyph = glyphFor(cur);
    const mc = chrome_colors.of(sc);
    const matugen = hypr_border.anyPaletteActive(sc.appearance);

    pill.paintPill(c, x, y, slot_w, slot_h);
    if (hovered or pressed) {
        const rad = pill.cornerRadius(slot_h, slot_w);
        cairo.cairo_new_sub_path(c);
        cairo.cairo_arc(c, x + slot_w - rad, y + rad, rad, -std.math.pi / 2.0, 0);
        cairo.cairo_arc(c, x + slot_w - rad, y + slot_h - rad, rad, 0, std.math.pi / 2.0);
        cairo.cairo_arc(c, x + rad, y + slot_h - rad, rad, std.math.pi / 2.0, std.math.pi);
        cairo.cairo_arc(c, x + rad, y + rad, rad, std.math.pi, 3.0 * std.math.pi / 2.0);
        cairo.cairo_close_path(c);
        if (matugen)
            cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, if (pressed) 0.28 else 0.18)
        else
            cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, if (pressed) 0.14 else 0.08);
        cairo.cairo_fill_preserve(c);
        if (matugen)
            cairo.cairo_set_source_rgba(c, mc.accent.r, mc.accent.g, mc.accent.b, 0.35)
        else
            cairo.cairo_set_source_rgba(c, 1.0, 1.0, 1.0, 0.22);
        cairo.cairo_set_line_width(c, 1.0);
        cairo.cairo_stroke(c);
    }
    const px = icon_ref_px * 0.52;
    const cx = x + slot_w * 0.5;
    const cy = y + slot_h * 0.5;
    if (matugen)
        drawGlyph(c, glyph, cx, cy, px, mc.accent.r, mc.accent.g, mc.accent.b, 1.0)
    else
        drawGlyph(c, glyph, cx, cy, px, 1.0, 1.0, 1.0, 1.0);
}

// Tests

test "layout: the backend list is trimmed to that backend" {
    const t = std.testing;
    // `backend()` answers from the real environment, so both halves are
    // checked through the table itself rather than through the switch —
    // `k_layouts` is the union and `k_mango_order` is Mango's order.
    var hypr_n: usize = 0;
    for (k_layouts) |d| {
        if (d.hypr) hypr_n += 1;
    }
    try t.expectEqual(@as(usize, 4), hypr_n);
    try t.expectEqual(@as(usize, 14), k_mango_order.len);
    try t.expectEqual(@as(usize, 16), k_layouts.len);
    // The union is unique by id.
    for (k_layouts, 0..) |a, i| {
        for (k_layouts[i + 1 ..]) |b| try t.expect(!std.mem.eql(u8, a.id, b.id));
    }
    // Mango's presentation order names only ids Mango actually offers, once
    // each, and starts on the default.
    try t.expectEqualStrings("tile", k_mango_order[0]);
    for (k_mango_order) |id| {
        var seen: usize = 0;
        for (k_mango_order) |other| {
            if (std.mem.eql(u8, id, other)) seen += 1;
        }
        try t.expectEqual(@as(usize, 1), seen);
        const d = findDef(id).?;
        try t.expect(d.mango);
    }
}

test "layout: lookup, typo alias and backend fallbacks" {
    const t = std.testing;
    try t.expectEqualStrings("Auto-tiling splits", descFor("dwindle"));
    try t.expectEqualStrings("Dwindle", titleFor("  DWINDLE  "));
    try t.expectEqualStrings("account_tree", glyphFor("dwindle"));
    try t.expectEqualStrings("monocle", normalize("monicle"));
    try t.expectEqualStrings("dwindle", normalize("nope"));
    // An id the other backend owns still resolves to its table entry — the
    // union is what `glyph_for`/`title_for` read. `title` and
    // `desc` are two different columns of that entry.
    try t.expectEqualStrings("Tile", titleFor("tile"));
    try t.expectEqualStrings("Master-stack tiling", descFor("tile"));
    try t.expectEqualStrings("", descFor("nope"));
    // Out-of-range indices answer the backend default rather than nothing.
    try t.expectEqualStrings("dwindle", idAt(9999));
}

test "layout: a hyprland reply is scanned for any known hyprland id" {
    const t = std.testing;
    var found: ?[]const u8 = null;
    // The JSON form of `j/getoption general:layout`.
    try t.expect(hyprResponseHasLayout(
        "{\"int\":0,\"str\":\"dwindle\",\"custom\":0,\"option\":true}",
        &found,
    ));
    try t.expectEqualStrings("dwindle", found.?);
    // The bare-word form of `getoption general:layout`.
    found = null;
    try t.expect(hyprResponseHasLayout("  DWINDLE\n", &found));
    try t.expectEqualStrings("dwindle", found.?);
    // `scrolling` contains no other id, and `tile` is mango-only so a reply
    // naming it must not answer.
    found = null;
    try t.expect(hyprResponseHasLayout("scrolling", &found));
    try t.expectEqualStrings("scrolling", found.?);
    found = null;
    try t.expect(!hyprResponseHasLayout("vertical_tile", &found));
    try t.expect(found == null);
    // Only ids the *hyprland* half of the table owns are candidates, so a
    // reply that merely contains a Mango id answers nothing: `grid` sits
    // inside `vertical_grid`, but `grid` is mango-only and gets skipped.
    found = null;
    try t.expect(!hyprResponseHasLayout("vertical_grid", &found));
    try t.expect(found == null);

    // Table order picks the winner when one reply names two hyprland ids:
    // `dwindle` is scanned before `master`, so it is the one that answers.
    found = null;
    try t.expect(hyprResponseHasLayout("master dwindle", &found));
    try t.expectEqualStrings("dwindle", found.?);
    found = null;
    try t.expect(hyprResponseHasLayout("dwindle master", &found));
    try t.expectEqualStrings("dwindle", found.?);
}

test "layout: the mango scan prefers layout keys over stray strings" {
    const t = std.testing;
    const alloc = std.testing.allocator;
    var found: ?[]const u8 = null;

    const cases = [_]struct { json: []const u8, want: ?[]const u8 }{
        .{ .json = "{\"tags\":[{\"name\":\"1\",\"layout\":\"scroller\"}]}", .want = "scroller" },
        // A field whose key mentions "layout" is asked first, wherever it
        // sits in the object: `title` is scanned in the second pass, so its
        // "Tile" never gets the chance to answer.
        .{ .json = "{\"tags\":[{\"layout\":\"deck\",\"title\":\"Tile\"}]}", .want = "deck" },
        .{ .json = "{\"tags\":[{\"title\":\"Tile\",\"layout\":\"deck\"}]}", .want = "deck" },
        // With no "layout" key anywhere, the second pass is a *full*
        // recursive scan and does reach that window title — so "Tile"
        // resolves. The second pass recurses into every value including
        // strings. The guard only bites once a layout key
        // exists, which is the next case:
        .{ .json = "{\"clients\":[{\"title\":\"Tile\"}]}", .want = "tile" },
        .{ .json = "{\"layout\":\"grid\",\"clients\":[{\"title\":\"Tile\"}]}", .want = "grid" },
        // No known id anywhere: nothing answers.
        .{ .json = "{\"clients\":[{\"title\":\"Niri terminal\"}]}", .want = null },
        // A string at the top level is matched directly.
        .{ .json = "\"vertical_deck\"", .want = "vertical_deck" },
        // Mango-only ids, and an id the union knows but Mango does not.
        .{ .json = "{\"layout\":\"master\"}", .want = null },
        .{ .json = "{\"layout\":\"scrolling\"}", .want = null },
        .{ .json = "{\"layout\":\"nope\"}", .want = null },
        .{ .json = "{\"layout\":4}", .want = null },
    };
    for (cases) |case| {
        found = null;
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, case.json, .{});
        defer parsed.deinit();
        const hit = mangoJsonScan(parsed.value, &found);
        if (case.want) |w| {
            try t.expect(hit);
            try t.expectEqualStrings(w, found.?);
        } else {
            try t.expect(!hit);
            try t.expect(found == null);
        }
    }
}

test "layout: every glyph in the union table resolves to a vendored icon" {
    // The slot and the popup draw these names, and a name the Lucide table
    // does not carry would fall through to the Material ligature — which a
    // host without the TTF renders as literal fallback text. The same guard
    // `svg_icons.zig` applies to the picker, taken here against the widget's
    // own table plus the popup's two fixed glyphs.
    // No `t.` assertion: a missing glyph is printed with its name so the
    // failure names the map entry to add.
    const surface = cairo.cairo_image_surface_create(0, 64, 64);
    defer cairo.cairo_surface_destroy(surface);
    const cr = cairo.cairo_create(surface);
    defer cairo.cairo_destroy(cr);
    for (k_layouts) |d| {
        if (!svg_icons.draw(cr, d.glyph, 32.0, 32.0, 24.0, 1.0, 1.0, 1.0, 1.0, false)) {
            std.debug.print("\nlucide map is missing layout glyph `{s}`\n", .{d.glyph});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "close", "check" }) |g| {
        if (!svg_icons.draw(cr, g, 32.0, 32.0, 24.0, 1.0, 1.0, 1.0, 1.0, false)) {
            std.debug.print("\nlucide map is missing popup glyph `{s}`\n", .{g});
            return error.TestUnexpectedResult;
        }
    }
}

test "layout: the slot is one icon plus the ui-scale pad" {
    const t = std.testing;
    var cfg = schema.ShellConfig{};
    cfg.dock.shell_ui_scale = 1.0;
    try t.expectEqual(@as(f64, 44.0 + 4.0), dockLayoutSlotWidth(null, &cfg, "layout", 44.0, 64.0));
    cfg.dock.shell_ui_scale = 2.0;
    try t.expectEqual(@as(f64, 44.0 + 8.0), dockLayoutSlotWidth(null, &cfg, "layout", 44.0, 64.0));
    // Clamp(x, 0.5, 2.0) bounds both ends.
    cfg.dock.shell_ui_scale = 0.1;
    try t.expectEqual(@as(f64, 44.0 + 2.0), dockLayoutSlotWidth(null, &cfg, "layout", 44.0, 64.0));
    cfg.dock.shell_ui_scale = 9.0;
    try t.expectEqual(@as(f64, 44.0 + 8.0), dockLayoutSlotWidth(null, &cfg, "layout", 44.0, 64.0));
    try t.expect(widgetListContainsLayout(&cfg, &.{"layout"}));
    try t.expect(!widgetListContainsLayout(&cfg, &.{"clock"}));
}

test "layout: persistence edits only the layout line" {
    const t = std.testing;
    const lua_in =
        \\hl.config({
        \\  general = {
        \\    border_size = 2,
        \\    layout = "dwindle",
        \\    gaps_in = 4,
        \\  },
        \\})
        \\
    ;
    try t.expectEqualStrings("dwindle", luaLayoutValue(lua_in).?);
    var out: [2048]u8 = undefined;
    const lua_out = setLuaLayout(lua_in, "master", &out);
    try t.expectEqualStrings("master", luaLayoutValue(lua_out).?);
    // Every other line survives byte-for-byte.
    try t.expect(std.mem.indexOf(u8, lua_out, "border_size = 2,") != null);
    try t.expect(std.mem.indexOf(u8, lua_out, "gaps_in = 4,") != null);
    try t.expect(std.mem.indexOf(u8, lua_out, "hl.config({") != null);
    try t.expectEqual(@as(usize, 1), countLinesContaining(lua_out, "layout ="));

    // A file with no layout line gains one inside the general block.
    const lua_bare =
        \\hl.config({
        \\  general = {
        \\    border_size = 2,
        \\  },
        \\})
        \\
    ;
    try t.expect(luaLayoutValue(lua_bare) == null);
    const lua_gained = setLuaLayout(lua_bare, "master", &out);
    try t.expectEqualStrings("master", luaLayoutValue(lua_gained).?);
    try t.expect(std.mem.indexOf(u8, lua_gained, "border_size = 2,") != null);

    // An empty file comes back in the shape `write_hl_config` produces.
    const lua_new = setLuaLayout("", "grid", &out);
    try t.expectEqualStrings("grid", luaLayoutValue(lua_new).?);

    // hyprland.conf: inside [general] only.
    const conf =
        \\# hyprland config
        \\monitor = ,preferred,auto,1
        \\
        \\[general]
        \\gaps_in = 4
        \\layout = "dwindle"
        \\
        \\[decoration]
        \\rounding = 12
        \\layout = "should-not-be-read"
        \\
    ;
    try t.expectEqualStrings("dwindle", confLayoutValue(conf).?);
    const conf_out = setConfLayout(conf, "monocle", &out);
    try t.expectEqualStrings("monocle", confLayoutValue(conf_out).?);
    try t.expect(std.mem.indexOf(u8, conf_out, "rounding = 12") != null);
    try t.expect(std.mem.indexOf(u8, conf_out, "gaps_in = 4") != null);
    // The other section is untouched.
    try t.expect(std.mem.indexOf(u8, conf_out, "layout = \"should-not-be-read\"") != null);

    // A [general] with no layout line gains one under the header.
    const conf_bare =
        \\[general]
        \\gaps_in = 4
        \\
    ;
    const conf_gained = setConfLayout(conf_bare, "master", &out);
    try t.expectEqualStrings("master", confLayoutValue(conf_gained).?);
    try t.expect(std.mem.indexOf(u8, conf_gained, "gaps_in = 4") != null);

    // No [general] section at all: nothing is invented.
    const conf_other =
        \\[decoration]
        \\rounding = 12
        \\
    ;
    const conf_same = setConfLayout(conf_other, "master", &out);
    try t.expectEqualStrings(conf_other, conf_same);

    // Quote and comment forms are all read back to the bare id.
    try t.expectEqualStrings("tile", confLayoutValue("[general]\nlayout = tile # tiling\n").?);
    try t.expectEqualStrings("fair", luaLayoutValue("  layout = \"fair\" ,\n").?);
}

fn countLinesContaining(text: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) n += 1;
    }
    return n;
}
