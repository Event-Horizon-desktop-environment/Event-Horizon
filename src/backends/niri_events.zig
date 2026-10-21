//! What kind of record a niri IPC line is.
//!
//! niri tags a line with the event name as its **single outer key** —
//! `{"WorkspacesChanged":{"workspaces":[...]}}`, `{"WindowClosed":7}` — not
//! with a `"type"` field. An object with one key is therefore the whole
//! discriminator; anything else is a reply shape or something this shell has
//! no name for, and both sort into `.unknown` rather than being guessed at.

const std = @import("std");

pub const Kind = enum { overview, workspaces, windows, quit, unknown };

pub fn classify(obj: std.json.Value) Kind {
    if (obj != .object) return .unknown;
    if (obj.object.count() != 1) return .unknown;
    var it = obj.object.iterator();
    const first = it.next() orelse return .unknown;
    const key = first.key_ptr.*;
    if (std.mem.eql(u8, key, "OverviewOpenedOrClosed")) return .overview;
    if (std.mem.eql(u8, key, "WorkspacesChanged")) return .workspaces;
    if (std.mem.eql(u8, key, "WindowsChanged")) return .windows;
    if (std.mem.eql(u8, key, "Quit")) return .quit;
    return .unknown;
}

test "niri-events: classify reads the outer key, not a type field" {
    const t = std.testing;

    const tagged = try std.json.parseFromSlice(std.json.Value, t.allocator,
        \\{"WorkspacesChanged":{"workspaces":[]}}
    , .{});
    defer tagged.deinit();
    try t.expectEqual(Kind.workspaces, classify(tagged.value));

    // The old shape this used to look for is not what niri puts on the wire,
    // and a reply with a bare `Ok` key stays unknown either way.
    const typed = try std.json.parseFromSlice(std.json.Value, t.allocator, "{\"type\":\"WorkspacesChanged\"}", .{});
    defer typed.deinit();
    try t.expectEqual(Kind.unknown, classify(typed.value));

    const reply = try std.json.parseFromSlice(std.json.Value, t.allocator, "{\"Ok\":null}", .{});
    defer reply.deinit();
    try t.expectEqual(Kind.unknown, classify(reply.value));

    // Two keys means this is not a tagged event at all.
    const doubled = try std.json.parseFromSlice(std.json.Value, t.allocator,
        \\{"Quit":null,"WindowsChanged":{"windows":[]}}
    , .{});
    defer doubled.deinit();
    try t.expectEqual(Kind.unknown, classify(doubled.value));

    const nope = try std.json.parseFromSlice(std.json.Value, t.allocator, "{\"SomethingNew\":1}", .{});
    defer nope.deinit();
    try t.expectEqual(Kind.unknown, classify(nope.value));

    const arr = try std.json.parseFromSlice(std.json.Value, t.allocator, "[]", .{});
    defer arr.deinit();
    try t.expectEqual(Kind.unknown, classify(arr.value));
}
