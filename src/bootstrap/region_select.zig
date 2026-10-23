//! Interactive region selection: a fullscreen dim overlay you drag a box
//! out of, answered in global logical coordinates. Also the cursor probe
//! (`--around-mouse`): a transparent fullscreen surface on every output so
//! the first pointer event says where the pointer is.
//!
//! The overlay paints the *frozen* capture behind the dim rather than the
//! live screen. What shows through the hole is exactly the frame the caller
//! goes on to crop, so a window that repaints mid-drag cannot produce a PNG
//! that differs from the selection — the C++ `region_select.cpp` dimmed the
//! live screen and cropped a frame captured earlier, which is the one
//! deliberate behavior change in this port. Passing a null backdrop gets the
//! old plain-dim overlay back.
//!
//! Everything the drag decides is a pure function of its coordinates
//! (`renderOverlay`, `normalize`, `paintBackdrop`), so the parts a user
//! actually feels are testable without a compositor.

const std = @import("std");
const wl = @import("../wl/c.zig").wl;
const seat_mod = @import("../wl/seat.zig");
const layer_mod = @import("../wl/surface/layer.zig");
const shot = @import("../wl/capture/shot.zig");

/// A rectangle in the compositor's global logical space — the coordinates
/// layer surfaces, `--geometry`, and the clipboard daemon all speak.
pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    /// The `WxH+X+Y` string the C++ path returned as a `std::string` and
    /// that `--geometry` accepts back. Grim interchange format, but it is
    /// the established one.
    pub fn format(self: Rect, buf: []u8) ![]u8 {
        return std.fmt.bufPrint(buf, "{d}x{d}+{d}+{d}", .{ self.w, self.h, self.x, self.y });
    }
};

/// One output's origin in global logical coordinates. `output` may be null
/// for a coordinate-only probe. `w`/`h` are the output's size, used to size
/// probe buffers (see `cursorGlobalPosition`).
pub const OutputRect = struct {
    output: ?*wl.wl_output = null,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

/// Overlay colors, straight 0xAARRGGBB — the byte order the overlay's
/// ARGB8888 buffer wants on a little-endian host.
pub const Palette = struct {
    dim: u32 = 0x44000000,
    border: u32 = 0xffffffff,
};

pub const Options = struct {
    /// Bake the capture's cursor into the frozen frame (and thus into the
    /// final crop). The C++ flag was `--cursor`.
    cursor: bool = false,
    palette: Palette = .{},
};

/// The subset of a bound connection this module needs. Kept flat so a test
/// (or a future caller with its own plumbing) is not forced through
/// `wl/connection.zig`.
pub const View = struct {
    display: ?*wl.wl_display = null,
    compositor: ?*wl.wl_compositor = null,
    shm: ?*wl.wl_shm = null,
    layer_shell: ?*wl.zwlr_layer_shell_v1 = null,
    seat: ?*wl.wl_seat = null,
};

/// The normalized box currently being dragged, in surface coordinates.
pub const Box = struct {
    x1: i32 = 0,
    y1: i32 = 0,
    x2: i32 = 0,
    y2: i32 = 0,
};

/// Overlay interaction state. Surface-local throughout; the global origin
/// is added exactly once, when the result leaves `select`.
pub const DragState = struct {
    cur_x: i32 = 0,
    cur_y: i32 = 0,
    buf_w: i32 = 0,
    buf_h: i32 = 0,
    dragging: bool = false,
    start_x: i32 = 0,
    start_y: i32 = 0,
    end_x: i32 = 0,
    end_y: i32 = 0,
    done: bool = false,
    cancelled: bool = false,
    redraw: bool = false,
    rect: Rect = .{},

    /// Drag corners in order, clamped to the surface — the exact rectangle
    /// the C++ `render_frame` used, including its clamp-to-edge behaviour
    /// when the pointer leaves the output mid-drag.
    pub fn box(self: *const DragState) Box {
        var b = Box{
            .x1 = @min(self.start_x, self.end_x),
            .y1 = @min(self.start_y, self.end_y),
            .x2 = @max(self.start_x, self.end_x),
            .y2 = @max(self.start_y, self.end_y),
        };
        b.x1 = std.math.clamp(b.x1, 0, self.buf_w - 1);
        b.y1 = std.math.clamp(b.y1, 0, self.buf_h - 1);
        b.x2 = std.math.clamp(b.x2, 0, self.buf_w - 1);
        b.y2 = std.math.clamp(b.y2, 0, self.buf_h - 1);
        return b;
    }
};

/// Source-over blend of straight-alpha `src` onto `dst`. Written for the
/// general case so the same code serves both callers: over a cleared buffer
/// (`dst` alpha 0) it reproduces `src` exactly — the C++ plain-dim look —
/// and over the opaque frozen backdrop it dims the picture underneath.
pub fn blendOver(dst: u32, src: u32) u32 {
    const sa = (src >> 24) & 0xff;
    if (sa == 0xff) return src;
    const da = (dst >> 24) & 0xff;
    const ia: u32 = 255 - sa;
    const out_a = sa + (da * ia) / 255;
    if (out_a == 0) return 0;
    const r = ((src >> 16) & 0xff) * sa + (((dst >> 16) & 0xff) * da * ia) / 255;
    const g = ((src >> 8) & 0xff) * sa + (((dst >> 8) & 0xff) * da * ia) / 255;
    const b = (src & 0xff) * sa + ((dst & 0xff) * da * ia) / 255;
    return (out_a << 24) | (((r / out_a) & 0xff) << 16) | (((g / out_a) & 0xff) << 8) | ((b / out_a) & 0xff);
}

/// One overlay frame into `pixels` (ARGB8888, `buf_w` x `buf_h`). Outside
/// the drag is dimmed, the drag border is lit, and the strict interior is
/// left exactly as it was so the frozen backdrop shows through it.
pub fn renderOverlay(pixels: []u32, buf_w: i32, buf_h: i32, box: ?Box, palette: Palette) void {
    const w: usize = @intCast(buf_w);
    const h: usize = @intCast(buf_h);
    if (buf_w <= 0 or buf_h <= 0 or pixels.len < w * h) return;
    const b = box;
    for (0..h) |y| {
        const row = pixels[y * w ..][0..w];
        for (row, 0..) |*p, x| {
            if (insideHole(b, x, y)) continue;
            p.* = blendOver(p.*, palette.dim);
        }
    }
    const box_val = b orelse return;
    if (box_val.x1 == box_val.x2 and box_val.y1 == box_val.y2) {
        pixels[@as(usize, @intCast(box_val.y1)) * w + @as(usize, @intCast(box_val.x1))] = palette.border;
        return;
    }
    const x1: usize = @intCast(box_val.x1);
    const x2: usize = @intCast(box_val.x2);
    const y1: usize = @intCast(box_val.y1);
    const y2: usize = @intCast(box_val.y2);
    for (y1..y2 + 1) |y| {
        const row = pixels[y * w ..][0..w];
        if (y == y1 or y == y2) {
            for (x1..x2 + 1) |x| row[x] = palette.border;
        } else {
            row[x1] = palette.border;
            row[x2] = palette.border;
        }
    }
}

/// Paint the box interior from `src` and light its border. The destination
/// is expected to already hold the dimmed frame, so a drag frame costs a
/// hole-sized copy plus a perimeter instead of a full-buffer blend.
fn paintHoleAndBorder(dst: []u32, src: []const u32, buf_w: i32, buf_h: i32, box: Box, palette: Palette) void {
    const w: usize = @intCast(buf_w);
    const h: usize = @intCast(buf_h);
    if (dst.len < w * h or src.len < w * h) return;
    const x1 = std.math.clamp(box.x1, 0, buf_w - 1);
    const y1 = std.math.clamp(box.y1, 0, buf_h - 1);
    const x2 = std.math.clamp(box.x2, 0, buf_w - 1);
    const y2 = std.math.clamp(box.y2, 0, buf_h - 1);
    const ux1: usize = @intCast(x1);
    const ux2: usize = @intCast(x2);
    const uy1: usize = @intCast(y1);
    const uy2: usize = @intCast(y2);
    // Strict interior, restored from the undimmed source. Empty when the
    // box is flat, so a click never copies.
    var y = uy1 + 1;
    while (y < uy2) : (y += 1) {
        @memcpy(dst[y * w + ux1 + 1 .. y * w + ux2], src[y * w + ux1 + 1 .. y * w + ux2]);
    }
    var by = uy1;
    while (by <= uy2) : (by += 1) {
        const row = dst[by * w ..][0..w];
        if (by == uy1 or by == uy2) {
            for (ux1..ux2 + 1) |x| row[x] = palette.border;
        } else {
            row[ux1] = palette.border;
            row[ux2] = palette.border;
        }
    }
}

/// One interactive frame, fast path: `dimmed` holds the frame pre-dimmed a
/// single time (see `select`), so a drag frame is a full memcpy plus a
/// hole-sized copy and a border perimeter — no per-pixel blend math at
/// motion rate. `box == null` paints the fully-dimmed frame. Repainting
/// from stored copies every frame (instead of dimming in place) is what
/// keeps a drag from compounding into blackness or leaving ghosts.
pub fn renderFrame(dst: []u32, dimmed: []const u32, pristine: []const u32, buf_w: i32, buf_h: i32, box: ?Box, palette: Palette) void {
    if (buf_w <= 0 or buf_h <= 0) return;
    const w: usize = @intCast(buf_w);
    const h: usize = @intCast(buf_h);
    const n = w * h;
    if (dst.len < n or dimmed.len < n or pristine.len < n) return;
    @memcpy(dst[0..n], dimmed[0..n]);
    const b = box orelse return;
    paintHoleAndBorder(dst, pristine, buf_w, buf_h, b, palette);
}

test "region-select: drag frames cost memcpys, not blends (no compounding, no ghosts)" {
    const t = std.testing;
    const w: i32 = 8;
    const h: i32 = 8;
    const pal = Palette{};
    const back = @as([64]u32, @splat(0xff808080)); // flat mid-grey frozen frame
    var dimmed = back;
    renderOverlay(&dimmed, w, h, null, pal); // the one-time pre-dim
    var frame = @as([64]u32, @splat(0));
    const box1 = Box{ .x1 = 1, .y1 = 1, .x2 = 3, .y2 = 3 };
    const box2 = Box{ .x1 = 4, .y1 = 4, .x2 = 6, .y2 = 6 };
    // Two consecutive frames, as the drag loop paints them.
    renderFrame(&frame, &dimmed, &back, w, h, box1, pal);
    renderFrame(&frame, &dimmed, &back, w, h, box2, pal);
    // ...must equal a single slow-path paint of the final box: no
    // double-dim anywhere, no stale border from box1.
    var ref = back;
    renderOverlay(&ref, w, h, box2, pal);
    try t.expectEqualSlices(u32, &ref, &frame);
    // Spot checks: old border (1,1) and old hole (2,2) are dimmed exactly
    // once; the new hole (5,5) is pristine backdrop.
    const dimmed_once = blendOver(0xff808080, pal.dim);
    try t.expectEqual(dimmed_once, frame[1 * 8 + 1]);
    try t.expectEqual(dimmed_once, frame[2 * 8 + 2]);
    try t.expectEqual(@as(u32, 0xff808080), frame[5 * 8 + 5]);
    // A null box paints the fully-dimmed frame with no selection.
    renderFrame(&frame, &dimmed, &back, w, h, null, pal);
    try t.expectEqualSlices(u32, &dimmed, &frame);
}

/// Damage hint for one drag frame: the union of the previous selection
/// rect and the new one. Outside that union a frame is byte-identical to
/// the one before it — every pixel is the same pre-dimmed value — so the
/// compositor may reuse everything else and re-composite only this strip.
/// Null means nothing changed.
fn dirtyFrom(prev: ?Box, next: ?Box) ?Box {
    if (prev == null and next == null) return null;
    if (prev == null) return next;
    if (next == null) return prev;
    const p = prev.?;
    const n = next.?;
    return .{
        .x1 = @min(p.x1, n.x1),
        .y1 = @min(p.y1, n.y1),
        .x2 = @max(p.x2, n.x2),
        .y2 = @max(p.y2, n.y2),
    };
}

test "region-select: damage is the union of old and new selection" {
    const t = std.testing;
    try t.expect(dirtyFrom(null, null) == null);
    const a = Box{ .x1 = 2, .y1 = 3, .x2 = 4, .y2 = 9 };
    const b = Box{ .x1 = 1, .y1 = 5, .x2 = 8, .y2 = 6 };
    const u = dirtyFrom(a, b).?;
    try t.expectEqual(@as(i32, 1), u.x1);
    try t.expectEqual(@as(i32, 3), u.y1);
    try t.expectEqual(@as(i32, 8), u.x2);
    try t.expectEqual(@as(i32, 9), u.y2);
    // Remove the selection: the recovery strip is the old rect itself.
    try t.expectEqual(a, dirtyFrom(a, null).?);
    // First selection: the strip is the new rect.
    try t.expectEqual(b, dirtyFrom(null, b).?);
}

/// Drag frame, damage-scoped: rewrite only `dirt` — the union of the rect
/// this buffer holds with the rect to draw now — from the pre-dimmed frame,
/// then light the new border. Untouched pixels keep the frame from two
/// commits ago, which matches what the screen shows everywhere outside
/// `dirt`; that is exactly why a strip-shaped damage hint is safe. A null
/// `dirt` is the fresh-slot fallback (full pre-dimmed copy).
pub fn renderFrameRegion(
    dst: []u32,
    dimmed: []const u32,
    pristine: []const u32,
    buf_w: i32,
    buf_h: i32,
    box: ?Box,
    dirt: ?Box,
    palette: Palette,
) void {
    if (buf_w <= 0 or buf_h <= 0) return;
    const w: usize = @intCast(buf_w);
    const h: usize = @intCast(buf_h);
    if (dst.len < w * h or dimmed.len < w * h or pristine.len < w * h) return;
    if (dirt) |dd| {
        const dx1 = std.math.clamp(dd.x1, 0, buf_w - 1);
        const dy1 = std.math.clamp(dd.y1, 0, buf_h - 1);
        const dx2 = std.math.clamp(dd.x2, 0, buf_w - 1);
        const dy2 = std.math.clamp(dd.y2, 0, buf_h - 1);
        const x1: usize = @intCast(dx1);
        const x2: usize = @intCast(dx2);
        var y: usize = @intCast(dy1);
        while (y <= @as(usize, @intCast(dy2))) : (y += 1) {
            @memcpy(dst[y * w + x1 .. y * w + x2 + 1], dimmed[y * w + x1 .. y * w + x2 + 1]);
        }
    } else {
        @memcpy(dst[0 .. w * h], dimmed[0 .. w * h]);
    }
    const b = box orelse return;
    // The new rect lies inside `dirt` by construction, so the hole/border
    // fill is bounded by the rect itself, never by the buffer size.
    paintHoleAndBorder(dst, pristine, buf_w, buf_h, b, palette);
}

test "region-select: damage-scoped slots match full repaints; damage covers every changed pixel" {
    const t = std.testing;
    const w: i32 = 16;
    const h: i32 = 12;
    const pal = Palette{};
    const back = @as([192]u32, @splat(0xff808080)); // flat mid-grey frozen frame
    var dimmed = back;
    renderOverlay(&dimmed, w, h, null, pal); // the one-time pre-dim

    // Production seeding: both slots hold the initial no-selection frame
    // (the box=null slow path = the fully dimmed frame).
    var initial = back;
    renderFrame(&initial, &dimmed, &back, w, h, null, pal);
    var full = initial; // reference: the frame the screen must show
    var screen = initial; // the frame the compositor last took
    var slots: [2][192]u32 = .{ initial, initial };
    var slot_last = [2]?Box{ null, null };
    var screen_last: ?Box = null;

    // The frames a drag produces, alternating slots as pickSlot does.
    const frames = [_]?Box{
        .{ .x1 = 1, .y1 = 1, .x2 = 5, .y2 = 4 },
        .{ .x1 = 3, .y1 = 2, .x2 = 9, .y2 = 7 },
        .{ .x1 = 4, .y1 = 6, .x2 = 12, .y2 = 11 },
        null, // selection gone again: back to the plain dim
    };

    for (frames, 0..) |box, i| {
        const slot: usize = i % 2;
        // Slow full reference of the target frame.
        renderFrame(&full, &dimmed, &back, w, h, box, pal);
        // Production write: the slot repairs only its own strip.
        renderFrameRegion(&slots[slot], &dimmed, &back, w, h, box, dirtyFrom(slot_last[slot], box), pal);
        try t.expectEqualSlices(u32, &full, &slots[slot]);
        slot_last[slot] = box;

        // The damage hint the compositor gets (vs the displayed frame) must
        // cover every pixel that changed, or stale pixels stay on screen.
        const dmg = dirtyFrom(screen_last, box).?;
        var px: usize = 0;
        while (px < 192) : (px += 1) {
            if (full[px] == screen[px]) continue;
            const y: i32 = @intCast(px / 16);
            const x: i32 = @intCast(px % 16);
            try t.expect(x >= dmg.x1 and x <= dmg.x2 and y >= dmg.y1 and y <= dmg.y2);
        }
        screen = full;
        screen_last = box;
    }
}

/// Which overlay slot to paint the next frame into, or null to drop the
/// frame when the compositor still holds both. Never returns a busy slot:
/// repainting a buffer the compositor is reading is what flicker is (the
/// same rule as `ShmPair.acquire`, in miniature). A dropped frame keeps
/// `redraw` set, so the next event retries it.
fn pickSlot(a_busy: bool, b_busy: bool) ?u1 {
    if (!a_busy) return 0;
    if (!b_busy) return 1;
    return null;
}

test "region-select: never paint into a buffer the compositor holds" {
    const t = std.testing;
    // Both free: the first slot paints.
    try t.expectEqual(@as(?u1, 0), pickSlot(false, false));
    // First held: the spare absorbs the frame.
    try t.expectEqual(@as(?u1, 1), pickSlot(true, false));
    // Both held: drop the frame; the next event retries.
    try t.expect(pickSlot(true, true) == null);
}

/// The strict interior of the box: the part that stays transparent.
fn insideHole(b: ?Box, x: usize, y: usize) bool {
    const bb = b orelse return false;
    if (bb.x1 < 0 or bb.y1 < 0) return false;
    const x1: usize = @intCast(bb.x1);
    const y1: usize = @intCast(bb.y1);
    if (x <= x1 or y <= y1) return false;
    return x < @as(usize, @intCast(bb.x2)) and y < @as(usize, @intCast(bb.y2));
}

/// Lay the frozen capture over the overlay buffer, nearest-neighbour. The
/// capture is in mode pixels and the overlay in logical ones, so a 1:1 blit
/// would only be right on an unscaled output.
pub fn paintBackdrop(pixels: []u32, buf_w: i32, buf_h: i32, src: *const shot.Image) void {
    const dw: usize = @intCast(buf_w);
    const dh: usize = @intCast(buf_h);
    const sw: usize = @intCast(src.width);
    const sh: usize = @intCast(src.height);
    if (buf_w <= 0 or buf_h <= 0 or pixels.len < dw * dh) return;
    if (sw == 0 or sh == 0 or src.rgba.len < sw * sh * 4) return;
    for (0..dh) |y| {
        const sy = (y * sh) / dh;
        for (0..dw) |x| {
            const sx = (x * sw) / dw;
            const o = (sy * sw + sx) * 4;
            const r = src.rgba[o];
            const g = src.rgba[o + 1];
            const b = src.rgba[o + 2];
            const a = src.rgba[o + 3];
            pixels[y * dw + x] = argbPremultiplied(r, g, b, a);
        }
    }
}

fn argbPremultiplied(r: u8, g: u8, b: u8, a: u8) u32 {
    const av: u32 = a;
    const rv = (@as(u32, r) * av + 127) / 255;
    const gv = (@as(u32, g) * av + 127) / 255;
    const bv = (@as(u32, b) * av + 127) / 255;
    return (av << 24) | (rv << 16) | (gv << 8) | bv;
}

// pointer / keyboard callbacks

fn onEnter(ctx: *anyopaque, x: f64, y: f64) void {
    const st: *DragState = @ptrCast(@alignCast(ctx));
    st.cur_x = @intFromFloat(@trunc(x));
    st.cur_y = @intFromFloat(@trunc(y));
}

fn onMotion(ctx: *anyopaque, x: f64, y: f64) void {
    const st: *DragState = @ptrCast(@alignCast(ctx));
    st.cur_x = @intFromFloat(@trunc(x));
    st.cur_y = @intFromFloat(@trunc(y));
    if (st.dragging) {
        st.end_x = st.cur_x;
        st.end_y = st.cur_y;
        st.redraw = true;
    }
}

/// evdev button codes: 272 = BTN_LEFT, 273 = BTN_RIGHT.
const btn_left: u32 = 272;
const btn_right: u32 = 273;

// One pointer, N screens: the shared handlers below keep the DragState
// mechanics identical to the single-screen overlay, adding only session
// bookkeeping (hop identity, global origins at release).

fn hopEnter(ctx: *anyopaque, x: f64, y: f64) void {
    const app: *HopApp = @ptrCast(@alignCast(ctx));
    onEnter(@ptrCast(&app.st), x, y);
    const idx = screenOfEnter(app) orelse return;
    if (idx == app.active) return;
    // Hop: what the pointer left reverts to a live view; the target
    // engages from the loop (capture + paint are not callback material).
    app.to_clear = app.active;
    app.active = idx;
    app.st.buf_w = app.screens[idx].def.w;
    app.st.buf_h = app.screens[idx].def.h;
    if (app.st.dragging) {
        // The drag continues on the target monitor from the boundary
        // point: the box restarts at the crossing corner, and whatever
        // was drawn on the vacated screen is dropped with it.
        app.st.start_x = app.st.cur_x;
        app.st.start_y = app.st.cur_y;
        app.st.end_x = app.st.cur_x;
        app.st.end_y = app.st.cur_y;
    }
    app.pending = idx;
}

fn hopMotion(ctx: *anyopaque, x: f64, y: f64) void {
    const app: *HopApp = @ptrCast(@alignCast(ctx));
    onMotion(@ptrCast(&app.st), x, y);
}

fn hopButton(ctx: *anyopaque, button: u32, state: u32) void {
    const app: *HopApp = @ptrCast(@alignCast(ctx));
    // The single-screen state machine decides press/release/cancel and
    // publishes a surface-local rect (it is the tested source of truth);
    // hop translation adds the active screen's origin exactly once here.
    onButton(@ptrCast(&app.st), button, state);
    if (app.st.done and !app.st.cancelled) {
        const sc = app.screens[app.active];
        app.st.rect.x += sc.def.x;
        app.st.rect.y += sc.def.y;
    }
}

/// The release state machine, in active-screen-local coordinates. Kept
/// handler-shaped so the button tests exercise it directly; `hopButton`
/// delegates to it and adds the screen origin at the boundary.
fn onButton(ctx: *anyopaque, button: u32, state: u32) void {
    const st: *DragState = @ptrCast(@alignCast(ctx));
    if (button == btn_right) {
        // Right-click cancels on press and also ends the loop on release.
        if (state != 0) st.cancelled = true;
        st.done = true;
        return;
    }
    if (button != btn_left) return;
    if (state != 0) {
        st.dragging = true;
        st.start_x = st.cur_x;
        st.start_y = st.cur_y;
        st.end_x = st.cur_x;
        st.end_y = st.cur_y;
        st.redraw = true;
        return;
    }
    st.dragging = false;
    const b = st.box();
    const w = b.x2 - b.x1;
    const h = b.y2 - b.y1;
    // A drag of 1px (or a plain click) is a mis-aim, not a selection.
    if (w < 2 or h < 2) {
        st.cancelled = true;
        st.done = true;
        return;
    }
    st.rect = .{ .x = b.x1, .y = b.y1, .w = w, .h = h };
    st.done = true;
}

fn hopKey(ctx: *anyopaque, ev: *const seat_mod.KeyEvent) void {
    const app: *HopApp = @ptrCast(@alignCast(ctx));
    onKey(@ptrCast(&app.st), ev);
}

fn onKey(ctx: *anyopaque, ev: *const seat_mod.KeyEvent) void {
    const st: *DragState = @ptrCast(@alignCast(ctx));
    if (ev.state != 1) return; // WL_KEYBOARD_KEY_STATE_PRESSED
    if (ev.sym == seat_mod.xkb.XKB_KEY_Escape) {
        st.cancelled = true;
        st.done = true;
    }
}

// the overlay itself

/// One full-size ARGB8888 overlay mapping plus the buffer wrapping it.
const Overlay = struct {
    fd: i32 = -1,
    map: ?[*]u32 = null,
    size: usize = 0,
    buffer: ?*wl.wl_buffer = null,
    /// True while the compositor may still be reading this buffer: set when
    /// a frame commits, cleared by the release event. Painting into a busy
    /// buffer is what shows up as flicker — see `pickSlot`.
    busy: bool = false,

    fn create(shm: ?*wl.wl_shm, w: i32, h: i32) !Overlay {
        const s = shm orelse return error.NoShm;
        if (w <= 0 or h <= 0) return error.BadDimensions;
        var o = Overlay{};
        errdefer o.deinit();
        const size: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
        var tag: [16:0]u8 = @as([16:0]u8, @splat(0));
        @memcpy(tag[0..6], "wl-shm");
        const fd_rc = std.os.linux.memfd_create(&tag, std.os.linux.MFD.CLOEXEC);
        if (std.os.linux.errno(fd_rc) != .SUCCESS) return error.NoShm;
        o.fd = @intCast(fd_rc);
        if (std.os.linux.errno(std.os.linux.ftruncate(o.fd, @intCast(size))) != .SUCCESS) return error.NoShm;
        const map_rc = std.os.linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, o.fd, 0);
        if (std.os.linux.errno(map_rc) != .SUCCESS) return error.NoShm;
        o.map = @ptrFromInt(map_rc);
        o.size = size;
        const pool = wl.wl_shm_create_pool(s, o.fd, @intCast(size));
        if (pool == null) return error.NoShm;
        o.buffer = wl.wl_shm_pool_create_buffer(pool, 0, w, h, w * 4, wl.WL_SHM_FORMAT_ARGB8888);
        wl.wl_shm_pool_destroy(pool);
        if (o.buffer == null) return error.NoShm;
        return o;
    }

    fn onRelease(data: ?*anyopaque, buffer: ?*wl.wl_buffer) callconv(.c) void {
        _ = buffer;
        const self: *Overlay = @ptrCast(@alignCast(data orelse return));
        self.busy = false;
    }

    const buffer_listener = wl.wl_buffer_listener{ .release = onRelease };

    /// Pin the release listener to this Overlay's final address: call once,
    /// after the value has landed where it will live. The listener captures
    /// the address, so a later move would clear freed memory while the live
    /// flags stayed busy forever (same trap as `layer.Surface` — and the
    /// reason the probe reads sizes from the caller instead of copies).
    fn trackReleases(self: *Overlay) void {
        if (self.buffer) |b| _ = wl.wl_buffer_add_listener(b, &buffer_listener, self);
    }

    fn pixels(self: *Overlay) []u32 {
        const m = self.map orelse return &.{};
        return m[0 .. self.size / 4];
    }

    fn deinit(self: *Overlay) void {
        if (self.buffer) |b| wl.wl_buffer_destroy(b);
        if (self.map) |m| _ = std.os.linux.munmap(@ptrCast(m), self.size);
        if (self.fd >= 0) _ = std.os.linux.close(self.fd);
        self.* = .{};
    }
};

/// The hop selection: the drag overlays whichever monitor the pointer is
/// over. An overlay surface is pre-mapped transparent on every screen, so
/// crossing mid-drag still produces a pointer enter there. On a hop the
/// previous screen reverts to its live view (transparent overlay) and the
/// target screen — captured *now*, still clean, since its overlay never
/// painted — engages with the box restarted at the boundary point. Returns
/// null on cancel (Escape, right-click, sub-2px drag, closed surface);
/// otherwise `rect` is global logical coordinates, `screen` is the index in
/// `screens` the drag finished on, and `img` is that screen's clean frozen
/// frame, which the caller crops and deinits.
pub const Selection = struct {
    rect: Rect,
    screen: usize,
    img: *shot.Image,
};

/// One output participating in a selection. Heap-pinned: the layer
/// surface's ctx and the buffer release listeners hold this address for
/// the whole session (the copied-surface trap the probe documents never
/// applies to the heap).
const Screen = struct {
    def: OutputRect,
    ls: layer_mod.Surface = .{},
    /// Overlay pair, created lazily at engagement and kept. Heap slots:
    /// the release listeners must never see a moved Overlay.
    ov0: ?*Overlay = null,
    ov1: ?*Overlay = null,
    /// Transparent buffer the screen shows before engagement (alpha 0
    /// everywhere; memfd memory is zeroed). Keeps the surface mapped while
    /// the pointer is still elsewhere, without touching the desktop.
    clear: ?*Overlay = null,
    pristine: []u32 = &.{},
    dimmed: []u32 = &.{},
    img: ?*shot.Image = null,
    engaged: bool = false,
    last_frame_ms: i64 = 0,
    slot_last: [2]?Box = .{ null, null },
    screen_last: ?Box = null,
    frame: FrameCb = .{},
    cfg_w: i32 = 0,
    cfg_h: i32 = 0,
    closed: bool = false,
    /// Set on the screen the result hands over: cleanup spares this one's
    /// frozen capture for the caller.
    keep: bool = false,

    fn size(self: *const Screen) [2]i32 {
        // Fullscreen-anchored layers get configure = output size; trusted
        // because this Screen is heap-pinned (per-surface ctx, no Cow).
        // Fall back to the caller's geometry if that beat us.
        const w = if (self.cfg_w > 0) self.cfg_w else self.def.w;
        const h = if (self.cfg_h > 0) self.cfg_h else self.def.h;
        return .{ w, h };
    }

    /// Release everything engagement owns. Idempotent: a screen that
    /// engaged and reverted can re-engage fresh.
    fn freeEngage(self: *Screen, alloc: std.mem.Allocator) void {
        if (self.pristine.len > 0) {
            alloc.free(self.pristine);
            self.pristine = &.{};
        }
        if (self.dimmed.len > 0) {
            alloc.free(self.dimmed);
            self.dimmed = &.{};
        }
        if (self.img) |img| {
            if (!self.keep) img.deinit(alloc);
            self.img = null;
        }
        self.engaged = false;
        self.screen_last = null;
        self.slot_last = .{ null, null };
    }

    fn cleanup(self: *Screen, alloc: std.mem.Allocator) void {
        self.frame.cancel();
        self.ls.destroy();
        if (self.ov0) |o| {
            o.deinit();
            alloc.destroy(o);
        }
        if (self.ov1) |o| {
            o.deinit();
            alloc.destroy(o);
        }
        if (self.clear) |o| {
            o.deinit();
            alloc.destroy(o);
        }
        self.freeEngage(alloc);
        alloc.destroy(self);
    }

    /// Heap Overlay with the release listener pinned to its final address.
    fn allocOverlay(self: *Screen, alloc: std.mem.Allocator, v: View) !*Overlay {
        const dims = self.size();
        const w = dims[0];
        const h = dims[1];
        const o = try alloc.create(Overlay);
        errdefer alloc.destroy(o);
        o.* = try Overlay.create(v.shm, w, h);
        o.trackReleases();
        return o;
    }
};

/// Shared drag state across screens (the seat carries exactly one pointer.
/// Coordinates are ACTIVE-screen-local; global origins resolve at release.)
const HopApp = struct {
    st: DragState = .{},
    seat: *seat_mod.Seat,
    screens: []*Screen = &.{},
    active: usize = 0,
    /// Entered a different screen: capture its frozen frame and engage the
    /// overlay (done from the loop — captureOutput's internal roundtrips
    /// must not run inside a seat callback).
    pending: ?usize = null,
    /// The just-vacated screen reverts to transparent (also from the loop:
    /// its slots may still be held until the releases arrive).
    to_clear: ?usize = null,
};

/// Which screen a pointer enter belongs to. The seat stores the entered
/// surface before running the callback, so identity resolves from
/// `focus_surface` — no Seat API change needed.
fn screenOfEnter(app: *HopApp) ?usize {
    const surf = app.seat.focus_surface orelse return null;
    for (app.screens, 0..) |sc, i| {
        if (sc.ls.wl_surface == surf) return i;
    }
    return null;
}

/// Give a screen the drag: capture its frozen frame in the clear (the
/// overlay never painted there), spin up pristine/dimmed and the slot
/// pair, then paint the engagement frame — dim only pre-press, dim plus
/// the current box mid-drag. Full-buffer damage: transparent to dimmed
/// over the entire screen. False if the engine still held both slots (the
/// loop retries).
fn paintEngage(
    alloc: std.mem.Allocator,
    v: View,
    backends: *const shot.Backends,
    opts: Options,
    st: *const DragState,
    sc: *Screen,
    d: ?*wl.wl_display,
) bool {
    const dims_ = sc.size(); const w = dims_[0]; const h = dims_[1];
    if (w <= 0 or h <= 0) return true;
    if (!sc.engaged) {
        // Capture in the clear — the overlay never painted on this screen,
        // so the frozen frame is clean. A screen the compositor refuses to
        // capture falls back to the C++ plain-dim overlay (pristine stays
        // zero, so the hole is transparent).
        sc.pristine = alloc.alloc(u32, @as(usize, @intCast(w)) * @as(usize, @intCast(h))) catch {
            sc.pristine = &.{};
            return false;
        };
        @memset(sc.pristine, 0);
        var cap: ?shot.Image = shot.captureOutput(alloc, backends, sc.def.output, opts.cursor) catch null;
        if (cap) |*im| {
            paintBackdrop(sc.pristine, w, h, im);
            // Box the value Image: the Screen and the caller share it by
            // pointer for the rest of the session.
            const boxed = alloc.create(shot.Image) catch {
                im.deinit(alloc);
                cap = null;
                sc.freeEngage(alloc);
                return false;
            };
            boxed.* = cap.?;
            sc.img = boxed;
        }
        sc.dimmed = alloc.dupe(u32, sc.pristine) catch {
            sc.dimmed = &.{};
            sc.freeEngage(alloc);
            return false;
        };
        renderOverlay(sc.dimmed, w, h, null, opts.palette);
        sc.ov0 = sc.allocOverlay(alloc, v) catch {
            sc.freeEngage(alloc);
            return false;
        };
        sc.ov1 = sc.allocOverlay(alloc, v) catch {
            sc.freeEngage(alloc);
            return false;
        };
    }
    const o0 = sc.ov0 orelse return false;
    const o1 = sc.ov1 orelse return false;
    const slot = pickSlot(o0.busy, o1.busy) orelse return false;
    const ov = if (slot == 0) o0 else o1;
    ov.busy = true;
    // Dim only until the button is down; mid-drag crossings restart the box
    // at the entry point and paint it immediately.
    const b: ?Box = if (st.dragging) st.box() else null;
    renderFrame(ov.pixels(), sc.dimmed, sc.pristine, w, h, b, opts.palette);
    paint(ov.buffer, sc.ls.wl_surface, w, h, d, null, &sc.frame);
    sc.screen_last = b;
    sc.slot_last[slot] = b;
    sc.engaged = true;
    return true;
}

/// Revert a screen to its live view: one slot (a free one) is zeroed and
/// committed with full damage — fully transparent, so the compositor shows
/// the desktop again. A screen still holding the overlay elsewhere remains
/// untouched; freeing its imagery keeps only the pair alive until exit.
fn paintClear(alloc: std.mem.Allocator, sc: *Screen, d: ?*wl.wl_display) bool {
    const dims_ = sc.size(); const w = dims_[0]; const h = dims_[1];
    const o0 = sc.ov0 orelse return true; // never engaged: nothing to clear
    const o1 = sc.ov1 orelse return true;
    const slot = pickSlot(o0.busy, o1.busy) orelse return false;
    const ov = if (slot == 0) o0 else o1;
    ov.busy = true;
    @memset(ov.pixels(), 0);
    paint(ov.buffer, sc.ls.wl_surface, w, h, d, null, &sc.frame);
    sc.freeEngage(alloc);
    return true;
}

/// Interactive box selection that can hop between monitors: an overlay
/// surface is pre-mapped transparent on every screen (from `screens`,
/// where `primary` is the entry screen). While the drag is up, entering a
/// different screen reverts the vacated one to live and engages the target
/// with the box restarted at the boundary point. The answer is in GLOBAL
/// logical coordinates — or null when the user cancelled: right-click,
/// Escape, a sub-2px drag, or the compositor closing any surface.
pub fn select(
    alloc: std.mem.Allocator,
    v: View,
    screens: []const OutputRect,
    primary: usize,
    seat: *seat_mod.Seat,
    backends: *const shot.Backends,
    opts: Options,
) !?Selection {
    const d = v.display orelse return error.NoDisplay;
    if (screens.len == 0) return error.NoScreens;
    if (seat.seat == null or seat.pointer == null) return error.NoSeat;

    var app = HopApp{ .st = .{}, .seat = seat };
    const st = &app.st;
    app.active = primary;
    if (primary >= screens.len) return error.NoScreens;

    const sc_list = try alloc.alloc(*Screen, screens.len);
    var n_built: usize = 0;
    defer {
        for (sc_list[0..n_built]) |sc| sc.cleanup(alloc);
        alloc.free(sc_list);
    }
    for (screens, 0..) |def, i| {
        const sc = try alloc.create(Screen);
        sc.* = Screen{ .def = def };
        // Registered before the surface exists: a later failure cleans up
        // the partial Screen through the same path (empty ls is a no-op).
        sc_list[i] = sc;
        n_built = i + 1;
        if (!sc.ls.create(v.compositor, v.layer_shell, def.output, .overlay, "region-select")) {
            return error.NoWayland;
        }
        sc.ls.setAnchor(layer_mod.Anchor.top | layer_mod.Anchor.bottom | layer_mod.Anchor.left | layer_mod.Anchor.right);
        sc.ls.setExclusiveZone(-1);
        // Exclusive: Escape reaches the engaged screen and nothing else.
        sc.ls.setKeyboardInteractivity(1);
        sc.ls.ctx = @ptrCast(sc);
        sc.ls.on_configure = onScreenConfigure;
        sc.ls.on_closed = onScreenClosed;
    }
    app.screens = sc_list;
    st.buf_w = sc_list[primary].def.w;
    st.buf_h = sc_list[primary].def.h;

    // Elicit a configure on every screen with a bufferless first commit.
    for (sc_list) |sc| sc.ls.commit();
    _ = wl.wl_display_flush(d);
    _ = wl.wl_display_roundtrip(d);
    for (sc_list) |sc| {
        sc.cfg_w = @intCast(sc.ls.configured_width);
        sc.cfg_h = @intCast(sc.ls.configured_height);
        if (sc.def.w <= 0 or sc.def.h <= 0 or sc.size()[0] <= 0 or sc.size()[1] <= 0) {
            return error.NoScreens;
        }
    }

    // Map every screen transparent: the pointer cannot enter an unmapped
    // surface, so the crossing detection below depends on this.
    for (sc_list) |sc| {
        const dims_ = sc.size(); const w = dims_[0]; const h = dims_[1];
        sc.clear = sc.allocOverlay(alloc, v) catch null;
        const o = sc.clear orelse return error.NoShm;
        paint(o.buffer, sc.ls.wl_surface, w, h, d, null, &sc.frame);
    }

    // Shared seat, as the single-screen overlay did: one listener bind,
    // callbacks cleared on exit.
    const seat_obj = seat;
    seat_obj.cb_ctx = @ptrCast(&app);
    seat_obj.on_pointer_enter = hopEnter;
    seat_obj.on_pointer_motion = hopMotion;
    seat_obj.on_pointer_button = hopButton;
    seat_obj.on_key = hopKey;
    defer {
        seat_obj.on_pointer_enter = null;
        seat_obj.on_pointer_motion = null;
        seat_obj.on_pointer_button = null;
        seat_obj.on_key = null;
    }

    app.pending = primary; // engage the entry screen from the loop

    var pfd = [1]std.posix.pollfd{
        .{ .fd = wl.wl_display_get_fd(d), .events = std.posix.POLL.IN, .revents = 0 },
    };
    while (!st.done) {
        _ = wl.wl_display_dispatch_pending(d);
        _ = wl.wl_display_flush(d);
        if (st.done) break;
        // Surface closed by the compositor is a cancellation as before.
        for (app.screens) |sc| {
            if (sc.closed) {
                st.cancelled = true;
                st.done = true;
            }
        }
        if (st.done) break;

        // Hop housekeeping before pointer redraws. `pending` holds the
        // screen to engage (capture + first paint); `to_clear` the one to
        // revert. Both retry on the next event if slots are held.
        if (app.pending) |want| {
            const sc = app.screens[want];
            if (paintEngage(alloc, v, backends, opts, st, sc, d) and app.pending == want) {
                app.pending = null;
            }
        }
        if (app.to_clear) |idx| {
            const sc = app.screens[idx];
            if (paintClear(alloc, sc, d) and app.to_clear == idx) {
                app.to_clear = null;
            }
        }

        if (st.redraw and app.pending == null and app.to_clear == null) {
            const sc = app.screens[app.active];
            if (sc.engaged and sc.ov0 != null and sc.ov1 != null) {
                // Repaints pace on the screen's own frame callback; the
                // wall clock is a watchdog only (same rationale as the
                // single-screen overlay).
                const now_ms = frameNowMs();
                if (sc.frame.ready or now_ms - sc.last_frame_ms >= kFrameWatchdogMs) {
                    if (pickSlot(sc.ov0.?.busy, sc.ov1.?.busy)) |slot| {
                        sc.last_frame_ms = now_ms;
                        st.redraw = false;
                        const nb = st.box();
                        const ov = if (slot == 0) sc.ov0.? else sc.ov1.?;
                        // Slot repair vs the rect this slot holds; the
                        // damage hint vs the rect this screen shows.
                        const dirt = dirtyFrom(sc.slot_last[slot], nb);
                        const dmg = dirtyFrom(sc.screen_last, nb);
                        ov.busy = true;
                        if (dirt) |dd| {
                            renderFrameRegion(ov.pixels(), sc.dimmed, sc.pristine, sc.def.w, sc.def.h, nb, dd, opts.palette);
                        } else {
                            renderFrame(ov.pixels(), sc.dimmed, sc.pristine, sc.def.w, sc.def.h, nb, opts.palette);
                        }
                        paint(ov.buffer, sc.ls.wl_surface, sc.def.w, sc.def.h, d, dmg, &sc.frame);
                        sc.slot_last[slot] = nb;
                        sc.screen_last = nb;
                    }
                }
            }
        }

        pfd[0].revents = 0;
        const pr = std.posix.poll(&pfd, 50) catch break;
        if (pr == 0) continue;
        if (wl.wl_display_dispatch(d) < 0) break;
    }

    if (st.cancelled) return null;
    const sc = app.screens[app.active];
    if (sc.img == null) return error.NoCapture;
    sc.keep = true;
    return .{
        .rect = st.rect,
        .screen = app.active,
        .img = sc.img.?,
    };
}

/// Per-screen configure: the layer ctx is the heap Screen itself, so the
/// dimensions land on the right one (the ArrayList copies that lost these
/// are exactly why probe sizes came from the caller instead).
fn onScreenConfigure(ctx: *anyopaque, w: u32, h: u32) void {
    const sc: *Screen = @ptrCast(@alignCast(ctx));
    sc.cfg_w = @intCast(w);
    sc.cfg_h = @intCast(h);
}

/// A compositor-closed overlay ends the selection; the loop turns any
/// screen's closed flag into the shared cancel.
fn onScreenClosed(ctx: *anyopaque) void {
    const sc: *Screen = @ptrCast(@alignCast(ctx));
    sc.closed = true;
}

/// Frame-callback pacing, in miniature (same pattern as `notifications.zig`):
/// request a wl_surface.frame right before each commit; the `done` event
/// says the compositor is between swaps, so the next commit lands on the
/// refresh beat instead of whenever motion happened to arrive.
const FrameCb = struct {
    pending: ?*wl.wl_callback = null,
    /// A queued frame callback fired: a commit now displays on the
    /// compositor's next swap.
    ready: bool = false,

    fn onDone(data: ?*anyopaque, cb: ?*wl.wl_callback, time: u32) callconv(.c) void {
        _ = time;
        const self: *FrameCb = @ptrCast(@alignCast(data orelse return));
        if (cb) |c| wl.wl_callback_destroy(c);
        if (self.pending == cb) self.pending = null;
        self.ready = true;
    }

    const frame_listener = wl.wl_callback_listener{ .done = onDone };

    /// Must be called before the commit it belongs to (protocol order):
    /// requested later, it fires for the *next* commit and the chain idles
    /// a frame.
    fn request(self: *FrameCb, surface: ?*wl.wl_surface) void {
        if (self.pending != null) return;
        const cb = wl.wl_surface_frame(surface) orelse return;
        self.pending = cb;
        _ = wl.wl_callback_add_listener(cb, &frame_listener, self);
    }

    /// Drop a not-yet-fired callback before the owning stack/surface goes
    /// away: the queued `done` would otherwise run into freed memory of
    /// `select`.
    fn cancel(self: *FrameCb) void {
        if (self.pending) |c| wl.wl_callback_destroy(c);
        self.pending = null;
    }
};

fn paint(
    buffer: ?*wl.wl_buffer,
    surface: ?*wl.wl_surface,
    w: i32,
    h: i32,
    display: ?*wl.wl_display,
    damage: ?Box,
    fc: *FrameCb,
) void {
    const s = surface orelse return;
    wl.wl_surface_attach(s, buffer, 0, 0);
    // Damage exactly what changed: a fullscreen hint makes the compositor
    // re-read the whole shm buffer and re-composite the entire output per
    // drag frame — 14 MB of bandwidth for a moving rectangle. Null damage
    // means a full-frame repaint (the initial commit).
    if (damage) |dmg| {
        const x = @max(dmg.x1, 0);
        const y = @max(dmg.y1, 0);
        wl.wl_surface_damage_buffer(
            s,
            x,
            y,
            @max(dmg.x2 - x + 1, 0),
            @max(dmg.y2 - y + 1, 0),
        );
    } else {
        wl.wl_surface_damage_buffer(s, 0, 0, w, h);
    }
    fc.ready = false;
    fc.request(surface);
    wl.wl_surface_commit(s);
    _ = wl.wl_display_flush(display);
}

// cursor probe

const kCursorTimeoutMs: i32 = 2000;

/// Fallback repaint interval when a compositor never answers the surface
/// frame request: dragging falls back to ~10fps instead of freezing on
/// account of a broken callback chain. Normal pacing is the frame
/// callback itself (see `FrameCb`).
const kFrameWatchdogMs: i64 = 100;

fn frameNowMs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * 1000 +
        @as(i64, @intCast(@divTrunc(@max(ts.nsec, 0), 1000000)));
}

/// Where the pointer is, in global logical coordinates. No compositor API
/// answers this portably, so a transparent fullscreen layer surface goes up
/// on every output and the first pointer event says which one it landed on.
/// (The C++ side tried `hyprctl cursorpos` through a shell first; this port
/// skips that shortcut — one less shell in the screenshot path, and the
/// probe below covers every compositor.)
pub fn cursorGlobalPosition(alloc: std.mem.Allocator, v: View, outputs: []const OutputRect, seat: ?*seat_mod.Seat) !?[2]i32 {
    const d = v.display orelse return error.NoDisplay;
    if (v.compositor == null or v.shm == null or v.layer_shell == null or outputs.len == 0) return null;

    var surfaces: std.ArrayList(layer_mod.Surface) = .empty;
    var origins_x: std.ArrayList(i32) = .empty;
    var origins_y: std.ArrayList(i32) = .empty;
    var sizes_w: std.ArrayList(i32) = .empty;
    var sizes_h: std.ArrayList(i32) = .empty;
    var overlays: std.ArrayList(Overlay) = .empty;
    defer {
        for (surfaces.items) |*s| s.destroy();
        surfaces.deinit(alloc);
        origins_x.deinit(alloc);
        origins_y.deinit(alloc);
        sizes_w.deinit(alloc);
        sizes_h.deinit(alloc);
        for (overlays.items) |*o| o.deinit();
        overlays.deinit(alloc);
    }

    var state = CursorState{};
    for (outputs) |o| {
        if (o.output == null) continue;
        var ls = layer_mod.Surface{};
        if (!ls.create(v.compositor, v.layer_shell, o.output, .overlay, "cursor-pos")) continue;
        ls.setAnchor(layer_mod.Anchor.top | layer_mod.Anchor.bottom | layer_mod.Anchor.left | layer_mod.Anchor.right);
        ls.setExclusiveZone(-1);
        // Commit without a buffer so the compositor sends a configure and
        // maps the surface; the transparent buffer below is sized from the
        // caller's output sizes.
        ls.commit();
        try surfaces.append(alloc, ls);
        try origins_x.append(alloc, o.x);
        try origins_y.append(alloc, o.y);
        try sizes_w.append(alloc, o.w);
        try sizes_h.append(alloc, o.h);
    }
    if (surfaces.items.len == 0) return null;

    // Install the callbacks BEFORE any roundtrip below: the seat listener
    // was bound once at startup, so the pointer's enter can be dispatched
    // by the very first roundtrip — and a stationary pointer sends exactly
    // one enter. If the handlers are still null then, the enter is missed
    // and the probe times out even with the pointer on a probe surface.
    const seat_obj = seat orelse return null;
    seat_obj.cb_ctx = @ptrCast(&state);
    seat_obj.on_pointer_enter = onCursorEnter;
    seat_obj.on_pointer_motion = onCursorMotion;
    defer {
        seat_obj.on_pointer_enter = null;
        seat_obj.on_pointer_motion = null;
    }

    _ = wl.wl_display_flush(d);
    _ = wl.wl_display_roundtrip(d);

    // Zero-filled ARGB is fully transparent, so the probe surfaces stay
    // invisible while still being mapped enough to take pointer input.
    for (surfaces.items, 0..) |*ls, i| {
        // Sized from the caller's output sizes, not `configured_*`: the
        // append above copied each Surface after `create` pinned the layer
        // listener to its stack address, so configure dims land in dead
        // stack slots and the copies read zero forever (which is why no
        // buffer was ever attached and the probe always timed out).
        // Fullscreen anchors make configure equal the output size anyway.
        const w = sizes_w.items[i];
        const h = sizes_h.items[i];
        if (w <= 0 or h <= 0) continue;
        var o = Overlay.create(v.shm, w, h) catch continue;
        @memset(o.pixels(), 0);
        try overlays.append(alloc, o);
        // Probe surfaces paint once and never animate: no damage scoping
        // (full-buffer damage is the honest hint for a zeroed buffer) and
        // no frame callback beyond the one the paint path takes anyway.
        var probe_fc = FrameCb{};
        paint(o.buffer, ls.wl_surface, w, h, d, null, &probe_fc);
    }
    // Push the mappings through so the pointer's enter lands now rather
    // than on the first poll below.
    _ = wl.wl_display_roundtrip(d);

    // (Seat callbacks were installed before the first roundtrip above, so
    // the enter cannot slip through while the handlers are still null.)

    var elapsed: i32 = 0;
    var pfd = [1]std.posix.pollfd{
        .{ .fd = wl.wl_display_get_fd(d), .events = std.posix.POLL.IN, .revents = 0 },
    };
    while (!state.done and elapsed < kCursorTimeoutMs) {
        _ = wl.wl_display_dispatch_pending(d);
        _ = wl.wl_display_flush(d);
        if (state.done) break;
        pfd[0].revents = 0;
        const pr = std.posix.poll(&pfd, 50) catch break;
        if (pr == 0) {
            elapsed += 50;
            continue;
        }
        if (wl.wl_display_dispatch(d) < 0) break;
    }
    if (!state.done) return null;

    // Motion carries no surface, so which output the pointer is on comes
    // from the surface the seat last entered.
    var ox: i32 = 0;
    var oy: i32 = 0;
    if (seat_obj.focus_surface) |fs| {
        for (surfaces.items, 0..) |*ls, i| {
            if (ls.wl_surface == fs) {
                ox = origins_x.items[i];
                oy = origins_y.items[i];
                break;
            }
        }
    }
    return .{ ox + state.local_x, oy + state.local_y };
}

const CursorState = struct {
    local_x: i32 = 0,
    local_y: i32 = 0,
    entered: bool = false,
    done: bool = false,
};

fn onCursorEnter(ctx: *anyopaque, x: f64, y: f64) void {
    const st: *CursorState = @ptrCast(@alignCast(ctx));
    st.local_x = @intFromFloat(@trunc(x));
    st.local_y = @intFromFloat(@trunc(y));
    st.entered = true;
    st.done = true;
}

fn onCursorMotion(ctx: *anyopaque, x: f64, y: f64) void {
    const st: *CursorState = @ptrCast(@alignCast(ctx));
    // Motion carries no surface, so it only means anything once `enter` has
    // said which output the pointer is on.
    if (!st.entered) return;
    st.local_x = @intFromFloat(@trunc(x));
    st.local_y = @intFromFloat(@trunc(y));
    st.done = true;
}

// tests

test "bootstrap-region-select: drag box normalizes and clamps" {
    const t = std.testing;
    var st = DragState{ .buf_w = 100, .buf_h = 80 };
    st.start_x = 60;
    st.start_y = 10;
    st.end_x = 20;
    st.end_y = 55;
    try t.expectEqual(Box{ .x1 = 20, .y1 = 10, .x2 = 60, .y2 = 55 }, st.box());

    // A pointer that leaves the output mid-drag clamps to the edge rather
    // than producing coordinates the crop cannot honor.
    st.end_x = 400;
    st.end_y = -30;
    try t.expectEqual(@as(i32, 99), st.box().x2);
    try t.expectEqual(@as(i32, 0), st.box().y1);
}

test "bootstrap-region-select: buttons decide the result the C++ way" {
    const t = std.testing;
    var st = DragState{ .buf_w = 100, .buf_h = 80, .cur_x = 10, .cur_y = 12 };

    // A click smaller than 2px is a cancellation, not a selection.
    onButton(@ptrCast(&st), btn_left, 1);
    try t.expect(st.dragging);
    onButton(@ptrCast(&st), btn_left, 0);
    try t.expect(st.cancelled);
    try t.expect(st.done);

    // Right-click cancels too.
    st = DragState{ .buf_w = 100, .buf_h = 80 };
    onButton(@ptrCast(&st), btn_right, 1);
    try t.expect(st.cancelled and st.done);

    // A real drag answers in surface coordinates; the origin is added later.
    st = DragState{ .buf_w = 100, .buf_h = 80, .cur_x = 10, .cur_y = 10 };
    onButton(@ptrCast(&st), btn_left, 1);
    st.cur_x = 50;
    st.cur_y = 40;
    onMotion(@ptrCast(&st), 50, 40);
    onButton(@ptrCast(&st), btn_left, 0);
    try t.expect(!st.cancelled);
    try t.expectEqual(Rect{ .x = 10, .y = 10, .w = 40, .h = 30 }, st.rect);

    // Escape cancels, and only on press.
    st = DragState{};
    onKey(@ptrCast(&st), &.{ .state = 0, .sym = seat_mod.xkb.XKB_KEY_Escape });
    try t.expect(!st.done);
    onKey(@ptrCast(&st), &.{ .state = 1, .sym = seat_mod.xkb.XKB_KEY_Escape });
    try t.expect(st.cancelled and st.done);
}

test "bootstrap-region-select: overlay paints dim, border, and a transparent hole" {
    const t = std.testing;
    // Transparent white: distinguishable from both paint colors, and its
    // zero alpha keeps the dim's arithmetic exact wherever it is applied.
    const untouched: u32 = 0x00ffffff;
    var px = @as([(8 * 4)]u32, @splat(0));
    renderOverlay(&px, 8, 4, null, .{});
    // Cleared buffer plus a straight-alpha dim reads back as the dim itself.
    for (px) |p| try t.expectEqual(@as(u32, 0x44000000), p);

    @memset(&px, untouched);
    renderOverlay(&px, 8, 4, Box{ .x1 = 2, .y1 = 1, .x2 = 6, .y2 = 3 }, .{});
    // The strict interior keeps whatever was underneath — that is the hole
    // the frozen backdrop shows through.
    try t.expectEqual(untouched, px[2 * 8 + 3]);
    try t.expectEqual(untouched, px[2 * 8 + 5]);
    // The border ring is opaque and lit on all four sides.
    try t.expectEqual(@as(u32, 0xffffffff), px[1 * 8 + 4]);
    try t.expectEqual(@as(u32, 0xffffffff), px[3 * 8 + 4]);
    try t.expectEqual(@as(u32, 0xffffffff), px[2 * 8 + 2]);
    try t.expectEqual(@as(u32, 0xffffffff), px[2 * 8 + 6]);
    // Everything outside is dimmed.
    try t.expectEqual(@as(u32, 0x44000000), px[0 * 8 + 0]);
    try t.expectEqual(@as(u32, 0x44000000), px[3 * 8 + 7]);
}

test "bootstrap-region-select: blend over an opaque backdrop dims it" {
    const t = std.testing;
    // 0x44 black over opaque white lands on 0xbf-be-be — the picture
    // underneath survives the dim instead of being replaced by it.
    try t.expectEqual(@as(u32, 0xffbbbbbb), blendOver(0xffffffff, 0x44000000));
    // Over a cleared pixel the same dim reads back unchanged.
    try t.expectEqual(@as(u32, 0x44000000), blendOver(0x00000000, 0x44000000));
}

test "bootstrap-region-select: rect formats as WxH+X+Y" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    const s = try (Rect{ .x = 1920, .y = -40, .w = 300, .h = 200 }).format(&buf);
    try t.expectEqualStrings("300x200+1920+-40", s);
}
