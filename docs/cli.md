---
slug: cli
title: Choose a run mode
order: 10
---

# Choose a run mode

Start with who Zi is talking to:

- You in a terminal: use interactive mode.
- A shell script that needs the final answer: use text mode.
- A process consuming one finite event stream: use JSON mode.
- A process controlling a long-lived session: use RPC mode.

```sh
zi                                      # interactive when stdin and stdout are TTYs
zi -p "summarize this repository"       # final assistant text
zi --mode json "inspect package.json"   # header-first JSONL events
cat error.log | zi -p "find the cause"  # stdin, then positional prompts
zi --mode rpc --no-session              # versioned JSONL process protocol
```

## Modes

`--mode` accepts:

- `auto`: interactive only when stdin and stdout are TTYs; otherwise text;
- `interactive`: require TTY stdin and stdout;
- `text`: write only the final assistant text to stdout;
- `json`: write the session header and source-ordered events as JSONL to stdout;
- `rpc`: read version-1 JSONL requests from stdin and write ordered protocol frames to stdout.

`-p` and `--print` are aliases for `--mode text`. Text and JSON modes require a positional prompt or piped stdin. Piped stdin is bounded at 8 MiB and becomes the first prompt; positional prompts run afterward in argument order. RPC rejects positional prompts because stdin is its protocol transport.

Diagnostics and failures go to stderr, preserving stdout for text, JSON, and RPC consumers. Explicit extensions load in every mode. Text and JSON modes do not dispatch interactive or extension commands; prompt-template and skill expansion still apply to admitted input.

`--code-only` is an invocation policy available in every mode. It exposes only the `code` tool to the model while retaining the normal admitted tools inside each cell's `zi` catalog. Interactive commands remain available because they are client operations rather than model tools. Spawned Zi subagents inherit the policy. See [Code Mode](code-mode.md#code-only-invocations).

See [JSON events](json-events.md) for the finite event stream and [RPC](rpc.md) for request framing, methods, bounds, and lifecycle.

## Invocation resolution

Zi resolves one invocation before reading stdin or constructing an agent runtime:

```text
last CLI occurrence > supported ZI_* environment default > runtime/settings default
```

CLI values always win, including over an invalid value in the corresponding environment variable. A wrapper can prepend defaults and let its caller append overrides:

```sh
zi --mode json --mode text "answer with one line"  # text
zi --no-session --new-session "keep this run"      # persistent new session
```

Repeatable `--append-system-prompt` and `--extension` values accumulate instead of replacing one another. `--flag=value` and `--flag value` are equivalent. `--` ends option parsing.

| Value                  | CLI                 | Environment           | Fallback                             |
| ---------------------- | ------------------- | --------------------- | ------------------------------------ |
| Mode                   | `--mode`, `--print` | `ZI_MODE`             | `auto`                               |
| Working directory      | `--cwd`             | —                     | process cwd                          |
| Global agent directory | `--agent-dir`       | `ZI_AGENT_DIR`        | `~/.zi/agent`                        |
| Session directory      | `--session-dir`     | `ZI_SESSION_DIR`      | cwd-partitioned agent sessions       |
| Model                  | `--model`           | `ZI_DEFAULT_MODEL`    | session, settings, provider fallback |
| Thinking level         | `--thinking`        | `ZI_DEFAULT_THINKING` | session, settings, `medium`          |
| Explicit extensions    | `--extension`       | —                     | discovered project/global sources    |

Empty supported `ZI_*` values and invalid mode or thinking syntax fail before stdin is read. Model existence and filesystem validity are checked during runtime construction. `--help` and `--version` do not resolve runtime environment values.

Relative `--cwd`, `--agent-dir`, `--resume`, and `--extension` paths are resolved against the process working directory captured at startup. Leading `~` uses the captured home directory. A relative session directory is resolved later against the effective session working directory, including a resumed journal's stored directory.

Working directory, session selection, system-prompt content, and `--api-key` are argument-only so inherited environment cannot silently redirect a nested run, resume a conversation, replace agent policy, or apply a provider-ambiguous secret. Provider-native credential variables remain supported.

## Sessions

The last session selector chooses exactly one intent:

| Selector                | Intent                                    |
| ----------------------- | ----------------------------------------- |
| `--new-session`         | New persistent session                    |
| `--no-session`          | New ephemeral session                     |
| `-c`, `--continue`      | Most recent session for the effective cwd |
| `-r`, `--resume <file>` | Exact session journal                     |

In interactive mode, `/resume` opens the bounded current-project session picker and `/new` starts a fresh session.

## Copy the last assistant message

Use `/copy` in interactive mode to copy the latest committed assistant message to the clipboard. Zi copies its Markdown source text, excluding thinking and tool calls. An in-progress streaming message is not included.

## Models and credentials

```sh
zi --model provider/model-id --api-key "$KEY" "try this once"
```

`--api-key` is memory-only. It is not written to settings, credentials, events, diagnostics, or journals. Like any command-line secret, it may still be visible in shell history or process listings; prefer provider credential variables or Zi's credential store for long-lived automation.

When profile-driven subagents are active, an ephemeral parent override is forwarded privately to child Zi processes, removed from the child environment before extensions or shell tools start, and never placed in child arguments. See [Subagents](subagents.md).

## Project trust

When protected project `.zi` configuration or ancestor `.agents/skills/` exists without a stored decision, interactive mode opens a project-trust picker before running positional prompts. Its safe default keeps project configuration disabled. Trust or rejection may apply only to the current session or be saved for the canonical working directory; a saved parent decision is inherited.

Applying a choice replaces the complete working-directory-bound runtime so settings, prompts, skills, subagent profiles, and extensions share one admission decision. Text, JSON, and RPC modes never prompt and continue with unresolved project configuration excluded.

## Invocation prompt policy

Use `--system-prompt <text>` to replace the built-in prompt for the invocation. Use `--append-system-prompt <text>` repeatedly to append ordered policy. Supplying any explicit append prompt replaces discovered `APPEND_SYSTEM.md` content for that invocation:

```sh
zi --no-session \
  --system-prompt "You are a release reviewer." \
  --append-system-prompt "Return only actionable findings." \
  -p "review the current diff"
```

These values are bounded by the session-resource budget and remain active when interactive mode starts or replaces a session. See [Prompts](prompts.md) for persisted prompt resources.

## Exit behavior

Successful completion, help, and version return `0`. Configuration, admission, provider, or shutdown failure returns `1`. Headless `SIGHUP`, `SIGINT`, and `SIGTERM` return `129`, `130`, and `143` after requesting bounded cancellation and disposing the session.
