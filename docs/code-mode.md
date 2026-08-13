---
slug: code-mode
title: Code Mode
order: 70
---

# Code Mode

A model that answers one question through ten separate tool calls re-reads the same files, loses every intermediate result between calls, and spends your context on data it only needed in order to filter something. Code Mode gives it a loop and a place to keep intermediate values.

Code Mode is Zi's built-in `code` tool. It lets the model use ordinary JavaScript for data-dependent loops, filtering, aggregation, and multi-tool workflows while keeping direct tools available for routine work.

A cell is an ordinary JavaScript async arrow function:

```js
;async () => {
  const files = await zi.read({ path: "package.json" })
  state.runs = (state.runs ?? 0) + 1
  scratch.lastPackage = files
  return { runs: state.runs }
}
```

## Authority

Code Mode has the same local authority as Zi. A cell can read the environment, access the filesystem and network, import modules, and start subprocesses. It is **not a security sandbox or credential boundary**. Worker isolation contains crashes, hangs, and retained memory; it does not make generated code untrusted.

Prefer `zi.*` calls when cancellation, tool traces, extension output validation, and normal Zi result handling matter.

## Cell API

The runtime APIs are available as cell globals.

- `zi` is the immutable tool catalog [admitted](vocabulary.md) when the cell starts. Extension catalog changes apply to later cells.
- `scratch` holds arbitrary volatile JavaScript values, including maps, functions, and imported modules.
- `state` is bounded JSON owned by the host.
- `project.import(specifier)` resolves packages and project files from the session working directory. Native dynamic import remains available.
- `console.log`, `console.warn`, and `console.error` use bounded Node-style value inspection. Logs are returned with both successful and failed cell results.

Every `zi` call must be awaited before the cell returns. Calls are serialized by Zi, even when the cell creates them concurrently. `Promise.all` does not add tool concurrency; use `Promise.allSettled` only when independent failures should remain available to the cell.

## Code-only invocations

Use `--code-only` to expose only the `code` tool to the model:

```sh
zi --code-only
zi --code-only -p "inspect this repository"
zi --code-only --mode json "implement the requested change"
```

The cell's `zi` snapshot still contains the same admitted built-in, extension, subagent, and peer tools that an ordinary invocation exposes directly. This changes the model's control surface, not Zi's authority. TUI commands remain available, and spawned Zi subagents inherit the policy. The flag applies to the invocation and is not persisted in a session journal.

## Memory and failure semantics

| Memory    | Values               | Ordinary cell failure | Worker restart | Session resume |
| --------- | -------------------- | --------------------- | -------------- | -------------- |
| `scratch` | Arbitrary JavaScript | Preserved             | Cleared        | Cleared        |
| `state`   | JSON object          | Rolled back           | Preserved      | Preserved      |

`state` commits only after a successful cell. Tool effects are not transactional: filesystem edits, commands, extension effects, and subprocess activity that happened before a failure are not rolled back.

A cancelled, timed-out, crashed, or over-limit worker is replaced only after its generation settles. Committed `state` is supplied to the replacement; stale tool completions from the old generation are rejected.

## Bounds

Each bound protects something the session needs in order to survive a bad cell.

A cell may contain at most 256 KiB of code, make at most 64 `zi` calls, and commit at most 256 KiB of structurally bounded JSON state, so one cell cannot take over the turn or the state store. The default execution deadline is 120 seconds, which bounds a cell that never returns.

Program-state history has its own 2,048-entry and 8 MiB admission limit, reserving the rest of the session [journal](vocabulary.md) for conversation and extension state. Protocol queues, tool traces, errors, console logs, worker output, retained memory, and shutdown waits are bounded for the same reason.

## What this does not do

Code Mode is not a security or credential boundary. A cell runs with the authority you gave Zi.

It does not add tool concurrency. `zi` calls are serialized, and `Promise.all` does not change that.

`scratch` does not survive worker replacement or session resume. Only committed `state` crosses those transitions.

A failed cell does not undo its effects. `state` rolls back; the filesystem, commands, and subprocesses do not.

`--code-only` does not reduce Zi's authority. It changes which tools the model can call directly, not what a cell may do.
