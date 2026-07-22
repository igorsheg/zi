# Pi coding-agent parity roadmap

The target is coding-agent architecture parity and observable product-behavior parity, including Pi's interactive mode, without source identity. Each item is complete only with an OpenZi-owned acceptance test.

## P0 — one dependable turn

- [x] Explicit provider registration and environment/API-key auth
- [x] Model resolution, explicit unselected startup, and clear no-model diagnostics
- [x] System prompt with cwd and project instructions
- [x] `read`, `bash`, `edit`, and `write`
- [x] Streaming assistant text and thinking
- [x] Streaming tool lifecycle and bounded output
- [x] Escape cancellation with queue restoration and settled run ownership
- [x] Double-Ctrl+C/Ctrl+D exit and bounded terminal shutdown
- [x] Append-only JSONL session with restore
- [x] Accepted default session screen and prompt appearance
- [x] Faux-provider integration and OpenTUI frame snapshots

### P0 evidence

- `packages/coding-agent/test/complete-turn.test.ts` drives the real Pi agent loop through `write`, `read`, `edit`, and `bash`, then restores JSONL.
- `packages/tui/test/interactive/complete-turn.test.ts` submits through OpenTUI's `TextareaRenderable` and captures the resulting frame.
- `packages/tui/test/interactive/visual-parity.test.ts` fixes representative normal and constrained character frames plus semantic color spans for user, thinking, Markdown, transparent open-rail tools, and prompt presentation.
- Tool semantics are ported from `pi/packages/coding-agent/src/core/tools/` at the commit pinned in `docs/reference-pins.md`. Typed result details and the shallow semantic presentation contract live in coding-agent; [ADR 0014](adr/0014-tool-presentation-is-semantic-data.md), `docs/tool-presentation-implementation-spec.md`, and `docs/transcript-item-presentation-implementation-spec.md` define the implemented coding-agent/TUI boundary and transcript chrome.
- `packages/tui/test/interactive/interactive-store.test.ts` fixes `message_update` argument streaming through preparing/ready/running/terminal states. `transcript-performance.test.ts` proves source ordering, transcript-item spacing, same-kind coalescing, and one native tool root through argument, execution, partial-result, and committed-result phases; `tool-block.test.ts` fixes lifecycle chrome, transparent rows, structural selection, post-wrap bounds, structured Bash notices, and in-place density changes. See ADR 0013.

### P0 lifecycle evidence

- `packages/coding-agent/test/agent-session-queue.test.ts` distinguishes queue-preserving interruption, Escape cancellation that returns pending input, and shutdown cancellation that discards pending input before aborting. `packages/coding-agent/test/bash.test.ts` proves abort terminates the subprocess group and settles with bounded captured output. All paths prevent discarded work from continuing.
- `packages/tui/test/interactive/app.test.ts`, `prompt-queue.test.ts`, and `run.test.ts` drive native-selection and picker precedence, Pi's 500 ms double-Ctrl+C window, Ctrl+D, Escape restoration, provider errors, concurrent SIGHUP/renderer teardown, immediate terminal restoration, queued-work disposal, shutdown failure propagation, and caller-owned session lifetime.
- Double-Ctrl+C and Ctrl+D behavior comes from Pi's `interactive-mode.ts` at the pinned commit. Renderer-destroy completion and scoped SIGHUP cleanup are characterized from OpenCode's OpenTUI application at its pinned commit. OpenZi deliberately restores OpenTUI before awaiting its bounded provider settlement.

### Interactive keybinding evidence

- `packages/tui/test/interactive/interactive-keybindings.test.ts` fixes semantic prompt/transcript action resolution, normalized overrides, explicit disablement, descriptions, effective hints, conflict reporting, and reserved-versus-overridable extension metadata.
- Real OpenTUI fixtures prove prompt clear/exit/newline, picker navigation, transcript navigation, and visible transcript hints follow one per-mode binding instance while default lifecycle and selection precedence remain unchanged.
- The owner split is characterized from Pi's `core/keybindings.ts`, `CustomEditor`, `InteractiveMode`, and `ExtensionRunner.getShortcuts()` at the pinned commit. OpenZi keeps the owner in `packages/tui`, makes it immutable and instance-scoped, and does not copy Pi TUI's mutable global manager.

## P1 — daily-driver session behavior

- [x] Model picker
- [x] Thinking-level picker
- [x] Session create/resume/list/switch
- [x] Steering and follow-up with bounded queues
- [x] Session-owned foreground/background shell tasks and interactive demotion
- [x] Retry policy and visible countdown
- [x] Context usage and automatic/manual compaction
- [x] Slash-command completion and `@` project-file completion
- [x] Conversation scrolling, follow-tail, unseen-line hint, selection/copy
- [x] Composer session-history recall with multiline boundary movement and exact draft restoration
- [x] Typed tool-result and semantic-presentation cutover with transcript-item spacing and open-rail polish for all six active built-ins
- [x] Settings: global and project scope
- [x] Print and JSON modes sharing the same `AgentSession`
- [x] Authentication commands and composer-owned provider flows

`@` project-file autocomplete is implemented from [`docs/file-autocomplete-implementation-spec.md`](file-autocomplete-implementation-spec.md). OpenZi preserves Pi's textual completion behavior while moving bounded Git/fallback search into coding-agent, restricting scope to the exact project cwd, and keeping accepted references ordinary prompt text. Unlike Pi's editor, exact file text and unmatched refinements become quiet, Escape suppresses the whole token, and visible results remain stable while a changed query is rescored.

Context accounting and compaction are implemented from [`docs/context-compaction-implementation-spec.md`](context-compaction-implementation-spec.md) and accepted in [ADR 0015](adr/0015-context-compaction-is-an-append-only-session-transaction.md). The implementation keeps Pi's append-only, tail-preserving behavior while adopting Grok Build's provider-boundary accounting, validation, and bounded failure lessons.

### P1 context-compaction evidence

- `packages/coding-agent/test/compaction.test.ts` fixes provider-anchored estimates, model-relative budgets, safe assistant/tool-result cuts, iterative prior-summary carry-forward, deterministic successful file operations, bounded serialization and UTF-8 splitting, chunk refusal, and summary/reduction validation.
- `packages/coding-agent/test/session-manager.test.ts` fixes transactional append ordering, marker restore, repeated projection across an older marker, durable overflow failures with active omission, semantic-reference rejection, torn-tail behavior, and in-memory parity.
- `packages/coding-agent/test/agent-session-compaction.test.ts` fixes manual admission, commit and cancellation; pre-prompt and tool-boundary compaction; queue continuation; run-local failure suppression; one overflow recovery; second-overflow refusal; context replacement; and ordered lifecycle events despite observer failure. `packages/coding-agent/test/context-usage.test.ts` fixes measured/estimated transitions and stale pre-marker usage on restore.
- `packages/tui/test/interactive/prompt-store.test.ts`, `settings.test.ts`, and `transcript-performance.test.ts` fix exact `/compact` focus forwarding, scoped On/Off policy, success feedback, and authoritative equal-length transcript rebuild with stable projection bounds. `packages/coding-agent/test/print-mode.test.ts` proves headless JSON preserves compaction start → durable entry → end ordering without terminal policy.

Pi's optional `grep`, `find`, and `ls` implementations are deliberately deferred: its vanilla session does not enable them, and Bash already supplies their default capability. They are not part of the current built-in UX scope.

### P1 retry evidence

- `packages/coding-agent/test/agent-session-retry.test.ts` fixes Pi AI-owned transient classification, disabled/quota refusal, the three-attempt budget, one logical settlement, `agent_end.willRetry`, cancellation with exact queue restoration, retry-before-follow-up ordering, durable context exclusion across compaction and resume, and retained failed-attempt presentation.
- `packages/coding-agent/test/agent-session-compaction.test.ts` proves manual and automatic summarization use the same bounded policy, remain inside the compaction operation, and release cancellation without another provider call. `packages/coding-agent/test/print-mode.test.ts` fixes source-ordered retry events and one final headless settlement.
- `packages/tui/test/interactive/retry.test.ts` drives the real semantic interrupt binding, derives the countdown from the session deadline through the existing renderer live lifecycle, proves live-request cleanup, and retains the failed attempt beside the recovered answer. `packages/tui/test/interactive/settings.test.ts` exposes scoped automatic retry enablement.
- Pi turn behavior is characterized from `core/agent-session.ts`, retry classification from `pi-ai/src/utils/retry.ts`, and countdown behavior from Pi interactive mode at the pinned commit. Post-pin Pi `8e53e0e4` and its aborted-retry fix `243f64be` supplied the compaction/branch-wide policy evidence. OpenZi keeps provider/SDK retries at zero by default, caps three exponential waits below two minutes, persists retry markers for deterministic resume, and uses no terminal timer. See [`docs/retry-implementation-spec.md`](retry-implementation-spec.md).

### P1 session-lifecycle evidence

- `packages/coding-agent/test/agent-session-runtime.test.ts` fixes globally serialized runtime-keyed listing, current-session no-op, new-session replacement, cross-cwd service reconstruction, pre-commit race rejection, failed-construction preservation, cancellation, and creator-owned disposal. `packages/coding-agent/test/session-manager.test.ts` fixes pending-to-durable creation on the first assistant response, retryable first-write failure, resumable context derivation, recent ordering, invalid-journal isolation, bounded files and previews, continue-recent, and full-load/catalog torn-tail recovery.
- `packages/tui/test/interactive/session-selector.test.ts` drives `/resume` and `/new` through the real composer-owned picker, verifies whole-session rebinding, read-only browsing during a run, replacement refusal until idle, current-session no-op, transcript replacement, focus preservation, invalid counts, and old-session disposal. `packages/tui/test/interactive/prompt-store.test.ts` keeps cancellation explicit until runtime settlement. `packages/cli/test/args.test.ts` distinguishes strict `--resume` from `--continue` and rejects the removed `--session` spelling.
- `AgentSessionRuntime` follows Pi's replacement boundary in `core/agent-session-runtime.ts`, while target-before-invalidation and bounded listing deliberately preserve OpenZi's failure and resource policy. Grok Build's pinned session startup, storage, and picker code supplies secondary torn-write, stale-load, cross-cwd, and catalog-scale failure cases; see ADR 0012.

### P1 model-selection evidence

- `packages/coding-agent/test/model-selection.test.ts` covers registry-order choices, provider-scoped authentication, bounded catalog work, canonical thinking capabilities, coherent persistence/events, admission, and model-validation races.
- `packages/coding-agent/test/runtime-paths.test.ts` and `model-onboarding.test.ts` fix Pi-shaped default settings, new-session metadata seeding, journal-over-settings resume precedence, configured fallback, old-journal model derivation, missing-thinking repair, explicit unselected startup, prompt guidance, first authenticated selection, and unavailable-model resume without history mutation. `packages/tui/test/interactive/model-onboarding.test.ts` proves the real terminal renders the unselected state before `/login` exists.
- `packages/tui/test/interactive/model-selector.test.ts` drives slash completion, exact and fuzzy `/model` paths, configured-provider filtering, Pi ordering, wrapped navigation, cancellation, mutation failure, stale completion, session replacement, persistent composer focus, and nested parent-filter restoration through real OpenTUI input and `AgentSession`.
- `packages/tui/test/interactive/picker-stack.test.ts` fixes top-frame filtering, wrapped selection, nested push/pop, and suspended parent-filter restoration without an input renderable.
- `packages/coding-agent/test/slash-commands.test.ts` fixes coding-agent ownership of supported built-in command descriptors.
- Mode-owned `SlashController` assembles a bounded current-session catalog, fuzzy-ranks command completion, safely splices the selected token, and parses invocation text into closed intents without retaining active picker state. Mode-owned `InteractiveKeybindings` resolves effective terminal actions without containing callbacks. `PromptStore` owns typed workflows and operation identity. `PickerStack` owns nested choice mechanics, while `PickerStackView` renders below the composer without creating another input. `PromptView`, `Composer`, `PickerStackView`, and `PickerList` contain no supported command names, argument rules, or dispatch policy.
- Command catalog composition, terminal parsing, exact reference matching, fuzzy search, sorting, and selector keys are characterized from Pi's `interactive-mode.ts`, `model-selector.ts`, `model-search.ts`, `model-resolver.ts`, and `pi-tui` fuzzy/editor implementation at the pinned commit.

### P1 project-file autocomplete evidence

- `packages/coding-agent/test/project-file-search.test.ts` fixes exact `OpenZiPaths.cwd` rooting, Git tracked/untracked and standard-ignore behavior, directory-scoped nested ignore semantics, conservative unreadable/oversized-ignore truncation, hidden entries, directory-symlink non-traversal, nested ranking, validation, cancellation, single flight, and disposal.
- `packages/tui/test/file-completion.test.ts` fixes bounded native-cursor token parsing, email and out-of-project rejection, full-token ranges, quoting, file/directory formatting, debounce, latest-query collapse, post-acceptance dismissal, stale work, and bounded picker projection. `packages/tui/test/composer.test.ts` fixes one-step native undo/redo, prior history, marker identity and offset preservation, overlap refusal, and more than 255 owned replacements without registry growth.
- `packages/tui/test/interactive/file-autocomplete.test.ts` drives stable rescoring, exact-file quieting, token-scoped Escape, directory continuation, file acceptance, persistent focus, and ordinary-text submission through the real OpenTUI composer and coding-agent search boundary.
- OpenZi deliberately differs from Pi by owning search in coding-agent, admitting only project-relative paths under the immutable session cwd, using Git plus a bounded fallback walk rather than managed `fd`, not traversing directory symlinks, and never reading completed files implicitly.

### P1 authentication evidence

- `packages/coding-agent/test/authentication.test.ts` fixes provider-derived API-key/OAuth methods, generic text/secret/select/manual-code prompts, browser/device events, interaction bounds, locked persistence, Pi AI-owned refresh, ambient auth after logout, stale completion rejection, and session-level cancellation/model gating.
- `packages/coding-agent/test/runtime-api-key.test.ts` and `packages/cli/test/args.test.ts` fix `--api-key` parsing, required model-provider inference, request-option precedence, model availability, unchanged stored credentials, no auth-file creation, and loss of the override in a fresh runtime.
- `Authentication` invokes the installed Pi AI provider contracts and persists through the runtime credential owner; provider protocols and OAuth refresh remain below that boundary. `AgentSession` gates this owner against runs and model mutations and chooses the provider's first known model after login when currently unselected.
- `packages/tui/test/interactive/authentication.test.ts` drives slash completion, exact provider routing, nested provider/method filters, multi-prompt hidden API-key entry, OAuth URL/device/select/manual-code/progress presentation, OSC 8-safe links, Escape cancellation, stale session replacement, first-model title updates, and stored-only logout through real OpenTUI input.

### P1 composer-history evidence

- `packages/coding-agent/test/session-manager.test.ts` fixes bounded reference indexing, exact trimmed text extraction, consecutive deduplication, stable-ID traversal, compaction independence, append behavior, and journal restore. `AgentSession` exposes only latest/older lookup; no frontend receives a copied history timeline.
- `packages/tui/test/composer.test.ts` fixes the direct `idle | browsing` zipper, Pi's idle-snap versus browsing-boundary cursor behavior, no-wrap traversal, visited redo, edit detachment, display-width cursor placement, exact draft cursor/paste/image restoration, replacement-failure rollback, catalog turnover without editor reset, stable-ID reuse across abandoned browses, pinned native undo/redo references, and repeated traversal beyond OpenTUI's default 255-slot failure point.
- `packages/tui/test/interactive/prompt-history.test.ts` drives default and overridden semantic actions, picker precedence, full-journal compacted recall, session replacement, focus, and attachment synchronization through real OpenTUI input. Queue restoration remains the separate `app.message.dequeue` path.
- The interaction follows Pi's inline editor history while deliberately keeping the bounded catalog in `SessionManager`, deriving resumed history from the full journal, admitting queued input only after commit, and deferring historical image recall. See [`docs/composer-history-implementation-spec.md`](composer-history-implementation-spec.md).

### P1 steering and follow-up evidence

- `packages/coding-agent/test/agent-session-queue.test.ts` covers delivery priority, queue modes, tool-batch timing, identity, bounds, dequeue, cancellation, continuation, and activity transitions through `AgentSession`. It also fixes global/project queue-mode mutations as one durable-to-live transition, including shadowed global values, invalid-scope and persistence refusal, effective-only events, active-run drain boundaries, and runtime restoration.
- `packages/tui/test/interactive/prompt-queue.test.ts` drives Return, Alt+Enter, Alt+Up, Escape, and Ctrl+C through real OpenTUI input and asserts queue rows, restoration, overflow, and cell-aware truncation.
- Behavior is characterized from `packages/agent/src/agent.ts`, `packages/agent/src/agent-loop.ts`, `packages/coding-agent/src/core/agent-session.ts`, and `packages/coding-agent/src/modes/interactive/interactive-mode.ts` at the Pi commit pinned in `docs/reference-pins.md`.
- Non-aborting dequeue prevents delivery while an entry remains in the core queue. `pi-agent-core` exposes no claim callback, so an entry already drained by the core before its `message_start` may still arrive; acceptance tests fix both clear-before-commit and commit-before-clear behavior at that dependency boundary.

### P1 shell-task evidence

- `packages/coding-agent/test/bash.test.ts` fixes foreground cancellation, process-group teardown, explicit background execution, foreground demotion, turn-signal detachment, output-file and aggregate retention limits, bounded completed tombstones, and final disposal cleanup.
- `SessionShell` is one concrete owner per `AgentSession`; `bash`, `task_output`, and `kill_task` adapt it, while session events expose task invalidation without a second TUI registry.
- `packages/tui/test/interactive/complete-turn.test.ts` drives Ctrl+G through real OpenTUI input and proves the foreground task becomes session-owned background work before completing.

### P1 path and settings evidence

- `packages/coding-agent/test/paths.test.ts` fixes the `$HOME/.openzi/agent` global root, exact `<cwd>/.openzi` project root, resource paths, canonical cwd session partition, and cwd-relative custom session directories.
- `packages/coding-agent/test/settings-manager.test.ts` fixes defaults < valid global < valid project < runtime precedence, explicit malformed-scope diagnostics and recovery, write refusal for invalid data, bounded input/output, shared-file handling, and scoped locked writes that preserve unknown fields.
- `packages/tui/test/interactive/settings.test.ts` drives `/settings` completion, explicit scope selection, inherited/shadowed values, model-supported thinking levels, queue-mode persistence, nested Escape restoration, and invalid-file refusal through real OpenTUI. `packages/tui/test/interactive/prompt-store.test.ts` fixes operation/session identity independently of rendering.
- `packages/coding-agent/test/credential-store.test.ts` fixes global-only credential persistence, redacted listing, bounded input/output and provider count, no-overwrite failures, and proves the default Pi AI model registry consumes the same path-owned `auth.json`.
- `packages/coding-agent/test/runtime-paths.test.ts` proves settings and default sessions share the effective cwd, including when an explicit session header replaces the invocation cwd, and proves runtime model factories consume the exact credential owner exposed by services.
- The policy is characterized from Pi's `config.ts`, path utilities, settings manager, auth storage, resource loader, session manager, and session-service construction at the pinned commit. OpenZi retains Pi's user-wide product/agent boundary at `$HOME/.openzi/agent`; see ADR 0011.

### P1 headless-mode evidence

- `packages/coding-agent/test/print-mode.test.ts` fixes bounded sequential prompts, final-text-only output, tool/thinking omission, missing-model/provider/abort results, caller cancellation, and caller-owned session reuse without process or terminal dependencies. It also fixes header-first/source-ordered JSONL, multi-prompt continuity, Unicode framing, credential exclusion, serialization failure, and bounded writer backpressure.
- Behavior is characterized from Pi's `modes/print-mode.ts`, strict RPC JSONL helper, `test/print-mode.test.ts`, and `test/rpc-jsonl.test.ts` at the pinned commit. OpenZi deliberately injects the writer, aborts on bounded JSON output failure, and leaves signals and final disposal with the caller.
- `packages/cli/test/run.test.ts` fixes explicit/TTY mode resolution, bounded stdin-first prompt ordering, text/JSON stdout cleanliness, missing-model diagnostics, runtime/API-key/session option forwarding, dynamic TUI isolation, signal exit codes, listener cleanup, and creator-owned disposal. `packages/tui/test/interactive/run.test.ts` proves positional TTY prompts start only after terminal ownership.

### P1 conversation navigation evidence

- `packages/tui/test/interactive/transcript-store.test.ts` fixes the Nano Store-owned follow/detached/unseen transition policy, including forbidden resize and output effects.
- `packages/tui/test/interactive/transcript.test.ts` drives native line, page, wheel, resize, selection, streamed tool output, tail jumps, and stale session callbacks through a real OpenTUI renderer and `AgentSession`.
- `packages/tui/test/interactive/prompt-queue.test.ts` proves native selected text takes precedence over draft clearing and is cleared only after successful OSC 52 copy.
- Native mechanics are characterized from OpenTUI `5d57e27e`; direct scrollbox, sticky-tail, focus-aware key, and selection patterns are characterized from OpenCode `cb8be9ba1`, as pinned in `docs/reference-pins.md`.

## P2 — resource and provider parity

- [x] `AGENTS.md`/instruction discovery
- [x] Skills (core global/project resources)
- [x] Prompt templates (core global/project resources)
- [x] Images and clipboard input
- [x] OAuth provider flows
- [ ] Custom models/providers
- [ ] Session tree/branch navigation and summaries
- [ ] Export
- [ ] Shell aliases and platform-specific behavior

### P2 image and clipboard evidence

- `packages/tui/test/interactive/prompt-paste.test.ts` drives real OpenTUI bracketed paste, CR/CRLF normalization, ANSI stripping, cursor insertion, one-step undo, paste bounds, Pi-compatible large-paste markers, exact payload submission, semantic native clipboard text fallback, atomic image attachment/removal/undo, image-only submission, inline transcript labels, and image-aware exit behavior. `packages/tui/test/composer.test.ts` fixes the exact `>10 lines | >1000 characters` thresholds, 32-marker/4 MiB retained bound with full-text fallback, marker expansion, and native image deletion/undo independently of the prompt workflow.
- `packages/tui/test/interactive/clipboard.test.ts` fixes signature-based PNG/JPEG/GIF/WebP admission, MIME preference, bounded Wayland image reads, and text fallback. `packages/tui/test/interactive/prompt-store.test.ts` fixes model capability, attachment count/byte policy, cancellation, supersession, and stale-session rejection independently of rendering.
- Bracketed-paste mechanics and atomic extmarks are delegated to OpenTUI `0c8c4f7c`. Marker integration is characterized from OpenCode v2 `4678bd104`; thresholds, labels, platform fallbacks, and image limits are characterized from Pi `0e6909f0`. OpenZi keeps platform clipboard access in the terminal package and submits direct `ImageContent` rather than Pi's temporary-path insertion.

### P2 session-resource evidence

- Behavior is characterized from Pi `0e6909f0` in `core/resource-loader.ts`, `core/skills.ts`, `core/prompt-templates.ts`, `core/system-prompt.ts`, and `core/agent-session.ts`.
- `packages/coding-agent/test/resource-loader.test.ts` fixes global instructions followed by root-to-cwd `AGENTS.md`/`CLAUDE.md`, project system-prompt precedence, project-over-global skill/template collisions, canonical deduplication, recursive `SKILL.md` discovery, root skill files, skill and prompt ignore rules, non-recursive prompt discovery, invalid-resource fallback, diagnostics, and bounds.
- `packages/coding-agent/test/skills.test.ts`, `prompt-templates.test.ts`, and `session-resources.test.ts` fix progressive skill disclosure, fresh bounded explicit invocation, Pi-compatible template arguments, immutable snapshot ownership, system-prompt composition, and expansion before session admission.
- `packages/tui/test/interactive/slash-controller.test.ts` fixes mode-owned aggregation of built-ins with the current session's prompt and skill commands, including built-in precedence, session replacement, fuzzy ranking, range-safe edits, and typed activation.
- Project `.openzi` resolution is exact to the effective cwd; ancestor traversal applies only to instruction files, matching Pi's distinction between project configuration and contextual instructions.

## P3 — extension platform

- [ ] Extension discovery and trust policy
- [ ] Typed extension host boundary
- [ ] Custom tools, commands, messages, and provider hooks
- [ ] UI contributions expressed through stable imperative OpenTUI component boundaries
- [ ] Package install/update/remove
- [ ] Extension fault isolation, cancellation, and bounded IPC

## Parity method

For each capability:

1. locate the behavior and tests in the pinned `pi-coding-agent` source;
2. write a black-box OpenZi characterization test;
3. port the minimum policy behind the owning OpenZi interface;
4. render the behavior through OpenTUI using OpenZi's visual contract;
5. record intentional deviations in this document;
6. keep the upstream commit/path near the fixture when provenance matters.

## Deliberate non-parity

- The behavior of `pi-coding-agent` interactive mode is a target; Pi's screen architecture and `@earendil-works/pi-tui` are not.
- Pi's coding-agent owner boundaries are the reference; incidental helpers and framework-specific mechanics are not copied blindly.
- Below-composer selectors keep OpenZi's composer mounted as the sole focused input and render a nested picker stack beneath it; Pi's selectors may create their own search input.
- Steering and follow-up queues deliberately diverge from Pi's unbounded queues: OpenZi admits at most 32 pending entries and 8 MiB of aggregate retained UTF-8 payload, with no eviction or deduplication.
- Unbounded output, subprocesses, logs, retries, or resource discovery are rejected even if an upstream path currently permits them.
- Core skill and prompt discovery currently covers `$HOME/.openzi/agent` and exact `<cwd>/.openzi` roots. Pi package resources, settings/CLI resource paths, `.agents/skills`, and project trust arrive with their owning capabilities rather than being partially recreated inside the core loader.
- A known skill that disappears or becomes unreadable at explicit invocation rejects admission; OpenZi does not pass the stale `/skill:name` text through to the model as Pi currently does.
- A Pi extension API is not promised until OpenZi has a stable owner boundary to expose.
