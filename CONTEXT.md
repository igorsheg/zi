# OpenZi

OpenZi is an extensible local coding-agent product. Pi supplies model and agent-loop primitives, OpenZi owns coding-agent policy, and OpenTUI presents that policy as a terminal application.

## Language

**Agent core**:
The lower-level Pi agent loop that streams model output and executes tools. It is a mechanism OpenZi configures, not the OpenZi product boundary.
_Avoid_: Pi coding agent, runtime

**Agent session**:
One coding conversation and its policy: active model, prompt resources, tools, durable history, queueing, compaction, retries, and lifecycle.
_Avoid_: Chat, agent core

**Runtime services**:
The process-scoped capabilities from which agent sessions are constructed, including models, credentials, settings, filesystem/process access, and persistence.
_Avoid_: Globals, app context

**Coding-agent parity**:
Behavioral and architectural compatibility with `pi-coding-agent`, verified capability by capability while keeping the recreated layer owned by OpenZi.
_Avoid_: Source identity, dependency parity

**Interactive-mode parity**:
Behavioral compatibility with the interactive mode inside `pi-coding-agent`, including editor actions, keybindings, queues, commands, selectors, session flows, and visible lifecycle semantics. It does not include `pi-tui`, Pi's screen architecture, or Pi's visual design.
_Avoid_: Pi TUI parity, `pi-tui` parity

**Zi visual target**:
The default palette, glyphs, spacing, and overall terminal appearance. Zi does not define OpenZi interaction behavior or frontend architecture.
_Avoid_: Zi behavior parity, Zi architecture parity
