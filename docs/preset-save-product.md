# Preset save product contract

Status: approved

References:

- `docs/preset-save-research.md`
- `docs/preset-product.md`

## Problem

Zi can enter a preset but cannot turn the current working selection into one. Users must
leave the conversation, hand-edit `config.json`, restart Zi, and reproduce settings that
already exist in the live process. That interrupts the workflow and makes useful stances
hard to keep.

`/preset-save` lets the user name the current stance, optionally give it a tint, persist
it safely, and enter it immediately.

## User outcome

After this capability ships, a user can run:

```text
/preset-save review rose
```

and get a durable `review` preset containing the current provider, eligible model,
effort, and prompt overrides. Zi announces the save, activates `[review]`, refreshes its
tint and prompt facts, and makes the preset available to `/preset` and `/new review`
without restarting.

## Command

The help registry places the command between `/preset` and `/compact` until `/config`
exists:

```text
/preset-save  save the current selection as a preset (name, optional tint)
```

It has no alias. Arguments follow this grammar:

```text
/preset-save NAME [TINT]
```

`NAME` is the first whitespace-delimited token. Zi skips whitespace after it and treats
the complete remaining tail as `TINT`. Trailing tint whitespace remains literal for Hax
parity.

## Preconditions

Zi checks these in order before parsing the name:

1. A live provider must exist. Otherwise:

   ```text
   no provider selected — use /provider to choose one first
   ```

2. A nonempty resolved model must exist. Otherwise:

   ```text
   no model resolved yet — use /model to pick one first
   ```

A missing name then prints:

```text
name it: /preset-save <name> [tint]
```

In an interactive terminal, the next prompt is prefilled with `/preset-save ` and the
cursor sits after the space. The seed is consumed once. Cooked input discards it so a
later interactive read cannot receive stale text.

## Name validation

Names are 1 to 63 bytes. The first byte must be ASCII alphanumeric. Remaining bytes may
be ASCII alphanumeric, `.`, `-`, or `_`.

Invalid names print:

```text
'NAME' can't be a preset name — use letters, digits, '.', '-' or '_', starting with a letter or digit
```

Zi does not trim, rewrite, or case-fold names.

## Tint behavior

An explicit tint accepts `teal`, `violet`, `rose`, or `sage` case-insensitively and saves
the canonical lowercase value. Invalid tint prints:

```text
unknown tint 'VALUE' (expected teal|violet|rose|sage)
```

Without an explicit tint, Zi opens the normal-buffer picker:

```text
tint for this preset
  none     Carry no tint of its own: your tint setting applies
  teal
  violet
  rose
  sage
```

Tint rows preview their colors. `none` means the preset has no tint member. Escape,
Ctrl-C, or cancellation abandons the save without output.

The initial row follows this priority:

1. Current run-only tint.
2. Active preset tint.
3. Existing target preset tint when overwriting.
4. `none`.

If an existing malformed definition contains an unsupported scalar tint, the picker
starts at row zero but marks no row current; it does not misrepresent that value as
`none`.

Zi snapshots the live selection before opening either picker. If that selection changes
before persistence, Zi saves nothing and reports:

```text
selection changed while choosing preset options — run /preset-save again
```

## Existing definitions

Any same-name state or config value counts as existing, even when malformed. Zi asks
before replacement:

```text
preset 'NAME' already exists
  keep it    Leave the existing definition alone
  overwrite  Replace it with the current selection
```

`keep it` is the safe default. Escape and cancellation also keep the definition. A
non-overwrite result prints:

```text
left preset 'NAME' unchanged
```

The overwrite row shows the existing provider, model, and effort when available, or
`no provider` when no provider can be read. Existing string, number, and boolean scalars
use the same canonical text conversion as normal configuration reads.

Zi preserves only an existing scalar `description`, converted to canonical text. Every
other supported member is replaced from the current selection or omitted. Unknown or
malformed preset members are not carried into the new definition.

## State shadowing

Zi preserves Hax's exact shadow rule. A nested object at `state.presets.NAME` blocks a
config save because it would outrank the new nested config definition:

```text
preset 'NAME' is defined in state.json, which outranks the config file — remove it there first
```

Malformed nested state scalars and flat compatibility values still count as existing for
confirmation, but do not block the config write.

Refusal leaves `config.json`, the preset cache, and the live selection unchanged.

## Captured fields

The saved definition contains only these supported fields, in this user-facing order:

1. Existing scalar `description`, converted to canonical text when overwriting.
2. Selected `tint`, unless `none`.
3. Canonical live `provider` ID.
4. Current `model`, unless it was discovered from provider server state.
5. Current `effort`, when present.
6. Raw `system_prompt`, when capture-eligible.
7. Raw `system_prompt_append`, when capture-eligible.

No endpoint, credential, context-window value, recording option, provider header,
discovered project instruction, or unrelated setting is saved.

A discovered model is omitted so entering the preset rediscovers current provider state.
Provider and resolved model remain prerequisites for the command.

## Prompt capture and privacy

Zi matches Hax's source-aware prompt behavior:

- Omit absent prompt values.
- Omit config and registry-default values because ordinary resolution reproduces them.
- Copy raw run, conversation, environment, and state overrides, including explicit empty
  values.
- Preserve raw `@file` references rather than copying file contents.
- Never save the assembled turn prompt or discovered project context.

This means an explicitly invoked preset save may copy a prompt override from an
environment variable, resumed conversation, or state into mode-0600 `config.json`. It
never copies provider credentials or general environment values. The explicit command,
private file mode, narrow allowlist, and Hax parity make this an accepted behavior rather
than a silent background export.

## Config preservation and safety

Zi updates only the target preset while preserving unknown root fields and unrelated
configuration. It removes a same-name flat `presets.NAME` fallback before writing the
nested definition, so the file cannot retain two config definitions for the saved name.

The rewrite uses two-space JSON indentation. Existing formatting, duplicate-key layout,
and numeric spelling are not preserved.

When no config directory can be resolved, Zi reports:

```text
couldn't locate the config directory
```

Zi refuses to write when the loaded config was malformed, oversized, unreadable,
non-regular, a final symlink, or otherwise unsafe:

```text
couldn't read PATH — fix or remove it first
```

If the file has changed since Zi loaded it, Zi does not overwrite the external edit:

```text
PATH changed since zi started — restart before saving a preset
```

A candidate that would exceed the bounded document or preset-cache limits reports:

```text
couldn't save preset 'NAME' — configuration data exceeds a safe limit
```

Other persistence failures report:

```text
couldn't write PATH
```

All failures before publication leave the loaded config document, preset cache, and live
selection unchanged. Temporary files are private, bounded, and cleaned up best-effort.
The replacement follows Zi's existing state-writer durability contract: file sync and
same-directory atomic rename, without adding a cross-process lock or requiring parent
directory sync in this slice.

The final fingerprint check deliberately narrows Hax's lost-update behavior. A small
unavoidable check-to-rename race remains for uncoordinated external writers; Zi does not
create a lock protocol that ordinary editors would ignore.

## Save and activation are two commits

Zi preserves Hax's truthful two-commit sequence:

1. Persist `config.json` and publish the refreshed config document and preset cache.
2. Print one of:

   ```text
   saved preset 'NAME' in config.json
   updated preset 'NAME' in config.json
   ```

3. Activate the saved definition through the existing `/preset` transaction.
4. Persist the active preset stance through the existing state writer.

If activation fails, the preset remains saved and available. The success announcement
already printed remains true, followed by the detailed activation error. Zi does not
roll back a durable user-authored config change because provider state changed.

Successful activation uses the existing fresh banner for an empty conversation and the
existing switch notice for a nonempty conversation. A state persistence failure keeps
the saved preset active and emits the preset-specific run-only warning once:

```text
couldn't save to state.json — this preset applies to this run only
```

## Normal-buffer behavior

Overwrite confirmation and tint selection use Zi's normal-buffer picker. They never
enter an alternate screen. Completion, cancellation, interruption, and failure restore
the prompt and terminal modes exactly as `/preset` does.

Cooked execution emits no ANSI styling. A no-tint picker cannot run in cooked mode and is
treated as cancellation; scripts should supply an explicit tint if they want a save.

## Success criteria

The capability is successful when:

- `/help` lists `/preset-save` in the correct order with exact summary text.
- Explicit saves persist only the allowlisted current-selection fields.
- Saved presets are immediately visible to `/preset`, `/new`, and prompt facts.
- Tint and overwrite pickers have safe defaults and cancel without mutation.
- Existing descriptions survive overwrite; unsupported members do not.
- State shadow, unusable config, concurrent edit, and write failure preserve all live
  state and bytes.
- Activation failure leaves a valid saved definition and reports the activation problem.
- Prompt capture obeys source rules and never serializes assembled context.
- Missing-name preseed is one-shot in TTY mode and discarded in cooked mode.
- Every retained allocation and every partial candidate is released on failure.
- No command path emits alternate-screen sequences.

## Non-goals

This capability does not:

- implement `/config`;
- save arbitrary settings;
- edit preset descriptions;
- preserve unsupported fields inside an overwritten preset;
- merge with a state-defined nested preset;
- delete or rename presets;
- provide cross-process locking;
- make configuration changes from another process visible without restart;
- resolve the host's pre-existing Zig filesystem test baseline.

## Product decisions

This contract resolves the research questions as follows:

1. Reuse Zi's existing file-sync-plus-rename durability contract; do not add directory
   sync or uncertain-publication poisoning in this slice.
2. Reject observed external edits with fingerprints; do not add an advisory lock.
3. Match Hax prompt capture, including environment, state, conversation, and run sources,
   while retaining raw references and excluding credentials and assembled context.
4. Match Hax's nested-state-object shadow rule exactly.
5. Preserve save-before-activation and announce the durable save before activation.
6. Implement bounded one-shot next-editor preseeding now.
7. Preserve a scalar description in canonical text form when overwriting; drop unsupported members.
