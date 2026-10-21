const std = @import("std");
const wl = @import("../connection.zig").wl;

const inhibit = @import("../c.zig").wl;
const session_lock = @import("../c.zig").wl;
const idle_notify = @import("../c.zig").wl;

pub const Inhibitor = struct {
    manager: ?*inhibit.zwp_idle_inhibit_manager_v1 = null,
    inhibitor: ?*inhibit.zwp_idle_inhibitor_v1 = null,
    surface: ?*wl.wl_surface = null,
    enabled: bool = false,

    pub fn setManager(self: *Inhibitor, mgr: ?*inhibit.zwp_idle_inhibit_manager_v1) void {
        self.manager = mgr;
        if (mgr == null and self.inhibitor != null) {
            inhibit.zwp_idle_inhibitor_v1_destroy(self.inhibitor);
            self.inhibitor = null;
        }
        self.sync();
    }

    pub fn setInhibited(self: *Inhibitor, surface: ?*wl.wl_surface, inhibited: bool) void {
        if (!inhibited) {
            if (self.inhibitor != null) {
                inhibit.zwp_idle_inhibitor_v1_destroy(self.inhibitor);
                self.inhibitor = null;
            }
            return;
        }
        if (self.inhibitor != null) return;
        const mgr = self.manager orelse return;
        const s = surface orelse return;
        self.surface = s;
        self.inhibitor = inhibit.zwp_idle_inhibit_manager_v1_create_inhibitor(mgr, s);
    }

    pub fn isInhibiting(self: *const Inhibitor) bool {
        return self.inhibitor != null;
    }

    fn sync(self: *Inhibitor) void {
        if (self.enabled) {
            self.setInhibited(self.surface, true);
        }
    }

    pub fn deinit(self: *Inhibitor) void {
        if (self.inhibitor != null) {
            inhibit.zwp_idle_inhibitor_v1_destroy(self.inhibitor);
            self.inhibitor = null;
        }
        self.manager = null;
    }
};

pub const SessionLock = struct {
    manager: ?*session_lock.ext_session_lock_manager_v1 = null,
    lock_obj: ?*session_lock.ext_session_lock_v1 = null,

    pub fn setManager(self: *SessionLock, mgr: ?*session_lock.ext_session_lock_manager_v1) void {
        self.manager = mgr;
    }

    pub fn lock(self: *SessionLock) bool {
        if (self.manager == null or self.lock_obj != null) return false;
        const l = session_lock.ext_session_lock_manager_v1_lock(self.manager);
        if (l == null) return false;
        self.lock_obj = l;
        return true;
    }

    pub fn unlock(self: *SessionLock) void {
        if (self.lock_obj) |l| {
            session_lock.ext_session_lock_v1_destroy(l);
            self.lock_obj = null;
        }
    }

    pub fn isLocked(self: *const SessionLock) bool {
        return self.lock_obj != null;
    }
};

pub const IdleBehavior = struct {
    timeout_sec: u32 = 0,
    on_idle: ?*const fn (ctx: *anyopaque) void = null,
    on_resume: ?*const fn (ctx: *anyopaque) void = null,
    ctx: *anyopaque = undefined,
    notifier: ?*idle_notify.ext_idle_notifier_v1 = null,
    notification: ?*idle_notify.ext_idle_notification_v1 = null,
};

fn idleNotified(data: ?*anyopaque, n: ?*idle_notify.ext_idle_notification_v1) callconv(.c) void {
    _ = n;
    const b: *IdleBehavior = @ptrCast(@alignCast(data orelse return));
    if (b.on_idle) |h| h(b.ctx);
}

fn idleResumed(data: ?*anyopaque, n: ?*idle_notify.ext_idle_notification_v1) callconv(.c) void {
    _ = n;
    const b: *IdleBehavior = @ptrCast(@alignCast(data orelse return));
    if (b.on_resume) |h| h(b.ctx);
}

const idle_listener = idle_notify.ext_idle_notification_v1_listener{
    .idled = idleNotified,
    .resumed = idleResumed,
};

pub const IdleService = struct {
    alloc: std.mem.Allocator,
    notifier: ?*idle_notify.ext_idle_notifier_v1 = null,
    seat: ?*wl.wl_seat = null,
    behaviors: std.ArrayList(IdleBehavior),

    pub fn init(alloc: std.mem.Allocator) IdleService {
        return .{ .alloc = alloc, .behaviors = .empty };
    }

    pub fn deinit(self: *IdleService) void {
        self.clearNotifications();
        self.behaviors.deinit(self.alloc);
    }

    pub fn setNotifier(self: *IdleService, n: ?*idle_notify.ext_idle_notifier_v1, seat: ?*wl.wl_seat) void {
        self.clearNotifications();
        self.notifier = n;
        self.seat = seat;
        self.armAll();
    }

    pub fn addBehavior(self: *IdleService, b: IdleBehavior) !void {
        try self.behaviors.append(self.alloc, b);
        self.armOne(&self.behaviors.items[self.behaviors.items.len - 1]);
    }

    fn armOne(self: *IdleService, b: *IdleBehavior) void {
        const n = self.notifier orelse return;
        const s = self.seat orelse return;
        if (b.timeout_sec == 0 or b.notification != null) return;
        const note = idle_notify.ext_idle_notifier_v1_get_idle_notification(n, b.timeout_sec * 1000, s);
        if (note == null) return;
        _ = idle_notify.ext_idle_notification_v1_add_listener(note, &idle_listener, b);
        b.notification = note;
    }

    fn armAll(self: *IdleService) void {
        for (self.behaviors.items) |*b| self.armOne(b);
    }

    fn clearNotifications(self: *IdleService) void {
        for (self.behaviors.items) |*b| {
            if (b.notification) |note| {
                idle_notify.ext_idle_notification_v1_destroy(note);
                b.notification = null;
            }
        }
    }
};

test "session: inhibitor state without wayland" {
    const t = std.testing;
    var inh = Inhibitor{};
    defer inh.deinit();
    inh.enabled = true;
    inh.setInhibited(null, true);
    try t.expect(!inh.isInhibiting());
    inh.setInhibited(null, false);
    try t.expect(!inh.isInhibiting());
}

test "session: lock guards null manager" {
    const t = std.testing;
    var l = SessionLock{};
    try t.expect(!l.lock());
    try t.expect(!l.isLocked());
    l.unlock();
}

test "session: idle behaviors queue without notifier" {
    const t = std.testing;
    var s = IdleService.init(t.allocator);
    defer s.deinit();
    try s.addBehavior(.{ .timeout_sec = 300 });
    try s.addBehavior(.{ .timeout_sec = 0 });
    try t.expectEqual(@as(usize, 2), s.behaviors.items.len);
}
