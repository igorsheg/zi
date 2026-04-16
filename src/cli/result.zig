pub const ExecutionDiagnostic = union(enum) {
    resolver_message: []const u8,
    session_load_failed: []const u8,
    session_file_has_no_messages,
    model_resolution_failed,
    no_model_found,
    no_model_available,
    no_api_key_for_provider: struct {
        provider: []const u8,
        env_hint: ?[]const u8,
    },
    continue_session_needs_prompt,
    continue_session_failed: []const u8,
};

pub const ExecutionResult = union(enum) {
    ok,
    err: ExecutionDiagnostic,
};
