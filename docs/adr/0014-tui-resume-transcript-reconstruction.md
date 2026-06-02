# adr 0014: reconstruct tui transcript from session history on resume

## status

accepted

## context

Zi's session history is the durable truth for a coding-agent session. The TUI
transcript is a bounded product view over that truth, not the source of truth.

Interactive TUI mode can create a fresh session or resume an existing one. A
resumed TUI that starts with an empty transcript violates the user's model of a
session: the session exists, but the visible product state does not reflect it.

At the same time, the TUI product behavior is still intentionally small and will
change. Zi has not committed to rich transcript blocks, markdown rendering, tool
collapse behavior, scroll restoration, or a component/widget API. Resume
reconstruction must therefore encode the stable boundary, not freeze future UI
behavior.

## decision

When interactive TUI mode resumes or creates a host with existing durable
history, the TUI must be seeded from a coding-agent-owned public history
snapshot before the first user-facing frame.

The data path is:

```text
session durable history
  -> coding_agent public/owned history snapshot
  -> src/coding_agent/interactive.zig adapter
  -> tui product commands
  -> src/tui/product/transcript.zig bounded resident transcript
  -> product frame projection
```

`src/tui` must not read session files, import `coding_agent`, inspect
`agent.Agent`, or depend on provider/session internals. TUI receives only product
commands such as transcript appends.

The first reconstruction format is deliberately lossy and boring:

```text
role: user | assistant | system
text: utf8 bytes
```

Tool calls, tool results, markdown structure, thinking blocks, custom items,
scroll position, and rich per-message metadata may be added later through the
same boundary when their product behavior is decided.

## invariants

- Session history is durable truth; TUI transcript is bounded display state.
- Resume reconstruction happens before the first TUI frame is rendered.
- `src/coding_agent` owns mapping session/history events into TUI commands.
- `src/tui` never imports session, provider, persistence, tool, `agent`, or
  `coding_agent` policy.
- Reconstruction uses the same TUI mutation path as live events: product
  commands applied by TUI owners.
- Reconstruction work and resident TUI memory are bounded. If durable history is
  larger than the resident transcript bounds, the TUI keeps the newest bounded
  tail and may indicate truncation later.
- Future rich transcript behavior must extend the snapshot/command boundary; it
  must not move persistence or session policy into `src/tui`.

## consequences

This lets Zi implement resume correctness without deciding the final transcript
UX. The current TUI may display only plain user/assistant/system text, while the
coding-agent session remains the source for richer reconstruction later.

It also keeps the failure mode obvious: if reconstruction fails, the
coding-agent integration can report a system/status transcript entry or fail
interactive startup. The TUI itself does not silently invent session state.

## rejected

### Let `src/tui` read session jsonl directly

Rejected. That would put persistence/session policy inside the TUI and couple
future UI behavior to durable storage format.

### Rebuild a rich transcript model now

Rejected. Tool blocks, markdown, thinking, custom transcript items, and scroll
restoration are product decisions that have not paid rent yet.

### Treat live public events as enough for resume

Rejected. Public event queues describe live progress. A resumed process needs an
owned snapshot of durable history before rendering.

### Keep resumed TUI empty until new events arrive

Rejected. This violates session continuity and makes resume look like data loss.
