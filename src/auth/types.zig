const std = @import("std");
const json_util = @import("../ai/json_util.zig");

/// API key credential — stored as `{"type": "api_key", "key": "..."}` in auth.json.
/// pi-mono source: packages/coding-agent/src/core/auth-storage.ts:22-25
pub const ApiKeyCredential = struct {
    key: []const u8,
};

/// OAuth credential — stored with refresh/access/expires in auth.json.
/// pi-mono source: packages/ai/src/utils/oauth/types.ts:3-8
/// Extra provider-specific fields (projectId, enterpriseUrl, etc.) are captured
/// in the `extras` map so round-tripping preserves unknown keys.
pub const OAuthCredential = struct {
    refresh: []const u8,
    access: []const u8,
    /// Unix timestamp in milliseconds when the access token expires.
    expires: i64,
    /// Provider-specific extra fields (e.g. projectId, enterpriseUrl).
    /// Preserves unknown keys for round-trip fidelity with pi-mono's
    /// `[key: string]: unknown` index signature on OAuthCredentials.
    extras: std.json.ObjectMap,
};

/// Tagged credential union matching pi-mono's AuthCredential.
/// pi-mono source: packages/coding-agent/src/core/auth-storage.ts:31
pub const AuthCredential = union(enum) {
    api_key: ApiKeyCredential,
    oauth: OAuthCredential,
};

/// The full auth.json data structure — a map from provider ID to credential.
/// pi-mono source: packages/coding-agent/src/core/auth-storage.ts:33
pub const AuthStorageData = std.StringHashMap(AuthCredential);

const log = std.log.scoped(.auth_storage);

/// Parse auth.json content into AuthStorageData.
/// Returns an owned hashmap — caller must call `deinitAuthStorageData`.
///
/// Resilience (zi-kfg): the OUTER `std.json.parseFromSlice` is the
/// only operation that can fail this whole function — if the file
/// is malformed JSON, there's nothing to recover. But once we have
/// a parsed object, individual entry failures (missing fields,
/// wrong types, bad UTF-8 in values) are LOGGED AND SKIPPED rather
/// than aborting the whole map. One bricked entry must not take
/// down every other credential. zi-m7q taught us this the hard way.
pub fn parseAuthJson(allocator: std.mem.Allocator, json_content: []const u8) !AuthStorageData {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.UnexpectedToken;

    var data = AuthStorageData.init(allocator);
    errdefer deinitAuthStorageData(&data);

    var it = root.object.iterator();
    while (it.next()) |entry| {
        const credential = parseEntry(allocator, entry.value_ptr.*) catch |err| {
            log.warn("auth.json: skipping malformed entry '{s}': {s}", .{ entry.key_ptr.*, @errorName(err) });
            continue;
        };

        const provider_id = allocator.dupe(u8, entry.key_ptr.*) catch |err| {
            // OOM cleaning up the entry we just built — free it then
            // propagate. Out-of-memory is the one error we don't try
            // to swallow because the caller's error path needs to know.
            freeOneCredential(allocator, credential);
            return err;
        };
        data.put(provider_id, credential) catch |err| {
            allocator.free(provider_id);
            freeOneCredential(allocator, credential);
            return err;
        };
    }

    return data;
}

/// Parse a single auth.json entry value (the object after the
/// provider key). Errors here are recoverable — the caller will
/// log + skip and continue with the rest of the map.
fn parseEntry(allocator: std.mem.Allocator, obj: std.json.Value) !AuthCredential {
    if (obj != .object) return error.UnexpectedToken;

    const type_val = obj.object.get("type") orelse return error.MissingField;
    if (type_val != .string) return error.UnexpectedToken;
    const type_str = type_val.string;

    if (std.mem.eql(u8, type_str, "api_key")) {
        const key_val = obj.object.get("key") orelse return error.MissingField;
        if (key_val != .string) return error.UnexpectedToken;
        const key_dup = try allocator.dupe(u8, key_val.string);
        return .{ .api_key = .{ .key = key_dup } };
    }

    if (std.mem.eql(u8, type_str, "oauth")) {
        const refresh_val = obj.object.get("refresh") orelse return error.MissingField;
        const access_val = obj.object.get("access") orelse return error.MissingField;
        const expires_val = obj.object.get("expires") orelse return error.MissingField;
        if (refresh_val != .string) return error.UnexpectedToken;
        if (access_val != .string) return error.UnexpectedToken;
        if (expires_val != .integer) return error.UnexpectedToken;

        const refresh_dup = try allocator.dupe(u8, refresh_val.string);
        errdefer allocator.free(refresh_dup);
        const access_dup = try allocator.dupe(u8, access_val.string);
        errdefer allocator.free(access_dup);

        var extras = std.json.ObjectMap.init(allocator);
        errdefer {
            var eit = extras.iterator();
            while (eit.next()) |e| {
                allocator.free(e.key_ptr.*);
                json_util.freeJsonValue(allocator, e.value_ptr.*);
            }
            extras.deinit();
        }

        var obj_it = obj.object.iterator();
        while (obj_it.next()) |field| {
            const k = field.key_ptr.*;
            if (std.mem.eql(u8, k, "type") or
                std.mem.eql(u8, k, "refresh") or
                std.mem.eql(u8, k, "access") or
                std.mem.eql(u8, k, "expires"))
                continue;
            const duped_key = try allocator.dupe(u8, k);
            errdefer allocator.free(duped_key);
            const cloned_val = try json_util.cloneJsonValue(allocator, field.value_ptr.*);
            try extras.put(duped_key, cloned_val);
        }

        return .{ .oauth = .{
            .refresh = refresh_dup,
            .access = access_dup,
            .expires = expires_val.integer,
            .extras = extras,
        } };
    }

    return error.UnexpectedToken;
}

/// Free a single credential's owned strings. Mirrors the cleanup
/// done by deinitAuthStorageData per-entry, factored out so the
/// skip-bad-entry path can free a partially-built credential
/// without nuking the whole map.
fn freeOneCredential(allocator: std.mem.Allocator, cred: AuthCredential) void {
    switch (cred) {
        .api_key => |c| allocator.free(c.key),
        .oauth => |c| {
            allocator.free(c.refresh);
            allocator.free(c.access);
            var extras = c.extras;
            var eit = extras.iterator();
            while (eit.next()) |e| {
                allocator.free(e.key_ptr.*);
                json_util.freeJsonValue(allocator, e.value_ptr.*);
            }
            extras.deinit();
        },
    }
}

/// Serialize AuthStorageData to JSON string matching pi-mono's format.
/// Produces `JSON.stringify(data, null, 2)` output — 2-space indent.
/// Caller owns the returned string.
pub fn serializeAuthJson(allocator: std.mem.Allocator, data: *const AuthStorageData) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2 },
    };

    try jw.beginObject();

    var it = data.iterator();
    while (it.next()) |entry| {
        try jw.objectField(entry.key_ptr.*);
        try jw.beginObject();

        switch (entry.value_ptr.*) {
            .api_key => |cred| {
                try jw.objectField("type");
                try jw.write("api_key");
                try jw.objectField("key");
                try jw.write(cred.key);
            },
            .oauth => |cred| {
                try jw.objectField("type");
                try jw.write("oauth");
                try jw.objectField("refresh");
                try jw.write(cred.refresh);
                try jw.objectField("access");
                try jw.write(cred.access);
                try jw.objectField("expires");
                try jw.write(cred.expires);

                var extras_it = cred.extras.iterator();
                while (extras_it.next()) |extra| {
                    try jw.objectField(extra.key_ptr.*);
                    try jw.write(extra.value_ptr.*);
                }
            },
        }

        try jw.endObject();
    }

    try jw.endObject();
    try out.writer.flush();

    return try allocator.dupe(u8, out.written());
}

/// Free all allocations owned by an AuthStorageData map.
pub fn deinitAuthStorageData(data: *AuthStorageData) void {
    const allocator = data.allocator;
    var it = data.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .api_key => |cred| allocator.free(cred.key),
            .oauth => |cred| {
                allocator.free(cred.refresh);
                allocator.free(cred.access);
                var extras = cred.extras;
                var eit = extras.iterator();
                while (eit.next()) |e| {
                    allocator.free(e.key_ptr.*);
                    json_util.freeJsonValue(allocator, e.value_ptr.*);
                }
                extras.deinit();
            },
        }
        allocator.free(entry.key_ptr.*);
    }
    data.deinit();
}

// ── tests ───────────────────────────────────────────────────────────────

test "parse auth.json with api_key and oauth entries" {
    const input =
        \\{
        \\  "anthropic": {
        \\    "type": "api_key",
        \\    "key": "sk-ant-test123"
        \\  },
        \\  "openai": {
        \\    "type": "oauth",
        \\    "refresh": "rt-abc",
        \\    "access": "at-xyz",
        \\    "expires": 1234567890000
        \\  }
        \\}
    ;

    var data = try parseAuthJson(std.testing.allocator, input);
    defer deinitAuthStorageData(&data);

    const anthropic = data.get("anthropic").?;
    try std.testing.expectEqual(.api_key, std.meta.activeTag(anthropic));
    try std.testing.expectEqualStrings("sk-ant-test123", anthropic.api_key.key);

    const openai = data.get("openai").?;
    try std.testing.expectEqual(.oauth, std.meta.activeTag(openai));
    try std.testing.expectEqualStrings("rt-abc", openai.oauth.refresh);
    try std.testing.expectEqualStrings("at-xyz", openai.oauth.access);
    try std.testing.expectEqual(@as(i64, 1234567890000), openai.oauth.expires);
}

test "round-trip serialize then parse preserves data" {
    var data = AuthStorageData.init(std.testing.allocator);
    defer deinitAuthStorageData(&data);

    const key = try std.testing.allocator.dupe(u8, "anthropic");
    errdefer std.testing.allocator.free(key);
    try data.put(key, .{ .api_key = .{
        .key = try std.testing.allocator.dupe(u8, "sk-test"),
    } });

    const key2 = try std.testing.allocator.dupe(u8, "openai");
    errdefer std.testing.allocator.free(key2);
    try data.put(key2, .{ .oauth = .{
        .refresh = try std.testing.allocator.dupe(u8, "rt-1"),
        .access = try std.testing.allocator.dupe(u8, "at-2"),
        .expires = 9999999,
        .extras = std.json.ObjectMap.init(std.testing.allocator),
    } });

    const json = try serializeAuthJson(std.testing.allocator, &data);
    defer std.testing.allocator.free(json);

    var parsed = try parseAuthJson(std.testing.allocator, json);
    defer deinitAuthStorageData(&parsed);

    const a = parsed.get("anthropic").?;
    try std.testing.expectEqualStrings("sk-test", a.api_key.key);

    const o = parsed.get("openai").?;
    try std.testing.expectEqualStrings("rt-1", o.oauth.refresh);
    try std.testing.expectEqualStrings("at-2", o.oauth.access);
    try std.testing.expectEqual(@as(i64, 9999999), o.oauth.expires);
}

test "zi-kfg: malformed entries are skipped, valid entries survive" {
    // Mixed file with one good entry sandwiched between two bad ones.
    // Pre-fix, the first bad entry would abort the whole parse and
    // the user would lose ALL credentials. Post-fix, parseAuthJson
    // logs and skips the bad ones, returns a map with just "good".
    const input =
        \\{
        \\  "missing-type": {
        \\    "refresh": "rt",
        \\    "access": "at",
        \\    "expires": 1
        \\  },
        \\  "good": {
        \\    "type": "api_key",
        \\    "key": "sk-keep-me"
        \\  },
        \\  "wrong-type-on-key": {
        \\    "type": "api_key",
        \\    "key": 12345
        \\  }
        \\}
    ;

    var data = try parseAuthJson(std.testing.allocator, input);
    defer deinitAuthStorageData(&data);

    try std.testing.expectEqual(@as(u32, 1), data.count());
    const good = data.get("good").?;
    try std.testing.expectEqualStrings("sk-keep-me", good.api_key.key);
    try std.testing.expect(data.get("missing-type") == null);
    try std.testing.expect(data.get("wrong-type-on-key") == null);
}

