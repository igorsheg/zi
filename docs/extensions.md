# Extensions

Zi extensions are trusted TypeScript modules that add repository-specific behavior without changing Zi. The supported public surface currently consists of lifecycle handlers and model-callable tools.

## Trust and authority

Project extensions are loaded only after the project `.zi` directory is trusted. Interactive mode asks; text and JSON modes never prompt and exclude unresolved project configuration. Global and explicit extensions are already user-admitted configuration.

Extensions run as the current user. They can read files and environment variables, access credentials, and spawn processes. The worker process contains crashes and hangs; it is not a security sandbox or credential boundary. Review extension code before trusting it.

## Locations

Zi discovers entry points in deterministic order:

1. repeated `--extension <path>` arguments;
2. `$HOME/.zi/agent/extensions/`;
3. `<cwd>/.zi/extensions/`, when trusted.

A directory entry may use `index.ts`; a direct `.ts` file also works. TypeScript and relative imports load without a build. Install third-party dependencies in the extension's own package hierarchy so normal bare-module resolution can find them.

Start with [`examples/extensions/custom-tool/index.ts`](../examples/extensions/custom-tool/index.ts).

## Public API

Import only `@with-zi/extension-api`:

```ts
import { Schema, type ExtensionAPI } from "@with-zi/extension-api"

export default function (zi: ExtensionAPI): void {
  zi.registerTool({
    name: "repository_rule",
    description: "Look up one repository rule",
    parameters: Schema.object({ topic: Schema.string() }),
    async execute({ topic }, { signal }) {
      signal.throwIfAborted()
      return `Rule for ${topic}`
    }
  })
}
```

The default factory may be synchronous or asynchronous. Registration is allowed only while that factory runs. A failure rolls back registrations from that source without preventing other extensions or Zi from starting.

Tool names use lowercase letters, numbers, and underscores and must begin with a letter. Parameters must be an object schema built from `Schema.string`, `number`, `integer`, `boolean`, `literal`, `optional`, `array`, and `object`. Zi validates arguments before calling `execute`. A tool returns one bounded string or throws an error. Built-in Zi tool names take precedence over extension registrations.

`execute` receives an invocation-scoped `AbortSignal`. Cancellation is cooperative: pass the signal to subprocess or I/O APIs and stop owned work promptly. Zi rejects late completion and terminates a worker that misses execution or cancellation deadlines.

## Lifecycle and resources

Use `zi.on("session_start", handler)` to create long-lived resources and `zi.on("session_shutdown", handler)` to stop them. The extension that creates a subprocess, listener, or other resource owns its cleanup. Shutdown waits are bounded, and Zi cannot clean up detached descendants.

## Modes and diagnostics

The authoritative tool catalog is shared by interactive, text, and JSON modes. Interactive mode uses Zi's generic tool frame. Text mode writes tool progress to stderr and the final answer to stdout. JSON mode emits ordered tool lifecycle events on stdout. Extension `stdout` and `stderr` are retained separately in bounded worker log tails and never join those output protocols.

Import, factory, registration, protocol, execution, and worker failures are source-attributed and fail closed. A failed worker generation is not restarted implicitly; reload or create a new session after correcting the extension.
