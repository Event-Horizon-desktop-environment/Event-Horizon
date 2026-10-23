//! Per-component file logging at `$HOME/EH-logs/<tag>.log`.
//!
//! Logging through one file
//! per tag under `$HOME/EH-logs` and prefixes every line with a local
//! timestamp and a `name:pid`. The Zig binaries used to print to stderr only,
//! which means their output evaporated the moment a launcher redirected or
//! discarded it — so "clicking the dock does nothing" was undiagnosable.
//!
//! This keeps one shared log format so both languages land in one greppable place:
//!
//!     [2026-10-07 11:59:02.123] [horizon-dock-zig:40122] [pointer] enter x=12.0 y=44.0
//!
//! Writes are a single `write(2)` per line with `O_APPEND`, so the logger is
//! safe from a signal handler and never needs the `std.Io` handle after
//! `init`.

const std = @import("std");
const linux = std.os.linux;

/// Longest single line; anything longer is dropped rather than split, because
/// a half-written line wrecks greppability.
const kMaxLine = 4096;
const kMaxMsg = 3072;
/// Log rotation at 64 MiB to `<file>.old`; matching so neither side
/// can grow an unbounded file.
const kRotate: u64 = 64 * 1024 * 1024;

var g_fd: i32 = -1;
var g_tag: []const u8 = "zig";
var g_proc: [160]u8 = undefined;
var g_proc_len: usize = 0;
var g_stamp: [23]u8 = undefined;

/// Opens `<home>/EH-logs/<tag>.log`. Calling it twice with the same tag is a
/// no-op; with a different tag it switches over, so a test can repoint the
/// logger without leaking a descriptor.
pub fn init(io: std.Io, home: ?[]const u8, tag: []const u8) void {
    if (g_fd >= 0 and std.mem.eql(u8, g_tag, tag)) return;
    if (g_fd >= 0) {
        _ = linux.close(g_fd);
        g_fd = -1;
    }
    g_tag = tag;

    if (std.fmt.bufPrint(&g_proc, "{s}:{d}", .{ tag, linux.getpid() })) |p| {
        g_proc_len = p.len;
    } else |_| {
        g_proc_len = 0;
    }

    var pathbuf: [1024]u8 = undefined;
    const path = buildPath(home, tag, &pathbuf) orelse return;
    const cwd = std.Io.Dir.cwd();

    // `EH-logs` is created on first use, under `eh_log::dir()`'s path.
    if (std.fs.path.dirname(path)) |d| cwd.createDirPath(io, d) catch {};

    // Rotate instead of truncating: a full log is usually the one you want.
    if (cwd.statFile(io, path, .{})) |st| {
        if (st.size > kRotate) {
            var oldbuf: [1100]u8 = undefined;
            if (std.fmt.bufPrint(&oldbuf, "{s}.old", .{path})) |old| {
                cwd.rename(path, cwd, old, io) catch {};
            } else |_| {}
        }
    } else |_| {}

    var z: [1060:0]u8 = @as([1060:0]u8, @splat(0));
    if (path.len + 1 > z.len) return;
    @memcpy(z[0..path.len], path);
    const rc = linux.open(&z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return;
    g_fd = @intCast(rc);
}

pub fn deinit() void {
    if (g_fd >= 0) {
        _ = linux.close(g_fd);
        g_fd = -1;
    }
}

pub fn isOpen() bool {
    return g_fd >= 0;
}

/// The `name:pid` this process writes its lines under, for callers that want
/// to log it as data rather than as the prefix.
pub fn proc() []const u8 {
    return g_proc[0..g_proc_len];
}

/// File only — the quiet path, used for anything that fires per frame or per
/// pointer motion.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (g_fd < 0) return;
    var msg: [kMaxMsg]u8 = undefined;
    const m = std.fmt.bufPrint(&msg, fmt, args) catch return;
    writeLine(m);
}

/// File *and* stderr, for the errors a developer watching a terminal wants to
/// see immediately.
pub fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
    if (g_fd < 0) return;
    var msg: [kMaxMsg]u8 = undefined;
    const m = std.fmt.bufPrint(&msg, fmt, args) catch return;
    writeLine(m);
}

fn writeLine(msg: []const u8) void {
    var line: [kMaxLine]u8 = undefined;
    const out = std.fmt.bufPrint(
        &line,
        "[{s}] [{s}] [{s}] {s}\n",
        .{ stamp(), g_proc[0..g_proc_len], g_tag, msg },
    ) catch return;
    var off: usize = 0;
    while (off < out.len) {
        const n = linux.write(g_fd, out[off..].ptr, out.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        off += n;
    }
}

/// `YYYY-MM-DD HH:MM:SS.mmm` in local time, in a static buffer — the process
/// is single threaded, and a log line never outlives its own `write`. The
/// millisecond field is what makes startup-phase deltas readable.
fn stamp() []const u8 {
    var tv: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.REALTIME, &tv);
    var t: i64 = @intCast(tv.sec);
    var tm: CTm = undefined;
    if (localtime_r(&t, &tm) == null) {
        @memcpy(g_stamp[0..23], "1970-01-01 00:00:00.000");
        return &g_stamp;
    }
    putFixed(g_stamp[0..4], @intCast(1900 + tm.tm_year), 4);
    g_stamp[4] = '-';
    putFixed(g_stamp[5..7], tm.tm_mon + 1, 2);
    g_stamp[7] = '-';
    putFixed(g_stamp[8..10], tm.tm_mday, 2);
    g_stamp[10] = ' ';
    putFixed(g_stamp[11..13], @intCast(@mod(tm.tm_hour, 24)), 2);
    g_stamp[13] = ':';
    putFixed(g_stamp[14..16], tm.tm_min, 2);
    g_stamp[16] = ':';
    putFixed(g_stamp[17..19], tm.tm_sec, 2);
    g_stamp[19] = '.';
    putFixed(g_stamp[20..23], @intCast(@divTrunc(@max(tv.nsec, 0), 1_000_000)), 3);
    return &g_stamp;
}

/// Zero-padded, fixed-width integer. `{d:0>2}` no longer exists in Zig 0.16
/// and `bufPrint` per field would mean nine formats per line.
fn putFixed(dst: []u8, v: i32, digits: usize) void {
    var x: i32 = if (v < 0) 0 else v;
    var n: usize = @min(digits, dst.len);
    while (n > 0) : (n -= 1) {
        dst[n - 1] = @intCast(@rem(x, 10) + '0');
        x = @divTrunc(x, 10);
    }
}

/// `<home>/EH-logs/<tag>.log`, with the tag restricted to characters that are
/// safe in a filename (a tag is also a directory entry, not just a label).
fn buildPath(home: ?[]const u8, tag: []const u8, buf: []u8) ?[]const u8 {
    const root = home orelse "/tmp";
    const suffix = "/EH-logs/".len + ".log".len;
    if (root.len + suffix + tag.len > buf.len) return null;
    var off: usize = 0;
    @memcpy(buf[off..][0..root.len], root);
    off += root.len;
    @memcpy(buf[off..][0.."/EH-logs/".len], "/EH-logs/");
    off += "/EH-logs/".len;
    for (tag, 0..) |ch, i| {
        buf[off + i] = switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => ch,
            else => '_',
        };
    }
    off += tag.len;
    @memcpy(buf[off..][0..".log".len], ".log");
    off += ".log".len;
    return buf[0..off];
}

const CTm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: [*:0]const u8,
};

extern fn localtime_r(t: [*c]const i64, out: *CTm) ?*CTm;

test "logz: path is $HOME/EH-logs/<tag>.log" {
    const t = std.testing;
    var buf: [512]u8 = undefined;
    const p = buildPath("/home/matt", "horizon-dock-zig", &buf).?;
    try t.expectEqualStrings("/home/matt/EH-logs/horizon-dock-zig.log", p);
}

test "logz: a tag that would escape the log dir cannot" {
    const t = std.testing;
    var buf: [512]u8 = undefined;
    const p = buildPath("/h", "../../etc/passwd", &buf).?;
    try t.expectEqualStrings("/h/EH-logs/.._.._etc_passwd.log", p);
}

test "logz: a missing HOME falls back to /tmp" {
    const t = std.testing;
    var buf: [512]u8 = undefined;
    const p = buildPath(null, "x", &buf).?;
    try t.expectEqualStrings("/tmp/EH-logs/x.log", p);
}

test "logz: fixed-width stamps" {
    const t = std.testing;
    var dst: [4]u8 = undefined;
    putFixed(&dst, 7, 4);
    try t.expectEqualStrings("0007", &dst);
    putFixed(&dst, 2026, 4);
    try t.expectEqualStrings("2026", &dst);
    var d2: [2]u8 = undefined;
    putFixed(&d2, 5, 2);
    try t.expectEqualStrings("05", &d2);
    putFixed(&d2, 60, 2);
    try t.expectEqualStrings("60", &d2);
}

test "logz: init opens a real file and writes a line" {
    const t = std.testing;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var homebuf: [256]u8 = undefined;
    const home = try std.fmt.bufPrint(&homebuf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    init(io, home, "unit-test-zig");
    try t.expect(isOpen());
    try t.expectEqualStrings("unit-test-zig", proc()[0.."unit-test-zig".len]);
    log("hello {d}", .{42});
    log("second line", .{});
    deinit();
    try t.expect(!isOpen());

    var pathbuf: [300]u8 = undefined;
    const path = try std.fmt.bufPrint(&pathbuf, "{s}/EH-logs/unit-test-zig.log", .{home});
    const data = try cwd.readFileAlloc(io, path, t.allocator, .limited(4096));
    defer t.allocator.free(data);

    // `[tag] pid` prefix, then the message, one line each.
    try t.expect(std.mem.indexOf(u8, data, "] [unit-test-zig:") != null);
    try t.expect(std.mem.indexOf(u8, data, "] [unit-test-zig] hello 42\n") != null);
    try t.expect(std.mem.endsWith(u8, data, "] [unit-test-zig] second line\n"));
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, data, "\n"));
}
