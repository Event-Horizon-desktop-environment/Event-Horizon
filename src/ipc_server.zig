const std = @import("std");
const linux = std.os.linux;
const ipc = @import("ipc.zig");
const sock = @import("sock.zig");

pub const HandlerFn = *const fn (alloc: std.mem.Allocator, args: []const []const u8) anyerror![]u8;

pub const PollInterest = struct {
    fd: i32,
    events: i16,
};

const QueuedEvent = struct {
    bytes: std.ArrayList(u8),
    fds: std.ArrayList(i32),
    fds_sent: bool = false,

    fn deinit(self: *QueuedEvent, alloc: std.mem.Allocator) void {
        for (self.fds.items) |f| sock.closeFd(f);
        self.fds.deinit(alloc);
        self.bytes.deinit(alloc);
    }
};

const Client = struct {
    fd: i32,
    rbuf: std.ArrayList(u8),
    out: std.ArrayList(QueuedEvent),
    want_poll_out: bool = false,

    fn deinit(self: *Client, alloc: std.mem.Allocator) void {
        for (self.out.items) |*q| q.deinit(alloc);
        self.out.deinit(alloc);
        self.rbuf.deinit(alloc);
    }
};

const PendingFd = struct {
    fd: i32,
    since_ms: i64,
};

pub const Service = struct {
    alloc: std.mem.Allocator,
    listen_fd: i32 = -1,
    socket_path: []u8 = &[_]u8{},
    handlers: std.StringHashMap(HandlerFn),
    clients: std.ArrayList(Client),
    pending: std.ArrayList(PendingFd),
    subscriptions: std.StringHashMap(std.ArrayList(i32)),

    pub fn init(alloc: std.mem.Allocator) Service {
        return .{
            .alloc = alloc,
            .handlers = std.StringHashMap(HandlerFn).init(alloc),
            .clients = .empty,
            .pending = .empty,
            .subscriptions = std.StringHashMap(std.ArrayList(i32)).init(alloc),
        };
    }

    pub fn deinit(self: *Service) void {
        self.stop();
        self.clients.deinit(self.alloc);
        self.pending.deinit(self.alloc);
        self.handlers.deinit();
        var sub_it = self.subscriptions.iterator();
        while (sub_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            e.value_ptr.deinit(self.alloc);
        }
        self.subscriptions.deinit();
    }

    pub fn defaultSocketPath(alloc: std.mem.Allocator, eh_ipc_socket: ?[]const u8, xdg_runtime: ?[]const u8) ![]u8 {
        if (eh_ipc_socket) |p| return alloc.dupe(u8, p);
        if (xdg_runtime) |d| {
            const dir = try std.fs.path.join(alloc, &.{ d, "event-horizon-ipc.sock" });
            return dir;
        }
        return alloc.dupe(u8, "/tmp/event-horizon-ipc.sock");
    }

    pub fn start(self: *Service, path: []const u8) !void {
        if (self.listen_fd >= 0) self.stop();
        self.socket_path = try self.alloc.dupe(u8, path);
        errdefer {
            self.alloc.free(self.socket_path);
            self.socket_path = &[_]u8{};
        }
        const zpath = try self.alloc.dupeSentinel(u8, path, 0);
        defer self.alloc.free(zpath);
        _ = linux.unlink(zpath);

        const fd = try sock.createStream(true);
        errdefer sock.closeFd(fd);
        try sock.bindPath(fd, path);
        _ = linux.chmod(zpath, 0o600);
        try sock.listenOn(fd, 8);
        self.listen_fd = fd;
    }

    pub fn stop(self: *Service) void {
        for (self.clients.items) |*c| {
            sock.closeFd(c.fd);
            c.deinit(self.alloc);
        }
        self.clients.clearRetainingCapacity();
        for (self.pending.items) |p| sock.closeFd(p.fd);
        self.pending.clearRetainingCapacity();
        var it = self.subscriptions.iterator();
        while (it.next()) |e| e.value_ptr.clearRetainingCapacity();
        if (self.listen_fd >= 0) {
            sock.closeFd(self.listen_fd);
            self.listen_fd = -1;
        }
        if (self.socket_path.len > 0) {
            const zpath = self.alloc.dupeSentinel(u8, self.socket_path, 0) catch null;
            if (zpath) |z| {
                defer self.alloc.free(z);
                _ = linux.unlink(z);
            }
            self.alloc.free(self.socket_path);
            self.socket_path = &[_]u8{};
        }
    }

    pub fn running(self: *const Service) bool {
        return self.listen_fd >= 0;
    }

    pub fn clientCount(self: *const Service) usize {
        return self.clients.items.len;
    }

    pub fn pumpOnce(self: *Service, timeout_ms: i32) void {
        var interests: std.ArrayList(PollInterest) = .empty;
        defer interests.deinit(self.alloc);
        self.pollInterests(&interests) catch return;
        var pfds: [64]std.posix.pollfd = undefined;
        const m = @min(interests.items.len, pfds.len);
        for (interests.items[0..m], 0..) |pi, k| {
            pfds[k] = .{ .fd = pi.fd, .events = pi.events, .revents = 0 };
        }
        _ = std.posix.poll(pfds[0..m], timeout_ms) catch 0;
        for (interests.items[0..m], 0..) |pi, k| {
            if (pfds[k].revents != 0) self.onFdReady(pi.fd, pfds[k].revents);
        }
    }

    pub fn registerHandler(self: *Service, name: []const u8, h: HandlerFn) !void {
        // NOTE: name must outlive the service (string literals in practice).
        try self.handlers.put(name, h);
    }

    pub fn unregisterHandler(self: *Service, name: []const u8) void {
        _ = self.handlers.remove(name);
    }

    fn findClient(self: *Service, fd: i32) ?*Client {
        for (self.clients.items) |*c| {
            if (c.fd == fd) return c;
        }
        return null;
    }

    fn removeClient(self: *Service, fd: i32) void {
        for (self.clients.items, 0..) |*c, i| {
            if (c.fd == fd) {
                sock.closeFd(c.fd);
                c.deinit(self.alloc);
                _ = self.clients.orderedRemove(i);
                break;
            }
        }
        var it = self.subscriptions.iterator();
        while (it.next()) |e| {
            const v = e.value_ptr;
            for (v.items, 0..) |m, k| {
                if (m == fd) {
                    _ = v.orderedRemove(k);
                    break;
                }
            }
        }
    }

    fn queueBytes(self: *Service, c: *Client, bytes: []const u8, fds: []const i32) !void {
        var q = QueuedEvent{ .bytes = .empty, .fds = .empty };
        errdefer q.deinit(self.alloc);
        try q.bytes.appendSlice(self.alloc, bytes);
        try q.fds.appendSlice(self.alloc, fds);
        try c.out.append(self.alloc, q);
        c.want_poll_out = true;
    }

    pub fn pollInterests(self: *Service, out: *std.ArrayList(PollInterest)) !void {
        out.clearRetainingCapacity();
        if (self.listen_fd >= 0) try out.append(self.alloc, .{ .fd = self.listen_fd, .events = std.posix.POLL.IN });
        for (self.pending.items) |p| try out.append(self.alloc, .{ .fd = p.fd, .events = std.posix.POLL.IN });
        for (self.clients.items) |*c| {
            var ev: i16 = std.posix.POLL.IN;
            if (c.want_poll_out or c.out.items.len > 0) ev |= std.posix.POLL.OUT;
            try out.append(self.alloc, .{ .fd = c.fd, .events = ev });
        }
    }

    pub fn onAccept(self: *Service) void {
        while (sock.acceptConn(self.listen_fd)) |fd| {
            self.pending.append(self.alloc, .{ .fd = fd, .since_ms = sock.nowMs() }) catch {
                sock.closeFd(fd);
                return;
            };
        }
    }

    fn sweepPending(self: *Service) void {
        const now = sock.nowMs();
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (now - self.pending.items[i].since_ms > 10_000) {
                sock.closeFd(self.pending.items[i].fd);
                _ = self.pending.orderedRemove(i);
            } else i += 1;
        }
    }

    pub fn onFdReady(self: *Service, fd: i32, revents: i16) void {
        if (fd == self.listen_fd) {
            self.onAccept();
            return;
        }
        self.sweepPending();

        for (self.pending.items, 0..) |p, i| {
            if (p.fd != fd) continue;
            if ((revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL | std.posix.POLL.HUP)) != 0) {
                sock.closeFd(fd);
                _ = self.pending.orderedRemove(i);
                return;
            }
            const probe = sock.peekByte(fd) orelse return;
            _ = self.pending.orderedRemove(i);
            if (probe == ipc.frame_magic) {
                self.clients.append(self.alloc, .{ .fd = fd, .rbuf = .empty, .out = .empty }) catch {
                    sock.closeFd(fd);
                    return;
                };
            } else {
                self.dispatchLegacy(fd);
            }
            return;
        }

        const c = self.findClient(fd) orelse return;
        var dead = (revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL | std.posix.POLL.HUP)) != 0;
        if (!dead and (revents & std.posix.POLL.IN) != 0) {
            var chunk: [65536]u8 = undefined;
            var tmp_fds: std.ArrayList(i32) = .empty;
            defer {
                for (tmp_fds.items) |f| sock.closeFd(f);
                tmp_fds.deinit(self.alloc);
            }
            const r = sock.recvWithFds(fd, &chunk, &tmp_fds, self.alloc) catch {
                dead = true;
                return;
            };
            if (r.eof or r.truncated) {
                dead = true;
            } else if (r.nbytes > 0) {
                c.rbuf.appendSlice(self.alloc, chunk[0..r.nbytes]) catch {
                    dead = true;
                    return;
                };
            }
            if (!dead) {
                var off: usize = 0;
                while (off < c.rbuf.items.len) {
                    const res = ipc.decodeFrame(self.alloc, c.rbuf.items[off..]) catch |err| {
                        if (err == ipc.DecodeError.NeedMoreData) break;
                        dead = true;
                        break;
                    };
                    self.handleFrame(c, res.frame);
                    self.alloc.free(res.frame.body);
                    off += res.consumed;
                }
                if (off > 0) {
                    std.mem.copyForwards(u8, c.rbuf.items[0 .. c.rbuf.items.len - off], c.rbuf.items[off..]);
                    c.rbuf.items.len -= off;
                }
            }
        }
        if (!dead and (revents & std.posix.POLL.OUT) != 0) {
            if (!self.flushClient(c)) dead = true;
        }
        if (dead) self.removeClient(fd);
    }

    fn dispatchLegacy(self: *Service, fd: i32) void {
        var buf: [ipc.max_legacy_cmd]u8 = undefined;
        const n = linux.read(fd, &buf, buf.len);
        const signed_n: isize = @bitCast(n);
        if (signed_n <= 0) {
            sock.closeFd(fd);
            return;
        }
        const got: usize = @intCast(signed_n);
        var line = buf[0..got];
        if (std.mem.indexOfScalar(u8, line, '\n')) |nl| {
            line = line[0..nl];
        } else if (got == ipc.max_legacy_cmd) {
            sock.sendAll(fd, "error command too long\n") catch {};
            sock.closeFd(fd);
            return;
        }
        const tline = std.mem.trimEnd(u8, line, "\r ");
        const resp = self.processCommand(tline);
        defer self.alloc.free(resp);
        var out_buf: [ipc.max_legacy_cmd + 64]u8 = undefined;
        const out = std.fmt.bufPrint(&out_buf, "{s}\n", .{resp}) catch {
            sock.closeFd(fd);
            return;
        };
        sock.sendAll(fd, out) catch {};
        sock.closeFd(fd);
    }

    fn processCommand(self: *Service, line: []const u8) []u8 {
        if (line.len == 0) return self.alloc.dupe(u8, "error empty command") catch &[_]u8{};
        var toks = std.mem.tokenizeAny(u8, line, " \t\r");
        const cmd = toks.next() orelse return self.alloc.dupe(u8, "error empty command") catch &[_]u8{};
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.alloc);
        while (toks.next()) |a| args.append(self.alloc, a) catch {};
        const h = self.handlers.get(cmd) orelse {
            const msg = std.fmt.allocPrint(self.alloc, "error unknown command: {s}", .{cmd}) catch return &[_]u8{};
            return msg;
        };
        const res = h(self.alloc, args.items) catch |err| {
            const msg = std.fmt.allocPrint(self.alloc, "error ipc handler exception: {s}", .{@errorName(err)}) catch return &[_]u8{};
            return msg;
        };
        return res;
    }

    fn handleFrame(self: *Service, c: *Client, frame: ipc.Frame) void {
        if (frame.header.version != ipc.protocol_version) return;
        const ftype: ipc.FrameType = @enumFromInt(frame.header.type);
        switch (ftype) {
            .request => {
                const line = self.alloc.dupe(u8, frame.body) catch return;
                defer self.alloc.free(line);
                const tline = std.mem.trimEnd(u8, line, "\n\r");
                const resp = self.processCommand(tline);
                defer self.alloc.free(resp);
                const rf = ipc.makeResponse(self.alloc, frame.header.id, resp) catch return;
                defer self.alloc.free(rf.body);
                const enc = ipc.encodeFrame(self.alloc, rf) catch return;
                defer self.alloc.free(enc);
                self.queueBytes(c, enc, &[_]i32{}) catch {};
            },
            .subscribe, .unsubscribe => {
                var topic = frame.body;
                if (std.mem.indexOfScalar(u8, topic, 0)) |nul| topic = topic[0..nul];
                const ack = ipc.makeAck(frame.header.id);
                const enc = ipc.encodeFrame(self.alloc, .{ .header = ack.header, .body = @constCast(&[_]u8{}) }) catch return;
                defer self.alloc.free(enc);
                if (ftype == .subscribe) {
                    if (topic.len > 0) {
                        const entry = self.subscriptions.getOrPut(topic) catch return;
                        if (!entry.found_existing) {
                            entry.key_ptr.* = self.alloc.dupe(u8, topic) catch return;
                            entry.value_ptr.* = .empty;
                        }
                        for (entry.value_ptr.items) |m| {
                            if (m == c.fd) break;
                        } else {
                            entry.value_ptr.append(self.alloc, c.fd) catch {};
                        }
                    }
                } else {
                    if (self.subscriptions.getEntry(topic)) |e| {
                        const v = e.value_ptr;
                        for (v.items, 0..) |m, k| {
                            if (m == c.fd) {
                                _ = v.orderedRemove(k);
                                break;
                            }
                        }
                    }
                }
                self.queueBytes(c, enc, &[_]i32{}) catch {};
            },
            .event => {
                const nul = std.mem.indexOfScalar(u8, frame.body, 0) orelse frame.body.len;
                const topic = frame.body[0..nul];
                const payload = if (nul < frame.body.len) frame.body[nul + 1 ..] else &[_]u8{};
                self.publish(topic, payload, &[_]i32{});
            },
            else => {},
        }
    }

    fn flushClient(self: *Service, c: *Client) bool {
        while (c.out.items.len > 0) {
            const q = &c.out.items[0];
            const first = !q.fds_sent;
            const n = sock.sendWithFds(c.fd, q.bytes.items, q.fds.items, first) catch return false;
            if (n > 0) {
                std.mem.copyForwards(u8, q.bytes.items[0 .. q.bytes.items.len - n], q.bytes.items[n..]);
                q.bytes.items.len -= n;
            } else {
                return true;
            }
            if (q.bytes.items.len == 0) {
                if (first) {
                    q.fds_sent = true;
                    for (q.fds.items) |f| sock.closeFd(f);
                    q.fds.clearRetainingCapacity();
                }
                var done = c.out.orderedRemove(0);
                done.deinit(self.alloc);
                if (c.out.items.len == 0) c.want_poll_out = false;
            }
        }
        return true;
    }

    pub fn publish(self: *Service, topic: []const u8, payload: []const u8, fds: []const i32) void {
        if (self.listen_fd < 0) return;
        const evt = ipc.makeEvent(self.alloc, topic, payload) catch return;
        defer self.alloc.free(evt.body);
        var hdr = evt.header;
        if (fds.len > 0) hdr.flags |= ipc.flag_fd;
        const enc = ipc.encodeFrame(self.alloc, .{ .header = hdr, .body = evt.body }) catch return;
        defer self.alloc.free(enc);
        const subs = self.subscriptions.get(topic) orelse return;
        for (subs.items) |fd| {
            const c = self.findClient(fd) orelse continue;
            var rfds: std.ArrayList(i32) = .empty;
            defer rfds.deinit(self.alloc);
            var ok = true;
            for (fds) |f| {
                const d: usize = linux.dup(f);
                if (@as(isize, @bitCast(d)) < 0) {
                    ok = false;
                    break;
                }
                rfds.append(self.alloc, @intCast(d)) catch {
                    ok = false;
                    break;
                };
            }
            if (!ok) {
                for (rfds.items) |d| sock.closeFd(d);
                continue;
            }
            const owned = rfds.toOwnedSlice(self.alloc) catch continue;
            self.queueBytes(c, enc, owned) catch {
                for (owned) |d| sock.closeFd(d);
                self.alloc.free(owned);
                continue;
            };
            self.alloc.free(owned);
        }
    }
};

fn pingHandler(alloc: std.mem.Allocator, args: []const []const u8) anyerror![]u8 {
    _ = args;
    return alloc.dupe(u8, "pong");
}

fn echoHandler(alloc: std.mem.Allocator, args: []const []const u8) anyerror![]u8 {
    return std.mem.join(alloc, " ", args);
}

fn readLegacyResponse(fd: i32, svc: *Service, buf: []u8) usize {
    var total: usize = 0;
    var ticks: u32 = 0;
    while (ticks < 300 and total < buf.len) : (ticks += 1) {
        svc.pumpOnce(20);
        const n: usize = linux.read(fd, buf[total..].ptr, buf.len - total);
        const s: isize = @bitCast(n);
        if (s > 0) {
            total += @intCast(s);
        } else if (s == 0) {
            break;
        }
    }
    return total;
}

test "ipc_server: legacy ping round trip" {
    const t = std.testing;
    var svc = Service.init(t.allocator);
    defer svc.deinit();
    const path = try std.fmt.allocPrint(t.allocator, "/tmp/eh-test-{d}.sock", .{std.os.linux.getpid()});
    defer t.allocator.free(path);
    try svc.registerHandler("ping", pingHandler);
    try svc.registerHandler("echo", echoHandler);
    try svc.start(path);
    defer svc.stop();

    const fd = try sock.createStream(true);
    defer sock.closeFd(fd);
    try t.expect(sock.connectPath(fd, path) == null);
    try sock.sendAll(fd, "ping\n");
    _ = linux.shutdown(fd, linux.SHUT.WR);
    var resp: [64]u8 = undefined;
    const n = readLegacyResponse(fd, &svc, &resp);
    try t.expect(n > 0);
    const got = std.mem.trimEnd(u8, resp[0..n], "\r\n ");
    try t.expectEqualStrings("pong", got);
}

test "ipc_server: unknown command errors" {
    const t = std.testing;
    var svc = Service.init(t.allocator);
    defer svc.deinit();
    const path = try std.fmt.allocPrint(t.allocator, "/tmp/eh-test-u-{d}.sock", .{std.os.linux.getpid()});
    defer t.allocator.free(path);
    try svc.start(path);
    defer svc.stop();

    const fd = try sock.createStream(true);
    defer sock.closeFd(fd);
    try t.expect(sock.connectPath(fd, path) == null);
    try sock.sendAll(fd, "frobnicate x\n");
    _ = linux.shutdown(fd, linux.SHUT.WR);
    var resp: [128]u8 = undefined;
    const n = readLegacyResponse(fd, &svc, &resp);
    try t.expect(n > 0);
    try t.expect(std.mem.startsWith(u8, resp[0..n], "error unknown command"));
}

test "ipc_server: framed request/response via poll integration" {
    const t = std.testing;
    var svc = Service.init(t.allocator);
    defer svc.deinit();
    const path = try std.fmt.allocPrint(t.allocator, "/tmp/eh-test-f-{d}.sock", .{std.os.linux.getpid()});
    defer t.allocator.free(path);
    try svc.registerHandler("echo", echoHandler);
    try svc.start(path);
    defer svc.stop();

    const fd = try sock.createStream(true);
    defer sock.closeFd(fd);
    try t.expect(sock.connectPath(fd, path) == null);

    const body = try t.allocator.dupe(u8, "echo hello world");
    defer t.allocator.free(body);
    const wire = try ipc.encodeFrame(t.allocator, ipc.makeRequest(7, body));
    defer t.allocator.free(wire);
    try sock.sendAll(fd, wire);

    var interests: std.ArrayList(PollInterest) = .empty;
    defer interests.deinit(t.allocator);
    var got_resp: ?[]u8 = null;
    defer if (got_resp) |g| t.allocator.free(g);
    var ticks: u32 = 0;
    while (ticks < 200 and got_resp == null) : (ticks += 1) {
        try svc.pollInterests(&interests);
        var pfds: [8]std.posix.pollfd = undefined;
        const m = @min(interests.items.len, pfds.len);
        for (interests.items[0..m], 0..) |pi, k| {
            pfds[k] = .{ .fd = pi.fd, .events = pi.events, .revents = 0 };
        }
        _ = std.posix.poll(pfds[0..m], 50) catch {};
        for (interests.items[0..m], 0..) |pi, k| {
            if (pfds[k].revents != 0) svc.onFdReady(pi.fd, pfds[k].revents);
        }
        var rbuf: [4096]u8 = undefined;
        var nofds: std.ArrayList(i32) = .empty;
        defer nofds.deinit(t.allocator);
        const r = try sock.recvWithFds(fd, &rbuf, &nofds, t.allocator);
        if (r.nbytes > 0) {
            const res = try ipc.decodeFrame(t.allocator, rbuf[0..r.nbytes]);
            defer t.allocator.free(res.frame.body);
            try t.expectEqual(@as(u64, 7), res.frame.header.id);
            got_resp = try t.allocator.dupe(u8, res.frame.body);
        }
    }
    try t.expect(got_resp != null);
    try t.expectEqualStrings("hello world", got_resp.?);
    try t.expectEqual(@as(usize, 1), svc.clientCount());
}
