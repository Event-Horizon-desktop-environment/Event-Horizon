//! Scratch test root: runs only the launcher's own suites while the shared
//! root is mid-edit elsewhere. Not part of the build; deleted after a run.

test {
    _ = @import("desktop_shell/widgets/launcher_layout.zig");
    _ = @import("desktop_shell/widgets/launcher_paint.zig");
    _ = @import("desktop_shell/widgets/launcher_rail_paint.zig");
    _ = @import("desktop_shell/dock/launcher_menu.zig");
    _ = @import("services/app_launch.zig");
    _ = @import("services/app_catalog.zig");
}
