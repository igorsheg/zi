# `@` project-file autocomplete implementation spec

Status: implemented

This specification defines OpenZi's first interactive `@` project-file autocomplete capability. It compares Pi's file-completion behavior at `earendil-works/pi@0e6909f0`, OpenCode's OpenTUI autocomplete and filesystem-search split at `anomalyco/opencode@cb8be9ba1` and `4678bd104`, OpenTUI's editor mechanics at `anomalyco/opentui@0c8c4f7c`, and Grok Build's `@` file-search state at `xai-org/grok-build@98c3b243`.

The product decision is deliberate: OpenZi will provide Pi-style textual `@path` completion through the existing below-composer `PickerStack`. OpenCode contributes the authoritative filesystem-owner split and display-offset handling. Grok Build contributes explicit token ranges, stale-generation rejection, and distinct file-versus-directory transitions. OpenTUI remains the native text, cursor, selection, extmark, and undo owner. OpenZi does not adopt a positioned popup, a second input, an unbounded project index, polling, structured file parts, atomic file chips, line-range browsing, or automatic file-content attachment.

This specification is governed by [ADR 0004](adr/0004-explicit-state-and-transitions.md), [ADR 0005](adr/0005-interactive-mode-owns-frontend-orchestration.md), [ADR 0008](adr/0008-composer-owned-picker-stack.md), [ADR 0010](adr/0010-interactive-mode-owns-keybindings.md), [ADR 0011](adr/0011-openzi-path-policy.md), and the [TUI hot-path and scaling implementation spec](tui-performance-implementation-spec.md). The version-pinned native replacement work follows the precedent established by the [Composer session-history implementation spec](composer-history-implementation-spec.md).

## Outcomes

The implementation must provide:

1. natural `@` activation at a valid token boundary anywhere in an ordinary composer draft;
2. recursive project-relative file and directory suggestions rooted at the current session's immutable `OpenZiPaths.cwd`;
3. deterministic fuzzy ranking of basename and nested-path matches;
4. a preferred seven-row below-composer frame that remains stable while the active query is rescored;
5. Enter and Tab acceptance, with file termination and directory continuation handled separately;
6. quoted completion for paths containing spaces or token delimiters;
7. display-width-correct parsing, replacement ranges, and cursor targets for Unicode drafts and paths;
8. one native undo step for an accepted completion while preserving unrelated compact-paste and image extmarks;
9. bounded, cancellable, single-flight filesystem work with no project-wide TUI catalog;
10. stale-result rejection across rapid typing, cursor movement, cancellation, disposal, and session replacement;
11. quiet exact-file, unmatched-refinement, and token-scoped Escape behavior that lets ordinary prose continue;
12. no startup scan, polling loop, file-content read, prompt-part schema, persistence format, or model-context mutation;
13. behavior and structural tests for parsing, ranking, bounds, races, native identity, undo, extmarks, and cleanup.

## Non-goals

The first implementation does not add:

- general Tab completion for bare `./`, absolute, shell, or slash-command argument paths;
- completion outside the current project through `../`, `~`, drive-qualified, UNC, or absolute paths;
- automatic reading or expansion of a completed file at submission;
- CLI `@file` argument processing or compatibility with Pi's separate initial-message file processor;
- structured provider file parts, MCP resources, agent mentions, reference aliases, or drag-and-drop files;
- atomic or specially styled `@file` extmarks after acceptance;
- line ranges such as `#10-20` or `:10-20`;
- a file preview, line viewer, split pane, modal, hover preview, or open-file action;
- frecency, recent-file ranking, query history, or persisted search state;
- Grok Build's `@!` hidden/ignored-file mode;
- traversal of directory symlinks outside the project root;
- a long-lived FFF, ripgrep, Nucleo, watchman, language-server, or custom native index;
- runtime downloading, bundling, or management of `fd` solely for this feature;
- a generic autocomplete-provider framework, query cache, root store, command bus, or second textarea;
- frontend ownership of cwd, ignore policy, filesystem subprocesses, or a copied file catalog.

Accepted completion remains ordinary prompt text. If OpenZi later adds semantic file attachment, it must define bounded file-content admission, durable representation, provider conversion, and client-neutral history independently of this feature.

# 1. Reference comparison

The repository pins are recorded in [`docs/reference-pins.md`](reference-pins.md). Relevant implementations were also compared with their current checkouts on 2026-07-21; the file-search mechanisms described below remain materially unchanged from the documented pins.

## Pi Mono

Relevant pinned sources:

- [`packages/tui/src/autocomplete.ts`](https://github.com/earendil-works/pi/blob/0e6909f0/packages/tui/src/autocomplete.ts)
- [`packages/tui/src/components/editor.ts`](https://github.com/earendil-works/pi/blob/0e6909f0/packages/tui/src/components/editor.ts)
- [`packages/tui/test/autocomplete.test.ts`](https://github.com/earendil-works/pi/blob/0e6909f0/packages/tui/test/autocomplete.test.ts)
- [`packages/tui/test/editor.test.ts`](https://github.com/earendil-works/pi/blob/0e6909f0/packages/tui/test/editor.test.ts)
- [`packages/coding-agent/src/modes/interactive/interactive-mode.ts`](https://github.com/earendil-works/pi/blob/0e6909f0/packages/coding-agent/src/modes/interactive/interactive-mode.ts)
- [`packages/coding-agent/src/utils/tools-manager.ts`](https://github.com/earendil-works/pi/blob/0e6909f0/packages/coding-agent/src/utils/tools-manager.ts)

Pi's combined TUI provider:

- recognizes an `@` token at a path delimiter;
- invokes `fd` asynchronously for recursive fuzzy file and directory search;
- roots search at the active session cwd unless an explicit path prefix scopes it elsewhere;
- asks `fd` for at most 100 entries and retains the top 20 candidates;
- includes hidden non-ignored entries, excludes `.git`, respects `fd` ignore policy, and follows symlinks;
- ranks exact basename, basename prefix, basename substring, and full-path substring matches;
- supports deep path queries such as `tui/src/auto`;
- uses `@"path with spaces"` and keeps the cursor inside a quoted directory completion;
- adds a trailing space after files but not directories;
- debounces natural attachment completion by 20 ms;
- aborts an active subprocess when typing continues;
- serializes requests and validates the complete text and cursor snapshot before applying a result;
- leaves the previously scored list visible while a replacement request is pending;
- closes the list when a current request has no suggestions, although editing the same token can trigger it again;
- records one editor undo snapshot before applying completion.

Keep:

- the observable `@path` text behavior;
- recursive nested-path matching;
- a 20-result boundary;
- a short natural-trigger debounce;
- explicit cancellation and stale text/cursor checks;
- separate file and directory completion behavior;
- quoted paths and single-step undo.

Change:

- the filesystem operation belongs to coding-agent rather than Pi's TUI package;
- search is restricted to `OpenZiPaths.cwd` rather than enumerating home, absolute, or parent scopes;
- OpenZi does not download or manage `fd` for this feature;
- directory symlinks are not followed outside the project root;
- the UI uses OpenZi's existing `PickerStack` rather than Pi TUI's `SelectList`;
- completion preserves OpenTUI-owned paste and image markers through an explicit range edit.

Pi calls these rows file attachments, but interactive submission sends the completed text unchanged to `AgentSession.prompt()`. Pi's CLI `@file` processing is a separate startup-input path. OpenZi keeps that separation: autocomplete does not imply file-content attachment.

## OpenCode

Relevant pinned sources:

- [`packages/tui/src/component/prompt/autocomplete.tsx`](https://github.com/anomalyco/opencode/blob/cb8be9ba1/packages/tui/src/component/prompt/autocomplete.tsx)
- [`packages/tui/src/prompt/display.ts`](https://github.com/anomalyco/opencode/blob/cb8be9ba1/packages/tui/src/prompt/display.ts)
- [`packages/core/src/filesystem/search.ts`](https://github.com/anomalyco/opencode/blob/cb8be9ba1/packages/core/src/filesystem/search.ts)

OpenCode:

- parses the nearest whitespace-delimited `@` trigger using display-width offsets;
- requests at most 20 filesystem results through its SDK rather than walking the tree in the prompt component;
- lets core filesystem search own FFF or background-ripgrep indexing and ranking;
- combines file rows with agents, MCP resources, and reference aliases;
- retains previous rows while a replacement query is loading;
- adds frecency to non-file candidates and trusts the filesystem searcher's file order;
- distinguishes files from directories and lets Tab expand a directory;
- inserts a structured file part plus a virtual extmark;
- optionally attaches a line range to the file URL;
- positions an autocomplete popup around the native textarea;
- hides when the cursor leaves the token or whitespace appears after the trigger, but a later edit inside the same token can reopen it.

Keep:

- the coding-agent/filesystem owner split;
- display-width conversion helpers around OpenTUI offsets;
- bounded server-side result admission;
- full current context validation before selection;
- directory expansion as a different transition from file acceptance;
- framework-independent key-layer precedence.

Reject:

- Solid component and context architecture;
- absolute popup positioning and its anchor polling;
- a mixed `@` catalog before OpenZi owns those other domains;
- structured frontend file parts and copied prompt payloads;
- file extmarks, frecency, line ranges, and resource URLs;
- FFF's retained native index and ripgrep fallback's large retained path arrays;
- stale visible rows that remain selectable against a newer query.

OpenCode demonstrates that filesystem search should be a non-frontend capability. It does not require OpenZi to adopt OpenCode's client/server state graph or attachment model.

## OpenTUI

Relevant pinned sources:

- [`packages/core/src/renderables/EditBufferRenderable.ts`](https://github.com/anomalyco/opentui/blob/0c8c4f7c/packages/core/src/renderables/EditBufferRenderable.ts)
- [`packages/core/src/edit-buffer.ts`](https://github.com/anomalyco/opentui/blob/0c8c4f7c/packages/core/src/edit-buffer.ts)
- [`packages/core/src/lib/extmarks.ts`](https://github.com/anomalyco/opentui/blob/0c8c4f7c/packages/core/src/lib/extmarks.ts)
- [`packages/solid/examples/components/autocomplete-demo.tsx`](https://github.com/anomalyco/opentui/blob/0c8c4f7c/packages/solid/examples/components/autocomplete-demo.tsx)

OpenTUI supplies editor mechanics, not autocomplete policy. The useful APIs are:

- `TextareaRenderable.onContentChange`;
- `TextareaRenderable.onCursorChange`;
- display-width `cursorOffset`;
- `logicalCursor`, `getTextRange()`, `deleteRange()`, and `insertText()`;
- `clearSelection()`;
- `EditBuffer.replaceTextOwned()`;
- native undo and redo;
- extmark snapshots integrated with wrapped edit-buffer mutations.

The OpenTUI autocomplete demo keeps trigger state, filtering, selection, and popup composition outside the input. OpenZi follows that ownership principle but uses the already accepted `PickerStack`, so no absolute anchor, second focus owner, or popup-position timer is needed.

The mutation distinction is load-bearing:

- `deleteRange()` followed by `insertText()` creates two native undo points;
- `setText()` clears prior undo history;
- wrapped `replaceText()` creates one undo point but clears extmarks;
- OpenTUI 0.4.5's default JavaScript `replaceText()` path also consumes one unreclaimed memory-registry slot per call;
- `replaceTextOwned()` creates one native undo point without consuming that JavaScript memory registry, but OpenTUI's extmark wrapper does not expose a public atomic range-replacement operation around it.

OpenZi therefore needs one small version-pinned Composer adapter for accepted completion. Section 9 defines it. Remove that adapter when OpenTUI exposes an equivalent public atomic range replacement or undo-group primitive.

## Grok Build

Relevant pinned sources:

- [`views/file_search/context.rs`](https://github.com/xai-org/grok-build/blob/98c3b243/crates/codegen/xai-grok-pager/src/views/file_search/context.rs)
- [`views/file_search/state.rs`](https://github.com/xai-org/grok-build/blob/98c3b243/crates/codegen/xai-grok-pager/src/views/file_search/state.rs)
- [`views/file_search/dropdown.rs`](https://github.com/xai-org/grok-build/blob/98c3b243/crates/codegen/xai-grok-pager/src/views/file_search/dropdown.rs)
- [`views/prompt_widget/mod.rs`](https://github.com/xai-org/grok-build/blob/98c3b243/crates/codegen/xai-grok-pager/src/views/prompt_widget/mod.rs)
- [`xai-grok-workspace/src/file_system/fuzzy.rs`](https://github.com/xai-org/grok-build/blob/98c3b243/crates/codegen/xai-grok-workspace/src/file_system/fuzzy.rs)
- [`xai-grok-shell/src/session/prompt_parser.rs`](https://github.com/xai-org/grok-build/blob/98c3b243/crates/codegen/xai-grok-shell/src/session/prompt_parser.rs)

Grok Build:

- represents the active `@` token as a byte range, cursor, and query;
- rejects email-like triggers;
- separates ordinary, directory, and hidden modes;
- owns query generation, selected index, scroll offset, and stale-result rejection in one file-search state;
- runs an ignore-aware background tree walk and Nucleo matcher;
- retains up to 1,000 matched rows from an index containing the walked tree;
- polls daemon results while the file picker may be active;
- renders the dropdown only while the context has non-empty results;
- distinguishes file acceptance from directory drill-down;
- groups accepted replacement into one undo operation;
- turns accepted files into atomic prompt elements;
- supports a file viewer and line ranges;
- parses submitted `@path` values, reads file contents, and injects them into provider context.

Keep:

- a direct context value with trigger range, token end, cursor, and query;
- email suppression;
- explicit file-versus-directory transitions;
- selected-result validation;
- generation-based stale completion rejection;
- one undo unit for completion;
- bounded symlink classification and deterministic result ordering lessons.

Reject:

- an always-retained full-tree matcher;
- worker and polling lifetimes tied to the prompt;
- 1,000 retained results;
- hidden-mode syntax in the first slice;
- Right-arrow completion, page navigation, mouse interaction, and line viewer;
- atomic file elements and submission-time file reads;
- ACP, actor, dashboard, and remote-workspace ownership.

Pi, OpenCode, and Grok all keep a manually typed exact path eligible until selection or a token delimiter, and all can reacquire an escaped token after another edit. OpenZi deliberately departs from that behavior because its accepted representation remains ordinary text rather than an atomic reference: an exact unquoted file already names its target, and Escape is a decision about the token rather than one draft revision.

Grok's provider-boundary expansion is a distinct attachment feature. Importing it into autocomplete would make typing a path silently change model context and persistence semantics without an admitted file-content owner.

## Decision matrix

| Concern                 | Pi                             | OpenCode                   | Grok Build                | OpenZi decision                            |
| ----------------------- | ------------------------------ | -------------------------- | ------------------------- | ------------------------------------------ |
| User syntax             | Textual `@path`                | Structured `@` mentions    | Atomic `@` elements       | Textual `@path`                            |
| Search owner            | Pi TUI provider                | Core filesystem service    | Pager/workspace daemon    | Coding-agent `ProjectFileSearch`           |
| Search lifetime         | Per query subprocess           | Long-lived index           | Long-lived daemon         | Per query, bounded single flight           |
| Scope                   | Cwd, parent, home, absolute    | Active project/location    | Active workspace root     | Exact `OpenZiPaths.cwd` only               |
| UI                      | Editor-owned select list       | Positioned popup           | Prompt dropdown           | Existing `PickerStack`                     |
| Result bound            | 20 retained from 100 `fd` rows | 20 from SDK                | Top 1,000                 | 20                                         |
| Stale work              | Abort + text/cursor snapshot   | Reactive resource identity | Generation counter        | Abort + operation/session/context identity |
| Directory selection     | Continue without space         | Tab expands                | Separate drill transition | Continue with trailing `/`                 |
| Accepted representation | Ordinary text                  | File part + extmark        | Atomic element            | Ordinary text                              |
| Submission              | Text unchanged                 | Structured file part       | Reads and injects content | Text unchanged                             |
| Undo                    | One editor snapshot            | Native mutations           | Undo group                | One native owned replacement               |
| Symlinks                | Follow                         | Backend-dependent          | Do not follow             | Do not traverse directory symlinks         |

# 2. Canonical language

**Project-file autocomplete** is the terminal interaction that scores bounded project-relative path matches for a file-completion context, presents useful choices in the existing picker, and replaces only that token after selection.

**File-completion context** is the parsed active token: trigger start, full token end, current cursor offset, decoded project-relative query, and quoted state. Its offsets use OpenTUI display-width units, including one unit for a newline. A valid context does not imply that a picker is visible.

**Project file match** is a validated project-relative path plus its `file | directory` kind. It contains no file contents, stat payload, renderable, callback, or provider part.

**Project file search** is the bounded coding-agent operation rooted at one immutable `OpenZiPaths.cwd`. It searches current filesystem names and returns ranked matches without retaining a complete project catalog.

**Completion range edit** is a revisioned one-shot request to replace one display-offset range in the native composer while preserving all text and markers outside that range.

**File acceptance** replaces the active token with a complete file reference and terminates it for continued prose.

**Directory continuation** replaces the active token with a complete directory reference ending in `/`, leaves the cursor in the path, and allows a new query to begin immediately.

**Dismissal** records the user's decision to hide project-file autocomplete for the lifetime of the current trigger token. Edits and cursor movement within that token do not revoke it; ending the token does. Dismissal does not delete or replace composer text.

**Quiet exact file** is a current unquoted query whose complete token exactly equals a returned file path. Its picker is hidden because the ordinary text already names one file.

**Quiet unmatched query** is a current query with no matches. Its picker is hidden only while the next query is an append-only refinement in both raw token text and canonical matcher text. Backspacing always searches again, even when removing `/` leaves the canonical matcher unchanged, because raw slash state affects exact-directory inclusion. Rewriting or crossing a normalization boundary also searches again.

**Incomplete search** is a successful search whose configured scan, byte, directory, depth, or duration bound stopped enumeration before the source was exhausted. It is not an unbounded best-effort result.

# 3. Product behavior

## Activation

Autocomplete is eligible only when:

1. `PromptWorkflow.type === "idle"`;
2. the input is not a secret authentication prompt;
3. the cursor lies within a syntactically valid `@` token;
4. the decoded query is project-relative and within its byte bound;
5. no command-name picker currently owns the same cursor context.

It remains available while the agent is streaming because ordinary prompt input can become steering or follow-up input. Search is read-only and does not interact with provider activity.

The empty token `@` is valid and returns shallow project entries. Debounce and initial search do not open a loading frame; the picker becomes visible only after a current query returns useful rows. Typing continues to replace the active request rather than stacking work.

## Token boundary

An `@` starts a candidate token when it is at the start of the draft or its preceding Unicode character is not a letter, number, or underscore. This rejects `user@example.com` and `name_@value` while allowing prose punctuation such as `(@src/file.ts)`.

For an unquoted token, whitespace, comma, or semicolon ends the full token. Newline is whitespace. The parser finds the rightmost eligible `@` at or before the cursor, rejects any delimiter between that trigger and the cursor, and requires the cursor to remain within the token. Delimiter text is never admitted as an unquoted search query.

For a quoted token beginning `@"`, spaces, commas, and semicolons are ordinary path characters until the closing quote. Completion remains active only while the cursor is before the closing quote. A manually typed closing quote therefore dismisses completion unless a directory completion deliberately places the cursor before it.

The query is text between the trigger or opening quote and the cursor. The replacement range covers the complete token, including text after the cursor and a closing quote. This prevents stale suffix concatenation when the cursor moves into the middle of a token.

## Search scope

Search is rooted at the exact current session `OpenZiPaths.cwd`.

Admitted queries:

- empty query;
- ordinary relative names;
- nested relative paths such as `src/com`;
- fuzzy segment queries such as `tui/src/auto`;
- an optional leading `./`, normalized away for matching and completion;
- spaces and punctuation when quoted.

Rejected queries:

- absolute POSIX paths;
- Windows drive-qualified or UNC paths;
- `~` and `~/`;
- any `..` path segment;
- NUL, escape, newline, or other control characters;
- query text over `maxProjectFileSearchQueryBytes`.

A rejected query closes the file picker and starts no filesystem work. Users may still type arbitrary text manually; this restriction applies only to enumeration.

## Suggestions

A project file match has this client-neutral shape:

```ts
export interface ProjectFileMatch {
  /** Slash-normalized path relative to OpenZiPaths.cwd, without @ or quotes. */
  readonly path: string
  readonly type: "file" | "directory"
}

export interface ProjectFileSearchResult {
  readonly matches: readonly ProjectFileMatch[]
  readonly truncated: boolean
}
```

`path` never starts with `/`, contains `.` or `..` traversal segments, or ends in `/`. The kind carries directory identity. Output paths use `/` on every platform.

File names containing terminal control or bidirectional-format characters are omitted. Paths containing a literal double quote are also omitted in the first slice because quoted directory continuation would otherwise require an escaping grammar not owned by submission. Literal backslashes in source paths are omitted rather than rewritten: Git and the walker already produce `/` separators, while POSIX backslashes are filename data and cannot be represented without ambiguity. Ordinary Unicode and spaces remain valid.

## Acceptance

Enter and Tab both accept the selected file row. A picker consumes those keys; it never submits the prompt on the same keypress.

For a file:

- replace the complete active token with `@path` or `@"path with spaces"`;
- if the token is at end of input, append one space and place the cursor after it;
- if one horizontal space or tab already follows the token, do not duplicate it and place the cursor after that separator;
- if newline, comma, or semicolon follows, preserve it and place the cursor immediately after the reference;
- dismiss autocomplete for the completed file token.

For a directory:

- replace the complete active token with `@path/`;
- quote it when the original token was quoted or the path contains a token delimiter;
- for an unquoted result, place the cursor after `/`;
- for a quoted result, emit `@"path/"` and place the cursor immediately before the closing quote;
- do not append a prose separator;
- keep the current rows visible but non-actionable until the resulting child query installs its scored rows.

When the raw query ends in `/`, the exact directory named by its canonical matcher query is excluded from results. Repeated separators and leading `./` segments do not bypass that exclusion: `empty/`, `empty//`, and `././empty/` all omit the `empty` directory itself. Directory continuation must make progress into descendants rather than repeatedly offering a no-op selection.

## Picker visibility, cancellation, and no matches

A valid file-completion context and a visible picker are separate facts. Initial debounce/search remains invisible. Once rows are visible, changed queries retain those scored rows until the current result replaces them atomically; the controller marks retained rows disabled, removes their selection accent, prevents navigation, and rejects activation. Selection follows the same row ID when it survives rescoring and otherwise resets to the first current row.

Escape closes a file frame and leaves the exact draft, cursor, markers, and selection unchanged. The same trigger stays dismissed while the cursor and edits remain within that token. Ending the token with whitespace, comma, semicolon, deletion, or a changed draft outside the context releases dismissal; a later trigger can open normally.

A successful empty result closes the frame. Refinements that append to both the raw query and its canonical matcher query start no redundant search. Backspacing—including `empty/` to `empty`—rewriting, or canonicalization that removes/reinterprets matcher text admits search again. A current exact unquoted file path at the end of its token also closes the frame without editing the draft. Exact directories remain visible for drill-down, while quoted references close naturally when their closing quote ends the context. The typed `@query` always remains ordinary text.

Filesystem failures are silent optional-completion failures unless they violate an OpenZi invariant. They close the frame without modifying the draft. Cancellation and stale completion never produce prompt feedback.

# 4. Owners and data flow

## Owner table

| Concern                                                                                  | Owner                                           |
| ---------------------------------------------------------------------------------------- | ----------------------------------------------- |
| Immutable effective cwd and project root                                                 | `OpenZiPaths`                                   |
| Bounded filesystem enumeration, Git subprocess, fallback walk, ranking, and cancellation | `ProjectFileSearch`                             |
| Client-independent search boundary and session disposal                                  | `AgentSession`                                  |
| `@` token parsing, debounce, request identity, dismissal, and selection interpretation   | `FileCompletionController`                      |
| Built-in/resource command syntax and command candidates                                  | Existing `SlashController`                      |
| Modal prompt workflows and autocomplete arbitration                                      | `PromptStore`                                   |
| Active picker frames, selection, and visible filtering mechanics                         | Existing `PickerStack`                          |
| File-row presentation values                                                             | `prompt/frames.ts`                              |
| Native text, cursor, selection, viewport, undo/redo, and extmarks                        | OpenTUI `TextareaRenderable`                    |
| Atomic range replacement and marker preservation                                         | `Composer` plus version-pinned adapter          |
| Available-height calculation and renderable updates                                      | Existing `PickerStackView` / `PickerList`       |
| Current session identity and replacement generation                                      | Existing `InteractiveStore` / `InteractiveMode` |

The data flow is:

```text
OpenTUI content/cursor event
  -> PromptStore
  -> SlashController or FileCompletionController
  -> AgentSession.searchProjectFiles()
  -> ProjectFileSearch(OpenZiPaths.cwd)
  -> bounded ProjectFileSearchResult
  -> file PickerFrame
  -> PickerStack
  -> PickerStackView / PickerList

selected row
  -> FileCompletionController validates current context
  -> PromptStore publishes one range InputEdit
  -> PromptView
  -> Composer.replaceRange()
  -> OpenTUI native edit buffer
```

No coding-agent module imports OpenTUI, Nano Stores, or picker types. No component parses `@` syntax or calls filesystem operations. No store copies the complete draft or project tree.

## Coding-agent construction

`createAgentSession()` constructs one `ProjectFileSearch` from `services.paths` and passes it into `AgentSession`. `AgentSession` owns its active operation lifetime:

```ts
searchProjectFiles(query: string, signal: AbortSignal): Promise<ProjectFileSearchResult>
```

The exact name may change, but the boundary remains query plus cancellation. Do not expose cwd, a backend selector, raw Git output, a directory iterator, or a generic filesystem-search option bag to the TUI.

`AgentSession.dispose()` aborts file search and includes its bounded settlement in session settlement. `waitForIdle()` includes an admitted file search so no process or directory handle outlives the session that created it. Search does not make the session non-replaceable; replacement disposal cancels it.

Print and future RPC clients pay no scan or subprocess cost unless they call the operation.

## TUI placement

Add one concrete controller under:

```text
packages/tui/src/interactive/prompt/file-completion.ts
```

`PromptStore` creates and disposes it beside `PickerStack`. The controller receives narrow access to the current `AgentSession` and picker operations. It does not become a provider registry or own command completion.

`PromptState.workflow` does not gain file-search variants. Project-file autocomplete is an editor interaction with an independent bounded asynchronous lifetime, not a model/authentication/settings workflow.

The controller's private state is not added to the public Nano Store. Picker transitions already notify the view through `PickerStack.$state`; accepted edits use the existing revisioned `PromptState.inputEdit` synchronization path.

# 5. Coding-agent `ProjectFileSearch`

## Direct operation state

`ProjectFileSearch` owns one operation at a time:

```ts
type ProjectFileSearchBackend = "unknown" | "git" | "walk"

type ProjectFileSearchState =
  | { readonly type: "idle"; readonly backend: ProjectFileSearchBackend }
  | {
      readonly type: "searching"
      readonly backend: ProjectFileSearchBackend
      readonly operationId: number
      readonly controller: AbortController
      readonly settled: Promise<void>
    }
  | { readonly type: "disposed"; readonly settled: Promise<void> }
```

A concurrent call while `searching` is rejected. `FileCompletionController` serializes cancellation and the latest pending query before calling again. This keeps the authoritative process boundary single-flight even if another client misuses it. Every retained `settled` promise is normalized to fulfillment after recording its operation outcome, so cancellation and failure cannot create an unhandled rejection in controller switching or disposal.

Allowed transitions:

| Current     | Request/outcome | Next        | Effect                                    |
| ----------- | --------------- | ----------- | ----------------------------------------- |
| `idle`      | valid search    | `searching` | start Git or walk operation               |
| `idle`      | invalid query   | `idle`      | reject before I/O                         |
| `searching` | success         | `idle`      | return frozen bounded result              |
| `searching` | failure         | `idle`      | reject normalized failure                 |
| `searching` | caller abort    | `idle`      | stop process/walk and reject cancellation |
| `idle`      | dispose         | `disposed`  | resolved settlement                       |
| `searching` | dispose         | `disposed`  | abort and retain bounded settlement       |
| `disposed`  | any search      | `disposed`  | reject disposed owner                     |

The backend is resolved lazily. A successful Git search changes `unknown` to `git`. Git unavailable or not-a-worktree changes it to `walk`. A later Git backend failure may degrade to `walk` for that session. Backend choice is operational state, not persisted configuration.

## Git backend

For a Git worktree, spawn directly without a shell:

```text
git ls-files --cached --others --exclude-standard -z
```

The child cwd is exactly `OpenZiPaths.cwd`. Git therefore returns paths relative to the effective cwd, including when cwd is a repository subdirectory.

The backend:

1. streams stdout instead of buffering it;
2. splits NUL-delimited path bytes incrementally;
3. decodes each token as strict UTF-8;
4. rejects invalid or oversized paths before ranking;
5. hard-excludes every `.git` path segment;
6. admits each file and derives its ancestor-directory candidates;
7. ranks online and retains only the best result bound;
8. stops at entry, output-byte, duration, or cancellation bounds;
9. ignores stderr except for bounded internal failure classification;
10. kills and settles the child on abort or truncation.

Git's standard ignore policy defines ignored files in this backend. Tracked paths remain visible because they are project files even if a later ignore rule names them. Submodule/gitlink entries may be treated as files in the first slice; OpenZi does not recursively enter submodules for autocomplete.

`ENOENT`, not-a-worktree exit, or an unavailable Git executable falls back to the bounded walker. Arbitrary Git stdout, stderr, paths, and exit values are process-boundary input and must be validated.

## Fallback walk

The non-Git fallback performs a breadth-first asynchronous walk rooted at `OpenZiPaths.cwd`.

It:

- reads one directory at a time through bounded `opendir` iteration;
- sorts the admitted per-directory entries before enqueueing children;
- applies each root or nested `.gitignore` through a directory-scoped inherited `ignore` matcher, preserving Git-relative wildcard, negation, and escaping semantics;
- includes hidden non-ignored files and directories;
- hard-excludes `.git` regardless of ignore negation;
- does not follow directory symlinks;
- may classify a bounded number of symlinks with `stat` for row presentation but never enqueues their targets;
- yields between bounded batches so caller cancellation and renderer input can progress;
- ranks entries online and retains no complete path list;
- marks the result truncated when any traversal bound is reached.

Breadth-first traversal makes empty-query and incomplete-search results prefer shallow project entries. Per-directory and queued-directory bounds prevent one pathological directory or wide tree from becoming an unbounded retained collection.

The fallback does not read global Git configuration or invent default ignores such as `node_modules`. Project ignore files remain authoritative. If an ignore file cannot be admitted within the aggregate byte bound or cannot be opened for a reason other than absence, the search marks the result truncated and conservatively skips that directory subtree rather than enumerating paths without its rules. Only `ENOENT` and `ENOTDIR` mean that the scope has no ignore file.

## Explicit bounds

Add exported production constants:

```ts
export const maxProjectFileSearchResults = 20
export const maxProjectFileSearchQueryBytes = 4 * 1024
export const maxProjectFileSearchPathBytes = 16 * 1024
export const maxProjectFileSearchEntries = 100_000
export const maxProjectFileSearchOutputBytes = 16 * 1024 * 1024
export const maxProjectFileSearchDirectories = 16_384
export const maxProjectFileSearchQueuedPathBytes = 4 * 1024 * 1024
export const maxProjectFileSearchDirectoryEntries = 4_096
export const maxProjectFileSearchDepth = 64
export const maxProjectFileSearchIgnoreBytes = 4 * 1024 * 1024
export const maxProjectFileSearchSymlinkStats = 64
export const maxProjectFileSearchDurationMs = 2_000
export const maxProjectFileSearchSettlementMs = 250
```

The implementation may refine a constant name but may not remove the represented bound.

`maxProjectFileSearchEntries` counts source path records before fuzzy filtering. Git output bytes include delimiters. Directory queue bytes count UTF-8 path bytes. Ignore bytes are aggregate bytes read by one fallback search. A deadline that fires returns an incomplete result only after the process/directory owner has initiated cancellation; it must not leave work detached.

Tests must characterize admission counts, kill/close calls, retained result count, and stale completion. CI tests must not use wall-clock performance thresholds.

## Ranking

Normalize query and candidate paths to `/` and lowercase only for comparison, stripping repeated leading `./` segments and matcher-only trailing slashes. The normalizer is idempotent and produces the same matcher text whether called on raw client input or the already validated query admitted by `ProjectFileSearch`. Preserve the original validated path for display and insertion. Coding-agent exposes this exact normalization so the TUI can require both raw and matcher append direction without duplicating ranking policy.

Ranking precedence is:

1. exact full-path match;
2. exact basename match;
3. basename prefix match;
4. ordered path-segment prefix match;
5. basename fuzzy subsequence match;
6. full-path fuzzy subsequence match.

Within one class, prefer:

1. lower fuzzy gap score;
2. earlier match start;
3. shallower path depth;
4. directories before files;
5. shorter path;
6. code-point lexical path order.

A query containing `/` is split into non-empty segments. Candidate segments must satisfy query segments in order, so `tui/src/auto` matches `packages/tui/src/autocomplete.ts` but not `packages/ai/src/autocomplete.ts`.

For an empty query, rank by depth, directory before file, path length, then lexical path. Duplicate directory candidates derived from multiple files must not grow an unbounded deduplication set; the bounded rank accumulator owns deduplication only for retained candidates.

Search returns a frozen array in final rank order. The TUI does not re-fuzzy or re-sort file rows.

# 6. Display-offset parsing

## One offset implementation

OpenTUI offsets count terminal display cells and count newline as one position. JavaScript indexes count UTF-16 code units. File completion must not compare or splice `cursorOffset` with `text.length`.

Move the existing Composer-local prompt offset helpers into the concrete domain-free `packages/tui/src/components/cell-text.ts` module, with names equivalent to:

```ts
promptTextWidth(text: string): number
promptTextSlice(text: string, start?: number, end?: number): string
promptTextIndex(text: string, offset: number): number
```

The exact names may differ. Composer history, marker expansion, file-context parsing, and range replacement must share this implementation. Tabs retain OpenTUI 0.4.5's two-cell indicator behavior; newline counts as one.

This follows OpenCode's pinned [`prompt/display.ts`](https://github.com/anomalyco/opencode/blob/cb8be9ba1/packages/tui/src/prompt/display.ts) adaptation around OpenTUI display offsets while keeping the primitive framework-neutral and local to OpenZi's imperative components.

## Parsed context

The pure parser returns:

```ts
export interface FileCompletionContext {
  readonly triggerStart: number
  readonly tokenEnd: number
  readonly cursorOffset: number
  readonly query: string
  readonly quoted: boolean
}
```

All offsets are display-width offsets into the complete textarea. `query` is decoded path text without `@` or surrounding quotes. The parser retains no draft.

The editor-event hot path does not rebuild a display-offset map for the complete draft. `PromptView` asks the native edit buffer for bounded before/after-cursor ranges on the current logical line plus an explicit following-newline fact, capped by `maxProjectFileSearchQueryBytes` plus syntax cells. The pure parser consumes that snapshot, computes absolute offsets relative to the native cursor, and conservatively rejects a token whose boundary falls outside the admitted window. The shared cell-text helpers remain authoritative for the bounded token and replacement ranges.

The parser validates:

- native cursor and bounded-window identity;
- eligible trigger predecessor;
- complete token end;
- cursor within token;
- quoted/open-quote state;
- project-relative query grammar;
- query byte bound.

A selection operation reparses the current native text and cursor and requires exact equality with the context that produced the visible result. Row identity alone is insufficient.

# 7. `FileCompletionController` states and transitions

## Private state union

The controller owns debounce, one active request, one latest pending request, and one bounded result:

```ts
interface PendingFileCompletion {
  readonly operationId: number
  readonly session: AgentSession
  readonly draftRevision: number
  readonly context: FileCompletionContext
}

type FileCompletionState =
  | { readonly type: "closed" }
  | { readonly type: "waiting"; readonly pending: PendingFileCompletion; readonly timer: ReturnType<typeof setTimeout> }
  | {
      readonly type: "searching"
      readonly active: PendingFileCompletion
      readonly controller: AbortController
      readonly settled: Promise<void>
    }
  | {
      readonly type: "switching"
      readonly pending: PendingFileCompletion
      readonly timer: ReturnType<typeof setTimeout>
      readonly previousSettled: Promise<void>
    }
  | { readonly type: "showing"; readonly request: PendingFileCompletion; readonly result: ProjectFileSearchResult }
  | { readonly type: "continuing"; readonly request: PendingFileCompletion }
  | {
      readonly type: "dismissed"
      readonly session: AgentSession
      readonly draftRevision: number
      readonly triggerStart: number
    }
  | {
      readonly type: "accepted"
      readonly session: AgentSession
      readonly draftRevision: number
      readonly triggerStart: number
    }
  | { readonly type: "exact"; readonly request: PendingFileCompletion }
  | { readonly type: "unmatched"; readonly request: PendingFileCompletion }
  | { readonly type: "disposed" }
```

`fileCompletionDebounceMs` is 20, following Pi. The timer belongs to the controller, is not a render scheduler, and is cleared on every transition that no longer needs it.

The state retains only one parsed query and at most 20 matches. `exact` and `unmatched` are quiet context states, `dismissed` is token-scoped user suppression, `accepted` rejects the native cursor/content notifications caused by one file range edit, and `continuing` keeps disabled parent rows visible until a directory range edit starts its child query. It never retains full draft text, all scanned paths, a queue of every typed query, or a second selected index. Selection remains `PickerStack` state.

## Transition table

| Current                | Input/outcome                                | Next               | Side effect                                                             |
| ---------------------- | -------------------------------------------- | ------------------ | ----------------------------------------------------------------------- |
| `closed`               | valid context                                | `waiting`          | arm 20 ms debounce; keep picker closed                                  |
| `waiting`              | same context                                 | unchanged          | none                                                                    |
| `waiting`              | newer valid context                          | `waiting` latest   | replace timer and pending request                                       |
| `waiting`              | timer fires                                  | `searching`        | call current session search                                             |
| `waiting`              | context closes/workflow changes              | `closed`           | clear timer                                                             |
| `searching`            | same context                                 | unchanged          | none                                                                    |
| `searching`            | newer valid context                          | `switching`        | abort active; debounce latest; retain any visible rows                  |
| `switching`            | newer valid context                          | `switching` latest | replace timer; retain one previous settlement                           |
| `switching`            | timer and previous settle                    | `searching`        | start latest search                                                     |
| `searching`            | useful current success                       | `showing`          | atomically install rows; preserve selected row ID when present          |
| `searching`            | exact unquoted file at token end             | `exact`            | close file frame without editing text                                   |
| `searching`            | empty current success                        | `unmatched`        | close file frame                                                        |
| `searching`            | current failure                              | `closed`           | close file frame                                                        |
| `showing`              | same context                                 | unchanged          | preserve selection                                                      |
| `showing`              | changed valid context                        | `waiting`          | visibly disable retained rows; debounce new query                       |
| `showing`              | accepted file                                | `accepted`         | close frame; emit range edit; suppress its cursor/content notifications |
| `showing`              | accepted directory                           | `continuing`       | disable retained rows; emit range edit; resulting content starts query  |
| `continuing`           | resulting directory context                  | `waiting`          | retain disabled rows; debounce child query                              |
| any visible file state | Escape                                       | `dismissed`        | clear timer or abort search; close frame; preserve input                |
| `dismissed`            | same trigger token                           | `dismissed` latest | remain closed across edits and cursor movement                          |
| `dismissed`            | token ends or a different trigger activates  | `closed`/`waiting` | release suppression or admit the different context                      |
| `exact`                | same exact query                             | `exact` latest     | remain closed                                                           |
| `exact`                | changed query                                | `waiting`          | debounce changed context                                                |
| `unmatched`            | raw and canonical append-only refinement     | `unmatched` latest | remain closed; start no redundant search                                |
| `unmatched`            | backspaced, rewritten, or renormalized query | `waiting`          | debounce changed context                                                |
| any live state         | session replacement/dispose                  | `disposed`         | clear timer, abort request, close owned frame                           |

Every async completion validates:

1. controller is not disposed;
2. operation ID matches;
3. admitted `AgentSession` is still the current session;
4. state still names the same request;
5. current parsed context still equals the request context;
6. the file frame has not been superseded by another picker workflow.

A stale success or failure releases only its own resources. It cannot close, replace, or report against the current picker.

## Content and cursor notifications

`ComposerOptions` gains an `onCursorChange` callback beside `onContentChange`.

`PromptStore` keeps a private monotonically increasing draft revision:

- content changes increment the revision and update slash/file completion;
- cursor-only changes do not increment it and update file completion only;
- image-marker synchronization remains separate;
- no draft text or cursor enters `PromptState` as authoritative state.

Cursor notifications are required because moving into, within, or out of an `@` token changes the active query without changing text. Command completion remains on its existing content-driven path in this slice; adding cursor refresh must not make a dismissed `/` picker reopen on every horizontal movement.

Duplicate content/cursor notifications for the same parsed context are no-ops and start no additional search. File acceptance dismisses both the pre-edit cursor notification and the resulting content revision for that trigger, preventing exact-path completion from reopening before a preserved comma or semicolon. Directory acceptance remains closed so its resulting content immediately starts the child query.

# 8. Picker integration

## Frame

Add `promptPickerFrameIds.files` and a pure `fileFrame()` builder in `packages/tui/src/interactive/prompt/frames.ts`.

The frame uses:

```ts
{
  id: promptPickerFrameIds.files,
  title: "",
  filter: "none",
  height: 7,
  rows: /* ranked project matches */
}
```

`height` is the preferred total frame height, not a guaranteed result-row count. `PickerStackView` gives rows remaining after optional title, hint, and footer chrome to the list. A normal file frame therefore shows up to seven results, while a truncation footer leaves six result rows inside the same seven-row outer geometry. Debounce, initial loading, exact, and unmatched states own no frame.

Rows use the same existing `PickerList` grammar as slash commands:

- `id`: stable controller-generated candidate ID;
- `label`: `@path` with `/` appended for a directory;
- `detail`: `[directory]` for directories only;
- no custom selected background, icon, border, or popup;
- `searchText`: the relative path, although `filter: "none"` prevents a second fuzzy pass.

A truncated result adds the muted footer:

```text
Search limited; refine @query
```

The frame contains at most 20 rows. The file list displays at most seven at once—or six beside the truncation footer—and centers its moving selection inside that stable outer frame; `PickerList` keeps its generic ten-row hard bound and existing glyphs, composer surface, and clipping behavior. Rescoring retains the current frame with `disabled: true` until replacement rows are ready, dims every retained row, and carries the selected row ID forward when that candidate survives.

The entire relative path remains visible as the primary value rather than Pi's basename-plus-description split. This matches OpenZi's existing `/command` row contract and makes the inserted value unambiguous.

## Arbitration with slash and workflow pickers

While `PromptWorkflow` is non-idle, file completion is closed and the active domain picker continues receiving the composer text as its filter.

While idle:

1. command-name completion is evaluated first;
2. if the cursor is in an admitted command-name context with suggestions, the command frame owns the picker and file work is canceled;
3. otherwise file completion may own a valid `@` context, including an `@` inside slash-command arguments;
4. leaving either context closes only that autocomplete owner's frame;
5. neither owner closes a modal frame it did not create.

`PickerStack` remains mechanical. It does not learn command/file precedence or parse candidate IDs.

## Selection dispatch

`PromptStore.activatePicker()` in idle state dispatches by active frame ID:

- command frame: existing `SlashController.activate()` behavior;
- file frame: `FileCompletionController.complete()`;
- any other frame in idle: impossible and exhaustively rejected.

`PromptStore.completePicker()` similarly dispatches:

- command frame: existing Tab completion;
- file frame: the same file completion used by Enter.

`backPicker()` gains a file-frame branch parallel to the existing command-frame branch. It calls controller dismissal and closes the picker without `#requestInput("")`. Dismissal remains attached to that token across edits until the context ends. The generic nested-picker back path must never clear an ordinary `@` draft.

## Key precedence

No new semantic action IDs are required. The existing picker actions remain authoritative:

- `picker_up` / `picker_down`;
- `picker_confirm` for Enter;
- `picker_complete` for Tab;
- `picker_cancel` for Escape or the effective picker-back binding.

While a file frame is visible, picker navigation wins over composer history and native vertical movement. Enter and Tab cannot submit or insert native whitespace. Escape cannot cancel a provider run on the same keypress. Modified keys not claimed by picker actions continue through existing OpenTUI behavior.

Composer focus never leaves the native textarea.

# 9. Revisioned range edits and native replacement

## Input edit union

Replace the current single-shape `PromptState.inputEdit` value with an explicit union:

```ts
export type PromptInputEdit =
  | { readonly type: "replace"; readonly revision: number; readonly text: string; readonly cursorOffset: number }
  | {
      readonly type: "range"
      readonly revision: number
      readonly startOffset: number
      readonly endOffset: number
      readonly replacement: string
      readonly cursorOffset: number
    }
```

Existing clear, restore, slash completion, queue, authentication, and selector transitions continue to issue `replace` edits. File acceptance issues `range` so text and native marker state outside the token are not copied through `PromptStore`.

`PromptView` tracks the applied revision and switches exhaustively on edit type. It applies exactly one edit, synchronizes active image identities as today, and refocuses the same textarea.

The range edit is a resource-synchronization request, not a mirrored draft. `PromptState` never receives the complete resulting text for file completion.

## Composer API

Add a concrete method equivalent to:

```ts
replaceRange(edit: {
  readonly startOffset: number
  readonly endOffset: number
  readonly replacement: string
  readonly cursorOffset: number
}): "applied" | "unavailable"
```

The Composer validates:

- offsets are ordered and within current display width;
- start, end, and cursor map to valid display boundaries;
- the range intersects no compact-paste or image extmark;
- the resulting text remains within OpenTUI's admitted composer bound;
- the target has not been destroyed.

An unavailable replacement leaves text, cursor, selection, extmarks, undo, and redo unchanged. PromptView may report one bounded warning for marker intersection; it must not fall back to whole-draft `setText()`.

## Version-pinned owned replacement adapter

Add:

```text
packages/tui/src/components/composer-range-replacement.ts
```

The adapter exists because OpenTUI 0.4.5 has no public one-undo range replacement that preserves extmarks and avoids `replaceText()` registry growth.

For one admitted replacement it:

1. captures the bounded Composer extmarks;
2. rejects any extmark intersecting the replacement range;
3. derives the complete next plain text with shared display-offset slicing;
4. derives shifted ranges for markers after the replacement;
5. verifies the installed extmark controller exposes the pinned snapshot primitive used by wrapped replacements;
6. saves exactly one extmark undo snapshot;
7. clears native selection;
8. calls public `input.editBuffer.replaceTextOwned(nextText)` for one native undo point without a JavaScript memory slot;
9. clears and recreates only the Composer-owned marker set at adjusted offsets, preserving payload object identity and order;
10. places the cursor at the admitted target;
11. releases completed history-browse replacement resources because native replacement clears redo;
12. emits one coherent Composer content report.

All compatibility checks and marker reconstruction values are prepared before native mutation. The adapter must fail fast with a version-specific incompatibility error if the pinned OpenTUI internals differ. It must not silently use unwrapped `replaceTextOwned()` and leave extmark history misaligned.

Undo after completion restores the exact pre-completion text, cursor, paste markers, image markers, and prior edit history. Redo restores the completed text and shifted markers. Repeated accepted completions must work beyond OpenTUI's 255 default replacement-slot limit.

Only Composer-owned extmarks are supported in this textarea. If another feature later adds another extmark type, the adapter must be extended by the Composer owner or reject the operation; it may not drop unknown native state.

This is a temporary version adapter, not a general editor transaction framework. Remove it when OpenTUI provides an atomic public `replaceRange()` or undo-group API with equivalent extmark and owned-memory behavior.

# 10. Completion encoding

## Candidate IDs

`FileCompletionController` derives stable frame-local IDs from kind plus exact relative path. IDs are opaque outside the controller. Selection resolves an ID only against the current bounded result; it is never parsed into an arbitrary filesystem path without that membership check.

A row from a stale result or another frame cannot produce an edit.

## Reference formatting

Use one pure formatter owned beside the parser:

```ts
formatFileReference(
  match: ProjectFileMatch,
  context: FileCompletionContext,
  followingText: string
): {
  readonly replacement: string
  readonly cursorWithinReplacementOrSuffix: number
}
```

The exact signature may differ, but formatting remains independent of picker rendering and filesystem search.

Quote when:

- the active context was already quoted; or
- the completed path contains whitespace, comma, or semicolon.

Files produce:

```text
@src/index.ts
@"my folder/index.ts"
```

Directories produce:

```text
@src/
@"my folder/"
```

The controller computes the final absolute display-offset cursor target from `triggerStart`, formatted display width, and an existing horizontal separator if reused. It never uses JavaScript `replacement.length` as an OpenTUI cursor offset.

Completion preserves all draft text before and after the parsed full token. A closing quote immediately after the cursor is part of the token and is replaced once, not duplicated.

# 11. Lifecycle, replacement, and interruption

## Session replacement

A `SessionScreen` owns one `PromptStore`, one `FileCompletionController`, and one captured current `AgentSession`. `InteractiveStore` generation replacement destroys the old screen before constructing the new one.

Destroying the old controller:

1. clears its debounce timer;
2. aborts active search;
3. prevents pending switching work from starting;
4. closes only its file frame;
5. rejects stale success/failure;
6. releases all bounded result references.

The disposed old `AgentSession` independently cancels its authoritative `ProjectFileSearch`. A completion from the old cwd cannot appear in the replacement session.

The new screen's first query uses the replacement runtime's `OpenZiPaths.cwd`, including a cwd restored from a resumed session header. No owner calls `process.cwd()` or joins `.openzi` while searching.

## Submission and clearing

Submitting, clearing, restoring queued input, entering authentication input, or opening a non-idle picker closes file completion and cancels search before the corresponding composer edit is requested.

Accepted `@path` text reaches `InteractiveStore.submit()` and `AgentSession` unchanged except for existing outer `trim()`. It does not enter `PromptState.images`, resource expansion, system prompt, or a separate durable field.

Session prompt history later recalls the exact durable user text containing `@path`, subject to its existing text-only bounds. No file search reruns merely because history replacement restores an `@` token; the ordinary content callback may open completion only if the restored cursor lies in a valid active context, matching normal editor behavior.

## Terminal shutdown

`PromptView.destroy()` disposes the controller before destroying the Composer and picker subtree. `AgentSession.dispose()` cancels the authoritative search. `runTui` continues to restore the terminal before awaiting bounded session settlement, as required by [ADR 0009](adr/0009-interruption-and-terminal-shutdown.md).

No autocomplete process, directory handle, timer, callback, or result survives final session disposal.

# 12. Performance and resource rules

Project-file autocomplete is an input hot path. The following structural properties are required:

- no startup or inactive-screen scan;
- no complete project catalog retained by TUI or coding-agent;
- at most one coding-agent search operation;
- at most one TUI debounce timer;
- at most one active and one latest pending TUI request;
- at most 20 retained matches;
- at most seven visible file row renderables, or six with footer chrome, within `PickerList`'s generic ten-row bound;
- stable file-frame and list-root identity while visible results are rescored;
- stable visible row identity for navigation within one result frame;
- old scored rows remain visible but cannot activate while a newer query is pending;
- no loading or empty frame;
- raw-and-canonical append-only refinements of a current unmatched query start no redundant traversal;
- no per-frame polling, animation tick, independent FPS scheduler, or anchor-position interval;
- no full draft copy in controller or store state;
- no filesystem work in `PickerStackView`, `PickerList`, or `Composer`;
- no unbounded stdout, stderr, path, directory, ignore, symlink, or settlement collection.

The 20 ms debounce is input admission, not presentation scheduling. Search result application uses the ordinary picker atom notification and renderer request path. It does not add `requestAnimationFrame` merely to delay I/O.

Instrumentation is not required for the first slice. If real projects show unacceptable latency after the bounded Git/walk implementation, measure query duration, entries scanned, cancellation rate, and truncation before considering a retained index or bundled native searcher.

# 13. Security and failure policy

Filesystem names and process output are external input.

Validate before presentation or insertion:

- strict UTF-8;
- relative containment beneath cwd;
- slash-normalized traversal-free path;
- path and query byte limits;
- no control, escape, newline, bidi-format, or literal quote characters;
- admitted `file | directory` kind only;
- result membership at selection time.

The fallback walk never follows a directory symlink. A file symlink may appear as a file row, and a symlink classified as a directory may display as a directory row, but selecting it does not authorize or start traversal through its target.

Autocomplete performs no file-content read, so selecting a path has no provider-cost, secret-exfiltration, or large-file effect beyond inserting visible text. Existing tools remain the explicit mechanism for reading files.

Git is executed without a shell, inherited stdin, or user-controlled arguments. Query text is never passed as a Git pathspec or command argument; it affects only in-process ranking. Stderr is bounded and never written directly into the terminal.

A malformed path is omitted. A source limit marks the result truncated. A missing/inaccessible path produces no candidates. A violated internal invariant or incompatible OpenTUI adapter is an error rather than silent editor corruption.

# 14. Testing

## Coding-agent behavior

Add `packages/coding-agent/test/project-file-search.test.ts` covering:

1. exact cwd rooting from `OpenZiPaths` rather than process cwd;
2. Git tracked and untracked files;
3. standard Git ignores and hard `.git` exclusion;
4. non-Git fallback with root and nested `.gitignore` files;
5. hidden non-ignored paths;
6. root and derived directory candidates plus canonical exact-directory exclusion for repeated slashes and `./` prefixes;
7. deep nested fuzzy queries and ordered segment matching;
8. exact, basename-prefix, fuzzy, depth, directory, and lexical ranking;
9. deterministic empty-query results;
10. invalid UTF-8/control/traversal/absolute/oversized path omission;
11. query validation before I/O;
12. entry, output-byte, path-byte, directory, depth, queue-byte, ignore-byte, symlink, duration, and result bounds;
13. truncated result signaling;
14. abort during Git output and fallback traversal;
15. Git failure fallback;
16. concurrent-call refusal;
17. dispose during search and bounded settlement;
18. no retained full catalog after completion.

Tests assert structural counts and owner cleanup. They do not benchmark wall-clock speed.

## Pure TUI behavior

Add `packages/tui/test/file-completion.test.ts` covering:

1. start-of-draft and punctuation boundaries, including delimiters before the cursor;
2. email and underscore rejection;
3. multiple `@` tokens and rightmost-context selection;
4. multiline token termination;
5. cursor in the middle of a token with full-token replacement;
6. empty, nested, quoted, and directory queries;
7. absolute, parent, home, drive, control, and oversized rejection;
8. Unicode text before the token and Unicode candidate paths;
9. quoted closing-quote deduplication;
10. file separator insertion/reuse around end, space, tab, newline, comma, and semicolon;
11. directory continuation with quoted cursor placement and disabled-row retention;
12. candidate ID membership validation;
13. debounce replacement and one-latest-pending bound;
14. stale success, stale failure, cancellation, and session identity;
15. token-scoped Escape dismissal across edits and cursor movement;
16. exact-file quieting while exact directories remain available;
17. empty-result closure, raw-and-canonical append suppression, slash backspace, and normalization re-search;
18. old-row retention, visible disabled state, attempted stale activation, atomic replacement, and selected-ID preservation;
19. error closure without draft mutation;
20. disposal clearing timers and requests.

Use a small fake `AgentSession` search boundary and real `PickerStack`; do not instantiate OpenTUI for pure controller transitions.

## Composer behavior

Extend `packages/tui/test/composer.test.ts` covering:

1. one range replacement preserves prefix and suffix;
2. exact display-width cursor targeting;
3. one undo restores pre-completion text and cursor;
4. redo restores completion;
5. prior ordinary undo remains available after undoing completion;
6. compact-paste markers before and after the range retain exact payload identity;
7. image markers before and after the range retain exact payload identity and order;
8. marker offsets shift by the replacement delta;
9. overlap with a virtual marker is refused atomically;
10. active native selection clears only on successful replacement;
11. range replacement detaches Composer session-history browsing correctly;
12. repeated accepted replacements beyond 255 do not exhaust OpenTUI's memory registry;
13. adapter incompatibility fails before native mutation;
14. destroy rejects stale edits.

These tests use real `@opentui/core/testing` and native undo/redo.

## Interactive OpenTUI behavior

Add `packages/tui/test/interactive/file-autocomplete.test.ts` covering:

1. typing `@` starts input admission without a loading frame and opens `picker-stack` only when rows arrive;
2. rows use the same glyphs, colors, surface, preferred seven-row outer frame, and focus behavior as `/` completion;
3. nested file and directory display;
4. wrapped Up/Down navigation;
5. Enter file acceptance without prompt submission;
6. Tab file acceptance;
7. directory acceptance retaining its outer frame through the immediate child query;
8. Escape preserving exact text and cursor and remaining dismissed while that token is edited;
9. picker priority over history, submit, newline, clear, and interruption;
10. Left/Right cursor movement closing or changing context;
11. rapid typing retaining old rows, rejecting their activation, and atomically installing current rows;
12. exact-file and no-match closure;
13. truncation footer;
14. completion beside compact paste and image markers;
15. steering/follow-up availability while streaming;
16. workflow suppression during authentication/settings/session pickers;
17. session replacement using the replacement cwd and rejecting old completion;
18. disposal with in-flight search and persistent composer focus.

The integration harness uses real temporary project trees and the real coding-agent search boundary where practical. Process-limit and rare filesystem-error cases remain coding-agent unit tests.

# 15. Implementation plan

## Slice 1: coding-agent project search

Add/change:

- new `packages/coding-agent/src/project-file-search.ts`;
- `packages/coding-agent/src/sdk.ts`;
- `packages/coding-agent/src/agent-session.ts`;
- `packages/coding-agent/src/index.ts`;
- new `packages/coding-agent/test/project-file-search.test.ts`.

Deliver:

1. public match/result values and explicit constants;
2. immutable path-owner construction;
3. direct `idle | searching | disposed` operation state;
4. streaming Git backend;
5. bounded ignore-aware fallback walk;
6. online deterministic ranking;
7. cancellation, fallback, disposal, and settlement;
8. `AgentSession` delegation and lifecycle integration.

No TUI code lands before the coding-agent boundary is behavior-tested.

## Slice 2: display offsets and file controller

Add/change:

- `packages/tui/src/components/cell-text.ts`;
- new `packages/tui/src/interactive/prompt/file-completion.ts`;
- `packages/tui/src/interactive/prompt/frames.ts`;
- `packages/tui/src/interactive/prompt/picker.ts` only if a mechanical invariant requires no API change;
- new `packages/tui/test/file-completion.test.ts`.

Deliver:

1. shared OpenTUI display-offset helpers;
2. pure context parser and reference formatter;
3. direct controller state and transitions;
4. debounce, cancellation, latest-pending collapse, dismissal, and stale checks;
5. bounded file frame projection;
6. pure transition tests.

`PickerStack` should require no domain-specific API.

## Slice 3: atomic Composer range replacement

Add/change:

- new `packages/tui/src/components/composer-range-replacement.ts`;
- `packages/tui/src/components/composer.ts`;
- `packages/tui/test/composer.test.ts`.

Deliver:

1. `Composer.replaceRange()`;
2. version-pinned owned replacement adapter;
3. one-step undo/redo;
4. marker offset and payload preservation;
5. overlap refusal;
6. registry-exhaustion regression coverage;
7. cursor-change callback.

Do not implement file completion with whole-draft `setText()` or two-step delete/insert.

## Slice 4: prompt and picker integration

Add/change:

- `packages/tui/src/interactive/prompt/state.ts`;
- `packages/tui/src/interactive/prompt/store.ts`;
- `packages/tui/src/interactive/prompt/view.ts`;
- new `packages/tui/test/interactive/file-autocomplete.test.ts`;
- affected prompt-store and picker tests.

Deliver:

1. discriminated replace/range input edits;
2. private draft revision and cursor notifications;
3. slash/file autocomplete arbitration;
4. file frame Enter/Tab/Escape dispatch;
5. exact focus, history, workflow, and replacement behavior;
6. session replacement and disposal coverage.

No new keybinding IDs, input renderables, or public root state are introduced.

## Slice 5: documentation and parity evidence

After behavior is green, update:

- [ADR 0005](adr/0005-interactive-mode-owns-frontend-orchestration.md);
- [ADR 0008](adr/0008-composer-owned-picker-stack.md);
- [ADR 0011](adr/0011-openzi-path-policy.md);
- [`docs/tui-architecture.md`](tui-architecture.md);
- [`docs/parity-roadmap.md`](parity-roadmap.md);
- [`CONTEXT.md`](../CONTEXT.md) with canonical project-file-search language if the owner remains public.

Record the intentional deviations from Pi:

- coding-agent owns search rather than TUI;
- exact project scope only;
- Git plus bounded walk rather than managed `fd`;
- no directory-symlink traversal;
- accepted references remain plain text and do not attach file contents.

# 16. Rejected alternatives

## Put `fd` search directly in `PromptStore`

Rejected. It copies Pi's package placement but violates OpenZi's coding-agent/client boundary, hides cwd and process ownership in a frontend store, and makes future non-terminal clients reimplement search policy.

## Add a generic combined autocomplete provider

Rejected. Slash completion is a synchronous descriptor projection; file completion is an asynchronous filesystem operation with cancellation, debounce, external input, and disposal. A common provider abstraction would widen both interfaces before a third concrete completion source exists.

## Put file completion in `PromptWorkflow`

Rejected. File completion can coexist with provider streaming and has no model/authentication mutation. Making it a workflow would conflate editor autocomplete with modal domain operations and complicate every exhaustive workflow transition.

## Add file candidates to `PromptState`

Rejected. `PickerStack` already owns admitted rows and selection. A second public candidate array would mirror transient picker data and expand the Nano Store without another observer.

## Let `PickerStack` fuzzy-filter the whole composer

Rejected. The active filter passed to the stack is the complete native composer text, while file search needs only the parsed `@` query. Coding-agent ranking is authoritative, so the file frame uses `filter: "none"`.

## Retain a complete project index

Rejected. OpenCode and Grok prove indexing can be fast, but their retained catalogs and worker lifetimes do not satisfy OpenZi's current bounds and disposal requirements. Per-query Git/walk search is fresh, cancellable, and sufficient until measured latency proves otherwise.

## Preload files during interactive startup

Rejected. It delays first draw and loads an inactive catalog. Search starts only after a valid `@` context, in line with the TUI performance specification.

## Replace old rows with a loading or empty frame

Rejected. The interaction is a scoring surface, not a progress panel. Replacing rows on each keystroke causes visible result/loading flicker even when total geometry is fixed. OpenZi keeps old scored rows mounted but visibly dimmed and disabled while the controller rejects their activation, atomically installs only a current result, and hides the frame when no useful rows exist.

## Use `deleteRange()` then `insertText()`

Rejected. OpenTUI records two undo points, violating Pi behavior and making one completion require two undos.

## Use Composer `setText()`

Rejected. It clears native undo history and recreates the full draft through a one-shot store value, losing the exact editor-state ownership this project already preserves for paste, images, and history.

## Use default `replaceText()` for every completion

Rejected. It clears extmarks and consumes OpenTUI 0.4.5's unreclaimed JavaScript memory slots. Repeated completion would eventually fail at the native 255-slot registry.

## Create atomic file extmarks

Rejected. Atomic visual references require a durable client-neutral file-part owner, history semantics, deletion/undo synchronization, and provider conversion. Autocomplete alone does not justify that attachment architecture.

## Read files on submission

Rejected. Typing or selecting a path must not silently perform bounded-content admission, leak secrets, inflate context, or alter persisted messages. Explicit tools remain the current file-content boundary.

## Support home, parent, and absolute search

Rejected for the first slice. Pi supports these scopes, but OpenZi's project search should not enumerate outside the admitted cwd. Manual text and explicit tools remain available for outside paths.

# 17. Acceptance checklist

The feature is complete only when:

- [x] `ProjectFileSearch` consumes `OpenZiPaths` and never ambient cwd;
- [x] Git and fallback sources are bounded, cancellable, single-flight, and disposed;
- [x] no complete project catalog is retained;
- [x] parsing and replacement use shared display-width offsets;
- [x] email-like and out-of-project queries do not trigger I/O;
- [x] file and directory transitions match this specification;
- [x] accepted completion is one native undo operation;
- [x] paste and image markers survive completion, undo, and redo;
- [x] repeated completion exceeds 255 operations without registry failure;
- [x] file rows render through the existing `PickerStackView` and `PickerList`;
- [x] no second input, popup anchor, polling loop, or new keybinding catalog exists;
- [x] rapid typing retains stable rows while Escape, exact files, empty results, errors, replacement, and disposal reject stale work;
- [x] submission remains ordinary text with no implicit file read or attachment;
- [x] coding-agent, pure transition, Composer, and real OpenTUI tests are green;
- [x] architecture, ADR, and parity documentation record the owner split and intentional deviations.
