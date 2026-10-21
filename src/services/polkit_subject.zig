const std = @import("std");

pub const Subject = struct {
    kind: []const u8 = "",
    pid: i32 = 0,
    start_time: u64 = 0,
};

pub fn parseUnixProcess(details: []const u8) ?Subject {
    var it = std.mem.splitScalar(u8, details, ' ');
    var parts: [4][]const u8 = .{ "", "", "", "" };
    var n: usize = 0;
    while (it.next()) |p| {
        if (n >= parts.len) break;
        parts[n] = p;
        n += 1;
    }
    if (n < 2) return null;
    const pid = std.fmt.parseInt(i32, parts[0], 10) catch return null;
    const start: u64 = if (n >= 2) std.fmt.parseInt(u64, parts[1], 10) catch 0 else 0;
    if (pid <= 0) return null;
    return .{ .kind = "unix-process", .pid = pid, .start_time = start };
}

pub fn sameProcess(a: Subject, b: Subject) bool {
    if (!std.mem.eql(u8, a.kind, b.kind)) return false;
    if (a.pid != b.pid) return false;
    if (a.start_time != 0 and b.start_time != 0 and a.start_time != b.start_time) return false;
    return true;
}

test "polkit-subject: parse + pid-reuse guard" {
    const t = std.testing;
    const s = parseUnixProcess("1234 567890").?;
    try t.expectEqual(@as(i32, 1234), s.pid);
    try t.expectEqual(@as(u64, 567890), s.start_time);
    try t.expect(parseUnixProcess("0 1") == null);
    try t.expect(parseUnixProcess("abc") == null);
    const reused = Subject{ .kind = "unix-process", .pid = 1234, .start_time = 999 };
    try t.expect(!sameProcess(s, reused));
    try t.expect(sameProcess(s, .{ .kind = "unix-process", .pid = 1234, .start_time = 567890 }));
}
