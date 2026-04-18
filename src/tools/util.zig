//! Shared helpers for built-in tools.
//!
//! pi-mono parity: ports the pieces of the personal pi override tools that
//! every tool needs — path resolution, secret guard, schema parsing, and
//! AgentToolResult builders.
//!
//! Design notes:
//! - Tools are registered with a `*BuiltinCtx` so they know cwd without
//!   touching process state. The session owns the ctx for its lifetime.
//! - JSON schemas are parsed once into the page allocator (leaked) so the
//!   `parameters` slot can be a borrowed `std.json.Value`. Same trick the
//!   bash tool uses.
//! - All tool results allocate from the per-call allocator the agent loop
//!   passes in; ownership flows out of `execute` to the caller.

const std = @import("std");
const protocol = @import("../agent2/protocol.zig");

pub const BuiltinCtx = struct {
    cwd: []const u8,
    session_id: []const u8 = "",
    image_auto_resize: bool = true,
};

/// Parse a JSON schema string at startup. Leaks into page_allocator —
/// schemas live for the whole process, so this is fine and matches the
/// existing bash tool pattern. Returns `.null` on parse failure rather
/// than crashing the agent.
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

/// Build a single text content block result. Caller owns the allocation.
pub fn textResult(allocator: std.mem.Allocator, text: []const u8) protocol.AgentToolResult {
    return singleTextResult(allocator, text, false);
}

/// Build an error result with a single text block. Convenience for the
/// `return errorResult(...)` pattern.
pub fn errorResult(allocator: std.mem.Allocator, text: []const u8) protocol.AgentToolResult {
    return singleTextResult(allocator, text, true);
}

/// Format an error result via fmt.allocPrint. Falls back to a static
/// message if formatting fails.
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

/// Extract a string field from a JSON object arg.
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

/// Get an array of two integers (e.g. read_range).
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

/// Expand `~` and strip a leading `@` from a path. Mirrors pi's
/// override `expandPath`.
pub fn expandPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const stripped = if (path.len > 0 and path[0] == '@') path[1..] else path;
    if (std.mem.eql(u8, stripped, "~")) {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch
            return allocator.dupe(u8, stripped);
        return home;
    }
    if (stripped.len >= 2 and stripped[0] == '~' and stripped[1] == '/') {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch
            return allocator.dupe(u8, stripped);
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, stripped[1..] });
    }
    return allocator.dupe(u8, stripped);
}

/// Resolve a (possibly relative, possibly `~`-prefixed) path against `cwd`.
/// Caller owns the returned slice.
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

/// Returns true if `basename` matches a known secret-file pattern
/// (`.env`, `.env.*`) but is NOT one of the example/template exceptions.
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
