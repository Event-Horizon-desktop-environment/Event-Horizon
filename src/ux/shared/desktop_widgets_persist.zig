const std = @import("std");
const cfg = @import("../../config.zig");
const toml = @import("../../config/toml.zig");

// Shell-side view of the `[desktop_widgets]` section in
// `~/.config/Event-Horizon/desktop_widgets/desktop_widgets.toml`.
// The desktop process has no settings `Settings` state: it reads the
// output name and the disabled widget-slot list straight from the toml.
// (The settings app's own save/load round trip lives in
// `ux/settings2/desktop_widgets_persist.zig`.)

pub const component = "desktop_widgets";
pub const section = "desktop_widgets";

fn str(v: ?toml.Value, alloc: std.mem.Allocator) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| alloc.dupe(u8, s) catch null,
        else => null,
    };
}

fn strList(v: ?toml.Value, alloc: std.mem.Allocator) ?[][]const u8 {
    const val = v orelse return null;
    const arr = switch (val) {
        .array => |a| a,
        else => return null,
    };
    const out = alloc.alloc([]const u8, arr.len) catch return null;
    for (arr, 0..) |item, i| {
        out[i] = switch (item) {
            .string => |s| alloc.dupe(u8, s) catch "",
            else => "",
        };
    }
    return out;
}

pub const ShellSlots = struct {
    output_name: []const u8 = "",
    disabled: [][]const u8 = &.{},
};

pub fn loadShellSlots(alloc: std.mem.Allocator, io: std.Io, state_dir: []const u8) ShellSlots {
    const path = cfg.componentPath(alloc, state_dir, component) catch return .{};
    defer alloc.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return .{};
    defer alloc.free(text);
    var doc = toml.parse(alloc, text) catch return .{};
    defer doc.deinit();
    const tbl = doc.table(section) orelse return .{};
    const t = tbl.table;
    var out = ShellSlots{};
    if (str(t.get("output_name"), alloc)) |name| out.output_name = name;
    if (strList(t.get("disabled_slots"), alloc)) |ids| out.disabled = ids;
    return out;
}

test "shared-desktop-widgets-persist: shell slots read the toml" {
    const t = std.testing;
    const alloc = t.allocator;
    const text =
        \\[desktop_widgets]
        \\output_name = 'DP-1'
        \\disabled_slots = [ 'clock', 'weather' ]
        \\
    ;
    var parsed = toml.parse(alloc, text) catch unreachable;
    defer parsed.deinit();
    const tbl = parsed.table(section).?;
    const name = str(tbl.table.get("output_name"), alloc).?;
    defer alloc.free(name);
    try t.expectEqualStrings("DP-1", name);
    const ids = strList(tbl.table.get("disabled_slots"), alloc).?;
    defer {
        for (ids) |id| alloc.free(id);
        alloc.free(ids);
    }
    try t.expectEqual(@as(usize, 2), ids.len);
    try t.expectEqualStrings("clock", ids[0]);
    try t.expectEqualStrings("weather", ids[1]);
    // Absent keys stay at the ShellSlots defaults.
    var none = toml.parse(alloc, "[other]\nx = 1\n") catch unreachable;
    defer none.deinit();
    try t.expect(none.table(section) == null);
}
