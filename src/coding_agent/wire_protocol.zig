const std = @import("std");

const client_protocol = @import("client_protocol.zig");

pub const max_input_line_bytes: usize = 64 * 1024;
pub const max_output_event_bytes: usize = 256 * 1024;
pub const max_malformed_lines: usize = 16;
pub const max_prompt_text_bytes: usize = 32 * 1024;

pub const CommandDecodeError = error{
    InputLineTooLarge,
    InvalidJson,
    InvalidMessage,
    InvalidRequestId,
    UnknownCommand,
    PromptTooLarge,
} || std.mem.Allocator.Error;

pub const EventEncodeError = error{
    OutputEventTooLarge,
    WriteFailed,
} || std.mem.Allocator.Error;

// ziglint-ignore: Z015 exported protocol API intentionally exposes its named decode error set.
pub fn decodeCommandLine(
    allocator: std.mem.Allocator,
    raw_line: []const u8,
) CommandDecodeError!?client_protocol.CommandEnvelope {
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

    if (std.mem.eql(u8, command_type, "submit")) {
        const text_value = object.get("text") orelse return error.InvalidMessage;
        if (text_value != .string) return error.InvalidMessage;
        if (text_value.string.len > max_prompt_text_bytes) return error.PromptTooLarge;
        const envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(
            allocator,
            id,
            text_value.string,
            try decodeSubmitMode(object.get("mode")),
        );
        return envelope;
    }
    if (std.mem.eql(u8, command_type, "cancel")) {
        return .{ .id = id, .command = .{ .cancel = try decodeCancel(object.get("target")) } };
    }
    if (std.mem.eql(u8, command_type, "queue.clear")) return .{ .id = id, .command = .{ .queue = .clear } };
    if (std.mem.eql(u8, command_type, "snapshot")) return .{ .id = id, .command = .snapshot };
    if (std.mem.eql(u8, command_type, "replay")) {
        return .{ .id = id, .command = .{ .replay = try decodeReplay(object) } };
    }
    if (std.mem.eql(u8, command_type, "shutdown")) return .{ .id = id, .command = .shutdown };
    return error.UnknownCommand;
}

// ziglint-ignore: Z015 exported protocol API intentionally exposes its named encode error set.
pub fn encodeEventEnvelope(
    allocator: std.mem.Allocator,
    envelope: client_protocol.EventEnvelope,
) EventEncodeError![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(envelope, .{}, &output.writer);
    try output.writer.writeByte('\n');
    if (output.written().len > max_output_event_bytes) return error.OutputEventTooLarge;
    return output.toOwnedSlice();
}

fn trimLine(raw_line: []const u8) []const u8 {
    if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') return raw_line[0 .. raw_line.len - 1];
    return raw_line;
}

fn decodeRequestId(value: ?std.json.Value) CommandDecodeError!?client_protocol.RequestId {
    return decodeOptionalId(value, error.InvalidRequestId);
}

fn decodeSubmitMode(value: ?std.json.Value) CommandDecodeError!client_protocol.Submit.Mode {
    const raw = value orelse return .auto;
    if (raw != .string) return error.InvalidMessage;
    if (std.mem.eql(u8, raw.string, "auto")) return .auto;
    if (std.mem.eql(u8, raw.string, "start")) return .start;
    if (std.mem.eql(u8, raw.string, "enqueue")) return .enqueue;
    if (std.mem.eql(u8, raw.string, "steer")) return .steer;
    return error.InvalidMessage;
}

fn decodeCancel(value: ?std.json.Value) CommandDecodeError!client_protocol.Cancel {
    const raw = value orelse return .{};
    if (raw == .string) {
        if (std.mem.eql(u8, raw.string, "active")) return .{};
        return error.InvalidMessage;
    }
    if (raw != .object) return error.InvalidMessage;
    if (raw.object.get("requestId")) |id| {
        return .{ .target = .{ .request_id = try decodeRequiredId(id) } };
    }
    if (raw.object.get("operationId")) |id| {
        return .{ .target = .{ .operation_id = try decodeRequiredId(id) } };
    }
    return error.InvalidMessage;
}

fn decodeRequiredId(raw: std.json.Value) CommandDecodeError!client_protocol.RequestId {
    return (try decodeOptionalId(raw, error.InvalidRequestId)) orelse error.InvalidRequestId;
}

fn decodeOptionalId(
    value: ?std.json.Value,
    err: CommandDecodeError,
) CommandDecodeError!?client_protocol.RequestId {
    const raw = value orelse return null;
    if (raw != .integer or raw.integer < 0) return err;
    return @intCast(raw.integer);
}

fn decodeReplay(object: std.json.ObjectMap) CommandDecodeError!client_protocol.ReplayRequest {
    const after = (try decodeOptionalId(object.get("after"), error.InvalidMessage)) orelse
        return error.InvalidMessage;
    return .{ .after = after };
}

test "wire protocol decodes submit prompt command" {
    const line = "{\"id\":1,\"type\":\"submit\",\"text\":\"hello\",\"mode\":\"start\"}";
    var envelope = (try decodeCommandLine(std.testing.allocator, line)) orelse unreachable;
    defer envelope.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?client_protocol.RequestId, 1), envelope.id);
    try std.testing.expect(envelope.command == .submit);
    try std.testing.expectEqualStrings("hello", envelope.command.submit.text);
    try std.testing.expectEqual(client_protocol.Submit.Mode.start, envelope.command.submit.mode);
}

test "wire protocol decodes CRLF and ignores empty lines" {
    try std.testing.expect((try decodeCommandLine(std.testing.allocator, "\r")) == null);
    var envelope = (try decodeCommandLine(std.testing.allocator, "{\"type\":\"cancel\"}\r")) orelse unreachable;
    defer envelope.deinit(std.testing.allocator);
    try std.testing.expect(envelope.command == .cancel);
}

// Cancel targets identify work without giving clients mutation authority.
test "wire protocol decodes cancel operation target" {
    const line = "{\"type\":\"cancel\",\"target\":{\"operationId\":9}}";
    var envelope = (try decodeCommandLine(std.testing.allocator, line)) orelse unreachable;
    defer envelope.deinit(std.testing.allocator);
    try std.testing.expect(envelope.command == .cancel);
    try std.testing.expectEqual(@as(client_protocol.OperationId, 9), envelope.command.cancel.target.operation_id);
}

test "wire protocol rejects malformed and oversized commands" {
    try std.testing.expectError(error.InvalidJson, decodeCommandLine(std.testing.allocator, "{"));
    try std.testing.expectError(error.UnknownCommand, decodeCommandLine(std.testing.allocator, "{\"type\":\"wat\"}"));
    try std.testing.expectError(
        error.InvalidRequestId,
        decodeCommandLine(std.testing.allocator, "{\"id\":-1,\"type\":\"cancel\"}"),
    );
    const oversized = "a" ** (max_prompt_text_bytes + 1);
    var line = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer line.deinit();
    try line.writer.writeAll("{\"type\":\"submit\",\"text\":\"");
    try line.writer.writeAll(oversized);
    try line.writer.writeAll("\"}");
    try std.testing.expectError(error.PromptTooLarge, decodeCommandLine(std.testing.allocator, line.written()));
}

test "wire protocol encodes event envelope object directly" {
    var message = try client_protocol.EventText.init(std.testing.allocator, "nope");
    defer message.deinit(std.testing.allocator);
    const event: client_protocol.EventEnvelope = .{
        .seq = 3,
        .request_id = 7,
        .event = .{ .rejected = .{ .code = .invalid_command, .message = message } },
    };
    const encoded = try encodeEventEnvelope(std.testing.allocator, event);
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(std.mem.startsWith(u8, encoded, "{\"seq\":3,\"id\":7,\"event\":{"));
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"type\":\"rejected\"") != null);
    try std.testing.expect(encoded[encoded.len - 1] == '\n');
}
