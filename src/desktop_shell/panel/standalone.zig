//! Panel standalone wiring — port of
//! `src/desktop_shell/panel/standalone/panel_standalone.cpp`.
//!
//! The event loop itself (poll mux, timerfds, inotify, IPC subscriptions)
//! lives in `bin/panel.zig` on top of the shared `App`/`Loop` infra. This
//! file pins the constants and the pure decisions the C++ loop embeds: tick
//! cadences, IPC topics, output selection, and the overview-toggle publish.

const std = @import("std");

/// 1 s poll tick: battery/bluetooth/MPRIS refresh + repaint
/// (`panel_standalone.cpp:149-154,241-255`).
pub const poll_interval_ms: u64 = 1000;

/// 200 ms tooltip tick — the 1 s poll would add up to a second of hover lag
/// (`panel_standalone.cpp:157-167,256-262`).
pub const tooltip_tick_ms: u64 = 200;

/// `config.applied` reload path: re-read disk, `maybe_reload`, repaint
/// (`panel_standalone.cpp:181-185,264-271`).
pub const topic_config_applied: []const u8 = "config.applied";
pub const topic_command_request: []const u8 = "command.request";

/// Middle-click on workspaces publishes this so horizon-stage flips the
/// overview (`panel_standalone.cpp:196-198`, `panel.cpp:917-927`).
pub const overview_toggle_payload: []const u8 = "overview.toggle";

/// `settings.toggle` is consumed by horizon-settings; the panel ignores it
/// (`panel_standalone.cpp:187-189`).
pub const settings_toggle_payload: []const u8 = "settings.toggle";

/// Output selection (`panel_standalone.cpp:86-105`): `all` binds every
/// output, `auto`/empty picks the primary (origin) output, anything else
/// names one output.
pub const OutputSelect = enum { all, auto_primary, named };

pub fn classifyOutputAssign(s: []const u8) OutputSelect {
    const v = std.mem.trim(u8, s, " \t\n");
    if (v.len == 0) return .auto_primary;
    if (std.ascii.eqlIgnoreCase(v, "all") or std.ascii.eqlIgnoreCase(v, "all-displays")) return .all;
    if (std.ascii.eqlIgnoreCase(v, "auto")) return .auto_primary;
    return .named;
}

/// Whether a named assignment matches an output name (exact; the C++ trims
/// via `trim_output_assign` first, so callers pass the trimmed value).
pub fn outputNameMatches(assign: []const u8, output_name: []const u8) bool {
    return std.mem.eql(u8, assign, output_name);
}

/// Settings-reload change classes (`panel.cpp:798-827`): geometry edits
/// re-apply layer margins in place; a layer/output/enable flip destroys the
/// layers and lets the loop rebind them.
pub const ReloadImpact = enum { none, geometry, rebind };

pub fn reloadImpact(
    overlay_changed: bool,
    enabled_changed: bool,
    output_changed: bool,
    geom_changed: bool,
) ReloadImpact {
    if (overlay_changed or enabled_changed or output_changed) return .rebind;
    if (geom_changed) return .geometry;
    return .none;
}

test "panel-standalone: topics and payloads are pinned" {
    const t = std.testing;
    try t.expectEqualStrings("config.applied", topic_config_applied);
    try t.expectEqualStrings("command.request", topic_command_request);
    try t.expectEqualStrings("overview.toggle", overview_toggle_payload);
    try t.expectEqual(@as(u64, 1000), poll_interval_ms);
    try t.expectEqual(@as(u64, 200), tooltip_tick_ms);
}

test "panel-standalone: output assignment classification" {
    const t = std.testing;
    try t.expect(classifyOutputAssign("all") == .all);
    try t.expect(classifyOutputAssign("All-Displays") == .all);
    try t.expect(classifyOutputAssign("auto") == .auto_primary);
    try t.expect(classifyOutputAssign("") == .auto_primary);
    try t.expect(classifyOutputAssign("HDMI-A-1") == .named);
    try t.expect(outputNameMatches("HDMI-A-1", "HDMI-A-1"));
    try t.expect(!outputNameMatches("HDMI-A-1", "DP-1"));
}

test "panel-standalone: reload impact ladder" {
    const t = std.testing;
    try t.expect(reloadImpact(true, false, false, false) == .rebind);
    try t.expect(reloadImpact(false, true, false, false) == .rebind);
    try t.expect(reloadImpact(false, false, true, false) == .rebind);
    try t.expect(reloadImpact(false, false, false, true) == .geometry);
    try t.expect(reloadImpact(false, false, false, false) == .none);
}
