const std = @import("std");

const c = @cImport(@cInclude("pthread.h"));

pub const TaskFn = *const fn (ctx: *anyopaque) void;

const Task = struct {
    func: TaskFn,
    ctx: *anyopaque,
};

pub const Pool = struct {
    alloc: std.mem.Allocator,
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    queue: std.ArrayList(Task),
    head: usize = 0,
    stop: bool = false,
    threads: std.ArrayList(c.pthread_t),
    started: bool = false,
    setup: bool = false,

    pub fn init(alloc: std.mem.Allocator) Pool {
        return .{ .alloc = alloc, .queue = .empty, .threads = .empty };
    }

    pub fn deinit(self: *Pool) void {
        std.debug.assert(!self.started);
        if (self.setup) {
            _ = c.pthread_cond_destroy(&self.cond);
            _ = c.pthread_mutex_destroy(&self.mutex);
            self.setup = false;
        }
        self.queue.deinit(self.alloc);
        self.threads.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn start(self: *Pool, count: usize) !void {
        std.debug.assert(!self.started);
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
        if (c.pthread_cond_init(&self.cond, null) != 0) {
            _ = c.pthread_mutex_destroy(&self.mutex);
            return error.CondInitFailed;
        }
        self.setup = true;
        errdefer self.shutdownJoinLocked();
        for (0..count) |_| {
            var tid: c.pthread_t = 0;
            if (c.pthread_create(&tid, null, workerMain, self) != 0) return error.ThreadSpawnFailed;
            try self.threads.append(self.alloc, tid);
        }
        self.started = true;
    }

    pub fn submit(self: *Pool, func: TaskFn, ctx: *anyopaque) !void {
        if (c.pthread_mutex_lock(&self.mutex) != 0) return error.LockFailed;
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        if (self.stop) return error.PoolStopped;
        try self.queue.append(self.alloc, .{ .func = func, .ctx = ctx });
        _ = c.pthread_cond_signal(&self.cond);
    }

    pub fn shutdownJoin(self: *Pool) void {
        if (!self.started and self.threads.items.len == 0) return;
        self.shutdownJoinLocked();
    }

    fn shutdownJoinLocked(self: *Pool) void {
        if (c.pthread_mutex_lock(&self.mutex) == 0) {
            self.stop = true;
            _ = c.pthread_cond_broadcast(&self.cond);
            _ = c.pthread_mutex_unlock(&self.mutex);
        }
        for (self.threads.items) |tid| {
            var ret: ?*anyopaque = null;
            _ = c.pthread_join(tid, &ret);
        }
        self.threads.clearRetainingCapacity();
        self.started = false;
    }

    fn take(self: *Pool) ?Task {
        if (c.pthread_mutex_lock(&self.mutex) != 0) return null;
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        while (!self.stop and self.head >= self.queue.items.len) {
            if (c.pthread_cond_wait(&self.cond, &self.mutex) != 0) return null;
        }
        if (self.head >= self.queue.items.len) return null;
        const t = self.queue.items[self.head];
        self.head += 1;
        if (self.head * 2 >= self.queue.items.len and self.head > 64) {
            self.queue.replaceRange(self.alloc, 0, self.head, &[_]Task{}) catch {};
            self.head = 0;
        }
        return t;
    }
};

fn workerMain(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const self: *Pool = @ptrCast(@alignCast(arg orelse return null));
    while (self.take()) |t| t.func(t.ctx);
    return null;
}

test "pool: N tasks all run exactly once" {
    const t = std.testing;
    var pool = Pool.init(t.allocator);
    defer pool.deinit();

    const counter = try t.allocator.create(std.atomic.Value(usize));
    defer t.allocator.destroy(counter);
    counter.* = .init(0);

    const Ctx = struct {
        var count: *std.atomic.Value(usize) = undefined;
        fn run(ctx: *anyopaque) void {
            _ = ctx;
            _ = count.fetchAdd(1, .seq_cst);
        }
    };
    Ctx.count = counter;

    try pool.start(4);
    const total = 2000;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        try pool.submit(Ctx.run, @ptrCast(counter));
    }
    pool.shutdownJoin();
    try t.expectEqual(total, counter.load(.seq_cst));
}

test "pool: submit after shutdown is rejected" {
    const t = std.testing;
    var pool = Pool.init(t.allocator);
    defer pool.deinit();
    try pool.start(1);
    pool.shutdownJoin();
    var x: u8 = 0;
    const res = pool.submit(struct {
        fn run(_: *anyopaque) void {}
    }.run, &x);
    try t.expectError(error.PoolStopped, res);
}
