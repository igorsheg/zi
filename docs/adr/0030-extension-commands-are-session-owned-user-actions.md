# ADR 0030: Extension commands are session-owned user actions

## Status

Accepted.

## Context

Zi already had closed built-in terminal commands, prompt and skill resource commands, supervised trusted extension workers, durable custom state, and direct RPC session operations. It did not have an executable user-command contract for extensions.

Three references informed the boundary:

- Pi Mono at `73414d08b94d7db46d3fa66582c8fe3b02dabf72` registers command descriptors in `core/extensions/types.ts` and executes them from `core/agent-session.ts`. Pi also permits immediate execution while streaming, suffixes duplicate extension commands, and passes a broad in-process `ExtensionCommandContext` with UI and session authority.
- Grok Build at `a4221165824e5b1f5c4c10b7459f65e78dd6448d` keeps `CommandSpec`, raw trimmed `CommandInvocation`, and closed `CommandAction` values in `xai-agent-lifecycle/src/send/contributors/command.rs`; the host parses input and routes an exact name to one contributor.
- Codex at `2b5bdcf67547860f2e5c5a605009a70026796b2b` keeps built-in identity, availability, parsing, validation, and exhaustive dispatch explicit in its TUI. It has no generic executable extension-command registry at that pin.

Zi needs executable extension commands without importing Pi's in-process authority or moving coding-agent policy into the terminal client.

## Decision

An extension may call `registerCommand({ name, description, argumentHint?, execute })` only during factory settlement. A handler receives one bounded raw argument string and `{ signal: AbortSignal }`. It returns a bounded string for local semantic feedback or returns nothing. Throwing reports command failure.

`AgentSession` owns the admitted command catalog and the idle-only `extension_command` activity. It rejects commands during provider work, compaction, reload, authentication, model mutation, queued input, another command, or disposal. It owns interruption at the session boundary and allows command handlers to append durable custom state. Command feedback is transient: it is not a session entry, presentation message, or provider-context value.

`ExtensionHost` owns the command catalog received at the worker-ready barrier, correlated command invocation, shared pending-request capacity, execution and cancellation deadlines, generation replacement, stale completion rejection, diagnostics, and worker disposal. `LoadedExtensionGeneration` owns registration order, unique-name admission, handler lookup, and invocation-scoped cancellation. Commands use closed `command_invoke`, `command_result`, `command_error`, and `command_cancelled` protocol messages. Extension protocol version 6 introduces this contract.

Names are lowercase kebab-case. Duplicate extension names fail the later source. Built-in names are reserved and rejected with a source-attributed registration diagnostic. Interactive precedence is built-in command, admitted extension command, then prompt or skill resource. Extension commands win resource-name collisions because resources remain prompt expansion rather than executable actions.

`SlashController` composes the catalog, parses terminal input, and emits a closed `extension_command` intent. `PromptStore` owns only the transient running/cancelling presentation workflow and delegates execution and interruption to `AgentSession`. Components do not receive command registries or dispatch business operations.

RPC exposes `command.list` and `command.invoke` over the same `AgentSession` owner. RPC invocation addresses a command directly and never sends slash text through `session.prompt`.

The initial bounds are:

- 128 commands and 512 KiB of command catalog data;
- 64-byte names, 4 KiB descriptions, and 1 KiB argument hints;
- 256 KiB raw invocation arguments and 16 KiB local results;
- 128 total command/tool invocations per worker generation;
- 30-second execution and 1-second cancellation deadlines.

Completion providers, extension shortcuts, command interception, execution while streaming, queued commands, arbitrary terminal UI, provider hooks, and session replacement authority remain deferred.

## Consequences

Trusted extensions can add narrow repository actions without turning them into model tools or provider-visible prompts. Durable state uses the existing append-only custom-entry contract, while ordinary feedback stays local and model-invisible. Reload atomically replaces command registrations; old invocations cannot complete into the new generation.

Zi intentionally differs from Pi: built-ins cannot be shadowed, duplicate names are not suffixed, commands are idle-only, and handlers receive no TUI, `SessionManager`, model, or session-replacement object graph. Zi preserves Grok's host-parsed, one-owner routing lesson while adding explicit validation, cancellation, bounds, source attribution, process isolation, and stale-generation behavior.
