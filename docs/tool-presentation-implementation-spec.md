# Tool presentation refactor implementation spec

Status: implemented

This specification replaces the current built-in `ToolDisplay` projection and tool-specific `ToolCallView` composition. The cutover is intentionally breaking inside OpenZi: old display types, projector behavior, visual fixtures, and built-in result-detail shapes are not compatibility boundaries. Persisted sessions remain readable through Pi's existing `{ content, details }` tool-result envelope, but obsolete or malformed details receive the ordinary generic presentation. There are no legacy tool-specific parsers or shims.

See [ADR 0014](adr/0014-tool-presentation-is-semantic-data.md) for the boundary decision and [ADR 0013](adr/0013-tool-invocations-keep-one-transcript-identity.md) for invocation identity and transcript placement.

## Outcomes

The refactor must produce:

1. one obvious data flow from tool execution to native rows;
2. explicit lifecycle states with one transition owner;
3. typed and bounded built-in result details distinct from model-facing content;
4. one framework-neutral presentation contract consumed by every client;
5. no built-in tool-name dispatch or result parsing in `packages/tui`;
6. stable native identity from streamed arguments through committed result;
7. width-dependent work only in the TUI;
8. no per-tool timers, renderer effects, or frontend reads of domain resources;
9. a normal generic fallback for unknown or invalid tool data;
10. one atomic cutover with deletion of the replaced path.

The design optimizes for local reasoning rather than minimum file count or maximum abstraction. A tool's execution may remain internally specialized. The boundaries leaving that implementation may not.

## Non-goals

This refactor does not:

- add `grep`, `find`, or `ls`; Pi implements them but does not enable them in its vanilla session, and Bash already covers their default capability;
- add extension renderer registration;
- group exploration tools or collapse adjacent tools into summaries;
- add per-row focus, navigation, or expansion state;
- emulate a terminal or preserve ANSI styling;
- create a generic tool framework over Pi's `AgentTool`;
- create a recursive render-node schema;
- move durable messages or tool lifecycle authority out of `AgentSession` and `InteractiveStore`;
- change the 200-message or 64-tool transcript projection limits;
- adopt Pi's TUI, Grok's ACP/actor architecture, OpenCode's client/server state graph, or a frontend framework.

## Reference lessons

### Pi Mono

Keep:

- typed arguments and result details beside each tool;
- one stable row from partial arguments through final result;
- a generic execution shell around tool-specific semantics;
- explicit call/result projection and generic fallback;
- post-wrap preview limits and retained component reuse.

Reject:

- importing TUI components and themes into tool definitions;
- renderer callbacks that return native components;
- I/O from renderers, including edit-preview file reads;
- per-tool timers such as Bash elapsed intervals;
- lifecycle represented by interacting booleans;
- allowing every tool to invent resource lifetime and chrome.

### Grok Build

Keep:

- stable IDs independent of parent message lifetime;
- eager placeholder refinement without replacing the row;
- closed semantic presentation shapes;
- retained source values separated from width-dependent layout;
- structured paths, commands, diffs, selection targets, and copy text;
- explicit compact and detailed behavior;
- generic handling for unknown tools.

Reject:

- ACP transport and actor ownership;
- a large compatibility adapter that guesses tool kinds and parses historical shapes;
- a broad block trait covering unrelated UI capabilities;
- duplicated lifecycle and timing fields in every tool variant;
- macro or registry machinery that exists only to delegate by variant.

### OpenCode v2

Keep:

- typed input and output schemas;
- independent structured output and model-output projections;
- validation before tool results enter session state;
- producer bounds separate from generic output bounds;
- durable lifecycle unions instead of optional-field state;
- stable transcript rows that retain message/part references;
- compact header-only tools and rich body tools as two observable densities.

Reject:

- a frontend `ToolPart` switch with one component per tool;
- frontend parsing of `Record<string, unknown>` metadata;
- frontend compatibility aliases for tool names;
- component-owned backend polling and timers;
- truncation by source characters as a substitute for terminal-cell layout;
- a process-global or frontend-owned tool registry.

## Canonical language

**Tool result details** are the bounded, typed, client-neutral data returned in Pi's `AgentToolResult.details`. They describe the operation and its outcome without requiring a client to parse model-facing text.

**Tool presentation** is the bounded, framework-neutral value derived from a tool invocation for display. It is not persisted separately and never becomes authoritative state.

**Tool body primitive** is one of the four visual content semantics understood by the TUI: terminal output, source text, diff, or plain text. It is not an arbitrary component or recursive node.

## Owners

| Concern                                                                     | Owner                                           |
| --------------------------------------------------------------------------- | ----------------------------------------------- |
| Tool arguments, execution, progress, and final result                       | Pi agent core configured by `AgentSession`      |
| Tool-specific operation and result-detail construction                      | Concrete built-in tool                          |
| Shell task identity, process groups, output capture, spill files, retention | `SessionShell`                                  |
| Mapping typed expected failures to Pi `isError`                             | Agent construction in `createAgentSession()`    |
| Transient preparing/ready/running/done/failed/aborted state                 | `InteractiveStore`                              |
| Validation and framework-neutral presentation projection                    | `packages/coding-agent/src/tools/presentation/` |
| Tool root identity, placement, eviction, and elapsed refresh admission      | `TranscriptView`                                |
| Tool header/body/notice renderables and their disposal                      | `ToolCallView` and concrete body views          |
| Theme, syntax highlighting, path display, links, cell wrapping, selection   | TUI body/header views                           |
| Durable transcript and restored tool results                                | `AgentSession` / `SessionManager`               |

No owner mirrors another owner's mutable state. A presentation is a bounded derived value. A native view may retain its current presentation to avoid redundant assignments, but it is not a second tool timeline.

## Target data flow

```text
model tool-call stream
  -> AgentSession events
  -> InteractiveStore invocation transition
  -> changed invocation only
  -> projectToolPresentation(invocation)
       -> built-in projector or generic fallback
       -> bounded ToolPresentation
  -> ToolCallView.update({ status, presentation })
       -> stable ToolHeaderView
       -> zero or one stable ToolBodyView
       -> bounded ToolNoticeView rows
  -> OpenTUI layout and paint
```

Tool execution follows a separate path into the same invocation:

```text
built-in execute()
  -> typed bounded details + model-facing content
  -> one coding-agent expected-failure finalizer
  -> Pi tool execution/progress/result events
  -> the same InteractiveStore invocation
  -> the same ToolCallView root
```

There is no callback from a projector into a view, no native component in a tool definition, and no frontend lookup back into a tool or filesystem.

# 1. Tool result contract

## Model content and client details

Every built-in returns Pi's existing result envelope:

```ts
interface AgentToolResult<TDetails> {
  readonly content: readonly (TextContent | ImageContent)[]
  readonly details: TDetails
}
```

The meanings are fixed:

- `content` is provider/model-facing output. It may contain concise human instructions needed by the next model turn.
- `details` is bounded structured data for persistence, diagnostics, presentation, and future clients.
- Built-in presentation uses details for facts such as outcome, continuation, truncation, task state, and full-output location.
- Presentation may use textual content as the body payload for read and shell output, but it never parses built-in footer prose to recover structured facts.
- Details do not duplicate large text already present in content. In particular, shell output text and image bytes are not copied into details.

## Direct per-tool unions

Each tool writes its state union directly. Do not introduce `Result<T>`, payload envelopes, a generic tagged-union builder, or a tool-result class hierarchy.

A shared `outcome` field has one narrow interoperability purpose:

```ts
type BuiltInToolOutcome = "progress" | "success" | "error"
```

The remainder of each details type is concrete to its tool. Tools without progress omit the `progress` variant.

### Bash

Bash details carry:

- `outcome`;
- a rejected admission state, or a task ID once execution is admitted;
- foreground/background placement or completed state;
- timeout requested by the call;
- final `ShellTaskOutcome` when known;
- output truncation metadata;
- full-output availability, path, byte count, and retention truncation;
- a bounded error message only for `outcome: "error"`.

They do not copy command output text. Arguments remain the source of the command and requested background/timeout values.

### Read

Read details carry:

- `outcome`;
- selected start and end lines;
- total file lines;
- the next offset and remaining line count when continuation is possible;
- truncation metadata;
- a bounded error message for expected failure.

Read content carries the selected text. Continuation prose may still be included for the model, but presentation uses details.

### Write

Write details carry:

- `outcome`;
- UTF-8 byte count;
- logical line count;
- a bounded error message for expected failure.

Write content remains the concise model confirmation. The presentation body is derived from bounded arguments, not from confirmation prose.

### Edit

Edit details carry:

- `outcome`;
- replacement count;
- bounded unified diff;
- whether the diff was truncated;
- first changed line when known;
- a bounded error message for expected failure.

The executed diff is authoritative after completion. Before it exists, the presenter may show bounded replacement arguments as a text body. If a richer pre-write preview is desired, the edit tool emits a progress detail after reading and computing the diff; the TUI never reads the file.

### Task output

Task-output details carry:

- `outcome`;
- task ID;
- current `ShellTaskSnapshot` state without copied output text;
- final outcome when known;
- output truncation/full-output metadata;
- a bounded error message for a missing or failed task query.

### Kill task

Kill-task details carry:

- `outcome`;
- task ID;
- the admitted stop result (`stopping | settling | already-completed`);
- final task outcome when available;
- a bounded error message for a missing task.

## Expected failures

Expected operational failures retain structured details:

- nonzero command exit;
- command timeout, output limit, dynamic timeout-limit rejection, or background-capacity rejection;
- missing/unreadable file;
- invalid read offset discovered at execution;
- failed exact replacement;
- missing shell task;
- task stop refusal represented by a domain result.

A built-in returns `outcome: "error"` for these cases. Agent construction installs one `afterToolCall` finalizer that marks a validated built-in error outcome as Pi `isError: true`. That finalizer does not rewrite content or details and applies only to OpenZi built-ins.

Interruption and unexpected defects still throw. Do not broadly catch unknown exceptions and relabel them as expected failures. A tool catches only process/filesystem errors it can classify at its own boundary. Pi's ordinary error result remains the fallback for thrown failures.

The finalizer is policy, not a compatibility adapter. It replaces the information-losing throw path for expected failures and has one test covering each built-in.

# 2. Tool presentation contract

## Source state

The projector receives a direct invocation union matching the client-neutral lifecycle facts needed for presentation:

```ts
export type ToolPresentationSource =
  | { readonly status: "preparing"; readonly name: string; readonly args: unknown }
  | { readonly status: "ready"; readonly name: string; readonly args: unknown }
  | { readonly status: "running"; readonly name: string; readonly args: unknown; readonly result?: unknown }
  | { readonly status: "done"; readonly name: string; readonly args: unknown; readonly result: unknown }
  | { readonly status: "failed"; readonly name: string; readonly args: unknown; readonly result: unknown }
  | { readonly status: "aborted"; readonly name: string; readonly args: unknown; readonly result: unknown }
```

This type does not own transitions. `InteractiveStore` remains the state owner. The status lets a pure projector distinguish legitimate partial input from a malformed terminal result and choose a compact policy. Status is not copied into `ToolPresentation`.

## Presentation value

```ts
export interface ToolPresentation {
  readonly header: ToolHeader
  readonly body?: ToolBody
  readonly notices: readonly ToolNotice[]
  readonly preview: ToolPreviewPolicy
}

export interface ToolHeader {
  readonly label: string
  readonly subject?: ToolSubject
  readonly details: readonly string[]
}

export type ToolSubject =
  | { readonly type: "command"; readonly text: string }
  | { readonly type: "path"; readonly path: string }
  | { readonly type: "task"; readonly id: string }
  | { readonly type: "text"; readonly text: string }

export type ToolBody =
  | { readonly type: "terminal"; readonly text: string }
  | { readonly type: "source"; readonly text: string; readonly path: string; readonly startLine?: number }
  | { readonly type: "diff"; readonly text: string; readonly path?: string }
  | { readonly type: "text"; readonly text: string; readonly tone: "normal" | "muted" | "error" }

export type ToolNotice =
  | { readonly type: "message"; readonly tone: "muted" | "warning" | "error"; readonly text: string }
  | { readonly type: "path"; readonly tone: "muted" | "warning"; readonly label: string; readonly path: string }

export type ToolPreviewPolicy =
  | { readonly type: "hidden" }
  | { readonly type: "head"; readonly rows: number }
  | { readonly type: "tail"; readonly rows: number }
  | { readonly type: "edges"; readonly head: number; readonly tail: number }
```

This is the entire coding-agent-to-TUI display contract. It is shallow, closed, framework-neutral, and non-recursive.

## Contract semantics

- `header.label` is the action label, not a complete preformatted title.
- A command subject remains a command so the TUI can apply shell styling and copy semantics.
- A path subject remains a path so the TUI can shorten it for width, resolve it against session cwd, select only the path, and emit a file hyperlink.
- A task subject remains a task ID so task presentation does not parse a title string.
- Header details are short non-actionable facts such as a range or timeout.
- Body text is already content-bounded but not terminal-width wrapped.
- Notices are outside the body preview budget and remain visible when body rows are omitted.
- Path notices keep full-output locations selectable and linkable.
- Preview row counts are trusted constants produced by built-in projectors and never exceed 12 compact visual rows.
- Expanded bodies are capped by the TUI at 200 visual rows.

## No hidden UI language

Do not add:

- nested children;
- arbitrary styles or colors;
- padding, borders, width, or alignment;
- callbacks or commands;
- native renderable handles;
- formatter names;
- arbitrary metadata bags;
- a generic list/table primitive without an existing built-in that requires it.

A fifth body primitive requires a concrete tool UX that cannot be expressed by the existing four and a spec amendment explaining its owner, bounds, selection behavior, and native lifetime.

# 3. Projection

## Organization

Target coding-agent modules:

```text
packages/coding-agent/src/tools/presentation/
  types.ts
  project.ts
  bash.ts
  read.ts
  write.ts
  edit.ts
  shell-task.ts
  generic.ts
```

- `types.ts` contains only the public contract and small shared limits.
- `project.ts` contains one direct switch from built-in name to concrete projector.
- Tool projectors validate their own arguments/details and return one `ToolPresentation`.
- `shell-task.ts` contains only repeated shell output/task projection used by Bash, task output, and kill task.
- `generic.ts` handles unknown tools and invalid terminal built-in data.

Do not create a presenter registry, registration lifecycle, class hierarchy, manager, or callback stored on `AgentTool`.

## Validation

Arguments and persisted details are external/open input at this boundary.

Rules:

1. Preparing and ready projectors accept absent fields that can occur during streamed JSON construction and show one ellipsis placeholder.
2. Running and terminal projectors validate the fields they consume.
3. A malformed terminal built-in result falls back as a whole to `generic.ts`.
4. Projectors do not partially recover a malformed details object field by field.
5. Valid closed details unions are handled exhaustively with `never` checks.
6. Unknown tool names take the generic path without logging or throwing.
7. Serialization failure in generic arguments produces one bounded `unserializable arguments` body.

Small scalar readers may be shared. Do not create a schema framework for projector validation. Tool execution types provide compile-time checks; projector tests cover persisted/open input.

## Text normalization

Before returning a presentation:

- normalize CRLF and bare CR to LF;
- strip ANSI escape sequences;
- remove unsafe control characters other than LF and tab;
- bound inline labels, paths, task IDs, header details, body text, notices, and collection counts;
- preserve Unicode scalar boundaries;
- never wrap by terminal width;
- never syntax-highlight;
- never read a file or inspect process state.

The first implementation intentionally renders safe plain terminal output. ANSI interpretation is a separate product capability.

## Generic projection

Generic presentation contains:

- the bounded tool name as a text subject;
- bounded serialized arguments;
- bounded text result or error;
- a head preview policy;
- no attempt to infer paths, commands, notices, or outcome from field names or prose.

Generic fallback is ordinary behavior for custom tools, unknown tools, and obsolete persisted details. It is not a compatibility layer.

# 4. TUI rendering

## ToolCallView input

`ToolCallView` no longer receives `ActiveTool` or calls a coding-agent projector internally:

```ts
export interface ToolViewFrame {
  readonly status: ToolPresentationSource["status"]
  readonly presentation: ToolPresentation
}

interface ToolCallView {
  readonly root: BoxRenderable
  readonly isRunning: boolean
  update(frame: ToolViewFrame): boolean
  refreshElapsed(): boolean
  setExpanded(expanded: boolean): boolean
  destroy(): void
}
```

The transcript projection invokes `projectToolPresentation()` only when the source invocation object changes. Elapsed refresh updates only generic lifecycle chrome; it never reserializes arguments, revalidates details, retruncates source data, or rebuilds syntax presentation.

## Native ownership

One `ToolCallView` owns:

```text
stable root
  -> ToolHeaderView
  -> optional ToolBodyView
  -> ToolNoticeView rows
  -> optional generic elapsed row
```

The root survives:

- tool-call start/delta/end;
- preparing to ready;
- ready to running;
- progress updates;
- success, failure, or abort;
- assistant-root promotion;
- tool-result commit;
- retained-window reparenting;
- compact/expanded changes.

Changing the body primitive may replace only the body subtree. The owner clears native selection before destroying selectable descendants. Header and unchanged body primitives update in place and skip equal native assignments.

## Body owners

The TUI has four concrete body owners:

```text
TerminalBodyView
SourceBodyView
DiffBodyView
TextBodyView
```

Their common surface is concrete and narrow:

```ts
interface ToolBodyView {
  readonly type: ToolBody["type"]
  update(body: ToolBody): boolean
  setExpanded(expanded: boolean): boolean
  destroy(): void
}
```

The implementation may narrow each concrete `update()` internally. Do not export a registry or generic component API.

### TerminalBodyView

- renders safe plain output;
- compact mode applies head/tail/edges after cell-aware wrapping;
- preserves a stable bounded row set;
- does not emulate ANSI or poll background tasks.

### SourceBodyView

- infers language from the semantic path;
- renders line numbers beginning at `startLine ?? 1`;
- owns syntax-highlighting resources;
- applies preview limits after cell-aware wrapping;
- leaves the source path in the header as the single navigation target;
- falls back to plain source text if highlighting is unavailable.

### DiffBodyView

- renders a unified diff in constrained widths;
- may use split view only after a separate product decision;
- preserves semantic inserted/deleted/context styling;
- owns line-number and highlighting resources;
- is bounded before and after layout.

### TextBodyView

- renders generic, status, and fallback text;
- applies semantic normal/muted/error tone;
- performs no JSON or result-detail parsing.

## Header and notices

`ToolHeaderView` switches only on `ToolSubject.type`. It owns:

- action label styling;
- command marker and shell subject styling;
- cwd-relative path display;
- path-only selection and hyperlink target;
- task-ID styling;
- waiting/error/aborted suffix and generic spinner/rail behavior.

`ToolNoticeView` switches only on notice type. Path notices expose only the path as selectable/linkable. Notice rows do not disappear merely because body preview is truncated.

## Compact and expanded density

A body hidden by compact policy produces a compact header-only row. A visible body produces the existing framed detail treatment. There is no separate `inline | block` option.

`Ctrl+O` remains a mode-owned global action:

- compact uses each presentation's preview policy;
- expanded reveals the bounded body;
- no per-row expansion state is introduced;
- expansion never replaces a tool root.

# 5. Lifecycle and transitions

`InteractiveStore` remains the sole transient invocation state owner:

```text
preparing(partial args)
  -> ready(final args)
  -> running(partial result?)
  -> done(final result) | failed(final result)

preparing | ready | running
  -> aborted(result)
```

Forbidden transitions remain ignored or rejected by that owner as currently characterized. Presentation is a pure read of the current state and cannot trigger a transition.

Lifecycle chrome is generic:

| Status      | Meaning                                             | Default chrome                       |
| ----------- | --------------------------------------------------- | ------------------------------------ |
| `preparing` | arguments still streaming                           | muted, preparing                     |
| `ready`     | complete arguments waiting for sequential execution | accent, waiting                      |
| `running`   | execution admitted                                  | accent/spinner, elapsed when visible |
| `done`      | successful typed outcome                            | success                              |
| `failed`    | Pi error or typed expected error                    | error, details visible               |
| `aborted`   | call did not settle because the run was interrupted | error, aborted                       |

One transcript-owned renderer live request refreshes visible running elapsed labels. A completed duration is shown only when this TUI observed the running transition. Restored tool rows do not invent timing.

# 6. Baseline built-in presentations

The architecture cutover gives every current built-in a coherent baseline. Later vertical slices may refine wording and visual treatment without changing the contract.

| Tool        | Header subject              | Body                                                       | Compact policy                        | Structured notices                 |
| ----------- | --------------------------- | ---------------------------------------------------------- | ------------------------------------- | ---------------------------------- |
| Bash        | command                     | terminal result/progress                                   | tail 5                                | truncation, full output, retention |
| Read        | path + range detail         | source result                                              | hidden on success; head 10 on failure | continuation, truncation           |
| Write       | path                        | source from arguments                                      | head 10                               | argument truncation, failure       |
| Edit        | path                        | executed diff; bounded replacement text before diff exists | head 12                               | change/diff truncation, failure    |
| Task output | task ID + task-state detail | terminal result                                            | tail 5                                | truncation, full output, retention |
| Kill task   | task ID                     | text only when useful                                      | hidden on success; head on failure    | stop state/failure                 |

Bash is the first post-cutover polish slice because it exercises streamed arguments, progress, command semantics, process outcomes, backgrounding, tail preview, full-output paths, errors, aborts, expansion, timing, and stable identity.

Subsequent slices are Read, Write, Edit, Task output, and Kill task. A slice includes its coding-agent outcome, projector, native body behavior, constrained-width fixture, lifecycle fixture, and restoration fixture.

# 7. Bounds and performance

## Layered bounds

Bounds have separate owners:

1. `SessionShell` bounds subprocess count, runtime, captured output, spill files, aggregate retained bytes, and disposal.
2. File tools bound reads, writes, diffs, argument collections, and result details before persistence.
3. Projectors bound every string and collection before returning `ToolPresentation`.
4. Body views apply compact limits after cell-aware wrapping.
5. Expanded bodies retain at most 200 visual rows.
6. `TranscriptView` retains at most 64 tool roots and 200 committed message roots.

A later layer never justifies removing an earlier process or persistence bound.

## Projection cost

- A changed tool projects independently of sibling tools.
- Elapsed-only refresh does not call a projector.
- Width changes relayout only retained body data and do not revalidate results.
- Streaming terminal updates reconcile the changed tail.
- Source and diff bodies avoid assigning unchanged native content.
- Projection and body caches retain only bounded strings and indexes.
- No tool starts a renderer live request, RAF callback, timer, or polling loop.

Tests use structural counts and identity assertions, not CI wall-clock thresholds.

# 8. Atomic migration

The feature branch may proceed in internal commits, but the mergeable result has one rendering path. No compatibility adapter or feature flag lands.

## Slice A — characterize and define

- add projector contract tests for all six tools and lifecycle phases;
- add structural tests forbidding built-in dispatch/detail imports in transcript rendering;
- add the new contract types and expected-failure policy tests;
- do not preserve old visual snapshots as requirements.

## Slice B — structured tool outcomes

- replace built-in detail shapes with direct bounded unions;
- separate model content from client facts;
- install the one built-in expected-failure finalizer in agent construction;
- update complete-turn and restoration tests;
- ensure details do not duplicate shell output or media bytes.

## Slice C — semantic projection

- create the presentation modules;
- project every current built-in and generic fallback;
- validate partial, final, malformed, and persisted inputs;
- remove prose notice extraction from built-in paths.

## Slice D — generic native views

- split stable header, body, notice, and elapsed ownership;
- implement terminal/source/diff/text body owners;
- preserve one tool root, selection cleanup, post-wrap limits, and equal-assignment avoidance;
- make elapsed refresh independent of projection.

## Slice E — cutover and deletion

- project before calling `ToolCallView.update()`;
- migrate streamed, standalone, committed, restored, promoted, and evicted placements;
- migrate all six tools in the same cutover;
- delete old display variants, `displayPresentation()`, notice scraping, legacy block helpers, and obsolete tests;
- update architecture and performance documentation.

## Slice F — vertical polish

Polish one tool at a time in the fixed order. A polish slice may deepen a concrete projector or body owner but may not add tool-name logic to the TUI.

# 9. Testing

## Coding-agent tests

Each built-in has tests for:

- partial argument projection;
- ready/running projection;
- successful final details;
- expected structured failure;
- thrown defect/interruption behavior where relevant;
- malformed terminal details falling back generically;
- string, collection, byte, line, path, and notice bounds;
- model content remaining useful without being parsed for UI facts;
- restored serialized details producing the same presentation.

## TUI tests

Generic primitive tests cover:

- header subjects and path-only selection;
- safe command wrapping;
- compact head, tail, edges, and hidden policies after cell wrapping;
- 200-row expanded cap;
- source line numbers and highlighting fallback;
- unified diff styling and constrained widths;
- notice persistence outside body preview;
- body-kind replacement with selection cleanup;
- unchanged frame avoiding native assignments;
- elapsed refresh changing only lifecycle chrome;
- destruction releasing every renderable and live request.

## Transcript tests

Retain or add tests for:

- one tool root through all lifecycle and commit phases;
- skipped sequential calls becoming aborted;
- coalesced events;
- source ordering among assistant parts;
- standalone fallback promotion;
- assistant-boundary eviction and reparenting;
- restored committed results;
- 64-tool projection bound;
- old/malformed details using generic fallback without crashing;
- no stale callback crossing session replacement.

## Structural tests

The final tree must prove:

- transcript rendering contains no switch or comparison on built-in tool names;
- `packages/tui` imports no built-in details types;
- coding-agent presentation imports no OpenTUI modules;
- projectors contain no filesystem, process, timer, renderer, syntax, or width dependencies;
- body owners contain no built-in argument/result parsing;
- no old/new dual renderer remains.

## Visual fixtures

For each tool, capture normal and constrained widths for:

- preparing or ready;
- running when observable;
- success;
- failure;
- compact;
- expanded when a body exists.

Visual fixtures assert accepted hierarchy and semantic colors. They do not freeze incidental spacing that native cell wrapping owns.

# 10. Acceptance criteria

The refactor is complete when:

- [x] every current built-in returns bounded typed details;
- [x] model content and structured details have documented separate purposes;
- [x] expected built-in failures retain details and are marked `isError` once;
- [x] `ToolPresentation` is the only coding-agent-to-TUI tool display contract;
- [x] the presentation algebra has exactly one header, zero or one body, notices, and preview policy;
- [x] the only body primitives are terminal, source, diff, and text;
- [x] `packages/tui` has no built-in tool-name dispatch or detail parsing;
- [x] projectors perform no I/O, timers, highlighting, or width work;
- [x] built-in presentation does not scrape model-facing notice prose;
- [x] unknown and invalid tools use one bounded generic fallback;
- [x] one native root survives every invocation transition and placement change;
- [x] body-kind replacement clears selection before destruction;
- [x] compact truncation occurs after cell-aware wrapping;
- [x] expanded bodies retain at most 200 visual rows;
- [x] elapsed refresh does not reproject tool data;
- [x] no tool owns a timer, live request, or polling loop;
- [x] all replaced display types, helpers, tests, and dual paths are deleted;
- [x] `bun run check` passes;
- [x] `git diff --check` passes.

# 11. Required deletions

The cutover is not complete while any of these concepts remain:

- `ToolDisplay` and its per-tool variants;
- `projectToolDisplay()`;
- `displayPresentation()` switching on tool display variants;
- TUI parsing of built-in arguments or details;
- regex extraction of built-in bracket notices;
- elapsed refresh that reconstructs tool presentation;
- old `createToolBlock`/`createCommandToolBlock` compatibility helpers if no non-test caller remains;
- tests whose only purpose is preserving the replaced display contract;
- comments or docs claiming the old union is the accepted boundary.

Delete rather than deprecate. There is no compatibility period.
