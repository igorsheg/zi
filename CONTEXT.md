# OpenZi

OpenZi is an extensible local coding-agent product. Pi supplies model and agent-loop primitives, OpenZi owns coding-agent policy, and OpenTUI presents that policy as a terminal application.

## Language

**Agent core**:
The lower-level Pi agent loop that streams model output and executes tools. It is a mechanism OpenZi configures, not the OpenZi product boundary.
_Avoid_: Pi coding agent, runtime

**Agent session**:
One coding conversation and its policy: active model, prompt resources, tools, durable history, queueing, compaction, retries, and lifecycle.
_Avoid_: Chat, agent core

**Run interruption**:
A request to stop active provider/tool work while keeping the `AgentSession` reusable. Escape cancellation returns pending queued input to the composer; lower-level interruption may preserve admitted queue work. Neither operation owns terminal teardown.
_Avoid_: Quit, shutdown, dispose

**Terminal shutdown**:
The terminal-run transition that stops input, discards queued work, signals active cancellation, restores OpenTUI immediately, and then awaits bounded settlement. The CLI remains responsible for final session disposal and exit reporting.
_Avoid_: Abort, component unmount, session disposal

**Runtime services**:
The process-scoped capabilities from which agent sessions are constructed, including models, credentials, settings, filesystem/process access, and persistence.
_Avoid_: Globals, app context

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
