pub const Failure = union(enum) {
    out_of_memory: []const u8,
    invalid_context: []const u8,
    stream_failed: []const u8,
    tool_failed: []const u8,
    tool_protocol_violation: []const u8,
    internal: []const u8,
};

pub const Kind = enum {
    out_of_memory,
    invalid_context,
    stream_failed,
    tool_failed,
    tool_protocol_violation,
    internal,
};

pub fn kind(value: Failure) Kind {
    return switch (value) {
        .out_of_memory => .out_of_memory,
        .invalid_context => .invalid_context,
        .stream_failed => .stream_failed,
        .tool_failed => .tool_failed,
        .tool_protocol_violation => .tool_protocol_violation,
        .internal => .internal,
    };
}
