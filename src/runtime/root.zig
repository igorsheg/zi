const async_runtime = @import("Runtime.zig");

pub const Process = @import("Process.zig").Process;
pub const Runtime = async_runtime.Runtime;
pub const ResetEvent = async_runtime.ResetEvent;
pub const Mutex = async_runtime.Mutex;
pub const Duration = async_runtime.Duration;
pub const Timeout = async_runtime.Timeout;
pub const Cancelable = async_runtime.Cancelable;

pub fn Channel(comptime Event: type) type {
    return async_runtime.Channel(Event);
}

pub fn Task(comptime Result: type) type {
    return async_runtime.Task(Result);
}

pub fn select(args: anytype) @TypeOf(async_runtime.select(args)) {
    return async_runtime.select(args);
}

pub fn sleep(duration: Duration) Cancelable!void {
    return async_runtime.sleep(duration);
}

pub fn yield() Cancelable!void {
    return async_runtime.yield();
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
    _ = @import("Runtime.zig");
    _ = @import("bounded_queue.zig");
    _ = @import("byte_builder.zig");
    _ = @import("cancel.zig");
    _ = @import("event_pipe.zig");
    _ = @import("fd_readiness.zig");
    _ = @import("json_owned.zig");
    _ = @import("operation.zig");
    _ = @import("process_runner.zig");
}
