const std = @import("std");

const component_mod = @import("primitives/view.zig");
const buffer_mod = @import("primitives/surface.zig");
const transcript_mod = @import("conversation/transcript.zig");

const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;
const Transcript = transcript_mod.Transcript;
const TranscriptItem = transcript_mod.TranscriptItem;
const TranscriptRenderable = transcript_mod.TranscriptRenderable;
const ItemId = transcript_mod.ItemId;

const FixedRow = struct {
    height: u32,

    pub fn measure(self: *FixedRow, _: u32) Measurement {
        return .{ .min_height = 1, .preferred_height = self.height };
    }

    pub fn renderSlice(_: *FixedRow, _: Region, _: u32) void {}
};

fn deinitFixedRow(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const row: *FixedRow = @ptrCast(@alignCast(ctx));
    allocator.destroy(row);
}

fn makeFixedItem(allocator: std.mem.Allocator, id: u64, height: u32, version: u64) !TranscriptItem {
    const row = try allocator.create(FixedRow);
    errdefer allocator.destroy(row);
    row.* = .{ .height = @max(1, height) };
    return .{
        .renderable = TranscriptRenderable.init(FixedRow, row),
        .retained_item_id = @enumFromInt(id),
        .retained_semantic_version = version,
        .deinit_ctx = @ptrCast(row),
        .deinit_fn = deinitFixedRow,
    };
}

fn assertTranscriptInvariants(transcript: *Transcript, width: u32, visible_height: u32) !void {
    const total = transcript.totalHeight(width);
    const max_scroll = if (total > visible_height) total - visible_height else 0;
    try std.testing.expect(transcript.scrollOffset() <= max_scroll);

    var seen = std.AutoHashMap(ItemId, usize).init(std.testing.allocator);
    defer seen.deinit();

    for (transcript.items.items, 0..) |item, index| {
        if (item.retained_item_id) |id| {
            try std.testing.expect(!seen.contains(id));
            try seen.put(id, index);
            const found = transcript.findRetainedItemIndex(id) orelse return error.RetainedItemMissing;
            try std.testing.expectEqual(index, found);
        }
    }

    var it = transcript.retained_items.iterator();
    while (it.next()) |entry| {
        const index = entry.value_ptr.*;
        try std.testing.expect(index < transcript.items.items.len);
        try std.testing.expect(transcript.items.items[index].retained_item_id != null);
        try std.testing.expectEqual(entry.key_ptr.*, transcript.items.items[index].retained_item_id.?);
    }
}

test "tui property: transcript random mutations preserve scroll and retained maps" {
    const seeds = [_]u64{ 0x1234, 0xdead_beef, 0x9502_9440, 0xfeed_face };

    for (seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        var transcript = Transcript.init(std.testing.allocator);
        defer transcript.deinit();

        var next_id: u64 = 1;
        var width: u32 = 40;
        var visible_height: u32 = 8;

        var step: usize = 0;
        while (step < 500) : (step += 1) {
            const op = random.uintLessThan(u8, 7);
            switch (op) {
                0 => {
                    const height = 1 + random.uintLessThan(u32, 8);
                    const item = try makeFixedItem(std.testing.allocator, next_id, height, 1);
                    next_id += 1;
                    try std.testing.expect(transcript.addItem(item));
                },
                1 => if (transcript.items.items.len > 0) {
                    const index = random.uintLessThan(usize, transcript.items.items.len);
                    const old = transcript.items.items[index];
                    const id: u64 = @intFromEnum(old.retained_item_id.?);
                    const version = (old.retained_semantic_version orelse 0) + 1;
                    const height = 1 + random.uintLessThan(u32, 12);
                    const item = try makeFixedItem(std.testing.allocator, id, height, version);
                    try std.testing.expect(transcript.replaceItemAt(index, item));
                },
                2 => if (transcript.items.items.len > 0) {
                    const index = random.uintLessThan(usize, transcript.items.items.len);
                    transcript.removeItemAt(index);
                },
                3 => if (transcript.items.items.len > 1) {
                    const from = random.uintLessThan(usize, transcript.items.items.len);
                    const to = random.uintLessThan(usize, transcript.items.items.len);
                    transcript.moveItem(from, to);
                },
                4 => {
                    const delta = @as(i64, random.intRangeAtMost(i8, -10, 10));
                    transcript.scrollBy(width, visible_height, delta);
                },
                5 => {
                    width = 1 + random.uintLessThan(u32, 120);
                    transcript.scrollBy(width, visible_height, 0);
                },
                6 => {
                    visible_height = 1 + random.uintLessThan(u32, 30);
                    transcript.scrollBy(width, visible_height, 0);
                },
                else => unreachable,
            }

            assertTranscriptInvariants(&transcript, width, visible_height) catch |err| {
                std.debug.print("property failure seed={x} step={d} op={d} items={d}\n", .{ seed, step, op, transcript.items.items.len });
                return err;
            };
        }
    }
}
