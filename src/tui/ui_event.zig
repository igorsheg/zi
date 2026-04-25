const std = @import("std");
const ai = @import("../ai/root.zig");
const conversation_state_mod = @import("../agent3/conversation_state.zig");
const runtime_host_mod = @import("../coding_agent/runtime_host.zig");
const model_registry_mod = @import("../coding_agent/model_registry.zig");
const ai_protocol = @import("../ai/protocol.zig");
const theme_mod = @import("theme.zig");
const RunOutcome = runtime_host_mod.RunOutcome;

pub const ExtensionCommandEntry = struct {
    name: []u8,
    description: []u8,
};

/// TUI-owned event type. All cross-thread payloads are deep-copied and
/// mailbox-owned. Conversation changes cross as authoritative mailbox snapshots.
pub const UiEvent = union(enum) {
    consumed: void,

    // --- conversation transport ---
    conversation_snapshot: conversation_state_mod.ConversationSnapshotEnvelope,
    queued_snapshot: runtime_host_mod.QueuedMessageSnapshot,

    // --- errors / status side effects ---
    error_message: struct { message: []u8 },
    theme_changed: theme_mod.Theme,
    assistant_run_finished: struct {
        is_aborted: bool,
        error_message: ?[]u8,
        failure_kind: ?ai.protocol.NormalizedFailure.Kind = null,
    },
    tool_running: struct {
        tool_name: []u8,
    },

    // --- login lifecycle ---
    // zi-wub.17: login thread publishes progress/auth-url through the
    // event queue instead of mutating status_text directly. Single-owner
    // invariant restored for status_text — only the TUI thread writes.
    login_progress: struct {
        message: []u8,
        kind: enum { info, auth_url },
    },
    login_complete: struct {
        provider_id: []u8,
        success: bool,
        message: []u8,
    },

    // --- retry lifecycle ---
    retry_start: struct {
        attempt: u32,
        max_attempts: u32,
        delay_ms: u64,
        error_message: []u8,
    },
    retry_wait_finished: void,
    retry_end: struct {
        success: bool,
        attempt: u32,
        final_error: ?[]u8 = null,
        failure_kind: ?ai.protocol.NormalizedFailure.Kind = null,
    },

    // --- prompt lifecycle ---
    prompt_worker_finished: struct {
        outcome: RunOutcome,
        internal_error: ?[]u8 = null,
    },

    // --- request drain lifecycle ---
    // Emitted by the long-lived agent owner thread after it finishes a
    // non-prompt AgentRequest drain. Separate from `prompt_worker_finished`
    // so the TUI can unwind request-mode loaders without stomping on
    // status_text or focus that the individual request handlers already set.
    request_worker_finished: void,

    // --- /resume outcomes ---
    // Banner-only outcome. Transcript state now crosses separately via
    // `conversation_state` so resume no longer ships raw AgentMessage[]
    // through this event.
    session_resumed: struct {
        restore_warning: ?[]u8 = null,
    },
    session_resume_failed: struct {
        message: []u8,
    },

    extension_commands_updated: struct {
        commands: []ExtensionCommandEntry,
    },

    visible_models_snapshot: struct {
        models: []ai_protocol.Model,
    },

    // --- /new outcomes ---
    session_new_started: void,
    session_fork_started: void,
    session_new_failed: struct {
        message: []u8,
    },

    // --- /compact outcomes ---
    session_compacted: void,
    session_compaction_failed: struct {
        message: []u8,
    },

    // --- shared status snapshot ---
    // Agent-thread owned model/thinking/context snapshot for the editor
    // border chips. Published whenever session state changes in a way the
    // TUI must render without reading agent-owned state directly.
    // Semantic state crosses the boundary; chip formatting/layout stays
    // TUI-owned rather than becoming part of the mailbox payload.
    status_snapshot: struct {
        model_provider: []u8,
        model_id: []u8,
        thinking_level: []u8,
        context_tokens: ?u64,
        context_window: u64,
    },

    // --- /model outcomes (zi-wub.16) ---
    // Published by the agent thread after processing a set_model
    // AgentRequest. Success is banner-only; semantic model state is
    // carried by the adjacent status_snapshot publication.
    model_switched: struct {
        model_id: []u8,
    },
    model_switch_failed: struct {
        message: []u8,
    },

    // --- /settings thinking-level outcomes ---
    // Success is banner-only; semantic thinking state is carried by
    // the adjacent status_snapshot publication.
    thinking_level_changed: struct {
        level: []u8,
    },
    thinking_level_change_failed: struct {
        message: []u8,
    },

    pub fn isSnapshotEvent(self: UiEvent) bool {
        return switch (self) {
            .conversation_snapshot,
            .queued_snapshot,
            .theme_changed,
            .tool_running,
            .login_progress,
            .status_snapshot,
            => true,
            else => false,
        };
    }

    pub fn takeConversationSnapshot(self: *UiEvent) ?conversation_state_mod.ConversationSnapshotEnvelope {
        return switch (self.*) {
            .conversation_snapshot => |snapshot| blk: {
                self.* = .{ .consumed = {} };
                break :blk snapshot;
            },
            else => null,
        };
    }

    pub fn takeQueuedSnapshot(self: *UiEvent) ?runtime_host_mod.QueuedMessageSnapshot {
        return switch (self.*) {
            .queued_snapshot => |snapshot| blk: {
                self.* = .{ .consumed = {} };
                break :blk snapshot;
            },
            else => null,
        };
    }

    pub fn takeVisibleModelsSnapshot(self: *UiEvent) ?[]ai_protocol.Model {
        return switch (self.*) {
            .visible_models_snapshot => |snapshot| blk: {
                self.* = .{ .consumed = {} };
                break :blk snapshot.models;
            },
            else => null,
        };
    }

    /// Free all owned memory.
    pub fn deinit(self: *UiEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .consumed => {},
            .conversation_snapshot => |*snapshot| snapshot.deinit(allocator),
            .queued_snapshot => |*snapshot| snapshot.deinit(allocator),
            .error_message => |e| allocator.free(e.message),
            .theme_changed => {},
            .assistant_run_finished => |m| {
                if (m.error_message) |msg| allocator.free(msg);
            },
            .tool_running => |t| allocator.free(t.tool_name),
            .login_progress => |l| allocator.free(l.message),
            .login_complete => |l| {
                allocator.free(l.provider_id);
                allocator.free(l.message);
            },
            .retry_start => |r| allocator.free(r.error_message),
            .retry_end => |r| {
                if (r.final_error) |msg| allocator.free(msg);
            },
            .session_resumed => |s| {
                if (s.restore_warning) |warning| allocator.free(warning);
            },
            .session_resume_failed => |f| allocator.free(f.message),
            .extension_commands_updated => |u| {
                for (u.commands) |cmd| {
                    allocator.free(cmd.name);
                    allocator.free(cmd.description);
                }
                allocator.free(u.commands);
            },
            .visible_models_snapshot => |u| model_registry_mod.deinitOwnedModels(allocator, u.models),
            .session_new_started => {},
            .session_fork_started => {},
            .session_new_failed => |f| allocator.free(f.message),
            .session_compacted => {},
            .session_compaction_failed => |f| allocator.free(f.message),
            .status_snapshot => |s| {
                allocator.free(s.model_provider);
                allocator.free(s.model_id);
                allocator.free(s.thinking_level);
            },
            .model_switched => |m| allocator.free(m.model_id),
            .model_switch_failed => |m| allocator.free(m.message),
            .thinking_level_changed => |t| allocator.free(t.level),
            .thinking_level_change_failed => |t| allocator.free(t.message),
            .prompt_worker_finished => |p| {
                if (p.internal_error) |msg| allocator.free(msg);
            },
            .retry_wait_finished, .request_worker_finished => {},
        }
    }
};

const testing = std.testing;

test "UiEvent deinit frees conversation snapshot payload" {
    const shared = try conversation_state_mod.SharedCommitted.fromMessages(testing.allocator, &.{});
    var ev = UiEvent{ .conversation_snapshot = .{
        .view = .{
            .committed = shared,
            .in_flight = null,
        },
    } };
    ev.deinit(testing.allocator);
}

test "UiEvent visible-model snapshot ownership transfers with take helper" {
    const allocator = testing.allocator;
    const models = try model_registry_mod.cloneOwnedModels(allocator, &.{.{
        .id = "proxy-model",
        .name = "Proxy Model",
        .api = .openai_completions,
        .provider = .{ .custom = "proxy-a" },
        .base_url = "https://proxy-a.example",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 1024,
    }});
    var ev = UiEvent{ .visible_models_snapshot = .{ .models = models } };

    const taken = ev.takeVisibleModelsSnapshot().?;
    defer model_registry_mod.deinitOwnedModels(allocator, taken);

    ev.deinit(allocator);
}

test "UiEvent takeConversationSnapshot disarms later cleanup" {
    const shared = try conversation_state_mod.SharedCommitted.fromMessages(testing.allocator, &.{});
    var ev = UiEvent{ .conversation_snapshot = .{
        .view = .{
            .committed = shared,
            .in_flight = null,
        },
    } };
    var snapshot = ev.takeConversationSnapshot().?;
    defer snapshot.deinit(testing.allocator);

    ev.deinit(testing.allocator);
}

test "UiEvent deinit frees tool-running label" {
    var ev = UiEvent{ .tool_running = .{
        .tool_name = try testing.allocator.dupe(u8, "bash"),
    } };
    ev.deinit(testing.allocator);
}

test "UiEvent deinit handles assistant failure without message" {
    var ev = UiEvent{ .assistant_run_finished = .{
        .is_aborted = false,
        .error_message = null,
    } };
    ev.deinit(testing.allocator);
}

test "UiEvent snapshot classification matches lossy transport variants" {
    var snapshot = UiEvent{ .status_snapshot = .{
        .model_provider = try testing.allocator.dupe(u8, "openai"),
        .model_id = try testing.allocator.dupe(u8, "gpt-5"),
        .thinking_level = try testing.allocator.dupe(u8, "high"),
        .context_tokens = 1,
        .context_window = 2,
    } };
    defer snapshot.deinit(testing.allocator);

    try testing.expect(snapshot.isSnapshotEvent());
    try testing.expect(!(UiEvent{ .request_worker_finished = {} }).isSnapshotEvent());
}

test "UiEvent conversation snapshot is mailbox payload for live conversation state" {
    const shared = try conversation_state_mod.SharedCommitted.fromMessages(testing.allocator, &.{});
    var ev = UiEvent{ .conversation_snapshot = .{
        .session_generation = 2,
        .conversation_version = 5,
        .view = .{
            .committed = shared,
            .in_flight = null,
        },
    } };
    try testing.expect(ev.isSnapshotEvent());

    var taken = ev.takeConversationSnapshot().?;
    defer taken.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 2), taken.session_generation);
    try testing.expectEqual(@as(u64, 5), taken.conversation_version);

    // After take, deinit of the event is a no-op for the payload.
    ev.deinit(testing.allocator);
}
