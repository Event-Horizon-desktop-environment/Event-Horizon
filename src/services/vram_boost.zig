const std = @import("std");

pub const DmemRegion = struct {
    start: u64 = 0,
    size: u64 = 0,
};

pub fn normalizeAppId(alloc: std.mem.Allocator, app_id: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (app_id) |ch| try out.append(alloc, std.ascii.toLower(ch));
    var s = out.items;
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |slash| s = s[slash + 1 ..];
    for ([_][]const u8{ ".desktop", ".appimage", ".exe" }) |suffix| {
        while (std.mem.endsWith(u8, s, suffix)) s = s[0 .. s.len - suffix.len];
    }
    const res = try alloc.dupe(u8, s);
    out.deinit(alloc);
    return res;
}

pub fn commMatches(comm: []const u8, normalized_app_id: []const u8, alloc: std.mem.Allocator) !bool {
    const norm_comm = try normalizeAppId(alloc, comm);
    defer alloc.free(norm_comm);
    if (norm_comm.len == 0 or normalized_app_id.len == 0) return false;
    if (std.mem.eql(u8, norm_comm, normalized_app_id)) return true;
    if (norm_comm.len < 3) return false;
    if (normalized_app_id.len < norm_comm.len) return false;
    if (!std.mem.endsWith(u8, normalized_app_id, norm_comm)) return false;
    const at = normalized_app_id.len - norm_comm.len;
    if (at == 0) return true;
    const prev = normalized_app_id[at - 1];
    return !(prev == '_' or (prev >= 'a' and prev <= 'z') or (prev >= '0' and prev <= '9'));
}

pub fn controllersHaveDmem(controllers: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, controllers, " \t\r\n");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "dmem")) return true;
    }
    return false;
}

test "vram: app id normalization is stable" {
    const t = std.testing;
    const n1 = try normalizeAppId(t.allocator, "FireFox");
    defer t.allocator.free(n1);
    try t.expectEqualStrings("firefox", n1);
    const n2 = try normalizeAppId(t.allocator, "/usr/bin/Steam.desktop");
    defer t.allocator.free(n2);
    try t.expectEqualStrings("steam", n2);
    const n3 = try normalizeAppId(t.allocator, "game.AppImage");
    defer t.allocator.free(n3);
    try t.expectEqualStrings("game", n3);
}

test "vram: comm matching boundary rules" {
    const t = std.testing;
    try t.expect(try commMatches("firefox", "firefox", t.allocator));
    try t.expect(try commMatches("firefox", "org.mozilla.firefox", t.allocator));
    try t.expect(!try commMatches("fox", "firefox", t.allocator));
    try t.expect(!try commMatches("firefox", "myfirefox", t.allocator));
    try t.expect(!try commMatches("", "firefox", t.allocator));
}

test "vram: dmem controller detection" {
    const t = std.testing;
    try t.expect(controllersHaveDmem("cpu memory dmem io"));
    try t.expect(!controllersHaveDmem("cpu memory io"));
    try t.expect(!controllersHaveDmem(""));
}
