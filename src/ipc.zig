const std = @import("std");

pub const frame_magic: u8 = 0xE7;
pub const protocol_version: u8 = 1;
pub const max_frame_body: u32 = 1 << 20;
pub const max_legacy_cmd: u16 = 4096;

pub const FrameType = enum(u8) {
    request = 1,
    response = 2,
    event = 3,
    ack = 4,
    subscribe = 5,
    unsubscribe = 6,
};

pub const flag_fd: u32 = 1 << 0;

pub const IpcHeader = packed struct {
    version: u8,
    type: u8,
    flags: u32,
    id: u64,
};

comptime {
    std.debug.assert(@bitSizeOf(IpcHeader) == 112);
}

pub const header_size: usize = 14;

fn writeHeader(dst: *[14]u8, h: IpcHeader) void {
    dst[0] = h.version;
    dst[1] = h.type;
    std.mem.writeInt(u32, dst[2..6], h.flags, .little);
    std.mem.writeInt(u64, dst[6..14], h.id, .little);
}

fn readHeader(src: *const [14]u8) IpcHeader {
    return .{
        .version = src[0],
        .type = src[1],
        .flags = std.mem.readInt(u32, src[2..6], .little),
        .id = std.mem.readInt(u64, src[6..14], .little),
    };
}

pub const Frame = struct {
    header: IpcHeader,
    body: []u8,
};

pub const DecodeError = error{
    NeedMoreData,
    BadMagic,
    FrameTooLarge,
    HeaderTooSmall,
};

pub fn encodeFrame(gpa: std.mem.Allocator, frame: Frame) ![]u8 {
    const total_len: u32 = @intCast(header_size + frame.body.len);
    var out = try gpa.alloc(u8, 5 + total_len);
    out[0] = frame_magic;
    std.mem.writeInt(u32, out[1..5], total_len, .little);
    writeHeader(out[5 .. 5 + header_size], frame.header);
    @memcpy(out[5 + header_size ..], frame.body);
    return out;
}

pub const DecodeResult = struct {
    frame: Frame,
    consumed: usize,
};

pub fn decodeFrame(gpa: std.mem.Allocator, data: []const u8) !DecodeResult {
    if (data.len == 0) return DecodeError.NeedMoreData;
    if (data[0] != frame_magic) return DecodeError.BadMagic;
    if (data.len < 5) return DecodeError.NeedMoreData;
    const frame_len = std.mem.readInt(u32, data[1..5], .little);
    if (frame_len < header_size or frame_len > max_frame_body + header_size)
        return DecodeError.FrameTooLarge;
    const total: usize = 5 + frame_len;
    if (data.len < total) return DecodeError.NeedMoreData;
    const hsrc: *const [14]u8 = @ptrCast(data[5 .. 5 + header_size]);
    const header = readHeader(hsrc);
    const body = try gpa.dupe(u8, data[5 + header_size .. total]);
    return .{ .frame = .{ .header = header, .body = body }, .consumed = total };
}

pub fn makeRequest(id: u64, command_line: []const u8) Frame {
    return .{
        .header = .{ .version = protocol_version, .type = @intFromEnum(FrameType.request), .flags = 0, .id = id },
        .body = @constCast(command_line),
    };
}

pub fn makeResponse(gpa: std.mem.Allocator, id: u64, body: []const u8) !Frame {
    return .{
        .header = .{ .version = protocol_version, .type = @intFromEnum(FrameType.response), .flags = 0, .id = id },
        .body = try gpa.dupe(u8, body),
    };
}

pub fn makeAck(id: u64) Frame {
    return .{
        .header = .{ .version = protocol_version, .type = @intFromEnum(FrameType.ack), .flags = 0, .id = id },
        .body = @constCast(&[_]u8{}),
    };
}

pub fn makeEvent(gpa: std.mem.Allocator, topic: []const u8, payload: []const u8) !Frame {
    var body = try gpa.alloc(u8, topic.len + 1 + payload.len);
    @memcpy(body[0..topic.len], topic);
    body[topic.len] = 0;
    @memcpy(body[topic.len + 1 ..], payload);
    return .{
        .header = .{ .version = protocol_version, .type = @intFromEnum(FrameType.event), .flags = 0, .id = 0 },
        .body = body,
    };
}

test "ipc: header is 14 packed bytes" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 112), @bitSizeOf(IpcHeader));
    try t.expectEqual(@as(usize, 14), header_size);
}

test "ipc: encode/decode round-trips" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const body = try gpa.dupe(u8, "ping");
    const wire = try encodeFrame(gpa, makeRequest(42, body));
    try t.expectEqual(frame_magic, wire[0]);

    const res = try decodeFrame(gpa, wire);
    defer gpa.free(res.frame.body);
    try t.expectEqual(res.consumed, wire.len);
    try t.expectEqual(@as(u64, 42), res.frame.header.id);
    try t.expectEqualStrings("ping", res.frame.body);
}

test "ipc: event body is topic NUL payload" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const f = try makeEvent(gpa, "workspaces", "{\"n\":2}");
    defer gpa.free(f.body);
    try t.expectEqualStrings("workspaces", f.body[0..10]);
    try t.expectEqual(@as(u8, 0), f.body[10]);
    try t.expectEqualStrings("{\"n\":2}", f.body[11..]);
}

test "ipc: truncated buffer needs more data" {
    const t = std.testing;
    const err = decodeFrame(t.allocator, &[_]u8{ frame_magic, 0x0E }) catch |e| e;
    try t.expectEqual(DecodeError.NeedMoreData, err);
}
