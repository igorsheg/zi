const std = @import("std");
const component_mod = @import("../component.zig");
const buffer_mod = @import("../buffer.zig");
const markdown_mod = @import("markdown.zig");
const text_mod = @import("text.zig");
const theme_mod = @import("../theme.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;

pub const AssistantMessage = struct {
    allocator: std.mem.Allocator,
    theme: *const theme_mod.Theme = &theme_mod.Theme.dark,
    hide_thinking_block: bool = false,
    hidden_thinking_label: []const u8 = "Thinking...",
    scroll_offset: u32 = 0,

    blocks: std.ArrayListUnmanaged(Block) = .empty,

    const BlockKind = enum { text, thinking };
    const RenderKind = enum { markdown, label };

    const Block = struct {
        kind: BlockKind,
        content_index: usize,
        markdown: *markdown_mod.Markdown,
        label: *text_mod.Text,
        render_kind: RenderKind,

        fn deinit(self: *Block, allocator: std.mem.Allocator) void {
            self.markdown.deinit();
            allocator.destroy(self.markdown);
            self.label.deinit();
            allocator.destroy(self.label);
        }
    };

    pub fn init(allocator: std.mem.Allocator) AssistantMessage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AssistantMessage) void {
        for (self.blocks.items) |*block| block.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
    }

    pub fn component(self: *AssistantMessage) Component {
        return Component.init(AssistantMessage, self);
    }

    pub fn appendText(self: *AssistantMessage, content_index: usize, delta: []const u8) void {
        const block = self.ensureBlock(content_index, .text) orelse return;
        block.markdown.appendContent(delta);
        block.markdown.invalidate();
    }

    pub fn appendThinking(self: *AssistantMessage, content_index: usize, delta: []const u8) void {
        const block = self.ensureBlock(content_index, .thinking) orelse return;
        block.markdown.appendContent(delta);
        block.markdown.invalidate();
        if (self.hide_thinking_block) self.refreshThinkingVisibility(block);
    }

    // Kept as no-op compatibility hooks so transcript animation plumbing can
    // stay simple while thinking blocks render statically through Markdown.
    pub fn deactivateThinkingShimmer(_: *AssistantMessage) bool {
        return false;
    }

    pub fn nextAnimationDeadline(_: *AssistantMessage, _: i128) ?i128 {
        return null;
    }

    pub fn tickAnimation(_: *AssistantMessage, _: i128) bool {
        return false;
    }

    pub fn setHideThinkingBlock(self: *AssistantMessage, hide: bool) void {
        if (self.hide_thinking_block == hide) return;
        self.hide_thinking_block = hide;
        for (self.blocks.items) |*block| {
            if (block.kind == .thinking) self.refreshThinkingVisibility(block);
        }
    }

    fn ensureBlock(self: *AssistantMessage, content_index: usize, kind: BlockKind) ?*Block {
        if (self.findBlock(content_index)) |idx| {
            const block = &self.blocks.items[idx];
            if (block.kind != kind) return null;
            return block;
        }

        const md = self.allocator.create(markdown_mod.Markdown) catch return null;
        errdefer self.allocator.destroy(md);
        md.* = markdown_mod.Markdown.init(self.allocator);
        md.padding_x = 1;
        md.theme = self.theme;
        if (kind == .thinking) {
            md.fg = self.theme.fg(.thinking_text);
            md.attrs = .{ .italic = true };
        }

        const label = self.allocator.create(text_mod.Text) catch {
            md.deinit();
            return null;
        };
        errdefer self.allocator.destroy(label);
        label.* = text_mod.Text.init(self.allocator);
        label.padding_x = 1;
        label.fg = self.theme.fg(.thinking_text);
        label.attrs = .{ .italic = true };
        label.setContent(self.hidden_thinking_label);

        const insert_idx = self.findInsertIndex(content_index);
        self.blocks.insert(self.allocator, insert_idx, .{
            .kind = kind,
            .content_index = content_index,
            .markdown = md,
            .label = label,
            .render_kind = if (kind == .thinking and self.hide_thinking_block) .label else .markdown,
        }) catch {
            md.deinit();
            self.allocator.destroy(md);
            label.deinit();
            self.allocator.destroy(label);
            return null;
        };
        return &self.blocks.items[insert_idx];
    }

    fn refreshThinkingVisibility(self: *AssistantMessage, block: *Block) void {
        if (block.kind != .thinking) return;
        if (self.hide_thinking_block) {
            block.render_kind = .label;
            if (block.markdown.content.len == 0) {
                block.label.setContent("");
            } else {
                block.label.setContent(self.hidden_thinking_label);
            }
        } else {
            block.render_kind = .markdown;
        }
    }

    fn findBlock(self: *AssistantMessage, content_index: usize) ?usize {
        for (self.blocks.items, 0..) |block, idx| {
            if (block.content_index == content_index) return idx;
        }
        return null;
    }

    fn findInsertIndex(self: *AssistantMessage, content_index: usize) usize {
        for (self.blocks.items, 0..) |block, idx| {
            if (content_index < block.content_index) return idx;
        }
        return self.blocks.items.len;
    }

    pub fn measure(self: *AssistantMessage, width: u32) Measurement {
        if (width == 0) return .{ .min_height = 1, .preferred_height = 1 };
        var total: u32 = 0;
        var seen_visible = false;
        for (self.blocks.items) |*block| {
            const h = self.blockHeight(block, width);
            if (h == 0) continue;
            if (seen_visible) total += 1;
            total += h;
            seen_visible = true;
        }
        return .{ .min_height = if (total > 0) 1 else 0, .preferred_height = total };
    }

    pub fn render(self: *AssistantMessage, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0) return;

        var screen_y: u32 = 0;
        var virtual_y: u32 = 0;
        var seen_visible = false;
        for (self.blocks.items) |*block| {
            const block_h = self.blockHeight(block, w);
            if (block_h == 0) continue;
            const separator_h: u32 = if (seen_visible) 1 else 0;
            const total_h = separator_h + block_h;
            const item_end = virtual_y + total_h;
            if (item_end <= self.scroll_offset) {
                virtual_y = item_end;
                seen_visible = true;
                continue;
            }
            if (screen_y >= h) break;

            const skipped = if (virtual_y < self.scroll_offset) self.scroll_offset - virtual_y else 0;
            const remaining = total_h - skipped;
            const visible_h = @min(remaining, h - screen_y);
            const row_region = region.sub(0, screen_y, w, visible_h);
            self.renderBlock(block, row_region, skipped, visible_h, w, separator_h);
            screen_y += visible_h;
            virtual_y = item_end;
            seen_visible = true;
        }
    }

    fn renderBlock(self: *AssistantMessage, block: *Block, row_region: Region, skipped: u32, visible_h: u32, w: u32, separator_h: u32) void {
        const comp = self.blockComponent(block);
        const comp_h = comp.measure(w).preferred_height;
        const row_skip = skipped;
        if (separator_h > 0 and row_skip < separator_h) {
            const sep_visible = separator_h - row_skip;
            if (visible_h > sep_visible) {
                const sub = row_region.sub(0, sep_visible, w, visible_h - sep_visible);
                self.renderComponentWithScroll(block, sub, 0, comp_h);
            }
        } else {
            self.renderComponentWithScroll(block, row_region, row_skip -| separator_h, comp_h);
        }
    }

    fn renderComponentWithScroll(self: *AssistantMessage, block: *Block, region: Region, skip: u32, comp_h: u32) void {
        _ = self;
        _ = comp_h;
        switch (block.render_kind) {
            .markdown => {
                const md = block.markdown;
                const saved = md.scroll_offset;
                md.scroll_offset = skip;
                md.render(region);
                md.scroll_offset = saved;
            },
            .label => {
                const txt = block.label;
                const saved = txt.scroll_offset;
                txt.scroll_offset = skip;
                txt.render(region);
                txt.scroll_offset = saved;
            },
        }
    }

    fn blockComponent(self: *AssistantMessage, block: *Block) Component {
        _ = self;
        return switch (block.render_kind) {
            .markdown => block.markdown.component(),
            .label => block.label.component(),
        };
    }

    fn blockHeight(self: *AssistantMessage, block: *Block, width: u32) u32 {
        _ = self;
        return switch (block.render_kind) {
            .markdown => block.markdown.measure(width).preferred_height,
            .label => block.label.measure(width).preferred_height,
        };
    }
};

const testing = std.testing;

test "assistant message animation hooks are static" {
    var msg = AssistantMessage.init(testing.allocator);
    defer msg.deinit();

    msg.appendThinking(0, "ponder");
    try testing.expectEqual(@as(?i128, null), msg.nextAnimationDeadline(0));
    try testing.expect(!msg.tickAnimation(0));
    try testing.expect(!msg.deactivateThinkingShimmer());
}
