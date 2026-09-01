# Prompt-recall product contract

Status: approved

References:

- `docs/prompt-recall-research.md`
- zig-ai implementation posture at `e2c5aef5f93015322891028a2048a217e7081687`

## Problem

Zi forgets every submitted prompt as soon as the next input starts. Up and Down are
recognized but do nothing, Ctrl-R does nothing, and restarting Zi loses all prompt
recall. Handled slash commands must remain available during the process without being
written to persistent prompt history.

## Product contract

Interactive terminal users can recall, edit, search, and resubmit recent prompts.
Recall is global across working directories and survives process restarts when
session recording is enabled.

Prompt recall is an input convenience only. Recalling or searching a line does not
change conversation state. A line affects the conversation only when it is submitted
through the normal prompt or command path.

## Admission

Zi admits non-empty terminal input after classifying it:

- Ordinary submitted prompts enter in-process recall and persistent history when
  recording is enabled.
- Prompts rejected later because provider or model setup is unavailable still enter
  recall and persistent history.
- Handled slash commands, including unknown commands and bad usage, enter in-process
  recall but are never persisted.
- Malformed slash-shaped lines remain ordinary prompts and follow ordinary
  persistence rules.
- Clearing a non-empty editor with Ctrl-C adds the discarded draft to in-process
  recall only.
- Empty submissions, continuation submissions, and program-generated messages never
  enter prompt recall.
- Piped and scripted input never loads or records prompt history.

Admission preserves the bytes retained by the terminal editor. Model-facing text
sanitation does not rewrite recalled input.

## Navigation

- Up and Ctrl-P recall older entries.
- Down and Ctrl-N recall newer entries.
- The first history move saves the current draft and cursor-independent content.
- Moving newer than the latest entry restores the saved draft.
- Navigation stops at the oldest entry and at the restored draft.
- Editing a recalled line changes only the editor. Navigating away and back restores
  the retained history value.
- Submitting a recalled line treats it as a new ordinary or command submission after
  classification.

History is exact and case-sensitive. Adding a value already present removes its old
copy and moves it to newest. Repeating the newest value changes neither order nor
count.

## Incremental search

Ctrl-R starts reverse incremental search in the current normal-buffer prompt.

- Typing extends a case-sensitive substring query and recomputes the match.
- Repeating Ctrl-R finds an older match.
- Ctrl-S finds a newer match.
- Backspace removes one UTF-8 unit from the query.
- A match replaces the editor contents and places the cursor at the first matched
  substring.
- No match displays an empty editor and marks the search prompt `(no match)`.
- Ctrl-C and Ctrl-G cancel, restoring the original buffer and cursor.
- Escape accepts the current result without submitting.
- LF accepts the result and returns to normal editing.
- CR accepts a non-empty result and submits it immediately.
- Accepting with no match restores the original buffer.
- Bracketed paste extends the query after dropping control bytes and newlines.

The search prompt occupies one terminal row, clips from the left when necessary, and
keeps the query tail visible with `…`. Search and cleanup remain in the normal
terminal buffer. Zi never enters the alternate screen.

## Retention and deduplication

- Zi retains at most 1000 prompts in process memory.
- The oldest prompt is evicted when a distinct newer prompt exceeds the limit.
- In-memory prompt size remains bounded by Zi's 1 MiB editor limit.
- Search and navigation operate on the retained deduplicated order.
- History is global across working directories.

## Persistent history

The history file is `<state_root>/history`:

- `$XDG_STATE_HOME/zi/history` when `XDG_STATE_HOME` is usable;
- otherwise `$HOME/.local/state/zi/history`.

Each prompt is one escaped physical record. Backslash becomes `\\` and embedded LF
becomes `\n`. Unknown escape forms remain literal when read.

- One encoded record, including its final newline, is limited to 65,536 bytes.
- A larger prompt remains available in the current process but is omitted from disk.
- Blank records are ignored.
- CRLF records load without the trailing CR.
- Oversized or corrupt records are skipped without preventing later records from
  loading.
- Startup keeps the newest 1000 deduplicated entries.
- After more than 3000 physical records, Zi rewrites the file to the retained set.
- Files are owner-only and final symlinks or non-regular files are not followed.
- Concurrent Zi processes append whole records without interleaving.
- Startup compaction coordinates with appends and does not lose concurrent appends.

A process-local entry later submitted as an ordinary prompt is written exactly once.

## Recording modes

Normal interactive recording:

- loads existing history;
- appends ordinary prompts;
- may compact an oversized record stream at startup.

`--no-session` and resolved `no_session=true` or `auto` for the mock provider:

- load existing history read-only;
- retain new ordinary prompts, commands, and discarded drafts for this process;
- do not create, append, or compact the history file.

When no usable state root exists, Zi provides in-process recall and silently skips
persistent history.

## Failure behavior

Prompt history is best-effort infrastructure:

- Missing files and directories are normal.
- Permission, open, lock, read, parse, append, flush, compact, rename, and close
  failures never stop the REPL.
- Unsafe file types are ignored rather than opened.
- A persistence failure degrades to in-process recall for the current run.
- Zi does not print recurring warnings for history failures.
- Allocation failure remains an explicit runtime error and must leave the old
  history and current editor intact.
- Terminal read, write, or mode-restoration errors keep their existing explicit
  failure behavior.

## Help behavior

Prompt recall adds no `/help` rows. Standard readline-style history navigation, search,
and ordinary motion bindings remain absent from the shortcut table. Existing help text
must not imply that handled slash commands persist across runs.

## Privacy and scope

Prompt history can contain sensitive text. Zi therefore:

- writes only to the private state root;
- creates the file with mode 0600;
- never adds piped input;
- does not expose history to providers unless the user explicitly submits a recalled
  line.

This milestone does not add history deletion commands, per-directory history,
configurable retention, shell-style expansion, fuzzy search, timestamps, metadata,
history synchronization, or session-conversation search.

## Acceptance checks

Core behavior:

- Up/Down and Ctrl-P/Ctrl-N traverse exact retained entries and restore a live draft.
- Recalled edits are temporary until submitted.
- Exact erasedups and 1000-entry eviction define the retention policy.
- Ctrl-R/Ctrl-S search, cancellation, acceptance, no-match, paste filtering, and UTF-8
  Backspace match the interaction contract.

Persistence:

- A normal prompt is recallable after restarting the built binary.
- A handled slash command is recallable during the process but absent after restart.
- No-session loads old history but leaves the file byte-for-byte unchanged.
- Piped input neither reads nor changes prompt history.
- Record encoding, bounds, corrupt-record recovery, permissions, and startup
  compaction are directly tested.
- Concurrent append and compaction cannot lose or interleave valid records.

Integration:

- Commands never enter model context or persistent prompt history.
- Ordinary prompts enter history before provider/model validation.
- Ctrl-C drafts enter only process-local recall.
- Search uses normal-buffer rendering and restores terminal state on acceptance,
  cancellation, error, and EOF.
- The built binary passes PTY probes for navigation, search, process-local command
  recall, restart persistence, no-session read-only behavior, and narrow terminal
  layout.
