//! ClipStack capture policy — which offered mimes become a history entry,
//! how entries are classified, and which selections are secrets.
//!
//! The policy is deliberately a pure function of the advertised mime list so
//! both the daemon and the tests exercise the same code without Wayland.

const std = @import("std");
const clipboard = @import("../wl/input/clipboard.zig");
const store = @import("store.zig");

pub const mime_png = "image/png";
pub const mime_gnome = clipboard.mime_gnome_files;
pub const mime_uri_list = clipboard.mime_uri_list;
pub const mime_utf8 = clipboard.mime_utf8;
pub const mime_plain = clipboard.mime_plain;
pub const mime_utf8_string = clipboard.mime_utf8_string;

/// Mimes captured from an offer, in the order they are read. Image first
/// (an image copy that also carries a text representation should keep the
/// image), then file lists, then text. Text mimes are all captured so a
/// paste target that asks for `UTF8_STRING` or plain `text/plain` still
/// finds bytes.
pub const priority = [_][]const u8{
    mime_png,
    mime_gnome,
    mime_uri_list,
    mime_utf8,
    mime_plain,
    mime_utf8_string,
};

/// Never capture more than this many mimes in one entry.
pub const max_mimes = priority.len;

/// Byte ceiling for one transfer while capturing. Clipboard services cap
/// their reads at 4 MiB (the C++ `receive_offer_as_mime` ceiling, preserved
/// by `Service.receivePump`); history capture needs the whole PNG, so it
/// raises the cap through `Service.receiveCapped`.
pub const capture_ceiling: usize = store.limits.entry_bytes;

pub fn offered(mimes: []const []const u8, want: []const u8) bool {
    for (mimes) |m| {
        if (std.mem.eql(u8, m, want)) return true;
    }
    return false;
}

fn containsCi(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Password managers mark their offers with a mime containing
/// `passwordManagerHint` (KDE's is `x-kde-passwordManagerHint`, value
/// `secret`). Those selections are owned and held like any other, but never
/// recorded — history must not outlive the paste.
pub fn isSecret(mimes: []const []const u8) bool {
    for (mimes) |m| {
        if (containsCi(m, "passwordManagerHint")) return true;
        if (containsCi(m, "x-kde-password")) return true;
    }
    return false;
}

/// Classify by the mimes actually captured (not the full offer).
pub fn kindFor(mimes: []const []const u8) store.Kind {
    var has_image = false;
    var has_files = false;
    var has_text = false;
    for (mimes) |m| {
        if (std.mem.eql(u8, m, mime_png) or std.mem.startsWith(u8, m, "image/")) has_image = true;
        if (std.mem.eql(u8, m, mime_gnome) or std.mem.eql(u8, m, mime_uri_list)) has_files = true;
        if (std.mem.eql(u8, m, mime_utf8) or std.mem.eql(u8, m, mime_plain) or
            std.mem.eql(u8, m, mime_utf8_string)) has_text = true;
    }
    // A copied image from a browser often also offers text/html and a text
    // fallback; the image is the intent, so it wins over text. File lists
    // win over text the same way.
    if (has_image) return .image;
    if (has_files) return .files;
    if (has_text) return .text;
    return .other;
}

/// Select up to `out.len` offered mimes in `priority` order. Returns the
/// count; entries are slices borrowed from `mimes`.
pub fn selectMimes(mimes: []const []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    const cap = @min(out.len, max_mimes);
    for (priority) |want| {
        if (n >= cap) break;
        if (offered(mimes, want)) {
            out[n] = want;
            n += 1;
        }
    }
    return n;
}

test "clipstack capture: selectMimes follows priority and drops duplicates" {
    const t = std.testing;
    const offer = [_][]const u8{ "text/plain", "text/html", "image/png", "text/plain;charset=utf-8" };
    var out: [max_mimes][]const u8 = undefined;
    const n = selectMimes(&offer, &out);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqualStrings(mime_png, out[0]);
    try t.expectEqualStrings(mime_utf8, out[1]);
    try t.expectEqualStrings(mime_plain, out[2]);

    const files = [_][]const u8{ "text/uri-list", "x-special/gnome-copied-files" };
    const n2 = selectMimes(&files, &out);
    try t.expectEqual(@as(usize, 2), n2);
    try t.expectEqualStrings(mime_gnome, out[0]);
    try t.expectEqualStrings(mime_uri_list, out[1]);
}

test "clipstack capture: kindFor prefers image, then files, then text" {
    const t = std.testing;
    try t.expectEqual(store.Kind.image, kindFor(&[_][]const u8{ "image/png", "text/plain" }));
    try t.expectEqual(store.Kind.files, kindFor(&[_][]const u8{ "text/uri-list", "text/plain" }));
    try t.expectEqual(store.Kind.files, kindFor(&[_][]const u8{"x-special/gnome-copied-files"}));
    try t.expectEqual(store.Kind.text, kindFor(&[_][]const u8{ "text/plain;charset=utf-8", "text/plain" }));
    try t.expectEqual(store.Kind.other, kindFor(&[_][]const u8{"application/pdf"}));
}

test "clipstack capture: password hints are recognized case-insensitively" {
    const t = std.testing;
    try t.expect(isSecret(&[_][]const u8{ "text/plain", "x-kde-passwordManagerHint" }));
    try t.expect(isSecret(&[_][]const u8{"x-special/application/x-kde-passwordmanagerhint"}));
    try t.expect(isSecret(&[_][]const u8{"application/x-kde-password"}));
    try t.expect(!isSecret(&[_][]const u8{ "text/plain", "text/html" }));
    try t.expect(!isSecret(&[_][]const u8{}));
}

test "clipstack capture: offered checks exact match only" {
    const t = std.testing;
    try t.expect(offered(&[_][]const u8{"text/plain"}, "text/plain"));
    try t.expect(!offered(&[_][]const u8{"text/plain"}, "text/plain;charset=utf-8"));
}
