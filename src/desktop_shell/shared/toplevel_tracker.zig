const std = @import("std");

pub const Win = struct {
    key: []const u8,
    app_id: []const u8,
    title: []const u8,
    focused: bool = false,
};

pub const Tracker = struct {
    alloc: std.mem.Allocator,
    wins: std.ArrayList(Win),
    on_changed: ?*const fn (ctx: *anyopaque) void = null,
    ctx: *anyopaque = undefined,

    pub fn init(alloc: std.mem.Allocator) Tracker {
        return .{ .alloc = alloc, .wins = .empty };
    }

    pub fn deinit(self: *Tracker) void {
        for (self.wins.items) |*w| {
            self.alloc.free(w.key);
            self.alloc.free(w.app_id);
            self.alloc.free(w.title);
        }
        self.wins.deinit(self.alloc);
    }

    pub fn sync(self: *Tracker, keys: []const []const u8, apps: []const []const u8, titles: []const []const u8, focused_key: ?[]const u8) !bool {
        var changed = false;
        var seen = try self.alloc.alloc(bool, self.wins.items.len);
        defer self.alloc.free(seen);
        @memset(seen, false);
        for (keys, 0..) |k, i| {
            const app = if (i < apps.len) apps[i] else "";
            const title = if (i < titles.len) titles[i] else "";
            var found: ?*Win = null;
            for (self.wins.items, 0..) |*w, j| {
                if (std.mem.eql(u8, w.key, k)) {
                    found = w;
                    seen[j] = true;
                    break;
                }
            }
            if (found) |w| {
                const foc = if (focused_key) |f| std.mem.eql(u8, f, k) else false;
                if (!std.mem.eql(u8, w.title, title) or w.focused != foc) changed = true;
                if (!std.mem.eql(u8, w.title, title)) {
                    self.alloc.free(w.title);
                    w.title = try self.alloc.dupe(u8, title);
                }
                w.focused = foc;
            } else {
                try self.wins.append(self.alloc, .{
                    .key = try self.alloc.dupe(u8, k),
                    .app_id = try self.alloc.dupe(u8, app),
                    .title = try self.alloc.dupe(u8, title),
                    .focused = if (focused_key) |f| std.mem.eql(u8, f, k) else false,
                });
                changed = true;
            }
        }
        var i: usize = self.wins.items.len;
        while (i > 0) {
            i -= 1;
            if (i < seen.len and !seen[i]) {
                const w = self.wins.orderedRemove(i);
                self.alloc.free(w.key);
                self.alloc.free(w.app_id);
                self.alloc.free(w.title);
                changed = true;
            }
        }
        if (changed) {
            if (self.on_changed) |h| h(self.ctx);
        }
        return changed;
    }

    pub fn focused(self: *const Tracker) ?*const Win {
        for (self.wins.items) |*w| {
            if (w.focused) return w;
        }
        return null;
    }
};

test "toplevel-tracker: sync add/update/remove" {
    const t = std.testing;
    var tr = Tracker.init(t.allocator);
    defer tr.deinit();
    try t.expect(try tr.sync(&[_][]const u8{ "a", "b" }, &[_][]const u8{ "x", "y" }, &[_][]const u8{ "t1", "t2" }, "a"));
    try t.expectEqual(@as(usize, 2), tr.wins.items.len);
    try t.expectEqualStrings("t1", tr.focused().?.title);
    try t.expect(!try tr.sync(&[_][]const u8{ "a", "b" }, &[_][]const u8{ "x", "y" }, &[_][]const u8{ "t1", "t2" }, "a"));
    try t.expect(try tr.sync(&[_][]const u8{"b"}, &[_][]const u8{"y"}, &[_][]const u8{"t2"}, null));
    try t.expectEqual(@as(usize, 1), tr.wins.items.len);
}
