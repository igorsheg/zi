const message = @import("message.zig");
const usage = @import("usage.zig");

pub const StreamSinkError = error{
    OutOfMemory,
    Cancelled,
    ConsumerStopped,
};

pub const ToolCallStart = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const ResponsePartStart = union(enum) {
    text,
    thinking,
    tool_call: ToolCallStart,
};

pub const PartStart = struct {
    index: usize,
    part: ResponsePartStart,
};

pub const ToolCallDelta = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments_delta: []const u8 = "",
};

pub const ResponsePartDelta = union(enum) {
    text: []const u8,
    thinking: []const u8,
    tool_call: ToolCallDelta,
};

pub const PartDelta = struct {
    index: usize,
    delta: ResponsePartDelta,
};

pub const PartEnd = struct {
    index: usize,
    part: message.ResponsePart,
};

pub const StreamEvent = union(enum) {
    part_start: PartStart,
    part_delta: PartDelta,
    part_end: PartEnd,
    usage: usage.Usage,
};

pub const StreamSink = struct {
    context: *anyopaque,
    emitFn: *const fn (context: *anyopaque, event: StreamEvent) StreamSinkError!void,

    pub fn emit(self: StreamSink, event: StreamEvent) StreamSinkError!void {
        return self.emitFn(self.context, event);
    }
};
