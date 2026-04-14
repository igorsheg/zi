# Priming Prompt: Stabilize Extension Tool Precedence / Override Semantics

We need to stabilize zi’s extension system by fixing **tool precedence and override behavior** first.

## Context

zi’s doctrine is that **pi-mono is the product spec**. Our extension docs currently claim:

- built-in tools go through the same registration model as extension tools
- precedence is `explicit > user > project > builtin`
- collision semantics are first-registered-wins
- a user extension can override a built-in tool by registering the same name first

But the current implementation appears to drift: built-ins are constructed separately and then merged before Lua tools, so built-ins may still win at execution time even when docs say a user extension should override them.

This is a contract bug, not just a documentation issue.

## Goal

Make tool precedence **truthful, deterministic, and aligned with the declared product contract**.

Prefer fixing the implementation to match the intended extension model, not watering down the docs unless absolutely necessary.

## Read first

Read these fully before changing code:

- `docs/extensions.md`
- `src/coding_agent.zig`
- `src/extensions/loader.zig`
- `src/extensions/registries/tool_registry.zig`
- `src/tools/definition.zig`
- `src/tools/builtins.zig`

Reference pi-mono locally for intended behavior/patterns:

- `.references/pi-mono/packages/coding-agent/examples/extensions/tool-override.ts`
- `.references/pi-mono/packages/coding-agent/src/core/extensions/loader.ts`
- `.references/pi-mono/packages/coding-agent/src/core/extensions/runner.ts`

## Task

Trace the current tool assembly path end-to-end:

1. how built-ins are created
2. how Lua tools are registered
3. how final `AgentTool[]` is assembled
4. how tool lookup/execution resolves collisions

Then implement the smallest clean fix that makes runtime behavior match the contract.

## Requirements

- Final effective precedence must be deterministic.
- A user/project/explicit extension that overrides a built-in tool by name must actually win at execution time.
- Prompt metadata (`prompt_snippet`, guidelines, tool list) must reflect the same winning tool set.
- `tool_allowlist` behavior must still work correctly after the fix.
- Do not introduce compatibility theater or dual truth.
- Keep architecture clean; don’t hack around with special-case post-filters if a real precedence fix is cleaner.

## Acceptance criteria

- If an extension registers a tool named `read`, that tool can truly override built-in `read`.
- The executed tool implementation matches the winner according to precedence.
- The final tool list used by the agent, prompt builder, and filtering logic is consistent.
- Collision handling remains deterministic and diagnosable.
- Discovery/merge order should not leave ambiguous “doc says X, runtime does Y” behavior.

## Testing doctrine

Add only a few boundary tests, max 3–5. Favor behavior over internals.

Good candidates:

1. `test "user extension overrides builtin tool at execution time"`
2. `test "final prompt metadata comes from the winning tool definition"`
3. `test "tool allowlist filters the post-precedence tool set"`

If helpful, use a seeded fake tool definition instead of broad integration spray.

## Non-goals for this session

Do **not** expand the extension API surface.
Do **not** tackle event payload parity yet.
Do **not** rewrite the whole extension system.

This session is only about making tool precedence and override semantics solid.

## Deliverable

At the end, summarize:

- previous behavior
- root cause
- chosen precedence model
- files changed
- tests added
- any follow-up issues discovered
