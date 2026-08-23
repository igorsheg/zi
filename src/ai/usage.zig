pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cached_input_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
};

pub const FinishCategory = enum {
    stop,
    tool_calls,
    length,
    content_filter,
    cancelled,
    provider_error,
    unknown,
};

pub const Finish = struct {
    category: FinishCategory = .unknown,
    raw_reason: ?[]const u8 = null,
};
