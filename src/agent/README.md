# agent

Stateful agent loop and SDK surface.

This directory should be implemented by reading the live reference package, not by copying this note:

- `.references/pi-mono/packages/agent/src/`
- `.references/pi-mono/packages/agent/test/`
- `.references/pi-mono/packages/ai/src/` for the lower LLM boundary

This README is a signpost only. If code and this file disagree, trust the code and the pi-mono reference, then update or delete this file.

## implementation rule

Before adding an agent state field, event, queue, tool phase, or SDK API:

1. inspect the matching pi-mono source and tests
2. identify the contract being ported
3. encode the Zig ownership/allocation/error shape
4. add tests for the observed contract

## sdk constraint

`agent` is intended to be embeddable by other Zig projects. That means the CLI may depend on `agent`, but `agent` must not depend on CLI policy. Keep process I/O, filesystem policy, terminal UI, and app-specific tools outside the core unless they are injected through explicit boundaries.

Do not fossilize detailed event order or tool semantics here before the Zig implementation and tests exist.
