//! Zoolander config data layer: typed model, loader, and writer for the
//! Lua setters in `~/.config/zoolander/*.lua`.
//!
//! Zoolander's config is LuaJIT code, not a key/value file. The settings app
//! exposes the schema-driven setters that take a table (`zl.set_window_style
//! { ... }` and friends); this layer locates the last call of a setter, reads
//! the literal at a dotted path out of its table, and rewrites only that
//! literal. Comments, surrounding calls and computed values stay as written.
//! A setter that is missing from the config gets a fresh call appended to
//! `init.lua`, so a stock config can still be edited from the settings app.
//!
//! The table parser is deliberately small: it understands the literal shapes
//! Zoolander's schema uses (booleans, numbers, quoted strings, nested tables)
//! and skips Lua comments and long strings. Values computed by code are left
//! alone; the app never tries to evaluate Lua.

const std = @import("std");

pub const Kind = enum { boolean, integer, number, text, flag, list };

pub const Meta = struct {
    setter: []const u8,
    /// Dotted path inside the setter's table (`shadow.enabled`).
    key: []const u8,
    kind: Kind,
    bool_default: bool = false,
    int_default: i32 = 0,
    num_default: f64 = 0,
    text_default: []const u8 = "",
    /// UI integer = round(value * scale). Floats use 10/100/1000 so the
    /// integer slider keeps their hundredths without a new row type.
    scale: i32 = 1,
    /// The literal is the setter's first positional argument
    /// (`zl.set_layout("scrolling")`) rather than a table key.
    positional: bool = false,
};

/// One entry per `Field.zool_*` variant, in the same order.
pub const k_meta = [_]Meta{
    // -- Displays / set_presentation --
    .{ .setter = "set_presentation", .key = "allow_tearing", .kind = .boolean },
    .{ .setter = "set_presentation", .key = "immediate_fullscreen", .kind = .boolean },
    .{ .setter = "set_presentation", .key = "direct_scanout", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_presentation", .key = "partial_damage", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_presentation", .key = "vrr", .kind = .text, .text_default = "off" },
    .{ .setter = "set_presentation", .key = "hdr", .kind = .text, .text_default = "auto" },
    .{ .setter = "set_presentation", .key = "sdr_brightness", .kind = .number, .num_default = 1, .scale = 100 },
    .{ .setter = "set_presentation", .key = "sdr_saturation", .kind = .number, .num_default = 1, .scale = 100 },
    .{ .setter = "set_presentation", .key = "sdr_min_luminance", .kind = .number, .num_default = 0, .scale = 1000 },
    .{ .setter = "set_presentation", .key = "sdr_max_luminance", .kind = .number, .num_default = 100, .scale = 1 },
    .{ .setter = "set_presentation", .key = "sdr_eotf", .kind = .text, .text_default = "gamma24" },

    // -- Keyboard --
    .{ .setter = "set_keyboard", .key = "repeat_rate", .kind = .integer, .int_default = 25 },
    .{ .setter = "set_keyboard", .key = "repeat_delay", .kind = .integer, .int_default = 600 },
    .{ .setter = "set_keyboard", .key = "numlock", .kind = .boolean },

    // -- Pointer --
    .{ .setter = "set_pointer", .key = "left_handed", .kind = .boolean },
    .{ .setter = "set_pointer", .key = "accel_profile", .kind = .text, .text_default = "adaptive" },
    .{ .setter = "set_pointer", .key = "sensitivity", .kind = .number, .num_default = 0, .scale = 100 },
    .{ .setter = "set_pointer", .key = "follow_mouse", .kind = .text, .text_default = "focus" },

    // -- Floating windows --
    .{ .setter = "set_floating", .key = "raise_on_hover", .kind = .boolean },
    .{ .setter = "set_floating", .key = "raise_delay", .kind = .integer, .int_default = 100 },

    // -- Windows / set_window_style --
    .{ .setter = "set_window_style", .key = "gaps_in", .kind = .integer },
    .{ .setter = "set_window_style", .key = "gaps_out", .kind = .integer },
    .{ .setter = "set_window_style", .key = "border_size", .kind = .integer, .int_default = 2 },
    .{ .setter = "set_window_style", .key = "rounding", .kind = .integer },
    .{ .setter = "set_window_style", .key = "rounding_power", .kind = .number, .num_default = 2, .scale = 10 },
    .{ .setter = "set_window_style", .key = "active_opacity", .kind = .number, .num_default = 1, .scale = 100 },
    .{ .setter = "set_window_style", .key = "inactive_opacity", .kind = .number, .num_default = 1, .scale = 100 },
    .{ .setter = "set_window_style", .key = "fullscreen_opacity", .kind = .number, .num_default = 1, .scale = 100 },

    // -- Decorations / set_ssd --
    .{ .setter = "set_ssd", .key = "enabled", .kind = .boolean },
    .{ .setter = "set_ssd", .key = "floating_workspaces_only", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_ssd", .key = "include_floating_windows", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_ssd", .key = "follow_theme", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_ssd", .key = "show_title", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_ssd", .key = "border", .kind = .integer, .int_default = 2 },
    .{ .setter = "set_ssd", .key = "titlebar", .kind = .integer, .int_default = 22 },
    .{ .setter = "set_ssd", .key = "title_font_size", .kind = .integer, .int_default = 13 },
    .{ .setter = "set_ssd", .key = "title_align", .kind = .text, .text_default = "center" },

    // -- Blur --
    .{ .setter = "set_blur", .key = "enabled", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_blur", .key = "ignore_opacity", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_blur", .key = "popups", .kind = .boolean },
    .{ .setter = "set_blur", .key = "popups_ignorealpha", .kind = .number, .num_default = 0.2, .scale = 100 },
    .{ .setter = "set_blur", .key = "input_methods", .kind = .boolean },
    .{ .setter = "set_blur", .key = "input_methods_ignorealpha", .kind = .number, .num_default = 0.2, .scale = 100 },
    .{ .setter = "set_blur", .key = "size", .kind = .integer, .int_default = 8 },
    .{ .setter = "set_blur", .key = "passes", .kind = .integer, .int_default = 1 },
    .{ .setter = "set_blur", .key = "resolution", .kind = .text, .text_default = "quarter" },
    .{ .setter = "set_blur", .key = "noise", .kind = .number, .num_default = 0.0117, .scale = 1000 },
    .{ .setter = "set_blur", .key = "contrast", .kind = .number, .num_default = 0.8916, .scale = 100 },
    .{ .setter = "set_blur", .key = "brightness", .kind = .number, .num_default = 1, .scale = 100 },
    .{ .setter = "set_blur", .key = "vibrancy", .kind = .number, .num_default = 0.1696, .scale = 100 },
    .{ .setter = "set_blur", .key = "vibrancy_darkness", .kind = .number, .num_default = 0, .scale = 100 },

    // -- Dimming --
    .{ .setter = "set_dim", .key = "inactive", .kind = .boolean },
    .{ .setter = "set_dim", .key = "strength", .kind = .number, .num_default = 0.5, .scale = 100 },
    .{ .setter = "set_dim", .key = "special", .kind = .number, .num_default = 0.2, .scale = 100 },
    .{ .setter = "set_dim", .key = "around", .kind = .number, .num_default = 0, .scale = 100 },

    // -- Tab bar --
    .{ .setter = "set_tab_bar", .key = "enabled", .kind = .boolean },
    .{ .setter = "set_tab_bar", .key = "height", .kind = .integer, .int_default = 30 },
    .{ .setter = "set_tab_bar", .key = "radius", .kind = .integer, .int_default = 8 },
    .{ .setter = "set_tab_bar", .key = "gap", .kind = .integer, .int_default = 3 },
    .{ .setter = "set_tab_bar", .key = "padding_x", .kind = .integer, .int_default = 12 },
    .{ .setter = "set_tab_bar", .key = "size", .kind = .integer, .int_default = 13 },
    .{ .setter = "set_tab_bar", .key = "monocle_all", .kind = .boolean, .bool_default = true },

    // -- Animations --
    .{ .setter = "set_animations", .key = "enabled", .kind = .boolean },
    .{ .setter = "set_animations", .key = "duration", .kind = .integer, .int_default = 180 },
    .{ .setter = "set_animations", .key = "easing", .kind = .text, .text_default = "ease_out_cubic" },

    // -- Default layout (`set_layout`) --
    // The layout name is the first positional argument; the optional ratio
    // and master count after it stay untouched.
    .{ .setter = "set_layout", .key = "layout", .kind = .text, .text_default = "master_stack", .positional = true },

    // -- Dwindle --
    .{ .setter = "set_dwindle", .key = "preserve_split", .kind = .boolean },
    .{ .setter = "set_dwindle", .key = "smart_split", .kind = .boolean },
    .{ .setter = "set_dwindle", .key = "smart_resizing", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_dwindle", .key = "force_split", .kind = .integer },
    .{ .setter = "set_dwindle", .key = "split_width_multiplier", .kind = .number, .num_default = 1, .scale = 10 },

    // -- Spatial layouts --
    .{ .setter = "set_spatial", .key = "fallback_width", .kind = .number, .num_default = 0.667, .scale = 1000 },
    .{ .setter = "set_spatial", .key = "fallback_height", .kind = .number, .num_default = 0.75, .scale = 1000 },
    .{ .setter = "set_spatial", .key = "width_cap", .kind = .integer, .int_default = 1440 },
    .{ .setter = "set_spatial", .key = "shelf_width", .kind = .integer },
    .{ .setter = "set_spatial", .key = "shelf_mode", .kind = .text, .text_default = "auto" },
    .{ .setter = "set_spatial", .key = "snap", .kind = .integer, .int_default = 12 },
    .{ .setter = "set_spatial", .key = "reveal_margin", .kind = .integer, .int_default = 24 },
    .{ .setter = "set_spatial", .key = "pan_fingers", .kind = .integer, .int_default = 3 },

    // -- Overview --
    .{ .setter = "set_overview", .key = "axis", .kind = .text, .text_default = "vertical" },
    .{ .setter = "set_overview", .key = "rail", .kind = .text, .text_default = "bottom" },
    .{ .setter = "set_overview", .key = "scale", .kind = .number, .num_default = 1, .scale = 100 },

    // -- XWayland --
    .{ .setter = "set_xwayland", .key = "enabled", .kind = .boolean, .bool_default = true },
    .{ .setter = "set_xwayland", .key = "force_zero_scaling", .kind = .boolean },

    // -- Keyboard XKB layout (`set_keyboard`) --
    .{ .setter = "set_keyboard", .key = "layout", .kind = .text },
    .{ .setter = "set_keyboard", .key = "variant", .kind = .text },
    .{ .setter = "set_keyboard", .key = "options", .kind = .text },
    .{ .setter = "set_keyboard", .key = "model", .kind = .text },
    .{ .setter = "set_keyboard", .key = "rules", .kind = .text },

    // -- Window borders (`set_window_style`) --
    .{ .setter = "set_window_style", .key = "active_border", .kind = .text, .text_default = "#598cf2ff" },
    .{ .setter = "set_window_style", .key = "active_border_end", .kind = .text, .text_default = "#598cf2ff" },
    .{ .setter = "set_window_style", .key = "active_border_angle", .kind = .number, .num_default = 0, .scale = 10 },
    .{ .setter = "set_window_style", .key = "inactive_border", .kind = .text, .text_default = "#40404dff" },
    .{ .setter = "set_window_style", .key = "inactive_border_end", .kind = .text, .text_default = "#40404dff" },
    .{ .setter = "set_window_style", .key = "inactive_border_angle", .kind = .number, .num_default = 0, .scale = 10 },

    // -- Server-side decoration colours (`set_ssd`) --
    .{ .setter = "set_ssd", .key = "active_border", .kind = .text, .text_default = "#598cf2ff" },
    .{ .setter = "set_ssd", .key = "active_border_end", .kind = .text, .text_default = "#598cf2ff" },
    .{ .setter = "set_ssd", .key = "active_border_angle", .kind = .number, .num_default = 0, .scale = 10 },
    .{ .setter = "set_ssd", .key = "inactive_border", .kind = .text, .text_default = "#40404dff" },
    .{ .setter = "set_ssd", .key = "inactive_border_end", .kind = .text, .text_default = "#40404dff" },
    .{ .setter = "set_ssd", .key = "inactive_border_angle", .kind = .number, .num_default = 0, .scale = 10 },
    .{ .setter = "set_ssd", .key = "active_titlebar", .kind = .text, .text_default = "#292e3dff" },
    .{ .setter = "set_ssd", .key = "inactive_titlebar", .kind = .text, .text_default = "#1a1a21ff" },
    .{ .setter = "set_ssd", .key = "title_color", .kind = .text, .text_default = "#ebf0faff" },
    .{ .setter = "set_ssd", .key = "inactive_title_color", .kind = .text, .text_default = "#ebf0faff" },
    .{ .setter = "set_ssd", .key = "title_font", .kind = .text },

    // -- Tab bar theme (`set_tab_bar`) --
    .{ .setter = "set_tab_bar", .key = "font", .kind = .text },
    .{ .setter = "set_tab_bar", .key = "bg", .kind = .text },
    .{ .setter = "set_tab_bar", .key = "fg", .kind = .text },
    .{ .setter = "set_tab_bar", .key = "focus_bg", .kind = .text },
    .{ .setter = "set_tab_bar", .key = "focus_fg", .kind = .text },

    // -- Animation master flags (bare calls, not tables) --
    .{ .setter = "set_animations_enabled", .key = "enabled", .kind = .flag, .bool_default = true },
    .{ .setter = "set_reduced_motion", .key = "enabled", .kind = .flag },

    // -- Window shadows (`set_window_style.shadow.*`) --
    .{ .setter = "set_window_style", .key = "shadow.enabled", .kind = .boolean },
    .{ .setter = "set_window_style", .key = "shadow.range", .kind = .integer, .int_default = 16 },
    .{ .setter = "set_window_style", .key = "shadow.sharp", .kind = .number, .num_default = 0, .scale = 100 },
    .{ .setter = "set_window_style", .key = "shadow.render_power", .kind = .number, .num_default = 2, .scale = 10 },
    .{ .setter = "set_window_style", .key = "shadow.offset_x", .kind = .integer },
    .{ .setter = "set_window_style", .key = "shadow.offset_y", .kind = .integer },
    .{ .setter = "set_window_style", .key = "shadow.scale", .kind = .number, .num_default = 1, .scale = 100 },
    .{ .setter = "set_window_style", .key = "shadow.color", .kind = .text, .text_default = "#00000066" },
    .{ .setter = "set_window_style", .key = "shadow.color_inactive", .kind = .text, .text_default = "#00000066" },

    // -- Scrolling layouts (`set_scrolling`) --
    // Comma-separated floats in the UI; the writer emits a Lua list.
    .{ .setter = "set_scrolling", .key = "width_presets", .kind = .list, .text_default = "0.333, 0.667, 1" },
};

pub const slot_count: u16 = k_meta.len;

pub const Value = union(enum) {
    boolean: bool,
    integer: i64,
    number: f64,
    text: []const u8,
};

// State.

var g_values: [k_meta.len]Value = initValues();
var g_edits: [k_meta.len]?Value = @splat(null);
var g_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var g_files: std.ArrayListUnmanaged(File) = .empty;
var g_dirty = false;

/// `set_presentation` touches the display group, so an applied change waits
/// for an explicit keep. The files written by the first commit in the window
/// are kept here so a timeout can put them back.
pub const confirm_seconds: u32 = 15;

const Backup = struct {
    path: []u8,
    /// null when the file did not exist before the commit.
    text: ?[]const u8,
};

var g_backups: std.ArrayListUnmanaged(Backup) = .empty;
var g_confirm_pending = false;
var g_confirm_deadline_ms: i64 = 0;

fn nowMs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * 1000 +
        @as(i64, @intCast(@divTrunc(@max(ts.nsec, 0), 1_000_000)));
}

pub fn confirmPending() bool {
    return g_confirm_pending;
}

pub fn confirmRemaining() u32 {
    if (!g_confirm_pending) return 0;
    const left = g_confirm_deadline_ms - nowMs();
    if (left <= 0) return 0;
    return @intCast(@divTrunc(left + 999, 1000));
}

fn freeBackups() void {
    for (g_backups.items) |b| {
        std.heap.page_allocator.free(b.path);
        if (b.text) |t| std.heap.page_allocator.free(t);
    }
    g_backups.deinit(std.heap.page_allocator);
    g_backups = .empty;
}

/// Accept the applied display settings.
pub fn keep(io: std.Io) void {
    clearMarker(io);
    freeBackups();
    g_confirm_pending = false;
    g_confirm_deadline_ms = 0;
}

/// Restore every file captured by the first display commit and reload.
pub fn revert(io: std.Io) void {
    for (g_backups.items) |b| {
        if (b.text) |t| {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = b.path, .data = t }) catch {};
        } else {
            std.Io.Dir.cwd().deleteFile(io, b.path) catch {};
        }
    }
    clearMarker(io);
    freeBackups();
    g_confirm_pending = false;
    g_confirm_deadline_ms = 0;
    reload(std.heap.page_allocator, io);
    load(io);
}

/// Called from the repaint tick; reverts when the window has expired.
pub fn tick(io: std.Io) bool {
    if (!g_confirm_pending) return false;
    if (nowMs() < g_confirm_deadline_ms) return false;
    revert(io);
    return true;
}

fn markerPath(a: std.mem.Allocator) ?[]u8 {
    const dir = configDir(a) catch return null;
    defer a.free(dir);
    return std.fmt.allocPrint(a, "{s}/.eh-pending-presentation", .{dir}) catch null;
}

fn clearMarker(io: std.Io) void {
    const a = std.heap.page_allocator;
    const path = markerPath(a) orelse return;
    defer a.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn writeMarker(io: std.Io) void {
    const a = std.heap.page_allocator;
    const path = markerPath(a) orelse return;
    defer a.free(path);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    out.appendSlice(a, "EHP1\n") catch return;
    for (g_backups.items) |b| {
        out.appendSlice(a, b.path) catch return;
        out.append(a, '\n') catch return;
        out.appendSlice(a, if (b.text != null) "1\n" else "0\n") catch return;
        var nb: [24]u8 = undefined;
        const txt: []const u8 = b.text orelse "";
        const ns = std.fmt.bufPrint(&nb, "{d}\n", .{txt.len}) catch return;
        out.appendSlice(a, ns) catch return;
        out.appendSlice(a, b.text orelse "") catch return;
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch {};
}

/// Restore presentation files captured before a commit that was never kept.
/// Called once at window startup, before the first `load`.
pub fn recoverAtLaunch(io: std.Io) void {
    const a = std.heap.page_allocator;
    const path = markerPath(a) orelse return;
    defer a.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20)) catch return;
    defer a.free(data);
    if (!std.mem.startsWith(u8, data, "EHP1\n")) {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        return;
    }
    const cwd = std.Io.Dir.cwd();
    var pos: usize = 5;
    while (pos < data.len) {
        const pnl = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse break;
        const fpath = data[pos..pnl];
        pos = pnl + 1;
        const hnl = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse break;
        const had = std.mem.eql(u8, std.mem.trim(u8, data[pos..hnl], " \t\r"), "1");
        pos = hnl + 1;
        const lnl = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse break;
        const n = std.fmt.parseInt(usize, std.mem.trim(u8, data[pos..lnl], " \t\r"), 10) catch break;
        pos = lnl + 1;
        if (pos + n > data.len) break;
        const text = data[pos .. pos + n];
        pos += n;
        if (had) {
            cwd.writeFile(io, .{ .sub_path = fpath, .data = text }) catch {};
        } else {
            cwd.deleteFile(io, fpath) catch {};
        }
    }
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    reload(a, io);
    load(io);
}

fn captureBackup(path: []const u8, io: std.Io) void {
    if (g_confirm_pending) return;
    const a = std.heap.page_allocator;
    const path_copy = a.dupe(u8, path) catch return;
    const text_copy = readFile(a, io, path);
    g_backups.append(a, .{ .path = path_copy, .text = text_copy }) catch {
        a.free(path_copy);
        if (text_copy) |t| a.free(t);
    };
}

const File = struct {
    path: []const u8,
    text: []const u8,
};

fn initValues() [k_meta.len]Value {
    var out: [k_meta.len]Value = undefined;
    for (&out, 0..) |*v, i| {
        const m = k_meta[i];
        v.* = switch (m.kind) {
            .boolean, .flag => .{ .boolean = m.bool_default },
            .integer => .{ .integer = m.int_default },
            .number => .{ .number = m.num_default },
            .text, .list => .{ .text = m.text_default },
        };
    }
    return out;
}

pub fn isDirty() bool {
    return g_dirty;
}

pub fn markDirty() void {
    g_dirty = true;
}

// Paths.

fn envStr(key: [:0]const u8) ?[]const u8 {
    const p = std.c.getenv(key) orelse return null;
    const s = std.mem.span(p);
    return if (s.len == 0) null else s;
}

fn homeDir() []const u8 {
    return envStr("HOME") orelse "/tmp";
}

/// `$XDG_CONFIG_HOME/zoolander`, or `~/.config/zoolander`.
pub fn configDir(a: std.mem.Allocator) ![]u8 {
    const base = envStr("XDG_CONFIG_HOME") orelse return std.fmt.allocPrint(a, "{s}/.config/zoolander", .{homeDir()});
    return std.fmt.allocPrint(a, "{s}/zoolander", .{base});
}

fn readFile(a: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20)) catch null;
}

// Tiny Lua table parser. It never evaluates code; it only records spans.

const Entry = struct {
    key: []const u8,
    value_start: usize,
    value_end: usize,
    child: ?*Object = null,
};

const Object = struct {
    open: usize,
    close: usize = 0,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
};

const Call = struct {
    name: []const u8,
    object: ?*Object = null,
    arg_start: usize = 0,
    arg_end: usize = 0,
};

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn skipLongBracket(text: []const u8, i: usize) ?usize {
    if (i >= text.len or text[i] != '[') return null;
    var j = i + 1;
    var eqs: usize = 0;
    while (j < text.len and text[j] == '=') : (j += 1) eqs += 1;
    if (j >= text.len or text[j] != '[') return null;
    j += 1;
    while (j < text.len) : (j += 1) {
        if (text[j] == ']') {
            var k = j + 1;
            var n: usize = 0;
            while (n < eqs and k < text.len and text[k] == '=') : ({
                k += 1;
                n += 1;
            }) {}
            if (n == eqs and k < text.len and text[k] == ']') return k + 1;
        }
    }
    return text.len;
}

fn skipString(text: []const u8, i: usize) usize {
    const quote = text[i];
    var j = i + 1;
    while (j < text.len) : (j += 1) {
        if (text[j] == '\\' and j + 1 < text.len) {
            j += 1;
            continue;
        }
        if (text[j] == quote) return j + 1;
    }
    return text.len;
}

fn skipWsComments(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) {
        if (std.ascii.isWhitespace(text[i])) {
            i += 1;
            continue;
        }
        if (i + 1 < text.len and text[i] == '-' and text[i + 1] == '-') {
            if (skipLongBracket(text, i + 2)) |end| {
                i = end;
                continue;
            }
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        break;
    }
    return i;
}

/// Skip a non-table value up to its top-level `,`, `;`, `}` or `)`.
fn scanValue(text: []const u8, start: usize) usize {
    var i = start;
    var depth: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"' or c == '\'') {
            i = skipString(text, i);
            continue;
        }
        if (c == '[') {
            if (skipLongBracket(text, i)) |end| {
                i = end;
                continue;
            }
        }
        if (c == '-' and i + 1 < text.len and text[i + 1] == '-') {
            const end = skipWsComments(text, i);
            i = end;
            continue;
        }
        switch (c) {
            '{', '(', '[' => depth += 1,
            '}', ')' => {
                if (depth == 0) return i;
                depth -= 1;
            },
            ']' => if (depth > 0) {
                depth -= 1;
            },
            ',', ';' => if (depth == 0) return i,
            else => {},
        }
        i += 1;
    }
    return i;
}

fn parseObject(a: std.mem.Allocator, text: []const u8, open: usize) !*Object {
    const obj = try a.create(Object);
    obj.* = .{ .open = open };
    var i = open + 1;
    while (true) {
        i = skipWsComments(text, i);
        if (i >= text.len) return error.UnterminatedTable;
        if (text[i] == '}') {
            obj.close = i;
            return obj;
        }
        if (text[i] == ',' or text[i] == ';') {
            i += 1;
            continue;
        }
        var key: []const u8 = "";
        if (text[i] == '[') {
            var j = i + 1;
            if (j < text.len and (text[j] == '"' or text[j] == '\'')) {
                const quote = text[j];
                j += 1;
                const ks = j;
                while (j < text.len and text[j] != quote) : (j += 1) {
                    if (text[j] == '\\' and j + 1 < text.len) j += 1;
                }
                key = text[ks..j];
                if (j < text.len) j += 1;
            }
            while (j < text.len and text[j] != ']') j += 1;
            if (j < text.len) j += 1;
            i = j;
        } else if (isIdent(text[i])) {
            const ks = i;
            while (i < text.len and isIdent(text[i])) i += 1;
            key = text[ks..i];
        } else {
            i += 1;
            continue;
        }
        i = skipWsComments(text, i);
        if (i >= text.len or text[i] != '=') {
            i = scanValue(text, i);
            continue;
        }
        i += 1;
        i = skipWsComments(text, i);
        const value_start = i;
        var value_end: usize = 0;
        var child: ?*Object = null;
        if (i < text.len and text[i] == '{') {
            child = try parseObject(a, text, i);
            value_end = child.?.close + 1;
            i = value_end;
        } else {
            value_end = scanValue(text, i);
            i = value_end;
        }
        try obj.entries.append(a, .{
            .key = key,
            .value_start = value_start,
            .value_end = value_end,
            .child = child,
        });
    }
}

fn scanCalls(a: std.mem.Allocator, text: []const u8) ![]Call {
    var out: std.ArrayListUnmanaged(Call) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"' or c == '\'') {
            i = skipString(text, i);
            continue;
        }
        if (c == '[') {
            if (skipLongBracket(text, i)) |end| {
                i = end;
                continue;
            }
        }
        if (c == '-' and i + 1 < text.len and text[i + 1] == '-') {
            i = skipWsComments(text, i);
            continue;
        }
        if (i + 1 < text.len and text[i] == 'z' and text[i + 1] == 'l' and
            (i == 0 or !isIdent(text[i - 1])) and (i + 2 >= text.len or !isIdent(text[i + 2])))
        {
            var j = skipWsComments(text, i + 2);
            if (j < text.len and text[j] == '.') {
                j = skipWsComments(text, j + 1);
                const name_start = j;
                while (j < text.len and isIdent(text[j])) j += 1;
                const name = text[name_start..j];
                j = skipWsComments(text, j);
                if (name.len > 0 and j < text.len and text[j] == '(') {
                    j = skipWsComments(text, j + 1);
                    const arg_start = j;
                    if (j < text.len and text[j] == '{') {
                        const obj = parseObject(a, text, j) catch null;
                        try out.append(a, .{ .name = name, .object = obj, .arg_start = arg_start });
                        i = if (obj) |o| o.close + 1 else j + 1;
                        continue;
                    }
                    const end = scanValue(text, j);
                    try out.append(a, .{ .name = name, .arg_start = arg_start, .arg_end = end });
                    i = end;
                    continue;
                }
            }
        }
        i += 1;
    }
    return out.toOwnedSlice(a);
}

fn findDirect(obj: *const Object, key: []const u8) ?*const Entry {
    var i = obj.entries.items.len;
    while (i > 0) {
        i -= 1;
        const e = &obj.entries.items[i];
        if (std.mem.eql(u8, e.key, key)) return e;
    }
    return null;
}

fn findEntry(obj: *const Object, path: []const u8) ?*const Entry {
    var cur = obj;
    var it = std.mem.splitScalar(u8, path, '.');
    var seg = it.next() orelse return null;
    while (true) {
        const e = findDirect(cur, seg) orelse return null;
        if (it.next()) |next| {
            cur = e.child orelse return null;
            seg = next;
        } else {
            return e;
        }
    }
}

// Formatting.

fn formatNumber(buf: []u8, v: f64) []const u8 {
    const s = std.fmt.bufPrint(buf, "{d:.4}", .{v}) catch return "0";
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

fn formatLiteral(buf: []u8, v: Value) []const u8 {
    return switch (v) {
        .boolean => |b| if (b) "true" else "false",
        .integer => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch "0",
        .number => |n| formatNumber(buf, n),
        .text => |s| blk: {
            if (buf.len < 2) return "\"\"";
            var i: usize = 0;
            buf[i] = '"';
            i += 1;
            for (s) |c| {
                if (i + 3 >= buf.len) break;
                if (c == '"' or c == '\\') {
                    buf[i] = '\\';
                    i += 1;
                }
                buf[i] = c;
                i += 1;
            }
            buf[i] = '"';
            i += 1;
            break :blk buf[0..i];
        },
    };
}

/// Render the editable comma-separated text as a Lua list literal. Tokens
/// that are not finite numbers fall back to a quoted string so a typo can
/// never inject code into the config.
fn formatList(buf: []u8, text: []const u8) []const u8 {
    if (buf.len < 4) return "{}";
    var n: usize = 0;
    buf[n] = '{';
    buf[n + 1] = ' ';
    n += 2;
    var any = false;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        const item = std.mem.trim(u8, part, " \t\r\n");
        if (item.len == 0) continue;
        if (any) {
            if (n + 2 >= buf.len) break;
            buf[n] = ',';
            buf[n + 1] = ' ';
            n += 2;
        }
        const numeric = if (std.fmt.parseFloat(f64, item)) |_| true else |_| false;
        if (numeric) {
            if (n + item.len + 2 >= buf.len) break;
            @memcpy(buf[n .. n + item.len], item);
            n += item.len;
        } else {
            if (n + 2 >= buf.len) break;
            buf[n] = '"';
            n += 1;
            for (item) |ch| {
                const need: usize = if (ch == '"' or ch == '\\') 2 else 1;
                if (n + need + 2 >= buf.len) break;
                if (need == 2) {
                    buf[n] = '\\';
                    n += 1;
                }
                buf[n] = ch;
                n += 1;
            }
            buf[n] = '"';
            n += 1;
        }
        any = true;
    }
    if (n + 2 < buf.len) {
        if (any) {
            buf[n] = ' ';
            n += 1;
        }
        buf[n] = '}';
        n += 1;
    }
    return buf[0..n];
}

fn nestedLiteral(a: std.mem.Allocator, path: []const u8, lit: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, path, '.')) |dot| {
        const head = path[0..dot];
        const tail = try nestedLiteral(a, path[dot + 1 ..], lit);
        defer a.free(tail);
        return std.fmt.allocPrint(a, "{s} = {{ {s} }}", .{ head, tail });
    }
    return std.fmt.allocPrint(a, "{s} = {s}", .{ path, lit });
}

fn insertSnippet(a: std.mem.Allocator, text: []const u8, obj: *const Object, snippet: []const u8) ![]u8 {
    const at = obj.close;
    var prev = at;
    while (prev > obj.open + 1 and std.ascii.isWhitespace(text[prev - 1])) prev -= 1;
    const need_comma = prev > obj.open + 1 and text[prev - 1] != '{' and text[prev - 1] != ',' and text[prev - 1] != ';';
    const prefix: []const u8 = if (need_comma) ", " else "";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, text[0..at]);
    try out.appendSlice(a, prefix);
    try out.appendSlice(a, snippet);
    try out.appendSlice(a, ", ");
    try out.appendSlice(a, text[at..]);
    return out.toOwnedSlice(a);
}

fn replaceSpan(a: std.mem.Allocator, text: []const u8, start: usize, end: usize, lit: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, text[0..start]);
    try out.appendSlice(a, lit);
    try out.appendSlice(a, text[end..]);
    return out.toOwnedSlice(a);
}

/// Rewrite one setter literal in `text`. Returns a new allocation, or null
/// when the setter has no call at all (the file writer then appends one).
fn editText(a: std.mem.Allocator, text: []const u8, setter: []const u8, key: []const u8, lit: []const u8) !?[]u8 {
    const calls = try scanCalls(a, text);
    var best: ?*Object = null;
    var last: ?*Object = null;
    for (calls) |c| {
        if (!std.mem.eql(u8, c.name, setter)) continue;
        const obj = c.object orelse continue;
        last = obj;
        if (findEntry(obj, key) != null) best = obj;
    }
    const target = best orelse last orelse return null;
    if (findEntry(target, key)) |e| {
        return try replaceSpan(a, text, e.value_start, e.value_end, lit);
    }
    const snippet = try nestedLiteral(a, key, lit);
    defer a.free(snippet);
    return try insertSnippet(a, text, target, snippet);
}

/// Rewrite the boolean argument of a bare-call setter (`zl.set_reduced_motion
/// (true)`). Returns null when the call is absent, so the writer appends one.
fn editFlag(a: std.mem.Allocator, text: []const u8, setter: []const u8, lit: []const u8) !?[]u8 {
    const calls = try scanCalls(a, text);
    var last: ?Call = null;
    for (calls) |c| {
        if (std.mem.eql(u8, c.name, setter) and c.object == null) last = c;
    }
    const c = last orelse return null;
    return try replaceSpan(a, text, c.arg_start, c.arg_end, lit);
}

/// Rewrite the first positional argument of a setter call
/// (`zl.set_layout("dwindle", 0.62)`), leaving the arguments after it alone.
/// Returns null when the call is absent, so the writer appends one.
fn editArgText(a: std.mem.Allocator, text: []const u8, setter: []const u8, lit: []const u8) !?[]u8 {
    const calls = try scanCalls(a, text);
    var last: ?Call = null;
    for (calls) |c| {
        if (std.mem.eql(u8, c.name, setter) and c.object == null) last = c;
    }
    const c = last orelse return null;
    if (c.arg_start >= c.arg_end) return null;
    return try replaceSpan(a, text, c.arg_start, c.arg_end, lit);
}

fn appendArgCall(a: std.mem.Allocator, text: []const u8, setter: []const u8, lit: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.append(a, '\n');
    try out.appendSlice(a, "\nzl.");
    try out.appendSlice(a, setter);
    try out.append(a, '(');
    try out.appendSlice(a, lit);
    try out.appendSlice(a, ")\n");
    return out.toOwnedSlice(a);
}

fn appendFlagCall(a: std.mem.Allocator, text: []const u8, setter: []const u8, lit: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.append(a, '\n');
    try out.appendSlice(a, "\nzl.");
    try out.appendSlice(a, setter);
    try out.append(a, '(');
    try out.appendSlice(a, lit);
    try out.appendSlice(a, ")\n");
    return out.toOwnedSlice(a);
}

fn appendCall(a: std.mem.Allocator, text: []const u8, setter: []const u8, key: []const u8, lit: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.append(a, '\n');
    try out.append(a, '\n');
    try out.appendSlice(a, "zl.");
    try out.appendSlice(a, setter);
    try out.appendSlice(a, "({\n    ");
    try out.appendSlice(a, key);
    try out.appendSlice(a, " = ");
    try out.appendSlice(a, lit);
    try out.appendSlice(a, ",\n})\n");
    return out.toOwnedSlice(a);
}

// Load.

/// Re-read every Lua file in the config directory. Missing files and
/// directories simply leave the schema defaults in place.
pub fn load(io: std.Io) void {
    g_arena.deinit();
    g_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    g_files = .empty;
    g_values = initValues();
    g_edits = @splat(null);
    g_dirty = false;

    const a = g_arena.allocator();
    const dir_path = configDir(a) catch return;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.name, ".lua")) continue;
        const name = a.dupe(u8, e.name) catch continue;
        names.append(a, name) catch continue;
    }
    std.mem.sort([]const u8, names.items, {}, nameLessThan);
    for (names.items) |name| {
        const path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, name }) catch continue;
        const text = readFile(a, io, path) orelse continue;
        g_files.append(a, .{ .path = path, .text = text }) catch continue;
    }

    for (g_files.items) |f| {
        const calls = scanCalls(a, f.text) catch continue;
        for (calls) |c| {
            for (k_meta, 0..) |m, i| {
                if (!std.mem.eql(u8, m.setter, c.name)) continue;
                if (m.kind == .flag) {
                    const raw = std.mem.trim(u8, f.text[c.arg_start..c.arg_end], " \t\r\n");
                    g_values[i] = parseValue(a, m, raw);
                    continue;
                }
                if (m.positional) {
                    const raw = std.mem.trim(u8, f.text[c.arg_start..c.arg_end], " \t\r\n");
                    // A computed first argument (a Lua function that places
                    // windows) is not ours to interpret; keep the default.
                    if (raw.len < 2 or (raw[0] != '"' and raw[0] != '\'')) continue;
                    g_values[i] = parseValue(a, m, raw);
                    continue;
                }
                const obj = c.object orelse continue;
                const e = findEntry(obj, m.key) orelse continue;
                const raw = std.mem.trim(u8, f.text[e.value_start..e.value_end], " \t\r\n");
                g_values[i] = parseValue(a, m, raw);
            }
        }
    }
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, "init.lua")) return false;
    if (std.mem.eql(u8, b, "init.lua")) return true;
    return std.mem.lessThan(u8, a, b);
}

fn parseValue(a: std.mem.Allocator, m: Meta, raw: []const u8) Value {
    return switch (m.kind) {
        .boolean, .flag => .{ .boolean = std.mem.eql(u8, raw, "true") },
        .integer => .{ .integer = std.fmt.parseInt(i64, raw, 10) catch m.int_default },
        .number => .{ .number = std.fmt.parseFloat(f64, raw) catch m.num_default },
        .text => blk: {
            var s = raw;
            if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
                s = s[1 .. s.len - 1];
            }
            break :blk .{ .text = a.dupe(u8, s) catch m.text_default };
        },
        .list => blk: {
            // Show a Lua list as the comma-separated text the band edits.
            var s = std.mem.trim(u8, raw, " \t\r\n");
            if (s.len >= 2 and s[0] == '{' and s[s.len - 1] == '}') s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
            var out: std.ArrayListUnmanaged(u8) = .empty;
            var it = std.mem.splitScalar(u8, s, ',');
            var first = true;
            while (it.next()) |part| {
                const item = std.mem.trim(u8, part, " \t\r\n");
                if (item.len == 0) continue;
                if (!first) out.appendSlice(a, ", ") catch {};
                out.appendSlice(a, item) catch {};
                first = false;
            }
            break :blk .{ .text = out.toOwnedSlice(a) catch m.text_default };
        },
    };
}

pub fn ensureLoaded(io: std.Io) void {
    if (g_dirty) return;
    load(io);
}

// UI accessors.

fn uiToValue(m: Meta, v: i32) Value {
    return switch (m.kind) {
        .boolean, .flag => .{ .boolean = v != 0 },
        .integer => .{ .integer = v },
        .number => .{ .number = @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(m.scale)) },
        .text, .list => .{ .text = "" },
    };
}

pub fn kindOf(slot: u16) Kind {
    return k_meta[slot].kind;
}

pub fn getBool(slot: u16) bool {
    return switch (g_values[slot]) {
        .boolean => |b| b,
        .integer => |n| n != 0,
        .number => |n| n != 0,
        .text => |s| s.len > 0,
    };
}

pub fn setBool(slot: u16, v: bool) void {
    g_values[slot] = .{ .boolean = v };
    g_edits[slot] = .{ .boolean = v };
    g_dirty = true;
}

pub fn getInt(slot: u16) i32 {
    const m = k_meta[slot];
    return switch (g_values[slot]) {
        .boolean => |b| if (b) 1 else 0,
        .integer => |n| std.math.cast(i32, n) orelse if (n > 0) std.math.maxInt(i32) else std.math.minInt(i32),
        .number => |n| blk: {
            const scaled = @round(n * @as(f64, @floatFromInt(m.scale)));
            if (scaled >= 2147483647.0) break :blk std.math.maxInt(i32);
            if (scaled <= -2147483648.0) break :blk std.math.minInt(i32);
            break :blk @intFromFloat(scaled);
        },
        .text => 0,
    };
}

pub fn setInt(slot: u16, v: i32) void {
    const m = k_meta[slot];
    const value = uiToValue(m, v);
    g_values[slot] = value;
    g_edits[slot] = value;
    g_dirty = true;
}

pub fn getStr(slot: u16) []const u8 {
    return switch (g_values[slot]) {
        .text => |s| s,
        else => "",
    };
}

pub fn setStr(slot: u16, v: []const u8) void {
    g_values[slot] = .{ .text = v };
    g_edits[slot] = .{ .text = v };
    g_dirty = true;
}

pub fn comboIndex(slot: u16, options: []const []const u8) usize {
    const cur = getStr(slot);
    for (options, 0..) |opt, i| {
        if (std.mem.eql(u8, opt, cur)) return i;
    }
    return 0;
}

pub fn setComboIndex(slot: u16, options: []const []const u8, idx: usize) void {
    if (idx < options.len) setStr(slot, options[idx]);
}

/// Slider display text: floats print with their scaled precision and no
/// floating-point noise; integers stay bare; enums never reach here.
pub fn valueText(slot: u16, v: i32, unit: []const u8, buf: []u8) []const u8 {
    const m = k_meta[slot];
    switch (m.kind) {
        .number => {
            const actual = @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(m.scale));
            var num_buf: [32]u8 = undefined;
            const num = formatNumber(&num_buf, actual);
            return if (unit.len == 0)
                std.fmt.bufPrint(buf, "{s}", .{num}) catch ""
            else
                std.fmt.bufPrint(buf, "{s} {s}", .{ num, unit }) catch "";
        },
        else => return if (unit.len == 0)
            std.fmt.bufPrint(buf, "{d}", .{v}) catch ""
        else
            std.fmt.bufPrint(buf, "{d} {s}", .{ v, unit }) catch "",
    }
}

// Write.

/// Write every pending edit back to its Lua file, then ask Zoolander to
/// reload. A field with no setter call gets a new call appended to
/// `init.lua`, creating the config directory when needed.
pub fn commit(alloc: std.mem.Allocator, io: std.Io) void {
    if (!g_dirty) return;

    // Any presentation edit belongs to the display group and must be
    // confirmed before it sticks.
    var touches_displays = false;
    for (g_edits, 0..) |maybe, i| {
        if (maybe != null and std.mem.eql(u8, k_meta[i].setter, "set_presentation")) {
            touches_displays = true;
            break;
        }
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var texts: std.ArrayListUnmanaged([]u8) = .empty;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    for (g_files.items) |f| {
        const copy = a.dupe(u8, f.text) catch continue;
        texts.append(a, copy) catch continue;
        paths.append(a, f.path) catch continue;
    }

    var any = false;
    for (g_edits, 0..) |maybe, i| {
        const value = maybe orelse continue;
        const m = k_meta[i];
        var lit_buf: [512]u8 = undefined;
        const lit = if (m.kind == .list) formatList(&lit_buf, value.text) else formatLiteral(&lit_buf, value);
        var applied = false;
        const is_flag = m.kind == .flag;
        for (texts.items, 0..) |old, ti| {
            const edited = if (is_flag)
                editFlag(a, old, m.setter, lit) catch null
            else if (m.positional)
                editArgText(a, old, m.setter, lit) catch null
            else
                editText(a, old, m.setter, m.key, lit) catch null;
            if (edited) |new| {
                texts.items[ti] = new;
                applied = true;
                break;
            }
        }
        if (!applied) {
            // No call anywhere: append to init.lua (or create it).
            const dir_path = configDir(a) catch continue;
            std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
            var found: ?usize = null;
            for (paths.items, 0..) |p, pi| {
                if (std.mem.endsWith(u8, p, "/init.lua")) found = pi;
            }
            if (found) |fi| {
                const new = if (is_flag)
                    appendFlagCall(a, texts.items[fi], m.setter, lit) catch continue
                else if (m.positional)
                    appendArgCall(a, texts.items[fi], m.setter, lit) catch continue
                else
                    appendCall(a, texts.items[fi], m.setter, m.key, lit) catch continue;
                texts.items[fi] = new;
            } else {
                const path = std.fmt.allocPrint(a, "{s}/init.lua", .{dir_path}) catch continue;
                const new = if (is_flag)
                    appendFlagCall(a, "", m.setter, lit) catch continue
                else if (m.positional)
                    appendArgCall(a, "", m.setter, lit) catch continue
                else
                    appendCall(a, "", m.setter, m.key, lit) catch continue;
                paths.append(a, path) catch continue;
                texts.append(a, new) catch continue;
            }
            applied = true;
        }
        if (applied) any = true;
    }

    if (any) {
        for (texts.items, 0..) |text, i| {
            const path = paths.items[i];
            var unchanged = false;
            for (g_files.items) |f| {
                if (std.mem.eql(u8, f.path, path) and std.mem.eql(u8, f.text, text)) {
                    unchanged = true;
                    break;
                }
            }
            if (unchanged) continue;
            if (touches_displays) captureBackup(path, io);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch {};
        }
        if (touches_displays) writeMarker(io);
        reload(alloc, io);
        if (touches_displays) {
            g_confirm_pending = true;
            g_confirm_deadline_ms = nowMs() + @as(i64, confirm_seconds) * 1000;
        }
    }

    load(io);
}

/// `zoolanderctl reload`, when the control tool is on PATH. A missing tool
/// or a refused reload is harmless: the files are already on disk.
pub fn reload(alloc: std.mem.Allocator, io: std.Io) void {
    const res = std.process.run(alloc, io, .{
        .argv = &.{ "zoolanderctl", "reload" },
    }) catch return;
    alloc.free(res.stdout);
    alloc.free(res.stderr);
}

// Tests.

test "zoolander-data: literal edit preserves the rest of the file" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\-- keep me
        \\zl.set_window_style({
        \\    gaps_in = 3, -- inner
        \\    shadow = { enabled = false, range = 35 },
        \\    rounding = 20,
        \\})
        \\zl.set_blur({ enabled = true, size = 8 })
    ;
    const out = (try editText(a, src, "set_window_style", "gaps_in", "12")).?;
    try t.expect(std.mem.indexOf(u8, out, "gaps_in = 12") != null);
    try t.expect(std.mem.indexOf(u8, out, "-- keep me") != null);
    try t.expect(std.mem.indexOf(u8, out, "-- inner") != null);
    const nested = (try editText(a, out, "set_window_style", "shadow.enabled", "true")).?;
    try t.expect(std.mem.indexOf(u8, nested, "shadow = { enabled = true") != null);
    const inserted = (try editText(a, nested, "set_window_style", "border_size", "4")).?;
    try t.expect(std.mem.indexOf(u8, inserted, "border_size = 4") != null);
    const fresh = (try editText(a, inserted, "set_blur", "noise", "0.02")).?;
    try t.expect(std.mem.indexOf(u8, fresh, "noise = 0.02") != null);
    try t.expect(try editText(a, fresh, "set_dim", "inactive", "true") == null);
}

test "zoolander-data: append creates a call when the setter is absent" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try appendCall(a, "", "set_presentation", "vrr", "\"always\"");
    try t.expect(std.mem.indexOf(u8, out, "zl.set_presentation({") != null);
    try t.expect(std.mem.indexOf(u8, out, "vrr = \"always\",") != null);
}

test "zoolander-data: the display confirmation keeps or expires" {
    const t = std.testing;
    keep(std.testing.io);
    g_confirm_pending = true;
    g_confirm_deadline_ms = nowMs() + 15_000;
    try t.expect(confirmPending());
    try t.expect(confirmRemaining() > 0);
    keep(std.testing.io);
    try t.expect(!confirmPending());
    try t.expectEqual(@as(u32, 0), confirmRemaining());
}

test "zoolander-data: defaults mirror the schema" {
    const t = std.testing;
    const vals = initValues();
    try t.expectEqual(@as(f64, 0.0117), vals[46].number);
    try t.expectEqual(false, vals[0].boolean);
    try t.expectEqualStrings("quarter", vals[45].text);
}

test "zoolander-data: bare-call flags rewrite their boolean argument" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\zl.set_reduced_motion(false)
        \\zl.set_animations_enabled( true )
    ;
    const off = (try editFlag(a, src, "set_reduced_motion", "true")).?;
    try t.expect(std.mem.indexOf(u8, off, "zl.set_reduced_motion(true)") != null);
    const on = (try editFlag(a, off, "set_animations_enabled", "false")).?;
    try t.expect(std.mem.indexOf(u8, on, "zl.set_animations_enabled( false)") != null);
    try t.expect(try editFlag(a, on, "set_missing_flag", "true") == null);
    const appended = try appendFlagCall(a, "", "set_reduced_motion", "true");
    try t.expectEqualStrings("\nzl.set_reduced_motion(true)\n", appended);
}

test "zoolander-data: positional setters rewrite only their first argument" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\zl.set_layout("dwindle", 0.62)
    ;
    const out = (try editArgText(a, src, "set_layout", "\"scrolling\"")).?;
    try t.expectEqualStrings("zl.set_layout(\"scrolling\", 0.62)", out);
    try t.expect(try editArgText(a, out, "set_missing_layout", "\"grid\"") == null);
    try t.expectEqualStrings("\nzl.set_layout(\"grid\")\n", try appendArgCall(a, "", "set_layout", "\"grid\""));
}

test "zoolander-data: list values bridge Lua tables and comma text" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const meta = Meta{ .setter = "set_scrolling", .key = "width_presets", .kind = .list };
    const v = parseValue(a, meta, "{ 0.333, 0.667, 1 }");
    try t.expectEqualStrings("0.333, 0.667, 1", v.text);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("{ 0.333, 0.667, 1 }", formatList(&buf, "0.333, 0.667, 1"));
    try t.expectEqualStrings("{ \"a\", 2 }", formatList(&buf, "a, 2"));
}
