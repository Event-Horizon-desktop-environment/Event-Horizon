//! Hyprland config data layer — Zig port of
//! `src/ux/settings/data/hyprland/settings_hyprland_data.{hpp,cpp}`.
//!
//! **Model.** The C++ keeps one typed struct per section (`HyprlandGeneral`,
//! `HyprlandDecoration`, …) with a `read_*`/`write_*` pair per file. Here the
//! same 291 keys live in the generated `hyprland_keys.zig` table — each key's
//! default is the C++ `*_val(kv, key, default)` fallback — and the values sit
//! in a parallel array indexed the same way, so one loader and one writer
//! cover all 16 sections. The sub-tab controls reach keys through `k_ui`: a
//! UI slot (the `hypr_*` `Field` enum value) is a key index plus the value
//! transform the C++ paints with (`ui = scale * real + offset`, or a label
//! table for the string keys it shows as `value_labels[val - lo]`).
//!
//! What lands on disk: the same 16
//! `~/.config/hypr/hyprland/<name>.lua` files, the same `-- <header> --
//! managed by Event Horizon` first line, the same entry order, the same
//! alphabetical sub-table nesting (`write_nested_entries`), the same
//! `escape_lua` quoting, the same six-decimal `std::to_string(double)`
//! numbers, and the same write conditions (`if (!x.empty())`, plus the
//! `screen_shader_enabled && !screen_shader.empty()` gate). A key the C++
//! reads but never writes (`.write = false`, e.g. `screen_shader_enabled`) is
//! dropped on save — the writer regenerates each file
//! from its struct and so loses it too.
//!
//! **Deviations, all deliberate:**
//! * `apply_config`'s `std::system("hyprctl reload 2>/dev/null")` is the same
//!   request over the Hyprland socket the shell already holds
//!   (`hyprland_ipc.ipcRequest(..., "reload")`) — same result, no fork. The
//!   layout widget makes the same substitution.
//! * Saving creates `~/.config/hypr/hyprland/` when it is missing; the C++
//!   `std::ofstream` would simply fail and return false there.
//! * The reload `draw()` runs every frame (`settings_app.cpp:1511`) is
//!   skipped while an edit is pending (`g_dirty`) rather than only while a
//!   slider is held. The two guards coincide — the C++ commits inside the
//!   pointer handler, so "pending edit" is exactly "slider is down" — and
//!   this keeps a toggle click from being reverted by a reload that lands
//!   before its commit.
//! * Reading a text value past its label table falls back to the plain
//!   number, where the C++ indexes `value_labels[]` out of bounds; and a
//!   number too large for `int` clamps, where the C++'s `static_cast<int>`
//!   is undefined. Both are unreachable with the shipped tables.
//!
//! The tab's controls never see these differences: `getBool`/`getInt`/
//! `getStr`/`set*`/`valueText` are the same calls the C++ `Content` makes.

const std = @import("std");

const keys = @import("hyprland_keys.zig");
const hypr_ipc = @import("../../backends/hyprland_ipc.zig");

// ---------------------------------------------------------------------------
// Generated tables (see hyprland_keys.zig for how they are produced).
// ---------------------------------------------------------------------------

pub const Kind = keys.Kind;
pub const Value = keys.Value;
pub const Key = keys.Key;
pub const Section = keys.Section;
pub const Fmt = keys.Fmt;
pub const UiSlot = keys.UiSlot;
pub const AnimEntry = keys.AnimEntry;
pub const AnimCategory = keys.AnimCategory;
pub const BezierPreset = keys.BezierPreset;

pub const k_keys = keys.k_keys;
pub const k_sections = keys.k_sections;
pub const k_ui = keys.k_ui;
pub const k_anim_entries = keys.k_anim_entries;
pub const k_anim_categories = keys.k_anim_categories;
pub const k_curve_names = keys.k_curve_names;
pub const k_bezier_presets = keys.k_bezier_presets;

pub const slot_count: u16 = k_ui.len;

/// The animations file holds a list of `animation = "…"` lines, one per
/// entry; the C++ model keeps them in a `std::vector` in file order. This is
/// that vector — including names the tab does not render, which a save
/// re-emits untouched (the C++ vector carries them for the same reason).
pub const AnimLine = struct {
    name: []const u8,
    enabled: bool = true,
    speed: f64 = 3.0,
    curve: []const u8 = "default",
    style: []const u8 = "",
};

// ---------------------------------------------------------------------------
// State.
// ---------------------------------------------------------------------------

/// One `Value` per key, indexed like `k_keys`; the animation list; and an
/// arena holding the text values read from disk (the C++ equivalents are
/// `std::string` members of the config struct). Every `load` swaps in a fresh
/// arena, so the previous round's strings go with it.
var g_values: [k_keys.len]Value = initValues();
var g_anims: std.ArrayListUnmanaged(AnimLine) = .empty;
var g_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var g_dirty = false;

fn initValues() [k_keys.len]Value {
    @setEvalBranchQuota(200_000);
    var out: [k_keys.len]Value = undefined;
    for (&out, 0..) |*v, i| v.* = k_keys[i].default;
    return out;
}

/// True between a change and its `commit` — the guard that stands in for the
/// C++'s `hyprland_m3_has_active_slider` reload check.
pub fn isDirty() bool {
    return g_dirty;
}

pub fn markDirty() void {
    g_dirty = true;
}

// ---------------------------------------------------------------------------
// Paths.
// ---------------------------------------------------------------------------

fn envStr(key: [:0]const u8) ?[]const u8 {
    const p = std.c.getenv(key) orelse return null;
    const s = std.mem.span(p);
    return if (s.len == 0) null else s;
}

/// `$HOME`, or `/tmp` when unset — the C++ `hyprland_config_dir()` fallback.
fn homeDir() []const u8 {
    return envStr("HOME") orelse "/tmp";
}

/// `~/.config/hypr/hyprland` — the C++ `hyprland_config_dir()`.
pub fn configDir(a: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/.config/hypr/hyprland", .{homeDir()});
}

/// `~/.config/hypr/hyprland/<name>.lua` — the C++ `file_path()`.
fn filePath(a: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/.config/hypr/hyprland/{s}.lua", .{ homeDir(), name });
}

fn readFile(a: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch null;
}

// ---------------------------------------------------------------------------
// Lua reading — the C++ `parse_lua_kv` and the typed `*_val` helpers.
// ---------------------------------------------------------------------------

/// The C++ `trim`: spaces and tabs only. A CRLF file therefore keeps its
/// `\r` on the last token of a line, as it does in the C++.
fn trim(s: []const u8) []const u8 {
    var b: usize = 0;
    while (b < s.len and (s[b] == ' ' or s[b] == '\t')) b += 1;
    var e: usize = s.len;
    while (e > b and (s[e - 1] == ' ' or s[e - 1] == '\t')) e -= 1;
    return s[b..e];
}

const KV = struct { key: []const u8, val: []const u8 };

/// `parse_lua_kv`: blank lines and `--`/`//` comments dropped, every `}`
/// popping one table frame (so `})` closes the `hl.config({` line), a value
/// of exactly `{` pushing the key as a new frame, quotes stripped, and keys
/// rebuilt relative to the section — the first non-empty frame is the section
/// root and is skipped, so `hl.config({ general = { border_size = 1 } })`
/// yields `general.border_size`.
///
/// The values borrow from `text` (only the rebuilt keys are copied), so the
/// text must outlive the result; `load` parses straight out of the arena the
/// values then live in.
fn parseKv(a: std.mem.Allocator, text: []const u8) ![]KV {
    var out: std.ArrayListUnmanaged(KV) = .empty;
    errdefer out.deinit(a);
    var stack: std.ArrayListUnmanaged([]const u8) = .empty;
    defer stack.deinit(a);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "--")) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;

        var opens: usize = 0;
        var closes: usize = 0;
        for (line) |c| {
            if (c == '{') opens += 1;
            if (c == '}') closes += 1;
        }
        var n: usize = 0;
        while (n < closes and stack.items.len > 0) : (n += 1) _ = stack.pop();

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            n = 0;
            while (n < opens) : (n += 1) try stack.append(a, "");
            continue;
        };
        const key = trim(line[0..eq]);
        var val = trim(line[eq + 1 ..]);
        while (val.len > 0 and val[val.len - 1] == ',') val = trim(val[0 .. val.len - 1]);
        if (std.mem.eql(u8, val, "{")) {
            try stack.append(a, key);
            continue;
        }
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }

        var full: std.ArrayListUnmanaged(u8) = .empty;
        defer full.deinit(a);
        var skipped_root = false;
        for (stack.items) |frame| {
            if (frame.len == 0) continue;
            if (!skipped_root) {
                skipped_root = true;
                continue;
            }
            if (full.items.len > 0) try full.append(a, '.');
            try full.appendSlice(a, frame);
        }
        if (full.items.len > 0) try full.append(a, '.');
        try full.appendSlice(a, key);

        try out.append(a, .{
            .key = try a.dupe(u8, full.items),
            .val = val,
        });
    }
    return out.toOwnedSlice(a);
}

/// First match wins (a key re-assigned in the file keeps its
/// first value).
fn strVal(kv: []const KV, key: []const u8) ?[]const u8 {
    for (kv) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.val;
    }
    return null;
}

/// `std::stoi` semantics: optional sign, then digits, stop at the first
/// character that is not one (`"12px"` -> 12). Overflow or nothing to parse
/// is the C++'s caught exception -> null.
fn stoiPrefix(s: []const u8) ?i32 {
    var i: usize = 0;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
    const start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == start) return null;
    const v = std.fmt.parseInt(i64, s[0..i], 10) catch return null;
    if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return null;
    return @intCast(v);
}

/// `std::stod` prefix parse: sign, digits and dots, then an optional
/// exponent. Anything else falls back (the C++ catches the throw).
fn stodPrefix(s: []const u8) ?f64 {
    var i: usize = 0;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
    var digits = false;
    while (i < s.len and ((s[i] >= '0' and s[i] <= '9') or s[i] == '.')) {
        if (s[i] >= '0' and s[i] <= '9') digits = true;
        i += 1;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '-' or s[j] == '+')) j += 1;
        const exp_digits = j;
        while (j < s.len and s[j] >= '0' and s[j] <= '9') j += 1;
        if (j > exp_digits) {
            i = j;
            digits = true;
        }
    }
    if (!digits) return null;
    return std.fmt.parseFloat(f64, s[0..i]) catch null;
}

/// `int_val`: empty or unparseable -> default.
fn intVal(kv: []const KV, key: []const u8, def: i32) i32 {
    const s = strVal(kv, key) orelse return def;
    if (s.len == 0) return def;
    return stoiPrefix(s) orelse def;
}

/// `bool_val`: `"true"`, `"yes"` or `"1"` — nothing else counts, not even
/// `"TRUE"`.
fn boolVal(kv: []const KV, key: []const u8, def: bool) bool {
    const s = strVal(kv, key) orelse return def;
    if (s.len == 0) return def;
    return std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes") or std.mem.eql(u8, s, "1");
}

/// `double_val`: empty or unparseable -> default.
fn doubleVal(kv: []const KV, key: []const u8, def: f64) f64 {
    const s = strVal(kv, key) orelse return def;
    if (s.len == 0) return def;
    return stodPrefix(s) orelse def;
}

// ---------------------------------------------------------------------------
// Animations list — the C++ `read_anim_lines` / `parse_anim_entry`.
// ---------------------------------------------------------------------------

/// `"windows, 1, 3.000000, default, slide"` -> name, enabled, speed, curve,
/// style. Every part is trimmed; an empty part between commas counts (the
/// C++ pushes it) while a trailing comma's empty tail does not; and a part
/// the line never had keeps the struct default. The three text parts are
/// copied into `a`.
fn parseAnimEntry(a: std.mem.Allocator, raw: []const u8) !AnimLine {
    var e: AnimLine = .{ .name = "" };
    var start: usize = 0;
    var idx: usize = 0;
    while (true) {
        const rel = std.mem.indexOfScalar(u8, raw[start..], ',');
        const seg_end = if (rel) |r| start + r else raw.len;
        const seg = trim(raw[start..seg_end]);
        if (seg_end == raw.len and seg.len == 0) break;
        switch (idx) {
            0 => e.name = try a.dupe(u8, seg),
            1 => e.enabled = std.mem.eql(u8, seg, "1") or std.mem.eql(u8, seg, "true"),
            2 => e.speed = stodPrefix(seg) orelse e.speed,
            3 => e.curve = try a.dupe(u8, seg),
            4 => e.style = try a.dupe(u8, seg),
            else => {},
        }
        idx += 1;
        if (seg_end == raw.len) break;
        start = seg_end + 1;
    }
    return e;
}

/// `read_anim_lines`: every line whose key is `animation`, in file order.
fn loadAnimLines(a: std.mem.Allocator, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = trim(raw);
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, trim(line[0..eq]), "animation")) continue;
        var val = trim(line[eq + 1 ..]);
        // Comma first, quotes second — `read_anim_lines` pops the trailing
        // comma before it unwraps the string, and `"…",` is the shape every
        // line has.
        if (val.len > 0 and val[val.len - 1] == ',') val = val[0 .. val.len - 1];
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }
        if (val.len == 0) continue;
        const e = parseAnimEntry(a, val) catch continue;
        g_anims.append(a, e) catch break;
    }
}

/// Test-side counterpart to `parseKv`: the rebuilt keys it copies.
fn freeKv(a: std.mem.Allocator, kv: []const KV) void {
    for (kv) |e| a.free(e.key);
    a.free(kv);
}

// ---------------------------------------------------------------------------
// Load.
// ---------------------------------------------------------------------------

/// Re-read every section file — the C++ `read_config()`.
pub fn load(io: std.Io) void {
    g_arena.deinit();
    g_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    g_anims = .empty;
    g_values = initValues();
    g_dirty = false;

    const a = g_arena.allocator();
    for (k_sections, 0..) |sec, si| {
        loadSection(a, io, si);
        if (std.mem.eql(u8, sec.name, "animations")) {
            if (filePath(a, sec.name)) |anim_path| {
                if (readFile(a, io, anim_path)) |text| loadAnimLines(a, text);
            } else |_| {}
        }
    }
}

fn loadSection(a: std.mem.Allocator, io: std.Io, si: usize) void {
    const text = readFile(a, io, filePath(a, k_sections[si].name) catch return) orelse return;
    const kv = parseKv(a, text) catch return;
    var i = k_sections[si].first;
    const end = k_sections[si].first + k_sections[si].len;
    while (i < end) : (i += 1) {
        const k = k_keys[i];
        const raw = strVal(kv, k.key) orelse continue;
        g_values[i] = switch (k.kind) {
            .boolean => .{ .boolean = boolVal(kv, k.key, k.default.boolean) },
            .integer => .{ .integer = intVal(kv, k.key, k.default.integer) },
            .number => .{ .number = doubleVal(kv, k.key, k.default.number) },
            // `str_val` returns the stored text even when empty, so the
            // default applies only to a key the file does not mention.
            .text => blk: {
                var v = a.dupe(u8, raw) catch k.default.text;
                // `read_input`'s one value check, and the only one in the
                // whole data layer: an unknown profile snaps back to the
                // built-in default.
                if (std.mem.eql(u8, k.key, "accel_profile") and !isKnownAccelProfile(v)) {
                    v = k.default.text;
                }
                break :blk .{ .text = v };
            },
        };
    }
}

fn isKnownAccelProfile(v: []const u8) bool {
    for ([_][]const u8{ "adaptive", "flat", "custom" }) |opt| {
        if (std.mem.eql(u8, v, opt)) return true;
    }
    return false;
}

/// Read once, then only when nothing is pending. The C++ re-reads on every
/// frame the tab is visible (`settings_app.cpp:1511`); the dirty guard is its
/// active-slider guard, widened to cover every pending edit.
pub fn ensureLoaded(io: std.Io) void {
    if (g_dirty) return;
    load(io);
}

// ---------------------------------------------------------------------------
// Write.
// ---------------------------------------------------------------------------

/// `escape_lua`: bare `true`/`false`, bare numbers, `""` for empty, quoted
/// otherwise. The bare-number arm is what round-trips `std::to_string`.
fn escapeLua(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return s;
    if (s.len == 0) return "\"\"";
    for (s) |c| {
        if (!std.ascii.isDigit(c) and c != '.' and c != '-' and c != '+') break;
    } else return s;
    return std.fmt.allocPrint(a, "\"{s}\"", .{s});
}

fn appendFmt(out: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    try out.appendSlice(a, s);
}

fn indentBy(out: *std.ArrayList(u8), a: std.mem.Allocator, levels: usize) !void {
    var i: usize = 0;
    while (i < levels * 2) : (i += 1) try out.append(a, ' ');
}

/// One `key = value,` line, indented.
fn writeKv(out: *std.ArrayList(u8), a: std.mem.Allocator, indent: usize, rel: []const u8, i: usize) !void {
    try indentBy(out, a, indent);
    try out.appendSlice(a, rel);
    try out.appendSlice(a, " = ");
    switch (g_values[i]) {
        .boolean => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .integer => |n| try appendFmt(out, a, "{d}", .{n}),
        // `std::to_string(double)` is `%f`: always six decimals.
        .number => |d| try appendFmt(out, a, "{d:.6}", .{d}),
        .text => |txt| if (k_keys[i].quote)
            try appendFmt(out, a, "\"{s}\"", .{txt})
        else
            try out.appendSlice(a, try escapeLua(a, txt)),
    }
    try out.appendSlice(a, ",\n");
}

/// `write_nested_entries`: the keys without a dot in entry order first, then
/// one sub-table per prefix, prefixes sorted the way `std::map` sorts them.
fn writeNested(out: *std.ArrayList(u8), a: std.mem.Allocator, indent: usize, sel: []const u16, base: usize) !void {
    for (sel) |i| {
        const rel = k_keys[i].key[base..];
        if (std.mem.indexOfScalar(u8, rel, '.') == null) try writeKv(out, a, indent, rel, i);
    }

    var subs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer subs.deinit(a);
    for (sel) |i| {
        const rel = k_keys[i].key[base..];
        const dot = std.mem.indexOfScalar(u8, rel, '.') orelse continue;
        const prefix = rel[0..dot];
        for (subs.items) |seen| {
            if (std.mem.eql(u8, seen, prefix)) break;
        } else try subs.append(a, prefix);
    }
    std.mem.sort([]const u8, subs.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    for (subs.items) |prefix| {
        try indentBy(out, a, indent);
        try out.appendSlice(a, prefix);
        try out.appendSlice(a, " = {\n");

        var nested: std.ArrayListUnmanaged(u16) = .empty;
        defer nested.deinit(a);
        for (sel) |i| {
            const rel = k_keys[i].key[base..];
            const dot = std.mem.indexOfScalar(u8, rel, '.') orelse continue;
            if (!std.mem.eql(u8, rel[0..dot], prefix)) continue;
            try nested.append(a, i);
        }
        try writeNested(out, a, indent + 1, nested.items, base + prefix.len + 1);

        try indentBy(out, a, indent);
        try out.appendSlice(a, "},\n");
    }
}

/// `write_animations`' per-entry block: a blank line, then a one-key
/// `hl.config({ animation = "…" })`.
fn writeAnimBlocks(out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    for (g_anims.items) |e| {
        var val: std.ArrayList(u8) = .empty;
        defer val.deinit(a);
        try val.appendSlice(a, e.name);
        try val.appendSlice(a, if (e.enabled) ", 1, " else ", 0, ");
        try appendFmt(&val, a, "{d:.6}", .{e.speed});
        try val.appendSlice(a, ", ");
        try val.appendSlice(a, e.curve);
        if (e.style.len != 0) {
            try val.appendSlice(a, ", ");
            try val.appendSlice(a, e.style);
        }
        try out.appendSlice(a, "\nhl.config({\n  animation = \"");
        try out.appendSlice(a, val.items);
        try out.appendSlice(a, "\",\n})\n");
    }
}

/// One whole `<section>.lua`, byte-for-byte.
fn sectionText(a: std.mem.Allocator, si: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const sec = k_sections[si];

    try out.appendSlice(a, sec.header);
    try out.append(a, '\n');
    try out.appendSlice(a, "hl.config({\n  ");
    try out.appendSlice(a, sec.name);
    try out.appendSlice(a, " = {\n");

    var sel: std.ArrayListUnmanaged(u16) = .empty;
    defer sel.deinit(a);
    var i = sec.first;
    const end = sec.first + sec.len;
    while (i < end) : (i += 1) {
        const k = k_keys[i];
        if (!k.write) continue;
        if (k.gate) |g| {
            if (!g_values[g].boolean) continue;
        }
        if (k.omit_empty) {
            switch (g_values[i]) {
                .text => |txt| if (txt.len == 0) continue,
                else => {},
            }
        }
        try sel.append(a, i);
    }

    try writeNested(&out, a, 2, sel.items, 0);
    try out.appendSlice(a, "  },\n})\n");
    if (std.mem.eql(u8, sec.name, "animations")) try writeAnimBlocks(&out, a);
    return out.toOwnedSlice(a);
}

/// Write every section file back — the C++ `write_config()`. Returns false
/// when any file could not be written.
pub fn save(alloc: std.mem.Allocator, io: std.Io) bool {
    var ok = true;
    var wrote_dir = false;
    for (k_sections, 0..) |sec, si| {
        const text = sectionText(alloc, si) catch {
            ok = false;
            continue;
        };
        defer alloc.free(text);
        const path = filePath(alloc, sec.name) catch {
            ok = false;
            continue;
        };
        defer alloc.free(path);
        if (!wrote_dir) {
            // The C++ has no mkdir: it fails here on a fresh install instead.
            if (configDir(alloc) catch null) |dir| {
                defer alloc.free(dir);
                std.Io.Dir.cwd().createDirPath(io, dir) catch {};
            }
            wrote_dir = true;
        }
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch {
            ok = false;
        };
    }
    return ok;
}

/// `apply_config()`: `hyprctl reload`, over the socket instead of through a
/// child process.
pub fn reload(alloc: std.mem.Allocator, io: std.Io) void {
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    if (envStr("HYPRLAND_INSTANCE_SIGNATURE")) |v| {
        env.put("HYPRLAND_INSTANCE_SIGNATURE", v) catch {};
    }
    if (envStr("XDG_RUNTIME_DIR")) |v| env.put("XDG_RUNTIME_DIR", v) catch {};
    if (hypr_ipc.ipcRequest(alloc, io, &env, "reload")) |resp| alloc.free(resp);
}

/// `write_config()` + `apply_config()` on every accepted edit.
pub fn commit(alloc: std.mem.Allocator, io: std.Io) void {
    if (!g_dirty) return;
    _ = save(alloc, io);
    reload(alloc, io);
    g_dirty = false;
}

// ---------------------------------------------------------------------------
// UI-slot accessors — the calls the sub-tabs make.
// ---------------------------------------------------------------------------

pub fn kindOf(slot: u16) Kind {
    return k_keys[k_ui[slot].key].kind;
}

/// `static_cast<int>` truncation toward zero, with the range guards the C++
/// does not need (its casts are undefined here instead).
fn toI32(x: f64) i32 {
    if (!std.math.isFinite(x)) return 0;
    if (x >= 2147483647.0) return 2147483647;
    if (x <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(x);
}

pub fn getBool(slot: u16) bool {
    const s = k_ui[slot];
    return switch (g_values[s.key]) {
        .boolean => |b| b,
        else => false,
    };
}

pub fn setBool(slot: u16, v: bool) void {
    const s = k_ui[slot];
    switch (g_values[s.key]) {
        .boolean => |*b| {
            b.* = v;
            g_dirty = true;
        },
        else => {},
    }
}

/// `ui = scale * real + offset`.
pub fn getInt(slot: u16) i32 {
    const s = k_ui[slot];
    return switch (g_values[s.key]) {
        .boolean => |b| @intFromBool(b),
        .integer => |v| s.scale * v + s.offset,
        .number => |d| toI32(d * @as(f64, @floatFromInt(s.scale))) + s.offset,
        .text => |txt| blk: {
            if (s.indexed) {
                for (s.labels, 0..) |l, i| {
                    if (std.mem.eql(u8, l, txt)) break :blk @intCast(i);
                }
            }
            // The C++ reads value_labels[val - lo] unguarded; the index it
            // could not find is 0, which is what the paint loop starts at.
            break :blk 0;
        },
    };
}

pub fn setInt(slot: u16, v: i32) void {
    const s = k_ui[slot];
    switch (g_values[s.key]) {
        .boolean => |*b| {
            b.* = v != 0;
            g_dirty = true;
        },
        .integer => |*n| {
            n.* = @divTrunc(v - s.offset, s.scale);
            g_dirty = true;
        },
        .number => |*d| {
            d.* = @as(f64, @floatFromInt(v - s.offset)) / @as(f64, @floatFromInt(s.scale));
            g_dirty = true;
        },
        .text => |*txt| {
            if (s.indexed and v >= 0 and @as(usize, @intCast(v)) < s.labels.len) {
                txt.* = s.labels[@intCast(v)];
                g_dirty = true;
            }
        },
    }
}

pub fn getStr(slot: u16) []const u8 {
    return switch (g_values[k_ui[slot].key]) {
        .text => |txt| txt,
        else => "",
    };
}

/// The caller's text must outlive the next `load` — every option list the
/// sub-tabs pass is a static table, so it does.
pub fn setStr(slot: u16, v: []const u8) void {
    const s = k_ui[slot];
    switch (g_values[s.key]) {
        .text => |*txt| {
            txt.* = v;
            g_dirty = true;
        },
        else => {},
    }
}

/// The dropdown index search the C++ Layout combo does: the first option
/// equal to the stored text, or 0 when nothing matches (C++ `layoutIdx`).
pub fn comboIndex(slot: u16, options: []const []const u8) usize {
    const v = getStr(slot);
    for (options, 0..) |o, i| {
        if (std.mem.eql(u8, o, v)) return i;
    }
    return 0;
}

pub fn setComboIndex(slot: u16, options: []const []const u8, idx: usize) void {
    if (idx < options.len) setStr(slot, options[idx]);
}

/// The pill text beside a slider: the label table when the value lands in it
/// (`value_labels[val - lo]`), else the slot's `%d %%` format, else the plain
/// number. The C++ prints no unit on these rows.
pub fn valueText(slot: u16, v: i32, lo: i32, buf: []u8) []const u8 {
    const s = k_ui[slot];
    if (s.labels.len != 0) {
        const i: i64 = @as(i64, v) - @as(i64, lo);
        if (i >= 0 and i < s.labels.len) return s.labels[@intCast(i)];
    }
    return switch (s.fmt) {
        .plain => std.fmt.bufPrint(buf, "{d}", .{v}) catch "",
        .percent => std.fmt.bufPrint(buf, "{d} %", .{v}) catch "",
    };
}

// ---------------------------------------------------------------------------
// Animation accessors — the `cfg.animations.entries` lookups the Animations
// tab and the editor popup make, by name.
// ---------------------------------------------------------------------------

pub fn animFind(name: []const u8) ?usize {
    for (g_anims.items, 0..) |e, i| {
        if (std.mem.eql(u8, e.name, name)) return i;
    }
    return null;
}

/// `find_or_create_anim`: a line the file did not have is appended, which is
/// where a new entry lands in the rewritten file.
fn animEnsure(name: []const u8) ?usize {
    if (animFind(name)) |i| return i;
    g_anims.append(g_arena.allocator(), .{ .name = name }) catch return null;
    return g_anims.items.len - 1;
}

/// An entry the file does not list is "inherited": the C++ reads it as the
/// built-in defaults (enabled, speed 3.0, curve `default`, no style).
pub fn animIsInherited(name: []const u8) bool {
    return animFind(name) == null;
}

pub fn animEnabled(name: []const u8) bool {
    const i = animFind(name) orelse return true;
    return g_anims.items[i].enabled;
}

pub fn animSpeed(name: []const u8) f64 {
    const i = animFind(name) orelse return 3.0;
    return g_anims.items[i].speed;
}

pub fn animCurve(name: []const u8) []const u8 {
    const i = animFind(name) orelse return "default";
    return g_anims.items[i].curve;
}

pub fn animStyle(name: []const u8) []const u8 {
    const i = animFind(name) orelse return "";
    return g_anims.items[i].style;
}

pub fn setAnimEnabled(name: []const u8, v: bool) void {
    const i = animEnsure(name) orelse return;
    g_anims.items[i].enabled = v;
    g_dirty = true;
}

pub fn setAnimSpeed(name: []const u8, v: f64) void {
    const i = animEnsure(name) orelse return;
    g_anims.items[i].speed = v;
    g_dirty = true;
}

pub fn setAnimCurve(name: []const u8, v: []const u8) void {
    const i = animEnsure(name) orelse return;
    g_anims.items[i].curve = v;
    g_dirty = true;
}

pub fn setAnimStyle(name: []const u8, v: []const u8) void {
    const i = animEnsure(name) orelse return;
    g_anims.items[i].style = v;
    g_dirty = true;
}

/// The line under an animation row's label: `"Inherited (3.0, default)"` for
/// an entry the file does not list, otherwise `"speed, curve"` with `", style"`
/// appended when the entry has one.
pub fn animInfo(name: []const u8, buf: []u8) []const u8 {
    const i = animFind(name) orelse {
        return std.fmt.bufPrint(buf, "Inherited ({d:.1}, {s})", .{ @as(f64, 3.0), "default" }) catch "";
    };
    const e = g_anims.items[i];
    if (e.style.len != 0) {
        return std.fmt.bufPrint(buf, "{d:.1}, {s}, {s}", .{ e.speed, e.curve, e.style }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d:.1}, {s}", .{ e.speed, e.curve }) catch "";
}

/// `get_bezier_for_curve`: the four control points behind a curve name, or
/// nothing when the name is not a preset (the bezier editor's own grid then
/// stands in). The C++ never persists them — there is no `bezier = …`
/// writer — so an edited curve is only ever recorded as its name.
pub fn bezierForCurve(name: []const u8) ?BezierPreset {
    for (k_bezier_presets) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// `split_styles`: `"slide, slidevert, fade"` -> the three names, spaces
/// dropped everywhere (not just trimmed).
pub fn splitStyles(alloc: std.mem.Allocator, styles: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var cur: std.ArrayListUnmanaged(u8) = .empty;
    defer cur.deinit(alloc);
    for (styles) |c| {
        if (c == ',') {
            try out.append(alloc, try cur.toOwnedSlice(alloc));
        } else if (c != ' ') {
            try cur.append(alloc, c);
        }
    }
    if (cur.items.len != 0) try out.append(alloc, try cur.toOwnedSlice(alloc));
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests — the file formats and transforms, no filesystem.
// ---------------------------------------------------------------------------

const t = std.testing;

test "hyprland-data: section table covers every key exactly once" {
    var seen = @as([k_keys.len]bool, @splat(false));
    for (k_sections) |sec| {
        var i = sec.first;
        const end = sec.first + sec.len;
        while (i < end) : (i += 1) {
            try t.expect(!seen[i]);
            seen[i] = true;
        }
    }
    for (seen) |s| try t.expect(s);
    try t.expectEqual(@as(usize, 291), k_keys.len);
    try t.expectEqual(@as(usize, 16), k_sections.len);
}

test "hyprland-data: ui slots point at real keys of a matching kind" {
    for (k_ui, 0..) |slot, i| {
        const k = k_keys[slot.key];
        switch (slot.indexed) {
            // A text key shown through a label table is a combo/slider over
            // the labels; an int key with labels displays `value_labels[v]`.
            true => try t.expect(k.kind == .text),
            false => try t.expect(k.kind != .text or slot.labels.len == 0),
        }
        _ = i;
    }
    try t.expectEqual(@as(usize, 179), k_ui.len);
}

test "hyprland-data: stoi/stod prefixes match std::stoi and std::stod" {
    try t.expectEqual(@as(?i32, 12), stoiPrefix("12px"));
    try t.expectEqual(@as(?i32, -5), stoiPrefix("-5.5"));
    try t.expectEqual(@as(?i32, 0), stoiPrefix("+0"));
    try t.expectEqual(@as(?i32, null), stoiPrefix("px"));
    try t.expectEqual(@as(?i32, null), stoiPrefix(""));
    try t.expectEqual(@as(?i32, null), stoiPrefix("2147483648"));
    try t.expectEqual(@as(?f64, 3.0), stodPrefix("3.000000"));
    try t.expectEqual(@as(?f64, 0.5), stodPrefix("0.5foo"));
    try t.expectEqual(@as(?f64, 1e3), stodPrefix("1e3"));
    try t.expectEqual(@as(?f64, null), stodPrefix("default"));
}

test "hyprland-data: bool_val only accepts true/yes/1" {
    const a = t.allocator;
    const kv = try parseKv(a, "a = true,\nb = yes,\nc = 1,\nd = TRUE,\ne = 0,\n");
    defer freeKv(a, kv);
    try t.expect(boolVal(kv, "a", false));
    try t.expect(boolVal(kv, "b", false));
    try t.expect(boolVal(kv, "c", false));
    try t.expect(!boolVal(kv, "d", false));
    try t.expect(!boolVal(kv, "e", true));
    try t.expect(boolVal(kv, "missing", true));
}

test "hyprland-data: parse_lua_kv tracks tables and strips quotes" {
    const a = t.allocator;
    const text =
        \\-- comment
        \\hl.config({
        \\  general = {
        \\    border_size = 1, -- trailing comment is not stripped by the C++
        \\    col = {
        \\      active_border = "rgba(1a1a1aff)",
        \\    },
        \\  },
        \\})
        \\
        \\hl.config({
        \\  animation = "windows, 1, 3.000000, default",
        \\})
        \\
    ;
    const kv = try parseKv(a, text);
    defer freeKv(a, kv);
    // The section frame is skipped, so every key comes out relative to it —
    // `border_size`, not `general.border_size` — which is what `read_general`
    // looks up. `hl.config({` pushes an *empty* frame (it has no `=`), so the
    // first non-empty one it reaches is always the section name.
    // A comma is only stripped from the very end of the value, so a trailing
    // comment keeps its own comma attached to the number.
    try t.expectEqualStrings("1, -- trailing comment is not stripped by the C++", strVal(kv, "border_size").?);
    try t.expectEqualStrings("rgba(1a1a1aff)", strVal(kv, "col.active_border").?);
    try t.expectEqualStrings("windows, 1, 3.000000, default", strVal(kv, "animation").?);
    try t.expect(strVal(kv, "general.border_size") == null);
}

test "hyprland-data: escape_lua quoting" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("true", try escapeLua(a, "true"));
    try t.expectEqualStrings("\"\"", try escapeLua(a, ""));
    try t.expectEqualStrings("20", try escapeLua(a, "20"));
    try t.expectEqualStrings("-1.5", try escapeLua(a, "-1.5"));
    try t.expectEqualStrings("---", try escapeLua(a, "---"));
    try t.expectEqualStrings("\"dwindle\"", try escapeLua(a, "dwindle"));
    try t.expectEqualStrings("\"0xee1a1a1a\"", try escapeLua(a, "0xee1a1a1a"));
}

test "hyprland-data: general.lua renders the managed section" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try sectionText(a, 0);
    defer a.free(text);
    const expected =
        \\-- General settings -- managed by Event Horizon
        \\hl.config({
        \\  general = {
        \\    border_size = 1,
        \\    gaps_in = 5,
        \\    gaps_out = 20,
        \\    float_gaps = 0,
        \\    gaps_workspaces = 0,
        \\    layout = "dwindle",
        \\    allow_tearing = false,
        \\    resize_on_border = false,
        \\    no_focus_fallback = false,
        \\    extend_border_grab_area = 15,
        \\    hover_icon_on_border = true,
        \\    resize_corner = 0,
        \\    modal_parent_blocking = true,
        \\    snap = {
        \\      enabled = false,
        \\      window_gap = 10,
        \\      monitor_gap = 0,
        \\      border_overlap = false,
        \\      respect_gaps = false,
        \\    },
        \\  },
        \\})
        \\
    ;
    try t.expectEqualStrings(expected, text);
}

test "hyprland-data: empty strings are omitted and shader is gated" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `col.*` starts empty -> no `col` sub-table at all (the nested writer
    // only sees the keys that survived), and `screen_shader` is gated off.
    const general = try sectionText(a, 0);
    defer a.free(general);
    try t.expect(std.mem.indexOf(u8, general, "col = {") == null);

    const decoration = try sectionText(a, 1);
    defer a.free(decoration);
    try t.expect(std.mem.indexOf(u8, decoration, "screen_shader") == null);
    // `screen_shader_enabled` itself is read-only and never written.
    try t.expect(std.mem.indexOf(u8, decoration, "screen_shader_enabled") == null);

    setBool(kUiSlot("blur.enabled"), false);
    defer setBool(kUiSlot("blur.enabled"), true);
    const gate_off = try sectionText(a, 1);
    try t.expect(std.mem.indexOf(u8, gate_off, "screen_shader") == null);
}

test "hyprland-data: ui transform round-trips" {
    // input.sensitivity: ui = 50*real + 50, so real 0.0 sits at 50.
    const sens = kUiSlot("sensitivity");
    const old = getInt(sens);
    defer setInt(sens, old);
    setInt(sens, 50);
    try t.expectEqual(@as(f64, 0.0), g_values[k_ui[sens].key].number);
    setInt(sens, 100);
    try t.expectEqual(@as(f64, 1.0), g_values[k_ui[sens].key].number);
    try t.expectEqual(@as(i32, 100), getInt(sens));
    // Truncation, not rounding: 0.99 * 100 lands on 99.
    g_values[k_ui[sens].key].number = 0.99;
    try t.expectEqual(@as(i32, 99), getInt(sens));
}

test "hyprland-data: indexed text keys store their label" {
    const slot = kUiSlot("new_status");
    try t.expect(k_ui[slot].indexed);
    const old = getStr(slot);
    defer setStr(slot, old);
    setStr(slot, "slave");
    try t.expectEqual(@as(i32, 1), getInt(slot));
    setStr(slot, "inherit");
    try t.expectEqual(@as(i32, 2), getInt(slot));
    setInt(slot, 0);
    try t.expectEqualStrings("master", getStr(slot));
    // Out of range leaves the value alone, where the C++ writes
    // value_labels[] past its end.
    setInt(slot, 9);
    try t.expectEqualStrings("master", getStr(slot));
}

test "hyprland-data: valueText uses labels, percent and plain numbers" {
    var buf: [64]u8 = undefined;
    const slot = kUiSlot("new_status");
    try t.expectEqualStrings("inherit", valueText(slot, 2, 0, &buf));

    const blur = kUiSlot("blur.noise");
    try t.expectEqualStrings("17 %", valueText(blur, 17, 0, &buf));

    const gaps = kUiSlot("gaps_in");
    try t.expectEqualStrings("5", valueText(gaps, 5, 0, &buf));
}

test "hyprland-data: animation entries parse and rewrite in file order" {
    // The list is module state, so it takes the module arena: mixing the two
    // would hand `append` a pointer from another arena's block.
    const a = g_arena.allocator();
    loadAnimLines(a,
        \\hl.config({
        \\  animation = "windows, 0, 1.500000, easeOut, slide",
        \\  animation = "weird_entry, 1, 2.000000, default",
        \\  animation = "fade, 1, 3.000000, default",
        \\})
    );
    try t.expectEqual(@as(usize, 3), g_anims.items.len);
    try t.expectEqualStrings("windows", g_anims.items[0].name);
    try t.expect(!g_anims.items[0].enabled);
    try t.expectEqual(@as(f64, 1.5), g_anims.items[0].speed);
    try t.expectEqualStrings("slide", g_anims.items[0].style);
    try t.expectEqualStrings("weird_entry", g_anims.items[1].name);
    try t.expectEqualStrings("fade", g_anims.items[2].name);

    // Info text, both shapes.
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("1.5, easeOut, slide", animInfo("windows", &buf));
    try t.expect(animIsInherited("global"));
    try t.expectEqualStrings("Inherited (3.0, default)", animInfo("global", &buf));

    // Turning an entry on appends the line the C++ would write.
    setAnimEnabled("global", false);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeAnimBlocks(&out, a);
    const expected =
        \\
        \\hl.config({
        \\  animation = "windows, 0, 1.500000, easeOut, slide",
        \\})
        \\
        \\hl.config({
        \\  animation = "weird_entry, 1, 2.000000, default",
        \\})
        \\
        \\hl.config({
        \\  animation = "fade, 1, 3.000000, default",
        \\})
        \\
        \\hl.config({
        \\  animation = "global, 0, 3.000000, default",
        \\})
        \\
    ;
    try t.expectEqualStrings(expected, out.items);

    // Reset for the other tests: nothing pending, defaults restored.
    g_anims = .empty;
    g_dirty = false;
}

test "hyprland-data: splitStyles drops spaces" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parts = try splitStyles(a, "slide, slidevert, fade");
    try t.expectEqual(@as(usize, 3), parts.len);
    try t.expectEqualStrings("slide", parts[0]);
    try t.expectEqualStrings("slidevert", parts[1]);
    try t.expectEqualStrings("fade", parts[2]);
    try t.expectEqual(@as(usize, 0), (try splitStyles(a, "")).len);
}

test "hyprland-data: bezier presets resolve by curve name" {
    const p = bezierForCurve("overshot").?;
    try t.expectEqual(@as(f64, 0.05), p.p1x);
    try t.expectEqual(@as(f64, 1.1), p.p2y);
    try t.expect(bezierForCurve("eh_custom") == null);
}

/// The slot bound to the section-relative key `path` (the table's keys are
/// relative to their section, the way `parse_lua_kv` leaves them) — test
/// shorthand, so a table regeneration that drops a key fails loudly here.
fn kUiSlot(path: []const u8) u16 {
    var want: u16 = 0;
    var found = false;
    for (k_keys, 0..) |k, i| {
        if (std.mem.eql(u8, k.key, path)) {
            want = @intCast(i);
            found = true;
            break;
        }
    }
    if (!found) unreachable;
    for (k_ui, 0..) |slot, i| {
        if (slot.key == want) return @intCast(i);
    }
    unreachable;
}
