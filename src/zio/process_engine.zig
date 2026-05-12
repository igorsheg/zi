const builtin = @import("builtin");

const blocking = @import("process_engine_blocking.zig");
const kqueue = @import("process_engine_kqueue.zig");
const linux = @import("process_engine_linux.zig");
const types = @import("process_engine_types.zig");

const backend = switch (builtin.os.tag) {
    .macos, .ios, .visionos => kqueue,
    .linux => linux,
    else => blocking,
};

pub const EnvPair = types.EnvPair;
pub const StreamKind = types.StreamKind;
pub const Event = types.Event;
pub const EventSink = types.EventSink;
pub const StartRequest = types.StartRequest;
pub const Engine = backend.Engine;
