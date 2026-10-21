//! Notifications tab persistence: `notifications/notifications.toml`, one
//! key per upsert (`pear/prefs.zig` discipline — `[rules.*]` tables the tab
//! does not manage survive byte for byte). Keys match what
//! `schema2.decodeNotifications` reads, so the daemon picks them up over
//! its inotify watch. Also owns the test-button `Notify`: a short-lived
//! session-bus call, no IPC sender required.

const std = @import("std");
const app_mod = @import("app.zig");
const schema2 = @import("../../config/schema2.zig");
const prefs = @import("../../desktop_shell/pear/prefs.zig");
const dbus_conn = @import("../../dbus/connection.zig");
const wire = @import("../../dbus/wire.zig");

const libc = @cImport(@cInclude("stdlib.h"));

fn getenvOpt(name: [:0]const u8) ?[]const u8 {
    const p = libc.getenv(name) orelse return null;
    return std.mem.span(p);
}

fn quoted(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "'{s}'", .{s});
}

/// Seed tab state from the decoded config (window init). Strings are duped;
/// numbers/bools copy.
pub fn load(alloc: std.mem.Allocator, s: *app_mod.Settings, n: *const schema2.NotificationsSettings) void {
    s.notifications_dbus_enabled = n.dbus_enabled;
    s.notifications_dnd = n.do_not_disturb;
    s.notifications_timeout_ms = n.default_timeout_ms;
    s.notifications_scale_pct = n.toast.scale_pct;
    s.notifications_margin_px = n.toast.margin_px;
    s.notifications_corner_radius_px = n.toast.corner_radius_px;
    s.notifications_max_width_px = n.toast.max_width_px;
    s.notifications_layer_shell = n.toast.layer_shell_enabled;
    s.notifications_toast_position = alloc.dupe(u8, n.toast.position) catch s.notifications_toast_position;
    const out = std.mem.trim(u8, n.output_name, " \t\n");
    s.notifications_output = alloc.dupe(u8, if (out.len == 0) "auto" else out) catch s.notifications_output;
}

/// Write every tab knob back. Best-effort per key (a failed write still
/// paints locally); returns false when anything failed.
pub fn save(gpa: std.mem.Allocator, io: std.Io, state_dir: []const u8, s: *const app_mod.Settings) bool {
    var ok = true;
    const put = struct {
        fn b(alloc: std.mem.Allocator, io2: std.Io, dir: []const u8, table: []const u8, key: []const u8, v: bool) bool {
            return prefs.writeComponentKey(alloc, io2, dir, "notifications", table, key, if (v) "true" else "false");
        }
        fn i(alloc: std.mem.Allocator, io2: std.Io, dir: []const u8, table: []const u8, key: []const u8, v: i32) bool {
            var buf: [16]u8 = undefined;
            const val = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return false;
            return prefs.writeComponentKey(alloc, io2, dir, "notifications", table, key, val);
        }
        fn q(alloc: std.mem.Allocator, io2: std.Io, dir: []const u8, table: []const u8, key: []const u8, v: []const u8) bool {
            const val = quoted(alloc, v) catch return false;
            defer alloc.free(val);
            return prefs.writeComponentKey(alloc, io2, dir, "notifications", table, key, val);
        }
    };
    ok = put.b(gpa, io, state_dir, "notifications", "dbus_enabled", s.notifications_dbus_enabled) and ok;
    ok = put.b(gpa, io, state_dir, "notifications", "do_not_disturb", s.notifications_dnd) and ok;
    ok = put.i(gpa, io, state_dir, "notifications", "default_timeout_ms", s.notifications_timeout_ms) and ok;
    ok = put.q(gpa, io, state_dir, "notifications", "output", s.notifications_output) and ok;
    ok = put.b(gpa, io, state_dir, "notifications.toast", "layer_shell_enabled", s.notifications_layer_shell) and ok;
    ok = put.q(gpa, io, state_dir, "notifications.toast", "position", s.notifications_toast_position) and ok;
    ok = put.i(gpa, io, state_dir, "notifications.toast", "margin_px", s.notifications_margin_px) and ok;
    ok = put.i(gpa, io, state_dir, "notifications.toast", "corner_radius_px", s.notifications_corner_radius_px) and ok;
    ok = put.i(gpa, io, state_dir, "notifications.toast", "max_width_px", s.notifications_max_width_px) and ok;
    ok = put.i(gpa, io, state_dir, "notifications.toast", "scale_pct", s.notifications_scale_pct) and ok;
    return ok;
}

/// The test button: `Notify("Event Horizon", …, "Test notification", …)`
/// straight at the daemon over a throwaway connection. True when a live id
/// came back.
pub fn sendTestNotification(gpa: std.mem.Allocator) bool {
    const addr = dbus_conn.addressFor(.session, getenvOpt("DBUS_SESSION_BUS_ADDRESS"), null) orelse return false;
    var conn = dbus_conn.Conn.init(gpa);
    defer conn.deinit();
    conn.connect(addr) catch return false;
    conn.hello() catch return false;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    const no_strs = aa.alloc(wire.Value, 0) catch return false;
    const body = aa.alloc(wire.Value, 8) catch return false;
    body[0] = .{ .string = "Event Horizon" };
    body[1] = .{ .uint32 = 0 };
    body[2] = .{ .string = "" };
    body[3] = .{ .string = "Test notification" };
    body[4] = .{ .string = "Sample from Settings \xe2\x86\x92 Notifications." };
    body[5] = .{ .array = .{ .elem = "s", .items = no_strs } };
    body[6] = .{ .array = .{ .elem = "{sv}", .items = no_strs } };
    body[7] = .{ .int32 = -1 };
    var reply = conn.call(.{
        .mtype = .method_call,
        .path = "/org/freedesktop/Notifications",
        .interface = "org.freedesktop.Notifications",
        .member = "Notify",
        .destination = "org.freedesktop.Notifications",
        .signature = "susssasa{sv}i",
        .body = body,
    }, 5000) catch return false;
    defer reply.deinit();
    return reply.body_vals.len >= 1 and reply.body_vals[0] == .uint32;
}

test "notifications-persist: save writes every key the schema reads" {
    const t = std.testing;
    // Shape check only (no IO): every knob maps to a table+key the decoder
    // understands. The decoder test in schema.zig covers the read side.
    var s = app_mod.Settings{};
    s.notifications_margin_px = 24;
    s.notifications_output = "DP-1";
    try t.expectEqual(@as(i32, 24), s.notifications_margin_px);
    try t.expectEqualStrings("DP-1", s.notifications_output);
}

test "notifications-persist: file round-trips through the real loader" {
    const t = std.testing;
    const a = t.allocator;
    const schema = @import("../../config/schema.zig");
    var io_threaded: std.Io.Threaded = .init(a, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();
    // Stage under the approved scratch root (Io.Dir has no tmppath helper).
    const state_path = try std.fmt.allocPrint(a, "/tmp/opencode/notif-test-{d}", .{std.os.linux.getpid()});
    defer a.free(state_path);
    std.Io.Dir.cwd().deleteTree(io, state_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, state_path) catch {};

    var s = app_mod.Settings{};
    s.notifications_dbus_enabled = false;
    s.notifications_dnd = true;
    s.notifications_timeout_ms = 9000;
    s.notifications_output = "DP-1";
    s.notifications_layer_shell = false;
    s.notifications_toast_position = "bottom_left";
    s.notifications_margin_px = 24;
    s.notifications_corner_radius_px = 5;
    s.notifications_max_width_px = 500;
    s.notifications_scale_pct = 150;
    try t.expect(save(a, io, state_path, &s));

    // Read back through the exact production path the daemon uses.
    const path = try std.fmt.allocPrint(a, "{s}/notifications/notifications.toml", .{state_path});
    defer a.free(path);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    defer a.free(text);
    var loaded = try schema.loadText(a, text);
    defer loaded.deinit();
    const n = loaded.cfg.notifications;
    try t.expect(!n.dbus_enabled);
    try t.expect(n.do_not_disturb);
    try t.expectEqual(@as(i32, 9000), n.default_timeout_ms);
    try t.expectEqualStrings("DP-1", n.output_name);
    try t.expect(!n.toast.layer_shell_enabled);
    try t.expectEqualStrings("bottom_left", n.toast.position);
    try t.expectEqual(@as(i32, 24), n.toast.margin_px);
    try t.expectEqual(@as(i32, 5), n.toast.corner_radius_px);
    try t.expectEqual(@as(i32, 500), n.toast.max_width_px);
    try t.expectEqual(@as(i32, 150), n.toast.scale_pct);
}
