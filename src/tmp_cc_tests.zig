//! TEMPORARY scoped test root: runs the control-center / pear tests while
//! another session's `m3/wl` → `wl` refactor leaves `src/tests.zig` broken.
//! Delete once the tree builds again.

const std = @import("std");

comptime {
    _ = @import("desktop_shell/controlcenter/live_audio.zig");
    _ = @import("desktop_shell/controlcenter/layout.zig");
    _ = @import("desktop_shell/controlcenter/state.zig");
    _ = @import("desktop_shell/controlcenter/apply.zig");
    _ = @import("desktop_shell/pear/layout.zig");
    _ = @import("desktop_shell/pear/state.zig");
    _ = @import("desktop_shell/pear/hit.zig");
}

test {
    std.testing.refAllDecls(@This());
}
