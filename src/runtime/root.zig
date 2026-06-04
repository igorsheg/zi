const zio = @import("zio");

pub const Process = @import("Process.zig").Process;
pub const Runtime = zio.Runtime;
pub const ResetEvent = zio.ResetEvent;
pub const Duration = zio.Duration;
pub const Timeout = zio.Timeout;
pub const Pipe = zio.Pipe;
pub const Cancelable = zio.Cancelable;

pub fn Channel(comptime Event: type) type {
    return zio.Channel(Event);
}

pub fn JoinHandle(comptime Result: type) type {
    return zio.JoinHandle(Result);
}

pub fn select(args: anytype) @TypeOf(zio.select(args)) {
    return zio.select(args);
}

pub fn sleep(duration: Duration) Cancelable!void {
    return zio.sleep(duration);
}

pub fn yield() Cancelable!void {
    return zio.yield();
}

const bounded_queue = @import("bounded_queue.zig");
const cancel = @import("cancel.zig");
const event_pipe = @import("event_pipe.zig");
const fd_readiness = @import("fd_readiness.zig");
const json_owned = @import("json_owned.zig");
const operation = @import("operation.zig");
const process_runner = @import("process_runner.zig");

pub const BoundedQueue = bounded_queue.BoundedQueue;
pub const ByteBuilder = @import("byte_builder.zig").ByteBuilder;
pub const CancelSource = cancel.CancelSource;
pub const CancelToken = cancel.CancelToken;
pub const EventPipe = event_pipe.EventPipe;
pub const ReadableFd = fd_readiness.ReadableFd;
pub const ReadableFdError = fd_readiness.ReadableFdError;
pub const JsonOwned = json_owned.JsonOwned;
pub const OperationId = operation.OperationId;
pub const OperationIdAllocator = operation.OperationIdAllocator;
pub const sleepUntilCancel = cancel.sleepUntilCancel;
pub const cloneJsonValue = json_owned.cloneJsonValue;
pub const freeJsonValue = json_owned.freeJsonValue;
pub const runProcess = process_runner.run;
pub const OutputStream = process_runner.OutputStream;

test {
    _ = @import("Process.zig");
    _ = @import("bounded_queue.zig");
    _ = @import("byte_builder.zig");
    _ = @import("cancel.zig");
    _ = @import("event_pipe.zig");
    _ = @import("fd_readiness.zig");
    _ = @import("json_owned.zig");
    _ = @import("operation.zig");
    _ = @import("process_runner.zig");
}
