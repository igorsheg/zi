# Prompt-recall program design

Status: awaiting review

References:

- `docs/prompt-recall-research.md`
- `docs/prompt-recall-product.md`
- `docs/prompt-recall-architecture.md`
- `docs/slash-commands-design.md`

## Product correction carried into this design

hax's `src/slash.c` intentionally omits standard readline history bindings from
`/help`. Prompt recall therefore adds no shortcut rows. The earlier product text that
required Up, Down, Ctrl-P, Ctrl-N, and Ctrl-R rows was corrected before this design.
Existing Zi help remains otherwise unchanged.

## File tree

```text
src/
├── terminal/
│   ├── PromptHistory.zig          NEW  bounded entries, admission, navigation, search
│   ├── PromptSearch.zig           NEW  pure incremental-search state
│   ├── LineEditor.zig             MODIFY Ctrl-P/N/R and atomic cursor replacement
│   ├── RawLineInput.zig           MODIFY navigation, Ctrl-C recall, search, paint options
│   └── root.zig                   MODIFY export history and register both new files
├── persistence/
│   ├── PromptHistoryFile.zig      NEW  stream format, locking, append, compact
│   └── root.zig                   MODIFY export and test-register file adapter
├── cli/
│   ├── Interactive.zig            MODIFY erased recall and two-phase command token
│   ├── Slash.zig                  MODIFY classify and execute separately
│   ├── InteractiveCommands.zig    MODIFY gateway adapter; help rows stay unchanged
│   ├── PrintRun.zig               MODIFY TTY-only history composition
│   └── root.zig                   MODIFY retain command test registration
├── THIRD_PARTY_NOTICES.md          MODIFY attribute prompt recall and search
└── docs/slash-commands-design.md   MODIFY replace combined-dispatch pseudocode
```

No new top-level module or persistence service is introduced.

## `terminal/PromptHistory.zig`

### Constants and erased append seam

```zig
pub const maximum_entries: usize = 1000;

pub const Admission = enum { session, persistent };
pub const AppendOutcome = enum { written, too_large, unavailable };

pub const Appender = struct {
    context: *anyopaque,
    append_fn: *const fn (
        *anyopaque,
        std.mem.Allocator,
        []const u8,
    ) error{OutOfMemory}!AppendOutcome,

    pub fn append(
        self: Appender,
        allocator: std.mem.Allocator,
        entry: []const u8,
    ) error{OutOfMemory}!AppendOutcome;

    pub fn from(implementation: anytype) Appender;
};
```

The terminal allocator is passed per append. The persistence context owns descriptors
and I/O, not allocation policy. `Appender.from` requires an address-stable mutable
implementation exposing the same narrow method.

### Owner

```zig
pub const PromptHistory = @This();

allocator: std.mem.Allocator,
entries: std.ArrayList([]u8) = .empty,
position: usize = 0,
draft: ?[]u8 = null,
newest_unpersisted: bool = false,
appender: ?Appender = null,

pub fn init(allocator: std.mem.Allocator) PromptHistory;
pub fn deinit(self: *PromptHistory) void;
pub fn setAppender(self: *PromptHistory, appender: ?Appender) void;
pub fn beginRead(self: *PromptHistory) void;
pub fn seed(self: *PromptHistory, entry: []const u8) error{OutOfMemory}!void;
pub fn admit(
    self: *PromptHistory,
    entry: []const u8,
    admission: Admission,
) error{OutOfMemory}!void;
pub fn count(self: *const PromptHistory) usize;
pub fn entry(self: *const PromptHistory, index: usize) ?[]const u8;
pub fn currentPosition(self: *const PromptHistory) usize;
```

`deinit` frees every entry, the pointer list, and the draft, then sets `self` to
`undefined`. `seed` uses erasedups and marks the newest entry already persisted. It
never invokes the appender.

`beginRead` frees an old draft and sets `position = entries.items.len`. It runs before
terminal mode is entered, so it cannot leave terminal cleanup debt.

### Prepared admission

An internal `PreparedAdmission` union has these states:

```zig
noop
promote_newest
replace: {
    owned_entry: []u8,
    duplicate_index: ?usize,
    evict_oldest: bool,
}
```

Preparation duplicates before list mutation and reserves pointer capacity. Because the
list invariant permits only one exact duplicate, commit removes at most one index.
Eviction applies only when no duplicate is removed and count is already 1000.

Admission flow:

1. Empty entry: no-op.
2. Session repeat of newest: no-op and preserve the existing persistence marker.
3. Persistent repeat of newest:
   - if `newest_unpersisted`, prepare `promote_newest`;
   - otherwise no-op.
4. Every other value: prepare `replace`.
5. Persistent non-noop calls the appender when attached; no appender means
   `unavailable`.
6. Only append `OutOfMemory` aborts and destroys the plan.
7. Commit is infallible and sets newest-unpersisted only for a changed session
   admission.

Any persistent append outcome consumes the pending promotion, matching hax. A session
repeat of an already persisted newest entry does not turn it back into an unpersisted
entry.

### Navigation

```zig
pub const Direction = enum { older, newer };

pub const PreparedNavigation = struct {
    target: []const u8,
    next_position: usize,
    owned_draft: ?[]u8,
    release_draft: bool,

    pub fn deinit(self: *PreparedNavigation, allocator: std.mem.Allocator) void;
};

pub fn prepareNavigation(
    self: *PromptHistory,
    current_editor: []const u8,
    direction: Direction,
) error{OutOfMemory}!?PreparedNavigation;

pub fn commitNavigation(
    self: *PromptHistory,
    prepared: *PreparedNavigation,
) void;
```

The first older move from the live position duplicates `current_editor` into the
plan. A move to an entry borrows stable entry bytes. A move newer to live borrows the
current owned draft and marks it for release after editor installation. Endpoints
return null.

`RawLineInput` calls `LineEditor.setBuffer`, then `commitNavigation`. If setting the
editor fails, it deinitializes the plan and history remains unchanged.

### Search

```zig
pub const SearchDirection = enum(i2) { older = -1, newer = 1 };

pub fn search(
    self: *const PromptHistory,
    query: []const u8,
    start: usize,
    direction: SearchDirection,
) ?usize;

pub fn acceptSearch(
    self: *PromptHistory,
    match_index: usize,
    original_position: usize,
    owned_original: *?[]u8,
) void;
```

`search` is allocation-free, case-sensitive, and byte-substring based. The caller
computes a valid start; empty queries and invalid starts return null.

`acceptSearch` sets the retained position. If search began live, it frees the prior
draft and takes ownership of `owned_original`; otherwise the search state keeps and
later frees the original. The transfer is explicit by emptying the caller's slice.

### Core tests

Port hax `test_input_core.c` fixtures and add Zig ownership checks:

- empty and endpoint navigation;
- oldest/newest traversal and live-draft restoration;
- edits to recalled values do not mutate entries;
- exact erasedups, newest repeat, and case sensitivity;
- 1000-entry eviction;
- session-only newest promotion writes once;
- persistent repeat never writes twice;
- unavailable and too-large append outcomes still commit memory;
- append OOM and every owner allocation failure preserve the old state;
- forward/reverse exact substring search and invalid starts;
- `beginRead` resets position and releases stale draft;
- admitted storage survives caller mutation.

Use stateful local append fakes and `std.testing.checkAllAllocationFailures`.

## `persistence/PromptHistoryFile.zig`

### Constants and adapters

```zig
pub const maximum_record_bytes: usize = 65_536;
pub const compact_after_records: usize = 3000;
pub const maximum_lock_attempts: usize = 8;
pub const maximum_lock_wait_ms: usize = 40;

pub const Mode = enum { read_only, writable };
pub const AppendOutcome = enum { written, too_large, unavailable };

pub const Entries = struct {
    context: *anyopaque,
    seed_fn: *const fn (*anyopaque, []const u8) error{OutOfMemory}!void,
    count_fn: *const fn (*anyopaque) usize,
    entry_fn: *const fn (*anyopaque, usize) ?[]const u8,

    pub fn from(implementation: anytype) Entries;
};
```

`compact_after_records` is the literal 3000 in this module; persistence does not
import terminal to compute it. A compile-time test in CLI confirms it equals
`3 * PromptHistory.maximum_entries`.

`Entries` exists only for synchronous startup. `PrintRun` supplies a tiny adapter over
the temporary `PromptHistory`. No callback retains a decoded record.

### Open result and writer owner

```zig
pub const Open = union(enum) {
    unavailable,
    read_only,
    writable: Owner,
};

pub fn open(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: []const u8,
    mode: Mode,
    entries: Entries,
    nonce_source: PrivateFileStore.NonceSource,
) error{OutOfMemory}!Open;

pub const Owner = struct {
    io: std.Io,
    root: std.Io.Dir,
    lock_file: std.Io.File,
    // test-injected append/lock operations

    pub fn deinit(self: *Owner) void;
    pub fn append(
        self: *Owner,
        allocator: std.mem.Allocator,
        entry: []const u8,
    ) error{OutOfMemory}!AppendOutcome;
};
```

`Open.read_only` means loading completed or safely degraded and no callback context
survives. `Open.unavailable` may still leave already decoded entries in the temporary
history; filesystem failure is best-effort. Only allocator failure escapes.

`Owner` is move-only by contract and sets itself to `undefined` in `deinit`.

### Path setup

Validate `state_root` as absolute, UTF-8, NUL-free, and below both the 4096-byte
configuration limit and `std.fs.max_path_bytes`.

Read-only mode:

- opens only existing root, lock, and history leaves;
- never creates a directory or file;
- never changes permissions;
- if the lock is absent, reads one opened/validated history descriptor snapshot;
- a missing root or history returns `.read_only` with no entries.

Writable mode:

- creates the root path with mode 0700 when absent and reapplies 0700 to the final
  state-root directory;
- creates or opens `.zi-lock-history` with mode 0600, no final symlink, regular type,
  and `nlink == 1`;
- tries an exclusive lock first. Success permits load and optional compaction;
- if another shared owner prevents exclusive locking, takes a shared lock, loads, and
  skips compaction;
- if bounded lock attempts fail, returns a writable owner for later append attempts
  only when its descriptors remain safe; otherwise `.unavailable`.

Use descriptor-relative operations after opening the root.

### Streaming decoder

Use one `std.ArrayList(u8)` with capacity at most `maximum_record_bytes` as the current
physical-record buffer.

For every byte stream record:

- retain bytes only while the encoded record plus LF can fit;
- on overflow, discard through the next LF;
- strip trailing CR bytes before decoding;
- ignore blank records;
- decode in place: `\\` to backslash, `\n` to LF, unknown/trailing backslash literal;
- synchronously call `Entries.seed` with the borrowed decoded slice;
- increment the physical-record counter with saturating arithmetic even for blank,
  duplicate, corrupt, and oversized records.

At descriptor EOF, process one non-empty unterminated record as hax does.

### Encoder and append

First compute encoded length without allocating. If length plus LF exceeds 65,536,
return `.too_large`. Otherwise allocate exactly that size, encode backslash and LF,
and append the physical LF.

After encoding:

1. acquire a shared lock with the bounded retry budget;
2. `openat` the current named `history` with
   `O_WRONLY|O_APPEND|O_CREAT|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK`, mode 0600;
3. `fstat` regular type and `nlink == 1`, then enforce mode 0600;
4. issue one `std.posix.write` for the complete record;
5. close the history descriptor;
6. release the lock;
7. return `.written` only for a full write, otherwise `.unavailable`.

The raw open/write functions live in one small internal `PosixAppend` section guarded
by the same Unix compile-time target switch as `ProcessAdapters`. No fallback performs
non-atomic close-on-exec setup.

### Compaction

With the exclusive lock still held from writable startup:

1. open and stream the current named history into `Entries`;
2. if physical count is at most 3000, release the lock;
3. otherwise create a random mode-0600 sibling using the existing explicit
   `PrivateFileStore.NonceSource` and bounded temp attempts;
4. enumerate retained entries through `Entries.entry` in oldest-first order;
5. encode and write each record to the temp, bounded one at a time;
6. sync and close the temp;
7. rename it over `history` and sync the root directory;
8. delete an unpublished temp on every pre-rename failure;
9. release the lock and keep the writer owner usable even if compaction failed.

A temp encoding allocation failure propagates only while startup history is still a
temporary owner. All filesystem failures skip publication and continue in memory.

### Injected operations and tests

Keep production operations behind a private `Ops` value used by `openWithOps` and
`appendWithOps`. Inject lock, append write, temp write, sync, rename, directory sync,
and cleanup failures without changing real user paths.

Tests cover:

- exact encode/decode round trips, unknown escapes, trailing backslash, CRLF, and
  unterminated EOF;
- blank, duplicate, malformed, and oversized record recovery;
- 1000 retained erasedups after more than 1000 records;
- missing read-only root and history create no leaves;
- read-only root containing only history gains no lock file;
- writable mode creates 0700 root and 0600 managed leaves;
- final symlink, FIFO, directory, multiply linked file, and replacement races degrade;
- append is one write after lock then open and never retains a history descriptor;
- shared append locks coexist and exclusive compact lock excludes them;
- more than 3000 records compact to exactly the retained order;
- append arriving before exclusive compaction is included after reload;
- append after rename opens the replacement inode;
- short write, lock timeout, sync, rename, directory-sync, and cleanup failures;
- all allocation failures release descriptors, locks, buffers, and temporary leaves.

## `terminal/LineEditor.zig`

Extend `Outcome` with `history_search`. Map:

- `0x10` Ctrl-P to `history_previous`;
- `0x0e` Ctrl-N to `history_next`;
- `0x12` Ctrl-R to `history_search`.

Ctrl-S remains inert outside modal search.

Add internal cross-file methods:

```zig
pub fn cursorOffset(self: *const LineEditor) usize;
pub fn setBufferAtCursor(
    self: *LineEditor,
    text: []const u8,
    cursor: usize,
) Error!void;
pub fn previousCodepoint(input: []const u8, offset: usize) usize;
```

`setBufferAtCursor` validates the prompt bound, reserves before mutation, copies, and
clamps cursor to the resulting length. `setBuffer` delegates with cursor at end.
Existing allocation-failure and alias tests extend to cursor placement.

## `terminal/PromptSearch.zig`

### State

```zig
pub const Direction = enum { older, newer };
pub const Intent = enum { accept, submit, cancel };
pub const Finish = enum { editing, submit };

allocator: std.mem.Allocator,
original: ?[]u8,
original_cursor: usize,
original_position: usize,
query: std.ArrayList(u8),
direction: Direction = .older,
match_index: ?usize = null,
no_match: bool = false,
```

`init` duplicates editor bytes before any editor mutation. Query size is capped at
`LineEditor.max_prompt_bytes`.

Operations:

```zig
pub fn append(self: *PromptSearch, history: *const PromptHistory, bytes: []const u8) Error!void;
pub fn backspace(self: *PromptSearch, history: *const PromptHistory) void;
pub fn repeat(self: *PromptSearch, history: *const PromptHistory, direction: Direction) void;
pub fn view(self: *const PromptSearch, history: *const PromptHistory) View;
pub fn finish(
    self: *PromptSearch,
    history: *PromptHistory,
    editor: *LineEditor,
    intent: Intent,
) Error!Finish;
```

`append` reserves before mutating and then recomputes. Normal typed bytes preserve
valid UTF-8 sequences assembled by the raw loop; paste bytes are already filtered.
`backspace` uses `LineEditor.previousCodepoint`.

Recompute matches hax:

- empty query clears match and no-match;
- initial older start is newest; initial newer start is oldest;
- query editing starts from the current match when one exists;
- repeated Ctrl-R/Ctrl-S starts one entry beyond the current match;
- failure preserves the last match index but sets no-match, so changing direction or
  editing can recompute from the hax starting point.

`View` borrows original bytes, the matched entry, or the empty slice and reports the
cursor at the first query substring.

`finish` installs the final editor state before changing history. Valid acceptance
calls `acceptSearch`; cancel or invalid acceptance restores original bytes/cursor.
Only `.submit` with a valid non-empty match returns `.submit`; otherwise `.editing`.
Every ownership transfer takes the optional slice and sets `original = null`; `deinit`
frees only a remaining non-null owner and is always safe afterward.

Pure tests cover all directions, repeated search, edit recompute, malformed UTF-8
query backspace, no-match, each finish intent, cursor placement, draft transfer, and
every allocation failure.

## `terminal/RawLineInput.zig`

### Options and public recall methods

```zig
pub const Options = struct {
    // existing fields
    history: ?*PromptHistory = null,
    search_style_open: []const u8 = "",
    search_style_close: []const u8 = "",
    search_no_match_style_open: []const u8 = "",
    search_no_match_style_close: []const u8 = "",
};

pub fn admitSession(self: *RawLineInput, line: []const u8) !void;
pub fn admitPersistent(self: *RawLineInput, line: []const u8) !void;
```

History and styles are borrowed for the raw-input lifetime. Admission methods no-op
when history is null.

At read start call `history.beginRead()` before `enter`. For non-empty Ctrl-C, call
`history.admit(editor.bytes(), .session)` before `LineEditor.handleByte`; OOM therefore
leaves the editor uncleared and normal errdefer restores terminal mode. On success,
call `history.beginRead()` before clearing so navigation returns to live and the saved
draft is released exactly as in hax.

### Navigation

Handle history outcomes outside the inert branch:

```text
prepareNavigation(editor.bytes, direction)
  null -> no repaint
  plan -> editor.setBuffer(plan.target)
          history.commitNavigation(plan)
          repaint
```

Modified Up/Down from CSI route to the same actions rather than being consumed. Update
the existing test that asserts they are inert.

### Paste extraction

Refactor `collectPasteFrom` into a bounded body collector plus target commit:

```zig
fn collectPasteBodyFrom(
    allocator: Allocator,
    maximum: usize,
    source: PasteByteSource,
) !OwnedPaste;
```

It preserves current CR/LF normalization, exact end-marker detection, partial idle/EOF
outcomes, and drain-after-retention-failure behavior. Normal editing inserts the body.
Search reserves query capacity once, copies only bytes `>= 0x20 && != 0x7f`, and drops
normalized newlines. No control byte from paste reaches the query.

### Search loop

`searchHistory` owns one `PromptSearch` and repeatedly:

1. applies its `View` with `setBufferAtCursor`;
2. builds the search prompt;
3. repaints with continuation column zero;
4. polls at 250 ms so resize remains live;
5. handles Ctrl-R, Ctrl-S, Backspace, Ctrl-C, Ctrl-G, CR, LF, typed UTF-8, and Escape;
6. restores or accepts through `PromptSearch.finish` before returning.

Search-specific Escape consumes a bounded sequence with the existing 50 ms timeout.
Only decoded paste-begin continues searching. Lone Escape and every other sequence
accept without submission.

### Search prompt and paint options

Refactor repaint to:

```zig
const PaintOptions = struct {
    prompt: []const u8,
    continuation_column: usize,
    show_notice: bool = false,
    clear_screen: bool = false,
};
```

Main editing passes the configured prompt and its width. Search builds exact hax-style
labels:

```text
reverse-search · <query> →
forward-search · <query> →
... (no match)
```

Use accent style around the prompt and dim/reset only for `(no match)` through borrowed
style bytes supplied by `PrintRun`. Unsafe or malformed query glyphs display as `?`.
The prompt builder measures display cells, keeps the query tail, prefixes `…` when
clipped, and emits at most one terminal row.

`EditLayout.compute` and `render` receive prompt width separately from continuation
column. Visible-window and cursor calculations continue to use layout positions.

Raw tests use injected byte sources for complete search key scripts and inspect:

- navigation and Ctrl-P/N parity;
- Ctrl-C session-only admission and OOM preservation;
- Ctrl-R/Ctrl-S, CR/LF/Escape/Ctrl-C/Ctrl-G outcomes;
- non-paste escape draining;
- search paste filtering and end-marker draining;
- search prompt clipping at 1, narrow, fixed, and wide columns;
- resize repaint and multiline match continuation at column zero;
- no alternate-screen bytes;
- cleanup after read, write, paste, search allocation, and editor replacement failures.

## `cli/Interactive.zig`

### Recall seam

```zig
pub const RecallKind = enum { session, persistent };

pub const PromptRecall = struct {
    context: *anyopaque,
    admit_fn: *const fn (*anyopaque, []const u8, RecallKind) anyerror!void,

    pub fn admit(self: PromptRecall, line: []const u8, kind: RecallKind) !void;
    pub fn from(implementation: anytype) PromptRecall;
};
```

`from` maps kinds to `implementation.admitSession(line)` and
`implementation.admitPersistent(line)`. Terminal code therefore never imports CLI.
`Inputs` gains `prompt_recall: ?PromptRecall = null`.

Without a command gateway, every non-empty non-resume submission calls persistent
recall after sanitation and before `Session.addUser`.

### Command token

Replace `CommandOutcome.not_command` and one combined dispatch callback with:

```zig
pub const CommandOutcome = enum { handled, exit };
pub const CommandUsage = enum { valid, unknown, bad_usage };

pub const CommandToken = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, CommandToken) anyerror!CommandOutcome,
    registry_index: ?usize,
    name: []const u8,
    argument: ?[]const u8,
    usage: CommandUsage,

    pub fn execute(self: CommandToken) !CommandOutcome;
};

pub const CommandClassification = union(enum) {
    prompt,
    command: CommandToken,
};

pub const CommandGateway = struct {
    context: *anyopaque,
    classify_fn: *const fn (*anyopaque, []const u8) CommandClassification,
};
```

`CommandGateway.from` builds tokens whose execute callback calls the implementation's
`executeCommand(token)` method. Registry index refers only to process-lifetime immutable
specs owned by that implementation. Name and argument borrow the sanitized allocation,
which remains alive through execution.

Prompt order becomes:

```text
sanitize submitted bytes
classification = gateway.classify(sanitized) or prompt
command:
  prompt_recall.admit(original, session)
  token.execute
  handled -> continue
  exit -> return 0
prompt:
  prompt_recall.admit(original, persistent)
  Session.addUser(sanitized)
```

Sanitation OOM happens before recall. Recall OOM happens before command output or
session mutation. First-send state, resumable input, and provider flow remain unchanged.

Tests assert exact callback order, borrowed original versus sanitized bytes, no recall
for empty resume or cooked input without a seam, command admission before a failing
handler, and persistent admission before a failing `Session.addUser` allocation.

## `cli/Slash.zig` and `InteractiveCommands.zig`

Replace combined `dispatch` with:

```zig
pub const Usage = enum { valid, unknown, bad_usage };

pub const ClassifiedCommand = struct {
    registry_index: ?usize,
    name: []const u8,
    argument: ?[]const u8,
    usage: Usage,
};

pub const Classification = union(enum) {
    prompt,
    command: ClassifiedCommand,
};

pub fn classify(line: []const u8, specs: []const Spec) Classification;
pub fn execute(
    command: ClassifiedCommand,
    specs: []const Spec,
    handler_context: *anyopaque,
    output: Output,
) !HandlerOutcome;
```

Classification resolves aliases to one stable index and determines usage but performs
no output. Execution validates the index invariant, begins command output, renders
unknown/bad usage, or calls the registered handler.

`InteractiveCommands.Owner.classifyCommand` maps `Slash.Classification` into the
generic `Interactive.CommandClassification`. `executeCommand` maps the token back to
a `Slash.ClassifiedCommand`, executes it, flushes output, and returns handled/exit.

Update parser tests to prove classification has no callback side effects and handler
failure occurs only in execute. `/help` keeps its existing shortcut table; history
bindings are intentionally absent for hax parity.

## `cli/PrintRun.zig`

Add one grouping value to avoid more positional arguments:

```zig
const PromptRecallStartup = struct {
    state_root: ?[]const u8,
    writable: bool,
    nonce_source: persistence.PrivateFileStore.NonceSource,
};
```

Pass it to `runRawInteractive` as:

```zig
.{
    .state_root = paths.state_root,
    .writable = !no_session,
    .nonce_source = random.nonceSource(),
}
```

Non-TTY interactive mode does not construct history and leaves `prompt_recall` null.

Inside raw mode:

1. construct temporary `PromptHistory`;
2. construct a local `HistoryEntriesAdapter` for persistence startup;
3. call `PromptHistoryFile.open` only when state root exists;
4. retain a writable `Owner` in an optional stable stack slot;
5. construct a stable `HistoryAppenderAdapter` that maps persistence outcomes to
   terminal outcomes;
6. attach it only when a writable owner exists;
7. initialize `RawLineInput.Options.history`, search styles, and normal styles;
8. set `inputs.prompt_input` and `inputs.prompt_recall` from the same raw owner.

Use one explicit cleanup block after all views die:

```text
history.setAppender(null)
history.deinit()
if writable file owner: owner.deinit()
```

The file owner outlives its erased callback. Matching errdefers close lock/root handles
and free temporary history on every startup failure.

For the later dynamic provider-selection milestone, add a small owner method that can
fallibly enable writable setup or detach before disabling. Do not implement provider
switching in this slice.

## Provenance

Add `THIRD_PARTY_NOTICES.md` entries attributing adaptation of:

- `src/terminal/input_core.c` history erasedups, navigation, draft, and search;
- `src/terminal/input.c` Ctrl-R interaction, record format, append, startup loading,
  and compaction;
- `src/agent.c` command versus ordinary prompt admission.

Keep the exact hax revision already recorded. Do not attribute zig-ai product behavior;
its ownership patterns are design guidance only.

## Implementation slices

The current worktree contains an uncommitted combined-dispatch `/help` slice. Preserve
that patch before implementation, then restore command-touched tracked files to HEAD
so prompt recall can land in coherent commits. Reapply and adapt the saved patch only
in slice 3. Never discard untracked command files without copying their exact contents.

### Slice 1: bounded persistent navigation

Capability: ordinary TTY prompts survive process restart and can be navigated with
Up/Down and Ctrl-P/Ctrl-N; Ctrl-C drafts remain process-local.

- Add `PromptHistory.zig` and `PromptHistoryFile.zig` with roots and tests.
- Add line-editor navigation keys and raw history integration, but not Ctrl-R.
- Add `Interactive.PromptRecall` with ordinary persistent admission.
- Compose writable/read-only history in `PrintRun`.
- Add provenance.

Direct checks:

- allocation-failure sweeps for core and file setup;
- isolated temporary-directory persistence tests;
- PTY navigation and Ctrl-C draft probes through `./zig-out/bin/zi`;
- restart probe with isolated XDG state;
- `--no-session` byte-for-byte read-only probe;
- piped mock input leaves no history path;
- changed-file ziglint and full ready gate.

Commit: `feat(terminal): add persistent prompt recall`

### Slice 2: incremental Ctrl-R search

Capability: normal-buffer reverse/forward incremental prompt search.

- Add `PromptSearch.zig`.
- Refactor bounded paste-body collection and paint options.
- Add search key loop, prompt clipping, resize, and terminal cleanup.

Direct checks:

- pure search-state and raw injected-source tests;
- PTY reverse/forward, cancel, LF, CR, Escape, no-match, paste, and narrow-layout
  probes through the built binary;
- normal-buffer assertion excludes `\x1b[?1049`;
- changed-file ziglint and full ready gate.

Commit: `feat(terminal): add incremental prompt search`

### Slice 3: session-only slash recall and `/help`

Capability: consumed command lines are recalled during the process but never written
to prompt history or model context.

- Reapply `Slash.zig`, `InteractiveCommands.zig`, and prior command wiring.
- Replace combined dispatch with classify then execute.
- Route command and ordinary admission separately.
- Keep `/help` shortcut rows unchanged.
- Amend slash architecture/design and provenance if exact implementation names differ.

Direct checks:

- parser/classifier and callback-order tests;
- handled, unknown, bad-usage, and handler-error commands enter session recall;
- malformed slash input persists and reaches the provider;
- `/help` never reaches provider/session or disk history;
- PTY Up recall proves `/help` exists in process;
- restart Ctrl-R proves `/help` is absent while ordinary prompts remain;
- existing help PTY layout probe;
- changed-file ziglint and full ready gate.

Commit: `feat(cli): add slash command front door`

## Mechanical completion ledger

Before reporting completion, confirm:

- `terminal.root` exports `PromptHistory` and test-registers `PromptSearch`;
- `persistence.root` exports and test-registers `PromptHistoryFile`;
- `Interactive.Inputs` exposes `prompt_recall` and two-phase `command_gateway`;
- `RawLineInput` exposes session/persistent admission methods;
- `PromptHistoryFile.Owner.append` opens history after acquiring its shared lock;
- read-only tests prove no directory, lock, history, chmod, rename, or compact mutation;
- all limits are compile-time constants and directly asserted;
- `THIRD_PARTY_NOTICES.md` attributes prompt recall, persistence, search, and command
  admission;
- `zig fmt --check src/`, `zig build`, `zig build test`, `./zig-out/bin/zi --help`,
  and `./zig-out/bin/zi --version` pass after every commit;
- final behavior is exercised only through `./zig-out/bin/zi` from this checkout.
