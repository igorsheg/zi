const std = @import("std");

const primitive = @import("../primitive/root.zig");
const composer_mod = @import("composer.zig");
const transcript_mod = @import("transcript.zig");

pub const transcript_width_columns_default = 80;
pub const effect_count_max = 16;

pub const Size = struct {
    width_columns: u16,
    height_rows: u16,
};

pub const Command = union(enum) {
    resize: Size,
    insert_composer_text: []const u8,
    backspace_composer,
    move_composer_left,
    move_composer_right,
    clear_composer,
    submit_composer,
    append_transcript_item: transcript_mod.ItemKind,
    append_transcript_text: struct {
        item_id: transcript_mod.ItemId,
        bytes: []const u8,
    },
    seal_transcript_item: transcript_mod.ItemId,
    scroll_transcript_up: usize,
    scroll_transcript_down: usize,
    jump_transcript_tail,
};

pub const Effect = union(enum) {
    submit_prompt: []u8,

    pub fn deinit(self: Effect, allocator: std.mem.Allocator) void {
        switch (self) {
            .submit_prompt => |prompt| allocator.free(prompt),
        }
    }
};

const EffectQueue = struct {
    items: [effect_count_max]Effect = undefined,
    count: usize = 0,

    fn push(self: *EffectQueue, effect: Effect) !void {
        if (self.count == self.items.len) return error.TuiEffectQueueFull;
        self.items[self.count] = effect;
        self.count += 1;
    }

    fn drainOne(self: *EffectQueue) ?Effect {
        if (self.count == 0) return null;
        const effect = self.items[0];
        @memmove(self.items[0 .. self.count - 1], self.items[1..self.count]);
        self.count -= 1;
        return effect;
    }

    fn deinit(self: *EffectQueue, allocator: std.mem.Allocator) void {
        for (self.items[0..self.count]) |effect| effect.deinit(allocator);
        self.* = undefined;
    }
};

pub const ProductApp = struct {
    composer: composer_mod.Composer = .{},
    transcript: transcript_mod.Transcript,
    transcript_viewport: primitive.viewport.Viewport = .{},
    transcript_render_rows: primitive.render_list.RenderList = .{},
    size: Size = .{ .width_columns = transcript_width_columns_default, .height_rows = 24 },
    effects: EffectQueue = .{},
    dirty: bool = true,

    pub fn init(transcript_options: primitive.document.Options) ProductApp {
        var app: ProductApp = .{
            .transcript = transcript_mod.Transcript.init(transcript_options),
        };
        app.transcript_viewport.resize(app.transcriptHeightRows(), 0);
        return app;
    }

    pub fn deinit(self: *ProductApp, allocator: std.mem.Allocator) void {
        self.effects.deinit(allocator);
        self.transcript_render_rows.deinit(allocator);
        self.transcript.deinit(allocator);
        self.composer.deinit(allocator);
        self.* = undefined;
    }

    pub fn apply(self: *ProductApp, allocator: std.mem.Allocator, command: Command) !?transcript_mod.ItemId {
        switch (command) {
            .resize => |size| {
                self.size = size;
                try self.rebuildTranscriptRows(allocator);
                self.dirty = true;
                return null;
            },
            .insert_composer_text => |bytes| {
                try self.composer.apply(allocator, .{ .insert_text = bytes });
                self.dirty = true;
                return null;
            },
            .backspace_composer => {
                try self.composer.apply(allocator, .backspace);
                self.dirty = true;
                return null;
            },
            .move_composer_left => {
                try self.composer.apply(allocator, .move_left);
                self.dirty = true;
                return null;
            },
            .move_composer_right => {
                try self.composer.apply(allocator, .move_right);
                self.dirty = true;
                return null;
            },
            .clear_composer => {
                try self.composer.apply(allocator, .clear);
                self.dirty = true;
                return null;
            },
            .submit_composer => return try self.submitComposer(allocator),
            .append_transcript_item => |kind| {
                const item_id = (try self.transcript.apply(allocator, .{ .append_item = kind })).?;
                try self.rebuildTranscriptRows(allocator);
                self.dirty = true;
                return item_id;
            },
            .append_transcript_text => |payload| {
                _ = try self.transcript.apply(allocator, .{
                    .append_text = .{ .item_id = payload.item_id, .bytes = payload.bytes },
                });
                try self.rebuildTranscriptRows(allocator);
                self.dirty = true;
                return null;
            },
            .seal_transcript_item => |item_id| {
                _ = try self.transcript.apply(allocator, .{ .seal_item = item_id });
                try self.rebuildTranscriptRows(allocator);
                self.dirty = true;
                return null;
            },
            .scroll_transcript_up => |row_count| {
                self.transcript_viewport.scrollUp(row_count);
                self.dirty = true;
                return null;
            },
            .scroll_transcript_down => |row_count| {
                self.transcript_viewport.scrollDown(row_count, self.transcript_render_rows.rows.items.len);
                self.dirty = true;
                return null;
            },
            .jump_transcript_tail => {
                self.transcript_viewport.jumpToTail(self.transcript_render_rows.rows.items.len);
                self.dirty = true;
                return null;
            },
        }
    }

    pub fn drainEffect(self: *ProductApp) ?Effect {
        return self.effects.drainOne();
    }

    pub fn visibleTranscriptRows(self: *const ProductApp) []const primitive.render_list.Row {
        const index_start = self.transcript_viewport.scroll_row_offset;
        const index_end = @min(
            self.transcript_render_rows.rows.items.len,
            index_start + self.transcript_viewport.height_rows,
        );
        return self.transcript_render_rows.rows.items[index_start..index_end];
    }

    fn submitComposer(self: *ProductApp, allocator: std.mem.Allocator) !?transcript_mod.ItemId {
        const prompt = try self.composer.submit(allocator);
        errdefer allocator.free(prompt);

        const item_id = (try self.transcript.apply(allocator, .{ .append_item = .user_message })).?;
        errdefer self.rollbackTailTranscriptItem(allocator, item_id);
        _ = try self.transcript.apply(allocator, .{ .append_text = .{ .item_id = item_id, .bytes = prompt } });
        _ = try self.transcript.apply(allocator, .{ .seal_item = item_id });
        try self.rebuildTranscriptRows(allocator);
        try self.effects.push(.{ .submit_prompt = prompt });
        self.dirty = true;
        return item_id;
    }

    fn rollbackTailTranscriptItem(
        self: *ProductApp,
        allocator: std.mem.Allocator,
        expected_id: transcript_mod.ItemId,
    ) void {
        if (self.transcript.items.items.len == 0) unreachable;
        const index = self.transcript.items.items.len - 1;
        if (self.transcript.items.items[index].id != expected_id) unreachable;
        const block_id = self.transcript.items.items[index].block_id;
        self.transcript.items.items.len = index;
        self.transcript.next_item_id -= 1;
        self.transcript.document.removeTailBlock(allocator, block_id) catch unreachable;
    }

    fn rebuildTranscriptRows(self: *ProductApp, allocator: std.mem.Allocator) !void {
        try self.transcript_render_rows.rebuild(
            allocator,
            &self.transcript.document,
            self.size.width_columns,
        );
        self.transcript_viewport.resize(
            self.transcriptHeightRows(),
            self.transcript_render_rows.rows.items.len,
        );
    }

    fn transcriptHeightRows(self: ProductApp) u16 {
        if (self.size.height_rows <= 1) return 0;
        return self.size.height_rows - 1;
    }
};

test "product app submit appends user transcript item and emits owned effect" {
    var app = ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);

    _ = try app.apply(std.testing.allocator, .{ .insert_composer_text = "hello" });
    const item_id = (try app.apply(std.testing.allocator, .submit_composer)).?;

    const item = app.transcript.item(item_id).?;
    const block = app.transcript.document.block(item.block_id).?;
    try std.testing.expectEqual(.user_message, item.kind);
    try std.testing.expectEqual(.sealed, item.state);
    try std.testing.expectEqualStrings("hello", block.bytes.items);
    try std.testing.expectEqualStrings("", app.composer.buffer.bytes.items);

    const effect = app.drainEffect().?;
    defer effect.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", effect.submit_prompt);
    try std.testing.expect(app.drainEffect() == null);
}

test "product app transcript viewport follows tail until scrolled" {
    var app = ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    _ = try app.apply(std.testing.allocator, .{ .resize = .{ .width_columns = 4, .height_rows = 3 } });

    const item_id = (try app.apply(std.testing.allocator, .{ .append_transcript_item = .assistant_message })).?;
    _ = try app.apply(std.testing.allocator, .{
        .append_transcript_text = .{ .item_id = item_id, .bytes = "abcdefghijkl" },
    });

    try std.testing.expectEqual(@as(usize, 3), app.transcript_render_rows.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.transcript_viewport.scroll_row_offset);
    try std.testing.expect(app.transcript_viewport.follow_tail);

    _ = try app.apply(std.testing.allocator, .{ .scroll_transcript_up = 1 });
    try std.testing.expectEqual(@as(usize, 0), app.transcript_viewport.scroll_row_offset);
    try std.testing.expect(!app.transcript_viewport.follow_tail);

    _ = try app.apply(std.testing.allocator, .{
        .append_transcript_text = .{ .item_id = item_id, .bytes = "mnop" },
    });
    try std.testing.expectEqual(@as(usize, 0), app.transcript_viewport.scroll_row_offset);
    try std.testing.expect(!app.transcript_viewport.follow_tail);

    _ = try app.apply(std.testing.allocator, .jump_transcript_tail);
    try std.testing.expect(app.transcript_viewport.follow_tail);
}
