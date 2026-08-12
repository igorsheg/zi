---
slug: code-mode
title: Code Mode
order: 75
---

# Code Mode

Code Mode is Zi's built-in `code` tool. It lets the model use ordinary JavaScript for data-dependent loops, filtering, aggregation, and multi-tool workflows while keeping direct tools available for routine work.

## Authority

Code Mode has the same local authority as Zi. A cell can read the environment, access the filesystem and network, import modules, and start subprocesses. It is **not a security sandbox or credential boundary**. Worker isolation contains crashes, hangs, and retained memory; it does not make generated code untrusted.

Prefer `zi.*` calls when cancellation, tool traces, extension output validation, and normal Zi result handling matter.

## Cell API

A cell is an ordinary JavaScript async arrow function:

```js
;async () => {
  const files = await zi.read({ path: "package.json" })
  state.runs = (state.runs ?? 0) + 1
  scratch.lastPackage = files
  return { runs: state.runs }
}
```

The runtime APIs are available as cell globals.

- `zi` is the immutable tool catalog admitted when the cell starts. Extension catalog changes apply to later cells.
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

A cell may contain at most 256 KiB of code, make at most 64 `zi` calls, and commit at most 256 KiB of structurally bounded JSON state. Program-state history has its own 2,048-entry and 8 MiB admission limit, reserving the rest of the session journal for conversation and extension state. The default execution deadline is 120 seconds. Protocol queues, tool traces, errors, console logs, worker output, retained memory, and shutdown waits are also bounded.
