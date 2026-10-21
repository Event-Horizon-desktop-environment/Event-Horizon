const std = @import("std");
const wl = @import("../connection.zig").wl;

const act = @import("../c.zig").wl;

pub const TokenCallback = *const fn (ctx: *anyopaque, token: []const u8) void;

const PendingToken = struct {
    obj: ?*act.xdg_activation_token_v1,
    cb: TokenCallback,
    ctx: *anyopaque,
};

fn tokenDone(data: ?*anyopaque, token: ?*act.xdg_activation_token_v1, token_str: [*c]const u8) callconv(.c) void {
    const svc: *Service = @ptrCast(@alignCast(data orelse return));
    var done_token: ?*act.xdg_activation_token_v1 = null;
    var cb: ?TokenCallback = null;
    var ctx: *anyopaque = undefined;
    for (svc.pending.items, 0..) |*p, i| {
        if (p.obj == token) {
            done_token = p.obj;
            cb = p.cb;
            ctx = p.ctx;
            _ = svc.pending.orderedRemove(i);
            break;
        }
    }
    if (cb) |h| {
        if (token_str != null) {
            h(ctx, std.mem.span(token_str));
        } else {
            h(ctx, "");
        }
    }
    if (done_token) |tok| act.xdg_activation_token_v1_destroy(tok);
}

const token_listener = act.xdg_activation_token_v1_listener{ .done = tokenDone };

pub const Service = struct {
    alloc: std.mem.Allocator,
    activation: ?*act.xdg_activation_v1 = null,
    pending: std.ArrayList(PendingToken),

    pub fn init(alloc: std.mem.Allocator) Service {
        return .{ .alloc = alloc, .pending = .empty };
    }

    pub fn deinit(self: *Service) void {
        for (self.pending.items) |*p| {
            if (p.obj) |o| act.xdg_activation_token_v1_destroy(o);
        }
        self.pending.deinit(self.alloc);
    }

    pub fn setActivation(self: *Service, a: ?*act.xdg_activation_v1) void {
        self.activation = a;
    }

    pub fn requestToken(self: *Service, seat: ?*wl.wl_seat, serial: u32, surface: ?*wl.wl_surface, cb: TokenCallback, ctx: *anyopaque) bool {
        const a = self.activation orelse return false;
        if (seat == null or serial == 0) return false;
        const token = act.xdg_activation_v1_get_activation_token(a);
        if (token == null) return false;
        errdefer act.xdg_activation_token_v1_destroy(token);
        self.pending.append(self.alloc, .{ .obj = token, .cb = cb, .ctx = ctx }) catch {
            return false;
        };
        _ = act.xdg_activation_token_v1_add_listener(token, &token_listener, self);
        act.xdg_activation_token_v1_set_serial(token, serial, seat);
        if (surface) |s| act.xdg_activation_token_v1_set_surface(token, s);
        act.xdg_activation_token_v1_commit(token);
        return true;
    }

    pub fn activate(self: *Service, token: []const u8, surface: ?*wl.wl_surface) bool {
        const a = self.activation orelse return false;
        if (token.len == 0) return false;
        const s = surface orelse return false;
        var zbuf: [512:0]u8 = [_:0]u8{0} ** 512;
        if (token.len >= zbuf.len) return false;
        @memcpy(zbuf[0..token.len], token);
        act.xdg_activation_v1_activate(a, &zbuf, s);
        return true;
    }
};

test "activation: null guards" {
    const t = std.testing;
    var s = Service.init(t.allocator);
    defer s.deinit();
    try t.expect(!s.requestToken(null, 0, null, struct {
        fn cb(_: *anyopaque, _: []const u8) void {}
    }.cb, undefined));
    try t.expect(!s.activate("", null));
    try t.expect(!s.activate("tok", null));
}
