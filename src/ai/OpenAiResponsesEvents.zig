const std = @import("std");
const Provider = @import("Provider.zig");
const StreamEvent = @import("StreamEvent.zig");
const Transport = @import("Transport.zig");
const Usage = @import("Usage.zig");

pub const maximum_tracked_calls: usize = 128;
pub const maximum_owned_state_bytes: usize = 256 * 1024;
pub const maximum_event_bytes: usize = 1024 * 1024;

pub const Options = struct {
    max_tracked_calls: usize = maximum_tracked_calls,
    max_owned_state_bytes: usize = maximum_owned_state_bytes,
    max_event_bytes: usize = maximum_event_bytes,
};

pub const Error = error{ OutOfMemory, Cancelled, InvalidResponse };

const ToolCall = struct {
    item_id: []u8,
    call_id: []u8,
    saw_arguments: bool = false,
    ended: bool = false,
};

/// Fresh, owned translation state for one OpenAI Responses stream. Emitted byte
/// slices are borrowed and remain valid only during the synchronous sink call.
pub const Parser = struct {
    allocator: std.mem.Allocator,
    sink: Provider.EventSink,
    options: Options,
    tool_calls: std.ArrayList(ToolCall) = .empty,
    owned_state_bytes: usize = 0,
    response_id: ?[]u8 = null,
    served_model: ?[]u8 = null,
    reasoning_item_id: ?[]u8 = null,
    reasoning_part_index: i64 = 0,
    reasoning_part_is_content: bool = false,
    terminal_emitted: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        sink: Provider.EventSink,
        options: Options,
    ) Error!Parser {
        if (options.max_tracked_calls == 0 or
            options.max_tracked_calls > maximum_tracked_calls or
            options.max_owned_state_bytes == 0 or
            options.max_owned_state_bytes > maximum_owned_state_bytes or
            options.max_event_bytes == 0 or
            options.max_event_bytes > maximum_event_bytes)
        {
            return error.InvalidResponse;
        }
        return .{ .allocator = allocator, .sink = sink, .options = options };
    }

    pub fn deinit(self: *Parser) void {
        for (self.tool_calls.items) |call| {
            self.allocator.free(call.item_id);
            self.allocator.free(call.call_id);
        }
        self.tool_calls.deinit(self.allocator);
        if (self.response_id) |value| self.allocator.free(value);
        if (self.served_model) |value| self.allocator.free(value);
        if (self.reasoning_item_id) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn feed(self: *Parser, event: Transport.SseEvent) Error!void {
        if (self.terminal_emitted) return;
        try validateSseEvent(event, self.options.max_event_bytes);
        const data = event.data;
        if (data.len == 0) return;
        if (std.mem.eql(u8, data, "[DONE]")) return self.emitCompleted(null);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResponse,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const root = parsed.value.object;
        const event_type = requiredString(root, "type") catch return error.InvalidResponse;
        if (event_type.len == 0) return error.InvalidResponse;
        try self.captureResponse(objectField(root, "response"));

        if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            try self.handleOutputItemAdded(objectField(root, "item"));
        } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            try self.handleOutputItemDone(objectField(root, "item"));
        } else if (std.mem.eql(u8, event_type, "response.output_text.delta") or
            std.mem.eql(u8, event_type, "response.refusal.delta"))
        {
            const delta = requiredString(root, "delta") catch return error.InvalidResponse;
            if (delta.len != 0) try self.emit(.{ .text_delta = delta });
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
        {
            try self.handleReasoningDelta(root);
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            try self.handleToolCallDelta(root);
        } else if (std.mem.eql(u8, event_type, "response.completed") or
            std.mem.eql(u8, event_type, "response.done"))
        {
            const response = objectField(root, "response") orelse return error.InvalidResponse;
            try self.emitCompleted(response);
        } else if (std.mem.eql(u8, event_type, "response.incomplete")) {
            const response = objectField(root, "response") orelse return error.InvalidResponse;
            const details = objectField(response, "incomplete_details");
            const reason = if (details) |value| stringField(value, "reason") else null;
            const message = try std.fmt.allocPrint(
                self.allocator,
                "response incomplete: {s}",
                .{reason orelse "unknown"},
            );
            defer self.allocator.free(message);
            try self.emitFailure(message, response);
        } else if (std.mem.eql(u8, event_type, "response.failed")) {
            const response = objectField(root, "response") orelse return error.InvalidResponse;
            const error_object = objectField(response, "error");
            const message = if (error_object) |value| stringField(value, "message") else null;
            try self.emitFailure(message orelse "response.failed", response);
        } else if (std.mem.eql(u8, event_type, "response.created")) {
            if (objectField(root, "response") == null) return error.InvalidResponse;
        } else if (std.mem.eql(u8, event_type, "error")) {
            const message = stringField(root, "message") orelse
                stringField(root, "code") orelse
                "provider error";
            try self.emitFailure(message, null);
        }
    }

    pub fn finalize(self: *Parser) Error!void {
        if (!self.terminal_emitted) try self.emitFailure("stream ended before completion", null);
    }

    pub fn isComplete(self: *const Parser) bool {
        return self.terminal_emitted;
    }

    /// Responses terminal usage is delivered with the terminal event. Attempt
    /// accounting is intentionally absent until retry integration owns it.
    pub fn usage(_: *const Parser) ?Usage.StreamUsage {
        return null;
    }

    pub fn recover(_: *Parser) Error!bool {
        return false;
    }

    fn handleOutputItemAdded(self: *Parser, item: ?std.json.ObjectMap) Error!void {
        const object = item orelse return error.InvalidResponse;
        const item_type = requiredString(object, "type") catch return error.InvalidResponse;
        if (!std.mem.eql(u8, item_type, "function_call")) return;
        const item_id = requiredString(object, "id") catch return error.InvalidResponse;
        const call_id = requiredString(object, "call_id") catch return error.InvalidResponse;
        const name = requiredString(object, "name") catch return error.InvalidResponse;
        if (item_id.len == 0 or call_id.len == 0 or name.len == 0) return error.InvalidResponse;
        if (self.findToolCall(item_id) != null) return error.InvalidResponse;
        if (self.tool_calls.items.len >= self.options.max_tracked_calls) return error.InvalidResponse;
        try self.reserveOwned(item_id.len + call_id.len);
        const owned_item = self.allocator.dupe(u8, item_id) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_item);
        const owned_call = self.allocator.dupe(u8, call_id) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_call);
        self.tool_calls.append(self.allocator, .{
            .item_id = owned_item,
            .call_id = owned_call,
        }) catch return error.OutOfMemory;
        try self.emit(.{ .tool_call_start = .{ .id = owned_call, .name = name } });
    }

    fn handleToolCallDelta(self: *Parser, root: std.json.ObjectMap) Error!void {
        const item_id = requiredString(root, "item_id") catch return error.InvalidResponse;
        const delta = requiredString(root, "delta") catch return error.InvalidResponse;
        if (delta.len == 0) return;
        const call = self.findToolCall(item_id) orelse return error.InvalidResponse;
        if (call.ended) return error.InvalidResponse;
        call.saw_arguments = true;
        try self.emit(.{ .tool_call_delta = .{ .id = call.call_id, .arguments_delta = delta } });
    }

    fn handleOutputItemDone(self: *Parser, item: ?std.json.ObjectMap) Error!void {
        const object = item orelse return error.InvalidResponse;
        const item_type = requiredString(object, "type") catch return error.InvalidResponse;
        if (std.mem.eql(u8, item_type, "function_call")) {
            const item_id = requiredString(object, "id") catch return error.InvalidResponse;
            const call = self.findToolCall(item_id) orelse return error.InvalidResponse;
            if (call.ended) return;
            if (!call.saw_arguments) {
                const arguments = requiredString(object, "arguments") catch
                    return error.InvalidResponse;
                if (arguments.len != 0) try self.emit(.{ .tool_call_delta = .{
                    .id = call.call_id,
                    .arguments_delta = arguments,
                } });
            }
            call.ended = true;
            try self.emit(.{ .tool_call_end = call.call_id });
        } else if (std.mem.eql(u8, item_type, "reasoning")) {
            const encrypted = object.get("encrypted_content") orelse return;
            if (encrypted == .null) return;
            const summary = object.get("summary");
            const Replay = struct {
                type: []const u8 = "reasoning",
                summary: std.json.Value,
                encrypted_content: std.json.Value,
            };
            var empty_summary = std.json.Array.init(self.allocator);
            defer empty_summary.deinit();
            const replay: Replay = .{
                .summary = if (summary) |value| value else .{ .array = empty_summary },
                .encrypted_content = encrypted,
            };
            const opaque_json = std.json.Stringify.valueAlloc(
                self.allocator,
                replay,
                .{},
            ) catch return error.OutOfMemory;
            defer self.allocator.free(opaque_json);
            try self.emit(.{ .reasoning_item = .{ .opaque_json = opaque_json } });
        }
    }

    fn handleReasoningDelta(self: *Parser, root: std.json.ObjectMap) Error!void {
        const delta = requiredString(root, "delta") catch return error.InvalidResponse;
        if (delta.len == 0) return;
        if (stringField(root, "item_id")) |item_id| {
            var is_content = false;
            const index = integerField(root, "summary_index") orelse index: {
                is_content = true;
                break :index integerField(root, "content_index") orelse {
                    try self.emit(.{ .reasoning_delta = delta });
                    return;
                };
            };
            const same_item = if (self.reasoning_item_id) |tracked| std.mem.eql(u8, tracked, item_id) else false;
            if (self.reasoning_item_id != null and
                (!same_item or index != self.reasoning_part_index or is_content != self.reasoning_part_is_content))
            {
                try self.emit(.{ .reasoning_delta = "  \n" });
            }
            if (!same_item) try self.replaceReasoningItem(item_id);
            self.reasoning_part_index = index;
            self.reasoning_part_is_content = is_content;
        }
        try self.emit(.{ .reasoning_delta = delta });
    }

    fn emitCompleted(self: *Parser, response: ?std.json.ObjectMap) Error!void {
        if (self.terminal_emitted) return;
        if (self.hasOpenToolCalls()) return error.InvalidResponse;
        if (response) |value| try self.captureResponse(value);
        self.terminal_emitted = true;
        try self.emit(.{ .done = .{
            .stop_reason = "completed",
            .usage = parseUsage(response),
            .response = self.responseIdentity(),
        } });
    }

    fn emitFailure(self: *Parser, message: []const u8, response: ?std.json.ObjectMap) Error!void {
        if (self.terminal_emitted) return;
        if (response) |value| try self.captureResponse(value);
        self.terminal_emitted = true;
        try self.emit(.{ .failure = .{
            .message = message,
            .usage = parseUsage(response),
            .response = self.responseIdentity(),
        } });
    }

    fn emit(self: *Parser, event: StreamEvent.StreamEvent) Error!void {
        switch (event) {
            .text_delta, .tool_call_start, .reasoning_item, .done, .failure => self.clearReasoningItem(),
            else => {},
        }
        self.sink.emit(event) catch return error.Cancelled;
    }

    fn captureResponse(self: *Parser, response: ?std.json.ObjectMap) Error!void {
        const object = response orelse return;
        if (self.response_id == null) if (stringField(object, "id")) |value| {
            if (value.len != 0) self.response_id = try self.own(value);
        };
        if (self.served_model == null) if (stringField(object, "model")) |value| {
            if (value.len != 0) self.served_model = try self.own(value);
        };
    }

    fn responseIdentity(self: *const Parser) StreamEvent.ResponseIdentity {
        return .{ .id = self.response_id, .model = self.served_model };
    }

    fn hasOpenToolCalls(self: *const Parser) bool {
        for (self.tool_calls.items) |call| if (!call.ended) return true;
        return false;
    }

    fn findToolCall(self: *Parser, item_id: []const u8) ?*ToolCall {
        for (self.tool_calls.items) |*call| if (std.mem.eql(u8, call.item_id, item_id)) return call;
        return null;
    }

    fn replaceReasoningItem(self: *Parser, item_id: []const u8) Error!void {
        const old_len = if (self.reasoning_item_id) |old| old.len else 0;
        const without_old = self.owned_state_bytes - old_len;
        const total = std.math.add(usize, without_old, item_id.len) catch return error.InvalidResponse;
        if (total > self.options.max_owned_state_bytes) return error.InvalidResponse;
        const replacement = self.allocator.dupe(u8, item_id) catch return error.OutOfMemory;
        if (self.reasoning_item_id) |old| self.allocator.free(old);
        self.owned_state_bytes = total;
        self.reasoning_item_id = replacement;
    }

    fn clearReasoningItem(self: *Parser) void {
        if (self.reasoning_item_id) |value| {
            self.allocator.free(value);
            self.owned_state_bytes -= value.len;
            self.reasoning_item_id = null;
        }
    }

    fn own(self: *Parser, value: []const u8) Error![]u8 {
        try self.reserveOwned(value.len);
        return self.allocator.dupe(u8, value) catch error.OutOfMemory;
    }

    fn reserveOwned(self: *Parser, count: usize) Error!void {
        const total = std.math.add(usize, self.owned_state_bytes, count) catch return error.InvalidResponse;
        if (total > self.options.max_owned_state_bytes) return error.InvalidResponse;
        self.owned_state_bytes = total;
    }
};

fn validateSseEvent(event: Transport.SseEvent, max_bytes: usize) Error!void {
    const name_len = if (event.event_name) |name| name.len else 0;
    const total = std.math.add(usize, name_len, event.data.len) catch return error.InvalidResponse;
    if (total > max_bytes) return error.InvalidResponse;
    if (event.event_name) |name| for (name) |byte| {
        if (byte == 0 or byte == '\r' or byte == '\n') return error.InvalidResponse;
    };
}

fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const value = object.get(name) orelse return null;
    return if (value == .object) value.object else null;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) error{InvalidResponse}![]const u8 {
    const value = object.get(name) orelse return error.InvalidResponse;
    if (value != .string) return error.InvalidResponse;
    return value.string;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn nonnegativeInteger(object: std.json.ObjectMap, name: []const u8) ?u64 {
    const value = integerField(object, name) orelse return null;
    return if (value >= 0) @intCast(value) else null;
}

fn parseUsage(response: ?std.json.ObjectMap) Usage.StreamUsage {
    const object = response orelse return .{};
    const usage = objectField(object, "usage") orelse return .{};
    const details = objectField(usage, "input_tokens_details");
    return .{
        .input_tokens = nonnegativeInteger(usage, "input_tokens"),
        .output_tokens = nonnegativeInteger(usage, "output_tokens"),
        .cached_tokens = if (details) |value| nonnegativeInteger(value, "cached_tokens") else null,
    };
}

const Captured = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(OwnedEvent) = .empty,

    const OwnedEvent = union(enum) {
        text: []u8,
        start: struct { id: []u8, name: []u8 },
        delta: struct { id: []u8, arguments: []u8 },
        end: []u8,
        reasoning: []u8,
        done: StreamEvent.Done,
        failure: struct { message: []u8, usage: ?Usage.StreamUsage },
    };

    fn deinit(self: *Captured) void {
        for (self.events.items) |event| switch (event) {
            .text, .end, .reasoning => |value| self.allocator.free(value),
            .start => |value| {
                self.allocator.free(value.id);
                self.allocator.free(value.name);
            },
            .delta => |value| {
                self.allocator.free(value.id);
                self.allocator.free(value.arguments);
            },
            .failure => |value| self.allocator.free(value.message),
            .done => {},
        };
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn emit(self: *Captured, event: StreamEvent.StreamEvent) Provider.DeliveryError!void {
        const owned: OwnedEvent = switch (event) {
            .text_delta => |value| .{ .text = self.allocator.dupe(u8, value) catch return error.Cancelled },
            .tool_call_start => |value| .{ .start = .{
                .id = self.allocator.dupe(u8, value.id) catch return error.Cancelled,
                .name = self.allocator.dupe(u8, value.name) catch return error.Cancelled,
            } },
            .tool_call_delta => |value| .{ .delta = .{
                .id = self.allocator.dupe(u8, value.id) catch return error.Cancelled,
                .arguments = self.allocator.dupe(u8, value.arguments_delta) catch return error.Cancelled,
            } },
            .tool_call_end => |value| .{ .end = self.allocator.dupe(u8, value) catch return error.Cancelled },
            .reasoning_item => |value| .{
                .reasoning = self.allocator.dupe(u8, value.opaque_json) catch return error.Cancelled,
            },
            .reasoning_delta => |value| .{
                .reasoning = self.allocator.dupe(u8, value orelse "") catch return error.Cancelled,
            },
            .done => |value| .{ .done = value },
            .failure => |value| .{ .failure = .{
                .message = self.allocator.dupe(u8, value.message) catch return error.Cancelled,
                .usage = value.usage,
            } },
            else => return,
        };
        self.events.append(self.allocator, owned) catch return error.Cancelled;
    }
};

fn testFeed(parser: *Parser, data: []const u8) Error!void {
    try parser.feed(.{ .data = data });
}

test "text refusal identity terminal usage and sticky completion" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testFeed(&parser, "{\"type\":\"response.created\",\"response\":{\"id\":\"first\",\"model\":\"m1\"}}");
    try testFeed(
        &parser,
        "{\"type\":\"response.refusal.delta\",\"delta\":\"I can't help\"," ++
            "\"response\":{\"id\":\"second\"}}",
    );
    try testFeed(
        &parser,
        "{\"type\":\"response.completed\",\"response\":{\"usage\":{" ++
            "\"input_tokens\":5,\"output_tokens\":2," ++
            "\"input_tokens_details\":{\"cached_tokens\":3}}}}",
    );
    try testFeed(&parser, "{\"type\":\"response.output_text.delta\",\"delta\":\"late\"}");
    try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
    try std.testing.expectEqualStrings("I can't help", capture.events.items[0].text);
    const done = capture.events.items[1].done;
    try std.testing.expectEqualStrings("first", done.response.id.?);
    try std.testing.expectEqual(@as(?u64, 5), done.usage.input_tokens);
    try std.testing.expect(parser.usage() == null);
    try std.testing.expect(!try parser.recover());
}

test "tool lifecycle maps item id, falls back, and rejects duplicate starts" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    const added = "{\"type\":\"response.output_item.added\",\"item\":{" ++
        "\"type\":\"function_call\",\"id\":\"i1\",\"call_id\":\"c1\",\"name\":\"bash\"}}";
    try testFeed(&parser, added);
    try std.testing.expectError(error.InvalidResponse, testFeed(&parser, added));
    try testFeed(&parser, "{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"i1\",\"delta\":\"\"}");
    const done = "{\"type\":\"response.output_item.done\",\"item\":{" ++
        "\"type\":\"function_call\",\"id\":\"i1\",\"arguments\":\"{}\"}}";
    try testFeed(&parser, done);
    try testFeed(&parser, done);
    try std.testing.expectEqual(@as(usize, 3), capture.events.items.len);
    try std.testing.expectEqualStrings("c1", capture.events.items[0].start.id);
    try std.testing.expectEqualStrings("{}", capture.events.items[1].delta.arguments);
    try std.testing.expectEqualStrings("c1", capture.events.items[2].end);
}

test "streamed tool arguments suppress done-item copy" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testFeed(&parser, "{\"type\":\"response.output_item.added\",\"item\":{" ++
        "\"type\":\"function_call\",\"id\":\"i\",\"call_id\":\"c\",\"name\":\"x\"}}");
    try testFeed(&parser, "{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"i\",\"delta\":\"{}\"}");
    try testFeed(&parser, "{\"type\":\"response.output_item.done\",\"item\":{" ++
        "\"type\":\"function_call\",\"id\":\"i\",\"arguments\":\"{}\"}}");
    try std.testing.expectEqual(@as(usize, 3), capture.events.items.len);
}

test "reasoning parts, seams, and canonical opaque replay" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testFeed(&parser, "{\"type\":\"response.reasoning_summary_text.delta\"," ++
        "\"item_id\":\"r1\",\"summary_index\":0,\"delta\":\"one\"}");
    try testFeed(&parser, "{\"type\":\"response.reasoning_text.delta\"," ++
        "\"item_id\":\"r1\",\"content_index\":0,\"delta\":\"two\"}");
    try testFeed(&parser, "{\"type\":\"response.output_item.done\",\"item\":{" ++
        "\"type\":\"reasoning\",\"id\":\"discard\",\"status\":\"completed\"," ++
        "\"summary\":[],\"encrypted_content\":\"abc==\",\"future\":1}}");
    try testFeed(&parser, "{\"type\":\"response.reasoning_summary_text.delta\"," ++
        "\"item_id\":\"r2\",\"summary_index\":0,\"delta\":\"three\"}");
    try std.testing.expectEqual(@as(usize, 5), capture.events.items.len);
    try std.testing.expectEqualStrings("  \n", capture.events.items[1].reasoning);
    try std.testing.expectEqualStrings(
        "{\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"abc==\"}",
        capture.events.items[3].reasoning,
    );
    try std.testing.expectEqualStrings("three", capture.events.items[4].reasoning);
}

test "incomplete failed bare error and finalize are terminal failures" {
    const cases = [_]struct { json: ?[]const u8, message: []const u8 }{
        .{
            .json = "{\"type\":\"response.incomplete\",\"response\":{" ++
                "\"incomplete_details\":{\"reason\":\"max_output_tokens\"}," ++
                "\"usage\":{\"input_tokens\":9}}}",
            .message = "response incomplete: max_output_tokens",
        },
        .{
            .json = "{\"type\":\"response.failed\",\"response\":{" ++
                "\"error\":{\"message\":\"Bad Request\"}}}",
            .message = "Bad Request",
        },
        .{ .json = "{\"type\":\"error\",\"code\":\"server_error\"}", .message = "server_error" },
        .{ .json = null, .message = "stream ended before completion" },
    };
    for (cases) |case| {
        var capture: Captured = .{ .allocator = std.testing.allocator };
        defer capture.deinit();
        var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
        defer parser.deinit();
        if (case.json) |json| try testFeed(&parser, json) else try parser.finalize();
        try parser.finalize();
        try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
        try std.testing.expectEqualStrings(case.message, capture.events.items[0].failure.message);
    }
}

test "unknown events are ignored but malformed recognized data is rejected" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testFeed(&parser, "");
    try testFeed(&parser, "{\"type\":\"future\"}");
    const malformed = [_][]const u8{
        "not json",
        "[]",
        "{}",
        "{\"type\":\"response.output_text.delta\"}",
        "{\"type\":\"response.output_item.added\",\"item\":{" ++
            "\"type\":\"function_call\",\"id\":\"i\"}}",
    };
    for (malformed) |json| {
        try std.testing.expectError(error.InvalidResponse, testFeed(&parser, json));
    }
    try std.testing.expectEqual(@as(usize, 0), capture.events.items.len);
}

test "completion rejects an open tool call" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testFeed(
        &parser,
        "{\"type\":\"response.output_item.added\",\"item\":{" ++
            "\"type\":\"function_call\",\"id\":\"item\"," ++
            "\"call_id\":\"call\",\"name\":\"bash\"}}",
    );
    try std.testing.expectError(error.InvalidResponse, testFeed(
        &parser,
        "{\"type\":\"response.completed\",\"response\":{}}",
    ));
    try std.testing.expect(!parser.isComplete());
}

test "done sentinel, state bounds, event validation, and allocation failure" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{
        .max_tracked_calls = 1,
        .max_owned_state_bytes = 4,
    });
    defer parser.deinit();
    try std.testing.expectError(error.InvalidResponse, parser.feed(.{
        .event_name = "bad\nname",
        .data = "{}",
    }));
    try std.testing.expectError(error.InvalidResponse, testFeed(
        &parser,
        "{\"type\":\"response.created\",\"response\":{\"id\":\"12345\"}}",
    ));

    var sentinel = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer sentinel.deinit();
    try testFeed(&sentinel, "[DONE]");
    try std.testing.expect(sentinel.isComplete());

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var oom_parser = try Parser.init(failing.allocator(), Provider.EventSink.from(&capture), .{});
    defer oom_parser.deinit();
    try std.testing.expectError(error.OutOfMemory, testFeed(
        &oom_parser,
        "{\"type\":\"response.output_text.delta\",\"delta\":\"x\"}",
    ));
}

test "bounds and cancellation are explicit" {
    const Reject = struct {
        const Self = @This();
        pub fn emit(_: *Self, _: StreamEvent.StreamEvent) Provider.DeliveryError!void {
            return error.Cancelled;
        }
    };
    var reject: Reject = .{};
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&reject), .{ .max_event_bytes = 8 });
    defer parser.deinit();
    try std.testing.expectError(error.InvalidResponse, testFeed(&parser, "123456789"));

    var parser2 = try Parser.init(std.testing.allocator, Provider.EventSink.from(&reject), .{});
    defer parser2.deinit();
    try std.testing.expectError(error.Cancelled, testFeed(
        &parser2,
        "{\"type\":\"response.output_text.delta\",\"delta\":\"x\"}",
    ));
}

test "tool lifecycle rejects unknown deltas missing fallback and duplicate starts" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try std.testing.expectError(error.InvalidResponse, testFeed(
        &parser,
        "{\"type\":\"response.function_call_arguments.delta\"," ++
            "\"item_id\":\"missing\",\"delta\":\"{}\"}",
    ));
    const start = "{\"type\":\"response.output_item.added\",\"item\":{" ++
        "\"type\":\"function_call\",\"id\":\"item\"," ++
        "\"call_id\":\"call\",\"name\":\"bash\"}}";
    try testFeed(&parser, start);
    try std.testing.expectError(error.InvalidResponse, testFeed(&parser, start));
    try std.testing.expectError(error.InvalidResponse, testFeed(
        &parser,
        "{\"type\":\"response.output_item.done\",\"item\":{" ++
            "\"type\":\"function_call\",\"id\":\"item\"}}",
    ));
    try std.testing.expect(!parser.isComplete());
}
