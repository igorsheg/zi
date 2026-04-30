const std = @import("std");

pub const PkceChallenge = struct {
    verifier_buf: [43]u8,
    challenge_buf: [43]u8,

    pub fn verifier(self: *const PkceChallenge) []const u8 {
        return &self.verifier_buf;
    }

    pub fn challenge(self: *const PkceChallenge) []const u8 {
        return &self.challenge_buf;
    }
};

/// Generate PKCE verifier and S256 challenge.
/// Uses cryptographic random + SHA-256. No allocation needed.
pub fn generate() PkceChallenge {
    var result: PkceChallenge = undefined;

    var random_bytes: [32]u8 = undefined;
    std.Options.debug_io.randomSecure(&random_bytes) catch std.Options.debug_io.random(&random_bytes);

    _ = std.base64.url_safe_no_pad.Encoder.encode(&result.verifier_buf, &random_bytes);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&result.verifier_buf, &hash, .{});

    _ = std.base64.url_safe_no_pad.Encoder.encode(&result.challenge_buf, &hash);

    return result;
}

pub const STATE_LEN = std.base64.url_safe_no_pad.Encoder.calcSize(16);

pub fn generateState() [STATE_LEN]u8 {
    var random_bytes: [16]u8 = undefined;
    std.Options.debug_io.randomSecure(&random_bytes) catch std.Options.debug_io.random(&random_bytes);
    var buf: [STATE_LEN]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&buf, &random_bytes);
    return buf;
}

test "pkce verifier and challenge are correct lengths" {
    const pkce = generate();
    try std.testing.expectEqual(@as(usize, 43), pkce.verifier().len);
    try std.testing.expectEqual(@as(usize, 43), pkce.challenge().len);
}

test "pkce challenge is sha256 of verifier" {
    const pkce = generate();
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&pkce.verifier_buf, &hash, .{});
    var expected: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&expected, &hash);
    try std.testing.expectEqualSlices(u8, &expected, pkce.challenge());
}

test "pkce generates unique values" {
    const a = generate();
    const b = generate();
    try std.testing.expect(!std.mem.eql(u8, &a.verifier_buf, &b.verifier_buf));
    try std.testing.expect(!std.mem.eql(u8, &a.challenge_buf, &b.challenge_buf));
}

test "generateState returns 22 chars" {
    const state = generateState();
    try std.testing.expectEqual(@as(usize, 22), state.len);
}
