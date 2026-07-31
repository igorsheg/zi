# Architecture

## Fixed references

| Source                      | Role                                                     |
| --------------------------- | -------------------------------------------------------- |
| `pi-ai` and `pi-agent-core` | Runtime dependencies                                     |
| `pi-coding-agent`           | Coding-agent architecture and product-behavior reference |
| Pi interactive mode         | Terminal interaction behavior and ownership reference    |
| `@opentui/core`             | Terminal implementation                                  |
| OpenCode                    | Proven OpenTUI patterns worth evaluating                 |

Zi recreates `pi-coding-agent`; it does not depend on it. Parity includes `AgentSession`, session/services construction, settings, model and resource owners, tools, extensions, and interactive/print/RPC modes—not only visible features.

Pi's `interactive-mode.ts` directly imports `pi-tui`, constructs terminal components, and delegates coding-agent policy to `AgentSession`. Print and RPC modes operate independently over the session/runtime boundary. Zi follows that separation: `AgentSession` is reusable core policy; interactive mode is a terminal application.

## Workspaces

```text
packages/
  coding-agent/   AgentSession, managers, tools, shared policy, non-terminal modes
  tui/            terminal-specific interactive mode and imperative OpenTUI
  cli/            runtime construction, argument parsing, mode selection
```

Dependencies point inward:

```text
cli -> tui -> coding-agent
cli -> coding-agent
```

- `coding-agent` never imports a frontend.
- `tui` consumes coding-agent public APIs and owns terminal behavior and native interaction state.
- `cli` owns the immutable CLI invocation: argument/environment precedence, TTY mode resolution, bounded stdin, process output backpressure, signals, exit status, and final session disposal. It dynamically imports `tui` only after selecting interactive mode. See [ADR 0020](adr/0020-cli-invocation-resolves-once-from-explicit-layers.md).
- Future web clients consume `AgentSession`, concrete managers, or RPC; they do not inherit terminal interaction state.
- There is no `shared`, `common`, universal mode facade, generic UI model, or event bus.
- A new package requires an independently meaningful lifecycle or public use case.

## State and transition architecture

Stateful behavior follows [ADR 0004](adr/0004-explicit-state-and-transitions.md): one owner holds concrete data and resources, admits operations from the current state, and applies explicit transitions. The same discipline applies inside an `AgentSession`, TUI store, imperative component, tool invocation, or process lifecycle.

Mutually exclusive modes use direct discriminated unions with domain fields:

```ts
type PickerState =
  { type: "closed" } | { type: "model"; query: string } | { type: "thinking-level"; selected: ThinkingLevel }
```

Do not replace this with coordinated flags, generic payload envelopes, or optional fields that permit impossible combinations. Closed unions are handled exhaustively. Persisted, provider, process, and other open input is validated before an owner transitions on it.

The owner also owns temporal correctness. It records admission before starting an effect, bounds the effect, and applies completion only to the operation that started it. Cancellation, settlement, queue limits, stale results, and resource cleanup are modeled and tested with their owner.

## Coding-agent architecture

```text
createAgentSessionRuntime(options) [replaceable modes only]
  -> current AgentRuntime
  -> bounded session listing + whole-runtime new/resume transitions

createAgentRuntime(options)
  -> ZiPaths (global directory + effective cwd policy)
  -> SettingsManager + FileCredentialStore + ModelRegistry + Authentication + ResourceLoader
  -> SessionManager
  -> SessionShell (session-scoped task/process/output owner)
  -> createAgentSession(services, session options)
      -> SettingsManager preferences + SessionManager context -> new | resumed bootstrap
      -> ResourceLoader.load() -> immutable SessionResources
      -> AgentSession
          -> pi-agent-core Agent
          -> admitted session resources
          -> SessionShell-backed bash and task tools
          -> other tool definitions
          -> context accounting and compaction transaction
          -> bounded agent-turn and summarization retry
          -> later: extensions
```

### `AgentRuntime` and `AgentSession`

`createAgentRuntime()` is the high-level SDK constructor. It receives one closed `new | continue | resume` session intent, snapshots caller-owned settings and prompt arrays, and returns a readonly, frozen shell containing one `AgentSession`, its concrete path-owned services, and any user-visible bootstrap diagnostic. `createAgentSession()` is the lower-level Pi-aligned bootstrap owner for callers that already own those services and a `SessionManager`; it classifies `new | resumed`, resolves model and thinking precedence without copying journal state into settings, seeds or repairs session metadata, and asks the caller-owned `ResourceLoader` for the session's initial resources unless the caller supplies an immutable snapshot. In both cases, the creator owns final `session.dispose()`. Application modes consume caller-owned sessions and must not dispose them. See [ADR 0016](adr/0016-session-bootstrap-separates-preferences-context-and-durability.md).

`AgentSessionRuntime` is the narrow owner for clients that replace whole sessions. It retains runtime construction policy plus the initial runtime's canonical global agent directory, owns `ready | replacing | cancelling | settling | disposed`, globally serializes runtime-keyed catalog scans, rebuilds every cwd-bound service for `/new` and `/resume`, and disposes replaced sessions. Construction or pre-commit validation failure leaves the old runtime usable. Selecting the already-current journal is a no-op. The creator owns final runtime disposal; terminal mode may only request replacement cancellation during shutdown. See [ADR 0012](adr/0012-agent-session-runtime-owns-replacement.md).

`AgentSession` is the policy spine shared by application modes. It owns:

- one Pi `Agent`;
- one optional session-scoped `SessionShell`, including foreground/background task identity, process groups, bounded output retention, completion, and final disposal;
- persistence of completed messages;
- explicit `unselected | selected` model state, including login-first startup, model and thinking-level changes;
- one immutable `SessionResources` snapshot, system-prompt composition, resource diagnostics, prompt-template expansion, and bounded explicit skill invocation;
- steering and follow-up queues;
- active-run admission, interruption, queue disposition, cancellation, and settlement;
- provider-anchored context accounting, manual and provider-boundary compaction, and one overflow recovery;
- bounded transient retry across agent turns and compaction summaries, with durable failure exclusion;
- later, branch and extension policy.

It exposes Pi agent events plus session-level events. Application modes subscribe; they do not control the provider loop or persist messages themselves. Runtime creation may produce an unselected session when no provider is authenticated; the terminal still starts, while prompt admission gives `/login` then `/model` guidance until `setModel()` commits the selected transition.

Queue-mode and thinking-level changes cross live and durable state through `AgentSession`, never through a frontend settings write. A mutation validates its global/project scope, persists it, derives the effective layered value, updates the Pi agent, and then publishes a change event. Failed persistence leaves live behavior unchanged; a project override can intentionally shadow a global write, which is reported by the requested/effective mutation result. Queue-mode changes remain admissible during a run and take effect at Pi's next queue-drain boundary; thinking changes retain the session's idle-only admission and model capability clamp.

### Paths, managers, and services

`ZiPaths` is the immutable path-policy owner for one effective cwd. It resolves the global `$HOME/.zi/agent` directory, exact `<cwd>/.zi` project directory, settings, authentication, resources, and cwd-partitioned sessions. Runtime construction opens an explicit session first, then creates cwd-bound paths and services from the header cwd. See [ADR 0011](adr/0011-zi-path-policy.md).

- `SessionManager` owns one append-only JSONL session journal and its leaf; persistent creation receives `ZiPaths`. New journals retain bootstrap metadata and user input in `pending` state until the first assistant response writes the complete file; durable appends reach disk before mutating the in-memory leaf. Format-2 journals store raw images in session-owned content-addressed blobs, and journal plus blob bytes share one live 64 MiB admission limit. Restore scans through a fixed buffer and retains only the physical suffix required by the latest compaction; non-persistent sessions retain compacted history in bounded raw-or-Zstd UTF-8 blocks. Explicit `entries()` materializes cold history while runtime policy uses `retainedEntries()`. Its static current-cwd catalog operation bounds candidates, previews, concurrency, returned rows, and invalid-journal reporting; continue-recent is distinct from strict resume.
- `SettingsManager` owns defaults < valid global < valid project < construction overrides, Pi-shaped model and thinking preferences, explicit missing/loaded/invalid scopes, bounded locked persistence, reload, and non-fatal diagnostics. It never stores resumed session context.
- `FileCredentialStore` owns bounded global `auth.json` serialization, redacted credential inspection, and the Pi AI `CredentialStore` contract.
- Runtime model factories receive that credential owner, ensuring `ModelRegistry`, provider requests, OAuth refresh, and login operations cannot use shadow stores. The raw-model test adapter is isolated under `@with-zi/coding-agent/testing`.
- `Authentication` derives login methods from Pi AI providers, forwards bounded generic prompt/event contracts, owns login/logout operation identity and cancellation, and commits returned credentials through `FileCredentialStore`. It never reimplements provider protocols or OAuth refresh.
- `--api-key` is a runtime-only provider override admitted only with an explicit or settings-inferred model. It marks only that provider available and is passed as Pi AI's explicit request option, ahead of stored and ambient auth, without entering settings, credentials, events, diagnostics, or journals.
- `AgentSession` gates authentication against provider runs and model mutations, joins cancellation during interruption/shutdown, emits credential-free change events, and selects a provider's first known model after login when the session is unselected.
- `ModelRegistry` wraps `pi-ai` model discovery and configured-provider checks.
- `ResourceLoader` is the concrete cwd-bound filesystem discovery owner. Each bounded `load()` returns a new immutable `SessionResources` value containing system prompts, contextual instructions, skills, prompt templates, and non-fatal diagnostics; the loader retains no mutable current catalog.
- `AgentSession` owns the admitted snapshot used by its conversation. It exposes resource command descriptors and expands prompt templates and `/skill:name` consistently for direct, steering, and follow-up input before provider or queue admission. Skill metadata is snapshotted, while explicit skill invocation performs a fresh bounded read for progressive disclosure.
- Themes remain TUI resources. Extension and package loading remain separate future capabilities rather than entering the core loader early.
- `createAgentSession` wires these owners to a Pi `Agent`.

These are concrete owners, not speculative dependency-injection interfaces. No manager derives `.zi` paths independently or reads cwd from mutable process state after construction.

### Tools

Tools belong in `coding-agent`. Stateless file tools own their invocation bounds directly. The concrete `SessionShell` owns every shell task and its process group, foreground/background transition, shared settlement, output preview and capped spill file, completed tombstone, TTL, and session disposal. `bash`, `task_output`, and `kill_task` are thin adapters over that owner; the TUI reaches shell operations only through `AgentSession` and never copies a task registry. Run interruption remains queue/provider-owned and stops only foreground shell work through the tool signal. Final `AgentSession.dispose()` admits termination of every surviving task, while its disposed settlement remains available through `waitForIdle()` for the creator to await after terminal restoration.

Built-in tools expose two client-independent boundaries. Their typed, bounded result details describe progress and outcome separately from model-facing content. Pure coding-agent projectors validate partial arguments and persisted results into one shallow `ToolPresentation`: verb-first semantic header, optional terminal/source/diff/text body, structured notices, explicit compact/detailed windows, and generic timing policy. Presentation is derived and never persisted separately. Expected operational failures retain typed details and one agent-construction finalizer maps their error outcome to Pi's `isError`; Bash interruption is one such typed process outcome, while unexpected defects still throw.

The TUI receives lifecycle status plus `ToolPresentation`. It never switches on built-in tool names, imports result-detail types, parses model-facing footer prose, or reads files/process state to improve rendering. It owns path display and links, command highlighting, terminal-cell wrapping, selection, compact/detailed density, observed timing, lightweight accent chrome, native identity, and disposal through generic body owners. Known built-in projectors are total and retain semantic chrome when details are absent or malformed; only unknown tool names use the bounded JSON-oriented generic projection. See [ADR 0014](adr/0014-tool-presentation-is-semantic-data.md) and `docs/tool-presentation-implementation-spec.md`.

The active built-in UX scope is `read`, `bash`, `edit`, `write`, `task_output`, `kill_task`, and additive `code`. `CodeMode` freezes the other admitted tools for one execution; `CodeExecution` owns one isolated QuickJS child, cancellation, serialized nested calls, bounded trace, and cleanup. The child has no session effects or ambient guest authority, while the host preserves ordinary tool validation and policy. Nested evidence remains under one outer transcript identity and contributes file operations to compaction accounting. See [ADR 0024](adr/0024-code-mode-isolates-generated-orchestration.md). Pi's optional `grep`, `find`, and `ls` implementations remain deferred because Pi's vanilla session does not enable them and Bash already supplies their default capability.

## Application modes

The CLI parses argument-owned intent before consulting supported `ZI_*` defaults, then resolves one immutable invocation before runtime construction. Cwd is argument-only; model and thinking environment defaults use `ZI_DEFAULT_*` names so future dynamic shell metadata keeps `ZI_MODEL` and `ZI_REASONING_LEVEL`. Scalar precedence is last CLI occurrence, environment default, then the owning runtime/settings policy. Output mode and session selection are closed unions; session operations, API-key overrides, and prompt content are never ambient environment defaults. Help and version exit before environment resolution. See [ADR 0020](adr/0020-cli-invocation-resolves-once-from-explicit-layers.md).

Modes are adapters over `AgentSession`, not one universal abstraction.

- Terminal `InteractiveMode` lives in `packages/tui` because it owns OpenTUI resources and terminal semantics.
- Print mode lives in `packages/coding-agent`; it sequences bounded prompts over a caller-owned session and returns closed success/failure results without owning process or session lifetime. Text output writes only final assistant text. JSON output writes the session header and source-ordered session events as strict JSONL through a bounded single-writer queue.
- RPC mode lives in `packages/coding-agent`; one connection owns versioned JSONL framing, closed request translation, ordered session-event projection, correlated concurrent operations, output backpressure, cancellation, and bounded settlement over a caller-owned session. See [ADR 0022](adr/0022-rpc-connections-own-versioned-session-transport.md).
- Each enabled `AgentSession` owns one native `SubagentSupervisor`. It owns direct-child admission, `ChildZiProcess` RPC subprocesses, immutable definition snapshots, work-cycle revisions, the bounded completion mailbox, native journal evidence, semantic notifications, and bounded disposal. Built-in tools adapt this owner; extensions contribute only `registerSubagentType()` definitions. RPC remains a single-session transport and exposes no `agent.*` topology methods. See [ADR 0027](adr/0027-session-owned-native-subagents.md).

If terminal and web clients later duplicate concrete command or session-flow policy, that policy moves into `AgentSession` or a dedicated coding-agent owner. Zi does not anticipate that reuse with a forwarding facade.

## Imperative terminal mode

```text
AgentSession
  -> InteractiveMode
      -> SlashController
      -> InteractiveKeybindings
      -> ExitGestureController
      -> InteractiveStore
      -> SessionScreen
          -> TranscriptView + TranscriptStore
          -> PromptView + PromptStore
              -> PromptFeedbackView -> BrowserOpener
              -> QueuedInputsView
              -> Composer
              -> PickerStack + PickerStackView
                  -> PickerList
```

`InteractiveMode` owns the root renderable subtree, current session binding, session replacement, syntax-style lifetime, prompt-focus preservation, terminal disposal, one `SlashController`, one immutable `InteractiveKeybindings`, and one `ExitGestureController`. When given an `AgentSessionRuntime`, the mode exposes only narrow list/new/resume/cancel actions to its prompt workflow and applies successful runtime replacement to `InteractiveStore`; screens and stores never receive the coding-agent runtime owner. Coding-agent owners supply command descriptors; `SlashController` owns the bounded current-session aggregate, fuzzy terminal completion, range-safe composer edits, and parsing into closed built-in intents without retaining active picker state. `InteractiveKeybindings` resolves terminal-native events into closed semantic prompt/transcript actions and exposes effective hints and conflict metadata without containing action callbacks. Exit arming, expiry, consumption, and requests stay behind the concrete gesture owner rather than three lifecycle callbacks. Internal prompt coordination remains direct and typed; Pi's string-channel event bus is an extension-to-extension API, not an internal UI decomposition mechanism.

`InteractiveStore` owns the session subscription, generation, submissions, Escape cancellation with queue restoration, and at most 64 transient tool invocations in explicit `preparing | ready | running | done | failed | aborted` states. It applies only the changed `message_update` tool part by `contentIndex` and aborts nonterminal invocations left behind at `agent_end`; durable messages remain direct `AgentSession` reads. OpenTUI owns bracketed-paste parsing and textarea edits; terminal-owned `SystemClipboardReader` and `SystemClipboardWriter` perform bounded local input and native/OSC 52 output. The mode-owned `SelectionCopyController` admits explicit copy keys before screen handlers, cancels superseded writes, and clears only the unchanged native selection after confirmed delivery. `Composer` projects Pi-compatible large text pastes and images as atomic virtual extmarks, expands exact text at submission, and reports native image-marker deletion/undo; `PromptStore` remains authoritative for signature-checked active image attachments against the current model, count, byte, operation, and session identity. `PromptStore` owns terminal feedback, retained images, typed command/model/authentication/settings/session workflows, pending provider-prompt settlement, stale-session rejection, and cursor-targeted one-shot composer edit requests. Session catalogs load only after `/resume` opens; cancellation remains an explicit transient state until runtime cleanup settles. One private controller keeps those resources and transitions together; active workflows carry their admitted session identity, and picker activation dispatches from the workflow state rather than coordinating a second transition system from frame IDs. `PickerStack` owns nested bounded frames, selection, suspended parent filters, and filtering of only the active frame through direct mechanical operations. `PromptView` owns layout-driven picker observation; `PickerStackView` renders the active frame below the always-mounted composer and owns no input or subscription; `PickerList` retains at most ten visible row roots keyed by row ID within the active frame scope and resets them when the frame ID changes. `TranscriptStore` owns follow/detached/unseen navigation. Durable messages, model, queues, credentials, persistence, and activity remain direct `AgentSession` reads.

Imperative components subscribe to readable Nano Stores and update only their owned renderables. `PromptView` coordinates the focused native input and semantic key precedence; `PromptFeedbackView` owns status/link renderables and one-shot browser requests; `QueuedInputsView` owns bounded queue layout. Durable transcript message renderables are appended rather than rebuilt, preserving native selection and detached scrolling. Assistant messages are spacing-neutral sequence owners that project thinking, prose, and tool transcript items in source order; each item owns its native subtree and exactly one trailing row. `TranscriptView` admits at most 64 tool roots across embedded, standalone, and committed placement, and reparents an embedded root when its assistant is evicted before its still-retained result. Each keyed `ToolCallView` keeps one native root while parsed arguments stream, execution runs, partial output arrives, and the durable result commits; lifecycle-colored transparent open-rail chrome, cell-aware previews, and the mode-owned expand binding change children without replacing that root, clearing native selection before selectable rows are destroyed. One transcript-owned, visibility-gated renderer live request refreshes visible running elapsed labels and their stepped `◈` marker pulse from a shared timestamp. See `docs/transcript-item-presentation-implementation-spec.md`. The composer textarea is the sole prompt/filter/authentication input and remains focused while picker frames change. Secret prompts switch that native textarea to `TextAttributes.HIDDEN`, disable selection, and clear it before provider continuation; secret values never enter Nano Store state, session events, or transcripts. Authentication URLs are bounded in coding-agent, rendered as styled OSC 8 links, and admitted to the mode-owned browser opener, which limits concurrent subprocesses, bounds settlement, and kills retained processes on disposal. Product chords are resolved by the mode-owned semantic keybindings; components apply closed actions to concrete native resources and stores. Screen-wide selection copy stays out of `PromptView`; selecting text alone never writes the clipboard. Textarea contents, cursor, focus, viewport, selection, and ordinary editing remain OpenTUI-owned.

The single-file executable uses OpenTUI's bundled TreeSitter worker, runtime WASM, parser WASM, and query assets under the pinned Bun runtime. A compiled acceptance waits for real Markdown highlighting to settle and rejects exposed source markers. Assistant answers retain one Markdown renderable per text part. OpenTUI 0.4.5 still removes those blocks from the immediate frame when `streaming` changes to false, so active, promoted, and restored answers keep streaming presentation enabled; first-frame behavior tests pin that remaining upstream workaround.

## Resource shutdown

1. the first interactive exit, signal, or renderer-destroy request admits one `runTui` close transition;
2. the terminal mode stops accepting input and disposes subscriptions and renderables;
3. `runTui` requests replacement cancellation, then asks the current `AgentSession` to discard queued work and abort the active provider run and authentication operation;
4. `runTui` clears the title and destroys OpenTUI immediately;
5. outside the alternate screen, `runTui` awaits run and replacement settlement with a deadline;
6. the CLI reports any shutdown failure, disposes the runtime or single session it created, and performs the final bounded settlement wait.

Concurrent close requests share one completion. Terminal teardown does not call the lower-level queue-preserving `AgentSession.abort()` path, and the TUI never disposes its caller-owned session.

## Code shape

The codebase optimizes for legibility and local reasoning:

- concrete modules before frameworks;
- narrow public exports;
- one owner for each mutable state family;
- direct calls before buses, adapters, or generic protocols;
- explicit domain states instead of flag combinations;
- exhaustive closed unions;
- validation at external, persisted, provider, and process boundaries;
- comments only for invariants, trade-offs, and provenance;
- no speculative extension points;
- no package or file split justified only by line count.

“Scalable” means a future capability has an obvious owner and path, not that every operation passes through another abstraction.
