//! Launchpad folders: auto buckets, manual folders, overrides, persistence.
//!
//! Empty query shows folders plus loose apps; any query shows flat hits.
//! Auto folders group the catalog by freedesktop category using the exact
//! bucket table below (the catch-all never becomes a folder, singletons
//! stay loose unless the user touched the bucket). Manual folders come
//! from drag-and-drop and persist with removals, additions, renames and
//! grid order in `overview_folders.toml`. Members are desktop paths;
//! indices resolve against the caller-provided app list at build time.

const std = @import("std");
const toml = @import("../../config/toml.zig");
const tw = @import("../../config/toml_writer.zig");

pub const Bucket = struct {
    label: []const u8,
    members: []const []const u8,
};

pub const buckets = [_]Bucket{
    .{ .label = "Productivity", .members = &.{ "Office", "Finance", "ProjectManagement", "Spreadsheet", "WordProcessor", "Presentation" } },
    .{ .label = "Creativity", .members = &.{ "Graphics", "Photography", "Publishing", "ImageProcessing", "VectorGraphics", "RasterGraphics" } },
    .{ .label = "Media", .members = &.{ "AudioVideo", "Audio", "Video", "Music", "Player", "Recorder" } },
    .{ .label = "Games", .members = &.{ "Game", "Amusement", "ActionGame", "ArcadeGame", "BoardGame", "CardGame", "KidsGame", "LogicGame", "RolePlaying", "Shooter", "Simulation", "SportsGame", "StrategyGame" } },
    .{ .label = "Developer", .members = &.{ "Development", "IDE", "GUIDesigner", "Profiling" } },
    .{ .label = "Utilities", .members = &.{ "Utility", "System", "Settings", "Administration", "PackageManager", "FileTools", "TerminalEmulator" } },
    .{ .label = "Other", .members = &.{} },
};

pub const bucket_count: usize = buckets.len;

/// Bucket index for raw `;`-separated freedesktop categories. Bucket
/// priority dominates token order: the first bucket holding any token
/// wins: buckets are scanned in priority order.
pub fn bucketFor(cats: []const u8) usize {
    var b: usize = 0;
    while (b < bucket_count - 1) : (b += 1) {
        for (buckets[b].members) |want| {
            var start: usize = 0;
            while (start <= cats.len) {
                const end = std.mem.indexOfScalarPos(u8, cats, start, ';') orelse cats.len;
                if (cats[start..end].len == want.len and std.mem.eql(u8, cats[start..end], want)) return b;
                if (end == cats.len) break;
                start = end + 1;
            }
        }
    }
    return bucket_count - 1;
}

pub const Folder = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    /// Desktop paths, owned.
    members: [][]const u8 = &.{},
};

pub const Item = struct {
    folder: bool = false,
    /// Index into `folders` (folder) or into the caller app list (app).
    index: usize = 0,
    /// Stable identity for shuffle animation + persisted order:
    /// `f:<folder id>` / `a:<desktop path>`, owned.
    key: []const u8 = "",
};

pub const ShuffleFrom = struct {
    key: []const u8,
    x: f64,
    y: f64,
};

const ManualFolder = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    paths: std.ArrayList([]const u8) = .empty,
};

pub const State = struct {
    const Self = @This();

    gpa: std.mem.Allocator,
    loaded: bool = false,
    manual: std.ArrayList(ManualFolder) = .empty,
    removed: std.StringHashMap(void),
    added: std.StringHashMap(std.ArrayList([]const u8)),
    names: std.StringHashMap([]const u8),
    order: std.ArrayList([]const u8) = .empty,
    folders: []Folder = &.{},
    items: []Item = &.{},

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{
            .gpa = gpa,
            .manual = .empty,
            .removed = std.StringHashMap(void).init(gpa),
            .added = std.StringHashMap(std.ArrayList([]const u8)).init(gpa),
            .names = std.StringHashMap([]const u8).init(gpa),
            .order = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.freeBuilt();
        for (self.manual.items) |*m| {
            self.gpa.free(m.id);
            self.gpa.free(m.name);
            for (m.paths.items) |p| self.gpa.free(p);
            m.paths.deinit(self.gpa);
        }
        self.manual.deinit(self.gpa);
        var rit = self.removed.iterator();
        while (rit.next()) |e| self.gpa.free(e.key_ptr.*);
        self.removed.deinit();
        var ait = self.added.iterator();
        while (ait.next()) |e| {
            for (e.value_ptr.items) |p| self.gpa.free(p);
            e.value_ptr.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.added.deinit();
        var nit = self.names.iterator();
        while (nit.next()) |e| {
            self.gpa.free(e.value_ptr.*);
            self.gpa.free(e.key_ptr.*);
        }
        self.names.deinit();
        for (self.order.items) |o| self.gpa.free(o);
        self.order.deinit(self.gpa);
    }

    fn freeBuilt(self: *Self) void {
        for (self.folders) |*f| {
            self.gpa.free(f.id);
            self.gpa.free(f.name);
            for (f.members) |m| self.gpa.free(m);
            self.gpa.free(f.members);
        }
        self.gpa.free(self.folders);
        self.folders = &.{};
        for (self.items) |*it| self.gpa.free(it.key);
        self.gpa.free(self.items);
        self.items = &.{};
    }

    /// App list view the build reads: path + categories per app, in
    /// catalog order.
    pub const App = struct {
        path: []const u8,
        categories: []const u8,
    };

    fn findApp(apps: []const App, path: []const u8) ?usize {
        for (apps, 0..) |a, i| {
            if (std.mem.eql(u8, a.path, path)) return i;
        }
        return null;
    }

    /// Rebuild folders + items from the query-filtered app list. Empty
    /// query with apps builds grouped folders; anything else is flat.
    pub fn rebuild(self: *Self, apps: []const App, query_empty: bool) !void {
        self.freeBuilt();
        if (!query_empty) {
            var items: std.ArrayList(Item) = .empty;
            errdefer items.deinit(self.gpa);
            for (apps, 0..) |_, i| {
                const key = try std.fmt.allocPrint(self.gpa, "a:{s}", .{apps[i].path});
                errdefer self.gpa.free(key);
                try items.append(self.gpa, .{ .folder = false, .index = i, .key = key });
            }
            self.items = try items.toOwnedSlice(self.gpa);
            return;
        }
        const other = bucket_count - 1;
        var members: [bucket_count]std.ArrayList(usize) = undefined;
        for (&members) |*m| m.* = .empty;
        defer for (&members) |*m| m.deinit(self.gpa);
        for (apps, 0..) |a, i| {
            if (self.removed.contains(a.path)) continue;
            try members[bucketFor(a.categories)].append(self.gpa, i);
        }
        var folders: std.ArrayList(Folder) = .empty;
        errdefer {
            for (folders.items) |*f| {
                self.gpa.free(f.id);
                self.gpa.free(f.name);
            }
            folders.deinit(self.gpa);
        }
        var items: std.ArrayList(Item) = .empty;
        errdefer items.deinit(self.gpa);
        var grouped = try self.gpa.alloc(bool, apps.len);
        defer self.gpa.free(grouped);
        @memset(grouped, false);
        var b: usize = 0;
        while (b < bucket_count) : (b += 1) {
            if (b == other) continue;
            const id = try std.fmt.allocPrint(self.gpa, "bucket-{d}", .{b});
            errdefer self.gpa.free(id);
            var mem = members[b].clone(self.gpa) catch continue;
            defer mem.deinit(self.gpa);
            if (self.added.get(id)) |extra| {
                for (extra.items) |p| {
                    if (findApp(apps, p)) |i| {
                        if (!grouped[i] and !containsIdx(mem.items, i)) mem.append(self.gpa, i) catch continue;
                    }
                }
            }
            if (mem.items.len == 0) {
                self.gpa.free(id);
                continue;
            }
            if (mem.items.len < 2 and !self.bucketTouched(b, apps)) {
                self.gpa.free(id);
                continue;
            }
            const label = self.names.get(id) orelse buckets[b].label;
            var folder = Folder{
                .id = id,
                .name = try self.gpa.dupe(u8, label),
            };
            errdefer {
                self.gpa.free(folder.id);
                self.gpa.free(folder.name);
            }
            var mpaths: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (mpaths.items) |p| self.gpa.free(p);
                mpaths.deinit(self.gpa);
            }
            for (mem.items) |i| {
                const p = try self.gpa.dupe(u8, apps[i].path);
                errdefer self.gpa.free(p);
                try mpaths.append(self.gpa, p);
                grouped[i] = true;
            }
            folder.members = try mpaths.toOwnedSlice(self.gpa);
            const fkey = try std.fmt.allocPrint(self.gpa, "f:{s}", .{folder.id});
            errdefer self.gpa.free(fkey);
            const fidx = folders.items.len;
            try folders.append(self.gpa, folder);
            try items.append(self.gpa, .{ .folder = true, .index = fidx, .key = fkey });
        }
        for (self.manual.items) |mf| {
            var mpaths: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (mpaths.items) |p| self.gpa.free(p);
                mpaths.deinit(self.gpa);
            }
            for (mf.paths.items) |p| {
                if (findApp(apps, p)) |i| {
                    if (grouped[i]) continue;
                    const cp = try self.gpa.dupe(u8, p);
                    errdefer self.gpa.free(cp);
                    try mpaths.append(self.gpa, cp);
                    grouped[i] = true;
                }
            }
            if (mpaths.items.len == 0) continue;
            const id = try self.gpa.dupe(u8, mf.id);
            errdefer self.gpa.free(id);
            const label = self.names.get(mf.id) orelse mf.name;
            const name = try self.gpa.dupe(u8, label);
            errdefer self.gpa.free(name);
            const members_owned = try mpaths.toOwnedSlice(self.gpa);
            errdefer {
                for (members_owned) |p| self.gpa.free(p);
                self.gpa.free(members_owned);
            }
            const fkey = try std.fmt.allocPrint(self.gpa, "f:{s}", .{id});
            errdefer self.gpa.free(fkey);
            const fidx = folders.items.len;
            try folders.append(self.gpa, .{ .id = id, .name = name, .members = members_owned });
            try items.append(self.gpa, .{ .folder = true, .index = fidx, .key = fkey });
        }
        for (apps, 0..) |a, i| {
            if (grouped[i]) continue;
            const key = try std.fmt.allocPrint(self.gpa, "a:{s}", .{a.path});
            errdefer self.gpa.free(key);
            try items.append(self.gpa, .{ .folder = false, .index = i, .key = key });
        }
        if (self.order.items.len > 1 and items.items.len > 1) {
            self.applyOrder(&items);
        }
        self.folders = try folders.toOwnedSlice(self.gpa);
        self.items = try items.toOwnedSlice(self.gpa);
    }

    fn containsIdx(list: []const usize, v: usize) bool {
        for (list) |x| if (x == v) return true;
        return false;
    }

    /// True when the user touched the bucket: explicit additions, or a
    /// removal that carved an app out of it.
    fn bucketTouched(self: *Self, b: usize, apps: []const App) bool {
        var idbuf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&idbuf, "bucket-{d}", .{b}) catch return false;
        if (self.added.get(id)) |extra| {
            if (extra.items.len > 0) return true;
        }
        var rit = self.removed.iterator();
        while (rit.next()) |e| {
            if (findApp(apps, e.key_ptr.*)) |i| {
                if (bucketFor(apps[i].categories) == b) return true;
            }
        }
        return false;
    }

    /// Saved manual order over the display build: known ids sort by saved
    /// position, unknown ids keep relative order at the end.
    fn applyOrder(self: *Self, items: *std.ArrayList(Item)) void {
        var pos = std.StringHashMap(usize).init(self.gpa);
        defer pos.deinit();
        for (self.order.items, 0..) |id, i| pos.put(id, i) catch continue;
        std.mem.sort(Item, items.items, &pos, struct {
            fn lt(p: *std.StringHashMap(usize), a: Item, b: Item) bool {
                const pa = p.get(a.key);
                const pb = p.get(b.key);
                if ((pa == null) != (pb == null)) return pa != null;
                if (pa != null) return pa.? < pb.?;
                return false;
            }
        }.lt);
    }

    /// App path for a main-grid item, or "" for folders/out of range.
    pub fn itemPath(self: *Self, idx: i32, apps: []const App) []const u8 {
        if (idx < 0 or idx >= self.items.len) return "";
        const it = self.items[@intCast(idx)];
        if (it.folder) return "";
        if (it.index >= apps.len) return "";
        return apps[it.index].path;
    }

    /// App path for a modal cell over the open folder's members.
    pub fn modalItemPath(self: *Self, open_folder: i32, idx: usize) []const u8 {
        if (open_folder < 0 or open_folder >= self.folders.len) return "";
        const m = self.folders[@intCast(open_folder)].members;
        if (idx >= m.len) return "";
        return m[idx];
    }

    /// Inline rename state. Keystrokes edit the buffer until Enter commits
    /// or Esc cancels; the buffer caps at 48 bytes with proper pop.
    pub const Rename = struct {
        active: bool = false,
        buf: [48]u8 = undefined,
        len: usize = 0,

        pub fn start(self: *Rename, current: []const u8) void {
            self.active = true;
            const n = @min(current.len, self.buf.len);
            @memcpy(self.buf[0..n], current[0..n]);
            self.len = n;
        }

        pub fn cancel(self: *Rename) void {
            self.active = false;
            self.len = 0;
        }

        pub fn typeText(self: *Rename, chunk: []const u8) void {
            if (!self.active) return;
            for (chunk) |ch| {
                if (self.len >= self.buf.len) return;
                self.buf[self.len] = ch;
                self.len += 1;
            }
        }

        pub fn backspace(self: *Rename) void {
            if (!self.active or self.len == 0) return;
            self.len -= 1;
            while (self.len > 0 and (self.buf[self.len] & 0xC0) == 0x80) self.len -= 1;
        }

        pub fn text(self: *const Rename) []const u8 {
            return self.buf[0..self.len];
        }
    };

    pub fn renameFolder(self: *Self, folder_id: []const u8, name: []const u8) void {
        if (name.len == 0) return;
        if (self.names.fetchRemove(folder_id)) |old| {
            self.gpa.free(old.key);
            self.gpa.free(old.value);
        }
        const kc = self.gpa.dupe(u8, folder_id) catch return;
        errdefer self.gpa.free(kc);
        const owned = self.gpa.dupe(u8, name) catch return;
        errdefer self.gpa.free(owned);
        self.names.put(kc, owned) catch {
            self.gpa.free(kc);
            self.gpa.free(owned);
        };
    }

    fn clearOrder(self: *Self) void {
        for (self.order.items) |o| self.gpa.free(o);
        self.order.clearRetainingCapacity();
    }

    /// Move display cell `src` before/after `dst`, persisting the order.
    pub fn reorder(self: *Self, src_idx: usize, dst_idx: usize, after: bool) void {
        if (src_idx >= self.items.len or dst_idx >= self.items.len or src_idx == dst_idx) return;
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(self.gpa);
        for (self.items) |it| ids.append(self.gpa, it.key) catch return;
        const moving = ids.orderedRemove(src_idx);
        var pos: usize = 0;
        for (ids.items, 0..) |id, i| {
            if (std.mem.eql(u8, id, self.items[dst_idx].key)) {
                pos = i;
                break;
            }
            pos = i + 1;
        }
        if (after) pos += 1;
        if (pos > ids.items.len) pos = ids.items.len;
        ids.insert(self.gpa, pos, moving) catch return;
        self.clearOrder();
        for (ids.items) |id| self.order.append(self.gpa, self.gpa.dupe(u8, id) catch continue) catch continue;
        // Re-sort the live items to match.
        var pos_map = std.StringHashMap(usize).init(self.gpa);
        defer pos_map.deinit();
        for (ids.items, 0..) |id, i| pos_map.put(id, i) catch continue;
        std.mem.sort(Item, self.items, &pos_map, struct {
            fn lt(p: *std.StringHashMap(usize), a: Item, b: Item) bool {
                const pa = p.get(a.key);
                const pb = p.get(b.key);
                if ((pa == null) != (pb == null)) return pa != null;
                if (pa != null) return pa.? < pb.?;
                return false;
            }
        }.lt);
    }

    /// Create a manual folder from two app paths. Returns its id or "".
    pub fn createManual(self: *Self, apps: []const App, path_a: []const u8, path_b: []const u8) []const u8 {
        if (path_a.len == 0 or path_b.len == 0 or std.mem.eql(u8, path_a, path_b)) return "";
        if (findApp(apps, path_a) == null or findApp(apps, path_b) == null) return "";
        var n: usize = 0;
        for (self.manual.items) |m| {
            if (std.mem.startsWith(u8, m.id, "custom-")) {
                const num = std.fmt.parseInt(usize, m.id["custom-".len..], 10) catch continue;
                n = @max(n, num + 1);
            }
        }
        var idbuf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&idbuf, "custom-{d}", .{n}) catch return "";
        var mf = ManualFolder{};
        mf.id = self.gpa.dupe(u8, id) catch return "";
        errdefer self.gpa.free(mf.id);
        mf.name = self.gpa.dupe(u8, "Folder") catch {
            self.gpa.free(mf.id);
            return "";
        };
        errdefer self.gpa.free(mf.name);
        for ([2][]const u8{ path_a, path_b }) |p| {
            const cp = self.gpa.dupe(u8, p) catch continue;
            mf.paths.append(self.gpa, cp) catch {
                self.gpa.free(cp);
                continue;
            };
        }
        if (mf.paths.items.len == 0) {
            self.gpa.free(mf.id);
            self.gpa.free(mf.name);
            return "";
        }
        self.manual.append(self.gpa, mf) catch {
            for (mf.paths.items) |p| self.gpa.free(p);
            mf.paths.deinit(self.gpa);
            self.gpa.free(mf.id);
            self.gpa.free(mf.name);
            return "";
        };
        self.exclude(path_a);
        self.exclude(path_b);
        return self.manual.items[self.manual.items.len - 1].id;
    }

    fn exclude(self: *Self, path: []const u8) void {
        if (self.removed.contains(path)) return;
        const cp = self.gpa.dupe(u8, path) catch return;
        self.removed.put(cp, {}) catch {
            self.gpa.free(cp);
        };
    }

    /// Move an app into a folder by id. Custom folders pull from elsewhere
    /// first (one home per app); auto folders record an explicit addition.
    pub fn moveInto(self: *Self, apps: []const App, app_path: []const u8, folder_id: []const u8) void {
        if (app_path.len == 0 or folder_id.len == 0) return;
        if (findApp(apps, app_path) == null) return;
        if (std.mem.startsWith(u8, folder_id, "custom-")) {
            var found = false;
            for (self.manual.items) |*m| {
                if (!std.mem.eql(u8, m.id, folder_id)) {
                    var k: usize = 0;
                    while (k < m.paths.items.len) {
                        if (std.mem.eql(u8, m.paths.items[k], app_path)) {
                            self.gpa.free(m.paths.items[k]);
                            _ = m.paths.orderedRemove(k);
                        } else k += 1;
                    }
                    continue;
                }
                found = true;
                for (m.paths.items) |p| {
                    if (std.mem.eql(u8, p, app_path)) return;
                }
                const cp = self.gpa.dupe(u8, app_path) catch return;
                m.paths.append(self.gpa, cp) catch {
                    self.gpa.free(cp);
                    return;
                };
            }
            if (!found) return;
            self.exclude(app_path);
            self.pruneManual();
            return;
        }
        const vec = self.added.getPtr(folder_id);
        if (vec) |vv| {
            for (vv.items) |p| {
                if (std.mem.eql(u8, p, app_path)) {
                    self.finishAutoMove(app_path);
                    return;
                }
            }
            const cp = self.gpa.dupe(u8, app_path) catch return;
            vv.append(self.gpa, cp) catch {
                self.gpa.free(cp);
                return;
            };
        } else {
            const kc = self.gpa.dupe(u8, folder_id) catch return;
            errdefer self.gpa.free(kc);
            var nv: std.ArrayList([]const u8) = .empty;
            errdefer nv.deinit(self.gpa);
            const cp = self.gpa.dupe(u8, app_path) catch return;
            errdefer self.gpa.free(cp);
            nv.append(self.gpa, cp) catch return;
            self.added.put(kc, nv) catch {
                self.gpa.free(kc);
                self.gpa.free(cp);
                nv.deinit(self.gpa);
                return;
            };
        }
        self.finishAutoMove(app_path);
    }

    fn finishAutoMove(self: *Self, app_path: []const u8) void {
        for (self.manual.items) |*m| {
            var k: usize = 0;
            while (k < m.paths.items.len) {
                if (std.mem.eql(u8, m.paths.items[k], app_path)) {
                    self.gpa.free(m.paths.items[k]);
                    _ = m.paths.orderedRemove(k);
                } else k += 1;
            }
        }
        self.exclude(app_path);
        self.pruneManual();
    }

    fn pruneManual(self: *Self) void {
        var k: usize = 0;
        while (k < self.manual.items.len) {
            if (self.manual.items[k].paths.items.len == 0) {
                var m = self.manual.orderedRemove(k);
                self.gpa.free(m.id);
                self.gpa.free(m.name);
                m.paths.deinit(self.gpa);
            } else k += 1;
        }
    }

    /// Remove an app from the open folder. Custom folders erase the member
    /// (dissolving when emptied); auto folders gain an exclusion.
    pub fn removeFrom(self: *Self, app_path: []const u8, open_folder: i32) void {
        if (open_folder < 0 or open_folder >= self.folders.len or app_path.len == 0) return;
        const fid = self.folders[@intCast(open_folder)].id;
        if (std.mem.startsWith(u8, fid, "custom-")) {
            for (self.manual.items) |*m| {
                if (!std.mem.eql(u8, m.id, fid)) continue;
                var k: usize = 0;
                while (k < m.paths.items.len) {
                    if (std.mem.eql(u8, m.paths.items[k], app_path)) {
                        self.gpa.free(m.paths.items[k]);
                        _ = m.paths.orderedRemove(k);
                    } else k += 1;
                }
            }
            self.pruneManual();
        } else {
            self.exclude(app_path);
        }
    }

    /// `<state>/overview_folders.toml`, mirroring `state_event_horizon_dir()`
    /// (the shared lowercase leaf, not the Zig config leaf).
    pub fn statePath(gpa: std.mem.Allocator, buf: []u8) ?[]const u8 {
        if (std.c.getenv("XDG_STATE_HOME")) |x| {
            const s = std.mem.span(x);
            if (s.len > 0) {
                const j = std.fs.path.join(gpa, &.{ s, "event-horizon" }) catch return null;
                defer gpa.free(j);
                return std.fmt.bufPrint(buf, "{s}/overview_folders.toml", .{j}) catch null;
            }
        }
        if (std.c.getenv("HOME")) |h| {
            const s = std.mem.span(h);
            if (s.len > 0) {
                const j = std.fs.path.join(gpa, &.{ s, ".local", "state", "event-horizon" }) catch return null;
                defer gpa.free(j);
                return std.fmt.bufPrint(buf, "{s}/overview_folders.toml", .{j}) catch null;
            }
        }
        return std.fmt.bufPrint(buf, "/tmp/event-horizon/overview_folders.toml", .{}) catch null;
    }

    /// Load persisted overrides. Missing/corrupt file starts clean, and
    /// either way the state counts as loaded afterwards.
    pub fn loadFile(self: *Self, io: std.Io) void {
        if (self.loaded) return;
        self.loaded = true;
        var pbuf: [1024]u8 = undefined;
        const path = statePath(self.gpa, &pbuf) orelse return;
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(1 << 20)) catch return;
        defer self.gpa.free(text);
        var doc = toml.parse(self.gpa, text) catch return;
        defer doc.deinit();
        if (doc.get("removed")) |v| {
            if (v == .array) {
                for (v.array) |el| {
                    if (el != .string) continue;
                    const cp = self.gpa.dupe(u8, el.string) catch continue;
                    self.removed.put(cp, {}) catch {
                        self.gpa.free(cp);
                    };
                }
            }
        }
        if (doc.table("added")) |t| {
            if (t.* != .table) return;
            var it = t.table.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* != .array) continue;
                const kc = self.gpa.dupe(u8, e.key_ptr.*) catch continue;
                errdefer self.gpa.free(kc);
                var vec: std.ArrayList([]const u8) = .empty;
                errdefer vec.deinit(self.gpa);
                for (e.value_ptr.array) |el| {
                    if (el != .string) continue;
                    vec.append(self.gpa, self.gpa.dupe(u8, el.string) catch continue) catch continue;
                }
                self.added.put(kc, vec) catch {
                    self.gpa.free(kc);
                    for (vec.items) |p| self.gpa.free(p);
                    vec.deinit(self.gpa);
                };
            }
        }
        if (doc.table("names")) |t| {
            if (t.* != .table) return;
            var it = t.table.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* != .string) continue;
                if (e.value_ptr.string.len == 0) continue;
                const kc = self.gpa.dupe(u8, e.key_ptr.*) catch continue;
                errdefer self.gpa.free(kc);
                const vc = self.gpa.dupe(u8, e.value_ptr.string) catch {
                    self.gpa.free(kc);
                    continue;
                };
                errdefer self.gpa.free(vc);
                self.names.put(kc, vc) catch {
                    self.gpa.free(kc);
                    self.gpa.free(vc);
                };
            }
        }
        if (doc.get("order")) |v| {
            if (v == .array) {
                for (v.array) |el| {
                    if (el != .string) continue;
                    self.order.append(self.gpa, self.gpa.dupe(u8, el.string) catch continue) catch continue;
                }
            }
        }
        // Custom folders keep creation order (`custom-N` survives the
        // round trip through the name, so numbering never reuses ids).
        const customs: []const toml.Value = blk: {
            const vv = doc.get("custom") orelse break :blk &.{};
            if (vv != .array) break :blk &.{};
            break :blk vv.array;
        };
        for (customs) |el| {
            if (el != .table) continue;
            const nm = el.table.get("name");
            const ap = el.table.get("apps");
            const name = if (nm != null and nm.? == .string) nm.?.string else "Folder";
            var mf = ManualFolder{};
            {
                var n: usize = 0;
                var found = true;
                while (found) {
                    found = false;
                    var idbuf: [32]u8 = undefined;
                    const cand = std.fmt.bufPrint(&idbuf, "custom-{d}", .{n}) catch break;
                    for (self.manual.items) |m| {
                        if (std.mem.eql(u8, m.id, cand)) {
                            found = true;
                            break;
                        }
                    }
                    if (found) n += 1;
                }
                var idbuf: [32]u8 = undefined;
                const id = std.fmt.bufPrint(&idbuf, "custom-{d}", .{n}) catch continue;
                mf.id = self.gpa.dupe(u8, id) catch continue;
            }
            errdefer self.gpa.free(mf.id);
            mf.name = self.gpa.dupe(u8, name) catch {
                self.gpa.free(mf.id);
                continue;
            };
            errdefer self.gpa.free(mf.name);
            if (ap != null and ap.? == .array) {
                for (ap.?.array) |ael| {
                    if (ael != .string) continue;
                    mf.paths.append(self.gpa, self.gpa.dupe(u8, ael.string) catch continue) catch continue;
                }
            }
            if (mf.paths.items.len == 0) {
                self.gpa.free(mf.id);
                self.gpa.free(mf.name);
                continue;
            }
            self.manual.append(self.gpa, mf) catch {
                for (mf.paths.items) |p| self.gpa.free(p);
                mf.paths.deinit(self.gpa);
                self.gpa.free(mf.id);
                self.gpa.free(mf.name);
            };
        }
    }

    /// Render + atomic write (tmp + rename) of the persisted overrides.
    pub fn saveFile(self: *Self, io: std.Io) void {
        var pbuf: [1024]u8 = undefined;
        const path = statePath(self.gpa, &pbuf) orelse return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        const S = struct {
            fn sort(a: *std.ArrayList([]const u8)) void {
                // No allocator needed: sorts borrowed views in place.
                std.mem.sort([]const u8, a.items, {}, struct {
                    fn lt(_: void, x: []const u8, y: []const u8) bool {
                        return std.mem.order(u8, x, y) == .lt;
                    }
                }.lt);
            }
            fn quote(o: *std.ArrayList(u8), alloc: std.mem.Allocator, v: []const u8) !void {
                try o.append(alloc, '"');
                for (v) |c| {
                    if (c == '"') try o.appendSlice(alloc, "\\\"");
                    if (c == '\\') try o.appendSlice(alloc, "\\\\");
                    if (c == '\n') try o.appendSlice(alloc, "\\n");
                    if (c != '"' and c != '\\' and c != '\n') try o.append(alloc, c);
                }
                try o.append(alloc, '"');
            }
        };
        var rem: std.ArrayList([]const u8) = .empty;
        defer rem.deinit(self.gpa);
        var rit = self.removed.iterator();
        while (rit.next()) |e| rem.append(self.gpa, e.key_ptr.*) catch return;
        S.sort(&rem);
        tw.writeStringArray(&out, self.gpa, "removed", rem.items) catch return;
        // Root keys (removed, order, custom) all come before any [table]:
        // TOML attaches trailing keys to the last table header.
        tw.writeStringArray(&out, self.gpa, "order", self.order.items) catch return;
        out.appendSlice(self.gpa, "custom = [") catch return;
        for (self.manual.items, 0..) |m, i| {
            if (i > 0) out.appendSlice(self.gpa, ", ") catch return;
            out.appendSlice(self.gpa, "{name = ") catch return;
            S.quote(&out, self.gpa, m.name) catch return;
            out.appendSlice(self.gpa, ", apps = [") catch return;
            for (m.paths.items, 0..) |p, j| {
                if (j > 0) out.appendSlice(self.gpa, ", ") catch return;
                S.quote(&out, self.gpa, p) catch return;
            }
            out.appendSlice(self.gpa, "]}") catch return;
        }
        out.appendSlice(self.gpa, "]\n") catch return;
        out.appendSlice(self.gpa, "[added]\n") catch return;
        var akeys: std.ArrayList([]const u8) = .empty;
        defer akeys.deinit(self.gpa);
        var ait = self.added.iterator();
        while (ait.next()) |e| akeys.append(self.gpa, e.key_ptr.*) catch return;
        S.sort(&akeys);
        for (akeys.items) |k| {
            const v = self.added.get(k) orelse continue;
            tw.writeStringArray(&out, self.gpa, k, v.items) catch return;
        }
        out.appendSlice(self.gpa, "[names]\n") catch return;
        var nkeys: std.ArrayList([]const u8) = .empty;
        defer nkeys.deinit(self.gpa);
        var nit = self.names.iterator();
        while (nit.next()) |e| nkeys.append(self.gpa, e.key_ptr.*) catch return;
        S.sort(&nkeys);
        for (nkeys.items) |k| {
            const v = self.names.get(k) orelse continue;
            tw.writeString(&out, self.gpa, k, v) catch return;
        }
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch return;
        var tmp: [1100]u8 = undefined;
        const tmpp = std.fmt.bufPrint(&tmp, "{s}.tmp", .{path}) catch return;
        cwd.writeFile(io, .{ .sub_path = tmpp, .data = out.items }) catch return;
        cwd.rename(tmpp, cwd, path, io) catch return;
    }
};

test "overview-folders: tahoe buckets match first bucket holding any token" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), bucketFor("Office;WordProcessor;"));
    try t.expectEqual(@as(usize, 3), bucketFor("Game;StrategyGame;"));
    try t.expectEqual(@as(usize, 4), bucketFor("Development;IDE;"));
    try t.expectEqual(@as(usize, 5), bucketFor("Utility;TerminalEmulator;"));
    try t.expectEqual(@as(usize, 6), bucketFor("Network;WebBrowser;"));
    try t.expectEqual(@as(usize, 6), bucketFor(""));
    // Bucket priority dominates token order: Games(3) beats Utilities(5).
    try t.expectEqual(@as(usize, 3), bucketFor("Game;Utility;"));
}

test "overview-folders: auto grouping skips Other and singletons" {
    const t = std.testing;
    var st = State.init(t.allocator);
    defer st.deinit();
    const apps = [_]State.App{
        .{ .path = "/a/firefox.desktop", .categories = "Network;WebBrowser;" },
        .{ .path = "/a/gimp.desktop", .categories = "Graphics;RasterGraphics;" },
        .{ .path = "/a/inkscape.desktop", .categories = "Graphics;VectorGraphics;" },
        .{ .path = "/a/steam.desktop", .categories = "Game;" },
    };
    try st.rebuild(&apps, true);
    // One Creativity folder (2 members); browser, game stay loose.
    try t.expectEqual(@as(usize, 1), st.folders.len);
    try t.expectEqualStrings("bucket-1", st.folders[0].id);
    try t.expectEqualStrings("Creativity", st.folders[0].name);
    try t.expectEqual(@as(usize, 3), st.items.len);
    try t.expect(st.items[0].folder);
    try t.expectEqualStrings("f:bucket-1", st.items[0].key);
    try t.expectEqualStrings("a:/a/firefox.desktop", st.items[1].key);
}

test "overview-folders: manual create, move, remove, reorder, rename" {
    const t = std.testing;
    var st = State.init(t.allocator);
    defer st.deinit();
    const apps = [_]State.App{
        .{ .path = "/a/one.desktop", .categories = "Utility;" },
        .{ .path = "/a/two.desktop", .categories = "Game;" },
        .{ .path = "/a/three.desktop", .categories = "Development;" },
        .{ .path = "/a/four.desktop", .categories = "Network;WebBrowser;" },
    };
    const fid = st.createManual(&apps, "/a/one.desktop", "/a/two.desktop");
    try t.expect(fid.len > 0);
    try st.rebuild(&apps, true);
    try t.expectEqual(@as(usize, 1), st.folders.len);
    try t.expectEqual(@as(usize, 2), st.folders[0].members.len);
    // Grid holds the folder plus the two loose singletons.
    try t.expectEqual(@as(usize, 3), st.items.len);
    // Move the third app into the manual folder.
    st.moveInto(&apps, "/a/three.desktop", fid);
    try st.rebuild(&apps, true);
    try t.expectEqual(@as(usize, 3), st.folders[0].members.len);
    try t.expectEqual(@as(usize, 2), st.items.len);
    // Reorder the loose app before the folder.
    st.reorder(1, 0, false);
    try t.expect(!st.items[0].folder);
    try t.expectEqual(@as(usize, 2), st.order.items.len);
    // Remove one: folder survives with two.
    st.removeFrom("/a/one.desktop", 0);
    try st.rebuild(&apps, true);
    try t.expectEqual(@as(usize, 2), st.folders[0].members.len);
    // Rename sticks.
    st.renameFolder(fid, "Stuff");
    try t.expectEqualStrings("Stuff", st.names.get(fid).?);
    try st.rebuild(&apps, true);
    try t.expectEqualStrings("Stuff", st.folders[0].name);
    // Draining the folder dissolves it instead of showing an empty popup.
    st.removeFrom("/a/two.desktop", 0);
    st.removeFrom("/a/three.desktop", 0);
    try st.rebuild(&apps, true);
    try t.expectEqual(@as(usize, 0), st.folders.len);
}

test "overview-folders: persist round trip through the state file" {
    const t = std.testing;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer t.allocator.free(dir);
    const old = std.c.getenv("XDG_STATE_HOME");
    const old_owned = if (old) |o| try t.allocator.dupe(u8, std.mem.span(o)) else null;
    defer if (old_owned) |o| t.allocator.free(o);
    {
        const c = @cImport(@cInclude("stdlib.h"));
        const zd = try t.allocator.dupeZ(u8, dir);
        defer t.allocator.free(zd);
        _ = c.setenv("XDG_STATE_HOME", zd, 1);
    }
    defer {
        const c = @cImport(@cInclude("stdlib.h"));
        if (old_owned) |o| {
            if (t.allocator.dupeZ(u8, o)) |zo| {
                defer t.allocator.free(zo);
                _ = c.setenv("XDG_STATE_HOME", zo, 1);
            } else |_| {}
        } else _ = c.unsetenv("XDG_STATE_HOME");
    }
    var st = State.init(t.allocator);
    defer st.deinit();
    const apps = [_]State.App{
        .{ .path = "/a/one.desktop", .categories = "Utility;" },
        .{ .path = "/a/two.desktop", .categories = "Utility;" },
    };
    const fid = st.createManual(&apps, "/a/one.desktop", "/a/two.desktop");
    try t.expect(fid.len > 0);
    st.renameFolder(fid, "Stuff");
    st.order.append(st.gpa, try st.gpa.dupe(u8, "a:/a/two.desktop")) catch unreachable;
    st.saveFile(io);
    var st2 = State.init(t.allocator);
    defer st2.deinit();
    st2.loadFile(io);
    try t.expect(st2.loaded);
    try t.expectEqual(@as(usize, 1), st2.manual.items.len);
    try t.expectEqualStrings("Stuff", st2.names.get(fid).?);
    try t.expect(st2.removed.contains("/a/one.desktop"));
    try t.expectEqual(@as(usize, 1), st2.order.items.len);
    try st2.rebuild(&apps, true);
    try t.expectEqual(@as(usize, 1), st2.folders.len);
    try t.expectEqualStrings("Stuff", st2.folders[0].name);
    try t.expectEqual(@as(usize, 2), st2.folders[0].members.len);
}
