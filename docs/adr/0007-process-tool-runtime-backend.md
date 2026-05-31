# adr 0007: use std process execution before vendoring zio

status: accepted

date: 2026-05-31

## context

zi needs a shell/process tool for coding-agent parity, but process execution is
the first feature that can easily smuggle in an ambient runtime: child process
ownership, pipe draining, timeout, cancellation, output limits, cwd policy, and
shutdown behavior.

`lalinsky/zio` is a good Zig 0.16 runtime candidate. it provides a full
`std.Io` implementation, task groups, cancellation, async process wait/kill,
and async file/network primitives. that is useful if zi later needs one backend
to cover provider streaming, process tools, and runtime completion queues.

for the current slice, Zig 0.16 already provides `std.process.run` over
`std.Io`. it spawns a child, drains stdout and stderr through a multi-reader,
applies output limits, accepts an `std.Io.Timeout`, waits for the child, and
kills it during error unwinding.

## decision

do not vendor `zio` for the first process tool.

the first process tool uses `std.process.run` and keeps the product contract
small:

- one command per tool call.
- fixed cwd from `coding_agent` services/session options.
- no stdin, background jobs, environment overrides, PTY, or streaming updates.
- sequential execution mode.
- bounded stdout and stderr.
- bounded timeout.
- nonzero exits are data, not tool execution errors.
- timeout and output overflow are explicit tool results.

`zio` remains allowed as a future backend if shared runtime pressure proves it:

```text
provider stream + process tool + cancellation + bounded completions
  -> one std.Io backend choice
  -> session/agent owners drain completions
```

vendoring a runtime must remove owned complexity across more than one subsystem.
it must not become app policy.
