//! Scratch test root: polkit agent port suites only, while the shared root
//! is mid-edit elsewhere. Not part of the build; deleted after a run.

test {
    _ = @import("services/polkit/session.zig");
    _ = @import("services/polkit/agent.zig");
    _ = @import("desktop_shell/widgets/polkit_dialog_paint.zig");
}
