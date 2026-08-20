const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const session_event = @import("AgentSessionEvent.zig");
const session_format = @import("SessionFormat.zig");

const OwnedAgentSessionEvent = @This();

pub const default_max_retained_bytes = session_format.max_journal_bytes;
pub const default_max_items = session_format.max_entries;

pub const Limits = struct {
    max_retained_bytes: usize = default_max_retained_bytes,
    max_items: usize = default_max_items,
};

pub const Error = error{
    OutOfMemory,
    EventTooLarge,
    TooManyItems,
};

arena: std.heap.ArenaAllocator,
value: session_event.Event,
retained_bytes: usize,
item_count: usize,

pub fn init(
    allocator: std.mem.Allocator,
    source: session_event.Event,
    limits: Limits,
) Error!OwnedAgentSessionEvent {
    var budget: Budget = .{ .limits = limits };
    try budget.addEvent(source);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const value = try copyEventLeaky(arena.allocator(), source);
    return .{
        .arena = arena,
        .value = value,
        .retained_bytes = budget.bytes,
        .item_count = budget.items,
    };
}

pub fn deinit(self: *OwnedAgentSessionEvent) void {
    self.arena.deinit();
    self.* = undefined;
}

fn copyEventLeaky(
    allocator: std.mem.Allocator,
    source: session_event.Event,
) error{OutOfMemory}!session_event.Event {
    return switch (source) {
        .agent_start => |value| .{ .agent_start = value },
        .agent_end => |value| .{ .agent_end = .{
            .run_id = value.run_id,
            .outcome = value.outcome,
            .messages = try copyMessagesLeaky(allocator, value.messages),
        } },
        .turn_start => |value| .{ .turn_start = value },
        .turn_end => |value| .{ .turn_end = .{
            .run_id = value.run_id,
            .index = value.index,
            .response = try copyResponseEndLeaky(allocator, value.response),
            .tool_results = try copyToolResultsLeaky(allocator, value.tool_results),
        } },
        .message_start => |value| .{ .message_start = .{
            .run_id = value.run_id,
            .turn_index = value.turn_index,
            .message = switch (value.message) {
                .request => |request| .{ .request = try ai.message.copyRequestLeaky(allocator, request) },
                .response => |response| .{ .response = try ai.stream.copySnapshotLeaky(allocator, response) },
            },
        } },
        .message_update => |value| .{ .message_update = .{
            .run_id = value.run_id,
            .turn_index = value.turn_index,
            .message = try ai.stream.copySnapshotLeaky(allocator, value.message),
            .update = try ai.stream.copyEventLeaky(allocator, value.update),
        } },
        .message_end => |value| .{ .message_end = .{
            .run_id = value.run_id,
            .turn_index = value.turn_index,
            .message = try copyMessageEndLeaky(allocator, value.message),
        } },
        .tool_execution_start => |value| .{ .tool_execution_start = .{
            .run_id = value.run_id,
            .turn_index = value.turn_index,
            .call_id = try allocator.dupe(u8, value.call_id),
            .name = try allocator.dupe(u8, value.name),
            .arguments_json = try allocator.dupe(u8, value.arguments_json),
        } },
        .tool_execution_end => |value| .{ .tool_execution_end = .{
            .run_id = value.run_id,
            .turn_index = value.turn_index,
            .call_id = try allocator.dupe(u8, value.call_id),
            .name = try allocator.dupe(u8, value.name),
            .result = switch (value.result) {
                .published => |result| .{ .published = try ai.message.copyToolResultLeaky(allocator, result) },
                .discarded => |outcome| .{ .discarded = outcome },
            },
        } },
        .agent_settled => |value| .{ .agent_settled = value },
    };
}

fn copyMessagesLeaky(
    allocator: std.mem.Allocator,
    source: []const ai.message.Message,
) error{OutOfMemory}![]const ai.message.Message {
    const result = try allocator.alloc(ai.message.Message, source.len);
    for (source, result) |message, *copy| copy.* = try ai.message.copyLeaky(allocator, message);
    return result;
}

fn copyToolResultsLeaky(
    allocator: std.mem.Allocator,
    source: []const ai.message.ToolResult,
) error{OutOfMemory}![]const ai.message.ToolResult {
    const result = try allocator.alloc(ai.message.ToolResult, source.len);
    for (source, result) |value, *copy| copy.* = try ai.message.copyToolResultLeaky(allocator, value);
    return result;
}

fn copyResponseEndLeaky(
    allocator: std.mem.Allocator,
    source: agent.event.ResponseEnd,
) error{OutOfMemory}!agent.event.ResponseEnd {
    return switch (source) {
        .published => |response| .{ .published = try ai.message.copyResponseLeaky(allocator, response) },
        .discarded => |discarded| .{ .discarded = try copyDiscardedLeaky(allocator, discarded) },
    };
}

fn copyMessageEndLeaky(
    allocator: std.mem.Allocator,
    source: agent.event.MessageEnd,
) error{OutOfMemory}!agent.event.MessageEnd {
    return switch (source) {
        .published => |message| .{ .published = try ai.message.copyLeaky(allocator, message) },
        .discarded_response => |discarded| .{
            .discarded_response = try copyDiscardedLeaky(allocator, discarded),
        },
    };
}

fn copyDiscardedLeaky(
    allocator: std.mem.Allocator,
    source: agent.event.DiscardedResponse,
) error{OutOfMemory}!agent.event.DiscardedResponse {
    return .{
        .response = try ai.stream.copySnapshotLeaky(allocator, source.response),
        .outcome = source.outcome,
    };
}

const Budget = struct {
    limits: Limits,
    bytes: usize = 0,
    items: usize = 0,

    fn addEvent(self: *Budget, event: session_event.Event) Error!void {
        switch (event) {
            .agent_start, .turn_start, .agent_settled => {},
            .agent_end => |value| try self.addMessages(value.messages),
            .turn_end => |value| {
                try self.addResponseEnd(value.response);
                try self.addItems(value.tool_results.len);
                for (value.tool_results) |result| try self.addToolResult(result);
            },
            .message_start => |value| switch (value.message) {
                .request => |request| try self.addRequest(request),
                .response => |response| try self.addSnapshot(response),
            },
            .message_update => |value| {
                try self.addSnapshot(value.message);
                try self.addStreamEvent(value.update);
            },
            .message_end => |value| switch (value.message) {
                .published => |message| try self.addMessage(message),
                .discarded_response => |discarded| try self.addSnapshot(discarded.response),
            },
            .tool_execution_start => |value| {
                try self.addBytes(value.call_id.len);
                try self.addBytes(value.name.len);
                try self.addBytes(value.arguments_json.len);
            },
            .tool_execution_end => |value| {
                try self.addBytes(value.call_id.len);
                try self.addBytes(value.name.len);
                switch (value.result) {
                    .published => |result| try self.addToolResult(result),
                    .discarded => {},
                }
            },
        }
    }

    fn addMessages(self: *Budget, messages: []const ai.message.Message) Error!void {
        try self.addItems(messages.len);
        for (messages) |message| try self.addMessage(message);
    }

    fn addMessage(self: *Budget, value: ai.message.Message) Error!void {
        switch (value) {
            .request => |request| try self.addRequest(request),
            .response => |response| try self.addResponse(response),
        }
    }

    fn addRequest(self: *Budget, value: ai.message.RequestMessage) Error!void {
        try self.addItems(value.parts.len);
        for (value.parts) |part| switch (part) {
            .user => |user| switch (user) {
                .text => |text| try self.addBytes(text.len),
                .image => |image| try self.addImage(image),
            },
            .tool_result => |result| try self.addToolResult(result),
            .retry_prompt => |text| try self.addBytes(text.len),
        };
    }

    fn addResponse(self: *Budget, value: ai.message.ResponseMessage) Error!void {
        try self.addBytes(value.identity.provider.len);
        try self.addBytes(value.identity.model.len);
        if (value.finish.raw_reason) |reason| try self.addBytes(reason.len);
        try self.addItems(value.parts.len);
        for (value.parts) |part| try self.addResponsePart(part);
    }

    fn addResponsePart(self: *Budget, part: ai.message.ResponsePart) Error!void {
        switch (part) {
            .text => |text| {
                try self.addBytes(text.text.len);
                if (text.provider_state) |state| try self.addProviderState(state);
            },
            .thinking => |thinking| {
                try self.addBytes(thinking.text.len);
                if (thinking.provider_state) |state| try self.addProviderState(state);
            },
            .tool_call => |call| {
                try self.addBytes(call.id.len);
                try self.addBytes(call.name.len);
                try self.addBytes(call.arguments_json.len);
                if (call.provider_state) |state| try self.addProviderState(state);
            },
        }
    }

    fn addToolResult(self: *Budget, result: ai.message.ToolResult) Error!void {
        try self.addBytes(result.call_id.len);
        try self.addBytes(result.name.len);
        try self.addItems(result.content.len);
        for (result.content) |content| switch (content) {
            .text => |text| try self.addBytes(text.len),
            .image => |image| try self.addImage(image),
        };
    }

    fn addImage(self: *Budget, image: ai.message.Image) Error!void {
        try self.addBytes(image.media_type.len);
        try self.addBytes(switch (image.source) {
            .bytes => |bytes| bytes.len,
            .url => |url| url.len,
        });
    }

    fn addProviderState(self: *Budget, state: ai.message.ProviderState) Error!void {
        try self.addBytes(state.provider.len);
        try self.addBytes(state.protocol.len);
        try self.addJson(state.value);
    }

    fn addJson(self: *Budget, value: std.json.Value) Error!void {
        try self.addItems(1);
        switch (value) {
            .null, .bool, .integer, .float => {},
            .number_string => |text| try self.addBytes(text.len),
            .string => |text| try self.addBytes(text.len),
            .array => |array| for (array.items) |item| try self.addJson(item),
            .object => |object| {
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    try self.addBytes(entry.key_ptr.*.len);
                    try self.addJson(entry.value_ptr.*);
                }
            },
        }
    }

    fn addSnapshot(self: *Budget, value: ai.stream.ResponseSnapshot) Error!void {
        try self.addBytes(value.identity.provider.len);
        try self.addBytes(value.identity.model.len);
        try self.addItems(value.parts.len);
        for (value.parts) |part| switch (part) {
            .text => |text| try self.addBytes(text.len),
            .thinking => |thinking| try self.addBytes(thinking.len),
            .tool_call => |call| {
                if (call.id) |id| try self.addBytes(id.len);
                if (call.name) |name| try self.addBytes(name.len);
                try self.addBytes(call.arguments_json.len);
            },
        };
    }

    fn addStreamEvent(self: *Budget, value: ai.stream.StreamEvent) Error!void {
        switch (value) {
            .part_start => |start| switch (start.part) {
                .text, .thinking => {},
                .tool_call => |call| {
                    if (call.id) |id| try self.addBytes(id.len);
                    if (call.name) |name| try self.addBytes(name.len);
                },
            },
            .part_delta => |delta| switch (delta.delta) {
                .text => |text| try self.addBytes(text.len),
                .thinking => |thinking| try self.addBytes(thinking.len),
                .tool_call => |call| {
                    if (call.id) |id| try self.addBytes(id.len);
                    if (call.name) |name| try self.addBytes(name.len);
                    try self.addBytes(call.arguments_delta.len);
                },
            },
            .part_end => |end| try self.addResponsePart(end.part),
            .usage => {},
        }
    }

    fn addResponseEnd(self: *Budget, value: agent.event.ResponseEnd) Error!void {
        switch (value) {
            .published => |response| try self.addResponse(response),
            .discarded => |discarded| try self.addSnapshot(discarded.response),
        }
    }

    fn addBytes(self: *Budget, count: usize) Error!void {
        self.bytes = std.math.add(usize, self.bytes, count) catch return error.EventTooLarge;
        if (self.bytes > self.limits.max_retained_bytes) return error.EventTooLarge;
    }

    fn addItems(self: *Budget, count: usize) Error!void {
        self.items = std.math.add(usize, self.items, count) catch return error.TooManyItems;
        if (self.items > self.limits.max_items) return error.TooManyItems;
    }
};

test "owned event retains stream bytes after sources are mutated" {
    var text = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    var owned = try OwnedAgentSessionEvent.init(std.testing.allocator, .{ .message_update = .{
        .run_id = @enumFromInt(9),
        .turn_index = 2,
        .message = .{
            .parts = &.{.{ .text = &text }},
            .identity = .{ .provider = "script", .model = "owned" },
        },
        .update = .{ .part_delta = .{ .index = 0, .delta = .{ .text = &text } } },
    } }, .{});
    defer owned.deinit();
    @memset(&text, 'x');

    try std.testing.expectEqualStrings("hello", owned.value.message_update.message.parts[0].text);
    try std.testing.expectEqualStrings("hello", owned.value.message_update.update.part_delta.delta.text);
    try std.testing.expectEqual(@as(u64, 9), @intFromEnum(owned.value.message_update.run_id));
}

test "owned event rejects byte and item bounds before allocation" {
    try std.testing.expectError(error.EventTooLarge, OwnedAgentSessionEvent.init(
        std.testing.allocator,
        .{ .tool_execution_start = .{
            .run_id = @enumFromInt(1),
            .turn_index = 1,
            .call_id = "call",
            .name = "read",
            .arguments_json = "{}",
        } },
        .{ .max_retained_bytes = 5 },
    ));
    try std.testing.expectError(error.TooManyItems, OwnedAgentSessionEvent.init(
        std.testing.allocator,
        .{ .agent_end = .{
            .run_id = @enumFromInt(1),
            .outcome = .completed,
            .messages = &.{.{ .request = .{ .parts = &.{} } }},
        } },
        .{ .max_items = 0 },
    ));
}

fn copyForAllocationFailure(allocator: std.mem.Allocator) !void {
    var update = try OwnedAgentSessionEvent.init(allocator, .{ .message_update = .{
        .run_id = @enumFromInt(3),
        .turn_index = 4,
        .message = .{
            .parts = &.{.{ .tool_call = .{
                .id = "call",
                .name = "read",
                .arguments_json = "{}",
            } }},
            .identity = .{ .provider = "script", .model = "allocation" },
        },
        .update = .{ .part_end = .{
            .index = 0,
            .part = .{ .text = .{
                .text = "contents",
                .provider_state = .{
                    .provider = "script",
                    .protocol = "test",
                    .value = .{ .string = "opaque" },
                },
            } },
        } },
    } }, .{});
    update.deinit();

    var tool = try OwnedAgentSessionEvent.init(allocator, .{ .tool_execution_end = .{
        .run_id = @enumFromInt(3),
        .turn_index = 4,
        .call_id = "call",
        .name = "read",
        .result = .{ .published = .{
            .call_id = "call",
            .name = "read",
            .content = &.{.{ .text = "contents" }},
            .outcome = .success,
        } },
    } }, .{});
    tool.deinit();
}

test "owned event settles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        copyForAllocationFailure,
        .{},
    );
}
