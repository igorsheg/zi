# zi

## contract

- Simple first. Complexity must earn its keep.
- One owner. One mutation path. One obvious failure mode.
- Encode states directly; no dummy fields, boolean modes, or ambient discipline.
- Compile errors beat runtime crashes. Crashes beat hidden corruption.
- Allocation may fail. Deallocation must succeed.
- Comments explain why. Types, assertions, comptime checks, and tests enforce what.

## tiger style systems

Use the Tiger Style discipline for runtime, async, lifecycle, queues, ownership, cancellation, workers, UI, process, and shutdown.

Before designing a boundary, answer in code:

```text
What can go wrong?
What is the maximum bound?
Who owns each resource?
Where is mutation allowed?
Which errors are handled?
Which invariants must always hold?
What is the slowest resource involved?
What must future maintainers not have to remember?
```

Runtime spine:

```text
Operation -> Backend -> Completion -> bounded queue -> owner drain
```

Rules:

- control flow is simple and explicit
- runtime is mechanism, not app policy
- completions are data, not authority
- owners mutate only at drain/apply sites
- loops, queues, buffers, retries, batches, and concurrency are bounded
- wakeups coalesce; inspect state after wake
- cancellation intent != cancellation completion
- every submitted operation completes, fails, or cancels observably
- programmer errors fail fast; operational errors are returned or reported
- no hidden async mutation, implicit defaults, or dependency-shaped control flow

## zig craft

- Read before writing. Trace before fixing.
- Small structs, explicit lifetimes, owned wrappers.
- State machines over callback control flow.
- Zi-shaped code over dependency-shaped ports.
- TigerBeetle-grade suspicion: bounds, ownership, shutdown.

## tests

- Run `zig build test` before claiming completion.
- Test invariants, not helper existence.
- Prefer narrow assertions over broad snapshots.
- Test names describe behavior: `follow up queues while running and starts after terminal`.
- Provider JSON tests may pin external contracts; internal serialization is not a contract unless callers rely on it.

## project structure

Zi starts minimal, but its architecture follows `.references/pi-mono/` contracts, rewritten with Tiger Style bounds, ownership, and explicit control flow.

```text
src/
  ai/        provider-agnostic LLM protocol and provider registry
  agent/     stateful agent loop, tool execution, event stream
  runtime/   operations, backend mechanisms, completions, queues, cancellation
  main.zig   CLI shell only; no core policy
  root.zig   public package surface
```

### `src/ai/`

Inspired by `.references/pi-mono/packages/ai/`.

Owns:

- message protocol: user, assistant, tool-result
- content blocks: text, thinking, image, tool-call
- assistant event protocol: start, deltas, tool-call events, done/error
- model metadata and cost/accounting data
- provider registry keyed by API
- stream/complete entry points
- provider adapters for OpenAI, Anthropic, etc.

Rules:

- provider request failures terminate through stream events, not side channels
- provider-specific wire formats stay behind provider adapters
- tools are schema/protocol data here; execution belongs to `agent/`
- context transformation for model calls is a boundary, not ambient mutation

### `src/agent/`

Inspired by `.references/pi-mono/packages/agent/`.

Owns:

- `Agent` state: system prompt, model, tools, transcript, active run
- agent loop: prompt/continue -> turns -> tool calls -> follow-up/steering
- event stream for UI/runtime consumers
- tool lifecycle: prepare arguments -> before hook -> execute -> after hook -> tool-result message
- steering and follow-up queues

Rules:

- `AgentMessage` may include app messages; only `ai.Message` crosses the LLM boundary
- `convertToLlm` filters/transforms at that boundary
- assistant `message_end` is a barrier before tool preflight
- parallel tools preflight sequentially, execute concurrently, persist results in assistant source order
- sequential tools execute, finalize, and emit result one at a time
- tool `terminate` stops the follow-up LLM call only when every tool in the batch asks for it
- `agent_end` means no more loop events; idle means subscribers/listeners have settled
