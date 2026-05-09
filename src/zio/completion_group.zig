const std = @import("std");

/// Structured concurrent fan-out with completion-order delivery.
///
/// This is a small zi policy wrapper over `std.Io.Select`: callers submit
/// work that must receive a real unit of concurrency, then await completed
/// values in completion order. It fills the gap between `TaskGroup`'s
/// spawn/wait ownership and ad-hoc mailbox-based completion queues.
///
/// The caller owns `buffer`; it must be large enough to hold all outstanding
/// completions, otherwise cancellation can deadlock for tasks whose return
/// values have not been drained. A good default is one slot per spawned task.
pub fn CompletionGroup(comptime Completion: type) type {
    const Event = union(enum) {
        completion: Completion,
    };

    return struct {
        const Self = @This();

        io: std.Io,
        select: std.Io.Select(Event),
        pending: usize = 0,
        closed: bool = false,

        pub fn init(io: std.Io, buffer: []Event) Self {
            return .{
                .io = io,
                .select = .init(io, buffer),
            };
        }

        /// Submit work that requires actual concurrency. The function's return
        /// value is delivered by `next` in completion order.
        pub fn concurrent(
            self: *Self,
            function: anytype,
            args: std.meta.ArgsTuple(@TypeOf(function)),
        ) std.Io.ConcurrentError!void {
            std.debug.assert(!self.closed);
            try self.select.concurrent(.completion, function, args);
            self.pending += 1;
        }

        /// Await the next completed task. Returns null once all submitted tasks
        /// have been observed.
        pub fn next(self: *Self) std.Io.Cancelable!?Completion {
            if (self.pending == 0) return null;
            const event = try self.select.await();
            self.pending -= 1;
            return switch (event) {
                .completion => |completion| completion,
            };
        }

        /// Cancel remaining tasks, draining any already-produced completions so
        /// result ownership stays explicit. Returns null once fully canceled.
        pub fn cancel(self: *Self) ?Completion {
            self.closed = true;
            const event = self.select.cancel() orelse {
                self.pending = 0;
                return null;
            };
            if (self.pending > 0) self.pending -= 1;
            return switch (event) {
                .completion => |completion| completion,
            };
        }

        /// Cancel remaining tasks and discard their results. Only use when
        /// `Completion` does not own resources.
        pub fn cancelDiscard(self: *Self) void {
            self.closed = true;
            self.pending = 0;
            self.select.cancelDiscard();
        }
    };
}

test "CompletionGroup yields concurrent completions" {
    const Completion = struct { value: u32 };
    const Work = struct {
        fn run(value: u32) Completion {
            return .{ .value = value };
        }
    };

    var buffer: [2]union(enum) { completion: Completion } = undefined;
    var group = CompletionGroup(Completion).init(std.Options.debug_io, &buffer);
    defer group.cancelDiscard();

    try group.concurrent(Work.run, .{2});
    try group.concurrent(Work.run, .{3});

    var sum: u32 = 0;
    while (try group.next()) |completion| {
        sum += completion.value;
    }

    try std.testing.expectEqual(@as(u32, 5), sum);
}
