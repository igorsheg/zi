# Architecture

zi has five layers.

## The stack

| Layer | Owns | Must stay out of |
|---|---|---|
| L1 data formats | messages, events, models, session entry shapes | provider policy, UI policy |
| L2 provider substrate | transport, streaming, provider normalization, model/provider interfaces | persistence, session logic, UI |
| L3 TUI | rendering, input, focus, overlays, components | agent policy, provider policy |
| L4 stateful agent | turns, tool lifecycle, steering, follow-ups, cancellation | sessions, compaction, extension discovery, rendering |
| L5 composition root | session persistence, compaction, extensions, built-in tools, resources, CLI modes | re-owning lower-layer responsibilities |

## The core rule

Each layer should be reusable by the layer above it.

If a layer stops being reusable, it usually means it absorbed responsibilities that belong elsewhere.

## Composition root philosophy

The top layer should wire the product together, not impersonate the layers below it.

It owns product assembly:
- sessions
- compaction
- extensions
- resource discovery
- built-in tool packaging
- mode selection

It should feel thin because the real behavior already lives below it.

## Agent philosophy

The agent is a reusable conversation engine, not the whole app.

It owns:
- turns
- tool execution lifecycle
- steering and follow-ups
- cancellation threading
- streaming state

It should not quietly absorb session or UI responsibilities.

## TUI philosophy

The TUI is a reusable terminal framework, not app-specific rendering code.

It owns:
- components
- layout
- focus
- overlays
- rendering
- input handling

It should render published state, not reach back into agent or provider internals.
When another owner publishes semantic state, the TUI should reconstruct its own local presentation state from that snapshot instead of depending on view-specific cross-thread payloads.

## Cross-owner boundary philosophy

Across the TUI↔agent boundary, prefer authoritative semantic snapshots over lossy projections tailored to one consumer.

That means:
- the producer publishes the domain state it actually owns
- the consumer rebuilds its local caches, transcript/editor state, and render surfaces from that snapshot
- request messages stay about mutation and work, not "please precompute my UI"

Lossy consumer-specific transport models create a shadow architecture. They duplicate only part of the real contract, drift when new UI-visible semantics appear, and pressure the system back toward shared-state reads or ad hoc exceptions.

## Provider philosophy

Provider code should normalize provider quirks into shared message and event contracts.

Provider-specific behavior belongs at the provider seam, not in session accounting, agent state, or the UI.

## What should survive refactors

These are the durable invariants:
- the layer split
- the ownership split
- the public data contracts
- the extension seam
- the distinction between reusable layers and product wiring
