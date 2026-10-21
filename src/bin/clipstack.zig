//! `horizon-clipstack` — the ClipStack daemon.
//!
//! Three jobs, one connection:
//!
//!  * **History.** Watch the clipboard selection through data-control
//!    (ext-first, wlr fallback — `clipboard_daemon.chooseBackend`), capture
//!    every new foreign selection (see `clipstack/capture.zig` for the mime
//!    policy and `clipstack/store.zig` for the on-disk format), and append
//!    it to the store. Password-manager selections are never recorded.
//!
//!  * **Ownership.** Immediately after capturing, re-publish the captured
//!    bytes as our own selection (`Service.copyDataMulti`), so the clipboard
//!    survives the source application exiting. That is also what powers
//!    "restore history after logout": on startup the newest entry is
//!    re-published unless a live selection already exists.
//!
//!  * **Tools.** `--wipe`, `--list` and `--export <id> <path>` operate on
//!    the store without touching Wayland; the picker and scripts use them.
//!
//! Pure Zig, no helper binaries: everything above is Wayland data-control
//! plus a plain directory of files. Listed in the supervisor table as an
//! always-on component — history only exists if somebody is watching. Run
//! mode takes an exclusive `flock` on the store (`.lock`) so a stray second
//! instance exits instead of ping-ponging re-publishes with the first.

const std = @import("std");
const linux = std.os.linux;
const eh = @import("eh");
const wl = eh.wl_c.wl;
const clip = eh.clipboard;
const capture = eh.clipstack_capture;
const store_mod = eh.clipstack_store;
const logz = eh.logz;

pub const usage =
    \\usage: horizon-clipstack [--wipe | --list | --export <id> <path> | --read [-|path]]
    \\
    \\  (no arguments)            run the history daemon
    \\  --wipe                    delete every stored entry
    \\  --list                    print "id kind bytes age preview" per entry
    \\  --export <id> <path>      write one entry's payload to a file
    \\  --read [-|path]           write the live selection's payload to a file
    \\                            ("-" prints text to stdout); --mime <m> picks
    \\                            a specific offered mime instead of the best
    \\
;

fn wallMs() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    svc: *clip.Service,
    conn: *eh.wl_conn.Connection,
    initial_done: bool = false,
};

/// Pump handed to `Service.receiveCapped`: the compositor only writes the
/// offer into the pipe while its own event queue is being drained.
fn pumpRoundtrip(ctx: *anyopaque) void {
    const c: *Ctx = @ptrCast(@alignCast(ctx));
    _ = c.conn.roundtrip();
}

fn captureNow(c: *Ctx) void {
    const mimes = c.svc.currentMimes(false);
    if (mimes.len == 0) return;

    var chosen: [capture.max_mimes][]const u8 = undefined;
    var n = capture.selectMimes(mimes, &chosen);
    if (n == 0) {
        // Nothing in the priority list: hold onto the selection with its
        // preferred (or first) mime so the clipboard still survives the
        // source exiting — just without a useful classification.
        if (clip.preferredMime(mimes)) |m| {
            chosen[0] = m;
            n = 1;
        }
    }
    if (n == 0) {
        logz.log("clipstack: selection offers no mime we can hold", .{});
        return;
    }

    const secret = capture.isSecret(mimes);
    var payloads: std.ArrayList(store_mod.Payload) = .empty;
    defer {
        for (payloads.items) |p| {
            c.gpa.free(@constCast(p.mime));
            c.gpa.free(@constCast(p.data));
        }
        payloads.deinit(c.gpa);
    }
    var items: std.ArrayList(clip.Service.DataItem) = .empty;
    defer items.deinit(c.gpa);

    var total: usize = 0;
    for (chosen[0..n]) |mime| {
        // 400ms stall budget per mime: the daemon's event loop is blocked
        // for the whole capture, and owned-selection pastes queue behind it.
        // 6 mimes × 400ms bounds the busy window at ~2.4s worst case
        // instead of 30s; a wedged source loses the mime, not the session.
        const data = c.svc.receiveCapped(mime, false, 400, capture.capture_ceiling, pumpRoundtrip, c) orelse continue;
        if (data.len == 0) {
            c.gpa.free(data);
            continue;
        }
        const mime_copy = c.gpa.dupe(u8, mime) catch {
            c.gpa.free(data);
            continue;
        };
        payloads.append(c.gpa, .{ .mime = mime_copy, .data = data }) catch {
            c.gpa.free(mime_copy);
            c.gpa.free(data);
            continue;
        };
        items.append(c.gpa, .{ .mime = mime_copy, .data = data }) catch {};
        total += data.len;
    }
    if (items.items.len == 0) {
        logz.log("clipstack: selection had no readable payload; not captured", .{});
        return;
    }

    var mime_slices: [capture.max_mimes][]const u8 = undefined;
    for (payloads.items, 0..) |p, i| mime_slices[i] = p.mime;
    const kind = capture.kindFor(mime_slices[0..payloads.items.len]);

    if (secret) {
        logz.log("clipstack: password-manager selection held, not stored ({d} bytes)", .{total});
    } else {
        const digest = store_mod.digestPayloads(payloads.items);
        var duplicate = false;
        if (c.store.newestMeta(c.gpa) catch null) |newest| {
            var m = newest;
            duplicate = m.digest == digest;
            m.deinit(c.gpa);
        }
        if (duplicate) {
            logz.log("clipstack: duplicate of newest entry, not stored", .{});
            // Do not re-own here: the foreign source holds byte-identical
            // data and is healthy. Cancelling it only churns the selection
            // (observed live: hundreds of duplicates per second) and opens
            // a handover gap under every paste. New content still re-owns
            // below, which keeps the source-exit guarantee intact.
            return;
        } else {
            const inserted = c.store.insert(kind, wallMs(), payloads.items) catch |e| {
                logz.err("clipstack: store write failed: {s}", .{@errorName(e)});
                return;
            };
            if (inserted) |id| {
                c.store.prune(store_mod.limits.max_entries, store_mod.limits.total_bytes);
                logz.log("clipstack: captured id={d} kind={s} payloads={d} bytes={d}", .{
                    id, kind.tag(), payloads.items.len, total,
                });
            } else {
                logz.log("clipstack: entry too large for history ({d} bytes), owned only", .{total});
            }
        }
    }

    // Take over the selection with the bytes we just read: the source
    // application may exit the moment after this, and the clipboard must
    // not go with it.
    if (!c.svc.copyDataMulti(items.items)) {
        logz.log("clipstack: re-publish failed; selection left with its owner", .{});
    }
}

/// Restore-on-startup: with no live selection, re-publish the newest
/// history entry so a reboot (or daemon restart) does not lose the
/// clipboard.
fn adoptNewest(c: *Ctx) void {
    var meta = (c.store.newestMeta(c.gpa) catch null) orelse return;
    defer meta.deinit(c.gpa);
    var entry = c.store.load(c.gpa, meta.id) catch return;
    defer entry.deinit(c.gpa);
    if (entry.payloads.len == 0) return;

    var items: [store_mod.max_payloads]clip.Service.DataItem = undefined;
    const n = @min(entry.payloads.len, items.len);
    for (entry.payloads[0..n], 0..) |p, i| {
        items[i] = .{ .mime = p.mime, .data = p.data };
    }
    if (c.svc.copyDataMulti(items[0..n])) {
        logz.log("clipstack: re-published history id={d} kind={s}", .{ meta.id, meta.kind.tag() });
    }
}

/// One decision point: a foreign selection to capture, or the startup
/// adoption. Our own selection is the steady state.
fn pump(c: *Ctx) void {
    if (c.svc.ownsSelection()) {
        c.initial_done = true;
        return;
    }
    if (c.svc.currentMimes(false).len > 0) {
        c.initial_done = true;
        captureNow(c);
        return;
    }
    if (!c.initial_done) {
        c.initial_done = true;
        adoptNewest(c);
    }
}

fn printMetas(io: std.Io, store: *store_mod.Store, gpa: std.mem.Allocator) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout = stdout_file.writer(io, &stdout_buf);
    const metas = try store.list(gpa);
    defer store_mod.freeMetas(gpa, metas);
    for (metas) |m| {
        const age_s = @max(0, @divTrunc(wallMs() - m.captured_ms, 1000));
        try stdout.interface.print("{d}\t{s}\t{d}\t{d}\t{s}\n", .{
            m.id, m.kind.tag(), m.size, age_s, m.preview,
        });
    }
    stdout.interface.flush() catch {};
}

fn exportEntry(io: std.Io, store: *store_mod.Store, gpa: std.mem.Allocator, id: u64, path: []const u8) !void {
    var entry = try store.load(gpa, id);
    defer entry.deinit(gpa);
    const payload = entry.dataFor(capture.mime_png) orelse blk: {
        const best = entry.largest() orelse return error.NoPayload;
        break :blk best.data;
    };
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, path, .{});
    var wbuf: [64 * 1024]u8 = undefined;
    var wr = file.writer(io, &wbuf);
    wr.interface.writeAll(payload) catch {
        file.close(io);
        return error.WriteFailed;
    };
    wr.end() catch {
        file.close(io);
        return error.WriteFailed;
    };
    file.close(io);
}

/// `--read`: dump the live selection via a throwaway data-control device.
/// Scriptable counterpart to the picker — useful for smoke tests and for
/// pulling a selection into a script without any clipboard utility.
fn readSelection(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    target: []const u8,
    want_mime: ?[]const u8,
) !void {
    var conn = eh.wl_conn.Connection.init(gpa);
    defer conn.deinit();
    if (!conn.connect(null)) return error.NoWayland;
    var bound = eh.wl_conn.Connection.Bound{};
    defer conn.freeBound(&bound);
    conn.bindAll(&bound);
    const display = conn.display orelse return error.NoWayland;
    const choice = eh.clipboard_daemon.chooseBackend(&bound) orelse return error.NoDataControl;
    const seat = bound.seat orelse return error.NoSeat;

    var svc = clip.Service.init(gpa);
    defer svc.deinit();
    if (!svc.bind(choice.manager, choice.backend, seat, display)) return error.BindFailed;
    _ = conn.flush();
    _ = conn.roundtrip();
    _ = conn.roundtrip();

    const mimes = svc.currentMimes(false);
    if (mimes.len == 0) return error.EmptySelection;
    const chosen: []const u8 = if (want_mime) |w| blk: {
        if (!capture.offered(mimes, w)) return error.MimeNotOffered;
        break :blk w;
    } else clip.preferredMime(mimes) orelse mimes[0];

    var ctx = Ctx{ .gpa = gpa, .store = store, .svc = &svc, .conn = &conn };
    const data = svc.receiveCapped(chosen, false, 5000, capture.capture_ceiling, pumpRoundtrip, &ctx) orelse
        return error.ReceiveFailed;
    defer gpa.free(data);

    if (std.mem.eql(u8, target, "-")) {
        var stdout_buf: [4096]u8 = undefined;
        var stdout_file = std.Io.File.stdout();
        var stdout = stdout_file.writer(io, &stdout_buf);
        try stdout.interface.writeAll(data);
        stdout.interface.flush() catch {};
        return;
    }
    const file = try std.Io.Dir.cwd().createFile(io, target, .{});
    var wbuf: [64 * 1024]u8 = undefined;
    var wr = file.writer(io, &wbuf);
    wr.interface.writeAll(data) catch {
        file.close(io);
        return error.WriteFailed;
    };
    wr.end() catch {
        file.close(io);
        return error.WriteFailed;
    };
    file.close(io);
    logz.log("clipstack: read {s} ({d} bytes) -> {s}", .{ chosen, data.len, target });
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    _ = eh.parent_guard.installGuard();
    logz.init(io, init.environ_map.get("HOME"), "horizon-clipstack-zig");
    defer logz.deinit();

    const args = init.minimal.args.toSlice(arena) catch &.{};
    const argv0: []const u8 = if (args.len > 0 and args[0].len > 0) args[0] else "horizon-clipstack";

    const dir = store_mod.defaultDir(arena, init.environ_map.get("XDG_DATA_HOME"), init.environ_map.get("HOME")) orelse {
        logz.err("clipstack: no store directory (HOME and XDG_DATA_HOME are both unset)", .{});
        return 1;
    };
    var store = store_mod.Store.open(io, gpa, dir) catch |e| {
        logz.err("clipstack: cannot open store {s}: {s}", .{ dir, @errorName(e) });
        return 1;
    };
    defer store.deinit();

    // Offline modes first: they never touch Wayland.
    var want_mime: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            var stdout_buf: [4096]u8 = undefined;
            var stdout_file = std.Io.File.stdout();
            var stdout = stdout_file.writer(io, &stdout_buf);
            try stdout.interface.print("{s}", .{usage});
            stdout.interface.flush() catch {};
            return 0;
        } else if (std.mem.eql(u8, a, "--wipe")) {
            const n = store.wipe();
            var stdout_buf: [256]u8 = undefined;
            var stdout_file = std.Io.File.stdout();
            var stdout = stdout_file.writer(io, &stdout_buf);
            try stdout.interface.print("wipe: {d} entries removed ({s})\n", .{ n, dir });
            stdout.interface.flush() catch {};
            logz.log("clipstack: wiped {d} entries", .{n});
            return 0;
        } else if (std.mem.eql(u8, a, "--list")) {
            printMetas(io, &store, gpa) catch |e| {
                logz.err("clipstack: list failed: {s}", .{@errorName(e)});
                return 1;
            };
            return 0;
        } else if (std.mem.eql(u8, a, "--export")) {
            if (i + 2 >= args.len) {
                logz.err("clipstack: --export needs <id> <path>", .{});
                return 2;
            }
            const id = std.fmt.parseInt(u64, args[i + 1], 10) catch {
                logz.err("clipstack: bad entry id '{s}'", .{args[i + 1]});
                return 2;
            };
            exportEntry(io, &store, gpa, id, args[i + 2]) catch |e| {
                logz.err("clipstack: export {d} failed: {s}", .{ id, @errorName(e) });
                return 1;
            };
            logz.log("clipstack: exported id={d} to {s}", .{ id, args[i + 2] });
            return 0;
        } else if (std.mem.eql(u8, a, "--mime")) {
            if (i + 1 >= args.len) {
                logz.err("clipstack: --mime needs an argument", .{});
                return 2;
            }
            want_mime = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--read")) {
            if (i + 1 >= args.len) {
                logz.err("clipstack: --read needs a target path or '-'", .{});
                return 2;
            }
            readSelection(io, gpa, &store, args[i + 1], want_mime) catch |e| {
                logz.err("clipstack: read failed: {s}", .{@errorName(e)});
                return 1;
            };
            return 0;
        } else {
            logz.err("clipstack: unknown argument '{s}'", .{a});
            logz.err("{s}", .{usage});
            return 2;
        }
    }
    _ = argv0;

    // Run mode: one watching daemon per store. A second instance would see
    // the first's re-publishes as foreign selections and ping-pong captures
    // (observed live: hundreds of duplicates per second), so the loser exits
    // before touching Wayland.
    const run_lock = store.tryRunLock() orelse {
        logz.err("clipstack: another horizon-clipstack already watches {s}", .{dir});
        return 0;
    };
    defer run_lock.close(io);

    var conn = eh.wl_conn.Connection.init(gpa);
    defer conn.deinit();
    if (!conn.connect(null)) {
        logz.err("clipstack: cannot connect to Wayland", .{});
        return 1;
    }
    var bound = eh.wl_conn.Connection.Bound{};
    defer conn.freeBound(&bound);
    conn.bindAll(&bound);
    const display = conn.display orelse {
        logz.err("clipstack: no display", .{});
        return 1;
    };
    const choice = eh.clipboard_daemon.chooseBackend(&bound) orelse {
        logz.err("clipstack: no data-control protocol available", .{});
        return 1;
    };
    const seat = bound.seat orelse {
        logz.err("clipstack: no wl_seat available", .{});
        return 1;
    };

    var svc = clip.Service.init(gpa);
    defer svc.deinit();
    if (!svc.bind(choice.manager, choice.backend, seat, display)) {
        logz.err("clipstack: data-control bind failed", .{});
        return 1;
    }

    var ctx = Ctx{ .gpa = gpa, .store = &store, .svc = &svc, .conn = &conn };
    _ = conn.flush();

    // Settle the initial selection state before deciding anything: two
    // roundtrips deliver the current offers, so the first pump sees the
    // real clipboard and not an empty intermediate state.
    _ = conn.roundtrip();
    _ = conn.roundtrip();
    logz.log("clipstack: running backend={s} store={s}", .{ @tagName(choice.backend), dir });
    pump(&ctx);

    while (true) {
        if (wl.wl_display_dispatch(display) < 0) break;
        pump(&ctx);
    }
    logz.log("clipstack: display closed; exiting", .{});
    return 0;
}
