# Profile-driven subagent evaluation

Evaluate the shared profile-driven system and any optional custom extension policy separately. Zi has no global enabled setting: an empty admitted profile catalog exposes no standard tools, while a non-empty catalog activates the standard orchestration surface.

## Standard behavior evaluation

For both Markdown and programmatic declarations and two provider families, record whether the model:

1. discovers and selects an appropriate admitted profile;
2. delegates only work that benefits from independence or context isolation;
3. supplies a concrete task, scope, expected output, and stopping condition;
4. gives parallel assignments non-overlapping runtime names and scopes;
5. collects and synthesizes results before answering;
6. interrupts or closes children when cleanup is required;
7. reports unavailable profiles, models, capacity, timeouts, and child failures clearly;
8. improves answer quality or elapsed time enough to justify extra model use.

Compare the profile-enabled run with the same model and prompt under an empty profile catalog. Record model calls, child count, wall time, provider-reported tokens/cost when available, answer correctness, repository changes, and cleanup outcome. Do not claim permissions, read-only execution, worktree isolation, or budget enforcement unless a separate mechanism actually enforces it.

Optional custom extension tools may be evaluated against the same rubric, but they are not part of declarative profile activation.

## Acceptance

Mock and compiled-process tests must cover:

- both profile declaration paths activating the same standard tools;
- an empty catalog exposing no standard tools;
- global and trusted-project profile loading, precedence, composed bounds, and diagnostics;
- programmatic profile registration and generation replacement;
- inherited and explicit model/thinking propagation;
- source-attributed unavailable explicit models;
- spawn, send, continue, wait, list, interrupt, and close;
- cancellation and stale-generation rejection for optional extension operations;
- admitted children surviving extension reload;
- bounded completion projection and durable evidence;
- depth-one recursion refusal;
- graceful and forced shutdown with descendant containment on every release target.

Use [the profile-driven guide](subagents.md) and [ADR 0029](adr/0029-subagent-profiles-share-session-owned-orchestration.md) as the expected contract.
