const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_api = @import("../agent/root.zig");
const ai_message = ai.message;
const Agent = agent_api.Agent;
const commit_api = agent_api.commit;
const format = @import("SessionFormat.zig");
const journal_api = @import("SessionJournal.zig");

const SessionCommit = @This();

pub const Error = error{
    OutOfMemory,
    SessionTooLarge,
    PersistenceFailed,
    CommitIndeterminate,
};

const EntryId = struct {
    bytes: [128]u8 = undefined,
    len: u8,

    fn init(value: []const u8) EntryId {
        var id: EntryId = .{ .len = @intCast(value.len) };
        @memcpy(id.bytes[0..value.len], value);
        return id;
    }

    fn slice(self: *const EntryId) []const u8 {
        return self.bytes[0..self.len];
    }
};

const TurnState = union(enum) {
    idle,
    active: EntryId,
};

const BindingState = union(enum) {
    restore_candidate: format.Restored,
    active,
};

allocator: std.mem.Allocator,
journal: journal_api,
sources: format.Sources,
faults: journal_api.Faults,
binding: BindingState,
turn: TurnState = .idle,

pub fn create(
    allocator: std.mem.Allocator,
    opened: *journal_api.Opened,
    sources: format.Sources,
    selection: ai_message.ModelIdentity,
    faults: journal_api.Faults,
) Error!*SessionCommit {
    var owned = opened.*;
    opened.* = undefined;
    var owned_live = true;
    errdefer if (owned_live) owned.deinit();
    const self = allocator.create(SessionCommit) catch return error.OutOfMemory;
    self.* = .{
        .allocator = allocator,
        .journal = owned.journal,
        .sources = sources,
        .faults = faults,
        .binding = .{ .restore_candidate = owned.restore_candidate },
    };
    owned_live = false;
    errdefer self.deinit();

    const restored = &self.binding.restore_candidate;
    switch (restored.recovery) {
        .clean => {},
        .interrupted => |interrupted| try self.appendTerminal(interrupted.turn_id, .interrupted),
    }
    if (restored.active_model == null or !sameModel(restored.active_model.?, selection)) {
        try self.appendModelChange(selection);
    }
    return self;
}

pub fn bindAgent(self: *SessionCommit, agent: *Agent) Error!void {
    const restored = &self.binding.restore_candidate;
    agent.bindCommits(restored.context_messages, self.sink()) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SessionTooLarge => return error.SessionTooLarge,
    };
    restored.deinit();
    self.binding = .active;
}

// Heap destruction follows explicit field invalidation.
// ziglint-ignore: Z030
pub fn deinit(self: *SessionCommit) void {
    const allocator = self.allocator;
    switch (self.binding) {
        .restore_candidate => |*restored| restored.deinit(),
        .active => {},
    }
    self.journal.deinit();
    self.* = undefined;
    allocator.destroy(self);
}

fn sink(self: *SessionCommit) commit_api.Sink {
    return .{
        .context = self,
        .messageFn = commitMessage,
        .settleFn = settleRun,
    };
}

fn commitMessage(
    context: *anyopaque,
    kind: commit_api.MessageKind,
    message: ai_message.Message,
) commit_api.Error!void {
    const self: *SessionCommit = @ptrCast(@alignCast(context));
    const stamp = self.sources.next() catch return error.PersistenceFailed;
    const entry: format.Entry = .{ .message = .{
        .base = stamp.base(self.journal.activeLeafId()),
        .message = message,
    } };
    self.journal.append(entry, self.faults) catch |failure| return mapJournalError(failure);
    if (kind == .user) self.turn = .{ .active = EntryId.init(stamp.id()) };
}

fn settleRun(context: *anyopaque, outcome: commit_api.RunOutcome) commit_api.Error!void {
    const self: *SessionCommit = @ptrCast(@alignCast(context));
    const turn_id = switch (self.turn) {
        .active => |*id| id.slice(),
        .idle => unreachable,
    };
    try self.appendTerminal(turn_id, mapOutcome(outcome));
    self.turn = .idle;
}

fn appendModelChange(self: *SessionCommit, selection: ai_message.ModelIdentity) Error!void {
    const stamp = self.sources.next() catch return error.PersistenceFailed;
    self.journal.append(.{ .model_change = .{
        .base = stamp.base(self.journal.activeLeafId()),
        .selection = selection,
    } }, self.faults) catch |failure| return mapJournalError(failure);
}

fn appendTerminal(self: *SessionCommit, turn_id: []const u8, outcome: format.TurnOutcome) Error!void {
    const stamp = self.sources.next() catch return error.PersistenceFailed;
    self.journal.append(.{ .turn_end = .{
        .base = stamp.base(self.journal.activeLeafId()),
        .turn_id = turn_id,
        .outcome = outcome,
    } }, self.faults) catch |failure| return mapJournalError(failure);
}

fn mapJournalError(failure: journal_api.Error) commit_api.Error {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.SessionTooLarge, error.TooManyEntries => error.SessionTooLarge,
        error.CommitIndeterminate => error.CommitIndeterminate,
        else => error.PersistenceFailed,
    };
}

fn mapOutcome(outcome: commit_api.RunOutcome) format.TurnOutcome {
    return switch (outcome) {
        .completed => .completed,
        .cancelled => .cancelled,
        .interrupted => .interrupted,
        .failed => |failure| .{ .failed = switch (failure) {
            .resource_exhausted => .resource_exhausted,
            .timed_out => .timed_out,
            .unsupported_capability => .unsupported_capability,
            .unsupported_setting => .unsupported_setting,
            .invalid_request => .invalid_request,
            .connection_failed => .connection_failed,
            .rate_limited => .rate_limited,
            .provider_rejected_request => .provider_rejected_request,
            .provider_unavailable => .provider_unavailable,
            .invalid_provider_response => .invalid_provider_response,
            .event_consumer_stopped => .stream_consumer_stopped,
            .handoff_rejected => .handoff_rejected,
            .max_model_requests_exceeded => .max_model_requests_exceeded,
            .max_tool_calls_exceeded => .max_tool_calls_exceeded,
            .tool_result_too_large => .tool_result_too_large,
            .tool_control_unavailable => .tool_control_unavailable,
            .persistence_failed => .persistence_failed,
        } },
    };
}

fn sameModel(left: ai_message.ModelIdentity, right: ai_message.ModelIdentity) bool {
    return std.mem.eql(u8, left.provider, right.provider) and
        std.mem.eql(u8, left.model, right.model);
}
