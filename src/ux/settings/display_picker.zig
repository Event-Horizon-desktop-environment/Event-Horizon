const std = @import("std");

// Display-output pickers — Zig port of
// src/ux/settings/utils/display/settings_display_dropdown.hpp.
// One picker per surface (dock/panel/taskbar/desktop-widgets/notifications).
// Same design: Auto + All + per-output rows; selection is an output name
// with "" meaning Auto.

pub const auto_label: []const u8 = "Auto";
pub const all_label: []const u8 = "All";

pub const DisplayPicker = struct {
    selected_name: []const u8 = "",
    show_all_row: bool = true,

    pub fn labelFor(self: *const DisplayPicker, alloc: std.mem.Allocator, output_name: []const u8) ![]u8 {
        if (output_name.len == 0) return alloc.dupe(u8, auto_label);
        if (std.mem.eql(u8, output_name, "all") and self.show_all_row) return alloc.dupe(u8, all_label);
        return alloc.dupe(u8, output_name);
    }

    pub fn rowCount(self: *const DisplayPicker, output_count: usize) usize {
        return 1 + (if (self.show_all_row) @as(usize, 1) else 0) + output_count;
    }

    /// Map a popup row back to an output name. Returns null for out-of-range.
    /// Row 0 = Auto(""), row 1 = All("all") when shown, rest = outputs[i].
    pub fn nameForRow(self: *const DisplayPicker, outputs: []const []const u8, row: usize) ?[]const u8 {
        if (row == 0) return "";
        var r = row - 1;
        if (self.show_all_row) {
            if (r == 0) return "all";
            r -= 1;
        }
        if (r < outputs.len) return outputs[r];
        return null;
    }
};

test "settings-display-picker: rows and mapping" {
    const t = std.testing;
    const p = DisplayPicker{};
    try t.expectEqual(@as(usize, 4), p.rowCount(2));
    const outs = [_][]const u8{ "DP-1", "HDMI-1" };
    try t.expectEqualStrings("", p.nameForRow(&outs, 0).?);
    try t.expectEqualStrings("all", p.nameForRow(&outs, 1).?);
    try t.expectEqualStrings("DP-1", p.nameForRow(&outs, 2).?);
    try t.expect(p.nameForRow(&outs, 9) == null);
    const lbl = try p.labelFor(t.allocator, "");
    defer t.allocator.free(lbl);
    try t.expectEqualStrings("Auto", lbl);
}
