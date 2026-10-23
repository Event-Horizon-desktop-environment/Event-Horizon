const std = @import("std");
const reflection = @import("../../compat/reflection.zig");
const app_catalog = @import("../../services/app_catalog.zig");
const app_mod = @import("app.zig");
const fields = @import("fields.zig");

// Default-apps data — the nine slots, their labels/details/mime lists and the
// role-based matcher, ported from the C++ `eh::settings::default_apps`
// (`settings_default_apps.cpp`). Slot keys are the `schema2.DefaultApps`
// keys (`web`, `mail`, …, `pdf`), so the per-component TOML round-trips
// with the C++ shell's `[default_apps]` section.
//
// Categories and MIME types arrive pre-folded to lower case
// (`app_catalog.Entry.cats_l` / `.mimes_l`), the same deal the C++ code
// strike-in-folds at match time: the matcher then compares plain literals
// and never allocates.

pub const Category = enum { web, mail, calendar, files, terminal, music, video, images, pdf };

pub const category_count: usize = reflection.enumFields(Category).len;

pub const category_labels = [category_count][]const u8{
    "Web browser", "Email", "Calendar", "File manager", "Terminal",
    "Audio",       "Video", "Images",   "PDF",
};

pub const category_details = [category_count][]const u8{
    "HTTP and HTTPS links",
    "mailto links",
    "Calendar files and webcal",
    "Folders and file browser",
    "Terminal emulator",
    "Music and other audio types",
    "Video playback",
    "Image viewing (raster / photo)",
    "PDF and document viewing",
};

/// The config key each slot decodes from (`schema2.DefaultApps` /
/// the C++ `DefaultAppsSettings` members).
pub const category_keys = [category_count][]const u8{
    "web", "mail", "calendar", "file_manager", "terminal", "music", "video", "images", "pdf",
};

/// The `Field` binding that reads/writes each slot on `Settings`. Names
/// match the `Settings` members, so `fields.kind` reflects them without
/// touching the branch-budgeted switch.
pub const category_fields = [category_count]fields.Field{
    .default_apps_web,
    .default_apps_mail,
    .default_apps_calendar,
    .default_apps_files,
    .default_apps_terminal,
    .default_apps_music,
    .default_apps_video,
    .default_apps_images,
    .default_apps_pdf,
};

// -- The mime lists each slot applies (C++ kMimeWeb/kMimeMail/…) ----------

pub const mimes_web = [_][]const u8{ "x-scheme-handler/http", "x-scheme-handler/https", "text/html", "application/xhtml+xml" };
pub const mimes_mail = [_][]const u8{"x-scheme-handler/mailto"};
pub const mimes_calendar = [_][]const u8{ "text/calendar", "x-scheme-handler/webcal" };
pub const mimes_files = [_][]const u8{ "inode/directory", "inode/mount-point" };
pub const mimes_terminal = [_][]const u8{"application/x-terminal-emulator"};
pub const mimes_music = [_][]const u8{ "audio/mpeg", "audio/flac", "audio/ogg", "audio/wav", "audio/x-wav", "audio/aac", "audio/mp4", "audio/opus", "audio/x-matroska", "audio/x-ms-wma" };
pub const mimes_video = [_][]const u8{ "video/mp4", "video/webm", "video/x-matroska", "video/quicktime", "video/x-msvideo", "video/mpeg", "video/ogg", "video/x-flv", "video/3gpp" };
pub const mimes_images = [_][]const u8{ "image/png", "image/jpeg", "image/webp", "image/gif", "image/svg+xml", "image/avif", "image/bmp", "image/tiff", "image/heic", "image/x-tga" };
pub const mimes_pdf = [_][]const u8{"application/pdf"};

/// The mime list `xdg-mime default` writes for a slot.
pub fn applyMimes(cat: Category) []const []const u8 {
    return switch (cat) {
        .web => &mimes_web,
        .mail => &mimes_mail,
        .calendar => &mimes_calendar,
        .files => &mimes_files,
        .terminal => &mimes_terminal,
        .music => &mimes_music,
        .video => &mimes_video,
        .images => &mimes_images,
        .pdf => &mimes_pdf,
    };
}

/// The one mime `xdg-mime query default` probes per slot (C++ kQueryMime).
pub fn queryMime(cat: Category) []const u8 {
    return switch (cat) {
        .web => "x-scheme-handler/https",
        .mail => "x-scheme-handler/mailto",
        .calendar => "text/calendar",
        .files => "inode/directory",
        .terminal => "application/x-terminal-emulator",
        .music => "audio/flac",
        .video => "video/mp4",
        .images => "image/png",
        .pdf => "application/pdf",
    };
}

// -- Semicolon-list token helpers (lowercase input, C++ exact) -------------

fn trimSeg(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " ");
}

/// True when one space-trimmed segment of a `;`-separated list equals `token`.
pub fn semicolonTokenEquals(tokens: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, tokens, ';');
    while (it.next()) |seg_raw| {
        if (std.mem.eql(u8, trimSeg(seg_raw), token)) return true;
    }
    return false;
}

/// True when any token in the list appears in `cats_l` (C++ has_any_cat_token).
pub fn hasAnyCatToken(cats_l: []const u8, tokens: []const []const u8) bool {
    for (tokens) |t| {
        if (t.len > 0 and semicolonTokenEquals(cats_l, t)) return true;
    }
    return false;
}

/// True when `frag` is a substring of some segment (C++ cat_token_contains).
pub fn catTokenContains(cats_l: []const u8, frag: []const u8) bool {
    if (frag.len == 0) return false;
    var it = std.mem.splitScalar(u8, cats_l, ';');
    while (it.next()) |seg_raw| {
        const seg = trimSeg(seg_raw);
        if (seg.len != 0 and std.mem.indexOf(u8, seg, frag) != null) return true;
    }
    return false;
}

/// True when some segment of the MimeType list starts with `prefix`
/// (segments trim spaces and tabs, C++ mime_token_has_prefix).
pub fn mimeTokenHasPrefix(mimes_l: []const u8, prefix: []const u8) bool {
    if (mimes_l.len == 0 or prefix.len == 0) return false;
    var it = std.mem.splitScalar(u8, mimes_l, ';');
    while (it.next()) |seg_raw| {
        const seg = std.mem.trim(u8, seg_raw, " \t");
        if (seg.len >= prefix.len and std.mem.eql(u8, seg[0..prefix.len], prefix)) return true;
    }
    return false;
}

// -- The role-based matcher -------------------------------------------------

/// The dedicated calendar rule (C++ desktop_entry_is_calendar_app): a
/// Calendar category without web/mail roles, or a calendar mime inside an
/// office/utility/pim scope that is not also a browser or mailer.
fn isCalendarApp(cats_l: []const u8, mimes_l: []const u8) bool {
    if (cats_l.len > 0 and semicolonTokenEquals(cats_l, "calendar") and
        !hasAnyCatToken(cats_l, &.{ "webbrowser", "email" }))
    {
        return true;
    }
    if (mimes_l.len == 0) return false;
    const mime_cal = semicolonTokenEquals(mimes_l, "text/calendar") or
        semicolonTokenEquals(mimes_l, "text/x-vcalendar") or
        semicolonTokenEquals(mimes_l, "application/ics") or
        semicolonTokenEquals(mimes_l, "text/x-ical") or
        semicolonTokenEquals(mimes_l, "model/calendar") or
        semicolonTokenEquals(mimes_l, "x-scheme-handler/webcal");
    if (!mime_cal) return false;
    if (hasAnyCatToken(cats_l, &.{ "webbrowser", "email" })) return false;
    return hasAnyCatToken(cats_l, &.{ "office", "utility", "pda", "pim" });
}

/// Role-based matching. MIME declarations are only a secondary signal and
/// are never allowed to promote an app whose Categories role belongs
/// elsewhere (a text editor that merely handles text/html is not a browser).
pub fn matchesCategory(cats_l: []const u8, mimes_l: []const u8, cat: Category) bool {
    return switch (cat) {
        .web => semicolonTokenEquals(cats_l, "webbrowser") and
            !hasAnyCatToken(cats_l, &.{ "email", "filemanager", "terminalemulator", "calendar" }),
        .mail => semicolonTokenEquals(cats_l, "email") and
            !hasAnyCatToken(cats_l, &.{ "webbrowser", "filemanager", "terminalemulator" }),
        .calendar => isCalendarApp(cats_l, mimes_l),
        .files => blk: {
            if (semicolonTokenEquals(cats_l, "filemanager")) break :blk true;
            if (!semicolonTokenEquals(mimes_l, "inode/directory")) break :blk false;
            if (hasAnyCatToken(cats_l, &.{ "webbrowser", "email", "terminalemulator", "texteditor", "office" })) break :blk false;
            break :blk hasAnyCatToken(cats_l, &.{ "system", "utility", "core" });
        },
        .terminal => semicolonTokenEquals(cats_l, "terminalemulator") and
            !hasAnyCatToken(cats_l, &.{ "webbrowser", "email", "filemanager" }),
        .music => blk: {
            if (hasAnyCatToken(cats_l, &.{"mixer"}) or catTokenContains(cats_l, "edit")) break :blk false;
            if (hasAnyCatToken(cats_l, &.{ "audio", "music", "audioplayer", "sequencer", "tuner" })) break :blk true;
            break :blk hasAnyCatToken(cats_l, &.{ "audiovideo", "player" }) and
                !hasAnyCatToken(cats_l, &.{ "video", "tv" }) and
                mimeTokenHasPrefix(mimes_l, "audio/");
        },
        .video => blk: {
            if (hasAnyCatToken(cats_l, &.{"mixer"}) or catTokenContains(cats_l, "edit")) break :blk false;
            if (hasAnyCatToken(cats_l, &.{ "video", "videoplayer", "tv" })) break :blk true;
            break :blk hasAnyCatToken(cats_l, &.{ "audiovideo", "player" }) and
                mimeTokenHasPrefix(mimes_l, "video/");
        },
        .images => blk: {
            if (hasAnyCatToken(cats_l, &.{ "webbrowser", "office", "texteditor" })) break :blk false;
            if (hasAnyCatToken(cats_l, &.{ "rastergraphics", "2dgraphics", "scanning" })) break :blk true;
            if (semicolonTokenEquals(cats_l, "viewer") and semicolonTokenEquals(cats_l, "graphics")) break :blk mimeTokenHasPrefix(mimes_l, "image/");
            break :blk semicolonTokenEquals(cats_l, "photography") and mimeTokenHasPrefix(mimes_l, "image/");
        },
        .pdf => blk: {
            if (!semicolonTokenEquals(mimes_l, "application/pdf")) break :blk false;
            if (semicolonTokenEquals(cats_l, "pdf")) break :blk true;
            if (semicolonTokenEquals(cats_l, "office") and semicolonTokenEquals(cats_l, "viewer")) break :blk true;
            // Chromium-based browsers (Edge, Chrome/Chromium, Helium, and
            // Firefox) can view PDFs, so include browsers that explicitly
            // declare application/pdf.
            break :blk semicolonTokenEquals(cats_l, "webbrowser");
        },
    };
}

pub fn entryMatchesCategory(e: app_catalog.Entry, cat: Category) bool {
    return matchesCategory(e.cats_l, e.mimes_l, cat);
}

// -- Search -----------------------------------------------------------------

fn foldContains(s: []const u8, needle_l: []const u8) bool {
    if (s.len == 0) return false;
    var buf: [512]u8 = undefined;
    const n = @min(s.len, buf.len);
    // ASCII fold: desktop metadata is ASCII in practice and the C++ port
    // used std::tolower per byte as well.
    for (s[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return std.mem.indexOf(u8, buf[0..n], needle_l) != null;
}

/// Type-to-search filter over name (pre-folded), generic, comment,
/// keywords and the path basename (C++ desktop_entry_matches_search).
pub fn entryMatchesSearch(e: app_catalog.Entry, needle_l: []const u8) bool {
    if (needle_l.len == 0) return true;
    if (e.fold.len > 0 and std.mem.indexOf(u8, e.fold, needle_l) != null) return true;
    if (foldContains(e.generic, needle_l)) return true;
    if (foldContains(e.comment, needle_l)) return true;
    if (foldContains(e.keywords, needle_l)) return true;
    const base = std.fs.path.basename(e.path);
    return foldContains(base, needle_l);
}

// -- Friendly naming + stored-slot access ------------------------------------

/// Drop a trailing `.desktop` (the display shortcut C++ applies everywhere).
pub fn stripDesktopSuffix(id: []const u8) []const u8 {
    const suf = ".desktop";
    if (id.len > suf.len and std.mem.endsWith(u8, id, suf)) return id[0 .. id.len - suf.len];
    return id;
}

/// The friendly one-liner for a stored id: the entry's Name when the id is
/// installed, otherwise the id's stem (C++ friendly_line_for_desktop_id).
pub fn friendlyLine(entries: []const app_catalog.Entry, desktop_id: []const u8) []const u8 {
    if (desktop_id.len == 0) return "";
    for (entries) |e| {
        if (std.mem.eql(u8, std.fs.path.basename(e.path), desktop_id)) return e.name;
    }
    return stripDesktopSuffix(desktop_id);
}

/// The stored desktop id for a slot (the `Settings` member, via the field
/// binding so both the tab and the persistence layer agree).
pub fn storedId(s: *const app_mod.Settings, cat: Category) []const u8 {
    return fields.getStr(s, category_fields[@intFromEnum(cat)]);
}

pub fn setStoredId(s: *app_mod.Settings, cat: Category, id: []const u8) void {
    fields.setStr(s, category_fields[@intFromEnum(cat)], id);
}

test "settings-default-apps: token helpers" {
    const t = std.testing;
    try t.expect(semicolonTokenEquals("webbrowser;network", "webbrowser"));
    try t.expect(semicolonTokenEquals(" network ; webbrowser ", "webbrowser"));
    // Catalog categories arrive lowercased (`app_catalog` lowercases at
    // parse time), so the compare stays exact like the C++ helper.
    try t.expect(!semicolonTokenEquals(" network ; WebBrowser ", "webbrowser"));
    try t.expect(!semicolonTokenEquals("webbrowsertools", "webbrowser"));
    try t.expect(hasAnyCatToken("utility;filemanager;", &.{ "filemanager", "office" }));
    try t.expect(!hasAnyCatToken("utility", &.{"office"}));
    try t.expect(catTokenContains("audio;audioeditor", "edit"));
    try t.expect(!catTokenContains("audio;editorial", "zoro"));
    try t.expect(mimeTokenHasPrefix(" video/mp4 ; image/png", "image/"));
    try t.expect(!mimeTokenHasPrefix("", "image/"));
}

test "settings-default-apps: role matcher" {
    const t = std.testing;
    // A browser: WebBrowser role, no competing roles.
    try t.expect(matchesCategory("network;webbrowser;", "text/html;x-scheme-handler/https;", .web));
    // An editor that declares text/html is NOT promoted to the web slot.
    try t.expect(!matchesCategory("texteditor;utility;", "text/plain;text/html;", .web));
    // Terminal emulator role, excluding file-manager doubles.
    try t.expect(matchesCategory("system;terminalemulator;", "application/x-terminal-emulator;", .terminal));
    try t.expect(!matchesCategory("filemanager;terminalemulator;", "", .terminal));
    // File manager via role, or via inode/directory inside a system utility.
    try t.expect(matchesCategory("filemanager;core;", "", .files));
    try t.expect(matchesCategory("system;utility;", "inode/directory;", .files));
    try t.expect(!matchesCategory("texteditor;utility;", "inode/directory;", .files));
    // Calendar: a pure calendar app, or calendar mime inside office.
    try t.expect(matchesCategory("calendar;", "", .calendar));
    try t.expect(matchesCategory("office;", "text/calendar;", .calendar));
    try t.expect(!matchesCategory("webbrowser;email;", "text/calendar;", .calendar));
    // Audio: player role; AudioEdit is excluded by the contains-edit rule.
    try t.expect(matchesCategory("audio;player;", "audio/mpeg;", .music));
    try t.expect(!matchesCategory("audio;audioeditor;", "audio/mpeg;", .music));
    // Video via AudioVideo+video mime.
    try t.expect(matchesCategory("audiovideo;player;", "video/mp4;", .video));
    // Images via 2dgraphics, and PDF via office+viewer.
    try t.expect(matchesCategory("graphics;2dgraphics;", "image/png;", .images));
    try t.expect(matchesCategory("office;viewer;", "application/pdf;", .pdf));
    try t.expect(matchesCategory("webbrowser;", "application/pdf;", .pdf));
    try t.expect(!matchesCategory("texteditor;", "application/pdf;", .pdf));
}

test "settings-default-apps: search + friendly" {
    const t = std.testing;
    const e = app_catalog.Entry{
        .path = "/usr/share/applications/firefox.desktop",
        .name = "Firefox Web Browser",
        .fold = "firefox web browser",
        .generic = "Web Browser",
        .keywords = "internet;www;browser;",
    };
    try t.expect(entryMatchesSearch(e, ""));
    try t.expect(entryMatchesSearch(e, "firefox"));
    try t.expect(entryMatchesSearch(e, "brow"));
    try t.expect(entryMatchesSearch(e, "www"));
    try t.expect(entryMatchesSearch(e, ".desktop"));
    try t.expect(!entryMatchesSearch(e, "chromium"));
    try t.expectEqualStrings("Firefox", friendlyLine(&.{
        .{ .path = "/usr/share/applications/firefox.desktop", .name = "Firefox" },
    }, "firefox.desktop"));
    try t.expectEqualStrings("org.gnome.Nautilus", friendlyLine(&.{}, "org.gnome.Nautilus.desktop"));
    try t.expectEqualStrings("", friendlyLine(&.{}, ""));
}

test "settings-default-apps: stored ids round-trip through Settings" {
    const t = std.testing;
    var s = app_mod.Settings{};
    setStoredId(&s, .web, "firefox.desktop");
    setStoredId(&s, .terminal, "kitty.desktop");
    try t.expectEqualStrings("firefox.desktop", storedId(&s, .web));
    try t.expectEqualStrings("kitty.desktop", storedId(&s, .terminal));
    try t.expectEqualStrings("", storedId(&s, .mail));
    setStoredId(&s, .web, "");
    try t.expectEqualStrings("", storedId(&s, .web));
}
