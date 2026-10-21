//! `horizon-wallpaper` — paints the background layer on every output.
//!
//! Two modes:
//!   * `--set <image>` writes `<settings>/wallpaper/wallpaper.toml` (under
//!     `~/.config/Event-Horizon`) and exits.
//!     That is the settings-app-free way to change wallpaper: the running
//!     instance notices the file over its inotify watch and repaints.
//!   * no args — bind the layer surfaces, decode the configured image, then
//!     park in the event loop watching for reloads.

const std = @import("std");
const eh = @import("eh");
const app = @import("app.zig");
const layer = eh.wl_layer;
const ns = eh.ns;
const shm_mod = eh.wl_shm;
const decode = eh.wp_decode;
const blit = eh.wp_blit;
const config = eh.config;
const setimage = eh.wp_setimage;
const linux = std.os.linux;
const parent_guard = eh.parent_guard;
const logz = eh.logz;

const Surface = struct {
    layer: layer.Surface = .{},
    shm: shm_mod.ShmBuffer,
    w: i32 = 0,
    h: i32 = 0,
};

const Wallpaper = struct {
    app: *app.App,
    surfaces: std.ArrayList(Surface) = .empty,
    img: ?decode.Image = null,
    /// Owned copy of what `img` was decoded from, so a reload that did not
    /// change the picture does not pay for a re-decode.
    path: []u8 = &.{},

    fn deinit(self: *Wallpaper) void {
        self.freeSurfaces();
        self.freeImage();
        if (self.path.len > 0) self.app.gpa.free(self.path);
        self.path = &.{};
    }

    fn freeImage(self: *Wallpaper) void {
        if (self.img) |*im| im.free(self.app.gpa);
        self.img = null;
    }

    fn freeSurfaces(self: *Wallpaper) void {
        for (self.surfaces.items) |*s| {
            s.layer.destroy();
            s.shm.deinit();
        }
        self.surfaces.clearRetainingCapacity();
    }

    /// Decodes `path`, keeping the old image when the new one fails so a bad
    /// pick leaves the desktop intact rather than blank.
    fn loadImage(self: *Wallpaper, path: []const u8) void {
        if (self.path.len > 0 and std.mem.eql(u8, self.path, path)) return;
        const gpa = self.app.gpa;
        const next = decode.loadRgba(gpa, path) orelse {
            logz.err("decode failed: {s}", .{path});
            return;
        };
        self.freeImage();
        self.img = next;
        if (self.path.len > 0) gpa.free(self.path);
        self.path = gpa.dupe(u8, path) catch &.{};
    }

    /// Re-blits the current image into every output surface and commits.
    fn paintAll(self: *Wallpaper) void {
        const im = self.img orelse return;
        for (self.surfaces.items) |*s| {
            if (s.w <= 0 or s.h <= 0) continue;
            const data = s.shm.data orelse continue;
            const pixels: [*]u32 = @ptrCast(@alignCast(data));
            const n: usize = @intCast(s.w * s.h);
            blit.blitCover(pixels[0..n], s.w, s.h, im.pixels, im.w, im.h, .fill);
            s.layer.attach(s.shm.wlBuffer(), 0, 0);
            // The buffer is allocated at the output's physical pixels and
            // filled 1:1 (raw blit, no cairo), so declare the scale — the
            // compositor then maps it to the correct logical surface size
            // instead of treating a 2x buffer as 2x too large.
            s.layer.setBufferScale(s.layer.scale);
            s.layer.damage(0, 0, s.w, s.h);
            s.shm.markBusy();
            s.layer.commit();
        }
        _ = self.app.conn.flush();
        logz.log(
            "paint: {d} surface(s) from {d}x{d} source",
            .{ self.surfaces.items.len, im.w, im.h },
        );
        _ = self.app.conn.roundtrip();
    }

    /// `App.on_reload` — the config slices were just swapped out, so read
    /// everything again from `loaded` rather than any cached copy.
    fn onReload(ctx: *anyopaque) void {
        const self: *Wallpaper = @ptrCast(@alignCast(ctx));
        const cfg = &self.app.loaded.cfg;
        logz.log(
            "reload: enabled={s} image='{s}' surfaces={d}",
            .{ if (cfg.wallpaper_enabled) "true" else "false", cfg.wallpaper_image, self.surfaces.items.len },
        );
        if (!cfg.wallpaper_enabled or cfg.wallpaper_image.len == 0) {
            self.freeImage();
            return;
        }
        const before = if (self.img) |_| true else false;
        self.loadImage(cfg.wallpaper_image);
        if (!before or self.img != null) self.paintAll();
    }
};

/// `horizon-wallpaper --set <image>` — rewrite the component file and stop.
fn runSet(init: std.process.Init, image: []const u8) u8 {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const settings = config.settingsDir(gpa, init.environ_map.get("XDG_CONFIG_HOME"), init.environ_map.get("HOME")) catch |e| {
        std.debug.print("horizon-wallpaper: cannot resolve settings dir: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer gpa.free(settings);
    const file = config.componentPath(gpa, settings, "wallpaper") catch |e| {
        std.debug.print("horizon-wallpaper: cannot resolve component path: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer gpa.free(file);
    const dir = std.fs.path.dirname(file) orelse return 1;

    const existing = cwd.readFileAlloc(io, file, gpa, .limited(1 << 20)) catch null;
    defer if (existing) |d| gpa.free(d);

    const updated = setimage.applySetImage(gpa, existing orelse "", image) catch |e| {
        logz.err("rewrite failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer gpa.free(updated);

    cwd.createDirPath(io, dir) catch {};
    cwd.writeFile(io, .{ .sub_path = file, .data = updated }) catch |e| {
        logz.err("cannot write {s}: {s}", .{ file, @errorName(e) });
        return 1;
    };
    logz.log("--set: '{s}' -> {s}", .{ image, file });
    return 0;
}

pub fn main(init: std.process.Init) !u8 {
    _ = parent_guard.installGuard();
    // Same isolation switch as the dock: `--set` resolves the settings dir, so
    // this must run before the args branch below, not just before `App.init`.
    config.setLeafOverride(config.leafForEnvFlag(init.environ_map.get(config.kIsolateEnv)));
    const gpa = init.gpa;
    const io = init.io;

    logz.init(io, init.environ_map.get("HOME"), "horizon-wallpaper-zig");
    defer logz.deinit();
    logz.log("boot: pid={d}", .{linux.getpid()});

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch &.{};
    if (args.len >= 2) {
        const a = args[1];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                "usage: horizon-wallpaper              show the configured wallpaper\n" ++
                    "       horizon-wallpaper --set <image>  switch wallpaper and exit\n",
                .{},
            );
            return 0;
        }
        if (std.mem.startsWith(u8, a, "--set=")) return runSet(init, a["--set=".len..]);
        if (std.mem.eql(u8, a, "--set")) {
            if (args.len < 3) {
                std.debug.print("horizon-wallpaper: --set needs an image path\n", .{});
                return 2;
            }
            return runSet(init, args[2]);
        }
    }

    var a = app.App.init(
        gpa,
        io,
        init.environ_map.get("XDG_CONFIG_HOME"),
        init.environ_map.get("HOME"),
    ) catch |e| {
        logz.err("init failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer a.deinit();

    var wp = Wallpaper{ .app = &a };
    defer wp.deinit();

    a.on_reload = Wallpaper.onReload;
    a.reload_ctx = &wp;

    const cfg = a.loaded.cfg;
    if (!cfg.wallpaper_enabled or cfg.wallpaper_image.len == 0) {
        logz.log("disabled or no image configured", .{});
        return 0;
    }
    wp.loadImage(cfg.wallpaper_image);
    if (wp.img == null) {
        logz.err("decode failed for '{s}'", .{cfg.wallpaper_image});
        return 1;
    }

    for (a.bound.outputs.items) |o| {
        if (o.width <= 0 or o.height <= 0) continue;
        var s = Surface{ .shm = shm_mod.ShmBuffer.init(gpa), .w = o.width, .h = o.height };
        if (!s.layer.create(a.bound.compositor, a.bound.layer_shell, o.obj, .background, ns.wallpaper)) continue;
        s.layer.setAnchor(layer.Anchor.top | layer.Anchor.bottom | layer.Anchor.left | layer.Anchor.right);
        s.layer.setExclusiveZone(-1);
        s.layer.setSize(@intCast(o.width), @intCast(o.height));
        s.layer.commit();
        var ticks: u32 = 0;
        while (ticks < 100 and !s.layer.configured) : (ticks += 1) {
            if (!a.conn.roundtrip()) break;
        }
        if (!s.layer.configured) {
            s.layer.destroy();
            s.shm.deinit();
            continue;
        }
        if (!s.shm.ensure(a.bound.shm, "wallpaper", o.width, o.height)) {
            s.layer.destroy();
            s.shm.deinit();
            continue;
        }
        wp.surfaces.append(gpa, s) catch {
            s.layer.destroy();
            s.shm.deinit();
            break;
        };
    }

    if (wp.surfaces.items.len == 0) {
        logz.err("no outputs painted", .{});
        return 1;
    }
    wp.paintAll();

    // inotify is not recursive: `<settings>` alone never reports edits to the
    // component file underneath it, so watch that directory too. The path is
    // only read for the duration of `startWatching` (the watcher keeps the fd,
    // not the string), so the temporary can go straight after.
    if (config.componentDir(gpa, a.xdg_config, a.home, "wallpaper")) |dir| {
        defer gpa.free(dir);
        a.startWatching(&.{dir});
    } else |_| {}

    a.run();
    return 0;
}
