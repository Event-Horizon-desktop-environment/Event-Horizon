const std = @import("std");
const app_mod = @import("app.zig");
const cfg = @import("../../config.zig");
const section_store = @import("../../config/section_store.zig");

// Launcher tab persistence —
// save/load functions:
// save_launchpad_settings_to_file / patch_workspaces_widget_in_shell_config).
//
// Same design: the Widget-opacity slider drives BOTH dock.slotPillOpacity
// and taskbar.slotPillOpacity (both set together), and the Workspaces
// child edits the `workspaces` widget instance (`max_workspaces`,
// `show_apps`, `max_workspace_icons`). All three land through
// `section_store.save` so unrelated keys survive byte-for-byte.

pub const dock_component = "dock";
pub const dock_section = "dock";
pub const taskbar_component = "taskbar";
pub const taskbar_section = "taskbar";
pub const widgets_component = "widgets";

/// Seed the Widget-opacity slider from the layered config. Both bars load
/// the same value; the slider keeps them in sync afterwards (see
/// fields.setInt for slot_pill_opacity).
pub fn loadSlotPill(s: *app_mod.Settings, d: *const cfg.DockSettings, t: *const cfg.TaskbarSettings) void {
    s.slot_pill_opacity = d.slot_pill_opacity;
    s.taskbar_slot_pill_opacity = t.slot_pill_opacity;
}

/// Seed the Workspaces child from the `workspaces` widget instance.
/// Missing keys keep the struct defaults (5 / true / 4).
/// `widget_setting_simple` guards in load_settings().
pub fn loadWorkspaces(s: *app_mod.Settings, instances: []const cfg.schema.WidgetInstance) void {
    for (instances) |w| {
        const is_ws = std.mem.eql(u8, w.id, "workspaces") or std.mem.eql(u8, w.type, "workspaces");
        if (!is_ws) continue;
        for (w.settings) |kv| {
            if (std.mem.eql(u8, kv.key, "max_workspaces")) {
                if (std.fmt.parseInt(i32, std.mem.trim(u8, kv.value, " \t"), 10) catch null) |v| {
                    s.workspaces_max_slots = @max(0, @min(16, v));
                }
            } else if (std.mem.eql(u8, kv.key, "show_apps")) {
                if (std.mem.eql(u8, kv.value, "1") or std.mem.eql(u8, kv.value, "true") or
                    std.mem.eql(u8, kv.value, "True") or std.mem.eql(u8, kv.value, "yes"))
                {
                    s.workspaces_show_apps = true;
                } else if (std.mem.eql(u8, kv.value, "0") or std.mem.eql(u8, kv.value, "false") or
                    std.mem.eql(u8, kv.value, "False") or std.mem.eql(u8, kv.value, "no"))
                {
                    s.workspaces_show_apps = false;
                }
            } else if (std.mem.eql(u8, kv.key, "max_workspace_icons")) {
                if (std.fmt.parseInt(i32, std.mem.trim(u8, kv.value, " \t"), 10) catch null) |v| {
                    s.workspaces_max_icons = @max(1, @min(8, v));
                }
            }
        }
        return;
    }
}

/// Write the Widget-opacity slider to both bar files.
pub fn saveSlotPill(
    gpa: std.mem.Allocator,
    io: std.Io,
    state_dir: []const u8,
    s: *const app_mod.Settings,
) !void {
    var values = std.heap.ArenaAllocator.init(gpa);
    defer values.deinit();
    {
        const path = try cfg.componentPath(gpa, state_dir, dock_component);
        defer gpa.free(path);
        const entries = [_]section_store.Entry{
            .{ .key = "slot_pill_opacity", .value = try section_store.intValue(values.allocator(), s.slot_pill_opacity) },
        };
        try section_store.save(gpa, io, path, dock_section, &entries);
    }
    {
        const path = try cfg.componentPath(gpa, state_dir, taskbar_component);
        defer gpa.free(path);
        const entries = [_]section_store.Entry{
            .{ .key = "slot_pill_opacity", .value = try section_store.intValue(values.allocator(), s.taskbar_slot_pill_opacity) },
        };
        try section_store.save(gpa, io, path, taskbar_section, &entries);
    }
}

/// Write the Workspaces child to `[widget.workspaces]` in widgets.toml.
pub fn saveWorkspaces(
    gpa: std.mem.Allocator,
    io: std.Io,
    state_dir: []const u8,
    s: *const app_mod.Settings,
) !void {
    const path = try cfg.componentPath(gpa, state_dir, widgets_component);
    defer gpa.free(path);
    var values = std.heap.ArenaAllocator.init(gpa);
    defer values.deinit();
    var buf: [16]u8 = undefined;
    const slots = std.fmt.bufPrint(&buf, "{d}", .{s.workspaces_max_slots}) catch "5";
    const slots_val = try values.allocator().dupe(u8, slots);
    var buf2: [16]u8 = undefined;
    const icons = std.fmt.bufPrint(&buf2, "{d}", .{s.workspaces_max_icons}) catch "4";
    const icons_val = try values.allocator().dupe(u8, icons);
    const entries = [_]section_store.Entry{
        .{ .key = "type", .value = try section_store.stringValue(values.allocator(), "workspaces") },
        .{ .key = "max_workspaces", .value = slots_val },
        .{ .key = "show_apps", .value = section_store.boolValue(s.workspaces_show_apps) },
        .{ .key = "max_workspace_icons", .value = icons_val },
    };
    try section_store.save(gpa, io, path, "widget.workspaces", &entries);
}

/// Full launcher flush: appearance (launchpad + overview) + both slot pills
/// + the workspaces widget instance.
pub fn saveAll(
    gpa: std.mem.Allocator,
    io: std.Io,
    state_dir: []const u8,
    s: *const app_mod.Settings,
) !void {
    const appearance_persist = @import("appearance_persist.zig");
    try appearance_persist.save(gpa, io, state_dir, s);
    try saveSlotPill(gpa, io, state_dir, s);
    try saveWorkspaces(gpa, io, state_dir, s);
}

test "launcher-persist: workspace load values clamp at the specified limits" {
    const t = std.testing;
    var s = app_mod.Settings{};
    const inst = [_]cfg.schema.WidgetInstance{
        .{ .id = "workspaces", .type = "workspaces", .settings = @constCast(&[_]cfg.schema.WidgetInstance.Setting{
            .{ .key = "max_workspaces", .value = "99" },
            .{ .key = "show_apps", .value = "false" },
            .{ .key = "max_workspace_icons", .value = "0" },
        }) },
    };
    loadWorkspaces(&s, &inst);
    try t.expectEqual(@as(i32, 16), s.workspaces_max_slots);
    try t.expect(!s.workspaces_show_apps);
    try t.expectEqual(@as(i32, 1), s.workspaces_max_icons);
}

test "launcher-persist: workspaces load keeps defaults when absent" {
    const t = std.testing;
    var s = app_mod.Settings{};
    loadWorkspaces(&s, &.{});
    try t.expectEqual(@as(i32, 5), s.workspaces_max_slots);
    try t.expect(s.workspaces_show_apps);
    try t.expectEqual(@as(i32, 4), s.workspaces_max_icons);
}

test "launcher-persist: slot pill seeds from dock" {
    const t = std.testing;
    var s = app_mod.Settings{};
    const d = cfg.DockSettings{ .slot_pill_opacity = 42 };
    const tb = cfg.TaskbarSettings{ .slot_pill_opacity = 43 };
    loadSlotPill(&s, &d, &tb);
    // Dock wins the shared slider; the taskbar copy keeps its own file value
    // until the slider moves (fields.setInt syncs both on edit).
    try t.expectEqual(@as(i32, 42), s.slot_pill_opacity);
    try t.expectEqual(@as(i32, 43), s.taskbar_slot_pill_opacity);
}
