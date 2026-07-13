# TypeScript extension API v1

Status: initial public capability.

See `docs/typescript-extension-api-north-star-prd.md` for the intended mature
capability model. This document remains the contract for the currently
implemented prompt-command tranche.

Zi borrows Pi's pleasant activation-function ergonomics, but not its in-process
service-locator or event-bus architecture. Extensions execute in the supervised
Node host. Zig owns registration publication, invocation deadlines, frontend
state, prompt submission, persistence, replacement, and shutdown.

## Author surface

The type-only `@zi/extension-api` package exports:

```ts
export type ExtensionFactory = (zi: ZiExtension) => void | Promise<void>

export interface ZiExtension {
  readonly apiVersion: 1
  readonly commands: CommandRegistrar
}

export interface CommandRegistrar {
  registerPrompt(definition: PromptCommandDefinition): void
}

export interface PromptCommandDefinition {
  readonly name: string
  readonly description: string
  run(context: PromptCommandContext):
    | PromptCommandResult
    | Promise<PromptCommandResult>
}

export interface PromptCommandContext {
  readonly args: string
  readonly cwd: string
  readonly signal: AbortSignal
}

export interface PromptCommandResult {
  readonly prompt: string
}
```

Example:

```ts
import type { ExtensionFactory } from "@zi/extension-api"

const activate: ExtensionFactory = (zi) => {
  zi.commands.registerPrompt({
    name: "review",
    description: "Review the current changes",
    run: ({ args }) => ({
      prompt: `Review the current changes. Focus on: ${args}`,
    }),
  })
}

export default activate
```

Install an extension globally, install it for one project, or load it explicitly:

```text
~/.zi/agent/extensions/review.ts
~/.zi/agent/extensions/review/index.ts
<project>/.zi/extensions/review.ts
<project>/.zi/extensions/review/index.ts
```

```sh
zi --extension ./review.ts       # -e is the short form
zi --print -e ./review.ts "/review concurrency"
```

Global extensions are trusted user resources and load automatically. Interactive
Zi asks before loading project extensions unless `--approve` or `--no-approve`
selects the one-run decision. Non-interactive modes ignore project extensions by
default and require `--approve`. `--no-extensions` disables global, project, and
explicit extension loading. `ZI_CODING_AGENT_DIR` relocates the global agent
directory, including its `extensions` child.

Within each scope, Zi loads `*.ts` and `*/index.ts` in lexical order. Scope order
is global, project, then explicit CLI entries. Every path is canonicalized and
canonical duplicates are removed before constructing the load plan. A missing
or empty set leaves the extension host absent and starts no Node process.

The command result enters Zi through the normal user-prompt path. The generated
prompt, not the slash invocation, is the durable user message. `--extension` is
repeatable up to eight entries.

## Registration transaction

Each module must export one default activation function. Registration is open
only while that function is running and closes when it settles. Registrations
are generation-local and invisible to Zi until every module activates and the
candidate generation commits. Any invalid registration, duplicate name,
built-in collision, activation exception, or initialization deadline rejects
the candidate and preserves the previous active catalog.

Dynamic registration is not supported in v1.

## Invocation ownership

`ExtensionHost` owns the generation-bound command catalog and typed invocation
handles. A concrete frontend starts, polls, cancels, takes, and deinitializes one
invocation. TUI execution is foreground work and ESC requests cancellation.
Print mode resolves the same slash command before driving its normal
`AgentSession` run. The host receives only command arguments, cwd, and an
`AbortSignal`; it receives no session, transcript, UI, settings, model, provider,
or persistence owner.

Replacement settles old-generation invocations as replaced. Deadline expiry,
malformed output, or an uncooperative handler fails the supervised generation;
Node cannot block the frontend owner loop.

## Bounds

| Value | Bound | Policy |
|---|---:|---|
| Discovered modules per generation | 128 | Reject discovery |
| Directory entries examined per scope | 1,024 | Reject discovery |
| Explicit `--extension` entries | 8 | Reject CLI parsing |
| Prompt commands per generation | 32 | Reject candidate |
| Command name | 32 ASCII bytes, `[a-z][a-z0-9-]*` | Reject candidate |
| Description | 96 UTF-8 bytes | Reject candidate |
| Arguments | 4 KiB UTF-8 | Reject invocation |
| Generated prompt | 4 KiB UTF-8 | Fail invocation |
| Concurrent prompt handlers | 8 | Reply overloaded |
| TUI/print invocation | 30 seconds | Cancel, then generation deadline policy |

The 4 KiB generated-prompt bound deliberately matches the concrete TUI
composer/run policy even though the generated text never needs to be placed in
the composer.

## Deliberately absent

- no `zi.on()` or generic event bus;
- no custom tools yet;
- no dynamic registration or argument completion;
- no UI, rendering, shortcut, or CLI flag APIs;
- no session-history or custom persistence API;
- no model, provider, settings, or active-tool mutation;
- no shell helper or arbitrary JSON-RPC method surface.

Future capabilities add explicit typed registrars and host methods. They do not
grow `ZiExtension` into an ambient application context.
