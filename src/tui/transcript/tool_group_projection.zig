// Adapted from vercel-labs/fx src/ui/transcript/tool_group_projection.zig.
// Licensed under Apache-2.0 and reduced to Zi's admitted tool detail contract.
const std = @import("std");
const tool_presentation = @import("../tools/tool_presentation.zig");
const Store = @import("Store.zig");

pub const EntryRenderAction = union(enum) {
    keep,
    hide,
    override: []const u8,
};

pub const Projection = struct {
    actions: []const EntryRenderAction,
};

/// Projects every typed tool-status run into presentation bytes. Consecutive
/// statuses share one compact group while retained entries remain unchanged.
pub fn build(
    arena: std.mem.Allocator,
    entries: []const Store.Entry,
) !Projection {
    const actions = try arena.alloc(EntryRenderAction, entries.len);
    @memset(actions, .keep);

    var index: usize = 0;
    while (index < entries.len) {
        if (entries[index].class() != .tool_status) {
            index += 1;
            continue;
        }
        var end = index + 1;
        while (end < entries.len and entries[end].class() == .tool_status) : (end += 1) {}

        var out: std.Io.Writer.Allocating = .init(arena);
        errdefer out.deinit();
        if (end - index == 1) {
            const status = entries[index].toolStatus().?;
            try tool_presentation.writeCompletion(
                &out.writer,
                status.phrase.items,
                status.outcome,
            );
        } else {
            var failed: usize = 0;
            for (entries[index..end]) |entry| {
                if (entry.toolStatus().?.outcome != .success) failed += 1;
            }
            try out.writer.print("● {d} tool calls", .{end - index});
            if (failed != 0) try out.writer.print(" · {d} failed", .{failed});
            for (entries[index..end], 0..) |entry, child_index| {
                const status = entry.toolStatus().?;
                try out.writer.writeByte('\n');
                try out.writer.writeAll(if (child_index + 1 == end - index) "└ " else "├ ");
                try tool_presentation.writePhrase(
                    &out.writer,
                    status.phrase.items,
                    status.outcome,
                );
            }
        }
        actions[index] = .{ .override = try out.toOwnedSlice() };
        for (actions[index + 1 .. end]) |*action| action.* = .hide;
        index = end;
    }
    return .{ .actions = actions };
}

test "projection groups typed tool statuses and preserves phrases" {
    var store = Store.Store.init(std.testing.allocator, 1024);
    defer store.deinit();
    _ = try store.appendToolStatus("Read a.zig", .success);
    _ = try store.appendToolStatus("Ran zig test", .failed);
    _ = try store.appendSealed(.assistant_turn, "done\n");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const projection = try build(arena.allocator(), store.items());
    try std.testing.expect(projection.actions[0] == .override);
    try std.testing.expect(projection.actions[1] == .hide);
    const grouped = projection.actions[0].override;
    try std.testing.expect(std.mem.find(u8, grouped, "2 tool calls · 1 failed") != null);
    try std.testing.expect(std.mem.find(u8, grouped, "├ Read a.zig") != null);
    try std.testing.expect(std.mem.find(u8, grouped, "└ Ran zig test failed") != null);
}

test "projection renders a single typed tool status" {
    var store = Store.Store.init(std.testing.allocator, 1024);
    defer store.deinit();
    _ = try store.appendToolStatus("Read a.zig", .cancelled);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const projection = try build(arena.allocator(), store.items());
    try std.testing.expectEqualStrings("■ Read a.zig cancelled\n", projection.actions[0].override);
}
