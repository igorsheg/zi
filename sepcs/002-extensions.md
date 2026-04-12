# Priming Prompt: Stabilize Extension Event Payload Parity

We need to stabilize zi’s extension system by fixing **event payload parity** against pi-mono.

## Context

zi’s doctrine is that **pi-mono is the product spec**. Our extension system currently has the right broad architecture, but several extension events still drift from pi-mono at the **observable contract** layer:

- payload fields are thinner than pi-mono
- some field names drift (`args` vs `input`)
- some events are only partially surfaced
- docs, runtime, and pi-mono behavior are not yet fully aligned

This session is about making the **core event surface truthful and parity-grade**, not about adding new extension features.

## Goal

Make zi’s implemented extension events match pi-mono’s **observable event contract** as closely as possible for the current v1-supported event set.

That means:
- same event names
- same payload field names
- same payload structure
- same ordering expectations where relevant
- no misleading partial payloads when parity is expected

Prefer fixing implementation toward pi-mono behavior, not redefining the product surface around current drift.

## Read first

Read these fully before changing code:

- `docs/extensions.md`
- `src/extensions/event_bridge.zig`
- `src/extensions/dispatch.zig`
- `src/extensions/api.zig`
- `src/extensions/context.zig`
- `src/agent/protocol.zig`
- `src/agent/loop.zig`
- `src/coding_agent.zig`

Reference pi-mono locally for exact behavior and payload shapes:

- `.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts`
- `.references/pi-mono/packages/coding-agent/src/core/extensions/runner.ts`
- `.references/pi-mono/packages/coding-agent/src/core/extensions/loader.ts`

If needed, also trace where pi-mono emits or transforms these events in the coding-agent and agent layers.

## Task

Trace the currently implemented extension event set end-to-end:

1. where the event originates in zi
2. how zi translates it into Lua-visible payloads
3. what the current Lua-visible shape is
4. what the equivalent pi-mono shape is
5. what drift remains

Then implement the smallest clean fix that makes zi’s current supported event payloads match pi-mono’s observable contract.

## Scope for this session

Focus on the currently implemented/supported event surface first:

- `message_start`
- `message_update`
- `message_end`
- `tool_execution_start`
- `tool_execution_update`
- `tool_execution_end`
- `tool_call`
- `tool_result`
- `session_start`
- `session_shutdown`
- `model_select`

You do **not** need to land all future/deferred extension events in this session.

## Requirements

- Public Lua-visible payloads should use pi-mono-compatible names and shapes.
- If pi-mono exposes `input`, zi should expose `input`, not a zi-only drift like `args`.
- Cancellable and transformable event semantics must remain correct while aligning payload shape.
- Do not fake parity by renaming docs only; runtime behavior must match.
- Do not introduce partial duplicated payload conventions unless there is a strong compatibility reason.
- Keep changes localized and architectural seams clean.

## Acceptance criteria

- Core implemented events have Lua-visible payloads that match pi-mono’s expected field names and structure.
- `tool_call` and `tool_result` use pi-mono-compatible payload conventions.
- Event consumers in zi use one coherent event contract, not mixed `args`/`input` drift.
- Session and model events that are publicly supported are surfaced with truthful payloads.
- Docs no longer imply one payload shape while runtime emits another.

## Testing doctrine

Add only a few high-value boundary/conformance tests, max 3–5.

Good candidates:

1. `test "tool_call payload matches pi-mono field names and mutation semantics"`
2. `test "tool_result transform sees and returns pi-mono-compatible payload shape"`
3. `test "message and tool execution observer events expose full expected payload fields"`
4. `test "session_start and model_select emit truthful payloads when supported"`

Prefer behavior checks over implementation details.

## Non-goals for this session

Do **not** broaden the extension API surface.
Do **not** add commands, shortcuts, provider registration, or new UI APIs.
Do **not** rewrite the full extension runtime.
Do **not** tackle deferred events outside the currently supported set unless required for coherence.

This session is only about making the current extension event payload contract solid.

## Deliverable

At the end, summarize:

- previous payload drift
- pi-mono reference behavior traced
- events fixed
- field/name changes made
- tests added
- any follow-up payload/event gaps still remaining
