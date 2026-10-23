//! Focused regression suite for the image loading and screenshot boundaries.
//! Run with: zig build test -Dtest-root=src/security_tests.zig

test {
    _ = @import("bootstrap/screenshot.zig");
    _ = @import("wallpaper/decode.zig");
    _ = @import("services/mpris_art.zig");
    _ = @import("wl/capture/shot.zig");
    _ = @import("clipboard_daemon.zig");
}
