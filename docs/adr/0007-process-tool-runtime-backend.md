# adr 0007: process tool runtime backend

status: superseded by zio-native process runner

date: 2026-05-31

superseded: 2026-06-01

## context

zi needs a shell/process tool for coding-agent parity, but process execution is
the first feature that can easily smuggle in an ambient runtime: child process
ownership, pipe draining, timeout, cancellation, output limits, cwd policy, and
shutdown behavior.

`lalinsky/zio` is a good Zig 0.16 runtime candidate. it provides a full
`std.Io` implementation, task groups, cancellation, async process wait/kill,
and async file/network primitives. that is useful if zi later needs one backend
to cover provider streaming, process tools, and runtime completion queues.

for the first slice, Zig 0.16 provided `std.process.run` over `std.Io`. it
spawned a child, drained stdout and stderr through a multi-reader, applied
output limits, accepted an `std.Io.Timeout`, waited for the child, and killed it
during error unwinding.

the zio runtime check showed that `std.process.run` is not a clean drop-in over
zio's `std.Io`: child pipe reads can report `error.WouldBlock`. the same check
showed that a zio-native runner using zio process wait, zio pipe reads, scoped
reader tasks, timeout, and explicit output bounds works for the bash tool
pressure points.

## decision

vendor `zio` and make the process tool use a Zi-owned zio-native process runner.

the process tool keeps the product contract small:

- one command per tool call.
- fixed cwd from `coding_agent` services/session options.
- no stdin, background jobs, environment overrides, PTY, or streaming updates.
- sequential execution mode.
- bounded stdout and stderr.
- bounded timeout.
- nonzero exits are data, not tool execution errors.
- timeout and output overflow are explicit tool results.

the runtime-owned process runner uses zio for the OS-backed process path:

- child process wait is a zio-backed completion.
- stdout and stderr are drained concurrently through `zio.Pipe`.
- timeout is an explicit zio task selected by the process runner owner.
- reader tasks are explicit zio join handles spawned from the caller's runtime.
- external cancellation is selected only when a cancel token exists; there is no
  dummy long-sleep branch.
- output memory is bounded by caller-supplied byte limits.
- pipe read faults, output limits, and output allocation failures wake the owner
  through an output-fault event so the child can be killed and drained promptly.
- timeout, external cancellation, and output-fault paths have one process-wait
  owner: on POSIX they terminate the child process group with TERM, escalate to
  KILL after a bounded grace period, and then join the existing wait task
  instead of racing `Child.kill` against `Child.wait`.

`zio` is still not app policy. `coding_agent` owns shell semantics and tool
result shaping. `runtime` owns the process mechanism.

## old decision

the original accepted decision was:

```text
do not vendor zio for the first process tool; use std.process.run.
```

that decision was valid for the first parity slice, but it is no longer the
target architecture. the migration pressure now is:

```text
provider stream + process tool + cancellation + bounded completions
  -> one std.Io backend choice
  -> session/agent owners drain completions
```

vendoring a runtime must remove owned complexity. it must not become app policy.
