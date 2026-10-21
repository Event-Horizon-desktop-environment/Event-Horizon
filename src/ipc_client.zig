const std = @import("std");
const linux = std.os.linux;
const ipc = @import("ipc.zig");
const sock = @import("sock.zig");

pub const EventHandler = *const fn (ctx: *anyopaque, topic: []const u8, payload: []const u8, fds: []i32) void;

pub const Client = struct {
    alloc: std.mem.Allocator,
    fd: i32 = -1,
    next_id: u64 = 1,
    rbuf: std.ArrayList(u8),
    pending_fds: std.ArrayList(i32),
    on_event: ?EventHandler = null,
    event_ctx: *anyopaque = undefined,

    pub fn init(alloc: std.mem.Allocator) Client {
        return .{ .alloc = alloc, .rbuf = .empty, .pending_fds = .empty };
    }

    pub fn deinit(self: *Client) void {
        self.disconnect();
        self.rbuf.deinit(self.alloc);
        self.pending_fds.deinit(self.alloc);
    }

    pub fn connected(self: *const Client) bool {
        return self.fd >= 0;
    }

    pub fn connect(self: *Client, path: []const u8, attempts: u32) bool {
        if (self.fd >= 0) self.disconnect();
        var i: u32 = 0;
        while (i < attempts) : (i += 1) {
            const fd = sock.createStream(false) catch return false;
            if (sock.connectPath(fd, path)) |e| {
                sock.closeFd(fd);
                if (e != .NOENT and e != .CONNREFUSED) return false;
                sleepMs(50);
                continue;
            }
            const fl: usize = linux.fcntl(fd, linux.F.GETFL, 0);
            if (@as(isize, @bitCast(fl)) >= 0) {
                const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
                _ = linux.fcntl(fd, linux.F.SETFL, fl | nonblock);
            }
            self.fd = fd;
            return true;
        }
        return false;
    }

    pub fn disconnect(self: *Client) void {
        if (self.fd >= 0) {
            sock.closeFd(self.fd);
            self.fd = -1;
        }
        for (self.pending_fds.items) |f| sock.closeFd(f);
        self.pending_fds.clearRetainingCapacity();
        self.rbuf.clearRetainingCapacity();
    }

    pub fn setEventHandler(self: *Client, h: EventHandler, ctx: *anyopaque) void {
        self.on_event = h;
        self.event_ctx = ctx;
    }

    fn writeAll(self: *Client, bytes: []const u8, timeout_ms: i64) bool {
        var off: usize = 0;
        const deadline = sock.nowMs() + timeout_ms;
        while (off < bytes.len) {
            const rc = linux.sendto(self.fd, bytes[off..].ptr, bytes.len - off, linux.MSG.NOSIGNAL, null, 0);
            const e = linux.errno(rc);
            if (e != .SUCCESS) {
                if (e == .AGAIN) {
                    if (!waitWritable(self.fd, deadline)) return false;
                    continue;
                }
                if (e == .INTR) continue;
                return false;
            }
            const n: usize = @intCast(rc);
            if (n == 0) return false;
            off += n;
        }
        return true;
    }

    fn readAvailable(self: *Client) bool {
        var chunk: [65536]u8 = undefined;
        while (true) {
            const r = sock.recvWithFds(self.fd, &chunk, &self.pending_fds, self.alloc) catch return false;
            if (r.truncated) {
                for (self.pending_fds.items) |f| sock.closeFd(f);
                self.pending_fds.clearRetainingCapacity();
                return false;
            }
            if (r.eof) return false;
            if (r.nbytes == 0) return true;
            self.rbuf.appendSlice(self.alloc, chunk[0..r.nbytes]) catch return false;
        }
    }

    fn pumpFrame(self: *Client, timeout_ms: i64) ?ipc.Frame {
        const deadline = sock.nowMs() + timeout_ms;
        while (true) {
            if (self.rbuf.items.len > 0) {
                const res = ipc.decodeFrame(self.alloc, self.rbuf.items) catch |err| {
                    if (err != ipc.DecodeError.NeedMoreData) return null;
                    if (!self.waitMore(deadline)) return null;
                    continue;
                };
                std.mem.copyForwards(u8, self.rbuf.items[0 .. self.rbuf.items.len - res.consumed], self.rbuf.items[res.consumed..]);
                self.rbuf.items.len -= res.consumed;
                return res.frame;
            }
            if (!self.waitMore(deadline)) return null;
        }
    }

    fn waitMore(self: *Client, deadline: i64) bool {
        const remaining = deadline - sock.nowMs();
        if (remaining <= 0) return false;
        if (!waitReadable(self.fd, remaining)) return false;
        if (!self.readAvailable()) return false;
        return self.rbuf.items.len > 0;
    }

    fn dispatchEvent(self: *Client, frame: ipc.Frame) void {
        defer self.alloc.free(frame.body);
        var fds: []i32 = &[_]i32{};
        if ((frame.header.flags & ipc.flag_fd) != 0) {
            fds = self.pending_fds.items;
        } else {
            for (self.pending_fds.items) |f| sock.closeFd(f);
            self.pending_fds.clearRetainingCapacity();
        }
        const nul = std.mem.indexOfScalar(u8, frame.body, 0) orelse frame.body.len;
        const topic = frame.body[0..nul];
        const payload = if (nul < frame.body.len) frame.body[nul + 1 ..] else &[_]u8{};
        if (self.on_event) |h| {
            h(self.event_ctx, topic, payload, fds);
        }
        for (self.pending_fds.items) |f| sock.closeFd(f);
        self.pending_fds.clearRetainingCapacity();
    }

    fn freeFrameBody(self: *Client, frame: ipc.Frame) void {
        self.alloc.free(frame.body);
    }

    pub fn request(self: *Client, command_line: []const u8, timeout_ms: i64) ?[]u8 {
        if (self.fd < 0) return null;
        const id = self.next_id;
        self.next_id += 1;
        const enc = ipc.encodeFrame(self.alloc, ipc.makeRequest(id, command_line)) catch return null;
        defer self.alloc.free(enc);
        if (!self.writeAll(enc, timeout_ms)) return null;
        const deadline = sock.nowMs() + timeout_ms;
        while (true) {
            if (sock.nowMs() >= deadline) return null;
            const frame = self.pumpFrame(deadline - sock.nowMs()) orelse return null;
            const ftype: ipc.FrameType = @enumFromInt(frame.header.type);
            if (ftype == .response and frame.header.id == id) {
                return frame.body;
            } else if (ftype == .event) {
                self.dispatchEvent(frame);
            } else {
                self.freeFrameBody(frame);
            }
        }
    }

    fn sendControl(self: *Client, ftype: ipc.FrameType, id: u64, topic: []const u8, timeout_ms: i64) bool {
        const frame = ipc.Frame{
            .header = .{ .version = ipc.protocol_version, .type = @intFromEnum(ftype), .flags = 0, .id = id },
            .body = @constCast(topic),
        };
        const enc = ipc.encodeFrame(self.alloc, frame) catch return false;
        defer self.alloc.free(enc);
        return self.writeAll(enc, timeout_ms);
    }

    fn waitForAck(self: *Client, id: u64, timeout_ms: i64) bool {
        const deadline = sock.nowMs() + timeout_ms;
        while (true) {
            if (sock.nowMs() >= deadline) return false;
            const frame = self.pumpFrame(deadline - sock.nowMs()) orelse return false;
            const ftype: ipc.FrameType = @enumFromInt(frame.header.type);
            if (ftype == .ack and frame.header.id == id) {
                self.freeFrameBody(frame);
                return true;
            } else if (ftype == .event) {
                self.dispatchEvent(frame);
            } else {
                self.freeFrameBody(frame);
            }
        }
    }

    pub fn subscribe(self: *Client, topic: []const u8, timeout_ms: i64) bool {
        if (self.fd < 0) return false;
        const id = self.next_id;
        self.next_id += 1;
        if (!self.sendControl(.subscribe, id, topic, timeout_ms)) return false;
        return self.waitForAck(id, timeout_ms);
    }

    pub fn subscribeAsync(self: *Client, topic: []const u8) bool {
        if (self.fd < 0) return false;
        const id = self.next_id;
        self.next_id += 1;
        return self.sendControl(.subscribe, id, topic, 3000);
    }

    pub fn unsubscribe(self: *Client, topic: []const u8, timeout_ms: i64) bool {
        if (self.fd < 0) return false;
        const id = self.next_id;
        self.next_id += 1;
        if (!self.sendControl(.unsubscribe, id, topic, timeout_ms)) return false;
        return self.waitForAck(id, timeout_ms);
    }

    pub fn publish(self: *Client, topic: []const u8, payload: []const u8) bool {
        if (self.fd < 0) return false;
        const evt = ipc.makeEvent(self.alloc, topic, payload) catch return false;
        defer self.alloc.free(evt.body);
        const enc = ipc.encodeFrame(self.alloc, evt) catch return false;
        defer self.alloc.free(enc);
        return self.writeAll(enc, 3000);
    }

    pub fn onFdReady(self: *Client, fd: i32) void {
        if (fd != self.fd) return;
        if (!self.readAvailable()) {
            self.disconnect();
            return;
        }
        while (self.rbuf.items.len > 0) {
            const res = ipc.decodeFrame(self.alloc, self.rbuf.items) catch |err| {
                if (err != ipc.DecodeError.NeedMoreData) self.disconnect();
                return;
            };
            std.mem.copyForwards(u8, self.rbuf.items[0 .. self.rbuf.items.len - res.consumed], self.rbuf.items[res.consumed..]);
            self.rbuf.items.len -= res.consumed;
            const ftype: ipc.FrameType = @enumFromInt(res.frame.header.type);
            if (ftype == .event) {
                self.dispatchEvent(res.frame);
            } else {
                self.freeFrameBody(res.frame);
            }
        }
    }
};

fn waitReadable(fd: i32, timeout_ms: i64) bool {
    var pfd = std.posix.pollfd{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
    const ms: i32 = @intCast(@max(0, @min(timeout_ms, std.math.maxInt(i32))));
    const r = std.posix.poll((&pfd)[0..1], ms) catch return false;
    return r > 0;
}

fn waitWritable(fd: i32, deadline: i64) bool {
    const remaining = deadline - sock.nowMs();
    if (remaining <= 0) return false;
    var pfd = std.posix.pollfd{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 };
    const ms: i32 = @intCast(@max(0, @min(remaining, std.math.maxInt(i32))));
    const r = std.posix.poll((&pfd)[0..1], ms) catch return false;
    return r > 0;
}

fn sleepMs(ms: i64) void {
    const clamped: i32 = @intCast(@max(0, @min(ms, std.math.maxInt(i32))));
    _ = std.posix.poll(&[_]std.posix.pollfd{}, clamped) catch 0;
}

pub fn socketPathFor(alloc: std.mem.Allocator, eh_ipc_socket: ?[]const u8, xdg_runtime: ?[]const u8) ![]u8 {
    if (eh_ipc_socket) |p| return alloc.dupe(u8, p);
    if (xdg_runtime) |d| return std.fs.path.join(alloc, &.{ d, "event-horizon-ipc.sock" });
    return alloc.dupe(u8, "/tmp/event-horizon-ipc.sock");
}

pub fn sendLegacy(alloc: std.mem.Allocator, path: []const u8, line: []const u8) ![]u8 {
    const fd = try sock.createStream(false);
    defer sock.closeFd(fd);
    if (sock.connectPath(fd, path) != null) return error.ConnectFailed;
    var msg = try std.ArrayList(u8).initCapacity(alloc, line.len + 1);
    defer msg.deinit(alloc);
    try msg.appendSlice(alloc, line);
    if (line.len == 0 or line[line.len - 1] != '\n') try msg.append(alloc, '\n');
    try sock.sendAll(fd, msg.items);
    _ = linux.shutdown(fd, linux.SHUT.WR);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n: usize = linux.read(fd, &chunk, chunk.len);
        const s: isize = @bitCast(n);
        if (s < 0) {
            const e = linux.errno(n);
            if (e == .INTR) continue;
            break;
        }
        if (s == 0) break;
        try out.appendSlice(alloc, chunk[0..@intCast(s)]);
    }
    const trimmed = std.mem.trimEnd(u8, out.items, "\r\n");
    const res = try alloc.dupe(u8, trimmed);
    out.deinit(alloc);
    return res;
}

const server = @import("ipc_server.zig");

fn testSocketPath(alloc: std.mem.Allocator, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "/tmp/eh-ct-{s}-{d}.sock", .{ tag, std.os.linux.getpid() });
}

fn pongHandler(alloc: std.mem.Allocator, args: []const []const u8) anyerror![]u8 {
    _ = args;
    return alloc.dupe(u8, "pong");
}

const EvCap = struct {
    topic: ?[]u8 = null,
    payload: ?[]u8 = null,
    nfds: usize = 0,
    alloc: std.mem.Allocator = undefined,
};

fn capEvent(ctx: *anyopaque, topic: []const u8, payload: []const u8, fds: []i32) void {
    const cap: *EvCap = @ptrCast(@alignCast(ctx));
    if (cap.topic) |s| cap.alloc.free(s);
    if (cap.payload) |s| cap.alloc.free(s);
    cap.topic = cap.alloc.dupe(u8, topic) catch null;
    cap.payload = cap.alloc.dupe(u8, payload) catch null;
    cap.nfds = fds.len;
    for (fds) |f| sock.closeFd(f);
}

test "ipc_client: framed request/response round trip" {
    const t = std.testing;
    var svc = server.Service.init(t.allocator);
    defer svc.deinit();
    const path = try testSocketPath(t.allocator, "rr");
    defer t.allocator.free(path);
    try svc.registerHandler("ping", pongHandler);
    try svc.start(path);
    defer svc.stop();

    var c = Client.init(t.allocator);
    defer c.deinit();
    try t.expect(c.connect(path, 8));

    var interests: std.ArrayList(server.PollInterest) = .empty;
    defer interests.deinit(t.allocator);
    const pump = struct {
        fn go(s: *server.Service, il: *std.ArrayList(server.PollInterest)) !void {
            try s.pollInterests(il);
            var pfds: [8]std.posix.pollfd = undefined;
            const m = @min(il.items.len, pfds.len);
            for (il.items[0..m], 0..) |pi, k| {
                pfds[k] = .{ .fd = pi.fd, .events = pi.events, .revents = 0 };
            }
            _ = std.posix.poll(pfds[0..m], 20) catch 0;
            for (il.items[0..m], 0..) |pi, k| {
                if (pfds[k].revents != 0) s.onFdReady(pi.fd, pfds[k].revents);
            }
        }
    }.go;

    var req_done = false;
    var resp: ?[]u8 = null;
    defer if (resp) |r| t.allocator.free(r);
    const id: u64 = 99;
    const enc = try ipc.encodeFrame(t.allocator, ipc.makeRequest(id, "ping"));
    defer t.allocator.free(enc);
    var off: usize = 0;
    var ticks: u32 = 0;
    while (ticks < 300 and !req_done) : (ticks += 1) {
        if (off < enc.len) {
            const n = sock.sendWithFds(c.fd, enc[off..], &[_]i32{}, true) catch 0;
            off += n;
        }
        try pump(&svc, &interests);
        var rbuf: [4096]u8 = undefined;
        var nofds: std.ArrayList(i32) = .empty;
        defer nofds.deinit(t.allocator);
        const r = try sock.recvWithFds(c.fd, &rbuf, &nofds, t.allocator);
        if (r.nbytes > 0) {
            const res = try ipc.decodeFrame(t.allocator, rbuf[0..r.nbytes]);
            defer t.allocator.free(res.frame.body);
            try t.expectEqual(id, res.frame.header.id);
            resp = try t.allocator.dupe(u8, res.frame.body);
            req_done = true;
        }
    }
    try t.expect(req_done);
    try t.expectEqualStrings("pong", resp.?);
}

test "ipc_client: subscribe + publish delivers event with fd" {
    const t = std.testing;
    var svc = server.Service.init(t.allocator);
    defer svc.deinit();
    const path = try testSocketPath(t.allocator, "ev");
    defer t.allocator.free(path);
    try svc.start(path);
    defer svc.stop();

    var sub = Client.init(t.allocator);
    defer sub.deinit();
    try t.expect(sub.connect(path, 8));
    var pubc = Client.init(t.allocator);
    defer pubc.deinit();
    try t.expect(pubc.connect(path, 8));

    var cap = EvCap{ .alloc = t.allocator };
    defer {
        if (cap.topic) |s| t.allocator.free(s);
        if (cap.payload) |s| t.allocator.free(s);
    }
    sub.setEventHandler(capEvent, &cap);

    const PumpCtx = struct {
        svc: *server.Service,
        stop: *std.atomic.Value(bool),
        fn run(p: *@This()) void {
            var interests: std.ArrayList(server.PollInterest) = .empty;
            defer interests.deinit(p.svc.alloc);
            var pfds: [16]std.posix.pollfd = undefined;
            while (!p.stop.load(.monotonic)) {
                p.svc.pollInterests(&interests) catch return;
                const m = @min(interests.items.len, pfds.len);
                for (interests.items[0..m], 0..) |pi, k| {
                    pfds[k] = .{ .fd = pi.fd, .events = pi.events, .revents = 0 };
                }
                _ = std.posix.poll(pfds[0..m], 20) catch 0;
                for (interests.items[0..m], 0..) |pi, k| {
                    if (pfds[k].revents != 0) p.svc.onFdReady(pi.fd, pfds[k].revents);
                }
            }
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    var pctx = PumpCtx{ .svc = &svc, .stop = &stop };
    const pump_thread = try std.Thread.spawn(.{}, PumpCtx.run, .{&pctx});
    defer {
        stop.store(true, .monotonic);
        pump_thread.join();
    }

    try t.expect(sub.subscribe("ws-a", 3000));
    try t.expect(sub.subscribe("ws-b", 3000));
    try t.expect(pubc.publish("ws-a", "{\"n\":2}"));

    var ticks: u32 = 0;
    while (ticks < 400 and cap.topic == null) : (ticks += 1) {
        sub.onFdReady(sub.fd);
        _ = std.posix.poll(&[_]std.posix.pollfd{}, 5) catch 0;
    }
    try t.expect(cap.topic != null);
    try t.expectEqualStrings("ws-a", cap.topic.?);
    try t.expectEqualStrings("{\"n\":2}", cap.payload.?);
    try t.expectEqual(@as(usize, 0), cap.nfds);

    var pfds: [2]i32 = .{ -1, -1 };
    try t.expect(linux.pipe(&pfds) == 0);
    svc.publish("ws-b", "bin", pfds[1..2]);
    sock.closeFd(pfds[1]);
    defer sock.closeFd(pfds[0]);

    ticks = 0;
    while (ticks < 400 and (cap.topic == null or !std.mem.eql(u8, cap.topic.?, "ws-b"))) : (ticks += 1) {
        sub.onFdReady(sub.fd);
        _ = std.posix.poll(&[_]std.posix.pollfd{}, 5) catch 0;
    }
    try t.expect(cap.topic != null);
    try t.expectEqualStrings("ws-b", cap.topic.?);
    try t.expectEqualStrings("bin", cap.payload.?);
    try t.expectEqual(@as(usize, 1), cap.nfds);
    try t.expect(sub.unsubscribe("ws-a", 3000));
    try t.expect(sub.unsubscribe("ws-b", 3000));
}
