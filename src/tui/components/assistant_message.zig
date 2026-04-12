const std = @import("std");
const component_mod = @import("../component.zig");
const buffer_mod = @import("../buffer.zig");
const cell_mod = @import("../cell.zig");
const markdown_mod = @import("markdown.zig");
const text_mod = @import("text.zig");
const theme_mod = @import("../theme.zig");
const shimmer_mod = @import("../shimmer.zig");
const word_wrap_mod = @import("../word_wrap.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;
const Buffer = buffer_mod.Buffer;
const Attributes = cell_mod.Attributes;
const Shimmer = shimmer_mod.Config;

pub const AssistantMessage = struct {
    allocator: std.mem.Allocator,
    theme: *const theme_mod.Theme = &theme_mod.Theme.dark,
    hide_thinking_block: bool = false,
    hidden_thinking_label: []const u8 = "Thinking...",
    scroll_offset: u32 = 0,
    shimmer_phase: u32 = 0,
    active_thinking_content_index: ?usize = null,

    blocks: std.ArrayListUnmanaged(Block) = .empty,

    const BlockKind = enum { text, thinking };
    const RenderKind = enum { markdown, label };
    pub const shimmer_step_ns: i128 = 33_333_333; // ≈30 FPS

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
        _ = self.deactivateThinkingShimmer();
    }

    pub fn appendThinking(self: *AssistantMessage, content_index: usize, delta: []const u8) void {
        const block = self.ensureBlock(content_index, .thinking) orelse return;
        block.markdown.appendContent(delta);
        block.markdown.invalidate();
        self.active_thinking_content_index = content_index;
        if (self.hide_thinking_block) self.refreshThinkingVisibility(block);
    }

    pub fn deactivateThinkingShimmer(self: *AssistantMessage) bool {
        const changed = self.active_thinking_content_index != null or self.shimmer_phase != 0;
        self.active_thinking_content_index = null;
        self.shimmer_phase = 0;
        return changed;
    }

    pub fn nextAnimationDeadline(self: *AssistantMessage, now_ns: i128) ?i128 {
        const block = self.activeThinkingBlock() orelse return null;
        if (self.activeThinkingText(block).len == 0) return null;
        return shimmer_mod.nextDeadline(now_ns, self.thinkingShimmerConfig());
    }

    pub fn tickAnimation(self: *AssistantMessage, now_ns: i128) bool {
        const block = self.activeThinkingBlock() orelse {
            if (self.shimmer_phase != 0) {
                self.shimmer_phase = 0;
                return true;
            }
            return false;
        };

        const phase = shimmer_mod.phaseForTime(now_ns, self.thinkingShimmerConfig(), self.activeThinkingText(block));
        if (phase == self.shimmer_phase) return false;
        self.shimmer_phase = phase;
        return true;
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

    fn activeThinkingBlock(self: *AssistantMessage) ?*Block {
        const content_index = self.active_thinking_content_index orelse return null;
        const idx = self.findBlock(content_index) orelse return null;
        const block = &self.blocks.items[idx];
        if (block.kind != .thinking) return null;
        if (self.activeThinkingText(block).len == 0) return null;
        return block;
    }

    fn activeThinkingText(self: *const AssistantMessage, block: *const Block) []const u8 {
        _ = self;
        return switch (block.render_kind) {
            .markdown => block.markdown.content,
            .label => block.label.content,
        };
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
        _ = comp_h;

        if (self.isActiveThinkingBlock(block)) {
            self.renderActiveThinkingBlock(block, region, skip);
            return;
        }

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

    fn isActiveThinkingBlock(self: *AssistantMessage, block: *const Block) bool {
        return if (self.activeThinkingBlock()) |active|
            active.content_index == block.content_index
        else
            false;
    }

    fn renderActiveThinkingBlock(self: *AssistantMessage, block: *const Block, region: Region, skip: u32) void {
        if (region.width == 0 or region.height == 0) return;

        const text = self.activeThinkingText(block);
        const pad_x: u32 = switch (block.render_kind) {
            .markdown => block.markdown.padding_x,
            .label => block.label.padding_x,
        };
        const base_attrs: Attributes = switch (block.render_kind) {
            .markdown => block.markdown.attrs,
            .label => block.label.attrs,
        };

        const content_width: usize = @intCast(if (region.width > pad_x * 2) region.width - pad_x * 2 else 1);
        const lines = word_wrap_mod.wordWrap(text, content_width, self.allocator) catch return;
        defer self.allocator.free(lines);

        var cfg = self.thinkingShimmerConfig();
        cfg.base_attrs = base_attrs;
        cfg.edge_attrs = base_attrs;
        cfg.peak_attrs = base_attrs;

        var row: u32 = 0;
        var virtual_row: u32 = skip;
        while (row < region.height) {
            if (virtual_row >= lines.len) break;
            _ = shimmer_mod.writeSmooth(
                region,
                pad_x,
                row,
                lines[virtual_row].text(text),
                cfg,
                self.shimmer_phase,
                96,
            );
            row += 1;
            virtual_row += 1;
        }
    }

    fn thinkingShimmerConfig(self: *const AssistantMessage) Shimmer {
        return .{
            .step_ns = shimmer_step_ns,
            .lead_pad_cols = 4,
            .tail_pad_cols = 8,
            .band_half_width = 5,
            .base_fg = self.theme.fg(.thinking_text),
            .edge_fg = self.theme.fg(.thinking_text),
            .peak_fg = self.theme.fg(.accent),
            .base_attrs = .{},
            .edge_attrs = .{},
            .peak_attrs = .{},
        };
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

test "assistant thinking shimmer tracks only the actively streaming block" {
    var msg = AssistantMessage.init(testing.allocator);
    defer msg.deinit();

    msg.appendThinking(0, "ponder");
    try testing.expect(msg.nextAnimationDeadline(AssistantMessage.shimmer_step_ns) != null);

    msg.appendText(1, "done");
    try testing.expectEqual(@as(?usize, null), msg.active_thinking_content_index);
    try testing.expectEqual(@as(?i128, null), msg.nextAnimationDeadline(AssistantMessage.shimmer_step_ns));
}

test "assistant thinking shimmer highlights the visible latest block" {
    var msg = AssistantMessage.init(testing.allocator);
    defer msg.deinit();
    msg.appendThinking(0, "abc");
    msg.shimmer_phase = 5;

    var buf = try Buffer.init(testing.allocator, 12, 2);
    defer buf.deinit();
    msg.render(buf.region());

    try testing.expect(buf.get(1, 0).fg.eql(msg.theme.fg(.accent)));
}

test "assistant thinking shimmer also animates hidden thinking label" {
    var msg = AssistantMessage.init(testing.allocator);
    defer msg.deinit();
    msg.setHideThinkingBlock(true);
    msg.appendThinking(0, "secret thoughts");
    msg.shimmer_phase = 5;

    try testing.expect(msg.nextAnimationDeadline(AssistantMessage.shimmer_step_ns) != null);

    var buf = try Buffer.init(testing.allocator, 16, 2);
    defer buf.deinit();
    msg.render(buf.region());

    try testing.expect(buf.get(1, 0).fg.eql(msg.theme.fg(.accent)));
}

test "assistant thinking shimmer clears active thinking background" {
    var msg = AssistantMessage.init(testing.allocator);
    defer msg.deinit();
    msg.appendThinking(0, "abc");
    msg.shimmer_phase = 5;

    const block = msg.activeThinkingBlock().?;
    block.markdown.bg = msg.theme.fg(.muted);

    var buf = try Buffer.init(testing.allocator, 12, 2);
    defer buf.deinit();
    msg.render(buf.region());

    try testing.expect(buf.get(1, 0).bg.is_default);
}
