const std = @import("std");
const eh = @import("eh");
const config = eh.config;
const wl_conn = eh.wl_conn;
const wl_loop = eh.loop;
const wl_pump = eh.wl_pump;
// Through `eh`: the bin module root is `src/bin`, so `../color/…` would be
// outside it (every other cross-directory import takes this route).
const palette_sync = eh.palette_sync;

/// inotify slots: settings dir (`~/.config/Event-Horizon`) plus up to six
/// component dirs the caller asks for (e.g. `<settings>/wallpaper`,
/// `<settings>/dock`). Watching a component dir is required because inotify
/// is not recursive.
const max_watchers = 8;

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    loaded: config.Loaded,
    conn: wl_conn.Connection,
    bound: wl_conn.Connection.Bound,
    loop: wl_loop.Loop,
    /// Owned copies of the ambient XDG paths, kept for reloads.
    xdg_config: ?[]const u8,
    home: ?[]const u8,
    watchers: [max_watchers]config.watch.Watcher = @as([max_watchers]config.watch.Watcher, @splat(.{})),
    nwatch: usize = 0,
    /// Invoked after `reload()` swaps `loaded` in. The callee must rebuild any
    /// cached view of the config — old slices point into the freed arena.
    on_reload: ?*const fn (*anyopaque) void = null,
    reload_ctx: ?*anyopaque = null,
    reloading: bool = false,
    /// The wallpaper-palette pass, run after every (re)load: refresh the
    /// palette into `loaded.cfg.appearance`, render the templates, sync the
    /// compositor's borders. Kept across reloads so the refresher's mem
    /// caches (and the template fingerprint) survive a config save.
    palette: palette_sync.Sync,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        xdg_config: ?[]const u8,
        home: ?[]const u8,
    ) !App {
        var loaded = try config.loadStacked(gpa, io, xdg_config, home);
        errdefer loaded.deinit();
        const cfg_copy = try dupOrNull(gpa, xdg_config);
        errdefer freeOrNull(gpa, cfg_copy);
        const home_copy = try dupOrNull(gpa, home);
        errdefer freeOrNull(gpa, home_copy);
        // Palette refresh runs inside the load, so the
        // config is never handed out with stale (stock) chrome colours.
        var palette = try palette_sync.Sync.init(gpa, io);
        errdefer palette.deinit();
        palette.run(&loaded.cfg);

        var conn = wl_conn.Connection.init(gpa);
        errdefer conn.deinit();
        if (!conn.connect(null)) return error.NoDisplay;
        var app = App{
            .gpa = gpa,
            .io = io,
            .loaded = loaded,
            .conn = conn,
            .bound = .{},
            .loop = try wl_loop.Loop.init(gpa),
            .xdg_config = cfg_copy,
            .home = home_copy,
            .palette = palette,
        };
        // `conn`/`loaded` are owned by their own errdefers above, so only the
        // pieces allocated after this point need unwinding here.
        errdefer app.conn.freeBound(&app.bound);
        errdefer app.loop.deinit();
        app.conn.bindAll(&app.bound);
        if (!app.conn.roundtrip()) return error.NoDisplay;
        try app.loop.watchFd(
            app.conn.displayFd(),
            std.posix.POLL.IN,
            wl_pump.displayCallback,
            @ptrCast(app.conn.display.?),
        );
        return app;
    }

    /// Must be called while `self` sits at its final address — the inotify
    /// callbacks are given `self` as their context pointer.
    pub fn startWatching(self: *App, extra_dirs: []const []const u8) void {
        const settings = config.settingsDir(self.gpa, self.xdg_config, self.home) catch return;
        defer self.gpa.free(settings);

        self.addWatch(settings);
        for (extra_dirs) |d| {
            if (std.mem.eql(u8, d, settings)) continue;
            self.addWatch(d);
        }
    }

    fn addWatch(self: *App, dir: []const u8) void {
        if (self.nwatch >= self.watchers.len) return;
        const w = &self.watchers[self.nwatch];
        if (!w.watchConfigDir(dir)) return;
        self.loop.watchFd(w.pollFd(), std.posix.POLL.IN, onConfigFd, @ptrCast(self)) catch {
            w.close();
            return;
        };
        self.nwatch += 1;
    }

    /// Re-reads the layered config. Returns false when the reload failed, in
    /// which case the previous config is still live.
    pub fn reload(self: *App) bool {
        if (self.reloading) return false;
        self.reloading = true;
        defer self.reloading = false;
        const fresh = config.loadStacked(
            self.gpa,
            self.io,
            self.xdg_config,
            self.home,
        ) catch |err| {
            eh.diag.log("reload: FAILED {s}", .{@errorName(err)});
            return false;
        };
        self.loaded.deinit();
        self.loaded = fresh;
        // Same position `init` gives it: the palette lands on the config
        // before `on_reload` rebuilds any cached view of it, so no caller
        // ever sees a config whose chrome colours are still stock. The
        // fingerprint inside `run` is also what stops the template renders
        // from tripping this very watcher — a second pass over unchanged
        // inputs writes nothing, so the reload loop closes.
        self.palette.run(&self.loaded.cfg);
        eh.diag.log(
            "reload: ok opacity={d} show_dock={} radius={d} icon_size={d} liquid_glass={} colored_glass={}",
            .{
                self.loaded.cfg.dock.dock_opacity,
                self.loaded.cfg.dock.dock_show_dock,
                self.loaded.cfg.dock.dock_radius,
                self.loaded.cfg.dock.dock_icon_size,
                self.loaded.cfg.dock.dock_liquid_glass,
                self.loaded.cfg.dock.dock_colored_glass,
            },
        );
        if (self.on_reload) |cb| {
            if (self.reload_ctx) |ctx| cb(ctx);
        }
        return true;
    }

    pub fn deinit(self: *App) void {
        for (self.watchers[0..self.nwatch]) |*w| w.close();
        self.nwatch = 0;
        self.conn.freeBound(&self.bound);
        self.loop.deinit();
        self.conn.deinit();
        self.loaded.deinit();
        self.palette.deinit();
        freeOrNull(self.gpa, self.xdg_config);
        freeOrNull(self.gpa, self.home);
    }

    pub fn run(self: *App) void {
        wl_loop.Loop.installSignalHandlers();
        self.loop.run();
    }
};

fn dupOrNull(gpa: std.mem.Allocator, v: ?[]const u8) !?[]const u8 {
    if (v) |s| return try gpa.dupe(u8, s);
    return null;
}

fn freeOrNull(gpa: std.mem.Allocator, v: ?[]const u8) void {
    if (v) |s| gpa.free(s);
}

fn onConfigFd(fd: i32, revents: i16, ctx: *anyopaque) void {
    _ = revents;
    const self: *App = @ptrCast(@alignCast(ctx));
    var hit = false;
    for (self.watchers[0..self.nwatch]) |*w| {
        if (w.pollFd() == fd and w.drainAnyLive(&config.watch.live_extra_names)) hit = true;
    }
    if (hit) {
        eh.diag.log("watch: fd={d} drained a config change -> reload (nwatch={d})", .{ fd, self.nwatch });
        const ok = self.reload();
        eh.diag.log("watch: reload returned ok={}", .{ok});
    } else {
        eh.diag.log("watch: fd={d} drained, no config name in it", .{fd});
    }
}
