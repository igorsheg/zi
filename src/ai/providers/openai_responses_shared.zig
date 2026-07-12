const std = @import("std");
const models_api = @import("../models.zig");
const mem = @import("../../runtime/root.zig");
const protocol = @import("../protocol.zig");
const sse = @import("../sse.zig");
const json_parse = @import("../utils/json_parse.zig");

pub const ProcessError = error{
    InvalidJson,
    ProviderError,
    OutOfMemory,
};

const max_stream_text_block_bytes = 4 * 1024 * 1024;
const max_stream_thinking_block_bytes = 4 * 1024 * 1024;
const max_stream_tool_arguments_bytes = 1024 * 1024;
const max_stream_signature_bytes = 1024 * 1024;
const max_stream_content_blocks = 256;

pub fn outOfMemoryStream() protocol.AssistantMessageEventStream {
    return protocol.AssistantMessageEventStream.initCustom(.{
        .context = null,
        .next_fn = outOfMemoryNext,
        .result_fn = emptyResult,
    });
}

fn outOfMemoryNext(_: ?*anyopaque, _: std.Io) anyerror!?protocol.AssistantMessageEvent {
    return error.OutOfMemory;
}

fn emptyResult(_: ?*anyopaque) ?protocol.AssistantMessage {
    return null;
}

pub fn errorStream(request: protocol.StreamRequest, err: anyerror) protocol.AssistantMessageEventStream {
    var stream = protocol.AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();
    if (err == error.OperationCancelled or err == error.Canceled) {
        var message = protocol.emptyAssistantMessageFromRequest(request, .aborted, "Request was aborted");
        message.operational_failure = classifyOpenError(request, err);
        sink.endAborted(request.io, message) catch unreachable;
    } else {
        var message = protocol.emptyAssistantMessageFromRequest(request, .error_, @errorName(err));
        message.operational_failure = classifyOpenError(request, err);
        sink.endError(request.io, .error_, message) catch unreachable;
    }
    return stream;
}

pub fn httpFailure(request: protocol.StreamRequest, status: std.http.Status, detail: []const u8) protocol.OperationalFailure {
    return .{
        .category = switch (status) {
            .unauthorized, .forbidden => .auth_rejected,
            .too_many_requests => .rate_limited,
            .bad_request, .request_header_fields_too_large => if (containsContextOverflow(detail)) .context_overflow else .unknown,
            .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => .provider_unavailable,
            else => .unknown,
        },
        .message = switch (status) {
            .unauthorized, .forbidden => "Provider rejected credentials",
            .too_many_requests => "Provider rate limit exceeded",
            .bad_request, .request_header_fields_too_large => if (containsContextOverflow(detail)) "Request exceeds model context window" else "Provider request failed",
            .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => "Provider service failed",
            else => "Provider request failed",
        },
        .detail = detail,
        .retryable = switch (status) {
            .too_many_requests, .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => .yes,
            .unauthorized, .forbidden => .no,
            else => .unknown,
        },
        .provider = request.model.provider,
        .model = request.model.id,
    };
}

fn containsContextOverflow(text: []const u8) bool {
    return protocol.isContextOverflowText(text);
}

fn classifyOpenError(request: protocol.StreamRequest, err: anyerror) protocol.OperationalFailure {
    if (err == error.OperationCancelled or err == error.Canceled) return .{
        .category = .canceled,
        .message = "Request was aborted",
        .retryable = .no,
        .provider = request.model.provider,
        .model = request.model.id,
    };
    if (err == error.MissingApiKey) return .{
        .category = .auth_missing,
        .message = "Missing provider API key",
        .detail = @errorName(err),
        .retryable = .no,
        .provider = request.model.provider,
        .model = request.model.id,
    };
    if (isMalformedResponseError(err)) return .{
        .category = .malformed_response,
        .message = @errorName(err),
        .retryable = .no,
        .provider = request.model.provider,
        .model = request.model.id,
    };
    if (isTransportError(err)) return .{
        .category = .transport,
        .message = @errorName(err),
        .retryable = .yes,
        .provider = request.model.provider,
        .model = request.model.id,
    };
    return .{
        .category = .unknown,
        .message = @errorName(err),
        .retryable = .unknown,
        .provider = request.model.provider,
        .model = request.model.id,
    };
}

fn classifyStreamError(request: protocol.StreamRequest, err: anyerror) protocol.OperationalFailure {
    if (isMalformedResponseError(err)) return .{
        .category = .malformed_response,
        .message = @errorName(err),
        .retryable = .no,
        .provider = request.model.provider,
        .model = request.model.id,
    };
    if (isTransportError(err)) return .{
        .category = .transport,
        .message = @errorName(err),
        .retryable = .yes,
        .provider = request.model.provider,
        .model = request.model.id,
    };
    return .{
        .category = .unknown,
        .message = @errorName(err),
        .retryable = .unknown,
        .provider = request.model.provider,
        .model = request.model.id,
    };
}

fn isMalformedResponseError(err: anyerror) bool {
    return err == error.InvalidJson or
        err == error.SyntaxError or
        err == error.UnexpectedToken or
        err == error.UnexpectedEndOfInput or
        err == error.InvalidCharacter or
        err == error.InvalidNumber or
        err == error.InvalidEnumTag or
        err == error.InvalidType or
        err == error.MissingField or
        err == error.UnknownField;
}

fn isTransportError(err: anyerror) bool {
    const name = @errorName(err);
    return containsErrorWord(name, "Connection") or
        containsErrorWord(name, "Connect") or
        containsErrorWord(name, "Socket") or
        containsErrorWord(name, "Tls") or
        containsErrorWord(name, "TLS") or
        containsErrorWord(name, "Dns") or
        containsErrorWord(name, "DNS") or
        containsErrorWord(name, "Http") or
        containsErrorWord(name, "HTTP") or
        containsErrorWord(name, "Timeout") or
        containsErrorWord(name, "TimedOut") or
        containsErrorWord(name, "BrokenPipe") or
        containsErrorWord(name, "Reset") or
        containsErrorWord(name, "EndOfStream") or
        err == error.NetworkUnreachable or
        err == error.ConnectionRefused or
        err == error.ConnectionResetByPeer or
        err == error.ConnectionTimedOut or
        err == error.TemporaryNameServerFailure or
        err == error.UnknownHostName;
}

fn containsErrorWord(name: []const u8, word: []const u8) bool {
    return std.mem.indexOf(u8, name, word) != null;
}

pub const PullStreamOptions = struct {
    read_buffer_len: usize,
    redirect_buffer_len: usize,
};

pub fn SsePullStream(comptime Owner: type, comptime options: PullStreamOptions) type {
    return struct {
        const Self = @This();

        owner: Owner,
        allocator: std.mem.Allocator,
        request: protocol.StreamRequest,
        client: std.http.Client,
        req: std.http.Client.Request = undefined,
        response: std.http.Client.Response = undefined,
        redirects: [options.redirect_buffer_len]u8 = .{},
        transfer_buffer: [options.read_buffer_len]u8 = undefined,
        chunk: [options.read_buffer_len]u8 = undefined,
        reader: ?*std.Io.Reader = null,
        parser: sse.Parser,
        reducer: ResponseStreamReducer,
        pending: std.ArrayList(protocol.AssistantMessageEvent) = .empty,
        pending_index: usize = 0,
        result: ?protocol.AssistantMessage = null,
        owned_error_detail: ?[]const u8 = null,
        started: bool = false,
        done: bool = false,
        has_request: bool = false,

        pub fn init(allocator: std.mem.Allocator, request: protocol.StreamRequest, owner: Owner) Self {
            return .{
                .owner = owner,
                .allocator = allocator,
                .request = request,
                .client = .{ .allocator = allocator, .io = request.io },
                .parser = sse.Parser.init(allocator, .{}),
                .reducer = ResponseStreamReducer.init(allocator, request.model, 0),
            };
        }

        pub fn stream(self: *Self) protocol.AssistantMessageEventStream {
            return protocol.AssistantMessageEventStream.initCustom(.{
                .context = self,
                .next_fn = nextFn,
                .result_fn = resultFn,
                .deinit_fn = deinitFn,
            });
        }

        pub fn openRequest(
            self: *Self,
            uri: std.Uri,
            headers: []const std.http.Header,
            body: []const u8,
        ) !void {
            if (self.has_request) {
                self.req.deinit();
                self.has_request = false;
                self.reader = null;
            }

            self.req = try self.client.request(.POST, uri, .{
                .extra_headers = headers,
                .headers = .{ .content_type = .{ .override = "application/json" }, .accept_encoding = .omit },
                .redirect_behavior = .unhandled,
                .keep_alive = false,
            });
            self.has_request = true;
            self.req.transfer_encoding = .{ .content_length = body.len };
            var body_writer = try self.req.sendBodyUnflushed(&.{});
            try body_writer.writer.writeAll(body);
            try body_writer.end();
            try self.req.connection.?.flush();

            self.response = try self.req.receiveHead(&self.redirects);
            self.reader = self.response.reader(&self.transfer_buffer);
        }

        pub fn emitError(self: *Self, detail: []const u8, owns_detail: bool, failure: protocol.OperationalFailure) !void {
            var message = protocol.emptyAssistantMessageFromRequest(self.request, .error_, detail);
            message.stop_reason = .error_;
            message.operational_failure = failure;
            if (owns_detail) self.owned_error_detail = detail;
            try self.pending.append(self.allocator, .{ .@"error" = .{ .reason = .error_, .@"error" = message } });
            self.result = message;
            self.done = true;
        }

        pub fn deinit(self: *Self) void {
            if (self.has_request) self.req.deinit();
            if (self.owned_error_detail) |detail| self.allocator.free(detail);
            self.pending.deinit(self.allocator);
            self.reducer.deinit();
            self.parser.deinit();
            self.client.deinit();
            self.owner.deinit(self.allocator);
            const allocator = self.allocator;
            self.* = undefined;
            allocator.destroy(self);
        }

        fn nextFn(context: ?*anyopaque, io: std.Io) anyerror!?protocol.AssistantMessageEvent {
            const self: *Self = @ptrCast(@alignCast(context.?));
            return self.next(io);
        }

        fn resultFn(context: ?*anyopaque) ?protocol.AssistantMessage {
            const self: *Self = @ptrCast(@alignCast(context.?));
            return self.result;
        }

        fn deinitFn(context: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.deinit();
        }

        fn next(self: *Self, io: std.Io) !?protocol.AssistantMessageEvent {
            _ = io;
            if (self.popPending()) |event| return event;
            if (!self.started and !self.done) {
                self.started = true;
                try self.pending.append(self.allocator, .{ .start = .{ .partial = try self.reducer.partial() } });
                return self.popPending();
            }
            while (!self.done) {
                var writer: std.Io.Writer = .fixed(&self.chunk);
                const n = self.reader.?.stream(&writer, .limited(self.chunk.len)) catch |err| switch (err) {
                    error.EndOfStream => {
                        self.finish() catch |finish_err| switch (finish_err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.ErrorEmitted => {
                                self.done = true;
                                return self.popPending();
                            },
                            else => return self.completeOperationalError(finish_err),
                        };
                        return self.popPending();
                    },
                    else => return self.completeOperationalError(err),
                };
                if (n == 0) continue;
                var sink = self.reducerSink();
                self.parser.feed(self.chunk[0..n], &sink) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ErrorEmitted => {
                        self.done = true;
                        return self.popPending();
                    },
                    else => return self.completeOperationalError(err),
                };
                if (self.popPending()) |event| return event;
            }
            return self.popPending();
        }

        fn finish(self: *Self) !void {
            var sink = self.reducerSink();
            try self.parser.finish(&sink);
            try self.reducer.finish(self.request.io, sink.assistant_sink);
            self.done = true;
        }

        fn completeOperationalError(self: *Self, err: anyerror) !?protocol.AssistantMessageEvent {
            if (self.done) return self.popPending();
            try self.emitError(@errorName(err), false, classifyStreamError(self.request, err));
            return self.popPending();
        }

        fn reducerSink(self: *Self) ReducerSseSink {
            return .{
                .io = self.request.io,
                .assistant_sink = .{ .allocator = self.allocator, .events = &self.pending, .result = &self.result },
                .reducer = &self.reducer,
            };
        }

        fn popPending(self: *Self) ?protocol.AssistantMessageEvent {
            if (self.pending_index >= self.pending.items.len) {
                self.pending.clearRetainingCapacity();
                self.pending_index = 0;
                return null;
            }
            const event = self.pending.items[self.pending_index];
            self.pending_index += 1;
            return event;
        }
    };
}

const ReducerSseSink = struct {
    io: std.Io,
    assistant_sink: PendingEventSink,
    reducer: *ResponseStreamReducer,

    pub fn emit(self: *ReducerSseSink, event: sse.Event) !void {
        try self.reducer.applySseData(self.io, self.assistant_sink, event.data);
    }
};

pub const PendingEventSink = struct {
    allocator: std.mem.Allocator,
    events: *std.ArrayList(protocol.AssistantMessageEvent),
    result: *?protocol.AssistantMessage,

    pub fn emit(self: PendingEventSink, _: std.Io, event: protocol.AssistantMessageEvent) !void {
        try self.events.append(self.allocator, event);
    }

    pub fn endDone(
        self: PendingEventSink,
        io: std.Io,
        reason: protocol.DoneReason,
        message: protocol.AssistantMessage,
    ) !void {
        try self.emit(io, .{ .done = .{ .reason = reason, .message = message } });
        self.result.* = message;
    }

    pub fn endError(
        self: PendingEventSink,
        io: std.Io,
        reason: protocol.ErrorReason,
        message: protocol.AssistantMessage,
    ) !void {
        try self.emit(io, .{ .@"error" = .{ .reason = reason, .@"error" = message } });
        self.result.* = message;
    }

    pub fn endAborted(self: PendingEventSink, io: std.Io, message: protocol.AssistantMessage) !void {
        try self.endError(io, .aborted, message);
    }
};

pub const ResponseStreamReducer = struct {
    backing_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    model: protocol.Model,
    output: protocol.AssistantMessage,
    content: std.ArrayList(protocol.AssistantContent) = .empty,
    current: CurrentBlock = .none,

    const CurrentBlock = union(enum) {
        none,
        thinking: TextState,
        text: TextState,
        tool_call: ToolCallState,
    };

    const TextState = struct {
        content_index: usize,
        bytes: mem.ByteBuilder,
    };

    const ToolCallState = struct {
        content_index: usize,
        partial_json: mem.ByteBuilder,
        streaming_parse_arena: std.heap.ArenaAllocator,
    };

    pub fn init(
        backing_allocator: std.mem.Allocator,
        model: protocol.Model,
        timestamp: protocol.Timestamp,
    ) ResponseStreamReducer {
        return .{
            .backing_allocator = backing_allocator,
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .model = model,
            .output = .{
                .content = &.{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = protocol.emptyUsage(),
                .stop_reason = .stop,
                .timestamp = timestamp,
            },
        };
    }

    pub fn deinit(self: *ResponseStreamReducer) void {
        self.discardCurrentBlock();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn partial(self: *ResponseStreamReducer) std.mem.Allocator.Error!protocol.AssistantMessage {
        var snapshot = self.output;
        snapshot.content = self.content.items;
        return snapshot;
    }

    /// All content-block appends go through here. `partial()` snapshots borrow
    /// `content.items`, and one SSE chunk can queue several events before the
    /// consumer drains them — so the array must never relocate while a stream
    /// is live. Capacity is reserved once and growth past the cap is rejected.
    fn appendContentBlock(self: *ResponseStreamReducer, block: protocol.AssistantContent) !void {
        if (self.content.capacity == 0) {
            try self.content.ensureTotalCapacityPrecise(self.arena.allocator(), max_stream_content_blocks);
        }
        if (self.content.items.len >= max_stream_content_blocks) return error.TooManyContentBlocks;
        self.content.appendAssumeCapacity(block);
    }

    pub fn applySseData(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: anytype,
        data: []const u8,
    ) anyerror!void {
        if (std.mem.eql(u8, std.mem.trim(u8, data, " \t\r\n"), "[DONE]")) return;
        var parsed = json_parse.parseJsonWithRepair(self.arena.allocator(), data) catch return error.InvalidJson;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidJson;
        try self.applyEvent(io, sink, parsed.value.object);
    }

    pub fn finish(self: *ResponseStreamReducer, io: std.Io, sink: anytype) anyerror!void {
        try self.finishCurrentBlock(io, sink);
        self.output.content = try self.content.toOwnedSlice(self.arena.allocator());
        if (hasToolCall(self.output.content) and self.output.stop_reason == .stop) self.output.stop_reason = .tool_use;
        switch (self.output.stop_reason) {
            .stop => try sink.endDone(io, .stop, self.output),
            .length => try sink.endDone(io, .length, self.output),
            .tool_use => try sink.endDone(io, .tool_use, self.output),
            .error_ => try sink.endError(io, .error_, self.output),
            .aborted => try sink.endAborted(io, self.output),
        }
    }

    fn applyEvent(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: anytype,
        object: std.json.ObjectMap,
    ) anyerror!void {
        const event_type = jsonString(object.get("type")) orelse return;

        if (std.mem.eql(u8, event_type, "response.created")) {
            if (object.get("response")) |response| if (response == .object) {
                if (jsonString(response.object.get("id"))) |id| self.output.response_id = try dupe(self, id);
            };
        } else if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            if (object.get("item")) |item| if (item == .object) try self.startItem(io, sink, item.object);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.added")) {
            // The part object is only a container for following text deltas; the
            // final output_item.done carries the durable summary text.
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta")) {
            if (jsonString(object.get("delta"))) |delta| try self.appendThinking(io, sink, delta);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.done")) {
            try self.appendThinking(io, sink, "\n\n");
        } else if (std.mem.eql(u8, event_type, "response.reasoning_text.delta")) {
            if (jsonString(object.get("delta"))) |delta| try self.appendThinking(io, sink, delta);
        } else if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
            if (jsonString(object.get("delta"))) |delta| try self.appendText(io, sink, delta);
        } else if (std.mem.eql(u8, event_type, "response.refusal.delta")) {
            if (jsonString(object.get("delta"))) |delta| try self.appendText(io, sink, delta);
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            if (jsonString(object.get("delta"))) |delta| try self.appendToolArguments(io, sink, delta);
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            if (jsonString(object.get("arguments"))) |arguments| try self.finishToolArguments(io, sink, arguments);
        } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            if (object.get("item")) |item| if (item == .object) try self.finishItem(io, sink, item.object);
        } else if (std.mem.eql(u8, event_type, "response.completed") or
            std.mem.eql(u8, event_type, "response.done") or
            std.mem.eql(u8, event_type, "response.incomplete"))
        {
            if (object.get("response")) |response| if (response == .object) try self.applyCompleted(response.object);
        } else if (std.mem.eql(u8, event_type, "error")) {
            self.output.stop_reason = .error_;
            self.output.error_message = try self.formatProviderError(object);
            self.output.operational_failure = self.providerEventFailure(self.output.error_message.?);
            try sink.endError(io, .error_, try self.partial());
            return error.ErrorEmitted;
        } else if (std.mem.eql(u8, event_type, "response.failed")) {
            self.output.stop_reason = .error_;
            self.output.error_message = try self.formatFailedResponse(object);
            self.output.operational_failure = self.providerEventFailure(self.output.error_message.?);
            try sink.endError(io, .error_, try self.partial());
            return error.ErrorEmitted;
        }
    }

    fn startItem(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: anytype,
        item: std.json.ObjectMap,
    ) anyerror!void {
        try self.finishCurrentBlock(io, sink);
        const item_type = jsonString(item.get("type")) orelse return;
        if (std.mem.eql(u8, item_type, "reasoning")) {
            try self.appendContentBlock(.{ .thinking = .{ .thinking = "" } });
            const index = self.content.items.len - 1;
            self.current = .{ .thinking = .{
                .content_index = index,
                .bytes = mem.ByteBuilder.initBounded(
                    self.arena.allocator(),
                    max_stream_thinking_block_bytes,
                ),
            } };
            try sink.emit(io, .{ .thinking_start = .{ .content_index = index, .partial = try self.partial() } });
        } else if (std.mem.eql(u8, item_type, "message")) {
            try self.appendContentBlock(.{ .text = .{ .text = "" } });
            const index = self.content.items.len - 1;
            self.current = .{ .text = .{
                .content_index = index,
                .bytes = mem.ByteBuilder.initBounded(
                    self.arena.allocator(),
                    max_stream_text_block_bytes,
                ),
            } };
            try sink.emit(io, .{ .text_start = .{ .content_index = index, .partial = try self.partial() } });
        } else if (std.mem.eql(u8, item_type, "function_call")) {
            const call_id = jsonString(item.get("call_id")) orelse "";
            const item_id = jsonString(item.get("id")) orelse "";
            const name = jsonString(item.get("name")) orelse "";
            const id = try std.fmt.allocPrint(self.arena.allocator(), "{s}|{s}", .{ call_id, item_id });
            try self.appendContentBlock(.{ .tool_call = .{
                .id = id,
                .name = try dupe(self, name),
                .arguments = emptyObject(),
            } });
            const index = self.content.items.len - 1;
            self.current = .{ .tool_call = .{
                .content_index = index,
                .partial_json = mem.ByteBuilder.initBounded(
                    self.backing_allocator,
                    max_stream_tool_arguments_bytes,
                ),
                .streaming_parse_arena = std.heap.ArenaAllocator.init(self.backing_allocator),
            } };
            if (jsonString(item.get("arguments"))) |arguments| {
                try self.current.tool_call.partial_json.append(arguments);
            }
            try sink.emit(io, .{ .toolcall_start = .{ .content_index = index, .partial = try self.partial() } });
        }
    }

    fn finishCurrentBlock(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: anytype,
    ) anyerror!void {
        switch (self.current) {
            .none => {},
            .thinking => |*state| {
                const frozen = try state.bytes.copyTo(self.arena.allocator());
                self.content.items[state.content_index].thinking.thinking = frozen;
                try sink.emit(io, .{ .thinking_end = .{
                    .content_index = state.content_index,
                    .content = frozen,
                    .partial = try self.partial(),
                } });
            },
            .text => |*state| {
                const frozen = try state.bytes.copyTo(self.arena.allocator());
                self.content.items[state.content_index].text.text = frozen;
                try sink.emit(io, .{ .text_end = .{
                    .content_index = state.content_index,
                    .content = frozen,
                    .partial = try self.partial(),
                } });
            },
            .tool_call => |*state| {
                errdefer {
                    state.partial_json.deinit();
                    state.streaming_parse_arena.deinit();
                }
                try self.parseToolArguments(state);
                try sink.emit(io, .{ .toolcall_end = .{
                    .content_index = state.content_index,
                    .tool_call = self.content.items[state.content_index].tool_call,
                    .partial = try self.partial(),
                } });
                state.partial_json.deinit();
                state.streaming_parse_arena.deinit();
            },
        }
        self.current = .none;
    }

    fn discardCurrentBlock(self: *ResponseStreamReducer) void {
        switch (self.current) {
            .thinking, .text => {},
            .tool_call => |*state| {
                state.partial_json.deinit();
                state.streaming_parse_arena.deinit();
            },
            .none => {},
        }
        self.current = .none;
    }

    fn appendThinking(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: anytype,
        delta: []const u8,
    ) anyerror!void {
        if (self.current != .thinking) return;
        const state = &self.current.thinking;
        try state.bytes.append(delta);
        const index = state.content_index;
        self.content.items[index].thinking.thinking = state.bytes.items();
        try sink.emit(io, .{ .thinking_delta = .{
            .content_index = index,
            .delta = try dupe(self, delta),
            .partial = try self.partial(),
        } });
    }

    fn appendText(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: anytype,
        delta: []const u8,
    ) anyerror!void {
        if (self.current != .text) return;
        const state = &self.current.text;
        try state.bytes.append(delta);
        const index = state.content_index;
        self.content.items[index].text.text = state.bytes.items();
        try sink.emit(io, .{ .text_delta = .{
            .content_index = index,
            .delta = try dupe(self, delta),
            .partial = try self.partial(),
        } });
    }

    fn appendToolArguments(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: anytype,
        delta: []const u8,
    ) anyerror!void {
        if (self.current != .tool_call) return;
        const state = &self.current.tool_call;
        try state.partial_json.append(delta);
        try self.parseStreamingToolArguments(state);
        try sink.emit(io, .{ .toolcall_delta = .{
            .content_index = state.content_index,
            .delta = try dupe(self, delta),
            .partial = try self.partial(),
        } });
    }

    fn finishToolArguments(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: anytype,
        arguments: []const u8,
    ) anyerror!void {
        if (self.current != .tool_call) return;
        const state = &self.current.tool_call;
        const previous_len = state.partial_json.items().len;
        state.partial_json.clearRetainingCapacity();
        try state.partial_json.append(arguments);
        try self.parseToolArguments(state);
        if (arguments.len > previous_len) {
            const delta = arguments[previous_len..];
            try sink.emit(io, .{ .toolcall_delta = .{
                .content_index = state.content_index,
                .delta = try dupe(self, delta),
                .partial = try self.partial(),
            } });
        }
    }

    fn finishItem(
        self: *ResponseStreamReducer,
        io: std.Io,
        sink: anytype,
        item: std.json.ObjectMap,
    ) anyerror!void {
        const item_type = jsonString(item.get("type")) orelse return;
        if (std.mem.eql(u8, item_type, "reasoning") and self.current == .thinking) {
            const state = &self.current.thinking;
            if (try self.reasoningTextFromItem(item)) |text| {
                state.bytes.clearRetainingCapacity();
                try state.bytes.append(text);
            }
            self.content.items[state.content_index].thinking.thinking_signature = try self.encodeItemSignature(item);
        } else if (std.mem.eql(u8, item_type, "message") and self.current == .text) {
            const index = self.current.text.content_index;
            if (jsonString(item.get("id"))) |id| {
                self.content.items[index].text.text_signature = encodeTextSignature(
                    self.arena.allocator(),
                    id,
                ) catch return error.OutOfMemory;
            }
        } else if (std.mem.eql(u8, item_type, "function_call") and self.current == .tool_call) {
            const state = &self.current.tool_call;
            if (jsonString(item.get("arguments"))) |arguments| {
                state.partial_json.clearRetainingCapacity();
                try state.partial_json.append(arguments);
            }
        }
        try self.finishCurrentBlock(io, sink);
    }

    fn parseToolArguments(self: *ResponseStreamReducer, state: *ToolCallState) !void {
        const parsed = try parseJsonValueLeaky(self.arena.allocator(), state.partial_json.items());
        self.content.items[state.content_index].tool_call.arguments = parsed;
    }

    fn parseStreamingToolArguments(self: *ResponseStreamReducer, state: *ToolCallState) !void {
        _ = state.streaming_parse_arena.reset(.retain_capacity);
        const parsed = try json_parse.parseStreamingJson(state.streaming_parse_arena.allocator(), state.partial_json.items());
        self.content.items[state.content_index].tool_call.arguments = parsed.value();
    }

    fn reasoningTextFromItem(self: *ResponseStreamReducer, item: std.json.ObjectMap) !?[]const u8 {
        if (try self.textParts(item.get("summary"))) |text| return text;
        return self.textParts(item.get("content"));
    }

    fn textParts(self: *ResponseStreamReducer, value: ?std.json.Value) !?[]const u8 {
        const resolved = value orelse return null;
        if (resolved != .array) return null;
        var out = mem.ByteBuilder.initBounded(self.arena.allocator(), max_stream_thinking_block_bytes);
        errdefer out.deinit();
        var wrote = false;
        for (resolved.array.items) |part| {
            if (part != .object) continue;
            const text = jsonString(part.object.get("text")) orelse continue;
            if (text.len == 0) continue;
            if (wrote) try out.append("\n\n");
            try out.append(text);
            wrote = true;
        }
        if (!wrote) {
            out.deinit();
            return null;
        }
        return try out.toOwnedSlice();
    }

    fn encodeItemSignature(self: *ResponseStreamReducer, item: std.json.ObjectMap) ![]const u8 {
        var out = mem.ByteBuilder.initBounded(self.arena.allocator(), max_stream_signature_bytes);
        errdefer out.deinit();
        try out.append("{\"v\":1");
        if (jsonString(item.get("id"))) |id| {
            try out.append(",\"id\":");
            try appendJsonStringBounded(&out, id);
        }
        if (jsonString(item.get("encrypted_content"))) |encrypted| {
            try out.append(",\"encrypted_content\":");
            try appendJsonStringBounded(&out, encrypted);
        }
        try out.appendByte('}');
        return out.toOwnedSlice();
    }

    fn applyCompleted(self: *ResponseStreamReducer, response: std.json.ObjectMap) !void {
        if (jsonString(response.get("id"))) |id| self.output.response_id = try dupe(self, id);
        if (response.get("usage")) |usage| if (usage == .object) {
            const cached = if (usage.object.get("input_tokens_details")) |details|
                if (details == .object) jsonU64(details.object.get("cached_tokens")) orelse 0 else 0
            else
                0;
            const input_tokens = jsonU64(usage.object.get("input_tokens")) orelse 0;
            self.output.usage.input = if (input_tokens > cached) input_tokens - cached else 0;
            self.output.usage.output = jsonU64(usage.object.get("output_tokens")) orelse 0;
            self.output.usage.cache_read = cached;
            self.output.usage.cache_write = 0;
            self.output.usage.total_tokens = jsonU64(usage.object.get("total_tokens")) orelse 0;
            _ = models_api.calculateCost(self.model, &self.output.usage);
        };
        self.output.stop_reason = mapStopReason(jsonString(response.get("status")));
    }

    fn providerEventFailure(self: *ResponseStreamReducer, message: []const u8) protocol.OperationalFailure {
        const category: protocol.OperationalFailure.Category = if (containsContextOverflow(message)) .context_overflow else .unknown;
        return .{
            .category = category,
            .message = if (category == .context_overflow) "Request exceeds model context window" else "Provider stream failed",
            .detail = message,
            .retryable = .unknown,
            .provider = self.output.provider,
            .model = self.output.model,
        };
    }

    fn formatProviderError(self: *ResponseStreamReducer, object: std.json.ObjectMap) ![]const u8 {
        const code = jsonString(object.get("code")) orelse "unknown";
        const message = jsonString(object.get("message")) orelse "Unknown error";
        return formatErrorMessage(self.arena.allocator(), "Error Code ", code, ": ", message);
    }

    fn formatFailedResponse(self: *ResponseStreamReducer, object: std.json.ObjectMap) ![]const u8 {
        if (object.get("response")) |response| if (response == .object) {
            if (response.object.get("error")) |err| if (err == .object) {
                const code = jsonString(err.object.get("code")) orelse "unknown";
                const message = jsonString(err.object.get("message")) orelse "no message";
                return formatErrorMessage(self.arena.allocator(), "", code, ": ", message);
            };
            if (response.object.get("incomplete_details")) |details| if (details == .object) {
                if (jsonString(details.object.get("reason"))) |reason| {
                    return formatErrorMessage(self.arena.allocator(), "incomplete: ", reason, "", "");
                }
            };
        };
        return dupe(self, "Unknown error (no error details in response)");
    }
};

fn formatErrorMessage(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    code: []const u8,
    separator: []const u8,
    message: []const u8,
) ![]const u8 {
    var buffer: [protocol.OperationalFailure.detail_bytes_max]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.writeAll(prefix) catch {};
    writer.writeAll(utf8Prefix(code, buffer.len - writer.buffered().len)) catch {};
    writer.writeAll(separator[0..@min(separator.len, buffer.len - writer.buffered().len)]) catch {};
    writer.writeAll(utf8Prefix(message, buffer.len - writer.buffered().len)) catch {};
    return allocator.dupe(u8, writer.buffered());
}

fn utf8Prefix(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var end = max_bytes;
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    return text[0..end];
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const resolved = value orelse return null;
    return switch (resolved) {
        .string => |string| string,
        else => null,
    };
}

fn jsonU64(value: ?std.json.Value) ?u64 {
    const resolved = value orelse return null;
    return switch (resolved) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0 and float <= @as(f64, @floatFromInt(std.math.maxInt(u64))))
            @intFromFloat(float)
        else
            null,
        else => null,
    };
}

fn mapStopReason(status: ?[]const u8) protocol.StopReason {
    const value = status orelse return .stop;
    if (std.mem.eql(u8, value, "completed")) return .stop;
    if (std.mem.eql(u8, value, "incomplete")) return .length;
    if (std.mem.eql(u8, value, "failed")) return .error_;
    if (std.mem.eql(u8, value, "cancelled")) return .error_;
    if (std.mem.eql(u8, value, "in_progress")) return .stop;
    if (std.mem.eql(u8, value, "queued")) return .stop;
    return .error_;
}

fn hasToolCall(content: []const protocol.AssistantContent) bool {
    for (content) |block| if (block == .tool_call) return true;
    return false;
}

fn emptyObject() std.json.Value {
    const object: std.json.ObjectMap = .empty;
    return .{ .object = object };
}

fn parseJsonValueLeaky(allocator: std.mem.Allocator, json: []const u8) !std.json.Value {
    const trimmed = std.mem.trim(u8, json, " \t\r\n");
    if (trimmed.len == 0) return emptyObject();
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{});
}

fn encodeTextSignature(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    var out = mem.ByteBuilder.initBounded(allocator, max_stream_signature_bytes);
    errdefer out.deinit();
    try out.append("{\"v\":1,\"id\":");
    try appendJsonStringBounded(&out, id);
    try out.appendByte('}');
    return out.toOwnedSlice();
}

fn appendJsonStringBounded(out: *mem.ByteBuilder, value: []const u8) mem.ByteBuilder.Error!void {
    try out.appendByte('"');
    for (value) |byte| switch (byte) {
        '"' => try out.append("\\\""),
        '\\' => try out.append("\\\\"),
        '\n' => try out.append("\\n"),
        '\r' => try out.append("\\r"),
        '\t' => try out.append("\\t"),
        0...8, 11...12, 14...0x1f => {
            var escaped: [6]u8 = undefined;
            const text = std.fmt.bufPrint(&escaped, "\\u{x:0>4}", .{byte}) catch unreachable;
            try out.append(text);
        },
        else => try out.appendByte(byte),
    };
    try out.appendByte('"');
}

fn concat(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ![]const u8 {
    const output = try allocator.alloc(u8, left.len + right.len);
    @memcpy(output[0..left.len], left);
    @memcpy(output[left.len..], right);
    return output;
}

fn dupe(self: *ResponseStreamReducer, value: []const u8) ![]const u8 {
    return self.arena.allocator().dupe(u8, value);
}

test "context overflow fallback follows common provider wording" {
    try std.testing.expect(containsContextOverflow("Your input exceeds the context window of this model"));
    try std.testing.expect(containsContextOverflow("prompt is too long: 213462 tokens > 200000 maximum"));
    try std.testing.expect(containsContextOverflow("maximum context length is 100 tokens"));
    try std.testing.expect(!containsContextOverflow("rate limit: too many tokens, please wait"));
}

test "stream errors classify transport and malformed response" {
    var cancel = try mem.CancelSource.init(std.testing.allocator, std.testing.io);
    defer cancel.deinit();
    const request: protocol.StreamRequest = .{
        .allocator = std.testing.allocator,
        .io = std.Io.failing,
        .model = testModel(),
        .context = .{ .messages = &.{} },
        .cancel_token = cancel.token(),
    };
    try std.testing.expectEqual(
        protocol.OperationalFailure.Category.malformed_response,
        classifyStreamError(request, error.InvalidJson).category,
    );
    try std.testing.expectEqual(
        protocol.OperationalFailure.Category.transport,
        classifyStreamError(request, error.ConnectionResetByPeer).category,
    );
}

test "open errors classify transport and malformed response" {
    var cancel = try mem.CancelSource.init(std.testing.allocator, std.testing.io);
    defer cancel.deinit();
    const request: protocol.StreamRequest = .{
        .allocator = std.testing.allocator,
        .io = std.Io.failing,
        .model = testModel(),
        .context = .{ .messages = &.{} },
        .cancel_token = cancel.token(),
    };
    var stream = errorStream(request, error.InvalidJson);
    var event = (try stream.next(std.Io.failing)).?.@"error";
    try std.testing.expectEqual(protocol.OperationalFailure.Category.malformed_response, event.@"error".operational_failure.?.category);
    stream.deinit();

    stream = errorStream(request, error.ConnectionRefused);
    event = (try stream.next(std.Io.failing)).?.@"error";
    try std.testing.expectEqual(protocol.OperationalFailure.Category.transport, event.@"error".operational_failure.?.category);
    stream.deinit();
}

test "provider error formatting is bounded" {
    const huge = "x" ** (protocol.OperationalFailure.detail_bytes_max * 2);
    const formatted = try formatErrorMessage(std.testing.allocator, "", "code", ": ", huge);
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(formatted.len <= protocol.OperationalFailure.detail_bytes_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(formatted));
}

test "responses reducer emits text deltas and done" {
    const model = testModel();
    var reducer = ResponseStreamReducer.init(std.testing.allocator, model, 123);
    defer reducer.deinit();
    var stream = protocol.AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();

    try sink.emit(std.Io.failing, .{ .start = .{ .partial = try reducer.partial() } });
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.output_item.added","item":{"type":"message","id":"msg_1"}}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.output_text.delta","delta":"hi"}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1"}}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.completed","response":{"id":"resp_1","status":"completed",
        \\"usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12,
        \\"input_tokens_details":{"cached_tokens":3}}}}
    );
    try reducer.finish(std.Io.failing, sink);

    var handler: CountingHandler = .{};
    const result = try protocol.AssistantMessageEventStream.drain(CountingHandler, std.Io.failing, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 5), handler.event_count);
    try std.testing.expectEqualStrings("hi", result.content[0].text.text);
    try std.testing.expectEqualStrings("resp_1", result.response_id.?);
    try std.testing.expectEqual(@as(u64, 7), result.usage.input);
    try std.testing.expectEqual(@as(u64, 3), result.usage.cache_read);
    try std.testing.expectEqual(protocol.StopReason.stop, result.stop_reason);
}

test "responses reducer finalizes reasoning summary from item done" {
    const model = testModel();
    var reducer = ResponseStreamReducer.init(std.testing.allocator, model, 123);
    defer reducer.deinit();
    var stream = protocol.AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();

    try sink.emit(std.Io.failing, .{ .start = .{ .partial = try reducer.partial() } });
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.output_item.added","item":{"type":"reasoning","id":"rs_1"}}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1",
        \\"summary":[{"type":"summary_text","text":"looked"},{"type":"summary_text","text":"decided"}],
        \\"encrypted_content":"secret"}}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.completed","response":{"status":"completed"}}
    );
    try reducer.finish(std.Io.failing, sink);

    var saw_end = false;
    while (try stream.next(std.Io.failing)) |event| {
        if (event == .thinking_end) {
            saw_end = true;
            try std.testing.expectEqualStrings("looked\n\ndecided", event.thinking_end.content);
        }
    }
    const result = stream.result().?;
    try std.testing.expect(saw_end);
    try std.testing.expectEqualStrings("looked\n\ndecided", result.content[0].thinking.thinking);
    try std.testing.expect(result.content[0].thinking.thinking_signature != null);
}

test "responses reducer streams reasoning text deltas" {
    const model = testModel();
    var reducer = ResponseStreamReducer.init(std.testing.allocator, model, 123);
    defer reducer.deinit();
    var stream = protocol.AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();

    try sink.emit(std.Io.failing, .{ .start = .{ .partial = try reducer.partial() } });
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.output_item.added","item":{"type":"reasoning","id":"rs_1"}}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.reasoning_text.delta","delta":"raw"}
    );

    var saw_delta = false;
    while (try stream.next(std.Io.failing)) |event| {
        if (event == .thinking_delta) {
            saw_delta = true;
            try std.testing.expectEqualStrings("raw", event.thinking_delta.delta);
        }
    }
    try std.testing.expect(saw_delta);
}

test "responses reducer parses tool call arguments and maps stop to tool use" {
    const model = testModel();
    var reducer = ResponseStreamReducer.init(std.testing.allocator, model, 123);
    defer reducer.deinit();
    var stream = protocol.AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();

    try sink.emit(std.Io.failing, .{ .start = .{ .partial = try reducer.partial() } });
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.output_item.added","item":{"type":"function_call",
        \\"id":"fc_1","call_id":"call_1","name":"echo","arguments":""}}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.function_call_arguments.delta","delta":"{\"text\":"}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.function_call_arguments.done","arguments":"{\"text\":\"ok\"}"}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.output_item.done","item":{"type":"function_call",
        \\"id":"fc_1","call_id":"call_1","name":"echo",
        \\"arguments":"{\"text\":\"ok\"}"}}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.completed","response":{"status":"completed"}}
    );
    try reducer.finish(std.Io.failing, sink);

    var handler: CountingHandler = .{};
    const result = try protocol.AssistantMessageEventStream.drain(CountingHandler, std.Io.failing, &stream, &handler);
    const call = result.content[0].tool_call;
    try std.testing.expectEqualStrings("call_1|fc_1", call.id);
    try std.testing.expectEqualStrings("echo", call.name);
    try std.testing.expectEqualStrings("ok", call.arguments.object.get("text").?.string);
    try std.testing.expectEqual(protocol.StopReason.tool_use, result.stop_reason);
}

test "responses reducer exposes partial tool arguments during deltas" {
    const model = testModel();
    var reducer = ResponseStreamReducer.init(std.testing.allocator, model, 123);
    defer reducer.deinit();
    var stream = protocol.AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();

    try sink.emit(std.Io.failing, .{ .start = .{ .partial = try reducer.partial() } });
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1",
        \\"call_id":"call_1","name":"write","arguments":""}}
    );
    try reducer.applySseData(std.Io.failing, sink,
        \\{"type":"response.function_call_arguments.delta","delta":"{\"content\":\"one"}
    );

    var handler: ToolDeltaHandler = .{};
    while (try stream.next(std.Io.failing)) |event| try handler.onAssistantMessageEvent(event);
    try std.testing.expectEqualStrings("one", handler.content_preview.?);
}

const ToolDeltaHandler = struct {
    content_preview: ?[]const u8 = null,

    pub fn onAssistantMessageEvent(self: *ToolDeltaHandler, event: protocol.AssistantMessageEvent) !void {
        if (event != .toolcall_delta) return;
        const partial = event.toolcall_delta.partial;
        if (partial.content.len == 0 or partial.content[0] != .tool_call) return;
        const args = partial.content[0].tool_call.arguments;
        if (args == .object) {
            if (args.object.get("content")) |value| {
                if (value == .string) self.content_preview = value.string;
            }
        }
    }
};

const CountingHandler = struct {
    event_count: usize = 0,

    pub fn onAssistantMessageEvent(self: *CountingHandler, _: protocol.AssistantMessageEvent) !void {
        self.event_count += 1;
    }
};

fn testModel() protocol.Model {
    return .{
        .id = "gpt-test",
        .name = "GPT Test",
        .api = protocol.KnownApi.openai_responses,
        .provider = protocol.KnownProvider.openai,
        .base_url = "https://api.openai.test/v1",
        .reasoning = true,
        .input = &.{ .text, .image },
        .cost = .{ .input = 1, .output = 2, .cache_read = 0.5, .cache_write = 1.5 },
        .context_window = 128_000,
        .max_tokens = 32_000,
    };
}

test "responses reducer content storage never relocates while a stream is live" {
    // Pending events queued between consumer pulls borrow `content.items`
    // (see `partial()`); a relocation would leave earlier snapshots dangling.
    const model = testModel();
    var reducer = ResponseStreamReducer.init(std.testing.allocator, model, 123);
    defer reducer.deinit();

    try reducer.appendContentBlock(.{ .text = .{ .text = "" } });
    const first_ptr = reducer.content.items.ptr;
    var index: usize = 1;
    while (index < max_stream_content_blocks) : (index += 1) {
        try reducer.appendContentBlock(.{ .text = .{ .text = "" } });
    }
    try std.testing.expectEqual(first_ptr, reducer.content.items.ptr);
    try std.testing.expectError(
        error.TooManyContentBlocks,
        reducer.appendContentBlock(.{ .text = .{ .text = "" } }),
    );
}
