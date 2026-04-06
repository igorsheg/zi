/// Shared types for ziSpawn — spawn a child zi process in --mode json,
/// parse JSONL events from stdout, collect output and usage stats.
/// Zig equivalent of pi-spawn.ts.
const std = @import("std");
const ai = @import("../ai/root.zig");

pub const UsageStats = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    cost: f64 = 0,
    context_tokens: u64 = 0,
    turns: u64 = 0,
};

pub const SpawnResult = struct {
    exit_code: u8 = 0,
    output: std.ArrayList(u8),
    stderr_output: std.ArrayList(u8),
    usage: UsageStats = .{},
    model: ?[]const u8 = null,
    stop_reason: ?[]const u8 = null,
    error_message: ?[]const u8 = null,

    pub fn init() SpawnResult {
        return .{
            .output = .empty,
            .stderr_output = .empty,
        };
    }

    pub fn deinit(self: *SpawnResult, allocator: std.mem.Allocator) void {
        self.output.deinit(allocator);
        self.stderr_output.deinit(allocator);
        if (self.model) |m| allocator.free(m);
        if (self.stop_reason) |sr| allocator.free(sr);
        if (self.error_message) |em| allocator.free(em);
    }

    /// Get the collected text output (last assistant message's text content).
    pub fn text(self: *const SpawnResult) ?[]const u8 {
        if (self.output.items.len == 0) return null;
        return self.output.items;
    }
};

pub const SpawnConfig = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8,
    task: []const u8,
    model: ?[]const u8 = null,
    tools: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    signal: ?*const std.atomic.Value(bool) = null,
};
