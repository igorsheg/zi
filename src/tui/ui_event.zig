const std = @import("std");
const ai = @import("../ai/root.zig");
const conversation_state_mod = @import("../agent/conversation_state.zig");
const runtime_host_mod = @import("../coding_agent/runtime_host.zig");
const model_registry_mod = @import("../coding_agent/model_registry.zig");
const ai_protocol = @import("../ai/protocol.zig");
const theme_mod = @import("theme.zig");
const extension_ui = @import("../coding_agent/extensions/ui.zig");
const request_mod = @import("../coding_agent/request.zig");
const keys_mod = @import("terminal/keys.zig");
const session_store_mod = @import("../coding_agent/session/store.zig");
const RunOutcome = runtime_host_mod.RunOutcome;

pub const ExtensionCommandEntry = struct {
    name: []u8,
    description: []u8,
};

pub const ExtensionKeybindingEntry = struct {
    id: []u8,
    description: []u8,
    key: keys_mod.Key,
    display: []u8,
};

/// Mailbox-owned TUI event; no borrowed agent pointers cross threads.
pub const UiEvent = union(enum) {
    consumed: void,

    conversation_snapshot: conversation_state_mod.ConversationSnapshotEnvelope,
    queued_snapshot: runtime_host_mod.QueuedMessageSnapshot,

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

    login_progress: struct {
        message: []u8,
        kind: enum { info, auth_url },
    },
    login_complete: struct {
        provider_id: []u8,
        success: bool,
        message: []u8,
    },

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

    compaction_start: struct {
        reason: runtime_host_mod.CompactionReason,
    },
    compaction_end: void,

    prompt_worker_finished: struct {
        outcome: RunOutcome,
        internal_error: ?[]u8 = null,
    },

    request_worker_finished: void,

    session_resumed: struct {
        restore_warning: ?[]u8 = null,
    },
    session_resume_failed: struct {
        message: []u8,
    },
    resume_sessions_loaded: struct {
        generation: u64,
        sessions: []session_store_mod.SessionInfo,
    },
    resume_sessions_failed: struct {
        generation: u64,
        message: []u8,
    },

    extension_commands_updated: struct {
        commands: []ExtensionCommandEntry,
    },
    extension_keybindings_updated: struct {
        keybindings: []ExtensionKeybindingEntry,
    },
    extension_report_shown: struct {
        report: extension_ui.Report,
    },
    extension_ui_published: struct {
        updates: []extension_ui.UiPublication,
    },
    extension_surface_updated: struct {
        updates: []extension_ui.SurfaceUpdate,
    },
    extension_editor_actions: struct {
        actions: []extension_ui.EditorAction,
    },
    extension_prompt_requested: struct {
        prompt: extension_ui.PromptRequest,
        response: *request_mod.ExtensionPromptResponse,
    },

    visible_models_snapshot: struct {
        models: []ai_protocol.Model,
    },

    session_new_started: void,
    session_fork_started: void,
    session_new_failed: struct {
        message: []u8,
    },

    session_compacted: void,
    session_compaction_failed: struct {
        message: []u8,
    },

    status_snapshot: struct {
        model_provider: []u8,
        model_id: []u8,
        thinking_level: []u8,
        context_tokens: ?u64,
        context_window: u64,
    },

    model_switched: struct {
        model_id: []u8,
    },
    model_switch_failed: struct {
        message: []u8,
    },

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
            .extension_surface_updated,
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

    /// Free with the same allocator that built the mailbox payload.
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
            .compaction_start => {},
            .compaction_end => {},
            .session_resumed => |s| {
                if (s.restore_warning) |warning| allocator.free(warning);
            },
            .session_resume_failed => |f| allocator.free(f.message),
            .resume_sessions_loaded => |r| session_store_mod.freeSessionInfos(allocator, r.sessions),
            .resume_sessions_failed => |f| allocator.free(f.message),
            .extension_commands_updated => |u| {
                for (u.commands) |cmd| {
                    allocator.free(cmd.name);
                    allocator.free(cmd.description);
                }
                allocator.free(u.commands);
            },
            .extension_keybindings_updated => |u| {
                for (u.keybindings) |kb| {
                    allocator.free(kb.id);
                    allocator.free(kb.description);
                    allocator.free(kb.display);
                }
                allocator.free(u.keybindings);
            },
            .extension_report_shown => |*u| u.report.deinit(allocator),
            .extension_ui_published => |u| {
                for (u.updates) |*update| update.deinit(allocator);
                allocator.free(u.updates);
            },
            .extension_surface_updated => |u| {
                for (u.updates) |*update| update.deinit(allocator);
                allocator.free(u.updates);
            },
            .extension_editor_actions => |u| {
                for (u.actions) |*action| action.deinit(allocator);
                allocator.free(u.actions);
            },
            .extension_prompt_requested => |*u| u.prompt.deinit(allocator),
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

test "UiEvent snapshot classification drives queue routing" {
    const themes_builtin = @import("../themes/builtin.zig");

    var status = UiEvent{ .status_snapshot = .{
        .model_provider = try testing.allocator.dupe(u8, "openai"),
        .model_id = try testing.allocator.dupe(u8, "gpt-5"),
        .thinking_level = try testing.allocator.dupe(u8, "high"),
        .context_tokens = 1,
        .context_window = 2,
    } };
    defer status.deinit(testing.allocator);

    var login = UiEvent{ .login_progress = .{
        .message = try testing.allocator.dupe(u8, "check your browser"),
        .kind = .auth_url,
    } };
    defer login.deinit(testing.allocator);

    try testing.expect((UiEvent{ .theme_changed = themes_builtin.dark().* }).isSnapshotEvent());
    try testing.expect(status.isSnapshotEvent());
    try testing.expect(login.isSnapshotEvent());
    try testing.expect(!(UiEvent{ .request_worker_finished = {} }).isSnapshotEvent());
    try testing.expect(!(UiEvent{ .session_new_started = {} }).isSnapshotEvent());
}

test "UiEvent snapshot take helpers transfer mailbox ownership" {
    const allocator = testing.allocator;

    const shared = try conversation_state_mod.SharedCommitted.fromMessages(allocator, &.{});
    var conversation = UiEvent{ .conversation_snapshot = .{
        .session_generation = 2,
        .conversation_version = 5,
        .view = .{
            .committed = shared,
            .in_flight = null,
        },
    } };
    var taken_conversation = conversation.takeConversationSnapshot().?;
    defer taken_conversation.deinit(allocator);
    try testing.expectEqual(@as(u64, 2), taken_conversation.session_generation);
    try testing.expectEqual(@as(u64, 5), taken_conversation.conversation_version);
    try testing.expect(conversation.takeConversationSnapshot() == null);
    conversation.deinit(allocator);

    const queued_snapshot = blk: {
        const steering = try allocator.alloc(runtime_host_mod.QueuedMessageText, 0);
        errdefer allocator.free(steering);
        const follow_up = try allocator.alloc(runtime_host_mod.QueuedMessageText, 0);
        break :blk runtime_host_mod.QueuedMessageSnapshot{
            .steering = steering,
            .follow_up = follow_up,
            .version = 9,
        };
    };
    var queued = UiEvent{ .queued_snapshot = queued_snapshot };
    var taken_queued = queued.takeQueuedSnapshot().?;
    defer taken_queued.deinit(allocator);
    try testing.expectEqual(@as(u64, 9), taken_queued.version);
    try testing.expect(queued.takeQueuedSnapshot() == null);
    queued.deinit(allocator);

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
    var visible = UiEvent{ .visible_models_snapshot = .{ .models = models } };
    const taken_models = visible.takeVisibleModelsSnapshot().?;
    defer model_registry_mod.deinitOwnedModels(allocator, taken_models);
    try testing.expect(visible.takeVisibleModelsSnapshot() == null);
    visible.deinit(allocator);
}

test "UiEvent deinit accepts owned payload variants and nullable edge cases" {
    var assistant = UiEvent{ .assistant_run_finished = .{
        .is_aborted = false,
        .error_message = null,
    } };
    assistant.deinit(testing.allocator);

    var retry = UiEvent{ .retry_end = .{
        .success = false,
        .attempt = 2,
        .final_error = null,
    } };
    retry.deinit(testing.allocator);

    var tool = UiEvent{ .tool_running = .{
        .tool_name = try testing.allocator.dupe(u8, "bash"),
    } };
    tool.deinit(testing.allocator);
}
