const std = @import("std");

pub const MsgType = enum(u8) {
    invalid = 0,
    method_call = 1,
    method_return = 2,
    @"error" = 3,
    signal = 4,
};

pub const Flags = struct {
    pub const no_reply_expected: u8 = 0x01;
    pub const no_auto_start: u8 = 0x02;
    pub const allow_interactive_auth: u8 = 0x04;
};

pub const protocol_version: u8 = 1;
pub const max_message: usize = 16 << 20;

pub const FieldCode = struct {
    pub const path: u8 = 1;
    pub const interface: u8 = 2;
    pub const member: u8 = 3;
    pub const error_name: u8 = 4;
    pub const reply_serial: u8 = 5;
    pub const destination: u8 = 6;
    pub const sender: u8 = 7;
    pub const signature: u8 = 8;
    pub const unix_fds: u8 = 9;
};

pub const WireError = error{
    BadSignature,
    SignatureTooLong,
    NestingTooDeep,
    BadObjectPath,
    BadString,
    MessageTooLarge,
    Truncated,
    BadEndian,
    BadVersion,
    OutOfMemory,
};

pub const Value = union(enum) {
    byte: u8,
    boolean: bool,
    int16: i16,
    uint16: u16,
    int32: i32,
    uint32: u32,
    int64: i64,
    uint64: u64,
    double: f64,
    string: []const u8,
    object_path: []const u8,
    signature: []const u8,
    unix_fd: u32,
    array: Array,
    structure: []Value,
    variant: Variant,

    pub const Array = struct {
        elem: []const u8,
        items: []Value,
    };
    pub const Variant = struct {
        sig: []const u8,
        val: *Value,
    };
};

pub fn baseAlignment(c: u8) WireError!usize {
    return switch (c) {
        'y', 'v' => 1,
        'b', 'i', 'u', 'h', 's', 'o', 'g' => 4,
        'n', 'q' => 2,
        'x', 't', 'd', 'r', 'e', '(', ')', '{', '}' => 8,
        'a' => 4,
        else => WireError.BadSignature,
    };
}

pub fn valueAlignmentOf(sig: []const u8) WireError!usize {
    if (sig.len == 0) return WireError.BadSignature;
    const c = sig[0];
    if (c == '(' or c == '{') return 8;
    // Arrays (dicts included) start with a UINT32 length: alignment 4. Only
    // the *entries* inside `a{...}` are 8-aligned, and the dict reader pads
    // for those explicitly. Returning 8 here misaligned every array value
    // sitting at offset % 8 ∉ {0, 4} (found live against BlueZ
    // `GetManagedObjects`, whose `a{sv}` variant values routinely land
    // there).
    if (c == 'a') return 4;
    return baseAlignment(c);
}

pub const SigParser = struct {
    s: []const u8,
    pos: usize = 0,
    depth: usize = 0,

    pub fn checkFull(sig: []const u8) WireError!void {
        if (sig.len > 255) return WireError.SignatureTooLong;
        var p = SigParser{ .s = sig };
        while (p.pos < p.s.len) try p.checkOne();
    }

    fn checkOne(p: *SigParser) WireError!void {
        if (p.pos >= p.s.len) return WireError.BadSignature;
        const c = p.s[p.pos];
        p.pos += 1;
        switch (c) {
            'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 'h', 's', 'o', 'g', 'v' => {},
            'a' => {
                if (p.depth >= 64) return WireError.NestingTooDeep;
                p.depth += 1;
                defer p.depth -= 1;
                if (p.pos < p.s.len and p.s[p.pos] == '{') {
                    try p.checkDictEntry();
                } else {
                    try p.checkOne();
                }
            },
            '(' => {
                if (p.depth >= 64) return WireError.NestingTooDeep;
                p.depth += 1;
                defer p.depth -= 1;
                if (p.pos >= p.s.len) return WireError.BadSignature;
                while (p.pos < p.s.len and p.s[p.pos] != ')') try p.checkOne();
                if (p.pos >= p.s.len) return WireError.BadSignature;
                p.pos += 1;
            },
            '{' => try p.checkDictEntry(),
            else => return WireError.BadSignature,
        }
    }

    fn checkDictEntry(p: *SigParser) WireError!void {
        if (p.pos >= p.s.len or p.s[p.pos] != '{') return WireError.BadSignature;
        p.pos += 1;
        if (p.depth >= 64) return WireError.NestingTooDeep;
        p.depth += 1;
        defer p.depth -= 1;
        try p.checkOne();
        try p.checkOne();
        if (p.pos >= p.s.len or p.s[p.pos] != '}') return WireError.BadSignature;
        p.pos += 1;
    }
};

pub fn findSigEnd(sig: []const u8, start: usize) usize {
    var i = start;
    if (i >= sig.len) return sig.len;
    const c = sig[i];
    i += 1;
    if (c == 'a') {
        if (i < sig.len and sig[i] == '{') {
            var depth: usize = 0;
            while (i < sig.len) : (i += 1) {
                if (sig[i] == '{') depth += 1;
                if (sig[i] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        i += 1;
                        break;
                    }
                }
            }
            return i;
        }
        return findSigEnd(sig, i);
    }
    if (c == '(') {
        var depth: usize = 1;
        while (i < sig.len and depth > 0) : (i += 1) {
            if (sig[i] == '(') depth += 1;
            if (sig[i] == ')') depth -= 1;
        }
        return i;
    }
    return i;
}

pub fn checkObjectPath(p: []const u8) WireError!void {
    if (p.len == 0 or p[0] != '/') return WireError.BadObjectPath;
    if (p.len > 1 and p[p.len - 1] == '/') return WireError.BadObjectPath;
    var i: usize = 1;
    var elem_len: usize = 0;
    while (i < p.len) : (i += 1) {
        const c = p[i];
        if (c == '/') {
            if (elem_len == 0) return WireError.BadObjectPath;
            elem_len = 0;
            continue;
        }
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return WireError.BadObjectPath;
        elem_len += 1;
    }
}

pub const Writer = struct {
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Writer {
        return .{ .buf = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.alloc);
    }

    pub fn bytes(self: *const Writer) []const u8 {
        return self.buf.items;
    }

    fn padTo(self: *Writer, al: usize) !void {
        const m = self.buf.items.len % al;
        if (m != 0) try self.buf.appendNTimes(self.alloc, 0, al - m);
    }

    pub fn u8v(self: *Writer, v: u8) !void {
        try self.buf.append(self.alloc, v);
    }

    pub fn u16v(self: *Writer, v: u16) !void {
        try self.padTo(2);
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .little);
        try self.buf.appendSlice(self.alloc, &b);
    }

    pub fn u32v(self: *Writer, v: u32) !void {
        try self.padTo(4);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.buf.appendSlice(self.alloc, &b);
    }

    pub fn u64v(self: *Writer, v: u64) !void {
        try self.padTo(8);
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try self.buf.appendSlice(self.alloc, &b);
    }

    pub fn stringv(self: *Writer, s: []const u8) !void {
        for (s) |c| if (c == 0) return WireError.BadString;
        try self.u32v(@intCast(s.len));
        try self.buf.appendSlice(self.alloc, s);
        try self.buf.append(self.alloc, 0);
    }

    pub fn objectPathv(self: *Writer, s: []const u8) !void {
        try checkObjectPath(s);
        try self.stringv(s);
    }

    pub fn signaturev(self: *Writer, s: []const u8) !void {
        try SigParser.checkFull(s);
        try self.buf.append(self.alloc, @intCast(s.len));
        try self.buf.appendSlice(self.alloc, s);
        try self.buf.append(self.alloc, 0);
    }

    pub fn aligned(self: *Writer, esig: []const u8, item: Value) WireError!void {
        try self.padTo(try valueAlignmentOf(esig));
        var p: usize = 0;
        try self.value(esig, &p, item);
        if (p != esig.len) return WireError.BadSignature;
    }

    pub fn value(self: *Writer, sig: []const u8, pos: *usize, v: Value) WireError!void {
        if (pos.* >= sig.len) return WireError.BadSignature;
        const c = sig[pos.*];
        pos.* += 1;
        switch (c) {
            'y' => try self.u8v(v.byte),
            'b' => try self.u32v(if (v.boolean) 1 else 0),
            'n' => {
                try self.padTo(2);
                var b: [2]u8 = undefined;
                std.mem.writeInt(i16, &b, v.int16, .little);
                try self.buf.appendSlice(self.alloc, &b);
            },
            'q' => try self.u16v(v.uint16),
            'i' => {
                try self.padTo(4);
                var b: [4]u8 = undefined;
                std.mem.writeInt(i32, &b, v.int32, .little);
                try self.buf.appendSlice(self.alloc, &b);
            },
            'u' => try self.u32v(v.uint32),
            'h' => try self.u32v(v.unix_fd),
            'x' => {
                try self.padTo(8);
                var b: [8]u8 = undefined;
                std.mem.writeInt(i64, &b, v.int64, .little);
                try self.buf.appendSlice(self.alloc, &b);
            },
            't' => try self.u64v(v.uint64),
            'd' => {
                try self.padTo(8);
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, @bitCast(v.double), .little);
                try self.buf.appendSlice(self.alloc, &b);
            },
            's' => try self.stringv(v.string),
            'o' => try self.objectPathv(v.object_path),
            'g' => try self.signaturev(v.signature),
            'v' => {
                try self.signaturev(v.variant.sig);
                try self.aligned(v.variant.sig, v.variant.val.*);
            },
            'a' => {
                try self.u32v(0);
                const start = self.buf.items.len - 4;
                if (pos.* < sig.len and sig[pos.*] == '{') {
                    pos.* += 1;
                    const key_end = findSigEnd(sig, pos.*);
                    const val_end = findSigEnd(sig, key_end);
                    if (val_end >= sig.len or sig[val_end] != '}') return WireError.BadSignature;
                    const ksig = sig[pos.*..key_end];
                    const vsig = sig[key_end..val_end];
                    pos.* = val_end + 1;
                    try self.padTo(8);
                    const data_start = self.buf.items.len;
                    for (v.array.items) |item| {
                        if (item != .structure or item.structure.len != 2) return WireError.BadSignature;
                        try self.padTo(8);
                        try self.aligned(ksig, item.structure[0]);
                        try self.aligned(vsig, item.structure[1]);
                    }
                    const arr_len: u32 = @intCast(self.buf.items.len - data_start);
                    std.mem.writeInt(u32, self.buf.items[start..][0..4], arr_len, .little);
                } else {
                    const elem_end = findSigEnd(sig, pos.*);
                    const esig = sig[pos.*..elem_end];
                    pos.* = elem_end;
                    try self.padTo(try valueAlignmentOf(esig));
                    const data_start = self.buf.items.len;
                    for (v.array.items) |item| try self.aligned(esig, item);
                    const arr_len: u32 = @intCast(self.buf.items.len - data_start);
                    std.mem.writeInt(u32, self.buf.items[start..][0..4], arr_len, .little);
                }
            },
            '(' => {
                try self.padTo(8);
                for (v.structure) |item| {
                    if (pos.* >= sig.len or sig[pos.*] == ')') return WireError.BadSignature;
                    const end = findSigEnd(sig, pos.*);
                    try self.aligned(sig[pos.*..end], item);
                    pos.* = end;
                }
                if (pos.* >= sig.len or sig[pos.*] != ')') return WireError.BadSignature;
                pos.* += 1;
            },
            else => return WireError.BadSignature,
        }
    }
};

pub const Message = struct {
    mtype: MsgType,
    flags: u8 = 0,
    serial: u32 = 0,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    err_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    unix_fds: ?u32 = null,
    signature: []const u8 = "",
    body: []const Value = &.{},
};

fn writeField(w: *Writer, code: u8, vsig: []const u8, v: Value) WireError!void {
    try w.padTo(8);
    try w.u8v(code);
    try w.signaturev(vsig);
    try w.aligned(vsig, v);
}

pub fn marshal(alloc: std.mem.Allocator, msg: Message) WireError![]u8 {
    try SigParser.checkFull(msg.signature);
    var out = Writer.init(alloc);
    errdefer out.deinit();
    try out.u8v('l');
    try out.u8v(@intFromEnum(msg.mtype));
    try out.u8v(msg.flags);
    try out.u8v(protocol_version);

    var body = Writer.init(alloc);
    defer body.deinit();
    var bp: usize = 0;
    var bi: usize = 0;
    while (bp < msg.signature.len) {
        const end = findSigEnd(msg.signature, bp);
        if (bi >= msg.body.len) return WireError.BadSignature;
        try body.aligned(msg.signature[bp..end], msg.body[bi]);
        bi += 1;
        bp = end;
    }
    if (bi != msg.body.len) return WireError.BadSignature;
    try out.u32v(@intCast(body.bytes().len));
    try out.u32v(msg.serial);

    const flen_pos = out.buf.items.len;
    try out.u32v(0);
    if (msg.path) |p| try writeField(&out, FieldCode.path, "o", .{ .object_path = p });
    if (msg.interface) |p| try writeField(&out, FieldCode.interface, "s", .{ .string = p });
    if (msg.member) |p| try writeField(&out, FieldCode.member, "s", .{ .string = p });
    if (msg.err_name) |p| try writeField(&out, FieldCode.error_name, "s", .{ .string = p });
    if (msg.reply_serial) |r| try writeField(&out, FieldCode.reply_serial, "u", .{ .uint32 = r });
    if (msg.destination) |p| try writeField(&out, FieldCode.destination, "s", .{ .string = p });
    if (msg.sender) |p| try writeField(&out, FieldCode.sender, "s", .{ .string = p });
    if (msg.signature.len > 0) try writeField(&out, FieldCode.signature, "g", .{ .signature = msg.signature });
    if (msg.unix_fds) |n| try writeField(&out, FieldCode.unix_fds, "u", .{ .uint32 = n });
    const flen: u32 = @intCast(out.buf.items.len - (flen_pos + 4));
    std.mem.writeInt(u32, out.buf.items[flen_pos..][0..4], flen, .little);

    try out.padTo(8);
    try out.buf.appendSlice(alloc, body.bytes());
    if (out.buf.items.len > max_message) return WireError.MessageTooLarge;
    const res = try alloc.dupe(u8, out.buf.items);
    out.deinit();
    return res;
}

/// Deep-copy `v` into `alloc` (strings, signatures, array items, structures
/// and variant boxes included) so the copy outlives the `Parsed` arena it
/// was read from. Free the result with `freeValue(alloc, v)`.
pub fn cloneValue(alloc: std.mem.Allocator, v: Value) WireError!Value {
    return switch (v) {
        .string => |s| .{ .string = try alloc.dupe(u8, s) },
        .object_path => |s| .{ .object_path = try alloc.dupe(u8, s) },
        .signature => |s| .{ .signature = try alloc.dupe(u8, s) },
        .array => |a| blk: {
            const elem = try alloc.dupe(u8, a.elem);
            errdefer alloc.free(elem);
            const items = try alloc.alloc(Value, a.items.len);
            var n: usize = 0;
            errdefer {
                for (items[0..n]) |it| freeValue(alloc, it);
                alloc.free(items);
            }
            for (a.items, 0..) |it, i| {
                items[i] = try cloneValue(alloc, it);
                n = i + 1;
            }
            break :blk .{ .array = .{ .elem = elem, .items = items } };
        },
        .structure => |s| blk: {
            const items = try alloc.alloc(Value, s.len);
            var n: usize = 0;
            errdefer {
                for (items[0..n]) |it| freeValue(alloc, it);
                alloc.free(items);
            }
            for (s, 0..) |it, i| {
                items[i] = try cloneValue(alloc, it);
                n = i + 1;
            }
            break :blk .{ .structure = items };
        },
        .variant => |x| blk: {
            const sig = try alloc.dupe(u8, x.sig);
            errdefer alloc.free(sig);
            const box = try alloc.create(Value);
            errdefer alloc.destroy(box);
            box.* = try cloneValue(alloc, x.val.*);
            break :blk .{ .variant = .{ .sig = sig, .val = box } };
        },
        else => v,
    };
}

pub fn freeValue(alloc: std.mem.Allocator, v: Value) void {
    switch (v) {
        .array => |a| {
            for (a.items) |it| freeValue(alloc, it);
            alloc.free(a.items);
            alloc.free(a.elem);
        },
        .structure => |s| {
            for (s) |it| freeValue(alloc, it);
            alloc.free(s);
        },
        .variant => |x| {
            alloc.free(x.sig);
            freeValue(alloc, x.val.*);
            alloc.destroy(x.val);
        },
        .string => |s| alloc.free(s),
        .object_path => |s| alloc.free(s),
        .signature => |s| alloc.free(s),
        else => {},
    }
}

pub const Reader = struct {
    buf: []const u8,
    pos: *usize,
    alloc: std.mem.Allocator,

    fn need(self: *Reader, n: usize) WireError!void {
        if (self.pos.* + n > self.buf.len) return WireError.Truncated;
    }

    fn padTo(self: *Reader, al: usize) WireError!void {
        const m = self.pos.* % al;
        if (m != 0) {
            try self.need(al - m);
            self.pos.* += al - m;
        }
    }

    pub fn u8v(self: *Reader) WireError!u8 {
        try self.need(1);
        const v = self.buf[self.pos.*];
        self.pos.* += 1;
        return v;
    }

    pub fn u16v(self: *Reader) WireError!u16 {
        try self.padTo(2);
        try self.need(2);
        const v = std.mem.readInt(u16, self.buf[self.pos.*..][0..2], .little);
        self.pos.* += 2;
        return v;
    }

    pub fn u32v(self: *Reader) WireError!u32 {
        try self.padTo(4);
        try self.need(4);
        const v = std.mem.readInt(u32, self.buf[self.pos.*..][0..4], .little);
        self.pos.* += 4;
        return v;
    }

    pub fn u64v(self: *Reader) WireError!u64 {
        try self.padTo(8);
        try self.need(8);
        const v = std.mem.readInt(u64, self.buf[self.pos.*..][0..8], .little);
        self.pos.* += 8;
        return v;
    }

    pub fn stringv(self: *Reader) WireError![]u8 {
        const len = try self.u32v();
        if (len > max_message) return WireError.MessageTooLarge;
        try self.need(len + 1);
        const s = try self.alloc.dupe(u8, self.buf[self.pos.* .. self.pos.* + len]);
        errdefer self.alloc.free(s);
        if (self.buf[self.pos.* + len] != 0) return WireError.BadString;
        for (s) |c| if (c == 0) return WireError.BadString;
        self.pos.* += len + 1;
        return s;
    }

    pub fn signaturev(self: *Reader) WireError![]u8 {
        const len = try self.u8v();
        try self.need(len + 1);
        const s = try self.alloc.dupe(u8, self.buf[self.pos.* .. self.pos.* + len]);
        errdefer self.alloc.free(s);
        if (self.buf[self.pos.* + len] != 0) return WireError.BadString;
        try SigParser.checkFull(s);
        self.pos.* += len + 1;
        return s;
    }

    pub fn readVariant(self: *Reader) WireError!Value {
        const sig = try self.signaturev();
        errdefer self.alloc.free(sig);
        try self.padTo(try valueAlignmentOf(sig));
        var r = Reader{ .buf = self.buf, .pos = self.pos, .alloc = self.alloc };
        var p: usize = 0;
        const v = try r.readValue(sig, &p);
        errdefer freeValue(self.alloc, v);
        if (p != sig.len) {
            freeValue(self.alloc, v);
            return WireError.BadSignature;
        }
        const box = try self.alloc.create(Value);
        box.* = v;
        return .{ .variant = .{ .sig = sig, .val = box } };
    }

    pub fn aligned(self: *Reader, esig: []const u8) WireError!Value {
        try self.padTo(try valueAlignmentOf(esig));
        var p: usize = 0;
        const v = try self.readValue(esig, &p);
        errdefer freeValue(self.alloc, v);
        if (p != esig.len) {
            freeValue(self.alloc, v);
            return WireError.BadSignature;
        }
        return v;
    }

    pub fn readValue(self: *Reader, sig: []const u8, pos: *usize) WireError!Value {
        if (pos.* >= sig.len) return WireError.BadSignature;
        const c = sig[pos.*];
        pos.* += 1;
        switch (c) {
            'y' => return .{ .byte = try self.u8v() },
            'b' => return .{ .boolean = (try self.u32v()) != 0 },
            'n' => {
                try self.padTo(2);
                try self.need(2);
                const v = std.mem.readInt(i16, self.buf[self.pos.*..][0..2], .little);
                self.pos.* += 2;
                return .{ .int16 = v };
            },
            'q' => return .{ .uint16 = try self.u16v() },
            'i' => {
                try self.padTo(4);
                try self.need(4);
                const v = std.mem.readInt(i32, self.buf[self.pos.*..][0..4], .little);
                self.pos.* += 4;
                return .{ .int32 = v };
            },
            'u' => return .{ .uint32 = try self.u32v() },
            'h' => return .{ .unix_fd = try self.u32v() },
            'x' => {
                try self.padTo(8);
                try self.need(8);
                const v = std.mem.readInt(i64, self.buf[self.pos.*..][0..8], .little);
                self.pos.* += 8;
                return .{ .int64 = v };
            },
            't' => return .{ .uint64 = try self.u64v() },
            'd' => {
                try self.padTo(8);
                try self.need(8);
                const bits = std.mem.readInt(u64, self.buf[self.pos.*..][0..8], .little);
                self.pos.* += 8;
                return .{ .double = @bitCast(bits) };
            },
            's' => return .{ .string = try self.stringv() },
            'o' => {
                const s = try self.stringv();
                errdefer self.alloc.free(s);
                try checkObjectPath(s);
                return .{ .object_path = s };
            },
            'g' => return .{ .signature = try self.signaturev() },
            'v' => return try self.readVariant(),
            'a' => {
                const alen = try self.u32v();
                if (alen > max_message) return WireError.MessageTooLarge;
                if (pos.* < sig.len and sig[pos.*] == '{') {
                    pos.* += 1;
                    const key_end = findSigEnd(sig, pos.*);
                    const val_end = findSigEnd(sig, key_end);
                    if (val_end >= sig.len or sig[val_end] != '}') return WireError.BadSignature;
                    const ksig = sig[pos.*..key_end];
                    const vsig = sig[key_end..val_end];
                    const esig = try std.fmt.allocPrint(self.alloc, "{{{s}{s}}}", .{ ksig, vsig });
                    errdefer self.alloc.free(esig);
                    pos.* = val_end + 1;
                    var items: std.ArrayList(Value) = .empty;
                    errdefer {
                        for (items.items) |it| freeValue(self.alloc, it);
                        items.deinit(self.alloc);
                    }
                    try self.padTo(8);
                    const end = self.pos.* + alen;
                    if (end > self.buf.len) return WireError.Truncated;
                    while (self.pos.* < end) {
                        try self.padTo(8);
                        const k = try self.aligned(ksig);
                        errdefer freeValue(self.alloc, k);
                        const v = try self.aligned(vsig);
                        errdefer freeValue(self.alloc, v);
                        const pair = try self.alloc.alloc(Value, 2);
                        pair[0] = k;
                        pair[1] = v;
                        try items.append(self.alloc, .{ .structure = pair });
                    }
                    if (self.pos.* != end) return WireError.BadSignature;
                    return .{ .array = .{ .elem = esig, .items = try items.toOwnedSlice(self.alloc) } };
                }
                const elem_end = findSigEnd(sig, pos.*);
                const esig = sig[pos.*..elem_end];
                pos.* = elem_end;
                var items: std.ArrayList(Value) = .empty;
                errdefer {
                    for (items.items) |it| freeValue(self.alloc, it);
                    items.deinit(self.alloc);
                }
                try self.padTo(try valueAlignmentOf(esig));
                const end = self.pos.* + alen;
                if (end > self.buf.len) return WireError.Truncated;
                while (self.pos.* < end) {
                    const item = try self.aligned(esig);
                    errdefer freeValue(self.alloc, item);
                    try items.append(self.alloc, item);
                }
                if (self.pos.* != end) return WireError.BadSignature;
                return .{ .array = .{ .elem = try self.alloc.dupe(u8, esig), .items = try items.toOwnedSlice(self.alloc) } };
            },
            '(' => {
                try self.padTo(8);
                var items: std.ArrayList(Value) = .empty;
                errdefer {
                    for (items.items) |it| freeValue(self.alloc, it);
                    items.deinit(self.alloc);
                }
                while (pos.* < sig.len and sig[pos.*] != ')') {
                    const end = findSigEnd(sig, pos.*);
                    const item = try self.aligned(sig[pos.*..end]);
                    errdefer freeValue(self.alloc, item);
                    try items.append(self.alloc, item);
                    pos.* = end;
                }
                if (pos.* >= sig.len or sig[pos.*] != ')') return WireError.BadSignature;
                pos.* += 1;
                return .{ .structure = try items.toOwnedSlice(self.alloc) };
            },
            else => return WireError.BadSignature,
        }
    }
};

pub const Parsed = struct {
    msg: Message,
    body_vals: []Value,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *Parsed) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }
};

pub fn unmarshal(alloc: std.mem.Allocator, data: []const u8) WireError!Parsed {
    if (data.len < 16) return WireError.Truncated;
    if (data[0] != 'l') return WireError.BadEndian;
    if (data[1] > 4) return WireError.BadSignature;
    const mtype: MsgType = @enumFromInt(data[1]);
    const flags = data[2];
    if (data[3] != protocol_version) return WireError.BadVersion;
    const body_len = std.mem.readInt(u32, data[4..8], .little);
    const serial = std.mem.readInt(u32, data[8..12], .little);
    const flen = std.mem.readInt(u32, data[12..16], .little);
    if (16 + flen > data.len) return WireError.Truncated;
    var fpos: usize = 16;
    const fend = 16 + flen;

    const arena = alloc.create(std.heap.ArenaAllocator) catch return WireError.OutOfMemory;
    arena.* = std.heap.ArenaAllocator.init(alloc);
    errdefer {
        arena.deinit();
        alloc.destroy(arena);
    }
    const aa = arena.allocator();

    var msg = Message{ .mtype = mtype, .flags = flags, .serial = serial };
    while (fpos < fend) {
        const pad = (8 - (fpos % 8)) % 8;
        fpos += pad;
        if (fpos >= fend) break;
        if (fpos + 1 > data.len) return WireError.Truncated;
        const code = data[fpos];
        fpos += 1;
        var r = Reader{ .buf = data, .pos = &fpos, .alloc = aa };
        const v = try r.readVariant();
        const inner = v.variant.val.*;
        switch (code) {
            FieldCode.path => msg.path = inner.object_path,
            FieldCode.interface => msg.interface = inner.string,
            FieldCode.member => msg.member = inner.string,
            FieldCode.error_name => msg.err_name = inner.string,
            FieldCode.reply_serial => msg.reply_serial = inner.uint32,
            FieldCode.destination => msg.destination = inner.string,
            FieldCode.sender => msg.sender = inner.string,
            FieldCode.signature => msg.signature = inner.signature,
            FieldCode.unix_fds => msg.unix_fds = inner.uint32,
            else => {},
        }
    }
    var bpos: usize = fend + ((8 - (fend % 8)) % 8);
    var body: std.ArrayList(Value) = .empty;
    errdefer {
        for (body.items) |it| freeValue(aa, it);
        body.deinit(aa);
    }
    var sp: usize = 0;
    while (sp < msg.signature.len) {
        const end = findSigEnd(msg.signature, sp);
        const fsig = msg.signature[sp..end];
        sp = end;
        var r = Reader{ .buf = data, .pos = &bpos, .alloc = aa };
        const item = try r.aligned(fsig);
        errdefer freeValue(aa, item);
        try body.append(aa, item);
    }
    if (body_len > 0 and bpos > data.len) return WireError.Truncated;
    const vals = try aa.dupe(Value, body.items);
    body.deinit(aa);
    return .{ .msg = msg, .body_vals = vals, .arena = arena };
}

pub fn valueEql(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .byte => |x| return x == b.byte,
        .boolean => |x| return x == b.boolean,
        .int16 => |x| return x == b.int16,
        .uint16 => |x| return x == b.uint16,
        .int32 => |x| return x == b.int32,
        .uint32 => |x| return x == b.uint32,
        .int64 => |x| return x == b.int64,
        .uint64 => |x| return x == b.uint64,
        .double => |x| return x == b.double,
        .string => |x| return std.mem.eql(u8, x, b.string),
        .object_path => |x| return std.mem.eql(u8, x, b.object_path),
        .signature => |x| return std.mem.eql(u8, x, b.signature),
        .unix_fd => |x| return x == b.unix_fd,
        .array => |x| {
            if (x.items.len != b.array.items.len) return false;
            if (!std.mem.eql(u8, x.elem, b.array.elem)) return false;
            for (x.items, b.array.items) |ia, ib| {
                if (!valueEql(ia, ib)) return false;
            }
            return true;
        },
        .structure => |x| {
            if (x.len != b.structure.len) return false;
            for (x, b.structure) |ia, ib| {
                if (!valueEql(ia, ib)) return false;
            }
            return true;
        },
        .variant => |x| {
            if (!std.mem.eql(u8, x.sig, b.variant.sig)) return false;
            return valueEql(x.val.*, b.variant.val.*);
        },
    }
}

test "wire: signature validation" {
    const t = std.testing;
    try SigParser.checkFull("a{sv}");
    try SigParser.checkFull("(iiay)");
    try SigParser.checkFull("s");
    try SigParser.checkFull("");
    try t.expectError(WireError.BadSignature, SigParser.checkFull("a{sv"));
    try t.expectError(WireError.BadSignature, SigParser.checkFull("(ii"));
    try t.expectError(WireError.BadSignature, SigParser.checkFull("z"));
    try t.expectError(WireError.BadSignature, SigParser.checkFull("{sv}"));
}

test "wire: object path validation" {
    const t = std.testing;
    try checkObjectPath("/org/freedesktop/DBus");
    try checkObjectPath("/");
    try t.expectError(WireError.BadObjectPath, checkObjectPath(""));
    try t.expectError(WireError.BadObjectPath, checkObjectPath("nope"));
    try t.expectError(WireError.BadObjectPath, checkObjectPath("/trailing/"));
    try t.expectError(WireError.BadObjectPath, checkObjectPath("/double//slash"));
    try t.expectError(WireError.BadObjectPath, checkObjectPath("/bad-char!"));
}

test "wire: Hello method call golden bytes" {
    const t = std.testing;
    const msg = Message{
        .mtype = .method_call,
        .serial = 1,
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .member = "Hello",
    };
    const wire = try marshal(t.allocator, msg);
    defer t.allocator.free(wire);
    try t.expectEqual(@as(u8, 'l'), wire[0]);
    try t.expectEqual(@as(u8, 1), wire[1]);
    try t.expectEqual(@as(u8, 1), wire[3]);
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, wire[4..8], .little));
    try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, wire[8..12], .little));
    try t.expect(wire.len % 8 == 0);
    var p = try unmarshal(t.allocator, wire);
    defer p.deinit();
    try t.expectEqual(MsgType.method_call, p.msg.mtype);
    try t.expectEqual(@as(u32, 1), p.msg.serial);
    try t.expectEqualStrings("/org/freedesktop/DBus", p.msg.path.?);
    try t.expectEqualStrings("org.freedesktop.DBus", p.msg.interface.?);
    try t.expectEqualStrings("Hello", p.msg.member.?);
    try t.expectEqual(@as(usize, 0), p.body_vals.len);
}

test "wire: body round trip with nested types" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const body = try aa.alloc(Value, 4);
    body[0] = .{ .string = "hello" };
    body[1] = .{ .int32 = -5 };
    body[2] = .{ .array = .{ .elem = "s", .items = try aa.dupe(Value, &[_]Value{.{ .string = "a" }}) } };
    const vbox = try aa.create(Value);
    vbox.* = .{ .uint32 = 7 };
    body[3] = .{ .variant = .{ .sig = "u", .val = vbox } };
    const msg = Message{
        .mtype = .signal,
        .serial = 9,
        .path = "/t",
        .interface = "i.I",
        .member = "M",
        .signature = "siasv",
        .body = body,
    };
    const wire = try marshal(t.allocator, msg);
    defer t.allocator.free(wire);
    var p = try unmarshal(t.allocator, wire);
    defer p.deinit();
    try t.expectEqual(@as(usize, 4), p.body_vals.len);
    try t.expect(valueEql(body[0], p.body_vals[0]));
    try t.expect(valueEql(body[1], p.body_vals[1]));
    try t.expect(p.body_vals[2] == .array);
    try t.expect(p.body_vals[3] == .variant);
    try t.expectEqualStrings("u", p.body_vals[3].variant.sig);
    try t.expectEqual(@as(u32, 7), p.body_vals[3].variant.val.uint32);
}

test "wire: dict entry array round trip" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const mk = struct {
        fn pair(a: std.mem.Allocator, k: []const u8, v: u32) !Value {
            const p = try a.alloc(Value, 2);
            p[0] = .{ .string = k };
            const vb = try a.create(Value);
            vb.* = .{ .uint32 = v };
            p[1] = .{ .variant = .{ .sig = "u", .val = vb } };
            return .{ .structure = p };
        }
    };
    const items = try aa.alloc(Value, 2);
    items[0] = try mk.pair(aa, "a", 1);
    items[1] = try mk.pair(aa, "b", 2);
    const body = try aa.alloc(Value, 1);
    body[0] = .{ .array = .{ .elem = "{sv}", .items = items } };
    const msg = Message{
        .mtype = .method_return,
        .serial = 2,
        .reply_serial = 1,
        .signature = "a{sv}",
        .body = body,
    };
    const wire = try marshal(t.allocator, msg);
    defer t.allocator.free(wire);
    var p = try unmarshal(t.allocator, wire);
    defer p.deinit();
    try t.expectEqual(@as(usize, 1), p.body_vals.len);
    const arr = p.body_vals[0].array;
    try t.expectEqual(@as(usize, 2), arr.items.len);
    try t.expectEqualStrings("a", arr.items[0].structure[0].string);
    try t.expectEqualStrings("b", arr.items[1].structure[0].string);
}

test "wire: array values align to 4, not 8" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 4), try valueAlignmentOf("a{sv}"));
    try t.expectEqual(@as(usize, 4), try valueAlignmentOf("as"));
    try t.expectEqual(@as(usize, 4), try valueAlignmentOf("ao"));
    try t.expectEqual(@as(usize, 8), try valueAlignmentOf("(ii)"));
    try t.expectEqual(@as(usize, 8), try valueAlignmentOf("{sv}"));

    // A method_return with body "ya{sv}" hand-encoded per the spec: the
    // leading byte sits at offset 0, so the dict length lands at offset 4
    // (%8==4). The old reader aligned arrays to 8 and read the length at
    // offset 8 instead — live BlueZ `GetManagedObjects` replies routinely
    // land variant-wrapped dicts at such offsets and failed with
    // MessageTooLarge.
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(t.allocator);
    const ap = struct {
        fn b(l: *std.ArrayList(u8), a: std.mem.Allocator, v: []const u8) !void {
            try l.appendSlice(a, v);
        }
    }.b;
    try ap(&bytes, t.allocator, &.{ 'l', 2, 0, 1 });
    try ap(&bytes, t.allocator, &.{ 24, 0, 0, 0 }); // body_len
    try ap(&bytes, t.allocator, &.{ 9, 0, 0, 0 }); // serial
    try ap(&bytes, t.allocator, &.{ 20, 0, 0, 0 }); // flen: 8 + 12
    try ap(&bytes, t.allocator, &.{5}); // reply_serial field
    try ap(&bytes, t.allocator, &.{ 1, 'u', 0 });
    try ap(&bytes, t.allocator, &.{ 7, 0, 0, 0 });
    try ap(&bytes, t.allocator, &.{8}); // signature field
    try ap(&bytes, t.allocator, &.{ 1, 'g', 0, 6, 'y', 'a', '{', 's', 'v', '}', 0 });
    try ap(&bytes, t.allocator, &.{ 0, 0, 0, 0 }); // pad to 40
    try ap(&bytes, t.allocator, &.{0x42}); // byte
    try ap(&bytes, t.allocator, &.{ 0, 0, 0 }); // pad to 44
    try ap(&bytes, t.allocator, &.{ 16, 0, 0, 0 }); // dict len
    try ap(&bytes, t.allocator, &.{ 1, 0, 0, 0, 'k', 0 }); // key "k"
    try ap(&bytes, t.allocator, &.{ 1, 'u', 0 }); // variant sig "u"
    try ap(&bytes, t.allocator, &.{ 0, 0, 0 }); // pad to 60
    try ap(&bytes, t.allocator, &.{ 7, 0, 0, 0 }); // value
    try t.expectEqual(@as(usize, 64), bytes.items.len);
    var p = try unmarshal(t.allocator, bytes.items);
    defer p.deinit();
    try t.expectEqual(@as(usize, 2), p.body_vals.len);
    try t.expectEqual(@as(u8, 0x42), p.body_vals[0].byte);
    const arr = p.body_vals[1].array;
    try t.expectEqual(@as(usize, 1), arr.items.len);
    try t.expectEqualStrings("k", arr.items[0].structure[0].string);
    try t.expectEqual(@as(u32, 7), arr.items[0].structure[1].variant.val.uint32);
}

test "wire: cloneValue survives the source arena being freed" {
    const t = std.testing;
    var src = std.heap.ArenaAllocator.init(t.allocator);
    defer src.deinit();
    const sa = src.allocator();
    // Nested a{sv} dict shaped like MPRIS Metadata: array of {s,v} with a
    // variant-wrapped string inside.
    const inner = try sa.create(Value);
    inner.* = .{ .string = try sa.dupe(u8, "Never Gonna Give You Up") };
    const pair = try sa.alloc(Value, 2);
    pair[0] = .{ .string = try sa.dupe(u8, "xesam:title") };
    pair[1] = .{ .variant = .{ .sig = try sa.dupe(u8, "s"), .val = inner } };
    const items = try sa.alloc(Value, 1);
    items[0] = .{ .structure = pair };
    const dict = Value{ .array = .{ .elem = try sa.dupe(u8, "{sv}"), .items = items } };

    // Clone out, then blow away every byte of the source (this is what
    // `Parsed.deinit` does right after `propGet` returned the shallow copy —
    // the crash the dock hit in `dictFind` on MPRIS Metadata).
    const dup = try cloneValue(t.allocator, dict);
    defer freeValue(t.allocator, dup);
    src.deinit();
    src = std.heap.ArenaAllocator.init(t.allocator); // re-arm the defer

    try t.expectEqualStrings("Never Gonna Give You Up", dup.array.items[0].structure[1].variant.val.string);
    try t.expectEqualStrings("xesam:title", dup.array.items[0].structure[0].string);
}
