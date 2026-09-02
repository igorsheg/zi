# Preset save program design

Status: implemented through Slice 3; ready gate blocked by the known Zig filesystem test baseline

References:

- `docs/preset-save-research.md`
- `docs/preset-save-product.md`
- `docs/preset-save-architecture.md`

## File changes

```text
src/
├── config/
│   ├── AtomicReplace.zig             NEW private common atomic replacement policy
│   ├── ConfigWriter.zig              NEW stable config document + preset cache owner
│   ├── Preset.zig                    raw save inspection helpers
│   ├── StateWriter.zig               delegate unchanged persistence behavior to AtomicReplace
│   └── root.zig                      export ConfigWriter; register AtomicReplace tests
├── cli/
│   ├── PresetSave.zig                NEW parser, tint, owned inspection, erased source
│   ├── StartupConfig.zig             transfer config ownership and implement save source
│   ├── Interactive.zig               carry and deliver borrowed preseed outcomes
│   ├── Slash.zig                     allow a handler outcome with preseed payload
│   ├── SelectionPicker.zig           overwrite and tint adapters
│   ├── InteractiveCommands.zig       register, run, diagnose, announce, activate
│   ├── ProcessAdapters.zig            config-writer nonce adapter
│   ├── PrintRun.zig                  source, nonce, picker, and raw-input wiring
│   └── root.zig                      register PresetSave tests
└── terminal/
    └── RawLineInput.zig              own and consume one bounded preseed

THIRD_PARTY_NOTICES.md                attribute adapted preset-save/config-write behavior
docs/preset-save-*.md                 research, product, architecture, and design record
```

No new top-level package is introduced. `ConfigWriter` is public only through
`src/config/root.zig`; `AtomicReplace` remains an internal config file. `PresetSave.zig`
is an internal CLI policy registered by `src/cli/root.zig`.

## Shared atomic replacement

Move StateWriter's filesystem-only types and helpers into `config/AtomicReplace.zig`.
Keep the existing StateWriter public surface source-compatible through aliases.

```zig
pub const NonceError = error{ OutOfMemory, Failed };

pub const NonceSource = struct {
    context: *anyopaque,
    fill_fn: *const fn (*anyopaque, []u8) NonceError!void,

    pub fn fill(self: NonceSource, bytes: []u8) NonceError!void;
    pub fn from(implementation: anytype) NonceSource;
};

pub const OpsError = error{Failed};
pub const CreateTempError = error{ Collision, Failed };

pub const CommitOps = struct {
    context: ?*anyopaque = null,
    make_parent_fn: *const fn (...) OpsError!void = standardMakeParent,
    open_parent_fn: *const fn (...) OpsError!std.Io.Dir = standardOpenParent,
    create_temp_fn: *const fn (...) CreateTempError!std.Io.File = standardCreateTemp,
    write_fn: *const fn (...) OpsError!void = standardWrite,
    sync_fn: *const fn (...) OpsError!void = standardSync,
    rename_fn: *const fn (...) OpsError!void = standardRename,
    cleanup_fn: *const fn (...) void = standardCleanup,

    pub const standard: CommitOps = .{};
};

pub const Inputs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    secure_open: SecureOpen.Capability,
    nonce_source: ?NonceSource,
    commit_ops: CommitOps,
    path: []const u8,
    expected: ?Loader.Fingerprint,
    temp_prefix: []const u8,
};

pub const TargetStatus = enum {
    unchanged,
    conflict,
    unavailable,
};

pub fn checkTarget(inputs: Inputs) error{OutOfMemory}!TargetStatus;

pub const Outcome = union(enum) {
    written: Loader.Fingerprint,
    conflict,
    target_unavailable,
    unavailable,
    failed,
};

pub fn commit(inputs: Inputs, bytes: []const u8) error{OutOfMemory}!Outcome;
```

`commit` contains no document or preset policy. It performs the bounded temporary-name
loop, parent safety check, private file creation, write, sync, temp identity check,
authoritative target fingerprint check, rename, and best-effort cleanup.

The outcome distinction is intentional:

- `conflict`: a coherently inspected regular target differs from the expected fingerprint,
  an expected regular target disappeared, or an expected missing target appeared as a
  regular file.
- `target_unavailable`: the destination is now a symlink or non-regular/unsafe
  value, or cannot be inspected coherently at the authoritative final check.
- `unavailable`: the path/parent cannot safely host the transaction or nonce generation
  is unavailable before a temporary is created.
- `failed`: temporary creation, write, sync, identity, or rename failure.
- `written`: rename succeeded; returned fingerprint describes the installed bytes.

`checkTarget` performs the absolute-path unchanged check without writing. StateWriter
uses it when a requested selection produces identical JSON, preserving the existing rule
that stale disk state turns an otherwise `.unchanged` write into `.failed`. `commit`
performs its own authoritative directory-relative check immediately before rename.
ConfigWriter maps a coherent `.conflict` to the restart diagnostic and both
`.target_unavailable` and `.unavailable` to the couldn't-write diagnostic;
startup-unusable and no-path states are decided before calling the helper.

`StateWriter.zig` retains:

```zig
pub const NonceError = AtomicReplace.NonceError;
pub const NonceSource = AtomicReplace.NonceSource;
pub const OpsError = AtomicReplace.OpsError;
pub const CreateTempError = AtomicReplace.CreateTempError;
pub const CommitOps = AtomicReplace.CommitOps;
```

Its private `commit` maps `conflict`, `target_unavailable`, and `failed` to current
`.failed`, maps pre-target `unavailable` unchanged, and stores the returned fingerprint
on `written`. Its no-write path maps `checkTarget(.unavailable)` to `.failed`, matching
current behavior. Existing
StateWriter tests must pass without expected-output changes.

`AtomicReplace` accepts a caller-provided prefix. State uses `.zi-state.tmp.`; config uses
`.zi-config.tmp.`. It remains bounded to 32 nonce attempts and mode `0600`.

## Raw preset inspection

Add an owned scalar-coercing view to `config/Preset.zig`:

```zig
pub const SaveInspection = struct {
    exists: bool,
    state_shadow: bool,
    provider: ?[]u8,
    model: ?[]u8,
    effort: ?[]u8,
    description: ?[]u8,
    tint: ?[]u8,

    pub fn deinit(self: *SaveInspection, allocator: std.mem.Allocator) void;
};

pub fn inspectForSave(
    allocator: std.mem.Allocator,
    documents: Documents,
    name: []const u8,
) error{OutOfMemory}!SaveInspection;
```

Node selection implements exact pinned precedence:

```text
exists:
  any nested or exact-flat same-name value in state or config

state_shadow:
  nested state value exists and is an object

selected node:
  first nested object in state, then config
  otherwise state dotted lookup, then config dotted lookup
  the dotted phase stops on a non-object and masks lower flat fallbacks

fields:
  only when the selected node is an object
  coerce string, integer, finite real, and boolean scalars through Document.scalarString
```

The owned field slices are required because scalar coercion may format numbers and
booleans. They also make inspection safe across picker calls and later config publication.
Use a fixed `"presets." ++ name` stack buffer sized from the 63-byte name limit for key
selection; dots inside `name` remain literal object-member bytes.

Refactor current private node selection only as needed to share these rules. Existing
lookup and enumeration behavior must remain byte-for-byte compatible. Allocation-failure
tests must release every already-coerced field.

## ConfigWriter types

Create `src/config/ConfigWriter.zig`:

```zig
const ConfigWriter = @This();

pub const maximum_file_bytes: usize = Loader.maximum_file_bytes;
const temp_prefix = ".zi-config.tmp.";

pub const NonceError = AtomicReplace.NonceError;
pub const NonceSource = AtomicReplace.NonceSource;
pub const OpsError = AtomicReplace.OpsError;
pub const CreateTempError = AtomicReplace.CreateTempError;
pub const CommitOps = AtomicReplace.CommitOps;

pub const Definition = struct {
    provider: []const u8,
    model: ?[]const u8,
    effort: ?[]const u8,
    system_prompt: ?[]const u8,
    system_prompt_append: ?[]const u8,
    tint: ?[]const u8,
};

pub const SaveKind = enum { saved, updated };

pub const SaveOutcome = union(enum) {
    written: SaveKind,
    state_shadow,
    no_path,
    unusable,
    conflict,
    malformed_presets,
    too_large,
    invalid: Preset.Invalid,
    failed,

    pub fn deinit(self: *SaveOutcome, allocator: std.mem.Allocator) void;
};

pub const Options = struct {
    secure_open: SecureOpen.Capability,
    nonce_source: ?NonceSource = null,
    commit_ops: CommitOps = .standard,
    home: ?[]const u8,
    cwd: ?[]const u8,
};
```

Only `.invalid` owns dynamic bytes, allocated with the caller-supplied
`outcome_allocator`. Every other outcome is allocation-free. The command must install
`defer outcome.deinit(outcome_allocator)` immediately after a successful return; `deinit`
releases the invalid report and poisons the union.

The stable owner is:

```zig
pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    secure_open: SecureOpen.Capability,
    nonce_source: ?NonceSource,
    commit_ops: CommitOps,
    path: ?[]u8,
    source: SourceState,
    expected: ?Loader.Fingerprint,
    document_value: Document,
    presets_value: Preset.Enumeration,
    state_document: ?*const Document,
    home: ?[]const u8,
    cwd: ?[]const u8,
    generation: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config_result: *?Loader.Result,
        initial_presets: *Preset.Enumeration,
        state_document: ?*const Document,
        options: Options,
    ) error{OutOfMemory}!*Owner;

    pub fn deinit(self: *Owner) void;
    pub fn document(self: *const Owner) *const Document;
    pub fn plans(self: *const Owner) []const Preset.Plan;
    pub fn invalid(self: *const Owner) []const Preset.Invalid;
    pub fn lookup(self: *const Owner, name: []const u8) Preset.BorrowedLookup;
    pub fn inspect(
        self: *const Owner,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) error{OutOfMemory}!Preset.SaveInspection;
    pub fn configPath(self: *const Owner) ?[]const u8;
    pub fn configRoot(self: *const Owner) ?[]const u8;
    pub fn generationValue(self: *const Owner) u64;

    pub fn savePreset(
        self: *Owner,
        outcome_allocator: std.mem.Allocator,
        name: []const u8,
        definition: Definition,
    ) error{OutOfMemory}!SaveOutcome;
};
```

`SourceState` is private and distinguishes `no_path`, `unusable`, and `writable`.
Writable covers loaded, empty, and missing files; `expected == null` means the path was
missing at load.

`init` is transactional. It allocates the owner and any synthetic `{}` document before
moving values. On success it:

- consumes `config_result` by setting the optional to null;
- consumes `initial_presets` by setting it to undefined;
- moves a loaded document or installs the synthetic empty document;
- moves the path and fingerprint when present;
- retains only documented process-lifetime borrows for state document, home, cwd,
  SecureOpen context, nonce context, and commit ops context.

On allocation error, both input owners remain valid. At the StartupConfig call site,
`presets_owned` remains true until `ConfigWriter.init` succeeds; success immediately
sets it false and installs `errdefer config_writer.deinit()` before any later fallible
selection composition. This prevents the old enumeration errdefer from touching a moved
value. `deinit` destroys presets before the document and frees the optional path.

## ConfigWriter candidate and save

Keep the candidate private:

```zig
const Candidate = struct {
    document: Document,
    presets: Preset.Enumeration,
    storage: []u8,
    bytes_len: usize,
    kind: SaveKind,

    fn bytes(self: *const Candidate) []const u8;
    fn deinit(self: *Candidate, allocator: std.mem.Allocator) void;
};
```

`bytes` is bounded to 1 MiB and may contain credentials or prompts from unrelated
config fields. `Candidate.deinit` securely zeros the complete allocation before freeing
it on every path. JSON-tree allocations use `Document`'s wiping allocator. The candidate
owns all allocations until publication.

`savePreset` executes:

```text
repeat name and field validation
inspection = inspect current documents
if inspection.state_shadow -> state_shadow
if source no_path/unusable -> typed outcome
candidate = prepareCandidate
  document/preset aggregate bounds -> too_large
  invalid target -> owned invalid report allocated by outcome_allocator
atomic = AtomicReplace.commit(exact candidate bytes)
conflict/target_unavailable/unavailable/failed -> destroy candidate and map outcome
written:
  expected = installed fingerprint
  swap document_value and candidate.document
  swap presets_value and candidate.presets
  generation += 1
  destroy retired pair and bytes
  return written(candidate.kind)
```

`prepareCandidate` performs:

1. Clone the current stable document by bounded stringify and `Document.parse`.
2. Reject a direct root `presets` member whose value is not an object.
3. Remove the exact root member `presets.NAME`.
4. Create `presets` when absent.
5. Build a fresh nested definition object in this insertion order:
   `description`, `tint`, `provider`, `model`, `effort`, `system_prompt`,
   `system_prompt_append`.
6. Preserve only the authoritative inspection's scalar-coerced description.
7. Replace nested `NAME` literally.
8. Pretty-serialize into a fixed-cap bounded buffer.
9. Parse those exact bytes into the final candidate document.
10. Enumerate presets against candidate config and stable state using prompt roots from
    path/home/cwd.
11. Require lookup of `NAME` in the candidate enumeration to be a valid plan.

Map `Document` input, string, field, token, and depth bound failures plus
`Preset.TooManyPresets` and retained-data overflow to `.too_large`. Propagate only OOM.
Invalid JSON or a non-object root after serializing a controlled candidate is an internal
invariant failure mapped to `.failed`.

If target lookup is invalid, clone its `Preset.Invalid` with `outcome_allocator` into
`.invalid` before destroying the candidate enumeration. Missing is an internal invariant
failure mapped to `.failed`. Every preparation error occurs before temporary-file creation.

After rename, publication uses swaps and scalar assignments only. Candidate cleanup then
destroys the displaced old document and enumeration. No function that can return an
error is called between the successful rename and pair swap.

## Config root exports

Update `src/config/root.zig`:

```zig
const AtomicReplace = @import("AtomicReplace.zig");
pub const ConfigWriter = @import("ConfigWriter.zig");

// existing exports

test {
    _ = AtomicReplace;
    _ = ConfigWriter;
    // existing registrations
}
```

Do not export `AtomicReplace` through the package seam.

## PresetSave CLI policy

Create `src/cli/PresetSave.zig` with no dependency on terminal input or
`InteractiveCommands`.

```zig
pub const Tint = enum {
    teal,
    violet,
    rose,
    sage,

    pub fn canonical(self: Tint) []const u8;
};

pub fn parseTint(value: []const u8) ?Tint;

pub const Arguments = struct {
    name: []const u8,
    tint_text: ?[]const u8,
};

pub fn parse(argument: ?[]const u8) ?Arguments;

pub const SelectionFacts = struct {
    generation: u64,
    provider: []const u8,
    model: []const u8,
    effort: ?[]const u8,
    active_preset: ?[]const u8,
    model_discovered: bool,
};

pub const InitialTint = union(enum) {
    none,
    unsupported,
    selected: Tint,
};

pub const Inspection = struct {
    path: ?[]u8,
    exists: bool,
    detail: ?[]u8,
    initial_tint: InitialTint,

    pub fn deinit(self: *Inspection, allocator: std.mem.Allocator) void;
};

pub const Request = struct {
    name: []const u8,
    tint: ?Tint,
    selection: SelectionFacts,
};

pub const Source = struct {
    context: *anyopaque,
    inspect_fn: *const fn (
        *anyopaque,
        std.mem.Allocator,
        []const u8,
        ?[]const u8,
    ) anyerror!Inspection,
    save_fn: *const fn (
        *anyopaque,
        std.mem.Allocator,
        Request,
    ) anyerror!config.ConfigWriter.SaveOutcome,

    pub fn inspect(
        self: Source,
        allocator: std.mem.Allocator,
        name: []const u8,
        active_preset: ?[]const u8,
    ) !Inspection;

    pub fn save(
        self: Source,
        outcome_allocator: std.mem.Allocator,
        request: Request,
    ) !config.ConfigWriter.SaveOutcome;

    pub fn from(implementation: anytype) Source;
};
```

`parse` preserves the complete tint tail after skipping the separator between name and
tint. It performs no allocation. `parseTint` is ASCII case-insensitive and excludes
`none`; only the picker represents no tint.

`Inspection` owns only path and display detail. `Tint` makes a selected value independent
of row-label storage. `InitialTint` distinguishes no configured tint from an unsupported
scalar: both start at index zero, but only `.none` marks the `none` row current. Inspection
deinit frees both optional slices.

`PresetSave.Source.from` requires a mutable single-item pointer. The implementation must
copy all inspection bytes, allocate any returned invalid report with `outcome_allocator`,
and not retain request slices after `save` returns.

Register the file privately in `src/cli/root.zig`:

```zig
const PresetSave = @import("PresetSave.zig");

test {
    _ = PresetSave;
}
```

## StartupConfig ownership change

Change `State`:

```diff
 const State = struct {
     allocator: std.mem.Allocator,
     tiers: config.Loader.InitialTiers,
     state_writer: ?*config.StateWriter.Owner,
+    config_writer: *config.ConfigWriter.Owner,
     base: config.Store.Options,
     facts: StartupFacts,
     selection: config.Selection,
-    presets: config.Preset.Enumeration,
     providers: config.ProviderDefinitions.Enumeration,
     warnings: []Warning,
 };
```

In `prepare`:

```text
load tiers and collect warnings
initialize stable StateWriter
compute initial document pointers
create initial Preset.Enumeration
create ProviderDefinitions.Enumeration
ConfigWriter.init consumes tiers.config + initial presets
recompute base.file = config_writer.document()
initialize Selection from the stable base
compose provisional selection with config_writer lookup/plans
store all owners
```

The provider enumeration must finish before the config load result is consumed. It owns
its output and does not retain config nodes.

`deinitState` order becomes:

```text
warnings
providers
selection
config_writer
state_writer
tiers remnants
```

The config writer is destroyed before the state writer because it borrows the stable
state document. Selection is destroyed before either document owner because its Store
borrows both slots.

Replace all `state.presets` access with `state.config_writer` delegation. Replace
`configResult()` with:

```zig
pub fn configPath(self: *const Owner) ?[]const u8;
pub fn configRoot(self: *const Owner) ?[]const u8;
```

Update initial/final composition helpers to accept a `*const ConfigWriter.Owner` or its
current lookup/plans rather than a standalone enumeration.

## StartupConfig preset-save source

`StartupConfig.zig` imports `PresetSave.zig` and implements:

```zig
pub fn inspectPresetSave(
    self: *const Owner,
    allocator: std.mem.Allocator,
    name: []const u8,
    active_preset: ?[]const u8,
) error{OutOfMemory}!PresetSave.Inspection;

pub fn savePreset(
    self: *Owner,
    outcome_allocator: std.mem.Allocator,
    request: PresetSave.Request,
) error{OutOfMemory}!config.ConfigWriter.SaveOutcome;
```

Inspection:

1. Calls `config_writer.inspect(allocator, name)` and defers owned inspection cleanup.
2. Copies the writer path when present.
3. Builds detail from scalar-coerced existing provider/model/effort, using `no provider`
   when absent.
4. Computes initial tint:
   - read effective `tint`; use it only when source is `.run`;
   - otherwise inspect active preset tint;
   - otherwise use target inspection tint;
   - return `.none` only when no scalar exists, `.selected` for a supported value, and
     `.unsupported` for any other scalar.
5. Returns owned path/detail and no document borrows.

Save:

1. Rechecks the request's live facts are structurally nonempty.
2. Reads `system_prompt` and `system_prompt_append` through the current Store.
3. Includes raw values only for `.run`, `.conversation`, `.env`, and `.state`.
4. Omits `.config`, `.default`, and absent values.
5. Forms a borrowed `ConfigWriter.Definition`:
   - provider from request;
   - model null when `model_discovered`, otherwise current model;
   - effort from request;
   - capture-eligible prompt values;
   - canonical tint string or null.
6. Calls `config_writer.savePreset(outcome_allocator, ...)` synchronously so any
   returned invalid report has caller-owned lifetime.
7. Releases owned Store results after the writer has copied candidate fields.

The method never reads `RunSelection.snapshot()`.

Add `config_nonce_source` to `StartupConfig.PrepareInputs` and forward it to
`ConfigWriter.Options`. Production gets it from `ProcessAdapters.Random`; tests use the
same deterministic nonce fake pattern as StateWriter.

## Picker adapters

Add to `SelectionPicker.zig`:

```zig
pub const PresetOverwriteOutcome = enum {
    canceled,
    keep,
    overwrite,
};

pub fn presetOverwrite(
    allocator: std.mem.Allocator,
    runner: Runner,
    name: []const u8,
    detail: ?[]const u8,
) !PresetOverwriteOutcome;

pub const PresetTintOutcome = union(enum) {
    canceled,
    selected: ?PresetSave.Tint,
};

pub fn presetTint(
    runner: Runner,
    base_theme: render.Theme,
    initial: PresetSave.InitialTint,
) !PresetTintOutcome;
```

`presetOverwrite` allocates only its bounded title, builds two stack rows, starts at row
0, and marks `keep it` current. A null runner result maps to `.canceled`.

`presetTint` builds five stack rows. Row 0 is `none`, current only for `.none`, with exact
description. A supported `.selected` tint marks and selects its row. `.unsupported`
selects index zero but marks no row current, matching malformed Hax definitions. Four
typed tint rows use `base_theme.withTint` for label color. The selected row maps
immediately to a typed value; no row slice escapes.

Tests capture the runner call and assert exact title, labels, detail, description,
current bits, initial index, tint color, mapping, cancellation, and all allocation
failures.

## Slash and command outcomes

Change both outcome enums to tagged unions with a borrowed preseed payload:

```zig
// Slash.zig
pub const HandlerOutcome = union(enum) {
    handled,
    history_changed,
    exit,
    preseed: []const u8,
};

// Interactive.zig
pub const CommandOutcome = union(enum) {
    handled,
    history_changed,
    exit,
    preseed: []const u8,
};
```

Payload bytes are borrowed only through synchronous outcome handling. Existing inferred
literal returns such as `return .handled` remain valid. Audit every qualified enum value,
equality assertion, and switch in `Slash`, `Interactive`, and `InteractiveCommands`:
union tests use `std.meta.activeTag` or exhaustive switches rather than enum equality.
`InteractiveCommands.execute` maps every tag, including the borrowed payload.

In `Interactive.run`, extend the command outcome switch:

```zig
.preseed => |bytes| {
    if (inputs.prompt_input) |input| try input.queuePreseed(bytes);
    continue;
},
```

This remains after session recall admission. `sanitized` command bytes remain alive until
the synchronous queue call returns. Cooked mode has `prompt_input == null`, so it drops
the seed immediately.

## PromptInput and RawLineInput

Extend `Interactive.PromptInput`:

```zig
queue_preseed_fn: *const fn (*anyopaque, []const u8) anyerror!void,

pub fn queuePreseed(self: PromptInput, bytes: []const u8) !void;
```

`PromptInput.from` calls `implementation.queuePreseed(bytes)` when declared; otherwise its
adapter is a no-op so existing focused fakes need no meaningless storage.

Add one field and two methods to `terminal.RawLineInput`:

```zig
pending_preseed: ?[]u8 = null,

pub fn deinit(input: *RawLineInput) void;

pub fn queuePreseed(
    input: *RawLineInput,
    bytes: []const u8,
) error{ OutOfMemory, PromptTooLarge }!void;
```

`queuePreseed` rejects bytes longer than `max_prompt_bytes`, duplicates first, then frees
and replaces the prior seed. Empty bytes clear the pending value only after successful
validation.

At the start of `read`:

```text
move pending_preseed to a local
clear the field immediately
install defer to free the local seed
create LineEditor
set editor buffer from local seed
begin history read
enter terminal
paint
```

The defer is installed before fallible `LineEditor.setBuffer`, so its OOM path cannot
leak the moved seed. The seed is consumed even if setting the editor, terminal entry, or
painting fails. The
existing `LineEditor.setBuffer` places the cursor at the end and preserves atomic OOM
behavior. `RawLineInput.deinit` frees an unused seed and asserts it is not active before
poisoning owned fields.

`PrintRun.runRawInteractive` adds `defer raw_input.deinit()` immediately after init and
before any later error path.

Tests cover initial seed, replacement, replacement OOM, too-large rejection, empty
clear, one-shot consumption, cursor-at-end behavior through a factored editor setup
helper, read failure after consumption, and deinit with an unused seed.

## InteractiveCommands ownership

Import `PresetSave.zig`. Add to `Owner`:

```zig
preset_save_source: ?PresetSave.Source = null,

pub fn setPresetSaveSource(self: *Owner, source: PresetSave.Source) void {
    self.preset_save_source = source;
}
```

Register immediately after `/preset`:

```zig
.{
    .name = "preset-save",
    .summary = "save the current selection as a preset (name, optional tint)",
    .arguments = .optional,
    .display = .managed,
    .handler_fn = runPresetSave,
},
```

Extract the named application half of `runPreset`:

```zig
fn activateNamedPreset(self: *Owner, name: []const u8) !void;
```

It performs the authoritative detailed preflight, `RunSelection.preparePreset`, commit,
retired cleanup, transcript rebuild, banner/switch notice, and only then the persistence
warning. This preserves current Zi and pinned Hax announcement order. `runPreset` retains
only optional picker selection and then calls this helper.

`runPresetSave` follows this exact stack:

```text
source/live missing -> defensive no-provider diagnostic
before = live.current()
provider empty -> exact provider diagnostic
model empty -> exact model diagnostic
arguments missing:
  print and flush name-it note
  return .{ .preseed = "/preset-save " }
invalid name -> exact escaped-name diagnostic
invalid explicit tint -> exact escaped-tint diagnostic
inspection = source.inspect(name, before.preset)
if exists:
  no picker -> keep
  picker keep/cancel -> unchanged note and stop
if no explicit tint:
  no picker -> stop silently
  tint picker cancel -> stop silently
if live.current().generation != before.generation:
  print selection-changed diagnostic and stop
outcome = source.save(live.allocator, request from before)
defer outcome.deinit(live.allocator)
written:
  print saved/updated note and flush
  activateNamedPreset(name)
state_shadow/no_path/unusable/conflict/malformed/failed:
  print exact safe diagnostic and stop
too_large:
  print exact bounded-configuration diagnostic and stop
invalid:
  reuse detailed invalid-preset renderer and stop
```

All name, tint, and path bytes pass through `DiagnosticText.write`. No untrusted content
is emitted directly. Path diagnostics use the owned `Inspection.path`; no borrow survives
config publication.

The explicit tint is canonicalized before save. The command compares generation after
all picker calls, not after persistence. Once config save starts, the synchronous command
model prevents another live selection transaction from interleaving. The source must
allocate `.invalid` payloads with `live.allocator`; the unconditional outcome defer owns
that payload through diagnostic rendering.

The save announcement is flushed before calling `activateNamedPreset`. If output fails,
config remains saved and activation is skipped by error propagation.

## PrintRun wiring

Extend `ProcessAdapters.Random`:

```zig
pub fn configNonceSource(self: *Random) config.ConfigWriter.NonceSource;
```

It shares the existing random fill implementation but returns the writer-specific alias.
Pass it into `StartupConfig.prepare` beside `state_nonce_source`.

After `StartupConfig.finish`, construct once:

```zig
const preset_save_source = PresetSave.Source.from(&startup);
```

Both cooked and raw `InteractiveCommands.Owner` receive it through
`setPresetSaveSource`. Cooked mode still receives no picker and no PromptInput, so only a
fresh explicit-tint save can proceed without TTY interaction.

Replace `startup.configResult()` prompt-root use with `startup.configRoot()`.

No new renderer wiring is needed. Successful activation already refreshes command theme,
Markdown theme, prompt facts, transcript, banner, and session metadata.

## Tests by file

### `config/AtomicReplace.zig`

Move or adapt StateWriter's existing operation fakes. Assert:

- loaded, empty, and missing expected-target checks;
- no-write `checkTarget` behavior used by unchanged StateWriter requests;
- same-size content conflict through digest;
- target appearance/disappearance/replacement conflict;
- unsafe parent and final symlink refusal;
- 32 bounded temp collisions;
- write, sync, temp identity, and rename failures;
- successful installed fingerprint;
- cleanup after every pre-rename failure;
- every allocation failure before rename preserves target bytes.

### `config/StateWriter.zig`

Keep all existing behavior tests. Add only a mapping assertion if needed for
`AtomicReplace.conflict -> StateWriter.failed`. This is a refactor gate, not new state
behavior.

### `config/Preset.zig`

Cover inspection of:

- missing target;
- valid nested state/config precedence;
- malformed nested values;
- exact flat state/config fallback;
- literal dotted names;
- any-type existence;
- nested-state-object shadow only;
- scalar-coerced string, integer, finite-real, and boolean detail/description/tint;
- non-object dotted-stage masking of lower flat fallbacks;
- every partial scalar-coercion allocation failure.

### `config/ConfigWriter.zig`

Cover:

- loaded, empty, missing, unusable, and no-path initialization ownership;
- stable document address before and after first save;
- unknown root-field preservation and exact flat-key removal;
- member order and two-space bounded serialization;
- description preservation and optional-field replacement;
- malformed `presets` root, state shadow, and invalid saved prompt;
- target saved/updated classification from authoritative any-type existence;
- complete candidate reparse and enumeration limits mapped to `.too_large`;
- secure zeroing of candidate bytes on success and every failure;
- conflict and every injected commit failure;
- rename success followed by allocation-free pair publication;
- immediate lookup/plans/invalid cache visibility;
- every allocation failure with no leaks or partial publication.

### `cli/PresetSave.zig`

Cover whitespace parsing, literal tint tails, case-insensitive canonical tint, explicit
`none` rejection, typed request forwarding, inspection ownership, adapter signatures,
and allocation cleanup.

### `cli/StartupConfig.zig`

Cover config result and preset enumeration transfer, stable Store resolution after save,
config path/root access, source-aware prompt capture for all six sources, explicit empty
capture, discovered model omission, initial tint precedence including unsupported scalar
tints, owned inspection, caller-allocator save outcomes, and forwarding.

### `cli/SelectionPicker.zig`

Cover exact overwrite and tint rows, safe initial indexes, cancellation mapping, tint
preview styles, selected typed values, no retained rows, and OOM cleanup.

### `cli/Interactive.zig` and `terminal/RawLineInput.zig`

Cover Zi's established recall-before-execute-before-preseed ordering, borrowed payload
copied before sanitized line release, cooked discard, adapter no-op fallback, every union
outcome migration, preseed bounds, replacement atomicity, `setBuffer` OOM cleanup,
one-shot consumption, cursor position, and deinit.

### `cli/InteractiveCommands.zig`

Cover registry order and exact help summary; provider/model/name/tint diagnostics;
missing-name preseed; overwrite keep/cancel; tint cancel; generation mismatch; every
save outcome; safe path/name/tint escaping; announcement flush before activation;
save-success/activation-failure partial state; and preset-specific state warning.

## Built-binary probes

Use only `./zig-out/bin/zi` with temporary XDG roots and the mock provider.

1. `printf '/help\n'` shows `/preset-save` after `/preset` and before `/compact`.
2. Cooked fresh explicit save writes expected JSON, emits no ANSI, activates the preset,
   updates `state.json`, and allows immediate `/preset NAME` and `/new NAME` reuse.
3. Cooked no-tint invocation cancels without changing bytes.
4. PTY bare invocation prints the note and preloads `/preset-save ` exactly once.
5. PTY tint picker verifies title, initial row, preview color, Enter, Escape, and no
   alternate-screen sequence.
6. PTY overwrite verifies keep default, cancellation, explicit overwrite, preserved
   description, and refreshed cache.
7. Same-name nested state object refuses with byte-identical config.
8. Invalid config, unsafe target, read-only parent, and external edit preserve bytes and
   live selection with exact diagnostics.
9. Environment and state prompt overrides serialize as raw scalars; config/default
   values are omitted; assembled project context never appears.
10. A controlled activation-failure seam proves the durable saved definition and cache
    survive while live selection remains old. If no deterministic binary fixture can
    interpose between save and activation, retain this as a highest-level CLI integration
    test rather than adding timing-dependent production behavior.
11. State-write failure keeps the new live preset and emits one preset-specific warning.

## Vertical implementation slices

### Slice 1: stable config publication foundation

Implement `AtomicReplace`, refactor StateWriter through it, add `ConfigWriter`, transfer
StartupConfig ownership, and replace `configResult()` with root/path accessors. Do not
register `/preset-save` yet.

Verification:

```sh
export PATH=/tmp/zig-x86_64-linux-0.16.0:$PATH
zig fmt --check src/
PKG_CONFIG_PATH=/tmp/zi-pkgconfig zig build
zig test src/root.zig \
  -I/tmp/zi-curl-dev/usr/include/x86_64-linux-gnu \
  -L/tmp/zi-curl-lib -lcurl -lc --test-filter 'atomic replace'
zig test src/root.zig \
  -I/tmp/zi-curl-dev/usr/include/x86_64-linux-gnu \
  -L/tmp/zi-curl-lib -lcurl -lc --test-filter 'config writer'
zig test src/root.zig \
  -I/tmp/zi-curl-dev/usr/include/x86_64-linux-gnu \
  -L/tmp/zi-curl-lib -lcurl -lc --test-filter 'startup config'
```

Directly prove stable Store reads and current preset lookup after writer publication.
Stop for review if ownership transfer changes any existing startup or `/preset` result.

### Slice 2: complete save command and picker path

Add `PresetSave`, source-aware StartupConfig capture, overwrite/tint picker adapters,
command registration and diagnostics, shared named activation helper, and cooked/raw
source wiring. Missing-name invocation prints the final note but does not preseed until
Slice 3.

Verification:

- focused policy, picker, StartupConfig, and command tests;
- built binary explicit-tint save through config, cache, activation, state, and next
  prompt;
- PTY overwrite/tint success and cancellation;
- controlled save-success/activation-failure integration test.

### Slice 3: bounded one-shot preseed and certification

Change slash/interactive outcomes, add `PromptInput.queuePreseed`, add RawLineInput
ownership and cleanup, and return preseed from bare `/preset-save`.

Verification:

- focused Interactive and RawLineInput allocation/order tests;
- PTY preseed and cooked-discard probes;
- all built-binary probes above;
- mechanical symbol/registry checks;
- `ziglint` when available;
- the full project ready gate.

After every slice, update this document's implementation ledger before continuing. At the
user's requested checkpoint, Slices 1 and 2 were committed as `ae797c55`
(`feat(cli): save current selection as preset`). Slice 3 remains a separate reviewable
preseed commit.

## Implementation ledger

### Slice 1 — complete

- Extracted `config/AtomicReplace.zig` with stage-sensitive outcomes, final-name
  restats, direct filesystem/cleanup/collision/OOM tests, and unchanged-target support.
- Routed `StateWriter` through the shared helper without changing its public types or
  outcome mapping.
- Added `ConfigWriter.Owner` with stable document and preset-cache slots, bounded exact
  candidate bytes, scalar description preservation, fingerprint conflict rejection,
  and allocation-free pair publication.
- Added owned scalar preset inspection with Hax nested/flat masking and state-shadow
  semantics.
- Transferred config Loader and preset enumeration ownership in `StartupConfig`; retained
  Store values and existing preset views observe publication through stable pointers.
- Replaced broad config-result access with `configPath`/`configRoot`, and wired a
  production ConfigWriter nonce source.
- Existing `/preset` PTY picker, cancellation, tint, prompt refresh, and state probe
  remains passing.

### Slice 1 verification

- `zig fmt --check src/` — pass.
- `zig build` — pass.
- Focused AtomicReplace tests — pass.
- Focused ConfigWriter publication, preservation, validation, conflict, shadow, and OOM
  tests — pass.
- Focused preset inspection and StartupConfig ownership/OOM tests — pass.
- Existing preset transaction and PTY probes — pass.
- Read-only final review — no P1/P2 blockers.

### Slice 2 — complete

- Added `cli/PresetSave.zig` with allocation-free argument parsing, typed canonical tints,
  owned inspection values, and a synchronous erased source.
- Added StartupConfig overwrite detail, active/target tint precedence, source-aware raw
  prompt capture, discovered-model omission, and ConfigWriter forwarding.
- Added exact overwrite and tint picker rows with safe defaults, typed results, color
  previews, cancellation, and propagated runtime failures.
- Registered `/preset-save` between `/preset` and `/compact`, extracted shared named
  activation, and implemented control-safe diagnostics and save-then-activate ordering.
- Factored the command shell for deterministic tests without changing production
  RunSelection ownership; injected activation failure leaves the written result truthful.
- Wired one startup-backed source into cooked and raw command owners.
- Extended exact Hax provenance in `THIRD_PARTY_NOTICES.md`.

### Slice 2 verification

- Focused PresetSave policy, StartupConfig capture, picker, orchestration, and complete
  InteractiveCommands suites — pass.
- Direct command tests cover preconditions, parsing, safe diagnostics, picker keep/cancel
  and errors, generation mismatch, every save outcome, request forwarding, observed flush
  before activation, and activation failure after a successful save.
- Built cooked save proves JSON publication, immediate cache activation/reuse, help order,
  state stance, prompt source capture, malformed-root diagnostics, and ANSI-free output.
- PTY probes prove tint selection/cancellation, overwrite keep/replace, description
  preservation, external-edit refusal, normal-buffer behavior, and existing `/preset`
  regression behavior.
- Final read-only review — no P1/P2 blockers.

### Slice 3 — complete

- Converted Slash and Interactive command outcomes to tagged unions with a synchronously
  borrowed preseed payload, including exhaustive mapping and active-tag tests.
- Added optional `PromptInput.queuePreseed`; adapters without that method remain no-ops,
  and cooked mode discards payloads immediately.
- Added bounded atomic preseed replacement to `RawLineInput`, moved ownership before every
  read attempt, seeded `LineEditor` at cursor end, and released unused or consumed bytes.
- Added production `RawLineInput.deinit` and installed it immediately after initialization.
- Bare `/preset-save` now prints the name hint and seeds `/preset-save ` once in TTY mode.

### Slice 3 verification

- Focused preseed, Slash, Interactive, InteractiveCommands, and RawLineInput suites pass.
- Tests cover recall-before-execute-before-copy ordering, borrowed payload lifetime,
  adapter fallback, cooked discard, bounds, replacement OOM, editor setup OOM, terminal
  entry failure, cursor position, one-shot ownership, and unused-seed teardown.
- The built PTY probe completed a save by typing only the tail after the preloaded text and
  proved the following prompt was clean. All prior cooked and PTY preset-save probes pass.
- `zig fmt --check src/`, `zig build`, `./zig-out/bin/zi --help`, and
  `./zig-out/bin/zi --version` pass. `ziglint` is unavailable.
- `zig build test` records 1620 of 1728 tests passing, with 9 failures, 99 crashes, and 6
  leaks in the documented Zig filesystem/BADF baseline. The feature-focused tests pass.
- Final read-only review found no P1/P2 blockers.

## Acceptance ledger

- [x] Shared atomic helper preserves StateWriter behavior.
- [x] Config owner consumes initial load result and owns stable document plus preset cache.
- [x] Complete candidate is bounded, reparsed, re-enumerated, and published as one pair.
- [x] External edits and unsafe files never get overwritten.
- [x] Raw inspection matches nested/flat Hax precedence and state shadowing.
- [x] Captured provider/model/effort/prompts/tint obey source and discovery rules.
- [x] Overwrite and tint pickers match exact rows, defaults, colors, and cancellation.
- [x] `/preset-save` diagnostics and help order are exact and control-byte safe.
- [x] Saved/updated announcement precedes shared preset activation.
- [x] Activation failure leaves config/cache saved and live selection unchanged.
- [x] Bare command seeds the next TTY editor exactly once; cooked mode discards it.
- [x] Prompt facts, tint, banner, transcript, and state stance refresh immediately.
- [x] Allocation failures in preset-save paths leak nothing and publish nothing before rename.
- [x] Built-binary probes use only this checkout's `./zig-out/bin/zi`.
- [x] Required ready gate result is recorded without weakening baseline failures.
