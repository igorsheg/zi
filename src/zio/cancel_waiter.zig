const std = @import("std");
const cancel = @import("cancel.zig");
const logging = @import("../logging.zig");

pub const Waiter = struct {
    state: ?*State = null,
    thread: ?std.Thread = null,

    pub const Callback = struct {
        ptr: *anyopaque,
        call: *const fn (ptr: *anyopaque) void,
    };

    const State = struct {
        stopped: std.atomic.Value(bool) = .init(false),
        token: cancel.Token,
        callback: Callback,
    };

    pub fn start(io: std.Io, token: cancel.Token, callback: Callback) !Waiter {
        if (token.isNone()) return .{};

        const state = try std.heap.page_allocator.create(State);
        state.* = .{ .token = token, .callback = callback };
        const thread = std.Thread.spawn(.{}, run, .{ io, state }) catch |err| {
            std.heap.page_allocator.destroy(state);
            return err;
        };
        return .{ .state = state, .thread = thread };
    }

    pub fn stop(self: *Waiter) void {
        const state = self.state orelse return;
        state.stopped.store(true, .release);
        state.token.notifyWaiters();
        if (self.thread) |thread| thread.join();
        std.heap.page_allocator.destroy(state);
        self.* = .{};
    }

    fn run(io: std.Io, state: *State) void {
        logging.setThreadLabel(.cancel_waiter);
        const result = state.token.waitUntilIo(io, null, stopped, state);
        if (result != .aborted) return;
        if (state.stopped.load(.acquire)) return;
        state.callback.call(state.callback.ptr);
    }

    fn stopped(ctx: ?*anyopaque) bool {
        const state: *State = @ptrCast(@alignCast(ctx.?));
        return state.stopped.load(.acquire);
    }
};

test "Waiter stop before abort joins without callback" {
    const Ctx = struct {
        called: std.atomic.Value(bool) = .init(false),
        fn callback(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.called.store(true, .release);
        }
    };

    var source = cancel.Source{};
    const token = source.beginRun();
    var ctx = Ctx{};
    var waiter = try Waiter.start(std.Options.debug_io, token, .{ .ptr = @ptrCast(&ctx), .call = Ctx.callback });
    waiter.stop();
    source.requestAbort();

    try std.testing.expect(!ctx.called.load(.acquire));
}

test "Waiter abort before stop calls callback once and stop is safe" {
    const Ctx = struct {
        count: std.atomic.Value(u32) = .init(0),
        fn callback(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = self.count.fetchAdd(1, .acq_rel);
        }
    };

    var source = cancel.Source{};
    const token = source.beginRun();
    var ctx = Ctx{};
    var waiter = try Waiter.start(std.Options.debug_io, token, .{ .ptr = @ptrCast(&ctx), .call = Ctx.callback });

    source.requestAbort();
    var waited: u32 = 0;
    while (ctx.count.load(.acquire) == 0 and waited < 100) : (waited += 1) {
        std.Options.debug_io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    waiter.stop();

    try std.testing.expectEqual(@as(u32, 1), ctx.count.load(.acquire));
}

test "Waiter none is inert" {
    const Ctx = struct {
        fn callback(_: *anyopaque) void {}
    };
    var byte: u8 = 0;
    var waiter = try Waiter.start(std.Options.debug_io, cancel.Token.none, .{ .ptr = @ptrCast(&byte), .call = Ctx.callback });
    waiter.stop();
    try std.testing.expect(waiter.state == null);
}
