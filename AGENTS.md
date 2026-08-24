# Zi engineering rules

Zi is a clean Zig 0.16 rewrite of hax v0.4.0. The hax checkout at the revision in
`THIRD_PARTY_NOTICES.md` is the behavior and architecture reference. Adapt behavior and
ownership. Do not translate C line by line.

## Ready gate

Do not call work ready until all of these pass:

```sh
zig fmt --check src/
zig build
zig build test
./zig-out/bin/zi --help
./zig-out/bin/zi --version
```

For later capabilities, exercise the highest level reachable from the built binary. Use only
`./zig-out/bin/zi` from this checkout. Report library-only work as library-only.

## Ownership

- `src/main.zig` adapts the process and imports only the public package seam.
- `src/ai/` owns provider-independent items, stream events, provider interfaces, wire protocols,
  and transports. Stream-event payloads are borrowed during synchronous delivery.
- `src/agent/` owns the pure turn assembler and, later, the shared agent loop. It depends on `ai`.
- `src/cli/` owns argument parsing, process output, and exit mapping.
- `src/tool/` owns erased synchronous tools, result ownership, and bounded model-facing output policy.
- `src/text/` owns provider-neutral byte and UTF-8 sanitation helpers.
- `src/ProcessSpawn.zig` owns the process-wide fork/exec coordinator. Every raw or wrapped process creation path must hold it across non-atomic close-on-exec descriptor setup and spawn.
- Future persistence, terminal, and rendering modules get their own `root.zig` seams when their
  first capability lands. Do not create empty modules.

Dependencies point inward. Callers outside a module import its `root.zig`, not leaf files. A
module root registers internal files so `zig build test` reaches their tests.

## Zig posture

- Pass allocators and `std.Io` explicitly. No global allocator or ambient I/O.
- Use tagged unions for mutually exclusive states and kind-specific payloads.
- Use small erased interfaces for providers, tools, and event sinks.
- Borrow request data. Arena-own bounded results when bulk lifetime is appropriate.
- Bound retained data, queues, subprocess output, network responses, and persisted input.
- Return errors for runtime failures. Reserve panic for programmer bugs.
- Free every allocation. State ownership transfer in API comments.
- Functions use `camelCase`, values and fields use `snake_case`, and types use `PascalCase`.
- Keep `pub` declarations to actual cross-file callers.
- Format with `zig fmt`. Run `ziglint` after non-trivial changes.

## Behavior and provenance

Preserve hax observable behavior unless Zig ownership or safety requires a narrower contract. Keep
provider quirks in adapters. Keep orchestration provider-independent. Attribute adapted source and
its exact revision in `THIRD_PARTY_NOTICES.md`.

Do not add Node.js, bun, npm, TypeScript, plugins, MCP, or an alternate-screen UI. hax's Unix
composition and normal-buffer terminal behavior are product constraints.

## Commits

Use conventional commits with an owning-module scope. Admit one capability with its tests per
commit. Never commit `.zig-cache/`, `zig-out/`, or session state.
