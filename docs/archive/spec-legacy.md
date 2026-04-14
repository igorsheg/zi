# zi specification

pi-mono reimplemented in zig. same product, same architecture, same data formats — compiled, zero-alloc hot paths, explicit ownership.

## doctrine

**pi-mono is the product spec.** every user-facing behavior, data format, wire protocol, event contract, and extension seam is taken from pi-mono. we don't invent alternatives. when the question is "how should X work?", the answer is "how does pi-mono do it?"

**zig is the implementation advantage, not the divergence.** comptime type generation, explicit memory ownership, zero-copy parsing, pre-allocated render buffers, no GC pauses. these are implementation details behind pi-mono's interfaces. the external contract — session files, event shapes, CLI flags — must be identical.

**never build a layer without a consumer above it.** if you're building the provider interface, there must be an agent loop calling it. if you're building the agent loop, there must be a CLI mode consuming events. code without a consumer is code in a vacuum where drift is invisible.

---

## the product

pi-mono is a terminal coding agent. you talk to it, it reads/writes/edits files, runs bash, uses tools, remembers conversations across sessions. you extend it without forking.

five layers, each with a precise responsibility:

```
L5  COMPOSITION ROOT  (coding_agent)
    wires everything below into a working app

L4  STATEFUL AGENT    (agent)
    reusable conversation loop with tool execution

L3  TERMINAL UI       (tui)
    differential renderer, component model, keyboard

L2  LLM SUBSTRATE     (ai)
    provider-agnostic streaming, model registry

L1  DATA FORMATS      (shared types across all layers)
    messages, events, session entries, models
```

---

## L1 — data formats

the foundation. everything above depends on these shapes being right.

### source of truth

`pi-mono/packages/ai/src/types.ts` — message types, model, usage, events.
`pi-mono/packages/agent/src/types.ts` — agent message, agent tool, agent state, agent events.
`pi-mono/packages/coding-agent/src/core/session-manager.ts` — session entry types.
`pi-mono/packages/coding-agent/src/core/messages.ts` — custom message roles.

### content blocks

```
TextContent       { text, textSignature? }
ThinkingContent   { thinking, thinkingSignature?, redacted? }
ImageContent      { data (base64), mimeType }
ToolCall          { id, name, arguments, thoughtSignature? }
```

### messages

```
UserMessage       { content: string | (TextContent | ImageContent)[], timestamp }
AssistantMessage  { content: (TextContent | ThinkingContent | ToolCall)[], api, provider, model, responseId?, usage, stopReason, errorMessage?, timestamp }
ToolResultMessage { toolCallId, toolName, content: (TextContent | ImageContent)[], details?, isError, timestamp }
```

`StopReason = "stop" | "length" | "toolUse" | "error" | "aborted"`

### assistant stream events (12 variants)

the streaming protocol. every provider must emit events in this order:

```
start               { partial }
text_start          { contentIndex, partial }
text_delta          { contentIndex, delta, partial }
text_end            { contentIndex, content, partial }
thinking_start      { contentIndex, partial }
thinking_delta      { contentIndex, delta, partial }
thinking_end        { contentIndex, content, partial }
toolcall_start      { contentIndex, partial }
toolcall_delta      { contentIndex, delta, partial }
toolcall_end        { contentIndex, toolCall, partial }
done                { reason: stop|length|toolUse, message }
error               { reason: aborted|error, error }
```

ordering contract: `start` first, then content blocks in order (each block has start/delta*/end), then exactly one terminal (`done` or `error`).

### agent events (10 variants)

```
agent_start            { sessionId, timestamp }
turn_start             { turnNumber }
message_start          { message }
message_update         { message, assistantMessageEvent }
message_end            { message }
tool_execution_start   { toolCallId, toolName, args }
tool_execution_update  { toolCallId, toolName, args, partialResult }
tool_execution_end     { toolCallId, toolName, result, isError }
turn_end               { turnNumber }
agent_end              { sessionId, usage, cost }
```

### session entries (9 types)

append-only JSONL. each entry has `id` (8-char hex) and `parentId` forming a tree.

| type | in LLM context? | purpose |
|------|-----------------|---------|
| `message` | yes | user, assistant, toolResult messages |
| `thinking_level_change` | no | persists thinking level switches |
| `model_change` | no | persists model switches |
| `compaction` | yes (as summary) | structured compaction checkpoint |
| `branch_summary` | yes | captures abandoned branch context |
| `custom` | no | extension state storage |
| `custom_message` | yes | extension-injected context |
| `label` | no | user bookmarks on entries |
| `session_info` | no | session display name |

### model

```
Model { id, name, api, provider, baseUrl, reasoning, input: [text|image], cost: { input, output, cacheRead, cacheWrite }, contextWindow, maxTokens, headers?, compat? }
```

`Api` and `Provider` support both known variants and custom strings for user-configured providers.

---

## L2 — LLM substrate (ai)

provider-agnostic streaming interface. knows nothing about agents, sessions, or tools beyond their schema shape.

### source of truth

`pi-mono/packages/ai/src/stream.ts` — entry points.
`pi-mono/packages/ai/src/api-registry.ts` — provider registry.
`pi-mono/packages/ai/src/providers/` — provider implementations.
`pi-mono/packages/ai/src/utils/event-stream.ts` — streaming primitive.

### what it owns

- `stream()` / `complete()` / `streamSimple()` / `completeSimple()` — top-level entry points
- provider registry — maps Api → provider implementation
- provider implementations — anthropic, openai-completions, openai-responses, google, vertex, gemini-cli, mistral, bedrock, azure
- model registry — catalog with cost tracking, `getModel()` / `getModels()` / `calculateCost()`
- transport — HTTP POST + SSE parsing
- utilities — context overflow detection, tool argument validation, unicode sanitization

### what it does NOT own

- conversation state, history, or persistence
- tool execution or orchestration
- steering, follow-ups, or queueing
- any UI concern

### provider contract

providers must:
- never throw for request/model/runtime failures
- encode failures as error events in the stream
- emit events following the 12-variant protocol exactly
- terminate with exactly one `done` or `error` event carrying a complete `AssistantMessage`

### zig implementation

streaming is pull-iterator or callback-based (no async). SSE parsing uses zero-alloc fixed buffers. HTTP uses `std.http.Client` (zig 0.15 API). provider interface uses vtable-based polymorphism.

---

## L3 — terminal UI (tui)

differential line renderer with component model. knows nothing about agents, LLMs, or sessions.

### source of truth

`pi-mono/packages/tui/src/tui.ts` — core TUI, container, rendering.
`pi-mono/packages/tui/src/terminal.ts` — raw terminal I/O.
`pi-mono/packages/tui/src/keys.ts` — keyboard input model.
`pi-mono/packages/tui/src/components/` — reusable components.

### what it owns

- `Component` interface: `render(width) → lines`, `handleInput(key)`, `invalidate()`
- `Container` — stacks components vertically, manages children
- `TUI` — extends container with focus, overlay stack, render loop
- differential rendering — compare previous vs current lines, repaint only changed
- synchronized output — CSI 2026 bracketed writes
- keyboard — kitty protocol with xterm fallback, key parsing
- terminal — raw mode, capability detection, cursor management
- components — editor, input, select list, markdown, box, text, image, etc.

### what it does NOT own

- what a "session" or "agent" is
- tool execution policy
- any LLM concern

### render pipeline

```
Component.render(width) → []string (lines of ANSI text)
         ↓
differential compare (previous vs current frame)
         ↓
damage regions (firstChanged..lastChanged)
         ↓
ANSI output into buffer
         ↓
synchronized write (CSI 2026 bracketed)
```

### zig advantages

pre-allocated A/B output buffers. arena allocator for per-frame temporaries freed after each render. zero heap allocation in the render hot path. comptime ANSI sequence generation.

---

## L4 — stateful agent (agent)

reusable conversation loop with tool execution. the layer most at risk of collapsing into the composition root.

### source of truth

`pi-mono/packages/agent/src/agent.ts` — stateful Agent class.
`pi-mono/packages/agent/src/agent-loop.ts` — dual-loop implementation.
`pi-mono/packages/agent/src/types.ts` — agent types, hooks, tool contracts.

### what it owns

the **reusable stateful product layer**. not just a while loop over LLM calls.

- `Agent` — public API with rich state management
  - `prompt(messages)` — start new conversation turn
  - `continue()` — resume from existing context
  - `steer(message)` — inject mid-run steering message
  - `followUp(message)` — queue post-run continuation
  - `abort()` — cancel with signal propagation
  - `waitForIdle()` — block until agent stops
  - `subscribe(listener)` — receive AgentEvents
  - state mutators: `setSystemPrompt`, `setModel`, `setTools`, `setThinkingLevel`

- `AgentState` — tracks everything
  - `systemPrompt`, `model`, `thinkingLevel`, `tools`, `messages`
  - `isStreaming`, `streamingMessage` (partial), `pendingToolCalls`, `errorMessage`

- `AgentLoopConfig` — hook bag for customization
  - `convertToLlm(messages)` — AgentMessage[] → Message[] for LLM
  - `transformContext(messages, signal)` — prune/inject before call
  - `getSteeringMessages()` — mid-run injection after tool execution
  - `getFollowUpMessages()` — post-run continuation
  - `beforeToolCall(ctx, signal)` — validate/block tool execution
  - `afterToolCall(ctx, signal)` — modify tool results
  - `getApiKey(provider)` — per-call key resolution (for expiring tokens)

### dual-loop architecture

```
OUTER LOOP (follow-ups)
│
├── get follow-up messages (if any queued)
├── add to context
│
└── INNER LOOP (tool calls + steering)
    │
    ├── transformContext(messages)
    ├── convertToLlm(messages)
    ├── stream assistant response
    │
    ├── if toolUse:
    │   ├── prepare all (validate args, beforeToolCall hook)
    │   ├── execute (sequential or parallel)
    │   ├── finalize (afterToolCall hook, emit events)
    │   ├── check steering messages → continue if any
    │   └── continue inner loop
    │
    ├── if stop/length:
    │   ├── check steering → continue if any
    │   └── break inner loop
    │
    └── if error/aborted:
        └── break both loops

CHECK FOLLOW-UPS → continue outer if any
```

### tool execution lifecycle

three phases, never collapsed:

1. **prepare** — find tool by name, validate args against schema, call `beforeToolCall` hook. can block execution.
2. **execute** — call `tool.execute()` with abort signal and update callback. returns `AgentToolResult { content, details }`.
3. **finalize** — call `afterToolCall` hook to override content/details/isError. emit `tool_execution_end`. return `ToolResultMessage`.

two modes:
- **sequential** — prepare → execute → finalize, one at a time
- **parallel** — prepare all sequentially, execute concurrently, finalize in source order

### cancellation contract

abort signal threads through the entire stack:
- `Agent.abort()` → AbortController
- signal passed to: stream function, beforeToolCall, tool.execute, afterToolCall, transformContext
- not just cooperative checkpoints — in-flight operations can be cancelled

### what it does NOT own

- session persistence
- compaction
- extension loading or dispatch
- UI rendering
- CLI mode selection

### critical boundary

if agent starts owning persistence, retry logic, extension wiring, or UI, the layer has drifted. those belong in L5. agent is reusable across different products — a slack bot and a CLI should both use the same Agent.

---

## L5 — composition root (coding_agent)

wires all lower layers into the product. should feel thin because real work lives below.

### source of truth

`pi-mono/packages/coding-agent/src/core/agent-session.ts` — the coordinator.
`pi-mono/packages/coding-agent/src/core/sdk.ts` — bootstrap/wiring.
`pi-mono/packages/coding-agent/src/core/session-manager.ts` — JSONL persistence.
`pi-mono/packages/coding-agent/src/core/compaction/` — context summarization.
`pi-mono/packages/coding-agent/src/core/extensions/` — extension system.
`pi-mono/packages/coding-agent/src/core/tools/` — built-in tool implementations.
`pi-mono/packages/coding-agent/src/modes/` — CLI mode implementations.

### what it owns

- **session persistence** — JSONL tree format, `buildSessionContext()`, branching, migration
- **compaction** — detect overflow, find cut point, LLM summarize, persist checkpoint
- **extension system** — discover, load, bind, dispatch events, UI replacement
- **built-in tools** — read, write, edit, bash, grep, find, ls
- **resource discovery** — skills, prompts, themes, packages
- **auth + settings** — credential storage, user preferences
- **model registry** — merges built-in + custom models from config
- **CLI modes** — interactive (TUI), print (-p), JSON (--mode json), RPC (--mode rpc)
- **AgentSession** — the coordinator that wires agent to session to extensions to compaction

### what it does NOT own

- the conversation loop or tool execution lifecycle (that's L4)
- the streaming event protocol (that's L2)
- the rendering engine (that's L3)
- message or model types (that's L1)

### extension system

TS modules that register tools, commands, shortcuts, event handlers, UI components:

```typescript
export default function (pi: ExtensionAPI) {
    pi.on("tool_call", async (event, ctx) => { ... });
    pi.registerTool({ name: "deploy", ... });
    pi.registerCommand("stats", { ... });
}
```

30+ lifecycle events. UI replacement for footer, header, editor, overlays. provider registration for custom OAuth flows.

zig implementation: this is the hardest zig challenge. pi-mono loads TS dynamically via jiti. options for zi: FFI bridge to bun/node, wasm runtime, shared library plugins, or embedded scripting.

### `prompt()` end-to-end flow

the full path through L5 → L4 → L2:

```
user types message
  → extension command check (handle /command)
  → extension input hook (transform input)
  → skill/template expansion
  → if streaming: queue as steer or follow-up
  → pre-flight: validate model, auth, flush pending
  → pre-prompt compaction check
  → build messages (user msg + images + pending)
  → extension before_agent_start hook (inject messages, modify system prompt)
  → agent.prompt(messages)
    → agent loop (L4)
      → stream to provider (L2)
        → HTTP POST + SSE
        → events flow back
      → tool execution if needed
      → steering/follow-up checks
    → agent events flow to session
  → persist messages to JSONL
  → post-run compaction check
  → wait for retry if triggered
```

---

## build order

vertical slice first, then fill horizontally. never build a layer without a consumer.

### phase 0 — contracts

define public boundaries as zig types. nothing runs. everything compiles. build.zig DAG enforces layering.

```
packages/ai/protocol.zig         ← message/model/event types
packages/ai/provider.zig         ← Provider vtable + Registry shape
packages/agent/protocol.zig      ← AgentMessage, AgentTool, AgentState, AgentEvent
packages/agent/hooks.zig         ← AgentLoopConfig shape
packages/session/protocol.zig    ← 9 entry types, session header
packages/tui/component.zig       ← Component interface, Key type
```

### phase 1 — vertical slice: `zi -p "hello"`

the simplest thing that works end-to-end. forces every layer thin but real.

```
main.zig          → parse "-p" flag
agent             → single-turn loop (no tools, no steering)
ai/anthropic      → HTTP POST, SSE parse, emit events
stdout            → print text_delta events
```

validates: types serialize correctly, streaming works, event protocol is right, layer boundaries are real.

skips: tools, steering, follow-ups, sessions, compaction, TUI, extensions, all other providers.

### phase 2 — agent loop completeness

full dual-loop with tools. conformance tests from `faux-provider.test.ts`:
- exact event order
- tool call streaming
- error/aborted terminals
- multiple tool calls per message
- steering and follow-up semantics

### phase 3 — session persistence

JSONL tree format. 9 entry types. `buildSessionContext()`. branching. compaction. migration.

conformance: round-trip tests against pi-mono session fixtures.

### phase 4 — TUI

differential renderer. component model. keyboard. largely independent of L2-L4.

### phase 5 — extensions + full product

wire everything. extension loading. all CLI modes. resource discovery.

---

## zig advantages (implementation, not interface)

these change HOW we build pi-mono's design, not WHAT we build.

| area | advantage |
|------|-----------|
| memory | explicit ownership. session entries freed atomically via arena. no GC pauses during streaming. |
| rendering | pre-allocated A/B buffers. comptime ANSI generation. zero-alloc damage tracking. arena per frame. |
| streaming | zero-copy SSE parsing into fixed buffers. pull-iterator with blocking reads. no async runtime. |
| concurrency | native threads for parallel tool execution. no async runtime overhead. |
| startup | single static binary. no node/bun bootstrap. sub-10ms cold start. |
| type safety | tagged unions for messages/events. comptime validation of event handler signatures. |
| JSON | manual serialization for hot paths. `std.json` only for cold paths. |

---

## anti-patterns

- **don't port syntax.** never open a TS file and translate it line by line. understand what it does, then write zig that does the same thing.
- **don't build without a consumer.** every layer needs something above it exercising its contract. otherwise drift is invisible.
- **don't collapse layers.** if agent starts owning session persistence or extension dispatch, stop. that's L5's job.
- **don't invent schemas.** if pi-mono stores `parentId`, we store `parentId`. not `parent_id`. wire formats must match.
- **don't coarsen events.** pi-mono has `text_start/delta/end`, `thinking_start/delta/end`, `toolcall_start/delta/end`. we emit those, not generic `update`.
- **don't simplify the agent loop.** dual-loop with steering and follow-ups. three-phase tool lifecycle. cancellation threading. all of it.
- **don't stub.** everything committed must work end-to-end. no `@panic("not yet implemented")`.
- **don't go wide before going deep.** one provider end-to-end before all providers. one tool before all tools. vertical slice validates architecture.

---

## reference material

### pi-mono source (local at `.references/pi-mono/`)

| component | path |
|-----------|------|
| message types | `packages/ai/src/types.ts` |
| stream events | `packages/ai/src/types.ts:237-249` |
| provider interface | `packages/ai/src/api-registry.ts` |
| stream entry points | `packages/ai/src/stream.ts` |
| provider implementations | `packages/ai/src/providers/` |
| faux provider (test oracle) | `packages/ai/src/providers/faux.ts` |
| faux provider tests | `packages/ai/test/faux-provider.test.ts` |
| agent types | `packages/agent/src/types.ts` |
| agent loop | `packages/agent/src/agent-loop.ts` |
| agent class | `packages/agent/src/agent.ts` |
| session manager | `packages/coding-agent/src/core/session-manager.ts` |
| agent session coordinator | `packages/coding-agent/src/core/agent-session.ts` |
| SDK bootstrap | `packages/coding-agent/src/core/sdk.ts` |
| compaction | `packages/coding-agent/src/core/compaction/compaction.ts` |
| extension types | `packages/coding-agent/src/core/extensions/types.ts` |
| extension loader | `packages/coding-agent/src/core/extensions/loader.ts` |
| built-in tools | `packages/coding-agent/src/core/tools/` |
| TUI core | `packages/tui/src/tui.ts` |
| terminal I/O | `packages/tui/src/terminal.ts` |
| keyboard input | `packages/tui/src/keys.ts` |
| CLI entry | `packages/coding-agent/src/cli.ts` |
| CLI modes | `packages/coding-agent/src/modes/` |

### external references

| project | what to study |
|---------|--------------|
| [nullclaw](https://github.com/nullclaw/nullclaw) | zig LLM patterns: vtable providers, callback streaming, SSE transport, JSON serialization |
| [OpenTUI](https://github.com/anomalyco/opentui) | zig TUI: pre-allocated buffers, differential rendering, arena allocators |
| [Ghostty](https://ghostty.org/) | zig terminal: VT parser, kitty keyboard protocol, capability detection |
| [eth.zig](https://github.com/StrobeLabs/eth.zig) | zero-alloc SSE parser, W3C spec compliant |
