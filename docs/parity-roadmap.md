# Pi coding-agent parity roadmap

The target is behavioral and coding-agent architecture parity, without source identity. Each item is complete only with an OpenZi-owned acceptance test.

## P0 — one dependable turn

- [ ] Explicit provider registration and environment/API-key auth
- [ ] Model resolution and clear no-model diagnostics
- [ ] System prompt with cwd and project instructions
- [ ] `read`, `bash`, `edit`, and `write`
- [ ] Streaming assistant text and thinking
- [ ] Streaming tool lifecycle and bounded output
- [ ] Cancellation and settled shutdown
- [ ] Append-only JSONL session with restore
- [ ] Zi-matched session screen and prompt appearance
- [ ] Faux-provider integration and OpenTUI frame snapshots

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
4. adapt presentation to the Zi/OpenTUI contract;
5. record intentional deviations in this document;
6. keep the upstream commit/path near the fixture when provenance matters.

## Deliberate non-parity

- Pi's TUI implementation and `@earendil-works/pi-tui` are never a target.
- Pi's coding-agent owner boundaries are the reference; incidental helpers and framework-specific mechanics are not copied blindly.
- Unbounded queues, output, subprocesses, logs, or retries are rejected even if an upstream path currently permits them.
- A Pi extension API is not promised until OpenZi has a stable owner boundary to expose.
