//! Notification D-Bus service — owns `org.freedesktop.Notifications`.
//!
//! Methods: `Notify` (sanitize + rules + DND gate, returns the live id, 0
//! when DND drops it), `CloseNotification` (errors NotFound when unknown),
//! `GetCapabilities` (`["body", "actions"]`), `GetServerInformation`,
//! the `ListNotifications` extension (live set as `aa{sv}`), and
//! `TriggerAction` (errors InvalidAction; never closes — the UX decides).
//! Signals `NotificationClosed(u,u)` / `ActionInvoked(u,s)` go out over the
//! same `object.Tree`. `shellDismiss(All)` and `sweepExpired` are the
//! shell-side close paths; both emit the close signal.
//!
//! Wire shapes mirror the spec: actions arrive `as`, hints `a{sv}`, and the
//! `image-data` variant carries `(iiibiiay)`. Handler outputs live in the
//! dispatch arena; everything the manager keeps is duped by the manager.

const std = @import("std");
const wire = @import("../dbus/wire.zig");
const object = @import("../dbus/object.zig");
const connection = @import("../dbus/connection.zig");
const manager_mod = @import("notify_manager.zig");
const schema2 = @import("../config/schema2.zig");

pub const bus_name = "org.freedesktop.Notifications";
pub const object_path = "/org/freedesktop/Notifications";
pub const interface = "org.freedesktop.Notifications";
pub const kMaxStringLen: usize = 1024;
pub const kVersion = "0.9.7.3-beta-3";

const Manager = manager_mod.Manager;
const Urgency = manager_mod.Urgency;

// Pure input shaping — unit-tested without a bus

pub fn clampStr(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    return alloc.dupe(u8, s[0..@min(s.len, kMaxStringLen)]);
}

/// Strip tags (`<br>`/`<br/>`/`<br />` become newlines), decode the five
/// entities, pass everything else through.
pub fn sanitizeMarkup(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '<') {
            if (std.mem.indexOfScalar(u8, s[i + 1 ..], '>')) |rel| {
                const tag = s[i + 1 .. i + 1 + rel];
                if (isBrTag(tag)) {
                    try out.append(alloc, '\n');
                }
                i += rel + 2;
                continue;
            }
        }
        if (s[i] == '&') {
            const rest = s[i..];
            if (std.mem.startsWith(u8, rest, "&lt;")) {
                try out.append(alloc, '<');
                i += 4;
                continue;
            } else if (std.mem.startsWith(u8, rest, "&gt;")) {
                try out.append(alloc, '>');
                i += 4;
                continue;
            } else if (std.mem.startsWith(u8, rest, "&amp;")) {
                try out.append(alloc, '&');
                i += 5;
                continue;
            } else if (std.mem.startsWith(u8, rest, "&quot;")) {
                try out.append(alloc, '"');
                i += 6;
                continue;
            } else if (std.mem.startsWith(u8, rest, "&apos;")) {
                try out.append(alloc, '\'');
                i += 6;
                continue;
            }
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn isBrTag(tag: []const u8) bool {
    // ASCII-lower compare without allocating.
    if (tag.len == 2 and (tag[0] | 32) == 'b' and (tag[0 + 1] | 32) == 'r') return true;
    if (tag.len == 3 and (tag[0] | 32) == 'b' and (tag[1] | 32) == 'r' and tag[2] == '/') return true;
    if (tag.len == 4 and (tag[0] | 32) == 'b' and (tag[1] | 32) == 'r' and tag[2] == ' ' and tag[3] == '/') return true;
    return false;
}

fn isBlank(s: []const u8) bool {
    if (s.len == 0) return true;
    for (s) |c| {
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != 0x0b and c != 0x0c) return false;
    }
    return true;
}

/// Even key/text pairs, clamped; blank labels become "Action", empty keys
/// are dropped (with their label), a trailing odd key is dropped.
pub fn sanitizeActions(alloc: std.mem.Allocator, actions: []const []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |a| alloc.free(a);
        out.deinit(alloc);
    }
    var i: usize = 0;
    while (i + 1 < actions.len) : (i += 2) {
        const key = try clampStr(alloc, actions[i]);
        errdefer alloc.free(key);
        if (key.len == 0) {
            alloc.free(key);
            continue;
        }
        var label = try clampStr(alloc, actions[i + 1]);
        if (isBlank(label)) {
            alloc.free(label);
            label = try alloc.dupe(u8, "Action");
        }
        try out.append(alloc, key);
        try out.append(alloc, label);
    }
    return out.toOwnedSlice(alloc);
}

pub const ParsedHints = struct {
    urgency: Urgency = .normal,
    icon: ?[]const u8 = null, // borrowed
    category: ?[]const u8 = null, // borrowed
    desktop_entry: ?[]const u8 = null, // borrowed
    image: ?RawImage = null,
};

/// The `(iiibiiay)` blob, still in wire form: pixel bytes must be compacted
/// (`compactImagePixels`) because a decoded `ay` is one `Value` per byte.
pub const RawImage = struct {
    width: i32 = 0,
    height: i32 = 0,
    row_stride: i32 = 0,
    has_alpha: bool = true,
    bits_per_sample: i32 = 8,
    channels: i32 = 4,
    items: []const wire.Value = &.{},
};

/// Pack the one-`Value`-per-byte items into a contiguous slice for the
/// manager (which dupes it into its own memory). Null when any item is not
/// a byte — a malformed blob, not an image.
pub fn compactImagePixels(alloc: std.mem.Allocator, items: []const wire.Value) ?[]u8 {
    if (items.len == 0) return &.{};
    const out = alloc.alloc(u8, items.len) catch return null;
    for (items, 0..) |b, i| {
        if (b != .byte) {
            alloc.free(out);
            return null;
        }
        out[i] = b.byte;
    }
    return out;
}

fn hintStr(hints: []const wire.Value, key: []const u8) ?[]const u8 {
    for (hints) |h| {
        if (h != .structure or h.structure.len != 2) continue;
        if (h.structure[0] != .string) continue;
        if (!std.mem.eql(u8, h.structure[0].string, key)) continue;
        if (h.structure[1] != .variant) continue;
        const v = h.structure[1].variant.val.*;
        if (v == .string) return v.string;
    }
    return null;
}

fn hintVariant(hints: []const wire.Value, key: []const u8) ?wire.Value {
    for (hints) |h| {
        if (h != .structure or h.structure.len != 2) continue;
        if (h.structure[0] != .string) continue;
        if (!std.mem.eql(u8, h.structure[0].string, key)) continue;
        if (h.structure[1] != .variant) continue;
        return h.structure[1].variant.val.*;
    }
    return null;
}

fn asI32(v: wire.Value) ?i32 {
    return switch (v) {
        .int32 => |x| x,
        else => null,
    };
}

/// `(iiibiiay)` image blob from `image-data` / `image_data` / `icon_data`.
pub fn parseImageData(v: wire.Value) ?RawImage {
    const s = switch (v) {
        .variant => |vr| switch (vr.val.*) {
            .structure => |st| st,
            else => return null,
        },
        .structure => |st| st,
        else => return null,
    };
    if (s.len != 7) return null;
    const w = asI32(s[0]) orelse return null;
    const h = asI32(s[1]) orelse return null;
    const stride = asI32(s[2]) orelse return null;
    const alpha = switch (s[3]) {
        .boolean => |b| b,
        else => return null,
    };
    const bps = asI32(s[4]) orelse return null;
    const ch = asI32(s[5]) orelse return null;
    const items = switch (s[6]) {
        .array => |a| a.items,
        else => return null,
    };
    if (w <= 0 or h <= 0) return null;
    return .{
        .width = w,
        .height = h,
        .row_stride = stride,
        .has_alpha = alpha,
        .bits_per_sample = bps,
        .channels = ch,
        .items = items,
    };
}

pub fn parseHints(hints: []const wire.Value, app_icon: []const u8) ParsedHints {
    var out = ParsedHints{};
    if (hintVariant(hints, "urgency")) |v| {
        const raw: ?u8 = switch (v) {
            .byte => |b| b,
            else => null,
        };
        if (raw) |r| {
            out.urgency = switch (r) {
                0 => .low,
                2 => .critical,
                else => .normal,
            };
        }
    }
    if (app_icon.len > 0) out.icon = app_icon;
    if (hintStr(hints, "image-path")) |s| out.icon = s;
    if (hintStr(hints, "image_path")) |s| out.icon = s;
    if (hintStr(hints, "category")) |s| out.category = s;
    if (hintStr(hints, "desktop-entry")) |s| out.desktop_entry = s;
    for ([_][]const u8{ "image-data", "image_data", "icon_data" }) |k| {
        if (hintVariant(hints, k)) |v| {
            if (parseImageData(v)) |img| {
                out.image = img;
                break;
            }
        }
    }
    return out;
}

pub const RuleDecision = struct {
    silent: bool = false,
    transient: bool = false,
    bypass_dnd: bool = false,
    matched: bool = false,
};

fn lowerContains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// First rule whose `match` is a case-insensitive substring of the app name
/// or desktop entry decides: urgency gate → silent, `!showToast` → silent,
/// `!saveHistory` → transient.
pub fn applyRules(
    rules: []const schema2.NotificationRule,
    app_name: []const u8,
    desktop_entry: ?[]const u8,
    urgency: Urgency,
) RuleDecision {
    for (rules) |r| {
        if (r.match.len == 0) continue;
        const app_hit = lowerContains(app_name, r.match);
        const entry_hit = if (desktop_entry) |e| lowerContains(e, r.match) else false;
        if (!app_hit and !entry_hit) continue;
        var d = RuleDecision{ .matched = true, .bypass_dnd = r.bypass_dnd };
        const ok = switch (urgency) {
            .low => r.allow_low,
            .normal => r.allow_normal,
            .critical => r.allow_critical,
        };
        if (!ok) d.silent = true;
        if (!r.show_toast) d.silent = true;
        if (!r.save_history) d.transient = true;
        return d;
    }
    return .{};
}

// Service — manager + Tree wiring

pub const Service = struct {
    alloc: std.mem.Allocator,
    mgr: *Manager,
    tree: *object.Tree,
    rules: []const schema2.NotificationRule = &.{},
    methods: [6]object.Method = undefined,
    vtables: [1]object.VTable = undefined,

    pub fn init(alloc: std.mem.Allocator, mgr: *Manager, tree: *object.Tree) *Service {
        const self = alloc.create(Service) catch @panic("notify service OOM");
        self.* = .{ .alloc = alloc, .mgr = mgr, .tree = tree };
        const ctx: *anyopaque = @ptrCast(self);
        self.methods = .{
            .{ .name = "Notify", .in_sig = "susssasa{sv}i", .out_sig = "u", .handler = onNotify, .ctx = ctx },
            .{ .name = "CloseNotification", .in_sig = "u", .out_sig = "", .handler = onClose, .ctx = ctx },
            .{ .name = "GetCapabilities", .in_sig = "", .out_sig = "as", .handler = onCaps, .ctx = ctx },
            .{ .name = "GetServerInformation", .in_sig = "", .out_sig = "ssss", .handler = onServerInfo, .ctx = ctx },
            .{ .name = "ListNotifications", .in_sig = "", .out_sig = "aa{sv}", .handler = readNotifications, .ctx = ctx },
            .{ .name = "TriggerAction", .in_sig = "us", .out_sig = "", .handler = fireAction, .ctx = ctx },
        };
        self.vtables = .{.{
            .interface = interface,
            .methods = &self.methods,
            .signals = &.{
                .{ .name = "NotificationClosed", .sig = "uu" },
                .{ .name = "ActionInvoked", .sig = "us" },
            },
        }};
        tree.addObject(object_path, &self.vtables) catch @panic("notify object OOM");
        mgr.setActionHandler(actionEmitted, ctx);
        return self;
    }

    pub fn deinit(self: *Service) void {
        self.mgr.setActionHandler(null, null);
        self.alloc.destroy(self);
    }

    pub fn setRules(self: *Service, rules: []const schema2.NotificationRule) void {
        self.rules = rules;
    }

    fn emitClosed(self: *Service, id: u32, reason: manager_mod.CloseReason) void {
        const body = [_]wire.Value{
            .{ .uint32 = id },
            .{ .uint32 = @intFromEnum(reason) },
        };
        self.tree.emitSignal(object_path, interface, "NotificationClosed", "uu", &body) catch {};
    }

    fn emitAction(self: *Service, id: u32, key: []const u8) void {
        const body = [_]wire.Value{
            .{ .uint32 = id },
            .{ .string = key },
        };
        self.tree.emitSignal(object_path, interface, "ActionInvoked", "us", &body) catch {};
    }

    /// Shell-initiated dismiss (toast X, CC clear): close + signal.
    pub fn shellDismiss(self: *Service, id: u32) void {
        if (!self.mgr.close(id, .dismissed)) return;
        self.emitClosed(id, .dismissed);
    }

    pub fn shellDismissAll(self: *Service) void {
        const items = self.mgr.all();
        var ids: [64]u32 = undefined;
        var n: usize = 0;
        for (items) |it| {
            if (n >= ids.len) break;
            ids[n] = it.id;
            n += 1;
        }
        for (ids[0..n]) |id| self.shellDismiss(id);
    }

    /// Expiry with the close signal per id (the standalone timer calls this,
    /// not `Manager.sweepExpired`, precisely so clients hear about it).
    pub fn sweepExpired(self: *Service) void {
        const ids = self.mgr.expiredList(self.alloc);
        defer self.alloc.free(ids);
        for (ids) |id| {
            if (self.mgr.close(id, .expired)) self.emitClosed(id, .expired);
        }
    }
};

fn serviceOf(ctx: *anyopaque) *Service {
    return @ptrCast(@alignCast(ctx));
}

fn argStr(args: []const wire.Value, i: usize) []const u8 {
    if (i >= args.len) return "";
    return switch (args[i]) {
        .string => |s| s,
        .object_path => |s| s,
        else => "",
    };
}

fn argU32(args: []const wire.Value, i: usize) u32 {
    if (i >= args.len) return 0;
    return switch (args[i]) {
        .uint32 => |x| x,
        else => 0,
    };
}

fn argI32(args: []const wire.Value, i: usize) i32 {
    if (i >= args.len) return 0;
    return switch (args[i]) {
        .int32 => |x| x,
        else => 0,
    };
}

fn argStrList(alloc: std.mem.Allocator, args: []const wire.Value, i: usize) [][]const u8 {
    if (i >= args.len) return &.{};
    const arr = switch (args[i]) {
        .array => |a| a,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (arr.items) |v| {
        if (v == .string) out.append(alloc, v.string) catch return out.toOwnedSlice(alloc) catch &.{};
    }
    return out.toOwnedSlice(alloc) catch &.{};
}

fn onNotify(alloc: std.mem.Allocator, ctx: *anyopaque, args: []const wire.Value) object.MethodResult {
    const self = serviceOf(ctx);
    const app_name = argStr(args, 0);
    const replaces_id = argU32(args, 1);
    const app_icon = argStr(args, 2);
    const summary = argStr(args, 3);
    const body = argStr(args, 4);
    const raw_actions = argStrList(alloc, args, 5);
    defer alloc.free(raw_actions);
    const hints = if (args.len > 6) switch (args[6]) {
        .array => |a| a.items,
        else => &.{},
    } else &.{};
    var timeout: i32 = argI32(args, 7);
    if (timeout < 0) timeout = self.mgr.server_default_timeout_ms;

    const sanitized = sanitizeActions(alloc, raw_actions) catch {
        return .{ .err = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .message = "out of memory" } };
    };
    defer {
        for (sanitized) |a| alloc.free(a);
        alloc.free(sanitized);
    }
    const hints_parsed = parseHints(hints, app_icon);

    const decision = applyRules(self.rules, app_name, hints_parsed.desktop_entry, hints_parsed.urgency);
    // DND drops the post outright (id 0), unless a matched rule bypasses it.
    // NOTE: replies must live in the dispatch arena — `dispatch` marshals
    // them AFTER the handler returns, so stack arrays dangle (crashed once
    // as "invalid enum value" in the marshaller).
    if (self.mgr.do_not_disturb and !(decision.matched and decision.bypass_dnd)) {
        const vals = alloc.alloc(wire.Value, 1) catch {
            return .{ .err = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .message = "out of memory" } };
        };
        vals[0] = .{ .uint32 = 0 };
        return .{ .ok = vals };
    }

    const app = clampStr(alloc, app_name) catch {
        return .{ .err = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .message = "out of memory" } };
    };
    defer alloc.free(app);
    const summ_raw = clampStr(alloc, summary) catch {
        return .{ .err = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .message = "out of memory" } };
    };
    defer alloc.free(summ_raw);
    const body_raw = clampStr(alloc, body) catch {
        return .{ .err = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .message = "out of memory" } };
    };
    defer alloc.free(body_raw);
    const summ = sanitizeMarkup(alloc, summ_raw) catch summ_raw;
    const body_clean = sanitizeMarkup(alloc, body_raw) catch body_raw;
    // sanitizeMarkup allocates on success; on failure it returns the input
    // borrow, so only free what it actually allocated.
    const summ_owned = summ.ptr != summ_raw.ptr;
    const body_owned = body_clean.ptr != body_raw.ptr;
    defer if (summ_owned) alloc.free(summ);
    defer if (body_owned) alloc.free(body_clean);

    const id = self.mgr.addOrUpdate(replaces_id, .{
        .app_name = app,
        .summary = summ,
        .body = body_clean,
        .urgency = hints_parsed.urgency,
        .timeout_ms = timeout,
        .origin = .external,
        .actions = sanitized,
        .icon = hints_parsed.icon,
        .image = if (hints_parsed.image) |raw| blk: {
            const pixels = compactImagePixels(alloc, raw.items) orelse break :blk null;
            break :blk manager_mod.ImageData{
                .width = raw.width,
                .height = raw.height,
                .row_stride = raw.row_stride,
                .has_alpha = raw.has_alpha,
                .bits_per_sample = raw.bits_per_sample,
                .channels = raw.channels,
                .pixels = pixels,
            };
        } else null,
        .category = hints_parsed.category,
        .desktop_entry = hints_parsed.desktop_entry,
        .silent = decision.silent,
        .transient = decision.transient,
    });
    const vals = alloc.alloc(wire.Value, 1) catch {
        return .{ .err = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .message = "out of memory" } };
    };
    vals[0] = .{ .uint32 = id };
    return .{ .ok = vals };
}

fn onClose(alloc: std.mem.Allocator, ctx: *anyopaque, args: []const wire.Value) object.MethodResult {
    _ = alloc;
    const self = serviceOf(ctx);
    const id = argU32(args, 0);
    if (!self.mgr.close(id, .closed_by_call)) {
        return .{ .err = .{
            .name = "org.freedesktop.Notifications.Error.NotFound",
            .message = "no notification with that id",
        } };
    }
    self.emitClosed(id, .closed_by_call);
    return .{ .ok = &.{} };
}

fn onCaps(alloc: std.mem.Allocator, ctx: *anyopaque, args: []const wire.Value) object.MethodResult {
    _ = ctx;
    _ = args;
    const items = alloc.alloc(wire.Value, 2) catch {
        return .{ .err = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .message = "out of memory" } };
    };
    items[0] = .{ .string = "body" };
    items[1] = .{ .string = "actions" };
    const arr = alloc.alloc(wire.Value, 1) catch {
        return .{ .err = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .message = "out of memory" } };
    };
    arr[0] = .{ .array = .{ .elem = "s", .items = items } };
    return .{ .ok = arr };
}

fn onServerInfo(alloc: std.mem.Allocator, ctx: *anyopaque, args: []const wire.Value) object.MethodResult {
    _ = ctx;
    _ = args;
    const vals = alloc.alloc(wire.Value, 4) catch {
        return .{ .err = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .message = "out of memory" } };
    };
    vals[0] = .{ .string = "EventHorizon" };
    vals[1] = .{ .string = "Event Horizon" };
    vals[2] = .{ .string = kVersion };
    vals[3] = .{ .string = "1.2" };
    return .{ .ok = vals };
}

fn putNotifProp(alloc: std.mem.Allocator, dict: *std.ArrayList(wire.Value), k: []const u8, v: wire.Value) !void {
    const pair = try alloc.alloc(wire.Value, 2);
    pair[0] = .{ .string = k };
    const box = try alloc.create(wire.Value);
    box.* = v;
    const sig: []const u8 = switch (v) {
        .uint32 => "u",
        .int32 => "i",
        .string => "s",
        else => "s",
    };
    pair[1] = .{ .variant = .{ .sig = sig, .val = box } };
    try dict.append(alloc, .{ .structure = pair });
}

fn readNotifications(alloc: std.mem.Allocator, ctx: *anyopaque, args: []const wire.Value) object.MethodResult {
    _ = args;
    const self = serviceOf(ctx);
    var rows: std.ArrayList(wire.Value) = .empty;
    errdefer rows.deinit(alloc);
    for (self.mgr.all()) |*n| {
        var dict: std.ArrayList(wire.Value) = .empty;
        errdefer dict.deinit(alloc);
        putNotifProp(alloc, &dict, "id", .{ .uint32 = n.id }) catch continue;
        putNotifProp(alloc, &dict, "app_name", .{ .string = n.app_name }) catch continue;
        putNotifProp(alloc, &dict, "summary", .{ .string = n.summary }) catch continue;
        putNotifProp(alloc, &dict, "body", .{ .string = n.body }) catch continue;
        putNotifProp(alloc, &dict, "timeout", .{ .int32 = n.timeout_ms }) catch continue;
        putNotifProp(alloc, &dict, "urgency", .{ .uint32 = @intFromEnum(n.urgency) }) catch continue;
        // actions is a string list; wrap the array in a variant of sig "as".
        const acts = alloc.alloc(wire.Value, n.actions.len) catch continue;
        for (n.actions, 0..) |a, i| acts[i] = .{ .string = a };
        const abox = alloc.create(wire.Value) catch {
            alloc.free(acts);
            continue;
        };
        abox.* = .{ .array = .{ .elem = "s", .items = acts } };
        const apair = alloc.alloc(wire.Value, 2) catch {
            alloc.free(acts);
            continue;
        };
        apair[0] = .{ .string = "actions" };
        apair[1] = .{ .variant = .{ .sig = "as", .val = abox } };
        dict.append(alloc, .{ .structure = apair }) catch continue;
        putNotifProp(alloc, &dict, "icon", .{ .string = n.icon orelse "" }) catch continue;
        putNotifProp(alloc, &dict, "category", .{ .string = n.category orelse "" }) catch continue;
        putNotifProp(alloc, &dict, "desktop_entry", .{ .string = n.desktop_entry orelse "" }) catch continue;
        const items = dict.toOwnedSlice(alloc) catch continue;
        rows.append(alloc, .{ .array = .{ .elem = "{sv}", .items = items } }) catch {
            alloc.free(items);
            continue;
        };
    }
    const all = rows.toOwnedSlice(alloc) catch {
        return .{ .err = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .message = "out of memory" } };
    };
    const out = alloc.alloc(wire.Value, 1) catch {
        alloc.free(all);
        return .{ .err = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .message = "out of memory" } };
    };
    out[0] = .{ .array = .{ .elem = "a{sv}", .items = all } };
    return .{ .ok = out };
}

fn fireAction(alloc: std.mem.Allocator, ctx: *anyopaque, args: []const wire.Value) object.MethodResult {
    _ = alloc;
    const self = serviceOf(ctx);
    const id = argU32(args, 0);
    const key = argStr(args, 1);
    if (key.len == 0 or key.len > kMaxStringLen) {
        return .{ .err = .{
            .name = "org.freedesktop.Notifications.Error.InvalidAction",
            .message = "an action key is required",
        } };
    }
    // No close here: the UX (toast click vs CC row) decides, via `silent`;
    // `triggerAction` runs the action with `close_after=false`.
    if (!self.mgr.triggerAction(id, key[0..@min(key.len, kMaxStringLen)], false)) {
        return .{ .err = .{
            .name = "org.freedesktop.Notifications.Error.InvalidAction",
            .message = "this notification offers no such action",
        } };
    }
    return .{ .ok = &.{} };
}

fn actionEmitted(ctx: ?*anyopaque, id: u32, key: []const u8) void {
    if (ctx == null) return;
    serviceOf(ctx.?).emitAction(id, key);
}

/// Take `org.freedesktop.Notifications` unless someone already owns it.
/// Returns false when another daemon won (defer to the winner).
pub fn claimBusName(conn: *connection.Conn) bool {
    // NameHasOwner(org.freedesktop.Notifications) -> bool.
    const arg = [_]wire.Value{.{ .string = bus_name }};
    const has_owner = blk: {
        const reply = conn.call(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "NameHasOwner",
            .destination = "org.freedesktop.DBus",
            .signature = "s",
            .body = &arg,
        }, 3000) catch return false;
        var p = reply;
        defer p.deinit();
        if (p.body_vals.len < 1 or p.body_vals[0] != .boolean) break :blk false;
        break :blk p.body_vals[0].boolean;
    };
    if (has_owner) return false;
    _ = conn.requestName(bus_name, 3000) catch return false;
    return true;
}

// Tests — pure shaping only; no bus needed.

test "notify-service: markup sanitize" {
    const t = std.testing;
    const a = t.allocator;
    const s1 = try sanitizeMarkup(a, "a<br>b<BR/>c<br />d<blink>e</blink>");
    defer a.free(s1);
    try t.expectEqualStrings("a\nb\nc\nde", s1);
    const s2 = try sanitizeMarkup(a, "&lt;&gt;&amp;&quot;&apos;&bogus;");
    defer a.free(s2);
    try t.expectEqualStrings("<>&\"'&bogus;", s2);
    const s3 = try sanitizeMarkup(a, "plain");
    defer a.free(s3);
    try t.expectEqualStrings("plain", s3);
    const s4 = try sanitizeMarkup(a, "a<b");
    defer a.free(s4);
    try t.expectEqualStrings("a<b", s4);
}

test "notify-service: actions sanitize" {
    const t = std.testing;
    const a = t.allocator;
    const raw = [_][]const u8{ "open", "Open", "", "dropped", "mute", "   ", "odd" };
    const out = try sanitizeActions(a, &raw);
    defer {
        for (out) |s| a.free(s);
        a.free(out);
    }
    // Empty key (+ label) dropped, blank label defaulted, trailing odd dropped.
    try t.expectEqual(@as(usize, 4), out.len);
    try t.expectEqualStrings("open", out[0]);
    try t.expectEqualStrings("Open", out[1]);
    try t.expectEqualStrings("mute", out[2]);
    try t.expectEqualStrings("Action", out[3]);
}

test "notify-service: hints parse incl image struct" {
    const t = std.testing;
    const a = t.allocator;
    // Heap-built, like real arena-parsed messages (avoids `var` scaffolding).
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const urg = try aa.create(wire.Value);
    urg.* = .{ .byte = 2 };
    const cat = try aa.create(wire.Value);
    cat.* = .{ .string = "email" };
    const pix_items = try aa.alloc(wire.Value, 1);
    pix_items[0] = .{ .byte = 1 };
    const parts = try aa.alloc(wire.Value, 7);
    parts[0] = .{ .int32 = 2 };
    parts[1] = .{ .int32 = 2 };
    parts[2] = .{ .int32 = 8 };
    parts[3] = .{ .boolean = true };
    parts[4] = .{ .int32 = 8 };
    parts[5] = .{ .int32 = 4 };
    parts[6] = .{ .array = .{ .elem = "y", .items = pix_items } };
    const st = try aa.create(wire.Value);
    st.* = .{ .structure = parts };
    const up = try aa.alloc(wire.Value, 2);
    up[0] = .{ .string = "urgency" };
    up[1] = .{ .variant = .{ .sig = "y", .val = urg } };
    const cp = try aa.alloc(wire.Value, 2);
    cp[0] = .{ .string = "category" };
    cp[1] = .{ .variant = .{ .sig = "s", .val = cat } };
    const ip = try aa.alloc(wire.Value, 2);
    ip[0] = .{ .string = "image-data" };
    ip[1] = .{ .variant = .{ .sig = "(iiibiiay)", .val = st } };
    const all = try aa.alloc(wire.Value, 3);
    all[0] = .{ .structure = up };
    all[1] = .{ .structure = cp };
    all[2] = .{ .structure = ip };
    const h = parseHints(all, "myapp");
    try t.expectEqual(Urgency.critical, h.urgency);
    try t.expectEqualStrings("myapp", h.icon.?);
    try t.expectEqualStrings("email", h.category.?);
    try t.expect(h.image != null);
    try t.expectEqual(@as(i32, 2), h.image.?.width);
    try t.expectEqual(@as(usize, 1), h.image.?.items.len);
    const compacted = compactImagePixels(a, h.image.?.items) orelse return error.TestUnexpectedResult;
    defer a.free(compacted);
    try t.expectEqual(@as(usize, 1), compacted.len);
    try t.expectEqual(@as(u8, 1), compacted[0]);
}

test "notify-service: rules match, gate urgency, and fall back" {
    const t = std.testing;
    const rules = [_]schema2.NotificationRule{
        .{ .name = "chat", .match = "discord", .show_toast = true },
        .{ .name = "quiet", .match = "spam", .show_toast = false, .allow_normal = false },
        .{ .name = "vip", .match = "boss", .bypass_dnd = true },
    };
    // Case-insensitive app substring.
    const d1 = applyRules(&rules, "Discord-Canary", null, .normal);
    try t.expect(d1.matched and !d1.silent and !d1.transient);
    // Urgency gate: normal disallowed -> silent (but not transient).
    const d2 = applyRules(&rules, "spam-app", null, .normal);
    try t.expect(d2.matched and d2.silent and !d2.transient);
    // show_toast=false -> silent regardless of urgency.
    const d2b = applyRules(&rules, "spam-app", null, .critical);
    try t.expect(d2b.silent);
    // Desktop-entry fallback.
    const d3 = applyRules(&rules, "Something", "com.discord.App", .low);
    try t.expect(d3.matched);
    // Bypass flag rides along for the DND gate.
    const d4 = applyRules(&rules, "boss-mail", null, .normal);
    try t.expect(d4.matched and d4.bypass_dnd and !d4.silent);
    // No match: everything default.
    const d5 = applyRules(&rules, "other", null, .normal);
    try t.expect(!d5.matched and !d5.silent and !d5.transient and !d5.bypass_dnd);
}
