# Preset and config command research

Status: approved

References:

- Zi: `62ad03580deaf96cb5895d32a715484738a34624`
- Hax product behavior: `189816fb8b02956a6913d7638e6d2cc90a91d61a`
- ZigAI Zig design reference: `e2c5aef5f93015322891028a2048a217e7081687`

Research used the pinned git objects in:

- `/home/igorsheg/.cache/checkouts/github.com/OleksandrChekhovskyi/hax`
- `/home/igorsheg/.cache/checkouts/github.com/Kludex/zigai`

Hax defines the product contract. ZigAI contributes ownership and I/O patterns only.
Zi keeps its own XDG roots and accepts only `ZI_*` product variables.

## Baseline

The checkout started clean on `main` at the Zi revision above and matched
`origin/main`. The host has no `zig` in `PATH`, so the direct ready gate cannot run.

A second baseline attempt used official Zig 0.16.0 and libcurl development files in an
Ubuntu 24.04 container. `zig fmt --check src/` and `zig build` passed. `zig build
test` reported 1,588 passes, one ordinary failure, and 99 crashes. The crashes came
from Docker bind-mount file operations returning `BADF` in Zig's `fileSyncPosix` or
`setPermissionsPosix`; the ordinary timeout test could not read its expected file.
The script stopped before `--help` and `--version`. Container artifacts were removed.
This is an unresolved environment-specific baseline failure and must be rerun on the
native development host before implementation is called ready.

## Hax registry contract

At the pinned Hax revision, registry order is:

```text
new, resume, undo, fork, provider, model, effort, preset, preset-save,
config, compact, copy, tasks, session, usage, login, logout, help
```

The relevant entries are in `src/slash.c:127-159`. Their exact summaries are:

| Command | Summary | Argument policy |
| --- | --- | --- |
| `/preset` | `switch to a config-defined preset (optional: name)` | optional name |
| `/preset-save` | `save the current selection as a preset (name, optional tint)` | optional text |
| `/config` | `view or change settings (optional: key value)` | optional text |

None has an alias. `/preset-save` is a separate command so a preset named `save`
remains valid. Help and lookup use registry order (`src/slash.c:803-834`). Slash
parsing preserves the text after leading argument whitespace (`src/slash.c:228-253`).

Zi currently registers `new, resume, undo, provider, model, effort, compact, help` in
`src/cli/InteractiveCommands.zig:62-112`. The existing allocation-free parser already
accepts hyphenated names and optional arguments (`src/cli/Slash.zig:130-239`,
`src/cli/Slash.zig:254-258`). The three descriptors belong between `/effort` and
`/compact`; no parser redesign is needed.

## Parity map

### `/preset [NAME]`

Hax behavior:

1. With no name, enumerate presets and open the normal-buffer picker. With no valid
   definitions, print
   `no presets defined in config.json — use /preset-save to save the current selection`
   (`src/select.c:825-843`).
2. Sort picker rows alphabetically, start on the active preset, show descriptions and
   explicit provider/model/effort details, preview tint, and leave unknown providers
   selectable so selection can report the real failure (`src/select.c:775-823`).
3. Snapshot the run and resumed-conversation config tiers, apply the prospective
   preset, build a prospective provider, require a resolved model, and rebuild all
   derived settings. Any preparation failure restores both tiers and leaves the live
   conversation untouched (`src/select.c:845-895`).
4. Publish the live provider, model, effort, prompt, policy, and session metadata as
   one selection change. Persist only the active preset stance afterward
   (`src/select.c:897-906`).
5. If state persistence fails, keep the live switch and warn once that the preset
   applies only to this run (`src/select.c:897-905`).
6. In a non-empty conversation, print
   `switched to [PRESET] PROVIDER · MODEL [· EFFORT]`. In an empty conversation,
   redraw the preset-aware banner (`src/agent.c:521-550`, `src/banner.c:95-107`).

Current Zi position:

- Preset names, fields, prompts, tint, and bounded enumeration are already parsed into
  owned plans (`src/config/Preset.zig:26-33`, `src/config/Preset.zig:75-115`,
  `src/config/Preset.zig:141-339`).
- `StartupConfig.Owner` owns the loaded tiers and exposes cached valid and invalid
  presets (`src/cli/StartupConfig.zig:126-136`, `src/cli/StartupConfig.zig:236-241`).
- `config.Selection` already prepares and allocation-free publishes preset overlays
  (`src/config/Selection.zig:130-158`, `src/config/Selection.zig:284-340`).
- `/new PRESET` already uses a move-only candidate to build the provider and prompt,
  update every selection-derived view, publish without allocation, then persist the
  preset stance (`src/cli/RunSelection.zig:543-577`,
  `src/cli/RunSelection.zig:1042-1177`, `src/cli/NewConversation.zig:93-154`).
- `StateWriter` already performs the post-commit state write and reports run-only
  persistence (`src/config/StateWriter.zig:184-350`).
- Command admission already keeps slash commands out of model context and durable
  conversation history (`src/cli/Interactive.zig:581-612`).

Missing Zi work:

- Register and handle `/preset`.
- Expose borrowed preset enumeration through `RunSelection.ConfigSource`, which
  currently exposes lookup and preset preparation only
  (`src/cli/RunSelection.zig:196-221`).
- Add the preset picker adapter and Hax row rendering.
- Generalize the `/new`-named preset transition API without weakening `/new`'s
  quarantined-authority behavior.
- Rebuild the transcript and render the banner or preset-aware switch notice.
- Refresh live presentation objects after tint changes. `PrintRun` currently resolves
  theme and tint once, then copies presentation values into long-lived terminal and
  renderer owners (`src/cli/PrintRun.zig:878-895`,
  `src/cli/PrintRun.zig:1428-1692`).
- Preserve detailed invalid-preset diagnostics instead of collapsing every invalid
  definition to `PresetInvalid`.

### `/preset-save NAME [TINT]`

Hax behavior:

1. Require a live provider and model. With no name, print
   `name it: /preset-save <name> [tint]` and preseed `/preset-save ` into the next
   editor (`src/select.c:1020-1041`).
2. Parse the first word as the name and the rest as tint. Names are 1 to 63 bytes,
   start alphanumeric, and then allow alphanumeric, `.`, `-`, and `_`
   (`src/select.c:1043-1053`, `src/config.c:1435-1448`).
3. Validate tint. Ask before replacing any valid or malformed definition. The safe
   default and cancellation both keep the existing definition
   (`src/select.c:1055-1087`, `src/select.c:962-992`).
4. Without an explicit tint, pick `none`, `teal`, `violet`, `rose`, or `sage`
   (`src/select.c:918-960`).
5. Save provider, current effort, eligible model, non-config/default system prompt
   overrides, selected tint, and an overwritten definition's description
   (`src/select.c:994-1005`, `src/select.c:1089-1099`).
6. Atomically update `config.json`, announce `saved` or `updated`, then enter the new
   preset through the full `/preset` path (`src/select.c:1100-1112`). File save and
   live activation are separate commits. Failed activation does not remove the saved
   definition.
7. Refuse a config save when a same-name state preset would shadow it
   (`src/config.c:1419-1432`, `src/config.c:1466-1471`).

Current Zi position:

- Preset parsing and name validation are reusable.
- Zi has no arbitrary `config.json` writer. `StateWriter` is intentionally limited to
  active selection state (`src/config/StateWriter.zig:13-30`).
- The writer must preserve unknown fields, race-check the loaded fingerprint, write a
  bounded complete candidate, sync it, and atomically replace the file. ZigAI's
  closest patterns are `src/cli/app.zig:254-265`, `src/mcp/task_store.zig:181-235`,
  and `src/durable/checkpoint.zig:162-190` at its pinned revision.
- A successful write must replace the cached preset plans and every borrower together.
  `PrintRun` currently builds prompt preset facts once from slices owned by the cached
  plans (`src/cli/PrintRun.zig:658-696`). Replacing only the cache would dangle those
  slices.
- Zi has no bounded next-editor preseed result. `Interactive.CommandOutcome` is only
  `handled`, `history_changed`, or `exit` (`src/cli/Interactive.zig:189-193`).
- Overwrite confirmation, tint selection, capture provenance, and the two-commit result
  still need explicit designs.

### `/config [KEY [VALUE]]`

Hax behavior:

1. With a key only, print `key = value (source[, invalid])`
   (`src/select.c:1242-1255`).
2. Reject writes to selection settings and direct the user to `/provider`, `/model`,
   `/effort`, or `/preset`. Other read-only rows point to their environment variable
   or `config.json` (`src/select.c:1257-1284`).
3. Treat lowercase `default` as removal of the run override. Validate other values and
   canonicalize enums (`src/select.c:1414-1428`).
4. Change the current process only. Do not write `config.json` or `state.json`. Refresh
   affected presentation state and report the resulting value and source
   (`src/select.c:1286-1292`, `src/agent.c:107-118`).
5. With no arguments, show registry rows in config order and groups. Hide
   `providers.*`, dim read-only rows, and show value, source, validity, description,
   and bounds (`src/select.c:1431-1486`).
6. Use a second picker for choices. Seed `/config KEY VALUE` into the next editor for
   free-form or exact numeric input (`src/select.c:1294-1371`,
   `src/select.c:1488-1503`).
7. Cap direct keys at 63 bytes (`src/select.c:1373-1396`).

Current Zi position:

- The 61-entry canonical registry already provides key, `ZI_*` environment name,
  default, empty policy, kind, numeric bounds, and description
  (`src/config/Settings.zig:6-21`).
- The store already resolves run, conversation, environment, state, config, and default
  tiers. Typed getters exist, but they fall back for invalid values and are not a
  reject-or-canonicalize command validator (`src/config/Settings.zig:695-777`).
- Registry metadata lacks choices, examples, editability, secrecy, and value hints.
- `config.Selection` has no generic prepared run-setting override. Its current generic
  run change covers selection flags only (`src/config/Selection.zig:473-491`).
- Many settings are copied into process-lifetime owners during `PrintRun` setup. A
  truthful `/config` requires prepared updates for render theme, tint, Markdown,
  reasoning visibility, width, max turns, context and image policy, compaction, tools,
  tasks, and HTTP retries (`src/cli/PrintRun.zig:415-455`,
  `src/cli/PrintRun.zig:569-620`, `src/cli/PrintRun.zig:703-802`,
  `src/cli/PrintRun.zig:878-987`).

## Shared persistence and limits

Hax caps `config.json` and `state.json` at 1 MiB and prompt files at 64 KiB
(`src/config.c:298-299`, `src/config.c:726-765`). Its writer resolves symlink targets,
writes pretty JSON to a mode-`0600` sibling temporary file, then renames it over the
destination (`src/config.c:1075-1155`). A malformed or oversized startup config blocks
later saves so the process cannot replace content it never loaded
(`src/config.c:376-409`, `src/config.c:1158-1163`). The pinned implementation does not
detect concurrent external edits.

Zi should retain its existing stricter fingerprint and regular-file checks rather than
copy Hax's lost-update behavior. ZigAI supports this narrower contract: prepare and
validate the complete candidate before publication, keep owned candidates private, and
transfer ownership only after success (`src/agent_spec.zig:209-289`,
`src/durable/checkpoint.zig:162-190` at the pinned ZigAI revision).

## Dependency map

```text
existing Store, Settings, Preset, Selection, StateWriter
    |
    +-- live preset candidate and publication
    |     +-- /new PRESET, already implemented
    |     +-- /preset, small command and presentation extension
    |           +-- activation step used by /preset-save
    |
    +-- new atomic config document owner
    |     +-- preset serialization and cache replacement
    |           +-- /preset-save
    |
    +-- generic prepared run-setting updates
          +-- dynamic policy owners across PrintRun
                +-- /config
```

The family shares configuration concepts, but it is not one implementation-sized
transaction. `/preset` reuses a complete live transaction. `/preset-save` adds a new
durable document transaction. `/config` requires mutable ownership for settings that
are currently fixed at startup.

## Smallest sensible vertical slice

Implement `/preset [NAME]` alone, including the optional picker. This is smaller and
safer than implementing only the explicit argument paths for all three commands.
It exercises one complete user capability through the binary and reuses the hard
provider, prompt, session, tool, and state transaction already proven by `/new PRESET`.

Acceptance for that slice:

- `/help` places `/preset` between `/effort` and `/compact`.
- A named preset and a picker-selected preset both switch the next request.
- Success updates provider, model, effort, prompt, tool environment, context/image
  policy, session metadata, transcript, active tint, and later state persistence.
- Empty and non-empty conversations use Hax's distinct banner and switch notice.
- Cancellation, missing or invalid definitions, provider failure, and allocation
  failure leave the live selection and conversation unchanged.
- State-write failure keeps the live selection and warns once.
- Built-binary probes use temporary Zi XDG roots, `ZI_*` variables, the mock provider,
  and the normal terminal buffer.

`/preset-save` should follow as the config-writer slice. `/config` should follow only
after its product contract decides which registered settings are truly live-editable.

## Open questions

1. Confirm `/preset` as the first slice, rather than combining shallow named-only paths
   from all three commands.
2. Confirm that Zi should refresh tint and all presentation owners immediately. This is
   required for Hax parity and also fixes the current `/new PRESET` banner mismatch.
3. Confirm that Zi should keep its stricter concurrent-edit rejection for future
   `config.json` writes instead of matching Hax's lost-update behavior.
4. For `/preset-save`, preserve Hax's two commits and its announcement order, or defer
   `saved preset` output until activation succeeds?
5. For `/preset-save`, should Zi copy system prompts sourced from environment, state,
   or resumed conversation into durable config exactly as Hax does?
6. For `/config`, which of the 61 settings are promised to change the current process?
   Rows tied to startup-only construction need either dynamic owners or an explicit
   read-only classification.
7. Preserve Hax's next-editor preseeding for missing preset names and free-form config
   values? The recommendation is yes, with a bounded terminal-owned one-shot buffer.
8. Preserve Hax's literal handling of trailing argument whitespace, or trim names and
   values in Zi? Exact parity keeps it literal.
