const std = @import("std");
const ai = @import("../ai/root.zig");

const log = std.log.scoped(.ai_completion);

pub const PreparedTextCompletionRequest = struct {
    provider: ai.provider.Provider,
    model: ai.protocol.Model,
    prompt: []const u8,
    system_prompt: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    headers: ?[]const ai.protocol.Header = null,
    max_tokens: ?u64 = null,
    reasoning: ?ai.protocol.ThinkingLevel = null,
};

pub const TextCompletionResult = union(enum) {
    completed: struct { text: []u8 },
    err: []u8,
    cancelled,

    pub fn deinit(self: *TextCompletionResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completed => |completed| allocator.free(completed.text),
            .err => |msg| allocator.free(msg),
            .cancelled => {},
        }
        self.* = undefined;
    }
};

pub fn runPreparedTextCompletion(
    result_allocator: std.mem.Allocator,
    request: PreparedTextCompletionRequest,
) TextCompletionResult {
    var stream_arena = std.heap.ArenaAllocator.init(result_allocator);
    defer stream_arena.deinit();
    const stream_allocator = stream_arena.allocator();

    const messages = [_]ai.protocol.Message{.{ .user = .{
        .content = .{ .text = request.prompt },
        .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
    } }};
    const context = ai.protocol.Context{
        .system_prompt = request.system_prompt,
        .messages = &messages,
    };

    var collector = CompletionCollector{ .allocator = result_allocator };
    request.provider.streamSimple(
        stream_allocator,
        request.model,
        context,
        .{
            .base = .{
                .api_key = request.api_key,
                .headers = request.headers,
                .max_tokens = request.max_tokens,
            },
            .reasoning = request.reasoning,
        },
        &CompletionCollector.callback,
        @ptrCast(&collector),
    );

    if (collector.error_message) |msg| return .{ .err = msg };
    return .{ .completed = .{ .text = collector.text orelse result_allocator.dupe(u8, "") catch return .cancelled } };
}

const CompletionCollector = struct {
    allocator: std.mem.Allocator,
    text: ?[]u8 = null,
    error_message: ?[]u8 = null,

    fn callback(event: ai.protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
        const self: *CompletionCollector = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .done => |done| {
                log.debug("provider done reason={s}", .{@tagName(done.reason)});
                self.text = collectText(self.allocator, done.message) catch null;
            },
            .@"error" => |err| {
                log.debug("provider error reason={s}", .{@tagName(err.reason)});
                const msg = err.@"error".error_message orelse "provider error";
                self.error_message = self.allocator.dupe(u8, msg) catch null;
            },
            else => {},
        }
    }

    fn collectText(allocator: std.mem.Allocator, msg: ai.protocol.AssistantMessage) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (msg.content) |block| switch (block) {
            .text => |text| try out.appendSlice(allocator, text.text),
            else => {},
        };
        return out.toOwnedSlice(allocator);
    }
};
