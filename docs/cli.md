# CLI actions, execution plans, and nuclear cutover doctrine

## status

accepted for `zi-k9f`.

this document is the contract for the CLI refactor.

## intent

Replace the current CLI mental model with explicit types and explicit planning.

This is a **nuclear refactor**:

- no backward-compat wrapper around the current CLI architecture
- no new facade that still uses old `RunOptions` as the real model underneath
- no boolean dispatch heuristics deciding behavior after parse
- no accepted flag that is silently ignored later
- no `std.process.exit()` below `main.zig`
- if lower-layer seams are awkward, refactor those seams instead of encoding CLI policy in the wrong layer

The refactor is complete only when the old implicit mode-inference path is deleted.

## problem

The current CLI's failure is not just parser syntax.

The deeper problem is that behavior emerges from incidental fields and boolean algebra:

- parse fills a broad `RunOptions` bag
- dispatch decides behavior from combinations such as prompt presence, mode, or continue state
- lower layers still perform CLI policy and process exits
- some flag combinations are accepted long before it is clear whether they are meaningful, valid, or ignored

That architecture produces untruthful UX.

A truthful CLI has one clear rule:

> syntax parsing records what the user typed. planning decides what the program will do.

## product contract

The CLI contract this refactor must preserve and clarify is:

- `zi` → interactive
- `zi "prompt"` → interactive with an initial prompt
- `zi -p "prompt"` → batch text and exit
- `zi --mode json "prompt"` → batch JSON and exit
- `zi --continue` → interactive resume of the most recent session for the current project
- `zi --resume` → interactive session picker
- `zi --session <path|id>` → interactive resume of a specific session by path or ID prefix
- `zi --list-models [search]` → list available models, optionally narrowed by fuzzy search

Additional contract rules:

- batch text mode prints the final assistant text only after completion
- batch JSON mode emits a session header first when session persistence is enabled, then JSON event lines
- batch text failures derive from the final assistant stop reason / error state, not incidental stream chatter
- the **default action is `run`**
- session-targeting flags are explicit and validated
- session targets are **interactive-only** and **mutually exclusive**
- prompt and session-target combinations must have defined semantics or be rejected
- no prompt/flag combination may be silently dropped, reinterpreted, or ignored
- help/version/list-models are top-level actions, not side effects of run-mode heuristics

## decision

The CLI is split into four explicit stages:

1. **action detection** — determine the top-level action
2. **raw parsing** — parse syntax into action-specific raw argument structs
3. **planning** — convert raw args into a validated execution plan
4. **execution** — execute the already-validated plan against a shared CLI runtime

The split is mandatory.

## 1. action detection is separate from run planning

Top-level action detection answers only:

- are we running `help`?
- `version`?
- `list_models`?
- or the default `run` action?

It does **not** decide whether `run` becomes interactive or batch.

That decision belongs to planning.

The intended shape is:

```zig
pub const Action = enum {
    run,
    help,
    version,
    list_models,
};
```

Rules:

- action detection operates on argv as given
- `run` is the fallback when no more specific action wins
- help detection is action-oriented: generic help is only the fallback when a more specific action was not requested
- action selection must stay explicit and typed

## 2. raw parsing is syntax only

Raw parsing records what the user passed for the selected action.

Raw arg structs may contain:

- booleans for presence of switches
- optional values for valued flags
- raw positionals exactly as typed

Raw arg structs must **not** contain policy decisions such as:

- "this means batch"
- "this prompt should be ignored"
- "this flag is interactive-only so keep it around and maybe drop it later"

Illustrative split:

```zig
pub const RawRunArgs = struct {
    print_mode: bool = false,
    mode: ?OutputMode = null,
    api_key: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    positionals: []const []const u8 = &.{},
    continue_session: bool = false,
    resume_picker: bool = false,
    session_ref: ?[]const u8 = null,
    no_session: bool = false,
    tools_filter: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
};
```

Syntax failures remain parser diagnostics.

Examples:

- missing value for `--model`
- unknown flag
- invalid enum-like flag value such as an unknown `--mode`

## 3. planning owns semantic validation

Planning converts raw args into a typed `ExecutionPlan`.

Planning owns all semantic policy:

- whether `run` becomes interactive or batch
- whether a prompt is required
- whether a prompt is allowed with a session target
- whether two selectors conflict
- whether a flag is unsupported for the selected action
- whether accepted syntax leads to an invalid meaning

Executors must not rediscover policy by branching on leftover raw fields.

### required plan split

The CLI must make the run split explicit in types.

```zig
pub const OutputMode = enum {
    text,
    json,
};

pub const SessionTarget = union(enum) {
    none,
    most_recent,
    picker,
    reference: []const u8,
};

pub const RunPlan = union(enum) {
    interactive: InteractivePlan,
    batch: BatchPlan,
};

pub const InteractivePlan = struct {
    initial_prompt: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    session_target: SessionTarget = .none,
    no_session: bool = false,
    tool_allowlist_csv: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
};

pub const BatchPlan = struct {
    output: OutputMode,
    prompt: []const u8,
    api_key: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    no_session: bool = false,
    tool_allowlist_csv: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
};

pub const ListModelsPlan = struct {
    search: ?[]const u8 = null,
};

pub const ExecutionPlan = union(enum) {
    help: HelpPlan,
    version: VersionPlan,
    list_models: ListModelsPlan,
    run: RunPlan,
};
```

The exact field set may grow, but the architecture rule is fixed:

- a batch plan requires a prompt
- an interactive plan may have an initial prompt
- batch output mode is explicit
- session targeting is explicit
- session targets are interactive-only and mutually exclusive
- unsupported or ambiguous combinations are rejected before execution

### diagnostics split

Diagnostics are also split by layer.

- **parse diagnostics** = syntax failed
- **plan diagnostics** = syntax parsed, but the requested meaning is invalid

That split is required because "missing a flag value" and "this combination has no defined semantics" are different failures.

Illustrative plan diagnostics include:

- `too_many_positionals`
- `prompt_required_for_batch`
- `prompt_not_allowed_for_session_target`
- `session_target_requires_interactive`
- `conflicting_batch_selectors`
- `conflicting_session_selectors`
- `unsupported_flag_for_action`
- `invalid_flag_combination`

## 4. executors consume validated plans

Execution begins only after planning succeeds.

Executors receive:

- the selected action as a typed plan
- a shared CLI runtime with bootstrapped dependencies
- no leftover heuristic branching to decide interactive vs batch vs utility action

Allowed executor behavior:

- do the work represented by the plan
- return typed outcomes or typed errors
- emit user-facing diagnostics through dedicated writers

Forbidden executor behavior:

- infer action or mode from incidental fields
- silently ignore fields that survived planning
- call `std.process.exit()`

## shared CLI runtime

The CLI must stop rebuilding auth/settings/model-registry/cwd bootstrap separately in each action module.

A shared runtime owns common CLI dependencies such as:

- allocator
- cwd
- auth storage
- settings manager
- model registry

This is composition-root work and belongs in one owned bootstrap surface.

The runtime exists to remove repeated drift between:

- interactive run
- batch run
- list-models
- future CLI actions

## typed outcome and exit flow

Lower CLI modules return typed outcomes.

Only `main.zig` owns process exit.

Required rule:

- no `std.process.exit()` below `main.zig`

This keeps:

- testability higher
- error reporting more uniform
- action modules reusable as normal program surfaces instead of hidden process terminators

Whether the implementation uses typed errors, a `CliExit`, a `CliResult`, or a similarly explicit outcome type is secondary.

The invariant is primary:

- lower layers report
- `main.zig` maps that report to exit code and stderr/stdout behavior

## truthful flag doctrine

Every accepted flag must do one of two things:

1. affect the execution plan, or
2. produce a diagnostic during planning

There is no third category.

In particular, the refactor forbids:

- interactive-only flags that are accepted and then ignored in batch
- batch selectors that are accepted but later collapse back to interactive
- prompt text that changes meaning because unrelated booleans happened to be present
- session-targeting flags whose prompt semantics are left undefined

## no compatibility layer for current mode inference

This is the negative rule that guards the whole epic.

The refactor must **not** preserve current mode inference behind a nicer façade.

That means:

- no planner that merely fills old `RunOptions`
- no dispatcher that still decides behavior with logic equivalent to `if prompt or json or continue then batch`
- no wrapper layer that renames current concepts while preserving the same implicit behavior underneath
- no compatibility shim whose real effect is "accept cursed input and keep guessing"

If a previous combination was ambiguous, surprising, or silently ignored, the new CLI should reject it unless the new semantics are explicitly designed and documented.

## ghostty lessons we are borrowing

Ghostty is a useful reference for architecture, not for surface syntax.

We are intentionally borrowing these lessons:

- action detection is explicit
- actions are typed
- help is action-oriented
- parsing and execution are separate concerns

We are explicitly **not** borrowing:

- `+action` syntax
- Ghostty's config-as-flags model
- any CLI surface that drifts from pi-mono product semantics

## upstream seam surgery is allowed

If the current lower layers make explicit planning awkward, the answer is to fix those seams.

Examples of allowed refactor pressure:

- moving CLI policy out of dispatch and mode-specific runners
- introducing shared runtime bootstrap ownership
- changing lower-layer return types so `main.zig` owns exit
- deleting obsolete helpers that only existed to support the old implicit path

The CLI refactor is not limited to argument parsing files.

## consequences

This ADR commits the codebase to the following:

- old `RunOptions`-driven dispatch is to be deleted, not wrapped
- help text must describe actions and plans truthfully
- semantic validation must move upward into planning
- tests that encode cursed behavior are disposable
- future CLI features must add explicit raw args, explicit plan semantics, and explicit execution handling

## minimal behavior matrix

Valid:

- `zi`
- `zi "hello"`
- `zi -p "hello"`
- `zi --mode json "hello"`
- `zi --continue`
- `zi --resume`
- `zi --session 2a9f7c1d`
- `zi --session ./session.jsonl`

Invalid unless later given explicit semantics:

- `zi -p`
- `zi --mode json`
- `zi "a" "b"`
- `zi --continue "prompt"`
- `zi --session 2a9f7c1d "prompt"`
- `zi -p --continue`
- `zi --continue --resume`
- any flag combination where a flag is accepted but does not affect the plan

## acceptance bar for the epic

The refactor succeeds only if a future reader can answer these questions from types alone:

1. what top-level action is requested?
2. what raw syntax did the user provide?
3. what validated execution plan will run?
4. which module owns exit?

If those answers still depend on boolean heuristics, implicit reinterpretation, or silent fallback, the refactor failed.
