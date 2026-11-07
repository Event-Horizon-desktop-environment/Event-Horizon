//! Workspace snapshot for the overview and the strip widget.
//!
//! Two sources produce the same owned shape. On Hyprland, three IPC
//! documents — `j/workspaces`, `j/clients`, `j/monitors` — become workspaces
//! with monitor geometry plus their windows. On Zoolander, `clients-json`,
//! `monitors-json` and one Lua `eval` are read through the control socket.
//! Special workspaces and unmapped clients are skipped. `applyMaxSlots`
//! pads/truncates to the widget's `max_workspaces` the way the strip does,
//! keeping real workspaces past the cap when they hold windows or focus;
//! name-keyed Zoolander sessions are left alone because they have no dense
//! numeric range to fill. Workspace jumps and window moves/swaps dispatch
//! through the same detection: Hyprland commands, or Zoolander Lua `eval`
//! with windows re-found by app id, title and workspace since the control
//! socket's window id is not the Lua address.

const std = @import("std");
const linux = std.os.linux;
const sock = @import("../../sock.zig");
const compositor = @import("../../backends/compositor.zig");
const desk = @import("../../backends/desk.zig");
const hypr_ipc = @import("../../backends/hyprland_ipc.zig");

pub const Window = struct {
    addr: []const u8 = "",
    app_id: []const u8 = "",
    title: []const u8 = "",
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    nx: f64 = 0,
    ny: f64 = 0,
    nw: f64 = 0,
    nh: f64 = 0,
    floating: bool = false,
    focused: bool = false,
    monitor: i32 = -1,
    ws_id: i32 = -1,
    /// Fully outside its monitor (beyond a 5% margin): the compositor
    /// will not copy it until it is parked on-monitor, which is the
    /// reveal pass's job.
    overflow: bool = false,
};

/// The subset of `Window` a compositor action needs; the overview's cards
/// carry the same fields in `host.Win`.
pub const WindowRef = struct {
    addr: []const u8 = "",
    app_id: []const u8 = "",
    title: []const u8 = "",
};

pub const Workspace = struct {
    id: i32 = 0,
    label: []const u8 = "",
    /// The name the compositor expects for activation. Empty means the
    /// numeric `id` is the target (Hyprland, and Zoolander's numeric names).
    target: []const u8 = "",
    monitor: []const u8 = "",
    mon_x: f64 = 0,
    mon_y: f64 = 0,
    mon_w: f64 = 0,
    mon_h: f64 = 0,
    active: bool = false,
    occupied: bool = false,
    wins: []Window = &.{},
};

pub const Snapshot = struct {
    alloc: std.mem.Allocator,
    ws: []Workspace = &.{},
    /// Workspace names are not a dense `1..N` numeric range, so
    /// `applyMaxSlots` must not manufacture numeric placeholders.
    named: bool = false,

    pub fn deinit(self: *Snapshot) void {
        for (self.ws) |*w| {
            self.alloc.free(w.label);
            self.alloc.free(w.target);
            self.alloc.free(w.monitor);
            for (w.wins) |*win| {
                self.alloc.free(win.addr);
                self.alloc.free(win.app_id);
                self.alloc.free(win.title);
            }
            self.alloc.free(w.wins);
        }
        self.alloc.free(self.ws);
        self.ws = &.{};
    }
};

fn jsonNum(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0.0,
    };
}

fn numKey(o: std.json.Value, key: []const u8) f64 {
    if (o != .object) return 0.0;
    const v = o.object.get(key) orelse return 0.0;
    return jsonNum(v);
}

fn pair(o: std.json.Value, key: []const u8) [2]f64 {
    const arr = desk.jsonArr(o, key) orelse return .{ 0, 0 };
    if (arr.items.len < 2) return .{ 0, 0 };
    return .{ jsonNum(arr.items[0]), jsonNum(arr.items[1]) };
}

const RawWs = struct { id: i32, label: []const u8, monitor: []const u8, active: bool, occupied: bool };
const RawMon = struct { id: i32, x: f64, y: f64, w: f64, h: f64 };

fn parseWsList(alloc: std.mem.Allocator, text: []const u8) ![]RawWs {
    var parsed = hypr_ipc.parseReply(alloc, "j/workspaces", text) orelse return error.BadJson;
    defer parsed.deinit();
    const arr = if (parsed.value == .array) parsed.value.array else return error.BadJson;
    var out: std.ArrayList(RawWs) = .empty;
    errdefer {
        for (out.items) |r| {
            alloc.free(r.label);
            alloc.free(r.monitor);
        }
        out.deinit(alloc);
    }
    for (arr.items) |item| {
        if (item != .object) continue;
        const id = desk.jsonInt(item, "id", i32, -1);
        if (id <= 0) continue;
        const name = desk.jsonStr(item, "name");
        var num: [16]u8 = undefined;
        const label = if (name.len > 0) name else std.fmt.bufPrint(&num, "{d}", .{id}) catch "?";
        const mon = desk.jsonStr(item, "monitor");
        try out.append(alloc, .{
            .id = id,
            .label = try alloc.dupe(u8, label),
            .monitor = try alloc.dupe(u8, mon),
            .active = desk.jsonBoolOr(item, "focused", false) or desk.jsonBoolOr(item, "visible", false),
            .occupied = desk.jsonInt(item, "windows", i32, 0) > 0,
        });
    }
    return out.toOwnedSlice(alloc);
}

fn parseMonList(alloc: std.mem.Allocator, text: []const u8) ![]RawMon {
    var parsed = hypr_ipc.parseReply(alloc, "j/monitors", text) orelse return error.BadJson;
    defer parsed.deinit();
    const arr = if (parsed.value == .array) parsed.value.array else return error.BadJson;
    var out: std.ArrayList(RawMon) = .empty;
    errdefer out.deinit(alloc);
    for (arr.items) |item| {
        if (item != .object) continue;
        const w = numKey(item, "width");
        const h = numKey(item, "height");
        if (w <= 0.0 or h <= 0.0) continue;
        try out.append(alloc, .{
            .id = desk.jsonInt(item, "id", i32, -1),
            .x = numKey(item, "x"),
            .y = numKey(item, "y"),
            .w = w,
            .h = h,
        });
    }
    return out.toOwnedSlice(alloc);
}

fn parseWinList(alloc: std.mem.Allocator, text: []const u8) ![]Window {
    var parsed = hypr_ipc.parseReply(alloc, "j/clients", text) orelse return error.BadJson;
    defer parsed.deinit();
    const arr = if (parsed.value == .array) parsed.value.array else return error.BadJson;
    var out: std.ArrayList(Window) = .empty;
    errdefer {
        for (out.items) |*w| {
            alloc.free(w.addr);
            alloc.free(w.app_id);
            alloc.free(w.title);
        }
        out.deinit(alloc);
    }
    for (arr.items) |item| {
        if (item != .object) continue;
        if (!desk.jsonBoolOr(item, "mapped", true)) continue;
        var ws_id: i32 = -1;
        if (desk.jsonObj(item, "workspace")) |ws| ws_id = desk.jsonInt(ws, "id", i32, -1);
        if (ws_id <= 0) continue;
        var app = desk.jsonStr(item, "class");
        if (app.len == 0) app = desk.jsonStr(item, "initialClass");
        const at = pair(item, "at");
        const sz = pair(item, "size");
        var focused = false;
        if (item.object.get("focusHistoryID")) |fh| {
            if (fh == .integer and fh.integer == 0) focused = true;
        }
        try out.append(alloc, .{
            .addr = try alloc.dupe(u8, desk.jsonStr(item, "address")),
            .app_id = try alloc.dupe(u8, app),
            .title = try alloc.dupe(u8, desk.jsonStr(item, "title")),
            .x = at[0],
            .y = at[1],
            .w = sz[0],
            .h = sz[1],
            .floating = desk.jsonBoolOr(item, "floating", false),
            .focused = focused,
            .monitor = desk.jsonInt(item, "monitor", i32, -1),
            .ws_id = ws_id,
        });
    }
    return out.toOwnedSlice(alloc);
}

fn clamp01(v: f64) f64 {
    return @min(1.0, @max(0.0, v));
}

/// True when the window box sits fully outside its monitor beyond a 5%
/// margin — the compositor will not copy it until it is parked
/// on-monitor, which is the reveal pass's job.
fn outsideMonitor(wx: f64, wy: f64, ww: f64, wh: f64, mx: f64, my: f64, mw: f64, mh: f64) bool {
    if (ww <= 0.0 or wh <= 0.0 or mw <= 0.0 or mh <= 0.0) return false;
    const padx = mw * 0.05;
    const pady = mh * 0.05;
    return wx + ww < mx - padx or wx > mx + mw + padx or wy + wh < my - pady or wy > my + mh + pady;
}

/// Assemble parsed documents into an owned snapshot, normalizing window
/// geometry against the monitor and attaching monitor geometry to the
/// workspace that names it (by monitor id when the client set one).
pub fn assemble(alloc: std.mem.Allocator, ws_text: []const u8, mon_text: []const u8, cl_text: []const u8) !Snapshot {
    const raws = try parseWsList(alloc, ws_text);
    defer {
        for (raws) |r| {
            alloc.free(r.label);
            alloc.free(r.monitor);
        }
        alloc.free(raws);
    }
    const mons = try parseMonList(alloc, mon_text);
    defer alloc.free(mons);
    const wins = try parseWinList(alloc, cl_text);
    defer {
        for (wins) |w| {
            alloc.free(w.addr);
            alloc.free(w.app_id);
            alloc.free(w.title);
        }
        alloc.free(wins);
    }

    var out: std.ArrayList(Workspace) = .empty;
    errdefer {
        for (out.items) |*w| {
            alloc.free(w.label);
            alloc.free(w.target);
            alloc.free(w.monitor);
            for (w.wins) |*win| {
                alloc.free(win.addr);
                alloc.free(win.app_id);
                alloc.free(win.title);
            }
            alloc.free(w.wins);
        }
        out.deinit(alloc);
    }
    for (raws) |r| {
        var list: std.ArrayList(Window) = .empty;
        errdefer {
            for (list.items) |*w| {
                alloc.free(w.addr);
                alloc.free(w.app_id);
                alloc.free(w.title);
            }
            list.deinit(alloc);
        }
        for (wins) |w| {
            if (w.ws_id != r.id) continue;
            var c = Window{
                .addr = try alloc.dupe(u8, w.addr),
                .app_id = try alloc.dupe(u8, w.app_id),
                .title = try alloc.dupe(u8, w.title),
                .x = w.x,
                .y = w.y,
                .w = w.w,
                .h = w.h,
                .floating = w.floating,
                .focused = w.focused,
                .monitor = w.monitor,
                .ws_id = w.ws_id,
            };
            for (mons) |m| {
                if (m.id != w.monitor) continue;
                if (w.w > 0.0 and w.h > 0.0) {
                    c.nw = std.math.clamp(w.w / m.w, 0.0, 1.0);
                    c.nh = std.math.clamp(w.h / m.h, 0.0, 1.0);
                    c.nx = clamp01((w.x - m.x) / m.w);
                    c.ny = clamp01((w.y - m.y) / m.h);
                }
                c.overflow = outsideMonitor(w.x, w.y, w.w, w.h, m.x, m.y, m.w, m.h);
                break;
            }
            try list.append(alloc, c);
        }
        var ws = Workspace{
            .id = r.id,
            .label = try alloc.dupe(u8, r.label),
            .monitor = try alloc.dupe(u8, r.monitor),
            .active = r.active,
            .occupied = r.occupied or list.items.len > 0,
            .wins = try list.toOwnedSlice(alloc),
        };
        for (mons) |m| {
            if (ws.wins.len > 0 and m.id == ws.wins[0].monitor) {
                ws.mon_x = m.x;
                ws.mon_y = m.y;
                ws.mon_w = m.w;
                ws.mon_h = m.h;
                break;
            }
        }
        try out.append(alloc, ws);
    }
    return .{ .alloc = alloc, .ws = try out.toOwnedSlice(alloc) };
}

/// Sort by id, then walk `1..max` keeping matches and manufacturing
/// placeholders — except real workspaces past the cap survive when they
/// hold windows or focus. Non-positive `max` disables the fill.
pub fn applyMaxSlots(alloc: std.mem.Allocator, snap: *Snapshot, max: i32) !void {
    if (max <= 0) return;
    // A name-keyed session has no dense numeric range: IDs were assigned in
    // discovery order and manufacturing `1..max` placeholders would add
    // workspaces the compositor does not have.
    if (snap.named) return;
    std.mem.sort(Workspace, snap.ws, {}, struct {
        fn lt(_: void, a: Workspace, b: Workspace) bool {
            return a.id < b.id;
        }
    }.lt);
    var last: i32 = max;
    for (snap.ws) |w| {
        if ((w.wins.len > 0 or w.active) and w.id > last) last = w.id;
    }
    var out: std.ArrayList(Workspace) = .empty;
    errdefer out.deinit(alloc);
    var idx: usize = 0;
    var id: i32 = 1;
    while (id <= last) : (id += 1) {
        if (idx < snap.ws.len and snap.ws[idx].id == id) {
            try out.append(alloc, snap.ws[idx]);
            idx += 1;
        } else {
            var num: [16]u8 = undefined;
            const label = std.fmt.bufPrint(&num, "{d}", .{id}) catch "?";
            try out.append(alloc, .{ .id = id, .label = try alloc.dupe(u8, label) });
        }
    }
    // Entries past the cap stay where the sort put them, in order.
    while (idx < snap.ws.len) : (idx += 1) {
        try out.append(alloc, snap.ws[idx]);
    }
    alloc.free(snap.ws);
    snap.ws = try out.toOwnedSlice(alloc);
}

/// One Hyprland round trip per document. Null when the socket is missing or
/// a document is unusable — the caller keeps its old snapshot.
pub fn fetch(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) ?Snapshot {
    const ws_text = hypr_ipc.ipcRequest(alloc, io, env, "j/workspaces") orelse return null;
    defer alloc.free(ws_text);
    const mon_text = hypr_ipc.ipcRequest(alloc, io, env, "j/monitors") orelse return null;
    defer alloc.free(mon_text);
    const cl_text = hypr_ipc.ipcRequest(alloc, io, env, "j/clients") orelse return null;
    defer alloc.free(cl_text);
    return assemble(alloc, ws_text, mon_text, cl_text) catch null;
}

/// Fire-and-forget compositor command (`dispatch …`). Answers the reply so
/// callers can check for the `ok` prefix.
pub fn send(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    command: []const u8,
) ?[]u8 {
    return hypr_ipc.ipcRequest(alloc, io, env, command);
}

// -- Zoolander control socket ------------------------------------------------

const ZMon = struct {
    name: []const u8,
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
};

const RawZWin = struct {
    id: []const u8 = "",
    app_id: []const u8 = "",
    title: []const u8 = "",
    ws: []const u8 = "",
    output: []const u8 = "",
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    floating: bool = false,
    focused: bool = false,
};

const ActiveWs = struct { output: []const u8, ws: []const u8 };

/// One Lua chunk asked for each output's active workspace. `eval` returns the
/// chunk's first result, so the chunk joins the pairs itself. The control
/// protocol replaces newlines in replies, and workspace names may contain any
/// other byte, so the pairs use the ASCII record/unit separators rather than
/// punctuation a name could plausibly hold.
const kActiveWorkspacesLua =
    "return (function() local o={} for i=0,zl.monitor_count()-1 do local m=zl.monitor_info(i) if m and m.active_workspace then o[#o+1]=m.name..\"\\30\"..m.active_workspace.name end end return table.concat(o,\"\\31\") end)()";

const kPairSep = 0x1f;
const kFieldSep = 0x1e;

/// One control-socket round trip. The server greets with `ZLCTL 1` and then
/// answers each newline-terminated command with an `OK`/`ERR` status line,
/// followed (for the query commands) by the report. The reply is read to EOF
/// and the greeting line dropped, so callers see the status line first. Null
/// when the socket is absent or the exchange fails.
fn zCtl(
    alloc: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    command: []const u8,
) ?[]u8 {
    var path_buf: [256]u8 = undefined;
    const path = compositor.zoolanderControlPath(&path_buf, env) orelse return null;
    const line = std.fmt.allocPrint(alloc, "{s}\n", .{command}) catch return null;
    defer alloc.free(line);
    const raw = hypr_ipc.requestOnce(alloc, path, line) orelse return null;
    defer alloc.free(raw);
    const nl = std.mem.indexOfScalar(u8, raw, '\n') orelse return null;
    return alloc.dupe(u8, raw[nl + 1 ..]) catch null;
}

fn replyBody(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.eql(u8, t, "OK")) return "";
    if (std.mem.startsWith(u8, t, "OK ")) return t[3..];
    return t;
}

fn findMon(mons: []const ZMon, name: []const u8) ?usize {
    if (name.len == 0) return null;
    for (mons, 0..) |m, i| {
        if (std.mem.eql(u8, m.name, name)) return i;
    }
    return null;
}

fn parsePositiveId(name: []const u8) ?i32 {
    const v = std.fmt.parseInt(i32, name, 10) catch return null;
    return if (v > 0) v else null;
}

fn idUsed(ids: []const i32, id: i32) bool {
    for (ids) |x| if (x == id) return true;
    return false;
}

/// Parse the `outputs` array of `monitors-json`; only enabled outputs carry
/// usable geometry.
fn parseZMons(doc: std.json.Value, out: *std.ArrayList(ZMon), alloc: std.mem.Allocator) !void {
    if (doc != .object) return error.BadJson;
    const arr_v = doc.object.get("outputs") orelse return error.BadJson;
    if (arr_v != .array) return error.BadJson;
    for (arr_v.array.items) |item| {
        if (item != .object) continue;
        if (!desk.jsonBoolOr(item, "enabled", false)) continue;
        const w = numKey(item, "logical_width");
        const h = numKey(item, "logical_height");
        if (w <= 0.0 or h <= 0.0) continue;
        const name = desk.jsonStr(item, "name");
        if (name.len == 0) continue;
        try out.append(alloc, .{
            .name = name,
            .x = numKey(item, "x"),
            .y = numKey(item, "y"),
            .w = w,
            .h = h,
        });
    }
}

/// Build the same owned snapshot from Zoolander's three control replies.
/// Workspace names come from the active-workspace eval and from every
/// non-special client. Empty named workspaces only appear once the
/// compositor makes them active; numeric sessions still get the usual
/// `max_workspaces` gap fill.
pub fn assembleZoolander(
    alloc: std.mem.Allocator,
    clients_text: []const u8,
    monitors_text: []const u8,
    active_text: []const u8,
) !Snapshot {
    const cstart = std.mem.indexOfScalar(u8, clients_text, '[') orelse return error.BadJson;
    var cparsed = try std.json.parseFromSlice(std.json.Value, alloc, clients_text[cstart..], .{});
    defer cparsed.deinit();
    const mstart = std.mem.indexOfScalar(u8, monitors_text, '{') orelse return error.BadJson;
    var mparsed = try std.json.parseFromSlice(std.json.Value, alloc, monitors_text[mstart..], .{});
    defer mparsed.deinit();

    var mons: std.ArrayList(ZMon) = .empty;
    defer mons.deinit(alloc);
    try parseZMons(mparsed.value, &mons, alloc);

    var active: std.ArrayList(ActiveWs) = .empty;
    defer active.deinit(alloc);
    var ait = std.mem.splitScalar(u8, active_text, kPairSep);
    while (ait.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, kFieldSep) orelse continue;
        const o = std.mem.trim(u8, entry[0..eq], " \t\r\n");
        const w = std.mem.trim(u8, entry[eq + 1 ..], " \t\r\n");
        if (o.len == 0 or w.len == 0) continue;
        try active.append(alloc, .{ .output = o, .ws = w });
    }

    const WsMeta = struct { active: bool = false, occupied: bool = false, monitor: []const u8 = "" };
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    var metas: std.ArrayList(WsMeta) = .empty;
    defer metas.deinit(alloc);
    var index = std.StringHashMap(usize).init(alloc);
    defer index.deinit();

    // Active workspaces first so an empty active card keeps its output.
    for (active.items) |a| {
        const gop = try index.getOrPut(a.ws);
        if (!gop.found_existing) {
            gop.value_ptr.* = names.items.len;
            try names.append(alloc, a.ws);
            try metas.append(alloc, .{});
        }
        const m = &metas.items[gop.value_ptr.*];
        m.active = true;
        if (m.monitor.len == 0) m.monitor = a.output;
    }

    var wins: std.ArrayList(RawZWin) = .empty;
    defer wins.deinit(alloc);
    const carr = if (cparsed.value == .array) cparsed.value.array else return error.BadJson;
    for (carr.items) |item| {
        if (item != .object) continue;
        if (desk.jsonBoolOr(item, "special", false)) continue;
        const ws = desk.jsonStr(item, "workspace");
        if (ws.len == 0) continue;
        const output = desk.jsonStr(item, "output");
        const gop = try index.getOrPut(ws);
        if (!gop.found_existing) {
            gop.value_ptr.* = names.items.len;
            try names.append(alloc, ws);
            try metas.append(alloc, .{});
        }
        const m = &metas.items[gop.value_ptr.*];
        m.occupied = true;
        if (m.monitor.len == 0) m.monitor = output;
        var app = desk.jsonStr(item, "app_id");
        if (app.len == 0) app = desk.jsonStr(item, "class");
        if (app.len == 0) app = desk.jsonStr(item, "instance");
        try wins.append(alloc, .{
            .id = desk.jsonStr(item, "id"),
            .app_id = app,
            .title = desk.jsonStr(item, "title"),
            .ws = ws,
            .output = output,
            .x = numKey(item, "x"),
            .y = numKey(item, "y"),
            .w = numKey(item, "width"),
            .h = numKey(item, "height"),
            .floating = desk.jsonBoolOr(item, "floating", false),
            .focused = desk.jsonBoolOr(item, "focused", false),
        });
    }

    if (names.items.len == 0) return .{ .alloc = alloc };

    var ids: std.ArrayList(i32) = .empty;
    defer ids.deinit(alloc);
    var named = false;
    var next_id: i32 = 1;
    for (names.items) |n| {
        if (parsePositiveId(n)) |id| {
            if (!idUsed(ids.items, id)) {
                try ids.append(alloc, id);
                if (id >= next_id) next_id = id + 1;
                continue;
            }
        }
        named = true;
        while (idUsed(ids.items, next_id)) next_id += 1;
        try ids.append(alloc, next_id);
        next_id += 1;
    }

    const order = try alloc.alloc(usize, names.items.len);
    defer alloc.free(order);
    for (order, 0..) |*o, i| o.* = i;
    if (!named) {
        std.mem.sort(usize, order, ids.items, struct {
            fn lt(slice: []i32, a: usize, b: usize) bool {
                return slice[a] < slice[b];
            }
        }.lt);
    }

    var out: std.ArrayList(Workspace) = .empty;
    errdefer {
        for (out.items) |*w| {
            alloc.free(w.label);
            alloc.free(w.target);
            alloc.free(w.monitor);
            for (w.wins) |*win| {
                alloc.free(win.addr);
                alloc.free(win.app_id);
                alloc.free(win.title);
            }
            alloc.free(w.wins);
        }
        out.deinit(alloc);
    }
    for (order) |i| {
        const name = names.items[i];
        const meta = metas.items[i];
        var list: std.ArrayList(Window) = .empty;
        errdefer {
            for (list.items) |*w| {
                alloc.free(w.addr);
                alloc.free(w.app_id);
                alloc.free(w.title);
            }
            list.deinit(alloc);
        }
        for (wins.items) |rw| {
            if (!std.mem.eql(u8, rw.ws, name)) continue;
            var c = Window{
                .addr = try alloc.dupe(u8, rw.id),
                .app_id = try alloc.dupe(u8, rw.app_id),
                .title = try alloc.dupe(u8, rw.title),
                .x = rw.x,
                .y = rw.y,
                .w = rw.w,
                .h = rw.h,
                .floating = rw.floating,
                .focused = rw.focused,
                .monitor = if (findMon(mons.items, rw.output)) |mi| @intCast(mi) else -1,
                .ws_id = ids.items[i],
            };
            if (c.monitor >= 0) {
                const mm = mons.items[@intCast(c.monitor)];
                if (rw.w > 0.0 and rw.h > 0.0) {
                    c.nw = std.math.clamp(rw.w / mm.w, 0.0, 1.0);
                    c.nh = std.math.clamp(rw.h / mm.h, 0.0, 1.0);
                    c.nx = clamp01((rw.x - mm.x) / mm.w);
                    c.ny = clamp01((rw.y - mm.y) / mm.h);
                }
                c.overflow = outsideMonitor(rw.x, rw.y, rw.w, rw.h, mm.x, mm.y, mm.w, mm.h);
            }
            try list.append(alloc, c);
        }
        var ws = Workspace{
            .id = ids.items[i],
            .label = try alloc.dupe(u8, name),
            .target = try alloc.dupe(u8, name),
            .monitor = try alloc.dupe(u8, meta.monitor),
            .active = meta.active,
            .occupied = meta.occupied or list.items.len > 0,
            .wins = try list.toOwnedSlice(alloc),
        };
        if (ws.monitor.len == 0 and ws.wins.len > 0 and ws.wins[0].monitor >= 0) {
            const fallback = mons.items[@intCast(ws.wins[0].monitor)].name;
            alloc.free(ws.monitor);
            ws.monitor = try alloc.dupe(u8, fallback);
        }
        var mon_idx = findMon(mons.items, ws.monitor);
        if (mon_idx == null and ws.wins.len > 0 and ws.wins[0].monitor >= 0) {
            mon_idx = @intCast(ws.wins[0].monitor);
        }
        if (mon_idx) |mi| {
            const mm = mons.items[mi];
            ws.mon_x = mm.x;
            ws.mon_y = mm.y;
            ws.mon_w = mm.w;
            ws.mon_h = mm.h;
        }
        try out.append(alloc, ws);
    }
    return .{ .alloc = alloc, .ws = try out.toOwnedSlice(alloc), .named = named };
}

/// One control round trip per document. The active-workspace eval is best
/// effort: a failed eval still leaves the occupied workspaces usable.
pub fn fetchZoolander(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) ?Snapshot {
    const clients = zCtl(alloc, env, "clients-json") orelse return null;
    defer alloc.free(clients);
    // Geometry is a nicety: without it the cards still show ids, labels and
    // occupancy, just no monitor-relative tile placement.
    const monitors = zCtl(alloc, env, "monitors-json");
    defer if (monitors) |m| alloc.free(m);
    const eval_owned = zCtl(alloc, env, "eval " ++ kActiveWorkspacesLua);
    defer if (eval_owned) |e| alloc.free(e);
    const active = if (eval_owned) |e| replyBody(e) else "";
    const docs = monitors orelse "{\"outputs\":[]}";
    return assembleZoolander(alloc, clients, docs, active) catch null;
}

/// Pick the snapshot source the environment names. Hyprland remains the
/// fallback for every other detected compositor.
pub fn fetchAuto(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) ?Snapshot {
    return switch (compositor.detect(io, env)) {
        .zoolander => fetchZoolander(alloc, env),
        .hyprland, .niri, .mango, .sway, .labwc, .unknown => fetch(alloc, io, env),
    };
}

fn hyprCommand(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    command: []const u8,
) bool {
    const reply = send(alloc, io, env, command) orelse return false;
    defer alloc.free(reply);
    return repliedOk(reply);
}

fn zoolanderEval(alloc: std.mem.Allocator, env: *const std.process.Environ.Map, code: []const u8) bool {
    // The server caps a command line at 2048 bytes and `eval ` plus the
    // newline are part of it.
    if (code.len + 6 > 2048) return false;
    const cmd = std.fmt.allocPrint(alloc, "eval {s}", .{code}) catch return false;
    defer alloc.free(cmd);
    const out = zCtl(alloc, env, cmd) orelse return false;
    defer alloc.free(out);
    const t = std.mem.trim(u8, out, " \t\r\n");
    if (std.mem.eql(u8, t, "OK")) return true;
    if (!std.mem.startsWith(u8, t, "OK ")) return false;
    // `eval` returns the chunk's first result, so a chunk that found nothing
    // answers `OK false`/`OK nil`; those are failures for the caller.
    const body = std.mem.trim(u8, t[3..], " \t\r\n");
    return !std.mem.eql(u8, body, "false") and !std.mem.eql(u8, body, "nil");
}

/// The window fields `clients-json` and `zl.get_windows()` share. The control
/// socket's `id` is a foreign-toplevel handle, not the Lua address, so actions
/// re-find the window inside the `eval` chunk by these fields.
const ZWindowKey = struct {
    app_id: []const u8 = "",
    title: []const u8 = "",
    ws: []const u8 = "",
};

/// Quote `s` as a Lua string literal on one line. Bytes below 0x20 and DEL use
/// three-digit decimal escapes so a control byte next to a digit cannot merge
/// into one escape.
fn luaQuote(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            0...8, 11...12, 14...0x1f, 0x7f => {
                const esc = [_]u8{ '\\', '0' + ch / 100, '0' + (ch / 10) % 10, '0' + ch % 10 };
                try out.appendSlice(alloc, &esc);
            },
            else => try out.append(alloc, ch),
        }
    }
    try out.append(alloc, '"');
}

/// A Lua condition matching one `zl.get_windows()` entry. Workspace always
/// participates; `app_id` and a non-empty title narrow it down when present.
fn appendZWindowMatch(out: *std.ArrayList(u8), alloc: std.mem.Allocator, key: ZWindowKey) !void {
    try out.appendSlice(alloc, "(w.workspace and w.workspace.name==");
    try luaQuote(out, alloc, key.ws);
    if (key.app_id.len > 0) {
        try out.appendSlice(alloc, " and w.app_id==");
        try luaQuote(out, alloc, key.app_id);
    }
    if (key.title.len > 0) {
        try out.appendSlice(alloc, " and w.title==");
        try luaQuote(out, alloc, key.title);
    }
    try out.append(alloc, ')');
}

fn zoolanderMoveLua(alloc: std.mem.Allocator, target: []const u8, key: ZWindowKey, follow: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "return (function() for _,w in ipairs(zl.get_windows()) do if ");
    try appendZWindowMatch(&out, alloc, key);
    try out.appendSlice(alloc, " then return zl.move_window_workspace(");
    try luaQuote(&out, alloc, target);
    try out.appendSlice(alloc, if (follow) ",true,w.address) end end return false end)()" else ",false,w.address) end end return false end)()");
    return out.toOwnedSlice(alloc);
}

/// Zoolander has no swap-by-address action. Two moves between the windows'
/// current workspaces express the same result as long as they differ.
fn zoolanderSwapLua(alloc: std.mem.Allocator, a: ZWindowKey, b: ZWindowKey) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "return (function() local a,b for _,w in ipairs(zl.get_windows()) do if ");
    try appendZWindowMatch(&out, alloc, a);
    try out.appendSlice(alloc, " then a=a or w end if ");
    try appendZWindowMatch(&out, alloc, b);
    try out.appendSlice(alloc, " then b=b or w end end if not a or not b or a==b then return false end " ++
        "local aw,bw=a.workspace.name,b.workspace.name if aw==bw then return false end " ++
        "return zl.move_window_workspace(bw,false,a.address) and zl.move_window_workspace(aw,false,b.address) end)()");
    return out.toOwnedSlice(alloc);
}

/// `return zl.workspace("<name>")`, with the name quoted for Lua.
fn luaWorkspaceCode(buf: []u8, name: []const u8) ?[]const u8 {
    const prefix = "return zl.workspace(\"";
    const suffix = "\")";
    if (prefix.len + name.len * 2 + suffix.len > buf.len) return null;
    var n: usize = 0;
    @memcpy(buf[n..][0..prefix.len], prefix);
    n += prefix.len;
    for (name) |ch| {
        switch (ch) {
            '"', '\\' => {
                buf[n] = '\\';
                n += 1;
                buf[n] = ch;
                n += 1;
            },
            '\n', '\r' => {
                buf[n] = ' ';
                n += 1;
            },
            else => {
                buf[n] = ch;
                n += 1;
            },
        }
    }
    @memcpy(buf[n..][0..suffix.len], suffix);
    n += suffix.len;
    return buf[0..n];
}

/// Activate a workspace on whichever compositor the environment names.
/// `target` is the workspace's compositor name, or its decimal id under
/// Hyprland.
pub fn jumpWorkspace(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    target: []const u8,
) bool {
    if (target.len == 0) return false;
    if (compositor.detect(io, env) == .zoolander) {
        var buf: [1024]u8 = undefined;
        const code = luaWorkspaceCode(&buf, target) orelse return false;
        return zoolanderEval(alloc, env, code);
    }
    const id = std.fmt.parseInt(i32, target, 10) catch return false;
    var buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "dispatch hl.dsp.focus({{workspace = {d}}})", .{id}) catch return false;
    if (hyprCommand(alloc, io, env, cmd)) return true;
    const plain = std.fmt.bufPrint(&buf, "dispatch workspace {d}", .{id}) catch return false;
    return hyprCommand(alloc, io, env, plain);
}

pub fn repliedOk(reply: ?[]const u8) bool {
    const r = reply orelse return false;
    return std.mem.startsWith(u8, std.mem.trim(u8, r, " \t\r\n"), "ok");
}

/// Move a window to a workspace on whichever compositor the environment
/// names. `from_ws` is the source's compositor workspace name (Zoolander)
/// and `target` the destination name; Hyprland uses decimal ids instead.
pub fn moveWindow(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    target: []const u8,
    win: WindowRef,
    from_ws: []const u8,
    follow: bool,
) bool {
    if (target.len == 0) return false;
    if (compositor.detect(io, env) == .zoolander) {
        const key = ZWindowKey{ .app_id = win.app_id, .title = win.title, .ws = from_ws };
        const code = zoolanderMoveLua(alloc, target, key, follow) catch return false;
        defer alloc.free(code);
        return zoolanderEval(alloc, env, code);
    }
    const ws_id = std.fmt.parseInt(i32, target, 10) catch return false;
    var buf: [160]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "dispatch hl.dsp.window.move({{workspace = {d}, window = \"address:{s}\"}})", .{ ws_id, win.addr }) catch return false;
    return hyprCommand(alloc, io, env, cmd);
}

/// Swap two windows between their workspaces. Zoolander cannot reorder inside
/// one workspace, so a same-workspace swap reports false.
pub fn swapWindows(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    a: WindowRef,
    a_ws: []const u8,
    b: WindowRef,
    b_ws: []const u8,
) bool {
    if (compositor.detect(io, env) == .zoolander) {
        if (std.mem.eql(u8, a_ws, b_ws)) return false;
        const code = zoolanderSwapLua(
            alloc,
            .{ .app_id = a.app_id, .title = a.title, .ws = a_ws },
            .{ .app_id = b.app_id, .title = b.title, .ws = b_ws },
        ) catch return false;
        defer alloc.free(code);
        return zoolanderEval(alloc, env, code);
    }
    if (a.addr.len == 0 or b.addr.len == 0) return false;
    var buf: [256]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "dispatch hl.dsp.window.swap({{window = \"address:{s}\", target = \"address:{s}\"}})", .{ a.addr, b.addr }) catch return false;
    return hyprCommand(alloc, io, env, cmd);
}

test "overview-ws: workspaces parse with labels and flags" {
    const t = std.testing;
    const doc =
        \\[{"id":1,"name":"1","monitor":"DP-1","focused":true,"windows":2},
        \\ {"id":2,"name":"web","monitor":"DP-1","focused":false,"windows":1},
        \\ {"id":-99,"name":"special","monitor":"DP-1","focused":false,"windows":1}]
    ;
    const raws = try parseWsList(t.allocator, doc);
    defer {
        for (raws) |r| {
            t.allocator.free(r.label);
            t.allocator.free(r.monitor);
        }
        t.allocator.free(raws);
    }
    try t.expectEqual(@as(usize, 2), raws.len);
    try t.expectEqualStrings("1", raws[0].label);
    try t.expect(raws[0].active);
    try t.expect(raws[0].occupied);
    try t.expectEqualStrings("web", raws[1].label);
    try t.expect(!raws[1].active);
}

test "overview-ws: clients attach with normalized geometry" {
    const t = std.testing;
    const ws_doc =
        \\[{"id":1,"name":"1","monitor":"DP-1","focused":true,"windows":2}]
    ;
    const mon_doc =
        \\[{"id":0,"x":0.0,"y":0.0,"width":1920.0,"height":1080.0}]
    ;
    const cl_doc =
        \\[{"address":"0xabc","class":"kitty","title":"sh","mapped":true,"floating":false,
        \\  "workspace":{"id":1},"at":[0.0,0.0],"size":[960.0,1080.0],"monitor":0,"focusHistoryID":0},
        \\ {"address":"0xdef","class":"","initialClass":"edge","title":"web","mapped":true,
        \\  "floating":true,"workspace":{"id":1},"at":[960.0,0.0],"size":[960.0,1080.0],"monitor":0,"focusHistoryID":2},
        \\ {"address":"0xghi","class":"hidden","title":"x","mapped":false,
        \\  "workspace":{"id":1},"at":[0.0,0.0],"size":[100.0,100.0],"monitor":0,"focusHistoryID":5}]
    ;
    var snap = try assemble(t.allocator, ws_doc, mon_doc, cl_doc);
    defer snap.deinit();
    try t.expectEqual(@as(usize, 1), snap.ws.len);
    try t.expectEqual(@as(usize, 2), snap.ws[0].wins.len);
    try t.expect(snap.ws[0].occupied);
    const a = snap.ws[0].wins[0];
    try t.expectEqualStrings("0xabc", a.addr);
    try t.expect(a.focused);
    try t.expectEqual(@as(f64, 0.5), a.nw);
    try t.expectEqual(@as(f64, 0), a.nx);
    const b = snap.ws[0].wins[1];
    try t.expectEqualStrings("edge", b.app_id);
    try t.expect(b.floating);
    try t.expectEqual(@as(f64, 0.5), b.nx);
    try t.expectEqual(@as(f64, 1920), snap.ws[0].mon_w);
}

test "overview-ws: max slots pads, keeps real overflow" {
    const t = std.testing;
    const ws_doc =
        \\[{"id":1,"name":"1","monitor":"DP-1","focused":false,"windows":0},
        \\ {"id":7,"name":"7","monitor":"DP-1","focused":true,"windows":1}]
    ;
    const mon_doc =
        \\[]
    ;
    const cl_doc =
        \\[{"address":"0xa","class":"x","title":"t","mapped":true,"workspace":{"id":7},
        \\  "at":[0.0,0.0],"size":[10.0,10.0],"monitor":0,"focusHistoryID":0}]
    ;
    var snap = try assemble(t.allocator, ws_doc, mon_doc, cl_doc);
    defer snap.deinit();
    try applyMaxSlots(t.allocator, &snap, 3);
    try t.expectEqual(@as(usize, 7), snap.ws.len);
    try t.expectEqual(@as(i32, 1), snap.ws[0].id);
    try t.expectEqual(@as(i32, 2), snap.ws[1].id);
    try t.expectEqualStrings("2", snap.ws[1].label);
    try t.expectEqual(@as(i32, 7), snap.ws[6].id);
    try t.expect(snap.ws[6].active);
}

test "overview-ws: zoolander clients and active outputs assemble" {
    const t = std.testing;
    const clients =
        \\OK json
        \\[{"id":"0xaaa","app_id":"kitty","title":"sh","workspace":"1","special":false,
        \\  "output":"DP-1","x":0,"y":0,"width":960,"height":1080,"floating":false,"focused":true},
        \\ {"id":"0xbbb","app_id":"firefox","title":"web","workspace":"2","special":false,
        \\  "output":"DP-1","x":0,"y":0,"width":1920,"height":1080,"floating":true,"focused":false},
        \\ {"id":"0xccc","app_id":"scratch","title":"hidden","workspace":"special:scratch","special":true,
        \\  "output":"DP-1","x":0,"y":0,"width":100,"height":100,"floating":false,"focused":false}]
    ;
    const monitors =
        \\OK json
        \\{"version":1,"outputs":[
        \\ {"name":"DP-1","enabled":true,"x":0,"y":0,"logical_width":1920,"logical_height":1080},
        \\ {"name":"HDMI-A-1","enabled":false,"x":1920,"y":0,"logical_width":1280,"logical_height":720}]}
    ;
    var snap = try assembleZoolander(t.allocator, clients, monitors, "DP-1\x1e2");
    defer snap.deinit();
    try t.expect(!snap.named);
    try t.expectEqual(@as(usize, 2), snap.ws.len);
    try t.expectEqualStrings("1", snap.ws[0].label);
    try t.expectEqualStrings("1", snap.ws[0].target);
    try t.expectEqual(@as(usize, 1), snap.ws[0].wins.len);
    try t.expect(snap.ws[0].wins[0].focused);
    try t.expectEqual(@as(f64, 0.5), snap.ws[0].wins[0].nw);
    try t.expectEqualStrings("2", snap.ws[1].label);
    try t.expect(snap.ws[1].active);
    try t.expectEqual(@as(usize, 1), snap.ws[1].wins.len);
    try t.expectEqualStrings("DP-1", snap.ws[1].monitor);
    try t.expectEqual(@as(f64, 1920), snap.ws[1].mon_w);
}

test "overview-ws: zoolander named workspaces keep discovery order and no padding" {
    const t = std.testing;
    const clients =
        \\[{"id":"0x1","app_id":"a","title":"","workspace":"dev","special":false,
        \\  "output":"DP-1","x":0,"y":0,"width":100,"height":100,"floating":false,"focused":false}]
    ;
    const monitors =
        \\{"version":1,"outputs":[{"name":"DP-1","enabled":true,"x":0,"y":0,
        \\  "logical_width":1000,"logical_height":1000}]}
    ;
    var snap = try assembleZoolander(t.allocator, clients, monitors, "DP-1\x1ewe|ird=x");
    defer snap.deinit();
    try t.expect(snap.named);
    try t.expectEqual(@as(usize, 2), snap.ws.len);
    try t.expectEqualStrings("we|ird=x", snap.ws[0].target);
    try t.expect(snap.ws[0].active);
    try t.expectEqualStrings("dev", snap.ws[1].target);
    try applyMaxSlots(t.allocator, &snap, 5);
    try t.expectEqual(@as(usize, 2), snap.ws.len);
}

test "overview-ws: zoolander reply bodies strip the status tag" {
    const t = std.testing;
    try t.expectEqualStrings("DP-1\x1e2", replyBody("OK DP-1\x1e2\n"));
    try t.expectEqualStrings("", replyBody("OK\n"));
    try t.expectEqualStrings("ERR nope", replyBody("ERR nope\n"));
}

test "overview-ws: zoolander lua workspace names are quoted" {
    const t = std.testing;
    var buf: [128]u8 = undefined;
    const code = luaWorkspaceCode(&buf, "we\"ird\\name").?;
    try t.expectEqualStrings("return zl.workspace(\"we\\\"ird\\\\name\")", code);
}

test "overview-ws: zoolander window actions build one-line lua" {
    const t = std.testing;
    const key = ZWindowKey{ .app_id = "we\"ird", .title = "a\nb", .ws = "x\x01y" };
    const move = try zoolanderMoveLua(t.allocator, "tar\"get", key, false);
    defer t.allocator.free(move);
    try t.expect(std.mem.indexOfScalar(u8, move, '\n') == null);
    try t.expect(std.mem.indexOf(u8, move, "w.app_id==\"we\\\"ird\"") != null);
    try t.expect(std.mem.indexOf(u8, move, "w.title==\"a\\nb\"") != null);
    try t.expect(std.mem.indexOf(u8, move, "w.workspace.name==\"x\\001y\"") != null);
    try t.expect(std.mem.indexOf(u8, move, "move_window_workspace(\"tar\\\"get\",false,w.address)") != null);

    const follow = try zoolanderMoveLua(t.allocator, "2", key, true);
    defer t.allocator.free(follow);
    try t.expect(std.mem.indexOf(u8, follow, ",true,w.address)") != null);

    const swap = try zoolanderSwapLua(t.allocator, key, .{ .app_id = "other", .title = "", .ws = "2" });
    defer t.allocator.free(swap);
    try t.expect(std.mem.indexOfScalar(u8, swap, '\n') == null);
    try t.expect(std.mem.indexOf(u8, swap, "local aw,bw=a.workspace.name,b.workspace.name") != null);
    try t.expect(std.mem.indexOf(u8, swap, "move_window_workspace(bw,false,a.address)") != null);
    try t.expect(std.mem.indexOf(u8, swap, "move_window_workspace(aw,false,b.address)") != null);
}

test "overview-ws: zoolander control round trip assembles a snapshot" {
    const t = std.testing;
    const io = t.io;
    const cwd = std.Io.Dir.cwd();

    var name_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&name_buf, "/tmp/opencode/eh-zctl-{d}", .{std.os.linux.getpid()});
    defer cwd.deleteTree(io, root) catch {};
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "zoolander-wayland-1.sock" });
    defer t.allocator.free(path);

    const lfd = try sock.createStream(false);
    defer sock.closeFd(lfd);
    try sock.bindPath(lfd, path);
    try sock.listenOn(lfd, 4);

    // One serving thread, three connections: the greeting then the reply each
    // `zCtl` command expects, keyed by the command line it reads.
    const Serve = struct {
        const clients_json =
            "OK json\n[{\"id\":\"0x1\",\"app_id\":\"kitty\",\"title\":\"sh\",\"workspace\":\"1\"," ++
            "\"special\":false,\"output\":\"DP-1\",\"x\":0,\"y\":0,\"width\":960,\"height\":1080," ++
            "\"floating\":false,\"focused\":true}]\n";
        const monitors_json =
            "OK json\n{\"version\":1,\"outputs\":[{\"name\":\"DP-1\",\"enabled\":true,\"x\":0,\"y\":0," ++
            "\"logical_width\":1920,\"logical_height\":1080}]}\n";
        const eval_reply = "OK DP-1\x1e1\n";

        lfd: i32,

        fn run(self: @This()) void {
            var served: u32 = 0;
            while (served < 3) : (served += 1) {
                const c = accept(self.lfd) orelse return;
                defer sock.closeFd(c);
                sock.sendAll(c, "ZLCTL 1\n") catch {};
                var got: [4096]u8 = undefined;
                const n = readAll(c, &got);
                if (std.mem.startsWith(u8, got[0..n], "clients-json")) {
                    sock.sendAll(c, clients_json) catch {};
                } else if (std.mem.startsWith(u8, got[0..n], "monitors-json")) {
                    sock.sendAll(c, monitors_json) catch {};
                } else if (std.mem.startsWith(u8, got[0..n], "eval ")) {
                    sock.sendAll(c, eval_reply) catch {};
                }
            }
        }

        fn accept(l: i32) ?i32 {
            const deadline = sock.nowMs() + 5000;
            while (sock.nowMs() < deadline) : (nap()) {
                if (sock.acceptConn(l)) |c| return c;
            }
            return null;
        }

        fn readAll(c: i32, out: []u8) usize {
            var n: usize = 0;
            while (n < out.len) {
                const rc = linux.recvfrom(c, out[n..].ptr, out.len - n, 0, null, null);
                const e = linux.errno(rc);
                if (e == .SUCCESS) {
                    if (rc == 0) break;
                    n += rc;
                    continue;
                }
                if (e == .INTR) continue;
                if (e == .AGAIN) {
                    nap();
                    continue;
                }
                break;
            }
            return n;
        }

        fn nap() void {
            var pfd = [_]std.posix.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
            _ = std.posix.poll(&pfd, 5) catch 0;
        }
    };
    var thread = try std.Thread.spawn(.{}, Serve.run, .{Serve{ .lfd = lfd }});
    defer thread.join();

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("XDG_RUNTIME_DIR", root);
    try env.put("WAYLAND_DISPLAY", "wayland-1");

    var snap = fetchZoolander(t.allocator, &env) orelse return error.TestUnexpectedResult;
    defer snap.deinit();
    try t.expectEqual(@as(usize, 1), snap.ws.len);
    try t.expectEqualStrings("1", snap.ws[0].label);
    try t.expectEqualStrings("1", snap.ws[0].target);
    try t.expect(snap.ws[0].active);
    try t.expectEqual(@as(usize, 1), snap.ws[0].wins.len);
    try t.expectEqualStrings("DP-1", snap.ws[0].monitor);
    try t.expectEqual(@as(f64, 0.5), snap.ws[0].wins[0].nw);
    try t.expectEqual(@as(f64, 1920), snap.ws[0].mon_w);
}
