//! Notification model: active set plus history.
//!
//! Owns the active set and the history: add-or-replace by `replaces_id`,
//! implicit duplicate suppression (same app+summary+body within 1 s),
//! same-app merge for chatty senders without a `replaces_id`, per-id expiry
//! with pause/resume, action invocation, a 100-entry history with an index,
//! do-not-disturb, and the server default timeout.
//!
//! Everything is single-threaded (no worker-thread dispatch),
//! dispatches on worker threads. The Zig daemon dispatches D-Bus on its
//! single loop thread, so this manager is intentionally lock-free: call it
//! from one thread only. (If a second thread ever touches it, wrap the
//! calls in the `SpinMu` from `controlcenter/live_bluetooth.zig`.)
//!
//! Strings and pixels are owned copies; `freeNotification` releases them.
//! `all()` / `history()` return borrowed slices valid until the next
//! mutation. Event callbacks fire synchronously — do not mutate the manager
//! from inside one.

const std = @import("std");
const base = @import("notifications.zig");

pub const Urgency = base.Urgency;
pub const kDefaultTimeoutMs: i32 = 6000;
pub const kMaxActive: usize = 50;
pub const kMaxHistory: usize = 100;
pub const kDuplicateWindowMs: i64 = 1000;

pub const Origin = enum(u8) { external = 0, internal = 1 };

pub const CloseReason = enum(u32) { expired = 1, dismissed = 2, closed_by_call = 3 };

pub const Event = enum { added, updated, closed };

/// Raw image bytes from the `image-data` hint. Owned copy when stored.
pub const ImageData = struct {
    width: i32 = 0,
    height: i32 = 0,
    row_stride: i32 = 0,
    has_alpha: bool = true,
    bits_per_sample: i32 = 8,
    channels: i32 = 4,
    pixels: []const u8 = &.{},
};

pub const Notification = struct {
    id: u32 = 0,
    origin: Origin = .external,
    app_name: []const u8 = "",
    summary: []const u8 = "",
    body: []const u8 = "",
    timeout_ms: i32 = 0,
    urgency: Urgency = .normal,
    /// Flat key/text pairs, exactly as the spec sends them.
    actions: [][]const u8 = &.{},
    icon: ?[]const u8 = null,
    image: ?ImageData = null,
    category: ?[]const u8 = null,
    desktop_entry: ?[]const u8 = null,
    received_ms: i64 = 0,
    expiry_ms: ?i64 = null,
    silent: bool = false,
    transient: bool = false,
};

pub const HistoryEntry = struct {
    notification: Notification,
    active: bool = true,
    close_reason: ?CloseReason = null,
    event_serial: u64 = 0,
};

pub const AddArgs = struct {
    app_name: []const u8,
    summary: []const u8,
    body: []const u8,
    urgency: Urgency = .normal,
    timeout_ms: i32 = kDefaultTimeoutMs,
    origin: Origin = .external,
    actions: []const []const u8 = &.{},
    icon: ?[]const u8 = null,
    image: ?ImageData = null,
    category: ?[]const u8 = null,
    desktop_entry: ?[]const u8 = null,
    silent: bool = false,
    transient: bool = false,
};

pub const EventCallback = *const fn (ctx: ?*anyopaque, n: *const Notification, ev: Event) void;
pub const ActionCallback = *const fn (ctx: ?*anyopaque, id: u32, action_key: []const u8) void;
pub const StateHandler = *const fn (ctx: ?*anyopaque) void;

fn realNowMs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const s: i64 = @intCast(@max(ts.sec, 0));
    const n: i64 = @intCast(@max(ts.nsec, 0));
    return s * 1000 + @divTrunc(n, 1_000_000);
}

pub const Manager = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayList(Notification) = .empty,
    id_to_index: std.AutoHashMap(u32, usize),
    hist: std.ArrayList(HistoryEntry) = .empty,
    history_index: std.AutoHashMap(u32, usize),
    callbacks: std.ArrayList(CallbackEntry) = .empty,
    action_cb: ?ActionCallback = null,
    action_ctx: ?*anyopaque = null,
    state_cb: ?StateHandler = null,
    state_ctx: ?*anyopaque = null,
    next_callback_token: i32 = 0,
    next_id: u32 = 1,
    change_serial: u64 = 0,
    do_not_disturb: bool = false,
    server_default_timeout_ms: i32 = kDefaultTimeoutMs,
    /// Override for tests; null means the monotonic clock.
    now_fn: *const fn () i64 = realNowMs,

    pub const CallbackEntry = struct {
        token: i32,
        cb: EventCallback,
        ctx: ?*anyopaque,
    };

    pub fn init(alloc: std.mem.Allocator) Manager {
        return .{
            .alloc = alloc,
            .id_to_index = std.AutoHashMap(u32, usize).init(alloc),
            .history_index = std.AutoHashMap(u32, usize).init(alloc),
        };
    }

    pub fn deinit(self: *Manager) void {
        for (self.items.items) |*n| freeNotification(self.alloc, n);
        self.items.deinit(self.alloc);
        self.id_to_index.deinit();
        for (self.hist.items) |*e| freeNotification(self.alloc, &e.notification);
        self.hist.deinit(self.alloc);
        self.history_index.deinit();
        self.callbacks.deinit(self.alloc);
    }

    fn now(self: *Manager) i64 {
        return self.now_fn();
    }

    fn emitLive(self: *Manager, id: u32, ev: Event) void {
        // Index loop over the live list, resolving the card per callback:
        // a callback that adds another notification may reallocate `items`,
        // so no live pointer is held across calls. (Mutating the manager
        // from a callback is still not supported; if the id vanishes
        // mid-emit there is nothing left to report.)
        var i: usize = 0;
        while (i < self.callbacks.items.len) : (i += 1) {
            const e = self.callbacks.items[i];
            const idx = self.id_to_index.get(id) orelse return;
            e.cb(e.ctx, &self.items.items[idx], ev);
        }
    }

    /// The closed card is already unlinked, so the event carries a copy the
    /// callee owns. Free with `freeClosed`.
    fn emitClosed(self: *Manager, n: *const Notification) void {
        var i: usize = 0;
        while (i < self.callbacks.items.len) : (i += 1) {
            const e = self.callbacks.items[i];
            e.cb(e.ctx, n, .closed);
        }
    }

    pub fn addEventCallback(self: *Manager, cb: EventCallback, ctx: ?*anyopaque) i32 {
        const token = self.next_callback_token;
        self.next_callback_token += 1;
        self.callbacks.append(self.alloc, .{ .token = token, .cb = cb, .ctx = ctx }) catch return -1;
        return token;
    }

    pub fn removeEventCallback(self: *Manager, token: i32) void {
        var i: usize = 0;
        while (i < self.callbacks.items.len) {
            if (self.callbacks.items[i].token == token) {
                _ = self.callbacks.orderedRemove(i);
            } else i += 1;
        }
    }

    pub fn setActionHandler(self: *Manager, cb: ?ActionCallback, ctx: ?*anyopaque) void {
        self.action_cb = cb;
        self.action_ctx = ctx;
    }

    pub fn setStateHandler(self: *Manager, cb: StateHandler, ctx: ?*anyopaque) void {
        self.state_cb = cb;
        self.state_ctx = ctx;
    }

    fn scheduleExpiry(now_ms: i64, timeout_ms: i32) ?i64 {
        if (timeout_ms > 0) return now_ms + timeout_ms;
        return null;
    }

    /// Add-or-update by `replaces_id`: duplicate suppression,
    /// same-app merge, then fresh insert. Returns the live id.
    pub fn addOrUpdate(self: *Manager, replaces_id: u32, args: AddArgs) u32 {
        const now_ms = self.now();

        if (replaces_id != 0) {
            if (self.id_to_index.get(replaces_id)) |idx| {
                const n = &self.items.items[idx];
                const changed = !std.mem.eql(u8, n.app_name, args.app_name) or
                    !std.mem.eql(u8, n.summary, args.summary) or
                    !std.mem.eql(u8, n.body, args.body) or
                    n.timeout_ms != args.timeout_ms or
                    n.urgency != args.urgency or
                    n.origin != args.origin or
                    !actionsEql(n.actions, args.actions) or
                    !optEql(n.icon, args.icon) or
                    !imageEql(n.image, args.image) or
                    !optEql(n.category, args.category) or
                    !optEql(n.desktop_entry, args.desktop_entry);
                replaceFields(self.alloc, n, args) catch return n.id;
                // Identical re-pushes (a track re-emitted by a second mpris
                // host) are true no-ops: restarting the clock would make the
                // toast's progress bar visibly jump backwards.
                if (changed) {
                    n.received_ms = now_ms;
                    n.expiry_ms = scheduleExpiry(now_ms, n.timeout_ms);
                }
                self.recordHistory(n.*, true, null);
                if (changed) self.emitLive(n.id, .updated);
                return n.id;
            }
        }

        // Implicit duplicate window, newest first.
        var ri: usize = self.items.items.len;
        while (ri > 0) {
            ri -= 1;
            const e = &self.items.items[ri];
            if (std.mem.eql(u8, e.app_name, args.app_name) and
                std.mem.eql(u8, e.summary, args.summary) and
                std.mem.eql(u8, e.body, args.body) and
                now_ms - e.received_ms < kDuplicateWindowMs)
            {
                return e.id;
            }
        }

        // Same-app merge for senders without a replaces_id (chat apps).
        // Case-insensitive app-name match, desktop-entry match as fallback.
        ri = self.items.items.len;
        while (ri > 0) {
            ri -= 1;
            const e = &self.items.items[ri];
            if (appNameEql(e.app_name, args.app_name) or entryEql(e.desktop_entry, args.desktop_entry)) {
                replaceFields(self.alloc, e, args) catch return e.id;
                e.received_ms = now_ms;
                e.expiry_ms = scheduleExpiry(now_ms, e.timeout_ms);
                self.recordHistory(e.*, true, null);
                self.emitLive(e.id, .updated);
                return e.id;
            }
        }

        const id = self.next_id;
        self.next_id += 1;
        var n = Notification{ .id = id };
        replaceFields(self.alloc, &n, args) catch return 0;
        n.received_ms = now_ms;
        n.expiry_ms = scheduleExpiry(now_ms, n.timeout_ms);
        self.items.append(self.alloc, n) catch {
            freeNotification(self.alloc, &n);
            return 0;
        };
        self.id_to_index.put(id, self.items.items.len - 1) catch {};

        // Cap active notifications at 50.
        while (self.items.items.len > kMaxActive) {
            const old_id = self.items.items[0].id;
            var old = self.items.orderedRemove(0);
            freeNotification(self.alloc, &old);
            _ = self.id_to_index.remove(old_id);
            self.reindexFrom(0);
        }

        const live_id = self.items.items[self.items.items.len - 1].id;
        self.recordHistory(self.items.items[self.items.items.len - 1], true, null);
        self.emitLive(live_id, .added);
        return live_id;
    }

    /// Shell-internal posts: no actions, silent/transient at false.
    pub fn addInternal(
        self: *Manager,
        app_name: []const u8,
        summary: []const u8,
        body: []const u8,
        urgency: Urgency,
        timeout_ms: i32,
    ) u32 {
        return self.addOrUpdate(0, .{
            .app_name = app_name,
            .summary = summary,
            .body = body,
            .urgency = urgency,
            .timeout_ms = timeout_ms,
            .origin = .internal,
        });
    }

    /// Runs the action callback, then closes as dismissed. False when the id
    /// is unknown or the key is not one of the notification's action keys.
    pub fn triggerAction(self: *Manager, id: u32, action_key: []const u8, close_after_invoke: bool) bool {
        const idx = self.id_to_index.get(id) orelse return false;
        if (action_key.len == 0) return false;
        const n = &self.items.items[idx];
        var found = false;
        var i: usize = 0;
        while (i + 1 < n.actions.len) : (i += 2) {
            if (std.mem.eql(u8, n.actions[i], action_key)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
        if (self.action_cb) |cb| cb(self.action_ctx, id, action_key);
        if (close_after_invoke) _ = self.close(id, .dismissed);
        return true;
    }

    pub fn close(self: *Manager, id: u32, reason: CloseReason) bool {
        const idx = self.id_to_index.get(id) orelse return false;
        // History keeps its own copies (minus image bytes); the live one is
        // freed here.
        const live = &self.items.items[idx];
        self.recordHistory(live.*, false, reason);
        var closed_copy = dupeNotification(self.alloc, live.*) catch return false;
        var gone = self.items.orderedRemove(idx);
        freeNotification(self.alloc, &gone);
        _ = self.id_to_index.remove(id);
        self.reindexFrom(idx);
        // The entry is already unlinked, so a callback that re-adds the
        // same id cannot collide with it.
        self.emitClosed(&closed_copy);
        freeNotification(self.alloc, &closed_copy);
        return true;
    }

    fn reindexFrom(self: *Manager, start: usize) void {
        var i: usize = start;
        while (i < self.items.items.len) : (i += 1) {
            self.id_to_index.put(self.items.items[i].id, i) catch {};
        }
    }

    pub fn expiredList(self: *Manager, alloc: std.mem.Allocator) []u32 {
        var out: std.ArrayList(u32) = .empty;
        const now_ms = self.now();
        for (self.items.items) |*n| {
            if (n.expiry_ms) |exp| {
                if (now_ms >= exp) out.append(alloc, n.id) catch {
                    out.deinit(alloc);
                    return &.{};
                };
            }
        }
        return out.toOwnedSlice(alloc) catch &.{};
    }

    /// Milliseconds until the next expiry, or -1 when nothing can expire.
    pub fn nextExpiryDelayMs(self: *Manager) i64 {
        var best: i64 = -1;
        const now_ms = self.now();
        for (self.items.items) |*n| {
            if (n.expiry_ms) |exp| {
                const ms: i64 = @max(0, exp - now_ms);
                if (best < 0 or ms < best) best = ms;
            }
        }
        return best;
    }

    pub fn sweepExpired(self: *Manager) void {
        const alloc = self.alloc;
        const ids = self.expiredList(alloc);
        defer alloc.free(ids);
        for (ids) |id| _ = self.close(id, .expired);
    }

    pub fn freezeExpiry(self: *Manager, id: u32) void {
        const idx = self.id_to_index.get(id) orelse return;
        self.items.items[idx].expiry_ms = null;
    }

    pub fn thawExpiry(self: *Manager, id: u32, remaining_ms: i32) void {
        const idx = self.id_to_index.get(id) orelse return;
        if (remaining_ms <= 0) {
            self.items.items[idx].expiry_ms = self.now();
            return;
        }
        self.items.items[idx].expiry_ms = self.now() + remaining_ms;
    }

    pub fn all(self: *Manager) []const Notification {
        return self.items.items;
    }

    pub fn history(self: *Manager) []const HistoryEntry {
        return self.hist.items;
    }

    pub fn changeSerial(self: *Manager) u64 {
        return self.change_serial;
    }

    pub fn dropHistoryEntry(self: *Manager, id: u32) void {
        const idx = self.history_index.get(id) orelse return;
        var gone = self.hist.orderedRemove(idx);
        freeNotification(self.alloc, &gone.notification);
        _ = self.history_index.remove(id);
        self.change_serial += 1;
        self.reindexHistoryFrom(idx);
    }

    pub fn wipeHistory(self: *Manager) void {
        if (self.hist.items.len == 0) return;
        for (self.hist.items) |*e| freeNotification(self.alloc, &e.notification);
        self.hist.clearRetainingCapacity();
        self.history_index.clearRetainingCapacity();
        self.change_serial += 1;
    }

    fn reindexHistoryFrom(self: *Manager, start: usize) void {
        var i: usize = start;
        while (i < self.hist.items.len) : (i += 1) {
            self.history_index.put(self.hist.items[i].notification.id, i) catch {};
        }
    }

    fn recordHistory(self: *Manager, n: Notification, active: bool, reason: ?CloseReason) void {
        if (self.history_index.get(n.id)) |idx| {
            var gone = self.hist.orderedRemove(idx);
            freeNotification(self.alloc, &gone.notification);
            _ = self.history_index.remove(n.id);
            self.reindexHistoryFrom(idx);
        }
        var entry = HistoryEntry{
            .notification = dupeNotification(self.alloc, n) catch return,
            .active = active,
            .close_reason = reason,
            .event_serial = self.change_serial + 1,
        };
        // History never keeps pixels; the live card owns the only copy.
        if (entry.notification.image) |*img| {
            if (img.pixels.len > 0) self.alloc.free(img.pixels);
            entry.notification.image = null;
        }
        self.change_serial += 1;
        self.hist.append(self.alloc, entry) catch {
            freeNotification(self.alloc, &entry.notification);
            return;
        };
        while (self.hist.items.len > kMaxHistory) {
            var old = self.hist.orderedRemove(0);
            _ = self.history_index.remove(old.notification.id);
            freeNotification(self.alloc, &old.notification);
            self.reindexHistoryFrom(0);
        }
        self.reindexHistory();
    }

    fn reindexHistory(self: *Manager) void {
        self.history_index.clearRetainingCapacity();
        for (self.hist.items, 0..) |*e, i| {
            self.history_index.put(e.notification.id, i) catch {};
        }
    }

    pub fn setQuietMode(self: *Manager, enabled: bool) void {
        if (self.do_not_disturb == enabled) return;
        self.do_not_disturb = enabled;
        if (self.state_cb) |cb| cb(self.state_ctx);
    }

    pub fn flipQuietMode(self: *Manager) bool {
        self.setQuietMode(!self.do_not_disturb);
        return self.do_not_disturb;
    }

    pub fn setServerDefaultTimeoutMs(self: *Manager, ms: i32) void {
        var v = if (ms < 1000) kDefaultTimeoutMs else ms;
        v = @min(@max(v, 1000), 600000);
        self.server_default_timeout_ms = v;
    }
};

fn freeNotification(alloc: std.mem.Allocator, n: *Notification) void {
    alloc.free(n.app_name);
    alloc.free(n.summary);
    alloc.free(n.body);
    for (n.actions) |a| alloc.free(a);
    if (n.actions.len > 0) alloc.free(n.actions);
    if (n.icon) |s| alloc.free(s);
    if (n.image) |img| {
        if (img.pixels.len > 0) alloc.free(img.pixels);
    }
    if (n.category) |s| alloc.free(s);
    if (n.desktop_entry) |s| alloc.free(s);
    n.* = .{};
}

fn dupeNotification(alloc: std.mem.Allocator, n: Notification) !Notification {
    var out = Notification{
        .id = n.id,
        .origin = n.origin,
        .app_name = try alloc.dupe(u8, n.app_name),
        .summary = try alloc.dupe(u8, n.summary),
        .body = try alloc.dupe(u8, n.body),
        .timeout_ms = n.timeout_ms,
        .urgency = n.urgency,
        .received_ms = n.received_ms,
        .expiry_ms = n.expiry_ms,
        .silent = n.silent,
        .transient = n.transient,
    };
    errdefer freeNotification(alloc, &out);
    if (n.actions.len > 0) {
        const acts = try alloc.alloc([]const u8, n.actions.len);
        errdefer alloc.free(acts);
        for (n.actions, 0..) |a, i| {
            acts[i] = try alloc.dupe(u8, a);
        }
        out.actions = acts;
    }
    if (n.icon) |s| out.icon = try alloc.dupe(u8, s);
    if (n.image) |img| {
        var c = img;
        if (img.pixels.len > 0) c.pixels = try alloc.dupe(u8, img.pixels);
        out.image = c;
    }
    if (n.category) |s| out.category = try alloc.dupe(u8, s);
    if (n.desktop_entry) |s| out.desktop_entry = try alloc.dupe(u8, s);
    return out;
}

/// Overwrite every owned field of `n` with copies of `args`, freeing the old
/// ones — the add/replace/merge paths all funnel here.
fn replaceFields(alloc: std.mem.Allocator, n: *Notification, args: AddArgs) !void {
    const app_name = try alloc.dupe(u8, args.app_name);
    errdefer alloc.free(app_name);
    const summary = try alloc.dupe(u8, args.summary);
    errdefer alloc.free(summary);
    const body = try alloc.dupe(u8, args.body);
    errdefer alloc.free(body);
    var actions: [][]const u8 = &.{};
    if (args.actions.len > 0) {
        actions = try alloc.alloc([]const u8, args.actions.len);
        errdefer alloc.free(actions);
        for (args.actions, 0..) |a, i| actions[i] = try alloc.dupe(u8, a);
    }
    const icon: ?[]const u8 = if (args.icon) |s| try alloc.dupe(u8, s) else null;
    var image: ?ImageData = null;
    if (args.image) |img| {
        var c = img;
        if (img.pixels.len > 0) c.pixels = try alloc.dupe(u8, img.pixels);
        image = c;
    }
    const category: ?[]const u8 = if (args.category) |s| try alloc.dupe(u8, s) else null;
    const desktop_entry: ?[]const u8 = if (args.desktop_entry) |s| try alloc.dupe(u8, s) else null;

    // All fallible work done: drop the old fields, install the new ones.
    // (On OOM above, `n` is untouched and the caller keeps the old card.)
    freeNotificationFieldsOnly(alloc, n);
    n.app_name = app_name;
    n.summary = summary;
    n.body = body;
    n.actions = actions;
    n.icon = icon;
    n.image = image;
    n.category = category;
    n.desktop_entry = desktop_entry;
    n.timeout_ms = args.timeout_ms;
    n.urgency = args.urgency;
    n.origin = args.origin;
    n.silent = args.silent;
    n.transient = args.transient;
}

fn freeNotificationFieldsOnly(alloc: std.mem.Allocator, n: *Notification) void {
    alloc.free(n.app_name);
    alloc.free(n.summary);
    alloc.free(n.body);
    for (n.actions) |a| alloc.free(a);
    if (n.actions.len > 0) alloc.free(n.actions);
    if (n.icon) |s| alloc.free(s);
    if (n.image) |img| {
        if (img.pixels.len > 0) alloc.free(img.pixels);
    }
    if (n.category) |s| alloc.free(s);
    if (n.desktop_entry) |s| alloc.free(s);
    n.app_name = "";
    n.summary = "";
    n.body = "";
    n.actions = &.{};
    n.icon = null;
    n.image = null;
    n.category = null;
    n.desktop_entry = null;
}

fn actionsEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn imageEql(a: ?ImageData, b: ?ImageData) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const x = a.?;
    const y = b.?;
    return x.width == y.width and x.height == y.height and
        x.row_stride == y.row_stride and x.has_alpha == y.has_alpha and
        x.bits_per_sample == y.bits_per_sample and x.channels == y.channels and
        std.mem.eql(u8, x.pixels, y.pixels);
}

fn appNameEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn entryEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return false;
    if (a.?.len == 0 or b.?.len == 0) return false;
    return std.mem.eql(u8, a.?, b.?);
}

// Tests — each pins a documented manager behavior.

var test_now: i64 = 1_000_000;

fn testClock() i64 {
    return test_now;
}

fn testManager(t: anytype) Manager {
    var m = Manager.init(t.allocator);
    m.now_fn = testClock;
    return m;
}

const Rec = struct {
    ev: Event,
    id: u32,
};

var recs: [16]Rec = undefined;
var nrecs: usize = 0;

fn recCb(_: ?*anyopaque, n: *const Notification, ev: Event) void {
    if (nrecs < recs.len) {
        recs[nrecs] = .{ .ev = ev, .id = n.id };
        nrecs += 1;
    }
}

var acted_id: u32 = 0;
var acted_key: []const u8 = "";

fn actCb(_: ?*anyopaque, id: u32, key: []const u8) void {
    acted_id = id;
    acted_key = key;
}

var state_calls: usize = 0;

fn stateCb(_: ?*anyopaque) void {
    state_calls += 1;
}

test "notify-manager: add fires Added with id 1" {
    const t = std.testing;
    var m = testManager(t);
    defer m.deinit();
    nrecs = 0;
    _ = m.addEventCallback(recCb, null);
    const id = m.addOrUpdate(0, .{ .app_name = "app", .summary = "t", .body = "b" });
    try t.expectEqual(@as(u32, 1), id);
    try t.expectEqual(@as(usize, 1), m.all().len);
    try t.expectEqual(@as(usize, 1), nrecs);
    try t.expectEqual(Event.added, recs[0].ev);
    try t.expectEqual(@as(u32, 1), recs[0].id);
    // History carries the same entries as the live set, without pixels.
    try t.expectEqual(@as(usize, 1), m.history().len);
    try t.expect(m.history()[0].active);
    try t.expect(m.history()[0].close_reason == null);
}

test "notify-manager: replaces_id updates in place, identical re-push is a no-op" {
    const t = std.testing;
    test_now = 1_000_000;
    var m = testManager(t);
    defer m.deinit();
    nrecs = 0;
    _ = m.addEventCallback(recCb, null);
    const id = m.addOrUpdate(0, .{ .app_name = "a", .summary = "s", .body = "b", .timeout_ms = 5000 });
    const exp0 = m.all()[0].expiry_ms.?;
    test_now += 2000;
    // Changed body: same id, Updated, clock restarts.
    const id2 = m.addOrUpdate(id, .{ .app_name = "a", .summary = "s", .body = "b2", .timeout_ms = 5000 });
    try t.expectEqual(id, id2);
    try t.expectEqual(@as(usize, 1), m.all().len);
    try t.expect(m.all()[0].expiry_ms.? > exp0);
    try t.expectEqual(Event.updated, recs[nrecs - 1].ev);
    const exp1 = m.all()[0].expiry_ms.?;
    test_now += 500;
    // Identical re-push: no event, clock untouched (no progress-bar jump).
    _ = m.addOrUpdate(id, .{ .app_name = "a", .summary = "s", .body = "b2", .timeout_ms = 5000 });
    try t.expectEqual(exp1, m.all()[0].expiry_ms.?);
    try t.expectEqual(Event.updated, recs[nrecs - 1].ev); // last event still the real update
    try t.expectEqual(@as(usize, 2), nrecs); // added + updated only
}

test "notify-manager: duplicate within 1s is suppressed, afterwards it stacks" {
    const t = std.testing;
    test_now = 5_000_000;
    var m = testManager(t);
    defer m.deinit();
    const a: AddArgs = .{ .app_name = "app", .summary = "s", .body = "b" };
    const id1 = m.addOrUpdate(0, a);
    test_now += 500;
    const id2 = m.addOrUpdate(0, a);
    try t.expectEqual(id1, id2);
    try t.expectEqual(@as(usize, 1), m.all().len);
    test_now += 600; // 1100ms after the original: outside the window...
    // ...so it falls through to the same-app merge, which updates the live
    // card in place instead of stacking.
    const id3 = m.addOrUpdate(0, a);
    try t.expectEqual(id1, id3);
    try t.expectEqual(@as(usize, 1), m.all().len);
}

test "notify-manager: same-app merge is case-insensitive, desktop-entry matches too" {
    const t = std.testing;
    test_now = 9_000_000;
    var m = testManager(t);
    defer m.deinit();
    nrecs = 0;
    _ = m.addEventCallback(recCb, null);
    const id1 = m.addOrUpdate(0, .{ .app_name = "Discord", .summary = "one", .body = "first" });
    test_now += 5000; // well past the duplicate window: merge must still hit
    const id2 = m.addOrUpdate(0, .{ .app_name = "discord", .summary = "two", .body = "second" });
    try t.expectEqual(id1, id2);
    try t.expectEqualStrings("two", m.all()[0].summary);
    try t.expectEqual(Event.updated, recs[nrecs - 1].ev);
    // Desktop-entry fallback: different app name, same entry.
    const id3 = m.addOrUpdate(0, .{
        .app_name = "Something Else",
        .summary = "three",
        .body = "third",
        .desktop_entry = "org.example.App",
    });
    test_now += 5000;
    const id4 = m.addOrUpdate(0, .{
        .app_name = "Discord",
        .summary = "four",
        .body = "fourth",
        .desktop_entry = "org.example.App",
    });
    // Newest-first scan hits the "Something Else" card via the entry match.
    try t.expectEqual(id3, id4);
    try t.expectEqual(@as(usize, 2), m.all().len);
}

test "notify-manager: expiry, pause and resume" {
    const t = std.testing;
    test_now = 20_000_000;
    var m = testManager(t);
    defer m.deinit();
    nrecs = 0;
    _ = m.addEventCallback(recCb, null);
    const id = m.addOrUpdate(0, .{ .app_name = "a", .summary = "s", .body = "b", .timeout_ms = 1000 });
    try t.expectEqual(@as(i64, 1000), m.nextExpiryDelayMs());
    test_now += 999;
    try t.expectEqual(@as(usize, 0), m.expiredList(t.allocator).len);
    // Pause freezes the countdown entirely.
    m.freezeExpiry(id);
    try t.expectEqual(@as(i64, -1), m.nextExpiryDelayMs());
    test_now += 10_000;
    m.sweepExpired();
    try t.expectEqual(@as(usize, 1), m.all().len);
    // Resume with 500ms left.
    m.thawExpiry(id, 500);
    try t.expectEqual(@as(i64, 500), m.nextExpiryDelayMs());
    test_now += 500;
    m.sweepExpired();
    try t.expectEqual(@as(usize, 0), m.all().len);
    try t.expectEqual(Event.closed, recs[nrecs - 1].ev);
    // Closed cards land in history as inactive with a reason.
    try t.expect(!m.history()[0].active);
    try t.expectEqual(CloseReason.expired, m.history()[0].close_reason.?);
    // timeout 0 never expires.
    _ = m.addOrUpdate(0, .{ .app_name = "z", .summary = "s", .body = "b", .timeout_ms = 0 });
    try t.expectEqual(@as(i64, -1), m.nextExpiryDelayMs());
}

test "notify-manager: actions invoke the callback and dismiss" {
    const t = std.testing;
    test_now = 30_000_000;
    var m = testManager(t);
    defer m.deinit();
    acted_id = 0;
    m.setActionHandler(actCb, null);
    const keys = [_][]const u8{ "open", "Open", "mute", "Mute" };
    const id = m.addOrUpdate(0, .{ .app_name = "a", .summary = "s", .body = "b", .actions = &keys });
    try t.expect(!m.triggerAction(id, "nope", true));
    try t.expectEqual(@as(u32, 0), acted_id);
    try t.expect(m.triggerAction(id, "mute", true));
    try t.expectEqual(id, acted_id);
    try t.expectEqualStrings("mute", acted_key);
    try t.expectEqual(@as(usize, 0), m.all().len); // closed after invoke
    try t.expectEqual(CloseReason.dismissed, m.history()[0].close_reason.?);
}

test "notify-manager: history cap, serial, remove and clear" {
    const t = std.testing;
    test_now = 40_000_000;
    var m = testManager(t);
    defer m.deinit();
    const s0 = m.changeSerial();
    // Distinct apps dodge the same-app merge so each insert is fresh.
    var i: u32 = 0;
    while (i < 105) : (i += 1) {
        var buf: [16]u8 = undefined;
        const app = std.fmt.bufPrint(&buf, "app{d}", .{i}) catch unreachable;
        _ = m.addOrUpdate(0, .{ .app_name = app, .summary = "s", .body = "b" });
        test_now += 2000;
    }
    try t.expectEqual(kMaxHistory, m.history().len);
    try t.expect(m.changeSerial() > s0);
    const some_id = m.history()[0].notification.id;
    const s1 = m.changeSerial();
    m.dropHistoryEntry(some_id);
    try t.expectEqual(kMaxHistory - 1, m.history().len);
    try t.expect(m.changeSerial() > s1);
    m.dropHistoryEntry(0xdeadbeef); // unknown: silent no-op
    m.wipeHistory();
    try t.expectEqual(@as(usize, 0), m.history().len);
    m.wipeHistory(); // empty clear is a no-op (no serial bump)
}

test "notify-manager: DND and server default timeout" {
    const t = std.testing;
    var m = testManager(t);
    defer m.deinit();
    state_calls = 0;
    m.setStateHandler(stateCb, null);
    try t.expect(!m.do_not_disturb);
    try t.expect(m.flipQuietMode());
    try t.expectEqual(@as(usize, 1), state_calls);
    m.setQuietMode(true); // already set: no callback
    try t.expectEqual(@as(usize, 1), state_calls);
    try t.expect(!m.flipQuietMode());
    m.setServerDefaultTimeoutMs(500); // below floor: back to default
    try t.expectEqual(@as(i32, kDefaultTimeoutMs), m.server_default_timeout_ms);
    m.setServerDefaultTimeoutMs(999_999); // above ceiling: clamped
    try t.expectEqual(@as(i32, 600000), m.server_default_timeout_ms);
    m.setServerDefaultTimeoutMs(10_000);
    try t.expectEqual(@as(i32, 10_000), m.server_default_timeout_ms);
}

test "notify-manager: active cap at 50 drops the oldest" {
    const t = std.testing;
    test_now = 60_000_000;
    var m = testManager(t);
    defer m.deinit();
    var i: u32 = 0;
    while (i < 55) : (i += 1) {
        var buf: [16]u8 = undefined;
        const app = std.fmt.bufPrint(&buf, "cap{d}", .{i}) catch unreachable;
        _ = m.addOrUpdate(0, .{ .app_name = app, .summary = "s", .body = "b" });
        test_now += 2000;
    }
    try t.expectEqual(kMaxActive, m.all().len);
}
