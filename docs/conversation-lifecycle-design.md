# Conversation lifecycle program design

Status: draft for review

References:

- `docs/conversation-lifecycle-research.md`
- `docs/conversation-lifecycle-product.md`
- `docs/conversation-lifecycle-architecture.md`

## File tree

```text
src/
├── agent/
│   ├── Session.zig                 MODIFY typed turns, prepared cuts/replacement
│   ├── CompactRunner.zig           MODIFY commit-classified results
│   └── root.zig                    MODIFY register public additions
├── cli/
│   ├── ConversationRuntime.zig     NEW stable conversation coordinator
│   ├── RunLogSeam.zig              NEW transcript + durability composition
│   ├── TurnPicker.zig              NEW typed-turn picker adapter
│   ├── InteractiveCommands.zig     MODIFY lifecycle handlers and registry order
│   ├── Interactive.zig             MODIFY history-changed command outcome
│   ├── RunSelection.zig            MODIFY detached and restore candidates
│   ├── SessionStartup.zig          MODIFY temporary startup candidate transfer
│   ├── SessionPicker.zig           MODIFY reusable active-path exclusion seam
│   ├── PrintRun.zig                MODIFY stable-owner composition only
│   └── root.zig                    MODIFY test-register new internal files
├── config/
│   └── Selection.zig               MODIFY prepared preset/restore overlays
├── persistence/
│   ├── SessionCut.zig              MODIFY verified cut plan
│   └── SessionFile.zig             MODIFY direct adoption and classified mutations
├── render/
│   └── History.zig                 MODIFY caller-supplied replay heading
├── terminal/
│   └── PromptHistory.zig           MODIFY public prepared session admission
├── transcript/
│   ├── root.zig                    NEW public package seam
│   ├── Renderer.zig                NEW bounded plain model-facing formatter
│   ├── Owner.zig                   NEW advisory secure file owner
│   └── SecureOpen.zig              NEW erased writable capability
├── SecureOpen.zig                  MODIFY production transcript writer adapter
├── SessionDurability.zig           MODIFY stable optional-log ownership
├── ToolRuntime.zig                 MODIFY typed task-settlement outcome
├── THIRD_PARTY_NOTICES.md          MODIFY lifecycle/transcript attribution
└── root.zig                        MODIFY export transcript package
```

No new top-level empty module is introduced. `src/transcript/` lands with its first
working capability. `ConversationRuntime`, `RunLogSeam`, and `TurnPicker` remain CLI
internal and are registered through `src/cli/root.zig` tests.

## Move-only conventions

Every prepared or retired value has:

- one owning allocator where needed;
- an `active` flag;
- `deinit` that releases only while active and sets `self.* = undefined`;
- a publish operation that moves fields and leaves a valid inactive sentinel;
- generation and owner-address assertions before mutation.

Zig assignments copy bits, so move operations are explicit methods. Publication sets
`active = false` but does not set the whole source to undefined; unconditional deferred
`deinit` remains safe and then sets `self.* = undefined`. No owning struct is returned
while another active value aliases its allocations.

All publication sections are allocation-free, I/O-free, non-failing, and non-reentrant.
They may invoke only internal publication adapters explicitly documented as synchronous,
allocation-free, non-failing, and non-reentrant. Adapters may retain pointers or slices
only into the newly published stable owner, never candidate or retired storage. Fallible observers,
persistence, transcript, presentation, and cleanup run afterward.

## `agent.Session`

### History generation and typed turns

Add a `history_generation: u64` beside `selection_generation`. Every successful history
mutation increments it. Complete replacement increments both generations because it
invalidates every outstanding cut and selection candidate.

```zig
pub fn historyGeneration(self: *const Session) u64;
pub fn selectionGeneration(self: *const Session) u64;

pub fn isTypedTurn(item: ai.Item.Item) bool;
pub fn typedTurnCount(self: *const Session) usize;

pub const TypedTurn = struct {
    ordinal: usize,
    item_index: usize,
    text: []const u8,
};

pub fn typedTurn(self: *const Session, ordinal: usize) ?TypedTurn;
```

`isTypedTurn` is true only for `.user_message` with `.external` origin. The returned
text is borrowed until the next session mutation.

### Prepared suffix cut

```zig
pub const CutEffect = struct {
    old_context_floor: usize,
    new_context_floor: usize,
    invalidates_context: bool,
};

pub const PreparedCut = struct {
    owner: *Session,
    generation: u64,
    original_items: usize,
    retained_items: usize,
    original_typed_turns: usize,
    retained_typed_turns: usize,
    retained_bytes: usize,
    retained_images: usize,
    retained_image_base64_bytes: usize,
    first_removed_prompt: ?[]const u8,
    effect: CutEffect,
    active: bool = true,

    pub fn deinit(self: *PreparedCut) void;
};

pub fn prepareTypedCut(
    self: *Session,
    retained_typed_turns: usize,
) (Error || error{InvalidTurnCount})!PreparedCut;

pub fn publishTypedCut(self: *Session, prepared: *PreparedCut) void;
```

Preparation requires an idle session, locates the first removed typed prompt, includes
its immediately preceding turn boundary, scans the retained prefix, and precomputes all
accounting. It owns no terminal recall bytes. `first_removed_prompt` stays borrowed only
while the generation is unchanged.

Publication verifies owner, generation, original item count, active state, and idle
lease; deinitializes the suffix; installs accounting; increments history generation;
and consumes the candidate without allocation.

### Complete replacement

```zig
pub const PreparedReplacement = struct {
    owner: *Session,
    history_generation: u64,
    selection_generation: u64,
    replacement: Session,
    active: bool = true,

    pub fn deinit(self: *PreparedReplacement) void;
};

pub const Retired = struct {
    session: Session,
    active: bool = true,

    pub fn deinit(self: *Retired) void;
};

pub fn prepareReplacement(
    self: *Session,
    replacement: *Session,
) Error!PreparedReplacement;

pub fn publishReplacement(
    self: *Session,
    prepared: *PreparedReplacement,
) Retired;
```

Preparation consumes `replacement` only on success. Publication keeps the outer
`*Session` address and carries generations forward from the replaced owner.

### Prepared compact seed

```zig
pub const PreparedCompactSeed = struct {
    owner: *Session,
    generation: u64,
    seed_item: ai.Item.Item,
    usage: PreparedUsage,
    retained_bytes: usize,
    image_count: usize,
    image_base64_bytes: usize,
    active: bool = true,

    pub fn deinit(self: *PreparedCompactSeed) void;
};

pub fn prepareCompactSeed(
    self: *Session,
    text: []const u8,
    usage: *PreparedUsage,
) Error!PreparedCompactSeed;

pub fn publishCompactSeed(
    self: *Session,
    prepared: *PreparedCompactSeed,
) void;

pub const RetiredCompactSeed = struct {
    item: ai.Item.Item,
    allocator: std.mem.Allocator,
    active: bool = true,

    pub fn deinit(self: *RetiredCompactSeed) void;
};

pub fn publishCompactUsageOnly(
    self: *Session,
    prepared: *PreparedCompactSeed,
) RetiredCompactSeed;
```

Preparation owns the copied seed text, reserves capacity, and consumes the exact
`PreparedUsage` only on success; preparation failure leaves usage active. The resulting owner has two allocation-free commit alternatives: seed plus that exact
usage, or usage only when final cancellation wins. Usage-only publication moves the
discarded seed item into `RetiredCompactSeed`; the caller deinitializes it after leaving
the commit section. Both alternatives assert owner/history generation and consume once.

### Direct loader adoption

```zig
pub fn initAdoptingItems(
    allocator: std.mem.Allocator,
    options: Options,
    items: *std.ArrayList(ai.Item.Item),
) Error!Session;
```

The list backing allocation and every nested item allocation must have been created by
the exact `allocator` argument; this is a documented caller invariant and is asserted in
test adapters. It validates and computes accounting before taking the list allocation.
On success it sets `items.* = .empty`; on error the caller still owns every item.
`SessionFile` uses
this after malformed-tail, dangling-tool, and image recovery, removing its current
second deep copy.

## `terminal.PromptHistory`

Make the existing prepared transaction public without changing behavior:

```zig
const PreparedValue = union(enum) {
    noop,
    promote_newest,
    replace: struct {
        owned_entry: []u8,
        duplicate_index: ?usize,
        evict_oldest: bool,
    },
};

pub const PreparedAdmission = struct {
    owner: *PromptHistory,
    allocator: std.mem.Allocator,
    generation: u64,
    admission: Admission,
    value: PreparedValue,
    active: bool = true,

    pub fn deinit(self: *PreparedAdmission) void;
};

pub fn prepareAdmission(
    self: *PromptHistory,
    entry: []const u8,
    admission: Admission,
) error{OutOfMemory}!PreparedAdmission;

pub fn validateAdmission(
    self: *const PromptHistory,
    prepared: *const PreparedAdmission,
) error{StaleAdmission}!void;

pub fn publishAdmission(
    self: *PromptHistory,
    prepared: *PreparedAdmission,
) void;
```

`PromptHistory` adds a generation incremented by every admission, seed, navigation draft
replacement, or deinit-relevant mutation. The candidate’s captured admission mode is authoritative; validation accepts no second
mode argument and publication uses that stored mode. `validateAdmission` verifies owner,
allocator, generation, and active state before the authoritative file step. Publication
asserts the same facts and consumes without allocation or failure before trusting
reserved capacity or duplicate indexes. The internal `PreparedValue` is not public API.
Generation increments exactly once after every successful mutation of entries,
`newest_unpersisted`, draft, or position. Undo and prefix fork prepare `.session`
admission before file mutation and publish it after the memory cut; no other history
mutation may interleave while the synchronous command owns the plan. Null prompt history in cooked mode is an allocation-free no-op.
The normal exact-duplicate and 1,000-entry eviction policies remain authoritative.

## `persistence.SessionCut`

Replace the offset-only result with a verified plan:

```zig
pub const Fingerprint = [32]u8;

pub const Plan = struct {
    original_size: u64,
    cut_offset: u64,
    original_typed_turns: usize,
    retained_typed_turns: usize,
    retained_item_records: usize,
    original_fingerprint: Fingerprint,
    retained_fingerprint: Fingerprint,
};

pub fn plan(
    allocator: std.mem.Allocator,
    jsonl: []const u8,
    retained_typed_turns: usize,
    limits: Limits,
) Error!Plan;
```

The parser applies the same malformed-record and dangling-tool recovery as session load
when computing `retained_item_records`. It imports the public agent typed-turn predicate
through `agent/root.zig`, not a leaf file. Memory and disk retained item counts must
match before truncate or fork.

## `persistence.SessionFile`

### Authoritative cut preparation

```zig
pub const PreparedCut = struct {
    owner: *Log,
    generation: u64,
    plan: SessionCut.Plan,
    opened_identity: FileIdentity,
    named_identity: FileIdentity,
    link_count: u64,
    original_size: u64,
    stat_token: StatToken,
    active: bool = true,

    pub fn deinit(self: *PreparedCut) void;
};

pub fn prepareCut(
    self: *Log,
    retained_typed_turns: usize,
) CutError!PreparedCut;
```

`FileIdentity` and `StatToken` are platform-adapted value types derived from the opened
handle and no-follow named stat. `prepareCut` requires matching opened/named identity,
regular kind, nonzero link count, expected log size, and a stable token, then reads,
stats, and fingerprints through the active locked log handle; callers
never reopen `Log.path()`. Truncate and fork validate owner/generation, repeat a no-follow named stat immediately
before mutation, require it to match both prepared identities and the opened handle, then
re-read that same handle against the plan. Missing or replaced names at the immediate pre-check return without mutation. A
non-cooperating rename between that check and descriptor mutation cannot be prevented
portably; the mandatory post-mutation named/open identity check classifies it
indeterminate and quarantines the held log.

### Classified truncate

```zig
pub const MutationDurability = enum { synced, sync_failed };

pub const TruncateUnchanged = enum { set_length_failed_verified_original };

pub const TruncateIndeterminate = enum {
    changed,
    removed,
    replaced,
    unreadable,
    content_mismatch,
};

pub const TruncateOutcome = union(enum) {
    unchanged: TruncateUnchanged,
    committed: struct {
        durability: MutationDurability,
        retained_items: usize,
    },
    indeterminate: TruncateIndeterminate,
};

pub fn truncatePrepared(
    self: *Log,
    prepared: *PreparedCut,
    retained_items: usize,
) TruncateError!TruncateOutcome;
```

The error set contains only failures proven before possible mutation: allocation,
bounds, invalid plan, or already-poisoned authority. After `setLength` returns, the
opened file is revalidated by identity, link state, size, and exact bytes:

- unchanged requires the complete original bytes;
- committed requires the exact original prefix;
- every other state is indeterminate.

A confirmed cut updates logical offset and high-water even when sync fails. The caller
publishes the matching memory cut, then quarantines that logger.

### Classified append

```zig
pub const AppendFailure = enum {
    path_collision,
    lock_failed_after_create,
    identity_changed,
    partial_write,
    verification_failed,
    cleanup_indeterminate,
};

pub const AppendOutcome = union(enum) {
    unchanged,
    committed: MutationDurability,
    indeterminate: AppendFailure,
};

pub fn appendSnapshotClassified(
    self: *Log,
    from: usize,
    items: []const ai.Item.Item,
) AppendError!AppendOutcome;
```

`AppendError` contains only allocation, serialization, bounds, and failures proven
before any create/open mutation. Once exclusive creation succeeds, every later lock,
permission, named/open identity, stat, header/item population, verification, close, file
sync, cleanup, and parent-directory sync failure returns `AppendOutcome`. A preexisting
exclusive-create collision is indeterminate/quarantined rather than retryable.

A fully synced first materialization is committed. If exact intended header/items are
verified but file or directory sync fails, it is committed with `.sync_failed`, advances
high-water, and quarantines. `.unchanged` requires proof that cleanup removed the exact
inode created by this attempt, the named path is absent, and the parent directory synced.
Partial or mismatched population and unconfirmed cleanup are indeterminate and
quarantine. Confirmed `.unchanged` cleanup leaves durability in `pending_append` and
`reconcile` returns `.retryable(.io_retryable)`; it never masquerades as synchronized.

For an existing log, after positional write begins the same opened-file identity and
exact expected old or intended final bytes classify unchanged, committed, or
indeterminate. Committed updates high-water even when sync fails; sync failure then
quarantines.

### Stable resume loading

```zig
pub fn loadLockedForResume(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limits: Limits,
) Error!ResumeLoaded;

pub fn loadStableForResume(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limits: Limits,
) Error!Loaded;
```

Both open no-follow and verify one exact bounded snapshot through the same handle.
Locked loading acquires an exclusive lifetime lock before reading and transfers the
handle to `Log`. Stable unrecorded loading verifies identity, timestamps, link state,
size, and exact bytes before closing. No path-based second read establishes authority.

The loader decodes directly into an adopting session. Torn-final-newline repair is
staged for the next positional append rather than mutating during load.

### Classified fork

```zig
pub const ForkDestinationFailure = enum {
    destination_write,
    destination_verify,
    destination_sync,
    directory_sync,
};

pub const ForkValue = union(enum) {
    ready: Log,
    unchanged: ForkDestinationFailure,
    source_indeterminate: enum { source_changed },
    cleanup_indeterminate: struct {
        path: []u8,
        failure: ForkDestinationFailure,
    },
    source_and_cleanup_indeterminate: struct {
        path: []u8,
        destination_failure: ForkDestinationFailure,
    },
};

pub const ForkOutcome = struct {
    value: ForkValue,
    allocator: std.mem.Allocator,
    active: bool = true,

    pub fn deinit(self: *ForkOutcome) void;
    pub fn takeReady(self: *ForkOutcome) ?Log;
};

pub fn forkPrepared(
    self: *Log,
    prepared: *PreparedCut,
    retained_items: usize,
    timestamp: Paths.Timestamp,
    uuid: [16]u8,
    live_selection: Selection,
) Error!ForkOutcome;
```

Every caller allocation is complete before destination creation. `.ready` owns a
synced, directory-synced, locked destination. Cleanup-indeterminate owns the
4,096-byte-bounded deterministic path for diagnostics. Source-indeterminate poisons the source authority. If final source verification and
destination cleanup both become indeterminate, the compound variant both quarantines the
source and retains the bounded orphan path.

## `SessionDurability.Owner`

The owner becomes mandatory and owns the replaceable optional log:

```zig
pub const QuarantineReason = enum {
    external_change,
    removed,
    append_indeterminate,
    truncate_indeterminate,
    sync_failed,
    high_water_diverged,
};

pub const Authority = union(enum) {
    unrecorded,
    active: persistence.SessionFile.Log,
    quarantined: struct {
        log: persistence.SessionFile.Log,
        reason: QuarantineReason,
    },
};

pub const State = union(enum) {
    unrecorded,
    synchronized: usize,
    pending_append: struct { durable: usize, memory: usize },
    quarantined: QuarantineReason,
};

pub fn create(
    allocator: std.mem.Allocator,
    log: *?persistence.SessionFile.Log,
    options: Options,
) CreateError!*Owner;

pub fn state(self: *const Owner, session: *const agent.Session.Session) State;
pub fn activePath(self: *const Owner) ?[]const u8;
pub fn materialized(self: *const Owner) bool;
pub fn resumeHint(self: *const Owner) ?[]const u8;
pub fn generationValue(self: *const Owner) u64;
pub fn seamHook(self: *Owner) agent.Loop.SeamHook;

pub const ReconcileFailure = enum {
    out_of_memory,
    serialization_failed,
    bounded_output,
    io_retryable,
};

pub const ReconcileOutcome = union(enum) {
    synchronized,
    unrecorded,
    retryable: ReconcileFailure,
    quarantined: QuarantineReason,
};

pub fn reconcile(
    self: *Owner,
    session: *const agent.Session.Session,
) ReconcileOutcome;
```

`create` consumes `log` on success. A quarantined logger stays owned and locked until
replacement or shutdown. The seam resolves the current authority on every call.
Unrecorded is a no-op; memory behind or an indeterminate append quarantines; memory
ahead remains an explicit pending append after retryable pre-write failure.

`reconcile` retries a pending append through the classified API. It never releases a
quarantined authority. `/new` and `/resume` call it before preparation or task
settlement. Undo, fork, and ordinary selection require synchronized or unrecorded state.
New and resume may explicitly replace quarantined authority after they establish their
new candidate and complete task settlement; operation-aware publication permits that
replacement while other operations remain blocked.

Log replacement uses prepared move-only values:

```zig
pub const PreparedAdoption = struct { /* owner, generation, replacement */ };
pub const RetiredAuthority = struct { /* old Authority, active */ };

pub fn prepareAdoption(
    self: *Owner,
    replacement: *?persistence.SessionFile.Log,
) error{StaleGeneration}!PreparedAdoption;

pub fn publishAdoption(
    self: *Owner,
    prepared: *PreparedAdoption,
) RetiredAuthority;

pub fn quarantine(self: *Owner, reason: QuarantineReason) void;
```

Prepared selection contains session replacement and optional log selection replacement.
Unrecorded authority updates only session metadata. Quarantined authority rejects
ordinary selection staging.

## `config.Selection` and `RunSelection`

### Prepared overlays

Add construct-then-publish APIs mirroring `prepareRun`:

```zig
pub const PreparedPreset = struct {
    allocator: std.mem.Allocator,
    run_document: ?Document,
    conversation_document: ?Document,
    run_tint: ?[]u8,
    conversation_tint: ?[]u8,
    base_options: Store.Options,
    active: bool = true,

    pub fn store(self: *const PreparedPreset) Store;
    pub fn deinit(self: *PreparedPreset) void;
};

pub const PreparedRestore = struct {
    allocator: std.mem.Allocator,
    run_document: ?Document,
    conversation_document: ?Document,
    run_tint: ?[]u8,
    conversation_tint: ?[]u8,
    outcome: RestoreOutcome,
    base_options: Store.Options,
    active: bool = true,

    pub fn store(self: *const PreparedRestore) Store;
    pub fn deinit(self: *PreparedRestore) void;
};

pub fn preparePreset(
    self: *const Selection,
    tier: Tier,
    plan_value: *const Preset.Plan,
) Error!PreparedPreset;

pub const RetiredOverlay = struct {
    allocator: std.mem.Allocator,
    run_document: ?Document,
    conversation_document: ?Document,
    run_tint: ?[]u8,
    conversation_tint: ?[]u8,
    active: bool = true,

    pub fn deinit(self: *RetiredOverlay) void;
};

pub fn publishPreset(
    self: *Selection,
    prepared: *PreparedPreset,
) RetiredOverlay;

pub fn prepareRestoreConversation(
    self: *const Selection,
    metadata: RestoreMetadata,
    lookup: ?*const Preset.Lookup,
) Error!PreparedRestore;

pub fn publishRestoreConversation(
    self: *Selection,
    prepared: *PreparedRestore,
) RetiredOverlay;
```

Run-tier preset preparation owns both its new run document/tint and the replacement
conversation document/tint that clears any resumed stance and prompt fields. Restore
preparation owns every document/tint it may replace. Cancellation deinitializes all four
optional values. Publication moves old
documents/tint into `RetiredOverlay`; it never frees them inside the critical section.
Existing direct wrappers deinitialize the retired overlay immediately after publication. Neither type stores a
pointer into its own document; each derives prospective `Store.Options` from its current
address after any return or move. Existing `applyPreset` and `restoreConversation`
delegate to prepare plus publish. Restore outcome remains `restored`, `no_preset`, `missing_preset`, `invalid_preset`, or
`mismatched_preset` after core provider/model/effort preparation.

### Detached run candidate

```zig
pub const Intent = enum { user_persistent, session_restore };

pub const DetachedCandidate = struct {
    owner: *Owner,
    generation: u64,
    allocator: std.mem.Allocator,
    config_overlay: ConfigOverlay,
    built: Built,
    requested: RequestedSelection,
    session_selection: agent.Session.Selection,
    log_selection: persistence.SessionFile.Selection,
    tool_selection: tool.Bash.RunSelection,
    intent: Intent,
    active: bool = true,

    pub fn deinit(self: *DetachedCandidate) void;
};

pub fn prepareDetached(
    self: *Owner,
    request: Request,
    intent: Intent,
) PrepareError!DetachedCandidate;
```

`ConfigOverlay` is a tagged union of prepared run, preset, or restore overlay. A
detached candidate has no `PreparedSelection` tied to a session address.

Ordinary provider/model/effort preparation wraps the detached value with current
session/durability selection staging. `RunSelection.commitLive` remains a separate
selection-only guarded publication path. It validates the candidate owner plus the
RunSelection, session-selection, and durability generations, then publishes under its
own non-reentrant phase. It releases that phase before state persistence, transcript
rebuild, notices, and retired-value cleanup. It does not acquire or require a
`ConversationRuntime.PublishLease`; that lease is only for a conversation replacement or
cut.

`/new PRESET` uses this live wrapper, not a bare detached candidate. The wrapper has two
projections over the same prepared selection: the live old-branch commit and borrowed
effective values used to construct the detached fresh session and lazy log. The live
commit publishes config, runtime, tools, current session selection, and current log
selection together before task settlement. It consumes the wrapper's publishable
selection state. The later `publishNew` candidate therefore carries no detached
selection to publish a second time; it carries only fresh conversation values already
normalized to the committed effective selection.

Under quarantine that existed at command entry, `preparePresetForTransition` creates an
operation-specific session-only live wrapper. Its commit updates stable old-memory
metadata, skips the unusable log metadata update, and records an incomplete-old-branch
warning. Ordinary selection commands still reject quarantine. Existing selection-command
behavior remains.

```zig
pub fn publishDetached(
    self: *Owner,
    candidate: *DetachedCandidate,
) RetiredRuntime;
```

This internal publication asserts candidate owner and generation against the
`PublishLease` selection pointer after `beginPublish` validation and performs no I/O; it invokes only
the existing config, tool, and view publication adapters after their contracts are
tightened to allocation-free, non-failing, and non-reentrant. View retention is limited
to newly published stable owner fields. It is
called only inside `ConversationRuntime`'s coordinated publish after guards were
checked. It returns retired runtime/config values, including `config.Selection.RetiredOverlay`,
for cleanup outside.

StateWriter, retired-value destruction, transcript rebuild, notices, and observers are
separate post-publication steps. `session_restore` never invokes `StateWriter`.
User-persistent preset publication writes state only after its live commit and retains
the current once-only run-only warning policy.

## `SessionStartup` and recording policy

`SessionStartup.start` returns a temporary move-only value instead of a heap-stable live
run:

```zig
pub const Identity = struct {
    active_path: ?[]u8,
    id: ?[]u8,
    origin: enum { fresh, resumed },

    pub fn deinit(self: *Identity, allocator: std.mem.Allocator) void;
};

pub const Candidate = struct {
    allocator: std.mem.Allocator,
    session: agent.Session.Session,
    log: ?persistence.SessionFile.Log,
    identity: Identity,
    meta: ?persistence.SessionFile.Meta,
    recovery: ?persistence.SessionFile.Recovery,
    index_recovery: ?persistence.SessionIndex.Recovery,
    warning: ?Warning,
    active: bool = true,

    pub fn deinit(self: *Candidate) void;
};
```

Warning paths and identity are owned; nothing borrows a destroyed `Resolved`.
`SessionStartup.zig` does not import `ConversationRuntime.zig`; runtime creation converts
and moves the startup-local identity, avoiding a file import cycle.

```zig
pub const RecordingPolicy = enum {
    disabled,
    enabled,
    automatic,

    pub fn permits(self: RecordingPolicy, provider: []const u8) bool;
};
```

`PrintRun` derives policy before collapsing current startup behavior:

- CLI `--no-session` or true setting: disabled;
- `no_session=auto`: automatic;
- false/absent: enabled.

The startup `no_session` boolean remains `!policy.permits(initial_provider)`.

## `cli.ConversationRuntime`

```zig
pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session_value: agent.Session.Session,
    durability_value: *SessionDurability.Owner,
    identity: Identity,
    recording_policy: RecordingPolicy,
    fresh: FreshFactory,
    generation: u64 = 0,
    next_authorization_nonce: u64 = 1,
    issued_authorization_nonce: ?u64 = null,
    consumed_authorization_nonce: u64 = 0,
    phase: Phase = .idle,

    pub fn create(
        allocator: std.mem.Allocator,
        startup: *SessionStartup.Candidate,
        options: CreateOptions,
    ) CreateError!*Owner;

    pub fn deinit(self: *Owner) void;
    pub fn session(self: *Owner) *agent.Session.Session;
    pub fn durability(self: *Owner) *SessionDurability.Owner;
    pub fn activePath(self: *const Owner) ?[]const u8;
    pub fn resumeHint(self: *const Owner) ?[]const u8;
};
```

`FreshFactory` owns or borrows the stable state root, cwd, writer version, Git probe,
limits, and injected timestamp/UUID functions. It creates a new lazy log only when the
current authority owns a logger.

### Publication guard

```zig
pub const Guard = struct {
    conversation: u64,
    session_history: u64,
    session_selection: u64,
    durability: u64,
    run_selection: u64,
};

pub const EntryState = struct {
    guard: Guard,
    authority: SessionDurability.State,
};

pub const PublicationAuthorization = struct {
    owner: *Owner,
    selection: *RunSelection.Owner,
    transition: Transition,
    candidate_address: *anyopaque,
    entry: EntryState,
    final_guard: Guard,
    settlement: union(enum) {
        none,
        completed: ToolRuntime.TransitionSettlement,
    },
    nonce: u64,
    active: bool = true,
};

pub const PublishLease = struct {
    authorization: PublicationAuthorization,
    conversation_phase_reserved: bool = true,
    selection_phase_reserved: bool = true,
    active: bool = true,

    pub fn cancel(self: *PublishLease) void;
};

pub const Transition = enum { new, resume, undo, fork };

pub fn captureEntryState(
    self: *Owner,
    selection: *RunSelection.Owner,
) EntryState;

pub fn bindAuthorization(
    self: *Owner,
    selection: *RunSelection.Owner,
    candidate: *anyopaque,
    authorization_slot: *?PublicationAuthorization,
    entry: EntryState,
    final_guard: Guard,
    transition: Transition,
    settlement: ?ToolRuntime.TransitionSettlement,
) error{StaleCandidate, Quarantined, SettlementIncomplete}!void;

pub fn beginPublish(
    self: *Owner,
    authorization: *PublicationAuthorization,
) error{Reentrant, StaleCandidate}!PublishLease;
```

Each command captures `EntryState` before reconciliation so preexisting quarantine cannot
be inferred from a later copy. After settlement and final binding, `bindAuthorization`
validates the exact candidate address, entry state, final guard, operation-specific
quarantine rule, and settlement matrix; undo/fork require null settlement while
new/resume require a completed one. It stores the authorization inside that candidate and
records one monotonic issued nonce in `Owner`. Only one authorization may be outstanding.

`beginPublish` atomically compares and moves that candidate-owned authorization into the
lease, clears `issued_authorization_nonce`, records the nonce as consumed in the owner,
and reserves both phases. A copied authorization cannot replay even if generations stay
unchanged. Each `publish*` requires the same candidate
address, transition, nonce, and unchanged generations before consuming anything. Cancel
releases both phases and invalidates the authorization.

The guard permits `.new` and `.resume` to replace quarantined authority only when their
verified replacement/unrecorded candidate and task-settlement result are complete. Undo
and fork reject quarantine.

New and resume preparation own detached session/log values, identity, and presentation
facts first. None contains a `PreparedReplacement`, `PreparedAdoption`, or other value
bound to the live session or durability owner while task settlement can still mutate
those owners.

After settlement permits replacement, the command samples a new complete `Guard`, binds
the detached values into owner-address/generation-specific `PreparedReplacement` and
`PreparedAdoption` values, and immediately calls `beginPublish` with that same guard. No
callback, allocation, I/O, transcript work, or cleanup may occur between binding and
`beginPublish`. A binding failure leaves the detached candidate owned and the old
conversation live. A stale final guard deinitializes the bound candidate, including its
still-unpublished replacement values, and reports the partial effects already caused by
preset commit or task settlement. It never retries against newly sampled generations.
This is the only binding point for `/new` and `/resume`.

The four candidate families own prepared session replacement/cut, durability adoption,
identity, optional detached selection, and post-publication facts. `publish*` methods
consume candidates under a lease and return retired values for cleanup:

```zig
pub fn publishNew(lease: *PublishLease, candidate: *NewCandidate) Retired;
pub fn publishResume(lease: *PublishLease, candidate: *ResumeCandidate) Retired;
pub fn publishUndo(lease: *PublishLease, candidate: *UndoCandidate) Retired;
pub fn publishFork(lease: *PublishLease, candidate: *ForkCandidate) Retired;
```

Only the constrained internal config, tool, view, and owner publication adapters may be
invoked by these methods. No writer, observer, state persistence, transcript,
presentation, allocation, or fallible callback runs inside.

### Resume outcome axes

```zig
pub const ResumeSelection = union(enum) {
    restored,
    core_restored: config.Selection.RestoreOutcome,
    kept_current: RestoreFailure,
};

pub const ResumeRecording = enum {
    appending,
    unrecorded_explicit,
    unrecorded_provider_policy,
    unrecorded_unavailable,
};

pub const ResumeResult = struct {
    selection: ResumeSelection,
    recording: ResumeRecording,
};
```

A locked candidate is attempted first unless recording is explicitly disabled. After
selection preparation, automatic policy chooses whether its log is published. If append
loading fails, `loadStableForResume` may provide the verified unrecorded candidate.

## Transcript package

### Public contracts

`src/transcript/Owner.zig` defines:

```zig
pub const default_max_file_bytes: usize = 256 * 1024 * 1024;
pub const default_max_segment_bytes: usize = 16 * 1024 * 1024;
pub const default_max_path_bytes: usize = 4096;
pub const default_max_items: usize = 16 * 1024;
pub const default_max_tools: usize = tool.Dispatch.default_maximum_tools;

pub const View = struct {
    system_prompt: []const u8,
    tools: []const tool.Tool.Tool,
    items: []const ai.Item.Item,
};

pub const Status = union(enum) {
    disabled,
    clean: Progress,
    degraded_attached: Failure,
    degraded_detached: Failure,
};

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    secure_open: SecureOpen.Capability,
    path: ?[]const u8,
    limits: Limits,
) error{OutOfMemory}!*Owner;

pub fn append(self: *Owner, view: View) Outcome;
pub fn rebuild(self: *Owner, operation: Operation, view: View) Outcome;
/// Borrowed until `ackWarning` or `deinit`; owner mutation does not invalidate it.
pub fn pendingWarning(self: *const Owner) ?Warning;
pub fn ackWarning(self: *Owner) void;
pub fn deinit(self: *Owner) void;
```

Null and empty paths produce a disabled owner. Append/rebuild return no error union;
failures keep an attached degraded state when identity and lock remain known, or move to
detached degradation after identity loss, and expose one bounded warning.

The owner stores one fixed-size pending warning value plus sequence number; its path
borrows the owner’s stable path. While unacknowledged, the same failure coalesces. A more
severe transition replaces only the enum payload and increments the sequence:
identity-loss/detached degradation outranks attached write degradation, which outranks a
bounds refusal. No warning queue or allocation is required. `pendingWarning` borrows the
latest value until acknowledgement or deinit, regardless of intervening owner mutations.
After acknowledgement a later distinct failure can become pending.

### Renderer

```zig
pub const Cursor = struct {
    item_high_water: usize = 0,
    turn_number: u64 = 0,
};

pub fn preflightAll(
    allocator: std.mem.Allocator,
    view: Owner.View,
    limits: Owner.Limits,
) Error!usize;

pub fn preflightSuffix(
    allocator: std.mem.Allocator,
    view: Owner.View,
    cursor: Cursor,
    remaining_bytes: usize,
    limits: Owner.Limits,
) Error!usize;

pub fn renderAll(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    view: Owner.View,
    cursor: *Cursor,
    limits: Owner.Limits,
) !void;

pub fn renderSuffix(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    view: Owner.View,
    cursor: *Cursor,
    limits: Owner.Limits,
) !void;
```

Rendering uses one segment buffer capped at 16 MiB, fixed advertised-tool storage,
bounded result pairing, and no item deep copy. It ports hax's 60-column plain header,
turn numbering, role/origin sections, tool schema and paired result layout, image
metadata placeholders, reasoning ID extraction, and usage/provenance text. It never
writes ANSI, image base64, encrypted reasoning JSON, call IDs, or response IDs.

### Secure owner

The production capability resolves relative or absolute paths by walking every parent
component through directory handles with no-follow checks, then opens the final target
close-on-exec, nonblocking, read/write/create mode `0600`, without truncate or append.
It rejects symlinked parents, final symlinks, non-regular files, targets not owned by the
current user, and targets with link count other than one. Existing targets are tightened
to `0600` and re-statted before use. Named/open descriptor identity must match. Atomic
close-on-exec requires no `ProcessSpawn` lock; any fallback with separate close-on-exec
setup must hold it.

Clean state retains an exclusive lifetime lock, descriptor identity, size, and stat
change token. Append preflights and verifies identity, link state, permissions, exact
size, and unchanged token before positional write, then advances cursor and token only
after final verification. The exact concurrency contract covers cooperating writers that
honor the lock; advisory transcript logging does not promise detection of a malicious
non-cooperating writer that rewrites bytes in place while preserving every observable
stat fact. This avoids an O(history) rehash before every append. A possible partial write
with intact identity keeps the descriptor and exclusive lock in `degraded_attached`;
identity loss closes it and becomes `degraded_detached`. Degraded append is a no-op until
full rebuild succeeds.

Rebuild preflights before truncation. From clean state it revalidates and truncates
through the existing lifetime-locked descriptor, so no self-lock conflict or close/open
race exists. Attached degradation reuses and revalidates the held lock. Detached
degradation securely opens and acquires a new exclusive lock before mutation; lock contention degrades without changing the target. Every path
rechecks no-follow named identity against the opened descriptor. It renders all and
publishes clean progress only after verification. Failure remains advisory and can be
retried by a later lifecycle or selection rebuild.

All transcript owner and seam methods are confined to the interactive process thread and
externally serialized with selection/lifecycle publication. Background task workers
never call them; task notes are collected synchronously on that thread. The `active`
flag rejects callback reentry but is not presented as a cross-thread lock.

## `cli.RunLogSeam`

```zig
/// Synchronous, infallible, non-retaining, and non-reentrant. Production adapters
/// consume writer failure internally.
pub const WarningSink = struct {
    context: *anyopaque,
    warn_fn: *const fn (*anyopaque, transcript.Owner.Warning) void,

    pub fn warn(self: WarningSink, warning: transcript.Owner.Warning) void;
};

pub const Owner = struct {
    allocator: std.mem.Allocator,
    selection: ?*RunSelection.Owner = null,
    transcript_owner: *transcript.Owner.Owner,
    durability: *SessionDurability.Owner,
    marker: ?*CompactionMarker,
    warning_sink: ?WarningSink,
    active: bool = false,

    pub fn create(...) error{OutOfMemory}!*Owner;
    pub fn bindSelection(self: *Owner, selection: *RunSelection.Owner) void;
    pub fn seamHook(self: *Owner) agent.Loop.SeamHook;
    pub fn rebuildTranscript(
        self: *Owner,
        operation: transcript.Owner.Operation,
        session: *const agent.Session.Session,
    ) void;
};
```

One-time binding breaks composition order: tools need the seam before `RunSelection`
exists, while the seam needs the stable selection owner before its first call. Calling
before binding is a programmer panic.

Seam order:

1. borrow current selection snapshot;
2. append advisory transcript and emit at most one warning;
3. borrow `pendingWarning`, call the infallible sink synchronously, then `ackWarning`;
4. call authoritative durability unconditionally even if the production warning writer
   failed internally;
5. print pending automatic-compaction marker only after authoritative success.

`RunLogSeam.append` and `rebuildTranscript` drain a newly pending warning immediately
after the owner mutation. They acknowledge only after an actual synchronous sink call;
with no sink, the owner retains the warning for a later drain. Selection and lifecycle
commits call `rebuildTranscript` after publication, never from a view callback or
critical section. Pre-bind calls panic as programmer errors; a second bind to any
pointer, including the same pointer, is rejected. Warning lifetime tests overwrite owner
storage after acknowledgement to prove sinks retained nothing.

## Task settlement and usage

```zig
pub const NoteMutation = enum { none, appended, pending_flush_recovered };
pub const FlushState = enum { not_needed, synchronized, unrecorded, preexisting_quarantine, failed, indeterminate };
pub const ShutdownState = enum { no_tasks, complete, partial, failed };

pub const TransitionSettlement = struct {
    note: NoteMutation,
    flush: FlushState,
    shutdown: ShutdownState,
    prior_quarantine: bool,

    pub fn permitsReplacement(self: TransitionSettlement) bool;
};

pub fn finishForTransition(
    self: *Owner,
    session: *agent.Session.Session,
    durability: *SessionDurability.Owner,
) TransitionSettlement;
```

`prior_quarantine` means the authority was quarantined when the command began, before its
initial `reconcile`. A quarantine created by that reconcile or by settlement is new and
never receives the abandonment exception. A retryable reconcile failure blocks the
transition before task settlement. Pending flush is reconciled before collecting another
note; settlement never appends a second copy of a note already present in memory.

The replacement decision follows this complete matrix:

| Authority at command entry | Note/flush result | Shutdown result | Replace? | Required report |
| --- | --- | --- | --- | --- |
| synchronized or unrecorded | `not_needed`, `synchronized`, or `unrecorded` | `no_tasks` or `complete` | yes | none |
| synchronized or unrecorded | `failed` or `indeterminate` | any | no | current conversation changed or is uncertain |
| synchronized or unrecorded | any | `partial` or `failed` | no | tasks may remain or have uncertain state |
| preexisting quarantine | `not_needed` or `preexisting_quarantine` | `no_tasks` or `complete` | yes | incomplete old branch |
| preexisting quarantine | `failed` or `indeterminate` | any | no | settlement failed independently of the old quarantine |
| preexisting quarantine | any | `partial` or `failed` | no | tasks may remain or have uncertain state |
| quarantine created after command entry | any | any | no | new recording uncertainty |

Precedence is new indeterminacy, other flush failure, partial or failed shutdown, then the
preexisting-quarantine warning. `permitsReplacement` implements the table rather than
inferring permission from `prior_quarantine` alone.

`ToolRuntime.finishForTransition` returns a typed result distinguishing no work,
settled, unrecorded, settled against preexisting quarantine, and failure. With
preexisting quarantine it may append the terminal note to old memory, stops tasks, skips
the unusable seam, and reports that the old branch is not fully recorded. New and resume
may then abandon that authority in favor of their verified candidate only for the two
permitted shutdown states above. `/new` and `/resume` inspect this result before binding
live-owner candidates.

`/new PRESET` uses an operation-specific live selection wrapper: synchronized authority
stages session and log selection normally, while preexisting quarantine stages only the
stable session and records an incomplete-old-branch warning. Ordinary selection
commands still reject quarantine. `/fork`, `/undo`, and `/compact` do not settle tasks.

`UsageStats` adds:

```zig
pub fn reset(self: *UsageStats) void;
pub fn invalidateContext(self: *UsageStats) void;
```

Reset clears the retained attempt list while keeping capacity. New resets all totals;
resume, destructive undo, prefix fork, and successful compact only invalidate context.

## `CompactRunner` result classification

```zig
pub const Mutation = enum { none, usage_only, seed_committed };
pub const Durability = enum {
    not_attempted,
    synchronized,
    unrecorded,
    failed,
    indeterminate,
};

pub const UsageDisposition = enum {
    committed,
    preparation_failed,
};

pub const PostProviderIssue = struct {
    usage_observer_failed: bool = false,
    durability: Durability = .not_attempted,
    diagnostic_omitted: bool = false,
};

pub const Result = struct {
    outcome: Outcome,
    mutation: Mutation,
    usage: UsageDisposition,
    issue: PostProviderIssue,
    attempts: usize,
    diagnostic: ?[]u8 = null,
};
```

`RunError` is restricted to validation and preparation failures before the first call to
`provider.stream`. Once that call begins, every exit returns `Result`, even if the
provider cannot prove that it sent a request. This keeps every possibly billed attempt
visible to the caller.

After a provider return, the runner prepares usage before any diagnostic copy, summary
or tool-result construction, or other fallible work. If usage preparation fails, it
returns `mutation = .none`, `usage = .preparation_failed`, a provider-failure outcome,
and no durability attempt. If no owned diagnostic is already available, it returns a
null diagnostic and sets `diagnostic_omitted` rather than allocating again. This is the
sole post-provider case without retained usage.

Once usage is prepared, every later failure, including diagnostic copy, summary
selection, seed construction, `prepareCompactSeed`, rejected-result construction,
scratch growth, observer, or durability failure, first commits that usage. The runner
then independently attempts usage observation and durability and returns a classified
`usage_only` result. `usage = .committed` applies to both `usage_only` and
`seed_committed`. An observer failure cannot skip durability. If an owned diagnostic
cannot be copied, `diagnostic_omitted` records that fact without changing the mutation
classification. Seed-committed always wins for lifecycle effects and product
presentation. No post-provider path escapes through `RunError`.

For rejected-tool attempts, continuation to another provider request occurs only when
usage observation succeeds and durability is synchronized or unrecorded. Observer,
failed durability, or indeterminate durability stops retries and returns a `usage_only`
provider-failure result. Allocation failure while building the rejected-response scratch
context follows the same path after usage observation and durability; it cannot escape
as `RunError`. Allocation-failure tests cover that exact post-commit point.

Cancellation becomes:

```zig
pub const Cancellation = struct {
    context: *anyopaque,
    sample_fn: *const fn (*anyopaque) bool,
    resolve_fn: *const fn (*anyopaque) bool,

    pub fn sample(self: Cancellation) bool;
    pub fn resolve(self: Cancellation) bool;
};
```

Accepted-summary flow is exact:

1. build the seed text;
2. call `prepareCompactSeed(&usage)`; failure leaves usage active and commits it alone;
3. on success the seed candidate owns that exact usage;
4. call `resolve()` exactly once;
5. cancellation calls `publishCompactUsageOnly(&seed_candidate)` and deinitializes the
   returned retired seed after publication;
6. acceptance calls `publishCompactSeed(&seed_candidate)`;
7. only after either publication run usage observation and durability independently.

Seed construction and every allocation finish before `resolve()`. After resolution
returns false, no allocation, callback, provider event, or I/O occurs before the
allocation-free accepted-seed commit. The terminal adapter maps pause and abort to true
and uses `GenerationInterrupt.resolve()` to settle a pending bare Escape.

Outcome precedence after `provider.stream` begins:

| Provider/assembly path | Mutation | Product outcome |
|---|---|---|
| usage preparation fails | none | provider failure, diagnostic may be omitted |
| cancellation or cancelled transport | usage only | cancelled |
| other transport, assembly, capture, or incomplete-turn failure | usage only | provider failure |
| empty complete response | usage only | no summary |
| seed build/preparation failure | usage only | provider failure |
| late resolved cancellation | usage only | cancelled |
| accepted prepared seed | seed committed | compacted |
| final rejected-tool attempt | usage only | no summary |
| rejected-response/scratch preparation failure | usage only | provider failure |
| retryable rejected-tool attempt with clean observers/durability | usage only | continue |

Observer and durability issues do not replace an already terminal cancelled, provider
failure, no-summary, or compacted outcome; they populate `issue`. On a branch that would
otherwise continue, either issue stops retries and maps the product outcome to provider
failure. `HookFailed` maps to `.failed`, `HookIndeterminate` to `.indeterminate`, and an
absent/unrecorded seam to `.unrecorded`. Attempt count increments once when each provider
stream starts. Diagnostic allocation failure sets `diagnostic_omitted` without changing
the outcome tuple.

## REPL and presentation

`Slash.HandlerOutcome` and `Interactive.CommandOutcome` add `.history_changed` between
`.handled` and `.exit`. `Interactive` applies it by clearing `resume_reason` and
`abort_marker_placed`, then continues. It does not reset the process-only first-send
catalog hook.

`render.History.Inputs` adds `heading: []const u8`; `replayBrief` removes its hard-coded
`resumed` label. Heading length is capped at 256 generated bytes.

`TurnPicker` adapts typed turns into picker rows with:

- at most 200 rows;
- 512 display cells per prompt label;
- 1 MiB aggregate row storage;
- newest prompt initially selected;
- caller title `revert to before which message` or `branch before which message`.

Numeric parsing uses hax ranges and permits surrounding whitespace. Bare noninteractive
undo/fork emits the hax diagnostic instead of silently handling.

## Command registry order

`InteractiveCommands.specs` becomes:

1. `new`, alias `clear`, optional argument;
2. `resume`;
3. `undo`, optional argument;
4. `fork`, optional argument;
5. `provider`;
6. `model`;
7. `effort`;
8. `compact`, optional argument;
9. `help`.

Future preset/config commands insert before compact without changing dispatch
semantics.

## Command call stacks

### `/new [PRESET]`

```text
Interactive.run
  admit slash line to session-only recall
  runNew
    SessionDurability.reconcile current conversation
    prepare optional preset live selection candidate
    prepare detached empty session + lazy log/unrecorded values
      under that candidate’s effective selection
    commit and persist live preset selection when supplied
    rebuild transcript for that selection before task settlement
    ToolRuntime.finishForTransition(old stable session, RunLogSeam)
    bind detached fresh values to current post-settlement generations
    beginPublish + publishNew
    cleanup retired session/log
    UsageStats.reset
    invalidate continuation/compaction state
    RunLogSeam.rebuildTranscript(lifecycle_rebuild)
    render Banner from current selection
  history_changed
```

Invalid preset is a no-op. If task settlement fails after preset publication, the preset
remains active and the old history remains live with an explicit partial diagnostic.

### `/resume`

```text
runResume
  SessionDurability.reconcile current conversation
  list current-directory sessions excluding active path
  SessionPicker.run
  loadLockedForResume or loadStableForResume
  prepare detached recorded restore
    full / core-only / current-selection fallback
  normalize detached session and candidate log to effective selection
  hold detached session/log/identity/replay facts
  ToolRuntime.finishForTransition(old conversation)
  bind replacements to current post-settlement generations
  coordinated conversation + optional selection publication
  cleanup retired owners
  UsageStats.invalidateContext
  RunLogSeam.rebuildTranscript(lifecycle_rebuild)
  replayBrief("resumed")
  render selection and recording warnings
```

History adoption, preset restoration, core selection, and recording are independent
result axes. Restore never writes state defaults.

### `/undo [N]`

```text
parse N or TurnPicker.run
prepare Session cut
prepare PromptHistory session admission from borrowed removed prompt
prepare and compare SessionCut plan
SessionFile.truncatePrepared
  unchanged -> discard all candidates
  indeterminate -> quarantine, keep memory, report
  committed -> publish memory cut and recall
  committed sync_failed -> publish then quarantine
UsageStats.invalidateContext
clear continuation/deferred state
transcript rebuild
replayBrief("undid N turn(s)")
```

No allocation occurs between confirmed file commit and memory/recall publication.
Unrecorded or lazy authority treats the file step as committed no-op.

### `/fork [N]`

```text
parse explicit tip clone or typed target
require synchronized materialized authority
prepare optional cut, recall, replay facts, timestamp, UUID
prepare and compare disk plan
SessionFile.forkPrepared
coordinated destination adoption + optional memory cut
cleanup retired source after publication
publish recall for prefix fork
invalidate context only for prefix fork
transcript rebuild
replayBrief("forked")
```

`/fork 0` accepts any non-empty history, including seed-only history. Bare fork still
requires a typed turn. Cleanup-indeterminate reports its owned path.

### `/compact [FOCUS]`

```text
validate provider/model/history/focus
start compacting spinner
arm GenerationInterrupt
CompactRunner.run standalone with RunLogSeam and usage observer
disarm and restore terminal in defer
stop spinner
inspect mutation before post-commit issue
seed_committed -> invalidate context and stale continuation state
render exactly one product outcome
render recording warning separately when needed
```

The manual path never touches the automatic marker's pending bit.

## Transcript integration call sites

- startup: full rebuild after `RunLogSeam.bindSelection`;
- provider/model/effort and preset commits: selection rebuild after publication;
- new: header-only lifecycle rebuild;
- resume/undo/fork: lifecycle rebuild from committed history;
- compact: append only through the ordinary seam;
- failed preparation and cancelled picker: no transcript operation.

## Vertical implementation slices

### Slice 1: transcript and stable run-log seam

- Add transcript renderer, secure owner, root seam, and bounds.
- Make `SessionDurability.Owner` mandatory and own optional log.
- Add one-time-bound `RunLogSeam` and replace inline `PrintRun.RunSeam`.
- Wire startup, ordinary turns, current selection commits, and automatic compaction.

Verification:

- golden renderer cases adapted from hax;
- preflight/render byte equality at exact and one-over bounds;
- cursor unchanged after allocation, writer, partial-write, and verification failures;
- maximum bounded call/result pairing without quadratic rescans;
- parent/final symlinks, permissive ownership/mode, hard links, FIFO/device/directory,
  rename/unlink, and same-size external mutation with a changed stat token;
- secure file degraded recovery and exact stat-token progression;
- second-owner lock contention, clean rebuild lock continuity, renamed-path identity,
  and lock release after degradation/deinit;
- pre-bind panic and double-bind rejection;
- transcript warning failure still calls authoritative durability;
- every durability authority/adoption/reconciliation state and allocation failure;
- lazy JSONL materialization: create, header/item partial writes, file sync, directory
  sync, confirmed cleanup, and cleanup indeterminacy;
- transcript-before-JSONL seam order;
- binary ordinary turn creates a bounded mode-0600 transcript;
- provider switch rebuilds it;
- ready gate, changed-file lint, commit.

### Slice 2: stable conversation runtime and `/new`

- Add session replacement, prepared preset overlay, startup candidate transfer,
  recording policy, task-settlement result, usage reset, and `ConversationRuntime`.
- Register `/new` with `/clear` alias.
- Render fresh banner and rebuild transcript.

Verification:

- stable session/durability addresses;
- invalid preset no-op;
- preset selection-only commit validates all three selection generations without a
  conversation lease and is not republished by `publishNew`;
- preset-before-task ordering and partial settlement;
- post-settlement binding uses one newly sampled guard and never retries a stale guard;
- every quarantine/flush/shutdown matrix row, including no-tasks preexisting quarantine
  and quarantine first created by reconcile;
- old log preserved, new log lazy, unrecorded stays unrecorded;
- no empty session file after `/new` plus EOF;
- PTY `/clear`, banner, next prompt, terminal restoration;
- ready gate, lint, commit.

### Slice 3: live `/resume`

- Add stable locked/unrecorded loaders, direct item adoption, prepared restore overlay,
  detached run selection, active-path exclusion, and coordinated resume publication.
- Generalize brief replay heading.

Verification:

- picker cancel/load failure no-op;
- full, core-only, and current-selection restore outcomes;
- explicit no-session and provider-auto recording outcomes;
- locked destination and stable unrecorded snapshot;
- resumed next request and append target;
- PTY search/cancel/replay/cursor restoration;
- ready gate, lint, commit.

### Slice 4: typed cuts and `/undo`

- Add typed-turn APIs, prepared session cut, public prepared prompt admission,
  `SessionCut.Plan`, classified truncate, `TurnPicker`, and `/undo`.

Verification:

- memory/file predicate and retained-count agreement;
- every origin, boundary, tool, image, usage, and compact-floor case;
- unchanged, committed, sync-failed, and indeterminate truncation;
- discarded prompt recalled with Up;
- numeric and noninteractive diagnostics;
- PTY replay and subsequent request;
- ready gate, lint, commit.

### Slice 5: `/fork`

- Add classified fork outcome and destination adoption using the shared cut plan.
- Register numeric, picker, tip, and prefix behavior.

Verification:

- source byte-identical;
- new identity and `forked_from`;
- destination locked and appendable;
- `/fork 0` empty rejection and seed-only success;
- prefix recall/context invalidation and tip context preservation;
- cleanup-indeterminate path;
- binary resume of source and destination proves independent tails;
- ready gate, lint, commit.

### Slice 6: commit-classified manual `/compact`

- Refactor `CompactRunner` post-commit reporting and late cancellation.
- Add manual compact service, spinner, interrupt handling, outcome markers, and command.

Verification:

- success, cancellation, provider failure, empty summary, four tool-call attempts;
- usage-only and seed-committed observer/seam failures;
- usage-preparation allocation failure after `provider.stream` returns classified
  `mutation = .none` rather than `RunError`;
- a failure injected at every fallible post-provider point returns `Result`, with
  committed usage whenever preparation succeeded;
- post-usage rejected-response allocation failure returns a classified result;
- retries stop on observer or durability issue;
- durability still runs after observer failure;
- one marker, no streamed summary, no automatic duplicate;
- PTY bare-Escape and double-Escape cancellation plus usable next prompt;
- final parity review, full ready gate, lint, commit.

## Mechanical acceptance ledger

Before final completion, verify:

- `transcript/root.zig` is exported and test-registered;
- CLI root test-registers `ConversationRuntime`, `RunLogSeam`, and `TurnPicker`;
- all nine command specs exist in exact order and `/clear` resolves to `/new`;
- `SessionDurability.Owner` is always created and no replaceable log pointer escapes;
- `ConversationRuntime.session()` address stays stable across every transition;
- session and disk cuts share the external-user predicate;
- every irreversible file API returns a classified outcome;
- restore intent never reaches `StateWriter`;
- transcript failures never suppress authoritative durability;
- manual and automatic compaction use one runner and distinct marker paths;
- lifecycle provenance is added to `THIRD_PARTY_NOTICES.md`;
- highest-level probes use only `./zig-out/bin/zi`;
- `zig fmt --check src/`, `zig build`, `zig build test`, help, and version all pass.
