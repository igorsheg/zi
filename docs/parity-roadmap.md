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
- `packages/tui/test/interactive/visual-parity.test.ts` fixes representative normal and constrained character frames plus semantic color spans for user, thinking, Markdown, tool, and prompt presentation.
- Tool semantics are ported from `pi/packages/coding-agent/src/core/tools/` at the commit pinned in `docs/reference-pins.md`. The current display union keeps partial arguments, truncation/continuation notices, write previews, and edit diffs in coding-agent; [ADR 0014](adr/0014-tool-presentation-is-semantic-data.md) and `docs/tool-presentation-implementation-spec.md` define its accepted replacement with typed result details and semantic body primitives.
- `packages/tui/test/interactive/interactive-store.test.ts` fixes `message_update` argument streaming through preparing/ready/running/terminal states. `transcript-performance.test.ts` proves source ordering and one native tool root through argument, execution, partial-result, and committed-result phases; `tool-block.test.ts` fixes post-wrap bounds, structured bash notices, and in-place expansion. These identity and bound properties remain required through the presentation cutover; see ADR 0013.

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
- [ ] Retry policy and visible countdown
- [ ] Context usage and automatic/manual compaction
- [ ] Slash commands and file completion
- [x] Conversation scrolling, follow-tail, unseen-line hint, selection/copy
- [ ] Typed tool-result and semantic-presentation cutover, then vertical polish of all six active built-ins
- [x] Settings: global and project scope
- [x] Print and JSON modes sharing the same `AgentSession`
- [x] Authentication commands and composer-owned provider flows

Pi's optional `grep`, `find`, and `ls` implementations are deliberately deferred: its vanilla session does not enable them, and Bash already supplies their default capability. They are not part of the current built-in UX scope.

### P1 session-lifecycle evidence

- `packages/coding-agent/test/agent-session-runtime.test.ts` fixes globally serialized runtime-keyed listing, current-session no-op, new-session replacement, cross-cwd service reconstruction, pre-commit race rejection, failed-construction preservation, cancellation, and creator-owned disposal. `packages/coding-agent/test/session-manager.test.ts` fixes recent ordering, invalid-journal isolation, bounded files and previews, continue-recent, and full-load/catalog torn-tail recovery.
- `packages/tui/test/interactive/session-selector.test.ts` drives `/resume` and `/new` through the real composer-owned picker, verifies whole-session rebinding, read-only browsing during a run, replacement refusal until idle, current-session no-op, transcript replacement, focus preservation, invalid counts, and old-session disposal. `packages/tui/test/interactive/prompt-store.test.ts` keeps cancellation explicit until runtime settlement. `packages/cli/test/args.test.ts` distinguishes strict `--resume` from `--continue` and rejects the removed `--session` spelling.
- `AgentSessionRuntime` follows Pi's replacement boundary in `core/agent-session-runtime.ts`, while target-before-invalidation and bounded listing deliberately preserve OpenZi's failure and resource policy. Grok Build's pinned session startup, storage, and picker code supplies secondary torn-write, stale-load, cross-cwd, and catalog-scale failure cases; see ADR 0012.

### P1 model-selection evidence

- `packages/coding-agent/test/model-selection.test.ts` covers registry-order choices, provider-scoped authentication, bounded catalog work, canonical thinking capabilities, coherent persistence/events, admission, and model-validation races.
- `packages/coding-agent/test/model-onboarding.test.ts` fixes explicit unselected startup, prompt guidance, first authenticated selection, settings/session persistence, and unavailable-model resume without history mutation. `packages/tui/test/interactive/model-onboarding.test.ts` proves the real terminal renders that state before `/login` exists.
- `packages/tui/test/interactive/model-selector.test.ts` drives slash completion, exact and fuzzy `/model` paths, configured-provider filtering, Pi ordering, wrapped navigation, cancellation, mutation failure, stale completion, session replacement, persistent composer focus, and nested parent-filter restoration through real OpenTUI input and `AgentSession`.
- `packages/tui/test/interactive/picker-stack.test.ts` fixes top-frame filtering, wrapped selection, nested push/pop, and suspended parent-filter restoration without an input renderable.
- `packages/coding-agent/test/slash-commands.test.ts` fixes coding-agent ownership of supported built-in command descriptors.
- Mode-owned `InteractiveCommands` assembles completion and parses invocation text into closed intents. Mode-owned `InteractiveKeybindings` resolves effective terminal actions without containing callbacks. `PromptStore` owns typed workflows and operation identity. `PickerStack` owns nested choice mechanics, while `PickerStackView` renders below the composer without creating another input. `PromptView`, `Composer`, `PickerStackView`, and `PickerList` contain no supported command names, argument rules, or dispatch policy.
- Command catalog composition, terminal parsing, exact reference matching, fuzzy search, sorting, and selector keys are characterized from Pi's `interactive-mode.ts`, `model-selector.ts`, `model-search.ts`, `model-resolver.ts`, and `pi-tui` fuzzy/editor implementation at the pinned commit.

### P1 authentication evidence

- `packages/coding-agent/test/authentication.test.ts` fixes provider-derived API-key/OAuth methods, generic text/secret/select/manual-code prompts, browser/device events, interaction bounds, locked persistence, Pi AI-owned refresh, ambient auth after logout, stale completion rejection, and session-level cancellation/model gating.
- `packages/coding-agent/test/runtime-api-key.test.ts` and `packages/cli/test/args.test.ts` fix `--api-key` parsing, required model-provider inference, request-option precedence, model availability, unchanged stored credentials, no auth-file creation, and loss of the override in a fresh runtime.
- `Authentication` invokes the installed Pi AI provider contracts and persists through the runtime credential owner; provider protocols and OAuth refresh remain below that boundary. `AgentSession` gates this owner against runs and model mutations and chooses the provider's first known model after login when currently unselected.
- `packages/tui/test/interactive/authentication.test.ts` drives slash completion, exact provider routing, nested provider/method filters, multi-prompt hidden API-key entry, OAuth URL/device/select/manual-code/progress presentation, OSC 8-safe links, Escape cancellation, stale session replacement, first-model title updates, and stored-only logout through real OpenTUI input.

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
- [ ] Images and clipboard input
- [x] OAuth provider flows
- [ ] Custom models/providers
- [ ] Session tree/branch navigation and summaries
- [ ] Export
- [ ] Shell aliases and platform-specific behavior

### P2 session-resource evidence

- Behavior is characterized from Pi `0e6909f0` in `core/resource-loader.ts`, `core/skills.ts`, `core/prompt-templates.ts`, `core/system-prompt.ts`, and `core/agent-session.ts`.
- `packages/coding-agent/test/resource-loader.test.ts` fixes global instructions followed by root-to-cwd `AGENTS.md`/`CLAUDE.md`, project system-prompt precedence, project-over-global skill/template collisions, canonical deduplication, recursive `SKILL.md` discovery, root skill files, skill and prompt ignore rules, non-recursive prompt discovery, invalid-resource fallback, diagnostics, and bounds.
- `packages/coding-agent/test/skills.test.ts`, `prompt-templates.test.ts`, and `session-resources.test.ts` fix progressive skill disclosure, fresh bounded explicit invocation, Pi-compatible template arguments, immutable snapshot ownership, system-prompt composition, and expansion before session admission.
- `packages/tui/test/interactive/interactive-commands.test.ts` fixes mode-owned aggregation of built-ins with the current session's prompt and skill commands, including built-in precedence and session replacement.
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
