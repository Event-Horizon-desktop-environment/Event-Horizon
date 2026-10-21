//! Launching desktop applications by id, the way the dock's pinned/running
//! slots need it: find `<id>.desktop` under the XDG applications dirs, read its
//! `Exec`, expand the desktop-entry field codes, and spawn it detached.
//!
//! This covers the `dock_launch_app` path at the level the Zig shell
//! currently supports: no `DBusActivatable`, no `Gio` activation, and
//! `Terminal=true` entries are reported as unsupported instead of guessed.

const std = @import("std");
const linux = std.os.linux;
const autostart = @import("autostart.zig");

pub const Error = error{
    NotFound,
    NoExec,
    Unsupported,
    OutOfMemory,
};

/// `$XDG_DATA_HOME/applications` followed by each `$XDG_DATA_DIRS/applications`.
pub fn applicationsDirs(
    alloc: std.mem.Allocator,
    xdg_data_home: ?[]const u8,
    home: ?[]const u8,
    xdg_data_dirs: ?[]const u8,
) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |d| alloc.free(d);
        out.deinit(alloc);
    }
    if (xdg_data_home) |d| {
        try out.append(alloc, try std.fs.path.join(alloc, &.{ d, "applications" }));
    } else if (home) |h| {
        try out.append(alloc, try std.fs.path.join(alloc, &.{ h, ".local", "share", "applications" }));
    }
    if (xdg_data_dirs) |dirs| {
        var it = std.mem.splitScalar(u8, dirs, ':');
        while (it.next()) |d| {
            if (d.len == 0) continue;
            try out.append(alloc, try std.fs.path.join(alloc, &.{ d, "applications" }));
        }
    } else {
        try out.append(alloc, try alloc.dupe(u8, "/usr/local/share/applications"));
        try out.append(alloc, try alloc.dupe(u8, "/usr/share/applications"));
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeDirs(alloc: std.mem.Allocator, dirs: [][]const u8) void {
    for (dirs) |d| alloc.free(d);
    alloc.free(dirs);
}

/// Looks for `<dir>/<app_id>.desktop`, then a flat match inside `<dir>`, then
/// one level of subdirectories (desktop files are occasionally grouped, e.g.
/// `kde/org.kde.foo.desktop`), then — when no spelling of the id names a file
/// at all — the entry whose `StartupWMClass` names the window the app opens.
/// Returns an owned absolute-ish path.
pub fn findDesktopPath(
    alloc: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    app_id: []const u8,
) ?[]u8 {
    var namebuf: [512]u8 = undefined;
    const fname: []const u8 = if (std.mem.endsWith(u8, app_id, ".desktop"))
        app_id
    else
        std.fmt.bufPrint(&namebuf, "{s}.desktop", .{app_id}) catch return null;

    const cwd = std.Io.Dir.cwd();
    for (dirs) |d| {
        const direct = std.fs.path.join(alloc, &.{ d, fname }) catch continue;
        if (fileExists(io, cwd, direct)) return direct;
        alloc.free(direct);
    }
    for (dirs) |d| {
        if (findInDir(alloc, io, cwd, d, fname)) |p| return p;
    }
    // The name an id arrives under is not always the name its file was
    // exported as — a Flatpak ships `sh.cider.Cider.desktop` while the window
    // it opens reports `cider`, and nothing at all matches `cider.desktop`.
    const folded = foldId(alloc, app_id) catch return null;
    defer alloc.free(folded);
    if (folded.len == 0) return null;
    if (findByIdentity(alloc, io, dirs, folded)) |p| return p;
    // The id and the file can have nothing in common at all: Proton VPN ships
    // `com.protonvpn.www.desktop` and opens a window reporting
    // `proton.vpn.app.gtk`, so neither the file name nor its last segment has
    // anything to match. `StartupWMClass` is the one key a desktop file
    // reserves for the window's name, and it is the last place to look — the
    // reached the same way.
    return findByWmClass(alloc, io, dirs, app_id);
}

// StartupWMClass index

/// The longest window class the fold accepts. Anything past it is not indexed
/// rather than cut down to a prefix that could answer for another app.
const k_wm_max = 256;

/// How much of one desktop file the scan reads through. `StartupWMClass` sits
/// in the `[Desktop Entry]` group, so this is far beyond any real file; one
/// that does not fit is indexed from its head.
const k_wm_scratch = 1 << 16;

/// `s` lower-cased into `buf` — trim plus fold — or null when there is nothing to fold.
fn lowerWm(buf: []u8, s: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, s, " \t\r");
    if (t.len == 0 or t.len > buf.len) return null;
    for (t, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..t.len];
}

/// The window-class key: the label's last path component, lower-cased, with
/// the `.exe` a Windows-side class carries dropped. Both sides of the
/// comparison go through this, so a class matches however either spells it.
fn wmKey(buf: []u8, s: []const u8) ?[]const u8 {
    const low = lowerWm(buf, s) orelse return null;
    var start: usize = 0;
    if (std.mem.lastIndexOfAny(u8, low, "/\\")) |i| {
        if (i + 1 < low.len) start = i + 1;
    }
    var out = low[start..];
    if (out.len > 4 and std.mem.endsWith(u8, out, ".exe")) out = out[0 .. out.len - 4];
    return out;
}

/// The `[Desktop Entry]` group's `StartupWMClass=`, first value wins, or null.
fn readWmClass(data: []const u8) ?[]const u8 {
    var in_group = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_group = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_group) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, line[0..eq], "StartupWMClass")) continue;
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (v.len == 0) return null;
        return v;
    }
    return null;
}

/// Window class → the desktop file that advertises it. The keys, the paths and
/// the map's own bookkeeping all come from `arena`, so `arena.deinit()` is the
/// whole teardown.
const WmIndex = struct {
    arena: std.heap.ArenaAllocator,
    /// Fingerprint of the directory list this was scanned under. The list
    /// comes from the environment and does not move during a session, but any
    /// caller may be handed a different one — every test is — and an index
    /// answering for files that have left the search path would be worse than
    /// none at all.
    sig: u64,
    map: std.StringHashMapUnmanaged([]const u8) = .empty,
};

/// The index, built by the first lookup no name could answer.
///
/// Every caller is the UI thread of its process — the dock's strip, its
/// right-click menu, the overview — so the lock never actually contends; it is
/// here so a second thread can only ever meet a finished map, and it blocks
/// rather than spins because building one reads the whole search path.
var wm_mu = std.Io.Mutex.init;
var wm_index: ?WmIndex = null;

fn dirsSig(dirs: []const []const u8) u64 {
    var h = std.hash.Wyhash.init(0x576d_636c);
    for (dirs) |d| {
        h.update(d);
        h.update(&[_]u8{0x1f});
    }
    return h.final();
}

/// One class → path pair, first writer wins: the directories arrive in XDG
/// order, so the file the search path reaches first keeps its own class.
fn putWmKey(ix: *WmIndex, key: []const u8, path: []const u8) void {
    if (ix.map.contains(key)) return;
    const aa = ix.arena.allocator();
    const owned = aa.dupe(u8, key) catch return;
    ix.map.put(aa, owned, path) catch {};
}

/// Files a class under both spellings: the folded key, and the raw label —
/// which is only a different string when the value carries a path, and then is
/// the one kept as well.
fn indexWmClass(ix: *WmIndex, label: []const u8, path: []const u8) void {
    var buf: [k_wm_max]u8 = undefined;
    if (wmKey(&buf, label)) |k| putWmKey(ix, k, path);
    var raw: [k_wm_max]u8 = undefined;
    if (lowerWm(&raw, label)) |k| putWmKey(ix, k, path);
}

/// Walks each directory's top level — the same reach the id lookups above
/// have, grouped desktop files included only by name — and folds every
/// `StartupWMClass` into `ix`.
fn scanWmClasses(ix: *WmIndex, io: std.Io, dirs: []const []const u8, scratch: []u8) void {
    const cwd = std.Io.Dir.cwd();
    for (dirs) |d| {
        var dir = cwd.openDir(io, d, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .file and e.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, e.name, ".desktop")) continue;
            const data = dir.readFile(io, e.name, scratch) catch continue;
            const wm = readWmClass(data) orelse continue;
            const path = std.fs.path.join(ix.arena.allocator(), &.{ d, e.name }) catch continue;
            indexWmClass(ix, wm, path);
        }
    }
}

/// Builds the index for `dirs`, or null when the scratch buffer the scan reads
/// through could not be had. The caller then keeps no index rather than a
/// half-built one, so the next lookup simply tries again.
fn buildWmIndex(io: std.Io, dirs: []const []const u8) ?WmIndex {
    const scratch = std.heap.page_allocator.alloc(u8, k_wm_scratch) catch return null;
    defer std.heap.page_allocator.free(scratch);
    var ix: WmIndex = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .sig = dirsSig(dirs),
    };
    scanWmClasses(&ix, io, dirs, scratch);
    return ix;
}

/// The desktop file that names `app_id` in its `StartupWMClass`, owned by the
/// caller. Building the index is the only part of `findDesktopPath` that reads
/// every file in the search path, so it happens once — every later miss is two
/// map reads.
fn findByWmClass(
    alloc: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    app_id: []const u8,
) ?[]u8 {
    wm_mu.lockUncancelable(io);
    defer wm_mu.unlock(io);
    const sig = dirsSig(dirs);
    if (wm_index == null or wm_index.?.sig != sig) {
        if (wm_index) |*old| {
            old.arena.deinit();
            wm_index = null;
        }
        wm_index = buildWmIndex(io, dirs);
    }
    const ix = wm_index orelse return null;
    var key: [k_wm_max]u8 = undefined;
    const folded = wmKey(&key, app_id) orelse return null;
    var found = ix.map.get(folded);
    if (found == null) {
        var raw: [k_wm_max]u8 = undefined;
        if (lowerWm(&raw, app_id)) |lower| {
            if (!std.mem.eql(u8, lower, folded)) found = ix.map.get(lower);
        }
    }
    const path = found orelse return null;
    return alloc.dupe(u8, path) catch null;
}

/// An app id folded the way `normalize_desktop_app_id` does, minus the
/// allocation and the `"unknown"` answer: lower case, with any trailing
/// `.desktop` removed. Empty stays empty.
fn foldId(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    while (out.len > 8 and std.mem.endsWith(u8, out, ".desktop")) out = out[0 .. out.len - 8];
    return out;
}

/// The last dotted segment of a desktop-file id, which is what a window's
/// `WM_CLASS` — and so the dock's slot key — usually carries.
fn lastSegment(s: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, s, '.') orelse return s;
    return if (dot + 1 < s.len) s[dot + 1 ..] else s;
}

/// Matches a folded id against what the files advertise about themselves:
/// the last dotted segment of their stem, which has to be unambiguous, so
/// `steam` can never claim one of several `*.Steam.desktop` files. An id with
/// no dots of its own — `cider`, `obs`, `Code` — resolves to the single
/// reverse-DNS file that ends in it, which is the whole Flatpak case.
///
/// The index also maps the legacy ids each file lists in
/// `X-Flatpak-RenamedFrom=`, for the app whose class name is neither its id
/// nor its last segment; that wants the same once-per-process read the
/// `StartupWMClass` index below does, and is not wired up yet.
fn findByIdentity(
    alloc: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    id_folded: []const u8,
) ?[]u8 {
    const seg = lastSegment(id_folded);
    if (seg.len == 0) return null;
    const cwd = std.Io.Dir.cwd();

    var only: ?[]u8 = null;
    var hits: usize = 0;
    for (dirs) |d| {
        var dir = cwd.openDir(io, d, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .file and e.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, e.name, ".desktop")) continue;
            const stem = e.name[0 .. e.name.len - ".desktop".len];
            if (!std.ascii.eqlIgnoreCase(lastSegment(stem), seg)) continue;
            hits += 1;
            if (hits == 1) {
                only = std.fs.path.join(alloc, &.{ d, e.name }) catch return null;
            }
        }
    }
    if (hits == 1) return only;
    if (only) |p| alloc.free(p);
    return null;
}

fn fileExists(io: std.Io, cwd: std.Io.Dir, path: []const u8) bool {
    _ = cwd.statFile(io, path, .{}) catch return false;
    return true;
}

fn findInDir(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    dir_path: []const u8,
    app_id: []const u8,
) ?[]u8 {
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (!std.mem.eql(u8, e.name, app_id)) continue;
        // Linked entries count too — the same Flatpak export layout the
        // catalog walk has to accept.
        if (e.kind != .file and e.kind != .sym_link) continue;
        return std.fs.path.join(alloc, &.{ dir_path, e.name }) catch null;
    }
    return null;
}

/// Tokenizes an already-expanded `Exec` line, honouring double quotes so
/// values like `Exec=foo --title "My Window" %U` stay intact.
pub fn tokenizeExec(alloc: std.mem.Allocator, exec: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |t| alloc.free(t);
        out.deinit(alloc);
    }
    var cur: std.ArrayList(u8) = .empty;
    errdefer cur.deinit(alloc);
    var in_quotes = false;
    var started = false;
    for (exec) |c| {
        if (c == '"') {
            in_quotes = !in_quotes;
            started = true;
            continue;
        }
        if (!in_quotes and (c == ' ' or c == '\t')) {
            if (started) {
                try out.append(alloc, try cur.toOwnedSlice(alloc));
                cur = .empty;
                started = false;
            }
            continue;
        }
        started = true;
        try cur.append(alloc, c);
    }
    if (started) try out.append(alloc, try cur.toOwnedSlice(alloc));
    return out.toOwnedSlice(alloc);
}

pub fn freeArgv(alloc: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |a| alloc.free(a);
    alloc.free(argv);
}

pub const Launch = struct {
    path: []u8,
    entry: autostart.Entry,
    argv: [][]const u8,

    pub fn deinit(self: *Launch, alloc: std.mem.Allocator) void {
        freeArgv(alloc, self.argv);
        self.entry.deinit(alloc);
        alloc.free(self.path);
    }
};

fn parseEntry(alloc: std.mem.Allocator, data: []const u8) Error!autostart.Entry {
    return autostart.parseDesktopFile(alloc, data) catch return error.OutOfMemory;
}

/// Resolves `app_id` to an argv ready for `autostart.spawnDetached`.
pub fn prepare(
    alloc: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    app_id: []const u8,
) Error!Launch {
    const path = findDesktopPath(alloc, io, dirs, app_id) orelse return error.NotFound;
    errdefer alloc.free(path);

    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return error.NotFound;
    defer alloc.free(data);

    var entry = try parseEntry(alloc, data);
    errdefer entry.deinit(alloc);

    if (entry.exec.len == 0) return error.NoExec;
    if (entry.hidden) return error.NotFound;
    if (entry.terminal) return error.Unsupported;

    const expanded = try autostart.expandFieldCodes(alloc, entry.exec, null);
    defer alloc.free(expanded);
    const argv = try tokenizeExec(alloc, expanded);
    if (argv.len == 0) {
        freeArgv(alloc, argv);
        return error.NoExec;
    }
    return .{ .path = path, .entry = entry, .argv = argv };
}

/// Resolve-and-spawn in one go. Returns false when nothing was launched.
pub fn launch(
    alloc: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    app_id: []const u8,
) bool {
    var l = prepare(alloc, io, dirs, app_id) catch return false;
    defer l.deinit(alloc);
    autostart.spawnDetached(io, l.argv) catch return false;
    return true;
}

/// Spawn a raw `Exec=` line straight from a desktop entry, field codes and
/// all. The catalog already knows which file an entry came from, so there is
/// nothing left to resolve but the command itself.
pub fn launchExec(alloc: std.mem.Allocator, io: std.Io, exec: []const u8) bool {
    const expanded = autostart.expandFieldCodes(alloc, exec, null) catch return false;
    defer alloc.free(expanded);
    const argv = tokenizeExec(alloc, expanded) catch return false;
    defer freeArgv(alloc, argv);
    if (argv.len == 0) return false;
    autostart.spawnDetached(io, argv) catch return false;
    return true;
}

/// Spawn an absolute path with no desktop-entry lookup in between. The shell's
/// own components go through here: `Exec=horizon-settings` resolves to
/// whichever build happens to be installed first on PATH, and a dock built
/// from this tree has to open the settings that belong to it.
pub fn launchPath(io: std.Io, path: []const u8) bool {
    const argv = [_][]const u8{path};
    autostart.spawnDetached(io, &argv) catch return false;
    return true;
}

/// The `Icon=` value of `app_id`'s desktop file, owned by the caller. Used as
/// a last resort when the app id itself is not an icon name — common enough
/// (`horizon-files` → `horizon-filesv2`, or an absolute `Icon=/path.svg`).
pub fn desktopIcon(
    alloc: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    app_id: []const u8,
) ?[]u8 {
    const path = findDesktopPath(alloc, io, dirs, app_id) orelse return null;
    defer alloc.free(path);
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return null;
    defer alloc.free(data);
    var entry = parseEntry(alloc, data) catch return null;
    defer entry.deinit(alloc);
    if (entry.icon.len == 0) return null;
    return alloc.dupe(u8, entry.icon) catch null;
}

/// The `Name=` of `app_id`'s desktop file, owned by the caller — the human
/// app name the stream cascade reads
/// off the same entry the icon comes from.
pub fn desktopName(
    alloc: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    app_id: []const u8,
) ?[]u8 {
    const path = findDesktopPath(alloc, io, dirs, app_id) orelse return null;
    defer alloc.free(path);
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return null;
    defer alloc.free(data);
    var entry = parseEntry(alloc, data) catch return null;
    defer entry.deinit(alloc);
    if (entry.name.len == 0) return null;
    return alloc.dupe(u8, entry.name) catch null;
}

/// Reaps children launched through this module without blocking.
pub fn reap() void {
    autostart.reapChildren();
}

test "app-launch: applications dirs" {
    const t = std.testing;
    const d = try applicationsDirs(t.allocator, "/home/u/.local/share", "/home/u", "/usr/share:/opt/share");
    defer freeDirs(t.allocator, d);
    try t.expectEqual(@as(usize, 3), d.len);
    try t.expectEqualStrings("/home/u/.local/share/applications", d[0]);
    try t.expectEqualStrings("/usr/share/applications", d[1]);
    try t.expectEqualStrings("/opt/share/applications", d[2]);

    const d2 = try applicationsDirs(t.allocator, null, "/home/u", null);
    defer freeDirs(t.allocator, d2);
    try t.expectEqual(@as(usize, 3), d2.len);
    try t.expectEqualStrings("/home/u/.local/share/applications", d2[0]);
}

test "app-launch: an app id resolves to the file it was exported as" {
    const t = std.testing;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer t.allocator.free(root);
    const apps = try std.fs.path.join(t.allocator, &.{ root, "applications" });
    defer t.allocator.free(apps);
    try cwd.createDirPath(io, apps);

    const cider = try std.fs.path.join(t.allocator, &.{ apps, "sh.cider.Cider.desktop" });
    defer t.allocator.free(cider);
    try cwd.writeFile(io, .{ .sub_path = cider, .data =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Cider
        \\Exec=flatpak run sh.cider.Cider
        \\Icon=sh.cider.Cider
        \\X-Flatpak-RenamedFrom=cider.desktop;
        \\
    });

    var dirs = [_][]const u8{apps};

    // The id the window reports is not the file the app was exported as.
    const found = findDesktopPath(t.allocator, io, &dirs, "cider");
    defer if (found) |p| t.allocator.free(p);
    try t.expect(found != null);
    try t.expectEqualStrings("sh.cider.Cider.desktop", std.fs.path.basename(found.?));

    // …and that is what the icon name is read from.
    const icon = desktopIcon(t.allocator, io, &dirs, "cider");
    defer if (icon) |n| t.allocator.free(n);
    try t.expect(icon != null);
    try t.expectEqualStrings("sh.cider.Cider", icon.?);

    // …and the display name the mixer row borrows from the same entry.
    const dname = desktopName(t.allocator, io, &dirs, "cider");
    defer if (dname) |n| t.allocator.free(n);
    try t.expect(dname != null);
    try t.expectEqualStrings("Cider", dname.?);

    // Two files ending in the same segment is no answer at all.
    const other = try std.fs.path.join(t.allocator, &.{ apps, "io.example.Cider.desktop" });
    defer t.allocator.free(other);
    try cwd.writeFile(io, .{ .sub_path = other, .data = "[Desktop Entry]\nType=Application\nName=Other\nExec=other\n" });
    try t.expect(findDesktopPath(t.allocator, io, &dirs, "cider") == null);
}

test "app-launch: tokenize honours quotes" {
    const t = std.testing;
    const a = try tokenizeExec(t.allocator, "foo --title \"My Window\" -x");
    defer freeArgv(t.allocator, a);
    try t.expectEqual(@as(usize, 4), a.len);
    try t.expectEqualStrings("--title", a[1]);
    try t.expectEqualStrings("My Window", a[2]);
    try t.expectEqualStrings("-x", a[3]);

    const b = try tokenizeExec(t.allocator, "  spaced   out  ");
    defer freeArgv(t.allocator, b);
    try t.expectEqual(@as(usize, 2), b.len);
    try t.expectEqualStrings("spaced", b[0]);
    try t.expectEqualStrings("out", b[1]);

    const c = try tokenizeExec(t.allocator, "");
    defer freeArgv(t.allocator, c);
    try t.expectEqual(@as(usize, 0), c.len);
}

test "app-launch: prepare reads a desktop file" {
    const t = std.testing;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer t.allocator.free(root);
    const apps = try std.fs.path.join(t.allocator, &.{ root, "applications" });
    defer t.allocator.free(apps);
    try cwd.createDirPath(io, apps);

    const df = try std.fs.path.join(t.allocator, &.{ apps, "org.example.Thing.desktop" });
    defer t.allocator.free(df);
    try cwd.writeFile(io, .{ .sub_path = df, .data =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Thing
        \\Exec=thing-bin --flag "A B" %U
        \\
    });

    const hidden = try std.fs.path.join(t.allocator, &.{ apps, "org.example.Hidden.desktop" });
    defer t.allocator.free(hidden);
    try cwd.writeFile(io, .{ .sub_path = hidden, .data =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Hidden
        \\Exec=hidden-bin
        \\Hidden=true
        \\
    });

    var dirs = [_][]const u8{apps};

    var l = try prepare(t.allocator, io, &dirs, "org.example.Thing");
    defer l.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), l.argv.len);
    try t.expectEqualStrings("thing-bin", l.argv[0]);
    try t.expectEqualStrings("--flag", l.argv[1]);
    try t.expectEqualStrings("A B", l.argv[2]);

    // A `Hidden=true` entry is not launchable.
    try t.expectError(error.NotFound, prepare(t.allocator, io, &dirs, "org.example.Hidden"));

    // Unknown ids report NotFound rather than launching something random.
    try t.expectError(error.NotFound, prepare(t.allocator, io, &dirs, "org.example.Nope"));
}

test "app-launch: an id no file name carries resolves by StartupWMClass" {
    const t = std.testing;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer t.allocator.free(root);
    const apps = try std.fs.path.join(t.allocator, &.{ root, "applications" });
    defer t.allocator.free(apps);
    try cwd.createDirPath(io, apps);

    // The Proton VPN shape: the file is named for the app, the window reports
    // something else entirely, and only `StartupWMClass` joins the two.
    const df = try std.fs.path.join(t.allocator, &.{ apps, "com.example.Vpn.desktop" });
    defer t.allocator.free(df);
    try cwd.writeFile(io, .{ .sub_path = df, .data =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Vpn
        \\Exec=vpn-app %u
        \\Icon=com.example.Vpn
        \\StartupWMClass=proton.vpn.app.gtk
        \\
    });

    var dirs = [_][]const u8{apps};

    const found = findDesktopPath(t.allocator, io, &dirs, "proton.vpn.app.gtk");
    defer if (found) |p| t.allocator.free(p);
    try t.expect(found != null);
    try t.expectEqualStrings("com.example.Vpn.desktop", std.fs.path.basename(found.?));

    // …which is where the icon and the launch come from.
    const icon = desktopIcon(t.allocator, io, &dirs, "proton.vpn.app.gtk");
    defer if (icon) |n| t.allocator.free(n);
    try t.expect(icon != null);
    try t.expectEqualStrings("com.example.Vpn", icon.?);

    var l = try prepare(t.allocator, io, &dirs, "proton.vpn.app.gtk");
    defer l.deinit(t.allocator);
    try t.expectEqualStrings("vpn-app", l.argv[0]);

    // The fold is case- and path-insensitive on both sides.
    const spaced = findDesktopPath(t.allocator, io, &dirs, "Proton.VPN.App.GTK");
    defer if (spaced) |p| t.allocator.free(p);
    try t.expect(spaced != null);

    // A class no file advertises is still no answer.
    const absent = findDesktopPath(t.allocator, io, &dirs, "com.example.Absent");
    defer if (absent) |p| t.allocator.free(p);
    try t.expect(absent == null);
}

test "app-launch: the window-class index answers for the path it was built under" {
    const t = std.testing;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer t.allocator.free(root);

    // Two directories advertising the same class under different files: the
    // only thing that can tell them apart is which directory list is asked.
    const dirs_a = [_][]const u8{try std.fs.path.join(t.allocator, &.{ root, "a" })};
    const dirs_b = [_][]const u8{try std.fs.path.join(t.allocator, &.{ root, "b" })};
    defer t.allocator.free(dirs_a[0]);
    defer t.allocator.free(dirs_b[0]);
    try cwd.createDirPath(io, dirs_a[0]);
    try cwd.createDirPath(io, dirs_b[0]);

    for ([_]struct { dir: []const u8, stem: []const u8 }{
        .{ .dir = dirs_a[0], .stem = "com.example.First" },
        .{ .dir = dirs_b[0], .stem = "com.example.Second" },
    }) |w| {
        const name = try std.fmt.allocPrint(t.allocator, "{s}.desktop", .{w.stem});
        defer t.allocator.free(name);
        const df = try std.fs.path.join(t.allocator, &.{ w.dir, name });
        defer t.allocator.free(df);
        try cwd.writeFile(io, .{ .sub_path = df, .data =
            \\[Desktop Entry]
            \\Type=Application
            \\Name=Thing
            \\Exec=thing
            \\StartupWMClass=shared.class
            \\
        });
    }

    const first = findDesktopPath(t.allocator, io, &dirs_a, "shared.class");
    defer if (first) |p| t.allocator.free(p);
    try t.expect(first != null);
    try t.expectEqualStrings("com.example.First.desktop", std.fs.path.basename(first.?));

    const second = findDesktopPath(t.allocator, io, &dirs_b, "shared.class");
    defer if (second) |p| t.allocator.free(p);
    try t.expect(second != null);
    try t.expectEqualStrings("com.example.Second.desktop", std.fs.path.basename(second.?));

    // The second build replaced the first rather than being answered from it.
    const again = findDesktopPath(t.allocator, io, &dirs_a, "shared.class");
    defer if (again) |p| t.allocator.free(p);
    try t.expect(again != null);
    try t.expectEqualStrings("com.example.First.desktop", std.fs.path.basename(again.?));
}
