const std = @import("std");
const component_mod = @import("component.zig");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");
const grapheme = @import("grapheme.zig");
const text_mod = @import("components/text.zig");
const markdown_mod = @import("components/markdown.zig");
const tool_display_mod = @import("tool_display.zig");
const word_wrap_mod = @import("word_wrap.zig");

const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const ToolDisplay = tool_display_mod.ToolDisplay;

/// A row in the conversation transcript.
pub const TranscriptRow = union(enum) {
    /// Accumulated assistant text rendered as markdown.
    assistant_text: *markdown_mod.Markdown,
    /// A tool execution with its display component.
    tool_execution: *ToolExecution,
};

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
};

/// Ordered conversation transcript — the document model for the output area.
///
/// Rows are appended in event order. The transcript handles:
/// - Creating/appending to assistant text rows
/// - Creating tool execution rows and routing updates by tool_call_id
/// - Measuring total height for scroll calculations
/// - Rendering visible rows into a Region given a scroll offset
pub const Transcript = struct {
    rows: std.ArrayListUnmanaged(TranscriptRow) = .empty,
    /// Fast lookup: tool_call_id → row index for routing updates.
    pending_tools: std.StringHashMapUnmanaged(usize) = .{},
    /// Current assistant text row being appended to (index into rows).
    current_text_idx: ?usize = null,
    /// Buffer for accumulating text_delta content.
    text_buf: std.ArrayListUnmanaged(u8) = .empty,

    allocator: std.mem.Allocator,
    scroll_offset: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Transcript {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Transcript) void {
        for (self.rows.items) |row| {
            switch (row) {
                .assistant_text => |md| {
                    md.deinit();
                    self.allocator.destroy(md);
                },
                .tool_execution => |te| te.deinit(),
            }
        }
        self.rows.deinit(self.allocator);
        self.text_buf.deinit(self.allocator);
        // pending_tools keys are borrowed from ToolExecution.tool_call_id — don't free
        self.pending_tools.deinit(self.allocator);
    }

    /// Start a new assistant message (clears text accumulator).
    pub fn beginAssistantMessage(self: *Transcript) void {
        self.text_buf.items.len = 0;
        self.current_text_idx = null;
    }

    /// Append streaming text content.
    pub fn appendText(self: *Transcript, delta: []const u8) void {
        self.text_buf.appendSlice(self.allocator, delta) catch return;

        if (self.current_text_idx) |idx| {
            // Update existing markdown row
            self.rows.items[idx].assistant_text.setContent(self.text_buf.items);
        } else {
            // Create new markdown row
            const md = self.allocator.create(markdown_mod.Markdown) catch return;
            md.* = markdown_mod.Markdown.init(self.allocator);
            md.padding_x = 1;
            md.setContent(self.text_buf.items);
            self.rows.append(self.allocator, .{ .assistant_text = md }) catch {
                md.deinit();
                self.allocator.destroy(md);
                return;
            };
            self.current_text_idx = self.rows.items.len - 1;
        }
    }

    /// Register a new tool execution. Idempotent — skips if tool_call_id already exists.
    pub fn addToolExecution(
        self: *Transcript,
        tool_call_id: []const u8,
        display: ToolDisplay,
    ) void {
        // Already registered (e.g., created during streaming, now getting tool_execution_start)
        if (self.pending_tools.contains(tool_call_id)) {
            display.deinitDisplay();
            return;
        }

        // End current text accumulation — tool breaks the text flow
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

        const row_idx = self.rows.items.len;
        self.rows.append(self.allocator, .{ .tool_execution = te }) catch {
            te.deinit();
            return;
        };
        self.pending_tools.put(self.allocator, te.tool_call_id, row_idx) catch {};
    }

    /// Route an event to a tool execution by ID.
    pub fn updateTool(self: *Transcript, tool_call_id: []const u8, event: ToolDisplay.Event) void {
        const idx = self.pending_tools.get(tool_call_id) orelse return;
        if (idx >= self.rows.items.len) return;
        const row = self.rows.items[idx];
        switch (row) {
            .tool_execution => |te| {
                te.display.apply(event);
                switch (event) {
                    .end => |e| {
                        te.is_complete = true;
                        te.is_error = e.is_error;
                        _ = self.pending_tools.remove(tool_call_id);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    /// Total height of all rows at the given width.
    pub fn totalHeight(self: *Transcript, width: u32) u32 {
        if (width == 0) return 0;
        var h: u32 = 0;
        for (self.rows.items) |row| {
            h += self.rowHeight(row, width);
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

    /// Render visible rows into the region, respecting scroll_offset.
    pub fn render(self: *Transcript, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0) return;

        var virtual_y: u32 = 0; // position in virtual document
        var screen_y: u32 = 0; // position in visible region

        for (self.rows.items) |row| {
            const row_h = self.rowHeight(row, w);
            const row_end = virtual_y + row_h;

            // skip rows entirely above the viewport
            if (row_end <= self.scroll_offset) {
                virtual_y = row_end;
                continue;
            }

            // stop if we've filled the screen
            if (screen_y >= h) break;

            // calculate visible portion of this row
            const row_start_in_viewport = if (virtual_y >= self.scroll_offset)
                virtual_y - self.scroll_offset
            else
                0;
            _ = row_start_in_viewport;

            const visible_h = @min(row_h, h - screen_y);

            // create a sub-region for this row
            const row_region = region.sub(0, screen_y, w, visible_h);

            switch (row) {
                .assistant_text => |md| {
                    // adjust scroll for partial visibility
                    const skip_lines = if (virtual_y < self.scroll_offset)
                        self.scroll_offset - virtual_y
                    else
                        0;
                    const saved_scroll = md.scroll_offset;
                    md.scroll_offset = skip_lines;
                    md.render(row_region);
                    md.scroll_offset = saved_scroll;
                },
                .tool_execution => |te| {
                    // render tool background
                    const bg = if (!te.is_complete)
                        Color.rgb(40, 40, 50) // pending
                    else if (te.is_error)
                        Color.rgb(60, 40, 40) // error
                    else
                        Color.default; // success — no bg

                    if (!bg.eql(Color.default)) {
                        row_region.fill(0, 0, w, visible_h, .{
                            .grapheme = .{ .codepoint = ' ' },
                            .bg = bg,
                        });
                    }

                    // render display content with padding
                    const content_region = row_region.sub(1, 0, if (w > 2) w - 2 else 1, visible_h);
                    te.display.render(content_region);
                },
            }

            screen_y += visible_h;
            virtual_y = row_end;
        }
    }

    fn rowHeight(self: *Transcript, row: TranscriptRow, width: u32) u32 {
        _ = self;
        return switch (row) {
            .assistant_text => |md| @max(1, md.measure(width).preferred_height),
            .tool_execution => |te| {
                const content_w = if (width > 2) width - 2 else 1;
                return @max(1, te.display.measure(content_w).preferred_height);
            },
        };
    }
};

// --- tests ---

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

test "Transcript renders assistant text and tool execution in order" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    // assistant text
    transcript.beginAssistantMessage();
    transcript.appendText("hello from assistant");

    // tool execution
    const display = tool_display_mod.GenericDisplay.create(testing.allocator, "bash").?;
    transcript.addToolExecution("tool-1", display);
    transcript.updateTool("tool-1", .{ .start = .{ .tool_name = "bash", .args_json = "echo hi" } });
    transcript.updateTool("tool-1", .{ .end = .{ .result_text = "hi", .is_error = false } });

    // verify structure
    try testing.expectEqual(@as(usize, 2), transcript.rows.items.len);

    // render into buffer
    var buf = try Buffer.init(testing.allocator, 30, 10);
    defer buf.deinit();
    transcript.render(buf.region());

    // assistant text should be on first rows
    try testing.expectEqual(@as(u21, 'h'), buf.get(1, 0).grapheme.codepoint); // padding_x=1
}
