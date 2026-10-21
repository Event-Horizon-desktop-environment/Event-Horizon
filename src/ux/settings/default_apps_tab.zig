const std = @import("std");

pub const Slot = enum { web, mail, calendar, files, terminal, music, video, images, pdf };

pub const Model = struct {
    apps: [@typeInfo(Slot).@"enum".fields.len][]const u8 = [_][]const u8{""} ** @typeInfo(Slot).@"enum".fields.len,

    pub fn set(self: *Model, slot: Slot, app_id: []const u8) void {
        self.apps[@intFromEnum(slot)] = app_id;
    }

    pub fn get(self: *const Model, slot: Slot) []const u8 {
        return self.apps[@intFromEnum(slot)];
    }

    pub fn filled(self: *const Model) usize {
        var n: usize = 0;
        for (self.apps) |a| {
            if (a.len > 0) n += 1;
        }
        return n;
    }
};

test "settings-default-apps: slots" {
    const t = std.testing;
    var m = Model{};
    m.set(.web, "firefox.desktop");
    m.set(.terminal, "kitty.desktop");
    try t.expectEqualStrings("firefox.desktop", m.get(.web));
    try t.expectEqualStrings("", m.get(.mail));
    try t.expectEqual(@as(usize, 2), m.filled());
}
