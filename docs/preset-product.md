# Preset command product contract

Status: approved

References:

- `docs/preset-config-research.md`
- Hax behavior revision `189816fb8b02956a6913d7638e6d2cc90a91d61a`
- ZigAI design revision `e2c5aef5f93015322891028a2048a217e7081687`

## Problem

Zi can apply a preset only through `/new PRESET`. A user cannot move the current
conversation to a favorite selection or configured role without clearing history or
restarting the process.

## Scope

Add `/preset [NAME]` to the interactive REPL. This slice selects existing preset
definitions. It does not create, edit, rename, or delete them.

`/preset-save` follows in a separate slice with an atomic `config.json` writer and one
prepared replacement of the loaded document and preset cache. `/config` and `/fork`
remain out of scope.

## Registry and admission

Registry order becomes:

```text
new, resume, undo, provider, model, effort, preset, compact, help
```

The descriptor is:

```text
/preset [NAME]  switch to a config-defined preset (optional: name)
```

The command accepts the complete optional argument after leading separator whitespace.
It preserves trailing whitespace, matching Hax. Configured preset names are literal and
case-sensitive. The 63-byte save-name grammar belongs to `/preset-save`, not selection.

A recognized invocation stays in process-local prompt recall but never enters model
context, persistent prompt history, or conversation history.

## Named selection

`/preset NAME` performs exact lookup.

- Missing definitions report that the preset was not found.
- Invalid cached definitions report the field and validation reason.
- Unknown providers report the preset and provider ids.
- Provider, prompt, model, tool, or allocation failure reports that the current
  selection was kept.
- Selecting the active name still reconstructs the provider and prompt.

For a preset that passed startup validation, every application rereads `@file` system
prompt references. Changed content takes effect; a deleted or newly unreadable file
makes application fail without changing the live selection. Zi does not reload the
configuration document during a run, so a definition rejected at startup remains
invalid until restart. This is narrower than Hax's per-command re-enumeration and keeps
Zi's bounded process-owned registry authoritative until `/preset-save` adds prepared
cache replacement.

Failure before publication leaves provider, model, effort, prompt, tools, context and
image policy, session metadata, transcript, tint, and state unchanged.

## Picker selection

Bare `/preset` opens the normal-buffer picker. With no valid presets it prints:

```text
no presets defined in config.json — use /preset-save to save the current selection
```

The picker:

- is titled `select a preset`;
- sorts names bytewise in ascending order;
- starts on and marks the active preset;
- shows the description;
- shows explicit `provider · model · effort` for known providers;
- shows `unknown provider 'ID'` and dims unknown providers without disabling them;
- treats a configured but unavailable provider as known;
- previews the tint that applying each preset would select;
- uses the existing filtering, resize, cancellation, and restoration behavior.

Invalid definitions do not appear in the picker but remain addressable by exact name.
Cancellation and non-TTY picker refusal are successful no-ops. A selection-generation
change while the picker is open discards the result.

## Successful application

Zi prepares all fallible work before publication:

- preset overlay;
- provider and resolved model;
- effort;
- freshly expanded and assembled system prompt;
- model metadata, image policy, context limit, and model order;
- session and append-log metadata;
- Bash child-process selection.

Publication is allocation-free, non-failing, and between turns. It updates the live
selection and all derived views while preserving conversation items and usage totals.

After live publication, Zi writes only the active preset name to `state.json`. A write
failure keeps the live preset and warns once per process:

```text
couldn't save to state.json — this preset applies to this run only
```

The next durable conversation item records the new selection through the existing
session metadata path.

## Presentation

For a conversation with no items, redraw the startup banner with the selected preset,
provider, model, effort, and tint.

For a non-empty conversation, print the complete bounded values directly:

```text
switched to [PRESET] PROVIDER · MODEL [· EFFORT]
```

Use the provider display name and model display label when present.

Applying a preset clears a prior run-tier tint, matching Hax and Zi's existing preset
overlay. The chosen preset tint wins, then tint below the run tier, then teal. Immediate
tint publication changes the banner and subsequent Markdown stance, inline code, code
blocks, headings, and links. Prompt, picker chrome, spinner, status, diff, warning, and
error colors do not depend on preset tint. Picker row previews use the same effective
policy.

Because `/new PRESET` shares publication, its fresh banner and later Markdown also gain
the selected tint.

## Limits

Existing limits remain:

- at most 1,024 total cached preset definitions;
- at most 1 MiB retained preset data;
- existing JSON, prompt-file, picker, title, frame, and output bounds.

Picker rows and provider-id lookup storage live in one arena for one synchronous picker
call. No command retains submitted input, plans, rows, or diagnostic buffers.

## Acceptance checks

- Interactive `/help` places `/preset` between `/effort` and `/compact`.
- Named and picker selection use one transaction.
- The next request uses the selected provider, model, effort, freshly expanded prompt,
  tools, context/image policy, and metadata.
- Session metadata, transcript, state stance, banner or notice, and Markdown tint agree.
- Re-selecting a preset rereads a changed valid prompt file.
- Missing, invalid, unknown-provider, no-model, prompt, allocation, and stale-picker
  failures preserve complete live state.
- State failure emits one preset-specific warning without rollback.
- Picker tests cover order, current row, description, detail, tint, unknown provider,
  cancellation, and normal-buffer restoration.
- Built-binary probes use temporary Zi XDG roots, `ZI_*` variables, and the mock
  provider. Zi accepts no Hax runtime namespace.
- `ziglint` and the full ready gate pass natively.
