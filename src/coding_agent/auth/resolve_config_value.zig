const std = @import("std");
const string_util = @import("../../lib/string_util.zig");

// Process-global cache/store backing. Entries own both key and value storage;
// `clearCache()` frees those allocations in tests.
const allocator = std.heap.page_allocator;

/// Cache for shell command results. Process-lifetime cache matching pi-mono.
/// Key: full config string including "!" prefix. Value: owned result or null on failure.
var command_cache: std.StringHashMap(?[]const u8) = std.StringHashMap(?[]const u8).init(allocator);

/// Resolve a config value.
/// - "!cmd" → execute shell command, cache result
/// - env var name → look up in environment
/// - otherwise → return as literal
///
/// pi-mono source: packages/coding-agent/src/core/resolve-config-value.ts:17-23
pub fn resolveConfigValue(config: []const u8) ?[]const u8 {
    if (config.len > 0 and config[0] == '!') {
        return executeCommand(config);
    }
    if (@import("env").get(config)) |env_val| {
        return env_val;
    }
    return config;
}

/// Same as resolveConfigValue but bypasses cache for command execution.
/// pi-mono source: resolve-config-value.ts:91-97
pub fn resolveConfigValueUncached(config: []const u8) ?[]const u8 {
    if (config.len > 0 and config[0] == '!') {
        return executeCommandUncached(config);
    }
    if (@import("env").get(config)) |env_val| {
        return env_val;
    }
    return config;
}

/// Resolve a config value, returning an error on failure.
/// pi-mono source: resolve-config-value.ts:99-110
pub fn resolveConfigValueOrError(config: []const u8) error{ResolveFailed}![]const u8 {
    return resolveConfigValueUncached(config) orelse error.ResolveFailed;
}

/// Clear the command cache. For testing.
pub fn clearCache() void {
    var it = command_cache.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        if (entry.value_ptr.*) |val| {
            allocator.free(val);
        }
    }
    command_cache.clearRetainingCapacity();
}

/// Resolve all header values using the same resolution logic as API keys.
/// pi-mono source: resolve-config-value.ts:115-125
pub fn resolveHeaders(
    alloc: std.mem.Allocator,
    headers: ?std.json.ObjectMap,
) ?std.StringArrayHashMap([]const u8) {
    const hdrs = headers orelse return null;
    if (hdrs.count() == 0) return null;

    var resolved = std.StringArrayHashMap([]const u8).init(alloc);
    var it = hdrs.iterator();
    while (it.next()) |entry| {
        const value = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => continue,
        };
        if (resolveConfigValue(value)) |resolved_val| {
            resolved.put(entry.key_ptr.*, resolved_val) catch continue;
        }
    }
    return if (resolved.count() > 0) resolved else null;
}

// --- internal ---

fn executeCommand(config: []const u8) ?[]const u8 {
    if (command_cache.get(config)) |cached| {
        return cached;
    }

    const result = executeCommandUncached(config);
    const owned_key = allocator.dupe(u8, config) catch return result;
    errdefer allocator.free(owned_key);

    command_cache.put(owned_key, result) catch return result;
    return result;
}

fn executeCommandUncached(config: []const u8) ?[]const u8 {
    const command = config[1..]; // strip "!"
    if (command.len == 0) return null;

    var child = std.process.spawn(std.Options.debug_io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(std.Options.debug_io, &stdout_buf);
    const stdout = stdout_reader.interface.allocRemaining(allocator, .limited(50 * 1024)) catch return null;
    defer allocator.free(stdout);

    const term = child.wait(std.Options.debug_io) catch return null;
    if (term != .exited or term.exited != 0) {
        return null;
    }

    const trimmed = string_util.dupeTrimmed(allocator, stdout, &std.ascii.whitespace) catch return null;
    errdefer allocator.free(trimmed);
    if (trimmed.len == 0) {
        return null;
    }

    return trimmed;
}

// --- tests ---

test "shell command returns trimmed stdout" {
    clearCache();
    defer clearCache();

    const val = resolveConfigValue("!echo hello");
    try std.testing.expectEqualStrings("hello", val.?);
}

test "command results are cached" {
    clearCache();
    defer clearCache();

    const a = resolveConfigValue("!echo cached-test");
    const b = resolveConfigValue("!echo cached-test");
    try std.testing.expectEqual(a.?.ptr, b.?.ptr);
}
