const std = @import("std");

pub const Toggle = struct {
    on: bool = false,
    enabled: bool = true,

    pub fn flip(self: *Toggle) bool {
        if (!self.enabled) return self.on;
        self.on = !self.on;
        return self.on;
    }

    pub fn knobOffset(width: i32, on: bool) i32 {
        return if (on) @divTrunc(width, 2) else 0;
    }
};

pub const Dropdown = struct {
    options: []const []const u8 = &.{},
    selected: usize = 0,
    open: bool = false,

    pub fn select(self: *Dropdown, i: usize) bool {
        if (i >= self.options.len) return false;
        self.selected = i;
        self.open = false;
        return true;
    }

    pub fn current(self: *const Dropdown) []const u8 {
        if (self.selected < self.options.len) return self.options[self.selected];
        return "";
    }
};

test "toggle: flip respects enabled" {
    const t = std.testing;
    var g = Toggle{};
    try t.expect(g.flip());
    try t.expect(!g.flip());
    g.enabled = false;
    try t.expect(!g.flip());
    try t.expectEqual(@as(i32, 50), Toggle.knobOffset(100, true));
    try t.expectEqual(@as(i32, 0), Toggle.knobOffset(100, false));
}

test "dropdown: select bounds-checked" {
    const t = std.testing;
    var d = Dropdown{ .options = &[_][]const u8{ "a", "b", "c" }, .open = true };
    try t.expect(d.select(2));
    try t.expectEqualStrings("c", d.current());
    try t.expect(!d.open);
    try t.expect(!d.select(9));
}
