const std = @import("std");
const InputDecoder = @import("InputDecoder.zig");
const TerminalSession = @import("TerminalSession.zig");

pub const ExitCause = enum {
    requested,
    input_closed,
};

pub const Callbacks = struct {
    context: *anyopaque,
    collectFactsFn: *const fn (*anyopaque) anyerror!void,
    handleActionFn: *const fn (*anyopaque, InputDecoder.Action) anyerror!void,
    resizeFn: *const fn (*anyopaque, TerminalSession.Size) anyerror!void,
    shouldExitFn: *const fn (*anyopaque) bool,
    nowMsFn: *const fn (*anyopaque) i64,

    fn collectFacts(self: Callbacks) !void {
        return self.collectFactsFn(self.context);
    }

    fn handleAction(self: Callbacks, action: InputDecoder.Action) !void {
        return self.handleActionFn(self.context, action);
    }

    fn resize(self: Callbacks, size: TerminalSession.Size) !void {
        return self.resizeFn(self.context, size);
    }

    fn shouldExit(self: Callbacks) bool {
        return self.shouldExitFn(self.context);
    }

    fn nowMs(self: Callbacks) i64 {
        return self.nowMsFn(self.context);
    }
};

pub const Options = struct {
    poll_timeout_ms: i32 = 16,
    escape_timeout_ms: i64 = 30,
    max_reads_per_tick: usize = 32,
};

/// Interleaves worker fact collection, resize observation, bounded input reads,
/// and quiet-period Escape resolution on one terminal-owning thread.
pub fn run(
    terminal: anytype,
    decoder: *InputDecoder,
    callbacks: Callbacks,
    options: Options,
) !ExitCause {
    if (options.poll_timeout_ms < 0 or
        options.escape_timeout_ms < 0 or
        options.max_reads_per_tick == 0)
    {
        return error.InvalidOptions;
    }
    var last_size: ?TerminalSession.Size = null;
    var input: [256]u8 = undefined;

    while (!callbacks.shouldExit()) {
        try callbacks.collectFacts();
        if (callbacks.shouldExit()) return .requested;

        if (terminal.querySize()) |size| {
            if (last_size == null or !std.meta.eql(last_size.?, size)) {
                try callbacks.resize(size);
                last_size = size;
            }
        } else |_| {}

        if (decoder.flush(callbacks.nowMs(), options.escape_timeout_ms)) |action| {
            try callbacks.handleAction(action);
            if (callbacks.shouldExit()) return .requested;
        }

        var poll = try terminal.pollInput(options.poll_timeout_ms);
        var reads: usize = 0;
        while (poll.readable and reads < options.max_reads_per_tick) : (reads += 1) {
            const count = try terminal.read(&input);
            if (count == 0) return .input_closed;
            for (input[0..count]) |byte| {
                if (decoder.feed(byte, callbacks.nowMs())) |action| {
                    try callbacks.handleAction(action);
                    if (callbacks.shouldExit()) return .requested;
                }
            }
            poll = try terminal.pollInput(0);
        }
        if (poll.closed()) return .input_closed;
    }
    return .requested;
}

const TestContext = struct {
    actions: [8]std.meta.Tag(InputDecoder.Action) = undefined,
    action_count: usize = 0,
    collect_count: usize = 0,
    resize_count: usize = 0,
    last_size: ?TerminalSession.Size = null,
    exit: bool = false,
    now_ms: i64 = 0,

    fn collect(raw: *anyopaque) !void {
        const self: *TestContext = @ptrCast(@alignCast(raw));
        self.collect_count += 1;
        self.now_ms += 16;
    }

    fn action(raw: *anyopaque, value: InputDecoder.Action) !void {
        const self: *TestContext = @ptrCast(@alignCast(raw));
        self.actions[self.action_count] = std.meta.activeTag(value);
        self.action_count += 1;
        if (value == .end_of_input or value == .escape) self.exit = true;
    }

    fn resize(raw: *anyopaque, size: TerminalSession.Size) !void {
        const self: *TestContext = @ptrCast(@alignCast(raw));
        self.resize_count += 1;
        self.last_size = size;
    }

    fn shouldExit(raw: *anyopaque) bool {
        const self: *TestContext = @ptrCast(@alignCast(raw));
        return self.exit;
    }

    fn now(raw: *anyopaque) i64 {
        const self: *TestContext = @ptrCast(@alignCast(raw));
        return self.now_ms;
    }

    fn callbacks(self: *TestContext) Callbacks {
        return .{
            .context = self,
            .collectFactsFn = collect,
            .handleActionFn = action,
            .resizeFn = resize,
            .shouldExitFn = shouldExit,
            .nowMsFn = now,
        };
    }
};

const TestTerminal = struct {
    chunks: []const []const u8,
    next_chunk: usize = 0,
    size_value: TerminalSession.Size = .{ .rows = 24, .columns = 80 },

    fn querySize(self: *TestTerminal) !TerminalSession.Size {
        return self.size_value;
    }

    fn pollInput(self: *TestTerminal, _: i32) !TerminalSession.PollResult {
        if (self.next_chunk < self.chunks.len) return .{ .readable = true };
        return .{ .hung_up = true };
    }

    fn read(self: *TestTerminal, output: []u8) !usize {
        const chunk = self.chunks[self.next_chunk];
        self.next_chunk += 1;
        @memcpy(output[0..chunk.len], chunk);
        return chunk.len;
    }
};

test "event loop batches decoded input around worker fact collection" {
    var context: TestContext = .{};
    var decoder: InputDecoder = .{};
    const chunks = [_][]const u8{ "hi", "\r", &.{4} };
    var terminal: TestTerminal = .{ .chunks = &chunks };

    const cause = try run(&terminal, &decoder, context.callbacks(), .{});
    try std.testing.expectEqual(ExitCause.requested, cause);
    try std.testing.expectEqual(@as(usize, 4), context.action_count);
    try std.testing.expectEqual(std.meta.Tag(InputDecoder.Action).text_byte, context.actions[0]);
    try std.testing.expectEqual(std.meta.Tag(InputDecoder.Action).text_byte, context.actions[1]);
    try std.testing.expectEqual(std.meta.Tag(InputDecoder.Action).submit, context.actions[2]);
    try std.testing.expectEqual(std.meta.Tag(InputDecoder.Action).end_of_input, context.actions[3]);
    try std.testing.expectEqual(@as(usize, 1), context.collect_count);
    try std.testing.expectEqual(@as(usize, 1), context.resize_count);
    try std.testing.expectEqual(@as(u16, 80), context.last_size.?.columns);
}

test "event loop rejects unbounded read configuration" {
    var context: TestContext = .{};
    var decoder: InputDecoder = .{};
    var terminal: TestTerminal = .{ .chunks = &.{} };
    try std.testing.expectError(
        error.InvalidOptions,
        run(&terminal, &decoder, context.callbacks(), .{ .max_reads_per_tick = 0 }),
    );
}

test "event loop resolves bare Escape after quiet polls" {
    const QuietTerminal = struct {
        const Self = @This();

        delivered: bool = false,

        fn querySize(_: *Self) !TerminalSession.Size {
            return .{ .rows = 24, .columns = 80 };
        }

        fn pollInput(self: *Self, _: i32) !TerminalSession.PollResult {
            return if (!self.delivered) .{ .readable = true } else .{};
        }

        fn read(self: *Self, output: []u8) !usize {
            self.delivered = true;
            output[0] = 0x1b;
            return 1;
        }
    };

    var context: TestContext = .{};
    var decoder: InputDecoder = .{};
    var terminal: QuietTerminal = .{};
    const cause = try run(&terminal, &decoder, context.callbacks(), .{
        .poll_timeout_ms = 0,
        .escape_timeout_ms = 30,
    });
    try std.testing.expectEqual(ExitCause.requested, cause);
    try std.testing.expectEqual(@as(usize, 1), context.action_count);
    try std.testing.expectEqual(std.meta.Tag(InputDecoder.Action).escape, context.actions[0]);
    try std.testing.expect(context.collect_count >= 3);
}
