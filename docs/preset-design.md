# Preset command program design

Status: implemented; native full-suite certification blocked by the reproduced clean-HEAD filesystem baseline

References:

- `docs/preset-config-research.md`
- `docs/preset-product.md`
- `docs/preset-architecture.md`

## File changes

```text
src/
├── config/
│   └── Preset.zig                    retain raw prompt scalars after validation
├── cli/
│   ├── StartupConfig.zig             keep invalid reports addressable
│   ├── RunSelection.zig              expose plans/lookup/tint; generalize names
│   ├── SelectionPicker.zig           add preset row adapter
│   ├── InteractiveCommands.zig       add descriptor, handler, diagnostics, output
│   ├── NewConversation.zig           use renamed shared preset API
│   └── PrintRun.zig                  cache-safe prompt facts and concrete tint views
└── render/
    ├── Theme.zig                     derive another valid tint
    ├── Markdown.zig                  accept theme on reset
    └── MarkdownStreamRenderer.zig    store theme for next turn
```

No new module or public package export is needed.

## Raw prompt retention

`config.Preset.promptMember` keeps validation and changes ownership transfer:

```text
read scalar
resolve scalar once to validate path and contents
release resolved text
return owned original scalar
```

Inline values remain unchanged. `@file` references survive in `Plan`, so
`config.Selection.preparePreset` writes the reference into the prospective overlay and
`LiveBuilder.build` performs the existing `PromptValue.resolve` on each application.

Tests prove startup rejects bad files, valid plans retain `@path`, repeated builds read
changed contents, and a deleted file fails without publication.

`StartupConfig.finish` stops filtering invalid entries out of `state.presets`. Warnings
remain separately owned. Update the existing test that currently requires removal and
add named borrowed-lookup coverage after finish.

## Config source

Add to `RunSelection.ConfigSource`:

```zig
preset_plans_fn: *const fn (*anyopaque) []const config.Preset.Plan,
preset_tint_fn: *const fn (*anyopaque) ?[]const u8,

pub fn presetPlans(self: ConfigSource) []const config.Preset.Plan;
pub fn presetTint(self: ConfigSource) ?[]const u8;
```

`ConfigSource.from` adapts the existing `StartupConfig.Owner.presetPlans()` and `tint()`
methods. Its local test fake in `RunSelection.zig` and the fake in
`NewConversation.zig` gain the same two methods.

Add to `RunSelection.Owner`:

```zig
pub fn lookupPreset(self: *const Owner, name: []const u8) config.Preset.BorrowedLookup;
pub fn presetPlans(self: *const Owner) []const config.Preset.Plan;
```

Both are synchronous borrowed views. `RunSelection.Derived` adds:

```zig
preset_tint: ?[]const u8,
```

`Owner.derived()` reads `config_source.presetTint()` only after overlay publication.

## Shared transaction names

Use one preparation API:

```zig
pub const PresetAuthority = enum {
    coordinated,
    quarantined_transition,
};

pub fn preparePreset(
    self: *Owner,
    name: []const u8,
    authority: PresetAuthority,
) !PresetCandidate;

pub fn commitPreset(
    self: *Owner,
    candidate: *PresetCandidate,
    retired: *RetiredPreset,
) CommitResult;
```

This renames the existing implementation rather than adding a second front.
`InteractiveCommands` passes `.coordinated`. `NewConversation` maps prior quarantine to
the enum. Remove the unused `PresetCandidate.session_only` field.

Keep commit order exactly as current code: both generation counters advance before
`views.publish(self.derived())`; state writing remains after `committing = false`.

Plain `/preset` may deinitialize `RetiredPreset` immediately after commit. `/new` keeps
its existing extraction of `TransitionSelection`, early retired deinit, transcript
rebuild, and settlement order.

## Picker API

Add:

```zig
pub const PresetOutcome = union(enum) {
    canceled,
    selected: usize,
};

pub fn preset(
    allocator: std.mem.Allocator,
    runner: Runner,
    plans: []const config.Preset.Plan,
    providers: []const ProviderConfig.ProviderChoice,
    current_preset: ?[]const u8,
    base_theme: render.Theme,
) !PresetOutcome;
```

`render.Theme` adds:

```zig
pub fn withTint(self: Theme, configured_tint: []const u8) Error!Theme;
```

The picker:

1. returns `canceled` for no plans;
2. creates one arena;
3. inserts every provider-choice id into an arena-backed `StringHashMapUnmanaged(void)`;
4. allocates and sorts source indices by plan name;
5. creates rows in sorted order;
6. treats a provider as known when `ai.ProviderRegistry.find` recognizes it or the
   choice set contains it, covering aliases, `mock`, and config-defined ids;
7. for known providers, formats explicit provider, model, and effort segments;
8. for unknown providers, writes only `unknown provider 'ID'` and dims the row;
9. uses description directly;
10. previews `plan.tint` through `base_theme.withTint`, or base tint when absent;
11. runs the picker and returns the source index.

A configured provider remains known even when `available == false`. `label_color` is
null when the resulting stance style has no open sequence.

Allocation-failure tests exercise the complete adapter and non-retaining fake runner.
Bounds are 1,024 plans and 4,096 provider definitions, so the hash set avoids millions
of worst-case prefix comparisons.

## Cache-safe prompt facts

Replace the long-lived `prompt_template.presets = prompt_presets` arrangement in
`PrintRun` with one helper:

```zig
fn buildPromptWithPresets(
    allocator: std.mem.Allocator,
    io: std.Io,
    template: PromptAssembly.Inputs,
    plans: []const config.Preset.Plan,
) !?PromptAssembly.OwnedPrompt;
```

The helper allocates a temporary `agent.Context.Preset` array, borrows each plan's name
and description for the synchronous build, and frees the array before returning the
owned prompt.

Initial startup uses the helper. The long-lived template stores `.presets = &.{}`.
`LiveBuilder` gains a `preset_source: *const StartupConfig.Owner` and calls the helper
with `preset_source.presetPlans()` after resolving the prospective role prompt. This
removes all retained slices into the replaceable enumeration.

## Theme composition

At startup, read `tint` once through `store.readBelowRun` and derive `base_theme` from
the already resolved theme name. Store it in the command owner through
`setPresetBaseTheme`:

```zig
const base_theme = theme.withTint(below_run_tint orelse "teal") catch
    try theme.withTint("teal");
```

`LiveViews` gains:

```zig
base_theme: render.Theme,
commands: ?*InteractiveCommands.Owner = null,
markdown: ?*render.MarkdownStreamRenderer = null,
```

Its existing `publishSelectionViews` computes:

```zig
const selected_theme = if (derived.preset_tint) |tint|
    self.base_theme.withTint(tint) catch unreachable
else
    self.base_theme;
if (self.commands) |commands| commands.setTheme(selected_theme);
if (self.markdown) |markdown| markdown.setTheme(selected_theme);
```

`InteractiveCommands.Owner` gains `preset_base_theme: render.Theme`, initialized to
its current theme, plus `setPresetBaseTheme`. `runPreset` passes that field to the
picker.

Cooked mode sets the base theme, binds `live_views.commands`, and defers clearing it.
Add `live_views: *LiveViews` to `runRawInteractive`; raw mode sets the base theme,
binds both pointers after their stack values are initialized, and clears both before
return.

`InteractiveCommands.Owner.setTheme` copies one value.
`MarkdownStreamRenderer.setTheme` asserts no active turn and stores one value.
`MarkdownStreamRenderer.begin` supplies that value to both new and reused Markdown
instances. Change `Markdown.reset(width)` to `Markdown.reset(theme, width)`.

No prompt, picker chrome, plain renderer, tool presentation, session replay, spinner, or
raw-input update is needed because those paths use tint-independent roles.

## Command registration

Insert between effort and compact:

```zig
.{
    .name = "preset",
    .summary = "switch to a config-defined preset (optional: name)",
    .arguments = .optional,
    .display = .managed,
    .handler_fn = runPreset,
},
```

## Command flow

```text
runPreset
  before = live.current()
  if no argument
    plans = live.presetPlans()
    if empty, write no-presets note
    choices = live.providerChoices()
    selected = SelectionPicker.preset(..., owner.preset_base_theme)
    cancel or reject stale generation
    name = plans[selected].name
  else
    name = exact argument
  preflight = live.lookupPreset(name)
  report missing or invalid
  candidate = live.preparePreset(name, .coordinated)
  report setup failure with current state untouched
  result = live.commitPreset(candidate, &retired)
  retired.deinit()
  rebuild transcript from new live session
  write preset-specific warning through shared latch
  if live.session.items().len == 0
    render banner
  else
    write direct preset switch notice
  return handled
```

The handler preflights for diagnostics, then preparation repeats authoritative lookup.
Every diagnostic uses `DiagnosticText` for names, fields, providers, and values.

`writePresetNotice` writes style, `[`, preset, `]`, provider display name, model label
or model id, and optional effort directly. It does not allocate or truncate.

Add `preset_persistence_warning_written` beside the existing generic selection latch.
`writePresetPersistenceWarning` uses the new latch and exact preset wording. Provider,
model, or effort persistence failures do not suppress it.

## Tests

### Config and ownership

- raw prompt retention plus startup validation;
- changed and removed prompt-file behavior;
- retained invalid lookup after `StartupConfig.finish`;
- ConfigSource plans and tint callbacks in production and both fakes;
- coordinated preset prepare/commit, re-selection, state payload, derived tint,
  retirement, and every preparation allocation failure;
- dynamic prompt facts contain current plans without retaining cache slices.

### Picker

- bytewise order and source-index mapping;
- active row, description, known detail, unknown detail, unavailable-known provider,
  compiled alias, and non-selectable mock provider;
- tint preview and no-color theme;
- cancellation and every allocation failure.

### Commands and presentation

- exact registry order and interactive help summary;
- named success, active re-selection, no plans, missing and invalid definitions;
- unknown provider, setup failure, picker cancellation, and stale generation;
- transcript rebuild and independent one-time preset warning;
- empty banner and full non-empty notice with model label;
- Markdown reset receives selected tint;
- failure before commit preserves all captured state.

### Built binary

With temporary Zi XDG roots and `ZI_PROVIDER=mock`:

1. `printf '/help\n' | ./zig-out/bin/zi` shows `/preset` between `/effort` and
   `/compact`.
2. Piped `/preset review` followed by a prompt proves next-turn selection, transcript,
   session metadata, and preset-only state stance.
3. Editing a valid referenced prompt file before re-selection changes the next prompt;
   deleting it preserves the old live selection.
4. Invalid and unknown-provider presets preserve state and next request.
5. Read-only state produces live success and one run-only warning.
6. A PTY covers picker search, Enter, Escape, normal-buffer restoration, tinted banner,
   and tinted Markdown after selection.
7. `/new review` uses the same tint publication.

## Completion ledger

- Confirm descriptor order and all ConfigSource implementations mechanically.
- Confirm `/new PRESET` and `/preset` call the same transaction.
- Confirm no long-lived prompt slice points into the preset cache.
- Run focused and allocation-failure tests.
- Run `ziglint` on changed Zig files.
- Run the full native ready gate.
- Exercise only `./zig-out/bin/zi` for end-to-end probes.
- Update `THIRD_PARTY_NOTICES.md` for preset selection, picker behavior, prompt
  re-expansion, and tint publication.
- Commit as `feat(cli): add preset selection`.

## Implementation outcome

Implemented the complete named and picker command through the shared preset candidate.
The final code keeps valid `@file` references raw and rereads them per application,
removes long-lived prompt slices into the preset cache, publishes banner and Markdown
tint between turns, preserves provider-specific model labels, and shares detailed
preflight and preset warning behavior with `/new PRESET`.

Focused tests cover picker rows and allocation failures, preset candidate rollback and
retirement, raw prompt ownership, retained invalid diagnostics, independent persistence
warnings, help order, and plain cooked banners. Built-binary probes cover named success,
invalid and unknown providers, state-write failure, normal-buffer picker success and
cancellation, tint, transcript rebuild, state stance, and same-process prompt-file
refresh.

On this Ubuntu host the ready gate passes formatting, build, help, and version. The full
test command remains blocked by the same Zig 0.16 filesystem behavior reproduced in a
detached clean worktree at `62ad0358`: 10 ordinary filesystem-test failures and 99
`BADF` crashes. The implementation worktree has the same counts. `ziglint` is not
installed on the host.
