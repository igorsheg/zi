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
    provider: []const u8,
    status: ?u16 = null,
    code: ?[]const u8 = null,
    message: []const u8,
    request_id: ?[]const u8 = null,
    retry_after_ms: ?u64 = null,
};

pub const FailureSink = struct {
    context: *anyopaque,
    observeFn: *const fn (context: *anyopaque, failure: ProviderFailure) void,

    pub fn observe(self: FailureSink, failure: ProviderFailure) void {
        self.observeFn(self.context, failure);
    }
};
