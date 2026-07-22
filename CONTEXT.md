# OpenZi

OpenZi is an extensible local coding-agent product. Pi supplies model and agent-loop primitives, OpenZi owns coding-agent policy, and OpenTUI presents that policy as a terminal application.

## Language

**Agent core**:
The lower-level Pi agent loop that streams model output and executes tools. It is a mechanism OpenZi configures, not the OpenZi product boundary.
_Avoid_: Pi coding agent, runtime

**Agent session**:
One coding conversation and its policy: active model, session resources, tools, durable history, queueing, compaction, retries, and lifecycle.
_Avoid_: Chat, agent core

**Session shell**:
The session-scoped coding-agent owner of shell task identity, foreground/background transitions, subprocess groups, bounded output files and previews, completion, retention, and disposal. Its Bash and task tools are adapters over the same task state. Run interruption stops foreground work; demoted or explicitly backgrounded work survives until completion, explicit kill, timeout, output bounds, or final session disposal.
_Avoid_: Global process manager, TUI task registry, detached Bash process

**Tool result details**:
The bounded, typed, client-neutral facts a built-in tool returns separately from model-facing content. They describe progress or outcome without requiring a client to parse explanatory prose.
_Avoid_: UI metadata, rendered result, tool payload

**Tool presentation**:
A bounded, framework-neutral display value derived from one tool invocation's arguments, lifecycle phase, content, and result details. It is never persisted or authoritative; terminal layout and native resources remain TUI-owned.
_Avoid_: Tool view model, render callback, tool component

**Session resources**:
The cwd-bound prompt inputs active for one agent session: base and appended system prompts, contextual instruction files, skill descriptors, and prompt templates. Resource discovery finds candidates; the agent session owns the coherent catalog used by its conversation. Terminal themes and extension/package loading are separate capabilities.
_Avoid_: Core resources, resource registry, frontend resources

**Run interruption**:
A request to stop active provider/tool work while keeping the `AgentSession` reusable. Escape cancellation returns pending queued input to the composer; lower-level interruption may preserve admitted queue work. Neither operation owns terminal teardown.
_Avoid_: Quit, shutdown, dispose

**Terminal shutdown**:
The terminal-run transition that stops input, discards queued work, signals active cancellation, restores OpenTUI immediately, and then awaits bounded settlement. The CLI remains responsible for final session disposal and exit reporting.
_Avoid_: Abort, component unmount, session disposal

**Runtime services**:
The process-scoped capabilities from which agent sessions are constructed, including models, credentials, settings, filesystem/process access, and persistence.
_Avoid_: Globals, app context

**Agent session runtime**:
The optional coding-agent owner of one replaceable current `AgentRuntime`. It performs bounded session listing and whole-runtime new/resume transitions, rebuilding cwd-bound services and disposing replaced sessions. Single-session SDK callers do not need it.
_Avoid_: Session manager, root store, TUI session controller

**OpenZi paths**:
The immutable coding-agent policy value for one effective cwd. It resolves global `$HOME/.openzi/agent`, exact project `<cwd>/.openzi`, credentials, scoped settings/resources, and cwd-partitioned sessions. A resumed session's stored cwd is admitted before this value and its cwd-bound services are constructed.
_Avoid_: Path registry, config singleton, ambient cwd

**Project file search**:
The bounded coding-agent operation that enumerates and ranks validated paths beneath one session's immutable `OpenZiPaths.cwd`. It uses per-query Git or ignore-aware fallback traversal, retains no complete index, and owns cancellation and filesystem/process cleanup.
_Avoid_: File catalog, TUI filesystem search, workspace index

**File-completion context**:
A boundary-safe textual `@` token containing the cursor. The context can remain valid while its picker is hidden; syntactic eligibility and visible choices are distinct facts.
_Avoid_: Open picker, file attachment, mention part

**Project-file autocomplete**:
The terminal interaction that scores bounded project file matches through `AgentSession`, presents useful choices in the composer-owned picker, and replaces only the active file-completion context after selection. Accepted text does not read or attach file contents.
_Avoid_: File attachment, mention part, autocomplete provider registry

**File-completion dismissal**:
The user's decision to hide choices for one active `@` token. Editing within that token does not revoke dismissal; ending the token does.
_Avoid_: Draft clearing, revision-scoped cancellation

**Completion range edit**:
A revisioned one-shot request to replace one display-offset range in the native Composer with an explicit cursor target. It is not a copied draft; OpenTUI remains authoritative for text, markers, selection, and undo.
_Avoid_: Prompt model, frontend draft state, delete-then-insert

**Coding-agent parity**:
Behavioral and architectural compatibility with `pi-coding-agent`, verified capability by capability while keeping the recreated layer owned by OpenZi.
_Avoid_: Source identity, dependency parity

**Interactive-mode parity**:
Behavioral compatibility with the interactive mode inside `pi-coding-agent`, including editor actions, keybindings, queues, commands, selectors, session flows, and visible lifecycle semantics. It does not include `pi-tui`, Pi's screen architecture, or Pi's visual design.
_Avoid_: Pi TUI parity, `pi-tui` parity

**State owner**:
The module, class, store instance, reducer, or cohesive component that holds one mutable state family, owns any resources tied to it, and admits all changes to it.
_Avoid_: Shared state, mirrored state

**Product mode**:
An application adapter over `AgentSession` for one interaction environment. Interactive mode is terminal-specific; print and RPC modes are non-terminal siblings. Shared policy moves into `AgentSession` or a concrete manager, not into a lowest-common-denominator mode facade.
_Avoid_: CLI branch, universal frontend mode

**Interactive store**:
The instance-scoped Nano Store owner created by one terminal `InteractiveMode`. It binds the current `AgentSession`, rejects stale events, and owns only terminal state such as transient tool blocks and render revisions. It does not mirror durable session state.
_Avoid_: Global store, frontend database, coding-agent policy

**Interactive keybindings**:
The instance-scoped terminal owner of semantic action IDs, effective key overrides, matching, hints, and conflict metadata. It translates OpenTUI key events into closed prompt/transcript actions but contains no callbacks or session operations.
_Avoid_: Global keymap, raw product chords in components, command bus

**Imperative TUI component**:
An owner of one OpenTUI renderable subtree and its direct updates. It exposes concrete renderables and explicit disposal; it may compose product presentation but does not decide coding-agent policy.
_Avoid_: React component, virtual DOM adapter, generic widget framework

**Picker stack**:
The instance-scoped owner of below-composer choice frames, top-frame selection/filtering, and suspended parent filters. It receives filter text from the always-focused composer and never owns an input renderable or domain action callbacks.
_Avoid_: Selector screen, picker input, dialog stack

**Explicit state machine**:
Concrete domain states and allowed transitions represented directly in data and owned operations. This describes every stateful behavior at its appropriate scale; it does not imply a statechart library, event bus, or generic tagged-union helper.
_Avoid_: Flag soup, generic payload protocol

**Transition**:
An allowed change from one explicit state to another, decided by the state owner separately from the bounded side effect it may start or complete.
_Avoid_: Setter, incidental effect
