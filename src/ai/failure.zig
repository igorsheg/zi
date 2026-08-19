pub const ModelError = error{
    OutOfMemory,
    Cancelled,
    TimedOut,
    UnsupportedCapability,
    UnsupportedSetting,
    InvalidRequest,
    ConnectionFailed,
    RateLimited,
    ProviderRejectedRequest,
    ProviderUnavailable,
    InvalidProviderResponse,
    StreamInterrupted,
    StreamConsumerStopped,
    HandoffRejected,
};

pub const ProviderFailure = struct {
    pub const max_provider_bytes = 256;
    pub const max_message_bytes = 4 * 1024;
    pub const max_code_bytes = 256;
    pub const max_request_id_bytes = 256;

    provider: []const u8,
    status: u16,
    code: ?[]const u8 = null,
    message: []const u8,
    request_id: ?[]const u8 = null,
    retry_after_ms: ?u64 = null,
    sensitive_data_redacted: bool = false,
};

pub const FailureSink = struct {
    context: *anyopaque,
    observeFn: *const fn (context: *anyopaque, failure: ProviderFailure) void,

    pub fn observe(self: FailureSink, failure: ProviderFailure) void {
        self.observeFn(self.context, failure);
    }
};
