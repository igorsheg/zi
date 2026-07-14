# Pi coding-agent parity roadmap

The target is coding-agent architecture parity and observable product-behavior parity, including Pi's interactive mode, without source identity. Each item is complete only with an OpenZi-owned acceptance test.

## P0 — one dependable turn

- [x] Explicit provider registration and environment/API-key auth
- [x] Model resolution and clear no-model diagnostics
- [x] System prompt with cwd and project instructions
- [x] `read`, `bash`, `edit`, and `write`
- [x] Streaming assistant text and thinking
- [x] Streaming tool lifecycle and bounded output
- [x] Cancellation and settled shutdown
- [x] Append-only JSONL session with restore
- [x] Zi-matched session screen and prompt appearance
- [x] Faux-provider integration and OpenTUI frame snapshots

### P0 evidence

- `packages/coding-agent/test/complete-turn.test.ts` drives the real Pi agent loop through `write`, `read`, `edit`, and `bash`, then restores JSONL.
- `packages/tui/test/complete-turn.test.tsx` submits through OpenTUI's `TextareaRenderable` and captures the resulting frame.
- `packages/tui/test/visual-parity.test.tsx` fixes representative normal and constrained character frames plus semantic color spans for user, thinking, Markdown, tool, and prompt presentation.
- Tool semantics are ported from `pi/packages/coding-agent/src/core/tools/` at the commit pinned in `docs/reference-pins.md`.

## P1 — daily-driver session behavior

- [ ] Model and thinking-level picker
- [ ] Session create/resume/list/switch
- [x] Steering and follow-up with bounded queues
- [ ] Retry policy and visible countdown
- [ ] Context usage and automatic/manual compaction
- [ ] Slash commands and file completion
- [x] Conversation scrolling, follow-tail, unseen-line hint, selection/copy
- [ ] `grep`, `find`, and `ls`
- [ ] Settings: global and project scope
- [ ] Print and JSON modes sharing the same `AgentSession`

### P1 steering and follow-up evidence

- `packages/coding-agent/test/agent-session-queue.test.ts` covers delivery priority, queue modes, tool-batch timing, identity, bounds, dequeue, cancellation, continuation, and activity transitions through `AgentSession`.
- `packages/tui/test/prompt-queue.test.tsx` drives Return, Alt+Enter, Alt+Up, Escape, and Ctrl+C through real OpenTUI input and asserts queue rows, restoration, overflow, and cell-aware truncation.
- Behavior is characterized from `packages/agent/src/agent.ts`, `packages/agent/src/agent-loop.ts`, `packages/coding-agent/src/core/agent-session.ts`, and `packages/coding-agent/src/modes/interactive/interactive-mode.ts` at the Pi commit pinned in `docs/reference-pins.md`.
- Non-aborting dequeue prevents delivery while an entry remains in the core queue. `pi-agent-core` exposes no claim callback, so an entry already drained by the core before its `message_start` may still arrive; acceptance tests fix both clear-before-commit and commit-before-clear behavior at that dependency boundary.

### P1 conversation navigation evidence

- `packages/tui/test/transcript-navigation.test.ts` fixes the closed follow/detached/unseen transition policy, including forbidden resize and output effects.
- `packages/tui/test/transcript.test.tsx` drives native line, page, wheel, resize, selection, streamed tool output, tail jumps, and stale session callbacks through a real OpenTUI renderer and `AgentSession`.
- `packages/tui/test/prompt-queue.test.tsx` proves native selected text takes precedence over draft clearing and is cleared only after successful OSC 52 copy.
- Native mechanics are characterized from OpenTUI `5d57e27e`; direct scrollbox, sticky-tail, focus-aware key, and selection patterns are characterized from OpenCode `cb8be9ba1`, as pinned in `docs/reference-pins.md`.

## P2 — resource and provider parity

- [ ] `AGENTS.md`/instruction discovery
- [ ] Skills
- [ ] Prompt templates
- [ ] Images and clipboard input
- [ ] OAuth provider flows
- [ ] Custom models/providers
- [ ] Session tree/branch navigation and summaries
- [ ] Export
- [ ] Shell aliases and platform-specific behavior

## P3 — extension platform

- [ ] Extension discovery and trust policy
- [ ] Typed extension host boundary
- [ ] Custom tools, commands, messages, and provider hooks
- [ ] UI contributions expressed through stable OpenTUI React component boundaries
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
- Zi is not a behavior reference. It supplies visual styling only.
- Steering and follow-up queues deliberately diverge from Pi's unbounded queues: OpenZi admits at most 32 pending entries and 8 MiB of aggregate retained UTF-8 payload, with no eviction or deduplication.
- Unbounded output, subprocesses, logs, or retries are rejected even if an upstream path currently permits them.
- A Pi extension API is not promised until OpenZi has a stable owner boundary to expose.
