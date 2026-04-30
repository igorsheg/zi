/// Shared types for ziSpawn — spawn a child zi process in --mode json,
/// parse JSONL events from stdout, collect output and usage stats.
/// Zig equivalent of pi-spawn.ts.
const std = @import("std");
const abort_signal = @import("../abort_signal.zig");
const ai = @import("../ai/root.zig");

/// Per-event observer callback. Fires once for every parsed JSONL line
/// from the child's stdout, BEFORE ziSpawn's built-in extractors run,
/// so callers see every event the child emits — not just message_end.
///
/// Runs synchronously inside the parent's stdout read loop. The
/// callback MUST be cheap and MUST NOT block: a slow callback
/// back-pressures the child via the OS pipe buffer.
///
/// `kind` is the event's `type` string ("message_end",
/// "tool_execution_start", ...). `event` is the parsed JSON value;
/// it is only valid for the duration of the callback — copy out
/// anything you need to retain.
pub const EventCallback = *const fn (
    kind: []const u8,
    event: std.json.Value,
    ctx: ?*anyopaque,
) void;

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
    cancelled: bool = false,
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
    io: std.Io = std.Options.debug_io,
    cwd: []const u8,
    task: []const u8,
    model: ?[]const u8 = null,
    tools: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    signal: ?abort_signal.AbortSignal = null,

    /// Optional per-event observer. See `EventCallback` for the
    /// contract. `on_event_ctx` is passed through verbatim.
    on_event: ?EventCallback = null,
    on_event_ctx: ?*anyopaque = null,

    /// Test-only escape hatch. When set, ziSpawn skips its own
    /// argv construction (self-exe + --mode json + ...) and runs
    /// this command instead. Used by spawn tests to point at a
    /// canned `sh -c` script that prints fixed JSONL, so the test
    /// suite never needs real API keys or a child zi process.
    /// Production code MUST leave this null.
    argv_override: ?[]const []const u8 = null,
};
