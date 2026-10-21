//! `[Desktop Action ...]` groups — the extra rows the dock/taskbar/panel
//! right-click menu offers for an app, above Pin and the window list. Steam's
//! Store / Library / Big Picture rows are exactly these: the app's own
//! `.desktop` file names them in `Actions=` and defines each group's
//! `Name`/`Exec`.
//!
//! Action half of desktop-entry parsing, with the same
//! three rules that file follows:
//!
//!   - `Actions=` in `[Desktop Entry]` names the ids *in menu order*; an id
//!     it names but no group defines still occupies its slot (an inert row),
//!     and a group it omits is dropped entirely;
//!   - with no `Actions=` line at all, the groups stand in file order;
//!   - within a group the first `Name=`/`Exec=` wins, and the locale variants
//!     (`Name[de]=`) are not `Name`, so they never shadow the plain key.
//!
//! Everything is allocated from the caller's allocator. The dock passes the
//! popup arena, which makes the whole record die with the menu it built and
//! turns the frees inside `forAppId` into no-ops.

const std = @import("std");
const app_launch = @import("app_launch.zig");

/// One row's worth of "what the file said". `name` empty means the menu
/// paints `id` instead, falling back when the name is empty.
/// does; `exec` empty means the row is drawn disabled.
pub const Action = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    exec: []const u8 = "",
};

pub const Info = struct {
    /// The `[Desktop Entry]` group's `Exec`, with "New Window" enabled on
    /// `popupAppDesktopExec` being non-empty, so an app with no entry — or a
    /// slot the lookup skips, like the settings gear — gets no such row.
    exec: []const u8 = "",
    actions: []const Action = &.{},
};

/// Parse a whole `.desktop` file. Pure — the bus and the filesystem stay on
/// the caller's side, which is what makes this testable on fixtures.
pub fn parseInto(alloc: std.mem.Allocator, data: []const u8) !Info {
    var ids: std.ArrayList([]const u8) = .empty;
    var found: std.ArrayList(Action) = .empty;
    var info = Info{};
    var section: []const u8 = "";

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']') {
            section = line[1 .. line.len - 1];
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = line[eq + 1 ..];

        if (std.mem.eql(u8, section, "Desktop Entry")) {
            if (std.mem.eql(u8, key, "Exec")) {
                // First wins.
                if (info.exec.len == 0) info.exec = try alloc.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "Actions")) {
                var it = std.mem.splitScalar(u8, val, ';');
                while (it.next()) |part| {
                    const id = std.mem.trim(u8, part, " \t");
                    if (id.len == 0) continue;
                    try ids.append(alloc, try alloc.dupe(u8, id));
                }
            }
        } else if (std.mem.startsWith(u8, section, "Desktop Action ")) {
            const id = std.mem.trim(u8, section["Desktop Action ".len ..], " \t");
            if (id.len == 0) continue;
            const act = try findOrCreate(alloc, &found, id);
            if (std.mem.eql(u8, key, "Name")) {
                if (act.name.len == 0) act.name = try alloc.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "Exec")) {
                if (act.exec.len == 0) act.exec = try alloc.dupe(u8, val);
            }
        }
    }

    if (ids.items.len > 0) {
        // `Actions=` decides both membership and order. An id with no group
        // behind it keeps its slot as an empty Action — the menu draws it
        // disabled rather than silently closing up the gap.
        var ordered: std.ArrayList(Action) = .empty;
        for (ids.items) |id| {
            for (found.items) |a| {
                if (std.mem.eql(u8, a.id, id)) {
                    try ordered.append(alloc, a);
                    break;
                }
            } else try ordered.append(alloc, .{ .id = id });
        }
        info.actions = try ordered.toOwnedSlice(alloc);
    } else {
        info.actions = try found.toOwnedSlice(alloc);
    }
    return info;
}

fn findOrCreate(
    alloc: std.mem.Allocator,
    list: *std.ArrayList(Action),
    id: []const u8,
) !*Action {
    for (list.items) |*a| {
        if (std.mem.eql(u8, a.id, id)) return a;
    }
    try list.append(alloc, .{ .id = id });
    return &list.items[list.items.len - 1];
}

/// `find_desktop_file_for_appid` + `read_desktop_entry_info`, narrowed to
/// what the right-click menu needs. Returns an empty `Info` rather than
/// null: an app with no entry is a menu without extra rows, not an error.
pub fn forAppId(
    alloc: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    app_id: []const u8,
) Info {
    const path = app_launch.findDesktopPath(alloc, io, dirs, app_id) orelse return .{};
    defer alloc.free(path);
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return .{};
    defer alloc.free(data);
    return parseInto(alloc, data) catch .{};
}

test "desktop-actions: Actions= decides membership and order" {
    const t = std.testing;
    // The dock passes the popup arena; every test here does the same rather
    // than hand back each duped string.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Steam's shape: an `Actions=` list, one group per id, one id listed
    // with no group behind it, and one group the list never mentions.
    const info = try parseInto(alloc,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Steam
        \\Exec=steam %U
        \\Actions=Store;BigPicture;Missing;Library;
        \\
        \\[Desktop Action Store]
        \\Name=Store
        \\Exec=steam steam://open/store
        \\
        \\[Desktop Action BigPicture]
        \\Name=Start In Big Picture Mode
        \\Exec=steam -bigpicture
        \\
        \\[Desktop Action Library]
        \\Exec=steam steam://open/games
        \\
        \\[Desktop Action Orphan]
        \\Name=Never Listed
        \\Exec=nope
        \\
    );
    try t.expectEqualStrings("steam %U", info.exec);
    try t.expectEqual(@as(usize, 4), info.actions.len);

    try t.expectEqualStrings("Store", info.actions[0].id);
    try t.expectEqualStrings("Store", info.actions[0].name);
    try t.expectEqualStrings("steam steam://open/store", info.actions[0].exec);

    try t.expectEqualStrings("BigPicture", info.actions[1].id);
    try t.expectEqualStrings("Start In Big Picture Mode", info.actions[1].name);

    // Listed but never defined: the slot survives with empty fields, which
    // the menu turns into a disabled row.
    try t.expectEqualStrings("Missing", info.actions[2].id);
    try t.expectEqualStrings("", info.actions[2].name);
    try t.expectEqualStrings("", info.actions[2].exec);

    // Defined but never listed: dropped.
    try t.expectEqualStrings("Library", info.actions[3].id);
    for (info.actions) |a| try t.expect(!std.mem.eql(u8, a.id, "Orphan"));
}

test "desktop-actions: no Actions= line leaves the groups in file order" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const info = try parseInto(alloc,
        \\[Desktop Entry]
        \\Name=Thing
        \\Exec=thing
        \\
        \\[Desktop Action Second]
        \\Name=Second
        \\Exec=thing --second
        \\Name=Shadowed
        \\Exec=thing --shadowed
        \\
        \\[Desktop Action First]
        \\Name=First
        \\Exec=thing --first
        \\
        \\# a comment between groups
        \\[Desktop Action ]
        \\Name=No Id
        \\Exec=nope
        \\
    );
    try t.expectEqualStrings("thing", info.exec);
    try t.expectEqual(@as(usize, 2), info.actions.len);
    try t.expectEqualStrings("Second", info.actions[0].id);
    try t.expectEqualStrings("thing --second", info.actions[0].exec);
    try t.expectEqualStrings("First", info.actions[1].id);
    // First `Name=`/`Exec=` in the group wins; the second is ignored.
    try t.expectEqualStrings("Second", info.actions[0].name);
}

test "desktop-actions: locale keys and a file with no groups at all" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const info = try parseInto(alloc,
        \\[Desktop Entry]
        \\Name=Plain
        \\Name[de]=Verdeuted
        \\Exec=plain --run
        \\Actions=One;
        \\
        \\[Desktop Action One]
        \\Name=One
        \\Name[de]=Eins
        \\Exec=plain --one
        \\
    );
    // The locale variant never shadows the plain key, in either group.
    try t.expectEqualStrings("plain --run", info.exec);
    try t.expectEqualStrings("One", info.actions[0].name);
    try t.expectEqualStrings("plain --one", info.actions[0].exec);

    const bare = try parseInto(alloc, "[Desktop Entry]\nName=Nope\n");
    try t.expectEqual(@as(usize, 0), bare.actions.len);
    try t.expectEqualStrings("", bare.exec);
}

test "desktop-actions: forAppId resolves an exported file" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    const apps = try std.fs.path.join(alloc, &.{ root, "applications" });
    defer alloc.free(apps);
    try cwd.createDirPath(io, apps);

    const df = try std.fs.path.join(alloc, &.{ apps, "com.steam.Steam.desktop" });
    defer alloc.free(df);
    try cwd.writeFile(io, .{ .sub_path = df, .data =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Steam
        \\Exec=steam %U
        \\Actions=BigPicture;
        \\
        \\[Desktop Action BigPicture]
        \\Name=Big Picture Mode
        \\Exec=steam -bigpicture
        \\
    });

    var dirs = [_][]const u8{apps};
    // As everywhere in this file: the arena is the caller's, so the frees
    // inside `forAppId` are no-ops and each string dies with the test.
    const info = forAppId(alloc, io, &dirs, "com.steam.Steam");
    try t.expectEqual(@as(usize, 1), info.actions.len);
    try t.expectEqualStrings("Big Picture Mode", info.actions[0].name);
    try t.expectEqualStrings("steam -bigpicture", info.actions[0].exec);

    // An id nothing exports is an empty menu, not a failure.
    const none = forAppId(alloc, io, &dirs, "com.example.Nope");
    try t.expectEqual(@as(usize, 0), none.actions.len);
    try t.expectEqualStrings("", none.exec);
}
