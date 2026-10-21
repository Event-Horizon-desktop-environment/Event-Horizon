//! Backlight behind the pear brightness row: cached scan of `/sys/class/backlight`
//! for a node carrying `brightness` + `max_brightness`, writability probed
//! once by opening the current file for append.

const std = @import("std");

/// Parse `"<cur> <max>"` readings into 0..100. -1 when unusable.
pub fn pctFromReadings(cur: []const u8, max: []const u8) i32 {
    const c = parseInt(cur) orelse return -1;
    const m = parseInt(max) orelse return -1;
    if (m <= 0) return -1;
    const v: f64 = @as(f64, @floatFromInt(c)) * 100.0 / @as(f64, @floatFromInt(m));
    return std.math.clamp(@as(i32, @intFromFloat(@round(v))), 0, 100);
}

fn parseInt(s: []const u8) ?i64 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return null;
    return std.fmt.parseInt(i64, t, 10) catch null;
}

/// sysfs write value for `pct` (0..100) against a `max_brightness` of `mx`.
pub fn writeValueFor(pct: i32, mx: i64) ?i64 {
    if (mx <= 0) return null;
    const p = std.math.clamp(pct, 0, 100);
    return @divTrunc(@as(i64, p) * mx, 100);
}

// sysfs backend (cached by the caller)

pub const Backlight = struct {
    /// `<node>/brightness` + `<node>/max_brightness` node paths, empty when
    /// no backlight node exists.
    cur_path: []const u8 = "",
    max_path: []const u8 = "",
    writable: bool = false,
    scanned: bool = false,

    pub fn available(self: *const Backlight) bool {
        return self.cur_path.len > 0;
    }

    pub fn deinit(self: *Backlight, alloc: std.mem.Allocator) void {
        if (self.cur_path.len > 0) alloc.free(self.cur_path);
        if (self.max_path.len > 0) alloc.free(self.max_path);
        self.* = .{};
    }

    /// One cached scan of `/sys/class/backlight` for the first node with
    /// both files (writability probed by opening `brightness` for append,
    /// mirroring the slider behaviour).
    pub fn scan(self: *Backlight, alloc: std.mem.Allocator, io: std.Io) void {
        if (self.scanned) return;
        self.scanned = true;
        var dir = std.Io.Dir.openDirAbsolute(io, "/sys/class/backlight", .{ .iterate = true }) catch return;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .directory) continue;
            const cur = std.fs.path.join(alloc, &.{ "/sys/class/backlight", e.name, "brightness" }) catch continue;
            errdefer alloc.free(cur);
            const max = std.fs.path.join(alloc, &.{ "/sys/class/backlight", e.name, "max_brightness" }) catch {
                alloc.free(cur);
                continue;
            };
            errdefer alloc.free(max);
            const cwd = std.Io.Dir.cwd();
            const cdata = cwd.readFileAlloc(io, cur, alloc, .limited(64)) catch {
                alloc.free(cur);
                alloc.free(max);
                continue;
            };
            alloc.free(cdata);
            const mdata = cwd.readFileAlloc(io, max, alloc, .limited(64)) catch {
                alloc.free(cur);
                alloc.free(max);
                continue;
            };
            alloc.free(mdata);
            self.cur_path = cur;
            self.max_path = max;
            // Writability probe: open without truncate (an append-mode
            // open). truncate=true here would zero the
            // brightness — never set it on this path.
            if (cwd.createFile(io, cur, .{ .truncate = false })) |file| {
                file.close(io);
                self.writable = true;
            } else |_| {}
            return;
        }
    }

    /// Current brightness 0..100, or -1 when unavailable.
    pub fn pct(self: *Backlight, alloc: std.mem.Allocator, io: std.Io) i32 {
        if (!self.available()) return -1;
        const cwd = std.Io.Dir.cwd();
        const cdata = cwd.readFileAlloc(io, self.cur_path, alloc, .limited(64)) catch return -1;
        defer alloc.free(cdata);
        const mdata = cwd.readFileAlloc(io, self.max_path, alloc, .limited(64)) catch return -1;
        defer alloc.free(mdata);
        return pctFromReadings(cdata, mdata);
    }

    /// Best-effort sysfs write. False on desktop rigs without a writable
    /// node (the row then hides — `showBrightness` requires availability,
    /// writability only gates the write path).
    pub fn setPct(self: *Backlight, alloc: std.mem.Allocator, io: std.Io, level: i32) bool {
        if (!self.available() or !self.writable) return false;
        const cwd = std.Io.Dir.cwd();
        const mdata = cwd.readFileAlloc(io, self.max_path, alloc, .limited(64)) catch return false;
        defer alloc.free(mdata);
        const mx = parseInt(mdata) orelse return false;
        const v = writeValueFor(level, mx) orelse return false;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return false;
        cwd.writeFile(io, .{ .sub_path = self.cur_path, .data = text }) catch return false;
        return true;
    }
};

test "pear-brightness: readings to percent" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 50), pctFromReadings("500\n", "1000\n"));
    try t.expectEqual(@as(i32, 100), pctFromReadings("1000", "1000"));
    try t.expectEqual(@as(i32, 0), pctFromReadings("0", "1000"));
    try t.expectEqual(@as(i32, -1), pctFromReadings("", "1000"));
    try t.expectEqual(@as(i32, -1), pctFromReadings("500", "0"));
    try t.expectEqual(@as(i32, -1), pctFromReadings("garbage", "1000"));
}

test "pear-brightness: write values scale to max" {
    const t = std.testing;
    try t.expectEqual(@as(?i64, 500), writeValueFor(50, 1000));
    try t.expectEqual(@as(?i64, 1000), writeValueFor(150, 1000));
    try t.expectEqual(@as(?i64, 0), writeValueFor(-5, 1000));
    try t.expect(writeValueFor(50, 0) == null);
}
