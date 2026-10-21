//! Temporary probe: what does the distro-logo resolver see on this box?
const std = @import("std");
const os_logo = @import("desktop_shell/common/os_logo.zig");
const icon_raster = @import("desktop_shell/common/icon_raster.zig");

test "probe distro logo resolution" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var info = os_logo.readOsRelease(alloc, io) orelse {
        std.debug.print("PROBE: no os-release\n", .{});
        return;
    };
    defer os_logo.freeOsRelease(alloc, &info);
    std.debug.print("PROBE: id='{s}' logo='{s}' id_like='{s}'\n", .{ info.id, info.logo, info.id_like });

    if (os_logo.resolveLogoPath(alloc, info)) |p| {
        defer alloc.free(p);
        std.debug.print("PROBE: path='{s}'\n", .{p});
    } else {
        std.debug.print("PROBE: path=none\n", .{});
    }

    var px = os_logo.loadDistroLogo(alloc, io, 48) orelse {
        std.debug.print("PROBE: load=none\n", .{});
        return;
    };
    defer icon_raster.freePixels(alloc, &px);
    std.debug.print("PROBE: px {d}x{d} bytes={d}\n", .{ px.w, px.h, px.data.len });
    var vis: usize = 0;
    var i: usize = 3;
    while (i < px.data.len) : (i += 4) {
        if (px.data[i] > 8) vis += 1;
    }
    std.debug.print("PROBE: vis-ish pixels={d}/{d}\n", .{ vis, px.data.len / 4 });
    // Does it look like the Fedora mark (blue-ish, one dominant hue)?
    var r_sum: usize = 0;
    var g_sum: usize = 0;
    var b_sum: usize = 0;
    i = 0;
    while (i < px.data.len) : (i += 4) {
        if (px.data[i + 3] > 8) {
            r_sum += px.data[i];
            g_sum += px.data[i + 1];
            b_sum += px.data[i + 2];
        }
    }
    if (vis > 0) {
        std.debug.print("PROBE: mean rgb=({d},{d},{d})\n", .{ r_sum / vis, g_sum / vis, b_sum / vis });
    }
}
