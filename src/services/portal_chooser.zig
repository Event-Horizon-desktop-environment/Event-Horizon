const std = @import("std");

pub const Choice = struct {
    path: []const u8,
    uri: []const u8,
};

pub fn fileUri(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "file://{s}", .{path});
}

pub fn requestToken() u32 {
    return 1;
}

pub const Request = struct {
    handle: []const u8 = "",
    done: bool = false,
    uris: u32 = 0,

    pub fn complete(self: *Request) void {
        self.done = true;
    }
};

test "portal-chooser: uri + request" {
    const t = std.testing;
    const u = try fileUri(t.allocator, "/tmp/a.txt");
    defer t.allocator.free(u);
    try t.expectEqualStrings("file:///tmp/a.txt", u);
    var r = Request{};
    try t.expect(!r.done);
    r.complete();
    try t.expect(r.done);
    _ = requestToken();
}
