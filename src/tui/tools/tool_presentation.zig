// Adapts fx's action-oriented tool presentation to Zi's four built-in tools.
// Licensed under Apache-2.0 and adapted to Zi's event contract.
const std = @import("std");
const Store = @import("../transcript/Store.zig");

const max_json_value_bytes: usize = 512;
const max_target_bytes: usize = 160;

pub const Activity = struct {
    running: []u8,
    completed: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        arguments_json: []const u8,
    ) !Activity {
        const labels = labelsFor(name);
        const key = if (std.mem.eql(u8, name, "bash")) "command" else "path";
        const target = extractTopLevelString(allocator, arguments_json, key) catch null;
        defer if (target) |value| allocator.free(value);

        const running = try formatLabel(allocator, labels.running, target);
        errdefer allocator.free(running);
        return .{
            .running = running,
            .completed = try formatLabel(allocator, labels.completed, target),
        };
    }

    pub fn deinit(self: *Activity, allocator: std.mem.Allocator) void {
        allocator.free(self.running);
        allocator.free(self.completed);
        self.* = undefined;
    }
};

pub fn writeCompletion(
    writer: *std.Io.Writer,
    phrase: []const u8,
    outcome: Store.ToolOutcome,
) std.Io.Writer.Error!void {
    try writer.writeAll(if (outcome == .success) "● " else "■ ");
    try writePhrase(writer, phrase, outcome);
    try writer.writeByte('\n');
}

pub fn writePhrase(
    writer: *std.Io.Writer,
    phrase: []const u8,
    outcome: Store.ToolOutcome,
) std.Io.Writer.Error!void {
    try writer.writeAll(phrase);
    switch (outcome) {
        .success => {},
        .failed => try writer.writeAll(" failed"),
        .cancelled => try writer.writeAll(" cancelled"),
        .interrupted => try writer.writeAll(" interrupted"),
    }
}

const Labels = struct {
    running: []const u8,
    completed: []const u8,
};

fn labelsFor(name: []const u8) Labels {
    if (std.mem.eql(u8, name, "read")) return .{ .running = "Reading", .completed = "Read" };
    if (std.mem.eql(u8, name, "write")) return .{ .running = "Writing", .completed = "Wrote" };
    if (std.mem.eql(u8, name, "edit")) return .{ .running = "Editing", .completed = "Edited" };
    if (std.mem.eql(u8, name, "bash")) return .{ .running = "Running", .completed = "Ran" };
    return .{ .running = "Using tool", .completed = "Used tool" };
}

fn formatLabel(
    allocator: std.mem.Allocator,
    action: []const u8,
    target: ?[]const u8,
) ![]u8 {
    if (target) |value| {
        if (value.len != 0) return std.fmt.allocPrint(allocator, "{s} {s}", .{ action, value });
    }
    return allocator.dupe(u8, action);
}

/// Extracts one top-level string without materializing unrelated values. This
/// keeps a large write payload from becoming presentation memory.
fn extractTopLevelString(
    allocator: std.mem.Allocator,
    source: []const u8,
    wanted_key: []const u8,
) !?[]u8 {
    var scanner = std.json.Scanner.initCompleteInput(allocator, source);
    defer scanner.deinit();

    const opening = try scanner.nextAllocMax(allocator, .alloc_if_needed, 64);
    defer freeToken(allocator, opening);
    if (opening != .object_begin) return null;

    while (true) {
        const key_token = try scanner.nextAllocMax(allocator, .alloc_if_needed, 64);
        switch (key_token) {
            .object_end => return null,
            .string, .allocated_string => |key| {
                const matches = std.mem.eql(u8, key, wanted_key);
                freeToken(allocator, key_token);
                if (!matches) {
                    try scanner.skipValue();
                    continue;
                }

                const value_token = try scanner.nextAllocMax(
                    allocator,
                    .alloc_if_needed,
                    max_json_value_bytes,
                );
                defer freeToken(allocator, value_token);
                return switch (value_token) {
                    .string, .allocated_string => |value| try normalizeTarget(allocator, value),
                    else => null,
                };
            },
            else => {
                freeToken(allocator, key_token);
                return null;
            },
        }
    }
}

fn normalizeTarget(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var view = std.unicode.Utf8View.init(source) catch return out.toOwnedSlice();
    var iterator = view.iterator();
    var consumed: usize = 0;
    var pending_space = false;
    while (iterator.peek(1).len != 0 and consumed < max_target_bytes) {
        const start = iterator.i;
        const scalar = iterator.nextCodepoint().?;
        const bytes = source[start..iterator.i];
        consumed = iterator.i;
        if (scalar == '\n' or scalar == '\r' or scalar == '\t' or scalar == ' ') {
            pending_space = out.written().len != 0;
            continue;
        }
        if (pending_space) {
            try out.writer.writeByte(' ');
            pending_space = false;
        }
        if (scalar < 0x20 or (scalar >= 0x7f and scalar <= 0x9f)) {
            try out.writer.writeAll("�");
        } else {
            try out.writer.writeAll(bytes);
        }
    }
    if (iterator.peek(1).len != 0) try out.writer.writeAll("…");
    return out.toOwnedSlice();
}

fn freeToken(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |value| allocator.free(value),
        else => {},
    }
}

test "tool presentation exposes action and bounded target instead of raw output" {
    var activity = try Activity.init(
        std.testing.allocator,
        "read",
        "{\"path\":\"src/main.zig\",\"offset\":1}",
    );
    defer activity.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Reading src/main.zig", activity.running);
    try std.testing.expectEqualStrings("Read src/main.zig", activity.completed);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCompletion(&out.writer, activity.completed, .success);
    try std.testing.expectEqualStrings("● Read src/main.zig\n", out.written());
}

test "tool presentation skips large unrelated write content" {
    var activity = try Activity.init(
        std.testing.allocator,
        "write",
        "{\"content\":\"large value\",\"path\":\"README.md\"}",
    );
    defer activity.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Writing README.md", activity.running);
}

test "tool presentation falls back when arguments are not usable" {
    var activity = try Activity.init(std.testing.allocator, "bash", "not json");
    defer activity.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Running", activity.running);
}
