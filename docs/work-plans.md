---
slug: work-plans
title: Work plans
order: 78
---

# Work plans

Zi keeps one work plan for each agent session. The plan is a concise ordered checklist for non-trivial work, not a background job queue or project backlog.

The model updates it with the built-in `update_plan` tool. Each call replaces the complete plan and may include a short explanation. A step has one status:

- `pending`
- `in_progress`
- `completed`
- `cancelled`

At most one step may be `in_progress`. Zi asks the model to mark work complete only after verification and to cancel steps that become obsolete. Replacing the plan with an empty `steps` array clears it.

## Persistence and limits

Plan replacements are appended to the session journal and restored when the session resumes, including when the latest plan predates compacted conversation history.

A plan is bounded to 32 steps. Each trimmed, non-empty step is at most 512 UTF-8 bytes, all step text is at most 16 KiB, and the optional explanation is at most 4 KiB.

## Terminal presentation

The interactive terminal shows incomplete steps immediately above the composer. Completed and cancelled steps are omitted. The panel uses at most eight rows, reserves its last row for an omission count when needed, and hides automatically when no incomplete work remains. There is no separate toggle or editable checklist input.

## Code Mode and RPC

`update_plan` is also available inside [Code Mode](code-mode.md):

```js
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

RPC `ready` and `session.get_state` projections include `workPlan`. Replacements emit a `work_plan_changed` session event and an `entry_appended` event for the durable `work_plan` journal entry. See [RPC](rpc.md).
