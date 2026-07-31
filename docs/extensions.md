# Extensions

Zi extensions are trusted TypeScript modules that add repository-specific behavior without changing Zi. The supported public surface consists of lifecycle handlers, model-callable tools, declarative subagent definitions, and bounded durable session operations.

## Trust and authority

Project extensions are loaded only after the project `.zi` directory is trusted. Interactive mode asks; text, JSON, and RPC modes never prompt and exclude unresolved project configuration. Global and explicit extensions are already user-admitted configuration.

Extensions run as the current user. They can read files and environment variables, access credentials, and spawn processes. The worker process contains crashes and hangs; it is not a security sandbox or credential boundary. Review extension code before trusting it.

## Locations

Zi discovers entry points in deterministic order:

1. repeated `--extension <path>` arguments;
2. `<cwd>/.zi/extensions/`, when trusted;
3. `$HOME/.zi/agent/extensions/`.

A directory entry may use `index.ts`; a direct `.ts` file also works. TypeScript and relative imports load without a build. Install third-party dependencies in the extension's own package hierarchy so normal bare-module resolution can find them.

Start with [`examples/extensions/custom-tool/index.ts`](../examples/extensions/custom-tool/index.ts). For session persistence and custom messages, see [`examples/extensions/durable-counter/index.ts`](../examples/extensions/durable-counter/index.ts).

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

The default factory may be synchronous or asynchronous. Registration is allowed only while that factory runs. A failure rolls back registrations from that source without preventing other extensions or Zi from starting.

Tool names use lowercase letters, numbers, and underscores and must begin with a letter. Parameters must be an object schema built from `Schema.string`, `number`, `integer`, `boolean`, `literal`, `optional`, `array`, and `object`. Literals are JSON primitives and string patterns are strings, not `RegExp` objects. The public types reject non-object tool parameters. Zi validates arguments before calling `execute`.

Without `outputSchema`, a tool returns one bounded string. Declaring `outputSchema` lets it return a matching bounded JSON value. Zi validates that value in the extension worker, renders it as JSON for direct model calls, and delivers it as an already-decoded JavaScript value in Code Mode. Tools throw errors for failed operations. Built-in Zi tool names take precedence over extension registrations.

`execute` receives an invocation-scoped `AbortSignal`. Cancellation is cooperative: pass the signal to subprocess or I/O APIs and stop owned work promptly. Zi rejects late completion and terminates a worker that misses execution or cancellation deadlines.

### Subagent definitions

Native Zi owns subagent processes, RPC sequencing, admission, completion durability, and shutdown. Extensions may contribute only declarative types during factory execution:

```ts
zi.registerSubagentType({
  name: "reviewer",
  description: "Review a change for correctness and missing tests",
  instructions: "Inspect the requested change. Do not edit files. Return findings with paths and line numbers."
})
```

The V1 definition has exactly `name`, `description`, and `instructions`. It cannot select a model, executable, tool set, permission policy, or worktree. The built-in `general` name cannot be replaced. Names and bounded normalized descriptions appear in the model-facing `spawn_subagent.type` catalog; child-only `instructions` do not. Source precedence is explicit, trusted project, then global; a conflicting later source fails its registration. Reload atomically replaces extension definitions and the derived direct/Code Mode tool catalogs, while live children keep their spawn-time snapshot and survive extension removal or worker failure.

See [`examples/extensions/subagent/`](../examples/extensions/subagent/) for the complete example. Extensions do not receive a procedural subagent API.

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

Use `zi.on("session_start", handler)` to create long-lived resources and `zi.on("session_shutdown", handler)` to stop them. Shutdown handlers may read custom entries and append final custom state until all handlers settle; conversation delivery is closed once session disposal begins. Zi then removes the session-operation binding before disposing the worker. The extension that creates a subprocess, listener, or other resource owns its cleanup. Shutdown waits are bounded, and Zi cannot clean up detached descendants.

Edit trusted extensions, skills, prompts, settings, or context files, then run `/reload` in interactive mode (or call `AgentSession.reload()` from a client). Reload keeps the same session identity and journal, rereads settings and resources under the current project-trust admission, replaces the extension generation in place, and emits `session_shutdown` / `session_start` with reason `"reload"`. Candidate `session_start` may append custom state and append-only custom messages; turn-triggering delivery stays closed until reload settles. A failed candidate before commit retains the previous generation. A worker crash leaves the session usable without extensions until an explicit reload recovers it.

## Modes and diagnostics

The authoritative tool catalog is shared by interactive, text, JSON, and RPC modes. Interactive mode uses Zi's generic tool frame. Text mode writes tool progress to stderr and the final answer to stdout. JSON mode emits ordered tool lifecycle events on stdout. RPC emits versioned, sequenced session events and correlated responses. Extension `stdout` and `stderr` are retained separately in bounded worker log tails and never join those output protocols.

Import, factory, registration, protocol, execution, and worker failures are source-attributed and fail closed. A failed worker generation is not restarted implicitly; use `/reload` or create a new session after correcting the extension.
