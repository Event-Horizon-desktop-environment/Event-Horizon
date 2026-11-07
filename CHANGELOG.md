# Changelog

All notable changes to Event Horizon are documented here, newest first.

## [0.1.2] - 2026-11-06

This release adds early support for the Zoolander compositor and fixes display
and clipboard behaviour that surfaced while bringing it up. Zoolander support is
still a work in progress, but the shell can now detect the compositor, read its
display and workspace data, and edit its Lua configuration from Settings.

### Added

- **Zoolander compositor detection.** Event Horizon recognises Zoolander
  sessions through its environment markers, desktop hints, and control socket.
  The socket check also covers sessions that start the shell without exporting
  a marker. Zoolander is detected before Hyprland because the two share some
  compatibility variables.
- **Display management for Zoolander.** The Monitors page can read output
  information from the compositor, including resolution, refresh rate, scale,
  rotation, HDR and VRR capabilities, bit depth, and EDID details. Changes are
  written back as `zl.output_rule` entries in
  `~/.config/zoolander/monitors.lua`.
- **Display confirmation dialog.** Display and presentation changes now show a
  15-second "Keep these settings?" prompt. If the user does not confirm, the
  previous configuration is restored automatically. The flow also survives a
  restart, so a failed display change cannot leave the session unusable.
- **Zoolander settings pages.** New pages cover Keyboard, Mouse and Touchpad,
  Windows and Borders, Effects, Animations, Decorations, Workspaces and
  Layouts, and XWayland. They read and write the matching Lua setters while
  leaving comments and computed values untouched.
- **Zoolander workspace support in the overview.** The overview builds its
  workspace and window snapshot from the compositor control socket, including
  named workspaces, active workspace state, monitor placement, and window
  geometry. Clicking a workspace activates it through the compositor's Lua
  interface.

### Changed

- Monitor settings now select the correct backend for both Hyprland and
  Zoolander, and preserve Zoolander-only output capabilities when building a
  configuration block.
- Toggle and dropdown edits on Zoolander pages are written to disk and followed
  by a configuration reload, so changes take effect without closing Settings.
- Zoolander configuration reloads go directly to the compositor control socket
  first and fall back to `zoolanderctl` when the socket is unavailable. Reload
  failures are logged and shown in the interface instead of being ignored.
- The settings field map now includes the Zoolander configuration bindings used
  by the shared settings code.
- Version updated to 0.1.2.

### Fixed

- Fixed a Lua syntax error in generated monitor configuration. Entries were
  separated with an extra comma, which produced an invalid file that Zoolander
  refused to load.
- Enum values written to `monitors.lua` are now quoted strings. Previously they
  were written as bare words, which Lua treated as empty globals.
- Fixed clipboard and primary-selection handling on Zoolander. The compositor
  rejects a data source that is already bound to a selection, so the clipboard
  and primary selections now use separate sources. This restores screenshot
  copying and other clipboard operations.
- Fixed monitor parsing and environment handling in the dock, taskbar, and
  overview after the Zoolander additions.
- Added tests for detection order, control-socket discovery, monitor parsing,
  workspace snapshot assembly, Lua value quoting, and the display confirmation
  state.
