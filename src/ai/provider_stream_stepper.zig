const std = @import("std");
const runtime = @import("../runtime/root.zig");
const protocol = @import("protocol.zig");
const provider_registry = @import("provider_registry.zig");
const stream_api = @import("stream.zig");
const faux = @import("providers/faux.zig");

pub const Completion = union(enum) {
    event: struct {
        id: runtime.OperationId,
        event: protocol.AssistantMessageEvent,
    },
    done: struct {
        id: runtime.OperationId,
        message: protocol.AssistantMessage,
    },
    failed: struct {
        id: runtime.OperationId,
        message: protocol.AssistantMessage,
    },
    canceled: struct {
        id: runtime.OperationId,
        message: protocol.AssistantMessage,
    },
};

pub const CompletionQueue = runtime.CompletionQueue(Completion, completionIsTerminal);

fn completionIsTerminal(completion: Completion) bool {
    return switch (completion) {
        .done, .failed, .canceled => true,
        .event => false,
    };
}

pub const Operation = struct {
    id: runtime.OperationId,
    request: protocol.StreamRequest,
    stream: protocol.AssistantMessageEventStream,
    state: runtime.OperationState = .running,
    cancel_token: ?runtime.CancelToken = null,
    latest_partial: ?protocol.AssistantMessage = null,

    pub fn start(
        id: runtime.OperationId,
        registry: *const provider_registry.ProviderRegistry,
        request: protocol.StreamRequest,
        cancel_token: ?runtime.CancelToken,
    ) stream_api.StreamError!Operation {
        return .{
            .id = id,
            .request = request,
            .stream = try stream_api.stream(registry, request),
            .cancel_token = cancel_token,
        };
    }

    pub fn step(self: *Operation, queue: *CompletionQueue) !bool {
        switch (self.state) {
            .completed, .failed, .canceled => return false,
            .queued => unreachable,
            .running, .cancel_requested => {},
        }

        if (self.cancel_token) |token| {
            if (token.isRequested()) {
                self.state = .cancel_requested;
                const message = self.abortedMessage();
                try queue.push(.{ .canceled = .{ .id = self.id, .message = message } });
                self.state = .canceled;
                return false;
            }
        }

        const next = try self.stream.next(self.request.io) orelse return self.completeFromResult(queue);
        self.rememberPartial(next);
        try queue.push(.{ .event = .{ .id = self.id, .event = next } });
        return true;
    }

    fn completeFromResult(self: *Operation, queue: *CompletionQueue) !bool {
        const message = self.stream.result() orelse return error.MissingResult;
        switch (message.stop_reason) {
            .error_ => {
                try queue.push(.{ .failed = .{ .id = self.id, .message = message } });
                self.state = .failed;
            },
            .aborted => {
                try queue.push(.{ .canceled = .{ .id = self.id, .message = message } });
                self.state = .canceled;
            },
            .stop, .length, .tool_use => {
                try queue.push(.{ .done = .{ .id = self.id, .message = message } });
                self.state = .completed;
            },
        }
        return false;
    }

    fn rememberPartial(self: *Operation, event: protocol.AssistantMessageEvent) void {
        self.latest_partial = switch (event) {
            .start => |payload| payload.partial,
            .text_start => |payload| payload.partial,
            .text_delta => |payload| payload.partial,
            .text_end => |payload| payload.partial,
            .thinking_start => |payload| payload.partial,
            .thinking_delta => |payload| payload.partial,
            .thinking_end => |payload| payload.partial,
            .toolcall_start => |payload| payload.partial,
            .toolcall_delta => |payload| payload.partial,
            .toolcall_end => |payload| payload.partial,
            .done => |payload| payload.message,
            .@"error" => |payload| payload.@"error",
        };
    }

    fn abortedMessage(self: *const Operation) protocol.AssistantMessage {
        var message = self.latest_partial orelse protocol.emptyAssistantMessageFromRequest(
            self.request,
            .aborted,
            "Request was aborted",
        );
        message.stop_reason = .aborted;
        message.error_message = "Request was aborted";
        return message;
    }
};

test "provider stream stepper forwards provider events as operation completions" {
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var provider = try faux.Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.register(&registry);
    try provider.setResponses(&.{faux.assistantMessage(&.{faux.text("ok")}, .{})});
    var completion_buffer: [8]Completion = undefined;
    var queue = CompletionQueue.init(&completion_buffer);
    var table: runtime.OperationIds = .{};
    var op = try Operation.start(table.reserve(), &registry, testRequest(provider.getModel()), null);

    while (try op.step(&queue)) {}

    var event_count: usize = 0;
    var done_count: usize = 0;
    while (queue.pop()) |completion| switch (completion) {
        .event => event_count += 1,
        .done => |done| {
            done_count += 1;
            try std.testing.expectEqual(protocol.StopReason.stop, done.message.stop_reason);
        },
        .failed, .canceled => return error.UnexpectedTerminal,
    };
    try std.testing.expect(event_count > 0);
    try std.testing.expectEqual(@as(usize, 1), done_count);
}

test "provider stream stepper cancellation before first event emits only aborted terminal" {
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var provider = try faux.Provider.init(std.testing.allocator, .{ .min_token_size = 1, .max_token_size = 1 });
    defer provider.deinit();
    try provider.register(&registry);
    try provider.setResponses(&.{faux.assistantMessage(&.{faux.text("abcdefghijklmnopqrstuvwxyz")}, .{})});
    var completion_buffer: [4]Completion = undefined;
    var queue = CompletionQueue.init(&completion_buffer);
    var source: runtime.CancelSource = .{};
    var table: runtime.OperationIds = .{};
    var op = try Operation.start(
        table.reserve(),
        &registry,
        testRequest(provider.getModel()),
        source.token(),
    );

    source.requestWithWake(std.Io.failing);
    try std.testing.expect(!try op.step(&queue));

    const completion = queue.pop().?.canceled;
    try std.testing.expectEqual(protocol.StopReason.aborted, completion.message.stop_reason);
    try std.testing.expectEqualStrings("Request was aborted", completion.message.error_message.?);
    try std.testing.expect(queue.pop() == null);
}

test "provider stream stepper cancellation after text delta omits text end and emits aborted terminal" {
    try expectCancelAfterDelta(
        &.{faux.text("abcdefghijklmnopqrstuvwxyz")},
        .text_delta,
        .text_end,
    );
}

test "provider stream stepper cancellation after thinking delta omits thinking end and emits aborted terminal" {
    try expectCancelAfterDelta(
        &.{faux.thinking("abcdefghijklmnopqrstuvwxyz")},
        .thinking_delta,
        .thinking_end,
    );
}

test "provider stream stepper cancellation after toolcall delta omits toolcall end and emits aborted terminal" {
    var arguments = try jsonObjectWithString(std.testing.allocator, "text", "abcdefghijklmnopqrstuvwxyz");
    defer arguments.deinit(std.testing.allocator);
    try expectCancelAfterDelta(
        &.{faux.toolCall("tool-1", "echo", .{ .object = arguments })},
        .toolcall_delta,
        .toolcall_end,
    );
}

fn expectCancelAfterDelta(
    content: []const protocol.AssistantContent,
    cancel_after: std.meta.Tag(protocol.AssistantMessageEvent),
    forbidden_after_cancel: std.meta.Tag(protocol.AssistantMessageEvent),
) !void {
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var provider = try faux.Provider.init(std.testing.allocator, .{ .min_token_size = 1, .max_token_size = 1 });
    defer provider.deinit();
    try provider.register(&registry);
    try provider.setResponses(&.{faux.assistantMessage(content, .{ .stop_reason = .tool_use })});
    var completion_buffer: [32]Completion = undefined;
    var queue = CompletionQueue.init(&completion_buffer);
    var source: runtime.CancelSource = .{};
    var table: runtime.OperationIds = .{};
    var op = try Operation.start(
        table.reserve(),
        &registry,
        testRequest(provider.getModel()),
        source.token(),
    );
    var target_delta_count: usize = 0;
    var saw_forbidden_after_cancel = false;
    var canceled_count: usize = 0;

    while (try op.step(&queue)) {
        const completion = queue.pop().?;
        if (completion != .event) return error.UnexpectedTerminal;
        const tag = std.meta.activeTag(completion.event.event);
        if (source.token().isRequested() and tag == forbidden_after_cancel) saw_forbidden_after_cancel = true;
        if (tag == cancel_after) {
            target_delta_count += 1;
            source.requestWithWake(std.Io.failing);
        }
    }

    while (queue.pop()) |completion| switch (completion) {
        .canceled => |canceled| {
            canceled_count += 1;
            try std.testing.expectEqual(protocol.StopReason.aborted, canceled.message.stop_reason);
            try std.testing.expectEqualStrings("Request was aborted", canceled.message.error_message.?);
        },
        .event => |event| {
            if (std.meta.activeTag(event.event) == forbidden_after_cancel) saw_forbidden_after_cancel = true;
        },
        .done, .failed => return error.UnexpectedTerminal,
    };

    try std.testing.expectEqual(@as(usize, 1), target_delta_count);
    try std.testing.expectEqual(@as(usize, 1), canceled_count);
    try std.testing.expect(!saw_forbidden_after_cancel);
    try std.testing.expectEqual(runtime.OperationState.canceled, op.state);
}

fn jsonObjectWithString(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) !std.json.ObjectMap {
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(allocator);
    try object.put(allocator, key, .{ .string = value });
    return object;
}

fn testRequest(model: protocol.Model) protocol.StreamRequest {
    return .{
        .allocator = std.testing.allocator,
        .io = std.Io.failing,
        .model = model,
        .context = .{ .messages = &.{.{ .user = .{ .content = .{ .string = "hello" }, .timestamp = 0 } }} },
    };
}
