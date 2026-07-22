# Retry failures remain durable but leave provider context

Status: Accepted

Zi retries transient model failures inside the `AgentSession` operation that admitted the model call. Agent turns and compaction summary samples share one validated exponential-backoff policy, while context overflow remains the separate compact-and-continue transaction. Provider/SDK retries default to zero so waits remain visible, cancellable, and owned by the coding-agent layer. Tools and other side effects are never admitted into this retry policy.

Every assistant failure is persisted normally. When `AgentSession` admits a retry, `SessionManager` appends a `retry` marker referencing that failure before backoff begins. The marker excludes the failed attempt from live context, restored context, and future compaction input without deleting it from the journal. `SessionManager` separately exposes a stable presentation projection that retains marked failures until an explicit compaction replacement, so terminal clients can show why a retry happened without copying message text or feeding malformed assistant/tool sequences back to a provider.

Retry waiting is an explicit phase of the owning agent run or compaction operation. That phase owns attempt identity, deadline, cancellation, and settlement. Zi accepts at most three retries and a 17-second base delay, keeping the complete `1x + 2x + 4x` wait below two minutes. Escape uses the mode-owned semantic interrupt path; the TUI derives its countdown from the session deadline through the existing renderer live lifecycle and owns no retry timer.

`agent_end.willRetry`, bounded retry events, and one final `agent_settled` expose the same lifecycle to interactive, text, and JSON clients. A cancelled, exhausted, stale, or disposed retry cannot continue provider work or commit compaction state. Future branch summarization joins this policy through its own operation state rather than introducing a retry manager.
