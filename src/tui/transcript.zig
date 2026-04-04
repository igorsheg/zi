const std = @import("std");
const component_mod = @import("component.zig");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");
const grapheme = @import("grapheme.zig");
const markdown_mod = @import("components/markdown.zig");
const tool_display_mod = @import("tool_display.zig");
const theme_mod = @import("theme.zig");
const word_wrap_mod = @import("word_wrap.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const ToolDisplay = tool_display_mod.ToolDisplay;

// ── Transcript Item ───────────────────────────────────────────────

/// Behavior tag for items that need special rendering treatment.
/// Most items are .generic (just render the component). Built-in types
/// use tags for: bg fill (tool), spacer (user_message), scroll merge (assistant).
pub const ItemKind = enum {
    generic,
    assistant_text,
    user_message,
    tool_execution,
};

/// Cleanup function type for owned items.
pub const DeinitFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void;

/// A single item in the transcript — generic component with optional metadata.
///
/// Replaces the previous closed TranscriptRow union. Every item is a Component
/// that can be rendered/measured via the vtable. Built-in types (assistant,
/// tool, user) are convenience constructors that set `kind` + metadata.
/// Extensions inject arbitrary components with kind=.generic.
pub const TranscriptItem = struct {
    component: Component,
    kind: ItemKind = .generic,
    /// For tool_execution: route updates by ID via pending_tools HashMap.
    tool_call_id: ?[]const u8 = null,
    /// Owned cleanup context. Called on item removal/transcript clear.
    deinit_ctx: ?*anyopaque = null,
    deinit_fn: ?DeinitFn = null,
    /// Extra height added outside the component (e.g., spacer before user message).
    extra_height: u32 = 0,

    pub fn deinit(self: *TranscriptItem, allocator: std.mem.Allocator) void {
        if (self.deinit_fn) |f| f(self.deinit_ctx.?, allocator);
    }
};

// ── Tool Execution ────────────────────────────────────────────────

/// State for a single tool execution within the transcript.
pub const ToolExecution = struct {
    tool_call_id: []u8,
    display: ToolDisplay,
    is_complete: bool = false,
    is_error: bool = false,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ToolExecution) void {
        self.display.deinitDisplay();
        self.allocator.free(self.tool_call_id);
        self.allocator.destroy(self);
    }

    fn deinitItem(ctx: *anyopaque, _: std.mem.Allocator) void {
        const self: *ToolExecution = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    pub fn measure(self: *ToolExecution, width: u32) Measurement {
        const content_w = if (width > 2) width - 2 else 1;
        return .{
            .min_height = 1,
            .preferred_height = @max(1, self.display.measure(content_w).preferred_height),
        };
    }

    pub fn render(self: *ToolExecution, region: Region) void {
        const content_region = region.sub(1, 0, if (region.width > 2) region.width - 2 else 1, region.height);
        self.display.render(content_region);
    }

    pub fn component(self: *ToolExecution) Component {
        return Component.init(ToolExecution, self);
    }
};

// ── Markdown wrapper deinit ───────────────────────────────────────

fn deinitMarkdown(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const md: *markdown_mod.Markdown = @ptrCast(@alignCast(ctx));
    md.deinit();
    allocator.destroy(md);
}

// ── Transcript ────────────────────────────────────────────────────

/// Scrollable conversation transcript with generic item storage.
///
/// Items are Components with optional metadata (kind, tool_call_id).
/// The transcript handles:
/// - Appending items in event order
/// - Streaming text merge (current_text_idx for assistant text deltas)
/// - Tool update routing by tool_call_id (O(1) HashMap lookup)
/// - Measuring total height for scroll calculations
/// - Rendering visible items into a Region given a scroll offset
///
/// Built-in types (assistant, tool, user) are convenience methods.
/// Extensions add arbitrary Components via addComponent().
pub const Transcript = struct {
    items: std.ArrayListUnmanaged(TranscriptItem) = .empty,
    /// Fast lookup: tool_call_id → item index for routing updates.
    pending_tools: std.StringHashMapUnmanaged(usize) = .{},
    /// Current assistant text item being appended to (index into items).
    current_text_idx: ?usize = null,

    allocator: std.mem.Allocator,
    theme: *const theme_mod.Theme = &theme_mod.Theme.dark,
    scroll_offset: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Transcript {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Transcript) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.pending_tools.deinit(self.allocator);
    }

    // ── Generic mutation API ──────────────────────────────────────

    /// Append an arbitrary component to the transcript.
    pub fn addComponent(self: *Transcript, comp: Component) void {
        self.current_text_idx = null;
        self.items.append(self.allocator, .{ .component = comp }) catch return;
    }

    /// Remove all items and reset state. Used on session reset / /clear.
    pub fn clearAll(self: *Transcript) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.items.len = 0;
        self.pending_tools.clearRetainingCapacity();
        self.current_text_idx = null;
        self.scroll_offset = 0;
    }

    // ── Built-in convenience methods ──────────────────────────────

    /// Start a new assistant message.
    pub fn beginAssistantMessage(self: *Transcript) void {
        self.current_text_idx = null;
    }

    /// Append streaming text content to the current assistant message.
    pub fn appendText(self: *Transcript, delta: []const u8) void {
        if (self.current_text_idx) |idx| {
            // Reach into the markdown component to append
            const item = &self.items.items[idx];
            const md: *markdown_mod.Markdown = @ptrCast(@alignCast(item.component.ptr));
            md.appendContent(delta);
        } else {
            const md = self.allocator.create(markdown_mod.Markdown) catch return;
            md.* = markdown_mod.Markdown.init(self.allocator);
            md.padding_x = 1;
            md.appendContent(delta);
            self.items.append(self.allocator, .{
                .component = md.component(),
                .kind = .assistant_text,
                .deinit_ctx = @ptrCast(md),
                .deinit_fn = deinitMarkdown,
            }) catch {
                md.deinit();
                self.allocator.destroy(md);
                return;
            };
            self.current_text_idx = self.items.items.len - 1;
        }
    }

    /// Register a new tool execution.
    pub fn addToolExecution(
        self: *Transcript,
        tool_call_id: []const u8,
        display: ToolDisplay,
    ) void {
        if (self.pending_tools.contains(tool_call_id)) {
            display.deinitDisplay();
            return;
        }

        self.current_text_idx = null;

        const id = self.allocator.dupe(u8, tool_call_id) catch return;
        const te = self.allocator.create(ToolExecution) catch {
            self.allocator.free(id);
            return;
        };
        te.* = .{
            .tool_call_id = id,
            .display = display,
            .allocator = self.allocator,
        };

        const item_idx = self.items.items.len;
        self.items.append(self.allocator, .{
            .component = te.component(),
            .kind = .tool_execution,
            .tool_call_id = te.tool_call_id,
            .deinit_ctx = @ptrCast(te),
            .deinit_fn = ToolExecution.deinitItem,
        }) catch {
            te.deinit();
            return;
        };
        self.pending_tools.put(self.allocator, te.tool_call_id, item_idx) catch {};
    }

    /// Route an event to a tool execution by ID.
    pub fn updateTool(self: *Transcript, tool_call_id: []const u8, event: ToolDisplay.Event) void {
        const idx = self.pending_tools.get(tool_call_id) orelse return;
        if (idx >= self.items.items.len) return;
        const item = &self.items.items[idx];
        if (item.kind != .tool_execution) return;
        const te: *ToolExecution = @ptrCast(@alignCast(item.deinit_ctx.?));
        te.display.apply(event);
        switch (event) {
            .end => |e| {
                te.is_complete = true;
                te.is_error = e.is_error;
                _ = self.pending_tools.remove(tool_call_id);
            },
            else => {},
        }
    }

    /// Add a user message bubble.
    pub fn addUserMessage(self: *Transcript, text: []const u8) void {
        self.current_text_idx = null;

        const md = self.allocator.create(markdown_mod.Markdown) catch return;
        md.* = markdown_mod.Markdown.init(self.allocator);
        md.padding_x = 1;
        md.padding_y = 1;
        md.bg = self.theme.bg(.user_message_bg);
        md.fg = self.theme.fg(.user_message_text);
        md.setContent(text);

        self.items.append(self.allocator, .{
            .component = md.component(),
            .kind = .user_message,
            .extra_height = 1, // spacer before user message
            .deinit_ctx = @ptrCast(md),
            .deinit_fn = deinitMarkdown,
        }) catch {
            md.deinit();
            self.allocator.destroy(md);
            return;
        };
    }

    // ── Layout / scroll ───────────────────────────────────────────

    /// Total height of all items at the given width.
    pub fn totalHeight(self: *Transcript, width: u32) u32 {
        if (width == 0) return 0;
        var h: u32 = 0;
        for (self.items.items) |*item| {
            h += self.itemHeight(item, width);
        }
        return h;
    }

    /// Scroll to bottom so last content is visible.
    pub fn scrollToBottom(self: *Transcript, width: u32, visible_height: u32) void {
        const total = self.totalHeight(width);
        if (total > visible_height) {
            self.scroll_offset = total - visible_height;
        } else {
            self.scroll_offset = 0;
        }
    }

    pub fn measure(self: *Transcript, width: u32) Measurement {
        const total = self.totalHeight(width);
        return .{ .min_height = 1, .preferred_height = total };
    }

    pub fn component(self: *Transcript) component_mod.Component {
        return component_mod.Component.init(Transcript, self);
    }

    /// Render visible items into the region, respecting scroll_offset.
    pub fn render(self: *Transcript, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0) return;

        var virtual_y: u32 = 0;
        var screen_y: u32 = 0;

        for (self.items.items) |*item| {
            const item_h = self.itemHeight(item, w);
            const item_end = virtual_y + item_h;

            if (item_end <= self.scroll_offset) {
                virtual_y = item_end;
                continue;
            }
            if (screen_y >= h) break;

            const skipped = if (virtual_y < self.scroll_offset) self.scroll_offset - virtual_y else 0;
            const remaining = item_h - skipped;
            const visible_h = @min(remaining, h - screen_y);
            const row_region = region.sub(0, screen_y, w, visible_h);

            self.renderItem(item, row_region, skipped, visible_h, w);

            screen_y += visible_h;
            virtual_y = item_end;
        }
    }

    fn renderItem(self: *Transcript, item: *TranscriptItem, row_region: Region, skipped: u32, visible_h: u32, w: u32) void {
        switch (item.kind) {
            .tool_execution => {
                // Tool bg fill
                const te: *ToolExecution = @ptrCast(@alignCast(item.deinit_ctx.?));
                const bg = if (!te.is_complete)
                    self.theme.bg(.tool_pending_bg)
                else if (te.is_error)
                    self.theme.bg(.tool_error_bg)
                else
                    self.theme.bg(.tool_success_bg);

                if (!bg.eql(Color.default)) {
                    row_region.fill(0, 0, w, visible_h, .{
                        .grapheme = .{ .codepoint = ' ' },
                        .bg = bg,
                    });
                }
                item.component.render(row_region);
            },
            .user_message => {
                // User message: extra_height=1 spacer before the markdown bubble
                const row_skip = skipped;
                if (row_skip == 0) {
                    // Spacer visible — render md into remaining space
                    if (visible_h > 1) {
                        const md_region = row_region.sub(0, 1, w, visible_h - 1);
                        // Temporarily set scroll offset on the markdown for partial visibility
                        const md: *markdown_mod.Markdown = @ptrCast(@alignCast(item.deinit_ctx.?));
                        const saved = md.scroll_offset;
                        md.scroll_offset = 0;
                        md.render(md_region);
                        md.scroll_offset = saved;
                    }
                } else {
                    // Spacer scrolled past — render md with adjusted scroll
                    const md: *markdown_mod.Markdown = @ptrCast(@alignCast(item.deinit_ctx.?));
                    const saved = md.scroll_offset;
                    md.scroll_offset = row_skip - 1; // -1 for spacer
                    md.render(row_region);
                    md.scroll_offset = saved;
                }
            },
            .assistant_text => {
                // Assistant text: partial scroll adjustment
                const md: *markdown_mod.Markdown = @ptrCast(@alignCast(item.deinit_ctx.?));
                const saved = md.scroll_offset;
                md.scroll_offset = skipped;
                md.render(row_region);
                md.scroll_offset = saved;
            },
            .generic => {
                // Generic: just render the component
                item.component.render(row_region);
            },
        }
    }

    fn itemHeight(self: *Transcript, item: *TranscriptItem, width: u32) u32 {
        _ = self;
        return @max(1, item.component.measure(width).preferred_height) + item.extra_height;
    }
};

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

test "Transcript renders assistant text and tool execution in order" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    transcript.beginAssistantMessage();
    transcript.appendText("hello from assistant");

    const display = tool_display_mod.GenericDisplay.create(testing.allocator, "bash").?;
    transcript.addToolExecution("tool-1", display);
    transcript.updateTool("tool-1", .{ .start = .{ .tool_name = "bash", .args_json = "echo hi" } });
    transcript.updateTool("tool-1", .{ .end = .{ .result_text = "hi", .is_error = false } });

    try testing.expectEqual(@as(usize, 2), transcript.items.items.len);

    var buf = try Buffer.init(testing.allocator, 30, 10);
    defer buf.deinit();
    transcript.render(buf.region());

    try testing.expectEqual(@as(u21, 'h'), buf.get(1, 0).grapheme.codepoint);
}

test "Transcript clearAll removes all items and resets state" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    transcript.beginAssistantMessage();
    transcript.appendText("hello");
    transcript.addUserMessage("user msg");

    try testing.expectEqual(@as(usize, 2), transcript.items.items.len);

    transcript.clearAll();

    try testing.expectEqual(@as(usize, 0), transcript.items.items.len);
    try testing.expectEqual(@as(?usize, null), transcript.current_text_idx);
    try testing.expectEqual(@as(u32, 0), transcript.scroll_offset);
}
