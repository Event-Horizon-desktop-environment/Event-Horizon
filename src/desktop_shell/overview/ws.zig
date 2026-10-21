//! Hyprland workspace snapshot for the overview and the strip widget.
//!
//! Three IPC documents — `j/workspaces`, `j/clients`, `j/monitors` — become
//! one owned snapshot: workspaces with monitor geometry plus their windows
//! with absolute geometry and normalized (monitor-relative) geometry for
//! tile layout. Special workspaces (id <= 0) and unmapped clients are
//! skipped. `applyMaxSlots` pads/truncates to the widget's `max_workspaces`
//! the way the strip does, keeping real workspaces past the cap when they
//! hold windows or focus.

const std = @import("std");
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

pub const Workspace = struct {
    id: i32 = 0,
    label: []const u8 = "",
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

    pub fn deinit(self: *Snapshot) void {
        for (self.ws) |*w| {
            self.alloc.free(w.label);
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

pub fn repliedOk(reply: ?[]const u8) bool {
    const r = reply orelse return false;
    return std.mem.startsWith(u8, std.mem.trim(u8, r, " \t\r\n"), "ok");
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
    const ws_doc = \\[{"id":1,"name":"1","monitor":"DP-1","focused":true,"windows":2}]
    ;
    const mon_doc = \\[{"id":0,"x":0.0,"y":0.0,"width":1920.0,"height":1080.0}]
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
    const mon_doc = \\[]
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
