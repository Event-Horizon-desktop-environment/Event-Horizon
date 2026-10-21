const std = @import("std");

pub const bing_api = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=en-US";

pub const Image = struct {
    url: []const u8 = "",
    title: []const u8 = "",
    copyright: []const u8 = "",
};

pub fn imageUrl(alloc: std.mem.Allocator, urlbase: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, urlbase, "http")) return alloc.dupe(u8, urlbase);
    return std.fmt.allocPrint(alloc, "https://www.bing.com{s}", .{urlbase});
}

pub fn parseArchive(alloc: std.mem.Allocator, json_text: []const u8) !Image {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    const obj = parsed.value.object.get("images") orelse return error.NoImages;
    if (obj != .array or obj.array.items.len == 0) return error.NoImages;
    const first = obj.array.items[0];
    if (first != .object) return error.NoImages;
    var img = Image{};
    if (first.object.get("urlbase")) |u| {
        if (u == .string) img.url = try alloc.dupe(u8, u.string);
    }
    if (first.object.get("title")) |u| {
        if (u == .string) img.title = try alloc.dupe(u8, u.string);
    }
    if (first.object.get("copyright")) |u| {
        if (u == .string) img.copyright = try alloc.dupe(u8, u.string);
    }
    if (img.url.len > 0) {
        const full = try imageUrl(alloc, img.url);
        alloc.free(img.url);
        img.url = full;
    }
    return img;
}

pub fn freeImage(alloc: std.mem.Allocator, img: *Image) void {
    if (img.url.len > 0) alloc.free(img.url);
    if (img.title.len > 0) alloc.free(img.title);
    if (img.copyright.len > 0) alloc.free(img.copyright);
    img.* = .{};
}

pub fn fetchText(alloc: std.mem.Allocator, io: std.Io, url: []const u8, max_bytes: usize) ![]u8 {
    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    const res = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    });
    if (res.status != .ok) return error.HttpStatus;
    const body = try aw.toOwnedSlice();
    if (body.len > max_bytes) {
        alloc.free(body);
        return error.TooLarge;
    }
    return body;
}

pub fn cachePath(alloc: std.mem.Allocator, xdg_cache: ?[]const u8, home: ?[]const u8) ![]u8 {
    if (xdg_cache) |c| return std.fs.path.join(alloc, &.{ c, "event-horizon", "bingwall", "bing_wallpapers.json" });
    if (home) |h| return std.fs.path.join(alloc, &.{ h, ".cache", "event-horizon", "bingwall", "bing_wallpapers.json" });
    return alloc.dupe(u8, "/tmp/event-horizon-bing.json");
}

test "bing: archive parse" {
    const t = std.testing;
    const doc =
        \\{"images":[{"urlbase":"/th?id=OHR.Test_EN-US123","title":"Test Dunes","copyright":"Someone (c)"}],"tooltips":{}}
    ;
    var img = try parseArchive(t.allocator, doc);
    defer freeImage(t.allocator, &img);
    try t.expectEqualStrings("https://www.bing.com/th?id=OHR.Test_EN-US123", img.url);
    try t.expectEqualStrings("Test Dunes", img.title);
    try t.expect(img.copyright.len > 0);
    try t.expectError(error.NoImages, parseArchive(t.allocator, "{\"images\":[]}"));
}
