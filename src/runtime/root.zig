const std = @import("std");

pub const cancel = @import("cancel.zig");
pub const completion_queue = @import("completion_queue.zig");
pub const operation = @import("operation.zig");

pub const CancelSource = cancel.CancelSource;
pub const CancelToken = cancel.CancelToken;
pub const sleep = cancel.sleep;
pub const CompletionQueue = completion_queue.CompletionQueue;
pub const OperationId = operation.OperationId;
pub const OperationState = operation.OperationState;
pub const OperationTable = operation.OperationTable;
pub const EventPipe = @import("event_pipe.zig").EventPipe;

pub const Process = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,

    pub fn init(process: std.process.Init) Process {
        return .{
            .arena = process.arena.allocator(),
            .gpa = process.gpa,
            .io = process.io,
        };
    }
};

test {
    _ = cancel;
    _ = completion_queue;
    _ = operation;
    _ = @import("event_pipe.zig");
}

test "process runtime stores explicit resources" {
    const process: Process = .{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = std.Io.failing,
    };

    try std.testing.expect(process.arena.ptr == std.testing.allocator.ptr);
    try std.testing.expect(process.gpa.ptr == std.testing.allocator.ptr);
}
