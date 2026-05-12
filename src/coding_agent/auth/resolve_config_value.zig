const std = @import("std");
const command_query = @import("../../lib/command_query.zig");

const allocator = std.heap.page_allocator;

var command_cache: std.StringHashMap(?[]const u8) = std.StringHashMap(?[]const u8).init(allocator);

pub fn resolveConfigValue(config: []const u8) ?[]const u8 {
    if (config.len > 0 and config[0] == '!') {
        return executeCommand(config);
    }
    if (@import("env").get(config)) |env_val| {
        return env_val;
    }
    return config;
}

pub fn resolveConfigValueUncached(config: []const u8) ?[]const u8 {
    if (config.len > 0 and config[0] == '!') {
        return executeCommandUncached(config);
    }
    if (@import("env").get(config)) |env_val| {
        return env_val;
    }
    return config;
}

pub fn resolveConfigValueOrError(config: []const u8) error{ResolveFailed}![]const u8 {
    return resolveConfigValueUncached(config) orelse error.ResolveFailed;
}

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
    const command = config[1..];
    if (command.len == 0) return null;

    return command_query.stdout(allocator, std.Options.debug_io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .timeout_ms = 5000,
        .max_stdout_bytes = 50 * 1024,
        .trim = true,
    });
}

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
