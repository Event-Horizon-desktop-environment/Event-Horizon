//! The polkit authentication agent: the object polkitd talks to and the
//! state machine behind the dialog. Port of the C++ pair
//! `polkit_auth_service.cpp` (state, identity choice, prompt fix-up) and
//! `eh_polkit_listener.c` (cookie bookkeeping, reply timing), with
//! libpolkit-agent's reply semantics:
//!
//! * `BeginAuthentication` is answered when the session *completes* — the
//!   reply is the "this authentication is over" signal polkitd waits for.
//!   A busy/no-identity rejection is answered immediately with
//!   `org.freedesktop.PolicyKit1.Error.Failed`.
//! * `CancelAuthentication` is answered immediately; an unknown cookie is a
//!   `Failed` error naming the cookie.
//!
//! The actual authentication runs in the helper child owned by
//! `session.zig`; this module only reacts to the prompts it produces.

const std = @import("std");
const linux = std.os.linux;
const wire = @import("../../dbus/wire.zig");
const session_mod = @import("session.zig");
const logz = @import("../../logz.zig");

const c = @import("c_polkit");

/// The agent object polkitd calls back into (same path the C++ used).
pub const agent_object_path = "/org/eventhorizon/polkit1/AuthenticationAgent";
pub const agent_interface = "org.freedesktop.PolicyKit1.AuthenticationAgent";
/// D-Bus error name for POLKIT_ERROR_FAILED, which is what the C++ replies
/// with for every rejection.
pub const error_failed = "org.freedesktop.PolicyKit1.Error.Failed";

pub const begin_in_sig = "sssa{ss}sa(sa{sv})";
pub const cancel_in_sig = "s";
pub const register_sig = "(sa{sv})ss";
pub const unregister_sig = "(sa{sv})s";

pub const Phase = enum { idle, pending, active, success, failed };

/// What the dialog renders — the C++ `PolkitState` snapshot. Slices are
/// borrowed from the agent and live until the next request.
pub const Snapshot = struct {
    phase: Phase = .idle,
    action_id: []const u8 = "",
    message: []const u8 = "",
    /// Human-readable identity ("user" / "Full Name (user)").
    identity: []const u8 = "",
    /// Password-field label, prompt rewritten "Password for <user>:".
    prompt: []const u8 = "",
    icon_name: []const u8 = "",
    details: []const u8 = "",
    info: []const u8 = "",
    err: []const u8 = "",
    cookie: []const u8 = "",
    echo_on: bool = true,
    has_request: bool = false,
};

/// A chosen identity from `a(sa{sv})`.
pub const Chosen = struct {
    kind: []const u8,
    uid: ?u32 = null,
    /// First string-valued dict detail (session id etc.), used only for the
    /// human-readable fallback of non-unix-user identities.
    detail: []const u8 = "",
};

pub const BeginOutcome = union(enum) {
    accepted,
    /// Reply immediately with `error_failed` and this message.
    rejected: []const u8,
};

pub const CancelOutcome = union(enum) {
    accepted,
    rejected: []const u8,
};

/// Where the agent reports back into the process around it. All optional so
/// the model can run without a bus (tests).
pub const Hooks = struct {
    ctx: *anyopaque = undefined,
    /// Send the deferred empty reply for the accepted BeginAuthentication.
    send_begin_reply: ?*const fn (ctx: *anyopaque, serial: u32, sender: []const u8) void = null,
    /// A transition the dialog must reflect (show/hide/repaint).
    changed: ?*const fn (ctx: *anyopaque) void = null,
    /// The session stopped owning its poll fd; drop the loop watch.
    fd_stopped: ?*const fn (ctx: *anyopaque, fd: i32) void = null,
};

fn asString(v: wire.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .object_path => |s| s,
        else => null,
    };
}

fn variantU32(v: wire.Value) ?u32 {
    if (v != .variant) return null;
    return switch (v.variant.val.*) {
        .uint32 => |x| x,
        .int32 => |x| if (x < 0) null else @as(u32, @intCast(x)),
        .uint64 => |x| if (x > std.math.maxInt(u32)) null else @as(u32, @intCast(x)),
        else => null,
    };
}

fn variantString(v: wire.Value) ?[]const u8 {
    if (v == .variant) {
        return switch (v.variant.val.*) {
            .string => |s| s,
            .object_path => |s| s,
            else => null,
        };
    }
    return asString(v);
}

/// Parse one `(sa{sv})` identity.
pub fn identityOf(item: wire.Value) ?Chosen {
    if (item != .structure or item.structure.len < 2) return null;
    const kind = asString(item.structure[0]) orelse return null;
    const dict = item.structure[1];
    if (dict != .array) return null;
    var out = Chosen{ .kind = kind };
    for (dict.array.items) |entry| {
        if (entry != .structure or entry.structure.len < 2) continue;
        const k = asString(entry.structure[0]) orelse continue;
        if (out.detail.len == 0) {
            out.detail = variantString(entry.structure[1]) orelse "";
        }
        if (std.mem.eql(u8, k, "uid")) out.uid = variantU32(entry.structure[1]);
        if (std.mem.eql(u8, k, "session-id")) {
            out.detail = variantString(entry.structure[1]) orelse out.detail;
        }
    }
    return out;
}

/// GNOME Shell's preference order, ported: the current user, then root, then
/// the first unix user, then whatever the first identity is.
pub fn chooseIdentity(identities: []const wire.Value) ?Chosen {
    var first_unix: ?Chosen = null;
    var root: ?Chosen = null;
    const self_uid: u32 = c.getuid();
    for (identities) |item| {
        const ch = identityOf(item) orelse continue;
        if (!std.mem.eql(u8, ch.kind, "unix-user")) continue;
        if (first_unix == null) first_unix = ch;
        const uid = ch.uid orelse continue;
        if (uid == self_uid) return ch;
        if (uid == 0) root = ch;
    }
    if (root) |r| return r;
    if (first_unix) |f| return f;
    for (identities) |item| {
        if (identityOf(item)) |ch| return ch;
    }
    return null;
}

/// Flatten `a{ss}` details into "key=value, key=value". Values carry argv/path
/// blobs that may embed newlines, so the run is sanitized and capped before
/// it can reach the dialog or the logs.
pub fn flattenDetails(alloc: std.mem.Allocator, details: wire.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (details == .array) {
        for (details.array.items) |item| {
            if (item != .structure or item.structure.len < 2) continue;
            const k = asString(item.structure[0]) orelse continue;
            const v = asString(item.structure[1]) orelse "";
            if (out.items.len > 0) try out.appendSlice(alloc, ", ");
            try out.appendSlice(alloc, k);
            try out.append(alloc, '=');
            try out.appendSlice(alloc, v);
            if (out.items.len >= 512) {
                try out.appendSlice(alloc, "...");
                break;
            }
        }
    }
    for (out.items) |*ch| {
        if (ch.* < 0x20 or ch.* == 0x7f) ch.* = ' ';
    }
    return out.toOwnedSlice(alloc);
}

/// `getpwuid_r` username for a uid, arena-allocated.
pub fn userNameForUid(alloc: std.mem.Allocator, uid: u32) ?[]const u8 {
    var pw: c.struct_passwd = undefined;
    var buf: [2048]u8 = undefined;
    var result: ?*c.struct_passwd = null;
    const rc = c.getpwuid_r(@intCast(uid), &pw, &buf, buf.len, &result);
    if (rc != 0 or result == null) return null;
    return alloc.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(pw.pw_name)))) catch null;
}

/// The identity the way the reference agents show it: "user", or
/// "Full Name (user)" when gecos says something, or polkit's own
/// "unix-user:<uid>" form when the user is unknown.
pub fn humanReadable(alloc: std.mem.Allocator, chosen: Chosen) []const u8 {
    if (chosen.uid) |uid| {
        var pw: c.struct_passwd = undefined;
        var buf: [2048]u8 = undefined;
        var result: ?*c.struct_passwd = null;
        const rc = c.getpwuid_r(@intCast(uid), &pw, &buf, buf.len, &result);
        if (rc == 0 and result != null) {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(pw.pw_name)));
            const gecos: []const u8 = if (pw.pw_gecos == null)
                ""
            else
                std.mem.span(@as([*:0]const u8, @ptrCast(pw.pw_gecos)));
            if (gecos.len == 0 or std.mem.eql(u8, gecos, name)) {
                return alloc.dupe(u8, name) catch "";
            }
            return std.fmt.allocPrint(alloc, "{s} ({s})", .{ gecos, name }) catch "";
        }
        return std.fmt.allocPrint(alloc, "unix-user:{d}", .{uid}) catch "";
    }
    if (chosen.detail.len > 0) {
        return std.fmt.allocPrint(alloc, "{s}:{s}", .{ chosen.kind, chosen.detail }) catch "";
    }
    return alloc.dupe(u8, chosen.kind) catch "";
}

/// Reference agents never show a bare "Password:" when authenticating as
/// someone else; mate-polkit rewrites it to "Password for <user>:". The
/// identity here is human-readable, so "Full Name (user)" shortens to
/// "user" first. Authenticating as yourself keeps the bare prompt.
pub fn promptLabelFor(alloc: std.mem.Allocator, identity: []const u8, prompt: []const u8) []const u8 {
    const kPw = "password:";
    if (prompt.len < kPw.len) return alloc.dupe(u8, prompt) catch "";
    if (!std.ascii.eqlIgnoreCase(prompt[0..kPw.len], kPw)) return alloc.dupe(u8, prompt) catch "";
    for (prompt[kPw.len..]) |ch| {
        if (ch != ' ' and ch != '\t') return alloc.dupe(u8, prompt) catch "";
    }
    var who = identity;
    if (who.len > 0 and who[who.len - 1] == ')') {
        if (std.mem.lastIndexOf(u8, who, " (")) |open| who = who[open + 2 .. who.len - 1];
    }
    if (who.len == 0) return alloc.dupe(u8, prompt) catch "";
    var pw: c.struct_passwd = undefined;
    var buf: [2048]u8 = undefined;
    var result: ?*c.struct_passwd = null;
    if (c.getpwuid_r(c.getuid(), &pw, &buf, buf.len, &result) == 0 and result != null) {
        const me = std.mem.span(@as([*:0]const u8, @ptrCast(pw.pw_name)));
        if (std.mem.eql(u8, who, me)) return alloc.dupe(u8, prompt) catch "";
    }
    return std.fmt.allocPrint(alloc, "Password for {s}:", .{who}) catch "";
}

/// The dialog's subtitle: "user@host". Anything that already reads as an
/// annotation ("@", " ", "(") is left alone.
pub fn identitySubtitle(alloc: std.mem.Allocator, identity: []const u8) []const u8 {
    if (identity.len == 0) return "";
    if (std.mem.indexOfAny(u8, identity, " @(") != null) return alloc.dupe(u8, identity) catch "";
    var host: [64]u8 = undefined;
    if (c.gethostname(&host, host.len - 1) != 0 or host[0] == 0) {
        return alloc.dupe(u8, identity) catch "";
    }
    const h = std.mem.sliceTo(&host, 0);
    return std.fmt.allocPrint(alloc, "{s}@{s}", .{ identity, h }) catch "";
}

// -- subject / registration value builders ---------------------------------

fn variant(alloc: std.mem.Allocator, sig: []const u8, val: wire.Value) !wire.Value {
    const p = try alloc.create(wire.Value);
    p.* = val;
    return .{ .variant = .{ .sig = sig, .val = p } };
}

fn dictPair(alloc: std.mem.Allocator, key: []const u8, value: wire.Value) !wire.Value {
    const pair = try alloc.alloc(wire.Value, 2);
    pair[0] = .{ .string = key };
    pair[1] = value;
    return .{ .structure = pair };
}

/// `("unix-session", {"session-id": <id>})`.
pub fn unixSessionSubject(alloc: std.mem.Allocator, id: []const u8) !wire.Value {
    const entries = try alloc.alloc(wire.Value, 1);
    entries[0] = try dictPair(alloc, "session-id", try variant(alloc, "s", .{ .string = id }));
    const s = try alloc.alloc(wire.Value, 2);
    s[0] = .{ .string = "unix-session" };
    s[1] = .{ .array = .{ .elem = "{sv}", .items = entries } };
    return .{ .structure = s };
}

/// `("unix-process", {"pid": <u>, "start-time": <t>})` — the fallback subject
/// when there is no session id to name.
pub fn unixProcessSubject(alloc: std.mem.Allocator, pid: u32, start_time: u64) !wire.Value {
    const entries = try alloc.alloc(wire.Value, 2);
    entries[0] = try dictPair(alloc, "pid", try variant(alloc, "u", .{ .uint32 = pid }));
    entries[1] = try dictPair(alloc, "start-time", try variant(alloc, "t", .{ .uint64 = start_time }));
    const s = try alloc.alloc(wire.Value, 2);
    s[0] = .{ .string = "unix-process" };
    s[1] = .{ .array = .{ .elem = "{sv}", .items = entries } };
    return .{ .structure = s };
}

/// Field 22 of /proc/self/stat (starttime in clock ticks). `comm` may contain
/// spaces, so parsing starts after the last ')'.
pub fn processStartTime(io: std.Io) ?u64 {
    var buf: [512]u8 = undefined;
    const f = std.Io.Dir.cwd().openFile(io, "/proc/self/stat", .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, &buf, 0) catch return null;
    const data = buf[0..n];
    const close_paren = std.mem.lastIndexOfScalar(u8, data, ')') orelse return null;
    var it = std.mem.tokenizeScalar(u8, data[close_paren + 1 ..], ' ');
    var field: usize = 3; // first token after comm is field 3 (state)
    while (it.next()) |tok| : (field += 1) {
        if (field == 22) return std.fmt.parseInt(u64, tok, 10) catch null;
    }
    return null;
}

/// libpolkit's registration locale: LANG, else en_US.UTF-8.
pub fn localeFor(lang: ?[]const u8) []const u8 {
    return lang orelse "en_US.UTF-8";
}

/// `RegisterAuthenticationAgent((sa{sv}) subject, s locale, s path)` args.
pub fn registerArgs(alloc: std.mem.Allocator, subject: wire.Value, locale: []const u8, path: []const u8) ![]wire.Value {
    const args = try alloc.alloc(wire.Value, 3);
    args[0] = subject;
    args[1] = .{ .string = locale };
    args[2] = .{ .string = path };
    return args;
}

/// `UnregisterAuthenticationAgent((sa{sv}) subject, s path)` args.
pub fn unregisterArgs(alloc: std.mem.Allocator, subject: wire.Value, path: []const u8) ![]wire.Value {
    const args = try alloc.alloc(wire.Value, 2);
    args[0] = subject;
    args[1] = .{ .string = path };
    return args;
}

// -- the agent --------------------------------------------------------------

const Pending = struct {
    serial: u32,
    sender: []const u8,
};

pub const Agent = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    session: session_mod.Session,
    hooks: Hooks = .{},

    phase: Phase = .idle,
    /// From accept until the BeginAuthentication reply is sent.
    in_flight: bool = false,
    pending: ?Pending = null,

    // Live request strings (arena-owned).
    action_id: []const u8 = "",
    message: []const u8 = "",
    cookie: []const u8 = "",
    icon_name: []const u8 = "",
    details: []const u8 = "",
    identity: []const u8 = "",
    input_prompt: []const u8 = "",
    prompt_label: []const u8 = "",
    info_line: []const u8 = "",
    supplementary_error: []const u8 = "",
    echo_on: bool = true,
    prompt_active: bool = false,
    /// Drop late prompts from a cancelled session and never re-show the
    /// dialog on one (the C++ `cancel_armed` hazard).
    cancel_armed: bool = false,

    const Self = @This();

    /// Place-first init: call on a stable address, because the session
    /// callbacks point back at the agent itself.
    pub fn init(self: *Self, gpa: std.mem.Allocator, io: std.Io) void {
        self.* = .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .session = session_mod.Session.init(gpa, io),
        };
        self.session.on_message = onSessionMessage;
        self.session.cb_ctx = self;
        self.session.on_stop = onSessionStop;
        self.session.stop_ctx = self;
    }

    pub fn deinit(self: *Self) void {
        if (self.pending) |p| self.gpa.free(p.sender);
        self.session.deinit();
        self.arena.deinit();
    }

    /// Handy for the binary: the session whose fd must be watched right after
    /// `handleBegin`.
    pub fn sessionOf(self: *Self) *session_mod.Session {
        return &self.session;
    }

    pub fn snapshot(self: *Self) Snapshot {
        return .{
            .phase = self.phase,
            .action_id = self.action_id,
            .message = self.message,
            .identity = self.identity,
            .prompt = self.prompt_label,
            .icon_name = self.icon_name,
            .details = self.details,
            .info = self.info_line,
            .err = self.supplementary_error,
            .cookie = self.cookie,
            .echo_on = self.echo_on,
            .has_request = self.prompt_active,
        };
    }

    /// The dialog is up exactly while a live prompt can take an answer.
    pub fn shouldShow(self: *Self) bool {
        return self.prompt_active and self.phase != .idle;
    }

    fn dupe(self: *Self, s: []const u8) []const u8 {
        return self.arena.allocator().dupe(u8, s) catch "";
    }

    fn changed(self: *Self) void {
        if (self.hooks.changed) |cb| cb(self.hooks.ctx);
    }

    fn sendPendingReply(self: *Self) void {
        const p = self.pending orelse return;
        self.pending = null;
        defer self.gpa.free(p.sender);
        if (self.hooks.send_begin_reply) |cb| cb(self.hooks.ctx, p.serial, p.sender);
    }

    /// Single point where a session ends: record the outcome, answer the
    /// deferred BeginAuthentication, and notify the dialog.
    fn finish(self: *Self, gained: bool) void {
        if (!self.in_flight) return;
        self.in_flight = false;
        self.phase = if (gained) .success else .failed;
        self.prompt_active = false;
        self.cancel_armed = false;
        logz.log("svc end_prompt gained={d}", .{@intFromBool(gained)});
        self.sendPendingReply();
        self.changed();
    }

    /// Port of `eh_polkit_listener_initiate_authentication` + the service's
    /// `begin_prompt`: reject busy/no-identity up front, otherwise capture the
    /// request, marshal the reply for later, and start the helper.
    pub fn handleBegin(self: *Self, args: []const wire.Value, serial: u32, sender: []const u8) BeginOutcome {
        if (self.in_flight) {
            logz.log("c initiate_authentication rejected: session already underway", .{});
            return .{ .rejected = "An authentication session is already underway." };
        }
        if (args.len < 6) {
            return .{ .rejected = "Invalid BeginAuthentication arguments." };
        }
        const action_id = asString(args[0]) orelse "";
        const message = asString(args[1]) orelse "";
        const icon_name = asString(args[2]) orelse "";
        const details = args[3];
        const cookie = asString(args[4]) orelse "";
        const identities: []const wire.Value = if (args[5] == .array) args[5].array.items else &.{};
        logz.log("c initiate_authentication enter action='{s}' icon='{s}' cookie='{s}'", .{ action_id, icon_name, cookie });

        if (identities.len < 1) {
            logz.log("c initiate_authentication rejected: no identities", .{});
            return .{ .rejected = "No identities available." };
        }
        const chosen = chooseIdentity(identities) orelse {
            logz.log("c initiate_authentication rejected: no suitable identity", .{});
            return .{ .rejected = "No suitable identity." };
        };

        // This request owns the arena from here on.
        _ = self.arena.reset(.retain_capacity);
        self.action_id = self.dupe(action_id);
        self.message = self.dupe(message);
        self.cookie = self.dupe(cookie);
        self.icon_name = self.dupe(icon_name);
        self.details = flattenDetails(self.arena.allocator(), details) catch "";
        self.identity = humanReadable(self.arena.allocator(), chosen);
        logz.log("svc begin_prompt action='{s}' icon='{s}' cookie='{s}'", .{ self.action_id, self.icon_name, self.cookie });
        self.input_prompt = "";
        self.prompt_label = "";
        self.info_line = "";
        self.supplementary_error = "";
        self.echo_on = true;
        self.prompt_active = false;
        self.cancel_armed = false;
        self.phase = .pending;
        self.in_flight = true;
        self.pending = .{ .serial = serial, .sender = self.gpa.dupe(u8, sender) catch "" };

        // Unsupported identity types behave like libpolkit: the session
        // completes immediately without authorization, and the caller still
        // gets a normal reply.
        const uid = chosen.uid orelse {
            self.finish(false);
            return .accepted;
        };
        const user = userNameForUid(self.arena.allocator(), uid) orelse {
            self.finish(false);
            return .accepted;
        };
        logz.log("c initiate_authentication: session created, calling initiate", .{});
        if (!self.session.start(user, self.cookie)) {
            // No helper to run: same as libpolkit's spawn failure.
            self.finish(false);
            return .accepted;
        }
        // The dialog shows on the first request line (`store_session`).
        return .accepted;
    }

    /// Port of `auth_agent_handle_cancel_authentication`: a known cookie
    /// cancels the session (and is answered immediately); anything else is a
    /// `Failed` naming the cookie.
    pub fn handleCancel(self: *Self, cookie: []const u8) CancelOutcome {
        if (self.in_flight and std.mem.eql(u8, cookie, self.cookie)) {
            logz.log("c on_cancelled (polkitd is cancelling us)", .{});
            self.cancelUser();
            return .accepted;
        }
        const msg = std.fmt.allocPrint(
            self.arena.allocator(),
            "No pending authentication request for cookie '{s}'",
            .{cookie},
        ) catch "No pending authentication request.";
        return .{ .rejected = msg };
    }

    /// Dialog-side cancel (Esc / Cancel / close). Tear down locally first so
    /// the dialog hides even if the helper never reports completion, then
    /// kill it; a late completion is idempotent.
    pub fn cancelUser(self: *Self) void {
        logz.log("svc cancel_session enter have_session={d}", .{@intFromBool(self.session.live())});
        self.phase = .failed;
        self.prompt_active = false;
        self.cancel_armed = true;
        if (self.session.live()) {
            // session.cancel emits failure synchronously, which lands in
            // finish() and answers polkitd.
            self.session.cancel();
        } else {
            self.finish(false);
        }
        self.changed();
    }

    /// The user's answer: hand it to the helper. `session.respond` is inert
    /// when no session is live, so a submit racing a cancel is dropped.
    pub fn submit(self: *Self, response: []const u8) void {
        self.session.respond(response);
    }

    // -- session → agent ----------------------------------------------------

    fn onSessionMessage(ctx: *anyopaque, msg: session_mod.Message) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        switch (msg) {
            .prompt => |p| self.storePrompt(p.text, p.echo),
            .info => |t| self.showInfo(t),
            .err => |t| self.showError(t),
            .success => self.finish(true),
            .failure => self.finish(false),
        }
    }

    fn onSessionStop(ctx: *anyopaque, fd: i32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.hooks.fd_stopped) |cb| cb(self.hooks.ctx, fd);
    }

    fn storePrompt(self: *Self, text: []const u8, echo: bool) void {
        // Drop prompts from a session the user already cancelled: accepting
        // one would re-show the dialog on a dead session and wedge the UI.
        if (self.cancel_armed) {
            logz.log("svc store_session DROPPED (cancel_armed)", .{});
            return;
        }
        self.input_prompt = self.dupe(text);
        self.prompt_label = promptLabelFor(self.arena.allocator(), self.identity, self.input_prompt);
        logz.log("svc store_session echo={d}", .{@intFromBool(echo)});
        self.echo_on = echo;
        self.prompt_active = true;
        self.phase = .active;
        self.changed();
    }

    fn showInfo(self: *Self, text: []const u8) void {
        self.info_line = self.dupe(text);
        self.changed();
    }

    fn showError(self: *Self, text: []const u8) void {
        self.supplementary_error = self.dupe(text);
        self.changed();
    }
};

// -- tests -----------------------------------------------------------------

const testing = std.testing;

fn strVal(comptime k: []const u8, comptime v: []const u8) wire.Value {
    // `structure` is []Value (not const), so the pair lives in a mutable
    // container-level var; each (k, v) instantiation gets its own.
    const S = struct {
        var pair: [2]wire.Value = .{ .{ .string = k }, .{ .string = v } };
    };
    return .{ .structure = &S.pair };
}

/// A `(sa{sv})` identity assembled in caller-owned scratch memory: every
/// slice a `wire.Value` exposes has to outlive the value itself, and an
/// identity built inside a helper would dangle on return.
const IdScratch = struct {
    payload: wire.Value = .{ .uint32 = 0 },
    pair: [2]wire.Value = undefined,
    dict: [1]wire.Value = undefined,
    outer: [2]wire.Value = undefined,

    fn build(self: *IdScratch, kind: []const u8, key: []const u8, payload: wire.Value, sig: []const u8) wire.Value {
        self.payload = payload;
        self.pair = .{ .{ .string = key }, .{ .variant = .{ .sig = sig, .val = &self.payload } } };
        self.dict = .{.{ .structure = &self.pair }};
        self.outer = .{ .{ .string = kind }, .{ .array = .{ .elem = "{sv}", .items = &self.dict } } };
        return .{ .structure = &self.outer };
    }
};

test "chooseIdentity: self, then root, then first unix user" {
    const self_uid: u32 = c.getuid();
    var scratch: [3]IdScratch = undefined;
    var ids = [_]wire.Value{
        scratch[0].build("unix-user", "uid", .{ .uint32 = 0 }, "u"),
        scratch[1].build("unix-user", "uid", .{ .uint32 = self_uid }, "u"),
        scratch[2].build("unix-user", "uid", .{ .uint32 = 1234 }, "u"),
    };
    // Self wins over root and over "first".
    try testing.expectEqual(self_uid, chooseIdentity(&ids).?.uid.?);

    var s2: [2]IdScratch = undefined;
    var ids2 = [_]wire.Value{
        s2[0].build("unix-user", "uid", .{ .uint32 = 1234 }, "u"),
        s2[1].build("unix-user", "uid", .{ .uint32 = 0 }, "u"),
    };
    // Root wins when self is absent.
    try testing.expectEqual(@as(u32, 0), chooseIdentity(&ids2).?.uid.?);

    var s3: [2]IdScratch = undefined;
    var ids3 = [_]wire.Value{
        s3[0].build("unix-user", "uid", .{ .uint32 = 4321 }, "u"),
        s3[1].build("unix-user", "uid", .{ .uint32 = 1234 }, "u"),
    };
    // Neither self nor root: the first unix user.
    try testing.expectEqual(@as(u32, 4321), chooseIdentity(&ids3).?.uid.?);

    var s4: [2]IdScratch = undefined;
    var ids4 = [_]wire.Value{
        s4[0].build("unix-session", "session-id", .{ .string = "2" }, "s"),
        s4[1].build("unix-process", "pid", .{ .uint32 = 99 }, "u"),
    };
    // No unix-user at all: fall back to the first identity of any kind.
    const fallback = chooseIdentity(&ids4).?;
    try testing.expectEqualStrings("unix-session", fallback.kind);
    try testing.expectEqual(@as(?u32, null), fallback.uid);
    try testing.expectEqualStrings("2", fallback.detail);

    try testing.expectEqual(@as(?Chosen, null), chooseIdentity(&[_]wire.Value{}));
}

test "flattenDetails: join, cap and sanitize" {
    var details = [_]wire.Value{
        strVal("polkit.caller-pid", "4242"),
        strVal("polkit.subject-pid", "77"),
        strVal("evil", "a\nb\x7fc"),
    };
    const got = try flattenDetails(testing.allocator, .{ .array = .{ .elem = "{ss}", .items = &details } });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("polkit.caller-pid=4242, polkit.subject-pid=77, evil=a b c", got);

    // Cap: once the run reaches 512 bytes it stops with "...".
    var many: [64]wire.Value = undefined;
    for (&many) |*m| {
        m.* = strVal(
            "kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk",
            "vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv",
        );
    }
    const big = try flattenDetails(testing.allocator, .{ .array = .{ .elem = "{ss}", .items = &many } });
    defer testing.allocator.free(big);
    try testing.expect(big.len >= 512);
    try testing.expect(std.mem.endsWith(u8, big, "..."));
}

test "promptLabelFor: rewrites only for another user" {
    const a1 = testing.allocator;
    var buf: [2048]u8 = undefined;
    var pw: c.struct_passwd = undefined;
    var result: ?*c.struct_passwd = null;
    try testing.expect(c.getpwuid_r(c.getuid(), &pw, &buf, buf.len, &result) == 0);
    const me = std.mem.span(@as([*:0]const u8, @ptrCast(pw.pw_name)));

    // Self: bare prompt stays.
    {
        const got = promptLabelFor(a1, me, "Password:");
        defer a1.free(got);
        try testing.expectEqualStrings("Password:", got);
    }
    // Another user: rewritten, with "Full Name (user)" shortened.
    {
        const got = promptLabelFor(a1, "Root Admin (root)", "Password: ");
        defer a1.free(got);
        try testing.expectEqualStrings("Password for root:", got);
    }
    // Non-password prompts are untouched.
    {
        const got = promptLabelFor(a1, "someone", "Login:");
        defer a1.free(got);
        try testing.expectEqualStrings("Login:", got);
    }
    // "Password:" with trailing junk is untouched.
    {
        const got = promptLabelFor(a1, "someone", "Password: (again)");
        defer a1.free(got);
        try testing.expectEqualStrings("Password: (again)", got);
    }
}

test "identitySubtitle: annotates plain names only" {
    const a1 = testing.allocator;
    try testing.expectEqualStrings("", identitySubtitle(a1, ""));
    {
        const got = identitySubtitle(a1, "Full Name (matt)");
        defer a1.free(got);
        try testing.expectEqualStrings("Full Name (matt)", got);
    }
    {
        const got = identitySubtitle(a1, "matt");
        defer a1.free(got);
        // Either "matt@host" or bare "matt" when hostname is unavailable.
        if (std.mem.indexOfScalar(u8, got, '@')) |_| {
            try testing.expect(std.mem.startsWith(u8, got, "matt@"));
        } else {
            try testing.expectEqualStrings("matt", got);
        }
    }
}

test "subjects: polkit encodings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const sess = try unixSessionSubject(aa, "2");
    try testing.expectEqualStrings("unix-session", sess.structure[0].string);
    const sess_dict = sess.structure[1].array;
    try testing.expectEqual(@as(usize, 1), sess_dict.items.len);
    const pair0 = sess_dict.items[0].structure;
    try testing.expectEqualStrings("session-id", pair0[0].string);
    try testing.expectEqualStrings("2", pair0[1].variant.val.string);
    try testing.expectEqualStrings("s", pair0[1].variant.sig);

    const proc = try unixProcessSubject(aa, 4242, 987654);
    try testing.expectEqualStrings("unix-process", proc.structure[0].string);
    const proc_dict = proc.structure[1].array;
    try testing.expectEqual(@as(usize, 2), proc_dict.items.len);
    try testing.expectEqualStrings("pid", proc_dict.items[0].structure[0].string);
    try testing.expectEqual(@as(u32, 4242), proc_dict.items[0].structure[1].variant.val.uint32);
    try testing.expectEqualStrings("t", proc_dict.items[1].structure[1].variant.sig);
    try testing.expectEqual(@as(u64, 987654), proc_dict.items[1].structure[1].variant.val.uint64);

    try testing.expectEqualStrings("en_US.UTF-8", localeFor(null));
    try testing.expectEqualStrings("de_DE.UTF-8", localeFor("de_DE.UTF-8"));
}
