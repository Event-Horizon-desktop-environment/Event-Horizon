const std = @import("std");
const reflection = @import("../../compat/reflection.zig");

// Default-apps data — Zig port of
// src/ux/settings/data/default_apps/settings_default_apps*.{hpp,cpp}.
// Same design: fixed category list, desktop-id per category, FileManager1
// backed file-manager slot, Exec field-code expansion is argv (never shell).

pub const Category = enum {
    web,
    mail,
    calendar,
    files,
    terminal,
    music,
    video,
    images,
    pdf,
};

pub const category_names = [_][]const u8{
    "Web", "Mail", "Calendar", "Files", "Terminal", "Music", "Video", "Images", "PDF",
};

pub const Model = struct {
    apps: [reflection.enumFields(Category).len][]const u8 = @as([reflection.enumFields(Category).len][]const u8, @splat("")),

    pub fn set(self: *Model, cat: Category, desktop_id: []const u8) void {
        self.apps[@intFromEnum(cat)] = desktop_id;
    }

    pub fn get(self: *const Model, cat: Category) []const u8 {
        return self.apps[@intFromEnum(cat)];
    }

    pub fn filled(self: *const Model) usize {
        var n: usize = 0;
        for (self.apps) |a| {
            if (a.len > 0) n += 1;
        }
        return n;
    }
};

/// Expand Desktop Entry Exec field codes %f/%F/%u/%U to argv (no shell).
/// Returns the number of argv entries written.
pub fn expandExec(exec: []const u8, path: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, exec, ' ');
    while (it.next()) |tok| {
        if (n >= out.len) break;
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "%f") or std.mem.eql(u8, tok, "%F") or
            std.mem.eql(u8, tok, "%u") or std.mem.eql(u8, tok, "%U"))
        {
            if (path.len > 0) {
                out[n] = path;
                n += 1;
            }
            continue;
        }
        if (tok[0] == '%') continue; // drop other field codes
        out[n] = tok;
        n += 1;
    }
    return n;
}

test "settings-default-apps-data: slots + exec" {
    const t = std.testing;
    var m = Model{};
    m.set(.web, "firefox.desktop");
    try t.expectEqual(@as(usize, 1), m.filled());
    var out: [8][]const u8 = undefined;
    const n = expandExec("firefox %u --new-tab", "/tmp/a.html", &out);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqualStrings("/tmp/a.html", out[1]);
}
