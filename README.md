# Zi

A coding agent built from Pi's lower-level AI/agent packages with an imperative OpenTUI frontend.

## Direction

- [`pi-coding-agent`](https://github.com/earendil-works/pi/tree/main/packages/coding-agent) is the **behavior and coding-agent architecture** parity target; its interactive mode defines TUI product behavior.
- Zi uses `@earendil-works/pi-ai` and `@earendil-works/pi-agent-core`, not `pi-coding-agent` or `pi-tui`.
- [`@opentui/core`](https://github.com/anomalyco/opentui) renderables are the terminal architecture; React is not part of the runtime.
- [OpenCode](https://github.com/anomalyco/opencode) is a source of proven OpenTUI organization patterns.

## Workspaces

- `packages/coding-agent` — `AgentSession`, managers, tools, non-terminal modes, and Pi parity
- `packages/tui` — the terminal-specific interactive mode and imperative OpenTUI components
- `packages/cli` — argument parsing, dynamic mode selection, and exit reporting

See [`docs/architecture.md`](docs/architecture.md), [`docs/tui-architecture.md`](docs/tui-architecture.md), [`docs/parity-roadmap.md`](docs/parity-roadmap.md), and [`AGENTS.md`](AGENTS.md).

## Install

```sh
npm install -g @with-zi/zi
zi --version
```

Update with the normal global npm update path:

```sh
npm update -g @with-zi/zi
```

## Configuration paths

Zi keeps coding-agent global state in `$HOME/.zi/agent` and project-scoped configuration in the effective working directory's `.zi/`:

```text
$HOME/.zi/agent/{settings.json,auth.json,sessions/,AGENTS.md,SYSTEM.md,...}
<cwd>/.zi/{settings.json,SYSTEM.md,APPEND_SYSTEM.md,...}
```

Global settings are overlaid by project settings and then runtime overrides. Authentication and default sessions remain global; sessions are partitioned by canonical cwd. Resuming a session rebuilds cwd-bound services from the cwd stored in its header. See [ADR 0011](docs/adr/0011-zi-path-policy.md).

Dogfood builds named OpenZi used `$HOME/.openzi/agent` and `<cwd>/.openzi`. Zi does not auto-move those files. To copy them without overwriting existing Zi state:

```sh
if [ -d "$HOME/.openzi/agent" ] && [ ! -e "$HOME/.zi/agent" ]; then
  mkdir -p "$HOME/.zi"
  cp -a "$HOME/.openzi/agent" "$HOME/.zi/agent"
fi

if [ -d .openzi ] && [ ! -e .zi ]; then
  cp -a .openzi .zi
fi
```

A fresh terminal can start without credentials; use `/login`, then `/model` if needed. `/logout` removes only stored credentials, not environment or external provider configuration. `/settings` edits thinking, queues, automatic compaction, and automatic retry with an explicit global or project scope. Transient model failures retry after 2, 4, and 8 seconds by default; the visible countdown can be cancelled with the active interrupt binding. `/new` starts a fresh session and `/resume` opens the bounded current-project session picker. For a one-process override, use `zi --model provider/model-id --api-key "$KEY"`; the key is applied in memory and is never written to settings or `auth.json`.

## CLI modes

```sh
zi                                      # interactive TUI on a TTY
zi -p "Summarize this project"          # final assistant text
zi --mode text "First" "Then summarize"
printf 'Summarize stdin' | zi            # non-TTY input selects text mode
zi --mode json "Inspect the project"    # strict JSONL events
```

Piped stdin is the first prompt and positional prompts follow in argument order. Text diagnostics use stderr; JSON stdout contains only JSONL records. `--resume <file>` strictly opens an existing journal, while `--continue` reuses the newest current-cwd journal or creates one. `--model`, memory-only `--api-key`, and `--no-session` apply to interactive and headless modes. RPC is deliberately not available yet.

## SDK

`@with-zi/coding-agent` can run without the CLI or TUI. `createAgentRuntime()` is the high-level constructor: it resolves one cwd, assembles path-owned services, and returns a frozen `{ session, services }` shell. The caller that creates the runtime always owns final session disposal.

```ts
import { createAgentRuntime } from "@with-zi/coding-agent"

const runtime = await createAgentRuntime({ cwd: process.cwd() }) // persistent session by default
try {
  if (runtime.session.modelState.type === "unselected") throw new Error("Select an authenticated model first")
  await runtime.session.prompt("Summarize this project")
  await runtime.session.waitForIdle()
} finally {
  runtime.session.dispose()
}
```

Set `persist: false` for an in-memory transcript. Supplying `agentDir` makes global configuration ownership explicit instead of deriving it from `$HOME`:

```ts
const runtime = await createAgentRuntime({
  cwd: "/workspace/project",
  agentDir: "/workspace/zi-config",
  persist: false
})
```

Production custom providers enter through the credential-aware model factory, so provider requests, OAuth refresh, login, and logout retain one credential owner:

```ts
const runtime = await createAgentRuntime({
  cwd: process.cwd(),
  modelFactory: credentials => createMyModels({ credentials })
})
```

For a client that supports whole-session `/new` and `/resume`, use `createAgentSessionRuntime(options)`. It exposes the current session and services, reconstructs every cwd-bound owner when switching, and owns disposal of replaced sessions. Its creator owns final `runtime.dispose()` followed by `runtime.waitForIdle()`.

For full assembly control, `createAgentSession({ services, sessionManager, model, tools })` is the lower-level constructor. It consumes caller-owned `ZiPaths`, `SettingsManager`, `FileCredentialStore`, `ModelRegistry`, `ResourceLoader`, and `SessionManager`; it does not construct or dispose them. Raw `Models` injection is test-only under `@with-zi/coding-agent/testing`.

Text batch execution reuses the same caller-owned session and does not access process streams or signals:

```ts
import { runPrintMode } from "@with-zi/coding-agent"

const result = await runPrintMode(runtime.session, {
  output: "text",
  prompts: ["Inspect the project", "Summarize the result"],
  writer: { write: chunk => process.stdout.write(chunk) }
})
```

The writer is awaited for backpressure. Set `output: "json"` to emit a header-first, source-ordered JSONL event stream instead of final text. JSON records, pending bytes, and pending writes are bounded. The caller maps the closed result to stderr/exit policy and still owns `runtime.session.dispose()`.

## Shipping

End-user releases are native standalone executables built with the pinned Bun version on each target platform. Pull requests and `main` run the complete check; SemVer `v*.*.*` tags build, smoke-test, checksum, attest, and publish macOS arm64/x64, Linux arm64/x64, and Windows x64 archives. See [`docs/shipping.md`](docs/shipping.md) and [`docs/release-packaging.md`](docs/release-packaging.md).

The embeddable packages remain a separate distribution boundary and will publish as transpiled ESM plus declarations rather than executable bundles.

## Development

Requires Bun 1.3.14. Installing dependencies also installs the Lefthook Git hooks.

```sh
bun install
bun run start         # run Zi directly from TypeScript
bun run build         # compile the local production executable to dist/zi
bun run fix           # apply Oxlint fixes, then format with Oxfmt
bun run check         # formatting, linting, TypeScript, and tests
```

The workspace uses TypeScript 7, type-aware Oxlint, and Oxfmt. Lefthook formats and lints staged files before commits and runs the complete check before pushes.

Stateful behavior is designed as explicit domain data with one owner and explicit transitions. TUI presentation state uses instance-scoped Nano Store owners rather than module globals or mirrored session state. Interruption, terminal shutdown, and caller-owned disposal are separate transitions; see [`docs/architecture.md`](docs/architecture.md), [ADR 0004](docs/adr/0004-explicit-state-and-transitions.md), [ADR 0006](docs/adr/0006-instance-scoped-nano-stores-own-tui-state.md), [ADR 0009](docs/adr/0009-interruption-and-terminal-shutdown.md), [ADR 0010](docs/adr/0010-interactive-mode-owns-keybindings.md), [ADR 0011](docs/adr/0011-zi-path-policy.md), [ADR 0012](docs/adr/0012-agent-session-runtime-owns-replacement.md), and [ADR 0017](docs/adr/0017-retry-failures-remain-durable-but-leave-provider-context.md).

The interactive path now resolves configured Pi providers, runs `read`/`bash`/`edit`/`write` through `AgentSession`, owns bounded foreground and background shell tasks for the session, streams into imperative OpenTUI renderables, and persists resumable JSONL sessions. Bash can start background work explicitly, `task_output` and `kill_task` operate on the same task owner, and Ctrl+G demotes the active foreground shell task. P0 visual acceptance and the remaining Pi coding-agent capabilities are tracked in `docs/parity-roadmap.md`.
