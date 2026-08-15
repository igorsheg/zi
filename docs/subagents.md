---
slug: subagents
title: Delegate with subagents
order: 90
---

# Delegate with subagents

You have a task with two or three independent lanes: map the storage layer while another lane implements a CLI change, then reconcile the two. Run all of it in one conversation and each lane's reading becomes the other lane's context.

Zi runs a lane in a child session that has its own transcript, model, and thinking level, and returns bounded evidence to the parent rather than the child's whole conversation.

Profiles come from Markdown resources or from programmatic extension registration. Both declaration paths produce the same session-owned profile catalog and activate the same standard model-facing tools. The parent `AgentSession` owns profile precedence, model and thinking resolution, and orchestration policy; its subagent supervisor owns child-session admission, durable evidence, and shutdown.

## Your first delegation

Put a profile in your global `subagents` directory:

```md
---
description: Find relevant implementation and tests
model: openai-codex/gpt-5.3-codex-spark
thinking: minimal
---

Inspect only the requested area. Return concrete file paths and concise findings.
```

Saved as `pathfinder.md`, this declares profile `pathfinder`. To hand it a lane, `spawn_subagent` selects that profile and supplies a separate unique runtime name.

A profile is reusable behavior configuration; a runtime name is a parent-session-unique routing identity. Use the runtime name—not the profile name—for every later operation. Runtime names remain reserved after close.

## Four rules to know first

- At most four children are live per parent, and at most two work cycles run at once. Extra admitted cycles wait in explicit FIFO order, bounding simultaneous model and executable work without discarding reusable child conversations.
- Idle and queued children still consume a live slot. Close children that will not be reused; a finished lane left open is what leaves you without capacity for the next one.
- Subagent completion never wakes the parent model automatically. A child that finishes mid-turn cannot inject itself into unrelated work, so its evidence waits for the parent's next model request.
- `wait_subagents` is a bounded receive, not an all-child barrier and not the delivery mechanism. Treat it as a barrier and you block on lanes you never meant to wait for; treat it as delivery and you poll for evidence that arrives anyway.

## Profile contract

A subagent profile contains:

- `name`: 1–64 bytes, beginning with `a-z` and containing only lowercase ASCII letters, numbers, `_`, or `-`;
- `description`: non-blank human- and model-facing purpose of at most 4 KiB;
- `instructions`: non-blank instructions of at most 8 KiB, prepended to the delegated task;
- `model`: optional non-blank `provider/model-id` selection of at most 4 KiB;
- `thinking`: optional `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`.

Omitted model and thinking values inherit the parent's current selection. An unavailable explicit model fails with profile source attribution; Zi does not silently fall back. Children also inherit the parent's invocation-only `--code-only` tool surface when it is active.

Profiles do not claim permissions, read-only behavior, worktrees, tool restrictions, budgets, or filesystem isolation. Child sessions and their executable tools retain the current user's authority unless an enforceable mechanism says otherwise.

## Markdown declaration

Global profiles load from:

```text
$HOME/.zi/agent/subagents/*.md
```

Trusted project profiles load from:

```text
<cwd>/.zi/subagents/*.md
```

The filename supplies the profile name. One valid admitted profile is sufficient to activate the standard tools after startup or `/reload`. Start from the copyable [`examples/subagents/pathfinder.md`](../examples/subagents/pathfinder.md) profile when creating one with Zi.

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

The profile parameter includes bounded purpose summaries for the admitted catalog, so normal selection does not require a preliminary tool call. `list_subagent_profiles` remains available when the full structured catalog is useful. The selected profile's instructions are prepended to the task, and its model and thinking selection are applied before the session-owned supervisor admits the child. Each parent may own at most four live children while the supervisor starts at most two work cycles concurrently.

`send_subagent_message` delivers context without assigning work and never starts an idle turn. `assign_subagent_task` starts a work cycle when idle or delivers the task to the active cycle. If the task must be a separate cycle, wait for the child to become idle before assigning it. Their successful model-facing results are concise text; typed semantic details remain authoritative for client presentation.

These names replace the ambiguous former `send_subagent` and `continue_subagent` names. Zi still renders persisted rows that used the former names, but does not advertise duplicate callable aliases.

`wait_subagents` is a bounded receive operation, not an all-child barrier or the completion-delivery mechanism. It accepts 1–16 explicit runtime names and captures each name's oldest pending completion, if one exists; otherwise it captures the current work cycle. The call returns when any captured cycle completes and coalesces every other captured completion ready at that instant.

Its result contains those completions, the names still pending, and whether the observation timed out. Pending children keep running, which lets the parent use an early result before waiting again for the remaining work.

Omitting `names` captures once, when the call begins, up to 16 children that are working or have a pending completion; later changes do not join that receive. If none qualify, the call returns immediately with an empty, non-timeout result. A timeout returns no completion, marks nothing delivered, and never cancels child work.

The extension API retains its explicit-name all-target wait for custom orchestration that needs a barrier. Its captured-set, timeout, and independent child-lifetime rules remain the same.

The standard model-facing flow admits each durable `{runtime name, work cycle}` to parent context automatically at most once: through a wait or terminal lifecycle tool result when captured there, otherwise as bounded hidden context before the next parent model request.

A model-facing operation claims its exact cycle while its tool result is in flight. Zi records delivery only after that parent message is durable and releases the claim if the parent turn is cancelled or fails. Nested Code Mode calls release their observations after the outer `code` result commits, leaving hidden context as the canonical automatic delivery. Hidden delivery is likewise acknowledged only after its custom context message is durable.

Restoration recognizes both evidence forms, including evidence compacted out of the exact active tail, so it neither loses nor reinjects an older result. Interrupt and close operations may inspect already-delivered terminal evidence again without causing another automatic injection; mailbox receives observe only newly deliverable completions.

`list_subagents` reports a bounded current-task summary, lifecycle, work cycle, elapsed milliseconds, and result-ready status without copying conversations. `interrupt_subagent` waits within the supervisor's bound for terminal evidence from the exact interrupted cycle and returns that evidence directly. `close_subagent` likewise returns the child's bounded terminal evidence. Neither successful operation requires a follow-up wait.

## Inspecting transcripts

In the terminal client, `/agent` lists running subagents by default and opens the selected child's bounded transcript in a read-only companion pane. Press `Tab` in the picker to switch between running subagents and all retained subagents; the picker title and footer show the active scope and the available toggle. Selecting another child retargets the companion. The pane uses the same message and tool presentation as the primary transcript; it does not create another child session or copy transcript state into the TUI.

Press `Ctrl+W`, then `h/j/k/l` to move between panes. `Esc` returns from the companion to the primary composer, and `q` closes the active read-only pane. On narrow terminals, Zi keeps the same workspace topology but shows only the active pane. Closing or hiding a pane never interrupts or closes its subagent.

Live child events provide streaming updates. After a work cycle settles, Zi independently refreshes at most the newest 200 authoritative messages and retains at most 8 MiB per child transcript. Exited transcripts share a 16 MiB retained bound.

A child recovered from journal evidence after restart has no fabricated transcript and cannot be opened unless live transcript evidence is available.

## Peer messaging

Depth-one child sessions expose two narrow collaboration tools:

- `list_peer_subagents` lists the other live children owned by the same parent session;
- `send_peer_message` sends context to one live sibling through the parent-owned relay.

Peer runtime names remain scoped to their common parent. A direct parent-owned relay captures the sender when the child session is constructed, validates the target against the authoritative live-child catalog, and serializes delivery through the target child. There is no peer RPC framing or process identity for a child to supply, so sender identity remains unforgeable.

Peer delivery is queue-only. It joins active sibling work through the same safe follow-up path as `send_subagent_message`, but never starts an idle sibling turn. The receiving child sees an attributed `[Peer message from <runtime-name>]` envelope. Final work-cycle evidence continues to flow to the parent; peer messages do not replace parent completion delivery.

A peer message retains at most 64 KiB, each child may have at most eight direct relay operations pending, and the parent exposes at most its four live-child slots. Cancellation stops the sender from waiting but does not retract a direct relay call already admitted; delivery may still complete.

## Optional custom orchestration

Extensions may provide specialized tools or workflows over the same substrate. `zi.subagents` exists only when the runtime can create child sessions and provides bounded operations for profile listing, spawn, send, continue, wait, list, interrupt, and close.

`send(...)` has the same context-only, never-wake semantics as `send_subagent_message`; `continue(...)` has the task-assignment semantics of `assign_subagent_task`. `interrupt(...)` returns `{ result, snapshot }`, where the snapshot contains terminal evidence for the exact affected cycle, and `close(...)` returns the corresponding terminal snapshot.

Runtime names follow the profile-name syntax, prompt and message inputs retain at most 8 MiB, waits accept 1–16 unique names and at most one hour, and result projections are bounded. A wait started by an extension command or tool must fit that invocation's remaining deadline and is cancelled when its owner is cancelled or settles.

Custom orchestration is optional; it is not required to use Markdown or programmatically registered profiles. Extension reload may replace programmatic registrations and custom tools without terminating already admitted children.

## Lifetime and safety

The parent supervisor owns in-process, depth-one child `AgentSession` lifetimes. It admits at most four live children, starts at most two work cycles, and starts queued cycles in FIFO order whenever a running cycle settles or is cancelled.

Each child independently owns its conversation, ephemeral session manager, session shell, Code Mode runtime, and extension host with its workers. The parent runtime shares admitted configuration, models, credentials, resources, worker commands, and one process tracker with those sessions; a child borrows that tracker and cannot dispose the parent runtime or tracker when it closes.

A child session itself is in process, but executable work is not collapsed into the parent. Extension handlers run in child-scoped extension workers, Code Mode runs in its programmatic worker, and shell commands retain process-group and process-tree containment. Parent shutdown first settles child-session owners, then disposes the shared process tracker so descendant executable work cannot outlive the runtime.

Each settled work cycle records one model-invisible `subagent_work_result` keyed by its runtime name and work-cycle number. It retains the selected profile when available, result, duration, omission facts, and a stable failure code. Spawn, send, assignment, interrupt, and close are control operations; they do not become journal records. Hidden completion context and orchestration tool results deliver work-cycle evidence without creating another result.

A parent retains at most 32 completed cycles; new work is refused rather than evicting undelivered evidence. Completion output is clipped to 50 KiB, durable previews to 8 KiB, listed task summaries to 256 bytes, and shutdown settlement to a fixed bound.

Each accepted initial spawn prompt and accepted task assigned to an idle child reserves a separately bounded work cycle using `subagentWorkTimeoutMs`. A queued cycle's deadline starts only when FIFO admission moves it to running, so time spent waiting behind the two-running bound does not consume its work budget. Assignments made while the child is queued or running join that same cycle and do not reset its deadline.

When a cycle settles, the child owner folds the latest typed assistant message into one bounded completion. An aborted message is cancellation, provider error is failure, and a tool-use or pending assistant without a final answer is incomplete; completion does not depend on an RPC idle projection.

Lifecycle settlement never waits on transcript presentation. The live projection keeps a bounded array of references to authoritative child-session messages plus streaming and active-tool facts; it neither pages a child transport nor copies message text into another timeline.

When work expires, the child owner interrupts it, waits within a separate settlement bound, records `work_cycle_timeout` evidence, and keeps a successfully settled child reusable. Requested interruption has its own bounded settlement deadline; a child that acknowledges interruption but never becomes idle is force-cleaned with durable `interrupt_settlement_timeout` evidence. This work deadline is independent of `wait_subagents`: observation timeouts never cancel child work.

Delivery follows the parent's own turn boundary. If the parent still has an active turn, the completion joins its next model request; otherwise it remains durable until a user or external client starts another turn. `wait_subagents` can synchronize active work, but completion delivery does not depend on polling. Standard calls have concise semantic tool rows and expandable completion evidence, while the bounded hidden completion context adds no separate transcript message, subagent rail, or notification channel.

## What this does not do

- A session with no admitted profiles exposes none of these parent orchestration tools.
- Depth-one child sessions cannot recursively create subagents, so a fan-out stays one level wide.
- Extensions never receive `SubagentSupervisor`, child-session owners, or process handles.
- A child cannot claim another sender, message itself, address an exited child, or acquire spawn, interrupt, close, wait, or process authority through the peer channel.
- Once the child emits a relay request, cancellation stops the sender from waiting but does not retract that request; delivery may still complete.
- Profiles do not enforce permissions. Child sessions, extension workers, Code Mode, and shell commands are not security sandboxes.
- Child sessions are not persistent; only their bounded evidence reaches the parent journal.
- A child recovered from journal evidence after restart has no fabricated transcript and cannot be opened unless live transcript evidence is available.
