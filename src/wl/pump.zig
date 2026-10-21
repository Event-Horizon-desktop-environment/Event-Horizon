const std = @import("std");
const wl = @import("c.zig").wl;

const POLL = std.posix.POLL;

/// The display fd is only readable when libwayland has *nothing* left to hand
/// out, so this callback has to pull bytes off the wire itself.
///
/// The original version called `wl_display_dispatch_pending` alone, which is
/// a no-op here: it only replays events libwayland has already read into the
/// client queue, and it never touches the socket. Two consequences, both of
/// them real and both observed:
///
///   * every event after startup — pointer enter/motion/button, foreign
///     toplevel add/remove, configure — was never read, so the dock had no
///     input and never lit an indicator; and
///   * the fd stayed readable forever, so `ppoll` returned immediately on the
///     next iteration and the process spun at 100% CPU.
///
/// `prepare_read`/`read_events` is the pair that actually consumes the fd, so
/// poll blocks again once the queue is empty.
pub fn displayCallback(fd: i32, revents: i16, ctx: *anyopaque) void {
    _ = fd;
    const display: ?*wl.wl_display = @ptrCast(@alignCast(ctx));
    const d = display orelse return;
    if (!isReadable(revents)) return;

    // `prepare_read` refuses while the queue holds events, so empty it first;
    // the loop only spins if dispatch keeps finding new work, which is bounded
    // by what the compositor has already sent. A negative return is a
    // connection error (the compositor dropped us): looping on it would spin
    // forever, so bail out instead.
    var prepared = wl.wl_display_dispatch_pending(d) >= 0 and wl.wl_display_prepare_read(d) == 0;
    while (!prepared) {
        if (wl.wl_display_dispatch_pending(d) <= 0) break;
        prepared = wl.wl_display_prepare_read(d) == 0;
    }
    if (!prepared) return;

    // Push our own requests first: a commit that stays buffered is a frame the
    // compositor never sees.
    _ = wl.wl_display_flush(d);
    _ = wl.wl_display_read_events(d);
    _ = wl.wl_display_dispatch_pending(d);
}

pub fn flushCallback(fd: i32, revents: i16, ctx: *anyopaque) void {
    _ = fd;
    _ = revents;
    const display: ?*wl.wl_display = @ptrCast(@alignCast(ctx));
    if (display) |d| {
        _ = wl.wl_display_flush(d);
    }
}

/// HUP and ERR have to count as readable: when the compositor disconnects the
/// fd reports exactly those, and ignoring them would leave us polling a socket
/// we can no longer read.
fn isReadable(revents: i16) bool {
    return (revents & (POLL.IN | POLL.ERR | POLL.HUP)) != 0;
}

test "pump: revents gate" {
    const t = std.testing;
    try t.expect(isReadable(POLL.IN));
    try t.expect(isReadable(POLL.HUP));
    try t.expect(isReadable(POLL.ERR));
    try t.expect(isReadable(POLL.IN | POLL.OUT));
    try t.expect(!isReadable(POLL.OUT));
    try t.expect(!isReadable(0));
}
