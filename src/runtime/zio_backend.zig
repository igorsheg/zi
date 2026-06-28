const zio = @import("zio");

pub const Runtime = zio.Runtime;
pub const RuntimeOptions = zio.RuntimeOptions;
pub const Timeout = zio.Timeout;
pub const ResetEvent = zio.ResetEvent;
pub const Mutex = zio.Mutex;
pub const Waiter = zio.Waiter;
pub const Pipe = zio.Pipe;
pub const ev = zio.ev;

pub fn Channel(comptime Event: type) type {
    return zio.Channel(Event);
}

pub fn JoinHandle(comptime Result: type) type {
    return zio.JoinHandle(Result);
}

pub fn select(args: anytype) @TypeOf(zio.select(args)) {
    return zio.select(args);
}

pub fn getCurrentExecutor() @TypeOf(zio.getCurrentExecutor()) {
    return zio.getCurrentExecutor();
}

pub fn createPipe() @TypeOf(zio.createPipe()) {
    return zio.createPipe();
}

pub fn yield() zio.Cancelable!void {
    return zio.yield();
}
