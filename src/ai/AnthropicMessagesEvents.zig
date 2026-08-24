const std = @import("std");
const Provider = @import("Provider.zig");
const StreamEvent = @import("StreamEvent.zig");
const Transport = @import("Transport.zig");
const Usage = @import("Usage.zig");

pub const maximum_tracked_blocks: usize = 128;
pub const maximum_owned_state_bytes: usize = 256 * 1024;
pub const maximum_event_bytes: usize = 1024 * 1024;
pub const maximum_json_depth: usize = 64;
pub const maximum_json_fields: usize = 4096;
pub const maximum_json_work: usize = 65_536;

pub const Options = struct {
    max_tracked_blocks: usize = maximum_tracked_blocks,
    max_owned_state_bytes: usize = maximum_owned_state_bytes,
    max_event_bytes: usize = maximum_event_bytes,
};

pub const Error = error{ OutOfMemory, Cancelled, InvalidResponse };

const BlockKind = enum { text, thinking, redacted_thinking, tool_use, other };

const Block = struct {
    index: i64,
    kind: BlockKind,
    tool_call_id: ?[]u8 = null,
    tool_name: ?[]u8 = null,
    thinking: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
    redacted_data: ?[]u8 = null,
    stopped: bool = false,
};

/// Fresh, owned translation state for one Anthropic Messages stream. Emitted
/// byte slices are borrowed and remain valid only during the synchronous sink call.
pub const Parser = struct {
    allocator: std.mem.Allocator,
    sink: Provider.EventSink,
    options: Options,
    blocks: std.ArrayList(Block) = .empty,
    owned_state_bytes: usize = 0,
    usage_value: Usage.StreamUsage = .{},
    response_id: ?[]u8 = null,
    served_model: ?[]u8 = null,
    stop_reason: ?[]u8 = null,
    message_started: bool = false,
    terminal_emitted: bool = false,

    pub fn init(allocator: std.mem.Allocator, sink: Provider.EventSink, options: Options) Error!Parser {
        if (options.max_tracked_blocks == 0 or
            options.max_tracked_blocks > maximum_tracked_blocks or
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
        for (self.blocks.items) |*block| {
            if (block.tool_call_id) |value| self.allocator.free(value);
            if (block.tool_name) |value| self.allocator.free(value);
            block.thinking.deinit(self.allocator);
            block.signature.deinit(self.allocator);
            if (block.redacted_data) |value| self.allocator.free(value);
        }
        self.blocks.deinit(self.allocator);
        if (self.response_id) |value| self.allocator.free(value);
        if (self.served_model) |value| self.allocator.free(value);
        if (self.stop_reason) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn feed(self: *Parser, event: Transport.SseEvent) Error!void {
        if (self.terminal_emitted) return;
        try validateSseEvent(event, self.options.max_event_bytes);
        if (event.data.len == 0) return;
        try validateJsonComplexity(event.data);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, event.data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResponse,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const root = parsed.value.object;
        const event_type = requiredString(root, "type") catch return error.InvalidResponse;
        if (event_type.len == 0) return error.InvalidResponse;

        if (std.mem.eql(u8, event_type, "message_start")) {
            try self.handleMessageStart(root);
        } else if (std.mem.eql(u8, event_type, "content_block_start")) {
            try self.handleBlockStart(root);
        } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
            try self.handleBlockDelta(root);
        } else if (std.mem.eql(u8, event_type, "content_block_stop")) {
            try self.handleBlockStop(root);
        } else if (std.mem.eql(u8, event_type, "message_delta")) {
            try self.handleMessageDelta(root);
        } else if (std.mem.eql(u8, event_type, "message_stop")) {
            try self.handleMessageStop();
        } else if (std.mem.eql(u8, event_type, "error")) {
            try self.handleError(root);
        }
    }

    pub fn finalize(self: *Parser) Error!void {
        if (!self.terminal_emitted) try self.emitFailure("stream ended before completion");
    }

    pub fn isComplete(self: *const Parser) bool {
        return self.terminal_emitted;
    }

    /// Usage seen so far belongs to this attempt and can be retained by retry.
    pub fn usage(self: *const Parser) ?Usage.StreamUsage {
        return self.reportedUsage();
    }

    pub fn recover(_: *Parser) Error!bool {
        return false;
    }

    fn handleMessageStart(self: *Parser, root: std.json.ObjectMap) Error!void {
        if (self.message_started) return error.InvalidResponse;
        const message = requiredObject(root, "message") catch return error.InvalidResponse;
        if (self.response_id == null) if (try optionalString(message, "id")) |value| {
            if (value.len != 0) self.response_id = try self.own(value);
        };
        if (self.served_model == null) if (try optionalString(message, "model")) |value| {
            if (value.len != 0) self.served_model = try self.own(value);
        };
        try self.captureUsageField(message);
        self.message_started = true;
    }

    fn handleBlockStart(self: *Parser, root: std.json.ObjectMap) Error!void {
        if (!self.message_started) return error.InvalidResponse;
        const index = try requiredIndex(root);
        if (self.findBlock(index) != null) return error.InvalidResponse;
        if (self.blocks.items.len >= self.options.max_tracked_blocks) return error.InvalidResponse;
        const content = requiredObject(root, "content_block") catch return error.InvalidResponse;
        const block_type = requiredString(content, "type") catch return error.InvalidResponse;
        if (block_type.len == 0) return error.InvalidResponse;
        const kind: BlockKind = if (std.mem.eql(u8, block_type, "text"))
            .text
        else if (std.mem.eql(u8, block_type, "thinking"))
            .thinking
        else if (std.mem.eql(u8, block_type, "redacted_thinking"))
            .redacted_thinking
        else if (std.mem.eql(u8, block_type, "tool_use"))
            .tool_use
        else
            .other;

        var block: Block = .{ .index = index, .kind = kind };
        var appended = false;
        errdefer if (!appended) {
            if (block.tool_call_id) |value| self.freeOwned(value);
            if (block.tool_name) |value| self.freeOwned(value);
            if (block.redacted_data) |value| self.freeOwned(value);
        };
        switch (kind) {
            .tool_use => {
                const id = requiredString(content, "id") catch return error.InvalidResponse;
                const name = requiredString(content, "name") catch return error.InvalidResponse;
                if (id.len == 0 or name.len == 0) return error.InvalidResponse;
                block.tool_call_id = try self.own(id);
                block.tool_name = try self.own(name);
            },
            .redacted_thinking => {
                const data = requiredString(content, "data") catch return error.InvalidResponse;
                if (data.len == 0) return error.InvalidResponse;
                block.redacted_data = try self.own(data);
            },
            else => {},
        }
        self.blocks.append(self.allocator, block) catch return error.OutOfMemory;
        appended = true;
        const added = &self.blocks.items[self.blocks.items.len - 1];
        switch (kind) {
            .thinking, .redacted_thinking => try self.emit(.{ .reasoning_delta = "" }),
            .tool_use => try self.emit(.{ .tool_call_start = .{
                .id = added.tool_call_id.?,
                .name = added.tool_name.?,
            } }),
            else => {},
        }
    }

    fn handleBlockDelta(self: *Parser, root: std.json.ObjectMap) Error!void {
        if (!self.message_started) return error.InvalidResponse;
        const index = try requiredIndex(root);
        const block = self.findBlock(index) orelse return error.InvalidResponse;
        if (block.stopped) return error.InvalidResponse;
        const delta = requiredObject(root, "delta") catch return error.InvalidResponse;
        const delta_type = requiredString(delta, "type") catch return error.InvalidResponse;
        if (delta_type.len == 0) return error.InvalidResponse;

        if (std.mem.eql(u8, delta_type, "text_delta")) {
            if (block.kind != .text) return error.InvalidResponse;
            const text = requiredString(delta, "text") catch return error.InvalidResponse;
            if (text.len != 0) try self.emit(.{ .text_delta = text });
        } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
            if (block.kind != .thinking) return error.InvalidResponse;
            const text = requiredString(delta, "thinking") catch return error.InvalidResponse;
            if (text.len != 0) {
                try self.appendOwned(&block.thinking, text);
                try self.emit(.{ .reasoning_delta = text });
            }
        } else if (std.mem.eql(u8, delta_type, "signature_delta")) {
            if (block.kind != .thinking) return error.InvalidResponse;
            const signature = requiredString(delta, "signature") catch return error.InvalidResponse;
            if (signature.len != 0) try self.appendOwned(&block.signature, signature);
        } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
            if (block.kind != .tool_use) return error.InvalidResponse;
            const partial = requiredString(delta, "partial_json") catch return error.InvalidResponse;
            if (partial.len != 0) try self.emit(.{ .tool_call_delta = .{
                .id = block.tool_call_id.?,
                .arguments_delta = partial,
            } });
        }
    }

    fn handleBlockStop(self: *Parser, root: std.json.ObjectMap) Error!void {
        if (!self.message_started) return error.InvalidResponse;
        const index = try requiredIndex(root);
        const block = self.findBlock(index) orelse return error.InvalidResponse;
        if (block.stopped) return error.InvalidResponse;
        block.stopped = true;
        switch (block.kind) {
            .tool_use => try self.emit(.{ .tool_call_end = block.tool_call_id.? }),
            .thinking => try self.emitThinkingItem(block),
            .redacted_thinking => try self.emitRedactedItem(block),
            else => {},
        }
        self.releaseBlockPayload(block);
    }

    fn emitThinkingItem(self: *Parser, block: *const Block) Error!void {
        if (block.thinking.items.len == 0 and block.signature.items.len == 0) return;
        const Replay = struct {
            type: []const u8 = "thinking",
            thinking: []const u8,
            signature: []const u8,
        };
        const replay: Replay = .{
            .thinking = block.thinking.items,
            .signature = block.signature.items,
        };
        const json = std.json.Stringify.valueAlloc(self.allocator, replay, .{}) catch
            return error.OutOfMemory;
        defer self.allocator.free(json);
        try self.emit(.{ .reasoning_item = .{ .opaque_json = json } });
    }

    fn emitRedactedItem(self: *Parser, block: *const Block) Error!void {
        const Replay = struct {
            type: []const u8 = "redacted_thinking",
            data: []const u8,
        };
        const replay: Replay = .{ .data = block.redacted_data.? };
        const json = std.json.Stringify.valueAlloc(self.allocator, replay, .{}) catch
            return error.OutOfMemory;
        defer self.allocator.free(json);
        try self.emit(.{ .reasoning_item = .{ .opaque_json = json } });
    }

    fn handleMessageDelta(self: *Parser, root: std.json.ObjectMap) Error!void {
        if (!self.message_started) return error.InvalidResponse;
        const delta = requiredObject(root, "delta") catch return error.InvalidResponse;
        if (try optionalString(delta, "stop_reason")) |reason| {
            if (reason.len == 0) return error.InvalidResponse;
            try self.replaceOwned(&self.stop_reason, reason);
        }
        try self.captureUsageField(root);
    }

    fn handleMessageStop(self: *Parser) Error!void {
        if (!self.message_started) return error.InvalidResponse;
        if (self.hasOpenBlocks()) return error.InvalidResponse;
        const reason = self.stop_reason orelse "end_turn";
        if (std.mem.eql(u8, reason, "max_tokens")) {
            return self.emitFailure(
                "response incomplete: max_tokens: " ++
                    "raise the provider's max_tokens or lower the effort level",
            );
        }
        if (std.mem.eql(u8, reason, "pause_turn")) {
            return self.emitFailure("response paused before completion (pause_turn)");
        }
        self.terminal_emitted = true;
        try self.emit(.{ .done = .{
            .stop_reason = reason,
            .usage = self.usage_value,
            .response = self.responseIdentity(),
        } });
    }

    fn handleError(self: *Parser, root: std.json.ObjectMap) Error!void {
        const error_object = requiredObject(root, "error") catch return error.InvalidResponse;
        const message = (try optionalString(error_object, "message")) orelse "provider error";
        try self.emitFailure(message);
    }

    fn emitFailure(self: *Parser, message: []const u8) Error!void {
        if (self.terminal_emitted) return;
        self.terminal_emitted = true;
        try self.emit(.{ .failure = .{
            .message = message,
            .usage = self.reportedUsage(),
            .response = self.responseIdentity(),
        } });
    }

    fn captureUsageField(self: *Parser, object: std.json.ObjectMap) Error!void {
        const value = object.get("usage") orelse return;
        if (value == .null) return;
        if (value != .object) return error.InvalidResponse;
        const usage_object = value.object;
        const input = try optionalCount(usage_object, "input_tokens");
        const cached = try optionalCount(usage_object, "cache_read_input_tokens");
        const written = try optionalCount(usage_object, "cache_creation_input_tokens");
        if (input) |base| {
            var total = base;
            if (cached) |count| {
                if (count > 0) total +|= count;
            }
            if (written) |count| {
                if (count > 0) total +|= count;
            }
            self.usage_value.input_tokens = total;
        }
        if (cached) |count| self.usage_value.cached_tokens = count;
        if (written) |count| self.usage_value.cache_write_tokens = count;
        if (try optionalCount(usage_object, "output_tokens")) |count| self.usage_value.output_tokens = count;
        if (usage_object.get("cache_creation")) |creation_value| {
            if (creation_value == .null) return;
            if (creation_value != .object) return error.InvalidResponse;
            if (try optionalCount(creation_value.object, "ephemeral_1h_input_tokens")) |count| {
                self.usage_value.cache_write_1h_tokens = count;
            }
        }
    }

    fn reportedUsage(self: *const Parser) ?Usage.StreamUsage {
        return if (Usage.usageReported(self.usage_value)) self.usage_value else null;
    }

    fn responseIdentity(self: *const Parser) StreamEvent.ResponseIdentity {
        return .{ .id = self.response_id, .model = self.served_model };
    }

    fn hasOpenBlocks(self: *const Parser) bool {
        for (self.blocks.items) |block| if (!block.stopped) return true;
        return false;
    }

    fn findBlock(self: *Parser, index: i64) ?*Block {
        for (self.blocks.items) |*block| if (block.index == index) return block;
        return null;
    }

    fn emit(self: *Parser, event: StreamEvent.StreamEvent) Error!void {
        self.sink.emit(event) catch return error.Cancelled;
    }

    fn own(self: *Parser, value: []const u8) Error![]u8 {
        try self.reserveOwned(value.len);
        return self.allocator.dupe(u8, value) catch |err| {
            self.owned_state_bytes -= value.len;
            return err;
        };
    }

    fn freeOwned(self: *Parser, value: []u8) void {
        self.owned_state_bytes -= value.len;
        self.allocator.free(value);
    }

    fn releaseBlockPayload(self: *Parser, block: *Block) void {
        if (block.tool_call_id) |value| {
            self.freeOwned(value);
            block.tool_call_id = null;
        }
        if (block.tool_name) |value| {
            self.freeOwned(value);
            block.tool_name = null;
        }
        if (block.thinking.items.len != 0) self.owned_state_bytes -= block.thinking.items.len;
        block.thinking.deinit(self.allocator);
        block.thinking = .empty;
        if (block.signature.items.len != 0) self.owned_state_bytes -= block.signature.items.len;
        block.signature.deinit(self.allocator);
        block.signature = .empty;
        if (block.redacted_data) |value| {
            self.freeOwned(value);
            block.redacted_data = null;
        }
    }

    fn appendOwned(self: *Parser, list: *std.ArrayList(u8), value: []const u8) Error!void {
        try self.reserveOwned(value.len);
        list.ensureTotalCapacityPrecise(self.allocator, list.items.len + value.len) catch |err| {
            self.owned_state_bytes -= value.len;
            return err;
        };
        list.appendSliceAssumeCapacity(value);
    }

    fn replaceOwned(self: *Parser, target: *?[]u8, value: []const u8) Error!void {
        const old_len = if (target.*) |old| old.len else 0;
        const base = self.owned_state_bytes - old_len;
        const total = std.math.add(usize, base, value.len) catch return error.InvalidResponse;
        if (total > self.options.max_owned_state_bytes) return error.InvalidResponse;
        const replacement = self.allocator.dupe(u8, value) catch return error.OutOfMemory;
        if (target.*) |old| self.allocator.free(old);
        self.owned_state_bytes = total;
        target.* = replacement;
    }

    fn reserveOwned(self: *Parser, count: usize) Error!void {
        const total = std.math.add(usize, self.owned_state_bytes, count) catch return error.InvalidResponse;
        if (total > self.options.max_owned_state_bytes) return error.InvalidResponse;
        self.owned_state_bytes = total;
    }
};

fn validateJsonComplexity(bytes: []const u8) Error!void {
    var depth: usize = 0;
    var fields: usize = 0;
    var work: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                work += 1;
                if (depth > maximum_json_depth) return error.InvalidResponse;
            },
            '}', ']' => {
                if (depth > 0) depth -= 1;
            },
            ':' => {
                fields += 1;
                work += 1;
                if (fields > maximum_json_fields) return error.InvalidResponse;
            },
            ',' => work += 1,
            else => {},
        }
        if (work > maximum_json_work) return error.InvalidResponse;
    }
}

fn validateSseEvent(event: Transport.SseEvent, maximum_bytes: usize) Error!void {
    const name_len = if (event.event_name) |name| name.len else 0;
    const total = std.math.add(usize, name_len, event.data.len) catch return error.InvalidResponse;
    if (total > maximum_bytes) return error.InvalidResponse;
    if (event.event_name) |name| for (name) |byte| {
        if (byte == 0 or byte == '\r' or byte == '\n') return error.InvalidResponse;
    };
}

fn requiredObject(object: std.json.ObjectMap, name: []const u8) error{InvalidResponse}!std.json.ObjectMap {
    const value = object.get(name) orelse return error.InvalidResponse;
    if (value != .object) return error.InvalidResponse;
    return value.object;
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) error{InvalidResponse}![]const u8 {
    const value = object.get(name) orelse return error.InvalidResponse;
    if (value != .string) return error.InvalidResponse;
    return value.string;
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) error{InvalidResponse}!?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidResponse;
    return value.string;
}

fn requiredIndex(object: std.json.ObjectMap) Error!i64 {
    const value = object.get("index") orelse return error.InvalidResponse;
    if (value != .integer or value.integer < 0) return error.InvalidResponse;
    return value.integer;
}

fn optionalCount(object: std.json.ObjectMap, name: []const u8) Error!?u64 {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return error.InvalidResponse;
    return @intCast(value.integer);
}

const Captured = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(OwnedEvent) = .empty,

    const OwnedIdentity = struct { id: ?[]u8 = null, model: ?[]u8 = null };
    const OwnedEvent = union(enum) {
        text: []u8,
        reasoning_delta: []u8,
        reasoning_item: []u8,
        start: struct { id: []u8, name: []u8 },
        delta: struct { id: []u8, arguments: []u8 },
        end: []u8,
        done: struct { reason: []u8, usage: Usage.StreamUsage, identity: OwnedIdentity },
        failure: struct { message: []u8, usage: ?Usage.StreamUsage, identity: OwnedIdentity },
    };

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
                freeIdentity(self.allocator, value.identity);
            },
            .failure => |value| {
                self.allocator.free(value.message);
                freeIdentity(self.allocator, value.identity);
            },
        };
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn emit(self: *Captured, event: StreamEvent.StreamEvent) Provider.DeliveryError!void {
        const owned: OwnedEvent = switch (event) {
            .text_delta => |value| .{ .text = try dupeForSink(self.allocator, value) },
            .reasoning_delta => |value| .{ .reasoning_delta = try dupeForSink(self.allocator, value orelse "") },
            .reasoning_item => |value| .{ .reasoning_item = try dupeForSink(self.allocator, value.opaque_json) },
            .tool_call_start => |value| .{ .start = .{
                .id = try dupeForSink(self.allocator, value.id),
                .name = try dupeForSink(self.allocator, value.name),
            } },
            .tool_call_delta => |value| .{ .delta = .{
                .id = try dupeForSink(self.allocator, value.id),
                .arguments = try dupeForSink(self.allocator, value.arguments_delta),
            } },
            .tool_call_end => |value| .{ .end = try dupeForSink(self.allocator, value) },
            .done => |value| .{ .done = .{
                .reason = try dupeForSink(self.allocator, value.stop_reason orelse ""),
                .usage = value.usage,
                .identity = try sinkIdentity(self.allocator, value.response),
            } },
            .failure => |value| .{ .failure = .{
                .message = try dupeForSink(self.allocator, value.message),
                .usage = value.usage,
                .identity = try sinkIdentity(self.allocator, value.response orelse .{}),
            } },
            else => return,
        };
        self.events.append(self.allocator, owned) catch return error.Cancelled;
    }
};

fn dupeForSink(allocator: std.mem.Allocator, value: []const u8) Provider.DeliveryError![]u8 {
    return allocator.dupe(u8, value) catch error.Cancelled;
}

fn sinkIdentity(
    allocator: std.mem.Allocator,
    identity: StreamEvent.ResponseIdentity,
) Provider.DeliveryError!Captured.OwnedIdentity {
    var result: Captured.OwnedIdentity = .{};
    errdefer freeIdentity(allocator, result);
    if (identity.id) |value| result.id = try dupeForSink(allocator, value);
    if (identity.model) |value| result.model = try dupeForSink(allocator, value);
    return result;
}

fn freeIdentity(allocator: std.mem.Allocator, identity: Captured.OwnedIdentity) void {
    if (identity.id) |value| allocator.free(value);
    if (identity.model) |value| allocator.free(value);
}

fn testFeed(parser: *Parser, data: []const u8) Error!void {
    try parser.feed(.{ .data = data });
}

fn testBegin(parser: *Parser) Error!void {
    try testFeed(parser, "{\"type\":\"message_start\",\"message\":{}}");
}

test "text tools reasoning and redacted blocks translate exactly" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testBegin(&parser);
    try testFeed(&parser, "{\"type\":\"content_block_start\",\"index\":0," ++
        "\"content_block\":{\"type\":\"text\",\"text\":\"\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_delta\",\"index\":0," ++
        "\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_stop\",\"index\":0}");
    try testFeed(&parser, "{\"type\":\"content_block_start\",\"index\":1," ++
        "\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_delta\",\"index\":1," ++
        "\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Think\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_delta\",\"index\":1," ++
        "\"delta\":{\"type\":\"signature_delta\",\"signature\":\"SIG\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_stop\",\"index\":1}");
    try testFeed(&parser, "{\"type\":\"content_block_start\",\"index\":2," ++
        "\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"ENC\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_stop\",\"index\":2}");
    try testFeed(&parser, "{\"type\":\"content_block_start\",\"index\":3," ++
        "\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"bash\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_delta\",\"index\":3," ++
        "\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_stop\",\"index\":3}");

    try std.testing.expectEqual(@as(usize, 9), capture.events.items.len);
    try std.testing.expectEqualStrings("Hello", capture.events.items[0].text);
    try std.testing.expectEqualStrings("", capture.events.items[1].reasoning_delta);
    try std.testing.expectEqualStrings("Think", capture.events.items[2].reasoning_delta);
    try std.testing.expectEqualStrings(
        "{\"type\":\"thinking\",\"thinking\":\"Think\",\"signature\":\"SIG\"}",
        capture.events.items[3].reasoning_item,
    );
    try std.testing.expectEqualStrings("", capture.events.items[4].reasoning_delta);
    try std.testing.expectEqualStrings(
        "{\"type\":\"redacted_thinking\",\"data\":\"ENC\"}",
        capture.events.items[5].reasoning_item,
    );
    try std.testing.expectEqualStrings("toolu_1", capture.events.items[6].start.id);
    try std.testing.expectEqualStrings("{}", capture.events.items[7].delta.arguments);
    try std.testing.expectEqualStrings("toolu_1", capture.events.items[8].end);
}

test "signature-only reasoning round trips and empty thinking does not" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testBegin(&parser);
    try testFeed(&parser, "{\"type\":\"content_block_start\",\"index\":0," ++
        "\"content_block\":{\"type\":\"thinking\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_stop\",\"index\":0}");
    try testFeed(&parser, "{\"type\":\"content_block_start\",\"index\":1," ++
        "\"content_block\":{\"type\":\"thinking\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_delta\",\"index\":1," ++
        "\"delta\":{\"type\":\"signature_delta\",\"signature\":\"OPAQUE\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_stop\",\"index\":1}");
    try std.testing.expectEqual(@as(usize, 3), capture.events.items.len);
    try std.testing.expectEqualStrings(
        "{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"OPAQUE\"}",
        capture.events.items[2].reasoning_item,
    );
}

test "identity and additive cache usage merge into terminal" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testFeed(&parser, "{\"type\":\"message_start\",\"message\":{" ++
        "\"id\":\"msg_1\",\"model\":\"claude-snapshot\",\"usage\":{" ++
        "\"input_tokens\":100,\"cache_read_input_tokens\":40," ++
        "\"cache_creation_input_tokens\":10,\"cache_creation\":{" ++
        "\"ephemeral_1h_input_tokens\":7},\"output_tokens\":0}}}");
    try std.testing.expectEqual(@as(?u64, 150), parser.usage().?.input_tokens);
    try testFeed(&parser, "{\"type\":\"message_delta\",\"delta\":{" ++
        "\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":25}}");
    try testFeed(&parser, "{\"type\":\"message_stop\"}");
    const done = capture.events.items[0].done;
    try std.testing.expectEqualStrings("end_turn", done.reason);
    try std.testing.expectEqualStrings("msg_1", done.identity.id.?);
    try std.testing.expectEqualStrings("claude-snapshot", done.identity.model.?);
    try std.testing.expectEqual(@as(?u64, 150), done.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 40), done.usage.cached_tokens);
    try std.testing.expectEqual(@as(?u64, 10), done.usage.cache_write_tokens);
    try std.testing.expectEqual(@as(?u64, 7), done.usage.cache_write_1h_tokens);
    try std.testing.expectEqual(@as(?u64, 25), done.usage.output_tokens);
}

test "cache addition saturates and cache-only fragments stay partial" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testFeed(&parser, "{\"type\":\"message_start\",\"message\":{\"usage\":{" ++
        "\"input_tokens\":9223372036854775807," ++
        "\"cache_read_input_tokens\":9223372036854775807," ++
        "\"cache_creation_input_tokens\":1}}}");
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), parser.usage().?.input_tokens);
}

test "max tokens pause error provider error and finalize retain accounting" {
    const cases = [_]struct { delta: ?[]const u8, needs_stop: bool = false, message: []const u8 }{
        .{
            .delta = "{\"type\":\"message_delta\"," ++
                "\"delta\":{\"stop_reason\":\"max_tokens\"}}",
            .needs_stop = true,
            .message = "response incomplete: max_tokens: " ++
                "raise the provider's max_tokens or lower the effort level",
        },
        .{
            .delta = "{\"type\":\"message_delta\"," ++
                "\"delta\":{\"stop_reason\":\"pause_turn\"}}",
            .needs_stop = true,
            .message = "response paused before completion (pause_turn)",
        },
        .{ .delta = "{\"type\":\"error\",\"error\":{\"message\":\"Overloaded\"}}", .message = "Overloaded" },
        .{ .delta = null, .message = "stream ended before completion" },
    };
    for (cases) |case| {
        var capture: Captured = .{ .allocator = std.testing.allocator };
        defer capture.deinit();
        var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
        defer parser.deinit();
        try testFeed(&parser, "{\"type\":\"message_start\",\"message\":{" ++
            "\"id\":\"id\",\"usage\":{\"input_tokens\":2}}}");
        if (case.delta) |delta| {
            try testFeed(&parser, delta);
            if (case.needs_stop) try testFeed(&parser, "{\"type\":\"message_stop\"}");
        } else try parser.finalize();
        try parser.finalize();
        try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
        const failure = capture.events.items[0].failure;
        try std.testing.expectEqualStrings(case.message, failure.message);
        try std.testing.expectEqual(@as(?u64, 2), failure.usage.?.input_tokens);
        try std.testing.expectEqualStrings("id", failure.identity.id.?);
    }
}

test "unknown events and block types are forward compatible" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    try testFeed(&parser, "{\"type\":\"ping\"}");
    try testFeed(&parser, "{\"type\":\"future_event\",\"payload\":true}");
    try testBegin(&parser);
    try testFeed(&parser, "{\"type\":\"content_block_start\",\"index\":9," ++
        "\"content_block\":{\"type\":\"future_block\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_delta\",\"index\":9," ++
        "\"delta\":{\"type\":\"future_delta\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_stop\",\"index\":9}");
    try std.testing.expectEqual(@as(usize, 0), capture.events.items.len);
}

test "malformed and out-of-order recognized events are rejected" {
    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer parser.deinit();
    const malformed = [_][]const u8{
        "not json",
        "[]",
        "{}",
        "{\"type\":1}",
        "{\"type\":\"message_start\"}",
        "{\"type\":\"content_block_start\",\"index\":-1,\"content_block\":{\"type\":\"text\"}}",
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}",
        "{\"type\":\"content_block_stop\",\"index\":0}",
        "{\"type\":\"message_delta\",\"delta\":[],\"usage\":{}}",
        "{\"type\":\"error\",\"error\":[]}",
    };
    for (malformed) |json| try std.testing.expectError(error.InvalidResponse, testFeed(&parser, json));
    try testBegin(&parser);
    try std.testing.expectError(error.InvalidResponse, testBegin(&parser));
    const start = "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\"}}";
    try testFeed(&parser, start);
    try std.testing.expectError(error.InvalidResponse, testFeed(&parser, start));
    try std.testing.expectError(error.InvalidResponse, testFeed(&parser, "{\"type\":\"message_stop\"}"));
    try testFeed(&parser, "{\"type\":\"content_block_stop\",\"index\":1}");
    try std.testing.expectError(error.InvalidResponse, testFeed(
        &parser,
        "{\"type\":\"content_block_stop\",\"index\":1}",
    ));
}

test "bounds validation cancellation and late events are explicit" {
    const Reject = struct {
        const Self = @This();
        pub fn emit(_: *Self, _: StreamEvent.StreamEvent) Provider.DeliveryError!void {
            return error.Cancelled;
        }
    };
    var reject: Reject = .{};
    var bounded = try Parser.init(std.testing.allocator, Provider.EventSink.from(&reject), .{
        .max_event_bytes = 8,
    });
    defer bounded.deinit();
    try std.testing.expectError(error.InvalidResponse, testFeed(&bounded, "123456789"));
    try std.testing.expectError(error.InvalidResponse, bounded.feed(.{ .event_name = "bad\n", .data = "{}" }));

    var cancelled = try Parser.init(std.testing.allocator, Provider.EventSink.from(&reject), .{});
    defer cancelled.deinit();
    try testBegin(&cancelled);
    try std.testing.expectError(error.Cancelled, testFeed(&cancelled, "{\"type\":\"content_block_start\"," ++
        "\"index\":0,\"content_block\":{\"type\":\"thinking\"}}"));

    var capture: Captured = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var complete = try Parser.init(std.testing.allocator, Provider.EventSink.from(&capture), .{});
    defer complete.deinit();
    try std.testing.expectError(error.InvalidResponse, testFeed(&complete, "{\"type\":\"message_stop\"}"));
    try testBegin(&complete);
    try testFeed(&complete, "{\"type\":\"message_stop\"}");
    try testFeed(&complete, "not json");
    try std.testing.expect(complete.isComplete());
    try std.testing.expect(!try complete.recover());
    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
}

fn exerciseParserAllocations(allocator: std.mem.Allocator) !void {
    const Sink = struct {
        const Self = @This();
        pub fn emit(_: *Self, _: StreamEvent.StreamEvent) Provider.DeliveryError!void {}
    };
    var sink: Sink = .{};
    var parser = try Parser.init(allocator, Provider.EventSink.from(&sink), .{});
    defer parser.deinit();
    try testFeed(&parser, "{\"type\":\"message_start\",\"message\":{" ++
        "\"id\":\"message\",\"model\":\"model\",\"usage\":{\"input_tokens\":1}}}");
    try testFeed(&parser, "{\"type\":\"content_block_start\",\"index\":0," ++
        "\"content_block\":{\"type\":\"thinking\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_delta\",\"index\":0," ++
        "\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"thought\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_delta\",\"index\":0," ++
        "\"delta\":{\"type\":\"signature_delta\",\"signature\":\"signature\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_stop\",\"index\":0}");
    try testFeed(&parser, "{\"type\":\"content_block_start\",\"index\":1," ++
        "\"content_block\":{\"type\":\"tool_use\",\"id\":\"call\",\"name\":\"bash\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_stop\",\"index\":1}");
    try testFeed(&parser, "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}");
    try testFeed(&parser, "{\"type\":\"message_stop\"}");
}

test "parser releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseParserAllocations,
        .{},
    );
}

test "block and owned-state caps are enforced" {
    const Sink = struct {
        const Self = @This();
        pub fn emit(_: *Self, _: StreamEvent.StreamEvent) Provider.DeliveryError!void {}
    };
    var sink: Sink = .{};
    try std.testing.expectError(error.InvalidResponse, Parser.init(
        std.testing.allocator,
        Provider.EventSink.from(&sink),
        .{ .max_tracked_blocks = 0 },
    ));
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&sink), .{
        .max_tracked_blocks = 1,
        .max_owned_state_bytes = 4,
    });
    defer parser.deinit();
    try testBegin(&parser);
    try testFeed(&parser, "{\"type\":\"content_block_start\",\"index\":0," ++
        "\"content_block\":{\"type\":\"text\"}}");
    try std.testing.expectError(error.InvalidResponse, testFeed(
        &parser,
        "{\"type\":\"content_block_start\",\"index\":1," ++
            "\"content_block\":{\"type\":\"text\"}}",
    ));

    var owned = try Parser.init(std.testing.allocator, Provider.EventSink.from(&sink), .{
        .max_owned_state_bytes = 4,
    });
    defer owned.deinit();
    try std.testing.expectError(error.InvalidResponse, testFeed(
        &owned,
        "{\"type\":\"message_start\",\"message\":{\"id\":\"12345\"}}",
    ));
}

test "recognized field types and block kinds are validated" {
    const Sink = struct {
        const Self = @This();
        pub fn emit(_: *Self, _: StreamEvent.StreamEvent) Provider.DeliveryError!void {}
    };
    var sink: Sink = .{};
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&sink), .{});
    defer parser.deinit();
    try std.testing.expectError(error.InvalidResponse, testFeed(
        &parser,
        "{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":-1}}}",
    ));
    try testBegin(&parser);
    try testFeed(&parser, "{\"type\":\"content_block_start\",\"index\":0," ++
        "\"content_block\":{\"type\":\"text\"}}");
    try std.testing.expectError(error.InvalidResponse, testFeed(
        &parser,
        "{\"type\":\"content_block_delta\",\"index\":0," ++
            "\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"x\"}}",
    ));
    try std.testing.expectError(error.InvalidResponse, testFeed(
        &parser,
        "{\"type\":\"content_block_delta\",\"index\":0," ++
            "\"delta\":{\"type\":\"text_delta\",\"text\":1}}",
    ));
}

test "message lifecycle JSON complexity and stopped-state reclamation are bounded" {
    const Sink = struct {
        const Self = @This();
        pub fn emit(_: *Self, _: StreamEvent.StreamEvent) Provider.DeliveryError!void {}
    };
    var sink: Sink = .{};
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&sink), .{
        .max_owned_state_bytes = 4,
    });
    defer parser.deinit();
    try testBegin(&parser);
    try testFeed(&parser, "{\"type\":\"content_block_start\",\"index\":0," ++
        "\"content_block\":{\"type\":\"thinking\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_delta\",\"index\":0," ++
        "\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"1234\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_stop\",\"index\":0}");
    try std.testing.expectEqual(@as(usize, 0), parser.owned_state_bytes);
    try testFeed(&parser, "{\"type\":\"content_block_start\",\"index\":1," ++
        "\"content_block\":{\"type\":\"thinking\"}}");
    try testFeed(&parser, "{\"type\":\"content_block_delta\",\"index\":1," ++
        "\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"5678\"}}");

    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(std.testing.allocator);
    try deep.appendSlice(std.testing.allocator, "{\"type\":\"future\",\"value\":");
    try deep.appendNTimes(std.testing.allocator, '[', maximum_json_depth + 1);
    try deep.appendNTimes(std.testing.allocator, ']', maximum_json_depth + 1);
    try deep.append(std.testing.allocator, '}');
    var fresh = try Parser.init(std.testing.allocator, Provider.EventSink.from(&sink), .{});
    defer fresh.deinit();
    try std.testing.expectError(error.InvalidResponse, fresh.feed(.{ .data = deep.items }));
}

test "event field and structural work thresholds reject before DOM parsing" {
    const Sink = struct {
        const Self = @This();
        pub fn emit(_: *Self, _: StreamEvent.StreamEvent) Provider.DeliveryError!void {}
    };
    var sink: Sink = .{};
    var parser = try Parser.init(std.testing.allocator, Provider.EventSink.from(&sink), .{});
    defer parser.deinit();

    var fields: std.ArrayList(u8) = .empty;
    defer fields.deinit(std.testing.allocator);
    try fields.appendSlice(std.testing.allocator, "{\"type\":\"future\",\"payload\":{");
    for (0..maximum_json_fields) |index| {
        if (index != 0) try fields.append(std.testing.allocator, ',');
        try fields.appendSlice(std.testing.allocator, "\"f\":0");
    }
    try fields.appendSlice(std.testing.allocator, "}}");
    try std.testing.expectError(error.InvalidResponse, parser.feed(.{ .data = fields.items }));

    var work: std.ArrayList(u8) = .empty;
    defer work.deinit(std.testing.allocator);
    try work.appendSlice(std.testing.allocator, "{\"type\":\"future\",\"payload\":[");
    for (0..maximum_json_work) |index| {
        if (index != 0) try work.append(std.testing.allocator, ',');
        try work.append(std.testing.allocator, '0');
    }
    try work.appendSlice(std.testing.allocator, "]}");
    try std.testing.expectError(error.InvalidResponse, parser.feed(.{ .data = work.items }));
}
