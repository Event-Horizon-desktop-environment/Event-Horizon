//! Shared 1 × 1
//! cairo context text is measured against.
//!
//! Pango needs a cairo context to measure a layout, and the widget widths
//! have to be computed without one of the real surfaces, so everything that
//! only needs a *size* measures here.

const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;

var g_surface: ?*cairo.cairo_surface_t = null;
var g_cr: ?*cairo.cairo_t = null;

/// The process-wide measuring context. Null only if cairo itself failed to
/// create an image surface, which callers treat as "no measurement".
pub fn measureCr() ?*cairo.cairo_t {
    if (g_cr) |cr| return cr;
    const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, 1, 1);
    if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    const cr = cairo.cairo_create(surf);
    if (cairo.cairo_status(cr) != cairo.CAIRO_STATUS_SUCCESS) {
        cairo.cairo_destroy(cr);
        cairo.cairo_surface_destroy(surf);
        return null;
    }
    g_surface = surf;
    g_cr = cr;
    return cr;
}

/// Drops the cached context. The widgets never call it — it exists so a
/// process that wants a clean slate (and the tests) can release cairo.
pub fn shutdown() void {
    if (g_cr) |cr| {
        cairo.cairo_destroy(cr);
        g_cr = null;
    }
    if (g_surface) |surf| {
        cairo.cairo_surface_destroy(surf);
        g_surface = null;
    }
}

test "measure-scratch: one shared context" {
    const t = std.testing;
    const a = measureCr();
    const b = measureCr();
    try t.expect(a != null);
    // Second call returns the same pointer rather than leaking a surface.
    try t.expect(a == b);
    try t.expect(cairo.cairo_status(a.?) == cairo.CAIRO_STATUS_SUCCESS);
}
