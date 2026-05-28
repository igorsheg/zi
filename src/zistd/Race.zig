const std = @import("std");

/// Bounded first-completion-wins scope over `std.Io.Select`.
///
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

        threaded: std.Io.Threaded,
        select: Select,
        capacity: usize,
        started: usize = 0,
        awaited: bool = false,
        drained: bool = false,

        pub const Options = struct {
            concurrent_limit: std.Io.Limit,
        };

        pub fn init(allocator: std.mem.Allocator, buffer: []Completion, options: Options) Self {
            std.debug.assert(buffer.len > 0);
            var threaded = std.Io.Threaded.init(allocator, .{ .concurrent_limit = options.concurrent_limit });
            const io_value = threaded.io();
            return .{
                .threaded = threaded,
                .select = Select.init(io_value, buffer),
                .capacity = buffer.len,
                .drained = true,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.started > 0 and !self.drained) @panic("zistd.Race deinit before cancelAndDrain");
            self.threaded.deinit();
            self.* = undefined;
        }

        pub fn io(self: *Self) std.Io {
            return self.threaded.io();
        }

        /// Starts one participant. A successful call must be followed by
        /// `cancelAndDrain` before `deinit`, even if later setup fails.
        pub fn concurrent(
            self: *Self,
            comptime field: Field,
            function: anytype,
            args: std.meta.ArgsTuple(@TypeOf(function)),
        ) !void {
            std.debug.assert(!self.awaited);
            std.debug.assert(self.started < self.capacity);
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
    var race = Race(TestCompletion).init(std.testing.allocator, &buffer, .{ .concurrent_limit = .limited(2) });
    defer race.deinit();

    try std.testing.expectEqual(@as(usize, 2), race.capacity);
    try std.testing.expectEqual(@as(usize, 0), race.started);
}
