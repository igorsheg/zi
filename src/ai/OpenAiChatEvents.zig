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
    emit_progress: bool = false,
    cache_write_1h: bool = false,
    /// Borrowed for the parser lifetime.
    length_hint: ?[]const u8 = null,
};

pub const Error = error{ OutOfMemory, Cancelled, InvalidResponse };

const ToolCall = struct {
    index: i64,
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    arguments_before_start: std.ArrayList(u8) = .empty,
    started: bool = false,
    finished: bool = false,
};

/// Fresh, owned translation state for one Chat Completions stream. Emitted byte
/// slices are borrowed and remain valid only during the synchronous sink call.
pub const Parser = struct {
    allocator: std.mem.Allocator,
    sink: Provider.EventSink,
    options: Options,
    tool_calls: std.ArrayList(ToolCall) = .empty,
    reasoning_blocks: std.ArrayList([]u8) = .empty,
    owned_state_bytes: usize = 0,
    usage_value: Usage.StreamUsage = .{},
    response_id: ?[]u8 = null,
    served_model: ?[]u8 = null,
    route: ?[]u8 = null,
    finish_reason: ?[]u8 = null,
    finish_error: ?[]u8 = null,
    finish_received: bool = false,
    terminal_emitted: bool = false,

    pub fn init(allocator: std.mem.Allocator, sink: Provider.EventSink, options: Options) Error!Parser {
        if (options.max_tracked_calls == 0 or options.max_tracked_calls > maximum_tracked_calls or
            options.max_owned_state_bytes == 0 or options.max_owned_state_bytes > maximum_owned_state_bytes or
            options.max_event_bytes == 0 or options.max_event_bytes > maximum_event_bytes)
        {
            return error.InvalidResponse;
        }
        return .{ .allocator = allocator, .sink = sink, .options = options };
    }

    pub fn deinit(self: *Parser) void {
        for (self.tool_calls.items) |*call| {
            if (call.id) |value| self.allocator.free(value);
            if (call.name) |value| self.allocator.free(value);
            call.arguments_before_start.deinit(self.allocator);
        }
        self.tool_calls.deinit(self.allocator);
        self.clearReasoningBlocks();
        self.reasoning_blocks.deinit(self.allocator);
        if (self.response_id) |value| self.allocator.free(value);
        if (self.served_model) |value| self.allocator.free(value);
        if (self.route) |value| self.allocator.free(value);
        if (self.finish_reason) |value| self.allocator.free(value);
        if (self.finish_error) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn feed(self: *Parser, event: Transport.SseEvent) Error!void {
        if (self.terminal_emitted) return;
        try validateSseEvent(event, self.options.max_event_bytes);
        if (event.data.len == 0) return;
        if (std.mem.eql(u8, event.data, "[DONE]")) return self.handleDone();

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, event.data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResponse,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const root = parsed.value.object;

        if (root.get("error")) |error_value| {
            if (error_value != .object) return error.InvalidResponse;
            return self.handleError(error_value.object);
        }
        try self.captureResponse(root);
        try self.captureUsage(root);
        try self.handleProgress(root);

        if (self.finish_received) {
            const late_choices = root.get("choices") orelse return;
            if (late_choices != .array or late_choices.array.items.len != 0) {
                return error.InvalidResponse;
            }
            return;
        }
        const choices_value = root.get("choices") orelse return;
        if (choices_value != .array) return error.InvalidResponse;
        if (choices_value.array.items.len == 0) return;
        const choice_value = choices_value.array.items[0];
        if (choice_value != .object) return error.InvalidResponse;
        try self.handleChoice(choice_value.object);
    }

    pub fn finalize(self: *Parser) Error!void {
        if (self.terminal_emitted) return;
        if (self.finish_received) return self.emitTerminal();
        self.terminal_emitted = true;
        try self.emit(.{ .failure = .{
            .message = "stream ended before completion",
            .usage = self.reportedUsage(),
            .response = self.responseIdentity(),
        } });
    }

    /// A finish reason is sufficient on a cleanly closed transport. `[DONE]`
    /// remains preferred because usage commonly follows the finish chunk.
    pub fn isComplete(self: *const Parser) bool {
        return self.terminal_emitted or self.finish_received;
    }

    /// Usage seen so far belongs to this attempt and can be retained by retry.
    pub fn usage(self: *const Parser) ?Usage.StreamUsage {
        return self.reportedUsage();
    }

    pub fn recover(_: *Parser) Error!bool {
        return false;
    }

    fn handleChoice(self: *Parser, choice: std.json.ObjectMap) Error!void {
        if (choice.get("delta")) |delta_value| {
            if (delta_value != .object) return error.InvalidResponse;
            const delta = delta_value.object;
            try self.collectReasoningDetails(delta);
            const reasoning = (optionalString(delta, "reasoning") catch return error.InvalidResponse) orelse
                (optionalString(delta, "reasoning_content") catch return error.InvalidResponse);
            if (reasoning) |text| {
                if (text.len != 0) try self.emit(.{ .reasoning_delta = text });
            }
            const content = optionalString(delta, "content") catch return error.InvalidResponse;
            const tool_calls = delta.get("tool_calls");
            if ((content != null and content.?.len != 0) or tool_calls != null) try self.flushReasoningDetails();
            if (content) |text| if (text.len != 0) try self.emit(.{ .text_delta = text });
            if (tool_calls) |calls_value| {
                if (calls_value != .array) return error.InvalidResponse;
                for (calls_value.array.items) |call_value| {
                    if (call_value != .object) return error.InvalidResponse;
                    try self.handleToolCallDelta(call_value.object);
                }
            }
        }

        if (optionalString(choice, "finish_reason") catch return error.InvalidResponse) |reason| {
            try self.handleFinishReason(reason);
        }
    }

    fn handleToolCallDelta(self: *Parser, delta: std.json.ObjectMap) Error!void {
        const index = (optionalInteger(delta, "index") catch return error.InvalidResponse) orelse 0;
        if (index < 0) return error.InvalidResponse;
        const call = try self.getToolCall(index);

        if (optionalString(delta, "id") catch return error.InvalidResponse) |id| {
            if (id.len != 0 and call.id == null) call.id = try self.own(id);
        }
        if (delta.get("function")) |function_value| {
            if (function_value != .object) return error.InvalidResponse;
            const function = function_value.object;
            if (optionalString(function, "name") catch return error.InvalidResponse) |name| {
                if (name.len != 0 and call.name == null) call.name = try self.own(name);
            }
            try self.startToolCall(call);
            if (optionalString(function, "arguments") catch return error.InvalidResponse) |arguments| {
                if (arguments.len == 0) return;
                if (!call.started) {
                    try self.reserveOwned(arguments.len);
                    call.arguments_before_start.appendSlice(self.allocator, arguments) catch return error.OutOfMemory;
                } else {
                    try self.emit(.{ .tool_call_delta = .{
                        .id = call.id.?,
                        .arguments_delta = arguments,
                    } });
                }
            }
        } else {
            try self.startToolCall(call);
        }
    }

    fn startToolCall(self: *Parser, call: *ToolCall) Error!void {
        if (call.started or call.name == null) return;
        if (call.id == null) {
            const id = std.fmt.allocPrint(self.allocator, "call_{d}", .{call.index}) catch return error.OutOfMemory;
            errdefer self.allocator.free(id);
            try self.reserveOwned(id.len);
            call.id = id;
        }
        call.started = true;
        try self.emit(.{ .tool_call_start = .{ .id = call.id.?, .name = call.name.? } });
        if (call.arguments_before_start.items.len != 0) {
            try self.emit(.{ .tool_call_delta = .{
                .id = call.id.?,
                .arguments_delta = call.arguments_before_start.items,
            } });
            self.owned_state_bytes -= call.arguments_before_start.items.len;
            call.arguments_before_start.deinit(self.allocator);
            call.arguments_before_start = .empty;
        }
    }

    fn getToolCall(self: *Parser, index: i64) Error!*ToolCall {
        for (self.tool_calls.items) |*call| if (call.index == index) return call;
        if (self.tool_calls.items.len >= self.options.max_tracked_calls) return error.InvalidResponse;
        self.tool_calls.append(self.allocator, .{ .index = index }) catch return error.OutOfMemory;
        return &self.tool_calls.items[self.tool_calls.items.len - 1];
    }

    fn finishToolCalls(self: *Parser) Error!void {
        for (self.tool_calls.items) |*call| {
            if (call.started and !call.finished) {
                call.finished = true;
                try self.emit(.{ .tool_call_end = call.id.? });
            }
        }
    }

    fn hasUnrepairableToolCall(self: *const Parser) bool {
        for (self.tool_calls.items) |call| if (!call.started) return true;
        return false;
    }

    fn collectReasoningDetails(self: *Parser, delta: std.json.ObjectMap) Error!void {
        const details_value = delta.get("reasoning_details") orelse return;
        if (details_value != .array) return error.InvalidResponse;
        for (details_value.array.items) |detail| {
            if (detail != .object) return error.InvalidResponse;
            const bytes = std.json.Stringify.valueAlloc(self.allocator, detail, .{}) catch
                return error.OutOfMemory;
            errdefer self.allocator.free(bytes);
            try self.reserveOwned(bytes.len);
            self.reasoning_blocks.append(self.allocator, bytes) catch return error.OutOfMemory;
        }
    }

    fn flushReasoningDetails(self: *Parser) Error!void {
        if (self.reasoning_blocks.items.len == 0) return;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        output.append(self.allocator, '[') catch return error.OutOfMemory;
        var index: usize = 0;
        var emitted: usize = 0;
        while (index < self.reasoning_blocks.items.len) {
            if (emitted != 0) output.append(self.allocator, ',') catch return error.OutOfMemory;
            if (try blockIsReasoningText(self.allocator, self.reasoning_blocks.items[index])) {
                var end = index + 1;
                while (end < self.reasoning_blocks.items.len and
                    try blockIsReasoningText(self.allocator, self.reasoning_blocks.items[end])) : (end += 1)
                {}
                try appendJoinedReasoningText(
                    self.allocator,
                    &output,
                    self.reasoning_blocks.items[index..end],
                );
                index = end;
            } else {
                output.appendSlice(self.allocator, self.reasoning_blocks.items[index]) catch
                    return error.OutOfMemory;
                index += 1;
            }
            emitted += 1;
        }
        output.append(self.allocator, ']') catch return error.OutOfMemory;
        try self.emit(.{ .reasoning_item = .{ .opaque_json = output.items } });
        self.clearReasoningBlocks();
    }

    fn clearReasoningBlocks(self: *Parser) void {
        for (self.reasoning_blocks.items) |block| {
            self.owned_state_bytes -= block.len;
            self.allocator.free(block);
        }
        self.reasoning_blocks.clearRetainingCapacity();
    }

    fn handleFinishReason(self: *Parser, reason: []const u8) Error!void {
        if (self.finish_received) return;
        if (self.hasUnrepairableToolCall()) return error.InvalidResponse;
        try self.flushReasoningDetails();
        try self.finishToolCalls();
        self.finish_received = true;
        if (std.mem.eql(u8, reason, "length") or std.mem.eql(u8, reason, "content_filter")) {
            const message = if (std.mem.eql(u8, reason, "length") and self.options.length_hint != null)
                std.fmt.allocPrint(self.allocator, "response incomplete: length: {s}", .{self.options.length_hint.?})
            else
                std.fmt.allocPrint(self.allocator, "response incomplete: {s}", .{reason});
            const owned = message catch return error.OutOfMemory;
            errdefer self.allocator.free(owned);
            try self.reserveOwned(owned.len);
            self.finish_error = owned;
        } else {
            self.finish_reason = try self.own(if (reason.len == 0) "stop" else reason);
        }
    }

    fn handleDone(self: *Parser) Error!void {
        if (self.hasUnrepairableToolCall()) return error.InvalidResponse;
        try self.flushReasoningDetails();
        try self.finishToolCalls();
        return self.emitTerminal();
    }

    fn emitTerminal(self: *Parser) Error!void {
        if (self.terminal_emitted) return;
        self.terminal_emitted = true;
        if (self.finish_error) |message| {
            try self.emit(.{ .failure = .{
                .message = message,
                .usage = self.reportedUsage(),
                .response = self.responseIdentity(),
            } });
        } else {
            try self.emit(.{ .done = .{
                .stop_reason = self.finish_reason orelse "stop",
                .usage = self.usage_value,
                .response = self.responseIdentity(),
            } });
        }
    }

    fn handleError(self: *Parser, object: std.json.ObjectMap) Error!void {
        const message = (optionalString(object, "message") catch return error.InvalidResponse) orelse "provider error";
        self.terminal_emitted = true;
        try self.emit(.{ .failure = .{
            .message = message,
            .usage = self.reportedUsage(),
            .response = self.responseIdentity(),
        } });
    }

    fn captureUsage(self: *Parser, root: std.json.ObjectMap) Error!void {
        const value = root.get("usage") orelse return;
        if (value == .null) return;
        if (value != .object) return error.InvalidResponse;
        const usage_object = value.object;
        try assignCount(&self.usage_value.input_tokens, usage_object, "prompt_tokens");
        try assignCount(&self.usage_value.output_tokens, usage_object, "completion_tokens");
        if (usage_object.get("prompt_tokens_details")) |details_value| {
            if (details_value != .object) return error.InvalidResponse;
            const details = details_value.object;
            try assignCount(&self.usage_value.cached_tokens, details, "cached_tokens");
            try assignCount(&self.usage_value.cache_write_tokens, details, "cache_write_tokens");
            if (self.options.cache_write_1h and self.usage_value.cache_write_tokens != null) {
                self.usage_value.cache_write_1h_tokens = self.usage_value.cache_write_tokens;
            }
        }
        if (usage_object.get("cost")) |cost_value| {
            const cost: f64 = switch (cost_value) {
                .integer => |number| @floatFromInt(number),
                .float => |number| number,
                else => return error.InvalidResponse,
            };
            if (!std.math.isFinite(cost) or cost < 0) return error.InvalidResponse;
            self.usage_value.cost_usd = cost;
        }
    }

    fn handleProgress(self: *Parser, root: std.json.ObjectMap) Error!void {
        const value = root.get("prompt_progress") orelse return;
        if (value != .object) return error.InvalidResponse;
        if (!self.options.emit_progress) return;
        const progress = value.object;
        try self.emit(.{ .progress = .{
            .processed_tokens = try countOrZero(progress, "processed"),
            .total_tokens = try countOrZero(progress, "total"),
            .cached_tokens = try countOrZero(progress, "cache"),
        } });
    }

    fn captureResponse(self: *Parser, root: std.json.ObjectMap) Error!void {
        if (self.response_id == null) if (optionalString(root, "id") catch return error.InvalidResponse) |value| {
            if (value.len != 0) self.response_id = try self.own(value);
        };
        if (self.served_model == null) if (optionalString(root, "model") catch return error.InvalidResponse) |value| {
            if (value.len != 0) self.served_model = try self.own(value);
        };
        if (self.route == null) if (optionalString(root, "provider") catch return error.InvalidResponse) |value| {
            if (value.len != 0) self.route = try self.own(value);
        };
    }

    fn responseIdentity(self: *const Parser) StreamEvent.ResponseIdentity {
        return .{ .id = self.response_id, .model = self.served_model, .route = self.route };
    }

    fn reportedUsage(self: *const Parser) ?Usage.StreamUsage {
        return if (Usage.usageReported(self.usage_value)) self.usage_value else null;
    }

    fn emit(self: *Parser, event: StreamEvent.StreamEvent) Error!void {
        self.sink.emit(event) catch return error.Cancelled;
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

fn blockIsReasoningText(allocator: std.mem.Allocator, bytes: []const u8) Error!bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    return parsed.value == .object and isReasoningText(parsed.value.object);
}

fn appendJoinedReasoningText(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    blocks: []const []u8,
) Error!void {
    std.debug.assert(blocks.len != 0);
    var first = std.json.parseFromSlice(std.json.Value, allocator, blocks[0], .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer first.deinit();
    if (first.value != .object or !isReasoningText(first.value.object)) return error.InvalidResponse;

    var merged: std.json.ObjectMap = .empty;
    defer merged.deinit(allocator);
    var iterator = first.value.object.iterator();
    while (iterator.next()) |entry| {
        merged.put(allocator, entry.key_ptr.*, entry.value_ptr.*) catch return error.OutOfMemory;
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    if (stringField(first.value.object, "text")) |value| {
        text.appendSlice(allocator, value) catch return error.OutOfMemory;
    }

    var signature_json: ?[]u8 = null;
    defer if (signature_json) |value| allocator.free(value);
    var format_json: ?[]u8 = null;
    defer if (format_json) |value| allocator.free(value);
    const first_has_signature = hasMember(first.value.object, "signature");
    const first_has_format = hasMember(first.value.object, "format");
    for (blocks[1..]) |bytes| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResponse,
        };
        defer parsed.deinit();
        if (parsed.value != .object or !isReasoningText(parsed.value.object)) return error.InvalidResponse;
        if (stringField(parsed.value.object, "text")) |value| {
            text.appendSlice(allocator, value) catch return error.OutOfMemory;
        }
        if (!first_has_signature and signature_json == null) {
            if (hasMember(parsed.value.object, "signature")) {
                const value = parsed.value.object.get("signature").?;
                signature_json = std.json.Stringify.valueAlloc(allocator, value, .{}) catch
                    return error.OutOfMemory;
            }
        }
        if (!first_has_format and format_json == null) {
            if (hasMember(parsed.value.object, "format")) {
                const value = parsed.value.object.get("format").?;
                format_json = std.json.Stringify.valueAlloc(allocator, value, .{}) catch
                    return error.OutOfMemory;
            }
        }
    }
    if (text.items.len != 0) {
        merged.put(allocator, "text", .{ .string = text.items }) catch return error.OutOfMemory;
    }

    var signature: ?std.json.Parsed(std.json.Value) = null;
    defer if (signature) |*value| value.deinit();
    if (signature_json) |bytes| {
        signature = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResponse,
        };
        merged.put(allocator, "signature", signature.?.value) catch return error.OutOfMemory;
    }
    var format: ?std.json.Parsed(std.json.Value) = null;
    defer if (format) |*value| value.deinit();
    if (format_json) |bytes| {
        format = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResponse,
        };
        merged.put(allocator, "format", format.?.value) catch return error.OutOfMemory;
    }

    const merged_value: std.json.Value = .{ .object = merged };
    const encoded = std.json.Stringify.valueAlloc(allocator, merged_value, .{}) catch
        return error.OutOfMemory;
    defer allocator.free(encoded);
    output.appendSlice(allocator, encoded) catch return error.OutOfMemory;
}

fn validateSseEvent(event: Transport.SseEvent, max_bytes: usize) Error!void {
    const name_len = if (event.event_name) |name| name.len else 0;
    const total = std.math.add(usize, name_len, event.data.len) catch return error.InvalidResponse;
    if (total > max_bytes) return error.InvalidResponse;
    if (event.event_name) |name| for (name) |byte| {
        if (byte == 0 or byte == '\r' or byte == '\n') return error.InvalidResponse;
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) error{InvalidResponse}!?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidResponse;
    return value.string;
}

fn optionalInteger(object: std.json.ObjectMap, name: []const u8) error{InvalidResponse}!?i64 {
    const value = object.get(name) orelse return null;
    if (value != .integer) return error.InvalidResponse;
    return value.integer;
}

fn assignCount(target: *?u64, object: std.json.ObjectMap, name: []const u8) Error!void {
    const value = object.get(name) orelse return;
    if (value != .integer or value.integer < 0) return error.InvalidResponse;
    target.* = @intCast(value.integer);
}

fn countOrZero(object: std.json.ObjectMap, name: []const u8) Error!u64 {
    const value = object.get(name) orelse return 0;
    if (value != .integer or value.integer < 0) return error.InvalidResponse;
    return @intCast(value.integer);
}

fn isReasoningText(object: std.json.ObjectMap) bool {
    const value = stringField(object, "type") orelse return false;
    return std.mem.eql(u8, value, "reasoning.text");
}

fn hasMember(object: std.json.ObjectMap, name: []const u8) bool {
    const value = object.get(name) orelse return false;
    if (value == .null) return false;
    return if (value == .string) value.string.len != 0 else true;
}

const Captured = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(OwnedEvent) = .empty,

    const OwnedEvent = union(enum) {
        text: []u8,
        reasoning_delta: []u8,
        reasoning_item: []u8,
        start: struct { id: []u8, name: []u8 },
        delta: struct { id: []u8, arguments: []u8 },
        end: []u8,
        progress: StreamEvent.Progress,
        done: struct { reason: []u8, usage: Usage.StreamUsage, response: OwnedIdentity },
        failure: struct { message: []u8, usage: ?Usage.StreamUsage, response: OwnedIdentity },
    };

    const OwnedIdentity = struct { id: ?[]u8 = null, model: ?[]u8 = null, route: ?[]u8 = null };

    fn deinit(self: *Captured) void {
        for (self.events.items) |event| switch (event) {
            .text, .reasoning_delta, .reasoning_item, .end => |value| self.allocator.free(value),
            .start => |value| {
                self.allocator.free(value.id);
                self.allocator.free(value.name);
            },
            .delta => |value| {
                self.allocator.free(value.id);
                self.allocator.free(value.arguments);
            },
            .done => |value| {
                self.allocator.free(value.reason);
                freeIdentity(self.allocator, value.response);
            },
            .failure => |value| {
                self.allocator.free(value.message);
                freeIdentity(self.allocator, value.response);
            },
            .progress => {},
        };
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn emit(self: *Captured, event: StreamEvent.StreamEvent) Provider.DeliveryError!void {
        const owned: OwnedEvent = switch (event) {
            .text_delta => |value| .{ .text = try tryDupe(self.allocator, value) },
            .reasoning_delta => |value| .{ .reasoning_delta = try tryDupe(self.allocator, value orelse "") },
            .reasoning_item => |value| .{ .reasoning_item = try tryDupe(self.allocator, value.opaque_json) },
            .tool_call_start => |value| .{ .start = .{
                .id = try tryDupe(self.allocator, value.id),
                .name = try tryDupe(self.allocator, value.name),
            } },
            .tool_call_delta => |value| .{ .delta = .{
                .id = try tryDupe(self.allocator, value.id),
                .arguments = try tryDupe(self.allocator, value.arguments_delta),
            } },
            .tool_call_end => |value| .{ .end = try tryDupe(self.allocator, value) },
            .progress => |value| .{ .progress = value },
            .done => |value| .{ .done = .{
                .reason = try tryDupe(self.allocator, value.stop_reason orelse ""),
                .usage = value.usage,
                .response = tryIdentity(self.allocator, value.response),
            } },
            .failure => |value| .{ .failure = .{
                .message = try tryDupe(self.allocator, value.message),
                .usage = value.usage,
                .response = tryIdentity(self.allocator, value.response orelse .{}),
            } },
            else => return,
        };
        self.events.append(self.allocator, owned) catch return error.Cancelled;
    }
};

fn tryDupe(allocator: std.mem.Allocator, value: []const u8) Provider.DeliveryError![]u8 {
    return allocator.dupe(u8, value) catch error.Cancelled;
}

fn tryIdentity(allocator: std.mem.Allocator, value: StreamEvent.ResponseIdentity) Captured.OwnedIdentity {
    return .{
        .id = if (value.id) |text| allocator.dupe(u8, text) catch null else null,
        .model = if (value.model) |text| allocator.dupe(u8, text) catch null else null,
        .route = if (value.route) |text| allocator.dupe(u8, text) catch null else null,
    };
}

fn freeIdentity(allocator: std.mem.Allocator, value: Captured.OwnedIdentity) void {
    if (value.id) |text| allocator.free(text);
    if (value.model) |text| allocator.free(text);
    if (value.route) |text| allocator.free(text);
}

fn testFeed(parser: *Parser, data: []const u8) Error!void {
    try parser.feed(.{ .data = data });
}

test "text reasoning identity usage progress and deferred finish" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{ .emit_progress = true });
    defer parser.deinit();
    try testFeed(&parser, "{\"id\":\"first\",\"model\":\"m\",\"provider\":\"route\"," ++
        "\"prompt_progress\":{\"processed\":2,\"total\":3,\"cache\":1}," ++
        "\"choices\":[{\"delta\":{\"reasoning\":\"think\",\"content\":\"answer\"}}]}");
    try testFeed(&parser, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}");
    try std.testing.expect(parser.isComplete());
    try std.testing.expectEqual(@as(usize, 3), capture.events.items.len);
    try testFeed(&parser, "{\"choices\":[],\"usage\":{\"prompt_tokens\":10," ++
        "\"completion_tokens\":2,\"cost\":0.25,\"prompt_tokens_details\":{\"cached_tokens\":4}}}");
    try testFeed(&parser, "[DONE]");
    try std.testing.expectEqual(@as(usize, 4), capture.events.items.len);
    const done = capture.events.items[3].done;
    try std.testing.expectEqualStrings("first", done.response.id.?);
    try std.testing.expectEqual(@as(?u64, 10), done.usage.input_tokens);
    try std.testing.expectEqual(@as(?f64, 0.25), done.usage.cost_usd);
}

test "reasoning details consolidate text and seal before content" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testFeed(&parser, "{\"choices\":[{\"delta\":{\"reasoning_details\":[" ++
        "{\"type\":\"reasoning.encrypted\",\"data\":\"aa\"}," ++
        "{\"type\":\"reasoning.text\",\"text\":\"Think\",\"format\":\"f\"}]}}]}");
    try testFeed(&parser, "{\"choices\":[{\"delta\":{\"reasoning_details\":[" ++
        "{\"type\":\"reasoning.text\",\"text\":\"ing\"}," ++
        "{\"type\":\"reasoning.text\",\"signature\":\"sig\"}]}}]}");
    try testFeed(&parser, "{\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}");
    try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
    try std.testing.expectEqualStrings(
        "[{\"type\":\"reasoning.encrypted\",\"data\":\"aa\"}," ++
            "{\"type\":\"reasoning.text\",\"text\":\"Thinking\",\"format\":\"f\",\"signature\":\"sig\"}]",
        capture.events.items[0].reasoning_item,
    );
}

test "tool metadata across deltas buffers arguments and synthesizes id" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testFeed(&parser, "{\"choices\":[{\"delta\":{\"tool_calls\":[{" ++
        "\"function\":{\"arguments\":\"{\\\"x\\\":\"}}]}}]}");
    try testFeed(&parser, "{\"choices\":[{\"delta\":{\"tool_calls\":[{" ++
        "\"function\":{\"name\":\"bash\",\"arguments\":\"1}\"}}]}}]}");
    try testFeed(&parser, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}");
    try testFeed(&parser, "[DONE]");
    try std.testing.expectEqual(@as(usize, 5), capture.events.items.len);
    try std.testing.expectEqualStrings("call_0", capture.events.items[0].start.id);
    try std.testing.expectEqualStrings("{\"x\":", capture.events.items[1].delta.arguments);
    try std.testing.expectEqualStrings("1}", capture.events.items[2].delta.arguments);
    try std.testing.expectEqualStrings("call_0", capture.events.items[3].end);
}

test "truncation finalize usage cache attribution and retry accounting" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{
        .cache_write_1h = true,
        .length_hint = "raise the output limit",
    });
    defer parser.deinit();
    try testFeed(&parser, "{\"choices\":[],\"usage\":{\"prompt_tokens\":8," ++
        "\"prompt_tokens_details\":{\"cache_write_tokens\":7}}}");
    try std.testing.expectEqual(@as(?u64, 8), parser.usage().?.input_tokens);
    try std.testing.expectEqual(@as(?u64, 7), parser.usage().?.cache_write_1h_tokens);
    try testFeed(&parser, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}");
    try parser.finalize();
    try std.testing.expectEqualStrings(
        "response incomplete: length: raise the output limit",
        capture.events.items[0].failure.message,
    );
}

test "unknown shapes ignore while malformed recognized shapes fail" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testFeed(&parser, "{}");
    try testFeed(&parser, "{\"future\":true}");
    const malformed = [_][]const u8{
        "not json",
        "[]",
        "{\"choices\":{}}",
        "{\"choices\":[{\"delta\":{\"content\":4}}]}",
        "{\"usage\":{\"prompt_tokens\":-1}}",
    };
    for (malformed) |json| try std.testing.expectError(error.InvalidResponse, testFeed(&parser, json));
}

test "incoherent open call bounds cancellation and sticky terminal" {
    const Reject = struct {
        const Self = @This();
        pub fn emit(_: *Self, _: StreamEvent.StreamEvent) Provider.DeliveryError!void {
            return error.Cancelled;
        }
    };
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testFeed(&parser, "{\"choices\":[{\"delta\":{\"tool_calls\":[{" ++
        "\"id\":\"c\",\"function\":{\"arguments\":\"{}\"}}]}}]}");
    try std.testing.expectError(error.InvalidResponse, testFeed(&parser, "[DONE]"));

    var reject: Reject = .{};
    var cancelled = try Parser.init(std.testing.allocator, Provider.EventSink.from(&reject), .{});
    defer cancelled.deinit();
    try std.testing.expectError(error.Cancelled, testFeed(&cancelled, "[DONE]"));
    try std.testing.expect(cancelled.isComplete());
    try testFeed(&cancelled, "not json");

    var bounded = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{
        .max_event_bytes = 8,
    });
    defer bounded.deinit();
    try std.testing.expectError(error.InvalidResponse, testFeed(&bounded, "123456789"));
}

test "many tiny reasoning fragments consolidate once at the seam" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    const fragment = "{\"choices\":[{\"delta\":{\"reasoning_details\":[{" ++
        "\"type\":\"reasoning.text\",\"text\":\"x\"}]}}]}";
    var index: usize = 0;
    while (index < 1000) : (index += 1) try testFeed(&parser, fragment);
    try testFeed(&parser, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}");
    try testFeed(&parser, "[DONE]");
    try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
    const replay = capture.events.items[0].reasoning_item;
    try std.testing.expect(std.mem.count(u8, replay, "x") >= 1000);
    try std.testing.expect(capture.events.items[1] == .done);
}

test "post-finish choices reject while trailing usage remains accepted" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testFeed(&parser, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}");
    try testFeed(&parser, "{\"choices\":[],\"usage\":{\"prompt_tokens\":2}}");
    try std.testing.expectError(error.InvalidResponse, testFeed(
        &parser,
        "{\"choices\":[{\"delta\":{\"content\":\"late\"}}]}",
    ));
    try std.testing.expectEqual(@as(?u64, 2), parser.usage().?.input_tokens);
}

test "incomplete finalize emits only failure and does not seal partial state" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testFeed(&parser, "{\"choices\":[{\"delta\":{\"reasoning_details\":[{" ++
        "\"type\":\"reasoning.text\",\"text\":\"partial\"}]}}]}");
    try std.testing.expectEqual(@as(usize, 0), capture.events.items.len);
    try parser.finalize();
    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    try std.testing.expect(capture.events.items[0] == .failure);

    var tool_capture: Captured = .{ .allocator = std.testing.allocator };
    defer tool_capture.deinit();
    var tool_parser = try Parser.init(
        std.testing.allocator,
        Provider.EventSink.from(&tool_capture),
        .{},
    );
    defer tool_parser.deinit();
    try testFeed(&tool_parser, "{\"choices\":[{\"delta\":{\"tool_calls\":[{" ++
        "\"index\":0,\"id\":\"call\",\"function\":{\"name\":\"bash\"}}]}}]}");
    try tool_parser.finalize();
    try std.testing.expectEqual(@as(usize, 2), tool_capture.events.items.len);
    try std.testing.expect(tool_capture.events.items[0] == .start);
    try std.testing.expect(tool_capture.events.items[1] == .failure);
}

fn exerciseParserAllocations(allocator: std.mem.Allocator) !void {
    const Sink = struct {
        const Self = @This();
        pub fn emit(_: *Self, _: StreamEvent.StreamEvent) Provider.DeliveryError!void {}
    };
    var sink: Sink = .{};
    var parser = try Parser.init(allocator, Provider.EventSink.from(&sink), .{});
    defer parser.deinit();
    try testFeed(&parser, "{\"id\":\"response\",\"model\":\"served\"," ++
        "\"provider\":\"route\",\"choices\":[{\"delta\":{" ++
        "\"reasoning_details\":[{\"type\":\"reasoning.text\"," ++
        "\"text\":\"a\",\"signature\":\"sig\"}],\"tool_calls\":[{" ++
        "\"index\":0,\"function\":{\"arguments\":\"{\"}}]}}]}");
    try testFeed(&parser, "{\"choices\":[{\"delta\":{\"tool_calls\":[{" ++
        "\"index\":0,\"id\":\"call\",\"function\":{\"name\":\"bash\"," ++
        "\"arguments\":\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}");
    try testFeed(&parser, "[DONE]");
}

test "parser releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseParserAllocations,
        .{},
    );
}

test "reasoning closing fields skip empty values and text stays absent" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    const parts = [_][]const u8{
        "{\"type\":\"reasoning.text\",\"signature\":null,\"format\":\"\"}",
        "{\"type\":\"reasoning.text\",\"signature\":\"\",\"format\":null}",
        "{\"type\":\"reasoning.text\",\"signature\":\"real\",\"format\":\"fmt\"}",
    };
    for (parts) |part| {
        const event = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"choices\":[{{\"delta\":{{\"reasoning_details\":[{s}]}}}}]}}",
            .{part},
        );
        defer std.testing.allocator.free(event);
        try testFeed(&parser, event);
    }
    try testFeed(&parser, "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}");
    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    const replay = capture.events.items[0].reasoning_item;
    try std.testing.expect(std.mem.find(u8, replay, "\"signature\":\"real\"") != null);
    try std.testing.expect(std.mem.find(u8, replay, "\"format\":\"fmt\"") != null);
    try std.testing.expect(std.mem.find(u8, replay, "\"text\"") == null);
}
