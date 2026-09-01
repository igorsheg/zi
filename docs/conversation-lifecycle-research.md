# Conversation lifecycle research

Status: approved

References:

- hax product and behavior: `189816fb8b02956a6913d7638e6d2cc90a91d61a`
- zig-ai Zig design reference: `e2c5aef5f93015322891028a2048a217e7081687`
- Zi starting point: `6c80ba19`

## Goal and scope

Add the next coherent hax product family to Zi:

- `/new` and its `/clear` alias;
- `/resume`;
- `/undo`;
- `/fork`;
- `/compact`.

Hax defines observable behavior. ZigAI informs Zig 0.16 ownership and transaction
posture. This effort includes the `ZI_TRANSCRIPT` mirror reshaped by these commands.
It does not yet include later preset/config, `/session`, `/tasks`, `/usage`,
clipboard/editor, image-paste, authentication, notification, or keep-awake work.

## Current Zi flow

`src/cli/PrintRun.zig` is the process composition root. It owns the startup session,
optional append log, durability owner, live run selection, tools, compaction inputs,
usage totals, renderers, and command owner. Most of those objects retain pointers for
the process lifetime.

`src/cli/Interactive.zig` classifies slash commands before session admission. Commands
run synchronously between turns while `agent.Session` is idle. A consumed command enters
session-only prompt recall and never reaches model context or the session file.

`src/cli/RunSelection.zig` already provides a construct-then-publish transaction for
provider, model, and effort. It can rebuild all selection-derived state, but it borrows
one stable `agent.Session` and one stable `SessionDurability.Owner`; it cannot replace a
conversation or append log.

`src/agent/Session.zig` owns bounded items and their nested allocations. It already has
leases, reset, selection replacement, context-floor behavior, and aggregate byte/image
accounting. It does not expose typed-turn enumeration or an allocation-free suffix cut.

`src/SessionDurability.zig` coordinates session and log selection. Its erased hook owns
a direct borrowed pointer to one `SessionFile.Log`. Mid-process `/new`, `/resume`, and
`/fork` therefore cannot replace the log without a stable routing owner or safe rebind
operation.

Useful persistence work already exists:

- `src/persistence/SessionFile.zig` loads a resumed session and matching append log;
- `Log.reset` prepares a new lazy log;
- `Log.truncate` cuts a materialized log by typed-turn count;
- `Log.fork` creates and locks an independent branch file;
- `src/persistence/SessionCut.zig` recognizes typed prompts consistently in JSONL;
- `src/persistence/SessionIndex.zig` and `src/cli/SessionPicker.zig` provide the bounded
  current-directory resume picker;
- `src/render/History.zig` already renders bounded brief replay;
- `src/agent/CompactRunner.zig` already implements standalone and continuation
  compaction with bounded retries and transactional seed admission.

The missing center is a stable live-conversation coordinator, not five unrelated
handlers.

## Hax behavior to preserve

### Shared command rules

The registry order in hax `src/slash.c:86-205` is also `/help` order. Recognized
commands remain consumed when validation fails or a picker is cancelled. `/resume`,
`/undo`, `/fork`, and `/compact` use managed normal-buffer presentation. `/new` accepts
an optional preset and `/clear` is an exact alias.

Typed turns mean only ordinary external user prompts. Compaction seeds, continuation
markers, and task notes do not count. Undo and fork must use the same predicate in
memory and on disk.

### `/new` and `/clear`

Hax `src/agent.c:568-591` performs this order:

1. apply an optional preset first; invalid preset leaves the conversation unchanged;
2. announce and settle background tasks into the conversation being left;
3. clear resumable and deferred-compaction state;
4. clear history while retaining the live selection;
5. reset the transcript and prepare a new lazy session identity;
6. clean tracked temporary files only after tasks stop;
7. reset all process-session usage statistics;
8. render the normal startup banner.

The old session remains resumable. The new session file is lazy and does not exist
until productive history is appended. Selection survives unless the optional preset
changes it. Prompt recall remains process-local.

A narrower Zig safety contract may report failure when Zi cannot prepare the new
identity or session owner. It must not expose half-reset live state.

### `/resume`

Hax `src/slash.c:314-334` opens a current-directory picker, newest first, excluding the
active session. Cancellation and load failure leave the current conversation intact.
The picker retains at most 200 rows and labels scan at most 64 KiB.

Hax `src/agent.c:679-734` loads non-empty history before disturbing the current run,
then settles old tasks, closes the old log, attempts recorded selection restoration,
adopts history even when selection restoration fails, reopens the selected file for
append, stages the actual live selection, rebuilds the transcript, clears stale
continuation/compaction state, and briefly replays the latest visible user turn.

Resume does not restore historical usage totals and does not reset current-process
totals. It keeps tracked temporary files because branches may share their paths. A
selected file that cannot be reopened remains live in memory but becomes unrecorded.

Zi intentionally keeps its existing bounded, fail-closed session loader rather than
copying hax's unbounded `getline` behavior.

### `/undo`

Bare `/undo` opens `revert to before which message`; noninteractive use requires an
explicit count. `/undo N` accepts `1..turn_count`, where `1` removes the newest typed
turn. Empty history reports `nothing to undo yet`.

Hax `src/agent.c:776-831` computes the cut before the selected prompt and its preceding
turn boundary, truncates the session file first, and mutates memory only after durable
truncation succeeds. Recording-disabled or unmaterialized logs treat truncation as a
successful no-op.

After commit, hax:

- stages the first removed prompt for editor recall;
- frees the suffix;
- clears continuation and deferred-compaction state;
- invalidates only the latest context snapshot, not cumulative billed usage;
- rebuilds the transcript;
- briefly replays retained history under `undid N turn(s)`.

Temporary files and cumulative usage totals are retained.

### `/fork`

Fork shares undo's picker and typed-turn rules. `/fork N` accepts `0..turn_count`;
zero clones the current tip. Bare fork still needs a typed prompt. Fork requires a
materialized session log.

Hax `src/agent.c:834-883` and `src/session.c:878-997` preserve the source branch by:

1. computing the in-memory and file prefix;
2. copying that prefix into a private new file;
3. rewriting its UUID and timestamp and adding `forked_from`;
4. opening the new file for append before closing the source log;
5. staging the actual live selection for the next append;
6. switching logs without truncating the source;
7. cutting memory, staging recall text when a suffix was removed, rebuilding the
   transcript, and replaying `forked`.

A tip fork keeps the current context snapshot. A prefix fork invalidates it. Cumulative
usage remains. Existing tasks and temporary files remain in hax, though Zi must prevent
an old background task from appending into the new logical branch.

### `/compact`

Manual compaction works even when automatic compaction is disabled. The optional
argument becomes additional summary focus. Missing provider/model and empty history
produce notices without a request.

Hax `src/agent.c:885-1037` and `src/compact.c`:

- compact only the model-visible window beginning at the newest seed;
- advertise tools for request-prefix stability but reject every requested tool;
- make at most four provider attempts;
- retain usage from every terminal attempt, including rejected, failed, or cancelled
  attempts;
- admit only the final non-empty, complete, tool-free summary;
- append a boundary, compact seed, and accepted usage without deleting old history;
- treat pause and abort alike because compaction has no pause seam;
- let a late cancellation override a complete streamed summary;
- reset latest context and stale continuation/deferred state only on success;
- render a spinner, suppress live summary text, then show exactly one outcome marker.

Visible outcomes are `conversation compacted`, `compaction cancelled`,
`compaction failed: ...`, and `compaction produced no summary`.

## ZigAI posture to adopt

ZigAI does not implement these product commands. Its useful contribution is ownership
shape, especially `src/graph_agent.zig:152-215`:

- reusable agent configuration borrows dependencies and does not own conversation
  history;
- canonical message values borrow nested slices;
- one explicit conversation owner contains a complete deep-copied snapshot;
- replacement constructs the entire next snapshot before releasing the old one;
- scratch arenas serve preparation, while the committed owner controls the durable
  lifetime;
- owning `deinit` methods release once and set `self.* = undefined`;
- erased interfaces expose synchronous behavior without hiding ownership;
- allocation-failure tests exercise every owning constructor and replacement.

Zi should adapt that posture rather than its exact arena layout. `agent.Session` already
has explicit item destructors and strict retained-data accounting, so a prepared move
or rebuilt owner can be clearer and cheaper than converting it wholesale to an arena.
The crucial rule is construct first, publish without failure, then destroy the old
state.

## Required architecture

The current pointers make replacing `SessionStartup.Run` unsafe. A process-owned,
heap-stable conversation coordinator should own or route:

- one stable-address `agent.Session`;
- the optional active `SessionFile.Log`;
- the active path and resume identity;
- state-root, cwd, writer version, timestamp, UUID, and Git inputs for fresh sessions;
- one stable durability seam that resolves the current log at call time;
- prepared transitions for new, resume, undo, and fork;
- callbacks for task settlement, transcript rebuild, replay/banner presentation,
  context snapshot invalidation, and usage reset.

The coordinator belongs in `src/cli/`: it is cross-module process policy. Pure typed
turn and suffix-cut policy belongs in `src/agent/Session.zig`; JSONL mutation remains
in `src/persistence/SessionFile.zig`; compaction remains provider-independent in
`src/agent/CompactRunner.zig`.

No command may move the stable session address. No erased callback may retain a pointer
to a replaceable optional log.

## Transaction boundaries

- **New:** fully prepare fresh identity/log state and any optional selection change,
  settle old tasks, then publish empty history and the new lazy log together.
- **Resume:** load and validate an owned candidate first; prepare recorded selection
  restoration independently; settle old tasks; publish candidate history/log through
  stable owners; then apply the hax-compatible restore outcome.
- **Undo:** prepare an allocation-free session cut; perform file truncation first;
  publish the cut only when no later fallible operation can break session/log equality.
- **Fork:** create and lock the destination before changing live state; prepare an
  allocation-free cut and log adoption; publish both together; preserve the source.
- **Compact:** reuse `CompactRunner.run`; its accepted seed remains the sole history
  transaction. Command code owns only interruption, usage observation, spinner, and
  outcome presentation.

Irreversible file operations require explicit outcome types. `IndeterminateCleanup`
or post-truncate reconciliation failures must not be flattened into ordinary errors.

## Bounds

Zi keeps its existing narrower safety limits:

- 16,384 in-memory items, 64 MiB retained item bytes;
- 256 images and 256 MiB encoded image data;
- 8 MiB session file and line limits, 4,096 loaded items, 64 MiB decoded retention;
- 4,096 indexed sessions; 200 picker rows; 64 KiB label scan;
- 4,096 typed turns in cut parsing;
- 1 MiB command line and prompt recall entries;
- four compaction attempts and 64 KiB focus/summary/final text.

Every new retained queue, path, prompt copy, and serialized candidate must have a named
bound. Linear scans are appropriate at these limits and keep state transitions easy to
reason about.

## Risks to resolve in design

1. Session and durability addresses are retained across `PrintRun`; replacement must
   happen through stable owners.
2. Old background tasks can append notes into a newly adopted conversation unless
   transitions settle or isolate them.
3. Session/log high-water marks must remain equal after undo, fork, resume, and every
   later append.
4. A failed or concurrent filesystem mutation must not produce memory/file divergence.
5. Removing the newest compact seed changes the model-visible context floor.
6. Resume selection restoration can fail while history adoption succeeds in hax; Zi
   needs an explicit partial-success result rather than hidden rollback.
7. Retention currently has a startup-only exclusion path; an active resumed or forked
   file needs lock-based or dynamically routed protection.
8. Normal-buffer output is append-only. Replay and diagnostics cannot erase old output.
9. Manual compaction must not duplicate automatic marker or durability callbacks.
10. Optional `/new <preset>` depends on the later preset command surface but can reuse
    existing preset lookup and `config.Selection` preparation without implementing
    `/preset` itself.

## Verification direction

- Pure typed-turn and cut tests across boundaries, seeds, continuations, task notes,
  images, tool records, and usage footers.
- Allocation-failure tests proving every candidate leaves the live owner unchanged.
- Durability tests for disabled, lazy, resumed, materialized, poisoned, externally
  changed, and removed logs.
- Fork tests proving source immutability, destination identity, independent future
  appends, and cleanup classification.
- Resume tests proving picker cancellation and malformed candidates are no-ops while
  selection restoration failure still adopts valid history.
- Compaction tests for all four outcomes, late cancellation, tool-call rejection,
  attempt usage, and same-file persistence.
- PTY probes for normal-buffer picker, recall, replay, spinner, interruption, cursor,
  and terminal restoration.
- Highest-level binary probes plus the complete project ready gate.

## Approved decisions

- This effort is the five-command conversation-lifecycle family. Later command and
  terminal-feature clusters remain separate work.
- Resume matches hax partial success: valid history is adopted even when recorded
  provider restoration fails.
- Background tasks match hax: settle them before `/new` and `/resume`, and preserve
  them across `/fork`.
- `/new <preset>` ships through existing preset lookup while `/preset` remains a later
  command.
