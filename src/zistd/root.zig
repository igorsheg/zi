const std = @import("std");

pub const bounded_queue = @import("BoundedQueue.zig");
pub const cancel = @import("Cancel.zig");
pub const completion_queue = @import("CompletionQueue.zig");
pub const event_pipe = @import("EventPipe.zig");
pub const operation = @import("Operation.zig");
pub const race = @import("Race.zig");

pub const ByteBuilder = @import("ByteBuilder.zig").ByteBuilder;
pub const BoundedQueue = bounded_queue.BoundedQueue;
pub const CancelSource = cancel.CancelSource;
pub const CancelToken = cancel.CancelToken;
pub const CompletionQueue = completion_queue.CompletionQueue;
pub const EventPipe = event_pipe.EventPipe;
pub const OperationId = operation.OperationId;
pub const OperationState = operation.OperationState;
pub const OperationTable = operation.OperationTable;
pub const Owned = @import("Owned.zig").Owned;
pub const Race = race.Race;
pub const sleep = cancel.sleep;

pub const Process = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,

    pub fn init(process: std.process.Init) Process {
        return .{
            .arena = process.arena.allocator(),
            .gpa = process.gpa,
            .io = process.io,
            .environ = process.environ_map,
        };
    }
};

test {
    _ = @import("BoundedQueue.zig");
    _ = @import("ByteBuilder.zig");
    _ = @import("Cancel.zig");
    _ = @import("CompletionQueue.zig");
    _ = @import("EventPipe.zig");
    _ = @import("Operation.zig");
    _ = @import("Owned.zig");
    _ = @import("Race.zig");
}

test "process runtime stores explicit resources" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const process: Process = .{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = std.Io.failing,
        .environ = &environ,
    };

    try std.testing.expect(process.arena.ptr == std.testing.allocator.ptr);
    try std.testing.expect(process.gpa.ptr == std.testing.allocator.ptr);
    try std.testing.expect(process.environ == &environ);
}
