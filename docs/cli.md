# CLI

Zi can run as an interactive terminal product or as a headless process primitive.

```sh
zi                                      # interactive when stdin and stdout are TTYs
zi -p "summarize this repository"       # final assistant text
zi --mode json "inspect package.json"   # header-first JSONL events
cat error.log | zi -p "find the cause"  # stdin, then positional prompts
```

## Resolution

Zi resolves one invocation before reading stdin or constructing an agent runtime:

```text
last CLI occurrence > supported ZI_* environment default > runtime/settings default
```

CLI values always win, including over an invalid value in the corresponding environment variable. This lets a wrapper prepend defaults and let its caller append overrides:

```sh
zi --mode json --mode text "answer with one line"  # text
zi --no-session --new-session "keep this run"      # persistent new session
```

Repeatable `--append-system-prompt` values accumulate instead of replacing one another. `--flag=value` and `--flag value` are equivalent. `--` ends option parsing.

| Value                  | CLI                 | Environment           | Fallback                             |
| ---------------------- | ------------------- | --------------------- | ------------------------------------ |
| Mode                   | `--mode`, `--print` | `ZI_MODE`             | `auto`                               |
| Working directory      | `--cwd`             | —                     | process cwd                          |
| Global agent directory | `--agent-dir`       | `ZI_AGENT_DIR`        | `~/.zi/agent`                        |
| Session directory      | `--session-dir`     | `ZI_SESSION_DIR`      | cwd-partitioned agent sessions       |
| Model                  | `--model`           | `ZI_DEFAULT_MODEL`    | session, settings, provider fallback |
| Thinking level         | `--thinking`        | `ZI_DEFAULT_THINKING` | session, settings, `medium`          |

Empty supported `ZI_*` values and invalid mode or thinking syntax fail before stdin is read. Model existence and filesystem validity are checked by their coding-agent owners during runtime construction. `--help` and `--version` do not resolve runtime environment values.

Relative `--cwd`, `--agent-dir`, and `--resume` paths are resolved against the process cwd captured at startup. Leading `~` uses the captured home directory. A relative session directory is resolved later against the effective session cwd, including a resumed journal's stored cwd.

Cwd, session selection, system-prompt content, and `--api-key` are intentionally argument-only so inherited environment cannot silently redirect a nested run, resume a conversation, replace agent policy, or apply a provider-ambiguous secret. Provider-native credential variables such as `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` remain supported by Pi AI.

`--api-key` is memory-only in Zi: it is not written to settings, credentials, events, diagnostics, or journals. Like any command-line secret, it may still be visible in shell history or process listings; prefer provider credential variables or Zi's credential store for long-lived automation.

## Modes

`--mode` accepts:

- `auto`: interactive only when stdin and stdout are TTYs; otherwise text;
- `interactive`: require TTY stdin and stdout;
- `text`: write only the final assistant text to stdout;
- `json`: write the session header and source-ordered events as JSONL to stdout.

`-p` and `--print` are aliases for `--mode text`. RPC remains reserved but is not implemented yet.

Headless modes require a positional prompt or piped stdin. Piped stdin is bounded at 8 MiB and becomes the first prompt; positional prompts run afterward in argument order. Diagnostics and failures go to stderr, preserving text and JSON stdout protocols.

## Sessions

The last session selector chooses exactly one intent:

| Selector                | Intent                                    |
| ----------------------- | ----------------------------------------- |
| `--new-session`         | New persistent session                    |
| `--no-session`          | New ephemeral session                     |
| `-c`, `--continue`      | Most recent session for the effective cwd |
| `-r`, `--resume <file>` | Exact session journal                     |

## Invocation prompt policy

Use `--system-prompt <text>` to replace the built-in prompt for the invocation. Use `--append-system-prompt <text>` repeatedly to append ordered policy. Supplying any explicit append prompt replaces discovered `APPEND_SYSTEM.md` content for that invocation:

```sh
zi --no-session \
  --system-prompt "You are a release reviewer." \
  --append-system-prompt "Return only actionable findings." \
  -p "review the current diff"
```

These values are bounded by the coding-agent session-resource budget and remain active when the interactive mode starts or replaces a session.

## Exit behavior

Successful completion, help, and version return `0`. Configuration, admission, provider, or shutdown failure returns `1`. Headless `SIGHUP`, `SIGINT`, and `SIGTERM` return `129`, `130`, and `143` after requesting bounded cancellation and disposing the session.

The architecture and rationale are recorded in [ADR 0020](adr/0020-cli-invocation-resolves-once-from-explicit-layers.md).
