const std = @import("std");
const TerminalSession = @import("terminal/Session.zig");

pub const ExitCause = enum {
    requested,
    input_closed,
};

pub const Callbacks = struct {
    context: *anyopaque,
    collectFactsFn: *const fn (*anyopaque) anyerror!void,
    handleByteFn: *const fn (*anyopaque, u8) anyerror!void,
    settleInputFn: *const fn (*anyopaque) anyerror!void,
    resizeFn: *const fn (*anyopaque, TerminalSession.Size) anyerror!void,
    commitFrameFn: *const fn (*anyopaque) anyerror!void,
    shouldExitFn: *const fn (*anyopaque) bool,

    fn collectFacts(self: Callbacks) !void {
        return self.collectFactsFn(self.context);
    }

    fn handleByte(self: Callbacks, byte: u8) !void {
        return self.handleByteFn(self.context, byte);
    }

    fn settleInput(self: Callbacks) !void {
        return self.settleInputFn(self.context);
    }

    fn resize(self: Callbacks, size: TerminalSession.Size) !void {
        return self.resizeFn(self.context, size);
    }

    fn commitFrame(self: Callbacks) !void {
        return self.commitFrameFn(self.context);
    }

    fn shouldExit(self: Callbacks) bool {
        return self.shouldExitFn(self.context);
    }
};

pub const Options = struct {
    poll_timeout_ms: i32 = 16,
    max_reads_per_tick: usize = 32,
};

/// Collects worker facts, observes resize, reduces bounded terminal input,
/// settles decoder delivery, then commits one requested frame on the
/// terminal-owning thread. The ordering follows fx's `ui/event_loop.zig`.
pub fn run(
    terminal: anytype,
    callbacks: Callbacks,
    options: Options,
) !ExitCause {
    if (options.poll_timeout_ms < 0 or options.max_reads_per_tick == 0) {
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

        var poll = try terminal.pollInput(options.poll_timeout_ms);
        var reads: usize = 0;
        while (poll.readable and reads < options.max_reads_per_tick) : (reads += 1) {
            const count = try terminal.read(&input);
            if (count == 0) return .input_closed;
            for (input[0..count]) |byte| {
                try callbacks.handleByte(byte);
                if (callbacks.shouldExit()) return .requested;
            }
            poll = try terminal.pollInput(0);
        }
        if (poll.readable) {
            try callbacks.commitFrame();
            continue;
        }
        if (poll.closed()) {
            if (reads != 0) try callbacks.commitFrame();
            return .input_closed;
        }

        try callbacks.settleInput();
        if (callbacks.shouldExit()) return .requested;
        try callbacks.commitFrame();
    }
    return .requested;
}

const TestContext = struct {
    bytes: [8]u8 = undefined,
    byte_count: usize = 0,
    collect_count: usize = 0,
    settle_count: usize = 0,
    resize_count: usize = 0,
    commit_count: usize = 0,
    last_size: ?TerminalSession.Size = null,
    exit: bool = false,

    fn collect(raw: *anyopaque) !void {
        const self: *TestContext = @ptrCast(@alignCast(raw));
        self.collect_count += 1;
    }

    fn handleByte(raw: *anyopaque, byte: u8) !void {
        const self: *TestContext = @ptrCast(@alignCast(raw));
        self.bytes[self.byte_count] = byte;
        self.byte_count += 1;
        if (byte == 4) self.exit = true;
    }

    fn settle(raw: *anyopaque) !void {
        const self: *TestContext = @ptrCast(@alignCast(raw));
        self.settle_count += 1;
    }

    fn resize(raw: *anyopaque, size: TerminalSession.Size) !void {
        const self: *TestContext = @ptrCast(@alignCast(raw));
        self.resize_count += 1;
        self.last_size = size;
    }

    fn commitFrame(raw: *anyopaque) !void {
        const self: *TestContext = @ptrCast(@alignCast(raw));
        self.commit_count += 1;
    }

    fn shouldExit(raw: *anyopaque) bool {
        const self: *TestContext = @ptrCast(@alignCast(raw));
        return self.exit;
    }

    fn callbacks(self: *TestContext) Callbacks {
        return .{
            .context = self,
            .collectFactsFn = collect,
            .handleByteFn = handleByte,
            .settleInputFn = settle,
            .resizeFn = resize,
            .commitFrameFn = commitFrame,
            .shouldExitFn = shouldExit,
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

test "event loop batches terminal bytes around worker fact collection" {
    var context: TestContext = .{};
    const chunks = [_][]const u8{ "hi", "\r", &.{4} };
    var terminal: TestTerminal = .{ .chunks = &chunks };

    const cause = try run(&terminal, context.callbacks(), .{});
    try std.testing.expectEqual(ExitCause.requested, cause);
    try std.testing.expectEqualStrings("hi\r\x04", context.bytes[0..context.byte_count]);
    try std.testing.expectEqual(@as(usize, 1), context.collect_count);
    try std.testing.expectEqual(@as(usize, 0), context.settle_count);
    try std.testing.expectEqual(@as(usize, 1), context.resize_count);
    try std.testing.expectEqual(@as(usize, 0), context.commit_count);
    try std.testing.expectEqual(@as(u16, 80), context.last_size.?.columns);
}

test "event loop commits bytes before reporting input closure" {
    var context: TestContext = .{};
    const chunks = [_][]const u8{"abc"};
    var terminal: TestTerminal = .{ .chunks = &chunks };

    const cause = try run(&terminal, context.callbacks(), .{});
    try std.testing.expectEqual(ExitCause.input_closed, cause);
    try std.testing.expectEqualStrings("abc", context.bytes[0..context.byte_count]);
    try std.testing.expectEqual(@as(usize, 1), context.commit_count);
}

test "event loop rejects unbounded read configuration" {
    var context: TestContext = .{};
    var terminal: TestTerminal = .{ .chunks = &.{} };
    try std.testing.expectError(
        error.InvalidOptions,
        run(&terminal, context.callbacks(), .{ .max_reads_per_tick = 0 }),
    );
}

test "event loop settles pending input after quiet polls" {
    const QuietTerminal = struct {
        const Self = @This();

        polls: usize = 0,

        fn querySize(_: *Self) !TerminalSession.Size {
            return .{ .rows = 24, .columns = 80 };
        }

        fn pollInput(self: *Self, _: i32) !TerminalSession.PollResult {
            self.polls += 1;
            return .{};
        }

        fn read(_: *Self, _: []u8) !usize {
            return error.UnexpectedRead;
        }
    };

    const SettlingContext = struct {
        const Self = @This();

        base: TestContext = .{},

        fn settle(raw: *anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            self.base.settle_count += 1;
            if (self.base.settle_count == 3) self.base.exit = true;
        }

        fn callbacks(self: *Self) Callbacks {
            return .{
                .context = self,
                .collectFactsFn = collect,
                .handleByteFn = handleByte,
                .settleInputFn = settle,
                .resizeFn = resize,
                .commitFrameFn = commitFrame,
                .shouldExitFn = shouldExit,
            };
        }

        fn collect(raw: *anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            self.base.collect_count += 1;
        }

        fn handleByte(_: *anyopaque, _: u8) !void {
            return error.UnexpectedByte;
        }

        fn resize(raw: *anyopaque, size: TerminalSession.Size) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            self.base.resize_count += 1;
            self.base.last_size = size;
        }

        fn commitFrame(raw: *anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            self.base.commit_count += 1;
        }

        fn shouldExit(raw: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(raw));
            return self.base.exit;
        }
    };

    var context: SettlingContext = .{};
    var terminal: QuietTerminal = .{};
    const cause = try run(&terminal, context.callbacks(), .{ .poll_timeout_ms = 0 });
    try std.testing.expectEqual(ExitCause.requested, cause);
    try std.testing.expectEqual(@as(usize, 3), context.base.settle_count);
    try std.testing.expectEqual(@as(usize, 3), terminal.polls);
    try std.testing.expectEqual(@as(usize, 2), context.base.commit_count);
}
