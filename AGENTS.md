Issue tracking: `bd prime`

## Reference Code

pi-mono is cloned locally at `.references/pi-mono/`. When you need to reference pi-mono source (types, implementations, patterns), always use local reads/greps against `.references/pi-mono/` — never the github tools. The code is on disk.

## Doctrine

zi must never be less capable than pi-mono at the architecture, design, or product layer. minimum bar: parity with pi-mono. maximum bar: extend pi-mono while preserving its contracts. zig is an implementation advantage, not a reason to collapse product surfaces, remove composition seams, or replace dedicated flows with narrower shortcuts.

when a zi surface drifts from pi-mono, default assumption is to close the drift, not defend it. if we simplify, that simplification must still preserve pi-mono-level capability and extensibility.

- no compatibility theater if a bad api blocks the right architecture
- no “quick fix” shim that papers over drift instead of removing it

## Testing Doctrine

**NO test spray.** we do not generate tests per-function. we test behavior at boundaries.

- **max 3-5 tests per task.** if you need more, the task is too big or you're testing implementation.
- **every test name states the behavior it verifies.** `test "session round-trips all 9 entry types"` not `test "parseEntry works"`.
- **no mocks unless crossing a network boundary.** use real modules.
- **conformance fixtures come from pi-mono** (real session files, provider responses, event transcripts). generate by running pi-mono, not by hand-writing JSON.
- **a test that can't break when behavior changes shouldn't exist.**

test types, in priority order:

1. **conformance** — golden fixtures proving our output matches pi-mono byte-for-byte.
2. **boundary** — exercise the contract between two modules (e.g., session write → read → buildSessionContext round-trip).
3. **behavior** — test what a module DOES, not how (e.g., "compaction keeps recent messages and produces summary" not "findCutPoint returns index 7").
