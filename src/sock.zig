const std = @import("std");
const linux = std.os.linux;

pub const SockError = error{
    SocketFailed,
    BindFailed,
    ListenFailed,
    AcceptFailed,
    ConnectFailed,
    SendFailed,
    RecvFailed,
    TruncatedControl,
    OutOfMemory,
};

/// `sizeof(sockaddr_un.sun_path)`, which C fixes at 108 on Linux.
pub const sun_path_len = 108;

pub const AddrUn = extern struct {
    family: u16 = linux.AF.UNIX,
    path: [sun_path_len]u8 = [_]u8{0} ** sun_path_len,

    pub fn init(path: []const u8) AddrUn {
        var a = AddrUn{};
        const n = @min(path.len, a.path.len - 1);
        @memcpy(a.path[0..n], path[0..n]);
        return a;
    }
};

pub const SOL_SOCKET: i32 = 1;
pub const SCM_RIGHTS: i32 = 1;

/// A path at least this long cannot be represented in `AddrUn`, and
/// `AddrUn.init` would silently truncate it onto some other socket — so
/// callers that mean *this* path have to reject it first.
pub const max_path: usize = sun_path_len;

const cmsg_align: usize = @sizeOf(usize);

fn cmsgAlignUp(n: usize) usize {
    return (n + cmsg_align - 1) & ~(cmsg_align - 1);
}

fn cmsgSpace(payload: usize) usize {
    return cmsgAlignUp(@sizeOf(linux.cmsghdr)) + cmsgAlignUp(payload);
}

fn cmsgLen(payload: usize) usize {
    return cmsgAlignUp(@sizeOf(linux.cmsghdr)) + payload;
}

fn errIsAgain(e: linux.E) bool {
    return e == .AGAIN;
}

fn check(rc: usize) ?linux.E {
    const e = linux.errno(rc);
    return if (e == .SUCCESS) null else e;
}

fn sleepMs(ms: i32) void {
    const n = std.posix.poll(&[_]std.posix.pollfd{}, ms) catch 0;
    _ = n;
}

pub fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub fn createStream(nonblock: bool) SockError!i32 {
    var flags: u32 = linux.SOCK.STREAM | linux.SOCK.CLOEXEC;
    if (nonblock) flags |= linux.SOCK.NONBLOCK;
    const rc = linux.socket(linux.AF.UNIX, flags, 0);
    if (check(rc)) |_| return error.SocketFailed;
    return @intCast(rc);
}

pub fn bindPath(fd: i32, path: []const u8) SockError!void {
    var addr = AddrUn.init(path);
    const rc = linux.bind(fd, @ptrCast(&addr), @sizeOf(AddrUn));
    if (check(rc)) |_| return error.BindFailed;
}

pub fn listenOn(fd: i32, backlog: u32) SockError!void {
    if (check(linux.listen(fd, backlog))) |_| return error.ListenFailed;
}

pub fn acceptConn(listen_fd: i32) ?i32 {
    var addr: AddrUn = .{};
    var len: linux.socklen_t = @sizeOf(AddrUn);
    const flags: u32 = linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK;
    const rc = linux.accept4(listen_fd, @ptrCast(&addr), &len, flags);
    if (check(rc)) |_| return null;
    return @intCast(rc);
}

pub fn connectPath(fd: i32, path: []const u8) ?linux.E {
    var addr = AddrUn.init(path);
    const rc = linux.connect(fd, @ptrCast(&addr), @sizeOf(AddrUn));
    return check(rc);
}

pub fn closeFd(fd: i32) void {
    _ = linux.close(fd);
}

/// Flips `O_NONBLOCK` on without disturbing the other status flags. A caller
/// that gets the flag word wrong either blocks its event loop or silently
/// disables close-on-exec, so it lives in one place.
pub fn setNonblock(fd: i32) void {
    const fl: usize = linux.fcntl(fd, linux.F.GETFL, 0);
    if (@as(isize, @bitCast(fl)) < 0) return;
    const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    _ = linux.fcntl(fd, linux.F.SETFL, fl | nonblock);
}

pub fn sendAll(fd: i32, data: []const u8) SockError!void {
    var off: usize = 0;
    var spins: u32 = 0;
    while (off < data.len) {
        const rc = linux.sendto(fd, data[off..].ptr, data.len - off, linux.MSG.NOSIGNAL, null, 0);
        if (check(rc)) |e| {
            if (errIsAgain(e)) {
                spins += 1;
                if (spins > 5000) return error.SendFailed;
                sleepMs(1);
                continue;
            }
            if (e == .INTR) continue;
            return error.SendFailed;
        } else {
            const n: usize = @intCast(rc);
            if (n == 0) return error.SendFailed;
            off += n;
            spins = 0;
        }
    }
}

pub const RecvOut = struct {
    nbytes: usize,
    eof: bool,
    truncated: bool,
};

pub fn recvWithFds(fd: i32, buf: []u8, fds: *std.ArrayList(i32), alloc: std.mem.Allocator) SockError!RecvOut {
    var iov = std.posix.iovec{ .base = buf.ptr, .len = buf.len };
    var cbuf: [cmsgSpace(16 * @sizeOf(i32))]u8 align(@sizeOf(usize)) = undefined;
    var hdr = linux.msghdr{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = @ptrCast(&cbuf),
        .controllen = cbuf.len,
        .flags = 0,
    };
    const rc = linux.recvmsg(fd, &hdr, linux.MSG.DONTWAIT);
    if (check(rc)) |e| {
        if (errIsAgain(e)) return .{ .nbytes = 0, .eof = false, .truncated = false };
        if (e == .INTR) return .{ .nbytes = 0, .eof = false, .truncated = false };
        return error.RecvFailed;
    }
    const n: usize = @intCast(rc);
    if (n == 0) return .{ .nbytes = 0, .eof = true, .truncated = false };
    if ((hdr.flags & linux.MSG.CTRUNC) != 0) {
        return .{ .nbytes = n, .eof = false, .truncated = true };
    }
    var off: usize = 0;
    while (off + @sizeOf(linux.cmsghdr) <= hdr.controllen) {
        const cmsg: *align(1) linux.cmsghdr = @ptrCast(@alignCast(cbuf[off..].ptr));
        if (cmsg.len < @sizeOf(linux.cmsghdr)) break;
        if (cmsg.level == SOL_SOCKET and cmsg.type == SCM_RIGHTS) {
            const data_off = off + cmsgAlignUp(@sizeOf(linux.cmsghdr));
            const payload = cmsg.len - cmsgAlignUp(@sizeOf(linux.cmsghdr));
            const count = payload / @sizeOf(i32);
            var k: usize = 0;
            while (k < count) : (k += 1) {
                const p: *align(1) i32 = @ptrCast(@alignCast(cbuf[data_off + k * 4 ..].ptr));
                fds.append(alloc, p.*) catch return error.OutOfMemory;
            }
        }
        const next = off + cmsgAlignUp(cmsg.len);
        if (next <= off) break;
        off = next;
    }
    return .{ .nbytes = n, .eof = false, .truncated = false };
}

pub fn sendWithFds(fd: i32, data: []const u8, fds: []const i32, first: bool) SockError!usize {
    var iov = std.posix.iovec_const{ .base = data.ptr, .len = data.len };
    var hdr = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    var cbuf: [cmsgSpace(16 * @sizeOf(i32))]u8 align(@sizeOf(usize)) = undefined;
    if (first and fds.len > 0) {
        if (fds.len > 16) return error.SendFailed;
        hdr.control = @ptrCast(&cbuf);
        hdr.controllen = cmsgSpace(fds.len * @sizeOf(i32));
        const cmsg: *align(1) linux.cmsghdr = @ptrCast(@alignCast(&cbuf));
        cmsg.len = cmsgLen(fds.len * @sizeOf(i32));
        cmsg.level = SOL_SOCKET;
        cmsg.type = SCM_RIGHTS;
        const data_off = cmsgAlignUp(@sizeOf(linux.cmsghdr));
        for (fds, 0..) |f, k| {
            const p: *align(1) i32 = @ptrCast(@alignCast(cbuf[data_off + k * 4 ..].ptr));
            p.* = f;
        }
    }
    const rc = linux.sendmsg(fd, &hdr, linux.MSG.NOSIGNAL);
    if (check(rc)) |e| {
        if (errIsAgain(e) or e == .INTR) return 0;
        return error.SendFailed;
    }
    return @intCast(rc);
}

pub fn peekByte(fd: i32) ?u8 {
    var b: [1]u8 = .{0};
    const rc = linux.recvfrom(fd, &b, 1, linux.MSG.PEEK | linux.MSG.DONTWAIT, null, null);
    if (check(rc)) |_| return null;
    if (rc != 1) return null;
    return b[0];
}

test "sock: cmsg sizes match kernel macros" {
    const t = std.testing;
    try t.expectEqual(cmsgAlignUp(@sizeOf(linux.cmsghdr)) + cmsgAlignUp(4), cmsgSpace(4));
    try t.expect(cmsgSpace(64) >= cmsgLen(64));
}

test "sock: socketpair send/recv with fd passing" {
    const t = std.testing;
    var pair: [2]i32 = .{ -1, -1 };
    {
        const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair);
        try t.expect(check(rc) == null);
    }
    defer closeFd(pair[0]);
    defer closeFd(pair[1]);

    var pfds: [2]i32 = .{ -1, -1 };
    try t.expect(linux.pipe(&pfds) == 0);
    defer closeFd(pfds[0]);

    const n = try sendWithFds(pair[0], "hi", pfds[1..2], true);
    try t.expectEqual(@as(usize, 2), n);
    closeFd(pfds[1]);

    var buf: [16]u8 = undefined;
    var got_fds: std.ArrayList(i32) = .empty;
    defer {
        for (got_fds.items) |f| closeFd(f);
        got_fds.deinit(t.allocator);
    }
    const r = try recvWithFds(pair[1], &buf, &got_fds, t.allocator);
    try t.expectEqual(@as(usize, 2), r.nbytes);
    try t.expectEqualStrings("hi", buf[0..2]);
    try t.expectEqual(@as(usize, 1), got_fds.items.len);
}
