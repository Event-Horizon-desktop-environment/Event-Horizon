//! Layer-surface namespaces.
//!
//! These strings are part of the shell's public surface: Hyprland
//! `layerrule`s (blur, ignore_alpha) target them by name, so changing one
//! silently breaks the user's compositor config. They are kept byte-identical
//! — the whole point is that
//! layer-surface namespace strings are stable across both shells.
//!
//! `manifest` below is the user's live rule set, verbatim. It is the contract:
//! every namespace the shell can put on screen is in it, and the test pins the
//! values so a typo cannot ship.

/// The dock bar itself.
pub const dock = "event-horizon-dock";
/// Top-edge dashboard (modular widget panel), a separate layer surface so it
/// can reveal independently of the dock.
pub const dashboard = "event-horizon-dashboard";
pub const osd = "event-horizon-osd";
pub const desktop_shell = "event-horizon-desktop-shell";
/// The start menu namespace.
pub const app_drawer = "event-horizon-appdrawer";
pub const spotlight = "event-horizon-spotlight";
pub const control_center = "event-horizon-controlcenter";
pub const notification_toast = "event-horizon-toasts";
pub const polkit = "event-horizon-polkit";
/// A tray icon's right-click menu.
pub const tray_menu = "event-horizon-tray";
/// An app slot's / the trash's right-click menu.
pub const dock_context_menu = "event-horizon-dock-context";
pub const context_menu = "event-horizon-context-menu";
pub const calendar = "event-horizon-calendar";
/// `PopupKind::Weather` and `PopupKind::VolumeMixer` both land here in the
/// Generic popup name shared with the weather card.
pub const popup = "event-horizon-popup";
/// The panel's own overview/launchpad surface, distinct from the shell-wide
/// `overview` below.
pub const taskbar = "event-horizon-taskbar";
pub const overview = "event-horizon-overview";
pub const overview_backdrop = "event-horizon-overview-backdrop";
/// Fullscreen wallpaper surface below the overview content. Opaque wallpaper
/// pixels live here (never in the content buffer) so the compositor can match
/// blur/background-effects on this namespace.
pub const overview_background = "event-horizon-overview-background";
pub const widgets = "event-horizon-widgets";
pub const desktop_widgets = "event-horizon-desktop-widgets";
pub const desktop_menus = "event-horizon-desktop-menus";
/// The launchpad / app grid and the dimmed layer behind it.
pub const launchpad = "event-horizon-launchpad";
pub const launchpad_backdrop = "event-horizon-launchpad-backdrop";
/// Settings' widget picker namespace.
/// own so it blurs separately from the settings window.
pub const settings_widget_picker = "event-horizon-settings-widget-picker";
/// The wallpaper client's own layer surface (hardcoded rather than pulled from the header).
pub const wallpaper = "event-horizon-wallpaper";

/// The Audio Center (pavucontrol-equivalent mixer) toplevel.
pub const audio_center_app_id = "event-horizon-audio-center";

/// The settings app namespace (xdg `app_id`).
/// layer namespace; the Zig settings window is an xdg toplevel, so this is the
/// `app_id` a *window* rule matches, not a `layerrule`.
pub const settings_app_id = "event-horizon-settings";

/// The redesigned `settings` binary keeps its own `app_id` so the dock and
/// taskbar can tell which of the two settings buttons owns the running
/// window — the running dot, focus-before-launch and right-click window
/// lists all key off this, while the classic binary keeps the id above.
pub const rail_settings_app_id = "event-horizon-rail-settings";

/// The Vinyl music player. Deliberately not `event-horizon-` prefixed: it is a
/// third-party app that ships its own layer surface, not part of this shell.
pub const vinyl = "horizon-vinyl";

// Slot key constants — widget/feature identifiers used in slot dispatch.
pub const slot_key_settings = "__settings__";
pub const slot_key_spotlight = "__spotlight__";
pub const slot_key_app_menu = "__app_menu__";
pub const slot_key_app_drawer = "__app_drawer__";
pub const slot_key_tray = "__tray__";
pub const slot_key_smenu = "__smenu__";
pub const slot_key_sep = "__sep__";

const std = @import("std");

/// Every namespace the user's Hyprland config has a rule for, with the value
/// pinned. This is the contract between the shell and the compositor config.
pub const manifest = [_]struct { []const u8, []const u8 }{
    .{ "dock", dock },
    .{ "vinyl", vinyl },
    .{ "spotlight", spotlight },
    .{ "settings", settings_app_id },
    .{ "appdrawer", app_drawer },
    .{ "tray", tray_menu },
    .{ "dock-context", dock_context_menu },
    .{ "controlcenter", control_center },
    .{ "settings-widget-picker", settings_widget_picker },
    .{ "context-menu", context_menu },
    .{ "calendar", calendar },
    .{ "popup", popup },
    .{ "taskbar", taskbar },
    .{ "toasts", notification_toast },
    .{ "osd", osd },
    .{ "launchpad", launchpad },
    .{ "launchpad-backdrop", launchpad_backdrop },
    .{ "polkit", polkit },
    .{ "widgets", widgets },
    .{ "overview-backdrop", overview_backdrop },
    .{ "desktop-shell", desktop_shell },
    .{ "desktop-widgets", desktop_widgets },
    .{ "desktop-menus", desktop_menus },
    .{ "overview", overview },
    .{ "dashboard", dashboard },
};

test "namespaces: every manifest value is exactly event-horizon-<suffix>" {
    const t = std.testing;
    for (manifest) |entry| {
        const label, const value = entry;
        // `horizon-vinyl` is a third-party app and is the one exception.
        if (std.mem.eql(u8, label, "vinyl")) {
            try t.expectEqualStrings("horizon-vinyl", value);
            continue;
        }
        var want_buf: [128]u8 = undefined;
        const want = try std.fmt.bufPrint(&want_buf, "event-horizon-{s}", .{label});
        try t.expectEqualStrings(want, value);
    }
}

test "namespaces: manifest has no duplicate values" {
    const t = std.testing;
    for (manifest, 0..) |entry, i| {
        for (manifest[i + 1 ..]) |other| {
            try t.expect(!std.mem.eql(u8, entry[1], other[1]));
        }
    }
}

test "namespaces: the names the dock popups map to" {
    const t = std.testing;
    // A rule written
    // must keep matching, so these are exact.
    try t.expectEqualStrings("event-horizon-tray", tray_menu);
    try t.expectEqualStrings("event-horizon-dock-context", dock_context_menu);
    try t.expectEqualStrings("event-horizon-appdrawer", app_drawer);
    try t.expectEqualStrings("event-horizon-spotlight", spotlight);
    try t.expectEqualStrings("event-horizon-controlcenter", control_center);
    try t.expectEqualStrings("event-horizon-calendar", calendar);
    try t.expectEqualStrings("event-horizon-popup", popup);
    try t.expectEqualStrings("event-horizon-dock", dock);
    try t.expectEqualStrings("event-horizon-wallpaper", wallpaper);
}
