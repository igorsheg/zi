const std = @import("std");
const mem = @import("../../runtime/root.zig");
const partial_json = @import("partial_json.zig");

pub const JsonDocument = mem.JsonOwned(std.json.Value);

pub const StreamingJson = struct {
    owned: JsonDocument,
    complete: bool,
    consumed: usize,

    pub fn deinit(self: *StreamingJson) void {
        self.owned.deinit();
        self.* = undefined;
    }

    pub fn value(self: *const StreamingJson) std.json.Value {
        return self.owned.value;
    }
};

pub fn repairJson(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    var repaired = mem.ByteBuilder.init(allocator);
    errdefer repaired.deinit();
    var in_string = false;
    var index: usize = 0;

    while (index < json.len) : (index += 1) {
        const byte = json[index];
        if (!in_string) {
            try repaired.appendByte(byte);
            if (byte == '"') in_string = true;
            continue;
        }

        if (byte == '"') {
            try repaired.appendByte(byte);
            in_string = false;
            continue;
        }

        if (byte == '\\') {
            index += try repairEscape(allocator, &repaired, json[index..]);
            continue;
        }

        if (isControlCharacter(byte)) {
            try writeEscapedControlCharacter(allocator, &repaired, byte);
        } else {
            try repaired.appendByte(byte);
        }
    }

    return repaired.toOwnedSlice();
}

pub fn parseJsonWithRepair(backing_allocator: std.mem.Allocator, json: []const u8) !JsonDocument {
    if (parseJsonDocument(backing_allocator, json)) |owned| return owned else |_| {}

    const repaired = try repairJson(backing_allocator, json);
    defer backing_allocator.free(repaired);

    if (std.mem.eql(u8, repaired, json)) return parseJsonDocument(backing_allocator, json);
    return parseJsonDocument(backing_allocator, repaired);
}

pub fn parseStreamingJson(backing_allocator: std.mem.Allocator, maybe_json: ?[]const u8) !StreamingJson {
    const json = std.mem.trim(u8, maybe_json orelse "", " \t\n\r");
    if (json.len == 0) return emptyStreamingObject(backing_allocator);

    if (parseJsonWithRepair(backing_allocator, json)) |owned| {
        return .{ .owned = owned, .complete = true, .consumed = json.len };
    } else |_| {}

    if (parsePartialOwned(backing_allocator, json)) |streaming| return streaming else |_| {}

    const repaired = try repairJson(backing_allocator, json);
    defer backing_allocator.free(repaired);
    if (parsePartialOwned(backing_allocator, repaired)) |streaming| return streaming else |_| {}

    return emptyStreamingObject(backing_allocator);
}

fn parseJsonDocument(backing_allocator: std.mem.Allocator, json: []const u8) !JsonDocument {
    const arena = try backing_allocator.create(std.heap.ArenaAllocator);
    errdefer backing_allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    return .{ .arena = arena, .value = value };
}

fn parsePartialOwned(backing_allocator: std.mem.Allocator, json: []const u8) !StreamingJson {
    const arena = try backing_allocator.create(std.heap.ArenaAllocator);
    errdefer backing_allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const result = try partial_json.parse(arena.allocator(), json);
    const value = result.value orelse return error.NoPartialValue;
    return .{
        .owned = .{ .arena = arena, .value = value },
        .complete = result.complete,
        .consumed = result.consumed,
    };
}

fn emptyStreamingObject(backing_allocator: std.mem.Allocator) !StreamingJson {
    const arena = try backing_allocator.create(std.heap.ArenaAllocator);
    errdefer backing_allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const object: std.json.ObjectMap = .empty;
    return .{
        .owned = .{ .arena = arena, .value = .{ .object = object } },
        .complete = false,
        .consumed = 0,
    };
}

fn repairEscape(allocator: std.mem.Allocator, repaired: *mem.ByteBuilder, remaining: []const u8) !usize {
    _ = allocator;
    if (remaining.len == 1) {
        try repaired.append("\\\\");
        return 0;
    }

    const escaped = remaining[1];
    if (escaped == 'u' and remaining.len >= 6 and isHexQuad(remaining[2..6])) {
        try repaired.append(remaining[0..6]);
        return 5;
    }

    if (isValidJsonEscape(escaped)) {
        try repaired.append(remaining[0..2]);
        return 1;
    }

    try repaired.append("\\\\");
    return 0;
}

fn isValidJsonEscape(byte: u8) bool {
    return switch (byte) {
        '"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u' => true,
        else => false,
    };
}

fn isHexQuad(bytes: []const u8) bool {
    if (bytes.len != 4) return false;
    for (bytes) |byte| {
        switch (byte) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

fn isControlCharacter(byte: u8) bool {
    return byte <= 0x1f;
}

fn writeEscapedControlCharacter(allocator: std.mem.Allocator, writer: *mem.ByteBuilder, byte: u8) !void {
    _ = allocator;
    switch (byte) {
        '\x08' => try writer.append("\\b"),
        '\x0c' => try writer.append("\\f"),
        '\n' => try writer.append("\\n"),
        '\r' => try writer.append("\\r"),
        '\t' => try writer.append("\\t"),
        else => {
            var buffer: [6]u8 = undefined;
            const escaped = try std.fmt.bufPrint(&buffer, "\\u{x:0>4}", .{byte});
            try writer.append(escaped);
        },
    }
}

test "repair json escapes raw control characters inside strings" {
    const repaired = try repairJson(std.testing.allocator, "{\"a\":\"one\ntwo\"}");
    defer std.testing.allocator.free(repaired);

    try std.testing.expectEqualStrings("{\"a\":\"one\\ntwo\"}", repaired);
}

test "repair json doubles invalid escape slash" {
    const repaired = try repairJson(std.testing.allocator, "{\"path\":\"c:\\q\"}");
    defer std.testing.allocator.free(repaired);

    try std.testing.expectEqualStrings("{\"path\":\"c:\\\\q\"}", repaired);
}

test "parse json with repair returns repaired value" {
    var owned = try parseJsonWithRepair(std.testing.allocator, "{\"a\":\"one\ntwo\"}");
    defer owned.deinit();

    try std.testing.expectEqualStrings("one\ntwo", owned.value.object.get("a").?.string);
}

test "parse streaming json returns empty object for empty input" {
    var parsed = try parseStreamingJson(std.testing.allocator, "  ");
    defer parsed.deinit();

    try std.testing.expect(parsed.value() == .object);
    try std.testing.expectEqual(@as(usize, 0), parsed.value().object.count());
    try std.testing.expect(!parsed.complete);
}

test "parse streaming json returns partial object" {
    var parsed = try parseStreamingJson(std.testing.allocator, "{\"location\": \"San");
    defer parsed.deinit();

    try std.testing.expect(parsed.value() == .object);
    try std.testing.expectEqualStrings("San", parsed.value().object.get("location").?.string);
    try std.testing.expect(!parsed.complete);
}

test "parse streaming json prefers strict complete parse" {
    var parsed = try parseStreamingJson(std.testing.allocator, "{\"ok\": true}");
    defer parsed.deinit();

    try std.testing.expect(parsed.complete);
    try std.testing.expect(parsed.value().object.get("ok").?.bool);
}
