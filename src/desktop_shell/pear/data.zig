//! Pear view model: the shared live snapshot plus the flags only the
//! compact popup paints (DND, night light, theme darkness, redeye,
//! brightness). The snapshot itself is borrowed — the host owns it.

const cc_data = @import("../controlcenter/data.zig");

pub const View = struct {
    snap: cc_data.Snapshot = .{},
    dnd_on: bool = false,
    night_on: bool = false,
    is_dark: bool = true,
    redeye_on: bool = false,
    brightness_pct: i32 = -1,
};
