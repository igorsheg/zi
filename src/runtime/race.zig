const std = @import("std");

/// Bounded first-completion-wins scope over `std.Io.Select`.
///
/// `Race` borrows a `std.Io`; the caller owns backend selection and teardown.
/// `Race` owns child task handles, not completion payloads. Callers own all
/// payload cleanup through `cancelAndDrain`. Any successful `concurrent` call
/// creates a drain obligation, including paths where a later `concurrent` or
/// `await` fails.
///
/// Cancellation requests are not cancellation completion. If a losing task is
/// blocked in an operation that cannot observe `std.Io` cancellation by itself,
/// the owner must wake or close that resource before `cancelAndDrain`/`deinit`.
pub fn Race(comptime Completion: type) type {
    return struct {
        const Self = @This();
        const Select = std.Io.Select(Completion);
        const Field = std.meta.FieldEnum(Completion);

        io: std.Io,
        select: Select,
        capacity: usize,
        started: usize = 0,
        awaited: bool = false,
        drained: bool = false,

        pub const ConcurrentError = error{Full} || std.Io.ConcurrentError;

        pub fn init(io: std.Io, buffer: []Completion) Self {
            std.debug.assert(buffer.len > 0);
            return .{
                .io = io,
                .select = Select.init(io, buffer),
                .capacity = buffer.len,
                .drained = true,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.started > 0 and !self.drained) @panic("runtime.Race deinit before cancelAndDrain");
            self.* = undefined;
        }

        /// Starts one participant. A successful call must be followed by
        /// `cancelAndDrain` before `deinit`, even if later setup fails.
        pub fn concurrent(
            self: *Self,
            comptime field: Field,
            function: anytype,
            args: std.meta.ArgsTuple(@TypeOf(function)),
        ) ConcurrentError!void {
            std.debug.assert(!self.awaited);
            if (self.started == self.capacity) return error.Full;
            try self.select.concurrent(field, function, args);
            self.started += 1;
            self.drained = false;
        }

        pub fn await(self: *Self) std.Io.Cancelable!Completion {
            std.debug.assert(!self.awaited);
            std.debug.assert(self.started > 0);
            self.awaited = true;
            return self.select.await();
        }

        /// Requests cancellation for remaining participants and drains any
        /// completions they publish. The caller-provided drain function owns
        /// cleanup for completion payloads.
        pub fn cancelAndDrain(
            self: *Self,
            context: anytype,
            comptime drainFn: fn (@TypeOf(context), Completion) void,
        ) void {
            while (self.select.cancel()) |completion| drainFn(context, completion);
            self.drained = true;
        }
    };
}

const TestCompletion = union(enum) {
    first: anyerror!u8,
    second: anyerror!u8,
};

test "race initializes with caller-owned completion capacity" {
    var buffer: [2]TestCompletion = undefined;
    var race = Race(TestCompletion).init(std.testing.io, &buffer);
    defer race.deinit();

    try std.testing.expectEqual(@as(usize, 2), race.capacity);
    try std.testing.expectEqual(@as(usize, 0), race.started);
}

fn returnOne() anyerror!u8 {
    return 1;
}

test "race returns full when caller exceeds completion capacity" {
    var buffer: [1]TestCompletion = undefined;
    var race = Race(TestCompletion).init(std.testing.io, &buffer);
    defer race.deinit();

    try race.concurrent(.first, returnOne, .{});
    try std.testing.expectError(error.Full, race.concurrent(.second, returnOne, .{}));
    race.cancelAndDrain({}, drainTestCompletion);
}

fn drainTestCompletion(_: void, _: TestCompletion) void {}
