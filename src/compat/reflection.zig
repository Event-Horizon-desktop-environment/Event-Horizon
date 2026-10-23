//! Compile-time reflection that works with both Zig 0.16's
//! `std.builtin.Type` and Zig 0.17's `std.lang.Type`.
//!
//! 0.16 exposes `fields`, `decls`, and friends as arrays of structs. 0.17
//! splits the same data into parallel arrays (`field_names`, `field_types`,
//! `field_values`, ...). These helpers hide the difference.

const std = @import("std");

pub const StructField = struct {
    name: [:0]const u8,
    type: type,
};

pub const EnumField = struct {
    name: [:0]const u8,
    value: comptime_int,
};

pub fn structFieldCount(comptime T: type) usize {
    const info = @typeInfo(T).@"struct";
    return if (@hasField(@TypeOf(info), "fields")) info.fields.len else info.field_names.len;
}

pub fn structFields(comptime T: type) [structFieldCount(T)]StructField {
    const info = @typeInfo(T).@"struct";
    var out: [structFieldCount(T)]StructField = undefined;
    inline for (0..out.len) |i| {
        out[i] = if (@hasField(@TypeOf(info), "fields"))
            .{ .name = info.fields[i].name, .type = info.fields[i].type }
        else
            .{ .name = info.field_names[i], .type = info.field_types[i] };
    }
    return out;
}

pub fn enumFieldCount(comptime T: type) usize {
    const info = @typeInfo(T).@"enum";
    return if (@hasField(@TypeOf(info), "fields")) info.fields.len else info.field_names.len;
}

pub fn enumFields(comptime T: type) [enumFieldCount(T)]EnumField {
    const info = @typeInfo(T).@"enum";
    var out: [enumFieldCount(T)]EnumField = undefined;
    inline for (0..out.len) |i| {
        out[i] = if (@hasField(@TypeOf(info), "fields"))
            .{ .name = info.fields[i].name, .value = info.fields[i].value }
        else
            .{ .name = info.field_names[i], .value = info.field_values[i] };
    }
    return out;
}
