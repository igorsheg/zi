# Product roadmap

- Status: active
- Updated: 2026-07-26

This roadmap orders product work by downstream leverage. [`parity-roadmap.md`](parity-roadmap.md) remains the capability and provenance inventory; parity evidence no longer determines product priority by itself. Product choices follow the [`building-block strategy`](building-block-strategy.md).

## Now — teach Zi one executable habit

The current product milestone is the [`custom-tool extension golden path`](extension-custom-tool-golden-path.md): a repository can add one trusted TypeScript tool that works in interactive, text, and JSON modes without modifying Zi.

### 1. Fix the target

- [x] Record the building-block strategy and feature-routing rule.
- [x] Define the custom-tool golden path and launch acceptance.
- [ ] Keep the extension platform described as infrastructure until that path passes.

### 2. Select the extension-worker runtime

- [x] Add a release-shaped, self-hosted Bun worker probe.
- [x] Prove the candidate locally on macOS arm64 with Bun 1.3.14.
- [x] Run the probe on all five release targets.
- [x] Record the selected self-hosted Bun mechanism and portable process pipes in ADR 0021.
- [x] Delete the probe and its temporary workflow after the ADR lands.

### 3. Admit trusted extension sources

- [x] Add bounded global persistence for canonical cwd trust decisions and nearest-parent inheritance.
- [x] Detect exact project configuration that requires trust without reading its contents.
- [x] Add cwd-keyed project-trust resolution and process-local runtime decisions.
- [x] Give project settings, resources, and extension discovery one admission value.
- [x] Add deterministic bounded global, project, and explicit source discovery.
- [x] Exclude unresolved project configuration with a diagnostic in headless modes.
- [ ] Present and remember cwd-keyed project-trust decisions in interactive mode.

### 4. Supervise one lifecycle generation

- [x] Add the versioned framed process protocol and TypeScript worker loader.
- [x] Add `ExtensionHost` ownership of startup, diagnostics, current/candidate generations, replacement, and disposal.
- [ ] Bind lifecycle to `AgentSession` without exposing the host to clients.
- [ ] Preserve immediate terminal restoration before bounded extension settlement.

### 5. Complete the custom-tool path

- [ ] Add the narrow public tool-registration contract.
- [ ] Admit custom tool definitions into the authoritative `AgentSession` tool catalog.
- [ ] Execute invocations through bounded correlated IPC with cancellation.
- [ ] Present unknown/custom tools through the existing generic tool presentation.
- [ ] Prove worker crash, hang, malformed result, stale completion, and shutdown behavior.
- [ ] Pass the golden path in interactive, text, and JSON modes.

### 6. Make the path copyable

- [ ] Publish `@with-zi/extension-api`; keep private coding-agent modules private.
- [ ] Ship `examples/extensions/custom-tool/` with an executable acceptance test.
- [ ] Add extension author documentation and source-attributed diagnostics.
- [ ] Run the example against compiled release artifacts on every release platform.

## Next — drive Zi as a process

Implement a versioned RPC mode over the existing `AgentSession` policy:

- observe authoritative session state and ordered events;
- submit direct, steering, and follow-up input;
- interrupt and await settlement;
- select model and thinking level;
- preserve bounded output, cancellation, and creator-owned disposal;
- ship one reference client tested against `dist/zi`.

RPC should not introduce a universal frontend facade or duplicate session policy.

## Then — follow demonstrated pressure

After custom tools and RPC are in use, choose independently proven slices:

- extension reload UX;
- commands and durable extension state;
- agent and tool interception;
- provider registration;
- session-tree operations;
- package installation and provenance;
- declarative terminal contributions.

Each capability receives its own closed protocol messages, owner, bounds, example, and behavior tests. No capability expands a generic extension facade in anticipation of another.

## Deliberately deferred

Unless user evidence changes priority, defer:

- publishing the current broad `@with-zi/coding-agent` package;
- an extension marketplace;
- arbitrary extension-owned OpenTUI renderables;
- broad Pi extension API compatibility;
- further visual polish that does not protect reference-client usability;
- speculative hooks, registries, and package splits.
