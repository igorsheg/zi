const std = @import("std");
const BoundedJson = @import("../../BoundedJson.zig");
const oauth_api = @import("../oauth.zig");
const fake_transport = @import("../transport/fake.zig");
const transport_api = @import("../transport.zig");

pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const token_url = "https://auth.openai.com/oauth/token";
const max_response_bytes = 64 * 1024;

pub const OAuth = struct {
    pub fn refresher(self: *const OAuth) oauth_api.Refresher {
        return oauth_api.Refresher.from(self);
    }

    pub fn refresh(
        _: *const OAuth,
        result_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        io: std.Io,
        transport: transport_api.Transport,
        request: oauth_api.Request,
    ) oauth_api.Error!oauth_api.Refreshed {
        var body: std.Io.Writer.Allocating = .init(scratch_allocator);
        defer {
            std.crypto.secureZero(u8, body.written());
            body.deinit();
        }
        var form: Form = .{};
        form.append(&body.writer, "grant_type", "refresh_token") catch return error.OutOfMemory;
        form.append(&body.writer, "refresh_token", request.credential.refresh) catch return error.OutOfMemory;
        form.append(&body.writer, "client_id", client_id) catch return error.OutOfMemory;

        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = .fromSeconds(15),
            .clock = .awake,
        });
        const response = try transport.exchange(scratch_allocator, io, .{
            .method = .POST,
            .url = token_url,
            .body = body.written(),
            .content_type = "application/x-www-form-urlencoded",
            .max_response_bytes = max_response_bytes,
            .deadline = deadline,
        }, .buffered);
        defer if (response.body.len > 0) std.crypto.secureZero(u8, @constCast(response.body));
        if (response.status < 200 or response.status >= 300) return error.Rejected;
        BoundedJson.validate(scratch_allocator, response.body, .{
            .document_bytes = max_response_bytes,
            .value_bytes = 64 * 1024,
            .depth = 3,
            .collection_items = 32,
        }) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidResponse,
        };
        const TokenResponse = struct {
            access_token: []const u8,
            refresh_token: []const u8,
            expires_in: u64,
        };
        var parsed = std.json.parseFromSlice(TokenResponse, scratch_allocator, response.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
            .max_value_len = 64 * 1024,
        }) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidResponse,
        };
        defer {
            std.crypto.secureZero(u8, @constCast(parsed.value.access_token));
            std.crypto.secureZero(u8, @constCast(parsed.value.refresh_token));
            parsed.deinit();
        }
        if (parsed.value.access_token.len == 0 or parsed.value.refresh_token.len == 0 or
            parsed.value.expires_in == 0)
        {
            return error.InvalidResponse;
        }
        const duration_ms = std.math.mul(u64, parsed.value.expires_in, 1000) catch
            return error.InvalidResponse;
        const expires_at_ms = std.math.add(u64, request.now_ms, duration_ms) catch
            return error.InvalidResponse;

        var arena = std.heap.ArenaAllocator.init(result_allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const access = owned.dupe(u8, parsed.value.access_token) catch return error.OutOfMemory;
        errdefer std.crypto.secureZero(u8, access);
        const refresh_token = owned.dupe(u8, parsed.value.refresh_token) catch return error.OutOfMemory;
        errdefer std.crypto.secureZero(u8, refresh_token);
        const account_id = accountIdFromJwt(owned, access) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidToken => error.InvalidResponse,
        };
        errdefer std.crypto.secureZero(u8, account_id);
        return .{
            .arena = arena,
            .credential = .{
                .access = access,
                .refresh = refresh_token,
                .expires_at_ms = expires_at_ms,
                .account_id = account_id,
            },
        };
    }
};

pub const AccountIdError = error{ OutOfMemory, InvalidToken };

pub fn accountIdFromJwt(
    allocator: std.mem.Allocator,
    access_token: []const u8,
) AccountIdError![]u8 {
    var segments = std.mem.splitScalar(u8, access_token, '.');
    _ = segments.next() orelse return error.InvalidToken;
    const payload_segment = segments.next() orelse return error.InvalidToken;
    if (segments.next() == null or segments.next() != null) return error.InvalidToken;
    const decoded_size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_segment) catch
        return error.InvalidToken;
    const decoded = allocator.alloc(u8, decoded_size) catch return error.OutOfMemory;
    defer {
        std.crypto.secureZero(u8, decoded);
        allocator.free(decoded);
    }
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload_segment) catch return error.InvalidToken;
    const Claims = struct {
        @"https://api.openai.com/auth": struct {
            chatgpt_account_id: []const u8,
        },
    };
    var parsed = std.json.parseFromSlice(Claims, allocator, decoded, .{
        .ignore_unknown_fields = true,
        .max_value_len = 64 * 1024,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidToken,
    };
    defer parsed.deinit();
    const account_id = parsed.value.@"https://api.openai.com/auth".chatgpt_account_id;
    if (account_id.len == 0) return error.InvalidToken;
    defer std.crypto.secureZero(u8, @constCast(account_id));
    return allocator.dupe(u8, account_id) catch return error.OutOfMemory;
}

const Form = struct {
    first: bool = true,

    fn append(self: *Form, writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
        if (!self.first) try writer.writeByte('&');
        self.first = false;
        try percentEncode(writer, key);
        try writer.writeByte('=');
        try percentEncode(writer, value);
    }
};

fn percentEncode(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn testAccessToken(allocator: std.mem.Allocator, account_id: []const u8) ![]u8 {
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\"}}}}",
        .{account_id},
    );
    defer allocator.free(payload);
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(payload.len));
    defer allocator.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
    return std.fmt.allocPrint(allocator, "header.{s}.signature", .{encoded});
}

fn refreshAndDeinit(allocator: std.mem.Allocator) !void {
    const response =
        "{\"access_token\":\"header." ++
        "eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudCJ9fQ" ++
        ".signature\",\"refresh_token\":\"rotated\",\"expires_in\":3600}";
    const exchanges = [_]fake_transport.Exchange{.{ .response = .{
        .status = 200,
        .body = response,
    } }};
    var fake = fake_transport.FakeTransport.init(&exchanges);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const implementation: OAuth = .{};
    var refreshed = try implementation.refresher().refresh(
        allocator,
        scratch.allocator(),
        std.testing.io,
        fake.transport(),
        .{
            .credential = .{
                .access = "old-access",
                .refresh = "old-refresh",
                .expires_at_ms = 1,
            },
            .now_ms = 1000,
        },
    );
    refreshed.deinit();
}

test "Codex OAuth refresh settles every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, refreshAndDeinit, .{});
}

test "Codex OAuth refresh rotates tokens and extracts the account identity" {
    const Inspector = struct {
        fn inspect(_: *anyopaque, request: transport_api.Request) error{Rejected}!void {
            if (!std.mem.eql(u8, request.url, token_url)) return error.Rejected;
            if (request.method != .POST) return error.Rejected;
            if (!std.mem.eql(u8, request.content_type.?, "application/x-www-form-urlencoded")) {
                return error.Rejected;
            }
            const expected = "grant_type=refresh_token&refresh_token=old%20refresh%2B%2F%3F&client_id=" ++ client_id;
            if (!std.mem.eql(u8, request.body, expected)) return error.Rejected;
            if (request.max_response_bytes != max_response_bytes or request.deadline == null) {
                return error.Rejected;
            }
        }
    };
    const access = try testAccessToken(std.testing.allocator, "account-123");
    defer std.testing.allocator.free(access);
    const response_body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"rotated\",\"expires_in\":3600}}",
        .{access},
    );
    defer std.testing.allocator.free(response_body);
    const exchanges = [_]fake_transport.Exchange{.{ .response = .{
        .status = 200,
        .body = response_body,
    } }};
    var fake = fake_transport.FakeTransport.init(&exchanges);
    var inspector_context: u8 = 0;
    fake.inspector = .{ .context = &inspector_context, .inspect_fn = Inspector.inspect };
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const implementation: OAuth = .{};
    var refreshed = try implementation.refresher().refresh(
        std.testing.allocator,
        scratch.allocator(),
        std.testing.io,
        fake.transport(),
        .{
            .credential = .{
                .access = "old-access",
                .refresh = "old refresh+/?",
                .expires_at_ms = 1,
            },
            .now_ms = 1000,
        },
    );
    defer refreshed.deinit();

    try std.testing.expectEqualStrings(access, refreshed.credential.access);
    try std.testing.expectEqualStrings("rotated", refreshed.credential.refresh);
    try std.testing.expectEqual(@as(u64, 3_601_000), refreshed.credential.expires_at_ms);
    try std.testing.expectEqualStrings("account-123", refreshed.credential.account_id.?);
    try std.testing.expectEqual(@as(usize, 1), fake.next_index);
}
