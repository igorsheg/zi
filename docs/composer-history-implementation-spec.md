# Composer session-history implementation spec

Status: implemented

This specification defines shell-style Up/Down recall for the interactive composer. It compares Pi's editor history at `earendil-works/pi@0e6909f0`, OpenTUI's native editor mechanics at `anomalyco/opentui@0c8c4f7c`, OpenCode's prompt-history implementations at `anomalyco/opencode@cb8be9ba1` and `4678bd104`, and Grok Build's prompt-history browser at `xai-org/grok-build@98c3b243`.

The product decision is deliberate: OpenZi will implement Pi-style inline history, not a hybrid history UI. Up and Down remain ordinary multiline cursor movement until they reach a composer boundary; only then do they traverse the current session's prompts. OpenCode contributes proven OpenTUI boundary and draft-restoration mechanics. Grok Build contributes session scoping and retention lessons. Neither contributes a second history panel or persistence path.

This capability is **composer session history**. It is distinct from transcript scrolling, session selection, future transcript paging, and future fuzzy `/history` search.

## Outcomes

The implementation must provide:

1. Up/Down traversal of the current session's recent user prompts;
2. ordinary native vertical movement inside multiline and wrapped drafts;
3. exact restoration of the pre-browse draft after moving Down past the newest recalled prompt;
4. stable oldest/newest boundaries with no wrapping;
5. start placement when moving toward older prompts and end placement when moving toward newer prompts;
6. a bounded coding-agent projection over the authoritative append-only journal;
7. stable entry identity when session messages append during browsing;
8. one explicit Composer-owned browsing state with no Nano Store or mirrored history list;
9. semantic, instance-scoped, overridable history bindings with picker precedence;
10. native preservation of compact-paste and image extmarks during an Up/Down round trip;
11. no new persistence file, async loader, query cache, input renderable, or history overlay;
12. behavior and structural tests for boundaries, drafts, bounds, races, replacement, and cleanup.

## Non-goals

The first implementation does not add:

- global or cross-session prompt history;
- per-working-directory history shared by multiple sessions;
- Ctrl+R reverse search or a `/history` command;
- a visible history dropdown, picker frame, search panel, or fuzzy matcher;
- history paging or asynchronous history loading;
- a second JSONL file, database, sidecar, or new journal entry type;
- historical image-attachment recall;
- recall of image-only historical prompts;
- shell-command mode or separate shell-command history;
- insertion of cleared Ctrl+C drafts into history;
- pending queued input to history before it becomes a committed user message;
- branch-aware history beyond the current append-only session shape;
- deletion, editing, or export of historical entries;
- a generic editor-history framework or frontend-wide input model;
- changes to OpenTUI or replacement of `TextareaRenderable`.

Pending steering and follow-up input remains queue state and is restored with `app.message.dequeue`. Composer history begins only after the input is committed as a user message in the session journal.

# 1. Reference comparison

## Pi Mono

Relevant sources at the pinned commit:

- `packages/tui/src/components/editor.ts`
- `packages/tui/test/editor.test.ts`
- `packages/coding-agent/src/modes/interactive/interactive-mode.ts`
- `packages/coding-agent/src/core/keybindings.ts`

Pi's editor:

- trims admitted history text;
- ignores empty entries;
- omits consecutive duplicates while preserving non-consecutive duplicates;
- keeps at most 100 entries;
- stores entries newest first;
- captures the current editor draft when browsing starts;
- restores that draft after Down moves past the newest entry;
- places the cursor at the start after Up and at the end after Down;
- uses ordinary cursor movement until the first or last visual line;
- before browsing, makes a first Up on a non-empty first line snap to its start before recalling history;
- before browsing, makes a first Down on a non-empty last line snap to its end;
- while browsing, traverses immediately from the first or last visual line regardless of horizontal cursor position;
- exits browsing when text is edited or externally replaced;
- does not wrap at either history boundary.

Keep this complete interaction model.

Pi populates a fresh editor from its active context and separately records accepted live submissions in editor memory. OpenZi will not copy that storage placement: terminal components may not own copied session messages, and compaction should not determine whether an older user input remains recallable.

## OpenTUI

Relevant sources at the pinned commit:

- `packages/core/src/renderables/Textarea.ts`
- `packages/core/src/renderables/EditBufferRenderable.ts`
- `packages/core/src/edit-buffer.ts`
- `packages/core/src/editor-view.ts`
- `packages/core/src/lib/extmarks.ts`
- `packages/core/src/renderables/__tests__/Textarea.keybinding.test.ts`

OpenTUI owns editor mechanics rather than prompt-history policy. The required public mechanics already exist:

- `TextareaRenderable.cursorOffset`;
- `TextareaRenderable.visualCursor`;
- `TextareaRenderable.scrollY`;
- `TextareaRenderable.moveCursorUp()` and `moveCursorDown()`;
- `TextareaRenderable.editorView.getTotalVirtualLineCount()`;
- `EditBufferRenderable.replaceText()`;
- native undo and redo;
- extmark snapshots integrated with replace, undo, and redo.

The replacement distinction is load-bearing:

- `setText()` resets the edit buffer and clears native undo history;
- `replaceText()` records one undo point and preserves prior edit history.

History traversal therefore uses OpenTUI's wrapped `replaceText()` path when entering a not-yet-visited older entry, native `undo()` while moving newer, and native `redo()` when moving older through an already-visited path. It does not use the Composer's existing external `replaceText()` path, which intentionally resets programmatic editor state.

OpenTUI 0.4.5's default replacement primitive registers one unreclaimed memory slot per call in a 255-slot registry. Composer's version-pinned adapter keeps OpenTUI's extmark snapshot wrapper and invokes native replacement from stable per-entry slots. One browse assigns at most 100 slots. After draft restoration those slots remain quarantined while native redo references them; the next browse starts from a spare slot, whose successful replacement clears redo and makes the completed browse recyclable. Slots retained by an abandoned browse or ordinary native undo/redo remain pinned against recycling until `setText()` clears native history, but their stable entry-ID mappings remain available so later browses of the same immutable entries reuse those slots instead of duplicating them. The physical pool is bounded at `2 * 100 + 1` slots, enough for one fully pinned browse, one current browse, and its turnover spare. Encoded backing bytes remain owned by OpenTUI's `EditBuffer`; Composer retains only bounded entry IDs and slot handles. Remove this adapter when OpenTUI provides equivalent bounded public replacement.

OpenTUI's extmark controller snapshots marker state before wrapped replacement and restores it on undo. This lets the Composer recover the exact draft's compact-paste and image markers without copying marker payloads into a second draft model.

## OpenCode

Relevant pinned and current sources:

- `packages/tui/src/component/prompt/index.tsx`
- `packages/tui/src/prompt/history.tsx`
- `packages/tui/test/prompt/history.test.ts`
- `packages/app/src/components/prompt-input/history.ts`
- `packages/app/src/components/prompt-input/history-store.ts`
- `packages/app/src/components/prompt-input/history.test.ts`

Keep:

- semantic previous/next history actions;
- picker and autocomplete precedence over history;
- first/last visual-row detection using `scrollY + visualCursor.visualRow`;
- explicit saved-draft restoration;
- no wrap at the oldest entry;
- moving Down from the newest entry back to the saved draft;
- distinct cursor placement for older and newer movement;
- structured tests for draft preservation and attachment-sensitive equality.

Reject:

- process-global prompt history;
- frontend persistence of a copied history list;
- another prompt-history JSONL file;
- cross-session recall as the default Up/Down behavior;
- mirroring session messages into a frontend store.

OpenCode's attachment-preserving prompt entries are useful evidence, but historical attachment recall is deferred until coding-agent exposes a bounded client-neutral prompt payload rather than only text. The first OpenZi slice still preserves attachments belonging to the current unsent draft.

## Grok Build

Relevant sources at the pinned commit:

- `crates/codegen/xai-grok-pager/src/app/agent_view/prompt.rs`
- `crates/codegen/xai-grok-pager/src/views/history_search.rs`
- `crates/codegen/xai-grok-pager/src/app/dispatch/prompt.rs`
- `crates/codegen/xai-grok-shell/src/session/prompt_history.rs`
- `crates/codegen/xai-grok-pager/src/slash/commands/history.rs`

Keep:

- current-session filtering for ordinary Up-arrow browse;
- a hard in-memory retention limit;
- newest-first admission;
- no wrap at the oldest entry;
- a deterministic return to the draft after the newest entry;
- explicit browse-mode state rather than coordinated booleans.

Reject for this capability:

- opening a history overlay from Up on an empty composer;
- background fuzzy matching and animation ticks;
- a `/history` panel coupled to basic Up/Down traversal;
- move-to-front deduplication, which changes chronological recall;
- per-CWD prompt-history persistence with up to 10,000 copied strings;
- adding cleared drafts to history;
- ACP and actor ownership.

A future explicit history-search capability may reconsider the search panel after a coding-agent query operation and its bounds exist. It must not be smuggled into basic composer navigation.

## Decision matrix

| Concern             | Pi                               | OpenCode                                        | Grok Build                                  | OpenZi decision                             |
| ------------------- | -------------------------------- | ----------------------------------------------- | ------------------------------------------- | ------------------------------------------- |
| Product interaction | Inline shell-style traversal     | Inline traversal; some clients persist globally | Visible browse/search panel                 | Pi                                          |
| Cursor boundary     | First/last visual line           | OpenTUI visual row plus scroll offset           | Empty composer opens browse                 | Pi behavior with OpenCode/OpenTUI mechanics |
| Draft restoration   | Editor-state snapshot            | Saved prompt/parts                              | Saved text                                  | Native OpenTUI undo/extmark snapshot        |
| History source      | Editor-owned list                | Frontend history store or session fetch         | Per-CWD sidecar plus current-session filter | Current `SessionManager` journal            |
| Retention           | 100                              | 50 or 100 depending client                      | 200 in memory, 10,000 persisted             | 100 bounded journal references              |
| Deduplication       | Consecutive                      | Consecutive structural equality                 | Move matching text to front                 | Consecutive exact trimmed text              |
| Compaction          | Fresh editor sees active context | Session messages                                | Separate prompt history                     | Full journal, independent of active context |
| Historical images   | Text extraction                  | Structured attachment recall                    | Text                                        | Deferred; mixed prompts recall text only    |
| Keybindings         | Semantic editor cursor actions   | Semantic history actions                        | Fixed browse entry plus panel keys          | Instance-scoped semantic history actions    |

# 2. Canonical language

**Composer session history** is the bounded sequence of text-bearing user prompts committed to the current `SessionManager` journal and eligible for Up/Down recall.

**History entry** is a stable journal entry ID plus exact trimmed user text. It is not a copied `AgentMessage`, transcript row, queued input, or persisted sidecar record.

**History source** is the narrow current-session interface injected into the Composer. It can return the latest eligible entry and the next older eligible entry by stable ID. It owns no terminal state.

**History browsing** is the Composer's temporary navigation state after an entry has replaced the draft and before the draft is restored, the input is edited, or an external replacement resets the Composer.

**Draft** is the exact native textarea state that exists when browsing begins, including text, cursor, undo position, compact-paste extmarks, and image extmarks. OpenTUI's edit buffer and extmark history remain its owner.

**Older movement** means moving toward earlier committed prompts. It is normally Up.

**Newer movement** means moving toward later committed prompts and eventually back to the draft. It is normally Down.

**Visual boundary** is the first or last wrapped visual row in the complete textarea buffer, not merely the first or last visible viewport row.

# 3. Owners

| Concern                                                           | Owner                                             |
| ----------------------------------------------------------------- | ------------------------------------------------- |
| Complete append-only session entries                              | `SessionManager`                                  |
| Bounded eligible-history reference index                          | `SessionManager`                                  |
| Client-independent history lookup boundary                        | `AgentSession`                                    |
| Effective physical bindings and closed prompt actions             | `InteractiveKeybindings`                          |
| Native text, cursor, undo/redo, viewport, selection, and extmarks | OpenTUI `TextareaRenderable`                      |
| Composer history traversal state and visited entry IDs            | `Composer`                                        |
| Key precedence and history action application                     | `PromptView`                                      |
| Active image payload admission and authoritative attachment state | `PromptStore`                                     |
| Session replacement and old-screen disposal                       | `InteractiveMode` / `InteractiveStore` generation |

No owner retains a copied history timeline in the TUI. `SessionManager` may retain at most 100 references to entries it already owns. `Composer` may retain at most 100 stable entry IDs in its browse zipper and current slot assignment, plus at most 201 bounded native slot handles across current, completed, and pinned browse lifetimes. Encoded slot bytes remain in OpenTUI's `EditBuffer`; Composer never retains historical message text.

No `PromptState` field, writable Nano Store, module-global history, root-store entry, or generic history manager is added.

# 4. Coding-agent history projection

## Public value

The coding-agent boundary exposes a text-only value:

```ts
export interface SessionPromptHistoryEntry {
  readonly entryId: string
  readonly text: string
}
```

The target `AgentSession` interface is deliberately narrow:

```ts
latestPromptHistoryEntry(): SessionPromptHistoryEntry | undefined
olderPromptHistoryEntry(entryId: string): SessionPromptHistoryEntry | undefined
```

`AgentSession` delegates to its `SessionManager`. It does not build or retain another history list.

The Composer receives a structurally equivalent TUI-owned source interface rather than importing `SessionManager`:

```ts
export interface ComposerHistorySource {
  latest(): SessionPromptHistoryEntry | undefined
  older(entryId: string): SessionPromptHistoryEntry | undefined
}
```

The exact local type name may differ, but the source remains latest-plus-older lookup. Do not expose the complete array merely to simplify traversal.

## Eligible entries

An entry is eligible when:

1. `entry.type === "message"`;
2. `entry.message.role === "user"`;
3. its content contains one or more text parts, or is a legacy string;
4. concatenated text after `trim()` is non-empty;
5. its UTF-8 text is within `maxSessionPromptHistoryEntryBytes`;
6. it is not an exact consecutive duplicate of the latest eligible text.

Text parts are concatenated in source order with no invented separator. Trimming follows Pi's submitted-history behavior. Internal whitespace and newlines are preserved exactly.

Image parts do not produce display labels in history text. A mixed text/image prompt contributes its text. An image-only prompt is ineligible in the first slice.

## Bounds

Add explicit exported limits:

```ts
export const maxSessionPromptHistoryEntries = 100
export const maxSessionPromptHistoryEntryBytes = 1024 * 1024
```

The projection stores references, not copied text. Nevertheless, extraction must not build an oversized concatenated string before enforcing the byte limit. Walk text parts in order, accumulate UTF-8 bytes, and reject the candidate as soon as it exceeds the entry limit.

The existing 64 MiB session-file bound remains the outer bound for the authoritative journal. No independent aggregate payload bound is needed for the reference index because it owns no text payloads.

## Construction and append

`SessionManager.open()` rebuilds the bounded index by considering validated entries in chronological order. `SessionManager.appendMessage()` updates the index only after the journal append has succeeded and the in-memory entry has committed.

The index stores oldest to newest so stable older lookup is direct within a maximum of 100 references. Admission evicts the oldest reference when the count bound is exceeded.

Compaction markers do not alter the index. `activeEntries()` and `activeMessages()` remain provider-context projections; composer history deliberately derives from `entries()`, the full journal. A resumed compacted session therefore retains recent eligible prompts even when they precede the active-context marker, subject to the 100-entry limit.

No persistence format changes. Old and new sessions derive the same projection from existing user messages.

## Identity and concurrent append

History traversal uses `SessionEntry.id`, not an array offset. A newly committed message can enter the catalog while the Composer is browsing without changing the identity of the recalled entry.

The Composer snapshots the newest entry ID only by entering browsing at that entry. It never asks for a newer entry during the same browse; Down follows native undo back through entries actually visited and then restores the original draft. Messages appended after browsing starts become visible the next time browsing starts from `idle`.

This avoids index drift and makes stale completion irrelevant: all history operations are synchronous, and session replacement destroys the old Composer rather than rebinding its source.

# 5. Composer state and transitions

## Direct state union

`Composer` owns this private union:

```ts
type ComposerHistoryState =
  | { readonly type: "idle" }
  | {
      readonly type: "browsing"
      /** Nearest previously visited older entry first. */
      readonly olderEntryIds: readonly string[]
      readonly currentEntryId: string
      /** Nearest visited newer entry first. */
      readonly newerEntryIds: readonly string[]
    }
```

The two ID arrays form a zipper around the current entry. Their aggregate count may not exceed `maxSessionPromptHistoryEntries`. Text remains only in OpenTUI's current buffer and undo/redo history.

Do not represent browsing with `historyIndex`, `savedDraft?`, and `isBrowsing` fields. Do not retain historical strings in this state.

## Transition table

| Current state | Request              | Condition                                | Next state                                                  | Native effect                                |
| ------------- | -------------------- | ---------------------------------------- | ----------------------------------------------------------- | -------------------------------------------- |
| `idle`        | older                | latest unavailable                       | `idle`                                                      | none                                         |
| `idle`        | older                | latest available                         | browsing latest                                             | `replaceText(latest.text)`, cursor start     |
| browsing      | older                | `olderEntryIds` non-empty                | pop nearest older into current; push old current into newer | `redo()`, cursor start                       |
| browsing      | older                | no visited older; source older available | current becomes returned older; push old current into newer | `replaceText(older.text)`, cursor start      |
| browsing      | older                | source older unavailable                 | unchanged                                                   | none                                         |
| `idle`        | newer                | always                                   | `idle`                                                      | none                                         |
| browsing      | newer                | `newerEntryIds` non-empty                | pop nearest newer into current; push old current into older | `undo()`, cursor end                         |
| browsing      | newer                | no visited newer                         | `idle`                                                      | `undo()` restores the exact draft and cursor |
| browsing      | native content edit  | always                                   | `idle`                                                      | native edit already applied                  |
| browsing      | external replacement | always                                   | `idle`                                                      | existing external replacement                |
| any           | destroy              | always                                   | released                                                    | Composer subtree destruction                 |

The owner records the state transition before applying the synchronous native effect. History-owned replace/undo/redo suppresses ordinary content-change detachment during that effect, then emits one normal content notification after text and cursor are coherent. A failed native effect restores the preceding history state before propagating the failure.

An ordinary native edit, paste, image insertion/deletion, undo, redo, or programmatic non-history replacement exits browsing and releases the visited IDs. Horizontal cursor movement alone does not exit browsing.

## Entering older history

At the history boundary in `idle`:

1. ask the source for `latest()`;
2. if absent, leave state and buffer unchanged;
3. record browsing with that entry as current;
4. call native `replaceText(entry.text)` rather than `setText()`;
5. place the cursor at display offset zero;
6. report one content change;
7. allow PromptView to synchronize active image markers.

`replaceText()` creates the undo point that owns the draft. The Composer does not copy draft text, markers, images, selection, or cursor into JavaScript state.

## Moving farther older

If an older entry was already visited and then undone, use native `redo()`. Otherwise query `older(currentEntryId)`, append only the stable ID to the zipper, and use native `replaceText()` with the returned text.

Every older movement places the cursor at the start. This means repeated Up can continue immediately. Pressing Down first on a multiline recalled entry still performs native cursor movement until the end boundary; it does not skip the entry's internal lines.

## Moving newer and restoring the draft

At the newer history boundary, native `undo()` restores the preceding buffer snapshot:

- when another recalled entry remains newer, retain browsing and place the cursor at that entry's display-width end;
- when no recalled entry remains newer, transition to `idle` and preserve the cursor restored by native undo.

The final undo restores the exact draft, including its original cursor and extmarks. Do not force the cursor to the draft's end.

## Editing a recalled entry

The first ordinary content mutation transitions to `idle` before notifying PromptStore or picker logic. The recalled text remains in the buffer and becomes a normal editable draft. Later Up begins a fresh browse at the newest current session entry rather than continuing from the abandoned zipper.

Native undo points created by the browse remain part of the textarea's owned edit history. Do not clear the entire edit buffer merely to hide those points; doing so would destroy valid pre-browse undo state.

# 6. Vertical boundary mechanics

## Semantic action, native movement

`InteractiveKeybindings` adds:

```text
tui.input.historyPrevious  Up    Previous session prompt
tui.input.historyNext      Down  Next session prompt
```

The corresponding closed prompt actions are:

```ts
"history_previous" | "history_next"
```

These actions mean **vertical prompt navigation with history at the boundary**, not unconditional text replacement. With the default bindings, PromptView consumes plain Up/Down and asks Composer to perform either native movement or history traversal.

If a history binding is disabled, plain Up/Down falls through to OpenTUI and remains ordinary cursor movement without history. If rebound, the effective key performs the same vertical/history behavior while OpenTUI's unclaimed arrow keys retain native cursor movement.

Both bindings are overridable. Intentional default overlap with `tui.select.up` and `tui.select.down` is resolved by context rather than reported as a conflict.

## Previous boundary algorithm

For `history_previous`:

1. if native selection is active, call ordinary `moveCursorUp()` and stop;
2. compute the global visual row as `scrollY + visualCursor.visualRow`;
3. while browsing, if the global visual row is zero, request older history immediately;
4. while idle, if `cursorOffset === 0`, request older history;
5. otherwise, if the global visual row is zero, set `cursorOffset = 0` and stop;
6. otherwise call `moveCursorUp()`.

The idle snap in step 5 matches Pi and OpenCode: a non-empty first line reaches its start on one Up and enters history on the next. Once browsing, horizontal movement on the first visual line does not add another snap before older traversal.

## Next boundary algorithm

For `history_next`:

1. if native selection is active, call ordinary `moveCursorDown()` and stop;
2. compute the buffer-end display offset using the Composer's grapheme/cell-aware offset function;
3. compute:

```ts
const globalVisualRow = input.scrollY + input.visualCursor.visualRow
const finalVisualRow = Math.max(0, input.editorView.getTotalVirtualLineCount() - 1)
```

4. while browsing, if the rows are equal, request newer history immediately;
5. while idle, if `cursorOffset` equals the end offset, request newer history;
6. otherwise, if the rows are equal, set the cursor to the buffer-end display offset and stop;
7. otherwise call `moveCursorDown()`.

The end snap applies only before browsing. Once browsing, horizontal movement on the last visual line does not delay newer traversal. Do not compare `cursorOffset` with JavaScript `text.length`; wide graphemes and newlines use OpenTUI display offsets.

## Context precedence

Prompt action precedence becomes:

1. native selection copy;
2. picker confirm/complete/cancel/up/down;
3. foreground-task backgrounding and clipboard actions;
4. interruption, clear, and empty-editor exit;
5. follow-up and queue restoration;
6. newline and submit;
7. composer history previous/next;
8. ordinary OpenTUI handling for unmatched input.

History is enabled only when:

- `PromptWorkflow.type === "idle"`;
- no picker presentation is active;
- the input is not a secret authentication prompt.

A picker consumes its configured Up/Down before history. Modified arrows not claimed by a semantic action retain their existing OpenTUI selection behavior outside a picker.

# 7. Paste and image-marker synchronization

## Draft preservation

The current Composer registers extmarks before history can run. OpenTUI's wrapped `replaceText()` therefore saves the draft's compact-paste and image extmarks beside the native undo point. Down through the final history entry restores those exact markers and payload references.

Tests must prove restoration of:

- displayed compact-paste labels;
- exact expanded paste text;
- image marker labels;
- `Composer.activeImages()` identity and order;
- original cursor offset.

No `ComposerDraft` payload or duplicated paste/image storage is introduced.

## Historical entries

History entries are text-only in this slice. Replacing the draft with a recalled entry clears its extmarks, so active Composer images become empty. A mixed historical message recalls only its text. An image-only message is not indexed.

After any `history_changed` result, `PromptView` reads `composer.activeImages()`, updates its `#syncedImages` identity, and reports the list through `PromptStore.imageMarkersChanged()`. This preserves PromptStore as the authoritative owner of active image payloads and prevents its next render update from reinserting stale draft markers.

When Down restores the draft, the same path reports the restored image references. Existing count and encoded-byte validation remains authoritative. No component writes PromptState directly.

Ordinary cursor-only history actions do not alter image state and need not publish another state value.

# 8. Session replacement, compaction, queues, and commands

## Session replacement

One `SessionScreen` captures one current `AgentSession` in the Composer history source. `InteractiveStore` generation replacement destroys that screen, Composer, history zipper, source closure, native undo resources, and subscriptions before constructing the replacement screen.

Do not rebind an existing Composer to another session. No callback from a destroyed screen may query or mutate the replacement.

## Compaction

Composer history reads the full bounded journal projection. A compaction marker changes active provider context and transcript projection but does not remove eligible history references. Successful compaction therefore leaves live browsing stable, and a resumed compacted session rebuilds history from the full journal.

No compaction event copies or rebuilds a TUI history list.

## Queues

A queued steering or follow-up input is not yet composer session history. It remains in `AgentSession.queuedInputs` and uses the existing `app.message.dequeue` restoration flow.

When Pi agent core later admits it as a user message and `SessionManager.appendMessage()` commits it, the coding-agent history projection admits it. This avoids mirroring queue state in history and prevents canceled queue items from becoming durable recall entries.

## Slash commands and resources

Built-in terminal slash commands handled by PromptStore do not enter session history because they do not produce user messages. Resource commands that reach `AgentSession` are recalled from the durable user message produced after expansion, matching the journal's authoritative content.

This first slice does not add a second raw-input journal field merely to preserve pre-expansion spelling.

# 9. Implementation plan

## Slice 1: coding-agent projection

Change:

- `packages/coding-agent/src/session-manager.ts`
- `packages/coding-agent/src/agent-session.ts`
- `packages/coding-agent/test/session-manager.test.ts`

Deliver:

1. `SessionPromptHistoryEntry` and explicit bounds;
2. bounded reference indexing on open and append;
3. exact text extraction and consecutive deduplication;
4. latest and stable older lookup;
5. `AgentSession` delegation;
6. tests for full-journal, compaction, restore, identity, and bounds.

No TUI code lands before this boundary is behavior-tested.

## Slice 2: Composer transitions

Change:

- `packages/tui/src/components/composer.ts`
- `packages/tui/src/components/composer-history-replacement.ts`
- `packages/tui/test/composer.test.ts`

Deliver:

1. the injected narrow history source;
2. direct `idle | browsing` zipper state;
3. visual-boundary movement;
4. native replace/undo/redo traversal;
5. ordinary-edit and external-replacement reset;
6. extmark/image/paste restoration tests;
7. display-width cursor tests.

The Composer test source is a small immutable fake implementing latest/older lookup. Do not instantiate an AgentSession in component tests.

## Slice 3: semantic key and prompt integration

Change:

- `packages/tui/src/interactive/interactive-keybindings.ts`
- `packages/tui/src/interactive/prompt/view.ts`
- `packages/tui/test/interactive/interactive-keybindings.test.ts`
- new `packages/tui/test/interactive/prompt-history.test.ts`

Deliver:

1. semantic IDs, defaults, metadata, overrides, and closed actions;
2. idle/picker/workflow context gating;
3. PromptView wiring to the captured current session;
4. active-image synchronization after history transitions;
5. real OpenTUI tests for traversal, picker priority, queues, and replacement.

`PromptStore`, `PromptState`, `InteractiveStore`, and `PickerStack` do not gain history state.

## Slice 4: documentation and parity evidence

After behavior is green, update:

- `docs/adr/0008-composer-owned-picker-stack.md`;
- `docs/adr/0010-interactive-mode-owns-keybindings.md`;
- `docs/tui-architecture.md`;
- `docs/parity-roadmap.md`.

Record the intentional deviations from Pi:

- the catalog is coding-agent-owned rather than editor-owned;
- resumed history comes from the full journal rather than only active context;
- queued input enters history only when committed;
- historical images are deferred.

# 10. Test matrix

## Coding-agent behavior

| Behavior                                               | Test                      |
| ------------------------------------------------------ | ------------------------- |
| Empty session has no latest entry                      | `session-manager.test.ts` |
| Latest and older traversal is chronological            | `session-manager.test.ts` |
| Consecutive duplicate omitted                          | `session-manager.test.ts` |
| Non-consecutive duplicate retained                     | `session-manager.test.ts` |
| Empty and whitespace-only text omitted                 | `session-manager.test.ts` |
| Mixed text/image message contributes text              | `session-manager.test.ts` |
| Image-only message omitted                             | `session-manager.test.ts` |
| More than 100 entries evicts oldest references         | `session-manager.test.ts` |
| Oversized text omitted without oversized concatenation | `session-manager.test.ts` |
| Compaction marker does not erase history               | `session-manager.test.ts` |
| Opened journal rebuilds the same projection            | `session-manager.test.ts` |
| Appended message receives stable ID lookup             | `session-manager.test.ts` |

## Composer transitions

| Behavior                                                     | Test               |
| ------------------------------------------------------------ | ------------------ |
| Empty source leaves buffer unchanged                         | `composer.test.ts` |
| First Up recalls latest                                      | `composer.test.ts` |
| Repeated Up reaches oldest and stops                         | `composer.test.ts` |
| Down traverses newer and restores draft                      | `composer.test.ts` |
| Up after Down uses visited redo path                         | `composer.test.ts` |
| Edit exits browsing                                          | `composer.test.ts` |
| External replacement exits browsing                          | `composer.test.ts` |
| Idle first-line nonzero cursor snaps before recall           | `composer.test.ts` |
| Idle last-line non-end cursor snaps to the buffer end        | `composer.test.ts` |
| Browsing boundary traversal ignores horizontal cursor offset | `composer.test.ts` |
| Wrapped/multiline cursor movement precedes history           | `composer.test.ts` |
| Selection collapses/moves rather than opening history        | `composer.test.ts` |
| Older cursor starts at zero                                  | `composer.test.ts` |
| Newer cursor uses cell-aware end                             | `composer.test.ts` |
| Draft restores its original cursor                           | `composer.test.ts` |
| Compact paste marker and exact payload restore               | `composer.test.ts` |
| Image markers and references restore                         | `composer.test.ts` |
| Browse round trip preserves prior native undo                | `composer.test.ts` |
| Repeated complete traversals reuse bounded native slots      | `composer.test.ts` |
| Catalog turnover recalls a new ID without editor reset       | `composer.test.ts` |
| Repeated abandoned browses reuse pinned stable-ID slots      | `composer.test.ts` |
| Slots retained by ordinary native redo are not recycled      | `composer.test.ts` |
| Native replacement failure restores the previous zipper      | `composer.test.ts` |
| New source append during browse does not shift visited path  | `composer.test.ts` |

## Interactive behavior

| Behavior                                                       | Test                                     |
| -------------------------------------------------------------- | ---------------------------------------- |
| Real committed session messages are recalled                   | `prompt-history.test.ts`                 |
| Default Up/Down drive the Composer                             | `prompt-history.test.ts`                 |
| Effective overrides drive history                              | `prompt-history.test.ts`                 |
| Disabled binding leaves native cursor movement only            | `prompt-history.test.ts`                 |
| Command/model/settings picker navigation wins                  | `prompt-history.test.ts`                 |
| Auth and non-idle workflows do not expose history              | `prompt-history.test.ts`                 |
| Queued input remains absent until committed                    | `prompt-history.test.ts`                 |
| Alt+Up queue restoration remains unchanged                     | existing queue test plus history fixture |
| Compacted restored session recalls pre-marker input            | `prompt-history.test.ts`                 |
| Session replacement switches catalogs and resets browse        | `prompt-history.test.ts`                 |
| Recalled draft attachment state clears and restores coherently | `prompt-history.test.ts`                 |
| Focus remains on the sole Composer textarea                    | `prompt-history.test.ts`                 |

Tests assert state, text, cursor, extmark payloads, stable IDs, and native behavior. They do not use wall-clock performance thresholds.

# 11. Rejected alternatives

## Editor-owned copied strings

Copying Pi's `string[]` directly into Composer is rejected. It would make a terminal component a second mutable session timeline, duplicate message text, and require explicit replacement synchronization.

## PromptStore-owned history

Putting history entries or an index in PromptState is rejected. Native text, cursor, extmarks, and undo already belong to Composer/OpenTUI. Splitting browsing between PromptStore and Composer would create coordinated state and one-shot edit traffic for a synchronous editor mechanic.

## InteractiveStore-owned history

InteractiveStore owns session identity, render revisions, and transient tool presentation. Prompt history has a narrower Composer lifetime and no independent observers. Adding it would enlarge the mode store and mirror session messages.

## PickerStack history

Basic Up/Down recall is not a choice flow. Opening a PickerStack frame would change focus semantics, prevent ordinary multiline cursor movement, and couple a shell-like editor behavior to a visible selector. A future explicit `/history` search may use a picker only after it has a separate product contract.

## Separate persistence

OpenCode's global JSONL and Grok Build's per-CWD JSONL are rejected. OpenZi already has a bounded authoritative session journal and immutable path owner. Another file would create deduplication, corruption, privacy, migration, and shutdown ordering that basic session recall does not require.

## `setText()` plus copied draft

Saving a JavaScript draft snapshot and using `setText()` is rejected. `setText()` clears native undo history, and a copied snapshot would have to duplicate cursor, selection, compact-paste payloads, image references, marker ranges, and future native editor state.

## Unconditional Up/Down interception

Replacing text whenever Up/Down is pressed is rejected. It breaks multiline editing and wrapped-line navigation. History is admitted only at native buffer boundaries.

## Historical attachment recall now

OpenCode proves structured attachment recall can work, but OpenZi's current durable message shape does not retain composer marker positions or a bounded client-neutral recall payload. Text-only historical entries keep the first slice narrow. Draft attachments still restore exactly through native extmark history.

# 12. Definition of done

The capability is complete when:

- [x] `SessionManager` owns a bounded reference-only prompt-history projection;
- [x] `AgentSession` exposes latest/older stable-ID lookup;
- [x] compaction and resume preserve full-journal history behavior;
- [x] Composer owns the direct `idle | browsing` zipper;
- [x] no TUI owner retains a copied history list;
- [x] default and overridden semantic bindings work;
- [x] picker and workflow precedence is fixed by tests;
- [x] multiline and wrapped cursor movement remains native;
- [x] oldest/newest traversal does not wrap;
- [x] Down past newest restores exact draft text, cursor, paste markers, and image markers;
- [x] ordinary edits and external replacement release browsing state;
- [x] pending queues remain separate until committed;
- [x] session replacement destroys old history state and callbacks;
- [x] all catalog and visited-ID collections have hard bounds;
- [x] coding-agent, Composer, keybinding, and interactive behavior tests pass;
- [x] architecture, ADR, and parity documentation records the implemented owner split and intentional deviations;
- [x] `bun run check` passes.
