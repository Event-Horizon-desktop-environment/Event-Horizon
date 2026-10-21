//! mango workspace events: one line off the `watch all-monitors` socket into
//! the tables, plus the client refresh every accepted line triggers.
//!
//! Both jobs live here because a monitor list without
//! its client list is a half-read state, and half-read states are never
//! published.

const std = @import("std");
const linux = std.os.linux;
const desk = @import("desk.zig");
const sock = @import("../sock.zig");
const st = @import("mango_ws_state.zig");
const run_ctx = @import("mango_run_ctx.zig");

/// Applies one subscription line. Returns true when it *was* a monitor list —
/// the only thing that makes the shell get told
/// anything. An empty line, malformed JSON, a non-object, or an object with
/// no `monitors` array all change nothing and answer false.
pub fn processMsg(tables: *st.Tables, rt: *run_ctx.Runtime, line: []const u8) bool {
    if (line.len == 0) return false;

    var doc = std.json.parseFromSlice(std.json.Value, tables.alloc, line, .{}) catch return false;
    defer doc.deinit();
    if (doc.value != .object) return false;
    const arr = desk.jsonArr(doc.value, "monitors") orelse return false;

    var next: st.OutMap = .empty;
    // Empty the moment the new table is adopted, so this is either "everything
    // the build had" on the way out or a no-op on the way past.
    defer st.freeOutMap(tables.alloc, &next);

    for (arr.items) |mon| {
        const m = st.decodeMonitor(tables.alloc, mon) orelse continue;
        st.putOut(tables.alloc, &next, m);
    }

    tables.adoptOutputs(&next);
    fetchClients(tables, rt);
    return true;
}

/// `get all-clients` over its own connection, replacing the client table. No
/// answer, an answer without a `clients` array, and a partial build all leave
/// the table as it was rather than reporting a window list nobody can read.
pub fn fetchClients(tables: *st.Tables, rt: *run_ctx.Runtime) void {
    const resp = rt.ipcQuery("get all-clients") orelse return;
    defer resp.deinit();
    if (resp.value != .object) return;
    const arr = desk.jsonArr(resp.value, "clients") orelse return;

    var next: std.ArrayList(st.Client) = .empty;
    defer {
        st.freeClientList(tables.alloc, &next);
        next.deinit(tables.alloc);
    }
    for (arr.items) |c| {
        const cl = st.decodeClient(tables.alloc, c) orelse continue;
        next.append(tables.alloc, cl) catch st.freeClient(tables.alloc, cl);
    }
    tables.adoptClients(&next);
}

// Tests

const t = std.testing;

const monitors_line =
    \\{"monitors":[
    \\ {"name":"DP-1","active":true,"x":0,"y":0,"width":2560,"height":1440,
    \\  "active_client":{"title":"Terminal","appid":"otter-term"},
    \\  "tags":[{"index":1,"is_active":true,"client_count":1},
    \\          {"index":2,"is_active":false,"client_count":0}]},
    \\ {"name":"HDMI-A-1","active":false,
    \\  "tags":[{"index":1,"is_active":false,"client_count":2}]}
    \\]}
;

/// Accepts one connection per canned reply and records the request line that
/// arrived on it. The accepted fd is non-blocking, so `readLine` polls out
/// `EAGAIN` rather than mistaking it for a short read.
const Serve = struct {
    lfd: i32,
    replies: []const []const u8,
    alloc: std.mem.Allocator,
    seen: *std.ArrayList([]u8),

    fn run(self: @This()) void {
        for (self.replies) |reply| {
            const c = self.accept() orelse return;
            defer sock.closeFd(c);
            var slot: [512]u8 = undefined;
            if (readLine(c, &slot)) |req| {
                const copy = self.alloc.dupe(u8, req) catch continue;
                self.seen.append(self.alloc, copy) catch {
                    self.alloc.free(copy);
                    continue;
                };
            }
            sock.sendAll(c, reply) catch return;
        }
    }

    fn accept(self: @This()) ?i32 {
        const deadline = sock.nowMs() + 5000;
        while (sock.nowMs() < deadline) : ({
            _ = std.posix.poll(&[_]std.posix.pollfd{}, 5) catch 0;
        }) {
            if (sock.acceptConn(self.lfd)) |c| return c;
        }
        return null;
    }

    fn readLine(c: i32, got: *[512]u8) ?[]u8 {
        var n: usize = 0;
        const deadline = sock.nowMs() + 5000;
        while (n < got.len and sock.nowMs() < deadline) {
            const rc = linux.recvfrom(c, got[n..].ptr, got.len - n, 0, null, null);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e == .AGAIN) {
                _ = std.posix.poll(&[_]std.posix.pollfd{}, 5) catch 0;
                continue;
            }
            if (e != .SUCCESS) return null;
            if (rc == 0) return null;
            n += rc;
            if (std.mem.indexOfScalar(u8, got[0..n], '\n')) |nl| return got[0..nl];
        }
        return null;
    }
};

fn freeSeen(list: *std.ArrayList([]u8), alloc: std.mem.Allocator) void {
    for (list.items) |s| alloc.free(s);
    list.deinit(alloc);
}

test "mango-ws-events: only a monitor list counts, and a bad one changes nothing" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var rt = run_ctx.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    var tables = st.Tables.init(t.allocator);
    defer tables.deinit();

    // Nothing to fetch from, but the monitors still land: the two tables are
    // independent, exactly as when mango answers one and not the other.
    try t.expect(processMsg(&tables, &rt, monitors_line));
    try t.expectEqual(@as(usize, 2), tables.outputs.count());
    try t.expectEqual(@as(usize, 0), tables.clients.items.len);
    try t.expect(tables.byName("DP-1").?.active);
    try t.expectEqual(@as(usize, 2), tables.byName("DP-1").?.tags.len);
    try t.expect(tables.byName("DP-1").?.tags[0].active);

    // Every rejected shape leaves the table untouched.
    try t.expect(!processMsg(&tables, &rt, ""));
    try t.expect(!processMsg(&tables, &rt, "not json"));
    try t.expect(!processMsg(&tables, &rt, "[1,2,3]"));
    try t.expect(!processMsg(&tables, &rt, "{\"foo\":1}"));
    try t.expect(!processMsg(&tables, &rt, "{\"monitors\":7}"));
    try t.expectEqual(@as(usize, 2), tables.outputs.count());

    // A monitor array that decodes to nothing still counts as a change —
    // the (now empty) table is published.
    try t.expect(processMsg(&tables, &rt, "{\"monitors\":[5]}"));
    try t.expectEqual(@as(usize, 0), tables.outputs.count());
}

test "mango-ws-events: every applied monitor list pulls the client list behind it" {
    const cwd = std.Io.Dir.cwd();
    var name_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&name_buf, "/tmp/opencode/eh-mango-ev-{d}", .{std.os.linux.getpid()});
    defer cwd.deleteTree(t.io, root) catch {};
    cwd.deleteTree(t.io, root) catch {};
    try cwd.createDirPath(t.io, root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "mango.sock" });
    defer t.allocator.free(path);

    const lfd = try sock.createStream(false);
    defer sock.closeFd(lfd);
    try sock.bindPath(lfd, path);
    try sock.listenOn(lfd, 4);

    var seen: std.ArrayList([]u8) = .empty;
    defer freeSeen(&seen, t.allocator);
    var thread = try std.Thread.spawn(
        .{},
        Serve.run,
        .{Serve{
            .lfd = lfd,
            .replies = &[_][]const u8{
                "{\"clients\":[{\"id\":11,\"title\":\"One\",\"appid\":\"foot\",\"monitor\":\"DP-1\",\"tags\":[1,2],\"is_focused\":true}]}",
                "{\"clients\":[{\"id\":11,\"title\":\"Replaced\",\"appid\":\"foot\",\"monitor\":\"DP-1\",\"tags\":[1]}]}",
                "{\"nope\":true}",
            },
            .alloc = t.allocator,
            .seen = &seen,
        }},
    );
    defer thread.join();

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MANGO_INSTANCE_SIGNATURE", path);
    var rt = run_ctx.Runtime.init(t.allocator, t.io, &env);
    defer rt.deinit();

    var tables = st.Tables.init(t.allocator);
    defer tables.deinit();

    try t.expect(processMsg(&tables, &rt, monitors_line));
    try t.expectEqual(@as(usize, 1), tables.clients.items.len);
    try t.expectEqualStrings("11", tables.clients.items[0].id);
    try t.expectEqualStrings("foot", tables.clients.items[0].app_id);
    try t.expect(tables.clients.items[0].focused);
    try t.expectEqualSlices(u32, &.{ 1, 2 }, tables.clients.items[0].tags);

    // A second list replaces the clients wholesale, not by merge.
    try t.expect(processMsg(&tables, &rt, monitors_line));
    try t.expectEqual(@as(usize, 1), tables.clients.items.len);
    try t.expectEqualStrings("Replaced", tables.clients.items[0].title);

    // An answer with no `clients` array leaves the previous list standing.
    try t.expect(processMsg(&tables, &rt, monitors_line));
    try t.expectEqual(@as(usize, 1), tables.clients.items.len);
    try t.expectEqualStrings("Replaced", tables.clients.items[0].title);

    try t.expectEqual(@as(usize, 3), seen.items.len);
    for (seen.items) |req| try t.expectEqualStrings("get all-clients", req);
}
