//! Temporary: runs only the settings-monitors tests while
//! `src/desktop_shell/` is mid-refactor. Delete once `zig build test` is
//! green again.
test {
    _ = @import("ux/settings/monitors_state.zig");
    _ = @import("ux/settings/monitors_page.zig");
    _ = @import("ux/settings/monitors_tab_helpers.zig");
    _ = @import("ux/settings/ui_content.zig");
    _ = @import("ux/settings/ui_widgets.zig");
}
