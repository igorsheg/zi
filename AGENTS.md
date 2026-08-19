# Zi engineering rules

Instructions for AI coding agents working on this Zig rewrite.

This file is for durable rules. Prefer principles and ownership boundaries over
feature inventories. When a fact changes often, point to the source of truth
instead of copying it here.

## Declaring work ready

Do not say the work is ready, done, or complete until you have built the binary
and exercised the change. A passing test suite is necessary, not sufficient.

Before reporting the work as ready:

1. `zig build` succeeds.
2. Focused tests for the changed path pass (`zig build test` when the change is
   not local enough to isolate).
3. Run the built binary at `./zig-out/bin/zi` and drive at least the happy path
   that the change affects.
4. Confirm the process did not abort, stderr is clean, and the behavior matches
   what you are about to tell the user.

If you cannot run the binary, say so and ask the user to verify. "The tests
pass" is not a substitute.

### Always use the built binary in this repo

When running zi for verification, always use `./zig-out/bin/zi` from this
checkout. Never run `zi` from `PATH`, and never assume an installed copy
reflects your change.

`zig build` writes to `zig-out/bin/zi`. That is the only binary that contains
your latest change.

## References

Use these references by role. Do not port any of them literally.

| Role | Reference | Use for |
| --- | --- | --- |
| Behavior | [pi](https://github.com/earendil-works/pi) / [pi-mono](https://github.com/badlogic/pi-mono) | Observable coding-agent behavior: model lookup, normalized messages, streaming tool calls, reasoning, usage, context, CLI/session contract |
| Zig model | [ZigAI](https://github.com/Kludex/zigai) | Representation: small erased interfaces, tagged unions, borrowed request data, arena-owned results, synchronous borrowed stream events, explicit model profiles, injected `std.Io`, adapters isolated from orchestration |
| Zig process | [fx](https://github.com/vercel-labs/fx) | Zig 0.16 process shape, module ownership, and native binary composition. Take a pattern only when it fits Zi's current owners |

Concrete behavior pins and provenance live with the owning source and data, or
in commit history, not as duplicated commit hashes in this file.

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

`.minimum_zig_version` in `build.zig.zon` is the pinned toolchain.

## Code style

- Format Zig with `zig fmt` before committing. The canonical check is
  `zig fmt --check src/ tools/`.
- Do not use emojis in code, output, or documentation.
- Do not use em dashes. Use a comma, colon, period, parentheses, or a plain
  hyphen.
- Prefer `snake_case` for Zig identifiers. Types use `PascalCase`.
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

Module ownership (stable boundaries):

- `src/ai/` owns the provider-independent model substrate: identities, profiles,
  settings, messages, streams, usage, failures, catalogs, wire protocols,
  transports, and provider adapters.
- `src/agent/` owns the streamed tool loop: history, tool execution, run limits,
  commits, and agent state.
- `src/coding_agent/` owns coding-agent policy: `AgentSession`, cwd-bound tools,
  CLI core, `ZiPaths`, model config and resolution, and the durable session
  journal.
- `src/BoundedJson.zig` is the shared bounded JSON helper. Domain-specific
  validation stays with the owning module.
- `data/model_catalog.json` plus `tools/model_catalog.zig` own catalog
  generation. The compiled snapshot lives in `src/ai/model_catalog_snapshot.zig`.

For the admitted product surface right now (providers, tools, what `main`
actually does), trust `src/` and `README.md`. Do not invent interactive mode,
extensions, RPC, Code Mode, MCP, or npm install on this branch.

### Adding a feature

Before implementing, answer in order:

1. Which module owns the behavior?
2. What is the typed contract?
3. Does it need persistence?
4. What tests land with it?

If unclear, define the contract first. Port one pi capability at a time with its
behavior tests and upstream provenance. Prefer a deep owner over another
pass-through wrapper.

## Configuration and state

`ZiPaths` is the immutable owner of one effective cwd. It resolves
`$HOME/.zi/agent`, exact `<cwd>/.zi`, and the global models file. Settings,
credentials, resources, and persistent session creation consume that cwd-bound
value. Do not join `.zi` or re-read process cwd inside those owners.

The session journal is the append-only JSONL authority for one durable session
when persistence is admitted. Torn-tail repair happens on the next append. The
owner that creates a session disposes it.

Credentials are admitted values on the session runtime, not ambient environment
reads scattered through the tree. Do not add a second configuration path for
the same fact.

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

### I/O (Zig 0.16)

- `main` uses `pub fn main(init: std.process.Init) !void`.
- Pass `std.Io` explicitly. File operations use `std.Io.Dir` and `std.Io.File`.
- In test blocks, use `std.testing.io`.
- `ArrayList(T)` initializes with `.empty`.
- `std.mem` renames: `trimStart`, `trimEnd`, `find`, `findScalar`.

## Testing

Zig unit tests go inside the source file they test, using
`test "description" { ... }` blocks.

- Run the narrowest relevant tests while developing. `zig build test` is the
  full suite.
- Use `std.testing.expect`, `std.testing.expectEqual`, and
  `std.testing.expectEqualStrings`.
- Cover transitions, forbidden transitions, cancellation, stale completion, and
  bounds where an owner crosses I/O or process boundaries.
- Use transport and model fakes. Do not require a network for unit tests.

There is no TypeScript, bun, or e2e suite on this branch.

## Documentation

There is no product `docs/` tree until the Zig binary has a user-facing surface.

When behavior that already exists in the binary changes:

1. Update `--help` only after the process actually exposes it.
2. Update `README.md` for build steps and what the binary does today.

Do not document intended behavior as if it already exists. Completed
implementation plans remain available in commit history instead of forming a
second documentation tree.

## What not to do

- Do not grow `main.zig` with leaf feature logic.
- Do not reintroduce TypeScript, bun, npm, OpenTUI, Nano Stores, TypeBox, or
  `packages/` into this Zig tree.
- Do not add a second execution path for the same feature without a clear reason.
- Do not port pi types, promises, or mutation into Zig.
- Do not copy a reference project's product scope wholesale (ZigAI agent/graph/
  MCP/durable-workflow/UI; fx TUI/ACP/WASM/PGSO/tape replay/release machinery).
  Take a pattern only when it fits an existing Zi owner.
- Do not commit generated state from `.zig-cache/` or `zig-out/`.
- Do not add dependencies outside the Zig standard library without discussion.
- Do not use `@import` with runtime-computed paths.
- Do not ignore `zig fmt` failures.
- Do not report work as ready without running the binary.

## Before marking a change ready

1. Run `zig fmt --check src/ tools/` and the focused tests for the changed path.
2. Build and exercise the change with `./zig-out/bin/zi`.
3. Update `README.md` only if user-visible behavior already exists and changed.
4. If this file's durable claims no longer match the tree, update this file in
   the same change.

## Keeping this file honest

Update `AGENTS.md` when a durable rule changes: ownership boundaries, toolchain
commands, ready-gate requirements, or hard prohibitions.

Do not use this file as a changelog of admitted providers, tools, CLI modes, or
reference commit pins. Those belong in `src/`, `README.md`,
`data/model_catalog.json`, or commit history.
