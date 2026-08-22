const std = @import("std");
const SessionTranscript = @import("../SessionTranscript.zig");
const InteractiveSessionHost = @import("InteractiveSessionHost.zig");

pub const ExitCause = enum {
    requested,
    input_closed,
};

/// Borrowed process and coding-agent values for one synchronous frontend run.
/// The launch owner keeps the host, transcript, prompts, files, and writer
/// alive until `runFn` returns.
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    host: *InteractiveSessionHost,
    transcript: *const SessionTranscript,
    initial_prompts: []const []const u8,
    input: std.Io.File,
    output: std.Io.File,
    writer: *std.Io.Writer,
};

/// One concrete interactive client selected by the composition root.
pub const Frontend = struct {
    context: ?*anyopaque = null,
    runFn: *const fn (?*anyopaque, Context) anyerror!ExitCause,

    pub fn run(self: Frontend, run_context: Context) !ExitCause {
        return self.runFn(self.context, run_context);
    }
};
