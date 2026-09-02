# Preset save system architecture

Status: approved

References:

- `docs/preset-save-research.md`
- `docs/preset-save-product.md`
- `docs/preset-architecture.md`

## Boundary

`/preset-save` is one user capability with two durable transactions:

1. Write and publish a preset definition in `config.json`.
2. Enter that definition through the existing live preset transaction and persist the
   active stance in `state.json`.

The first transaction is new. The second remains owned by `RunSelection` and
`StateWriter`. The command layer sequences them and deliberately does not merge their
rollback domains.

The new config writer is preset-scoped. It preserves the complete config document but
only exposes preset inspection and save operations. `/config` may later broaden the
writer's mutation contract together with the additional caches and runtime policies that
settings changes require.

## Component ownership

```text
config.Loader
  transfers config path, document, outcome, fingerprint
        |
        v
config.ConfigWriter.Owner  <---- stable state Document borrow
  owns stable config Document slot
  owns current Preset.Enumeration
  owns config path, usability, expected fingerprint, generation
  prepares complete document + enumeration candidates
  commits and publishes both together
        |
        v
cli.StartupConfig.Owner
  owns ConfigWriter.Owner transitively
  owns Store and Selection borrowers of stable document slots
  resolves source-aware prompt capture
  implements cli.PresetSave.Source
        |
        +---------------------------+
        v                           v
cli.InteractiveCommands       cli.RunSelection
  owns command UX              owns existing live preset activation
  overwrite/tint policy        owns provider/model/effort/runtime publication
  save announcement            owns state stance persistence
        |
        v
cli.Interactive
  admits command history
  transfers optional preseed
        |
        v
terminal.RawLineInput
  owns and consumes bounded next-read preseed
```

`ConfigWriter.Owner` is heap-stable. Every long-lived `config.Store` points to its config
`Document` slot, whose address never changes. The writer replaces the slot's contents,
not the slot itself.

`ConfigWriter.Owner` also owns `Preset.Enumeration`. This keeps the config document and
all preset plans under one publication authority. `StartupConfig.lookupPreset`,
`presetPlans`, and `invalidPresets` delegate to the current writer-owned enumeration.

Provider-definition enumeration remains separately owned by `StartupConfig`. The writer
cannot mutate `providers`, so `/preset-save` does not refresh or publish provider
configuration.

## Initial ownership transfer

Startup keeps the current load order but changes final ownership:

```text
Loader.loadInitialTiers
  StateWriter consumes state Loader.Result
  Preset.enumerate(initial config, stable state document)
  ConfigWriter consumes config Loader.Result + initial enumeration
  Store points at stable ConfigWriter document + stable StateWriter document
  Selection and provider runtime copy that Store value
```

The config load result is consumed exactly once. It is not retained beside the writer.
The writer owns:

- the loaded document when valid;
- a synthetic empty object when the file is empty, missing, unusable, or unavailable;
- the resolved path when one exists;
- the initial fingerprint when the source exists coherently;
- a writability state distinguishing missing, writable, unusable, and no-path sources.

A synthetic empty document makes the stable pointer available even when `config.json`
did not exist at startup. This is resolution-equivalent to the current null config tier,
but permits the first successful save to publish without rebuilding every retained
`Store`.

Malformed, oversized, unreadable, non-regular, and final-symlink sources remain
non-writable for the process. Their synthetic empty document supports the same startup
fallback behavior without erasing the writer's refusal reason.

The current broad `StartupConfig.configResult()` exposure is replaced by narrow
config-path and config-root accessors. Prompt-file resolution continues to derive its
root from the writer-owned path without borrowing the consumed load result.

## Preset-save source seam

A new CLI-owned `PresetSave.Source` separates command interaction from config ownership.
It is an erased synchronous interface implemented by `StartupConfig.Owner` and faked by
command tests.

It has two responsibilities:

1. Inspect a target name for overwrite interaction.
2. Save the current selection after all interaction has completed.

Inspection returns an owned, bounded value containing:

- whether any same-name state or config value exists;
- displayable existing provider, model, and effort detail;
- initial-tint facts for run, active preset, and target preset precedence;
- enough status for command wording, but no mutable JSON node.

The command may retain inspection across two picker calls, so it must not borrow the
replaceable config document or enumeration. Inspection is advisory. Save repeats all
authoritative structure, state-shadow, validation, and fingerprint checks.

The save request borrows, for one synchronous call:

- validated name and canonical optional tint;
- canonical live provider ID;
- resolved live model;
- current effort;
- whether the model was discovered.

`StartupConfig.Owner` augments this request with raw prompt values and their source. It
passes only capture-eligible values to `ConfigWriter`; no assembled turn prompt crosses
the seam.

Save returns a typed result distinguishing:

- newly saved;
- updated;
- state shadow;
- unusable or unavailable config;
- external-edit conflict;
- malformed `presets` root;
- persistence failure.

Allocation failure remains an error. All other expected runtime failures are values so
the command can print exact diagnostics without stringly typed ownership.

## Existing-definition inspection

Preset inspection lives in `config.Preset` because it owns nested/flat compatibility and
tier precedence. It examines raw state and config documents rather than only valid plans.

The inspection policy matches pinned Hax:

```text
exists = any same-name nested or flat value in state or config
state shadow = nested state value is an object
selected value = first nested object in state/config; otherwise first dotted lookup
                 result in state/config, even when that value is not an object
existing detail/description/tint = scalar-coerced fields when selected value is an object
```

Malformed values still make `exists` true. A non-object selected value provides no fields
and can mask a lower flat fallback exactly as in Hax. A malformed root
`presets` value cannot yield a nested member; authoritative save later reports the root
shape error.

Description is not trusted from the UX inspection. During candidate preparation the
writer rereads the authoritative current documents and preserves any coercible scalar
description in canonical text form.

## Source-aware capture

Capture is split between the live selection and startup config owners:

- `RunSelection.CurrentSelection` supplies the resolved provider, model, effort, active
  preset, and `model_discovered` bit.
- `StartupConfig` reads raw `system_prompt` and `system_prompt_append` through `Store`,
  including their source tags.
- `ConfigWriter` receives a config-neutral definition and serializes only allowed fields.

Prompt-source policy is:

```text
run | conversation | env | state -> capture raw scalar
config | default                    -> omit
absent                              -> omit
```

The Store results are owned for the synchronous save call and released afterward. The
writer copies values into the candidate document before they are released. Raw `@file`
references remain raw. Model is omitted when `model_discovered` is true.

This architecture does not expose `RunSelection.CurrentSelection` to `config`; it
prevents the config module from depending outward on CLI runtime types.

## Config candidate

Preparation constructs one move-only candidate owning:

- owner identity and generation;
- the complete replacement config `Document`;
- the complete replacement `Preset.Enumeration`;
- the exact bounded two-space-indented bytes destined for disk;
- whether the target was new or existing.

All allocation and semantic validation happen before any temporary file is created.
Name and field validation run first; the exact nested-state-object shadow check precedes
config path and startup-usability reporting, matching Hax:

```text
repeat name and field validation
repeat exact nested-state-object shadow check
check config path and startup usability
clone current bounded config tree
reject non-object root "presets"
remove exact flat root key "presets.NAME"
create/reuse nested "presets"
replace nested member NAME in approved field order
serialize into a bounded 1 MiB buffer
parse those exact bytes through Document.parse
re-enumerate all presets against candidate config + stable state
require NAME to resolve as a valid plan
```

Reparsing the exact output bytes reapplies document depth, field, token, string, and file
bounds. Re-enumeration reapplies preset count, retained-data, schema, tint, and prompt
reference checks. Unrelated malformed presets remain owned invalid reports and do not
block a valid save unless an enumeration-wide bound is exceeded.

The candidate document is exactly the document that will be published after those bytes
reach disk. No second serialization occurs during commit.

## Filesystem commit

The commit adapts the established `StateWriter` policy inside `config`; it does not import
`StateWriter` as another writer and does not depend on `persistence`.

```text
make/open parent directory
reject non-directory or group/other-writable parent
create exclusive mode-0600 sibling temporary
write exact candidate bytes
sync temporary file
verify temporary descriptor and name identify the same regular one-link file
perform authoritative destination fingerprint check
rename temporary over config.json
record candidate fingerprint
```

The writer tries bounded random temporary names and cleans an unrenamed file best-effort.
It rejects a final target symlink, unsafe target type, disappearance/replacement of an
expected file, or appearance of a target expected to be missing.

A coherent fingerprint mismatch maps to the external-edit conflict. Unsafe inspection,
parent failure, temporary failure, write, sync, or rename failure maps to persistence
failure. An optional early fingerprint check may avoid expensive preparation but never
replaces the authoritative check immediately before rename.

There is no `ProcessSpawn` involvement: the operation spawns no process and descriptors
are created close-on-exec atomically.

Per the product contract, commit file-syncs before rename but does not require parent
directory sync or add a lock protocol. The final check-to-rename race against an
uncoordinated external writer remains explicit.

## Allocation-free publication

`ConfigWriter.Owner` is the only publication authority. After rename succeeds it enters
a short critical section with no allocation, I/O, callbacks, validation, or recoverable
failure:

```text
expected fingerprint = committed fingerprint
swap stable document contents with candidate document
swap current preset enumeration with candidate enumeration
generation += 1
candidate becomes retired old document + old enumeration
```

The retired pair is destroyed after publication. A process termination between rename
and swap is safe: the next process reads committed disk state. No runtime error can leave
only one of the in-memory pair replaced.

Borrow rules remain synchronous:

- Document nodes, preset plans, invalid reports, and inspection internals never survive a
  call that may publish config.
- Pickers finish before save begins.
- `RunSelection.preparePreset` runs only after publication and owns everything retained.
- Existing turn prompts and active session metadata already own their bytes.
- Prompt facts are rebuilt from the current enumeration and return owned prompt bytes.

No pinning, reference counting, or process-wide lock is required under the current
single-threaded interactive command model.

## Command sequence

```text
InteractiveCommands.runPresetSave
  current = RunSelection.current
  require provider and model
  parse NAME and optional TINT
  validate NAME and explicit TINT
  inspection = PresetSave.Source.inspect(NAME, current preset)
  if inspection.exists
    SelectionPicker.presetOverwrite
    keep/cancel -> print unchanged and stop
  if no explicit tint
    SelectionPicker.presetTint
    cancel -> stop silently
  verify live generation still equals current.generation
  PresetSave.Source.save(NAME, tint, current facts)
    StartupConfig captures raw prompt overrides
    ConfigWriter prepares, commits, and publishes
  print and flush saved/updated announcement
  activateNamedPreset(NAME)
    existing RunSelection prepare + commit
    existing banner/switch notice
    existing state stance persistence and warning
```

Generation is checked after picker interaction and before save. If some future callback
changes the live selection while a picker is open, the command reports that the
selection changed and saves nothing. The save source still repeats config authority
checks.

`activateNamedPreset` is extracted from the named half of `/preset`; `/preset`,
`/preset-save`, and `/new PRESET` continue to use the same underlying `RunSelection`
transaction. The command does not recursively dispatch slash text.

The save announcement is flushed before activation. If output fails, config remains
saved and activation is not attempted. If activation preparation fails, config and the
new cache remain published while the old live selection remains active.

## Picker architecture

`SelectionPicker` gains two row adapters over its existing generic runner:

- Preset overwrite returns keep/overwrite, with keep selected and marked current.
- Preset tint returns cancellation or an optional canonical tint, where null means
  `none`.

Rows are stack-built and synchronously borrowed by the runner. Dynamic title and detail
storage remain owned by the caller for the call. Tint labels use the existing
`Theme.withTint` result for preview. No renderer or alternate-screen component is added.

A missing runner behaves like picker cancellation:

- Existing target: keep it and print unchanged.
- Missing explicit tint: abandon silently.
- Explicit tint: no picker is needed, so cooked execution may save.

## One-shot prompt preseed

Preseed transfer belongs to `Interactive`, between command dispatch and input ownership.
The command outcome becomes a tagged result capable of carrying a synchronously borrowed
preseed slice. The command does not receive a `RawLineInput` pointer.

Ordering is:

```text
read submitted command
admit command to session recall
execute command
if outcome carries preseed and PromptInput exists
  PromptInput copies it into input-owned bounded storage
start next read
consume and clear pending seed
initialize LineEditor from seed, cursor at end
```

`PromptInput` gains an erased synchronous queue operation whose implementation must copy
before returning. `RawLineInput` owns at most one pending seed, bounded by the existing
maximum prompt size. Replacement allocates first, then frees the old value so OOM cannot
destroy an already queued seed. Deinit frees an unused seed.

At next raw read, the input moves the seed to a local owner and clears the field before
terminal setup. It remains consumed even if editor setup or terminal entry fails, which
prevents stale replay.

Cooked interactive mode has no `PromptInput`; `Interactive` discards the borrowed preseed
outcome immediately. Nothing survives to a later raw session. Zi retains its established
admit-before-execute ordering; pinned Hax differs only in the OOM-visible order of command
execution and history admission, then transfers preseed after both.

## Failure domains

| Failure point | Config/cache | Live selection | User result |
| --- | --- | --- | --- |
| Validation, inspection, capture, preparation, OOM | unchanged | unchanged | exact diagnostic or propagated runtime error |
| Picker keep/cancel | unchanged | unchanged | unchanged note or silent tint cancellation |
| Nested state object shadow | unchanged | unchanged | state-shadow diagnostic |
| External config edit | unchanged; external bytes preserved | unchanged | restart-before-save diagnostic |
| Temp/write/sync/rename failure | unchanged | unchanged | couldn't-write diagnostic |
| Rename succeeds, process exits before publication | disk committed; next start reloads | process exits | no in-process inconsistency survives |
| Save publishes, announcement fails | saved and current cache updated | unchanged | output error; no activation |
| Activation preparation fails | saved and current cache updated | unchanged | saved note, then detailed preset error |
| Activation publishes, state write fails | saved and current cache updated | new preset active for run | once-only preset warning |
| Prompt file changes after save validation | saved and current cache updated | activation may remain unchanged | saved note, then prompt diagnostic |

## Dependency direction

```text
Document, Loader, SecureOpen
          |
          v
        Preset
          |
          v
     ConfigWriter
          |
          v
     config/root.zig
          |
          v
   StartupConfig ----> PresetSave.Source
          |                    |
          v                    v
     RunSelection      InteractiveCommands
          \                    /
           \                  /
                  PrintRun

InteractiveCommands -> SelectionPicker -> terminal picker seam
Interactive -> PromptInput -> RawLineInput -> LineEditor
```

Forbidden dependencies:

- `config` importing `cli`, `RunSelection`, or `InteractiveCommands`;
- `ConfigWriter` importing `StateWriter` merely for code reuse;
- `ConfigWriter` importing `persistence.PrivateFileStore`;
- `InteractiveCommands` owning raw JSON or filesystem paths;
- `RunSelection` becoming the config-file writer;
- `RawLineInput` knowing slash commands.

If atomic replacement logic is extracted to avoid duplication, it remains a private
config helper registered by `config/root.zig`; callers still enter through the public
writer seams.

## Verification boundaries

The architecture is testable at four levels:

1. `config`: raw inspection, candidate mutation, complete revalidation, fingerprint and
   filesystem failures, pair publication, and allocation cleanup.
2. `cli`: source-aware capture, typed save outcomes, parser policy, picker rows,
   generation checks, announcement ordering, and activation partial success.
3. `terminal`: preseed copy, replacement, bound, one-shot consumption, cursor placement,
   cooked discard, and deinit.
4. Built binary: help, explicit save, picker and overwrite PTYs, prompt sources, config
   bytes, immediate `/preset` visibility, activation failure, state warning, external
   conflict, and normal-buffer restoration.

The required ready gate remains unchanged. Baseline filesystem failures must be reported
without weakening or skipping new tests.
