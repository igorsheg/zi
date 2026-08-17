# Integrate AgentTeam runtime invariants

## Intent

The recursive AgentTeam refactor removed the retired supervisor invariant without adding the root-scoped replacement specified by the control-plane design. Restore diagnostics only for relationships that cross AgentTeam runtime ownership and durable target admission; keep journal validation, bounds, idempotency, and shutdown guarantees unconditional.

A reproduced race currently lets `shutdown()` close while `spawn()` is awaiting fork creation. The spawn can then commit a durable unloaded record after closure. Fix that production transition before relying on diagnostics.

## Program design

```text
createAgentSessionWithProcessTreeTracker
  create root InvariantRegistry
  AgentTeam.create(..., invariantRegistry)
    recover durable journal
    install one AgentTeamInvariant
  AgentSession.dispose
    start AgentTeam.shutdown
      stop admissions
      settle or bound outstanding spawn operations
      dispose resident owners
      verify successful terminal cleanup
    dispose invariant registry after owned resources settle
```

```diff
 packages/coding-agent/src/agent-team/
+├── invariant.ts                 # owner-local admission and terminal-cleanup diagnostics
~├── agent-team.ts                # spawn/shutdown synchronization and observations
 packages/coding-agent/test/
+├── agent-team-invariant.test.ts # valid, invalid, disabled, and terminal traces
~├── agent-team.test.ts           # spawn cannot publish after shutdown
~├── agent-session.ts             # registry remains alive through resource settlement
~└── sdk.ts                       # root registry injection only
```

`AgentTeamInvariant` is registered once as `@with-zi/coding-agent/agent-team`. Member sessions borrow the team and do not register another instance.

The invariant checks:

- a turn, ordinary mail, or completion admission returns a target entry representing the exact stable input and requested publication;
- a proposed root-journal acknowledgement uses the target entry returned by that admission;
- successful shutdown retains no spawn reservation, active spawn operation, resident/loading owner, active turn deadline or settlement, or transcript lease.

It does not revalidate graph lineage, journal JSON, durable turn monotonicity, uniqueness, capacity, or idempotency. It adds no journal events and does not eagerly open restored child journals.

## Vertical slices

1. Add a public-behavior regression test that starts a persistent spawn, immediately shuts down, and proves no record can appear after shutdown. Make shutdown synchronize with or reject the outstanding spawn and keep failed terminal state honest.
2. Add the owner-local invariant with direct trace tests, then wire target admissions immediately before their root-journal commits.
3. Keep the root registry alive until team and shell settlement, add terminal cleanup observation, and run coding-agent plus repository checks.

## Acceptance

- No committed agent record appears after AgentTeam reaches `closed`.
- Successful shutdown has no retained AgentTeam runtime work.
- Target admission and acknowledgement mismatch raises an attributed `InvariantError` before the root acknowledgement append.
- Disabling invariants preserves behavior.
- Existing durable replay, recursive routing, restoration, and bounded shutdown tests remain green.
