# Conversation lifecycle architecture

Status: approved

References:

- `docs/conversation-lifecycle-research.md`
- `docs/conversation-lifecycle-product.md`
- hax behavior revision `189816fb8b02956a6913d7638e6d2cc90a91d61a`
- zig-ai design revision `e2c5aef5f93015322891028a2048a217e7081687`

## Architectural choice

Zi will use two heap-stable sibling owners in `src/cli/`:

- `RunSelection.Owner` continues to own provider, model, effort, prompt, and every
  selection-derived next-turn view.
- A new `ConversationRuntime.Owner` owns the stable live conversation identity and
  coordinates session history with its replaceable authoritative append log.

The two axes remain separate because `/resume` intentionally permits valid history to
commit when recorded selection restoration fails. Combining them into one supposedly
atomic owner would hide that product-level partial success.

`PrintRun` constructs both owners once. Their addresses do not change until process
shutdown.

## Ownership map

```text
PrintRun
├── RunSelection.Owner                     provider/configuration axis
│   ├── ProviderRuntime.Owned
│   ├── PromptAssembly.Value
│   └── borrowed stable ConversationRuntime session/durability
├── ConversationRuntime.Owner              conversation axis
│   ├── stable-address agent.Session
│   ├── stable SessionDurability.Owner
│   │   └── owned optional SessionFile.Log
│   ├── active identity/path
│   ├── immutable RecordingPolicy
│   └── fresh-session factory inputs
├── ToolRuntime.Owner                      process tools and tasks
├── UsageStats                             current process-conversation totals
├── Transcript.Owner                       advisory model-facing mirror
└── terminal presentation adapters         banner, replay, spinner, diagnostics
```

`SessionStartup` becomes a startup candidate builder. Its owned session, optional log,
metadata, and active path move into `ConversationRuntime.Owner`. Startup wrappers no
longer remain the process-lifetime authority.

## Stable conversation owner

`ConversationRuntime.Owner` is the only CLI policy object allowed to publish a change
of conversation identity or history. It owns:

- one `agent.Session` whose outer address never changes;
- one stable `SessionDurability.Owner` whose outer address never changes;
- current identity and active path, including an unrecorded resumed path;
- canonical cwd, state root, writer version, limits, Git probe, and injected timestamp
  and UUID sources for fresh sessions and forks;
- immutable recording policy distinguishing explicit disable from provider-sensitive
  automatic eligibility;
- a monotonically increasing generation;
- transition phase: idle, publishing, or quarantined.

A complete candidate owns every nested allocation until publication. One
`ConversationRuntime.publish` operation is the coordinator for changes spanning both
sibling owners. It acquires a non-reentrant publishing phase, checks conversation and
selection generations, transfers exact fields, immediately invalidates consumed
candidates, increments both generations, and returns replaced owners for cleanup after
publication. The critical section performs no I/O, allocation, or fallible work. It may invoke only
internal publication adapters whose contracts are synchronous, non-reentrant,
allocation-free, and non-failing; they may retain only pointers or slices into the newly
published stable owner, never candidate or retired storage; arbitrary observers and presentation
callbacks remain forbidden. Replaced values are destroyed only after the new values are visible.

This adapts ZigAI's `Conversation.replace` posture without changing Zi's explicit item
ownership into an arena merely for symmetry.

## Stable authoritative durability

`SessionDurability.Owner` becomes mandatory even when recording is disabled. It owns an
optional `SessionFile.Log` instead of borrowing a pointer to startup storage. Every
erased seam call resolves the current owned slot synchronously; no callback can retain
`*SessionFile.Log`.

The owner distinguishes:

- unrecorded: no authoritative file;
- synchronized: log high-water equals live session length;
- pending append: memory is ahead of the durable high-water;
- quarantined: an externally changed or indeterminate log must not receive later
  appends.

Ordinary loop and compaction seams may temporarily create pending append state because
session admission precedes durability. A lifecycle transition normally starts only from
a synchronized or unrecorded state. It first attempts any required reconciliation; a
failure leaves or quarantines the current conversation rather than routing later writes
through uncertain offsets. `/new` and `/resume` may abandon an authority that was already
quarantined when the command began, but never one first quarantined by reconciliation or
task settlement. `/new` replaces a logger only when one is currently owned; it never
recovers an explicitly disabled or already unrecorded run. `/resume` always honors
explicit disable and reevaluates automatic eligibility against the actual post-restore
provider.

Session JSONL remains authoritative. Transcript and terminal output never participate
in this state machine.

## Recording policy

`ConversationRuntime` retains the startup recording intent, not only the current optional
log. Explicit CLI disable is immutable. Automatic mode reevaluates provider eligibility
when resume determines its effective selection.

`/new` follows hax logger continuity: an owned logger becomes a fresh lazy logger; an
unrecorded run remains unrecorded. `/resume` may acquire a locked log while preparing a
stable snapshot, but publishes it only when explicit policy permits recording and the
effective provider is eligible. Otherwise it adopts the verified history as unrecorded.
Provider switching alone does not retroactively create or discard the current
conversation log.

## Agent session contracts

`src/agent/Session.zig` owns provider-neutral history policy. It gains:

- one public typed-turn predicate: an external user message only;
- bounded typed-turn enumeration for picker labels;
- a prepared suffix-cut owner containing generation, original and retained item counts,
  typed-turn counts, context-floor effect, and a borrowed view of the first removed
  external prompt valid until cut publication;
- allocation-free publication of that cut;
- allocation-free replacement by a completely prepared owned session while preserving
  the outer session address.

Preparation validates leases, item invariants, retained accounting, and limits. Cut
publication releases the suffix and recomputes retained bytes, images, pending tool
state, and model-visible context floor without allocation.

The same typed-turn rule is used by `persistence.SessionCut`. The disk parser returns a
cut description containing byte offset, typed-turn count, and retained item-record
count. Before destructive mutation, the coordinator requires the memory and file plans
to agree.

`terminal.PromptHistory` owns the copied recall entry. It exposes prepared admission so
the CLI can allocate and validate recall before file mutation, then publish without
allocation after the session cut. `agent.Session` never imports terminal policy.

## Authoritative file outcomes

Irreversible operations cannot use an error union that implies failure means no change.

Session truncation classifies its result as:

- unchanged: the old size and logical state are confirmed;
- committed: the intended cut is confirmed and memory must publish the matching cut;
- indeterminate: the observed file cannot be proven old or intended, so recording is
  quarantined and the command reports the uncertainty.

Classification verifies the same opened file, expected pre-mutation identity and link
state, original size and content fingerprint, intended cut offset, and observed final
identity. A failed `setLength` followed by the intended size is committed only when
those invariants still identify the expected opened snapshot, no-follow named identity
still matches after mutation, and a post-operation read matches the exact original prefix
through the intended cut. Zi cannot portably lock a pathname against non-cooperating
rename; a race after the immediate pre-check may mutate the held inode, but the
post-check classifies that result indeterminate and quarantines it. Identity and coincidental
size alone are not proof. Unchanged classification likewise verifies the original full
bytes. A different, replaced, unreadable, or content-mismatched target is indeterminate.

Logical mutation and crash durability are reported separately. A confirmed logical cut
requires the matching memory cut even when a later sync fails. Every sync failure moves
a logically committed conversation to quarantined recording: later appends are forbidden
until an explicit reload or abandonment establishes a new authority. There is no
undefined degraded append state.

Fork already models `IndeterminateCleanup`. Every allocation needed after destination
creation—including recall text and presentation facts—is prepared first. Once
`SessionFile.Log.fork` returns a locked destination, live publication cannot fail. The
source lock remains held until the destination is published.

## Selection integration

`RunSelection` gains explicit intent:

- user-persistent selection for `/provider`, `/model`, `/effort`, and preset entry;
- session restore, which changes only the live run tier and never writes `state.json`;
- detached candidate preparation for a conversation not yet live.

Ordinary selection commands retain their current coordinated session/log update.
Detached preparation builds the provider runtime, prompt, tool environment, catalog,
image, context, effort, and presentation facts without staging metadata on the
conversation being left. It contains no `PreparedSelection` tied to either session
address. The detached replacement session and log are normalized directly while owned;
only their completed values cross the coordinated publish boundary.

For resume:

1. prepare recorded selection restoration against the detached history;
2. classify full restoration, core provider/model/effort restoration with a missing or
   invalid preset, or core restoration failure;
3. normalize the detached session and destination log to the effective actual
   selection—restored core selection for the first two outcomes, current selection for
   core failure;
4. publish selection-derived runtime state and conversation state through the single
   coordinated, allocation-free critical section;
5. never invoke `StateWriter` for session restoration.

This produces independent history, core-selection, preset, and recording outcomes. A
restoration warning cannot roll history back.

`/new PRESET` uses user-persistent preset intent, matching hax. Preset validation and
all selection-derived preparation happen before task settlement or conversation reset.

## Task settlement

`ToolRuntime.Owner.finish` already collects terminal task notes, flushes them through
the durability seam, then shuts tasks down. It becomes the shared settlement operation
for process exit, `/new`, and `/resume`.

Task settlement is itself stateful:

- no work;
- settled and durably flushed;
- settled in an unrecorded conversation;
- settled against quarantine that existed when the command began;
- current conversation mutated but flush failed or became indeterminate.

A failure or indeterminacy created by the command keeps the old conversation active and
must not publish a new one. Tasks may already be stopped, and the diagnostic must not
claim a complete no-op. When quarantine existed before command entry, complete task
shutdown may skip its unusable seam and new/resume may replace that authority with an
explicit incomplete-old-branch warning.

`/new PRESET` matches hax’s two commit points: after complete preparation, it publishes
and persists the preset selection first. Task settlement then records against that new
selection in the old conversation. If settlement cannot safely finish, the new preset
remains active while history stays in place, and the command reports that partial
result.

`/undo` and `/compact` do not settle tasks. `/fork` preserves tasks. Task state may retain the stable session and routing-owner
pointers already established by `ToolRuntime`, but never a replaceable log slot or
session contents. Terminal notes are collected synchronously through those stable
owners and therefore enter whichever fork is active at collection time, matching hax.

Zi currently has no product-owned temporary-file registry. The new-conversation
transition exposes an advisory resource-cleanup callback after successful task shutdown;
there is no empty module until image paste or another capability first owns tracked
temporary resources.

## Advisory transcript

This capability lands the first `src/transcript/` module because the already-supported
`HAX_TRANSCRIPT` setting is observable across all five commands.

`transcript/root.zig` exports a provider-neutral owner that:

- renders the model-facing system prompt, tools, items, reasoning metadata, and usage;
- owns a configured path, secure regular-file handle, and independent item high-water;
- supports append and truncate-and-rebuild;
- omits image base64 and encrypted reasoning payloads;
- uses no ANSI escapes;
- enforces named file and rendering bounds;
- opens no-follow, close-on-exec, mode `0600` targets and rejects non-regular files.

Transcript failure is advisory. The owner records a warning/degraded state and never
blocks or rolls back session JSONL, history, selection, or compaction. A later rebuild
may retry opening the retained path.

A heap-stable CLI `RunLogSeam` composes both outputs. Each synchronous call receives the
stable session pointer, borrows the current `RunSelection` snapshot, attempts transcript
append first, consumes transcript errors into a once-per-state warning, then calls the
authoritative durability seam. `SessionDurability.Observer` is not used for transcript
composition. Lifecycle order is different by design: authoritative
new/resume/undo/fork commits first, then transcript rebuild runs best-effort.

Transcript state is clean, degraded, or disabled. An uncertain partial append stops
incremental writes until a complete bounded rebuild succeeds; advisory status does not
permit a fictional high-water mark.

Selection changes rebuild the transcript because system prompt, tools, and selection
facts may change. Compaction appends through the ordinary seam; it does not truncate the
historical transcript prefix.

## Terminal and REPL state

`InteractiveCommands.Owner` owns registry handlers, command validation, picker calls,
and diagnostics. It borrows erased synchronous services for conversation transitions,
manual compaction, prompt-recall preparation, and presentation. Every erased callback documents synchronous borrowing, forbids retention of candidate,
retired, or replaceable log contents, rejects
reentry, and classifies whether it can allocate or fail. Fallible, allocating, advisory, and presentation callbacks run only before preparation
or after publication. Internal publication adapters may run inside only under the
non-failing contract above.

The presentation adapter owns:

- startup banner rendering;
- lifecycle-specific brief replay;
- compaction spinner and outcome marker;
- normal-buffer frame synchronization.

`render.History.replayBrief` accepts a bounded heading rather than hard-coding
`resumed`. Its anchor policy remains external user prompts and compaction seeds only.

Command execution returns effects in addition to handled/exit:

- clear stale pause/retry/interruption state;
- clear deferred compaction and latest context through the appropriate owner;
- publish a prepared recall entry after undo or prefix fork.

`Interactive` remains the owner of its local resume reason. It applies command effects
before reading the next prompt. Lifecycle commands do not reset the process-only
catalog prefetch hook.

## Usage and compaction state

`UsageStats` gains allocation-free operations to:

- reset all totals and retained attempts for `/new`;
- invalidate only the latest ordinary context snapshot for resume, destructive undo,
  prefix fork, and successful compact.

Resume keeps totals already incurred by the current process. Undo and fork retain
cumulative totals. A tip fork retains the latest context snapshot.

The automatic compaction controller gains explicit invalidation and deferred-state
clearing methods. Lifecycle code does not mutate its fields through borrowed knowledge.

## Manual compaction

`/compact` calls only `agent.CompactRunner.run` in standalone mode with the current
`RunSelection` snapshot. It does not create a second summarizer.

A command adapter owns generation interruption and spinner presentation. It suppresses
summary text while still forwarding usage events. Pause and abort both map to the
runner's cancellation sample.

`CompactRunner` returns a commit-classified result even when a later hook or observer
fails:

- no model mutation;
- usage-only mutation;
- compact seed committed.

The result also reports durability and the product outcome: compacted, cancelled,
provider failure, or no summary. If a seed committed, lifecycle state is cleared even
when a post-commit observer failed. Usage-only failure and cancellation remain billed
and durably flushed when possible.

Manual compact prints its own marker and never sets the automatic marker's pending bit.
No duplicate terminal marker is possible.

## Command transitions

### `/new` and `/clear`

```text
prepare optional preset selection and fresh conversation candidate
when supplied, publish and persist preset selection
settle tasks into old conversation under the effective selection
publish empty session and replacement lazy log/unrecorded state without failure
reset usage and continuation/context state
advisory resource cleanup
advisory transcript rebuild
render banner
```

Preparation failure is a no-op. After `/new PRESET` publishes its first hax-compatible
commit, settlement failure retains that preset and the old conversation with an explicit
partial result. Without a preset, settlement failure retains both old selection and
history. The old materialized log is never truncated. A fresh lazy log is prepared only
when the current run already owns a logger.

### `/resume`

```text
index and pick, excluding active path
open and lock before loading a non-empty bounded append candidate
or verify one exact opened read snapshot for unrecorded fallback
prepare detached full/core/current selection outcome
reevaluate recording policy against the effective provider
prepare replay and destination metadata
settle tasks into old conversation
publish loaded session, destination log/unrecorded state, and selection result
release old log
clear continuation/context/deferred state
advisory transcript rebuild
render resumed replay and warnings
```

The successful result independently reports full versus core-only versus kept-current
selection and recorded versus unrecorded append state. A recorded destination is read
under its acquired lifetime lock. An unrecorded fallback is adopted only after the same
opened file snapshot is verified stable; inability to establish a stable snapshot is a
no-op load failure.

### `/undo`

```text
resolve typed-turn target
prepare memory cut + recall + disk cut agreement
truncate authoritative log
  unchanged failure -> discard candidate
  committed -> publish memory cut
  indeterminate -> quarantine recording and report
publish recall and invalidate context when committed
advisory transcript rebuild
render "undid N turn(s)" replay
```

No fallible allocation occurs after a confirmed file cut and before memory publication.

### `/fork`

```text
resolve either explicit tip clone or typed-turn target
(`/fork 0` accepts any non-empty history, including seed-only history)
prepare optional memory cut + recall + presentation facts
create, sync, and lock destination from the verified source prefix
publish destination log and memory prefix without failure
release source log
publish recall and invalidate context only for a prefix fork
advisory transcript rebuild
render "forked" replay
```

A tip fork keeps history and context. Any pre-publication failure preserves the source.
Indeterminate cleanup reports the deterministic candidate path when safely available.

### `/compact`

```text
validate provider/model/history and bounded focus
arm generation interrupt and start compacting spinner
run CompactRunner standalone with routed durability and usage observation
classify model mutation and durability
stop spinner
clear stale state if seed committed
render exactly one product outcome
```

## Retention

Active materialized logs are protected by their exclusive lifetime lock. Resume and
fork acquire the destination lock before publication and release the old lock only
after publication. `SessionIndex` pruning already keeps locked files.

The startup exclusion path remains a race reduction during initial composition, not a
runtime correctness mechanism. Lazy and unrecorded sessions have no active file to
protect.

## Failure model

The architecture separates:

- preparation failures that prove no live change;
- authoritative committed outcomes;
- authoritative indeterminate outcomes requiring quarantine;
- deliberate resume partial success;
- task-settlement partial effects;
- advisory transcript/presentation failures;
- persistent-default failure after user selection, which remains run-only as today.

User diagnostics are derived from these typed outcomes. Catch-all errors cannot cross
an irreversible boundary.

## Bounds

All existing session, file, picker, prompt, image, and compaction limits remain. New
public defaults are:

- transcript file: 256 MiB; an append or rebuild that would exceed it degrades and
  disables incremental transcript output with one warning;
- one transcript-rendered segment: 16 MiB; larger data degrades transcript only;
- active path: 4,096 bytes, reusing `persistence.Paths.default_max_path_bytes`;
- lifecycle diagnostic: 8 KiB; longer provider or I/O diagnostics are safely clipped;
- replay heading: 256 bytes; headings are generated by Zi, not retained user input;
- staged recall: 1 MiB, reusing `terminal.max_prompt_bytes`;
- aggregate prepared turn-picker labels: 1 MiB across at most 200 rows.

A transition retains at most the current session, one complete replacement session, and
one 8 MiB session-file snapshot. Resume loading must decode directly into that candidate
session or transfer decoded item ownership into it; the current loader’s intermediate
deep copy is removed. At default limits the two sessions may each own 64 MiB of
non-image retained data and 256 MiB of image base64; no third complete history copy is
permitted. Allocation failure before publication leaves the current owner unchanged.
Candidates use bounded linear scans; there is no unbounded queue, process-lifetime
arena, or quadratic history copy.

## Module boundaries

- `src/cli/ConversationRuntime.zig`: cross-module lifecycle orchestration.
- `src/cli/InteractiveCommands.zig`: commands, pickers, and diagnostics.
- `src/cli/RunSelection.zig`: selection preparation/publication and persistence intent.
- `src/cli/Interactive.zig`: REPL-local command effects.
- `src/agent/Session.zig`: typed turns, cuts, stable replacement, accounting.
- `src/agent/CompactRunner.zig`: sole compaction transaction and commit classification.
- `src/SessionDurability.zig`: stable optional-log ownership and routed seam.
- `src/persistence/SessionFile.zig`: authoritative JSONL mutation and classified file
  outcomes.
- `src/persistence/SessionCut.zig`: disk cut plan and item-count verification.
- `src/terminal/PromptHistory.zig`: prepared recall admission.
- `src/render/History.zig`: lifecycle brief replay.
- `src/transcript/`: advisory model-facing transcript owner and renderer.
- `src/ToolRuntime.zig`: task settlement.
- `src/cli/PrintRun.zig`: composition only.

Dependencies continue to point inward. `src/main.zig` remains unchanged except through
the public CLI seam.

## Architecture acceptance

- The live `agent.Session` address is stable across every command.
- No erased callback retains a replaceable log pointer.
- Every transition candidate owns all nested data and is allocation-failure safe.
- Session and file cuts use one typed-turn contract and verified retained item counts.
- Every irreversible operation returns a commit-classifying outcome.
- Resume restoration never writes persistent defaults.
- JSONL authority, transcript mirror, and terminal presentation remain separate.
- Task terminal notes are flushed to the conversation being left for new/resume and to
  the active branch when preserved across fork.
- Manual and automatic compaction share one runner without duplicate markers.
- Active files remain retention-safe through locks.
- All public bounds and ready-gate requirements remain enforceable.
