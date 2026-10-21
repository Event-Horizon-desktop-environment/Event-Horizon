const std = @import("std");

pub const Kind = enum { volume, brightness, mic_mute, caps_lock };

pub const Request = struct {
    kind: Kind,
    value_pct: u32 = 0,
    muted: bool = false,
    serial: u64 = 0,
};

pub const Queue = struct {
    alloc: std.mem.Allocator,
    pending: std.ArrayList(Request),
    current: ?Request = null,
    current_deadline_ms: i64 = 0,
    hold_ms: i64 = 2000,

    pub fn init(alloc: std.mem.Allocator) Queue {
        return .{ .alloc = alloc, .pending = .empty };
    }

    pub fn deinit(self: *Queue) void {
        self.pending.deinit(self.alloc);
    }

    pub fn push(self: *Queue, req: Request) !void {
        for (self.pending.items, 0..) |*p, i| {
            if (p.kind == req.kind) {
                self.pending.items[i] = req;
                return;
            }
        }
        if (self.current != null and self.current.?.kind == req.kind) {
            self.current = req;
            return;
        }
        try self.pending.append(self.alloc, req);
    }

    pub fn tick(self: *Queue, now_ms: i64) ?Request {
        if (self.current) |c| {
            if (now_ms < self.current_deadline_ms) return c;
            self.current = null;
        }
        if (self.pending.items.len == 0) return null;
        const r = self.pending.orderedRemove(0);
        self.current = r;
        self.current_deadline_ms = now_ms + self.hold_ms;
        return r;
    }
};

test "osd: coalesce + hold + expiry" {
    const t = std.testing;
    var q = Queue.init(t.allocator);
    defer q.deinit();
    try q.push(.{ .kind = .volume, .value_pct = 30 });
    try q.push(.{ .kind = .volume, .value_pct = 40 });
    try q.push(.{ .kind = .brightness, .value_pct = 80 });
    try t.expectEqual(@as(usize, 2), q.pending.items.len);
    const a = q.tick(0).?;
    try t.expectEqual(@as(u32, 40), a.value_pct);
    try t.expect(q.tick(500).?.kind == .volume);
    const b = q.tick(2500).?;
    try t.expect(b.kind == .brightness);
    try t.expect(q.tick(5000) == null);
}
