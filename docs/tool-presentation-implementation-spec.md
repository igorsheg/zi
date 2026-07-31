# Tool presentation refactor implementation spec

Status: implemented

> Amended by [`transcript-item-presentation-implementation-spec.md`](transcript-item-presentation-implementation-spec.md): the shallow semantic presentation contract remains unchanged, while transcript-item spacing, transparent tool surfaces, lifecycle-only glyphs, and open-rail chrome replace the original panel treatment.

This specification replaces the current built-in `ToolDisplay` projection and tool-specific `ToolCallView` composition. The cutover is intentionally breaking inside Zi: old display types, projector behavior, visual fixtures, and built-in result-detail shapes are not compatibility boundaries. Persisted sessions remain readable through Pi's existing `{ content, details }` tool-result envelope. A known built-in always keeps its semantic row; obsolete or malformed details are ignored as a whole and the row degrades to bounded arguments/result content. Only unknown tool names receive the JSON-oriented generic presentation. There are no legacy tool-specific parsers or shims.

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
- I/O from renderers, including Edit file reads;
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
| Tool root identity, placement, eviction, and running refresh admission      | `TranscriptView`                                |
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

They do not copy command output text. Arguments remain the source of the command, optional bounded human description, and requested background/timeout values. The projector strips a redundant leading `Run`/`Running` from the display description but never parses arbitrary shell to invent one.

### Read

Read details carry:

- `outcome`;
- selected start and end lines;
- total file lines;
- the next offset and remaining line count when continuation is possible;
- truncation metadata;
- a closed expected-failure reason (`not_found | not_file | permission_denied | too_large | invalid_offset | unreadable`);
- a bounded error message for expected failure.

Read content carries the selected text. Continuation prose may still be included for the model, but presentation uses details.

### Write

Write details carry:

- `outcome`;
- UTF-8 byte count;
- logical line count;
- a closed expected-failure reason (`invalid_path | not_file | permission_denied | too_large | unwritable`);
- a bounded error message for expected failure.

Write content remains the concise model confirmation. The presentation body is derived from bounded arguments, not from confirmation prose. While arguments stream, the projector reports a bounded logical-line count as `so far`; settled arguments receive exact counts and completed typed details are authoritative. This is model argument progress, not incremental filesystem-write progress.

### Edit

Edit details carry:

- `outcome`;
- replacement, insertion, and deletion counts;
- bounded context-rich unified diff;
- whether the diff was truncated;
- first changed line;
- a closed expected-failure reason (`invalid_path | not_found | not_file | permission_denied | too_large | invalid_edit | match_missing | match_ambiguous | overlap | no_change | unreadable | unwritable`);
- a bounded error message for expected failure.

The executed diff is authoritative after completion. While arguments stream, the presenter reports only the number of complete replacement entries as `so far`; once arguments settle, that count is exact. Preparation, waiting, and execution remain header-only because argument progress is not filesystem mutation progress. Only a validated successful result introduces the generic diff primitive. The TUI never reads the file, computes matches, coalesces invocations, or starts a highlighter worker.

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
- command timeout, interruption, disposal, output limit, dynamic timeout-limit rejection, or background-capacity rejection;
- missing/unreadable file;
- invalid read offset discovered at execution;
- failed exact replacement;
- missing shell task;
- task stop refusal represented by a domain result.

A built-in returns `outcome: "error"` for these cases. Agent construction installs one `afterToolCall` finalizer that marks a validated built-in error outcome as Pi `isError: true`. That finalizer does not rewrite content or details and applies only to Zi built-ins.

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

This type does not own transitions. `InteractiveStore` remains the state owner. Lifecycle status lets a pure projector distinguish legitimate partial input from a malformed terminal result and choose compact/detailed behavior. `header.status` is only a bounded semantic summary such as `exit 1`; it does not duplicate lifecycle authority.

## Presentation value

```ts
export interface ToolPresentation {
  readonly header: ToolHeader
  readonly body?: ToolBody
  readonly notices: readonly ToolNotice[]
  readonly preview: ToolPreviewPolicy
  readonly timing: "duration" | "started" | "hidden"
}

export interface ToolHeader {
  readonly label: string
  readonly subject?: ToolSubject
  readonly secondary?: ToolSubject
  readonly details: readonly string[]
  readonly delta?: { readonly added: number; readonly removed: number }
  readonly status?: string
}

export type ToolSubject =
  | { readonly type: "command"; readonly text: string; readonly prompt: boolean }
  | { readonly type: "path"; readonly path: string }
  | { readonly type: "task"; readonly id: string }
  | { readonly type: "text"; readonly text: string }

export type ToolBody =
  | { readonly type: "terminal"; readonly text: string }
  | { readonly type: "source"; readonly text: string; readonly path: string; readonly startLine?: number }
  | { readonly type: "diff"; readonly text: string; readonly path?: string }
  | { readonly type: "text"; readonly text: string; readonly tone: "normal" | "muted" | "error" }

export type ToolNotice =
  | {
      readonly type: "message"
      readonly tone: "muted" | "warning" | "error"
      readonly visibility: "always" | "detailed"
      readonly text: string
    }
  | {
      readonly type: "path"
      readonly tone: "muted" | "warning"
      readonly visibility: "always" | "detailed"
      readonly label: string
      readonly path: string
    }

export interface ToolPreviewPolicy {
  readonly compact: ToolPreviewWindow
  readonly detailed: ToolPreviewWindow
}

export type ToolPreviewWindow =
  | { readonly type: "hidden" }
  | { readonly type: "head"; readonly rows: number }
  | { readonly type: "tail"; readonly rows: number }
  | { readonly type: "edges"; readonly head: number; readonly tail: number }
```

This is the entire coding-agent-to-TUI display contract. It is shallow, closed, framework-neutral, and non-recursive.

## Contract semantics

- `header.label` is the verb-first action label, not an implementation tool name.
- `header.secondary` reveals an exact resource or command beneath a human title during peek or detailed presentation.
- A command subject remains a command so the TUI can apply shell prompt, highlighting, wrapping, selection, and copy semantics; `prompt` says whether `$` is visible.
- A path subject remains a path so the TUI can shorten it for width, resolve it against session cwd, select only the path, and emit a file hyperlink.
- A task subject remains a task ID so task presentation does not parse a title string.
- Header details are short non-actionable facts such as a range or timeout; at constrained widths the TUI admits whole facts in order rather than clipping a partial fact. `delta` is a compact-only semantic insertion/deletion stat with distinct colors, not text parsed by the TUI. `status` is a bounded semantic terminal summary such as `exit 1`.
- Body text is already content-bounded but not terminal-width wrapped.
- Always-visible notices survive compact body truncation. Detailed notices remain available without cluttering successful compact rows.
- Path notices keep full-output locations selectable and linkable.
- Compact and detailed windows are explicit semantic density choices; compact row counts never exceed 12 visual rows.
- Detailed bodies retain at most 200 visual rows.
- Timing policy changes only generic header chrome. Restored rows never invent a duration.

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
  subagent.ts
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

1. Every known built-in projector is total across preparing, ready, running, and terminal input.
2. Missing or malformed arguments use the built-in's semantic placeholder instead of changing row type.
3. Running and terminal projectors validate the detail fields they consume.
4. A malformed details object is ignored as a whole; the same built-in row degrades to safe arguments and bounded result content.
5. Projectors do not partially recover a malformed details object field by field.
6. Valid closed details unions are handled exhaustively with `never` checks.
7. Only unknown tool names take the JSON-oriented generic path.
8. Serialization failure in generic arguments produces one bounded `unserializable arguments` body.

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
  refreshRunning(now: number): boolean
  setExpanded(expanded: boolean): boolean
  setActionHint(hint: string | undefined): boolean
  destroy(): void
}
```

The transcript projection invokes `projectToolPresentation()` only when the source invocation object changes. Running refresh updates only generic lifecycle chrome: elapsed text and the stepped `◈` marker pulse. It never reserializes arguments, revalidates details, retruncates source data, or rebuilds syntax presentation.

## Native ownership

One `ToolCallView` owns:

```text
stable root
  -> ToolHeaderView with lifecycle glyph and observed timing
  -> optional ToolBodyView
  -> ToolNoticeView rows
  -> optional semantic action-hint row
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

- parses the generic unified-diff primitive rather than tool result details;
- hides file/hunk metadata after deriving one relevant line-number gutter;
- renders explicit insertion/deletion markers, semantic tones, blank continuation gutters, and exact inter-hunk gap counts;
- renders pre-execution marker-only proposals when numbered hunks do not yet exist;
- performs no file I/O, invocation coalescing, or background highlighting;
- may use split view only after a separate product decision;
- is bounded before and after layout.

### TextBodyView

- renders generic, status, and fallback text;
- applies semantic normal/muted/error tone;
- performs no JSON or result-detail parsing.

## Header and notices

`ToolHeaderView` switches only on `ToolSubject.type`. It owns:

- action-label emphasis and compact lifecycle glyphs;
- command prompt, lightweight shell highlighting, hanging wrap, and compact truncation;
- optional secondary command/resource presentation;
- cwd-relative path display;
- path-only selection and hyperlink target;
- task-ID styling;
- waiting, semantic failure, and observed timing chrome.

`ToolNoticeView` switches only on notice type. Path notices expose only the path as selectable/linkable. It filters detailed notices from compact rows without interpreting tool names or notice prose.

## Compact and expanded density

A body hidden by compact policy produces a dense verb-first row. A compact running or failed body is a bounded peek. When the same invocation still owns in-flight execution evidence at completion, its projector retains bounded compact evidence instead of collapsing solely because the lifecycle settled; an explicit ownership handoff such as background Bash may hide it. This is a deterministic current-state projection, never renderer memory of an earlier height. Detailed mode uses the projector's explicit detailed window. The accepted transcript-item amendment renders visible subordinate rows on the inherited transcript surface with a lifecycle-colored open rail, semantic separator, and short closing cap.

`Ctrl+O` remains a mode-owned global action:

- compact uses each presentation's compact window;
- detailed uses its independently bounded detailed window;
- no per-row expansion state is introduced;
- the user's global density choice survives tool lifecycle updates;
- density changes never replace a tool root.

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

Forbidden transitions remain ignored or rejected by that owner as currently characterized. Presentation is a pure read of the current state and cannot trigger a transition. For Write and Edit, a successfully resolved file write is the mutation commit point: cancellation is admitted before that point, but a signal observed afterward cannot truthfully turn the committed mutation into an aborted tool result.

Lifecycle chrome is generic:

| Status      | Meaning                                             | Default chrome                             |
| ----------- | --------------------------------------------------- | ------------------------------------------ |
| `preparing` | arguments still streaming                           | muted hollow glyph and eager placeholder   |
| `ready`     | complete arguments waiting for sequential execution | accent glyph and `waiting`                 |
| `running`   | execution admitted                                  | stepped dim-to-accent `◈` and inline time  |
| `done`      | successful typed outcome                            | compact success glyph                      |
| `failed`    | Pi error or typed expected error                    | error glyph, semantic status, bounded peek |
| `aborted`   | call did not settle because the run was interrupted | error glyph and `aborted`                  |

One transcript-owned renderer live request refreshes visible running timing in generic header chrome. Completed timing is visible only in detailed mode and only when this TUI observed the running transition. A backgrounded Bash row says `started in`; restored rows show no timing.

# 6. Baseline built-in presentations

The architecture cutover gives every current built-in a coherent baseline. Later vertical slices may refine wording and visual treatment without changing the contract.

| Tool        | Header subject                | Body                                                       | Compact policy                                        | Structured notices                     |
| ----------- | ----------------------------- | ---------------------------------------------------------- | ----------------------------------------------------- | -------------------------------------- |
| Bash        | `Run` description or command  | exact command + terminal result/progress                   | running/output success tail 5; failure edges 2/3      | outcome, task, truncation, full output |
| Read        | path + actual range/status    | absolute-numbered source                                   | success hidden; failure head 4; detail edges 120/79   | detailed continuation/truncation       |
| Write       | path + written size           | numbered source from arguments                             | success hidden; failure head 4; detail head 200       | detailed preview truncation            |
| Edit        | path + replacement/diff facts | context-rich executed diff only after successful execution | preterminal hidden; success edges 5/5; failure head 4 | detailed diff truncation               |
| Task output | task ID + task-state detail   | terminal result                                            | tail 5                                                | truncation, full output, retention     |
| Kill task   | task ID                       | text only when useful                                      | hidden on success; head on failure                    | stop state/failure                     |
| Subagents   | human type or bounded count   | task/message details or bounded completion summaries       | administrative success hidden; wait head 6            | detailed agent IDs                     |

Bash is the first shipped post-cutover polish slice. It adds an optional bounded human description, verb-first compact rows, an exact secondary command, a completion-stable five-row output tail, failed edge peek, compact empty success and background handoff, structured background/admission/interruption states, detailed-only retention notices, shell highlighting, action hints, and typed cancellation without changing the client boundary. A terminal LF terminates the final usable output line instead of consuming an additional line slot; intentional blank lines before that terminator remain lines.

Read is the second shipped slice. Successful whole-file reads collapse to one basename row, while detailed mode restores the cwd-relative path; requested or partial reads show the actual selected range. Empty files, truncation, oversized lines, and closed operational failures have semantic statuses. Detailed mode reveals an absolute-numbered, dim-gutter source panel with bounded first/last retention and detailed-only continuation/truncation guidance. Model-facing continuation prose never enters the source body.

Write is the third shipped slice. Preparing writes update a bounded `lines so far` fact from streamed arguments without implying filesystem progress. Successful writes collapse to one basename row with authoritative line and byte counts using the same terminal-LF line semantics as Read, Bash, truncation, and rendering; detailed mode restores the cwd-relative path and bounded numbered content derived from arguments. Empty writes remain a one-row success, preview truncation guidance is detailed-only, and closed operational failures replace attempted content with one bounded error body.

Edit is the fourth shipped slice. Streamed arguments update a header-only `replacements so far` fact without exposing speculative content or implying filesystem progress; complete arguments waiting or running remain one line. Successful execution introduces a bounded first/last diff review beneath the basename and authoritative `+N/-N` diffstat. Detailed mode restores the cwd-relative path and renders context-rich hunks with one relevant line-number gutter, explicit change markers, wrapped continuation gutters, and exact unchanged-line gaps. An oversized individual diff line becomes an explicit bounded added, removed, or context omission line so successful details always retain visible mutation evidence; header-only truncated diffs are invalid. Closed matching and filesystem failures expose one bounded error body. Each invocation retains its own transcript identity; Zi does not adopt Grok Build's adjacent-edit coalescing, fullscreen block viewer, TUI filesystem reads, or progressive highlighter worker.

Subsequent slices are Task output and Kill task. A slice includes its coding-agent outcome, projector, compact/detailed behavior, native body behavior, constrained-width fixture, lifecycle fixture, and restoration fixture.

# 7. Bounds and performance

## Layered bounds

Bounds have separate owners:

1. `SessionShell` bounds subprocess count, runtime, captured output, spill files, aggregate retained bytes, and disposal.
2. File tools bound reads, writes, diffs, argument collections, and result details before persistence.
3. Projectors bound every string and collection before returning `ToolPresentation`.
4. Body views reject hidden previews before line splitting or wrapping and admit head, tail, and edge windows through directional bounded wrapping.
5. Detailed bodies retain at most 200 visual rows.
6. `TranscriptView` retains at most 64 tool roots and 200 committed message roots.

A later layer never justifies removing an earlier process or persistence bound.

## Projection cost

- A changed tool projects independently of sibling tools.
- Elapsed-only refresh does not call a projector.
- Width changes relayout only retained body data and do not revalidate results.
- Streaming terminal updates split bounded text but wrap only the admitted changed tail; hidden source bodies perform no wrapping.
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

- split stable header, body, notice, and running-refresh ownership;
- implement terminal/source/diff/text body owners;
- preserve one tool root, selection cleanup, post-wrap limits, and equal-assignment avoidance;
- make running refresh independent of projection.

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
- malformed terminal details degrading inside the same semantic built-in row;
- string, collection, byte, line, path, and notice bounds;
- model content remaining useful without being parsed for UI facts;
- restored serialized details producing the same presentation.

## TUI tests

Generic primitive tests cover:

- header subjects and path-only selection;
- safe command wrapping;
- compact head, tail, edges, and hidden policies after cell wrapping;
- 200-row detailed cap;
- source line numbers and highlighting fallback;
- unified diff styling and constrained widths;
- notice persistence outside body preview;
- body-kind replacement with selection cleanup;
- unchanged frame avoiding native assignments;
- running refresh changing only lifecycle chrome;
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
- old/malformed details retaining semantic built-in chrome without crashing;
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
- detailed when a body exists.

Visual fixtures assert accepted hierarchy, semantic colors, transparent tool surfaces, exact one-row inter-item spacing, and the open-rail grammar. Native cell wrapping remains structural rather than snapshot-incidental: every wrapped subordinate row keeps the rail while retained row counts stay bounded.

# 10. Acceptance criteria

The refactor is complete when:

- [x] every current built-in returns bounded typed details;
- [x] model content and structured details have documented separate purposes;
- [x] expected built-in failures retain details and are marked `isError` once;
- [x] `ToolPresentation` is the only coding-agent-to-TUI tool display contract;
- [x] the presentation algebra has exactly one header, zero or one body, notices, explicit compact/detailed windows, and generic timing policy;
- [x] the only body primitives are terminal, source, diff, and text;
- [x] `packages/tui` has no built-in tool-name dispatch or detail parsing;
- [x] projectors perform no I/O, timers, highlighting, or width work;
- [x] built-in presentation does not scrape model-facing notice prose;
- [x] unknown tools use one bounded generic fallback while invalid known tools retain semantic chrome;
- [x] one native root survives every invocation transition and placement change;
- [x] body-kind replacement clears selection before destruction;
- [x] compact truncation occurs after cell-aware wrapping;
- [x] detailed bodies retain at most 200 visual rows;
- [x] running refresh does not reproject tool data;
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
- running refresh that reconstructs tool presentation;
- old `createToolBlock`/`createCommandToolBlock` compatibility helpers if no non-test caller remains;
- tests whose only purpose is preserving the replaced display contract;
- comments or docs claiming the old union is the accepted boundary.

Delete rather than deprecate. There is no compatibility period.
