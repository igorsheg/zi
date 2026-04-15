const std = @import("std");

/// Read-only cooperative cancellation token for one in-flight run.
/// Passed through agent loop → provider → tool execution.
/// All layers check `isAborted()` at cancellation points.
///
/// The signal is generation-scoped: when the owner starts a new run,
/// stale signals from the previous run become aborted automatically.
pub const AbortSignal = struct {
    flag: *const std.atomic.Value(bool),
    generation: *const std.atomic.Value(u64),
    expected_generation: u64,

    /// Sentinel for "no abort signal" — never triggers.
    pub const none: AbortSignal = .{
        .flag = &never_aborted,
        .generation = &never_generation,
        .expected_generation = 0,
    };

    pub fn isAborted(self: AbortSignal) bool {
        return self.generation.load(.acquire) != self.expected_generation or self.flag.load(.acquire);
    }

    pub fn isNone(self: AbortSignal) bool {
        return self.flag == &never_aborted and
            self.generation == &never_generation and
            self.expected_generation == 0;
    }

    pub fn runId(self: AbortSignal) u64 {
        return self.expected_generation;
    }

    var never_aborted = std.atomic.Value(bool).init(false);
    var never_generation = std.atomic.Value(u64).init(0);
};

/// Run-scoped abort controller.
///
/// One owner mutates it (`beginRun`, `requestAbort`); readers receive
/// `AbortSignal` snapshots that stay valid for the lifetime of the run.
pub const AbortController = struct {
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    pub fn beginRun(self: *AbortController) AbortSignal {
        self.aborted.store(true, .release);
        const next_generation = self.generation.load(.acquire) + 1;
        self.generation.store(next_generation, .release);
        self.aborted.store(false, .release);
        return .{
            .flag = &self.aborted,
            .generation = &self.generation,
            .expected_generation = next_generation,
        };
    }

    pub fn signal(self: *const AbortController) AbortSignal {
        const current_generation = self.generation.load(.acquire);
        return .{
            .flag = &self.aborted,
            .generation = &self.generation,
            .expected_generation = current_generation,
        };
    }

    pub fn requestAbort(self: *AbortController) void {
        self.aborted.store(true, .release);
    }

    pub fn isAborted(self: *const AbortController) bool {
        return self.aborted.load(.acquire);
    }

    pub fn currentRunId(self: *const AbortController) u64 {
        return self.generation.load(.acquire);
    }
};

test "AbortController invalidates stale signals when a new run begins" {
    var controller = AbortController{};

    const first = controller.beginRun();
    try std.testing.expect(!first.isAborted());
    try std.testing.expect(first.runId() != 0);

    controller.requestAbort();
    try std.testing.expect(first.isAborted());

    const second = controller.beginRun();
    try std.testing.expect(!second.isAborted());
    try std.testing.expect(second.runId() != first.runId());
    try std.testing.expect(first.isAborted());
}

test "AbortSignal.none never aborts" {
    try std.testing.expect(AbortSignal.none.isNone());
    try std.testing.expect(!AbortSignal.none.isAborted());
}
