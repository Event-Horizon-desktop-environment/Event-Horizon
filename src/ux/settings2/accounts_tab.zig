//! Accounts tab (tab 46): the `settings_tab_accounts` port, redesigned to
//! match `accounts-redesign.md`.
//!
//! Two columns when the card column is wide enough — a 288px Users list on
//! the left and the Profile / Access / This Device / Delete user stack on the
//! right — else one stacked column. The page paints itself like `time_tab`,
//! owns its scroll extent through `totalHeight`, and runs its two forms
//! (Add User, Change Password) as window-space modal dialogs checked before
//! regular hit testing. Feedback is a transient toast, not a status line.
//!
//! Backend parity with `accounts_users.cpp`: users come from libc
//! `getpwent` (NSS-aware, same as the reference), the admin group is found in
//! `/etc/group` (wheel then sudo), every mutation runs a literal `pkexec`
//! argv, avatars resolve `settings.avatar_path` → `~/.face` →
//! `/var/lib/AccountsService/icons/<user>`, and autologin speaks GDM, SDDM
//! and LightDM the way the reference does.

const std = @import("std");
const common = @import("common.zig");
const ui_paint = @import("ui_paint.zig");
const app_mod = @import("app.zig");
const accounts_data = @import("accounts_data.zig");
const decode = @import("../../wallpaper/decode.zig");
const xkb = @import("../../wl/seat.zig").xkb;
const cairo = @import("../../wl/buffer/shm.zig").cairo;

pub const tab_id: i32 = app_mod.TabId.accounts;

pub fn ownsTab(tab: i32) bool {
    return tab == tab_id;
}

const tau: f64 = 6.283185307179586;

// ---------------------------------------------------------------------------
// Metrics and palette
// ---------------------------------------------------------------------------

const page_bottom_pad: i32 = 24;
const card_gap: i32 = 16;
const pad_x: i32 = 20;
const label_band: i32 = 42;
const row_h: i32 = 72;
const user_row_h: i32 = 64;
const users_head_band: i32 = 40;
const add_area_h: i32 = 60;
const btn_h: i32 = 36;
const field_h: i32 = 36;
const profile_head_h: i32 = 104;
const avatar_s: i32 = 72;
const user_avatar_s: i32 = 40;
const two_col_list_w: i32 = 288;
const two_col_gap: i32 = 24;
// 288 list + 24 gap + 420 minimum detail column: below this the stack is one
// column, exactly as the redesign's narrow-window rule reflows.
const two_col_min_card_w: i32 = two_col_list_w + two_col_gap + 420;
// Button widths are the label's measured width plus ~32px of padding (the
// redesign's `.btn{padding:0 16px}`), so no label can outgrow its outline.
const save_w: i32 = 68;
const apply_w: i32 = 76;
const change_pw_w: i32 = 172;
const photo_w: i32 = 140;
const delete_w: i32 = 152;
const switch_w: i32 = 40;
// Dialog buttons: sized to their labels ("Cancel" 51px, "Create User" 90px,
// "Change Password" 137px) plus ~32px of horizontal padding.
const dlg_cancel_w: i32 = 90;
const dlg_submit_add_w: i32 = 122;
const dlg_submit_pw_w: i32 = 172;
const switch_h: i32 = 24;
const toast_ms: i64 = 3200;
const refresh_ms: i64 = 2000;
const dlg_max_w: i32 = 560;
const dlg_pad: i32 = 20;
const dlg_btn_h: i32 = 36;
const dlg_block_h: i32 = 62;
const dlg_field_h: i32 = 36;
const add_dlg_h: i32 = 470;
const pw_dlg_h: i32 = 306;
// Stacked rows: once a row's inline text column can no longer show its
// description, the row reflows (text block on top, controls underneath) so
// nothing is squeezed or ellipsised at the cost of the input.
const stacked_row_h: i32 = 112;
const stack_text_dy: i32 = 2;
const stack_text_band: i32 = 56;
const stack_ctrl_dy: i32 = 62;
// Inline text column needed for the widest copy of each row, measured at
// 12/400: "Shown on the login screen and in the shell" 319px, "The name this
// computer uses on the network" 346px, "You can't delete the account you're
// signed in with." 378px / "Remove <name> and their home directory. This
// cannot be undone." 479px, "Change the password for <name>" 232px.
const stack_min_display: i32 = 330;
const stack_min_hostname: i32 = 356;
const stack_min_delete: i32 = 490;
const stack_min_pw: i32 = 240;

/// Width of the dialog's primary submit button; hit-testing and painting must
/// agree, so both go through here.
fn dlgSubmitW(add: bool) i32 {
    return if (add) dlg_submit_add_w else dlg_submit_pw_w;
}

/// True once the inline text column (`inner_w` minus the right-aligned control
/// cluster) drops below `desc_w`: the row must stack instead of truncating.
fn rowStacks(inner_w: i32, desc_w: i32) bool {
    const group_w = std.math.clamp(@divTrunc(inner_w * 48, 100), 170, 320);
    return inner_w - group_w - 14 < desc_w;
}
const add_dlg_fields: u8 = 4;
const pw_dlg_fields: u8 = 2;

const danger_r: f64 = 0.957;
const danger_g: f64 = 0.627;
const danger_b: f64 = 0.627;
const on_accent_r: f64 = 0.043;
const on_accent_g: f64 = 0.102;
const on_accent_b: f64 = 0.141;

const max_username = 32;
const max_full = 128;
const max_host = 64;
const max_pw = 64;
const max_cur = 64;

const linux = std.os.linux;

fn nowMs() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(@max(ts.sec, 0))) * 1000 +
        @as(i64, @divTrunc(@max(ts.nsec, 0), 1_000_000));
}

/// 500 ms caret blink, like the popups.
fn caretOn() bool {
    return @mod(@divTrunc(nowMs(), 500), 2) == 0;
}

fn popByte(buf: []u8, len: *usize) void {
    if (len.* == 0) return;
    var end = len.* - 1;
    while (end > 0 and (buf[end] & 0xC0) == 0x80) end -= 1;
    len.* = end;
}

fn copyField(buf: []u8, s: []const u8) usize {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return n;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn dirName(buf: []u8, path: []const u8) []const u8 {
    const n = @min(path.len, buf.len);
    @memcpy(buf[0..n], path[0..n]);
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested at the bottom)
// ---------------------------------------------------------------------------

/// GECOS's first comma-separated field, falling back to the login name —
/// `full_from_gecos`.
pub fn fullFromGecos(gecos: []const u8, name: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, gecos, ',') orelse gecos.len;
    const raw = gecos[0..end];
    return if (raw.len > 0) raw else name;
}

/// `accounts_valid_fullname`: non-empty, no NUL/colon/newline.
pub fn validFullName(f: []const u8) bool {
    if (f.len == 0 or f.len > max_full) return false;
    for (f) |c| {
        if (c == 0 or c == ':' or c == '\n' or c == '\r') return false;
    }
    return true;
}

/// `passwd -S` output: `name STATUS …` with status L (locked), P (usable)
/// or NP (no password). Returns the locked bit, or null when the line does
/// not belong to `username` / uses an unknown status.
pub fn parseLockStatus(out: []const u8, username: []const u8) ?bool {
    const line = std.mem.trim(u8, out, " \t\r\n");
    if (line.len == 0) return null;
    var it = std.mem.tokenizeAny(u8, line, " \t\r\n");
    const who = it.next() orelse return null;
    if (!std.mem.eql(u8, who, username)) return null;
    const st = it.next() orelse return null;
    if (std.mem.eql(u8, st, "L")) return true;
    if (std.mem.eql(u8, st, "P") or std.mem.eql(u8, st, "NP")) return false;
    return null;
}

pub const GroupEntry = struct { gid: u32, members: []const u8 };

/// One `/etc/group` line whose group name matches `name`; slices point into
/// `content`, which the caller must keep alive while the entry is used.
pub fn findGroup(content: []const u8, name: []const u8) ?GroupEntry {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, ':');
        const gname = f.next() orelse continue;
        if (!std.mem.eql(u8, gname, name)) continue;
        _ = f.next() orelse continue;
        const gid_s = f.next() orelse continue;
        const gid = std.fmt.parseInt(u32, trim(gid_s), 10) catch continue;
        const members = f.next() orelse "";
        return .{ .gid = gid, .members = members };
    }
    return null;
}

pub fn groupHasMember(members: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, members, ',');
    while (it.next()) |m| {
        if (std.mem.eql(u8, trim(m), name)) return true;
    }
    return false;
}

pub fn strOn(v: []const u8) bool {
    const s = trim(v);
    return std.ascii.eqlIgnoreCase(s, "true") or
        std.ascii.eqlIgnoreCase(s, "yes") or
        std.mem.eql(u8, s, "1");
}

/// Last `key=value` under `[section]` wins, matching the reference's
/// ordered scan (`ini_get`).
pub fn iniGet(content: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var cur: []const u8 = "";
    var val: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const t = trim(raw);
        if (t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']') {
            cur = t[1 .. t.len - 1];
            continue;
        }
        if (!std.mem.eql(u8, cur, section) or t.len == 0 or t[0] == '#' or t[0] == ';') continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        if (!std.mem.eql(u8, trim(t[0..eq]), key)) continue;
        val = trim(t[eq + 1 ..]);
    }
    return val;
}

fn appendIniLine(out: *std.ArrayList(u8), alloc: std.mem.Allocator, line: []const u8) !void {
    try out.appendSlice(alloc, line);
    try out.append(alloc, '\n');
}

fn appendIniKey(out: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try out.appendSlice(alloc, key);
    try out.append(alloc, '=');
    try out.appendSlice(alloc, value);
    try out.append(alloc, '\n');
}

fn lastLineIsBlank(text: []const u8) bool {
    if (text.len == 0) return true;
    var end = text.len;
    if (text[end - 1] == '\n') end -= 1;
    var start = end;
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    return std.mem.trim(u8, text[start..end], " \t\r").len == 0;
}

/// `ini_set`: replace the key inside `[section]` in place, append it to an
/// existing section, or add the section at the end. `erase` deletes the
/// matched line instead (GDM's `AutomaticLogin` disable). Caller owns the
/// result.
pub fn iniSet(
    alloc: std.mem.Allocator,
    content: []const u8,
    section: []const u8,
    key: []const u8,
    value: []const u8,
    erase: bool,
) ![]u8 {
    if (std.mem.trim(u8, content, " \t\r\n").len == 0) {
        if (erase) return alloc.dupe(u8, "");
        return std.fmt.allocPrint(alloc, "[{s}]\n{s}={s}\n", .{ section, key, value });
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var in_section = false;
    var section_seen = false;
    var done = false;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        // A trailing newline makes the split emit one empty token; the line
        // it would represent is already covered by the newline preserved
        // with the previous line, so skip it.
        if (raw.len == 0 and it.peek() == null and content[content.len - 1] == '\n') continue;
        const t = trim(raw);
        if (t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']') {
            if (in_section and !done and !erase) {
                try appendIniKey(&out, alloc, key, value);
                done = true;
            }
            in_section = std.mem.eql(u8, t[1 .. t.len - 1], section);
            if (in_section) section_seen = true;
            try appendIniLine(&out, alloc, raw);
            continue;
        }
        if (in_section and t.len > 0 and t[0] != '#' and t[0] != ';') {
            if (std.mem.indexOfScalar(u8, t, '=')) |eq| {
                if (std.mem.eql(u8, trim(t[0..eq]), key)) {
                    if (!erase) {
                        try appendIniKey(&out, alloc, key, value);
                        done = true;
                    }
                    continue;
                }
            }
        }
        try appendIniLine(&out, alloc, raw);
    }
    if (!done and !erase) {
        if (!section_seen) {
            if (!lastLineIsBlank(out.items)) try out.append(alloc, '\n');
            var hdr: [96]u8 = undefined;
            const hs = std.fmt.bufPrint(&hdr, "[{s}]", .{section}) catch return error.OutOfMemory;
            try appendIniLine(&out, alloc, hs);
        }
        try appendIniKey(&out, alloc, key, value);
    }
    return out.toOwnedSlice(alloc);
}

/// One or two upper-case initials for the avatar fallback: first letter of
/// the first and (when there is one) the last word.
pub fn initials(full: []const u8, name: []const u8, buf: []u8) []const u8 {
    const src = if (full.len > 0) full else name;
    var it = std.mem.tokenizeAny(u8, src, " \t");
    var first: u8 = 0;
    var last: u8 = 0;
    var words: usize = 0;
    while (it.next()) |w| {
        if (w.len == 0) continue;
        if (words == 0) first = w[0] else last = w[0];
        words += 1;
    }
    if (first == 0 and src.len > 0) first = src[0];
    var n: usize = 0;
    if (first != 0 and n < buf.len) {
        buf[n] = std.ascii.toUpper(first);
        n += 1;
    }
    if (words > 1 and last != 0 and n < buf.len) {
        buf[n] = std.ascii.toUpper(last);
        n += 1;
    }
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Data and page state
// ---------------------------------------------------------------------------

pub const User = struct {
    name: []u8,
    full: []u8,
    home: []u8,
    uid: u32,
    gid: u32,
    admin: bool = false,
    is_current: bool = false,
    locked: bool = false,
    lock_known: bool = false,
};

/// What the window must do after a page press. Only the avatar choice
/// touches `Settings`; every other action is a system change repainted from
/// the next refresh.
pub const Action = enum { redraw, persist };

pub const Geo = struct {
    content_x: i32,
    content_w: i32,
    win_w: i32,
    win_h: i32,
    scroll_px: i32,
};

const Dm = enum { none, gdm, sddm, lightdm };
const Modal = enum { none, add_user, password };
const Focus = enum { none, display_name, hostname };

const Dialog = struct {
    focus: u8 = 0,
    err_buf: [160]u8 = undefined,
    err_len: usize = 0,
    arm: i32 = -1,
    hover: i32 = -1,
};

fn lessThanUser(_: void, a: User, b: User) bool {
    if (a.is_current != b.is_current) return a.is_current;
    return std.mem.lessThan(u8, a.name, b.name);
}

pub const Page = struct {
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    inited: bool = false,
    settings: *app_mod.Settings = undefined,

    loaded: bool = false,
    last_refresh_ms: i64 = 0,

    users: std.ArrayList(User) = .empty,
    current_buf: [max_cur]u8 = undefined,
    current_len: usize = 0,
    selected_buf: [max_cur]u8 = undefined,
    selected_len: usize = 0,

    admin_name: []const u8 = "",
    has_admin_group: bool = false,

    host_buf: [max_host]u8 = undefined,
    host_len: usize = 0,
    sys_host_buf: [max_host]u8 = undefined,
    sys_host_len: usize = 0,

    name_buf: [max_full]u8 = undefined,
    name_len: usize = 0,
    focus: Focus = .none,

    delete_arm_buf: [max_cur]u8 = undefined,
    delete_arm_len: usize = 0,

    dm: Dm = .none,
    auto_enabled: bool = false,
    auto_user_buf: [max_cur]u8 = undefined,
    auto_user_len: usize = 0,

    modal: Modal = .none,
    dlg: Dialog = .{},
    add_user_buf: [max_username + 1]u8 = undefined,
    add_user_len: usize = 0,
    add_full_buf: [max_full + 1]u8 = undefined,
    add_full_len: usize = 0,
    add_pw_buf: [max_pw + 1]u8 = undefined,
    add_pw_len: usize = 0,
    add_confirm_buf: [max_pw + 1]u8 = undefined,
    add_confirm_len: usize = 0,
    add_admin: bool = false,
    pw_buf: [max_pw + 1]u8 = undefined,
    pw_len: usize = 0,
    pw_confirm_buf: [max_pw + 1]u8 = undefined,
    pw_confirm_len: usize = 0,
    pw_target_buf: [max_cur]u8 = undefined,
    pw_target_len: usize = 0,

    toast_buf: [200]u8 = undefined,
    toast_len: usize = 0,
    toast_err: bool = false,
    toast_ms: i64 = 0,

    avatars: std.StringHashMapUnmanaged(?*cairo.cairo_surface_t) = .empty,
    avatar_hold: ?[]u8 = null,

    pub fn init(self: *Page, gpa: std.mem.Allocator, io: std.Io, settings: *app_mod.Settings) void {
        self.* = .{};
        self.gpa = gpa;
        self.io = io;
        self.settings = settings;
        self.inited = true;
    }

    pub fn deinit(self: *Page) void {
        self.freeUsers();
        self.users.deinit(self.gpa);
        self.clearAvatars();
        self.avatars.deinit(self.gpa);
        if (self.avatar_hold) |p| self.gpa.free(p);
        self.avatar_hold = null;
        self.inited = false;
    }

    // -----------------------------------------------------------------
    // Load / refresh
    // -----------------------------------------------------------------

    fn ensureLoaded(self: *Page) void {
        if (self.loaded) return;
        self.loaded = true;
        self.loadCurrent();
        self.loadHostname();
        self.loadUsers();
        self.refreshAutologin();
        self.queryOwnLock();
        self.last_refresh_ms = nowMs();
    }

    /// The 2 s poll: user list, autologin config and (once) the own lock
    /// state, exactly the cadence `accounts_poll_refresh` keeps.
    fn refreshDue(self: *Page) void {
        self.ensureLoaded();
        const now = nowMs();
        if (now - self.last_refresh_ms < refresh_ms) return;
        self.last_refresh_ms = now;
        self.loadUsers();
        self.refreshAutologin();
        self.queryOwnLock();
    }

    fn loadCurrent(self: *Page) void {
        self.current_len = 0;
        if (std.c.getpwuid(std.c.getuid())) |pw| {
            if (pw.name) |n| self.current_len = copyField(self.current_buf[0..], std.mem.span(n));
        }
        if (self.current_len == 0) {
            if (std.c.getenv("USER")) |v| {
                self.current_len = copyField(self.current_buf[0..], std.mem.span(v));
            }
        }
        if (self.current_len == 0) {
            if (std.c.getenv("LOGNAME")) |v| {
                self.current_len = copyField(self.current_buf[0..], std.mem.span(v));
            }
        }
    }

    fn loadHostname(self: *Page) void {
        var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const h = std.posix.gethostname(&buf) catch "localhost";
        self.sys_host_len = copyField(self.sys_host_buf[0..], h);
        self.host_len = copyField(self.host_buf[0..], h);
    }

    fn freeUserValues(self: *Page, u: User) void {
        self.gpa.free(u.name);
        self.gpa.free(u.full);
        self.gpa.free(u.home);
    }

    fn freeUsers(self: *Page) void {
        for (self.users.items) |u| self.freeUserValues(u);
        self.users.clearRetainingCapacity();
    }

    /// `enumerate_users`: uid >= 1000 (plus the signed-in account whatever
    /// its uid, and never nobody), GECOS full name, admin membership from
    /// the detected group, current first then name order. Lock state is
    /// carried over from the previous list.
    fn loadUsers(self: *Page) void {
        var group_text: ?[]u8 = null;
        if (self.readFileAlloc("/etc/group", 1 << 20)) |t| group_text = t;
        defer if (group_text) |t| self.gpa.free(t);
        var admin: ?GroupEntry = null;
        var admin_is_wheel = false;
        if (group_text) |t| {
            if (findGroup(t, "wheel")) |g| {
                admin = g;
                admin_is_wheel = true;
            } else if (findGroup(t, "sudo")) |g| {
                admin = g;
            }
        }
        self.has_admin_group = admin != null;
        self.admin_name = if (admin == null) "" else if (admin_is_wheel) "wheel" else "sudo";

        var fresh: std.ArrayList(User) = .empty;
        var failed = false;
        std.c.setpwent();
        while (std.c.getpwent()) |pw| {
            const name_p = pw.name orelse continue;
            const name = std.mem.span(name_p);
            if (name.len == 0 or name.len > max_cur) continue;
            const is_cur = std.mem.eql(u8, name, self.currentName());
            if (!is_cur and (pw.uid < 1000 or pw.uid == 65534)) continue;
            const name_dup = self.gpa.dupe(u8, name) catch {
                failed = true;
                break;
            };
            const gecos = if (pw.gecos) |g| std.mem.span(g) else "";
            const full_dup = self.gpa.dupe(u8, fullFromGecos(gecos, name)) catch {
                self.gpa.free(name_dup);
                failed = true;
                break;
            };
            const home_src = if (pw.dir) |d| std.mem.span(d) else "";
            const home_dup = self.gpa.dupe(u8, home_src) catch {
                self.gpa.free(name_dup);
                self.gpa.free(full_dup);
                failed = true;
                break;
            };
            var u = User{
                .name = name_dup,
                .full = full_dup,
                .home = home_dup,
                .uid = pw.uid,
                .gid = pw.gid,
                .admin = if (admin) |a| (pw.gid == a.gid or groupHasMember(a.members, name)) else false,
                .is_current = is_cur,
            };
            if (self.findUserName(name)) |old| {
                u.locked = old.locked;
                u.lock_known = old.lock_known;
            }
            fresh.append(self.gpa, u) catch {
                self.freeUserValues(u);
                failed = true;
                break;
            };
        }
        std.c.endpwent();
        if (failed) {
            for (fresh.items) |u| self.freeUserValues(u);
            fresh.deinit(self.gpa);
            return;
        }
        std.mem.sort(User, fresh.items, {}, lessThanUser);
        self.freeUsers();
        self.users.deinit(self.gpa);
        self.users = fresh;
        self.ensureSelection();
        if (self.focus == .none) self.seedName();
        if (self.delete_arm_len > 0 and self.findUserName(self.deleteArmName()) == null) {
            self.delete_arm_len = 0;
        }
    }

    fn currentName(self: *const Page) []const u8 {
        return self.current_buf[0..self.current_len];
    }

    fn selectedName(self: *const Page) []const u8 {
        return self.selected_buf[0..self.selected_len];
    }

    fn autoUser(self: *const Page) []const u8 {
        return self.auto_user_buf[0..self.auto_user_len];
    }

    fn deleteArmName(self: *const Page) []const u8 {
        return self.delete_arm_buf[0..self.delete_arm_len];
    }

    fn findUserName(self: *Page, name: []const u8) ?*User {
        for (self.users.items) |*u| {
            if (std.mem.eql(u8, u.name, name)) return u;
        }
        return null;
    }

    fn selectedUser(self: *Page) ?*User {
        if (self.selected_len == 0) return null;
        return self.findUserName(self.selectedName());
    }

    fn copySelected(self: *Page, name: []const u8) void {
        self.selected_len = copyField(self.selected_buf[0..], name);
    }

    fn ensureSelection(self: *Page) void {
        if (self.selected_len > 0 and self.findUserName(self.selectedName()) != null) return;
        if (self.current_len > 0 and self.findUserName(self.currentName()) != null) {
            self.copySelected(self.currentName());
            return;
        }
        if (self.users.items.len > 0) self.copySelected(self.users.items[0].name);
    }

    fn selectUser(self: *Page, name: []const u8) void {
        self.copySelected(name);
        self.delete_arm_len = 0;
        self.focus = .none;
        self.seedName();
    }

    fn seedName(self: *Page) void {
        const u = self.selectedUser() orelse {
            self.name_len = 0;
            return;
        };
        self.name_len = copyField(self.name_buf[0..], u.full);
    }

    fn seedHost(self: *Page) void {
        self.host_len = copyField(self.host_buf[0..], self.sys_host_buf[0..self.sys_host_len]);
    }

    fn adminCount(self: *const Page) usize {
        var n: usize = 0;
        for (self.users.items) |u| {
            if (u.admin) n += 1;
        }
        return n;
    }

    fn setToast(self: *Page, msg: []const u8, err: bool) void {
        self.toast_len = copyField(self.toast_buf[0..], msg);
        self.toast_err = err;
        self.toast_ms = nowMs();
    }

    fn toastVisible(self: *const Page) bool {
        return self.toast_len > 0 and nowMs() - self.toast_ms < toast_ms;
    }

    fn setModalError(self: *Page, msg: []const u8) void {
        self.dlg.err_len = copyField(self.dlg.err_buf[0..], msg);
    }

    fn clearModalError(self: *Page) void {
        self.dlg.err_len = 0;
    }

    fn modalFields(self: *const Page) u8 {
        return if (self.modal == .password) pw_dlg_fields else add_dlg_fields;
    }

    fn dmName(self: *const Page) []const u8 {
        return switch (self.dm) {
            .gdm => "GDM",
            .sddm => "SDDM",
            .lightdm => "LightDM",
            .none => "",
        };
    }

    // -----------------------------------------------------------------
    // Process / file helpers
    // -----------------------------------------------------------------

    fn readFileAlloc(self: *Page, path: []const u8, limit: usize) ?[]u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(limit)) catch null;
    }

    fn pathExists(self: *Page, path: []const u8) bool {
        std.Io.Dir.accessAbsolute(self.io, path, .{}) catch return false;
        return true;
    }

    fn readableFile(self: *Page, path: []const u8) bool {
        var f = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return false;
        f.close(self.io);
        return true;
    }

    /// Literal `pkexec` argv, blocking for the answer like the reference.
    fn runPriv(self: *Page, argv: []const []const u8) bool {
        const res = std.process.run(self.gpa, self.io, .{ .argv = argv }) catch return false;
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        return switch (res.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    /// Same, capturing stdout (for `passwd -S`) into `out`.
    fn runCapture(self: *Page, argv: []const []const u8, out: []u8) ?[]const u8 {
        const res = std.process.run(self.gpa, self.io, .{ .argv = argv }) catch return null;
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        switch (res.term) {
            .exited => |code| if (code != 0) return null,
            else => return null,
        }
        const n = @min(out.len, res.stdout.len);
        @memcpy(out[0..n], res.stdout[0..n]);
        return out[0..n];
    }

    /// Runs `argv` with `input` on stdin — `chpasswd`, `tee`. `process.run`
    /// has no stdin, so this drives the pipes directly.
    fn runPrivInput(self: *Page, argv: []const []const u8, input: []const u8) bool {
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch return false;
        var ok = true;
        if (child.stdin) |f| {
            f.writeStreamingAll(self.io, input) catch {
                ok = false;
            };
            f.close(self.io);
            child.stdin = null;
        }
        self.drainPipe(child.stdout);
        self.drainPipe(child.stderr);
        const term = child.wait(self.io) catch return false;
        if (!ok) return false;
        return switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    fn drainPipe(self: *Page, file_opt: ?std.Io.File) void {
        const f = file_opt orelse return;
        var buf: [512]u8 = undefined;
        var r = f.reader(self.io, &buf);
        _ = r.interface.discardRemaining() catch {};
    }

    // -----------------------------------------------------------------
    // Lock state
    // -----------------------------------------------------------------

    /// Once per session, unprivileged `passwd -S` for the signed-in user
    /// (the reference's `query_locked` self branch).
    fn queryOwnLock(self: *Page) void {
        if (self.current_len == 0) return;
        const u = self.findUserName(self.currentName()) orelse return;
        if (u.lock_known) return;
        var out: [512]u8 = undefined;
        const text = self.runCapture(&.{ "passwd", "-S" }, &out) orelse return;
        if (parseLockStatus(text, self.currentName())) |locked| {
            u.locked = locked;
            u.lock_known = true;
        }
    }

    /// `accounts_query_locked`: self unprivileged, others through pkexec.
    /// Updates the user's cached state on success.
    fn queryLocked(self: *Page, u: *User) ?bool {
        var out: [512]u8 = undefined;
        var text: ?[]const u8 = null;
        if (u.is_current) {
            text = self.runCapture(&.{ "passwd", "-S" }, &out);
        } else if (accounts_data.isValidUsername(u.name)) {
            text = self.runCapture(&.{ "pkexec", "passwd", "-S", u.name }, &out);
        }
        const t = text orelse return null;
        const locked = parseLockStatus(t, u.name) orelse return null;
        u.locked = locked;
        u.lock_known = true;
        return locked;
    }

    // -----------------------------------------------------------------
    // Autologin
    // -----------------------------------------------------------------

    fn refreshAutologin(self: *Page) void {
        self.dm = .none;
        self.auto_enabled = false;
        self.auto_user_len = 0;
        if (self.pathExists("/usr/bin/gdm") or self.pathExists("/usr/sbin/gdm") or
            self.pathExists("/etc/gdm/custom.conf"))
        {
            self.dm = .gdm;
            const text_opt = self.readFileAlloc("/etc/gdm/custom.conf", 1 << 20);
            defer if (text_opt) |t| self.gpa.free(t);
            const text = text_opt orelse "";
            const user = iniGet(text, "daemon", "AutomaticLogin") orelse "";
            const on = strOn(iniGet(text, "daemon", "AutomaticLoginEnable") orelse "");
            self.auto_user_len = copyField(self.auto_user_buf[0..], user);
            self.auto_enabled = on and user.len > 0;
            return;
        }
        if (self.pathExists("/usr/bin/sddm") or self.pathExists("/etc/sddm.conf") or
            self.pathExists("/etc/sddm.conf.d"))
        {
            self.dm = .sddm;
            var user_buf: [max_cur]u8 = undefined;
            const user = self.sddmMerged("User", &user_buf);
            self.auto_user_len = copyField(self.auto_user_buf[0..], user);
            self.auto_enabled = user.len > 0;
            return;
        }
        if (self.pathExists("/usr/sbin/lightdm") or self.pathExists("/etc/lightdm/lightdm.conf")) {
            self.dm = .lightdm;
            const text_opt = self.readFileAlloc("/etc/lightdm/lightdm.conf", 1 << 20);
            defer if (text_opt) |t| self.gpa.free(t);
            const text = text_opt orelse "";
            const user = iniGet(text, "Seat:*", "autologin-user") orelse "";
            self.auto_user_len = copyField(self.auto_user_buf[0..], user);
            self.auto_enabled = user.len > 0;
        }
    }

    /// SDDM's effective key: `/etc/sddm.conf`, then every `*.conf` under
    /// `/etc/sddm.conf.d` in sorted order (later wins).
    fn sddmMerged(self: *Page, ini_key: []const u8, out: []u8) []const u8 {
        var len: usize = 0;
        if (self.readFileAlloc("/etc/sddm.conf", 1 << 20)) |text| {
            defer self.gpa.free(text);
            if (iniGet(text, "Autologin", ini_key)) |v| len = copyField(out, v);
        }
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| self.gpa.free(n);
            names.deinit(self.gpa);
        }
        var dir = std.Io.Dir.cwd().openDir(self.io, "/etc/sddm.conf.d", .{ .iterate = true }) catch
            return out[0..len];
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |e| {
            if (e.kind != .file) continue;
            if (!std.mem.endsWith(u8, e.name, ".conf")) continue;
            const dup = self.gpa.dupe(u8, e.name) catch continue;
            names.append(self.gpa, dup) catch self.gpa.free(dup);
        }
        std.mem.sort([]u8, names.items, {}, lessThanName);
        for (names.items) |n| {
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/etc/sddm.conf.d/{s}", .{n}) catch continue;
            const text = self.readFileAlloc(path, 1 << 20) orelse continue;
            defer self.gpa.free(text);
            if (iniGet(text, "Autologin", ini_key)) |v| {
                if (v.len > 0) len = copyField(out, v);
            }
        }
        return out[0..len];
    }

    fn applyAutologin(self: *Page, username: []const u8, enable: bool) bool {
        switch (self.dm) {
            .none => return false,
            .gdm => {
                const text_opt = self.readFileAlloc("/etc/gdm/custom.conf", 1 << 20);
                defer if (text_opt) |t| self.gpa.free(t);
                const base = text_opt orelse "# GDM configuration\n";
                const c1 = iniSet(self.gpa, base, "daemon", "AutomaticLoginEnable", if (enable) "True" else "False", false) catch return false;
                defer self.gpa.free(c1);
                const c2 = iniSet(self.gpa, c1, "daemon", "AutomaticLogin", username, !enable) catch return false;
                defer self.gpa.free(c2);
                return self.runPrivInput(&.{ "pkexec", "tee", "/etc/gdm/custom.conf" }, c2);
            },
            .sddm => {
                if (!enable) {
                    return self.runPriv(&.{ "pkexec", "rm", "-f", "/etc/sddm.conf.d/10-event-horizon-autologin.conf" });
                }
                var session_buf: [max_cur]u8 = undefined;
                const session = self.sddmMerged("Session", &session_buf);
                var content: std.ArrayList(u8) = .empty;
                defer content.deinit(self.gpa);
                content.appendSlice(self.gpa, "[Autologin]\n") catch return false;
                var line_buf: [256]u8 = undefined;
                const l1 = std.fmt.bufPrint(&line_buf, "User={s}\n", .{username}) catch return false;
                content.appendSlice(self.gpa, l1) catch return false;
                if (session.len > 0) {
                    var sline: [256]u8 = undefined;
                    const l2 = std.fmt.bufPrint(&sline, "Session={s}\n", .{session}) catch return false;
                    content.appendSlice(self.gpa, l2) catch return false;
                }
                return self.runPrivInput(&.{ "pkexec", "tee", "/etc/sddm.conf.d/10-event-horizon-autologin.conf" }, content.items);
            },
            .lightdm => {
                const text_opt = self.readFileAlloc("/etc/lightdm/lightdm.conf", 1 << 20);
                defer if (text_opt) |t| self.gpa.free(t);
                const base = text_opt orelse "";
                const next = iniSet(self.gpa, base, "Seat:*", "autologin-user", username, !enable) catch return false;
                defer self.gpa.free(next);
                return self.runPrivInput(&.{ "pkexec", "tee", "/etc/lightdm/lightdm.conf" }, next);
            },
        }
    }

    // -----------------------------------------------------------------
    // Avatars
    // -----------------------------------------------------------------

    fn decodeAvatar(self: *Page, path: []const u8) ?*cairo.cairo_surface_t {
        var img = decode.loadRgba(self.gpa, path) orelse return null;
        defer img.free(self.gpa);
        if (img.w <= 0 or img.h <= 0) return null;
        const w: usize = @intCast(img.w);
        const h: usize = @intCast(img.h);
        if (img.pixels.len < w * h * 4) return null;
        const surf = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, img.w, img.h);
        if (cairo.cairo_surface_status(surf) != cairo.CAIRO_STATUS_SUCCESS) {
            cairo.cairo_surface_destroy(surf);
            return null;
        }
        const data = cairo.cairo_image_surface_get_data(surf);
        const stride = cairo.cairo_image_surface_get_stride(surf);
        if (data == null or stride <= 0) {
            cairo.cairo_surface_destroy(surf);
            return null;
        }
        const dst: [*]u8 = @ptrCast(data);
        const stride_us: usize = @intCast(stride);
        var y: usize = 0;
        while (y < h) : (y += 1) {
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const si = (y * w + x) * 4;
                const a: u32 = img.pixels[si + 3];
                const r: u32 = img.pixels[si];
                const g: u32 = img.pixels[si + 1];
                const b: u32 = img.pixels[si + 2];
                const rp: u8 = @intCast((r * a + 127) / 255);
                const gp: u8 = @intCast((g * a + 127) / 255);
                const bp: u8 = @intCast((b * a + 127) / 255);
                const off = y * stride_us + x * 4;
                dst[off] = bp;
                dst[off + 1] = gp;
                dst[off + 2] = rp;
                dst[off + 3] = @intCast(a);
            }
        }
        cairo.cairo_surface_mark_dirty(surf);
        return surf;
    }

    /// Explicit `settings.avatar_path` for self, then `~/.face`, then
    /// AccountsService. Cached per user name; a miss is cached as null.
    fn avatarSurface(self: *Page, u: *const User) ?*cairo.cairo_surface_t {
        if (self.avatars.get(u.name)) |surf| return surf;
        var surf: ?*cairo.cairo_surface_t = null;
        if (u.is_current and self.settings.avatar_path.len > 0) {
            surf = self.decodeAvatar(self.settings.avatar_path);
        }
        if (surf == null and u.home.len > 0) {
            var buf: [1024]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{s}/.face", .{u.home})) |p| {
                surf = self.decodeAvatar(p);
            } else |_| {}
        }
        if (surf == null) {
            var buf: [1024]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "/var/lib/AccountsService/icons/{s}", .{u.name})) |p| {
                surf = self.decodeAvatar(p);
            } else |_| {}
        }
        const cache_key = self.gpa.dupe(u8, u.name) catch return surf;
        self.avatars.put(self.gpa, cache_key, surf) catch {
            self.gpa.free(cache_key);
            return surf;
        };
        return surf;
    }

    fn invalidateAvatar(self: *Page, name: []const u8) void {
        if (self.avatars.fetchRemove(name)) |kv| {
            if (kv.value) |s| cairo.cairo_surface_destroy(s);
            self.gpa.free(kv.key);
        }
    }

    fn clearAvatars(self: *Page) void {
        var it = self.avatars.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*) |s| cairo.cairo_surface_destroy(s);
            self.gpa.free(e.key_ptr.*);
        }
        self.avatars.clearRetainingCapacity();
    }

    /// `accounts_install_avatar`: probe-decode, then copy to `~/.face` —
    /// directly for self, through `pkexec install` for other users.
    fn installAvatar(self: *Page, u: *const User, src: []const u8) bool {
        if (!accounts_data.isValidUsername(u.name)) {
            self.setToast("Invalid user name.", true);
            return false;
        }
        if (u.home.len == 0 or u.home[0] != '/') {
            self.setToast("Unknown home directory.", true);
            return false;
        }
        if (!self.readableFile(src)) {
            self.setToast("Cannot read the chosen image.", true);
            return false;
        }
        const probe = self.decodeAvatar(src) orelse {
            self.setToast("Unsupported image file.", true);
            return false;
        };
        cairo.cairo_surface_destroy(probe);
        var dst_buf: [1024]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/.face", .{u.home}) catch {
            self.setToast("Avatar path too long.", true);
            return false;
        };
        if (u.is_current) {
            const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, src, self.gpa, .limited(64 << 20)) catch {
                self.setToast("Cannot read the chosen image.", true);
                return false;
            };
            defer self.gpa.free(bytes);
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = dst, .data = bytes }) catch {
                self.setToast("Failed to save avatar.", true);
                return false;
            };
            return true;
        }
        var gid_buf: [16]u8 = undefined;
        const gid_s = std.fmt.bufPrint(&gid_buf, "{d}", .{u.gid}) catch return false;
        if (!self.runPriv(&.{ "pkexec", "install", "-o", u.name, "-g", gid_s, "-m", "0644", src, dst })) {
            self.setToast("Failed to install avatar.", true);
            return false;
        }
        return true;
    }

    /// Zenity file picker, then install. Returns true when `Settings`
    /// changed (self avatar), which the window persists as `[general]`.
    fn actChooseAvatar(self: *Page) bool {
        const u = self.selectedUser() orelse {
            self.setToast("No user account selected.", true);
            return false;
        };
        const res = std.process.run(self.gpa, self.io, .{ .argv = &.{
            "zenity",                 "--file-selection",
            "--title=Choose Avatar Image", "--file-filter=*.png *.jpg *.jpeg",
        } }) catch {
            self.setToast("Install zenity for file picker.", true);
            return false;
        };
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        switch (res.term) {
            .exited => |code| {
                if (code != 0) return false; // cancelled
            },
            else => return false,
        }        const path = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (path.len == 0 or path.len >= 1024) return false;
        if (!self.installAvatar(u, path)) return false;
        self.invalidateAvatar(u.name);
        var msg: [96]u8 = undefined;
        const m = std.fmt.bufPrint(&msg, "Avatar updated for '{s}'.", .{u.name}) catch "Avatar updated.";
        self.setToast(m, false);
        if (!u.is_current) return false;
        if (self.avatar_hold) |p| self.gpa.free(p);
        self.avatar_hold = self.gpa.dupe(u8, path) catch null;
        self.settings.avatar_path = self.avatar_hold orelse "";
        return true;
    }

    // -----------------------------------------------------------------
    // Actions
    // -----------------------------------------------------------------

    fn actSaveFullName(self: *Page) void {
        const u = self.selectedUser() orelse {
            self.setToast("No user account selected.", true);
            return;
        };
        const name = self.name_buf[0..self.name_len];
        if (!validFullName(name)) {
            self.setToast("Full name is empty.", true);
            return;
        }
        const ok = self.runPriv(&.{ "pkexec", "usermod", "-c", name, u.name });
        self.loadUsers();
        if (ok) {
            self.setToast("Full name updated.", false);
        } else {
            self.setToast("Failed to update full name.", true);
        }
    }

    fn actToggleAdmin(self: *Page) void {
        const u = self.selectedUser() orelse {
            self.setToast("No user account selected.", true);
            return;
        };
        var target: [max_cur]u8 = undefined;
        const tlen = copyField(target[0..], u.name);
        const name = target[0..tlen];
        const want = !u.admin;
        if (!want and self.adminCount() <= 1) {
            self.setToast("Cannot remove the last administrator.", true);
            return;
        }
        if (want and !self.has_admin_group) {
            self.setToast("No administrator group (wheel/sudo) found.", true);
            return;
        }
        const ok = if (want)
            self.runPriv(&.{ "pkexec", "usermod", "-aG", self.admin_name, name })
        else
            self.runPriv(&.{ "pkexec", "gpasswd", "-d", name, self.admin_name });
        self.loadUsers();
        if (!ok) {
            self.setToast("Failed to change administrator rights.", true);
            return;
        }
        var msg: [96]u8 = undefined;
        const m: []const u8 = if (want)
            std.fmt.bufPrint(&msg, "'{s}' is now an administrator.", .{name}) catch "Administrator added."
        else
            std.fmt.bufPrint(&msg, "'{s}' is now a standard user.", .{name}) catch "Administrator removed.";
        self.setToast(m, false);
    }

    fn actToggleLock(self: *Page) void {
        const u = self.selectedUser() orelse {
            self.setToast("No user account selected.", true);
            return;
        };
        var target: [max_cur]u8 = undefined;
        const tlen = copyField(target[0..], u.name);
        const name = target[0..tlen];
        if (u.is_current) {
            self.setToast("You cannot lock your own account.", true);
            return;
        }
        if (!u.lock_known) {
            // First click only reads the state; later clicks flip it.
            if (self.queryLocked(u)) |locked| {
                var msg: [96]u8 = undefined;
                const m: []const u8 = if (locked)
                    std.fmt.bufPrint(&msg, "'{s}' is currently locked.", .{name}) catch "Account is locked."
                else
                    std.fmt.bufPrint(&msg, "'{s}' is currently unlocked.", .{name}) catch "Account is unlocked.";
                self.setToast(m, false);
            } else {
                self.setToast("Could not read lock state (authentication needed?).", true);
            }
            return;
        }
        const want = !u.locked;
        const ok = if (want)
            self.runPriv(&.{ "pkexec", "passwd", "-l", name })
        else
            self.runPriv(&.{ "pkexec", "passwd", "-u", name });
        if (!ok) {
            self.setToast("Failed to change account lock.", true);
            return;
        }
        if (self.queryLocked(u)) |locked| {
            var msg: [96]u8 = undefined;
            const m: []const u8 = if (locked)
                std.fmt.bufPrint(&msg, "'{s}' is locked.", .{name}) catch "Account locked."
            else
                std.fmt.bufPrint(&msg, "'{s}' is unlocked.", .{name}) catch "Account unlocked.";
            self.setToast(m, false);
        } else {
            u.locked = want;
            u.lock_known = true;
            self.setToast(if (want) "Lock requested." else "Unlock requested.", false);
        }
    }

    fn setPasswordFor(self: *Page, username: []const u8, pass: []const u8) bool {
        if (!accounts_data.isValidUsername(username)) return false;
        if (pass.len < 4) return false;
        for (pass) |c| {
            if (c == '\n' or c == '\r' or c == 0) return false;
        }
        var line_buf: [max_username + max_pw + 4]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}:{s}\n", .{ username, pass }) catch return false;
        return self.runPrivInput(&.{ "pkexec", "chpasswd" }, line);
    }

    fn userExists(name: []const u8) bool {
        if (name.len == 0 or name.len > max_username) return false;
        var zbuf: [max_username + 1]u8 = @splat(0);
        @memcpy(zbuf[0..name.len], name);
        const z: [*:0]const u8 = @ptrCast(&zbuf);
        return std.c.getpwnam(z) != null;
    }

    fn openAddDialog(self: *Page) void {
        self.add_user_len = 0;
        self.add_full_len = 0;
        self.add_pw_len = 0;
        self.add_confirm_len = 0;
        self.add_admin = false;
        self.focus = .none;
        self.modal = .add_user;
        self.dlg = .{ .focus = 0 };
    }

    fn openPasswordDialog(self: *Page) void {
        const u = self.selectedUser() orelse {
            self.setToast("No user account selected.", true);
            return;
        };
        self.pw_len = 0;
        self.pw_confirm_len = 0;
        self.pw_target_len = copyField(self.pw_target_buf[0..], u.name);
        self.focus = .none;
        self.modal = .password;
        self.dlg = .{ .focus = 0 };
    }

    fn submitPassword(self: *Page) void {
        const name = self.pw_target_buf[0..self.pw_target_len];
        const pw = self.pw_buf[0..self.pw_len];
        const confirm = self.pw_confirm_buf[0..self.pw_confirm_len];
        if (self.pw_len == 0 or self.pw_confirm_len == 0) {
            self.setModalError("Please fill in both fields.");
            return;
        }
        if (!std.mem.eql(u8, pw, confirm)) {
            self.setModalError("Passwords do not match.");
            return;
        }
        if (pw.len < 4) {
            self.setModalError("Password too short (min 4 chars).");
            return;
        }
        if (!self.setPasswordFor(name, pw)) {
            self.setModalError("Failed to change password.");
            return;
        }
        self.modal = .none;
        var msg: [96]u8 = undefined;
        const m: []const u8 = std.fmt.bufPrint(&msg, "Password changed for '{s}'.", .{name}) catch "Password changed.";
        self.setToast(m, false);
    }

    fn submitAddUser(self: *Page) void {
        const username = self.add_user_buf[0..self.add_user_len];
        const full = self.add_full_buf[0..self.add_full_len];
        const pw = self.add_pw_buf[0..self.add_pw_len];
        const confirm = self.add_confirm_buf[0..self.add_confirm_len];
        if (!accounts_data.isValidUsername(username)) {
            self.setModalError("Invalid username (a-z, 0-9, _, -, max 32).");
            return;
        }
        if (!validFullName(full)) {
            self.setModalError("Invalid full name.");
            return;
        }
        if (self.add_pw_len == 0 or self.add_confirm_len == 0) {
            self.setModalError("Please fill in both fields.");
            return;
        }
        if (!std.mem.eql(u8, pw, confirm)) {
            self.setModalError("Passwords do not match.");
            return;
        }
        if (pw.len < 4) {
            self.setModalError("Password too short (min 4 chars).");
            return;
        }
        for (pw) |c| {
            if (c == '\n' or c == '\r' or c == 0) {
                self.setModalError("Password cannot contain newlines.");
                return;
            }
        }
        if (userExists(username)) {
            var msg: [96]u8 = undefined;
            const m: []const u8 = std.fmt.bufPrint(&msg, "User '{s}' already exists.", .{username}) catch "User already exists.";
            self.setModalError(m);
            return;
        }
        if (self.add_admin and !self.has_admin_group) {
            self.setModalError("No administrator group (wheel/sudo) found.");
            return;
        }
        var name_copy: [max_cur]u8 = undefined;
        const nlen = copyField(name_copy[0..], username);
        const target = name_copy[0..nlen];
        var argv_buf: [12][]const u8 = undefined;
        var n: usize = 0;
        argv_buf[n] = "pkexec";
        n += 1;
        argv_buf[n] = "useradd";
        n += 1;
        argv_buf[n] = "-m";
        n += 1;
        argv_buf[n] = "-s";
        n += 1;
        argv_buf[n] = "/bin/bash";
        n += 1;
        argv_buf[n] = "-c";
        n += 1;
        argv_buf[n] = full;
        n += 1;
        const was_admin = self.add_admin;
        if (self.add_admin) {
            argv_buf[n] = "-G";
            n += 1;
            argv_buf[n] = self.admin_name;
            n += 1;
        }
        argv_buf[n] = username;
        n += 1;
        if (!self.runPriv(argv_buf[0..n])) {
            self.setModalError("Failed to create user (already exists?).");
            return;
        }
        const pw_ok = self.setPasswordFor(username, pw);
        self.loadUsers();
        if (self.findUserName(target) != null) self.selectUser(target);
        self.modal = .none;
        if (!pw_ok) {
            self.setToast("User created but password failed.", true);
            return;
        }
        var msg: [128]u8 = undefined;
        const m: []const u8 = std.fmt.bufPrint(&msg, "User '{s}' created.{s}", .{
            target,
            if (was_admin) " (administrator)" else "",
        }) catch "User created.";
        self.setToast(m, false);
    }

    fn actDeleteUser(self: *Page) void {
        const u = self.selectedUser() orelse {
            self.setToast("No user account selected.", true);
            return;
        };
        var target: [max_cur]u8 = undefined;
        const tlen = copyField(target[0..], u.name);
        const name = target[0..tlen];
        if (u.is_current) {
            self.setToast("You cannot delete your own account.", true);
            return;
        }
        if (u.admin and self.adminCount() <= 1) {
            self.setToast("Cannot remove the last administrator.", true);
            return;
        }
        if (!std.mem.eql(u8, self.deleteArmName(), name)) {
            self.delete_arm_len = copyField(self.delete_arm_buf[0..], name);
            self.setToast("Click Delete User again to confirm.", true);
            return;
        }
        self.delete_arm_len = 0;
        const ok = self.runPriv(&.{ "pkexec", "userdel", "-r", name });
        self.loadUsers();
        if (ok) {
            var msg: [96]u8 = undefined;
            const m: []const u8 = std.fmt.bufPrint(&msg, "User '{s}' deleted.", .{name}) catch "User deleted.";
            self.setToast(m, false);
        } else {
            self.setToast("Failed to delete user.", true);
        }
    }

    fn actToggleAutologin(self: *Page) void {
        const u = self.selectedUser() orelse {
            self.setToast("No user account selected.", true);
            return;
        };
        if (self.dm == .none) {
            self.setToast("No supported login manager (GDM/SDDM/LightDM) detected.", true);
            return;
        }
        var target: [max_cur]u8 = undefined;
        const tlen = copyField(target[0..], u.name);
        const name = target[0..tlen];
        const on = self.auto_enabled and std.mem.eql(u8, self.autoUser(), name);
        const want = !on;
        if (!self.applyAutologin(name, want)) {
            var msg: [96]u8 = undefined;
            const m: []const u8 = std.fmt.bufPrint(&msg, "Failed to update {s} autologin.", .{self.dmName()}) catch "Failed to update autologin.";
            self.setToast(m, true);
            return;
        }
        self.refreshAutologin();
        var msg: [96]u8 = undefined;
        const m: []const u8 = if (want)
            std.fmt.bufPrint(&msg, "Automatic login enabled for '{s}' ({s}).", .{ name, self.dmName() }) catch "Automatic login enabled."
        else
            std.fmt.bufPrint(&msg, "Automatic login disabled ({s}).", .{self.dmName()}) catch "Automatic login disabled.";
        self.setToast(m, false);
    }

    fn actApplyHostname(self: *Page) void {
        var copy_buf: [max_host]u8 = undefined;
        const hlen = copyField(copy_buf[0..], self.host_buf[0..self.host_len]);
        const host = copy_buf[0..hlen];
        if (!accounts_data.isValidHostname(host)) {
            self.setToast("Invalid hostname.", true);
            return;
        }
        if (!self.runPriv(&.{ "pkexec", "hostnamectl", "set-hostname", host })) {
            self.setToast("Failed to set hostname.", true);
            return;
        }
        self.loadHostname();
        self.setToast("Hostname changed.", false);
    }

    // -----------------------------------------------------------------
    // Keyboard
    // -----------------------------------------------------------------

    fn modalKey(self: *Page, sym: u32, text: []const u8) void {
        switch (sym) {
            xkb.XKB_KEY_Escape => {
                self.modal = .none;
                return;
            },
            xkb.XKB_KEY_Tab => {
                const n = self.modalFields();
                self.dlg.focus = (self.dlg.focus + 1) % n;
                return;
            },
            xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => {
                if (self.modal == .password) self.submitPassword() else self.submitAddUser();
                return;
            },
            xkb.XKB_KEY_BackSpace => {
                self.clearModalError();
                const f = self.dlg.focus;
                if (self.modal == .password) {
                    if (f == 0) {
                        popByte(self.pw_buf[0..], &self.pw_len);
                    } else {
                        popByte(self.pw_confirm_buf[0..], &self.pw_confirm_len);
                    }
                } else switch (f) {
                    0 => popByte(self.add_user_buf[0..], &self.add_user_len),
                    1 => popByte(self.add_full_buf[0..], &self.add_full_len),
                    2 => popByte(self.add_pw_buf[0..], &self.add_pw_len),
                    else => popByte(self.add_confirm_buf[0..], &self.add_confirm_len),
                }
                return;
            },
            else => {},
        }
        if (text.len == 0 or text[0] < 0x20 or text[0] == 0x7f) return;
        self.clearModalError();
        const f = self.dlg.focus;
        if (self.modal == .password) {
            if (f == 0) {
                appendText(self.pw_buf[0..], &self.pw_len, text);
            } else {
                appendText(self.pw_confirm_buf[0..], &self.pw_confirm_len, text);
            }
        } else switch (f) {
            0 => appendText(self.add_user_buf[0..], &self.add_user_len, text),
            1 => appendText(self.add_full_buf[0..], &self.add_full_len, text),
            2 => appendText(self.add_pw_buf[0..], &self.add_pw_len, text),
            else => appendText(self.add_confirm_buf[0..], &self.add_confirm_len, text),
        }
    }

    pub fn key(self: *Page, sym: u32, text: []const u8) bool {
        if (!self.inited) return false;
        if (self.modal != .none) {
            self.modalKey(sym, text);
            return true;
        }
        switch (self.focus) {
            .none => return false,
            .display_name => {
                switch (sym) {
                    xkb.XKB_KEY_Escape => {
                        self.focus = .none;
                        self.seedName();
                    },
                    xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => {
                        self.actSaveFullName();
                        self.focus = .none;
                    },
                    xkb.XKB_KEY_Tab => {
                        self.seedHost();
                        self.focus = .hostname;
                    },
                    xkb.XKB_KEY_BackSpace => popByte(self.name_buf[0..], &self.name_len),
                    else => {
                        if (text.len > 0 and text[0] >= 0x20 and text[0] != 0x7f) {
                            appendText(self.name_buf[0..], &self.name_len, text);
                        }
                    },
                }
                return true;
            },
            .hostname => {
                switch (sym) {
                    xkb.XKB_KEY_Escape => {
                        self.focus = .none;
                        self.seedHost();
                    },
                    xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => {
                        self.actApplyHostname();
                        self.focus = .none;
                    },
                    xkb.XKB_KEY_Tab => {
                        self.focus = .display_name;
                    },
                    xkb.XKB_KEY_BackSpace => popByte(self.host_buf[0..], &self.host_len),
                    else => {
                        if (text.len > 0 and text[0] >= 0x20 and text[0] != 0x7f) {
                            appendText(self.host_buf[0..], &self.host_len, text);
                        }
                    },
                }
                return true;
            },
        }
    }

    // -----------------------------------------------------------------
    // Layout
    // -----------------------------------------------------------------

    fn userCount(self: *const Page) i32 {
        return @intCast(@max(self.users.items.len, 1));
    }

    pub fn totalHeight(self: *Page, g: Geo) i32 {
        if (!self.inited) return 0;
        self.refreshDue();
        return self.layoutFor(g).total_h;
    }

    fn layoutFor(self: *const Page, g: Geo) Layout {
        const card_x = g.content_x + 8;
        const card_w = g.content_w - 16;
        const two = card_w >= two_col_min_card_w;
        const users_h = users_head_band + self.userCount() * user_row_h + add_area_h;
        var l: Layout = .{
            .g = g,
            .card_x = card_x,
            .card_w = card_w,
            .two_col = two,
            .users_x = card_x,
            .users_w = card_w,
            .users_top = common.content_top,
            .users_h = users_h,
            .profile_x = card_x,
            .profile_w = card_w,
            .profile_top = common.content_top,
            .profile_h = 0,
            .access_top = 0,
            .access_h = 0,
            .device_top = 0,
            .device_h = 0,
            .delete_top = 0,
            .delete_h = 0,
            .name_row_top = 0,
            .name_group_x = 0,
            .name_group_w = 0,
            .name_field_w = 0,
            .device_row_top = 0,
            .device_field_w = 0,
            .name_stacked = false,
            .device_stacked = false,
            .delete_stacked = false,
            .pw_stacked = false,
            .user_count = self.userCount(),
            .total_h = 0,
        };
        if (two) {
            l.users_w = two_col_list_w;
            l.profile_x = card_x + two_col_list_w + two_col_gap;
            l.profile_w = card_w - two_col_list_w - two_col_gap;
        } else {
            l.profile_top = l.users_top + users_h + card_gap;
        }
        // Rows that cannot show their description inline reflow to the
        // stacked layout; card heights follow so nothing overlaps at narrow
        // widths.
        const inner_w = l.profile_w - 2 * pad_x;
        var group_w = @divTrunc(inner_w * 48, 100);
        group_w = std.math.clamp(group_w, 170, 320);
        l.name_group_w = group_w;
        l.name_group_x = l.profile_x + l.profile_w - pad_x - group_w;
        l.name_field_w = group_w - save_w - 8;
        l.device_field_w = group_w - apply_w - 8;
        l.name_stacked = rowStacks(inner_w, stack_min_display);
        l.device_stacked = rowStacks(inner_w, stack_min_hostname);
        l.delete_stacked = rowStacks(inner_w, stack_min_delete);
        l.pw_stacked = (inner_w - change_pw_w - 24) < stack_min_pw;
        l.profile_h = label_band + profile_head_h + rowHeightOf(l.name_stacked);
        l.access_h = label_band + 3 * row_h + rowHeightOf(l.pw_stacked);
        l.device_h = label_band + rowHeightOf(l.device_stacked);
        l.delete_h = rowHeightOf(l.delete_stacked);
        l.access_top = l.profile_top + l.profile_h + card_gap;
        l.device_top = l.access_top + l.access_h + card_gap;
        l.delete_top = l.device_top + l.device_h + card_gap;
        const bottom = @max(l.users_top + l.users_h, l.delete_top + l.delete_h);
        l.total_h = bottom + page_bottom_pad;
        l.name_row_top = l.profile_top + label_band + profile_head_h;
        l.device_row_top = l.device_top + label_band;
        return l;
    }

    // -----------------------------------------------------------------
    // Paint primitives
    // -----------------------------------------------------------------

    fn paintAvatar(self: *Page, cr: *cairo.cairo_t, x: i32, y: i32, size: i32, u: *const User) void {
        const t = common.Theme;
        const cx = @as(f64, @floatFromInt(x)) + @as(f64, @floatFromInt(size)) / 2.0;
        const cy = @as(f64, @floatFromInt(y)) + @as(f64, @floatFromInt(size)) / 2.0;
        const r = @as(f64, @floatFromInt(size)) / 2.0;
        var drawn = false;
        if (self.avatarSurface(u)) |surf| {
            const iw = cairo.cairo_image_surface_get_width(surf);
            const ih = cairo.cairo_image_surface_get_height(surf);
            if (iw > 0 and ih > 0) {
                const scale = @max(
                    r * 2.0 / @as(f64, @floatFromInt(iw)),
                    r * 2.0 / @as(f64, @floatFromInt(ih)),
                );
                cairo.cairo_save(cr);
                cairo.cairo_arc(cr, cx, cy, r, 0, tau);
                cairo.cairo_clip(cr);
                cairo.cairo_translate(cr, cx, cy);
                cairo.cairo_scale(cr, scale, scale);
                cairo.cairo_set_source_surface(
                    cr,
                    surf,
                    -@as(f64, @floatFromInt(iw)) / 2.0,
                    -@as(f64, @floatFromInt(ih)) / 2.0,
                );
                cairo.cairo_paint(cr);
                cairo.cairo_restore(cr);
                drawn = true;
            }
        }
        if (!drawn) {
            cairo.cairo_save(cr);
            const pat = cairo.cairo_pattern_create_linear(cx, cy - r, cx, cy + r);
            cairo.cairo_pattern_add_color_stop_rgba(pat, 0.0, t.acc_r, t.acc_g, t.acc_b, 0.62);
            cairo.cairo_pattern_add_color_stop_rgba(pat, 1.0, t.acc_r, t.acc_g, t.acc_b, 0.30);
            cairo.cairo_arc(cr, cx, cy, r, 0, tau);
            cairo.cairo_set_source(cr, pat);
            cairo.cairo_fill(cr);
            cairo.cairo_pattern_destroy(pat);
            var ibuf: [8]u8 = undefined;
            const ini = initials(u.full, u.name, &ibuf);
            if (ini.len > 0) {
                const font = @as(f32, @floatFromInt(size)) * 0.42;
                paintLineCentered(
                    cr,
                    .{ .x = x, .y = y, .w = size, .h = size },
                    ini,
                    font,
                    700,
                    1,
                    1,
                    1,
                    0.92,
                );
            }
            cairo.cairo_restore(cr);
        }
        // 2px ring in the card's own background color, so a photo never
        // bleeds past the glass edge.
        cairo.cairo_save(cr);
        cairo.cairo_set_line_width(cr, 2.0);
        cairo.cairo_set_source_rgba(cr, t.bg_r, t.bg_g, t.bg_b, 0.85);
        cairo.cairo_arc(cr, cx, cy, r + 1.0, 0, tau);
        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
    }

    fn roundFill(cr: *cairo.cairo_t, r: common.Rect, rad: f64, fr: f64, fg: f64, fb: f64, fa: f64) void {
        cairo.cairo_save(cr);
        ui_paint.roundRect(
            cr,
            @floatFromInt(r.x),
            @floatFromInt(r.y),
            @floatFromInt(r.w),
            @floatFromInt(r.h),
            rad,
        );
        cairo.cairo_set_source_rgba(cr, fr, fg, fb, fa);
        cairo.cairo_fill(cr);
        cairo.cairo_restore(cr);
    }

    fn roundStroke(cr: *cairo.cairo_t, r: common.Rect, rad: f64, lw: f64, sr: f64, sg: f64, sb: f64, sa: f64) void {
        cairo.cairo_save(cr);
        ui_paint.roundRect(
            cr,
            @as(f64, @floatFromInt(r.x)) + 0.5,
            @as(f64, @floatFromInt(r.y)) + 0.5,
            @as(f64, @floatFromInt(r.w)) - 1.0,
            @as(f64, @floatFromInt(r.h)) - 1.0,
            rad,
        );
        cairo.cairo_set_line_width(cr, lw);
        cairo.cairo_set_source_rgba(cr, sr, sg, sb, sa);
        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
    }

    fn chipWidth(cr: *cairo.cairo_t, label: []const u8) i32 {
        return ui_paint.textWidthPx(cr, label, 11, 600) + 18;
    }

    /// `showText`/`showTextW` anchor that centres a run's ink in
    /// `[band_y, band_y + band_h)`. The painted glyph box is not the Pango
    /// line box (`h` is 23 at 12px Inter, the ink is ~16), so fixed
    /// baselines (`+30` in a 72px row, `+15` in a 20px chip) only lined up
    /// for one string; measuring the ink keeps every label optically
    /// centred.
    fn lineAnchor(
        cr: *cairo.cairo_t,
        band_y: i32,
        band_h: i32,
        label: []const u8,
        size: f32,
        weight: c_uint,
        max_w: f64,
    ) f64 {
        const m = ui_paint.textMetricsPx(cr, label, size, weight, max_w);
        if (m.h == 0) return @floatFromInt(band_y + band_h);
        const centre: f64 = @as(f64, @floatFromInt(band_y)) + @as(f64, @floatFromInt(band_h)) / 2.0;
        const ink_centre: f64 = @as(f64, @floatFromInt(m.ink_y)) + @as(f64, @floatFromInt(m.ink_h)) / 2.0;
        return centre - ink_centre + @as(f64, @floatFromInt(m.h)) - 2.0;
    }

    /// `showText` anchor that lands a run's ink top exactly at `ink_top`.
    fn inkTopAnchor(
        cr: *cairo.cairo_t,
        ink_top: f64,
        label: []const u8,
        size: f32,
        weight: c_uint,
        max_w: f64,
    ) f64 {
        const m = ui_paint.textMetricsPx(cr, label, size, weight, max_w);
        if (m.h == 0) return ink_top;
        return ink_top - @as(f64, @floatFromInt(m.ink_y)) + @as(f64, @floatFromInt(m.h)) - 2.0;
    }

    /// Left-aligned run, ink-centred in `[band_y, band_y + band_h)`,
    /// ellipsised against `max_w` when positive.
    fn paintLine(
        cr: *cairo.cairo_t,
        x: f64,
        band_y: i32,
        band_h: i32,
        max_w: f64,
        label: []const u8,
        size: f32,
        weight: c_uint,
        fr: f64,
        fg: f64,
        fb: f64,
        fa: f64,
    ) void {
        if (label.len == 0) return;
        const y = lineAnchor(cr, band_y, band_h, label, size, weight, max_w);
        if (max_w > 0.0) {
            ui_paint.showTextW(cr, x, y, label, size, weight, max_w, fr, fg, fb, fa);
        } else {
            ui_paint.showText(cr, x, y, label, size, weight, fr, fg, fb, fa);
        }
    }

    /// Run centred both ways inside a rect (button and chip labels).
    fn paintLineCentered(
        cr: *cairo.cairo_t,
        r: common.Rect,
        label: []const u8,
        size: f32,
        weight: c_uint,
        fr: f64,
        fg: f64,
        fb: f64,
        fa: f64,
    ) void {
        if (label.len == 0) return;
        const m = ui_paint.textMetricsPx(cr, label, size, weight, 0);
        if (m.h == 0) return;
        const cx: f64 = @as(f64, @floatFromInt(r.x)) + @as(f64, @floatFromInt(r.w)) / 2.0;
        const cy: f64 = @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h)) / 2.0;
        const ink_cx: f64 = @as(f64, @floatFromInt(m.ink_x)) + @as(f64, @floatFromInt(m.ink_w)) / 2.0;
        const ink_cy: f64 = @as(f64, @floatFromInt(m.ink_y)) + @as(f64, @floatFromInt(m.ink_h)) / 2.0;
        ui_paint.showText(
            cr,
            cx - ink_cx,
            cy - ink_cy + @as(f64, @floatFromInt(m.h)) - 2.0,
            label,
            size,
            weight,
            fr,
            fg,
            fb,
            fa,
        );
    }

    const TextLine = struct {
        text: []const u8,
        size: f32,
        weight: c_uint,
        alpha: f64,
        gap_before: i32 = 0,
    };

    /// A stack of left-aligned lines sharing one ink block, centred in
    /// `[band_y, band_y + band_h)`. `tail` reserves space below the stack
    /// (a chip row, say) so the whole unit centres; the ink bottom is
    /// returned so the caller can hang that row without re-measuring.
    fn paintLineStack(
        cr: *cairo.cairo_t,
        x: f64,
        band_y: i32,
        band_h: i32,
        max_w: f64,
        tail: i32,
        lines: []const TextLine,
    ) f64 {
        const t = common.Theme;
        var block: i32 = tail;
        var i: usize = 0;
        while (i < lines.len) : (i += 1) {
            if (i > 0) block += lines[i].gap_before;
            block += ui_paint.textMetricsPx(cr, lines[i].text, lines[i].size, lines[i].weight, max_w).ink_h;
        }
        var ink_top: f64 = @as(f64, @floatFromInt(band_y)) +
            @as(f64, @floatFromInt(band_h - block)) / 2.0;
        i = 0;
        while (i < lines.len) : (i += 1) {
            if (i > 0) ink_top += @as(f64, @floatFromInt(lines[i].gap_before));
            const m = ui_paint.textMetricsPx(cr, lines[i].text, lines[i].size, lines[i].weight, max_w);
            if (m.h > 0) {
                const y = inkTopAnchor(cr, ink_top, lines[i].text, lines[i].size, lines[i].weight, max_w);
                if (max_w > 0.0) {
                    ui_paint.showTextW(cr, x, y, lines[i].text, lines[i].size, lines[i].weight, max_w, t.text_r, t.text_g, t.text_b, lines[i].alpha);
                } else {
                    ui_paint.showText(cr, x, y, lines[i].text, lines[i].size, lines[i].weight, t.text_r, t.text_g, t.text_b, lines[i].alpha);
                }
            }
            ink_top += @as(f64, @floatFromInt(m.ink_h));
        }
        return ink_top;
    }

    fn paintChip(cr: *cairo.cairo_t, x: i32, y: i32, label: []const u8, style: ChipStyle) i32 {
        const t = common.Theme;
        const w = chipWidth(cr, label);
        const r = common.Rect{ .x = x, .y = y, .w = w, .h = 20 };
        var fr: f64 = 1;
        var fg: f64 = 1;
        var fb: f64 = 1;
        var fa: f64 = 0.72;
        switch (style) {
            .plain => {
                roundFill(cr, r, 10, 1, 1, 1, 0.07);
                roundStroke(cr, r, 10, 1, 1, 1, 1, 0.14);
            },
            .accent => {
                roundFill(cr, r, 10, t.acc_r, t.acc_g, t.acc_b, 0.16);
                roundStroke(cr, r, 10, 1, t.acc_r, t.acc_g, t.acc_b, 0.38);
                fr = t.acc_r;
                fg = t.acc_g;
                fb = t.acc_b;
                fa = 0.95;
            },
            .danger => {
                roundFill(cr, r, 10, danger_r, danger_g, danger_b, 0.14);
                roundStroke(cr, r, 10, 1, danger_r, danger_g, danger_b, 0.4);
                fr = danger_r;
                fg = danger_g;
                fb = danger_b;
                fa = 0.95;
            },
        }
        paintLineCentered(cr, r, label, 11, 600, fr, fg, fb, fa);
        return w;
    }

    fn paintSwitchEx(cr: *cairo.cairo_t, x: i32, y: i32, w: i32, h: i32, on: bool, enabled: bool) void {
        if (enabled) {
            ui_paint.paintSwitch(cr, x, y, w, h, on);
            return;
        }
        const t = common.Theme;
        const hf = @as(f64, @floatFromInt(h));
        ui_paint.glassBox(cr, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), hf, hf / 2.0, 1, 1, 1, 0.03);
        roundStroke(cr, .{ .x = x, .y = y, .w = w, .h = h }, hf / 2.0 - 0.5, 1.4, t.outline_r, t.outline_g, t.outline_b, 0.25);
        const knob = hf * 0.34;
        const kx = @as(f64, @floatFromInt(x)) + hf / 2.0;
        const ky = @as(f64, @floatFromInt(y)) + hf / 2.0;
        ui_paint.glassBox(cr, kx - knob, ky - knob, knob * 2, knob * 2, knob, 1, 1, 1, 0.3);
    }

    /// The accent primary (Add User, dialog submit): solid accent body with
    /// an ink-centred label.
    fn paintPrimaryBtn(cr: *cairo.cairo_t, r: common.Rect, label: []const u8, enabled: bool, hovered: bool) void {
        const t = common.Theme;
        const xf = @as(f64, @floatFromInt(r.x));
        const yf = @as(f64, @floatFromInt(r.y));
        const wf = @as(f64, @floatFromInt(r.w));
        const hf = @as(f64, @floatFromInt(r.h));
        if (enabled) {
            ui_paint.glassBox(cr, xf, yf, wf, hf, 10, t.acc_r, t.acc_g, t.acc_b, if (hovered) 1.0 else 0.9);
            paintLineCentered(cr, r, label, 12, 600, on_accent_r, on_accent_g, on_accent_b, 0.95);
        } else {
            ui_paint.glassBox(cr, xf, yf, wf, hf, 10, 1, 1, 1, 0.05);
            paintLineCentered(cr, r, label, 12, 600, t.text_r, t.text_g, t.text_b, 0.35);
            roundStroke(cr, r, 10, 1, t.outline_r, t.outline_g, t.outline_b, 0.25);
        }
    }

    const BtnTone = enum { neutral, danger };

    /// Every secondary button draws through here — the Delete User button
    /// is the reference the rest now match: 36px tall, 10px radius, 1px
    /// outline, a glass fill that brightens on hover and a measured,
    /// ink-centred 12/600 label. `tone` only swaps the stroke/label colour,
    /// so danger stays legible while Change Photo, Save, Apply, Change
    /// Password and the dialog's Cancel read as one button family.
    fn paintBtnTone(cr: *cairo.cairo_t, r: common.Rect, label: []const u8, enabled: bool, hovered: bool, tone: BtnTone) void {
        const t = common.Theme;
        const xf = @as(f64, @floatFromInt(r.x));
        const yf = @as(f64, @floatFromInt(r.y));
        const wf = @as(f64, @floatFromInt(r.w));
        const hf = @as(f64, @floatFromInt(r.h));
        ui_paint.glassBox(cr, xf, yf, wf, hf, 10, 1, 1, 1, if (enabled and hovered) 0.09 else 0.05);
        switch (tone) {
            .neutral => {
                paintLineCentered(cr, r, label, 12, 600, t.text_r, t.text_g, t.text_b, if (enabled) 0.92 else 0.32);
                roundStroke(cr, r, 10, 1, 1, 1, 1, if (enabled) 0.16 else 0.08);
            },
            .danger => {
                paintLineCentered(
                    cr,
                    r,
                    label,
                    12,
                    600,
                    if (enabled) danger_r else t.text_r,
                    if (enabled) danger_g else t.text_g,
                    if (enabled) danger_b else t.text_b,
                    if (enabled) 0.95 else 0.3,
                );
                roundStroke(cr, r, 10, 1, danger_r, danger_g, danger_b, if (enabled) 0.5 else 0.14);
            },
        }
    }

    fn paintDangerBtn(cr: *cairo.cairo_t, r: common.Rect, label: []const u8, enabled: bool, hovered: bool) void {
        paintBtnTone(cr, r, label, enabled, hovered, .danger);
    }

    fn paintField(cr: *cairo.cairo_t, r: common.Rect, text: []const u8, placeholder: []const u8, active: bool, masked: bool) void {
        const t = common.Theme;
        const xf = @as(f64, @floatFromInt(r.x));
        const yf = @as(f64, @floatFromInt(r.y));
        const wf = @as(f64, @floatFromInt(r.w));
        const hf = @as(f64, @floatFromInt(r.h));
        ui_paint.glassBox(cr, xf, yf, wf, hf, 10, 1, 1, 1, 0.06);
        cairo.cairo_save(cr);
        ui_paint.roundRect(cr, xf + 0.5, yf + 0.5, wf - 1.0, hf - 1.0, 9.5);
        cairo.cairo_set_line_width(cr, 1.0);
        if (active) {
            cairo.cairo_set_source_rgba(cr, t.acc_r, t.acc_g, t.acc_b, 0.75);
        } else {
            cairo.cairo_set_source_rgba(cr, t.outline_r, t.outline_g, t.outline_b, 0.5);
        }
        cairo.cairo_stroke(cr);
        cairo.cairo_restore(cr);
        var shown_buf: [max_pw + 1]u8 = undefined;
        var shown: []const u8 = text;
        if (masked and text.len > 0) {
            const n = @min(text.len, shown_buf.len);
            for (0..n) |i| shown_buf[i] = '*';
            shown = shown_buf[0..n];
        }
        const tx = xf + 12.0;
        const max_w = wf - 24.0;
        const is_placeholder = shown.len == 0;
        const m = ui_paint.textMetricsPx(cr, if (is_placeholder) placeholder else shown, 12, 400, if (is_placeholder) 0 else max_w);
        if (m.h > 0) {
            const cy = yf + hf / 2.0;
            const ink_cy = @as(f64, @floatFromInt(m.ink_y)) + @as(f64, @floatFromInt(m.ink_h)) / 2.0;
            const ty = cy - ink_cy + @as(f64, @floatFromInt(m.h)) - 2.0;
            if (is_placeholder) {
                ui_paint.showText(cr, tx, ty, placeholder, 12, 400, t.text_r, t.text_g, t.text_b, 0.35);
            } else {
                ui_paint.showTextW(cr, tx, ty, shown, 12, 400, max_w, t.text_r, t.text_g, t.text_b, 0.92);
            }
        }
        if (active and caretOn()) {
            const tw = ui_paint.textWidthPx(cr, shown, 12, 400);
            var cx = tx + @as(f64, @floatFromInt(tw)) + 1.5;
            const max_cx = xf + wf - 8.0;
            if (cx > max_cx) cx = max_cx;
            const ch = @max(10.0, @as(f64, @floatFromInt(m.ink_h)) + 4.0);
            cairo.cairo_save(cr);
            cairo.cairo_set_source_rgba(cr, t.acc_r, t.acc_g, t.acc_b, 0.9);
            cairo.cairo_rectangle(cr, cx, yf + (hf - ch) / 2.0, 1.5, ch);
            cairo.cairo_fill(cr);
            cairo.cairo_restore(cr);
        }
    }

    /// Paints a row's title/description text block centred in a band of
    /// `band_h` starting at `y` (inline rows pass `row_h`; stacked rows pass
    /// the shorter text band above their controls).
    fn paintRowText(cr: *cairo.cairo_t, x: i32, y: i32, band_h: i32, max_w: i32, title: []const u8, desc: []const u8, dim: bool) void {
        const t = common.Theme;
        const wf: f64 = @floatFromInt(max_w);
        if (desc.len == 0) {
            paintLine(cr, @floatFromInt(x), y, band_h, wf, title, 14, 500, t.text_r, t.text_g, t.text_b, if (dim) 0.4 else 0.93);
            return;
        }
        _ = paintLineStack(cr, @floatFromInt(x), y, band_h, wf, 0, &.{
            .{ .text = title, .size = 14, .weight = 500, .alpha = if (dim) 0.4 else 0.93 },
            .{ .text = desc, .size = 12, .weight = 400, .alpha = if (dim) 0.28 else 0.5, .gap_before = 6 },
        });
    }

    /// Row text with the stacking rule applied: stacked rows centre the text
    /// block in the top band and let the controls own the bottom.
    fn paintRowTextRow(cr: *cairo.cairo_t, row: common.Rect, stacked: bool, inline_w: i32, title: []const u8, desc: []const u8, dim: bool) void {
        paintRowText(
            cr,
            row.x,
            row.y + if (stacked) stack_text_dy else 0,
            if (stacked) stack_text_band else row_h,
            if (stacked) row.w else inline_w,
            title,
            desc,
            dim,
        );
    }

    fn paintDivider(cr: *cairo.cairo_t, x: i32, y: i32, w: i32) void {
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, 1, 1, 1, 0.06);
        cairo.cairo_rectangle(cr, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), 1);
        cairo.cairo_fill(cr);
        cairo.cairo_restore(cr);
    }

    fn paintToast(self: *Page, cr: *cairo.cairo_t, win_w: i32, win_h: i32) void {
        if (!self.toastVisible()) return;
        const t = common.Theme;
        const msg = self.toast_buf[0..self.toast_len];
        var max_text_w: i32 = 460;
        if (win_w < 560) max_text_w = win_w - 100;
        if (max_text_w < 120) max_text_w = 120;
        const tw = ui_paint.textWidthPx(cr, msg, 12, 500);
        var w = @min(tw + 36, max_text_w + 36);
        if (w < 180) w = 180;
        const lines = ui_paint.measureWrappedLines(msg, 12, 500, w - 36);
        const h = @max(40, lines * 18 + 22);
        const x = @divTrunc(win_w - w, 2);
        const y = win_h - 24 - h;
        if (y < 40) return;
        const rr = common.Rect{ .x = x, .y = y, .w = w, .h = h };
        if (self.toast_err) {
            ui_paint.glassBox(cr, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h), 12, danger_r, danger_g, danger_b, 0.22);
            roundStroke(cr, rr, 12, 1, danger_r, danger_g, danger_b, 0.55);
        } else {
            ui_paint.glassBox(cr, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h), 12, 1, 1, 1, 0.1);
            roundStroke(cr, rr, 12, 1, t.acc_r, t.acc_g, t.acc_b, 0.45);
        }
        ui_paint.showWrapped(cr, @floatFromInt(x + 18), @floatFromInt(y + 11), msg, 12, 500, t.text_r, t.text_g, t.text_b, 0.95, w - 36, true);
    }

    // -----------------------------------------------------------------
    // Cards
    // -----------------------------------------------------------------

    fn paintUserRow(self: *Page, cr: *cairo.cairo_t, l: Layout, idx: i32, px: f64, py: f64) void {
        const t = common.Theme;
        const u = &self.users.items[@intCast(idx)];
        const row = userRowRect(l, idx);
        const sel = std.mem.eql(u8, u.name, self.selectedName());
        if (sel) {
            roundFill(cr, row, 12, t.acc_r, t.acc_g, t.acc_b, 0.1);
            roundStroke(cr, row, 12, 1, t.acc_r, t.acc_g, t.acc_b, 0.28);
        } else if (common.pointInRect(px, py, row)) {
            roundFill(cr, row, 12, 1, 1, 1, 0.04);
        }
        self.paintAvatar(cr, row.x + 12, row.y + @divTrunc(user_row_h - user_avatar_s, 2), user_avatar_s, u);
        const tx = row.x + 12 + user_avatar_s + 12;
        var chip_labels: [3][]const u8 = undefined;
        var chip_styles: [3]ChipStyle = undefined;
        var chip_n: usize = 0;
        if (u.is_current) {
            chip_labels[chip_n] = "You";
            chip_styles[chip_n] = .plain;
            chip_n += 1;
        }
        if (u.admin) {
            chip_labels[chip_n] = "Admin";
            chip_styles[chip_n] = .accent;
            chip_n += 1;
        }
        if (u.lock_known and u.locked) {
            chip_labels[chip_n] = "Locked";
            chip_styles[chip_n] = .danger;
            chip_n += 1;
        }
        var chip_w: [3]i32 = undefined;
        var chips_w: i32 = 0;
        var ci: usize = 0;
        while (ci < chip_n) : (ci += 1) {
            chip_w[ci] = chipWidth(cr, chip_labels[ci]);
            if (ci > 0) chips_w += 6;
            chips_w += chip_w[ci];
        }
        var name_max = row.x + row.w - 12 - chips_w - tx;
        if (name_max < 40) name_max = 40;
        var handle_buf: [max_cur + 2]u8 = undefined;
        const handle = std.fmt.bufPrint(&handle_buf, "@{s}", .{u.name}) catch u.name;
        _ = paintLineStack(cr, @floatFromInt(tx), row.y, user_row_h, @floatFromInt(name_max), 0, &.{
            .{ .text = u.full, .size = 13, .weight = 600, .alpha = 0.93 },
            .{ .text = handle, .size = 11, .weight = 400, .alpha = 0.5, .gap_before = 3 },
        });
        var chip_x = row.x + row.w - 12 - chips_w;
        const chip_y = row.y + @divTrunc(user_row_h - 20, 2);
        ci = 0;
        while (ci < chip_n) : (ci += 1) {
            _ = paintChip(cr, chip_x, chip_y, chip_labels[ci], chip_styles[ci]);
            chip_x += chip_w[ci] + 6;
        }
    }

    fn paintUsersCard(self: *Page, cr: *cairo.cairo_t, l: Layout, ov: f64, px: f64, py: f64) void {
        const t = common.Theme;
        ui_paint.card(cr, @floatFromInt(l.users_x), @floatFromInt(l.users_top), @floatFromInt(l.users_w), @floatFromInt(l.users_h), ov);
        ui_paint.catLabel(cr, @floatFromInt(l.users_x + pad_x), @floatFromInt(l.users_top + 22), "USERS");
        var count_buf: [8]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buf, "{d}", .{self.users.items.len}) catch "0";
        const cw = ui_paint.textWidthPx(cr, count, 11, 500);
        ui_paint.showText(cr, @floatFromInt(l.users_x + l.users_w - pad_x - cw), @floatFromInt(l.users_top + 22), count, 11, 500, t.text_r, t.text_g, t.text_b, 0.45);
        var i: i32 = 0;
        while (i < @as(i32, @intCast(self.users.items.len))) : (i += 1) {
            self.paintUserRow(cr, l, i, px, py);
        }
        if (self.users.items.len == 0) {
            paintLine(
                cr,
                @floatFromInt(l.users_x + pad_x),
                l.users_top + users_head_band,
                user_row_h,
                0,
                "No local accounts found.",
                12,
                400,
                t.text_r,
                t.text_g,
                t.text_b,
                0.5,
            );
        }
        const add = addUserRect(l);
        paintDivider(cr, l.users_x + 12, add.y - 12, l.users_w - 24);
        paintPrimaryBtn(cr, add, "Add User", true, common.pointInRect(px, py, add));
    }

    fn paintProfileCard(self: *Page, cr: *cairo.cairo_t, l: Layout, ov: f64, px: f64, py: f64) void {
        const t = common.Theme;
        ui_paint.card(cr, @floatFromInt(l.profile_x), @floatFromInt(l.profile_top), @floatFromInt(l.profile_w), @floatFromInt(l.profile_h), ov);
        ui_paint.catLabel(cr, @floatFromInt(l.profile_x + pad_x), @floatFromInt(l.profile_top + 22), "PROFILE");
        const head_y = l.profile_top + label_band;
        const u_opt = self.selectedUser();
        const photo = photoRect(l);
        if (u_opt) |u| {
            self.paintAvatar(cr, l.profile_x + pad_x, head_y + @divTrunc(profile_head_h - avatar_s, 2), avatar_s, u);
            const tx = l.profile_x + pad_x + avatar_s + 18;
            const max_w = photo.x - tx - 12;
            var handle_buf: [max_cur + 2]u8 = undefined;
            const handle = std.fmt.bufPrint(&handle_buf, "@{s}", .{u.name}) catch u.name;
            // Name, handle and the chip row centre as one unit against the
            // avatar: the chip row is reserved as a tail while the text
            // block centres, then hung under the returned ink bottom.
            const chip_gap: i32 = 8;
            const ink_bottom = paintLineStack(
                cr,
                @floatFromInt(tx),
                head_y,
                profile_head_h,
                @floatFromInt(max_w),
                chip_gap + 20,
                &.{
                    .{ .text = u.full, .size = 20, .weight = 600, .alpha = 0.95 },
                    .{ .text = handle, .size = 13, .weight = 400, .alpha = 0.55, .gap_before = 3 },
                },
            );
            var chip_x = tx;
            const chip_y: i32 = @as(i32, @intFromFloat(ink_bottom)) + chip_gap;
            if (u.is_current) chip_x += paintChip(cr, chip_x, chip_y, "You", .plain) + 6;
            if (u.admin) chip_x += paintChip(cr, chip_x, chip_y, "Administrator", .accent) + 6;
            if (u.lock_known and u.locked) chip_x += paintChip(cr, chip_x, chip_y, "Locked", .danger) + 6;
            paintBtnTone(cr, photo, "Change Photo", true, common.pointInRect(px, py, photo), .neutral);
        } else {
            paintLine(
                cr,
                @floatFromInt(l.profile_x + pad_x),
                head_y,
                profile_head_h,
                0,
                "No user account selected.",
                13,
                400,
                t.text_r,
                t.text_g,
                t.text_b,
                0.5,
            );
            paintBtnTone(cr, photo, "Change Photo", false, false, .neutral);
        }
        paintDivider(cr, l.profile_x + pad_x, l.name_row_top, l.profile_w - 2 * pad_x);
        var row_text_w = l.name_group_x - (l.profile_x + pad_x) - 14;
        if (row_text_w < 80) row_text_w = 80;
        const name_row = rowRect(l, l.name_row_top);
        paintRowTextRow(cr, name_row, l.name_stacked, row_text_w, "Display name", "Shown on the login screen and in the shell", u_opt == null);
        const field = nameFieldRect(l);
        paintField(cr, field, self.name_buf[0..self.name_len], "Full name", self.focus == .display_name, false);
        const save = nameSaveRect(l);
        if (u_opt != null) {
            paintBtnTone(cr, save, "Save", true, common.pointInRect(px, py, save), .neutral);
        } else {
            paintBtnTone(cr, save, "Save", false, false, .neutral);
        }
    }

    fn paintAccessCard(self: *Page, cr: *cairo.cairo_t, l: Layout, ov: f64, px: f64, py: f64) void {
        const t = common.Theme;
        ui_paint.card(cr, @floatFromInt(l.profile_x), @floatFromInt(l.access_top), @floatFromInt(l.profile_w), @floatFromInt(l.access_h), ov);
        ui_paint.catLabel(cr, @floatFromInt(l.profile_x + pad_x), @floatFromInt(l.access_top + 22), "ACCESS");
        const u_opt = self.selectedUser();
        var desc_buf: [160]u8 = undefined;
        {
            const row = accessRowRect(l, 0);
            if (u_opt) |u| {
                const desc: []const u8 = if (u.admin)
                    std.fmt.bufPrint(&desc_buf, "Remove administrator rights from {s}", .{u.name}) catch "Grant or remove sudo rights"
                else
                    std.fmt.bufPrint(&desc_buf, "Grant {s} sudo rights", .{u.name}) catch "Grant or remove sudo rights";
                paintRowTextRow(cr, row, false, row.w - 60, "Administrator", desc, false);
                const sw = rowSwitchRect(l, row);
                paintSwitchEx(cr, sw.x, sw.y, sw.w, sw.h, u.admin, true);
            } else {
                paintRowTextRow(cr, row, false, row.w - 60, "Administrator", "Select a user first", true);
                const sw = rowSwitchRect(l, row);
                paintSwitchEx(cr, sw.x, sw.y, sw.w, sw.h, false, false);
            }
        }
        {
            const row = accessRowRect(l, 1);
            if (u_opt) |u| {
                const self_lock = u.is_current;
                const desc: []const u8 = if (self_lock)
                    "You can't lock the account you're signed in with."
                else
                    std.fmt.bufPrint(&desc_buf, "Prevent {s} from signing in", .{u.name}) catch "Prevent this user from signing in";
                paintRowTextRow(cr, row, false, row.w - 60, "Lock account", desc, self_lock);
                const sw = rowSwitchRect(l, row);
                paintSwitchEx(cr, sw.x, sw.y, sw.w, sw.h, u.lock_known and u.locked, !self_lock);
            } else {
                paintRowTextRow(cr, row, false, row.w - 60, "Lock account", "Select a user first", true);
                const sw = rowSwitchRect(l, row);
                paintSwitchEx(cr, sw.x, sw.y, sw.w, sw.h, false, false);
            }
        }
        {
            const row = accessRowRect(l, 2);
            const no_dm = self.dm == .none;
            if (u_opt) |u| {
                const desc: []const u8 = if (no_dm)
                    "No supported login manager (GDM/SDDM/LightDM) detected."
                else if (self.dm == .gdm)
                    "Skip the password at boot. Uses GDM."
                else if (self.dm == .sddm)
                    "Skip the password at boot. Uses SDDM."
                else
                    "Skip the password at boot. Uses LightDM.";
                const on = !no_dm and self.auto_enabled and std.mem.eql(u8, self.autoUser(), u.name);
                paintRowTextRow(cr, row, false, row.w - 60, "Log in automatically", desc, no_dm);
                const sw = rowSwitchRect(l, row);
                paintSwitchEx(cr, sw.x, sw.y, sw.w, sw.h, on, !no_dm);
            } else {
                paintRowTextRow(cr, row, false, row.w - 60, "Log in automatically", "Select a user first", true);
                const sw = rowSwitchRect(l, row);
                paintSwitchEx(cr, sw.x, sw.y, sw.w, sw.h, false, false);
            }
        }
        {
            const row = accessRowRect(l, 3);
            if (u_opt) |u| {
                const desc: []const u8 = std.fmt.bufPrint(&desc_buf, "Change the password for {s}", .{u.name}) catch "Change this user's password";
                paintRowTextRow(cr, row, l.pw_stacked, row.w - change_pw_w - 24, "Password", desc, false);
            } else {
                paintRowTextRow(cr, row, l.pw_stacked, row.w - change_pw_w - 24, "Password", "Select a user first", true);
            }
            const btn = passwordBtnRect(l);
            if (u_opt != null) {
                paintBtnTone(cr, btn, "Change Password", true, common.pointInRect(px, py, btn), .neutral);
            } else {
                paintBtnTone(cr, btn, "Change Password", false, false, .neutral);
            }
        }
        _ = t;
    }

    fn paintDeviceCard(self: *Page, cr: *cairo.cairo_t, l: Layout, ov: f64, px: f64, py: f64) void {
        ui_paint.card(cr, @floatFromInt(l.profile_x), @floatFromInt(l.device_top), @floatFromInt(l.profile_w), @floatFromInt(l.device_h), ov);
        ui_paint.catLabel(cr, @floatFromInt(l.profile_x + pad_x), @floatFromInt(l.device_top + 22), "THIS DEVICE");
        // The row starts below the category label band; anchoring it at the
        // card top ran "Hostname" straight through "THIS DEVICE".
        const row = rowRect(l, l.device_row_top);
        var text_w = l.name_group_x - (l.profile_x + pad_x) - 14;
        if (text_w < 80) text_w = 80;
        paintRowTextRow(cr, row, l.device_stacked, text_w, "Hostname", "The name this computer uses on the network", false);
        const field = deviceFieldRect(l);
        paintField(cr, field, self.host_buf[0..self.host_len], "hostname", self.focus == .hostname, false);
        const btn = deviceApplyRect(l);
        paintBtnTone(cr, btn, "Apply", true, common.pointInRect(px, py, btn), .neutral);
    }

    fn paintDeleteCard(self: *Page, cr: *cairo.cairo_t, l: Layout, ov: f64, px: f64, py: f64) void {
        const t = common.Theme;
        ui_paint.card(cr, @floatFromInt(l.profile_x), @floatFromInt(l.delete_top), @floatFromInt(l.profile_w), @floatFromInt(l.delete_h), ov);
        roundStroke(cr, .{ .x = l.profile_x, .y = l.delete_top, .w = l.profile_w, .h = l.delete_h }, 16, 1, danger_r, danger_g, danger_b, 0.22);
        const u_opt = self.selectedUser();
        const row = rowRect(l, l.delete_top);
        const enabled = u_opt != null and !u_opt.?.is_current;
        const armed = u_opt != null and std.mem.eql(u8, self.deleteArmName(), u_opt.?.name);
        var desc_buf: [160]u8 = undefined;
        if (u_opt) |u| {
            const desc: []const u8 = if (u.is_current)
                "You can't delete the account you're signed in with."
            else
                std.fmt.bufPrint(&desc_buf, "Remove {s} and their home directory. This cannot be undone.", .{u.name}) catch "Remove this user and their home directory.";
            paintRowTextRow(cr, row, l.delete_stacked, row.w - delete_w - 24, "Delete user", desc, u.is_current);
        } else {
            paintRowTextRow(cr, row, l.delete_stacked, row.w - delete_w - 24, "Delete user", "Select a user first", true);
        }
        const btn = deleteBtnRect(l);
        paintDangerBtn(cr, btn, if (armed) "Confirm Delete" else "Delete User", enabled, common.pointInRect(px, py, btn));
        _ = t;
    }

    // -----------------------------------------------------------------
    // Frame
    // -----------------------------------------------------------------

    pub fn paint(
        self: *Page,
        c: ?*cairo.cairo_t,
        g: Geo,
        px: f64,
        py: f64,
        glass_ov: f64,
    ) void {
        const cr = c orelse return;
        if (!self.inited) return;
        self.refreshDue();
        const l = self.layoutFor(g);
        self.paintUsersCard(cr, l, glass_ov, px, py);
        self.paintProfileCard(cr, l, glass_ov, px, py);
        self.paintAccessCard(cr, l, glass_ov, px, py);
        self.paintDeviceCard(cr, l, glass_ov, px, py);
        self.paintDeleteCard(cr, l, glass_ov, px, py);
        // Window-space layers: undo the content scroll translate and drop
        // the content clip before drawing the toast and the dialog veil.
        cairo.cairo_save(cr);
        cairo.cairo_translate(cr, 0, @floatFromInt(g.scroll_px));
        cairo.cairo_reset_clip(cr);
        self.paintToast(cr, g.win_w, g.win_h);
        if (self.modal != .none) self.paintModal(cr, g.win_w, g.win_h);
        cairo.cairo_restore(cr);
    }

    // -----------------------------------------------------------------
    // Modal dialogs (window space)
    // -----------------------------------------------------------------

    fn dlgLayout(self: *const Page, win_w: i32, win_h: i32) DlgLayout {
        const add = self.modal == .add_user;
        const h: i32 = if (add) add_dlg_h else pw_dlg_h;
        var w: i32 = win_w - 80;
        if (w > dlg_max_w) w = dlg_max_w;
        if (w < 340) w = 340;
        var x = @divTrunc(win_w - w, 2);
        if (x < 16) x = 16;
        var y = @divTrunc(win_h - h, 2);
        if (y < common.content_top + 12) y = common.content_top + 12;
        return .{ .x = x, .y = y, .w = w, .h = h, .add = add };
    }

    /// -1 none/outside; 0..n fields; -10 admin; -11 cancel; -12 submit.
    fn dlgItemAt(self: *const Page, win_w: i32, win_h: i32, px: f64, py: f64) i32 {
        const l = dlgLayout(self, win_w, win_h);
        const n = self.modalFields();
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            const fr = common.Rect{
                .x = l.x + dlg_pad,
                .y = dlgFieldY(l, i),
                .w = l.w - 2 * dlg_pad,
                .h = dlg_field_h,
            };
            if (common.pointInRect(px, py, fr)) return @intCast(i);
        }
        if (l.add) {
            const admin_r = common.Rect{
                .x = l.x + dlg_pad,
                .y = l.y + 320,
                .w = l.w - 2 * dlg_pad,
                .h = 36,
            };
            if (common.pointInRect(px, py, admin_r)) return -10;
        }
        const by = l.y + l.h - 56;
        const submit_w = dlgSubmitW(l.add);
        const submit_r = common.Rect{ .x = l.x + l.w - dlg_pad - submit_w, .y = by, .w = submit_w, .h = dlg_btn_h };
        if (common.pointInRect(px, py, submit_r)) return -12;
        const cancel_r = common.Rect{ .x = submit_r.x - 8 - dlg_cancel_w, .y = by, .w = dlg_cancel_w, .h = dlg_btn_h };
        if (common.pointInRect(px, py, cancel_r)) return -11;
        return -1;
    }

    fn dlgFieldText(self: *const Page, i: u8) []const u8 {
        if (self.modal == .password) {
            return if (i == 0)
                self.pw_buf[0..self.pw_len]
            else
                self.pw_confirm_buf[0..self.pw_confirm_len];
        }
        return switch (i) {
            0 => self.add_user_buf[0..self.add_user_len],
            1 => self.add_full_buf[0..self.add_full_len],
            2 => self.add_pw_buf[0..self.add_pw_len],
            else => self.add_confirm_buf[0..self.add_confirm_len],
        };
    }

    fn paintModal(self: *Page, cr: *cairo.cairo_t, win_w: i32, win_h: i32) void {
        const t = common.Theme;
        const l = dlgLayout(self, win_w, win_h);
        // Veil.
        cairo.cairo_save(cr);
        cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0.45);
        cairo.cairo_rectangle(cr, 0, 0, @floatFromInt(win_w), @floatFromInt(win_h));
        cairo.cairo_fill(cr);
        cairo.cairo_restore(cr);
        // Panel.
        ui_paint.card(cr, @floatFromInt(l.x), @floatFromInt(l.y), @floatFromInt(l.w), @floatFromInt(l.h), 0.92);
        roundStroke(cr, .{ .x = l.x, .y = l.y, .w = l.w, .h = l.h }, 16, 1, 1, 1, 1, 0.12);
        paintLine(
            cr,
            @floatFromInt(l.x + dlg_pad),
            l.y + 14,
            24,
            0,
            if (l.add) "Add User" else "Change Password",
            18,
            600,
            t.text_r,
            t.text_g,
            t.text_b,
            0.95,
        );
        var sub_buf: [96]u8 = undefined;
        const sub: []const u8 = if (l.add)
            "Create a local account on this device."
        else
            std.fmt.bufPrint(&sub_buf, "Set a new password for @{s}.", .{self.pw_target_buf[0..self.pw_target_len]}) catch "Set a new password for this user.";
        paintLine(cr, @floatFromInt(l.x + dlg_pad), l.y + 38, 20, 0, sub, 12, 400, t.text_r, t.text_g, t.text_b, 0.5);
        // Fields.
        const labels_add = [_][]const u8{ "Username", "Full name", "Password", "Confirm password" };
        const labels_pw = [_][]const u8{ "New password", "Confirm password" };
        const n = self.modalFields();
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            const fy = dlgFieldY(l, i);
            const label: []const u8 = if (l.add) labels_add[i] else labels_pw[i];
            paintLine(cr, @floatFromInt(l.x + dlg_pad), fy - 20, 16, 0, label, 12, 500, t.text_r, t.text_g, t.text_b, 0.62);
            const fr = common.Rect{ .x = l.x + dlg_pad, .y = fy, .w = l.w - 2 * dlg_pad, .h = dlg_field_h };
            const masked = !l.add or i >= 2;
            paintField(cr, fr, self.dlgFieldText(i), dlgPlaceholder(l, i), self.dlg.focus == i, masked);
        }
        // Admin opt-in (Add User only).
        if (l.add) {
            const bx = l.x + dlg_pad;
            const by = l.y + 326;
            const box = common.Rect{ .x = bx, .y = by, .w = 20, .h = 20 };
            roundFill(cr, box, 6, 1, 1, 1, 0.06);
            if (self.add_admin) {
                roundFill(cr, box, 6, t.acc_r, t.acc_g, t.acc_b, 0.9);
                cairo.cairo_save(cr);
                cairo.cairo_set_source_rgba(cr, on_accent_r, on_accent_g, on_accent_b, 0.95);
                cairo.cairo_set_line_width(cr, 2.2);
                cairo.cairo_move_to(cr, @floatFromInt(bx + 5), @floatFromInt(by + 10));
                cairo.cairo_line_to(cr, @floatFromInt(bx + 9), @floatFromInt(by + 14));
                cairo.cairo_line_to(cr, @floatFromInt(bx + 15), @floatFromInt(by + 6));
                cairo.cairo_stroke(cr);
                cairo.cairo_restore(cr);
            } else {
                roundStroke(cr, box, 6, 1.2, t.outline_r, t.outline_g, t.outline_b, 0.7);
            }
            paintLine(
                cr,
                @floatFromInt(bx + 32),
                by,
                20,
                0,
                "Make this user an administrator",
                13,
                500,
                t.text_r,
                t.text_g,
                t.text_b,
                0.85,
            );
        }
        // Inline validation error.
        if (self.dlg.err_len > 0) {
            paintLine(
                cr,
                @floatFromInt(l.x + dlg_pad),
                l.y + l.h - 82,
                20,
                @floatFromInt(l.w - 2 * dlg_pad),
                self.dlg.err_buf[0..self.dlg.err_len],
                12,
                500,
                danger_r,
                danger_g,
                danger_b,
                0.95,
            );
        }
        // Buttons.
        const by2 = l.y + l.h - 56;
        const submit_w = dlgSubmitW(l.add);
        const submit = common.Rect{ .x = l.x + l.w - dlg_pad - submit_w, .y = by2, .w = submit_w, .h = dlg_btn_h };
        const cancel = common.Rect{ .x = submit.x - 8 - dlg_cancel_w, .y = by2, .w = dlg_cancel_w, .h = dlg_btn_h };
        paintBtnTone(cr, cancel, "Cancel", true, self.dlg.hover == -11 or self.dlg.arm == -11, .neutral);
        paintPrimaryBtn(cr, submit, if (l.add) "Create User" else "Change Password", true, self.dlg.hover == -12 or self.dlg.arm == -12);
    }

    // -----------------------------------------------------------------
    // Window-space modal hooks
    // -----------------------------------------------------------------

    pub fn modalActive(self: *const Page) bool {
        return self.modal != .none;
    }

    pub fn modalDown(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) bool {
        if (self.modal == .none) return false;
        const l = dlgLayout(self, win_w, win_h);
        const inside = px >= @as(f64, @floatFromInt(l.x)) and
            px <= @as(f64, @floatFromInt(l.x + l.w)) and
            py >= @as(f64, @floatFromInt(l.y)) and
            py <= @as(f64, @floatFromInt(l.y + l.h));
        if (!inside) {
            self.modal = .none;
            return true;
        }
        self.dlg.arm = self.dlgItemAt(win_w, win_h, px, py);
        if (self.dlg.arm >= 0) self.dlg.focus = @intCast(self.dlg.arm);
        return true;
    }

    pub fn modalUp(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) bool {
        if (self.modal == .none) return false;
        const armed = self.dlg.arm;
        self.dlg.arm = -1;
        const item = self.dlgItemAt(win_w, win_h, px, py);
        if (item != armed) return true;
        switch (item) {
            -10 => self.add_admin = !self.add_admin,
            -11 => self.modal = .none,
            -12 => {
                if (self.modal == .password) {
                    self.submitPassword();
                } else {
                    self.submitAddUser();
                }
            },
            else => {},
        }
        return true;
    }

    pub fn modalMotion(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64) void {
        if (self.modal == .none) return;
        var h = self.dlgItemAt(win_w, win_h, px, py);
        if (h < 0) h = -1;
        self.dlg.hover = h;
    }

    pub fn modalAxis(self: *Page, win_w: i32, win_h: i32, px: f64, py: f64, delta: f64) bool {
        _ = delta;
        if (self.modal == .none) return false;
        const l = dlgLayout(self, win_w, win_h);
        return px >= @as(f64, @floatFromInt(l.x)) and
            px <= @as(f64, @floatFromInt(l.x + l.w)) and
            py >= @as(f64, @floatFromInt(l.y)) and
            py <= @as(f64, @floatFromInt(l.y + l.h));
    }

    // -----------------------------------------------------------------
    // Pointer
    // -----------------------------------------------------------------

    /// `(px, ly)` are content-space: the window adds the scroll offset
    /// before calling, so the layout rects line up directly.
    pub fn hit(self: *Page, g: Geo, px: f64, ly: f64) ?Action {
        if (!self.inited) return null;
        self.refreshDue();
        if (self.modal != .none) return null;
        const l = self.layoutFor(g);

        var i: i32 = 0;
        while (i < @as(i32, @intCast(self.users.items.len))) : (i += 1) {
            if (common.pointInRect(px, ly, userRowRect(l, i))) {
                self.selectUser(self.users.items[@intCast(i)].name);
                return .redraw;
            }
        }
        if (common.pointInRect(px, ly, addUserRect(l))) {
            self.openAddDialog();
            return .redraw;
        }
        if (common.pointInRect(px, ly, photoRect(l))) {
            return if (self.actChooseAvatar()) .persist else .redraw;
        }
        if (common.pointInRect(px, ly, nameSaveRect(l))) {
            self.focus = .none;
            self.actSaveFullName();
            return .redraw;
        }
        if (common.pointInRect(px, ly, nameFieldRect(l))) {
            if (self.focus != .display_name) {
                self.seedName();
                self.focus = .display_name;
            }
            return .redraw;
        }
        if (common.pointInRect(px, ly, rowSwitchRect(l, accessRowRect(l, 0)))) {
            self.actToggleAdmin();
            return .redraw;
        }
        if (common.pointInRect(px, ly, rowSwitchRect(l, accessRowRect(l, 1)))) {
            self.actToggleLock();
            return .redraw;
        }
        if (common.pointInRect(px, ly, rowSwitchRect(l, accessRowRect(l, 2)))) {
            self.actToggleAutologin();
            return .redraw;
        }
        if (common.pointInRect(px, ly, passwordBtnRect(l))) {
            self.openPasswordDialog();
            return .redraw;
        }
        if (common.pointInRect(px, ly, deviceFieldRect(l))) {
            if (self.focus != .hostname) {
                self.seedHost();
                self.focus = .hostname;
            }
            return .redraw;
        }
        if (common.pointInRect(px, ly, deviceApplyRect(l))) {
            self.focus = .none;
            self.actApplyHostname();
            return .redraw;
        }
        if (common.pointInRect(px, ly, deleteBtnRect(l))) {
            self.actDeleteUser();
            return .redraw;
        }
        // Anywhere else ends inline editing and restores the saved values.
        if (self.focus != .none) {
            self.focus = .none;
            self.seedName();
            self.seedHost();
            return .redraw;
        }
        return .redraw;
    }
};

// ---------------------------------------------------------------------------
// Layout and rect helpers
// ---------------------------------------------------------------------------

const DlgLayout = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    add: bool,
};

fn dlgFieldY(l: DlgLayout, i: u8) i32 {
    const base: i32 = if (l.add) 82 else 84;
    return l.y + base + @as(i32, i) * dlg_block_h;
}

fn dlgPlaceholder(l: DlgLayout, i: u8) []const u8 {
    if (l.add) {
        return switch (i) {
            0 => "e.g. alice",
            1 => "Alice Liddell",
            2 => "At least 4 characters",
            else => "Repeat password",
        };
    }
    return if (i == 0) "At least 4 characters" else "Repeat password";
}

const ChipStyle = enum { plain, accent, danger };

const Layout = struct {
    g: Geo,
    card_x: i32,
    card_w: i32,
    two_col: bool,
    users_x: i32,
    users_w: i32,
    users_top: i32,
    users_h: i32,
    profile_x: i32,
    profile_w: i32,
    profile_top: i32,
    profile_h: i32,
    access_top: i32,
    access_h: i32,
    device_top: i32,
    device_h: i32,
    delete_top: i32,
    delete_h: i32,
    name_row_top: i32,
    name_group_x: i32,
    name_group_w: i32,
    name_field_w: i32,
    device_row_top: i32,
    device_field_w: i32,
    name_stacked: bool,
    device_stacked: bool,
    delete_stacked: bool,
    pw_stacked: bool,
    user_count: i32,
    total_h: i32,
};

/// Row height for a row that may be stacked (text above, controls below).
fn rowHeightOf(stacked: bool) i32 {
    return if (stacked) stacked_row_h else row_h;
}

fn userRowRect(l: Layout, idx: i32) common.Rect {
    return .{
        .x = l.users_x + 8,
        .y = l.users_top + users_head_band + idx * user_row_h,
        .w = l.users_w - 16,
        .h = user_row_h,
    };
}

fn addUserRect(l: Layout) common.Rect {
    return .{
        .x = l.users_x + 12,
        .y = l.users_top + users_head_band + l.user_count * user_row_h + 12,
        .w = l.users_w - 24,
        .h = btn_h,
    };
}

fn photoRect(l: Layout) common.Rect {
    return .{
        .x = l.profile_x + l.profile_w - pad_x - photo_w,
        .y = l.profile_top + label_band + @divTrunc(profile_head_h - btn_h, 2),
        .w = photo_w,
        .h = btn_h,
    };
}

fn nameFieldRect(l: Layout) common.Rect {
    if (l.name_stacked) {
        const row = rowRect(l, l.name_row_top);
        return .{
            .x = row.x,
            .y = row.y + stack_ctrl_dy + @divTrunc(btn_h - field_h, 2),
            .w = row.w - 8 - save_w,
            .h = field_h,
        };
    }
    return .{
        .x = l.name_group_x,
        .y = l.name_row_top + @divTrunc(row_h - field_h, 2),
        .w = l.name_field_w,
        .h = field_h,
    };
}

fn nameSaveRect(l: Layout) common.Rect {
    if (l.name_stacked) {
        const row = rowRect(l, l.name_row_top);
        return .{
            .x = row.x + row.w - save_w,
            .y = row.y + stack_ctrl_dy,
            .w = save_w,
            .h = btn_h,
        };
    }
    return .{
        .x = l.name_group_x + l.name_field_w + 8,
        .y = l.name_row_top + @divTrunc(row_h - btn_h, 2),
        .w = save_w,
        .h = btn_h,
    };
}

fn accessRowRect(l: Layout, idx: i32) common.Rect {
    return .{
        .x = l.profile_x + pad_x,
        .y = l.access_top + label_band + idx * row_h,
        .w = l.profile_w - 2 * pad_x,
        .h = row_h,
    };
}

fn rowSwitchRect(l: Layout, row: common.Rect) common.Rect {
    _ = l;
    return .{
        .x = row.x + row.w - switch_w,
        .y = row.y + @divTrunc(row_h - switch_h, 2),
        .w = switch_w,
        .h = switch_h,
    };
}

fn rowRightBtnRect(row: common.Rect, w: i32, h: i32) common.Rect {
    return .{
        .x = row.x + row.w - w,
        .y = row.y + @divTrunc(row_h - h, 2),
        .w = w,
        .h = h,
    };
}

fn passwordBtnRect(l: Layout) common.Rect {
    const row = accessRowRect(l, 3);
    if (l.pw_stacked) {
        return .{
            .x = row.x + row.w - change_pw_w,
            .y = row.y + stack_ctrl_dy,
            .w = change_pw_w,
            .h = btn_h,
        };
    }
    return rowRightBtnRect(row, change_pw_w, btn_h);
}

fn deviceFieldRect(l: Layout) common.Rect {
    if (l.device_stacked) {
        const row = rowRect(l, l.device_row_top);
        return .{
            .x = row.x,
            .y = row.y + stack_ctrl_dy + @divTrunc(btn_h - field_h, 2),
            .w = row.w - 8 - apply_w,
            .h = field_h,
        };
    }
    return .{
        .x = l.name_group_x,
        .y = l.device_row_top + @divTrunc(row_h - field_h, 2),
        .w = l.device_field_w,
        .h = field_h,
    };
}

fn deviceApplyRect(l: Layout) common.Rect {
    if (l.device_stacked) {
        const row = rowRect(l, l.device_row_top);
        return .{
            .x = row.x + row.w - apply_w,
            .y = row.y + stack_ctrl_dy,
            .w = apply_w,
            .h = btn_h,
        };
    }
    const f = deviceFieldRect(l);
    return .{
        .x = f.x + f.w + 8,
        .y = l.device_row_top + @divTrunc(row_h - btn_h, 2),
        .w = apply_w,
        .h = btn_h,
    };
}

fn deleteBtnRect(l: Layout) common.Rect {
    return .{
        .x = l.profile_x + l.profile_w - pad_x - delete_w,
        .y = l.delete_top + if (l.delete_stacked) stack_ctrl_dy else @divTrunc(row_h - btn_h, 2),
        .w = delete_w,
        .h = btn_h,
    };
}

fn rowRect(l: Layout, top: i32) common.Rect {
    return .{
        .x = l.profile_x + pad_x,
        .y = top,
        .w = l.profile_w - 2 * pad_x,
        .h = row_h,
    };
}

fn lessThanName(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn appendText(buf: []u8, len: *usize, text: []const u8) void {
    if (len.* >= buf.len) return;
    const n = @min(text.len, buf.len - len.*);
    @memcpy(buf[len.* .. len.* + n], text[0..n]);
    len.* += n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "accounts: fullFromGecos" {
    try std.testing.expectEqualStrings("Alice Liddell", fullFromGecos("Alice Liddell,,,", "alice"));
    try std.testing.expectEqualStrings("alice", fullFromGecos("", "alice"));
    try std.testing.expectEqualStrings("alice", fullFromGecos(",,,", "alice"));
}

test "accounts: validFullName" {
    try std.testing.expect(validFullName("Alice Liddell"));
    try std.testing.expect(!validFullName(""));
    try std.testing.expect(!validFullName("bad:name"));
    try std.testing.expect(!validFullName("bad\nname"));
}

test "accounts: parseLockStatus" {
    try std.testing.expectEqual(@as(?bool, true), parseLockStatus("alice L 01/01/2026\n", "alice"));
    try std.testing.expectEqual(@as(?bool, false), parseLockStatus("alice P 05/05/2026 0 99999 7 -1\n", "alice"));
    try std.testing.expectEqual(@as(?bool, false), parseLockStatus("alice NP 05/05/2026\n", "alice"));
    try std.testing.expectEqual(@as(?bool, null), parseLockStatus("bob L 01/01/2026\n", "alice"));
    try std.testing.expectEqual(@as(?bool, null), parseLockStatus("", "alice"));
}

test "accounts: findGroup and membership" {
    const text = "# groups\nwheel:x:10:alice,bob\nsudo:x:27:carol\n";
    const g = findGroup(text, "wheel").?;
    try std.testing.expectEqual(@as(u32, 10), g.gid);
    try std.testing.expect(groupHasMember(g.members, "bob"));
    try std.testing.expect(!groupHasMember(g.members, "dave"));
    try std.testing.expectEqual(@as(u32, 27), findGroup(text, "sudo").?.gid);
    try std.testing.expect(findGroup(text, "nope") == null);
}

test "accounts: iniGet reads the last key in the section" {
    const text = "[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=alice\n";
    try std.testing.expectEqualStrings("True", iniGet(text, "daemon", "AutomaticLoginEnable").?);
    try std.testing.expectEqualStrings("alice", iniGet(text, "daemon", "AutomaticLogin").?);
    try std.testing.expect(iniGet(text, "seat", "x") == null);
}

test "accounts: iniSet replaces, appends and erases" {
    const alloc = std.testing.allocator;
    const replaced = try iniSet(alloc, "[daemon]\nAutomaticLogin=alice\n", "daemon", "AutomaticLogin", "bob", false);
    defer alloc.free(replaced);
    try std.testing.expectEqualStrings("[daemon]\nAutomaticLogin=bob\n", replaced);

    const added = try iniSet(alloc, "key=1\n", "seat", "name", "v", false);
    defer alloc.free(added);
    try std.testing.expectEqualStrings("key=1\n\n[seat]\nname=v\n", added);

    const erased = try iniSet(alloc, "[daemon]\nAutomaticLogin=alice\nOther=1\n", "daemon", "AutomaticLogin", "", true);
    defer alloc.free(erased);
    try std.testing.expectEqualStrings("[daemon]\nOther=1\n", erased);

    const fresh = try iniSet(alloc, "", "s", "k", "v", false);
    defer alloc.free(fresh);
    try std.testing.expectEqualStrings("[s]\nk=v\n", fresh);
}

test "accounts: initials" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("AL", initials("Alice Liddell", "alice", &buf));
    try std.testing.expectEqualStrings("A", initials("Alice", "alice", &buf));
    try std.testing.expectEqualStrings("A", initials("", "alice", &buf));
}

