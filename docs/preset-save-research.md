# Preset save research

Status: approved

References:

- hax v0.4.0 at `189816fb8b02956a6913d7638e6d2cc90a91d61a`
- ZigAI at `e2c5aef5f93015322891028a2048a217e7081687`
- Zi at `95ff225309db7fe16b5894f6aa2d5d0235ca0638`
- `docs/preset-config-research.md`
- `docs/preset-architecture.md`

## Scope

This record isolates the next complete capability: `/preset-save NAME [TINT]`.
It covers the user-visible Hax contract, Zi's current ownership seams, the missing
config writer, cache replacement, selection capture, picker reuse, and editor
preseeding. `/config` remains a later capability.

The Hax checkout has advanced beyond the pinned release, so every Hax line reference
below was verified against the exact pinned object with `git show`, not against checkout
`HEAD`.

## Baseline

The `/preset` capability is committed as `95ff2253`. On this Ubuntu host,
`zig fmt --check src/`, `zig build`, `zi --help`, and `zi --version` pass. The full
suite remains blocked by the same Zig 0.16 filesystem behavior reproduced in a detached
clean worktree: 10 ordinary filesystem failures and 99 `BADF` crashes. `ziglint` is not
installed.

## Hax command contract

The command is registered immediately after `/preset` and before `/config`:

```text
/preset-save  save the current selection as a preset (name, optional tint)
```

It has optional text arguments, managed display, and no alias. Keeping it separate from
`/preset` leaves a preset named `save` unambiguous (`src/slash.c:133-152`). The slash
parser skips whitespace before the argument and passes the remaining tail without
trimming it (`src/slash.c:228-253`).

`select_preset_save` owns the interaction (`src/select.c:1020-1115`):

1. Require a live provider. Otherwise print
   `no provider selected — use /provider to choose one first`.
2. Require a nonempty resolved model. Otherwise print
   `no model resolved yet — use /model to pick one first`.
3. With no argument, print `name it: /preset-save <name> [tint]` and seed the next
   editor with `/preset-save `.
4. Parse the first whitespace-delimited token as the name. Skip whitespace after it.
   Treat the complete remaining tail as the tint.
5. Validate the name and explicit tint before asking to overwrite.
6. Ask before replacing any existing definition. Keep is the safe default; Escape and
   cancellation also keep it.
7. With no explicit tint, run the tint picker. Cancellation abandons the save.
8. Capture the live selection, save it to `config.json`, announce the save, then enter
   the new preset through the existing preset activation path.

Trailing tint whitespace is literal. `/preset-save scout rose   ` fails because the
value is `rose   `, while `/preset-save scout   ` has no tint and opens the picker.

## Name and tint rules

Names are 1 to 63 bytes. The first byte is alphanumeric; the rest permit alphanumeric,
`.`, `-`, and `_` (`src/config.c:1435-1448`). The exact error is:

```text
'NAME' can't be a preset name — use letters, digits, '.', '-' or '_', starting with a letter or digit
```

Explicit tint matching is ASCII case-insensitive and saves canonical registry spelling.
The pinned choices are `teal|violet|rose|sage`; invalid input reports:

```text
unknown tint 'VALUE' (expected teal|violet|rose|sage)
```

Without an explicit tint, the picker title is `tint for this preset`. Its rows are:

- `none` — `Carry no tint of its own: your tint setting applies`
- `teal`
- `violet`
- `rose`
- `sage`

The color rows preview their tint. `none` omits the member. The initial row is chosen in
this order (`src/select.c:918-960,1007-1018`):

1. Current run-tier tint.
2. Active preset tint.
3. Existing target preset tint when overwriting.
4. `none`.

## Overwrite and shadow behavior

Any same-name state or config value counts as existing, including malformed scalars and
flat compatibility definitions (`src/config.c:1401-1433`). The confirmation picker is:

```text
preset 'NAME' already exists
  keep it    Leave the existing definition alone
  overwrite  Replace it with the current selection
```

`keep it` is current and selected initially. Decline or cancellation prints:

```text
left preset 'NAME' unchanged
```

The overwrite detail is assembled from the existing definition's provider, model, and
effort; a missing provider displays `no provider` (`src/select.c:962-992`).

A nested object at `state.presets.NAME` outranks the nested config definition that save
would create. Hax confirms first, then refuses the write with:

```text
preset 'NAME' is defined in state.json, which outranks the config file — remove it there first
```

Only a nested state object triggers this refusal (`src/config.c:1419-1423,1466-1471`).
Malformed nested state scalars and flat state definitions still trigger confirmation but
do not block the config write. This is precise observable behavior, not a general
"anything in state shadows" rule.

If root `presets` in `config.json` exists but is not an object, save fails with:

```text
"presets" in PATH is not a block of presets — fix it first
```

Unreadable, malformed, oversized, or otherwise unusable loaded config refuses all writes:

```text
couldn't read PATH — fix or remove it first
```

## Captured definition

The serialized member order is (`src/config.c:1478-1496`):

1. Existing `description`, when overwriting and readable as a string.
2. Chosen `tint`.
3. Canonical live provider ID.
4. Current model, unless the provider reports that it was discovered.
5. Current effort.
6. `system_prompt`.
7. `system_prompt_append`.

Provider and resolved model are prerequisites even when the discovered model is omitted.
No endpoint, credential, context, recording, or unrelated setting is captured.

Prompt capture is source-aware (`src/select.c:994-1005`):

- Omit absent values.
- Omit values sourced from `config.json` or registry defaults because ordinary
  resolution will reproduce them.
- Copy run, conversation, environment, and state values, including explicit empty
  values.
- Preserve raw prompt scalars, including `@file` references; do not serialize the
  assembled prompt with discovered project context.

Re-saving preserves a valid existing description but replaces all other optional
members. A field not captured is omitted rather than retained.

## Save, cache publication, and activation

Hax validates the complete new preset before disk mutation. It deep-copies the loaded
config tree, removes the flat `presets.NAME` fallback, creates or reuses the nested
`presets` object, and replaces only member `NAME` (`src/config.c:1450-1537`). Unknown
root fields survive, but formatting, duplicate fields, and numeric spelling are
normalized by parse and pretty-print.

After the rename succeeds, Hax replaces the process config tree and clears borrowed
scalar caches (`src/config.c:1539-1543`). It then prints one of:

```text
saved preset 'NAME' in config.json
updated preset 'NAME' in config.json
```

Only then does it invoke preset activation (`src/select.c:1089-1111`). These are two
commits:

- Config failure means no save and no activation.
- Activation failure leaves the saved config definition and success announcement in
  place.
- Activation success uses the existing banner or switch notice.
- State persistence failure leaves the preset active and prints the preset-specific
  run-only warning once.

## Hax atomic write posture

The pinned `write_json_atomic` resolves a final symlink target, creates parent
directories, writes a sibling `PATH.tmp.XXXXXX`, forces mode `0600`, closes it, and
renames it over the destination. Failure unlinks the temporary file
(`src/config.c:1075-1127`).

It does not:

- bound serialized output independently of the loader limit;
- reread or fingerprint the destination before rename;
- reject a concurrent external edit;
- `fsync` the file;
- `fsync` the parent directory.

Zi must not copy those weaker properties when its existing ownership and safety rules
already provide a narrower contract.

## Zi config ownership today

`config.Document` owns a bounded dynamic `std.json.Value` object tree. Parsing enforces
a 1 MiB input cap, depth 64, 8,192 fields, 262,144 tokens, and 64 KiB strings
(`src/config/Document.zig:6-26,105-132`). The public API is read-only, but sibling config
files can access the root tree.

`config.Loader.Result` owns the path, optional document, outcome, and optional
fingerprint (`src/config/Loader.zig:83-123`). The fingerprint includes inode, link count,
size, timestamps, and BLAKE3 content, while equality compares identity-relevant fields
and content. Loading coherently reads only regular, bounded, non-final-symlink files
through `SecureOpen` (`src/config/Loader.zig:130-217`).

`StartupConfig.State` currently owns the config load result and the independent preset
enumeration (`src/cli/StartupConfig.zig:126-145`). Its `Store`, `Selection`, provider
configuration, and prompt expansion borrow the config document for process lifetime.
There is no config writer in `src/config/root.zig`.

`StateWriter.Owner` is the nearest writer pattern (`src/config/StateWriter.zig:99-304`):

- Own an address-stable document slot and expected fingerprint.
- Clone the complete tree and preserve unknown fields.
- Mutate only owned candidate state.
- Pretty-serialize into a bounded 1 MiB buffer before filesystem mutation.
- Create an exclusive mode-0600 sibling temporary file.
- Write, file-sync, verify temporary identity, fingerprint-check the destination, and
  rename.
- Publish the candidate document in memory only after rename succeeds.

It rejects unsafe parents and final symlinks, but it does not directory-sync after
rename and cannot close the final check-to-rename race against an uncoordinated writer.
`persistence.PrivateFileStore` has explicit not-published/uncertain/published outcomes,
poisoning, and parent-directory sync, but assumes an already-open trusted private
directory and is not directly reusable for the user-selected config path.

ZigAI's pinned task and checkpoint stores confirm the same useful baseline: prepare and
bound the complete candidate, write a same-directory temporary, flush, file-sync, and
rename. Their local mutexes do not detect external edits, and their schema reconstruction
would incorrectly drop Zi's unknown config fields.

## Zi preset cache and borrowers

`config.Preset.Enumeration` independently owns valid plans and invalid reports. It does
not borrow the source documents (`src/config/Preset.zig:141-247`). Current borrowers are
safe for cache replacement because they retain the `StartupConfig.Owner` and fetch plans
synchronously:

- `StartupConfig.lookupPreset` and `presetPlans` read the current enumeration.
- `RunSelection.ConfigSource` retains callbacks, not plan slices.
- `/preset` borrows plans only across a synchronous picker and then repeats lookup.
- Preset preparation owns its documents, runtime, prompt, and name before publication.
- Prompt building creates temporary preset facts and returns independently owned bytes.

A save transaction can therefore prepare a candidate config document and candidate
preset enumeration together, commit disk, swap both allocation-free, and retire the old
pair. It must not swap while a synchronous picker or lookup borrow is active.

Provider definitions are also derived from `config.json`, but `/preset-save` changes only
`presets`, so this slice need not rebuild the provider cache. A future generic `/config`
writer will require a broader dependent-cache contract.

## Zi selection capture

`RunSelection.CurrentSelection` already exposes canonical provider ID, resolved model,
effort, active preset, and `model_discovered` (`src/cli/RunSelection.zig:658-734`). Hax's
model omission rule maps directly to `model_discovered`; Zi's richer model provenance is
not a substitute because startup provenance defaults to inherited.

The assembled `TurnSnapshot.system_prompt` is not saveable: it includes built-in and
discovered project context. Source-aware raw prompt values are available from
`StartupConfig.Owner.store.read`, whose source tags are run, conversation, environment,
state, config, or default (`src/config/Store.zig:95-180,239-310`). A preset-save capture
API therefore belongs beside StartupConfig's config source, not in the agent snapshot.

## Zi picker and editor seams

`SelectionPicker.Runner` already accepts a title, rows, initial index, and optional
selection. Picker rows support labels, details, descriptions, safe-current markers,
dimming, and label colors (`src/cli/SelectionPicker.zig:29-62`;
`src/terminal/PickerCore.zig:8-15`). Small adapters can express overwrite confirmation
and tint selection without a new terminal UI.

The editor can atomically replace its buffer and place the cursor at the end
(`src/terminal/LineEditor.zig:48-66`), but `RawLineInput` creates a fresh editor for each
read and `Interactive.PromptInput` exposes no preseed operation. Command outcomes carry
no payload. Pinned Hax executes the slash handler, then admits command history, then transfers an
owned pending seed. The input owner consumes it on the next TTY read; cooked input
discards it (`src/agent.c:1140-1159`; `src/terminal/input.c:1283-1330`). Zi needs an equivalent
bounded, one-shot, input-owned seam usable later by `/config`.

## Required new capability surface

The evidence requires four coordinated additions:

1. A config-owned preset writer that prepares a complete bounded document and preset
   enumeration, race-checks and atomically replaces `config.json`, then publishes both
   in-memory owners together.
2. A source-aware snapshot of exactly the preset-save fields, without assembled prompt
   context.
3. Reusable overwrite and tint picker adapters.
4. A bounded consume-on-next-TTY-read editor preseed channel.

`ProcessSpawn` is not involved because every descriptor can be created with atomic
close-on-exec semantics and no process is spawned.

## Verification surface

Unit and allocation-failure tests need to cover:

- name/tint parsing and exact diagnostics;
- source-aware field capture, discovered-model omission, and description preservation;
- existing valid, malformed, flat, and state-shadow definitions;
- bounded clone, mutation, serialization, candidate enumeration, and every partial OOM;
- external edit, unsafe parent, symlink, temp identity, sync, rename, and cleanup failures;
- allocation-free document-plus-enumeration publication;
- keep/overwrite and tint picker rows, defaults, cancellation, and tint previews;
- one-shot TTY preseed consumption and cooked-input discard;
- save success followed by activation success and activation failure.

Built-binary probes should use only `./zig-out/bin/zi` with temporary XDG roots and the
mock provider. Cover help order, explicit save, tint picker, overwrite, shadow refusal,
external edit, prompt-source capture, save-with-failed-activation, prompt preseeding,
state persistence warning, normal-buffer restoration, and absence of alternate-screen
sequences.

## Decisions still open

1. **Publication durability:** retain StateWriter's file-sync-plus-rename outcome, or add
   parent-directory sync and explicit uncertain-publication poisoning for config writes?
2. **Final race:** accept fingerprint checks plus a small final race, or add a cooperating
   lock protocol that external editors will not honor?
3. **Prompt persistence:** match Hax by copying environment, state, conversation, and run
   prompt overrides, or narrow this because environment and resumed prompts may contain
   secrets the user did not expect to write to `config.json`?
4. **State shadow parity:** preserve Hax's exact nested-object-only refusal even though
   malformed Zi resolution has edge differences, or reject every same-name state value?
5. **Two commits:** preserve Hax's save announcement before activation, with saved config
   surviving activation failure, or announce only after activation succeeds?
6. **Missing-name UX:** add the bounded one-shot preseed now for exact parity, or print the
   instruction without editing the next prompt?
7. **Overwrite identity:** preserve only a valid string description as Hax does, or retain
   additional unknown fields from an existing preset definition?
