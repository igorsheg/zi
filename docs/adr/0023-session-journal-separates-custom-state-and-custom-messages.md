# ADR 0023: Session journal separates custom state and custom messages

## Status

Accepted.

## Context

Extensions need two durable session capabilities with different semantics: private state used to restore extension behavior, and conversation side-channel messages that the model may act on. Zi already separates journal durability, provider context, and transcript presentation for compaction, retry failures, and context-excluded Bash output, but it has no durable extension-state entry and accepts `role: "custom"` only as an ordinary message row.

Pi proves a useful split between `type: "custom"` state entries and `type: "custom_message"` conversation entries. Pi also proves that `display: false` means hidden from presentation, not excluded from provider context. Its custom-message compaction regression showed that entry-to-context policy must not be duplicated between restore and compaction planning.

Zi extensions execute in isolated workers and do not receive `SessionManager`. Durable state therefore also needs a narrow bounded read projection and, when exposed publicly, concrete correlated worker-to-host operations rather than direct journal access.

## Decision

Zi adopts two top-level append-only journal kinds:

- `custom` stores bounded JSON extension state. It never projects into provider context or the default transcript.
- `custom_message` stores bounded text/image conversation content, optional bounded JSON details, and a `display` value. It always projects to a runtime `role: "custom"` message and enters provider context; it enters presentation only when `display` is true.

`SessionManager` owns validation, persistence, image blobs, aggregate custom-state bounds, and all projections. Journal-owned custom values are immutable snapshots so returned entries and projections cannot diverge from persisted restore. One canonical `sessionEntryToContextMessage()` rule is shared by active context and compaction planning. A bounded full-journal custom-state index remains available after compaction makes old message entries cold. The first custom append flushes a pending journal so “durable” never means process-local.

Released `type: "message"` rows containing `role: "custom"` remain readable with the same context and presentation semantics, but new writes through `appendMessage()` are rejected. Supported producers use the dedicated custom-message transaction.

`AgentSession` will own append and delivery admission through a closed intent union. Clients render coding-agent projections and never invent journal rows. Isolated extensions will cross only concrete source-attributed operations for reading custom entries, appending an entry, and sending a message; operation promises settle on admission rather than on completion of a triggered provider turn. During `session_shutdown`, custom-state reads and appends remain admitted until handlers settle; conversation delivery is closed, then the binding is released before worker disposal.

First-party compaction remains a dedicated `compaction` marker. It projects one summary into context and one transcript item; `compaction_end` remains lifecycle feedback and cannot create transcript identity.

Initial bounds are concrete policy: 128-byte custom types, JSON depth 32, 4096 JSON nodes, 256 KiB per JSON value, 1 MiB custom-message content, and 2048 entries or 2 MiB for complete custom-state history. Custom-message images use the format-2 session blob transaction and existing session storage bounds.

## Consequences

- Durability, provider context, and presentation remain independent, owner-defined axes.
- Hidden custom messages consume context and compaction budgets by design.
- Extensions can restore state folded out of the resident session tail without receiving private journal machinery.
- Compaction cut points and accounting automatically admit future context-visible entry kinds only when the canonical projector admits them.
- Public extension delivery, correlated protocol operations, and optional declarative renderers remain separate implementation slices; this decision does not create a generic command bus or permit extension-owned OpenTUI renderables.
