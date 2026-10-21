const std = @import("std");

pub const SurfaceHandle = enum(usize) {
    none = 0,
    _,
};

pub const InhibitRequest = struct {
    surface: SurfaceHandle,
    enable: bool,
};

pub const Service = struct {
    manager_bound: bool = false,
    surface: SurfaceHandle = .none,
    enabled: bool = false,
    inhibitor_active: bool = false,

    pub fn setManager(self: *Service, bound: bool) void {
        self.manager_bound = bound;
        if (!bound) self.inhibitor_active = false;
        self.sync();
    }

    pub fn setEnabled(self: *Service, on: bool, surface: SurfaceHandle) void {
        self.enabled = on;
        self.surface = surface;
        self.sync();
    }

    pub fn isEnabled(self: *const Service) bool {
        return self.enabled;
    }

    pub fn isInhibiting(self: *const Service) bool {
        return self.inhibitor_active;
    }

    fn sync(self: *Service) void {
        self.inhibitor_active = self.enabled and self.manager_bound and self.surface != .none;
    }
};

test "redeye: inhibitor only when enabled + manager + surface" {
    const t = std.testing;
    var s = Service{};
    s.setEnabled(true, @enumFromInt(7));
    try t.expect(!s.isInhibiting());
    s.setManager(true);
    try t.expect(s.isInhibiting());
    s.setManager(false);
    try t.expect(!s.isInhibiting());
    s.setManager(true);
    s.setEnabled(false, @enumFromInt(7));
    try t.expect(!s.isInhibiting());
    try t.expect(!s.isEnabled());
}
