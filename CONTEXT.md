# Zi

Zi is an extensible local coding-agent product. Pi supplies model and agent-loop primitives, Zi owns coding-agent policy, and OpenTUI presents that policy as a terminal application.

## Language

**Agent core**:
The lower-level Pi agent loop that streams model output and executes tools. It is a mechanism Zi configures, not the Zi product boundary.
_Avoid_: Pi coding agent, runtime

**Agent session**:
One coding conversation and its policy: active model, session resources, tools, durable history, queueing, compaction, retries, and its bound extension lifecycle.
_Avoid_: Chat, agent core

**Work plan**:
The session-scoped ordered checklist for non-trivial work. It is a complete bounded snapshot of concise steps and their `pending`, `in_progress`, `completed`, or `cancelled` status, with at most one step in progress. Replacements are appended to the session journal, projected by `AgentSession`, and rendered without a second mutable copy.
_Avoid_: Task list, project plan, backlog, shell task

**Session journal**:
The append-only JSONL authority for one agent session's durable history. Format 2 stores image bytes in content-addressed session image blobs while journal records retain validated references. The session journal owns aggregate storage admission, transactional appends, torn-tail repair on the next append, streaming restore, and deletion of its blob directory.
_Avoid_: Transcript cache, provider context, message database

**Resident session tail**:
The exact physical journal suffix required to derive current provider context and transcript presentation after the latest compaction. Persisted history before this suffix remains authoritative on disk but is not retained as parsed messages; in-memory sessions retain that cold prefix in bounded raw-or-Zstd UTF-8 blocks. Explicit full-journal access may materialize cold entries without changing residency.
_Avoid_: Deleted history, compacted journal, TUI message cache

**Session image blob**:
A SHA-256-addressed raw image file owned by one format-2 session journal. Active messages hydrate the provider's base64 image value on demand; compacted cold history retains only its journal reference. Blob bytes and journal bytes share one session storage limit.
_Avoid_: Attachment upload, global media cache, inline base64 journal

**Session shell**:
The session-scoped coding-agent owner of shell task identity, foreground/background transitions, subprocess groups, bounded output files and previews, completion, retention, and disposal. Its Bash and task tools are adapters over the same task state. Run interruption stops foreground work; demoted or explicitly backgrounded work survives until completion, explicit kill, timeout, output bounds, or final session disposal.
_Avoid_: Global process manager, TUI task registry, detached Bash process

**Tool result details**:
The bounded, typed, client-neutral facts a built-in tool returns separately from model-facing content. They describe progress or outcome without requiring a client to parse explanatory prose.
_Avoid_: UI metadata, rendered result, tool payload

**Code-mode tool value**:
The bounded JSON-compatible operational result that one admitted tool returns to generated Code Mode JavaScript. Its declared shape is distinct from model-facing content and tool result details; plain text tools return a string value.
_Avoid_: Tool result details, presentation envelope, encoded JSON response

**Code mode**:
The default additive Zi tool for executing generated JavaScript in the session's programmatic runtime. It is for data-dependent loops, branching, filtering, aggregation, and multi-call workflows; ordinary coding keeps direct tools.
_Avoid_: Tool replacement, feature flag, shell alias, security sandbox

**Code cell**:
One ordinary JavaScript async function admitted to the programmatic runtime with an immutable tool-catalog snapshot. Its nested calls share one transcript tool identity, cancellation scope, bounded trace, and outcome. Tool side effects are not transactional.
_Avoid_: Agent turn, lexical REPL input, nested session, transaction

**Programmatic runtime**:
The session-scoped full-authority JavaScript environment behind Code Mode. It preserves arbitrary volatile `scratch` values across ordinary cell failures and host-owned bounded JSON `state` across successful cells, worker restart, and session resume. A failed cell rolls back `state` but not tool side effects or `scratch`; a worker restart clears `scratch`. Full local process, module, filesystem, environment, and network authority is intentional, so the runtime is fault containment rather than a security sandbox.
_Avoid_: Code worker, reusable sandbox, extension worker, credential boundary

**Nested tool trace**:
The bounded durable evidence projected from calls made during one code cell: admitted arguments such as paths, commands, or operations; current activity; outcomes; durations; short result/error previews; and console logs. Full nested results remain transient protocol data.
_Avoid_: Nested transcript, replay log, rollback journal, copied tool timeline

**Tool presentation**:
A bounded, framework-neutral display value derived from one tool invocation's arguments, lifecycle phase, content, and result details. It is never persisted or authoritative; terminal layout and native resources remain TUI-owned.
_Avoid_: Tool view model, render callback, tool component

**Session resources**:
The cwd-bound prompt inputs active for one agent session: base and appended system prompts, contextual instruction files, skill descriptors, prompt templates, and subagent profiles. Resource discovery finds candidates; the agent session owns the coherent catalog used by its conversation. Terminal themes and extension/package loading are separate capabilities.
_Avoid_: Core resources, resource registry, frontend resources

**Retry sequence**:
One bounded chain of consecutive transient model failures inside an admitted agent turn or summarization call. `AgentSession` owns classification, attempts, exponential backoff, cancellation, context exclusion, events, and final settlement. Provider/SDK retries remain a separate lower-level policy and default to zero attempts.
_Avoid_: Request loop, tool retry, overflow recovery

**Retry marker**:
An append-only session entry recording that one durable assistant failure was admitted for retry. It keeps the failed attempt available to transcript presentation while excluding it from live and resumed provider context, including later compaction input.
_Avoid_: Deleted error, UI retry row, mutable context flag

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
The optional coding-agent owner of one replaceable current `AgentRuntime`. It performs bounded session listing and whole-runtime new/resume transitions, building an unbound candidate, retiring the current extension lifecycle, and only then activating the candidate. Single-session SDK callers do not need it.
_Avoid_: Session manager, root store, TUI session controller

**Zi paths**:
The immutable coding-agent policy value for one effective cwd. It resolves global `$HOME/.zi/agent`, exact project `<cwd>/.zi`, credentials, project trust, scoped settings/resources, and cwd-partitioned sessions. A resumed session's stored cwd is admitted before this value and its cwd-bound services are constructed.
_Avoid_: Path registry, config singleton, ambient cwd

**Project trust**:
The admission decision controlling whether configuration owned by one canonical project cwd may affect Zi. Interactive decisions are explicitly session-only or saved; stored decisions may come from the cwd or its nearest decided parent. Applying an unresolved decision replaces the whole cwd-bound runtime before queued startup prompts so project settings, system prompts, skills, prompts, themes, and extensions share one admission. Trust is not a sandbox for later agent activity. A project configuration root that coincides with the explicitly admitted global root is global configuration and does not require project trust.
_Avoid_: Extension trust, repository safety, tool sandbox

**Project file search**:
The bounded coding-agent operation that enumerates and ranks validated paths beneath one session's immutable `ZiPaths.cwd`. It uses per-query Git or ignore-aware fallback traversal, retains no complete index, and owns cancellation and filesystem/process cleanup.
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

**Native text selection**:
The current terminal-highlighted text range across the composer or transcript. It is an ephemeral interaction surface, not conversation state or a selected transcript item.
_Avoid_: Copy buffer, transcript cursor, selected message

**Selection copy**:
The explicit terminal interaction that delivers the current non-empty native text selection to a clipboard. Selecting text alone never performs this operation, and failure preserves the selection for retry.
_Avoid_: Copy-on-select, message export, clipboard paste

**Assistant message copy**:
The explicit `/copy` interaction that delivers source text from the latest committed assistant message. It excludes thinking, tool calls, and the current streaming message, and is distinct from copying a native terminal selection.
_Avoid_: Selection copy, transcript export, rendered Markdown copy

**Clipboard delivery**:
The bounded attempt to make copied text available through one or more terminal or local-system routes. Delivery outcome is distinct from the selected text and from clipboard input.
_Avoid_: Selection state, paste handling, guaranteed remote clipboard

**Building block**:
A supported way to configure, extend, drive, or embed Zi with explicit compatibility and lifecycle expectations. A repository package or exported internal symbol is not a building block merely because it is technically reachable.
_Avoid_: Public internals, speculative extension point

**Extension source**:
One canonical extension entry point with its declared path, global/project/temporary scope, origin, and stable identity. Discovery returns source data without loading executable code.
_Avoid_: Loaded extension, plugin instance

**Extension load plan**:
The immutable ordered extension sources admitted for one exact session cwd after project trust. Explicit sources precede trusted project sources, which precede global sources.
_Avoid_: Extension registry, worker generation

**Extension host**:
The coding-agent owner that supervises extension generations, correlated protocol requests, diagnostics, bounded logs, atomic replacement, and final process teardown. Clients receive domain data and operations, never worker handles.
_Avoid_: Plugin registry, process manager, extension store

**Extension worker**:
The supervised child process that loads trusted extension modules, owns their JavaScript state, runs factories and handlers, and exchanges bounded protocol messages with Zi. It contains faults but is not a security sandbox.
_Avoid_: Plugin sandbox, extension thread, credential boundary

**Extension generation**:
One extension worker, one immutable load plan, one generation identity, and the resources tied to that process lifetime. Replacement creates a generation rather than mutating one.
_Avoid_: Module-cache refresh, extension registry version

**Extension lifecycle**:
The interval beginning when a committed generation receives `session_start` and ending when it receives `session_shutdown` or is forcibly terminated.
_Avoid_: Factory execution, process disposal, tool cancellation

**Custom-tool extension golden path**:
The first externally useful extension outcome: a trusted repository-owned TypeScript extension adds one model-callable tool that behaves consistently across interactive and headless Zi modes without modifying Zi.
_Avoid_: Extension infrastructure complete, plugin demo

**Coding-agent parity**:
Behavioral and architectural compatibility with `pi-coding-agent`, verified capability by capability while keeping the recreated layer owned by Zi. It is a capability and provenance standard, not the product priority order.
_Avoid_: Source identity, dependency parity, product roadmap

**Interactive-mode parity**:
Behavioral compatibility with the interactive mode inside `pi-coding-agent`, including editor actions, keybindings, queues, commands, selectors, session flows, and visible lifecycle semantics. It does not include `pi-tui`, Pi's screen architecture, or Pi's visual design.
_Avoid_: Pi TUI parity, `pi-tui` parity

**State owner**:
The module, class, store instance, reducer, or cohesive component that holds one mutable state family, owns any resources tied to it, and admits all changes to it.
_Avoid_: Shared state, mirrored state

**Product mode**:
An application adapter over `AgentSession` for one interaction environment. Interactive mode is terminal-specific; print and RPC modes are non-terminal siblings. Shared policy moves into `AgentSession` or a concrete manager, not into a lowest-common-denominator mode facade.
_Avoid_: CLI branch, universal frontend mode

**RPC connection**:
One versioned JSONL process relationship over a caller-owned `AgentSession`. It owns framing, request validation, correlation, total output sequence, bounded concurrent operations, backpressure, cancellation, and settlement; it projects public session facts but owns no conversation policy or session disposal.
_Avoid_: Remote session, API server, command bus, RPC runtime

**Subagent profile**:
Static configuration for delegated work: a profile name, description, instructions, and optional model and thinking selection. Trusted resources and programmatic extension registration are equal declaration paths into one session-owned catalog; an admitted profile activates standard orchestration but is not a running child or a claim about permissions, tools, worktrees, or filesystem isolation.
_Avoid_: Subagent, role, agent type, permission profile

**Subagent**:
One runtime child Zi agent session created from a subagent profile whose conversation remains authoritative in that child. Subagents remain direct children of one parent session; sibling collaboration is routed by that parent rather than by a separate peer network.
_Avoid_: Subagent profile, worker, tool call, copied parent agent

**Subagent name**:
The parent-session-unique runtime identity chosen when a subagent is spawned. It is both the readable collaboration label and the routing key for every later operation; the selected subagent profile remains separate static configuration.
_Avoid_: Subagent type, role, operational ID

**Subagent supervisor**:
The `AgentSession`-owned controller of direct-child names, admission, process lifetimes, work cycles, bounded completion retention, durable evidence, and shutdown. `AgentSession` derives standard orchestration from its admitted profile catalog; extensions may reach the same mechanics only through bounded session operations for optional custom workflows.
_Avoid_: Extension generation, agent coordinator, extension API object, session registry

**Peer message**:
Bounded context sent from one subagent to a live sibling through their common parent supervisor. The parent derives the sender identity, validates the sibling target, and admits the message queue-only; a peer message neither assigns a work cycle nor replaces parent completion delivery.
_Avoid_: Subagent task, completion, direct process message, peer network event

**Subagent completion**:
The bounded result projected when admitted subagent work settles, including identity, status, final text, duration, and omission facts. It is not a copied child transcript.
_Avoid_: Child stdout, event stream, transcript snapshot

**CLI invocation**:
One immutable startup intent resolved before runtime construction from arguments, supported Zi environment defaults, and captured process facts. Arguments outrank environment defaults; cwd and session selection remain explicit invocation operations rather than ambient configuration.
_Avoid_: CLI settings, process globals, argument bag

**Runtime session intent**:
The one startup choice admitted by the coding-agent SDK: create a new persistent or ephemeral session, continue the current cwd's recent session, or resume an exact journal. Persistence belongs only to the new-session state.
_Avoid_: Session flags, combinable persistence options

**Interactive store**:
The instance-scoped Nano Store owner created by one terminal `InteractiveMode`. It binds the current `AgentSession`, rejects stale events, and owns only terminal state such as transient tool blocks and render revisions. It does not mirror durable session state.
_Avoid_: Global store, frontend database, coding-agent policy

**Interactive keybindings**:
The instance-scoped terminal owner of semantic action IDs, effective key overrides, matching, hints, and conflict metadata. It translates OpenTUI key events into closed prompt/transcript actions but contains no callbacks or session operations.
_Avoid_: Global keymap, raw product chords in components, command bus

**Notification center**:
The `InteractiveMode`-owned controller of active notification groups, exclusive internal group claims, keyed item replacement, finite expiry, close and suppression state, bounded removed history, and the retained bottom-right transcript surface. It presents passive notices, including workflow progress and outcomes, survives session-screen replacement, and never starts a model turn.
_Avoid_: Toast store, transcript message, session notification state

**Built-in notification presenter**:
The `InteractiveMode`-owned producer for the exclusive bounded `zi.system` group. It translates Zi-owned bootstrap, extension, project-trust, compaction, copy, shell-capacity, reload, and prompt-workflow conditions into keyed notices, and removes them when their authoritative condition or session generation changes.
_Avoid_: Prompt-status owner, public notification API in components, session state

**Working status**:
The dedicated `PromptView` activity row derived from provider runs, compaction, cancellation, and retry backoff. It remains separate from `NotificationCenter` because it is continuously animated layout status rather than a notification item.
_Avoid_: Workflow notice, transcript message, copied session state

**Notification item**:
One bounded active notice identified optionally by a key within a group. It retains message, annotation, severity, expiry, visibility, history policy, and immutable JSON data until expiry or explicit removal moves it to bounded history.
_Avoid_: Transcript row, working status, subagent result

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
