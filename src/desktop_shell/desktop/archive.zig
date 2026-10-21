const std = @import("std");

/// Archive detect/extract/compress command builders.
/// Port of `entries/desktop_archive.{hpp,cpp}`.
///
/// Detection (`path_looks_like_archive`, `:109-121`):
/// `.zip/.7z/.rar/.cab`, `.tar/.tgz/.tbz2/.tbz/.txz/.tlz/.tzst`, or
/// `*.tar.{gz,bz2,xz,zst,lzma}`. Extension compare is lowercase.
/// Extraction and compression shell out through `xdg::spawn_sh_lc_detached`
/// to `7zz/7z/unzip/tar/zip` (`:134-207`); this module builds the same
/// script strings so they can be tested without spawning.

pub const CompressFormat = enum(u8) {
    zip = 0,
    tar_gz = 1,
    tar = 2,
    seven_z = 3,
};

pub fn compressExtension(fmt: CompressFormat) []const u8 {
    return switch (fmt) {
        .zip => ".zip",
        .tar_gz => ".tar.gz",
        .tar => ".tar",
        .seven_z => ".7z",
    };
}

fn lowerExt(filename: []const u8) struct { ext: [16]u8, len: usize } {
    var out: [16]u8 = undefined;
    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return .{ .ext = out, .len = 0 };
    const e = filename[dot..];
    const n: usize = @min(e.len, 16);
    for (0..n) |i| out[i] = std.ascii.toLower(e[i]);
    return .{ .ext = out, .len = n };
}

fn extIs(filename: []const u8, want: []const u8) bool {
    const e = lowerExt(filename);
    if (e.len != want.len) return false;
    return std.mem.eql(u8, e.ext[0..e.len], want);
}

fn stemOf(filename: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return filename;
    if (dot == 0) return filename;
    return filename[0..dot];
}

/// `path_looks_like_archive` (`:109-121`).
pub fn pathLooksLikeArchive(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    if (base.len == 0) return false;
    if (extIs(base, ".zip") or extIs(base, ".7z") or extIs(base, ".rar") or extIs(base, ".cab")) return true;
    if (extIs(base, ".tar") or extIs(base, ".tgz") or extIs(base, ".tbz2") or extIs(base, ".tbz") or
        extIs(base, ".txz") or extIs(base, ".tlz") or extIs(base, ".tzst")) return true;
    const stem = stemOf(base);
    const stem_ext = lowerExt(stem);
    const stem_ext_s = stem_ext.ext[0..stem_ext.len];
    if (std.mem.eql(u8, stem_ext_s, ".tar")) {
        if (extIs(base, ".gz") or extIs(base, ".bz2") or extIs(base, ".xz") or
            extIs(base, ".zst") or extIs(base, ".lzma")) return true;
    }
    return false;
}

/// Strip every known archive extension (`archive_folder_basename`, `:40-67`).
pub fn archiveFolderBasename(filename: []const u8) []const u8 {
    var x = filename;
    while (true) {
        if (extIs(x, ".zip") or extIs(x, ".7z") or extIs(x, ".rar") or extIs(x, ".cab") or
            extIs(x, ".tar") or extIs(x, ".tgz") or extIs(x, ".tbz2") or extIs(x, ".tbz") or
            extIs(x, ".txz") or extIs(x, ".tzst") or extIs(x, ".tlz") or
            extIs(x, ".gz") or extIs(x, ".bz2") or extIs(x, ".xz") or
            extIs(x, ".zst") or extIs(x, ".lzma"))
        {
            const nx = stemOf(x);
            if (nx.len == x.len or nx.len == 0) break;
            // `.tar.gz` needs two strips: `.gz` then `.tar`. Generic loop handles it.
            x = nx;
            continue;
        }
        break;
    }
    if (x.len == 0 or std.mem.eql(u8, x, ".") or std.mem.eql(u8, x, "..")) return "archive";
    return x;
}

/// `sh_single_quote` (`:27-38`).
pub fn shSingleQuote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(alloc, "'\\''") else try out.append(alloc, c);
    }
    try out.append(alloc, '\'');
    return out.toOwnedSlice(alloc);
}

/// Unique `name (n).ext` candidate (`unique_output_file`, `:83-90`).
/// `exists` answers "does this candidate already exist" (fs probe in prod,
/// a stub in tests).
pub fn uniqueName(alloc: std.mem.Allocator, base: []const u8, ext: []const u8, exists: *const fn ([]const u8) bool) ![]u8 {
    var n: usize = 0;
    while (true) : (n += 1) {
        const cand = if (n == 0)
            try std.fmt.allocPrint(alloc, "{s}{s}", .{ base, ext })
        else
            try std.fmt.allocPrint(alloc, "{s} ({d}){s}", .{ base, n, ext });
        errdefer alloc.free(cand);
        if (!exists(cand)) return cand;
        alloc.free(cand);
        if (n > 9999) return error.OutOfNames;
    }
}

pub fn isTarFamily(filename: []const u8) bool {
    const base = std.fs.path.basename(filename);
    if (extIs(base, ".tar") or extIs(base, ".tgz") or extIs(base, ".tbz2") or extIs(base, ".tbz") or
        extIs(base, ".txz") or extIs(base, ".tzst")) return true;
    const stem = stemOf(base);
    const se = lowerExt(stem);
    if (std.mem.eql(u8, se.ext[0..se.len], ".tar")) {
        if (extIs(base, ".gz") or extIs(base, ".bz2") or extIs(base, ".xz") or
            extIs(base, ".zst") or extIs(base, ".lzma")) return true;
    }
    return false;
}

/// Filter to regular-archive paths (`filter_archive_paths`).
/// `is_file` answers regular-file (fs probe in prod, stub in tests).
pub fn filterArchives(alloc: std.mem.Allocator, paths: []const []const u8, is_file: *const fn ([]const u8) bool) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    for (paths) |p| {
        if (!is_file(p)) continue;
        if (pathLooksLikeArchive(p)) try out.append(alloc, p);
    }
    return out.toOwnedSlice(alloc);
}

/// Build the exact extract script (`extract_archives_detached`, `:134-166`).
/// Caller owns the result. `dest_for` maps archive -> unique dest dir.
pub fn buildExtractScript(alloc: std.mem.Allocator, archives: []const []const u8, dest_for: *const fn ([]const u8) []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (archives) |ap| {
        const dest = dest_for(ap);
        const qarch = try shSingleQuote(alloc, ap);
        defer alloc.free(qarch);
        const qdest = try shSingleQuote(alloc, dest);
        defer alloc.free(qdest);
        const base = std.fs.path.basename(ap);
        const tar_family = isTarFamily(base);
        const is_zip = extIs(base, ".zip");
        try out.appendSlice(alloc, "DEST=");
        try out.appendSlice(alloc, qdest);
        try out.appendSlice(alloc, "\nmkdir -p \"$DEST\" || true\n");
        try out.appendSlice(alloc, "if command -v 7zz >/dev/null 2>&1 && 7zz x -y ");
        try out.appendSlice(alloc, qarch);
        try out.appendSlice(alloc, " -o\"$DEST/\"; then :\n");
        try out.appendSlice(alloc, "elif command -v 7z >/dev/null 2>&1 && 7z x -y ");
        try out.appendSlice(alloc, qarch);
        try out.appendSlice(alloc, " -o\"$DEST/\"; then :\n");
        if (is_zip) {
            try out.appendSlice(alloc, "elif command -v unzip >/dev/null 2>&1 && unzip -q -o ");
            try out.appendSlice(alloc, qarch);
            try out.appendSlice(alloc, " -d \"$DEST\"; then :\n");
        }
        if (tar_family) {
            try out.appendSlice(alloc, "elif command -v tar >/dev/null 2>&1 && tar -xf ");
            try out.appendSlice(alloc, qarch);
            try out.appendSlice(alloc, " -C \"$DEST\"; then :\n");
        }
        try out.appendSlice(alloc, "else echo \"[desktop] extract failed (install p7zip/unzip/tar): ");
        try out.appendSlice(alloc, ap);
        try out.appendSlice(alloc, "\" >&2\nfi\n");
    }
    return out.toOwnedSlice(alloc);
}

/// Build the exact compress script (`compress_paths_detached`, `:168-207`).
pub fn buildCompressScript(alloc: std.mem.Allocator, fmt: CompressFormat, out_path: []const u8, paths: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const qout = try shSingleQuote(alloc, out_path);
    defer alloc.free(qout);
    var args: std.ArrayList(u8) = .empty;
    defer args.deinit(alloc);
    for (paths) |p| {
        const q = try shSingleQuote(alloc, p);
        defer alloc.free(q);
        try args.append(alloc, ' ');
        try args.appendSlice(alloc, q);
    }
    if (args.items.len == 0) return error.EmptyPaths;
    switch (fmt) {
        .zip => {
            try out.appendSlice(alloc, "if command -v zip >/dev/null 2>&1; then zip -q -r ");
            try out.appendSlice(alloc, qout);
            try out.appendSlice(alloc, args.items);
            try out.appendSlice(alloc, "; else echo '[desktop] compress: zip not found' >&2; exit 1; fi\n");
        },
        .tar_gz => {
            try out.appendSlice(alloc, "if command -v tar >/dev/null 2>&1; then tar -czf ");
            try out.appendSlice(alloc, qout);
            try out.appendSlice(alloc, args.items);
            try out.appendSlice(alloc, "; else echo '[desktop] compress: tar not found' >&2; exit 1; fi\n");
        },
        .tar => {
            try out.appendSlice(alloc, "if command -v tar >/dev/null 2>&1; then tar -cf ");
            try out.appendSlice(alloc, qout);
            try out.appendSlice(alloc, args.items);
            try out.appendSlice(alloc, "; else echo '[desktop] compress: tar not found' >&2; exit 1; fi\n");
        },
        .seven_z => {
            try out.appendSlice(alloc, "if command -v 7zz >/dev/null 2>&1; then 7zz a -t7z ");
            try out.appendSlice(alloc, qout);
            try out.appendSlice(alloc, args.items);
            try out.appendSlice(alloc, "; elif command -v 7z >/dev/null 2>&1; then 7z a -t7z ");
            try out.appendSlice(alloc, qout);
            try out.appendSlice(alloc, args.items);
            try out.appendSlice(alloc, "; else echo '[desktop] compress: 7z/7zz not found' >&2; exit 1; fi\n");
        },
    }
    return out.toOwnedSlice(alloc);
}

test "archive: detect" {
    const t = std.testing;
    try t.expect(pathLooksLikeArchive("/a/b.zip"));
    try t.expect(pathLooksLikeArchive("/a/b.TAR.GZ"));
    try t.expect(pathLooksLikeArchive("/a/b.tar.bz2"));
    try t.expect(pathLooksLikeArchive("/a/b.7z"));
    try t.expect(!pathLooksLikeArchive("/a/b.txt"));
    try t.expect(!pathLooksLikeArchive("/a/b"));
    try t.expect(!pathLooksLikeArchive(""));
    try t.expect(isTarFamily("x.tgz"));
    try t.expect(!isTarFamily("x.zip"));
}

test "archive: folder basename strips all layers" {
    const t = std.testing;
    try t.expectEqualStrings("photos", archiveFolderBasename("photos.tar.gz"));
    try t.expectEqualStrings("photos", archiveFolderBasename("photos.zip"));
    try t.expectEqualStrings("a", archiveFolderBasename("a.tar.bz2"));
    try t.expectEqualStrings("archive", archiveFolderBasename(""));
    try t.expectEqualStrings(".zip", archiveFolderBasename(".zip"));
}

test "archive: sh quote + unique names" {
    const t = std.testing;
    const q = try shSingleQuote(t.allocator, "a'b");
    defer t.allocator.free(q);
    try t.expectEqualStrings("'a'\\''b'", q);
    const S = struct {
        fn no(_: []const u8) bool {
            return false;
        }
        var calls: usize = 0;
        fn once(name: []const u8) bool {
            _ = name;
            calls += 1;
            return calls == 1;
        }
    };
    const uniq0 = try uniqueName(t.allocator, "Selection-20240101-000000", ".zip", &S.no);
    defer t.allocator.free(uniq0);
    try t.expectEqualStrings("Selection-20240101-000000.zip", uniq0);
    S.calls = 0;
    const uniq1 = try uniqueName(t.allocator, "base", ".zip", &S.once);
    defer t.allocator.free(uniq1);
    try t.expectEqualStrings("base (1).zip", uniq1);
    try t.expectEqualStrings(".zip", compressExtension(.zip));
    try t.expectEqualStrings(".tar.gz", compressExtension(.tar_gz));
}

test "archive: filter + extract/compress scripts use the specified commands" {
    const t = std.testing;
    const F = struct {
        fn isFile(p: []const u8) bool {
            return !std.mem.endsWith(u8, p, ".txt");
        }
        fn dest(_: []const u8) []const u8 {
            return "/parent/photos";
        }
    };
    const paths = [_][]const u8{ "/a/b.zip", "/a/c.txt" };
    const filt = try filterArchives(t.allocator, &paths, &F.isFile);
    defer t.allocator.free(filt);
    try t.expectEqual(@as(usize, 1), filt.len);
    const ex = try buildExtractScript(t.allocator, filt, &F.dest);
    defer t.allocator.free(ex);
    try t.expect(std.mem.indexOf(u8, ex, "7zz x -y") != null);
    try t.expect(std.mem.indexOf(u8, ex, "unzip -q -o") != null);
    const co = try buildCompressScript(t.allocator, .zip, "/parent/out.zip", filt);
    defer t.allocator.free(co);
    try t.expect(std.mem.indexOf(u8, co, "zip -q -r") != null);
    const c7 = try buildCompressScript(t.allocator, .seven_z, "/parent/out.7z", filt);
    defer t.allocator.free(c7);
    try t.expect(std.mem.indexOf(u8, c7, "7zz a -t7z") != null);
}
