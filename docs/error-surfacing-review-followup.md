# Error Surfacing Review Follow-up

Re-reviewed the current tree after the serious blocker fixes and reran gates.

Gates passed:

- `zig build test`
- `zig build`
- `zig fmt --check src`

## Fixed satisfactorily

- `SessionRuntime.enqueueEvent()` ownership bug is fixed. It no longer returns `EventQueueFull` after moving ownership into `pending_event`.
- HTTP error detail ownership in `SsePullStream` is now explicit via `owned_error_detail`.
- `SsePullStream.finish()` no longer sets `done = true` before terminal emission succeeds.
- Provider construction `error.OutOfMemory` is preserved via `outOfMemoryStream()` instead of becoming a user-facing provider failure.
- Codex final retryable HTTP failure now emits typed HTTP failure instead of degrading to `RetryableRequestFailed` / `unknown`.
- Provider stream failures now use concise `message` plus bounded diagnostic `detail`.
- Session load now bounds persisted `operationalFailure` fields.

## Remaining blockers

Resolved in follow-up: no blockers remain.

### 1. HTTP error-body read still masks `OutOfMemory`

Both providers still use this pattern:

```zig
const detail = readErrorBody(...) catch try std.fmt.allocPrint(...);
```

Locations:

- `src/ai/providers/openai_responses.zig`
- `src/ai/providers/openai_codex_responses.zig`

`readErrorBody()` can fail with `error.OutOfMemory`. If `allocPrint()` succeeds, OOM becomes an ordinary HTTP operational failure. That violates the invariant that allocation failure remains explicit.

Minimal fix:

```zig
const detail = readErrorBody(allocator, reader) catch |err| switch (err) {
    error.OutOfMemory => return error.OutOfMemory,
    else => try std.fmt.allocPrint(allocator, "HTTP {s}", .{@tagName(status)}),
};
```

`BodyTooLarge` degrading to `"HTTP status"` is fine. OOM is not.

### 2. `parser.finish()` can emit a terminal provider error, then get reclassified

Current finish catch:

```zig
self.finish() catch |finish_err| switch (finish_err) {
    error.OutOfMemory => return error.OutOfMemory,
    else => return self.completeOperationalError(finish_err),
};
```

But `parser.finish()` can dispatch a pending SSE event and hit `error.ErrorEmitted`, same as `parser.feed()` already handles. In that case a real provider terminal error is already pending, but finish reclassifies `ErrorEmitted` as another operational error.

Mirror the feed path:

```zig
self.finish() catch |finish_err| switch (finish_err) {
    error.OutOfMemory => return error.OutOfMemory,
    error.ErrorEmitted => return self.popPending(),
    else => return self.completeOperationalError(finish_err),
};
```

This is an edge case: provider sends an error event and closes without the usual blank-line dispatch before EOF.

## Missing regression test

Resolved in follow-up. The UAF path now has a direct regression test covering both pending-slot cases.

Original request:

> Fill the runtime event queue, produce failed `operation_finished.failure`, force it into `pending_event`, then drain/deinit cleanly.

Add this if practical. It locks the ownership contract on `enqueueEvent()`.

## Verdict

Updated after final cleanup: shippable. The follow-up blockers were fixed, the pending-event ownership regression test was added, dead `EventQueueFull` plumbing was removed, and context-overflow fallback phrases now have a single AI-owned helper used by coding-agent fallback policy.
