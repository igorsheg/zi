# Error Surfacing Review

I would not ship this yet. The shape is mostly Zi-shaped and not a framework, but there are a few correctness bugs in ownership/error handling that are exactly the kind of thing Zig is supposed to make obvious.

Gates run:

- `zig build test` ✅
- `zig build` ✅
- `zig fmt --check src` ✅

## Blockers

### 1. `SessionRuntime.enqueueEvent` can store an owned event and still return an error

`src/coding_agent/session_runtime.zig:1917`

```zig
if (self.events.pushOrDrop(sequenced)) return;
if (self.pending_event == null) {
    self.pending_event = sequenced;
} else {
    var owned_envelope = sequenced;
    owned_envelope.deinit(self.allocator);
}
return error.EventQueueFull;
```

Now `operation_finished` can own `failure`. Callers do this:

```zig
var failure = try self.copyLatestOperationalFailure();
errdefer if (failure) |*owned| owned.deinit(self.allocator);
try self.enqueueEvent(... failure ...);
```

If the event queue is full and `pending_event == null`, `enqueueEvent` takes ownership into `pending_event` but returns `error.EventQueueFull`, so caller `errdefer` frees the same strings. Later the pending event is delivered/deinitialized: use-after-free / double-free.

Smallest fix: do not return an error after taking ownership.

```zig
if (self.events.pushOrDrop(sequenced)) return;
if (self.pending_event == null) {
    self.pending_event = sequenced;
    return;
}
var owned_envelope = sequenced;
owned_envelope.deinit(self.allocator);
return error.EventQueueFull;
```

Add a test that fills the runtime event queue, finishes a failed operation with an owned `failure`, then drains/deinits under GPA.

---

### 2. HTTP error body ownership leaks at the AI stream boundary

`src/ai/providers/openai_responses.zig:91-98` allocates `detail`, then:

```zig
try state.emitError(detail, shared.httpFailure(request, state.response.head.status, detail));
```

`SsePullStream.emitError` stores `detail` in both `error_message` and `operational_failure.detail`:

`src/ai/providers/openai_responses_shared.zig:273-279`

But `SsePullStream.deinit` does not free it:

`src/ai/providers/openai_responses_shared.zig:282-291`

Same issue exists in Codex for non-retryable HTTP failures.

Right now the stream state has no clear owner for that allocation. Either the owner struct must own `error_detail`, or `emitError` must copy into an arena that `SsePullStream.deinit` owns. Do not leave protocol message slices pointing at anonymous allocations.

---

### 3. `OutOfMemory` is still converted into user-facing operational failure

OpenAI/Codex stream construction catches every error:

- `src/ai/providers/openai_responses.zig:55-58`
- `src/ai/providers/openai_codex_responses.zig:60-64`

```zig
const state = createResponseStream(...) catch |err| return shared.errorStream(request, err);
```

That includes `error.OutOfMemory` from allocation/building request bodies/headers. `errorStream` then turns it into an assistant error fact.

That violates the stated invariant: allocation failure remains explicit, not an operational provider failure.

Given the provider API returns a stream, the minimal repair is probably a synthetic stream whose first `next()` returns `error.OutOfMemory` for allocation failure, while still using assistant terminal facts for real operational setup failures like `MissingApiKey`.

---

### 4. Mid-stream finish error handling is wrong

`src/ai/providers/openai_responses_shared.zig:338-347`

```zig
fn finish(self: *Self) !void {
    self.done = true;
    var sink = self.reducerSink();
    try self.parser.finish(&sink);
    try self.reducer.finish(self.request.io, sink.assistant_sink);
}
```

If `parser.finish` or `reducer.finish` fails, `next()` calls `completeOperationalError`, but `completeOperationalError` sees `self.done == true` and returns pending/null without emitting the classified failure.

So EOF/parser/reducer finish failures can become `MissingAssistantResult` or disappear from the typed failure path. Also `OutOfMemory` on finish is not preserved.

Set `done = true` only after successful terminal emission, and special-case `error.OutOfMemory` everywhere in this path.

---

### 5. Codex retries lose the final typed failure

`src/ai/providers/openai_codex_responses.zig:151-216`

For retryable HTTP statuses, `openOnce` frees the body and returns `error.RetryableRequestFailed`. On the final attempt, `openWithRetries` returns that bare error. `errorStream` classifies it as `unknown`.

So a final Codex 429/5xx becomes “RetryableRequestFailed / unknown” instead of `rate_limited` or `provider_unavailable`.

Retry-after support can be a follow-up. Preserving the final failure category is not optional if this PRD claims terminal facts agree.

Small fix: store the last `httpFailure` detail in the stream owner/state and, on the final attempt, emit it instead of returning `RetryableRequestFailed`.

---

## Other findings

### AI boundary bounds are not fully enforced

`providerEventFailure` uses the same string for `message` and `detail`:

`src/ai/providers/openai_responses_shared.zig:836-844`

```zig
.message = message,
.detail = message,
```

`message` can be up to `detail_bytes_max` because it comes from `formatErrorMessage`. Public protocol later truncates to 512, but the AI boundary fact says `message_bytes_max = 512`.

Make provider event failures use a concise static/category message and put provider text in `detail`.

Also, session replay load parses persisted `operationalFailure` strings without enforcing the same caps:

`src/coding_agent/session_manager.zig:1178-1187`

A malicious/old jsonl line can put up to the session line limit into resident failure strings before public projection truncates.

---

### Context-overflow regex is duplicated policy

There is one matcher in AI:

`src/ai/providers/openai_responses_shared.zig:61-89`

And another in coding-agent:

`src/coding_agent/message_policy.zig:47-75`

Typed facts are the good path. The string fallback is necessary for legacy/custom providers, but duplicating the phrase table is how regex policy soup starts. Keep one fallback owner or expose one helper from `ai` for coding-agent to use.

---

## Specific answers

1. **`OperationalFailure` shape:** mostly right and small. `category`, `message`, `detail`, `retryable` all pay rent. `provider`/`model` duplicate assistant metadata but are useful on `operation_finished`/snapshots, so acceptable. Do not add `http_status`, `code`, or `retry_after` to the public fact yet.

2. **Optional `failure` ownership:** `client_protocol` deinit paths look mostly correct. The serious ownership bug is `enqueueEvent` returning error after moving an owned failure into `pending_event`.

3. **Bounded early enough:** not completely. HTTP body/detail is bounded early. SSE provider failure `message` is not capped to `message_bytes_max`, and session load can resurrect oversized persisted failure fields.

4. **Mid-stream SSE/read/parser failure conversion:** no. `OutOfMemory` is not preserved consistently, and finish-path errors can be swallowed/misclassified because `done` is set too early.

5. **Context overflow fallback:** broad enough, maybe too broad now. The bigger issue is duplicated phrase policy.

6. **Codex retry-after:** retry-after itself can be follow-up. Losing final 429/5xx category after retries is a correctness gap in this PRD.

7. **TUI `[annote] message`:** yes, this improves grammar. It stays generic in `src/tui/render.zig`; not a second styling system.

8. **Core `src/tui` provider awareness:** no new agent/provider/error knowledge found in core TUI. Mapping lives in `src/frontends/tui/interactive.zig`, which is the right boundary.

9. **Delete / add tests:**
   - Delete or demote `context overflow fallback follows common provider wording`; it locks in private regex shape.
   - Add: event queue full + failed `operation_finished.failure` retained as pending event, then drain/deinit without UAF/leak. That catches the scariest regression.

10. **Smallest follow-up:** fix `enqueueEvent` ownership semantics first. That is a tiny diff and removes a release-mode memory corruption path. Next: preserve `OutOfMemory` through provider stream construction/finish.
