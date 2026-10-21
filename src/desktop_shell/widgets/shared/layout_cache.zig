//! One cached pango
//! layout per key.
//!
//! The cache clears itself whenever the font changes, so in practice it
//! holds a single entry; the map is kept because that is the contract the
//! header publishes (`get` may be called with many keys).

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");

const Entry = struct {
    layout: ?*text.PangoLayout = null,
    font_desc: []const u8 = "",
    font_px: i32 = 0,
};

pub const LayoutCache = struct {
    alloc: std.mem.Allocator,
    map: std.StringHashMap(Entry),
    last_font_px: i32 = 0,
    initialized: bool = false,

    pub fn init(alloc: std.mem.Allocator) LayoutCache {
        return .{ .alloc = alloc, .map = std.StringHashMap(Entry).init(alloc) };
    }

    pub fn deinit(self: *LayoutCache) void {
        self.clear();
        self.map.deinit();
    }

    /// The layout for `key`, rebuilt when the font description or pixel size
    /// differs. Returns null only when cairo could not create a layout.
    pub fn get(self: *LayoutCache, cr: ?*cairo.cairo_t, font_desc: []const u8, font_px: i32, key: []const u8) ?*text.PangoLayout {
        const c = cr orelse return null;

        if (self.map.get(key)) |e| {
            if (e.font_px == font_px and std.mem.eql(u8, e.font_desc, font_desc)) {
                if (e.layout) |lo| {
                    text.pango_cairo_update_layout(c, lo);
                    return lo;
                }
            }
        }
        // Font changed (or nothing cached yet): drop everything and start
        // over, which is what makes the map hold at most one entry.
        self.clear();

        // Pango wants NUL-terminated strings, so go through the `Layout`
        // wrapper rather than handing it a raw slice pointer.
        var built = text.Layout.createForCairo(c);
        built.setFont(font_desc);
        const layout = built.layout;

        const key_copy = self.alloc.dupe(u8, key) catch {
            built.destroy();
            return null;
        };
        const desc_copy = self.alloc.dupe(u8, font_desc) catch {
            self.alloc.free(key_copy);
            built.destroy();
            return null;
        };
        self.map.put(key_copy, .{ .layout = layout, .font_desc = desc_copy, .font_px = font_px }) catch {
            self.alloc.free(key_copy);
            self.alloc.free(desc_copy);
            built.destroy();
            return null;
        };
        self.last_font_px = font_px;
        return layout;
    }

    pub fn clear(self: *LayoutCache) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.layout) |lo| text.Layout.release(lo);
            self.alloc.free(e.value_ptr.font_desc);
            self.alloc.free(e.key_ptr.*);
        }
        self.map.clearRetainingCapacity();
    }
};

test "layout-cache: reuse on the same font, rebuild on change" {
    const t = std.testing;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 1, 1);
    defer cairo.cairo_surface_destroy(surf);
    const cr = cairo.cairo_create(surf);
    defer cairo.cairo_destroy(cr);

    var lc = LayoutCache.init(t.allocator);
    defer lc.deinit();

    const a = lc.get(cr, "Inter 12", 12, "clock").?;
    const b = lc.get(cr, "Inter 12", 12, "clock").?;
    try t.expect(a == b);
    try t.expectEqual(@as(usize, 1), lc.map.count());

    // A different size invalidates the cache. The pointer is *not* compared
    // here: cairo is likely to hand the same address straight back after the
    // old layout is freed, so the observable difference is the cache state.
    // A different size invalidates the cache. The pointer is *not* compared
    // here: cairo is likely to hand the same address straight back after the
    // old layout is freed, so the observable difference is the cache state.
    try t.expect(lc.get(cr, "Inter 14", 14, "clock") != null);
    try t.expectEqual(@as(i32, 14), lc.last_font_px);
    try t.expectEqual(@as(usize, 1), lc.map.count());
    try t.expectEqualStrings("Inter 14", lc.map.get("clock").?.font_desc);

    // A second key evicts the first.
    try t.expect(lc.get(cr, "Inter 14", 14, "weather") != null);
    try t.expectEqual(@as(usize, 1), lc.map.count());
    try t.expect(lc.map.get("clock") == null);

    lc.clear();
    try t.expectEqual(@as(usize, 0), lc.map.count());

    // A null context yields no layout instead of crashing.
    try t.expect(lc.get(null, "Inter 12", 12, "clock") == null);
    // …and it left the cache untouched.
    try t.expectEqual(@as(usize, 0), lc.map.count());
}
