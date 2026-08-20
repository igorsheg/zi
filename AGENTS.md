# Zi engineering rules

Instructions for AI coding agents working on this Zig rewrite.

This file is for durable rules. Prefer principles and ownership boundaries over
feature inventories. When a fact changes often, point to the source of truth
instead of copying it here.

The tree wins. If a rule below disagrees with `src/`, `build.zig`, or
`.github/workflows/`, the code is right and this file is stale. Fix the file in
the same change that discovers the drift.

## Declaring work ready

Do not say the work is ready, done, or complete until you have built the binary
and proven the change at the highest level it is actually reachable. A passing
test suite is necessary, not sufficient.

Before reporting the work as ready:

1. `zig fmt --check src/ tools/` passes.
2. `zig build` succeeds.
3. Focused tests for the changed path pass (`zig build test` when the change is
   not local enough to isolate).
4. Prove the change at its reachable level, and say which level you used:
   - Reachable from the binary: run `./zig-out/bin/zi` and drive the happy path
     the change affects.
   - Library-level only: run the focused tests, run `./zig-out/bin/zi` to
     confirm the process still builds and starts clean, and state plainly that
     the change is not yet reachable from the binary.
5. Confirm the process did not abort, stderr is clean, and the behavior matches
   what you are about to tell the user.

Never describe library-level work as user-facing behavior. "You can now resume a
session" is false while nothing in `main` can reach the code that does it.

If you cannot run the binary, say so and ask the user to verify. "The tests
pass" is not a substitute.

### Always use the built binary in this repo

When running zi for verification, always use `./zig-out/bin/zi` from this
checkout. Never run `zi` from `PATH`, and never assume an installed copy
reflects your change.

`zig build` writes to `zig-out/bin/zi`. That is the only binary that contains
your latest change.

### What the binary does today

`src/main.zig` delegates process adaptation and dispatch to
`src/coding_agent/cli/entry.zig`. The built binary exposes the surface printed
by `./zig-out/bin/zi --help`.
Treat that output and the composition code as the authority. Do not infer
interactive, JSON, or RPC support from parser types that the process rejects.

## Continuous integration

`.github/workflows/ci.yml` runs on pull requests and on pushes to `main` and
`zig`. It pins Zig to the same version as `.minimum_zig_version` and runs
exactly three checks on `ubuntu-24.04`:

```
zig fmt --check src/ tools/
zig build
zig build test
```

The CI commands are part of the local ready gate, not a superset of it. If CI
fails after those commands pass locally, investigate platform dependence. Keep
the two in sync: a new required CI check belongs in this file and in `ci.yml`
in the same change.

## References

Use these references by role. Do not port any of them literally.

| Role | Reference | Use for |
| --- | --- | --- |
| Behavior | [pi](https://github.com/earendil-works/pi) / [pi-mono](https://github.com/badlogic/pi-mono) | Observable coding-agent behavior: model lookup, normalized messages, streaming tool calls, reasoning, usage, context, CLI/session contract |
| Zig model | [ZigAI](https://github.com/Kludex/zigai) | Representation: small erased interfaces, tagged unions, borrowed request data, arena-owned results, synchronous borrowed stream events, explicit model profiles, injected `std.Io`, adapters isolated from orchestration |
| Zig process | [fx](https://github.com/vercel-labs/fx) | Zig 0.16 process shape, module ownership, and native binary composition. Take a pattern only when it fits Zi's current owners |

Concrete behavior pins and provenance live with the owning source and data, or
in commit history, not as duplicated commit hashes in this file.

A reference's rules assume a reference's maturity. fx ships a real binary, a
four-platform CI matrix, and a release pipeline. Zi does not. Do not adopt a
process rule whose precondition this repo has not built.

When the references disagree:

1. Preserve pi's observable cross-provider behavior.
2. Preserve Zig's explicit ownership, error, and I/O model.
3. Keep Zi's public seam smaller than any reference's full surface.
4. Put provider quirks in adapters or model profiles, never in harness branches.
5. Defer a feature rather than weaken the canonical types.

This branch is the Zig rewrite. It is not a mix of the TypeScript product on
`main`. Do not reintroduce Node, bun, npm, OpenTUI, or `packages/` into the Zig
tree.

## Language and toolchain

This project is written in **Zig 0.16+**. There is no Node.js runtime, no
`package.json`, and no JavaScript build step for this branch.

```bash
zig build                          # build the binary
zig build test                     # run unit tests and the model-catalog check
zig build run                      # build and run
zig fmt src/ tools/                # format Zig sources
zig build check-model-catalog      # verify data/model_catalog.json vs the snapshot
zig build update-model-catalog     # regenerate src/ai/model_catalog_snapshot.zig
```

`.minimum_zig_version` in `build.zig.zon` is the pinned toolchain. `build.zig`
owns the step list; that block is a convenience copy, not the authority.

`node_modules/` and `dist/` may still exist on disk as ignored leftovers from
`main`. They are not part of this branch. Do not read, grep, or reason from
them, and do not let a search result inside them influence a decision.

## Commits

- Conventional commits, with a scope naming the owning module:
  `feat(coding-agent): add durable session journal`.
- No emojis in commit messages or PR text.
- No generated-by or co-authored-by attribution footers.
- One admitted capability per commit, with its tests.

## Code style

- Format Zig with `zig fmt` before committing. The canonical check is
  `zig fmt --check src/ tools/`.
- Do not use emojis in code, output, or documentation.
- Do not use em dashes. Use a comma, colon, period, parentheses, or a plain
  hyphen.
- Functions use `camelCase`, as enforced by `ziglint`. Variables, fields, and
  constants use `snake_case`; types use `PascalCase`.
- Keep `pub` surface area minimal. Only mark declarations `pub` when they are
  used outside the file.
- Write direct code with one obvious control path. Name the owner of mutable
  state and resource lifetimes.
- Comments explain invariants, trade-offs, and provenance. They do not narrate
  syntax.
- Represent mutually exclusive states as explicit tagged unions. Make invalid
  combinations unrepresentable.

## Architecture

`src/main.zig` is the composition root. Do not add leaf feature logic there.

Each module directory has a `root.zig` that is its public seam to other modules.
Owners inside one module may import sibling files directly; callers outside it
use `root.zig` instead of reaching through the boundary. Export only declarations
with a current cross-module caller; `coding_agent/root.zig` currently exposes the
reachable CLI seam and keeps its implementation owners private. A root's
`test { _ = ... }` block is also the test registry: a new file in the module is
not covered by `zig build test` until it is referenced there.

Module ownership (stable boundaries):

- `src/ai/` owns the provider-independent model substrate: identities, profiles,
  settings, messages, streams, usage, failures, catalogs, wire protocols,
  transports, and provider adapters.
- `src/agent/` owns the streamed tool loop: provider context, tool execution,
  run limits, commits, resumable settlement, and the data-oriented run, turn,
  message, and tool event contract. Core event payloads are borrowed during the
  synchronous sink call.
- `src/coding_agent/` owns coding-agent policy: the session (identity,
  selection, durable journal, commits, on-disk format), the runtime that admits
  a model and its credentials, cwd-bound tools, `ZiPaths`, model config and
  resolution, the CLI process adapter, and the interactive application.
- `src/BoundedJson.zig` is the shared bounded JSON helper. Domain-specific
  validation stays with the owning module.
- `src/coding_agent/BoundedTextFile.zig` shares optional bounded UTF-8 file-read
  mechanics inside `coding_agent`. Discovery, limits, and diagnostics stay with
  each resource owner.
- `data/model_catalog.json` plus `tools/model_catalog.zig` own catalog
  generation. The compiled snapshot lives in `src/ai/model_catalog_snapshot.zig`.

Dependencies point one way: `coding_agent` depends on `agent` and `ai`; `agent`
depends on `ai`; `ai` depends on neither. Do not add a back edge.

For the admitted product behavior right now (providers, tools, and what `main`
actually does), trust `src/`. Do not invent extensions, RPC, Code Mode, MCP, or
npm install on this branch.

### Adding a feature

Before implementing, answer in order:

1. Which module owns the behavior?
2. What is the typed contract?
3. Does it need persistence?
4. What tests land with it, and where are they registered?

If unclear, define the contract first. Port one pi capability at a time with its
behavior tests and upstream provenance. Prefer a deep owner over another
pass-through wrapper.

## Configuration and state

`ZiPaths` is the immutable owner of one effective cwd and one home. From those
two admitted values it resolves the global agent root and the exact project `.zi`
root. Feature owners define their directories and files beneath those roots.
Settings, credentials, resources, and persistent session creation consume the
cwd-bound roots. Do not join `.zi` or re-read process cwd inside those owners.

`ProjectTrust` owns project prompt-file admission, and `ProjectTrustStore` owns
canonical directory identities plus the bounded versioned
`$HOME/.zi/agent/trust.json`. The nearest saved cwd or ancestor decision applies;
without one, non-interactive automatic trust is closed. Store mutations consume
the shared private-file transaction mechanics. Explicit approve
and reject launch decisions override saved policy without persisting it. Trusted
project prompt files resolve from the effective session cwd and shadow global
prompt files independently by role.

`RuntimeResources` owns invocation-scoped trust resolution, prompt-file and
context discovery, and the effective prompt policy that borrows those owned
resources. `RuntimeServices` sequences session selection, resources, model and
credential admission, and runtime construction. It projects and owns the
restored `SessionTranscript` before transferring the selected journal into the
live runtime. Resource policy does not belong in that composition owner.

`ContextFiles` owns bounded global and cwd-ancestor instruction discovery.
Ancestor instructions apply from broadest to narrowest scope regardless of
project-resource trust.

The session journal is the append-only JSONL authority for one durable session
when persistence is admitted. Torn-tail repair happens on the next append. The
owner that creates a session disposes it. Live and restored provider context use
`agent.ContextProjection` to remove incomplete tool exchanges after abandoned
runs. Ordinary provider, tool, cancellation, timeout, and bounded-resource
settlement returns the agent to ready; indeterminate publication poisons the live
agent until the durable session is reopened.

`AgentSessionEvent` extends the core agent lifecycle with session facts such as
final settlement. It does not replace core payloads with rendering commands.
`OwnedAgentSessionEvent` is the bounded arena-owned copy for worker or UI
boundaries; presentation remains a downstream reducer. Canonical message and
stream owners provide bulk-lifetime copy operations so boundary owners do not
reimplement nested message or provider-state copying. Only `TurnWorker` mutates
or disposes a transferred `AgentSession`. It applies backpressure at bounded
event-count and aggregate-byte limits rather than locking the agent or retaining
borrowed callback data. `SessionTranscript` owns the presentation-neutral active
branch projection of restored journal entries. It preserves user, assistant,
tool, model-change, failure, cancellation, and interruption facts independently
of the cleaned provider-context projection. `coding_agent/interactive/` owns the
interactive application. Its `Policy` owns bounded sequential follow-ups and
deterministic submission, cancellation, restoration, stale-run, and
poisoned-session transitions. `App` applies that policy to worker facts and
input actions, and clears editor drafts only after policy and worker admission
succeed. The CLI owns process adaptation and launch composition, not terminal
mechanics or interactive policy.

`interactive/terminal/Session.zig` owns raw-mode admission and best-effort
cooked-mode, style, hyperlink, and cursor restoration. Interactive mode starts
on the normal screen without mouse tracking, alternate-screen rendering,
keyboard-protocol negotiation, or frame diffs. `interactive/input/Decoder.zig`
owns bounded escape parsing and resolves a bare Escape only after a quiet-period
deadline. `interactive/EventLoop.zig` handles bounded terminal bytes, resize
observation, worker fact collection, and input-deadline callbacks on the
terminal-owning thread. It does not interpret coding-agent input actions.
`NormalScreenRenderer` uses append-only output, sanitizes all provider and tool
text before writing terminal bytes, and redraws only the active prompt line.

Credentials are admitted values on the session runtime, not ambient environment
reads scattered through the tree. The process edge reads the environment once
and passes the value inward; owners take credential inputs and never call
`getenv`. Do not add a second configuration path for the same fact.

`PrivateFileStore` owns the shared mechanics for bounded private-file reads,
non-following path validation, mutation locks, and durable atomic replacement.
Domain stores retain their own filenames, formats, limits, error mapping, and
secret handling.

`$HOME/.zi/agent/auth.json` is the durable credential authority. `CredentialStore`
owns its bounded versioned format and secret wiping, and performs mutations
through `PrivateFileStore`. OAuth refresh rechecks expiry while holding the store
mutation lock and persists a rotated credential before releasing it.

## Zig-specific patterns

### Memory

- Allocators are passed explicitly. Never use a global allocator.
- Free what you allocate. Use `defer` for cleanup at the call site.
- Prefer `ArenaAllocator` for request-scoped work that can be freed in bulk.
- When a function returns allocated memory, document who owns it.

### Error handling

- Return errors rather than panicking. `@panic` is for programmer bugs, not
  runtime conditions.
- Use `errdefer` to clean up partial state on error paths.
- Prefer specific error sets over `anyerror` when the set is bounded.
- Validate external input, persisted data, provider data, and process
  boundaries. Do not add defensive branches for states the types already forbid.

### Strings and JSON

- Zig strings are `[]const u8`. There is no implicit null termination.
- Bound queues, output, retries, subprocesses, and retained data.
- Use the project's bounded JSON helper instead of inventing another decoder.
- `ai.transport.Request.headers` is the sole outbound header representation.
  Compose headers case-insensitively with `HeaderList`; configured headers may
  not replace framing, authentication, or protocol-owned headers.

### I/O (Zig 0.16)

- `main` uses `pub fn main(init: std.process.Init) !void`.
- Pass `std.Io` explicitly. File and directory operations use `std.Io.File` and
  `std.Io.Dir`, not `std.fs`. Pure path math (`std.fs.path.resolve`, `join`,
  `dirname`) is not I/O and stays on `std.fs.path`.
- In test blocks, use `std.testing.io`.
- `ArrayList(T)` initializes with `.empty`.
- New code uses the current `std.mem` names: `find`, `findScalar`,
  `findScalarPos`, `trimStart`, `trimEnd`. `indexOf` and `indexOfScalar` are
  deprecated aliases that still compile, and the tree still has call sites using
  them. Do not mass-rename them as a side effect of unrelated work.

## Testing

Zig unit tests go inside the source file they test, using
`test "description" { ... }` blocks. A new file is only reached by the suite
once its module `root.zig` references it.

- Run the narrowest relevant tests while developing. `zig build test` is the
  full suite, and it also runs the model-catalog check.
- Use `std.testing.expect`, `std.testing.expectEqual`, and
  `std.testing.expectEqualStrings`.
- Cover transitions, forbidden transitions, cancellation, stale completion, and
  bounds where an owner crosses I/O or process boundaries.
- Use transport and model fakes. Do not require a network for unit tests.

There is no TypeScript, bun, or e2e suite on this branch.

## Documentation

There is no product `docs/` tree. `README.md` documents the admitted build and
usage surface. `build.zig` owns the step list, and `src/main.zig` plus
`src/coding_agent/cli/` own the reachable process contract.

When behavior that already exists in the binary changes, update `--help` and
`README.md` in the same change and keep both limited to the reachable surface.

Do not document intended behavior as if it already exists. Completed
implementation plans remain available in commit history instead of forming a
second documentation tree.

## What not to do

- Do not grow `main.zig` with leaf feature logic.
- Do not report a library-level change as a user-facing capability.
- Do not reintroduce TypeScript, bun, npm, OpenTUI, Nano Stores, TypeBox, or
  `packages/` into this Zig tree.
- Do not add a second execution path for the same feature without a clear reason.
- Do not port pi types, promises, or mutation into Zig.
- Do not copy a reference project's product scope wholesale (ZigAI agent/graph/
  MCP/durable-workflow/UI; fx TUI/ACP/WASM/PGSO/tape replay/release machinery).
  Take a pattern only when it fits an existing Zi owner.
- Do not reach past another module's `root.zig` to import one of its files.
- Do not commit generated state from `.zig-cache/`, `zig-out/`, or `.zi/`.
- Do not add dependencies outside the Zig standard library without discussion.
- Do not use `@import` with runtime-computed paths.
- Do not ignore `zig fmt` failures.
- Do not report work as ready without running the binary.

## Before marking a change ready

1. Run `zig fmt --check src/ tools/` and the focused tests for the changed path.
2. Build and exercise the change with `./zig-out/bin/zi`, at the level the
   change is reachable.
3. Run the commands CI will run. If the commit has been pushed, confirm CI
   passes on that exact commit.
4. Update `README.md` only if user-visible behavior already exists and changed.
5. If this file's durable claims no longer match the tree, update this file in
   the same change.

## Keeping this file honest

Update `AGENTS.md` when a durable rule changes: ownership boundaries, toolchain
commands, ready-gate requirements, dependency direction, or hard prohibitions.

Reconcile against the tree, not against memory of the tree. Before trusting a
claim here, check the file it names. A rule that cannot currently be satisfied
is worse than no rule, because it teaches the next agent to route around this
file.

Do not use this file as a changelog of admitted providers, tools, CLI modes, or
reference commit pins. Those belong in `src/`, `README.md`,
`data/model_catalog.json`, or commit history.
