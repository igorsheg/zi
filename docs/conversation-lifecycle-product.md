# Conversation lifecycle product contract

Status: approved

## Problem

Zi can resume a session only at process startup. During an interactive run, users
cannot start over, move to another conversation, discard recent turns, branch history,
or manually free context. They must quit and reconstruct state outside the product,
even though Zi already owns session persistence, history replay, and compaction
machinery.

## Milestone

Add these commands to the interactive REPL in registry order:

- `/new` with alias `/clear`;
- `/resume`;
- `/undo`;
- `/fork`;
- existing `/provider`, `/model`, and `/effort` remain after them;
- `/compact` follows future preset/config slots until those commands land;
- `/help` remains last among implemented commands.

This milestone implements the five lifecycle commands and the `ZI_TRANSCRIPT`
behavior they visibly reshape. It does not include later preset/config, `/session`,
`/tasks`, `/usage`, clipboard/editor, image-paste, login, notification, or keep-awake
work.

Every command runs between turns, remains in process-local prompt recall, and never
becomes model context or a recorded conversation item.

## `/new` and `/clear`

`/new` starts a fresh conversation while keeping the current provider, model, effort,
tools, and ordinary configuration. `/clear` is an exact alias.

Before clearing history, Zi settles running background tasks into the conversation
being left. If tasks are running, it announces how many are being stopped. The old
recorded session remains resumable.

The fresh conversation receives a new identity but stays lazy: no empty session file
is created. Usage totals and stale pause, retry, context, and deferred-compaction state
reset. Zi clears tracked temporary files after tasks stop and prints the normal startup
banner for the fresh conversation.

`/new PRESET` applies and persists the named preset before task settlement. An invalid
preset reports an error and leaves both selection and conversation unchanged. The later
`/preset` command is not required for this form. A successful preset remains active if
later task settlement prevents the reset; Zi reports that partial result and keeps the
current history. Terminal task notes use the newly applied preset selection.

Without a preset commit, failure to prepare or publish the fresh conversation keeps the
current selection and history intact. `/new` preserves recording availability: it
replaces an existing logger with a fresh lazy logger but does not silently re-enable a
run that is explicitly disabled or already unrecorded.

## `/resume`

Bare `/resume` opens the current-directory session picker used by startup resume. It
lists the newest eligible conversations, excludes the active session, supports search,
and stays in the normal terminal buffer.

No candidates reports `no past conversations in this directory`. Cancellation and
load failure leave the current conversation untouched. A loaded session must be valid
and non-empty under Zi's bounded session rules.

On success Zi:

1. settles running background tasks into the conversation being left;
2. adopts the selected history;
3. attempts to restore its recorded provider, model, effort, and preset;
4. resumes appending to the selected session when safe;
5. clears stale continuation, context, and deferred-compaction state;
6. replaces the transcript view;
7. briefly replays the latest visible user turn under a `resumed` heading.

History adoption distinguishes complete
restoration, core provider/model/effort restoration with a missing or invalid recorded
preset, and failure of the core selection. Only core failure keeps the current live
selection. Every partial outcome still adopts valid history and records the actual
selection with the next productive append.

If a stable bounded snapshot can be loaded but the selected file cannot be retained for
append, the in-memory resume still succeeds and Zi warns that the run is no longer
recorded. Explicit `--no-session` remains authoritative. Automatic recording eligibility
is reevaluated against the actual post-restore provider.

Resume does not reconstruct old usage totals and does not reset usage already incurred
by the current process. Tracked temporary files remain available.

## `/undo`

Bare `/undo` opens `revert to before which message`, newest typed prompt first. Only
ordinary user prompts count as turns; compaction seeds, continuations, and task notes do
not.

In noninteractive mode, a numeric argument is required. `/undo N` accepts one through
the number of typed turns. One removes the newest typed turn. With no typed turns Zi
reports `nothing to undo yet`. Invalid values report the accepted range.

Zi truncates the recorded branch before changing in-memory history. If truncation
fails, it reports that the conversation was left unchanged. Recording-disabled and
not-yet-materialized sessions can still undo in memory.

A successful undo:

- removes the selected prompt and every later item;
- makes the first discarded prompt available to prompt recall for editing;
- keeps cumulative billed usage and elapsed totals;
- invalidates the latest provider context snapshot;
- clears stale continuation and deferred-compaction state;
- preserves tracked temporary files;
- replaces the transcript view;
- briefly replays retained history under `undid N turn(s)`.

## `/fork`

Fork uses the same typed-turn picker and numeric rules as undo. `/fork N` accepts zero
through the number of typed turns. Zero clones the current tip, including non-empty
seed-only history with zero typed turns. Bare `/fork` requires at least one typed prompt;
empty or seed-only history reports `nothing to fork yet`.

Fork requires an existing materialized session file. Otherwise Zi reports
`/fork needs session recording (it is disabled or unavailable)`.

On success Zi creates an independent private session with a new identity and a
`forked_from` reference. The source branch is never truncated. Zi switches to the new
append target only after it is complete and safe to open.

A prefix fork removes the chosen suffix from live history, stages the first discarded
prompt for recall, invalidates the latest context snapshot, replaces the transcript,
and briefly replays `forked`. A tip fork keeps all history and the current context
snapshot. Both retain cumulative usage, running background tasks, and tracked temporary
files. Future appends go only to the new branch.

Any failure before the switch leaves the source branch and live conversation unchanged.
If cleanup of an incomplete destination cannot be confirmed, Zi reports an explicit
indeterminate-cleanup diagnostic rather than pretending no file may remain.

## `/compact`

`/compact` manually summarizes model-visible history to free context. It works whether
or not automatic compaction is enabled. `/compact FOCUS` adds the argument as summary
focus instructions.

Missing provider, missing model, and empty history produce specific notices without a
request. Otherwise Zi shows a `compacting` spinner and does not stream summary prose to
the terminal.

Compaction may make at most four provider attempts. It advertises normal tools for
request-prefix stability but never executes tool requests. A tool request receives a
rejected result and triggers another bounded attempt.

All completed-attempt usage remains billed and recorded, including rejected, failed,
or cancelled attempts. Either pause or abort cancels manual compaction, and late
cancellation wins over an otherwise complete summary.

Only a final non-empty, complete, tool-free summary commits. Success appends a
compaction seed without deleting earlier history, resets stale context and continuation
state, and prints `conversation compacted`. Other terminal outcomes are:

- `compaction cancelled`;
- `compaction failed: REASON`;
- `compaction produced no summary`.

Failure and cancellation never admit partial assistant summary text.

## History and terminal behavior

All pickers use Zi's normal-buffer terminal contract. Search, resize handling,
cancellation, configured theme, display width, cursor restoration, and terminal cleanup
match the existing session and selection pickers. No command enters the alternate
screen.

Resume, undo, and fork append a brief replay to terminal history; they cannot erase
previously printed output. Replay anchors only on ordinary user prompts and compaction
seeds. Continuations and task notes do not create empty replay headings.

Command failures remain consumed commands. They do not trigger provider execution,
first-send hooks, or durable prompt-history admission.

## Safety and limits

Zi preserves its existing bounded safety contract for every input. Session files, JSON lines, retained items, images, picker rows, label scans,
typed turns, command arguments, and compaction text remain capped by their current
public limits.

All lifecycle transitions are fail-closed before publication. Once an irreversible
file operation succeeds, remaining in-memory publication cannot fail. Concurrent or
externally changed session files produce explicit errors rather than memory/file
divergence.

## Acceptance checks

- `/help` advertises the new commands and `/clear` alias in registry order.
- Recognized lifecycle commands never reach the provider or conversation history.
- `/new` preserves selection, resets usage/history, settles tasks, keeps the old file,
  and lazily records the next conversation.
- Invalid `/new PRESET` is a complete no-op.
- `/resume` picker cancellation and malformed candidates are complete no-ops.
- Successful resume adopts history, replays the tail, uses the correct next-turn
  selection, and appends to the selected file.
- Selection restore failure still adopts valid history and stages the actual selection.
- `/undo` and `/fork` count only typed prompts and keep in-memory and JSONL cuts equal.
- Undo truncation failure preserves the complete branch.
- Fork preserves the source, gives the destination a new identity, and isolates future
  appends.
- Removed prompts reappear in prompt recall after undo.
- Manual compaction covers success, cancellation, provider failure, no summary, tool
  rejection, four-attempt exhaustion, usage ordering, and same-file persistence.
- Background tasks settle before new/resume and remain active across fork.
- Allocation, I/O, cancellation, and cleanup failures preserve documented transaction
  boundaries.
- PTY probes confirm picker, banner, replay, spinner, interruption, normal-buffer
  output, cursor restoration, and subsequent prompt usability.
- The complete project ready gate passes.
