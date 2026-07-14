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
- [ ] Steering and follow-up with bounded queues
- [ ] Retry policy and visible countdown
- [ ] Context usage and automatic/manual compaction
- [ ] Slash commands and file completion
- [ ] Conversation scrolling, follow-tail, unseen-line hint, selection/copy
- [ ] `grep`, `find`, and `ls`
- [ ] Settings: global and project scope
- [ ] Print and JSON modes sharing the same `AgentSession`

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
- Unbounded queues, output, subprocesses, logs, or retries are rejected even if an upstream path currently permits them.
- A Pi extension API is not promised until OpenZi has a stable owner boundary to expose.
