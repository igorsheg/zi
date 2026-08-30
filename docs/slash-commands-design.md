# Slash-command program design

Status: awaiting review

References:

- `docs/slash-commands-research.md`
- `docs/slash-commands-product.md`
- `docs/slash-commands-architecture.md`

## File tree

```text
src/
├── ai/
│   ├── ModelListing.zig          NEW  provider-neutral list owner and erased source
│   ├── OpenAiModels.zig          NEW  bounded OpenAI-compatible /models parser
│   ├── AnthropicModels.zig       NEW  bounded Anthropic model-list parser
│   ├── CodexModels.zig           MODIFY return the shared listing owner
│   └── root.zig                  MODIFY export and register model-list modules
├── agent/
│   └── Session.zig               MODIFY prepare and publish owned selection
├── config/
│   ├── Selection.zig             MODIFY prospective run-selection plan
│   ├── StateWriter.zig           NEW  preserve-and-atomically-replace state.json
│   └── root.zig                  MODIFY export and register StateWriter
├── persistence/
│   ├── SessionFile.zig           MODIFY prepare and publish log selection
│   └── root.zig                  MODIFY only if the prepared type is public
├── tool/
│   └── Bash.zig                  MODIFY allocation-free full selection update
├── cli/
│   ├── Slash.zig                 NEW  parser, registry, erased handler, dispatch
│   ├── ModelOrder.zig            NEW  pure hax-compatible model ID ordering
│   ├── SelectionPicker.zig       NEW  model, effort, and provider picker adapters
│   ├── RunSelection.zig          NEW  live owner, candidate, and commit transaction
│   ├── InteractiveCommands.zig   NEW  command handlers and user-facing diagnostics
│   ├── Interactive.zig           MODIFY command gateway and per-turn source
│   ├── PrintRun.zig              MODIFY construct one interactive live owner
│   └── root.zig                  MODIFY register internal files
├── ProviderRuntime.zig           MODIFY model listing and move-swap support
├── ToolRuntime.zig               MODIFY full child-process selection update
├── SessionDurability.zig         MODIFY prepared selection transaction
└── THIRD_PARTY_NOTICES.md        MODIFY attribute added hax behavior
```

No new top-level module is needed. The cross-module transaction is interactive CLI
process policy and stays in `src/cli/RunSelection.zig`. Lower modules expose only the
small prepare and publish operations they own.

## Command core

### Declarations

```zig
pub const ArgumentPolicy = enum { none, optional };
pub const DisplayPolicy = enum { ordinary, managed };

pub const Spec = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
    summary: []const u8,
    arguments: ArgumentPolicy = .none,
    display: DisplayPolicy = .ordinary,
    handler: Handler,
};
```

The registry is an explicit `comptime` array in help order. The completed milestone
contains `help`, `provider`, `model`, and `effort`. A vertical slice registers a command
only when its real handler exists, so `/help` never advertises temporary behavior. Later
commands append descriptors without changing dispatch.

`validateSpecs(comptime specs)` checks at compile time:

- command and alias syntax;
- duplicate command names;
- duplicate aliases;
- command-alias collisions;
- non-empty summaries;
- a maximum of 32 declarations.

This follows zig-ai's explicit ordered registries and preflight validation. It avoids
reflection because help order and aliases are product data.

### Parser and dispatch

```zig
pub const Parsed = struct {
    name: []const u8,
    argument: ?[]const u8,
};

pub const Parse = union(enum) {
    prompt,
    command: Parsed,
};

pub fn parse(line: []const u8) Parse;

pub const Usage = enum { valid, unknown, bad_usage };

pub const ClassifiedCommand = struct {
    registry_index: ?usize,
    name: []const u8,
    argument: ?[]const u8,
    usage: Usage,
};

pub const Classification = union(enum) {
    prompt,
    command: ClassifiedCommand,
};

pub const Handler = struct {
    context: *anyopaque,
    call_fn: *const fn (*anyopaque, Call) anyerror!HandlerOutcome,
};

pub const Call = struct {
    spec: *const Spec,
    argument: ?[]const u8,
};

pub const HandlerOutcome = enum { handled, exit };

pub fn classify(line: []const u8, specs: []const Spec) Classification;
pub fn execute(
    command: ClassifiedCommand,
    specs: []const Spec,
    output: Output,
) !HandlerOutcome;
```

`classify` is allocation-free and performs no output or callback. `Output` is a tiny
erased synchronous diagnostic renderer used only by `execute`. Slash does not own a
writer or allocate output. Unknown and bad-usage messages pass parsed safe-ASCII names
through the existing diagnostic path.

Parser tests cover every hax fixture, controls, invalid UTF-8 bytes, names at the
line boundary, trailing whitespace, and exact argument borrowing.

## Interactive seams

```zig
pub const CommandToken = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, CommandToken) anyerror!CommandOutcome,
    registry_index: ?usize,
    name: []const u8,
    argument: ?[]const u8,
    usage: CommandUsage,
};

pub const CommandClassification = union(enum) {
    prompt,
    command: CommandToken,
};

pub const CommandGateway = struct {
    context: *anyopaque,
    classify_fn: *const fn (*anyopaque, []const u8) CommandClassification,
};

pub const TurnSnapshot = struct {
    provider: ai.Provider.Provider,
    model: []const u8,
    model_metadata: ai.ModelMeta.Metadata,
    model_metadata_source: ?agent.ModelMetadataSource.ModelMetadataSource,
    system_prompt: []const u8,
    tools: []const tool.Tool.Tool,
    effort: ?[]const u8,
    image_input: ai.Provider.ImageInput,
    image_input_source: ?agent.ImageInputSource.ImageInputSource,
};

pub const TurnSource = struct {
    context: *anyopaque,
    snapshot_fn: *const fn (*anyopaque) TurnSnapshot,
};
```

`Interactive.Inputs` gains optional `command_gateway` and `turn_source`. The existing
fixed fields remain required for now and provide the fallback snapshot. This avoids a
large test migration in the command-core slice.

The prompt path changes as follows:

```diff
 Interactive.run
   read terminal result
   sanitize non-empty input
+  command_gateway.classify(sanitized)
+    command -> prompt_recall.admit(original, session)
+               token.execute
+                 handled -> continue prompt loop
+                 exit -> return 0
+    prompt -> prompt_recall.admit(original, persistent)
   Session.addUser
   durability seam
   before-first-send hook
+  turn = turn_source.snapshot() or fixedSnapshot(inputs)
   agent.Loop.run(turn)
```

A gateway never sees empty resume input. Classification happens before session-only or
persistent prompt-recall admission as specified by `docs/prompt-recall-design.md`.
`first_send` remains true after commands.

## Model listing

### Shared owner

```zig
pub const Model = struct {
    id: []const u8,
    description: ?[]const u8 = null,
    metadata: ModelMeta.Metadata = .{},
};

pub const OwnedList = struct {
    owner: *Owner,
    models: []const Model,
    pub fn deinit(self: *OwnedList) void;
};

pub const Outcome = union(enum) {
    unsupported,
    failure: []const u8,
    models: OwnedList,
};

pub const Source = struct {
    context: *anyopaque,
    list_fn: *const fn (
        *anyopaque,
        std.mem.Allocator,
        std.Io,
        ?Provider.Tick,
    ) Error!Outcome,
};
```

`Owner` is heap-stable and contains an arena. IDs, descriptions, the failure message,
and the model slice share one bounded lifetime. `deinit` destroys the arena and owner
and sets the public handle to `undefined`.

`CodexModels` keeps protocol parsing but builds this common owner. OpenAI-compatible
and Anthropic parsers receive their own files because response shapes and pagination
rules differ. `ProviderRuntime` routes its resolved adapter to the correct source. It
does not add listing to `ai.Provider.VTable`.

Provider and configured `sort_models` policy becomes a boolean on the live snapshot.
`SelectionPicker` either preserves returned order or sorts an index slice, leaving
the provider-owned model list unchanged.

## Model order

```zig
pub fn lessThan(_: void, left: []const u8, right: []const u8) bool;
```

`ModelOrder` adapts hax's observed rules rather than translating its tokenizer:
case-insensitive family grouping, newer numeric versions first, bare IDs before dated
snapshots, snapshots before named variants, and bytewise fallback for a total order.
Tests port every `test_model_sort.c` example plus antisymmetry and stable-list cases.

## Prospective configuration

`config.Selection` gains a move-only plan:

```zig
pub const RunChange = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    exit_preset: bool = false,
};

pub const PreparedRun = struct {
    document: Document,
    tint: ?[]u8,
    store: Store,
    pub fn deinit(self: *PreparedRun, allocator: std.mem.Allocator) void;
};

pub fn prepareRun(self: *const Selection, change: RunChange) Error!PreparedRun;
pub fn publishRun(self: *Selection, prepared: *PreparedRun) void;
```

The exact `Store` representation may be derived on demand rather than retained if it
would contain a self-pointer invalidated by moving `PreparedRun`. The invariant is
more important: candidate construction reads a complete prospective tier, and
`publishRun` moves it into live selection without allocation.

A provider change sets provider, clears model and effort to the explicit default
sentinel, and exits the preset. Final model and effort preparation starts from that
prospective state. A model change keeps provider, replaces model, adjusts effort, and
exits the preset. An effort change keeps provider and model and exits the preset.

## Prepared session durability

Preparation is split from publication in `agent.Session`, `SessionFile.Log`, and
`SessionDurability`:

```zig
Session.prepareSelection(selection) !PreparedSelection
Session.publishSelection(*PreparedSelection) void

Log.prepareSelection(selection) !PreparedSelection
Log.publishSelection(*PreparedSelection) void

SessionDurability.prepareSelection(session, requested) !PreparedSelection
SessionDurability.publishSelection(session, *PreparedSelection) void
```

The durability owner first verifies that session and log selections agree. Its
prepared value owns both replacements. Publication moves both values and cannot
fail. An absent log prepares only the session replacement through the coordinator.

The existing `updateSelection` API remains for compaction and delegates to prepare
plus publish. This avoids rewriting a proven call path while giving commands a
fallible preflight.

## Tool selection

`tool.Bash.RunSelectionState` already owns fixed-size provider, model, and effort
assignments. Add:

```zig
pub fn updateRunSelection(self: *Bash, selection: RunSelection) error{InvalidConfig}!void;
pub fn updateRunSelection(self: *ToolRuntime.Owner, selection: RunSelection)
    (BindingError || error{InvalidConfig})!void;
```

Validation happens before any fixed array changes. Publication rewrites all arrays
without allocation. Existing background processes retain the environment copied at
spawn; later launches use the new values.

## State writer

```zig
pub const Selection = struct {
    provider: []const u8,
    model: ?[]const u8,
    effort: ?[]const u8,
    preset: ?[]const u8 = null,
};

pub const Outcome = enum { unchanged, written, unavailable, failed };

pub const Writer = struct {
    context: *anyopaque,
    write_fn: *const fn (*anyopaque, Selection) error{OutOfMemory}!Outcome,
};
```

The production owner retains the loaded state path and source document. It prepares a
new bounded JSON object, preserves unrelated root members, writes a private temporary
file in the state directory, syncs it, atomically renames it, and only then replaces
its in-memory document. The writer compares the target identity or expected content
before rename so an external edit is reported as failure rather than overwritten.

Tests inject filesystem operations. No test changes the real user state directory.

## Live coordinator

```zig
pub const Owner = struct {
    // owned current runtime and prompt
    // borrowed process services and static prompt inputs

    pub fn snapshot(self: *Owner) Interactive.TurnSnapshot;
    pub fn current(self: *const Owner) CurrentSelection;
    pub fn listModels(self: *Owner, tick: ?ai.Provider.Tick) !ai.ModelListing.Outcome;
    pub fn prepare(self: *Owner, requested: RequestedSelection) !Candidate;
    pub fn commit(self: *Owner, candidate: *Candidate) CommitResult;
};

pub const RequestedSelection = struct {
    provider: []const u8,
    model: ?[]const u8,
    model_label: ?[]const u8,
    effort: ?[]const u8,
};

pub const CommitResult = struct {
    persistent: enum { written, unchanged, run_only },
};
```

`Candidate` owns a `ProviderRuntime.Owned`, optional prompt, prospective config run,
prepared durability selection, and copied derived facts. `prepare` validates the tool
selection but does not publish it.

`commit` is called only between turns. It publishes config, swaps runtime and prompt,
updates fixed derived holders, publishes tool and session state, then destroys the
old owned values. Persistent state runs last. The method has no general error union;
post-preparation failures are represented only by the persistent `run_only` result.

`CatalogRuntime`, `DynamicEffort`, `DynamicModelMetadata`, `DynamicImageInput`,
`AutoCompact`, and stats stop pointing directly at the old stack
`ProviderRuntime.Owned`. They borrow the live coordinator or receive all changed
fields during publication.

## Command handlers

`InteractiveCommands.Owner` has a stable address and contains:

- ordered command specs with erased handlers;
- `RunSelection.Owner` pointer;
- terminal files, writer, theme, width policy, and picker limits;
- provider availability source;
- one process-lifetime persistence-warning flag.

Handlers are thin:

```text
/model
  current provider check
  show fetching status
  live.listModels
  SelectionPicker.model
  SelectionPicker.effort when available
  live.prepare
  live.commit
  render notice and optional run-only warning

/effort
  resolve current metadata effort set
  SelectionPicker.effort
  live.prepare
  live.commit

/provider
  enumerate and probe providers
  SelectionPicker.provider
  current provider -> /model path
  temporary default candidate
  model and effort path against temporary candidate
  final live.prepare
  live.commit

/help
  render command specs and supported shortcuts
```

Picker setup failure follows hax and becomes cancellation. Provider, model, and state
diagnostics pass through bounded safe rendering.

## Vertical implementation slices

### Slice 1: command front door and `/help`

- Add `Slash.zig`, gateway integration, help rendering, and registry tests.
- Keep fixed turn inputs.
- Register only `/help` in this slice. Later slices add each selection descriptor
  together with its real handler, so every milestone commit remains a truthful product.

Verification:

- targeted parser and `Interactive` tests;
- mock script proves `/help` and unknown commands never invoke the provider;
- malformed slash input reaches the provider unchanged;
- PTY help output stays in the normal buffer;
- ready gate, changed-file lint, commit.

### Slice 2: model listing and ordering

- Add shared listing ownership, Codex adaptation, OpenAI-compatible and Anthropic
  parsers, provider runtime routing, and `ModelOrder`.
- No interactive mutation yet.

Verification:

- fake JSON transports cover supported, unsupported, malformed, oversized,
  cancellation, auth, and pagination behavior;
- all hax model-order fixtures;
- allocation-failure sweeps for common owners and parsers;
- direct public-`ai` tests, ready gate, changed-file lint, commit.

### Slice 3: live snapshots and `/effort`

- Add prospective config and prepared session/log APIs.
- Add full tool selection updates.
- Introduce `RunSelection.Owner`, candidate publication, `TurnSource`, and `/effort`.
- Refactor catalog, compaction, prompt, and stats holders through the live owner.

Verification:

- failure injection before every publication leaves the original snapshot unchanged;
- successful commit changes next-turn request, Bash child environment, prompt model
  fact, session/log selection, image policy, context limit, and compaction inputs;
- effort picker cancellation is a no-op;
- ready gate, changed-file lint, commit.

### Slice 4: `/model`

- Add model and effort picker composition, singleton behavior, diagnostics, sorting,
  and current-provider candidate preparation.

Verification:

- local fake `/models` endpoint drives the built binary through multi-model selection;
- next mock-compatible request uses the selected model and effort;
- cancellation at effort rolls back model choice;
- session resume restores the switched model;
- PTY normal-buffer probe, ready gate, changed-file lint, commit.

### Slice 5: `/provider` and persistent state

- Add provider availability source, temporary provider candidates, chained selection,
  and `StateWriter`.
- Register the final `/provider` descriptor alongside its real handler.

Verification:

- two local provider fixtures prove old-provider preservation, current-provider reuse,
  unavailable-row selection, full commit, and next-request routing;
- state writer preserves unrelated fields and reports concurrent edits;
- persistence failure retains the live choice and warns once;
- recorded session writes selection only with the next item;
- PTY cancellation and terminal restoration probes;
- full project ready gate and changed-file lint;
- independent hax parity and Zig ownership reviews before final commit.

## Public symbols and registration checks

Before completion, mechanically confirm:

- `ai.root` exports and test-registers `ModelListing` and adapter modules;
- `config.root` exports and test-registers `StateWriter`;
- `cli.root` test-registers every new internal file;
- `Interactive.Inputs` exposes `command_gateway` and `turn_source`;
- `ToolRuntime.Owner.updateRunSelection` exists;
- `SessionDurability` exposes prepared selection publication;
- all four command specs have live handlers;
- `THIRD_PARTY_NOTICES.md` names slash dispatch, model selection and ordering, effort
  selection, provider switching, and persistent selection behavior.
