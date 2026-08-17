---
slug: work-plans
title: Work plans
order: 65
---

# Work plans

On a long task you want to see what the agent thinks it is doing, and you want to catch it calling work finished that is not.

Zi keeps one work plan for each agent session: a concise ordered checklist for non-trivial work, not a background job queue or project backlog. At most one step may be `in_progress`, so the plan never shows two things in flight at once. Zi asks the model to mark work complete only after verification and to cancel steps that become obsolete.

The model updates the plan with the built-in `update_plan` tool. Each call replaces the complete plan and may include a short explanation. Replacing the plan with an empty `steps` array clears it.

A step has one status:

- `pending`
- `in_progress`
- `completed`
- `cancelled`

## Persistence and limits

Plan replacements are appended to the session [journal](vocabulary.md) and restored when the session resumes, including when the latest plan predates compacted conversation history. A task that outlives its conversation history keeps its checklist.

The bounds keep a plan a checklist rather than a document: at most 32 steps, at most 512 UTF-8 bytes per trimmed non-empty step, at most 16 KiB of step text in total, and at most 4 KiB for the optional explanation.

## Terminal presentation

The interactive terminal shows incomplete plans in the transcript status row:

```text
Working… • Plan (1/4) — Implement status composition       (Ctrl+P)
```

While the root agent is running, the `Working…` shimmer always remains visible. The row then composes detached-transcript attention (`New output`), independent background ownership (`◎ 1 command · 2 agents still running`), and plan progress, in that priority order. Exceptional lifecycle states such as cancellation, retry, and compaction appear beside `Working…` instead of replacing it.

Press `Ctrl+P` to open or close the complete plan in a read-only shelf between the transcript and composer. The composer stays anchored at the bottom while the transcript gives up only the shelf's bounded height. The shelf wraps long steps, keeps the current step in view, and scrolls with the ordinary transcript page, line, and tail controls.

It shows every bounded step:

- `✓` completed
- `◉` in progress
- `○` pending
- `–` cancelled

Press `Esc` to close the shelf and restore composer focus. Completing or clearing the plan closes it automatically.

## Code Mode and RPC

`update_plan` is also available inside [Code Mode](code-mode.md):

```ts
await zi.update_plan({
  explanation: "Implementation started",
  steps: [
    { text: "Inspect the current behavior", status: "completed" },
    { text: "Implement the change", status: "in_progress" },
    { text: "Verify the result", status: "pending" }
  ]
})
```

The call returns the new bounded snapshot, including its revision.

RPC `ready` and `session.get_state` projections include `workPlan`. Replacements emit a `work_plan_changed` session event and an `entry_appended` event for the durable `work_plan` journal entry. See [RPC](rpc.md) for those projections and events in full.
