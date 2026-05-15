const std = @import("std");
const protocol = @import("../../agent/types.zig");
const observations = @import("observations.zig");

pub const Limits = struct {
    pub const text_result_bytes: usize = 64 * 1024;

    pub const listing_entries: usize = 1000;
    pub const listing_scan_entries: usize = 10_000;

    pub const process_stdout_bytes: usize = 8 * 1024 * 1024;
};

pub const BuiltinCtx = struct {
    cwd: []const u8,
    owns_cwd: bool = false,
    io: std.Io = std.Options.debug_io,
    session_id: []const u8 = "",
    image_auto_resize: bool = true,
    observations: observations.Store = observations.Store.init(std.heap.page_allocator),
    observation_events: observations.PendingEvents = observations.PendingEvents.init(std.heap.page_allocator),

    pub fn deinit(self: *BuiltinCtx, allocator: std.mem.Allocator) void {
        self.observation_events.deinit(allocator);
        self.observations.deinit(allocator);
        if (self.owns_cwd) allocator.free(self.cwd);
        self.* = undefined;
    }
};

pub fn parseSchema(comptime schema: []const u8) std.json.Value {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        std.heap.page_allocator,
        schema,
        .{ .allocate = .alloc_always },
    ) catch return .null;
    return parsed.value;
}

fn singleTextResult(allocator: std.mem.Allocator, text: []const u8, is_error: bool) protocol.AgentToolResult {
    const owned_text = allocator.dupe(u8, text) catch return .{ .content = &.{}, .is_error = is_error };
    errdefer allocator.free(owned_text);

    const blocks = allocator.alloc(protocol.AgentToolResult.ContentBlock, 1) catch
        return .{ .content = &.{}, .is_error = is_error };
    blocks[0] = .{ .text = .{ .text = owned_text } };
    return .{ .content = blocks, .is_error = is_error };
}

pub fn textResult(allocator: std.mem.Allocator, text: []const u8) protocol.AgentToolResult {
    return singleTextResult(allocator, text, false);
}

pub fn ownedTextResult(allocator: std.mem.Allocator, owned_text: []u8, is_error: bool) protocol.AgentToolResult {
    errdefer allocator.free(owned_text);
    const blocks = allocator.alloc(protocol.AgentToolResult.ContentBlock, 1) catch {
        allocator.free(owned_text);
        return .{ .content = &.{}, .is_error = is_error };
    };
    blocks[0] = .{ .text = .{ .text = owned_text } };
    return .{ .content = blocks, .is_error = is_error };
}

pub fn errorResult(allocator: std.mem.Allocator, text: []const u8) protocol.AgentToolResult {
    return singleTextResult(allocator, text, true);
}

pub fn errorf(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) protocol.AgentToolResult {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch
        return errorResult(allocator, "(error formatting failure)");
    defer allocator.free(msg);
    return errorResult(allocator, msg);
}

pub fn jsonPutString(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try obj.put(allocator, owned_key, .{ .string = owned_value });
}

pub fn jsonPutOwnedString(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, owned_value: []u8) !void {
    errdefer allocator.free(owned_value);
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try obj.put(allocator, owned_key, .{ .string = owned_value });
}

pub fn jsonPutInt(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: i64) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try obj.put(allocator, owned_key, .{ .integer = value });
}

pub fn jsonPutBool(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: bool) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try obj.put(allocator, owned_key, .{ .bool = value });
}

pub fn getString(args: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = switch (args) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn getBool(args: std.json.Value, key: []const u8) ?bool {
    const obj = switch (args) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

pub fn getI64(args: std.json.Value, key: []const u8) ?i64 {
    const obj = switch (args) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

pub fn getIntPair(args: std.json.Value, key: []const u8) ?[2]i64 {
    const obj = switch (args) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get(key) orelse return null;
    const arr = switch (v) {
        .array => |a| a,
        else => return null,
    };
    if (arr.items.len != 2) return null;
    const a = switch (arr.items[0]) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return null,
    };
    const b = switch (arr.items[1]) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return null,
    };
    return .{ a, b };
}

pub fn expandPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const stripped = if (path.len > 0 and path[0] == '@') path[1..] else path;
    if (std.mem.eql(u8, stripped, "~")) {
        const home = @import("env").get("HOME") orelse
            return allocator.dupe(u8, stripped);
        return allocator.dupe(u8, home);
    }
    if (stripped.len >= 2 and stripped[0] == '~' and stripped[1] == '/') {
        const home = @import("env").get("HOME") orelse
            return allocator.dupe(u8, stripped);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, stripped[1..] });
    }
    return allocator.dupe(u8, stripped);
}

pub fn resolvePath(
    allocator: std.mem.Allocator,
    path: []const u8,
    cwd: []const u8,
) ![]const u8 {
    const expanded = try expandPath(allocator, path);
    if (std.fs.path.isAbsolute(expanded)) return expanded;
    defer allocator.free(expanded);
    return std.fs.path.resolve(allocator, &.{ cwd, expanded });
}

pub fn isSecretFile(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    const exceptions = [_][]const u8{ ".env.example", ".env.sample", ".env.template" };
    for (exceptions) |ex| if (std.mem.eql(u8, base, ex)) return false;
    if (std.mem.eql(u8, base, ".env")) return true;
    if (std.mem.startsWith(u8, base, ".env.")) return true;
    return false;
}

test "textResult owns copied text" {
    const allocator = std.testing.allocator;
    const literal = "hello world";

    const result = textResult(allocator, literal);
    defer result.free(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expectEqualStrings(literal, result.content[0].text.text);
    try std.testing.expect(result.content[0].text.text.ptr != literal.ptr);
    try std.testing.expect(!result.is_error);
}

test "errorResult owns copied text" {
    const allocator = std.testing.allocator;
    const literal = "boom";

    const result = errorResult(allocator, literal);
    defer result.free(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expectEqualStrings(literal, result.content[0].text.text);
    try std.testing.expect(result.content[0].text.text.ptr != literal.ptr);
    try std.testing.expect(result.is_error);
}
