const std = @import("std");
const app_mod = @import("app.zig");
const cfg = @import("../../config.zig");
const toml = @import("../../config/toml.zig");
const section_store = @import("../../config/section_store.zig");
const widgets = @import("../../desktop_shell/dock/widgets.zig");

pub const component = "widgets";

/// Seed `Settings.widget_states` from every `[widget.<id>]` instance the
/// loader knows, carrying each id's implementation type and on/off. Only
/// defined instances are tracked: an untouched stock widget has no section
/// and reads as enabled, which is also what the dock's `instanceEnabled`
/// answers for it.
pub fn load(alloc: std.mem.Allocator, s: *app_mod.Settings, instances: []const cfg.schema.WidgetInstance) void {
    var out: std.ArrayList(app_mod.WidgetState) = .empty;
    for (instances) |w| {
        const id = alloc.dupe(u8, w.id) catch continue;
        const impl = alloc.dupe(u8, if (w.type.len > 0) w.type else w.id) catch {
            alloc.free(id);
            continue;
        };
        out.append(alloc, .{
            .id = id,
            .impl = impl,
            .enabled = widgets.instanceEnabledBySettings(w.settings),
        }) catch {
            alloc.free(id);
            alloc.free(impl);
        };
    }
    s.widget_states = out.toOwnedSlice(alloc) catch &.{};
}

/// The board's on/off answer for one widget id. Untouched ids read enabled.
pub fn isEnabled(s: *const app_mod.Settings, id: []const u8) bool {
    return isEnabledStates(s.widget_states, id);
}

/// Slice-level on/off answer, for paint code that holds states directly.
pub fn isEnabledStates(states: []const app_mod.WidgetState, id: []const u8) bool {
    for (states) |w| {
        if (std.mem.eql(u8, w.id, id)) return w.enabled;
    }
    return true;
}

/// Flip one widget's switch, tracking a fresh state for untouched ids (whose
/// implementation is the id itself, matching `implType`'s fallback).
/// Returns false when nothing changed.
pub fn toggle(s: *app_mod.Settings, alloc: std.mem.Allocator, id: []const u8) bool {
    for (s.widget_states) |*w| {
        if (std.mem.eql(u8, w.id, id)) {
            w.enabled = !w.enabled;
            return true;
        }
    }
    const nid = alloc.dupe(u8, id) catch return false;
    errdefer alloc.free(nid);
    const nimpl = alloc.dupe(u8, id) catch return false;
    errdefer alloc.free(nimpl);
    var list: std.ArrayList(app_mod.WidgetState) = .empty;
    list.append(alloc, .{ .id = nid, .impl = nimpl, .enabled = false }) catch return false;
    const joined = std.mem.concat(alloc, app_mod.WidgetState, &.{ s.widget_states, list.items }) catch return false;
    list.deinit(alloc);
    // The old buffer is heap on every path but the first (which is the
    // static empty slice); its strings moved into `joined`, so only the
    // buffer itself goes back.
    if (s.widget_states.len > 0) alloc.free(s.widget_states);
    s.widget_states = joined;
    return true;
}

/// Write every tracked state back into `widgets/widgets.toml`, one dotted
/// section per instance (`[widget.clock]` with `type` + `enabled`). Always
/// rewriting (rather than erasing re-enabled sections) means a flip back on
/// can never leave a stale `enabled = false` behind.
pub fn save(
    gpa: std.mem.Allocator,
    io: std.Io,
    state_dir: []const u8,
    s: *const app_mod.Settings,
) !void {
    if (s.widget_states.len == 0) return;
    const path = try cfg.componentPath(gpa, state_dir, component);
    defer gpa.free(path);

    var values = std.heap.ArenaAllocator.init(gpa);
    defer values.deinit();
    for (s.widget_states) |w| {
        const section = try std.fmt.allocPrint(gpa, "widget.{s}", .{w.id});
        defer gpa.free(section);
        const entries = [_]section_store.Entry{
            .{ .key = "type", .value = try section_store.stringValue(values.allocator(), w.impl) },
            .{ .key = "enabled", .value = section_store.boolValue(w.enabled) },
        };
        try section_store.save(gpa, io, path, section, &entries);
    }
}

test "widget-persist: untracked ids read enabled, toggles stick" {
    const t = std.testing;
    var s: app_mod.Settings = .{};
    try t.expect(isEnabled(&s, "clock"));
    try t.expect(toggle(&s, t.allocator, "clock"));
    try t.expect(!isEnabled(&s, "clock"));
    try t.expect(toggle(&s, t.allocator, "clock"));
    try t.expect(isEnabled(&s, "clock"));
    defer {
        for (s.widget_states) |w| {
            t.allocator.free(w.id);
            t.allocator.free(w.impl);
        }
        t.allocator.free(s.widget_states);
    }
}

test "widget-persist: save round-trips through the widget loader" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(root);
    const dir = try std.fs.path.join(alloc, &.{ root, "widgets" });
    defer alloc.free(dir);

    var s: app_mod.Settings = .{};
    defer {
        for (s.widget_states) |w| {
            alloc.free(w.id);
            alloc.free(w.impl);
        }
        alloc.free(s.widget_states);
    }
    try t.expect(toggle(&s, alloc, "clock"));
    try t.expect(toggle(&s, alloc, "tray"));
    try t.expect(toggle(&s, alloc, "tray"));

    try cwd.createDirPath(io, dir);
    const state = try std.fs.path.join(alloc, &.{ root });
    defer alloc.free(state);
    // save() builds `<state>/widgets/widgets.toml` itself.
    try save(alloc, io, state, &s);

    const path = try std.fs.path.join(alloc, &.{ dir, "widgets.toml" });
    defer alloc.free(path);
    const text = try cwd.readFileAlloc(io, path, alloc, .limited(1 << 16));
    defer alloc.free(text);

    var doc = try toml.parse(alloc, text);
    defer doc.deinit();
    const wtab = doc.table("widget").?.table;
    try t.expect(wtab.get("clock").?.table.get("enabled").?.boolean == false);
    // Flipped twice: back on, but still written (no stale-off possible).
    try t.expect(wtab.get("tray").?.table.get("enabled").?.boolean == true);
    try t.expectEqualStrings("clock", wtab.get("clock").?.table.get("type").?.string);
}
