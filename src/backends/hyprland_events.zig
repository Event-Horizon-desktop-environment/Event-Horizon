const std = @import("std");

pub const Event = union(enum) {
    workspace: []const u8,
    open_window: []const u8,
    close_window: []const u8,
    move_window: []const u8,
    active_window: []const u8,
    fullscreen: bool,
    monitor_added: []const u8,
    unknown: void,
};

pub fn parseEventLine(line: []const u8) Event {
    if (std.mem.indexOfScalar(u8, line, '>')) |sep| {
        const name = line[0..sep];
        const arg = line[sep + 2 ..];
        const arg2 = std.mem.indexOfScalar(u8, arg, ',');
        _ = arg2;
        if (std.mem.eql(u8, name, "workspace")) return .{ .workspace = arg };
        if (std.mem.eql(u8, name, "openwindow")) return .{ .open_window = arg };
        if (std.mem.eql(u8, name, "closewindow")) return .{ .close_window = arg };
        if (std.mem.eql(u8, name, "movewindow")) return .{ .move_window = arg };
        if (std.mem.eql(u8, name, "activewindow")) return .{ .active_window = arg };
        if (std.mem.eql(u8, name, "fullscreen")) return .{ .fullscreen = arg.len > 0 and arg[0] == '1' };
        if (std.mem.eql(u8, name, "monitoradded")) return .{ .monitor_added = arg };
    }
    return .unknown;
}

test "hypr-events: line parse" {
    const t = std.testing;
    const e = parseEventLine("workspace>>1");
    try t.expect(e == .workspace);
    try t.expectEqualStrings("1", e.workspace);
    try t.expect(parseEventLine("foobar") == .unknown);
    try t.expect(parseEventLine("fullscreen>>1").fullscreen);
}
