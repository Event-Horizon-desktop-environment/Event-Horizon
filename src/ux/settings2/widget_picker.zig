const std = @import("std");

// Widget picker + drag state.
// widget_picker.{hpp,cpp} (logic only; painting uses shared card geometry).
// Same design: armed -> dragging with grab delta, insert-before index,
// per-section lists (dock/panel/taskbar/desktop/dashboard).

pub const Section = enum {
    none,
    dock,
    panel,
    taskbar,
    desktop,
    dashboard,
};

pub const DragState = struct {
    section: Section = .none,
    target_section: Section = .none,
    from_index: isize = -1,
    press_x: f64 = 0,
    press_y: f64 = 0,
    grab_dx: f64 = 0,
    grab_dy: f64 = 0,
    armed: bool = false,
    dragging: bool = false,
    insert_before: usize = 0,

    pub fn arm(self: *DragState, section: Section, index: usize, px: f64, py: f64) void {
        self.section = section;
        self.target_section = section;
        self.from_index = @intCast(index);
        self.press_x = px;
        self.press_y = py;
        self.grab_dx = 0;
        self.grab_dy = 0;
        self.armed = true;
        self.dragging = false;
    }

    pub fn motion(self: *DragState, px: f64, py: f64) void {
        if (!self.armed) return;
        const dx = px - self.press_x;
        const dy = py - self.press_y;
        if (!self.dragging and (dx * dx + dy * dy) > 25.0) {
            self.dragging = true;
        }
        if (self.dragging) {
            self.grab_dx = dx;
            self.grab_dy = dy;
        }
    }

    pub fn cancel(self: *DragState) void {
        self.* = .{};
    }
};

pub fn moveWithin(list_len: usize, from: usize, insert_before: usize) usize {
    if (list_len == 0 or from >= list_len) return 0;
    var dst = insert_before;
    if (dst > list_len) dst = list_len;
    if (dst > from) dst -= 1;
    return dst;
}

pub const PickerState = struct {
    open: bool = false,
    section: Section = .none,
    filter_len: usize = 0,
    hover_slot: isize = -1,
    scroll_px: i32 = 0,
};

test "settings-widget-picker: drag arm/motion/cancel" {
    const t = std.testing;
    var d = DragState{};
    d.arm(.dock, 2, 100, 100);
    try t.expect(d.armed);
    d.motion(101, 101);
    try t.expect(!d.dragging);
    d.motion(120, 120);
    try t.expect(d.dragging);
    d.cancel();
    try t.expect(!d.armed);
}

test "settings-widget-picker: move index math" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 1), moveWithin(4, 0, 2));
    try t.expectEqual(@as(usize, 0), moveWithin(4, 2, 0));
    try t.expectEqual(@as(usize, 0), moveWithin(0, 0, 0));
}
