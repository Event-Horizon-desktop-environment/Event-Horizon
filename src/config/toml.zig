const std = @import("std");

pub const ParseError = error{
    BadSyntax,
    BadString,
    BadNumber,
    BadDate,
    DuplicateKey,
    OutOfMemory,
};

pub const Value = union(enum) {
    boolean: bool,
    integer: i64,
    float: f64,
    string: []u8,
    array: []Value,
    table: Table,

    pub const Table = std.StringHashMap(Value);
};

pub const Doc = struct {
    arena: *std.heap.ArenaAllocator,
    root: Value.Table,

    pub fn deinit(self: *Doc) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }

    pub fn table(self: *const Doc, name: []const u8) ?*const Value {
        const e = self.root.getEntry(name) orelse return null;
        if (e.value_ptr.* != .table) return null;
        return e.value_ptr;
    }

    pub fn get(self: *const Doc, name: []const u8) ?Value {
        return self.root.get(name);
    }
};

pub fn parse(alloc: std.mem.Allocator, text: []const u8) ParseError!Doc {
    const arena = alloc.create(std.heap.ArenaAllocator) catch return ParseError.OutOfMemory;
    arena.* = std.heap.ArenaAllocator.init(alloc);
    errdefer {
        arena.deinit();
        alloc.destroy(arena);
    }
    const aa = arena.allocator();
    var p = Parser{ .text = text, .alloc = aa };
    var root = Value.Table.init(aa);
    var cur: *Value.Table = &root;
    while (true) {
        p.skipWsAndComments();
        if (p.eof()) break;
        if (p.peek() == '[') {
            p.pos += 1;
            if (!p.eof() and p.peek() == '[') {
                p.pos += 1;
                const path = try p.parseKeyPath();
                p.skipWs();
                try p.expect(']');
                try p.expect(']');
                p.skipWsAndComments();
                cur = try navigateArrayTable(aa, &root, path);
            } else {
                const path = try p.parseKeyPath();
                p.skipWs();
                try p.expect(']');
                p.skipWsAndComments();
                cur = try navigateTable(aa, &root, path, false);
            }
        } else {
            const key = try p.parseKey();
            p.skipWs();
            try p.expect('=');
            p.skipWs();
            const val = try p.parseValue();
            p.skipWsAndComments();
            const entry = try cur.getOrPut(key);
            if (entry.found_existing) return ParseError.DuplicateKey;
            entry.key_ptr.* = key;
            entry.value_ptr.* = val;
        }
    }
    return .{ .arena = arena, .root = root };
}

fn navigateTable(aa: std.mem.Allocator, root: *Value.Table, path: []const []const u8, _: bool) ParseError!*Value.Table {
    var cur = root;
    for (path) |part| {
        const entry = try cur.getOrPut(part);
        if (!entry.found_existing) {
            entry.key_ptr.* = part;
            entry.value_ptr.* = .{ .table = Value.Table.init(aa) };
        } else if (entry.value_ptr.* != .table) {
            return ParseError.DuplicateKey;
        }
        cur = &entry.value_ptr.table;
    }
    return cur;
}

fn navigateArrayTable(aa: std.mem.Allocator, root: *Value.Table, path: []const []const u8) ParseError!*Value.Table {
    var cur = root;
    for (path[0 .. path.len - 1]) |part| {
        const entry = try cur.getOrPut(part);
        if (!entry.found_existing) {
            entry.key_ptr.* = part;
            entry.value_ptr.* = .{ .table = Value.Table.init(aa) };
        } else if (entry.value_ptr.* != .table) {
            return ParseError.DuplicateKey;
        }
        cur = &entry.value_ptr.table;
    }
    const last = path[path.len - 1];
    const entry = try cur.getOrPut(last);
    if (!entry.found_existing) {
        entry.key_ptr.* = last;
        entry.value_ptr.* = .{ .array = &.{} };
    }
    if (entry.value_ptr.* != .array) return ParseError.DuplicateKey;
    const old = entry.value_ptr.array;
    const backing = try aa.alloc(Value, old.len + 1);
    @memcpy(backing[0..old.len], old);
    if (old.len > 0) aa.free(old);
    backing[old.len] = .{ .table = Value.Table.init(aa) };
    entry.value_ptr.array = backing;
    return &entry.value_ptr.array[old.len].table;
}

const Parser = struct {
    text: []const u8,
    pos: usize = 0,
    alloc: std.mem.Allocator,

    fn eof(p: *Parser) bool {
        return p.pos >= p.text.len;
    }

    fn peek(p: *Parser) u8 {
        return p.text[p.pos];
    }

    fn skipWs(p: *Parser) void {
        while (!p.eof() and (p.peek() == ' ' or p.peek() == '\t')) p.pos += 1;
    }

    fn skipWsAndComments(p: *Parser) void {
        while (!p.eof()) {
            const c = p.peek();
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                p.pos += 1;
            } else if (c == '#') {
                while (!p.eof() and p.peek() != '\n') p.pos += 1;
            } else break;
        }
    }

    fn expect(p: *Parser, c: u8) ParseError!void {
        if (p.eof() or p.peek() != c) return ParseError.BadSyntax;
        p.pos += 1;
    }

    fn parseKey(p: *Parser) ParseError![]const u8 {
        p.skipWs();
        if (p.eof()) return ParseError.BadSyntax;
        if (p.peek() == '"' or p.peek() == '\'') {
            return p.parseBasicString();
        }
        const start = p.pos;
        while (!p.eof()) {
            const c = p.peek();
            if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-') {
                p.pos += 1;
            } else break;
        }
        if (p.pos == start) return ParseError.BadSyntax;
        return p.alloc.dupe(u8, p.text[start..p.pos]) catch ParseError.OutOfMemory;
    }

    fn parseKeyPath(p: *Parser) ParseError![][]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        errdefer parts.deinit(p.alloc);
        while (true) {
            const k = try p.parseKey();
            try parts.append(p.alloc, k);
            p.skipWs();
            if (!p.eof() and p.peek() == '.') {
                p.pos += 1;
                p.skipWs();
                continue;
            }
            break;
        }
        return parts.toOwnedSlice(p.alloc);
    }

    fn parseValue(p: *Parser) ParseError!Value {
        if (p.eof()) return ParseError.BadSyntax;
        const c = p.peek();
        if (c == '"') {
            if (p.pos + 2 < p.text.len and p.text[p.pos + 1] == '"' and p.text[p.pos + 2] == '"') {
                return p.parseMultilineString();
            }
            const s = try p.parseBasicString();
            return .{ .string = s };
        }
        if (c == '\'') {
            if (p.pos + 2 < p.text.len and p.text[p.pos + 1] == '\'' and p.text[p.pos + 2] == '\'') {
                return p.parseMultilineLiteral();
            }
            const s = try p.parseLiteralString();
            return .{ .string = s };
        }
        if (c == '[') return p.parseArray();
        if (c == '{') return p.parseInlineTable();
        if (c == 't' or c == 'f') return p.parseBool();
        if (c == 'i' or c == 'n') return p.parseInfNan();
        if (c == '-' or c == '+' or (c >= '0' and c <= '9')) return p.parseNumber();
        return ParseError.BadSyntax;
    }

    fn parseBasicString(p: *Parser) ParseError![]u8 {
        try p.expect('"');
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(p.alloc);
        while (!p.eof()) {
            const c = p.peek();
            if (c == '"') {
                p.pos += 1;
                return out.toOwnedSlice(p.alloc);
            }
            if (c == '\\') {
                p.pos += 1;
                if (p.eof()) return ParseError.BadString;
                const e = p.peek();
                p.pos += 1;
                switch (e) {
                    'b' => try out.append(p.alloc, 0x08),
                    'f' => try out.append(p.alloc, 0x0C),
                    'n' => try out.append(p.alloc, '\n'),
                    'r' => try out.append(p.alloc, '\r'),
                    't' => try out.append(p.alloc, '\t'),
                    '"' => try out.append(p.alloc, '"'),
                    '\\' => try out.append(p.alloc, '\\'),
                    'u' => {
                        const cp = try p.parseHex(4);
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch return ParseError.BadString;
                        try out.appendSlice(p.alloc, buf[0..n]);
                    },
                    'U' => {
                        const cp = try p.parseHex(8);
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch return ParseError.BadString;
                        try out.appendSlice(p.alloc, buf[0..n]);
                    },
                    else => return ParseError.BadString,
                }
                continue;
            }
            if (c == '\n') return ParseError.BadString;
            p.pos += 1;
            try out.append(p.alloc, c);
        }
        return ParseError.BadString;
    }

    fn parseHex(p: *Parser, n: usize) ParseError!u21 {
        if (p.pos + n > p.text.len) return ParseError.BadString;
        const v = std.fmt.parseInt(u21, p.text[p.pos .. p.pos + n], 16) catch return ParseError.BadString;
        p.pos += n;
        return v;
    }

    fn parseLiteralString(p: *Parser) ParseError![]u8 {
        try p.expect('\'');
        const start = p.pos;
        while (!p.eof() and p.peek() != '\'') {
            if (p.peek() == '\n') return ParseError.BadString;
            p.pos += 1;
        }
        if (p.eof()) return ParseError.BadString;
        const s = try p.alloc.dupe(u8, p.text[start..p.pos]);
        p.pos += 1;
        return s;
    }

    fn parseMultilineString(p: *Parser) ParseError!Value {
        p.pos += 3;
        if (!p.eof() and p.peek() == '\n') p.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(p.alloc);
        while (!p.eof()) {
            if (p.pos + 2 < p.text.len and p.text[p.pos] == '"' and p.text[p.pos + 1] == '"' and p.text[p.pos + 2] == '"') {
                p.pos += 3;
                return .{ .string = try out.toOwnedSlice(p.alloc) };
            }
            if (p.peek() == '\\' and p.pos + 1 < p.text.len and (p.text[p.pos + 1] == '\n' or p.text[p.pos + 1] == ' ' or p.text[p.pos + 1] == '\t')) {
                p.pos += 1;
                while (!p.eof() and (p.peek() == ' ' or p.peek() == '\t' or p.peek() == '\n' or p.peek() == '\r')) p.pos += 1;
                continue;
            }
            if (p.peek() == '\\') {
                p.pos += 1;
                if (p.eof()) return ParseError.BadString;
                const e = p.peek();
                p.pos += 1;
                switch (e) {
                    'n' => try out.append(p.alloc, '\n'),
                    't' => try out.append(p.alloc, '\t'),
                    'r' => try out.append(p.alloc, '\r'),
                    '"' => try out.append(p.alloc, '"'),
                    '\\' => try out.append(p.alloc, '\\'),
                    else => return ParseError.BadString,
                }
                continue;
            }
            try out.append(p.alloc, p.peek());
            p.pos += 1;
        }
        return ParseError.BadString;
    }

    fn parseMultilineLiteral(p: *Parser) ParseError!Value {
        p.pos += 3;
        if (!p.eof() and p.peek() == '\n') p.pos += 1;
        const start = p.pos;
        while (p.pos + 2 < p.text.len) {
            if (p.text[p.pos] == '\'' and p.text[p.pos + 1] == '\'' and p.text[p.pos + 2] == '\'') {
                const s = try p.alloc.dupe(u8, p.text[start..p.pos]);
                p.pos += 3;
                return .{ .string = s };
            }
            p.pos += 1;
        }
        return ParseError.BadString;
    }

    fn parseArray(p: *Parser) ParseError!Value {
        try p.expect('[');
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(p.alloc);
        while (true) {
            p.skipWsAndComments();
            if (p.eof()) return ParseError.BadSyntax;
            if (p.peek() == ']') {
                p.pos += 1;
                return .{ .array = try items.toOwnedSlice(p.alloc) };
            }
            const v = try p.parseValue();
            try items.append(p.alloc, v);
            p.skipWsAndComments();
            if (p.eof()) return ParseError.BadSyntax;
            if (p.peek() == ',') {
                p.pos += 1;
                continue;
            }
            if (p.peek() == ']') {
                p.pos += 1;
                return .{ .array = try items.toOwnedSlice(p.alloc) };
            }
            return ParseError.BadSyntax;
        }
    }

    fn parseInlineTable(p: *Parser) ParseError!Value {
        try p.expect('{');
        var tbl = Value.Table.init(p.alloc);
        while (true) {
            p.skipWs();
            if (p.eof()) return ParseError.BadSyntax;
            if (p.peek() == '}') {
                p.pos += 1;
                return .{ .table = tbl };
            }
            const key = try p.parseKey();
            p.skipWs();
            try p.expect('=');
            p.skipWs();
            const val = try p.parseValue();
            const entry = try tbl.getOrPut(key);
            if (entry.found_existing) return ParseError.DuplicateKey;
            entry.key_ptr.* = key;
            entry.value_ptr.* = val;
            p.skipWs();
            if (p.eof()) return ParseError.BadSyntax;
            if (p.peek() == ',') {
                p.pos += 1;
                continue;
            }
            if (p.peek() == '}') {
                p.pos += 1;
                return .{ .table = tbl };
            }
            return ParseError.BadSyntax;
        }
    }

    fn parseBool(p: *Parser) ParseError!Value {
        if (std.mem.startsWith(u8, p.text[p.pos..], "true")) {
            p.pos += 4;
            return .{ .boolean = true };
        }
        if (std.mem.startsWith(u8, p.text[p.pos..], "false")) {
            p.pos += 5;
            return .{ .boolean = false };
        }
        return ParseError.BadSyntax;
    }

    fn parseInfNan(p: *Parser) ParseError!Value {
        for ([_][]const u8{ "inf", "+inf", "-inf", "nan", "+nan", "-nan" }) |lit| {
            if (std.mem.startsWith(u8, p.text[p.pos..], lit)) {
                p.pos += lit.len;
                const neg = lit[0] == '-';
                const is_inf = std.mem.indexOfScalar(u8, lit, 'i') != null;
                if (is_inf) return .{ .float = if (neg) -std.math.inf(f64) else std.math.inf(f64) };
                return .{ .float = std.math.nan(f64) };
            }
        }
        return ParseError.BadSyntax;
    }

    fn parseNumber(p: *Parser) ParseError!Value {
        const start = p.pos;
        if (!p.eof() and (p.peek() == '+' or p.peek() == '-')) p.pos += 1;
        if (p.pos + 1 < p.text.len and p.text[p.pos] == '0' and (p.text[p.pos + 1] == 'x' or p.text[p.pos + 1] == 'X')) {
            p.pos += 2;
            const ds = p.pos;
            while (!p.eof() and std.ascii.isHex(p.peek())) p.pos += 1;
            const v = std.fmt.parseInt(i64, p.text[start..p.pos], 0) catch return ParseError.BadNumber;
            _ = ds;
            return .{ .integer = v };
        }
        var is_float = false;
        while (!p.eof()) {
            const c = p.peek();
            if (c >= '0' and c <= '9') {
                p.pos += 1;
            } else if (c == '.' or c == 'e' or c == 'E') {
                is_float = true;
                p.pos += 1;
            } else if ((c == '+' or c == '-') and p.pos > start and (p.text[p.pos - 1] == 'e' or p.text[p.pos - 1] == 'E')) {
                p.pos += 1;
            } else break;
        }
        const tok = p.text[start..p.pos];
        if (tok.len == 0) return ParseError.BadSyntax;
        if (is_float) {
            const v = std.fmt.parseFloat(f64, tok) catch return ParseError.BadNumber;
            return .{ .float = v };
        }
        if (tok.len >= 10) {
            const as_date = looksLikeDate(tok);
            if (as_date) return ParseError.BadDate;
        }
        const v = std.fmt.parseInt(i64, tok, 10) catch return ParseError.BadNumber;
        return .{ .integer = v };
    }

    fn looksLikeDate(tok: []const u8) bool {
        if (tok.len < 10) return false;
        return tok[4] == '-' and tok[7] == '-';
    }
};

fn tab(t: std.mem.Allocator, tbl: *const Value.Table, key: []const u8) *const Value.Table {
    _ = t;
    const e = tbl.getEntry(key) orelse unreachable;
    return &e.value_ptr.table;
}

test "toml: basic table decode" {
    const t = std.testing;
    var doc = try parse(t.allocator,
        \\# comment
        \\renderer = "vulkan"
        \\count = 42
        \\ratio = 1.5
        \\flag = true
        \\[dock]
        \\icon_size = 64
        \\autohide = false
        \\pinned = ["a", "b"]
        \\
    );
    defer doc.deinit();
    try t.expectEqualStrings("vulkan", doc.root.get("renderer").?.string);
    try t.expectEqual(@as(i64, 42), doc.root.get("count").?.integer);
    try t.expectEqual(@as(f64, 1.5), doc.root.get("ratio").?.float);
    try t.expect(doc.root.get("flag").?.boolean);
    const dock = tab(t.allocator, &doc.root, "dock");
    try t.expectEqual(@as(i64, 64), dock.get("icon_size").?.integer);
    try t.expect(!dock.get("autohide").?.boolean);
    try t.expectEqual(@as(usize, 2), dock.get("pinned").?.array.len);
}

test "toml: dotted tables, nesting, escapes" {
    const t = std.testing;
    var doc = try parse(t.allocator,
        \\[notifications.rules.work]
        \\match = "x"
        \\show_toast = false
        \\[a.b.c]
        \\v = "a\nb\t\"q\"\\"
        \\
    );
    defer doc.deinit();
    const rules = tab(t.allocator, tab(t.allocator, tab(t.allocator, &doc.root, "notifications"), "rules"), "work");
    try t.expectEqualStrings("x", rules.get("match").?.string);
    try t.expect(!rules.get("show_toast").?.boolean);
    try t.expectEqualStrings("a\nb\t\"q\"\\", tab(t.allocator, tab(t.allocator, tab(t.allocator, &doc.root, "a"), "b"), "c").get("v").?.string);
}

test "toml: arrays multiline, inline tables, literals" {
    const t = std.testing;
    var doc = try parse(t.allocator,
        \\list = [
        \\  "x",
        \\  'y',
        \\]
        \\point = { x = 1, y = 2 }
        \\n = -17
        \\f = 2e3
        \\
    );
    defer doc.deinit();
    try t.expectEqual(@as(usize, 2), doc.root.get("list").?.array.len);
    try t.expectEqual(@as(i64, 1), tab(t.allocator, &doc.root, "point").get("x").?.integer);
    try t.expectEqual(@as(i64, -17), doc.root.get("n").?.integer);
    try t.expectEqual(@as(f64, 2000.0), doc.root.get("f").?.float);
}

test "toml: rejections" {
    const t = std.testing;
    try t.expectError(ParseError.DuplicateKey, parse(t.allocator, "a = 1\na = 2\n"));
    try t.expectError(ParseError.BadSyntax, parse(t.allocator, "a = \n"));
    try t.expectError(ParseError.BadString, parse(t.allocator, "a = \"oops\n\"\n"));
}
