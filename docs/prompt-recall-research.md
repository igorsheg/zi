# Prompt-recall research

Status: approved

References:

- hax product and behavior: `189816fb8b02956a6913d7638e6d2cc90a91d61a`
- zig-ai Zig design reference: `e2c5aef5f93015322891028a2048a217e7081687`
- slash-command research and design: `docs/slash-commands-*.md`

## Correction to the slash-command research

The approved slash documents assumed prompt recall already existed and was
terminal-owned. That is false.

`src/terminal/RawLineInput.zig:125` consumes history navigation without changing the
editor. `LineEditor` decodes Up and Down but owns no history. Zi has no Ctrl-R search,
process-lifetime prompt entries, or prompt-history file.

hax admits handled slash commands to in-process recall at `src/agent.c:1148` and
persists ordinary submitted prompts at line 1305. Faithful slash behavior therefore
requires prompt recall first. The slash architecture and program design must be
amended before their first implementation commit.

The current uncommitted slash parser, gateway, `/help`, and tests remain useful. They
must not be committed as a completed slice until history admission is wired.

## hax in-memory behavior

The core lives in hax `src/terminal/input_core.c:270-399`. It owns an oldest-first
list capped at 1000 entries.

Admission:

- Empty entries are ignored.
- Repeating the newest entry changes nothing.
- Re-adding any older exact match removes all earlier copies and moves the value to
  newest.
- Equality is byte-exact and case-sensitive.
- Slash commands and Ctrl-C-discarded drafts are session-only. Normal prompts may be
  persisted.

Navigation:

- Up and Ctrl-P move toward older entries.
- Down and Ctrl-N move toward newer entries.
- The first history move snapshots the live draft.
- Down past the newest entry restores that draft.
- Navigation stops at both ends.
- Editing a recalled value never changes the stored entry. Navigating away restores
  the original retained value.

Search:

- Search is a case-sensitive substring match.
- Reverse and forward searches take an explicit starting index.
- An empty query, invalid direction, or out-of-range start returns no match.
- Search returns a borrowed entry index, not a copied string.

Ownership and bounds:

- The history owner deep-copies admitted entries.
- Entry size is bounded by Zi's 1 MiB prompt limit in memory.
- Count is capped at 1000. Admitting another entry drops the oldest.
- The live draft is separately owned and replaced atomically.

## hax Ctrl-R interaction

The modal search loop starts at hax `src/terminal/input.c:931`.

- Ctrl-R enters reverse incremental search. Repeating Ctrl-R finds an older match.
- Ctrl-S switches direction and finds a newer match.
- The original buffer and cursor remain recoverable throughout the modal loop.
- A match replaces the edit buffer and positions the cursor at the first matching
  substring.
- No match displays an empty buffer and `(no match)` in the prompt.
- Backspace removes one UTF-8 unit from the query and recomputes.
- Ctrl-C and Ctrl-G cancel and restore the original buffer and cursor.
- Escape accepts the current match without submitting.
- LF accepts and returns to normal editing.
- CR accepts and immediately submits a non-empty match.
- Accepting with no valid match restores the original edit buffer.
- Bracketed paste extends the query after dropping all control bytes, including
  newlines.
- The search prompt occupies one terminal row. Long queries keep their tail and show
  `…` for UTF-8 terminals or `<` otherwise.
- After accepting a result that started from the live draft, Down past the newest
  entry can still restore that draft.

Search runs inside the active raw editor. Reusing `terminal.Picker.run` would nest
terminal-mode ownership and invalidate editor geometry. Zi should reuse picker
painting ideas, not the picker lifecycle.

## hax persistent history

Persistence lives in hax `src/terminal/input.c:1065-1230`.

Path:

- `$XDG_STATE_HOME/hax/history`
- otherwise `$HOME/.local/state/hax/history`
- Zi adapts this to `<state_root>/history`
- history is global across working directories

Format:

- One encoded prompt per physical line.
- `\\` encodes as `\\\\`.
- LF encodes as `\\n`.
- Decode reverses those forms and preserves unknown or trailing escapes literally.
- Blank records are ignored.
- A CR immediately before the record newline is removed.

Bounds:

- An encoded record plus newline may use at most 65,536 bytes.
- Oversized records are drained through newline and dropped during loading.
- A prompt may remain available in process memory while being too large for disk.
- Startup retains only the newest 1000 deduplicated entries.
- More than 3000 scanned physical records triggers a compact rewrite containing the
  retained entries.

File behavior:

- History is loaded only when both stdin and stdout are terminals.
- Normal recording loads and opens the file for later append.
- `--no-session` loads existing history read-only. New prompts remain process-local.
- Non-TTY input never loads or writes prompt history.
- A missing read-only file is ignored and not created.
- Writable setup creates parent directories and a mode-0600 file.
- Final symlinks and non-regular files are rejected.
- Nonblocking opens prevent a planted FIFO from hanging startup.
- Each append uses one `O_APPEND` write so concurrent records cannot interleave.
- I/O failures are silent. They never stop the REPL.
- A session-only newest entry that is later submitted normally is appended exactly
  once.

hax's startup compact rewrite can lose a concurrent append during rename. That race
is documented in its source, not a product requirement. Zi should coordinate rewrite
and append so safety improves without changing normal behavior.

## Admission order

hax reads one line, classifies slash input, then updates prompt recall before provider
validation or model execution.

Zi's equivalent seam now exists in the uncommitted command gateway at
`src/cli/Interactive.zig:462`.

Required paths:

- handled, unknown, and bad-usage slash commands enter session-only recall;
- ordinary prompts enter recall and persistent history when recording is enabled;
- malformed slash-shaped text remains an ordinary prompt and may be persisted;
- prompts rejected later for missing provider or model are still persisted;
- empty resume submissions never enter recall;
- Ctrl-C-discarded drafts enter session-only recall directly from raw input;
- non-TTY submissions never enter prompt history.

Persistence cannot happen inside `RawLineInput.submitAndFinish`, because slash
classification occurs later. `Interactive.PromptInput` needs an admission callback
that distinguishes session-only and persistent entries.

Recall should preserve the original editor bytes. The model-facing UTF-8 sanitation
buffer has a different purpose and must not silently rewrite history.

## Zi ownership and placement

`runRawInteractive` constructs one `RawLineInput` for the whole REPL. Each `read`
constructs a fresh `LineEditor`. The process-lifetime recall owner therefore belongs
inside or beside `RawLineInput`, never inside `LineEditor`.

Proposed ownership for the planning stage:

- `src/terminal/PromptHistory.zig` owns the bounded in-memory entries, position,
  draft, exact search, and encoding helpers that are independent of files.
- `src/persistence/PromptHistoryFile.zig` owns bounded loading, append, compact
  replacement, permissions, and no-follow file policy.
- `RawLineInput` owns or borrows one process-lifetime `PromptHistory` and drives
  navigation and modal search.
- `PrintRun` derives `<state_root>/history`, creates the file adapter only for a TTY,
  and selects writable or read-only mode from the resolved no-session policy.
- `Interactive.PromptInput` admits classified submissions back into the raw history
  owner. Cooked input's adapter is a no-op.

Dependencies remain inward: terminal history has no persistence import, persistence
has no terminal import, and CLI composes both.

## zig-ai posture to adopt

zig-ai revision `e2c5aef5` offers the useful implementation patterns, not product
behavior.

- `telemetry.BufferedExporter` deep-copies each admitted record, uses an explicit
  count bound and drop-oldest policy, and tests ownership after source mutation.
- `memory.InMemoryStore` validates bounds before copying and returns detached owned
  search results rather than pointers into mutable storage.
- file stores build and bound a complete replacement before atomic publication.
- erased stores use one borrowed context plus operation function pointers.
- move-only results own an arena, release it in `deinit`, and set themselves to
  `undefined`.
- tests use local stateful fakes and `std.testing.checkAllAllocationFailures`.

For Zi:

- Keep history entries individually owned because drop-oldest and erasedups mutate
  the list incrementally. An arena would retain evicted prompts until process exit.
- Keep searches allocation-free and return indexes.
- Use a small erased file interface. Terminal code should not know paths or POSIX.
- Prepare encoded append bytes before invoking the file adapter.
- Validate before mutation. Allocation failure must preserve history and the editor.
- Never run persistence callbacks while an internal history mutation is half
  published.

Avoid zig-ai's unbounded pending-message queue and convention-only ownership APIs
that invite copying a move-only result.

## Tests required before command slice completion

Pure core:

- empty history and endpoint navigation;
- 1000-entry eviction;
- exact erasedups and newest-repeat behavior;
- draft capture and restoration;
- recalled-edit discard;
- Ctrl-P and Ctrl-N parity;
- case-sensitive search in both directions;
- multiline and backslash encode/decode;
- unknown and trailing escape preservation;
- every allocation failure leaves the old history intact.

Persistence:

- read-only load and missing file;
- writable append, reload, and mode 0600;
- session-only then persistent duplicate writes exactly once;
- corrupt, blank, CRLF, and oversized records;
- non-regular and final-symlink rejection;
- compact rewrite after 3000 physical records;
- append and compact fault injection;
- no real user path in tests.

Raw terminal:

- Up, Down, Ctrl-P, and Ctrl-N with a live draft;
- Ctrl-C draft recall;
- Ctrl-R and Ctrl-S traversal;
- no-match, Backspace, Ctrl-G, Ctrl-C, Escape, LF, and CR outcomes;
- bracketed paste filtering;
- clipped one-row search prompt at narrow widths;
- cleanup after every read, write, allocation, and terminal-mode error;
- no alternate-screen sequences.

CLI integration:

- handled slash command enters memory only;
- ordinary and malformed slash prompts persist when recording is enabled;
- no-session loads history but never writes;
- non-TTY commands and prompts neither load nor write;
- command dispatch still leaves session and provider untouched;
- PTY process restart proves persistent ordinary prompts and process-local slash
  commands.

## Open design decisions

1. hax silently ignores all prompt-history I/O failures. I recommend preserving that
   behavior while keeping allocator exhaustion explicit and fatal in library APIs.
2. hax's compact rewrite has a concurrent-append race. I recommend a per-file advisory
   lock around startup load/rewrite and one-write appends, with lock failure degrading
   to in-memory recall.
3. Ctrl-R prompt clipping checks locale for UTF-8. Zi already renders UTF-8 terminal
   UI and should use `…` when the prompt can display it, falling back to `<` only when
   terminal policy disables UTF-8.
4. The first revised implementation milestone should land prompt-history core,
   persistence, raw navigation/search, and slash admission before committing `/help`.
