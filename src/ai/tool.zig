const std = @import("std");
const ai = @import("root.zig");
const json_value = @import("../json/value.zig");
const cancel = @import("../runtime/cancel.zig");

pub const ToolOpId = u64;

pub const ExecutionMode = enum {
    sequential,
    parallel,
};

pub const AgentToolResult = ai.protocol.AgentToolResult;

pub const AgentToolResultOwned = struct {
    result: AgentToolResult,

    pub fn deinit(self: AgentToolResultOwned, allocator: std.mem.Allocator) void {
        for (self.result.content) |block| switch (block) {
            .text => |text| {
                allocator.free(text.text);
                if (text.text_signature) |sig| allocator.free(sig);
            },
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
        };
        allocator.free(self.result.content);
        if (self.result.details) |details| {
            var owned = details;
            owned.deinit();
        }
        if (self.result.presentation) |presentation| {
            var owned = presentation;
            owned.deinit();
        }
    }
};

pub const ToolInvocation = struct {
    op_id: ToolOpId,
    source_index: usize,
    // Borrowed invocation ingress. Synchronous tools may inspect these fields
    // during execute. Async/runtime-backed tools must clone any retained id,
    // name, or args into operation-owned memory before returning.
    tool_call_id: []const u8,
    tool_name: []const u8,
    args: json_value.BorrowedValue,
    // Scoped cancellation intent. Tools may observe it, but cancellation
    // completion is a ToolTerminal.aborted completion emitted through the sink.
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
        (AgentToolResultOwned{ .result = self.partial_result }).deinit(allocator);
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
            .completed => |result| (AgentToolResultOwned{ .result = result }).deinit(allocator),
            .failed => |result| (AgentToolResultOwned{ .result = result }).deinit(allocator),
            .aborted => |result| (AgentToolResultOwned{ .result = result }).deinit(allocator),
        }
    }
};

pub const AgentTool = struct {
    name: []const u8,
    description: []const u8,
    parameters: json_value.BorrowedValue,
    ctx: ?*anyopaque = null,
    execution_mode: ?ExecutionMode = null,
    execute_fn: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, invocation: ToolInvocation, sink: ToolCompletionSink) void, // ziglint-ignore: Z024

    pub fn execute(self: AgentTool, allocator: std.mem.Allocator, invocation: ToolInvocation, sink: ToolCompletionSink) void { // ziglint-ignore: Z024
        self.execute_fn(self.ctx, allocator, invocation, sink);
    }
};

pub const ToolCompletionSink = struct {
    ctx: ?*anyopaque = null,
    // Synchronous consumption boundary. ToolCompletion can contain owned heap
    // payloads and must not be bitwise-copied by value. The callee consumes the
    // pointed-to completion before returning.
    emit_fn: *const fn (completion: *ToolCompletion, ctx: ?*anyopaque) void,

    pub fn emit(self: ToolCompletionSink, completion: *ToolCompletion) void {
        self.emit_fn(completion, self.ctx);
    }
};
