const std = @import("std");
const component_mod = @import("../primitives/view.zig");
const buffer_mod = @import("../primitives/surface.zig");
const markdown_mod = @import("markdown.zig");
const text_mod = @import("../components/text.zig");
const grapheme_mod = @import("../grapheme.zig");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;

pub const AssistantRowModel = struct {
    blocks: std.ArrayListUnmanaged(Block) = .empty,

    pub const Block = union(enum) {
        text: []u8,
        thinking: []u8,

        fn clone(self: Block, allocator: std.mem.Allocator) !Block {
            return switch (self) {
                .text => |text| .{ .text = try allocator.dupe(u8, text) },
                .thinking => |thinking| .{ .thinking = try allocator.dupe(u8, thinking) },
            };
        }

        fn deinit(self: *Block, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .text => |text| allocator.free(text),
                .thinking => |thinking| allocator.free(thinking),
            }
            self.* = undefined;
        }

        fn content(self: Block) []const u8 {
            return switch (self) {
                .text => |text| text,
                .thinking => |thinking| thinking,
            };
        }
    };

    pub fn clone(self: AssistantRowModel, allocator: std.mem.Allocator) !AssistantRowModel {
        var out: AssistantRowModel = .{};
        errdefer out.deinit(allocator);

        for (self.blocks.items) |block| {
            try out.blocks.append(allocator, try block.clone(allocator));
        }
        return out;
    }

    pub fn deinit(self: *AssistantRowModel, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*block| block.deinit(allocator);
        self.blocks.deinit(allocator);
        self.* = .{};
    }
};

pub const AssistantMessage = struct {
    allocator: std.mem.Allocator,
    theme: *const theme_mod.Theme = undefined,
    hide_thinking_block: bool = false,
    hidden_thinking_label: []const u8 = "Thinking...",

    model: AssistantRowModel = .{},
    render_blocks: std.ArrayListUnmanaged(RenderBlock) = .empty,
    width_method: grapheme_mod.WidthMethod,

    const RenderBlock = union(enum) {
        markdown: *markdown_mod.Markdown,
        label: *text_mod.Text,

        fn deinit(self: *RenderBlock, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .markdown => |md| {
                    md.deinit();
                    allocator.destroy(md);
                },
                .label => |label| {
                    label.deinit();
                    allocator.destroy(label);
                },
            }
            self.* = undefined;
        }
    };

    pub fn init(allocator: std.mem.Allocator, width_method: grapheme_mod.WidthMethod) AssistantMessage {
        return .{ .allocator = allocator, .theme = themes_builtin.dark(), .width_method = width_method };
    }

    pub fn deinit(self: *AssistantMessage) void {
        self.deinitRenderBlocks();
        self.model.deinit(self.allocator);
    }

    pub fn setWidthMethod(self: *AssistantMessage, width_method: grapheme_mod.WidthMethod) void {
        if (self.width_method == width_method) return;
        self.width_method = width_method;
        for (self.render_blocks.items) |*block| {
            switch (block.*) {
                .markdown => |md| md.setWidthMethod(width_method),
                .label => |label| label.setWidthMethod(width_method),
            }
        }
    }

    pub fn component(self: *AssistantMessage) Component {
        return Component.init(AssistantMessage, self);
    }

    pub fn setOwnedModel(self: *AssistantMessage, model: *AssistantRowModel) !void {
        var new_render_blocks: std.ArrayListUnmanaged(RenderBlock) = .empty;
        errdefer deinitRenderBlocksList(&new_render_blocks, self.allocator);
        try self.buildRenderBlocks(&new_render_blocks, model.*, self.hide_thinking_block);

        self.deinitRenderBlocks();
        self.model.deinit(self.allocator);
        self.model = model.*;
        model.* = .{};
        self.render_blocks = new_render_blocks;
    }

    pub fn setHideThinkingBlock(self: *AssistantMessage, hide: bool) !void {
        if (self.hide_thinking_block == hide) return;
        try self.rebuildRenderBlocks(hide, self.hidden_thinking_label);
    }

    pub fn setHiddenThinkingLabel(self: *AssistantMessage, label: []const u8) !void {
        if (std.mem.eql(u8, self.hidden_thinking_label, label)) return;
        try self.rebuildRenderBlocks(self.hide_thinking_block, label);
    }

    fn rebuildRenderBlocks(self: *AssistantMessage, hide: bool, label: []const u8) !void {
        var new_render_blocks: std.ArrayListUnmanaged(RenderBlock) = .empty;
        errdefer deinitRenderBlocksList(&new_render_blocks, self.allocator);
        const previous_label = self.hidden_thinking_label;
        self.hidden_thinking_label = label;
        errdefer self.hidden_thinking_label = previous_label;
        try self.buildRenderBlocks(&new_render_blocks, self.model, hide);

        self.deinitRenderBlocks();
        self.hide_thinking_block = hide;
        self.render_blocks = new_render_blocks;
    }

    fn buildRenderBlocks(
        self: *AssistantMessage,
        out: *std.ArrayListUnmanaged(RenderBlock),
        model: AssistantRowModel,
        hide_thinking_block: bool,
    ) !void {
        for (model.blocks.items) |block| {
            switch (block) {
                .text => try out.append(self.allocator, .{ .markdown = try self.createMarkdown(block.content(), false) }),
                .thinking => {
                    if (hide_thinking_block) {
                        const label = if (block.content().len == 0) "" else self.hidden_thinking_label;
                        try out.append(self.allocator, .{ .label = try self.createThinkingLabel(label) });
                    } else {
                        try out.append(self.allocator, .{ .markdown = try self.createMarkdown(block.content(), true) });
                    }
                },
            }
        }
    }

    fn createMarkdown(self: *AssistantMessage, content: []const u8, thinking: bool) !*markdown_mod.Markdown {
        const md = try self.allocator.create(markdown_mod.Markdown);
        errdefer self.allocator.destroy(md);

        md.* = markdown_mod.Markdown.init(self.allocator, self.width_method);
        errdefer md.deinit();
        md.padding_x = 1;
        md.theme = self.theme;
        if (thinking) {
            md.fg = self.theme.fg(.thinking_text);
            md.attrs = .{ .italic = true };
        }
        md.setContent(content);
        return md;
    }

    fn createThinkingLabel(self: *AssistantMessage, content: []const u8) !*text_mod.Text {
        const label = try self.allocator.create(text_mod.Text);
        errdefer self.allocator.destroy(label);

        label.* = text_mod.Text.init(self.allocator, self.width_method);
        errdefer label.deinit();
        label.padding_x = 1;
        label.fg = self.theme.fg(.thinking_text);
        label.attrs = .{ .italic = true };
        label.setContent(content);
        return label;
    }

    fn deinitRenderBlocks(self: *AssistantMessage) void {
        deinitRenderBlocksList(&self.render_blocks, self.allocator);
    }

    pub fn deactivateThinkingShimmer(_: *AssistantMessage) bool {
        return false;
    }

    pub fn nextAnimationDeadline(_: *AssistantMessage, _: i128) ?i128 {
        return null;
    }

    pub fn tickAnimation(_: *AssistantMessage, _: i128) bool {
        return false;
    }

    pub fn measure(self: *AssistantMessage, width: u32) Measurement {
        if (width == 0) return .{ .min_height = 1, .preferred_height = 1 };
        var total: u32 = 0;
        var seen_visible = false;
        for (self.render_blocks.items) |*block| {
            const h = self.blockHeight(block, width);
            if (h == 0) continue;
            if (seen_visible) total += 1;
            total += h;
            seen_visible = true;
        }
        return .{ .min_height = if (total > 0) 1 else 0, .preferred_height = total };
    }

    pub fn render(self: *AssistantMessage, region: Region) void {
        self.renderSlice(region, 0);
    }

    pub fn renderSlice(self: *AssistantMessage, region: Region, first_row: u32) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0) return;

        var screen_y: u32 = 0;
        var virtual_y: u32 = 0;
        var seen_visible = false;
        for (self.render_blocks.items) |*block| {
            const block_h = self.blockHeight(block, w);
            if (block_h == 0) continue;
            const separator_h: u32 = if (seen_visible) 1 else 0;
            const total_h = separator_h + block_h;
            const item_end = virtual_y + total_h;
            if (item_end <= first_row) {
                virtual_y = item_end;
                seen_visible = true;
                continue;
            }
            if (screen_y >= h) break;

            const skipped = if (virtual_y < first_row) first_row - virtual_y else 0;
            const remaining = total_h - skipped;
            const visible_h = @min(remaining, h - screen_y);
            const row_region = region.sub(0, screen_y, w, visible_h);
            self.renderBlock(block, row_region, skipped, w, separator_h);
            screen_y += visible_h;
            virtual_y = item_end;
            seen_visible = true;
        }
    }

    fn renderBlock(self: *AssistantMessage, block: *RenderBlock, row_region: Region, skipped: u32, w: u32, separator_h: u32) void {
        const comp = self.blockComponent(block);
        const row_skip = skipped;
        if (separator_h > 0 and row_skip < separator_h) {
            const sep_visible = separator_h - row_skip;
            if (row_region.height > sep_visible) {
                const sub = row_region.sub(0, sep_visible, w, row_region.height - sep_visible);
                renderComponentSlice(comp, sub, 0);
            }
        } else {
            renderComponentSlice(comp, row_region, row_skip -| separator_h);
        }
    }

    fn blockComponent(self: *AssistantMessage, block: *RenderBlock) Component {
        _ = self;
        return switch (block.*) {
            .markdown => |md| md.component(),
            .label => |label| label.component(),
        };
    }

    fn blockHeight(self: *AssistantMessage, block: *RenderBlock, width: u32) u32 {
        _ = self;
        return switch (block.*) {
            .markdown => |md| md.measure(width).preferred_height,
            .label => |label| label.measure(width).preferred_height,
        };
    }
};

fn deinitRenderBlocksList(blocks: *std.ArrayListUnmanaged(AssistantMessage.RenderBlock), allocator: std.mem.Allocator) void {
    for (blocks.items) |*block| block.deinit(allocator);
    blocks.deinit(allocator);
    blocks.* = .empty;
}

fn renderComponentSlice(comp: Component, region: Region, first_row: u32) void {
    if (first_row == 0) {
        comp.render(region);
        return;
    }
    comp.renderSlice(region, first_row);
}

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

fn appendModelBlock(model: *AssistantRowModel, block: AssistantRowModel.Block) !void {
    try model.blocks.append(testing.allocator, try block.clone(testing.allocator));
}

fn bufferText(buf: *const Buffer, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (0..buf.height) |row| {
        if (row > 0) try out.append(allocator, '\n');
        var end = buf.width;
        while (end > 0 and buf.cellIsSpace(buf.get(end - 1, @intCast(row)))) : (end -= 1) {}
        for (0..end) |col| {
            try buf.appendCellText(&out, allocator, buf.get(@intCast(col), @intCast(row)));
        }
    }

    return out.toOwnedSlice(allocator);
}

test "assistant message renders stable row model and hidden thinking label" {
    var model: AssistantRowModel = .{};
    defer model.deinit(testing.allocator);
    try appendModelBlock(&model, .{ .text = @constCast("hello") });
    try appendModelBlock(&model, .{ .thinking = @constCast("ponder") });
    try appendModelBlock(&model, .{ .text = @constCast("world") });

    var msg = AssistantMessage.init(testing.allocator, .wcwidth);
    defer msg.deinit();
    try msg.setOwnedModel(&model);

    var visible_buf = try Buffer.init(testing.allocator, 40, 8, .wcwidth);
    defer visible_buf.deinit();
    msg.render(visible_buf.region());

    const visible_text = try bufferText(&visible_buf, testing.allocator);
    defer testing.allocator.free(visible_text);
    try testing.expect(std.mem.indexOf(u8, visible_text, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, visible_text, "ponder") != null);
    try testing.expect(std.mem.indexOf(u8, visible_text, "world") != null);

    try msg.setHideThinkingBlock(true);

    var hidden_buf = try Buffer.init(testing.allocator, 40, 8, .wcwidth);
    defer hidden_buf.deinit();
    msg.render(hidden_buf.region());

    const hidden_text = try bufferText(&hidden_buf, testing.allocator);
    defer testing.allocator.free(hidden_text);
    try testing.expect(std.mem.indexOf(u8, hidden_text, "Thinking...") != null);
    try testing.expect(std.mem.indexOf(u8, hidden_text, "ponder") == null);

    try msg.setHiddenThinkingLabel("Pondering...");
    var custom_label_buf = try Buffer.init(testing.allocator, 40, 8, .wcwidth);
    defer custom_label_buf.deinit();
    msg.render(custom_label_buf.region());

    const custom_label_text = try bufferText(&custom_label_buf, testing.allocator);
    defer testing.allocator.free(custom_label_text);
    try testing.expect(std.mem.indexOf(u8, custom_label_text, "Pondering...") != null);
    try testing.expect(std.mem.indexOf(u8, custom_label_text, "Thinking...") == null);
}
