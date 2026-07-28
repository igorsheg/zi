# Product roadmap

- Status: active
- Updated: 2026-07-28

This roadmap orders product work by downstream leverage. [`parity-roadmap.md`](parity-roadmap.md) remains the capability and provenance inventory; parity evidence no longer determines product priority by itself. Product choices follow the [`building-block strategy`](building-block-strategy.md).

## Shipped — teach Zi one executable habit

Zi v0.1.12 shipped the [`custom-tool extension golden path`](extension-custom-tool-golden-path.md): a repository can add one trusted TypeScript tool that works in interactive, text, and JSON modes without modifying Zi.

### 1. Fix the target

- [x] Record the building-block strategy and feature-routing rule.
- [x] Define the custom-tool golden path and launch acceptance.
- [x] Keep the extension platform described as infrastructure until that path passes.

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
- [x] Present and remember cwd-keyed project-trust decisions in interactive mode.

### 4. Supervise one lifecycle generation

- [x] Add the versioned framed process protocol and TypeScript worker loader.
- [x] Add `ExtensionHost` ownership of startup, diagnostics, current/candidate generations, replacement, and disposal.
- [x] Bind lifecycle to `AgentSession` without exposing the host to clients.
- [x] Preserve immediate terminal restoration before bounded extension settlement.

### 5. Complete the custom-tool path

- [x] Add the narrow public tool-registration contract.
- [x] Admit custom tool definitions into the authoritative `AgentSession` tool catalog.
- [x] Execute invocations through bounded correlated IPC with cancellation.
- [x] Present unknown/custom tools through the existing generic tool presentation.
- [x] Prove worker crash, hang, malformed result, stale completion, and shutdown behavior.
- [x] Pass the golden path in interactive, text, and JSON modes.

### 6. Make the path copyable

- [x] Publish `@with-zi/extension-api`; keep private coding-agent modules private.
- [x] Ship `examples/extensions/custom-tool/` with an executable acceptance test.
- [x] Add extension author documentation and source-attributed diagnostics.
- [x] Pass the compiled example acceptance in the five-target release matrix.
- [x] Publish Zi v0.1.12, its five native packages, and `@with-zi/extension-api` through the release workflow.

## Shipped — drive Zi as a process

Zi v0.1.13 shipped a versioned RPC mode over the existing `AgentSession` policy and a copyable process-owning reference client:

- [x] Observe authoritative session state, paged messages, and ordered events.
- [x] Submit direct, steering, and follow-up input.
- [x] Interrupt and await settlement with reserved control capacity.
- [x] List and select models and thinking levels.
- [x] Preserve bounded framing, operations, output, cancellation, and creator-owned disposal.
- [x] Prove the protocol against a compiled standalone executable.
- [x] Ship one copyable reference client tested against the compiled standalone executable.

RPC should not introduce a universal frontend facade or duplicate session policy.

## Now — follow demonstrated pressure

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
