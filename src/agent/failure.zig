pub const Failure = union(enum) {
    out_of_memory: []const u8,
    invalid_context: []const u8,
    stream_failed: []const u8,
    tool_failed: []const u8,
    tool_protocol_violation: []const u8,
    internal: []const u8,
};
