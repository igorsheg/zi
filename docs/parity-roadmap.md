# Pi coding-agent parity roadmap

The target is coding-agent architecture parity and observable product-behavior parity, including Pi's interactive mode, without source identity. Each item is complete only with an OpenZi-owned acceptance test.

## P0 — one dependable turn

- [x] Explicit provider registration and environment/API-key auth
- [x] Model resolution and clear no-model diagnostics
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
- Tool semantics are ported from `pi/packages/coding-agent/src/core/tools/` at the commit pinned in `docs/reference-pins.md`.

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
- [ ] Thinking-level picker
- [ ] Session create/resume/list/switch
- [x] Steering and follow-up with bounded queues
- [ ] Retry policy and visible countdown
- [ ] Context usage and automatic/manual compaction
- [ ] Slash commands and file completion
- [x] Conversation scrolling, follow-tail, unseen-line hint, selection/copy
- [ ] `grep`, `find`, and `ls`
- [x] Settings: global and project scope
- [ ] Print and JSON modes sharing the same `AgentSession`

### P1 model-selection evidence

- `packages/coding-agent/test/model-selection.test.ts` covers registry-order choices, provider-scoped authentication, bounded catalog work, canonical thinking capabilities, coherent persistence/events, admission, and model-validation races.
- `packages/tui/test/interactive/model-selector.test.ts` drives slash completion, exact and fuzzy `/model` paths, configured-provider filtering, Pi ordering, wrapped navigation, cancellation, mutation failure, stale completion, session replacement, persistent composer focus, and nested parent-filter restoration through real OpenTUI input and `AgentSession`.
- `packages/tui/test/interactive/picker-stack.test.ts` fixes top-frame filtering, wrapped selection, nested push/pop, and suspended parent-filter restoration without an input renderable.
- `packages/coding-agent/test/slash-commands.test.ts` fixes coding-agent ownership of supported built-in command descriptors.
- Mode-owned `InteractiveCommands` assembles completion and parses invocation text into closed intents. Mode-owned `InteractiveKeybindings` resolves effective terminal actions without containing callbacks. `PromptStore` owns typed workflows and operation identity. `PickerStack` owns nested choice mechanics, while `PickerStackView` renders below the composer without creating another input. `PromptView`, `Composer`, `PickerStackView`, and `PickerList` contain no supported command names, argument rules, or dispatch policy.
- Command catalog composition, terminal parsing, exact reference matching, fuzzy search, sorting, and selector keys are characterized from Pi's `interactive-mode.ts`, `model-selector.ts`, `model-search.ts`, `model-resolver.ts`, and `pi-tui` fuzzy/editor implementation at the pinned commit.

### P1 steering and follow-up evidence

- `packages/coding-agent/test/agent-session-queue.test.ts` covers delivery priority, queue modes, tool-batch timing, identity, bounds, dequeue, cancellation, continuation, and activity transitions through `AgentSession`.
- `packages/tui/test/interactive/prompt-queue.test.ts` drives Return, Alt+Enter, Alt+Up, Escape, and Ctrl+C through real OpenTUI input and asserts queue rows, restoration, overflow, and cell-aware truncation.
- Behavior is characterized from `packages/agent/src/agent.ts`, `packages/agent/src/agent-loop.ts`, `packages/coding-agent/src/core/agent-session.ts`, and `packages/coding-agent/src/modes/interactive/interactive-mode.ts` at the Pi commit pinned in `docs/reference-pins.md`.
- Non-aborting dequeue prevents delivery while an entry remains in the core queue. `pi-agent-core` exposes no claim callback, so an entry already drained by the core before its `message_start` may still arrive; acceptance tests fix both clear-before-commit and commit-before-clear behavior at that dependency boundary.

### P1 path and settings evidence

- `packages/coding-agent/test/paths.test.ts` fixes the `$HOME/.openzi` global root, exact `<cwd>/.openzi` project root, resource paths, canonical cwd session partition, and cwd-relative custom session directories.
- `packages/coding-agent/test/settings-manager.test.ts` fixes defaults < global < project < runtime precedence plus scoped locked writes that preserve unknown fields.
- `packages/coding-agent/test/credential-store.test.ts` fixes global-only credential persistence and proves the default Pi AI model registry consumes the same path-owned `auth.json`.
- `packages/coding-agent/test/runtime-paths.test.ts` proves settings and default sessions share the effective cwd, including when an explicit session header replaces the invocation cwd.
- The policy is characterized from Pi's `config.ts`, path utilities, settings manager, auth storage, resource loader, session manager, and session-service construction at the pinned commit. OpenZi deliberately maps the global root directly to `$HOME/.openzi` rather than retaining Pi's additional `agent/` segment; see ADR 0011.

### P1 conversation navigation evidence

- `packages/tui/test/interactive/transcript-store.test.ts` fixes the Nano Store-owned follow/detached/unseen transition policy, including forbidden resize and output effects.
- `packages/tui/test/interactive/transcript.test.ts` drives native line, page, wheel, resize, selection, streamed tool output, tail jumps, and stale session callbacks through a real OpenTUI renderer and `AgentSession`.
- `packages/tui/test/interactive/prompt-queue.test.ts` proves native selected text takes precedence over draft clearing and is cleared only after successful OSC 52 copy.
- Native mechanics are characterized from OpenTUI `5d57e27e`; direct scrollbox, sticky-tail, focus-aware key, and selection patterns are characterized from OpenCode `cb8be9ba1`, as pinned in `docs/reference-pins.md`.

## P2 — resource and provider parity

- [x] `AGENTS.md`/instruction discovery
- [ ] Skills
- [ ] Prompt templates
- [ ] Images and clipboard input
- [ ] OAuth provider flows
- [ ] Custom models/providers
- [ ] Session tree/branch navigation and summaries
- [ ] Export
- [ ] Shell aliases and platform-specific behavior

### P2 instruction-discovery evidence

- `packages/coding-agent/test/resource-loader.test.ts` fixes global instructions followed by root-to-cwd `AGENTS.md`/`CLAUDE.md`, plus project `.openzi/SYSTEM.md` and `.openzi/APPEND_SYSTEM.md` precedence over global files.
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
- Unbounded output, subprocesses, logs, or retries are rejected even if an upstream path currently permits them.
- A Pi extension API is not promised until OpenZi has a stable owner boundary to expose.
