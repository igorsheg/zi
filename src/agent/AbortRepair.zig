const std = @import("std");
const ai = @import("../ai/root.zig");
const SessionModule = @import("Session.zig");
const TurnModule = @import("Turn.zig");

const Item = ai.Item.Item;
const Session = SessionModule.Session;
const Turn = TurnModule.Turn;

pub const Reason = enum {
    user_cancel,
    provider_error,
};

pub const Outcome = struct {
    marker_placed: bool = false,
    items_from: usize,
    items_to: usize,
};

pub const Error = error{
    OutOfMemory,
    SessionBusy,
    TooManyItems,
    UserTextTooLarge,
    ProviderIdTooLarge,
    ModelIdTooLarge,
    LabelTooLarge,
    EffortTooLarge,
    PresetTooLarge,
    RetainedDataTooLarge,
    TooManyImages,
    ImageDataTooLarge,
    ProvenanceTooLarge,
    TurnStillStreaming,
    TurnNeedsRepair,
    InvalidItem,
    InvalidItemIndex,
    InvalidUsage,
};

/// Repairs one failed provider turn into a canonical batch and commits it
/// atomically. Until the session commit succeeds, the source turn is unchanged.
pub fn repairAndAbsorb(
    allocator: std.mem.Allocator,
    session: *Session,
    turn: *Turn,
    reason: Reason,
) Error!Outcome {
    return repairAndAbsorbWithBoundary(allocator, session, turn, reason, false);
}

pub fn repairAndAbsorbWithBoundary(
    allocator: std.mem.Allocator,
    session: *Session,
    turn: *Turn,
    reason: Reason,
    prepend_boundary: bool,
) Error!Outcome {
    const initial_count = session.items().len;
    if (reason == .user_cancel and !survivesCancel(turn)) {
        if (!prepend_boundary) {
            turn.reset();
            return .{ .items_from = initial_count, .items_to = initial_count };
        }
        const boundary = [_]Item{.turn_boundary};
        const absorbed = try session.absorbItemsCopy(&boundary);
        turn.reset();
        return .{ .items_from = absorbed.items_from + 1, .items_to = absorbed.items_from + 1 };
    }

    var prepared: std.ArrayList(Item) = .empty;
    defer {
        for (prepared.items) |*item| item.deinit(allocator);
        prepared.deinit(allocator);
    }
    try prepared.ensureUnusedCapacity(
        allocator,
        turn.items.items.len + 1 + @as(usize, @intFromBool(prepend_boundary)),
    );
    if (prepend_boundary) prepared.appendAssumeCapacity(.turn_boundary);
    const response_start = prepared.items.len;

    var kept_text = turn.has_text;
    for (turn.items.items) |item| {
        if (reason == .provider_error and item != .assistant_message) continue;
        var cloned = try item.clone(allocator);
        errdefer cloned.deinit(allocator);
        if (cloned == .assistant_message) kept_text = true;
        try prepared.append(allocator, cloned);
    }

    const had_partial_text = turn.has_text;
    var marker_placed = false;
    if (had_partial_text) {
        try appendAssistant(
            allocator,
            &prepared,
            turn.text.items,
            true,
        );
        marker_placed = true;
    }

    const assembled_count = prepared.items.len - response_start;
    if (reason == .user_cancel) {
        for (prepared.items[response_start .. response_start + assembled_count]) |item| {
            if (item != .tool_call) continue;
            try appendSkippedResult(allocator, &prepared, item.tool_call.id);
            marker_placed = true;
        }
    }

    if (!marker_placed and (reason == .user_cancel or kept_text)) {
        if (lastAssistant(&prepared)) |assistant| {
            try appendMarker(allocator, assistant);
        } else {
            try appendAssistant(allocator, &prepared, "", false);
        }
        marker_placed = true;
    }

    const absorbed = try session.absorbItemsCopy(prepared.items);
    turn.reset();
    return .{
        .marker_placed = marker_placed,
        .items_from = absorbed.items_from + response_start,
        .items_to = absorbed.items_from + response_start + assembled_count,
    };
}

fn survivesCancel(turn: *const Turn) bool {
    if (turn.has_text) return true;
    for (turn.items.items) |item| {
        if (item == .assistant_message or item == .tool_call) return true;
    }
    return false;
}

fn appendAssistant(
    allocator: std.mem.Allocator,
    prepared: *std.ArrayList(Item),
    text: []const u8,
    partial: bool,
) error{OutOfMemory}!void {
    const suffix = if (partial) "\n" ++ SessionModule.interrupt_marker else SessionModule.interrupt_marker;
    const marked = try std.mem.concat(allocator, u8, &.{ text, suffix });
    errdefer allocator.free(marked);
    try prepared.append(allocator, .{ .assistant_message = .{
        .text = marked,
        .origin = .interrupted,
    } });
}

fn appendSkippedResult(
    allocator: std.mem.Allocator,
    prepared: *std.ArrayList(Item),
    call_id: []const u8,
) error{OutOfMemory}!void {
    const owned_id = try allocator.dupe(u8, call_id);
    errdefer allocator.free(owned_id);
    const output = try allocator.dupe(u8, SessionModule.interrupt_marker);
    errdefer allocator.free(output);
    try prepared.append(allocator, .{ .tool_result = .{
        .call_id = owned_id,
        .output = output,
        .origin = .skipped,
    } });
}

fn lastAssistant(prepared: *std.ArrayList(Item)) ?*ai.Item.AssistantMessage {
    var index = prepared.items.len;
    while (index > 0) {
        index -= 1;
        if (prepared.items[index] == .assistant_message) {
            return &prepared.items[index].assistant_message;
        }
    }
    return null;
}

fn appendMarker(
    allocator: std.mem.Allocator,
    assistant: *ai.Item.AssistantMessage,
) error{OutOfMemory}!void {
    const marked = try std.mem.concat(
        allocator,
        u8,
        &.{ assistant.text, "\n" ++ SessionModule.interrupt_marker },
    );
    allocator.free(assistant.text);
    assistant.text = marked;
    assistant.origin = .interrupted;
}

fn failedTurn(allocator: std.mem.Allocator) Turn {
    var turn = Turn.init(allocator, .{});
    turn.state = .failed;
    return turn;
}

test "provider error with no streamed content leaves no trace" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var turn = failedTurn(std.testing.allocator);
    defer turn.deinit();

    const outcome = try repairAndAbsorb(
        std.testing.allocator,
        &session,
        &turn,
        .provider_error,
    );
    try std.testing.expectEqual(@as(usize, 0), outcome.items_from);
    try std.testing.expectEqual(@as(usize, 0), outcome.items_to);
    try std.testing.expect(!outcome.marker_placed);
}

test "provider error keeps partial assistant text and drops completed calls" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();
    try turn.consume(.{ .text_delta = "partial" });
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "read" } });
    try turn.consume(.{ .tool_call_end = "call" });
    try turn.consume(.{ .failure = .{ .message = "failed" } });

    const outcome = try repairAndAbsorb(
        std.testing.allocator,
        &session,
        &turn,
        .provider_error,
    );
    try std.testing.expect(outcome.marker_placed);
    try std.testing.expectEqual(@as(usize, 1), session.items().len);
    try std.testing.expectEqualStrings(
        "partial\n[interrupted]",
        session.items()[0].assistant_message.text,
    );
    try std.testing.expectEqual(
        ai.Item.AssistantOrigin.interrupted,
        session.items()[0].assistant_message.origin,
    );
}

test "user cancel with no text or call evaporates reasoning" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();
    try turn.consume(.{ .reasoning_delta = "open" });

    const outcome = try repairAndAbsorb(
        std.testing.allocator,
        &session,
        &turn,
        .user_cancel,
    );
    try std.testing.expectEqual(outcome.items_from, outcome.items_to);
    try std.testing.expectEqual(@as(usize, 0), session.items().len);
}

test "user cancel fabricates skipped results for completed calls" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "read" } });
    try turn.consume(.{ .tool_call_end = "call" });
    try turn.consume(.{ .failure = .{ .message = "cancelled" } });

    const outcome = try repairAndAbsorb(
        std.testing.allocator,
        &session,
        &turn,
        .user_cancel,
    );
    try std.testing.expect(outcome.marker_placed);
    try std.testing.expectEqual(@as(usize, 0), outcome.items_from);
    try std.testing.expectEqual(@as(usize, 1), outcome.items_to);
    try std.testing.expectEqual(@as(usize, 2), session.items().len);
    try std.testing.expectEqualStrings("call", session.items()[1].tool_result.call_id);
    try std.testing.expectEqualStrings("[interrupted]", session.items()[1].tool_result.output);
    try std.testing.expectEqual(ai.Item.ToolResultOrigin.skipped, session.items()[1].tool_result.origin);
}

test "cancel preserves sealed reasoning and marks sealed assistant text" {
    var session = try Session.init(std.testing.allocator, .{
        .provider_id = "provider",
        .model = "model",
    });
    defer session.deinit();
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();
    try turn.consume(.{ .reasoning_delta = "sealed reasoning" });
    try turn.consume(.{ .text_delta = "sealed text" });
    try turn.consume(.{ .failure = .{ .message = "cancelled" } });

    _ = try repairAndAbsorb(std.testing.allocator, &session, &turn, .user_cancel);
    try std.testing.expectEqual(@as(usize, 2), session.items().len);
    try std.testing.expectEqualStrings("provider", session.items()[0].reasoning.source.?.provider.?);
    try std.testing.expectEqualStrings(
        "sealed text\n[interrupted]",
        session.items()[1].assistant_message.text,
    );
}

fn exerciseRepairAllocations(allocator: std.mem.Allocator) !void {
    var session = try Session.init(allocator, .{ .provider_id = "provider", .model = "model" });
    defer session.deinit();
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();
    try turn.consume(.{ .reasoning_delta = "reasoning" });
    try turn.consume(.{ .text_delta = "text" });
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "read" } });
    try turn.consume(.{ .tool_call_end = "call" });
    try turn.consume(.{ .failure = .{ .message = "cancelled" } });
    _ = try repairAndAbsorb(allocator, &session, &turn, .user_cancel);
}

test "abort repair frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRepairAllocations,
        .{},
    );
}

test "cancelled text and call range excludes synthesized result" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();
    try turn.consume(.{ .text_delta = "before" });
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "read" } });
    try turn.consume(.{ .tool_call_end = "call" });

    const outcome = try repairAndAbsorb(std.testing.allocator, &session, &turn, .user_cancel);
    try std.testing.expectEqual(@as(usize, 0), outcome.items_from);
    try std.testing.expectEqual(@as(usize, 2), outcome.items_to);
    try std.testing.expectEqual(@as(usize, 3), session.items().len);
    try std.testing.expectEqualStrings("before", session.items()[0].assistant_message.text);
    try std.testing.expect(session.items()[1] == .tool_call);
    try std.testing.expect(session.items()[2] == .tool_result);
}

test "repair admission failure keeps call and result out together" {
    var session = try Session.init(std.testing.allocator, .{
        .limits = .{ .items = 1 },
    });
    defer session.deinit();
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "read" } });
    try turn.consume(.{ .tool_call_end = "call" });

    try std.testing.expectError(
        error.TooManyItems,
        repairAndAbsorb(std.testing.allocator, &session, &turn, .user_cancel),
    );
    try std.testing.expectEqual(@as(usize, 0), session.items().len);
    try std.testing.expectEqual(@as(usize, 1), turn.items.items.len);
}

test "repair OOM is atomic across preparation and session commit" {
    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var session = try Session.init(failing.allocator(), .{});
        defer session.deinit();
        var turn = Turn.init(std.testing.allocator, .{});
        defer turn.deinit();
        try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "read" } });
        try turn.consume(.{ .tool_call_end = "call" });

        if (repairAndAbsorb(failing.allocator(), &session, &turn, .user_cancel)) |_| {
            try std.testing.expectEqual(@as(usize, 2), session.items().len);
            try std.testing.expectEqual(@as(usize, 0), turn.items.items.len);
            break;
        } else |failure| {
            try std.testing.expectEqual(error.OutOfMemory, failure);
            try std.testing.expectEqual(@as(usize, 0), session.items().len);
            try std.testing.expectEqual(@as(usize, 1), turn.items.items.len);
        }
    } else return error.TestUnexpectedResult;
}
