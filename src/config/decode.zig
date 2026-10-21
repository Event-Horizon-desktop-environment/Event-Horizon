const std = @import("std");
const toml = @import("toml.zig");

pub const T = toml.Value.Table;
pub const V = toml.Value;

pub fn childTbl(t: *const T, key: []const u8) ?*const T {
    const e = t.getEntry(key) orelse return null;
    if (e.value_ptr.* != .table) return null;
    return &e.value_ptr.table;
}

pub fn getBool(t: *const T, key: []const u8) ?bool {
    const v = t.get(key) orelse return null;
    if (v != .boolean) return null;
    return v.boolean;
}

pub fn getStr(t: *const T, key: []const u8) ?[]const u8 {
    const v = t.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

pub fn getInt(t: *const T, key: []const u8) ?i64 {
    const v = t.get(key) orelse return null;
    if (v != .integer) return null;
    return v.integer;
}

pub fn getFloat(t: *const T, key: []const u8) ?f64 {
    const v = t.get(key) orelse return null;
    if (v == .float) return v.float;
    if (v == .integer) return @floatFromInt(v.integer);
    return null;
}

pub fn getFloatStrict(t: *const T, key: []const u8) ?f64 {
    const v = t.get(key) orelse return null;
    if (v != .float) return null;
    return v.float;
}

pub fn clampI(v: i64, lo: i64, hi: i64) i64 {
    return @max(lo, @min(hi, v));
}

pub fn clampI32(v: i64, lo: i64, hi: i64) i32 {
    return @intCast(@max(lo, @min(hi, v)));
}

pub fn clampF(v: f64, lo: f64, hi: f64) f32 {
    return @floatCast(@max(lo, @min(hi, v)));
}

pub fn setBool(t: *const T, key: []const u8, field: *bool) void {
    if (getBool(t, key)) |v| field.* = v;
}

pub fn setInt(t: *const T, key: []const u8, field: *i32, lo: i64, hi: i64) void {
    if (getInt(t, key)) |v| field.* = clampI32(v, lo, hi);
}

pub fn setStr(alloc: std.mem.Allocator, t: *const T, key: []const u8, field: *[]const u8) !void {
    if (getStr(t, key)) |v| {
        if (field.*.len > 0) alloc.free(field.*);
        field.* = try alloc.dupe(u8, v);
    }
}

pub fn setStrArray(alloc: std.mem.Allocator, t: *const T, key: []const u8, field: *[][]const u8) !void {
    const v = t.get(key) orelse return;
    if (v != .array) return;
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    for (v.array) |item| {
        if (item != .string) continue;
        try out.append(alloc, try alloc.dupe(u8, item.string));
    }
    if (field.*.len > 0) {
        for (field.*) |s| alloc.free(s);
        alloc.free(field.*);
    }
    field.* = try out.toOwnedSlice(alloc);
}

pub fn setScale(t: *const T, key: []const u8, field: *f64) void {
    if (getFloatStrict(t, key)) |d| {
        if (std.math.isFinite(d)) field.* = @max(0.5, @min(2.0, d));
        return;
    }
    if (getInt(t, key)) |i| field.* = @max(0.5, @min(2.0, @as(f64, @floatFromInt(i))));
}

pub fn setOpacity(t: *const T, key: []const u8, field: *f32) void {
    if (getFloatStrict(t, key)) |d| {
        field.* = clampF(d, 0.0, 1.0);
        return;
    }
    if (getInt(t, key)) |i| field.* = clampF(@as(f64, @floatFromInt(i)) / 100.0, 0.0, 1.0);
}

/// The overlay-opacity keys, same shapes as `setOpacity` but with a 2.0
/// ceiling: they store the *multiplier* on a surface's designed body alpha,
/// where 1.0 is the design and the Appearance page writes `1 / design` (up
/// to ~1.82) for a fully opaque body. See `overlay.zig`'s `designAlpha`.
pub fn setOverlayOpacity(t: *const T, key: []const u8, field: *f32) void {
    if (getFloatStrict(t, key)) |d| {
        field.* = clampF(d, 0.0, 2.0);
        return;
    }
    if (getInt(t, key)) |i| field.* = clampF(@as(f64, @floatFromInt(i)) / 100.0, 0.0, 2.0);
}
