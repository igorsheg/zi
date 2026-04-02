const std = @import("std");

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

/// Parse auth.json content into AuthStorageData.
/// Returns an owned hashmap — caller must call `deinitAuthStorageData`.
pub fn parseAuthJson(allocator: std.mem.Allocator, json_content: []const u8) !AuthStorageData {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.UnexpectedToken;

    var data = AuthStorageData.init(allocator);
    errdefer deinitAuthStorageData(&data);

    var it = root.object.iterator();
    while (it.next()) |entry| {
        const provider_id = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(provider_id);

        const obj = entry.value_ptr.*;
        if (obj != .object) return error.UnexpectedToken;

        const type_val = obj.object.get("type") orelse return error.MissingField;
        if (type_val != .string) return error.UnexpectedToken;
        const type_str = type_val.string;

        const credential = if (std.mem.eql(u8, type_str, "api_key")) blk: {
            const key_val = obj.object.get("key") orelse return error.MissingField;
            if (key_val != .string) return error.UnexpectedToken;
            break :blk AuthCredential{ .api_key = .{
                .key = try allocator.dupe(u8, key_val.string),
            } };
        } else if (std.mem.eql(u8, type_str, "oauth")) blk: {
            const refresh_val = obj.object.get("refresh") orelse return error.MissingField;
            const access_val = obj.object.get("access") orelse return error.MissingField;
            const expires_val = obj.object.get("expires") orelse return error.MissingField;
            if (refresh_val != .string) return error.UnexpectedToken;
            if (access_val != .string) return error.UnexpectedToken;
            if (expires_val != .integer) return error.UnexpectedToken;

            var extras = std.json.ObjectMap.init(allocator);
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
                const cloned_val = try cloneJsonValue(allocator, field.value_ptr.*);
                try extras.put(duped_key, cloned_val);
            }

            break :blk AuthCredential{ .oauth = .{
                .refresh = try allocator.dupe(u8, refresh_val.string),
                .access = try allocator.dupe(u8, access_val.string),
                .expires = expires_val.integer,
                .extras = extras,
            } };
        } else return error.UnexpectedToken;

        try data.put(provider_id, credential);
    }

    return data;
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
                    freeJsonValue(allocator, e.value_ptr.*);
                }
                extras.deinit();
            },
        }
        allocator.free(entry.key_ptr.*);
    }
    data.deinit();
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| return .{ .integer = i },
        .float => |f| return .{ .float = f },
        .number_string => |s| return .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var new_arr = try std.json.Array.initCapacity(allocator, arr.items.len);
            for (arr.items) |item| {
                try new_arr.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = std.json.ObjectMap.init(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try cloneJsonValue(allocator, entry.value_ptr.*);
                try new_obj.put(key, val);
            }
            return .{ .object = new_obj };
        },
    }
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var mutable = arr;
            mutable.deinit();
        },
        .object => |obj| {
            var mutable = obj;
            var oit = mutable.iterator();
            while (oit.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            mutable.deinit();
        },
        else => {},
    }
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

