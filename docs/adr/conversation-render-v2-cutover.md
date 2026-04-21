# conversation/render v2 cutover doctrine

## status

accepted for `zi-5psf.1`.

this is the root adr for conversation/render v2 contract work.

## intent

replace zi's current conversation/render path with one truthful request/snapshot pipeline that matches the runtime's ownership rules.

## why

zi's runtime doctrine is already explicit:
- the tui renders published semantic state
- tui -> agent mutation and work go through the request queue and run-control boundaries
- owner-boundary transport is private runtime machinery, not product api
- conversation projection already rebuilds transcript state from owned snapshots

that means the current cut is not between "live" and "replay". the real cut is between owner-local state and published semantic state.

any compatibility-first redesign would preserve the wrong seams: fallback event transport beside snapshots, old `UiEvent` conversation semantics surviving under a new name, transcript-owned conversation lifecycle logic, and stringify/parse hops that exist only to shuttle data between internal owners. that would keep legacy architecture alive inside the replacement.

## decision

conversation/render v2 is a **nuclear cutover**.

rules:
- no compatibility transport alongside the new snapshot path
- no preserving `UiEvent` live conversation semantics as a fallback
- no split live-vs-replay architecture after the cut
- no transcript-local state machine preserved for convenience
- no extra json/stringify/parse hops unless they correspond to a real owner or wire boundary

after cutover, zi has one internal conversation/render pipeline:
- requests and run controls mutate agent-owned state
- runtime host publishes authoritative semantic snapshots
- tui projection derives transcript/render state from those snapshots

## forbidden compatibility theater

the following are rejected:
- shipping snapshot publication while keeping a second conversation transport alive for safety, rollout, or migration
- preserving old live `UiEvent` conversation behavior as an alternate source of truth once snapshots own the boundary
- keeping separate "live incremental apply" and "resume/replay rebuild" projector paths after the cut
- leaving transcript lifecycle mutators or embedded conversation state in place just because current rendering code already depends on them
- translating internal conversation state through json, strings, or ad hoc serialization between agent runtime, runtime host, tui mailboxes, and projection when no real wire boundary exists
- exposing request payloads, snapshot payloads, patch payloads, or other owner-boundary structs as public contract just because they already move through the system

## consumers that move together

the cutover boundary is repo-wide for every consumer that participates in conversation/render state:

- agent-owned live conversation and tool execution state
- session/controller integration that requests work or swaps sessions
- request queue and run-control submission paths
- runtime-host publication of conversation and queued snapshots
- tui mailbox payloads that carry conversation/render inputs
- conversation projection and transcript reconciliation
- transcript/component render APIs that consume projected rows
- resume/history rebuild paths and any other path that reconstructs visible conversation state

there is no promise that an old conversation seam survives behind an adapter. the promise is that zi has one truthful conversation/render pipeline after the cut.

## runtime anchor

this adr is anchored to zi's existing runtime doctrine:

- **request vs snapshot** — if the tui needs mutation or work, it submits a request. if it needs to render, it consumes a published snapshot.
- **private owner boundaries** — request queues, mailbox payloads, snapshot publication, and patch/reconcile mechanics are host runtime machinery, not product api.
- **authoritative publication** — runtime host is the publication point for conversation and queued snapshots.
- **snapshot-driven projection** — tui conversation projection owns local render state, but it rebuilds and reconciles from owned snapshots rather than preserving a second live conversation model.
- **real wire edges only** — serialization belongs at explicit observer, persistence, or external wire boundaries, not between internal owners that already share semantic structs.

## consequences

follow-on conversation/render docs should treat this adr as settled ground.

that means:
- child issues delete dead seams instead of wrapping them
- new conversation contracts are judged by whether they fit request-for-work plus snapshot-for-render ownership
- any consumer broken by the cut moves to the new snapshot pipeline instead of getting a bridge back to legacy transport
- transcript/render code is allowed to become a retained projection of semantic state, not a second conversation owner
- internal transport shapes remain disposable implementation details unless zi intentionally exports them at a real public boundary
