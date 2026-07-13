# OpenZi

A coding agent built from Pi's lower-level AI/agent packages with an OpenTUI React frontend.

## Direction

- [`pi-coding-agent`](https://github.com/earendil-works/pi/tree/main/packages/coding-agent) is the **behavior and coding-agent architecture** parity target.
- OpenZi uses `@earendil-works/pi-ai` and `@earendil-works/pi-agent-core`, not `pi-coding-agent` or `pi-tui`.
- [OpenTUI React](https://github.com/anomalyco/opentui) is the frontend architecture.
- [Zi](https://github.com/igorsheg/zi) is the visual and interaction reference only.
- [OpenCode](https://github.com/anomalyco/opencode) is a source of proven OpenTUI organization patterns.

## Workspaces

- `packages/coding-agent` — session policy, managers, resources, tools, and Pi parity
- `packages/tui` — OpenTUI React screens, prompt, message rendering, and overlays
- `packages/cli` — entrypoint and future interactive/print/RPC mode composition

See [`docs/architecture.md`](docs/architecture.md), [`docs/parity-roadmap.md`](docs/parity-roadmap.md), and [`AGENTS.md`](AGENTS.md).

## Development

Requires Bun 1.3+.

```sh
bun install
bun run check
bun run start
```

The current executable renders the initial OpenTUI shell. Provider and tool wiring is the next vertical slice.
