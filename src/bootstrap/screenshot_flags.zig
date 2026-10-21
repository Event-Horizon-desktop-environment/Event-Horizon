//! `--eh-screenshot` flag parsing: the C++ flag table as data, plus the two
//! geometry forms the mode accepts.
//!
//! Three deliberate differences from `src/bootstrap/entry/screenshot_mode.cpp`:
//!
//!   * `clipboard` defaults to true, matching the usage text. The C++ flag
//!     defaulted to false, so `--eh-screenshot out.png` silently skipped the
//!     clipboard handoff its own help promised (audit F-8). An explicit
//!     `--clipboard` is still tracked, because "the user asked" and "the
//!     default kicked in" are different answers to different questions.
//!   * `--around-mouse` consumes its `WxH` argument here. The old parser read
//!     the flag and left the value behind in argv, where it was then taken
//!     for the output filename.
//!   * `--slurp` counts as a mode for the exclusivity and usage rules. The C++
//!     checks forgot it, so `--slurp --select` slipped past both.

const std = @import("std");

/// A `WxH+X+Y` region in global logical coordinates.
pub const Geometry = struct {
    w: i32 = 0,
    h: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
};

pub const Flags = struct {
    cursor: bool = false,
    select: bool = false,
    around_mouse: bool = false,
    slurp: bool = false,
    clipboard: bool = true,
    /// Set when `--clipboard` was written out, so the mode can tell an
    /// explicit request from the default.
    clipboard_set: bool = false,
    preview: bool = false,
    list_windows: bool = false,
    window: ?[]const u8 = null,
    geometry: ?[]const u8 = null,
    output: ?[]const u8 = null,
    file: ?[]const u8 = null,
    /// `--all-monitors`: every output stitched into one panoramic frame.
    /// No C++ counterpart existed; the C++ `-o` ladder each honored was for
    /// single outputs only.
    all_monitors: bool = false,
    /// Parsed `--around-mouse WxH`; zero until a value arrives.
    around_w: i32 = 0,
    around_h: i32 = 0,

    /// True when the invocation said nothing at all: no file, and no mode
    /// that can run without one. Then the usage text is the right answer.
    pub fn wantsUsage(self: *const Flags) bool {
        if (self.file != null) return false;
        return !self.list_windows and !self.preview and !self.clipboard_set and !self.select and
            !self.around_mouse and !self.slurp and !self.all_monitors and self.geometry == null and self.window == null;
    }

    /// At most one area/window mode per run — the rule the C++ enforced
    /// across five separate `if`s.
    pub fn exclusiveProblem(self: *const Flags) ?[]const u8 {
        var modes: u32 = 0;
        if (self.window != null) modes += 1;
        if (self.select) modes += 1;
        if (self.slurp) modes += 1;
        if (self.around_mouse) modes += 1;
        if (self.geometry != null) modes += 1;
        if (self.all_monitors) modes += 1;
        if (modes > 1) return "use only one of --select, --toplevel/--window, --slurp, --around-mouse, --geometry, or --all-monitors";
        return null;
    }
};

pub const Result = struct {
    flags: Flags = .{},
    /// Why parsing stopped, or null on success.
    problem: ?[]const u8 = null,
};

/// Parse a screenshot argv. `args[0]` is the program name and is dropped;
/// `--eh-screenshot` is skipped wherever it appears, so a direct invocation
/// and a re-spawned one parse identically.
pub fn parse(args: []const []const u8) Result {
    var r = Result{};
    var f = Flags{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--eh-screenshot")) continue;
        if (std.mem.eql(u8, a, "--cursor")) {
            f.cursor = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--select")) {
            f.select = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--slurp")) {
            f.slurp = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--clipboard")) {
            f.clipboard = true;
            f.clipboard_set = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-clipboard")) {
            f.clipboard = false;
            f.clipboard_set = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--preview")) {
            f.preview = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--list-windows")) {
            f.list_windows = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--all-monitors")) {
            f.all_monitors = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--around-mouse")) {
            f.around_mouse = true;
            i += 1;
            const raw = if (i < args.len) args[i] else {
                r.problem = "--around-mouse needs a WxH value (e.g. 400x300)";
                return r;
            };
            const size = parseSize(raw) orelse {
                r.problem = "--around-mouse value must be WxH, e.g. 400x300";
                return r;
            };
            f.around_w = size[0];
            f.around_h = size[1];
            continue;
        }
        if (std.mem.eql(u8, a, "--toplevel") or std.mem.eql(u8, a, "--window")) {
            i += 1;
            if (i >= args.len) {
                r.problem = "missing value for --toplevel/--window";
                return r;
            }
            f.window = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--geometry") or std.mem.eql(u8, a, "-g")) {
            i += 1;
            if (i >= args.len) {
                r.problem = "missing value for --geometry";
                return r;
            }
            f.geometry = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--output") or std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= args.len) {
                r.problem = "missing value for --output";
                return r;
            }
            f.output = args[i];
            continue;
        }
        if (a.len > 0 and a[0] == '-') {
            r.problem = "unknown option";
            return r;
        }
        if (f.file == null) {
            f.file = a;
        } else {
            r.problem = "more than one output file given";
            return r;
        }
    }
    r.flags = f;
    return r;
}

/// A cursor over the string being scanned.
const Scanner = struct {
    s: []const u8,
    pos: usize = 0,

    fn take(self: *Scanner, c: u8) bool {
        if (self.pos < self.s.len and self.s[self.pos] == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    /// A decimal integer, optionally negative. `+` is a field separator in
    /// these geometry strings rather than a sign, so it is never consumed
    /// here — which is what makes `300x200+1920+-40` (what `Rect.format`
    /// writes for a negative origin) parse back correctly.
    fn number(self: *Scanner) ?i64 {
        const start = self.pos;
        _ = self.take('-');
        const digits = self.pos;
        while (self.pos < self.s.len and std.ascii.isDigit(self.s[self.pos])) self.pos += 1;
        if (self.pos == digits) {
            self.pos = start;
            return null;
        }
        return std.fmt.parseInt(i64, self.s[start..self.pos], 10) catch null;
    }
};

/// `WxH+X+Y` in global logical coordinates, whitespace-trimmed. Sizes below
/// 1x1 are rejected the way the C++ parser rejected them.
pub fn parseGeometry(raw: []const u8) ?Geometry {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    var sc = Scanner{ .s = s };
    const w = sc.number() orelse return null;
    if (!sc.take('x')) return null;
    const h = sc.number() orelse return null;
    if (!sc.take('+')) return null;
    const x = sc.number() orelse return null;
    if (!sc.take('+')) return null;
    const y = sc.number() orelse return null;
    if (sc.pos != s.len) return null;
    if (w < 1 or h < 1) return null;
    return .{ .w = @intCast(w), .h = @intCast(h), .x = @intCast(x), .y = @intCast(y) };
}

/// `WxH` with no origin — the `--around-mouse` form.
pub fn parseSize(raw: []const u8) ?[2]i32 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    var sc = Scanner{ .s = s };
    const w = sc.number() orelse return null;
    if (!sc.take('x')) return null;
    const h = sc.number() orelse return null;
    if (sc.pos != s.len) return null;
    if (w < 1 or h < 1) return null;
    return .{ @intCast(w), @intCast(h) };
}

test "screenshot-flags: parse + geometry" {
    const t = std.testing;
    const f = parse(&[_][]const u8{ "horizon", "--cursor", "--output", "DP-1", "out.png" }).flags;
    try t.expect(f.cursor);
    try t.expectEqualStrings("DP-1", f.output.?);
    try t.expectEqualStrings("out.png", f.file.?);
    try t.expect(f.clipboard);
    const g = parseGeometry("800x600+10+20").?;
    try t.expect(g.w == 800 and g.x == 10);
    try t.expect(parseGeometry("bogus") == null);
    try t.expect(parseGeometry("-5x10+0+0") == null);
}

test "screenshot-flags: --around-mouse eats its WxH value" {
    const t = std.testing;
    const r = parse(&[_][]const u8{ "horizon", "--eh-screenshot", "--around-mouse", "400x300", "out.png" });
    try t.expect(r.problem == null);
    try t.expect(r.flags.around_mouse);
    try t.expectEqual(@as(i32, 400), r.flags.around_w);
    try t.expectEqual(@as(i32, 300), r.flags.around_h);
    // The value is consumed, so it never becomes the output filename.
    try t.expectEqualStrings("out.png", r.flags.file.?);

    try t.expect(parse(&[_][]const u8{ "horizon", "--around-mouse" }).problem != null);
    try t.expect(parse(&[_][]const u8{ "horizon", "--around-mouse", "big" }).problem != null);
}

test "screenshot-flags: geometry round-trips a negative origin" {
    const t = std.testing;
    // What `Rect.format` writes for a crop above a monitor at y=0.
    const g = parseGeometry("300x200+1920+-40").?;
    try t.expectEqual(@as(i32, 300), g.w);
    try t.expectEqual(@as(i32, 200), g.h);
    try t.expectEqual(@as(i32, 1920), g.x);
    try t.expectEqual(@as(i32, -40), g.y);
    // Trailing newline from slurp's output, and leading spaces.
    const trimmed = parseGeometry("  640x480+0+120\n").?;
    try t.expectEqual(@as(i32, 640), trimmed.w);
    try t.expectEqual(@as(i32, 120), trimmed.y);
    try t.expect(parseGeometry("640x480+0") == null);
    try t.expect(parseGeometry("640x480+0+1+2") == null);
}

test "screenshot-flags: exclusivity and usage rules" {
    const t = std.testing;
    const both = parse(&[_][]const u8{ "horizon", "--select", "--slurp", "out.png" }).flags;
    try t.expect(both.exclusiveProblem() != null);
    const one = parse(&[_][]const u8{ "horizon", "--select", "out.png" }).flags;
    try t.expect(one.exclusiveProblem() == null);

    // Nothing asked for at all.
    try t.expect(parse(&[_][]const u8{ "horizon" }).flags.wantsUsage());
    // A bare file, or the clipboard default alone, is a whole-output save.
    try t.expect(!parse(&[_][]const u8{ "horizon", "out.png" }).flags.wantsUsage());
    try t.expect(parse(&[_][]const u8{ "horizon", "out.png" }).flags.clipboard);
    try t.expect(!parse(&[_][]const u8{ "horizon", "--clipboard" }).flags.wantsUsage());
    // `--no-clipboard` is explicit intent too.
    try t.expect(!parse(&[_][]const u8{ "horizon", "--no-clipboard" }).flags.wantsUsage());
}

test "screenshot-flags: --all-monitors is its own mode" {
    const t = std.testing;
    const f = parse(&[_][]const u8{ "horizon", "--all-monitors", "out.png" }).flags;
    try t.expect(f.all_monitors);
    try t.expect(!f.wantsUsage());
    try t.expect(f.exclusiveProblem() == null);
    // It must not silently combine with the interactive region picker.
    const both = parse(&[_][]const u8{ "horizon", "--all-monitors", "--select", "out.png" }).flags;
    try t.expect(both.exclusiveProblem() != null);
}

test "screenshot-flags: unknown option still fails" {
    const t = std.testing;
    try t.expect(parse(&[_][]const u8{ "horizon", "--bogus-flag" }).problem != null);
}
