const std = @import("std");

pub const PkcePair = struct {
    verifier: []u8,
    challenge: []u8,

    pub fn deinit(self: *PkcePair, allocator: std.mem.Allocator) void {
        allocator.free(self.challenge);
        allocator.free(self.verifier);
        self.* = undefined;
    }
};

pub fn generate(allocator: std.mem.Allocator, random: std.Random) !PkcePair {
    var verifier_bytes: [32]u8 = undefined;
    random.bytes(&verifier_bytes);
    const verifier = try base64UrlEncode(allocator, &verifier_bytes);
    errdefer allocator.free(verifier);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const challenge = try base64UrlEncode(allocator, &digest);

    return .{ .verifier = verifier, .challenge = challenge };
}

pub fn base64UrlEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const output = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    errdefer allocator.free(output);
    _ = encoder.encode(output, bytes);
    return output;
}

test "base64 url encode omits padding and uses url alphabet" {
    const encoded = try base64UrlEncode(std.testing.allocator, &.{ 0xfb, 0xff, 0xee });
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("-__u", encoded);
}

test "generate returns verifier and sha256 challenge encoded as base64url" {
    var prng = std.Random.DefaultPrng.init(1);
    var pair = try generate(std.testing.allocator, prng.random());
    defer pair.deinit(std.testing.allocator);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pair.verifier, &digest, .{});
    const expected = try base64UrlEncode(std.testing.allocator, &digest);
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqual(@as(usize, 43), pair.verifier.len);
    try std.testing.expectEqualStrings(expected, pair.challenge);
}
