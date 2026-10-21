//! Audio Center UI preferences — the active page and the three view filters
//! (meters, recording's "all streams", devices' "hardware only").
//!
//! Stored under `[audio_center]` in
//! `~/.config/Event-Horizon/audio-center/audio-center.toml`, written through
//! `section_store` so the file keeps any other key a future version adds and
//! so a half-written file is never visible to a reader.
//!
//! pavucontrol keeps the same handful of view flags in GSettings
//! (`show-volume-meters`, the active tab); this is the native stand-in.

const std = @import("std");
const cfg = @import("../../config.zig");
const section_store = @import("../../config/section_store.zig");

pub const component = "audio-center";
pub const section = "audio_center";

pub const Prefs = struct {
    /// Page index: 0 Playback, 1 Recording, 2 Output, 3 Input, 4 Configuration.
    page: u8 = 0,
    show_meters: bool = true,
    all_streams: bool = false,
    hw_only: bool = false,
};

/// `<settings>/audio-center/audio-center.toml`.
pub fn path(gpa: std.mem.Allocator, xdg_config_home: ?[]const u8, home: ?[]const u8) ![]u8 {
    const settings = try cfg.settingsDir(gpa, xdg_config_home, home);
    defer gpa.free(settings);
    return cfg.componentPath(gpa, settings, component);
}

/// Missing/unreadable file or malformed values leave the defaults in place:
/// a mixer must open even with no config at all.
pub fn load(gpa: std.mem.Allocator, io: std.Io, p: []const u8) Prefs {
    var prefs: Prefs = .{};
    const text = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 20)) catch return prefs;
    defer gpa.free(text);
    var in_section = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const name = std.mem.trim(u8, line, "[] \t");
            in_section = std.mem.eql(u8, name, section);
            continue;
        }
        if (!in_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "page")) {
            prefs.page = std.fmt.parseInt(u8, val, 10) catch prefs.page;
        } else if (std.mem.eql(u8, key, "show_meters")) {
            prefs.show_meters = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "all_streams")) {
            prefs.all_streams = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "hw_only")) {
            prefs.hw_only = std.mem.eql(u8, val, "true");
        }
    }
    return prefs;
}

pub fn save(gpa: std.mem.Allocator, io: std.Io, p: []const u8, prefs: Prefs) void {
    var page_buf: [4]u8 = undefined;
    const page = std.fmt.bufPrint(&page_buf, "{d}", .{prefs.page}) catch "0";
    const entries = [_]section_store.Entry{
        .{ .key = "page", .value = page },
        .{ .key = "show_meters", .value = section_store.boolValue(prefs.show_meters) },
        .{ .key = "all_streams", .value = section_store.boolValue(prefs.all_streams) },
        .{ .key = "hw_only", .value = section_store.boolValue(prefs.hw_only) },
    };
    section_store.save(gpa, io, p, section, &entries) catch |e| {
        std.log.scoped(.audio_center).warn("prefs save failed: {s}", .{@errorName(e)});
    };
}

test "prefs round trip through the section store" {
    const t = std.testing;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/ac.toml", .{&tmp.sub_path});
    defer t.allocator.free(p);
    // An unrelated section in the same file must survive a save.
    try cwd.writeFile(io, .{ .sub_path = p, .data = "[other]\nkeep = 1\n" });

    try section_store.save(t.allocator, io, p, section, &.{
        .{ .key = "page", .value = "3" },
        .{ .key = "show_meters", .value = "false" },
        .{ .key = "all_streams", .value = "true" },
    });
    const got = load(t.allocator, io, p);
    try t.expectEqual(@as(u8, 3), got.page);
    try t.expect(!got.show_meters);
    try t.expect(got.all_streams);
    try t.expect(!got.hw_only);
    // Defaults for a file that is not there at all.
    const none = load(t.allocator, io, ".zig-cache/tmp/prefs-does-not-exist.toml");
    try t.expect(none.show_meters);
    try t.expectEqual(@as(u8, 0), none.page);
}
