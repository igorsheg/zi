# zi engineering contract

## posture

- Simple is good. Complex is evil. Complexity compounds.
- Build the boring mechanism first. Let real callers earn abstraction.
- Prefer one owner, one path, one obvious failure mode.
- If some fields only matter in some states, do not use dummy values or boolean mode flags. Encode the states directly.
- Runtime crashes are better than hidden corruption. Compile errors are better than runtime crashes.
- Resource allocation may fail. Resource deallocation must succeed.

## explicit systems

Use the `explicit-systems` skill for runtime, async, lifecycle, queues, ownership, cancellation, workers, UI, process, and shutdown work.

Every boundary must answer in code, not prose:

- Who owns this state?
- Who may mutate it?
- What event crosses the boundary?
- What queue carries it, and what bounds it?
- Where does time advance?
- Where does cancellation complete?
- Where is shutdown observed?

Comments are not contracts. If a comment explains required discipline, prefer:

- a type that makes the illegal shape unrepresentable
- a runtime assertion for owner/lifetime invariants
- a comptime error for interface contracts
- a test that captures the invariant

Use comments only for why, not for obligations the code can enforce.

## concurrency spine

zi follows a libxev-shaped, zi-specific runtime spine:

```text
Operation -> Backend mechanism -> Completion -> bounded queue -> owner drain
```

Rules:

- Runtime is mechanism, not App/UI/agent/session policy.
- Completion is data, not authority.
- Owners mutate state only at explicit drain/apply sites.
- Wakeups may coalesce; they are signals to inspect state, not messages.
- Cancellation intent and cancellation completion are different facts.
- Every submitted operation must complete, fail, or cancel observably.
- No unbounded queues.
- No hidden async continuation mutating owner state.

## zig systems craft

- Read before writing. Trace before fixing.
- Prefer small structs with explicit lifetimes over frameworks.
- Prefer state machines over callback control flow.
- Prefer owned wrappers over naked values when allocator ownership matters.
- Use TigerBeetle-grade suspicion: bounds, invariants, memory ownership, shutdown.
- Do not port dependencies wholesale. Study, extract contracts, write zi-shaped code.

## tests and checks

- Code is evidence. Tests are judgment.
- Add tests for invariants, not just examples.
- Run `zig build test` before claiming completion.
