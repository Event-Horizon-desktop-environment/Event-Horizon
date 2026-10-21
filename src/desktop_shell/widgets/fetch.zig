const std = @import("std");

pub const Info = struct {
    os: []const u8 = "",
    kernel: []const u8 = "",
    arch: []const u8 = "",
    shell: []const u8 = "",
    de: []const u8 = "",
};

pub fn parseOsRelease(data: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "PRETTY_NAME=")) {
            var v = line["PRETTY_NAME=".len..];
            if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
            return v;
        }
    }
    return null;
}

pub fn uptimeHMS(seconds: u64, buf: []u8) []const u8 {
    const h = seconds / 3600;
    const m = (seconds % 3600) / 60;
    if (h > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m", .{ h, m }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d}m", .{m}) catch buf[0..0];
}

test "fetch: os-release + uptime" {
    const t = std.testing;
    try t.expectEqualStrings("PikaOS Linux", parseOsRelease("NAME=x\nPRETTY_NAME=\"PikaOS Linux\"\n").?);
    try t.expect(parseOsRelease("NAME=x\n") == null);
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("2h 5m", uptimeHMS(7500, &buf));
    try t.expectEqualStrings("3m", uptimeHMS(200, &buf));
}
