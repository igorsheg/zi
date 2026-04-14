# Extensions

Extensions are part of the product surface, not an afterthought.

zi follows pi-mono's extension model in behavior and composition, while using Lua instead of TypeScript.

## What extensions are for

Extensions should be able to change how zi behaves without forking zi.

That includes four broad categories:
- registering capabilities such as tools and commands
- observing and shaping agent/session events
- performing runtime actions through the host
- participating in UI through host-provided primitives

## Architectural stance

The core app stays small on purpose.
Opinionated workflows should fit naturally as extensions instead of forcing product forks.

Built-ins and user extensions should go through the same conceptual registry and the same precedence rules. There should not be one truth for docs and another for runtime behavior.

## Lifecycle

Extensions have two phases:

1. **load** — discover code and collect registrations
2. **bind** — attach the loaded extension world to the live session/runtime

That split keeps discovery deterministic while preventing unsafe side effects before the host is ready.

## Precedence

Precedence should be deterministic and obvious:
- explicit
- user
- project
- builtin

Earlier, more specific registrations win.
The final winning tool or command definition should be the same one used for execution, filtering, and prompt metadata.

## Ownership

Extension execution is agent-owned.

Rules:
- Lua and extension registries live on the agent thread
- the TUI never calls into Lua directly on the hot path
- extension-triggered UI flows go through host-owned UI primitives, requests, or snapshots

## Event model

Extensions should see stable, product-grade payloads.

That means:
- event names and payloads match pi-mono at the observable level
- mutable/transformable hooks are explicit where the product expects them
- provider or transport quirks are normalized before extension consumers see them

## Tool model

Tool hooks have three separate concerns:
- prepare or validate
- execute
- finalize or transform result

Do not collapse these phases if the product contract needs them distinct.

## UI philosophy

Extensions should ask the host for UI capabilities, not reach through a raw component boundary.

The host owns:
- focus
- overlays
- transcript insertion
- editor state
- theme application

Extensions should receive stable primitives the host can uphold across refactors.

## What good extension docs should preserve

The durable parts are:
- lifecycle
- precedence
- ownership
- payload parity
- host/extension boundary

The exact list of hooks can evolve. The architectural shape should not.
