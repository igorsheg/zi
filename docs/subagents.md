---
slug: subagents
title: Delegate with subagents
order: 80
---

# Profile-driven subagents

Zi admits subagent profiles from Markdown resources and programmatic extension registration. Both declaration paths produce the same session-owned profile catalog and activate the same standard model-facing tools. The parent `AgentSession` owns profile precedence, model and thinking resolution, orchestration tools, child-process mechanics, durable evidence, and shutdown.

## Profile contract

A subagent profile contains:

- `name`: 1–64 bytes, beginning with `a-z` and containing only lowercase ASCII letters, numbers, `_`, or `-`;
- `description`: non-blank human- and model-facing purpose of at most 4 KiB;
- `instructions`: non-blank instructions of at most 8 KiB, prepended to the delegated task;
- `model`: optional non-blank `provider/model-id` selection of at most 4 KiB;
- `thinking`: optional `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`.

Omitted model and thinking values inherit the parent's current selection. An unavailable explicit model fails with profile source attribution; Zi does not silently fall back. Children also inherit the parent's invocation-only `--code-only` tool surface when it is active.

Profiles do not claim permissions, read-only behavior, worktrees, tool restrictions, budgets, or filesystem isolation. Child Zi processes retain the current user's authority unless a future enforceable mechanism says otherwise.

## Markdown declaration

Global profiles load from:

```text
$HOME/.zi/agent/subagents/*.md
```

Trusted project profiles load from:

```text
<cwd>/.zi/subagents/*.md
```

The filename supplies the profile name:

```md
---
description: Find relevant implementation and tests
model: openai-codex/gpt-5.3-codex-spark
thinking: minimal
---

Inspect only the requested area. Return concrete file paths and concise findings.
```

Saved as `pathfinder.md`, this declares profile `pathfinder`. One valid admitted profile is sufficient to activate the standard tools after startup or `/reload`. Start from the copyable [`examples/subagents/pathfinder.md`](../examples/subagents/pathfinder.md) profile when creating one with Zi.

## Programmatic declaration

Extensions declare the same profile shape:

```ts
import type { ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
  zi.registerSubagentProfile({
    name: "pathfinder",
    description: "Find relevant implementation and tests",
    instructions: "Inspect only the requested area and return concrete evidence.",
    model: "openai-codex/gpt-5.3-codex-spark",
    thinking: "minimal"
  })
}
```

This registration alone activates the same standard tools as the Markdown declaration. It does not require a second extension tool.

Profile precedence is:

1. trusted project Markdown;
2. global Markdown;
3. extension registration.

Resource loading and one extension generation each retain at most 64 profiles, so the composed catalog remains bounded at 128 before same-name precedence removes collisions.

## Standard tools

A non-empty catalog activates:

- `list_subagent_profiles`;
- `spawn_subagent`;
- `send_subagent_message`;
- `assign_subagent_task`;
- `wait_subagents`;
- `list_subagents`;
- `interrupt_subagent`;
- `close_subagent`.

`spawn_subagent` selects a profile and supplies a separate unique runtime name. A profile is reusable behavior configuration; a runtime name is a parent-session-unique routing identity. Use the runtime name—not the profile name—for every later operation. Runtime names remain reserved after close.

The profile parameter includes bounded purpose summaries for the admitted catalog, so normal selection does not require a preliminary tool call. `list_subagent_profiles` remains available when the full structured catalog is useful. The selected profile's instructions are prepended to the task, and its model and thinking selection are applied before the session-owned supervisor admits the child. Each parent may own at most four live children. Idle children still consume a slot; close children that will not be reused to free capacity.

`send_subagent_message` delivers context without assigning work and never starts an idle turn. `assign_subagent_task` starts a work cycle when idle or delivers the task to the active cycle. If the task must be a separate cycle, wait for the child to become idle before assigning it. Their successful model-facing results are concise text; typed semantic details remain authoritative for client presentation. These names replace the ambiguous former `send_subagent` and `continue_subagent` names; Zi still renders persisted rows that used the former names, but does not advertise duplicate callable aliases.

`wait_subagents` is a bounded receive operation, not an all-child barrier or the completion-delivery mechanism. It accepts 1–16 explicit runtime names and captures each name's oldest pending completion, if one exists; otherwise it captures the current work cycle. The call returns when any captured cycle completes and coalesces every other captured completion ready at that instant. Its result contains those completions, the names still pending, and whether the observation timed out; pending children keep running. This lets the parent use an early result before waiting again for the remaining work. Omitting `names` captures once, when the call begins, up to 16 children that are working or have a pending completion; later changes do not join that receive. If none qualify, the call returns immediately with an empty, non-timeout result. A timeout returns no completion, marks nothing delivered, and never cancels child work.

The extension API retains its explicit-name all-target wait for custom orchestration that needs a barrier. Its captured-set, timeout, and independent child-lifetime rules remain the same.

The standard model-facing flow admits each durable `{runtime name, work cycle}` to parent context automatically at most once: through a wait or terminal lifecycle tool result when captured there, otherwise as bounded hidden context before the next parent model request. A model-facing operation claims its exact cycle while its tool result is in flight; Zi records delivery only after that parent message is durable and releases the claim if the parent turn is cancelled or fails. Nested Code Mode calls release their observations after the outer `code` result commits, leaving hidden context as the canonical automatic delivery. Hidden delivery is likewise acknowledged only after its custom context message is durable. Restoration recognizes both evidence forms, including evidence compacted out of the exact active tail, so it neither loses nor reinjects an older result. Interrupt and close operations may inspect already-delivered terminal evidence again without causing another automatic injection; mailbox receives observe only newly deliverable completions.

`list_subagents` reports a bounded current-task summary, lifecycle, work cycle, elapsed milliseconds, and result-ready status without copying conversations. `interrupt_subagent` waits within the supervisor's bound for terminal evidence from the exact interrupted cycle and returns that evidence directly. `close_subagent` likewise returns the child's bounded terminal evidence. Neither successful operation requires a follow-up wait.

A session with no admitted profiles exposes none of these parent orchestration tools. Depth-one child sessions cannot recursively create subagents.

## Inspecting transcripts

In the terminal client, `/agent` lists running subagents by default and opens the selected child's bounded transcript in a read-only companion pane. Press `Tab` in the picker to switch between running subagents and all retained subagents; the picker title and footer show the active scope and the available toggle. Selecting another child retargets the companion. The pane uses the same message and tool presentation as the primary transcript; it does not create another child session or copy transcript state into the TUI.

Press `Ctrl+W`, then `h/j/k/l` to move between panes. `Esc` returns from the companion to the primary composer, and `q` closes the active read-only pane. On narrow terminals, Zi keeps the same workspace topology but shows only the active pane. Closing or hiding a pane never interrupts or closes its subagent.

Live child events provide streaming updates. After a work cycle settles, Zi independently refreshes at most the newest 200 authoritative messages and retains at most 8 MiB per child transcript. Exited transcripts share a 16 MiB retained bound. A child recovered from journal evidence after restart has no fabricated transcript and cannot be opened unless live transcript evidence is available.

## Peer messaging

Depth-one child sessions expose two narrow collaboration tools:

- `list_peer_subagents` lists the other live children owned by the same parent session;
- `send_peer_message` sends context to one live sibling through the parent-owned relay.

Peer runtime names remain scoped to their common parent. The parent derives the sender identity from the child process that issued the request, validates the target against its authoritative live-child catalog, and serializes delivery through the target child. A child cannot claim another sender, message itself, address an exited child, or acquire spawn, interrupt, close, wait, or process-handle authority through this channel.

Peer delivery is queue-only. It joins active sibling work through the same safe follow-up path as `send_subagent_message`, but never starts an idle sibling turn. The receiving child sees an attributed `[Peer message from <runtime-name>]` envelope. Final work-cycle evidence continues to flow to the parent; peer messages do not replace parent completion delivery.

The child-to-parent request and parent-to-child acknowledgement are correlated and bounded. A peer message retains at most 64 KiB, each child may have at most eight peer requests in flight, and the parent exposes at most its four live-child slots. Once the child emits a relay request, cancellation stops the sender from waiting but does not retract that request; delivery may still complete.

## Optional custom orchestration

Extensions may provide specialized tools or workflows over the same substrate. `zi.subagents` exists only when the runtime can create child sessions and provides bounded operations for profile listing, spawn, send, continue, wait, list, interrupt, and close. `send(...)` has the same context-only, never-wake semantics as `send_subagent_message`; `continue(...)` has the task-assignment semantics of `assign_subagent_task`. `interrupt(...)` returns `{ result, snapshot }`, where the snapshot contains terminal evidence for the exact affected cycle, and `close(...)` returns the corresponding terminal snapshot. Runtime names follow the profile-name syntax, prompt and message inputs retain at most 8 MiB, waits accept 1–16 unique names and at most one hour, and result projections are bounded. A wait started by an extension command or tool must fit that invocation's remaining deadline and is cancelled when its owner is cancelled or settles. Custom orchestration is optional; it is not required to use Markdown or programmatically registered profiles.

Extensions never receive `SubagentSupervisor` or child-process handles. Extension reload may replace programmatic registrations and custom tools without terminating already admitted children.

## Lifetime and safety

The parent `AgentSession` owns admitted child processes. Zi enforces child concurrency, runtime names, RPC framing, output retention, cancellation, work and wait bounds, credential and cwd propagation, process-tree containment, durable operation outcomes, and forced cleanup. Each settled work cycle records one model-invisible outcome keyed by its runtime name and work-cycle number, including the selected profile when available, result, duration, omission facts, and a stable failure code. Hidden completion context and orchestration tool results deliver that evidence without creating additional outcomes. A parent owns at most four live children and retains at most 32 completed cycles; new work is refused rather than evicting undelivered evidence. Completion output is clipped to 50 KiB, durable previews to 8 KiB, listed task summaries to 256 bytes, and shutdown settlement to a fixed bound.

Each accepted initial spawn prompt and accepted task assigned to an idle child starts a separately bounded work cycle using `subagentWorkTimeoutMs`. Assignments made while the child is already working join its current cycle and do not reset that deadline. `session.await_idle` is a semantic completion watch rather than an ordinary RPC response deadline. The child gives every admitted prompt in one cycle the same completion ID; the RPC session accumulates the latest assistant completion event and returns one bounded terminal projection with its admission revision when idle. Lifecycle settlement never waits on transcript paging. A separate bounded message-tail refresh may enrich presentation after the child becomes idle, and a newer admission rejects that refresh as stale.

When work expires, the child owner interrupts it, waits within a separate settlement bound, records `work_cycle_timeout` evidence, and keeps a successfully settled child reusable. Requested interruption has its own bounded settlement deadline; a child that acknowledges interruption but never becomes idle is force-cleaned with durable `interrupt_settlement_timeout` evidence. This work deadline is independent of `wait_subagents`: observation timeouts never cancel child work.

Subagent completion never wakes the parent model automatically. If the parent still has an active turn, the completion joins its next model request; otherwise it remains durable until a user or external client starts another turn. `wait_subagents` can synchronize active work, but completion delivery does not depend on polling. Standard calls have concise semantic tool rows and expandable completion evidence, while the bounded hidden completion context adds no separate transcript message, subagent rail, or notification channel.
