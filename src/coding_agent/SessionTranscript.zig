const std = @import("std");
const ai = @import("../ai/root.zig");
const session_format = @import("SessionFormat.zig");

const SessionTranscript = @This();

pub const Error = error{
    OutOfMemory,
    InvalidTranscript,
};

pub const DurableMetadata = struct {
    entry_id: []const u8,
    timestamp: []const u8,
};

pub const Metadata = union(enum) {
    durable: DurableMetadata,
    recovered_open_turn,
};

pub const Interrupted = struct {
    turn_id: []const u8,
};

pub const UserTurn = struct {
    parts: []const ai.message.UserContent,
};

pub const ToolResults = struct {
    results: []const ai.message.ToolResult,
};

pub const Content = union(enum) {
    model_change: ai.message.ModelIdentity,
    user: UserTurn,
    assistant: ai.message.ResponseMessage,
    tool_results: ToolResults,
    failure: struct {
        turn_id: []const u8,
        category: session_format.FailureCategory,
    },
    cancelled: struct { turn_id: []const u8 },
    interrupted: Interrupted,
};

pub const Item = struct {
    metadata: Metadata,
    content: Content,
};

arena: std.heap.ArenaAllocator,
items: []const Item,

/// Builds an owned presentation-neutral projection of the restored active
/// branch. The result remains valid after the journal restoration is released.
pub fn init(
    allocator: std.mem.Allocator,
    restored: *const session_format.Restored,
) Error!SessionTranscript {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();

    var by_id: std.StringHashMapUnmanaged(usize) = .empty;
    defer by_id.deinit(allocator);
    try by_id.ensureTotalCapacity(allocator, @intCast(restored.entries.len));
    for (restored.entries, 0..) |entry, index| {
        const id = entry.base().id;
        if (by_id.contains(id)) return error.InvalidTranscript;
        by_id.putAssumeCapacity(id, index);
    }

    var path: std.ArrayList(usize) = .empty;
    defer path.deinit(allocator);
    if (restored.active_leaf_id) |leaf_id| {
        var index = by_id.get(leaf_id) orelse return error.InvalidTranscript;
        while (true) {
            if (path.items.len >= restored.entries.len) return error.InvalidTranscript;
            try path.append(allocator, index);
            const parent_id = restored.entries[index].base().parent_id orelse break;
            index = by_id.get(parent_id) orelse return error.InvalidTranscript;
        }
        std.mem.reverse(usize, path.items);
    } else if (restored.entries.len != 0) {
        return error.InvalidTranscript;
    }

    var projected: std.ArrayList(Item) = .empty;
    for (path.items) |index| {
        const entry = restored.entries[index];
        const content: ?Content = switch (entry) {
            .model_change => |change| .{ .model_change = try ai.message.copyIdentityLeaky(
                memory,
                change.selection,
            ) },
            .message => |message_entry| switch (message_entry.message) {
                .response => |response| .{
                    .assistant = try ai.message.copyResponseLeaky(memory, response),
                },
                .request => |request| switch (try classifyRequest(request)) {
                    .user => .{ .user = try copyUserTurnLeaky(memory, request) },
                    .tool_results => .{
                        .tool_results = try copyToolResultsLeaky(memory, request),
                    },
                },
            },
            .turn_end => |terminal| switch (terminal.outcome) {
                .completed => null,
                .failed => |category| .{ .failure = .{
                    .turn_id = try memory.dupe(u8, terminal.turn_id),
                    .category = category,
                } },
                .cancelled => .{ .cancelled = .{
                    .turn_id = try memory.dupe(u8, terminal.turn_id),
                } },
                .interrupted => .{ .interrupted = .{
                    .turn_id = try memory.dupe(u8, terminal.turn_id),
                } },
            },
        };
        if (content) |value| try projected.append(memory, .{
            .metadata = try copyMetadataLeaky(memory, entry.base()),
            .content = value,
        });
    }

    switch (restored.recovery) {
        .clean => {},
        .interrupted => |interrupted| try projected.append(memory, .{
            .metadata = .recovered_open_turn,
            .content = .{ .interrupted = .{
                .turn_id = try memory.dupe(u8, interrupted.turn_id),
            } },
        }),
    }

    return .{
        .arena = arena,
        .items = projected.items,
    };
}

/// Deep-copies a transcript into storage owned by the returned value.
pub fn clone(
    self: *const SessionTranscript,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!SessionTranscript {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const items = try memory.alloc(Item, self.items.len);
    for (self.items, items) |item, *copy| {
        copy.* = .{
            .metadata = try cloneMetadataLeaky(memory, item.metadata),
            .content = try cloneContentLeaky(memory, item.content),
        };
    }
    return .{ .arena = arena, .items = items };
}

pub fn deinit(self: *SessionTranscript) void {
    self.arena.deinit();
    self.* = undefined;
}

fn cloneMetadataLeaky(
    allocator: std.mem.Allocator,
    metadata: Metadata,
) error{OutOfMemory}!Metadata {
    return switch (metadata) {
        .durable => |durable| .{ .durable = .{
            .entry_id = try allocator.dupe(u8, durable.entry_id),
            .timestamp = try allocator.dupe(u8, durable.timestamp),
        } },
        .recovered_open_turn => .recovered_open_turn,
    };
}

fn cloneContentLeaky(
    allocator: std.mem.Allocator,
    content: Content,
) error{OutOfMemory}!Content {
    return switch (content) {
        .model_change => |identity| .{
            .model_change = try ai.message.copyIdentityLeaky(allocator, identity),
        },
        .user => |user| result: {
            const parts = try allocator.alloc(ai.message.UserContent, user.parts.len);
            for (user.parts, parts) |part, *copy| {
                copy.* = try ai.message.copyUserContentLeaky(allocator, part);
            }
            break :result .{ .user = .{ .parts = parts } };
        },
        .assistant => |response| .{
            .assistant = try ai.message.copyResponseLeaky(allocator, response),
        },
        .tool_results => |tool_results| result: {
            const results = try allocator.alloc(ai.message.ToolResult, tool_results.results.len);
            for (tool_results.results, results) |tool_result, *copy| {
                copy.* = try ai.message.copyToolResultLeaky(allocator, tool_result);
            }
            break :result .{ .tool_results = .{ .results = results } };
        },
        .failure => |failure| .{ .failure = .{
            .turn_id = try allocator.dupe(u8, failure.turn_id),
            .category = failure.category,
        } },
        .cancelled => |cancelled| .{ .cancelled = .{
            .turn_id = try allocator.dupe(u8, cancelled.turn_id),
        } },
        .interrupted => |interrupted| .{ .interrupted = .{
            .turn_id = try allocator.dupe(u8, interrupted.turn_id),
        } },
    };
}

const RequestKind = enum {
    user,
    tool_results,
};

fn classifyRequest(request: ai.message.RequestMessage) Error!RequestKind {
    if (request.parts.len == 0) return error.InvalidTranscript;
    var kind: ?RequestKind = null;
    for (request.parts) |part| {
        const current: RequestKind = switch (part) {
            .user => .user,
            .tool_result => .tool_results,
            .retry_prompt => return error.InvalidTranscript,
        };
        if (kind) |existing| {
            if (existing != current) return error.InvalidTranscript;
        } else {
            kind = current;
        }
    }
    return kind.?;
}

fn copyUserTurnLeaky(
    allocator: std.mem.Allocator,
    request: ai.message.RequestMessage,
) error{OutOfMemory}!UserTurn {
    const parts = try allocator.alloc(ai.message.UserContent, request.parts.len);
    for (request.parts, parts) |part, *copy| {
        copy.* = try ai.message.copyUserContentLeaky(allocator, part.user);
    }
    return .{ .parts = parts };
}

fn copyToolResultsLeaky(
    allocator: std.mem.Allocator,
    request: ai.message.RequestMessage,
) error{OutOfMemory}!ToolResults {
    const results = try allocator.alloc(ai.message.ToolResult, request.parts.len);
    for (request.parts, results) |part, *copy| {
        copy.* = try ai.message.copyToolResultLeaky(allocator, part.tool_result);
    }
    return .{ .results = results };
}

fn copyMetadataLeaky(
    allocator: std.mem.Allocator,
    base: session_format.EntryBase,
) error{OutOfMemory}!Metadata {
    return .{ .durable = .{
        .entry_id = try allocator.dupe(u8, base.id),
        .timestamp = try allocator.dupe(u8, base.timestamp),
    } };
}

fn restoredView(
    entries: []const session_format.Entry,
    active_leaf_id: ?[]const u8,
    recovery: session_format.Recovery,
) session_format.Restored {
    return .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .header = .{ .id = "session", .timestamp = "time", .cwd = "/tmp" },
        .entries = entries,
        .active_leaf_id = active_leaf_id,
        .active_model = null,
        .context_messages = &.{},
        .recovery = recovery,
    };
}

test "transcript projects only the restored active branch" {
    const entries = [_]session_format.Entry{
        .{ .model_change = .{
            .base = .{ .id = "model", .parent_id = null, .timestamp = "t0" },
            .selection = .{ .provider = "script", .model = "model-a" },
        } },
        .{ .message = .{
            .base = .{ .id = "main-user", .parent_id = "model", .timestamp = "t1" },
            .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "main" } }} } },
        } },
        .{ .turn_end = .{
            .base = .{ .id = "main-end", .parent_id = "main-user", .timestamp = "t2" },
            .turn_id = "main-user",
            .outcome = .cancelled,
        } },
        .{ .message = .{
            .base = .{ .id = "branch-user", .parent_id = "model", .timestamp = "t3" },
            .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "branch" } }} } },
        } },
        .{ .turn_end = .{
            .base = .{ .id = "branch-end", .parent_id = "branch-user", .timestamp = "t4" },
            .turn_id = "branch-user",
            .outcome = .{ .failed = .connection_failed },
        } },
    };
    var restored = restoredView(&entries, "branch-end", .clean);
    defer restored.deinit();
    var transcript = try SessionTranscript.init(std.testing.allocator, &restored);
    defer transcript.deinit();

    try std.testing.expectEqual(@as(usize, 3), transcript.items.len);
    try std.testing.expect(transcript.items[0].content == .model_change);
    try std.testing.expectEqualStrings(
        "branch",
        transcript.items[1].content.user.parts[0].text,
    );
    try std.testing.expect(transcript.items[2].content == .failure);
    try std.testing.expectEqual(
        session_format.FailureCategory.connection_failed,
        transcript.items[2].content.failure.category,
    );
}

test "transcript retains assistant and tool facts after source mutation" {
    var user_text = [_]u8{ 'f', 'i', 'x' };
    var assistant_text = [_]u8{ 'd', 'o', 'n', 'e' };
    var tool_text = [_]u8{ 'o', 'k' };
    const entries = [_]session_format.Entry{
        .{ .message = .{
            .base = .{ .id = "user", .parent_id = null, .timestamp = "t0" },
            .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = &user_text } }} } },
        } },
        .{ .message = .{
            .base = .{ .id = "tool-call", .parent_id = "user", .timestamp = "t1" },
            .message = .{ .response = .{
                .parts = &.{.{ .tool_call = .{
                    .id = "call",
                    .name = "read",
                    .arguments_json = "{}",
                } }},
                .identity = .{ .provider = "script", .model = "model" },
            } },
        } },
        .{ .message = .{
            .base = .{ .id = "tool-result", .parent_id = "tool-call", .timestamp = "t2" },
            .message = .{ .request = .{ .parts = &.{.{ .tool_result = .{
                .call_id = "call",
                .name = "read",
                .content = &.{.{ .text = &tool_text }},
                .outcome = .success,
            } }} } },
        } },
        .{ .message = .{
            .base = .{ .id = "assistant", .parent_id = "tool-result", .timestamp = "t3" },
            .message = .{ .response = .{
                .parts = &.{.{ .text = .{ .text = &assistant_text } }},
                .identity = .{ .provider = "script", .model = "model" },
            } },
        } },
        .{ .turn_end = .{
            .base = .{ .id = "end", .parent_id = "assistant", .timestamp = "t4" },
            .turn_id = "user",
            .outcome = .completed,
        } },
    };
    var restored = restoredView(&entries, "end", .clean);
    defer restored.deinit();
    var transcript = try SessionTranscript.init(std.testing.allocator, &restored);
    defer transcript.deinit();
    @memset(&user_text, 'x');
    @memset(&assistant_text, 'x');
    @memset(&tool_text, 'x');

    try std.testing.expectEqual(@as(usize, 4), transcript.items.len);
    try std.testing.expectEqualStrings("fix", transcript.items[0].content.user.parts[0].text);
    try std.testing.expect(transcript.items[1].content == .assistant);
    try std.testing.expectEqualStrings(
        "ok",
        transcript.items[2].content.tool_results.results[0].content[0].text,
    );
    try std.testing.expectEqualStrings(
        "done",
        transcript.items[3].content.assistant.parts[0].text.text,
    );
}

test "transcript preserves durable cancellation and interruption terminals" {
    const cases = [_]struct {
        outcome: session_format.TurnOutcome,
        expected: std.meta.Tag(Content),
    }{
        .{ .outcome = .cancelled, .expected = .cancelled },
        .{ .outcome = .interrupted, .expected = .interrupted },
    };
    for (cases) |case| {
        const entries = [_]session_format.Entry{
            .{ .message = .{
                .base = .{ .id = "turn", .parent_id = null, .timestamp = "t0" },
                .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "prompt" } }} } },
            } },
            .{ .turn_end = .{
                .base = .{ .id = "end", .parent_id = "turn", .timestamp = "t1" },
                .turn_id = "turn",
                .outcome = case.outcome,
            } },
        };
        var restored = restoredView(&entries, "end", .clean);
        defer restored.deinit();
        var transcript = try SessionTranscript.init(std.testing.allocator, &restored);
        defer transcript.deinit();

        try std.testing.expectEqual(@as(usize, 2), transcript.items.len);
        try std.testing.expectEqual(case.expected, std.meta.activeTag(transcript.items[1].content));
        try std.testing.expect(transcript.items[1].metadata == .durable);
    }
}

test "transcript marks a recovered open turn as synthetic interruption" {
    const entries = [_]session_format.Entry{.{ .message = .{
        .base = .{ .id = "open-turn", .parent_id = null, .timestamp = "t0" },
        .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "unfinished" } }} } },
    } }};
    var restored = restoredView(
        &entries,
        "open-turn",
        .{ .interrupted = .{ .turn_id = "open-turn" } },
    );
    defer restored.deinit();
    var transcript = try SessionTranscript.init(std.testing.allocator, &restored);
    defer transcript.deinit();

    try std.testing.expectEqual(@as(usize, 2), transcript.items.len);
    const interruption = transcript.items[1];
    try std.testing.expect(interruption.content == .interrupted);
    try std.testing.expect(interruption.metadata == .recovered_open_turn);
    try std.testing.expectEqualStrings("open-turn", interruption.content.interrupted.turn_id);
}

fn projectForAllocationFailure(allocator: std.mem.Allocator) !void {
    const entries = [_]session_format.Entry{
        .{ .model_change = .{
            .base = .{ .id = "model", .parent_id = null, .timestamp = "t0" },
            .selection = .{ .provider = "script", .model = "allocation" },
        } },
        .{ .message = .{
            .base = .{ .id = "user", .parent_id = "model", .timestamp = "t1" },
            .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "prompt" } }} } },
        } },
        .{ .message = .{
            .base = .{ .id = "assistant", .parent_id = "user", .timestamp = "t2" },
            .message = .{ .response = .{
                .parts = &.{.{ .text = .{
                    .text = "answer",
                    .provider_state = .{
                        .provider = "script",
                        .protocol = "test",
                        .value = .{ .string = "opaque" },
                    },
                } }},
                .identity = .{ .provider = "script", .model = "allocation" },
            } },
        } },
    };
    var restored = restoredView(
        &entries,
        "assistant",
        .{ .interrupted = .{ .turn_id = "user" } },
    );
    defer restored.deinit();
    var transcript = try SessionTranscript.init(allocator, &restored);
    transcript.deinit();
}

test "transcript settles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        projectForAllocationFailure,
        .{},
    );
}

fn cloneForAllocationFailure(allocator: std.mem.Allocator) !void {
    const entries = [_]session_format.Entry{.{ .message = .{
        .base = .{ .id = "user", .parent_id = null, .timestamp = "t0" },
        .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "secret" } }} } },
    } }};
    var restored = restoredView(&entries, "user", .clean);
    defer restored.deinit();
    var source = try SessionTranscript.init(std.testing.allocator, &restored);
    defer source.deinit();
    var copy = try source.clone(allocator);
    defer copy.deinit();
    try std.testing.expectEqualStrings("secret", copy.items[0].content.user.parts[0].text);
}

test "transcript clone owns nested data and settles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        cloneForAllocationFailure,
        .{},
    );
}

test "transcript rejects missing leaves and mixed request roles" {
    const mixed = [_]session_format.Entry{.{ .message = .{
        .base = .{ .id = "mixed", .parent_id = null, .timestamp = "t0" },
        .message = .{ .request = .{ .parts = &.{
            .{ .user = .{ .text = "question" } },
            .{ .tool_result = .{
                .call_id = "call",
                .name = "read",
                .content = &.{.{ .text = "result" }},
                .outcome = .success,
            } },
        } } },
    } }};
    var missing = restoredView(&.{}, "missing", .clean);
    defer missing.deinit();
    try std.testing.expectError(
        error.InvalidTranscript,
        SessionTranscript.init(std.testing.allocator, &missing),
    );
    var invalid = restoredView(&mixed, "mixed", .clean);
    defer invalid.deinit();
    try std.testing.expectError(
        error.InvalidTranscript,
        SessionTranscript.init(std.testing.allocator, &invalid),
    );
}
