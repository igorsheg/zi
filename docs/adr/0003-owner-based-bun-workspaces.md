# Use owner-based Bun workspaces

> Amended by [ADR 0007](0007-terminal-interactive-mode-over-agent-session.md).

OpenZi has three workspaces: `coding-agent` owns `AgentSession`, coding-agent policy, managers, tools, and non-terminal modes; `tui` owns the terminal-specific interactive mode; `cli` owns argument parsing, runtime construction, mode selection, and exit reporting.

```text
cli -> tui -> coding-agent
cli -> coding-agent
```

Shared coding-agent policy belongs in `AgentSession` or a concrete manager. Terminal behavior and native interaction state belong in `tui`. Print/RPC modes may live in `coding-agent` because they are direct non-frontend adapters over the session/runtime boundary. This avoids a speculative universal mode facade as well as vague `shared`, `common`, or `core` packages.
