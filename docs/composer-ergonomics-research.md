# Composer ergonomics research

Status: recommendation, 2026-07-26

## Scope

This note compares prompt-input behavior in:

- Pi Mono `5bc1c2c0a6f07e00e8c240304182f213ab8d311f`
- OpenCode `7534d23551f665e65080809975b4ca5c7d63807b`
- Grok Build `47348d13ec4508dcfe440e34c6d511bb02998fb2`
- OpenTUI `34e78b2fbf18fd969efdf5f3e2589d17d1f536f1`

These are supplemental research snapshots, not new dependency pins. Zi still builds against `@opentui/core@0.4.5`, documented at OpenTUI `0c8c4f7c` in [`reference-pins.md`](reference-pins.md).

The existing Zi decisions remain authoritative:

- `Composer` owns the sole `TextareaRenderable`, native editor state, paste/image markers, range edits, and inline history traversal.
- `PickerStack` owns below-composer choices without creating another input.
- `PromptStore` owns workflows and interprets accepted choices.
- `InteractiveKeybindings` owns semantic product bindings and precedence.
- OpenTUI remains authoritative for text, cursor, selection, wrapping, extmarks, and undo.

## Recommendation

Ship the inexpensive editing improvements before adding another prompt workflow:

1. Treat Up/Down movement through multiline and soft-wrapped input as the primary composer invariant. Zi already implements the basic state-dependent behavior; harden it as the first quality gate.
2. Characterize the remaining OpenTUI editing behavior that Zi already receives, then stop treating it as accidental behavior.
3. Make explicit draft clearing one native undo step and show the undo chord after clearing.
4. Add `Ctrl+P`/`Ctrl+N` picker navigation and `Ctrl+Return` as a newline fallback.
5. Make editor bindings replaceable and discoverable once OpenTUI can disable its default keymap cleanly.
6. Specify direct shell mode as the next larger prompt capability. All three reference products converge on it, but it requires a coding-agent operation and durability policy rather than a composer callback.

Do not add fuzzy-history UI, persistent stash, generated ghost suggestions, or submitted-turn rewind as composer primitives. They either conflict with an accepted Zi interaction or require a separate session/persistence decision.

## Current Zi routing audit

`Composer` overrides only bare Return and Shift+Return when constructing the textarea. `PromptView` resolves product behavior before the event reaches OpenTUI.

| Input                                                                                                            | Current owner and behavior                                                                                |
| ---------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Return                                                                                                           | `PromptView` submits; OpenTUI does not see it                                                             |
| Shift+Return                                                                                                     | `PromptView` inserts a native newline                                                                     |
| Ctrl+J / linefeed                                                                                                | OpenTUI inserts a newline, but the chord is not in Zi's semantic catalog                                  |
| Alt+Return                                                                                                       | `PromptView` sends or queues a follow-up; it is not a newline chord                                       |
| Up / Down                                                                                                        | `Composer` conditionally intercepts boundary/history behavior; interior movement falls through to OpenTUI |
| Return / Tab / Escape / Up / Down with a picker                                                                  | `PickerStack` policy wins                                                                                 |
| Ctrl+C                                                                                                           | Native-selection copy wins first; otherwise Zi clears or exits on a second press                          |
| Ctrl+V                                                                                                           | Zi's clipboard/image pipeline wins                                                                        |
| Ctrl+G                                                                                                           | External editor or foreground-task demotion wins by context                                               |
| Escape                                                                                                           | Picker cancellation or active-run interruption wins by context                                            |
| Ctrl+B/F, Ctrl+A/E, word movement/deletion, line kills, shifted selection, Home/End, Ctrl+-/Ctrl+., Cmd+Z, Cmd+A | OpenTUI handles the native editor mechanics                                                               |

The highest-value interaction is the state-dependent Up/Down path. Within a multiline or soft-wrapped draft, Up/Down must preserve native visual-row movement and its preferred horizontal column. History traversal begins only at the first or last visual row. Before browsing, a boundary press first snaps a non-boundary cursor to the start or end; while browsing, the corresponding boundary moves immediately to the adjacent history entry. Shift+Up/Down remains native selection, and an open picker wins over both movement and history.

Zi already implements this in `Composer.historyPrevious()` and `historyNext()` using OpenTUI's `scrollY`, `visualCursor`, visual-line count, and native movement. This is implemented behavior to strengthen, not a new history UI or a reason to mirror editor state.

OpenTUI 0.4.5 already implements movement and selection by character, logical line, visual line, buffer, and word; character/word/line deletion; select-all; newline; submit; undo; and redo. Zi should not reimplement those algorithms.

The weakness is policy ownership. OpenTUI always merges application bindings over its defaults. An application can add or replace a chord, but it cannot request a fully replacement keymap or explicitly unbind a default. Moving every editor chord into `PromptKeyAction` would solve the wrong problem: it would route local mutations through application workflow code and duplicate OpenTUI's editor dispatcher.

## Reference comparison and disposition

| Capability                                              | Reference evidence                                          |                     User value |         Cost | Zi disposition                                                                                                   |
| ------------------------------------------------------- | ----------------------------------------------------------- | -----------------------------: | -----------: | ---------------------------------------------------------------------------------------------------------------- |
| Multiline/wrapped visual Up/Down and history boundaries | Pi and OpenCode                                             |                        Highest |        Small | **P0:** first quality gate; preserve native visual movement before history traversal                             |
| Word/line movement, deletion, selection, undo/redo      | Pi, OpenCode, Grok Build                                    |                           High |        Small | **P0:** expose, integrate-test, and document the OpenTUI behavior already present                                |
| Undoable draft clear                                    | Grok Build advertises undo immediately after clear          |                           High | Small–medium | **P0:** one native undo step; restore paste/image markers exactly                                                |
| `Ctrl+P` / `Ctrl+N` picker movement                     | OpenCode dialogs and terminal conventions                   |                         Medium |         Tiny | **P0:** aliases on `tui.select.up/down`, active only while a picker is open                                      |
| Modified-Enter and linefeed fallbacks                   | Pi, OpenCode, Grok Build                                    | High in incompatible terminals |         Tiny | **P0:** retain Shift+Return and Ctrl+J; add Ctrl+Return; keep Alt+Return for follow-up                           |
| External editor                                         | All three                                                   |                           High |            — | Already implemented; keep replacement and subprocess lifetime in `PromptView`/`ExternalEditor`                   |
| Boundary-aware draft-preserving history                 | Pi and OpenCode                                             |                           High |            — | Already implemented from the full journal with bounded coding-agent lookup                                       |
| Text/image paste with atomic placeholders               | Pi, OpenCode, Grok Build                                    |                           High |            — | Already implemented with bounded payloads and exact submission/copy expansion                                    |
| Direct `!` shell mode                                   | Pi, OpenCode, Grok Build                                    |                           High | Medium–large | **P1:** separate coding-agent/session capability and prompt mode                                                 |
| Kill ring, yank, yank-pop                               | Pi; Grok Build exposes readline-style kill/yank             |      Medium for terminal users |       Medium | **P1:** only after OpenTUI exposes coherent edit results/transactions                                            |
| Reveal a compact paste in place                         | Grok Build                                                  |                         Medium |       Medium | **P1:** useful follow-up; Composer performs one native range transaction                                         |
| Searchable shortcut help                                | Pi, OpenCode, Grok Build                                    |                         Medium |       Medium | **P1:** derive from semantic and native binding catalogs after keymap ownership is complete                      |
| Multiline toggle                                        | Grok Build                                                  |                         Medium |       Medium | Defer. Zi already grows to multiple rows and has explicit newline chords; do not add mode state without evidence |
| Persistent stash/pop/list                               | OpenCode                                                    |                         Medium |        Large | Defer pending scope, attachment, encryption, and persistence decisions                                           |
| `/history` fuzzy-search panel                           | Grok Build                                                  |                         Medium |       Medium | Defer. Zi deliberately chose Pi-style inline boundary history rather than a hybrid history panel                 |
| Model/thinking mode cycling                             | Pi, OpenCode, Grok Build                                    |                         Medium |       Medium | Treat as AgentSession actions, not editor mechanics; consider after binding discovery                            |
| Generated next-prompt ghost text                        | Grok Build                                                  |    Unproven/high when accurate |   Very large | Defer pending cost, privacy, cancellation, and model-selection policy                                            |
| Undo/rewind a submitted turn                            | OpenCode undo; Grok Build rewind; Pi session-tree workflows |                           High |   Very large | Separate session transaction; never implement as textarea undo                                                   |
| Queue row edit/reorder/send-now                         | Grok Build and OpenCode queue workflows                     |                         Medium |        Large | Separate queue capability; current Alt+Up restore remains authoritative                                          |

## P0 implementation shape

### 1. Lock down multiline Up/Down

The existing `idle | browsing` Composer history state is sufficient. Whether the draft is multiline is derived from OpenTUI's current visual layout; it must not become another stored mode or copied text model.

Strengthen `packages/tui/test/composer.test.ts` and the real `PromptView` fixture around:

- explicit newlines and soft-wrapped visual rows;
- preservation of the preferred horizontal column across shorter and longer rows;
- first/last visual-row detection while the textarea is internally scrolled;
- idle boundary snap followed by history traversal on the next press;
- immediate boundary traversal once history browsing is active;
- Shift+Up/Down selection without history traversal;
- picker precedence without cursor movement;
- width changes that reflow the draft before the next movement.

These should be direct keypress tests where routing matters. OpenTUI remains responsible for calculating the destination cursor; Composer decides only whether the key means native movement or a history transition.

Current OpenCode implements this as layered fallthrough: its higher-priority history command returns `false` inside the draft, then `@opentui/keymap` runs the lower textarea `input.move.up/down` command. At a history boundary, the history command mutates the prompt and claims the key.

Zi should adopt that behavior without adopting OpenCode's mutable component command registry or copied persistent prompt history:

1. `InteractiveKeybindings` resolves the semantic history chord after picker precedence.
2. `PromptView` asks Composer whether history policy intercepts this press.
3. Composer returns one closed result: `native_fallthrough`, `cursor_boundary`, `history_changed`, or `history_boundary`.
4. For `native_fallthrough`, `PromptView` leaves the event unconsumed so the focused `TextareaRenderable` handles the original key.
5. For every other result, `PromptView` consumes the event; only `history_changed` requires attachment synchronization.

Zi previously consumed every history chord and had Composer manually call `moveCursorUp/Down()` for an interior row. The implemented fallthrough now preserves OpenTUI dispatch behavior and means a rebound history chord does not pretend to be an arrow key inside the draft.

### 2. Characterize remaining native editing

Add focused integration coverage rather than copying OpenTUI's entire editor test suite.

`packages/tui/test/composer.test.ts` should prove:

- word movement and deletion operate on the native cursor and selection;
- logical versus wrapped visual-line boundaries remain distinct;
- Ctrl+-/Ctrl+. and Cmd+Z/Cmd+Shift+Z preserve paste/image extmarks;
- a native edit detaches inline history browsing without losing the recalled draft's undo point;
- Unicode grapheme and wide-cell offsets remain valid.

A real `PromptView` fixture should prove that picker, history, clear, clipboard, and follow-up precedence do not shadow unrelated native editing chords.

Do not add editor-local actions to `PromptKeyAction` merely to test them. Until OpenTUI supports a replacement keymap, they remain fixed native mechanics.

### 3. Make clear recoverable

The current `PromptStore.clear()` emits a whole-input `replace` request. `Composer.replaceText()` calls OpenTUI `setText()`, which intentionally resets native history. That makes an accidental Ctrl+C destructive.

Use a distinct transition:

1. `PromptStore` decides whether Ctrl+C cancels a workflow or admits an ordinary draft discard.
2. For an ordinary discard, `PromptView` asks `Composer` to clear undoably.
3. `Composer` selects the entire native buffer and deletes the selection as one native edit. It does not copy text into store state.
4. The existing marker notification synchronizes the now-empty image list.
5. Native undo restores text, cursor-relevant editor history, paste extmarks, and image identity; marker notification restores the store's attachment references.
6. A built-in prompt notice says `Input cleared · Ctrl+- to undo` using the effective semantic/native hint.

Submission, session replacement, authentication transitions, and initial input still use hard-reset replacement. A submitted prompt must not reappear through textarea undo; submitted-turn undo is a different session operation.

Required races and bounds:

- clear → undo → redo;
- clear with compact paste and images;
- clear while browsing history;
- first and second Ctrl+C within the existing 500 ms exit window;
- picker/workflow cancellation must not create a draft undo point;
- repeated clear/undo must not grow application-retained payload collections.

### 4. Add low-risk aliases

Change only semantic defaults:

- `tui.select.up`: `Up`, `Ctrl+P`
- `tui.select.down`: `Down`, `Ctrl+N`
- `tui.input.newLine`: `Shift+Return`, `Ctrl+Return`

Ctrl+J remains OpenTUI's linefeed behavior until editor bindings join the semantic owner. Alt+Return remains `app.message.followUp`; changing it would break accepted queue behavior.

## P1 direct shell mode

Shell mode has the strongest cross-product convergence among the larger features. It still must not be implemented by spawning a process from `Composer`.

### Ownership

- `AgentSession` exposes one bounded direct-shell operation and owns durability, context inclusion, task lifetime, cancellation, and emitted events.
- The existing `SessionShell` owns the subprocess and output bounds.
- `PromptStore` owns an explicit `agent | shell` input mode and interprets submission.
- `PromptView` translates the `!` trigger and Escape/backspace mechanics into store operations.
- `Composer` only renders the mode presentation and edits command text.

Start with one shell mode whose output has a documented durable/context policy. Do not copy Pi's `!!` hidden-output variant until that second policy is explicitly chosen.

The operation must define:

- whether it is admitted during an agent run;
- whether output becomes provider context;
- the durable `bashExecution` entry shape;
- foreground/background behavior and capacity;
- cwd/environment ownership;
- output byte/time bounds;
- interruption versus kill versus terminal shutdown;
- whether failed commands stay in shell history or session prompt history.

This capability needs its own spec and behavior tests in coding-agent before terminal syntax is added.

## P1 kill ring and paste reveal

Both features need atomic range mutation but no new authoritative text model.

A Composer-owned kill ring may retain a small bounded list of deleted strings and a discriminated yank state. OpenTUI still computes word/line boundaries and performs deletion/insertion. Consecutive kills may coalesce; any unrelated edit ends yank-pop eligibility. The ring must have entry-count and byte bounds.

Paste reveal replaces one owned virtual marker with its retained payload in one undo step. It removes the marker payload after expansion so text is not retained twice. Undo restores the same marker identity and payload. The interaction needs a semantic command or unambiguous cursor affordance; bare Return should continue to submit by default.

Neither feature should proceed on top of more private OpenTUI reflection.

## OpenTUI support

OpenTUI should provide editor mechanics, not Zi product workflows.

### 1. Existing keymap fallthrough

`@opentui/keymap@0.4.5` already provides the general mechanism OpenCode uses: `registerManagedTextareaLayer()` suspends the textarea's built-in mappings, registers semantic editor commands against the focused renderable, and lets a rejected higher-priority command fall through to a lower binding.

Zi does not need that dependency to correct Up/Down routing. Its existing renderer listener can leave the original event unconsumed when Composer returns `native_fallthrough`. This preserves the instance-scoped `InteractiveKeybindings` owner and avoids introducing OpenCode's mutable component-level command registration.

If Zi later moves every editor binding into semantic policy, evaluate a narrow mode-owned adapter around `@opentui/keymap`; do not create a second mutable keybinding owner. The adapter would consume one immutable resolved binding catalog from `InteractiveKeybindings`, own registration/disposal, and keep product precedence outside renderables.

OpenTUI core's direct `TextareaRenderable.keyBindings` API still only merges over defaults. Applications using core without the keymap package cannot request a replacement map or explicit unbinding.

### 2. One atomic, undoable range-replacement API

OpenTUI needs a public operation that replaces a valid native offset range, places the cursor, shifts unaffected extmarks, records one undo entry, and restores the complete result on redo. It must define its offset coordinate system and expose boundary conversion helpers for graphemes, newlines, tabs, and wide cells.

Zi currently has to reach into private extmark snapshots and call `editBuffer.replaceTextOwned()` to make file completion one undo step. That adapter should disappear.

### 3. Bounded replacement history and memory

`replaceText()` currently registers backing memory retained by private arrays. Repeated whole-buffer history traversal requires Zi to reflect into native handles and recycle slots. OpenTUI should reclaim or reuse replacement storage when undo entries are evicted or redo is invalidated, and expose a configurable hard history bound.

No application should need access to `bufferPtr`, `textBufferPtr`, `_textBytes`, or `originalReplaceText`.

### 4. Correct extmark restoration

Undo/redo must keep the canonical extmark collection and every type index consistent. In 0.4.5, Zi uses `extmarks.getAll().filter(...)` because restored extmarks are not reliably rebuilt in the type index.

Range edits should have documented overlap/gravity behavior. Applications may reject edits intersecting owned atomic markers, but they should not rebuild extmark snapshots themselves.

### 5. Coherent edit results and notifications

A native action should report whether it changed content and, for deletion, the deleted range/text. A synchronous post-transaction notification should identify the action/revision without requiring applications to monkey-patch every mutating method.

That lets Zi detach history browsing, update marker-derived attachments, and maintain a bounded kill ring while OpenTUI remains the sole mutation engine.

### 6. Terminal input correctness

OpenTUI should normalize Return, keypad Enter, linefeed, and Kitty modified-Enter variants and expose terminal capability information for reliable hints. Submit must observe any pending IME composition commit. Characterization should cover CJK input, emoji graphemes, CR/CRLF bracketed paste, and terminals without enhanced keyboard reporting.

OpenTUI cannot infer Zi's follow-up, picker, clear, or interruption precedence; those remain application policy.

## Explicit non-goals

- No second textarea for search, completion, shell, or stash flows.
- No mirrored prompt string in `PromptStore`.
- No frontend copy of the session history timeline.
- No shell subprocess launched by a renderable.
- No generated suggestion request owned by the composer.
- No persistent stash without an explicit path, scope, retention, and secret-handling decision.
- No submitted-turn rewind implemented as native editor undo.
