const std = @import("std");
const parse_mod = @import("parse.zig");

pub const ExecutionPlan = union(enum) {
    help,
    version,
    run: RunPlan,
};

pub const RunPlan = struct {
    prompt: []const u8,
    output: OutputMode = .text,
    model: ?[]const u8 = null,
    tools: ToolsMode = .builtins,

    pub fn deinit(self: *RunPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
        self.* = undefined;
    }
};

pub const OutputMode = enum { text, final_text, jsonl_events };
pub const ToolsMode = enum { none, builtins };

pub const Diagnostic = union(enum) {
    missing_prompt,
    invalid_mode: []const u8,
    conflicting_output_modes,
};

pub const Result = union(enum) {
    ok: ExecutionPlan,
    err: Diagnostic,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*ok| switch (ok.*) {
                .run => |*run| run.deinit(allocator),
                .help, .version => {},
            },
            .err => {},
        }
        self.* = undefined;
    }
};

pub fn build(allocator: std.mem.Allocator, raw: parse_mod.RawCommand) error{OutOfMemory}!Result {
    return switch (raw) {
        .help => .{ .ok = .help },
        .version => .{ .ok = .version },
        .run => |run| buildRun(allocator, run),
    };
}

fn buildRun(allocator: std.mem.Allocator, raw: parse_mod.RawRun) error{OutOfMemory}!Result {
    if (raw.prompt_parts.len == 0) return .{ .err = .missing_prompt };
    const output: OutputMode = blk: {
        if (raw.print and raw.mode != null) return .{ .err = .conflicting_output_modes };
        if (raw.print) break :blk .final_text;
        if (raw.mode) |mode| {
            if (std.mem.eql(u8, mode, "text")) break :blk .text;
            if (std.mem.eql(u8, mode, "json")) break :blk .jsonl_events;
            return .{ .err = .{ .invalid_mode = mode } };
        }
        break :blk .text;
    };
    return .{ .ok = .{ .run = .{
        .prompt = try std.mem.join(allocator, " ", raw.prompt_parts),
        .output = output,
        .model = raw.model,
        .tools = if (raw.no_tools) .none else .builtins,
    } } };
}

test "plan maps json mode" {
    const raw = parse_mod.RawCommand{ .run = .{ .prompt_parts = &.{"hello"}, .mode = "json" } };
    var result = try build(std.testing.allocator, raw);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.ok.run.output == .jsonl_events);
}

test "plan rejects empty prompt" {
    const raw = parse_mod.RawCommand{ .run = .{ .prompt_parts = &.{} } };
    const result = try build(std.testing.allocator, raw);
    try std.testing.expect(result.err == .missing_prompt);
}
