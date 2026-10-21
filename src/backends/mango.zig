const std = @import("std");

pub const mango_note =
    "Mango speaks dwl-ipc over Wayland (no unix socket). Full support needs the " ++
    "dwl-ipc-v2 protocol binding in build codegen plus an output/workspace model. " ++
    "Tracked for the P5 backend pass; ext-workspace covers capable compositors first.";

pub const Workspace = struct {
    id: u32 = 0,
    name: []const u8 = "",
    focused: bool = false,
};

test "mango: placeholder documents the path" {
    const t = std.testing;
    try t.expect(mango_note.len > 0);
    try t.expectEqual(@as(u32, 0), (Workspace{}).id);
}
