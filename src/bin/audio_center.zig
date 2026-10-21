//! horizon-audio-center — the Event Horizon audio mixer.
//!
//! At this stage the binary carries the back end only: `--probe` prints the
//! live PipeWire graph, and the action flags exercise individual writes
//! (volume, mute, default, routing, terminate). The window drills in on top
//! of the same client.

const std = @import("std");
const eh = @import("eh");
const client_mod = eh.ac_client;
const graph_mod = eh.ac_graph;
const meter_mod = eh.ac_meter;

const Client = client_mod.Client;
const Graph = graph_mod.Graph;

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch &.{};

    // No arguments: the mixer window (pavucontrol's five tabs in the shell's
    // chrome). Any flag keeps the headless CLI the probes use.
    if (args.len < 2) {
        return eh.ac_window.run(init);
    }

    var g = Graph.init(alloc);
    defer g.deinit();
    const client = try Client.create(alloc, &g);
    defer client.destroy();

    try pump(client, 12);

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "--probe") or std.mem.eql(u8, cmd, "--dump")) {
        try pumpAfterSync(client);
        dump(&g);
    } else if (std.mem.eql(u8, cmd, "--set-volume")) {
        const id = try parseU32(getArg(args, 2) orelse return usage());
        const ratio = try parseF32(getArg(args, 3) orelse return usage());
        const amp = graph_mod.ratioAmplitude(ratio);
        var vols: [graph_mod.max_channels]f32 = undefined;
        const n: usize = if (g.findNode(id)) |node| blk: {
            const t = g.volumeTarget(node, false);
            break :blk if (t.n_volumes > 0) t.n_volumes else 2;
        } else 2;
        for (0..n) |i| vols[i] = amp;
        if (!client.setVolume(id, vols[0..n], false)) std.debug.print("set-volume failed\n", .{});
        try pumpAfterSync(client);
        dumpNode(&g, id);
    } else if (std.mem.eql(u8, cmd, "--set-channels")) {
        const id = try parseU32(getArg(args, 2) orelse return usage());
        var vols: [graph_mod.max_channels]f32 = undefined;
        var n: usize = 0;
        while (n < vols.len) : (n += 1) {
            const s = getArg(args, 3 + n) orelse break;
            vols[n] = try parseF32(s);
        }
        if (n == 0) return usage();
        if (!client.setVolume(id, vols[0..n], false)) std.debug.print("set-channels failed\n", .{});
        try pumpAfterSync(client);
        dumpNode(&g, id);
    } else if (std.mem.eql(u8, cmd, "--set-mute")) {
        const id = try parseU32(getArg(args, 2) orelse return usage());
        const m = try parseU32(getArg(args, 3) orelse return usage());
        if (!client.setMute(id, m != 0, false)) std.debug.print("set-mute failed\n", .{});
        try pumpAfterSync(client);
        dumpNode(&g, id);
    } else if (std.mem.eql(u8, cmd, "--set-default")) {
        const kind = getArg(args, 2) orelse return usage();
        const name = getArg(args, 3) orelse return usage();
        const ok = if (std.mem.eql(u8, kind, "source"))
            client.setDefaultSourceName(name)
        else
            client.setDefaultSinkName(name);
        if (!ok) std.debug.print("set-default failed\n", .{});
        try pumpAfterSync(client);
        std.debug.print("default sink={s} source={s}\n", .{ g.default_sink.get(), g.default_source.get() });
    } else if (std.mem.eql(u8, cmd, "--move")) {
        const id = try parseU32(getArg(args, 2) orelse return usage());
        const target = try parseU32(getArg(args, 3) orelse return usage());
        if (!client.moveStream(id, target)) std.debug.print("move failed\n", .{});
        try pumpAfterSync(client);
        dumpNode(&g, id);
    } else if (std.mem.eql(u8, cmd, "--kill")) {
        const id = try parseU32(getArg(args, 2) orelse return usage());
        if (!client.killNode(id)) std.debug.print("kill failed\n", .{});
        try pumpAfterSync(client);
        std.debug.print("node {d} present: {}\n", .{ id, g.findNode(id) != null });
    } else if (std.mem.eql(u8, cmd, "--meter")) {
        const id = try parseU32(getArg(args, 2) orelse return usage());
        const secs = if (getArg(args, 3)) |s| try parseF32(s) else 5.0;
        var target = meter_mod.Target{ .id = id, .sink = false };
        if (g.findNode(id)) |n| target.sink = n.role == .sink;
        std.debug.print("metering node {d} sink={}\n", .{ id, target.sink });
        var mgr = meter_mod.Manager.init(alloc, client);
        defer mgr.deinit();
        _ = mgr.setTargets(&.{target});
        var elapsed: f32 = 0;
        var next_print: f32 = 0;
        while (elapsed < secs) {
            client.iterate(20);
            mgr.tick(0.02);
            elapsed += 0.02;
            if (elapsed >= next_print) {
                next_print += 0.2;
                const lv = mgr.level(id) orelse .{ @as(f32, 0), @as(f32, 0) };
                std.debug.print("t={d:.1} L={d:.4} R={d:.4}\n", .{ elapsed, lv[0], lv[1] });
            }
        }
    } else if (std.mem.eql(u8, cmd, "--set-profile")) {
        const dev = try parseU32(getArg(args, 2) orelse return usage());
        const index = try parseI32(getArg(args, 3) orelse return usage());
        if (!client.setProfile(dev, index)) std.debug.print("set-profile failed\n", .{});
        try pumpAfterSync(client);
        if (g.findDevice(dev)) |d| {
            std.debug.print("device {d} active_profile={d}\n", .{ dev, d.active_profile });
        }
    } else if (std.mem.eql(u8, cmd, "--set-route")) {
        const dev = try parseU32(getArg(args, 2) orelse return usage());
        const index = try parseI32(getArg(args, 3) orelse return usage());
        const inner = if (getArg(args, 4)) |s| try parseI32(s) else -1;
        if (!client.setRoute(dev, index, inner)) std.debug.print("set-route failed\n", .{});
        try pumpAfterSync(client);
        if (g.findDevice(dev)) |d| {
            std.debug.print("device {d} active_route={d}\n", .{ dev, d.active_route });
        }
    } else {
        return usage();
    }
    return 0;
}

fn getArg(args: []const []const u8, i: usize) ?[]const u8 {
    if (i >= args.len) return null;
    return args[i];
}

fn usage() u8 {
    const text =
        \\usage: horizon-audio-center <command>
        \\  --probe                              dump the live graph and exit
        \\  --meter <node> [seconds]             watch peak levels of a node
        \\  --set-volume <node> <0.0..1.5+>      set volume (pulse ratio, cubic)
        \\  --set-channels <node> <v> [v...]     set per-channel volumes (linear)
        \\  --set-mute <node> <0|1>              set mute
        \\  --set-default <sink|source> <name>   set the default device
        \\  --move <stream-node> <target-node>    move a stream to another node
        \\  --kill <node>                        terminate a node
        \\  --set-profile <device> <index>       switch card profile
        \\  --set-route <device> <index> [inner] switch port/route
        \\
    ;
    std.debug.print("{s}", .{text});
    return 2;
}

fn parseU32(s: []const u8) !u32 {
    return std.fmt.parseInt(u32, s, 10) catch {
        std.debug.print("bad number: {s}\n", .{s});
        return error.BadArgs;
    };
}

fn parseI32(s: []const u8) !i32 {
    return std.fmt.parseInt(i32, s, 10) catch {
        std.debug.print("bad number: {s}\n", .{s});
        return error.BadArgs;
    };
}

fn parseF32(s: []const u8) !f32 {
    return std.fmt.parseFloat(f32, s) catch {
        std.debug.print("bad number: {s}\n", .{s});
        return error.BadArgs;
    };
}

/// Iterate the client a fixed number of rounds to let the registry burst
/// arrive before any action is attempted.
fn pump(client: *Client, rounds: usize) !void {
    if (rounds == 0) return;
    var i: usize = 0;
    while (i < rounds) : (i += 1) client.iterate(15);
}

/// Roundtrip twice: the first sync confirms the registry burst was processed,
/// the second one catches param replies queued behind it.
fn pumpAfterSync(client: *Client) !void {
    client.sync();
    var i: usize = 0;
    while (i < 300 and client.syncs_done == 0) : (i += 1) client.iterate(15);
    client.sync();
    i = 0;
    while (i < 300 and client.syncs_done < 2) : (i += 1) client.iterate(15);
}

fn roleName(role: graph_mod.Role) []const u8 {
    return switch (role) {
        .sink => "sink",
        .source => "source",
        .stream_playback => "playback",
        .stream_record => "record",
        .other => "other",
    };
}

fn dumpNode(g: *Graph, id: u32) void {
    const n = g.findNode(id) orelse {
        std.debug.print("node {d}: (not in graph)\n", .{id});
        return;
    };
    printNode(g, n);
}

fn printNode(g: *Graph, n: *const graph_mod.Node) void {
    std.debug.print("[{d}] {s} name={s} desc={s} vol={d:.4} mute={} ch={d}", .{
        n.id, roleName(n.role), n.node_name.get(), n.displayName(), n.volume, n.mute, n.volume_count,
    });
    if (n.volume_count > 0) {
        std.debug.print(" linear=[", .{});
        for (0..n.volume_count) |i| {
            std.debug.print("{d:.4}{s}", .{ n.volumes[i], if (i + 1 < n.volume_count) " " else "" });
        }
        std.debug.print("]", .{});
    }
    // The volume the pulse layer (and pavucontrol) actually shows.
    const t = g.volumeTarget(n, false);
    if (t.n_volumes > 0 or t.card_id != 0) {
        std.debug.print(" eff=[", .{});
        for (0..t.n_volumes) |i| {
            std.debug.print("{d:.4}{s}", .{ t.volumes[i], if (i + 1 < t.n_volumes) " " else "" });
        }
        std.debug.print("] pct={d:.1} via={s} mute={}", .{
            graph_mod.amplitudeRatio(if (t.n_volumes > 0) t.volumes[0] else 0) * 100,
            if (t.card_id != 0) "route" else "node",
            t.mute,
        });
        if (t.card_id != 0) std.debug.print("({d}:{d}/{d})", .{ t.card_id, t.route_index, t.route_device });
    }
    std.debug.print(" device={d} serial={d} client={d} hw={} meter={} state={d} app={s} media={s}\n", .{
        n.device_id, n.serial, n.client_id, n.isHardware(), n.is_meter, n.state, n.app_name.get(), n.media_name.get(),
    });
}

fn dump(g: *Graph) void {
    std.debug.print("defaults: sink={s} source={s} (have={})\n", .{
        g.default_sink.get(), g.default_source.get(), g.have_defaults,
    });
    for ([_]graph_mod.Role{ .sink, .source, .stream_playback, .stream_record }) |role| {
        std.debug.print("== {s} ({d}) ==\n", .{ roleName(role), g.countRole(role) });
        for (g.nodes.items) |*n| {
            if (n.role != role) continue;
            printNode(g, n);
        }
    }
    std.debug.print("== devices ({d}) ==\n", .{g.devices.items.len});
    for (g.devices.items) |*d| {
        std.debug.print("[{d}] {s} name={s} api={s} prof={d} route={d} profiles={d} routes={d}\n", .{
            d.id, d.displayName(), d.device_name.get(), d.api.get(), d.active_profile, d.active_route, d.profiles.items.len, d.routes.items.len,
        });
        std.debug.print("    active: in idx={d} dev={d} props={} vols={d} | out idx={d} dev={d} props={} vols={d}\n", .{
            d.active_in.index,  d.active_in.device,  d.active_in.has_props,  d.active_in.n_volumes,
            d.active_out.index, d.active_out.device, d.active_out.has_props, d.active_out.n_volumes,
        });
        for (d.profiles.items) |*p| {
            std.debug.print("    profile {d} \"{s}\" prio={d} avail={d}\n", .{ p.index, p.label(), p.priority, p.available });
        }
        for (d.routes.items) |*r| {
            std.debug.print("    route {d} dir={d} \"{s}\" prio={d} avail={d} dev={d}\n", .{ r.index, r.direction, r.label(), r.priority, r.available, r.device });
        }
    }
    std.debug.print("== links ({d}) ==\n", .{g.links.items.len});
    for (g.links.items) |*l| {
        std.debug.print("  {d}: {d} -> {d}\n", .{ l.id, l.out_node, l.in_node });
    }
}
