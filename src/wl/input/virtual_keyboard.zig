//! `zwp_virtual_keyboard_v1` — synthetic key events, the transport under
//! ClipStack's auto-paste (`Enter` in the picker → selection set → Ctrl+V
//! injected into whatever window regains focus).
//!
//! The protocol needs an XKB keymap uploaded before the first key event.
//! This module builds one with the same xkbcommon the seat uses — the
//! session's own default layout, so a shortcut written as "Ctrl+V" resolves
//! through the exact keymap the physical keyboard uses. When xkbcommon
//! cannot produce a keymap (no XKB data, no environment names) the embedded
//! `fallback_keymap` takes over: a self-contained layout covering the keys
//! auto-paste and basic typing need. `buildKeymap` therefore never fails
//! for environmental reasons.
//!
//! Key codes on the wire are evdev kernel codes, as the protocol specifies;
//! the compositor translates them to XKB keycodes (+8) exactly like
//! `Seat.kbKey` does for real hardware, so the local `xkb_state` below
//! mirrors the compositor's view one-to-one.
//!
//! After every key the local xkb state is serialized into a `modifiers`
//! request — wlroots and Hyprland only forward modifier state to the
//! focused client when it arrives explicitly, so without this step a
//! synthetic Ctrl+V reaches the app as a bare "v". (`wtype` does the same.)

const std = @import("std");
const linux = std.os.linux;
const wl = @import("../c.zig").wl;
const xkb = @import("../seat.zig").xkb;

const libc = @import("c_stdlib");

/// `zwp_virtual_keyboard_v1.keymap` format enum: XKB_V1.
pub const keymap_format_xkb_v1: u32 = 1;

// evdev key codes (`linux/input-event-codes.h`).
pub const key_esc: u32 = 1;
pub const key_enter: u32 = 28;
pub const key_leftctrl: u32 = 29;
pub const key_leftshift: u32 = 42;
pub const key_v: u32 = 47;

/// Self-contained US keymap used only when xkbcommon cannot build the
/// session default. Keycodes are XKB keycodes (evdev + 8): `V` is evdev 47
/// → keycode 55 → `<AB04>`. The unit test below compiles this text with
/// xkbcommon and checks that Ctrl+V resolves, so it cannot rot silently.
pub const fallback_keymap =
    \\xkb_keymap {
    \\    xkb_keycodes "cs-min" {
    \\        minimum = 8;
    \\        maximum = 255;
    \\        <ESC> = 9;
    \\        <RTRN> = 36;
    \\        <LCTL> = 37;
    \\        <LFSH> = 50;
    \\        <AB01> = 52;
    \\        <AB02> = 53;
    \\        <AB03> = 54;
    \\        <AB04> = 55;
    \\    };
    \\    xkb_types "cs-min" {
    \\        type "ONE_LEVEL" {
    \\            level_name[Level1] = "Any";
    \\        };
    \\        type "TWO_LEVEL" {
    \\            modifiers = Shift;
    \\            map[Shift] = Level2;
    \\            level_name[Level1] = "Base";
    \\            level_name[Level2] = "Shift";
    \\        };
    \\    };
    \\    xkb_compat "cs-min" {
    \\        interpret Control_L { action = SetMods(modifiers=Control); };
    \\        interpret Shift_L { action = SetMods(modifiers=Shift); };
    \\    };
    \\    xkb_symbols "cs-min" {
    \\        key <ESC> { [ Escape ] };
    \\        key <RTRN> { [ Return ] };
    \\        key <LCTL> { [ Control_L ] };
    \\        key <LFSH> { [ Shift_L ] };
    \\        modifier_map Control { <LCTL> };
    \\        modifier_map Shift { <LFSH> };
    \\        key <AB01> { type[group1] = "TWO_LEVEL", [ z, Z ] };
    \\        key <AB02> { type[group1] = "TWO_LEVEL", [ x, X ] };
    \\        key <AB03> { type[group1] = "TWO_LEVEL", [ c, C ] };
    \\        key <AB04> { type[group1] = "TWO_LEVEL", [ v, V ] };
    \\    };
    \\};
;

pub const KeyDir = enum { press, release };

/// The session default keymap as XKB text, or a copy of `fallback_keymap`
/// when xkbcommon cannot build one. Caller frees.
pub fn buildKeymap(alloc: std.mem.Allocator) ?[]u8 {
    if (xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS)) |ctx| {
        defer xkb.xkb_context_unref(ctx);
        const km = xkb.xkb_keymap_new_from_names(ctx, null, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS);
        if (km != null) {
            defer xkb.xkb_keymap_unref(km);
            const str = xkb.xkb_keymap_get_as_string(km, xkb.XKB_KEYMAP_FORMAT_TEXT_V1);
            if (str != null) {
                defer libc.free(@ptrCast(str));
                const bytes = std.mem.span(str);
                if (bytes.len > 0) return alloc.dupe(u8, bytes) catch null;
            }
        }
    }
    return alloc.dupe(u8, fallback_keymap) catch null;
}

fn writeAll(fd: i32, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS) return false;
        if (rc == 0) return false;
        off += rc;
    }
    return true;
}

fn sendKeymap(vk: *wl.zwp_virtual_keyboard_v1, map: []const u8) bool {
    var tag: [16:0]u8 = @as([16:0]u8, @splat(0));
    @memcpy(tag[0..9], "vk-keymap");
    const rc = linux.memfd_create(&tag, linux.MFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    if (!writeAll(fd, map)) return false;
    _ = linux.lseek(fd, 0, linux.SEEK.SET);
    wl.zwp_virtual_keyboard_v1_keymap(vk, keymap_format_xkb_v1, fd, @intCast(map.len));
    return true;
}

pub const Keyboard = struct {
    alloc: std.mem.Allocator,
    vk: ?*wl.zwp_virtual_keyboard_v1 = null,
    keymap: ?*xkb.xkb_keymap = null,
    state: ?*xkb.xkb_state = null,

    /// Create a virtual keyboard on `seat` and upload a keymap. A Keyboard
    /// with `.vk == null` means the compositor does not offer the protocol
    /// (or the keymap could not be produced) — callers degrade gracefully.
    pub fn create(
        alloc: std.mem.Allocator,
        manager: ?*wl.zwp_virtual_keyboard_manager_v1,
        seat: ?*wl.wl_seat,
    ) Keyboard {
        var self = Keyboard{ .alloc = alloc };
        const mgr = manager orelse return self;
        const s = seat orelse return self;

        const map = buildKeymap(alloc) orelse return self;
        defer alloc.free(map);
        const map_z = alloc.dupeSentinel(u8, map, 0) catch return self;
        defer alloc.free(map_z);

        const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse return self;
        defer xkb.xkb_context_unref(ctx);
        const km = xkb.xkb_keymap_new_from_string(ctx, map_z.ptr, xkb.XKB_KEYMAP_FORMAT_TEXT_V1, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return self;
        const state = xkb.xkb_state_new(km) orelse {
            xkb.xkb_keymap_unref(km);
            return self;
        };

        const vk = wl.zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(mgr, s) orelse {
            xkb.xkb_state_unref(state);
            xkb.xkb_keymap_unref(km);
            return self;
        };
        if (!sendKeymap(vk, map)) {
            wl.zwp_virtual_keyboard_v1_destroy(vk);
            xkb.xkb_state_unref(state);
            xkb.xkb_keymap_unref(km);
            return self;
        }
        self.vk = vk;
        self.keymap = km;
        self.state = state;
        return self;
    }

    pub fn ready(self: *const Keyboard) bool {
        return self.vk != null;
    }

    /// One key event. Serializes the local modifier state into a
    /// `modifiers` request so the focused client sees held modifiers.
    pub fn key(self: *Keyboard, code: u32, dir: KeyDir) void {
        const vk = self.vk orelse return;
        const state = self.state orelse return;
        _ = xkb.xkb_state_update_key(state, code + 8, if (dir == .press) xkb.XKB_KEY_DOWN else xkb.XKB_KEY_UP);
        const depressed = xkb.xkb_state_serialize_mods(state, xkb.XKB_STATE_MODS_DEPRESSED);
        const latched = xkb.xkb_state_serialize_mods(state, xkb.XKB_STATE_MODS_LATCHED);
        const locked = xkb.xkb_state_serialize_mods(state, xkb.XKB_STATE_MODS_LOCKED);
        const group = xkb.xkb_state_serialize_layout(state, xkb.XKB_STATE_LAYOUT_EFFECTIVE);
        wl.zwp_virtual_keyboard_v1_modifiers(vk, depressed, latched, locked, group);
        wl.zwp_virtual_keyboard_v1_key(vk, 0, code, if (dir == .press) 1 else 0);
    }

    /// Ctrl+V, the paste chord. Modifier masks are serialized from the
    /// local keymap, so a layout that puts Control elsewhere still works.
    pub fn pressCtrlV(self: *Keyboard) void {
        self.key(key_leftctrl, .press);
        self.key(key_v, .press);
        self.key(key_v, .release);
        self.key(key_leftctrl, .release);
    }

    pub fn destroy(self: *Keyboard) void {
        if (self.vk) |vk| wl.zwp_virtual_keyboard_v1_destroy(vk);
        if (self.state) |st| xkb.xkb_state_unref(st);
        if (self.keymap) |km| xkb.xkb_keymap_unref(km);
        self.vk = null;
        self.state = null;
        self.keymap = null;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "clipstack vk: buildKeymap always yields a keymap (system or fallback)" {
    const map = buildKeymap(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(map);
    try testing.expect(map.len > 0);
    try testing.expect(std.mem.indexOf(u8, map, "xkb_keymap") != null);

    const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS).?;
    defer xkb.xkb_context_unref(ctx);
    const map_z = try testing.allocator.dupeSentinel(u8, map, 0);
    defer testing.allocator.free(map_z);
    const km = xkb.xkb_keymap_new_from_string(ctx, map_z.ptr, xkb.XKB_KEYMAP_FORMAT_TEXT_V1, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (km != null) xkb.xkb_keymap_unref(km);
    try testing.expect(km != null);
}

test "clipstack vk: fallback keymap compiles and resolves Ctrl+V" {
    const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS).?;
    defer xkb.xkb_context_unref(ctx);
    const km = xkb.xkb_keymap_new_from_string(
        ctx,
        fallback_keymap.ptr,
        xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
        xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.BadFallbackKeymap;
    defer xkb.xkb_keymap_unref(km);
    const state = xkb.xkb_state_new(km).?;
    defer xkb.xkb_state_unref(state);

    // evdev 47 == V; the compositor and this module both address it as
    // xkb keycode 55.
    const code = key_v + 8;
    const sym_v = xkb.xkb_state_key_get_one_sym(state, code);
    try testing.expectEqual(@as(u32, xkb.XKB_KEY_v), sym_v);

    _ = xkb.xkb_state_update_key(state, key_leftctrl + 8, xkb.XKB_KEY_DOWN);
    try testing.expectEqual(@as(c_int, 1), xkb.xkb_state_mod_name_is_active(state, xkb.XKB_MOD_NAME_CTRL, xkb.XKB_STATE_MODS_EFFECTIVE));
    // Still "v" while Ctrl is held — no implicit glyph change.
    try testing.expectEqual(@as(u32, xkb.XKB_KEY_v), xkb.xkb_state_key_get_one_sym(state, code));
    // And with Shift, the second level answers.
    _ = xkb.xkb_state_update_key(state, key_leftshift + 8, xkb.XKB_KEY_DOWN);
    try testing.expectEqual(@as(u32, xkb.XKB_KEY_V), xkb.xkb_state_key_get_one_sym(state, code));
}

test "clipstack vk: no manager and no seat degrade to a null keyboard" {
    var kb = Keyboard.create(testing.allocator, null, null);
    defer kb.destroy();
    try testing.expect(!kb.ready());
    kb.pressCtrlV(); // must not crash
}

test "clipstack vk: live keymap upload (EH_CLIPSTACK_VK_LIVE=1)" {
    const env = libc.getenv("EH_CLIPSTACK_VK_LIVE");
    if (env == null) return error.SkipZigTest;

    const conn_mod = @import("../connection.zig");
    const gpa = testing.allocator;
    var conn = conn_mod.Connection.init(gpa);
    defer conn.deinit();
    if (!conn.connect(null)) return error.SkipZigTest;
    var bound = conn_mod.Connection.Bound{};
    defer conn.freeBound(&bound);
    conn.bindAll(&bound);
    if (bound.virtual_keyboard_manager == null or bound.seat == null) return error.SkipZigTest;

    var kb = Keyboard.create(gpa, bound.virtual_keyboard_manager, bound.seat);
    defer kb.destroy();
    try testing.expect(kb.ready());
    // No keys are sent here: the test proves the keymap upload is accepted
    // by the live compositor without typing into whatever has focus.
    try testing.expect(conn.roundtrip());
}
