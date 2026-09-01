# Preset command system architecture

Status: approved

References:

- `docs/preset-config-research.md`
- `docs/preset-product.md`
- Hax behavior revision `189816fb8b02956a6913d7638e6d2cc90a91d61a`
- ZigAI design revision `e2c5aef5f93015322891028a2048a217e7081687`

## Decision

Reuse Zi's existing move-only preset transaction. `/new PRESET` and `/preset NAME`
share preparation and publication. `/new` keeps only its conversation transition and
quarantine work around that transaction.

Keep presentation changes small. Preset tint affects banner stance and Markdown roles,
not prompt chrome, pickers, spinner, status, or tool output. `PrintRun.LiveViews`
publishes the value directly to the command owner and Markdown renderer.

## Runtime flow

```text
Interactive.run
  command gateway
    InteractiveCommands.runPreset
      named argument or SelectionPicker.preset
      borrowed preflight lookup for diagnostics
      RunSelection.Owner.preparePreset
        authoritative cached lookup
        config.Selection.preparePreset
        LiveBuilder.build prospective Store
          reread @file prompt references
          build current prompt preset facts synchronously
        SessionDurability.prepareSelection
        ToolRuntime.prepareRunSelection
      RunSelection.Owner.commitPreset
        publish overlay, provider, prompt, metadata, and tools
        advance generations
        publish catalog, stats, compaction, tint views
        write active preset stance to state.json
      retire displaced ownership
      RunLogSeam.rebuildTranscript
      banner or switch notice
```

No allocation, terminal output, provider callback, or prompt callback runs inside live
publication. State writing follows publication and returns `run_only` instead of
rolling back.

## Process-owned registry

`StartupConfig.Owner` already owns the bounded `config.Preset.Enumeration`. The
`RunSelection.ConfigSource` adapter gains borrowed reads for:

- exact lookup, already present;
- valid plans for the picker;
- current active preset tint after overlay publication.

`RunSelection.Owner` exposes synchronous `lookupPreset` and `presetPlans` methods.
Preparation repeats lookup so picker preflight cannot bypass the transaction.

Startup keeps invalid reports after emitting startup warnings. This permits a later
named command to explain the cached failure. The loaded config document remains fixed
for the process lifetime in this slice.

### Prompt references

A `Preset.Plan` retains the original scalar system-prompt values rather than the text
read from `@file`. Startup validation still resolves each reference once to reject an
unreadable, non-regular, oversized, or invalid path. `LiveBuilder` resolves the raw
value again for every application. This gives fresh contents without reloading or
mutating the registry.

### Future cache replacement

`PromptAssembly.Inputs` must not retain name or description slices from the preset
cache. Initial prompt construction and every `LiveBuilder.build` call create temporary
`agent.Context.Preset` facts from the current cache, build the owned prompt, and then
free the temporary array.

After this change, the picker and prompt builder borrow plans only synchronously. The
later `/preset-save` transaction can replace the loaded config document and enumeration
together, then retire the old pair without coordinating hidden prompt-template slices.

## Picker adapter

`SelectionPicker` adapts plans to `terminal.Picker.Item`, like its provider and model
adapters. It receives valid plans, provider choices, current preset, below-run base
theme, and the existing runner. Knownness combines those choices with the complete
compiled provider registry, including aliases and non-selectable test providers.

One arena owns:

- sorted source indices;
- a provider-id hash set;
- picker rows;
- formatted detail strings.

The hash set includes every provider choice regardless of availability. A provider is
known when either the complete compiled registry recognizes it or the set contains its
config-defined id. This covers aliases such as `llama.cpp` and non-selectable `mock`.
Unknown providers receive only the Hax diagnostic detail and stay selectable. The
selected row maps back to the source-plan index. Nothing survives the synchronous call.

## Shared preset transaction

The existing `PresetCandidate` remains the sole owner of prospective live state.
Preparation:

1. checks owner stability and reentrancy;
2. resolves the exact cached plan;
3. duplicates the active name;
4. prepares the preset overlay;
5. constructs provider, prompt, and model-derived policy against its Store;
6. prepares coordinated or quarantined session metadata;
7. validates tool selection;
8. returns the complete candidate.

Every acquisition gets immediate `errdefer` cleanup. The authority input is a tagged
enum, not a boolean. Plain `/preset` uses `coordinated`; `/new` selects coordinated or
quarantined transition authority.

Publication keeps current order:

1. publish overlay;
2. move provider, prompt, image, context, and sort policy;
3. publish session and append-log metadata;
4. publish Bash selection and model provenance;
5. advance selection and preset-transition generations;
6. publish derived views;
7. leave the commit section;
8. attempt state persistence.

Displaced values return in `RetiredPreset`. Plain `/preset` deinitializes them after
commit. `/new` first moves old-log settlement ownership into `TransitionSelection`, then
deinitializes the remaining retired values. Transcript rebuild borrows only the new
live selection and session.

## Tint publication

`RunSelection.Derived` gains borrowed `preset_tint`. `LiveViews` owns the resolved
below-run base theme and optional pointers to the active `InteractiveCommands.Owner`
and `MarkdownStreamRenderer`.

On derived publication it computes:

```text
preset tint when present
otherwise below-run configured tint
otherwise teal
```

`render.Theme.withTint` is value-only and allocation-free. Valid plans guarantee preset
tint syntax; invalid below-run tint falls back to teal as startup recovery does.

The command owner stores the immutable below-run base theme for picker previews.
Cooked mode binds only that owner directly in `PrintRun.run`. Raw mode receives
`*LiveViews`, binds the command owner and Markdown renderer after both stack addresses
are stable, then clears the pointers before either leaves scope. The Markdown renderer
stores the theme for its next turn. Reused Markdown state receives it during reset.

No other long-lived presentation value changes because Zi and Hax keep all non-Markdown
roles independent of tint.

## Output policy

After commit and transcript rebuild, `InteractiveCommands` checks session items:

- empty: existing banner renderer with `live.current()`;
- non-empty: direct bounded writes of preset, provider label, model label, and effort.

Direct writes avoid a fixed-buffer truncation fallback. `DiagnosticText` sanitizes each
untrusted configured value. Output failure does not roll back committed state.

Preset persistence has its own once-per-process warning latch, matching Hax's
separate preset path. Earlier provider, model, or effort persistence failures do not suppress the
preset-specific warning.

## Failure boundaries

- Missing and cached-invalid definitions fail before candidate preparation.
- Picker cancellation is a successful no-op.
- Picker allocation, provider-choice, or stale-generation failure leaves state intact.
- Candidate failure deinitializes all prospective values and leaves live owners intact.
- Publication has no recoverable failure.
- Transcript rebuild remains advisory under the existing run-log seam.
- State failure keeps live state and warns once.
- Terminal failure returns after committed state remains authoritative.

## Module boundaries

- `src/config/Preset.zig`: validated definitions with raw prompt references.
- `src/config/Selection.zig`: prospective overlay and active tint.
- `src/cli/StartupConfig.zig`: loaded document, enumeration, and invalid reports.
- `src/cli/RunSelection.zig`: live candidate and publication.
- `src/cli/SelectionPicker.zig`: row adaptation.
- `src/cli/InteractiveCommands.zig`: command policy and diagnostics.
- `src/cli/PrintRun.zig`: composition, prompt facts, and concrete tint views.
- `src/render/Theme.zig`, `Markdown.zig`, `MarkdownStreamRenderer.zig`: value-only
  between-turn tint update.

`src/main.zig` and public package seams do not change.
