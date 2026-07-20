# ADR 0013: Tool invocations keep one transcript identity

> Amended by [ADR 0014](0014-tool-presentation-is-semantic-data.md): invocation identity and placement remain unchanged, while the former per-tool `ToolDisplay` union is replaced by typed result details and semantic presentation primitives.

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

Built-in tool semantics remain in `packages/coding-agent`. Each tool returns bounded typed result details separately from model-facing content. A pure projector validates the current invocation and produces one shallow, framework-neutral `ToolPresentation`: verb-first semantic header, optional `terminal | source | diff | text` body, structured notices, explicit compact/detailed windows, and generic timing policy. Every known built-in projector is total: obsolete or malformed details are ignored as a whole while the same semantic row degrades to bounded arguments/result content. Only unknown tool names use the JSON-oriented generic projection. There are no legacy tool-specific compatibility parsers.

The OpenTUI view receives lifecycle status plus `ToolPresentation`; it never switches on built-in names or parses their arguments and result details. It owns width, path display and links, command highlighting, cell-aware wrapping, lifecycle-colored open-rail chrome, compact/detailed density, native identity, selection, observed timing, and renderable disposal. Tool previews are bounded before entering the TUI and again after visual wrapping. Compact bodies retain at most 12 rows and detailed bodies at most 200. The mode-owned `app.tools.expand` binding toggles density without replacing roots. One transcript-owned live request refreshes inline timing for visible running tools without reprojecting tool data; individual tool views never create timers or frame schedulers. See `docs/tool-presentation-implementation-spec.md` and `docs/transcript-item-presentation-implementation-spec.md`.

## Consequences

- A user can see tool identity and meaningful arguments while the model is still generating them.
- Sequential calls distinguish complete-but-waiting arguments from running execution.
- Tool rows remain source ordered and keep native identity through final commit and projection-boundary promotion.
- Transcript reconciliation still uses one frame-coalesced notification stream and updates only changed retained handles.
- Tool-specific hints and typed result details evolve in coding-agent projectors without importing OpenTUI or adding tool dispatch to `packages/tui`.
- Expansion currently applies to all projected tool rows, matching Pi's simple global interaction. Per-row focus or folding requires a separate navigation owner rather than booleans on renderables.
