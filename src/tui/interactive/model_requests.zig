const std = @import("std");
const ai_resolve = @import("../../coding_agent/resolve.zig");
const json_util = @import("../../ai/json_util.zig");
const coding_agent_mod = @import("../../coding_agent/root.zig");
const agent_protocol = @import("../../agent/types.zig");
const thinking_mod = @import("thinking.zig");
const status_snapshot_mod = @import("status_snapshot.zig");
const UiEvent = @import("../ui_event.zig").UiEvent;

pub const SnapshotPublisher = struct {
    msg_allocator: std.mem.Allocator,
    runtime_host: *coding_agent_mod.RuntimeHost,
    last_published_status_snapshot: *?status_snapshot_mod.PublishedStatusSnapshot,
    publish_snapshot: *const fn (ctx: ?*anyopaque, event: UiEvent) bool,
    publish_lifecycle: *const fn (ctx: ?*anyopaque, event: UiEvent) bool,
    ctx: ?*anyopaque,
};

pub fn handleSetModel(self: anytype, m: anytype) void {
    switch (self.runtime_host.currentSession().trySetModel(m)) {
        .success => {
            self.publishStatusSnapshot();
            const model_id = self.msg_allocator.dupe(u8, m.id) catch return;
            _ = self.publishLifecycleUiEvent(.{ .model_switched = .{ .model_id = model_id } });
        },
        .no_auth => |blocked| {
            const provider_str = json_util.providerToString(blocked.provider);
            const msg = std.fmt.allocPrint(
                self.msg_allocator,
                "No API key for {s}/{s}",
                .{ provider_str, blocked.id },
            ) catch return;
            _ = self.publishLifecycleUiEvent(.{ .model_switch_failed = .{ .message = msg } });
        },
        .registry_unavailable => {
            const msg = self.msg_allocator.dupe(u8, "model registry unavailable") catch return;
            _ = self.publishLifecycleUiEvent(.{ .model_switch_failed = .{ .message = msg } });
        },
    }
}

pub fn handleSetModelPattern(self: anytype, pattern: []const u8) void {
    const registry = self.runtime_host.currentSession().model_registry orelse {
        const msg = self.msg_allocator.dupe(u8, "model registry unavailable") catch return;
        _ = self.publishLifecycleUiEvent(.{ .model_switch_failed = .{ .message = msg } });
        return;
    };

    var scratch = std.heap.ArenaAllocator.init(self.msg_allocator);
    defer scratch.deinit();
    const result = ai_resolve.resolveCliModel(.{
        .cli_model = pattern,
        .registry = registry,
        .allocator = scratch.allocator(),
    });
    if (result.err) |err_msg| {
        const msg = self.msg_allocator.dupe(u8, err_msg) catch return;
        _ = self.publishLifecycleUiEvent(.{ .model_switch_failed = .{ .message = msg } });
        return;
    }
    const model = result.model orelse {
        const msg = self.msg_allocator.dupe(u8, "model not found") catch return;
        _ = self.publishLifecycleUiEvent(.{ .model_switch_failed = .{ .message = msg } });
        return;
    };
    self.handleSetModel(model);
}

pub fn publishVisibleModelsSnapshot(self: anytype) void {
    const registry = self.runtime_host.currentSession().model_registry orelse {
        _ = self.publishLifecycleUiEvent(.{ .visible_models_snapshot = .{ .models = &.{} } });
        return;
    };
    const models = coding_agent_mod.model_registry.cloneOwnedModels(self.msg_allocator, registry.getAll()) catch return;
    _ = self.publishLifecycleUiEvent(.{ .visible_models_snapshot = .{ .models = models } });
}

pub fn publishVisibleModelsSnapshotWithPublisher(publisher: SnapshotPublisher) void {
    const registry = publisher.runtime_host.currentSession().model_registry orelse {
        _ = publisher.publish_lifecycle(publisher.ctx, .{ .visible_models_snapshot = .{ .models = &.{} } });
        return;
    };
    const models = coding_agent_mod.model_registry.cloneOwnedModels(publisher.msg_allocator, registry.getAll()) catch return;
    _ = publisher.publish_lifecycle(publisher.ctx, .{ .visible_models_snapshot = .{ .models = models } });
}

pub fn publishStatusSnapshot(self: anytype) void {
    const snapshot = self.runtime_host.currentSession().statusSnapshot();
    if (self.shouldSkipStatusSnapshotPublish(snapshot)) return;

    const provider_copy = self.msg_allocator.dupe(u8, snapshot.model_provider) catch return;
    errdefer self.msg_allocator.free(provider_copy);
    const model_id_copy = self.msg_allocator.dupe(u8, snapshot.model_id) catch return;
    errdefer self.msg_allocator.free(model_id_copy);
    const thinking_copy = self.msg_allocator.dupe(u8, thinking_mod.label(snapshot.thinking_level)) catch return;
    errdefer self.msg_allocator.free(thinking_copy);

    if (self.publishSnapshotUiEvent(.{ .status_snapshot = .{
        .model_provider = provider_copy,
        .model_id = model_id_copy,
        .thinking_level = thinking_copy,
        .context_tokens = snapshot.context_tokens,
        .context_window = snapshot.context_window,
    } })) {
        self.rememberPublishedStatusSnapshot(snapshot);
    }
}

pub fn publishStatusSnapshotWithPublisher(publisher: SnapshotPublisher) void {
    const snapshot = publisher.runtime_host.currentSession().statusSnapshot();
    if (shouldSkipStatusSnapshotPublish(publisher, snapshot)) return;

    const provider_copy = publisher.msg_allocator.dupe(u8, snapshot.model_provider) catch return;
    errdefer publisher.msg_allocator.free(provider_copy);
    const model_id_copy = publisher.msg_allocator.dupe(u8, snapshot.model_id) catch return;
    errdefer publisher.msg_allocator.free(model_id_copy);
    const thinking_copy = publisher.msg_allocator.dupe(u8, thinking_mod.label(snapshot.thinking_level)) catch return;
    errdefer publisher.msg_allocator.free(thinking_copy);

    if (publisher.publish_snapshot(publisher.ctx, .{ .status_snapshot = .{
        .model_provider = provider_copy,
        .model_id = model_id_copy,
        .thinking_level = thinking_copy,
        .context_tokens = snapshot.context_tokens,
        .context_window = snapshot.context_window,
    } })) {
        rememberPublishedStatusSnapshot(publisher, snapshot);
    }
}

fn shouldSkipStatusSnapshotPublish(publisher: SnapshotPublisher, snapshot: coding_agent_mod.AgentSession.StatusSnapshot) bool {
    const last = publisher.last_published_status_snapshot.* orelse return false;
    return last.eql(snapshot);
}

fn rememberPublishedStatusSnapshot(publisher: SnapshotPublisher, snapshot: coding_agent_mod.AgentSession.StatusSnapshot) void {
    const replacement = status_snapshot_mod.PublishedStatusSnapshot.init(publisher.msg_allocator, snapshot) catch return;
    if (publisher.last_published_status_snapshot.*) |*last| {
        last.deinit(publisher.msg_allocator);
    }
    publisher.last_published_status_snapshot.* = replacement;
}

pub fn handleSetThinkingLevel(self: anytype, level: agent_protocol.ThinkingLevel) void {
    _ = self.runtime_host.currentSession().trySetThinkingLevel(level);
    self.publishStatusSnapshot();
    const level_label = self.msg_allocator.dupe(u8, thinking_mod.label(level)) catch return;
    _ = self.publishLifecycleUiEvent(.{ .thinking_level_changed = .{ .level = level_label } });
}
