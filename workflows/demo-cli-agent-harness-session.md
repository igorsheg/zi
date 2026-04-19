# Demo CLI agent harness session

_Date: 2026-04-19_

This is a grounded demo of a zi-style CLI agent harness session against the current repo. It is not a fake product pitch; it is based on actual tool calls made in this workspace.

## What I did

I used a bunch of agent tools to inspect the repo and exercise the CLI surface:

- `read`
- `ls`
- `find`
- `grep`
- `bash`

I also attempted a higher-level `finder` search, but it returned no useful output in this session.

## Demo transcript

### 1) User kicks off a loose demo request

> do some demo cli agent harness session, talk back, write markdown, call a bunch of tools, go at it

### 2) Assistant orients on docs first

I read the repo docs map in `docs/README.md`.

Key takeaway:

- `docs/cli.md` is the canonical CLI contract.
- `docs/architecture.md` explains the five-layer split.

From `docs/cli.md`, the CLI is explicitly structured as:

1. action detection
2. raw parsing
3. planning
4. execution

That matters because the demo should reflect the real harness shape, not hand-wave about “some parser somewhere.”

### 3) Assistant inspects the real entrypoint

I read `src/main.zig`.

Observed flow:

- `src/main.zig:61` detects the top-level action.
- `src/main.zig:62-69` parses raw args.
- `src/main.zig:79-85` builds an execution plan.
- `src/main.zig:95-103` initializes shared runtime only when needed.
- `src/main.zig:105-119` dispatches execution and reports typed diagnostics.

That is the harness in one file: detect → parse → plan → runtime → dispatch.

### 4) Assistant inspects plan types

I read `src/coding_agent/cli/plan.zig`.

Observed contract:

- `RunPlan` is a tagged union with:
  - `interactive`
  - `batch`
- `ExecutionPlan` is a tagged union with:
  - `help`
  - `version`
  - `list_models`
  - `run`
- `SessionTarget` is explicit:
  - `none`
  - `most_recent`
  - `picker`
  - `reference`

Important validation behavior visible in code:

- batch mode requires a prompt source
- session-target flags are interactive-only
- startup prompt inputs cannot be combined with session-target flags
- conflicting selectors fail during planning instead of being silently ignored

That matches the “truthful flag doctrine” in `docs/cli.md`.

### 5) Assistant inspects built-in tool wiring

I read `src/coding_agent/tools/builtins.zig`.

The default built-in tool bundle currently includes:

1. `bash`
2. `read`
3. `write`
4. `edit`
5. `grep`
6. `find`
7. `ls`

This is the harness’s default product-layer tool set.

I also read `src/coding_agent/tools/bash.zig`.

Notable guardrails baked into the tool description:

- do not chain commands with `;` or `&&`
- do not use interactive commands
- output is head/tail truncated for large results
- use `cwd` instead of relying on persistent shell state
- do not run `git commit` or `git push` unless explicitly asked

## CLI exercised for real

### `zi --help`

I ran:

```bash
"/Users/igors/workspace/dev/personal/zi/zig-out/bin/zi" --help
```

Observed highlights:

- `zi` starts interactive mode
- `zi "prompt"` starts interactive with an initial prompt
- `zi -p "prompt"` is explicit batch text mode
- `zi --mode json "prompt"` is explicit batch JSON mode
- `zi --continue`, `--resume`, and `--session` are interactive-only session selectors
- `--list-models [search]` is a top-level action

This lines up with both `docs/cli.md` and `src/coding_agent/cli/plan.zig`.

### `zi --list-models sonnet`

I ran:

```bash
"/Users/igors/workspace/dev/personal/zi/zig-out/bin/zi" --list-models sonnet
```

Observed output included models such as:

- `anthropic claude-sonnet-4-6`
- `anthropic claude-sonnet-4-5`
- `anthropic claude-3-7-sonnet-20250219`
- `openrouter anthropic/claude-sonnet-4.6`

This is a good demo of a real non-chat CLI action that does useful work without needing to run a full model turn.

### Invalid combination: `zi --continue "hello"`

I ran:

```bash
"/Users/igors/workspace/dev/personal/zi/zig-out/bin/zi" --continue "hello"
```

Observed diagnostic:

```text
error: startup prompt inputs cannot be combined with --continue. session targets start interactively without an initial prompt
```

That is exactly the kind of planning-time diagnostic the CLI contract promises.

### Invalid batch invocation: `zi -p`

I ran:

```bash
"/Users/igors/workspace/dev/personal/zi/zig-out/bin/zi" -p
```

Observed diagnostic:

```text
error: batch mode requires a prompt source. use `zi -p "prompt"`, `zi -p @file`, `zi --mode json "prompt"`, or `cat file | zi -p`
```

Again: explicit validation, no silent fallback.

## Condensed “talk back” version

```text
user>
  do some demo cli agent harness session

assistant>
  yep — I’m going to inspect the docs, read the CLI entrypoint,
  confirm the plan types, then run a few real CLI commands.

tool(read) -> docs/README.md
  docs map says docs/cli.md is the canonical CLI contract

tool(read) -> docs/cli.md
  CLI contract is action detection -> raw parsing -> planning -> execution

tool(read) -> src/main.zig
  main does detect -> parse -> plan -> runtime init -> dispatch

tool(read) -> src/coding_agent/cli/plan.zig
  RunPlan is interactive|batch; session targets are explicit and validated

tool(read) -> src/coding_agent/tools/builtins.zig
  built-in tools are bash/read/write/edit/grep/find/ls

tool(bash) -> zi --help
  help text confirms explicit batch mode and interactive-only session selectors

tool(bash) -> zi --list-models sonnet
  real model list printed

tool(bash) -> zi --continue "hello"
  planner rejects prompt + session-target combination

tool(bash) -> zi -p
  planner rejects batch mode without a prompt source

assistant>
  done — the harness is real, typed, and opinionated:
  no heuristic mush, no silent flag dropping, and a concrete default tool bundle.
```

## Quick architecture summary from the demo

If you want the shortest accurate summary of the harness:

- **Entrypoint**: `src/main.zig`
- **CLI contract**: `docs/cli.md`
- **Plan types**: `src/coding_agent/cli/plan.zig`
- **Built-in tools**: `src/coding_agent/tools/builtins.zig`
- **Example tool implementation**: `src/coding_agent/tools/bash.zig`

## Suggested next demo if you want a bigger one

Good follow-ups would be:

1. a full batch JSON run with a faux provider fixture
2. an interactive resume/session-selector walkthrough
3. a transcript showing tool calls end-to-end through the agent loop
4. a TUI demo that maps agent events onto the current interactive surface
