# Design durable Zig agent sessions

Status: Slices A, B, and C implemented and verified on 2026-08-19; executable session selection and compaction pending

## Intent

Make one agent session durable before adding more executable wiring. The journal must preserve the conversation Zi actually admitted, recover conservatively after a crash, and restore enough policy to construct the same cwd-bound session without turning persistence into a second agent loop.

```text
admitted session path
    -> bounded header probe
    -> stored cwd and session identity
    -> effective cwd admission
    -> ZiPaths and later RuntimeServices construction
    -> bounded streaming journal restore
    -> AgentSession projection

AgentSession authoritative message/model/turn commit
    -> prepared journal record and prepared in-memory projection
    -> durable append
    -> allocation-free in-memory publication
```

This slice does not make the current executable live. It establishes the durable authority that new, open, continue, and resume must consume before cwd-bound services exist.

## Reference authority

The design uses three pinned references for different questions.

| Reference       | Pinned revision                                       | Authority                                                                                                                                                                 | Deliberately not copied                                                                                                                                     |
| --------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pi coding-agent | `73414d08b94d7db46d3fa66582c8fe3b02dabf72`            | Session header, stable entry IDs, parent-linked history, message/model-change entries, active-path projection, compaction-aware context, and cwd as session identity      | Unbounded pending-line reads, malformed-line skipping, synchronous append without an explicit durability boundary, ambient IDs/time, and rewrite migrations |
| Vercel Labs Fx  | `fc124be4f4c67ac4c1b7a0b586a3831e93b463d6` (`v0.0.3`) | Zig implementation evidence for framed JSONL, ordered identity validation, exact committed offsets, provisional-tail recovery, sync boundaries, and injected fault points | Its turn-shaped product schema, app-layer commit owner, ambient ID generation, and multi-process watermark/intent/checkpoint/sidecar/compaction system      |
| ZigAI           | `e2c5aef5f93015322891028a2048a217e7081687`            | Zig ownership, bounded JSON preflight, typed decoding, atomic file publication, explicit allocators and `std.Io`, cleanup, and allocation-failure testing                 | Snapshot persistence as a substitute for an append journal, or ZigAI product policy                                                                         |

Pi remains the product and architecture reference. Fx is third-order implementation evidence from a complete Zig coding harness, not a new product authority or a template for Zi.

## Findings that constrain the design

Pi's session file begins with a versioned header and then appends entries carrying `id`, `parentId`, and `timestamp`. Message and model-change entries advance a leaf, while projection walks the selected parent chain and folds model changes. Those semantics are worth preserving because they allow later branching and compaction without rewriting history.

Pi's file mechanics are not sufficient for Zi. Its loader can retain an unbounded partial line, skips malformed records, uses ambient identity and time, and appends without a successful file sync as the explicit publication boundary. Zi must reject interior corruption, bound every record and aggregate, and distinguish a recoverable final torn record from corruption.

Fx demonstrates that a Zig JSONL journal can retain an exact byte boundary, stream records, validate ordered identity, and inject failure at each write and sync boundary. Its `session_log.zig` also demonstrates the cost of solving multi-process publication, compaction, caches, checkpoints, and recovery in one owner. Zi's first journal has one writer and does not need that machinery.

Version 1 therefore does not copy Fx's `generation` and `seq` fields. The immutable header session ID identifies the file generation, physical record order plus unique IDs identifies sequence, and `parentId` validates logical ancestry. If a later compaction implementation replaces a journal file in place, that slice must first introduce an explicit generation contract rather than retrofitting invisible rewrite behavior.

The current Zig `Agent` appends the user request, each completed provider response, and each completed tool result directly to its owned `History`. A failed or cancelled run therefore leaves a meaningful partial message sequence. Provider failures that do not produce a valid response are not messages, and a process death can occur after a user or tool-call entry without any terminal record. Durability must preserve those partial sequences rather than persisting only successful turns.

## Product contract

### One authority

`SessionJournal` is the append-only authority for a persistent session. The in-memory transcript, provider context, model selection, prompt history, and presentation state are projections of committed journal entries.

An ephemeral session uses the same entry admission and projection rules with an in-memory journal backend. It does not gain a separate history model. The first implementation may admit only durable sessions if sharing the backend would enlarge the slice; it must not create a second set of message semantics.

### Pi-shaped, not Pi-file-compatible

Zi adopts Pi's header-plus-entry tree and user-visible field meanings. It does not promise byte-for-byte compatibility with Pi session files, accept arbitrary Pi extension entries, or make migrations silently rewrite source files.

The stable external names use Pi's established spelling: `parentId`, `modelId`, and RFC 3339 `timestamp`. Zi owns its version numbers, exact message encoding, validation, bounds, and additional turn-settlement record.

### Version 1 header

The first newline-terminated record is the only header.

```json
{
  "type": "session",
  "version": 1,
  "id": "018f...",
  "timestamp": "2026-08-19T10:30:00.000Z",
  "cwd": "/workspace/project"
}
```

Required fields:

- `type` is exactly `session`.
- `version` is exactly `1`; absent or unknown versions are rejected.
- `id` is a valid Zi session ID.
- `timestamp` is canonical UTC RFC 3339 with millisecond precision.
- `cwd` is an absolute, normalized, valid UTF-8 path within the `ZiPaths` path bound.

The header does not contain credentials, provider configuration, an endpoint, current model, mutable display metadata, or derived paths. Parent-session lineage, agent-team lineage, and image-blob format 2 remain later versioned additions.

### Entry base

Every later record contains:

```json
{ "type": "...", "id": "018f...", "parentId": "018f...", "timestamp": "2026-08-19T10:30:01.000Z" }
```

Entry IDs are generated before preparation and remain stable across an indeterminate append recovery. IDs are unique within the journal. `parentId` is `null` only for the first root entry; otherwise it references an earlier entry in the same journal.

The initial writer is linear and always uses the current leaf as `parentId`. The loader validates the more general earlier-parent relationship and builds the active path by walking from the selected leaf, matching Pi's model. Branch/fork operations are deferred, so exact resume selects the final physically committed entry as the leaf.

IDs and timestamps come from injected sources. Production may use UUIDv7-compatible IDs and the wall clock, while tests supply deterministic sequences. Journal and projection code never call ambient random or clock APIs.

### Version 1 entry kinds

Version 1 admits three entry kinds only.

```text
message
model_change
turn_end
```

`message` stores one stable, explicitly encoded Zi canonical message. It does not serialize a Zig union by field-name reflection. The codec owns a durable DTO for request parts, response parts, model identity, usage, finish classification, tool-call identity, tool-result identity, and provider replay state.

Version 1 accepts text user content, text tool-result content, response text, reasoning, and tool calls. Images are rejected at journal admission even though the current in-memory AI type can represent them. Format 2 image blobs remain governed by `CONTEXT.md` and are not predeclared as inert version-1 fields.

`model_change` stores a canonical provider and model ID:

```json
{
  "type": "model_change",
  "id": "...",
  "parentId": "...",
  "timestamp": "...",
  "provider": "openai",
  "modelId": "gpt-5.2"
}
```

It is appended before a new persistent session's first turn and before any later model switch becomes active. Aliases never enter the journal. An assistant response identity must equal the active canonical model at the point where it is committed.

`turn_end` is Zi's narrow addition to Pi's entry set:

```json
{ "type": "turn_end", "id": "...", "parentId": "...", "timestamp": "...", "turnId": "...", "outcome": "completed" }
```

`turnId` is the entry ID of the user message that admitted the turn. Outcomes are a closed union:

- `completed`: a final valid assistant response settled the turn.
- `failed`: the turn settled with a non-cancellation failure or configured limit.
- `cancelled`: admitted cancellation stopped active work.
- `interrupted`: provider streaming ended without a valid terminal response, or recovery closed a turn left open by process death.

A failed record stores a stable bounded failure category, not arbitrary provider text, stack output, secrets, or an open-ended error name. Cancellation and interruption remain distinct from terminal shutdown.

The terminal record makes failure state durable without inventing a synthetic assistant message. It also lets restore distinguish a completed turn from a partial tool sequence and a clean cancellation from a crash. This is a deliberate Zi extension; Pi's message and parent-link semantics still define the transcript.

### Tool relationships

A tool result references the provider tool call through `callId` and repeats the admitted tool name. Restore validates it against the closest unmatched tool call on the active turn path.

Within one response, tool-call IDs are non-empty and unique. A result must match one unresolved earlier call and its tool name, and one call receives at most one result. Provider call IDs need not be globally unique across completed turns.

A completed turn has no unresolved tool calls. Failed, cancelled, or interrupted turns may end with unresolved calls; restore retains those calls for presentation but excludes them from the next provider request unless later policy explicitly supplies synthetic results. This prevents an incomplete tool protocol exchange from being replayed as valid model context.

## Restore projections

Opening a journal produces one owned `RestoredSession` candidate rather than constructing tools, providers, or `AgentSession` during parsing.

```zig
const RestoredSession = struct {
    header: Header,
    active_leaf_id: ?EntryId,
    active_model: ?ModelSelection,
    context_messages: []const ai.Message,
    presentation_entries: []const Entry,
    recovery: Recovery,
    storage: StorageAccounting,
};
```

The exact type remains private. The important contract is:

- header identity and cwd are owned and available after a bounded header probe;
- canonical active model is folded from `model_change` records and checked against assistant identities;
- provider context contains only complete protocol-safe message sequences;
- presentation retains committed partial work and its terminal outcome;
- the active leaf and parent index are reconstructed from committed records;
- recovery reports a torn physical tail or an unterminated logical turn without mutating a read-only open;
- all returned slices have one owner and one `deinit` boundary.

An unmatched user turn at end of committed history is projected as interrupted recovery evidence. A writable resume durably appends its `turn_end: interrupted` record before admitting another user turn. Read-only inspection remains non-mutating.

No loader skips an invalid record. A malformed, duplicate, out-of-order, semantically invalid, or over-bound newline-terminated record is corruption and rejects the journal.

### Effective cwd ordering

Resume uses two admissions:

1. Open the exact selected journal and decode only its bounded header.
2. Admit the stored cwd, subject to the future explicit cwd override policy.
3. Construct immutable `ZiPaths` from that effective cwd.
4. Construct cwd-bound settings, credentials, resources, tools, and runtime services.
5. Restore the remaining journal and create `AgentSession`.

Session discovery may read bounded headers for listing, but it does not construct `ZiPaths` for each candidate. No owner below the future process host re-reads process cwd or joins `.zi` paths.

## Journal owner and states

`SessionJournal` is private to `coding_agent`. It owns the open file, exact path, validated header, committed byte offset, entry/parent index, active leaf, storage accounting, and any pending repair or indeterminate append. It does not own model providers, tools, process signals, or session-selection policy.

Its state is an explicit union:

```text
closed
read_only
    clean
    torn_tail { truncate_offset }
writable
    clean
    repair_pending { truncate_offset }
write_indeterminate { entry_id, start_offset, encoded_sha256 }
```

Allowed transitions:

| From                      | Operation                                      | To                                            |
| ------------------------- | ---------------------------------------------- | --------------------------------------------- |
| `closed`                  | open valid journal read-only                   | `read_only.clean` or `read_only.torn_tail`    |
| `closed`                  | open valid journal writable                    | `writable.clean` or `writable.repair_pending` |
| `writable.repair_pending` | first append repairs and syncs prefix          | `writable.clean`, then append proceeds        |
| `writable.clean`          | durable append succeeds                        | `writable.clean` at the new committed offset  |
| `writable.clean`          | append fails and rollback is durably synced    | `writable.clean` at the old offset            |
| `writable.clean`          | append or rollback cannot determine durability | `write_indeterminate`                         |
| any open state            | close                                          | `closed`                                      |

`read_only` never becomes writable in place. A writable recovery is reopened through the owning session transition so path, lock, projection, and repair policy are revalidated together.

`write_indeterminate` rejects every further append. The owner must close and reconstruct the candidate from the journal. While the process remains alive, the stable entry ID and SHA-256 of the exact encoded record let reopen verify that the tail is the same candidate. After process death, the ordinary physical rule applies: a valid newline-terminated record is committed, an unterminated record is torn, and absence means it was not committed. No other writer may publish a competing tail.

## Physical format and recovery

Every record is one UTF-8 JSON object followed by `\n`. Embedded newlines are JSON escapes. The newline is the physical record terminator; an unterminated final record is never admitted even when its bytes parse as complete JSON.

Open scans incrementally from byte zero with a fixed-size read buffer and a bounded current-record buffer. It records the byte after every fully decoded, semantically admitted newline-terminated record. End-of-file cases are:

- exactly at a record boundary: clean;
- after non-empty unterminated bytes: recoverable torn tail at the last admitted offset;
- after an invalid newline-terminated record: corruption;
- before a complete valid header: corruption, not an empty session.

Only the final unterminated bytes are repairable. Interior corruption, unknown versions, invalid UTF-8, duplicate keys where the JSON decoder can observe them, duplicate IDs, invalid parents, invalid tool relationships, and inconsistent terminal records are never truncated away.

The next append to a repair-pending journal first truncates to the exact admitted offset and syncs the file. If either operation fails, no candidate record is written and the journal becomes indeterminate or returns a repair failure according to whether the old boundary is still provable.

### New journal publication

Creation writes the complete header and newline to a same-directory temporary file opened exclusively with user-only permissions. It flushes the writer, syncs the file, atomically publishes the selected final name, and syncs the containing directory. Failure removes only the known temporary file and never replaces an existing session.

Session path selection and new/open/resume policy remain the later startup slice. The journal constructor consumes an exact admitted path; it does not derive session directories itself.

### Append transaction

For one candidate entry:

1. Generate its stable ID and timestamp from injected sources.
2. Validate it against the current projection and storage limits.
3. Deep-copy and encode the durable record into bounded prepared storage.
4. Prepare every in-memory projection mutation and reserve all collection capacity.
5. Write the record and newline at the exact committed offset.
6. Flush buffered writer state and sync the file.
7. Publish the prepared message/index/model/turn mutations without allocation.
8. Advance the committed offset and storage accounting.

No observer sees a message or model change before step 6. No allocation or validation may fail after the file sync succeeds. This requires a prepared-commit seam rather than calling the current arena-backed `History.append*` after durability.

If writing or syncing fails, the journal attempts to truncate to the old committed offset and sync that rollback. A successful rollback returns a definite append failure and keeps the journal usable. An unprovable rollback enters `write_indeterminate`; the current session stops accepting turns and must be reconstructed through normal open/restore.

A sync error can mean that the new bytes are durable even though the call reported failure. Reopen admits a complete valid record, repairs an unterminated record, or observes its absence; an in-process recovery additionally compares the retained ID and SHA-256 before publishing the prepared projection. This gives deterministic single-writer recovery without Fx's multi-process publication files.

The file is synced for each authoritative entry in version 1. There is no `none`, timed, or turn-batched production policy yet. A later explicit performance policy may batch only if it changes the product contract and exposes the possible-loss window; tests may inject a no-op sync implementation but cannot change production semantics.

The directory is synced for creation, atomic replacement, and deletion, not for ordinary appends to an already published inode.

## Binding to AgentSession

`AgentSession` owns durable commit policy. The lower-level `Agent` remains the provider/tool loop and must not learn paths, JSONL, file sync, session selection, or recovery.

The current `Agent.History` interface cannot satisfy durable-before-visible publication: its arena copy and list append can fail after a journal write, while appending to memory first exposes state that may not be durable. Before journal binding, history admission must gain a private prepare/publish protocol:

```text
prepare canonical message copy and projection capacity
    -> PreparedMessage
journal append and sync
    -> PreparedMessage.publish()  // allocation-free and infallible
```

The exact shape should remain concrete. Do not add a generic event store, command bus, repository interface, or public persistence callback.

The preferred seam is one private session commit owner used by the agent loop for user messages, provider responses, tool results, and terminal settlement. `AgentSession` supplies the journal-backed implementation; tests and explicitly ephemeral sessions use the same admission logic with an in-memory backend. Agent events remain notifications after authoritative publication and do not become the persistence protocol.

Commit order for a turn is:

1. Commit the user `message`; only then invoke the model.
2. Commit each valid provider response before executing any tool call it requested.
3. Commit each tool result before the next provider request.
4. Commit one `turn_end` after completed, failed, cancelled, or interrupted settlement.

This ordering ensures restored context never contains a tool side effect whose result was never admitted, though tool side effects themselves are not transactional. A crash after a tool side effect but before its result commit is represented as an interrupted turn with an unresolved call; Zi never fabricates success.

Model switching uses the same owner: prepare the new canonical model, commit `model_change`, then replace the active in-memory selection without allocation. Provider runtime replacement is a later `AgentSessionRuntime` transition and must not make the model active before the journal commit.

## Bounds

Version 1 starts with fixed private limits, not user configuration:

| Resource                           | Limit             | Reason                                                                                                                                       |
| ---------------------------------- | ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Header bytes                       | 64 KiB            | Header contains only identity, time, and cwd; this prevents listing from allocating record-sized buffers                                     |
| One entry record                   | 64 MiB            | Covers the existing 8 MiB admitted prompt and transport payload after worst-case JSON escaping while remaining below the total journal limit |
| Journal bytes                      | 64 MiB            | Matches Zi's settled aggregate session-storage ceiling and prevents unbounded restore or append growth                                       |
| Journal entries                    | 65,536            | Bounds indexes and tiny-record attacks independently of bytes                                                                                |
| JSON nesting depth                 | 32                | Matches existing bounded configuration parsing and exceeds the canonical message shape                                                       |
| Collection items per decoded value | 4,096             | Bounds hostile arrays/objects while exceeding protocol part counts                                                                           |
| Session/entry/turn ID              | 128 bytes         | Leaves room for stable textual IDs without accepting arbitrary keys                                                                          |
| Provider ID                        | 256 bytes         | Matches admitted model configuration                                                                                                         |
| Model ID                           | 512 bytes         | Matches admitted model configuration                                                                                                         |
| Tool call ID/name                  | 4 KiB / 256 bytes | Covers provider identifiers and the coding-tool catalog without unbounded relationship indexes                                               |
| Durable failure category           | 128 bytes         | Closed categories encode well below this; arbitrary error prose is forbidden                                                                 |

Journal bytes and future format-2 image blobs share the 64 MiB aggregate storage limit. Version 1 has no blobs, so journal and aggregate storage are equal.

Before compaction exists, the complete journal is the resident tail and append rejects growth beyond the 64 MiB storage limit. The journal must not create a persisted session that its own current restore cannot materialize.

Compaction is a subsequent entry-kind slice built on this format. It will add Pi-shaped summary and first-kept-boundary semantics, make the resident tail the exact physical suffix beginning at that boundary, retain only bounded entry-reference metadata for the cold durable prefix, and use bounded raw-or-Zstd blocks for an ephemeral journal's cold prefix. It must land before lowering the resident-memory ceiling below total storage; no placeholder compaction fields or codecs are added in version 1.

Every count and byte total uses checked arithmetic before allocation or I/O. Bounds are checked on decoded meaning and encoded bytes where escaping can increase size.

## Validation and corruption policy

The codec validates external durable data before it enters projection state:

- exact known fields for version 1;
- valid UTF-8 and no NUL in identifiers, paths, model names, tool names, and text fields where prohibited;
- canonical IDs, timestamps, provider/model identities, and finish categories;
- unique entry IDs and earlier-parent references;
- one root on the active tree;
- model identity consistency;
- message ordering and terminal-settlement rules;
- tool call/result relationships;
- checked token/usage values and aggregate counters;
- every byte, depth, collection, entry, and storage bound.

Unknown entry types and unknown fields are rejected in version 1. Forward compatibility comes from a new header version with an explicit migration or reader, not from silently ignoring durable state that may affect provider context.

Out-of-memory remains distinguishable from invalid or corrupt data. Diagnostics contain the path, record number, and stable error category, but never message bodies, tool arguments/results, provider replay state, or credential material.

## Implementation slices

Implementation proceeds only after this contract is reviewed.

### Slice A: codec and projection

Implemented in `src/coding_agent/SessionFormat.zig`, with the repeated untrusted-JSON preflight extracted to private `src/BoundedJson.zig` and reused by model configuration.

- Add private version-1 header, entry DTOs, typed encoder/decoder, identity/time sources, and semantic validator.
- Project message/model/terminal records into active context and presentation.
- Cover tool relationships, unmatched-turn recovery, canonical model folding, and exact bounds.
- Use allocation-failure tests for every owned decode and projection path.

No filesystem writes occur in this slice.

### Slice B: streaming journal owner

Implemented in private `src/coding_agent/SessionJournal.zig`.

- Bounded header probing and streaming full restore admit only newline-terminated records.
- Exclusive atomic creation publishes a mode-0600 file and syncs its containing directory.
- Transactional single-writer append reserves index ownership before I/O, syncs every record, and advances its exact committed offset without post-sync allocation.
- Torn final bytes remain visible on read-only open and are truncated and synced only before the next writable append.
- Injected boundaries cover partial records, completed writes, file sync, rollback, repair, publish, and directory sync. Definite rollback keeps the owner writable; uncertainty records the candidate ID and SHA-256 and blocks mutation until reopen.

The returned restore candidate is the committed projection at open time. Physical append does not mutate it; Slice C prepares and publishes the authoritative in-memory projection around journal sync.

No `AgentSession` mutation occurs in this slice.

### Slice C: authoritative AgentSession commit

Implemented through private `src/agent/Commit.zig` and `src/coding_agent/SessionCommit.zig`, with construction kept inside `AgentSessionRuntime`.

- Canonical history now prepares an owned message and both publication capacities before persistence. Its publish operation is allocation-free and infallible.
- `Agent` routes user messages, provider responses, tool results, and completed, failed, cancelled, or interrupted settlement through one commit seam. Ephemeral sessions retain the same admission order without a journal.
- `SessionCommit` owns the journal-backed implementation, emits canonical model changes, closes a restored open turn before admitting another, and installs restored provider-safe context before the session is published.
- Model and tool completion notifications are emitted only after the corresponding durable message has been synced and published.
- Real `FakeTransport` and temporary-directory tests cover a complete tool loop, response and tool-result commit failures, restored interruption followed by cancellation, and exhaustive construction allocation failures.

No session picker, credential file, or executable wiring occurs in this slice.

### Slice D: compaction residency

- Add the Pi-shaped compaction record only with the compaction policy that produces and consumes it.
- Stream cold durable history without hydrating it, retain the exact active suffix, and implement bounded ephemeral cold blocks.
- Test context/presentation projection, corrupted boundaries, allocation failure, and memory/storage ceilings.

This slice may follow initial durable sessions but must precede claiming long-lived bounded-resident resume.

## Behavior and fault coverage

The implementation gates must include:

- create, close, read-only open, writable open, and exact header probe;
- deterministic IDs and timestamps with caller-buffer mutation resistance;
- message/model/turn round trips through the stable wire DTO;
- canonical provider/model recovery and response-identity mismatch rejection;
- tool calls with separate output-item and call IDs, multiple calls, failure results, cancellation between calls, orphan results, duplicates, and name mismatch;
- completed, failed, cancelled, explicit interrupted, and crash-inferred interrupted turns;
- an open turn closed durably before the next resumed turn;
- valid branches in loaded history and invalid/cyclic/forward/missing parents;
- clean EOF, zero-byte tail, partial JSON tail, complete JSON without newline, invalid terminated final record, and invalid interior record;
- failure before write, partial write, flush failure, file-sync failure, rollback truncate failure, rollback-sync failure, creation publish failure, and directory-sync failure;
- stable-ID resolution of an indeterminate complete candidate after reopen;
- every exact and over-limit byte/count/depth/storage case;
- total-storage checked-arithmetic overflow;
- exhaustive allocation failures for prepare, decode, index, and restore;
- cleanup of files, handles, prepared entries, and projections on every failure;
- Debug and ReleaseSafe suites, `ziglint`, `git diff --check`, catalog drift, and the default build.

Wall-clock timing is not an acceptance test. Crash behavior is proved through injected boundary failures and reopening real temporary files.

## Deferred surfaces

- `src/main.zig` and a live network request;
- new/open/continue/resume CLI selection and session listing;
- the private cwd-bound `RuntimeServices` owner;
- persistent `auth.json`, Codex acquisition/refresh, and credential writes;
- process signal handling, terminal shutdown, and bounded settlement;
- branching, forking, labels, custom entries, work plans, extensions, and agent-team entries;
- retries and retry markers;
- compaction until Slice D;
- format 2 image blobs and image-capable provider requests;
- multi-process writers, locks, watermarks, intent files, sidecars, cached projections, and background compaction;
- transparent source-file migration or Pi session-file import.

These are not optional hooks in the first interface. Each joins through its concrete owner when its product behavior is admitted.

## Acceptance

- A persistent journal is the sole durable authority; no second transcript or mutable model state is maintained.
- Pi's header, stable entry, parent-tree, message/model, and active-path semantics are recognizable without inheriting Pi's unsafe file mechanics.
- Fx informs framed recovery and fault testing without introducing its product schema or persistence subsystem.
- ZigAI informs bounded ownership and cleanup without turning the journal into a snapshot store.
- Every externally supplied byte is bounded and validated before publication.
- A complete committed prefix is always restorable; only an unterminated final record is automatically repairable.
- Append success means the record was file-synced and its in-memory projection was published.
- Append uncertainty is explicit and blocks further mutation until reopen resolves it.
- Failed, cancelled, interrupted, and partial tool turns remain durable and cannot be replayed as valid provider context.
- Effective cwd is known before `ZiPaths` and every cwd-bound service are constructed.
- `AgentSession`, `SessionJournal`, codec types, and commit seams remain private unless a later curated SDK contract independently justifies exposure.
- The existing models/configuration worktree is preserved, and the executable remains unchanged.
