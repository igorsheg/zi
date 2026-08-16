---
slug: code-mode
title: Code Mode
order: 70
---

# Code Mode

A model that answers one question through ten separate tool calls re-reads the same files, loses every intermediate result between calls, and spends your context on data it only needed in order to filter something. Code Mode gives it a loop and a place to keep intermediate values.

Code Mode is Zi's built-in `code` tool. It gives the model an erasable-TypeScript function body for data-dependent loops, filtering, aggregation, and multi-tool workflows while keeping direct tools available for routine work.

Each call supplies a short active-voice `description` and the function `code`. Top-level `await` and `return` work directly:

```ts
const files = await zi.read({ path: "package.json" })
state.runs = ((state.runs as number | undefined) ?? 0) + 1
scratch.lastPackage = files
return { runs: state.runs }
```

Zi strips types before execution. Syntax that emits JavaScript, including enums, namespaces, parameter properties, import aliases, and export assignments, is rejected instead of being transformed into hidden runtime behavior.

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

Every `zi` call must be awaited before the cell returns. Zi starts calls in submission order: tools declared parallel may overlap in a four-call pool, while sequential tools wait for earlier parallel work and then run alone. A sequential call is also a barrier for later parallel calls.

Tool failures reject with `ZiToolError`. Its `toolName` identifies the failed tool, so a cell can catch one expected failure without parsing presentation text; `Promise.allSettled` retains independent failures.

## Code-only invocations

Use `--code-only` to expose only the `code` tool to the model:

```sh
zi --code-only
zi --code-only -p "inspect this repository"
zi --code-only --mode json "implement the requested change"
```

The cell's `zi` snapshot still contains the same admitted built-in, extension, and six agent-collaboration tools that an ordinary invocation exposes directly. This changes the model's control surface, not Zi's authority. TUI commands remain available, and spawned agents inherit the policy. The flag applies to the invocation and is not persisted in a session journal.

## Memory and failure semantics

| Memory    | Values               | Ordinary cell failure | Worker restart | Session resume |
| --------- | -------------------- | --------------------- | -------------- | -------------- |
| `scratch` | Arbitrary JavaScript | Preserved             | Cleared        | Cleared        |
| `state`   | JSON object          | Rolled back           | Preserved      | Preserved      |

`state` commits only after a successful cell. Tool effects are not transactional: filesystem edits, commands, extension effects, and subprocess activity that happened before a failure are not rolled back.

A cancelled, timed-out, crashed, or over-limit worker is replaced only after its generation settles. Committed `state` is supplied to the replacement; stale tool completions from the old generation are rejected.

## Bounds

Each bound protects something the session needs in order to survive a bad cell.

A cell may contain at most 256 KiB of code, make at most 64 `zi` calls, and commit at most 256 KiB of structurally bounded JSON state, so one cell cannot take over the turn or the state store. The runtime separately admits at most 60 seconds of worker-process compute and 120 seconds of wall time; waiting on a legitimate tool consumes wall time without materially spending the compute budget.

Values crossing from the cell are snapshotted through captured intrinsics. The boundary accepts only finite, lossless JSON in plain objects and dense undecorated arrays, with at most 32 levels and 16,384 nodes; it does not invoke getters, `toJSON`, or guest-replaced JSON methods.

Logs and the terminal result or error share an exact 512 KiB serialized UTF-8 budget. Program-state history has its own 2,048-entry and 8 MiB admission limit, reserving the rest of the session [journal](vocabulary.md) for conversation and extension state. Protocol queues, tool traces, retained memory, and shutdown waits are bounded for the same reason.

## What this does not do

Code Mode is not a security or credential boundary. A cell runs with the authority you gave Zi.

It does not make every tool concurrent. Only tools whose owner declares parallel execution may overlap, and the pool remains bounded; sequential tools retain an exclusive ordering barrier.

`scratch` does not survive worker replacement or session resume. Only committed `state` crosses those transitions.

A failed cell does not undo its effects. `state` rolls back; the filesystem, commands, and subprocesses do not.

`--code-only` does not reduce Zi's authority. It changes which tools the model can call directly, not what a cell may do.
