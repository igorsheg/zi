const session_lookup = @import("../session/lookup.zig");

pub const ExecutionDiagnostic = union(enum) {
    resolver_message: []const u8,
    session_lookup_failed: []const u8,
    no_recent_session,
    session_target_not_found: []const u8,
    session_target_ambiguous: []const u8,
    model_resolution_failed,
    no_model_found,
    no_model_available,
    batch_assistant_failed: []const u8,
    no_api_key_for_provider: struct {
        provider: []const u8,
        env_hint: ?[]const u8,
    },
};

pub const ExecutionResult = union(enum) {
    ok,
    err: ExecutionDiagnostic,
};

pub fn fromSessionLookupDiagnostic(diagnostic: session_lookup.Diagnostic) ExecutionDiagnostic {
    return switch (diagnostic) {
        .lookup_failed => |err_name| .{ .session_lookup_failed = err_name },
        .no_recent_session => .no_recent_session,
        .not_found => |ref| .{ .session_target_not_found = ref },
        .ambiguous => |ref| .{ .session_target_ambiguous = ref },
    };
}
