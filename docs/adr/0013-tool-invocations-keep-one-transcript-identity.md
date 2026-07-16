# ADR 0013: Tool invocations keep one transcript identity

## Status

Accepted.

## Context

A tool call begins before execution. `pi-ai` streams `toolcall_start | toolcall_delta | toolcall_end` inside `message_update`, with the current best-effort parsed arguments at the changed `contentIndex`. Only after the assistant message ends does `pi-agent-core` emit `tool_execution_start`, optional partial-result updates, and the final execution result.

OpenZi previously ignored tool-call parts in the streaming assistant message. It created a transient row at `tool_execution_start`, then destroyed that row and built another committed row from the later tool-result message. Arguments were therefore invisible while generated, source order was lost, and native identity changed at the most important lifecycle boundary.

Pi's pinned `interactive-mode.ts` creates `ToolExecutionComponent` from `message_update`, updates parsed arguments, marks arguments complete at `message_end`, and applies execution updates to the same component. Grok Build's pinned pager independently demonstrates stable keyed transcript entries, eager placeholder refinement, timing preservation, and truncation after wrapping. Pi remains the behavior reference; Grok's ACP tracker, actors, and scrollback framework are not imported.

## Decision

`InteractiveStore` owns a bounded transient invocation union:

```text
preparing(partial args)
  -> ready(final args)
  -> running(partial result?)
  -> done(final result) | failed(final result)

preparing | ready | running
  -> aborted(result)
```

The store consumes only the changed tool-call part identified by `assistantMessageEvent.contentIndex`; it does not scan or copy the assistant timeline. `AgentSession.streamingMessage` and committed messages remain authoritative. At most 64 transient invocations are retained. At `agent_end`, any invocation that received no terminal execution event becomes `aborted` instead of disappearing; this covers later calls skipped when an earlier sequential call is interrupted.

`StreamingAssistantView` projects tool-call parts at their actual content positions beside thinking and prose. `TranscriptView` admits at most 64 projected tool IDs across embedded, standalone, and committed placement, replacing older projected invocations with bounded omission rows. It indexes each admitted `ToolCallView` by tool-call ID. One stable native root receives partial arguments, ready/running transitions, partial output, and the final tool-result payload. When the assistant message commits, its streaming root is promoted only at the message index where streaming began. When the tool result commits, an embedded tool view is updated in place; a standalone fallback is promoted rather than rebuilt. If live message eviction removes an assistant while its result remains inside the 200-message window, the same tool root is detached and promoted to that result position before the assistant is destroyed. Live and restored projections therefore agree.

Built-in tool semantics remain in `packages/coding-agent`. The pure `projectToolDisplay()` boundary validates unknown args/results and produces a closed, framework-neutral display value for bash, read, write, edit, or generic tools. Output, full-output paths, notice count, and each notice are bounded before wrapping. The OpenTUI view owns width, wrapping, rail styling, expansion, native identity, and selection mechanics; it clears native selection before destroying selectable preview rows and does not parse built-in result details by tool name.

Tool previews are bounded before entering the TUI and again after cell-aware visual wrapping. Collapsed tools retain at most 12 preview rows by kind; expansion retains at most 200 visual rows. Bash keeps a five-row tail and exposes structured truncation/full-output notices. Read is compact on success and reveals bounded output on expansion or failure. Write streams a bounded content head. Edit streams bounded replacements and replaces them with the executed diff. Generic arguments and output remain bounded. The mode-owned `app.tools.expand` binding toggles detail without replacing roots. One transcript-owned live request refreshes elapsed text for visible running tools through the renderer lifecycle; individual tool views never create timers or frame schedulers.

## Consequences

- A user can see tool identity and meaningful arguments while the model is still generating them.
- Sequential calls distinguish complete-but-waiting arguments from running execution.
- Tool rows remain source ordered and keep native identity through final commit and projection-boundary promotion.
- Transcript reconciliation still uses one frame-coalesced notification stream and updates only changed retained handles.
- Tool-specific hints and structured result details can evolve beside their coding-agent tools without importing OpenTUI into `packages/coding-agent`.
- Expansion currently applies to all projected tool rows, matching Pi's simple global interaction. Per-row focus or folding requires a separate navigation owner rather than booleans on renderables.
