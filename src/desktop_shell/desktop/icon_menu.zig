const std = @import("std");
const icon_item = @import("icon_item.zig");

/// Icon right-click context menu + mount dialog.
///
/// Row model (`IconCtxMenuRow::Kind`): Open, OpenWith, DesktopEntryAction(i),
/// Separator, OpenLocation, RunElevated, PinStart, PinTaskbar, Separator2,
/// Cut, Copy, CreateShortcut, Delete, Rename, Properties, ExtractArchive,
/// CompressSubmenu, CompressZip, CompressTarGz, CompressTar, Compress7z,
/// Mount, Unmount, EmptyTrash.
///
/// Geometry (scaled by `us`): `W measured, RightPad=6*us, RowH=28*us,
/// Pad=10*us, Corner=8*us, Hl=5*us, Gap=4*us, MinCompressW=180*us,
/// IconMinW=120*us, ChevronGap=8*us` (matches desktop_menu constants).

pub const CtxKind = enum(u8) {
    open = 0,
    open_with = 1,
    desktop_action = 2,
    separator = 3,
    open_location = 4,
    run_elevated = 5,
    pin_start = 6,
    pin_taskbar = 7,
    separator2 = 8,
    cut = 9,
    copy = 10,
    create_shortcut = 11,
    delete = 12,
    rename = 13,
    properties = 14,
    extract_archive = 15,
    compress_submenu = 16,
    compress_zip = 17,
    compress_tar_gz = 18,
    compress_tar = 19,
    compress_7z = 20,
    mount = 21,
    unmount = 22,
    empty_trash = 23,
};

pub const CtxRow = struct {
    kind: CtxKind,
    action_index: u16 = 0,
};

pub const row_h: f64 = 28.0;
pub const pad: f64 = 10.0;
pub const menu_right_pad: f64 = 6.0;
pub const cascade_gap: f64 = 4.0;
pub const min_compress_w: f64 = 180.0;
pub const min_icon_menu_w: f64 = 120.0;
pub const clamp_margin: f64 = 4.0;
pub const compress_sub_rows: usize = 4;

pub fn isSep(r: CtxRow) bool {
    return r.kind == .separator or r.kind == .separator2;
}

pub fn isCompressSubmenu(r: CtxRow) bool {
    return r.kind == .compress_submenu;
}

pub fn menuHeight(rows: usize, us: f64) f64 {
    return @as(f64, @floatFromInt(rows)) * row_h * us + pad * us * 2.0;
}

/// Rebuild rows (`rebuild_icon_ctx_rows`, `:217-323`).
/// `sel` are the selected icon indices; `icons` the full store; `archives`
/// marks which selected paths are archives; `action_count` is the number of
/// valid `.desktop` actions for a single Application icon.
pub fn rebuildRows(
    alloc: std.mem.Allocator,
    sel_kinds: []const icon_item.IconKind,
    drive_mounted: bool,
    show_extract: bool,
    action_count: usize,
) ![]CtxRow {
    var out: std.ArrayList(CtxRow) = .empty;
    errdefer out.deinit(alloc);
    if (sel_kinds.len == 0) return out.toOwnedSlice(alloc);
    const multi = sel_kinds.len > 1;
    if (multi) {
        try out.append(alloc, .{ .kind = .open });
        if (show_extract) try out.append(alloc, .{ .kind = .extract_archive });
        try out.append(alloc, .{ .kind = .compress_submenu });
        try out.append(alloc, .{ .kind = .separator });
        try out.append(alloc, .{ .kind = .cut });
        try out.append(alloc, .{ .kind = .copy });
        try out.append(alloc, .{ .kind = .separator2 });
        try out.append(alloc, .{ .kind = .delete });
        return out.toOwnedSlice(alloc);
    }
    const k = sel_kinds[0];
    switch (k) {
        .file, .folder => {
            try out.append(alloc, .{ .kind = .open });
            try out.append(alloc, .{ .kind = .open_with });
            if (show_extract) try out.append(alloc, .{ .kind = .extract_archive });
            try out.append(alloc, .{ .kind = .compress_submenu });
            try out.append(alloc, .{ .kind = .separator });
            try out.append(alloc, .{ .kind = .open_location });
            try out.append(alloc, .{ .kind = .separator2 });
            try out.append(alloc, .{ .kind = .cut });
            try out.append(alloc, .{ .kind = .copy });
            try out.append(alloc, .{ .kind = .separator });
            try out.append(alloc, .{ .kind = .delete });
            try out.append(alloc, .{ .kind = .rename });
            try out.append(alloc, .{ .kind = .properties });
        },
        .drive => {
            if (drive_mounted) {
                try out.append(alloc, .{ .kind = .open });
                try out.append(alloc, .{ .kind = .separator });
                try out.append(alloc, .{ .kind = .open_location });
                try out.append(alloc, .{ .kind = .separator2 });
                try out.append(alloc, .{ .kind = .copy });
                try out.append(alloc, .{ .kind = .separator });
                try out.append(alloc, .{ .kind = .unmount });
                try out.append(alloc, .{ .kind = .separator });
                try out.append(alloc, .{ .kind = .properties });
            } else {
                try out.append(alloc, .{ .kind = .mount });
                try out.append(alloc, .{ .kind = .separator });
                try out.append(alloc, .{ .kind = .properties });
            }
        },
        .trash => {
            try out.append(alloc, .{ .kind = .open });
            try out.append(alloc, .{ .kind = .empty_trash });
            try out.append(alloc, .{ .kind = .separator });
            try out.append(alloc, .{ .kind = .properties });
        },
        .my_computer => {
            try out.append(alloc, .{ .kind = .properties });
        },
        .application => {
            try out.append(alloc, .{ .kind = .open });
            for (0..action_count) |i| try out.append(alloc, .{ .kind = .desktop_action, .action_index = @intCast(i) });
            try out.append(alloc, .{ .kind = .separator });
            try out.append(alloc, .{ .kind = .open_location });
            try out.append(alloc, .{ .kind = .run_elevated });
            try out.append(alloc, .{ .kind = .separator2 });
            try out.append(alloc, .{ .kind = .pin_start });
            try out.append(alloc, .{ .kind = .pin_taskbar });
            try out.append(alloc, .{ .kind = .separator });
            try out.append(alloc, .{ .kind = .cut });
            try out.append(alloc, .{ .kind = .copy });
            try out.append(alloc, .{ .kind = .compress_submenu });
            try out.append(alloc, .{ .kind = .create_shortcut });
            try out.append(alloc, .{ .kind = .delete });
            try out.append(alloc, .{ .kind = .rename });
            try out.append(alloc, .{ .kind = .properties });
        },
    }
    return out.toOwnedSlice(alloc);
}

/// Row labels (`row_label`, `:325-380`). `action_name` is the
/// `DesktopEntryAction.name` for `desktop_action` rows; `pinned` toggles pin labels.
pub fn rowLabel(kind: CtxKind, action_name: ?[]const u8, pinned: bool) []const u8 {
    return switch (kind) {
        .open => "Open",
        .open_with => "Open With",
        .desktop_action => action_name orelse "",
        .open_location => "Open file location",
        .run_elevated => "Run as administrator",
        .pin_start => if (pinned) "Unpin from Start menu" else "Pin to Start menu",
        .pin_taskbar => if (pinned) "Unpin from Dock" else "Pin to Dock",
        .cut => "Cut",
        .copy => "Copy",
        .create_shortcut => "Create shortcut",
        .delete => "Delete",
        .rename => "Rename",
        .properties => "Properties",
        .extract_archive => "Extract to folder",
        .compress_submenu => "Compress",
        .compress_zip => "Compress to ZIP",
        .compress_tar_gz => "Compress to tar.gz",
        .compress_tar => "Compress to tar",
        .compress_7z => "Compress to 7z",
        .mount => "Mount",
        .unmount => "Unmount",
        .empty_trash => "Empty Trash",
        .separator, .separator2 => "",
    };
}

pub fn compressSubLabel(row: usize) []const u8 {
    return switch (row) {
        0 => "Compress to ZIP",
        1 => "Compress to tar.gz",
        2 => "Compress to tar",
        else => "Compress to 7z",
    };
}

/// Compress cascade anchor (`layout_compress_cascade`, `:92-111`):
/// right of main, flip left on overflow, clamp vertically.
pub fn compressCascadePos(
    mx: f64,
    my: f64,
    mw: f64,
    anchor_row: i32,
    sub_w: f64,
    sub_h: f64,
    layer_w: i32,
    layer_h: i32,
    us: f64,
) struct { x: f64, y: f64 } {
    const anchor_y = my + pad * us + @as(f64, @floatFromInt(anchor_row)) * row_h * us;
    var sx = mx + mw + cascade_gap * us;
    if (layer_w > 0 and sx + sub_w > @as(f64, @floatFromInt(layer_w)) - clamp_margin * us)
        sx = mx - sub_w - cascade_gap * us;
    var sy = anchor_y;
    if (layer_h > 0) {
        sy = std.math.clamp(sy, clamp_margin * us, @max(clamp_margin * us, @as(f64, @floatFromInt(layer_h)) - sub_h - clamp_margin * us));
    } else {
        sy = @max(clamp_margin * us, sy);
    }
    return .{ .x = sx, .y = sy };
}

/// Hit test shared by main + compress cascade (`hit_*`, main `:178-192`
/// pattern reused for icon menus).
pub fn hitMenuRow(lx: f64, ly: f64, mx: f64, my: f64, mw: f64, rows: usize, rows_are_sep: []const bool, us: f64) i32 {
    const mh = menuHeight(rows, us);
    if (lx < mx or ly < my or lx >= mx + mw or ly >= my + mh) return -2;
    const rel = ly - my - pad * us;
    const row: i32 = @intFromFloat(@floor(rel / (row_h * us)));
    if (row < 0 or row >= @as(i32, @intCast(rows))) return -1;
    if (rows_are_sep[@intCast(row)]) return -1;
    return row;
}

pub const mount_w: f64 = 400.0;
// Taller than the C++ 210: the card carries Device/Filesystem/UUID info rows
// plus the mount-option checkboxes, GNOME Disks-style, above the mount-point
// combo (see `fstab-dialog` in gnome-disk-utility: startup/show/auth rows).
pub const mount_base_h: f64 = 370.0;
pub const mount_row_h: f64 = 22.0;
pub const mount_extra_h: f64 = 8.0;
// Combo-box top offset: title 24 + label 46 + three 20px info rows + hint.
pub const mount_box_y: f64 = 146.0;
// Read-only checkbox sits one checkbox pitch below the boot checkbox.
pub const mount_check_dy: f64 = 28.0;

/// Dialog size: `400*us x (286*us + dropdown ? 3*22*us + 8*us : 0)`.
pub fn mountDialogSize(dropdown_open: bool, us: f64) struct { w: f64, h: f64 } {
    var h = mount_base_h * us;
    if (dropdown_open) h += 3.0 * mount_row_h * us + mount_extra_h * us;
    return .{ .w = mount_w * us, .h = h };
}

pub fn mountDialogPos(layer_w: i32, layer_h: i32, w: f64, h: f64) struct { x: f64, y: f64 } {
    return .{
        .x = @max(0.0, @as(f64, @floatFromInt(layer_w)) / 2.0 - w / 2.0),
        .y = @max(0.0, @as(f64, @floatFromInt(layer_h)) / 2.0 - h / 2.0),
    };
}

/// Mount-point candidates (`/run/media/$USER/label`, `/media/label`, `/mnt/label`).
pub fn mountCandidate(alloc: std.mem.Allocator, base: u8, user: []const u8, label: []const u8) ![]u8 {
    return switch (base) {
        0 => std.fmt.allocPrint(alloc, "/run/media/{s}/{s}", .{ user, label }),
        1 => std.fmt.allocPrint(alloc, "/media/{s}", .{label}),
        else => std.fmt.allocPrint(alloc, "/mnt/{s}", .{label}),
    };
}

pub const MountDeferred = enum(u8) {
    none = 0,
    mount_dialog = 1,
    fstab_mount = 2,
    unmount = 3,
};

/// Rename title by kind (`CreateShortcut/Delete/Rename` block).
pub fn renameTitle(kind: icon_item.IconKind) []const u8 {
    return switch (kind) {
        .application => "Rename desktop shortcut",
        .file => "Rename file",
        .folder => "Rename folder",
        else => "Rename",
    };
}

/// Sanitize rename input (`/` and NUL become `_`).
pub fn sanitizeRename(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, s);
    for (out) |*c| {
        if (c.* == '/' or c.* == 0) c.* = '_';
    }
    return out;
}

/// Mount dialog item ids (paint + hit order, `:562-585` dialog, extended
/// GNOME Disks-style): 0 combo box, 1..3 mount-point radio list (visible when
/// dropdown open), 4 `Mount at boot` master, 5 Mount button, 6 Cancel button,
/// 7 `Read-only`, 8 `Mount at system startup` (`!noauto`), 9 `Show in file
/// manager` (`x-gvfs-show`), 10 `Require authorization` (`x-udisks-auth`).
/// Items 8..10 only take effect while 4 is on (Disks dims its grid when its
/// `User Session Defaults` switch is on).
pub const mount_item_combo: i32 = 0;
pub const mount_item_boot: i32 = 4;
pub const mount_item_mount: i32 = 5;
pub const mount_item_cancel: i32 = 6;
pub const mount_item_readonly: i32 = 7;
pub const mount_item_startup: i32 = 8;
pub const mount_item_showui: i32 = 9;
pub const mount_item_auth: i32 = 10;

/// Item is an fstab-only sub-option (dead unless `Mount at boot` is on).
pub fn mountItemNeedsBoot(item: i32) bool {
    return item == mount_item_startup or item == mount_item_showui or item == mount_item_auth;
}

pub fn mountItemCount(dropdown_open: bool) i32 {
    return if (dropdown_open) 11 else 8;
}

/// Shared rect type for dialog geometry so paint and hit tests in
/// `desktop.zig` can pass `mountItemRect` results around by name (Zig treats
/// each anonymous `struct {...}` literal type as distinct).
pub const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

/// Combo/list/radio/checkbox/button rects inside the dialog (all scaled by us).
/// Dialog origin (x,y), width `w` from mountDialogSize/Pos. `dropdown_open`
/// shifts the checkbox and the two buttons down by the open list height, which
/// is how C++ lays the dialog out (`paint_mount_dialog` / `mount_dialog_hit_item`).
pub fn mountItemRect(item: i32, x: f64, y: f64, w: f64, dropdown_open: bool, us: f64) Rect {
    const box_x = x + 16 * us;
    const box_y = y + mount_box_y * us;
    const box_w = w - 32 * us;
    const box_h = 26 * us;
    const item_h = mount_row_h * us;
    if (item == mount_item_combo) {
        return .{ .x = box_x, .y = box_y, .w = box_w, .h = box_h };
    }
    if (item >= 1 and item <= 3) {
        const list_top = box_y + box_h;
        return .{ .x = box_x, .y = list_top + @as(f64, @floatFromInt(item - 1)) * item_h, .w = box_w, .h = item_h };
    }
    if (item == mount_item_boot) {
        const list_extra: f64 = if (dropdown_open) 3.0 * item_h else 0.0;
        return .{ .x = box_x, .y = box_y + box_h + list_extra + 8 * us, .w = box_w, .h = 22 * us };
    }
    if (item == mount_item_readonly) {
        const boot = mountItemRect(mount_item_boot, x, y, w, dropdown_open, us);
        return .{ .x = boot.x, .y = boot.y + mount_check_dy * us, .w = boot.w, .h = 22 * us };
    }
    if (item == mount_item_startup or item == mount_item_showui or item == mount_item_auth) {
        const boot = mountItemRect(mount_item_boot, x, y, w, dropdown_open, us);
        // One pitch per row below boot: readonly sits at +1, so startup is
        // +2, show +3, auth +4.
        const step: f64 = @floatFromInt(item - mount_item_readonly + 1);
        return .{ .x = boot.x, .y = boot.y + step * mount_check_dy * us, .w = boot.w, .h = 22 * us };
    }
    // Buttons: two 100x32 centered with 12 gap, 12 above the dialog's
    // *current* bottom (`btnY = dialogY + dlgH - 12 - btnH`).
    const bw: f64 = 100 * us;
    const bh: f64 = 32 * us;
    const dlg_h = mountDialogSize(dropdown_open, us).h;
    const cy = y + dlg_h - 12 * us - bh;
    const cx = x + w / 2.0;
    if (item == mount_item_mount) return .{ .x = cx - bw - 6 * us, .y = cy, .w = bw, .h = bh };
    return .{ .x = cx + 6 * us, .y = cy, .w = bw, .h = bh };
}

/// Hit test matching C++ `mount_dialog_hit_item`: dropdown radio rows first,
/// then the combo box, the checkboxes and the two buttons. Returns -2 when
/// the point is outside the dialog card, -1 when inside but on no item.
pub fn hitMountItem(lx: f64, ly: f64, x: f64, y: f64, w: f64, h: f64, dropdown_open: bool, us: f64) i32 {
    if (lx < x or ly < y or lx >= x + w or ly >= y + h) return -2;
    // Radio rows only exist while the dropdown is open.
    if (dropdown_open) {
        for ([3]i32{ 1, 2, 3 }) |i| {
            const r = mountItemRect(i, x, y, w, true, us);
            if (lx >= r.x and ly >= r.y and lx < r.x + r.w and ly < r.y + r.h) return i;
        }
    }
    const rest = [_]i32{ mount_item_combo, mount_item_boot, mount_item_readonly, mount_item_startup, mount_item_showui, mount_item_auth, mount_item_mount, mount_item_cancel };
    for (rest) |i| {
        const r = mountItemRect(i, x, y, w, dropdown_open, us);
        if (lx >= r.x and ly >= r.y and lx < r.x + r.w and ly < r.y + r.h) return i;
    }
    return -1;
}

/// fstab `opts` field in the GNOME Disks shape (`fstab-dialog` in
/// gnome-disk-utility, confirmed against its embedded GtkBuilder template):
/// `nosuid,nodev,nofail` base, `noauto` unless mounting at startup, an
/// `x-gvfs-show`/`x-gvfs-hide` marker for file-manager visibility, and
/// `x-udisks-auth` when mounting needs extra authorization. Disks' own
/// default line is `nosuid,nodev,nofail,x-gvfs-show`. Composed into the
/// caller buffer (longest output is 55 bytes); returns the filled slice.
pub fn fstabOpts(buf: []u8, readonly: bool, startup: bool, show_ui: bool, require_auth: bool) []const u8 {
    const s = std.fmt.bufPrint(buf, "nosuid,nodev,nofail{s}{s}{s}{s}", .{
        if (readonly) ",ro" else "",
        if (startup) "" else ",noauto",
        if (show_ui) ",x-gvfs-show" else ",x-gvfs-hide",
        if (require_auth) ",x-udisks-auth" else "",
    }) catch return "nosuid,nodev,nofail,x-gvfs-show";
    return s;
}

/// `has_fstab_entry`: pure check over `/etc/fstab` text (device or uuid present).
pub fn hasFstabEntry(fstab_text: []const u8, device: []const u8, uuid: []const u8) bool {
    var it = std.mem.splitScalar(u8, fstab_text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (device.len > 0 and std.mem.indexOf(u8, line, device) != null) return true;
        if (uuid.len > 0 and std.mem.indexOf(u8, line, uuid) != null) return true;
    }
    return false;
}

/// Shortcut dest `dir/stem+" shortcut.desktop"` with `(n)` numbering.
pub fn shortcutDest(alloc: std.mem.Allocator, dir: []const u8, stem: []const u8, exists: *const fn ([]const u8) bool) ![]u8 {
    var n: usize = 0;
    while (true) : (n += 1) {
        const cand = if (n == 0)
            try std.fmt.allocPrint(alloc, "{s}/{s} shortcut.desktop", .{ dir, stem })
        else
            try std.fmt.allocPrint(alloc, "{s}/{s} shortcut ({d}).desktop", .{ dir, stem, n });
        errdefer alloc.free(cand);
        if (!exists(cand)) return cand;
        alloc.free(cand);
        if (n > 9999) return error.OutOfNames;
    }
}

/// Icon-menu press/motion/release arm state (mirrors `desktop_menu` pattern):
/// press inside arms, release on same row activates.
pub const IconPress = struct {
    arm_main: i32 = -1,
    arm_compress: i32 = -1,
    hover_main: i32 = -1,
    hover_compress: i32 = -1,
    cascade_open: bool = false,
    anchor_row: i32 = -1,

    pub fn press(self: *IconPress, main_row: i32, compress_row: i32) void {
        if (compress_row >= 0) {
            self.arm_main = -1;
            self.arm_compress = compress_row;
        } else if (main_row >= 0) {
            self.arm_main = main_row;
            self.arm_compress = -1;
        } else {
            self.arm_main = -1;
            self.arm_compress = -1;
        }
    }

    pub fn motion(self: *IconPress, main_row: i32, compress_row: i32, rows: []const CtxRow) void {
        if (compress_row >= 0) {
            self.hover_compress = compress_row;
            self.hover_main = self.anchor_row;
            return;
        }
        if (main_row >= 0) {
            self.hover_main = main_row;
            self.hover_compress = -1;
            // Opening the cascade happens on the Compress row.
            if (main_row < rows.len and rows[@intCast(main_row)].kind == .compress_submenu) {
                self.cascade_open = true;
                self.anchor_row = main_row;
            } else {
                self.cascade_open = false;
            }
            return;
        }
        self.hover_main = -1;
        self.hover_compress = -1;
    }
};

/// Snapshot dispatch target (`apply_icon_menu_snapshot` switch, `:434-651`).
pub const SnapshotAction = enum {
    open,
    open_with,
    desktop_action,
    open_location,
    run_elevated,
    pin_start,
    pin_taskbar,
    cut,
    copy,
    create_shortcut,
    delete,
    rename,
    properties,
    extract,
    compress_zip,
    compress_tar_gz,
    compress_tar,
    compress_7z,
    mount,
    unmount,
    empty_trash,
    none,
};

pub fn snapshotActionFor(kind: CtxKind) SnapshotAction {
    return switch (kind) {
        .open => .open,
        .open_with => .open_with,
        .desktop_action => .desktop_action,
        .open_location => .open_location,
        .run_elevated => .run_elevated,
        .pin_start => .pin_start,
        .pin_taskbar => .pin_taskbar,
        .cut => .cut,
        .copy => .copy,
        .create_shortcut => .create_shortcut,
        .delete => .delete,
        .rename => .rename,
        .properties => .properties,
        .extract_archive => .extract,
        .compress_zip => .compress_zip,
        .compress_tar_gz => .compress_tar_gz,
        .compress_tar => .compress_tar,
        .compress_7z => .compress_7z,
        .mount => .mount,
        .unmount => .unmount,
        .empty_trash => .empty_trash,
        .compress_submenu, .separator, .separator2 => .none,
    };
}

test "icon_menu: multi + file + drive + trash + app rows" {
    const t = std.testing;
    {
        const kinds = [_]icon_item.IconKind{ .file, .file };
        const rows = try rebuildRows(t.allocator, &kinds, true, false, 0);
        defer t.allocator.free(rows);
        try t.expectEqual(@as(usize, 7), rows.len);
        try t.expectEqual(CtxKind.open, rows[0].kind);
        try t.expectEqual(CtxKind.compress_submenu, rows[1].kind);
        try t.expectEqual(CtxKind.delete, rows[6].kind);
    }
    {
        const kinds = [_]icon_item.IconKind{.file};
        const rows = try rebuildRows(t.allocator, &kinds, true, true, 0);
        defer t.allocator.free(rows);
        // Open, OpenWith, Extract, Compress, Sep, OpenLocation, Sep2, Cut, Copy, Sep, Delete, Rename, Properties
        try t.expectEqual(@as(usize, 13), rows.len);
        try t.expectEqual(CtxKind.extract_archive, rows[2].kind);
    }
    {
        const kinds = [_]icon_item.IconKind{.drive};
        const rows = try rebuildRows(t.allocator, &kinds, true, false, 0);
        defer t.allocator.free(rows);
        try t.expectEqual(CtxKind.unmount, rows[6].kind);
        const kinds2 = [_]icon_item.IconKind{.drive};
        const rows2 = try rebuildRows(t.allocator, &kinds2, false, false, 0);
        defer t.allocator.free(rows2);
        try t.expectEqual(@as(usize, 3), rows2.len);
        try t.expectEqual(CtxKind.mount, rows2[0].kind);
    }
    {
        const kinds = [_]icon_item.IconKind{.trash};
        const rows = try rebuildRows(t.allocator, &kinds, true, false, 0);
        defer t.allocator.free(rows);
        try t.expectEqual(CtxKind.empty_trash, rows[1].kind);
    }
    {
        const kinds = [_]icon_item.IconKind{.application};
        const rows = try rebuildRows(t.allocator, &kinds, true, false, 2);
        defer t.allocator.free(rows);
        try t.expectEqual(CtxKind.desktop_action, rows[1].kind);
        try t.expectEqual(@as(u16, 1), rows[2].action_index);
        try t.expectEqual(CtxKind.run_elevated, rows[5].kind);
    }
}

test "icon_menu: labels + hit + mount dialog" {
    const t = std.testing;
    try t.expectEqualStrings("Open With", rowLabel(.open_with, null, false));
    try t.expectEqualStrings("Pin to Dock", rowLabel(.pin_taskbar, null, false));
    try t.expectEqualStrings("Unpin from Dock", rowLabel(.pin_taskbar, null, true));
    try t.expectEqualStrings("Compress to tar.gz", compressSubLabel(1));
    try t.expect(isSep(.{ .kind = .separator }));
    try t.expect(!isSep(.{ .kind = .open }));
    const seps = [_]bool{ false, true, false };
    try t.expectEqual(@as(i32, 0), hitMenuRow(20, 25, 10, 10, 200, 3, &seps, 1.0));
    try t.expectEqual(@as(i32, -1), hitMenuRow(20, 10 + 10 + 28 + 5, 10, 10, 200, 3, &seps, 1.0));
    try t.expectEqual(@as(i32, -2), hitMenuRow(0, 0, 10, 10, 200, 3, &seps, 1.0));
    const sz = mountDialogSize(true, 1.0);
    try t.expectEqual(@as(f64, 400), sz.w);
    try t.expectApproxEqAbs(@as(f64, 370 + 66 + 8), sz.h, 1e-9);
    const p = mountDialogPos(1920, 1080, 400, 210);
    try t.expectApproxEqAbs(@as(f64, 760), p.x, 1e-9);
    const m0 = try mountCandidate(t.allocator, 0, "u", "disk");
    defer t.allocator.free(m0);
    try t.expectEqualStrings("/run/media/u/disk", m0);
    try t.expectEqualStrings("Rename file", renameTitle(.file));
    const s = try sanitizeRename(t.allocator, "a/b\x00c");
    defer t.allocator.free(s);
    try t.expectEqualStrings("a_b_c", s);
}

test "icon_menu: mount items + fstab + shortcut + press state" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 11), mountItemCount(true));
    try t.expectEqual(@as(i32, 8), mountItemCount(false));
    const r = mountItemRect(5, 760, 435, 400, false, 1.0);
    try t.expect(r.w == 100 and r.h == 32);
    // Closed dialog: buttons sit 12px above the 370px card bottom (y+435+326).
    try t.expectApproxEqAbs(@as(f64, 435 + 370 - 12 - 32), r.y, 1e-9);
    // Open dialog (444 tall): combo box, then the first radio row.
    try t.expectEqual(@as(i32, 0), hitMountItem(800, 590, 760, 435, 400, 444, true, 1.0));
    try t.expectEqual(@as(i32, 1), hitMountItem(800, 615, 760, 435, 400, 444, true, 1.0));
    try t.expectEqual(@as(i32, -2), hitMountItem(0, 0, 760, 435, 400, 444, true, 1.0));
    // Closed dialog still hits Mount (item 5) and Cancel (item 6).
    try t.expectEqual(@as(i32, 5), hitMountItem(760 + 94 + 50, 435 + 326 + 16, 760, 435, 400, 370, false, 1.0));
    try t.expectEqual(@as(i32, 6), hitMountItem(760 + 94 + 100 + 12 + 50, 435 + 326 + 16, 760, 435, 400, 370, false, 1.0));
    try t.expectEqual(@as(i32, 4), hitMountItem(760 + 100, 435 + 146 + 26 + 8 + 10, 760, 435, 400, 370, false, 1.0));
    try t.expectEqual(@as(i32, 7), hitMountItem(760 + 100, 435 + 146 + 26 + 8 + 28 + 10, 760, 435, 400, 370, false, 1.0));
    // GNOME Disks sub-rows: startup, show-in-UI, require-auth.
    try t.expectEqual(@as(i32, 8), hitMountItem(760 + 100, 435 + 146 + 26 + 8 + 56 + 10, 760, 435, 400, 370, false, 1.0));
    try t.expectEqual(@as(i32, 9), hitMountItem(760 + 100, 435 + 146 + 26 + 8 + 84 + 10, 760, 435, 400, 370, false, 1.0));
    try t.expectEqual(@as(i32, 10), hitMountItem(760 + 100, 435 + 146 + 26 + 8 + 112 + 10, 760, 435, 400, 370, false, 1.0));
    try t.expect(mountItemNeedsBoot(8) and mountItemNeedsBoot(9) and mountItemNeedsBoot(10));
    try t.expect(!mountItemNeedsBoot(4) and !mountItemNeedsBoot(7) and !mountItemNeedsBoot(5));
    // Disks-shaped fstab opts: base, no-startup, hidden, authorized, combined.
    var obuf: [64]u8 = undefined;
    try t.expectEqualStrings("nosuid,nodev,nofail,x-gvfs-show", fstabOpts(&obuf, false, true, true, false));
    try t.expectEqualStrings("nosuid,nodev,nofail,noauto,x-gvfs-show", fstabOpts(&obuf, false, false, true, false));
    try t.expectEqualStrings("nosuid,nodev,nofail,x-gvfs-hide", fstabOpts(&obuf, false, true, false, false));
    try t.expectEqualStrings("nosuid,nodev,nofail,ro,x-gvfs-show,x-udisks-auth", fstabOpts(&obuf, true, true, true, true));
    try t.expect(hasFstabEntry("UUID=abc /mnt/disk ext4 defaults 0 0\n", "/dev/sdb1", "abc"));
    try t.expect(!hasFstabEntry("# empty\n", "/dev/sdb1", "zzz"));
    const S = struct {
        fn no(_: []const u8) bool {
            return false;
        }
    };
    const sc = try shortcutDest(t.allocator, "/d", "Firefox", &S.no);
    defer t.allocator.free(sc);
    try t.expectEqualStrings("/d/Firefox shortcut.desktop", sc);
    var pr = IconPress{};
    pr.press(3, -1);
    try t.expectEqual(@as(i32, 3), pr.arm_main);
    const rows = [_]CtxRow{ .{ .kind = .open }, .{ .kind = .compress_submenu } };
    pr.motion(1, -1, &rows);
    try t.expect(pr.cascade_open);
    try t.expectEqual(SnapshotAction.open, snapshotActionFor(.open));
    try t.expectEqual(SnapshotAction.compress_tar_gz, snapshotActionFor(.compress_tar_gz));
    try t.expectEqual(SnapshotAction.none, snapshotActionFor(.compress_submenu));
}
