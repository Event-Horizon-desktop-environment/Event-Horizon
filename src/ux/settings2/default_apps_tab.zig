//! The Default Apps tab (id 10): one dropdown per category over the
//! installed application catalog — the C++ `settings_tab_default_apps`
//! page ported onto the shared card/combo renderer. The page owns the app
//! scan (lazy: the catalog loads on first entry to the tab) and rebuilds
//! its row tables whenever the stored ids move (`dirty`).
//!
//! Every dropdown lists the system-default choice first, pads the stored
//! id in when it is not installed, and then the entries the role matcher
//! claims for that category — strict, with no fallback list: an empty
//! strict list is honest, exactly like the C++ picker.

const std = @import("std");
const app_mod = @import("app.zig");
const rows_mod = @import("rows.zig");
const fields = @import("fields.zig");
const app_catalog = @import("../../services/app_catalog.zig");
const icon_cache = @import("../../desktop_shell/common/icon_cache.zig");
const da_data = @import("default_apps_data.zig");
const da_apply = @import("default_apps_apply.zig");

pub const tab_id = app_mod.TabId.default_apps;

pub const reset_button_label = "Reset to detected defaults";

/// How many entries may crowd one dropdown: the popup is drawn unclipped,
/// so the list has to fit the window band.
const max_options: usize = 24;

/// The Associations card is only the reset control now — the explainer
/// lines above it were dropped. Its label is routed to a real reset in the
/// window.
const associations_rows = [_]rows_mod.Row{
    .{ .button = .{ .label = reset_button_label } },
};

pub const Page = struct {
    /// gpa/io arrive with the first `noteTabEntered` (the window wires the
    /// page before the loop starts, but the scan itself waits for entry).
    initted: bool = false,
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    catalog_loaded: bool = false,
    catalog: ?app_catalog.Catalog = null,

    /// The dropdown option/label slices live here; a build resets the
    /// arena and rebuilds everything. Initialized in `init` (house rule
    /// for owned arenas).
    arena: std.heap.ArenaAllocator = undefined,
    dirty: bool = true,

    /// The system default each dropdown's first row displays, cached per
    /// slot until an apply moved that slot (a miss costs one
    /// `xdg-mime query` run).
    ///
    /// The cache lives in fixed buffers, never in the build arena: `build`
    /// resets that arena on every rebuild while `sys_valid` stays true, so
    /// an arena-backed slice would be handed out again to the very next
    /// allocation — which is how a label formatter's own writer buffer used
    /// to alias the "System default · …" string it was printing
    /// (`@memcpy arguments alias` panic, plus a flood of invalid-UTF-8
    /// Pango warnings from painting the dangling bytes).
    sys_valid: [da_data.category_count]bool = [_]bool{false} ** da_data.category_count,
    sys_buf: [da_data.category_count][256]u8 = undefined,
    sys_len: [da_data.category_count]usize = [_]usize{0} ** da_data.category_count,

    /// Themed icon pixels for the dropdown rows, keyed by the catalog
    /// entry's `Icon=` name. Resolved lazily on first paint through the
    /// shared icon cache (the settings binary installs one) and kept until
    /// the page dies — the popup redraws every frame, so re-fetching per
    /// row per frame would mean an allocation under the cache lock each
    /// time.
    icon_pixels: std.StringHashMapUnmanaged(icon_cache.Owned) = .empty,

    /// Backing store for the nine category rows; the Associations card
    /// rows are a compile-time constant above.
    rows_cat: [da_data.category_count]rows_mod.Row = undefined,
    cards_buf: [2]rows_mod.Card = undefined,
    cards_built: bool = false,

    pub fn init(self: *Page, gpa: std.mem.Allocator, io: std.Io) void {
        self.gpa = gpa;
        self.io = io;
        self.arena = std.heap.ArenaAllocator.init(gpa);
        self.initted = true;
    }

    pub fn deinit(self: *Page) void {
        if (self.catalog) |*c| {
            c.deinit();
            self.catalog = null;
        }
        self.catalog_loaded = false;
        var it = self.icon_pixels.valueIterator();
        while (it.next()) |v| {
            var owned = v.*;
            owned.deinit(self.gpa);
        }
        self.icon_pixels.deinit(self.gpa);
        self.icon_pixels = .empty;
        self.arena.deinit();
    }

    pub fn entries(self: *const Page) []const app_catalog.Entry {
        return if (self.catalog) |*c| c.entries else &.{};
    }

    /// The entry whose desktop id matches, or null. `id` is a bare
    /// `foo.desktop` stem, the form the dropdown slots store.
    pub fn entryFor(self: *const Page, id: []const u8) ?*const app_catalog.Entry {
        if (id.len == 0) return null;
        for (self.entries()) |*e| {
            if (std.mem.eql(u8, std.fs.path.basename(e.path), id)) return e;
        }
        return null;
    }

    /// Borrowed icon pixels for an entry's `Icon=` name, resolved on first
    /// use through the shared icon cache and cached for the page's life.
    /// Returns null when the cache is not installed, the name is empty, or
    /// the theme ships no such icon — the caller draws the generic "apps"
    /// glyph then, exactly like the C++ picker.
    pub fn iconFor(self: *Page, icon_name: []const u8) ?*const icon_cache.Owned {
        if (icon_name.len == 0) return null;
        if (self.icon_pixels.getEntry(icon_name)) |e| return &e.value_ptr.*;
        const ic = icon_cache.shared() orelse return null;
        const owned = ic.getOwned(.app, icon_name, 32) orelse return null;
        const gop = self.icon_pixels.getOrPut(self.gpa, icon_name) catch {
            var o = owned;
            o.deinit(self.gpa);
            return null;
        };
        if (gop.found_existing) {
            var o = owned;
            o.deinit(self.gpa);
            return gop.value_ptr;
        }
        gop.key_ptr.* = icon_name; // catalog-arena name: lives as long as the page
        gop.value_ptr.* = owned;
        return gop.value_ptr;
    }

    /// First entry to the tab: store the loop context and scan the
    /// applications dirs once. Later entries keep the scan (a package
    /// installed while the settings are open shows up on the next open).
    pub fn noteTabEntered(self: *Page, gpa: std.mem.Allocator, io: std.Io) void {
        if (!self.initted) self.init(gpa, io);
        if (!self.catalog_loaded) {
            self.catalog_loaded = true; // set first: a failed scan is final
            self.catalog = app_catalog.load(self.gpa, self.io) catch null;
        }
        self.dirty = true;
    }

    pub fn markPick(self: *Page, cat: da_data.Category) void {
        self.sys_valid[@intFromEnum(cat)] = false;
        self.dirty = true;
    }

    /// Reset moved every slot (and each cached system default).
    pub fn markReset(self: *Page) void {
        @memset(&self.sys_valid, false);
        self.dirty = true;
    }

    pub fn markDirty(self: *Page) void {
        self.dirty = true;
    }

    /// Rebuild the dynamic card list from `Settings` + the scan. Runs
    /// inside relayout when dirty.
    pub fn build(self: *Page, s: *const app_mod.Settings) void {
        if (!self.initted) return;
        _ = self.arena.reset(.retain_capacity);
        const aa = self.arena.allocator();

        for (0..da_data.category_count) |i| {
            const cat: da_data.Category = @enumFromInt(i);
            if (!self.sys_valid[i]) {
                const cap = da_apply.queryEffectiveDesktopId(self.gpa, self.io, cat);
                if (cap) |c| {
                    defer self.gpa.free(c);
                    const n = @min(c.len, self.sys_buf[i].len);
                    @memcpy(self.sys_buf[i][0..n], c[0..n]);
                    self.sys_len[i] = n;
                } else {
                    self.sys_len[i] = 0;
                }
                self.sys_valid[i] = true;
            }
            const sd: []const u8 = self.sys_buf[i][0..self.sys_len[i]];
            // Plain "System default" — the app name made the row overflow the
            // 200px dropdown, and the pill already shows the resolved icon,
            // so the name adds nothing.
            const sys_label: []const u8 = "System default";
            const stored = da_data.storedId(s, cat);
            const opts = assembleOptions(aa, self.entries(), cat, stored, sys_label, sd);
            self.rows_cat[i] = .{ .combo = .{
                .label = da_data.category_labels[i],
                .desc = da_data.category_details[i],
                .field = da_data.category_fields[i],
                .options = opts.ids,
                .labels = opts.labels,
                .icons = opts.icons,
            } };
        }

        self.cards_buf[0] = .{
            .title = "Default applications",
            .rows = self.rows_cat[0..da_data.category_count],
        };
        self.cards_buf[1] = .{
            .title = "Associations",
            .rows = &associations_rows,
        };
        self.cards_built = true;
        self.dirty = false;
    }

    pub fn cardsSlice(self: *const Page) []const rows_mod.Card {
        if (!self.cards_built) return &.{};
        return self.cards_buf[0..self.cards_buf.len];
    }
};

const Options = struct {
    ids: []const []const u8,
    labels: []const []const u8,
    icons: []const []const u8,
};

/// The dropdown for one slot: the system-default choice at index 0, the
/// stored id padded in when it is not among the installed entries, then
/// every installed entry the role matcher claims — truncated to fit the
/// popup. `""` is the value stored for "follow the system default".
fn assembleOptions(
    arena: std.mem.Allocator,
    entries: []const app_catalog.Entry,
    cat: da_data.Category,
    stored: []const u8,
    sys_label: []const u8,
    sys_id: []const u8,
) Options {
    var ids = std.ArrayList([]const u8).empty;
    var labels = std.ArrayList([]const u8).empty;
    var icons = std.ArrayList([]const u8).empty;

    const fail = Options{ .ids = &.{}, .labels = &.{}, .icons = &.{} };
    ids.append(arena, "") catch return fail;
    labels.append(arena, sys_label) catch return fail;
    icons.append(arena, iconOfId(entries, sys_id)) catch return fail;

    // A stored id that is no longer installed stays visible so the slot
    // is not silently repointed: padded right after the system row.
    if (stored.len > 0) {
        var installed = false;
        for (entries) |e| {
            if (std.mem.eql(u8, std.fs.path.basename(e.path), stored)) {
                installed = true;
                break;
            }
        }
        if (!installed) {
            ids.append(arena, stored) catch return fail;
            labels.append(arena, da_data.stripDesktopSuffix(stored)) catch return fail;
            icons.append(arena, "") catch return fail;
        }
    }

    for (entries) |e| {
        if (ids.items.len >= max_options) break;
        if (!da_data.entryMatchesCategory(e, cat)) continue;
        ids.append(arena, std.fs.path.basename(e.path)) catch return fail;
        labels.append(arena, e.name) catch return fail;
        icons.append(arena, e.icon) catch return fail;
    }
    return .{ .ids = ids.items, .labels = labels.items, .icons = icons.items };
}

/// The `Icon=` name of the entry a desktop id names, or "" when the id is
/// not installed (or declares no icon).
fn iconOfId(entries: []const app_catalog.Entry, id: []const u8) []const u8 {
    if (id.len == 0) return "";
    for (entries) |e| {
        if (std.mem.eql(u8, std.fs.path.basename(e.path), id)) return e.icon;
    }
    return "";
}

/// The slot a combo field drives, or null for anything else (the window
/// routing uses this to know which cache to refresh after a pick).
pub fn slotFromField(f: fields.Field) ?da_data.Category {
    for (da_data.category_fields, 0..) |cf, i| {
        if (cf == f) return @enumFromInt(i);
    }
    return null;
}

test "settings-default-apps-tab: options assemble system-first, pad stored, stay strict" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const entries = [_]app_catalog.Entry{
        .{ .path = "/usr/share/applications/firefox.desktop", .name = "Firefox", .icon = "firefox", .cats_l = "network;webbrowser;", .mimes_l = "text/html;" },
        .{ .path = "/usr/share/applications/kitty.desktop", .name = "Kitty", .icon = "kitty", .cats_l = "system;terminalemulator;", .mimes_l = "application/x-terminal-emulator;" },
        .{ .path = "/usr/share/applications/org.gnome.TextEditor.desktop", .name = "Text Editor", .cats_l = "texteditor;utility;", .mimes_l = "text/plain;" },
    };

    // No stored id: the system row alone plus the strict matches.
    const o0 = assembleOptions(aa, &entries, .web, "", "Use system default", "");
    try t.expectEqual(@as(usize, 2), o0.ids.len);
    try t.expectEqual(@as(usize, 2), o0.icons.len);
    try t.expectEqualStrings("", o0.icons[0]); // system row: whatever the system default declares
    try t.expectEqualStrings("firefox.desktop", o0.ids[1]);
    try t.expectEqualStrings("Firefox", o0.labels[1]);
    try t.expectEqualStrings("firefox", o0.icons[1]);

    // System default is installed: its icon rides on the system row.
    const o0b = assembleOptions(aa, &entries, .terminal, "", "System default · Kitty", "kitty.desktop");
    try t.expectEqualStrings("kitty", o0b.icons[0]);

    // Stored and installed: no pad, no duplicate.
    const o1 = assembleOptions(aa, &entries, .terminal, "kitty.desktop", "Use system default", "");
    try t.expectEqual(@as(usize, 2), o1.ids.len);
    try t.expectEqualStrings("kitty.desktop", o1.ids[1]);
    try t.expectEqualStrings("kitty", o1.icons[1]);

    // Stored id that no longer exists: padded right after the system row,
    // with no icon to show (the row renders the generic apps glyph).
    const o2 = assembleOptions(aa, &entries, .terminal, "gone.desktop", "Use system default", "");
    try t.expectEqual(@as(usize, 3), o2.ids.len);
    try t.expectEqualStrings("", o2.ids[0]);
    try t.expectEqualStrings("gone.desktop", o2.ids[1]);
    try t.expectEqualStrings("gone", o2.labels[1]);
    try t.expectEqualStrings("", o2.icons[1]);

    // Strict list is honest: the text editor is not a calendar.
    const o3 = assembleOptions(aa, &entries, .calendar, "", "Use system default", "");
    try t.expectEqual(@as(usize, 1), o3.ids.len);
    try t.expectEqualStrings("Use system default", o3.labels[0]);
}

test "settings-default-apps-tab: slotFromField round-trips" {
    const t = std.testing;
    try t.expectEqual(da_data.Category.web, slotFromField(.default_apps_web).?);
    try t.expectEqual(da_data.Category.pdf, slotFromField(.default_apps_pdf).?);
    try t.expectEqual(@as(?da_data.Category, null), slotFromField(.icon_theme));
}
