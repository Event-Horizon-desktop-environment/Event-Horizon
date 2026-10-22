//! `--eh-screenshot`: the screenshot entry point.
//!
//! One capture, one crop, one PNG — all in memory. The C++ mode wrote a
//! scratch PNG to /tmp, decoded it again to crop, then unlinked it; keeping
//! the frame in RAM removes the temp files, the second decode, and the two
//! places a crashed run used to leave scratch bytes behind.
//!
//! Modes, resolved in the order `screenshot_mode.cpp` resolved them:
//!
//!   --list-windows                 print toplevel identifiers and exit
//!   --toplevel/--window ID         one window, via ext capture sources
//!   --select                       built-in drag picker over a frozen frame
//!   --slurp / --around-mouse / --geometry   an area of one output
//!   (nothing)                      one whole output
//!
//! `--select` differs from the C++ on purpose: the overlay shows the frame
//! that was captured rather than the live screen (see `region_select.zig`),
//! so the crop cannot disagree with what was on screen when the box was
//! drawn.
//!
//! Only one interactive picker may run at a time. Both the evdev
//! Super+Shift+S action and the Hyprland SUPER+SHIFT+S bind fire on the
//! same keypress, so without the lock a second picker mapped its overlay
//! behind the first and stayed open after the top one finished.

const std = @import("std");
extern fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
const wl = @import("../wl/c.zig").wl;
const conn_mod = @import("../wl/connection.zig");
const shot = @import("../wl/capture/shot.zig");
const foreign = @import("../wl/toplevel/foreign.zig");
const region = @import("region_select.zig");
const flags_mod = @import("screenshot_flags.zig");
const seat_mod = @import("../wl/seat.zig");
const logz = @import("../logz.zig");

const Allocator = std.mem.Allocator;

/// Sibling of the running binary, exactly where the C++ build puts it.
const clipboard_daemon_name = "horizonClipboardDaemon";

/// One bound output with everything the mode needs to place a crop in it.
const Out = struct {
    obj: ?*wl.wl_output = null,
    name: []const u8 = "",
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    fn contains(self: Out, x: i32, y: i32) bool {
        return x >= self.x and x < self.x + self.w and y >= self.y and y < self.y + self.h;
    }

    /// Overlap, the way the C++ picked an output for an arbitrary region.
    fn overlaps(self: Out, g: flags_mod.Geometry) bool {
        return g.x + g.w > self.x and g.x < self.x + self.w and g.y + g.h > self.y and g.y < self.y + self.h;
    }
};

/// stdout/stderr writers for a mode that has to report like a CLI tool
/// rather than a shell component.
const Reporter = struct {
    io: std.Io,
    buf: [1024]u8 = undefined,

    fn err(self: *Reporter, comptime fmt: []const u8, args: anytype) void {
        var f = std.Io.File.stderr();
        var w = f.writer(self.io, &self.buf);
        w.interface.print(fmt, args) catch {};
        w.interface.flush() catch {};
    }

    fn out(self: *Reporter, comptime fmt: []const u8, args: anytype) void {
        var f = std.Io.File.stdout();
        var w = f.writer(self.io, &self.buf);
        w.interface.print(fmt, args) catch {};
        w.interface.flush() catch {};
    }
};

fn printUsage(rep: *Reporter, argv0: []const u8) void {
    rep.err(
        \\Usage: {s} --eh-screenshot [options] [<file.png>]
        \\
        \\Options:
        \\  --cursor              Include cursor in capture
        \\  -o, --output NAME     wl_output name (full capture; default: output under the cursor, else largest)
        \\  --geometry WxH+X+Y    Region in compositor-global logical coordinates
        \\  -g WxH+X+Y            Same as --geometry
        \\  --select              Interactive region selection (built in, no external tools)
        \\  --around-mouse WxH    Capture a WxH region centered on the current cursor
        \\  --all-monitors        Capture every output as one stitched panoramic frame
        \\  --slurp               Pick a region with the external `slurp` tool
        \\  --no-clipboard        Do not hand the PNG to the clipboard daemon
        \\  --clipboard           Same, spelled out (this is already the default)
        \\  --preview             Hand the PNG to the clipboard daemon for the preview
        \\                        card. There is no GUI for it yet: behaves as --clipboard
        \\  --list-windows        List toplevel identifiers and exit
        \\  --toplevel ID         Capture a toplevel window by identifier
        \\  --window ID           Same as --toplevel
        \\
        \\After a successful save the image is handed to horizonClipboardDaemon
        \\(image/png, offered over data-control) unless --no-clipboard is given.
        \\
        \\Full output: omit --geometry / --select (uses --output, else the output under
        \\the cursor, else the largest). Uses ext-image-copy-capture when available and
        \\falls back to zwlr_screencopy.
        \\Area: --geometry / --around-mouse / --select / --slurp. Captures the full
        \\output via ext-image-copy-capture and crops in memory; falls back to
        \\zwlr_screencopy region capture.
        \\Window: --toplevel / --window. Requires ext-foreign-toplevel-list and
        \\ext-foreign-toplevel-image-capture-source.
        \\Panorama: --all-monitors. The union of the outputs in logical
        \\coordinates; gaps between monitors stay opaque black.
        \\
    , .{argv0});
}

/// `slurp`'s geometry line, or null when the tool is missing, cancelled, or
/// printed something unparseable. Spawned directly — no shell, so nothing in
/// the slurp output can be re-interpreted as a command.
fn slurpLine(alloc: Allocator, io: std.Io) ?[]u8 {
    const res = std.process.run(alloc, io, .{ .argv = &[_][]const u8{ "slurp", "-f", "%wx%h+%x+%y" } }) catch return null;
    defer alloc.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        alloc.free(res.stdout);
        return null;
    }
    const line = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (line.len == 0) {
        alloc.free(res.stdout);
        return null;
    }
    return alloc.dupe(u8, line) catch {
        alloc.free(res.stdout);
        return null;
    };
}

/// Hand the PNG to the clipboard daemon, preferring the copy next to our own
/// executable (audit F-5: never a hardcoded /usr/bin path) and falling back
/// to a PATH lookup. The daemon outlives this process — the screenshot mode
/// exits as soon as the file is written.
fn handoffClipboard(io: std.Io, self_exe: []const u8, png_path: []const u8, temporary: bool) bool {
    if (std.fs.path.dirname(self_exe)) |dir| {
        if (std.fs.path.join(std.heap.page_allocator, &.{ dir, clipboard_daemon_name }) catch null) |sibling| {
            defer std.heap.page_allocator.free(sibling);
            if (spawnDaemon(io, sibling, png_path, temporary)) return true;
        }
    }
    return spawnDaemon(io, clipboard_daemon_name, png_path, temporary);
}

fn spawnDaemon(io: std.Io, bin: []const u8, png_path: []const u8, temporary: bool) bool {
    var child = std.process.spawn(io, .{
        .argv = if (temporary) &.{ bin, png_path, "--remove-after-read" } else &.{ bin, png_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    // No wait: the daemon is meant to outlive this mode, and reaping it here
    // would defeat that.
    _ = &child;
    return true;
}

/// `--all-monitors`: the whole virtual desktop in one RGBA frame. The
/// canvas is the union of the output rects in logical coordinates; each
/// output's capture (mode pixels) is scaled in nearest-neighbour, the same
/// math `paintBackdrop` uses for the frozen backdrop. Gaps between
/// monitors stay opaque black — layout, not transparency. A capture that
/// fails leaves its placement black and the panorama still ships.
fn captureAllMonitors(
    alloc: Allocator,
    backends: *const shot.Backends,
    outs: []const Out,
    cursor: bool,
) !shot.Image {
    var min_x = outs[0].x;
    var min_y = outs[0].y;
    var max_x = outs[0].x + outs[0].w;
    var max_y = outs[0].y + outs[0].h;
    for (outs[1..]) |o| {
        min_x = @min(min_x, o.x);
        min_y = @min(min_y, o.y);
        max_x = @max(max_x, o.x + o.w);
        max_y = @max(max_y, o.y + o.h);
    }
    const vw = max_x - min_x;
    const vh = max_y - min_y;
    if (vw <= 0 or vh <= 0) return error.BadDimensions;
    var canvas = try shot.Image.init(alloc, vw, vh);
    errdefer canvas.deinit(alloc);
    // Opaque black floor before the placements land on top.
    @memset(canvas.rgba, 0);
    var p: usize = 3;
    while (p < canvas.rgba.len) : (p += 4) canvas.rgba[p] = 255;
    for (outs) |o| {
        var frame = shot.captureOutput(alloc, backends, o.obj, cursor) catch continue;
        defer frame.deinit(alloc);
        blitScaled(&canvas, &frame, o.x - min_x, o.y - min_y, o.w, o.h);
    }
    return canvas;
}

/// Nearest-neighbour scale of `src` into `dst`'s logical rect at (dx,dy)
/// sized dw×dh (mode pixels → logical, as `paintBackdrop` does). Identity
/// scale — every scale-1 output, the common case — takes the row memcpy.
fn blitScaled(dst: *shot.Image, src: *const shot.Image, dx: i32, dy: i32, dw: i32, dh: i32) void {
    if (dw <= 0 or dh <= 0) return;
    if (src.width <= 0 or src.height <= 0) return;
    const sw: i64 = src.width;
    const sh: i64 = src.height;
    const dwl: i64 = dw;
    const dhl: i64 = dh;
    var y: i64 = 0;
    while (y < dhl) : (y += 1) {
        const src_row_i: i64 = @divTrunc(y * sh, dhl) * sw * 4;
        const src_row: usize = @intCast(src_row_i);
        const dst_off: usize = @intCast(
            (@as(i64, dy) + y) * @as(i64, dst.width) * 4 + @as(i64, dx) * 4,
        );
        const row: usize = @intCast(dwl * 4);
        if (sw == dwl and sh == dhl) {
            if (dst_off + row <= dst.rgba.len and src_row + row <= src.rgba.len) {
                @memcpy(dst.rgba[dst_off..][0..row], src.rgba[src_row..][0..row]);
            }
            continue;
        }
        var x: i64 = 0;
        while (x < dwl) : (x += 1) {
            const so: usize = @intCast(src_row_i + @divTrunc(x * sw, dwl) * 4);
            const do: usize = dst_off + @as(usize, @intCast(x)) * 4;
            if (so + 4 <= src.rgba.len and do + 4 <= dst.rgba.len) {
                @memcpy(dst.rgba[do..][0..4], src.rgba[so..][0..4]);
            }
        }
    }
}

fn collectOutputs(alloc: Allocator, bound: *const conn_mod.Connection.Bound) ![]Out {
    var list: std.ArrayList(Out) = .empty;
    errdefer list.deinit(alloc);
    for (bound.outputs.items) |o| {
        const r = o.rect();
        try list.append(alloc, .{ .obj = o.obj, .name = o.name, .x = r.x, .y = r.y, .w = r.w, .h = r.h });
    }
    return list.toOwnedSlice(alloc);
}

/// Output for a region: the one it overlaps, else the one under the cursor,
/// else the largest — the C++ fallback ladder. One deliberate difference:
/// `--geometry` also picks the output the region actually sits on, where the
/// C++ ignored the region and cropped global coordinates out of whichever
/// output the cursor happened to be over.
fn pickOutput(alloc: Allocator, v: region.View, outs: []const Out, want_name: ?[]const u8, g: ?flags_mod.Geometry, seat: ?*seat_mod.Seat) !Out {
    if (want_name) |name| {
        for (outs) |o| {
            if (std.mem.eql(u8, o.name, name)) return o;
        }
        return error.NoMatchingOutput;
    }
    if (g) |geo| {
        for (outs) |o| {
            if (o.overlaps(geo)) return o;
        }
        return error.RegionOutsideOutputs;
    }
    // No region and no name: the output the cursor is on, then the largest.
    // The probe needs a transparent surface per output, so it is only built
    // here — a run that already knows its output never pays for it.
    const rects = try outputRects(alloc, outs);
    defer alloc.free(rects);
    if (region.cursorGlobalPosition(alloc, v, rects, seat) catch null) |p| {
        for (outs) |o| {
            if (o.contains(p[0], p[1])) return o;
        }
    }
    var best: ?Out = null;
    for (outs) |o| {
        if (best == null or @as(i64, o.w) * o.h > @as(i64, best.?.w) * best.?.h) best = o;
    }
    return best orelse error.NoOutputs;
}

fn outputRects(alloc: Allocator, outs: []const Out) ![]region.OutputRect {
    var list: std.ArrayList(region.OutputRect) = .empty;
    errdefer list.deinit(alloc);
    for (outs) |o| try list.append(alloc, .{ .output = o.obj, .x = o.x, .y = o.y, .w = o.w, .h = o.h });
    return list.toOwnedSlice(alloc);
}

/// The picker's single-flight lock result. `file` is the held lock (kept
/// open for the process lifetime; the kernel drops it on exit); `busy`
/// means a live picker owns it. Both empty means no lock could be taken —
/// no XDG_RUNTIME_DIR, or an unwritable one — and the picker proceeds, so
/// the guard can never be the reason a screenshot is impossible.
const PickerLock = struct {
    file: ?std.Io.File = null,
    busy: bool = false,
};

fn acquirePickerLock(io: std.Io, xdg_runtime: ?[]const u8) PickerLock {
    const rt = xdg_runtime orelse return .{};
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/event-horizon-region-select.lock", .{rt}) catch return .{};
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return .{};
    const rc = std.os.linux.flock(file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB);
    if (std.os.linux.errno(rc) != .SUCCESS) {
        file.close(io);
        return .{ .busy = true };
    }
    return .{ .file = file };
}

pub fn run(io: std.Io, alloc: Allocator, args: []const []const u8, xdg_runtime: ?[]const u8) !u8 {
    var rep = Reporter{ .io = io };
    const argv0: []const u8 = if (args.len > 0) args[0] else "horizon";

    const parsed = flags_mod.parse(args);
    if (parsed.problem) |p| {
        rep.err("screenshot: {s}\n", .{p});
        printUsage(&rep, argv0);
        return 2;
    }
    const f = parsed.flags;
    if (f.wantsUsage()) {
        printUsage(&rep, argv0);
        return 2;
    }
    if (f.exclusiveProblem()) |p| {
        rep.err("screenshot: {s}.\n", .{p});
        return 2;
    }

    // Super+Shift+S reaches this mode twice: once from the supervisor's
    // evdev keybinds and once from the Hyprland bind (`eh-ipc screenshot
    // --select --clipboard`). Both processes would map a picker; the one
    // behind would be left open after the top selection finished. Let the
    // first process own the picker and drop the duplicate quietly.
    var picker_lock: ?std.Io.File = null;
    if (f.select) {
        const lock = acquirePickerLock(io, xdg_runtime);
        if (lock.busy) {
            logz.log("screenshot: region picker already open; duplicate request ignored", .{});
            return 0;
        }
        picker_lock = lock.file;
    }
    defer if (picker_lock) |file| file.close(io);

    // Geometry and slurp do not need a compositor, so they resolve first.
    var geom: ?flags_mod.Geometry = null;
    if (f.geometry) |raw| {
        geom = flags_mod.parseGeometry(raw) orelse {
            rep.err("screenshot: bad --geometry value '{s}' (expected WxH+X+Y, e.g. 400x300+10+20)\n", .{raw});
            return 2;
        };
    }
    if (f.slurp) {
        const line = slurpLine(alloc, io) orelse {
            rep.err("screenshot: slurp failed or was cancelled (is `slurp` installed?)\n", .{});
            return 2;
        };
        defer alloc.free(line);
        geom = flags_mod.parseGeometry(line) orelse {
            rep.err("screenshot: slurp returned a bad geometry '{s}'.\n", .{line});
            return 2;
        };
    }
    var conn = conn_mod.Connection.init(alloc);
    defer conn.deinit();
    if (!conn.connect(null)) {
        rep.err("screenshot: Wayland connection failed (WAYLAND_DISPLAY?)\n", .{});
        return 1;
    }
    var bound = conn_mod.Connection.Bound{};
    defer conn.freeBound(&bound);
    conn.bindAll(&bound);

    const backends = shot.Backends{
        .display = conn.display,
        .shm = bound.shm,
        .ext_copy = bound.ext_image_copy_capture,
        .ext_output_source = bound.ext_output_capture_source,
        .ext_toplevel_source = bound.ext_toplevel_capture_source,
        .wlr = bound.screencopy,
    };
    if (backends.shm == null) {
        rep.err("screenshot: wl_shm not available.\n", .{});
        return 1;
    }

    // mkdtemp creates an unpredictable 0700 directory atomically, even with
    // umask 022. The writer opens its file with 0600 and O_NOFOLLOW.
    var tmp_dir = "/tmp/eh-screenshot-XXXXXX".* ++ [_:0]u8{0};
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    var handed_off = false;
    const out_path: []const u8 = f.file orelse blk: {
        if (mkdtemp(&tmp_dir) == null) return 1;
        break :blk std.fmt.bufPrint(&tmp_buf, "{s}/capture.png", .{std.mem.sliceTo(&tmp_dir, 0)}) catch return 1;
    };
    defer if (f.file == null and !handed_off) {
        std.Io.Dir.cwd().deleteFile(io, out_path) catch {};
        std.Io.Dir.cwd().deleteDir(io, std.mem.sliceTo(&tmp_dir, 0)) catch {};
    };

    const view = region.View{
        .display = conn.display,
        .compositor = bound.compositor,
        .shm = bound.shm,
        .layer_shell = bound.layer_shell,
        .seat = if (bound.seat_obj) |s| s.seat else null,
    };

    // --- window capture -------------------------------------------------
    if (f.window) |id| {
        if (bound.foreign_toplevel_list == null) {
            rep.err("screenshot: window capture requires ext-foreign-toplevel-list (not available).\n", .{});
            return 1;
        }
        if (backends.ext_toplevel_source == null) {
            rep.err("screenshot: window capture requires ext-foreign-toplevel-image-capture-source (not available).\n", .{});
            return 1;
        }
        if (backends.ext_copy == null) {
            rep.err("screenshot: window capture requires ext-image-copy-capture (not available).\n", .{});
            return 1;
        }
        var tracker = foreign.Tracker.init(alloc);
        defer tracker.deinit();
        tracker.bindExt(bound.foreign_toplevel_list);
        _ = wl.wl_display_roundtrip(conn.display);

        var handle: ?*wl.ext_foreign_toplevel_handle_v1 = null;
        for (tracker.windows.items) |w| {
            if (std.mem.eql(u8, w.identifier, id)) {
                handle = @ptrCast(@alignCast(w.raw));
                break;
            }
        }
        if (handle == null) {
            rep.err("screenshot: no toplevel found with identifier: {s}\n", .{id});
            return 1;
        }
        var img = shot.captureToplevel(alloc, &backends, handle, f.cursor) catch |e| {
            rep.err("screenshot: toplevel capture failed ({s}).\n", .{@errorName(e)});
            return 1;
        };
        defer img.deinit(alloc);
        shot.writePng(out_path, &img, f.file == null) catch |e| {
            rep.err("screenshot: writing {s} failed ({s}).\n", .{ out_path, @errorName(e) });
            return 1;
        };
        if (f.clipboard or f.preview) handed_off = handoffClipboard(io, argv0, out_path, f.file == null);
        return 0;
    }

    // --- list windows ---------------------------------------------------
    if (f.list_windows) {
        if (bound.foreign_toplevel_list == null) {
            rep.err("screenshot: ext-foreign-toplevel-list not available (not Hyprland?).\n", .{});
            return 1;
        }
        var tracker = foreign.Tracker.init(alloc);
        defer tracker.deinit();
        tracker.bindExt(bound.foreign_toplevel_list);
        _ = wl.wl_display_roundtrip(conn.display);
        for (tracker.windows.items) |w| {
            rep.out("{s}  {s}  {s}\n", .{ w.identifier, w.app_id, w.title });
        }
        return 0;
    }

    // --- output choice --------------------------------------------------
    const outs = try collectOutputs(alloc, &bound);
    defer alloc.free(outs);
    if (outs.len == 0) {
        rep.err("screenshot: no wl_output available.\n", .{});
        return 1;
    }

    // `--around-mouse` resolves the cursor now: the region is centered on it
    // and the crop then comes from whichever output that lands on.
    if (f.around_mouse) {
        if (view.layer_shell == null) {
            rep.err("screenshot: --around-mouse requires layer-shell (not available).\n", .{});
            return 1;
        }
        const rects = try outputRects(alloc, outs);
        defer alloc.free(rects);
        const pos = region.cursorGlobalPosition(alloc, view, rects, bound.seat_obj) catch null orelse {
            rep.err("screenshot: failed to get cursor position.\n", .{});
            return 1;
        };
        geom = .{
            .w = f.around_w,
            .h = f.around_h,
            .x = pos[0] - @divTrunc(f.around_w, 2),
            .y = pos[1] - @divTrunc(f.around_h, 2),
        };
    }

    const chosen = pickOutput(alloc, view, outs, f.output, geom, bound.seat_obj) catch |e| {
        switch (e) {
            error.NoMatchingOutput => rep.err("screenshot: no matching wl_output (--output {s}).\n", .{f.output.?}),
            error.RegionOutsideOutputs => rep.err(
                "screenshot: region {d}x{d}+{d}+{d} is not within any output.\n",
                .{ geom.?.w, geom.?.h, geom.?.x, geom.?.y },
            ),
            else => rep.err("screenshot: no wl_output available.\n", .{}),
        }
        return 1;
    };
    const out_origin_x = chosen.x;
    const out_origin_y = chosen.y;

    // --- panorama capture ------------------------------------------------
    if (f.all_monitors) {
        var all = captureAllMonitors(alloc, &backends, outs, f.cursor) catch |e| {
            rep.err("screenshot: all-monitors capture failed ({s}).\n", .{@errorName(e)});
            return 1;
        };
        defer all.deinit(alloc);
        shot.writePng(out_path, &all, f.file == null) catch |e| {
            rep.err("screenshot: writing {s} failed ({s}).\n", .{ out_path, @errorName(e) });
            return 1;
        };
        if (f.clipboard or f.preview) handed_off = handoffClipboard(io, argv0, out_path, f.file == null);
        return 0;
    }

    // --- capture --------------------------------------------------------
    if (f.select) {
        if (view.layer_shell == null) {
            rep.err("screenshot: interactive selection requires layer-shell (not available).\n", .{});
            return 1;
        }
        // The selection hops between monitors: `pickOutput` decides where
        // it starts, and mid-drag the overlay follows the pointer onto any
        // other screen. `outputRects` is built from `outs` in the same
        // order, so the entry screen's index resolves which frozen frame
        // the release cropped from.
        const seat_state = bound.seat_obj orelse {
            rep.err("screenshot: interactive selection requires a seat (not available).\n", .{});
            return 1;
        };
        const rects = try outputRects(alloc, outs);
        defer alloc.free(rects);
        var primary: usize = 0;
        for (outs, 0..) |o, i| {
            if (o.obj == chosen.obj) primary = i;
        }
        const sel = region.select(alloc, view, rects, primary, seat_state, &backends, .{ .cursor = f.cursor }) catch |e| {
            rep.err("screenshot: selection overlay failed ({s}).\n", .{@errorName(e)});
            return 1;
        } orelse {
            // Cancelled: right-click, Escape, or a too-small drag.
            return 2;
        };
        // Crop the screen the selection finished on, not the entry screen:
        // a hop moves both the rectangle and the pixels it belongs to.
        defer sel.img.deinit(alloc);
        var cropped = sel.img.crop(
            alloc,
            sel.rect.x - rects[sel.screen].x,
            sel.rect.y - rects[sel.screen].y,
            sel.rect.w,
            sel.rect.h,
        ) catch |e| {
            rep.err("screenshot: crop of the frozen capture failed ({s}).\n", .{@errorName(e)});
            return 1;
        };
        defer cropped.deinit(alloc);
        shot.writePng(out_path, &cropped, f.file == null) catch |e| {
            rep.err("screenshot: writing {s} failed ({s}).\n", .{ out_path, @errorName(e) });
            return 1;
        };
    } else if (geom) |g| {
        var img = shot.captureRegion(
            alloc,
            &backends,
            chosen.obj,
            g.x - out_origin_x,
            g.y - out_origin_y,
            g.w,
            g.h,
            f.cursor,
        ) catch |e| {
            rep.err("screenshot: area capture failed ({s}).\n", .{@errorName(e)});
            return 1;
        };
        defer img.deinit(alloc);
        shot.writePng(out_path, &img, f.file == null) catch |e| {
            rep.err("screenshot: writing {s} failed ({s}).\n", .{ out_path, @errorName(e) });
            return 1;
        };
    } else {
        var img = shot.captureOutput(alloc, &backends, chosen.obj, f.cursor) catch |e| {
            rep.err("screenshot: full output capture failed ({s}).\n", .{@errorName(e)});
            return 1;
        };
        defer img.deinit(alloc);
        shot.writePng(out_path, &img, f.file == null) catch |e| {
            rep.err("screenshot: writing {s} failed ({s}).\n", .{ out_path, @errorName(e) });
            return 1;
        };
    }

    if (f.clipboard or f.preview) handed_off = handoffClipboard(io, argv0, out_path, f.file == null);
    return 0;
}

// tests

test "bootstrap-screenshot: picker lock is single-flight per runtime dir" {
    const t = std.testing;
    const io = std.testing.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var rtbuf: [256]u8 = undefined;
    const rt = try std.fmt.bufPrint(&rtbuf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    const first = acquirePickerLock(io, rt);
    try t.expect(first.file != null);
    try t.expect(!first.busy);
    var first_file = first.file;
    defer if (first_file) |file| file.close(io);

    // A second picker in the same runtime dir must see the lock held.
    const second = acquirePickerLock(io, rt);
    try t.expect(second.file == null);
    try t.expect(second.busy);

    // Dropping the holder releases it for the next request.
    first_file.?.close(io);
    first_file = null;
    const third = acquirePickerLock(io, rt);
    try t.expect(third.file != null);
    try t.expect(!third.busy);
    if (third.file) |file| file.close(io);

    // No runtime dir is not a conflict: the picker proceeds unlocked.
    const unlocked = acquirePickerLock(io, null);
    try t.expect(unlocked.file == null);
    try t.expect(!unlocked.busy);
}

test "bootstrap-screenshot: output choice by name, region, and size" {
    const t = std.testing;
    var seat_state = seat_mod.Seat.init(t.allocator);
    defer seat_state.deinit();
    const outs = [_]Out{
        .{ .name = "DP-1", .x = 0, .y = 0, .w = 1920, .h = 1080 },
        .{ .name = "HDMI-A-1", .x = 1920, .y = 0, .w = 2560, .h = 1440 },
    };
    // By name, and the miss that has to stay a miss.
    try t.expectEqual(outs[0], try pickOutput(t.allocator, .{}, &outs, "DP-1", null, &seat_state));
    try t.expectError(error.NoMatchingOutput, pickOutput(t.allocator, .{}, &outs, "eDP-1", null, &seat_state));
    // A region on the second output selects it; one off every output does not.
    try t.expectEqual(outs[1], try pickOutput(t.allocator, .{}, &outs, null, .{ .w = 100, .h = 100, .x = 2000, .y = 10 }, &seat_state));
    try t.expectError(error.RegionOutsideOutputs, pickOutput(t.allocator, .{}, &outs, null, .{ .w = 100, .h = 100, .x = 9000, .y = 9000 }, &seat_state));
    // With no cursor and no region, the largest output wins.
    try t.expectEqual(outs[1], try pickOutput(t.allocator, .{}, &outs, null, null, &seat_state));
}

test "bootstrap-screenshot: overlap and containment" {
    const t = std.testing;
    const o = Out{ .name = "DP-1", .x = 1920, .y = 0, .w = 2560, .h = 1440 };
    try t.expect(o.contains(1920, 0));
    try t.expect(!o.contains(1919, 0));
    try t.expect(!o.contains(1920 + 2560, 0));
    // The C++ overlap test: touching edges do not count.
    try t.expect(!o.overlaps(.{ .w = 10, .h = 10, .x = 1910, .y = 0 }));
    try t.expect(o.overlaps(.{ .w = 10, .h = 10, .x = 1915, .y = 0 }));
}
