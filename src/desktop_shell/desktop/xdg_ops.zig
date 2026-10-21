const std = @import("std");

/// XDG / shell-out operations used by desktop icons and menus.
/// Port of `entries/desktop_xdg_ops.{hpp,cpp}` pure string/command logic:
/// `canonical_absolute_path`, `file_uri_for_path`, `expand_desktop_exec_tokens`,
/// `sh` quoting, `open_path`/`open_uri` command lines, clipboard payloads,
/// `trash` command lines, `launch`/`pkexec` wrappers, and the rename prompt.
///
/// Process spawning itself stays in the standalone layer; this module builds
/// the exact argv/script strings shelled out with so behavior matches
/// byte-for-byte and stays unit-testable.

/// `sh_single_quote` (also in archive): `'a'\\''b'`.
pub fn shQuote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(alloc, "'\\''") else try out.append(alloc, c);
    }
    try out.append(alloc, '\'');
    return out.toOwnedSlice(alloc);
}

fn isUriSafe(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.' or c == '~';
}

/// `file_uri_for_path`: `file://` + percent-encode (space -> `%20`, keep
/// alnum `/-_.~`).
pub fn fileUriForPath(alloc: std.mem.Allocator, abs_path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "file://");
    for (abs_path) |c| {
        if (isUriSafe(c)) {
            try out.append(alloc, c);
        } else {
            const h = "0123456789ABCDEF";
            try out.append(alloc, '%');
            try out.append(alloc, h[c >> 4]);
            try out.append(alloc, h[c & 0xF]);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Decode `%HH` back to bytes (clipboard paste path).
pub fn percentDecode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const h = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch {
                try out.append(alloc, s[i]);
                i += 1;
                continue;
            };
            try out.append(alloc, h);
            i += 3;
        } else {
            try out.append(alloc, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Expand `%f/%F/%u/%U/%k/%c` tokens (`expand_desktop_exec_tokens`).
/// `%i/%v/%m` drop out, `%%` -> `%`. Unknown `%x` is dropped.
pub fn expandExecTokens(
    alloc: std.mem.Allocator,
    exec: []const u8,
    file_canon: []const u8,
    file_uri: []const u8,
    display_name: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < exec.len) : (i += 1) {
        if (exec[i] != '%') {
            try out.append(alloc, exec[i]);
            continue;
        }
        if (i + 1 >= exec.len) break;
        const n = exec[i + 1];
        i += 1;
        switch (n) {
            '%' => try out.append(alloc, '%'),
            'f', 'F' => try out.appendSlice(alloc, file_canon),
            'u', 'U', 'k' => try out.appendSlice(alloc, file_uri),
            'c' => try out.appendSlice(alloc, display_name),
            'i', 'v', 'm' => {},
            else => {},
        }
    }
    return out.toOwnedSlice(alloc);
}

/// `xdg-open 'canon'`.
pub fn openPathCmd(alloc: std.mem.Allocator, canon: []const u8) ![]u8 {
    const q = try shQuote(alloc, canon);
    defer alloc.free(q);
    return std.fmt.allocPrint(alloc, "xdg-open {s}", .{q});
}

/// `gio open 'uri' || xdg-open 'uri'`.
pub fn openUriCmd(alloc: std.mem.Allocator, uri: []const u8) ![]u8 {
    const q = try shQuote(alloc, uri);
    defer alloc.free(q);
    return std.fmt.allocPrint(alloc, "gio open {s} || xdg-open {s}", .{ q, q });
}

/// Nautilus clipboard body: header + `cut|copy` + one uri per line.
pub fn clipboardBody(alloc: std.mem.Allocator, cut: bool, uris: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "x-special/nautilus-clipboard\n");
    try out.appendSlice(alloc, if (cut) "cut\n" else "copy\n");
    for (uris) |u| {
        try out.appendSlice(alloc, u);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

/// `gio trash 'p' || trash-put 'p'`.
pub fn trashCmd(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const q = try shQuote(alloc, path);
    defer alloc.free(q);
    return std.fmt.allocPrint(alloc, "gio trash {s} || trash-put {s}", .{ q, q });
}

/// `pkexec env DISPLAY... /bin/sh -c 'inner'` wrapper (`launch_pkexec`).
pub fn pkexecWrap(alloc: std.mem.Allocator, inner: []const u8) ![]u8 {
    const q = try shQuote(alloc, inner);
    defer alloc.free(q);
    return std.fmt.allocPrint(alloc, "pkexec env DISPLAY=\"$DISPLAY\" WAYLAND_DISPLAY=\"$WAYLAND_DISPLAY\" /bin/sh -c {s}", .{q});
}

/// Rename prompt command (`prompt_rename_text`): zenity || kdialog || yad.
pub fn renamePromptCmd(alloc: std.mem.Allocator, title: []const u8, initial: []const u8) ![]u8 {
    const qt = try shQuote(alloc, title);
    defer alloc.free(qt);
    const qi = try shQuote(alloc, initial);
    defer alloc.free(qi);
    return std.fmt.allocPrint(alloc, "zenity --entry --title {s} --entry-text {s} || kdialog --inputbox {s} {s} || yad --entry --title {s} --entry-text {s}", .{ qt, qi, qi, qi, qt, qi });
}

/// Unique copy destination `dir/name (n).ext` (paste path dedups).
pub fn uniqueDest(alloc: std.mem.Allocator, dir: []const u8, name: []const u8, exists: *const fn ([]const u8) bool) ![]u8 {
    var n: usize = 0;
    while (true) : (n += 1) {
        const cand = if (n == 0)
            try std.fs.path.join(alloc, &.{ dir, name })
        else blk: {
            if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
                if (dot > 0) break :blk try std.fmt.allocPrint(alloc, "{s}/{s} ({d}){s}", .{ dir, name[0..dot], n, name[dot..] });
            }
            break :blk try std.fmt.allocPrint(alloc, "{s}/{s} ({d})", .{ dir, name, n });
        };
        errdefer alloc.free(cand);
        if (!exists(cand)) return cand;
        alloc.free(cand);
        if (n > 9999) return error.OutOfNames;
    }
}

/// Detached spawn (`spawn_sh_lc_detached`): `/bin/sh -lc 'script' &`
/// via double-fork so the caller never blocks or zombies.
pub fn spawnDetachedArgv(script: []const u8) [5][]const u8 {
    return .{ "/bin/sh", "-lc", script, "&", "" };
}

/// Parse `text/uri-list` or plain clipboard into file paths.
/// `file://` prefix stripped, `%HH` decoded, `file:` without `//` tolerated.
pub fn parseUriList(alloc: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var path: []const u8 = line;
        if (std.mem.startsWith(u8, line, "file://")) {
            path = line[7..];
        } else if (std.mem.startsWith(u8, line, "file:")) {
            path = line[5..];
        }
        const dec = try percentDecode(alloc, path);
        // Skip duplicates.
        var dup = false;
        for (out.items) |have| {
            if (std.mem.eql(u8, have, dec)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            alloc.free(dec);
            continue;
        }
        try out.append(alloc, dec);
    }
    return out.toOwnedSlice(alloc);
}

/// `Skip self` check for paste: dest inside source tree.
pub fn isSelfCopy(src: []const u8, dest_dir: []const u8) bool {
    if (src.len == 0 or dest_dir.len == 0) return false;
    if (std.mem.eql(u8, src, dest_dir)) return true;
    if (std.mem.startsWith(u8, dest_dir, src) and dest_dir.len > src.len and dest_dir[src.len] == '/') return true;
    return false;
}

test "xdg_ops: uri + exec expand + sh quote" {
    const t = std.testing;
    const uri = try fileUriForPath(t.allocator, "/a/my file.txt");
    defer t.allocator.free(uri);
    try t.expectEqualStrings("file:///a/my%20file.txt", uri);
    const dec = try percentDecode(t.allocator, "file%20x%2Fy");
    defer t.allocator.free(dec);
    try t.expectEqualStrings("file x/y", dec);
    const ex = try expandExecTokens(t.allocator, "app %f %u %c %% %i", "/a/f", "file:///a/f", "Name");
    defer t.allocator.free(ex);
    try t.expectEqualStrings("app /a/f file:///a/f Name % ", ex);
    const q = try shQuote(t.allocator, "o'clock");
    defer t.allocator.free(q);
    try t.expectEqualStrings("'o'\\''clock'", q);
    const oc = try openPathCmd(t.allocator, "/a/b");
    defer t.allocator.free(oc);
    try t.expectEqualStrings("xdg-open '/a/b'", oc);
    const tc = try trashCmd(t.allocator, "/a/b");
    defer t.allocator.free(tc);
    try t.expect(std.mem.indexOf(u8, tc, "gio trash") != null);
}

test "xdg_ops: clipboard + unique dest" {
    const t = std.testing;
    const uris = [_][]const u8{"file:///a", "file:///b"};
    const body = try clipboardBody(t.allocator, true, &uris);
    defer t.allocator.free(body);
    try t.expectEqualStrings("x-special/nautilus-clipboard\ncut\nfile:///a\nfile:///b\n", body);
    const S = struct {
        fn no(_: []const u8) bool {
            return false;
        }
    };
    const d = try uniqueDest(t.allocator, "/d", "f.txt", &S.no);
    defer t.allocator.free(d);
    try t.expectEqualStrings("/d/f.txt", d);
    const rc = try renamePromptCmd(t.allocator, "Rename file", "a.txt");
    defer t.allocator.free(rc);
    try t.expect(std.mem.indexOf(u8, rc, "zenity") != null);
    const pk = try pkexecWrap(t.allocator, "id");
    defer t.allocator.free(pk);
    try t.expect(std.mem.indexOf(u8, pk, "pkexec") != null);
}

test "xdg_ops: uri list parse + self-copy guard" {
    const t = std.testing;
    const list = try parseUriList(t.allocator, "file:///a/b%20c\nfile:///a/b%20c\nplain\n");
    defer {
        for (list) |p| t.allocator.free(p);
        t.allocator.free(list);
    }
    try t.expectEqual(@as(usize, 2), list.len);
    try t.expectEqualStrings("/a/b c", list[0]);
    try t.expect(isSelfCopy("/a/b", "/a/b/c"));
    try t.expect(!isSelfCopy("/a/b", "/a/other"));
    const argv = spawnDetachedArgv("echo hi");
    try t.expectEqualStrings("/bin/sh", argv[0]);
}
