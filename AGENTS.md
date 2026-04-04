Issue tracking: `bd prime`

## Reference Code

pi-mono is cloned locally at `.references/pi-mono/`. When you need to reference pi-mono source (types, implementations, patterns), always use local reads/greps against `.references/pi-mono/` - never the github tools. The code is on disk.

opentui is cloned locally at `.references/opentui/`. When you need to reference opentui source (zig TUI patterns, buffer/renderer/utf8), always use local reads/greps against `.references/opentui/` - never the github tools. The code is on disk.

## Doctrine

zi must never be less capable than pi-mono at the architecture, design, or product layer. minimum bar: parity with pi-mono. maximum bar: extend pi-mono while preserving its contracts. zig is an implementation advantage, not a reason to collapse product surfaces, remove composition seams, or replace dedicated flows with narrower shortcuts.

when a zi surface drifts from pi-mono, default assumption is to close the drift, not defend it. if we simplify, that simplification must still preserve pi-mono-level capability and extensibility.

- no compatibility theater if a bad api blocks the right architecture
- no "quick fix" shim that papers over drift instead of removing it

## JSON Serialization

**do NOT hand-roll JSON.** use `std.json.Stringify` for writing and `std.json.parseFromSlice` for reading.

- **writing**: create a `std.io.Writer.Allocating`, wrap in `std.json.Stringify`, use `jw.beginObject()` / `jw.objectField("camelCase")` / `jw.write(value)` / `jw.endObject()`. this handles escaping, commas, and nesting correctly. get output via `out.toOwnedSlice()`.
- **reading**: parse into `std.json.Value` with `std.json.parseFromSlice`, extract fields by camelCase name. for struct-based parsing, use `std.json.parseFromSlice(MyStruct, ...)` when field names match.
- **shared utils**: `packages/ai/src/json_util.zig` — `cloneJsonValue`, `jsonToFloat`, enum↔string converters (`providerToString`/`parseProvider`, `parseApi`, `stopReasonToString`/`parseStopReason`). use these instead of writing local copies.
- **camelCase wire format**: zig structs use snake_case but pi-mono's JSON uses camelCase. we handle this with explicit `jw.objectField("camelCase")` calls — NOT by renaming struct fields.

## Implementation Process

two failure modes, opposite directions:

**don't approximate the protocol.** before writing any function that emits events or builds protocol objects, find the exact pi-mono function, read it fully, trace every event emitted and every field set. the pi-mono source is at `.references/pi-mono/` on disk. the WHAT must match — same events, same order, same fields.

**don't port the syntax.** never translate typescript line-by-line into zig. `async/await` → blocking calls, `Promise.all` → sequential or threads, `Array.map` → explicit loops, `try/catch` → error unions or result fields. the HOW should be idiomatic zig.

the process:
1. find the pi-mono function (e.g., `streamAssistantResponse`, `emitToolCallOutcome`)
2. list the observable behavior: events emitted, fields set, ordering, edge cases
3. write zig that produces the same observable behavior using zig idioms
4. oracle audit verifies parity after, not instead of tracing

## Testing Doctrine

**NO test spray.** we do not generate tests per-function. we test behavior at boundaries.

- **max 3-5 tests per task.** if you need more, the task is too big or you're testing implementation.
- **every test name states the behavior it verifies.** `test "session round-trips all 9 entry types"` not `test "parseEntry works"`.
- **no mocks unless crossing a network boundary.** use real modules.
- **conformance fixtures come from pi-mono** (real session files, provider responses, event transcripts). generate by running pi-mono, not by hand-writing JSON.
- **a test that can't break when behavior changes shouldn't exist.**

test types, in priority order:

1. **conformance** - golden fixtures proving our output matches pi-mono byte-for-byte.
2. **boundary** - exercise the contract between two modules (e.g., session write → read → buildSessionContext round-trip).
3. **behavior** - test what a module DOES, not how (e.g., "compaction keeps recent messages and produces summary" not "findCutPoint returns index 7").

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**

- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

pi-mono is 5 products stacked:

```
  ┌─────────────────────────────────────────────────────────────────┐
  │ PRODUCT: terminal coding agent you talk to                      │
  │                                                                 │
  │  L5  COMPOSITION ROOT (coding_agent)                            │
  │      - wires everything below into a working app                │
  │      - session persistence (JSONL tree)                         │
  │      - compaction (auto-summarize long contexts)                │
  │      - extension system (TS modules that add tools/UI/hooks)    │
  │      - resource discovery (skills, prompts, themes, packages)   │
  │      - CLI modes (interactive/print/json/rpc)                   │
  │                                                                 │
  │  L4  STATEFUL AGENT (agent)                                     │
  │      - dual-loop: inner=tools+steering, outer=follow-ups        │
  │      - tool lifecycle: prepare(validate) → execute → finalize   │
  │      - cancellation threading through all boundaries            │
  │      - AgentState with streaming/pending/error tracking         │
  │      - queue semantics for steering vs follow-up messages       │
  │      - public api: prompt/continue/steer/followUp/abort/wait    │
  │                                                                 │
  │  L3  TERMINAL UI (tui)                                          │
  │      - differential line renderer (compare prev vs new)         │
  │      - component model: render(width) → string[]                │
  │      - container/focus/overlay stack                             │
  │      - keyboard: kitty protocol + xterm fallback                │
  │      - synchronized output (CSI 2026)                           │
  │                                                                 │
  │  L2  LLM SUBSTRATE (ai)                                         │
  │      - message types (user/assistant/toolResult)                │
  │      - streaming event protocol (12 event variants)             │
  │      - provider interface + registry                            │
  │      - 18+ provider implementations                             │
  │      - model catalog with cost tracking                         │
  │      - transport (HTTP+SSE)                                     │
  │                                                                 │
  │  L1  DATA FORMATS (shared types across all layers)              │
  │      - ContentBlock = text|thinking|image|toolCall              │
  │      - Message = user|assistant|toolResult                      │
  │      - Usage, Cost, StopReason                                  │
  │      - Model (id, api, provider, cost, context window)          │
  │      - Session entry types (9 variants)                         │
  │      - AgentEvent (10 variants)                                 │
  │      - AssistantMessageEvent (12 variants)                      │
  └─────────────────────────────────────────────────────────────────┘
```
