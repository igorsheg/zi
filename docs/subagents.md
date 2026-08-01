# Subagents

Zi can delegate independent work to native background subagents. A subagent is a direct child Zi session with its own conversation and tools. The parent model decides when to delegate, gives each child a task, collects the results, and synthesizes the answer you see.

Native subagents are currently development functionality. The implementation exists, but release support still depends on the compiled acceptance and process-containment gates tracked in the [roadmap](roadmap.md#in-progress--native-subagents).

## When delegation helps

Good uses have a clean boundary and can proceed independently:

- inspect separate packages or subsystems in parallel;
- compare two implementation approaches;
- ask one child to investigate code while another checks tests or documentation;
- isolate a context-heavy audit from the parent's main conversation;
- independently verify a conclusion before the parent changes code.

Keep work in the parent when it is trivial, sequential, or tightly coupled:

- reading one small file;
- making one localized edit;
- repeatedly changing the same files;
- work that depends on unstated details from the parent conversation;
- operations where concurrent writers could conflict.

Zi does not provide subagent roles, worktrees, reduced permissions, or merge coordination. A name such as `reviewer` is the child's unique identity, but it does not make the child read-only.

## Ask for delegation

You normally describe the outcome rather than call subagent tools yourself:

```text
Audit retry behavior. Delegate two independent read-only reviews:
- one child should inspect retry policy and tests;
- one child should inspect TUI status and documentation.
Give each child a self-contained task, wait for both, synthesize the findings
with file paths, and close the children when finished.
```

You can also leave the choice to Zi:

```text
Investigate this failure. Delegate independent or context-heavy parts when that
will improve the result, but keep trivial work in the parent.
```

The transcript shows semantic rows such as `Started Retry reviewer` and `Finished waiting`. The composer rail reports agents working and results ready. `Ctrl+O` expands tool details, including lifecycle and completion metadata.

## Make child tasks self-contained

A child does **not** inherit the parent's conversation. It receives normal project instructions and resources discovered for its own Zi process, plus the task the parent sends. A useful delegated prompt therefore includes:

1. the exact question or deliverable;
2. relevant paths and known constraints;
3. whether edits are allowed;
4. verification expected before completion;
5. the desired answer shape.

For example:

```text
Inspect packages/coding-agent/src/retry.ts and its tests. Do not edit files.
Identify retry admission, bounds, and cancellation behavior. Return at most five
findings, each with a file path and supporting evidence. Distinguish confirmed
behavior from inference.
```

Avoid prompts such as `check the approach we discussed` or `fix the other issue`; the child cannot see what “discussed” or “other” means unless the parent restates it.

## Shared authority and conflicting edits

Subagents are process-isolated for fault containment, not sandboxed. They run as the same user and can access the same:

- working directory and files;
- credentials admitted by normal Zi/provider policy;
- network;
- independently admitted project resources and extensions.

Concurrent children can edit the same working tree. Zi has no transaction, automatic worktree, conflict prevention, or merge policy for them. Prefer one of these patterns:

- parallel read-only research, followed by one parent writer;
- disjoint file ownership stated explicitly in every child prompt;
- sequential delegation when later work depends on earlier edits.

Before delegating in a sensitive repository, assume each child has the same practical authority as the parent. Do not rely on labels such as `reviewer` or prose such as “read-only” as an enforced permission boundary.

## Models, context, and cost

A child starts with the parent's selected model and thinking level. It has a separate conversation and provider requests, so delegation can multiply token use, latency, and provider cost. Four live children can mean four concurrent consumers in addition to the parent.

Use delegation when parallelism or context isolation justifies that cost. Ask for bounded outputs, avoid spawning multiple children for the same question, and close children that will not be reused. Zi currently has no per-subagent budget or cheaper-child model selector.

## Collecting results

Spawning transfers the task to background ownership. The parent must wait for or later collect the completion before it can use the full result.

Completion does not automatically start another parent turn. If the rail says a result is ready after Zi has stopped responding, prompt it directly:

```text
Collect all ready subagent results, report any failures, synthesize the answer,
and close children that are no longer needed.
```

A collected completion includes status, final child text, duration, and truncation facts. One wait result has a 64 KiB aggregate model-facing bound with explicit omission metadata. Internal work-cycle and delivery bookkeeping stays out of that result. Each requested child returns either its captured completion or its current status, never a previous completion beside newer running work. The compact transcript shows a bounded summary; `Ctrl+O` reveals the retained completion evidence without copying the full child conversation. The parent should cite and synthesize the evidence instead of merely saying that a child finished.

`wait_subagents` addresses children by name. It captures each requested child's current work cycle and, by default, waits for every captured cycle rather than returning after the first completion. A wait is still bounded: on timeout, a returned child may still be working and `all_completed` is false. That is not cancellation or failure; ask Zi to wait again when the result is still needed.

## Interruption and cleanup

Parent interruption and child interruption are intentionally different:

- pressing `Escape` stops the active parent run but does not cancel already admitted background children;
- asking Zi to interrupt a child stops its current work while preserving the child process for reuse;
- sending a child information never starts a turn, while continuing an idle child assigns work and starts another turn;
- closing a child ends its process, releases one live-child slot, and reports the pre-close lifecycle as `previous_status` plus bounded `previous_completion` state when present;
- ending or replacing the owning session closes its live children;
- `/reload` does not stop or reconfigure live children.

Useful control prompts are:

```text
List active subagents and summarize their states.
Interrupt the release-auditor, collect its cancellation result, then close it.
Close every idle subagent; do not start new work.
```

If a child fails, ask the parent to collect the result and include the failure reason. An unexpected child exit is reported as a failed completion rather than silently retried.

## Limits and lifecycle

| Behavior                  | Current limit or rule                                 |
| ------------------------- | ----------------------------------------------------- |
| Live direct children      | 4 per parent session                                  |
| Nesting                   | Direct children only; children cannot spawn subagents |
| Names in one wait         | 16                                                    |
| One blocking wait         | Configured default 30 seconds; hard maximum one hour  |
| Model-visible completion  | 50 KiB per work cycle; 64 KiB aggregate per wait      |
| Child names               | Unique for the complete parent session                |
| Child conversation resume | Not supported after parent restart                    |
| Parent interruption       | Does not cancel admitted children                     |
| Parent session disposal   | Closes all live children                              |

A closed child's name remains reserved for that parent session. Choose short, specific names such as `retry-tests` or `docs-audit`, not generic names that are likely to be needed again.

## Configure or disable subagents

Subagents are enabled by default. A wait that omits `timeout_ms` uses `subagentWaitTimeoutMs`, which defaults to 30 seconds and accepts bounded integer values through one hour. An explicit tool argument may also request any timeout through that hard maximum.

Configure admitted global or project settings, for example:

```json
{ "subagentsEnabled": true, "subagentWaitTimeoutMs": 180000 }
```

Set `subagentsEnabled` to `false` to disable the complete native tool set. These settings are applied when the session runtime is constructed. Start a new session or restart Zi after changing them; `/reload` does not reconfigure an already-owned subagent supervisor.

## Examples of good and bad delegation

**Good:** “Have one child inspect shutdown ownership and another inspect process-containment tests. Both are read-only. Wait, compare their evidence, then return prioritized gaps.”

**Bad:** “Spawn four agents to fix this typo.” The task is trivial and the coordination costs more than the work.

**Good:** “Let one child research the provider API while the parent edits a disjoint documentation file.” The ownership boundary is explicit.

**Bad:** “Have three agents refactor the same module.” They share one working tree and can overwrite or invalidate each other's changes.

For repeatable product evaluation against real models, use the [subagent evaluation rubric](subagents-evaluation.md).
