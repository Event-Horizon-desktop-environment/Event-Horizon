const std = @import("std");
const theme_data = @import("theme_data.zig");

// User theme manager.
// Owns the custom-theme list, selection, and brightness/contrast/vibrance
// adjustments. Same design: built-ins are read-only, customs live as TOML
// files, selection round-trips through settings.color_theme_* fields.

pub const UserTheme = struct {
    name: []const u8,
    source: []const u8 = "custom",
    palette: theme_data.Palette = .{},
};

pub const Manager = struct {
    alloc: std.mem.Allocator,
    customs: std.ArrayList(UserTheme),
    active_name: []const u8 = "",
    brightness_pct: i32 = 100,
    contrast_pct: i32 = 100,
    vibrance_pct: i32 = 100,

    pub fn init(alloc: std.mem.Allocator) Manager {
        return .{ .alloc = alloc, .customs = .empty };
    }

    pub fn deinit(self: *Manager) void {
        for (self.customs.items) |*c| {
            self.alloc.free(c.name);
            self.alloc.free(c.source);
        }
        self.customs.deinit(self.alloc);
    }

    pub fn addCustom(self: *Manager, name: []const u8, palette: theme_data.Palette) !void {
        for (self.customs.items) |*c| {
            if (std.mem.eql(u8, c.name, name)) {
                c.palette = palette;
                return;
            }
        }
        try self.customs.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, name),
            .source = try self.alloc.dupe(u8, "custom"),
            .palette = palette,
        });
    }

    pub fn removeCustom(self: *Manager, name: []const u8) bool {
        for (self.customs.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.name, name)) {
                self.alloc.free(c.name);
                self.alloc.free(c.source);
                _ = self.customs.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn resolve(self: *const Manager, name: []const u8) ?theme_data.Palette {
        for (self.customs.items) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.palette;
        }
        if (theme_data.findPreset(name)) |p| return p.palette;
        return null;
    }

    pub fn adjustChannel(v: f32, brightness_pct: i32, contrast_pct: i32) f32 {
        const b: f32 = @as(f32, @floatFromInt(brightness_pct)) / 100.0;
        const c: f32 = @as(f32, @floatFromInt(contrast_pct)) / 100.0;
        return @min(1, @max(0, (v - 0.5) * c + 0.5 * b));
    }
};

test "settings-theme-manager: add/resolve/remove" {
    const t = std.testing;
    var m = Manager.init(t.allocator);
    defer m.deinit();
    try m.addCustom("Mine", .{});
    try t.expect(m.resolve("Mine") != null);
    try t.expect(m.resolve("Catppuccin Mocha") != null);
    try t.expect(m.removeCustom("Mine"));
    try t.expect(!m.removeCustom("Mine"));
    try t.expectEqual(@as(f32, 0.5), Manager.adjustChannel(0.5, 100, 100));
}
