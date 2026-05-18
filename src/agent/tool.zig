const std = @import("std");
const ai = @import("../ai/root.zig");
const json_value = @import("../json/value.zig");
const cancel = @import("../runtime/cancel.zig");

pub const ToolOpId = u64;

pub const AgentToolResult = struct {
    content: []const ContentBlock,
    details: json_value.OwnedValue = json_value.OwnedValue.nullValue(),
    presentation: json_value.OwnedValue = json_value.OwnedValue.nullValue(),
    is_error: bool = false,

    pub const ContentBlock = union(enum) {
        text: ai.protocol.TextContent,
        image: ai.protocol.ImageContent,
    };

    pub fn deinit(self: AgentToolResult, allocator: std.mem.Allocator) void {
        for (self.content) |block| switch (block) {
            .text => |text| {
                allocator.free(text.text);
                if (text.text_signature) |sig| allocator.free(sig);
            },
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
        };
        allocator.free(self.content);
        var details = self.details;
        details.deinit();
        var presentation = self.presentation;
        presentation.deinit();
    }
};

pub const ToolInvocation = struct {
    op_id: ToolOpId,
    source_index: usize,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args: json_value.BorrowedValue,
    signal: cancel.Token,
};

pub const ToolTerminal = union(enum) {
    completed: AgentToolResult,
    failed: AgentToolResult,
    aborted: AgentToolResult,
};

pub const ToolCompletion = union(enum) {
    update: ToolUpdate,
    terminal: ToolTerminalCompletion,
};

pub const ToolUpdate = struct {
    op_id: ToolOpId,
    source_index: usize,
    tool_call_id: []const u8,
    tool_name: []const u8,
    partial_result: AgentToolResult,

    pub fn deinit(self: ToolUpdate, allocator: std.mem.Allocator) void {
        self.partial_result.deinit(allocator);
    }
};

pub const ToolTerminalCompletion = struct {
    op_id: ToolOpId,
    source_index: usize,
    tool_call_id: []const u8,
    tool_name: []const u8,
    terminal: ToolTerminal,

    pub fn deinit(self: ToolTerminalCompletion, allocator: std.mem.Allocator) void {
        switch (self.terminal) {
            .completed => |result| result.deinit(allocator),
            .failed => |result| result.deinit(allocator),
            .aborted => |result| result.deinit(allocator),
        }
    }
};

pub const AgentTool = struct {
    name: []const u8,
    description: []const u8,
    parameters: json_value.BorrowedValue,
    ctx: ?*anyopaque = null,
    execute_fn: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, invocation: ToolInvocation, sink: ToolCompletionSink) void,

    pub fn execute(self: AgentTool, allocator: std.mem.Allocator, invocation: ToolInvocation, sink: ToolCompletionSink) void {
        self.execute_fn(self.ctx, allocator, invocation, sink);
    }
};

pub const ToolCompletionSink = struct {
    ctx: ?*anyopaque = null,
    emit_fn: *const fn (completion: ToolCompletion, ctx: ?*anyopaque) void,

    pub fn emit(self: ToolCompletionSink, completion: ToolCompletion) void {
        self.emit_fn(completion, self.ctx);
    }
};
