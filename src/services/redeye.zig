//! The redeye service: a `zwp_idle_inhibitor_v1` that keeps the session awake
//! while the pear's redeye toggle is on.
//!
//! Ported from the reference `services/redeye/redeye_service.cpp`. Like the
//! reference it owns at most one inhibitor object, created against the surface
//! the caller supplies and destroyed when the toggle turns off or the manager
//! goes away. The Wayland object bookkeeping lives in `wl.session.Inhibitor`;
//! this module adds the remembered on/off bit the reference keeps separate
//! from "an inhibitor object exists".

const std = @import("std");
const wl = @import("../wl/connection.zig").wl;
const inhibit = @import("../wl/c.zig").wl;
const wl_session = @import("../wl/session/session.zig");

pub const Service = struct {
    inner: wl_session.Inhibitor = .{},
    /// The requested state, which outlives the object: an enable that arrives
    /// before the manager is bound is remembered and applied by `setManager`.
    enabled: bool = false,

    pub fn setManager(self: *Service, mgr: ?*inhibit.zwp_idle_inhibit_manager_v1) void {
        // `Inhibitor.setManager` re-runs `sync`, so a remembered enable is
        // applied the moment the registry hands us the manager.
        self.inner.setManager(mgr);
    }

    pub fn setEnabled(self: *Service, on: bool, surface: ?*wl.wl_surface) void {
        self.enabled = on;
        // Keep the inhibitor's own latch in step: it is what `setManager`
        // consults when the compositor rebinds the manager, and a stale `true`
        // there would resurrect an inhibitor the user just turned off.
        self.inner.enabled = on;
        if (surface != null) self.inner.surface = surface;
        if (!on) {
            self.inner.setInhibited(null, false);
            return;
        }
        // Already inhibiting: keep the existing object, as the reference does.
        if (self.inner.isInhibiting()) return;
        self.inner.setInhibited(self.inner.surface, true);
    }

    pub fn isEnabled(self: *const Service) bool {
        return self.enabled;
    }

    /// Whether a Wayland inhibitor object is actually alive. This can lag
    /// `isEnabled` when the manager or the surface is not available.
    pub fn isInhibiting(self: *const Service) bool {
        return self.inner.isInhibiting();
    }

    pub fn deinit(self: *Service) void {
        self.inner.deinit();
        self.inner.enabled = false;
        self.enabled = false;
    }
};

test "redeye: enabled is remembered without a manager or surface" {
    const t = std.testing;
    var s = Service{};
    defer s.deinit();

    s.setEnabled(true, null);
    try t.expect(s.isEnabled());
    try t.expect(!s.isInhibiting());

    // The manager arriving without a surface still cannot create the object,
    // but the request is not lost.
    s.setManager(null);
    try t.expect(s.isEnabled());
    try t.expect(!s.isInhibiting());

    s.setEnabled(false, null);
    try t.expect(!s.isEnabled());
    try t.expect(!s.isInhibiting());
}

test "redeye: manager teardown clears the inhibitor but not the request" {
    const t = std.testing;
    var s = Service{};
    defer s.deinit();

    s.setEnabled(true, null);
    s.setManager(null);
    try t.expect(s.isEnabled());
    try t.expect(!s.isInhibiting());
}

test "redeye: turning off clears the inhibitor latch so a rebind stays off" {
    const t = std.testing;
    var s = Service{};
    defer s.deinit();

    s.setEnabled(true, null);
    s.setEnabled(false, null);
    // The inhibitor's own latch must follow the service, otherwise the next
    // manager bind would create an inhibitor behind the user's back.
    try t.expect(!s.inner.enabled);
    s.setManager(null);
    try t.expect(!s.isEnabled());
    try t.expect(!s.isInhibiting());
}
