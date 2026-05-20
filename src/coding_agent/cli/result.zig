pub const ExecutionResult = union(enum) {
    ok,
    err: Diagnostic,
};

pub const Diagnostic = union(enum) {
    submit_rejected,
    run_failed,
};
