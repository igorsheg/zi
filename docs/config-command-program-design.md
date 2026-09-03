# Config command program design

Status: implemented

References:

- `docs/config-command-research.md`
- `docs/config-command-product.md`
- `docs/config-command-architecture.md`

Implementation note: the production review replaced the planned erased request/tool pull sources with
validated value publication. `RuntimeConfig` prepares the complete policy and confirmation before the
run document changes. The main thread then copies request and tool values through infallible module-owned
setters between operations. Background tasks retain launch limits in each entry. This note supersedes the
source sketches in the approved pre-implementation design.

## Acceptance ledger

The implementation is complete only when all of these are true:

- [x] `/config` is registered after `/preset-save` and before `/compact`.
- [x] Direct query works for all 61 registry rows with exact source, normalization, invalid marking,
      guidance, clipping, and secret redaction.
- [x] Bare `/config` is silent without a picker and opens the two-stage picker in a TTY.
- [x] Exactly the approved 21 settings accept process-local mutation.
- [x] `default` removes the run member and reveals the lower tier without leaving a sentinel.
- [x] Every mutation is prepared completely before allocation-free publication.
- [x] Every failed preparation leaves the run document and runtime snapshot unchanged.
- [x] Display, turn, compaction, tool, task, and provider-request settings activate at the boundary in
      the product contract.
- [x] Provider, preset, state, and config caches are not rebuilt.
- [x] No config or state file is written.
- [x] Cooked output has no ANSI bytes.
- [x] Picker and displayed data stay within their stated budgets and secret bytes never enter CLI
      buffers.
- [x] Optional turn, sort, context, image, and display sources retain fixed fallbacks for library tests.
- [x] All new owned values are leak-free and allocation-failure tests pass.
- [x] The built binary demonstrates direct inspect, set, clear, cooked behavior, and TTY picker/display
      refresh.
- [x] The repository ready gate passes.

This checklist is also the implementation progress record. Mark a row only after its direct test and
behavioral probe pass.

## File tree

```text
src
├── ai
│   ├── RequestPolicy.zig                 # NEW: validated request policy value
│   └── root.zig                          # export/register RequestPolicy
├── tool
│   ├── RuntimePolicy.zig                 # NEW: validated tool policy value
│   ├── TaskRegistry.zig                  # retain launch policy per entry
│   └── root.zig                          # export/register RuntimePolicy
├── config
│   ├── Settings.zig                      # metadata, validation, inspection classification
│   ├── Store.zig                         # shared borrowed scalar resolution + bounded materialization
│   └── Selection.zig                     # generic prepared run override
├── cli
│   ├── RuntimeConfig.zig                 # NEW: typed snapshot and publication coordinator
│   ├── ConfigCommand.zig                 # NEW: direct and picker UX
│   ├── StartupConfig.zig                 # forward generic override preparation/publication
│   ├── Interactive.zig                   # per-turn max policy and renderer source
│   ├── InteractiveCommands.zig           # register /config, source, stable preseed storage
│   ├── SelectionPicker.zig               # config setting/choice picker builders
│   ├── RunSelection.zig                  # dynamic model-sort source
│   ├── Stats.zig                         # optional dynamic context-limit source
│   ├── PrintRun.zig                      # lifetime composition and raw appearance adapters
│   └── root.zig                          # register new CLI tests
├── render
│   ├── ToolPresentation.zig              # inactive setTheme
│   ├── PlainInteractiveRenderer.zig      # inactive setTheme
│   └── Spinner.zig                       # synchronized setTheme
├── terminal
│   ├── Picker.zig                        # wipe rendered frame scratch
│   └── RawLineInput.zig                  # inactive setAppearance
├── ProviderConfig.zig                    # retain validated request policy
├── ProviderRuntime.zig                   # locked infallible request publication
└── ToolRuntime.zig                       # infallible tool policy publication
```

No new top-level package seam is required. `RuntimeConfig` and `ConfigCommand` are CLI internals. The two
new inward policy files are public through their module roots because `ProviderConfig`, `ToolRuntime`,
and tests are outside those modules.

## Config registry types

`src/config/Settings.zig` extends the existing metadata without replacing `Kind.bool`:

```zig
pub const Setting = struct {
    key: []const u8,
    env: []const u8,
    default: ?[]const u8,
    keep_empty: bool,
    kind: Kind,
    min: ?i32,
    max: ?i32,
    description: []const u8,
    choices: []const []const u8 = &.{},
    example: ?[]const u8 = null,
    editable: bool = false,
    secret: bool = false,
};
```

Choice slices are static arrays. Numeric choices are additive; string choices are exhaustive. Boolean
rows declare `on`, `off`; tri-state rows remain `Kind.string` and declare `auto`, `on`, `off`.

New validation types:

```zig
pub const Update = union(enum) {
    clear,
    set: []const u8, // borrowed input or canonical static choice
};

pub const ValidationError = error{ ReadOnly, InvalidValue };

pub fn validateUpdate(setting: *const Setting, value: []const u8) ValidationError!Update;
pub fn expectedHint(setting: *const Setting, buffer: []u8) []const u8;
pub fn classifyResolved(setting: *const Setting, value: ?[]const u8) Classification;
```

`validateUpdate` is allocation-free:

1. Exact lowercase `default` returns `.clear` before ordinary validation.
2. A case-insensitive declared choice returns that row's canonical static spelling.
3. Boolean aliases outside the declared choices retain the borrowed input; display later normalizes
   them.
4. Integer, size, and duration parsers consume the complete slice and enforce mutation bounds.
5. A negative number, leading/trailing whitespace, extra suffix, and overflow fail.

The existing startup getters keep their fallback behavior. Mutation validation is stricter where the
approved command grammar is stricter; it does not silently broaden or narrow startup compatibility.

`Classification` is synchronous and allocation-free. It reports presence, validity, and whether a
static normalized spelling such as `on` should replace raw display spelling.

Golden tests pin:

- 61 keys in order;
- all metadata fields for representative rows;
- the exact 21 editable keys;
- the three secret API-key rows;
- choice and example rows used by the picker;
- every accepted alias, unit, boundary, and malformed tail.

## Shared Store resolution

`Store.read` and bounded inspection need one precedence walk. The internal representation becomes a
borrowed scalar rather than an eagerly allocated string:

```zig
const Scalar = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
};

const ResolvedScalar = struct {
    value: ?Scalar,
    source: Source,
};

fn resolveScalar(self: Store, key: []const u8, options: ResolveOptions) !ResolvedScalar;
```

Document strings borrow parsed JSON storage. Environment and default strings borrow stable source
storage. JSON numbers and booleans remain values until a materializer formats them through a fixed
buffer. Object and array members stay absent.

Provider binding still uses the same scalar resolver. Canonical provider scratch is copied only under
the existing provider-id bound; an oversized canonical value cannot equal a valid provider and is
rejected without copying an unbounded environment value.

Existing `read`, `readBelowRun`, `readNonempty`, and `readForProvider` call `resolveScalar` and then
materialize a complete owned result. Their public signatures and wiping behavior remain unchanged.

Bounded inspection adds:

```zig
pub const Inspector = struct {
    context: *const anyopaque,
    classify_fn: *const fn (*const anyopaque, ?[]const u8) Classification,
    secret: bool,
};

pub const BoundedResult = struct {
    value: ?[]u8,
    source: Source,
    presence: Presence,
    invalid: bool,
    clipped: bool,

    pub fn deinit(self: *BoundedResult, allocator: std.mem.Allocator) void;
};

pub fn inspectBounded(
    self: Store,
    allocator: std.mem.Allocator,
    key: []const u8,
    maximum_display_bytes: usize,
    inspector: Inspector,
) error{OutOfMemory}!BoundedResult;
```

The classifier sees the complete scalar spelling synchronously. The materializer then copies only the
normalized or raw visible prefix required by the display budget. For a secret it materializes only
`set` or `unset` and never calls a formatter with secret bytes.

`Settings.inspect` wraps this generic Store API with the row's classifier. It is the only inspection
entry point exposed to CLI:

```zig
pub const Inspection = struct {
    display: []u8,
    source: Store.Source,
    invalid: bool,
    clipped: bool,
    pub fn deinit(self: *Inspection, allocator: std.mem.Allocator) void;
};

pub fn inspect(
    store: Store,
    allocator: std.mem.Allocator,
    setting: *const Setting,
    maximum_display_bytes: usize,
) error{OutOfMemory}!Inspection;
```

`Inspection.display` already contains `set`, `unset`, `(empty)`, normalized boolean/tri-state text, or a
bounded raw subject. Terminal control escaping remains CLI output policy because the same inspection is
also used as picker detail.

## Generic run override

`Selection.PreparedRun` remains selection-specific. A smaller type prevents `/config` from copying or
publishing preset tint accidentally:

```zig
pub const PreparedOverride = struct {
    document: Document,
    options: Store.Options,

    pub fn store(self: *const PreparedOverride) Store;
    pub fn deinit(self: *PreparedOverride) void;
};

pub fn prepareRunOverride(
    self: *const Selection,
    key: []const u8,
    value: ?[]const u8,
) Error!PreparedOverride;

pub fn publishRunOverrideRetired(
    self: *Selection,
    prepared: *PreparedOverride,
) RetiredOverlay;
```

`value = null` deletes the member. The method calls the existing `changedDocument(.run, ...)`, so it
inherits tree, string, field-count, and aggregate-byte limits. The prepared store points at the complete
candidate document and current conversation/base tiers.

Publication replaces only `Selection.run`. It leaves both preset-tint owners and the conversation tier
untouched. `RetiredOverlay` is reused with only `run_document` populated.

`StartupConfig.Owner` adds direct forwarding methods with the same names and no extra state.

## Request and tool policy publication

`src/ai/RequestPolicy.zig` and `src/tool/RuntimePolicy.zig` own small value policies, shared validity
predicates, and typed validation errors. They do not expose erased sources.

`RuntimeConfig.prepare` resolves and validates both complete policies from the prospective Store. Initial
provider and tool construction uses those values directly. After a successful runtime mutation,
`PrintRun.LiveViews` publishes the already validated values through module-owned infallible setters while
no request or synchronous tool callback is active.

`ProviderRuntime.publishHttpPolicy` serializes with the existing provider-plan lock. `ProviderConfig`
retains HTTP policy and Anthropic reasoning visibility, so later provider selection and authoritative
catalog rebuilds preserve the live setting.

`ToolRuntime.publishRuntimePolicy` updates later read, Bash, task-admission, and wait defaults. A
background task copies model-output and termination-grace limits into its `TaskRegistry.Entry` at launch.
Later changes do not reinterpret an existing task. Bash bounds its result at three times the raw model-facing cap for worst-case UTF-8 replacement, plus
64 KiB for truncation markers and status text.

## RuntimeConfig snapshot

`src/cli/RuntimeConfig.zig` owns the aggregate policy. Its value types are:

```zig
pub const AutomaticBool = enum { auto, on, off };
pub const ImagePolicy = enum { auto, on, off };

pub const Snapshot = struct {
    markdown: bool,
    show_reasoning: bool,
    display_columns: terminal.DisplayColumns.Policy,
    base_theme: render.Theme,
    run_tint_explicit: bool,

    sort_models: AutomaticBool,
    manual_context_limit: ?u64,
    image_input: ImagePolicy,
    maximum_turns: usize,

    compact_enabled: bool,
    compact_threshold: u8,

    request: ai.RequestPolicy.Policy,
    tools: tool.RuntimePolicy.Policy,
};
```

`base_theme` is already resolved against the captured terminal facts and the configured lower-tier tint.
If tint's resolved source is `.run`, it includes that explicit tint. Otherwise `Owner.theme()` applies
`StartupConfig.tint()` to `base_theme` on demand.

Main public/internal types:

```zig
pub const ThemeFacts = struct {
    no_color: ?[]const u8,
    term: ?[]const u8,
    colorterm: ?[]const u8,
    colorfgbg: ?[]const u8,
};

pub const Prepared = struct {
    override: config.Selection.PreparedOverride,
    snapshot: Snapshot,
    pub fn deinit(self: *Prepared) void;
};

pub const Owner = struct {
    allocator: std.mem.Allocator,
    startup: *StartupConfig.Owner,
    theme_facts: ThemeFacts,
    snapshot: Snapshot,

    pub fn init(...) error{ OutOfMemory, InvalidSetting }!Owner;
    pub fn prepare(self: *Owner, setting: *const config.Settings.Setting, update: config.Settings.Update) !Prepared;
    pub fn publishRetired(self: *Owner, prepared: *Prepared) config.Selection.RetiredOverlay;
    pub fn publish(self: *Owner, prepared: *Prepared) void;
    pub fn inspect(...) !config.Settings.Inspection;

    pub fn theme(self: *const Owner) render.Theme;
    pub fn displayPolicy(self: *const Owner) DisplayPolicy;
    pub fn turnPolicy(self: *const Owner) TurnPolicy;
    pub fn compactionPolicy(self: *const Owner) CompactionPolicy;
    pub fn effectiveContextLimit(self: *const Owner, discovered: u64) ?u64;
    pub fn resolveSortModels(self: *const Owner, keep_provider_order: bool) bool;
    pub fn resolveImageInput(self: *const Owner, support: ai.ModelMeta.Support) ai.Provider.ImageInput;
    pub fn requestPolicy(self: *const Owner) ai.RequestPolicy.Policy;
    pub fn toolPolicy(self: *const Owner) tool.RuntimePolicy.Policy;
};
```

`prepare` accepts only an already validated editable row. It prepares the run document, resolves a full
snapshot from `PreparedOverride.store()`, and validates all narrowed module fields. Any error destroys
the candidate.

`publishRetired` performs:

```zig
self.snapshot = prepared.snapshot;
const retired = self.startup.publishRunOverrideRetired(&prepared.override);
prepared.* = undefined;
return retired;
```

Both operations are moves or value assignments. `publish` calls it, then deinitializes the retired
document after publication.

`RuntimeConfig.Owner` exposes request and tool policy values directly and satisfies
`ConfigCommand.Source` through the live CLI adapter. No erased request/tool interface is retained.

## Dynamic turn policy

`Interactive.TurnSnapshot` gains:

```zig
max_turns: usize,
```

The loop passes `turn.max_turns` to `agent.Loop.run` and uses it in the max-turn diagnostic. Fixed inputs
populate it from `Inputs.max_turns`; the live `RunSelection.Owner.snapshot` path receives a turn-policy
source or `LiveProviderSource` in `PrintRun` overlays the value from `RuntimeConfig`.

The chosen implementation is a small wrapper in `PrintRun`:

```zig
const LiveTurnSource = struct {
    selection: *RunSelection.Owner,
    runtime_config: *const RuntimeConfig.Owner,

    pub fn snapshot(self: *LiveTurnSource) Interactive.TurnSnapshot;
};
```

It starts from `selection.snapshot()` and assigns `max_turns`. This avoids making `RunSelection` depend
on CLI runtime configuration for a loop-only field.

`AutoCompact` gains `runtime_config` and samples `compactionPolicy()` at the start of each check.
`enabled` and `threshold` fixed fields remain test fallbacks.

`Stats.Renderer` gets an optional context-limit source, implemented by a `PrintRun` adapter that combines
current runtime policy with current model metadata. `CatalogHook` and `LiveViews` call the same helper
after metadata or selection publication.

`DynamicImageInput` replaces its fixed policy field with a runtime-config pointer and resolves image
support after any catalog refresh.

`RunSelection.Owner` adds an erased `SortSource`:

```zig
pub const SortSource = struct {
    context: *const anyopaque,
    resolve_fn: *const fn (*const anyopaque, bool) bool,
};
```

`current()` and provider-listing preparation use it when present; existing `sort_models` stays the fixed
test fallback.

## Dynamic renderer and appearance

`Interactive` adds:

```zig
pub const TurnRendererSource = struct {
    context: *anyopaque,
    resolve_fn: *const fn (*anyopaque) TurnRenderer,
};

// Inputs
turn_renderer_source: ?TurnRendererSource = null,
```

At each turn, after the turn snapshot and before `begin`, the loop resolves one renderer. The local
`TurnRenderer` handles begin, tool observer, close, and check for the whole turn.

`PrintRun.DynamicTurnRenderer.resolve()`:

1. Gets current theme, reasoning visibility, Markdown mode, and width.
2. Calls inactive `setTheme` and `setShowReasoning` on both renderers.
3. Calls synchronized `spinner.setTheme`.
4. Returns Markdown or plain renderer.

`ToolPresentation.setTheme` asserts no active tool. Both interactive renderer setters propagate theme to
their `ToolPresentation`. The plain renderer gains the same inactive assertion as Markdown.

`Spinner.setTheme` takes its existing mutex, hides/repaints if necessary, copies the value-only theme,
and wakes the painter. `DynamicTurnRenderer` calls it while the spinner is hidden before a turn.

### Raw appearance refresh

`RawLineInput` gains an inactive setter:

```zig
pub const Appearance = struct {
    prompt: []const u8,
    submission_style_open: []const u8,
    submission_style_close: []const u8,
    display_columns: DisplayColumns.Policy,
    search_style_open: []const u8,
    search_style_close: []const u8,
    search_no_match_style_open: []const u8,
    search_no_match_style_close: []const u8,
};

pub fn setAppearance(self: *RawLineInput, appearance: Appearance) void;
```

`RawPresentation` owns a 128-byte prompt buffer and pointers to raw input, command owner, selection
picker runners, session picker, and replay adapter. `beforePrompt` samples RuntimeConfig and refreshes
all cached appearance values before any input or slash picker can run.

`RawMarkdownWidth` stores a runtime-config pointer instead of a copied display policy. Cooked command
width uses a parallel source that resolves current policy against stdout width.

`RawResumeReplay.replay` samples theme, mode, reasoning, and width at replay start. `RawSessionPicker.run`
and `SelectionPicker.TerminalRunner.run` sample current style and display policy at invocation. The
initial banner uses the initial RuntimeConfig appearance.

`LiveViews.publishSelectionViews` stops deriving theme from a frozen `base_theme`. It asks
`RuntimeConfig.theme()` after preset publication and updates command/renderer caches for output emitted
inside that same selection command. RuntimeConfig's next prompt refresh handles config-only changes.

## Config command source

`src/cli/ConfigCommand.zig` defines a narrow source independent of StartupConfig ownership:

```zig
pub const Source = struct {
    context: *anyopaque,
    inspect_fn: *const fn (std.mem.Allocator, *anyopaque, *const Setting, usize) anyerror!Inspection,
    apply_fn: *const fn (*anyopaque, *const Setting, Settings.Update) anyerror!ApplyResult,
    theme_fn: *const fn (*const anyopaque) render.Theme,
    display_policy_fn: *const fn (*const anyopaque) terminal.DisplayColumns.Policy,
};

pub const ApplyResult = enum { changed, failed };

pub const Outcome = union(enum) {
    handled,
    preseed: []const u8,
};
```

`RuntimeConfig.Owner` implements the source. `ConfigCommand` resolves `display_policy_fn` against
`physical_columns` after mutation, so a new width governs the confirmation line. Selection/document
validation errors become `.failed`; `OutOfMemory` remains an error. A successful apply publishes,
retires old storage, and returns `.changed`.

Command inputs:

```zig
pub const Inputs = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    styled: bool,
    source: Source,
    picker: ?SelectionPicker.Runner = null,
    physical_columns: usize,
    preseed_buffer: []u8,
};

pub fn run(inputs: Inputs, argument: ?[]const u8) !Outcome;
```

The command uses `preseed_buffer` owned by `InteractiveCommands.Owner`. Returned seed bytes therefore
remain valid until `Interactive` synchronously copies them into RawLineInput. The buffer is wiped before
reuse.

`InteractiveCommands.Owner` gains:

```zig
config_source: ?ConfigCommand.Source = null,
config_preseed: [config_preseed_bytes]u8 = undefined,

pub fn setConfigSource(self: *Owner, source: ConfigCommand.Source) void;
```

The `/config` slash handler passes current writer, style, picker, and stable buffer to
`ConfigCommand.run`, then maps the outcome. The spec uses `.arguments = .optional` and
`.display = .managed`.

## Direct command call stack

```diff
 Interactive.CommandGateway.execute
   Slash.execute
     InteractiveCommands.runConfig
+      ConfigCommand.run(argument)
+        parse key and optional tail without allocation
+        Settings.find(key)
+        query:
+          Source.inspect(setting, 4096)
+          writeSettingLine
+          write read-only guidance when required
+        mutation:
+          Settings.validateUpdate(setting, value)
+          Source.apply(setting, update)
+            RuntimeConfig.prepare
+              StartupConfig.prepareRunOverride
+              RuntimeConfig.resolveSnapshot(candidate.store)
+            RuntimeConfig.publish
+          Source.inspect(setting, 4096)
+          writeSettingLine with newly resolved theme and width
```

Key and value diagnostics use `DiagnosticText`-style bounded escaping. The too-long-key branch does not
append the listing hint. Read-only dedicated command mapping remains a static four-row CLI table.

## Picker program

`SelectionPicker.zig` adds config-specific result types:

```zig
pub const ConfigSettingOutcome = union(enum) { canceled, selected: usize };
pub const ConfigValueOutcome = union(enum) {
    canceled,
    selected: Settings.Update,
    exact: []const u8,
};
```

The broad builder:

```zig
pub fn configSetting(
    allocator: std.mem.Allocator,
    runner: Runner,
    source: ConfigCommand.Source,
) !ConfigSettingOutcome;
```

It iterates `Settings.list()` in order, skips `providers.*`, builds rows under one 256-KiB wiping budget,
and keeps a parallel registry index. Each detail inspection is limited to 4096 bytes. Secret rows have
already been redacted.

The value builder:

```zig
pub fn configValue(
    allocator: std.mem.Allocator,
    runner: Runner,
    source: ConfigCommand.Source,
    setting: *const Settings.Setting,
    preseed_buffer: []u8,
) !ConfigValueOutcome;
```

Rows are `default`, declared choices, then `exact value...` when the numeric kind has an example. The
current exact normalized value sets the initial row. Tint choice rows receive preview styles from the
current effective theme.

Selecting `exact value...` writes `/config KEY VALUE` into `preseed_buffer` and returns `.preseed` rather
than mutating. The value is current valid exact spelling or the static registry example. Buffer overflow
is an ordinary error and cannot produce a partial seed.

Picker-owned arrays and copied detail bytes are wiped before free. Selection identity always comes from
the index map, not row labels.

## PrintRun composition

The central call stack changes to:

```diff
 PrintRun.run
   StartupConfig.finish
+  RuntimeConfig.Owner.init(&startup, theme facts)
   ProviderConfig.resolve
+    http_policy = RuntimeConfig.requestPolicy()
   ToolRuntime.init
+    tool policy = RuntimeConfig.toolPolicy()
   RunSelection.Owner
+    sort source = RuntimeConfig adapter
   AutoCompact / Stats / DynamicImageInput
+    runtime policy snapshot
   InteractiveCommands
+    config source = ConfigCommand.Source.from(&runtime_config)
   Interactive.run
+    LiveTurnSource
+    DynamicTurnRenderer in TTY mode
```

`RuntimeConfig.Owner` is declared after final StartupConfig ownership and before ProviderConfig. Defers
remain LIFO so commands, terminal objects, renderers, tools, providers, and all erased sources die before
RuntimeConfig and StartupConfig.

The old startup locals for the 21 editable settings are removed as their consumers move to the snapshot.
Read-only settings keep current startup resolution.

## Error mapping

`ConfigCommand` maps only expected command-domain failures:

```text
unknown key                   exact unknown-setting diagnostic
read-only key                 dedicated or restart diagnostic
invalid value                 exact expected-hint diagnostic
Selection TooLarge/Invalid    couldn't change 'KEY' — keeping the current settings
snapshot InvalidSetting       couldn't change 'KEY' — keeping the current settings
picker cancellation           handled, no output
```

OOM, writer errors, picker I/O, and terminal restoration errors propagate through the existing command
error path. They are not relabeled as validation failures.

If confirmation output fails after publication, the command returns the writer error and leaves the
coherent new runtime state installed.

## Test placement

Tests stay beside owners:

- `config/Settings.zig`: metadata golden, validation matrix, display classification, secret behavior.
- `config/Store.zig`: scalar-resolution parity, bounded environment reads, sentinel, provider binding,
  clipping, and every allocation failure.
- `config/Selection.zig`: generic prepare/cancel/publish, preset tint retained, lower tier exposed,
  aggregate limits, no-allocation publication.
- `ai/RequestPolicy.zig` and four adapters: validation and one sample per stream.
- `ProviderConfig.zig`: source survives initial and rebuilt adapter plans.
- `tool/RuntimePolicy.zig`, Read, Bash, TaskRegistry, TaskWait: sampling and launch-time retention.
- `cli/RuntimeConfig.zig`: all 21 typed fields, lower fallback, source run detection, preset tint,
  candidate rollback, and coherent publication.
- `cli/ConfigCommand.zig`: syntax, diagnostics, query/mutation, clipping, redaction, cancellation, seed.
- `cli/SelectionPicker.zig`: exact row order, index mapping, budget, initial selection, tint preview.
- `cli/Interactive.zig`: per-turn max and renderer source lifetime.
- render/terminal files: inactive setter and synchronized theme tests.
- `cli/PrintRun.zig`: policy adapter helpers and effective context/image/sort behavior.

Allocation tests use `std.testing.checkAllAllocationFailures` for every new move-only prepared or retained
value. Publication tests use an observing allocator and assert zero calls inside the critical section.

## Vertical implementation slices

### Slice 1: inspect one setting end to end

Implement registry metadata, shared bounded Store resolution, `Settings.inspect`, `ConfigCommand` direct
query, and slash registration. All rows remain read-only for mutation at this checkpoint.

Demonstrable behavior:

```text
/config compact.threshold
compact.threshold = 85 (default)
```

Verification:

```sh
zig fmt --check src/
zig build test
zig build
printf '/config compact.threshold\n/config provider\n' | ./zig-out/bin/zi [isolated mock args]
```

Expected: exact inspection and `/provider` guidance, no ANSI in captured cooked output, no file changes.

### Slice 2: transactional core plus turn and compaction policy

Implement `PreparedOverride`, RuntimeConfig snapshot/publication, max turns, sort, context, image, and
automatic compaction sources. Mark only these six settings editable:

```text
sort_models
context_limit
compact.auto
compact.threshold
max_turns
image_input
```

Verification adds direct set/query/default sequences and unit probes that the next turn or compaction
check sees the new sample while failed candidates preserve old state.

**Review stop A:** inspect the config ownership and publication diff before adding transport, tool, or
raw-terminal fan-out.

### Slice 3: dynamic display

Implement dynamic width, theme/tint, Markdown selector, raw appearance refresh, renderer/theme setters,
replay behavior, and spinner synchronization. Mark these four settings editable:

```text
markdown
display_width
theme
tint
```

`show_reasoning` remains read-only until its request-body path lands.

Verification includes renderer unit probes and an `expect` PTY script that changes theme, width, and
Markdown mode, submits a mock prompt, and asserts normal-buffer output with no `\x1b[?1049` sequence.

### Slice 4: dynamic tools and tasks

Implement `tool.RuntimePolicy`, ToolRuntime injection, Read/Bash sampling, task admission, entry policy,
and TaskWait sampling. Mark the seven tool/task settings editable only after all child owners use the
source.

Verification runs tool methods through `ToolRuntime.Owner`, changes the source between invocations,
keeps one task alive across a change, and proves launch-time versus next-wait behavior.

**Review stop B:** inspect all runtime consumers and background-task ownership before modifying provider
adapters.

### Slice 5: dynamic provider request policy and reasoning

Implement `ai.RequestPolicy`, all four adapter sampling paths, and ProviderConfig source retention. Mark
the three `http.*` rows and `show_reasoning` editable after renderer and Anthropic request behavior both
pass.

Verification uses fake transports to mutate policy between streams and asserts one sampled value across
all retries. Anthropic request JSON must change `thinking.display`; OpenAI and Codex requests must not
gain an unrelated body field.

### Slice 6: TTY picker, bounds, and final integration

Implement both config pickers, stable exact-value preseed, wiping budgets, fresh appearance at picker
invocation, and complete binary probes. Confirm the editable golden is exactly 21.

Built-binary probes use an isolated temporary HOME/state/config root and the built-in mock provider:

- cooked query, set, clear, invalid, read-only, secret redaction;
- multiple mutations in one process to prove live state;
- TTY broad picker and choice picker with `/usr/bin/expect`;
- exact-value preseed visible in the raw editor;
- theme/width/Markdown refresh on the next eligible operation;
- persistent config and state hashes unchanged;
- no alternate-screen control sequence.

**Review stop C:** final diff and acceptance-ledger review.

## Ready gate

After the final slice:

```sh
zig fmt --check src/
zig build
zig build test
./zig-out/bin/zi --help
./zig-out/bin/zi --version
```

Run `ziglint src build.zig` after formatting. Report the existing baseline findings separately from any
new finding; do not weaken or suppress either set.

## Decisions requiring approval

1. Add four implementation files: `ai/RequestPolicy.zig`, `tool/RuntimePolicy.zig`,
   `cli/RuntimeConfig.zig`, and `cli/ConfigCommand.zig`.
2. Refactor Store to one borrowed scalar resolver so bounded inspection does not copy unbounded values.
3. Add `Selection.PreparedOverride` rather than overloading selection-specific `PreparedRun`.
4. Keep the aggregate snapshot value-only and resolve active preset tint on demand.
5. Sample request and tool sources once per operation and copy task launch policy into each entry.
6. Use `Interactive.TurnRendererSource` to select a complete renderer per turn.
7. Refresh raw appearance before each prompt and sample replay/picker appearance per invocation.
8. Keep a stable config preseed buffer in `InteractiveCommands.Owner`.
9. Land the feature in six vertical slices with review stops after slices 2, 4, and 6.
