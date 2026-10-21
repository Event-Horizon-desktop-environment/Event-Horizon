const std = @import("std");

/// "Open With" dialog model.
/// Port of `entries/desktop_open_with.{hpp,cpp}` pure logic: mime detection
/// (extension fallback map), dialog geometry, row hit-testing, scroll clamp.
///
/// Card: `min(480*us, W-32*us) x Pad16+Top44+PadIn12+list+PadIn12+Bottom52+Pad16`,
/// rows `40*us`, list clamped to `320*us`, centered; header `Open With` 16 bold
/// + filename 12; bottom checkbox + `Cancel`/`Open` (`90x34*us` pills).

pub const row_h: f64 = 40.0;
pub const max_list_h: f64 = 320.0;
pub const card_w: f64 = 480.0;
pub const card_margin: f64 = 32.0;
pub const top_h: f64 = 44.0;
pub const bottom_h: f64 = 52.0;
pub const vpad: f64 = 16.0;
pub const inner_pad: f64 = 12.0;

/// Special hover indices (`OpenWithState.hoverIdx`): -2 close, -3 cancel,
/// -4 open, -5 default checkbox, >=0 app row.
pub const hover_close: i32 = -2;
pub const hover_cancel: i32 = -3;
pub const hover_open: i32 = -4;
pub const hover_default: i32 = -5;

pub fn cardWidth(layer_w: i32, us: f64) f64 {
    return @min(card_w * us, @as(f64, @floatFromInt(layer_w)) - card_margin * us);
}

pub fn listHeight(count: usize, us: f64) f64 {
    return @min(@as(f64, @floatFromInt(count)) * row_h * us, max_list_h * us);
}

pub fn cardHeight(count: usize, us: f64) f64 {
    return vpad * us + top_h * us + inner_pad * us + listHeight(count, us) + inner_pad * us + bottom_h * us + vpad * us;
}

/// Extension → mime fallback (`open_with_open`: `inode/x-empty|octet-stream`
/// goes through this map after `xdg-mime query filetype || file -b --mime`).
pub fn mimeForExtension(filename: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return "application/octet-stream";
    const ext = filename[dot..];
    var buf: [16]u8 = undefined;
    const n: usize = @min(ext.len, 16);
    for (0..n) |i| buf[i] = std.ascii.toLower(ext[i]);
    const e = buf[0..n];
    if (std.mem.eql(u8, e, ".txt") or std.mem.eql(u8, e, ".md") or std.mem.eql(u8, e, ".log")) return "text/plain";
    if (std.mem.eql(u8, e, ".html") or std.mem.eql(u8, e, ".htm")) return "text/html";
    if (std.mem.eql(u8, e, ".js")) return "text/javascript";
    if (std.mem.eql(u8, e, ".json")) return "application/json";
    if (std.mem.eql(u8, e, ".png")) return "image/png";
    if (std.mem.eql(u8, e, ".jpg") or std.mem.eql(u8, e, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, e, ".pdf")) return "application/pdf";
    if (std.mem.eql(u8, e, ".mp3")) return "audio/mpeg";
    if (std.mem.eql(u8, e, ".mp4")) return "video/mp4";
    if (std.mem.eql(u8, e, ".zip")) return "application/zip";
    if (std.mem.eql(u8, e, ".gz") or std.mem.eql(u8, e, ".tgz")) return "application/gzip";
    if (std.mem.eql(u8, e, ".tar")) return "application/x-tar";
    if (std.mem.eql(u8, e, ".7z")) return "application/x-7z-compressed";
    if (std.mem.eql(u8, e, ".rar")) return "application/vnd.rar";
    return "application/octet-stream";
}

/// Scroll by wheel: `delta = dy/EntryH || ±1`, clamped to `[0, count-visible]`.
pub fn scrollBy(offset: i32, dy: f64, count: usize, visible: usize) i32 {
    const step: i32 = if (dy != 0) @intFromFloat(@trunc(dy / row_h)) else 0;
    const d: i32 = if (step != 0) step else (if (dy > 0) 1 else if (dy < 0) -1 else 0);
    const max_off: i32 = @max(0, @as(i32, @intCast(count)) - @as(i32, @intCast(visible)));
    return std.math.clamp(offset + d, 0, max_off);
}

/// `gtk-launch id uri &` one-liner used on row activate.
pub fn gtkLaunchCmd(alloc: std.mem.Allocator, desktop_id: []const u8, file_uri: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "gtk-launch {s} {s} &", .{ desktop_id, file_uri });
}

/// `xdg-mime default id.desktop mime`.
pub fn setDefaultCmd(alloc: std.mem.Allocator, desktop_id: []const u8, mime: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "xdg-mime default {s}.desktop {s}", .{ desktop_id, mime });
}

/// Parse `mimeinfo.cache` / `mimeapps.list` lines for one mime:
/// `text/plain=firefox.desktop;code.desktop;` -> ids in order.
/// Comment/`#`/empty lines skipped; section must match when given.
pub fn parseMimeAssociations(alloc: std.mem.Allocator, text: []const u8, mime: []const u8, section: ?[]const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var cur_section: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, std.mem.trimEnd(u8, raw, "\r"), " \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            cur_section = line[1 .. line.len - 1];
            continue;
        }
        if (section) |want| {
            if (cur_section == null or !std.mem.eql(u8, cur_section.?, want)) continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, key, mime)) continue;
        var ids = std.mem.splitScalar(u8, line[eq + 1 ..], ';');
        while (ids.next()) |id| {
            const clean = std.mem.trim(u8, id, " \t");
            if (clean.len == 0) continue;
            // Strip trailing `.desktop` for `gtk-launch` id form.
            const stem = if (std.mem.endsWith(u8, clean, ".desktop")) clean[0 .. clean.len - 8] else clean;
            var dup = false;
            for (out.items) |have| {
                if (std.mem.eql(u8, have, stem)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) try out.append(alloc, stem);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Partition app ids into recommended (exact mime match) vs other (family).
/// `exact` is the ordered exact list; `family` the fallback list.
/// Returns split index: first `n` of `joined` are recommended.
pub fn partitionRecommended(ids: []const []const u8, exact: []const []const u8) usize {
    var n: usize = 0;
    for (ids) |id| {
        for (exact) |e| {
            if (std.mem.eql(u8, id, e)) {
                n += 1;
                break;
            }
        }
    }
    return n;
}

test "open_with: mime + geometry + scroll" {
    const t = std.testing;
    try t.expectEqualStrings("text/plain", mimeForExtension("a.TXT"));
    try t.expectEqualStrings("image/png", mimeForExtension("a.png"));
    try t.expectEqualStrings("application/octet-stream", mimeForExtension("a.unknownext"));
    try t.expectApproxEqAbs(@as(f64, 3 * 40), listHeight(3, 1.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 320), listHeight(100, 1.0), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 480), cardWidth(1920, 1.0), 1e-9);
    try t.expect(scrollBy(0, 80, 10, 5) > 0);
    try t.expectEqual(@as(i32, 0), scrollBy(0, -80, 10, 5));
    const c = try gtkLaunchCmd(t.allocator, "firefox", "file:///a");
    defer t.allocator.free(c);
    try t.expectEqualStrings("gtk-launch firefox file:///a &", c);
}

test "open_with: mime associations parse + partition" {
    const t = std.testing;
    const text = "[MIME Cache]\ntext/plain=firefox.desktop;code.desktop;\nimage/png=firefox.desktop;\n";
    const ids = try parseMimeAssociations(t.allocator, text, "text/plain", "MIME Cache");
    defer t.allocator.free(ids);
    try t.expectEqual(@as(usize, 2), ids.len);
    try t.expectEqualStrings("firefox", ids[0]);
    const apps = [_][]const u8{ "firefox", "gimp" };
    const exact = [_][]const u8{"firefox"};
    try t.expectEqual(@as(usize, 1), partitionRecommended(&apps, &exact));
}
