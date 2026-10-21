const std = @import("std");
const linux = std.os.linux;

const c = @cImport(@cInclude("pthread.h"));

pub const FdCallback = *const fn (fd: i32, revents: i16, ctx: *anyopaque) void;

const WatchedFd = struct {
    fd: i32,
    events: i16,
    cb: FdCallback,
    ctx: *anyopaque,
};

var stop_flag: std.atomic.Value(bool) = .init(false);

fn onTerm(_: std.posix.SIG) callconv(.c) void {
    stop_flag.store(true, .monotonic);
}

pub const Loop = struct {
    alloc: std.mem.Allocator,
    watched: std.ArrayList(WatchedFd),
    pending: std.ArrayList(threads_Task),
    pending_mutex: c.pthread_mutex_t = undefined,
    mutex_ready: bool = false,
    wake_r: i32 = -1,
    wake_w: i32 = -1,
    running: bool = false,

    const threads_Task = struct {
        func: *const fn (*anyopaque) void,
        ctx: *anyopaque,
    };

    pub fn init(alloc: std.mem.Allocator) !Loop {
        var self = Loop{
            .alloc = alloc,
            .watched = .empty,
            .pending = .empty,
        };
        errdefer self.deinit();
        if (c.pthread_mutex_init(&self.pending_mutex, null) != 0) return error.MutexInitFailed;
        self.mutex_ready = true;
        var fds: [2]i32 = .{ -1, -1 };
        if (linux.pipe(&fds) != 0) return error.PipeFailed;
        errdefer {
            _ = linux.close(fds[0]);
            _ = linux.close(fds[1]);
        }
        for (fds) |fd| {
            const cur: usize = linux.fcntl(fd, linux.F.GETFL, 0);
            if (@as(isize, @bitCast(cur)) < 0) return error.FcntlFailed;
            const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
            const want: usize = cur | nonblock;
            const set: usize = linux.fcntl(fd, linux.F.SETFL, want);
            if (@as(isize, @bitCast(set)) < 0) return error.FcntlFailed;
        }
        self.wake_r = fds[0];
        self.wake_w = fds[1];
        return self;
    }

    pub fn deinit(self: *Loop) void {
        if (self.wake_r >= 0) _ = linux.close(self.wake_r);
        if (self.wake_w >= 0) _ = linux.close(self.wake_w);
        if (self.mutex_ready) _ = c.pthread_mutex_destroy(&self.pending_mutex);
        self.watched.deinit(self.alloc);
        self.pending.deinit(self.alloc);
        self.* = undefined;
    }

    /// Watch `fd`. Re-registering an fd replaces its entry instead of adding
    /// a second one: the kernel reports an fd once, and a duplicated entry
    /// used to fire the same callback twice per readiness.
    pub fn watchFd(self: *Loop, fd: i32, events: i16, cb: FdCallback, ctx: *anyopaque) !void {
        for (self.watched.items) |*w| {
            if (w.fd == fd) {
                w.events = events;
                w.cb = cb;
                w.ctx = ctx;
                return;
            }
        }
        try self.watched.append(self.alloc, .{ .fd = fd, .events = events, .cb = cb, .ctx = ctx });
    }

    /// Drop every entry for `fd`. Call this *before* closing a watched fd:
    /// a stale entry keeps winning poll readiness for a number that now
    /// belongs to something else, and the old callback then reads (or worse,
    /// blocks on) an object it does not own.
    pub fn unwatch(self: *Loop, fd: i32) void {
        var i: usize = 0;
        while (i < self.watched.items.len) {
            if (self.watched.items[i].fd == fd) {
                _ = self.watched.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn callLater(self: *Loop, func: *const fn (*anyopaque) void, ctx: *anyopaque) !void {
        if (c.pthread_mutex_lock(&self.pending_mutex) != 0) return error.LockFailed;
        defer _ = c.pthread_mutex_unlock(&self.pending_mutex);
        if (!self.running) return error.LoopNotRunning;
        try self.pending.append(self.alloc, .{ .func = func, .ctx = ctx });
        var one: [1]u8 = .{1};
        _ = linux.write(self.wake_w, &one, 1);
    }

    fn drainPending(self: *Loop) void {
        while (true) {
            if (c.pthread_mutex_lock(&self.pending_mutex) != 0) return;
            if (self.pending.items.len == 0) {
                _ = c.pthread_mutex_unlock(&self.pending_mutex);
                return;
            }
            const t = self.pending.orderedRemove(0);
            _ = c.pthread_mutex_unlock(&self.pending_mutex);
            t.func(t.ctx);
        }
    }

    fn drainWake(self: *Loop) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const n: usize = linux.read(self.wake_r, &buf, buf.len);
            if (n == 0 or n > buf.len) break;
        }
    }

    pub fn installSignalHandlers() void {
        const act = std.posix.Sigaction{
            .handler = .{ .handler = onTerm },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        ensureTermIntUnblocked();
    }

    fn ensureTermIntUnblocked() void {
        var cur: std.posix.sigset_t = undefined;
        std.posix.sigprocmask(std.posix.SIG.SETMASK, null, &cur);
        std.posix.sigdelset(&cur, std.posix.SIG.TERM);
        std.posix.sigdelset(&cur, std.posix.SIG.INT);
        std.posix.sigprocmask(std.posix.SIG.SETMASK, &cur, null);
    }

    pub fn requestStop() void {
        stop_flag.store(true, .monotonic);
    }

    pub fn run(self: *Loop) void {
        self.running = true;
        defer {
            self.running = false;
        }
        var old_mask: std.posix.sigset_t = undefined;
        var block = std.posix.sigemptyset();
        std.posix.sigaddset(&block, std.posix.SIG.TERM);
        std.posix.sigaddset(&block, std.posix.SIG.INT);
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &block, &old_mask);

        var pollfds_buf: [65]std.posix.pollfd = undefined;
        while (!stop_flag.load(.monotonic)) {
            self.drainPending();
            var n: usize = 0;
            pollfds_buf[n] = .{ .fd = self.wake_r, .events = std.posix.POLL.IN, .revents = 0 };
            n += 1;
            for (self.watched.items) |w| {
                if (n >= pollfds_buf.len) break;
                pollfds_buf[n] = .{ .fd = w.fd, .events = w.events, .revents = 0 };
                n += 1;
            }
            _ = std.posix.ppoll(pollfds_buf[0..n], null, &old_mask) catch |err| {
                if (err == error.SignalInterrupt) continue;
                continue;
            };
            if ((pollfds_buf[0].revents & std.posix.POLL.IN) != 0) self.drainWake();
            for (self.watched.items, 1..) |w, i| {
                if (i >= n) break;
                const rev = pollfds_buf[i].revents;
                if (rev != 0) w.cb(w.fd, rev, w.ctx);
            }
        }
        std.posix.sigprocmask(std.posix.SIG.SETMASK, &old_mask, null);
        self.drainPending();
    }
};

test "loop: SIGTERM handler sets stop flag" {
    const t = std.testing;
    var saved: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.SETMASK, null, &saved);
    defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &saved, null);
    stop_flag.store(false, .monotonic);
    Loop.installSignalHandlers();
    try std.posix.raise(std.posix.SIG.TERM);
    try t.expect(stop_flag.load(.monotonic));
    stop_flag.store(false, .monotonic);
}

test "loop: fd callback fires on writable pipe" {
    const t = std.testing;
    var loop = try Loop.init(t.allocator);
    defer loop.deinit();

    var fds: [2]i32 = .{ -1, -1 };
    try t.expect(linux.pipe(&fds) == 0);
    defer {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
    }

    const Ctx = struct {
        var fired: *std.atomic.Value(bool) = undefined;
        fn cb(_: i32, _: i16, _: *anyopaque) void {
            fired.store(true, .seq_cst);
            Loop.requestStop();
        }
    };
    var fired = std.atomic.Value(bool).init(false);
    Ctx.fired = &fired;

    stop_flag.store(false, .monotonic);
    try loop.watchFd(fds[0], std.posix.POLL.IN, Ctx.cb, @ptrCast(&fired));
    var one: [1]u8 = .{7};
    _ = linux.write(fds[1], &one, 1);
    loop.run();
    try t.expect(fired.load(.seq_cst));
}

test "loop: callLater runs before poll blocks" {
    const t = std.testing;
    var loop = try Loop.init(t.allocator);
    defer loop.deinit();

    const Ctx = struct {
        var ran: *std.atomic.Value(usize) = undefined;
        fn task(ctx: *anyopaque) void {
            const n: *std.atomic.Value(usize) = @ptrCast(@alignCast(ctx));
            _ = n.fetchAdd(1, .seq_cst);
            Loop.requestStop();
        }
    };
    var ran = std.atomic.Value(usize).init(0);
    Ctx.ran = &ran;

    stop_flag.store(false, .monotonic);
    loop.running = true;
    try loop.callLater(Ctx.task, @ptrCast(&ran));
    loop.running = false;
    loop.drainPending();
    try t.expectEqual(@as(usize, 1), ran.load(.seq_cst));
}
