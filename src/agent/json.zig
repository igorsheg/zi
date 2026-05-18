const std = @import("std");
const event = @import("event.zig");

pub fn writeEvent(jw: *std.json.Stringify, value: event.AgentEvent) !void {
    try jw.beginObject();
    try jw.objectField("type");
    switch (value) {
        .lifecycle => |lifecycle| switch (lifecycle) {
            .run_started => try jw.write("runStarted"),
            .turn_started => try jw.write("turnStarted"),
            .run_finished => |terminal| {
                try jw.write("runFinished");
                try jw.objectField("terminal");
                try writeRunTerminal(jw, terminal);
            },
            .turn_finished => |terminal| {
                try jw.write("turnFinished");
                try jw.objectField("terminal");
                try writeTurnTerminal(jw, terminal);
            },
        },
        .message => |message| switch (message) {
            .started => try jw.write("messageStarted"),
            .delta => try jw.write("messageDelta"),
            .finished => try jw.write("messageFinished"),
        },
        .tool => |tool| switch (tool) {
            .started => try jw.write("toolStarted"),
            .update => try jw.write("toolUpdate"),
            .finished => try jw.write("toolFinished"),
        },
    }
    try jw.endObject();
}

fn writeRunTerminal(jw: *std.json.Stringify, terminal: event.RunTerminal) !void {
    return writeTerminalTag(jw, switch (terminal) {
        .completed => "completed",
        .failed => "failed",
        .aborted => "aborted",
    });
}

fn writeTurnTerminal(jw: *std.json.Stringify, terminal: event.TurnTerminal) !void {
    return writeTerminalTag(jw, switch (terminal) {
        .completed => "completed",
        .failed => "failed",
        .aborted => "aborted",
    });
}

fn writeTerminalTag(jw: *std.json.Stringify, tag: []const u8) !void {
    try jw.beginObject();
    try jw.objectField("status");
    try jw.write(tag);
    try jw.endObject();
}

test "writes run terminal event status" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try writeEvent(&jw, .{ .lifecycle = .{ .run_finished = .{ .aborted = .{ .messages = &.{} } } } });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "aborted") != null);
}
