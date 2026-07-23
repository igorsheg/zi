# ADR 0018: Session memory follows active and cold ownership

## Status

Accepted.

## Context

The append-only session transaction in ADR 0015 made durable compaction safe, but its first implementation retained every parsed journal entry for the session lifetime. The characterization and before/after measurements are recorded in [`docs/session-memory-spike.md`](../session-memory-spike.md). Context compaction reduced provider input and terminal renderables without releasing compacted message text, thinking, tool arguments, results, or inline base64 images. `SessionManager.open()` also read, decoded, split, parsed, and retained a complete journal at once. A compacted 32 MiB characterization journal consequently reported only 164 KiB of active message payload while the interactive process retained roughly 304 MiB RSS.

The 64 MiB session file limit was checked only during listing and restore. A live session could cross it and become impossible to resume. Shell previews had a byte bound but rebuilt their retained tail with `Buffer.concat()` for every output chunk.

## Decision

The session journal remains append-only and authoritative. Its in-memory representation now distinguishes the **resident session tail** from cold durable history.

- `SessionManager` retains only the physical suffix beginning at the latest compaction marker's `firstKeptEntryId`. This suffix is sufficient for repeated compaction, retry exclusion, provider context, and current transcript presentation.
- Persisted cold entries remain only in JSONL. In-memory sessions encode a pruned cold prefix as UTF-8 bytes so `persist: false` keeps full-journal behavior without retaining duplicate parsed object graphs.
- Explicit `entries()` and `messages()` calls may materialize the complete journal. Runtime policy uses `retainedEntries()` and never materializes cold history accidentally.
- Prompt history owns bounded `{ entryId, text }` values rather than message references. It remains limited to 100 entries, 1 MiB per entry, and 8 MiB in aggregate.
- Restore scans a bounded file through one reusable 64 KiB read buffer. The first pass validates journal order and semantic references, derives model, thinking, prompt history, blob references, and the latest resident boundary. The second pass hydrates only the requested full journal or resident suffix. A malformed unterminated tail remains untouched until the next append, which repairs it before committing a new record.

New journals use format version 2.

- Image bytes are decoded once, stored raw in a per-session SHA-256-addressed blob directory, and represented in JSONL by `{ sha256, bytes }` references.
- Existing format-1 journals remain readable and continue appending inline images. Format-2 active messages hydrate Pi's required base64 value; cold images do not.
- Blob creation precedes a referencing append. Failed appends remove blobs created by that operation. Session-runtime discard removes both the journal and its blob directory.
- Journal and unique blob bytes share one 64 MiB storage admission limit. Every live append is checked before persistence or in-memory mutation, so every committed session remains resumable.

The session shell retains preview bytes in one fixed UTF-8-aligned buffer. Overflow moves the bounded tail in place instead of allocating a concatenated buffer for each chunk. Full shell output remains file-backed under the existing session-shell limits.

Memory diagnostics report total, resident, and cold entry counts; logical journal bytes; resident entry bytes; image blob bytes; and encoded in-memory cold bytes. These are ownership diagnostics, not estimates of JavaScript object layout.

## Consequences

- Compaction now releases persisted cold message objects and strings while preserving the append-only durable journal.
- Uncompacted sessions still retain their complete active history because the provider and transcript can require it.
- Full-journal inspection is deliberately expensive and explicit. A future history view must page through a bounded coding-agent operation rather than repeatedly call `entries()`.
- Format-2 journals depend on their sibling blob directory. Copying or backing up a session requires both.
- Content-addressing deduplicates repeated images within one session, but blobs are not shared globally and introduce no global cache lifetime.
- Streaming restore performs two sequential scans for compacted journals. The bounded extra I/O is accepted in exchange for lower peak and retained memory.
- Aggregate storage rejection can surface at message commit. Future session rollover may improve that product behavior without weakening the resumability invariant.
- This decision amends ADR 0015's statement that `SessionManager.entries()` is always the resident full journal. Durability remains append-only; residency no longer mirrors durability.
