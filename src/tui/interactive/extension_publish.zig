const std = @import("std");

const coding_agent_mod = @import("../../coding_agent/root.zig");
const ui_event_mod = @import("../ui_event.zig");
const UiEvent = ui_event_mod.UiEvent;

pub const Publisher = struct {
    msg_allocator: std.mem.Allocator,
    runtime_host: *coding_agent_mod.RuntimeHost,
    publish_lifecycle: *const fn (ctx: ?*anyopaque, event: UiEvent) bool,
    ctx: ?*anyopaque,
};

pub fn publishCommandsUpdate(publisher: Publisher) void {
    const commands = blk: {
        const runner = publisher.runtime_host.currentSession().extensionRunner() orelse break :blk publisher.msg_allocator.alloc(ui_event_mod.ExtensionCommandEntry, 0) catch return;
        const items = runner.command_registry.items();
        var owned = publisher.msg_allocator.alloc(ui_event_mod.ExtensionCommandEntry, items.len) catch return;
        var built: usize = 0;
        errdefer {
            for (owned[0..built]) |cmd| {
                publisher.msg_allocator.free(cmd.name);
                publisher.msg_allocator.free(cmd.description);
            }
            publisher.msg_allocator.free(owned);
        }
        for (items) |entry| {
            owned[built] = .{
                .name = publisher.msg_allocator.dupe(u8, entry.visible_name) catch return,
                .description = publisher.msg_allocator.dupe(u8, entry.description) catch {
                    publisher.msg_allocator.free(owned[built].name);
                    return;
                },
            };
            built += 1;
        }
        break :blk owned;
    };
    _ = publisher.publish_lifecycle(publisher.ctx, .{ .extension_commands_updated = .{ .commands = commands } });
    publishKeybindingsSnapshot(publisher);
}

pub fn publishKeybindingsSnapshot(publisher: Publisher) void {
    const extension_bindings = blk: {
        const runner = publisher.runtime_host.currentSession().extensionRunner() orelse break :blk publisher.msg_allocator.alloc(ui_event_mod.ExtensionKeybindingEntry, 0) catch return;
        var count: usize = 0;
        for (runner.keybinding_registry.items()) |entry| count += entry.keys.len;
        var owned = publisher.msg_allocator.alloc(ui_event_mod.ExtensionKeybindingEntry, count) catch return;
        var built: usize = 0;
        errdefer {
            for (owned[0..built]) |kb| {
                publisher.msg_allocator.free(kb.id);
                publisher.msg_allocator.free(kb.description);
                publisher.msg_allocator.free(kb.display);
            }
            publisher.msg_allocator.free(owned);
        }
        for (runner.keybinding_registry.items()) |entry| {
            for (entry.keys, 0..) |key, i| {
                owned[built] = .{
                    .id = publisher.msg_allocator.dupe(u8, entry.id) catch return,
                    .description = publisher.msg_allocator.dupe(u8, entry.description) catch {
                        publisher.msg_allocator.free(owned[built].id);
                        return;
                    },
                    .key = key,
                    .display = publisher.msg_allocator.dupe(u8, entry.displays[i]) catch {
                        publisher.msg_allocator.free(owned[built].id);
                        publisher.msg_allocator.free(owned[built].description);
                        return;
                    },
                };
                built += 1;
            }
        }
        break :blk owned;
    };
    _ = publisher.publish_lifecycle(publisher.ctx, .{ .extension_keybindings_updated = .{ .keybindings = extension_bindings } });
}

pub fn publishPendingUi(publisher: Publisher) void {
    const render_updates = publisher.runtime_host.takePendingExtensionRenderUpdates(publisher.msg_allocator);
    if (render_updates.len > 0) {
        _ = publisher.publish_lifecycle(publisher.ctx, .{ .extension_ui_rendered = .{ .updates = render_updates } });
    } else {
        publisher.msg_allocator.free(render_updates);
    }
    const frame_updates = publisher.runtime_host.takePendingExtensionFrameUpdates(publisher.msg_allocator);
    if (frame_updates.len > 0) {
        _ = publisher.publish_lifecycle(publisher.ctx, .{ .extension_ui_framed = .{ .updates = frame_updates } });
    } else {
        publisher.msg_allocator.free(frame_updates);
    }
    const actions = publisher.runtime_host.takePendingExtensionEditorActions(publisher.msg_allocator);
    if (actions.len > 0) {
        _ = publisher.publish_lifecycle(publisher.ctx, .{ .extension_editor_actions = .{ .actions = actions } });
    } else {
        publisher.msg_allocator.free(actions);
    }
}
