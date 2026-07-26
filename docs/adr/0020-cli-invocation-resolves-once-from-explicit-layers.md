# ADR 0020: CLI invocation resolves once from explicit layers

## Status

Accepted.

## Context

Zi is both a terminal product and a process primitive. A wrapper, shell pipeline, CI job, or future product must be able to select a stable output protocol and runtime context without inheriting accidental terminal behavior or relying on ambient reads deep in runtime construction.

Pi coding-agent at the pinned `0e6909f0` revision keeps invocation flags separate from durable settings, gives explicit `--api-key` precedence over provider authentication, infers print mode from TTY state, and resolves session storage as `--session-dir`, then `PI_CODING_AGENT_SESSION_DIR`, then settings. Most operational flags deliberately have no environment equivalent. Relevant sources are `src/cli/args.ts`, `src/main.ts`, `src/config.ts`, and `docs/settings.md`.

Zi already exposed interactive, text, and JSON modes, but argument parsing also read `process.cwd()`, `ZI_AGENT_DIR` remained a later coding-agent read, supported runtime options had no CLI path, and the precedence between `--print`, `--mode`, TTY inference, settings, and environment was only implicit.

Mirroring every flag into an environment variable would not fix this. Ambient session selection and prompt content are hazardous when inherited by child processes, while a generic `ZI_API_KEY` is provider-ambiguous and would propagate a secret into nested Zi runs.

## Decision

The CLI resolves one immutable **CLI invocation** before runtime construction.

Resolution has two phases:

1. parse argument-owned intent without reading the environment or process cwd;
2. resolve supported environment defaults and process facts supplied by the CLI host.

`--help` and `--version` finish after phase one, so broken runtime configuration cannot prevent metadata commands. Argument syntax, empty supported environment values, and invalid mode or thinking syntax fail on stderr before stdin is consumed. Domain validation that requires coding-agent owners occurs during runtime construction.

### Precedence

For scalar invocation values:

```text
last CLI occurrence > supported ZI_* environment value > lower owner policy
```

The lower owner is specific to the value: captured process cwd, the default Zi path, resumed journal context, layered settings, model discovery, or TTY inference. Environment values are defaults, not a second argument stream. Empty values and invalid enum syntax are rejected during invocation resolution; model existence and filesystem validity remain runtime-owned and may fail after piped stdin is read.

The admitted environment defaults are intentionally small:

| Value                  | CLI                 | Environment           | Lower policy                                                |
| ---------------------- | ------------------- | --------------------- | ----------------------------------------------------------- |
| Product mode           | `--mode`, `--print` | `ZI_MODE`             | `auto`, inferred from stdin/stdout TTY facts                |
| Effective cwd          | `--cwd`             | —                     | process cwd captured by the CLI host                        |
| Global agent directory | `--agent-dir`       | `ZI_AGENT_DIR`        | `$HOME/.zi/agent`                                           |
| Session storage        | `--session-dir`     | `ZI_SESSION_DIR`      | cwd partition under the global agent directory              |
| Model override         | `--model`           | `ZI_DEFAULT_MODEL`    | resumed journal, settings, then available-provider fallback |
| Thinking override      | `--thinking`        | `ZI_DEFAULT_THINKING` | resumed journal, settings, then `medium`                    |

`--api-key` remains CLI-only and memory-only. It requires an explicit or settings-resolved model and outranks stored and provider-environment authentication for that provider. Long-lived automation should use the provider-native credential variables supported by Pi AI or Zi's credential store; Zi does not introduce a provider-ambiguous generic secret variable.

System-prompt replacement and ordered appended prompt text are invocation content, so they remain explicit `--system-prompt` and repeatable `--append-system-prompt` arguments. Supplying any explicit append prompt replaces discovered `APPEND_SYSTEM.md` content for that invocation. Session operations also remain argument-only:

```text
new persistent | new ephemeral | continue recent | resume exact file
```

`--new-session`, `--no-session`, `--continue`, and `--resume` select one member of that union. The last selector wins, allowing a composing wrapper to prepend a default and let its caller append an override without constructing an invalid flag combination. The same closed `new | continue | resume` intent is the coding-agent SDK boundary; persistence exists only on the `new` state.

### Modes and argument composition

The mode preference is `auto | interactive | text | json`. `--print` is exactly an alias for `--mode text`, not a second boolean. Later scalar flags win, `--flag=value` and `--flag value` are equivalent, repeatable appended prompts preserve order, and `--` ends option parsing.

`auto` selects interactive mode only when both stdin and stdout are TTYs; otherwise it selects text. Explicit interactive mode rejects non-TTY stdin or stdout instead of trying to initialize a broken terminal. Explicit text and JSON never load the TUI. JSON keeps stdout protocol-clean and all diagnostics use stderr.

The resolved invocation is translated once into `CreateAgentRuntimeOptions`. Cwd, global agent directory, and resume file are canonicalized against the CLI host's captured cwd and home before stdin is read. A relative session directory remains unresolved until `ZiPaths` knows the authoritative resumed cwd; leading `~` is still expanded at CLI admission. Coding-agent owners receive explicit selected paths and overrides and do not re-read CLI configuration.

SDK callers may construct runtime options directly without depending on the CLI. Runtime construction snapshots the session intent, settings override, and append-prompt array before asynchronous work. `AgentSessionRuntime` retains the same owned snapshot for replacements and replaces its base `agentDir` with the initial runtime's canonical `ZiPaths.globalDir`, so caller mutation or later ambient path changes cannot redirect later sessions.

The implementation stays direct: a concrete parser, a concrete resolver, and the closed mode/session unions. Zi does not add a generic option registry or configuration framework before extension flags create repeated pressure for one.

## Consequences

- Wrappers can set stable environment defaults while end users override them with appended CLI flags.
- Session continuation, ephemeral execution, cwd, API keys, and prompt content cannot change merely because a child inherited generic Zi environment state.
- Help and version remain cheap and independent of runtime environment validity.
- New CLI capabilities must be classified as invocation operations, environment-worthy process defaults, durable settings, or coding-agent policy instead of automatically joining every layer.
- Adding an environment default requires a matching explicit flag, validation, help and documentation entries, and precedence tests.
- `ZI_SESSION_DIR` replaces the previously undocumented gap between the public runtime option and the CLI; `ZI_AGENT_DIR` now enters runtime construction through the resolved invocation rather than a later ambient read.
- `ZI_MODEL` and `ZI_REASONING_LEVEL` remain available for future dynamic shell-session metadata. Invocation defaults use `ZI_DEFAULT_MODEL` and `ZI_DEFAULT_THINKING` instead.
