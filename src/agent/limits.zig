pub const RunLimits = struct {
    max_model_requests: usize = 16,
    max_tool_calls: usize = 64,
    max_tool_result_bytes: usize = 1024 * 1024,
};

pub const Error = error{
    MaxModelRequestsExceeded,
    MaxToolCallsExceeded,
    ToolResultTooLarge,
};
