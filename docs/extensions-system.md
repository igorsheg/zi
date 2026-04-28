# extension system command api

## status

contract for the first `zi.system` vertical slice.

this follows [extensions.md](./extensions.md), [runtime.md](./runtime.md), [extensions-lifecycle.md](./extensions-lifecycle.md), and [extensions-jobs-subagents.md](./extensions-jobs-subagents.md).

## decision

`zi.system` is a Neovim-inspired, zi-native way for extensions to run bounded OS commands through the host scheduler.

it is not a raw process API. extensions do not receive process handles, pipes, worker callbacks, or terminal ownership.

## api

```lua
zi.register_command({
  name = "git-status",
  handler = function(_, ctx)
    local result = zi.system({ "git", "status", "--short" }, {
      cwd = ctx.cwd,
      timeout_ms = 5000,
    })
  end,
})
```

### command form

commands are argv arrays only:

```lua
zi.system({ "git", "status", "--short" })
```

there is no implicit shell string form. if shell behavior is required, invoke a shell explicitly:

```lua
zi.system({ "/bin/sh", "-c", "echo $HOME" })
```

### options

```lua
{
  cwd = ctx.cwd,
  stdin = "optional input",
  env = { FOO = "bar" },
  clear_env = false,
  timeout_ms = 10000,
  max_stdout_bytes = 1024 * 1024,
  max_stderr_bytes = 1024 * 1024,
  text = true,
}
```

`text = true` normalizes CRLF line endings to LF.

`env` overlays the inherited process environment by default. `clear_env = true` runs with only the supplied environment.

### result

completed process, including non-zero exit:

```lua
{
  status = "completed",
  code = 0,
  signal = nil,
  stdout = "...",
  stderr = "...",
}
```

non-zero exit is still `status = "completed"`; inspect `code`.

spawn/runtime error:

```lua
{
  status = "error",
  error = "spawn failed: FileNotFound",
  stdout = "",
  stderr = "",
}
```

timeout:

```lua
{
  status = "timeout",
  error = "timed out after 5000ms",
  stdout = "...partial...",
  stderr = "...partial...",
}
```

## scheduler contract

`zi.system` is yieldable. it must run from a yieldable extension execution context, such as a command handler using the command coroutine scheduler.

load/register code must not call `zi.system`; extension load remains cheap and deterministic.

implementation routing:

```text
lua zi.system
  -> typed async request
  -> worker thread process runner
  -> mailbox result
  -> agent/lua owner thread resumes coroutine
```

workers never call Lua.

## relationship to tools and jobs

`zi.system` is extension-author code, not model tool execution. it does not inherit bash-tool prompt rules, transcript formatting, git trailer injection, or tool-call permission behavior.

future retained job/process APIs can build on the same process runner when extensions need streaming, cancellation handles, detached processes, watchers, or progress UI.

## non-goals

v1 does not expose:

- shell string shorthand.
- callbacks.
- stdout/stderr streaming.
- process handles or `kill`/`write` methods.
- detached background processes.
- pty or interactive terminal ownership.
- file watchers.
- user-bash interception.
