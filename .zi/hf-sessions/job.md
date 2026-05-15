# zi job model: make it work, make it right, make it fast

We made it work. Now make it right. Then make it fast.

This note records the job/process extension model after adding tool-scoped `zi.job` support, and the design direction for hardening it using the TigerBeetle mindset from `.zi/hf-sessions/tigerbeetle.md`.

## Why this exists

Autoresearch exposed a gap in zi's extension system.

Existing extensions such as finder, task, and code-review worked because they stream semantic AI/session events. They can keep state in Lua and call `ctx.update(...)` when model or side-agent events arrive.

Autoresearch is different. It needs host process streaming:

```text
start benchmark command
receive stdout/stderr while it runs
publish live tail with ctx.update
observe exit status
parse METRIC lines
run checks conditionally
kill on timeout or abort
return final structured result
```

Before this change, zi had the pieces split across contexts:

```text
ctx.update   available in model-visible tools
zi.system    available in model-visible tools, but aggregate/blocking
zi.job       streaming/evented, but interactive/session scoped only
```

The missing seam was:

```text
tool-scoped host process completions
```

## What works now

`zi.job` can now be used inside model-visible tool execution.

Shape:

```lua
local job = zi.job.start({
  argv = { "/bin/sh", "-c", command },
  cwd = ctx.cwd,
})

while true do
  local ev = zi.job.next(job, { timeout_ms = 250 })

  if ev == nil then
    ctx.update(...)
  elseif ev.type == "stdout" then
    append_stdout(ev.data)
  elseif ev.type == "stderr" then
    append_stderr(ev.data)
  elseif ev.type == "exit" then
    break
  end
end
```

Semantics added:

```text
zi.job.start in a tool scope creates a tool-scoped job
zi.job.next drains one completion from that job
zi.job.write writes stdin to tool-scoped or dispatcher-backed jobs
zi.job.stop stops tool-scoped or dispatcher-backed jobs
tool-scoped jobs are cleaned up when they exit or when the runner is destroyed
```

This fixed autoresearch's immediate issue: `run_experiment` can stream stdout/stderr from `autoresearch.sh`, publish progress, and return parsed metrics.

## Why the direction is right

The design follows the TigerBeetle-style rule:

```text
submit explicit operation
receive explicit completion
owner drains completions
owner mutates state
owner controls time
bounds are explicit
shutdown is explicit
```

`zi.job.next(...)` is the important shape. It avoids raw callback ownership and keeps the tool coroutine as the owner of job state.

Good:

```lua
local ev = zi.job.next(job, { timeout_ms = 250 })
-- owner decides how to mutate state and whether to call ctx.update
```

Avoid as the primitive:

```lua
child.stdout:on("data", function(bytes)
  -- callback ownership unclear
end)
```

Callbacks may be ergonomic later, but they should be implemented on top of the same scoped completion model, not as raw process ownership handed to Lua.

## Current architecture

Public API surface:

```text
zi.system  aggregate host command, returns final stdout/stderr/status
zi.job     owned host process, exposes completions
zi.spawn   delegated child zi/agent execution
ctx.update current in-flight tool preview
```

Current implementation split:

```text
interactive command job:
  zi.job.start -> async dispatcher / runtime job manager
  stdout/stderr/exit -> global job events via zi.on("job_*")

tool-scoped job:
  zi.job.start -> ToolJob owned by ExtensionRunner
  stdout/stderr/exit -> zi.job.next(job, ...)
```

This is acceptable as the "make it work" stage. The public primitive is unified; internals are not yet fully unified.

## What is still wrong

### 1. Tool jobs are runner-scoped, not tool-call scoped

Current owner:

```text
ExtensionRunner.tool_jobs
```

Better owner:

```text
ToolExecutionContext.job_scope
```

Invariant wanted:

```text
when a tool call ends, every job started by that tool call is stopped and cleaned up
```

Runner cleanup is too coarse. Job lifetime should be tied to the execution scope that created it.

### 2. `ToolJob` lives in `runner.zig`

This was expedient.

Better boundary:

```text
src/coding_agent/extensions/job_scope.zig
```

`ExtensionRunner` should own a narrow `JobScope` or reference one through `ToolExecutionContext`, not the process implementation directly.

### 3. One reactor per tool job

Current implementation creates one `process_reactor.Reactor` per tool-scoped job.

This is okay for correctness but not the final shape.

Better shape:

```text
one process reactor per execution/runtime scope
many jobs registered in it
job completions routed by id
owner drains completions
```

TigerBeetle reference: one event loop owns many in-flight operations.

### 4. Tool-side pending events are not explicitly bounded

Current shape uses a pending list.

Need explicit policy:

```text
max pending events
max pending bytes
stdout/stderr chunks may be dropped/coalesced
exit is never dropped
output_dropped completion is emitted when loss occurs
```

Progress output is lossy. Lifecycle output is not.

### 5. Timeout is caller-owned

Autoresearch currently owns benchmark deadlines in Lua.

`zi.job.start` should eventually support process lifetime deadlines:

```lua
zi.job.start({ argv = ..., timeout_ms = 600000 })
```

Then timeout becomes a host-owned process property, not convention in each extension.

### 6. `zi.system` still has separate process plumbing

Target:

```text
zi.system = zi.job.start + drain completions to aggregate result
```

Or, if renaming later:

```text
zi.run = aggregate wrapper over zi.job
```

Do not maintain two process substrates long-term.

### 7. `zi.job.next` is local-only

Currently `zi.job.next` works for tool-scoped jobs. Interactive/session jobs still use global `zi.on("job_stdout")` events.

This is acceptable if the scope distinction is explicit, but the error messages and docs should say so.

Longer-term options:

```text
A. make zi.job.next work for all local handles regardless of scope
B. keep next only for scoped/foreground jobs and document global events for session/background jobs
```

Do not leave it accidental.

## Desired final model

Introduce an explicit execution scope concept.

```zig
const ExtensionExecutionScope = struct {
    kind: enum { tool, command, event, context_hook },
    signal: cancel.Token,
    update_sink: ?ToolUpdateSink,
    jobs: ?JobScope,
    capabilities: Capabilities,
};
```

Capabilities are policy, not accidents:

```text
tool scope:
  can start tool-scoped jobs
  can drain completions with zi.job.next
  can call ctx.update
  jobs auto-clean on tool end

command scope:
  can start session/background jobs
  can observe global job events
  can use UI if interactive

event/context scope:
  no long-running jobs by default
  maybe short aggregate zi.system/zi.run with tight bounds
```

## Public API direction

Keep the arsenal small.

Current names:

```text
zi.system  aggregate process result
zi.job     process handle/completion primitive
zi.spawn   child zi/agent run
ctx.update tool preview
```

Possible nuclear rename later:

```text
zi.run          aggregate process result
zi.job          process handle/completion primitive
zi.agent.spawn  child zi/agent run
ctx.update      tool preview
```

Do not add a parallel `ctx.process`, `zi.streaming_system`, or `tool.subprocess` API. Scope and capability should be part of `zi.job`, not separate surface area.

## Use-case derivation

### Quick shell query

```lua
local r = zi.system({ "git", "status", "--short" }, { cwd = ctx.cwd })
```

Needs aggregate result only.

### Long benchmark with progress

```lua
local job = zi.job.start({ argv = { "./bench.sh" }, cwd = ctx.cwd })
while true do
  local ev = zi.job.next(job, { timeout_ms = 250 })
  update_tail(ev)
  ctx.update(...)
  if ev and ev.type == "exit" then break end
end
```

Needs process completions and tool preview updates.

### Background UI helper

```lua
local job = zi.job.start({ argv = ..., stdout = { mode = "ui_frame", ... } })
-- command returns; job continues; UI/job events are observed globally
```

Needs session/background scope.

### Finder/task/code-review

These stream semantic AI/session events, not raw host process output.

They should continue to use:

```text
ctx.ai
zi.spawn / future zi.agent.spawn
ctx.update
```

Do not force semantic agent streams through `zi.job`.

## Make it right checklist

1. Move job scope implementation out of `runner.zig`.
2. Add `ToolExecutionContext.job_scope`.
3. Auto-stop/cleanup tool-scoped jobs at tool return, abort, and extension reload.
4. Add explicit pending event/byte bounds.
5. Ensure exit completion is never dropped.
6. Add `timeout_ms` to job start for host-owned process deadlines.
7. Improve `zi.job.next` errors for non-local/background jobs.
8. Make `zi.system` aggregate over the same job substrate.
9. Add docs that distinguish foreground scoped jobs from session/background jobs.
10. Add tests for abort cleanup, timeout cleanup, output dropping, stderr/stdout ordering tolerance, and job cleanup on tool runtime error.

## Make it fast checklist

Only after correctness/lifecycle hardening:

1. Replace one-reactor-per-tool-job with scoped/shared process reactor.
2. Route many jobs through one owner completion queue.
3. Coalesce stdout/stderr chunks under pressure.
4. Avoid per-event heap allocation where possible.
5. Add queue lag/drop telemetry.
6. Benchmark autoresearch and shell-heavy extension workloads.

## Core invariant

The invariant to preserve:

```text
Lua owns orchestration.
Zi owns host resources.
Lua drains zi-owned completions.
```

This gives pi-mono-level capability without copying pi-mono's extension-owned raw process lifecycle.
