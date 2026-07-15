# OpenZi

A coding agent built from Pi's lower-level AI/agent packages with an imperative OpenTUI frontend.

## Direction

- [`pi-coding-agent`](https://github.com/earendil-works/pi/tree/main/packages/coding-agent) is the **behavior and coding-agent architecture** parity target; its interactive mode defines TUI product behavior.
- OpenZi uses `@earendil-works/pi-ai` and `@earendil-works/pi-agent-core`, not `pi-coding-agent` or `pi-tui`.
- [`@opentui/core`](https://github.com/anomalyco/opentui) renderables are the terminal architecture; React is not part of the runtime.
- [OpenCode](https://github.com/anomalyco/opencode) is a source of proven OpenTUI organization patterns.

## Workspaces

- `packages/coding-agent` — `AgentSession`, managers, tools, non-terminal modes, and Pi parity
- `packages/tui` — the terminal-specific interactive mode and imperative OpenTUI components
- `packages/cli` — argument parsing, dynamic mode selection, and exit reporting

See [`docs/architecture.md`](docs/architecture.md), [`docs/tui-architecture.md`](docs/tui-architecture.md), [`docs/parity-roadmap.md`](docs/parity-roadmap.md), and [`AGENTS.md`](AGENTS.md).

## Configuration paths

OpenZi keeps global state directly in `$HOME/.openzi` and project-scoped configuration in the effective working directory's `.openzi/`:

```text
$HOME/.openzi/{settings.json,auth.json,sessions/,AGENTS.md,SYSTEM.md,...}
<cwd>/.openzi/{settings.json,SYSTEM.md,APPEND_SYSTEM.md,...}
```

Global settings are overlaid by project settings and then runtime overrides. Authentication and default sessions remain global; sessions are partitioned by canonical cwd. Resuming a session rebuilds cwd-bound services from the cwd stored in its header. See [ADR 0011](docs/adr/0011-openzi-path-policy.md).

A fresh terminal can start without credentials; use `/login`, then `/model` if needed. `/logout` removes only stored credentials, not environment or external provider configuration. For a one-process override, use `openzi --model provider/model-id --api-key "$KEY"`; the key is applied in memory and is never written to settings or `auth.json`.

## Development

Requires Bun 1.3.5. Installing dependencies also installs the Lefthook Git hooks.

```sh
bun install
bun run start         # run OpenZi
bun run fix           # apply Oxlint fixes, then format with Oxfmt
bun run check         # formatting, linting, TypeScript, and tests
```

The workspace uses TypeScript 7, type-aware Oxlint, and Oxfmt. Lefthook formats and lints staged files before commits and runs the complete check before pushes.

Stateful behavior is designed as explicit domain data with one owner and explicit transitions. TUI presentation state uses instance-scoped Nano Store owners rather than module globals or mirrored session state. Interruption, terminal shutdown, and caller-owned disposal are separate transitions; see [`docs/architecture.md`](docs/architecture.md), [ADR 0004](docs/adr/0004-explicit-state-and-transitions.md), [ADR 0006](docs/adr/0006-instance-scoped-nano-stores-own-tui-state.md), [ADR 0009](docs/adr/0009-interruption-and-terminal-shutdown.md), [ADR 0010](docs/adr/0010-interactive-mode-owns-keybindings.md), and [ADR 0011](docs/adr/0011-openzi-path-policy.md).

The interactive path now resolves configured Pi providers, runs `read`/`bash`/`edit`/`write` through `AgentSession`, streams into imperative OpenTUI renderables, and persists resumable JSONL sessions. P0 visual acceptance and the remaining Pi coding-agent capabilities are tracked in `docs/parity-roadmap.md`.
