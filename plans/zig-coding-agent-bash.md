# Add shallow bounded shell execution

**Status:** Implemented and verified
**References:** Pi `73414d08b94d7db46d3fa66582c8fe3b02dabf72`; ZigAI as the Zig implementation model
**Scope:** One settled shell command per tool call through the existing OpenAI-compatible and OpenAI Codex coding-agent paths

## Intent

The initial tools should complete a usable coding loop before Zi deepens Pi parity. This slice adds the smallest dependable `bash` capability: execute one command in the session directory, capture bounded output, report termination, and settle process cleanup on timeout or cancellation.

The tool remains concrete and private to `AgentSession`. It does not add interactive processes, streaming updates, background jobs, environment configuration, persisted full output, or a process abstraction.

## Interface

```json
{ "command": "zig build test" }
```

`command` is required, non-empty UTF-8 without NUL bytes, and limited to 64 KiB. Raw arguments are limited to 128 KiB.

The process is launched as:

```text
bash -c <command>
```

It inherits the parent environment, receives no stdin, and uses the borrowed session `std.Io.Dir` as its cwd.

## Process contract

- Fixed default timeout: 120 seconds.
- An earlier run deadline is folded into the process deadline. Dynamic cancellation is owned by `Agent.executeControlled`, whose select cancellation unwinds `std.process.run` and waits for its deferred kill/reap before returning.
- `std.process.run` owns spawn, concurrent pipe draining, wait, and unconditional settled kill on timeout/cancellation/error. The configured duration is converted once to an absolute deadline before the read loop.
- Exit code zero is a successful tool result.
- Non-zero exit, signal termination, spawn failure, and capture overflow are bounded model-visible failures.
- OOM, cancellation, and timeout are fatal run errors.
- Process cleanup is settled before any success, failure, cancellation, or timeout returns. Result formatting remains bounded and may still fail fatally on OOM after process settlement.

The private tool stores a timeout value so focused tests can use milliseconds without changing the provider-visible interface.

## Output bounds

- Capture at most 8 MiB from stdout and 8 MiB from stderr; exceeding either aborts and settles the process with a model-visible failure.
- Present stdout followed by a marked stderr section.
- Model-visible text, truncation notice, and termination status together stay within 50 KiB.
- Retain at most the last 2,000 lines and the useful UTF-8 tail.
- Reject captured output that is not valid UTF-8.
- Do not persist full output in this initial slice.

Successful output ends with `Command exited with code 0`. Non-zero failures end with the corresponding code; signal/stopped/unknown terms receive explicit bounded status text.

## Ownership and program design

Add `src/coding_agent/tools/BashTool.zig` as one concrete executor. Extend stable tool storage:

```zig
const Tools = struct {
    read: ReadTool,
    write: WriteTool,
    edit: EditTool,
    bash: BashTool,
};
```

`AgentSession` keeps the existing allocate/admit/deinit lifecycle. There is no command runner interface, shell registry, environment owner, job manager, or process store.

## Instructions

The fixed coding policy says to use `bash` for builds, tests, repository inspection, and commands; read files with `read` rather than `cat` or `sed`; use `edit` for precise changes and `write` for new files or full rewrites. It must not claim interactive/background shell capabilities.

## Behavior tests

1. Execute in the borrowed cwd and capture stdout.
2. Capture and distinguish stderr.
3. Report exit zero, non-zero exit, no output, and signal termination.
4. Bound line-heavy and byte-heavy output while retaining the tail.
5. Reject invalid UTF-8 output.
6. Reject malformed, empty, NUL, invalid UTF-8, and oversized commands.
7. Enforce and settle a short test timeout.
8. Honor pre-cancellation without spawning.
9. Run a real `bash` tool call through `AgentSession`; verify instructions, canonical history, cwd evidence, and final model response.

## Deferred

Per-call timeouts, process-tree groups, interactive stdin, background jobs, output streaming, temp-file persistence, environment customization, shell selection, Windows shell adaptation, progress events, and TUI rendering are outside this slice.

## Acceptance

- A supported model can run builds, tests, and repository commands in the session directory.
- Output and process lifetime remain bounded.
- Timeout/cancellation settle child cleanup before returning.
- `AgentSession` exposes a truthful read/write/edit/bash coding loop without provider expansion.
- Build, debug and ReleaseSafe tests, lint, diff checks, and focused review pass.

**Verification:** `zig build`; 97/97 debug and ReleaseSafe tests; `ziglint`; `git diff --check`; independent re-review with no findings.
