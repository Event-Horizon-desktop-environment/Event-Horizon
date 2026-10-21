const std = @import("std");

pub const Action = enum { none, launch, show_tooltip, begin_drag, show_menu };

pub const SlotEvent = struct {
    action: Action,
    slot: usize = 0,
};

pub fn press(slots: usize, idx: usize, button: u8, long_press_ms: i64, down_ms: i64) SlotEvent {
    if (idx >= slots) return .{ .action = .none };
    if (button == 3) return .{ .action = .show_menu, .slot = idx };
    if (down_ms >= long_press_ms) return .{ .action = .begin_drag, .slot = idx };
    return .{ .action = .launch, .slot = idx };
}

pub fn motion(slots: usize, idx: usize, dragging: bool) SlotEvent {
    if (dragging and idx < slots) return .{ .action = .begin_drag, .slot = idx };
    if (idx < slots) return .{ .action = .show_tooltip, .slot = idx };
    return .{ .action = .none };
}

test "dock-input: press dispatch" {
    const t = std.testing;
    try t.expectEqual(Action.launch, press(5, 2, 1, 500, 100).action);
    try t.expectEqual(Action.show_menu, press(5, 2, 3, 500, 100).action);
    try t.expectEqual(Action.begin_drag, press(5, 2, 1, 500, 600).action);
    try t.expectEqual(Action.none, press(5, 9, 1, 500, 100).action);
    try t.expectEqual(Action.show_tooltip, motion(5, 1, false).action);
}
