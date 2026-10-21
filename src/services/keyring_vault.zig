const std = @import("std");

pub const rounds: u32 = 100_000;
pub const salt_len = 16;
pub const nonce_len = 12;
pub const tag_len = 16;

const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;

pub fn deriveKey(password: []const u8, salt: []const u8, out_key: *[32]u8) !void {
    try std.crypto.pwhash.pbkdf2(out_key, password, salt, rounds, std.crypto.auth.hmac.sha2.HmacSha256);
}

pub const Package = struct {
    salt: [salt_len]u8,
    nonce: [nonce_len]u8,
    ct: []u8,
    tag: [tag_len]u8,
};

fn randBytes(buf: []u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.os.linux.getrandom(buf[off..].ptr, buf.len - off, 0);
        const e = std.os.linux.errno(n);
        if (e != .SUCCESS) {
            if (e == .INTR) continue;
            @panic("getrandom failed");
        }
        const got: usize = @intCast(n);
        if (got == 0) @panic("getrandom returned 0");
        off += got;
    }
}

pub fn seal(alloc: std.mem.Allocator, password: []const u8, plaintext: []const u8) !Package {
    var salt: [salt_len]u8 = undefined;
    var nonce: [nonce_len]u8 = undefined;
    randBytes(&salt);
    randBytes(&nonce);
    var key: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try deriveKey(password, &salt, &key);
    const ct = try alloc.alloc(u8, plaintext.len);
    errdefer alloc.free(ct);
    var tag: [tag_len]u8 = undefined;
    Aes.encrypt(ct, &tag, plaintext, "", nonce, key);
    return .{ .salt = salt, .nonce = nonce, .ct = ct, .tag = tag };
}

pub fn open(alloc: std.mem.Allocator, password: []const u8, pkg: Package) ![]u8 {
    var key: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try deriveKey(password, &pkg.salt, &key);
    const pt = try alloc.alloc(u8, pkg.ct.len);
    errdefer alloc.free(pt);
    Aes.decrypt(pt, pkg.ct, pkg.tag, "", pkg.nonce, key) catch return error.AuthenticationFailed;
    return pt;
}

pub fn freePackage(alloc: std.mem.Allocator, pkg: *Package) void {
    std.crypto.secureZero(u8, pkg.ct);
    alloc.free(pkg.ct);
    std.crypto.secureZero(u8, &pkg.salt);
    std.crypto.secureZero(u8, &pkg.nonce);
    std.crypto.secureZero(u8, &pkg.tag);
}

test "keyring-vault: seal/open round trip + wrong password fails" {
    const t = std.testing;
    var pkg = try seal(t.allocator, "correct horse", "super secret");
    defer freePackage(t.allocator, &pkg);
    const pt = try open(t.allocator, "correct horse", pkg);
    defer {
        std.crypto.secureZero(u8, pt);
        t.allocator.free(pt);
    }
    try t.expectEqualStrings("super secret", pt);
    try t.expectError(error.AuthenticationFailed, open(t.allocator, "wrong horse", pkg));
}
