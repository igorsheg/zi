const settings_resolve = @import("../../settings/resolve.zig");

pub const ExecutionResult = union(enum) {
    ok,
    err: Diagnostic,
};

pub const Diagnostic = union(enum) {
    submit_rejected,
    run_failed,
    tui_unavailable,
    missing_model,
    unknown_model,
    invalid_settings_model: settings_resolve.Diagnostic,
    provider_unavailable,
    missing_api_key,
};
