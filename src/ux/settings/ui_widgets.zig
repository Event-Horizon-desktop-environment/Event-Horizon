const std = @import("std");
const app_mod = @import("app.zig");
const common = @import("common.zig");
const rows_mod = @import("rows.zig");
const ui_paint = @import("ui_paint.zig");
const widget_persist = @import("widget_persist.zig");
const mon_state = @import("monitors_state.zig");
const mon_tab = @import("monitors_tab_helpers.zig");
const mon_page = @import("monitors_page.zig");
const cairo = @import("../../wl/buffer/shm.zig").cairo;
const m3_button = @import("../../m3/controls/containers/button.zig");
const m3_box = @import("../../m3/core/primitives/box.zig");

/// "2560x1440 @144Hz" from the row's own strings — the canvas subtitle.
fn modeLine(row: *const mon_state.MonitorRow, buf: []u8) []const u8 {
    const res = row.resolution.slice();
    const hz = row.refresh_rate.slice();
    if (res.len == 0 and hz.len == 0) return "No mode set";
    if (hz.len == 0) return std.fmt.bufPrint(buf, "{s}", .{res}) catch "";
    return std.fmt.bufPrint(buf, "{s} @{s}Hz", .{ res, hz }) catch "";
}

// Row painters for the wide custom rows: the three-column widget board
// (Widgets child tabs), the monitors toolbar / arrange canvas / output
// pills. Geometry helpers are shared with ui_content's hit-test so paint
// and input can never disagree.

// Unified with `common.Rect` (identical layout): the refactor left two
// same-shaped rect types and call sites mix them, which the compiler
// rejects. One canonical type until the dedup lands properly.
pub const Rect = common.Rect;
pub const board_pad: i32 = 16;
pub const col_gap: i32 = 12;
pub const btn_w: i32 = 150;
pub const btn_h: i32 = 32;
pub const pill_w: i32 = 100;
pub const pill_h: i32 = 28;

/// (column, index) of an enable switch inside a widget board.
pub const WidgetRef = struct { col: usize, idx: usize };

/// Dragged-card state for a widget board, shared by paint and input so the
/// two can never disagree. Tracks the source section/index and the target
/// section/insert-before index: `insert_before` is in erased space (the source row already
/// removed), `lift_x/y` is the lifted card's origin in layout space.
pub const BoardDrag = struct {
    active: bool = false,
    dragging: bool = false,
    src_col: usize = 0,
    src_idx: usize = 0,
    target_col: usize = 0,
    insert_before: usize = 0,
    press_x: f64 = 0,
    press_y: f64 = 0,
    grab_dx: f64 = 0,
    grab_dy: f64 = 0,
    lift_x: f64 = 0,
    lift_y: f64 = 0,
    id: []const u8 = "",
};

/// Widget id -> display title + Material ligature. Titles and ligatures are
/// ported verbatim from the C++ `widget_display_title`
/// (`settings_widget_drag.cpp`) and `dock_widget_material_ligature`
/// (`material_glyphs.cpp`), so the board and picker show the same names and
/// icons the C++ shell does.
pub fn widgetMeta(id: []const u8) struct { title: []const u8, glyph: []const u8 } {
    const Pair = struct { id: []const u8, title: []const u8, glyph: []const u8 };
    const table = [_]Pair{
        .{ .id = "pinned_apps", .title = "Pinned Apps", .glyph = "push_pin" },
        .{ .id = "running_apps", .title = "Running Apps", .glyph = "apps" },
        .{ .id = "win7_tasks", .title = "Win7 Tasklist", .glyph = "app_registration" },
        .{ .id = "tray", .title = "System Tray", .glyph = "notifications" },
        .{ .id = "settings_button", .title = "Settings", .glyph = "settings" },
        .{ .id = "distro_spotlight", .title = "Spotlight", .glyph = "search" },
        .{ .id = "spotlight", .title = "Spotlight", .glyph = "search" },
        .{ .id = "app_menu", .title = "App menu", .glyph = "apps" },
        .{ .id = "app_drawer", .title = "App drawer", .glyph = "widgets" },
        .{ .id = "smenu", .title = "Start Menu", .glyph = "menu" },
        .{ .id = "launchpad", .title = "Launchpad", .glyph = "rocket_launch" },
        .{ .id = "clock", .title = "Clock", .glyph = "schedule" },
        .{ .id = "weather", .title = "Weather", .glyph = "partly_cloudy_day" },
        .{ .id = "weather_fancy", .title = "Weather Fancy", .glyph = "cloud" },
        .{ .id = "calendar", .title = "Calendar", .glyph = "calendar_month" },
        .{ .id = "system_monitor", .title = "System Monitor", .glyph = "monitoring" },
        .{ .id = "media", .title = "Media", .glyph = "music_note" },
        .{ .id = "media_compact", .title = "Media Compact", .glyph = "music_note" },
        .{ .id = "fetch", .title = "System Info", .glyph = "terminal" },
        .{ .id = "volume", .title = "Volume", .glyph = "volume_up" },
        .{ .id = "mic", .title = "Microphone", .glyph = "mic" },
        .{ .id = "network", .title = "Network", .glyph = "wifi" },
        .{ .id = "mixer", .title = "Mixer", .glyph = "tune" },
        .{ .id = "workspaces", .title = "Workspaces", .glyph = "view_module" },
        .{ .id = "world_clock", .title = "World Clock", .glyph = "public" },
        .{ .id = "control_center", .title = "Control Center", .glyph = "tune" },
        .{ .id = "pear_center", .title = "PearCenter", .glyph = "tune" },
        .{ .id = "notifications", .title = "Notifications", .glyph = "notifications" },
        .{ .id = "overview", .title = "Overview", .glyph = "dashboard" },
        .{ .id = "layout", .title = "Window Layout", .glyph = "grid_view" },
        .{ .id = "window_layout", .title = "Window Layout", .glyph = "grid_view" },
        .{ .id = "spacer", .title = "Spacer", .glyph = "horizontal_rule" },
        .{ .id = "trash", .title = "Trash", .glyph = "delete" },
        .{ .id = "volume_mixer", .title = "Volume Mixer", .glyph = "volume_up" },
        .{ .id = "vpn", .title = "VPN", .glyph = "vpn_key" },
        .{ .id = "battery", .title = "Battery", .glyph = "battery_full" },
        .{ .id = "bluetooth", .title = "Bluetooth", .glyph = "bluetooth" },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e.id, id)) return .{ .title = e.title, .glyph = e.glyph };
    }
    // Unknown id: fall back to a mapped icon too, so nothing can reach the
    // Material-font path and render literal fallback text over a card title.
    return .{ .title = id, .glyph = "widgets" };
}

/// Widget id -> one-line description, ported verbatim from the C++ picker's
/// `widget_display_desc` (`widget_picker.cpp`). Used by the add-widget modal's
/// card grid; unknown ids get no description.
pub fn widgetDesc(id: []const u8) []const u8 {
    const Pair = struct { id: []const u8, desc: []const u8 };
    const table = [_]Pair{
        .{ .id = "pinned_apps", .desc = "Shows pinned apps (and running indicators)" },
        .{ .id = "running_apps", .desc = "Shows running applications with focus indication" },
        .{ .id = "win7_tasks", .desc = "Win7-style unified buttons: launch + switch, labels, stacking (taskbar only)" },
        .{ .id = "tray", .desc = "System notification area icons" },
        .{ .id = "settings_button", .desc = "Quick access to this settings window" },
        .{ .id = "app_menu", .desc = "Nine-dot icon; opens the full start-menu style app drawer" },
        .{ .id = "app_drawer", .desc = "OS logo; opens the same full app drawer as App menu" },
        .{ .id = "smenu", .desc = "Start menu icon; opens search + app grid (no pinned, no power buttons)" },
        .{ .id = "distro_spotlight", .desc = "Compact search with distro logo (dock Spotlight), not the full app drawer" },
        .{ .id = "clock", .desc = "Time and date (12h by default); optional [widget.clock] in TOML" },
        .{ .id = "weather", .desc = "Open-Meteo strip (icon, temp, unit); [widget.weather] weather_lat/lon or weather_city, weather_unit c|f" },
        .{ .id = "media", .desc = "MPRIS now-playing (title/artist, prev/play/next); optional [widget.media] in TOML" },
        .{ .id = "workspaces", .desc = "Hyprland workspace strip (hyprctl); optional [widget.workspaces] display=id|name|none" },
        .{ .id = "world_clock", .desc = "Multi-timezone clock w/ neon retro style; configurable via [widget.world_clock] in TOML" },
        .{ .id = "control_center", .desc = "Control Center classic popup (network, audio, mixer, media, weather); legacy design" },
        .{ .id = "pear_center", .desc = "PearCenter quick settings (network, audio, display, media); optional [widget.pear_center] pear_* booleans" },
        .{ .id = "notifications", .desc = "Bell opens PearCenter notifications; right-click toggles do-not-disturb" },
        .{ .id = "overview", .desc = "Button that opens the Overview (workspaces + windows)" },
        .{ .id = "spacer", .desc = "Empty slot one icon wide; use between dock groups instead of automatic gaps" },
        .{ .id = "trash", .desc = "Trash can icon (empty/full); right-click for Empty Trash" },
        .{ .id = "volume_mixer", .desc = "Volume mixer popup with device/app streams, sliders, mute, and EQ" },
        .{ .id = "vpn", .desc = "VPN connection popup with connect/disconnect" },
        .{ .id = "battery", .desc = "Battery percentage and charging state from UPower" },
        .{ .id = "bluetooth", .desc = "Bluetooth adapter status, connected devices, and power toggle" },
        .{ .id = "layout", .desc = "Hyprland + MangoWM window layout switcher (click to swap live)" },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e.id, id)) return e.desc;
    }
    return "";
}

fn colList(lists: [3][]const []const u8, col: usize) []const []const u8 {
    return switch (col) {
        0 => lists[0],
        1 => lists[1],
        else => lists[2],
    };
}

fn colX(p_x: i32, p_w: i32, col: usize) i32 {
    const inner = p_w - 2 * board_pad;
    const col_w = @divTrunc(inner - 2 * col_gap, 3);
    return p_x + board_pad + @as(i32, @intCast(col)) * (col_w + col_gap);
}

fn colW(p_w: i32) i32 {
    const inner = p_w - 2 * board_pad;
    return @divTrunc(inner - 2 * col_gap, 3);
}

fn listY(p_y: i32) i32 {
    return p_y + 26;
}

/// Widget card rect (col 0..2, idx within column).
pub fn cardRect(p_x: i32, p_y: i32, p_w: i32, col: usize, idx: usize) Rect {
    return .{
        .x = colX(p_x, p_w, col),
        .y = listY(p_y) + @as(i32, @intCast(idx)) * (rows_mod.widget_card_h + rows_mod.widget_card_gap),
        .w = colW(p_w),
        .h = rows_mod.widget_card_h,
    };
}

/// Remove (×) button hit box at a card's right edge — 26×26, 8px inset
/// (x = card.x + card.w - 8 - 26).
pub fn removeRect(card: Rect) Rect {
    return .{
        .x = card.x + card.w - 8 - 26,
        .y = card.y + @divTrunc(card.h - 26, 2),
        .w = 26,
        .h = 26,
    };
}

/// Toggle switch rect inside a widget card, 8px left of the remove button
/// (x = remove.x - 8 - toggleW).
pub fn toggleRect(r: Rect) Rect {
    const rm = removeRect(r);
    return .{
        .x = rm.x - 8 - common.toggle_w,
        .y = r.y + @divTrunc(r.h - common.toggle_h, 2),
        .w = common.toggle_w,
        .h = common.toggle_h,
    };
}

/// Widget toggle hit: (column, index) at window/layout point.
pub fn widgetHit(
    lists: [3][]const []const u8,
    p_x: i32,
    p_y: i32,
    p_w: i32,
    lx: f64,
    ly: f64,
) ?WidgetRef {
    for (0..3) |col| {
        const list = colList(lists, col);
        for (list, 0..) |_, i| {
            const tr = toggleRect(cardRect(p_x, p_y, p_w, col, i));
            if (common.pointInRect(lx, ly, .{
                .x = tr.x,
                .y = tr.y,
                .w = tr.w,
                .h = tr.h,
            })) return .{ .col = col, .idx = i };
        }
    }
    return null;
}

/// Remove (×) hit left of a card's toggle. Geometry matches the paint below.
pub fn widgetRemoveHit(
    lists: [3][]const []const u8,
    p_x: i32,
    p_y: i32,
    p_w: i32,
    lx: f64,
    ly: f64,
) ?WidgetRef {
    for (0..3) |col| {
        const list = colList(lists, col);
        for (list, 0..) |_, i| {
            const r = removeRect(cardRect(p_x, p_y, p_w, col, i));
            if (common.pointInRect(lx, ly, .{
                .x = r.x,
                .y = r.y,
                .w = r.w,
                .h = r.h,
            })) return .{ .col = col, .idx = i };
        }
    }
    return null;
}

/// Grip band at a card's left edge — 48px wide (covers the 6-dot grip and
/// the icon box; the toggle and remove live on the right edge, so nothing
/// conflicts with starting a drag here).
pub fn dragHandleRect(card: Rect) Rect {
    return .{
        .x = card.x,
        .y = card.y,
        .w = 48,
        .h = card.h,
    };
}

/// Drag-grip hit: (column, index) at window/layout point.
pub fn widgetDragHit(
    lists: [3][]const []const u8,
    p_x: i32,
    p_y: i32,
    p_w: i32,
    lx: f64,
    ly: f64,
) ?WidgetRef {
    for (0..3) |col| {
        const list = colList(lists, col);
        for (list, 0..) |_, i| {
            const r = dragHandleRect(cardRect(p_x, p_y, p_w, col, i));
            if (common.pointInRect(lx, ly, .{
                .x = r.x,
                .y = r.y,
                .w = r.w,
                .h = r.h,
            })) return .{ .col = col, .idx = i };
        }
    }
    return null;
}

/// Drop target for a drag at layout point (lx, ly): which column, and the
/// insert-before index within it in erased space (the dragged row skipped,
/// the same space `widget_lists.moveItem` commits into). Row midpoints
/// decide above/below from row midpoints; the column
/// is whichever band holds the pointer, nearest-column fallback.
pub fn widgetDropTarget(
    lists: [3][]const []const u8,
    p_x: i32,
    p_y: i32,
    p_w: i32,
    lx: f64,
    ly: f64,
    src_col: usize,
    src_idx: usize,
) struct { col: usize, insert_before: usize } {
    var col: usize = 0;
    var in_any = false;
    for (0..3) |c| {
        const cx: f64 = @floatFromInt(colX(p_x, p_w, c));
        const cw: f64 = @floatFromInt(colW(p_w));
        if (lx >= cx and lx < cx + cw) {
            col = c;
            in_any = true;
            break;
        }
    }
    if (!in_any) {
        var best: f64 = 1e18;
        for (0..3) |c| {
            const cx: f64 = @floatFromInt(colX(p_x, p_w, c));
            const cw: f64 = @floatFromInt(colW(p_w));
            const d = @abs(lx - (cx + cw * 0.5));
            if (d < best) {
                best = d;
                col = c;
            }
        }
    }
    var ins: usize = 0;
    var vis: usize = 0;
    for (colList(lists, col), 0..) |_, i| {
        if (col == src_col and i == src_idx) continue;
        const r = cardRect(p_x, p_y, p_w, col, i);
        const mid: f64 = @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h)) * 0.5;
        if (mid < ly) ins = vis + 1;
        vis += 1;
    }
    return .{ .col = col, .insert_before = ins };
}

/// Add-widget button rect for one column (paint + hit-test share it); a
/// card-gap separates it from the last widget.
pub fn widgetAddRect(p_x: i32, p_y: i32, p_w: i32, col: usize, n: usize) Rect {
    return .{
        .x = colX(p_x, p_w, col),
        .y = listY(p_y) + @as(i32, @intCast(n)) * (rows_mod.widget_card_h + rows_mod.widget_card_gap) + rows_mod.widget_card_gap,
        .w = colW(p_w),
        .h = 38,
    };
}

pub fn widgetAddHit(
    lists: [3][]const []const u8,
    p_x: i32,
    p_y: i32,
    p_w: i32,
    lx: f64,
    ly: f64,
) ?usize {
    for (0..3) |col| {
        const r = widgetAddRect(p_x, p_y, p_w, col, colList(lists, col).len);
        if (common.pointInRect(lx, ly, .{
            .x = r.x,
            .y = r.y,
            .w = r.w,
            .h = r.h,
        })) return col;
    }
    return null;
}

/// Reset-to-defaults row below the tallest column (full board width).
pub fn widgetsResetRect(p_x: i32, p_y: i32, p_w: i32, max_n: usize) Rect {
    return .{
        .x = p_x + board_pad,
        .y = listY(p_y) + @as(i32, @intCast(max_n)) * (rows_mod.widget_card_h + rows_mod.widget_card_gap) + rows_mod.widget_card_gap + 38 + 12,
        .w = p_w - 2 * board_pad,
        .h = 38,
    };
}

pub fn widgetsResetHit(
    lists: [3][]const []const u8,
    p_x: i32,
    p_y: i32,
    p_w: i32,
    lx: f64,
    ly: f64,
) bool {
    var max_n: usize = 0;
    for (0..3) |col| max_n = @max(max_n, colList(lists, col).len);
    const r = widgetsResetRect(p_x, p_y, p_w, max_n);
    return common.pointInRect(lx, ly, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
}

/// Tallest column length: drives the add/reset rows and the board height.
pub fn maxColLen(lists: [3][]const []const u8) usize {
    var n: usize = 0;
    for (0..3) |col| n = @max(n, colList(lists, col).len);
    return n;
}

/// Paint the LEFT / CENTER / RIGHT widget columns from live settings lists:
/// header label, widget cards (grip, icon, name, enable switch, remove ×),
/// an Add-widget button per column and a reset-to-defaults row. `states`
/// answers each card's switch; unknown ids read on. When `drag` is an active
/// drag, the source card is washed out, an accent insertion line marks the
/// drop slot, and a lifted card follows the pointer.
pub fn paintWidgetBoard(
    c: anytype,
    p_x: i32,
    p_y: i32,
    p_w: i32,
    lists: [3][]const []const u8,
    states: []const app_mod.WidgetState,
    pointer_x: f64,
    pointer_y: f64,
    accent: []const f64,
    drag: ?BoardDrag,
) void {
    const t = common.Theme;
    const headers = [_][]const u8{ "LEFT", "CENTER", "RIGHT" };
    for (headers, 0..) |hdr, col| {
        const cx = colX(p_x, p_w, col);
        // Column title: accent, 11px bold (C++: Inter bold 11 @ accent 0.55).
        ui_paint.showText(
            c,
            @floatFromInt(cx),
            @floatFromInt(p_y + 16),
            hdr,
            11,
            700,
            accent[0],
            accent[1],
            accent[2],
            0.55,
        );
        const list = colList(lists, col);
        for (list, 0..) |id, i| {
            const r = cardRect(p_x, p_y, p_w, col, i);
            const meta = widgetMeta(id);
            const on = widget_persist.isEnabledStates(states, id);
            const rx: f64 = @floatFromInt(r.x);
            const ry: f64 = @floatFromInt(r.y);
            const rw: f64 = @floatFromInt(r.w);
            const rh: f64 = @floatFromInt(r.h);
            // Washed out while held: this card is following the pointer.
            const is_src = if (drag) |d| d.active and d.dragging and d.src_col == col and d.src_idx == i else false;
            // Card background: m3::Box surface, r12, glassy — the same ported
            // primitive the C++ dock tab uses. The drop shadow, milky wash and
            // lit bottom rim it adds are what make the card read frosted
            // instead of flat.
            {
                var bg: m3_box.Box = .{};
                bg.setColor(@floatCast(t.bg_r), @floatCast(t.bg_g), @floatCast(t.bg_b), 0.90);
                bg.setRadius(12.0);
                bg.setGeometry(@floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
                bg.setGlassy(true);
                bg.paint(c);
            }
            // Drag grip: 6-dot (2x3) handle (C++ settings_draw_drag_handle_row).
            cairo.cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, 0.38);
            const grip_cx = rx + 10.0;
            const oy0 = ry + rh * 0.5 - 8.0;
            var gc: i32 = 0;
            while (gc < 2) : (gc += 1) {
                var gr: i32 = 0;
                while (gr < 3) : (gr += 1) {
                    cairo.cairo_arc(
                        c,
                        grip_cx + @as(f64, @floatFromInt(gc)) * 8.0,
                        oy0 + @as(f64, @floatFromInt(gr)) * 8.0,
                        2.0,
                        0,
                        2 * std.math.pi,
                    );
                    cairo.cairo_fill(c);
                }
            }
            // Icon box: accent-tinted glassy square + centred material glyph.
            const icon_x = rx + 34.0;
            const icon_y = ry + (rh - 30.0) * 0.5;
            {
                var ibox: m3_box.Box = .{};
                ibox.setColor(
                    @floatCast(@min(1.0, accent[0] * 0.4 + 0.4)),
                    @floatCast(@min(1.0, accent[1] * 0.4 + 0.4)),
                    @floatCast(@min(1.0, accent[2] * 0.4 + 0.4)),
                    0.85,
                );
                ibox.setRadius(8.0);
                ibox.setGeometry(@floatCast(icon_x), @floatCast(icon_y), 30.0, 30.0);
                ibox.setGlassy(true);
                ibox.paint(c);
            }
            ui_paint.glyph(
                c,
                icon_x + 15.0,
                icon_y + 15.5,
                20.0,
                meta.glyph,
                t.text_r,
                t.text_g,
                t.text_b,
                0.95,
            );
            // Widget name: 13px/600. The C++ `settings_draw_trimmed_text_line`
            // truncates by an approximate character budget (nameW passed as
            // maxChars) that these short titles never hit, so the full name is
            // drawn here too.
            const name_x = icon_x + 30.0 + 6.0;
            ui_paint.showText(
                c,
                name_x,
                ry + 35.0,
                meta.title,
                13,
                600,
                t.text_r,
                t.text_g,
                t.text_b,
                1.0,
            );
            // Remove button: 26x26 glassy box + drawn X (C++
            // settings_draw_row_remove_button: bg at 0.9 * (hover ? .96 : .90)).
            const rm = removeRect(r);
            const rmx: f64 = @floatFromInt(rm.x);
            const rmy: f64 = @floatFromInt(rm.y);
            const rmhov = common.pointInRect(pointer_x, pointer_y, rm);
            {
                var rmb: m3_box.Box = .{};
                rmb.setColor(
                    @floatCast(t.bg_r),
                    @floatCast(t.bg_g),
                    @floatCast(t.bg_b),
                    if (rmhov) 0.9 * 0.96 else 0.9 * 0.90,
                );
                rmb.setRadius(8.0);
                rmb.setGeometry(@floatFromInt(rm.x), @floatFromInt(rm.y), 26.0, 26.0);
                rmb.setGlassy(true);
                rmb.paint(c);
            }
            cairo.cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, if (rmhov) 0.9 else 0.52);
            cairo.cairo_set_line_width(c, 2.0);
            cairo.cairo_move_to(c, rmx + 8.0, rmy + 8.0);
            cairo.cairo_line_to(c, rmx + 18.0, rmy + 18.0);
            cairo.cairo_move_to(c, rmx + 18.0, rmy + 8.0);
            cairo.cairo_line_to(c, rmx + 8.0, rmy + 18.0);
            cairo.cairo_stroke(c);
            // Enable switch (m3 Toggle track).
            const tr = toggleRect(r);
            drawSwitch(c, tr.x, tr.y, on, accent);
            if (is_src) {
                // Ghost the held card in place; the lifted copy below is
                // what tracks the pointer.
                cairo.cairo_set_source_rgba(c, t.bg_r, t.bg_g, t.bg_b, 0.55);
                cairo.cairo_rectangle(c, rx, ry, rw, rh);
                cairo.cairo_fill(c);
            }
        }
        // Add-widget button (m3 outlined, accent).
        const add = widgetAddRect(p_x, p_y, p_w, col, list.len);
        const addhov = common.pointInRect(pointer_x, pointer_y, .{
            .x = add.x,
            .y = add.y,
            .w = add.w,
            .h = add.h,
        });
        var addbtn: m3_button.Button = .{};
        addbtn.setMinSize(0, 0);
        addbtn.setGlyph("add");
        addbtn.setLabel("Add widget");
        addbtn.setGeometry(@floatFromInt(add.x), @floatFromInt(add.y), @floatFromInt(add.w), 38);
        addbtn.setStyle(.outlined);
        addbtn.setSize(.xs);
        addbtn.setAccentColor(@floatCast(accent[0]), @floatCast(accent[1]), @floatCast(accent[2]));
        addbtn.setOutlineColor(@floatCast(t.outline_r), @floatCast(t.outline_g), @floatCast(t.outline_b));
        addbtn.setTextColor(@floatCast(t.text_r), @floatCast(t.text_g), @floatCast(t.text_b));
        addbtn.setHovered(addhov);
        addbtn.paint(c, 0);
    }
    // Reset-to-defaults row (m3 outlined, full board width, below the tallest column).
    const rr = widgetsResetRect(p_x, p_y, p_w, maxColLen(lists));
    const rhov = common.pointInRect(pointer_x, pointer_y, .{
        .x = rr.x,
        .y = rr.y,
        .w = rr.w,
        .h = rr.h,
    });
    var resetbtn: m3_button.Button = .{};
    resetbtn.setMinSize(0, 0);
    resetbtn.setGlyph("restart_alt");
    resetbtn.setLabel("Reset to defaults");
    resetbtn.setGeometry(@floatFromInt(rr.x), @floatFromInt(rr.y), @floatFromInt(rr.w), 38);
    resetbtn.setStyle(.outlined);
    resetbtn.setSize(.xs);
    resetbtn.setAccentColor(@floatCast(accent[0]), @floatCast(accent[1]), @floatCast(accent[2]));
    resetbtn.setOutlineColor(@floatCast(t.outline_r), @floatCast(t.outline_g), @floatCast(t.outline_b));
    resetbtn.setTextColor(@floatCast(t.text_r), @floatCast(t.text_g), @floatCast(t.text_b));
    resetbtn.setHovered(rhov);
    resetbtn.paint(c, 0);
    if (drag) |d| {
        if (d.active and d.dragging and d.id.len > 0) paintBoardDrag(c, p_x, p_y, p_w, accent, d);
    }
}

/// Drop feedback for an active board drag: an accent insertion line at the
/// drop slot, then the lifted card following the pointer. The line is drawn
/// in *visible* space — erased index k sits at raw k, or raw k+1 past the
/// held card in the same column.
fn paintBoardDrag(c: anytype, p_x: i32, p_y: i32, p_w: i32, accent: []const f64, d: BoardDrag) void {
    const t = common.Theme;
    const pitch: i32 = rows_mod.widget_card_h + rows_mod.widget_card_gap;
    const kk = if (d.target_col == d.src_col and d.insert_before >= d.src_idx)
        d.insert_before + 1
    else
        d.insert_before;
    const line_y: f64 = @floatFromInt(listY(p_y) + @as(i32, @intCast(kk)) * pitch - @divTrunc(rows_mod.widget_card_gap, 2));
    const line_x: f64 = @floatFromInt(colX(p_x, p_w, d.target_col));
    const line_w: f64 = @floatFromInt(colW(p_w));
    cairo.cairo_set_source_rgba(c, accent[0], accent[1], accent[2], 0.95);
    cairo.cairo_rectangle(c, line_x, line_y, line_w, 3.0);
    cairo.cairo_fill(c);
    // Lifted card: surface + grip + icon + name (no switch — it reads as
    // the thing being held, not a live row).
    const lw: f64 = @floatFromInt(colW(p_w));
    const lh: f64 = @floatFromInt(rows_mod.widget_card_h);
    {
        var lbg: m3_box.Box = .{};
        lbg.setColor(@floatCast(t.bg_r), @floatCast(t.bg_g), @floatCast(t.bg_b), 0.95);
        lbg.setRadius(12.0);
        lbg.setGeometry(@floatCast(d.lift_x), @floatCast(d.lift_y), @floatCast(lw), @floatCast(lh));
        lbg.setGlassy(true);
        lbg.paint(c);
    }
    const meta = widgetMeta(d.id);
    cairo.cairo_set_source_rgba(c, t.text_r, t.text_g, t.text_b, 0.55);
    const grip_cx = d.lift_x + 10.0;
    const oy0 = d.lift_y + lh * 0.5 - 8.0;
    var gc: i32 = 0;
    while (gc < 2) : (gc += 1) {
        var gr: i32 = 0;
        while (gr < 3) : (gr += 1) {
            cairo.cairo_arc(
                c,
                grip_cx + @as(f64, @floatFromInt(gc)) * 8.0,
                oy0 + @as(f64, @floatFromInt(gr)) * 8.0,
                2.0,
                0,
                2 * std.math.pi,
            );
            cairo.cairo_fill(c);
        }
    }
    const icon_x = d.lift_x + 34.0;
    const icon_y = d.lift_y + (lh - 30.0) * 0.5;
    {
        var ibox: m3_box.Box = .{};
        ibox.setColor(
            @floatCast(@min(1.0, accent[0] * 0.4 + 0.4)),
            @floatCast(@min(1.0, accent[1] * 0.4 + 0.4)),
            @floatCast(@min(1.0, accent[2] * 0.4 + 0.4)),
            0.85,
        );
        ibox.setRadius(8.0);
        ibox.setGeometry(@floatCast(icon_x), @floatCast(icon_y), 30.0, 30.0);
        ibox.setGlassy(true);
        ibox.paint(c);
    }
    ui_paint.glyph(
        c,
        icon_x + 15.0,
        icon_y + 15.5,
        20.0,
        meta.glyph,
        t.text_r,
        t.text_g,
        t.text_b,
        0.95,
    );
    ui_paint.showText(
        c,
        icon_x + 30.0 + 6.0,
        d.lift_y + 35.0,
        meta.title,
        13,
        600,
        t.text_r,
        t.text_g,
        t.text_b,
        1.0,
    );
}

/// Toolbar button rect `i` (monitors tab) — fixed width keeps hit-test
/// free of text measurement.
pub fn toolbarBtnRect(p_x: i32, p_y: i32, i: usize) Rect {
    return .{
        .x = p_x + board_pad + @as(i32, @intCast(i)) * (btn_w + 8),
        .y = p_y + @divTrunc(rows_mod.toolbar_h - btn_h, 2),
        .w = btn_w,
        .h = btn_h,
    };
}

pub fn toolbarHit(n_buttons: usize, p_x: i32, p_y: i32, lx: f64, ly: f64) ?usize {
    for (0..n_buttons) |i| {
        const r = toolbarBtnRect(p_x, p_y, i);
        if (common.pointInRect(lx, ly, .{
            .x = r.x,
            .y = r.y,
            .w = r.w,
            .h = r.h,
        })) return i;
    }
    return null;
}

pub fn paintToolbar(
    c: anytype,
    p_x: i32,
    p_y: i32,
    buttons: []const []const u8,
    pointer_x: f64,
    pointer_y: f64,
    accent: []const f64,
) void {
    const t = common.Theme;
    for (buttons, 0..) |label, i| {
        const r = toolbarBtnRect(p_x, p_y, i);
        const primary = i == 2; // Apply is the accent action.
        const hov = common.pointInRect(pointer_x, pointer_y, .{
            .x = r.x,
            .y = r.y,
            .w = r.w,
            .h = r.h,
        });
        if (primary) {
            ui_paint.glassBox(
                c,
                @floatFromInt(r.x),
                @floatFromInt(r.y),
                @floatFromInt(r.w),
                @floatFromInt(r.h),
                8,
                accent[0],
                accent[1],
                accent[2],
                if (hov) 0.35 else 0.25,
            );
        } else {
            ui_paint.glassBox(
                c,
                @floatFromInt(r.x),
                @floatFromInt(r.y),
                @floatFromInt(r.w),
                @floatFromInt(r.h),
                8,
                1,
                1,
                1,
                if (hov) 0.10 else 0.06,
            );
        }
        const tw = ui_paint.textWidthPx(c, label, 12, 500);
        const cx = @as(f64, @floatFromInt(r.x)) +
            (@as(f64, @floatFromInt(r.w)) - @as(f64, @floatFromInt(tw))) * 0.5;
        ui_paint.showText(
            c,
            cx,
            @floatFromInt(r.y + 21),
            label,
            12,
            500,
            if (primary) accent[0] else t.text_r,
            if (primary) accent[1] else t.text_g,
            if (primary) accent[2] else t.text_b,
            if (primary) 0.95 else 0.85,
        );
    }
}

/// The inner board the arrange canvas draws into — shared by paint, hit-test
/// and the wheel-zoom anchor so the three can never disagree.
pub fn canvasBoxRect(p_x: i32, p_y: i32, p_w: i32, p_h: i32) Rect {
    return .{
        .x = p_x + board_pad,
        .y = p_y + 4,
        .w = p_w - 2 * board_pad,
        .h = p_h - 8 - 44,
    };
}

/// Aux button `i` sits in a row along the canvas row's bottom edge.
pub fn canvasAuxRect(p_x: i32, p_y: i32, p_h: i32, i: usize) Rect {
    return toolbarBtnRect(p_x, p_y + p_h - 36, i);
}

pub fn canvasAuxHit(
    labels: []const []const u8,
    p_x: i32,
    p_y: i32,
    p_h: i32,
    lx: f64,
    ly: f64,
) ?usize {
    for (labels, 0..) |_, i| {
        const r = canvasAuxRect(p_x, p_y, p_h, i);
        if (common.pointInRect(lx, ly, .{
            .x = r.x,
            .y = r.y,
            .w = r.w,
            .h = r.h,
        })) return i;
    }
    return null;
}

/// Arrange canvas: output rectangles mapped through the state's fit, pan and
/// zoom, the selected output outlined in accent, plus the aux buttons.
pub fn paintCanvas(
    c: anytype,
    p_x: i32,
    p_y: i32,
    p_w: i32,
    p_h: i32,
    st: *mon_state.State,
    pointer_x: f64,
    pointer_y: f64,
    accent: []const f64,
) void {
    const t = common.Theme;
    const box = canvasBoxRect(p_x, p_y, p_w, p_h);
    ui_paint.glassBox(
        c,
        @floatFromInt(box.x),
        @floatFromInt(box.y),
        @floatFromInt(box.w),
        @floatFromInt(box.h),
        10,
        1,
        1,
        1,
        0.03,
    );
    const sel: i32 = if (st.outputs_len == 0) -1 else @intCast(@min(st.selected, st.outputs_len - 1));
    var v = mon_tab.canvasView(st, box.w, box.h);
    for (0..v.n) |i| {
        if (i >= st.outputs_len) break;
        const row = &st.outputs[i];
        const scr = mon_tab.canvasScreenRect(&v, i) orelse continue;
        if (row.disabled) {
            // A disabled output is drawn hollow: still on the canvas, so it
            // can be dragged back on, but clearly not driving anything.
            ui_paint.roundRect(c, box.x + scr.x + 0.5, box.y + scr.y + 0.5, scr.w - 1.0, scr.h - 1.0, 6);
            cairo.cairo_set_line_width(c, 1.0);
            cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.30);
            const dash = [_]f64{ 4.0, 4.0 };
            cairo.cairo_set_dash(c, &dash, 2, 0);
            cairo.cairo_stroke(c);
            // num_dashes = 0 with a null array restores the solid pattern.
            cairo.cairo_set_dash(c, null, 0, 0);
        } else {
            const is_sel = @as(i32, @intCast(i)) == sel;
            ui_paint.glassBox(
                c,
                box.x + scr.x,
                box.y + scr.y,
                scr.w,
                scr.h,
                6,
                if (is_sel) accent[0] else 1,
                if (is_sel) accent[1] else 1,
                if (is_sel) accent[2] else 1,
                if (is_sel) 0.16 else 0.06,
            );
            ui_paint.roundRect(c, box.x + scr.x + 0.5, box.y + scr.y + 0.5, scr.w - 1.0, scr.h - 1.0, 6);
            if (is_sel) {
                cairo.cairo_set_line_width(c, 1.5);
                cairo.cairo_set_source_rgba(c, accent[0], accent[1], accent[2], 0.95);
            } else {
                cairo.cairo_set_line_width(c, 1.0);
                cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 0.35);
            }
            cairo.cairo_stroke(c);
        }
        // Name + mode line, centred in the rect; skipped when the rect is too
        // small to hold them legibly (zoomed far out).
        if (scr.w >= 48 and scr.h >= 30) {
            const cx = box.x + scr.x + scr.w * 0.5;
            const cy = box.y + scr.y + scr.h * 0.5;
            const name_w: f64 = @floatFromInt(ui_paint.textWidthPx(c, row.name.slice(), 13, 600));
            ui_paint.showText(
                c,
                cx - name_w * 0.5,
                cy - 2,
                row.name.slice(),
                13,
                600,
                t.text_r,
                t.text_g,
                t.text_b,
                0.9,
            );
            var buf: [64]u8 = undefined;
            const sub = modeLine(row, &buf);
            const sw: f64 = @floatFromInt(ui_paint.textWidthPx(c, sub, 11, 400));
            ui_paint.showText(
                c,
                cx - sw * 0.5,
                cy + 16,
                sub,
                11,
                400,
                t.text_r,
                t.text_g,
                t.text_b,
                0.5,
            );
        }
    }
    // Aux buttons: Center view / Align top.
    const aux = mon_page.canvas_aux_buttons;
    for (aux, 0..) |label, i| {
        const r = canvasAuxRect(p_x, p_y, p_h, i);
        const hov = common.pointInRect(pointer_x, pointer_y, .{
            .x = r.x,
            .y = r.y,
            .w = r.w,
            .h = r.h,
        });
        ui_paint.glassBox(
            c,
            @floatFromInt(r.x),
            @floatFromInt(r.y),
            @floatFromInt(r.w),
            @floatFromInt(r.h),
            8,
            1,
            1,
            1,
            if (hov) 0.10 else 0.06,
        );
        const tw = ui_paint.textWidthPx(c, label, 12, 500);
        const cx = @as(f64, @floatFromInt(r.x)) +
            (@as(f64, @floatFromInt(r.w)) - @as(f64, @floatFromInt(tw))) * 0.5;
        ui_paint.showText(
            c,
            cx,
            @floatFromInt(r.y + 21),
            label,
            12,
            500,
            t.text_r,
            t.text_g,
            t.text_b,
            0.75,
        );
    }
}

pub fn pillRect(p_x: i32, p_y: i32, i: usize) Rect {
    return .{
        .x = p_x + board_pad + @as(i32, @intCast(i)) * (pill_w + 8),
        .y = p_y + @divTrunc(rows_mod.pills_h - pill_h, 2),
        .w = pill_w,
        .h = pill_h,
    };
}

pub fn pillsHit(n: usize, p_x: i32, p_y: i32, lx: f64, ly: f64) ?usize {
    for (0..n) |i| {
        const r = pillRect(p_x, p_y, i);
        if (common.pointInRect(lx, ly, .{
            .x = r.x,
            .y = r.y,
            .w = r.w,
            .h = r.h,
        })) return i;
    }
    return null;
}

pub fn paintPills(
    c: anytype,
    p_x: i32,
    p_y: i32,
    pills: []const []const u8,
    sel: i32,
    pointer_x: f64,
    pointer_y: f64,
    accent: []const f64,
) void {
    for (pills, 0..) |label, i| {
        const r = pillRect(p_x, p_y, i);
        const is_sel = @as(i32, @intCast(i)) == sel;
        const hov = common.pointInRect(pointer_x, pointer_y, .{
            .x = r.x,
            .y = r.y,
            .w = r.w,
            .h = r.h,
        });
        if (is_sel) {
            ui_paint.glassBox(
                c,
                @floatFromInt(r.x),
                @floatFromInt(r.y),
                @floatFromInt(r.w),
                @floatFromInt(r.h),
                14,
                accent[0],
                accent[1],
                accent[2],
                if (hov) 0.35 else 0.28,
            );
        } else {
            ui_paint.glassBox(
                c,
                @floatFromInt(r.x),
                @floatFromInt(r.y),
                @floatFromInt(r.w),
                @floatFromInt(r.h),
                14,
                1,
                1,
                1,
                if (hov) 0.10 else 0.06,
            );
        }
        const tw = ui_paint.textWidthPx(c, label, 12, 500);
        const cx = @as(f64, @floatFromInt(r.x)) +
            (@as(f64, @floatFromInt(r.w)) - @as(f64, @floatFromInt(tw))) * 0.5;
        ui_paint.showText(
            c,
            cx,
            @floatFromInt(r.y + 19),
            label,
            12,
            500,
            if (is_sel) accent[0] else 1,
            if (is_sel) accent[1] else 1,
            if (is_sel) accent[2] else 1,
            if (is_sel) 0.95 else 0.7,
        );
    }
}

/// m3 Toggle track (Size::L — 40x24, `common.toggle_w/h`) used inside widget
/// cards. Follows the settings-wide `drawToggle` in `ui_content.zig` so the
/// board's switches match every other tab: accent pill when on, hairline
/// outline on a faint white track when off, white knob scaled off the height.
/// Widget-board enable switch: `m3::Toggle` at its default Size::M
/// (32x20 track, 16px knob) centered in the row's switch box: flat accent track and
/// white knob when on; surface track at half strength, 2px outline stroke
/// and outline-colored knob when off.
fn drawSwitch(
    c: anytype,
    x: i32,
    y: i32,
    on: bool,
    accent: []const f64,
) void {
    const t = common.Theme;
    const tw: f64 = 32.0;
    const th: f64 = 20.0;
    const hr: f64 = 8.0;
    const tlx = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(common.toggle_w)) - tw) * 0.5;
    const tly = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(common.toggle_h)) - th) * 0.5;
    const hx = if (on) tlx + tw - hr else tlx + hr;
    const hy = tly + th * 0.5;
    ui_paint.roundRect(c, tlx, tly, tw, th, th * 0.5);
    if (on) {
        cairo.cairo_set_source_rgba(c, accent[0], accent[1], accent[2], 1.0);
    } else {
        cairo.cairo_set_source_rgba(c, t.bg_r, t.bg_g, t.bg_b, 0.5);
    }
    cairo.cairo_fill(c);
    if (!on) {
        ui_paint.roundRect(c, tlx + 1.0, tly + 1.0, tw - 2.0, th - 2.0, th * 0.5 - 1.0);
        cairo.cairo_set_line_width(c, 2.0);
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 1.0);
        cairo.cairo_stroke(c);
    }
    if (on) {
        cairo.cairo_set_source_rgba(c, 1, 1, 1, 1.0);
    } else {
        cairo.cairo_set_source_rgba(c, t.outline_r, t.outline_g, t.outline_b, 1.0);
    }
    cairo.cairo_arc(c, hx, hy, hr, 0, std.math.pi * 2.0);
    cairo.cairo_fill(c);
}

test "settings-ui-widgets: board geometry" {
    const t = std.testing;
    const lists: [3][]const []const u8 = .{
        &.{"app_menu"},
        &.{ "clock", "media" },
        &.{"notifications"},
    };
    const c0 = cardRect(300, 100, 576, 0, 0);
    const c1 = cardRect(300, 100, 576, 1, 0);
    try t.expect(c1.x > c0.x);
    try t.expectEqual(@as(i32, rows_mod.widget_card_h), c0.h);
    const tr = toggleRect(c0);
    try t.expectEqual(@as(i32, c0.x + c0.w - 8 - 26 - 8 - 40), tr.x);
    // Toggle hit on the first widget of LEFT.
    const hit = widgetHit(lists, 300, 100, 576, @floatFromInt(tr.x + 4), @floatFromInt(tr.y + 4));
    try t.expect(hit != null);
    try t.expectEqual(@as(usize, 0), hit.?.col);
    const tr1 = toggleRect(cardRect(300, 100, 576, 1, 0));
    const hit1 = widgetHit(lists, 300, 100, 576, @floatFromInt(tr1.x + 4), @floatFromInt(tr1.y + 4));
    try t.expect(hit1 != null);
    try t.expectEqual(@as(usize, 1), hit1.?.col);
    // Add / remove / reset zones resolve around the same geometry.
    try t.expect(widgetAddHit(lists, 300, 100, 576, @floatFromInt(c0.x + 4), @floatFromInt(200)) == 0);
    const rm0 = removeRect(c0);
    try t.expect(widgetRemoveHit(lists, 300, 100, 576, @floatFromInt(rm0.x + 4), @floatFromInt(rm0.y + 4)) != null);
    try t.expect(widgetsResetHit(lists, 300, 100, 576, @floatFromInt(400), @floatFromInt(310)));
    // Toolbar rects do not overlap.
    const b0 = toolbarBtnRect(300, 40, 0);
    const b1 = toolbarBtnRect(300, 40, 1);
    try t.expectEqual(@as(i32, b0.x + b0.w + 8), b1.x);
    try t.expect(toolbarHit(4, 300, 40, @floatFromInt(b1.x + 4), @floatFromInt(b1.y + 4)) == 1);
    // Widget meta fallback.
    const m = widgetMeta("clock");
    try t.expectEqualStrings("Clock", m.title);
    const fb = widgetMeta("mystery");
    try t.expectEqualStrings("mystery", fb.title);
}
