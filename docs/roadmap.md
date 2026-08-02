# Product roadmap

- Status: active
- Updated: 2026-07-31

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

## Ready — orchestrate tools without replacing them

Native code mode is implemented as a default additive tool for data-dependent orchestration:

- [x] Evaluate replacement and additive catalogs on opaque extension orchestration and an ordinary repository edit.
- [x] Select QuickJS and prove its compiled single-file WASM variant on all five release targets.
- [x] Isolate each code execution in one bounded, cancellable, self-hosted child worker.
- [x] Preserve host-owned tool validation, expected errors, cancellation, deterministic mutation order, and termination.
- [x] Deliver declared, validated native tool values to generated code without exposing presentation envelopes.
- [x] Persist and present bounded nested evidence and include nested file operations in compaction accounting.
- [x] Reserve `code` against extension conflicts and remove the prototype flag and code-only catalog.
- [x] Record runtime, authority, ownership, and v1 scope in ADR 0024.
- [x] Pass the production compiled acceptance on all five release targets.

V1 remains stateless and deliberately excludes approvals, replay, rollback, snippets, connectors, and ambient network access.

## Now — follow demonstrated pressure

After custom tools and RPC are in use, choose independently proven slices:

- extension reload UX;
- commands and durable extension state;
- agent and tool interception;
- provider registration;
- session-tree operations;
- package installation and provenance;
- declarative terminal contributions.

### In progress — profile-driven subagents

Decision: [ADR 0029](adr/0029-subagent-profiles-share-session-owned-orchestration.md). ADR 0026 remains the RPC subprocess and containment decision; ADR 0027 is superseded.

- [x] Retain session-owned `ChildZiProcess` and `SubagentSupervisor` mechanics with bounded concurrency, output, waits, cancellation, shutdown, credentials, cwd propagation, and process-tree containment.
- [x] Admit trusted global/project Markdown profiles and programmatic `registerSubagentProfile(...)` declarations into one bounded catalog with shared shape and precedence.
- [x] Derive the standard profile-listing, spawn, send, continue, wait, list, interrupt, and close tools only when that catalog is non-empty.
- [x] Make omitted profile model and thinking inherit the parent selection; report unavailable explicit models with profile source.
- [x] Preserve admitted child work across extension reload while replacing programmatic registrations.
- [x] Keep optional bounded extension orchestration operations over the same session-owned mechanics.
- [x] Remove the enablement setting, native delegation system prompt, session-level status projections, composer rail, and subagent-specific notifications while retaining semantic tool-call presentation.
- [x] Publish the [profile-driven subagent guide](subagents.md) and a complete [programmatic profile example](../examples/extensions/subagents/index.ts).
- [x] Add compiled acceptance for both declaration paths and standard child operations on all release targets.
- [ ] Prove graceful and forced descendant cleanup on every target, including a real Windows Job Object, before calling the substrate release-supported.

Each capability receives its own closed protocol messages, owner, bounds, example, and behavior tests. No capability expands a generic extension facade in anticipation of another.

### Shipped — commands and durable extension state

Decision: [ADR 0030](adr/0030-extension-commands-are-session-owned-user-actions.md) and [ADR 0023](adr/0023-session-journal-separates-custom-state-and-custom-messages.md).

- [x] Research Pi's custom state/message split and record provenance.
- [x] Accept the journal and projection ownership decision in ADR 0023.
- [x] Add the bounded journal kinds, canonical context projector, custom-state index, and image transaction.
- [x] Add closed `AgentSession` custom-entry and delivery admissions.
- [x] Render displayed custom messages through authoritative client projections.
- [x] Add concrete correlated extension session operations and a compiled durable-counter example.
- [x] Characterize Pi, Grok Build, and Codex command mechanics and preserve host-parsed one-owner routing.
- [x] Add factory-time `registerCommand(...)`, bounded raw arguments, cancellation, local model-invisible feedback, reserved built-in names, and idle-only `AgentSession` admission.
- [x] Add command catalogs and correlated invocation across extension protocol v6, interactive typed intents, direct RPC list/invoke, reload replacement, and stale-completion containment.
- [x] Extend the durable-counter example with `/counter show|increment|reset` and compiled worker/session behavior acceptance.

### Shipped — extension reload UX

Research: [`extension-reload-research.md`](extension-reload-research.md).

- [x] Characterize Pi's `/reload` path and Zi's existing `ExtensionHost.reload` ownership.
- [x] Add `AgentSession.reload()` for in-session settings, resource, and extension-generation refresh.
- [x] Keep session identity and journal stable; do not route ordinary reload through `AgentSessionRuntime` replacement.
- [x] Enforce idle-only admission in coding-agent; surface `/reload` in interactive mode.
- [x] Prove candidate failure retention, failed-host recovery, durable-state restore on reload `session_start`, and dispose-during-reload settlement.
- [x] Update extension docs and the author recovery habit (edit or crash → explicit reload).

## Deliberately deferred

Unless user evidence changes priority, defer:

- publishing the current broad `@with-zi/coding-agent` package;
- an extension marketplace;
- arbitrary extension-owned OpenTUI renderables;
- broad Pi extension API compatibility;
- further visual polish that does not protect reference-client usability;
- speculative hooks, registries, and package splits.
