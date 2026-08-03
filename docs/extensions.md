---
slug: extensions
title: Extend Zi
order: 70
---

# Extensions

Zi extensions are trusted TypeScript modules that add repository-specific behavior without changing Zi. The supported public surface consists of lifecycle and agent-activity handlers, user-invoked commands, model-callable tools, bounded durable session operations, and optional subagent profiles and operations.

## Trust and authority

Project extensions are loaded only after the project `.zi` directory is trusted. Interactive mode asks; text, JSON, and RPC modes never prompt and exclude unresolved project configuration. Global and explicit extensions are already user-admitted configuration.

Extensions run as the current user. They can read files and environment variables, access credentials, and spawn processes. The worker process contains crashes and hangs; it is not a security sandbox or credential boundary. Review extension code before trusting it.

## Locations

Zi discovers entry points in deterministic order:

1. repeated `--extension <path>` arguments;
2. `<cwd>/.zi/extensions/`, when trusted;
3. `$HOME/.zi/agent/extensions/`.

A directory entry may use `index.ts`; a direct `.ts` file also works. TypeScript and relative imports load without a build. Install third-party dependencies in the extension's own package hierarchy so normal bare-module resolution can find them.

Start with [`examples/extensions/custom-tool/index.ts`](../examples/extensions/custom-tool/index.ts). For a dormant catalog, see [`examples/extensions/deferred-tools/index.ts`](../examples/extensions/deferred-tools/index.ts). For session persistence and custom messages, see [`examples/extensions/durable-counter/index.ts`](../examples/extensions/durable-counter/index.ts). For programmatic subagent profiles, see [`examples/extensions/subagents/index.ts`](../examples/extensions/subagents/index.ts). For an observational terminal integration, see [`examples/extensions/herdr-agent-state/index.ts`](../examples/extensions/herdr-agent-state/index.ts).

## Public API

Import only `@with-zi/extension-api`:

```ts
import { Schema, type ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
  zi.registerTool({
    name: "repository_rule",
    description: "Look up one repository rule",
    parameters: Schema.object({ topic: Schema.string() }),
    outputSchema: Schema.object({ topic: Schema.string(), rule: Schema.string() }),
    async execute({ topic }, { signal }) {
      signal.throwIfAborted()
      return { topic, rule: `Rule for ${topic}` }
    }
  })
}
```

The default factory may be synchronous or asynchronous. Registration is allowed only while that factory runs. A failure rolls back registrations from that source without preventing other extensions or Zi from starting. Session context does not exist at factory time.

### Callback context

Every handler and command or tool invocation in one extension generation receives the same frozen session identity:

```ts
interface ExtensionContext {
  readonly mode: "interactive" | "text" | "json" | "rpc" | "embedded"
  readonly cwd: string
  readonly session:
    | { readonly type: "memory"; readonly id: string }
    | { readonly type: "journal"; readonly id: string; readonly file: string }
}
```

`interactive` is Zi's visible terminal client. `text`, `json`, and `rpc` are the corresponding CLI protocols. `embedded` is the default for direct SDK/runtime construction unless the embedding client supplies a more specific mode. `cwd` is the runtime's absolute working directory. A journal path is absolute; a memory session has no resumable file.

Lifecycle and agent-activity handlers receive `(event, context)`. Command and tool execution contexts extend this value with their invocation-scoped `signal`. The context is an immutable value captured when the session is constructed, not a live session API; extensions do not receive `AgentSession`, terminal UI objects, or session-manager authority.

```ts
zi.on("session_start", (event, context) => {
  if (context.mode !== "interactive") return
  console.error(`Started ${context.session.id} from ${event.reason}`)
})
```

### User commands

Register one idle-only user action with `registerCommand(...)`:

```ts
zi.registerCommand({
  name: "counter",
  description: "Show or increment the durable counter",
  argumentHint: "[show|increment]",
  async execute(arguments_, { signal }) {
    signal.throwIfAborted()
    return arguments_.trim() === "increment" ? "Counter incremented" : "Counter unchanged"
  }
})
```

Command names are lowercase kebab-case, begin with a letter, and are unique across the active extension generation. Built-in names are reserved. Interactive catalog precedence is built-in command, extension command, then prompt or skill resource. Duplicate extension names fail the later source instead of suffixing or shadowing the first.

The handler receives one bounded raw argument string and an invocation-scoped `AbortSignal`. It may return a bounded string for local user feedback or return nothing. Feedback is neither a journal entry nor provider context. Throw to report failure. Commands cannot run, queue, or intercept text while another session operation is active; interruption aborts the invocation, and `ExtensionHost` enforces execution and cancellation deadlines. Use `appendEntry(...)` when a command must persist model-invisible state. Conversation `sendMessage(...)` delivery is refused while a command owns the session; return feedback instead.

Interactive mode parses `/name arguments` and dispatches a typed intent through `AgentSession`; the extension never receives TUI objects. RPC clients use `command.list` and `command.invoke` directly rather than sending slash text through `session.prompt`. Completion providers, command shortcuts, arbitrary UI, provider interception, and session replacement authority are not part of this contract.

The catalog is limited to 128 commands and 512 KiB. Names are limited to 64 bytes, descriptions to 4 KiB, argument hints to 1 KiB, invocation arguments to 256 KiB, and local results to 16 KiB.

### Model-callable tools

Tool names use lowercase letters, numbers, and underscores and must begin with a letter. Parameters must be an object schema built from `Schema.string`, `number`, `integer`, `boolean`, `literal`, `optional`, `array`, and `object`. Literals are JSON primitives and string patterns are strings, not `RegExp` objects. The public types reject non-object tool parameters. Zi validates arguments before calling `execute`.

Without `outputSchema`, a tool returns one bounded string. Declaring `outputSchema` lets it return a matching bounded JSON value. Zi validates that value in the extension worker, renders it as JSON for direct model calls, and delivers it as an already-decoded JavaScript value in Code Mode. Tools throw errors for failed operations. Built-in Zi tool names take precedence over extension registrations.

`execute` receives an invocation-scoped `AbortSignal`. Cancellation is cooperative: pass the signal to subprocess or I/O APIs and stop owned work promptly. Zi rejects late completion and terminates a worker that misses execution or cancellation deadlines.

Large catalogs can register dormant tools with `active: false`, then replace that extension's model-visible subset at runtime:

```ts
zi.registerTool({
  name: "catalog_search",
  description: "Find an operational tool",
  parameters: Schema.object({ query: Schema.string() }),
  async execute({ query }) {
    const selected = query === "grafana" ? ["catalog_search", "oncall_grafana_query"] : ["catalog_search"]
    await zi.setActiveTools(selected)
    return `Active tools: ${selected.join(", ")}`
  }
})

zi.registerTool({
  name: "oncall_grafana_query",
  description: "Run one reviewed Grafana query",
  active: false,
  parameters: Schema.object({ expression: Schema.string() }),
  async execute({ expression }) {
    return `Reviewed query: ${expression}`
  }
})
```

`getActiveTools()` returns only the calling extension's active, admitted registrations. `setActiveTools(names)` replaces that set; it cannot disable built-ins or tools owned by another extension, and it rejects unknown or unadmitted names. The current provider tool-call batch and an already-running Code Mode invocation retain their admitted snapshot. The new selection is used by both direct calls and Code Mode before the next provider step.

Registration remains factory-time and statically reviewable. `active` defaults to `true`. Reload creates a new generation and restores each registration's `active` default. An extension that wants durable selection can read custom entries and call `setActiveTools(...)` from `session_start`.

A generation may register up to 256 tools in a 2 MiB catalog. At most 64 extension tools and 512 KiB of their provider-facing definitions may be active. Per-tool names are limited to 64 bytes, descriptions to 4 KiB, schemas to 16 KiB, invocation arguments to 256 KiB, and results to 256 KiB.

### Programmatic subagent profiles

`registerSubagentProfile(...)` is the programmatic counterpart to a Markdown profile resource. Both declarations join one `AgentSession`-owned catalog with the same name, description, instructions, optional model, and optional thinking contract. When child execution is available, a programmatic registration alone activates Zi's standard subagent tools; an extension does not need to register a second delegation tool.

Extensions may optionally build specialized orchestration with the bounded `zi.subagents` operations. The parent session retains profile precedence, process, protocol, concurrency, output, cancellation, durable evidence, containment, and shutdown ownership. Extension generation replacement removes its profile registrations without terminating admitted children. Profiles do not claim permissions, read-only behavior, worktrees, tool restrictions, or isolation. See [Profile-driven subagents](subagents.md) for the complete contract and example.

### Durable state and custom messages

Use `getSessionEntries(customType)` and `appendEntry(customType, data)` for extension state that must survive resume but must not enter model context. Values are bounded JSON. Reads return that custom type's complete bounded session history, including entries older than the active post-compaction message tail.

Use `sendMessage(message, delivery)` for conversation side channels. Content may contain text and images; optional `details` are durable JSON for clients and extensions, not model content. Delivery is one of `append`, `trigger_turn`, `steer`, `follow_up`, or `next_turn`.

```ts
zi.on("session_start", async () => {
  const entries = await zi.getSessionEntries("example.mode")
  // Restore from entries.at(-1)?.data.
})

await zi.appendEntry("example.mode", { enabled: true })
await zi.sendMessage({ customType: "example.mode", content: "Mode enabled", display: true }, "follow_up")
```

`display` controls transcript presentation only. Both `display: true` and `display: false` messages enter provider context and compaction budgets. Use `appendEntry`—not a hidden custom message—for model-invisible state. Session-operation promises settle when Zi admits or refuses the operation; `trigger_turn` does not wait for the resulting provider turn.

Custom types use lowercase ASCII names beginning with a letter. They may contain digits and `._:/-`, up to 128 bytes. Session operations share the worker's bounded correlated-request capacity. A domain refusal rejects only that operation promise; malformed protocol data still fails the worker generation.

## Lifecycle and resources

Use `zi.on("session_start", handler)` to create long-lived resources and `zi.on("session_shutdown", handler)` to stop them. Shutdown handlers may read custom entries and append final custom state until all handlers settle; conversation delivery is closed once session disposal begins. Zi then removes the session-operation binding before disposing the worker. The extension that creates a subprocess, listener, socket, or other resource owns its cleanup. Shutdown waits are bounded, and Zi cannot clean up detached descendants.

Use `zi.on("agent_start", handler)` for the start of underlying agent activity and `zi.on("agent_settled", handler)` for the final transition back to logical idle. Settlement occurs only after retries, compaction recovery, and admitted queued continuation have finished. Zi intentionally does not expose `agent_end` as an idle signal.

Agent-activity handlers are observational. Zi publishes them without awaiting them in `AgentSession`; one slow extension cannot enter agent-run settlement. A worker delivers them in order through a 32-event queue, gives each event one second across its registered handlers, and fails only that extension generation on timeout or overflow. Reload, session replacement, and shutdown close the old generation so stale completion cannot cross into the new session. Use `session_shutdown`—not an activity handler—to release resources.

Edit trusted extensions, skills, prompts, settings, or context files, then run `/reload` in interactive mode (or call `AgentSession.reload()` from a client). Reload keeps the same session identity and journal, rereads settings and resources under the current project-trust admission, replaces the extension generation in place, and emits `session_shutdown` / `session_start` with reason `"reload"`. Candidate `session_start` may append custom state and append-only custom messages; turn-triggering delivery stays closed until reload settles. A failed candidate before commit retains the previous generation. A worker crash leaves the session usable without extensions until an explicit reload recovers it. Subagent profiles registered by the old generation are replaced with the generation, while already admitted child work remains owned by the session.

## Modes and diagnostics

The authoritative command catalog is shared by interactive mode and RPC. RPC exposes `command.list` and `command.invoke`; text and JSON modes do not parse slash commands. The authoritative tool catalog is shared by interactive, text, JSON, and RPC modes. Interactive mode uses Zi's generic tool frame. Text mode writes tool progress to stderr and the final answer to stdout. JSON mode emits ordered tool lifecycle events on stdout. RPC emits versioned, sequenced session events and correlated responses. Extension `stdout` and `stderr` are retained separately in bounded worker log tails and never join those output protocols.

Import, factory, registration, protocol, execution, and worker failures are source-attributed and fail closed. A failed worker generation is not restarted implicitly; use `/reload` or create a new session after correcting the extension.
