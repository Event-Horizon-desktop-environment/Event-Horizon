const std = @import("std");
const linux = std.os.linux;
const wire = @import("wire.zig");
const sock = @import("../sock.zig");

const c = @cImport(@cInclude("stdlib.h"));

pub const BusError = error{
    BadAddress,
    UnsupportedTransport,
    ConnectFailed,
    AuthRejected,
    AuthProtocol,
    HelloFailed,
    NoReply,
    RemoteError,
    Timeout,
    Truncated,
    BadName,
    OutOfMemory,
    SendFailed,
    RecvFailed,
};

pub fn checkBusName(name: []const u8) BusError!void {
    if (name.len == 0 or name.len > 255) return BusError.BadName;
    if (std.mem.indexOfScalar(u8, name, '.') == null) return BusError.BadName;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |elem| {
        if (elem.len == 0 or elem.len > 255) return BusError.BadName;
        if (elem[0] >= '0' and elem[0] <= '9') return BusError.BadName;
        for (elem) |ch| {
            const ok = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_';
            if (!ok) return BusError.BadName;
        }
    }
}

pub const BusKind = enum { session, system };

pub fn addressFor(kind: BusKind, session_env: ?[]const u8, system_env: ?[]const u8) ?[]const u8 {
    return switch (kind) {
        .session => session_env orelse "unix:path=/run/user/1000/bus",
        .system => system_env orelse "unix:path=/run/dbus/system_bus_socket",
    };
}

pub const Conn = struct {
    alloc: std.mem.Allocator,
    fd: i32 = -1,
    next_serial: u32 = 1,
    unique_name: []u8 = &[_]u8{},
    rbuf: std.ArrayList(u8),
    /// Messages that arrived while a blocking `call` was waiting for *its*
    /// reply. Dropping them would lose the signals that tell the tray which
    /// items exist, so they are parked here and handed out by `recvNow`.
    pending: std.ArrayList(wire.Parsed),

    pub fn init(alloc: std.mem.Allocator) Conn {
        return .{ .alloc = alloc, .rbuf = .empty, .pending = .empty };
    }

    pub fn deinit(self: *Conn) void {
        if (self.fd >= 0) {
            sock.closeFd(self.fd);
            self.fd = -1;
        }
        if (self.unique_name.len > 0) self.alloc.free(self.unique_name);
        for (self.pending.items) |*p| p.deinit();
        self.pending.deinit(self.alloc);
        self.rbuf.deinit(self.alloc);
    }

    /// Park a message that is not the reply a `call` is waiting for, so the
    /// next `recvNow` still delivers it.
    fn stash(self: *Conn, p: wire.Parsed) void {
        // Bounded: a wedged consumer must not grow without limit.
        if (self.pending.items.len >= 512) {
            var oldest = self.pending.orderedRemove(0);
            oldest.deinit();
        }
        self.pending.append(self.alloc, p) catch {
            var dropped = p;
            dropped.deinit();
        };
    }

    pub fn connect(self: *Conn, address: []const u8) BusError!void {
        const path = parseUnixAddress(address) orelse return BusError.BadAddress;
        const fd = sock.createStream(false) catch return BusError.ConnectFailed;
        errdefer sock.closeFd(fd);
        if (sock.connectPath(fd, path) != null) return BusError.ConnectFailed;
        self.fd = fd;
        try self.auth();
    }

    fn sendRaw(self: *Conn, data: []const u8) BusError!void {
        sock.sendAll(self.fd, data) catch return BusError.SendFailed;
    }

    fn readLine(self: *Conn, buf: []u8) BusError![]u8 {
        var total: usize = 0;
        while (total < buf.len) {
            const n: usize = linux.read(self.fd, buf[total..].ptr, 1);
            const s: isize = @bitCast(n);
            if (s < 0) {
                const e = linux.errno(n);
                if (e == .INTR) continue;
                return BusError.RecvFailed;
            }
            if (s == 0) return BusError.Truncated;
            total += 1;
            if (total >= 2 and buf[total - 2] == '\r' and buf[total - 1] == '\n') {
                return buf[0 .. total - 2];
            }
        }
        return BusError.AuthProtocol;
    }

    fn auth(self: *Conn) BusError!void {
        const uid = linux.getuid();
        var uid_buf: [32]u8 = undefined;
        const uid_str = std.fmt.bufPrint(&uid_buf, "{d}", .{uid}) catch return BusError.AuthRejected;
        var hex: [64]u8 = undefined;
        const digits = "0123456789abcdef";
        for (uid_str, 0..) |ch, i| {
            hex[2 * i] = digits[ch >> 4];
            hex[2 * i + 1] = digits[ch & 0x0F];
        }
        try self.sendRaw("\x00");
        var cmd: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&cmd, "AUTH EXTERNAL {s}\r\n", .{hex[0 .. uid_str.len * 2]}) catch return BusError.AuthRejected;
        try self.sendRaw(line);
        var reply: [256]u8 = undefined;
        const ans = try self.readLine(&reply);
        if (!std.mem.startsWith(u8, ans, "OK ")) return BusError.AuthRejected;
        try self.sendRaw("BEGIN\r\n");
    }

    pub fn sendMessage(self: *Conn, msg: wire.Message) BusError!u32 {
        const serial = self.next_serial;
        self.next_serial += 1;
        var m = msg;
        m.serial = serial;
        const bytes = wire.marshal(self.alloc, m) catch return BusError.SendFailed;
        defer self.alloc.free(bytes);
        try self.sendRaw(bytes);
        return serial;
    }

    /// Removes and returns one complete message from the read buffer, or
    /// `null` when the buffer does not yet hold a whole one. Unmarshal copies
    /// every string into its own arena, so shifting the buffer afterwards
    /// cannot invalidate the result.
    fn takeMessage(self: *Conn) BusError!?wire.Parsed {
        if (self.rbuf.items.len < 16) return null;
        const body_len = std.mem.readInt(u32, self.rbuf.items[4..8], .little);
        const flen = std.mem.readInt(u32, self.rbuf.items[12..16], .little);
        const hpad = (8 - ((16 + flen) % 8)) % 8;
        const total = 16 + flen + hpad + body_len;
        if (total > wire.max_message) return BusError.RecvFailed;
        if (self.rbuf.items.len < total) return null;
        const parsed = wire.unmarshal(self.alloc, self.rbuf.items[0..total]) catch return BusError.RecvFailed;
        std.mem.copyForwards(u8, self.rbuf.items[0 .. self.rbuf.items.len - total], self.rbuf.items[total..]);
        self.rbuf.items.len -= total;
        return parsed;
    }

    /// Drains the socket without ever blocking the caller: the wayland loop
    /// watches `fd` and calls this to pull out every message that already
    /// arrived. Returns `null` once nothing complete is left.
    ///
    /// Unlike `recvMessage` this never waits for a partial message to finish
    /// arriving — that is left to the next readable notification.
    pub fn recvNow(self: *Conn) BusError!?wire.Parsed {
        if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
        var spun: u8 = 0;
        while (spun < 256) : (spun += 1) {
            if (try self.takeMessage()) |p| return p;
            var pfd = std.posix.pollfd{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 };
            const r = std.posix.poll((&pfd)[0..1], 0) catch return BusError.RecvFailed;
            if (r == 0) return null;
            if (pfd.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) return BusError.Truncated;
            var chunk: [65536]u8 = undefined;
            const n: usize = linux.read(self.fd, &chunk, chunk.len);
            const s: isize = @bitCast(n);
            if (s < 0) {
                const e = linux.errno(n);
                if (e == .INTR or e == .AGAIN) continue;
                return BusError.RecvFailed;
            }
            if (s == 0) return BusError.Truncated;
            self.rbuf.appendSlice(self.alloc, chunk[0..@intCast(s)]) catch return BusError.OutOfMemory;
        }
        return null;
    }

    pub fn recvMessage(self: *Conn, timeout_ms: i64) BusError!wire.Parsed {
        const deadline = sock.nowMs() + timeout_ms;
        while (true) {
            if (try self.takeMessage()) |p| return p;
            const remaining = deadline - sock.nowMs();
            if (remaining <= 0) return BusError.Timeout;
            var pfd = std.posix.pollfd{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 };
            const ms: i32 = @intCast(@max(0, @min(remaining, std.math.maxInt(i32))));
            const r = std.posix.poll((&pfd)[0..1], ms) catch return BusError.RecvFailed;
            if (r == 0) return BusError.Timeout;
            var chunk: [65536]u8 = undefined;
            const n: usize = linux.read(self.fd, &chunk, chunk.len);
            const s: isize = @bitCast(n);
            if (s < 0) {
                const e = linux.errno(n);
                if (e == .INTR) continue;
                if (e == .AGAIN) continue;
                return BusError.RecvFailed;
            }
            if (s == 0) return BusError.Truncated;
            self.rbuf.appendSlice(self.alloc, chunk[0..@intCast(s)]) catch return BusError.OutOfMemory;
        }
    }

    pub fn hello(self: *Conn) BusError!void {
        const serial = try self.sendMessage(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "Hello",
            .destination = "org.freedesktop.DBus",
        });
        while (true) {
            var p = try self.recvMessage(5000);
            if (p.msg.mtype == .method_return and p.msg.reply_serial == serial) {
                if (p.body_vals.len < 1 or p.body_vals[0] != .string) {
                    p.deinit();
                    return BusError.HelloFailed;
                }
                if (self.unique_name.len > 0) self.alloc.free(self.unique_name);
                self.unique_name = self.alloc.dupe(u8, p.body_vals[0].string) catch {
                    p.deinit();
                    return BusError.OutOfMemory;
                };
                p.deinit();
                return;
            }
            if (p.msg.mtype == .@"error") {
                self.stash(p);
                return BusError.HelloFailed;
            }
            self.stash(p);
        }
    }

    pub fn call(self: *Conn, msg: wire.Message, timeout_ms: i64) BusError!wire.Parsed {
        const serial = try self.sendMessage(msg);
        while (true) {
            var p = try self.recvMessage(timeout_ms);
            if (p.msg.reply_serial) |rs| {
                if (rs == serial) {
                    if (p.msg.mtype == .@"error") {
                        p.deinit();
                        return BusError.RemoteError;
                    }
                    return p;
                }
            }
            // Not ours — a signal or someone else's reply that arrived while
            // we waited. Park it instead of throwing it away.
            self.stash(p);
        }
    }

    pub fn requestName(self: *Conn, name: []const u8, timeout_ms: i64) BusError!u32 {
        try checkBusName(name);
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();
        const body = try aa.alloc(wire.Value, 2);
        body[0] = .{ .string = name };
        body[1] = .{ .uint32 = 0 };
        var p = try self.call(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "RequestName",
            .destination = "org.freedesktop.DBus",
            .signature = "su",
            .body = body,
        }, timeout_ms);
        defer p.deinit();
        if (p.body_vals.len < 1 or p.body_vals[0] != .uint32) return BusError.RemoteError;
        return p.body_vals[0].uint32;
    }

    pub fn pingPeer(self: *Conn, dest: []const u8, path: []const u8, timeout_ms: i64) BusError!void {
        var p = try self.call(.{
            .mtype = .method_call,
            .path = path,
            .interface = "org.freedesktop.DBus.Peer",
            .member = "Ping",
            .destination = dest,
        }, timeout_ms);
        defer p.deinit();
    }

    pub fn addMatch(self: *Conn, rule: []const u8, timeout_ms: i64) BusError!void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();
        const body = try aa.alloc(wire.Value, 1);
        body[0] = .{ .string = rule };
        var p = try self.call(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "AddMatch",
            .destination = "org.freedesktop.DBus",
            .signature = "s",
            .body = body,
        }, timeout_ms);
        defer p.deinit();
    }
};

pub fn parseUnixAddress(address: []const u8) ?[]const u8 {
    var rest = address;
    if (std.mem.startsWith(u8, rest, "unix:")) rest = rest[5..];
    var it = std.mem.splitScalar(u8, rest, ',');
    while (it.next()) |part| {
        if (std.mem.startsWith(u8, part, "path=")) return part[5..];
        if (std.mem.startsWith(u8, part, "abstract=")) return null;
    }
    return null;
}

fn getenvDup(alloc: std.mem.Allocator, key: [:0]const u8) ?[]u8 {
    const p = c.getenv(key);
    if (p == null) return null;
    return alloc.dupe(u8, std.mem.span(p)) catch null;
}

test "dbus-conn: address parsing" {
    const t = std.testing;
    try t.expectEqualStrings("/run/user/1000/bus", parseUnixAddress("unix:path=/run/user/1000/bus,guid=abc").?);
    try t.expectEqualStrings("/tmp/x.sock", parseUnixAddress("unix:path=/tmp/x.sock").?);
    try t.expect(parseUnixAddress("tcp:host=1.2.3.4,port=1234") == null);
    try t.expect(parseUnixAddress("unix:abstract=/tmp/dbus-xyz") == null);
}

test "dbus-conn: bus name validation" {
    const t = std.testing;
    try checkBusName("org.freedesktop.DBus");
    try checkBusName("org.eventhorizon.zigtest.pid123");
    try t.expectError(BusError.BadName, checkBusName(""));
    try t.expectError(BusError.BadName, checkBusName("nodots"));
    try t.expectError(BusError.BadName, checkBusName("org.123abc"));
    try t.expectError(BusError.BadName, checkBusName("org.bad-char"));
    try t.expectError(BusError.BadName, checkBusName("org..empty"));
}

test "dbus-conn: hello + ping + requestname on live bus" {
    const t = std.testing;
    const addr = getenvDup(t.allocator, "DBUS_SESSION_BUS_ADDRESS");
    defer if (addr) |a| t.allocator.free(a);
    const address = addr orelse {
        return error.SkipZigTest;
    };
    var conn = Conn.init(t.allocator);
    defer conn.deinit();
    conn.connect(address) catch {
        return error.SkipZigTest;
    };
    try conn.hello();
    try t.expect(conn.unique_name.len > 0);
    try t.expect(std.mem.startsWith(u8, conn.unique_name, ":1."));
    try conn.pingPeer("org.freedesktop.DBus", "/org/freedesktop/DBus", 3000);
    const name = try std.fmt.allocPrint(t.allocator, "org.eventhorizon.zigtest.pid{d}", .{std.os.linux.getpid()});
    defer t.allocator.free(name);
    const rc = try conn.requestName(name, 3000);
    try t.expectEqual(@as(u32, 1), rc);
    try conn.addMatch("type='signal',sender='org.freedesktop.DBus'", 3000);
}
