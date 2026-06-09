const std = @import("std");

const client_protocol = @import("client_protocol.zig");

pub const version: u32 = 1;
pub const max_input_line_bytes: usize = 64 * 1024;
pub const max_output_event_bytes: usize = 256 * 1024;
pub const max_pending_request_ids: usize = 64;
pub const max_malformed_lines: usize = 16;
pub const max_prompt_text_bytes: usize = 32 * 1024;

pub const DecodeError = error{
    InputLineTooLarge,
    InvalidJson,
    InvalidMessage,
    InvalidRequestId,
    UnknownCommand,
    PromptTooLarge,
} || std.mem.Allocator.Error;

pub const EncodeError = error{
    OutputEventTooLarge,
    EventJsonNotObject,
    WriteFailed,
} || std.mem.Allocator.Error;

pub fn decodeCommandLine(
    allocator: std.mem.Allocator,
    raw_line: []const u8,
) DecodeError!?client_protocol.CommandEnvelope {
    if (raw_line.len > max_input_line_bytes) return error.InputLineTooLarge;
    const line = trimLine(raw_line);
    if (line.len == 0) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .object) return error.InvalidMessage;
    const object = value.object;

    const id = try decodeRequestId(object.get("id"));
    const type_value = object.get("type") orelse return error.InvalidMessage;
    if (type_value != .string) return error.InvalidMessage;
    const command_type = type_value.string;

    if (std.mem.eql(u8, command_type, "submit_prompt")) {
        const text_value = object.get("text") orelse return error.InvalidMessage;
        if (text_value != .string) return error.InvalidMessage;
        if (text_value.string.len > max_prompt_text_bytes) return error.PromptTooLarge;
        return try client_protocol.CommandEnvelope.initSubmitPrompt(allocator, id, text_value.string);
    }
    if (std.mem.eql(u8, command_type, "cancel")) return .{ .id = id, .command = .cancel };
    if (std.mem.eql(u8, command_type, "clear_queue")) return .{ .id = id, .command = .clear_queue };
    if (std.mem.eql(u8, command_type, "request_snapshot")) return .{ .id = id, .command = .request_snapshot };
    if (std.mem.eql(u8, command_type, "shutdown")) return .{ .id = id, .command = .shutdown };
    return error.UnknownCommand;
}

pub fn encodeEventEnvelope(
    allocator: std.mem.Allocator,
    envelope: client_protocol.EventEnvelope,
) EncodeError![]u8 {
    var event_json: std.Io.Writer.Allocating = .init(allocator);
    defer event_json.deinit();
    try std.json.Stringify.value(envelope.event, .{}, &event_json.writer);
    const event_bytes = event_json.written();
    if (event_bytes.len < 2 or event_bytes[0] != '{' or event_bytes[event_bytes.len - 1] != '}') {
        return error.EventJsonNotObject;
    }

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (envelope.request_id) |id| {
        try output.writer.writeByte('{');
        try output.writer.print("\"id\":{},", .{id});
        try output.writer.writeAll(event_bytes[1 .. event_bytes.len - 1]);
        try output.writer.writeByte('}');
    } else {
        try output.writer.writeAll(event_bytes);
    }
    try output.writer.writeByte('\n');
    if (output.written().len > max_output_event_bytes) return error.OutputEventTooLarge;
    return try output.toOwnedSlice();
}

pub fn trimLine(raw_line: []const u8) []const u8 {
    if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') return raw_line[0 .. raw_line.len - 1];
    return raw_line;
}

fn decodeRequestId(value: ?std.json.Value) DecodeError!?client_protocol.RequestId {
    const raw = value orelse return null;
    if (raw != .integer) return error.InvalidRequestId;
    if (raw.integer < 0) return error.InvalidRequestId;
    return @intCast(raw.integer);
}

test "wire protocol decodes submit prompt command" {
    var envelope = (try decodeCommandLine(std.testing.allocator, "{\"id\":1,\"type\":\"submit_prompt\",\"text\":\"hello\"}")) orelse unreachable;
    defer envelope.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?client_protocol.RequestId, 1), envelope.id);
    try std.testing.expect(envelope.command == .submit_prompt);
    try std.testing.expectEqualStrings("hello", envelope.command.submit_prompt.text);
}

test "wire protocol decodes CRLF and ignores empty lines" {
    try std.testing.expect((try decodeCommandLine(std.testing.allocator, "\r")) == null);
    var envelope = (try decodeCommandLine(std.testing.allocator, "{\"type\":\"cancel\"}\r")) orelse unreachable;
    defer envelope.deinit(std.testing.allocator);
    try std.testing.expect(envelope.command == .cancel);
}

test "wire protocol rejects malformed and oversized commands" {
    try std.testing.expectError(error.InvalidJson, decodeCommandLine(std.testing.allocator, "{"));
    try std.testing.expectError(error.UnknownCommand, decodeCommandLine(std.testing.allocator, "{\"type\":\"wat\"}"));
    try std.testing.expectError(error.InvalidRequestId, decodeCommandLine(std.testing.allocator, "{\"id\":-1,\"type\":\"cancel\"}"));
    const oversized = "a" ** (max_prompt_text_bytes + 1);
    var line = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer line.deinit();
    try line.writer.writeAll("{\"type\":\"submit_prompt\",\"text\":\"");
    try line.writer.writeAll(oversized);
    try line.writer.writeAll("\"}");
    try std.testing.expectError(error.PromptTooLarge, decodeCommandLine(std.testing.allocator, line.written()));
}

test "wire protocol encodes event envelope with top-level id" {
    var message = try client_protocol.EventText.init(std.testing.allocator, "nope");
    defer message.deinit();
    const event: client_protocol.EventEnvelope = .{
        .request_id = 7,
        .event = .{ .rejected = .{ .code = .invalid_command, .message = message } },
    };
    const encoded = try encodeEventEnvelope(std.testing.allocator, event);
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(std.mem.startsWith(u8, encoded, "{\"id\":7,"));
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"type\":\"rejected\"") != null);
    try std.testing.expect(encoded[encoded.len - 1] == '\n');
}
