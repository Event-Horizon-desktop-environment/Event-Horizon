const std = @import("std");
const wire = @import("wire.zig");
const connection = @import("connection.zig");

pub const MethodResult = union(enum) {
    ok: []const wire.Value,
    err: MethodError,

    pub const MethodError = struct {
        name: []const u8,
        message: []const u8,
    };
};

pub const MethodHandler = *const fn (alloc: std.mem.Allocator, ctx: *anyopaque, args: []const wire.Value) MethodResult;

pub const Method = struct {
    name: []const u8,
    in_sig: []const u8,
    out_sig: []const u8,
    handler: MethodHandler,
    ctx: *anyopaque,
};

pub const PropAccess = enum { read, write, readwrite };

pub const Property = struct {
    name: []const u8,
    sig: []const u8,
    access: PropAccess,
    get: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!wire.Value = null,
    set: ?*const fn (ctx: *anyopaque, v: wire.Value) anyerror!void = null,
    ctx: *anyopaque = undefined,
};

pub const VTable = struct {
    interface: []const u8,
    methods: []const Method = &.{},
    properties: []const Property = &.{},
    signals: []const Signal = &.{},

    pub const Signal = struct {
        name: []const u8,
        sig: []const u8 = "",
    };
};

const Object = struct {
    path: []const u8,
    vtables: std.ArrayList(VTable),
};

pub const Tree = struct {
    alloc: std.mem.Allocator,
    conn: *connection.Conn,
    objects: std.ArrayList(Object),
    prop_changed_handler: ?*const fn (ctx: *anyopaque, path: []const u8, iface: []const u8, name: []const u8) void = null,
    prop_changed_ctx: *anyopaque = undefined,
    /// Bus name of the peer whose method call is currently running. A
    /// `MethodHandler` only receives the arguments, but the status-notifier
    /// registration protocol needs the caller's name when the client passes
    /// an object path instead of a well-known name.
    last_sender: []const u8 = "",

    pub fn init(alloc: std.mem.Allocator, conn: *connection.Conn) Tree {
        return .{ .alloc = alloc, .conn = conn, .objects = .empty };
    }

    pub fn deinit(self: *Tree) void {
        for (self.objects.items) |*o| {
            self.alloc.free(o.path);
            o.vtables.deinit(self.alloc);
        }
        self.objects.deinit(self.alloc);
        if (self.last_sender.len > 0) self.alloc.free(self.last_sender);
    }

    /// Registers an object path. The path string is copied, but the vtable
    /// array and everything it points at (methods, properties, signals) is
    /// kept by reference: the caller must keep those slices alive for as
    /// long as the tree does. Passing function-local temporaries leaves
    /// dangling lookups once the caller returns.
    pub fn addObject(self: *Tree, path: []const u8, vtables: []const VTable) !void {
        const owned = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(owned);
        var list: std.ArrayList(VTable) = .empty;
        errdefer list.deinit(self.alloc);
        try list.appendSlice(self.alloc, vtables);
        try self.objects.append(self.alloc, .{ .path = owned, .vtables = list });
    }

    fn findObject(self: *Tree, path: []const u8) ?*Object {
        for (self.objects.items) |*o| {
            if (std.mem.eql(u8, o.path, path)) return o;
        }
        return null;
    }

    fn findVTable(o: *Object, iface: []const u8) ?*VTable {
        for (o.vtables.items) |*v| {
            if (std.mem.eql(u8, v.interface, iface)) return v;
        }
        return null;
    }

    pub fn emitSignal(self: *Tree, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const wire.Value) !void {
        _ = try self.conn.sendMessage(.{
            .mtype = .signal,
            .path = path,
            .interface = iface,
            .member = member,
            .signature = sig,
            .body = body,
        });
    }

    pub fn emitPropertiesChanged(self: *Tree, path: []const u8, iface: []const u8, name: []const u8, val_sig: []const u8, val: wire.Value) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();
        const pair = try aa.alloc(wire.Value, 2);
        pair[0] = .{ .string = try aa.dupe(u8, name) };
        const vb = try aa.create(wire.Value);
        vb.* = val;
        pair[1] = .{ .variant = .{ .sig = try aa.dupe(u8, val_sig), .val = vb } };
        const changed = try aa.alloc(wire.Value, 1);
        changed[0] = .{ .structure = pair };
        const body = try aa.alloc(wire.Value, 3);
        body[0] = .{ .string = try aa.dupe(u8, iface) };
        body[1] = .{ .array = .{ .elem = try aa.dupe(u8, "{sv}"), .items = changed } };
        body[2] = .{ .array = .{ .elem = try aa.dupe(u8, "s"), .items = &.{} } };
        try self.emitSignal(path, "org.freedesktop.DBus.Properties", "PropertiesChanged", "sa{sv}as", body);
    }

    fn replyOk(self: *Tree, req: wire.Message, out_sig: []const u8, vals: []const wire.Value) !void {
        _ = try self.conn.sendMessage(.{
            .mtype = .method_return,
            .reply_serial = req.serial,
            .destination = req.sender,
            .signature = out_sig,
            .body = vals,
        });
    }

    fn replyErr(self: *Tree, req: wire.Message, name: []const u8, msg: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const body = try arena.allocator().alloc(wire.Value, 1);
        body[0] = .{ .string = msg };
        _ = try self.conn.sendMessage(.{
            .mtype = .@"error",
            .err_name = name,
            .reply_serial = req.serial,
            .destination = req.sender,
            .signature = "s",
            .body = body,
        });
    }

    pub fn introspectXml(self: *Tree, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        const w = XmlWriter{ .out = &out, .alloc = alloc };
        try w.print(
            \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
            \\<node>
            \\
        , .{});
        if (self.findObject(path)) |o| {
            for (o.vtables.items) |*v| {
                try w.print("  <interface name=\"{s}\">\n", .{v.interface});
                for (v.methods) |*m| {
                    try w.print("    <method name=\"{s}\">\n", .{m.name});
                    try writeSigArgs(w, m.in_sig, "in");
                    try writeSigArgs(w, m.out_sig, "out");
                    try w.writeAll("    </method>\n");
                }
                for (v.properties) |*p| {
                    const acc: []const u8 = switch (p.access) {
                        .read => "read",
                        .write => "write",
                        .readwrite => "readwrite",
                    };
                    try w.print("    <property name=\"{s}\" type=\"{s}\" access=\"{s}\"/>\n", .{ p.name, p.sig, acc });
                }
                for (v.signals) |*s| {
                    try w.print("    <signal name=\"{s}\">\n", .{s.name});
                    try writeSigArgs(w, s.sig, "out");
                    try w.writeAll("    </signal>\n");
                }
                try w.writeAll("  </interface>\n");
            }
        }
        try w.writeAll(
            \\  <interface name="org.freedesktop.DBus.Introspectable">
            \\    <method name="Introspect">
            \\      <arg name="out0" type="s" direction="out"/>
            \\    </method>
            \\  </interface>
            \\  <interface name="org.freedesktop.DBus.Properties">
            \\    <method name="Get">
            \\      <arg name="in0" type="s" direction="in"/>
            \\      <arg name="in1" type="s" direction="in"/>
            \\      <arg name="out0" type="v" direction="out"/>
            \\    </method>
            \\    <method name="GetAll">
            \\      <arg name="in0" type="s" direction="in"/>
            \\      <arg name="out0" type="a{sv}" direction="out"/>
            \\    </method>
            \\    <method name="Set">
            \\      <arg name="in0" type="s" direction="in"/>
            \\      <arg name="in1" type="s" direction="in"/>
            \\      <arg name="in2" type="v" direction="out"/>
            \\    </method>
            \\    <signal name="PropertiesChanged">
            \\      <arg name="out0" type="s" direction="out"/>
            \\      <arg name="out1" type="a{sv}" direction="out"/>
            \\      <arg name="out2" type="as" direction="out"/>
            \\    </signal>
            \\  </interface>
            \\  <interface name="org.freedesktop.DBus.Peer">
            \\    <method name="Ping">
            \\    </method>
            \\    <method name="GetMachineId">
            \\      <arg name="out0" type="s" direction="out"/>
            \\    </method>
            \\  </interface>
            \\</node>
            \\
        );
        return out.toOwnedSlice(alloc);
    }

    const XmlWriter = struct {
        out: *std.ArrayList(u8),
        alloc: std.mem.Allocator,

        fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
            const s = try std.fmt.allocPrint(self.alloc, fmt, args);
            defer self.alloc.free(s);
            try self.out.appendSlice(self.alloc, s);
        }

        fn writeAll(self: @This(), s: []const u8) !void {
            try self.out.appendSlice(self.alloc, s);
        }
    };

    fn writeSigArgs(w: XmlWriter, sig: []const u8, dir: []const u8) !void {
        var i: usize = 0;
        var n: usize = 0;
        while (i < sig.len) {
            const end = wire.findSigEnd(sig, i);
            try w.print("      <arg name=\"{s}{d}\" type=\"{s}\" direction=\"{s}\"/>\n", .{ dir, n, sig[i..end], dir });
            n += 1;
            i = end;
        }
    }

    pub fn dispatch(self: *Tree, req: wire.Message, body: []const wire.Value) !bool {
        if (req.mtype != .method_call) return false;
        const path = req.path orelse return false;
        const iface = req.interface orelse {
            try self.replyErr(req, "org.freedesktop.DBus.Error.UnknownMethod", "missing interface");
            return true;
        };
        const member = req.member orelse {
            try self.replyErr(req, "org.freedesktop.DBus.Error.UnknownMethod", "missing member");
            return true;
        };
        if (std.mem.eql(u8, iface, "org.freedesktop.DBus.Peer")) {
            if (std.mem.eql(u8, member, "Ping")) {
                try self.replyOk(req, "", &.{});
                return true;
            }
            if (std.mem.eql(u8, member, "GetMachineId")) {
                const id = try self.alloc.dupe(u8, "0123456789abcdef0123456789abcdef");
                defer self.alloc.free(id);
                const vals = [_]wire.Value{.{ .string = id }};
                try self.replyOk(req, "s", &vals);
                return true;
            }
        }
        if (std.mem.eql(u8, iface, "org.freedesktop.DBus.Introspectable") and std.mem.eql(u8, member, "Introspect")) {
            const xml = try self.introspectXml(self.alloc, path);
            defer self.alloc.free(xml);
            const vals = [_]wire.Value{.{ .string = xml }};
            try self.replyOk(req, "s", &vals);
            return true;
        }
        if (std.mem.eql(u8, iface, "org.freedesktop.DBus.Properties")) {
            return self.dispatchProperties(req, body, path, member);
        }
        const o = self.findObject(path) orelse {
            try self.replyErr(req, "org.freedesktop.DBus.Error.UnknownObject", "no such object");
            return true;
        };
        const v = findVTable(o, iface) orelse {
            try self.replyErr(req, "org.freedesktop.DBus.Error.UnknownInterface", "no such interface");
            return true;
        };
        for (v.methods) |*m| {
            if (!std.mem.eql(u8, m.name, member)) continue;
            if (!std.mem.eql(u8, req.signature, m.in_sig)) {
                try self.replyErr(req, "org.freedesktop.DBus.Error.InvalidArgs", "signature mismatch");
                return true;
            }
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            if (self.last_sender.len > 0) self.alloc.free(self.last_sender);
            self.last_sender = self.alloc.dupe(u8, req.sender orelse "") catch "";
            switch (m.handler(arena.allocator(), m.ctx, body)) {
                .ok => |vals| try self.replyOk(req, m.out_sig, vals),
                .err => |e| try self.replyErr(req, e.name, e.message),
            }
            return true;
        }
        try self.replyErr(req, "org.freedesktop.DBus.Error.UnknownMethod", "no such method");
        return true;
    }

    fn dispatchProperties(self: *Tree, req: wire.Message, body: []const wire.Value, path: []const u8, member: []const u8) !bool {
        const o = self.findObject(path) orelse {
            try self.replyErr(req, "org.freedesktop.DBus.Error.UnknownObject", "no such object");
            return true;
        };
        if (std.mem.eql(u8, member, "Get")) {
            const vals = body;
            if (vals.len < 2 or vals[0] != .string or vals[1] != .string) {
                try self.replyErr(req, "org.freedesktop.DBus.Error.InvalidArgs", "Get needs s,s");
                return true;
            }
            const prop = self.findProp(o, vals[0].string, vals[1].string) orelse {
                try self.replyErr(req, "org.freedesktop.DBus.Error.UnknownProperty", "no such property");
                return true;
            };
            if (prop.get == null) {
                try self.replyErr(req, "org.freedesktop.DBus.Error.PropertyReadOnly", "write only");
                return true;
            }
            const v = prop.get.?(prop.ctx, self.alloc) catch {
                try self.replyErr(req, "org.freedesktop.DBus.Error.Failed", "get failed");
                return true;
            };
            defer wire.freeValue(self.alloc, v);
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const box = try arena.allocator().create(wire.Value);
            box.* = v;
            const duped_sig = try arena.allocator().dupe(u8, prop.sig);
            const out = [_]wire.Value{.{ .variant = .{ .sig = duped_sig, .val = box } }};
            try self.replyOk(req, "v", &out);
            return true;
        }
        if (std.mem.eql(u8, member, "GetAll")) {
            const vals = body;
            if (vals.len < 1 or vals[0] != .string) {
                try self.replyErr(req, "org.freedesktop.DBus.Error.InvalidArgs", "GetAll needs s");
                return true;
            }
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const aa = arena.allocator();
            var items: std.ArrayList(wire.Value) = .empty;
            for (o.vtables.items) |*vt| {
                if (!std.mem.eql(u8, vt.interface, vals[0].string)) continue;
                for (vt.properties) |*p| {
                    if (p.get == null) continue;
                    const v = p.get.?(p.ctx, aa) catch continue;
                    const pair = try aa.alloc(wire.Value, 2);
                    pair[0] = .{ .string = try aa.dupe(u8, p.name) };
                    const vb = try aa.create(wire.Value);
                    vb.* = v;
                    const vsig = try aa.dupe(u8, p.sig);
                    pair[1] = .{ .variant = .{ .sig = vsig, .val = vb } };
                    try items.append(aa, .{ .structure = pair });
                }
            }
            const owned = try aa.alloc(wire.Value, 1);
            owned[0] = .{ .array = .{ .elem = try aa.dupe(u8, "{sv}"), .items = try items.toOwnedSlice(aa) } };
            try self.replyOk(req, "a{sv}", owned);
            return true;
        }
        if (std.mem.eql(u8, member, "Set")) {
            const vals = body;
            if (vals.len < 3 or vals[0] != .string or vals[1] != .string or vals[2] != .variant) {
                try self.replyErr(req, "org.freedesktop.DBus.Error.InvalidArgs", "Set needs s,s,v");
                return true;
            }
            const prop = self.findProp(o, vals[0].string, vals[1].string) orelse {
                try self.replyErr(req, "org.freedesktop.DBus.Error.UnknownProperty", "no such property");
                return true;
            };
            if (prop.access == .read or prop.set == null) {
                try self.replyErr(req, "org.freedesktop.DBus.Error.PropertyReadOnly", "read only");
                return true;
            }
            prop.set.?(prop.ctx, vals[2].variant.val.*) catch {
                try self.replyErr(req, "org.freedesktop.DBus.Error.Failed", "set failed");
                return true;
            };
            try self.replyOk(req, "", &.{});
            return true;
        }
        try self.replyErr(req, "org.freedesktop.DBus.Error.UnknownMethod", "no such method");
        return true;
    }

    fn findProp(self: *Tree, o: *Object, iface: []const u8, name: []const u8) ?*const Property {
        _ = self;
        const v = findVTable(o, iface) orelse return null;
        for (v.properties) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

const SCtx = struct {
    count: u32 = 0,
};

fn echoHandler(alloc: std.mem.Allocator, ctx: *anyopaque, args: []const wire.Value) MethodResult {
    _ = ctx;
    if (args.len < 1 or args[0] != .string) {
        return .{ .err = .{ .name = "org.eventhorizon.Test.Error", .message = "need s" } };
    }
    const out = alloc.dupe(u8, args[0].string) catch {
        return .{ .err = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .message = "oom" } };
    };
    const vals = alloc.alloc(wire.Value, 1) catch {
        alloc.free(out);
        return .{ .err = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .message = "oom" } };
    };
    vals[0] = .{ .string = out };
    return .{ .ok = vals };
}

fn countGet(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!wire.Value {
    _ = alloc;
    const s: *SCtx = @ptrCast(@alignCast(ctx));
    return .{ .uint32 = s.count };
}

fn countSet(ctx: *anyopaque, v: wire.Value) anyerror!void {
    const s: *SCtx = @ptrCast(@alignCast(ctx));
    if (v != .uint32) return error.BadValue;
    s.count = v.uint32;
}

fn pumpServer(svc: *connection.Conn, tree: *Tree, budget_ms: i64) void {
    const sockm = @import("../sock.zig");
    const deadline = sockm.nowMs() + budget_ms;
    while (sockm.nowMs() < deadline) {
        var pfd = std.posix.pollfd{ .fd = svc.fd, .events = std.posix.POLL.IN, .revents = 0 };
        const r = std.posix.poll((&pfd)[0..1], 20) catch 0;
        if (r == 0) continue;
        var p = svc.recvMessage(100) catch continue;
        defer p.deinit();
        _ = tree.dispatch(p.msg, p.body_vals) catch false;
    }
}

fn callServer(cli: *connection.Conn, srv: *connection.Conn, tree: *Tree, msg: wire.Message) !wire.Parsed {
    const serial = try cli.sendMessage(msg);
    var ticks: u32 = 0;
    while (ticks < 300) : (ticks += 1) {
        pumpServer(srv, tree, 20);
        var p = cli.recvMessage(100) catch continue;
        errdefer p.deinit();
        if (p.msg.reply_serial) |rs| {
            if (rs == serial) return p;
        }
        p.deinit();
    }
    return error.Timeout;
}

test "dbus-object: serve + introspect + props + method + signal" {
    const t = std.testing;
    const getAddr = struct {
        fn env(alloc: std.mem.Allocator) ?[]u8 {
            const cc = @import("c_stdlib");
            const p = cc.getenv("DBUS_SESSION_BUS_ADDRESS");
            if (p == null) return null;
            return alloc.dupe(u8, std.mem.span(p)) catch null;
        }
    }.env;
    const addr = getAddr(t.allocator) orelse return error.SkipZigTest;
    defer t.allocator.free(addr);

    var srv = connection.Conn.init(t.allocator);
    defer srv.deinit();
    srv.connect(addr) catch return error.SkipZigTest;
    try srv.hello();
    var cli = connection.Conn.init(t.allocator);
    defer cli.deinit();
    cli.connect(addr) catch return error.SkipZigTest;
    try cli.hello();

    var sctx = SCtx{};
    var tree = Tree.init(t.allocator, &srv);
    defer tree.deinit();
    const vtables = [_]VTable{.{
        .interface = "com.example.Test",
        .methods = &[_]Method{.{ .name = "Echo", .in_sig = "s", .out_sig = "s", .handler = echoHandler, .ctx = &sctx }},
        .properties = &[_]Property{.{ .name = "Count", .sig = "u", .access = .readwrite, .get = countGet, .set = countSet, .ctx = &sctx }},
        .signals = &[_]VTable.Signal{.{ .name = "Changed", .sig = "u" }},
    }};
    try tree.addObject("/com/example/Test", &vtables);
    const svc_name = try std.fmt.allocPrint(t.allocator, "org.eventhorizon.objtest.pid{d}", .{std.os.linux.getpid()});
    defer t.allocator.free(svc_name);
    _ = try srv.requestName(svc_name, 3000);

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var ip = try callServer(&cli, &srv, &tree, .{
        .mtype = .method_call,
        .path = "/com/example/Test",
        .interface = "org.freedesktop.DBus.Introspectable",
        .member = "Introspect",
        .destination = svc_name,
    });
    defer ip.deinit();
    try t.expect(ip.body_vals.len == 1);
    const xml = ip.body_vals[0].string;
    try t.expect(std.mem.indexOf(u8, xml, "com.example.Test") != null);
    try t.expect(std.mem.indexOf(u8, xml, "name=\"Echo\"") != null);
    try t.expect(std.mem.indexOf(u8, xml, "name=\"Count\"") != null);
    try t.expect(std.mem.indexOf(u8, xml, "name=\"Changed\"") != null);

    const get_body = try aa.alloc(wire.Value, 2);
    get_body[0] = .{ .string = "com.example.Test" };
    get_body[1] = .{ .string = "Count" };
    var gp = try callServer(&cli, &srv, &tree, .{
        .mtype = .method_call,
        .path = "/com/example/Test",
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Get",
        .destination = svc_name,
        .signature = "ss",
        .body = get_body,
    });
    defer gp.deinit();
    try t.expect(gp.body_vals.len == 1);
    try t.expect(gp.body_vals[0] == .variant);
    try t.expectEqual(@as(u32, 0), gp.body_vals[0].variant.val.uint32);

    const set_body = try aa.alloc(wire.Value, 3);
    set_body[0] = .{ .string = "com.example.Test" };
    set_body[1] = .{ .string = "Count" };
    const svbox = try aa.create(wire.Value);
    svbox.* = .{ .uint32 = 41 };
    set_body[2] = .{ .variant = .{ .sig = "u", .val = svbox } };
    var sp = try callServer(&cli, &srv, &tree, .{
        .mtype = .method_call,
        .path = "/com/example/Test",
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Set",
        .destination = svc_name,
        .signature = "ssv",
        .body = set_body,
    });
    defer sp.deinit();

    var gp2 = try callServer(&cli, &srv, &tree, .{
        .mtype = .method_call,
        .path = "/com/example/Test",
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Get",
        .destination = svc_name,
        .signature = "ss",
        .body = get_body,
    });
    defer gp2.deinit();
    try t.expectEqual(@as(u32, 41), gp2.body_vals[0].variant.val.uint32);

    const echo_body = try aa.alloc(wire.Value, 1);
    echo_body[0] = .{ .string = "hi" };
    var ep = try callServer(&cli, &srv, &tree, .{
        .mtype = .method_call,
        .path = "/com/example/Test",
        .interface = "com.example.Test",
        .member = "Echo",
        .destination = svc_name,
        .signature = "s",
        .body = echo_body,
    });
    defer ep.deinit();
    try t.expectEqualStrings("hi", ep.body_vals[0].string);

    try cli.addMatch("type='signal',interface='com.example.Test'", 3000);
    const sig_body = try aa.alloc(wire.Value, 1);
    sig_body[0] = .{ .uint32 = 7 };
    try tree.emitSignal("/com/example/Test", "com.example.Test", "Changed", "u", sig_body);
    var seen: ?u32 = null;
    var ticks: u32 = 0;
    while (ticks < 100 and seen == null) : (ticks += 1) {
        pumpServer(&srv, &tree, 20);
        var cp = cli.recvMessage(100) catch continue;
        defer cp.deinit();
        if (cp.msg.mtype == .signal and cp.msg.member != null and std.mem.eql(u8, cp.msg.member.?, "Changed")) {
            if (cp.body_vals.len > 0 and cp.body_vals[0] == .uint32) seen = cp.body_vals[0].uint32;
        }
    }
    try t.expectEqual(@as(?u32, 7), seen);
}
