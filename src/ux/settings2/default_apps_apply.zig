//! Default-apps apply layer, ported from the C++
//! `settings_default_apps_apply.cpp` and the FileManager1 helper in
//! `settings_default_apps_filemanager1.cpp`.
//!
//! Writes stay restrained: `xdg-mime default` over each declared mime of a
//! slot, a capture of the pre-apply system default (reset's memory), the
//! `[default_apps]` signature gate on `applyFromConfig`, and the
//! `org.freedesktop.FileManager1` override sync outside that gate — the
//! D-Bus endpoint must converge even when the signature is unchanged
//! (override deleted externally, or set before this logic existed).

const std = @import("std");
const live = @import("../../desktop_shell/controlcenter/live.zig");
const autostart = @import("../../services/autostart.zig");
const data = @import("default_apps_data.zig");

const Category = data.Category;

const proxy_binary = "horizon-filemanager1";
const bus_name = "org.freedesktop.FileManager1";
const managed_marker = "# Event Horizon managed";

const max_desktop_id_len: usize = 256;

fn getenvOpt(name: [:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    const s = std.mem.span(p);
    return if (s.len == 0) null else s;
}

fn pathJoin(buf: []u8, a: []const u8, b: []const u8) ?[]const u8 {
    if (a.len + b.len > buf.len) return null;
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch null;
}

/// Atomic write: temp file beside the target, then rename over it (the
/// house discipline — config readers never observe a half-written file).
fn writeAtomic(gpa: std.mem.Allocator, io: std.Io, path: []const u8, content: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const tmp = try std.fmt.allocPrint(gpa, "{s}.eh-tmp", .{path});
    defer gpa.free(tmp);
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = content });
    cwd.rename(tmp, cwd, path, io) catch |e| {
        cwd.deleteFile(io, tmp) catch {};
        return e;
    };
}

fn logz(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[default-apps-apply] " ++ fmt ++ "\n", args);
}

// -- Id guard + normalization --------------------------------------------------

/// Digit/letter/`.-_` body with the `.desktop` suffix, 9..256 chars — the
/// guard that keeps a stored id to a single plain word everywhere it is
/// written (never a shell escape).
pub fn desktopIdOk(id: []const u8) bool {
    const suf = ".desktop";
    if (id.len < 9 or id.len > max_desktop_id_len) return false;
    if (!std.mem.endsWith(u8, id, suf)) return false;
    for (id[0 .. id.len - suf.len]) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// Trim, take the basename and ensure the `.desktop` suffix. Writes into
/// `buf` and returns the slice inside it (empty when nothing remains after
/// trimming — an empty stored slot means "use the system default").
pub fn normalizeDesktopId(id: []const u8, buf: []u8) []const u8 {
    var s = std.mem.trim(u8, id, " \t\n\r");
    s = std.fs.path.basename(s);
    if (s.len == 0) return "";
    const suf = ".desktop";
    const total = s.len + if (std.mem.endsWith(u8, s, suf)) 0 else suf.len;
    if (total > buf.len or total > max_desktop_id_len) return "";
    @memcpy(buf[0..s.len], s);
    if (std.mem.endsWith(u8, s, suf)) return buf[0..s.len];
    @memcpy(buf[s.len..][0..suf.len], suf);
    return buf[0..total];
}

// -- xdg-mime runners -----------------------------------------------------------

/// `xdg-mime default <id> <mime>`. The guard keeps every argument a plain
/// word, so the spawn is direct argv with no shell involved — the same call
/// the C++ runner gated with a `command -v` check.
fn runXdgMimeDefault(gpa: std.mem.Allocator, io: std.Io, desktop_id: []const u8, mime: []const u8) void {
    if (!desktopIdOk(desktop_id) or mime.len == 0) return;
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "xdg-mime", "default", desktop_id, mime },
    }) catch |e| {
        logz("xdg-mime default failed ({s}) desktop={s} mime={s}", .{ @errorName(e), desktop_id, mime });
        return;
    };
    gpa.free(res.stdout);
    gpa.free(res.stderr);
}

/// `xdg-mime query default <mime>`; null when the tool is missing, fails
/// or answers nothing (the C++ popen_line fallback). A non-empty result is
/// caller-owned.
pub fn queryEffectiveDesktopId(gpa: std.mem.Allocator, io: std.Io, cat: Category) ?[]u8 {
    const out = live.runCapture(gpa, io, &.{ "xdg-mime", "query", "default", data.queryMime(cat) }) orelse return null;
    defer gpa.free(out);
    const line = std.mem.trim(u8, out, " \t\r\n");
    if (line.len == 0) return null;
    return gpa.dupe(u8, line) catch null;
}

// -- Pre-apply capture (the reset memory) ----------------------------------------

var capture_arena: ?std.heap.ArenaAllocator = null;
var s_pre_apply: [data.category_count][]const u8 = .{""} ** data.category_count;
var s_pre_apply_set = [_]bool{false} ** data.category_count;
var s_last_applied: ?[]const u8 = null;

fn dupePersistent(gpa: std.mem.Allocator, s: []const u8) []const u8 {
    if (capture_arena == null) capture_arena = std.heap.ArenaAllocator.init(gpa);
    return capture_arena.?.allocator().dupe(u8, s) catch "";
}

/// Captures the system default we are about to overwrite, so "reset" can
/// restore it (C++ `s_pre_apply`).
fn recordCapture(gpa: std.mem.Allocator, cat: Category, line: []const u8) void {
    s_pre_apply[@intFromEnum(cat)] = dupePersistent(gpa, line);
    s_pre_apply_set[@intFromEnum(cat)] = true;
}

/// The system default captured before this process's first apply of the
/// slot, or "" when nothing was captured (C++ captured_system_default).
pub fn capturedSystemDefault(cat: Category) []const u8 {
    if (!s_pre_apply_set[@intFromEnum(cat)]) return "";
    return s_pre_apply[@intFromEnum(cat)];
}

// -- Apply / reset / converge ------------------------------------------------------

/// Applies one slot: captures the prior default once, then writes
/// `xdg-mime default` for every declared mime. The file-manager slot also
/// routes the FileManager1 D-Bus endpoint.
pub fn applyCategoryDefault(gpa: std.mem.Allocator, io: std.Io, desktop_id: []const u8, cat: Category) void {
    if (desktop_id.len == 0) return;
    var id_buf: [max_desktop_id_len + 8]u8 = undefined;
    const id = normalizeDesktopId(desktop_id, &id_buf);
    if (id.len == 0) return;
    if (!s_pre_apply_set[@intFromEnum(cat)]) {
        const cap = queryEffectiveDesktopId(gpa, io, cat);
        recordCapture(gpa, cat, cap orelse "");
        if (cap) |c| gpa.free(c);
    }
    for (data.applyMimes(cat)) |mime| runXdgMimeDefault(gpa, io, id, mime);
    if (cat == .files) {
        applyFilemanager1Transition(gpa, io, syncFilemanager1Override(gpa, io, id));
    }
}

/// Restores the captured system default for a slot; when no prior default
/// existed the user-level override lines are dropped instead so the system
/// value re-surfaces (C++ restore_category_system_default).
pub fn restoreCategorySystemDefault(gpa: std.mem.Allocator, io: std.Io, cat: Category) void {
    if (cat == .files) {
        applyFilemanager1Transition(gpa, io, syncFilemanager1Override(gpa, io, ""));
    }
    const i = @intFromEnum(cat);
    // The prior is either the capture (not ours to free) or a fresh query
    // (caller-owned; the record dupe leaves it disposable).
    const prior_is_heap = !s_pre_apply_set[i];
    const prior = if (prior_is_heap) (queryEffectiveDesktopId(gpa, io, cat) orelse "") else s_pre_apply[i];
    defer if (prior_is_heap and prior.len > 0) gpa.free(prior);
    recordCapture(gpa, cat, prior);
    if (prior.len > 0) {
        var id_buf: [max_desktop_id_len + 8]u8 = undefined;
        const id = normalizeDesktopId(prior, &id_buf);
        if (id.len > 0) {
            for (data.applyMimes(cat)) |mime| runXdgMimeDefault(gpa, io, id, mime);
            return;
        }
    }
    // No prior default existed (or the captured id failed its guard): drop
    // the user-level override lines so the system value re-surfaces.
    for (data.applyMimes(cat)) |mime| unsetMimeDefault(gpa, io, mime);
}

/// Restores every slot to the system default, dropping overrides that have
/// no prior to restore. The settings window wires this to the reset button;
/// the stored config ids are cleared by the caller (with a flush) after
/// this returns.
pub fn resetAllToSystemDefault(gpa: std.mem.Allocator, io: std.Io) void {
    inline for (@typeInfo(Category).@"enum".fields) |f| {
        restoreCategorySystemDefault(gpa, io, @enumFromInt(f.value));
    }
}

/// Drops every user override line starting with `<mime>=` from the
/// user-level `mimeapps.list` so the system default re-surfaces. The C++
/// runner did this with a `grep -v` script against `$HOME/.config`; direct
/// file IO does the same remove-pass and honors XDG_CONFIG_HOME.
fn unsetMimeDefault(gpa: std.mem.Allocator, io: std.Io, mime: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path = mimeappsPath(&path_buf) orelse return;
    const cur = readFile(gpa, io, path) orelse return; // nothing to unset
    defer gpa.free(cur);

    var kept = std.ArrayList(u8).empty;
    defer kept.deinit(gpa);
    var changed = false;
    var lines = std.mem.splitScalar(u8, cur, '\n');
    while (lines.next()) |line_raw| {
        const removed = std.mem.startsWith(u8, line_raw, mime) and
            line_raw.len > mime.len and line_raw[mime.len] == '=';
        if (removed) {
            changed = true;
            continue;
        }
        kept.appendSlice(gpa, line_raw) catch return;
        kept.append(gpa, '\n') catch return;
    }
    if (!changed) return; // no override line for this mime
    writeAtomic(gpa, io, path, kept.items) catch |e| {
        logz("mimeapps.list unset write failed: {s}", .{@errorName(e)});
    };
}

/// `$XDG_CONFIG_HOME/mimeapps.list` or `$HOME/.config/mimeapps.list`.
fn mimeappsPath(buf: []u8) ?[]const u8 {
    if (getenvOpt("XDG_CONFIG_HOME")) |x| return pathJoin(buf, x, "/mimeapps.list");
    const home = getenvOpt("HOME") orelse return null;
    var inner: [256]u8 = undefined;
    const config_home = pathJoin(&inner, home, "/.config") orelse return null;
    return pathJoin(buf, config_home, "/mimeapps.list");
}

// -- Config convergence -------------------------------------------------------------

/// Applies every stored id from the config — but only when the
/// `\x1f`-joined signature moved since the last run (C++ apply_from_config).
/// The FileManager1 sync runs outside the gate so the endpoint converges on
/// every settings save, even when the ids themselves did not change.
pub fn applyFromConfig(gpa: std.mem.Allocator, io: std.Io, ids: [data.category_count][]const u8) void {
    applyFilemanager1Transition(
        gpa,
        io,
        syncFilemanager1Override(gpa, io, ids[@intFromEnum(Category.files)]),
    );
    var sig_buf: [data.category_count * (max_desktop_id_len + 1)]u8 = undefined;
    var sig_len: usize = 0;
    for (ids) |id| {
        const src = if (id.len > max_desktop_id_len) id[0..max_desktop_id_len] else id;
        @memcpy(sig_buf[sig_len..][0..src.len], src);
        sig_len += src.len;
        sig_buf[sig_len] = 0x1f;
        sig_len += 1;
    }
    const sig = sig_buf[0..sig_len];
    if (s_last_applied) |prev| {
        if (std.mem.eql(u8, prev, sig)) return;
    }
    s_last_applied = dupePersistent(gpa, sig);
    for (ids, 0..) |id, i| {
        if (id.len == 0) continue;
        applyCategoryDefault(gpa, io, id, @enumFromInt(i));
    }
}

// -- FileManager1 routing -------------------------------------------------------------

pub const Transition = enum { unchanged, installed, removed };

fn dataHome(buf: []u8) ?[]const u8 {
    if (getenvOpt("XDG_DATA_HOME")) |x| {
        if (x.len <= buf.len) {
            @memcpy(buf[0..x.len], x);
            return buf[0..x.len];
        }
        return null;
    }
    const home = getenvOpt("HOME") orelse return null;
    return pathJoin(buf, home, "/.local/share");
}

/// The data dirs the override resolver scans, C++-ordered: the data home,
/// the XDG_DATA_DIRS entries (or the two defaults), then /usr/share and
/// /usr/local/share again — sorted and de-duplicated. Caller frees.
pub fn dataDirs(gpa: std.mem.Allocator) ![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    defer list.deinit(gpa);

    var home_buf: [512]u8 = undefined;
    if (dataHome(&home_buf)) |dh| try list.append(gpa, try gpa.dupe(u8, dh));

    if (getenvOpt("XDG_DATA_DIRS")) |dirs| {
        var it = std.mem.splitScalar(u8, dirs, ':');
        while (it.next()) |d| {
            if (d.len > 0) try list.append(gpa, try gpa.dupe(u8, d));
        }
    } else {
        try list.append(gpa, try gpa.dupe(u8, "/usr/local/share"));
        try list.append(gpa, try gpa.dupe(u8, "/usr/share"));
    }
    try list.append(gpa, try gpa.dupe(u8, "/usr/share"));
    try list.append(gpa, try gpa.dupe(u8, "/usr/local/share"));

    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(gpa);
    for (list.items, 0..) |d, i| {
        if (i > 0 and std.mem.eql(u8, d, list.items[i - 1])) {
            gpa.free(d);
            continue;
        }
        try out.append(gpa, d);
    }
    return out.toOwnedSlice(gpa);
}

/// The managed override file path
/// (`datahome/dbus-1/services/org.freedesktop.FileManager1.service`).
/// Caller frees on success.
pub fn userOverridePath(gpa: std.mem.Allocator) ![]u8 {
    var home_buf: [512]u8 = undefined;
    const dh = dataHome(&home_buf) orelse return error.NoDataHome;
    var path = std.ArrayList(u8).empty;
    errdefer path.deinit(gpa);
    try path.appendSlice(gpa, dh);
    try path.appendSlice(gpa, "/dbus-1/services/" ++ bus_name ++ ".service");
    return path.toOwnedSlice(gpa);
}

/// First token of an Exec= line, honoring simple quoting, then basename
/// (C++ exec_basename). The result lives in `buf`.
pub fn execBasename(exec_line: []const u8, buf: []u8) []const u8 {
    var in_single = false;
    var in_double = false;
    var n: usize = 0;
    var i: usize = 0;
    while (i < exec_line.len) : (i += 1) {
        const ch = exec_line[i];
        if (in_single) {
            if (ch == '\'') {
                in_single = false;
            } else if (n < buf.len) {
                buf[n] = ch;
                n += 1;
            }
        } else if (in_double) {
            if (ch == '"') {
                in_double = false;
            } else if (ch == '\\' and i + 1 < exec_line.len) {
                if (n < buf.len) {
                    buf[n] = exec_line[i + 1];
                    n += 1;
                }
                i += 1;
            } else if (n < buf.len) {
                buf[n] = ch;
                n += 1;
            }
        } else {
            if (ch == ' ' or ch == '\t') break;
            if (ch == '\'') {
                in_single = true;
            } else if (ch == '"') {
                in_double = true;
            } else if (ch == '\\' and i + 1 < exec_line.len) {
                if (n < buf.len) {
                    buf[n] = exec_line[i + 1];
                    n += 1;
                }
                i += 1;
            } else if (n < buf.len) {
                buf[n] = ch;
                n += 1;
            }
        }
    }
    if (n == 0) return "";
    // Basename: advance past the last '/' if any.
    var j: usize = n;
    while (j > 0) : (j -= 1) {
        if (buf[j - 1] == '/') break;
    }
    if (j > 0) {
        // Copy the basename to the front of buf so the slice is clean.
        const b = buf[j..n];
        std.mem.copyForwards(u8, buf[0..b.len], b);
        n = b.len;
    }
    return buf[0..n];
}

/// Exec= first-token basename of a `.desktop` id, or "" when not found
/// (C++ desktop_exec_program). The result lives in `buf`.
pub fn desktopExecProgram(gpa: std.mem.Allocator, io: std.Io, desktop_id: []const u8, buf: []u8) []const u8 {
    const dirs = dataDirs(gpa) catch return "";
    defer {
        for (dirs) |d| gpa.free(d);
        gpa.free(dirs);
    }
    for (dirs) |dir| {
        var p_buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&p_buf, "{s}/applications/{s}", .{ dir, desktop_id }) catch continue;
        const file_data = readFile(gpa, io, p) orelse continue;
        defer gpa.free(file_data);
        var in_entry = false;
        var lines = std.mem.splitScalar(u8, file_data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
                continue;
            }
            if (!in_entry) continue;
            if (std.mem.startsWith(u8, line, "Exec=")) {
                const v = std.mem.trimStart(u8, line[5..], " \t");
                if (v.len > 0) return execBasename(v, buf);
            }
        }
    }
    return "";
}

/// True when some installed (non-override) D-Bus service already activates
/// the chosen manager for `org.freedesktop.FileManager1` — native handling
/// wins and no proxy override is needed (C++ provider_is_native).
pub fn providerIsNative(gpa: std.mem.Allocator, io: std.Io, program: []const u8) bool {
    if (program.len == 0) return false;
    const dirs = dataDirs(gpa) catch return false;
    defer {
        for (dirs) |d| gpa.free(d);
        gpa.free(dirs);
    }
    const ours_abs = userOverridePath(gpa) catch return false;
    defer gpa.free(ours_abs);

    const cwd = std.Io.Dir.cwd();
    for (dirs) |dir| {
        var services_buf: [512]u8 = undefined;
        const services = std.fmt.bufPrint(&services_buf, "{s}/dbus-1/services", .{dir}) catch continue;
        var d = cwd.openDir(io, services, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |rec| {
            if (!std.mem.endsWith(u8, rec.name, ".service")) continue;
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ services, rec.name }) catch continue;
            if (std.mem.eql(u8, path, ours_abs)) continue;
            if (serviceActivatesProgram(gpa, io, path, program)) return true;
        }
    }
    return false;
}

/// True when the `.service` file at `path` carries Name=<bus_name> inside
/// `[D-BUS Service]` and its Exec's program (first-token basename)
/// matches `program`.
fn serviceActivatesProgram(gpa: std.mem.Allocator, io: std.Io, path: []const u8, program: []const u8) bool {
    const body = readFile(gpa, io, path) orelse return false;
    defer gpa.free(body);
    var in_service = false;
    var is_ours = false;
    var exec: []const u8 = "";
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r\n");
        if (t.len == 0 or t[0] == '#') continue;
        if (t[0] == '[') {
            in_service = std.mem.eql(u8, t, "[D-BUS Service]");
            continue;
        }
        if (!in_service) continue;
        if (std.mem.startsWith(u8, t, "Name=")) {
            if (std.mem.eql(u8, std.mem.trim(u8, t[5..], " \t"), bus_name)) is_ours = true;
        } else if (std.mem.startsWith(u8, t, "Exec=") and exec.len == 0) {
            exec = std.mem.trim(u8, t[5..], " \t");
        }
    }
    if (!is_ours or exec.len == 0) return false;
    var base_buf: [256]u8 = undefined;
    const base = execBasename(exec, &base_buf);
    return std.mem.eql(u8, base, program);
}

/// Where the proxy binary is: `EH_FILEMANAGER1_PROXY_BIN`, the directory of
/// this executable, or on PATH via `command -v` (installed layout). ""
/// when none exists works; the result lives in `buf`.
pub fn proxyBinaryPath(gpa: std.mem.Allocator, io: std.Io, buf: []u8) []const u8 {
    // Test hook: point at a fake proxy binary without touching the real one.
    if (getenvOpt("EH_FILEMANAGER1_PROXY_BIN")) |e| {
        if (e.len <= buf.len) {
            @memcpy(buf[0..e.len], e);
            return buf[0..e.len];
        }
    }
    // Same directory as this settings binary.
    var self_buf: [512]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    const n = cwd.readLink(io, "/proc/self/exe", &self_buf) catch 0;
    if (n > 0) {
        const self = self_buf[0..n];
        if (std.mem.lastIndexOfScalar(u8, self, '/')) |sl| {
            const side = pathJoin(buf, self[0..sl], "/" ++ proxy_binary) orelse return "";
            const ok = blk: {
                cwd.access(io, side, .{ .execute = true }) catch break :blk false;
                break :blk true;
            };
            if (ok) return side;
        }
    }
    // Installed layout: resolve via PATH (`command -v`, as C++ did).
    if (live.runCapture(gpa, io, &.{
        "sh", "-c", "command -v " ++ proxy_binary ++ " 2>/dev/null",
    })) |found| {
        defer gpa.free(found);
        const line = std.mem.trim(u8, found, " \t\r\n");
        if (line.len > 0 and line.len <= buf.len) {
            const cwd2 = std.Io.Dir.cwd();
            cwd2.access(io, line, .{ .execute = true }) catch return "";
            @memcpy(buf[0..line.len], line);
            return buf[0..line.len];
        }
    }
    return "";
}

fn removeIfManaged(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Transition {
    const cur = readFile(gpa, io, path) orelse return .unchanged;
    defer gpa.free(cur);
    if (std.mem.indexOf(u8, cur, managed_marker) == null) {
        logz("FileManager1 override is foreign, leaving it alone: {s}", .{path});
        return .unchanged;
    }
    std.Io.Dir.cwd().deleteFile(io, path) catch return .unchanged;
    logz("FileManager1 override removed (system provider restored)", .{});
    return .removed;
}

/// Writes or removes the managed FileManager1 override and reports the
/// transition the caller must realize (C++ sync_filemanager1_override).
pub fn syncFilemanager1Override(gpa: std.mem.Allocator, io: std.Io, desktop_id_raw: []const u8) Transition {
    const path = userOverridePath(gpa) catch return .unchanged;
    defer gpa.free(path);

    const trimmed = std.mem.trim(u8, desktop_id_raw, " \t\n\r");
    if (trimmed.len == 0) {
        return removeIfManaged(gpa, io, path);
    }
    var id_buf: [max_desktop_id_len + 8]u8 = undefined;
    const id = normalizeDesktopId(trimmed, &id_buf);
    if (id.len == 0) return .unchanged;

    var prog_buf: [256]u8 = undefined;
    const program = desktopExecProgram(gpa, io, id, &prog_buf);
    if (program.len > 0 and providerIsNative(gpa, io, program)) {
        // The chosen manager owns FileManager1 itself (e.g. otter-files):
        // direct activation is native and keeps --select/property support.
        return removeIfManaged(gpa, io, path);
    }
    var proxy_buf: [512]u8 = undefined;
    const proxy = proxyBinaryPath(gpa, io, &proxy_buf);
    if (proxy.len == 0) {
        logz("{s} not found next to settings or on PATH; FileManager1 routing left unchanged", .{proxy_binary});
        return .unchanged;
    }
    const content = std.fmt.allocPrint(gpa, "{s} — do not edit; managed by Default Apps.\n[D-BUS Service]\nName={s}\nExec={s}\n", .{ managed_marker, bus_name, proxy }) catch return .unchanged;
    defer gpa.free(content);
    if (readFile(gpa, io, path)) |cur| {
        defer gpa.free(cur);
        if (std.mem.eql(u8, cur, content)) return .unchanged;
    }
    var dir_buf: [512]u8 = undefined;
    const dir_slash = pathJoin(&dir_buf, dirname(path), "/") orelse return .unchanged;
    const dir = std.mem.trimEnd(u8, dir_slash, "/");
    std.Io.Dir.cwd().createDirPath(io, dir) catch |e| {
        logz("cannot create dbus services dir: {s}", .{@errorName(e)});
        return .unchanged;
    };
    writeAtomic(gpa, io, path, content) catch |e| {
        logz("cannot install FileManager1 override: {s}", .{@errorName(e)});
        return .unchanged;
    };
    logz("FileManager1 now routes to {s} via {s}", .{ id, proxy });
    return .installed;
}

/// Realizes the transition: `--replace` spawns take the bus name right
/// away so the new default applies this session; a removal best-effort
/// stops the headless proxy so the native provider activates on the next
/// request (C++ apply_filemanager1_transition).
pub fn applyFilemanager1Transition(gpa: std.mem.Allocator, io: std.Io, t: Transition) void {
    switch (t) {
        .installed => {
            var proxy_buf: [512]u8 = undefined;
            const proxy = proxyBinaryPath(gpa, io, &proxy_buf);
            if (proxy.len == 0) return;
            autostart.spawnDetached(io, &.{ proxy, "--replace" }) catch |e| {
                logz("proxy spawn failed: {s}", .{@errorName(e)});
            };
        },
        .removed => autostart.spawnDetached(io, &.{ "pkill", "-x", proxy_binary }) catch {},
        .unchanged => {},
    }
}

fn dirname(p: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, p, '/') orelse return "";
    return p[0..idx];
}

test "settings-default-apps-apply: id guard and normalization" {
    const t = std.testing;
    try t.expect(desktopIdOk("firefox.desktop"));
    try t.expect(desktopIdOk("org.gnome.Nautilus.desktop"));
    try t.expect(desktopIdOk("io.elementary.files.desktop"));
    try t.expect(!desktopIdOk("short.desktop"[0..3])); // under 9 chars
    try t.expect(!desktopIdOk("evil `rm`.desktop"));
    try t.expect(!desktopIdOk("no-suffix"));
    try t.expect(!desktopIdOk(""));

    var buf: [280]u8 = undefined;
    try t.expectEqualStrings("firefox.desktop", normalizeDesktopId(" firefox.desktop \n", &buf));
    try t.expectEqualStrings("kitty.desktop", normalizeDesktopId("/usr/share/applications/kitty.desktop", &buf));
    try t.expectEqualStrings("nautilus.desktop", normalizeDesktopId("nautilus", &buf));
    try t.expectEqualStrings("", normalizeDesktopId("", &buf));
}

test "settings-default-apps-apply: exec basename honors quoting" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("nautilus", execBasename("nautilus %U", &buf));
    try t.expectEqualStrings("otter-browser", execBasename("\"otter-browser\" %u", &buf));
    try t.expectEqualStrings("io.papermc.launcher", execBasename("/opt/io.papermc.launcher --flag a'b", &buf));
    try t.expectEqualStrings("dầuog", execBasename("'dầuog'", &buf));
    try t.expectEqualStrings("", execBasename("   ", &buf));
    try t.expectEqualStrings("", execBasename("", &buf));
}
