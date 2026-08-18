# Add the first pi-mono-compatible CLI core

**Status:** Implemented and verified
**Reference:** `badlogic/pi-mono` commit `ea7bfdc08bc2859cde8292655f075b37ae1da1a9`
**Scope:** Argument parsing, mode resolution, initial-message construction, and one-shot text print execution inside `coding_agent`

## Product intent

Zi now has a bounded `AgentSession` with read, write, edit, and bash. The next slice establishes the CLI interface that will eventually own process configuration, modes, session selection, and terminal startup without copying pi-mono's mature surface all at once.

The interface follows pi-mono's current production CLI, not its experimental command tree and not the older `earendil-works/pi` checkout. Names and observable semantics are kept compatible where this slice admits them. Zig ownership, error unions, explicit allocators, and `std.Io.Writer` replace TypeScript mutation and process globals.

This slice deliberately stops before provider/environment resolution. Adding a compatible endpoint or Codex credential flag without the corresponding pi-mono configuration owner would invent a second CLI. The following slice will connect the process adapter and the two existing providers through the surface established here.

## Pi-mono behavior admitted now

### Parsed arguments

Admit the stable core needed by print mode and the next provider-wiring slice:

- `--help`, `-h`
- `--version`, `-v`
- `--print`, `-p`
- `--mode text|json|rpc`
- `--provider <name>`
- `--model <pattern>`
- `--api-key <key>`
- positional messages
- `@file` classification
- unknown long flags retained as `name = true|string` for future extension flags
- unknown short flags recorded as errors

Parsing is one left-to-right pass. Repeated scalar flags use the last value. `-p` may consume the immediately following prompt, does not consume an `@file` or ordinary option, and accepts a prompt beginning with `---`, matching pi-mono `src/cli/args.ts:65-225`.

Unlike pi-mono's accidental silent handling for some missing values, every admitted value flag records a diagnostic when its value is absent. This is the external-input boundary and is intentionally stricter without changing valid invocations.

Arguments and retained values are UTF-8 validated. Admit at most 64 arguments, 256 KiB per argument, and 1 MiB total. Parsed strings borrow argv; `Args` owns only its index/diagnostic collections and has one `deinit` boundary.

### Mode resolution

Keep pi-mono's exact application-mode precedence:

```text
--mode rpc                       -> rpc
else --mode json                 -> json
else --print                     -> print
else stdin is not TTY            -> print
else stdout is not TTY           -> print
else                             -> interactive
```

`--mode text` does not force print mode on a full TTY. This distinction matters when interactive mode arrives.

The public closed types are:

```zig
pub const Mode = enum { text, json, rpc };
pub const AppMode = enum { interactive, print, json, rpc };
```

Only text print execution is implemented in this slice. JSON, RPC, and interactive are represented by the stable mode vocabulary but are not advertised as working Zi modes until their implementations exist.

### Initial message

`buildInitialMessage` follows pi-mono `src/cli/initial-message.ts`:

1. Piped stdin.
2. Processed `@file` text.
3. First positional message.

The present pieces are concatenated with no invented delimiter. The result returns the remaining positional messages without mutating `Args`. The combined text has one explicit allocation/deinit boundary.

Actual stdin reading and `@file` processing are deferred to the process adapter and file-input slices. Tests inject those already-processed byte slices; the composition owner still rejects invalid UTF-8, more than 64 positional messages, and any prompt above 8 MiB before model admission.

### Text print mode

`runPrintMode` borrows an existing `AgentSession` and output writers. It:

1. Prompts with the initial message when present.
2. Prompts with each remaining message sequentially.
3. Writes only the final assistant text to stdout, followed by one newline.
4. Writes a settled run error to stderr and returns failure status.
5. Emits nothing and succeeds when there was no prompt.

The caller that created `AgentSession` remains its owner and deinitializes it after `runPrintMode` settles. This differs from pi-mono's garbage-collected runtime-host shape while preserving its prompt and output behavior.

JSON event output, signal ownership, runtime rebinding, extensions, and detached-child cleanup are not part of the first mode implementation.

## Public module interface

Add `coding_agent.cli` with a narrow curated interface corresponding to pi-mono's exported parser and print mode:

```zig
pub const Args;
pub const Diagnostic;
pub const Mode;
pub const AppMode;
pub const UnknownFlag;
pub const UnknownFlagValue;
pub const InitialMessage;
pub const PrintModeOptions;
pub const ExitCode;

pub fn parseArgs(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) error{OutOfMemory}!Args;

pub fn resolveAppMode(
    args: *const Args,
    stdin_is_tty: bool,
    stdout_is_tty: bool,
) AppMode;

pub fn buildInitialMessage(
    allocator: std.mem.Allocator,
    messages: []const []const u8,
    stdin_content: ?[]const u8,
    file_text: ?[]const u8,
) error{OutOfMemory}!InitialMessage;

pub fn runPrintMode(
    session: *AgentSession,
    options: PrintModeOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) std.Io.Writer.Error!ExitCode;
```

`runPrintMode` currently accepts only text output. `PrintModeOptions` does not gain placeholder image or JSON fields before those canonical capabilities exist.

The process-level `run(init: std.process.Init)` entrypoint is intentionally not exposed yet. Its implementation needs the next slice's concrete provider/configuration owner; publishing it now would either hide invented environment rules or require a speculative factory seam.

## Program design

```text
src/coding_agent/
  root.zig                         # exports cli
  cli/
    root.zig                       # curated CLI interface and integration tests
    args.zig                       # argv owner/parser and mode resolution
    initial_message.zig            # prompt composition owner
    print_mode.zig                 # AgentSession-to-writer execution
```

Call path:

```text
future src/main.zig
  std.process.Args.toSlice(process arena)
  coding_agent.cli.parseArgs
  future provider/config resolution
  AgentSession.init
  coding_agent.cli.buildInitialMessage
  coding_agent.cli.runPrintMode
  AgentSession.deinit
```

No CLI manager, command registry, provider switch in the agent loop, generic runtime host, or output abstraction is introduced. `std.Io.Writer` is the existing output seam; `ai.Model` remains the model test seam.

## Behavior tests

1. Parse help/version/print and last-wins provider/model/api-key values.
2. Preserve pi-mono `-p` prompt consumption, `@file`, YAML-frontmatter, positional-message, and unknown-flag behavior.
3. Record missing-value, invalid-mode, invalid UTF-8, unknown-short-option, and bound diagnostics without exposing secret values.
4. Resolve every application-mode precedence branch, including `--mode text` on a TTY.
5. Combine stdin, file text, and first positional message without separators; retain later messages.
6. Run initial and remaining messages sequentially through a real `AgentSession` backed by `ScriptedModel`.
7. Print only the final response to stdout.
8. Keep stderr empty on success; return failure and write only stderr on agent failure.
9. Succeed silently with no prompt.
10. Verify caller-owned session lifetime remains valid until explicit deinit and all allocations are leak-free.

## Deferred pi-mono surface

- Process-level provider and credential resolution.
- Replacing `src/main.zig` with the CLI adapter.
- Piped-stdin reading and TTY detection at the process edge.
- `@file` text/image processing.
- JSON event mode and its schema.
- RPC mode and client exports.
- Interactive mode and TUI startup.
- Persistent sessions, resume/continue/fork, and naming.
- System prompt overrides and context-file discovery.
- Tool allow/deny flags.
- Extensions, skills, prompt templates, themes, and extension flag consumption.
- Model catalogs, `--models`, thinking syntax, and `--list-models`.
- Export/package/config/auth commands.
- Project trust, migrations, settings, and offline startup behavior.
- Signal handling and process-tree ownership.

These are additions to the same interface, not alternate Zi-specific commands.

## Acceptance

- `coding_agent.cli` exposes pi-mono-compatible core vocabulary and valid invocation behavior.
- One-shot text mode exercises the real `AgentSession` through its public interface and keeps stdout clean.
- The next provider/process slice can consume `Args` without renaming flags or replacing the parser.
- No provider support is added beyond the existing OpenAI-compatible and OpenAI Codex implementations.
- Build, debug and ReleaseSafe tests, lint, diff checks, and independent review pass.

**Verification:** `zig build`; 111/111 debug and ReleaseSafe tests; `ziglint`; `git diff --check`; independent re-review with no findings.
