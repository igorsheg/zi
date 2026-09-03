# Config command research

Status: approved

References:

- Zi baseline: `ce8cec0b3531eec5a2d83bda5ae7b5b27c99a723`
- Hax product and architecture authority: `189816fb8b02956a6913d7638e6d2cc90a91d61a`
- Hax version: v0.4.0
- ZigAI implementation reference: `e2c5aef5f93015322891028a2048a217e7081687`

Every Hax citation below was read with `git show 189816fb8b02956a6913d7638e6d2cc90a91d61a:<path>`.
The cached Hax checkout currently points at that revision, but the pinned git object remains the source.
Hax defines behavior. ZigAI contributes Zig 0.16 ownership and I/O patterns only.

## Baseline

The supplied Linux path was not visible in this agent environment. The same checkout was available at
`/Users/igors/workspace/dev/personal/zi`. It was clean on `main`; local `HEAD` and `origin/main` both
resolved to `ce8cec0b3531eec5a2d83bda5ae7b5b27c99a723`.

The local baseline used Zig 0.16.0 on Darwin 24.6.0 arm64:

| Check | Result |
| --- | --- |
| `zig fmt --check src/` | passed |
| `zig build` | passed |
| `zig build test` | passed with no output |
| `./zig-out/bin/zi --help` | passed |
| `./zig-out/bin/zi --version` | passed, `zi 0.1.0-dev` |
| `ziglint src build.zig` | ran and reported 22 existing findings |

The lint findings are pre-existing at the clean baseline. They include `ConfigWriter.deinit`, render
cleanup, private-type exposure, line length, and import/style findings. This research change adds no Zig
source.

The handoff also records a different Linux filesystem baseline where `zig build test` reached
1,620 of 1,728 passing tests, with 9 failures, 99 crashes, and 6 leaks caused by the documented
filesystem/BADF problem. The Darwin pass does not reclassify or erase that Linux result. Both baselines
must remain visible until the feature is tested on the intended Linux checkout.

## Pinned Hax sources

Primary behavior and architecture sources:

- `docs/configuration.md:6-64,66-88`
- `src/slash.c:45-52,85-201,228-302,480-483,794-850`
- `src/select.c:1201-1503`
- `src/select.h:28-29`
- `src/config.c:21-298,344-409,541-609,645-694,778-951`
- `src/config.h:153-195`
- `src/agent.c:95-118,1140-1159,1272-1285`
- `src/terminal/picker.c:653-722`
- `src/terminal/input.c:1283-1330`
- `src/terminal/input.h:65-67`
- `src/util.c:260-273`
- `tests/test_select_config.c:41-271,408-423`
- `tests/test_config.c:613-906`
- `tests/test_slash.c:92-125,580-613`

No current-checkout Hax file was treated as evidence without pinning it to the revision above.

## Observable command contract

### Registration and help order

Hax registers `/config` with this exact help row:

```text
/config  view or change settings (optional: key value)
```

It accepts an optional argument and uses managed display output. Registry order is also help order
(`src/slash.c:85-86,147-153,803-834`). The full pinned order is:

```text
/new
/clear                 alias for /new
/resume
/undo
/fork
/provider
/model
/effort
/preset
/preset-save
/config
/compact
/copy
/tasks
/session
/usage
/login
/logout
/help
```

Zi currently implements a subset of that registry. The parity position is after `/preset-save` and
before `/compact` in `src/cli/InteractiveCommands.zig:66-133`.

### Syntax and whitespace

The command has three useful forms:

```text
/config
/config KEY
/config KEY VALUE
```

Slash parsing skips whitespace before the optional argument but preserves the remaining bytes
(`src/slash.c:228-253`). `/config` then splits that argument at the first whitespace run
(`src/select.c:1373-1389`). Consequences:

- `/config markdown` inspects one setting.
- `/config markdown off` writes a run override.
- `/config markdown   off` has the same value, `off`.
- `/config markdown off   ` passes `off   ` as the value and fails validation.
- `/config markdown off extra` passes `off extra` as one value and fails validation.
- `/config markdown   ` is a key-only query because no non-whitespace value remains.
- Only exact lowercase `default` clears an override. `Default` is an ordinary value and normally fails.

A direct key may contain at most 63 bytes. A longer first token reports `unknown setting '<token>'`
without the usual list hint (`src/select.c:1378-1383`).

### No argument

`/config` opens a searchable normal-buffer picker titled `configuration`. It lists registry rows in
registry order, which retains the category grouping encoded by the registry, but it does not add group
header rows. All `providers.*` rows are omitted from this picker. They remain directly queryable by key
(`src/select.c:1431-1474`).

Each row contains:

- the canonical key as its label;
- `VALUE (SOURCE)` as detail, with `, invalid` when the resolved raw value fails typed validation;
- the registry description;
- a value grammar suffix for sizes, durations, and bounded integers;
- dim styling when the setting is read-only at runtime.

Selecting a read-only row prints its value and change guidance. Selecting an editable row with choices
opens a second picker. Selecting an editable free-form row seeds the next prompt with
`/config KEY VALUE`. Numeric settings with symbolic choices add an `exact value...` row that performs
the same handoff (`src/select.c:1294-1371,1495-1503`).

The choice picker starts with:

```text
default
Clear the runtime override and use the environment, saved configuration, or built-in default
```

The current exact choice is selected initially. Tint choices preview their color. For a numeric setting
whose current value is exact and valid, `exact value...` is current and retains that value. Otherwise
it uses the registry example, such as `100` for `display_width`
(`tests/test_select_config.c:215-271`).

### Direct query

`/config KEY` prints:

```text
KEY = VALUE (SOURCE)
```

An invalid non-secret value adds `, invalid` after the source. Values display as follows
(`src/select.c:1216-1255`):

- secrets are `set` or `unset`;
- booleans are normalized to `on` or `off`;
- tri-state values are normalized to `auto`, `on`, or `off` when valid;
- absent values are `unset`;
- a resolved meaningful empty string is `(empty)`;
- other values retain their resolved spelling.

A query of a read-only setting adds one guidance line. Selection keys point to their dedicated command:

```text
  change it with /provider
  change it with /model
  change it with /effort
  change it with /preset
```

Other read-only keys print:

```text
  read-only at runtime — set ENV_VAR or config.json and restart to change
```

### Direct mutation

`/config KEY VALUE` is typed process-local mutation, not JSON editing.

The command first finds a static registry row. It rejects unknown keys, rejects non-editable rows,
validates the complete remaining value, canonicalizes an enum choice where needed, and only then
publishes the run override. A successful change refreshes display state and prints the same current
setting line as a query (`src/select.c:1373-1428`).

`default` deletes the run override. It does not write the internal `(default)` sentinel. Lower tiers are
then visible again according to normal precedence.

The command accepts case-insensitive enum choices and stores their canonical registry spelling. Boolean
aliases `1/0`, `true/false`, `yes/no`, and `on/off` are accepted case-insensitively. Their display is
normalized even when the stored run spelling is an alias. Integers are complete base-10 values. Sizes
accept a positive integer with an optional binary `k` or `m` suffix. Durations accept a nonnegative
integer with no suffix or `ms`, `s`, `m`, or `h`; no suffix means seconds
(`src/config.c:778-904`; `src/util.c:260-273`).

### Exact diagnostics

Pinned Hax emits these command-specific messages:

```text
unknown setting 'KEY' — /config lists them
unknown setting 'TOO_LONG_KEY'
'provider' can't be changed from /config — use /provider
'KEY' can't be changed at runtime — set ENV_VAR or config.json and restart
invalid value 'VALUE' for KEY (expected: HINT, or default)
```

A read-only query uses the note wording shown above. Successful mutation has no separate success phrase;
the resulting `KEY = VALUE (run)` line is the confirmation.

Picker cancellation is silent and leaves state unchanged. Cancellation from either the outer setting
picker or inner choice picker returns no setting outcome. Hax's `xmalloc` family treats allocation
failure as fatal rather than as a recoverable `/config` diagnostic. Zi must return allocation and I/O
errors through its existing command path instead of copying that process-abort behavior.

## Registry and type model

Hax has 66 ordered registry rows and 23 runtime-editable rows at the pinned revision
(`src/config.c:25-246`). Each `config_setting` contains:

```text
key
environment variable
optional default
human description
optional | separated choices
optional numeric example
kind: string | int | size | duration
optional minimum and maximum in native units
editable
secret
keep_empty
```

Choices are exhaustive for strings and additive for numeric kinds. Hax models boolean and tri-state
settings as string settings with the shared choice grammars `on|off` and `auto|on|off`
(`src/config.h:153-176`).

The 23 Hax-editable settings are:

```text
markdown
show_reasoning
sort_models
context_limit
display_width
notify
theme
tint
keep_awake
compact.auto
compact.threshold
max_turns
image_input
tool_output_cap
bash.timeout
bash.timeout_max
bash.timeout_grace
bash.background_yield
task.wait_timeout
task.max_running
http.max_retries
http.retry_base
http.idle_timeout
```

Provider, model, effort, and preset are deliberately not editable through `/config`. System prompt and
context-construction settings are also read-only despite some consumers being able to read them later.
Hax uses the registry's `editable` bit as the product boundary, not a guess based on technical
possibility.

Three registered API key rows are secret. Provider rows are hidden from the no-argument picker because
provider blocks are definition data owned by `/provider`, environment variables, and `config.json`.
Direct key queries still work and still redact secrets (`src/select.c:1216-1223,1437-1445`).

## Resolution, persistence, and activation

### Precedence and source labels

For ordinary settings, the first present eligible value wins:

```text
run override
resumed conversation
environment
state.json
config.json
registry default
```

The source labels exposed by `/config` are exactly `run`, `conversation`, `env`, `state`, `config`, and
`default` (`src/config.c:548-609`; `docs/configuration.md:24-43`). Model and effort values in persistent
tiers apply only when their sibling provider matches the active provider.

An invalid configured typed value remains visible with its real source and `invalid` marker. Typed
consumers fall back to the registry default. The UI therefore distinguishes "what the user supplied"
from "what the consumer safely uses."

### Persistence

`/config` writes neither `config.json` nor `state.json`. It changes only Hax's in-memory run object via
`config_set_override` (`src/config.c:926-939`). The change lasts for the current process and outranks
environment, state, and config values. `default` removes that run member.

This answers the file-mutation questions directly:

- No config writer is called.
- File permissions, symlinks, concurrent edits, malformed documents, and rename failures are outside
  the command transaction.
- Comments cannot exist in accepted `config.json` because the format is strict JSON.
- Unknown keys, nested fields, scalar descriptions, duplicate spelling, and original file bytes survive
  because `/config` never rewrites either persistent document.
- A malformed or oversized startup file is ignored with its startup warning, but a valid direct runtime
  override can still be applied.

Hax's preset writer rules are relevant to `/preset-save`, not `/config`. Generalizing Zi's
preset-scoped `ConfigWriter` for this command would add the wrong persistence contract.

### Activation timing

Every editable value becomes the resolved run value immediately. Hax then activates it in one of two
ways:

1. Display state refreshes before the command returns. `agent_display_refresh` reruns theme selection,
   updates reasoning visibility, destroys the old Markdown renderer, and recreates it when Markdown is
   enabled (`src/agent.c:95-118`; `src/select.c:1286-1292`).
2. Other consumers read the registry live at their next use. Since slash commands execute between
   turns, request, tool, compaction, and transport changes affect the next relevant operation.

Concrete timing by group:

| Settings | Hax activation |
| --- | --- |
| `markdown`, `show_reasoning`, `theme`, `tint` | display refresh during the command |
| `display_width` | next width calculation, including the next prompt and output |
| `sort_models` | next `/model` picker |
| `context_limit`, `image_input` | next metadata, display, request, or tool capability use |
| `notify` | next notification |
| `keep_awake` | next turn sleep-inhibition decision |
| `compact.auto`, `compact.threshold`, `max_turns` | next loop or compaction check |
| tool, bash, and task settings | next relevant tool call or task admission; existing tasks are unchanged |
| HTTP retry settings | next HTTP request |

No editable Hax row requires restart. Read-only rows either use their dedicated selection command or
require a restart after environment or file configuration.

## TTY and cooked input

Hax's picker returns cancellation immediately when either stdin or stdout is not a TTY
(`src/terminal/picker.c:653-656`). Therefore:

- no-argument `/config` is silent in cooked mode;
- `/config KEY` works in cooked mode;
- `/config KEY VALUE` works in cooked mode;
- picker cancellation in a TTY is silent;
- an exact-input handoff seeds only the next editable TTY read;
- a pending seed is discarded before a non-TTY canonical read
  (`src/terminal/input.c:1306-1330`; `src/terminal/input.h:65-67`).

Zi already has the matching composition points. Cooked commands use an unstyled
`InteractiveCommands.Owner`, while raw mode uses the normal-buffer terminal picker. Command preseed is
borrowed only through synchronous outcome delivery and copied by `RawLineInput`. It is bounded by the
prompt limit, replaces the previous seed only after allocation succeeds, is one-shot, and cooked input
discards it (`src/cli/Interactive.zig:203-239,537-615,997-1117`;
`src/terminal/RawLineInput.zig:100-144,1129-1194`).

## Bounds and output safety

Pinned Hax enforces these relevant limits:

- `config.json` and `state.json`: 1 MiB each (`src/config.c:298,376-409`);
- direct config key token: 63 bytes (`src/select.c:1378-1386`);
- value-hint stack buffer: 64 bytes (`src/select.c:1418-1422`);
- setting picker count: the static 66-row registry, with provider rows filtered out;
- picker viewport: at most 12 rows (`src/terminal/picker.c:26,451-485`);
- typed numeric ranges from each registry row.

Hax does not place a command-specific byte cap on an editable input line, an environment-backed string
shown by a direct query, or the allocated picker detail text. Its editor buffer grows dynamically.
Those are gaps, not behavior Zi should copy.

Zi already caps config input at 1 MiB, JSON depth at 64, fields at 8,192, tokens at 262,144, ordinary
JSON strings at 64 KiB, and runtime strings through `Document.runtime_limits`
(`src/config/Document.zig:6-29,105-127`). Its picker clips visible rows and descriptions, and raw prompt
preseed is bounded. `/config` still needs an explicit retained-row and direct-output budget so a large
environment value or config scalar cannot cause unbounded allocation or terminal output.

Hax prints unrestricted read-only values directly. That permits control bytes from config or the
environment to affect terminal output. Zi must use `cli/DiagnosticText.zig` for keys, values, and errors,
redact secrets before formatting, clip to the command budget, and preserve plain ANSI-free cooked
output. This is a required safety narrowing.

## Current Zi seams

### Config ownership

- `src/config/root.zig:1-30` is the public module seam and already registers every config test.
- `src/config/Loader.zig:7-8,83-217` owns path and 1 MiB file loading, regular-file checks, and content
  fingerprints.
- `src/config/Document.zig:6-29,105-220` owns bounded JSON and dotted-key lookup. Exact flat dotted keys
  outrank nested traversal.
- `src/config/Store.zig:95-180,238-383` already implements the six-tier source model and owned reads.
- `src/config/Settings.zig:6-21,643-911` owns the ordered registry and typed fallback getters.
- `src/config/Preset.zig:125-247` owns bounded preset plans and enumeration independent of source
  documents.
- `src/config/AtomicReplace.zig:56-140,143-242` owns conflict-aware regular-file inspection and atomic
  replacement.
- `src/config/StateWriter.zig:13-30,61-134,215-270` writes only remembered selection state.
- `src/config/ConfigWriter.zig:20-51,64-183` owns a stable config document and preset enumeration, but
  exposes only preset inspection and save.

`ConfigWriter` already preserves unknown config roots while replacing one preset and refuses unsafe,
malformed, externally changed, or shadowed files. None of that should be broadened for process-local
`/config`.

### Startup and run overlays

`StartupConfig.Owner` owns heap-stable startup state and delegates current stores to
`config.Selection`. It also owns the config writer transitively
(`src/cli/StartupConfig.zig:174-348,578-623`). `Selection` owns optional run and conversation documents,
prepares complete candidate overlays, and publishes prepared selection changes without allocation
(`src/config/Selection.zig:97-158,490-567`).

There is no generic prepared setting change. `Selection.RunChange` covers selection and startup flags,
not an arbitrary registry key. There is also an address-stability concern. A `Store` created while the
optional run document is absent points to the base run tier; creating the first owned run document later
does not retarget that copied `Store`. A `/config` design must either keep one always-present stable run
document slot or make every long-lived consumer fetch a fresh store through an erased source.

### Slash and interaction

`src/cli/Slash.zig:132-242` already preserves Hax's argument tail, classifies without side effects, and
executes synchronously. `src/cli/Interactive.zig:537-615` admits commands before execution and keeps them
out of model context. No parser change is needed beyond registering the command.

`src/cli/InteractiveCommands.zig` has no `/config` spec or config command source. Its owner stores theme,
width, render frame, selection, picker, tool command collaborators, and warning state. The existing
`SelectionPicker.Runner` supports titles, row detail, descriptions, initial selection, cancellation,
and tint colors. It is sufficient for both config pickers.

### Fixed process-lifetime policies

The central gap is truthful activation. `PrintRun` resolves most editable settings once and copies them
into process-lifetime owners:

| Hax-editable Zi settings | Current Zi owner or snapshot |
| --- | --- |
| `markdown`, `show_reasoning` | selects and configures fixed raw turn renderers at `PrintRun.zig:999-1030,1620-1697` |
| `theme`, `tint` | initial theme plus partial preset-tint updates through `LiveViews` at `PrintRun.zig:872-890,2115-2142` |
| `display_width` | one `DisplayColumns.Policy` copied into input, picker, frame, and render width sources at `PrintRun.zig:971-1001,1443-1723` |
| `sort_models` | resolved by selection building and can be recomputed from a fresh store at `PrintRun.zig:1878-1883,2015-2094` |
| `context_limit` | copied into stats, compaction, and live builder at `PrintRun.zig:704-715,2115-2134` |
| `image_input` | copied into `DynamicImageInput.policy` and the live builder at `PrintRun.zig:713-715,2220-2256` |
| `compact.auto`, `compact.threshold` | mutable fields exist on `AutoCompact`, but startup values are copied once at `PrintRun.zig:778-803,2398-2465` |
| `max_turns` | copied into interactive loop inputs at `PrintRun.zig:779-784` |
| tool, bash, and task settings | copied into `ToolRuntime` configs at `PrintRun.zig:571-623` |
| HTTP retry settings | copied into `ProviderConfig.Inputs.http_policy` at `PrintRun.zig:418-460` |

Zi's current 61-row registry lacks these five Hax rows:

```text
keep_awake
notify
providers.openrouter.referer
providers.openrouter.title
trace
```

The first two are Hax-editable. Zi should not list or claim runtime mutation for unsupported product
features. Among rows Zi already implements, 21 correspond to Hax-editable settings.

## ZigAI patterns worth carrying forward

At ZigAI revision `e2c5aef5f93015322891028a2048a217e7081687`:

- `src/agent_spec.zig:196-235,238-289` prepares an owned candidate, validates before provider
  construction, uses `errdefer` for every ownership edge, and returns one object with one `deinit`.
- `src/capability.zig:118-180` uses a tagged outcome, an arena-owned result, deterministic borrowed
  registry order, explicit limits, and duplicate validation.
- `src/durable/checkpoint.zig:162-190,274-294` loads and validates a complete snapshot, serializes and
  bounds the candidate, flushes and syncs it, and replaces only after all preparation succeeds.
- `src/settings.zig:1-4,96-160` states borrowing duration in the API and validates provider-neutral
  settings before provider-specific use.

The useful adaptation is not ZigAI's product model. It is the transaction shape: build an owned
candidate, validate every dependent policy, publish without allocation, retire old ownership after the
new state is visible, and expose mutually exclusive results as tagged unions.

## Ownership and boundedness constraints for Zi

A later design should preserve these constraints:

1. The setting registry remains static, ordered, provider-independent data in `config`.
2. Registry metadata owns type grammar, editability, secrecy, canonicalization, descriptions, and
   bounds. CLI owns command wording and picker layout.
3. Direct input is borrowed only through synchronous command execution. Any candidate run value is
   copied before publication.
4. The config layer prepares a complete run-tier candidate and returns typed validation outcomes. It
   does not import CLI, render, terminal, tools, or providers.
5. CLI orchestration prepares every affected live policy before publishing any one of them.
6. Publication performs no allocation, I/O, callbacks, or recoverable validation. Retired state is
   cleaned afterward.
7. Failed allocation, validation, policy preparation, or output setup leaves both the resolved run
   store and every live consumer unchanged.
8. Config and environment values shown to users are redacted where secret, escaped for control bytes,
   and clipped to explicit byte and display-cell budgets.
9. Picker rows have a static count bound and a retained-byte bound. Preseed remains bounded by the
   existing raw input limit.
10. Stream event and command outcome payloads remain borrowed only during synchronous delivery.
11. Cooked mode stays plain and ANSI-free. TTY mode stays in the normal terminal buffer.
12. No file writer, state writer, or config fingerprint participates in `/config`.

## Unresolved product and architecture questions

1. Should the first Zi command expose only the 61 settings Zi implements, or add Hax's five missing
   settings and their underlying capabilities first? The smallest honest boundary is the current 61.
2. Must all 21 Hax-editable Zi settings become live in the same capability? Hax says yes. Marking copied
   settings editable before their owners can update would lie to the user.
3. If the capability is split internally, may early slices register `/config` with all rows read-only,
   or should command registration wait until the 21-setting transaction is complete?
4. What exact retained-byte and direct-output caps should Zi promise? Hax has no adequate value-output
   cap. Zi needs a measured limit that still shows useful paths and URLs.
5. Should Zi preserve Hax's silent cooked no-argument behavior, or print guidance to use
   `/config KEY`? Exact parity is silent.
6. Should invalid lower-tier values show the raw rejected value plus `invalid`, as Hax does, or show the
   effective fallback too? Exact parity shows only the raw value and marker.
7. Should setting `default` remain exact lowercase and should trailing whitespace remain literal?
   Existing slash parsing and Hax both say yes.
8. Which owner provides the stable run document? Extending `Selection` is mechanically close, but a
   narrower `RuntimeSettings` owner may prevent selection-specific preset rules from leaking into
   ordinary changes.
9. How should display refresh replace Markdown versus plain renderers while keeping replay, picker,
   prompt, spinner, and frame styles coherent?
10. Can `ToolRuntime` prepare and atomically publish all seven tool-policy changes without disturbing
    running tasks? Existing tasks must retain their established limits.
11. Should HTTP policy become a mutable transport policy read per request, or should provider runtimes
    be rebuilt? Hax reads it per request; rebuilding providers would add unrelated failure modes.
12. How should context-limit and image-input changes coordinate with late catalog refresh so the next
    turn sees one coherent policy snapshot?
13. What is the command-visible failure message when policy preparation runs out of memory or rejects a
    setting for a stricter Zi bound? Hax has no recoverable allocation precedent.
14. Should unsupported Hax rows remain absent from `/config`, or appear read-only with an unsupported
    explanation? The current registry contract favors absence.

## Provenance requirements

Implementation will adapt runtime configuration inspection, source display, typed validation,
process-scoped override semantics, picker behavior, and activation timing from the pinned Hax paths
listed above. The capability commit must extend the Hax paragraph in `THIRD_PARTY_NOTICES.md` with that
behavior and retain revision `189816fb8b02956a6913d7638e6d2cc90a91d61a`.

ZigAI needs no notice change unless source is copied. Its patterns should remain design references, not
translated code.

## Proposed smallest complete capability boundary

The smallest complete `/config` capability is:

1. Register `/config` after `/preset-save` and before `/compact` with Hax's help summary.
2. Extend Zi's existing 61-row registry with the metadata needed for query, validation, redaction,
   choices, examples, editability, and hints.
3. Mark the 21 existing Hax-editable counterparts editable. Keep every other row read-only and point
   selection rows to dedicated commands.
4. Implement direct query, direct typed run override, exact lowercase `default`, enum
   canonicalization, invalid markers, secret redaction, and safe bounded output.
5. Implement the no-argument setting picker and second-stage choice or exact-input picker, including
   silent cancellation and one-shot prompt preseeding.
6. Prepare and atomically publish one coherent run setting plus every affected live policy. All 21
   editable settings must take effect at Hax's timing before the capability is called complete.
7. Support direct query and mutation in cooked input, while no-argument picker execution remains a
   silent no-op there.
8. Leave `config.json`, `state.json`, `ConfigWriter`, `StateWriter`, provider definitions, and preset
   caches untouched.
9. Verify registry order and metadata mechanically, then test config-domain validation, CLI messages,
   picker cancellation and preseed, rollback on every preparation failure, cooked output, PTY behavior,
   and built-binary next-turn effects.

This boundary is larger than a parser addition because Hax's promise is live configuration. A smaller
command that accepts values but leaves process owners unchanged would preserve syntax while breaking
the product contract.
